import AudoraApplication
import AudoraDomain
import AppKit
import Foundation
import SwiftUI

struct LibraryActivationPresentationIdentity: Hashable {
    let libraryID: LibraryID
    let generation: UInt64

    init(_ activation: LibraryActivation) {
        libraryID = activation.scope.libraryID
        generation = activation.generation
    }
}

struct ChatRenameEditorTaskID: Hashable {
    let chatID: ChatID
    let manifestRevision: UInt64
}

struct NewChatSheetInteractionPresentation: Equatable, Sendable {
    let allowsControlInteraction: Bool
    let allowsCancellation: Bool
    let preventsInteractiveDismissal: Bool
    let busyAccessibilityLabel: String?

    init(
        admissionState: ApplicationCommandAdmissionState,
        chatState: ChatFeatureState
    ) {
        let allowsNavigationAndMutation =
            !admissionState.isLibraryNavigationPending &&
            !admissionState.isChatBoundaryPending &&
            !admissionState.isOrderlyTerminationPending &&
            ChatInteractionPolicy.allowsNavigationAndMutation(in: chatState)
        let isCreating = chatState.activity == .creating
        allowsControlInteraction = allowsNavigationAndMutation
        allowsCancellation = !admissionState.isOrderlyTerminationPending && !isCreating
        preventsInteractiveDismissal = !allowsCancellation
        if allowsNavigationAndMutation {
            busyAccessibilityLabel = nil
        } else if allowsCancellation {
            busyAccessibilityLabel =
                "New Chat is busy. Search, Session selection, and Create Chat are temporarily unavailable. Cancel remains available."
        } else if isCreating {
            busyAccessibilityLabel =
                "New Chat is being created. Search, Session selection, Cancel, and Create Chat are unavailable."
        } else {
            busyAccessibilityLabel =
                "New Chat is busy. Search, Session selection, Cancel, and Create Chat are temporarily unavailable."
        }
    }
}

struct CoachResponseStopInteractionPresentation: Equatable, Sendable {
    let isEnabled: Bool

    init(
        admissionState: ApplicationCommandAdmissionState,
        chatState: ChatFeatureState
    ) {
        guard !admissionState.isOrderlyTerminationPending,
              let authority = chatState.coachInvocationStopAuthority,
              case let .open(aggregate) = chatState.selection,
              aggregate.chat.id == authority.chatID,
              aggregate.pendingUserTurn?.id == authority.pendingUserTurnID,
              chatState.activity == .invokingCoach(authority.chatID) ||
                  chatState.activity == .stoppingCoach(authority.chatID)
        else {
            isEnabled = false
            return
        }
        isEnabled = true
    }
}

struct ProfileReconsiderationStopInteractionPresentation: Equatable, Sendable {
    let isEnabled: Bool

    init(
        admissionState: ApplicationCommandAdmissionState,
        chatState: ChatFeatureState
    ) {
        guard !admissionState.isOrderlyTerminationPending,
              let authority =
                chatState.profileReconsiderationStopAuthority,
              case let .open(aggregate) = chatState.selection,
              aggregate.chat.id == authority.chatID,
              aggregate.profileEffect?.identity ==
                authority.sourceEffectIdentity,
              aggregate.profileReconsideration?.sourceEffectIdentity ==
                authority.sourceEffectIdentity,
              aggregate.profileReconsideration?.resultResponsePositionID ==
                authority.resultResponsePositionID,
              chatState.activity ==
                .reconsideringProfileEffect(authority.chatID) ||
                chatState.activity ==
                    .stoppingProfileReconsideration(authority.chatID)
        else {
            isEnabled = false
            return
        }
        isEnabled = true
    }
}

enum ChatNoticePresentation {
    static func recoveryText(for notice: ChatNotice) -> String {
        switch notice {
        case .invalidTitle: "Enter a valid Chat title."
        case .createFailed: "The Chat could not be created."
        case .createCollisionLimitReached: "The Chat could not be created after retrying."
        case .renameFailed: "The Chat could not be renamed."
        case .staleRename: "The Chat changed elsewhere. Its current title is shown."
        case .chatMissing: "That Chat is no longer available."
        case .chatOpenFailed: "That Chat could not be opened. Try again after reopening the Library."
        case .chatFrozen: "That Chat is read-only or unavailable."
        case .catalogFailed: "Chats could not be loaded."
        case .readOnlyLibrary: "Chats cannot be changed in this read-only Library."
        case .invalidDraft: "Write a valid Draft before sending."
        case .draftSaveFailed: "The Draft could not be saved. Try again before leaving."
        case .draftChanged: "The Draft changed elsewhere. Its current text is shown."
        case .pendingUserTurnFailed: "The pending Chat turn could not be changed."
        case .coachContextUnavailable: "Context capacity is unavailable for this Coach configuration."
        case .messageMustBeShortened: "Message is too long. Shorten it to send."
        case .coachBusy: "The Coach is already working in this Library. Try again after it finishes."
        case .coachAdmissionLimited: "The Coach was used recently. Try this Send again when admission reopens."
        case .coachSendUnavailable: "The Coach could not accept this Send. Your Draft is still editable."
        case .coachRetryUnavailable:
            "The Coach could not accept this Retry. " +
                "Your Draft remains locked; Retry or Discard."
        case .coachResponseInterrupted: "The Coach response was interrupted and nothing was published."
        case .attachmentCatalogFailed: "Sessions could not be loaded for Chat creation."
        case .qualifiedCoachConfigurationUnavailable:
            "No qualified Coach configuration is available. Install an Audora update with a qualified configuration before creating a Chat."
        case .profileProposalAcceptFailed:
            "The Profile changes could not be accepted. Review the proposal and try again."
        case .profileProposalDiscardFailed:
            "The Profile proposal could not be discarded. Review it and try again."
        case .profileProposalStale:
            "The Profile changed elsewhere, so this suggestion must be reconsidered before it can be accepted."
        case .profileEffectAssessmentFailed:
            "The current Profile could not be compared with this suggestion. Reopen the Chat and try again."
        case .profileReconsiderationUnavailable:
            "The suggestion could not be reconsidered. Retry or discard the failure."
        case .profileReconsiderationDiscardFailed:
            "The Reconsider failure could not be discarded. Try again."
        }
    }

    static func accessibilityLabel(for notice: ChatNotice) -> String {
        "Chat notice: \(recoveryText(for: notice))"
    }
}

enum ChatTransientNoticePresentation {
    static func text(for notice: ChatTransientNotice) -> String {
        switch notice {
        case .suggestionNoLongerRelevant:
            "Suggestion is no longer relevant."
        }
    }

    static func accessibilityLabel(for notice: ChatTransientNotice) -> String {
        text(for: notice)
    }
}

enum ProfileProposalChangeOperation: Equatable {
    case add
    case replace
    case retire
}

struct ProfileProposalChangePresentation: Equatable {
    let operation: ProfileProposalChangeOperation
    let statementKindLabel: String
    let currentWording: String?
    let proposedWording: String?
    let evidence: [EvidenceReference]

    var heading: String {
        switch operation {
        case .add: "Add \(statementKindLabel)"
        case .replace: "Replace \(statementKindLabel)"
        case .retire: "Retire \(statementKindLabel)"
        }
    }
}

struct ProfileEvidenceAppendPresentation: Equatable {
    let statementKindLabel: String
    let targetWording: String
    let evidence: [EvidenceReference]

    var heading: String { "Add evidence to \(statementKindLabel)" }
}

struct ProfileProposalCardPresentation: Equatable {
    static let acceptActionTitle = "Accept"
    static let discardActionTitle = "Discard"
    static let actionTitles = [acceptActionTitle, discardActionTitle]
    static let explanatoryCopy =
        "Want to change this suggestion? Discard it, continue chatting with the coach, then ask the coach to remember the result."

    let proposalID: ProfileChangeProposalID
    let changes: [ProfileProposalChangePresentation]
    let evidenceAppends: [ProfileEvidenceAppendPresentation]

