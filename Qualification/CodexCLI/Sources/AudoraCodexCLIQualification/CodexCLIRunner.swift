import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct CodexRunControl: Equatable, Sendable {
    public var cancelAfterSeconds: TimeInterval?

    public init(cancelAfterSeconds: TimeInterval? = nil) {
        if let cancelAfterSeconds {
            precondition(cancelAfterSeconds >= 0)
        }
        self.cancelAfterSeconds = cancelAfterSeconds
    }
}

public struct CodexCLIRunner: Sendable {
    public init() {}

    public func run(
        plan: CodexInvocationPlan,
        limits: QualificationLimits = QualificationLimits(),
        control: CodexRunControl = CodexRunControl()
    ) -> CodexRunOutcome {
        let startedAt = Date()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let output = BoundedByteCollector(limit: limits.eventStreamByteCeiling)
        let failureSignal = BoundedByteCollector(limit: limits.failureSignalByteCeiling)
        let readers = DispatchGroup()

        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = plan.workingDirectoryURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return .failure(
                SanitizedFailure(
                    reason: .processFailure,
                    processWasReaped: true,
                    durationMilliseconds: elapsedMilliseconds(since: startedAt)
                )
            )
        }

        startReader(
            outputPipe.fileHandleForReading,
            collector: output,
            group: readers
        )
        startReader(
            errorPipe.fileHandleForReading,
            collector: failureSignal,
            group: readers
        )

        inputPipe.fileHandleForWriting.write(plan.standardInput)
        try? inputPipe.fileHandleForWriting.close()

        let stopReason = monitor(
            process: process,
            output: output,
            failureSignal: failureSignal,
            limits: limits,
            control: control,
            startedAt: startedAt
        )
        if process.isRunning {
            terminateAndReap(process, graceSeconds: limits.terminationGraceSeconds)
        } else {
            process.waitUntilExit()
        }

        readers.wait()
        let duration = elapsedMilliseconds(since: startedAt)
        let reaped = !process.isRunning

        if let stopReason {
            return .failure(
                SanitizedFailure(
                    reason: stopReason,
                    processWasReaped: reaped,
                    durationMilliseconds: duration
                )
            )
        }

        let parsed = CodexEventParser.parse(output.data)
        if parsed.forbiddenCapabilityWasUsed {
            return .failure(
                SanitizedFailure(
                    reason: .forbiddenCapabilityUsed,
                    processWasReaped: reaped,
                    durationMilliseconds: duration
                )
            )
        }

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let reason = SanitizedErrorClassifier.classify(
                standardErrorSignal: failureSignal.data,
                structuredEventSignal: output.data
            )
            return .failure(
                SanitizedFailure(
                    reason: reason,
                    processWasReaped: reaped,
                    durationMilliseconds: duration
                )
            )
        }

        guard
            !parsed.wasMalformed,
            let response = parsed.lastAgentMessage,
            let outputTokens = parsed.outputTokenCount,
            StrictQualificationResponseValidator.isValid(response)
        else {
            return .failure(
                SanitizedFailure(
                    reason: .malformedOutput,
                    processWasReaped: reaped,
                    durationMilliseconds: duration
                )
            )
        }

        let responseBytes = response.utf8.count
        guard responseBytes <= limits.responseByteCeiling else {
            return .failure(
                SanitizedFailure(
                    reason: .responseByteLimit,
                    processWasReaped: reaped,
                    durationMilliseconds: duration
                )
            )
        }
        guard outputTokens <= limits.outputTokenCeiling else {
            return .failure(
                SanitizedFailure(
                    reason: .outputTokenLimit,
                    processWasReaped: reaped,
                    durationMilliseconds: duration
                )
            )
        }

        return .success(
            QualifiedResponse(
                responseByteCount: responseBytes,
                outputTokenCount: outputTokens,
                processWasReaped: reaped,
                durationMilliseconds: duration
            )
        )
    }

    private func monitor(
        process: Process,
        output: BoundedByteCollector,
        failureSignal: BoundedByteCollector,
        limits: QualificationLimits,
        control: CodexRunControl,
        startedAt: Date
    ) -> SanitizedFailureReason? {
        while process.isRunning {
            let elapsed = Date().timeIntervalSince(startedAt)
            if output.didOverflow {
                return .responseByteLimit
            }
            if failureSignal.didOverflow {
                return .processFailure
            }
            if let cancelAfter = control.cancelAfterSeconds, elapsed >= cancelAfter {
                return .cancelled
            }
            if elapsed >= limits.timeoutSeconds {
                return .timedOut
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    private func terminateAndReap(_ process: Process, graceSeconds: TimeInterval) {
        if process.isRunning {
            process.terminate()
        }

        let graceDeadline = Date().addingTimeInterval(graceSeconds)
        while process.isRunning, Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private func startReader(
        _ handle: FileHandle,
        collector: BoundedByteCollector,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                collector.append(data)
            }
        }
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }
}

private final class BoundedByteCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var overflow = false

    init(limit: Int) {
        self.limit = limit
        storage.reserveCapacity(min(limit, 16 * 1_024))
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var didOverflow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflow
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        let remaining = max(0, limit - storage.count)
        if data.count > remaining {
            storage.append(data.prefix(remaining))
            overflow = true
        } else {
            storage.append(data)
        }
    }
}

