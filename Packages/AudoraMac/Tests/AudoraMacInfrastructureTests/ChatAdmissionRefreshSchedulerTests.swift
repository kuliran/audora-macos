@testable import AudoraMacInfrastructure
import AudoraDomain
import Foundation
import XCTest

final class ChatAdmissionRefreshSchedulerTests: XCTestCase {
    func testWallClockDeadlineIsConvertedToDeterministicSleepDuration() async throws {
        let now = try XCTUnwrap(Self.date("2026-08-30T12:00:00.000Z"))
        let recorder = SleepDurationRecorder()
        let scheduler = SystemChatAdmissionRefreshScheduler(
            now: { now },
            sleep: { nanoseconds in await recorder.record(nanoseconds) }
        )

        try await scheduler.sleep(
            until: UTCInstant("2026-08-30T12:00:01.500Z")
        )

        let values = await recorder.values
        XCTAssertEqual(values, [1_500_000_000])
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

private actor SleepDurationRecorder {
    private(set) var values: [UInt64] = []

    func record(_ value: UInt64) {
        values.append(value)
    }
}
