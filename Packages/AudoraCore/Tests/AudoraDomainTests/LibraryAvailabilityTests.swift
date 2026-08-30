import AudoraDomain
import XCTest

final class PortableLibraryDomainTests: XCTestCase {
    func testTypedLibraryAndProfileIdentitiesValidateTheirCompleteShape() throws {
        XCTAssertEqual(
            try LibraryID("lib-20260830T120000000Z-2ABC").rawValue,
            "lib-20260830T120000000Z-2ABC"
        )
        XCTAssertEqual(
            try ProfileRevisionID("prf-20260830T120000000Z-3DEF").rawValue,
            "prf-20260830T120000000Z-3DEF"
        )

        for invalid in [
            "ses-20260830T120000000Z-2ABC",
            "lib-20260230T120000000Z-2ABC",
            "lib-20260830T120000000Z-2abC",
            "lib-20260830T120000000Z-2AOC",
            "../lib-20260830T120000000Z-2ABC",
        ] {
            XCTAssertThrowsError(try LibraryID(invalid), invalid)
        }
    }

    func testInstantRejectsNonexistentCalendarValuesAndRequiresMilliseconds() {
        XCTAssertNoThrow(try UTCInstant("2024-02-29T23:59:59.999Z"))
        XCTAssertThrowsError(try UTCInstant("2026-02-29T12:00:00.000Z"))
        XCTAssertThrowsError(try UTCInstant("2026-08-30T12:00:00Z"))
    }

    func testRelativePathRejectsEveryEscapeAndKeepsPortableComponents() throws {
        XCTAssertEqual(
            try LibraryRelativePath("profile/revisions/item.json").components,
            ["profile", "revisions", "item.json"]
        )
        for invalid in [
            "", "/profile/head.json", "~/head.json", "profile//head.json",
            "profile/./head.json", "profile/../head.json", "profile\\head.json",
            "file:profile/head.json", "C:/profile/head.json",
        ] {
            XCTAssertThrowsError(try LibraryRelativePath(invalid), invalid)
        }
    }

    func testNullProfileIsValidAuthorityAndProjectsToNoStatements() throws {
        let head = ProfileHead(
            generation: 0,
            statementGeneration: 0,
            selection: .null,
            updatedAt: try UTCInstant("2026-08-30T12:00:00.000Z")
        )

        XCTAssertEqual(
            ProfileProjection.context(from: head),
            ProfileContext(statements: [])
        )
    }

    func testSelectedProfilePointerRequiresTypedIDAndLowercaseSHA256() throws {
        let revisionID = try ProfileRevisionID("prf-20260830T120100000Z-3DEF")
        XCTAssertNoThrow(
            try ProfileRevisionPointer(
                revisionID: revisionID,
                sha256: String(repeating: "a", count: 64)
            )
        )
        XCTAssertThrowsError(
            try ProfileRevisionPointer(
                revisionID: revisionID,
                sha256: String(repeating: "A", count: 64)
            )
        )
    }

    func testPreferencesRequireFinitePositivePlaybackRate() throws {
        XCTAssertEqual(LibraryPreferences.defaults.playbackRate, 1.0)
        for invalid in [0.0, -1.0, .infinity, .nan] {
            XCTAssertThrowsError(
                try LibraryPreferences(
                    language: .english,
                    annotationsVisible: true,
                    playbackRate: invalid
                )
            )
        }
    }
}
