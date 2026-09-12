import Foundation

struct CodexRunControl: Equatable, Sendable {
    var cancelAfterSeconds: TimeInterval?

    init(cancelAfterSeconds: TimeInterval? = nil) {
        if let cancelAfterSeconds {
            precondition(cancelAfterSeconds >= 0)
        }
        self.cancelAfterSeconds = cancelAfterSeconds
    }
}

struct CodexCLIRunner: Sendable {
    init() {}

    func run(
        plan: CodexInvocationPlan,
        limits: QualificationLimits = QualificationLimits(),
        control: CodexRunControl = CodexRunControl()
    ) -> CodexRunOutcome {
        let process = BoundedProcessHost().run(
            BoundedProcessRequest(
                executableURL: plan.executableURL,
                arguments: plan.arguments,
                environment: plan.environment,
                workingDirectoryURL: plan.workingDirectoryURL,
                standardInput: plan.standardInput,
                standardOutputByteCeiling: limits.eventStreamByteCeiling,
                standardErrorByteCeiling: limits.failureSignalByteCeiling,
                timeoutSeconds: limits.timeoutSeconds,
                cancelAfterSeconds: control.cancelAfterSeconds,
                terminationGraceSeconds: limits.terminationGraceSeconds
            )
        )
        guard process.launched else {
            return .failure(
                SanitizedFailure(
                    reason: .processFailure,
                    processWasReaped: true,
                    durationMilliseconds: process.durationMilliseconds
                )
            )
        }

        if process.stopReason != nil {
            switch CodexEventParser.capturedOutputConfinementStatus(
                process.standardOutput,
                rejectIncompleteTrailingLine: process.terminationTrigger == .cancelled
                    || process.terminationTrigger == .timedOut
            ) {
            case .forbiddenCapability:
                return .failure(
                    SanitizedFailure(
                        reason: .forbiddenCapabilityUsed,
                        processWasReaped: process.processGroupWasReaped,
                        durationMilliseconds: process.durationMilliseconds
                    )
                )
            case .malformed:
                return .failure(
                    SanitizedFailure(
                        reason: .malformedOutput,
                        processWasReaped: process.processGroupWasReaped,
                        durationMilliseconds: process.durationMilliseconds
                    )
                )
            case .clean:
                break
            }
        }

        if let stopReason = process.stopReason {
            if stopReason == .cancelled {
                let parsed = CodexEventParser.parse(process.standardOutput)
                guard
                    !parsed.wasMalformed,
                    !parsed.forbiddenCapabilityWasUsed,
                    !parsed.failureEventWasObserved,
                    parsed.providerWorkWasAcknowledged
                else {
                    return .failure(
                        SanitizedFailure(
                            reason: .processFailure,
                            processWasReaped: process.processGroupWasReaped,
                            durationMilliseconds: process.durationMilliseconds
                        )
                    )
                }
            }
            let reason: SanitizedFailureReason = switch stopReason {
            case .standardOutputLimit: .responseByteLimit
            case .standardErrorLimit, .ioFailure: .processFailure
            case .cancelled: .cancelled
            case .timedOut: .timedOut
            }
            return .failure(
                SanitizedFailure(
                    reason: reason,
                    processWasReaped: process.processGroupWasReaped,
                    durationMilliseconds: process.durationMilliseconds
                )
            )
        }

        guard process.standardInputWasWritten else {
            return .failure(
                SanitizedFailure(
                    reason: .processFailure,
                    processWasReaped: process.processGroupWasReaped,
                    durationMilliseconds: process.durationMilliseconds
                )
            )
        }

        let parsed = CodexEventParser.parse(process.standardOutput)
        if parsed.forbiddenCapabilityWasUsed {
            return .failure(
                SanitizedFailure(
                    reason: .forbiddenCapabilityUsed,
                    processWasReaped: process.processGroupWasReaped,
                    durationMilliseconds: process.durationMilliseconds
                )
            )
        }

        if parsed.wasMalformed {
            return .failure(
                SanitizedFailure(
                    reason: .malformedOutput,
                    processWasReaped: process.processGroupWasReaped,
                    durationMilliseconds: process.durationMilliseconds
                )
            )
        }

        if parsed.failureEventWasObserved {
            return .failure(
                SanitizedFailure(
                    reason: SanitizedErrorClassifier.classify(
                        standardErrorSignal: process.standardError,
                        structuredEventSignal: process.standardOutput
                    ),
                    processWasReaped: process.processGroupWasReaped,
                    durationMilliseconds: process.durationMilliseconds
                )
            )
        }

        guard process.exitedNormally, process.exitStatus == 0 else {
            let reason = SanitizedErrorClassifier.classify(
                standardErrorSignal: process.standardError,
                structuredEventSignal: process.standardOutput
            )
            return .failure(
                SanitizedFailure(
                    reason: reason,
                    processWasReaped: process.processGroupWasReaped,
                    durationMilliseconds: process.durationMilliseconds
                )
            )
        }

        guard
            parsed.agentMessageCount == 1,
            parsed.usageRecordCount == 1,
            let response = parsed.lastAgentMessage,
            let outputTokens = parsed.outputTokenCount,
            StrictQualificationResponseValidator.isValid(response)
        else {
            return .failure(
                SanitizedFailure(
                    reason: .malformedOutput,
                    processWasReaped: process.processGroupWasReaped,
                    durationMilliseconds: process.durationMilliseconds
                )
            )
        }

        let responseBytes = response.utf8.count
        guard responseBytes <= limits.responseByteCeiling else {
            return .failure(
                SanitizedFailure(
                    reason: .responseByteLimit,
                    processWasReaped: process.processGroupWasReaped,
                    durationMilliseconds: process.durationMilliseconds
                )
            )
        }
        guard outputTokens <= limits.outputTokenCeiling else {
            return .failure(
                SanitizedFailure(
                    reason: .outputTokenLimit,
                    processWasReaped: process.processGroupWasReaped,
                    durationMilliseconds: process.durationMilliseconds
                )
            )
        }

        return .success(
            QualifiedResponse(
                responseByteCount: responseBytes,
                outputTokenCount: outputTokens,
                processWasReaped: process.processGroupWasReaped,
                durationMilliseconds: process.durationMilliseconds
            )
        )
    }
}

