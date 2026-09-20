import Darwin
import Foundation

enum BoundedProcessStopReason: Equatable, Sendable {
    case standardOutputLimit
    case standardErrorLimit
    case ioFailure
    case cancelled
    case timedOut
}

struct BoundedProcessRequest: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let executableURL: URL
    let executableArtifact: CodexCLIExecutableArtifact?
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryURL: URL
    let standardInput: Data
    let standardOutputByteCeiling: Int
    let standardErrorByteCeiling: Int
    let timeoutSeconds: TimeInterval
    let cancelAfterSeconds: TimeInterval?
    let terminationGraceSeconds: TimeInterval

    init(
        executableURL: URL,
        executableArtifact: CodexCLIExecutableArtifact? = nil,
        arguments: [String],
        environment: [String: String],
        workingDirectoryURL: URL,
        standardInput: Data,
        standardOutputByteCeiling: Int,
        standardErrorByteCeiling: Int,
        timeoutSeconds: TimeInterval,
        cancelAfterSeconds: TimeInterval?,
        terminationGraceSeconds: TimeInterval
    ) {
        self.executableURL = executableURL
        self.executableArtifact = executableArtifact
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.standardInput = standardInput
        self.standardOutputByteCeiling = standardOutputByteCeiling
        self.standardErrorByteCeiling = standardErrorByteCeiling
        self.timeoutSeconds = timeoutSeconds
        self.cancelAfterSeconds = cancelAfterSeconds
        self.terminationGraceSeconds = terminationGraceSeconds
    }

    var description: String {
        "BoundedProcessRequest(executable: \(executableURL.lastPathComponent), " +
            "arguments: <redacted>, environment: <redacted>, " +
            "standardInput: <redacted>)"
    }

    var debugDescription: String { description }
}

struct BoundedProcessResult: Sendable {
    let launched: Bool
    let standardOutput: Data
    let standardError: Data
    let terminationTrigger: BoundedProcessStopReason?
    let stopReason: BoundedProcessStopReason?
    let standardInputWasWritten: Bool
    let exitedNormally: Bool
    let exitStatus: Int32
    let processGroupWasReaped: Bool
    let durationMilliseconds: Int
}

struct BoundedProcessHost: Sendable {
    private let monotonicNanoseconds: @Sendable () -> UInt64
    private let willSpawn: @Sendable () -> Void
    private let didSpawnSuspended: @Sendable (pid_t) -> Void

    init(
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        willSpawn: @escaping @Sendable () -> Void = {},
        didSpawnSuspended: @escaping @Sendable (pid_t) -> Void = { _ in }
    ) {
        self.monotonicNanoseconds = monotonicNanoseconds
        self.willSpawn = willSpawn
        self.didSpawnSuspended = didSpawnSuspended
    }

