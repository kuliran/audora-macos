public struct LibraryInteractionAvailability: Equatable, Sendable {
    public let canRevealLibrary: Bool
    public let canMutateLibrarySelection: Bool
    public let canUseAudioImportControls: Bool
    public let canUseRecordingControls: Bool

    public init(
        canRevealLibrary: Bool,
        canMutateLibrarySelection: Bool,
        canUseAudioImportControls: Bool,
        canUseRecordingControls: Bool
    ) {
        self.canRevealLibrary = canRevealLibrary
        self.canMutateLibrarySelection = canMutateLibrarySelection
        self.canUseAudioImportControls = canUseAudioImportControls
        self.canUseRecordingControls = canUseRecordingControls
    }

    public static let unavailable = LibraryInteractionAvailability(
        canRevealLibrary: false,
        canMutateLibrarySelection: false,
        canUseAudioImportControls: false,
        canUseRecordingControls: false
    )
}

/// Application-owned admission policy for interactions that share one
/// Library. Reveal is observational and remains available while import or
/// Recording owns mutation authority; changing Library selection does not.
public enum LibraryInteractionPolicy {
    public static func availability(
        library: LibraryFeatureState?,
        audioImport: AudioImportFeatureState?,
        recording: RecordingFeatureState
    ) -> LibraryInteractionAvailability {
        guard let library, library.activity == nil else { return .unavailable }

        let hasSelectedLibrary: Bool
        let hasWritableLibrary: Bool
        switch library.selection {
        case .active:
            hasSelectedLibrary = true
            hasWritableLibrary = true
        case .readOnly:
            hasSelectedLibrary = true
            hasWritableLibrary = false
        case .awaitingBootstrap, .noLibrarySelected:
            hasSelectedLibrary = false
            hasWritableLibrary = false
        }

        let importOwnsMutation = audioImport?.isImporting == true
        let recordingOwnsMutation = recording.ownsLibraryMutationAuthority
        return LibraryInteractionAvailability(
            canRevealLibrary: hasSelectedLibrary,
            canMutateLibrarySelection: !importOwnsMutation && !recordingOwnsMutation,
            canUseAudioImportControls: hasWritableLibrary && !recordingOwnsMutation,
            canUseRecordingControls: hasWritableLibrary && !importOwnsMutation
        )
    }
}

private extension RecordingFeatureState {
    var ownsLibraryMutationAuthority: Bool {
        switch self {
        case .selectingLibrary, .starting, .active, .finishing, .sealing,
             .recoveryRequired, .resolvingRecovery:
            true
        case .unavailable, .idle, .completed, .failed:
            false
        }
    }
}
