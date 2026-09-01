@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
import Darwin
import Foundation

@_silgen_name("flock")
private func audoraFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

private struct PortableInvocationLivenessKey: Hashable {
    let device: dev_t
    let inode: ino_t
}

private struct PortableInvocationLivenessAuthority {
    let libraryID: LibraryID
    let root: PortableInvocationLivenessKey
    let invocations: PortableInvocationLivenessKey
    let pendingUserTurn: PortableInvocationLivenessKey?
}

/// `flock` provides the cross-process lifetime authority. Darwin may coalesce
/// independently opened locks in one process, so this registry supplies the
/// equivalent exclusion between separately composed stores in that process.
private enum PortableInvocationLivenessRegistry {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var held: Set<PortableInvocationLivenessKey> = []

    static func claim(_ key: PortableInvocationLivenessKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return held.insert(key).inserted
    }

    static func release(_ key: PortableInvocationLivenessKey) {
        lock.lock()
        held.remove(key)
        lock.unlock()
    }
}

/// Typed ownership of the stable Invocations-directory namespace. It keeps the
/// in-process registry claim and cross-process `flock` coupled to the same file
/// descriptor so every acquisition path has one idempotent release lifecycle.
private final class PortableInvocationNamespaceLock: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?
    let key: PortableInvocationLivenessKey

    init(descriptor: Int32, key: PortableInvocationLivenessKey) {
        self.descriptor = descriptor
        self.key = key
    }

    func release() {
        lock.lock()
        guard let descriptor else {
            lock.unlock()
            return
        }
        self.descriptor = nil
        lock.unlock()

        _ = audoraFlock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        PortableInvocationLivenessRegistry.release(key)
    }

    deinit { release() }
}

/// Exact Pending-file authority shared by the winning Invocation lease and
/// ordinary Pending mutations. The in-process registry complements `flock`
/// because Darwin may coalesce independently opened locks in one process.
private final class PortablePendingUserTurnFileLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?
    let key: PortableInvocationLivenessKey

    init(descriptor: Int32, key: PortableInvocationLivenessKey) {
        self.descriptor = descriptor
        self.key = key
    }

    func release() {
        lock.lock()
        guard let descriptor else {
            lock.unlock()
            return
        }
        self.descriptor = nil
        lock.unlock()

        _ = audoraFlock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        PortableInvocationLivenessRegistry.release(key)
    }

    deinit { release() }
}

/// One live provider owner's confined Library lifetime authority. The descriptor
/// remains locked from the first active check through terminal publication or
/// abort. A process crash closes it in the kernel, proving that relaunch recovery
/// may reconcile the durable Invocation.
private final class PortableInvocationLivenessLease: @unchecked Sendable {
    private let lock = NSLock()
    private var rootDescriptor: Int32?
    private var namespaceLock: PortableInvocationNamespaceLock?
    private let reservedAuthority: PortableInvocationLivenessAuthority
    private let pendingUserTurnLease: PortablePendingUserTurnFileLease
    private let reservedRequest: PendingCoachInvocationRequest

    init(
        rootDescriptor: Int32,
        namespaceLock: PortableInvocationNamespaceLock,
        authority: PortableInvocationLivenessAuthority,
        pendingUserTurnLease: PortablePendingUserTurnFileLease,
        reservedRequest: PendingCoachInvocationRequest
    ) {
        self.rootDescriptor = rootDescriptor
        self.namespaceLock = namespaceLock
        reservedAuthority = authority
        self.pendingUserTurnLease = pendingUserTurnLease
        self.reservedRequest = reservedRequest
    }

    func authority() -> PortableInvocationLivenessAuthority? {
        lock.lock()
        defer { lock.unlock() }
        guard rootDescriptor != nil, namespaceLock != nil else { return nil }
        return reservedAuthority
    }

    func authority(
        for request: PendingCoachInvocationRequest
    ) -> PortableInvocationLivenessAuthority? {
        guard request == reservedRequest else { return nil }
        return authority()
    }

    func reservation() -> (
        authority: PortableInvocationLivenessAuthority,
        request: PendingCoachInvocationRequest
    )? {
        lock.lock()
        defer { lock.unlock() }
        guard rootDescriptor != nil, namespaceLock != nil else { return nil }
        return (reservedAuthority, reservedRequest)
    }

    func release() {
        lock.lock()
        guard let rootDescriptor, let namespaceLock else {
            lock.unlock()
            return
        }
        self.rootDescriptor = nil
        self.namespaceLock = nil
        lock.unlock()

        // Release the exact Pending fence before advertising that the Library
        // Invocation namespace is unowned. A Library activation that wins the
        // namespace after this point can then acquire Pending authority instead
        // of observing a transient half-released owner.
        pendingUserTurnLease.release()
        namespaceLock.release()
        Darwin.close(rootDescriptor)
    }

    deinit { release() }
}

/// Short-lived authority used only while a newly activated Library reconciles
/// Invocations whose provider owner died with the previous process. It shares
/// the exact stable Invocations-directory namespace with live provider leases,
/// so a load can never retire an Invocation that still has a live owner.
private final class PortableInvocationRecoveryLease: @unchecked Sendable {
    private let lock = NSLock()
    private var rootDescriptor: Int32?
    private var namespaceLock: PortableInvocationNamespaceLock?
    private let reservedAuthority: PortableInvocationLivenessAuthority

    init(
        rootDescriptor: Int32,
        namespaceLock: PortableInvocationNamespaceLock,
        authority: PortableInvocationLivenessAuthority
    ) {
        self.rootDescriptor = rootDescriptor
        self.namespaceLock = namespaceLock
        reservedAuthority = authority
    }

    func authority() -> PortableInvocationLivenessAuthority? {
        lock.lock()
        defer { lock.unlock() }
        guard rootDescriptor != nil, namespaceLock != nil else { return nil }
        return reservedAuthority
    }

    func release() {
        lock.lock()
        guard let rootDescriptor, let namespaceLock else {
            lock.unlock()
            return
        }
        self.rootDescriptor = nil
        self.namespaceLock = nil
        lock.unlock()

        namespaceLock.release()
        Darwin.close(rootDescriptor)
    }

    deinit { release() }
}

public enum PortableChatFaultPoint: Hashable, Sendable {
    case candidateCreated
    case messagesDirectoryCreated
    case memoryDirectoryCreated
    case beforeMemoryPartialWrite
    case afterMemoryPartialWrite
    case afterMemoryFileFlush
    case afterMemoryInstall
    case afterMemoryDirectoryFlush
    case beforeChatPartialWrite
    case afterChatPartialWrite
    case afterChatFileFlush
    case afterChatInstall
    case afterCandidateFlush
    case beforeStagedRead
    case beforeFinalInstall
    case afterFinalInstall
    case afterChatsFlush
    case beforeFinalRead
    case beforeRenamePartialWrite
    case afterRenamePartialWrite
    case afterRenameFileFlush
    case afterRenameInstall
    case afterRenameDirectoryFlush
    case beforeRenameFinalRead
    case beforeDraftPartialWrite
    case afterDraftPartialWrite
    case afterDraftFileFlush
    case afterDraftInstall
    case afterDraftDirectoryFlush
    case beforeDraftFinalRead
    case beforePendingPartialWrite
    case afterPendingPartialWrite
    case afterPendingFileFlush
    case afterPendingInstall
    case afterPendingDirectoryFlush
    case beforePendingFinalRead
    case afterPendingInvocationAuthorityBound
    case beforePendingRemoval
    case afterPendingRemoval
    case afterPendingRemovalDirectoryFlush
    case beforeInvocationReconciliation
    case beforeInvocationReconciliationCommit
    case beforeInvocationPartialWrite
    case afterInvocationPartialWrite
    case afterInvocationFileFlush
    case afterInvocationInstall
    case afterInvocationDirectoryFlush
    case afterInvocationAbortMarkerInstall
    case afterInvocationAbortDirectoryRemoval
    case afterInvocationAbortPendingFailureInstall
    case afterUserMessageInstall
    case afterCoachMessageInstall
    case afterPublicationManifestFileFlush
    case afterPublicationManifestInstall
    case afterPublicationManifestDirectoryFlush
    case beforePublicationCleanup
    case beforePublicationReconciliationRead
}

public enum PortableChatPersistenceError: Error, Equatable, Sendable {
    case collision
    case readOnlyLibrary
    case libraryScopeMismatch
    case profileStatementGenerationChanged(UInt64)
    case chatMissing
    case expectedPathIsSymlink
    case invalidLayout
    case rootTooLarge
    case invalidJSON
    case invalidSchemaVersion
    case unknownKey
    case unsupportedOlderSchema
    case ioFailure
    case injectedFault(PortableChatFaultPoint)
}

public enum LoadedPortableChat: Equatable, Sendable {
    case readWrite(ChatAggregate)
    case frozen(FrozenChatSnapshot)
}

public enum PortableChatRenameResult: Equatable, Sendable {
    case renamed(ChatAggregate)
    case stale(ChatAggregate)
    case frozen(FrozenChatSnapshot)
}

public enum PortableChatMutationResult: Equatable, Sendable {
    case committed(ChatAggregate)
    case stale(ChatAggregate)
    case frozen(FrozenChatSnapshot)
}

private func frozenChatSnapshot(
    for error: PortableChatPersistenceError,
    chatID: ChatID
) -> FrozenChatSnapshot? {
    switch error {
    case .unsupportedOlderSchema:
        FrozenChatSnapshot(chatID: chatID, reason: .unsupportedSchema)
    case .expectedPathIsSymlink, .invalidLayout, .rootTooLarge, .invalidJSON,
         .invalidSchemaVersion, .unknownKey:
        FrozenChatSnapshot(chatID: chatID, reason: .corrupt)
    case .collision, .readOnlyLibrary, .libraryScopeMismatch,
         .profileStatementGenerationChanged, .chatMissing, .ioFailure,
         .injectedFault:
        nil
    }
}

public struct PortableChatPersistence: @unchecked Sendable {
    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct BoundPendingMutationResult {
        let mutation: PortableChatMutationResult
        let pendingLease: PortablePendingUserTurnFileLease?
    }

    fileprivate enum PreparedPendingInvocationResult {
        case prepared(ChatAggregate, PortableInvocationLivenessLease)
        case stale(ChatAggregate)
        case frozen(FrozenChatSnapshot)
        case activeExists
    }

    public static let maximumRootBytes = 65_536
    static let maximumChatCatalogEntries = 4_096
    static let maximumMessageDirectoryEntries = 4_096
    static let maximumChatRootEntries = 256
    static let maximumMemoryDirectoryEntries = 256
    static let maximumInvocationDirectoryEntries = 16

    private let fault: @Sendable (PortableChatFaultPoint) throws -> Void

    public init(
        fault: @escaping @Sendable (PortableChatFaultPoint) throws -> Void = { _ in }
    ) {
        self.fault = fault
    }

    /// Reserves the one live provider authority for this exact Library. `nil`
    /// means another process or separately composed store still owns it.
    fileprivate func acquireInvocationLivenessLease(
        at libraryRoot: URL,
        in scope: LibraryScope,
        for request: PendingCoachInvocationRequest
    ) throws -> PortableInvocationLivenessLease? {
        guard request.library == scope else {
            throw PortableChatPersistenceError.libraryScopeMismatch
        }
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        var ownsRootDescriptor = true
        defer {
            if ownsRootDescriptor { Darwin.close(rootDescriptor) }
        }
        let stagingDescriptor = try openDirectory(named: "staging", under: rootDescriptor)
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }

        let rootIdentity = try invocationLivenessIdentity(of: rootDescriptor)
        guard let namespaceLock = try acquireInvocationNamespaceLock(
            under: rootDescriptor
        ) else { return nil }

        try revalidateLibraryAuthority(libraryID: scope.libraryID, under: rootDescriptor)

        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let chatDescriptor = try openDirectory(
            named: request.chatID.rawValue,
            under: chatsDescriptor
        )
        defer { Darwin.close(chatDescriptor) }
        guard let pendingUserTurnLease = try acquirePendingUserTurnFileLease(
            under: chatDescriptor
        ) else {
            return nil
        }
        let pendingData = try boundedData(
            named: "pending-user-turn.json",
            under: chatDescriptor
        )
        guard try regularFileLivenessIdentity(
            named: "pending-user-turn.json",
            under: chatDescriptor
        ) == pendingUserTurnLease.key,
            try decodePendingUserTurn(pendingData).id == request.pendingUserTurnID
        else {
            throw PortableChatPersistenceError.invalidLayout
        }

