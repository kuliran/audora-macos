import Foundation

/// Pure timeline arithmetic shared by transcription and lossless recording.
/// Callback timestamps have minor scheduling jitter; only a larger positive
/// discontinuity is represented as silence/a new transcription window.
enum AudioTimelineGapReconciler {
    static let toleranceSeconds: TimeInterval = 0.2

    static func missingFrames(
        reportedStartTime: TimeInterval,
        expectedStartTime: TimeInterval,
        sampleRate: Double
    ) -> Int64 {
        guard reportedStartTime.isFinite,
              expectedStartTime.isFinite,
              sampleRate.isFinite,
              sampleRate > 0 else {
            return 0
        }

        let gap = reportedStartTime - expectedStartTime
        guard gap > toleranceSeconds else { return 0 }

        let frameCount = gap * sampleRate
        guard frameCount.isFinite, frameCount > 0 else { return 0 }
        if frameCount >= Double(Int64.max) { return Int64.max }
        return Int64(frameCount.rounded())
    }
}