    init(_ proposal: ProfileChangeProposal) {
        proposalID = proposal.id
        changes = proposal.changes.map { change in
            switch change {
            case let .add(statement):
                ProfileProposalChangePresentation(
                    operation: .add,
                    statementKindLabel: Self.statementKindLabel(
                        statement.statementKind
                    ),
                    currentWording: nil,
                    proposedWording: statement.wording,
                    evidence: statement.evidence
                )
            case let .replace(target, replacement):
                ProfileProposalChangePresentation(
                    operation: .replace,
                    statementKindLabel: Self.statementKindLabel(
                        target.statementKind
                    ),
                    currentWording: target.wording,
                    proposedWording: replacement.wording,
                    evidence: replacement.evidence
                )
            case let .retire(target, evidence):
                ProfileProposalChangePresentation(
                    operation: .retire,
                    statementKindLabel: Self.statementKindLabel(
                        target.statementKind
                    ),
                    currentWording: target.wording,
                    proposedWording: nil,
                    evidence: evidence
                )
            }
        }
        evidenceAppends = proposal.evidenceAppends.map { append in
            ProfileEvidenceAppendPresentation(
                statementKindLabel: Self.statementKindLabel(
                    append.target.statementKind
                ),
                targetWording: append.target.wording,
                evidence: append.evidence
            )
        }
    }

    private static func statementKindLabel(
        _ kind: ProfileStatementKind
    ) -> String {
        switch kind {
        case .goal: "Goal"
        case .coachingPreference: "Coaching preference"
        case .selfAssessment: "Self-assessment"
        case .speakingObservation: "Speaking observation"
        case .growthDirection: "Growth direction"
        }
    }
}

enum ProfileEffectRecoveryAction: Equatable, Hashable, Sendable {
    case acceptProposal
    case retryEvidencePublication
    case reconsider
    case retryReconsideration
    case stopReconsideration
    case discardEffect
    case discardReconsiderationFailure

    var title: String {
        switch self {
        case .acceptProposal: "Accept"
        case .retryEvidencePublication, .retryReconsideration: "Retry"
        case .stopReconsideration: "Stop"
        case .reconsider: "Reconsider"
        case .discardEffect, .discardReconsiderationFailure: "Discard"
        }
    }
}

enum ProfileEffectRecoveryPresentation {
    /// Projects only actions that are valid for the exact assessed effect.
    /// The Application layer independently enforces the same identity and
    /// staleness fences when a command arrives.
    static func actions(
        for sourceEffectIdentity: ChatProfileEffectIdentity,
        in state: ChatFeatureState
    ) -> [ProfileEffectRecoveryAction] {
        guard case let .open(aggregate) = state.selection,
              aggregate.profileEffect?.identity == sourceEffectIdentity,
              state.profileEffectReview?.sourceEffectIdentity ==
                sourceEffectIdentity
        else { return [] }

        if let reconsideration = aggregate.profileReconsideration {
            guard reconsideration.sourceEffectIdentity == sourceEffectIdentity
            else { return [] }
            if reconsideration.failure != nil, state.activity == nil {
                return [
                    .retryReconsideration,
                    .discardReconsiderationFailure,
                ]
            }
            if state.isProfileReconsiderationRetryableFailure(reconsideration),
               state.activity == nil
            {
                // An unproven terminal write retains only exact operational
                // Retry authority. Local Discard appears after recovery has
                // durably classified the sidecar failure.
                return [.retryReconsideration]
            }
            if let authority = state.profileReconsiderationStopAuthority,
               authority.sourceEffectIdentity == sourceEffectIdentity,
               authority.resultResponsePositionID ==
                reconsideration.resultResponsePositionID,
               state.activity ==
                .reconsideringProfileEffect(aggregate.chat.id) ||
                state.activity ==
                    .stoppingProfileReconsideration(aggregate.chat.id)
            {
                return [.stopReconsideration]
            }
            return []
        }

        guard state.activity == nil else { return [] }
        switch state.profileEffectReview {
        case .current(.proposal):
            return [.acceptProposal, .discardEffect]
        case .current(.evidencePublication):
            return [.retryEvidencePublication, .discardEffect]
        case .stale:
            return [.reconsider, .discardEffect]
        case .unavailable, .none:
            return []
        }
    }
}

struct ProfileEvidencePublicationFailureCardPresentation: Equatable {
    static let headingText = "Profile evidence couldn't be saved"
    static let retryActionTitle = "Retry"
    static let discardActionTitle = "Discard"

    let responsePositionID: ChatResponsePositionID
    let updates: [String]

    var heading: String { Self.headingText }
    var actionTitles: [String] {
        [Self.retryActionTitle, Self.discardActionTitle]
    }
    var accessibilityLabel: String {
        ([heading + "."] + updates).joined(separator: " ")
    }
}

enum ProfileEvidencePublicationFailurePresentation {
    private struct AttachmentPair: Hashable {
        let sessionID: SessionID
        let transcriptRevisionID: TranscriptRevisionID
    }

    static func card(
        for publication: ProfileEvidencePublication?,
        openedAttachments: OpenedChatAttachmentsState,
        activity: ChatFeatureState.Activity? = nil
    ) -> ProfileEvidencePublicationFailureCardPresentation? {
        guard let publication else { return nil }
        if activity == .publishingProfileEvidence(publication.chatID) {
            return nil
        }
        let resolvedSessionLabels = resolvedSessionLabels(
            in: openedAttachments
        )
        let updates = publication.evidenceAppends.flatMap { append in
            append.evidence.map { reference in
                let key = AttachmentPair(
                    sessionID: reference.sessionID,
                    transcriptRevisionID: reference.transcriptRevisionID
                )
                let sessionLabel = resolvedSessionLabels[key] ??
                    reference.display.sessionLabel
                return "Add evidence from “\(sessionLabel)” to " +
                    "“\(append.target.wording)”"
            }
        }
        return ProfileEvidencePublicationFailureCardPresentation(
            responsePositionID: publication.responsePositionID,
            updates: updates
        )
    }

    private static func resolvedSessionLabels(
        in openedAttachments: OpenedChatAttachmentsState
    ) -> [AttachmentPair: String] {
        guard case let .resolved(resolutions) = openedAttachments else {
            return [:]
        }
        return Dictionary(
            uniqueKeysWithValues: resolutions.compactMap { resolution in
                guard case let .available(candidate) = resolution.resolution
                else { return nil }
                return (
                    AttachmentPair(
                        sessionID: candidate.sessionID,
                        transcriptRevisionID: candidate.transcriptRevisionID
                    ),
                    candidate.displayLabel
                )
            }
        )
    }
}

struct ChatRowIndicatorPresentation: Equatable {
    let indicators: ChatRowIndicators

    var activityAccessibilityLabel: String? {
        switch indicators.activity {
        case .idle: nil
        case .processing: "Coach response in progress"
        case .interrupted: "Coach response needs attention"
        case .newMessage: "New Coach message"
        }
    }

    var profileAccessibilityLabel: String? {
        switch indicators.profileUpdate {
        case .none: nil
        case .pendingApproval: "Profile changes awaiting approval"
        case .publicationFailure: "Profile update could not be saved"
        }
    }

    var activitySymbolName: String? {
        switch indicators.activity {
        case .idle, .processing: nil
        case .interrupted: "exclamationmark.circle.fill"
        case .newMessage: "circle.fill"
        }
    }

    var profileSymbolName: String? {
        switch indicators.profileUpdate {
        case .none: nil
        case .pendingApproval: "person.crop.circle.badge.questionmark"
        case .publicationFailure: "exclamationmark.triangle.fill"
        }
    }

    var hasVisibleIndicator: Bool {
        indicators.activity != .idle || indicators.profileUpdate != .none
    }

    func accessibilityLabel(for row: ChatRowSnapshot) -> String {
        let openingLabel = row.title.map { "Open Chat, \($0.rawValue)" }
            ?? "Open unavailable Chat"
        let availabilityLabel: String? = switch row.availability {
        case .available: nil
        case .frozen(.newerSchema): "Chat is read-only"
        case .frozen(.corrupt), .frozen(.unsupportedSchema):
            "Chat is unavailable"
        }
        return ([openingLabel] + [
            availabilityLabel,
            activityAccessibilityLabel,
            profileAccessibilityLabel,
        ].compactMap { $0 })
            .map { $0 + "." }
            .joined(separator: " ")
    }
}

