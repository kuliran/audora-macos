import AudoraApplication
import AudoraDomain
import Combine

public enum NewChatAttachmentPickerAction: Equatable, Sendable {
    case toggle(ChatSessionAttachmentID)
    case defaultAction
    case cancelAction
}

struct ChatUnreadResponseTracker: Equatable {
    private(set) var unreadChatIDs: Set<ChatID> = []

    private var observedChatIDs: Set<ChatID> = []
    private var latestResponseMessageIDs: [ChatID: ChatMessageID] = [:]
    private var hasCatalogBaseline = false

    mutating func reset() {
        self = ChatUnreadResponseTracker()
    }

    mutating func observe(_ state: ChatFeatureState) {
        guard case let .ready(catalog) = state.catalog else { return }
        let rows = catalog.allRows.filter { row in
            if case .available = row.availability { return true }
            return false
        }
        let currentChatIDs = Set(rows.map(\.chatID))

        guard hasCatalogBaseline else {
            hasCatalogBaseline = true
            observedChatIDs = currentChatIDs
            latestResponseMessageIDs = Dictionary(
                uniqueKeysWithValues: rows.compactMap { row in
                    row.latestCompletedResponseMessageID.map {
                        (row.chatID, $0)
                    }
                }
            )
            unreadChatIDs.removeAll(keepingCapacity: true)
            acknowledgeSelectedChat(in: state)
            return
        }

        observedChatIDs.formIntersection(currentChatIDs)
        unreadChatIDs.formIntersection(currentChatIDs)
        latestResponseMessageIDs = latestResponseMessageIDs.filter {
            currentChatIDs.contains($0.key)
        }

        let selectedChatID: ChatID? = if case let .open(aggregate) =
            state.selection
        {
            aggregate.chat.id
        } else {
            nil
        }
        for row in rows {
            let wasObserved = observedChatIDs.contains(row.chatID)
            let previous = latestResponseMessageIDs[row.chatID]
            let current = row.latestCompletedResponseMessageID
            if wasObserved, current != previous, current != nil {
                if row.chatID == selectedChatID {
                    unreadChatIDs.remove(row.chatID)
                } else {
                    unreadChatIDs.insert(row.chatID)
                }
            }
            observedChatIDs.insert(row.chatID)
            if let current {
                latestResponseMessageIDs[row.chatID] = current
            } else {
                latestResponseMessageIDs.removeValue(forKey: row.chatID)
            }
        }
        acknowledgeSelectedChat(in: state)
    }

    private mutating func acknowledgeSelectedChat(
        in state: ChatFeatureState
    ) {
        guard case let .open(aggregate) = state.selection else { return }
        unreadChatIDs.remove(aggregate.chat.id)
    }
}

@MainActor
public final class ChatPresentationModel: ObservableObject {
    @Published public private(set) var snapshot = ChatFeatureState()
    private(set) var unreadChatIDs: Set<ChatID> = []
    @Published public var filterText = ""
    @Published public var newChatAttachmentFilterText = ""

    private let feature: any ApplicationCommandFeature
    private let dispatcher: ChatCommandDispatcher
    private let announcements: any AccessibilityAnnouncementPosting
    private var startedActivation: LibraryActivation?
    private var commandContext: ChatCommandContext?
    private var projectedStateContext: ChatCommandContext?
    private var stateConsumer: Task<Void, Never>?
    private var lastAnnouncedPickerIssue: ChatAttachmentPickerIssue?
    private var lastAnnouncedTransientNotice: ChatTransientNotice?
    private var unreadResponseTracker = ChatUnreadResponseTracker()

    public init(
        dispatcher: ChatCommandDispatcher,
        announcements: (any AccessibilityAnnouncementPosting)? = nil
    ) {
        feature = dispatcher.feature
        self.dispatcher = dispatcher
        self.announcements = announcements ?? SystemAccessibilityAnnouncementPoster()
    }

