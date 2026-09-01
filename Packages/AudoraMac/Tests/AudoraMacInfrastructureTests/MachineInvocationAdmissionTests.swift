@testable @_spi(InvocationInfrastructure) import AudoraApplication
@testable @_spi(InvocationInfrastructure) import AudoraMacInfrastructure
import AudoraDomain
import Foundation
import XCTest

final class MachineInvocationAdmissionTests: XCTestCase {
    func testReadOnlyAvailabilitySurvivesRelaunchAndDoesNotConsumeReopening() async throws {
        let fixture = try Fixture()
        let admittedAt = fixture.instant(0)
        let reopensAt = fixture.instant(60_000)
        let first = ApplicationSupportInvocationAdmission(fileURL: fixture.fileURL)
        let firstClaim = await first.claim(
            library: fixture.firstLibrary,
            at: admittedAt
        )
        XCTAssertEqual(firstClaim, .admitted)

        let relaunched = ApplicationSupportInvocationAdmission(fileURL: fixture.fileURL)
        let cooldown = await relaunched.availability(
            library: fixture.firstLibrary,
            at: fixture.instant(59_999)
        )
        XCTAssertEqual(
            cooldown,
            .cooldown(reopensAt: reopensAt)
        )
        let available = await relaunched.availability(
            library: fixture.firstLibrary,
            at: reopensAt
        )
        XCTAssertEqual(available, .available)
        let reopenedClaim = await relaunched.claim(
            library: fixture.firstLibrary,
            at: reopensAt
        )
        XCTAssertEqual(
            reopenedClaim,
            .admitted,
            "observing an open window must not debit it"
        )
    }

    func testProductionIdentityGeneratorEmitsPortableTypedAuthorities() async throws {
        let generated = await RandomInvocationIdentityGenerator().generate(
            at: try UTCInstant("2026-08-30T12:00:02.000Z")
        )

        XCTAssertNoThrow(try CoachInvocationID(generated.invocationID.rawValue))
        XCTAssertNoThrow(try CoachProviderAttemptID(generated.attemptID.rawValue))
        XCTAssertNoThrow(try ChatMessageID(generated.userMessageID.rawValue))
        XCTAssertNoThrow(try ChatMessageID(generated.coachMessageID.rawValue))
        XCTAssertNoThrow(try ChatDraftID(generated.freshDraftID.rawValue))
        XCTAssertNotEqual(generated.userMessageID, generated.coachMessageID)
        XCTAssertEqual(
            generated.idempotencyValue.rawValue,
            generated.attemptID.rawValue
        )
    }

    func testDurableDebitRejectsAt59999MillisecondsAndAdmitsAt60Seconds() async throws {
        let fixture = try Fixture()
        let first = ApplicationSupportInvocationAdmission(fileURL: fixture.fileURL)

        let firstOutcome = await first.claim(
            library: fixture.firstLibrary,
            at: fixture.instant(0)
        )
        XCTAssertEqual(firstOutcome, .admitted)

        let relaunched = ApplicationSupportInvocationAdmission(fileURL: fixture.fileURL)
        guard case .cooldown = await relaunched.claim(
            library: fixture.firstLibrary,
            at: fixture.instant(59_999)
        ) else {
            return XCTFail("59.999 seconds must remain inside the rolling window")
        }
        let reopened = await relaunched.claim(
            library: fixture.firstLibrary,
            at: fixture.instant(60_000)
        )
        XCTAssertEqual(reopened, .admitted)
    }

    func testClockRollbackFailsClosedWithoutMovingDurableDebitBackward() async throws {
        let fixture = try Fixture()
        let admission = ApplicationSupportInvocationAdmission(fileURL: fixture.fileURL)
        let firstOutcome = await admission.claim(
            library: fixture.firstLibrary,
            at: fixture.instant(60_000)
        )
        XCTAssertEqual(firstOutcome, .admitted)

        guard case .clockRollback = await admission.claim(
            library: fixture.firstLibrary,
            at: fixture.instant(0)
        ) else {
            return XCTFail("wall-clock rollback must fail closed")
        }
        guard case .cooldown = await admission.claim(
            library: fixture.firstLibrary,
            at: fixture.instant(119_999)
        ) else {
            return XCTFail("rollback must not erase or move the debit")
        }
        let reopened = await admission.claim(
            library: fixture.firstLibrary,
            at: fixture.instant(120_000)
        )
        XCTAssertEqual(reopened, .admitted)
    }