private struct ParsedCodexEvents {
    var lastAgentMessage: String?
    var agentMessageCount = 0
    var outputTokenCount: Int?
    var usageRecordCount = 0
    var forbiddenCapabilityWasUsed = false
    var failureEventWasObserved = false
    var providerWorkWasAcknowledged = false
    var wasMalformed = false
}

private enum CodexEventParser {
    enum CapturedOutputConfinementStatus: Equatable {
        case clean
        case forbiddenCapability
        case malformed
    }

    private static let permittedEventTypes: Set<String> = [
        "error",
        "item.completed",
        "item.started",
        "item.updated",
        "thread.started",
        "turn.completed",
        "turn.failed",
        "turn.started",
    ]
    private static let itemEventTypes: Set<String> = [
        "item.completed",
        "item.started",
        "item.updated",
    ]
    private static let safeItemTypes: Set<String> = [
        "agent_message",
        "error",
        "reasoning",
    ]

    static func capturedOutputConfinementStatus(
        _ data: Data,
        rejectIncompleteTrailingLine: Bool
    ) -> CapturedOutputConfinementStatus {
        var status = CapturedOutputConfinementStatus.clean
        var lineStart = data.startIndex
        for index in data.indices where data[index] == 0x0a {
            let line = Data(data[lineStart ..< index])
            let lineStatus = completeLineConfinementStatus(line)
            if lineStatus == .forbiddenCapability {
                return .forbiddenCapability
            }
            if lineStatus == .malformed {
                status = .malformed
            }
            lineStart = data.index(after: index)
        }

        guard lineStart < data.endIndex else { return status }
        let trailingLine = Data(data[lineStart ..< data.endIndex])
        guard !trailingLine.allSatisfy(isJSONWhitespace) else { return status }
        guard (try? JSONSerialization.jsonObject(with: trailingLine)) != nil else {
            return rejectIncompleteTrailingLine ? .malformed : status
        }
        let trailingStatus = completeLineConfinementStatus(trailingLine)
        if trailingStatus == .forbiddenCapability {
            return .forbiddenCapability
        }
        if trailingStatus == .malformed {
            status = .malformed
        }
        return status
    }

