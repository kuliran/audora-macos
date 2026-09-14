@testable @_spi(CoachContextQualification) import AudoraApplication
import AudoraDomain
import Foundation

/// Exact attachment projection used by the Chat contract scenarios. Unlike the
/// empty-only helper above, every selected pin is represented in the prepared
/// exchange, so the fixture cannot silently drop evidence.
struct ScenarioChatAttachmentCapacityPreparer:
    ChatAttachmentCapacityPreparing
{
    private let configuration: CoachContextConfigurationStamp
    private let evidenceAuthority: ChatCreationEvidenceAuthority

    init(
        configuration: CoachContextConfigurationStamp,
        evidenceAuthority: ChatCreationEvidenceAuthority
    ) {
        self.configuration = configuration
        self.evidenceAuthority = evidenceAuthority
    }

    func prepareCapacityAttachments(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentCapacityPreparationOutcome {
        let prepared = attachments.values.map { attachment in
            PreparedCoachAttachment.inline(
                requestValue: .object([
                    "sessionAttachmentId": .string(
                        attachment.attachmentID.rawValue
                    ),
                    "displayLabel": .string("Synthetic Session"),
                    "transcript": .object([
                        "text": .string(String(repeating: "x", count: 32)),
                    ]),
                ])
            )
        }
        return .prepared(
            prepared,
            configuration: configuration,
            evidenceAuthority: evidenceAuthority
        )
    }
}