struct SlowChatRowSpinner: View {
    /// A deliberately calm cadence: one full turn is slower than the system's
    /// compact indeterminate progress treatment.
    static let rotationDuration: TimeInterval = 1.8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRotating = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.78)
            .stroke(
                Color.secondary,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
            )
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .animation(
                reduceMotion
                    ? nil
                    : .linear(duration: Self.rotationDuration)
                        .repeatForever(autoreverses: false),
                value: isRotating
            )
            .onAppear {
                isRotating = !reduceMotion
            }
            .onChange(of: reduceMotion) { _, newValue in
                isRotating = !newValue
            }
    }
}

enum ChatActivityPresentation {
    static func progressLabel(
        for activity: ChatFeatureState.Activity?
    ) -> String? {
        switch activity {
        case .creating: "Creating Chat…"
        case .renaming: "Renaming Chat…"
        case .lockingDraft: "Preparing Draft…"
        case .invokingCoach: "Coach is responding…"
        case .stoppingCoach: "Stopping Coach response…"
        case .retryingPendingUserTurn: "Rechecking Chat capacity…"
        case .discardingPendingUserTurn: "Unlocking Draft…"
        case .acceptingProfileProposal: "Accepting Profile changes…"
        case .discardingProfileProposal: "Discarding Profile changes…"
        case .publishingProfileEvidence: nil
        case .retryingProfileEvidencePublication: "Retrying Profile evidence…"
        case .discardingProfileEvidencePublication: "Discarding Profile evidence…"
        case .reconsideringProfileEffect: "Coach is reconsidering the suggestion…"
        case .stoppingProfileReconsideration:
            "Stopping Profile reconsideration…"
        case .discardingProfileReconsiderationFailure:
            "Restoring Profile suggestion actions…"
        case nil: nil
        }
    }

    static func usesChatRowSpinner(
        for activity: ChatFeatureState.Activity?
    ) -> Bool {
        activity?.processingChatID != nil
    }

    static func usesVisibleChatRowSpinner(
        for activity: ChatFeatureState.Activity?,
        visibleChatIDs: [ChatID]
    ) -> Bool {
        guard let processingChatID = activity?.processingChatID else {
            return false
        }
        return visibleChatIDs.contains(processingChatID)
    }
}

enum CoachContextQuotePresentation {
    static func summary(_ quote: CoachContextQuote) -> String {
        summary(
            completeInputTokens: quote.completeInputTokens,
            inputCeilingTokens: quote.inputCeilingTokens
        )
    }

    static func summary(
        completeInputTokens: Int,
        inputCeilingTokens: Int
    ) -> String {
        "~\(completeInputTokens) / \(inputCeilingTokens) input tokens"
    }

    static func categoryLabel(_ category: CoachContextCostCategory) -> String {
        switch category {
        case .profile: "Profile"
        case .memory: "Coach Memory"
        case .history: "Prior chat history"
        case .draft: "Current Draft"
        case .framing: "Provider framing"
        case .attachments: "Attachments"
        case .transcriptExchange: "Transcript exchange reserve"
        case .responseReserve: "Response reserve"
        case .safetyMargin: "Safety margin"
        }
    }
}

enum ChatInvocationAdmissionPresentation {
    static func unavailableReason(
        for availability: InvocationAdmissionAvailability?
    ) -> String? {
        switch availability {
        case nil:
            "Coach admission availability is being checked."
        case let .cooldown(reopensAt):
            "Coach admission reopens at \(reopensAt.rawValue)."
        case .unavailable:
            "Coach admission availability could not be checked."
        case .available:
            nil
        }
    }
}

struct CoachResponseFailureCardPresentation: Equatable {
    let heading: String
    let body: String?
    let sessionLinks: [CoachResponseFailureSessionLinkPresentation]
    let additionalSessionCount: Int

    init(
        heading: String,
        body: String?,
        sessionLinks: [CoachResponseFailureSessionLinkPresentation] = [],
        additionalSessionCount: Int = 0
    ) {
        self.heading = heading
        self.body = body
        self.sessionLinks = sessionLinks
        self.additionalSessionCount = additionalSessionCount
    }
}

struct CoachResponseFailureSessionLinkPresentation: Equatable {
    let attachmentID: ChatSessionAttachmentID
    let displayLabel: String
    let sessionID: SessionID
}

struct CoachResponseFailureSessionLinkView: View {
    let link: CoachResponseFailureSessionLinkPresentation
    let onOpenSession: (SessionID) -> Void

    var body: some View {
        Button(link.displayLabel, action: openSession)
            .accessibilityLabel("Open Session, \(link.displayLabel)")
    }

    func openSession() {
        onOpenSession(link.sessionID)
    }
}

enum CoachResponseFailurePresentation {
    static func card(
        for failure: PendingUserTurnFailure?,
        attachments: ChatAttachments = .empty
    ) -> CoachResponseFailureCardPresentation {
        switch failure {
        case .coachProviderError:
            return CoachResponseFailureCardPresentation(
                heading: "Coach provider error",
                body: "The coach could not complete the request."
            )
        case .coachResponseInvalid:
            return CoachResponseFailureCardPresentation(
                heading: "Coach response couldn't be used",
                body: "The coach returned an incomplete or invalid response."
            )
        case let .coachTranscriptReadFailed(summary):
            let sessionsByAttachmentID = Dictionary(
                uniqueKeysWithValues: attachments.values.map {
                    ($0.attachmentID, $0.sessionID)
                }
            )
            let links: [CoachResponseFailureSessionLinkPresentation] = summary.sessions
                .prefix(CoachTranscriptReadFailureSummary.maximumLinkedSessionCount)
                .compactMap { session in
                    guard let sessionID = sessionsByAttachmentID[
                        session.sessionAttachmentID
                    ] else { return nil }
                    return CoachResponseFailureSessionLinkPresentation(
                        attachmentID: session.sessionAttachmentID,
                        displayLabel: session.displayLabel,
                        sessionID: sessionID
                    )
                }
            return CoachResponseFailureCardPresentation(
                heading: "Some Sessions couldn't be read",
                body: "The Coach stopped before publishing anything. Open the affected Sessions, then Retry.",
                sessionLinks: links,
                additionalSessionCount: Int(summary.additionalSessionCount)
            )
        case .coachResponseInterrupted, .none, .coachContextCannotFit:
            return CoachResponseFailureCardPresentation(
                heading: "Coach response was interrupted",
                body: nil
            )
        }
    }

    static func retryAccessibilityLabel(
        for _: PendingUserTurnFailure?
    ) -> String {
        "Retry Coach Response"
    }

    static func discardAccessibilityLabel(
        for _: PendingUserTurnFailure?
    ) -> String {
        "Discard Coach Response"
    }
}

enum PendingUserTurnRecoveryAction: Hashable {
    case stopCoachResponse
    case retryPendingUserTurn
    case discardPendingUserTurn
    case createNewChatFromCapacityFailure
    case retryCoachResponse
    case discardCoachResponse

    var title: String {
        switch self {
        case .stopCoachResponse: "Stop"
        case .retryPendingUserTurn, .retryCoachResponse: "Retry"
        case .discardPendingUserTurn, .discardCoachResponse: "Discard"
        case .createNewChatFromCapacityFailure: "Create New Chat"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .stopCoachResponse: "Stop Coach Response"
        case .retryPendingUserTurn: "Retry Pending User Turn"
        case .discardPendingUserTurn: "Discard Pending User Turn"
        case .createNewChatFromCapacityFailure:
            "Create New Chat from capacity failure"
        case .retryCoachResponse:
            CoachResponseFailurePresentation.retryAccessibilityLabel(for: nil)
        case .discardCoachResponse:
            CoachResponseFailurePresentation.discardAccessibilityLabel(for: nil)
        }
    }
}

enum PendingUserTurnPresentation: Equatable {
    case processing
    case stopping
    case contextCapacityFailure
    case coachResponseFailure
    case locked