    func run(_ request: BoundedProcessRequest) -> BoundedProcessResult {
        precondition(request.standardOutputByteCeiling > 0)
        precondition(request.standardErrorByteCeiling > 0)
        precondition(request.timeoutSeconds.isFinite && request.timeoutSeconds > 0)
        precondition(
            request.terminationGraceSeconds.isFinite
                && request.terminationGraceSeconds >= 0
        )

        let startedAt = monotonicNanoseconds()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        guard let spawnedProcess = spawn(
            request,
            standardInput: inputPipe.fileHandleForReading.fileDescriptor,
            standardOutput: outputPipe.fileHandleForWriting.fileDescriptor,
            standardError: errorPipe.fileHandleForWriting.fileDescriptor,
            descriptorsClosedInChild: [
                inputPipe.fileHandleForReading.fileDescriptor,
                inputPipe.fileHandleForWriting.fileDescriptor,
                outputPipe.fileHandleForReading.fileDescriptor,
                outputPipe.fileHandleForWriting.fileDescriptor,
                errorPipe.fileHandleForReading.fileDescriptor,
                errorPipe.fileHandleForWriting.fileDescriptor,
            ]
        ) else {
            close(inputPipe)
            close(outputPipe)
            close(errorPipe)
            return BoundedProcessResult(
                launched: false,
                standardOutput: Data(),
                standardError: Data(),
                terminationTrigger: nil,
                stopReason: nil,
                standardInputWasWritten: false,
                exitedNormally: false,
                exitStatus: -1,
                processGroupWasReaped: true,
                durationMilliseconds: elapsedMilliseconds(since: startedAt)
            )
        }
        let processID = spawnedProcess.processID
        let processTreeProof = BoundedProcessTreeProof(processID: processID)

        guard spawnedProcess.exactArtifactWasValidated else {
            close(inputPipe)
            close(outputPipe)
            close(errorPipe)
            var waitStatus: Int32?
            let rootAndProcessGroupWereReaped = terminateRemainingProcessGroup(
                processID,
                waitStatus: &waitStatus,
                graceSeconds: 0
            )
            processTreeProof.observePendingEvents()
            return BoundedProcessResult(
                launched: false,
                standardOutput: Data(),
                standardError: Data(),
                terminationTrigger: nil,
                stopReason: nil,
                standardInputWasWritten: false,
                exitedNormally: false,
                exitStatus: -1,
                // The child has never been resumed, so it cannot have forked;
                // reaping the root and its empty process group is complete proof.
                processGroupWasReaped: rootAndProcessGroupWereReaped,
                durationMilliseconds: elapsedMilliseconds(since: startedAt)
            )
        }

        inputPipe.fileHandleForReading.closeFile()
        outputPipe.fileHandleForWriting.closeFile()
        errorPipe.fileHandleForWriting.closeFile()

        let output = BoundedProcessByteCollector(
            limit: request.standardOutputByteCeiling
        )
        let error = BoundedProcessByteCollector(
            limit: request.standardErrorByteCeiling
        )
        let transfers = DispatchGroup()
        let transferControl = BoundedProcessTransferControl()
        let inputStatus = BoundedProcessInputStatus()
        let inputHandle = inputPipe.fileHandleForWriting
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        let transferSetupSucceeded = setNonblocking(inputHandle.fileDescriptor)
            && fcntl(inputHandle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0
            && setNonblocking(outputHandle.fileDescriptor)
            && setNonblocking(errorHandle.fileDescriptor)
        if transferSetupSucceeded {
            startReader(
                outputHandle,
                collector: output,
                control: transferControl,
                group: transfers
            )
            startReader(
                errorHandle,
                collector: error,
                control: transferControl,
                group: transfers
            )
            startWriter(
                inputHandle,
                data: request.standardInput,
                status: inputStatus,
                control: transferControl,
                group: transfers
            )
        } else {
            inputHandle.closeFile()
            outputHandle.closeFile()
            errorHandle.closeFile()
        }
        let processResumed = kill(processID, SIGCONT) == 0
        if !processResumed {
            processTreeProof.invalidate()
        }

        var waitStatus: Int32?
        let stopReason = monitor(
            processID: processID,
            waitStatus: &waitStatus,
            processTreeProof: processTreeProof,
            output: output,
            error: error,
            request: request,
            startedAt: startedAt
        )
        let rootAndProcessGroupWereReaped = terminateRemainingProcessGroup(
            processID,
            waitStatus: &waitStatus,
            graceSeconds: request.terminationGraceSeconds
        )
        processTreeProof.observePendingEvents()
        let processGroupWasReaped = rootAndProcessGroupWereReaped
            && processTreeProof.reclamationCanBeProven

        let transfersFinishedNaturally = transfers.wait(
            timeout: .now() + 0.05
        ) == .success
        if !transfersFinishedNaturally {
            transferControl.requestStop()
        }
        let transfersStopped = transfersFinishedNaturally || transfers.wait(
            timeout: .now() + 0.5
        ) == .success
        let finalStopReason: BoundedProcessStopReason?
        if !processGroupWasReaped
            || !transferSetupSucceeded
            || !transfersFinishedNaturally
            || !transfersStopped {
            finalStopReason = .ioFailure
        } else {
            finalStopReason = stopReason
                ?? (output.didOverflow ? .standardOutputLimit : nil)
                ?? (error.didOverflow ? .standardErrorLimit : nil)
        }
        return BoundedProcessResult(
            launched: true,
            standardOutput: output.data,
            standardError: error.data,
            terminationTrigger: stopReason,
            stopReason: finalStopReason,
            standardInputWasWritten: inputStatus.wasFullyWritten,
            exitedNormally: waitStatus.map(exitedNormally) ?? false,
            exitStatus: waitStatus.map(exitStatus) ?? -1,
            processGroupWasReaped: processGroupWasReaped,
            durationMilliseconds: elapsedMilliseconds(since: startedAt)
        )
    }

    private struct SpawnedProcess {
        let processID: pid_t
        let exactArtifactWasValidated: Bool
    }

    private func spawn(
        _ request: BoundedProcessRequest,
        standardInput: Int32,
        standardOutput: Int32,
        standardError: Int32,
        descriptorsClosedInChild: [Int32]
    ) -> SpawnedProcess? {
        guard request.executableArtifact?.revalidate() != false else {
            return nil
        }
        willSpawn()
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            return nil
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        guard
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardInput,
                STDIN_FILENO
            ) == 0,
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardOutput,
                STDOUT_FILENO
            ) == 0,
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardError,
                STDERR_FILENO
            ) == 0,
            descriptorsClosedInChild.allSatisfy({
                posix_spawn_file_actions_addclose(&fileActions, $0) == 0
            }),
            addWorkingDirectoryAction(
                &fileActions,
                path: request.workingDirectoryURL.path
            ) == 0
        else {
            return nil
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            return nil
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETSID
            | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_START_SUSPENDED
        guard posix_spawnattr_setflags(&attributes, Int16(flags)) == 0 else {
            return nil
        }

        let argumentStrings = [request.executableURL.path] + request.arguments
        let environmentStrings = request.environment
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
        guard let arguments = duplicatedCStringArray(argumentStrings) else {
            return nil
        }
        defer { freeCStringArray(arguments) }
        guard let environment = duplicatedCStringArray(environmentStrings) else {
            return nil
        }
        defer { freeCStringArray(environment) }

        var mutableArguments = arguments
        var mutableEnvironment = environment
        var processID = pid_t()
        let result = request.executableURL.path.withCString { executable in
            mutableArguments.withUnsafeMutableBufferPointer { argumentBuffer in
                mutableEnvironment.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(
                        &processID,
                        executable,
                        &fileActions,
                        &attributes,
                        argumentBuffer.baseAddress,
                        environmentBuffer.baseAddress
                    )
                }
            }
        }
        guard result == 0 else { return nil }
        didSpawnSuspended(processID)
        return SpawnedProcess(
            processID: processID,
            exactArtifactWasValidated: request.executableArtifact?
                .revalidateLaunchedProcess(processID) != false
        )
    }

    private func addWorkingDirectoryAction(
        _ fileActions: inout posix_spawn_file_actions_t?,
        path: String
    ) -> Int32 {
        path.withCString { pathPointer in
            posix_spawn_file_actions_addchdir(&fileActions, pathPointer)
        }
    }

    private func monitor(
        processID: pid_t,
        waitStatus: inout Int32?,
        processTreeProof: BoundedProcessTreeProof,
        output: BoundedProcessByteCollector,
        error: BoundedProcessByteCollector,
        request: BoundedProcessRequest,
        startedAt: UInt64
    ) -> BoundedProcessStopReason? {
        let timeoutDeadline = deadline(
            after: request.timeoutSeconds,
            from: startedAt
        )
        let cancellationDeadline = request.cancelAfterSeconds.map {
            deadline(after: $0, from: startedAt)
        }
        while poll(processID, waitStatus: &waitStatus) {
            processTreeProof.observePendingEvents()
            if output.didOverflow {
                return .standardOutputLimit
            }
            if error.didOverflow {
                return .standardErrorLimit
            }
            let now = monotonicNanoseconds()
            if let cancellationDeadline, now >= cancellationDeadline {
                return .cancelled
            }
            if now >= timeoutDeadline {
                return .timedOut
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        processTreeProof.observePendingEvents()
        return nil
    }

    private func terminateRemainingProcessGroup(
        _ processID: pid_t,
        waitStatus: inout Int32?,
        graceSeconds: TimeInterval
    ) -> Bool {
        if waitStatus == nil || processGroupExists(processID) {
            if kill(-processID, SIGTERM) != 0, waitStatus == nil {
                _ = kill(processID, SIGTERM)
            }
        }

        let graceDeadline = deadline(after: graceSeconds)
        while poll(processID, waitStatus: &waitStatus) || processGroupExists(processID) {
            guard monotonicNanoseconds() < graceDeadline else { break }
            Thread.sleep(forTimeInterval: 0.01)
        }

        if processGroupExists(processID) {
            _ = kill(-processID, SIGKILL)
        }
        if waitStatus == nil {
            _ = kill(processID, SIGKILL)
        }

        let reapDeadline = deadline(after: 0.5)
        while waitStatus == nil || processGroupExists(processID) {
            if waitStatus == nil {
                _ = poll(processID, waitStatus: &waitStatus)
            }
            if waitStatus != nil, !processGroupExists(processID) {
                break
            }
            guard monotonicNanoseconds() < reapDeadline else { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return waitStatus != nil && !processGroupExists(processID)
    }

    private func poll(_ processID: pid_t, waitStatus: inout Int32?) -> Bool {
        guard waitStatus == nil else { return false }

        var status = Int32()
        let result = waitpid(processID, &status, WNOHANG)
        if result == processID {
            waitStatus = status
            return false
        }
        return result == 0 || (result == -1 && errno == EINTR)
    }

    private func processGroupExists(_ processGroupID: pid_t) -> Bool {
        if kill(-processGroupID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func exitedNormally(_ status: Int32) -> Bool {
        status & 0x7f == 0
    }

    private func exitStatus(_ status: Int32) -> Int32 {
        exitedNormally(status) ? (status >> 8) & 0xff : status & 0x7f
    }

    private func duplicatedCStringArray(
        _ strings: [String]
    ) -> [UnsafeMutablePointer<CChar>?]? {
        guard strings.allSatisfy({ !$0.utf8.contains(0) }) else {
            return nil
        }
        var result: [UnsafeMutablePointer<CChar>?] = []
        result.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let duplicate = strdup(string) else {
                freeCStringArray(result)
                return nil
            }
            result.append(duplicate)
        }
        result.append(nil)
        return result
    }

    private func freeCStringArray(_ strings: [UnsafeMutablePointer<CChar>?]) {
        for case let string? in strings {
            free(string)
        }
    }

    private func startReader(
        _ handle: FileHandle,
        collector: BoundedProcessByteCollector,
        control: BoundedProcessTransferControl,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                handle.closeFile()
                group.leave()
            }
            var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
            while true {
                if control.shouldStop { return }
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(
                        handle.fileDescriptor,
                        bytes.baseAddress,
                        bytes.count
                    )
                }
                if count > 0 {
                    collector.append(Data(buffer.prefix(count)))
                } else if count == 0 {
                    return
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    if control.shouldStop { return }
                    Thread.sleep(forTimeInterval: 0.005)
                } else {
                    return
                }
            }
        }
    }

    private func startWriter(
        _ handle: FileHandle,
        data: Data,
        status: BoundedProcessInputStatus,
        control: BoundedProcessTransferControl,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                handle.closeFile()
                group.leave()
            }
            guard !data.isEmpty else {
                status.markFullyWritten()
                return
            }
            let wasFullyWritten = data.withUnsafeBytes { bytes -> Bool in
                guard let baseAddress = bytes.baseAddress else { return false }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        handle.fileDescriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written > 0 {
                        offset += written
                    } else if written == -1, errno == EINTR {
                        continue
                    } else if written == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                        if control.shouldStop { return false }
                        Thread.sleep(forTimeInterval: 0.005)
                    } else {
                        return false
                    }
                }
                return true
            }
            if wasFullyWritten {
                status.markFullyWritten()
            }
        }
    }

    private func close(_ pipe: Pipe) {
        pipe.fileHandleForReading.closeFile()
        pipe.fileHandleForWriting.closeFile()
    }

    private func setNonblocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private func deadline(
        after seconds: TimeInterval,
        from start: UInt64? = nil
    ) -> UInt64 {
        let origin = start ?? monotonicNanoseconds()
        let maximumSeconds = Double(UInt64.max) / 1_000_000_000
        let intervalNanoseconds = seconds >= maximumSeconds
            ? UInt64.max
            : UInt64((seconds * 1_000_000_000).rounded(.up))
        let (value, overflow) = origin.addingReportingOverflow(intervalNanoseconds)
        return overflow ? UInt64.max : value
    }

    private func elapsedMilliseconds(since start: UInt64) -> Int {
        let now = monotonicNanoseconds()
        guard now >= start else { return 0 }
        let milliseconds = (now - start) / 1_000_000
        return milliseconds > UInt64(Int.max) ? Int.max : Int(milliseconds)
    }
}