    private static func completeLineConfinementStatus(
        _ data: Data
    ) -> CapturedOutputConfinementStatus {
        guard !data.isEmpty else { return .clean }
        guard
            StrictJSONDocument.hasUniqueObjectKeys(data),
            let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .malformed
        }
        if let item = event["item"] as? [String: Any],
           let itemType = item["type"] as? String,
           !safeItemTypes.contains(itemType) {
            return .forbiddenCapability
        }
        let parsed = parse(data)
        if parsed.forbiddenCapabilityWasUsed {
            return .forbiddenCapability
        }
        return parsed.wasMalformed ? .malformed : .clean
    }

    static func parse(_ data: Data) -> ParsedCodexEvents {
        var result = ParsedCodexEvents()
        guard let stream = String(data: data, encoding: .utf8) else {
            result.wasMalformed = true
            return result
        }

        for line in stream.split(whereSeparator: \Character.isNewline) {
            guard
                let lineData = String(line).data(using: .utf8),
                StrictJSONDocument.hasUniqueObjectKeys(lineData),
                let object = try? JSONSerialization.jsonObject(with: lineData),
                let event = object as? [String: Any]
            else {
                result.wasMalformed = true
                continue
            }
            guard
                let eventType = event["type"] as? String,
                permittedEventTypes.contains(eventType),
                hasPermittedShape(event, type: eventType)
            else {
                result.wasMalformed = true
                continue
            }

            if ["error", "turn.failed"].contains(eventType) {
                result.failureEventWasObserved = true
            }

            if event.keys.contains("item") {
                guard
                    itemEventTypes.contains(eventType),
                    let item = event["item"] as? [String: Any],
                    let itemType = item["type"] as? String
                else {
                    result.wasMalformed = true
                    continue
                }
                if !safeItemTypes.contains(itemType) {
                    result.forbiddenCapabilityWasUsed = true
                }
                if ["agent_message", "reasoning"].contains(itemType),
                   !Set(item.keys).isSubset(of: ["id", "type", "text"]) {
                    result.wasMalformed = true
                    continue
                }
                if itemType == "reasoning", !(item["text"] is String) {
                    result.wasMalformed = true
                    continue
                }
                if ["agent_message", "reasoning"].contains(itemType) {
                    result.providerWorkWasAcknowledged = true
                }
                if itemType == "error" {
                    guard
                        Set(item.keys).isSubset(of: ["code", "id", "message", "type"]),
                        item["code"] != nil || item["message"] != nil,
                        item["code"] == nil || item["code"] is String,
                        item["message"] == nil || item["message"] is String
                    else {
                        result.wasMalformed = true
                        continue
                    }
                    result.failureEventWasObserved = true
                }
                if itemType == "agent_message" {
                    guard let text = item["text"] as? String else {
                        result.wasMalformed = true
                        continue
                    }
                    if event["type"] as? String == "item.completed" {
                        result.agentMessageCount += 1
                        result.lastAgentMessage = text
                    }
                }
            }

            if eventType == "turn.completed" {
                guard
                    let usage = event["usage"] as? [String: Any],
                    let outputTokens = exactTokenUsage(
                        in: lineData,
                        keys: Set(usage.keys)
                    )
                else {
                    result.wasMalformed = true
                    continue
                }
                result.usageRecordCount += 1
                result.outputTokenCount = outputTokens
            }
        }

        return result
    }

    private static func hasPermittedShape(
        _ event: [String: Any],
        type: String
    ) -> Bool {
        switch type {
        case "thread.started":
            return Set(event.keys) == ["thread_id", "type"]
                && event["thread_id"] is String
        case "turn.started":
            return Set(event.keys) == ["type"]
        case "item.completed", "item.started", "item.updated":
            return Set(event.keys) == ["item", "type"]
                && event["item"] is [String: Any]
        case "turn.completed":
            guard
                Set(event.keys) == ["type", "usage"],
                let usage = event["usage"] as? [String: Any],
                Set(usage.keys).isSubset(
                    of: [
                        "cached_input_tokens",
                        "input_tokens",
                        "output_tokens",
                        "reasoning_output_tokens",
                    ]
                ),
                usage["output_tokens"] != nil
            else {
                return false
            }
            return true
        case "error":
            guard
                Set(event.keys).isSubset(of: ["code", "message", "type"]),
                event["code"] != nil || event["message"] != nil
            else {
                return false
            }
            return (event["code"] == nil || event["code"] is String)
                && (event["message"] == nil || event["message"] is String)
        case "turn.failed":
            guard
                Set(event.keys) == ["error", "type"],
                let error = event["error"] as? [String: Any],
                Set(error.keys).isSubset(of: ["code", "message"]),
                error["code"] != nil || error["message"] != nil
            else {
                return false
            }
            return (error["code"] == nil || error["code"] is String)
                && (error["message"] == nil || error["message"] is String)
        default:
            return false
        }
    }

    private static func exactTokenUsage(
        in data: Data,
        keys: Set<String>
    ) -> Int? {
        let bytes = [UInt8](data)
        var outputTokens: Int?
        for key in keys {
            guard let value = exactNonnegativeInteger(
                forJSONKey: key,
                in: bytes
            ) else {
                return nil
            }
            if key == "output_tokens" {
                outputTokens = value
            }
        }
        return outputTokens
    }

    private static func exactNonnegativeInteger(
        forJSONKey key: String,
        in bytes: [UInt8]
    ) -> Int? {
        let marker = [UInt8]("\"\(key)\"".utf8)
        guard marker.count <= bytes.count else { return nil }

        var markerIndex: Int?
        for index in 0 ... (bytes.count - marker.count)
        where bytes[index ..< index + marker.count].elementsEqual(marker) {
            guard markerIndex == nil else { return nil }
            markerIndex = index
        }
        guard var index = markerIndex.map({ $0 + marker.count }) else {
            return nil
        }

        while index < bytes.count, isJSONWhitespace(bytes[index]) {
            index += 1
        }
        guard index < bytes.count, bytes[index] == 0x3a else { return nil }
        index += 1
        while index < bytes.count, isJSONWhitespace(bytes[index]) {
            index += 1
        }

        let valueStart = index
        while index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) {
            index += 1
        }
        guard valueStart < index else { return nil }
        if index - valueStart > 1, bytes[valueStart] == 0x30 {
            return nil
        }
        let valueEnd = index
        while index < bytes.count, isJSONWhitespace(bytes[index]) {
            index += 1
        }
        guard
            index < bytes.count,
            bytes[index] == 0x2c || bytes[index] == 0x7d
        else {
            return nil
        }

        return Int(String(decoding: bytes[valueStart ..< valueEnd], as: UTF8.self))
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d
    }
}

