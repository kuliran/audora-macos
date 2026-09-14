import AudoraApplication
import AudoraDomain
import Foundation
import SwiftUI

public struct LibraryCatalogView: View {
    @ObservedObject private var model: LibraryCatalogPresentationModel
    @State private var catalogSearchText = ""
    @State private var selectedActiveSessionIDs: Set<SessionID> = []

    public init(model: LibraryCatalogPresentationModel) {
        self.model = model
    }

    public var body: some View {
        GroupBox("Library Contents") {
            VStack(alignment: .leading, spacing: 10) {
                content

                if let activity = model.state.activity {
                    ProgressView(activityLabel(activity))
                        .controlSize(.small)
                        .accessibilityLabel(activityAccessibilityLabel(activity))
                }

                if let notice = model.state.mutationNotice {
                    Text(LibraryCatalogMutationNoticeFormatter.text(for: notice))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            "Library contents notice: " +
                                LibraryCatalogMutationNoticeFormatter.text(
                                    for: notice
                                )
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
        .onChange(of: model.state.scope) { _, _ in
            catalogSearchText = ""
            selectedActiveSessionIDs = []
        }
        .onChange(of: activeSessionIDs) { _, activeSessionIDs in
            selectedActiveSessionIDs.formIntersection(activeSessionIDs)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state.availability {
        case .inactive:
            Text("Open a Library to view its contents.")
                .foregroundStyle(.secondary)
        case .loading:
            ProgressView("Loading Library contents…")
        case .available:
            if let catalog = model.state.catalog {
                available(catalog)
            }
        case .readOnly:
            unavailable(
                "Library contents cannot be changed while this Library is read-only."
            )
        case .unavailable:
            unavailable(
                "Library contents are unavailable. Reopen the Library and try again."
            )
        case .integrityMismatch:
            unavailable(
                "Library contents could not be verified. Refresh before making another change."
            )
        }
    }

    private func available(_ catalog: LibraryCatalogSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Active · \(catalog.active.count)    Trash · \(catalog.trash.count)")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)
                .accessibilityLabel("Refresh Library contents")
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Active Sessions · \(activeSessionRows.count)")
                        .font(.subheadline.weight(.semibold))
                    SessionMultiSelectionShell(
                        searchText: $catalogSearchText,
                        searchPrompt: "Search Library Contents",
                        searchAccessibilityLabel:
                            "Search active and Trash Library contents",
                        rows: filteredActiveSessionRows.compactMap { row in
                            guard let sessionID = sessionID(in: row) else {
                                return nil
                            }
                            let presentation = LibraryCatalogRowPresentation(
                                row: row
                            )
                            return SessionMultiSelectionRow(
                                id: sessionID,
                                title: presentation.title,
                                metadata: presentation.metadata,
                                accessibilityLabel:
                                    presentation.accessibilityLabel
                            )
                        },
                        hasAnyRows: !activeSessionRows.isEmpty,
                        selectedIDs: selectedActiveSessionIDs,
                        controlsEnabled: !model.isBusy
                    ) { sessionID in
                        if selectedActiveSessionIDs.contains(sessionID) {
                            selectedActiveSessionIDs.remove(sessionID)
                        } else {
                            selectedActiveSessionIDs.insert(sessionID)
                        }
                    }
                    .frame(minHeight: 92, maxHeight: 154)

                    HStack {
                        Text("\(selectedActiveSessionIDs.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            let aggregates = Set(
                                selectedActiveSessionIDs.map(
                                    LibraryAggregate.session
                                )
                            )
                            Task { await model.moveToTrash(aggregates) }
                        } label: {
                            Label("Move Selected", systemImage: "trash")
                        }
                        .disabled(
                            selectedActiveSessionIDs.isEmpty || model.isBusy
                        )
                        .accessibilityLabel(
                            "Move \(selectedActiveSessionIDs.count) selected " +
                                "Sessions to Trash"
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Active Chats · \(activeChatRows.count)")
                        .font(.subheadline.weight(.semibold))
                    aggregateList(
                        filteredActiveChatRows,
                        emptyText: "No active Chats.",
                        actionLabel: "Move to Trash",
                        actionSystemImage: "trash"
                    ) { aggregate in
                        await model.moveToTrash(aggregate)
                    }

                    Divider()

                    Text("Trash · \(catalog.trash.count)")
                        .font(.subheadline.weight(.semibold))
                    aggregateList(
                        filteredTrashRows,
                        emptyText: "Trash is empty.",
                        actionLabel: "Restore",
                        actionSystemImage: "arrow.uturn.backward"
                    ) { aggregate in
                        await model.restore(aggregate)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func aggregateList(
        _ rows: [LibraryCatalogRow],
        emptyText: String,
        actionLabel: String,
        actionSystemImage: String,
        action: @escaping (LibraryAggregate) async -> Void
    ) -> some View {
        Group {
            if rows.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(rows, id: \.aggregate) { row in
                            aggregateRow(
                                row,
                                actionLabel: actionLabel,
                                actionSystemImage: actionSystemImage,
                                action: action
                            )
                        }
                    }
                }
                .frame(maxHeight: 132)
            }
        }
    }

    private var activeSessionRows: [LibraryCatalogRow] {
        guard let active = model.state.catalog?.active else { return [] }
        return active.filter { row in
            if case .session = row.aggregate { return true }
            return false
        }
    }

    private var activeSessionIDs: [SessionID] {
        activeSessionRows.compactMap { sessionID(in: $0) }
    }

    private var filteredActiveSessionRows: [LibraryCatalogRow] {
        filtered(activeSessionRows)
    }

    private var activeChatRows: [LibraryCatalogRow] {
        model.state.catalog?.active.filter { row in
            if case .chat = row.aggregate { return true }
            return false
        } ?? []
    }

    private var filteredActiveChatRows: [LibraryCatalogRow] {
        filtered(activeChatRows)
    }

    private var filteredTrashRows: [LibraryCatalogRow] {
        filtered(model.state.catalog?.trash ?? [])
    }

    private func aggregateRow(
        _ row: LibraryCatalogRow,
        actionLabel: String,
        actionSystemImage: String,
        action: @escaping (LibraryAggregate) async -> Void
    ) -> some View {
        let aggregate = row.aggregate
        let presentation = LibraryCatalogRowPresentation(row: row)
        return HStack(spacing: 10) {
            Label(aggregateKind(aggregate), systemImage: aggregateSystemImage(aggregate))
                .font(.callout.weight(.semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .lineLimit(1)
                Text(presentation.metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                Task { await action(aggregate) }
            } label: {
                Label(actionLabel, systemImage: actionSystemImage)
            }
            .disabled(model.isBusy)
            .accessibilityLabel(
                "\(actionLabel) \(presentation.accessibilityLabel)"
            )
        }
    }

    private func unavailable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Try Again") {
                Task { await model.refresh() }
            }
            .disabled(model.isBusy)
            .accessibilityLabel("Reload Library contents")
        }
    }

    private func aggregateKind(_ aggregate: LibraryAggregate) -> String {
        switch aggregate {
        case .session: "Session"
        case .chat: "Chat"
        }
    }

    private func aggregateSystemImage(_ aggregate: LibraryAggregate) -> String {
        switch aggregate {
        case .session: "waveform"
        case .chat: "bubble.left.and.bubble.right"
        }
    }

    private func sessionID(in row: LibraryCatalogRow) -> SessionID? {
        guard case let .session(sessionID) = row.aggregate else { return nil }
        return sessionID
    }

    private func filtered(_ rows: [LibraryCatalogRow]) -> [LibraryCatalogRow] {
        return rows.filter { row in
            LibraryCatalogRowPresentation(row: row).matches(catalogSearchText)
        }
    }

    private func activityLabel(
        _ activity: LibraryCatalogPresentationState.Activity
    ) -> String {
        switch activity {
        case .refreshing: "Refreshing Library contents…"
        case .movingToTrash: "Moving item to Trash…"
        case .restoring: "Restoring item…"
        }
    }

    private func activityAccessibilityLabel(
        _ activity: LibraryCatalogPresentationState.Activity
    ) -> String {
        switch activity {
        case .refreshing: "Refreshing Library contents"
        case .movingToTrash: "Moving Library item to Trash"
        case .restoring: "Restoring Library item from Trash"
        }
    }

}