    public func start(in activation: LibraryActivation) async {
        guard !Task.isCancelled else { return }
        guard startedActivation != activation else { return }
        startedActivation = activation
        let context = ChatCommandContext(
            libraryScope: activation.scope,
            generation: activation.generation
        )
        commandContext = context

        stateConsumer?.cancel()
        lastAnnouncedPickerIssue = nil
        lastAnnouncedTransientNotice = nil
        unreadResponseTracker.reset()
        unreadChatIDs = []
        installSnapshot(
            ChatFeatureState(
                catalog: .loading,
                filterQuery: .empty,
                selection: .none
            )
        )
        filterText = ""

        let stream = feature.chatStates
        let consumer = Task { @MainActor [weak self] in
            guard let self else { return }
            var states = stream.makeAsyncIterator()
            while !Task.isCancelled, let next = await states.next() {
                guard context == commandContext else { return }
                if projectedStateContext != context {
                    guard await feature.currentChatState(in: context) == next else {
                        continue
                    }
                    guard context == commandContext, !Task.isCancelled else { return }
                    projectedStateContext = context
                }
                installSnapshot(next)
            }
        }
        stateConsumer = consumer

        await withTaskCancellationHandler {
            await dispatcher.sendAndWait(.start(context))
            guard !Task.isCancelled else {
                consumer.cancel()
                return
            }
            if let current = await feature.currentChatState(in: context) {
                guard context == commandContext, !Task.isCancelled else {
                    consumer.cancel()
                    return
                }
                projectedStateContext = context
                installSnapshot(current)
            }
            await consumer.value
        } onCancel: {
            consumer.cancel()
        }
        guard context == commandContext, !Task.isCancelled else { return }
        stateConsumer = nil
    }

    private func installSnapshot(_ replacement: ChatFeatureState) {
        unreadResponseTracker.observe(replacement)
        unreadChatIDs = unreadResponseTracker.unreadChatIDs
        snapshot = replacement
        if replacement.transientNotice != lastAnnouncedTransientNotice {
            lastAnnouncedTransientNotice = replacement.transientNotice
            if let notice = replacement.transientNotice {
                announcements.post(
                    ChatTransientNoticePresentation.accessibilityLabel(
                        for: notice
                    )
                )
            }
        }
        let issue: ChatAttachmentPickerIssue?
        switch replacement.newChatPicker {
        case let .ready(picker):
            issue = picker.issue
        case .closed:
            if case .loading = replacement.catalog {
                return
            }
            issue = nil
        case .loading, .failed:
            issue = nil
        }
        guard issue != lastAnnouncedPickerIssue else { return }
        lastAnnouncedPickerIssue = issue
        if let issue {
            announcements.post(
                NewChatAttachmentPickerPresentation.accessibilityAnnouncement(
                    for: issue
                )
            )
        }
    }

    func indicators(for row: ChatRowSnapshot) -> ChatRowIndicators {
        snapshot.indicators(
            for: row,
            isUnread: unreadChatIDs.contains(row.chatID)
        )
    }

    public func beginNewChat() {
        guard let context = commandContext else { return }
        newChatAttachmentFilterText = ""
        send(.beginNewChat(context))
    }

    public func retryNewChatConfiguration() {
        guard let context = commandContext,
              case let .ready(picker) = snapshot.newChatPicker,
              picker.issue == .qualifiedConfigurationUnavailable
        else { return }
        send(.beginNewChat(context))
    }

    public func updateNewChatAttachmentFilter(_ value: String) {
        newChatAttachmentFilterText = value
        guard let context = commandContext,
              let query = try? ChatAttachmentFilterQuery(value)
        else { return }
        send(.setNewChatAttachmentFilter(context, query))
    }

    public func toggleNewChatAttachment(_ attachmentID: ChatSessionAttachmentID) {
        guard let context = commandContext else { return }
        send(.toggleNewChatAttachment(context, attachmentID))
    }

    public func performNewChatAttachmentPickerAction(
        _ action: NewChatAttachmentPickerAction
    ) {
        switch action {
        case let .toggle(attachmentID): toggleNewChatAttachment(attachmentID)
        case .defaultAction: confirmNewChat()
        case .cancelAction: cancelNewChat()
        }
    }

