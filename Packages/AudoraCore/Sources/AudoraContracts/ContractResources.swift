import Foundation

public enum ContractResource: String, CaseIterable, Sendable {
    case coachProviderDescriptorSchema = "CoachProviderDescriptor.json"
    case coachRequestSchema = "CoachRequest.json"
    case coachResponseSchema = "CoachResponse.json"
    case audioImportFeatureScenarioSchema = "AudioImportFeatureScenario.json"
    case audioManifestSchema = "AudioManifest.json"
    case audioNormalizationVectorsSchema = "AudioNormalizationVectors.json"
    case libraryFeatureScenarioSchema = "LibraryFeatureScenario.json"
    case libraryManifestSchema = "LibraryManifest.json"
    case libraryPreferencesSchema = "LibraryPreferences.json"
    case profileHeadSchema = "ProfileHead.json"
    case readSessionTranscriptsRequestSchema = "ReadSessionTranscriptsRequest.json"
    case readSessionTranscriptsResponseSchema = "ReadSessionTranscriptsResponse.json"
    case sessionManifestSchema = "SessionManifest.json"
    case audioImportSuccessScenario = "success-retains-and-reopens.v1.json"
    case audioImportSelectionCancelledScenario = "selection-cancelled.v1.json"
    case audioImportNormalizationFailureScenario = "normalization-failure-publishes-nothing.v1.json"
    case audioImportCorruptCandidateScenario = "corrupt-candidate-discarded.v1.json"
    case audioImportInstallFailureScenario = "install-failure-discards-staging.v1.json"
    case audioImportPostcommitFailureScenario = "postcommit-reopen-failure-keeps-session.v1.json"
    case audioImportCollisionRegenerationScenario = "session-id-collision-regenerates.v1.json"
    case libraryLaunchNoSelectionScenario = "library-launch-no-selection.v1.json"
    case libraryCreateScenario = "create-installs-null-authority.v1.json"
    case libraryRelaunchScenario = "relaunch-restores-persisted-values.v1.json"
    case libraryFailedSwitchScenario = "failed-switch-retains-current.v1.json"
    case libraryCloseReopenScenario = "close-and-reopen-recent.v1.json"
    case libraryRevealScenario = "reveal-is-non-mutating.v1.json"
    case libraryExternalOpenScenario = "external-open-switches-after-success.v1.json"
    case libraryNewerRootScenario = "newer-root-is-read-only.v1.json"
    case portableLibraryManifestExample = "library.json"
    case portableLibraryPreferencesExample = "preferences.json"
    case portableProfileNullExample = "profile-head-null.json"
    case portableProfileSelectedExample = "profile-head-selected.json"
    case rejectedHalfProfilePointer = "profile-head-half-present.json"
    case rejectedWrongLibraryIDPrefix = "library-wrong-id-prefix.json"
    case rejectedForbiddenLibraryIDSuffix = "library-forbidden-id-suffix.json"
    case rejectedPathLikeLibraryID = "library-path-like-id.json"
    case rejectedUnknownPreferenceKey = "preferences-unknown-key.json"
    case rejectedInvalidLibraryInstant = "library-invalid-instant.json"
    case rejectedNegativeProfileGeneration = "profile-head-negative-generation.json"
    case newerPreferencesExample = "preferences-newer-schema.json"
    case importedAudioManifestExample = "audio.json"
    case importedSessionManifestExample = "session.json"
    case audioNormalizationVectorsExample = "normalization-vectors.json"
    case rejectedAudioContainerCodecMismatch = "audio-container-codec-mismatch.json"
    case rejectedNewerAudioManifest = "audio-newer-schema.json"
    case rejectedAudioMachinePath = "audio-unknown-machine-path.json"
    case rejectedSessionCrossRootHash = "session-cross-root-hash.json"
}

public enum ContractResourceError: Error, Equatable, Sendable {
    case missing(ContractResource)
}

public enum ContractResources {
    public static func data(for resource: ContractResource) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: resource.rawValue,
            withExtension: nil
        ) else {
            throw ContractResourceError.missing(resource)
        }

        return try Data(contentsOf: url)
    }
}
