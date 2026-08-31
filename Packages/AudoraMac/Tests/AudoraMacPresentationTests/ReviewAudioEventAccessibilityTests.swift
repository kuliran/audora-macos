import AudoraDomain
import AudoraMacPresentation
import XCTest

@MainActor
final class ReviewAudioEventAccessibilityTests: XCTestCase {
    func testAudioEventAccessibilityLabelPreservesMeasuredMilliseconds() throws {
        let event = TranscriptAudioEvent(
            audioEventID: try AudioEventID("a000000"),
            category: .silentPause,
            audioSourceID: .microphone,
            timeRange: try SessionTimeRange(
                startMilliseconds: 25,
                endMilliseconds: 50,
                sessionDurationMilliseconds: 1_000
            )
        )

        XCTAssertEqual(
            ReviewPresentationModel.audioEventAccessibilityLabel(for: event),
            "Pause 00:00.025–00:00.050"
        )
    }
}
