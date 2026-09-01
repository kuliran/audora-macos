import AudoraApplication
import AudoraDomain
import Foundation
import SwiftUI

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
        case .attachmentCatalogFailed: "Sessions could not be loaded for Chat creation."
        case .qualifiedCoachConfigurationUnavailable:
            "No qualified Coach configuration is available. Install an Audora update with a qualified configuration before creating a Chat."
        }
    }

    static func accessibilityLabel(for notice: ChatNotice) -> String {
        "Chat notice: \(recoveryText(for: notice))"
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

public struct ChatRootView: View {
    @StateObject private var model: ChatPresentationModel
    @ObservedObject private var dispatcher: ChatCommandDispatcher
    @State private var renameTitle = ""
    private let scope: LibraryScope

    public init(dispatcher: ChatCommandDispatcher, scope: LibraryScope) {
        _model = StateObject(wrappedValue: ChatPresentationModel(dispatcher: dispatcher))
        _dispatcher = ObservedObject(wrappedValue: dispatcher)
        self.scope = scope
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
        .task { await model.start(in: scope) }
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
                    Button {
                        model.open(row.chatID)
                    } label: {
                        HStack {
                            Text(row.title?.rawValue ?? "Unavailable Chat")
                            Spacer()
                            if case .frozen = row.availability {
                                Image(systemName: "lock.fill")
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        row.title.map { "Open Chat, \($0.rawValue)" }
                            ?? "Open unavailable Chat"
                    )
                    .disabled(!allowsNavigationAndMutation)
                }
                .listStyle(.sidebar)
            }
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
                    } else {
                        Text("\(aggregate.chat.messageIDs.count) completed messages")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                composerView
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
                    .disabled(!allowsNavigationAndMutation)

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
                            .disabled(
                                !allowsNavigationAndMutation ||
                                    !sendIsContextEligible ||
                                    !draft.text.unicodeScalars.contains {
                                        !$0.properties.isWhitespace
                                    }
                            )
                    }
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
                    if pending.failure == .coachContextCannotFit {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Chat size exceeded. Please create a new one.")
                                .font(.callout.weight(.semibold))
                                .accessibilityLabel(
                                    "Chat size exceeded. Please create a new one."
                                )
                            contextDetails
                            HStack {
                                Button("Retry") {
                                    model.retryPendingUserTurn(pending.id)
                                }
                                .accessibilityLabel("Retry Pending User Turn")
                                Button("Discard") {
                                    model.discardPendingUserTurn(pending.id)
                                }
                                .accessibilityLabel("Discard Pending User Turn")
                                Button("Create New Chat") {
                                    model.createNewChatFromCapacityFailure(pending.id)
                                }
                                .accessibilityLabel(
                                    "Create New Chat from capacity failure"
                                )
                            }
                            .disabled(!allowsNavigationAndMutation)
                        }
                    } else {
                        HStack {
                            Spacer()
                            Button("Discard") {
                                model.discardPendingUserTurn(pending.id)
                            }
                            .accessibilityLabel("Discard Pending User Turn")
                            .disabled(!allowsNavigationAndMutation)
                        }
                    }
                }
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var activityView: some View {
        switch model.snapshot.activity {
        case .creating:
            ProgressView("Creating Chat…")
        case .renaming:
            ProgressView("Renaming Chat…")
        case .lockingDraft:
            ProgressView("Preparing Draft…")
        case .retryingPendingUserTurn:
            ProgressView("Rechecking Chat capacity…")
        case .discardingPendingUserTurn:
            ProgressView("Unlocking Draft…")
        case nil:
            EmptyView()
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

            switch model.snapshot.newChatPicker {
            case .closed:
                EmptyView()
            case .loading:
                VStack {
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
                if picker.visibleRows.isEmpty {
                    ContentUnavailableView(
                        picker.allRows.isEmpty ? "No Sessions" : "No Matching Sessions",
                        systemImage: "waveform"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(picker.visibleRows) { row in
                        Button {
                            model.performNewChatAttachmentPickerAction(.toggle(row.id))
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(
                                    systemName: picker.selectedAttachmentIDs.contains(row.id)
                                        ? "checkmark.circle.fill"
                                        : "circle"
                                )
                                .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.displayLabel)
                                    HStack(spacing: 12) {
                                        Text(Self.durationText(row.durationMilliseconds))
                                        Text("~\(row.approximateTranscriptTokens) tokens")
                                        Text(row.delivery == .inline ? "Inline" : "On demand")
                                    }
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(picker.selectedAttachmentIDs.contains(row.id) ? "Selected" : "Not selected"), \(row.displayLabel), \(Self.durationText(row.durationMilliseconds)), approximately \(row.approximateTranscriptTokens) transcript tokens, \(row.delivery == .inline ? "inline" : "on demand")"
                        )
                    }
                    .disabled(!newChatSheetInteractionPresentation.allowsControlInteraction)
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
            VStack(alignment: .leading, spacing: 4) {
                Text(CoachContextQuotePresentation.summary(quote.context))
                    .font(.callout.monospacedDigit())
                if let profile = quote.context.categoryCosts[.profile] {
                    Text("Current Profile: ~\(profile.estimatedTokenCount) tokens")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        case .providerUnavailable:
            Text(NewChatAttachmentPickerPresentation.providerUnavailableRecoveryText)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unavailable:
            EmptyView()
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
        case .unavailable:
            HStack(spacing: 4) {
                Text("Capacity unavailable")
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
