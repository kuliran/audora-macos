import Foundation

public enum ContractResource: CaseIterable, Sendable {
    case audioImportFeatureScenarioSchema
    case audioManifestSchema
    case audioNormalizationVectorsSchema
    case chatManifestSchema
    case pendingUserTurnSchema
    case coachMemoryEnvelopeSchema
    case coachContextQuoteSchema
    case coachProviderDescriptorSchema
    case coachRequestSchema
    case coachResponseSchema
    case developmentChatFeatureScenarioSchema
    case libraryFeatureScenarioSchema
    case libraryManifestSchema
    case libraryPreferencesSchema
    case profileHeadSchema
    case readSessionTranscriptsRequestSchema
    case readSessionTranscriptsResponseSchema
    case recordingFeatureScenarioSchema
    case recordingStagingIdentityManifestSchema
    case recordingStagingManifestSchema
    case sessionManifestSchema
    case sessionProcessingFeatureScenarioSchema
    case transcriptRevisionSchema
    case transcriptionCandidateArtifactSchema
    case transcriptionJobManifestSchema
    case transcriptionWorkerMessageSchema
    case transcriptionWorkerRequestSchema

    case audioImportSuccessScenario
    case audioImportSelectionCancelledScenario
    case audioImportNormalizationFailureScenario
    case audioImportCorruptCandidateScenario
    case audioImportInstallFailureScenario
    case audioImportPostcommitFailureScenario
    case audioImportCollisionRegenerationScenario
    case createDevelopmentChatScenario
    case draftSendDiscardDevelopmentChatScenario
    case contextCapacityRecoveryDevelopmentChatScenario
    case renameDevelopmentChatScenario
    case filterDevelopmentChatsScenario
    case relaunchDevelopmentChatScenario
    case staleRenameDevelopmentChatScenario
    case wrongLibraryDevelopmentChatScenario
    case corruptDevelopmentChatScenario
    case newerDevelopmentChatScenario
    case collisionDevelopmentChatScenario
    case providerUnavailableDevelopmentChatScenario
    case suspendedLibrarySwitchDevelopmentChatScenario
    case libraryLaunchNoSelectionScenario
    case libraryCreateScenario
    case libraryRelaunchScenario
    case libraryFailedSwitchScenario
    case libraryCloseReopenScenario
    case libraryRevealScenario
    case libraryExternalOpenScenario
    case libraryNewerRootScenario
    case recordingHonestLiveScenario
    case recordingMuteScenario
    case recordingMuteGapScenario
    case recordingFiveMinuteWarningScenario
    case recordingCountdownScenario
    case recordingDurationLimitScenario
    case recordingUserStopScenario
    case recordingStopLimitRaceScenario
    case recordingCancelScenario
    case recordingConfirmedCancelScenario
    case recordingDiscardFailureScenario
    case recordingStartFailureScenario
    case recordingInterruptionScenario
    case recordingRecoveredSealScenario
    case recordingDiscardOnlyScenario
    case recordingAnotherTakeScenario
    case recordingLateEventsScenario
    case recordingLibrarySwitchScenario
    case sessionProcessingQualifiedSuccessScenario
    case sessionProcessingQualificationBlockedScenario
    case sessionProcessingCandidateRejectedScenario
    case sessionProcessingModelPrepareRetryScenario

    case portableLibraryManifestExample
    case portableLibraryPreferencesExample
    case portableProfileNullExample
    case portableProfileSelectedExample
    case rejectedHalfProfilePointer
    case rejectedWrongLibraryIDPrefix
    case rejectedForbiddenLibraryIDSuffix
    case rejectedPathLikeLibraryID
    case rejectedUnknownPreferenceKey
    case rejectedInvalidLibraryInstant
    case rejectedNegativeProfileGeneration
    case newerPreferencesExample

    case developmentChatExample
    case developmentChatMemoryExample
    case pendingUserTurnExample
    case pendingUserTurnCapacityFailureExample
    case coachContextQuoteExample
    case renamedDevelopmentChatExample
    case sessionAnalysisChatExample
    case rejectedChatExplicitNullOrigin
    case rejectedChatMissingAttachments
    case rejectedNewChatWithOrigin
    case rejectedNewerChatSchema
    case rejectedChatUnknownKey
    case rejectedDanglingMemorySummary

