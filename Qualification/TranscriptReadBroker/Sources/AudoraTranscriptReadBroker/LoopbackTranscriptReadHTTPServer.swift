import AudoraApplication
import AudoraCodexCLIQualification
import Darwin
import Foundation

public enum LoopbackTranscriptReadServerError: Error, Equatable, Sendable {
    case invalidConfiguration
    case listenerFailed
}

public enum LoopbackTranscriptReadHTTPClosedReason: String, Equatable, Sendable {
    case headerTooLarge
    case invalidRequestLine
    case invalidHeader
    case unsupportedTransferEncoding
    case missingRequiredHeader
    case invalidContentLength
    case bodySmuggling
    case bodyTimedOut
}

struct LoopbackTranscriptReadServerTestHooks: Sendable {
    let acceptedBeforeRegistration: (@Sendable (Int32) -> Void)?
    let acceptedBeforeReceive: (@Sendable (Int32) -> Void)?
    let transportDidMarkStopped: (@Sendable () -> Void)?
    let acceptLoopFinished: (@Sendable () -> Void)?
    let connectionWorkerFinished: (@Sendable (Int32) -> Void)?
    let descriptorWillBeUsed: (@Sendable (Int32) -> Void)?

    init(
        acceptedBeforeRegistration: (@Sendable (Int32) -> Void)? = nil,
        acceptedBeforeReceive: (@Sendable (Int32) -> Void)? = nil,
        transportDidMarkStopped: (@Sendable () -> Void)? = nil,
        acceptLoopFinished: (@Sendable () -> Void)? = nil,
        connectionWorkerFinished: (@Sendable (Int32) -> Void)? = nil,
        descriptorWillBeUsed: (@Sendable (Int32) -> Void)? = nil
    ) {
        self.acceptedBeforeRegistration = acceptedBeforeRegistration
        self.acceptedBeforeReceive = acceptedBeforeReceive
        self.transportDidMarkStopped = transportDidMarkStopped
        self.acceptLoopFinished = acceptLoopFinished
        self.connectionWorkerFinished = connectionWorkerFinished
        self.descriptorWillBeUsed = descriptorWillBeUsed
    }

    static let none = LoopbackTranscriptReadServerTestHooks()
}

/// Attempt-owned loopback listener for the strict MCP boundary.
///
/// It accepts one bounded HTTP/1.1 request per connection, never redirects,
/// never emits CORS headers, and closes the listening endpoint whenever the MCP
/// boundary reaches a terminal state.
public final class LoopbackTranscriptReadHTTPServer: @unchecked Sendable {
    private static let maximumAllowedBodyBytes = 1 * 1_024 * 1_024
    private static let maximumAllowedHeaderBytes = 64 * 1_024
    private static let maximumAllowedRequestTimeout: Duration = .seconds(30)
    private static let acceptPollMilliseconds: Int32 = 10

    public let host = "127.0.0.1"
    public let port: UInt16

    public var endpointURL: URL {
        URL(string: "http://127.0.0.1:\(port)/mcp")!
    }

    private let listener: SerializedSocket
    private let queue: DispatchQueue
    private let boundary: TranscriptReadMCPBoundary
    private let maximumBodyBytes: Int
    private let maximumHeaderBytes: Int
    private let maximumCollectedBytes: Int
    private let maximumReadCapacity: Int
    private let requestTimeout: Duration
    private let maximumConnections: Int
    private let testHooks: LoopbackTranscriptReadServerTestHooks
    private let stateLock = NSLock()
    private var stopped = false
    private var connections: [ObjectIdentifier: SerializedSocket] = [:]
    private var httpClosedReason: LoopbackTranscriptReadHTTPClosedReason?

    private init(
        listener: SerializedSocket,
        port: UInt16,
        grant: AttemptTranscriptGrant,
        maximumBodyBytes: Int,
        maximumHeaderBytes: Int,
        maximumCollectedBytes: Int,
        maximumReadCapacity: Int,
        requestTimeout: Duration,
        maximumConnections: Int,
        testHooks: LoopbackTranscriptReadServerTestHooks
    ) {
        self.listener = listener
        self.port = port
        self.maximumBodyBytes = maximumBodyBytes
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumCollectedBytes = maximumCollectedBytes
        self.maximumReadCapacity = maximumReadCapacity
        self.requestTimeout = requestTimeout
        self.maximumConnections = maximumConnections
        self.testHooks = testHooks
        queue = DispatchQueue(label: "audora.transcript-read.loopback")
        boundary = grant.makeMCPBoundary(
            expectedAuthority: "127.0.0.1:\(port)",
            maximumBodyBytes: maximumBodyBytes
        )
    }

