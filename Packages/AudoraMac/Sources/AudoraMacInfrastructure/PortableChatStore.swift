@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
import Foundation

public actor PortableChatStore: ChatStorePort {
    private let persistence: PortableChatPersistence
    private let workspace: PortableLibraryWorkspace

    public init(
        persistence: PortableChatPersistence = PortableChatPersistence(),
        workspace: PortableLibraryWorkspace
    ) {
        self.persistence = persistence
        self.workspace = workspace
    }

    public func loadCatalog(in library: LibraryScope) async -> ChatCatalogOutcome {
        let result: ActiveLibraryOperationResult<ChatCatalogOutcome> =
            await workspace.performActiveReadWriteOperation(in: library) { root in
            do {
                try persistence.reconcileInterruptedInvocationsIfUnowned(
                    at: root,
                    in: library
                )
                return ChatCatalogOutcome.loaded(
                    try persistence.loadCatalog(at: root, in: library).map { loaded -> ChatCatalogEntry in
                        switch loaded {
                        case let .readWrite(aggregate): ChatCatalogEntry.available(aggregate)
                        case let .frozen(frozen): ChatCatalogEntry.frozen(frozen)
                        }
                    }
                )
            } catch PortableChatPersistenceError.readOnlyLibrary {
                return ChatCatalogOutcome.readOnlyLibrary
            } catch {
                return ChatCatalogOutcome.failed
            }
        }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly: ChatCatalogOutcome.readOnlyLibrary
        case .unavailable: ChatCatalogOutcome.failed
        }
    }

    public func create(_ seed: NewDevelopmentChatSeed) async -> ChatMutationOutcome {
        let result: ActiveLibraryOperationResult<ChatMutationOutcome> =
            await workspace.performActiveReadWriteOperation(in: seed.library) { root in
            do {
                return ChatMutationOutcome.committed(try persistence.create(seed, at: root))
            } catch PortableChatPersistenceError.collision {
                return ChatMutationOutcome.collision
            } catch let PortableChatPersistenceError.profileStatementGenerationChanged(current) {
                return ChatMutationOutcome.profileStatementGenerationChanged(current)
            } catch PortableChatPersistenceError.readOnlyLibrary {
                return ChatMutationOutcome.readOnlyLibrary
            } catch {
                if let committed = try? persistence.reconcileCommittedCreate(seed, at: root) {
                    return ChatMutationOutcome.committed(committed)
                }
                return ChatMutationOutcome.failed
            }
        }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly: ChatMutationOutcome.readOnlyLibrary
        case .unavailable: ChatMutationOutcome.failed
        }
    }

    public func rename(_ mutation: RenameChatMutation) async -> ChatMutationOutcome {
        let result: ActiveLibraryOperationResult<ChatMutationOutcome> =
            await workspace.performActiveReadWriteOperation(in: mutation.library) { root in
            do {
                switch try persistence.rename(mutation, at: root) {
                case let .renamed(aggregate):
                    return ChatMutationOutcome.committed(aggregate)
                case let .stale(aggregate):
                    return ChatMutationOutcome.stale(aggregate)
                case let .frozen(frozen):
                    return ChatMutationOutcome.frozen(frozen)
                }
            } catch PortableChatPersistenceError.readOnlyLibrary {
                return ChatMutationOutcome.readOnlyLibrary
            } catch {
                if let committed = try? persistence.reconcileCommittedRename(mutation, at: root) {
                    return ChatMutationOutcome.committed(committed)
                }
                return ChatMutationOutcome.failed
            }
        }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly: ChatMutationOutcome.readOnlyLibrary
        case .unavailable: ChatMutationOutcome.failed
        }
    }

    public func saveDraft(_ mutation: SaveChatDraftMutation) async -> ChatMutationOutcome {
        await performMutation(
            in: mutation.library,
            operation: { root in try persistence.saveDraft(mutation, at: root) },
            reconcile: { root in
                try persistence.reconcileCommittedDraft(mutation, at: root)
            }
        )
    }

    public func lockPendingUserTurn(
        _ mutation: LockPendingUserTurnMutation
    ) async -> ChatMutationOutcome {
        await performMutation(
            in: mutation.library,
            operation: { root in
                try persistence.lockPendingUserTurn(mutation, at: root)
            },
            reconcile: { root in
                try persistence.reconcileCommittedPendingLock(mutation, at: root)
            }
        )
    }

    public func replacePendingUserTurn(
        _ mutation: ReplacePendingUserTurnMutation
    ) async -> ChatMutationOutcome {
        await performMutation(
            in: mutation.library,
            operation: { root in
                try persistence.replacePendingUserTurn(mutation, at: root)
            },
            reconcile: { root in
                try persistence.reconcileCommittedPendingReplacement(mutation, at: root)
            }
        )
    }

    public func discardPendingUserTurn(
        _ mutation: DiscardPendingUserTurnMutation
    ) async -> ChatMutationOutcome {
        await performMutation(
            in: mutation.library,
            operation: { root in
                try persistence.discardPendingUserTurn(mutation, at: root)
            },
            reconcile: { root in
                try persistence.reconcileCommittedPendingDiscard(mutation, at: root)
            }
        )
    }

    private func performMutation(
        in library: LibraryScope,
        operation: @Sendable (URL) throws -> PortableChatMutationResult,
        reconcile: @Sendable (URL) throws -> ChatAggregate?
    ) async -> ChatMutationOutcome {
        let result: ActiveLibraryOperationResult<ChatMutationOutcome> =
            await workspace.performActiveReadWriteOperation(in: library) { root in
            do {
                switch try operation(root) {
                case let .committed(aggregate):
                    return ChatMutationOutcome.committed(aggregate)
                case let .stale(aggregate):
                    return ChatMutationOutcome.stale(aggregate)
                case let .frozen(frozen):
                    return ChatMutationOutcome.frozen(frozen)
                }
            } catch PortableChatPersistenceError.readOnlyLibrary {
                return ChatMutationOutcome.readOnlyLibrary
            } catch {
                if let committed = try? reconcile(root) {
                    return ChatMutationOutcome.committed(committed)
                }
                return ChatMutationOutcome.failed
            }
        }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly: .readOnlyLibrary
        case .unavailable: .failed
        }
    }

    public func load(_ chatID: ChatID, in library: LibraryScope) async -> ChatLoadOutcome {
        let result: ActiveLibraryOperationResult<ChatLoadOutcome> =
            await workspace.performActiveReadWriteOperation(in: library) { root in
            do {
                try persistence.reconcileInterruptedInvocationsIfUnowned(
                    at: root,
                    in: library
                )
                switch try persistence.load(chatID, at: root, in: library) {
                case let .readWrite(aggregate):
                    return ChatLoadOutcome.loaded(aggregate)
                case let .frozen(frozen):
                    return ChatLoadOutcome.frozen(frozen)
                }
            } catch PortableChatPersistenceError.chatMissing {
                return ChatLoadOutcome.missing
            } catch PortableChatPersistenceError.readOnlyLibrary {
                return ChatLoadOutcome.readOnlyLibrary
            } catch PortableChatPersistenceError.libraryScopeMismatch {
                return ChatLoadOutcome.failed
            } catch {
                return ChatLoadOutcome.failed
            }
        }
        switch result {
        case let .performed(outcome): return outcome
        case .readOnly: return ChatLoadOutcome.readOnlyLibrary
        case .unavailable: return ChatLoadOutcome.failed
        }
    }
}
