import Foundation

public enum ContractResource: String, CaseIterable, Sendable {
    case audioManifestSchema = "AudioManifest.json"
    case coachProviderDescriptorSchema = "CoachProviderDescriptor.json"
    case coachRequestSchema = "CoachRequest.json"
    case coachResponseSchema = "CoachResponse.json"
    case libraryFeatureScenarioSchema = "LibraryFeatureScenario.json"
    case libraryManifestSchema = "LibraryManifest.json"
    case libraryPreferencesSchema = "LibraryPreferences.json"
    case profileHeadSchema = "ProfileHead.json"
    case recordingFeatureScenarioSchema = "RecordingFeatureScenario.json"
    case recordingStagingIdentityManifestSchema = "RecordingStagingIdentityManifest.json"
    case recordingStagingManifestSchema = "RecordingStagingManifest.json"
    case readSessionTranscriptsRequestSchema = "ReadSessionTranscriptsRequest.json"
    case readSessionTranscriptsResponseSchema = "ReadSessionTranscriptsResponse.json"
    case sessionManifestSchema = "SessionManifest.json"
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
    case recordingSessionExample = "session.json"
    case recordingAudioExample = "audio.json"
    case recordingMaximumDurationAudioExample = "audio-45-minutes.json"
    case recordingCapturingExample = "recording-capturing.json"
    case recordingRecoverableExample = "recording-recoverable.json"
    case recordingDiscardOnlyExample = "recording-discard-only.json"
    case recordingCommittedExample = "recording-committed.json"
    case rejectedRecordingWrongFormat = "audio-wrong-format.json"
    case rejectedRecordingZeroSources = "audio-zero-sources.json"
    case rejectedRecordingMultipleSources = "audio-multiple-sources.json"
    case rejectedRecordingWrongSampleRate = "audio-wrong-sample-rate.json"
    case rejectedRecordingWrongChannelCount = "audio-wrong-channel-count.json"
    case rejectedRecordingDurationOverflow = "audio-duration-overflow.json"
    case rejectedRecordingEmptyReasons = "audio-empty-reasons.json"
    case rejectedRecordingUnknownKey = "audio-unknown-key.json"
    case rejectedRecordingPathLikeSessionID = "session-path-like-id.json"
    case rejectedRecordingInvalidSessionID = "session-invalid-id.json"
    case rejectedRecordingUnorderedIntervals = "audio-interval-unordered.json"
    case rejectedRecordingOverlappingIntervals = "audio-interval-overlap.json"
    case rejectedRecordingOutOfBoundsInterval = "audio-interval-out-of-bounds.json"
    case rejectedRecordingMismatchedFingerprint = "audio-mismatched-fingerprint.json"
    case recordingHonestLiveScenario = "honest-live-state.v1.json"
    case recordingMuteScenario = "live-mute-acknowledgement.v1.json"
    case recordingMuteGapScenario = "mute-gap-unavailable.v1.json"
    case recordingFiveMinuteWarningScenario = "five-minute-warning.v1.json"
    case recordingCountdownScenario = "one-minute-countdown.v1.json"
    case recordingDurationLimitScenario = "duration-limit-seals.v1.json"
    case recordingUserStopScenario = "user-stop-seals.v1.json"
    case recordingStopLimitRaceScenario = "stop-limit-race.v1.json"
    case recordingCancelScenario = "cancel-keeps-recording.v1.json"
    case recordingConfirmedCancelScenario = "confirmed-cancel-discards.v1.json"
    case recordingDiscardFailureScenario = "discard-failure-honest.v1.json"
    case recordingStartFailureScenario = "start-failure-no-publication.v1.json"
    case recordingInterruptionScenario = "interruption-recovery.v1.json"
    case recordingRecoveredSealScenario = "recovered-seal-idempotent.v1.json"
    case recordingDiscardOnlyScenario = "recovery-discard-only.v1.json"
    case recordingAnotherTakeScenario = "another-take-new-session.v1.json"
    case recordingLateEventsScenario = "late-events-fenced.v1.json"
    case recordingLibrarySwitchScenario = "library-switch-serialized.v1.json"
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