private enum StrictQualificationResponseValidator {
    static func isValid(_ text: String) -> Bool {
        guard
            let data = text.data(using: .utf8),
            StrictJSONDocument.hasUniqueObjectKeys(data),
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
            markdown.unicodeScalars.count <= 160
        else {
            return false
        }
        return true
    }
}

enum SanitizedErrorClassifier {
    static func classify(
        standardErrorSignal: Data,
        structuredEventSignal: Data = Data()
    ) -> SanitizedFailureReason {
        if let structuredReason = structuredReason(from: structuredEventSignal) {
            return structuredReason
        }

        return reason(
            fromMessage: String(decoding: standardErrorSignal, as: UTF8.self)
        ) ?? .processFailure
    }

    private static func reason(fromMessage message: String) -> SanitizedFailureReason? {
        let signal = message.lowercased()

        if containsAny(
            signal,
            [
                "authentication",
                "unauthorized",
                "not logged in",
                "login required",
                "invalid api key",
                "status 401",
                "http 401",
                "access token could not be refreshed",
                "refresh token has expired",
                "please log out and sign in again",
            ]
        ) {
            return .authentication
        }
        if containsAny(
            signal,
            [
                "insufficient_quota",
                "quota",
                "billing",
                "usage limit",
                "credit balance",
                "workspace is out of credits",
                "spend cap",
                "usagenotincluded",
                "to use codex with your chatgpt plan, upgrade to plus",
            ]
        ) {
            return .quota
        }
        if containsAny(
            signal,
            ["model_not_found", "model not found", "model is not available", "unavailable model", "unsupported model", "unknown model", "does not exist"]
        ) {
            return .unavailableModel
        }
        if containsTransientHTTPStatus(signal) {
            return .transient
        }
        if containsAny(
            signal,
            [
                "rate limit",
                "timed out",
                "timeout",
                "connection reset",
                "connection refused",
                "connection failed:",
                "error while reading the server response",
                "selected model is at capacity",
                "stream disconnected before completion",
                "codex is experiencing high demand",
                "temporary errors",
                "temporarily unavailable",
                "server error",
            ]
        ) {
            return .transient
        }
        if containsAny(
            signal,
            ["output schema", "invalid json", "malformed output", "structured output"]
        ) {
            return .malformedOutput
        }
        return nil
    }

