@_spi(InvocationInfrastructure) @_spi(CoachContextQualification) import AudoraApplication
import AudoraDomain
import CryptoKit
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
    let profileReconsideration: PortableInvocationLivenessKey?
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

/// Exact Reconsider-sidecar authority. It shares the Library Invocation
/// namespace with Pending leases but never invents an answer-only file.
private final class PortableProfileReconsiderationFileLease: @unchecked Sendable {
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
    private var pendingUserTurnLease: PortablePendingUserTurnFileLease?
    private var profileReconsiderationLease:
        PortableProfileReconsiderationFileLease?
    private let reservedPendingRequest: PendingCoachInvocationRequest?
    private let reservedReconsiderationRequest:
        ProfileReconsiderationInvocationRequest?
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
        profileReconsiderationLease = nil
        reservedPendingRequest = reservedRequest
        reservedReconsiderationRequest = nil
        self.didRelease = didRelease
    }

    fileprivate init(
        rootDescriptor: Int32,
        namespaceLock: PortableInvocationNamespaceLock,
        authority: PortableInvocationLivenessAuthority,
        profileReconsiderationLease: PortableProfileReconsiderationFileLease,
        reservedRequest: ProfileReconsiderationInvocationRequest,
        didRelease: @escaping @Sendable () -> Void
    ) {
        self.rootDescriptor = rootDescriptor
        self.namespaceLock = namespaceLock
        reservedAuthority = authority
        pendingUserTurnLease = nil
        self.profileReconsiderationLease = profileReconsiderationLease
        reservedPendingRequest = nil
        reservedReconsiderationRequest = reservedRequest
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
        guard request == reservedPendingRequest else { return nil }
        return authority()
    }

    fileprivate func authority(
        for request: ProfileReconsiderationInvocationRequest
    ) -> PortableInvocationLivenessAuthority? {
        guard request == reservedReconsiderationRequest else { return nil }
        return authority()
    }

    fileprivate func reservation() -> (
        authority: PortableInvocationLivenessAuthority,
        pendingRequest: PendingCoachInvocationRequest?,
        reconsiderationRequest: ProfileReconsiderationInvocationRequest?
    )? {
        lock.lock()
        defer { lock.unlock() }
        guard rootDescriptor != nil, namespaceLock != nil else { return nil }
        return (
            reservedAuthority,
            reservedPendingRequest,
            reservedReconsiderationRequest
        )
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
              let pendingUserTurnLease,
              reservedAuthority.pendingUserTurn == pendingUserTurnLease.key
        else {
            lock.unlock()
            replacement.release()
            throw PortableChatPersistenceError.ioFailure
        }
        let prior = pendingUserTurnLease
        self.pendingUserTurnLease = replacement
        reservedAuthority = PortableInvocationLivenessAuthority(
            libraryID: reservedAuthority.libraryID,
            root: reservedAuthority.root,
            invocations: reservedAuthority.invocations,
            pendingUserTurn: replacement.key,
            profileReconsideration: nil
        )
        lock.unlock()
        prior.release()
    }

    fileprivate func rebindProfileReconsiderationLease(
        _ replacement: PortableProfileReconsiderationFileLease
    ) throws {
        lock.lock()
        guard rootDescriptor != nil,
              namespaceLock != nil,
              let profileReconsiderationLease,
              reservedAuthority.profileReconsideration ==
                profileReconsiderationLease.key
        else {
            lock.unlock()
            replacement.release()
            throw PortableChatPersistenceError.ioFailure
        }
        let prior = profileReconsiderationLease
        self.profileReconsiderationLease = replacement
        reservedAuthority = PortableInvocationLivenessAuthority(
            libraryID: reservedAuthority.libraryID,
            root: reservedAuthority.root,
            invocations: reservedAuthority.invocations,
            pendingUserTurn: nil,
            profileReconsideration: replacement.key
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
        pendingUserTurnLease?.release()
        profileReconsiderationLease?.release()
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
    case afterAttachmentValidation
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
    case beforeProfileReconsiderationPartialWrite
    case afterProfileReconsiderationPartialWrite
    case afterProfileReconsiderationFileFlush
    case afterProfileReconsiderationInstall
    case afterProfileReconsiderationDirectoryFlush
    case beforePendingRemoval
    case afterPendingRemoval
    case afterPendingRemovalDirectoryFlush
    case beforeInvocationReconciliation
    case beforeInvocationReconciliationCommit
    case beforeInvocationPartialCleanup
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
    case afterReconsiderationSourceEffectBackupInstall
    case afterReconsiderationReplacementProposalInstall
    case afterReconsiderationReplacementProposalCommitInstall
    case afterUserMessageInstall
    case afterCoachMessageInstall
    case afterProfileProposalInstall
    case afterProfileEvidencePublicationInstall
    case beforeProfileWriteIntentPartialWrite
    case afterProfileWriteIntentPartialWrite
    case afterProfileWriteIntentFileFlush
    case afterProfileWriteIntentInstall
    case afterProfileWriteIntentDirectoryFlush
    case afterProfileRevisionInstall
    case afterProfileRevisionAbortRename
    case afterProfileRevisionAbsenceDirectoryFlush
    case beforeProfileHeadPartialWrite
    case afterProfileHeadPartialWrite
    case afterProfileHeadFileFlush
    case beforeProfileHeadInstall
    case afterProfileHeadInstall
    case afterProfileHeadDirectoryFlush
    case afterProfileProposalRemoval
    case afterProfileEvidencePublicationRemoval
    case beforeReconsiderationDiscardPartialWrite
    case afterReconsiderationDiscardPartialWrite
    case afterReconsiderationDiscardFileFlush
    case afterReconsiderationDiscardManifestInstall
    case afterReconsiderationDiscardDirectoryFlush
    case afterReconsiderationDiscardSidecarRemoval
    case afterProfileWriteIntentRemoval
    case afterPublicationManifestFileFlush
    case afterPublicationManifestInstall
    case afterPublicationManifestDirectoryFlush
    case beforePublicationCleanup
    case beforeReconsiderationPublishedInvocationRetirement
    case beforePublicationReconciliationRead
    case beforeStagedProfileRevisionCleanup
    case beforeStagedProfileRevisionLeafCleanup
}

public enum PortableChatPersistenceError: Error, Equatable, Sendable {
    case collision
    case creationAuthorityChanged
    case attachmentUnavailable
    case readOnlyLibrary
    case libraryScopeMismatch
    case profileStatementGenerationChanged(UInt64)
    case profileWriteInProgress
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

enum PortableProfileEffectAssessmentResult: Equatable, Sendable {
    case current(ChatAggregate)
    case stale(ChatAggregate, ProfileReconsiderationBasis)
}

enum PortableInvocationPublicationRecoveryResult: Sendable {
    case published(ChatAggregate)
    case notPublished
    case owned
}

private enum PortableProfileReconsiderationPublicationReconciliation {
    case base(ChatAggregate)
    case published(ChatAggregate)
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
    case .collision, .creationAuthorityChanged, .attachmentUnavailable,
         .readOnlyLibrary, .libraryScopeMismatch,
         .profileStatementGenerationChanged, .profileWriteInProgress,
         .chatMissing, .ioFailure,
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
    private struct InvocationPublicationArtifacts {
        let proof: InvocationPublicationProof
        let proposalData: Data?
        let profileEvidencePublicationData: Data?
    }

    private struct ProfileReconsiderationPublicationArtifacts {
        let proof: InvocationPublicationProof
        let sourceEffectData: Data
        let profileReconsiderationData: Data
        let coachMessageData: Data?
        let replacementProposalData: Data?
    }

    private struct RetryDiagnosticDependencies: Sendable {
        let sink: any InvocationRetryDiagnostics
        let now: @Sendable () -> UTCInstant
    }

    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct InvocationPartialFileIdentity: Equatable {
        let name: String
        let identity: PortableInvocationLivenessKey
    }

    private struct InvocationPartialCleanupPlan {
        let name: String
        let rootIdentity: DirectoryIdentity
        let invocationIdentity: PortableInvocationLivenessKey
        let invocation: CoachInvocation
        let partials: [InvocationPartialFileIdentity]

        func hasSameBoundEvidence(as other: Self) -> Bool {
            name == other.name &&
                rootIdentity == other.rootIdentity &&
                invocationIdentity == other.invocationIdentity &&
                invocation.hasSameDurableProjection(as: other.invocation) &&
                partials == other.partials
        }
    }

    private struct InvocationPartialCleanupCandidate {
        let record: InvocationDirectoryRecord
        let plan: InvocationPartialCleanupPlan
    }

    private struct StagedProfileRevisionCleanupFile: Equatable {
        let name: String
        let identity: PortableInvocationLivenessKey
        let data: Data
    }

    private struct StagedProfileRevisionCleanupPlan {
        let name: String
        let directoryIdentity: DirectoryIdentity
        let files: [StagedProfileRevisionCleanupFile]

        var nodeCount: Int { files.count + 1 }
    }

    private enum InvocationPartialCleanupInspection {
        case available(InvocationPartialCleanupCandidate)
        case frozen(PortableInvocationCommonIdentityEnvelope, FrozenChatSnapshot)
    }

    private enum DurablePublicIDCollisionCandidateID {
        case attemptID(CoachProviderAttemptID)
        case userMessageID(ChatMessageID)
        case coachMessageID(ChatMessageID)
        case freshDraftID(ChatDraftID)

        var collision: InvocationLaunchIdentityCollision {
            switch self {
            case .attemptID: .attemptID
            case .userMessageID: .userMessageID
            case .coachMessageID: .coachMessageID
            case .freshDraftID: .freshDraftID
            }
        }
    }

    private struct DurablePublicIDCollisionCandidate {
        let attemptID: CoachProviderAttemptID
        let userMessageID: ChatMessageID?
        let coachMessageID: ChatMessageID
        let freshDraftID: ChatDraftID?

        init(_ identity: InvocationLaunchIdentity) {
            attemptID = identity.attemptID
            userMessageID = identity.userMessageID
            coachMessageID = identity.coachMessageID
            freshDraftID = identity.freshDraftID
        }

        init(_ identity: InvocationProfileReconsiderationLaunchIdentity) {
            attemptID = identity.attemptID
            userMessageID = nil
            coachMessageID = identity.coachMessageID
            freshDraftID = nil
        }

        init(
            attemptID: CoachProviderAttemptID,
            authority: CoachProviderAttemptPublicationAuthority
        ) {
            self.attemptID = attemptID
            switch authority {
            case let .answerPendingUserTurn(
                userMessageID,
                coachMessageID,
                freshDraftID
            ):
                self.userMessageID = userMessageID
                self.coachMessageID = coachMessageID
                self.freshDraftID = freshDraftID
            case let .reconsiderProfileChange(coachMessageID):
                userMessageID = nil
                self.coachMessageID = coachMessageID
                freshDraftID = nil
            }
        }

        /// Launch preflight preserves its category-major priority across every
        /// Attempt while still validating the complete Library namespace.
        func launchOrderedCollisions(
            in invocation: CoachInvocation
        ) -> [DurablePublicIDCollisionCandidateID] {
            let attempts = invocation.attempts
            var collisions: [DurablePublicIDCollisionCandidateID] = []
            if attempts.contains(where: { $0.id == attemptID }) {
                collisions.append(.attemptID(attemptID))
            }
            if let userMessageID,
               attempts.contains(where: {
                   $0.userMessageID == userMessageID ||
                       $0.coachMessageID == userMessageID
               })
            {
                collisions.append(.userMessageID(userMessageID))
            }
            if attempts.contains(where: {
                $0.userMessageID == coachMessageID ||
                    $0.coachMessageID == coachMessageID
            }) {
                collisions.append(.coachMessageID(coachMessageID))
            }
            if let freshDraftID {
                let intentOwnsDraft: Bool = if case let .answerPendingUserTurn(
                    _, draftID, _, _
                ) = invocation.intent {
                    draftID == freshDraftID
                } else {
                    false
                }
                if attempts.contains(where: {
                    $0.freshDraftID == freshDraftID
                }) || intentOwnsDraft {
                    collisions.append(.freshDraftID(freshDraftID))
                }
            }
            return collisions
        }

        /// Next-Attempt installation preserves its attempt-major early-return
        /// policy, including the Invocation-root Draft check after all Attempts.
        func nextAttemptCollision(
            in invocation: CoachInvocation
        ) -> DurablePublicIDCollisionCandidateID? {
            for attempt in invocation.attempts {
                if attempt.id == attemptID { return .attemptID(attemptID) }
                if let userMessageID,
                   attempt.userMessageID == userMessageID ||
                    attempt.coachMessageID == userMessageID
                { return .userMessageID(userMessageID) }
                if attempt.userMessageID == coachMessageID ||
                    attempt.coachMessageID == coachMessageID
                { return .coachMessageID(coachMessageID) }
                if let freshDraftID,
                   attempt.freshDraftID == freshDraftID
                {
                    return .freshDraftID(freshDraftID)
                }
            }
            if let freshDraftID,
               case let .answerPendingUserTurn(_, draftID, _, _) =
                invocation.intent,
               draftID == freshDraftID
            {
                return .freshDraftID(freshDraftID)
            }
            return nil
        }

        func collision(
            in frozen: PortableInvocationCommonIdentityEnvelope
        ) -> DurablePublicIDCollisionCandidateID? {
            if frozen.contains(attemptID) { return .attemptID(attemptID) }
            if let userMessageID, frozen.contains(userMessageID) {
                return .userMessageID(userMessageID)
            }
            if frozen.contains(coachMessageID) {
                return .coachMessageID(coachMessageID)
            }
            if let freshDraftID, frozen.contains(freshDraftID) {
                return .freshDraftID(freshDraftID)
            }
            return nil
        }

        func collision(
            in chat: PortableChatDurablePublicIDs
        ) -> DurablePublicIDCollisionCandidateID? {
            if let userMessageID, chat.contains(userMessageID) {
                return .userMessageID(userMessageID)
            }
            if chat.contains(coachMessageID) {
                return .coachMessageID(coachMessageID)
            }
            if let freshDraftID, chat.contains(freshDraftID) {
                return .freshDraftID(freshDraftID)
            }
            return nil
        }
    }

    private enum ChatRootPublicIDProbe {
        case inspected(DurablePublicIDCollisionCandidateID?)
        case missing(PortableChatPersistenceError)
    }

    private enum ChatRootPublicIDProbeMode {
        case classifySiblingAbsence
        case strict
    }

    private enum SiblingChatPublicIDProbeMode: Equatable {
        case exhaustive
        case stopAtFirstCollision
    }

    /// Shared descriptor-relative scanner for the durable public-ID namespace.
    /// The two callers retain their own traversal and outcome policies: launch
    /// preflight records and continues, while next-Attempt installation returns
    /// its first collision immediately.
    private struct DurablePublicIDCollisionScanner {
        let candidate: DurablePublicIDCollisionCandidate
        private let entryExists: (String, Int32) throws -> Bool
        private let readChatPublicIDs: (Int32) throws -> PortableChatDurablePublicIDs

        init(
            persistence: PortableChatPersistence,
            candidate: DurablePublicIDCollisionCandidate
        ) {
            self.candidate = candidate
            entryExists = { name, descriptor in
                try persistence.entryExists(named: name, under: descriptor)
            }
            readChatPublicIDs = { descriptor in
                let manifest = try persistence.boundedData(
                    named: "chat.json",
                    under: descriptor
                )
                do {
                    return try persistence.invocationEvidenceCodec
                        .decodeChatDurablePublicIDs(manifest)
                } catch {
                    throw PortableChatPersistenceError.ioFailure
                }
            }
        }

        func messageFileCollision(
            under messagesDescriptor: Int32,
            mode: SiblingChatPublicIDProbeMode
        ) throws -> DurablePublicIDCollisionCandidateID? {
            var collision: DurablePublicIDCollisionCandidateID?
            if let userMessageID = candidate.userMessageID,
               try entryExists(
                   "\(userMessageID.rawValue).json",
                   messagesDescriptor
               )
            {
                collision = .userMessageID(userMessageID)
                if mode == .stopAtFirstCollision { return collision }
            }
            if try entryExists(
                "\(candidate.coachMessageID.rawValue).json",
                messagesDescriptor
            ) {
                return collision ?? .coachMessageID(candidate.coachMessageID)
            }
            return collision
        }

        func chatRootCollision(
            under chatDescriptor: Int32,
            mode: ChatRootPublicIDProbeMode
        ) throws -> ChatRootPublicIDProbe {
            do {
                return .inspected(
                    candidate.collision(in: try readChatPublicIDs(chatDescriptor))
                )
            } catch let error as PortableChatPersistenceError {
                if case .strict = mode { throw error }
                let manifestExists: Bool
                do {
                    manifestExists = try entryExists("chat.json", chatDescriptor)
                } catch {
                    throw PortableChatPersistenceError.ioFailure
                }
                if manifestExists {
                    throw PortableChatPersistenceError.ioFailure
                }
                return .missing(error)
            }
        }
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

    enum PreparedProfileReconsiderationResult {
        case prepared(
            InvocationProfileReconsiderationAuthority,
            PortableInvocationLivenessLease
        )
        case stale(ChatAggregate)
        case frozen(FrozenChatSnapshot)
        case activeExists
    }

    enum AcquiredProfileReconsiderationResult {
        case acquired(
            InvocationProfileReconsiderationAuthority,
            PortableInvocationLivenessLease
        )
        case ineligible(ChatAggregate?)
        case activeExists
    }

    private enum ProfileReconsiderationOpenMode {
        case new(NewProfileReconsiderationInvocationRequest)
        case retry(RetryProfileReconsiderationInvocationRequest)
        case operational(ProfileReconsiderationInvocationRequest)
    }

    private enum ProfileReconsiderationOpenResult {
        case opened(
            InvocationProfileReconsiderationAuthority,
            PortableInvocationLivenessLease
        )
        case ineligible(ChatAggregate?)
        case frozen(FrozenChatSnapshot)
        case activeExists
    }

    private struct OpenedLibraryRootAuthority {
        let parentDescriptor: Int32
        let rootDescriptor: Int32
        let name: String
        let identity: DirectoryIdentity
    }

    private struct ProfileProposalMutationAuthority {
        let root: OpenedLibraryRootAuthority
        let stagingDescriptor: Int32
        let stagingIdentity: DirectoryIdentity
        let publicationsDescriptor: Int32
        let publicationsIdentity: DirectoryIdentity
        let profileDescriptor: Int32
        let profileIdentity: DirectoryIdentity
        let revisionsDescriptor: Int32
        let revisionsIdentity: DirectoryIdentity
        let chatsDescriptor: Int32
        let chatsIdentity: DirectoryIdentity
        let chatName: String
        let chatDescriptor: Int32
        let chatIdentity: DirectoryIdentity
    }

    private struct PersistedProfileWriteIntent {
        let schemaVersion: UInt32
        let id: ProfileWriteIntentID
        let proposalID: ProfileChangeProposalID
        let chatID: ChatID
        let expectedHead: ProfileHeadAuthority
        let intendedRevisionID: ProfileRevisionID
        let createdAt: UTCInstant
        let proposalSHA256: String?
        let intendedRevisionSHA256: String?

        var hasRecoveryBinding: Bool {
            schemaVersion == PortableChatPersistence
                .profileWriteIntentSchemaVersion &&
                proposalSHA256 != nil && intendedRevisionSHA256 != nil
        }

        func domainValue(
            proposal: ProfileChangeProposal
        ) throws -> ProfileWriteIntent {
            guard proposal.id == proposalID, proposal.chatID == chatID else {
                throw PortableChatPersistenceError.invalidJSON
            }
            return try ProfileWriteIntent(
                id: id,
                proposal: proposal,
                expectedHead: expectedHead,
                intendedRevisionID: intendedRevisionID,
                createdAt: createdAt
            )
        }
    }

    public static let maximumRootBytes = 65_536
    static let maximumChatCatalogEntries = 4_096
    static let maximumMessageDirectoryEntries = 4_096
    static let maximumChatRootEntries = 256
    static let maximumMemoryDirectoryEntries = 256
    static let maximumInvocationDirectoryEntries = 16
    private static let profileWriteIntentSchemaVersion: UInt32 = 2
    private static let reconsiderationSourceEffectName =
        "reconsideration-source-effect.json"
    private static let reconsiderationReplacementProposalName =
        "reconsideration-replacement-proposal.json"

    private let fault: @Sendable (PortableChatFaultPoint) throws -> Void
    private let invocationLivenessReleased: @Sendable () -> Void
    private let retryDiagnosticDependencies: RetryDiagnosticDependencies?

    public init(
        fault: @escaping @Sendable (PortableChatFaultPoint) throws -> Void = { _ in }
    ) {
        self.fault = fault
        invocationLivenessReleased = {}
        retryDiagnosticDependencies = nil
    }

    @_spi(InvocationInfrastructure)
    public init(
        retryDiagnostics: any InvocationRetryDiagnostics,
        retryDiagnosticNow: @escaping @Sendable () -> UTCInstant
    ) {
        fault = { _ in }
        invocationLivenessReleased = {}
        retryDiagnosticDependencies = RetryDiagnosticDependencies(
            sink: retryDiagnostics,
            now: retryDiagnosticNow
        )
    }

    init(
        fault: @escaping @Sendable (PortableChatFaultPoint) throws -> Void,
        invocationLivenessReleased: @escaping @Sendable () -> Void
    ) {
        self.fault = fault
        self.invocationLivenessReleased = invocationLivenessReleased
        retryDiagnosticDependencies = nil
    }

    init(
        fault: @escaping @Sendable (PortableChatFaultPoint) throws -> Void,
        invocationLivenessReleased: @escaping @Sendable () -> Void,
        retryDiagnostics: any InvocationRetryDiagnostics,
        retryDiagnosticNow: @escaping @Sendable () -> UTCInstant
    ) {
        self.fault = fault
        self.invocationLivenessReleased = invocationLivenessReleased
        retryDiagnosticDependencies = RetryDiagnosticDependencies(
            sink: retryDiagnostics,
            now: retryDiagnosticNow
        )
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
                pendingUserTurn: pendingUserTurnLease.key,
                profileReconsideration: nil
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
            pendingUserTurn: nil,
            profileReconsideration: nil
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
                    pendingUserTurn: pendingLease.key,
                    profileReconsideration: nil
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

    func prepareNewProfileReconsiderationInvocation(
        _ request: NewProfileReconsiderationInvocationRequest,
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> PreparedProfileReconsiderationResult {
        guard request.library == scope else {
            throw PortableChatPersistenceError.libraryScopeMismatch
        }
        return switch try openProfileReconsiderationAuthority(
            .new(request),
            at: libraryRoot,
            in: scope
        ) {
        case let .opened(authority, lease): .prepared(authority, lease)
        case let .ineligible(current):
            if let current { .stale(current) }
            else { throw PortableChatPersistenceError.chatMissing }
        case let .frozen(frozen): .frozen(frozen)
        case .activeExists: .activeExists
        }
    }

    func acquireRetryProfileReconsiderationInvocation(
        _ request: RetryProfileReconsiderationInvocationRequest,
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> AcquiredProfileReconsiderationResult {
        guard request.library == scope else {
            throw PortableChatPersistenceError.libraryScopeMismatch
        }
        return switch try openProfileReconsiderationAuthority(
            .retry(request),
            at: libraryRoot,
            in: scope
        ) {
        case let .opened(authority, lease): .acquired(authority, lease)
        case let .ineligible(current): .ineligible(current)
        case .frozen: .ineligible(nil)
        case .activeExists: .activeExists
        }
    }

    func acquireOperationalProfileReconsiderationInvocation(
        _ request: ProfileReconsiderationInvocationRequest,
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> AcquiredProfileReconsiderationResult {
        guard request.library == scope else {
            throw PortableChatPersistenceError.libraryScopeMismatch
        }
        return switch try openProfileReconsiderationAuthority(
            .operational(request),
            at: libraryRoot,
            in: scope
        ) {
        case let .opened(authority, lease): .acquired(authority, lease)
        case let .ineligible(current): .ineligible(current)
        case .frozen: .ineligible(nil)
        case .activeExists: .activeExists
        }
    }

    private func openProfileReconsiderationAuthority(
        _ mode: ProfileReconsiderationOpenMode,
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> ProfileReconsiderationOpenResult {
        try withReconciledProfileWritesBeforeChatExposure(
            at: libraryRoot,
            in: scope
        ) { root, stagingDescriptor, stagingIdentity in
            guard let namespaceLock = try acquireInvocationNamespaceLock(
                under: root.rootDescriptor
            ) else { return .activeExists }
            var ownsNamespaceLock = true
            defer {
                if ownsNamespaceLock { namespaceLock.release() }
            }
            let rootIdentity = try invocationLivenessIdentity(
                of: root.rootDescriptor
            )
            let invocationsDescriptor = try openDirectory(
                named: "invocations",
                under: root.rootDescriptor
            )
            defer { Darwin.close(invocationsDescriptor) }
            let namespaceAuthority = PortableInvocationLivenessAuthority(
                libraryID: scope.libraryID,
                root: rootIdentity,
                invocations: namespaceLock.key,
                pendingUserTurn: nil,
                profileReconsideration: nil
            )
            let revalidateNamespace = invocationLivenessRevalidator(
                namespaceAuthority,
                at: libraryRoot,
                in: scope,
                under: root.rootDescriptor,
                invocationsDescriptor: invocationsDescriptor
            )
            try revalidateNamespace()
            let invocationNames = try invocationDirectoryNamesRemovingEmptyResidue(
                under: invocationsDescriptor,
                beforeRemoving: revalidateNamespace
            )
            if !invocationNames.isEmpty {
                // Operational recovery is allowed to retire its exact dead
                // prepublication Invocation below. Other opens never consume
                // an unclassified durable authority.
                guard case .operational = mode,
                      invocationNames.count == 1
                else { return .activeExists }
            }

            let publicationsIdentity = try directoryIdentity(
                named: "publications",
                under: stagingDescriptor
            )
            let publicationsDescriptor = try openDirectory(
                named: "publications",
                under: stagingDescriptor
            )
            defer { Darwin.close(publicationsDescriptor) }
            let profileIdentity = try directoryIdentity(
                named: "profile",
                under: root.rootDescriptor
            )
            let profileDescriptor = try openDirectory(
                named: "profile",
                under: root.rootDescriptor
            )
            defer { Darwin.close(profileDescriptor) }
            let revisionsIdentity = try directoryIdentity(
                named: "revisions",
                under: profileDescriptor
            )
            let revisionsDescriptor = try openDirectory(
                named: "revisions",
                under: profileDescriptor
            )
            defer { Darwin.close(revisionsDescriptor) }
            let chatsIdentity = try directoryIdentity(
                named: "chats",
                under: root.rootDescriptor
            )
            let chatsDescriptor = try openDirectory(
                named: "chats",
                under: root.rootDescriptor
            )
            defer { Darwin.close(chatsDescriptor) }

            let chatID: ChatID = switch mode {
            case let .new(request): request.observedAggregate.chat.id
            case let .retry(request): request.observedAggregate.chat.id
            case let .operational(request): request.chatID
            }
            let chatName = chatID.rawValue
            guard try entryExists(named: chatName, under: chatsDescriptor) else {
                return .ineligible(nil)
            }
            let chatIdentity = try directoryIdentity(
                named: chatName,
                under: chatsDescriptor
            )
            let chatDescriptor = try openDirectory(
                named: chatName,
                under: chatsDescriptor
            )
            defer { Darwin.close(chatDescriptor) }
            try acquireExclusiveMutationLock(on: chatDescriptor)
            defer { releaseMutationLock(on: chatDescriptor) }

            let profileAuthority = ProfileProposalMutationAuthority(
                root: root,
                stagingDescriptor: stagingDescriptor,
                stagingIdentity: stagingIdentity,
                publicationsDescriptor: publicationsDescriptor,
                publicationsIdentity: publicationsIdentity,
                profileDescriptor: profileDescriptor,
                profileIdentity: profileIdentity,
                revisionsDescriptor: revisionsDescriptor,
                revisionsIdentity: revisionsIdentity,
                chatsDescriptor: chatsDescriptor,
                chatsIdentity: chatsIdentity,
                chatName: chatName,
                chatDescriptor: chatDescriptor,
                chatIdentity: chatIdentity
            )
            let revalidate = {
                try self.revalidateProfileProposalMutationAuthority(
                    profileAuthority,
                    at: libraryRoot,
                    in: scope
                )
                try revalidateNamespace()
            }
            try revalidate()
            let loaded = try loadChat(
                from: chatDescriptor,
                expectedID: chatID,
                reconcileTransients: true,
                beforeDestructiveMutation: revalidate
            )
            guard case let .readWrite(initial) = loaded else {
                if case let .frozen(frozen) = loaded { return .frozen(frozen) }
                throw PortableChatPersistenceError.invalidLayout
            }

            let expectedBasis: ProfileReconsiderationBasis?
            let expectedReconsideration: ProfileReconsideration
            let stableRequest: ProfileReconsiderationInvocationRequest
            switch mode {
            case let .new(request):
                guard initial == request.observedAggregate,
                      initial.profileReconsideration == nil
                else { return .ineligible(initial) }
                expectedBasis = request.basis
                expectedReconsideration = request.reconsideration
                stableRequest = request.request
            case let .retry(request):
                guard initial == request.observedAggregate,
                      let reconsideration = initial.profileReconsideration,
                      reconsideration.failure != nil
                else { return .ineligible(initial) }
                expectedBasis = request.basis
                expectedReconsideration = reconsideration
                stableRequest = request.request
            case let .operational(request):
                guard let reconsideration = initial.profileReconsideration,
                      reconsideration.failure == nil,
                      reconsideration.sourceEffectIdentity ==
                        request.sourceEffectIdentity,
                      reconsideration.resultResponsePositionID ==
                        request.resultResponsePositionID
                else { return .ineligible(initial) }
                expectedBasis = nil
                expectedReconsideration = reconsideration
                stableRequest = request
            }
            guard initial.pendingUserTurn == nil,
                  let effect = initial.profileEffect,
                  effect.identity == expectedReconsideration.sourceEffectIdentity
            else { return .ineligible(initial) }

            let headData = try boundedData(
                named: "head.json",
                under: profileDescriptor
            )
            let head = try PortableLibraryPersistence().decodeProfileHead(headData)
            let selectedRevision = try loadSelectedProfileRevision(
                head,
                under: profileDescriptor
            )
            let latestProfile = selectedRevision.map(ProfileSnapshot.init) ??
                ProfileSnapshot(
                    nullAtStatementGeneration: head.statementGeneration
                )
            let sourceProvenance = try profileEffectSourceProvenance(
                effect,
                in: initial
            )
            let baseProfile = try loadProfileSnapshot(
                proving: sourceProvenance,
                under: profileDescriptor
            )
            try validateProfileEffect(effect, against: baseProfile)
            guard effect.requiresReconsideration(against: latestProfile) else {
                return .ineligible(initial)
            }
            let basis = try ProfileReconsiderationBasis(
                sourceEffect: effect,
                baseProfile: baseProfile,
                latestProfile: latestProfile
            )
            guard expectedBasis == nil || expectedBasis == basis else {
                return .ineligible(initial)
            }

            if case .new = mode {
                try revalidate()
                try installProfileReconsideration(
                    expectedReconsideration,
                    under: chatDescriptor
                )
            }
            let sidecarLease = try acquireAndValidateProfileReconsiderationFileLease(
                expectedReconsideration,
                under: chatDescriptor
            )
            var ownsSidecarLease = true
            defer {
                if ownsSidecarLease { sidecarLease.release() }
            }
            guard case let .readWrite(authoritativeAggregate) = try loadChat(
                from: chatDescriptor,
                expectedID: chatID,
                reconcileTransients: false
            ), authoritativeAggregate.profileReconsideration ==
                expectedReconsideration,
                authoritativeAggregate.profileEffect == effect
            else { throw PortableChatPersistenceError.invalidLayout }
            let authority = try InvocationProfileReconsiderationAuthority(
                request: stableRequest,
                aggregate: authoritativeAggregate,
                basis: basis
            )

            if let invocationName = invocationNames.first {
                guard case .operational = mode,
                      let invocationID = try? CoachInvocationID(invocationName)
                else { throw PortableChatPersistenceError.invalidLayout }
                let invocationRoot = try openDirectory(
                    named: invocationName,
                    under: invocationsDescriptor
                )
                defer { Darwin.close(invocationRoot) }
                let record = try loadInvocationDirectoryRecord(
                    expectedInvocationID: invocationID,
                    expectedLibraryID: scope.libraryID,
                    under: invocationRoot,
                    beforeRemoving: revalidate
                )
                guard record.publicationProof == nil,
                      record.invocation.terminalFailure == nil,
                      case let .reconsiderProfileChange(source, result) =
                        record.invocation.intent,
                      source == stableRequest.sourceEffectIdentity,
                      result == stableRequest.resultResponsePositionID,
                      record.invocation.chatID == stableRequest.chatID
                else { throw PortableChatPersistenceError.invalidLayout }
                try removeInvocationDirectoryIfPresent(
                    record.invocation,
                    under: invocationsDescriptor,
                    beforeRemoving: revalidate
                )
            }
            try revalidate()
            guard try boundedData(
                named: "head.json",
                under: profileDescriptor
            ) == headData else { throw PortableChatPersistenceError.invalidLayout }

            let retainedRootDescriptor = Darwin.dup(root.rootDescriptor)
            guard retainedRootDescriptor >= 0 else {
                throw PortableChatPersistenceError.ioFailure
            }
            let lease = PortableInvocationLivenessLease(
                rootDescriptor: retainedRootDescriptor,
                namespaceLock: namespaceLock,
                authority: PortableInvocationLivenessAuthority(
                    libraryID: scope.libraryID,
                    root: rootIdentity,
                    invocations: namespaceLock.key,
                    pendingUserTurn: nil,
                    profileReconsideration: sidecarLease.key
                ),
                profileReconsiderationLease: sidecarLease,
                reservedRequest: stableRequest,
                didRelease: invocationLivenessReleased
            )
            ownsNamespaceLock = false
            ownsSidecarLease = false
            return .opened(authority, lease)
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
                pendingUserTurn: nil,
                profileReconsideration: nil
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
        var reconsiderationMutations: [(
            aggregate: ChatAggregate,
            base: ProfileReconsideration,
            replacement: ProfileReconsideration,
            lease: PortableProfileReconsiderationFileLease
        )] = []
        defer {
            for mutation in reconsiderationMutations {
                mutation.lease.release()
            }
        }
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
                ) else { continue }
                if let pending = current.pendingUserTurn,
                   pending.failure == nil
                {
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
                } else if let reconsideration = current.profileReconsideration,
                          reconsideration.failure == nil
                {
                    let sidecarLease = try
                        acquireAndValidateProfileReconsiderationFileLease(
                            reconsideration,
                            under: chatDescriptor
                        )
                    reconsiderationMutations.append((
                        aggregate: current,
                        base: reconsideration,
                        replacement: reconsideration.replacingFailure(
                            .coachResponseInterrupted
                        ),
                        lease: sidecarLease
                    ))
                }
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
            let outcome = try replacePendingUserTurn(
                mutation,
                at: libraryRoot,
                livenessAuthority: livenessAuthority,
                ownsPendingUserTurnLease: false
            )
            if case .committed = outcome {
                recordRelaunchInterruption(invocation: nil)
            }
        }
        for mutation in reconsiderationMutations {
            let outcome = try replaceProfileReconsideration(
                expectedAggregate: mutation.aggregate,
                expected: mutation.base,
                replacement: mutation.replacement,
                at: libraryRoot,
                in: scope,
                livenessAuthority: livenessAuthority,
                lease: nil
            )
            if case .committed = outcome {
                recordRelaunchInterruption(invocation: nil)
            }
        }
    }

    private func recordRelaunchInterruption(invocation: CoachInvocation?) {
        guard let retryDiagnosticDependencies else { return }
        retryDiagnosticDependencies.sink.enqueue(
            InvocationRetryDiagnosticEvent(
                reason: .relaunchedInvocationInterrupted,
                classification: .interruption,
                disposition: .userRetryableFailure,
                invocationID: invocation?.id,
                attemptID: invocation?.attempt.id,
                attemptOrdinal: invocation?.attempt.ordinal,
                retryNumber: invocation?.attempt.ordinal,
                occurredAt: retryDiagnosticDependencies.now(),
                durationMilliseconds: 0,
                context: .unavailable
            )
        )
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
        try withReconciledProfileWritesBeforeChatExposure(
            at: libraryRoot,
            in: scope
        ) { root, _, _ in
            let rootDescriptor = root.rootDescriptor
            let publicationProof = try publicationProofLookup(
                expectedLibraryID: scope.libraryID,
                under: rootDescriptor
            )
            let chatsDescriptor = try openDirectory(
                named: "chats",
                under: rootDescriptor
            )
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
                        let descriptor = try openDirectory(
                            named: name,
                            under: chatsDescriptor
                        )
                        defer { Darwin.close(descriptor) }
                        return try loadChatReconcilingTransients(
                            from: descriptor,
                            expectedID: chatID,
                            publicationProofAuthority:
                                publicationProof.authority(for: chatID)
                        )
                    } catch let error as PortableChatPersistenceError {
                        guard let frozen = frozenChatSnapshot(
                            for: error,
                            chatID: chatID
                        ) else { throw error }
                        return .frozen(frozen)
                    } catch {
                        return .frozen(
                            FrozenChatSnapshot(chatID: chatID, reason: .corrupt)
                        )
                    }
                }
        }
    }

    func reconcileProfileWritesBeforeInvocationRecovery(
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws {
        try withReconciledProfileWritesBeforeChatExposure(
            at: libraryRoot,
            in: scope
        ) { _, _, _ in () }
    }

    public func load(
        _ chatID: ChatID,
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> LoadedPortableChat {
        try withReconciledProfileWritesBeforeChatExposure(
            at: libraryRoot,
            in: scope
        ) { root, _, _ in
            let rootDescriptor = root.rootDescriptor
            let publicationProof = try publicationProofLookup(
                expectedLibraryID: scope.libraryID,
                under: rootDescriptor
            )
            if let snapshot = publicationProof.frozenSnapshots[chatID] {
                return .frozen(snapshot)
            }
            let chatsDescriptor = try openDirectory(
                named: "chats",
                under: rootDescriptor
            )
            defer { Darwin.close(chatsDescriptor) }
            guard try entryExists(
                named: chatID.rawValue,
                under: chatsDescriptor
            ) else { throw PortableChatPersistenceError.chatMissing }
            let descriptor = try openDirectory(
                named: chatID.rawValue,
                under: chatsDescriptor
            )
            defer { Darwin.close(descriptor) }
            do {
                return try loadChatReconcilingTransients(
                    from: descriptor,
                    expectedID: chatID,
                    publicationProofAuthority:
                        publicationProof.authority(for: chatID)
                )
            } catch let error as PortableChatPersistenceError {
                guard let frozen = frozenChatSnapshot(
                    for: error,
                    chatID: chatID
                ) else { throw error }
                return .frozen(frozen)
            } catch {
                return .frozen(
                    FrozenChatSnapshot(chatID: chatID, reason: .corrupt)
                )
            }
        }
    }

    /// Reads the immutable attachment authority for one active Attempt without
    /// waiting behind a local writer. The caller owns bounded retry and treats
    /// `nil` as transient lock contention.
    func loadForAttemptTranscriptAvailability(
        _ chatID: ChatID,
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> LoadedPortableChat? {
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(
            named: "staging",
            under: rootDescriptor
        )
        defer { Darwin.close(stagingDescriptor) }
        guard try acquireSharedMutationLockNonblocking(on: stagingDescriptor)
        else { return nil }
        defer { releaseMutationLock(on: stagingDescriptor) }

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
        let chatDescriptor = try openDirectory(
            named: chatID.rawValue,
            under: chatsDescriptor
        )
        defer { Darwin.close(chatDescriptor) }
        guard try acquireSharedMutationLockNonblocking(on: chatDescriptor)
        else { return nil }
        defer { releaseMutationLock(on: chatDescriptor) }
        do {
            return try loadChat(
                from: chatDescriptor,
                expectedID: chatID,
                reconcileTransients: false,
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

    func create(
        _ seed: NewChatSeed,
        at libraryRoot: URL
    ) throws -> ChatAggregate {
        try create(
            seed,
            at: libraryRoot,
            expectedAttachmentFingerprints: nil,
            expectedRootIdentity: nil
        )
    }

    func create(
        _ seed: NewChatSeed,
        at libraryRoot: URL,
        expectedAttachmentFingerprints:
            [PortableChatAttachmentFingerprint]?,
        expectedRootIdentity: SessionProcessingRootIdentity? = nil
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
        let rootAuthority = try openLibraryRootAuthority(
            at: libraryRoot,
            in: seed.library,
            expectedProfileStatementGeneration:
                seed.aggregate.chat.profileStatementGenerationAtCreation
        )
        let rootDescriptor = rootAuthority.rootDescriptor
        defer { Darwin.close(rootDescriptor) }
        defer { Darwin.close(rootAuthority.parentDescriptor) }
        try revalidateExpectedChatCreationRootIdentity(
            expectedRootIdentity,
            under: rootDescriptor
        )
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
        try revalidateConfiguredRootAuthority(rootAuthority)
        try revalidateLibraryAuthority(
            libraryID: seed.library.libraryID,
            profileStatementGeneration:
                seed.aggregate.chat.profileStatementGenerationAtCreation,
            under: rootDescriptor
        )
        let attachmentInstall: Bool?
        do {
            attachmentInstall = try PortableTranscriptRevisionRepository(
                root: libraryRoot,
                libraryID: seed.library.libraryID
            ).withAvailableChatAttachmentsSynchronously(
                seed.aggregate.chat.attachments,
                expectedFingerprints: expectedAttachmentFingerprints,
                underRootDescriptor: rootDescriptor
            ) {
                try fault(.afterAttachmentValidation)
                try revalidateConfiguredRootAuthority(rootAuthority)
                try revalidateExpectedChatCreationRootIdentity(
                    expectedRootIdentity,
                    under: rootDescriptor
                )
                try revalidateLibraryAuthority(
                    libraryID: seed.library.libraryID,
                    profileStatementGeneration:
                        seed.aggregate.chat.profileStatementGenerationAtCreation,
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
                return true
            }
        } catch let error as PortableChatPersistenceError {
            throw error
        } catch {
            throw expectedAttachmentFingerprints == nil
                ? PortableChatPersistenceError.attachmentUnavailable
                : PortableChatPersistenceError.creationAuthorityChanged
        }
        guard attachmentInstall == true else {
            throw expectedAttachmentFingerprints == nil
                ? PortableChatPersistenceError.attachmentUnavailable
                : PortableChatPersistenceError.creationAuthorityChanged
        }
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
            memory: current.memory,
            messages: current.messages,
            profileProposal: current.profileProposal,
            profileEvidencePublication: current.profileEvidencePublication
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
            messages: current.messages,
            pendingUserTurn: mutation.pendingUserTurn,
            profileProposal: current.profileProposal,
            profileEvidencePublication: current.profileEvidencePublication
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
            messages: current.messages,
            pendingUserTurn: mutation.replacement,
            profileProposal: current.profileProposal,
            profileEvidencePublication: current.profileEvidencePublication
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
        let replacement = try ChatAggregate(
            chat: current.chat,
            memory: current.memory,
            messages: current.messages,
            profileProposal: current.profileProposal,
            profileEvidencePublication: current.profileEvidencePublication
        )
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
            reservedRequest: nil,
            reservedReconsiderationRequest: nil
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
            reservedRequest: reservation.pendingRequest,
            reservedReconsiderationRequest: reservation.reconsiderationRequest
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
            reservedRequest: nil,
            reservedReconsiderationRequest: nil
        )
    }

    private func reconcileInterruptedInvocations(
        at libraryRoot: URL,
        in scope: LibraryScope,
        livenessAuthority: PortableInvocationLivenessAuthority?,
        reservedRequest: PendingCoachInvocationRequest?,
        reservedReconsiderationRequest:
            ProfileReconsiderationInvocationRequest? = nil
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
                    reservedReconsiderationRequest:
                        reservedReconsiderationRequest,
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
                        reservedReconsiderationRequest:
                            reservedReconsiderationRequest,
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
                var recoveryReconsiderationLease:
                    PortableProfileReconsiderationFileLease?
                switch invocation.intent {
                case let .answerPendingUserTurn(pendingID, _, _, _):
                    let invocationRequest = PendingCoachInvocationRequest(
                        library: scope,
                        chatID: invocation.chatID,
                        pendingUserTurnID: pendingID
                    )
                    guard try entryExists(
                        named: "pending-user-turn.json",
                        under: chatDescriptor
                    ) else { throw PortableChatPersistenceError.invalidLayout }
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
                        ) else { throw PortableChatPersistenceError.ioFailure }
                        recoveryPendingLease = lease
                    }
                case let .reconsiderProfileChange(source, result):
                    let invocationRequest =
                        ProfileReconsiderationInvocationRequest(
                            library: scope,
                            chatID: invocation.chatID,
                            sourceEffectIdentity: source,
                            resultResponsePositionID: result
                        )
                    let hasReconsideration = try entryExists(
                        named: "profile-reconsideration.json",
                        under: chatDescriptor
                    )
                    if !hasReconsideration {
                        guard record.publicationProof.map({ proof in
                            if case .reconsiderProfileChange = proof.intent {
                                return true
                            }
                            return false
                        }) == true else {
                            throw PortableChatPersistenceError.invalidLayout
                        }
                    } else if invocationRequest == reservedReconsiderationRequest,
                       let expected = livenessAuthority?.profileReconsideration
                    {
                        guard try regularFileLivenessIdentity(
                            named: "profile-reconsideration.json",
                            under: chatDescriptor
                        ) == expected else {
                            throw PortableChatPersistenceError.invalidLayout
                        }
                    } else {
                        guard let lease = try
                            acquireProfileReconsiderationFileLease(
                                under: chatDescriptor
                            )
                        else { throw PortableChatPersistenceError.ioFailure }
                        recoveryReconsiderationLease = lease
                    }
                }
                defer { recoveryPendingLease?.release() }
                defer { recoveryReconsiderationLease?.release() }
                try revalidateBeforeMutation()
                let reconciledReconsiderationBase: ChatAggregate?
                if let proof = record.publicationProof,
                   case .reconsiderProfileChange = invocation.intent
                {
                    switch try reconcileProfileReconsiderationPublication(
                        invocation: invocation,
                        proof: proof,
                        record: record,
                        invocationRoot: invocationRoot,
                        invocationsDescriptor: invocationsDescriptor,
                        chatDescriptor: chatDescriptor,
                        beforeMutation: revalidateBeforeMutation
                    ) {
                    case .published:
                        continue
                    case let .base(base):
                        reconciledReconsiderationBase = base
                    }
                } else {
                    reconciledReconsiderationBase = nil
                }
                let current: ChatAggregate
                if let reconciledReconsiderationBase {
                    current = reconciledReconsiderationBase
                } else {
                    guard case let .readWrite(loaded) = try loadChat(
                        from: chatDescriptor,
                        expectedID: invocation.chatID,
                        reconcileTransients: true,
                        publicationProofAuthority: publicationAuthority,
                        beforeDestructiveMutation: revalidateBeforeMutation
                    ) else { throw PortableChatPersistenceError.invalidLayout }
                    current = loaded
                }

                let pendingData = try entryExists(
                    named: "pending-user-turn.json",
                    under: chatDescriptor
                ) ? boundedData(
                    named: "pending-user-turn.json",
                    under: chatDescriptor
                ) : nil
                if let proof = record.publicationProof,
                   case .answerPendingUserTurn = invocation.intent,
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
                    let isInvalidPublicationState: Bool
                    switch invocation.intent {
                    case .answerPendingUserTurn:
                        isInvalidPublicationState =
                            record.publicationProof != nil ||
                            (current.pendingUserTurn == nil &&
                                !isProvablyPrePublication(
                                    invocation,
                                    current: current
                                ))
                    case .reconsiderProfileChange:
                        isInvalidPublicationState = record.publicationProof != nil
                    }
                    if isInvalidPublicationState {
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
                let createdRetry: Bool = switch invocation.intent {
                case .answerPendingUserTurn:
                    current.pendingUserTurn?.failure == nil
                case .reconsiderProfileChange:
                    current.profileReconsideration?.failure == nil
                }
                _ = try retireInvocation(
                    invocation,
                    current: current,
                    invocationRoot: invocationRoot,
                    invocationsDescriptor: invocationsDescriptor,
                    chatDescriptor: chatDescriptor,
                    beforeCommitting: revalidateBeforeMutation
                )
                if createdRetry {
                    recordRelaunchInterruption(invocation: invocation)
                }
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
        reservedReconsiderationRequest:
            ProfileReconsiderationInvocationRequest?,
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
        var recoveryReconsiderationLease:
            PortableProfileReconsiderationFileLease?
        switch invocation.intent {
        case let .answerPendingUserTurn(pendingID, _, _, _):
            let request = PendingCoachInvocationRequest(
                library: scope,
                chatID: invocation.chatID,
                pendingUserTurnID: pendingID
            )
            guard try entryExists(
                named: "pending-user-turn.json",
                under: chatDescriptor
            ) else { return false }
            if request == reservedRequest,
               let expected = livenessAuthority?.pendingUserTurn
            {
                guard try regularFileLivenessIdentity(
                    named: "pending-user-turn.json",
                    under: chatDescriptor
                ) == expected else {
                    throw PortableChatPersistenceError.invalidLayout
                }
            } else {
                guard let lease = try acquirePendingUserTurnFileLease(
                    under: chatDescriptor
                ) else { throw PortableChatPersistenceError.ioFailure }
                recoveryPendingLease = lease
            }
        case let .reconsiderProfileChange(source, result):
            let request = ProfileReconsiderationInvocationRequest(
                library: scope,
                chatID: invocation.chatID,
                sourceEffectIdentity: source,
                resultResponsePositionID: result
            )
            guard try entryExists(
                named: "profile-reconsideration.json",
                under: chatDescriptor
            ) else { return false }
            if request == reservedReconsiderationRequest,
               let expected = livenessAuthority?.profileReconsideration
            {
                guard try regularFileLivenessIdentity(
                    named: "profile-reconsideration.json",
                    under: chatDescriptor
                ) == expected else {
                    throw PortableChatPersistenceError.invalidLayout
                }
            } else {
                guard let lease = try acquireProfileReconsiderationFileLease(
                    under: chatDescriptor
                ) else { throw PortableChatPersistenceError.ioFailure }
                recoveryReconsiderationLease = lease
            }
        }
        defer { recoveryPendingLease?.release() }
        defer { recoveryReconsiderationLease?.release() }

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
        guard case let .readWrite(current) = loaded else { return false }
        let hasPrePublicationManifest: Bool = switch invocation.intent {
        case .answerPendingUserTurn:
            // Answer intent validation deliberately survives title-only
            // metadata revisions while the exact Pending/Draft stays locked.
            true
        case .reconsiderProfileChange:
            // Reconsider keeps its source and sidecar canonical until C1, so
            // intent shape alone cannot distinguish C0 from a committed C1.
            current.chat.manifestRevision == invocation.expectedManifestRevision
        }
        guard hasPrePublicationManifest,
              (try? invocation.validateIntent(against: current)) != nil
        else { return false }

        if performRetirement {
            let createdRetry: Bool = switch invocation.intent {
            case .answerPendingUserTurn:
                current.pendingUserTurn?.failure == nil
            case .reconsiderProfileChange:
                current.profileReconsideration?.failure == nil
            }
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
            if createdRetry {
                recordRelaunchInterruption(invocation: invocation)
            }
        }
        return true
    }

    private func siblingChatPublicIDCollision(
        using scanner: DurablePublicIDCollisionScanner,
        chatID: ChatID,
        named chatName: String,
        under chatsDescriptor: Int32,
        mode: SiblingChatPublicIDProbeMode
    ) throws -> DurablePublicIDCollisionCandidateID? {
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
            return nil
        } catch {
            throw error
        }
        defer { Darwin.close(chatDescriptor) }

        var collision: DurablePublicIDCollisionCandidateID?
        do {
            let messagesDescriptor = try openDirectory(
                named: "messages",
                under: chatDescriptor
            )
            defer { Darwin.close(messagesDescriptor) }
            collision = try scanner.messageFileCollision(
                under: messagesDescriptor,
                mode: mode
            )
            if collision != nil, mode == .stopAtFirstCollision {
                return collision
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
        } catch {
            throw error
        }

        switch try scanner.chatRootCollision(
            under: chatDescriptor,
            mode: .classifySiblingAbsence
        ) {
        case let .inspected(rootCollision):
            return collision ?? rootCollision
        case let .missing(error):
            guard frozenChatSnapshot(for: error, chatID: chatID) != nil else {
                throw error
            }
            return collision
        }
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

        let publicIDScanner = DurablePublicIDCollisionScanner(
            persistence: self,
            candidate: DurablePublicIDCollisionCandidate(identity)
        )
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
                for candidateID in publicIDScanner.candidate
                    .launchOrderedCollisions(in: record.invocation)
                {
                    recordCollision(candidateID.collision)
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
                if let candidateID = publicIDScanner.candidate.collision(in: common) {
                    recordCollision(candidateID.collision)
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
            if chatID != authority.request.chatID {
                if let candidateID = try siblingChatPublicIDCollision(
                    using: publicIDScanner,
                    chatID: chatID,
                    named: chatName,
                    under: chatsDescriptor,
                    mode: .exhaustive
                ) {
                    recordCollision(candidateID.collision)
                }
                continue
            }

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
            try acquireExclusiveMutationLock(on: chatDescriptor)
            defer { releaseMutationLock(on: chatDescriptor) }
            guard let expectedPending = livenessAuthority.pendingUserTurn,
                  try regularFileLivenessIdentity(
                      named: "pending-user-turn.json",
                      under: chatDescriptor
                  ) == expectedPending
            else { throw PortableChatPersistenceError.invalidLayout }

            do {
                let messagesDescriptor = try openDirectory(
                    named: "messages",
                    under: chatDescriptor
                )
                defer { Darwin.close(messagesDescriptor) }
                if let candidateID = try publicIDScanner.messageFileCollision(
                    under: messagesDescriptor,
                    mode: .exhaustive
                ) {
                    recordCollision(candidateID.collision)
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
            let publicIDs = PortableChatDurablePublicIDs(
                draftID: aggregate.chat.draft.draftID,
                messageIDs: Set(aggregate.chat.messageIDs)
            )
            if let candidateID = publicIDScanner.candidate.collision(in: publicIDs) {
                recordCollision(candidateID.collision)
            }
        }
        guard let current else { return .stale(nil) }
        guard current == authority.aggregate else { return .stale(current) }
        try revalidateLiveness()
        if let collision { return .collision(collision) }
        return .available
    }

    func checkLaunchIdentity(
        _ identity: InvocationProfileReconsiderationLaunchIdentity,
        for authority: InvocationProfileReconsiderationAuthority,
        at libraryRoot: URL,
        holding lease: PortableInvocationLivenessLease
    ) throws -> InvocationLaunchIdentityAvailabilityOutcome {
        guard let livenessAuthority = lease.authority(for: authority.request),
              let expectedSidecar = livenessAuthority.profileReconsideration
        else { throw PortableChatPersistenceError.ioFailure }
        let rootDescriptor = try openLibraryRoot(
            at: libraryRoot,
            in: authority.request.library
        )
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(
            named: "staging",
            under: rootDescriptor
        )
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

        let publicIDScanner = DurablePublicIDCollisionScanner(
            persistence: self,
            candidate: DurablePublicIDCollisionCandidate(identity)
        )
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
            switch try inspectInvocationDirectory(
                named: invocationName,
                expectedLibraryID: authority.request.library.libraryID,
                under: invocationsDescriptor,
                reconcileProofPartial: false
            ) {
            case let .available(record):
                for candidateID in publicIDScanner.candidate
                    .launchOrderedCollisions(in: record.invocation)
                {
                    recordCollision(candidateID.collision)
                }
                let attempts = record.invocation.attempts
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
                if let candidateID = publicIDScanner.candidate.collision(
                    in: common
                ) {
                    recordCollision(candidateID.collision)
                }
            }
        }

        let chatsDescriptor = try openDirectory(
            named: "chats",
            under: rootDescriptor
        )
        defer { Darwin.close(chatsDescriptor) }
        var current: ChatAggregate?
        for chatName in try listEntryNames(
            under: chatsDescriptor,
            maximumCount: Self.maximumChatCatalogEntries
        ) {
            guard let chatID = try? ChatID(chatName) else { continue }
            if chatID != authority.request.chatID {
                if let candidateID = try siblingChatPublicIDCollision(
                    using: publicIDScanner,
                    chatID: chatID,
                    named: chatName,
                    under: chatsDescriptor,
                    mode: .exhaustive
                ) {
                    recordCollision(candidateID.collision)
                }
                continue
            }
            let chatDescriptor = try openDirectory(
                named: chatName,
                under: chatsDescriptor
            )
            defer { Darwin.close(chatDescriptor) }
            try acquireExclusiveMutationLock(on: chatDescriptor)
            defer { releaseMutationLock(on: chatDescriptor) }
            guard try regularFileLivenessIdentity(
                named: "profile-reconsideration.json",
                under: chatDescriptor
            ) == expectedSidecar else {
                throw PortableChatPersistenceError.invalidLayout
            }
            let messagesDescriptor = try openDirectory(
                named: "messages",
                under: chatDescriptor
            )
            defer { Darwin.close(messagesDescriptor) }
            if let candidateID = try publicIDScanner.messageFileCollision(
                under: messagesDescriptor,
                mode: .exhaustive
            ) {
                recordCollision(candidateID.collision)
            }
            guard case let .readWrite(aggregate) = try loadChat(
                from: chatDescriptor,
                expectedID: chatID,
                reconcileTransients: true,
                beforeDestructiveMutation: revalidateLiveness
            ) else { return .stale(nil) }
            current = aggregate
            if let candidateID = publicIDScanner.candidate.collision(
                in: PortableChatDurablePublicIDs(
                    draftID: aggregate.chat.draft.draftID,
                    messageIDs: Set(aggregate.chat.messageIDs)
                )
            ) {
                recordCollision(candidateID.collision)
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

    func installProfileReconsiderationInvocation(
        _ mutation: InstallProfileReconsiderationInvocationMutation,
        at libraryRoot: URL,
        holding lease: PortableInvocationLivenessLease
    ) throws -> InvocationInstallOutcome {
        guard let livenessAuthority = lease.authority(
            for: mutation.authority.request
        ), livenessAuthority.profileReconsideration != nil else {
            throw PortableChatPersistenceError.ioFailure
        }
        let scope = mutation.authority.request.library
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(
            named: "staging",
            under: rootDescriptor
        )
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
        if try hasActiveInvocation(
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor,
            expectedLibraryID: scope.libraryID,
            beforeDestructiveMutation: revalidateLiveness
        ) { return .activeExists }

        let chatsDescriptor = try openDirectory(
            named: "chats",
            under: rootDescriptor
        )
        defer { Darwin.close(chatsDescriptor) }
        let chatName = mutation.authority.request.chatID.rawValue
        guard try entryExists(named: chatName, under: chatsDescriptor) else {
            return .stale(nil)
        }
        let chatIdentity = try directoryIdentity(
            named: chatName,
            under: chatsDescriptor
        )
        let chatDescriptor = try openDirectory(
            named: chatName,
            under: chatsDescriptor
        )
        defer { Darwin.close(chatDescriptor) }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        guard try directoryIdentity(of: chatDescriptor) == chatIdentity,
              case let .readWrite(current) = try loadChat(
                  from: chatDescriptor,
                  expectedID: mutation.authority.request.chatID,
                  reconcileTransients: true,
                  beforeDestructiveMutation: revalidateLiveness
              ), current == mutation.authority.aggregate
        else { return .stale(nil) }

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
        try revalidateLiveness()
        guard try directoryIdentity(
            named: partialName,
            under: invocationsDescriptor
        ) == partialIdentity,
            case let .readWrite(commitAuthority) = try loadChat(
                from: chatDescriptor,
                expectedID: mutation.authority.request.chatID,
                reconcileTransients: false
            ), commitAuthority == current
        else { return .stale(current) }
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
        _ = try installProfileReconsiderationProcessingTransition(
            mutation,
            current: current,
            under: chatDescriptor,
            holding: lease,
            beforeCommitting: revalidateLiveness
        )
        return .installed(mutation.invocation)
    }

    func reconcileInstalledProfileReconsiderationInvocation(
        _ mutation: InstallProfileReconsiderationInvocationMutation,
        at libraryRoot: URL,
        holding lease: PortableInvocationLivenessLease
    ) throws -> CoachInvocation? {
        guard let livenessAuthority = lease.authority(
            for: mutation.authority.request
        ) else { throw PortableChatPersistenceError.ioFailure }
        let scope = mutation.authority.request.library
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(
            named: "staging",
            under: rootDescriptor
        )
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        let revalidate = invocationLivenessRevalidator(
            livenessAuthority,
            at: libraryRoot,
            in: scope,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
        try revalidate()
        try reconcileInvocationPartials(
            under: invocationsDescriptor,
            beforeRemoving: revalidate
        )
        let invocationName = mutation.invocation.id.rawValue
        guard try entryExists(
            named: invocationName,
            under: invocationsDescriptor
        ) else { return nil }
        let invocationRoot = try openDirectory(
            named: invocationName,
            under: invocationsDescriptor
        )
        defer { Darwin.close(invocationRoot) }
        let chatsDescriptor = try openDirectory(
            named: "chats",
            under: rootDescriptor
        )
        defer { Darwin.close(chatsDescriptor) }
        let chatDescriptor = try openDirectory(
            named: mutation.authority.request.chatID.rawValue,
            under: chatsDescriptor
        )
        defer { Darwin.close(chatDescriptor) }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        guard case let .readWrite(current) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.authority.request.chatID,
            reconcileTransients: true,
            beforeDestructiveMutation: revalidate
        ), current == mutation.authority.aggregate ||
            current == mutation.processingAggregate
        else { return nil }
        let installed = try loadInvocationDirectoryRecord(
            expectedInvocationID: mutation.invocation.id,
            expectedLibraryID: scope.libraryID,
            under: invocationRoot,
            beforeRemoving: revalidate
        ).invocation
        guard installed.hasSameDurableProjection(as: mutation.invocation) else {
            return nil
        }
        try flushDescriptor(invocationRoot)
        try flushDescriptor(invocationsDescriptor)
        _ = try installProfileReconsiderationProcessingTransition(
            mutation,
            current: current,
            under: chatDescriptor,
            holding: lease,
            beforeCommitting: revalidate
        )
        return mutation.invocation
    }

    private func installProfileReconsiderationProcessingTransition(
        _ mutation: InstallProfileReconsiderationInvocationMutation,
        current: ChatAggregate,
        under chatDescriptor: Int32,
        holding lease: PortableInvocationLivenessLease,
        beforeCommitting: () throws -> Void
    ) throws -> ChatAggregate {
        guard current == mutation.authority.aggregate ||
                current == mutation.processingAggregate,
              current.profileReconsideration == mutation.authority.reconsideration
                || current.profileReconsideration ==
                    mutation.processingAggregate.profileReconsideration,
              let processing = mutation.processingAggregate.profileReconsideration
        else { throw PortableChatPersistenceError.invalidLayout }
        if current != mutation.processingAggregate {
            let partialName =
                ".profile-reconsideration.json.\(UUID().uuidString.lowercased()).partial"
            var partialExists = false
            defer {
                if partialExists {
                    _ = partialName.withCString {
                        Darwin.unlinkat(chatDescriptor, $0, 0)
                    }
                }
            }
            try writeExclusive(
                try encodeProfileReconsideration(processing),
                named: partialName,
                under: chatDescriptor
            )
            partialExists = true
            let descriptor = try openRegularFile(
                named: partialName,
                under: chatDescriptor
            )
            defer { Darwin.close(descriptor) }
            try flushDescriptor(descriptor)
            try beforeCommitting()
            guard case let .readWrite(exact) = try loadChat(
                from: chatDescriptor,
                expectedID: mutation.authority.request.chatID,
                reconcileTransients: false
            ), exact == mutation.authority.aggregate,
                renameat(
                    chatDescriptor,
                    partialName,
                    chatDescriptor,
                    "profile-reconsideration.json"
                ) == 0
            else { throw PortableChatPersistenceError.invalidLayout }
            partialExists = false
        }
        try flushDescriptor(chatDescriptor)
        let installedKey = try regularFileLivenessIdentity(
            named: "profile-reconsideration.json",
            under: chatDescriptor
        )
        guard let currentAuthority = lease.authority(
            for: mutation.authority.request
        ) else { throw PortableChatPersistenceError.ioFailure }
        if currentAuthority.profileReconsideration != installedKey {
            let replacementLease = try
                acquireAndValidateProfileReconsiderationFileLease(
                    processing,
                    under: chatDescriptor
                )
            try lease.rebindProfileReconsiderationLease(replacementLease)
        }
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.authority.request.chatID,
            reconcileTransients: true,
            beforeDestructiveMutation: beforeCommitting
        ), reopened == mutation.processingAggregate else {
            throw PortableChatPersistenceError.invalidLayout
        }
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

    func installNextProfileReconsiderationAttempt(
        _ mutation: InstallNextProfileReconsiderationAttemptMutation,
        at libraryRoot: URL,
        in scope: LibraryScope,
        holding lease: PortableInvocationLivenessLease
    ) throws -> PortableNextAttemptInstallResult {
        guard case let .reconsiderProfileChange(source, result) =
            mutation.base.intent
        else { throw PortableChatPersistenceError.invalidLayout }
        let request = ProfileReconsiderationInvocationRequest(
            library: scope,
            chatID: mutation.base.chatID,
            sourceEffectIdentity: source,
            resultResponsePositionID: result
        )
        guard mutation.base.libraryID == scope.libraryID,
              mutation.replacement.libraryID == scope.libraryID,
              mutation.replacement.id == mutation.base.id,
              let livenessAuthority = lease.authority(for: request)
        else { throw PortableChatPersistenceError.ioFailure }

        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(
            named: "staging",
            under: rootDescriptor
        )
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        let revalidate = invocationLivenessRevalidator(
            livenessAuthority,
            at: libraryRoot,
            in: scope,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
        try revalidate()
        let invocationName = mutation.base.id.rawValue
        guard try entryExists(
            named: invocationName,
            under: invocationsDescriptor
        ) else { return .stale(nil) }
        let invocationIdentity = try directoryIdentity(
            named: invocationName,
            under: invocationsDescriptor
        )
        let invocationRoot = try openDirectory(
            named: invocationName,
            under: invocationsDescriptor
        )
        defer { Darwin.close(invocationRoot) }
        let current = try loadInvocationDirectoryRecord(
            expectedInvocationID: mutation.base.id,
            expectedLibraryID: scope.libraryID,
            under: invocationRoot,
            reconcileProofPartial: true,
            beforeRemoving: revalidate
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
            beforeDestructiveMutation: revalidate
        ) {
            return .collision(collision)
        }
        let partialName =
            ".invocation.json.\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString {
                    Darwin.unlinkat(invocationRoot, $0, 0)
                }
            }
        }
        try writeExclusive(
            try encodeInvocation(mutation.replacement),
            named: partialName,
            under: invocationRoot
        )
        partialExists = true
        let partialDescriptor = try openRegularFile(
            named: partialName,
            under: invocationRoot
        )
        defer { Darwin.close(partialDescriptor) }
        try flushDescriptor(partialDescriptor)
        try revalidate()
        guard try directoryIdentity(
            named: invocationName,
            under: invocationsDescriptor
        ) == invocationIdentity,
            try loadInvocationDirectoryRecord(
                expectedInvocationID: mutation.base.id,
                expectedLibraryID: scope.libraryID,
                under: invocationRoot,
                reconcileProofPartial: false
            ).invocation.hasSameDurableProjection(as: mutation.base),
            renameat(
                invocationRoot,
                partialName,
                invocationRoot,
                "invocation.json"
            ) == 0
        else { throw PortableChatPersistenceError.invalidLayout }
        partialExists = false
        try flushDescriptor(invocationRoot)
        let installed = try decodeInvocation(
            boundedData(named: "invocation.json", under: invocationRoot)
        )
        guard installed.hasSameDurableProjection(as: mutation.replacement) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return .installed(mutation.replacement)
    }

    func reconcileInstalledProfileReconsiderationNextAttempt(
        _ mutation: InstallNextProfileReconsiderationAttemptMutation,
        at libraryRoot: URL,
        in scope: LibraryScope,
        holding lease: PortableInvocationLivenessLease
    ) throws -> CoachInvocation? {
        guard case let .reconsiderProfileChange(source, result) =
            mutation.base.intent
        else { return nil }
        let request = ProfileReconsiderationInvocationRequest(
            library: scope,
            chatID: mutation.base.chatID,
            sourceEffectIdentity: source,
            resultResponsePositionID: result
        )
        guard let livenessAuthority = lease.authority(for: request) else {
            throw PortableChatPersistenceError.ioFailure
        }
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(
            named: "staging",
            under: rootDescriptor
        )
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        let revalidate = invocationLivenessRevalidator(
            livenessAuthority,
            at: libraryRoot,
            in: scope,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
        try revalidate()
        guard try entryExists(
            named: mutation.base.id.rawValue,
            under: invocationsDescriptor
        ) else { return nil }
        let root = try openDirectory(
            named: mutation.base.id.rawValue,
            under: invocationsDescriptor
        )
        defer { Darwin.close(root) }
        let record = try loadInvocationDirectoryRecord(
            expectedInvocationID: mutation.base.id,
            expectedLibraryID: scope.libraryID,
            under: root,
            reconcileProofPartial: true,
            beforeRemoving: revalidate
        )
        guard record.publicationProof == nil else { return nil }
        if record.invocation.hasSameDurableProjection(as: mutation.replacement) {
            try flushDescriptor(root)
            try flushDescriptor(invocationsDescriptor)
            return mutation.replacement
        }
        guard record.invocation.hasSameDurableProjection(as: mutation.base) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return nil
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
        let collisionCandidate = DurablePublicIDCollisionCandidate(
            attemptID: candidate.id,
            authority: authority
        )
        let publicIDScanner = DurablePublicIDCollisionScanner(
            persistence: self,
            candidate: collisionCandidate
        )
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
                if let candidateID = publicIDScanner.candidate
                    .nextAttemptCollision(in: record.invocation)
                {
                    return candidateID.collision
                }
            case let .frozen(common, _):
                if let candidateID = publicIDScanner.candidate.collision(in: common) {
                    return candidateID.collision
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
            if chatID != activeChatID {
                if let candidateID = try siblingChatPublicIDCollision(
                    using: publicIDScanner,
                    chatID: chatID,
                    named: chatName,
                    under: chatsDescriptor,
                    mode: .stopAtFirstCollision
                ) {
                    return candidateID.collision
                }
                continue
            }

            let chatDescriptor = try openDirectory(
                named: chatName,
                under: chatsDescriptor
            )
            defer { Darwin.close(chatDescriptor) }
            let messagesDescriptor = try openDirectory(
                named: "messages",
                under: chatDescriptor
            )
            defer { Darwin.close(messagesDescriptor) }
            if let candidateID = try publicIDScanner.messageFileCollision(
                under: messagesDescriptor,
                mode: .stopAtFirstCollision
            ) {
                return candidateID.collision
            }
            switch try publicIDScanner.chatRootCollision(
                under: chatDescriptor,
                mode: .strict
            ) {
            case let .inspected(candidateID):
                if let candidateID { return candidateID.collision }
            case let .missing(error):
                throw error
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

    func abortInstalledProfileReconsideration(
        _ invocation: CoachInvocation,
        failure: PendingUserTurnFailure,
        at libraryRoot: URL,
        in scope: LibraryScope,
        holding lease: PortableInvocationLivenessLease
    ) throws -> PortableChatMutationResult {
        guard case let .reconsiderProfileChange(source, result) =
            invocation.intent
        else { throw PortableChatPersistenceError.invalidLayout }
        let request = ProfileReconsiderationInvocationRequest(
            library: scope,
            chatID: invocation.chatID,
            sourceEffectIdentity: source,
            resultResponsePositionID: result
        )
        guard let authority = lease.authority(for: request) else {
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
            if case .reconsiderProfileChange = terminalInvocation.intent {
                guard record.publicationProof == nil else {
                    throw PortableChatPersistenceError.invalidLayout
                }
                try removeInvocationDirectoryIfPresent(
                    terminalInvocation,
                    under: invocationsDescriptor,
                    beforeRemoving: revalidateLiveness
                )
                return .stale(current)
            }
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
        let artifacts = try publicationArtifacts(for: mutation)
        let proof = artifacts.proof
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

        let memoryDescriptor = try openDirectory(named: "memory", under: chatDescriptor)
        defer { Darwin.close(memoryDescriptor) }
        if let replacementMemory = mutation.replacementMemory {
            try revalidateLiveness()
            try installMemory(
                replacementMemory,
                under: memoryDescriptor
            )
        }

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
        if let proposalData = artifacts.proposalData {
            try revalidateLiveness()
            try installProfileProposal(
                proposalData,
                under: chatDescriptor
            )
        }
        if let publicationData = artifacts.profileEvidencePublicationData {
            try revalidateLiveness()
            try installProfileEvidencePublication(
                publicationData,
                under: chatDescriptor
            )
        }

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
                  reconcileTransients: false,
                  publicationProofAuthority: InvocationPublicationProofAuthority(
                      invocation: mutation.invocation,
                      proof: proof
                  )
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

    func publishProfileReconsideration(
        _ mutation: PublishProfileReconsiderationInvocationMutation,
        at libraryRoot: URL,
        in scope: LibraryScope,
        holding lease: PortableInvocationLivenessLease
    ) throws -> PortableChatMutationResult {
        guard case let .reconsiderProfileChange(source, result) =
            mutation.invocation.intent
        else { throw PortableChatPersistenceError.invalidLayout }
        let request = ProfileReconsiderationInvocationRequest(
            library: scope,
            chatID: mutation.invocation.chatID,
            sourceEffectIdentity: source,
            resultResponsePositionID: result
        )
        guard let authority = lease.authority(for: request) else {
            throw PortableChatPersistenceError.ioFailure
        }
        return try publishProfileReconsideration(
            mutation,
            at: libraryRoot,
            in: scope,
            livenessAuthority: authority
        )
    }

    private func publishProfileReconsideration(
        _ mutation: PublishProfileReconsiderationInvocationMutation,
        at libraryRoot: URL,
        in scope: LibraryScope,
        livenessAuthority: PortableInvocationLivenessAuthority
    ) throws -> PortableChatMutationResult {
        guard mutation.invocation.libraryID == scope.libraryID,
              mutation.invocation.chatID == mutation.base.chat.id,
              mutation.replacement.chat.id == mutation.base.chat.id
        else { throw PortableChatPersistenceError.libraryScopeMismatch }
        let artifacts = try publicationArtifacts(for: mutation)
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(
            named: "staging",
            under: rootDescriptor
        )
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        let revalidate = invocationLivenessRevalidator(
            livenessAuthority,
            at: libraryRoot,
            in: scope,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
        try revalidate()
        try reconcileInvocationPartials(
            under: invocationsDescriptor,
            beforeRemoving: revalidate
        )
        let chatsDescriptor = try openDirectory(
            named: "chats",
            under: rootDescriptor
        )
        defer { Darwin.close(chatsDescriptor) }
        let chatName = mutation.invocation.chatID.rawValue
        guard try entryExists(named: chatName, under: chatsDescriptor) else {
            throw PortableChatPersistenceError.chatMissing
        }
        let chatIdentity = try directoryIdentity(
            named: chatName,
            under: chatsDescriptor
        )
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
        try revalidate()

        if try entryExists(
            named: mutation.invocation.id.rawValue,
            under: invocationsDescriptor
        ) {
            let invocationRoot = try openDirectory(
                named: mutation.invocation.id.rawValue,
                under: invocationsDescriptor
            )
            defer { Darwin.close(invocationRoot) }
            let record = try loadInvocationDirectoryRecord(
                expectedInvocationID: mutation.invocation.id,
                expectedLibraryID: scope.libraryID,
                under: invocationRoot,
                beforeRemoving: revalidate
            )
            guard record.invocation.hasSameDurableProjection(
                as: mutation.invocation
            ) else { throw PortableChatPersistenceError.invalidLayout }
            if let installedProof = record.publicationProof {
                guard installedProof == artifacts.proof else {
                    throw PortableChatPersistenceError.invalidLayout
                }
                switch try reconcileProfileReconsiderationPublication(
                    invocation: mutation.invocation,
                    proof: installedProof,
                    record: record,
                    invocationRoot: invocationRoot,
                    invocationsDescriptor: invocationsDescriptor,
                    chatDescriptor: chatDescriptor,
                    beforeMutation: revalidate
                ) {
                case let .published(published):
                    return .committed(published)
                case let .base(base):
                    guard base == mutation.base else { return .stale(base) }
                }
            }
        }

        guard case let .readWrite(current) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.invocation.chatID,
            reconcileTransients: true,
            beforeDestructiveMutation: revalidate
        ) else { throw PortableChatPersistenceError.invalidLayout }
        if try isExactPublishedProfileReconsideration(
                artifacts.proof,
                invocation: mutation.invocation,
                aggregate: current,
                under: chatDescriptor
            )
        {
            return .committed(current)
        }
        guard current == mutation.base,
              try entryExists(
                  named: mutation.invocation.id.rawValue,
                  under: invocationsDescriptor
              )
        else { return .stale(current) }
        let invocationRoot = try openDirectory(
            named: mutation.invocation.id.rawValue,
            under: invocationsDescriptor
        )
        defer { Darwin.close(invocationRoot) }
        let record = try loadInvocationDirectoryRecord(
            expectedInvocationID: mutation.invocation.id,
            expectedLibraryID: scope.libraryID,
            under: invocationRoot,
            beforeRemoving: revalidate
        )
        guard record.invocation.hasSameDurableProjection(
            as: mutation.invocation
        ), record.publicationProof == nil,
            record.reconsiderationSourceEffectData == nil ||
                record.reconsiderationSourceEffectData ==
                    artifacts.sourceEffectData,
            record.reconsiderationReplacementProposalData == nil ||
                record.reconsiderationReplacementProposalData ==
                    artifacts.replacementProposalData
        else { return .stale(current) }
        let canonicalSourceName: String = switch mutation
            .reconsideration.sourceEffectIdentity
        {
        case .proposal: "proposal.json"
        case .evidencePublication: "profile-publication.json"
        }
        guard try boundedData(
            named: canonicalSourceName,
            under: chatDescriptor
        ) == artifacts.sourceEffectData,
            try boundedData(
                named: "profile-reconsideration.json",
                under: chatDescriptor
            ) == artifacts.profileReconsiderationData
        else { return .stale(current) }

        try installInvocationOwnedPublicationArtifact(
            artifacts.sourceEffectData,
            named: Self.reconsiderationSourceEffectName,
            under: invocationRoot,
            installedFault: .afterReconsiderationSourceEffectBackupInstall
        )
        if let replacementProposalData = artifacts.replacementProposalData {
            try installInvocationOwnedPublicationArtifact(
                replacementProposalData,
                named: Self.reconsiderationReplacementProposalName,
                under: invocationRoot,
                installedFault: .afterReconsiderationReplacementProposalInstall
            )
        }
        try installPublicationProof(artifacts.proof, under: invocationRoot)

        let memoryDescriptor = try openDirectory(
            named: "memory",
            under: chatDescriptor
        )
        defer { Darwin.close(memoryDescriptor) }
        if let replacementMemory = mutation.replacementMemory {
            try revalidate()
            try installMemory(replacementMemory, under: memoryDescriptor)
        }
        if let coachMessage = mutation.coachMessage {
            let messagesDescriptor = try openDirectory(
                named: "messages",
                under: chatDescriptor
            )
            defer { Darwin.close(messagesDescriptor) }
            try revalidate()
            try installMessage(
                coachMessage,
                under: messagesDescriptor,
                installedFault: .afterCoachMessageInstall
            )
        }

        let partialName = ".chat.json.\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString {
                    Darwin.unlinkat(chatDescriptor, $0, 0)
                }
            }
        }
        try writeExclusive(
            try encodeChat(mutation.replacement.chat),
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
        try fault(.afterPublicationManifestFileFlush)
        try revalidate()
        guard try directoryIdentity(
            named: chatName,
            under: chatsDescriptor
        ) == chatIdentity,
            try directoryIdentity(of: chatDescriptor) == chatIdentity,
            case let .readWrite(authority) = try loadChat(
                from: chatDescriptor,
                expectedID: mutation.invocation.chatID,
                reconcileTransients: false,
                publicationProofAuthority: InvocationPublicationProofAuthority(
                    invocation: mutation.invocation,
                    proof: artifacts.proof
                )
            ), authority == current,
            renameat(
                chatDescriptor,
                partialName,
                chatDescriptor,
                "chat.json"
            ) == 0
        else { return .stale(current) }
        partialExists = false
        try fault(.afterPublicationManifestInstall)
        try flushDescriptor(chatDescriptor)
        try fault(.afterPublicationManifestDirectoryFlush)
        try fault(.beforePublicationCleanup)
        try revalidate()
        let committedRecord = try loadInvocationDirectoryRecord(
            expectedInvocationID: mutation.invocation.id,
            expectedLibraryID: scope.libraryID,
            under: invocationRoot,
            beforeRemoving: revalidate
        )
        guard case let .published(published) = try
            reconcileProfileReconsiderationPublication(
                invocation: mutation.invocation,
                proof: artifacts.proof,
                record: committedRecord,
                invocationRoot: invocationRoot,
                invocationsDescriptor: invocationsDescriptor,
                chatDescriptor: chatDescriptor,
                beforeMutation: revalidate
            ), published == mutation.replacement
        else { throw PortableChatPersistenceError.invalidLayout }
        return .committed(published)
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
        let proof = try publicationArtifacts(for: mutation).proof
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

    func reconcileCommittedProfileReconsiderationPublication(
        _ mutation: PublishProfileReconsiderationInvocationMutation,
        at libraryRoot: URL,
        in scope: LibraryScope,
        holding lease: PortableInvocationLivenessLease
    ) throws -> ChatAggregate? {
        guard case let .reconsiderProfileChange(source, result) =
            mutation.invocation.intent
        else { throw PortableChatPersistenceError.invalidLayout }
        let request = ProfileReconsiderationInvocationRequest(
            library: scope,
            chatID: mutation.invocation.chatID,
            sourceEffectIdentity: source,
            resultResponsePositionID: result
        )
        guard let authority = lease.authority(for: request) else {
            throw PortableChatPersistenceError.ioFailure
        }
        return try reconcileCommittedProfileReconsiderationPublication(
            mutation,
            at: libraryRoot,
            in: scope,
            livenessAuthority: authority
        )
    }

    func reconcileCommittedProfileReconsiderationPublicationIfUnowned(
        _ mutation: PublishProfileReconsiderationInvocationMutation,
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
        if let published = try
            reconcileCommittedProfileReconsiderationPublication(
                mutation,
                at: libraryRoot,
                in: scope,
                livenessAuthority: authority
            )
        {
            return .published(published)
        }
        return .notPublished
    }

    private func reconcileCommittedProfileReconsiderationPublication(
        _ mutation: PublishProfileReconsiderationInvocationMutation,
        at libraryRoot: URL,
        in scope: LibraryScope,
        livenessAuthority: PortableInvocationLivenessAuthority?
    ) throws -> ChatAggregate? {
        guard mutation.invocation.libraryID == scope.libraryID else {
            throw PortableChatPersistenceError.libraryScopeMismatch
        }
        try fault(.beforePublicationReconciliationRead)
        let artifacts = try publicationArtifacts(for: mutation)
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(
            named: "staging",
            under: rootDescriptor
        )
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        let revalidate = invocationLivenessRevalidator(
            livenessAuthority,
            at: libraryRoot,
            in: scope,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
        try revalidate()
        try reconcileInvocationPartials(
            under: invocationsDescriptor,
            beforeRemoving: revalidate
        )
        let chatsDescriptor = try openDirectory(
            named: "chats",
            under: rootDescriptor
        )
        defer { Darwin.close(chatsDescriptor) }
        let chatName = mutation.invocation.chatID.rawValue
        guard try entryExists(named: chatName, under: chatsDescriptor) else {
            return nil
        }
        let chatDescriptor = try openDirectory(
            named: chatName,
            under: chatsDescriptor
        )
        defer { Darwin.close(chatDescriptor) }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        try revalidate()
        if try entryExists(
            named: mutation.invocation.id.rawValue,
            under: invocationsDescriptor
        ) {
            let invocationRoot = try openDirectory(
                named: mutation.invocation.id.rawValue,
                under: invocationsDescriptor
            )
            defer { Darwin.close(invocationRoot) }
            let record = try loadInvocationDirectoryRecord(
                expectedInvocationID: mutation.invocation.id,
                expectedLibraryID: scope.libraryID,
                under: invocationRoot,
                beforeRemoving: revalidate
            )
            guard record.invocation.hasSameDurableProjection(
                as: mutation.invocation
            ) else { throw PortableChatPersistenceError.invalidLayout }
            guard let proof = record.publicationProof else { return nil }
            guard proof == artifacts.proof else {
                throw PortableChatPersistenceError.invalidLayout
            }
            switch try reconcileProfileReconsiderationPublication(
                invocation: mutation.invocation,
                proof: proof,
                record: record,
                invocationRoot: invocationRoot,
                invocationsDescriptor: invocationsDescriptor,
                chatDescriptor: chatDescriptor,
                beforeMutation: revalidate
            ) {
            case .base:
                return nil
            case let .published(published):
                return published
            }
        }
        guard case let .readWrite(current) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.invocation.chatID,
            reconcileTransients: true,
            beforeDestructiveMutation: revalidate
        ), try isExactPublishedProfileReconsideration(
                artifacts.proof,
                invocation: mutation.invocation,
                aggregate: current,
                under: chatDescriptor
            )
        else { return nil }
        return current
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
        guard case let .answerPendingUserTurn(
            _,
            _,
            userMessageID,
            _,
            _,
            _,
            _
        ) = proof.intent else { return false }
        let messagesDescriptor = try openDirectory(
            named: "messages",
            under: chatDescriptor
        )
        defer { Darwin.close(messagesDescriptor) }
        let userData = try boundedData(
            named: "\(userMessageID.rawValue).json",
            under: messagesDescriptor
        )
        let coachData = try boundedData(
            named: "\(proof.coachMessageID.rawValue).json",
            under: messagesDescriptor
        )
        let user = try decodeMessage(userData)
        let coach = try decodeMessage(coachData)
        let proposalData: Data? = if try entryExists(
            named: "proposal.json",
            under: chatDescriptor
        ) {
            try boundedData(named: "proposal.json", under: chatDescriptor)
        } else {
            nil
        }
        let profileEvidencePublicationData: Data? = if try entryExists(
            named: "profile-publication.json",
            under: chatDescriptor
        ) {
            try boundedData(
                named: "profile-publication.json",
                under: chatDescriptor
            )
        } else {
            nil
        }
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
                coachMessage: coach,
                proposalData: proposalData,
                profileEvidencePublicationData: profileEvidencePublicationData
            )
        )
    }

    private func isExactPublishedProfileReconsideration(
        _ proof: InvocationPublicationProof,
        invocation: CoachInvocation,
        aggregate: ChatAggregate,
        under chatDescriptor: Int32
    ) throws -> Bool {
        guard case .reconsiderProfileChange = proof.intent else { return false }
        let messagesDescriptor = try openDirectory(
            named: "messages",
            under: chatDescriptor
        )
        defer { Darwin.close(messagesDescriptor) }
        let coachName = "\(proof.coachMessageID.rawValue).json"
        let coachData: Data? = if try entryExists(
            named: coachName,
            under: messagesDescriptor
        ) {
            try boundedData(named: coachName, under: messagesDescriptor)
        } else {
            nil
        }
        let proposalData: Data? = if try entryExists(
            named: "proposal.json",
            under: chatDescriptor
        ) {
            try boundedData(named: "proposal.json", under: chatDescriptor)
        } else {
            nil
        }
        return invocationEvidenceCodec.isExactPublishedProfileReconsideration(
            proof,
            invocation: invocation,
            evidence: PortableProfileReconsiderationPublicationCurrentEvidence(
                aggregate: aggregate,
                canonicalChat: try encodeChat(aggregate.chat),
                stableChat: try encodeStableChat(aggregate.chat),
                memory: try encodeMemory(aggregate.memory),
                coachMessageData: coachData,
                coachMessage: coachData.flatMap { try? decodeMessage($0) },
                replacementProposalData: proposalData
            )
        )
    }

    private func reconcileProfileReconsiderationPublication(
        invocation: CoachInvocation,
        proof: InvocationPublicationProof,
        record: InvocationDirectoryRecord,
        invocationRoot: Int32,
        invocationsDescriptor: Int32,
        chatDescriptor: Int32,
        beforeMutation: () throws -> Void
    ) throws -> PortableProfileReconsiderationPublicationReconciliation {
        guard case let .reconsiderProfileChange(
            sourceEffectIdentity,
            baseManifestRevision,
            _, _, _, _
        ) = proof.intent,
              record.publicationProof == proof,
              record.invocation.hasSameDurableProjection(as: invocation),
              let sourceBackup = record.reconsiderationSourceEffectData,
              invocationEvidenceCodec.proof(
                  proof,
                  bindsReconsiderationSourceEffectData: sourceBackup
              )
        else { throw PortableChatPersistenceError.invalidLayout }

        func dataIfPresent(_ name: String, under descriptor: Int32) throws -> Data? {
            guard try entryExists(named: name, under: descriptor) else {
                return nil
            }
            guard isRegularFile(named: name, under: descriptor) else {
                throw PortableChatPersistenceError.invalidLayout
            }
            return try boundedData(named: name, under: descriptor)
        }

        let chatData = try boundedData(named: "chat.json", under: chatDescriptor)
        let persistedChat = try decodeChat(chatData)
        guard persistedChat.id == invocation.chatID else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let reconsiderationData = try dataIfPresent(
            "profile-reconsideration.json",
            under: chatDescriptor
        )
        if let reconsiderationData,
           !invocationEvidenceCodec.proof(
               proof,
               bindsProfileReconsiderationData: reconsiderationData
           )
        {
            throw PortableChatPersistenceError.invalidLayout
        }
        let sourceName: String
        switch sourceEffectIdentity {
        case .proposal:
            sourceName = "proposal.json"
        case .evidencePublication:
            sourceName = "profile-publication.json"
        }
        let canonicalSourceData = try dataIfPresent(
            sourceName,
            under: chatDescriptor
        )
        let canonicalProposalData = try dataIfPresent(
            "proposal.json",
            under: chatDescriptor
        )
        let canonicalEvidenceData = try dataIfPresent(
            "profile-publication.json",
            under: chatDescriptor
        )
        let messagesDescriptor = try openDirectory(
            named: "messages",
            under: chatDescriptor
        )
        defer { Darwin.close(messagesDescriptor) }
        let coachName = "\(proof.coachMessageID.rawValue).json"
        let coachData = try dataIfPresent(coachName, under: messagesDescriptor)
        if proof.coachMessageSHA256 != nil {
            if let coachData,
               !invocationEvidenceCodec.proof(
                   proof,
                   bindsCoachMessageData: coachData
               )
            {
                throw PortableChatPersistenceError.invalidLayout
            }
        } else if coachData != nil {
            throw PortableChatPersistenceError.invalidLayout
        }

        let memoryDescriptor = try openDirectory(
            named: "memory",
            under: chatDescriptor
        )
        defer { Darwin.close(memoryDescriptor) }
        let selectedMemoryData = try boundedData(
            named: "\(persistedChat.currentMemoryID.rawValue).json",
            under: memoryDescriptor
        )

        if persistedChat.manifestRevision == baseManifestRevision,
           invocationEvidenceCodec.proof(
               proof,
               bindsReconsiderationBaseChatData: chatData
           )
        {
            guard let reconsiderationData,
                  canonicalSourceData == sourceBackup,
                  invocationEvidenceCodec.proof(
                      proof,
                      bindsReconsiderationBaseMemoryData: selectedMemoryData
                  ),
                  proof.coachMessageSHA256 == nil ||
                    coachData == nil ||
                    !persistedChat.messageIDs.contains(proof.coachMessageID)
            else { throw PortableChatPersistenceError.invalidLayout }
            if case .proposal = sourceEffectIdentity {
                guard canonicalEvidenceData == nil else {
                    throw PortableChatPersistenceError.invalidLayout
                }
            } else {
                guard canonicalProposalData == nil else {
                    throw PortableChatPersistenceError.invalidLayout
                }
            }
            guard case let .readWrite(base) = try loadChat(
                from: chatDescriptor,
                expectedID: invocation.chatID,
                reconcileTransients: true,
                publicationProofAuthority: InvocationPublicationProofAuthority(
                    invocation: invocation,
                    proof: proof
                ),
                beforeDestructiveMutation: beforeMutation
            ),
                invocationEvidenceCodec
                    .isExactProfileReconsiderationPublicationBase(
                        proof,
                        invocation: invocation,
                        aggregate: base,
                        canonicalChat: chatData,
                        memory: selectedMemoryData,
                        sourceEffect: sourceBackup,
                        profileReconsideration: reconsiderationData
                    )
            else { throw PortableChatPersistenceError.invalidLayout }
            try discardPrePublicationEvidence(
                from: invocationRoot,
                beforeRemoving: beforeMutation
            )
            return .base(base)
        }

        let hasExactPublishedManifest =
            persistedChat.manifestRevision == proof.publishedManifestRevision &&
            invocationEvidenceCodec.proof(
                proof,
                bindsPublishedChatData: chatData
            )
        let stablePersistedChatData = try encodeStableChat(persistedChat)
        let hasAllowedLaterManifest =
            persistedChat.manifestRevision > proof.publishedManifestRevision &&
            invocationEvidenceCodec.proof(
                proof,
                bindsStableChatData: stablePersistedChatData
            )
        guard hasExactPublishedManifest || hasAllowedLaterManifest,
              persistedChat.messageIDs == proof.messageIDs,
              invocationEvidenceCodec.proof(
                  proof,
                  bindsPublishedMemoryData: selectedMemoryData
              ),
              (proof.coachMessageSHA256 == nil) == (coachData == nil),
              (proof.coachMessageSHA256 != nil ||
                !persistedChat.messageIDs.contains(proof.coachMessageID))
        else { throw PortableChatPersistenceError.invalidLayout }

        let replacementData = record.reconsiderationReplacementProposalData
        guard (replacementData != nil) == (proof.proposalSHA256 != nil) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        switch sourceEffectIdentity {
        case .proposal:
            guard canonicalEvidenceData == nil,
                  canonicalProposalData == sourceBackup ||
                    canonicalProposalData == replacementData ||
                    (replacementData == nil && canonicalProposalData == nil)
            else { throw PortableChatPersistenceError.invalidLayout }
        case .evidencePublication:
            guard canonicalEvidenceData == sourceBackup ||
                    canonicalEvidenceData == nil,
                  canonicalProposalData == nil ||
                    canonicalProposalData == replacementData
            else { throw PortableChatPersistenceError.invalidLayout }
        }

        if let replacementData {
            if canonicalProposalData != replacementData {
                try beforeMutation()
                try installCommittedReconsiderationReplacementProposal(
                    replacementData,
                    under: chatDescriptor
                )
            }
            if case .evidencePublication = sourceEffectIdentity,
               canonicalEvidenceData != nil
            {
                try beforeMutation()
                try removeRegularFileIfPresent(
                    named: "profile-publication.json",
                    under: chatDescriptor
                )
                try flushDescriptor(chatDescriptor)
            }
        } else if canonicalSourceData != nil {
            try beforeMutation()
            try removeRegularFileIfPresent(
                named: sourceName,
                under: chatDescriptor
            )
            try flushDescriptor(chatDescriptor)
        }
        if reconsiderationData != nil {
            try beforeMutation()
            try removeRegularFileIfPresent(
                named: "profile-reconsideration.json",
                under: chatDescriptor
            )
            try flushDescriptor(chatDescriptor)
        }

        guard case let .readWrite(published) = try loadChat(
            from: chatDescriptor,
            expectedID: invocation.chatID,
            reconcileTransients: true,
            beforeDestructiveMutation: beforeMutation
        ),
            try isExactPublishedProfileReconsideration(
                proof,
                invocation: invocation,
                aggregate: published,
                under: chatDescriptor
            )
        else { throw PortableChatPersistenceError.invalidLayout }
        try fault(.beforeReconsiderationPublishedInvocationRetirement)
        try atomicallyRetirePublishedInvocationDirectory(
            invocation,
            under: invocationsDescriptor,
            beforeMutation: beforeMutation
        )
        return .published(published)
    }

    fileprivate func reconcileCommittedCreate(
        _ seed: NewChatSeed,
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

    func replaceProfileReconsideration(
        authority: InvocationProfileReconsiderationAuthority,
        failure: PendingUserTurnFailure,
        at libraryRoot: URL,
        holding lease: PortableInvocationLivenessLease
    ) throws -> PortableChatMutationResult {
        let replacement = authority.reconsideration.replacingFailure(failure)
        return try replaceProfileReconsideration(
            expectedAggregate: authority.aggregate,
            expected: authority.reconsideration,
            replacement: replacement,
            at: libraryRoot,
            in: authority.request.library,
            livenessAuthority: lease.authority(for: authority.request),
            lease: lease
        )
    }

    func discardProvisionalProfileReconsideration(
        authority: InvocationProfileReconsiderationAuthority,
        at libraryRoot: URL,
        holding lease: PortableInvocationLivenessLease
    ) throws -> PortableChatMutationResult {
        guard let livenessAuthority = lease.authority(for: authority.request) else {
            throw PortableChatPersistenceError.ioFailure
        }
        let rootDescriptor = try openLibraryRoot(
            at: libraryRoot,
            in: authority.request.library
        )
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(
            named: "staging",
            under: rootDescriptor
        )
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        let revalidate = invocationLivenessRevalidator(
            livenessAuthority,
            at: libraryRoot,
            in: authority.request.library,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
        try revalidate()
        let chatsDescriptor = try openDirectory(
            named: "chats",
            under: rootDescriptor
        )
        defer { Darwin.close(chatsDescriptor) }
        guard try entryExists(
            named: authority.request.chatID.rawValue,
            under: chatsDescriptor
        ) else { return .stale(authority.aggregate) }
        let chatDescriptor = try openDirectory(
            named: authority.request.chatID.rawValue,
            under: chatsDescriptor
        )
        defer { Darwin.close(chatDescriptor) }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        guard case let .readWrite(current) = try loadChat(
            from: chatDescriptor,
            expectedID: authority.request.chatID,
            reconcileTransients: true,
            beforeDestructiveMutation: revalidate
        ) else { return .frozen(FrozenChatSnapshot(
            chatID: authority.request.chatID,
            reason: .corrupt
        )) }
        let replacement = try ChatAggregate(
            chat: authority.aggregate.chat,
            memory: authority.aggregate.memory,
            messages: authority.aggregate.messages,
            profileEffect: authority.aggregate.profileEffect
        )
        if current == replacement { return .committed(current) }
        guard current == authority.aggregate,
              current.profileReconsideration == authority.reconsideration,
              authority.reconsideration.failure == nil
        else { return .stale(current) }
        try revalidate()
        try removeRegularFileIfPresent(
            named: "profile-reconsideration.json",
            under: chatDescriptor
        )
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: authority.request.chatID,
            reconcileTransients: true,
            beforeDestructiveMutation: revalidate
        ), reopened == replacement else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return .committed(reopened)
    }

    private func replaceProfileReconsideration(
        expectedAggregate: ChatAggregate,
        expected: ProfileReconsideration,
        replacement: ProfileReconsideration,
        at libraryRoot: URL,
        in scope: LibraryScope,
        livenessAuthority: PortableInvocationLivenessAuthority?,
        lease: PortableInvocationLivenessLease?
    ) throws -> PortableChatMutationResult {
        guard let livenessAuthority else {
            throw PortableChatPersistenceError.ioFailure
        }
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(rootDescriptor) }
        let stagingDescriptor = try openDirectory(
            named: "staging",
            under: rootDescriptor
        )
        defer { Darwin.close(stagingDescriptor) }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }
        let invocationsDescriptor = try openDirectory(
            named: "invocations",
            under: rootDescriptor
        )
        defer { Darwin.close(invocationsDescriptor) }
        let revalidate = invocationLivenessRevalidator(
            livenessAuthority,
            at: libraryRoot,
            in: scope,
            under: rootDescriptor,
            invocationsDescriptor: invocationsDescriptor
        )
        try revalidate()
        let chatsDescriptor = try openDirectory(
            named: "chats",
            under: rootDescriptor
        )
        defer { Darwin.close(chatsDescriptor) }
        guard try entryExists(
            named: expectedAggregate.chat.id.rawValue,
            under: chatsDescriptor
        ) else { return .stale(expectedAggregate) }
        let chatDescriptor = try openDirectory(
            named: expectedAggregate.chat.id.rawValue,
            under: chatsDescriptor
        )
        defer { Darwin.close(chatDescriptor) }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        guard case let .readWrite(current) = try loadChat(
            from: chatDescriptor,
            expectedID: expectedAggregate.chat.id,
            reconcileTransients: true,
            beforeDestructiveMutation: revalidate
        ) else { throw PortableChatPersistenceError.invalidLayout }
        let replacementAggregate = try ChatAggregate(
            chat: expectedAggregate.chat,
            memory: expectedAggregate.memory,
            messages: expectedAggregate.messages,
            profileEffect: expectedAggregate.profileEffect,
            profileReconsideration: replacement
        )
        if current == replacementAggregate { return .committed(current) }
        guard current == expectedAggregate,
              current.profileReconsideration == expected
        else { return .stale(current) }
        let partialName =
            ".profile-reconsideration.json.\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString {
                    Darwin.unlinkat(chatDescriptor, $0, 0)
                }
            }
        }
        try writeExclusive(
            try encodeProfileReconsideration(replacement),
            named: partialName,
            under: chatDescriptor
        )
        partialExists = true
        let descriptor = try openRegularFile(
            named: partialName,
            under: chatDescriptor
        )
        defer { Darwin.close(descriptor) }
        try flushDescriptor(descriptor)
        try revalidate()
        guard renameat(
            chatDescriptor,
            partialName,
            chatDescriptor,
            "profile-reconsideration.json"
        ) == 0 else { throw PortableChatPersistenceError.ioFailure }
        partialExists = false
        try flushDescriptor(chatDescriptor)
        if let lease {
            let replacementLease = try
                acquireAndValidateProfileReconsiderationFileLease(
                    replacement,
                    under: chatDescriptor
                )
            try lease.rebindProfileReconsiderationLease(replacementLease)
        }
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: expectedAggregate.chat.id,
            reconcileTransients: true,
            beforeDestructiveMutation: revalidate
        ), reopened == replacementAggregate else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return .committed(reopened)
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

    func assessProfileEffect(
        _ request: AssessProfileEffectRequest,
        at libraryRoot: URL
    ) throws -> PortableProfileEffectAssessmentResult {
        try withReconciledProfileWritesBeforeChatExposure(
            at: libraryRoot,
            in: request.library
        ) { root, stagingDescriptor, stagingIdentity in
            let rootDescriptor = root.rootDescriptor
            let profileIdentity = try directoryIdentity(
                named: "profile",
                under: rootDescriptor
            )
            let profileDescriptor = try openDirectory(
                named: "profile",
                under: rootDescriptor
            )
            defer { Darwin.close(profileDescriptor) }
            guard try directoryIdentity(of: profileDescriptor) == profileIdentity
            else { throw PortableChatPersistenceError.invalidLayout }

            let revisionsIdentity = try directoryIdentity(
                named: "revisions",
                under: profileDescriptor
            )
            let revisionsDescriptor = try openDirectory(
                named: "revisions",
                under: profileDescriptor
            )
            defer { Darwin.close(revisionsDescriptor) }
            guard try directoryIdentity(of: revisionsDescriptor) ==
                    revisionsIdentity
            else { throw PortableChatPersistenceError.invalidLayout }

            let chatsIdentity = try directoryIdentity(
                named: "chats",
                under: rootDescriptor
            )
            let chatsDescriptor = try openDirectory(
                named: "chats",
                under: rootDescriptor
            )
            defer { Darwin.close(chatsDescriptor) }
            guard try directoryIdentity(of: chatsDescriptor) == chatsIdentity
            else { throw PortableChatPersistenceError.invalidLayout }

            let chatName = request.base.chat.id.rawValue
            guard try entryExists(named: chatName, under: chatsDescriptor) else {
                throw PortableChatPersistenceError.chatMissing
            }
            let chatIdentity = try directoryIdentity(
                named: chatName,
                under: chatsDescriptor
            )
            let chatDescriptor = try openDirectory(
                named: chatName,
                under: chatsDescriptor
            )
            defer { Darwin.close(chatDescriptor) }
            guard try directoryIdentity(of: chatDescriptor) == chatIdentity
            else { throw PortableChatPersistenceError.invalidLayout }
            try acquireExclusiveMutationLock(on: chatDescriptor)
            defer { releaseMutationLock(on: chatDescriptor) }

            let revalidate = {
                try self.revalidateConfiguredRootAuthority(root)
                try self.revalidateLibraryAuthority(
                    libraryID: request.library.libraryID,
                    under: rootDescriptor
                )
                guard try self.directoryIdentity(
                    named: "staging",
                    under: rootDescriptor
                ) == stagingIdentity,
                    try self.directoryIdentity(of: stagingDescriptor) ==
                        stagingIdentity,
                    try self.directoryIdentity(
                        named: "profile",
                        under: rootDescriptor
                    ) == profileIdentity,
                    try self.directoryIdentity(of: profileDescriptor) ==
                        profileIdentity,
                    try self.directoryIdentity(
                        named: "revisions",
                        under: profileDescriptor
                    ) == revisionsIdentity,
                    try self.directoryIdentity(of: revisionsDescriptor) ==
                        revisionsIdentity,
                    try self.directoryIdentity(
                        named: "chats",
                        under: rootDescriptor
                    ) == chatsIdentity,
                    try self.directoryIdentity(of: chatsDescriptor) ==
                        chatsIdentity,
                    try self.directoryIdentity(
                        named: chatName,
                        under: chatsDescriptor
                    ) == chatIdentity,
                    try self.directoryIdentity(of: chatDescriptor) == chatIdentity
                else { throw PortableChatPersistenceError.invalidLayout }
            }
            try revalidate()
            guard case let .readWrite(current) = try loadChat(
                from: chatDescriptor,
                expectedID: request.base.chat.id,
                reconcileTransients: true,
                beforeDestructiveMutation: revalidate
            ), current == request.base,
                let effect = current.profileEffect,
                effect.identity == request.sourceEffectIdentity
            else { throw PortableChatPersistenceError.invalidLayout }

            let headData = try boundedData(
                named: "head.json",
                under: profileDescriptor
            )
            let head = try PortableLibraryPersistence().decodeProfileHead(headData)
            let selectedRevision = try loadSelectedProfileRevision(
                head,
                under: profileDescriptor
            )
            let latestProfile = selectedRevision.map(ProfileSnapshot.init) ??
                ProfileSnapshot(
                    nullAtStatementGeneration: head.statementGeneration
                )
            let sourceProvenance = try profileEffectSourceProvenance(
                effect,
                in: current
            )
            let baseProfile = try loadProfileSnapshot(
                proving: sourceProvenance,
                under: profileDescriptor
            )
            try validateProfileEffect(effect, against: baseProfile)

            let result: PortableProfileEffectAssessmentResult
            if effect.requiresReconsideration(against: latestProfile) {
                result = .stale(
                    current,
                    try ProfileReconsiderationBasis(
                        sourceEffect: effect,
                        baseProfile: baseProfile,
                        latestProfile: latestProfile
                    )
                )
            } else {
                result = .current(current)
            }

            try revalidate()
            guard try boundedData(
                named: "head.json",
                under: profileDescriptor
            ) == headData,
                try PortableLibraryPersistence().decodeProfileHead(headData) == head,
                try loadSelectedProfileRevision(
                    head,
                    under: profileDescriptor
                ) == selectedRevision,
                try loadProfileSnapshot(
                    proving: sourceProvenance,
                    under: profileDescriptor
                ) == baseProfile,
                case let .readWrite(reopened) = try loadChat(
                    from: chatDescriptor,
                    expectedID: current.chat.id,
                    reconcileTransients: false
                ), reopened == current
            else { throw PortableChatPersistenceError.invalidLayout }
            try revalidate()
            return result
        }
    }

    func acceptProfileProposal(
        _ mutation: AcceptProfileProposalMutation,
        at libraryRoot: URL
    ) throws -> PortableChatMutationResult {
        guard mutation.base.chat.id == mutation.base.profileProposal?.chatID else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return try withProfileProposalMutationAuthority(
            at: libraryRoot,
            in: mutation.library,
            chatID: mutation.base.chat.id
        ) { authority in
            let chatDescriptor = authority.chatDescriptor
            let profileDescriptor = authority.profileDescriptor
            let revalidate = {
                try self.revalidateProfileProposalMutationAuthority(
                    authority,
                    at: libraryRoot,
                    in: mutation.library
                )
            }

        guard case let .readWrite(current) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.base.chat.id,
            reconcileTransients: true,
            allowsProfileWriteIntent: true,
            beforeDestructiveMutation: revalidate
        ) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let resolvedBase = try aggregateResolvingProfileProposal(mutation.base)
        guard current == mutation.base || current == resolvedBase,
              let proposal = mutation.base.profileProposal,
              proposal.id == mutation.proposalID
        else { return .stale(current) }
        let hasWriteIntent = try entryExists(
            named: "profile-write.json",
            under: chatDescriptor
        )
        let proposalData: Data
        if try entryExists(named: "proposal.json", under: chatDescriptor) {
            proposalData = try boundedData(
                named: "proposal.json",
                under: chatDescriptor
            )
        } else if hasWriteIntent {
            // A committed head may outlive proposal cleanup after a crash. The
            // durable v2 intent still binds these canonical proposal bytes.
            proposalData = try encodeProfileProposal(proposal)
        } else {
            return .stale(current)
        }

        guard !(try hasForeignProfileWriteIntent(
            excluding: authority.chatName,
            under: authority.chatsDescriptor
        )) else { throw PortableChatPersistenceError.profileWriteInProgress }
        try revalidate()
        let headData = try boundedData(
            named: "head.json",
            under: profileDescriptor
        )
        let head = try PortableLibraryPersistence().decodeProfileHead(headData)

        let intent: ProfileWriteIntent
        let intentData: Data
        if hasWriteIntent {
            intentData = try boundedData(
                named: "profile-write.json",
                under: chatDescriptor
            )
            intent = try decodeProfileWriteIntent(
                intentData,
                proposal: proposal,
                proposalData: proposalData
            )
            guard intent.id == mutation.writeIntentID,
                  intent.proposalID == mutation.proposalID,
                  intent.chatID == mutation.base.chat.id,
                  intent.intendedRevisionID == mutation.intendedRevisionID
            else { return .stale(current) }
            // Every UI retry samples a fresh clock value. Once the intent is
            // durable, its original timestamp owns the exact revision bytes.
            try revalidate()
            try flushDescriptor(chatDescriptor)
            guard try boundedData(
                named: "profile-write.json",
                under: chatDescriptor
            ) == intentData,
                try decodeProfileWriteIntent(
                    intentData,
                    proposal: proposal,
                    proposalData: proposalData
                ) == intent
            else { throw PortableChatPersistenceError.invalidLayout }
            try revalidate()
        } else {
            guard current == mutation.base,
                  current.profileProposal == proposal,
                  head.statementGeneration == proposal.baseProfile.statementGeneration,
                  (head.authority.currentRevisionID == nil) ==
                    (proposal.baseProfile.revisionID == nil)
            else { return .stale(current) }
            do {
                intent = try ProfileWriteIntent(
                    id: mutation.writeIntentID,
                    proposal: proposal,
                    expectedHead: head,
                    intendedRevisionID: mutation.intendedRevisionID,
                    createdAt: mutation.acceptedAt
                )
            } catch {
                return .stale(current)
            }
            let intendedRevision: ProfileRevision
            do {
                intendedRevision = try proposal.applying(
                    to: loadSelectedProfileRevision(
                        head,
                        under: profileDescriptor
                    ),
                    currentHeadGeneration: head.generation,
                    intendedRevisionID: intent.intendedRevisionID,
                    createdAt: intent.createdAt
                )
            } catch ProfileProposalApplicationError.staleSemanticBase {
                return .stale(current)
            } catch ProfileProposalApplicationError.targetNotFound {
                return .stale(current)
            } catch ProfileProposalApplicationError.targetMismatch {
                return .stale(current)
            } catch {
                throw PortableChatPersistenceError.invalidLayout
            }
            let intendedRevisionData = try encodeProfileRevision(
                intendedRevision
            )
            intentData = try encodeProfileWriteIntent(
                intent,
                proposalData: proposalData,
                intendedRevisionData: intendedRevisionData
            )
            try installProfileWriteIntent(
                intentData,
                under: chatDescriptor,
                beforeMutation: revalidate
            )
        }

        return try finishProfileProposalAcceptance(
            proposal: proposal,
            intent: intent,
            intentData: intentData,
            proposalData: proposalData,
            current: current,
            resolvedBase: resolvedBase,
            initialHeadData: headData,
            initialHead: head,
            chatDescriptor: chatDescriptor,
            profileDescriptor: profileDescriptor,
            revisionsDescriptor: authority.revisionsDescriptor,
            publicationsDescriptor: authority.publicationsDescriptor,
            beforeMutation: revalidate
        )
        }
    }

    func discardProfileProposal(
        _ mutation: DiscardProfileProposalMutation,
        at libraryRoot: URL
    ) throws -> PortableChatMutationResult {
        try withProfileProposalMutationAuthority(
            at: libraryRoot,
            in: mutation.library,
            chatID: mutation.base.chat.id
        ) { authority in
            let chatDescriptor = authority.chatDescriptor
            let profileDescriptor = authority.profileDescriptor
            let revalidate = {
                try self.revalidateProfileProposalMutationAuthority(
                    authority,
                    at: libraryRoot,
                    in: mutation.library
                )
            }
            guard case let .readWrite(current) = try loadChat(
                from: chatDescriptor,
                expectedID: mutation.base.chat.id,
                reconcileTransients: true,
                allowsProfileWriteIntent: true,
                beforeDestructiveMutation: revalidate
            ) else {
                throw PortableChatPersistenceError.invalidLayout
            }
            let resolved = try aggregateResolvingProfileProposal(mutation.base)
            guard current == mutation.base || current == resolved,
                  let proposal = mutation.base.profileProposal,
                  proposal.id == mutation.proposalID
            else { return .stale(current) }
            try revalidate()

            let retainedWriteIntentData: Data?
            if try entryExists(
                named: "profile-write.json",
                under: chatDescriptor
            ) {
                guard !(try hasForeignProfileWriteIntent(
                    excluding: authority.chatName,
                    under: authority.chatsDescriptor
                )) else {
                    throw PortableChatPersistenceError.profileWriteInProgress
                }
                let intentData = try boundedData(
                    named: "profile-write.json",
                    under: chatDescriptor
                )
                let proposalData = try boundedData(
                    named: "proposal.json",
                    under: chatDescriptor
                )
                let intent = try decodeProfileWriteIntent(
                    intentData,
                    proposal: proposal,
                    proposalData: proposalData
                )
                let acceptance = try AcceptProfileProposalMutation(
                    library: mutation.library,
                    base: mutation.base,
                    proposalID: proposal.id,
                    acceptedAt: intent.createdAt
                )
                guard intent.id == acceptance.writeIntentID,
                      intent.proposalID == proposal.id,
                      intent.chatID == mutation.base.chat.id,
                      intent.intendedRevisionID == acceptance.intendedRevisionID
                else { return .stale(current) }
                try revalidate()
                try flushDescriptor(chatDescriptor)
                guard try boundedData(
                    named: "profile-write.json",
                    under: chatDescriptor
                ) == intentData else {
                    throw PortableChatPersistenceError.invalidLayout
                }
                try revalidate()

                let head = try PortableLibraryPersistence().decodeProfileHead(
                    boundedData(named: "head.json", under: profileDescriptor)
                )
                if try headSelectsIntendedProfileRevision(
                    head,
                    intent: intent,
                    proposal: proposal,
                    under: profileDescriptor
                ) {
                    try makeIntendedProfileHeadDurable(
                        head,
                        intent: intent,
                        proposal: proposal,
                        under: profileDescriptor,
                        beforeMutation: revalidate
                    )
                    let accepted = try finishAcceptedProfileProposal(
                        expected: resolved,
                        chatDescriptor: chatDescriptor,
                        beforeMutation: revalidate
                    )
                    return .stale(accepted)
                }
                guard current == mutation.base,
                      current.profileProposal == proposal,
                      head.authority == intent.expectedHead
                else { return .stale(current) }
                try removeUncommittedProfileRevisionIfPresent(
                    intent: intent,
                    proposal: proposal,
                    profileDescriptor: profileDescriptor,
                    revisionsDescriptor: authority.revisionsDescriptor,
                    publicationsDescriptor: authority.publicationsDescriptor,
                    beforeMutation: revalidate
                )
                try revalidate()
                let provedHead = try PortableLibraryPersistence()
                    .decodeProfileHead(
                        boundedData(
                            named: "head.json",
                            under: profileDescriptor
                        )
                    )
                guard provedHead.authority == intent.expectedHead else {
                    return .stale(current)
                }
                retainedWriteIntentData = intentData
            } else {
                guard current == mutation.base,
                      current.profileProposal == proposal
                else { return .stale(current) }
                retainedWriteIntentData = nil
            }
            return .committed(
                try finishDiscardedProfileProposal(
                    expected: resolved,
                    retainedWriteIntentData: retainedWriteIntentData,
                    chatDescriptor: chatDescriptor,
                    beforeMutation: revalidate
                )
            )
        }
    }

    func reconcileCommittedProfileProposalAcceptance(
        _ mutation: AcceptProfileProposalMutation,
        at libraryRoot: URL
    ) throws -> ChatAggregate? {
        do {
            return try withProfileProposalMutationAuthority(
                at: libraryRoot,
                in: mutation.library,
                chatID: mutation.base.chat.id
            ) { authority in
                let chatDescriptor = authority.chatDescriptor
                let profileDescriptor = authority.profileDescriptor
                let revalidate = {
                    try self.revalidateProfileProposalMutationAuthority(
                        authority,
                        at: libraryRoot,
                        in: mutation.library
                    )
                }
                guard let proposal = mutation.base.profileProposal,
                      !(try hasForeignProfileWriteIntent(
                          excluding: authority.chatName,
                          under: authority.chatsDescriptor
                      ))
                else { return nil }
                try revalidate()
                let head = try PortableLibraryPersistence().decodeProfileHead(
                    boundedData(named: "head.json", under: profileDescriptor)
                )
                if try entryExists(
                    named: "profile-write.json",
                    under: chatDescriptor
                ) {
                    let intentData = try boundedData(
                        named: "profile-write.json",
                        under: chatDescriptor
                    )
                    let proposalData = if try entryExists(
                        named: "proposal.json",
                        under: chatDescriptor
                    ) {
                        try boundedData(
                            named: "proposal.json",
                            under: chatDescriptor
                        )
                    } else {
                        try encodeProfileProposal(proposal)
                    }
                    let intent = try decodeProfileWriteIntent(
                        intentData,
                        proposal: proposal,
                        proposalData: proposalData
                    )
                    guard intent.id == mutation.writeIntentID,
                          intent.proposalID == mutation.proposalID,
                          intent.chatID == mutation.base.chat.id,
                          intent.intendedRevisionID == mutation.intendedRevisionID,
                          try headSelectsIntendedProfileRevision(
                              head,
                              intent: intent,
                              proposal: proposal,
                              under: profileDescriptor
                          )
                    else { return nil }
                    try makeIntendedProfileHeadDurable(
                        head,
                        intent: intent,
                        proposal: proposal,
                        under: profileDescriptor,
                        beforeMutation: revalidate
                    )
                } else {
                    guard !(try entryExists(
                        named: "proposal.json",
                        under: chatDescriptor
                    )), try headSelectsMutationProfileRevision(
                        head,
                        mutation: mutation,
                        proposal: proposal,
                        under: profileDescriptor
                    ) else { return nil }
                    try makeMutationProfileHeadDurable(
                        head,
                        mutation: mutation,
                        proposal: proposal,
                        under: profileDescriptor,
                        beforeMutation: revalidate
                    )
                }
                return try finishAcceptedProfileProposal(
                    expected: aggregateResolvingProfileProposal(mutation.base),
                    chatDescriptor: chatDescriptor,
                    beforeMutation: revalidate
                )
            }
        } catch PortableChatPersistenceError.chatMissing {
            return nil
        }
    }

    func reconcileCommittedProfileProposalDiscard(
        _ mutation: DiscardProfileProposalMutation,
        at libraryRoot: URL
    ) throws -> ChatAggregate? {
        do {
            return try withProfileProposalMutationAuthority(
                at: libraryRoot,
                in: mutation.library,
                chatID: mutation.base.chat.id
            ) { authority in
                let chatDescriptor = authority.chatDescriptor
                let revalidate = {
                    try self.revalidateProfileProposalMutationAuthority(
                        authority,
                        at: libraryRoot,
                        in: mutation.library
                    )
                }
                guard let proposal = mutation.base.profileProposal,
                      !(try entryExists(
                          named: "profile-write.json",
                          under: chatDescriptor
                      )), !(try entryExists(
                          named: "proposal.json",
                          under: chatDescriptor
                      ))
                else { return nil }
                try revalidate()
                try flushDescriptor(chatDescriptor)
                try revalidate()
                guard case let .readWrite(reopened) = try loadChat(
                    from: chatDescriptor,
                    expectedID: mutation.base.chat.id,
                    reconcileTransients: true,
                    beforeDestructiveMutation: revalidate
                ), reopened == (try aggregateResolvingProfileProposal(
                    mutation.base
                )) else { return nil }
                let head = try PortableLibraryPersistence().decodeProfileHead(
                    boundedData(
                        named: "head.json",
                        under: authority.profileDescriptor
                    )
                )
                guard head.statementGeneration ==
                        proposal.baseProfile.statementGeneration
                else { return nil }
                try revalidate()
                return reopened
            }
        } catch PortableChatPersistenceError.chatMissing {
            return nil
        }
    }

    func publishProfileEvidence(
        _ mutation: PublishProfileEvidenceMutation,
        at libraryRoot: URL
    ) throws -> PortableChatMutationResult {
        guard let publication = mutation.base.profileEvidencePublication,
              mutation.base.chat.id == publication.chatID,
              mutation.responsePositionID == publication.responsePositionID
        else { throw PortableChatPersistenceError.invalidLayout }
        return try withProfileProposalMutationAuthority(
            at: libraryRoot,
            in: mutation.library,
            chatID: mutation.base.chat.id
        ) { authority in
            let revalidate = {
                try self.revalidateProfileProposalMutationAuthority(
                    authority,
                    at: libraryRoot,
                    in: mutation.library
                )
            }
            guard case let .readWrite(current) = try loadChat(
                from: authority.chatDescriptor,
                expectedID: mutation.base.chat.id,
                reconcileTransients: true,
                beforeDestructiveMutation: revalidate
            ) else { throw PortableChatPersistenceError.invalidLayout }
            let resolved = try aggregateResolvingProfileEvidencePublication(
                mutation.base
            )
            guard current == mutation.base || current == resolved else {
                return .stale(current)
            }
            guard !(try hasForeignProfileWriteIntent(
                excluding: authority.chatName,
                under: authority.chatsDescriptor
            )) else { throw PortableChatPersistenceError.profileWriteInProgress }
            try revalidate()
            let headData = try boundedData(
                named: "head.json",
                under: authority.profileDescriptor
            )
            let head = try PortableLibraryPersistence().decodeProfileHead(headData)
            if try headSelectsProfileEvidenceRevision(
                head,
                mutation: mutation,
                publication: publication,
                under: authority.profileDescriptor
            ) {
                try makeProfileEvidenceHeadDurable(
                    head,
                    mutation: mutation,
                    publication: publication,
                    under: authority.profileDescriptor,
                    beforeMutation: revalidate
                )
                return .committed(
                    try finishProfileEvidencePublication(
                        expected: resolved,
                        chatDescriptor: authority.chatDescriptor,
                        beforeMutation: revalidate
                    )
                )
            }
            guard current == mutation.base,
                  current.profileEvidencePublication == publication,
                  let selectedRevision = try loadSelectedProfileRevision(
                      head,
                      under: authority.profileDescriptor
                  )
            else { return .stale(current) }

            let application: ProfileEvidencePublicationApplicationResult
            do {
                application = try selectedRevision.applying(
                    publication,
                    intendedRevisionID: mutation.intendedRevisionID,
                    createdAt: publication.createdAt
                )
            } catch ProfileEvidencePublicationApplicationError.staleTarget {
                return .stale(current)
            } catch ProfileEvidencePublicationApplicationError
                .intendedRevisionIDCollision
            {
                return .stale(current)
            } catch {
                throw PortableChatPersistenceError.invalidLayout
            }
            switch application {
            case .noOp:
                _ = try removeProvedUnselectedProfileEvidenceRevisionIfPresent(
                    intendedRevisionID: mutation.intendedRevisionID,
                    publication: publication,
                    currentHeadData: headData,
                    currentHead: head,
                    profileDescriptor: authority.profileDescriptor,
                    revisionsDescriptor: authority.revisionsDescriptor,
                    publicationsDescriptor: authority.publicationsDescriptor,
                    beforeMutation: revalidate
                )
                return .committed(
                    try finishProfileEvidencePublication(
                        expected: resolved,
                        chatDescriptor: authority.chatDescriptor,
                        beforeMutation: revalidate
                    )
                )
            case let .changed(revision):
                let revisionData = try encodeProfileRevision(revision)
                let digest = Self.sha256(revisionData)
                try prepareProfileEvidenceRevisionSlot(
                    for: revision,
                    publication: publication,
                    currentHeadData: headData,
                    currentHead: head,
                    profileDescriptor: authority.profileDescriptor,
                    revisionsDescriptor: authority.revisionsDescriptor,
                    publicationsDescriptor: authority.publicationsDescriptor,
                    beforeMutation: revalidate
                )
                try installProfileRevision(
                    revision,
                    data: revisionData,
                    digest: digest,
                    revisionsDescriptor: authority.revisionsDescriptor,
                    publicationsDescriptor: authority.publicationsDescriptor,
                    beforeMutation: revalidate
                )
                try fault(.afterProfileRevisionInstall)
                let replacementHead = ProfileHead(
                    generation: revision.generation,
                    statementGeneration: revision.statementGeneration,
                    selection: .revision(
                        try ProfileRevisionPointer(
                            revisionID: revision.revisionID,
                            sha256: digest
                        )
                    ),
                    updatedAt: publication.createdAt
                )
                let proveInstalledRevision = {
                    try revalidate()
                    try self.requireExactInstalledProfileRevision(
                        revision,
                        data: revisionData,
                        digest: digest,
                        under: authority.revisionsDescriptor
                    )
                }
                guard try compareAndSwapProfileHead(
                    expectedData: headData,
                    expected: head,
                    replacement: replacementHead,
                    under: authority.profileDescriptor,
                    beforeInstalling: proveInstalledRevision
                ) else { return .stale(current) }
                try makeProfileEvidenceHeadDurable(
                    replacementHead,
                    mutation: mutation,
                    publication: publication,
                    under: authority.profileDescriptor,
                    beforeMutation: revalidate
                )
                return .committed(
                    try finishProfileEvidencePublication(
                        expected: resolved,
                        chatDescriptor: authority.chatDescriptor,
                        beforeMutation: revalidate
                    )
                )
            }
        }
    }

    func discardProfileEvidencePublication(
        _ mutation: DiscardProfileEvidencePublicationMutation,
        at libraryRoot: URL
    ) throws -> PortableChatMutationResult {
        guard let publication = mutation.base.profileEvidencePublication,
              mutation.base.chat.id == publication.chatID,
              mutation.responsePositionID == publication.responsePositionID
        else { throw PortableChatPersistenceError.invalidLayout }
        return try withProfileProposalMutationAuthority(
            at: libraryRoot,
            in: mutation.library,
            chatID: mutation.base.chat.id
        ) { authority in
            let revalidate = {
                try self.revalidateProfileProposalMutationAuthority(
                    authority,
                    at: libraryRoot,
                    in: mutation.library
                )
            }
            guard case let .readWrite(current) = try loadChat(
                from: authority.chatDescriptor,
                expectedID: mutation.base.chat.id,
                reconcileTransients: true,
                beforeDestructiveMutation: revalidate
            ) else { throw PortableChatPersistenceError.invalidLayout }
            let resolved = try aggregateResolvingProfileEvidencePublication(
                mutation.base
            )
            guard current == mutation.base || current == resolved else {
                return .stale(current)
            }
            let publish = try PublishProfileEvidenceMutation(
                library: mutation.library,
                base: mutation.base,
                responsePositionID: mutation.responsePositionID
            )
            let headData = try boundedData(
                named: "head.json",
                under: authority.profileDescriptor
            )
            let head = try PortableLibraryPersistence().decodeProfileHead(headData)
            if try headSelectsProfileEvidenceRevision(
                head,
                mutation: publish,
                publication: publication,
                under: authority.profileDescriptor
            ) {
                try makeProfileEvidenceHeadDurable(
                    head,
                    mutation: publish,
                    publication: publication,
                    under: authority.profileDescriptor,
                    beforeMutation: revalidate
                )
                let published = try finishProfileEvidencePublication(
                    expected: resolved,
                    chatDescriptor: authority.chatDescriptor,
                    beforeMutation: revalidate
                )
                return .stale(published)
            }
            guard current == mutation.base,
                  current.profileEvidencePublication == publication
            else { return .stale(current) }
            _ = try removeProvedUnselectedProfileEvidenceRevisionIfPresent(
                intendedRevisionID: publish.intendedRevisionID,
                publication: publication,
                currentHeadData: headData,
                currentHead: head,
                profileDescriptor: authority.profileDescriptor,
                revisionsDescriptor: authority.revisionsDescriptor,
                publicationsDescriptor: authority.publicationsDescriptor,
                beforeMutation: revalidate
            )
            return .committed(
                try finishProfileEvidencePublication(
                    expected: resolved,
                    chatDescriptor: authority.chatDescriptor,
                    beforeMutation: revalidate
                )
            )
        }
    }

    func reconcileCommittedProfileEvidencePublication(
        _ mutation: PublishProfileEvidenceMutation,
        at libraryRoot: URL
    ) throws -> ChatAggregate? {
        do {
            return try withProfileProposalMutationAuthority(
                at: libraryRoot,
                in: mutation.library,
                chatID: mutation.base.chat.id
            ) { authority in
                guard let publication = mutation.base.profileEvidencePublication
                else { return nil }
                let revalidate = {
                    try self.revalidateProfileProposalMutationAuthority(
                        authority,
                        at: libraryRoot,
                        in: mutation.library
                    )
                }
                guard case let .readWrite(current) = try loadChat(
                    from: authority.chatDescriptor,
                    expectedID: mutation.base.chat.id,
                    reconcileTransients: true,
                    beforeDestructiveMutation: revalidate
                ) else { return nil }
                let resolved = try aggregateResolvingProfileEvidencePublication(
                    mutation.base
                )
                guard current == mutation.base || current == resolved,
                      !(try hasForeignProfileWriteIntent(
                          excluding: authority.chatName,
                          under: authority.chatsDescriptor
                      ))
                else { return nil }
                let head = try PortableLibraryPersistence().decodeProfileHead(
                    boundedData(
                        named: "head.json",
                        under: authority.profileDescriptor
                    )
                )
                if try headSelectsProfileEvidenceRevision(
                    head,
                    mutation: mutation,
                    publication: publication,
                    under: authority.profileDescriptor
                ) {
                    try makeProfileEvidenceHeadDurable(
                        head,
                        mutation: mutation,
                        publication: publication,
                        under: authority.profileDescriptor,
                        beforeMutation: revalidate
                    )
                    return try finishProfileEvidencePublication(
                        expected: resolved,
                        chatDescriptor: authority.chatDescriptor,
                        beforeMutation: revalidate
                    )
                }
                guard current == resolved,
                      !(try entryExists(
                          named: "profile-publication.json",
                          under: authority.chatDescriptor
                      )),
                      let selected = try loadSelectedProfileRevision(
                          head,
                          under: authority.profileDescriptor
                      ),
                      case .noOp = try selected.applying(
                          publication,
                          intendedRevisionID: mutation.intendedRevisionID,
                          createdAt: publication.createdAt
                )
                else { return nil }
                return try proveProfileEvidencePublicationRemovalDurable(
                    expected: resolved,
                    chatDescriptor: authority.chatDescriptor,
                    beforeMutation: revalidate
                )
            }
        } catch PortableChatPersistenceError.chatMissing {
            return nil
        } catch ProfileEvidencePublicationApplicationError.staleTarget {
            return nil
        }
    }

    func reconcileCommittedProfileEvidenceDiscard(
        _ mutation: DiscardProfileEvidencePublicationMutation,
        at libraryRoot: URL
    ) throws -> ChatAggregate? {
        do {
            return try withProfileProposalMutationAuthority(
                at: libraryRoot,
                in: mutation.library,
                chatID: mutation.base.chat.id
            ) { authority in
                guard let publication = mutation.base.profileEvidencePublication
                else { return nil }
                let revalidate = {
                    try self.revalidateProfileProposalMutationAuthority(
                        authority,
                        at: libraryRoot,
                        in: mutation.library
                    )
                }
                guard !(try entryExists(
                    named: "profile-publication.json",
                    under: authority.chatDescriptor
                )), case let .readWrite(current) = try loadChat(
                    from: authority.chatDescriptor,
                    expectedID: mutation.base.chat.id,
                    reconcileTransients: true,
                    beforeDestructiveMutation: revalidate
                ), current == (try aggregateResolvingProfileEvidencePublication(
                    mutation.base
                )) else { return nil }
                let publish = try PublishProfileEvidenceMutation(
                    library: mutation.library,
                    base: mutation.base,
                    responsePositionID: mutation.responsePositionID
                )
                let head = try PortableLibraryPersistence().decodeProfileHead(
                    boundedData(
                        named: "head.json",
                        under: authority.profileDescriptor
                    )
                )
                guard !(try headSelectsProfileEvidenceRevision(
                    head,
                    mutation: publish,
                    publication: publication,
                    under: authority.profileDescriptor
                )) else { return nil }
                return try proveProfileEvidencePublicationRemovalDurable(
                    expected: current,
                    chatDescriptor: authority.chatDescriptor,
                    beforeMutation: revalidate
                )
            }
        } catch PortableChatPersistenceError.chatMissing {
            return nil
        }
    }

    func discardProfileReconsiderationFailure(
        _ mutation: DiscardProfileReconsiderationFailureMutation,
        at libraryRoot: URL
    ) throws -> PortableChatMutationResult {
        guard let expected = mutation.base.profileReconsideration,
              expected.failure != nil,
              expected.sourceEffectIdentity == mutation.sourceEffectIdentity,
              mutation.base.profileEffect?.identity ==
                mutation.sourceEffectIdentity
        else { throw PortableChatPersistenceError.invalidLayout }
        return try withProfileProposalMutationAuthority(
            at: libraryRoot,
            in: mutation.library,
            chatID: mutation.base.chat.id
        ) { authority in
            let revalidate = {
                try self.revalidateProfileProposalMutationAuthority(
                    authority,
                    at: libraryRoot,
                    in: mutation.library
                )
            }
            guard case let .readWrite(current) = try loadChat(
                from: authority.chatDescriptor,
                expectedID: mutation.base.chat.id,
                reconcileTransients: true,
                beforeDestructiveMutation: revalidate
            ) else { throw PortableChatPersistenceError.invalidLayout }
            let replacement = try mutation.base.discardingReconsiderationFailure(
                expected: expected,
                at: mutation.discardedAt
            )
            if current == replacement,
               !(try entryExists(
                   named: "profile-reconsideration.json",
                   under: authority.chatDescriptor
               ))
            {
                return .committed(current)
            }
            guard current == mutation.base,
                  current.profileReconsideration == expected
            else { return .stale(current) }

            let partialName =
                ".chat.json.\(UUID().uuidString.lowercased()).partial"
            var partialExists = false
            defer {
                if partialExists {
                    _ = partialName.withCString {
                        Darwin.unlinkat(authority.chatDescriptor, $0, 0)
                    }
                }
            }
            try fault(.beforeReconsiderationDiscardPartialWrite)
            try writeExclusive(
                try encodeChat(replacement.chat),
                named: partialName,
                under: authority.chatDescriptor
            )
            partialExists = true
            try fault(.afterReconsiderationDiscardPartialWrite)
            let partialDescriptor = try openRegularFile(
                named: partialName,
                under: authority.chatDescriptor
            )
            defer { Darwin.close(partialDescriptor) }
            try flushDescriptor(partialDescriptor)
            try fault(.afterReconsiderationDiscardFileFlush)
            try revalidate()
            guard case let .readWrite(commitAuthority) = try loadChat(
                from: authority.chatDescriptor,
                expectedID: mutation.base.chat.id,
                reconcileTransients: false
            ), commitAuthority == mutation.base else {
                throw PortableChatPersistenceError.invalidLayout
            }
            guard renameat(
                authority.chatDescriptor,
                partialName,
                authority.chatDescriptor,
                "chat.json"
            ) == 0 else { throw PortableChatPersistenceError.ioFailure }
            partialExists = false
            try fault(.afterReconsiderationDiscardManifestInstall)
            try flushDescriptor(authority.chatDescriptor)
            try fault(.afterReconsiderationDiscardDirectoryFlush)
            try revalidate()
            try removeRegularFileIfPresent(
                named: "profile-reconsideration.json",
                under: authority.chatDescriptor
            )
            try fault(.afterReconsiderationDiscardSidecarRemoval)
            try flushDescriptor(authority.chatDescriptor)
            guard case let .readWrite(reopened) = try loadChat(
                from: authority.chatDescriptor,
                expectedID: mutation.base.chat.id,
                reconcileTransients: true,
                beforeDestructiveMutation: revalidate
            ), reopened == replacement else {
                throw PortableChatPersistenceError.invalidLayout
            }
            return .committed(reopened)
        }
    }

    func reconcileCommittedProfileReconsiderationFailureDiscard(
        _ mutation: DiscardProfileReconsiderationFailureMutation,
        at libraryRoot: URL
    ) throws -> ChatAggregate? {
        guard let expected = mutation.base.profileReconsideration else {
            return nil
        }
        return try withProfileProposalMutationAuthority(
            at: libraryRoot,
            in: mutation.library,
            chatID: mutation.base.chat.id
        ) { authority in
            let revalidate = {
                try self.revalidateProfileProposalMutationAuthority(
                    authority,
                    at: libraryRoot,
                    in: mutation.library
                )
            }
            let replacement = try mutation.base.discardingReconsiderationFailure(
                expected: expected,
                at: mutation.discardedAt
            )
            guard case let .readWrite(current) = try loadChat(
                from: authority.chatDescriptor,
                expectedID: mutation.base.chat.id,
                reconcileTransients: true,
                beforeDestructiveMutation: revalidate
            ) else { return nil }
            if current == replacement,
               !(try entryExists(
                   named: "profile-reconsideration.json",
                   under: authority.chatDescriptor
               ))
            {
                return current
            }
            guard current.chat == replacement.chat,
                  current.memory == replacement.memory,
                  current.messages == replacement.messages,
                  current.profileEffect == replacement.profileEffect,
                  current.profileReconsideration == expected,
                  try entryExists(
                      named: "profile-reconsideration.json",
                      under: authority.chatDescriptor
                  )
            else { return nil }
            try revalidate()
            try removeRegularFileIfPresent(
                named: "profile-reconsideration.json",
                under: authority.chatDescriptor
            )
            try flushDescriptor(authority.chatDescriptor)
            guard case let .readWrite(reopened) = try loadChat(
                from: authority.chatDescriptor,
                expectedID: mutation.base.chat.id,
                reconcileTransients: true,
                beforeDestructiveMutation: revalidate
            ), reopened == replacement else { return nil }
            return reopened
        }
    }

    private func finishProfileProposalAcceptance(
        proposal: ProfileChangeProposal,
        intent: ProfileWriteIntent,
        intentData: Data,
        proposalData: Data,
        current: ChatAggregate,
        resolvedBase: ChatAggregate,
        initialHeadData: Data,
        initialHead: ProfileHead,
        chatDescriptor: Int32,
        profileDescriptor: Int32,
        revisionsDescriptor: Int32,
        publicationsDescriptor: Int32,
        beforeMutation: () throws -> Void
    ) throws -> PortableChatMutationResult {
        let intendedRevision: ProfileRevision
        do {
            intendedRevision = try proposal.applying(
                to: loadProfileRevision(
                    selectedBy: intent.expectedHead.selection,
                    under: profileDescriptor
                ),
                currentHeadGeneration: intent.expectedHead.generation,
                intendedRevisionID: intent.intendedRevisionID,
                createdAt: intent.createdAt
            )
        } catch ProfileProposalApplicationError.staleSemanticBase {
            return .stale(current)
        } catch ProfileProposalApplicationError.targetNotFound {
            return .stale(current)
        } catch ProfileProposalApplicationError.targetMismatch {
            return .stale(current)
        } catch {
            throw PortableChatPersistenceError.invalidLayout
        }
        let revisionData = try encodeProfileRevision(intendedRevision)
        _ = try requireProfileWriteIntentBindings(
            intentData,
            proposalData: proposalData,
            intendedRevisionData: revisionData,
            requiresRecoveryBinding: false
        )
        if try headSelectsIntendedProfileRevision(
            initialHead,
            intent: intent,
            proposal: proposal,
            under: profileDescriptor
        ) {
            try makeIntendedProfileHeadDurable(
                initialHead,
                intent: intent,
                proposal: proposal,
                under: profileDescriptor,
                beforeMutation: beforeMutation
            )
            _ = try finishAcceptedProfileProposal(
                expected: resolvedBase,
                chatDescriptor: chatDescriptor,
                beforeMutation: beforeMutation
            )
            return .committed(resolvedBase)
        }
        guard initialHead.authority == intent.expectedHead,
              current.profileProposal == proposal
        else { return .stale(current) }

        let digest = Self.sha256(revisionData)
        try installProfileRevision(
            intendedRevision,
            data: revisionData,
            digest: digest,
            revisionsDescriptor: revisionsDescriptor,
            publicationsDescriptor: publicationsDescriptor,
            beforeMutation: beforeMutation
        )
        try fault(.afterProfileRevisionInstall)
        let pointer = try ProfileRevisionPointer(
            revisionID: intendedRevision.revisionID,
            sha256: digest
        )
        let replacementHead = ProfileHead(
            generation: intendedRevision.generation,
            statementGeneration: intendedRevision.statementGeneration,
            selection: .revision(pointer),
            updatedAt: intent.createdAt
        )
        let proveInstalledRevision = {
            try beforeMutation()
            try self.requireExactInstalledProfileRevision(
                intendedRevision,
                data: revisionData,
                digest: digest,
                under: revisionsDescriptor
            )
        }
        guard try compareAndSwapProfileHead(
            expectedData: initialHeadData,
            expected: initialHead,
            replacement: replacementHead,
            under: profileDescriptor,
            beforeInstalling: proveInstalledRevision
        ) else { return .stale(current) }
        try makeIntendedProfileHeadDurable(
            replacementHead,
            intent: intent,
            proposal: proposal,
            under: profileDescriptor,
            beforeMutation: beforeMutation
        )
        _ = try finishAcceptedProfileProposal(
            expected: resolvedBase,
            chatDescriptor: chatDescriptor,
            beforeMutation: beforeMutation
        )
        return .committed(resolvedBase)
    }

    private func finishAcceptedProfileProposal(
        expected: ChatAggregate,
        chatDescriptor: Int32,
        beforeMutation: () throws -> Void
    ) throws -> ChatAggregate {
        try beforeMutation()
        try removeRegularFileIfPresent(named: "proposal.json", under: chatDescriptor)
        try fault(.afterProfileProposalRemoval)
        try beforeMutation()
        try flushDescriptor(chatDescriptor)
        try beforeMutation()
        guard !(try entryExists(named: "proposal.json", under: chatDescriptor)),
              case let .readWrite(cleanedChat) = try loadChat(
                  from: chatDescriptor,
                  expectedID: expected.chat.id,
                  reconcileTransients: true,
                  allowsProfileWriteIntent: true,
                  beforeDestructiveMutation: beforeMutation
              ),
              cleanedChat == expected
        else { throw PortableChatPersistenceError.invalidLayout }
        try beforeMutation()
        try removeRegularFileIfPresent(
            named: "profile-write.json",
            under: chatDescriptor
        )
        try fault(.afterProfileWriteIntentRemoval)
        try beforeMutation()
        try flushDescriptor(chatDescriptor)
        guard !(try entryExists(named: "proposal.json", under: chatDescriptor)),
              !(try entryExists(
                  named: "profile-write.json",
                  under: chatDescriptor
              ))
        else { throw PortableChatPersistenceError.invalidLayout }
        try beforeMutation()
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: expected.chat.id,
            reconcileTransients: true,
            beforeDestructiveMutation: beforeMutation
        ), reopened == expected else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return reopened
    }

    private func finishDiscardedProfileProposal(
        expected: ChatAggregate,
        retainedWriteIntentData: Data?,
        chatDescriptor: Int32,
        beforeMutation: () throws -> Void
    ) throws -> ChatAggregate {
        try beforeMutation()
        try removeRegularFileIfPresent(
            named: "proposal.json",
            under: chatDescriptor
        )
        try fault(.afterProfileProposalRemoval)
        try beforeMutation()
        try flushDescriptor(chatDescriptor)
        guard !(try entryExists(named: "proposal.json", under: chatDescriptor))
        else { throw PortableChatPersistenceError.invalidLayout }
        if let retainedWriteIntentData {
            guard try boundedData(
                named: "profile-write.json",
                under: chatDescriptor
            ) == retainedWriteIntentData,
                case let .readWrite(cleanedChat) = try loadChat(
                    from: chatDescriptor,
                    expectedID: expected.chat.id,
                    reconcileTransients: true,
                    allowsProfileWriteIntent: true,
                    beforeDestructiveMutation: beforeMutation
                ), cleanedChat == expected
            else { throw PortableChatPersistenceError.invalidLayout }
            try beforeMutation()
            try removeRegularFileIfPresent(
                named: "profile-write.json",
                under: chatDescriptor
            )
            try fault(.afterProfileWriteIntentRemoval)
            try beforeMutation()
            try flushDescriptor(chatDescriptor)
        }
        guard !(try entryExists(
            named: "profile-write.json",
            under: chatDescriptor
        )) else { throw PortableChatPersistenceError.invalidLayout }
        try beforeMutation()
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: expected.chat.id,
            reconcileTransients: true,
            beforeDestructiveMutation: beforeMutation
        ), reopened == expected else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return reopened
    }

    private func finishProfileEvidencePublication(
        expected: ChatAggregate,
        chatDescriptor: Int32,
        beforeMutation: () throws -> Void
    ) throws -> ChatAggregate {
        try beforeMutation()
        try removeRegularFileIfPresent(
            named: "profile-publication.json",
            under: chatDescriptor
        )
        try fault(.afterProfileEvidencePublicationRemoval)
        return try proveProfileEvidencePublicationRemovalDurable(
            expected: expected,
            chatDescriptor: chatDescriptor,
            beforeMutation: beforeMutation
        )
    }

    private func proveProfileEvidencePublicationRemovalDurable(
        expected: ChatAggregate,
        chatDescriptor: Int32,
        beforeMutation: () throws -> Void
    ) throws -> ChatAggregate {
        try beforeMutation()
        try flushDescriptor(chatDescriptor)
        try beforeMutation()
        guard !(try entryExists(
            named: "profile-publication.json",
            under: chatDescriptor
        )) else { throw PortableChatPersistenceError.invalidLayout }
        try beforeMutation()
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: expected.chat.id,
            reconcileTransients: true,
            beforeDestructiveMutation: beforeMutation
        ), reopened == expected else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try beforeMutation()
        return reopened
    }

    private func aggregateResolvingProfileProposal(
        _ aggregate: ChatAggregate
    ) throws -> ChatAggregate {
        try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            messages: aggregate.messages,
            pendingUserTurn: aggregate.pendingUserTurn,
            profileProposal: nil,
            profileEvidencePublication: aggregate.profileEvidencePublication
        )
    }

    private func aggregateResolvingProfileEvidencePublication(
        _ aggregate: ChatAggregate
    ) throws -> ChatAggregate {
        try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            messages: aggregate.messages,
            pendingUserTurn: aggregate.pendingUserTurn,
            profileProposal: aggregate.profileProposal,
            profileEvidencePublication: nil
        )
    }

    func encodeProfileRevision(_ revision: ProfileRevision) throws -> Data {
        let data = try deterministicJSON(ProfileRevisionDTO(revision))
        guard data.count <= Self.maximumRootBytes else {
            throw PortableChatPersistenceError.rootTooLarge
        }
        return data
    }

    func decodeProfileRevision(_ data: Data) throws -> ProfileRevision {
        let dictionary = try jsonDictionary(data)
        let required: Set<String> = [
            "schemaVersion", "revisionId", "generation",
            "statementGeneration", "createdAt", "statements",
        ]
        let actual = Set(dictionary.keys)
        guard actual == required || actual == required.union(["parentRevisionId"]),
              !(dictionary["parentRevisionId"] is NSNull),
              let statements = dictionary["statements"] as? [[String: Any]]
        else { throw PortableChatPersistenceError.invalidJSON }
        for statement in statements {
            try requireExactKeys(
                statement,
                [
                    "statementId", "statementKind", "wording",
                    "supportingSessionCount", "evidence",
                ]
            )
            try validateEvidenceReferenceArrayJSON(
                statement["evidence"],
                allowsEmpty: true
            )
        }
        let dto: ProfileRevisionDTO = try decode(ProfileRevisionDTO.self, data)
        guard dto.schemaVersion == ProfileRevision.schemaVersion,
              dto.statementGeneration <= dto.generation
        else {
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        do {
            return try dto.domainValue
        } catch {
            throw PortableChatPersistenceError.invalidJSON
        }
    }

    func encodeProfileWriteIntent(
        _ intent: ProfileWriteIntent,
        proposalData: Data,
        intendedRevisionData: Data
    ) throws -> Data {
        let data = try deterministicJSON(
            ProfileWriteIntentDTO(
                intent,
                proposalSha256: Self.sha256(proposalData),
                intendedRevisionSha256: Self.sha256(intendedRevisionData)
            )
        )
        guard data.count <= Self.maximumRootBytes else {
            throw PortableChatPersistenceError.rootTooLarge
        }
        return data
    }

    func decodeProfileWriteIntent(
        _ data: Data,
        proposal: ProfileChangeProposal,
        proposalData: Data
    ) throws -> ProfileWriteIntent {
        let persisted = try decodePersistedProfileWriteIntent(data)
        if let expectedProposalDigest = persisted.proposalSHA256,
           expectedProposalDigest != Self.sha256(proposalData)
        {
            throw PortableChatPersistenceError.invalidLayout
        }
        return try persisted.domainValue(proposal: proposal)
    }

    private func decodePersistedProfileWriteIntent(
        _ data: Data
    ) throws -> PersistedProfileWriteIntent {
        let dictionary = try jsonDictionary(data)
        guard let rawSchemaVersion = dictionary["schemaVersion"] as? NSNumber,
              CFGetTypeID(rawSchemaVersion) != CFBooleanGetTypeID()
        else { throw PortableChatPersistenceError.invalidJSON }
        let schemaVersion = rawSchemaVersion.uint32Value
        switch schemaVersion {
        case ProfileWriteIntent.schemaVersion:
            try requireExactKeys(dictionary, [
                "schemaVersion", "intentId", "proposalId", "chatId",
                "expectedHead", "intendedRevisionId", "createdAt",
            ])
        case Self.profileWriteIntentSchemaVersion:
            try requireExactKeys(dictionary, [
                "schemaVersion", "intentId", "proposalId", "chatId",
                "expectedHead", "intendedRevisionId", "createdAt",
                "proposalSha256", "intendedRevisionSha256",
            ])
        default:
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        guard let expectedHead = dictionary["expectedHead"] as? [String: Any]
        else { throw PortableChatPersistenceError.invalidJSON }
        let common: Set<String> = ["generation", "statementGeneration"]
        let selected = common.union(["revisionId", "revisionSha256"])
        let expectedKeys = Set(expectedHead.keys)
        guard expectedKeys == common || expectedKeys == selected else {
            throw PortableChatPersistenceError.unknownKey
        }
        if expectedKeys == selected,
           expectedHead["revisionId"] is NSNull ||
            expectedHead["revisionSha256"] is NSNull
        {
            throw PortableChatPersistenceError.invalidJSON
        }
        let dto: ProfileWriteIntentDTO = try decode(
            ProfileWriteIntentDTO.self,
            data
        )
        guard dto.schemaVersion == schemaVersion else {
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        do {
            let record = PersistedProfileWriteIntent(
                schemaVersion: schemaVersion,
                id: try ProfileWriteIntentID(dto.intentId),
                proposalID: try ProfileChangeProposalID(dto.proposalId),
                chatID: try ChatID(dto.chatId),
                expectedHead: try dto.expectedHead.domainValue,
                intendedRevisionID: try ProfileRevisionID(
                    dto.intendedRevisionId
                ),
                createdAt: try UTCInstant(dto.createdAt),
                proposalSHA256: dto.proposalSha256,
                intendedRevisionSHA256: dto.intendedRevisionSha256
            )
            let tail = String(
                record.proposalID.rawValue.dropFirst("prp-".count)
            )
            guard record.id.rawValue == "pwi-\(tail)",
                  record.intendedRevisionID.rawValue == "prf-\(tail)",
                  record.expectedHead.statementGeneration <=
                    record.expectedHead.generation
            else { throw PortableChatPersistenceError.invalidJSON }
            if schemaVersion == Self.profileWriteIntentSchemaVersion {
                guard let proposalSHA256 = record.proposalSHA256,
                      let intendedRevisionSHA256 =
                        record.intendedRevisionSHA256,
                      Self.isSHA256(proposalSHA256),
                      Self.isSHA256(intendedRevisionSHA256)
                else { throw PortableChatPersistenceError.invalidJSON }
            } else {
                guard record.proposalSHA256 == nil,
                      record.intendedRevisionSHA256 == nil
                else { throw PortableChatPersistenceError.invalidJSON }
            }
            return record
        } catch {
            if let error = error as? PortableChatPersistenceError {
                throw error
            }
            throw PortableChatPersistenceError.invalidJSON
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    @discardableResult
    private func requireProfileWriteIntentBindings(
        _ data: Data,
        proposalData: Data,
        intendedRevisionData: Data,
        requiresRecoveryBinding: Bool
    ) throws -> PersistedProfileWriteIntent {
        let persisted = try decodePersistedProfileWriteIntent(data)
        if requiresRecoveryBinding, !persisted.hasRecoveryBinding {
            throw PortableChatPersistenceError.invalidLayout
        }
        if let proposalSHA256 = persisted.proposalSHA256,
           proposalSHA256 != Self.sha256(proposalData)
        {
            throw PortableChatPersistenceError.invalidLayout
        }
        if let intendedRevisionSHA256 = persisted.intendedRevisionSHA256,
           intendedRevisionSHA256 != Self.sha256(intendedRevisionData)
        {
            throw PortableChatPersistenceError.invalidLayout
        }
        return persisted
    }

    private func installProfileWriteIntent(
        _ data: Data,
        under chatDescriptor: Int32,
        beforeMutation: () throws -> Void
    ) throws {
        if try entryExists(named: "profile-write.json", under: chatDescriptor) {
            guard try boundedData(
                named: "profile-write.json",
                under: chatDescriptor
            ) == data else { throw PortableChatPersistenceError.invalidLayout }
            return
        }
        try fault(.beforeProfileWriteIntentPartialWrite)
        let partialName = ".profile-write.json.\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString {
                    Darwin.unlinkat(chatDescriptor, $0, 0)
                }
            }
        }
        try writeExclusive(data, named: partialName, under: chatDescriptor)
        partialExists = true
        try fault(.afterProfileWriteIntentPartialWrite)
        let descriptor = try openRegularFile(
            named: partialName,
            under: chatDescriptor
        )
        defer { Darwin.close(descriptor) }
        let partialIdentity = try regularFileLivenessIdentity(of: descriptor)
        try flushDescriptor(descriptor)
        try fault(.afterProfileWriteIntentFileFlush)
        try beforeMutation()
        guard try regularFileLivenessIdentity(of: descriptor) == partialIdentity,
              try regularFileLivenessIdentity(
                  named: partialName,
                  under: chatDescriptor
              ) == partialIdentity
        else { throw PortableChatPersistenceError.invalidLayout }
        try noReplaceRename(
            from: partialName,
            under: chatDescriptor,
            to: "profile-write.json",
            under: chatDescriptor
        )
        partialExists = false
        try fault(.afterProfileWriteIntentInstall)
        try beforeMutation()
        try flushDescriptor(chatDescriptor)
        try fault(.afterProfileWriteIntentDirectoryFlush)
        try beforeMutation()
        guard try boundedData(
            named: "profile-write.json",
            under: chatDescriptor
        ) == data else { throw PortableChatPersistenceError.invalidLayout }
    }

    private func loadSelectedProfileRevision(
        _ head: ProfileHead,
        under profileDescriptor: Int32
    ) throws -> ProfileRevision? {
        let revision = try loadProfileRevision(
            selectedBy: head.selection,
            under: profileDescriptor
        )
        guard revision?.generation ?? head.generation == head.generation,
              revision?.statementGeneration ?? head.statementGeneration ==
                head.statementGeneration
        else { throw PortableChatPersistenceError.invalidLayout }
        return revision
    }

    private func profileEffectSourceProvenance(
        _ effect: ChatProfileEffect,
        in aggregate: ChatAggregate
    ) throws -> CoachProfileProvenance {
        guard effect.chatID == aggregate.chat.id else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let sourceMessages = aggregate.messages.filter { message in
            guard message.responsePositionID == effect.responsePositionID,
                  case .coach = message.content
            else { return false }
            return true
        }
        switch effect {
        case let .proposal(proposal):
            guard sourceMessages.count <= 1 else {
                throw PortableChatPersistenceError.invalidLayout
            }
            if let sourceMessage = sourceMessages.first,
               sourceMessage.coachProfile != proposal.baseProfile
            {
                throw PortableChatPersistenceError.invalidLayout
            }
            return proposal.baseProfile
        case .evidencePublication:
            guard sourceMessages.count == 1,
                  let provenance = sourceMessages[0].coachProfile
            else { throw PortableChatPersistenceError.invalidLayout }
            return provenance
        }
    }

    private func loadProfileSnapshot(
        proving provenance: CoachProfileProvenance,
        under profileDescriptor: Int32
    ) throws -> ProfileSnapshot {
        guard let revisionID = provenance.revisionID else {
            return ProfileSnapshot(
                nullAtStatementGeneration: provenance.statementGeneration
            )
        }
        let revision = try loadProfileRevision(
            id: revisionID,
            under: profileDescriptor
        )
        guard revision.statementGeneration == provenance.statementGeneration
        else { throw PortableChatPersistenceError.invalidLayout }
        return ProfileSnapshot(revision: revision)
    }

    private func validateProfileEffect(
        _ effect: ChatProfileEffect,
        against baseProfile: ProfileSnapshot
    ) throws {
        func requireExact(_ target: ProfileProposalTarget) throws {
            guard let statement = baseProfile.statement(
                id: target.statementID
            ), target.matches(statement) else {
                throw PortableChatPersistenceError.invalidLayout
            }
        }
        func requireAbsent(_ statement: ProfileProposedStatement) throws {
            guard baseProfile.statement(id: statement.statementID) == nil else {
                throw PortableChatPersistenceError.invalidLayout
            }
        }

        switch effect {
        case let .proposal(proposal):
            guard proposal.baseProfile == baseProfile.provenance else {
                throw PortableChatPersistenceError.invalidLayout
            }
            for change in proposal.changes {
                switch change {
                case let .add(statement):
                    try requireAbsent(statement)
                case let .replace(target, replacement):
                    try requireExact(target)
                    try requireAbsent(replacement)
                case let .retire(target, _):
                    try requireExact(target)
                }
            }
            for append in proposal.evidenceAppends {
                try requireExact(append.target)
            }
        case let .evidencePublication(publication):
            for append in publication.evidenceAppends {
                try requireExact(append.target)
            }
        }
    }

    private func loadProfileRevision(
        selectedBy selection: ProfileSelection,
        under profileDescriptor: Int32
    ) throws -> ProfileRevision? {
        guard case let .revision(pointer) = selection else { return nil }
        let revisionsDescriptor = try openDirectory(
            named: "revisions",
            under: profileDescriptor
        )
        defer { Darwin.close(revisionsDescriptor) }
        let revisionDescriptor = try openDirectory(
            named: pointer.revisionID.rawValue,
            under: revisionsDescriptor
        )
        defer { Darwin.close(revisionDescriptor) }
        guard Set(try listEntryNames(
            under: revisionDescriptor,
            maximumCount: 2
        )) == ["revision.json", "revision.sha256"] else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let data = try boundedData(
            named: "revision.json",
            under: revisionDescriptor
        )
        let detachedData = try boundedData(
            named: "revision.sha256",
            under: revisionDescriptor
        )
        guard detachedData.count == 64,
              let detached = String(data: detachedData, encoding: .utf8),
              detached == pointer.sha256,
              detached == Self.sha256(data)
        else { throw PortableChatPersistenceError.invalidLayout }
        let revision = try decodeProfileRevision(data)
        guard revision.revisionID == pointer.revisionID else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return revision
    }

    private func installProfileRevision(
        _ revision: ProfileRevision,
        data: Data,
        digest: String,
        revisionsDescriptor: Int32,
        publicationsDescriptor: Int32,
        beforeMutation: () throws -> Void
    ) throws {
        if try entryExists(
            named: revision.revisionID.rawValue,
            under: revisionsDescriptor
        ) {
            try requireExactInstalledProfileRevision(
                revision,
                data: data,
                digest: digest,
                under: revisionsDescriptor
            )
            // A retry may observe a rename whose parent-directory flush was
            // interrupted. Make that exact immutable entry durable before a
            // head is ever allowed to select it.
            try flushDescriptor(revisionsDescriptor)
            return
        }
        let candidateName = ".profile-\(revision.revisionID.rawValue)-\(UUID().uuidString.lowercased()).partial"
        try makeDirectory(named: candidateName, under: publicationsDescriptor)
        let candidateIdentity = try directoryIdentity(
            named: candidateName,
            under: publicationsDescriptor
        )
        var candidateExists = true
        defer {
            if candidateExists {
                removeProfileRevisionCandidate(
                    named: candidateName,
                    expectedIdentity: candidateIdentity,
                    under: publicationsDescriptor
                )
            }
        }
        let candidateDescriptor = try openDirectory(
            named: candidateName,
            under: publicationsDescriptor
        )
        defer { Darwin.close(candidateDescriptor) }
        guard try directoryIdentity(of: candidateDescriptor) == candidateIdentity
        else { throw PortableChatPersistenceError.invalidLayout }
        try writeExclusive(data, named: "revision.json", under: candidateDescriptor)
        try writeExclusive(
            Data(digest.utf8),
            named: "revision.sha256",
            under: candidateDescriptor
        )
        for name in ["revision.json", "revision.sha256"] {
            try {
                let descriptor = try openRegularFile(
                    named: name,
                    under: candidateDescriptor
                )
                defer { Darwin.close(descriptor) }
                try flushDescriptor(descriptor)
            }()
        }
        try flushDescriptor(candidateDescriptor)
        guard Set(try listEntryNames(
            under: candidateDescriptor,
            maximumCount: 2
        )) == ["revision.json", "revision.sha256"],
              try boundedData(
                  named: "revision.json",
                  under: candidateDescriptor
              ) == data,
              try boundedData(
                  named: "revision.sha256",
                  under: candidateDescriptor
              ) == Data(digest.utf8),
              try directoryIdentity(of: candidateDescriptor) == candidateIdentity,
              try directoryIdentity(
                  named: candidateName,
                  under: publicationsDescriptor
              ) == candidateIdentity
        else { throw PortableChatPersistenceError.invalidLayout }
        try beforeMutation()
        guard try directoryIdentity(of: candidateDescriptor) == candidateIdentity,
              try directoryIdentity(
                  named: candidateName,
                  under: publicationsDescriptor
              ) == candidateIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try noReplaceRename(
            from: candidateName,
            under: publicationsDescriptor,
            to: revision.revisionID.rawValue,
            under: revisionsDescriptor
        )
        candidateExists = false
        guard try directoryIdentity(
            named: revision.revisionID.rawValue,
            under: revisionsDescriptor
        ) == candidateIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try flushDescriptor(revisionsDescriptor)
        try flushDescriptor(publicationsDescriptor)
        try beforeMutation()
        try requireExactInstalledProfileRevision(
            revision,
            data: data,
            digest: digest,
            under: revisionsDescriptor
        )
    }

    private func requireExactInstalledProfileRevision(
        _ revision: ProfileRevision,
        data: Data,
        digest: String,
        under revisionsDescriptor: Int32
    ) throws {
        let identity = try directoryIdentity(
            named: revision.revisionID.rawValue,
            under: revisionsDescriptor
        )
        let descriptor = try openDirectory(
            named: revision.revisionID.rawValue,
            under: revisionsDescriptor
        )
        defer { Darwin.close(descriptor) }
        guard try directoryIdentity(of: descriptor) == identity,
              Set(try listEntryNames(under: descriptor, maximumCount: 2)) ==
                ["revision.json", "revision.sha256"],
              try boundedData(named: "revision.json", under: descriptor) == data,
              try boundedData(named: "revision.sha256", under: descriptor) ==
                Data(digest.utf8),
              try decodeProfileRevision(data) == revision,
              try directoryIdentity(of: descriptor) == identity,
              try directoryIdentity(
                  named: revision.revisionID.rawValue,
                  under: revisionsDescriptor
              ) == identity
        else { throw PortableChatPersistenceError.invalidLayout }
    }

    private func removeProfileRevisionCandidate(
        named name: String,
        expectedIdentity: DirectoryIdentity,
        under publicationsDescriptor: Int32
    ) {
        var budget = CandidateCleanupBudget()
        guard let plan = try? stagedProfileRevisionCleanupPlan(
            named: name,
            under: publicationsDescriptor,
            budget: &budget
        ), plan.directoryIdentity == expectedIdentity else { return }
        try? removeStagedProfileRevision(
            plan,
            under: publicationsDescriptor,
            emitsFaults: false
        )
    }

    /// A lost head CAS can leave this operation's deterministic revision ID
    /// installed against an older parent. Before rebasing the same operation,
    /// remove only that proved, unselected, and unreferenced orphan.
    private func prepareProfileEvidenceRevisionSlot(
        for revision: ProfileRevision,
        publication: ProfileEvidencePublication,
        currentHeadData: Data,
        currentHead: ProfileHead,
        profileDescriptor: Int32,
        revisionsDescriptor: Int32,
        publicationsDescriptor: Int32,
        beforeMutation: () throws -> Void
    ) throws {
        let name = revision.revisionID.rawValue
        guard try entryExists(named: name, under: revisionsDescriptor) else {
            return
        }
        let installed = try loadProfileRevision(
            id: revision.revisionID,
            under: profileDescriptor
        )
        guard installed != revision else { return }
        guard try removeProvedUnselectedProfileEvidenceRevisionIfPresent(
            intendedRevisionID: revision.revisionID,
            publication: publication,
            currentHeadData: currentHeadData,
            currentHead: currentHead,
            profileDescriptor: profileDescriptor,
            revisionsDescriptor: revisionsDescriptor,
            publicationsDescriptor: publicationsDescriptor,
            beforeMutation: beforeMutation
        ) else {
            throw PortableChatPersistenceError.invalidLayout
        }
    }

    @discardableResult
    private func removeProvedUnselectedProfileEvidenceRevisionIfPresent(
        intendedRevisionID: ProfileRevisionID,
        publication: ProfileEvidencePublication,
        currentHeadData: Data,
        currentHead: ProfileHead,
        profileDescriptor: Int32,
        revisionsDescriptor: Int32,
        publicationsDescriptor: Int32,
        beforeMutation: () throws -> Void
    ) throws -> Bool {
        let name = intendedRevisionID.rawValue
        guard try entryExists(named: name, under: revisionsDescriptor) else {
            return false
        }
        let installed = try loadProfileRevision(
            id: intendedRevisionID,
            under: profileDescriptor
        )
        guard currentHead.authority.currentRevisionID != intendedRevisionID,
              installed.createdAt == publication.createdAt,
              let installedParentID = installed.parentRevisionID
        else { return false }
        let installedParent = try loadProfileRevision(
            id: installedParentID,
            under: profileDescriptor
        )
        let application: ProfileEvidencePublicationApplicationResult
        do {
            application = try installedParent.applying(
                publication,
                intendedRevisionID: intendedRevisionID,
                createdAt: publication.createdAt
            )
        } catch {
            return false
        }
        guard case let .changed(provedInstalled) = application,
              provedInstalled == installed
        else { return false }

        let revisionNames = try listEntryNames(
            under: revisionsDescriptor,
            maximumCount: 65_536
        ).filter { $0 != ".DS_Store" && $0 != name }
        for childName in revisionNames {
            let childID: ProfileRevisionID
            do {
                childID = try ProfileRevisionID(childName)
            } catch {
                throw PortableChatPersistenceError.invalidLayout
            }
            let child = try loadProfileRevision(
                id: childID,
                under: profileDescriptor
            )
            if child.parentRevisionID == intendedRevisionID {
                return false
            }
        }

        let revisionIdentity = try directoryIdentity(
            named: name,
            under: revisionsDescriptor
        )
        let revisionDescriptor = try openDirectory(
            named: name,
            under: revisionsDescriptor
        )
        defer { Darwin.close(revisionDescriptor) }
        try beforeMutation()
        let provedHeadData = try boundedData(
            named: "head.json",
            under: profileDescriptor
        )
        guard provedHeadData == currentHeadData,
              try PortableLibraryPersistence().decodeProfileHead(
                  provedHeadData
              ) == currentHead,
              currentHead.authority.currentRevisionID != intendedRevisionID,
              try directoryIdentity(of: revisionDescriptor) == revisionIdentity,
              try directoryIdentity(named: name, under: revisionsDescriptor) ==
                revisionIdentity
        else { throw PortableChatPersistenceError.invalidLayout }

        let tombstoneName =
            ".profile-\(name)-\(UUID().uuidString.lowercased()).partial"
        try noReplaceRename(
            from: name,
            under: revisionsDescriptor,
            to: tombstoneName,
            under: publicationsDescriptor
        )
        try fault(.afterProfileRevisionAbortRename)
        guard try directoryIdentity(
            named: tombstoneName,
            under: publicationsDescriptor
        ) == revisionIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try flushDescriptor(revisionsDescriptor)
        try flushDescriptor(publicationsDescriptor)
        try beforeMutation()
        var cleanupBudget = CandidateCleanupBudget()
        guard let cleanupPlan = try stagedProfileRevisionCleanupPlan(
            named: tombstoneName,
            under: publicationsDescriptor,
            budget: &cleanupBudget
        ), cleanupPlan.directoryIdentity == revisionIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try removeStagedProfileRevision(
            cleanupPlan,
            under: publicationsDescriptor,
            emitsFaults: true
        )
        try flushDescriptor(publicationsDescriptor)
        try beforeMutation()
        guard !(try entryExists(named: name, under: revisionsDescriptor)),
              try boundedData(
                  named: "head.json",
                  under: profileDescriptor
              ) == currentHeadData
        else { throw PortableChatPersistenceError.invalidLayout }
        return true
    }

    private func removeUncommittedProfileRevisionIfPresent(
        intent: ProfileWriteIntent,
        proposal: ProfileChangeProposal,
        profileDescriptor: Int32,
        revisionsDescriptor: Int32,
        publicationsDescriptor: Int32,
        beforeMutation: () throws -> Void
    ) throws {
        let name = intent.intendedRevisionID.rawValue
        let base = try loadProfileRevision(
            selectedBy: intent.expectedHead.selection,
            under: profileDescriptor
        )
        let expected = try proposal.applying(
            to: base,
            currentHeadGeneration: intent.expectedHead.generation,
            intendedRevisionID: intent.intendedRevisionID,
            createdAt: intent.createdAt
        )
        let expectedData = try encodeProfileRevision(expected)
        let expectedDigest = Self.sha256(expectedData)
        guard try entryExists(named: name, under: revisionsDescriptor) else {
            // A prior abort may have completed the cross-directory rename but
            // crashed before synchronizing the source parent. Re-synchronizing
            // and then re-proving absence makes the rename-away durable before
            // the write intent and proposal can be removed.
            try beforeMutation()
            try flushDescriptor(revisionsDescriptor)
            try fault(.afterProfileRevisionAbsenceDirectoryFlush)
            try beforeMutation()
            guard !(try entryExists(named: name, under: revisionsDescriptor)) else {
                throw PortableChatPersistenceError.invalidLayout
            }
            return
        }
        try requireExactInstalledProfileRevision(
            expected,
            data: expectedData,
            digest: expectedDigest,
            under: revisionsDescriptor
        )
        let revisionIdentity = try directoryIdentity(
            named: name,
            under: revisionsDescriptor
        )
        let revisionDescriptor = try openDirectory(
            named: name,
            under: revisionsDescriptor
        )
        defer { Darwin.close(revisionDescriptor) }
        guard try directoryIdentity(of: revisionDescriptor) == revisionIdentity,
              try directoryIdentity(named: name, under: revisionsDescriptor) ==
                revisionIdentity
        else { throw PortableChatPersistenceError.invalidLayout }

        let tombstoneName = ".profile-\(name)-\(UUID().uuidString.lowercased()).partial"
        try beforeMutation()
        let currentHead = try PortableLibraryPersistence().decodeProfileHead(
            boundedData(named: "head.json", under: profileDescriptor)
        )
        guard currentHead.authority == intent.expectedHead,
              try directoryIdentity(of: revisionDescriptor) == revisionIdentity,
              try directoryIdentity(named: name, under: revisionsDescriptor) ==
                revisionIdentity
        else { throw PortableChatPersistenceError.invalidLayout }
        try noReplaceRename(
            from: name,
            under: revisionsDescriptor,
            to: tombstoneName,
            under: publicationsDescriptor
        )
        try fault(.afterProfileRevisionAbortRename)
        guard try directoryIdentity(
            named: tombstoneName,
            under: publicationsDescriptor
        ) == revisionIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try flushDescriptor(revisionsDescriptor)
        try flushDescriptor(publicationsDescriptor)
        try beforeMutation()
        var cleanupBudget = CandidateCleanupBudget()
        guard let cleanupPlan = try stagedProfileRevisionCleanupPlan(
            named: tombstoneName,
            under: publicationsDescriptor,
            budget: &cleanupBudget
        ), cleanupPlan.directoryIdentity == revisionIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try removeStagedProfileRevision(
            cleanupPlan,
            under: publicationsDescriptor,
            emitsFaults: true
        )
        guard !(try entryExists(
            named: tombstoneName,
            under: publicationsDescriptor
        )) else { throw PortableChatPersistenceError.ioFailure }
        try flushDescriptor(publicationsDescriptor)
        try beforeMutation()
    }

    private func compareAndSwapProfileHead(
        expectedData: Data,
        expected: ProfileHead,
        replacement: ProfileHead,
        under profileDescriptor: Int32,
        beforeInstalling: () throws -> Void
    ) throws -> Bool {
        let replacementData = try PortableLibraryPersistence().encodeProfileHead(
            replacement
        )
        try fault(.beforeProfileHeadPartialWrite)
        let partialName = ".head.json.\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString {
                    Darwin.unlinkat(profileDescriptor, $0, 0)
                }
            }
        }
        try writeExclusive(
            replacementData,
            named: partialName,
            under: profileDescriptor
        )
        partialExists = true
        try fault(.afterProfileHeadPartialWrite)
        let descriptor = try openRegularFile(
            named: partialName,
            under: profileDescriptor
        )
        defer { Darwin.close(descriptor) }
        let partialIdentity = try regularFileLivenessIdentity(of: descriptor)
        try flushDescriptor(descriptor)
        try fault(.afterProfileHeadFileFlush)
        try fault(.beforeProfileHeadInstall)
        try beforeInstalling()
        let currentData = try boundedData(
            named: "head.json",
            under: profileDescriptor
        )
        guard currentData == expectedData,
              try PortableLibraryPersistence().decodeProfileHead(currentData) == expected
        else { return false }
        try beforeInstalling()
        guard try regularFileLivenessIdentity(of: descriptor) == partialIdentity,
              try regularFileLivenessIdentity(
                  named: partialName,
                  under: profileDescriptor
              ) == partialIdentity
        else { throw PortableChatPersistenceError.invalidLayout }
        guard renameat(
            profileDescriptor,
            partialName,
            profileDescriptor,
            "head.json"
        ) == 0 else { throw PortableChatPersistenceError.ioFailure }
        partialExists = false
        try fault(.afterProfileHeadInstall)
        try flushDescriptor(profileDescriptor)
        try fault(.afterProfileHeadDirectoryFlush)
        guard try boundedData(named: "head.json", under: profileDescriptor) ==
                replacementData
        else { throw PortableChatPersistenceError.invalidLayout }
        return true
    }

    private func headSelectsIntendedProfileRevision(
        _ head: ProfileHead,
        intent: ProfileWriteIntent,
        proposal: ProfileChangeProposal,
        under profileDescriptor: Int32
    ) throws -> Bool {
        let base = try loadProfileRevision(
            selectedBy: intent.expectedHead.selection,
            under: profileDescriptor
        )
        let expected = try proposal.applying(
            to: base,
            currentHeadGeneration: intent.expectedHead.generation,
            intendedRevisionID: intent.intendedRevisionID,
            createdAt: intent.createdAt
        )
        guard head.generation == expected.generation,
              head.statementGeneration == expected.statementGeneration,
              head.authority.currentRevisionID == intent.intendedRevisionID,
              let installed = try loadProfileRevision(
                  selectedBy: head.selection,
                  under: profileDescriptor
              )
        else { return false }
        return installed == expected
    }

    private func makeIntendedProfileHeadDurable(
        _ head: ProfileHead,
        intent: ProfileWriteIntent,
        proposal: ProfileChangeProposal,
        under profileDescriptor: Int32,
        beforeMutation: () throws -> Void
    ) throws {
        try beforeMutation()
        guard try headSelectsIntendedProfileRevision(
            head,
            intent: intent,
            proposal: proposal,
            under: profileDescriptor
        ) else { throw PortableChatPersistenceError.invalidLayout }
        try flushDescriptor(profileDescriptor)
        try beforeMutation()
        let durableHead = try PortableLibraryPersistence().decodeProfileHead(
            boundedData(named: "head.json", under: profileDescriptor)
        )
        guard durableHead == head,
              try headSelectsIntendedProfileRevision(
                  durableHead,
                  intent: intent,
                  proposal: proposal,
                  under: profileDescriptor
              )
        else { throw PortableChatPersistenceError.invalidLayout }
    }

    private func makeMutationProfileHeadDurable(
        _ head: ProfileHead,
        mutation: AcceptProfileProposalMutation,
        proposal: ProfileChangeProposal,
        under profileDescriptor: Int32,
        beforeMutation: () throws -> Void
    ) throws {
        try beforeMutation()
        guard try headSelectsMutationProfileRevision(
            head,
            mutation: mutation,
            proposal: proposal,
            under: profileDescriptor
        ) else { throw PortableChatPersistenceError.invalidLayout }
        try flushDescriptor(profileDescriptor)
        try beforeMutation()
        let durableHead = try PortableLibraryPersistence().decodeProfileHead(
            boundedData(named: "head.json", under: profileDescriptor)
        )
        guard durableHead == head,
              try headSelectsMutationProfileRevision(
                  durableHead,
                  mutation: mutation,
                  proposal: proposal,
                  under: profileDescriptor
              )
        else { throw PortableChatPersistenceError.invalidLayout }
    }

    private func headSelectsMutationProfileRevision(
        _ head: ProfileHead,
        mutation: AcceptProfileProposalMutation,
        proposal: ProfileChangeProposal,
        under profileDescriptor: Int32
    ) throws -> Bool {
        guard head.authority.currentRevisionID == mutation.intendedRevisionID,
              let installed = try loadProfileRevision(
                  selectedBy: head.selection,
                  under: profileDescriptor
              ),
              installed.generation == head.generation,
              installed.statementGeneration == head.statementGeneration,
              installed.createdAt == mutation.acceptedAt
        else { return false }
        let base: ProfileRevision?
        if let parentRevisionID = installed.parentRevisionID {
            base = try loadProfileRevision(
                id: parentRevisionID,
                under: profileDescriptor
            )
        } else {
            base = nil
        }
        let (currentGeneration, underflow) =
            installed.generation.subtractingReportingOverflow(1)
        guard !underflow else { return false }
        let expected = try proposal.applying(
            to: base,
            currentHeadGeneration: currentGeneration,
            intendedRevisionID: mutation.intendedRevisionID,
            createdAt: mutation.acceptedAt
        )
        return installed == expected
    }

    private func headSelectsProfileEvidenceRevision(
        _ head: ProfileHead,
        mutation: PublishProfileEvidenceMutation,
        publication: ProfileEvidencePublication,
        under profileDescriptor: Int32
    ) throws -> Bool {
        guard head.authority.currentRevisionID == mutation.intendedRevisionID,
              let installed = try loadProfileRevision(
                  selectedBy: head.selection,
                  under: profileDescriptor
              ),
              installed.generation == head.generation,
              installed.statementGeneration == head.statementGeneration,
              installed.createdAt == publication.createdAt,
              let parentRevisionID = installed.parentRevisionID
        else { return false }
        let parent = try loadProfileRevision(
            id: parentRevisionID,
            under: profileDescriptor
        )
        let expected = try parent.applying(
            publication,
            intendedRevisionID: mutation.intendedRevisionID,
            createdAt: publication.createdAt
        )
        guard case let .changed(revision) = expected else { return false }
        return installed == revision
    }

    private func makeProfileEvidenceHeadDurable(
        _ head: ProfileHead,
        mutation: PublishProfileEvidenceMutation,
        publication: ProfileEvidencePublication,
        under profileDescriptor: Int32,
        beforeMutation: () throws -> Void
    ) throws {
        try beforeMutation()
        guard try headSelectsProfileEvidenceRevision(
            head,
            mutation: mutation,
            publication: publication,
            under: profileDescriptor
        ) else { throw PortableChatPersistenceError.invalidLayout }
        try flushDescriptor(profileDescriptor)
        try beforeMutation()
        let durableHead = try PortableLibraryPersistence().decodeProfileHead(
            boundedData(named: "head.json", under: profileDescriptor)
        )
        guard durableHead == head,
              try headSelectsProfileEvidenceRevision(
                  durableHead,
                  mutation: mutation,
                  publication: publication,
                  under: profileDescriptor
              )
        else { throw PortableChatPersistenceError.invalidLayout }
    }

    private func loadProfileRevision(
        id: ProfileRevisionID,
        under profileDescriptor: Int32
    ) throws -> ProfileRevision {
        let revisionsDescriptor = try openDirectory(
            named: "revisions",
            under: profileDescriptor
        )
        defer { Darwin.close(revisionsDescriptor) }
        let descriptor = try openDirectory(
            named: id.rawValue,
            under: revisionsDescriptor
        )
        defer { Darwin.close(descriptor) }
        let detachedData = try boundedData(
            named: "revision.sha256",
            under: descriptor
        )
        guard detachedData.count == 64,
              let digest = String(data: detachedData, encoding: .utf8),
              let pointer = try? ProfileRevisionPointer(
                  revisionID: id,
                  sha256: digest
              ),
              let revision = try loadProfileRevision(
                  selectedBy: .revision(pointer),
                  under: profileDescriptor
              )
        else { throw PortableChatPersistenceError.invalidLayout }
        return revision
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
                failure: pending.failure?.rawValue,
                transcriptReadFailure: pending.failure?.transcriptReadFailureSummary
                    .map(PortableCoachTranscriptReadFailureSummaryDTO.init)
            )
        )
    }

    func encodeProfileReconsideration(
        _ reconsideration: ProfileReconsideration
    ) throws -> Data {
        try deterministicJSON(
            ProfileReconsiderationDTO(reconsideration)
        )
    }

    @_spi(InvocationInfrastructure)
    public func encodeMessage(_ message: ChatMessage) throws -> Data {
        let role: String
        let text: String?
        let markdown: String?
        let blocks: [ChatMessageBlockDTO]?
        switch message.content {
        case let .user(value):
            role = "user"
            text = value
            markdown = nil
            blocks = nil
        case let .coach(value):
            role = "coach"
            text = nil
            if message.persistedSchemaVersion < ChatMessage.schemaVersion {
                guard value.count == 1,
                      case let .markdown(legacyMarkdown) = value[0]
                else { throw PortableChatPersistenceError.invalidJSON }
                markdown = legacyMarkdown
                blocks = nil
            } else {
                markdown = nil
                blocks = value.map(ChatMessageBlockDTO.init)
            }
        }
        let data = try deterministicJSON(
            ChatMessageDTO(
                schemaVersion: message.persistedSchemaVersion,
                messageId: message.id.rawValue,
                responsePositionId: message.responsePositionID.rawValue,
                role: role,
                text: text,
                markdown: markdown,
                blocks: blocks,
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

    func encodeProfileProposal(_ proposal: ProfileChangeProposal) throws -> Data {
        let data = try deterministicJSON(
            ProfileChangeProposalDTO(
                schemaVersion: ProfileChangeProposal.schemaVersion,
                proposalId: proposal.id.rawValue,
                chatId: proposal.chatID.rawValue,
                responsePositionId: proposal.responsePositionID.rawValue,
                baseProfile: ProfileProposalBaseDTO(proposal.baseProfile),
                changes: proposal.changes.map(ProfileProposalChangeDTO.init),
                evidenceAppends: proposal.evidenceAppends.isEmpty
                    ? nil
                    : proposal.evidenceAppends.map(
                        ProfileEvidenceAppendDTO.init
                    ),
                createdAt: proposal.createdAt.rawValue
            )
        )
        guard data.count <= Self.maximumRootBytes else {
            throw PortableChatPersistenceError.rootTooLarge
        }
        return data
    }

    func encodeProfileEvidencePublication(
        _ publication: ProfileEvidencePublication
    ) throws -> Data {
        let data = try deterministicJSON(
            ProfileEvidencePublicationDTO(
                schemaVersion: ProfileEvidencePublication.schemaVersion,
                chatId: publication.chatID.rawValue,
                responsePositionId: publication.responsePositionID.rawValue,
                evidenceAppends: publication.evidenceAppends.map(
                    ProfileEvidenceAppendDTO.init
                ),
                createdAt: publication.createdAt.rawValue
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

    private func publicationArtifacts(
        for mutation: PublishCoachInvocationMutation
    ) throws -> InvocationPublicationArtifacts {
        guard let pending = mutation.base.pendingUserTurn else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let published = mutation.replacement
        let proposalData = try mutation.profileProposal.map(
            encodeProfileProposal
        )
        let profileEvidencePublicationData = try mutation
            .profileEvidencePublication.map(encodeProfileEvidencePublication)
        let proof = try invocationEvidenceCodec.makePublicationProof(
            for: mutation,
            evidence: PortableInvocationPublicationSourceEvidence(
                publishedChat: try encodeChat(published.chat),
                stableChat: try encodeStableChat(published.chat),
                memory: try encodeMemory(published.memory),
                pendingUserTurn: try encodePendingUserTurn(pending),
                userMessage: try encodeMessage(mutation.userMessage),
                coachMessage: try encodeMessage(mutation.coachMessage),
                freshDraft: try encodeDraft(mutation.freshDraft),
                proposal: proposalData,
                profileEvidencePublication: profileEvidencePublicationData
            )
        )
        return InvocationPublicationArtifacts(
            proof: proof,
            proposalData: proposalData,
            profileEvidencePublicationData: profileEvidencePublicationData
        )
    }

    private func publicationArtifacts(
        for mutation: PublishProfileReconsiderationInvocationMutation
    ) throws -> ProfileReconsiderationPublicationArtifacts {
        guard let sourceEffect = mutation.base.profileEffect,
              sourceEffect.identity ==
                mutation.reconsideration.sourceEffectIdentity,
              mutation.base.profileReconsideration == mutation.reconsideration
        else { throw PortableChatPersistenceError.invalidLayout }
        let sourceEffectData = try encodeProfileEffect(sourceEffect)
        let reconsiderationData = try encodeProfileReconsideration(
            mutation.reconsideration
        )
        let coachMessageData = try mutation.coachMessage.map(encodeMessage)
        let replacementProposalData = try mutation.replacementProposal.map(
            encodeProfileProposal
        )
        let proof = try invocationEvidenceCodec.makePublicationProof(
            for: mutation,
            evidence: PortableProfileReconsiderationPublicationSourceEvidence(
                baseChat: try encodeChat(mutation.base.chat),
                publishedChat: try encodeChat(mutation.replacement.chat),
                stableChat: try encodeStableChat(mutation.replacement.chat),
                baseMemory: try encodeMemory(mutation.base.memory),
                publishedMemory: try encodeMemory(mutation.replacement.memory),
                sourceEffect: sourceEffectData,
                profileReconsideration: reconsiderationData,
                coachMessage: coachMessageData,
                replacementProposal: replacementProposalData
            )
        )
        return ProfileReconsiderationPublicationArtifacts(
            proof: proof,
            sourceEffectData: sourceEffectData,
            profileReconsiderationData: reconsiderationData,
            coachMessageData: coachMessageData,
            replacementProposalData: replacementProposalData
        )
    }

    private func encodeProfileEffect(_ effect: ChatProfileEffect) throws -> Data {
        switch effect {
        case let .proposal(proposal):
            try encodeProfileProposal(proposal)
        case let .evidencePublication(publication):
            try encodeProfileEvidencePublication(publication)
        }
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
            try validateLibraryRootDescriptor(
                descriptor,
                in: scope,
                expectedProfileStatementGeneration: expectedProfileStatementGeneration
            )
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func openLibraryRootAuthority(
        at url: URL,
        in scope: LibraryScope,
        expectedProfileStatementGeneration: UInt64? = nil
    ) throws -> OpenedLibraryRootAuthority {
        let parentURL = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\")
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let parentDescriptor = parentURL.path.withCString { pointer -> Int32 in
            while true {
                let result = Darwin.open(
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard parentDescriptor >= 0 else {
            throw PortableChatPersistenceError.ioFailure
        }
        let rootDescriptor = name.withCString { pointer -> Int32 in
            while true {
                let result = Darwin.openat(
                    parentDescriptor,
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard rootDescriptor >= 0 else {
            Darwin.close(parentDescriptor)
            if urlHasSymlink(url) {
                throw PortableChatPersistenceError.expectedPathIsSymlink
            }
            throw PortableChatPersistenceError.ioFailure
        }
        do {
            try validateLibraryRootDescriptor(
                rootDescriptor,
                in: scope,
                expectedProfileStatementGeneration: expectedProfileStatementGeneration
            )
            return OpenedLibraryRootAuthority(
                parentDescriptor: parentDescriptor,
                rootDescriptor: rootDescriptor,
                name: name,
                identity: try directoryIdentity(of: rootDescriptor)
            )
        } catch {
            Darwin.close(rootDescriptor)
            Darwin.close(parentDescriptor)
            throw error
        }
    }

    private func withReconciledProfileWritesBeforeChatExposure<Result>(
        at libraryRoot: URL,
        in scope: LibraryScope,
        _ exposure: (
            OpenedLibraryRootAuthority,
            Int32,
            DirectoryIdentity
        ) throws -> Result
    ) throws -> Result {
        let root = try openLibraryRootAuthority(at: libraryRoot, in: scope)
        defer { Darwin.close(root.rootDescriptor) }
        defer { Darwin.close(root.parentDescriptor) }

        let stagingIdentity = try directoryIdentity(
            named: "staging",
            under: root.rootDescriptor
        )
        let stagingDescriptor = try openDirectory(
            named: "staging",
            under: root.rootDescriptor
        )
        defer { Darwin.close(stagingDescriptor) }
        guard try directoryIdentity(of: stagingDescriptor) == stagingIdentity
        else { throw PortableChatPersistenceError.invalidLayout }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }

        let revalidateRoot = {
            try self.revalidateConfiguredRootAuthority(root)
            try self.revalidateLibraryAuthority(
                libraryID: scope.libraryID,
                under: root.rootDescriptor
            )
            guard try self.directoryIdentity(
                named: "staging",
                under: root.rootDescriptor
            ) == stagingIdentity,
                try self.directoryIdentity(of: stagingDescriptor) ==
                    stagingIdentity
            else { throw PortableChatPersistenceError.invalidLayout }
        }
        try revalidateRoot()
        try reconcileStagedChatCandidates(under: root.rootDescriptor)
        try reconcileAcceptedProfileWriteIntentBeforeExposure(
            root: root,
            stagingDescriptor: stagingDescriptor,
            stagingIdentity: stagingIdentity,
            libraryRoot: libraryRoot,
            scope: scope
        )
        try revalidateRoot()
        let result = try exposure(root, stagingDescriptor, stagingIdentity)
        try revalidateRoot()
        return result
    }

    private func reconcileAcceptedProfileWriteIntentBeforeExposure(
        root: OpenedLibraryRootAuthority,
        stagingDescriptor: Int32,
        stagingIdentity: DirectoryIdentity,
        libraryRoot: URL,
        scope: LibraryScope
    ) throws {
        let publicationsIdentity = try directoryIdentity(
            named: "publications",
            under: stagingDescriptor
        )
        let publicationsDescriptor = try openDirectory(
            named: "publications",
            under: stagingDescriptor
        )
        defer { Darwin.close(publicationsDescriptor) }
        guard try directoryIdentity(of: publicationsDescriptor) ==
                publicationsIdentity
        else { throw PortableChatPersistenceError.invalidLayout }

        let profileIdentity = try directoryIdentity(
            named: "profile",
            under: root.rootDescriptor
        )
        let profileDescriptor = try openDirectory(
            named: "profile",
            under: root.rootDescriptor
        )
        defer { Darwin.close(profileDescriptor) }
        guard try directoryIdentity(of: profileDescriptor) == profileIdentity
        else { throw PortableChatPersistenceError.invalidLayout }

        let revisionsIdentity = try directoryIdentity(
            named: "revisions",
            under: profileDescriptor
        )
        let revisionsDescriptor = try openDirectory(
            named: "revisions",
            under: profileDescriptor
        )
        defer { Darwin.close(revisionsDescriptor) }
        guard try directoryIdentity(of: revisionsDescriptor) ==
                revisionsIdentity
        else { throw PortableChatPersistenceError.invalidLayout }

        let chatsIdentity = try directoryIdentity(
            named: "chats",
            under: root.rootDescriptor
        )
        let chatsDescriptor = try openDirectory(
            named: "chats",
            under: root.rootDescriptor
        )
        defer { Darwin.close(chatsDescriptor) }
        guard try directoryIdentity(of: chatsDescriptor) == chatsIdentity
        else { throw PortableChatPersistenceError.invalidLayout }

        var outstanding: (
            chatID: ChatID,
            name: String,
            identity: DirectoryIdentity
        )?
        for name in try listEntryNames(
            under: chatsDescriptor,
            maximumCount: Self.maximumChatCatalogEntries
        ) {
            guard let chatID = try? ChatID(name),
                  !isSymlink(named: name, under: chatsDescriptor)
            else { continue }
            let identity = try directoryIdentity(
                named: name,
                under: chatsDescriptor
            )
            let descriptor = try openDirectory(
                named: name,
                under: chatsDescriptor
            )
            defer { Darwin.close(descriptor) }
            guard try directoryIdentity(of: descriptor) == identity,
                  try directoryIdentity(named: name, under: chatsDescriptor) ==
                    identity
            else { throw PortableChatPersistenceError.invalidLayout }
            guard try entryExists(
                named: "profile-write.json",
                under: descriptor
            ) else { continue }
            guard outstanding == nil else {
                throw PortableChatPersistenceError.invalidLayout
            }
            outstanding = (chatID, name, identity)
        }
        guard let outstanding else { return }

        let chatDescriptor = try openDirectory(
            named: outstanding.name,
            under: chatsDescriptor
        )
        defer { Darwin.close(chatDescriptor) }
        guard try directoryIdentity(of: chatDescriptor) == outstanding.identity
        else { throw PortableChatPersistenceError.invalidLayout }
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }

        let authority = ProfileProposalMutationAuthority(
            root: root,
            stagingDescriptor: stagingDescriptor,
            stagingIdentity: stagingIdentity,
            publicationsDescriptor: publicationsDescriptor,
            publicationsIdentity: publicationsIdentity,
            profileDescriptor: profileDescriptor,
            profileIdentity: profileIdentity,
            revisionsDescriptor: revisionsDescriptor,
            revisionsIdentity: revisionsIdentity,
            chatsDescriptor: chatsDescriptor,
            chatsIdentity: chatsIdentity,
            chatName: outstanding.name,
            chatDescriptor: chatDescriptor,
            chatIdentity: outstanding.identity
        )
        let revalidate = {
            try self.revalidateProfileProposalMutationAuthority(
                authority,
                at: libraryRoot,
                in: scope
            )
        }
        try revalidate()
        try recoverAcceptedProfileWriteIntent(
            expectedChatID: outstanding.chatID,
            authority: authority,
            beforeMutation: revalidate
        )
        try revalidate()
    }

    private func recoverAcceptedProfileWriteIntent(
        expectedChatID: ChatID,
        authority: ProfileProposalMutationAuthority,
        beforeMutation: () throws -> Void
    ) throws {
        let chatDescriptor = authority.chatDescriptor
        let profileDescriptor = authority.profileDescriptor
        let intentData = try boundedData(
            named: "profile-write.json",
            under: chatDescriptor
        )
        let persisted = try decodePersistedProfileWriteIntent(intentData)
        guard persisted.hasRecoveryBinding,
              persisted.chatID == expectedChatID
        else { throw PortableChatPersistenceError.invalidLayout }

        try beforeMutation()
        try flushDescriptor(chatDescriptor)
        try beforeMutation()
        guard try boundedData(
            named: "profile-write.json",
            under: chatDescriptor
        ) == intentData else { throw PortableChatPersistenceError.invalidLayout }

        let proposalData: Data? = if try entryExists(
            named: "proposal.json",
            under: chatDescriptor
        ) {
            try boundedData(named: "proposal.json", under: chatDescriptor)
        } else {
            nil
        }
        let headData = try boundedData(
            named: "head.json",
            under: profileDescriptor
        )
        let head = try PortableLibraryPersistence().decodeProfileHead(headData)

        if try headSelectsBoundProfileWriteIntent(
            head,
            persisted: persisted,
            under: profileDescriptor
        ) {
            let current = try requireRecoverableProfileWriteChat(
                expectedChatID: expectedChatID,
                proposalData: proposalData,
                persisted: persisted,
                intentData: intentData,
                authority: authority
            )
            try makeBoundProfileHeadDurable(
                head,
                persisted: persisted,
                under: profileDescriptor,
                beforeMutation: beforeMutation
            )
            let resolved = if current.profileProposal == nil {
                current
            } else {
                try aggregateResolvingProfileProposal(current)
            }
            _ = try finishAcceptedProfileProposal(
                expected: resolved,
                chatDescriptor: chatDescriptor,
                beforeMutation: beforeMutation
            )
            return
        }

        if proposalData == nil,
           head.authority == persisted.expectedHead
        {
            try beforeMutation()
            try flushDescriptor(authority.revisionsDescriptor)
            try beforeMutation()
            guard !(try entryExists(
                named: persisted.intendedRevisionID.rawValue,
                under: authority.revisionsDescriptor
            )),
                try boundedData(
                    named: "head.json",
                    under: profileDescriptor
                ) == headData,
                try boundedData(
                    named: "profile-write.json",
                    under: chatDescriptor
                ) == intentData,
                case let .readWrite(current) = try loadChat(
                    from: chatDescriptor,
                    expectedID: expectedChatID,
                    reconcileTransients: false,
                    allowsProfileWriteIntent: true
                ), current.profileProposal == nil
            else { throw PortableChatPersistenceError.invalidLayout }
            _ = try finishDiscardedProfileProposal(
                expected: current,
                retainedWriteIntentData: intentData,
                chatDescriptor: chatDescriptor,
                beforeMutation: beforeMutation
            )
            return
        }

        guard head.authority == persisted.expectedHead,
              let proposalData
        else { throw PortableChatPersistenceError.invalidLayout }
        let proposal = try mapPersistedDomainValidation {
            try decodeProfileProposal(proposalData)
        }
        let intent = try decodeProfileWriteIntent(
            intentData,
            proposal: proposal,
            proposalData: proposalData
        )
        guard intent.id == persisted.id,
              intent.intendedRevisionID == persisted.intendedRevisionID,
              intent.chatID == expectedChatID,
              case let .readWrite(current) = try loadChat(
                  from: chatDescriptor,
                  expectedID: expectedChatID,
                  reconcileTransients: false,
                  allowsProfileWriteIntent: true
              ),
              current.profileProposal == proposal
        else { throw PortableChatPersistenceError.invalidLayout }
        let resolved = try aggregateResolvingProfileProposal(current)
        guard case .committed = try finishProfileProposalAcceptance(
            proposal: proposal,
            intent: intent,
            intentData: intentData,
            proposalData: proposalData,
            current: current,
            resolvedBase: resolved,
            initialHeadData: headData,
            initialHead: head,
            chatDescriptor: chatDescriptor,
            profileDescriptor: profileDescriptor,
            revisionsDescriptor: authority.revisionsDescriptor,
            publicationsDescriptor: authority.publicationsDescriptor,
            beforeMutation: beforeMutation
        ) else { throw PortableChatPersistenceError.invalidLayout }
    }

    private func requireRecoverableProfileWriteChat(
        expectedChatID: ChatID,
        proposalData: Data?,
        persisted: PersistedProfileWriteIntent,
        intentData: Data,
        authority: ProfileProposalMutationAuthority
    ) throws -> ChatAggregate {
        guard case let .readWrite(current) = try loadChat(
            from: authority.chatDescriptor,
            expectedID: expectedChatID,
            reconcileTransients: false,
            allowsProfileWriteIntent: true
        ) else { throw PortableChatPersistenceError.invalidLayout }
        guard let proposalData else {
            guard current.profileProposal == nil else {
                throw PortableChatPersistenceError.invalidLayout
            }
            return current
        }
        let proposal = try mapPersistedDomainValidation {
            try decodeProfileProposal(proposalData)
        }
        let intent = try decodeProfileWriteIntent(
            intentData,
            proposal: proposal,
            proposalData: proposalData
        )
        guard intent.id == persisted.id,
              intent.intendedRevisionID == persisted.intendedRevisionID,
              current.profileProposal == proposal
        else { throw PortableChatPersistenceError.invalidLayout }
        let intendedRevision = try proposal.applying(
            to: loadProfileRevision(
                selectedBy: persisted.expectedHead.selection,
                under: authority.profileDescriptor
            ),
            currentHeadGeneration: persisted.expectedHead.generation,
            intendedRevisionID: persisted.intendedRevisionID,
            createdAt: persisted.createdAt
        )
        _ = try requireProfileWriteIntentBindings(
            intentData,
            proposalData: proposalData,
            intendedRevisionData: encodeProfileRevision(intendedRevision),
            requiresRecoveryBinding: true
        )
        return current
    }

    private func headSelectsBoundProfileWriteIntent(
        _ head: ProfileHead,
        persisted: PersistedProfileWriteIntent,
        under profileDescriptor: Int32
    ) throws -> Bool {
        guard let intendedRevisionSHA256 = persisted.intendedRevisionSHA256
        else { return false }
        let (generation, generationOverflow) =
            persisted.expectedHead.generation.addingReportingOverflow(1)
        guard !generationOverflow,
              head.generation == generation,
              case let .revision(pointer) = head.selection,
              pointer.revisionID == persisted.intendedRevisionID,
              pointer.sha256 == intendedRevisionSHA256,
              let intended = try loadProfileRevision(
                  selectedBy: head.selection,
                  under: profileDescriptor
              ),
              intended.revisionID == persisted.intendedRevisionID,
              intended.parentRevisionID ==
                persisted.expectedHead.currentRevisionID,
              intended.generation == generation,
              intended.createdAt == persisted.createdAt,
              Self.sha256(try encodeProfileRevision(intended)) ==
                intendedRevisionSHA256
        else { return false }
        let base = try loadProfileRevision(
            selectedBy: persisted.expectedHead.selection,
            under: profileDescriptor
        )
        let expectedStatementGeneration: UInt64
        if preservesProfileStatementSemantics(from: base, to: intended) {
            expectedStatementGeneration =
                persisted.expectedHead.statementGeneration
        } else {
            let (advanced, overflow) = persisted.expectedHead
                .statementGeneration.addingReportingOverflow(1)
            guard !overflow else { return false }
            expectedStatementGeneration = advanced
        }
        return intended.statementGeneration == expectedStatementGeneration &&
            head.statementGeneration == expectedStatementGeneration
    }

    private func preservesProfileStatementSemantics(
        from base: ProfileRevision?,
        to intended: ProfileRevision
    ) -> Bool {
        let baseStatements = base?.statements ?? []
        guard baseStatements.count == intended.statements.count else {
            return false
        }
        return zip(baseStatements, intended.statements).allSatisfy {
            current, replacement in
            current.statementID == replacement.statementID &&
                current.statementKind == replacement.statementKind &&
                current.wording == replacement.wording
        }
    }

    private func makeBoundProfileHeadDurable(
        _ head: ProfileHead,
        persisted: PersistedProfileWriteIntent,
        under profileDescriptor: Int32,
        beforeMutation: () throws -> Void
    ) throws {
        try beforeMutation()
        guard try headSelectsBoundProfileWriteIntent(
            head,
            persisted: persisted,
            under: profileDescriptor
        ) else { throw PortableChatPersistenceError.invalidLayout }
        try flushDescriptor(profileDescriptor)
        try beforeMutation()
        let durable = try PortableLibraryPersistence().decodeProfileHead(
            boundedData(named: "head.json", under: profileDescriptor)
        )
        guard durable == head,
              try headSelectsBoundProfileWriteIntent(
                  durable,
                  persisted: persisted,
                  under: profileDescriptor
              )
        else { throw PortableChatPersistenceError.invalidLayout }
    }

    private func withProfileProposalMutationAuthority<Result>(
        at libraryRoot: URL,
        in scope: LibraryScope,
        chatID: ChatID,
        _ operation: (ProfileProposalMutationAuthority) throws -> Result
    ) throws -> Result {
        let root = try openLibraryRootAuthority(at: libraryRoot, in: scope)
        defer { Darwin.close(root.rootDescriptor) }
        defer { Darwin.close(root.parentDescriptor) }

        let stagingIdentity = try directoryIdentity(
            named: "staging",
            under: root.rootDescriptor
        )
        let stagingDescriptor = try openDirectory(
            named: "staging",
            under: root.rootDescriptor
        )
        defer { Darwin.close(stagingDescriptor) }
        guard try directoryIdentity(of: stagingDescriptor) == stagingIdentity
        else { throw PortableChatPersistenceError.invalidLayout }
        try acquireExclusiveMutationLock(on: stagingDescriptor)
        defer { releaseMutationLock(on: stagingDescriptor) }

        let publicationsIdentity = try directoryIdentity(
            named: "publications",
            under: stagingDescriptor
        )
        let publicationsDescriptor = try openDirectory(
            named: "publications",
            under: stagingDescriptor
        )
        defer { Darwin.close(publicationsDescriptor) }
        guard try directoryIdentity(of: publicationsDescriptor) ==
                publicationsIdentity
        else { throw PortableChatPersistenceError.invalidLayout }

        let profileIdentity = try directoryIdentity(
            named: "profile",
            under: root.rootDescriptor
        )
        let profileDescriptor = try openDirectory(
            named: "profile",
            under: root.rootDescriptor
        )
        defer { Darwin.close(profileDescriptor) }
        guard try directoryIdentity(of: profileDescriptor) == profileIdentity
        else { throw PortableChatPersistenceError.invalidLayout }

        let revisionsIdentity = try directoryIdentity(
            named: "revisions",
            under: profileDescriptor
        )
        let revisionsDescriptor = try openDirectory(
            named: "revisions",
            under: profileDescriptor
        )
        defer { Darwin.close(revisionsDescriptor) }
        guard try directoryIdentity(of: revisionsDescriptor) ==
                revisionsIdentity
        else { throw PortableChatPersistenceError.invalidLayout }

        let chatsIdentity = try directoryIdentity(
            named: "chats",
            under: root.rootDescriptor
        )
        let chatsDescriptor = try openDirectory(
            named: "chats",
            under: root.rootDescriptor
        )
        defer { Darwin.close(chatsDescriptor) }
        guard try directoryIdentity(of: chatsDescriptor) == chatsIdentity
        else { throw PortableChatPersistenceError.invalidLayout }

        let chatName = chatID.rawValue
        guard try entryExists(named: chatName, under: chatsDescriptor) else {
            throw PortableChatPersistenceError.chatMissing
        }
        let chatIdentity = try directoryIdentity(
            named: chatName,
            under: chatsDescriptor
        )
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

        let authority = ProfileProposalMutationAuthority(
            root: root,
            stagingDescriptor: stagingDescriptor,
            stagingIdentity: stagingIdentity,
            publicationsDescriptor: publicationsDescriptor,
            publicationsIdentity: publicationsIdentity,
            profileDescriptor: profileDescriptor,
            profileIdentity: profileIdentity,
            revisionsDescriptor: revisionsDescriptor,
            revisionsIdentity: revisionsIdentity,
            chatsDescriptor: chatsDescriptor,
            chatsIdentity: chatsIdentity,
            chatName: chatName,
            chatDescriptor: chatDescriptor,
            chatIdentity: chatIdentity
        )
        try revalidateProfileProposalMutationAuthority(
            authority,
            at: libraryRoot,
            in: scope
        )
        let result = try operation(authority)
        try revalidateProfileProposalMutationAuthority(
            authority,
            at: libraryRoot,
            in: scope
        )
        return result
    }

    private func revalidateProfileProposalMutationAuthority(
        _ authority: ProfileProposalMutationAuthority,
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws {
        try revalidateConfiguredRootAuthority(authority.root)
        try revalidateLibraryAuthority(
            libraryID: scope.libraryID,
            under: authority.root.rootDescriptor
        )
        guard try directoryIdentity(
            named: "staging",
            under: authority.root.rootDescriptor
        ) == authority.stagingIdentity,
            try directoryIdentity(of: authority.stagingDescriptor) ==
                authority.stagingIdentity,
            try directoryIdentity(
                named: "publications",
                under: authority.stagingDescriptor
            ) == authority.publicationsIdentity,
            try directoryIdentity(of: authority.publicationsDescriptor) ==
                authority.publicationsIdentity,
            try directoryIdentity(
                named: "profile",
                under: authority.root.rootDescriptor
            ) == authority.profileIdentity,
            try directoryIdentity(of: authority.profileDescriptor) ==
                authority.profileIdentity,
            try directoryIdentity(
                named: "revisions",
                under: authority.profileDescriptor
            ) == authority.revisionsIdentity,
            try directoryIdentity(of: authority.revisionsDescriptor) ==
                authority.revisionsIdentity,
            try directoryIdentity(
                named: "chats",
                under: authority.root.rootDescriptor
            ) == authority.chatsIdentity,
            try directoryIdentity(of: authority.chatsDescriptor) ==
                authority.chatsIdentity,
            try directoryIdentity(
                named: authority.chatName,
                under: authority.chatsDescriptor
            ) == authority.chatIdentity,
            try directoryIdentity(of: authority.chatDescriptor) ==
                authority.chatIdentity
        else { throw PortableChatPersistenceError.invalidLayout }

        // Reopen by the configured URL as a final guard against replacing the
        // Library path while its original descriptor remains valid.
        let configured = try openLibraryRoot(at: libraryRoot, in: scope)
        defer { Darwin.close(configured) }
        guard try directoryIdentity(of: configured) == authority.root.identity
        else { throw PortableChatPersistenceError.invalidLayout }
    }

    private func hasForeignProfileWriteIntent(
        excluding chatName: String,
        under chatsDescriptor: Int32
    ) throws -> Bool {
        for name in try listEntryNames(
            under: chatsDescriptor,
            maximumCount: Self.maximumChatCatalogEntries
        ) where name != chatName {
            guard (try? ChatID(name)) != nil else { continue }
            let identity = try directoryIdentity(
                named: name,
                under: chatsDescriptor
            )
            let hasIntent = try {
                let descriptor = try openDirectory(
                    named: name,
                    under: chatsDescriptor
                )
                defer { Darwin.close(descriptor) }
                guard try directoryIdentity(of: descriptor) == identity,
                      try directoryIdentity(
                          named: name,
                          under: chatsDescriptor
                      ) == identity
                else { throw PortableChatPersistenceError.invalidLayout }
                return try entryExists(
                    named: "profile-write.json",
                    under: descriptor
                )
            }()
            if hasIntent { return true }
        }
        return false
    }

    private func validateLibraryRootDescriptor(
        _ descriptor: Int32,
        in scope: LibraryScope,
        expectedProfileStatementGeneration: UInt64?
    ) throws {
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
    }

    private func revalidateConfiguredRootAuthority(
        _ authority: OpenedLibraryRootAuthority
    ) throws {
        guard try directoryIdentity(of: authority.rootDescriptor) == authority.identity,
              try directoryIdentity(
                  named: authority.name,
                  under: authority.parentDescriptor
              ) == authority.identity
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
    }

    private func revalidateExpectedChatCreationRootIdentity(
        _ expected: SessionProcessingRootIdentity?,
        under rootDescriptor: Int32
    ) throws {
        guard let expected else { return }
        let identity = try directoryIdentity(of: rootDescriptor)
        guard UInt64(truncatingIfNeeded: identity.device) == expected.device,
              UInt64(truncatingIfNeeded: identity.inode) == expected.inode
        else {
            throw PortableChatPersistenceError.creationAuthorityChanged
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
        allowsProfileWriteIntent: Bool = false,
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

        let hasProfileWriteIntent = try entryExists(
            named: "profile-write.json",
            under: chatDescriptor
        )
        guard allowsProfileWriteIntent || !hasProfileWriteIntent else {
            // #32 adds relaunch reconciliation. Until then, preserve an
            // accepted intent and fail closed rather than exposing Discard.
            throw PortableChatPersistenceError.invalidLayout
        }
        let persistedProposalData: Data? = if try entryExists(
            named: "proposal.json",
            under: chatDescriptor
        ) {
            try boundedData(named: "proposal.json", under: chatDescriptor)
        } else {
            nil
        }
        let persistedProfileEvidencePublicationData: Data? = if try entryExists(
            named: "profile-publication.json",
            under: chatDescriptor
        ) {
            try boundedData(
                named: "profile-publication.json",
                under: chatDescriptor
            )
        } else {
            nil
        }
        guard persistedProposalData == nil ||
                persistedProfileEvidencePublicationData == nil
        else { throw PortableChatPersistenceError.invalidLayout }
        if let data = persistedProfileEvidencePublicationData {
            let version = try schemaVersion(in: data)
            if version > UInt64(ProfileEvidencePublication.schemaVersion) {
                return .frozen(
                    FrozenChatSnapshot(chatID: expectedID, reason: .newerSchema)
                )
            }
            guard version == UInt64(ProfileEvidencePublication.schemaVersion) else {
                throw PortableChatPersistenceError.unsupportedOlderSchema
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
                pendingVersion == 3 ||
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
        let profileReconsideration: ProfileReconsideration?
        if try entryExists(
            named: "profile-reconsideration.json",
            under: chatDescriptor
        ) {
            let data = try boundedData(
                named: "profile-reconsideration.json",
                under: chatDescriptor
            )
            let version = try schemaVersion(in: data)
            if version > UInt64(ProfileReconsideration.schemaVersion) {
                return .frozen(
                    FrozenChatSnapshot(chatID: expectedID, reason: .newerSchema)
                )
            }
            guard version == UInt64(ProfileReconsideration.schemaVersion) else {
                throw PortableChatPersistenceError.unsupportedOlderSchema
            }
            profileReconsideration = try mapPersistedDomainValidation {
                try decodeProfileReconsideration(data)
            }
        } else {
            profileReconsideration = nil
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
        let profileProposal: ProfileChangeProposal?
        var removesUncommittedProposal = false
        if let persistedProposalData {
            let proposal = try mapPersistedDomainValidation {
                try decodeProfileProposal(persistedProposalData)
            }
            guard proposal.chatID == chat.id else {
                throw PortableChatPersistenceError.invalidLayout
            }
            let sourceMessages = orderedMessages.filter { message in
                guard message.responsePositionID == proposal.responsePositionID,
                      case .coach = message.content
                else { return false }
                return true
            }
            if sourceMessages.count == 1 {
                guard sourceMessages[0].coachProfile == proposal.baseProfile else {
                    throw PortableChatPersistenceError.invalidLayout
                }
                profileProposal = proposal
            } else if sourceMessages.isEmpty {
                if let publicationProofAuthority,
                   invocationEvidenceCodec.proof(
                       publicationProofAuthority.proof,
                       bindsProposalData: persistedProposalData
                   )
                {
                    switch publicationProofAuthority.proof.intent {
                    case .answerPendingUserTurn:
                        profileProposal = nil
                        removesUncommittedProposal = reconcileTransients
                    case .reconsiderProfileChange:
                        guard chat.manifestRevision >=
                                publicationProofAuthority.proof
                                    .publishedManifestRevision,
                              chat.messageIDs ==
                                publicationProofAuthority.proof.messageIDs,
                              proposal.responsePositionID ==
                                publicationProofAuthority.proof
                                    .responsePositionID,
                              proposal.baseProfile ==
                                publicationProofAuthority.invocation
                                    .preparedProfile
                        else {
                            throw PortableChatPersistenceError.invalidLayout
                        }
                        profileProposal = proposal
                    }
                } else {
                    // A Reconsider result may intentionally publish a reviewed
                    // Proposal without fabricating a coach-history message.
                    profileProposal = proposal
                }
            } else {
                throw PortableChatPersistenceError.invalidLayout
            }
        } else {
            profileProposal = nil
        }

        let profileEvidencePublication: ProfileEvidencePublication?
        var removesUncommittedProfileEvidencePublication = false
        if let publicationData = persistedProfileEvidencePublicationData {
            let publication = try mapPersistedDomainValidation {
                try decodeProfileEvidencePublication(publicationData)
            }
            guard publication.chatID == chat.id else {
                throw PortableChatPersistenceError.invalidLayout
            }
            let sourceMessages = orderedMessages.filter { message in
                guard message.responsePositionID == publication.responsePositionID,
                      case .coach = message.content
                else { return false }
                return true
            }
            if sourceMessages.count == 1 {
                profileEvidencePublication = publication
            } else if sourceMessages.isEmpty,
                      let publicationProofAuthority,
                      invocationEvidenceCodec.proof(
                          publicationProofAuthority.proof,
                          bindsProfileEvidencePublicationData: publicationData
                      )
            {
                profileEvidencePublication = nil
                removesUncommittedProfileEvidencePublication = reconcileTransients
            } else {
                throw PortableChatPersistenceError.invalidLayout
            }
        } else {
            profileEvidencePublication = nil
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
                messages: orderedMessages,
                pendingUserTurn: pendingUserTurn,
                profileProposal: profileProposal,
                profileEvidencePublication: profileEvidencePublication,
                profileReconsideration: profileReconsideration
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
            if removesUncommittedProposal {
                try beforeDestructiveMutation()
                try removeRegularFileIfPresent(
                    named: "proposal.json",
                    under: chatDescriptor
                )
            }
            if removesUncommittedProfileEvidencePublication {
                try beforeDestructiveMutation()
                try removeRegularFileIfPresent(
                    named: "profile-publication.json",
                    under: chatDescriptor
                )
            }
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
            if stagedChatCandidateID(name) != nil,
               let nodeCount = try isOwnedStagedChatCandidate(
                   named: name,
                   under: publicationsDescriptor,
                   budget: &budget
               )
            {
                guard budget.consume(nodeCount) else { break }
                var removalBudget = CandidateCleanupBudget(remaining: nodeCount)
                try removeTree(
                    named: name,
                    under: publicationsDescriptor,
                    component: .candidate,
                    budget: &removalBudget
                )
                removed = true
            } else if stagedProfileRevisionCandidateID(name) != nil,
                      let plan = try stagedProfileRevisionCleanupPlan(
                          named: name,
                          under: publicationsDescriptor,
                          budget: &budget
                      )
            {
                guard budget.consume(plan.nodeCount) else { break }
                try removeStagedProfileRevision(
                    plan,
                    under: publicationsDescriptor,
                    emitsFaults: true
                )
                removed = true
            }
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
        where (Self.isRenamePartialName(name) || Self.isPendingPartialName(name) ||
            Self.isProfilePublicationPartialName(name)) &&
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
        guard invocation.chatID == chat.id else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let terminalFailure = invocation.terminalFailure ?? .coachResponseInterrupted
        if let summary = terminalFailure.transcriptReadFailureSummary {
            let attachmentIDs = Set(chat.attachments.values.map(\.attachmentID))
            guard summary.sessions.allSatisfy({
                attachmentIDs.contains($0.sessionAttachmentID)
            }),
                summary.sessions.count + Int(summary.additionalSessionCount) <=
                attachmentIDs.count
            else { throw PortableChatPersistenceError.invalidLayout }
        }
        let sourceName: String
        let partialName: String
        let replacementData: Data?
        switch invocation.intent {
        case let .answerPendingUserTurn(
            pendingUserTurnID,
            draftID,
            draftVersion,
            responsePositionID
        ):
            guard draftID == chat.draft.draftID,
                  draftVersion == chat.draft.version,
                  try entryExists(
                      named: "pending-user-turn.json",
                      under: chatDescriptor
                  )
            else { throw PortableChatPersistenceError.invalidLayout }
            let pending = try decodePendingUserTurn(
                boundedData(
                    named: "pending-user-turn.json",
                    under: chatDescriptor
                )
            )
            guard pending.id == pendingUserTurnID,
                  pending.draftID == draftID,
                  pending.draftVersion == draftVersion,
                  pending.responsePositionID == responsePositionID
            else { throw PortableChatPersistenceError.invalidLayout }
            sourceName = "pending-user-turn.json"
            partialName =
                ".pending-user-turn.json.\(UUID().uuidString.lowercased()).partial"
            let terminal = pending.replacingFailure(terminalFailure)
            replacementData = terminal == pending
                ? nil
                : try encodePendingUserTurn(terminal)

        case let .reconsiderProfileChange(source, result):
            guard try entryExists(
                named: "profile-reconsideration.json",
                under: chatDescriptor
            ) else { throw PortableChatPersistenceError.invalidLayout }
            let reconsideration = try decodeProfileReconsideration(
                boundedData(
                    named: "profile-reconsideration.json",
                    under: chatDescriptor
                )
            )
            guard reconsideration.sourceEffectIdentity == source,
                  reconsideration.resultResponsePositionID == result
            else { throw PortableChatPersistenceError.invalidLayout }
            sourceName = "profile-reconsideration.json"
            partialName =
                ".profile-reconsideration.json.\(UUID().uuidString.lowercased()).partial"
            let terminal = reconsideration.replacingFailure(terminalFailure)
            replacementData = terminal == reconsideration
                ? nil
                : try encodeProfileReconsideration(terminal)
        }
        if let replacementData {
            var partialExists = false
            defer {
                if partialExists {
                    _ = partialName.withCString {
                        Darwin.unlinkat(chatDescriptor, $0, 0)
                    }
                }
            }
            try writeExclusive(
                replacementData,
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
                sourceName
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
        guard (try? invocation.validateIntent(against: current)) != nil else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let terminalFailure = invocation.terminalFailure ?? failure
        let sourceName: String
        let partialName: String
        let replacementData: Data?
        let expectedAggregate: ChatAggregate
        switch invocation.intent {
        case .answerPendingUserTurn:
            guard let pending = current.pendingUserTurn else {
                throw PortableChatPersistenceError.invalidLayout
            }
            let replacement = pending.replacingFailure(terminalFailure)
            sourceName = "pending-user-turn.json"
            partialName =
                ".pending-user-turn.json.\(UUID().uuidString.lowercased()).partial"
            replacementData = pending == replacement
                ? nil
                : try encodePendingUserTurn(replacement)
            expectedAggregate = try ChatAggregate(
                chat: current.chat,
                memory: current.memory,
                messages: current.messages,
                pendingUserTurn: replacement,
                profileEffect: current.profileEffect
            )
        case .reconsiderProfileChange:
            guard let reconsideration = current.profileReconsideration else {
                throw PortableChatPersistenceError.invalidLayout
            }
            let replacement = reconsideration.replacingFailure(terminalFailure)
            sourceName = "profile-reconsideration.json"
            partialName =
                ".profile-reconsideration.json.\(UUID().uuidString.lowercased()).partial"
            replacementData = reconsideration == replacement
                ? nil
                : try encodeProfileReconsideration(replacement)
            expectedAggregate = try ChatAggregate(
                chat: current.chat,
                memory: current.memory,
                messages: current.messages,
                profileEffect: current.profileEffect,
                profileReconsideration: replacement
            )
        }
        if let replacementData {
            var partialExists = false
            defer {
                if partialExists {
                    _ = partialName.withCString {
                        Darwin.unlinkat(chatDescriptor, $0, 0)
                    }
                }
            }
            try writeExclusive(
                replacementData,
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
                sourceName
            ) == 0 else { throw PortableChatPersistenceError.ioFailure }
            partialExists = false
            try flushDescriptor(chatDescriptor)
            try fault(.afterInvocationAbortPendingFailureInstall)
        }
        try beforeCommitting()
        guard try listEntryNames(under: invocationRoot, maximumCount: 4) ==
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
        ), reopened == expectedAggregate
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
            let entries = try listEntryNames(under: descriptor, maximumCount: 8)
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
        var entries = try listEntryNames(under: invocationRoot, maximumCount: 8)
        let proofPartials = entries.filter(Self.isPublicationProofPartialName)
        let attemptPartials = entries.filter(Self.isAttemptReplacementPartialName)
        let sourceEffectPartials = entries.filter(
            Self.isReconsiderationSourceEffectPartialName
        )
        let replacementProposalPartials = entries.filter(
            Self.isReconsiderationReplacementProposalPartialName
        )
        guard proofPartials.count <= 1,
              attemptPartials.count <= 1,
              sourceEffectPartials.count <= 1,
              replacementProposalPartials.count <= 1,
              entries.count <= 8,
              Set(entries).isSubset(of: Set([
                  "invocation.json",
                  "publication-proof.json",
                  Self.reconsiderationSourceEffectName,
                  Self.reconsiderationReplacementProposalName,
              ] + proofPartials + attemptPartials + sourceEffectPartials +
                  replacementProposalPartials))
        else { throw PortableChatPersistenceError.invalidLayout }
        for partial in proofPartials + attemptPartials + sourceEffectPartials +
            replacementProposalPartials
        {
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
        let sourceEffectData: Data?
        if entries.contains(Self.reconsiderationSourceEffectName) {
            guard isRegularFile(
                named: Self.reconsiderationSourceEffectName,
                under: invocationRoot
            ) else { throw PortableChatPersistenceError.invalidLayout }
            sourceEffectData = try boundedData(
                named: Self.reconsiderationSourceEffectName,
                under: invocationRoot
            )
        } else {
            sourceEffectData = nil
        }
        let replacementProposalData: Data?
        if entries.contains(Self.reconsiderationReplacementProposalName) {
            guard isRegularFile(
                named: Self.reconsiderationReplacementProposalName,
                under: invocationRoot
            ) else { throw PortableChatPersistenceError.invalidLayout }
            replacementProposalData = try boundedData(
                named: Self.reconsiderationReplacementProposalName,
                under: invocationRoot
            )
        } else {
            replacementProposalData = nil
        }
        switch invocation.intent {
        case .answerPendingUserTurn:
            guard sourceEffectData == nil,
                  replacementProposalData == nil
            else { throw PortableChatPersistenceError.invalidLayout }
        case .reconsiderProfileChange:
            if let proof {
                let replacementMatches = replacementProposalData.map { data in
                    invocationEvidenceCodec.proof(
                        proof,
                        bindsProposalData: data
                    )
                } ?? (proof.proposalSHA256 == nil)
                guard case .reconsiderProfileChange = proof.intent,
                      let sourceEffectData,
                      invocationEvidenceCodec.proof(
                          proof,
                          bindsReconsiderationSourceEffectData:
                            sourceEffectData
                      ),
                      (replacementProposalData != nil) ==
                        (proof.proposalSHA256 != nil),
                      replacementMatches
                else { throw PortableChatPersistenceError.invalidLayout }
            } else if replacementProposalData != nil && sourceEffectData == nil {
                throw PortableChatPersistenceError.invalidLayout
            }
        }
        return InvocationDirectoryRecord(
            invocation: invocation,
            publicationProof: proof,
            reconsiderationSourceEffectData: sourceEffectData,
            reconsiderationReplacementProposalData: replacementProposalData
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

    private func inspectInvocationDirectoryForPartialCleanup(
        named name: String,
        expectedLibraryID: LibraryID,
        under invocationsDescriptor: Int32
    ) throws -> InvocationPartialCleanupInspection {
        guard let invocationID = try? CoachInvocationID(name) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let invocationRoot = try openDirectory(
            named: name,
            under: invocationsDescriptor
        )
        defer { Darwin.close(invocationRoot) }
        let rootIdentity = try directoryIdentity(of: invocationRoot)
        guard try directoryIdentity(
            named: name,
            under: invocationsDescriptor
        ) == rootIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
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
            let invocationIdentity = try regularFileLivenessIdentity(
                named: "invocation.json",
                under: invocationRoot
            )
            let record = try loadInvocationDirectoryRecord(
                expectedInvocationID: invocationID,
                expectedLibraryID: expectedLibraryID,
                under: invocationRoot,
                reconcileProofPartial: false
            )
            guard record.invocation.hasSameDurableProjection(
                as: validatedBody.invocation
            ) else {
                throw PortableChatPersistenceError.invalidLayout
            }
            let entries = try listEntryNames(
                under: invocationRoot,
                maximumCount: 8
            )
            let proofPartials = entries.filter(Self.isPublicationProofPartialName)
            let attemptPartials = entries.filter(Self.isAttemptReplacementPartialName)
            let sourceEffectPartials = entries.filter(
                Self.isReconsiderationSourceEffectPartialName
            )
            let replacementProposalPartials = entries.filter(
                Self.isReconsiderationReplacementProposalPartialName
            )
            guard proofPartials.count <= 1,
                  attemptPartials.count <= 1,
                  sourceEffectPartials.count <= 1,
                  replacementProposalPartials.count <= 1,
                  entries.count <= 8,
                  Set(entries).isSubset(of: Set([
                      "invocation.json",
                      "publication-proof.json",
                      Self.reconsiderationSourceEffectName,
                      Self.reconsiderationReplacementProposalName,
                  ] + proofPartials + attemptPartials + sourceEffectPartials +
                      replacementProposalPartials))
            else { throw PortableChatPersistenceError.invalidLayout }
            let partials = try (
                proofPartials + attemptPartials + sourceEffectPartials +
                    replacementProposalPartials
            ).sorted().map {
                InvocationPartialFileIdentity(
                    name: $0,
                    identity: try regularFileLivenessIdentity(
                        named: $0,
                        under: invocationRoot
                    )
                )
            }
            guard try regularFileLivenessIdentity(
                named: "invocation.json",
                under: invocationRoot
            ) == invocationIdentity,
                try directoryIdentity(of: invocationRoot) == rootIdentity,
                try directoryIdentity(
                    named: name,
                    under: invocationsDescriptor
                ) == rootIdentity
            else { throw PortableChatPersistenceError.invalidLayout }
            return .available(InvocationPartialCleanupCandidate(
                record: record,
                plan: InvocationPartialCleanupPlan(
                    name: name,
                    rootIdentity: rootIdentity,
                    invocationIdentity: invocationIdentity,
                    invocation: record.invocation,
                    partials: partials
                )
            ))
        } catch let error as PortableChatPersistenceError {
            guard let snapshot = frozenChatSnapshot(
                for: error,
                chatID: validatedBody.invocation.chatID
            ) else { throw error }
            return .frozen(validatedBody.common, snapshot)
        }
    }

    private func removeBoundInvocationPartial(
        _ partial: InvocationPartialFileIdentity,
        from plan: InvocationPartialCleanupPlan,
        expectedLibraryID: LibraryID,
        under invocationsDescriptor: Int32
    ) throws {
        guard try directoryIdentity(
            named: plan.name,
            under: invocationsDescriptor
        ) == plan.rootIdentity else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let invocationRoot = try openDirectory(
            named: plan.name,
            under: invocationsDescriptor
        )
        defer { Darwin.close(invocationRoot) }
        guard try directoryIdentity(of: invocationRoot) == plan.rootIdentity,
              try regularFileLivenessIdentity(
                  named: "invocation.json",
                  under: invocationRoot
              ) == plan.invocationIdentity
        else { throw PortableChatPersistenceError.invalidLayout }
        let current = try loadInvocationBodyIdentity(
            expectedInvocationID: plan.invocation.id,
            expectedLibraryID: expectedLibraryID,
            under: invocationRoot
        )
        guard current.invocation.hasSameDurableProjection(as: plan.invocation),
              try directoryIdentity(
                  named: plan.name,
                  under: invocationsDescriptor
              ) == plan.rootIdentity,
              try directoryIdentity(of: invocationRoot) == plan.rootIdentity,
              try regularFileLivenessIdentity(
                  named: "invocation.json",
                  under: invocationRoot
              ) == plan.invocationIdentity,
              try regularFileLivenessIdentity(
                  named: partial.name,
                  under: invocationRoot
              ) == partial.identity
        else { throw PortableChatPersistenceError.invalidLayout }
        guard unlinkat(invocationRoot, partial.name, 0) == 0 else {
            throw PortableChatPersistenceError.invalidLayout
        }
        try flushDescriptor(invocationRoot)
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
                    maximumCount: 8
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
        let inspections: [(name: String, result: InvocationDirectoryInspection)] =
            try names.sorted().map { name in
                (
                    name,
                    try inspectInvocationDirectory(
                        named: name,
                        expectedLibraryID: expectedLibraryID,
                        under: invocationsDescriptor,
                        reconcileProofPartial: false
                    )
                )
            }
        for (_, inspection) in inspections {
            if case let .frozen(common, _) = inspection {
                frozenChatIDs.insert(common.chatID)
            }
        }
        // Bind every still-readable root without mutating it. A later sibling
        // classification can therefore freeze the whole Chat before cleanup.
        var candidates: [InvocationPartialCleanupCandidate] = []
        for (name, initialInspection) in inspections {
            guard case let .available(initialRecord) = initialInspection,
                  !frozenChatIDs.contains(initialRecord.invocation.chatID)
            else { continue }
            let reconciled = try inspectInvocationDirectoryForPartialCleanup(
                named: name,
                expectedLibraryID: expectedLibraryID,
                under: invocationsDescriptor
            )
            switch reconciled {
            case let .available(candidate):
                guard candidate.record.invocation.hasSameDurableProjection(
                    as: initialRecord.invocation
                ) else {
                    throw PortableChatPersistenceError.invalidLayout
                }
                candidates.append(candidate)
            case let .frozen(common, _):
                frozenChatIDs.insert(common.chatID)
            }
        }
        let hasCleanableCandidate = candidates.contains {
            !frozenChatIDs.contains($0.record.invocation.chatID) &&
                !$0.plan.partials.isEmpty
        }
        if hasCleanableCandidate {
            try fault(.beforeInvocationPartialCleanup)
            try beforeDestructiveMutation()
            // The callback is the last sanctioned race boundary. Reclassify
            // the complete candidate set before the first unlink so a newly
            // frozen sibling preserves every root belonging to that Chat.
            var revalidatedCandidates: [InvocationPartialCleanupCandidate] = []
            for candidate in candidates {
                guard !frozenChatIDs.contains(candidate.record.invocation.chatID)
                else { continue }
                let revalidated = try inspectInvocationDirectoryForPartialCleanup(
                    named: candidate.plan.name,
                    expectedLibraryID: expectedLibraryID,
                    under: invocationsDescriptor
                )
                switch revalidated {
                case let .available(current):
                    guard current.plan.hasSameBoundEvidence(as: candidate.plan),
                          current.record.invocation.hasSameDurableProjection(
                              as: candidate.record.invocation
                          )
                    else { throw PortableChatPersistenceError.invalidLayout }
                    revalidatedCandidates.append(current)
                case let .frozen(common, _):
                    frozenChatIDs.insert(common.chatID)
                }
            }
            candidates = revalidatedCandidates
            for candidate in candidates
            where !frozenChatIDs.contains(candidate.record.invocation.chatID) {
                for partial in candidate.plan.partials {
                    try beforeDestructiveMutation()
                    // Reopen and revalidate the exact bound root, Invocation,
                    // durable projection, and partial immediately before unlink.
                    try removeBoundInvocationPartial(
                        partial,
                        from: candidate.plan,
                        expectedLibraryID: expectedLibraryID,
                        under: invocationsDescriptor
                    )
                }
            }
        }
        for candidate in candidates
        where !frozenChatIDs.contains(candidate.record.invocation.chatID) {
            do {
                if try invocationIsActive(
                    candidate.record,
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
                    chatID: candidate.record.invocation.chatID
                ) != nil else { throw error }
                frozenChatIDs.insert(candidate.record.invocation.chatID)
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
        try? removeInvocationCandidateDuringReconciliation(
            named: name,
            under: invocationsDescriptor,
            beforeRemoving: {}
        )
    }

    private func removeInvocationCandidateDuringReconciliation(
        named name: String,
        under invocationsDescriptor: Int32,
        beforeRemoving: () throws -> Void
    ) throws {
        let descriptor = try openDirectory(named: name, under: invocationsDescriptor)
        defer { Darwin.close(descriptor) }
        let entries = try listEntryNames(under: descriptor, maximumCount: 8)
        let proofPartials = entries.filter(Self.isPublicationProofPartialName)
        let attemptPartials = entries.filter(Self.isAttemptReplacementPartialName)
        let sourceEffectPartials = entries.filter(
            Self.isReconsiderationSourceEffectPartialName
        )
        let replacementProposalPartials = entries.filter(
            Self.isReconsiderationReplacementProposalPartialName
        )
        guard proofPartials.count <= 1,
              attemptPartials.count <= 1,
              sourceEffectPartials.count <= 1,
              replacementProposalPartials.count <= 1,
              Set(entries).isSubset(of: Set([
                  "invocation.json",
                  "publication-proof.json",
                  Self.reconsiderationSourceEffectName,
                  Self.reconsiderationReplacementProposalName,
              ] + proofPartials + attemptPartials + sourceEffectPartials +
                replacementProposalPartials))
        else { throw PortableChatPersistenceError.invalidLayout }
        for entry in entries.sorted() {
            guard isRegularFile(named: entry, under: descriptor) else {
                throw PortableChatPersistenceError.invalidLayout
            }
            try beforeRemoving()
            guard unlinkat(descriptor, entry, 0) == 0 else {
                throw PortableChatPersistenceError.ioFailure
            }
        }
        if !entries.isEmpty { try flushDescriptor(descriptor) }
        try beforeRemoving()
        guard unlinkat(invocationsDescriptor, name, AT_REMOVEDIR) == 0 else {
            throw PortableChatPersistenceError.invalidLayout
        }
    }

    private func atomicallyRetirePublishedInvocationDirectory(
        _ invocation: CoachInvocation,
        under invocationsDescriptor: Int32,
        beforeMutation: () throws -> Void
    ) throws {
        let finalName = invocation.id.rawValue
        guard try entryExists(named: finalName, under: invocationsDescriptor)
        else { return }
        let finalIdentity = try directoryIdentity(
            named: finalName,
            under: invocationsDescriptor
        )
        let partialName =
            ".\(finalName).\(UUID().uuidString.lowercased()).partial"
        try beforeMutation()
        guard try directoryIdentity(
            named: finalName,
            under: invocationsDescriptor
        ) == finalIdentity,
            renameat(
                invocationsDescriptor,
                finalName,
                invocationsDescriptor,
                partialName
            ) == 0
        else { throw PortableChatPersistenceError.invalidLayout }
        try flushDescriptor(invocationsDescriptor)
        try removeInvocationCandidateDuringReconciliation(
            named: partialName,
            under: invocationsDescriptor,
            beforeRemoving: beforeMutation
        )
        try flushDescriptor(invocationsDescriptor)
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
        try discardPrePublicationEvidence(
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
            maximumCount: 8
        )
        let proofPartials = entries.filter(Self.isPublicationProofPartialName)
        let attemptPartials = entries.filter(Self.isAttemptReplacementPartialName)
        let sourceEffectPartials = entries.filter(
            Self.isReconsiderationSourceEffectPartialName
        )
        let replacementProposalPartials = entries.filter(
            Self.isReconsiderationReplacementProposalPartialName
        )
        guard proofPartials.count <= 1,
              attemptPartials.count <= 1,
              sourceEffectPartials.count <= 1,
              replacementProposalPartials.count <= 1,
              entries.count <= 8,
              Set(entries).isSubset(of: Set([
                  "invocation.json",
                  "publication-proof.json",
                  Self.reconsiderationSourceEffectName,
                  Self.reconsiderationReplacementProposalName,
              ] + proofPartials + attemptPartials + sourceEffectPartials +
                  replacementProposalPartials)),
              entries.contains("invocation.json")
        else { throw PortableChatPersistenceError.invalidLayout }

        var removed = false
        for name in proofPartials + attemptPartials + sourceEffectPartials +
            replacementProposalPartials + [
                "publication-proof.json",
                Self.reconsiderationSourceEffectName,
                Self.reconsiderationReplacementProposalName,
            ]
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

    private func installProfileProposal(
        _ data: Data,
        under chatDescriptor: Int32
    ) throws {
        if try entryExists(named: "proposal.json", under: chatDescriptor) {
            guard try boundedData(
                named: "proposal.json",
                under: chatDescriptor
            ) == data else { throw PortableChatPersistenceError.invalidLayout }
            return
        }
        let partialName = ".proposal.json.\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString {
                    Darwin.unlinkat(chatDescriptor, $0, 0)
                }
            }
        }
        try writeExclusive(data, named: partialName, under: chatDescriptor)
        partialExists = true
        let partialDescriptor = try openRegularFile(
            named: partialName,
            under: chatDescriptor
        )
        defer { Darwin.close(partialDescriptor) }
        try flushDescriptor(partialDescriptor)
        try noReplaceRename(
            from: partialName,
            under: chatDescriptor,
            to: "proposal.json",
            under: chatDescriptor
        )
        partialExists = false
        try flushDescriptor(chatDescriptor)
        try fault(.afterProfileProposalInstall)
    }

    private func installProfileEvidencePublication(
        _ data: Data,
        under chatDescriptor: Int32
    ) throws {
        let finalName = "profile-publication.json"
        if try entryExists(named: finalName, under: chatDescriptor) {
            guard try boundedData(named: finalName, under: chatDescriptor) == data
            else { throw PortableChatPersistenceError.invalidLayout }
            return
        }
        let partialName =
            ".profile-publication.json.\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString {
                    Darwin.unlinkat(chatDescriptor, $0, 0)
                }
            }
        }
        try writeExclusive(data, named: partialName, under: chatDescriptor)
        partialExists = true
        let partialDescriptor = try openRegularFile(
            named: partialName,
            under: chatDescriptor
        )
        defer { Darwin.close(partialDescriptor) }
        try flushDescriptor(partialDescriptor)
        try noReplaceRename(
            from: partialName,
            under: chatDescriptor,
            to: finalName,
            under: chatDescriptor
        )
        partialExists = false
        try flushDescriptor(chatDescriptor)
        try fault(.afterProfileEvidencePublicationInstall)
    }

    private func installProfileReconsideration(
        _ reconsideration: ProfileReconsideration,
        under chatDescriptor: Int32
    ) throws {
        let data = try encodeProfileReconsideration(reconsideration)
        if try entryExists(
            named: "profile-reconsideration.json",
            under: chatDescriptor
        ) {
            guard try boundedData(
                named: "profile-reconsideration.json",
                under: chatDescriptor
            ) == data else { throw PortableChatPersistenceError.collision }
            return
        }
        try writeNewRoot(
            data,
            named: "profile-reconsideration.json",
            under: chatDescriptor,
            points: (
                .beforeProfileReconsiderationPartialWrite,
                .afterProfileReconsiderationPartialWrite,
                .afterProfileReconsiderationFileFlush,
                .afterProfileReconsiderationInstall,
                .afterProfileReconsiderationDirectoryFlush
            )
        )
    }

    private func installMemory(
        _ memory: CoachMemory,
        under memoryDescriptor: Int32
    ) throws {
        let finalName = "\(memory.memoryID.rawValue).json"
        if try entryExists(named: finalName, under: memoryDescriptor) {
            guard try boundedData(named: finalName, under: memoryDescriptor) ==
                (try encodeMemory(memory))
            else {
                throw PortableChatPersistenceError.collision
            }
            return
        }
        try writeNewRoot(
            encodeMemory(memory),
            named: finalName,
            under: memoryDescriptor,
            points: (
                .beforeMemoryPartialWrite,
                .afterMemoryPartialWrite,
                .afterMemoryFileFlush,
                .afterMemoryInstall,
                .afterMemoryDirectoryFlush
            )
        )
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

    private func installInvocationOwnedPublicationArtifact(
        _ data: Data,
        named finalName: String,
        under invocationRoot: Int32,
        installedFault: PortableChatFaultPoint
    ) throws {
        if try entryExists(named: finalName, under: invocationRoot) {
            guard isRegularFile(named: finalName, under: invocationRoot),
                  try boundedData(named: finalName, under: invocationRoot) ==
                    data
            else { throw PortableChatPersistenceError.invalidLayout }
            return
        }
        let partialName = ".\(finalName).\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString {
                    Darwin.unlinkat(invocationRoot, $0, 0)
                }
            }
        }
        try writeExclusive(data, named: partialName, under: invocationRoot)
        partialExists = true
        let descriptor = try openRegularFile(
            named: partialName,
            under: invocationRoot
        )
        defer { Darwin.close(descriptor) }
        try flushDescriptor(descriptor)
        try noReplaceRename(
            from: partialName,
            under: invocationRoot,
            to: finalName,
            under: invocationRoot
        )
        partialExists = false
        try flushDescriptor(invocationRoot)
        try fault(installedFault)
    }

    /// Installs the committed replacement without consuming the
    /// Invocation-owned staged bytes. Those bytes remain the exact recovery
    /// authority until every source-sidecar cleanup step and Invocation-root
    /// retirement has completed.
    private func installCommittedReconsiderationReplacementProposal(
        _ data: Data,
        under chatDescriptor: Int32
    ) throws {
        let partialName =
            ".proposal.json.\(UUID().uuidString.lowercased()).partial"
        var partialExists = false
        defer {
            if partialExists {
                _ = partialName.withCString {
                    Darwin.unlinkat(chatDescriptor, $0, 0)
                }
            }
        }
        try writeExclusive(data, named: partialName, under: chatDescriptor)
        partialExists = true
        let descriptor = try openRegularFile(
            named: partialName,
            under: chatDescriptor
        )
        defer { Darwin.close(descriptor) }
        try flushDescriptor(descriptor)
        guard renameat(
            chatDescriptor,
            partialName,
            chatDescriptor,
            "proposal.json"
        ) == 0 else { throw PortableChatPersistenceError.ioFailure }
        partialExists = false
        try flushDescriptor(chatDescriptor)
        try fault(.afterReconsiderationReplacementProposalCommitInstall)
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

    private func stagedProfileRevisionCandidateID(
        _ name: String
    ) -> ProfileRevisionID? {
        let prefix = ".profile-"
        let suffix = ".partial"
        let uuidLength = 36
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let body = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard body.count > uuidLength + 1 else { return nil }
        let separator = body.index(body.endIndex, offsetBy: -(uuidLength + 1))
        guard body[separator] == "-" else { return nil }
        let revisionText = String(body[..<separator])
        let uuidText = String(body[body.index(after: separator)...])
        guard let revisionID = try? ProfileRevisionID(revisionText),
              let uuid = UUID(uuidString: uuidText),
              uuid.uuidString.lowercased() == uuidText
        else { return nil }
        return revisionID
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

    private static func isProfilePublicationPartialName(_ name: String) -> Bool {
        let prefixes = [
            ".proposal.json.",
            ".profile-publication.json.",
            ".profile-write.json.",
            ".profile-reconsideration.json.",
        ]
        let suffix = ".partial"
        guard let prefix = prefixes.first(where: { name.hasPrefix($0) }),
              name.hasSuffix(suffix)
        else { return false }
        let uuid = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return UUID(uuidString: uuid)?.uuidString.lowercased() == uuid
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

    private static func isReconsiderationSourceEffectPartialName(
        _ name: String
    ) -> Bool {
        isInvocationOwnedArtifactPartialName(
            name,
            finalName: reconsiderationSourceEffectName
        )
    }

    private static func isReconsiderationReplacementProposalPartialName(
        _ name: String
    ) -> Bool {
        isInvocationOwnedArtifactPartialName(
            name,
            finalName: reconsiderationReplacementProposalName
        )
    }

    private static func isInvocationOwnedArtifactPartialName(
        _ name: String,
        finalName: String
    ) -> Bool {
        let prefix = ".\(finalName)."
        let suffix = ".partial"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else {
            return false
        }
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

    private func stagedProfileRevisionCleanupPlan(
        named name: String,
        under parent: Int32,
        budget: inout CandidateCleanupBudget
    ) throws -> StagedProfileRevisionCleanupPlan? {
        guard let revisionID = stagedProfileRevisionCandidateID(name),
              let candidateIdentity = try? directoryIdentity(
                  named: name,
                  under: parent
              ),
              let candidate = try? openDirectory(named: name, under: parent)
        else { return nil }
        defer { Darwin.close(candidate) }
        guard try directoryIdentity(of: candidate) == candidateIdentity,
              try directoryIdentity(named: name, under: parent) == candidateIdentity,
              budget.consume()
        else { return nil }
        guard let entries = try? listEntryNames(
            under: candidate,
            maximumCount: 2
        ) else { return nil }
        let allowed: Set<String> = ["revision.json", "revision.sha256"]
        let entrySet = Set(entries)
        guard entrySet.isSubset(of: allowed),
              entrySet != ["revision.sha256"]
        else { return nil }

        var files: [StagedProfileRevisionCleanupFile] = []
        var dataByName: [String: Data] = [:]
        for entry in entries.sorted() {
            guard budget.consume(),
                  let descriptor = try? openRegularFile(
                      named: entry,
                      under: candidate
                  )
            else { return nil }
            defer { Darwin.close(descriptor) }
            guard let identity = try? cleanupRegularFileIdentity(
                of: descriptor
            ), (try? cleanupRegularFileIdentity(
                named: entry,
                under: candidate
            )) == identity,
                let data = try? boundedData(named: entry, under: candidate),
                (try? cleanupRegularFileIdentity(of: descriptor)) == identity,
                (try? cleanupRegularFileIdentity(
                    named: entry,
                    under: candidate
                )) == identity
            else { return nil }
            dataByName[entry] = data
            files.append(.init(name: entry, identity: identity, data: data))
        }

        if let revisionData = dataByName["revision.json"] {
            guard let revision = try? decodeProfileRevision(revisionData),
                  revision.revisionID == revisionID
            else { return nil }
            if let digestData = dataByName["revision.sha256"] {
                guard digestData == Data(Self.sha256(revisionData).utf8) else {
                    return nil
                }
            }
        }
        guard try directoryIdentity(of: candidate) == candidateIdentity,
              try directoryIdentity(named: name, under: parent) == candidateIdentity,
              Set(try listEntryNames(under: candidate, maximumCount: 2)) == entrySet,
              files.allSatisfy({ file in
                  (try? cleanupRegularFileIdentity(
                      named: file.name,
                      under: candidate
                  )) == file.identity
              })
        else { return nil }
        return StagedProfileRevisionCleanupPlan(
            name: name,
            directoryIdentity: candidateIdentity,
            files: files
        )
    }

    private func removeStagedProfileRevision(
        _ plan: StagedProfileRevisionCleanupPlan,
        under parent: Int32,
        emitsFaults: Bool
    ) throws {
        if emitsFaults { try fault(.beforeStagedProfileRevisionCleanup) }
        let candidate = try openDirectory(named: plan.name, under: parent)
        defer { Darwin.close(candidate) }
        guard try directoryIdentity(of: candidate) == plan.directoryIdentity,
              try directoryIdentity(named: plan.name, under: parent) ==
                plan.directoryIdentity,
              Set(try listEntryNames(under: candidate, maximumCount: 2)) ==
                Set(plan.files.map(\.name))
        else { throw PortableChatPersistenceError.invalidLayout }

        let deletionOrder = plan.files.sorted { lhs, rhs in
            if lhs.name == "revision.sha256" { return true }
            if rhs.name == "revision.sha256" { return false }
            return lhs.name < rhs.name
        }
        var remainingNames = Set(plan.files.map(\.name))
        for file in deletionOrder {
            if emitsFaults {
                try fault(.beforeStagedProfileRevisionLeafCleanup)
            }
            guard Set(try listEntryNames(
                under: candidate,
                maximumCount: remainingNames.count
            )) == remainingNames else {
                throw PortableChatPersistenceError.invalidLayout
            }
            let descriptor = try openRegularFile(
                named: file.name,
                under: candidate
            )
            defer { Darwin.close(descriptor) }
            guard try cleanupRegularFileIdentity(of: descriptor) == file.identity,
                  try cleanupRegularFileIdentity(
                      named: file.name,
                      under: candidate
                  ) == file.identity,
                  try boundedData(named: file.name, under: candidate) == file.data,
                  try cleanupRegularFileIdentity(of: descriptor) == file.identity,
                  try cleanupRegularFileIdentity(
                      named: file.name,
                      under: candidate
                  ) == file.identity
            else { throw PortableChatPersistenceError.invalidLayout }
            guard file.name.withCString({ Darwin.unlinkat(candidate, $0, 0) }) == 0
            else { throw PortableChatPersistenceError.ioFailure }
            remainingNames.remove(file.name)
            var removedMetadata = stat()
            guard Darwin.fstat(descriptor, &removedMetadata) == 0,
                  (removedMetadata.st_mode & S_IFMT) == S_IFREG,
                  removedMetadata.st_nlink == 0,
                  !(try entryExists(named: file.name, under: candidate))
            else { throw PortableChatPersistenceError.invalidLayout }
        }
        guard try listEntryNames(under: candidate, maximumCount: 0).isEmpty,
              try directoryIdentity(of: candidate) == plan.directoryIdentity,
              try directoryIdentity(named: plan.name, under: parent) ==
                plan.directoryIdentity
        else { throw PortableChatPersistenceError.invalidLayout }
        guard plan.name.withCString({
            Darwin.unlinkat(parent, $0, AT_REMOVEDIR)
        }) == 0 else { throw PortableChatPersistenceError.ioFailure }
        guard !(try entryExists(named: plan.name, under: parent)) else {
            throw PortableChatPersistenceError.invalidLayout
        }
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
        case profileRevision
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
            case .profileRevision:
                return ["revision.json", "revision.sha256"].contains(name)
                    ? .leaf
                    : nil
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
        let dto: PendingUserTurnDTO = try decode(PendingUserTurnDTO.self, data)
        let requiredKeys: Set<String> = [
            "schemaVersion", "pendingUserTurnId", "draftId", "draftVersion",
            "responsePositionId",
        ]
        let actualKeys = Set(dictionary.keys)
        let allowedOptionalKeys: Set<String>
        switch dto.schemaVersion {
        case 1, 2, 3:
            allowedOptionalKeys = ["failure"]
        case PendingUserTurn.schemaVersion:
            allowedOptionalKeys = ["failure", "transcriptReadFailure"]
        default:
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        guard actualKeys.isSuperset(of: requiredKeys),
              actualKeys.subtracting(requiredKeys).isSubset(of: allowedOptionalKeys)
        else { throw PortableChatPersistenceError.unknownKey }
        if actualKeys.contains("failure"), dictionary["failure"] is NSNull {
            throw PortableChatPersistenceError.invalidJSON
        }
        if actualKeys.contains("transcriptReadFailure") {
            guard dto.schemaVersion == PendingUserTurn.schemaVersion,
                  let summary = dictionary["transcriptReadFailure"]
                    as? [String: Any]
            else { throw PortableChatPersistenceError.invalidJSON }
            try requireExactKeys(summary, ["sessions", "additionalSessionCount"])
            guard let sessions = summary["sessions"] as? [[String: Any]] else {
                throw PortableChatPersistenceError.invalidJSON
            }
            for session in sessions {
                try requireExactKeys(session, ["sessionAttachmentId", "displayLabel"])
            }
        }
        let failure: PendingUserTurnFailure?
        switch dto.schemaVersion {
        case 1:
            guard dto.transcriptReadFailure == nil else {
                throw PortableChatPersistenceError.invalidJSON
            }
            switch dto.failure {
            case nil: failure = nil
            case PendingUserTurnFailure.coachContextCannotFit.rawValue:
                failure = .coachContextCannotFit
            case .some:
                throw PortableChatPersistenceError.invalidJSON
            }
        case 2:
            guard dto.transcriptReadFailure == nil else {
                throw PortableChatPersistenceError.invalidJSON
            }
            switch dto.failure {
            case nil: failure = nil
            case PendingUserTurnFailure.coachContextCannotFit.rawValue:
                failure = .coachContextCannotFit
            case PendingUserTurnFailure.coachResponseInterrupted.rawValue:
                failure = .coachResponseInterrupted
            case .some:
                throw PortableChatPersistenceError.invalidJSON
            }
        case 3:
            guard dto.transcriptReadFailure == nil else {
                throw PortableChatPersistenceError.invalidJSON
            }
            if let rawFailure = dto.failure {
                guard let parsed = PendingUserTurnFailure(rawValue: rawFailure) else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                failure = parsed
            } else {
                failure = nil
            }
        case PendingUserTurn.schemaVersion:
            if dto.failure == "coachTranscriptReadFailed" {
                guard let summary = try dto.transcriptReadFailure?.domainValue() else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                failure = .coachTranscriptReadFailed(summary)
            } else {
                guard dto.transcriptReadFailure == nil else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                if let rawFailure = dto.failure {
                    guard let parsed = PendingUserTurnFailure(rawValue: rawFailure) else {
                        throw PortableChatPersistenceError.invalidJSON
                    }
                    failure = parsed
                } else {
                    failure = nil
                }
            }
        default:
            preconditionFailure("schema version was validated above")
        }
        return PendingUserTurn(
            id: try PendingUserTurnID(dto.pendingUserTurnId),
            draftID: try ChatDraftID(dto.draftId),
            draftVersion: dto.draftVersion,
            responsePositionID: try ChatResponsePositionID(dto.responsePositionId),
            failure: failure
        )
    }

    private func decodeProfileReconsideration(
        _ data: Data
    ) throws -> ProfileReconsideration {
        let dictionary = try jsonDictionary(data)
        let dto: ProfileReconsiderationDTO = try decode(
            ProfileReconsiderationDTO.self,
            data
        )
        guard dto.schemaVersion == ProfileReconsideration.schemaVersion else {
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        let requiredKeys: Set<String> = [
            "schemaVersion", "sourceEffectIdentity", "resultResponsePositionId",
        ]
        let optionalKeys: Set<String> = ["failure", "transcriptReadFailure"]
        let actualKeys = Set(dictionary.keys)
        guard actualKeys.isSuperset(of: requiredKeys),
              actualKeys.subtracting(requiredKeys).isSubset(of: optionalKeys)
        else { throw PortableChatPersistenceError.unknownKey }
        for key in optionalKeys where actualKeys.contains(key) &&
            dictionary[key] is NSNull
        {
            throw PortableChatPersistenceError.invalidJSON
        }
        guard let source = dictionary["sourceEffectIdentity"] as? [String: Any],
              let sourceKind = source["kind"] as? String
        else { throw PortableChatPersistenceError.invalidJSON }
        switch sourceKind {
        case "proposal":
            try requireExactKeys(source, ["kind", "proposalId"])
        case "evidencePublication":
            try requireExactKeys(source, ["kind", "responsePositionId"])
        default:
            throw PortableChatPersistenceError.invalidJSON
        }
        if actualKeys.contains("transcriptReadFailure") {
            guard let summary = dictionary["transcriptReadFailure"]
                as? [String: Any]
            else { throw PortableChatPersistenceError.invalidJSON }
            try requireExactKeys(summary, ["sessions", "additionalSessionCount"])
            guard let sessions = summary["sessions"] as? [[String: Any]] else {
                throw PortableChatPersistenceError.invalidJSON
            }
            for session in sessions {
                try requireExactKeys(
                    session,
                    ["sessionAttachmentId", "displayLabel"]
                )
            }
        }
        let failure: PendingUserTurnFailure?
        if dto.failure == "coachTranscriptReadFailed" {
            guard let summary = try dto.transcriptReadFailure?.domainValue() else {
                throw PortableChatPersistenceError.invalidJSON
            }
            failure = .coachTranscriptReadFailed(summary)
        } else {
            guard dto.transcriptReadFailure == nil else {
                throw PortableChatPersistenceError.invalidJSON
            }
            if let rawFailure = dto.failure {
                guard let parsed = PendingUserTurnFailure(rawValue: rawFailure) else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                failure = parsed
            } else {
                failure = nil
            }
        }
        return ProfileReconsideration(
            sourceEffectIdentity: try dto.sourceEffectIdentity.domainValue(),
            resultResponsePositionID: try ChatResponsePositionID(
                dto.resultResponsePositionId
            ),
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
        guard schemaVersion == 1 ||
            schemaVersion == ChatMessage.profileProvenanceSchemaVersion ||
            schemaVersion == ChatMessage.schemaVersion
        else {
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
            } else if schemaVersion == ChatMessage.profileProvenanceSchemaVersion {
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
            } else {
                let coachKeys = common.union([
                    "blocks", "profileStatementGeneration",
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
                try validateMessageBlocks(dictionary["blocks"])
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
                  dto.blocks == nil,
                  dto.profileRevisionId == nil,
                  dto.profileStatementGeneration == nil
            else {
                throw PortableChatPersistenceError.invalidJSON
            }
            content = .user(text: text)
            coachProfile = nil
        case "coach":
            guard dto.text == nil else {
                throw PortableChatPersistenceError.invalidJSON
            }
            if dto.schemaVersion == ChatMessage.schemaVersion {
                guard dto.markdown == nil, let blocks = dto.blocks else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                do {
                    content = .coach(blocks: try blocks.map { try $0.domainValue })
                } catch {
                    throw PortableChatPersistenceError.invalidJSON
                }
            } else {
                guard let markdown = dto.markdown, dto.blocks == nil else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                content = .coach(markdown: markdown)
            }
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

    private func decodeProfileProposal(_ data: Data) throws -> ProfileChangeProposal {
        let dictionary = try jsonDictionary(data)
        let required: Set<String> = [
            "schemaVersion", "proposalId", "chatId", "responsePositionId",
            "baseProfile", "changes", "createdAt",
        ]
        let actual = Set(dictionary.keys)
        guard actual == required || actual == required.union(["evidenceAppends"]),
              let base = dictionary["baseProfile"] as? [String: Any],
              let changes = dictionary["changes"] as? [[String: Any]]
        else { throw PortableChatPersistenceError.invalidJSON }
        let baseKeys = Set(base.keys)
        guard baseKeys == ["statementGeneration"] ||
                baseKeys == ["revisionId", "statementGeneration"],
              !(base["revisionId"] is NSNull)
        else { throw PortableChatPersistenceError.unknownKey }
        for change in changes {
            guard let kind = change["kind"] as? String else {
                throw PortableChatPersistenceError.invalidJSON
            }
            switch kind {
            case "add":
                try requireExactKeys(change, ["kind", "statement"])
                try validateProfileProposedStatementJSON(change["statement"])
            case "replace":
                try requireExactKeys(
                    change,
                    ["kind", "target", "replacement"]
                )
                try validateProfileProposalTargetJSON(change["target"])
                try validateProfileProposedStatementJSON(change["replacement"])
            case "retire":
                try requireExactKeys(change, ["kind", "target", "evidence"])
                try validateProfileProposalTargetJSON(change["target"])
                try validateEvidenceReferenceArrayJSON(
                    change["evidence"],
                    allowsEmpty: true
                )
            default:
                throw PortableChatPersistenceError.invalidJSON
            }
        }
        if actual.contains("evidenceAppends") {
            guard let appends = dictionary["evidenceAppends"] as? [[String: Any]],
                  !appends.isEmpty
            else { throw PortableChatPersistenceError.invalidJSON }
            for append in appends {
                try requireExactKeys(append, ["target", "evidence"])
                try validateProfileProposalTargetJSON(append["target"])
                try validateEvidenceReferenceArrayJSON(
                    append["evidence"],
                    allowsEmpty: false
                )
            }
        }
        guard !changes.isEmpty || actual.contains("evidenceAppends") else {
            throw PortableChatPersistenceError.invalidJSON
        }
        let dto: ProfileChangeProposalDTO = try decode(
            ProfileChangeProposalDTO.self,
            data
        )
        guard dto.schemaVersion == ProfileChangeProposal.schemaVersion else {
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        do {
            return try dto.domainValue()
        } catch {
            throw PortableChatPersistenceError.invalidJSON
        }
    }

    private func decodeProfileEvidencePublication(
        _ data: Data
    ) throws -> ProfileEvidencePublication {
        let dictionary = try jsonDictionary(data)
        try requireExactKeys(
            dictionary,
            [
                "schemaVersion", "chatId", "responsePositionId",
                "evidenceAppends", "createdAt",
            ]
        )
        guard let appends = dictionary["evidenceAppends"] as? [[String: Any]],
              !appends.isEmpty
        else { throw PortableChatPersistenceError.invalidJSON }
        for append in appends {
            try requireExactKeys(append, ["target", "evidence"])
            try validateProfileProposalTargetJSON(append["target"])
            try validateEvidenceReferenceArrayJSON(
                append["evidence"],
                allowsEmpty: false
            )
        }
        let dto: ProfileEvidencePublicationDTO = try decode(
            ProfileEvidencePublicationDTO.self,
            data
        )
        guard dto.schemaVersion == ProfileEvidencePublication.schemaVersion else {
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        do {
            return try dto.domainValue()
        } catch {
            throw PortableChatPersistenceError.invalidJSON
        }
    }

    private func validateProfileProposalTargetJSON(_ value: Any?) throws {
        guard let target = value as? [String: Any] else {
            throw PortableChatPersistenceError.invalidJSON
        }
        try requireExactKeys(
            target,
            ["statementId", "statementKind", "wording"]
        )
    }

    private func validateProfileProposedStatementJSON(_ value: Any?) throws {
        guard let statement = value as? [String: Any] else {
            throw PortableChatPersistenceError.invalidJSON
        }
        try requireExactKeys(
            statement,
            ["statementId", "statementKind", "wording", "evidence"]
        )
        try validateEvidenceReferenceArrayJSON(
            statement["evidence"],
            allowsEmpty: true
        )
    }

    private func validateEvidenceReferenceArrayJSON(
        _ value: Any?,
        allowsEmpty: Bool
    ) throws {
        guard let evidence = value as? [[String: Any]],
              allowsEmpty || !evidence.isEmpty
        else { throw PortableChatPersistenceError.invalidJSON }
        for reference in evidence {
            try validateEvidenceReferenceJSON(reference)
        }
    }

    private func validateEvidenceReferenceJSON(
        _ reference: [String: Any]
    ) throws {
        try requireExactKeys(
            reference,
            ["sessionId", "transcriptRevisionId", "target", "display"]
        )
        guard let target = reference["target"] as? [String: Any],
              let targetKind = target["kind"] as? String,
              let display = reference["display"] as? [String: Any]
        else { throw PortableChatPersistenceError.invalidJSON }
        switch targetKind {
        case "wordRange":
            try requireExactKeys(
                target,
                ["kind", "startWordId", "endWordId"]
            )
        case "audioEvent":
            try requireExactKeys(target, ["kind", "audioEventId"])
        default:
            throw PortableChatPersistenceError.invalidJSON
        }
        try requireExactKeys(
            display,
            ["sessionLabel", "trustedText", "startMs", "endMs"]
        )
    }

    private func validateMessageBlocks(_ value: Any?) throws {
        guard let blocks = value as? [[String: Any]], !blocks.isEmpty else {
            throw PortableChatPersistenceError.invalidJSON
        }
        for block in blocks {
            guard let kind = block["kind"] as? String else {
                throw PortableChatPersistenceError.invalidJSON
            }
            switch kind {
            case "markdown":
                try requireExactKeys(block, ["kind", "markdown"])
            case "evidenceObservation":
                try requireExactKeys(block, ["kind", "markdown", "evidence"])
                guard let evidence = block["evidence"] as? [[String: Any]],
                      !evidence.isEmpty
                else { throw PortableChatPersistenceError.invalidJSON }
                for reference in evidence {
                    try requireExactKeys(
                        reference,
                        ["sessionId", "transcriptRevisionId", "target", "display"]
                    )
                    guard let target = reference["target"] as? [String: Any],
                          let targetKind = target["kind"] as? String,
                          let display = reference["display"] as? [String: Any]
                    else { throw PortableChatPersistenceError.invalidJSON }
                    switch targetKind {
                    case "wordRange":
                        try requireExactKeys(
                            target,
                            ["kind", "startWordId", "endWordId"]
                        )
                    case "audioEvent":
                        try requireExactKeys(target, ["kind", "audioEventId"])
                    default:
                        throw PortableChatPersistenceError.invalidJSON
                    }
                    try requireExactKeys(
                        display,
                        [
                            "sessionLabel", "trustedText", "startMs", "endMs",
                        ]
                    )
                }
            default:
                throw PortableChatPersistenceError.invalidJSON
            }
        }
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

    private func acquireProfileReconsiderationFileLease(
        under chatDescriptor: Int32
    ) throws -> PortableProfileReconsiderationFileLease? {
        let descriptor = try openRegularFile(
            named: "profile-reconsideration.json",
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
            if ownsRegistryClaim {
                PortableInvocationLivenessRegistry.release(key)
            }
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
            named: "profile-reconsideration.json",
            under: chatDescriptor
        ) == key else { throw PortableChatPersistenceError.invalidLayout }
        ownsDescriptor = false
        ownsRegistryClaim = false
        ownsFileLock = false
        return PortableProfileReconsiderationFileLease(
            descriptor: descriptor,
            key: key
        )
    }

    private func acquireAndValidateProfileReconsiderationFileLease(
        _ expected: ProfileReconsideration,
        under chatDescriptor: Int32
    ) throws -> PortableProfileReconsiderationFileLease {
        guard let lease = try acquireProfileReconsiderationFileLease(
            under: chatDescriptor
        ) else { throw PortableChatPersistenceError.ioFailure }
        do {
            guard try regularFileLivenessIdentity(
                named: "profile-reconsideration.json",
                under: chatDescriptor
            ) == lease.key,
                try decodeProfileReconsideration(
                    boundedData(
                        named: "profile-reconsideration.json",
                        under: chatDescriptor
                    )
                ) == expected
            else { throw PortableChatPersistenceError.invalidLayout }
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

    private func cleanupRegularFileIdentity(
        of descriptor: Int32
    ) throws -> PortableInvocationLivenessKey {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1
        else { throw PortableChatPersistenceError.invalidLayout }
        return PortableInvocationLivenessKey(
            device: metadata.st_dev,
            inode: metadata.st_ino
        )
    }

    private func cleanupRegularFileIdentity(
        named name: String,
        under parent: Int32
    ) throws -> PortableInvocationLivenessKey {
        var metadata = stat()
        let status = name.withCString {
            Darwin.fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1
        else { throw PortableChatPersistenceError.invalidLayout }
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

    private func acquireSharedMutationLockNonblocking(
        on descriptor: Int32
    ) throws -> Bool {
        try Task.checkCancellation()
        guard audoraFlock(descriptor, LOCK_SH | LOCK_NB) != 0 else { return true }
        if errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR {
            return false
        }
        throw PortableChatPersistenceError.ioFailure
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
                try persistence.reconcileProfileWritesBeforeInvocationRecovery(
                    at: root,
                    in: library
                )
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
        switch result {
        case let .performed(outcome): return outcome
        case .readOnly: return ChatCatalogOutcome.readOnlyLibrary
        case .unavailable: return ChatCatalogOutcome.failed
        }
    }

    public func create(_ commit: NewChatCommit) async -> ChatMutationOutcome {
        await createAuthorized(commit)
    }

    /// Test-support setup path. Product creation crosses the authorized commit
    /// interface above; infrastructure tests use this only to seed later mutation
    /// scenarios that do not exercise new-Chat confirmation.
    func create(_ seed: NewChatSeed) async -> ChatMutationOutcome {
        await createUnbound(seed)
    }

    private func createAuthorized(
        _ commit: NewChatCommit
    ) async -> ChatMutationOutcome {
        let seed = commit.seed
        let outcome = await workspace.withCurrentChatCreationEvidenceAuthority(
            commit.portableEvidenceAuthority,
            in: seed.library
        ) { root, rootIdentity, fingerprints in
            let outcome: ChatMutationOutcome
            do {
                outcome = ChatMutationOutcome.committed(
                    try persistence.create(
                        seed,
                        at: root,
                        expectedAttachmentFingerprints: fingerprints,
                        expectedRootIdentity: rootIdentity
                    )
                )
            } catch PortableChatPersistenceError.collision {
                outcome = ChatMutationOutcome.collision
            } catch PortableChatPersistenceError.creationAuthorityChanged {
                outcome = ChatMutationOutcome.creationAuthorityChanged
            } catch PortableChatPersistenceError.attachmentUnavailable {
                outcome = ChatMutationOutcome.attachmentUnavailable
            } catch let PortableChatPersistenceError
                .profileStatementGenerationChanged(current)
            {
                outcome = ChatMutationOutcome.profileStatementGenerationChanged(current)
            } catch PortableChatPersistenceError.readOnlyLibrary {
                outcome = ChatMutationOutcome.readOnlyLibrary
            } catch {
                if let committed = try? persistence.reconcileCommittedCreate(
                    seed,
                    at: root
                ) {
                    outcome = ChatMutationOutcome.committed(committed)
                } else {
                    outcome = ChatMutationOutcome.failed
                }
            }
            if case .collision = outcome,
               commit.portableRetainsEvidenceAuthorityOnCollision
            {
                return .retain(outcome)
            }
            return .consume(outcome)
        }
        return outcome ?? .creationAuthorityChanged
    }

    private func createUnbound(_ seed: NewChatSeed) async -> ChatMutationOutcome {
        let result: ActiveLibraryOperationResult<ChatMutationOutcome> =
            await workspace.performActiveReadWriteOperation(in: seed.library) { root in
            do {
                return ChatMutationOutcome.committed(try persistence.create(seed, at: root))
            } catch PortableChatPersistenceError.collision {
                return ChatMutationOutcome.collision
            } catch PortableChatPersistenceError.attachmentUnavailable {
                return ChatMutationOutcome.attachmentUnavailable
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
        switch result {
        case let .performed(outcome): return outcome
        case .readOnly: return ChatMutationOutcome.readOnlyLibrary
        case .unavailable: return ChatMutationOutcome.failed
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
        switch result {
        case let .performed(outcome): return outcome
        case .readOnly: return ChatMutationOutcome.readOnlyLibrary
        case .unavailable: return ChatMutationOutcome.failed
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
        switch result {
        case let .performed(outcome): return outcome
        case .readOnly: return .readOnlyLibrary
        case .unavailable: return .failed
        }
    }

    public func load(_ chatID: ChatID, in library: LibraryScope) async -> ChatLoadOutcome {
        let result: ActiveLibraryOperationResult<ChatLoadOutcome> =
            await workspace.performActiveReadWriteOperation(in: library) { root in
            do {
                try persistence.reconcileProfileWritesBeforeInvocationRecovery(
                    at: root,
                    in: library
                )
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

public actor PortableProfileProposalCoordinator: ProfileProposalCoordinating {
    private let persistence: PortableChatPersistence
    private let workspace: PortableLibraryWorkspace

    public init(
        persistence: PortableChatPersistence = PortableChatPersistence(),
        workspace: PortableLibraryWorkspace
    ) {
        self.persistence = persistence
        self.workspace = workspace
    }

    public func assess(
        _ request: AssessProfileEffectRequest
    ) async -> ProfileEffectAssessmentOutcome {
        let result: ActiveLibraryOperationResult<ProfileEffectAssessmentOutcome> =
            await workspace.performActiveReadWriteOperation(
                in: request.library
            ) { root in
                do {
                    return switch try persistence.assessProfileEffect(
                        request,
                        at: root
                    ) {
                    case let .current(current): .current(current)
                    case let .stale(current, basis): .stale(current, basis)
                    }
                } catch PortableChatPersistenceError.readOnlyLibrary {
                    return .readOnlyLibrary
                } catch {
                    return .failed
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly: .readOnlyLibrary
        case .unavailable: .failed
        }
    }

    public func accept(
        _ mutation: AcceptProfileProposalMutation
    ) async -> ProfileProposalMutationOutcome {
        let result: ActiveLibraryOperationResult<ProfileProposalMutationOutcome> =
            await workspace.performActiveReadWriteOperation(
                in: mutation.library
            ) { root in
                do {
                    return Self.map(
                        try persistence.acceptProfileProposal(
                            mutation,
                            at: root
                        )
                    )
                } catch PortableChatPersistenceError.readOnlyLibrary {
                    return .readOnlyLibrary
                } catch {
                    if let committed = try? persistence
                        .reconcileCommittedProfileProposalAcceptance(
                            mutation,
                            at: root
                        )
                    {
                        return .committed(committed)
                    }
                    return .failed
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly: .readOnlyLibrary
        case .unavailable: .failed
        }
    }

    public func discard(
        _ mutation: DiscardProfileProposalMutation
    ) async -> ProfileProposalMutationOutcome {
        let result: ActiveLibraryOperationResult<ProfileProposalMutationOutcome> =
            await workspace.performActiveReadWriteOperation(
                in: mutation.library
            ) { root in
                do {
                    return Self.map(
                        try persistence.discardProfileProposal(
                            mutation,
                            at: root
                        )
                    )
                } catch PortableChatPersistenceError.readOnlyLibrary {
                    return .readOnlyLibrary
                } catch {
                    if let committed = try? persistence
                        .reconcileCommittedProfileProposalDiscard(
                            mutation,
                            at: root
                        )
                    {
                        return .committed(committed)
                    }
                    return .failed
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly: .readOnlyLibrary
        case .unavailable: .failed
        }
    }

    public func publishEvidence(
        _ mutation: PublishProfileEvidenceMutation
    ) async -> ProfileEvidencePublicationMutationOutcome {
        let result:
            ActiveLibraryOperationResult<ProfileEvidencePublicationMutationOutcome> =
            await workspace.performActiveReadWriteOperation(
                in: mutation.library
            ) { root in
                do {
                    return Self.mapEvidence(
                        try persistence.publishProfileEvidence(
                            mutation,
                            at: root
                        )
                    )
                } catch PortableChatPersistenceError.readOnlyLibrary {
                    return .readOnlyLibrary
                } catch {
                    if let committed = try? persistence
                        .reconcileCommittedProfileEvidencePublication(
                            mutation,
                            at: root
                        )
                    {
                        return .committed(committed)
                    }
                    return .failed
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly: .readOnlyLibrary
        case .unavailable: .failed
        }
    }

    public func discardEvidence(
        _ mutation: DiscardProfileEvidencePublicationMutation
    ) async -> ProfileEvidencePublicationMutationOutcome {
        let result:
            ActiveLibraryOperationResult<ProfileEvidencePublicationMutationOutcome> =
            await workspace.performActiveReadWriteOperation(
                in: mutation.library
            ) { root in
                do {
                    return Self.mapEvidence(
                        try persistence.discardProfileEvidencePublication(
                            mutation,
                            at: root
                        )
                    )
                } catch PortableChatPersistenceError.readOnlyLibrary {
                    return .readOnlyLibrary
                } catch {
                    if let committed = try? persistence
                        .reconcileCommittedProfileEvidenceDiscard(
                            mutation,
                            at: root
                        )
                    {
                        return .committed(committed)
                    }
                    return .failed
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly: .readOnlyLibrary
        case .unavailable: .failed
        }
    }

    public func discardReconsiderationFailure(
        _ mutation: DiscardProfileReconsiderationFailureMutation
    ) async -> ProfileEffectMutationOutcome {
        let result: ActiveLibraryOperationResult<ProfileEffectMutationOutcome> =
            await workspace.performActiveReadWriteOperation(
                in: mutation.library
            ) { root in
                do {
                    return Self.map(
                        try persistence.discardProfileReconsiderationFailure(
                            mutation,
                            at: root
                        )
                    )
                } catch PortableChatPersistenceError.readOnlyLibrary {
                    return .readOnlyLibrary
                } catch {
                    if let committed = try? persistence
                        .reconcileCommittedProfileReconsiderationFailureDiscard(
                            mutation,
                            at: root
                        )
                    {
                        return .committed(committed)
                    }
                    return .failed
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly: .readOnlyLibrary
        case .unavailable: .failed
        }
    }

    private nonisolated static func map(
        _ result: PortableChatMutationResult
    ) -> ProfileProposalMutationOutcome {
        switch result {
        case let .committed(aggregate): .committed(aggregate)
        case let .stale(aggregate): .stale(aggregate)
        case .frozen: .failed
        }
    }

    private nonisolated static func mapEvidence(
        _ result: PortableChatMutationResult
    ) -> ProfileEvidencePublicationMutationOutcome {
        switch result {
        case let .committed(aggregate): .committed(aggregate)
        case let .stale(aggregate): .stale(aggregate)
        case .frozen: .failed
        }
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
    let transcriptReadFailure: PortableCoachTranscriptReadFailureSummaryDTO?
}

private struct ProfileReconsiderationDTO: Codable {
    let schemaVersion: UInt32
    let sourceEffectIdentity: ProfileReconsiderationEffectIdentityDTO
    let resultResponsePositionId: String
    let failure: String?
    let transcriptReadFailure: PortableCoachTranscriptReadFailureSummaryDTO?

    init(_ value: ProfileReconsideration) {
        schemaVersion = ProfileReconsideration.schemaVersion
        sourceEffectIdentity = ProfileReconsiderationEffectIdentityDTO(
            value.sourceEffectIdentity
        )
        resultResponsePositionId = value.resultResponsePositionID.rawValue
        failure = value.failure?.rawValue
        transcriptReadFailure = value.failure?.transcriptReadFailureSummary.map(
            PortableCoachTranscriptReadFailureSummaryDTO.init
        )
    }
}

private struct ProfileReconsiderationEffectIdentityDTO: Codable {
    let kind: String
    let proposalId: String?
    let responsePositionId: String?

    init(_ value: ChatProfileEffectIdentity) {
        switch value {
        case let .proposal(proposalID):
            kind = "proposal"
            proposalId = proposalID.rawValue
            responsePositionId = nil
        case let .evidencePublication(responsePositionID):
            kind = "evidencePublication"
            proposalId = nil
            responsePositionId = responsePositionID.rawValue
        }
    }

    func domainValue() throws -> ChatProfileEffectIdentity {
        switch kind {
        case "proposal":
            guard let proposalId, responsePositionId == nil else {
                throw PortableChatPersistenceError.invalidJSON
            }
            return .proposal(try ProfileChangeProposalID(proposalId))
        case "evidencePublication":
            guard proposalId == nil, let responsePositionId else {
                throw PortableChatPersistenceError.invalidJSON
            }
            return .evidencePublication(
                try ChatResponsePositionID(responsePositionId)
            )
        default:
            throw PortableChatPersistenceError.invalidJSON
        }
    }
}

private struct ChatMessageDTO: Codable {
    let schemaVersion: UInt32
    let messageId: String
    let responsePositionId: String
    let role: String
    let text: String?
    let markdown: String?
    let blocks: [ChatMessageBlockDTO]?
    let profileRevisionId: String?
    let profileStatementGeneration: UInt64?
    let createdAt: String
}

private struct ChatMessageBlockDTO: Codable {
    let kind: String
    let markdown: String
    let evidence: [EvidenceReferenceDTO]?

    init(_ block: CoachMessageBlock) {
        switch block {
        case let .markdown(markdown):
            kind = "markdown"
            self.markdown = markdown
            evidence = nil
        case let .evidenceObservation(markdown, references):
            kind = "evidenceObservation"
            self.markdown = markdown
            evidence = references.map(EvidenceReferenceDTO.init)
        }
    }

    var domainValue: CoachMessageBlock {
        get throws {
            switch kind {
            case "markdown":
                guard evidence == nil else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                return .markdown(markdown)
            case "evidenceObservation":
                guard let evidence, !evidence.isEmpty else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                return .evidenceObservation(
                    markdown: markdown,
            evidence: try evidence.map { try $0.domainValue }
                )
            default:
                throw PortableChatPersistenceError.invalidJSON
            }
        }
    }
}

private struct EvidenceReferenceDTO: Codable {
    let sessionId: String
    let transcriptRevisionId: String
    let target: EvidenceReferenceTargetDTO
    let display: EvidenceReferenceDisplayDTO

    init(_ reference: EvidenceReference) {
        sessionId = reference.sessionID.rawValue
        transcriptRevisionId = reference.transcriptRevisionID.rawValue
        target = EvidenceReferenceTargetDTO(reference.target)
        display = EvidenceReferenceDisplayDTO(reference.display)
    }

    var domainValue: EvidenceReference {
        get throws {
            try EvidenceReference(
                sessionID: SessionID(sessionId),
                transcriptRevisionID: TranscriptRevisionID(transcriptRevisionId),
                target: target.domainValue,
                display: display.domainValue
            )
        }
    }
}

private struct EvidenceReferenceTargetDTO: Codable {
    let kind: String
    let startWordId: String?
    let endWordId: String?
    let audioEventId: String?

    init(_ target: EvidenceReferenceTarget) {
        switch target {
        case let .wordRange(startWordID, endWordID):
            kind = "wordRange"
            startWordId = startWordID.rawValue
            endWordId = endWordID.rawValue
            audioEventId = nil
        case let .audioEvent(audioEventID):
            kind = "audioEvent"
            startWordId = nil
            endWordId = nil
            audioEventId = audioEventID.rawValue
        }
    }

    var domainValue: EvidenceReferenceTarget {
        get throws {
            switch kind {
            case "wordRange":
                guard let startWordId, let endWordId, audioEventId == nil else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                return .wordRange(
                    startWordID: try TranscriptWordID(startWordId),
                    endWordID: try TranscriptWordID(endWordId)
                )
            case "audioEvent":
                guard startWordId == nil, endWordId == nil, let audioEventId else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                return .audioEvent(audioEventID: try AudioEventID(audioEventId))
            default:
                throw PortableChatPersistenceError.invalidJSON
            }
        }
    }
}

private struct EvidenceReferenceDisplayDTO: Codable {
    let sessionLabel: String
    let trustedText: String
    let startMs: UInt64
    let endMs: UInt64

    init(_ display: EvidenceReferenceDisplay) {
        sessionLabel = display.sessionLabel
        trustedText = display.trustedText
        startMs = display.startMilliseconds
        endMs = display.endMilliseconds
    }

    var domainValue: EvidenceReferenceDisplay {
        get throws {
            try EvidenceReferenceDisplay(
                sessionLabel: sessionLabel,
                trustedText: trustedText,
                startMilliseconds: startMs,
                endMilliseconds: endMs
            )
        }
    }
}

private struct ProfileRevisionDTO: Codable {
    let schemaVersion: UInt32
    let revisionId: String
    let parentRevisionId: String?
    let generation: UInt64
    let statementGeneration: UInt64
    let createdAt: String
    let statements: [ProfileStatementDTO]

    init(_ value: ProfileRevision) {
        schemaVersion = ProfileRevision.schemaVersion
        revisionId = value.revisionID.rawValue
        parentRevisionId = value.parentRevisionID?.rawValue
        generation = value.generation
        statementGeneration = value.statementGeneration
        createdAt = value.createdAt.rawValue
        statements = value.statements.map(ProfileStatementDTO.init)
    }

    var domainValue: ProfileRevision {
        get throws {
            try ProfileRevision(
                revisionID: ProfileRevisionID(revisionId),
                parentRevisionID: try parentRevisionId.map(
                    ProfileRevisionID.init
                ),
                generation: generation,
                statementGeneration: statementGeneration,
                createdAt: UTCInstant(createdAt),
                statements: try statements.map { try $0.domainValue }
            )
        }
    }
}

private struct ProfileStatementDTO: Codable {
    let statementId: String
    let statementKind: String
    let wording: String
    let supportingSessionCount: UInt32
    let evidence: [EvidenceReferenceDTO]

    init(_ value: ProfileStatement) {
        statementId = value.statementID.rawValue
        statementKind = value.statementKind.rawValue
        wording = value.wording
        supportingSessionCount = value.supportingSessionCount
        evidence = value.evidence.map(EvidenceReferenceDTO.init)
    }

    var domainValue: ProfileStatement {
        get throws {
            guard let kind = ProfileStatementKind(rawValue: statementKind) else {
                throw PortableChatPersistenceError.invalidJSON
            }
            return try ProfileStatement(
                statementID: ProfileStatementID(statementId),
                statementKind: kind,
                wording: wording,
                supportingSessionCount: supportingSessionCount,
                evidence: evidence.map { try $0.domainValue }
            )
        }
    }
}

private struct ProfileWriteIntentDTO: Codable {
    let schemaVersion: UInt32
    let intentId: String
    let proposalId: String
    let chatId: String
    let expectedHead: ProfileWriteExpectedHeadDTO
    let intendedRevisionId: String
    let createdAt: String
    let proposalSha256: String?
    let intendedRevisionSha256: String?

    init(
        _ value: ProfileWriteIntent,
        proposalSha256: String,
        intendedRevisionSha256: String
    ) {
        schemaVersion = 2
        intentId = value.id.rawValue
        proposalId = value.proposalID.rawValue
        chatId = value.chatID.rawValue
        expectedHead = ProfileWriteExpectedHeadDTO(value.expectedHead)
        intendedRevisionId = value.intendedRevisionID.rawValue
        createdAt = value.createdAt.rawValue
        self.proposalSha256 = proposalSha256
        self.intendedRevisionSha256 = intendedRevisionSha256
    }

    func domainValue(
        proposal: ProfileChangeProposal
    ) throws -> ProfileWriteIntent {
        guard proposal.id.rawValue == proposalId,
              proposal.chatID.rawValue == chatId
        else { throw PortableChatPersistenceError.invalidJSON }
        return try ProfileWriteIntent(
            id: ProfileWriteIntentID(intentId),
            proposal: proposal,
            expectedHead: expectedHead.domainValue,
            intendedRevisionID: ProfileRevisionID(intendedRevisionId),
            createdAt: UTCInstant(createdAt)
        )
    }
}

private struct ProfileWriteExpectedHeadDTO: Codable {
    let generation: UInt64
    let statementGeneration: UInt64
    let revisionId: String?
    let revisionSha256: String?

    init(_ value: ProfileHeadAuthority) {
        generation = value.generation
        statementGeneration = value.statementGeneration
        switch value.selection {
        case .null:
            revisionId = nil
            revisionSha256 = nil
        case let .revision(pointer):
            revisionId = pointer.revisionID.rawValue
            revisionSha256 = pointer.sha256
        }
    }

    var domainValue: ProfileHeadAuthority {
        get throws {
            let selection: ProfileSelection
            if let revisionId, let revisionSha256 {
                selection = .revision(
                    try ProfileRevisionPointer(
                        revisionID: ProfileRevisionID(revisionId),
                        sha256: revisionSha256
                    )
                )
            } else if revisionId == nil, revisionSha256 == nil {
                selection = .null
            } else {
                throw PortableChatPersistenceError.invalidJSON
            }
            return ProfileHeadAuthority(
                generation: generation,
                statementGeneration: statementGeneration,
                selection: selection
            )
        }
    }
}

private struct ProfileChangeProposalDTO: Codable {
    let schemaVersion: UInt32
    let proposalId: String
    let chatId: String
    let responsePositionId: String
    let baseProfile: ProfileProposalBaseDTO
    let changes: [ProfileProposalChangeDTO]
    let evidenceAppends: [ProfileEvidenceAppendDTO]?
    let createdAt: String

    func domainValue() throws -> ProfileChangeProposal {
        let id = try ProfileChangeProposalID(proposalId)
        let chatID = try ChatID(chatId)
        let responsePositionID = try ChatResponsePositionID(responsePositionId)
        let baseProfile = try baseProfile.domainValue
        let changes = try changes.map { try $0.domainValue }
        let evidenceAppends = try (evidenceAppends ?? []).map {
            try $0.domainValue
        }
        let createdAt = try UTCInstant(createdAt)
        if changes.isEmpty {
            return try ProfileChangeProposal.reconsidered(
                id: id,
                chatID: chatID,
                responsePositionID: responsePositionID,
                baseProfile: baseProfile,
                changes: changes,
                evidenceAppends: evidenceAppends,
                createdAt: createdAt
            )
        }
        return try ProfileChangeProposal(
            id: id,
            chatID: chatID,
            responsePositionID: responsePositionID,
            baseProfile: baseProfile,
            changes: changes,
            evidenceAppends: evidenceAppends,
            createdAt: createdAt
        )
    }
}

private struct ProfileEvidencePublicationDTO: Codable {
    let schemaVersion: UInt32
    let chatId: String
    let responsePositionId: String
    let evidenceAppends: [ProfileEvidenceAppendDTO]
    let createdAt: String

    func domainValue() throws -> ProfileEvidencePublication {
        try ProfileEvidencePublication(
            chatID: ChatID(chatId),
            responsePositionID: ChatResponsePositionID(responsePositionId),
            evidenceAppends: evidenceAppends.map { try $0.domainValue },
            createdAt: UTCInstant(createdAt)
        )
    }
}

private struct ProfileProposalBaseDTO: Codable {
    let revisionId: String?
    let statementGeneration: UInt64

    init(_ value: CoachProfileProvenance) {
        revisionId = value.revisionID?.rawValue
        statementGeneration = value.statementGeneration
    }

    var domainValue: CoachProfileProvenance {
        get throws {
            CoachProfileProvenance(
                revisionID: try revisionId.map(ProfileRevisionID.init),
                statementGeneration: statementGeneration
            )
        }
    }
}

private struct ProfileProposalTargetDTO: Codable {
    let statementId: String
    let statementKind: String
    let wording: String

    init(_ value: ProfileProposalTarget) {
        statementId = value.statementID.rawValue
        statementKind = value.statementKind.rawValue
        wording = value.wording
    }

    var domainValue: ProfileProposalTarget {
        get throws {
            guard let kind = ProfileStatementKind(rawValue: statementKind) else {
                throw PortableChatPersistenceError.invalidJSON
            }
            return try ProfileProposalTarget(
                statementID: ProfileStatementID(statementId),
                statementKind: kind,
                wording: wording
            )
        }
    }
}

private struct ProfileProposedStatementDTO: Codable {
    let statementId: String
    let statementKind: String
    let wording: String
    let evidence: [EvidenceReferenceDTO]

    init(_ value: ProfileProposedStatement) {
        statementId = value.statementID.rawValue
        statementKind = value.statementKind.rawValue
        wording = value.wording
        evidence = value.evidence.map(EvidenceReferenceDTO.init)
    }

    var domainValue: ProfileProposedStatement {
        get throws {
            guard let kind = ProfileStatementKind(rawValue: statementKind) else {
                throw PortableChatPersistenceError.invalidJSON
            }
            return try ProfileProposedStatement(
                statementID: ProfileStatementID(statementId),
                statementKind: kind,
                wording: wording,
                evidence: evidence.map { try $0.domainValue }
            )
        }
    }
}

private struct ProfileProposalChangeDTO: Codable {
    let kind: String
    let statement: ProfileProposedStatementDTO?
    let target: ProfileProposalTargetDTO?
    let replacement: ProfileProposedStatementDTO?
    let evidence: [EvidenceReferenceDTO]?

    init(_ value: ProfileProposalChange) {
        switch value {
        case let .add(statement):
            kind = "add"
            self.statement = ProfileProposedStatementDTO(statement)
            target = nil
            replacement = nil
            evidence = nil
        case let .replace(target, replacement):
            kind = "replace"
            statement = nil
            self.target = ProfileProposalTargetDTO(target)
            self.replacement = ProfileProposedStatementDTO(replacement)
            evidence = nil
        case let .retire(target, evidence):
            kind = "retire"
            statement = nil
            self.target = ProfileProposalTargetDTO(target)
            replacement = nil
            self.evidence = evidence.map(EvidenceReferenceDTO.init)
        }
    }

    var domainValue: ProfileProposalChange {
        get throws {
            switch kind {
            case "add":
                guard let statement, target == nil, replacement == nil,
                      evidence == nil
                else { throw PortableChatPersistenceError.invalidJSON }
                return .add(statement: try statement.domainValue)
            case "replace":
                guard statement == nil, let target, let replacement,
                      evidence == nil
                else { throw PortableChatPersistenceError.invalidJSON }
                return .replace(
                    target: try target.domainValue,
                    replacement: try replacement.domainValue
                )
            case "retire":
                guard statement == nil, let target, replacement == nil,
                      let evidence
                else { throw PortableChatPersistenceError.invalidJSON }
                return .retire(
                    target: try target.domainValue,
                    evidence: try evidence.map { try $0.domainValue }
                )
            default:
                throw PortableChatPersistenceError.invalidJSON
            }
        }
    }
}

private struct ProfileEvidenceAppendDTO: Codable {
    let target: ProfileProposalTargetDTO
    let evidence: [EvidenceReferenceDTO]

    init(_ value: ProfileEvidenceAppend) {
        target = ProfileProposalTargetDTO(value.target)
        evidence = value.evidence.map(EvidenceReferenceDTO.init)
    }

    var domainValue: ProfileEvidenceAppend {
        get throws {
            try ProfileEvidenceAppend(
                target: target.domainValue,
                evidence: evidence.map { try $0.domainValue }
            )
        }
    }
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
    let reconsiderationSourceEffectData: Data?
    let reconsiderationReplacementProposalData: Data?
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