    static func project(
        _ pending: PendingUserTurn,
        state: ChatFeatureState
    ) -> PendingUserTurnPresentation {
        if case let .open(aggregate) = state.selection,
           aggregate.pendingUserTurn == pending,
           state.composer == .locked(aggregate.chat.draft, pending),
           state.operationallyInterruptedInvocation == nil,
           pending.failure == nil
        {
            if state.activity == .invokingCoach(aggregate.chat.id) {
                return .processing
            }
            if state.activity == .stoppingCoach(aggregate.chat.id) {
                return .stopping
            }
        }
        if pending.failure == .coachContextCannotFit {
            return .contextCapacityFailure
        }
        if state.isCoachResponseRetryableFailure(pending) {
            return .coachResponseFailure
        }
        return .locked
    }

    var showsAdmissionUnavailableReason: Bool {
        self != .processing && self != .stopping
    }

    var recoveryActions: [PendingUserTurnRecoveryAction] {
        switch self {
        case .processing:
            [.stopCoachResponse]
        case .stopping:
            [.stopCoachResponse]
        case .contextCapacityFailure:
            [
                .retryPendingUserTurn,
                .discardPendingUserTurn,
                .createNewChatFromCapacityFailure,
            ]
        case .coachResponseFailure:
            [.retryCoachResponse, .discardCoachResponse]
        case .locked:
            [.discardPendingUserTurn]
        }
    }
}

private struct CoachInvocationControlModifier: ViewModifier {
    let disabled: Bool
    let unavailableReason: String?

    func body(content: Content) -> some View {
        content
            .disabled(disabled)
            .accessibilityHint(unavailableReason ?? "")
            .onHover { hovering in
                if hovering, disabled {
                    NSCursor.operationNotAllowed.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }
}

private extension View {
    func coachInvocationControl(
        disabled: Bool,
        admissionAvailability: InvocationAdmissionAvailability?
    ) -> some View {
        modifier(
            CoachInvocationControlModifier(
                disabled: disabled,
                unavailableReason: ChatInvocationAdmissionPresentation
                    .unavailableReason(for: admissionAvailability)
            )
        )
    }
}

struct CoachEvidenceObservationView: View {
    let markdown: String
    let evidence: [EvidenceReference]
    let availability: (EvidenceReference) -> CoachEvidenceLinkAvailability
    let onOpenEvidence: (EvidenceReference) -> Void
    let onUnavailable: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Evidence-backed observation", systemImage: "quote.bubble")
                .font(.caption.weight(.semibold))
            Text(renderedMarkdown)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(evidence.enumerated()), id: \.offset) { _, reference in
                CoachEvidenceLinkView(
                    reference: reference,
                    availability: availability(reference),
                    onOpen: onOpenEvidence,
                    onUnavailable: onUnavailable
                )
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator)
        }
        .accessibilityElement(children: .contain)
    }

    private var renderedMarkdown: AttributedString {
        (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }
}

enum CoachEvidenceLinkAvailability: Equatable {
    case available
    case unavailable(String)

    var explanation: String? {
        guard case let .unavailable(explanation) = self else { return nil }
        return explanation
    }
}

