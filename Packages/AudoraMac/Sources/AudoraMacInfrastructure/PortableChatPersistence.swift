@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
import Darwin
import Foundation

@_silgen_name("flock")
private func audoraFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

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
    case beforePendingRemoval
    case afterPendingRemoval
    case afterPendingRemovalDirectoryFlush
    case beforeInvocationPartialWrite
    case afterInvocationPartialWrite
    case afterInvocationFileFlush
    case afterInvocationInstall
    case afterInvocationDirectoryFlush
    case afterInvocationAbortMarkerInstall
    case afterInvocationAbortDirectoryRemoval
    case afterInvocationAbortPendingRemoval
    case afterUserMessageInstall
    case afterCoachMessageInstall
    case afterPublicationManifestFileFlush
    case afterPublicationManifestInstall
    case afterPublicationManifestDirectoryFlush
    case beforePublicationCleanup
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
        let loaded = try loadChatForRename(from: chatDescriptor, expectedID: mutation.chatID)
        guard case let .readWrite(current) = loaded else {
            if case let .frozen(frozen) = loaded { return .frozen(frozen) }
            throw PortableChatPersistenceError.invalidLayout
        }
        if let installed = current.pendingUserTurn {
            return installed == mutation.pendingUserTurn ? .committed(current) : .stale(current)
        }
        guard current.chat.draft.draftID == mutation.pendingUserTurn.draftID,
              current.chat.draft.version == mutation.pendingUserTurn.draftVersion
        else {
            return .stale(current)
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
            return .frozen(frozen)
        case let .readWrite(commitAuthority):
            guard commitAuthority == current else { return .stale(commitAuthority) }
        }
        try revalidateLibraryAuthority(
            libraryID: mutation.library.libraryID,
            under: rootDescriptor
        )
        try noReplaceRename(
            from: partialName,
            under: chatDescriptor,
            to: "pending-user-turn.json",
            under: chatDescriptor
        )
        partialExists = false
        try fault(.afterPendingInstall)
        try flushDescriptor(chatDescriptor)
        try fault(.afterPendingDirectoryFlush)
        try fault(.beforePendingFinalRead)
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.chatID,
            reconcileTransients: true
        ), reopened == replacement else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return .committed(reopened)
    }

    public func replacePendingUserTurn(
        _ mutation: ReplacePendingUserTurnMutation,
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
        if current.pendingUserTurn == mutation.replacement {
            return .committed(current)
        }
        guard current.pendingUserTurn == mutation.base else {
            return .stale(current)
        }
        let replacement = try ChatAggregate(
            chat: current.chat,
            memory: current.memory,
            pendingUserTurn: mutation.replacement
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
        try revalidateLibraryAuthority(
            libraryID: mutation.library.libraryID,
            under: rootDescriptor
        )
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
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.chatID,
            reconcileTransients: true
        ), reopened == replacement else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return .committed(reopened)
    }

    public func discardPendingUserTurn(
        _ mutation: DiscardPendingUserTurnMutation,
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
        let loaded = try loadChatForRename(from: chatDescriptor, expectedID: mutation.chatID)
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
        let replacement = try ChatAggregate(chat: current.chat, memory: current.memory)
        try fault(.beforePendingRemoval)
        try revalidateLibraryAuthority(
            libraryID: mutation.library.libraryID,
            under: rootDescriptor
        )
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
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.chatID,
            reconcileTransients: true
        ), reopened == replacement else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return .committed(reopened)
    }

    @_spi(InvocationInfrastructure)
    public func hasActiveInvocation(
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

    /// A freshly composed process has no live provider task for an Invocation
    /// left by its predecessor. Under the Library mutation lock, either finish
    /// committed-publication cleanup or retire that one interrupted authority.
    @_spi(InvocationInfrastructure)
    public func reconcileInterruptedInvocations(
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws {
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
        try reconcileInvocationPartials(under: invocationsDescriptor)

        let candidates = try invocationDirectoryNamesRemovingEmptyResidue(
            under: invocationsDescriptor
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
                under: invocationsDescriptor
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
        guard case let .readWrite(current) = try loadChat(
            from: chatDescriptor,
            expectedID: invocation.chatID,
            reconcileTransients: true
        ) else { throw PortableChatPersistenceError.invalidLayout }

        if try invocationWasPublished(
            invocation,
            aggregate: current,
            under: chatDescriptor
        ) {
            try removeInvocationDirectoryIfPresent(
                invocation,
                under: invocationsDescriptor
            )
            return
        }
        guard (try? invocation.validate(against: current)) != nil else {
            try removeInvocationDirectoryIfPresent(
                invocation,
                under: invocationsDescriptor
            )
            return
        }
        _ = try retireInvocation(
            invocation,
            current: current,
            invocationRoot: invocationRoot,
            invocationsDescriptor: invocationsDescriptor,
            chatDescriptor: chatDescriptor
        )
    }

    @_spi(InvocationInfrastructure)
    public func installInvocation(
        _ mutation: InstallCoachInvocationMutation,
        at libraryRoot: URL
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
        try reconcileInvocationPartials(under: invocationsDescriptor)
        if try hasActiveInvocation(
            under: rootDescriptor,
            expectedLibraryID: mutation.authority.request.library.libraryID
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
        guard case let .readWrite(current) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.authority.request.chatID,
            reconcileTransients: true
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

    @_spi(InvocationInfrastructure)
    public func reconcileInstalledInvocation(
        _ mutation: InstallCoachInvocationMutation,
        at libraryRoot: URL
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
        try reconcileInvocationPartials(under: invocationsDescriptor)
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
        guard case let .readWrite(current) = try loadChat(
                  from: chatDescriptor,
                  expectedID: mutation.authority.request.chatID,
                  reconcileTransients: true
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
        try revalidateLibraryAuthority(libraryID: scope.libraryID, under: rootDescriptor)
        let confirmed = try decodeInvocation(
            boundedData(named: "invocation.json", under: invocationRoot)
        )
        return confirmed == invocation ? confirmed : nil
    }

    @_spi(InvocationInfrastructure)
    public func abortInstalledNewSend(
        _ invocation: CoachInvocation,
        at libraryRoot: URL,
        in scope: LibraryScope
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
        try reconcileInvocationPartials(under: invocationsDescriptor)
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
        guard case let .readWrite(current) = try loadChat(
            from: chatDescriptor,
            expectedID: invocation.chatID,
            reconcileTransients: true
        ) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        guard (try? invocation.validate(against: current)) != nil else {
            try removeInvocationDirectoryIfPresent(
                invocation,
                under: invocationsDescriptor
            )
            return .stale(current)
        }
        return .committed(
            try retireInvocation(
                invocation,
                current: current,
                invocationRoot: invocationRoot,
                invocationsDescriptor: invocationsDescriptor,
                chatDescriptor: chatDescriptor
            )
        )
    }

    @_spi(InvocationInfrastructure)
    public func publishInvocation(
        _ mutation: PublishCoachInvocationMutation,
        at libraryRoot: URL,
        in scope: LibraryScope
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
        try reconcileInvocationPartials(under: invocationsDescriptor)
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
        guard case let .readWrite(current) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.invocation.chatID,
            reconcileTransients: true
        ) else {
            throw PortableChatPersistenceError.invalidLayout
        }
        if current == mutation.replacement {
            try removeInvocationDirectoryIfPresent(
                mutation.invocation,
                under: invocationsDescriptor
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
        try installMessage(
            mutation.userMessage,
            under: messagesDescriptor,
            installedFault: .afterUserMessageInstall
        )
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
        try removeRegularFileIfPresent(named: "pending-user-turn.json", under: chatDescriptor)
        try removeInvocationDirectoryIfPresent(
            mutation.invocation,
            under: invocationsDescriptor
        )
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: mutation.invocation.chatID,
            reconcileTransients: true
        ), reopened == mutation.replacement else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return .committed(reopened)
    }

    @_spi(InvocationInfrastructure)
    public func reconcileCommittedInvocationPublication(
        _ mutation: PublishCoachInvocationMutation,
        at libraryRoot: URL,
        in scope: LibraryScope
    ) throws -> ChatAggregate? {
        guard case let .readWrite(aggregate) = try load(
            mutation.invocation.chatID,
            at: libraryRoot,
            in: scope
        ), aggregate == mutation.replacement else {
            return nil
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
        try removeInvocationDirectoryIfPresent(
            mutation.invocation,
            under: invocationsDescriptor
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

    private func reconcileCommittedMutation(
        in library: LibraryScope,
        chatID: ChatID,
        at libraryRoot: URL,
        matches: (ChatAggregate) -> Bool
    ) throws -> ChatAggregate? {
        let rootDescriptor = try openLibraryRoot(at: libraryRoot, in: library)
        defer { Darwin.close(rootDescriptor) }
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
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              try directoryIdentity(of: chatDescriptor) == chatIdentity,
              case let .readWrite(installed) = try loadChat(
                  from: chatDescriptor,
                  expectedID: chatID,
                  reconcileTransients: true
              ),
              matches(installed)
        else {
            return nil
        }

        try flushDescriptor(chatDescriptor)
        try revalidateLibraryAuthority(libraryID: library.libraryID, under: rootDescriptor)
        guard try directoryIdentity(named: chatName, under: chatsDescriptor) == chatIdentity,
              try directoryIdentity(of: chatDescriptor) == chatIdentity,
              case let .readWrite(confirmed) = try loadChat(
                  from: chatDescriptor,
                  expectedID: chatID,
                  reconcileTransients: true
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
                schemaVersion: ChatMessage.schemaVersion,
                messageId: message.id.rawValue,
                responsePositionId: message.responsePositionID.rawValue,
                role: role,
                text: text,
                markdown: markdown,
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
                schemaVersion: CoachInvocation.schemaVersion,
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
        reconcileTransients: Bool
    ) throws -> LoadedPortableChat {
        let chatData = try boundedData(named: "chat.json", under: chatDescriptor)
        let chatVersion = try schemaVersion(in: chatData)
        if chatVersion > UInt64(Chat.schemaVersion) {
            return .frozen(FrozenChatSnapshot(chatID: expectedID, reason: .newerSchema))
        }
        guard chatVersion == UInt64(Chat.schemaVersion) else {
            throw PortableChatPersistenceError.unsupportedOlderSchema
        }
        let chat = try decodeChat(chatData)
        guard chat.id == expectedID else {
            throw PortableChatPersistenceError.invalidLayout
        }

        for forbidden in ["proposal.json", "profile-write.json"] {
            guard !(try entryExists(named: forbidden, under: chatDescriptor)) else {
                throw PortableChatPersistenceError.invalidLayout
            }
        }
        if reconcileTransients {
            try reconcileAbortingInvocation(chat: chat, under: chatDescriptor)
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
            guard pendingVersion == UInt64(PendingUserTurn.schemaVersion) else {
                throw PortableChatPersistenceError.unsupportedOlderSchema
            }
            decodedPendingUserTurn = try decodePendingUserTurn(pendingData)
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
                let message = try decodeMessage(messageData)
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
        let memory = try decodeMemory(memoryData, attachments: chat.attachments)
        let aggregate = try ChatAggregate(
            chat: chat,
            memory: memory,
            pendingUserTurn: pendingUserTurn
        )
        if reconcileTransients {
            try reconcileRootMutationPartials(under: chatDescriptor)
            try reconcileUnreferencedMessages(
                unreferencedNames + messagePartialNames,
                under: messagesDescriptor
            )
            if removesStalePending {
                try removeRegularFileIfPresent(
                    named: "pending-user-turn.json",
                    under: chatDescriptor
                )
            }
            try reconcileUnreferencedMemorySnapshots(
                currentMemoryID: chat.currentMemoryID,
                under: memoryDescriptor
            )
        }
        return .readWrite(aggregate)
    }

    private func loadChatReconcilingTransients(
        from chatDescriptor: Int32,
        expectedID: ChatID
    ) throws -> LoadedPortableChat {
        try acquireExclusiveMutationLock(on: chatDescriptor)
        defer { releaseMutationLock(on: chatDescriptor) }
        return try loadChat(
            from: chatDescriptor,
            expectedID: expectedID,
            reconcileTransients: true
        )
    }

    private func loadChatForRename(
        from chatDescriptor: Int32,
        expectedID: ChatID,
        reconcileTransients: Bool = true
    ) throws -> LoadedPortableChat {
        do {
            return try loadChat(
                from: chatDescriptor,
                expectedID: expectedID,
                reconcileTransients: reconcileTransients
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

    private func reconcileRootMutationPartials(under chatDescriptor: Int32) throws {
        var removed = false
        for name in try listEntryNames(
            under: chatDescriptor,
            maximumCount: Self.maximumChatRootEntries
        )
        where (Self.isRenamePartialName(name) || Self.isPendingPartialName(name)) &&
            isRegularFile(named: name, under: chatDescriptor)
        {
            guard name.withCString({ Darwin.unlinkat(chatDescriptor, $0, 0) }) == 0 else {
                throw PortableChatPersistenceError.ioFailure
            }
            removed = true
        }
        if removed { try flushDescriptor(chatDescriptor) }
    }

    private func reconcileUnreferencedMemorySnapshots(
        currentMemoryID: CoachMemoryID,
        under memoryDescriptor: Int32
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
            guard name.withCString({ Darwin.unlinkat(memoryDescriptor, $0, 0) }) == 0 else {
                throw PortableChatPersistenceError.ioFailure
            }
            removed = true
        }
        if removed { try flushDescriptor(memoryDescriptor) }
    }

    private func reconcileUnreferencedMessages(
        _ names: [String],
        under messagesDescriptor: Int32
    ) throws {
        var removed = false
        for name in names {
            let isMessage = name.hasSuffix(".json") &&
                (try? ChatMessageID(String(name.dropLast(5)))) != nil
            guard (isMessage || Self.isMessagePartialName(name)),
                  isRegularFile(named: name, under: messagesDescriptor),
                  name.withCString({ Darwin.unlinkat(messagesDescriptor, $0, 0) }) == 0
            else {
                throw PortableChatPersistenceError.invalidLayout
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
        under chatDescriptor: Int32
    ) throws {
        let marker = "aborting-invocation.json"
        guard try entryExists(named: marker, under: chatDescriptor) else { return }
        let invocation = try decodeInvocation(
            boundedData(named: marker, under: chatDescriptor)
        )
        guard invocation.chatID == chat.id,
              invocation.draftID == chat.draft.draftID,
              invocation.draftVersion == chat.draft.version
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        if try entryExists(named: "pending-user-turn.json", under: chatDescriptor) {
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
            try removeRegularFileIfPresent(
                named: "pending-user-turn.json",
                under: chatDescriptor
            )
            try fault(.afterInvocationAbortPendingRemoval)
        }
        try removeRegularFileIfPresent(named: marker, under: chatDescriptor)
    }

    private func retireInvocation(
        _ invocation: CoachInvocation,
        current: ChatAggregate,
        invocationRoot: Int32,
        invocationsDescriptor: Int32,
        chatDescriptor: Int32
    ) throws -> ChatAggregate {
        guard (try? invocation.validate(against: current)) != nil,
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
        guard unlinkat(
            invocationsDescriptor,
            invocation.id.rawValue,
            AT_REMOVEDIR
        ) == 0 else { throw PortableChatPersistenceError.ioFailure }
        try flushDescriptor(invocationsDescriptor)
        try fault(.afterInvocationAbortDirectoryRemoval)
        try reconcileAbortingInvocation(chat: current.chat, under: chatDescriptor)
        guard case let .readWrite(reopened) = try loadChat(
            from: chatDescriptor,
            expectedID: invocation.chatID,
            reconcileTransients: true
        ),
            reopened == (try ChatAggregate(chat: current.chat, memory: current.memory))
        else { throw PortableChatPersistenceError.invalidLayout }
        return reopened
    }

    private func invocationDirectoryNamesRemovingEmptyResidue(
        under invocationsDescriptor: Int32
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
        try reconcileInvocationPartials(under: invocationsDescriptor)
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
                    under: invocationsDescriptor
                )
                continue
            }
            let chatDescriptor = try openDirectory(
                named: invocation.chatID.rawValue,
                under: chatsDescriptor
            )
            defer { Darwin.close(chatDescriptor) }
            guard case let .readWrite(aggregate) = try loadChatReconcilingTransients(
                from: chatDescriptor,
                expectedID: invocation.chatID
            ) else { throw PortableChatPersistenceError.invalidLayout }
            if (try? invocation.validate(against: aggregate)) != nil {
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
                    under: invocationsDescriptor
                )
            } else {
                // A changed Chat can no longer publish through this authority.
                // Retiring the stale root prevents a permanent Library block
                // without touching whatever Pending/Draft now owns the Chat.
                try removeInvocationDirectoryIfPresent(
                    invocation,
                    under: invocationsDescriptor
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
        return true
    }

    private func reconcileInvocationPartials(
        under invocationsDescriptor: Int32
    ) throws {
        let names = try listEntryNames(
            under: invocationsDescriptor,
            maximumCount: Self.maximumInvocationDirectoryEntries
        )
        var removed = false
        for name in names where Self.isInvocationPartialName(name) {
            removeInvocationCandidate(named: name, under: invocationsDescriptor)
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

    private func removeInvocationDirectoryIfPresent(
        _ invocation: CoachInvocation,
        under invocationsDescriptor: Int32
    ) throws {
        let name = invocation.id.rawValue
        guard try entryExists(named: name, under: invocationsDescriptor) else { return }
        let descriptor = try openDirectory(named: name, under: invocationsDescriptor)
        defer { Darwin.close(descriptor) }
        guard try listEntryNames(under: descriptor, maximumCount: 2) == ["invocation.json"],
              try decodeInvocation(
                  boundedData(named: "invocation.json", under: descriptor)
              ) == invocation,
              unlinkat(descriptor, "invocation.json", 0) == 0
        else { throw PortableChatPersistenceError.invalidLayout }
        try flushDescriptor(descriptor)
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
        if let rawFailure = dto.failure {
            guard let parsedFailure = PendingUserTurnFailure(rawValue: rawFailure) else {
                throw PortableChatPersistenceError.invalidJSON
            }
            failure = parsedFailure
        } else {
            failure = nil
        }
        guard dto.schemaVersion == PendingUserTurn.schemaVersion else {
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
        guard let role = dictionary["role"] as? String else {
            throw PortableChatPersistenceError.invalidJSON
        }
        let common: Set<String> = [
            "schemaVersion", "messageId", "responsePositionId", "role", "createdAt",
        ]
        switch role {
        case "user":
            try requireExactKeys(dictionary, common.union(["text"]))
        case "coach":
            try requireExactKeys(dictionary, common.union(["markdown"]))
        default:
            throw PortableChatPersistenceError.invalidJSON
        }
        let dto: ChatMessageDTO = try decode(ChatMessageDTO.self, data)
        guard dto.schemaVersion == ChatMessage.schemaVersion,
              let messageID = try? ChatMessageID(dto.messageId),
              let responsePositionID = try? ChatResponsePositionID(dto.responsePositionId),
              let createdAt = try? UTCInstant(dto.createdAt)
        else {
            throw PortableChatPersistenceError.invalidJSON
        }
        let content: ChatMessageContent
        switch role {
        case "user":
            guard let text = dto.text, dto.markdown == nil else {
                throw PortableChatPersistenceError.invalidJSON
            }
            content = .user(text: text)
        case "coach":
            guard let markdown = dto.markdown, dto.text == nil else {
                throw PortableChatPersistenceError.invalidJSON
            }
            content = .coach(markdown: markdown)
        default:
            throw PortableChatPersistenceError.invalidJSON
        }
        return try ChatMessage(
            id: messageID,
            responsePositionID: responsePositionID,
            content: content,
            createdAt: createdAt
        )
    }

    private func decodeInvocation(_ data: Data) throws -> CoachInvocation {
        let dictionary = try jsonDictionary(data)
        try requireExactKeys(
            dictionary,
            [
                "schemaVersion", "invocationId", "attemptId",
                "providerIdempotencyValue", "libraryId", "chatId", "pendingUserTurnId", "draftId",
                "draftVersion", "responsePositionId", "expectedManifestRevision",
                "admittedAt",
            ]
        )
        let dto: CoachInvocationDTO = try decode(CoachInvocationDTO.self, data)
        guard dto.schemaVersion == CoachInvocation.schemaVersion else {
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        let pending = PendingUserTurn(
            id: try PendingUserTurnID(dto.pendingUserTurnId),
            draftID: try ChatDraftID(dto.draftId),
            draftVersion: dto.draftVersion,
            responsePositionID: try ChatResponsePositionID(dto.responsePositionId)
        )
        return try CoachInvocation(
            id: CoachInvocationID(dto.invocationId),
            attemptID: CoachProviderAttemptID(dto.attemptId),
            providerIdempotencyValue: ProviderIdempotencyValue(
                dto.providerIdempotencyValue
            ),
            library: LibraryScope(libraryID: try LibraryID(dto.libraryId)),
            chatID: ChatID(dto.chatId),
            pendingUserTurn: pending,
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

    private func directoryIdentity(of descriptor: Int32) throws -> DirectoryIdentity {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return DirectoryIdentity(device: metadata.st_dev, inode: metadata.st_ino)
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
    private let persistence: PortableChatPersistence
    private let workspace: PortableLibraryWorkspace
    private let chats: PortableChatStore
    private var reconciledLibraries: Set<LibraryID> = []

    public init(
        persistence: PortableChatPersistence = PortableChatPersistence(),
        workspace: PortableLibraryWorkspace
    ) {
        self.persistence = persistence
        self.workspace = workspace
        chats = PortableChatStore(persistence: persistence, workspace: workspace)
    }

    public func resolvePending(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingResolutionOutcome {
        switch await chats.load(request.chatID, in: request.library) {
        case let .loaded(aggregate):
            do {
                return .eligible(
                    try InvocationPendingAuthority(request: request, aggregate: aggregate)
                )
            } catch {
                return .ineligible(aggregate)
            }
        case .frozen, .missing, .readOnlyLibrary:
            return .ineligible(nil)
        case .failed:
            return .unavailable
        }
    }

    public func checkActiveInvocation(
        in library: LibraryScope
    ) async -> InvocationActiveCheckOutcome {
        let requiresRelaunchReconciliation = !reconciledLibraries.contains(
            library.libraryID
        )
        let result: ActiveLibraryOperationResult<InvocationActiveCheckOutcome> =
            await workspace.performActiveReadWriteOperation(in: library) { root in
                do {
                    if requiresRelaunchReconciliation {
                        try persistence.reconcileInterruptedInvocations(
                            at: root,
                            in: library
                        )
                    }
                    return try persistence.hasActiveInvocation(at: root, in: library)
                        ? .exists
                        : .none
                } catch {
                    return .unavailable
                }
            }
        switch result {
        case let .performed(outcome):
            if requiresRelaunchReconciliation, outcome != .unavailable {
                reconciledLibraries.insert(library.libraryID)
            }
            return outcome
        case .readOnly, .unavailable:
            return .unavailable
        }
    }

    public func installInvocation(
        _ mutation: InstallCoachInvocationMutation
    ) async -> InvocationInstallOutcome {
        let result: ActiveLibraryOperationResult<InvocationInstallOutcome> =
            await workspace.performActiveReadWriteOperation(
                in: mutation.authority.request.library
            ) { root in
                do {
                    return try persistence.installInvocation(mutation, at: root)
                } catch {
                    if let installed = try? persistence.reconcileInstalledInvocation(
                        mutation,
                        at: root
                    ) {
                        return .installed(installed)
                    }
                    return .failed
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly, .unavailable: .failed
        }
    }

    public func markContextCapacityFailure(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome {
        let mutation: ReplacePendingUserTurnMutation
        do {
            mutation = try ReplacePendingUserTurnMutation(
                library: authority.request.library,
                chatID: authority.request.chatID,
                base: authority.pendingUserTurn,
                replacement: authority.pendingUserTurn.replacingFailure(
                    .coachContextCannotFit
                )
            )
        } catch {
            return .failed
        }
        return invocationMutationOutcome(await chats.replacePendingUserTurn(mutation))
    }

    public func rejectNewSend(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome {
        invocationMutationOutcome(
            await chats.discardPendingUserTurn(
                DiscardPendingUserTurnMutation(
                    library: authority.request.library,
                    chatID: authority.request.chatID,
                    pendingUserTurn: authority.pendingUserTurn
                )
            )
        )
    }

    public func abortInstalledNewSend(
        _ invocation: CoachInvocation
    ) async -> InvocationPendingMutationOutcome {
        let scope = LibraryScope(libraryID: invocation.libraryID)
        let result: ActiveLibraryOperationResult<InvocationPendingMutationOutcome> =
            await workspace.performActiveReadWriteOperation(in: scope) { root in
                do {
                    switch try persistence.abortInstalledNewSend(
                        invocation,
                        at: root,
                        in: scope
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
        let scope = LibraryScope(libraryID: mutation.invocation.libraryID)
        let result: ActiveLibraryOperationResult<InvocationPublicationOutcome> =
            await workspace.performActiveReadWriteOperation(in: scope) { root in
                do {
                    switch try persistence.publishInvocation(
                        mutation,
                        at: root,
                        in: scope
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
                            in: scope
                        )
                    {
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
