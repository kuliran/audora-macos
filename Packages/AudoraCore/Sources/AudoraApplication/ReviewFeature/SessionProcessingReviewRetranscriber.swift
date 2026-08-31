import AudoraDomain

/// Adapts the existing Session-processing command boundary for Review. Worker
/// lifecycle, qualification, progress, recovery, and publication remain owned
/// by SessionProcessingFeature.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct SessionProcessingReviewRetranscriber: ReviewRetranscriptionPort {
    private let feature: any SessionProcessingFeature

    public init(feature: any SessionProcessingFeature) {
        self.feature = feature
    }

    public func retranscribe(
        _ selection: ReviewSelection
    ) async -> ReviewRetranscriptionResult {
        let processingSelection = SessionProcessingSelection(
            scope: selection.scope,
            sessionID: selection.sessionID
        )
        await feature.send(.selectSession(processingSelection))
        switch await feature.currentState {
        case .ready, .failed:
            break
        case .unavailable:
            return .unavailable
        case .preparing, .running, .validating, .completed, .recoveryRequired:
            return .failed
        }

        await feature.send(.start)
        switch await feature.currentState {
        case let .completed(snapshot) where snapshot.sessionID == selection.sessionID:
            return .completed
        case .unavailable:
            return .unavailable
        case .ready, .preparing, .running, .validating, .completed, .failed,
             .recoveryRequired:
            return .failed
        }
    }
}