    public func cancelNewChat() {
        guard let context = commandContext else { return }
        send(.cancelNewChat(context))
    }

    public func confirmNewChat() {
        guard let context = commandContext,
              case let .ready(picker) = snapshot.newChatPicker,
              let confirmationToken = picker.confirmationToken
        else { return }
        send(.confirmNewChat(context, confirmationToken))
    }

    public func open(_ chatID: ChatID) {
        guard let context = commandContext else { return }
        send(.open(context, chatID))
    }

    public func rename(
        _ chatID: ChatID,
        title: String,
        expectedRevision: UInt64
    ) {
        guard let context = commandContext else { return }
        send(
            .rename(
                context,
                chatID,
                title: title,
                expectedRevision: expectedRevision
            )
        )
    }

    public func updateDraft(_ text: String) {
        guard let context = commandContext,
              ChatInteractionPolicy.allowsComposerEditing(in: snapshot),
              case let .open(aggregate) = snapshot.selection,
              case let .editable(draft, _) = snapshot.composer,
              aggregate.chat.draft.draftID == draft.draftID
        else {
            return
        }
        send(.editDraft(context, aggregate.chat.id, draft.draftID, text: text))
    }

    public func sendDraft() {
        guard let context = commandContext,
              ChatInteractionPolicy.allowsComposerEditing(in: snapshot),
              case let .open(aggregate) = snapshot.selection,
              case let .editable(draft, _) = snapshot.composer,
              aggregate.chat.draft.draftID == draft.draftID
        else {
            return
        }
        send(.sendDraft(context, aggregate.chat.id, draft))
    }

    public func stopCoachResponse() {
        guard let context = commandContext,
              let authority = snapshot.coachInvocationStopAuthority
        else { return }
        send(.stopCoachResponse(context, authority))
    }

    public func stopProfileReconsideration() {
        guard let context = commandContext,
              let authority = snapshot.profileReconsiderationStopAuthority
        else { return }
        send(.stopProfileReconsideration(context, authority))
    }

    /// Re-resolves current Profile, Memory, history, attachments, and provider
    /// configuration without changing the Chat or invoking a provider.
    public func refreshContextQuote() {
        guard let context = commandContext,
              case let .open(aggregate) = snapshot.selection,
              let draft = snapshot.composer?.draft
        else {
            return
        }
        send(.refreshContextQuote(context, aggregate.chat.id, draft))
    }

    public func discardPendingUserTurn(_ pendingUserTurnID: PendingUserTurnID) {
        guard let context = commandContext else { return }
        send(.discardPendingUserTurn(context, pendingUserTurnID))
    }

    public func retryPendingUserTurn(_ pendingUserTurnID: PendingUserTurnID) {
        guard let context = commandContext else { return }
        send(.retryPendingUserTurn(context, pendingUserTurnID))
    }

    public func createNewChatFromCapacityFailure(
        _ pendingUserTurnID: PendingUserTurnID
    ) {
        guard let context = commandContext else { return }
        send(.createNewChatFromCapacityFailure(context, pendingUserTurnID))
    }

    public func acceptProfileProposal(_ proposalID: ProfileChangeProposalID) {
        guard let context = commandContext,
              ChatInteractionPolicy.allowsNavigationAndMutation(in: snapshot),
              case let .open(aggregate) = snapshot.selection,
              aggregate.profileProposal?.id == proposalID,
              aggregate.profileReconsideration == nil,
              snapshot.profileEffectReview == .current(.proposal(proposalID))
        else { return }
        send(.acceptProfileProposal(context, proposalID))
    }

    public func discardProfileProposal(_ proposalID: ProfileChangeProposalID) {
        guard let context = commandContext,
              ChatInteractionPolicy.allowsNavigationAndMutation(in: snapshot),
              case let .open(aggregate) = snapshot.selection,
              aggregate.profileProposal?.id == proposalID,
              aggregate.profileReconsideration == nil,
              snapshot.profileEffectReview?.sourceEffectIdentity ==
                .proposal(proposalID)
        else { return }
        send(.discardProfileProposal(context, proposalID))
    }

