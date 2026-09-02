@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
@_spi(InvocationInfrastructure) @testable import AudoraMacInfrastructure
import Darwin
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

    func testDrainKeepsTheExactEnvelopeForAPreInvocationRetryEvent() throws {
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

            diagnostics.enqueue(try preInvocationDiagnosticEvent())
            scheduler.runAll()

            let line = try XCTUnwrap(activeLogLines(in: logDirectory).first)
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
            XCTAssertTrue(rootObject["invocationId"] is NSNull)
            XCTAssertTrue(rootObject["attemptId"] is NSNull)
            XCTAssertTrue(rootObject["attemptOrdinal"] is NSNull)
            XCTAssertTrue(rootObject["retryNumber"] is NSNull)
            XCTAssertEqual(rootObject["reason"] as? String, "admissionCooldown")
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

    func testRelaunchRepairsATornFinalJSONLRecordBeforeAppending() throws {
        try withTemporaryDirectory { root in
            let logDirectory = root.appendingPathComponent(
                "diagnostics",
                isDirectory: true
            )
            let firstScheduler = HeldInvocationRetryDiagnosticDrainScheduler()
            let first = ApplicationSupportInvocationRetryDiagnostics(
                directoryURL: logDirectory,
                limits: InvocationRetryDiagnosticLogLimits(
                    maximumTotalBytes: 8_192,
                    maximumActiveFileBytes: 4_096,
                    maximumQueuedEvents: 4
                ),
                scheduler: firstScheduler
            )
            first.enqueue(try diagnosticEvent())
            firstScheduler.runAll()

            let active = logDirectory.appendingPathComponent(
                "invocation-retry-current.jsonl"
            )
            let handle = try FileHandle(forWritingTo: active)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(#"{"schemaVersion":1"#.utf8))
            try handle.close()

            let relaunchedScheduler = HeldInvocationRetryDiagnosticDrainScheduler()
            let relaunched = ApplicationSupportInvocationRetryDiagnostics(
                directoryURL: logDirectory,
                limits: InvocationRetryDiagnosticLogLimits(
                    maximumTotalBytes: 8_192,
                    maximumActiveFileBytes: 4_096,
                    maximumQueuedEvents: 4
                ),
                scheduler: relaunchedScheduler
            )
            relaunched.enqueue(try diagnosticEvent())
            relaunchedScheduler.runAll()

            let data = try Data(contentsOf: active)
            XCTAssertEqual(data.last, 0x0A)
            let lines = try activeLogLines(in: logDirectory)
            XCTAssertEqual(lines.count, 2)
            for line in lines {
                XCTAssertNoThrow(
                    try JSONSerialization.jsonObject(with: Data(line.utf8))
                )
            }
        }
    }

    func testPartialAppendFailureImmediatelyRestoresPriorCompleteJSONLBoundary()
        throws
    {
        try withTemporaryDirectory { root in
            let logDirectory = root.appendingPathComponent(
                "diagnostics",
                isDirectory: true
            )
            let seedScheduler = HeldInvocationRetryDiagnosticDrainScheduler()
            let seed = ApplicationSupportInvocationRetryDiagnostics(
                directoryURL: logDirectory,
                limits: InvocationRetryDiagnosticLogLimits(
                    maximumTotalBytes: 8_192,
                    maximumActiveFileBytes: 4_096,
                    maximumQueuedEvents: 4
                ),
                scheduler: seedScheduler
            )
            seed.enqueue(try diagnosticEvent())
            seedScheduler.runAll()

            let active = logDirectory.appendingPathComponent(
                "invocation-retry-current.jsonl"
            )
            let priorCompleteData = try Data(contentsOf: active)
            XCTAssertEqual(priorCompleteData.last, 0x0A)
            XCTAssertEqual(try activeLogLines(in: logDirectory).count, 1)

            let failingWrite = PartialThenFailInvocationRetryDiagnosticWrite()
            let scheduler = HeldInvocationRetryDiagnosticDrainScheduler()
            let diagnostics = ApplicationSupportInvocationRetryDiagnostics(
                directoryURL: logDirectory,
                limits: InvocationRetryDiagnosticLogLimits(
                    maximumTotalBytes: 8_192,
                    maximumActiveFileBytes: 4_096,
                    maximumQueuedEvents: 4
                ),
                scheduler: scheduler,
                writeOperation: { descriptor, buffer, byteCount in
                    failingWrite.write(
                        descriptor,
                        buffer: buffer,
                        byteCount: byteCount
                    )
                }
            )

            diagnostics.enqueue(try diagnosticEvent())
            scheduler.runAll()

            XCTAssertGreaterThan(failingWrite.successfulByteCount, 0)
            XCTAssertEqual(failingWrite.injectedFailureCount, 1)
            XCTAssertEqual(
                try Data(contentsOf: active),
                priorCompleteData,
                "a failed drain must not leave a partial record for a future drain"
            )
            let retainedLine = try XCTUnwrap(activeLogLines(in: logDirectory).first)
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(retainedLine.utf8))
            )
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

    func testSeparateAdaptersSerializeRotationWithinSharedByteCaps() throws {
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

            for iteration in 0 ..< 8 {
                let logDirectory = root.appendingPathComponent(
                    "shared-\(iteration)",
                    isDirectory: true
                )
                let limits = InvocationRetryDiagnosticLogLimits(
                    maximumTotalBytes: lineByteCount * 3 + 2,
                    maximumActiveFileBytes: lineByteCount + 1,
                    maximumQueuedEvents: 16
                )
                let seedScheduler = HeldInvocationRetryDiagnosticDrainScheduler()
                let seed = ApplicationSupportInvocationRetryDiagnostics(
                    directoryURL: logDirectory,
                    limits: limits,
                    scheduler: seedScheduler
                )
                seed.enqueue(try diagnosticEvent())
                seedScheduler.runAll()
                let firstScheduler = HeldInvocationRetryDiagnosticDrainScheduler()
                let secondScheduler = HeldInvocationRetryDiagnosticDrainScheduler()
                let first = ApplicationSupportInvocationRetryDiagnostics(
                    directoryURL: logDirectory,
                    limits: limits,
                    scheduler: firstScheduler
                )
                let second = ApplicationSupportInvocationRetryDiagnostics(
                    directoryURL: logDirectory,
                    limits: limits,
                    scheduler: secondScheduler
                )
                first.enqueue(try diagnosticEvent())
                second.enqueue(try diagnosticEvent())

                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    firstScheduler.runAll()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    secondScheduler.runAll()
                    group.leave()
                }
                XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

                let logs = try FileManager.default.contentsOfDirectory(
                    at: logDirectory,
                    includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
                let sizes = try logs.map {
                    try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                }
                XCTAssertTrue(
                    sizes.allSatisfy { $0 <= limits.maximumActiveFileBytes },
                    "iteration \(iteration)"
                )
                XCTAssertLessThanOrEqual(
                    sizes.reduce(0, +),
                    limits.maximumTotalBytes,
                    "iteration \(iteration)"
                )
                let lines = try allLogLines(in: logDirectory)
                XCTAssertEqual(lines.count, 3, "iteration \(iteration)")
                for line in lines {
                    XCTAssertNoThrow(
                        try JSONSerialization.jsonObject(with: Data(line.utf8)),
                        "iteration \(iteration)"
                    )
                }
            }
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

    func testDrainRefusesSymlinkHardLinkAndNonregularWriterLocks() throws {
        try withTemporaryDirectory { root in
            let sentinel = Data("outside lock target must remain unchanged".utf8)

            for kind in UnsafeActiveTarget.allCases {
                let target = root.appendingPathComponent(
                    "outside-lock-target-\(kind.rawValue)"
                )
                try sentinel.write(to: target)
                let logDirectory = root.appendingPathComponent(
                    "lock-\(kind.rawValue)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: logDirectory,
                    withIntermediateDirectories: false
                )
                let writerLock = logDirectory.appendingPathComponent(
                    ".invocation-retry-diagnostics.lock"
                )
                switch kind {
                case .symbolicLink:
                    try FileManager.default.createSymbolicLink(
                        at: writerLock,
                        withDestinationURL: target
                    )
                case .hardLink:
                    try FileManager.default.linkItem(at: target, to: writerLock)
                case .directory:
                    try FileManager.default.createDirectory(
                        at: writerLock,
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

                XCTAssertEqual(try Data(contentsOf: target), sentinel, kind.rawValue)
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: logDirectory.appendingPathComponent(
                            "invocation-retry-current.jsonl"
                        ).path
                    ),
                    kind.rawValue
                )
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

private final class PartialThenFailInvocationRetryDiagnosticWrite:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var callCount = 0
    private var writtenByteCount = 0
    private var failureCount = 0

    var successfulByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writtenByteCount
    }

    var injectedFailureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return failureCount
    }

    func write(
        _ descriptor: Int32,
        buffer: UnsafeRawPointer,
        byteCount: Int
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        if callCount == 1 {
            let result = Darwin.write(descriptor, buffer, min(17, byteCount))
            if result > 0 { writtenByteCount += result }
            return result
        }
        failureCount += 1
        errno = EIO
        return -1
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

private func preInvocationDiagnosticEvent() throws -> InvocationRetryDiagnosticEvent {
    InvocationRetryDiagnosticEvent(
        reason: .admissionCooldown,
        classification: .admissionRejected,
        disposition: .userRetryableFailure,
        invocationID: nil,
        attemptID: nil,
        attemptOrdinal: nil,
        retryNumber: nil,
        occurredAt: try UTCInstant("2026-08-30T12:00:00.000Z"),
        durationMilliseconds: 0,
        context: .unavailable
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

private func allLogLines(in directory: URL) throws -> [Substring] {
    let logs = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "jsonl" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    return try logs.flatMap { log in
        try XCTUnwrap(String(data: Data(contentsOf: log), encoding: .utf8))
            .split(separator: "\n")
    }
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
