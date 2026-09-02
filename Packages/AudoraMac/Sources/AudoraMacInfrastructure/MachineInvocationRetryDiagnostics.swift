@_spi(InvocationInfrastructure) import AudoraApplication
import Darwin
import Foundation

@_spi(InvocationInfrastructure)
public struct InvocationRetryDiagnosticLogLimits: Equatable, Sendable {
    public static let production = InvocationRetryDiagnosticLogLimits(
        maximumTotalBytes: 100 * 1_024 * 1_024,
        maximumActiveFileBytes: 100 * 1_024 * 1_024,
        maximumQueuedEvents: 256
    )

    public let maximumTotalBytes: Int
    public let maximumActiveFileBytes: Int
    public let maximumQueuedEvents: Int

    public init(
        maximumTotalBytes: Int,
        maximumActiveFileBytes: Int,
        maximumQueuedEvents: Int
    ) {
        precondition(maximumTotalBytes > 0)
        precondition(maximumActiveFileBytes > 0)
        precondition(maximumActiveFileBytes <= maximumTotalBytes)
        precondition(maximumQueuedEvents > 0)
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumActiveFileBytes = maximumActiveFileBytes
        self.maximumQueuedEvents = maximumQueuedEvents
    }
}

@_spi(InvocationInfrastructure)
public protocol InvocationRetryDiagnosticDrainScheduling: Sendable {
    func schedule(_ operation: @escaping @Sendable () -> Void)
}

@_spi(InvocationInfrastructure)
public final class DispatchInvocationRetryDiagnosticDrainScheduler:
    @unchecked Sendable,
    InvocationRetryDiagnosticDrainScheduling
{
    private let queue: DispatchQueue

    public init(
        label: String = "com.audora.invocation-retry-diagnostics"
    ) {
        queue = DispatchQueue(label: label, qos: .utility)
    }

    public func schedule(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }
}

