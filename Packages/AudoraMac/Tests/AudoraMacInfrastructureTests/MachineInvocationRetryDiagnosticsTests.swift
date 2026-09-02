@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
@_spi(InvocationInfrastructure) @testable import AudoraMacInfrastructure
import Foundation
import XCTest

final class MachineInvocationRetryDiagnosticsTests: XCTestCase {
    func testDrainWritesOnlyTheExactMetadataEnvelopeKeys() throws {
        try withTemporaryDirectory { root in
            let scheduler = HeldInvocationRetryDiagnosticDrainScheduler()
            let logDirectory = root.appendingPathComponent(
                "diagnostics",
                isDirectory: true
            )
            let diagnostics = ApplicationSupportInvocationRetryDiagnostics(
                directoryURL: logDirectory,
                limits: InvocationRetryDiagnosticLogLimits(
                    maximumTotalBytes: 8_192,
                    maximumActiveFileBytes: 4_096,
                    maximumQueuedEvents: 4
                ),
                scheduler: scheduler
            )

            diagnostics.enqueue(try diagnosticEvent())

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: logDirectory.path),
                "enqueue must not perform filesystem work"
            )
            XCTAssertEqual(scheduler.scheduledCount, 1)
            scheduler.runAll()

            let active = logDirectory.appendingPathComponent(
                "invocation-retry-current.jsonl"
            )
            let line = try XCTUnwrap(
                String(data: Data(contentsOf: active), encoding: .utf8)?
                    .split(separator: "\n")
                    .first
            )
            let rootObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any]
            )
            XCTAssertEqual(Set(rootObject.keys), [
                "schemaVersion",
                "invocationId",
                "attemptId",
                "occurredAt",
                "reason",
                "classification",
                "disposition",
                "attemptOrdinal",
                "retryNumber",
                "durationMilliseconds",
                "requestUtf8Bytes",
                "completeModelInputUtf8Bytes",
                "transcriptReadRequestUtf8Bytes",
                "transcriptReadResponseUtf8Bytes",
                "completeInputTokens",
                "inputCeilingTokens",
                "memoryUtf8Bytes",
            ])
            XCTAssertEqual(rootObject["schemaVersion"] as? Int, 1)
            XCTAssertEqual(
                rootObject["invocationId"] as? String,
                "inv-20260830T120000000Z-5KMN"
            )
            XCTAssertEqual(
                rootObject["attemptId"] as? String,
                "atm-20260830T120000000Z-6NPQ"
            )
            XCTAssertEqual(
                rootObject["reason"] as? String,
                "publicationPersistenceUnavailable"
            )
            XCTAssertEqual(
                rootObject["classification"] as? String,
                "persistenceUnavailable"
            )
            XCTAssertEqual(
                rootObject["disposition"] as? String,
                "userRetryableFailure"
            )
            XCTAssertEqual(rootObject["memoryUtf8Bytes"] as? Int, 89)
        }
    }

    func testDrainRotatesAndPrunesBeforeActiveOrTotalByteCaps() throws {
        try withTemporaryDirectory { root in
            let probeDirectory = root.appendingPathComponent(
                "probe",
                isDirectory: true
            )
            let probeScheduler = HeldInvocationRetryDiagnosticDrainScheduler()
            let probe = ApplicationSupportInvocationRetryDiagnostics(
                directoryURL: probeDirectory,
                limits: InvocationRetryDiagnosticLogLimits(
                    maximumTotalBytes: 8_192,
                    maximumActiveFileBytes: 4_096,
                    maximumQueuedEvents: 4
                ),
                scheduler: probeScheduler
            )
            probe.enqueue(try diagnosticEvent())
            probeScheduler.runAll()
            let lineByteCount = try Data(
                contentsOf: probeDirectory.appendingPathComponent(
                    "invocation-retry-current.jsonl"
                )
            ).count

            let logDirectory = root.appendingPathComponent(
                "rotating",
                isDirectory: true
            )
            let scheduler = HeldInvocationRetryDiagnosticDrainScheduler()
            let diagnostics = ApplicationSupportInvocationRetryDiagnostics(
                directoryURL: logDirectory,
                limits: InvocationRetryDiagnosticLogLimits(
                    maximumTotalBytes: lineByteCount * 2 + 1,
                    maximumActiveFileBytes: lineByteCount + 1,
                    maximumQueuedEvents: 8
                ),
                scheduler: scheduler
            )
            for _ in 0 ..< 4 {
                diagnostics.enqueue(try diagnosticEvent())
            }
            XCTAssertEqual(scheduler.scheduledCount, 1)
            scheduler.runAll()

            let logs = try FileManager.default.contentsOfDirectory(
                at: logDirectory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            let sizes = try logs.map {
                try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            }
            XCTAssertEqual(logs.count, 2)
            XCTAssertTrue(
                logs.contains {
                    $0.lastPathComponent.hasPrefix("invocation-retry-") &&
                        $0.lastPathComponent !=
                        "invocation-retry-current.jsonl"
                }
            )
            XCTAssertTrue(sizes.allSatisfy { $0 <= lineByteCount + 1 })
            XCTAssertLessThanOrEqual(
                sizes.reduce(0, +),
                lineByteCount * 2 + 1
            )
        }
    }

    func testRelaunchAppendsToTheExistingActiveLog() throws {
        try withTemporaryDirectory { root in
            let logDirectory = root.appendingPathComponent(
                "diagnostics",
                isDirectory: true
            )
            for _ in 0 ..< 2 {
                let scheduler = HeldInvocationRetryDiagnosticDrainScheduler()
                let diagnostics = ApplicationSupportInvocationRetryDiagnostics(
                    directoryURL: logDirectory,
                    limits: InvocationRetryDiagnosticLogLimits(
                        maximumTotalBytes: 8_192,
                        maximumActiveFileBytes: 4_096,
                        maximumQueuedEvents: 4
                    ),
                    scheduler: scheduler
                )
                diagnostics.enqueue(try diagnosticEvent())
                scheduler.runAll()
            }

            XCTAssertEqual(try activeLogLines(in: logDirectory).count, 2)
        }
    }

    func testEnqueueIsBoundedAndSchedulesOnlyOneBackgroundDrain() throws {
        try withTemporaryDirectory { root in
            let logDirectory = root.appendingPathComponent(
                "diagnostics",
                isDirectory: true
            )
            let scheduler = HeldInvocationRetryDiagnosticDrainScheduler()
            let diagnostics = ApplicationSupportInvocationRetryDiagnostics(
                directoryURL: logDirectory,
                limits: InvocationRetryDiagnosticLogLimits(
                    maximumTotalBytes: 8_192,
                    maximumActiveFileBytes: 4_096,
                    maximumQueuedEvents: 2
                ),
                scheduler: scheduler
            )

            for _ in 0 ..< 4 {
                diagnostics.enqueue(try diagnosticEvent())
            }

            XCTAssertEqual(scheduler.scheduledCount, 1)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: logDirectory.path),
                "even a full queue must not perform durable work in enqueue"
            )
            scheduler.runAll()
            XCTAssertEqual(try activeLogLines(in: logDirectory).count, 2)
        }
    }

    func testDrainRefusesSymlinkHardLinkAndNonregularActiveTargets() throws {
        try withTemporaryDirectory { root in
            let sentinel = Data("outside must remain unchanged".utf8)

            for kind in UnsafeActiveTarget.allCases {
                let target = root.appendingPathComponent(
                    "outside-target-\(kind.rawValue)"
                )
                try sentinel.write(to: target)
                let logDirectory = root.appendingPathComponent(
                    kind.rawValue,
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: logDirectory,
                    withIntermediateDirectories: false
                )
                let active = logDirectory.appendingPathComponent(
                    "invocation-retry-current.jsonl"
                )
                switch kind {
                case .symbolicLink:
                    try FileManager.default.createSymbolicLink(
                        at: active,
                        withDestinationURL: target
                    )
                case .hardLink:
                    try FileManager.default.linkItem(at: target, to: active)
                case .directory:
                    try FileManager.default.createDirectory(
                        at: active,
                        withIntermediateDirectories: false
                    )
                }

                let scheduler = HeldInvocationRetryDiagnosticDrainScheduler()
                let diagnostics = ApplicationSupportInvocationRetryDiagnostics(
                    directoryURL: logDirectory,
                    limits: InvocationRetryDiagnosticLogLimits(
                        maximumTotalBytes: 8_192,
                        maximumActiveFileBytes: 4_096,
                        maximumQueuedEvents: 4
                    ),
                    scheduler: scheduler
                )
                diagnostics.enqueue(try diagnosticEvent())
                scheduler.runAll()

                XCTAssertEqual(
                    try Data(contentsOf: target),
                    sentinel,
                    kind.rawValue
                )
                let values = try active.resourceValues(
                    forKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                    ]
                )
                switch kind {
                case .symbolicLink:
                    XCTAssertEqual(values.isSymbolicLink, true)
                case .hardLink:
                    XCTAssertEqual(try Data(contentsOf: active), sentinel)
                case .directory:
                    XCTAssertEqual(values.isDirectory, true)
                }
            }
        }
    }

    func testDrainRefusesASymlinkedParentWithoutCreatingOutsideIt() throws {
        try withTemporaryDirectory { root in
            let outside = root.appendingPathComponent(
                "outside",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: outside,
                withIntermediateDirectories: false
            )
            let linkedParent = root.appendingPathComponent(
                "linked-parent",
                isDirectory: true
            )
            try FileManager.default.createSymbolicLink(
                at: linkedParent,
                withDestinationURL: outside
            )
            let logDirectory = linkedParent.appendingPathComponent(
                "diagnostics",
                isDirectory: true
            )
            let scheduler = HeldInvocationRetryDiagnosticDrainScheduler()
            let diagnostics = ApplicationSupportInvocationRetryDiagnostics(
                directoryURL: logDirectory,
                limits: InvocationRetryDiagnosticLogLimits(
                    maximumTotalBytes: 8_192,
                    maximumActiveFileBytes: 4_096,
                    maximumQueuedEvents: 4
                ),
                scheduler: scheduler
            )

            diagnostics.enqueue(try diagnosticEvent())
            scheduler.runAll()

            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: outside.path),
                [],
                "a symlinked path component must never redirect durable work"
            )
        }
    }

    func testDrainRefusesASymlinkedFinalDirectory() throws {
        try withTemporaryDirectory { root in
            let outside = root.appendingPathComponent(
                "outside",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: outside,
                withIntermediateDirectories: false
            )
            let logDirectory = root.appendingPathComponent(
                "diagnostics",
                isDirectory: true
            )
            try FileManager.default.createSymbolicLink(
                at: logDirectory,
                withDestinationURL: outside
            )
            let scheduler = HeldInvocationRetryDiagnosticDrainScheduler()
            let diagnostics = ApplicationSupportInvocationRetryDiagnostics(
                directoryURL: logDirectory,
                limits: InvocationRetryDiagnosticLogLimits(
                    maximumTotalBytes: 8_192,
                    maximumActiveFileBytes: 4_096,
                    maximumQueuedEvents: 4
                ),
                scheduler: scheduler
            )

            diagnostics.enqueue(try diagnosticEvent())
            scheduler.runAll()

            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: outside.path),
                [],
                "the final directory must not redirect durable work"
            )
        }
    }
}

