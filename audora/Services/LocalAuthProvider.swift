import ConvexMobile
import Foundation

struct LocalCredentials {
    let token: String
    let expiresAt: Date
}

private struct LocalTokenResponse: Decodable {
    let token: String
    let expiresAt: Double
}

private func isExactLocalTokenURL(_ url: URL?) -> Bool {
    guard let url else { return false }
    return url.scheme == "http"
        && url.host == "127.0.0.1"
        && url.port == 5173
        && url.path == "/api/local-auth-token"
        && url.query == nil
        && url.fragment == nil
        && url.user == nil
        && url.password == nil
}

private final class LocalTokenSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // This fixed loopback endpoint never needs a redirect. Rejecting every
        // redirect prevents a compromised local service from forwarding the app
        // to a remote host.
        completionHandler(nil)
    }
}

enum LocalAuthError: LocalizedError {
    case connectionUnavailable
    case invalidEndpoint
    case invalidResponse
    case serverUnavailable(Int)

    var errorDescription: String? {
        switch self {
        case .connectionUnavailable:
            return "The local JWT service at 127.0.0.1:5173 is not reachable. Start the Audora web server, then retry."
        case .invalidEndpoint:
            return "The local JWT endpoint is invalid."
        case .invalidResponse:
            return "The local JWT endpoint returned an invalid response."
        case .serverUnavailable(let status):
            return "The local JWT endpoint is unavailable (HTTP \(status)). Start the Audora web server first."
        }
    }
}

struct LocalAuthProvider: AuthProvider {
    private let tokenURL: URL

    init(tokenURL: String = AppMode.localAuthTokenURL) {
        guard let url = URL(string: tokenURL) else {
            preconditionFailure("Invalid local auth token URL")
        }
        self.tokenURL = url
    }

    func login() async throws -> LocalCredentials {
        try await fetchCredentials()
    }

    func loginFromCache() async throws -> LocalCredentials {
        try await fetchCredentials()
    }

    func logout() async throws {}

    func extractIdToken(from authResult: LocalCredentials) -> String {
        authResult.token
    }

    private func fetchCredentials() async throws -> LocalCredentials {
        guard isExactLocalTokenURL(tokenURL) else {
            throw LocalAuthError.invalidEndpoint
        }

        var request = URLRequest(url: tokenURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        let delegate = LocalTokenSessionDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let networkError = error as NSError
            if networkError.domain == NSURLErrorDomain {
                throw LocalAuthError.connectionUnavailable
            }
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse,
              isExactLocalTokenURL(httpResponse.url) else {
            throw LocalAuthError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LocalAuthError.serverUnavailable(httpResponse.statusCode)
        }

        let payload = try JSONDecoder().decode(LocalTokenResponse.self, from: data)
        guard !payload.token.isEmpty else {
            throw LocalAuthError.invalidResponse
        }
        let expiresAt = Date(timeIntervalSince1970: payload.expiresAt / 1_000)
        guard expiresAt > Date() else {
            throw LocalAuthError.invalidResponse
        }
        return LocalCredentials(token: payload.token, expiresAt: expiresAt)
    }
}
