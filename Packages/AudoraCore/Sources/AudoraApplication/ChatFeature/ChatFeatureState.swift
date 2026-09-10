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
    case coachBusy
    case coachAdmissionLimited
    case coachSendUnavailable
    case coachRetryUnavailable
    case coachResponseInterrupted
    case attachmentCatalogFailed
    case qualifiedCoachConfigurationUnavailable
    case profileProposalAcceptFailed
    case profileProposalDiscardFailed
    case profileProposalStale
    case profileEffectAssessmentFailed
    case profileReconsiderationUnavailable
    case profileReconsiderationDiscardFailed
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

/// Application's authoritative review projection for the one Chat-owned Profile
/// effect. The effect remains durable on `ChatAggregate`; this value records only
/// the current Profile comparison and is rebuilt whenever the Chat is opened.
public enum ProfileEffectReviewState: Equatable, Sendable {
    case current(ChatProfileEffectIdentity)
    case stale(ProfileReconsiderationBasis)
    case unavailable(ChatProfileEffectIdentity)

    public var sourceEffectIdentity: ChatProfileEffectIdentity {
        switch self {
        case let .current(identity), let .unavailable(identity):
            identity
        case let .stale(basis):
            basis.sourceEffect.identity
        }
    }

    public var reconsiderationBasis: ProfileReconsiderationBasis? {
        guard case let .stale(basis) = self else { return nil }
        return basis
    }
}

/// A process-local accessibility announcement. It is intentionally absent from
/// Chat persistence and history.
public enum ChatTransientNotice: String, Equatable, Sendable {
    case suggestionNoLongerRelevant
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
        case invokingCoach(ChatID)
        case stoppingCoach(ChatID)
        case retryingPendingUserTurn(ChatID)
        case discardingPendingUserTurn(ChatID)
        case acceptingProfileProposal(ChatID)
        case discardingProfileProposal(ChatID)
        case publishingProfileEvidence(ChatID)
        case retryingProfileEvidencePublication(ChatID)
        case discardingProfileEvidencePublication(ChatID)
        case reconsideringProfileEffect(ChatID)
        case stoppingProfileReconsideration(ChatID)
        case discardingProfileReconsiderationFailure(ChatID)
    }

    public let catalog: Catalog
    public let filterQuery: ChatFilterQuery
    public let selection: Selection
    public let composer: ChatComposerState?
    public let contextAdvisory: CoachContextAdvisoryState
    public let admissionAvailability: InvocationAdmissionAvailability?
    public let createNewChatRecoveryIntent: CoachContextCreateNewChatRecoveryIntent?
    /// An exact retry authority held only in Application memory when
    /// persistence could not prove its terminal interruption write.
    public let operationallyInterruptedInvocation: PendingCoachInvocationRequest?
    /// Exact process-local retry projection used only when persistence could
    /// not prove a Reconsider terminal write. It never authorizes provider
    /// resumption after relaunch.
    public let operationallyInterruptedProfileReconsideration:
        ProfileReconsiderationInvocationRequest?
    /// Process-live, Attempt-scoped capability presented only while the exact
    /// active Coach response can still be stopped.
    public let coachInvocationStopAuthority: InvocationStopAuthority?
    /// Process-live, Attempt-scoped Stop authority for the exact active
    /// Reconsider Invocation. A replacement Attempt receives a new authority.
    public let profileReconsiderationStopAuthority:
        ProfileReconsiderationInvocationStopAuthority?
    public let profileEffectReview: ProfileEffectReviewState?
    public let transientNotice: ChatTransientNotice?
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
        admissionAvailability: InvocationAdmissionAvailability? = nil,
        createNewChatRecoveryIntent: CoachContextCreateNewChatRecoveryIntent? = nil,
        operationallyInterruptedInvocation: PendingCoachInvocationRequest? = nil,
        operationallyInterruptedProfileReconsideration:
            ProfileReconsiderationInvocationRequest? = nil,
        coachInvocationStopAuthority: InvocationStopAuthority? = nil,
        profileReconsiderationStopAuthority:
            ProfileReconsiderationInvocationStopAuthority? = nil,
        profileEffectReview: ProfileEffectReviewState? = nil,
        transientNotice: ChatTransientNotice? = nil,
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
        self.admissionAvailability = admissionAvailability
        self.createNewChatRecoveryIntent = createNewChatRecoveryIntent
        self.operationallyInterruptedInvocation = operationallyInterruptedInvocation
        self.operationallyInterruptedProfileReconsideration =
            operationallyInterruptedProfileReconsideration
        self.coachInvocationStopAuthority = coachInvocationStopAuthority
        self.profileReconsiderationStopAuthority =
            profileReconsiderationStopAuthority
        self.profileEffectReview = profileEffectReview
        self.transientNotice = transientNotice
        self.newChatPicker = newChatPicker
        self.openedAttachments = openedAttachments
        self.activity = activity
        self.notice = notice
    }

    public func isCoachResponseInterrupted(_ pending: PendingUserTurn) -> Bool {
        isCoachResponseRetryableFailure(pending)
    }

    public func isCoachResponseRetryableFailure(_ pending: PendingUserTurn) -> Bool {
        if pending.failure == .coachResponseInterrupted ||
            pending.failure == .coachProviderError ||
            pending.failure == .coachResponseInvalid ||
            pending.failure?.transcriptReadFailureSummary != nil
        {
            return true
        }
        guard let request = operationallyInterruptedInvocation,
              case let .open(aggregate) = selection,
              aggregate.chat.id == request.chatID,
              aggregate.pendingUserTurn == pending,
              pending.id == request.pendingUserTurnID
        else { return false }
        return true
    }

    public func isProfileReconsiderationRetryableFailure(
        _ reconsideration: ProfileReconsideration
    ) -> Bool {
        if reconsideration.failure != nil { return true }
        guard let request = operationallyInterruptedProfileReconsideration,
              case let .open(aggregate) = selection,
              aggregate.chat.id == request.chatID,
              aggregate.profileEffect?.identity ==
                request.sourceEffectIdentity,
              aggregate.profileReconsideration == reconsideration,
              reconsideration.sourceEffectIdentity ==
                request.sourceEffectIdentity,
              reconsideration.resultResponsePositionID ==
                request.resultResponsePositionID
        else { return false }
        return true
    }
}
