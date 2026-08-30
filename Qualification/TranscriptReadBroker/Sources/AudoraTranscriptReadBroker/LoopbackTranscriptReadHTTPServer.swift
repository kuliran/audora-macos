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

/// Attempt-owned loopback listener for the strict MCP boundary.
///
/// It accepts one bounded HTTP/1.1 request per connection, never redirects,
/// never emits CORS headers, and closes the listening endpoint whenever the MCP
/// boundary reaches a terminal state.
public final class LoopbackTranscriptReadHTTPServer: @unchecked Sendable {
    public let host = "127.0.0.1"
    public let port: UInt16

    public var endpointURL: URL {
        URL(string: "http://127.0.0.1:\(port)/mcp")!
    }

    private let listenerDescriptor: Int32
    private let queue: DispatchQueue
    private let boundary: TranscriptReadMCPBoundary
    private let maximumBodyBytes: Int
    private let maximumHeaderBytes: Int
    private let requestTimeout: Duration
    private let maximumConnections: Int
    private let stateLock = NSLock()
    private var stopped = false
    private var connections: Set<Int32> = []
    private var readSource: DispatchSourceRead?
    private var httpClosedReason: LoopbackTranscriptReadHTTPClosedReason?

    private init(
        listenerDescriptor: Int32,
        port: UInt16,
        grant: AttemptTranscriptGrant,
        maximumBodyBytes: Int,
        maximumHeaderBytes: Int,
        requestTimeout: Duration,
        maximumConnections: Int
    ) {
        self.listenerDescriptor = listenerDescriptor
        self.port = port
        self.maximumBodyBytes = maximumBodyBytes
        self.maximumHeaderBytes = maximumHeaderBytes
        self.requestTimeout = requestTimeout
        self.maximumConnections = maximumConnections
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
        guard maximumBodyBytes > 0,
              maximumHeaderBytes > 0,
              requestTimeout > .zero,
              maximumConnections > 0
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
              Darwin.listen(descriptor, Int32(maximumConnections)) == 0
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

        let server = LoopbackTranscriptReadHTTPServer(
            listenerDescriptor: descriptor,
            port: UInt16(bigEndian: boundAddress.sin_port),
            grant: grant,
            maximumBodyBytes: maximumBodyBytes,
            maximumHeaderBytes: maximumHeaderBytes,
            requestTimeout: requestTimeout,
            maximumConnections: maximumConnections
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

    private func beginAccepting() {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: listenerDescriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.acceptAvailableConnections()
        }
        stateLock.lock()
        readSource = source
        stateLock.unlock()
        source.resume()
    }

    private func acceptAvailableConnections() {
        while !isStopped() {
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let descriptor = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.accept(listenerDescriptor, socketAddress, &length)
                }
            }
            if descriptor < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                Task { [weak self] in
                    await self?.boundary.stop(reason: .protocolFailure)
                    self?.closeTransport()
                }
                return
            }

            guard setCloseOnExec(descriptor),
                  setBlocking(descriptor),
                  setNoSigPipe(descriptor),
                  setTimeout(descriptor, duration: requestTimeout),
                  addConnection(descriptor)
            else {
                Darwin.close(descriptor)
                Task { [weak self] in
                    await self?.boundary.stop(reason: .protocolFailure)
                    self?.closeTransport()
                }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.readOneRequest(from: descriptor)
            }
        }
    }

    private func addConnection(_ descriptor: Int32) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopped, connections.count < maximumConnections else {
            return false
        }
        connections.insert(descriptor)
        return true
    }

    private func readOneRequest(from descriptor: Int32) {
        let maximumTotal = maximumHeaderBytes + maximumBodyBytes
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: requestTimeout)
        var collected = Data()
        while collected.count <= maximumTotal {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero,
                  setReceiveTimeout(descriptor, duration: remaining)
            else {
                failProtocol(descriptor, reason: .bodyTimedOut)
                return
            }
            var bytes = [UInt8](
                repeating: 0,
                count: min(16 * 1_024, maximumTotal + 1 - collected.count)
            )
            let received = bytes.withUnsafeMutableBytes { pointer in
                Darwin.recv(descriptor, pointer.baseAddress, pointer.count, 0)
            }
            guard received > 0 else {
                failProtocol(descriptor, reason: .bodyTimedOut)
                return
            }
            collected.append(contentsOf: bytes.prefix(received))

            switch parseRequest(collected) {
            case .incomplete:
                continue
            case let .invalid(reason):
                failProtocol(descriptor, reason: reason)
                return
            case let .complete(request):
                Task { [weak self] in
                    guard let self else { return }
                    let response = await boundary.handle(request)
                    let stopAfterResponse = await boundary.isStopped()
                    self.send(response, to: descriptor)
                    self.finishConnection(descriptor)
                    if stopAfterResponse {
                        self.closeTransport()
                    }
                }
                return
            }
        }
        failProtocol(descriptor, reason: .bodySmuggling)
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
        guard let contentLength = Int(lengthText),
              contentLength >= 0,
              contentLength <= maximumBodyBytes
        else {
            return .invalid(.invalidContentLength)
        }

        let bodyStart = headerRange.upperBound
        let expectedSize = bodyStart + contentLength
        guard data.count >= expectedSize else { return .incomplete }
        guard data.count == expectedSize else { return .invalid(.bodySmuggling) }
        return .complete(
            TranscriptReadHTTPRequest(
                method: String(requestParts[0]),
                path: String(requestParts[1]),
                authority: authority,
                contentType: contentType,
                authorization: headers["authorization"],
                origin: headers["origin"],
                body: data.subdata(in: bodyStart ..< expectedSize)
            )
        )
    }

    private func failProtocol(
        _ descriptor: Int32,
        reason: LoopbackTranscriptReadHTTPClosedReason
    ) {
        stateLock.lock()
        httpClosedReason = reason
        stateLock.unlock()
        Task { [weak self] in
            guard let self else { return }
            await boundary.stop(reason: .protocolFailure)
            send(.closedProtocolError, to: descriptor)
            finishConnection(descriptor)
            closeTransport()
        }
    }

    private func send(_ response: TranscriptReadHTTPResponse, to descriptor: Int32) {
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

        // Serialize send against connection teardown so a closed descriptor
        // cannot be reused elsewhere in the process between validation and send.
        stateLock.lock()
        guard connections.contains(descriptor) else {
            stateLock.unlock()
            return
        }
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
        stateLock.unlock()
    }

    private func finishConnection(_ descriptor: Int32) {
        stateLock.lock()
        let wasTracked = connections.remove(descriptor) != nil
        stateLock.unlock()
        if wasTracked {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }

    private func closeTransport() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        let descriptors = connections
        connections.removeAll(keepingCapacity: false)
        let source = readSource
        readSource = nil
        stateLock.unlock()

        source?.cancel()
        Darwin.shutdown(listenerDescriptor, SHUT_RDWR)
        Darwin.close(listenerDescriptor)
        for descriptor in descriptors {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }
}

private enum HTTPParseResult {
    case incomplete
    case invalid(LoopbackTranscriptReadHTTPClosedReason)
    case complete(TranscriptReadHTTPRequest)
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
