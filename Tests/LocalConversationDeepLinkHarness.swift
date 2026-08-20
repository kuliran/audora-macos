import Foundation

@main
private enum LocalConversationDeepLinkHarness {
    private static let validID = "j57h3k9m2n6p8q4r7s5t1v0w3x9y2z6a"

    static func main() {
        expectAccepted(
            "audora-local://conversation/\(validID)",
            conversationID: validID
        )

        let rejected = [
            "https://conversation/\(validID)",
            "AUDORA-LOCAL://conversation/\(validID)",
            "audora-local://other/\(validID)",
            "audora-local://user@conversation/\(validID)",
            "audora-local://conversation:1234/\(validID)",
            "audora-local://conversation/\(validID)?token=secret",
            "audora-local://conversation/\(validID)#fragment",
            "audora-local://conversation/\(validID)/extra",
            "audora-local://conversation/%6A57h3k9m2n6p8q4r7s5t1v0w3x9y2z6a",
            "audora-local://conversation/J57h3k9m2n6p8q4r7s5t1v0w3x9y2z6a",
            "audora-local://conversation/short",
            "audora-local://conversation/\(String(repeating: "a", count: 65))",
            "audora-local://conversation/j57h3k9m2n6p8q4r7s5t1v0w3x9y2z-a",
        ]

        for value in rejected {
            expectRejected(value)
        }

        print("LocalConversationDeepLinkHarness: all deterministic checks passed")
    }

    private static func expectAccepted(_ value: String, conversationID: String) {
        guard let url = URL(string: value),
              LocalConversationDeepLink.parse(url)?.conversationID == conversationID else {
            fatalError("expected accepted local conversation URL")
        }
    }

    private static func expectRejected(_ value: String) {
        guard let url = URL(string: value) else {
            return
        }
        if LocalConversationDeepLink.parse(url) != nil {
            fatalError("expected rejected local conversation URL")
        }
    }
}
