import AudoraDomain
@testable import AudoraApplication
import XCTest

final class ReplacePendingUserTurnMutationTests: XCTestCase {
    func testReplacementChangesOnlyFailureAndRetainsCASBase() throws {
        let base = try makePendingUserTurn()
        let replacement = base.replacingFailure(.coachContextCannotFit)

        let mutation = try ReplacePendingUserTurnMutation(
            library: makeLibraryScope(),
            chatID: try ChatID("cht-20260830T120000000Z-2ABC"),
            base: base,
            replacement: replacement
        )

        XCTAssertEqual(mutation.base, base)
        XCTAssertEqual(mutation.replacement, replacement)
        XCTAssertEqual(mutation.replacement.id, mutation.base.id)
        XCTAssertEqual(mutation.replacement.draftID, mutation.base.draftID)
        XCTAssertEqual(mutation.replacement.draftVersion, mutation.base.draftVersion)
        XCTAssertEqual(
            mutation.replacement.responsePositionID,
            mutation.base.responsePositionID
        )
    }

    func testReplacementRejectsAnyPendingIdentityChange() throws {
        let base = try makePendingUserTurn()
        let changedIdentity = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120001000Z-7STV"),
            draftID: base.draftID,
            draftVersion: base.draftVersion,
            responsePositionID: base.responsePositionID,
            failure: .coachContextCannotFit
        )

        XCTAssertThrowsError(
            try ReplacePendingUserTurnMutation(
                library: makeLibraryScope(),
                chatID: try ChatID("cht-20260830T120000000Z-2ABC"),
                base: base,
                replacement: changedIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? ReplacePendingUserTurnMutationError,
                .identityChanged
            )
        }
    }

    private func makePendingUserTurn() throws -> PendingUserTurn {
        PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
            draftID: try ChatDraftID("drf-20260830T120000000Z-3DEF"),
            draftVersion: 7,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120001000Z-6PQR"
            )
        )
    }

    private func makeLibraryScope() -> LibraryScope {
        LibraryScope(libraryID: try! LibraryID("lib-20260830T120000000Z-2ABC"))
    }
}