    deinit {
        closeTransport()
    }

    public static func start(
        grant: AttemptTranscriptGrant,
        maximumBodyBytes: Int = 32 * 1_024,
        maximumHeaderBytes: Int = 16 * 1_024,
        requestTimeout: Duration = .seconds(2),
        maximumConnections: Int = 8
    ) async throws -> LoopbackTranscriptReadHTTPServer {
        try startConfigured(
            grant: grant,
            maximumBodyBytes: maximumBodyBytes,
            maximumHeaderBytes: maximumHeaderBytes,
            requestTimeout: requestTimeout,
            maximumConnections: maximumConnections,
            testHooks: .none
        )
    }

    static func startForTesting(
        grant: AttemptTranscriptGrant,
        maximumBodyBytes: Int = 32 * 1_024,
        maximumHeaderBytes: Int = 16 * 1_024,
        requestTimeout: Duration = .seconds(2),
        maximumConnections: Int = 8,
        testHooks: LoopbackTranscriptReadServerTestHooks
    ) throws -> LoopbackTranscriptReadHTTPServer {
        try startConfigured(
            grant: grant,
            maximumBodyBytes: maximumBodyBytes,
            maximumHeaderBytes: maximumHeaderBytes,
            requestTimeout: requestTimeout,
            maximumConnections: maximumConnections,
            testHooks: testHooks
        )
    }

    private static func startConfigured(
        grant: AttemptTranscriptGrant,
        maximumBodyBytes: Int,
        maximumHeaderBytes: Int,
        requestTimeout: Duration,
        maximumConnections: Int,
        testHooks: LoopbackTranscriptReadServerTestHooks
    ) throws -> LoopbackTranscriptReadHTTPServer {
        let headerWithSeparator = maximumHeaderBytes.addingReportingOverflow(4)
        let maximumRequest = headerWithSeparator.partialValue.addingReportingOverflow(
            maximumBodyBytes
        )
        let maximumRead = maximumRequest.partialValue.addingReportingOverflow(1)
        guard maximumBodyBytes > 0,
              maximumBodyBytes <= maximumAllowedBodyBytes,
              maximumHeaderBytes > 0,
              maximumHeaderBytes <= maximumAllowedHeaderBytes,
              requestTimeout > .zero,
              requestTimeout <= maximumAllowedRequestTimeout,
              maximumConnections > 0,
              let listenBacklog = Int32(exactly: maximumConnections),
              !headerWithSeparator.overflow,
              !maximumRequest.overflow,
              !maximumRead.overflow
        else {
            throw LoopbackTranscriptReadServerError.invalidConfiguration
        }

        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw LoopbackTranscriptReadServerError.listenerFailed
        }
        var shouldClose = true
        defer {
            if shouldClose {
                Darwin.close(descriptor)
            }
        }
        guard setCloseOnExec(descriptor), setNonblocking(descriptor) else {
            throw LoopbackTranscriptReadServerError.listenerFailed
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0,
              Darwin.listen(descriptor, listenBacklog) == 0
        else {
            throw LoopbackTranscriptReadServerError.listenerFailed
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(descriptor, socketAddress, &boundLength)
            }
        }
        guard nameResult == 0,
              boundAddress.sin_addr.s_addr == inet_addr("127.0.0.1")
        else {
            throw LoopbackTranscriptReadServerError.listenerFailed
        }

