@testable @_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
import XCTest

final class InvocationAdmissionLedgerTests: XCTestCase {
    func testRollingWindowRejectsAt59999MillisecondsAndAdmitsAt60000() throws {
        var ledger = RollingInvocationAdmissionLedger(maximumLibraries: 4)
        let library = try scope("lib-20260830T120000000Z-1ABC")

        XCTAssertEqual(
            ledger.claim(library: library, at: try instant("2026-08-30T12:00:00.000Z")),
            .admitted
        )
        XCTAssertEqual(
            ledger.claim(library: library, at: try instant("2026-08-30T12:00:59.999Z")),
            .cooldown(
                lastAdmittedAt: try instant("2026-08-30T12:00:00.000Z"),
                reopensAt: try instant("2026-08-30T12:01:00.000Z")
            )
        )
        XCTAssertEqual(
            ledger.claim(library: library, at: try instant("2026-08-30T12:01:00.000Z")),
            .admitted
        )
    }

    func testClockRollbackFailsClosedUntilLastDebitWindowHasElapsed() throws {
        var ledger = RollingInvocationAdmissionLedger(maximumLibraries: 4)
        let library = try scope("lib-20260830T120000000Z-1ABC")
        let lastDebit = try instant("2026-08-30T12:02:00.000Z")

        XCTAssertEqual(ledger.claim(library: library, at: lastDebit), .admitted)
        XCTAssertEqual(
            ledger.claim(library: library, at: try instant("2026-08-30T12:01:59.999Z")),
            .clockRollback(lastAdmittedAt: lastDebit)
        )
        XCTAssertEqual(
            ledger.claim(library: library, at: try instant("2026-08-30T12:03:00.000Z")),
            .admitted
        )
    }

    func testBoundedLedgerRejectsANewLibraryWithoutEvictingDurableDebits() throws {
        var ledger = RollingInvocationAdmissionLedger(maximumLibraries: 1)
        let first = try scope("lib-20260830T120000000Z-1ABC")
        let second = try scope("lib-20260830T120000000Z-2DEF")
        let now = try instant("2026-08-30T12:00:00.000Z")

        XCTAssertEqual(ledger.claim(library: first, at: now), .admitted)
        XCTAssertEqual(ledger.claim(library: second, at: now), .ledgerFull)
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.entries.first?.library, first)
    }

    func testRestoredEntriesRejectDuplicatesAndImpossibleBounds() throws {
        let library = try scope("lib-20260830T120000000Z-1ABC")
        let entry = RollingInvocationAdmissionEntry(
            library: library,
            lastAdmittedAt: try instant("2026-08-30T12:00:00.000Z")
        )

        XCTAssertThrowsError(
            try RollingInvocationAdmissionLedger(
                validating: [entry, entry],
                maximumLibraries: 4
            )
        ) { error in
            XCTAssertEqual(error as? RollingInvocationAdmissionLedgerError, .duplicateLibrary)
        }
        XCTAssertThrowsError(
            try RollingInvocationAdmissionLedger(
                validating: [entry],
                maximumLibraries: 0
            )
        ) { error in
            XCTAssertEqual(error as? RollingInvocationAdmissionLedgerError, .invalidLimit)
        }
    }

    private func scope(_ rawValue: String) throws -> LibraryScope {
        LibraryScope(libraryID: try LibraryID(rawValue))
    }

    private func instant(_ rawValue: String) throws -> UTCInstant {
        try UTCInstant(rawValue)
    }
}
