#if AUDORA_LOCAL_SETUP
import Foundation

/// A local-only handoff from the loopback web UI to the native recorder.
///
/// The URL is intentionally data-minimal: it contains only a Convex document ID.
/// Authentication is performed independently by the app before the ID is used.
struct LocalConversationDeepLink: Equatable {
    static let scheme = "audora-local"
    static let host = "conversation"

    let conversationID: String

    static func parse(_ url: URL) -> LocalConversationDeepLink? {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
        components.scheme == scheme,
        components.host == host,
        components.user == nil,
        components.password == nil,
        components.port == nil,
        components.percentEncodedQuery == nil,
        components.percentEncodedFragment == nil else {
            return nil
        }

        // Reject percent-encoding rather than accepting multiple textual forms
        // of the same identifier. Convex IDs are lowercase base-32 strings.
        let encodedPath = components.percentEncodedPath
        guard encodedPath.first == "/",
              encodedPath.dropFirst().contains("/") == false,
              encodedPath.contains("%") == false else {
            return nil
        }

        let conversationID = String(encodedPath.dropFirst())
        guard isValidConversationID(conversationID) else {
            return nil
        }

        return LocalConversationDeepLink(conversationID: conversationID)
    }

    static func isValidConversationID(_ value: String) -> Bool {
        // The upper bound keeps malformed links from becoming oversized
        // backend arguments while allowing Convex to evolve its ID length.
        guard (16...64).contains(value.utf8.count) else {
            return false
        }

        return value.utf8.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
        }
    }
}
#endif