        let listener = SerializedSocket(
            descriptor: descriptor,
            operationObserver: testHooks.descriptorWillBeUsed
        )
        let server = LoopbackTranscriptReadHTTPServer(
            listener: listener,
            port: UInt16(bigEndian: boundAddress.sin_port),
            grant: grant,
            maximumBodyBytes: maximumBodyBytes,
            maximumHeaderBytes: maximumHeaderBytes,
            maximumCollectedBytes: maximumRequest.partialValue,
            maximumReadCapacity: maximumRead.partialValue,
            requestTimeout: requestTimeout,
            maximumConnections: maximumConnections,
            testHooks: testHooks
        )
        shouldClose = false
        server.beginAccepting()
        return server
    }

    public func stop(reason: TranscriptReadRevocationReason) async {
        await boundary.stop(reason: reason)
        closeTransport()
    }

    public func isStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    public func diagnosticClosedReason() async -> TranscriptReadMCPClosedReason? {
        await boundary.diagnosticClosedReason()
    }

    public func diagnosticHTTPClosedReason() -> LoopbackTranscriptReadHTTPClosedReason? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return httpClosedReason
    }

    func listenerDescriptorForTesting() -> Int32 {
        listener.initialDescriptor
    }

    private func beginAccepting() {
        enqueueAcceptStep()
    }

    private func enqueueAcceptStep() {
        queue.async { [weak self] in
            self?.acceptOne()
        }
    }

    /// Processes one bounded poll/accept step, then releases the strong server
    /// reference before scheduling the next weakly captured step. Dropping the
    /// last Attempt owner therefore still reaches deinit and closes the listener.
    private func acceptOne() {
        guard !isStopped(),
              let step = listener.withOpenDescriptor({ descriptor in
                  pollAndAccept(listenerDescriptor: descriptor)
              })
        else {
            testHooks.acceptLoopFinished?()
            return
        }
        switch step {
        case .idle:
            enqueueAcceptStep()
        case let .accepted(connection):
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.readOneRequest(from: connection)
            }
            enqueueAcceptStep()
        case .stopped:
            testHooks.acceptLoopFinished?()
        case .failed:
            testHooks.acceptLoopFinished?()
            requestProtocolStop()
        }
    }

    /// Runs under the listener owner's lock. This makes acceptance and
    /// registration indivisible with respect to listener close: stop either
    /// snapshots the registered connection or registration observes stopped and
    /// closes it before the listener lock is released.
    private func pollAndAccept(listenerDescriptor: Int32) -> ListenerStep {
        var pollDescriptor = pollfd(
            fd: listenerDescriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        let pollResult = Darwin.poll(
            &pollDescriptor,
            1,
            Self.acceptPollMilliseconds
        )
        if pollResult == 0 || (pollResult < 0 && errno == EINTR) {
            return .idle
        }
        guard pollResult > 0, pollDescriptor.revents & Int16(POLLIN) != 0 else {
            return isStopped() ? .stopped : .failed
        }

        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let acceptedDescriptor = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.accept(listenerDescriptor, socketAddress, &length)
            }
        }
        if acceptedDescriptor < 0 {
            return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR
                ? .idle
                : (isStopped() ? .stopped : .failed)
        }

        let connection = SerializedSocket(
            descriptor: acceptedDescriptor,
            operationObserver: testHooks.descriptorWillBeUsed
        )
        testHooks.acceptedBeforeRegistration?(acceptedDescriptor)
        let configured = connection.withOpenDescriptor { descriptor in
            setCloseOnExec(descriptor)
                && setBlocking(descriptor)
                && setNoSigPipe(descriptor)
                && setTimeout(descriptor, duration: requestTimeout)
        } ?? false
        guard configured else {
            connection.close()
            return isStopped() ? .stopped : .failed
        }

        switch addConnection(connection) {
        case .registered:
            return .accepted(connection)
        case .stopped:
            connection.close()
            return .stopped
        case .capacityExceeded:
            connection.close()
            return .failed
        }
    }

    private func addConnection(_ connection: SerializedSocket) -> ConnectionRegistration {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopped else { return .stopped }
        guard connections.count < maximumConnections else {
            return .capacityExceeded
        }
        connections[ObjectIdentifier(connection)] = connection
        return .registered
    }

    private func readOneRequest(from connection: SerializedSocket) {
        let descriptor = connection.initialDescriptor
        defer { testHooks.connectionWorkerFinished?(descriptor) }
        testHooks.acceptedBeforeReceive?(descriptor)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: requestTimeout)
        var collected = Data()
        while collected.count < maximumReadCapacity {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                failProtocol(connection, reason: .bodyTimedOut)
                return
            }
            var bytes = [UInt8](
                repeating: 0,
                count: min(16 * 1_024, maximumReadCapacity - collected.count)
            )
            guard let received = connection.withOpenDescriptor({ descriptor in
                guard setReceiveTimeout(descriptor, duration: remaining) else {
                    return -1
                }
                return bytes.withUnsafeMutableBytes { pointer in
                    Darwin.recv(descriptor, pointer.baseAddress, pointer.count, 0)
                }
            }) else {
                finishConnection(connection)
                return
            }
            guard received > 0 else {
                failProtocol(connection, reason: .bodyTimedOut)
                return
            }
            collected.append(contentsOf: bytes.prefix(received))

            switch parseRequest(collected) {
            case .incomplete:
                continue
            case let .invalid(reason):
                failProtocol(connection, reason: reason)
                return
            case let .complete(request):
                Task { [weak self] in
                    guard let self else { return }
                    let response = await boundary.handle(request)
                    let stopAfterResponse = await boundary.isStopped()
                    self.send(response, to: connection)
                    self.finishConnection(connection)
                    if stopAfterResponse {
                        self.closeTransport()
                    }
                }
                return
            }
        }
        failProtocol(connection, reason: .bodySmuggling)
    }

    private func parseRequest(_ data: Data) -> HTTPParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            return data.count > maximumHeaderBytes ? .invalid(.headerTooLarge) : .incomplete
        }
        guard headerRange.lowerBound <= maximumHeaderBytes,
              let headerText = String(
                  data: data.subdata(in: 0 ..< headerRange.lowerBound),
                  encoding: .utf8
              )
        else {
            return .invalid(.invalidHeader)
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid(.invalidRequestLine) }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard requestParts.count == 3,
              requestParts[2] == "HTTP/1.1"
        else {
            return .invalid(.invalidRequestLine)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                return .invalid(.invalidHeader)
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  name.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil,
                  headers.updateValue(value, forKey: name) == nil
            else {
                return .invalid(.invalidHeader)
            }
        }
        guard headers["transfer-encoding"] == nil else {
            return .invalid(.unsupportedTransferEncoding)
        }
        guard let lengthText = headers["content-length"],
              let authority = headers["host"],
              let contentType = headers["content-type"]
        else {
            return .invalid(.missingRequiredHeader)
        }
        guard !lengthText.isEmpty,
              lengthText.utf8.allSatisfy({ (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }),
              let contentLength = Int(lengthText),
              contentLength <= maximumBodyBytes
        else {
            return .invalid(.invalidContentLength)
        }

        let bodyStart = headerRange.upperBound
        let expectedSize = bodyStart.addingReportingOverflow(contentLength)
        guard !expectedSize.overflow,
              expectedSize.partialValue <= maximumCollectedBytes
        else {
            return .invalid(.invalidContentLength)
        }
        guard data.count >= expectedSize.partialValue else { return .incomplete }
        guard data.count == expectedSize.partialValue else { return .invalid(.bodySmuggling) }
        return .complete(
            TranscriptReadHTTPRequest(
                method: String(requestParts[0]),
                path: String(requestParts[1]),
                authority: authority,
                contentType: contentType,
                authorization: headers["authorization"],
                origin: headers["origin"],
                body: data.subdata(in: bodyStart ..< expectedSize.partialValue)
            )
        )
    }

    private func failProtocol(
        _ connection: SerializedSocket,
        reason: LoopbackTranscriptReadHTTPClosedReason
    ) {
        stateLock.lock()
        httpClosedReason = reason
        stateLock.unlock()
        Task { [weak self] in
            guard let self else { return }
            await boundary.stop(reason: .protocolFailure)
            send(.closedProtocolError, to: connection)
            finishConnection(connection)
            closeTransport()
        }
    }

    private func send(_ response: TranscriptReadHTTPResponse, to connection: SerializedSocket) {
        let reason: String
        switch response.statusCode {
        case 200:
            reason = "OK"
        case 202:
            reason = "Accepted"
        default:
            reason = "Bad Request"
        }
        var headers = "HTTP/1.1 \(response.statusCode) \(reason)\r\n"
        if let contentType = response.contentType {
            headers += "Content-Type: \(contentType)\r\n"
        }
        headers += "Cache-Control: no-store\r\n"
        headers += "Content-Length: \(response.body.count)\r\n"
        headers += "Connection: close\r\n\r\n"
        var bytes = Data(headers.utf8)
        bytes.append(response.body)

        _ = connection.withOpenDescriptor { descriptor in
            bytes.withUnsafeBytes { pointer in
                var sent = 0
                while sent < pointer.count {
                    let result = Darwin.send(
                        descriptor,
                        pointer.baseAddress?.advanced(by: sent),
                        pointer.count - sent,
                        0
                    )
                    guard result > 0 else { return }
                    sent += result
                }
            }
        }
    }

    private func finishConnection(_ connection: SerializedSocket) {
        stateLock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        stateLock.unlock()
        connection.close()
    }

    private func closeTransport() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        let activeConnections = Array(connections.values)
        connections.removeAll(keepingCapacity: false)
        stateLock.unlock()

        testHooks.transportDidMarkStopped?()
        listener.close()
        for connection in activeConnections {
            connection.close()
        }
    }

    private func requestProtocolStop() {
        Task { [weak self] in
            guard let self else { return }
            await boundary.stop(reason: .protocolFailure)
            closeTransport()
        }
    }
}

