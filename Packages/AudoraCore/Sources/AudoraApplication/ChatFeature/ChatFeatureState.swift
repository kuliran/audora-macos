import AudoraDomain

public enum FrozenChatReason: String, Equatable, Sendable {
    case corrupt
    case newerSchema
    case unsupportedSchema
}

public struct FrozenChatSnapshot: Equatable, Sendable {
    public let chatID: ChatID
    public let reason: FrozenChatReason

    public init(chatID: ChatID, reason: FrozenChatReason) {
        self.chatID = chatID
        self.reason = reason
    }
}

public struct ChatRowSnapshot: Equatable, Sendable {
    public enum Availability: Equatable, Sendable {
        case available
        case frozen(FrozenChatReason)
    }

    public let chatID: ChatID
    public let title: ChatTitle?
    public let createdAt: UTCInstant?
    public let updatedAt: UTCInstant?
    public let availability: Availability

    public init(aggregate: ChatAggregate) {
        chatID = aggregate.chat.id
        title = aggregate.chat.title
        createdAt = aggregate.chat.createdAt
        updatedAt = aggregate.chat.updatedAt
        availability = .available
    }

    public init(frozen: FrozenChatSnapshot) {
        chatID = frozen.chatID
        title = nil
        createdAt = nil
        updatedAt = nil
        availability = .frozen(frozen.reason)
    }
}

public struct ChatCatalogSnapshot: Equatable, Sendable {
    public let allRows: [ChatRowSnapshot]
    public let visibleRows: [ChatRowSnapshot]

    public init(allRows: [ChatRowSnapshot], visibleRows: [ChatRowSnapshot]) {
        self.allRows = allRows
        self.visibleRows = visibleRows
    }
}

public enum ChatNotice: String, Equatable, Sendable {
    case invalidTitle
    case createFailed
    case createCollisionLimitReached
    case renameFailed
    case staleRename
    case chatMissing
    case chatOpenFailed
    case chatFrozen
    case catalogFailed
    case readOnlyLibrary
    case invalidDraft
    case draftSaveFailed
    case draftChanged
    case pendingUserTurnFailed
    case coachContextUnavailable
    case messageMustBeShortened
    case attachmentCatalogFailed
    case qualifiedCoachConfigurationUnavailable
}

public enum CoachContextAdvisoryState: Equatable, Sendable {
    case notRequested
    case quoting
    case available(CoachContextQuote)
    case messageTooLong(maximumUTF8Bytes: Int)
    case unavailable(CoachContextUnavailableReason)
}

public enum ChatComposerState: Equatable, Sendable {
    case editable(ChatDraft, isDirty: Bool)
    case locked(ChatDraft, PendingUserTurn)

    public var draft: ChatDraft {
        switch self {
        case let .editable(draft, _), let .locked(draft, _): draft
        }
    }
}

public struct ChatFeatureState: Equatable, Sendable {
    public enum Catalog: Equatable, Sendable {
        case notLoaded
        case loading
        case ready(ChatCatalogSnapshot)
        case failed
    }

    public enum Selection: Equatable, Sendable {
        case none
        case opening(ChatID)
        case open(ChatAggregate)
        case frozen(FrozenChatSnapshot)
    }

    public enum Activity: Equatable, Sendable {
        case creating
        case renaming(ChatID)
        case lockingDraft(ChatID)
        case retryingPendingUserTurn(ChatID)
        case discardingPendingUserTurn(ChatID)
    }

    public let catalog: Catalog
    public let filterQuery: ChatFilterQuery
    public let selection: Selection
    public let composer: ChatComposerState?
    public let contextAdvisory: CoachContextAdvisoryState
    public let createNewChatRecoveryIntent: CoachContextCreateNewChatRecoveryIntent?
    public let newChatPicker: NewChatAttachmentPickerState
    public let openedAttachments: OpenedChatAttachmentsState
    public let activity: Activity?
    public let notice: ChatNotice?

    public init(
        catalog: Catalog = .notLoaded,
        filterQuery: ChatFilterQuery = .empty,
        selection: Selection = .none,
        composer: ChatComposerState? = nil,
        contextAdvisory: CoachContextAdvisoryState = .notRequested,
        createNewChatRecoveryIntent: CoachContextCreateNewChatRecoveryIntent? = nil,
        newChatPicker: NewChatAttachmentPickerState = .closed,
        openedAttachments: OpenedChatAttachmentsState = .notRequested,
        activity: Activity? = nil,
        notice: ChatNotice? = nil
    ) {
        self.catalog = catalog
        self.filterQuery = filterQuery
        self.selection = selection
        self.composer = composer
        self.contextAdvisory = contextAdvisory
        self.createNewChatRecoveryIntent = createNewChatRecoveryIntent
        self.newChatPicker = newChatPicker
        self.openedAttachments = openedAttachments
        self.activity = activity
        self.notice = notice
    }
}