    case importedAudioManifestExample
    case importedSessionManifestExample
    case audioNormalizationVectorsExample
    case rejectedAudioContainerCodecMismatch
    case rejectedNewerAudioManifest
    case rejectedAudioMachinePath
    case rejectedSessionCrossRootHash

    case recordingSessionExample
    case recordingAudioExample
    case recordingMaximumDurationAudioExample
    case recordingCapturingExample
    case recordingRecoverableExample
    case recordingDiscardOnlyExample
    case recordingCommittedExample
    case rejectedRecordingWrongFormat
    case rejectedRecordingZeroSources
    case rejectedRecordingMultipleSources
    case rejectedRecordingWrongSampleRate
    case rejectedRecordingWrongChannelCount
    case rejectedRecordingDurationOverflow
    case rejectedRecordingEmptyReasons
    case rejectedRecordingUnknownKey
    case rejectedRecordingPathLikeSessionID
    case rejectedRecordingInvalidSessionID
    case rejectedRecordingUnorderedIntervals
    case rejectedRecordingOverlappingIntervals
    case rejectedRecordingOutOfBoundsInterval
    case rejectedRecordingMismatchedFingerprint

    case transcriptRevisionExample
    case legacyTranscriptRevisionExample
    case rejectedTranscriptPunctuationWord
    case rejectedTranscriptUTF8Range

