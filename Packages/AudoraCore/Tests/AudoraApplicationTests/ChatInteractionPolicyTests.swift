@testable import AudoraApplication
import AudoraDomain
import XCTest

final class ChatInteractionPolicyTests: XCTestCase {
    func testNavigationAndMutationRequireAReadyIdleCatalog() throws {
        let ready = ChatCatalogSnapshot(allRows: [], visibleRows: [])
        let chatID = try ChatID("cht-20260830T120000000Z-2ABC")

        XCTAssertFalse(
            ChatInteractionPolicy.allowsNavigationAndMutation(
                in: ChatFeatureState(catalog: .notLoaded)
            )
        )
        XCTAssertFalse(
            ChatInteractionPolicy.allowsNavigationAndMutation(
                in: ChatFeatureState(catalog: .loading)
            )
        )
        XCTAssertFalse(
            ChatInteractionPolicy.allowsNavigationAndMutation(
                in: ChatFeatureState(catalog: .failed)
            )
        )
        XCTAssertTrue(
            ChatInteractionPolicy.allowsNavigationAndMutation(
                in: ChatFeatureState(catalog: .ready(ready))
            )
        )
        XCTAssertFalse(
            ChatInteractionPolicy.allowsNavigationAndMutation(
                in: ChatFeatureState(catalog: .ready(ready), activity: .creating)
            )
        )
        XCTAssertFalse(
            ChatInteractionPolicy.allowsNavigationAndMutation(
                in: ChatFeatureState(catalog: .ready(ready), selection: .opening(chatID))
            )
        )
    }
}
