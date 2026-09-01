import AudoraApplication
import AudoraDomain

/// Portable-library adapter for verified immutable transcript evidence. It does
/// not estimate provider tokens or choose a delivery form.
public actor PortableChatSessionAttachmentSource: ChatSessionAttachmentEvidenceSource {
    private let workspace: PortableLibraryWorkspace

    public init(workspace: PortableLibraryWorkspace) {
        self.workspace = workspace
    }

    public func loadEvidence(
        in library: LibraryScope
    ) async -> ChatAttachmentEvidenceCatalogOutcome {
        let result: ActiveLibraryOperationResult<ChatAttachmentEvidenceCatalogOutcome> =
            await workspace.performActiveReadWriteOperation(in: library) { root in
                do {
                    return .loaded(
                        try PortableTranscriptRevisionRepository(
                            root: root,
                            libraryID: library.libraryID
                        ).loadChatAttachmentEvidenceCatalogSynchronously()
                    )
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

    public func resolveEvidence(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentEvidenceResolutionOutcome {
        let result: ActiveLibraryOperationResult<ChatAttachmentEvidenceResolutionOutcome> =
            await workspace.performActiveReadWriteOperation(in: library) { root in
                .resolved(
                    PortableTranscriptRevisionRepository(
                        root: root,
                        libraryID: library.libraryID
                    ).resolveChatAttachmentEvidenceSynchronously(attachments)
                )
            }
        switch result {
        case let .performed(outcome): return outcome
        case .readOnly: return .readOnlyLibrary
        case .unavailable: return .failed
        }
    }
}
