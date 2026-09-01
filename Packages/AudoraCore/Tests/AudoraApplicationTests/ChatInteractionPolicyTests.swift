@testable import AudoraApplication
import AudoraDomain
import XCTest

final class ChatInteractionPolicyTests: XCTestCase {
    func testCoachInvocationControlsRequireProjectedAdmissionAvailability() throws {
        let reopensAt = try UTCInstant("2026-08-30T12:01:00.000Z")

        XCTAssertFalse(
            ChatInteractionPolicy.allowsCoachInvocation(
                in: ChatFeatureState(admissionAvailability: nil)
            )
        )
        XCTAssertFalse(
            ChatInteractionPolicy.allowsCoachInvocation(
                in: ChatFeatureState(
                    admissionAvailability: .cooldown(reopensAt: reopensAt)
                )
            )
        )
        XCTAssertFalse(
            ChatInteractionPolicy.allowsCoachInvocation(
                in: ChatFeatureState(admissionAvailability: .unavailable)
            )
        )
        XCTAssertTrue(
            ChatInteractionPolicy.allowsCoachInvocation(
                in: ChatFeatureState(admissionAvailability: .available)
            )
        )
    }

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