private enum HTTPParseResult {
    case incomplete
    case invalid(LoopbackTranscriptReadHTTPClosedReason)
    case complete(TranscriptReadHTTPRequest)
}

private enum ListenerStep {
    case idle
    case accepted(SerializedSocket)
    case stopped
    case failed
}

private enum ConnectionRegistration {
    case registered
    case stopped
    case capacityExceeded
}

/// Owns one descriptor for its entire lifetime. The lock stays held across each
/// syscall, including bounded blocking calls. Close acquires the same lock and
/// clears the descriptor before releasing it, so no later operation can target a
/// different in-process resource that reused the numeric descriptor.
private final class SerializedSocket: @unchecked Sendable {
    let initialDescriptor: Int32

    private let lock = NSLock()
    private let operationObserver: (@Sendable (Int32) -> Void)?
    private var descriptor: Int32?

    init(
        descriptor: Int32,
        operationObserver: (@Sendable (Int32) -> Void)? = nil
    ) {
        initialDescriptor = descriptor
        self.operationObserver = operationObserver
        self.descriptor = descriptor
    }

    deinit {
        close()
    }

    func withOpenDescriptor<Result>(_ operation: (Int32) -> Result) -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor else { return nil }
        operationObserver?(descriptor)
        return operation(descriptor)
    }

    func close() {
        lock.lock()
        guard let descriptor else {
            lock.unlock()
            return
        }
        self.descriptor = nil
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        lock.unlock()
    }
}