struct CoachEvidenceLinkView: View {
    let reference: EvidenceReference
    let availability: CoachEvidenceLinkAvailability
    let onOpen: (EvidenceReference) -> Void
    let onUnavailable: (String) -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            if availability == .available {
                onOpen(reference)
            } else if let explanation = availability.explanation {
                onUnavailable(explanation)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.circle.fill")
                VStack(alignment: .leading, spacing: 1) {
                    Text(reference.display.sessionLabel)
                        .font(.caption.weight(.semibold))
                        .underline(isHovering || isFocused)
                    Text(
                        "\(Self.format(reference.display.startMilliseconds)) · " +
                            reference.display.trustedText
                    )
                    .font(.caption)
                    .lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isHovering || isFocused
                    ? Color.accentColor.opacity(0.12)
                    : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isFocused ? Color.accentColor : Color.secondary.opacity(0.45),
                        lineWidth: isFocused ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .accessibilityLabel(
            "Open evidence in \(reference.display.sessionLabel) at " +
                Self.format(reference.display.startMilliseconds)
        )
        .accessibilityHint(
            availability.explanation ??
                "Opens Transcript Review, highlights this evidence, and seeks audio."
        )
        if let explanation = availability.explanation {
            Text(explanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Evidence unavailable: \(explanation)")
        }
    }

    private static func format(_ milliseconds: UInt64) -> String {
        let totalSeconds = milliseconds / 1_000
        return String(
            format: "%02llu:%02llu.%03llu",
            totalSeconds / 60,
            totalSeconds % 60,
            milliseconds % 1_000
        )
    }
}

public struct ChatRootView: View {
    @StateObject private var model: ChatPresentationModel
    @ObservedObject private var dispatcher: ChatCommandDispatcher
    @State private var renameTitle = ""
    private let activation: LibraryActivation
    private let onOpenSession: (SessionID) -> Void
    private let onOpenEvidence: (EvidenceReference) -> Void

    public init(
        dispatcher: ChatCommandDispatcher,
        activation: LibraryActivation,
        onOpenSession: @escaping (SessionID) -> Void = { _ in },
        onOpenEvidence: @escaping (EvidenceReference) -> Void = { _ in }
    ) {
        _model = StateObject(wrappedValue: ChatPresentationModel(dispatcher: dispatcher))
        _dispatcher = ObservedObject(wrappedValue: dispatcher)
        self.activation = activation
        self.onOpenSession = onOpenSession
        self.onOpenEvidence = onOpenEvidence
    }

    public var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Chats")
                        .font(.headline)
                    Spacer()
                    Button("New Chat") {
                        model.beginNewChat()
                    }
                    .accessibilityLabel("Create New Chat")
                    .disabled(!allowsNavigationAndMutation)
                }

                HStack {
                    TextField(
                        "Filter Chats",
                        text: Binding(
                            get: { model.filterText },
                            set: { model.updateFilter($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter Chats")
                    if !model.filterText.isEmpty {
                        Button("Clear") { model.clearFilter() }
                            .accessibilityLabel("Clear Chat Filter")
                    }
                }

                chatList
                activityView
                if let notice = model.snapshot.notice {
                    Text(ChatNoticePresentation.recoveryText(for: notice))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            ChatNoticePresentation.accessibilityLabel(for: notice)
                        )
                }
            }
            .frame(minWidth: 220, idealWidth: 260)
            .padding(.trailing, 12)

            detailView
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, 12)
        }
        .overlay(alignment: .top) {
            if let notice = model.snapshot.transientNotice {
                Text(ChatTransientNoticePresentation.text(for: notice))
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 4, y: 2)
                    .padding(.top, 12)
                    .accessibilityLabel(
                        ChatTransientNoticePresentation.accessibilityLabel(
                            for: notice
                        )
                    )
            }
        }
        .task(id: LibraryActivationPresentationIdentity(activation)) {
            await model.start(in: activation)
        }
        .sheet(isPresented: newChatSheetIsPresented) {
            newChatSheet
        }
    }

    @ViewBuilder
    private var chatList: some View {
        switch model.snapshot.catalog {
        case .notLoaded, .loading:
            ProgressView("Loading Chats…")
        case .failed:
            ContentUnavailableView(
                "Chats Unavailable",
                systemImage: "exclamationmark.bubble"
            )
        case let .ready(catalog):
            if catalog.visibleRows.isEmpty {
                ContentUnavailableView(
                    model.filterText.isEmpty ? "No Chats" : "No Matching Chats",
                    systemImage: "bubble.left.and.bubble.right"
                )
            } else {
                List(catalog.visibleRows, id: \.chatID) { row in
                    let indicatorPresentation = ChatRowIndicatorPresentation(
                        indicators: model.indicators(for: row)
                    )
                    Button {
                        model.open(row.chatID)
                    } label: {
                        HStack {
                            Text(row.title?.rawValue ?? "Unavailable Chat")
                            Spacer()
                            chatRowIndicators(indicatorPresentation)
                            if case .frozen = row.availability {
                                Image(systemName: "lock.fill")
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        indicatorPresentation.accessibilityLabel(for: row)
                    )
                    .disabled(!allowsNavigationAndMutation)
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder
    private func chatRowIndicators(
        _ presentation: ChatRowIndicatorPresentation
    ) -> some View {
        if presentation.hasVisibleIndicator {
            HStack(spacing: 7) {
                switch presentation.indicators.activity {
                case .idle:
                    EmptyView()
                case .processing:
                    SlowChatRowSpinner()
                        .help(presentation.activityAccessibilityLabel ?? "")
                case .interrupted:
                    Image(systemName: presentation.activitySymbolName ?? "")
                        .foregroundStyle(.orange)
                        .help(presentation.activityAccessibilityLabel ?? "")
                case .newMessage:
                    Image(systemName: presentation.activitySymbolName ?? "")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tint)
                        .help(presentation.activityAccessibilityLabel ?? "")
                }
                if let profileSymbolName = presentation.profileSymbolName {
                    Image(systemName: profileSymbolName)
                        .foregroundStyle(
                            presentation.indicators.profileUpdate ==
                                .publicationFailure ? .red : .purple
                        )
                        .help(presentation.profileAccessibilityLabel ?? "")
                }
            }
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch model.snapshot.selection {
        case .none:
            ContentUnavailableView(
                "Select a Chat",
                systemImage: "bubble.left"
            )
        case .opening:
            ProgressView("Opening Chat…")
        case let .frozen(frozen):
            ContentUnavailableView(
                frozen.reason == .newerSchema ? "Chat Is Read-Only" : "Chat Is Unavailable",
                systemImage: "lock.doc",
                description: Text("Create a new Chat to continue reflecting.")
            )
        case let .open(aggregate):
            let timeline = ChatTimelinePresentation.project(
                aggregate,
                state: model.snapshot
            )
            VStack(alignment: .leading, spacing: 16) {
                Text(aggregate.chat.title.rawValue)
                    .font(.title2.weight(.semibold))
                HStack {
                    TextField("Chat title", text: $renameTitle)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Rename Chat Title")
                    Button("Rename Chat") {
                        model.rename(
                            aggregate.chat.id,
                            title: renameTitle,
                            expectedRevision: aggregate.chat.manifestRevision
                        )
                    }
                    .disabled(!allowsNavigationAndMutation)
                }
                openedAttachmentsView(aggregate)
                GroupBox("Successful history") {
                    if aggregate.chat.messageIDs.isEmpty {
                        Text("No completed Coach turns yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if aggregate.messages.isEmpty {
                        Text("\(aggregate.chat.messageIDs.count) completed messages")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(timeline.successfulHistory) { entry in
                                    successfulTimelineEntryView(entry)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 300)
                    }
                }
                if timeline.tailPlacement == .afterSuccessfulContent,
                   let divider = timeline.tailProfileUpdate
                {
                    profileUpdateDividerView(divider)
                }
                if let divider = timeline.profileEffectProfileUpdate {
                    profileUpdateDividerView(divider)
                }
                if let proposal = aggregate.profileProposal {
                    profileProposalView(
                        proposal,
                        preparedTimelineDivider:
                            profileEffectPreparedTimelineDivider(timeline),
                        tailTimelineDivider:
                            profileEffectTailTimelineDivider(timeline)
                    )
                }
                if let publicationCard =
                    ProfileEvidencePublicationFailurePresentation.card(
                        for: aggregate.profileEvidencePublication,
                        openedAttachments: model.snapshot.openedAttachments,
                        activity: model.snapshot.activity
                    )
                {
                    profileEvidencePublicationFailureView(
                        publicationCard,
                        preparedTimelineDivider:
                            profileEffectPreparedTimelineDivider(timeline),
                        tailTimelineDivider:
                            profileEffectTailTimelineDivider(timeline)
                    )
                }
                if timeline.tailPlacement == .afterProfileEffectCard,
                   let divider = timeline.tailProfileUpdate
                {
                    profileUpdateDividerView(divider)
                }
                if timeline.pendingActionPlacement == .beforePendingUserTurn,
                   let divider = timeline.pendingActionProfileUpdate
                {
                    profileUpdateDividerView(divider)
                }
                composerView
                if timeline.tailPlacement == .afterPendingUserTurn,
                   let divider = timeline.tailProfileUpdate
                {
                    profileUpdateDividerView(divider)
                }
                Spacer()
            }
            .task(
                id: ChatRenameEditorTaskID(
                    chatID: aggregate.chat.id,
                    manifestRevision: aggregate.chat.manifestRevision
                )
            ) {
                renameTitle = aggregate.chat.title.rawValue
            }
        }
    }

    @ViewBuilder
    private func successfulTimelineEntryView(
        _ entry: ChatTimelineEntryPresentation
    ) -> some View {
        switch entry {
        case let .profileUpdate(divider):
            profileUpdateDividerView(divider)
        case let .message(message):
            successfulMessageView(message)
        }
    }

    private func profileUpdateDividerView(
        _ presentation: ProfileUpdateDividerPresentation
    ) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.secondary.opacity(0.28))
                .frame(height: 1)
                .accessibilityHidden(true)
            Text(presentation.visibleText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle()
                .fill(Color.secondary.opacity(0.28))
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private func profileEffectPreparedTimelineDivider(
        _ timeline: ChatTimelinePresentation
    ) -> ProfileUpdateDividerPresentation? {
        guard timeline.pendingActionPlacement ==
            .beforeProfileReconsiderationResult
        else {
            return nil
        }
        return timeline.pendingActionProfileUpdate
    }

    private func profileEffectTailTimelineDivider(
        _ timeline: ChatTimelinePresentation
    ) -> ProfileUpdateDividerPresentation? {
        guard timeline.tailPlacement == .afterProfileReconsideration else {
            return nil
        }
        return timeline.tailProfileUpdate
    }

    @ViewBuilder
    private func successfulMessageView(_ message: ChatMessage) -> some View {
        switch message.content {
        case let .user(text):
            VStack(alignment: .leading, spacing: 4) {
                Text("You").font(.caption.weight(.semibold))
                Text(text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .coach(blocks):
            VStack(alignment: .leading, spacing: 8) {
                Text("Coach").font(.caption.weight(.semibold))
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case let .markdown(markdown):
                        Text(renderedMarkdown(markdown))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case let .evidenceObservation(markdown, evidence):
                        CoachEvidenceObservationView(
                            markdown: markdown,
                            evidence: evidence,
                            availability: evidenceAvailability,
                            onOpenEvidence: onOpenEvidence,
                            onUnavailable: model.announceEvidenceUnavailable
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func renderedMarkdown(_ source: String) -> AttributedString {
        (try? AttributedString(markdown: source)) ?? AttributedString(source)
    }

    private func evidenceAvailability(
        _ reference: EvidenceReference
    ) -> CoachEvidenceLinkAvailability {
        switch model.snapshot.openedAttachments {
        case .notRequested, .resolving:
            return .unavailable("Checking the exact Transcript Revision…")
        case .failed:
            return .unavailable("The exact Transcript Revision could not be verified.")
        case let .resolved(resolutions):
            guard let resolved = resolutions.first(where: {
                $0.attachment.sessionID == reference.sessionID &&
                    $0.attachment.transcriptRevisionID ==
                    reference.transcriptRevisionID
            }) else {
                return .unavailable("The attached Transcript Revision is unavailable.")
            }
            switch resolved.resolution {
            case .available:
                return .available
            case let .unavailable(reason):
                return .unavailable(
                    "The supporting Session is \(Self.attachmentUnavailableText(reason))."
                )
            }
        }
    }

    private func profileProposalView(
        _ proposal: ProfileChangeProposal,
        preparedTimelineDivider: ProfileUpdateDividerPresentation?,
        tailTimelineDivider: ProfileUpdateDividerPresentation?
    ) -> some View {
        let presentation = ProfileProposalCardPresentation(proposal)
        return GroupBox("Profile Change Proposal") {
            VStack(alignment: .leading, spacing: 12) {
                Text("The coach suggests these Profile changes:")
                    .font(.callout)

                ForEach(
                    Array(presentation.changes.enumerated()),
                    id: \.offset
                ) { _, change in
                    profileProposalChangeView(change)
                }

                ForEach(
                    Array(presentation.evidenceAppends.enumerated()),
                    id: \.offset
                ) { _, append in
                    profileEvidenceAppendView(append)
                }

                Text(ProfileProposalCardPresentation.explanatoryCopy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let preparedTimelineDivider {
                    profileUpdateDividerView(preparedTimelineDivider)
                }
                if let reconsideration = currentProfileReconsideration(
                    for: .proposal(presentation.proposalID)
                ) {
                    profileReconsiderationFailureDetails(reconsideration)
                }
                if let tailTimelineDivider {
                    profileUpdateDividerView(tailTimelineDivider)
                }
                profileEffectRecoveryActions(
                    for: .proposal(presentation.proposalID)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private func profileEvidencePublicationFailureView(
        _ presentation: ProfileEvidencePublicationFailureCardPresentation,
        preparedTimelineDivider: ProfileUpdateDividerPresentation?,
        tailTimelineDivider: ProfileUpdateDividerPresentation?
    ) -> some View {
        GroupBox("Profile Publication Failure") {
            VStack(alignment: .leading, spacing: 12) {
                Text(presentation.heading)
                    .font(.callout.weight(.semibold))

                ForEach(Array(presentation.updates.enumerated()), id: \.offset) {
                    _, update in
                    Text(update)
                        .fixedSize(horizontal: false, vertical: true)
                }

                let identity = ChatProfileEffectIdentity.evidencePublication(
                    presentation.responsePositionID
                )
                if let preparedTimelineDivider {
                    profileUpdateDividerView(preparedTimelineDivider)
                }
                if let reconsideration = currentProfileReconsideration(
                    for: identity
                ) {
                    profileReconsiderationFailureDetails(reconsideration)
                }
                if let tailTimelineDivider {
                    profileUpdateDividerView(tailTimelineDivider)
                }
                profileEffectRecoveryActions(for: identity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private func currentProfileReconsideration(
        for identity: ChatProfileEffectIdentity
    ) -> ProfileReconsideration? {
        guard case let .open(aggregate) = model.snapshot.selection,
              aggregate.profileEffect?.identity == identity,
              aggregate.profileReconsideration?.sourceEffectIdentity ==
                identity
        else { return nil }
        return aggregate.profileReconsideration
    }

    @ViewBuilder
    private func profileReconsiderationFailureDetails(
        _ reconsideration: ProfileReconsideration
    ) -> some View {
        if let failure = reconsideration.failure {
            let card = CoachResponseFailurePresentation.card(
                for: failure,
                attachments: selectedChatAttachments
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(card.heading)
                    .font(.callout.weight(.semibold))
                    .accessibilityLabel(card.heading)
                if let body = card.body {
                    Text(body)
                        .font(.callout)
                        .accessibilityLabel(body)
                }
                ForEach(card.sessionLinks, id: \.attachmentID) { link in
                    CoachResponseFailureSessionLinkView(
                        link: link,
                        onOpenSession: onOpenSession
                    )
                }
                if card.additionalSessionCount > 0 {
                    Text("+ \(card.additionalSessionCount) more Sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            "\(card.additionalSessionCount) additional affected Sessions"
                        )
                }
            }
        }
    }

    @ViewBuilder
    private func profileEffectRecoveryActions(
        for identity: ChatProfileEffectIdentity
    ) -> some View {
        let actions = ProfileEffectRecoveryPresentation.actions(
            for: identity,
            in: model.snapshot
        )
        if !actions.isEmpty {
            HStack {
                Spacer()
                ForEach(Array(actions.reversed()), id: \.self) { action in
                    profileEffectRecoveryButton(action, identity: identity)
                }
            }
        }
    }

    @ViewBuilder
    private func profileEffectRecoveryButton(
        _ action: ProfileEffectRecoveryAction,
        identity: ChatProfileEffectIdentity
    ) -> some View {
        switch action {
        case .reconsider, .retryReconsideration:
            Button(action.title) {
                if action == .reconsider {
                    model.reconsiderProfileEffect(identity)
                } else {
                    model.retryProfileReconsideration(identity)
                }
            }
            .accessibilityLabel(
                action == .reconsider
                    ? "Reconsider Profile Suggestion"
                    : "Retry Profile Reconsideration"
            )
            .coachInvocationControl(
                disabled: !allowsNavigationAndMutation ||
                    model.snapshot.admissionAvailability != .available,
                admissionAvailability: model.snapshot.admissionAvailability
            )

        case .stopReconsideration:
            Button(action.title) {
                model.stopProfileReconsideration()
            }
            .accessibilityLabel("Stop Profile Reconsideration")
            .disabled(
                !ProfileReconsiderationStopInteractionPresentation(
                    admissionState: dispatcher.admissionState,
                    chatState: model.snapshot
                ).isEnabled
            )

        case .acceptProposal:
            if case let .proposal(proposalID) = identity {
                Button(action.title) {
                    model.acceptProfileProposal(proposalID)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Accept Profile Change Proposal")
                .disabled(!allowsNavigationAndMutation)
            }

        case .retryEvidencePublication:
            if case let .evidencePublication(responsePositionID) = identity {
                Button(action.title) {
                    model.retryProfileEvidencePublication(responsePositionID)
                }
                .accessibilityLabel("Retry Profile Evidence Publication")
                .disabled(!allowsNavigationAndMutation)
            }

        case .discardEffect:
            Button(action.title) {
                switch identity {
                case let .proposal(proposalID):
                    model.discardProfileProposal(proposalID)
                case let .evidencePublication(responsePositionID):
                    model.discardProfileEvidencePublication(responsePositionID)
                }
            }
            .accessibilityLabel("Discard Profile Suggestion")
            .disabled(!allowsNavigationAndMutation)

        case .discardReconsiderationFailure:
            Button(action.title) {
                model.discardProfileReconsiderationFailure(identity)
            }
            .accessibilityLabel("Discard Profile Reconsideration Failure")
            .disabled(!allowsNavigationAndMutation)
        }
    }

    private func profileProposalChangeView(
        _ change: ProfileProposalChangePresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(change.heading)
                .font(.callout.weight(.semibold))
            if let currentWording = change.currentWording {
                proposalWording(label: "Current", wording: currentWording)
            }
            if let proposedWording = change.proposedWording {
                proposalWording(label: "Proposed", wording: proposedWording)
            }
            proposalEvidenceLinks(change.evidence)
        }
        .padding(10)
        .background(
            .quaternary.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator)
        }
        .accessibilityElement(children: .contain)
    }

    private func profileEvidenceAppendView(
        _ append: ProfileEvidenceAppendPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(append.heading)
                .font(.callout.weight(.semibold))
            proposalWording(label: "Current", wording: append.targetWording)
            proposalEvidenceLinks(append.evidence)
        }
        .padding(10)
        .background(
            .quaternary.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator)
        }
        .accessibilityElement(children: .contain)
    }

    private func proposalWording(label: String, wording: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(wording)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func proposalEvidenceLinks(
        _ evidence: [EvidenceReference]
    ) -> some View {
        if evidence.isEmpty {
            Text("No supporting evidence")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Evidence")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(evidence.enumerated()), id: \.offset) { _, reference in
                CoachEvidenceLinkView(
                    reference: reference,
                    availability: evidenceAvailability(reference),
                    onOpen: onOpenEvidence,
                    onUnavailable: model.announceEvidenceUnavailable
                )
            }
        }
    }

    @ViewBuilder
    private var composerView: some View {
        switch model.snapshot.composer {
        case let .editable(draft, isDirty):
            GroupBox("Draft") {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(
                        text: Binding(
                            get: {
                                guard case let .editable(current, _) = model.snapshot.composer,
                                      current.draftID == draft.draftID
                                else {
                                    return draft.text
                                }
                                return current.text
                            },
                            set: { model.updateDraft($0) }
                        )
                    )
                    .font(.body)
                    .frame(minHeight: 140)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.separator)
                    }
                    .accessibilityLabel("Chat Draft")
                    .disabled(
                        !allowsNavigationAndMutation ||
                            !ChatInteractionPolicy.allowsComposerEditing(
                                in: model.snapshot
                            )
                    )

                    HStack {
                        Text(isDirty ? "Unsaved changes" : "Saved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(
                                isDirty ? "Chat Draft has unsaved changes" : "Chat Draft is saved"
                            )
                        Spacer()
                        contextSummary
                        Button("Send") { model.sendDraft() }
                            .keyboardShortcut(.return, modifiers: [.command])
                            .accessibilityLabel("Send Chat Draft")
                            .coachInvocationControl(
                                disabled:
                                !allowsNavigationAndMutation ||
                                    !ChatInteractionPolicy.allowsComposerEditing(
                                        in: model.snapshot
                                    ) ||
                                    !ChatInteractionPolicy.allowsCoachInvocation(
                                        in: model.snapshot
                                    ) ||
                                    !sendIsContextEligible ||
                                    !draft.text.unicodeScalars.contains {
                                        !$0.properties.isWhitespace
                                    },
                                admissionAvailability: model.snapshot
                                    .admissionAvailability
                            )
                    }
                    admissionUnavailableReason
                    contextDetails
                    if messageNeedsShortening {
                        Text("Message is too long. Shorten it to send.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Message is too long. Shorten it to send.")
                    }
                }
            }
        case let .locked(draft, pending):
            GroupBox("Pending User Turn") {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView {
                        Text(draft.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 100)
                    .accessibilityLabel("Locked Chat Draft")
                    Text("This exact Draft is locked outside successful history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let presentation = PendingUserTurnPresentation.project(
                        pending,
                        state: model.snapshot
                    )
                    if presentation.showsAdmissionUnavailableReason {
                        admissionUnavailableReason
                    }
                    switch presentation {
                    case .processing:
                        HStack {
                            Spacer()
                            pendingRecoveryButtons(
                                presentation.recoveryActions,
                                pending: pending
                            )
                        }
                    case .stopping:
                        HStack {
                            Spacer()
                            pendingRecoveryButtons(
                                presentation.recoveryActions,
                                pending: pending
                            )
                        }
                    case .contextCapacityFailure:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Chat size exceeded. Please create a new one.")
                                .font(.callout.weight(.semibold))
                                .accessibilityLabel(
                                    "Chat size exceeded. Please create a new one."
                                )
                            contextDetails
                            HStack {
                                pendingRecoveryButtons(
                                    presentation.recoveryActions,
                                    pending: pending
                                )
                            }
                        }
                    case .coachResponseFailure:
                        VStack(alignment: .leading, spacing: 8) {
                            let failureCard = CoachResponseFailurePresentation.card(
                                for: pending.failure,
                                attachments: selectedChatAttachments
                            )
                            Text(failureCard.heading)
                                .font(.callout.weight(.semibold))
                                .accessibilityLabel(failureCard.heading)
                            if let body = failureCard.body {
                                Text(body)
                                    .font(.callout)
                                    .accessibilityLabel(body)
                            }
                            ForEach(
                                failureCard.sessionLinks,
                                id: \.attachmentID
                            ) { link in
                                CoachResponseFailureSessionLinkView(
                                    link: link,
                                    onOpenSession: onOpenSession
                                )
                            }
                            if failureCard.additionalSessionCount > 0 {
                                Text(
                                    "+ \(failureCard.additionalSessionCount) more Sessions"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(
                                    "\(failureCard.additionalSessionCount) additional affected Sessions"
                                )
                            }
                            HStack {
                                pendingRecoveryButtons(
                                    presentation.recoveryActions,
                                    pending: pending
                                )
                            }
                        }
                    case .locked:
                        HStack {
                            Spacer()
                            pendingRecoveryButtons(
                                presentation.recoveryActions,
                                pending: pending
                            )
                        }
                    }
                }
            }
        case nil:
            EmptyView()
        }
    }

    private var selectedChatAttachments: ChatAttachments {
        guard case let .open(aggregate) = model.snapshot.selection else {
            return .empty
        }
        return aggregate.chat.attachments
    }

    @ViewBuilder
    private var activityView: some View {
        if let label = ChatActivityPresentation.progressLabel(
            for: model.snapshot.activity
        ) {
            if ChatActivityPresentation.usesVisibleChatRowSpinner(
                for: model.snapshot.activity,
                visibleChatIDs: visibleChatIDs
            ) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if ChatActivityPresentation.usesChatRowSpinner(
                for: model.snapshot.activity
            ) {
                HStack(spacing: 7) {
                    SlowChatRowSpinner()
                    Text(label)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label)
            } else {
                ProgressView(label)
            }
        }
    }

    private var visibleChatIDs: [ChatID] {
        guard case let .ready(catalog) = model.snapshot.catalog else {
            return []
        }
        return catalog.visibleRows.map(\.chatID)
    }

    @ViewBuilder
    private func pendingRecoveryButtons(
        _ actions: [PendingUserTurnRecoveryAction],
        pending: PendingUserTurn
    ) -> some View {
        ForEach(actions, id: \.self) { action in
            switch action {
            case .stopCoachResponse:
                Button(action.title) {
                    model.stopCoachResponse()
                }
                .accessibilityLabel(action.accessibilityLabel)
                .disabled(
                    !CoachResponseStopInteractionPresentation(
                        admissionState: dispatcher.admissionState,
                        chatState: model.snapshot
                    ).isEnabled
                )
            case .retryPendingUserTurn, .retryCoachResponse:
                Button(action.title) {
                    model.retryPendingUserTurn(pending.id)
                }
                .accessibilityLabel(action.accessibilityLabel)
                .coachInvocationControl(
                    disabled: !allowsNavigationAndMutation ||
                        !ChatInteractionPolicy.allowsCoachInvocation(
                            in: model.snapshot
                        ),
                    admissionAvailability: model.snapshot.admissionAvailability
                )
            case .discardPendingUserTurn, .discardCoachResponse:
                Button(action.title) {
                    model.discardPendingUserTurn(pending.id)
                }
                .accessibilityLabel(action.accessibilityLabel)
                .disabled(!allowsNavigationAndMutation)
            case .createNewChatFromCapacityFailure:
                Button(action.title) {
                    model.createNewChatFromCapacityFailure(pending.id)
                }
                .accessibilityLabel(action.accessibilityLabel)
                .disabled(!allowsNavigationAndMutation)
            }
        }
    }

    private var allowsNavigationAndMutation: Bool {
        newChatSheetInteractionPresentation.allowsControlInteraction
    }

    private var newChatSheetIsPresented: Binding<Bool> {
        Binding(
            get: {
                if case .closed = model.snapshot.newChatPicker { return false }
                return true
            },
            set: { presented in
                if !presented { model.cancelNewChat() }
            }
        )
    }

    @ViewBuilder
    private var newChatSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Chat")
                .font(.title2.weight(.semibold))
            Text("Choose any number of Sessions. The exact selected transcript revisions stay pinned to this Chat.")
                .foregroundStyle(.secondary)

            switch model.snapshot.newChatPicker {
            case .closed:
                EmptyView()
            case .loading:
                VStack {
                    newChatSearchField
                    ProgressView("Loading Sessions…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack {
                        Spacer()
                        Button("Cancel") { model.cancelNewChat() }
                            .keyboardShortcut(.cancelAction)
                            .disabled(!newChatSheetInteractionPresentation.allowsCancellation)
                    }
                }
            case .failed:
                VStack {
                    newChatSearchField
                    ContentUnavailableView(
                        "Sessions Unavailable",
                        systemImage: "exclamationmark.bubble"
                    )
                    HStack {
                        Spacer()
                        Button("Cancel") { model.cancelNewChat() }
                            .keyboardShortcut(.cancelAction)
                            .disabled(!newChatSheetInteractionPresentation.allowsCancellation)
                    }
                }
            case let .ready(picker):
                SessionMultiSelectionShell(
                    searchText: Binding(
                        get: { model.newChatAttachmentFilterText },
                        set: { model.updateNewChatAttachmentFilter($0) }
                    ),
                    searchAccessibilityLabel: "Search Sessions for New Chat",
                    rows: picker.visibleRows.map { row in
                        SessionMultiSelectionRow(
                            id: row.id,
                            title: row.displayLabel,
                            metadata: "\(Self.durationText(row.durationMilliseconds)) · " +
                                "~\(row.approximateTranscriptTokens) tokens · " +
                                (row.delivery == .inline ? "Inline" : "On demand"),
                            accessibilityLabel:
                                "\(row.displayLabel), " +
                                "\(Self.durationText(row.durationMilliseconds)), " +
                                "approximately \(row.approximateTranscriptTokens) " +
                                "transcript tokens, " +
                                (row.delivery == .inline ? "inline" : "on demand")
                        )
                    },
                    hasAnyRows: !picker.allRows.isEmpty,
                    selectedIDs: picker.selectedAttachmentIDs,
                    controlsEnabled:
                        newChatSheetInteractionPresentation.allowsControlInteraction
                ) { attachmentID in
                    model.performNewChatAttachmentPickerAction(
                        .toggle(attachmentID)
                    )
                }

                creationQuote(picker)
                if let issue = picker.issue {
                    Label(
                        NewChatAttachmentPickerPresentation.recoveryText(for: issue),
                        systemImage: issue.blocksConfirmation
                            ? "exclamationmark.triangle"
                            : "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        NewChatAttachmentPickerPresentation.accessibilityAnnouncement(
                            for: issue
                        )
                    )
                    if issue == .qualifiedConfigurationUnavailable {
                        Button("Check Again") {
                            model.retryNewChatConfiguration()
                        }
                        .disabled(
                            !newChatSheetInteractionPresentation.allowsControlInteraction
                        )
                        .accessibilityHint(
                            "Reloads Sessions and recalculates context while retaining every still-available exact selection"
                        )
                    }
                }
                HStack {
                    Text("\(picker.selectionCount) selected")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(picker.selectionCount) Sessions selected")
                    Spacer()
                    Button("Cancel") {
                        model.performNewChatAttachmentPickerAction(.cancelAction)
                    }
                        .keyboardShortcut(.cancelAction)
                        .disabled(!newChatSheetInteractionPresentation.allowsCancellation)
                    Button("Create Chat") {
                        model.performNewChatAttachmentPickerAction(.defaultAction)
                    }
                        .keyboardShortcut(.defaultAction)
                        .disabled(
                            !newChatSheetInteractionPresentation.allowsControlInteraction ||
                                !picker.permitsConfirmation
                        )
                        .accessibilityHint("Creates a Chat without sending a message")
                }
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 520)
        .overlay(alignment: .bottomLeading) {
            if let busyAccessibilityLabel =
                newChatSheetInteractionPresentation.busyAccessibilityLabel
            {
                ProgressView("Finishing current action…")
                    .accessibilityLabel(busyAccessibilityLabel)
                    .padding(24)
            }
        }
        .interactiveDismissDisabled(
            newChatSheetInteractionPresentation.preventsInteractiveDismissal
        )
    }

    private var newChatSearchField: some View {
        TextField(
            "Search Sessions",
            text: Binding(
                get: { model.newChatAttachmentFilterText },
                set: { model.updateNewChatAttachmentFilter($0) }
            )
        )
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Search Sessions for New Chat")
        .disabled(!newChatSheetInteractionPresentation.allowsControlInteraction)
    }

    private var newChatSheetInteractionPresentation: NewChatSheetInteractionPresentation {
        NewChatSheetInteractionPresentation(
            admissionState: dispatcher.admissionState,
            chatState: model.snapshot
        )
    }

    @ViewBuilder
    private func creationQuote(_ picker: ChatAttachmentPickerSnapshot) -> some View {
        switch picker.feasibility {
        case .quoting:
            ProgressView("Estimating current Profile and Session context…")
                .controlSize(.small)
        case let .available(quote):
            creationContextMeter(NewChatCreationContextPresentation(quote.context))
        case let .providerUnavailable(lowerBound):
            VStack(alignment: .leading, spacing: 4) {
                creationContextMeter(NewChatCreationContextPresentation(lowerBound))
                Text(NewChatAttachmentPickerPresentation.providerUnavailableRecoveryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .unavailable:
            EmptyView()
        }
    }

    @ViewBuilder
    private func creationContextMeter(
        _ presentation: NewChatCreationContextPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(presentation.summary)
                .font(.callout.monospacedDigit())
            ProgressView(
                value: Double(presentation.usedTokens),
                total: Double(presentation.maximumTokens)
            )
            .accessibilityLabel(presentation.accessibilityLabel)
            if let profileContribution = presentation.profileContribution {
                Text(profileContribution)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func durationText(_ milliseconds: UInt64) -> String {
        let totalSeconds = milliseconds / 1_000
        return String(
            format: "%llu:%02llu",
            totalSeconds / 60,
            totalSeconds % 60
        )
    }

    @ViewBuilder
    private func openedAttachmentsView(_ aggregate: ChatAggregate) -> some View {
        if aggregate.chat.attachments.values.isEmpty {
            Text("No Sessions attached")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Chat attachments: No Sessions attached")
        } else {
            GroupBox("Pinned Sessions") {
                switch model.snapshot.openedAttachments {
                case .notRequested, .resolving:
                    ProgressView("Checking exact transcript revisions…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .failed:
                    Label("Pinned Sessions could not be verified", systemImage: "exclamationmark.triangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Pinned Chat attachments could not be verified")
                case let .resolved(resolutions):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(resolutions.enumerated()), id: \.element.attachment.attachmentID) {
                            index, resolved in
                            switch resolved.resolution {
                            case let .available(candidate):
                                HStack {
                                    Image(systemName: "pin.fill")
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.displayLabel)
                                        Text(
                                            "\(Self.durationText(candidate.durationMilliseconds)) · ~\(candidate.approximateTranscriptTokens) tokens · \(candidate.delivery == .inline ? "Inline" : "On demand")"
                                        )
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityLabel(
                                    "Pinned Session \(index + 1), \(candidate.displayLabel), exact transcript revision available"
                                )
                            case let .unavailable(reason):
                                Label(
                                    "Pinned Session \(index + 1): \(Self.attachmentUnavailableText(reason))",
                                    systemImage: "exclamationmark.triangle"
                                )
                                .accessibilityLabel(
                                    "Pinned Session \(index + 1), \(Self.attachmentUnavailableText(reason))"
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private static func attachmentUnavailableText(
        _ reason: ChatAttachmentUnavailableReason
    ) -> String {
        switch reason {
        case .missing: "missing"
        case .inTrash: "in Trash"
        case .corrupt: "corrupt"
        case .unsupportedSchema: "requires a newer Audora version"
        case .externalProcessingDisallowed:
            "not permitted for external Coach processing"
        }
    }

    @ViewBuilder
    private var admissionUnavailableReason: some View {
        if let reason = ChatInvocationAdmissionPresentation.unavailableReason(
            for: model.snapshot.admissionAvailability
        ) {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(reason)
        }
    }

    @ViewBuilder
    private var contextSummary: some View {
        switch model.snapshot.contextAdvisory {
        case let .available(quote):
            Text(CoachContextQuotePresentation.summary(quote))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "Estimated context, \(quote.completeInputTokens) of \(quote.inputCeilingTokens) input tokens"
                )
        case .quoting:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Estimating context capacity")
        case let .unavailable(reason):
            VStack(alignment: .leading, spacing: 4) {
                Text(CoachContextUnavailablePresentation.recoveryText(for: reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Refresh") { model.refreshContextQuote() }
                    .buttonStyle(.link)
                    .accessibilityLabel("Refresh context capacity")
            }
        case .messageTooLong:
            Text("Message too long")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Message exceeds the per-message Send limit")
        case .notRequested:
            EmptyView()
        }
    }

    @ViewBuilder
    private var contextDetails: some View {
        if case let .available(quote) = model.snapshot.contextAdvisory {
            DisclosureGroup("Context details") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(CoachContextCostCategory.allCases, id: \.self) { category in
                        if let cost = quote.categoryCosts[category] {
                            HStack {
                                Text(CoachContextQuotePresentation.categoryLabel(category))
                                Spacer()
                                Text("~\(cost.estimatedTokenCount) tokens")
                                    .monospacedDigit()
                            }
                        }
                    }
                    Text(
                        "Category estimates explain usage. The complete request total is authoritative and may differ from their sum."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .accessibilityLabel("Context cost categories")
        }
    }

    private var sendIsContextEligible: Bool {
        switch model.snapshot.contextAdvisory {
        case let .available(quote):
            if case .mustShorten = quote.messageLength { return false }
            return true
        case .notRequested, .quoting, .messageTooLong, .unavailable:
            return false
        }
    }

    private var messageNeedsShortening: Bool {
        switch model.snapshot.contextAdvisory {
        case .messageTooLong:
            true
        case let .available(quote):
            if case .mustShorten = quote.messageLength { true } else { false }
        case .notRequested, .quoting, .unavailable:
            false
        }
    }

}
