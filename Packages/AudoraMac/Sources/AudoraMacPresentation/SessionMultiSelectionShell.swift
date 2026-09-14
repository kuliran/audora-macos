import SwiftUI

struct SessionMultiSelectionRow<SelectionID: Hashable>: Identifiable {
    let id: SelectionID
    let title: String
    let metadata: String?
    let accessibilityLabel: String
}

/// The shared searchable, keyboard-navigable Session selection shell used by
/// both Chat creation and batch Move to Trash. Callers own their typed
/// selection and decide which Application command confirmation sends.
struct SessionMultiSelectionShell<SelectionID: Hashable>: View {
    let searchText: Binding<String>
    let searchPrompt: String
    let searchAccessibilityLabel: String
    let rows: [SessionMultiSelectionRow<SelectionID>]
    let hasAnyRows: Bool
    let selectedIDs: Set<SelectionID>
    let controlsEnabled: Bool
    let toggle: (SelectionID) -> Void

    init(
        searchText: Binding<String>,
        searchPrompt: String = "Search Sessions",
        searchAccessibilityLabel: String,
        rows: [SessionMultiSelectionRow<SelectionID>],
        hasAnyRows: Bool,
        selectedIDs: Set<SelectionID>,
        controlsEnabled: Bool,
        toggle: @escaping (SelectionID) -> Void
    ) {
        self.searchText = searchText
        self.searchPrompt = searchPrompt
        self.searchAccessibilityLabel = searchAccessibilityLabel
        self.rows = rows
        self.hasAnyRows = hasAnyRows
        self.selectedIDs = selectedIDs
        self.controlsEnabled = controlsEnabled
        self.toggle = toggle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(searchPrompt, text: searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(searchAccessibilityLabel)
                .disabled(!controlsEnabled)

            if rows.isEmpty {
                ContentUnavailableView(
                    hasAnyRows ? "No Matching Sessions" : "No Sessions",
                    systemImage: "waveform"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { row in
                    Button {
                        toggle(row.id)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(
                                systemName: selectedIDs.contains(row.id)
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                            .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.title)
                                if let metadata = row.metadata {
                                    Text(metadata)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "\(selectedIDs.contains(row.id) ? "Selected" : "Not selected"), " +
                            row.accessibilityLabel
                    )
                }
                .disabled(!controlsEnabled)
            }
        }
    }
}
