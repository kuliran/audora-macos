import AudoraApplication
import AudoraDomain

/// Portable-library adapter for the Chat creation picker and immutable reopen.
/// Filesystem details and transcript content remain behind this Application seam.
public actor PortableChatSessionAttachmentSource: ChatSessionAttachmentSource {
    private let workspace: PortableLibraryWorkspace

    public init(workspace: PortableLibraryWorkspace) {
        self.workspace = workspace
    }

    public func loadCandidates(
        in library: LibraryScope
    ) async -> ChatAttachmentCatalogOutcome {
        let result: ActiveLibraryOperationResult<ChatAttachmentCatalogOutcome> =
            await workspace.performActiveReadWriteOperation(in: library) { root in
                do {
                    return .loaded(
                        try PortableTranscriptRevisionRepository(
                            root: root,
                            libraryID: library.libraryID
                        ).loadChatAttachmentCatalogSynchronously()
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

    public func resolve(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome {
        let result: ActiveLibraryOperationResult<ChatAttachmentResolutionOutcome> =
            await workspace.performActiveReadWriteOperation(in: library) { root in
                .resolved(
                    PortableTranscriptRevisionRepository(
                        root: root,
                        libraryID: library.libraryID
                    ).resolveChatAttachmentsSynchronously(attachments)
                )
            }
        switch result {
        case let .performed(outcome): return outcome
        case .readOnly: return .readOnlyLibrary
        case .unavailable: return .failed
        }
    }
}
