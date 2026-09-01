import AudoraApplication
import AudoraDomain
import Combine
import Foundation

@MainActor
public final class ReviewPresentationModel: ObservableObject {
    @Published public private(set) var state: ReviewFeatureState?

    private let feature: any ReviewFeature
    private var hasStarted = false

    public init(feature: any ReviewFeature) {
        self.feature = feature
    }

    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        var states = feature.states.makeAsyncIterator()
        while !Task.isCancelled, let next = await states.next() {
            state = next
        }
    }

    public func selectSession(_ selection: ReviewSelection) {
        send(.selectSession(selection))
    }

    public func clearSelection() {
        send(.clearSelection)
    }

    public func refresh() {
        send(.refresh)
    }

    public func play() {
        send(.play)
    }

    public func pause() {
        send(.pause)
    }

    public func setAnnotationsVisible(_ visible: Bool) {
        send(.setAnnotationsVisible(visible))
    }

    public func seek(lineID: TranscriptLineID, utf8ByteOffset: Int) {
        send(.seek(lineID: lineID, utf8ByteOffset: utf8ByteOffset))
    }

    public func selectRevision(_ revisionID: TranscriptRevisionID) {
        guard case let .ready(snapshot) = state,
              snapshot.revisionIDs.contains(revisionID)
        else { return }
        send(
            .selectRevision(
                revisionID,
                expectedSelectedRevisionID: snapshot.selectedRevisionID
            )
        )
    }

    public func retranscribe() {
        send(.retranscribe)
    }

    public static func audioEventAccessibilityLabel(
        for event: TranscriptAudioEvent
    ) -> String {
        let title = switch event.category {
        case .nonSpeech: "Non-speech"
        case .silentPause: "Pause"
        case .untranscribedVoicedInterval: "Untranscribed voice"
        case .muted: "Muted"
        case .captureGap: "Capture gap"
        }
        return "\(title) \(formatAudioEventTime(event.timeRange.startMilliseconds))–" +
            formatAudioEventTime(event.timeRange.endMilliseconds)
    }

    private func send(_ command: ReviewCommand) {
        Task { await feature.send(command) }
    }

    private static func formatAudioEventTime(_ milliseconds: UInt64) -> String {
        let totalSeconds = milliseconds / 1_000
        return String(
            format: "%02llu:%02llu.%03llu",
            totalSeconds / 60,
            totalSeconds % 60,
            milliseconds % 1_000
        )
    }
}
