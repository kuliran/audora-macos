import AudoraApplication
import AudoraDomain
@testable import AudoraMacPresentation
import XCTest

final class LibraryCatalogFormattingTests: XCTestCase {
    func testRowsUseManifestMetadataWithoutExposingStorageIdentifiers()
        throws
    {
        let createdAt = try UTCInstant("2026-08-30T12:00:00.000Z")
        let updatedAt = try UTCInstant("2026-08-30T12:01:00.000Z")
        let sessionID = try SessionID("ses-20260830T120000000Z-2ABC")
        let chatID = try ChatID("cht-20260830T120000000Z-3DEF")
        let cases: [(
            row: LibraryCatalogRow,
            title: String,
            metadata: String,
            matchingQueries: [String],
            hiddenIdentifier: String
        )] = [
            (
                .session(
                    sessionID,
                    LibrarySessionCatalogMetadata(
                        acquisition: .imported,
                        createdAt: createdAt,
                        hasSelectedTranscript: false
                    )
                ),
                "Session · Aug 30",
                "Imported · No transcript",
                ["session", "AUG 30", "imported", "no transcript", "12:00"],
                sessionID.rawValue
            ),
            (
                .chat(
                    chatID,
                    LibraryChatCatalogMetadata(
                        title: try ChatTitle("Café Conversation"),
                        createdAt: createdAt,
                        updatedAt: updatedAt
                    )
                ),
                "Café Conversation",
                "Created Aug 30 · Updated Aug 30",
                ["chat", "cafe", "conversation", "12:01"],
                chatID.rawValue
            ),
            (
                .unavailable(.chat(chatID), .newerSchema),
                "Unavailable Chat",
                "Created by a newer Audora version",
                ["unavailable", "newer audora"],
                chatID.rawValue
            ),
        ]

        for item in cases {
            let presentation = LibraryCatalogRowPresentation(
                row: item.row,
                formatDate: { _ in "Aug 30" }
            )
            XCTAssertEqual(presentation.title, item.title)
            XCTAssertEqual(presentation.metadata, item.metadata)
            XCTAssertFalse(presentation.title.contains(item.hiddenIdentifier))
            XCTAssertFalse(
                presentation.accessibilityLabel.contains(item.hiddenIdentifier)
            )
            XCTAssertFalse(presentation.matches(item.hiddenIdentifier))
            for query in item.matchingQueries {
                XCTAssertTrue(
                    presentation.matches(query),
                    "Expected \(item.title) to match \(query)"
                )
            }
        }
    }

    func testMutationNoticeCopyReflectsWhetherCatalogWasVerified() throws {
        let chat = LibraryAggregate.chat(
            try ChatID("cht-20260830T120000000Z-3DEF")
        )
        let uncertain = LibraryAggregateMutationResult(
            aggregate: chat,
            outcome: .commitUncertain
        )
        let integrityMismatch = LibraryAggregateMutationResult(
            aggregate: chat,
            outcome: .integrityMismatch
        )
        let cases: [(
            notice: LibraryCatalogMutationNotice,
            expected: String
        )] = [
            (
                LibraryCatalogMutationNotice(
                    action: .movedToTrash,
                    results: [uncertain],
                    catalogVerification: .verifiedCurrentContents
                ),
                "1 change may have completed; the Library contents were refreshed."
            ),
            (
                LibraryCatalogMutationNotice(
                    action: .restored,
                    results: [uncertain],
                    catalogVerification: .unverified
                ),
                "1 change may have completed; current Library contents could not be verified."
            ),
            (
                LibraryCatalogMutationNotice(
                    action: .movedToTrash,
                    results: [integrityMismatch]
                ),
                "1 item could not be verified and was not changed."
            ),
        ]

        for item in cases {
            XCTAssertEqual(
                LibraryCatalogMutationNoticeFormatter.text(for: item.notice),
                item.expected
            )
        }
    }
}
