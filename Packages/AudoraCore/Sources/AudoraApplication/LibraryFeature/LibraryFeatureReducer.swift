import AudoraDomain

enum LibraryFeatureEffect: Equatable, Sendable {
    case resolveInitialLibrary
}

enum LibraryFeatureReducer {
    static let initialState = LibraryFeatureState(phase: .awaitingBootstrap)

    static func effects(
        for command: LibraryCommand,
        state: LibraryFeatureState
    ) -> [LibraryFeatureEffect] {
        switch (command, state.phase) {
        case (.start, .awaitingBootstrap):
            [.resolveInitialLibrary]
        case (.start, .noLibrarySelected):
            []
        }
    }

    static func reduce(
        _ state: LibraryFeatureState,
        availability: LibraryAvailability
    ) -> LibraryFeatureState {
        switch availability {
        case .noLibrarySelected:
            LibraryFeatureState(phase: .noLibrarySelected)
        }
    }
}
