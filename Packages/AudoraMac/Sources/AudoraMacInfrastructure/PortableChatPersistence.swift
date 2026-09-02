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

/// The one idempotent RAII resource behind every semantically typed persistence
/// lease. It couples the descriptor, cross-process `flock`, and in-process
/// registry claim so no wrapper can release only part of the authority.
private final class PortableRegistryFileLockLease: @unchecked Sendable {
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

/// Typed ownership of the stable Invocations-directory namespace.
private final class PortableInvocationNamespaceLock: @unchecked Sendable {
    private let resource: PortableRegistryFileLockLease
    var key: PortableInvocationLivenessKey { resource.key }

    init(descriptor: Int32, key: PortableInvocationLivenessKey) {
        resource = PortableRegistryFileLockLease(descriptor: descriptor, key: key)
    }

    func release() { resource.release() }
}

/// Exact Pending-file authority shared by the winning Invocation lease and
/// ordinary Pending mutations.
private final class PortablePendingUserTurnFileLease: @unchecked Sendable {
    private let resource: PortableRegistryFileLockLease
    var key: PortableInvocationLivenessKey { resource.key }

    init(descriptor: Int32, key: PortableInvocationLivenessKey) {
        resource = PortableRegistryFileLockLease(descriptor: descriptor, key: key)
    }

    func release() { resource.release() }
}

/// One live provider owner's confined Library lifetime authority. The descriptor
/// remains locked from the first active check through terminal publication or
/// abort. A process crash closes it in the kernel, proving that relaunch recovery
/// may reconcile the durable Invocation.
final class PortableInvocationLivenessLease: @unchecked Sendable {
    private let lock = NSLock()
    private var rootDescriptor: Int32?
    private var namespaceLock: PortableInvocationNamespaceLock?
    private var reservedAuthority: PortableInvocationLivenessAuthority
    private var pendingUserTurnLease: PortablePendingUserTurnFileLease
    private let reservedRequest: PendingCoachInvocationRequest
    private let didRelease: @Sendable () -> Void

    fileprivate init(
        rootDescriptor: Int32,
        namespaceLock: PortableInvocationNamespaceLock,
        authority: PortableInvocationLivenessAuthority,
        pendingUserTurnLease: PortablePendingUserTurnFileLease,
        reservedRequest: PendingCoachInvocationRequest,
        didRelease: @escaping @Sendable () -> Void
    ) {
        self.rootDescriptor = rootDescriptor
        self.namespaceLock = namespaceLock
        reservedAuthority = authority
        self.pendingUserTurnLease = pendingUserTurnLease
        self.reservedRequest = reservedRequest
        self.didRelease = didRelease
    }

    fileprivate func authority() -> PortableInvocationLivenessAuthority? {
        lock.lock()
        defer { lock.unlock() }
        guard rootDescriptor != nil, namespaceLock != nil else { return nil }
        return reservedAuthority
    }

    fileprivate func authority(
        for request: PendingCoachInvocationRequest
    ) -> PortableInvocationLivenessAuthority? {
        guard request == reservedRequest else { return nil }
        return authority()
    }

    fileprivate func reservation() -> (
        authority: PortableInvocationLivenessAuthority,
        request: PendingCoachInvocationRequest
    )? {
        lock.lock()
        defer { lock.unlock() }
        guard rootDescriptor != nil, namespaceLock != nil else { return nil }
        return (reservedAuthority, reservedRequest)
    }