    func testConcurrentInstancesAdmitExactlyOneClaimForTheSameLibrary() async throws {
        let fixture = try Fixture()
        let first = ApplicationSupportInvocationAdmission(fileURL: fixture.fileURL)
        let second = ApplicationSupportInvocationAdmission(fileURL: fixture.fileURL)

        async let firstClaim = first.claim(
            library: fixture.firstLibrary,
            at: fixture.instant(0)
        )
        async let secondClaim = second.claim(
            library: fixture.firstLibrary,
            at: fixture.instant(0)
        )
        let outcomes = await [firstClaim, secondClaim]

        XCTAssertEqual(outcomes.filter { $0 == .admitted }.count, 1)
        XCTAssertEqual(outcomes.filter {
            if case .cooldown = $0 { return true }
            return false
        }.count, 1, "\(outcomes)")
    }

    func testConcurrentDifferentLibrariesRetainBothIndependentDurableWindows() async throws {
        let fixture = try Fixture()
        let firstAdmission = ApplicationSupportInvocationAdmission(fileURL: fixture.fileURL)
        let secondAdmission = ApplicationSupportInvocationAdmission(fileURL: fixture.fileURL)

        async let firstOutcome = firstAdmission.claim(
            library: fixture.firstLibrary,
            at: fixture.instant(0)
        )
        async let secondOutcome = secondAdmission.claim(
            library: fixture.secondLibrary,
            at: fixture.instant(1)
        )
        let outcomes = await [firstOutcome, secondOutcome]
        XCTAssertEqual(outcomes, [.admitted, .admitted])

        let relaunched = ApplicationSupportInvocationAdmission(fileURL: fixture.fileURL)
        guard case .cooldown = await relaunched.claim(
            library: fixture.firstLibrary,
            at: fixture.instant(1_000)
        ) else { return XCTFail("first Library debit must survive") }
        guard case .cooldown = await relaunched.claim(
            library: fixture.secondLibrary,
            at: fixture.instant(1_000)
        ) else { return XCTFail("second Library debit must survive") }
    }

    func testCorruptOversizedAndSymlinkLedgersFailClosed() async throws {
        for setup in [FixtureSetup.corrupt, .oversized, .symlink] {
            let fixture = try Fixture(setup: setup)
            let admission = ApplicationSupportInvocationAdmission(fileURL: fixture.fileURL)
            let outcome = await admission.claim(
                library: fixture.firstLibrary,
                at: fixture.instant(0)
            )
            XCTAssertEqual(outcome, .unavailable, "\(setup)")
        }
    }
}

private enum FixtureSetup {
    case empty
    case corrupt
    case oversized
    case symlink
}

private final class Fixture: @unchecked Sendable {
    let root: URL
    let fileURL: URL
    let firstLibrary = LibraryScope(
        libraryID: try! LibraryID("lib-20260830T115900000Z-1ABC")
    )
    let secondLibrary = LibraryScope(
        libraryID: try! LibraryID("lib-20260830T115900000Z-2DEF")
    )

    init(setup: FixtureSetup = .empty) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-invocation-admission-\(UUID().uuidString)",
            isDirectory: true
        )
        fileURL = root.appendingPathComponent("invocation-admission.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        switch setup {
        case .empty:
            break
        case .corrupt:
            try Data("{\"schemaVersion\":1,\"entries\":[] ,\"extra\":true}\n".utf8)
                .write(to: fileURL)
        case .oversized:
            try Data(repeating: 0x20, count: 1_048_577).write(to: fileURL)
        case .symlink:
            let target = root.appendingPathComponent("target.json")
            try Data("{}\n".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: target)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func instant(_ offsetMilliseconds: Int) -> UTCInstant {
        let seconds = offsetMilliseconds / 1_000
        let milliseconds = offsetMilliseconds % 1_000
        let minute = seconds / 60
        let second = seconds % 60
        return try! UTCInstant(
            String(
                format: "2026-08-30T12:%02d:%02d.%03dZ",
                minute,
                second,
                milliseconds
            )
        )
    }
}