    /// Preserves the historical filename-only diagnostic and scenario identity.
    public var rawValue: String {
        switch self {
        case .audioImportFeatureScenarioSchema:
            "AudioImportFeatureScenario.json"
        case .audioManifestSchema:
            "AudioManifest.json"
        case .audioNormalizationVectorsSchema:
            "AudioNormalizationVectors.json"
        case .chatManifestSchema:
            "ChatManifest.json"
        case .pendingUserTurnSchema:
            "PendingUserTurn.json"
        case .coachMemoryEnvelopeSchema:
            "CoachMemoryEnvelope.json"
        case .coachContextQuoteSchema:
            "CoachContextQuote.json"
        case .coachProviderDescriptorSchema:
            "CoachProviderDescriptor.json"
        case .coachRequestSchema:
            "CoachRequest.json"
        case .coachResponseSchema:
            "CoachResponse.json"
        case .developmentChatFeatureScenarioSchema:
            "DevelopmentChatFeatureScenario.json"
        case .libraryFeatureScenarioSchema:
            "LibraryFeatureScenario.json"
        case .libraryManifestSchema:
            "LibraryManifest.json"
        case .libraryPreferencesSchema:
            "LibraryPreferences.json"
        case .profileHeadSchema:
            "ProfileHead.json"
        case .readSessionTranscriptsRequestSchema:
            "ReadSessionTranscriptsRequest.json"
        case .readSessionTranscriptsResponseSchema:
            "ReadSessionTranscriptsResponse.json"
        case .recordingFeatureScenarioSchema:
            "RecordingFeatureScenario.json"
        case .recordingStagingIdentityManifestSchema:
            "RecordingStagingIdentityManifest.json"
        case .recordingStagingManifestSchema:
            "RecordingStagingManifest.json"
        case .sessionManifestSchema:
            "SessionManifest.json"
        case .sessionProcessingFeatureScenarioSchema:
            "SessionProcessingFeatureScenario.json"
        case .transcriptRevisionSchema:
            "TranscriptRevision.json"
        case .transcriptionCandidateArtifactSchema:
            "TranscriptionCandidateArtifact.json"
        case .transcriptionJobManifestSchema:
            "TranscriptionJobManifest.json"
        case .transcriptionWorkerMessageSchema:
            "TranscriptionWorkerMessage.json"
        case .transcriptionWorkerRequestSchema:
            "TranscriptionWorkerRequest.json"
        case .audioImportSuccessScenario:
            "success-retains-and-reopens.v1.json"
        case .audioImportSelectionCancelledScenario:
            "selection-cancelled.v1.json"
        case .audioImportNormalizationFailureScenario:
            "normalization-failure-publishes-nothing.v1.json"
        case .audioImportCorruptCandidateScenario:
            "corrupt-candidate-discarded.v1.json"
        case .audioImportInstallFailureScenario:
            "install-failure-discards-staging.v1.json"
        case .audioImportPostcommitFailureScenario:
            "postcommit-reopen-failure-keeps-session.v1.json"
        case .audioImportCollisionRegenerationScenario:
            "session-id-collision-regenerates.v1.json"
        case .createDevelopmentChatScenario:
            "create-empty-development-chat.v1.json"
        case .draftSendDiscardDevelopmentChatScenario:
            "draft-send-discard.v1.json"
        case .contextCapacityRecoveryDevelopmentChatScenario:
            "context-capacity-recovery.v1.json"
        case .renameDevelopmentChatScenario:
            "rename-preserves-identity.v1.json"
        case .filterDevelopmentChatsScenario:
            "filter-is-pure.v1.json"
        case .relaunchDevelopmentChatScenario:
            "relaunch-reopens-exact-aggregate.v1.json"
        case .staleRenameDevelopmentChatScenario:
            "stale-rename-cannot-overwrite.v1.json"
        case .wrongLibraryDevelopmentChatScenario:
            "wrong-library-load-fails.v1.json"
        case .corruptDevelopmentChatScenario:
            "corrupt-chat-freezes.v1.json"
        case .newerDevelopmentChatScenario:
            "newer-chat-freezes.v1.json"
        case .collisionDevelopmentChatScenario:
            "create-collision-limit.v1.json"
        case .providerUnavailableDevelopmentChatScenario:
            "provider-unavailable-creates-locally.v1.json"
        case .suspendedLibrarySwitchDevelopmentChatScenario:
            "library-switch-during-suspended-load.v1.json"
        case .libraryLaunchNoSelectionScenario:
            "library-launch-no-selection.v1.json"
        case .libraryCreateScenario:
            "create-installs-null-authority.v1.json"
        case .libraryRelaunchScenario:
            "relaunch-restores-persisted-values.v1.json"
        case .libraryFailedSwitchScenario:
            "failed-switch-retains-current.v1.json"
        case .libraryCloseReopenScenario:
            "close-and-reopen-recent.v1.json"
        case .libraryRevealScenario:
            "reveal-is-non-mutating.v1.json"
        case .libraryExternalOpenScenario:
            "external-open-switches-after-success.v1.json"
        case .libraryNewerRootScenario:
            "newer-root-is-read-only.v1.json"
        case .recordingHonestLiveScenario:
            "honest-live-state.v1.json"
        case .recordingMuteScenario:
            "live-mute-acknowledgement.v1.json"
        case .recordingMuteGapScenario:
            "mute-gap-unavailable.v1.json"
        case .recordingFiveMinuteWarningScenario:
            "five-minute-warning.v1.json"
        case .recordingCountdownScenario:
            "one-minute-countdown.v1.json"
        case .recordingDurationLimitScenario:
            "duration-limit-seals.v1.json"
        case .recordingUserStopScenario:
            "user-stop-seals.v1.json"
        case .recordingStopLimitRaceScenario:
            "stop-limit-race.v1.json"
        case .recordingCancelScenario:
            "cancel-keeps-recording.v1.json"
        case .recordingConfirmedCancelScenario:
            "confirmed-cancel-discards.v1.json"
        case .recordingDiscardFailureScenario:
            "discard-failure-honest.v1.json"
        case .recordingStartFailureScenario:
            "start-failure-no-publication.v1.json"
        case .recordingInterruptionScenario:
            "interruption-recovery.v1.json"
        case .recordingRecoveredSealScenario:
            "recovered-seal-idempotent.v1.json"
        case .recordingDiscardOnlyScenario:
            "recovery-discard-only.v1.json"
        case .recordingAnotherTakeScenario:
            "another-take-new-session.v1.json"
        case .recordingLateEventsScenario:
            "late-events-fenced.v1.json"
        case .recordingLibrarySwitchScenario:
            "library-switch-serialized.v1.json"
        case .sessionProcessingQualifiedSuccessScenario:
            "qualified-offline-success.v1.json"
        case .sessionProcessingQualificationBlockedScenario:
            "qualification-blocked-no-fallback.v1.json"
        case .sessionProcessingCandidateRejectedScenario:
            "candidate-rejected-no-publication.v1.json"
        case .sessionProcessingModelPrepareRetryScenario:
            "model-prepare-retry.v1.json"
        case .portableLibraryManifestExample:
            "library.json"
        case .portableLibraryPreferencesExample:
            "preferences.json"
        case .portableProfileNullExample:
            "profile-head-null.json"
        case .portableProfileSelectedExample:
            "profile-head-selected.json"
        case .rejectedHalfProfilePointer:
            "profile-head-half-present.json"
        case .rejectedWrongLibraryIDPrefix:
            "library-wrong-id-prefix.json"
        case .rejectedForbiddenLibraryIDSuffix:
            "library-forbidden-id-suffix.json"
        case .rejectedPathLikeLibraryID:
            "library-path-like-id.json"
        case .rejectedUnknownPreferenceKey:
            "preferences-unknown-key.json"
        case .rejectedInvalidLibraryInstant:
            "library-invalid-instant.json"
        case .rejectedNegativeProfileGeneration:
            "profile-head-negative-generation.json"
        case .newerPreferencesExample:
            "preferences-newer-schema.json"
        case .developmentChatExample:
            "chat.json"
        case .developmentChatMemoryExample:
            "memory.json"
        case .pendingUserTurnExample:
            "pending-user-turn.json"
        case .pendingUserTurnCapacityFailureExample:
            "pending-user-turn-capacity-failure.json"
        case .coachContextQuoteExample:
            "quote.json"
        case .renamedDevelopmentChatExample:
            "renamed-chat.json"
        case .sessionAnalysisChatExample:
            "session-analysis-chat.json"
        case .rejectedChatExplicitNullOrigin:
            "chat-explicit-null-origin.json"
        case .rejectedChatMissingAttachments:
            "chat-missing-attachments.json"
        case .rejectedNewChatWithOrigin:
            "chat-newchat-with-origin.json"
        case .rejectedNewerChatSchema:
            "chat-newer-schema.json"
        case .rejectedChatUnknownKey:
            "chat-unknown-key.json"
        case .rejectedDanglingMemorySummary:
            "memory-dangling-summary.json"
        case .importedAudioManifestExample, .recordingAudioExample:
            "audio.json"
        case .importedSessionManifestExample, .recordingSessionExample:
            "session.json"
        case .audioNormalizationVectorsExample:
            "normalization-vectors.json"
        case .rejectedAudioContainerCodecMismatch:
            "audio-container-codec-mismatch.json"
        case .rejectedNewerAudioManifest:
            "audio-newer-schema.json"
        case .rejectedAudioMachinePath:
            "audio-unknown-machine-path.json"
        case .rejectedSessionCrossRootHash:
            "session-cross-root-hash.json"
        case .recordingMaximumDurationAudioExample:
            "audio-45-minutes.json"
        case .recordingCapturingExample:
            "recording-capturing.json"
        case .recordingRecoverableExample:
            "recording-recoverable.json"
        case .recordingDiscardOnlyExample:
            "recording-discard-only.json"
        case .recordingCommittedExample:
            "recording-committed.json"
        case .rejectedRecordingWrongFormat:
            "audio-wrong-format.json"
        case .rejectedRecordingZeroSources:
            "audio-zero-sources.json"
        case .rejectedRecordingMultipleSources:
            "audio-multiple-sources.json"
        case .rejectedRecordingWrongSampleRate:
            "audio-wrong-sample-rate.json"
        case .rejectedRecordingWrongChannelCount:
            "audio-wrong-channel-count.json"
        case .rejectedRecordingDurationOverflow:
            "audio-duration-overflow.json"
        case .rejectedRecordingEmptyReasons:
            "audio-empty-reasons.json"
        case .rejectedRecordingUnknownKey:
            "audio-unknown-key.json"
        case .rejectedRecordingPathLikeSessionID:
            "session-path-like-id.json"
        case .rejectedRecordingInvalidSessionID:
            "session-invalid-id.json"
        case .rejectedRecordingUnorderedIntervals:
            "audio-interval-unordered.json"
        case .rejectedRecordingOverlappingIntervals:
            "audio-interval-overlap.json"
        case .rejectedRecordingOutOfBoundsInterval:
            "audio-interval-out-of-bounds.json"
        case .rejectedRecordingMismatchedFingerprint:
            "audio-mismatched-fingerprint.json"
        case .transcriptRevisionExample:
            "revision.json"
        case .legacyTranscriptRevisionExample:
            "revision.json"
        case .rejectedTranscriptPunctuationWord:
            "punctuation-as-word.json"
        case .rejectedTranscriptUTF8Range:
            "utf8-range-split.json"
        }
    }