        ownsRootDescriptor = false
        return PortableInvocationLivenessLease(
            rootDescriptor: rootDescriptor,
            namespaceLock: namespaceLock,
            authority: PortableInvocationLivenessAuthority(
                libraryID: scope.libraryID,
                root: rootIdentity,
                invocations: namespaceLock.key,
                pendingUserTurn: pendingUserTurnLease.key
            ),
            pendingUserTurnLease: pendingUserTurnLease,
            reservedRequest: request
        )
    }

    /// Owns the full new-Send installation window: the Library Invocation
    /// namespace is acquired before the Pending CAS, and the exact installed
    /// Pending inode is locked before the Chat mutation lock is released.
    fileprivate func prepareNewPendingInvocation(
        _ request: NewPendingCoachInvocationRequest,
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> PreparedPendingInvocationResult {
        guard request.library == scope else {
            throw PortableChatPersistenceError.libraryScopeMismatch
        }
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        var ownsRootDescriptor = true
        defer {
            if ownsRootDescriptor { Darwin.close(rootDescriptor) }
        }

        let rootIdentity: PortableInvocationLivenessKey
        let namespaceLock: PortableInvocationNamespaceLock
        do {
            let stagingDescriptor = try openDirectory(
                named: "staging",
                under: rootDescriptor
            )
            defer { Darwin.close(stagingDescriptor) }
            try acquireExclusiveMutationLock(on: stagingDescriptor)
            defer { releaseMutationLock(on: stagingDescriptor) }
            rootIdentity = try invocationLivenessIdentity(of: rootDescriptor)
            guard let acquired = try acquireInvocationNamespaceLock(
                under: rootDescriptor
            ) else { return .activeExists }
            namespaceLock = acquired
            try revalidateLibraryAuthority(
                libraryID: scope.libraryID,
                under: rootDescriptor
            )
        }
        var ownsNamespaceLock = true
        defer {
            if ownsNamespaceLock { namespaceLock.release() }
        }
        let namespaceAuthority = PortableInvocationLivenessAuthority(
            libraryID: scope.libraryID,
            root: rootIdentity,
            invocations: namespaceLock.key,
            pendingUserTurn: nil
        )

        try reconcileInterruptedInvocations(
            at: libraryRoot,
            in: scope,
            livenessAuthority: namespaceAuthority,
            reservedRequest: nil
        )
        try reconcileUninstalledPendingIntents(
            at: libraryRoot,
            in: scope,
            livenessAuthority: namespaceAuthority
        )

        let mutation = LockPendingUserTurnMutation(
            library: request.library,
            chatID: request.chatID,
            pendingUserTurn: request.pendingUserTurn
        )
        let bound: BoundPendingMutationResult
        do {
            bound = try lockPendingUserTurn(
                mutation,
                at: libraryRoot,
                livenessAuthority: namespaceAuthority,
                bindsPendingAuthority: true
            )
        } catch {
            guard let committed = try reconcileCommittedPendingLockAndBind(
                mutation,
                at: libraryRoot,
                livenessAuthority: namespaceAuthority
            ) else {
                throw error
            }
            bound = committed
        }
        switch bound.mutation {
        case let .committed(aggregate):
            guard let pendingLease = bound.pendingLease else {
                throw PortableChatPersistenceError.ioFailure
            }
            let pendingRequest = PendingCoachInvocationRequest(
                library: request.library,
                chatID: request.chatID,
                pendingUserTurnID: request.pendingUserTurn.id
            )
            let lease = PortableInvocationLivenessLease(
                rootDescriptor: rootDescriptor,
                namespaceLock: namespaceLock,
                authority: PortableInvocationLivenessAuthority(
                    libraryID: scope.libraryID,
                    root: rootIdentity,
                    invocations: namespaceLock.key,
                    pendingUserTurn: pendingLease.key
                ),
                pendingUserTurnLease: pendingLease,
                reservedRequest: pendingRequest
            )
            do {
                try fault(.afterPendingInvocationAuthorityBound)
            } catch {
                // The exact Pending and both levels of liveness authority are
                // already proven. Returning failure here would strand a live
                // Pending behind an editable Draft, so the handoff is total.
            }
            ownsRootDescriptor = false
            ownsNamespaceLock = false
            return .prepared(aggregate, lease)
        case let .stale(aggregate):
            return .stale(aggregate)
        case let .frozen(frozen):
            return .frozen(frozen)
        }
    }

    /// Claims the Library's Invocation namespace only when no provider task in
    /// this or another process still owns it. The caller must hold this lease
    /// through the complete interruption reconciliation transaction.
    private func acquireInvocationRecoveryLease(
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> PortableInvocationRecoveryLease? {
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        var ownsRootDescriptor = true
        defer {
            if ownsRootDescriptor { Darwin.close(rootDescriptor) }
        }

        let rootIdentity = try invocationLivenessIdentity(of: rootDescriptor)
        guard let namespaceLock = try acquireInvocationNamespaceLock(
            under: rootDescriptor
        ) else { return nil }

        try revalidateLibraryAuthority(libraryID: scope.libraryID, under: rootDescriptor)

        ownsRootDescriptor = false
        return PortableInvocationRecoveryLease(
            rootDescriptor: rootDescriptor,
            namespaceLock: namespaceLock,
            authority: PortableInvocationLivenessAuthority(
                libraryID: scope.libraryID,
                root: rootIdentity,
                invocations: namespaceLock.key,
                pendingUserTurn: nil
            )
        )
    }

    private func acquireInvocationNamespaceLock(
        under rootDescriptor: Int32
    ) throws -> PortableInvocationNamespaceLock? {
        let descriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        var ownsDescriptor = true
        defer {
            if ownsDescriptor { Darwin.close(descriptor) }
        }
        let key = try invocationLivenessIdentity(of: descriptor)
        guard PortableInvocationLivenessRegistry.claim(key) else { return nil }
        var ownsRegistryClaim = true
        defer {
            if ownsRegistryClaim { PortableInvocationLivenessRegistry.release(key) }
        }

        while audoraFlock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK || errno == EAGAIN { return nil }
            throw PortableChatPersistenceError.ioFailure
        }
        var ownsFileLock = true
        defer {
            if ownsFileLock { _ = audoraFlock(descriptor, LOCK_UN) }
        }
        guard try directoryIdentity(named: "invocations", under: rootDescriptor) ==
            directoryIdentity(of: descriptor)
        else { throw PortableChatPersistenceError.invalidLayout }

        ownsDescriptor = false
        ownsRegistryClaim = false
        ownsFileLock = false
        return PortableInvocationNamespaceLock(descriptor: descriptor, key: key)
    }

    fileprivate func reconcileInterruptedInvocationsIfUnowned(
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws {
        guard let lease = try acquireInvocationRecoveryLease(
            at: libraryRoot,
            in: scope
        ) else { return }
        defer { lease.release() }
        try reconcileInterruptedInvocations(
            at: libraryRoot,
            in: scope,
            holding: lease
        )
        try reconcileUninstalledPendingIntents(
            at: libraryRoot,
            in: scope,
            holding: lease
        )
    }

    /// A Pending is installed before admission and before its durable
    /// Invocation. Once the Library Invocation namespace is proven unowned,
    /// any remaining failure-free Pending is therefore an interrupted launch,
    /// not an active request. Preserve its exact intent and expose Retry/Discard.
    private func reconcileUninstalledPendingIntents(
        at libraryRoot: URL,
        in scope: LibraryScope,
        holding lease: PortableInvocationRecoveryLease
    ) throws {
        guard let livenessAuthority = lease.authority() else {
            throw PortableChatPersistenceError.ioFailure
        }
        try reconcileUninstalledPendingIntents(
            at: libraryRoot,
            in: scope,
            livenessAuthority: livenessAuthority
        )
    }

    private func reconcileUninstalledPendingIntents(
        at libraryRoot: URL,
        in scope: LibraryScope,
        livenessAuthority: PortableInvocationLivenessAuthority
    ) throws {
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        let revalidateLiveness = invocationLivenessRevalidator(
            livenessAuthority,
            at: libraryRoot,
            in: scope,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
        try revalidateLiveness()
        guard try invocationDirectoryNamesRemovingEmptyResidue(
            under: invocationsDescriptor,
            beforeRemoving: revalidateLiveness
        ).isEmpty else {
            throw PortableChatPersistenceError.invalidLayout
        }

        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let chatNames = try listEntryNames(
            under: chatsDescriptor,
            maximumCount: Self.maximumChatCatalogEntries
        )
        var mutations: [ReplacePendingUserTurnMutation] = []
        for chatName in chatNames {
            guard let chatID = try? ChatID(chatName) else { continue }
            do {
                let chatDescriptor = try openDirectory(
                    named: chatName,
                    under: chatsDescriptor
                )
                defer { Darwin.close(chatDescriptor) }
                try acquireExclusiveMutationLock(on: chatDescriptor)
                defer { releaseMutationLock(on: chatDescriptor) }
                try revalidateLiveness()
                guard case let .readWrite(current) = try loadChat(
                    from: chatDescriptor,
                    expectedID: chatID,
                    reconcileTransients: true,
                    beforeDestructiveMutation: revalidateLiveness
                ), let pending = current.pendingUserTurn,
                    pending.failure == nil
                else { continue }
                mutations.append(
                    try ReplacePendingUserTurnMutation(
                        library: scope,
                        chatID: chatID,
                        base: pending,
                        replacement: pending.replacingFailure(
                            .coachResponseInterrupted
                        )
                    )
                )
            } catch let error as PortableChatPersistenceError
                where frozenChatSnapshot(for: error, chatID: chatID) != nil
            {
                // Recovery is per Chat. A permanently frozen sibling has no
                // launch authority, and must not hide or strand healthy
                // Pending intents elsewhere in the Library.
                continue
            } catch {
                throw error
            }
        }

        for mutation in mutations {
            _ = try replacePendingUserTurn(
                mutation,
                at: libraryRoot,
                livenessAuthority: livenessAuthority,
                ownsPendingUserTurnLease: false
            )
        }
    }

    private var confined: ConfinedPersistencePrimitives<PortableChatPersistenceError> {
        ConfinedPersistencePrimitives(
            ioFailure: .ioFailure,
            invalidLayout: .invalidLayout,
            expectedPathIsSymlink: .expectedPathIsSymlink,
            rootTooLarge: .rootTooLarge,
            invalidJSON: .invalidJSON,
            invalidSchemaVersion: .invalidSchemaVersion,
            unknownKey: .unknownKey
        )
    }

    public func loadCatalog(
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> [LoadedPortableChat] {
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        try reconcileStagedChatCandidatesExclusively(under: rootDescriptor)
        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }

        return try listEntryNames(
            under: chatsDescriptor,
            maximumCount: Self.maximumChatCatalogEntries
        )
            .compactMap { name -> (ChatID, String)? in
                guard let chatID = try? ChatID(name) else { return nil }
                return (chatID, name)
            }
            .sorted { $0.0.rawValue < $1.0.rawValue }
            .map { chatID, name in
                do {
                    let descriptor = try openDirectory(named: name, under: chatsDescriptor)
                    defer { Darwin.close(descriptor) }
                    return try loadChatReconcilingTransients(
                        from: descriptor,
                        expectedID: chatID
                    )
                } catch let error as PortableChatPersistenceError {
                    guard let frozen = frozenChatSnapshot(for: error, chatID: chatID) else {
                        throw error
                    }
                    return .frozen(frozen)
                } catch {
                    return .frozen(FrozenChatSnapshot(chatID: chatID, reason: .corrupt))
                }
            }
    }

    public func load(
        _ chatID: ChatID,
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> LoadedPortableChat {
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        try reconcileStagedChatCandidatesExclusively(under: rootDescriptor)
        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        guard try entryExists(named: chatID.rawValue, under: chatsDescriptor) else {
            throw PortableChatPersistenceError.chatMissing
        }
        let descriptor = try openDirectory(named: chatID.rawValue, under: chatsDescriptor)
        defer { Darwin.close(descriptor) }
        do {
            return try loadChatReconcilingTransients(
                from: descriptor,
                expectedID: chatID
            )
        } catch let error as PortableChatPersistenceError {
            guard let frozen = frozenChatSnapshot(for: error, chatID: chatID) else {
                throw error
            }
            return .frozen(frozen)
        } catch {
            return .frozen(FrozenChatSnapshot(chatID: chatID, reason: .corrupt))
        }
    }

    public func create(
        _ seed: NewDevelopmentChatSeed,
        at libraryRoot: URL
    ) throws -> ChatAggregate {
        // A new Chat introduces a Draft ID into the same Library-wide
        // namespace checked before provider launch. Hold the stable Invocation
        // namespace so it cannot install a checked fresh-Draft collision while
        // an Invocation reservation is live (or vice versa).
        guard let invocationNamespaceLease = try acquireInvocationRecoveryLease(
            at: libraryRoot,
            in: seed.library
        ) else {
            throw PortableChatPersistenceError.ioFailure
        }
        defer { invocationNamespaceLease.release() }
        let rootDescriptor = try openLibraryRoot(
            at: libraryRoot,
            in: seed.library,
            expectedProfileStatementGeneration:
                seed.aggregate.chat.profileStatementGenerationAtCreation
        )
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(named: "staging", under: rootDescriptor)
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        try reconcileStagedChatCandidates(under: rootDescriptor)
        let publicationsDescriptor = try openDirectory(
            named: "publications",
            under: stagingDescriptor
        )
        defer { Darwin.close(publicationsDescriptor) }
        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }

        let finalName = seed.aggregate.chat.id.rawValue
        guard !(try entryExists(named: finalName, under: chatsDescriptor)) else {
            throw PortableChatPersistenceError.collision
        }

        let candidateName = "chat-\(finalName)-\(UUID().uuidString.lowercased())"
        try makeDirectory(named: candidateName, under: publicationsDescriptor)
        let candidateIdentity = try directoryIdentity(
            named: candidateName,
            under: publicationsDescriptor
        )
        var candidateInstalled = false
        defer {
            if !candidateInstalled {
                removeCandidate(
                    named: candidateName,
                    memoryID: seed.aggregate.memory.memoryID,
                    expectedIdentity: candidateIdentity,
                    under: publicationsDescriptor
                )
            }
        }
        try fault(.candidateCreated)

        let candidateDescriptor = try openDirectory(
            named: candidateName,
            under: publicationsDescriptor
        )
        defer { Darwin.close(candidateDescriptor) }
        guard try directoryIdentity(of: candidateDescriptor) == candidateIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try makeDirectory(named: "messages", under: candidateDescriptor)
        try fault(.messagesDirectoryCreated)
        try makeDirectory(named: "memory", under: candidateDescriptor)
        try fault(.memoryDirectoryCreated)

        let messagesDescriptor = try openDirectory(named: "messages", under: candidateDescriptor)
        defer { Darwin.close(messagesDescriptor) }
        let memoryDescriptor = try openDirectory(named: "memory", under: candidateDescriptor)
        defer { Darwin.close(memoryDescriptor) }

        try writeNewRoot(
            encodeMemory(seed.aggregate.memory),
            named: "\(seed.aggregate.memory.memoryID.rawValue).json",
            under: memoryDescriptor,
            points: (
                .beforeMemoryPartialWrite,
                .afterMemoryPartialWrite,
                .afterMemoryFileFlush,
                .afterMemoryInstall,
                .afterMemoryDirectoryFlush
            )
        )
        try flushDescriptor(messagesDescriptor)
        try writeNewRoot(
            encodeChat(seed.aggregate.chat),
            named: "chat.json",
            under: candidateDescriptor,
            points: (
                .beforeChatPartialWrite,
                .afterChatPartialWrite,
                .afterChatFileFlush,
                .afterChatInstall,
                nil
            )
        )
        try flushDescriptor(candidateDescriptor)
        try fault(.afterCandidateFlush)
        try fault(.beforeStagedRead)
        guard case let .readWrite(staged) = try loadChat(
            from: candidateDescriptor,
            expectedID: seed.aggregate.chat.id,
            reconcileTransients: false
        ), staged == seed.aggregate else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let validatedCandidateIdentity = try directoryIdentity(of: candidateDescriptor)

        try fault(.beforeFinalInstall)
        try revalidateLibraryAuthority(
            libraryID: seed.library.libraryID,
            profileStatementGeneration: seed.aggregate.chat.profileStatementGenerationAtCreation,
            under: rootDescriptor
        )
        guard try directoryIdentity(
            named: candidateName,
            under: publicationsDescriptor
        ) == validatedCandidateIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try noReplaceRename(
            from: candidateName,
            under: publicationsDescriptor,
            to: finalName,
            under: chatsDescriptor
        )
        let finalDescriptor = try openDirectory(named: finalName, under: chatsDescriptor)
        defer { Darwin.close(finalDescriptor) }
        guard try directoryIdentity(of: finalDescriptor) == validatedCandidateIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        candidateInstalled = true
        try fault(.afterFinalInstall)
        try flushDescriptor(chatsDescriptor)
        try fault(.afterChatsFlush)
        try fault(.beforeFinalRead)

        guard try directoryIdentity(
            named: finalName,
            under: chatsDescriptor
        ) == validatedCandidateIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        guard case let .readWrite(installed) = try loadChatReconcilingTransients(
            from: finalDescriptor,
            expectedID: seed.aggregate.chat.id
        ), installed == seed.aggregate else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return installed
    }

    public func rename(
        _ mutation: RenameChatMutation,
        at libraryRoot: URL
    ) throws -> PortableChatRenameResult {
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: mutation.library)
        defer { Darwin.close(rootDescriptor) }
        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let chatName = mutation.chatID.rawValue
        guard try entryExists(named: chatName, under: chatsDescriptor) else {
            throw PortableChatPersistenceError.chatMissing
        }
        let chatIdentity = try directoryIdentity(named: chatName, under: chatsDescriptor)
        let chatDescriptor = try openDirectory(
            named: chatName,
            under: chatsDescriptor
        )
        defer { Darwin.close(chatDescriptor) }
        guard try directoryIdentity(of: chatDescriptor) == chatIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              try directoryIdentity(of: chatDescriptor) == chatIdentity
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let loaded = try loadChatForRename(from: chatDescriptor, expectedID: mutation.chatID)
        guard case let .readWrite(current) = loaded else {
            if case let .frozen(frozen) = loaded { return .frozen(frozen) }
            throw PortableChatPersistenceError.invalidLayout
        }
        if current == mutation.replacement {
            return .renamed(current)
        }
        guard current == mutation.base else {
            return .stale(current)
        }
        let renamed = mutation.replacement
        let memoryDescriptor = try openDirectory(named: "memory", under: chatDescriptor)
        defer { Darwin.close(memoryDescriptor) }
        let memoryBytes = try boundedData(
            named: "\(current.memory.memoryID.rawValue).json",
            under: memoryDescriptor
        )

        try fault(.beforeRenamePartialWrite)
        let partialName = ".chat.json.\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString { Darwin.unlinkat(chatDescriptor, $0, 0) }
            }
        }
        let data = try encodeChat(renamed.chat)
        try writeExclusive(data, named: partialName, under: chatDescriptor)
        partialExists = true
        try fault(.afterRenamePartialWrite)
        let partialDescriptor = try openRegularFile(named: partialName, under: chatDescriptor)
        defer { Darwin.close(partialDescriptor) }
        try flushDescriptor(partialDescriptor)
        try fault(.afterRenameFileFlush)
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              try directoryIdentity(of: chatDescriptor) == chatIdentity
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        switch try loadChatForRename(
            from: chatDescriptor,
            expectedID: mutation.chatID,
            reconcileTransients: false
        ) {
        case let .frozen(frozen):
            return .frozen(frozen)
        case let .readWrite(commitAuthority):
            if commitAuthority == renamed {
                return .renamed(commitAuthority)
            }
            guard commitAuthority == mutation.base else {
                return .stale(commitAuthority)
            }
        }
        try revalidateLibraryAuthority(
            libraryID: mutation.library.libraryID,
            under: rootDescriptor
        )
        guard renameat(chatDescriptor, partialName, chatDescriptor, "chat.json") == 0 else {
            throw PortableChatPersistenceError.ioFailure
        }
        partialExists = false
        try fault(.afterRenameInstall)
        try flushDescriptor(chatDescriptor)
        try fault(.afterRenameDirectoryFlush)
        try fault(.beforeRenameFinalRead)

        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.chatID,
            reconcileTransients: true
        ), reopened == renamed else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let reopenedMemoryBytes = try boundedData(
            named: "\(current.memory.memoryID.rawValue).json",
            under: memoryDescriptor
        )
        guard reopenedMemoryBytes == memoryBytes else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return .renamed(reopened)
    }

    public func saveDraft(
        _ mutation: SaveChatDraftMutation,
        at libraryRoot: URL
    ) throws -> PortableChatMutationResult {
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: mutation.library)
        defer { Darwin.close(rootDescriptor) }
        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let chatName = mutation.chatID.rawValue
        guard try entryExists(named: chatName, under: chatsDescriptor) else {
            throw PortableChatPersistenceError.chatMissing
        }
        let chatIdentity = try directoryIdentity(named: chatName, under: chatsDescriptor)
        let chatDescriptor = try openDirectory(named: chatName, under: chatsDescriptor)
        defer { Darwin.close(chatDescriptor) }
        guard try directoryIdentity(of: chatDescriptor) == chatIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              try directoryIdentity(of: chatDescriptor) == chatIdentity
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let loaded = try loadChatForRename(from: chatDescriptor, expectedID: mutation.chatID)
        guard case let .readWrite(current) = loaded else {
            if case let .frozen(frozen) = loaded { return .frozen(frozen) }
            throw PortableChatPersistenceError.invalidLayout
        }
        guard current.pendingUserTurn == nil,
              mutation.replacement.draftID == current.chat.draft.draftID
        else {
            return .stale(current)
        }
        if mutation.replacement.version < current.chat.draft.version {
            return .stale(current)
        }
        if mutation.replacement.version == current.chat.draft.version {
            return mutation.replacement == current.chat.draft
                ? .committed(current)
                : .stale(current)
        }
        let replacement = try ChatAggregate(
            chat: current.chat.replacingDraft(with: mutation.replacement),
            memory: current.memory
        )

        try fault(.beforeDraftPartialWrite)
        let partialName = ".chat.json.\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString { Darwin.unlinkat(chatDescriptor, $0, 0) }
            }
        }
        try writeExclusive(try encodeChat(replacement.chat), named: partialName, under: chatDescriptor)
        partialExists = true
        try fault(.afterDraftPartialWrite)
        let partialDescriptor = try openRegularFile(named: partialName, under: chatDescriptor)
        defer { Darwin.close(partialDescriptor) }
        try flushDescriptor(partialDescriptor)
        try fault(.afterDraftFileFlush)
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              try directoryIdentity(of: chatDescriptor) == chatIdentity
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        switch try loadChatForRename(
            from: chatDescriptor,
            expectedID: mutation.chatID,
            reconcileTransients: false
        ) {
        case let .frozen(frozen):
            return .frozen(frozen)
        case let .readWrite(commitAuthority):
            if commitAuthority == replacement { return .committed(commitAuthority) }
            guard commitAuthority == current else { return .stale(commitAuthority) }
        }
        try revalidateLibraryAuthority(
            libraryID: mutation.library.libraryID,
            under: rootDescriptor
        )
        guard renameat(chatDescriptor, partialName, chatDescriptor, "chat.json") == 0 else {
            throw PortableChatPersistenceError.ioFailure
        }
        partialExists = false
        try fault(.afterDraftInstall)
        try flushDescriptor(chatDescriptor)
        try fault(.afterDraftDirectoryFlush)
        try fault(.beforeDraftFinalRead)
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.chatID,
            reconcileTransients: true
        ), reopened == replacement else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return .committed(reopened)
    }

    public func lockPendingUserTurn(
        _ mutation: LockPendingUserTurnMutation,
        at libraryRoot: URL
    ) throws -> PortableChatMutationResult {
        try lockPendingUserTurn(
            mutation,
            at: libraryRoot,
            livenessAuthority: nil,
            bindsPendingAuthority: false
        ).mutation
    }

    private func lockPendingUserTurn(
        _ mutation: LockPendingUserTurnMutation,
        at libraryRoot: URL,
        livenessAuthority: PortableInvocationLivenessAuthority?,
        bindsPendingAuthority: Bool
    ) throws -> BoundPendingMutationResult {
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: mutation.library)
        defer { Darwin.close(rootDescriptor) }
        let revalidateLiveness: () throws -> Void = {
            guard let livenessAuthority else { return }
            try self.revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: mutation.library,
                under: rootDescriptor
            )
        }
        try revalidateLiveness()
        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let chatName = mutation.chatID.rawValue
        guard try entryExists(named: chatName, under: chatsDescriptor) else {
            throw PortableChatPersistenceError.chatMissing
        }
        let chatIdentity = try directoryIdentity(named: chatName, under: chatsDescriptor)
        let chatDescriptor = try openDirectory(named: chatName, under: chatsDescriptor)
        defer { Darwin.close(chatDescriptor) }
        guard try directoryIdentity(of: chatDescriptor) == chatIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        let loaded = try loadChatForRename(from: chatDescriptor, expectedID: mutation.chatID)
        guard case let .readWrite(current) = loaded else {
            if case let .frozen(frozen) = loaded {
                return BoundPendingMutationResult(
                    mutation: .frozen(frozen),
                    pendingLease: nil
                )
            }
            throw PortableChatPersistenceError.invalidLayout
        }
        if let installed = current.pendingUserTurn {
            guard installed == mutation.pendingUserTurn else {
                return BoundPendingMutationResult(
                    mutation: .stale(current),
                    pendingLease: nil
                )
            }
            let pendingLease = bindsPendingAuthority
                ? try acquireAndValidatePendingUserTurnFileLease(
                    mutation.pendingUserTurn,
                    under: chatDescriptor
                )
                : nil
            return BoundPendingMutationResult(
                mutation: .committed(current),
                pendingLease: pendingLease
            )
        }
        guard current.chat.draft.draftID == mutation.pendingUserTurn.draftID,
              current.chat.draft.version == mutation.pendingUserTurn.draftVersion
        else {
            return BoundPendingMutationResult(
                mutation: .stale(current),
                pendingLease: nil
            )
        }
        let replacement = try ChatAggregate(
            chat: current.chat,
            memory: current.memory,
            pendingUserTurn: mutation.pendingUserTurn
        )

        try fault(.beforePendingPartialWrite)
        let partialName = ".pending-user-turn.json.\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString { Darwin.unlinkat(chatDescriptor, $0, 0) }
            }
        }
        try writeExclusive(
            try encodePendingUserTurn(mutation.pendingUserTurn),
            named: partialName,
            under: chatDescriptor
        )
        partialExists = true
        try fault(.afterPendingPartialWrite)
        let partialDescriptor = try openRegularFile(named: partialName, under: chatDescriptor)
        defer { Darwin.close(partialDescriptor) }
        try flushDescriptor(partialDescriptor)
        try fault(.afterPendingFileFlush)
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              try directoryIdentity(of: chatDescriptor) == chatIdentity
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        switch try loadChatForRename(
            from: chatDescriptor,
            expectedID: mutation.chatID,
            reconcileTransients: false
        ) {
        case let .frozen(frozen):
            return BoundPendingMutationResult(
                mutation: .frozen(frozen),
                pendingLease: nil
            )
        case let .readWrite(commitAuthority):
            guard commitAuthority == current else {
                return BoundPendingMutationResult(
                    mutation: .stale(commitAuthority),
                    pendingLease: nil
                )
            }
        }
        if livenessAuthority != nil {
            try revalidateLiveness()
        } else {
            try revalidateLibraryAuthority(
                libraryID: mutation.library.libraryID,
                under: rootDescriptor
            )
        }
        try noReplaceRename(
            from: partialName,
            under: chatDescriptor,
            to: "pending-user-turn.json",
            under: chatDescriptor
        )
        partialExists = false
        let pendingLease = bindsPendingAuthority
            ? try acquireAndValidatePendingUserTurnFileLease(
                mutation.pendingUserTurn,
                under: chatDescriptor
            )
            : nil
        try fault(.afterPendingInstall)
        try flushDescriptor(chatDescriptor)
        try fault(.afterPendingDirectoryFlush)
        try fault(.beforePendingFinalRead)
        try revalidateLiveness()
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.chatID,
            reconcileTransients: true
        ), reopened == replacement else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return BoundPendingMutationResult(
            mutation: .committed(reopened),
            pendingLease: pendingLease
        )
    }

    private func reconcileCommittedPendingLockAndBind(
        _ mutation: LockPendingUserTurnMutation,
        at libraryRoot: URL,
        livenessAuthority: PortableInvocationLivenessAuthority
    ) throws -> BoundPendingMutationResult? {
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: mutation.library)
        defer { Darwin.close(rootDescriptor) }
        let revalidateLiveness: () throws -> Void = {
            try self.revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: mutation.library,
                under: rootDescriptor
            )
        }
        try revalidateLiveness()
        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let chatName = mutation.chatID.rawValue
        guard try entryExists(named: chatName, under: chatsDescriptor) else {
            return nil
        }
        let chatIdentity = try directoryIdentity(named: chatName, under: chatsDescriptor)
        let chatDescriptor = try openDirectory(named: chatName, under: chatsDescriptor)
        defer { Darwin.close(chatDescriptor) }
        guard try directoryIdentity(of: chatDescriptor) == chatIdentity else {
            return nil
        }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        try revalidateLiveness()
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              try directoryIdentity(of: chatDescriptor) == chatIdentity,
              case let .readWrite(installed) = try loadChat(
                  from: chatDescriptor,
                  expectedID: mutation.chatID,
                  reconcileTransients: true,
                  beforeDestructiveMutation: revalidateLiveness
              ),
              installed.pendingUserTurn == mutation.pendingUserTurn
        else { return nil }

        try flushDescriptor(chatDescriptor)
        try revalidateLiveness()
        let pendingLease = try acquireAndValidatePendingUserTurnFileLease(
            mutation.pendingUserTurn,
            under: chatDescriptor
        )
        do {
            guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
                  try directoryIdentity(of: chatDescriptor) == chatIdentity,
                  case let .readWrite(confirmed) = try loadChat(
                      from: chatDescriptor,
                      expectedID: mutation.chatID,
                      reconcileTransients: true,
                      beforeDestructiveMutation: revalidateLiveness
                  ),
                  confirmed.pendingUserTurn == mutation.pendingUserTurn
            else {
                throw PortableChatPersistenceError.invalidLayout
            }
            return BoundPendingMutationResult(
                mutation: .committed(confirmed),
                pendingLease: pendingLease
            )
        } catch {
            pendingLease.release()
            throw error
        }
    }

    public func replacePendingUserTurn(
        _ mutation: ReplacePendingUserTurnMutation,
        at libraryRoot: URL
    ) throws -> PortableChatMutationResult {
        try replacePendingUserTurn(
            mutation,
            at: libraryRoot,
            livenessAuthority: nil,
            ownsPendingUserTurnLease: false
        )
    }

    fileprivate func replacePendingUserTurn(
        _ mutation: ReplacePendingUserTurnMutation,
        at libraryRoot: URL,
        holding lease: PortableInvocationLivenessLease
    ) throws -> PortableChatMutationResult {
        guard let authority = lease.authority(for: PendingCoachInvocationRequest(
            library: mutation.library,
            chatID: mutation.chatID,
            pendingUserTurnID: mutation.base.id
        )) else {
            throw PortableChatPersistenceError.ioFailure
        }
        return try replacePendingUserTurn(
            mutation,
            at: libraryRoot,
            livenessAuthority: authority,
            ownsPendingUserTurnLease: true
        )
    }

    private func replacePendingUserTurn(
        _ mutation: ReplacePendingUserTurnMutation,
        at libraryRoot: URL,
        holding lease: PortableInvocationRecoveryLease
    ) throws -> PortableChatMutationResult {
        guard let authority = lease.authority() else {
            throw PortableChatPersistenceError.ioFailure
        }
        return try replacePendingUserTurn(
            mutation,
            at: libraryRoot,
            livenessAuthority: authority,
            ownsPendingUserTurnLease: false
        )
    }

    private func replacePendingUserTurn(
        _ mutation: ReplacePendingUserTurnMutation,
        at libraryRoot: URL,
        livenessAuthority: PortableInvocationLivenessAuthority?,
        ownsPendingUserTurnLease: Bool
    ) throws -> PortableChatMutationResult {
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: mutation.library)
        defer { Darwin.close(rootDescriptor) }
        let revalidateLiveness: () throws -> Void = {
            guard let livenessAuthority else { return }
            try self.revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: mutation.library,
                under: rootDescriptor
            )
        }
        try revalidateLiveness()
        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let chatName = mutation.chatID.rawValue
        guard try entryExists(named: chatName, under: chatsDescriptor) else {
            throw PortableChatPersistenceError.chatMissing
        }
        let chatIdentity = try directoryIdentity(named: chatName, under: chatsDescriptor)
        let chatDescriptor = try openDirectory(named: chatName, under: chatsDescriptor)
        defer { Darwin.close(chatDescriptor) }
        guard try directoryIdentity(of: chatDescriptor) == chatIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              try directoryIdentity(of: chatDescriptor) == chatIdentity
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        if let livenessAuthority {
            try revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: mutation.library,
                under: rootDescriptor
            )
        }
        let loaded = try loadChatForRename(
            from: chatDescriptor,
            expectedID: mutation.chatID,
            beforeDestructiveMutation: revalidateLiveness
        )
        guard case let .readWrite(current) = loaded else {
            if case let .frozen(frozen) = loaded { return .frozen(frozen) }
            throw PortableChatPersistenceError.invalidLayout
        }
        if current.pendingUserTurn == mutation.replacement {
            return .committed(current)
        }
        guard current.pendingUserTurn == mutation.base else {
            return .stale(current)
        }
        let pendingMutationLease: PortablePendingUserTurnFileLease?
        if !ownsPendingUserTurnLease {
            guard let lease = try acquirePendingUserTurnFileLease(
                under: chatDescriptor
            ) else {
                return .stale(current)
            }
            pendingMutationLease = lease
        } else {
            pendingMutationLease = nil
        }
        defer { pendingMutationLease?.release() }
        let replacement = try ChatAggregate(
            chat: current.chat,
            memory: current.memory,
            pendingUserTurn: mutation.replacement
        )

        if let livenessAuthority {
            try revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: mutation.library,
                under: rootDescriptor
            )
        }
        try fault(.beforePendingPartialWrite)
        let partialName = ".pending-user-turn.json.\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString { Darwin.unlinkat(chatDescriptor, $0, 0) }
            }
        }
        try writeExclusive(
            try encodePendingUserTurn(mutation.replacement),
            named: partialName,
            under: chatDescriptor
        )
        partialExists = true
        try fault(.afterPendingPartialWrite)
        let partialDescriptor = try openRegularFile(named: partialName, under: chatDescriptor)
        defer { Darwin.close(partialDescriptor) }
        try flushDescriptor(partialDescriptor)
        try fault(.afterPendingFileFlush)
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              try directoryIdentity(of: chatDescriptor) == chatIdentity
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        switch try loadChatForRename(
            from: chatDescriptor,
            expectedID: mutation.chatID,
            reconcileTransients: false
        ) {
        case let .frozen(frozen):
            return .frozen(frozen)
        case let .readWrite(commitAuthority):
            if commitAuthority == replacement { return .committed(commitAuthority) }
            guard commitAuthority == current else { return .stale(commitAuthority) }
        }
        if let livenessAuthority {
            try revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: mutation.library,
                under: rootDescriptor
            )
        } else {
            try revalidateLibraryAuthority(
                libraryID: mutation.library.libraryID,
                under: rootDescriptor
            )
        }
        guard renameat(
            chatDescriptor,
            partialName,
            chatDescriptor,
            "pending-user-turn.json"
        ) == 0 else {
            throw PortableChatPersistenceError.ioFailure
        }
        partialExists = false
        try fault(.afterPendingInstall)
        try flushDescriptor(chatDescriptor)
        try fault(.afterPendingDirectoryFlush)
        try fault(.beforePendingFinalRead)
        if let livenessAuthority {
            try revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: mutation.library,
                under: rootDescriptor
            )
        }
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.chatID,
            reconcileTransients: true,
            beforeDestructiveMutation: revalidateLiveness
        ), reopened == replacement else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return .committed(reopened)
    }

    public func discardPendingUserTurn(
        _ mutation: DiscardPendingUserTurnMutation,
        at libraryRoot: URL
    ) throws -> PortableChatMutationResult {
        try discardPendingUserTurn(
            mutation,
            at: libraryRoot,
            livenessAuthority: nil
        )
    }

    fileprivate func discardPendingUserTurn(
        _ mutation: DiscardPendingUserTurnMutation,
        at libraryRoot: URL,
        holding lease: PortableInvocationLivenessLease
    ) throws -> PortableChatMutationResult {
        guard let authority = lease.authority(for: PendingCoachInvocationRequest(
            library: mutation.library,
            chatID: mutation.chatID,
            pendingUserTurnID: mutation.pendingUserTurn.id
        )) else {
            throw PortableChatPersistenceError.ioFailure
        }
        return try discardPendingUserTurn(
            mutation,
            at: libraryRoot,
            livenessAuthority: authority
        )
    }

    private func discardPendingUserTurn(
        _ mutation: DiscardPendingUserTurnMutation,
        at libraryRoot: URL,
        livenessAuthority: PortableInvocationLivenessAuthority?
    ) throws -> PortableChatMutationResult {
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: mutation.library)
        defer { Darwin.close(rootDescriptor) }
        let revalidateLiveness: () throws -> Void = {
            guard let livenessAuthority else { return }
            try self.revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: mutation.library,
                under: rootDescriptor
            )
        }
        try revalidateLiveness()
        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let chatName = mutation.chatID.rawValue
        guard try entryExists(named: chatName, under: chatsDescriptor) else {
            throw PortableChatPersistenceError.chatMissing
        }
        let chatIdentity = try directoryIdentity(named: chatName, under: chatsDescriptor)
        let chatDescriptor = try openDirectory(named: chatName, under: chatsDescriptor)
        defer { Darwin.close(chatDescriptor) }
        guard try directoryIdentity(of: chatDescriptor) == chatIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        if let livenessAuthority {
            try revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: mutation.library,
                under: rootDescriptor
            )
        }
        let loaded = try loadChatForRename(
            from: chatDescriptor,
            expectedID: mutation.chatID,
            beforeDestructiveMutation: revalidateLiveness
        )
        guard case let .readWrite(current) = loaded else {
            if case let .frozen(frozen) = loaded { return .frozen(frozen) }
            throw PortableChatPersistenceError.invalidLayout
        }
        if current.pendingUserTurn == nil,
           current.chat.draft.draftID == mutation.pendingUserTurn.draftID,
           current.chat.draft.version == mutation.pendingUserTurn.draftVersion
        {
            return .committed(current)
        }
        guard current.pendingUserTurn == mutation.pendingUserTurn else {
            return .stale(current)
        }
        let pendingMutationLease: PortablePendingUserTurnFileLease?
        if livenessAuthority == nil {
            guard let lease = try acquirePendingUserTurnFileLease(
                under: chatDescriptor
            ) else {
                return .stale(current)
            }
            pendingMutationLease = lease
        } else {
            pendingMutationLease = nil
        }
        defer { pendingMutationLease?.release() }
        let replacement = try ChatAggregate(chat: current.chat, memory: current.memory)
        try fault(.beforePendingRemoval)
        if let livenessAuthority {
            try revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: mutation.library,
                under: rootDescriptor
            )
        } else {
            try revalidateLibraryAuthority(
                libraryID: mutation.library.libraryID,
                under: rootDescriptor
            )
        }
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              try directoryIdentity(of: chatDescriptor) == chatIdentity,
              "pending-user-turn.json".withCString({
                  Darwin.unlinkat(chatDescriptor, $0, 0)
              }) == 0
        else {
            throw PortableChatPersistenceError.ioFailure
        }
        try fault(.afterPendingRemoval)
        try flushDescriptor(chatDescriptor)
        try fault(.afterPendingRemovalDirectoryFlush)
        if let livenessAuthority {
            try revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: mutation.library,
                under: rootDescriptor
            )
        }
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.chatID,
            reconcileTransients: true,
            beforeDestructiveMutation: revalidateLiveness
        ), reopened == replacement else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return .committed(reopened)
    }

    func hasActiveInvocation(
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> Bool {
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(named: "staging", under: rootDescriptor)
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        return try hasActiveInvocation(
            under: rootDescriptor,
            expectedLibraryID: scope.libraryID
        )
    }

    fileprivate func hasActiveInvocation(
        at libraryRoot: URL,
        in scope: LibraryScope,
        holding lease: PortableInvocationLivenessLease
    ) throws -> Bool {
        guard let authority = lease.authority() else {
            throw PortableChatPersistenceError.ioFailure
        }
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(named: "staging", under: rootDescriptor)
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        let revalidateLiveness = invocationLivenessRevalidator(
            authority,
            at: libraryRoot,
            in: scope,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
        try revalidateLiveness()
        return try hasActiveInvocation(
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor,
            expectedLibraryID: scope.libraryID,
            beforeDestructiveMutation: revalidateLiveness
        )
    }

    /// A freshly composed process has no live provider task for an Invocation
    /// left by its predecessor. Under the Library mutation lock, either finish
    /// committed-publication cleanup or retire that one interrupted authority.
    func reconcileInterruptedInvocations(
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws {
        try reconcileInterruptedInvocations(
            at: libraryRoot,
            in: scope,
            livenessAuthority: nil,
            reservedRequest: nil
        )
    }

    fileprivate func reconcileInterruptedInvocations(
        at libraryRoot: URL,
        in scope: LibraryScope,
        holding lease: PortableInvocationLivenessLease
    ) throws {
        guard let reservation = lease.reservation() else {
            throw PortableChatPersistenceError.ioFailure
        }
        try reconcileInterruptedInvocations(
            at: libraryRoot,
            in: scope,
            livenessAuthority: reservation.authority,
            reservedRequest: reservation.request
        )
    }

    private func reconcileInterruptedInvocations(
        at libraryRoot: URL,
        in scope: LibraryScope,
        holding lease: PortableInvocationRecoveryLease
    ) throws {
        guard let authority = lease.authority() else {
            throw PortableChatPersistenceError.ioFailure
        }
        try reconcileInterruptedInvocations(
            at: libraryRoot,
            in: scope,
            livenessAuthority: authority,
            reservedRequest: nil
        )
    }

    private func reconcileInterruptedInvocations(
        at libraryRoot: URL,
        in scope: LibraryScope,
        livenessAuthority: PortableInvocationLivenessAuthority?,
        reservedRequest: PendingCoachInvocationRequest?
    ) throws {
        try fault(.beforeInvocationReconciliation)
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(named: "staging", under: rootDescriptor)
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        let validateLiveness = invocationLivenessRevalidator(
            livenessAuthority,
            at: libraryRoot,
            in: scope,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
        try validateLiveness()
        let revalidateBeforeMutation: () throws -> Void = if livenessAuthority != nil {
            {
                try fault(.beforeInvocationReconciliationCommit)
                try validateLiveness()
            }
        } else {
            {}
        }
        try reconcileInvocationPartials(
            under: invocationsDescriptor,
            beforeRemoving: revalidateBeforeMutation
        )

        let candidates = try invocationDirectoryNamesRemovingEmptyResidue(
            under: invocationsDescriptor,
            beforeRemoving: revalidateBeforeMutation
        )
        guard candidates.count <= 1 else {
            throw PortableChatPersistenceError.invalidLayout
        }
        guard let name = candidates.first,
              let invocationID = try? CoachInvocationID(name)
        else { return }
        let invocationRoot = try openDirectory(named: name, under: invocationsDescriptor)
        defer { Darwin.close(invocationRoot) }
        guard try listEntryNames(under: invocationRoot, maximumCount: 2) ==
            ["invocation.json"]
        else { throw PortableChatPersistenceError.invalidLayout }
        let invocation = try decodeInvocation(
            boundedData(named: "invocation.json", under: invocationRoot)
        )
        guard invocation.id == invocationID,
              invocation.libraryID == scope.libraryID
        else { throw PortableChatPersistenceError.invalidLayout }

        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        guard try entryExists(named: invocation.chatID.rawValue, under: chatsDescriptor) else {
            try removeInvocationDirectoryIfPresent(
                invocation,
                under: invocationsDescriptor,
                beforeRemoving: revalidateBeforeMutation
            )
            return
        }
        let chatDescriptor = try openDirectory(
            named: invocation.chatID.rawValue,
            under: chatsDescriptor
        )
        defer { Darwin.close(chatDescriptor) }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        var recoveryPendingLease: PortablePendingUserTurnFileLease?
        let invocationRequest = PendingCoachInvocationRequest(
            library: scope,
            chatID: invocation.chatID,
            pendingUserTurnID: invocation.pendingUserTurnID
        )
        if try entryExists(named: "pending-user-turn.json", under: chatDescriptor) {
            if invocationRequest == reservedRequest,
               let expectedPending = livenessAuthority?.pendingUserTurn
            {
                guard try regularFileLivenessIdentity(
                    named: "pending-user-turn.json",
                    under: chatDescriptor
                ) == expectedPending else {
                    throw PortableChatPersistenceError.invalidLayout
                }
            } else {
                guard let lease = try acquirePendingUserTurnFileLease(
                    under: chatDescriptor
                ) else {
                    throw PortableChatPersistenceError.ioFailure
                }
                recoveryPendingLease = lease
            }
        } else if invocationRequest == reservedRequest,
                  livenessAuthority?.pendingUserTurn != nil
        {
            throw PortableChatPersistenceError.invalidLayout
        }
        defer { recoveryPendingLease?.release() }
        try revalidateBeforeMutation()
        guard case let .readWrite(current) = try loadChat(
            from: chatDescriptor,
            expectedID: invocation.chatID,
            reconcileTransients: true,
            beforeDestructiveMutation: revalidateBeforeMutation
        ) else { throw PortableChatPersistenceError.invalidLayout }

        if try invocationWasPublished(
            invocation,
            aggregate: current,
            under: chatDescriptor
        ) {
            try removeInvocationDirectoryIfPresent(
                invocation,
                under: invocationsDescriptor,
                beforeRemoving: revalidateBeforeMutation
            )
            return
        }
        guard (try? invocation.validateIntent(against: current)) != nil else {
            try removeInvocationDirectoryIfPresent(
                invocation,
                under: invocationsDescriptor,
                beforeRemoving: revalidateBeforeMutation
            )
            return
        }
        _ = try retireInvocation(
            invocation,
            current: current,
            invocationRoot: invocationRoot,
            invocationsDescriptor: invocationsDescriptor,
            chatDescriptor: chatDescriptor,
            beforeCommitting: revalidateBeforeMutation
        )
    }

    fileprivate func checkLaunchIdentity(
        _ identity: InvocationLaunchIdentity,
        for authority: InvocationPendingAuthority,
        at libraryRoot: URL,
        holding lease: PortableInvocationLivenessLease
    ) throws -> InvocationLaunchIdentityAvailabilityOutcome {
        guard let livenessAuthority = lease.authority(for: authority.request) else {
            throw PortableChatPersistenceError.ioFailure
        }
        let rootDescriptor = try openLibraryRoot(
            at: libraryRoot,
            in: authority.request.library
        )
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(named: "staging", under: rootDescriptor)
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        let revalidateLiveness = invocationLivenessRevalidator(
            livenessAuthority,
            at: libraryRoot,
            in: authority.request.library,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
        try revalidateLiveness()

        var collision: InvocationLaunchIdentityCollision?
        func recordCollision(_ candidate: InvocationLaunchIdentityCollision) {
            if collision == nil { collision = candidate }
        }
        if try entryExists(
            named: identity.invocationID.rawValue,
            under: invocationsDescriptor
        ) {
            recordCollision(.invocationID)
        }
        for invocationName in try invocationDirectoryNamesRemovingEmptyResidue(
            under: invocationsDescriptor,
            beforeRemoving: revalidateLiveness
        ) {
            let invocationDescriptor = try openDirectory(
                named: invocationName,
                under: invocationsDescriptor
            )
            defer { Darwin.close(invocationDescriptor) }
            let existing = try decodeInvocation(
                boundedData(named: "invocation.json", under: invocationDescriptor)
            )
            if existing.attemptID == identity.attemptID {
                recordCollision(.attemptID)
            }
            if existing.providerIdempotencyValue == identity.idempotencyValue {
                recordCollision(.providerIdempotencyValue)
            }
        }
        if identity.userMessageID == identity.coachMessageID {
            recordCollision(.coachMessageID)
        }

        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        var current: ChatAggregate?
        let chatNames = try listEntryNames(
            under: chatsDescriptor,
            maximumCount: Self.maximumChatCatalogEntries
        )
        for chatName in chatNames {
            guard let chatID = try? ChatID(chatName) else { continue }
            let chatDescriptor: Int32
            do {
                chatDescriptor = try openDirectory(
                    named: chatName,
                    under: chatsDescriptor
                )
            } catch let error as PortableChatPersistenceError {
                if error == .invalidLayout,
                   (try? directoryIdentity(
                       named: chatName,
                       under: chatsDescriptor
                   )) != nil
                {
                    throw PortableChatPersistenceError.ioFailure
                }
                guard frozenChatSnapshot(for: error, chatID: chatID) != nil else {
                    throw error
                }
                continue
            } catch {
                throw error
            }
            defer { Darwin.close(chatDescriptor) }
            if chatID == authority.request.chatID {
                try acquireExclusiveMutationLock(on: chatDescriptor)
                defer { releaseMutationLock(on: chatDescriptor) }
                guard let expectedPending = livenessAuthority.pendingUserTurn,
                      try regularFileLivenessIdentity(
                          named: "pending-user-turn.json",
                          under: chatDescriptor
                      ) == expectedPending
                else { throw PortableChatPersistenceError.invalidLayout }
            }

            do {
                let messagesDescriptor = try openDirectory(
                    named: "messages",
                    under: chatDescriptor
                )
                defer { Darwin.close(messagesDescriptor) }
                if try entryExists(
                    named: "\(identity.userMessageID.rawValue).json",
                    under: messagesDescriptor
                ) {
                    recordCollision(.userMessageID)
                }
                if try entryExists(
                    named: "\(identity.coachMessageID.rawValue).json",
                    under: messagesDescriptor
                ) {
                    recordCollision(.coachMessageID)
                }
            } catch let error as PortableChatPersistenceError {
                if error == .invalidLayout,
                   (try? directoryIdentity(
                       named: "messages",
                       under: chatDescriptor
                   )) != nil
                {
                    throw PortableChatPersistenceError.ioFailure
                }
                guard frozenChatSnapshot(for: error, chatID: chatID) != nil else {
                    throw error
                }
                // Invalid sibling layout freezes that Chat. Transient I/O is
                // not equivalent to proving the candidate namespace free.
            } catch {
                throw error
            }

            if chatID == authority.request.chatID {
                let loaded = try loadChat(
                    from: chatDescriptor,
                    expectedID: chatID,
                    reconcileTransients: true,
                    beforeDestructiveMutation: revalidateLiveness
                )
                guard case let .readWrite(aggregate) = loaded else {
                    return .stale(nil)
                }
                current = aggregate
                if aggregate.chat.messageIDs.contains(identity.userMessageID) {
                    recordCollision(.userMessageID)
                }
                if aggregate.chat.messageIDs.contains(identity.coachMessageID) {
                    recordCollision(.coachMessageID)
                }
                if aggregate.chat.draft.draftID == identity.freshDraftID {
                    recordCollision(.freshDraftID)
                }
            } else {
                do {
                    let manifest = try boundedData(
                        named: "chat.json",
                        under: chatDescriptor
                    )
                    // Sibling Chats are independent failure domains. Their bounded
                    // root bytes are sufficient for conservative identity
                    // detection even when a newer schema or corruption makes the
                    // aggregate permanently frozen. A literal hit may regenerate
                    // unnecessarily, but can never admit a known collision.
                    if manifest.range(
                        of: Data(identity.userMessageID.rawValue.utf8)
                    ) != nil {
                        recordCollision(.userMessageID)
                    }
                    if manifest.range(
                        of: Data(identity.coachMessageID.rawValue.utf8)
                    ) != nil {
                        recordCollision(.coachMessageID)
                    }
                    if manifest.range(
                        of: Data(identity.freshDraftID.rawValue.utf8)
                    ) != nil {
                        recordCollision(.freshDraftID)
                    }
                } catch let error as PortableChatPersistenceError {
                    if error == .invalidLayout,
                       isRegularFile(named: "chat.json", under: chatDescriptor)
                    {
                        throw PortableChatPersistenceError.ioFailure
                    }
                    guard frozenChatSnapshot(for: error, chatID: chatID) != nil else {
                        throw error
                    }
                    // This sibling has no readable root identity to reserve.
                } catch {
                    throw error
                }
            }
        }
        guard let current else { return .stale(nil) }
        guard current == authority.aggregate else { return .stale(current) }
        try revalidateLiveness()
        if let collision { return .collision(collision) }
        return .available
    }

    func installInvocation(
        _ mutation: InstallCoachInvocationMutation,
        at libraryRoot: URL
    ) throws -> InvocationInstallOutcome {
        try installInvocation(
            mutation,
            at: libraryRoot,
            livenessAuthority: nil
        )
    }

    fileprivate func installInvocation(
        _ mutation: InstallCoachInvocationMutation,
        at libraryRoot: URL,
        holding lease: PortableInvocationLivenessLease
    ) throws -> InvocationInstallOutcome {
        guard let authority = lease.authority(for: mutation.authority.request) else {
            throw PortableChatPersistenceError.ioFailure
        }
        return try installInvocation(
            mutation,
            at: libraryRoot,
            livenessAuthority: authority
        )
    }

    private func installInvocation(
        _ mutation: InstallCoachInvocationMutation,
        at libraryRoot: URL,
        livenessAuthority: PortableInvocationLivenessAuthority?
    ) throws -> InvocationInstallOutcome {
        let rootDescriptor = try openLibraryRoot(
            at: libraryRoot,
            in: mutation.authority.request.library
        )
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(named: "staging", under: rootDescriptor)
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        let revalidateLiveness = invocationLivenessRevalidator(
            livenessAuthority,
            at: libraryRoot,
            in: mutation.authority.request.library,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
        try revalidateLiveness()
        try reconcileInvocationPartials(
            under: invocationsDescriptor,
            beforeRemoving: revalidateLiveness
        )
        if try hasActiveInvocation(
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor,
            expectedLibraryID: mutation.authority.request.library.libraryID,
            beforeDestructiveMutation: revalidateLiveness
        ) { return .activeExists }

        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let chatName = mutation.authority.request.chatID.rawValue
        guard try entryExists(named: chatName, under: chatsDescriptor) else {
            return .stale(nil)
        }
        let chatIdentity = try directoryIdentity(named: chatName, under: chatsDescriptor)
        let chatDescriptor = try openDirectory(named: chatName, under: chatsDescriptor)
        defer { Darwin.close(chatDescriptor) }
        guard try directoryIdentity(of: chatDescriptor) == chatIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        try revalidateLiveness()
        guard case let .readWrite(current) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.authority.request.chatID,
            reconcileTransients: true,
            beforeDestructiveMutation: revalidateLiveness
        ) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        guard current == mutation.authority.aggregate else { return .stale(current) }

        try fault(.beforeInvocationPartialWrite)
        let partialName = ".\(mutation.invocation.id.rawValue)." +
            "\(UUID().uuidString.lowercased()).partial"
        guard mkdirat(invocationsDescriptor, partialName, 0o700) == 0 else {
            throw PortableChatPersistenceError.ioFailure
        }
        var partialExists = true
        defer {
            if partialExists {
                removeInvocationCandidate(
                    named: partialName,
                    under: invocationsDescriptor
                )
            }
        }
        let partialDescriptor = try openDirectory(
            named: partialName,
            under: invocationsDescriptor
        )
        defer { Darwin.close(partialDescriptor) }
        let partialIdentity = try directoryIdentity(of: partialDescriptor)
        try writeExclusive(
            try encodeInvocation(mutation.invocation),
            named: "invocation.json",
            under: partialDescriptor
        )
        try fault(.afterInvocationPartialWrite)
        let invocationDescriptor = try openRegularFile(
            named: "invocation.json",
            under: partialDescriptor
        )
        defer { Darwin.close(invocationDescriptor) }
        try flushDescriptor(invocationDescriptor)
        try fault(.afterInvocationFileFlush)
        try flushDescriptor(partialDescriptor)
        if let livenessAuthority {
            try revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: mutation.authority.request.library,
                under: rootDescriptor,
                invocationsDescriptor: invocationsDescriptor
            )
        } else {
            try revalidateLibraryAuthority(
                libraryID: mutation.authority.request.library.libraryID,
                under: rootDescriptor
            )
        }
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              try directoryIdentity(of: chatDescriptor) == chatIdentity,
              try directoryIdentity(named: partialName, under: invocationsDescriptor) ==
              partialIdentity,
              try directoryIdentity(of: partialDescriptor) == partialIdentity,
              case let .readWrite(authority) = try loadChat(
                  from: chatDescriptor,
                  expectedID: mutation.authority.request.chatID,
                  reconcileTransients: false
              ),
              authority == current
        else {
            return .stale(current)
        }
        try noReplaceRename(
            from: partialName,
            under: invocationsDescriptor,
            to: mutation.invocation.id.rawValue,
            under: invocationsDescriptor
        )
        partialExists = false
        try fault(.afterInvocationInstall)
        try flushDescriptor(invocationsDescriptor)
        try fault(.afterInvocationDirectoryFlush)
        let installed = try decodeInvocation(
            boundedData(named: "invocation.json", under: partialDescriptor)
        )
        guard installed == mutation.invocation else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return .installed(installed)
    }

    func reconcileInstalledInvocation(
        _ mutation: InstallCoachInvocationMutation,
        at libraryRoot: URL
    ) throws -> CoachInvocation? {
        try reconcileInstalledInvocation(
            mutation,
            at: libraryRoot,
            livenessAuthority: nil
        )
    }

    fileprivate func reconcileInstalledInvocation(
        _ mutation: InstallCoachInvocationMutation,
        at libraryRoot: URL,
        holding lease: PortableInvocationLivenessLease
    ) throws -> CoachInvocation? {
        guard let authority = lease.authority(for: mutation.authority.request) else {
            throw PortableChatPersistenceError.ioFailure
        }
        return try reconcileInstalledInvocation(
            mutation,
            at: libraryRoot,
            livenessAuthority: authority
        )
    }

    private func reconcileInstalledInvocation(
        _ mutation: InstallCoachInvocationMutation,
        at libraryRoot: URL,
        livenessAuthority: PortableInvocationLivenessAuthority?
    ) throws -> CoachInvocation? {
        let scope = mutation.authority.request.library
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(named: "staging", under: rootDescriptor)
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        let revalidateLiveness = invocationLivenessRevalidator(
            livenessAuthority,
            at: libraryRoot,
            in: scope,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
        try revalidateLiveness()
        try reconcileInvocationPartials(
            under: invocationsDescriptor,
            beforeRemoving: revalidateLiveness
        )
        let invocationName = mutation.invocation.id.rawValue
        guard try entryExists(named: invocationName, under: invocationsDescriptor) else {
            return nil
        }
        let invocationRoot = try openDirectory(
            named: invocationName,
            under: invocationsDescriptor
        )
        defer { Darwin.close(invocationRoot) }

        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let chatName = mutation.authority.request.chatID.rawValue
        guard try entryExists(named: chatName, under: chatsDescriptor) else { return nil }
        let chatDescriptor = try openDirectory(named: chatName, under: chatsDescriptor)
        defer { Darwin.close(chatDescriptor) }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        try revalidateLiveness()
        guard case let .readWrite(current) = try loadChat(
                  from: chatDescriptor,
                  expectedID: mutation.authority.request.chatID,
                  reconcileTransients: true,
                  beforeDestructiveMutation: revalidateLiveness
              ),
              current == mutation.authority.aggregate
        else { return nil }
        let invocation = try decodeInvocation(
            boundedData(named: "invocation.json", under: invocationRoot)
        )
        guard invocation == mutation.invocation,
              invocation.libraryID == scope.libraryID
        else { return nil }
        try flushDescriptor(invocationRoot)
        try flushDescriptor(invocationsDescriptor)
        if let livenessAuthority {
            try revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: scope,
                under: rootDescriptor,
                invocationsDescriptor: invocationsDescriptor
            )
        } else {
            try revalidateLibraryAuthority(
                libraryID: scope.libraryID,
                under: rootDescriptor
            )
        }
        let confirmed = try decodeInvocation(
            boundedData(named: "invocation.json", under: invocationRoot)
        )
        return confirmed == invocation ? confirmed : nil
    }

    func abortInstalledNewSend(
        _ invocation: CoachInvocation,
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> PortableChatMutationResult {
        try abortInstalledNewSend(
            invocation,
            at: libraryRoot,
            in: scope,
            livenessAuthority: nil
        )
    }

    fileprivate func abortInstalledNewSend(
        _ invocation: CoachInvocation,
        at libraryRoot: URL,
        in scope: LibraryScope,
        holding lease: PortableInvocationLivenessLease
    ) throws -> PortableChatMutationResult {
        guard let authority = lease.authority(for: PendingCoachInvocationRequest(
            library: scope,
            chatID: invocation.chatID,
            pendingUserTurnID: invocation.pendingUserTurnID
        )) else {
            throw PortableChatPersistenceError.ioFailure
        }
        return try abortInstalledNewSend(
            invocation,
            at: libraryRoot,
            in: scope,
            livenessAuthority: authority
        )
    }

    private func abortInstalledNewSend(
        _ invocation: CoachInvocation,
        at libraryRoot: URL,
        in scope: LibraryScope,
        livenessAuthority: PortableInvocationLivenessAuthority?
    ) throws -> PortableChatMutationResult {
        guard invocation.libraryID == scope.libraryID else {
            throw PortableChatPersistenceError.libraryScopeMismatch
        }
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(named: "staging", under: rootDescriptor)
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        let revalidateLiveness = invocationLivenessRevalidator(
            livenessAuthority,
            at: libraryRoot,
            in: scope,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
        try revalidateLiveness()
        try reconcileInvocationPartials(
            under: invocationsDescriptor,
            beforeRemoving: revalidateLiveness
        )
        guard try entryExists(named: invocation.id.rawValue, under: invocationsDescriptor)
        else { throw PortableChatPersistenceError.invalidLayout }
        let invocationRoot = try openDirectory(
            named: invocation.id.rawValue,
            under: invocationsDescriptor
        )
        defer { Darwin.close(invocationRoot) }
        guard try listEntryNames(
            under: invocationRoot,
            maximumCount: 2
        ) == ["invocation.json"] else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let installed = try decodeInvocation(
            boundedData(named: "invocation.json", under: invocationRoot)
        )
        guard installed == invocation else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let chatName = invocation.chatID.rawValue
        guard try entryExists(named: chatName, under: chatsDescriptor) else {
            throw PortableChatPersistenceError.chatMissing
        }
        let chatDescriptor = try openDirectory(named: chatName, under: chatsDescriptor)
        defer { Darwin.close(chatDescriptor) }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        try revalidateLiveness()
        guard case let .readWrite(current) = try loadChat(
            from: chatDescriptor,
            expectedID: invocation.chatID,
            reconcileTransients: true,
            beforeDestructiveMutation: revalidateLiveness
        ) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        guard (try? invocation.validateIntent(against: current)) != nil else {
            if let livenessAuthority {
                try revalidateInvocationLivenessAuthority(
                    livenessAuthority,
                    at: libraryRoot,
                    in: scope,
                    under: rootDescriptor,
                    invocationsDescriptor: invocationsDescriptor
                )
            }
            try removeInvocationDirectoryIfPresent(
                invocation,
                under: invocationsDescriptor,
                beforeRemoving: revalidateLiveness
            )
            return .stale(current)
        }
        if let livenessAuthority {
            try revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: scope,
                under: rootDescriptor,
                invocationsDescriptor: invocationsDescriptor
            )
        }
        return .committed(
            try retireInvocation(
                invocation,
                current: current,
                invocationRoot: invocationRoot,
                invocationsDescriptor: invocationsDescriptor,
                chatDescriptor: chatDescriptor,
                beforeCommitting: revalidateLiveness
            )
        )
    }

    func publishInvocation(
        _ mutation: PublishCoachInvocationMutation,
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> PortableChatMutationResult {
        try publishInvocation(
            mutation,
            at: libraryRoot,
            in: scope,
            livenessAuthority: nil
        )
    }

    fileprivate func publishInvocation(
        _ mutation: PublishCoachInvocationMutation,
        at libraryRoot: URL,
        in scope: LibraryScope,
        holding lease: PortableInvocationLivenessLease
    ) throws -> PortableChatMutationResult {
        guard let authority = lease.authority(for: PendingCoachInvocationRequest(
            library: scope,
            chatID: mutation.invocation.chatID,
            pendingUserTurnID: mutation.invocation.pendingUserTurnID
        )) else {
            throw PortableChatPersistenceError.ioFailure
        }
        return try publishInvocation(
            mutation,
            at: libraryRoot,
            in: scope,
            livenessAuthority: authority
        )
    }

    private func publishInvocation(
        _ mutation: PublishCoachInvocationMutation,
        at libraryRoot: URL,
        in scope: LibraryScope,
        livenessAuthority: PortableInvocationLivenessAuthority?
    ) throws -> PortableChatMutationResult {
        guard mutation.invocation.libraryID == scope.libraryID else {
            throw PortableChatPersistenceError.libraryScopeMismatch
        }
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(named: "staging", under: rootDescriptor)
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        let revalidateLiveness = invocationLivenessRevalidator(
            livenessAuthority,
            at: libraryRoot,
            in: scope,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
        try revalidateLiveness()
        try reconcileInvocationPartials(
            under: invocationsDescriptor,
            beforeRemoving: revalidateLiveness
        )
        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let chatName = mutation.invocation.chatID.rawValue
        guard try entryExists(named: chatName, under: chatsDescriptor) else {
            throw PortableChatPersistenceError.chatMissing
        }
        let chatIdentity = try directoryIdentity(named: chatName, under: chatsDescriptor)
        let chatDescriptor = try openDirectory(named: chatName, under: chatsDescriptor)
        defer { Darwin.close(chatDescriptor) }
        guard try directoryIdentity(of: chatDescriptor) == chatIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        try revalidateLiveness()
        guard case let .readWrite(current) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.invocation.chatID,
            reconcileTransients: true,
            beforeDestructiveMutation: revalidateLiveness
        ) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        if current == mutation.replacement {
            try removeInvocationDirectoryIfPresent(
                mutation.invocation,
                under: invocationsDescriptor,
                beforeRemoving: revalidateLiveness
            )
            return .committed(current)
        }
        guard current == mutation.base else { return .stale(current) }
        guard try entryExists(
            named: mutation.invocation.id.rawValue,
            under: invocationsDescriptor
        ) else { return .stale(current) }
        let invocationRoot = try openDirectory(
            named: mutation.invocation.id.rawValue,
            under: invocationsDescriptor
        )
        defer { Darwin.close(invocationRoot) }
        let installedInvocation = try decodeInvocation(
            boundedData(named: "invocation.json", under: invocationRoot)
        )
        guard installedInvocation == mutation.invocation else { return .stale(current) }

        let messagesDescriptor = try openDirectory(named: "messages", under: chatDescriptor)
        defer { Darwin.close(messagesDescriptor) }
        try revalidateLiveness()
        try installMessage(
            mutation.userMessage,
            under: messagesDescriptor,
            installedFault: .afterUserMessageInstall
        )
        try revalidateLiveness()
        try installMessage(
            mutation.coachMessage,
            under: messagesDescriptor,
            installedFault: .afterCoachMessageInstall
        )

        let partialName = ".chat.json.\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString { Darwin.unlinkat(chatDescriptor, $0, 0) }
            }
        }
        try writeExclusive(
            try encodeChat(mutation.replacement.chat),
            named: partialName,
            under: chatDescriptor
        )
        partialExists = true
        let partialDescriptor = try openRegularFile(named: partialName, under: chatDescriptor)
        defer { Darwin.close(partialDescriptor) }
        try flushDescriptor(partialDescriptor)
        try fault(.afterPublicationManifestFileFlush)
        if let livenessAuthority {
            try revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: scope,
                under: rootDescriptor,
                invocationsDescriptor: invocationsDescriptor
            )
        } else {
            try revalidateLibraryAuthority(
                libraryID: scope.libraryID,
                under: rootDescriptor
            )
        }
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              try directoryIdentity(of: chatDescriptor) == chatIdentity,
              case let .readWrite(authority) = try loadChat(
                  from: chatDescriptor,
                  expectedID: mutation.invocation.chatID,
                  reconcileTransients: false
              ),
              authority == current
        else {
            return .stale(current)
        }
        guard renameat(chatDescriptor, partialName, chatDescriptor, "chat.json") == 0 else {
            throw PortableChatPersistenceError.ioFailure
        }
        partialExists = false
        try fault(.afterPublicationManifestInstall)
        try flushDescriptor(chatDescriptor)
        try fault(.afterPublicationManifestDirectoryFlush)
        try fault(.beforePublicationCleanup)
        try revalidateLiveness()
        try removeRegularFileIfPresent(named: "pending-user-turn.json", under: chatDescriptor)
        try removeInvocationDirectoryIfPresent(
            mutation.invocation,
            under: invocationsDescriptor,
            beforeRemoving: revalidateLiveness
        )
        try revalidateLiveness()
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.invocation.chatID,
            reconcileTransients: true,
            beforeDestructiveMutation: revalidateLiveness
        ), reopened == mutation.replacement else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return .committed(reopened)
    }

    func reconcileCommittedInvocationPublication(
        _ mutation: PublishCoachInvocationMutation,
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> ChatAggregate? {
        try reconcileCommittedInvocationPublication(
            mutation,
            at: libraryRoot,
            in: scope,
            livenessAuthority: nil
        )
    }

    fileprivate func reconcileCommittedInvocationPublication(
        _ mutation: PublishCoachInvocationMutation,
        at libraryRoot: URL,
        in scope: LibraryScope,
        holding lease: PortableInvocationLivenessLease
    ) throws -> ChatAggregate? {
        guard let authority = lease.authority(for: PendingCoachInvocationRequest(
            library: scope,
            chatID: mutation.invocation.chatID,
            pendingUserTurnID: mutation.invocation.pendingUserTurnID
        )) else {
            throw PortableChatPersistenceError.ioFailure
        }
        return try reconcileCommittedInvocationPublication(
            mutation,
            at: libraryRoot,
            in: scope,
            livenessAuthority: authority
        )
    }

    private func reconcileCommittedInvocationPublication(
        _ mutation: PublishCoachInvocationMutation,
        at libraryRoot: URL,
        in scope: LibraryScope,
        livenessAuthority: PortableInvocationLivenessAuthority?
    ) throws -> ChatAggregate? {
        guard mutation.invocation.libraryID == scope.libraryID else {
            throw PortableChatPersistenceError.libraryScopeMismatch
        }
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(named: "staging", under: rootDescriptor)
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        let revalidateLiveness = invocationLivenessRevalidator(
            livenessAuthority,
            at: libraryRoot,
            in: scope,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
        try revalidateLiveness()
        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let chatName = mutation.invocation.chatID.rawValue
        guard try entryExists(named: chatName, under: chatsDescriptor) else { return nil }
        let chatIdentity = try directoryIdentity(named: chatName, under: chatsDescriptor)
        let chatDescriptor = try openDirectory(named: chatName, under: chatsDescriptor)
        defer { Darwin.close(chatDescriptor) }
        guard try directoryIdentity(of: chatDescriptor) == chatIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        try revalidateLiveness()
        try fault(.beforePublicationReconciliationRead)
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              try directoryIdentity(of: chatDescriptor) == chatIdentity,
              case let .readWrite(aggregate) = try loadChat(
                  from: chatDescriptor,
                  expectedID: mutation.invocation.chatID,
                  reconcileTransients: true,
                  beforeDestructiveMutation: revalidateLiveness
              ),
              aggregate == mutation.replacement
        else { return nil }
        try removeInvocationDirectoryIfPresent(
            mutation.invocation,
            under: invocationsDescriptor,
            beforeRemoving: revalidateLiveness
        )
        return aggregate
    }

    fileprivate func reconcileCommittedCreate(
        _ seed: NewDevelopmentChatSeed,
        at libraryRoot: URL
    ) throws -> ChatAggregate? {
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: seed.library)
        defer { Darwin.close(rootDescriptor) }
        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let finalName = seed.aggregate.chat.id.rawValue
        guard try entryExists(named: finalName, under: chatsDescriptor) else {
            return nil
        }
        let installedIdentity = try directoryIdentity(
            named: finalName,
            under: chatsDescriptor
        )
        let chatDescriptor = try openDirectory(named: finalName, under: chatsDescriptor)
        defer { Darwin.close(chatDescriptor) }
        guard try directoryIdentity(of: chatDescriptor) == installedIdentity,
              case let .readWrite(installed) = try loadChatReconcilingTransients(
                  from: chatDescriptor,
                  expectedID: seed.aggregate.chat.id
              ),
              installed == seed.aggregate
        else {
            return nil
        }

        try flushDescriptor(chatsDescriptor)
        guard try directoryIdentity(
            named: finalName,
            under: chatsDescriptor
        ) == installedIdentity,
              case let .readWrite(confirmed) = try loadChatReconcilingTransients(
                  from: chatDescriptor,
                  expectedID: seed.aggregate.chat.id
              ),
              confirmed == seed.aggregate
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return confirmed
    }

    fileprivate func reconcileCommittedRename(
        _ mutation: RenameChatMutation,
        at libraryRoot: URL
    ) throws -> ChatAggregate? {
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: mutation.library)
        defer { Darwin.close(rootDescriptor) }
        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let chatName = mutation.chatID.rawValue
        guard try entryExists(named: chatName, under: chatsDescriptor) else {
            return nil
        }
        let chatIdentity = try directoryIdentity(named: chatName, under: chatsDescriptor)
        let chatDescriptor = try openDirectory(named: chatName, under: chatsDescriptor)
        defer { Darwin.close(chatDescriptor) }
        guard try directoryIdentity(of: chatDescriptor) == chatIdentity,
              case let .readWrite(renamed) = try loadChatReconcilingTransients(
                  from: chatDescriptor,
                  expectedID: mutation.chatID
              ),
              renamed == mutation.replacement
        else {
            return nil
        }

        try flushDescriptor(chatDescriptor)
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              case let .readWrite(confirmed) = try loadChatReconcilingTransients(
                  from: chatDescriptor,
                  expectedID: mutation.chatID
              ),
              confirmed == mutation.replacement
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return confirmed
    }

    fileprivate func reconcileCommittedDraft(
        _ mutation: SaveChatDraftMutation,
        at libraryRoot: URL
    ) throws -> ChatAggregate? {
        try reconcileCommittedMutation(
            in: mutation.library,
            chatID: mutation.chatID,
            at: libraryRoot
        ) { aggregate in
            aggregate.chat.draft == mutation.replacement
        }
    }

    fileprivate func reconcileCommittedPendingLock(
        _ mutation: LockPendingUserTurnMutation,
        at libraryRoot: URL
    ) throws -> ChatAggregate? {
        try reconcileCommittedMutation(
            in: mutation.library,
            chatID: mutation.chatID,
            at: libraryRoot
        ) { aggregate in
            aggregate.pendingUserTurn == mutation.pendingUserTurn
        }
    }

    fileprivate func reconcileCommittedPendingReplacement(
        _ mutation: ReplacePendingUserTurnMutation,
        at libraryRoot: URL
    ) throws -> ChatAggregate? {
        try reconcileCommittedMutation(
            in: mutation.library,
            chatID: mutation.chatID,
            at: libraryRoot
        ) { aggregate in
            aggregate.pendingUserTurn == mutation.replacement
        }
    }

    fileprivate func reconcileCommittedPendingReplacement(
        _ mutation: ReplacePendingUserTurnMutation,
        at libraryRoot: URL,
        holding lease: PortableInvocationLivenessLease
    ) throws -> ChatAggregate? {
        guard let authority = lease.authority(for: PendingCoachInvocationRequest(
            library: mutation.library,
            chatID: mutation.chatID,
            pendingUserTurnID: mutation.base.id
        )) else {
            throw PortableChatPersistenceError.ioFailure
        }
        return try reconcileCommittedMutation(
            in: mutation.library,
            chatID: mutation.chatID,
            at: libraryRoot,
            livenessAuthority: authority
        ) { aggregate in
            aggregate.pendingUserTurn == mutation.replacement
        }
    }

    fileprivate func reconcileCommittedPendingDiscard(
        _ mutation: DiscardPendingUserTurnMutation,
        at libraryRoot: URL
    ) throws -> ChatAggregate? {
        try reconcileCommittedMutation(
            in: mutation.library,
            chatID: mutation.chatID,
            at: libraryRoot
        ) { aggregate in
            aggregate.pendingUserTurn == nil &&
                aggregate.chat.draft.draftID == mutation.pendingUserTurn.draftID &&
                aggregate.chat.draft.version == mutation.pendingUserTurn.draftVersion
        }
    }

    fileprivate func reconcileCommittedPendingDiscard(
        _ mutation: DiscardPendingUserTurnMutation,
        at libraryRoot: URL,
        holding lease: PortableInvocationLivenessLease
    ) throws -> ChatAggregate? {
        guard let authority = lease.authority(for: PendingCoachInvocationRequest(
            library: mutation.library,
            chatID: mutation.chatID,
            pendingUserTurnID: mutation.pendingUserTurn.id
        )) else {
            throw PortableChatPersistenceError.ioFailure
        }
        return try reconcileCommittedMutation(
            in: mutation.library,
            chatID: mutation.chatID,
            at: libraryRoot,
            livenessAuthority: authority
        ) { aggregate in
            aggregate.pendingUserTurn == nil &&
                aggregate.chat.draft.draftID == mutation.pendingUserTurn.draftID &&
                aggregate.chat.draft.version == mutation.pendingUserTurn.draftVersion
        }
    }

    private func reconcileCommittedMutation(
        in library: LibraryScope,
        chatID: ChatID,
        at libraryRoot: URL,
        livenessAuthority: PortableInvocationLivenessAuthority? = nil,
        matches: (ChatAggregate) -> Bool
    ) throws -> ChatAggregate? {
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: library)
        defer { Darwin.close(rootDescriptor) }
        let revalidateLiveness: () throws -> Void = {
            guard let livenessAuthority else { return }
            try self.revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: library,
                under: rootDescriptor
            )
        }
        try revalidateLiveness()
        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let chatName = chatID.rawValue
        guard try entryExists(named: chatName, under: chatsDescriptor) else {
            return nil
        }
        let chatIdentity = try directoryIdentity(named: chatName, under: chatsDescriptor)
        let chatDescriptor = try openDirectory(named: chatName, under: chatsDescriptor)
        defer { Darwin.close(chatDescriptor) }
        guard try directoryIdentity(of: chatDescriptor) == chatIdentity else {
            return nil
        }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        if let livenessAuthority {
            try revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: library,
                under: rootDescriptor
            )
        }
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              try directoryIdentity(of: chatDescriptor) == chatIdentity,
              case let .readWrite(installed) = try loadChat(
                  from: chatDescriptor,
                  expectedID: chatID,
                  reconcileTransients: true,
                  beforeDestructiveMutation: revalidateLiveness
              ),
              matches(installed)
        else {
            return nil
        }

        try flushDescriptor(chatDescriptor)
        if let livenessAuthority {
            try revalidateInvocationLivenessAuthority(
                livenessAuthority,
                at: libraryRoot,
                in: library,
                under: rootDescriptor
            )
        } else {
            try revalidateLibraryAuthority(
                libraryID: library.libraryID,
                under: rootDescriptor
            )
        }
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              try directoryIdentity(of: chatDescriptor) == chatIdentity,
              case let .readWrite(confirmed) = try loadChat(
                  from: chatDescriptor,
                  expectedID: chatID,
                  reconcileTransients: true,
                  beforeDestructiveMutation: revalidateLiveness
              ),
              matches(confirmed)
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return confirmed
    }

    public func encodeChat(_ chat: Chat) throws -> Data {
        let data = try deterministicJSON(
            ChatDTO(
                schemaVersion: 1,
                chatId: chat.id.rawValue,
                manifestRevision: chat.manifestRevision,
                title: chat.title.rawValue,
                createdAt: chat.createdAt.rawValue,
                updatedAt: chat.updatedAt.rawValue,
                creationKind: chat.creation.kind.rawValue,
                originAttachmentId: chat.creation.originAttachmentID?.rawValue,
                profileStatementGenerationAtCreation: chat.profileStatementGenerationAtCreation,
                attachments: chat.attachments.values.map {
                    ChatAttachmentDTO(
                        attachmentId: $0.attachmentID.rawValue,
                        sessionId: $0.sessionID.rawValue,
                        transcriptRevisionId: $0.transcriptRevisionID.rawValue
                    )
                },
                draft: ChatDraftDTO(
                    draftId: chat.draft.draftID.rawValue,
                    version: chat.draft.version,
                    text: chat.draft.text,
                    updatedAt: chat.draft.updatedAt.rawValue
                ),
                messageIds: chat.messageIDs.map(\.rawValue),
                currentMemoryId: chat.currentMemoryID.rawValue
            )
        )
        guard data.count <= Self.maximumRootBytes else {
            throw PortableChatPersistenceError.rootTooLarge
        }
        return data
    }

    public func encodeMemory(_ memory: CoachMemory) throws -> Data {
        try deterministicJSON(
            CoachMemoryDTO(
                schemaVersion: 1,
                memoryId: memory.memoryID.rawValue,
                chatId: memory.chatID.rawValue,
                generalNotes: memory.generalNotes,
                sessionSummaries: memory.sessionSummaries.map {
                    CoachMemorySummaryDTO(
                        sessionAttachmentId: $0.sessionAttachmentID.rawValue,
                        notes: $0.notes
                    )
                }
            )
        )
    }

    public func encodePendingUserTurn(_ pending: PendingUserTurn) throws -> Data {
        try deterministicJSON(
            PendingUserTurnDTO(
                schemaVersion: PendingUserTurn.schemaVersion,
                pendingUserTurnId: pending.id.rawValue,
                draftId: pending.draftID.rawValue,
                draftVersion: pending.draftVersion,
                responsePositionId: pending.responsePositionID.rawValue,
                failure: pending.failure?.rawValue
            )
        )
    }

    @_spi(InvocationInfrastructure)
    public func encodeMessage(_ message: ChatMessage) throws -> Data {
        let role: String
        let text: String?
        let markdown: String?
        switch message.content {
        case let .user(value):
            role = "user"
            text = value
            markdown = nil
        case let .coach(value):
            role = "coach"
            text = nil
            markdown = value
        }
        let data = try deterministicJSON(
            ChatMessageDTO(
                schemaVersion: message.persistedSchemaVersion,
                messageId: message.id.rawValue,
                responsePositionId: message.responsePositionID.rawValue,
                role: role,
                text: text,
                markdown: markdown,
                profileRevisionId: message.coachProfile?.revisionID?.rawValue,
                profileStatementGeneration: message.coachProfile?.statementGeneration,
                createdAt: message.createdAt.rawValue
            )
        )
        guard data.count <= Self.maximumRootBytes else {
            throw PortableChatPersistenceError.rootTooLarge
        }
        return data
    }

    @_spi(InvocationInfrastructure)
    public func encodeInvocation(_ invocation: CoachInvocation) throws -> Data {
        let data = try deterministicJSON(
            CoachInvocationDTO(
                schemaVersion: invocation.persistedSchemaVersion,
                invocationId: invocation.id.rawValue,
                attemptId: invocation.attemptID.rawValue,
                providerIdempotencyValue: invocation.providerIdempotencyValue.rawValue,
                libraryId: invocation.libraryID.rawValue,
                chatId: invocation.chatID.rawValue,
                pendingUserTurnId: invocation.pendingUserTurnID.rawValue,
                draftId: invocation.draftID.rawValue,
                draftVersion: invocation.draftVersion,
                responsePositionId: invocation.responsePositionID.rawValue,
                expectedManifestRevision: invocation.expectedManifestRevision,
                profileRevisionId: invocation.preparedProfile?.revisionID?.rawValue,
                profileStatementGeneration:
                    invocation.preparedProfile?.statementGeneration,
                admittedAt: invocation.admittedAt.rawValue
            )
        )
        guard data.count <= Self.maximumRootBytes else {
            throw PortableChatPersistenceError.rootTooLarge
        }
        return data
    }

    private func openLibraryRoot(
        at url: URL,
        in scope: LibraryScope,
        expectedProfileStatementGeneration: UInt64? = nil
    ) throws -> Int32 {
        let descriptor = url.path.withCString { pointer -> Int32 in
            while true {
                let result = Darwin.open(
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard descriptor >= 0 else {
            if urlHasSymlink(url) {
                throw PortableChatPersistenceError.expectedPathIsSymlink
            }
            throw PortableChatPersistenceError.ioFailure
        }
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR
            else {
                throw PortableChatPersistenceError.invalidLayout
            }
            switch try PortableLibraryPersistence().load(
                from: descriptor,
                reconcileAbandonedImports: false
            ) {
            case let .readWrite(authority):
                guard authority.manifest.libraryID == scope.libraryID else {
                    throw PortableChatPersistenceError.libraryScopeMismatch
                }
                if let expectedProfileStatementGeneration,
                   authority.profileHead.statementGeneration != expectedProfileStatementGeneration
                {
                    throw PortableChatPersistenceError.profileStatementGenerationChanged(
                        authority.profileHead.statementGeneration
                    )
                }
            case .readOnly:
                throw PortableChatPersistenceError.readOnlyLibrary
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func revalidateLibraryAuthority(
        libraryID expectedLibraryID: LibraryID,
        profileStatementGeneration expectedProfileStatementGeneration: UInt64? = nil,
        under rootDescriptor: Int32
    ) throws {
        switch try PortableLibraryPersistence().load(
            from: rootDescriptor,
            reconcileAbandonedImports: false
        ) {
        case let .readWrite(authority):
            guard authority.manifest.libraryID == expectedLibraryID else {
                throw PortableChatPersistenceError.libraryScopeMismatch
            }
            if let expectedProfileStatementGeneration,
               authority.profileHead.statementGeneration != expectedProfileStatementGeneration
            {
                throw PortableChatPersistenceError.profileStatementGenerationChanged(
                    authority.profileHead.statementGeneration
                )
            }
        case .readOnly:
            throw PortableChatPersistenceError.readOnlyLibrary
        }
    }

    private func loadChat(
        from chatDescriptor: Int32,
        expectedID: ChatID,
        reconcileTransients: Bool,
        beforeDestructiveMutation: () throws -> Void = {}
    ) throws -> LoadedPortableChat {
        let chatData = try boundedData(named: "chat.json", under: chatDescriptor)
        let chatVersion = try schemaVersion(in: chatData)
        if chatVersion > UInt64(Chat.schemaVersion) {
            return .frozen(FrozenChatSnapshot(chatID: expectedID, reason: .newerSchema))
        }
        guard chatVersion == UInt64(Chat.schemaVersion) else {
            throw PortableChatPersistenceError.unsupportedOlderSchema
        }
        let chat = try mapPersistedDomainValidation {
            try decodeChat(chatData)
        }
        guard chat.id == expectedID else {
            throw PortableChatPersistenceError.invalidLayout
        }

        for forbidden in ["proposal.json", "profile-write.json"] {
            guard !(try entryExists(named: forbidden, under: chatDescriptor)) else {
                throw PortableChatPersistenceError.invalidLayout
            }
        }
        if reconcileTransients {
            try reconcileAbortingInvocation(
                chat: chat,
                under: chatDescriptor,
                beforeRemoving: beforeDestructiveMutation
            )
        } else if try entryExists(named: "aborting-invocation.json", under: chatDescriptor) {
            throw PortableChatPersistenceError.invalidLayout
        }
        let decodedPendingUserTurn: PendingUserTurn?
        if try entryExists(named: "pending-user-turn.json", under: chatDescriptor) {
            let pendingData = try boundedData(
                named: "pending-user-turn.json",
                under: chatDescriptor
            )
            let pendingVersion = try schemaVersion(in: pendingData)
            if pendingVersion > UInt64(PendingUserTurn.schemaVersion) {
                return .frozen(FrozenChatSnapshot(chatID: expectedID, reason: .newerSchema))
            }
            guard pendingVersion == 1 ||
                pendingVersion == UInt64(PendingUserTurn.schemaVersion)
            else {
                throw PortableChatPersistenceError.unsupportedOlderSchema
            }
            decodedPendingUserTurn = try mapPersistedDomainValidation {
                try decodePendingUserTurn(pendingData)
            }
        } else {
            decodedPendingUserTurn = nil
        }
        let messagesDescriptor = try openDirectory(named: "messages", under: chatDescriptor)
        defer { Darwin.close(messagesDescriptor) }
        let memoryDescriptor = try openDirectory(named: "memory", under: chatDescriptor)
        defer { Darwin.close(memoryDescriptor) }
        let messageEntries = try listEntryNames(
            under: messagesDescriptor,
            maximumCount: Self.maximumMessageDirectoryEntries
        )
            .filter { $0 != ".DS_Store" }
        let referencedNames = Set(chat.messageIDs.map { "\($0.rawValue).json" })
        var messagesByID: [ChatMessageID: ChatMessage] = [:]
        var unreferencedNames: [String] = []
        var messagePartialNames: [String] = []
        for name in messageEntries {
            if Self.isMessagePartialName(name), isRegularFile(named: name, under: messagesDescriptor) {
                messagePartialNames.append(name)
                continue
            }
            guard name.hasSuffix(".json"),
                  let messageID = try? ChatMessageID(String(name.dropLast(5))),
                  isRegularFile(named: name, under: messagesDescriptor)
            else {
                throw PortableChatPersistenceError.invalidLayout
            }
            if referencedNames.contains(name) {
                let messageData = try boundedData(named: name, under: messagesDescriptor)
                let message = try mapPersistedDomainValidation {
                    try decodeMessage(messageData)
                }
                guard message.id == messageID else {
                    throw PortableChatPersistenceError.invalidLayout
                }
                messagesByID[messageID] = message
            } else {
                unreferencedNames.append(name)
            }
        }
        guard messagesByID.count == chat.messageIDs.count else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let orderedMessages = try chat.messageIDs.map { messageID -> ChatMessage in
            guard let message = messagesByID[messageID] else {
                throw PortableChatPersistenceError.invalidLayout
            }
            return message
        }
        guard orderedMessages.count.isMultiple(of: 2) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        for userIndex in stride(from: 0, to: orderedMessages.count, by: 2) {
            guard case .user = orderedMessages[userIndex].content,
                  case .coach = orderedMessages[userIndex + 1].content,
                  orderedMessages[userIndex].persistedSchemaVersion ==
                  orderedMessages[userIndex + 1].persistedSchemaVersion,
                  orderedMessages[userIndex].responsePositionID ==
                  orderedMessages[userIndex + 1].responsePositionID
            else {
                throw PortableChatPersistenceError.invalidLayout
            }
        }

        let pendingUserTurn: PendingUserTurn?
        var removesStalePending = false
        if let decodedPendingUserTurn,
           decodedPendingUserTurn.draftID == chat.draft.draftID,
           decodedPendingUserTurn.draftVersion == chat.draft.version
        {
            pendingUserTurn = decodedPendingUserTurn
        } else if let decodedPendingUserTurn {
            let tail = Array(orderedMessages.suffix(2))
            guard tail.count == 2,
                  tail.allSatisfy({
                      $0.responsePositionID == decodedPendingUserTurn.responsePositionID
                  }), case .user = tail[0].content, case .coach = tail[1].content
            else {
                throw PortableChatPersistenceError.invalidLayout
            }
            pendingUserTurn = nil
            removesStalePending = true
        } else {
            pendingUserTurn = nil
        }

        let memoryData = try boundedData(
            named: "\(chat.currentMemoryID.rawValue).json",
            under: memoryDescriptor
        )
        let memoryVersion = try schemaVersion(in: memoryData)
        if memoryVersion > UInt64(CoachMemory.schemaVersion) {
            return .frozen(FrozenChatSnapshot(chatID: expectedID, reason: .newerSchema))
        }
        guard memoryVersion == UInt64(CoachMemory.schemaVersion) else {
            throw PortableChatPersistenceError.unsupportedOlderSchema
        }
        let memory = try mapPersistedDomainValidation {
            try decodeMemory(memoryData, attachments: chat.attachments)
        }
        let aggregate = try mapPersistedDomainValidation {
            try ChatAggregate(
                chat: chat,
                memory: memory,
                pendingUserTurn: pendingUserTurn
            )
        }
        if reconcileTransients {
            try reconcileRootMutationPartials(
                under: chatDescriptor,
                beforeRemoving: beforeDestructiveMutation
            )
            try reconcileUnreferencedMessages(
                unreferencedNames + messagePartialNames,
                under: messagesDescriptor,
                beforeRemoving: beforeDestructiveMutation
            )
            if removesStalePending {
                try beforeDestructiveMutation()
                try removeRegularFileIfPresent(
                    named: "pending-user-turn.json",
                    under: chatDescriptor
                )
            }
            try reconcileUnreferencedMemorySnapshots(
                currentMemoryID: chat.currentMemoryID,
                under: memoryDescriptor,
                beforeRemoving: beforeDestructiveMutation
            )
        }
        return .readWrite(aggregate)
    }

    private func loadChatReconcilingTransients(
        from chatDescriptor: Int32,
        expectedID: ChatID,
        beforeDestructiveMutation: () throws -> Void = {}
    ) throws -> LoadedPortableChat {
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        return try loadChat(
            from: chatDescriptor,
            expectedID: expectedID,
            reconcileTransients: true,
            beforeDestructiveMutation: beforeDestructiveMutation
        )
    }

    private func loadChatForRename(
        from chatDescriptor: Int32,
        expectedID: ChatID,
        reconcileTransients: Bool = true,
        beforeDestructiveMutation: () throws -> Void = {}
    ) throws -> LoadedPortableChat {
        do {
            return try loadChat(
                from: chatDescriptor,
                expectedID: expectedID,
                reconcileTransients: reconcileTransients,
                beforeDestructiveMutation: beforeDestructiveMutation
            )
        } catch let error as PortableChatPersistenceError {
            guard let frozen = frozenChatSnapshot(for: error, chatID: expectedID) else {
                throw error
            }
            return .frozen(frozen)
        } catch {
            return .frozen(FrozenChatSnapshot(chatID: expectedID, reason: .corrupt))
        }
    }

    private func reconcileStagedChatCandidates(under rootDescriptor: Int32) throws {
        let stagingDescriptor = try openDirectory(named: "staging", under: rootDescriptor)
        defer { Darwin.close(stagingDescriptor) }
        let publicationsDescriptor = try openDirectory(
            named: "publications",
            under: stagingDescriptor
        )
        defer { Darwin.close(publicationsDescriptor) }
        var budget = CandidateCleanupBudget()
        guard let names = try? listEntryNames(
            under: publicationsDescriptor,
            maximumCount: budget.remaining
        ), budget.consume(names.count)
        else {
            return
        }
        var removed = false
        for name in names {
            guard stagedChatCandidateID(name) != nil,
                  let nodeCount = try isOwnedStagedChatCandidate(
                      named: name,
                      under: publicationsDescriptor,
                      budget: &budget
                  )
            else {
                continue
            }
            guard budget.consume(nodeCount) else { break }
            var removalBudget = CandidateCleanupBudget(remaining: nodeCount)
            try removeTree(
                named: name,
                under: publicationsDescriptor,
                component: .candidate,
                budget: &removalBudget
            )
            removed = true
        }
        if removed { try flushDescriptor(publicationsDescriptor) }
    }

    private func reconcileStagedChatCandidatesExclusively(
        under rootDescriptor: Int32
    ) throws {
        let stagingDescriptor = try openDirectory(named: "staging", under: rootDescriptor)
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        try reconcileStagedChatCandidates(under: rootDescriptor)
    }

    private func reconcileRootMutationPartials(
        under chatDescriptor: Int32,
        beforeRemoving: () throws -> Void = {}
    ) throws {
        var removed = false
        for name in try listEntryNames(
            under: chatDescriptor,
            maximumCount: Self.maximumChatRootEntries
        )
        where (Self.isRenamePartialName(name) || Self.isPendingPartialName(name)) &&
            isRegularFile(named: name, under: chatDescriptor)
        {
            try beforeRemoving()
            guard name.withCString({ Darwin.unlinkat(chatDescriptor, $0, 0) }) == 0 else {
                throw PortableChatPersistenceError.ioFailure
            }
            removed = true
        }
        if removed { try flushDescriptor(chatDescriptor) }
    }

    private func reconcileUnreferencedMemorySnapshots(
        currentMemoryID: CoachMemoryID,
        under memoryDescriptor: Int32,
        beforeRemoving: () throws -> Void = {}
    ) throws {
        let currentName = "\(currentMemoryID.rawValue).json"
        var removed = false
        for name in try listEntryNames(
            under: memoryDescriptor,
            maximumCount: Self.maximumMemoryDirectoryEntries
        ) {
            guard name != currentName else { continue }
            let isSnapshot = name.hasSuffix(".json") &&
                (try? CoachMemoryID(String(name.dropLast(5)))) != nil
            guard (isSnapshot || isRootPartialName(name)),
                  isRegularFile(named: name, under: memoryDescriptor)
            else {
                continue
            }
            try beforeRemoving()
            guard name.withCString({ Darwin.unlinkat(memoryDescriptor, $0, 0) }) == 0 else {
                throw PortableChatPersistenceError.ioFailure
            }
            removed = true
        }
        if removed { try flushDescriptor(memoryDescriptor) }
    }

    private func reconcileUnreferencedMessages(
        _ names: [String],
        under messagesDescriptor: Int32,
        beforeRemoving: () throws -> Void = {}
    ) throws {
        var removed = false
        for name in names {
            let isMessage = name.hasSuffix(".json") &&
                (try? ChatMessageID(String(name.dropLast(5)))) != nil
            guard (isMessage || Self.isMessagePartialName(name)),
                  isRegularFile(named: name, under: messagesDescriptor)
            else {
                throw PortableChatPersistenceError.invalidLayout
            }
            try beforeRemoving()
            guard name.withCString({ Darwin.unlinkat(messagesDescriptor, $0, 0) }) == 0 else {
                throw PortableChatPersistenceError.ioFailure
            }
            removed = true
        }
        if removed { try flushDescriptor(messagesDescriptor) }
    }

    private func removeRegularFileIfPresent(
        named name: String,
        under descriptor: Int32
    ) throws {
        guard try entryExists(named: name, under: descriptor) else { return }
        guard isRegularFile(named: name, under: descriptor),
              name.withCString({ Darwin.unlinkat(descriptor, $0, 0) }) == 0
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try flushDescriptor(descriptor)
    }

    private func reconcileAbortingInvocation(
        chat: Chat,
        under chatDescriptor: Int32,
        beforeRemoving: () throws -> Void = {}
    ) throws {
        let marker = "aborting-invocation.json"
        guard try entryExists(named: marker, under: chatDescriptor) else { return }
        let invocationData = try boundedData(named: marker, under: chatDescriptor)
        let invocation = try mapPersistedDomainValidation {
            try decodeInvocation(invocationData)
        }
        guard invocation.chatID == chat.id,
              invocation.draftID == chat.draft.draftID,
              invocation.draftVersion == chat.draft.version
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        guard try entryExists(named: "pending-user-turn.json", under: chatDescriptor) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let pending = try decodePendingUserTurn(
            boundedData(named: "pending-user-turn.json", under: chatDescriptor)
        )
        guard pending.id == invocation.pendingUserTurnID,
              pending.draftID == invocation.draftID,
              pending.draftVersion == invocation.draftVersion,
              pending.responsePositionID == invocation.responsePositionID
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let interrupted = pending.replacingFailure(.coachResponseInterrupted)
        if interrupted != pending {
            let partialName = ".pending-user-turn.json.\(UUID().uuidString.lowercased()).partial"
            var partialExists = false
            defer {
                if partialExists {
                    _ = partialName.withCString {
                        Darwin.unlinkat(chatDescriptor, $0, 0)
                    }
                }
            }
            try writeExclusive(
                try encodePendingUserTurn(interrupted),
                named: partialName,
                under: chatDescriptor
            )
            partialExists = true
            let partialDescriptor = try openRegularFile(
                named: partialName,
                under: chatDescriptor
            )
            defer { Darwin.close(partialDescriptor) }
            try flushDescriptor(partialDescriptor)
            try beforeRemoving()
            guard renameat(
                chatDescriptor,
                partialName,
                chatDescriptor,
                "pending-user-turn.json"
            ) == 0 else {
                throw PortableChatPersistenceError.ioFailure
            }
            partialExists = false
            try flushDescriptor(chatDescriptor)
            try fault(.afterInvocationAbortPendingFailureInstall)
        }
        try beforeRemoving()
        try removeRegularFileIfPresent(named: marker, under: chatDescriptor)
    }

    private func retireInvocation(
        _ invocation: CoachInvocation,
        current: ChatAggregate,
        invocationRoot: Int32,
        invocationsDescriptor: Int32,
        chatDescriptor: Int32,
        beforeCommitting: () throws -> Void = {}
    ) throws -> ChatAggregate {
        try beforeCommitting()
        guard (try? invocation.validateIntent(against: current)) != nil,
              !(try entryExists(named: "aborting-invocation.json", under: chatDescriptor)),
              renameat(
                  invocationRoot,
                  "invocation.json",
                  chatDescriptor,
                  "aborting-invocation.json"
              ) == 0
        else { throw PortableChatPersistenceError.invalidLayout }
        try flushDescriptor(chatDescriptor)
        try flushDescriptor(invocationRoot)
        try fault(.afterInvocationAbortMarkerInstall)
        try beforeCommitting()
        guard unlinkat(
            invocationsDescriptor,
            invocation.id.rawValue,
            AT_REMOVEDIR
        ) == 0 else { throw PortableChatPersistenceError.ioFailure }
        try flushDescriptor(invocationsDescriptor)
        try fault(.afterInvocationAbortDirectoryRemoval)
        try reconcileAbortingInvocation(
            chat: current.chat,
            under: chatDescriptor,
            beforeRemoving: beforeCommitting
        )
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: invocation.chatID,
            reconcileTransients: true,
            beforeDestructiveMutation: beforeCommitting
        ), let pending = current.pendingUserTurn,
            reopened == (try ChatAggregate(
                chat: current.chat,
                memory: current.memory,
                pendingUserTurn: pending.replacingFailure(.coachResponseInterrupted)
            ))
        else { throw PortableChatPersistenceError.invalidLayout }
        return reopened
    }

    private func invocationDirectoryNamesRemovingEmptyResidue(
        under invocationsDescriptor: Int32,
        beforeRemoving: () throws -> Void = {}
    ) throws -> [String] {
        let names = try listEntryNames(
            under: invocationsDescriptor,
            maximumCount: Self.maximumInvocationDirectoryEntries
        ).filter { $0 != ".DS_Store" }
        var candidates: [String] = []
        var removed = false
        for name in names {
            guard (try? CoachInvocationID(name)) != nil else {
                throw PortableChatPersistenceError.invalidLayout
            }
            let descriptor = try openDirectory(named: name, under: invocationsDescriptor)
            defer { Darwin.close(descriptor) }
            let entries = try listEntryNames(under: descriptor, maximumCount: 2)
            if entries.isEmpty {
                try beforeRemoving()
                guard unlinkat(invocationsDescriptor, name, AT_REMOVEDIR) == 0 else {
                    throw PortableChatPersistenceError.ioFailure
                }
                removed = true
            } else {
                candidates.append(name)
            }
        }
        if removed { try flushDescriptor(invocationsDescriptor) }
        return candidates
    }

    private func hasActiveInvocation(
        under rootDescriptor: Int32,
        expectedLibraryID: LibraryID
    ) throws -> Bool {
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        return try hasActiveInvocation(
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor,
            expectedLibraryID: expectedLibraryID
        )
    }

    private func hasActiveInvocation(
        under rootDescriptor: Int32,
        invocationsDescriptor: Int32,
        expectedLibraryID: LibraryID,
        beforeDestructiveMutation: () throws -> Void = {}
    ) throws -> Bool {
        try reconcileInvocationPartials(
            under: invocationsDescriptor,
            beforeRemoving: beforeDestructiveMutation
        )
        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let names = try listEntryNames(
            under: invocationsDescriptor,
            maximumCount: Self.maximumInvocationDirectoryEntries
        ).filter { $0 != ".DS_Store" }
        var activeCount = 0
        for name in names {
            guard let invocationID = try? CoachInvocationID(name) else {
                throw PortableChatPersistenceError.invalidLayout
            }
            let invocationRoot = try openDirectory(
                named: name,
                under: invocationsDescriptor
            )
            defer { Darwin.close(invocationRoot) }
            let entries = try listEntryNames(under: invocationRoot, maximumCount: 2)
            if entries.isEmpty {
                try beforeDestructiveMutation()
                guard unlinkat(invocationsDescriptor, name, AT_REMOVEDIR) == 0 else {
                    throw PortableChatPersistenceError.ioFailure
                }
                try flushDescriptor(invocationsDescriptor)
                continue
            }
            guard entries == ["invocation.json"] else {
                throw PortableChatPersistenceError.invalidLayout
            }
            let invocation = try decodeInvocation(
                boundedData(named: "invocation.json", under: invocationRoot)
            )
            guard invocation.id == invocationID,
                  invocation.libraryID == expectedLibraryID
            else { throw PortableChatPersistenceError.invalidLayout }
            guard try entryExists(named: invocation.chatID.rawValue, under: chatsDescriptor)
            else {
                try removeInvocationDirectoryIfPresent(
                    invocation,
                    under: invocationsDescriptor,
                    beforeRemoving: beforeDestructiveMutation
                )
                continue
            }
            let chatDescriptor = try openDirectory(
                named: invocation.chatID.rawValue,
                under: chatsDescriptor
            )
            defer { Darwin.close(chatDescriptor) }
            try beforeDestructiveMutation()
            guard case let .readWrite(aggregate) = try loadChatReconcilingTransients(
                from: chatDescriptor,
                expectedID: invocation.chatID,
                beforeDestructiveMutation: beforeDestructiveMutation
            ) else { throw PortableChatPersistenceError.invalidLayout }
            if (try? invocation.validateIntent(against: aggregate)) != nil {
                activeCount += 1
                guard activeCount == 1 else {
                    throw PortableChatPersistenceError.invalidLayout
                }
                continue
            }
            if try invocationWasPublished(
                invocation,
                aggregate: aggregate,
                under: chatDescriptor
            ) {
                try removeInvocationDirectoryIfPresent(
                    invocation,
                    under: invocationsDescriptor,
                    beforeRemoving: beforeDestructiveMutation
                )
            } else {
                // A changed Chat can no longer publish through this authority.
                // Retiring the stale root prevents a permanent Library block
                // without touching whatever Pending/Draft now owns the Chat.
                try removeInvocationDirectoryIfPresent(
                    invocation,
                    under: invocationsDescriptor,
                    beforeRemoving: beforeDestructiveMutation
                )
            }
        }
        return activeCount == 1
    }

    private func invocationWasPublished(
        _ invocation: CoachInvocation,
        aggregate: ChatAggregate,
        under chatDescriptor: Int32
    ) throws -> Bool {
        guard aggregate.pendingUserTurn == nil,
              aggregate.chat.messageIDs.count >= 2
        else { return false }
        let messagesDescriptor = try openDirectory(named: "messages", under: chatDescriptor)
        defer { Darwin.close(messagesDescriptor) }
        let tailIDs = Array(aggregate.chat.messageIDs.suffix(2))
        let messages = try tailIDs.map { id in
            try decodeMessage(
                boundedData(named: "\(id.rawValue).json", under: messagesDescriptor)
            )
        }
        guard messages.allSatisfy({
            $0.responsePositionID == invocation.responsePositionID
        }), case .user = messages[0].content, case .coach = messages[1].content
        else { return false }
        switch invocation.persistedSchemaVersion {
        case 1:
            guard messages.allSatisfy({
                $0.persistedSchemaVersion == 1 && $0.coachProfile == nil
            }) else {
                throw PortableChatPersistenceError.invalidLayout
            }
        case CoachInvocation.schemaVersion:
            guard let preparedProfile = invocation.preparedProfile,
                  messages.allSatisfy({
                      $0.persistedSchemaVersion == ChatMessage.schemaVersion
                  }), messages[0].coachProfile == nil,
                  messages[1].coachProfile == preparedProfile
            else {
                throw PortableChatPersistenceError.invalidLayout
            }
        default:
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        return true
    }

    private func reconcileInvocationPartials(
        under invocationsDescriptor: Int32,
        beforeRemoving: () throws -> Void = {}
    ) throws {
        let names = try listEntryNames(
            under: invocationsDescriptor,
            maximumCount: Self.maximumInvocationDirectoryEntries
        )
        var removed = false
        for name in names where Self.isInvocationPartialName(name) {
            try removeInvocationCandidateDuringReconciliation(
                named: name,
                under: invocationsDescriptor,
                beforeRemoving: beforeRemoving
            )
            removed = true
        }
        if removed { try flushDescriptor(invocationsDescriptor) }
    }

    private func removeInvocationCandidate(
        named name: String,
        under invocationsDescriptor: Int32
    ) {
        guard let descriptor = try? openDirectory(
            named: name,
            under: invocationsDescriptor
        ) else { return }
        _ = unlinkat(descriptor, "invocation.json", 0)
        Darwin.close(descriptor)
        _ = unlinkat(invocationsDescriptor, name, AT_REMOVEDIR)
    }

    private func removeInvocationCandidateDuringReconciliation(
        named name: String,
        under invocationsDescriptor: Int32,
        beforeRemoving: () throws -> Void
    ) throws {
        let descriptor = try openDirectory(named: name, under: invocationsDescriptor)
        defer { Darwin.close(descriptor) }
        if try entryExists(named: "invocation.json", under: descriptor) {
            try beforeRemoving()
            guard unlinkat(descriptor, "invocation.json", 0) == 0 else {
                throw PortableChatPersistenceError.ioFailure
            }
            try flushDescriptor(descriptor)
        }
        try beforeRemoving()
        guard unlinkat(invocationsDescriptor, name, AT_REMOVEDIR) == 0 else {
            throw PortableChatPersistenceError.invalidLayout
        }
    }

    private func removeInvocationDirectoryIfPresent(
        _ invocation: CoachInvocation,
        under invocationsDescriptor: Int32,
        beforeRemoving: () throws -> Void = {}
    ) throws {
        let name = invocation.id.rawValue
        guard try entryExists(named: name, under: invocationsDescriptor) else { return }
        let descriptor = try openDirectory(named: name, under: invocationsDescriptor)
        defer { Darwin.close(descriptor) }
        guard try listEntryNames(under: descriptor, maximumCount: 2) == ["invocation.json"],
              try decodeInvocation(
                  boundedData(named: "invocation.json", under: descriptor)
              ) == invocation
        else { throw PortableChatPersistenceError.invalidLayout }
        try beforeRemoving()
        guard unlinkat(descriptor, "invocation.json", 0) == 0 else {
            throw PortableChatPersistenceError.ioFailure
        }
        try flushDescriptor(descriptor)
        try beforeRemoving()
        guard unlinkat(invocationsDescriptor, name, AT_REMOVEDIR) == 0 else {
            throw PortableChatPersistenceError.ioFailure
        }
        try flushDescriptor(invocationsDescriptor)
    }

    private func installMessage(
        _ message: ChatMessage,
        under messagesDescriptor: Int32,
        installedFault: PortableChatFaultPoint
    ) throws {
        let finalName = "\(message.id.rawValue).json"
        if try entryExists(named: finalName, under: messagesDescriptor) {
            let installed = try decodeMessage(
                boundedData(named: finalName, under: messagesDescriptor)
            )
            guard installed == message else {
                throw PortableChatPersistenceError.invalidLayout
            }
            return
        }
        let partialName = ".\(finalName).\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString { Darwin.unlinkat(messagesDescriptor, $0, 0) }
            }
        }
        try writeExclusive(
            try encodeMessage(message),
            named: partialName,
            under: messagesDescriptor
        )
        partialExists = true
        let partialDescriptor = try openRegularFile(
            named: partialName,
            under: messagesDescriptor
        )
        defer { Darwin.close(partialDescriptor) }
        try flushDescriptor(partialDescriptor)
        try noReplaceRename(
            from: partialName,
            under: messagesDescriptor,
            to: finalName,
            under: messagesDescriptor
        )
        partialExists = false
        try flushDescriptor(messagesDescriptor)
        try fault(installedFault)
    }

    private func stagedChatCandidateID(_ name: String) -> ChatID? {
        let prefix = Array("chat-".utf8)
        let chatIDByteCount = 28
        let uuidByteCount = 36
        let expectedByteCount = prefix.count + chatIDByteCount + 1 + uuidByteCount
        guard name.utf8.count == expectedByteCount else { return nil }
        let bytes = Array(name.utf8)
        guard bytes.allSatisfy({ $0 < 0x80 }), bytes.starts(with: prefix) else { return nil }
        let chatStart = prefix.count
        let separator = chatStart + chatIDByteCount
        guard bytes[separator] == 0x2D,
              let chatID = try? ChatID(
                  String(decoding: bytes[chatStart ..< separator], as: UTF8.self)
              )
        else { return nil }
        let uuidText = String(decoding: bytes[(separator + 1)...], as: UTF8.self)
        guard let uuid = UUID(uuidString: uuidText),
              uuid.uuidString.lowercased() == uuidText
        else { return nil }
        return chatID
    }

    private static func isRenamePartialName(_ name: String) -> Bool {
        let prefix = ".chat.json."
        let suffix = ".partial"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let uuid = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return UUID(uuidString: uuid) != nil
    }

    private static func isPendingPartialName(_ name: String) -> Bool {
        let prefix = ".pending-user-turn.json."
        let suffix = ".partial"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let uuid = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return UUID(uuidString: uuid) != nil
    }

    private static func isInvocationPartialName(_ name: String) -> Bool {
        guard name.first == ".", name.hasSuffix(".partial") else { return false }
        let body = String(name.dropFirst().dropLast(".partial".count))
        guard let separator = body.lastIndex(of: ".") else { return false }
        let invocation = String(body[..<separator])
        let uuid = String(body[body.index(after: separator)...])
        return (try? CoachInvocationID(invocation)) != nil &&
            UUID(uuidString: uuid)?.uuidString.lowercased() == uuid
    }

    private static func isMessagePartialName(_ name: String) -> Bool {
        let suffix = ".partial"
        guard name.first == ".", name.hasSuffix(suffix) else { return false }
        let body = String(name.dropFirst().dropLast(suffix.count))
        guard let separator = body.lastIndex(of: "."),
              UUID(uuidString: String(body[body.index(after: separator)...])) != nil
        else { return false }
        let finalName = String(body[..<separator])
        guard finalName.hasSuffix(".json") else { return false }
        return (try? ChatMessageID(String(finalName.dropLast(5)))) != nil
    }

    private func isRootPartialName(_ name: String) -> Bool {
        let suffix = ".partial"
        guard name.first == ".", name.hasSuffix(suffix) else { return false }
        let body = String(name.dropFirst().dropLast(suffix.count))
        guard let separator = body.lastIndex(of: ".") else { return false }
        return UUID(uuidString: String(body[body.index(after: separator)...])) != nil
    }

    private func isOwnedStagedChatCandidate(
        named name: String,
        under parent: Int32,
        budget: inout CandidateCleanupBudget
    ) throws -> Int? {
        guard let candidateID = stagedChatCandidateID(name),
              let candidate = try? openDirectory(named: name, under: parent)
        else {
            return nil
        }
        defer { Darwin.close(candidate) }
        guard budget.consume() else { return nil }
        var nodeCount = 1
        guard let entries = try? listEntryNames(
            under: candidate,
            maximumCount: budget.remaining
        ) else {
            return nil
        }
        let entrySet = Set(entries)
        let baseLayout: Set<String> = ["messages", "memory"]
        let hasInstalledChat = entrySet.contains("chat.json")
        let partials = entries.filter(Self.isRenamePartialName)
        let isOwnedPhase = entrySet.isEmpty ||
            entrySet == ["messages"] ||
            entrySet == baseLayout ||
            (entrySet.count == 3 && baseLayout.isSubset(of: entrySet) &&
                ((hasInstalledChat && partials.isEmpty) ||
                    (!hasInstalledChat && partials.count == 1)))
        guard isOwnedPhase else { return nil }
        let requiresInstalledMemory = entrySet.count == 3
        for entry in entries {
            guard budget.consume() else { return nil }
            nodeCount += 1
            switch entry {
            case "messages":
                guard try isEmptyDirectory(named: entry, under: candidate) else { return nil }
            case "memory":
                guard let memoryNodeCount = try isOwnedCandidateMemoryDirectory(
                    named: entry,
                    under: candidate,
                    requiresInstalledSnapshot: requiresInstalledMemory,
                    budget: &budget
                ) else {
                    return nil
                }
                nodeCount += memoryNodeCount
            case "chat.json":
                guard isRegularFile(named: entry, under: candidate),
                      let bytes = try? boundedData(named: entry, under: candidate),
                      let chat = try? decodeChat(bytes),
                      chat.id == candidateID
                else {
                    return nil
                }
            default:
                guard Self.isRenamePartialName(entry),
                      isRegularFile(named: entry, under: candidate)
                else {
                    return nil
                }
            }
        }
        return nodeCount
    }

    private func isOwnedCandidateMemoryDirectory(
        named name: String,
        under parent: Int32,
        requiresInstalledSnapshot: Bool,
        budget: inout CandidateCleanupBudget
    ) throws -> Int? {
        guard let descriptor = try? openDirectory(named: name, under: parent) else {
            return nil
        }
        defer { Darwin.close(descriptor) }
        guard let entries = try? listEntryNames(
            under: descriptor,
            maximumCount: budget.remaining
        ) else {
            return nil
        }
        guard entries.count <= 1 else { return nil }
        if requiresInstalledSnapshot {
            guard let installed = entries.first,
                  installed.hasSuffix(".json"),
                  (try? CoachMemoryID(String(installed.dropLast(5)))) != nil
            else {
                return nil
            }
        }
        var nodeCount = 0
        for entry in entries {
            guard budget.consume(), Self.isCandidateMemoryEntryName(entry),
                  isRegularFile(named: entry, under: descriptor)
            else {
                return nil
            }
            nodeCount += 1
        }
        return nodeCount
    }

    private func isEmptyDirectory(named name: String, under parent: Int32) throws -> Bool {
        guard let descriptor = try? openDirectory(named: name, under: parent) else {
            return false
        }
        defer { Darwin.close(descriptor) }
        guard let entries = try? listEntryNames(under: descriptor, maximumCount: 0) else {
            return false
        }
        return entries.isEmpty
    }

    private static func isCandidateMemoryEntryName(_ name: String) -> Bool {
        if name.hasSuffix(".json"),
           (try? CoachMemoryID(String(name.dropLast(5)))) != nil
        {
            return true
        }
        let suffix = ".partial"
        guard name.first == ".", name.hasSuffix(suffix) else { return false }
        let body = String(name.dropFirst().dropLast(suffix.count))
        guard let separator = body.lastIndex(of: "."),
              UUID(uuidString: String(body[body.index(after: separator)...])) != nil
        else {
            return false
        }
        let target = String(body[..<separator])
        return target.hasSuffix(".json") &&
            (try? CoachMemoryID(String(target.dropLast(5)))) != nil
    }

    private func isRegularFile(named name: String, under parent: Int32) -> Bool {
        var metadata = stat()
        let status = name.withCString {
            Darwin.fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        return status == 0 && (metadata.st_mode & S_IFMT) == S_IFREG
    }

    private func removeTree(
        named name: String,
        under parent: Int32,
        component: CandidateCleanupComponent,
        budget: inout CandidateCleanupBudget
    ) throws {
        guard budget.consume() else { throw PortableChatPersistenceError.invalidLayout }
        var metadata = stat()
        let status = name.withCString {
            Darwin.fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else {
            if errno == ENOENT { return }
            throw PortableChatPersistenceError.ioFailure
        }
        let kind = metadata.st_mode & S_IFMT
        if component == .leaf {
            guard kind == S_IFREG else {
                throw PortableChatPersistenceError.invalidLayout
            }
            guard name.withCString({ Darwin.unlinkat(parent, $0, 0) }) == 0 else {
                throw PortableChatPersistenceError.ioFailure
            }
        } else {
            guard kind == S_IFDIR else {
                throw PortableChatPersistenceError.invalidLayout
            }
            let descriptor = try openDirectory(named: name, under: parent)
            defer { Darwin.close(descriptor) }
            let children = try listEntryNames(
                under: descriptor,
                maximumCount: budget.remaining
            )
            for child in children {
                guard let childComponent = component.child(named: child) else {
                    throw PortableChatPersistenceError.invalidLayout
                }
                try removeTree(
                    named: child,
                    under: descriptor,
                    component: childComponent,
                    budget: &budget
                )
            }
            guard name.withCString({ Darwin.unlinkat(parent, $0, AT_REMOVEDIR) }) == 0 else {
                throw PortableChatPersistenceError.ioFailure
            }
        }
    }

    private struct CandidateCleanupBudget {
        static let maximumNodes = 32

        private(set) var remaining: Int

        init(remaining: Int = maximumNodes) {
            self.remaining = remaining
        }

        mutating func consume(_ count: Int = 1) -> Bool {
            guard count >= 0, count <= remaining else { return false }
            remaining -= count
            return true
        }
    }

    private enum CandidateCleanupComponent: Equatable {
        case candidate
        case messages
        case memory
        case leaf

        func child(named name: String) -> Self? {
            switch self {
            case .candidate:
                if name == "messages" { return .messages }
                if name == "memory" { return .memory }
                if name == "chat.json" { return .leaf }
                return PortableChatPersistence.isRenamePartialName(name) ? .leaf : nil
            case .messages:
                return nil
            case .memory:
                return PortableChatPersistence.isCandidateMemoryEntryName(name) ? .leaf : nil
            case .leaf:
                return nil
            }
        }
    }

    private func decodeChat(_ data: Data) throws -> Chat {
        let dictionary = try jsonDictionary(data)
        guard let kind = dictionary["creationKind"] as? String else {
            throw PortableChatPersistenceError.invalidJSON
        }
        let commonKeys: Set<String> = [
            "schemaVersion", "chatId", "manifestRevision", "title", "createdAt",
            "updatedAt", "creationKind", "profileStatementGenerationAtCreation",
            "attachments", "draft", "messageIds", "currentMemoryId",
        ]
        switch kind {
        case ChatCreationKind.newChat.rawValue:
            try requireExactKeys(dictionary, commonKeys)
        case ChatCreationKind.sessionAnalysis.rawValue:
            try requireExactKeys(dictionary, commonKeys.union(["originAttachmentId"]))
            guard !(dictionary["originAttachmentId"] is NSNull) else {
                throw PortableChatPersistenceError.invalidJSON
            }
        default:
            throw PortableChatPersistenceError.invalidJSON
        }
        guard let draft = dictionary["draft"] as? [String: Any] else {
            throw PortableChatPersistenceError.invalidJSON
        }
        try requireExactKeys(draft, ["draftId", "version", "text", "updatedAt"])
        guard let attachments = dictionary["attachments"] as? [[String: Any]] else {
            throw PortableChatPersistenceError.invalidJSON
        }
        for attachment in attachments {
            try requireExactKeys(
                attachment,
                ["attachmentId", "sessionId", "transcriptRevisionId"]
            )
        }

        let dto: ChatDTO = try decode(ChatDTO.self, data)
        guard dto.schemaVersion == 1,
              let chatID = try? ChatID(dto.chatId),
              let title = try? ChatTitle(dto.title),
              let createdAt = try? UTCInstant(dto.createdAt),
              let updatedAt = try? UTCInstant(dto.updatedAt),
              let kind = ChatCreationKind(rawValue: dto.creationKind),
              let draftID = try? ChatDraftID(dto.draft.draftId),
              let draftUpdatedAt = try? UTCInstant(dto.draft.updatedAt),
              let currentMemoryID = try? CoachMemoryID(dto.currentMemoryId)
        else {
            throw PortableChatPersistenceError.invalidJSON
        }
        let attachmentValues = try dto.attachments.map {
            ChatSessionAttachment(
                attachmentID: try ChatSessionAttachmentID($0.attachmentId),
                sessionID: try SessionID($0.sessionId),
                transcriptRevisionID: try TranscriptRevisionID($0.transcriptRevisionId)
            )
        }
        let attachmentsValue = try ChatAttachments(validating: attachmentValues)
        let origin = try dto.originAttachmentId.map(ChatSessionAttachmentID.init)
        let creation = try ChatCreation(
            kind: kind,
            originAttachmentID: origin,
            attachments: attachmentsValue
        )
        let chatDraft = try ChatDraft(
            draftID: draftID,
            version: dto.draft.version,
            text: dto.draft.text,
            updatedAt: draftUpdatedAt
        )
        let messageIDs = try dto.messageIds.map(ChatMessageID.init)
        return try Chat(
            id: chatID,
            manifestRevision: dto.manifestRevision,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            creation: creation,
            profileStatementGenerationAtCreation: dto.profileStatementGenerationAtCreation,
            attachments: attachmentsValue,
            draft: chatDraft,
            messageIDs: messageIDs,
            currentMemoryID: currentMemoryID
        )
    }

    private func decodeMemory(
        _ data: Data,
        attachments: ChatAttachments
    ) throws -> CoachMemory {
        let dictionary = try jsonDictionary(data)
        try requireExactKeys(
            dictionary,
            ["schemaVersion", "memoryId", "chatId", "generalNotes", "sessionSummaries"]
        )
        guard let summaries = dictionary["sessionSummaries"] as? [[String: Any]] else {
            throw PortableChatPersistenceError.invalidJSON
        }
        for summary in summaries {
            try requireExactKeys(summary, ["sessionAttachmentId", "notes"])
        }
        let dto: CoachMemoryDTO = try decode(CoachMemoryDTO.self, data)
        guard dto.schemaVersion == 1,
              let memoryID = try? CoachMemoryID(dto.memoryId),
              let chatID = try? ChatID(dto.chatId)
        else {
            throw PortableChatPersistenceError.invalidJSON
        }
        let values = try dto.sessionSummaries.map {
            CoachMemorySessionSummary(
                sessionAttachmentID: try ChatSessionAttachmentID($0.sessionAttachmentId),
                notes: $0.notes
            )
        }
        return try CoachMemory(
            memoryID: memoryID,
            chatID: chatID,
            generalNotes: dto.generalNotes,
            sessionSummaries: values,
            attachments: attachments
        )
    }

    private func decodePendingUserTurn(_ data: Data) throws -> PendingUserTurn {
        let dictionary = try jsonDictionary(data)
        let requiredKeys: Set<String> = [
            "schemaVersion", "pendingUserTurnId", "draftId", "draftVersion",
            "responsePositionId",
        ]
        let actualKeys = Set(dictionary.keys)
        guard actualKeys == requiredKeys || actualKeys == requiredKeys.union(["failure"])
        else {
            throw PortableChatPersistenceError.unknownKey
        }
        if actualKeys.contains("failure"), dictionary["failure"] is NSNull {
            throw PortableChatPersistenceError.invalidJSON
        }
        let dto: PendingUserTurnDTO = try decode(PendingUserTurnDTO.self, data)
        let failure: PendingUserTurnFailure?
        switch dto.schemaVersion {
        case 1:
            switch dto.failure {
            case nil: failure = nil
            case PendingUserTurnFailure.coachContextCannotFit.rawValue:
                failure = .coachContextCannotFit
            case .some:
                throw PortableChatPersistenceError.invalidJSON
            }
        case PendingUserTurn.schemaVersion:
            if let rawFailure = dto.failure {
                guard let parsed = PendingUserTurnFailure(rawValue: rawFailure) else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                failure = parsed
            } else {
                failure = nil
            }
        default:
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        return PendingUserTurn(
            id: try PendingUserTurnID(dto.pendingUserTurnId),
            draftID: try ChatDraftID(dto.draftId),
            draftVersion: dto.draftVersion,
            responsePositionID: try ChatResponsePositionID(dto.responsePositionId),
            failure: failure
        )
    }

    private func decodeMessage(_ data: Data) throws -> ChatMessage {
        let dictionary = try jsonDictionary(data)
        guard let role = dictionary["role"] as? String,
              let schemaVersionNumber = dictionary["schemaVersion"] as? NSNumber
        else {
            throw PortableChatPersistenceError.invalidJSON
        }
        let schemaVersion = schemaVersionNumber.uint32Value
        guard schemaVersion == 1 || schemaVersion == ChatMessage.schemaVersion else {
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        let common: Set<String> = [
            "schemaVersion", "messageId", "responsePositionId", "role", "createdAt",
        ]
        switch role {
        case "user":
            try requireExactKeys(dictionary, common.union(["text"]))
        case "coach":
            if schemaVersion == 1 {
                try requireExactKeys(dictionary, common.union(["markdown"]))
            } else {
                let coachKeys = common.union([
                    "markdown", "profileStatementGeneration",
                ])
                let actualKeys = Set(dictionary.keys)
                guard actualKeys == coachKeys ||
                    actualKeys == coachKeys.union(["profileRevisionId"])
                else { throw PortableChatPersistenceError.unknownKey }
                if actualKeys.contains("profileRevisionId"),
                   dictionary["profileRevisionId"] is NSNull
                {
                    throw PortableChatPersistenceError.invalidJSON
                }
            }
        default:
            throw PortableChatPersistenceError.invalidJSON
        }
        let dto: ChatMessageDTO = try decode(ChatMessageDTO.self, data)
        guard let messageID = try? ChatMessageID(dto.messageId),
              let responsePositionID = try? ChatResponsePositionID(dto.responsePositionId),
              let createdAt = try? UTCInstant(dto.createdAt)
        else {
            throw PortableChatPersistenceError.invalidJSON
        }
        let content: ChatMessageContent
        let coachProfile: CoachProfileProvenance?
        switch role {
        case "user":
            guard let text = dto.text, dto.markdown == nil,
                  dto.profileRevisionId == nil,
                  dto.profileStatementGeneration == nil
            else {
                throw PortableChatPersistenceError.invalidJSON
            }
            content = .user(text: text)
            coachProfile = nil
        case "coach":
            guard let markdown = dto.markdown, dto.text == nil
            else {
                throw PortableChatPersistenceError.invalidJSON
            }
            content = .coach(markdown: markdown)
            if dto.schemaVersion == 1 {
                guard dto.profileRevisionId == nil,
                      dto.profileStatementGeneration == nil
                else { throw PortableChatPersistenceError.invalidJSON }
                coachProfile = nil
            } else {
                guard let statementGeneration = dto.profileStatementGeneration else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                coachProfile = CoachProfileProvenance(
                    revisionID: try dto.profileRevisionId.map(ProfileRevisionID.init),
                    statementGeneration: statementGeneration
                )
            }
        default:
            throw PortableChatPersistenceError.invalidJSON
        }
        return try ChatMessage(
            schemaVersion: dto.schemaVersion,
            id: messageID,
            responsePositionID: responsePositionID,
            content: content,
            coachProfile: coachProfile,
            createdAt: createdAt
        )
    }

    private func decodeInvocation(_ data: Data) throws -> CoachInvocation {
        let dictionary = try jsonDictionary(data)
        let dto: CoachInvocationDTO = try decode(CoachInvocationDTO.self, data)
        let common: Set<String> = [
            "schemaVersion", "invocationId", "attemptId",
            "providerIdempotencyValue", "libraryId", "chatId", "pendingUserTurnId", "draftId",
            "draftVersion", "responsePositionId", "expectedManifestRevision", "admittedAt",
        ]
        guard dto.schemaVersion == 1 || dto.schemaVersion == CoachInvocation.schemaVersion else {
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        if dto.schemaVersion == 1 {
            try requireExactKeys(dictionary, common)
        } else {
            let v2 = common.union(["profileStatementGeneration"])
            let actualKeys = Set(dictionary.keys)
            guard actualKeys == v2 || actualKeys == v2.union(["profileRevisionId"])
            else { throw PortableChatPersistenceError.unknownKey }
            if actualKeys.contains("profileRevisionId"),
               dictionary["profileRevisionId"] is NSNull
            {
                throw PortableChatPersistenceError.invalidJSON
            }
        }
        let pending = PendingUserTurn(
            id: try PendingUserTurnID(dto.pendingUserTurnId),
            draftID: try ChatDraftID(dto.draftId),
            draftVersion: dto.draftVersion,
            responsePositionID: try ChatResponsePositionID(dto.responsePositionId)
        )
        let preparedProfile: CoachProfileProvenance?
        if dto.schemaVersion == 1 {
            guard dto.profileRevisionId == nil,
                  dto.profileStatementGeneration == nil
            else { throw PortableChatPersistenceError.invalidJSON }
            preparedProfile = nil
        } else {
            guard let statementGeneration = dto.profileStatementGeneration else {
                throw PortableChatPersistenceError.invalidJSON
            }
            preparedProfile = CoachProfileProvenance(
                revisionID: try dto.profileRevisionId.map(ProfileRevisionID.init),
                statementGeneration: statementGeneration
            )
        }
        return try CoachInvocation(
            schemaVersion: dto.schemaVersion,
            id: CoachInvocationID(dto.invocationId),
            attemptID: CoachProviderAttemptID(dto.attemptId),
            providerIdempotencyValue: ProviderIdempotencyValue(
                dto.providerIdempotencyValue
            ),
            library: LibraryScope(libraryID: try LibraryID(dto.libraryId)),
            chatID: ChatID(dto.chatId),
            pendingUserTurn: pending,
            preparedProfile: preparedProfile,
            expectedManifestRevision: dto.expectedManifestRevision,
            admittedAt: UTCInstant(dto.admittedAt)
        )
    }

    private func writeNewRoot(
        _ data: Data,
        named name: String,
        under descriptor: Int32,
        points: (
            PortableChatFaultPoint,
            PortableChatFaultPoint,
            PortableChatFaultPoint,
            PortableChatFaultPoint,
            PortableChatFaultPoint?
        )
    ) throws {
        try fault(points.0)
        let partialName = ".\(name).\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString { Darwin.unlinkat(descriptor, $0, 0) }
            }
        }
        try writeExclusive(data, named: partialName, under: descriptor)
        partialExists = true
        try fault(points.1)
        let partialDescriptor = try openRegularFile(named: partialName, under: descriptor)
        defer { Darwin.close(partialDescriptor) }
        try flushDescriptor(partialDescriptor)
        try fault(points.2)
        try noReplaceRename(
            from: partialName,
            under: descriptor,
            to: name,
            under: descriptor
        )
        partialExists = false
        try fault(points.3)
        try flushDescriptor(descriptor)
        if let directoryPoint = points.4 { try fault(directoryPoint) }
    }

    private func writeExclusive(_ data: Data, named name: String, under parent: Int32) throws {
        try confined.writeExclusive(data, named: name, under: parent, flushBeforeClose: false)
    }

    private func noReplaceRename(
        from source: String,
        under sourceParent: Int32,
        to destination: String,
        under destinationParent: Int32
    ) throws {
        try confined.renameNoReplace(
            from: source,
            under: sourceParent,
            to: destination,
            under: destinationParent,
            collision: .collision
        )
    }

    private func boundedData(named name: String, under parent: Int32) throws -> Data {
        try confined.boundedData(named: name, under: parent, maximumBytes: Self.maximumRootBytes)
    }

    private func schemaVersion(in data: Data) throws -> UInt64 {
        try confined.schemaVersion(in: data)
    }

    private func jsonDictionary(_ data: Data) throws -> [String: Any] {
        try confined.jsonDictionary(data)
    }

    private func requireExactKeys(
        _ dictionary: [String: Any],
        _ expected: Set<String>
    ) throws {
        try confined.requireExactKeys(dictionary, expected)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try confined.decode(type, from: data)
    }

    private func mapPersistedDomainValidation<T>(
        _ operation: () throws -> T
    ) throws -> T {
        do {
            return try operation()
        } catch let error as PortableChatPersistenceError {
            throw error
        } catch {
            throw PortableChatPersistenceError.invalidJSON
        }
    }

    private func deterministicJSON<T: Encodable>(_ value: T) throws -> Data {
        try confined.deterministicJSON(value)
    }

    private func makeDirectory(named name: String, under parent: Int32) throws {
        guard name.withCString({ Darwin.mkdirat(parent, $0, 0o700) }) == 0 else {
            throw PortableChatPersistenceError.ioFailure
        }
    }

    private func openDirectory(named name: String, under parent: Int32) throws -> Int32 {
        try confined.openDirectory(named: name, under: parent)
    }

    private func openRegularFile(named name: String, under parent: Int32) throws -> Int32 {
        try confined.openRegularFile(named: name, under: parent)
    }

    private func acquirePendingUserTurnFileLease(
        under chatDescriptor: Int32
    ) throws -> PortablePendingUserTurnFileLease? {
        let descriptor = try openRegularFile(
            named: "pending-user-turn.json",
            under: chatDescriptor
        )
        var ownsDescriptor = true
        defer {
            if ownsDescriptor { Darwin.close(descriptor) }
        }
        let key = try regularFileLivenessIdentity(of: descriptor)
        guard PortableInvocationLivenessRegistry.claim(key) else { return nil }
        var ownsRegistryClaim = true
        defer {
            if ownsRegistryClaim { PortableInvocationLivenessRegistry.release(key) }
        }

        while audoraFlock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK || errno == EAGAIN { return nil }
            throw PortableChatPersistenceError.ioFailure
        }
        var ownsFileLock = true
        defer {
            if ownsFileLock { _ = audoraFlock(descriptor, LOCK_UN) }
        }
        guard try regularFileLivenessIdentity(
            named: "pending-user-turn.json",
            under: chatDescriptor
        ) == key else {
            throw PortableChatPersistenceError.invalidLayout
        }

        ownsDescriptor = false
        ownsRegistryClaim = false
        ownsFileLock = false
        return PortablePendingUserTurnFileLease(descriptor: descriptor, key: key)
    }

    private func acquireAndValidatePendingUserTurnFileLease(
        _ expected: PendingUserTurn,
        under chatDescriptor: Int32
    ) throws -> PortablePendingUserTurnFileLease {
        guard let lease = try acquirePendingUserTurnFileLease(
            under: chatDescriptor
        ) else {
            throw PortableChatPersistenceError.ioFailure
        }
        do {
            guard try regularFileLivenessIdentity(
                named: "pending-user-turn.json",
                under: chatDescriptor
            ) == lease.key,
                try decodePendingUserTurn(
                    boundedData(
                        named: "pending-user-turn.json",
                        under: chatDescriptor
                    )
                ) == expected
            else {
                throw PortableChatPersistenceError.invalidLayout
            }
            return lease
        } catch {
            lease.release()
            throw error
        }
    }

    private func directoryIdentity(of descriptor: Int32) throws -> DirectoryIdentity {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return DirectoryIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }

    private func invocationLivenessIdentity(
        of descriptor: Int32
    ) throws -> PortableInvocationLivenessKey {
        let identity = try directoryIdentity(of: descriptor)
        return PortableInvocationLivenessKey(
            device: identity.device,
            inode: identity.inode
        )
    }

    private func invocationLivenessIdentity(
        named name: String,
        under parent: Int32
    ) throws -> PortableInvocationLivenessKey {
        let identity = try directoryIdentity(named: name, under: parent)
        return PortableInvocationLivenessKey(
            device: identity.device,
            inode: identity.inode
        )
    }

    private func regularFileLivenessIdentity(
        of descriptor: Int32
    ) throws -> PortableInvocationLivenessKey {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return PortableInvocationLivenessKey(
            device: metadata.st_dev,
            inode: metadata.st_ino
        )
    }

    private func regularFileLivenessIdentity(
        named name: String,
        under parent: Int32
    ) throws -> PortableInvocationLivenessKey {
        var metadata = stat()
        let status = name.withCString {
            Darwin.fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return PortableInvocationLivenessKey(
            device: metadata.st_dev,
            inode: metadata.st_ino
        )
    }

    /// Confirms that a mutation still targets the exact root and Invocations
    /// directory whose lifetime lock was reserved. The path check prevents a
    /// same-ID replacement Library from inheriting that authority.
    private func revalidateInvocationLivenessAuthority(
        _ authority: PortableInvocationLivenessAuthority,
        at libraryRoot: URL,
        in scope: LibraryScope,
        under rootDescriptor: Int32
    ) throws {
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        try revalidateInvocationLivenessAuthority(
            authority,
            at: libraryRoot,
            in: scope,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
    }

    private func revalidateInvocationLivenessAuthority(
        _ authority: PortableInvocationLivenessAuthority,
        at libraryRoot: URL,
        in scope: LibraryScope,
        under rootDescriptor: Int32,
        invocationsDescriptor: Int32
    ) throws {
        guard authority.libraryID == scope.libraryID else {
            throw PortableChatPersistenceError.libraryScopeMismatch
        }
        guard try invocationLivenessIdentity(of: rootDescriptor) == authority.root,
              try invocationLivenessIdentity(of: invocationsDescriptor) ==
              authority.invocations,
              try invocationLivenessIdentity(
                  named: "invocations",
                  under: rootDescriptor
              ) == authority.invocations
        else {
            throw PortableChatPersistenceError.invalidLayout
        }

        let currentRootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(currentRootDescriptor) }
        guard try invocationLivenessIdentity(of: currentRootDescriptor) == authority.root,
              try invocationLivenessIdentity(
                  named: "invocations",
                  under: currentRootDescriptor
              ) == authority.invocations
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try revalidateLibraryAuthority(
            libraryID: scope.libraryID,
            under: rootDescriptor
        )
    }

    private func invocationLivenessRevalidator(
        _ authority: PortableInvocationLivenessAuthority?,
        at libraryRoot: URL,
        in scope: LibraryScope,
        under rootDescriptor: Int32,
        invocationsDescriptor: Int32
    ) -> () throws -> Void {
        guard let authority else { return {} }
        return {
            try revalidateInvocationLivenessAuthority(
                authority,
                at: libraryRoot,
                in: scope,
                under: rootDescriptor,
                invocationsDescriptor: invocationsDescriptor
            )
        }
    }

    private func directoryIdentity(
        named name: String,
        under parent: Int32
    ) throws -> DirectoryIdentity {
        var metadata = stat()
        let status = name.withCString {
            Darwin.fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return DirectoryIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }

    private func flushDescriptor(_ descriptor: Int32) throws {
        try confined.flush(descriptor)
    }

    private func acquireExclusiveMutationLock(on descriptor: Int32) throws {
        while audoraFlock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw PortableChatPersistenceError.ioFailure }
        }
    }

    private func releaseMutationLock(on descriptor: Int32) {
        _ = audoraFlock(descriptor, LOCK_UN)
    }

    private func entryExists(named name: String, under parent: Int32) throws -> Bool {
        try confined.entryExists(named: name, under: parent)
    }

    private func isSymlink(named name: String, under parent: Int32) -> Bool {
        confined.isSymlink(named: name, under: parent)
    }

    private func urlHasSymlink(_ url: URL) -> Bool {
        var metadata = stat()
        return url.path.withCString { Darwin.lstat($0, &metadata) } == 0 &&
            (metadata.st_mode & S_IFMT) == S_IFLNK
    }

    private func listEntryNames(
        under descriptor: Int32,
        maximumCount: Int? = nil
    ) throws -> [String] {
        try confined.listEntryNames(under: descriptor, maximumCount: maximumCount)
    }

    private func removeCandidate(
        named candidateName: String,
        memoryID: CoachMemoryID,
        expectedIdentity: DirectoryIdentity,
        under parent: Int32
    ) {
        guard (try? directoryIdentity(named: candidateName, under: parent)) == expectedIdentity
        else {
            return
        }
        guard let candidate = try? openDirectory(named: candidateName, under: parent) else {
            return
        }
        defer { Darwin.close(candidate) }
        guard (try? directoryIdentity(of: candidate)) == expectedIdentity else { return }
        _ = "chat.json".withCString { Darwin.unlinkat(candidate, $0, 0) }
        if let memory = try? openDirectory(named: "memory", under: candidate) {
            _ = "\(memoryID.rawValue).json".withCString { Darwin.unlinkat(memory, $0, 0) }
            Darwin.close(memory)
        }
        _ = "memory".withCString { Darwin.unlinkat(candidate, $0, AT_REMOVEDIR) }
        _ = "messages".withCString { Darwin.unlinkat(candidate, $0, AT_REMOVEDIR) }
        guard (try? directoryIdentity(named: candidateName, under: parent)) == expectedIdentity
        else {
            return
        }
        _ = candidateName.withCString { Darwin.unlinkat(parent, $0, AT_REMOVEDIR) }
    }
}

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

@_spi(InvocationInfrastructure)
public actor PortableInvocationStore: InvocationPersistencePort {
    private struct ActiveLivenessKey: Hashable {
        let libraryID: LibraryID
        let invocationID: CoachInvocationID

        init(_ invocation: CoachInvocation) {
            libraryID = invocation.libraryID
            invocationID = invocation.id
        }
    }

    private struct ActiveLivenessAuthority {
        let invocation: CoachInvocation
        let lease: PortableInvocationLivenessLease

        var libraryID: LibraryID { invocation.libraryID }
    }

    private let persistence: PortableChatPersistence
    private let workspace: PortableLibraryWorkspace
    private let chats: PortableChatStore
    private var pendingLivenessLeases: [
        PendingCoachInvocationRequest: PortableInvocationLivenessLease
    ] = [:]
    private var activeLivenessLeases: [ActiveLivenessKey: ActiveLivenessAuthority] = [:]

    public init(
        persistence: PortableChatPersistence = PortableChatPersistence(),
        workspace: PortableLibraryWorkspace
    ) {
        self.persistence = persistence
        self.workspace = workspace
        chats = PortableChatStore(persistence: persistence, workspace: workspace)
    }

    public func prepareNewPendingInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> InvocationPendingPreparationOutcome {
        let library = request.library
        guard !pendingLivenessLeases.keys.contains(where: {
            $0.library.libraryID == library.libraryID
        }),
              !activeLivenessLeases.values.contains(where: {
                  $0.libraryID == library.libraryID
              })
        else { return .activeExists }
        let result: ActiveLibraryOperationResult<(
            InvocationPendingPreparationOutcome,
            PortableInvocationLivenessLease?
        )> = await workspace.performActiveReadWriteOperation(in: library) { root in
            do {
                switch try persistence.prepareNewPendingInvocation(
                    request,
                    at: root,
                    in: library
                ) {
                case let .prepared(aggregate, lease):
                    let pendingRequest = PendingCoachInvocationRequest(
                        library: library,
                        chatID: request.chatID,
                        pendingUserTurnID: request.pendingUserTurn.id
                    )
                    do {
                        return (
                            .prepared(
                                try InvocationPendingAuthority(
                                    request: pendingRequest,
                                    aggregate: aggregate
                                )
                            ),
                            lease
                        )
                    } catch {
                        lease.release()
                        return (.unavailable, nil)
                    }
                case let .stale(current):
                    return (.stale(current), nil)
                case let .frozen(frozen):
                    return (.frozen(frozen), nil)
                case .activeExists:
                    return (.activeExists, nil)
                }
            } catch PortableChatPersistenceError.readOnlyLibrary {
                return (.readOnlyLibrary, nil)
            } catch {
                return (.unavailable, nil)
            }
        }
        switch result {
        case let .performed((outcome, lease)):
            if let lease, case let .prepared(authority) = outcome {
                pendingLivenessLeases[authority.request] = lease
            }
            return outcome
        case .readOnly:
            return .readOnlyLibrary
        case .unavailable:
            return .unavailable
        }
    }

    public func acquirePendingInvocation(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingAcquisitionOutcome {
        let library = request.library
        guard !pendingLivenessLeases.keys.contains(where: {
            $0.library.libraryID == library.libraryID
        }),
              !activeLivenessLeases.values.contains(where: {
                  $0.libraryID == library.libraryID
              })
        else { return .activeExists }
        let result: ActiveLibraryOperationResult<(
            InvocationPendingAcquisitionOutcome,
            PortableInvocationLivenessLease?
        )> =
            await workspace.performActiveReadWriteOperation(in: library) { root in
                do {
                    guard let lease = try persistence.acquireInvocationLivenessLease(
                        at: root,
                        in: library,
                        for: request
                    ) else {
                        return (.activeExists, nil)
                    }
                    do {
                        try persistence.reconcileInterruptedInvocations(
                            at: root,
                            in: library,
                            holding: lease
                        )
                        guard try !persistence.hasActiveInvocation(
                            at: root,
                            in: library,
                            holding: lease
                        ) else {
                            lease.release()
                            return (.activeExists, nil)
                        }
                        switch try persistence.load(
                            request.chatID,
                            at: root,
                            in: library
                        ) {
                        case let .readWrite(aggregate):
                            do {
                                let authority = try InvocationPendingAuthority(
                                    request: request,
                                    aggregate: aggregate
                                )
                                return (.acquired(authority), lease)
                            } catch {
                                lease.release()
                                return (.ineligible(aggregate), nil)
                            }
                        case .frozen:
                            lease.release()
                            return (.ineligible(nil), nil)
                        }
                    } catch {
                        lease.release()
                        return (.unavailable, nil)
                    }
                } catch {
                    return (.unavailable, nil)
                }
            }
        switch result {
        case let .performed((outcome, lease)):
            if let lease {
                pendingLivenessLeases[request] = lease
            }
            return outcome
        case .readOnly, .unavailable:
            return .unavailable
        }
    }

    public func revalidatePendingInvocation(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingResolutionOutcome {
        let request = authority.request
        guard pendingLivenessLeases[request] != nil else { return .unavailable }
        let result: ActiveLibraryOperationResult<InvocationPendingResolutionOutcome> =
            await workspace.performActiveReadWriteOperation(in: request.library) { root in
                do {
                    switch try persistence.load(
                        request.chatID,
                        at: root,
                        in: request.library
                    ) {
                    case let .readWrite(aggregate):
                        do {
                            return .eligible(
                                try InvocationPendingAuthority(
                                    request: request,
                                    aggregate: aggregate
                                )
                            )
                        } catch {
                            return .ineligible(aggregate)
                        }
                    case .frozen:
                        return .ineligible(nil)
                    }
                } catch PortableChatPersistenceError.chatMissing {
                    return .ineligible(nil)
                } catch {
                    return .unavailable
                }
            }
        let outcome: InvocationPendingResolutionOutcome = switch result {
        case let .performed(outcome): outcome
        case .readOnly: .ineligible(nil)
        case .unavailable: .unavailable
        }
        if case .ineligible = outcome {
            releasePendingLivenessLease(for: request)
        }
        return outcome
    }

    public func installInvocation(
        _ mutation: InstallCoachInvocationMutation
    ) async -> InvocationInstallOutcome {
        guard let lease = pendingLivenessLeases.removeValue(
            forKey: mutation.authority.request
        ) else {
            return .failed
        }
        let result: ActiveLibraryOperationResult<InvocationInstallOutcome> =
            await workspace.performActiveReadWriteOperation(
                in: mutation.authority.request.library
            ) { root in
                do {
                    return try persistence.installInvocation(
                        mutation,
                        at: root,
                        holding: lease
                    )
                } catch {
                    if let installed = try? persistence.reconcileInstalledInvocation(
                        mutation,
                        at: root,
                        holding: lease
                    ) {
                        return .installed(installed)
                    }
                    return .failed
                }
            }
        let outcome: InvocationInstallOutcome = switch result {
        case let .performed(outcome): outcome
        case .readOnly, .unavailable: .failed
        }
        if case let .installed(invocation) = outcome {
            activeLivenessLeases[ActiveLivenessKey(invocation)] = ActiveLivenessAuthority(
                invocation: invocation,
                lease: lease
            )
        } else {
            pendingLivenessLeases[mutation.authority.request] = lease
        }
        return outcome
    }

    public func checkLaunchIdentity(
        _ identity: InvocationLaunchIdentity,
        for authority: InvocationPendingAuthority
    ) async -> InvocationLaunchIdentityAvailabilityOutcome {
        guard let lease = pendingLivenessLeases[authority.request] else {
            return .unavailable
        }
        let result: ActiveLibraryOperationResult<InvocationLaunchIdentityAvailabilityOutcome> =
            await workspace.performActiveReadWriteOperation(
                in: authority.request.library
            ) { root in
                do {
                    return try persistence.checkLaunchIdentity(
                        identity,
                        for: authority,
                        at: root,
                        holding: lease
                    )
                } catch {
                    return .unavailable
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly, .unavailable: .unavailable
        }
    }

    public func cancelInvocationReservation(
        _ request: PendingCoachInvocationRequest
    ) async {
        releasePendingLivenessLease(for: request)
    }

    public func markContextCapacityFailure(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome {
        await markPendingFailure(authority, failure: .coachContextCannotFit)
    }

    public func markInterruptedNewSend(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome {
        await markPendingFailure(authority, failure: .coachResponseInterrupted)
    }

    public func recoverPendingAfterTerminalFailure(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingResolutionOutcome {
        let result: ActiveLibraryOperationResult<InvocationPendingResolutionOutcome> =
            await workspace.performActiveReadWriteOperation(in: request.library) { root in
                do {
                    try persistence.reconcileInterruptedInvocationsIfUnowned(
                        at: root,
                        in: request.library
                    )
                    switch try persistence.load(
                        request.chatID,
                        at: root,
                        in: request.library
                    ) {
                    case let .readWrite(aggregate):
                        do {
                            return .eligible(
                                try InvocationPendingAuthority(
                                    request: request,
                                    aggregate: aggregate
                                )
                            )
                        } catch {
                            return .ineligible(aggregate)
                        }
                    case .frozen:
                        return .ineligible(nil)
                    }
                } catch PortableChatPersistenceError.chatMissing {
                    return .ineligible(nil)
                } catch {
                    return .unavailable
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly, .unavailable: .unavailable
        }
    }

    private func markPendingFailure(
        _ authority: InvocationPendingAuthority,
        failure: PendingUserTurnFailure
    ) async -> InvocationPendingMutationOutcome {
        let lease = pendingLivenessLeases[authority.request]
        defer { releasePendingLivenessLease(for: authority.request) }
        let mutation: ReplacePendingUserTurnMutation
        do {
            mutation = try ReplacePendingUserTurnMutation(
                library: authority.request.library,
                chatID: authority.request.chatID,
                base: authority.pendingUserTurn,
                replacement: authority.pendingUserTurn.replacingFailure(failure)
            )
        } catch {
            return .failed
        }
        if let lease {
            return await performPendingMutation(
                in: authority.request.library,
                operation: { root in
                    try self.persistence.replacePendingUserTurn(
                        mutation,
                        at: root,
                        holding: lease
                    )
                },
                reconcile: { root in
                    try self.persistence.reconcileCommittedPendingReplacement(
                        mutation,
                        at: root,
                        holding: lease
                    )
                }
            )
        }
        return invocationMutationOutcome(await chats.replacePendingUserTurn(mutation))
    }

    public func rejectNewSend(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome {
        let lease = pendingLivenessLeases[authority.request]
        defer { releasePendingLivenessLease(for: authority.request) }
        let mutation = DiscardPendingUserTurnMutation(
            library: authority.request.library,
            chatID: authority.request.chatID,
            pendingUserTurn: authority.pendingUserTurn
        )
        if let lease {
            return await performPendingMutation(
                in: authority.request.library,
                operation: { root in
                    try self.persistence.discardPendingUserTurn(
                        mutation,
                        at: root,
                        holding: lease
                    )
                },
                reconcile: { root in
                    try self.persistence.reconcileCommittedPendingDiscard(
                        mutation,
                        at: root,
                        holding: lease
                    )
                }
            )
        }
        return invocationMutationOutcome(
            await chats.discardPendingUserTurn(mutation)
        )
    }

    public func abortInstalledNewSend(
        _ invocation: CoachInvocation
    ) async -> InvocationPendingMutationOutcome {
        guard let authority = activeLivenessLeases[ActiveLivenessKey(invocation)],
              authority.invocation == invocation
        else { return .failed }
        defer { releaseActiveLivenessLease(for: invocation) }
        let scope = LibraryScope(libraryID: invocation.libraryID)
        let result: ActiveLibraryOperationResult<InvocationPendingMutationOutcome> =
            await workspace.performActiveReadWriteOperation(in: scope) { root in
                do {
                    switch try persistence.abortInstalledNewSend(
                        invocation,
                        at: root,
                        in: scope,
                        holding: authority.lease
                    ) {
                    case let .committed(aggregate): return .committed(aggregate)
                    case let .stale(aggregate): return .stale(aggregate)
                    case .frozen: return .failed
                    }
                } catch {
                    return .failed
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly, .unavailable: .failed
        }
    }

    public func publish(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationOutcome {
        guard let authority = activeLivenessLeases[ActiveLivenessKey(mutation.invocation)],
              authority.invocation == mutation.invocation
        else { return .failed }
        let scope = LibraryScope(libraryID: mutation.invocation.libraryID)
        let result: ActiveLibraryOperationResult<InvocationPublicationOutcome> =
            await workspace.performActiveReadWriteOperation(in: scope) { root in
                do {
                    switch try persistence.publishInvocation(
                        mutation,
                        at: root,
                        in: scope,
                        holding: authority.lease
                    ) {
                    case let .committed(aggregate): return .committed(aggregate)
                    case let .stale(aggregate): return .stale(aggregate)
                    case .frozen: return .failed
                    }
                } catch {
                    if let committed = try? persistence
                        .reconcileCommittedInvocationPublication(
                            mutation,
                            at: root,
                            in: scope,
                            holding: authority.lease
                        )
                    {
                        return .committed(committed)
                    }
                    return .failed
                }
            }
        let outcome: InvocationPublicationOutcome = switch result {
        case let .performed(outcome): outcome
        case .readOnly, .unavailable: .failed
        }
        if case .committed = outcome {
            releaseActiveLivenessLease(for: mutation.invocation)
        }
        return outcome
    }

    private func invocationMutationOutcome(
        _ outcome: ChatMutationOutcome
    ) -> InvocationPendingMutationOutcome {
        switch outcome {
        case let .committed(aggregate): .committed(aggregate)
        case let .stale(aggregate): .stale(aggregate)
        case .collision, .profileStatementGenerationChanged, .frozen,
             .readOnlyLibrary, .failed: .failed
        }
    }

    private func performPendingMutation(
        in library: LibraryScope,
        operation: @Sendable (URL) throws -> PortableChatMutationResult,
        reconcile: @Sendable (URL) throws -> ChatAggregate?
    ) async -> InvocationPendingMutationOutcome {
        let result: ActiveLibraryOperationResult<InvocationPendingMutationOutcome> =
            await workspace.performActiveReadWriteOperation(in: library) { root in
                do {
                    switch try operation(root) {
                    case let .committed(aggregate): return .committed(aggregate)
                    case let .stale(aggregate): return .stale(aggregate)
                    case .frozen: return .failed
                    }
                } catch {
                    if let committed = try? reconcile(root) {
                        return .committed(committed)
                    }
                    return .failed
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly, .unavailable: .failed
        }
    }

    private func releasePendingLivenessLease(
        for request: PendingCoachInvocationRequest
    ) {
        pendingLivenessLeases.removeValue(forKey: request)?.release()
    }

    private func releaseActiveLivenessLease(for invocation: CoachInvocation) {
        let key = ActiveLivenessKey(invocation)
        guard activeLivenessLeases[key]?.invocation == invocation else { return }
        activeLivenessLeases.removeValue(forKey: key)?.lease.release()
    }
}

private struct ChatDTO: Codable {
    let schemaVersion: UInt32
    let chatId: String
    let manifestRevision: UInt64
    let title: String
    let createdAt: String
    let updatedAt: String
    let creationKind: String
    let originAttachmentId: String?
    let profileStatementGenerationAtCreation: UInt64
    let attachments: [ChatAttachmentDTO]
    let draft: ChatDraftDTO
    let messageIds: [String]
    let currentMemoryId: String
}

private struct ChatAttachmentDTO: Codable {
    let attachmentId: String
    let sessionId: String
    let transcriptRevisionId: String
}

private struct ChatDraftDTO: Codable {
    let draftId: String
    let version: UInt64
    let text: String
    let updatedAt: String
}

private struct PendingUserTurnDTO: Codable {
    let schemaVersion: UInt32
    let pendingUserTurnId: String
    let draftId: String
    let draftVersion: UInt64
    let responsePositionId: String
    let failure: String?
}

private struct ChatMessageDTO: Codable {
    let schemaVersion: UInt32
    let messageId: String
    let responsePositionId: String
    let role: String
    let text: String?
    let markdown: String?
    let profileRevisionId: String?
    let profileStatementGeneration: UInt64?
    let createdAt: String
}

private struct CoachInvocationDTO: Codable {
    let schemaVersion: UInt32
    let invocationId: String
    let attemptId: String
    let providerIdempotencyValue: String
    let libraryId: String
    let chatId: String
    let pendingUserTurnId: String
    let draftId: String
    let draftVersion: UInt64
    let responsePositionId: String
    let expectedManifestRevision: UInt64
    let profileRevisionId: String?
    let profileStatementGeneration: UInt64?
    let admittedAt: String
}

private struct CoachMemoryDTO: Codable {
    let schemaVersion: UInt32
    let memoryId: String
    let chatId: String
    let generalNotes: String
    let sessionSummaries: [CoachMemorySummaryDTO]
}

private struct CoachMemorySummaryDTO: Codable {
    let sessionAttachmentId: String
    let notes: String
}
