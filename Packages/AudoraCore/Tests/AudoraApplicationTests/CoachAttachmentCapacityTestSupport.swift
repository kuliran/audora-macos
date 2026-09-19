@testable @_spi(CoachContextQualification) import AudoraApplication
import AudoraDomain
import Foundation

/// Test-only attachment authority for source fixtures that intentionally model
/// an exact qualified configuration but have no attachment persistence adapter.
/// It can authorize only the absence of attachments; selected evidence must go
/// through a real `ChatAttachmentCapacityPreparing` test adapter.
struct EmptyOnlyChatAttachmentCapacityPreparer:
    ChatAttachmentCapacityPreparing
{
    private let configuration: CoachContextConfigurationStamp
    private let evidenceAuthority: ChatCreationEvidenceAuthority

    init(
        configurationAuthorityID: UUID,
        configurationGeneration: UInt64,
        evidenceAuthorityID: UUID = UUID()
    ) {
        configuration = CoachContextConfigurationStamp(
            authorityID: configurationAuthorityID,
            generation: configurationGeneration
        )
        evidenceAuthority = ChatCreationEvidenceAuthority(
            portableOpaqueIdentifier: evidenceAuthorityID
        )
    }

    func prepareCapacityAttachments(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentCapacityPreparationOutcome {
        guard attachments == .empty else { return .attachmentUnavailable }
        return .prepared(
            [],
            configuration: configuration,
            evidenceAuthority: evidenceAuthority
        )
    }
}

extension DefaultCoachContextFeature {
    init(
        testSourceWithNoAttachments source: any CoachContextSnapshotPort,
        configurationGeneration: UInt64,
        configurationAuthorityID: UUID = UUID(),
        evidenceUsePolicySource: (any CoachEvidenceUsePolicySource)? = nil
    ) {
        self.init(
            source: source,
            attachmentCapacityPreparer: EmptyOnlyChatAttachmentCapacityPreparer(
                configurationAuthorityID: configurationAuthorityID,
                configurationGeneration: configurationGeneration
            ),
            evidenceUsePolicySource: evidenceUsePolicySource,
            configurationAuthorityID: configurationAuthorityID
        )
    }
}