private func setCloseOnExec(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFD)
    return flags >= 0 && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
}

private func setNonblocking(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFL)
    return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
}

private func setBlocking(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFL)
    return flags >= 0 && fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0
}

private func setNoSigPipe(_ descriptor: Int32) -> Bool {
    var enabled: Int32 = 1
    return setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &enabled,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0
}

private func setTimeout(_ descriptor: Int32, duration: Duration) -> Bool {
    var timeout = duration.timevalValue
    let size = socklen_t(MemoryLayout<timeval>.size)
    return setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0
        && setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0
}

private func setReceiveTimeout(_ descriptor: Int32, duration: Duration) -> Bool {
    var timeout = duration.timevalValue
    return setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    ) == 0
}

private extension Duration {
    var timevalValue: timeval {
        let components = self.components
        let seconds = max(0, components.seconds)
        let microseconds = max(1, components.attoseconds / 1_000_000_000_000)
        return timeval(tv_sec: Int(seconds), tv_usec: Int32(microseconds))
    }
}

private extension TranscriptReadHTTPResponse {
    static let closedProtocolError = TranscriptReadHTTPResponse(
        statusCode: 400,
        contentType: "application/json",
        body: CanonicalJSON.serialize(
            .object([
                "error": .object([
                    "code": .integer(-32_600),
                    "message": .string("requestRejected"),
                ]),
                "id": .null,
                "jsonrpc": .string("2.0"),
            ])
        )
    )
}