    public func retryProfileEvidencePublication(
        _ responsePositionID: ChatResponsePositionID
    ) {
        guard let context = commandContext,
              ChatInteractionPolicy.allowsNavigationAndMutation(in: snapshot),
              case let .open(aggregate) = snapshot.selection,
              aggregate.profileEvidencePublication?.responsePositionID ==
                responsePositionID,
              aggregate.profileReconsideration == nil,
              snapshot.profileEffectReview == .current(
                .evidencePublication(responsePositionID)
              )
        else { return }
        send(.retryProfileEvidencePublication(context, responsePositionID))
    }

    public func discardProfileEvidencePublication(
        _ responsePositionID: ChatResponsePositionID
    ) {
        guard let context = commandContext,
              ChatInteractionPolicy.allowsNavigationAndMutation(in: snapshot),
              case let .open(aggregate) = snapshot.selection,
              aggregate.profileEvidencePublication?.responsePositionID ==
                responsePositionID,
              aggregate.profileReconsideration == nil,
              snapshot.profileEffectReview?.sourceEffectIdentity ==
                .evidencePublication(responsePositionID)
        else { return }
        send(.discardProfileEvidencePublication(context, responsePositionID))
    }

    public func reconsiderProfileEffect(
        _ sourceEffectIdentity: ChatProfileEffectIdentity
    ) {
        guard let context = commandContext,
              ChatInteractionPolicy.allowsProfileReconsideration(in: snapshot),
              case let .open(aggregate) = snapshot.selection,
              aggregate.profileEffect?.identity == sourceEffectIdentity,
              aggregate.profileReconsideration == nil,
              snapshot.profileEffectReview?.sourceEffectIdentity ==
                sourceEffectIdentity
        else { return }
        send(.reconsiderProfileEffect(context, sourceEffectIdentity))
    }

    public func retryProfileReconsideration(
        _ sourceEffectIdentity: ChatProfileEffectIdentity
    ) {
        guard let context = commandContext,
              ChatInteractionPolicy.allowsNavigationAndMutation(in: snapshot),
              snapshot.admissionAvailability == .available,
              case let .open(aggregate) = snapshot.selection,
              aggregate.profileEffect?.identity == sourceEffectIdentity,
              let reconsideration = aggregate.profileReconsideration,
              reconsideration.sourceEffectIdentity == sourceEffectIdentity,
              snapshot.isProfileReconsiderationRetryableFailure(
                reconsideration
              ),
              snapshot.profileEffectReview?.sourceEffectIdentity ==
                sourceEffectIdentity
        else { return }
        send(.retryProfileReconsideration(context, sourceEffectIdentity))
    }

    public func discardProfileReconsiderationFailure(
        _ sourceEffectIdentity: ChatProfileEffectIdentity
    ) {
        guard let context = commandContext,
              ChatInteractionPolicy.allowsNavigationAndMutation(in: snapshot),
              case let .open(aggregate) = snapshot.selection,
              aggregate.profileEffect?.identity == sourceEffectIdentity,
              let reconsideration = aggregate.profileReconsideration,
              reconsideration.sourceEffectIdentity == sourceEffectIdentity,
              reconsideration.failure != nil,
              snapshot.profileEffectReview?.sourceEffectIdentity ==
                sourceEffectIdentity
        else { return }
        send(
            .discardProfileReconsiderationFailure(
                context,
                sourceEffectIdentity
            )
        )
    }

    public func announceEvidenceUnavailable(_ explanation: String) {
        announcements.post("Evidence unavailable. \(explanation)")
    }

    private func send(_ command: ChatCommand) {
        dispatcher.enqueue(command)
    }

    public func updateFilter(_ value: String) {
        filterText = value
        guard let query = try? ChatFilterQuery(value) else { return }
        guard let context = commandContext else { return }
        send(.setFilter(context, query))
    }

    public func clearFilter() {
        updateFilter("")
    }
}
