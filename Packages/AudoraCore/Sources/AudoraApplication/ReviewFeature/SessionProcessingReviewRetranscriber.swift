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
        guard await feature.send(.selectSession(processingSelection)) else {
            return .failed
        }
        guard let selectedState = await feature.currentSessionProcessingState()
        else {
            return .unavailable
        }
        let launchCommand: SessionProcessingCommand
        switch selectedState {
        case .ready, .completed:
            launchCommand = .start
        case let .failed(snapshot):
            guard snapshot.actions.contains(.retry) else { return .failed }
            launchCommand = .retry
        case let .cancelled(snapshot), let .interrupted(snapshot):
            guard snapshot.actions.contains(.retry) else { return .failed }
            launchCommand = .retry
        case .unavailable:
            return .unavailable
        case .preparing, .queued, .running, .cancelling, .validating,
             .recoveryRequired:
            return .failed
        }

        guard await feature.send(launchCommand) else { return .failed }
        guard let completedState = await feature.currentSessionProcessingState()
        else {
            return .unavailable
        }
        switch completedState {
        case let .completed(snapshot) where snapshot.sessionID == selection.sessionID:
            return .completed
        case .unavailable:
            return .unavailable
        case .ready, .preparing, .queued, .running, .cancelling, .validating,
             .completed, .failed, .cancelled, .interrupted, .recoveryRequired:
            return .failed
        }
    }
}
