enum LibraryFeatureReducer {
    static let initialState = LibraryFeatureState(selection: .awaitingBootstrap)

    static func begin(
        _ activity: LibraryFeatureState.Activity,
        from state: LibraryFeatureState
    ) -> LibraryFeatureState {
        LibraryFeatureState(selection: state.selection, activity: activity)
    }

    static func completeOpen(
        _ outcome: LibraryOpenOutcome,
        previous: LibraryFeatureState.Selection
    ) -> LibraryFeatureState {
        switch outcome {
        case let .noLibrarySelected(recentAvailable):
            LibraryFeatureState(selection: .noLibrarySelected(recentAvailable: recentAvailable))
        case let .opened(snapshot, notice):
            LibraryFeatureState(selection: .active(snapshot), notice: notice)
        case let .readOnly(snapshot, reason, notice):
            LibraryFeatureState(selection: .readOnly(snapshot, reason: reason), notice: notice)
        case .cancelled:
            LibraryFeatureState(selection: resolvedSelectionAfterNoResult(previous))
        case let .failed(notice):
            LibraryFeatureState(
                selection: resolvedSelectionAfterNoResult(previous),
                notice: notice
            )
        }
    }

    static func completeReveal(
        _ outcome: LibraryActionOutcome,
        previous: LibraryFeatureState.Selection
    ) -> LibraryFeatureState {
        switch outcome {
        case .succeeded:
            LibraryFeatureState(selection: previous)
        case let .failed(notice):
            LibraryFeatureState(selection: previous, notice: notice)
        }
    }

    static func completeClose(
        _ outcome: LibraryActionOutcome,
        previous: LibraryFeatureState.Selection
    ) -> LibraryFeatureState {
        switch outcome {
        case let .succeeded(recentAvailable):
            LibraryFeatureState(selection: .noLibrarySelected(recentAvailable: recentAvailable))
        case let .failed(notice):
            LibraryFeatureState(selection: previous, notice: notice)
        }
    }

    private static func resolvedSelectionAfterNoResult(
        _ previous: LibraryFeatureState.Selection
    ) -> LibraryFeatureState.Selection {
        if case .awaitingBootstrap = previous {
            return .noLibrarySelected(recentAvailable: false)
        }
        return previous
    }
}