    private static func containsTransientHTTPStatus(_ signal: String) -> Bool {
        let bytes = Array(signal.utf8)
        for marker in [Array("status".utf8), Array("http".utf8)] {
            guard bytes.count >= marker.count else { continue }
            for start in 0 ... (bytes.count - marker.count) {
                if start > 0, isASCIILetterOrDigit(bytes[start - 1]) {
                    continue
                }
                guard bytes[start ..< start + marker.count].elementsEqual(marker) else {
                    continue
                }

                var cursor = start + marker.count
                guard cursor < bytes.count, isStatusSeparator(bytes[cursor]) else {
                    continue
                }
                while cursor < bytes.count, isStatusSeparator(bytes[cursor]) {
                    cursor += 1
                }
                guard cursor + 3 <= bytes.count else { continue }
                let digits = bytes[cursor ..< cursor + 3]
                guard digits.allSatisfy({ (0x30 ... 0x39).contains($0) }) else {
                    continue
                }
                if cursor + 3 < bytes.count,
                   (0x30 ... 0x39).contains(bytes[cursor + 3]) {
                    continue
                }

                let status = Int(digits[digits.startIndex] - 0x30) * 100
                    + Int(digits[digits.index(after: digits.startIndex)] - 0x30) * 10
                    + Int(digits[digits.index(digits.startIndex, offsetBy: 2)] - 0x30)
                if status == 429 || (500 ... 599).contains(status) {
                    return true
                }
            }
        }
        return false
    }

    private static func isStatusSeparator(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x3a
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
            || (0x41 ... 0x5a).contains(byte)
            || (0x61 ... 0x7a).contains(byte)
    }

    private static func structuredReason(from data: Data) -> SanitizedFailureReason? {
        let stream = String(decoding: data, as: UTF8.self)
        var messageReason: SanitizedFailureReason?
        for line in stream.split(whereSeparator: \Character.isNewline) {
            guard
                let lineData = String(line).data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                continue
            }
            let nestedError = event["error"] as? [String: Any]
            let errorItem = event["item"] as? [String: Any]
            let eventType = event["type"] as? String
            guard
                ["error", "turn.failed"].contains(eventType)
                    || (eventType == "item.completed" && errorItem?["type"] as? String == "error")
            else {
                continue
            }
            if let code = (
                nestedError?["code"]
                    ?? event["code"]
                    ?? (errorItem?["type"] as? String == "error" ? errorItem?["code"] : nil)
            ) as? String,
               let codeReason = reason(fromCode: code) {
                return codeReason
            }

            if messageReason == nil,
               let message = (
                   nestedError?["message"]
                       ?? event["message"]
                       ?? (errorItem?["type"] as? String == "error"
                           ? errorItem?["message"]
                           : nil)
               ) as? String {
                messageReason = reason(fromMessage: message)
            }
        }
        return messageReason
    }

    private static func reason(fromCode code: String) -> SanitizedFailureReason? {
        switch code {
        case "authentication_error":
            return .authentication
        case "insufficient_quota":
            return .quota
        case "rate_limit_exceeded":
            return .transient
        case "model_not_found":
            return .unavailableModel
        case "invalid_output_schema":
            return .malformedOutput
        default:
            return nil
        }
    }

    private static func containsAny(_ signal: String, _ patterns: [String]) -> Bool {
        patterns.contains(where: signal.contains)
    }
}