@_spi(InvocationInfrastructure)
public final class ApplicationSupportInvocationRetryDiagnostics:
    @unchecked Sendable,
    InvocationRetryDiagnostics
{
    private static let activeFileName = "invocation-retry-current.jsonl"

    private let directoryURL: URL
    private let limits: InvocationRetryDiagnosticLogLimits
    private let scheduler: any InvocationRetryDiagnosticDrainScheduling
    private let lock = NSLock()
    private var pending: [InvocationRetryDiagnosticEvent] = []
    private var drainIsScheduled = false

    public init(
        directoryURL: URL,
        limits: InvocationRetryDiagnosticLogLimits = .production,
        scheduler: any InvocationRetryDiagnosticDrainScheduling =
            DispatchInvocationRetryDiagnosticDrainScheduler()
    ) {
        self.directoryURL = directoryURL
        self.limits = limits
        self.scheduler = scheduler
        pending.reserveCapacity(limits.maximumQueuedEvents)
    }

    public func enqueue(_ event: InvocationRetryDiagnosticEvent) {
        var shouldSchedule = false
        lock.lock()
        if pending.count < limits.maximumQueuedEvents {
            pending.append(event)
            if !drainIsScheduled {
                drainIsScheduled = true
                shouldSchedule = true
            }
        }
        lock.unlock()

        if shouldSchedule {
            scheduler.schedule { [weak self] in self?.drain() }
        }
    }

    private func drain() {
        while true {
            let batch: [InvocationRetryDiagnosticEvent]
            lock.lock()
            if pending.isEmpty {
                drainIsScheduled = false
                lock.unlock()
                return
            }
            batch = pending
            pending.removeAll(keepingCapacity: true)
            lock.unlock()

            do {
                try append(batch)
            } catch {
                // Diagnostics are metadata-only best effort and never affect the
                // Invocation outcome that requested them.
            }
        }
    }

    private func append(_ events: [InvocationRetryDiagnosticEvent]) throws {
        let directory = try openLogDirectory()
        defer { Darwin.close(directory) }

        for event in events {
            let line = try Self.encodedLine(event)
            guard line.count <= limits.maximumActiveFileBytes,
                  line.count <= limits.maximumTotalBytes
            else { continue }
            guard try prepareForAppend(
                lineByteCount: line.count,
                under: directory
            ) else { continue }
            try append(line, under: directory)
        }
    }

    private struct LogFile {
        let name: String
        let byteCount: Int
        let archiveSequence: UInt64?

        var isActive: Bool { archiveSequence == nil }
    }

    private enum PersistenceError: Error {
        case unavailable
        case unsafeTarget
    }

    private func openLogDirectory() throws -> Int32 {
        guard directoryURL.isFileURL else { throw PersistenceError.unsafeTarget }
        let components = (directoryURL.path as NSString).pathComponents
        guard components.first == "/", components.count > 1 else {
            throw PersistenceError.unsafeTarget
        }
        var current = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else { throw PersistenceError.unavailable }

        for component in components.dropFirst() {
            guard Self.isSafePathComponent(component) else {
                Darwin.close(current)
                throw PersistenceError.unsafeTarget
            }
            var next = Self.openDirectory(named: component, under: current)
            if next < 0, errno == ENOENT {
                let creation = component.withCString {
                    Darwin.mkdirat(current, $0, 0o700)
                }
                guard creation == 0 || errno == EEXIST else {
                    Darwin.close(current)
                    throw PersistenceError.unavailable
                }
                next = Self.openDirectory(named: component, under: current)
            }
            guard next >= 0 else {
                Darwin.close(current)
                throw PersistenceError.unsafeTarget
            }
            var metadata = stat()
            guard fstat(next, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR
            else {
                Darwin.close(next)
                Darwin.close(current)
                throw PersistenceError.unsafeTarget
            }
            Darwin.close(current)
            current = next
        }
        return current
    }

    private static func openDirectory(
        named name: String,
        under parent: Int32
    ) -> Int32 {
        name.withCString { pointer in
            while true {
                let descriptor = Darwin.openat(
                    parent,
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                if descriptor < 0, errno == EINTR { continue }
                return descriptor
            }
        }
    }

    private static func isSafePathComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." &&
            !component.contains("/") && !component.contains("\0")
    }

    private func prepareForAppend(
        lineByteCount: Int,
        under directory: Int32
    ) throws -> Bool {
        var logs = try validatedLogFiles(under: directory)
        if let active = logs.first(where: \.isActive),
           try exceedsLimit(
               active.byteCount,
               adding: lineByteCount,
               limit: limits.maximumActiveFileBytes
           )
        {
            try rotate(active, among: logs, under: directory)
            logs = try validatedLogFiles(under: directory)
        }

        while try exceedsLimit(
            totalByteCount(of: logs),
            adding: lineByteCount,
            limit: limits.maximumTotalBytes
        )
        {
            guard let oldest = logs
                .filter({ !$0.isActive })
                .min(by: {
                    ($0.archiveSequence ?? 0) < ($1.archiveSequence ?? 0)
                })
            else { return false }
            try remove(oldest, under: directory)
            logs.removeAll { $0.name == oldest.name }
        }
        return true
    }

    private func exceedsLimit(
        _ current: Int,
        adding addition: Int,
        limit: Int
    ) throws -> Bool {
        let (total, overflow) = current.addingReportingOverflow(addition)
        guard !overflow else { throw PersistenceError.unsafeTarget }
        return total > limit
    }

    private func totalByteCount(of logs: [LogFile]) throws -> Int {
        try logs.reduce(0) { total, log in
            let (next, overflow) = total.addingReportingOverflow(log.byteCount)
            guard !overflow else { throw PersistenceError.unsafeTarget }
            return next
        }
    }

    private func rotate(
        _ active: LogFile,
        among logs: [LogFile],
        under directory: Int32
    ) throws {
        guard active.byteCount > 0 else { return }
        let descriptor = try openValidated(active, under: directory)
        defer { Darwin.close(descriptor) }
        guard try nameStillRefersTo(
            descriptor,
            named: active.name,
            under: directory
        ) else { throw PersistenceError.unsafeTarget }
        let highestSequence = logs.compactMap(\.archiveSequence).max() ?? 0
        let (nextSequence, overflow) = highestSequence.addingReportingOverflow(1)
        guard !overflow else { throw PersistenceError.unsafeTarget }
        let archiveName = String(
            format: "invocation-retry-%020llu.jsonl",
            nextSequence
        )
        let status = active.name.withCString { source in
            archiveName.withCString { destination in
                Darwin.renameatx_np(
                    directory,
                    source,
                    directory,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard status == 0 else { throw PersistenceError.unsafeTarget }
        guard try nameStillRefersTo(
            descriptor,
            named: archiveName,
            under: directory
        ) else { throw PersistenceError.unsafeTarget }
        try synchronize(directory)
    }

    private func remove(_ log: LogFile, under directory: Int32) throws {
        let descriptor = try openValidated(log, under: directory)
        defer { Darwin.close(descriptor) }
        var linked = stat()
        guard fstat(descriptor, &linked) == 0 else {
            throw PersistenceError.unavailable
        }
        guard try nameStillRefersTo(
            descriptor,
            named: log.name,
            under: directory
        ) else { throw PersistenceError.unsafeTarget }
        let status = log.name.withCString {
            Darwin.unlinkat(directory, $0, 0)
        }
        guard status == 0 else { throw PersistenceError.unsafeTarget }
        var unlinked = stat()
        guard fstat(descriptor, &unlinked) == 0,
              unlinked.st_dev == linked.st_dev,
              unlinked.st_ino == linked.st_ino,
              unlinked.st_size == linked.st_size,
              unlinked.st_nlink == 0
        else { throw PersistenceError.unsafeTarget }
        try synchronize(directory)
    }

    private func validatedLogFiles(under directory: Int32) throws -> [LogFile] {
        try entryNames(under: directory).compactMap { name in
            let sequence: UInt64?
            if name == Self.activeFileName {
                sequence = nil
            } else if let parsed = Self.archiveSequence(from: name) {
                sequence = parsed
            } else if name.hasPrefix("invocation-retry-"),
                      name.hasSuffix(".jsonl")
            {
                throw PersistenceError.unsafeTarget
            } else {
                return nil
            }
            let byteCount = try regularFileByteCount(
                named: name,
                under: directory
            )
            let log = LogFile(
                name: name,
                byteCount: byteCount,
                archiveSequence: sequence
            )
            try validate(log, under: directory)
            return log
        }
    }

    private func validate(_ log: LogFile, under directory: Int32) throws {
        let descriptor = try openValidated(log, under: directory)
        Darwin.close(descriptor)
    }

    private func openValidated(
        _ log: LogFile,
        under directory: Int32
    ) throws -> Int32 {
        let descriptor = log.name.withCString { pointer -> Int32 in
            while true {
                let result = Darwin.openat(
                    directory,
                    pointer,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard descriptor >= 0 else { throw PersistenceError.unsafeTarget }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) < UInt64(Int.max),
              Int(metadata.st_size) == log.byteCount
        else {
            Darwin.close(descriptor)
            throw PersistenceError.unsafeTarget
        }
        return descriptor
    }

    private func nameStillRefersTo(
        _ descriptor: Int32,
        named name: String,
        under directory: Int32
    ) throws -> Bool {
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0 else {
            throw PersistenceError.unavailable
        }
        let status = name.withCString {
            Darwin.fstatat(directory, $0, &named, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else { return false }
        return (opened.st_mode & S_IFMT) == S_IFREG &&
            opened.st_nlink == 1 &&
            (named.st_mode & S_IFMT) == S_IFREG &&
            named.st_nlink == 1 &&
            opened.st_dev == named.st_dev &&
            opened.st_ino == named.st_ino &&
            opened.st_size == named.st_size
    }

    private func regularFileByteCount(
        named name: String,
        under directory: Int32
    ) throws -> Int {
        var metadata = stat()
        let status = name.withCString {
            Darwin.fstatat(directory, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) < UInt64(Int.max)
        else { throw PersistenceError.unsafeTarget }
        return Int(metadata.st_size)
    }

    private func entryNames(under directory: Int32) throws -> [String] {
        let enumeration = Darwin.openat(
            directory,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumeration >= 0 else { throw PersistenceError.unavailable }
        guard let stream = fdopendir(enumeration) else {
            Darwin.close(enumeration)
            throw PersistenceError.unavailable
        }
        defer { closedir(stream) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(NAME_MAX) + 1
                ) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                names.append(name)
                guard names.count <= 1_024 else {
                    throw PersistenceError.unsafeTarget
                }
            }
            errno = 0
        }
        guard errno == 0 else { throw PersistenceError.unavailable }
        return names.sorted()
    }

    private func append(_ data: Data, under directory: Int32) throws {
        let descriptor = try openActiveFile(under: directory)
        var closeRequired = true
        defer { if closeRequired { Darwin.close(descriptor) } }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) < UInt64(Int.max),
              try !exceedsLimit(
                  Int(metadata.st_size),
                  adding: data.count,
                  limit: limits.maximumActiveFileBytes
              )
        else { throw PersistenceError.unsafeTarget }
        try write(data, to: descriptor)
        try synchronize(descriptor)
        guard Darwin.close(descriptor) == 0 else {
            closeRequired = false
            throw PersistenceError.unavailable
        }
        closeRequired = false
        try synchronize(directory)
    }

    private func openActiveFile(under directory: Int32) throws -> Int32 {
        let existing = Self.activeFileName.withCString { pointer -> Int32 in
            while true {
                let descriptor = Darwin.openat(
                    directory,
                    pointer,
                    O_WRONLY | O_APPEND | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                if descriptor < 0, errno == EINTR { continue }
                return descriptor
            }
        }
        if existing >= 0 { return existing }
        guard errno == ENOENT else { throw PersistenceError.unsafeTarget }
        let created = Self.activeFileName.withCString { pointer -> Int32 in
            while true {
                let descriptor = Darwin.openat(
                    directory,
                    pointer,
                    O_WRONLY | O_APPEND | O_NONBLOCK | O_CREAT | O_EXCL |
                        O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
                if descriptor < 0, errno == EINTR { continue }
                return descriptor
            }
        }
        guard created >= 0 else { throw PersistenceError.unsafeTarget }
        return created
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        let succeeded = data.withUnsafeBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard succeeded else { throw PersistenceError.unavailable }
    }

    private func synchronize(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw PersistenceError.unavailable
        }
    }

    private static func archiveSequence(from fileName: String) -> UInt64? {
        let prefix = "invocation-retry-"
        let suffix = ".jsonl"
        guard fileName.hasPrefix(prefix),
              fileName.hasSuffix(suffix),
              fileName != activeFileName
        else { return nil }
        let start = fileName.index(fileName.startIndex, offsetBy: prefix.count)
        let end = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
        let digits = fileName[start ..< end]
        guard digits.count == 20,
              digits.allSatisfy(\.isNumber)
        else { return nil }
        return UInt64(digits)
    }

    private static func encodedLine(
        _ event: InvocationRetryDiagnosticEvent
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(Envelope(event))
        data.append(0x0A)
        return data
    }

    private struct Envelope: Encodable {
        let schemaVersion: UInt32
        let invocationId: String
        let attemptId: String
        let occurredAt: String
        let reason: String
        let classification: String
        let disposition: String
        let attemptOrdinal: UInt8
        let retryNumber: UInt8
        let durationMilliseconds: UInt64
        let requestUtf8Bytes: Int
        let completeModelInputUtf8Bytes: Int
        let transcriptReadRequestUtf8Bytes: Int
        let transcriptReadResponseUtf8Bytes: Int
        let completeInputTokens: Int
        let inputCeilingTokens: Int
        let memoryUtf8Bytes: Int

        init(_ event: InvocationRetryDiagnosticEvent) {
            schemaVersion = 1
            invocationId = event.invocationID.rawValue
            attemptId = event.attemptID.rawValue
            occurredAt = event.occurredAt.rawValue
            reason = event.reason.rawValue
            classification = event.classification.rawValue
            disposition = event.disposition.rawValue
            attemptOrdinal = event.attemptOrdinal
            retryNumber = event.retryNumber
            durationMilliseconds = event.durationMilliseconds
            requestUtf8Bytes = event.context.requestUTF8Bytes
            completeModelInputUtf8Bytes = event.context.completeModelInputUTF8Bytes
            transcriptReadRequestUtf8Bytes =
                event.context.transcriptReadRequestUTF8Bytes
            transcriptReadResponseUtf8Bytes =
                event.context.transcriptReadResponseUTF8Bytes
            completeInputTokens = event.context.completeInputTokens
            inputCeilingTokens = event.context.inputCeilingTokens
            memoryUtf8Bytes = event.context.memoryUTF8Bytes
        }
    }
}

@_spi(InvocationInfrastructure)
public enum MachineInvocationRetryDiagnosticsFactory {
    private static let scheduler =
        DispatchInvocationRetryDiagnosticDrainScheduler()

    public static func live(
        fileManager: FileManager = .default
    ) -> any InvocationRetryDiagnostics {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return UnavailableMachineInvocationRetryDiagnostics()
        }
        return ApplicationSupportInvocationRetryDiagnostics(
            directoryURL: applicationSupport
                .appendingPathComponent("Audora", isDirectory: true)
                .appendingPathComponent(
                    "InvocationRetryDiagnostics",
                    isDirectory: true
                ),
            scheduler: scheduler
        )
    }
}

private struct UnavailableMachineInvocationRetryDiagnostics:
    InvocationRetryDiagnostics
{
    func enqueue(_ event: InvocationRetryDiagnosticEvent) {}
}
