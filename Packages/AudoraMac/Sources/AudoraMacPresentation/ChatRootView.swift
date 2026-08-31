import AudoraApplication
import AudoraDomain
import SwiftUI

struct ChatRenameEditorTaskID: Hashable {
    let chatID: ChatID
    let manifestRevision: UInt64
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
        }
    }

    static func accessibilityLabel(for notice: ChatNotice) -> String {
        "Chat notice: \(recoveryText(for: notice))"
    }
}

public struct ChatRootView: View {
    @StateObject private var model: ChatPresentationModel
    @State private var renameTitle = ""
    private let scope: LibraryScope

    public init(feature: any ChatFeature, scope: LibraryScope) {
        _model = StateObject(wrappedValue: ChatPresentationModel(feature: feature))
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
                        model.createDevelopmentChat()
                    }
                    .accessibilityLabel("Create New Development Chat")
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
                Text("No Sessions attached")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Chat attachments: No Sessions attached")
                ContentUnavailableView(
                    "Start a reflection",
                    systemImage: "text.bubble",
                    description: Text("Write a thought when you are ready. Nothing is sent automatically.")
                )
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
    private var activityView: some View {
        switch model.snapshot.activity {
        case .creating:
            ProgressView("Creating Chat…")
        case .renaming:
            ProgressView("Renaming Chat…")
        case nil:
            EmptyView()
        }
    }

    private var allowsNavigationAndMutation: Bool {
        ChatInteractionPolicy.allowsNavigationAndMutation(in: model.snapshot)
    }

}