    public var subdirectory: String {
        switch self {
        case .audioImportFeatureScenarioSchema, .audioManifestSchema,
             .audioNormalizationVectorsSchema, .chatManifestSchema,
             .pendingUserTurnSchema,
             .coachMemoryEnvelopeSchema, .coachContextQuoteSchema,
             .coachProviderDescriptorSchema,
             .coachRequestSchema, .coachResponseSchema,
             .developmentChatFeatureScenarioSchema, .libraryFeatureScenarioSchema,
             .libraryManifestSchema, .libraryPreferencesSchema, .profileHeadSchema,
             .readSessionTranscriptsRequestSchema, .readSessionTranscriptsResponseSchema,
             .recordingFeatureScenarioSchema, .recordingStagingIdentityManifestSchema,
             .recordingStagingManifestSchema, .sessionManifestSchema,
             .sessionProcessingFeatureScenarioSchema, .transcriptRevisionSchema,
             .transcriptionCandidateArtifactSchema, .transcriptionJobManifestSchema,
             .transcriptionWorkerMessageSchema, .transcriptionWorkerRequestSchema:
            "Schemas"
        case .audioImportSuccessScenario, .audioImportSelectionCancelledScenario,
             .audioImportNormalizationFailureScenario, .audioImportCorruptCandidateScenario,
             .audioImportInstallFailureScenario, .audioImportPostcommitFailureScenario,
             .audioImportCollisionRegenerationScenario:
            "Scenarios/AudioImport"
        case .createDevelopmentChatScenario, .draftSendDiscardDevelopmentChatScenario,
             .contextCapacityRecoveryDevelopmentChatScenario,
             .renameDevelopmentChatScenario,
             .filterDevelopmentChatsScenario, .relaunchDevelopmentChatScenario,
             .staleRenameDevelopmentChatScenario, .wrongLibraryDevelopmentChatScenario,
             .corruptDevelopmentChatScenario, .newerDevelopmentChatScenario,
             .collisionDevelopmentChatScenario,
             .providerUnavailableDevelopmentChatScenario,
             .suspendedLibrarySwitchDevelopmentChatScenario:
            "Scenarios/Chat"
        case .libraryLaunchNoSelectionScenario:
            "Scenarios"
        case .libraryCreateScenario, .libraryRelaunchScenario,
             .libraryFailedSwitchScenario, .libraryCloseReopenScenario,
             .libraryRevealScenario, .libraryExternalOpenScenario,
             .libraryNewerRootScenario:
            "Scenarios/Library"
        case .recordingHonestLiveScenario, .recordingMuteScenario,
             .recordingMuteGapScenario, .recordingFiveMinuteWarningScenario,
             .recordingCountdownScenario, .recordingDurationLimitScenario,
             .recordingUserStopScenario, .recordingStopLimitRaceScenario,
             .recordingCancelScenario, .recordingConfirmedCancelScenario,
             .recordingDiscardFailureScenario, .recordingStartFailureScenario,
             .recordingInterruptionScenario, .recordingRecoveredSealScenario,
             .recordingDiscardOnlyScenario, .recordingAnotherTakeScenario,
             .recordingLateEventsScenario, .recordingLibrarySwitchScenario:
            "Scenarios/Recording"
        case .sessionProcessingQualifiedSuccessScenario,
             .sessionProcessingQualificationBlockedScenario,
             .sessionProcessingCandidateRejectedScenario,
             .sessionProcessingModelPrepareRetryScenario:
            "Scenarios/SessionProcessing"
        case .portableLibraryManifestExample, .portableLibraryPreferencesExample,
             .portableProfileNullExample, .portableProfileSelectedExample:
            "Examples/PortableLibrary/v1"
        case .rejectedHalfProfilePointer, .rejectedWrongLibraryIDPrefix,
             .rejectedForbiddenLibraryIDSuffix, .rejectedPathLikeLibraryID,
             .rejectedUnknownPreferenceKey, .rejectedInvalidLibraryInstant,
             .rejectedNegativeProfileGeneration, .newerPreferencesExample:
            "Examples/PortableLibrary/v1/rejected"
        case .developmentChatExample, .developmentChatMemoryExample,
             .pendingUserTurnExample, .pendingUserTurnCapacityFailureExample,
             .renamedDevelopmentChatExample, .sessionAnalysisChatExample:
            "Examples/DevelopmentChat/v1"
        case .coachContextQuoteExample:
            "Examples/CoachContext/v1"
        case .rejectedChatExplicitNullOrigin, .rejectedChatMissingAttachments,
             .rejectedNewChatWithOrigin, .rejectedNewerChatSchema,
             .rejectedChatUnknownKey, .rejectedDanglingMemorySummary:
            "Examples/DevelopmentChat/v1/rejected"
        case .importedAudioManifestExample, .importedSessionManifestExample,
             .audioNormalizationVectorsExample:
            "Examples/AudioImport/v1"
        case .rejectedAudioContainerCodecMismatch, .rejectedNewerAudioManifest,
             .rejectedAudioMachinePath, .rejectedSessionCrossRootHash:
            "Examples/AudioImport/v1/rejected"
        case .recordingSessionExample, .recordingAudioExample,
             .recordingMaximumDurationAudioExample, .recordingCapturingExample,
             .recordingRecoverableExample, .recordingDiscardOnlyExample,
             .recordingCommittedExample:
            "Examples/Recording/v1"
        case .rejectedRecordingWrongFormat, .rejectedRecordingZeroSources,
             .rejectedRecordingMultipleSources, .rejectedRecordingWrongSampleRate,
             .rejectedRecordingWrongChannelCount, .rejectedRecordingDurationOverflow,
             .rejectedRecordingEmptyReasons, .rejectedRecordingUnknownKey,
             .rejectedRecordingPathLikeSessionID, .rejectedRecordingInvalidSessionID,
             .rejectedRecordingUnorderedIntervals, .rejectedRecordingOverlappingIntervals,
             .rejectedRecordingOutOfBoundsInterval,
             .rejectedRecordingMismatchedFingerprint:
            "Examples/Recording/v1/rejected"
        case .transcriptRevisionExample:
            "Examples/TranscriptRevision/v2"
        case .legacyTranscriptRevisionExample:
            "Examples/TranscriptRevision/v1"
        case .rejectedTranscriptPunctuationWord, .rejectedTranscriptUTF8Range:
            "Examples/TranscriptRevision/v1/rejected"
        }
    }

    public var bundlePath: String {
        "\(subdirectory)/\(rawValue)"
    }
}

public enum ContractResourceError: Error, Equatable, Sendable {
    case missing(ContractResource)
}

public enum ContractResources {
    public static func data(for resource: ContractResource) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: resource.rawValue,
            withExtension: nil,
            subdirectory: resource.subdirectory
        ) else {
            throw ContractResourceError.missing(resource)
        }

        return try Data(contentsOf: url)
    }
}