private final class BoundedProcessTreeProof {
    private let queueDescriptor: Int32
    private var trackingSucceeded: Bool
    private var forkWasObserved = false

    init(processID: pid_t) {
        queueDescriptor = kqueue()
        guard queueDescriptor >= 0 else {
            trackingSucceeded = false
            return
        }

        var change = kevent64_s()
        change.ident = UInt64(processID)
        change.filter = Int16(EVFILT_PROC)
        change.flags = UInt16(EV_ADD | EV_CLEAR)
        change.fflags = UInt32(bitPattern: NOTE_FORK) | NOTE_EXIT
        trackingSucceeded = Darwin.kevent64(
            queueDescriptor,
            &change,
            1,
            nil,
            0,
            0,
            nil
        ) == 0
    }

    deinit {
        if queueDescriptor >= 0 {
            _ = Darwin.close(queueDescriptor)
        }
    }

    var reclamationCanBeProven: Bool {
        trackingSucceeded && !forkWasObserved
    }

    func invalidate() {
        trackingSucceeded = false
    }

    func observePendingEvents() {
        guard trackingSucceeded else { return }
        var event = kevent64_s()
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        while true {
            let eventCount = Darwin.kevent64(
                queueDescriptor,
                nil,
                0,
                &event,
                1,
                0,
                &timeout
            )
            if eventCount == 0 {
                return
            }
            if eventCount < 0 {
                if errno == EINTR { continue }
                trackingSucceeded = false
                return
            }
            if event.flags & UInt16(EV_ERROR) != 0 {
                trackingSucceeded = false
                return
            }
            if event.fflags & UInt32(NOTE_FORK) != 0 {
                forkWasObserved = true
            }
        }
    }
}

private final class BoundedProcessTransferControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func requestStop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

private final class BoundedProcessInputStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var fullyWritten = false

    var wasFullyWritten: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fullyWritten
    }

    func markFullyWritten() {
        lock.lock()
        fullyWritten = true
        lock.unlock()
    }
}

private final class BoundedProcessByteCollector: @unchecked Sendable {
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
        storage.append(data.prefix(remaining))
        if data.count > remaining {
            overflow = true
        }
    }
}
