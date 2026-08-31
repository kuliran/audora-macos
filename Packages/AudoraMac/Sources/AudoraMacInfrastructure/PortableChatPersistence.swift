import AudoraApplication
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
        try deterministicJSON(
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
                responsePositionId: pending.responsePositionID.rawValue
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
        let pendingUserTurn: PendingUserTurn?
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
            pendingUserTurn = try decodePendingUserTurn(pendingData)
        } else {
            pendingUserTurn = nil
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
        guard chat.messageIDs.isEmpty, messageEntries.isEmpty else {
            throw PortableChatPersistenceError.invalidLayout
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
        try requireExactKeys(
            dictionary,
            [
                "schemaVersion", "pendingUserTurnId", "draftId", "draftVersion",
                "responsePositionId",
            ]
        )
        let dto: PendingUserTurnDTO = try decode(PendingUserTurnDTO.self, data)
        guard dto.schemaVersion == PendingUserTurn.schemaVersion else {
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        return PendingUserTurn(
            id: try PendingUserTurnID(dto.pendingUserTurnId),
            draftID: try ChatDraftID(dto.draftId),
            draftVersion: dto.draftVersion,
            responsePositionID: try ChatResponsePositionID(dto.responsePositionId)
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
        switch result {
        case let .performed(outcome): return outcome
        case .readOnly: return ChatCatalogOutcome.readOnlyLibrary
        case .unavailable: return ChatCatalogOutcome.failed
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