    /// Rebinds the lifetime fence after the Retry processing CAS replaces the
    /// Pending inode. The new file lock is acquired and validated before this
    /// atomic swap; releasing the old inode afterward leaves no unfenced gap.
    fileprivate func rebindPendingUserTurnLease(
        _ replacement: PortablePendingUserTurnFileLease
    ) throws {
        lock.lock()
        guard rootDescriptor != nil,
              namespaceLock != nil,
              reservedAuthority.pendingUserTurn == pendingUserTurnLease.key
        else {
            lock.unlock()
            replacement.release()
            throw PortableChatPersistenceError.ioFailure
        }
        let prior = pendingUserTurnLease
        pendingUserTurnLease = replacement
        reservedAuthority = PortableInvocationLivenessAuthority(
            libraryID: reservedAuthority.libraryID,
            root: reservedAuthority.root,
            invocations: reservedAuthority.invocations,
            pendingUserTurn: replacement.key
        )
        lock.unlock()
        prior.release()
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
        didRelease()
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
    case beforeInvocationIdentityRead
    case beforeInvocationPartialWrite
    case afterInvocationPartialWrite
    case afterInvocationFileFlush
    case afterInvocationInstall
    case afterInvocationDirectoryFlush
    case afterReconciledInvocationRootFlush
    case afterReconciledInvocationDirectoryFlush
    case beforeRetryProcessingPendingPartialWrite
    case afterRetryProcessingPendingPartialWrite
    case afterRetryProcessingPendingFileFlush
    case afterRetryProcessingPendingInstall
    case afterRetryProcessingPendingDirectoryFlush
    case afterRetryProcessingAuthorityRebind
    case beforeNextAttemptPartialWrite
    case afterNextAttemptPartialWrite
    case afterNextAttemptFileFlush
    case afterNextAttemptInstall
    case afterNextAttemptDirectoryFlush
    case beforeInvocationTerminalIntentPartialWrite
    case afterInvocationTerminalIntentPartialWrite
    case afterInvocationTerminalIntentFileFlush
    case afterInvocationTerminalIntentInstall
    case afterInvocationTerminalIntentDirectoryFlush
    case afterInvocationAbortMarkerInstall
    case afterInvocationAbortDirectoryRemoval
    case afterInvocationAbortPendingFailureInstall
    case beforePublicationProofPartialWrite
    case afterPublicationProofPartialWrite
    case afterPublicationProofFileFlush
    case afterPublicationProofInstall
    case afterPublicationProofDirectoryFlush
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

enum PortableInvocationPublicationRecoveryResult: Sendable {
    case published(ChatAggregate)
    case notPublished
    case owned
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

private func coalesceFrozenChatSnapshot(
    _ snapshot: FrozenChatSnapshot,
    into snapshots: inout [ChatID: FrozenChatSnapshot]
) {
    guard let current = snapshots[snapshot.chatID] else {
        snapshots[snapshot.chatID] = snapshot
        return
    }
    let reason: FrozenChatReason = switch (current.reason, snapshot.reason) {
    case (.corrupt, _), (_, .corrupt): .corrupt
    case (.unsupportedSchema, _), (_, .unsupportedSchema): .unsupportedSchema
    case (.newerSchema, .newerSchema): .newerSchema
    }
    snapshots[snapshot.chatID] = FrozenChatSnapshot(
        chatID: snapshot.chatID,
        reason: reason
    )
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

    enum PreparedPendingInvocationResult {
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
    private let invocationLivenessReleased: @Sendable () -> Void

    public init(
        fault: @escaping @Sendable (PortableChatFaultPoint) throws -> Void = { _ in }
    ) {
        self.fault = fault
        invocationLivenessReleased = {}
    }

    init(
        fault: @escaping @Sendable (PortableChatFaultPoint) throws -> Void,
        invocationLivenessReleased: @escaping @Sendable () -> Void
    ) {
        self.fault = fault
        self.invocationLivenessReleased = invocationLivenessReleased
    }

    /// Reserves the one live provider authority for this exact Library. `nil`
    /// means another process or separately composed store still owns it.
    func acquireInvocationLivenessLease(
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
            reservedRequest: request,
            didRelease: invocationLivenessReleased
        )
    }

    /// Owns the full new-Send installation window: the Library Invocation
    /// namespace is acquired before the Pending CAS, and the exact installed
    /// Pending inode is locked before the Chat mutation lock is released.
    func prepareNewPendingInvocation(
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

        let frozenChatIDs = try reconcileInterruptedInvocations(
            at: libraryRoot,
            in: scope,
            livenessAuthority: namespaceAuthority,
            reservedRequest: nil
        )
        try reconcileUninstalledPendingIntents(
            at: libraryRoot,
            in: scope,
            livenessAuthority: namespaceAuthority,
            frozenChatIDs: frozenChatIDs
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
                reservedRequest: pendingRequest,
                didRelease: invocationLivenessReleased
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

    func reconcileInterruptedInvocationsIfUnowned(
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws {
        guard let lease = try acquireInvocationRecoveryLease(
            at: libraryRoot,
            in: scope
        ) else { return }
        defer { lease.release() }
        let frozenChatIDs = try reconcileInterruptedInvocations(
            at: libraryRoot,
            in: scope,
            holding: lease
        )
        try reconcileUninstalledPendingIntents(
            at: libraryRoot,
            in: scope,
            holding: lease,
            frozenChatIDs: frozenChatIDs
        )
    }

    /// A Pending is installed before admission and before its durable
    /// Invocation. Once the Library Invocation namespace is proven unowned,
    /// any remaining failure-free Pending is therefore an interrupted launch,
    /// not an active request. Preserve its exact intent and expose Retry/Discard.
    private func reconcileUninstalledPendingIntents(
        at libraryRoot: URL,
        in scope: LibraryScope,
        holding lease: PortableInvocationRecoveryLease,
        frozenChatIDs: Set<ChatID>
    ) throws {
        guard let livenessAuthority = lease.authority() else {
            throw PortableChatPersistenceError.ioFailure
        }
        try reconcileUninstalledPendingIntents(
            at: libraryRoot,
            in: scope,
            livenessAuthority: livenessAuthority,
            frozenChatIDs: frozenChatIDs
        )
    }

    private func reconcileUninstalledPendingIntents(
        at libraryRoot: URL,
        in scope: LibraryScope,
        livenessAuthority: PortableInvocationLivenessAuthority,
        frozenChatIDs: Set<ChatID>
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
        let remainingInvocationNames = try invocationDirectoryNamesRemovingEmptyResidue(
            under: invocationsDescriptor,
            beforeRemoving: revalidateLiveness
        )
        let inspections = try remainingInvocationNames.sorted().map { name in
            try inspectInvocationDirectory(
                named: name,
                expectedLibraryID: scope.libraryID,
                under: invocationsDescriptor,
                reconcileProofPartial: false
            )
        }
        let invocationRootFrozenTargets = Set<ChatID>(
            inspections.compactMap { inspection in
                guard case let .frozen(common, _) = inspection else { return nil }
                return common.chatID
            }
        )
        var remainingTargets: Set<ChatID> = []
        for inspection in inspections {
            let chatID: ChatID
            switch inspection {
            case let .available(record):
                chatID = record.invocation.chatID
                guard invocationRootFrozenTargets.contains(chatID) else {
                    throw PortableChatPersistenceError.invalidLayout
                }
            case let .frozen(common, _):
                chatID = common.chatID
            }
            guard frozenChatIDs.contains(chatID) else {
                throw PortableChatPersistenceError.invalidLayout
            }
            remainingTargets.insert(chatID)
        }
        guard remainingTargets == frozenChatIDs else {
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
            guard !frozenChatIDs.contains(chatID) else { continue }
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

    private var invocationEvidenceCodec: PortableInvocationEvidenceCodec {
        PortableInvocationEvidenceCodec(
            maximumRootBytes: Self.maximumRootBytes,
            maximumMessageCount: Self.maximumMessageDirectoryEntries
        )
    }

    public func loadCatalog(
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> [LoadedPortableChat] {
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        try reconcileStagedChatCandidatesExclusively(under: rootDescriptor)
        let publicationProof = try publicationProofLookup(
            expectedLibraryID: scope.libraryID,
            under: rootDescriptor
        )
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
                if let snapshot = publicationProof.frozenSnapshots[chatID] {
                    return .frozen(snapshot)
                }
                do {
                    let descriptor = try openDirectory(named: name, under: chatsDescriptor)
                    defer { Darwin.close(descriptor) }
                    return try loadChatReconcilingTransients(
                        from: descriptor,
                        expectedID: chatID,
                        publicationProofAuthority:
                            publicationProof.authority(for: chatID)
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
        let publicationProof = try publicationProofLookup(
            expectedLibraryID: scope.libraryID,
            under: rootDescriptor
        )
        if let snapshot = publicationProof.frozenSnapshots[chatID] {
            return .frozen(snapshot)
        }
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
                expectedID: chatID,
                publicationProofAuthority: publicationProof.authority(for: chatID)
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

    func replacePendingUserTurn(
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

    func discardPendingUserTurn(
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

    func hasActiveInvocation(
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
        _ = try reconcileInterruptedInvocations(
            at: libraryRoot,
            in: scope,
            livenessAuthority: nil,
            reservedRequest: nil
        )
    }

    func reconcileInterruptedInvocations(
        at libraryRoot: URL,
        in scope: LibraryScope,
        holding lease: PortableInvocationLivenessLease
    ) throws {
        guard let reservation = lease.reservation() else {
            throw PortableChatPersistenceError.ioFailure
        }
        _ = try reconcileInterruptedInvocations(
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
    ) throws -> Set<ChatID> {
        guard let authority = lease.authority() else {
            throw PortableChatPersistenceError.ioFailure
        }
        return try reconcileInterruptedInvocations(
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
    ) throws -> Set<ChatID> {
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
        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        let bodyInspections: [(name: String, result: InvocationBodyInspection)] =
            try candidates.sorted().map { name in
                (
                    name,
                    try inspectInvocationBody(
                        named: name,
                        expectedLibraryID: scope.libraryID,
                        under: invocationsDescriptor
                    )
                )
            }
        var frozenChatIDs: Set<ChatID> = []
        for (_, inspection) in bodyInspections {
            if case let .frozen(common, _) = inspection {
                frozenChatIDs.insert(common.chatID)
            }
        }
        var exactPrePublicationNames: Set<String> = []
        var directoryInspections: [String: InvocationDirectoryInspection] = [:]
        // Exact prepublication intent makes proof bytes disposable. Establish
        // that classification before decoding proof, while still completing
        // every read-only root classification before the first retirement.
        for (name, bodyInspection) in bodyInspections {
            guard case let .available(bodyIdentity) = bodyInspection,
                  !frozenChatIDs.contains(bodyIdentity.invocation.chatID)
            else { continue }
            let invocation = bodyIdentity.invocation
            do {
                if try retireExactPrePublicationInvocationIfPresent(
                    invocation,
                    named: name,
                    scope: scope,
                    reservedRequest: reservedRequest,
                    livenessAuthority: livenessAuthority,
                    invocationsDescriptor: invocationsDescriptor,
                    chatsDescriptor: chatsDescriptor,
                    beforeCommitting: revalidateBeforeMutation,
                    performRetirement: false
                ) {
                    exactPrePublicationNames.insert(name)
                    continue
                }
            } catch let error as PortableChatPersistenceError {
                guard frozenChatSnapshot(
                    for: error,
                    chatID: invocation.chatID
                ) != nil else { throw error }
                frozenChatIDs.insert(invocation.chatID)
                continue
            }
            let inspection = try inspectInvocationDirectory(
                named: name,
                expectedLibraryID: scope.libraryID,
                under: invocationsDescriptor,
                reconcileProofPartial: false
            )
            directoryInspections[name] = inspection
            if case let .frozen(common, _) = inspection {
                frozenChatIDs.insert(common.chatID)
            }
        }
        // Classify every trustworthy Invocation root before touching one. A
        // frozen root owns the complete recovery decision for its Chat, so an
        // otherwise readable sibling root for that same Chat must remain byte
        // exact regardless of directory enumeration order.
        var availableCount = 0
        for (name, bodyInspection) in bodyInspections {
            guard case let .available(bodyIdentity) = bodyInspection,
                  !frozenChatIDs.contains(bodyIdentity.invocation.chatID)
            else { continue }
            let invocation = bodyIdentity.invocation
            if exactPrePublicationNames.contains(name) {
                do {
                    if try retireExactPrePublicationInvocationIfPresent(
                        invocation,
                        named: name,
                        scope: scope,
                        reservedRequest: reservedRequest,
                        livenessAuthority: livenessAuthority,
                        invocationsDescriptor: invocationsDescriptor,
                        chatsDescriptor: chatsDescriptor,
                        beforeCommitting: revalidateBeforeMutation
                    ) {
                        continue
                    }
                } catch let error as PortableChatPersistenceError {
                    guard frozenChatSnapshot(
                        for: error,
                        chatID: invocation.chatID
                    ) != nil else { throw error }
                    frozenChatIDs.insert(invocation.chatID)
                    continue
                }
            }
            let initialInspection = try directoryInspections[name] ??
                inspectInvocationDirectory(
                    named: name,
                    expectedLibraryID: scope.libraryID,
                    under: invocationsDescriptor,
                    reconcileProofPartial: false
                )
            guard case .available = initialInspection else {
                if case let .frozen(common, _) = initialInspection {
                    frozenChatIDs.insert(common.chatID)
                }
                continue
            }
            let inspection = try inspectInvocationDirectory(
                named: name,
                expectedLibraryID: scope.libraryID,
                under: invocationsDescriptor,
                reconcileProofPartial: true,
                beforeRemoving: revalidateBeforeMutation
            )
            guard case let .available(record) = inspection else {
                if case let .frozen(common, _) = inspection {
                    frozenChatIDs.insert(common.chatID)
                }
                continue
            }
            availableCount += 1
            guard availableCount == 1 else {
                throw PortableChatPersistenceError.invalidLayout
            }
            guard record.invocation.hasSameDurableProjection(as: invocation) else {
                throw PortableChatPersistenceError.invalidLayout
            }
            do {
                let invocationRoot = try openDirectory(
                    named: name,
                    under: invocationsDescriptor
                )
                defer { Darwin.close(invocationRoot) }
                let publicationAuthority = record.publicationProof.map {
                    InvocationPublicationProofAuthority(
                        invocation: invocation,
                        proof: $0
                    )
                }

                guard try entryExists(
                    named: invocation.chatID.rawValue,
                    under: chatsDescriptor
                ) else {
                    guard record.publicationProof == nil else {
                        throw PortableChatPersistenceError.invalidLayout
                    }
                    try removeInvocationDirectoryIfPresent(
                        invocation,
                        under: invocationsDescriptor,
                        beforeRemoving: revalidateBeforeMutation
                    )
                    continue
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
                if try entryExists(
                    named: "pending-user-turn.json",
                    under: chatDescriptor
                ) {
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
                    publicationProofAuthority: publicationAuthority,
                    beforeDestructiveMutation: revalidateBeforeMutation
                ) else { throw PortableChatPersistenceError.invalidLayout }

                let pendingData = try entryExists(
                    named: "pending-user-turn.json",
                    under: chatDescriptor
                ) ? boundedData(
                    named: "pending-user-turn.json",
                    under: chatDescriptor
                ) : nil
                if let proof = record.publicationProof,
                   try isExactPublishedInvocation(
                       proof,
                       invocation: invocation,
                       aggregate: current,
                       pendingData: pendingData,
                       under: chatDescriptor
                   )
                {
                    try removeInvocationDirectoryIfPresent(
                        invocation,
                        under: invocationsDescriptor,
                        beforeRemoving: revalidateBeforeMutation
                    )
                    continue
                }
                guard (try? invocation.validateIntent(against: current)) != nil else {
                    if record.publicationProof != nil ||
                        (current.pendingUserTurn == nil &&
                            !isProvablyPrePublication(invocation, current: current))
                    {
                        throw PortableChatPersistenceError.invalidLayout
                    }
                    try removeInvocationDirectoryIfPresent(
                        invocation,
                        under: invocationsDescriptor,
                        beforeRemoving: revalidateBeforeMutation
                    )
                    continue
                }
                if record.publicationProof != nil {
                    try removePublicationProofIfPresent(
                        from: invocationRoot,
                        beforeRemoving: revalidateBeforeMutation
                    )
                }
                _ = try retireInvocation(
                    invocation,
                    current: current,
                    invocationRoot: invocationRoot,
                    invocationsDescriptor: invocationsDescriptor,
                    chatDescriptor: chatDescriptor,
                    beforeCommitting: revalidateBeforeMutation
                )
            } catch let error as PortableChatPersistenceError {
                guard frozenChatSnapshot(
                    for: error,
                    chatID: invocation.chatID
                ) != nil else { throw error }
                frozenChatIDs.insert(invocation.chatID)
            }
        }
        return frozenChatIDs
    }

    /// A durable Invocation plus its exact still-locked intent proves that the
    /// Chat manifest never crossed publication's commit point. Classify that
    /// state without decoding publication evidence: a crash can leave the
    /// proof file or its partial incomplete, and those bytes have no authority
    /// until the manifest changes. Once the intent is proven, all recognized
    /// precommit evidence is disposable and normal interruption retirement
    /// cleans the unreferenced Chat artifacts.
    private func retireExactPrePublicationInvocationIfPresent(
        _ invocation: CoachInvocation,
        named name: String,
        scope: LibraryScope,
        reservedRequest: PendingCoachInvocationRequest?,
        livenessAuthority: PortableInvocationLivenessAuthority?,
        invocationsDescriptor: Int32,
        chatsDescriptor: Int32,
        beforeCommitting: () throws -> Void,
        performRetirement: Bool = true
    ) throws -> Bool {
        guard try entryExists(
            named: invocation.chatID.rawValue,
            under: chatsDescriptor
        ) else { return false }
        let invocationRoot = try openDirectory(
            named: name,
            under: invocationsDescriptor
        )
        defer { Darwin.close(invocationRoot) }
        guard try loadInvocationBodyIdentity(
            expectedInvocationID: invocation.id,
            expectedLibraryID: scope.libraryID,
            under: invocationRoot
        ).invocation.hasSameDurableProjection(as: invocation)
        else { throw PortableChatPersistenceError.invalidLayout }

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
        if try entryExists(
            named: "pending-user-turn.json",
            under: chatDescriptor
        ) {
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

        try beforeCommitting()
        let loaded: LoadedPortableChat
        do {
            loaded = try loadChat(
                from: chatDescriptor,
                expectedID: invocation.chatID,
                reconcileTransients: false
            )
        } catch let error as PortableChatPersistenceError {
            guard frozenChatSnapshot(
                for: error,
                chatID: invocation.chatID
            ) != nil else { throw error }
            return false
        }
        guard case let .readWrite(current) = loaded,
              (try? invocation.validateIntent(against: current)) != nil
        else { return false }

        if performRetirement {
            try discardPrePublicationEvidence(
                from: invocationRoot,
                beforeRemoving: beforeCommitting
            )
            _ = try retireInvocation(
                invocation,
                current: current,
                invocationRoot: invocationRoot,
                invocationsDescriptor: invocationsDescriptor,
                chatDescriptor: chatDescriptor,
                beforeCommitting: beforeCommitting
            )
        }
        return true
    }

    func checkLaunchIdentity(
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
            let inspection = try inspectInvocationDirectory(
                named: invocationName,
                expectedLibraryID: authority.request.library.libraryID,
                under: invocationsDescriptor,
                reconcileProofPartial: false
            )
            switch inspection {
            case let .available(record):
                let attempts = record.invocation.attempts
                if attempts.contains(where: { $0.id == identity.attemptID }) {
                    recordCollision(.attemptID)
                }
                if attempts.contains(where: {
                    $0.userMessageID == identity.userMessageID ||
                        $0.coachMessageID == identity.userMessageID
                }) {
                    recordCollision(.userMessageID)
                }
                if attempts.contains(where: {
                    $0.userMessageID == identity.coachMessageID ||
                        $0.coachMessageID == identity.coachMessageID
                }) {
                    recordCollision(.coachMessageID)
                }
                if attempts.contains(where: {
                    $0.freshDraftID == identity.freshDraftID
                }) {
                    recordCollision(.freshDraftID)
                }
                if record.invocation.draftID == identity.freshDraftID {
                    recordCollision(.freshDraftID)
                }
                if attempts.contains(where: {
                    $0.transportAuthority?.providerIdempotencyValue ==
                        identity.idempotencyValue
                }) {
                    recordCollision(.providerIdempotencyValue)
                }
                if !Set(attempts.compactMap(\.transportAuthority).flatMap(
                    \.transcriptHandles
                )).isDisjoint(with: identity.transcriptHandles) {
                    recordCollision(.transcriptHandle)
                }
            case let .frozen(common, _):
                if common.contains(identity.attemptID) {
                    recordCollision(.attemptID)
                }
                if common.contains(identity.userMessageID) {
                    recordCollision(.userMessageID)
                }
                if common.contains(identity.coachMessageID) {
                    recordCollision(.coachMessageID)
                }
                if common.contains(identity.freshDraftID) {
                    recordCollision(.freshDraftID)
                }
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
                    let publicIDs: PortableChatDurablePublicIDs
                    do {
                        publicIDs = try invocationEvidenceCodec
                            .decodeChatDurablePublicIDs(manifest)
                    } catch {
                        // A present but ambiguous root cannot prove the Library-wide
                        // public namespace free even when only this Chat is frozen.
                        throw PortableChatPersistenceError.ioFailure
                    }
                    if publicIDs.contains(identity.userMessageID) {
                        recordCollision(.userMessageID)
                    }
                    if publicIDs.contains(identity.coachMessageID) {
                        recordCollision(.coachMessageID)
                    }
                    if publicIDs.contains(identity.freshDraftID) {
                        recordCollision(.freshDraftID)
                    }
                } catch let error as PortableChatPersistenceError {
                    let manifestExists: Bool
                    do {
                        manifestExists = try entryExists(
                            named: "chat.json",
                            under: chatDescriptor
                        )
                    } catch {
                        throw PortableChatPersistenceError.ioFailure
                    }
                    if manifestExists {
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
            livenessLease: nil
        )
    }

    func installInvocation(
        _ mutation: InstallCoachInvocationMutation,
        at libraryRoot: URL,
        holding lease: PortableInvocationLivenessLease
    ) throws -> InvocationInstallOutcome {
        guard lease.authority(for: mutation.authority.request) != nil else {
            throw PortableChatPersistenceError.ioFailure
        }
        return try installInvocation(
            mutation,
            at: libraryRoot,
            livenessLease: lease
        )
    }

    private func installInvocation(
        _ mutation: InstallCoachInvocationMutation,
        at libraryRoot: URL,
        livenessLease: PortableInvocationLivenessLease?
    ) throws -> InvocationInstallOutcome {
        let livenessAuthority = livenessLease?.authority(
            for: mutation.authority.request
        )
        if livenessLease != nil, livenessAuthority == nil {
            throw PortableChatPersistenceError.ioFailure
        }
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
        guard installed.hasSameDurableProjection(as: mutation.invocation) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        _ = try installRetryProcessingTransition(
            mutation,
            current: current,
            under: chatDescriptor,
            holding: livenessLease,
            beforeCommitting: revalidateLiveness
        )
        return .installed(mutation.invocation)
    }

    func reconcileInstalledInvocation(
        _ mutation: InstallCoachInvocationMutation,
        at libraryRoot: URL
    ) throws -> CoachInvocation? {
        try reconcileInstalledInvocation(
            mutation,
            at: libraryRoot,
            livenessLease: nil
        )
    }

    func reconcileInstalledInvocation(
        _ mutation: InstallCoachInvocationMutation,
        at libraryRoot: URL,
        holding lease: PortableInvocationLivenessLease
    ) throws -> CoachInvocation? {
        guard lease.authority(for: mutation.authority.request) != nil else {
            throw PortableChatPersistenceError.ioFailure
        }
        return try reconcileInstalledInvocation(
            mutation,
            at: libraryRoot,
            livenessLease: lease
        )
    }

    private func reconcileInstalledInvocation(
        _ mutation: InstallCoachInvocationMutation,
        at libraryRoot: URL,
        livenessLease: PortableInvocationLivenessLease?
    ) throws -> CoachInvocation? {
        let scope = mutation.authority.request.library
        let livenessAuthority = livenessLease?.authority(
            for: mutation.authority.request
        )
        if livenessLease != nil, livenessAuthority == nil {
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
              current == mutation.authority.aggregate ||
              current == mutation.processingAggregate
        else { return nil }
        let invocation = try loadInvocationDirectoryRecord(
            expectedInvocationID: mutation.invocation.id,
            expectedLibraryID: scope.libraryID,
            under: invocationRoot,
            beforeRemoving: revalidateLiveness
        ).invocation
        guard invocation.hasSameDurableProjection(as: mutation.invocation),
              invocation.libraryID == scope.libraryID
        else { return nil }
        // A recovered rename proves that the generation marker exists, but
        // not that either directory entry survived a crash. Establish the
        // marker's complete durability boundary before clearing the visible
        // Retry failure or rebinding provider liveness to that Pending inode.
        try flushDescriptor(invocationRoot)
        try fault(.afterReconciledInvocationRootFlush)
        try flushDescriptor(invocationsDescriptor)
        try fault(.afterReconciledInvocationDirectoryFlush)
        _ = try installRetryProcessingTransition(
            mutation,
            current: current,
            under: chatDescriptor,
            holding: livenessLease,
            beforeCommitting: revalidateLiveness
        )
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
        let confirmed = try loadInvocationDirectoryRecord(
            expectedInvocationID: mutation.invocation.id,
            expectedLibraryID: scope.libraryID,
            under: invocationRoot,
            beforeRemoving: revalidateLiveness
        ).invocation
        return confirmed.hasSameDurableProjection(as: mutation.invocation)
            ? mutation.invocation
            : nil
    }

    /// Completes the second half of Retry admission after the Invocation root
    /// is durable. The Invocation is the generation marker: if any write below
    /// is uncertain, reconciliation may safely finish this exact transition,
    /// but provider authority is never returned while the prior failure is
    /// still visible.
    private func installRetryProcessingTransition(
        _ mutation: InstallCoachInvocationMutation,
        current: ChatAggregate,
        under chatDescriptor: Int32,
        holding lease: PortableInvocationLivenessLease?,
        beforeCommitting: () throws -> Void
    ) throws -> ChatAggregate {
        guard current == mutation.authority.aggregate ||
                current == mutation.processingAggregate,
              current.pendingUserTurn?.id == mutation.invocation.pendingUserTurnID
        else { throw PortableChatPersistenceError.invalidLayout }

        if current != mutation.processingAggregate {
            try fault(.beforeRetryProcessingPendingPartialWrite)
            let partialName = ".pending-user-turn.json.\(UUID().uuidString.lowercased()).partial"
            var partialExists = false
            defer {
                if partialExists {
                    _ = partialName.withCString {
                        Darwin.unlinkat(chatDescriptor, $0, 0)
                    }
                }
            }
            guard let processingPending = mutation.processingAggregate.pendingUserTurn else {
                throw PortableChatPersistenceError.invalidLayout
            }
            try writeExclusive(
                try encodePendingUserTurn(processingPending),
                named: partialName,
                under: chatDescriptor
            )
            partialExists = true
            try fault(.afterRetryProcessingPendingPartialWrite)
            let partialDescriptor = try openRegularFile(
                named: partialName,
                under: chatDescriptor
            )
            defer { Darwin.close(partialDescriptor) }
            try flushDescriptor(partialDescriptor)
            try fault(.afterRetryProcessingPendingFileFlush)
            try beforeCommitting()
            guard case let .readWrite(exactBase) = try loadChat(
                from: chatDescriptor,
                expectedID: mutation.authority.request.chatID,
                reconcileTransients: false
            ), exactBase == mutation.authority.aggregate,
                renameat(
                    chatDescriptor,
                    partialName,
                    chatDescriptor,
                    "pending-user-turn.json"
                ) == 0
            else { throw PortableChatPersistenceError.invalidLayout }
            partialExists = false
            try fault(.afterRetryProcessingPendingInstall)
        }
        // Observing the exact processing bytes proves the rename, not that its
        // directory entry survived a crash. Reconciliation must establish the
        // same durability checkpoint before rebinding live provider authority.
        try flushDescriptor(chatDescriptor)
        try fault(.afterRetryProcessingPendingDirectoryFlush)

        guard let processingPending = mutation.processingAggregate.pendingUserTurn else {
            throw PortableChatPersistenceError.invalidLayout
        }
        if let lease {
            let installedKey = try regularFileLivenessIdentity(
                named: "pending-user-turn.json",
                under: chatDescriptor
            )
            guard let currentAuthority = lease.authority(
                for: mutation.authority.request
            ) else { throw PortableChatPersistenceError.ioFailure }
            if currentAuthority.pendingUserTurn != installedKey {
                let replacementLease = try acquireAndValidatePendingUserTurnFileLease(
                    processingPending,
                    under: chatDescriptor
                )
                try lease.rebindPendingUserTurnLease(replacementLease)
            }
        }
        try fault(.afterRetryProcessingAuthorityRebind)
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.authority.request.chatID,
            reconcileTransients: false
        ), reopened == mutation.processingAggregate
        else { throw PortableChatPersistenceError.invalidLayout }
        return reopened
    }

    func installNextAttempt(
        _ mutation: InstallNextCoachProviderAttemptMutation,
        at libraryRoot: URL,
        in scope: LibraryScope,
        holding lease: PortableInvocationLivenessLease
    ) throws -> PortableNextAttemptInstallResult {
        let request = PendingCoachInvocationRequest(
            library: scope,
            chatID: mutation.base.chatID,
            pendingUserTurnID: mutation.base.pendingUserTurnID
        )
        guard mutation.base.libraryID == scope.libraryID,
              mutation.replacement.libraryID == scope.libraryID,
              mutation.replacement.id == mutation.base.id,
              let livenessAuthority = lease.authority(for: request)
        else { throw PortableChatPersistenceError.ioFailure }

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

        let invocationName = mutation.base.id.rawValue
        guard try entryExists(named: invocationName, under: invocationsDescriptor)
        else { return .stale(nil) }
        let invocationIdentity = try directoryIdentity(
            named: invocationName,
            under: invocationsDescriptor
        )
        let invocationRoot = try openDirectory(
            named: invocationName,
            under: invocationsDescriptor
        )
        defer { Darwin.close(invocationRoot) }
        guard try directoryIdentity(of: invocationRoot) == invocationIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let current = try loadInvocationDirectoryRecord(
            expectedInvocationID: mutation.base.id,
            expectedLibraryID: scope.libraryID,
            under: invocationRoot,
            reconcileProofPartial: true,
            beforeRemoving: revalidateLiveness
        )
        guard current.invocation.hasSameDurableProjection(as: mutation.base)
        else { return .stale(nil) }
        guard current.publicationProof == nil else {
            throw PortableChatPersistenceError.invalidLayout
        }
        if let collision = try nextAttemptIdentityCollision(
            mutation.replacement.attempt,
            activeChatID: mutation.base.chatID,
            expectedLibraryID: scope.libraryID,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor,
            beforeDestructiveMutation: revalidateLiveness
        ) {
            return .collision(collision)
        }

        try fault(.beforeNextAttemptPartialWrite)
        let partialName = ".invocation.json.\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString { Darwin.unlinkat(invocationRoot, $0, 0) }
            }
        }
        try writeExclusive(
            try encodeInvocation(mutation.replacement),
            named: partialName,
            under: invocationRoot
        )
        partialExists = true
        try fault(.afterNextAttemptPartialWrite)
        let partialDescriptor = try openRegularFile(
            named: partialName,
            under: invocationRoot
        )
        defer { Darwin.close(partialDescriptor) }
        try flushDescriptor(partialDescriptor)
        try fault(.afterNextAttemptFileFlush)
        try revalidateLiveness()
        guard try directoryIdentity(
            named: invocationName,
            under: invocationsDescriptor
        ) == invocationIdentity,
            try directoryIdentity(of: invocationRoot) == invocationIdentity
        else { throw PortableChatPersistenceError.invalidLayout }
        let exactBase = try loadInvocationDirectoryRecord(
            expectedInvocationID: mutation.base.id,
            expectedLibraryID: scope.libraryID,
            under: invocationRoot,
            reconcileProofPartial: false
        )
        guard exactBase.invocation.hasSameDurableProjection(as: mutation.base)
        else { return .stale(nil) }
        guard exactBase.publicationProof == nil,
              isRegularFile(named: "invocation.json", under: invocationRoot),
              renameat(
                  invocationRoot,
                  partialName,
                  invocationRoot,
                  "invocation.json"
              ) == 0
        else { throw PortableChatPersistenceError.ioFailure }
        partialExists = false
        try fault(.afterNextAttemptInstall)
        try flushDescriptor(invocationRoot)
        try fault(.afterNextAttemptDirectoryFlush)
        let installed = try decodeInvocation(
            boundedData(named: "invocation.json", under: invocationRoot)
        )
        guard installed.hasSameDurableProjection(as: mutation.replacement) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        // The durable reread proves the safe projection committed. Only this
        // mutation-held capability may reattach the process-live transport
        // authority; no provider authority is ever reconstructed from disk.
        return .installed(mutation.replacement)
    }

    func reconcileInstalledNextAttempt(
        _ mutation: InstallNextCoachProviderAttemptMutation,
        at libraryRoot: URL,
        in scope: LibraryScope,
        holding lease: PortableInvocationLivenessLease
    ) throws -> CoachInvocation? {
        let request = PendingCoachInvocationRequest(
            library: scope,
            chatID: mutation.base.chatID,
            pendingUserTurnID: mutation.base.pendingUserTurnID
        )
        guard let livenessAuthority = lease.authority(for: request) else {
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
            livenessAuthority,
            at: libraryRoot,
            in: scope,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
        try revalidateLiveness()
        guard try entryExists(
            named: mutation.base.id.rawValue,
            under: invocationsDescriptor
        ) else { return nil }
        let invocationRoot = try openDirectory(
            named: mutation.base.id.rawValue,
            under: invocationsDescriptor
        )
        defer { Darwin.close(invocationRoot) }
        let record = try loadInvocationDirectoryRecord(
            expectedInvocationID: mutation.base.id,
            expectedLibraryID: scope.libraryID,
            under: invocationRoot,
            reconcileProofPartial: true,
            beforeRemoving: revalidateLiveness
        )
        guard record.publicationProof == nil else { return nil }
        if record.invocation.hasSameDurableProjection(as: mutation.replacement) {
            try flushDescriptor(invocationRoot)
            try flushDescriptor(invocationsDescriptor)
            try revalidateLiveness()
            return mutation.replacement
        }
        guard record.invocation.hasSameDurableProjection(as: mutation.base) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return nil
    }

    private func nextAttemptIdentityCollision(
        _ candidate: CoachProviderAttempt,
        activeChatID: ChatID,
        expectedLibraryID: LibraryID,
        under rootDescriptor: Int32,
        invocationsDescriptor: Int32,
        beforeDestructiveMutation: () throws -> Void
    ) throws -> InvocationLaunchIdentityCollision? {
        guard let authority = candidate.publicationAuthority else {
            throw PortableChatPersistenceError.invalidLayout
        }
        guard candidate.transportAuthority != nil else {
            throw PortableChatPersistenceError.invalidLayout
        }
        for invocationName in try invocationDirectoryNamesRemovingEmptyResidue(
            under: invocationsDescriptor,
            beforeRemoving: beforeDestructiveMutation
        ) {
            let inspection = try inspectInvocationDirectory(
                named: invocationName,
                expectedLibraryID: expectedLibraryID,
                under: invocationsDescriptor,
                reconcileProofPartial: false
            )
            switch inspection {
            case let .available(record):
                for attempt in record.invocation.attempts {
                    if attempt.id == candidate.id { return .attemptID }
                    if attempt.userMessageID == authority.userMessageID ||
                        attempt.coachMessageID == authority.userMessageID
                    { return .userMessageID }
                    if attempt.userMessageID == authority.coachMessageID ||
                        attempt.coachMessageID == authority.coachMessageID
                    { return .coachMessageID }
                    if attempt.freshDraftID == authority.freshDraftID {
                        return .freshDraftID
                    }
                }
                if record.invocation.draftID == authority.freshDraftID {
                    return .freshDraftID
                }
            case let .frozen(common, _):
                if common.contains(candidate.id) {
                    return .attemptID
                }
                if common.contains(authority.userMessageID) {
                    return .userMessageID
                }
                if common.contains(authority.coachMessageID) {
                    return .coachMessageID
                }
                if common.contains(authority.freshDraftID) {
                    return .freshDraftID
                }
            }
        }

        let chatsDescriptor = try openDirectory(named: "chats", under: rootDescriptor)
        defer { Darwin.close(chatsDescriptor) }
        for chatName in try listEntryNames(
            under: chatsDescriptor,
            maximumCount: Self.maximumChatCatalogEntries
        ) {
            guard let chatID = try? ChatID(chatName) else { continue }
            let chatDescriptor: Int32
            do {
                chatDescriptor = try openDirectory(named: chatName, under: chatsDescriptor)
            } catch let error as PortableChatPersistenceError {
                if chatID == activeChatID { throw error }
                if error == .invalidLayout,
                   (try? directoryIdentity(named: chatName, under: chatsDescriptor)) != nil
                {
                    throw PortableChatPersistenceError.ioFailure
                }
                guard frozenChatSnapshot(for: error, chatID: chatID) != nil else {
                    throw error
                }
                continue
            }
            defer { Darwin.close(chatDescriptor) }
            do {
                let messagesDescriptor = try openDirectory(
                    named: "messages",
                    under: chatDescriptor
                )
                defer { Darwin.close(messagesDescriptor) }
                if try entryExists(
                    named: "\(authority.userMessageID.rawValue).json",
                    under: messagesDescriptor
                ) { return .userMessageID }
                if try entryExists(
                    named: "\(authority.coachMessageID.rawValue).json",
                    under: messagesDescriptor
                ) { return .coachMessageID }
            } catch let error as PortableChatPersistenceError {
                if chatID == activeChatID { throw error }
                if error == .invalidLayout,
                   (try? directoryIdentity(named: "messages", under: chatDescriptor)) != nil
                {
                    throw PortableChatPersistenceError.ioFailure
                }
                guard frozenChatSnapshot(for: error, chatID: chatID) != nil else {
                    throw error
                }
            }
            do {
                let manifest = try boundedData(named: "chat.json", under: chatDescriptor)
                let publicIDs: PortableChatDurablePublicIDs
                do {
                    publicIDs = try invocationEvidenceCodec
                        .decodeChatDurablePublicIDs(manifest)
                } catch {
                    throw PortableChatPersistenceError.ioFailure
                }
                if publicIDs.contains(authority.userMessageID) {
                    return .userMessageID
                }
                if publicIDs.contains(authority.coachMessageID) {
                    return .coachMessageID
                }
                if publicIDs.contains(authority.freshDraftID) {
                    return .freshDraftID
                }
            } catch let error as PortableChatPersistenceError {
                if chatID == activeChatID { throw error }
                let manifestExists: Bool
                do {
                    manifestExists = try entryExists(
                        named: "chat.json",
                        under: chatDescriptor
                    )
                } catch {
                    throw PortableChatPersistenceError.ioFailure
                }
                if manifestExists {
                    throw PortableChatPersistenceError.ioFailure
                }
                guard frozenChatSnapshot(for: error, chatID: chatID) != nil else {
                    throw error
                }
            }
        }
        return nil
    }

    func abortInstalledNewSend(
        _ invocation: CoachInvocation,
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> PortableChatMutationResult {
        try abortInstalledNewSend(
            invocation,
            failure: .coachResponseInterrupted,
            at: libraryRoot,
            in: scope,
            livenessAuthority: nil
        )
    }

    func abortInstalledNewSend(
        _ invocation: CoachInvocation,
        failure: PendingUserTurnFailure = .coachResponseInterrupted,
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
            failure: failure,
            at: libraryRoot,
            in: scope,
            livenessAuthority: authority
        )
    }

    private func abortInstalledNewSend(
        _ invocation: CoachInvocation,
        failure: PendingUserTurnFailure,
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
        let record = try loadInvocationDirectoryRecord(
            expectedInvocationID: invocation.id,
            expectedLibraryID: scope.libraryID,
            under: invocationRoot,
            beforeRemoving: revalidateLiveness
        )
        guard record.invocation.hasSameDurableProjection(as: invocation) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let terminalInvocation = try installInvocationTerminalIntent(
            base: invocation,
            failure: failure,
            under: invocationRoot,
            beforeCommitting: revalidateLiveness
        )
        let publicationAuthority = record.publicationProof.map {
            InvocationPublicationProofAuthority(invocation: terminalInvocation, proof: $0)
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
            publicationProofAuthority: publicationAuthority,
            beforeDestructiveMutation: revalidateLiveness
        ) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        guard (try? terminalInvocation.validateIntent(against: current)) != nil else {
            if current.pendingUserTurn == nil {
                let pendingData = try entryExists(
                    named: "pending-user-turn.json",
                    under: chatDescriptor
                ) ? boundedData(
                    named: "pending-user-turn.json",
                    under: chatDescriptor
                ) : nil
                if let proof = record.publicationProof {
                    guard try isExactPublishedInvocation(
                        proof,
                        invocation: terminalInvocation,
                        aggregate: current,
                        pendingData: pendingData,
                        under: chatDescriptor
                    ) else { throw PortableChatPersistenceError.invalidLayout }
                } else {
                    guard isProvablyPrePublication(invocation, current: current) else {
                        throw PortableChatPersistenceError.invalidLayout
                    }
                }
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
            try removeInvocationDirectoryIfPresent(
                terminalInvocation,
                under: invocationsDescriptor,
                beforeRemoving: revalidateLiveness
            )
            return .stale(current)
        }
        if record.publicationProof != nil {
            try removePublicationProofIfPresent(
                from: invocationRoot,
                beforeRemoving: revalidateLiveness
            )
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
                terminalInvocation,
                failure: failure,
                current: current,
                invocationRoot: invocationRoot,
                invocationsDescriptor: invocationsDescriptor,
                chatDescriptor: chatDescriptor,
                beforeCommitting: revalidateLiveness
            )
        )
    }

    private func installInvocationTerminalIntent(
        base: CoachInvocation,
        failure: PendingUserTurnFailure,
        under invocationRoot: Int32,
        beforeCommitting: () throws -> Void
    ) throws -> CoachInvocation {
        let replacement = try base.recordingTerminalFailure(failure)
        if replacement == base { return base }
        try fault(.beforeInvocationTerminalIntentPartialWrite)
        let partialName = ".invocation.json.\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString { Darwin.unlinkat(invocationRoot, $0, 0) }
            }
        }
        try writeExclusive(
            try encodeInvocation(replacement),
            named: partialName,
            under: invocationRoot
        )
        partialExists = true
        try fault(.afterInvocationTerminalIntentPartialWrite)
        let partialDescriptor = try openRegularFile(
            named: partialName,
            under: invocationRoot
        )
        defer { Darwin.close(partialDescriptor) }
        try flushDescriptor(partialDescriptor)
        try fault(.afterInvocationTerminalIntentFileFlush)
        try beforeCommitting()
        guard try decodeInvocation(
            boundedData(named: "invocation.json", under: invocationRoot)
        ).hasSameDurableProjection(as: base),
            renameat(
                invocationRoot,
                partialName,
                invocationRoot,
                "invocation.json"
            ) == 0
        else { throw PortableChatPersistenceError.ioFailure }
        partialExists = false
        try fault(.afterInvocationTerminalIntentInstall)
        try flushDescriptor(invocationRoot)
        try fault(.afterInvocationTerminalIntentDirectoryFlush)
        let installed = try decodeInvocation(
            boundedData(named: "invocation.json", under: invocationRoot)
        )
        guard installed.hasSameDurableProjection(as: replacement) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return installed
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

    func publishInvocation(
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
        let proof = try publicationProof(for: mutation)
        let installedRecord = try loadInvocationDirectoryRecordIfPresent(
            mutation.invocation,
            under: invocationsDescriptor
        )
        let installedProofAuthority: InvocationPublicationProofAuthority? =
            if installedRecord?.invocation.hasSameDurableProjection(
                as: mutation.invocation
            ) == true,
               installedRecord?.publicationProof == proof
            {
                InvocationPublicationProofAuthority(
                    invocation: mutation.invocation,
                    proof: proof
                )
            } else {
                nil
            }
        guard case let .readWrite(current) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.invocation.chatID,
            reconcileTransients: true,
            publicationProofAuthority: installedProofAuthority,
            beforeDestructiveMutation: revalidateLiveness
        ) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        if current == mutation.replacement {
            if let installedRecord {
                guard installedRecord.invocation.hasSameDurableProjection(
                    as: mutation.invocation
                ),
                      installedRecord.publicationProof == proof
                else { return .stale(current) }
            }
            guard try isExactPublishedInvocation(
                proof,
                invocation: mutation.invocation,
                aggregate: current,
                pendingData: nil,
                under: chatDescriptor
            ) else { return .stale(current) }
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
        let invocationRecord = try loadInvocationDirectoryRecord(
            expectedInvocationID: mutation.invocation.id,
            expectedLibraryID: scope.libraryID,
            under: invocationRoot,
            beforeRemoving: revalidateLiveness
        )
        guard invocationRecord.invocation.hasSameDurableProjection(
            as: mutation.invocation
        ),
              (invocationRecord.publicationProof == nil ||
                  invocationRecord.publicationProof == proof)
        else { return .stale(current) }
        try installPublicationProof(proof, under: invocationRoot)

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

    func reconcileCommittedInvocationPublication(
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

    func reconcileCommittedInvocationPublicationIfUnowned(
        _ mutation: PublishCoachInvocationMutation,
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> PortableInvocationPublicationRecoveryResult {
        guard let lease = try acquireInvocationRecoveryLease(
            at: libraryRoot,
            in: scope
        ) else { return .owned }
        defer { lease.release() }
        guard let authority = lease.authority() else {
            throw PortableChatPersistenceError.ioFailure
        }
        if let aggregate = try reconcileCommittedInvocationPublication(
            mutation,
            at: libraryRoot,
            in: scope,
            livenessAuthority: authority
        ) {
            return .published(aggregate)
        }
        return .notPublished
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
        let proof = try publicationProof(for: mutation)
        if let installed = try loadInvocationDirectoryRecordIfPresent(
            mutation.invocation,
            under: invocationsDescriptor
        ) {
            guard installed.invocation.hasSameDurableProjection(
                as: mutation.invocation
            ),
                  installed.publicationProof == proof
            else { throw PortableChatPersistenceError.invalidLayout }
        }
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              try directoryIdentity(of: chatDescriptor) == chatIdentity,
              case let .readWrite(aggregate) = try loadChat(
                  from: chatDescriptor,
                  expectedID: mutation.invocation.chatID,
                  reconcileTransients: true,
                  publicationProofAuthority: InvocationPublicationProofAuthority(
                      invocation: mutation.invocation,
                      proof: proof
                  ),
                  beforeDestructiveMutation: revalidateLiveness
              ),
              try isExactPublishedInvocation(
                  proof,
                  invocation: mutation.invocation,
                  aggregate: aggregate,
                  pendingData: nil,
                  under: chatDescriptor
              )
        else { return nil }
        try removeInvocationDirectoryIfPresent(
            mutation.invocation,
            under: invocationsDescriptor,
            beforeRemoving: revalidateLiveness
        )
        return aggregate
    }

    /// One exact publication prover is shared by mutation-owned immediate
    /// recovery and marker-owned relaunch recovery. It permits only ordinary
    /// title and fresh-Draft evolution after the committed manifest revision.
    private func isExactPublishedInvocation(
        _ proof: InvocationPublicationProof,
        invocation: CoachInvocation,
        aggregate: ChatAggregate,
        pendingData: Data?,
        under chatDescriptor: Int32
    ) throws -> Bool {
        let messagesDescriptor = try openDirectory(
            named: "messages",
            under: chatDescriptor
        )
        defer { Darwin.close(messagesDescriptor) }
        let userData = try boundedData(
            named: "\(proof.userMessageID.rawValue).json",
            under: messagesDescriptor
        )
        let coachData = try boundedData(
            named: "\(proof.coachMessageID.rawValue).json",
            under: messagesDescriptor
        )
        let user = try decodeMessage(userData)
        let coach = try decodeMessage(coachData)
        return invocationEvidenceCodec.isExactPublishedInvocation(
            proof,
            invocation: invocation,
            evidence: PortableInvocationPublicationCurrentEvidence(
                aggregate: aggregate,
                canonicalChat: try encodeChat(aggregate.chat),
                stableChat: try encodeStableChat(aggregate.chat),
                memory: try encodeMemory(aggregate.memory),
                freshDraft: try encodeDraft(aggregate.chat.draft),
                pendingUserTurnData: pendingData,
                pendingUserTurn: pendingData.flatMap {
                    try? decodePendingUserTurn($0)
                },
                userMessageData: userData,
                userMessage: user,
                coachMessageData: coachData,
                coachMessage: coach
            )
        )
    }

    func reconcileCommittedCreate(
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

    func reconcileCommittedRename(
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

    func reconcileCommittedDraft(
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

    func reconcileCommittedPendingLock(
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

    func reconcileCommittedPendingReplacement(
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

    func reconcileCommittedPendingReplacement(
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

    func reconcileCommittedPendingDiscard(
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

    func reconcileCommittedPendingDiscard(
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
        try invocationEvidenceCodec.encodeInvocation(invocation)
    }

    private func publicationProof(
        for mutation: PublishCoachInvocationMutation
    ) throws -> InvocationPublicationProof {
        guard let pending = mutation.base.pendingUserTurn else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let published = mutation.replacement
        return try invocationEvidenceCodec.makePublicationProof(
            for: mutation,
            evidence: PortableInvocationPublicationSourceEvidence(
                publishedChat: try encodeChat(published.chat),
                stableChat: try encodeStableChat(published.chat),
                memory: try encodeMemory(published.memory),
                pendingUserTurn: try encodePendingUserTurn(pending),
                userMessage: try encodeMessage(mutation.userMessage),
                coachMessage: try encodeMessage(mutation.coachMessage),
                freshDraft: try encodeDraft(mutation.freshDraft)
            )
        )
    }

    private func encodePublicationProof(
        _ proof: InvocationPublicationProof
    ) throws -> Data {
        try invocationEvidenceCodec.encodePublicationProof(proof)
    }

    private func decodePublicationProof(_ data: Data) throws -> InvocationPublicationProof {
        try invocationEvidenceCodec.decodePublicationProof(data)
    }

    private func encodeStableChat(_ chat: Chat) throws -> Data {
        try deterministicJSON(
            InvocationStableChatDTO(
                chatId: chat.id.rawValue,
                createdAt: chat.createdAt.rawValue,
                creationKind: chat.creation.kind.rawValue,
                originAttachmentId: chat.creation.originAttachmentID?.rawValue,
                profileStatementGenerationAtCreation:
                    chat.profileStatementGenerationAtCreation,
                attachments: chat.attachments.values.map {
                    ChatAttachmentDTO(
                        attachmentId: $0.attachmentID.rawValue,
                        sessionId: $0.sessionID.rawValue,
                        transcriptRevisionId: $0.transcriptRevisionID.rawValue
                    )
                },
                messageIds: chat.messageIDs.map(\.rawValue),
                currentMemoryId: chat.currentMemoryID.rawValue
            )
        )
    }

    private func encodeDraft(_ draft: ChatDraft) throws -> Data {
        try deterministicJSON(
            ChatDraftDTO(
                draftId: draft.draftID.rawValue,
                version: draft.version,
                text: draft.text,
                updatedAt: draft.updatedAt.rawValue
            )
        )
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
        publicationProofAuthority: InvocationPublicationProofAuthority? = nil,
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
        let decodedPendingData: Data?
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
                pendingVersion == 2 ||
                pendingVersion == UInt64(PendingUserTurn.schemaVersion)
            else {
                throw PortableChatPersistenceError.unsupportedOlderSchema
            }
            decodedPendingUserTurn = try mapPersistedDomainValidation {
                try decodePendingUserTurn(pendingData)
            }
            decodedPendingData = pendingData
        } else {
            decodedPendingUserTurn = nil
            decodedPendingData = nil
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
        } else if decodedPendingUserTurn != nil {
            guard publicationProofAuthority != nil else {
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
        if removesStalePending {
            guard let publicationProofAuthority,
                  try isExactPublishedInvocation(
                      publicationProofAuthority.proof,
                      invocation: publicationProofAuthority.invocation,
                      aggregate: aggregate,
                      pendingData: decodedPendingData,
                      under: chatDescriptor
                  )
            else {
                throw PortableChatPersistenceError.invalidLayout
            }
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
        publicationProofAuthority: InvocationPublicationProofAuthority? = nil,
        beforeDestructiveMutation: () throws -> Void = {}
    ) throws -> LoadedPortableChat {
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        return try loadChat(
            from: chatDescriptor,
            expectedID: expectedID,
            reconcileTransients: true,
            publicationProofAuthority: publicationProofAuthority,
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
        let terminalFailure = invocation.terminalFailure ?? .coachResponseInterrupted
        let terminal = pending.replacingFailure(terminalFailure)
        if terminal != pending {
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
                try encodePendingUserTurn(terminal),
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
        failure: PendingUserTurnFailure = .coachResponseInterrupted,
        current: ChatAggregate,
        invocationRoot: Int32,
        invocationsDescriptor: Int32,
        chatDescriptor: Int32,
        beforeCommitting: () throws -> Void = {}
    ) throws -> ChatAggregate {
        guard let pending = current.pendingUserTurn else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let terminalFailure = invocation.terminalFailure ?? failure
        if pending.failure != terminalFailure {
            let replacement = pending.replacingFailure(terminalFailure)
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
                try encodePendingUserTurn(replacement),
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
            try beforeCommitting()
            guard renameat(
                chatDescriptor,
                partialName,
                chatDescriptor,
                "pending-user-turn.json"
            ) == 0 else { throw PortableChatPersistenceError.ioFailure }
            partialExists = false
            try flushDescriptor(chatDescriptor)
            try fault(.afterInvocationAbortPendingFailureInstall)
        }
        try beforeCommitting()
        guard (try? invocation.validateIntent(against: current)) != nil,
              try listEntryNames(under: invocationRoot, maximumCount: 4) ==
              ["invocation.json"],
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
        ),
            reopened == (try ChatAggregate(
                chat: current.chat,
                memory: current.memory,
                pendingUserTurn: pending.replacingFailure(terminalFailure)
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
            let entries = try listEntryNames(under: descriptor, maximumCount: 4)
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

    private func loadInvocationDirectoryRecord(
        expectedInvocationID: CoachInvocationID,
        expectedLibraryID: LibraryID,
        under invocationRoot: Int32,
        validatedBody: InvocationBodyIdentity? = nil,
        reconcileProofPartial: Bool = true,
        beforeRemoving: () throws -> Void = {}
    ) throws -> InvocationDirectoryRecord {
        var entries = try listEntryNames(under: invocationRoot, maximumCount: 4)
        let proofPartials = entries.filter(Self.isPublicationProofPartialName)
        let attemptPartials = entries.filter(Self.isAttemptReplacementPartialName)
        guard proofPartials.count <= 1,
              attemptPartials.count <= 1,
              entries.count <= 4,
              Set(entries).isSubset(of: Set([
                  "invocation.json",
                  "publication-proof.json",
              ] + proofPartials + attemptPartials))
        else { throw PortableChatPersistenceError.invalidLayout }
        for partial in proofPartials + attemptPartials {
            guard isRegularFile(named: partial, under: invocationRoot) else {
                throw PortableChatPersistenceError.invalidLayout
            }
            if reconcileProofPartial {
                try beforeRemoving()
                guard unlinkat(invocationRoot, partial, 0) == 0 else {
                    throw PortableChatPersistenceError.invalidLayout
                }
                try flushDescriptor(invocationRoot)
            }
            entries.removeAll { $0 == partial }
        }
        guard entries.contains("invocation.json"),
              isRegularFile(named: "invocation.json", under: invocationRoot)
        else { throw PortableChatPersistenceError.invalidLayout }
        let body = try validatedBody ?? loadInvocationBodyIdentity(
            expectedInvocationID: expectedInvocationID,
            expectedLibraryID: expectedLibraryID,
            under: invocationRoot
        )
        guard body.common.invocationID == expectedInvocationID,
              body.common.libraryID == expectedLibraryID
        else { throw PortableChatPersistenceError.invalidLayout }
        let invocation = body.invocation
        let proof: InvocationPublicationProof?
        if entries.contains("publication-proof.json") {
            guard isRegularFile(named: "publication-proof.json", under: invocationRoot) else {
                throw PortableChatPersistenceError.invalidLayout
            }
            let decoded = try decodePublicationProof(
                boundedData(named: "publication-proof.json", under: invocationRoot)
            )
            guard invocationEvidenceCodec.proof(
                decoded,
                isBoundTo: invocation
            ) else {
                throw PortableChatPersistenceError.invalidLayout
            }
            proof = decoded
        } else {
            proof = nil
        }
        return InvocationDirectoryRecord(
            invocation: invocation,
            publicationProof: proof
        )
    }

    private func loadInvocationDirectoryRecordIfPresent(
        _ invocation: CoachInvocation,
        under invocationsDescriptor: Int32,
        reconcileProofPartial: Bool = false,
        beforeRemoving: () throws -> Void = {}
    ) throws -> InvocationDirectoryRecord? {
        let name = invocation.id.rawValue
        guard try entryExists(named: name, under: invocationsDescriptor) else {
            return nil
        }
        let invocationRoot = try openDirectory(named: name, under: invocationsDescriptor)
        defer { Darwin.close(invocationRoot) }
        return try loadInvocationDirectoryRecord(
            expectedInvocationID: invocation.id,
            expectedLibraryID: invocation.libraryID,
            under: invocationRoot,
            reconcileProofPartial: reconcileProofPartial,
            beforeRemoving: beforeRemoving
        )
    }

    /// Reads the immutable common identity before any version-specific body.
    /// Transient I/O and an unreadable or ambiguous identity remain
    /// Library-level failures because no trustworthy Chat exists to freeze.
    private func loadInvocationCommonIdentity(
        expectedInvocationID: CoachInvocationID,
        expectedLibraryID: LibraryID,
        under invocationRoot: Int32
    ) throws -> PortableInvocationCommonIdentityEnvelope {
        guard isRegularFile(named: "invocation.json", under: invocationRoot) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try fault(.beforeInvocationIdentityRead)
        return try invocationEvidenceCodec.decodeCommonInvocationIdentity(
            boundedData(named: "invocation.json", under: invocationRoot),
            expectedInvocationID: expectedInvocationID,
            expectedLibraryID: expectedLibraryID
        )
    }

    private func loadInvocationBodyIdentity(
        expectedInvocationID: CoachInvocationID,
        expectedLibraryID: LibraryID,
        under invocationRoot: Int32
    ) throws -> InvocationBodyIdentity {
        let common = try loadInvocationCommonIdentity(
            expectedInvocationID: expectedInvocationID,
            expectedLibraryID: expectedLibraryID,
            under: invocationRoot
        )
        return InvocationBodyIdentity(
            common: common,
            invocation: try invocationEvidenceCodec.decodeSupportedInvocation(common)
        )
    }

    private func inspectInvocationBody(
        named name: String,
        expectedLibraryID: LibraryID,
        under invocationsDescriptor: Int32
    ) throws -> InvocationBodyInspection {
        guard let invocationID = try? CoachInvocationID(name) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let invocationRoot = try openDirectory(
            named: name,
            under: invocationsDescriptor
        )
        defer { Darwin.close(invocationRoot) }
        return try inspectInvocationBody(
            expectedInvocationID: invocationID,
            expectedLibraryID: expectedLibraryID,
            under: invocationRoot
        )
    }

    private func inspectInvocationBody(
        expectedInvocationID: CoachInvocationID,
        expectedLibraryID: LibraryID,
        under invocationRoot: Int32
    ) throws -> InvocationBodyInspection {
        let common = try loadInvocationCommonIdentity(
            expectedInvocationID: expectedInvocationID,
            expectedLibraryID: expectedLibraryID,
            under: invocationRoot
        )
        guard common.hasSupportedBody else {
            return .frozen(
                common,
                FrozenChatSnapshot(chatID: common.chatID, reason: .newerSchema)
            )
        }
        do {
            return .available(InvocationBodyIdentity(
                common: common,
                invocation: try invocationEvidenceCodec.decodeSupportedInvocation(common)
            ))
        } catch let error as PortableChatPersistenceError {
            guard let snapshot = frozenChatSnapshot(
                for: error,
                chatID: common.chatID
            ) else { throw error }
            return .frozen(common, snapshot)
        }
    }

    private func inspectInvocationDirectory(
        named name: String,
        expectedLibraryID: LibraryID,
        under invocationsDescriptor: Int32,
        reconcileProofPartial: Bool,
        beforeRemoving: () throws -> Void = {}
    ) throws -> InvocationDirectoryInspection {
        guard let invocationID = try? CoachInvocationID(name) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let invocationRoot = try openDirectory(
            named: name,
            under: invocationsDescriptor
        )
        defer { Darwin.close(invocationRoot) }
        let body = try inspectInvocationBody(
            expectedInvocationID: invocationID,
            expectedLibraryID: expectedLibraryID,
            under: invocationRoot
        )
        guard case let .available(validatedBody) = body else {
            if case let .frozen(common, snapshot) = body {
                return .frozen(common, snapshot)
            }
            throw PortableChatPersistenceError.invalidLayout
        }
        do {
            return .available(try loadInvocationDirectoryRecord(
                expectedInvocationID: validatedBody.invocation.id,
                expectedLibraryID: expectedLibraryID,
                under: invocationRoot,
                validatedBody: validatedBody,
                reconcileProofPartial: reconcileProofPartial,
                beforeRemoving: beforeRemoving
            ))
        } catch let error as PortableChatPersistenceError {
            guard let snapshot = frozenChatSnapshot(
                for: error,
                chatID: validatedBody.invocation.chatID
            ) else { throw error }
            return .frozen(validatedBody.common, snapshot)
        }
    }

    private func isProvablyPrePublication(
        _ invocation: CoachInvocation,
        current: ChatAggregate
    ) -> Bool {
        current.chat.id == invocation.chatID &&
            current.chat.manifestRevision == invocation.expectedManifestRevision
    }

    private func publicationProofLookup(
        expectedLibraryID: LibraryID,
        under rootDescriptor: Int32
    ) throws -> InvocationPublicationProofLookup {
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        let names = try listEntryNames(
            under: invocationsDescriptor,
            maximumCount: Self.maximumInvocationDirectoryEntries
        ).filter { $0 != ".DS_Store" && !Self.isInvocationPartialName($0) }
        var authorities: [ChatID: InvocationPublicationProofAuthority] = [:]
        var frozenSnapshots: [ChatID: FrozenChatSnapshot] = [:]
        var inspections: [InvocationDirectoryInspection] = []
        for name in names.sorted() {
            let isEmpty: Bool = try {
                let invocationRoot = try openDirectory(
                    named: name,
                    under: invocationsDescriptor
                )
                defer { Darwin.close(invocationRoot) }
                return try listEntryNames(
                    under: invocationRoot,
                    maximumCount: 4
                ).isEmpty
            }()
            if isEmpty { continue }
            inspections.append(try inspectInvocationDirectory(
                named: name,
                expectedLibraryID: expectedLibraryID,
                under: invocationsDescriptor,
                reconcileProofPartial: false
            ))
        }
        for inspection in inspections {
            if case let .frozen(_, snapshot) = inspection {
                coalesceFrozenChatSnapshot(snapshot, into: &frozenSnapshots)
            }
        }
        var availableCount = 0
        for inspection in inspections {
            switch inspection {
            case let .available(record):
                guard frozenSnapshots[record.invocation.chatID] == nil else {
                    continue
                }
                availableCount += 1
                guard availableCount == 1 else {
                    throw PortableChatPersistenceError.invalidLayout
                }
                if let proof = record.publicationProof {
                    guard authorities[record.invocation.chatID] == nil else {
                        throw PortableChatPersistenceError.invalidLayout
                    }
                    authorities[record.invocation.chatID] =
                        InvocationPublicationProofAuthority(
                            invocation: record.invocation,
                            proof: proof
                        )
                }
            case .frozen:
                continue
            }
        }
        return InvocationPublicationProofLookup(
            authorities: authorities,
            frozenSnapshots: frozenSnapshots
        )
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
        let names = try invocationDirectoryNamesRemovingEmptyResidue(
            under: invocationsDescriptor,
            beforeRemoving: beforeDestructiveMutation
        )
        var activeCount = 0
        var frozenChatIDs: Set<ChatID> = []
        let inspections = try names.sorted().map { name in
            try inspectInvocationDirectory(
                named: name,
                expectedLibraryID: expectedLibraryID,
                under: invocationsDescriptor,
                reconcileProofPartial: false
            )
        }
        for inspection in inspections {
            if case let .frozen(common, _) = inspection {
                frozenChatIDs.insert(common.chatID)
            }
        }
        for inspection in inspections {
            guard case let .available(record) = inspection,
                  !frozenChatIDs.contains(record.invocation.chatID)
            else { continue }
            do {
                if try invocationIsActive(
                    record,
                    under: invocationsDescriptor,
                    chatsDescriptor: chatsDescriptor,
                    beforeDestructiveMutation: beforeDestructiveMutation
                ) {
                    activeCount += 1
                    guard activeCount == 1 else {
                        throw PortableChatPersistenceError.invalidLayout
                    }
                }
            } catch let error as PortableChatPersistenceError {
                guard frozenChatSnapshot(
                    for: error,
                    chatID: record.invocation.chatID
                ) != nil else { throw error }
                frozenChatIDs.insert(record.invocation.chatID)
            }
        }
        return activeCount == 1
    }

    private func invocationIsActive(
        _ record: InvocationDirectoryRecord,
        under invocationsDescriptor: Int32,
        chatsDescriptor: Int32,
        beforeDestructiveMutation: () throws -> Void
    ) throws -> Bool {
        let invocation = record.invocation
        let publicationAuthority = record.publicationProof.map {
            InvocationPublicationProofAuthority(invocation: invocation, proof: $0)
        }
        guard try entryExists(named: invocation.chatID.rawValue, under: chatsDescriptor)
        else {
            guard record.publicationProof == nil else {
                throw PortableChatPersistenceError.invalidLayout
            }
            try removeInvocationDirectoryIfPresent(
                invocation,
                under: invocationsDescriptor,
                beforeRemoving: beforeDestructiveMutation
            )
            return false
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
            publicationProofAuthority: publicationAuthority,
            beforeDestructiveMutation: beforeDestructiveMutation
        ) else { throw PortableChatPersistenceError.invalidLayout }
        if (try? invocation.validateIntent(against: aggregate)) != nil {
            return true
        }
        let pendingData = try entryExists(
            named: "pending-user-turn.json",
            under: chatDescriptor
        ) ? boundedData(named: "pending-user-turn.json", under: chatDescriptor) : nil
        if let proof = record.publicationProof,
           try isExactPublishedInvocation(
               proof,
               invocation: invocation,
               aggregate: aggregate,
               pendingData: pendingData,
               under: chatDescriptor
           )
        {
            try removeInvocationDirectoryIfPresent(
                invocation,
                under: invocationsDescriptor,
                beforeRemoving: beforeDestructiveMutation
            )
            return false
        }
        guard record.publicationProof == nil,
              aggregate.pendingUserTurn != nil ||
              isProvablyPrePublication(invocation, current: aggregate)
        else { throw PortableChatPersistenceError.invalidLayout }
        // A changed Chat can no longer publish through this authority. Retiring
        // the stale root cannot touch a frozen sibling's independent evidence.
        try removeInvocationDirectoryIfPresent(
            invocation,
            under: invocationsDescriptor,
            beforeRemoving: beforeDestructiveMutation
        )
        return false
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
        let record = try loadInvocationDirectoryRecord(
            expectedInvocationID: invocation.id,
            expectedLibraryID: invocation.libraryID,
            under: descriptor,
            beforeRemoving: beforeRemoving
        )
        guard record.invocation.hasSameDurableProjection(as: invocation)
        else { throw PortableChatPersistenceError.invalidLayout }
        try removePublicationProofIfPresent(
            from: descriptor,
            beforeRemoving: beforeRemoving
        )
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

    private func discardPrePublicationEvidence(
        from invocationRoot: Int32,
        beforeRemoving: () throws -> Void
    ) throws {
        let entries = try listEntryNames(
            under: invocationRoot,
            maximumCount: 4
        )
        let proofPartials = entries.filter(Self.isPublicationProofPartialName)
        let attemptPartials = entries.filter(Self.isAttemptReplacementPartialName)
        guard proofPartials.count <= 1,
              attemptPartials.count <= 1,
              entries.count <= 4,
              Set(entries).isSubset(of: Set([
                  "invocation.json",
                  "publication-proof.json",
              ] + proofPartials + attemptPartials)),
              entries.contains("invocation.json")
        else { throw PortableChatPersistenceError.invalidLayout }

        var removed = false
        for name in proofPartials + attemptPartials + ["publication-proof.json"]
        where entries.contains(name) {
            guard isRegularFile(named: name, under: invocationRoot) else {
                throw PortableChatPersistenceError.invalidLayout
            }
            try beforeRemoving()
            guard unlinkat(invocationRoot, name, 0) == 0 else {
                throw PortableChatPersistenceError.ioFailure
            }
            removed = true
        }
        if removed { try flushDescriptor(invocationRoot) }
    }

    private func removePublicationProofIfPresent(
        from invocationRoot: Int32,
        beforeRemoving: () throws -> Void = {}
    ) throws {
        guard try entryExists(named: "publication-proof.json", under: invocationRoot) else {
            return
        }
        try beforeRemoving()
        guard isRegularFile(named: "publication-proof.json", under: invocationRoot),
              unlinkat(invocationRoot, "publication-proof.json", 0) == 0
        else { throw PortableChatPersistenceError.invalidLayout }
        try flushDescriptor(invocationRoot)
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

    private func installPublicationProof(
        _ proof: InvocationPublicationProof,
        under invocationRoot: Int32
    ) throws {
        if try entryExists(named: "publication-proof.json", under: invocationRoot) {
            let installed = try decodePublicationProof(
                boundedData(named: "publication-proof.json", under: invocationRoot)
            )
            guard installed == proof else {
                throw PortableChatPersistenceError.invalidLayout
            }
            try flushDescriptor(invocationRoot)
            return
        }
        try writeNewRoot(
            try encodePublicationProof(proof),
            named: "publication-proof.json",
            under: invocationRoot,
            points: (
                .beforePublicationProofPartialWrite,
                .afterPublicationProofPartialWrite,
                .afterPublicationProofFileFlush,
                .afterPublicationProofInstall,
                .afterPublicationProofDirectoryFlush
            )
        )
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

    private static func isPublicationProofPartialName(_ name: String) -> Bool {
        let prefix = ".publication-proof.json."
        let suffix = ".partial"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let uuid = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return UUID(uuidString: uuid)?.uuidString.lowercased() == uuid
    }

    private static func isAttemptReplacementPartialName(_ name: String) -> Bool {
        let prefix = ".invocation.json."
        let suffix = ".partial"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let uuid = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return UUID(uuidString: uuid)?.uuidString.lowercased() == uuid
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
        case 2:
            switch dto.failure {
            case nil: failure = nil
            case PendingUserTurnFailure.coachContextCannotFit.rawValue:
                failure = .coachContextCannotFit
            case PendingUserTurnFailure.coachResponseInterrupted.rawValue:
                failure = .coachResponseInterrupted
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
        try invocationEvidenceCodec.decodeInvocation(data)
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

private struct InvocationPublicationProofAuthority {
    let invocation: CoachInvocation
    let proof: InvocationPublicationProof
}

private struct InvocationPublicationProofLookup {
    let authorities: [ChatID: InvocationPublicationProofAuthority]
    let frozenSnapshots: [ChatID: FrozenChatSnapshot]

    func authority(for chatID: ChatID) -> InvocationPublicationProofAuthority? {
        authorities[chatID]
    }
}

private struct InvocationDirectoryRecord {
    let invocation: CoachInvocation
    let publicationProof: InvocationPublicationProof?
}

private struct InvocationBodyIdentity {
    let common: PortableInvocationCommonIdentityEnvelope
    let invocation: CoachInvocation
}

private enum InvocationBodyInspection {
    case available(InvocationBodyIdentity)
    case frozen(PortableInvocationCommonIdentityEnvelope, FrozenChatSnapshot)
}

private enum InvocationDirectoryInspection {
    case available(InvocationDirectoryRecord)
    case frozen(PortableInvocationCommonIdentityEnvelope, FrozenChatSnapshot)
}

private struct InvocationStableChatDTO: Codable {
    let chatId: String
    let createdAt: String
    let creationKind: String
    let originAttachmentId: String?
    let profileStatementGenerationAtCreation: UInt64
    let attachments: [ChatAttachmentDTO]
    let messageIds: [String]
    let currentMemoryId: String
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