private enum UnsafeActiveTarget: String, CaseIterable {
    case symbolicLink
    case hardLink
    case directory
}

private final class HeldInvocationRetryDiagnosticDrainScheduler:
    @unchecked Sendable,
    InvocationRetryDiagnosticDrainScheduling
{
    private let lock = NSLock()
    private var operations: [@Sendable () -> Void] = []

    var scheduledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return operations.count
    }

    func schedule(_ operation: @escaping @Sendable () -> Void) {
        lock.lock()
        operations.append(operation)
        lock.unlock()
    }

    func runAll() {
        while true {
            let operation: (@Sendable () -> Void)?
            lock.lock()
            operation = operations.isEmpty ? nil : operations.removeFirst()
            lock.unlock()
            guard let operation else { return }
            operation()
        }
    }
}

private func diagnosticEvent() throws -> InvocationRetryDiagnosticEvent {
    InvocationRetryDiagnosticEvent(
        reason: .publicationPersistenceUnavailable,
        classification: .persistenceUnavailable,
        disposition: .userRetryableFailure,
        invocationID: try CoachInvocationID(
            "inv-20260830T120000000Z-5KMN"
        ),
        attemptID: try CoachProviderAttemptID(
            "atm-20260830T120000000Z-6NPQ"
        ),
        attemptOrdinal: 2,
        retryNumber: 2,
        occurredAt: try UTCInstant("2026-08-30T12:00:00.000Z"),
        durationMilliseconds: 37,
        context: InvocationRetryDiagnosticContext(
            requestUTF8Bytes: 11,
            completeModelInputUTF8Bytes: 23,
            transcriptReadRequestUTF8Bytes: 31,
            transcriptReadResponseUTF8Bytes: 47,
            completeInputTokens: 53,
            inputCeilingTokens: 67,
            memoryUTF8Bytes: 89
        )
    )
}

private func activeLogLines(in directory: URL) throws -> [Substring] {
    let data = try Data(
        contentsOf: directory.appendingPathComponent(
            "invocation-retry-current.jsonl"
        )
    )
    return try XCTUnwrap(String(data: data, encoding: .utf8))
        .split(separator: "\n")
}

private func withTemporaryDirectory(
    _ operation: (URL) throws -> Void
) throws {
    let requestedRoot = URL(
        fileURLWithPath: "/private/tmp",
        isDirectory: true
    ).appendingPathComponent(
        "audora-invocation-diagnostics-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: requestedRoot,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: requestedRoot) }
    try operation(requestedRoot)
}
