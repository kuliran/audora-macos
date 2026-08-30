import Foundation

public enum ContractResource: String, CaseIterable, Sendable {
    case chatManifestSchema = "ChatManifest.json"
    case coachMemoryEnvelopeSchema = "CoachMemoryEnvelope.json"
    case coachProviderDescriptorSchema = "CoachProviderDescriptor.json"
    case coachRequestSchema = "CoachRequest.json"
    case coachResponseSchema = "CoachResponse.json"
    case developmentChatFeatureScenarioSchema = "DevelopmentChatFeatureScenario.json"
    case libraryFeatureScenarioSchema = "LibraryFeatureScenario.json"
    case libraryManifestSchema = "LibraryManifest.json"
    case libraryPreferencesSchema = "LibraryPreferences.json"
    case profileHeadSchema = "ProfileHead.json"
    case readSessionTranscriptsRequestSchema = "ReadSessionTranscriptsRequest.json"
    case readSessionTranscriptsResponseSchema = "ReadSessionTranscriptsResponse.json"
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
    case developmentChatExample = "chat.json"
    case developmentChatMemoryExample = "memory.json"
    case renamedDevelopmentChatExample = "renamed-chat.json"
    case sessionAnalysisChatExample = "session-analysis-chat.json"
    case rejectedChatExplicitNullOrigin = "chat-explicit-null-origin.json"
    case rejectedChatMissingAttachments = "chat-missing-attachments.json"
    case rejectedNewChatWithOrigin = "chat-newchat-with-origin.json"
    case rejectedNewerChatSchema = "chat-newer-schema.json"
    case rejectedChatUnknownKey = "chat-unknown-key.json"
    case rejectedDanglingMemorySummary = "memory-dangling-summary.json"
    case createDevelopmentChatScenario = "create-empty-development-chat.v1.json"
    case renameDevelopmentChatScenario = "rename-preserves-identity.v1.json"
    case filterDevelopmentChatsScenario = "filter-is-pure.v1.json"
    case relaunchDevelopmentChatScenario = "relaunch-reopens-exact-aggregate.v1.json"
    case staleRenameDevelopmentChatScenario = "stale-rename-cannot-overwrite.v1.json"
    case wrongLibraryDevelopmentChatScenario = "wrong-library-load-fails.v1.json"
    case corruptDevelopmentChatScenario = "corrupt-chat-freezes.v1.json"
    case newerDevelopmentChatScenario = "newer-chat-freezes.v1.json"
    case collisionDevelopmentChatScenario = "create-collision-limit.v1.json"
    case providerUnavailableDevelopmentChatScenario = "provider-unavailable-creates-locally.v1.json"
    case suspendedLibrarySwitchDevelopmentChatScenario = "library-switch-during-suspended-load.v1.json"
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