private struct ParsedCodexEvents {
    var lastAgentMessage: String?
    var outputTokenCount: Int?
    var forbiddenCapabilityWasUsed = false
    var wasMalformed = false
}

private enum CodexEventParser {
    private static let safeItemTypes: Set<String> = [
        "agent_message",
        "error",
        "reasoning",
    ]

    static func parse(_ data: Data) -> ParsedCodexEvents {
        var result = ParsedCodexEvents()
        let stream = String(decoding: data, as: UTF8.self)

        for line in stream.split(whereSeparator: \Character.isNewline) {
            guard
                let lineData = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: lineData),
                let event = object as? [String: Any]
            else {
                result.wasMalformed = true
                continue
            }

            if let item = event["item"] as? [String: Any],
               let itemType = item["type"] as? String {
                if !safeItemTypes.contains(itemType) {
                    result.forbiddenCapabilityWasUsed = true
                }
                if itemType == "agent_message", let text = item["text"] as? String {
                    result.lastAgentMessage = text
                }
            }

            if let usage = event["usage"] as? [String: Any],
               let outputTokens = usage["output_tokens"] as? NSNumber {
                result.outputTokenCount = outputTokens.intValue
            }
        }

        return result
    }
}

private enum StrictQualificationResponseValidator {
    static func isValid(_ text: String) -> Bool {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            Set(root.keys) == ["messageBlocks"],
            let blocks = root["messageBlocks"] as? [[String: Any]],
            blocks.count == 1,
            let block = blocks.first,
            Set(block.keys) == ["kind", "markdown"],
            block["kind"] as? String == "markdown",
            let markdown = block["markdown"] as? String,
            !markdown.isEmpty,
            markdown.count <= 160
        else {
            return false
        }
        return true
    }
}

public enum SanitizedErrorClassifier {
    public static func classify(
        standardErrorSignal: Data,
        structuredEventSignal: Data = Data()
    ) -> SanitizedFailureReason {
        let signal = (
            String(decoding: standardErrorSignal, as: UTF8.self)
                + "\n"
                + String(decoding: structuredEventSignal, as: UTF8.self)
        ).lowercased()

        if containsAny(
            signal,
            ["authentication", "unauthorized", "not logged in", "login required", "invalid api key", "status 401", "http 401"]
        ) {
            return .authentication
        }
        if containsAny(
            signal,
            ["insufficient_quota", "quota", "billing", "usage limit", "credit balance"]
        ) {
            return .quota
        }
        if containsAny(
            signal,
            ["model_not_found", "model not found", "model is not available", "unavailable model", "unsupported model", "unknown model", "does not exist"]
        ) {
            return .unavailableModel
        }
        if containsAny(
            signal,
            ["rate limit", "status 429", "http 429", "timed out", "timeout", "connection reset", "connection refused", "temporarily unavailable", "server error", "status 5"]
        ) {
            return .transient
        }
        if containsAny(
            signal,
            ["output schema", "invalid json", "malformed output", "structured output"]
        ) {
            return .malformedOutput
        }
        return .processFailure
    }

    private static func containsAny(_ signal: String, _ patterns: [String]) -> Bool {
        patterns.contains(where: signal.contains)
    }
}
