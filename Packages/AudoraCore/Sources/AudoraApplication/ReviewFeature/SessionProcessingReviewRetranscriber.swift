import AudoraDomain

/// Adapts the existing Session-processing command boundary for Review. Worker
/// lifecycle, qualification, progress, recovery, and publication remain owned
/// by SessionProcessingFeature.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct SessionProcessingReviewRetranscriber: ReviewRetranscriptionPort {
    private let feature: any ApplicationSessionProcessingFeature

    public init(feature: any ApplicationSessionProcessingFeature) {
        self.feature = feature
    }

    public func retranscribe(
        _ selection: ReviewSelection
    ) async -> ReviewRetranscriptionResult {
        let processingSelection = SessionProcessingSelection(
            scope: selection.scope,
            sessionID: selection.sessionID
        )
        return switch await feature.retranscribeExactly(processingSelection) {
        case .completed: .completed
        case .unavailable: .unavailable
        case .failed: .failed
        }
    }
}
