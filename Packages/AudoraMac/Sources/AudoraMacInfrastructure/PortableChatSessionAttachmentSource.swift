@_spi(CoachContextQualification) import AudoraApplication
import AudoraDomain

/// Portable-library adapter for verified immutable transcript evidence. It does
/// not estimate provider tokens or choose a delivery form.
@_spi(CoachContextQualification)
public actor PortableChatSessionAttachmentSource:
    ChatSessionAttachmentEvidenceSource,
    CoachEvidenceUsePolicySource
{
    private let workspace: PortableLibraryWorkspace

    public init(workspace: PortableLibraryWorkspace) {
        self.workspace = workspace
    }

    public func forEachEvidence(
        in library: LibraryScope,
        _ visit: @escaping @Sendable (ChatAttachmentEvidence) throws -> Void
    ) async -> ChatAttachmentEvidenceTraversalOutcome {
        let result: ActiveLibraryOperationResult<ChatAttachmentEvidenceTraversalOutcome> =
            await workspace.performActiveReadWriteOperation(in: library) { root in
                do {
                    try PortableTranscriptRevisionRepository(
                        root: root,
                        libraryID: library.libraryID
                    ).forEachChatAttachmentEvidenceSynchronously(
                        visit
                    )
                    return .completed
                } catch {
                    return .failed
                }
            }
        switch result {
        case let .performed(outcome): return outcome
        case .readOnly: return .readOnlyLibrary
        case .unavailable: return .failed
        }
    }

    public func forEachResolvedEvidence(
        _ attachments: ChatAttachments,
        in library: LibraryScope,
        _ visit: @escaping @Sendable (ResolvedChatAttachmentEvidence) throws -> Void
    ) async -> ChatAttachmentEvidenceTraversalOutcome {
        let result: ActiveLibraryOperationResult<ChatCreationEvidenceAuthority> =
            await workspace.issueChatCreationEvidenceAuthority(in: library) {
                root in
                do {
                    return try PortableTranscriptRevisionRepository(
                        root: root,
                        libraryID: library.libraryID
                    ).forEachResolvedChatAttachmentEvidenceSynchronously(
                        attachments,
                        visit
                    )
                } catch {
                    return nil
                }
            }
        switch result {
        case let .performed(authority):
            return .completedWithAuthority(authority)
        case .readOnly: return .readOnlyLibrary
        case .unavailable: return .failed
        }
    }

    public func resolveUsePolicies(
        for sources: [CoachEvidencePolicySourceIdentity],
        in library: LibraryScope
    ) async -> [CoachEvidenceUsePolicyResolution] {
        guard !sources.isEmpty else { return [] }
        let result: ActiveLibraryOperationResult<[
            CoachEvidenceUsePolicyResolution
        ]> = await workspace.performActiveReadWriteOperation(in: library) { root in
            PortableTranscriptRevisionRepository(
                root: root,
                libraryID: library.libraryID
            ).resolveCoachEvidenceUsePoliciesSynchronously(sources)
        }
        switch result {
        case let .performed(resolutions):
            return resolutions
        case .readOnly, .unavailable:
            return sources.map(CoachEvidenceUsePolicyResolution.unavailable)
        }
    }
}
