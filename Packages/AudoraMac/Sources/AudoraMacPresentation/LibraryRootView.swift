import AudoraApplication
import AudoraDomain
import SwiftUI

public struct LibraryRootView: View {
    @StateObject private var model: LibraryPresentationModel
    @Environment(\.openWindow) private var openWindow
    private let chatFeature: any ChatFeature
    private let windowCoordinator: MainWindowCoordinator

    public init(
        feature: any LibraryFeature,
        chatFeature: any ChatFeature,
        windowCoordinator: MainWindowCoordinator
    ) {
        _model = StateObject(wrappedValue: LibraryPresentationModel(feature: feature))
        self.chatFeature = chatFeature
        self.windowCoordinator = windowCoordinator
    }

    public var body: some View {
        VStack(spacing: 18) {
            switch model.snapshot?.selection {
            case nil, .some(.awaitingBootstrap):
                ProgressView("Preparing Audora…")
                    .controlSize(.large)

            case let .some(.noLibrarySelected(recentAvailable)):
                ContentUnavailableView(
                    "No Library Selected",
                    systemImage: "waveform",
                    description: Text(
                        "Create a portable Library or choose an existing one."
                    )
                )
                HStack {
                    Button("Create Library") { model.send(.create) }
                    Button("Choose Library…") { model.send(.chooseExisting) }
                    if recentAvailable {
                        Button("Reopen Recent") { model.send(.reopenRecent) }
                    }
                }

            case let .some(.active(library)):
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)
                Text("Library Ready")
                    .font(.title2.weight(.semibold))
                Text(library.libraryID.rawValue)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text(profileDescription(library.profile))
                    .foregroundStyle(.secondary)
                libraryActions
                Divider()
                ChatRootView(
                    feature: chatFeature,
                    scope: LibraryScope(libraryID: library.libraryID)
                )
                .id(library.libraryID.rawValue)

            case .some(.readOnly):
                ContentUnavailableView(
                    "Library Is Read-Only",
                    systemImage: "lock.doc",
                    description: Text(
                        "This Library uses a newer schema. Audora will not modify it."
                    )
                )
                libraryActions
            }

            if let notice = model.snapshot?.notice {
                Text(noticeText(notice))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Library notice: \(noticeText(notice))")
            }

            if let activity = model.snapshot?.activity {
                ProgressView(activityText(activity))
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .padding(32)
        .disabled(model.snapshot?.activity != nil)
        .task {
            windowCoordinator.registerReopenAction {
                openWindow(id: "library")
            }
            await model.start()
        }
    }

    private var libraryActions: some View {
        HStack {
            Button("Reveal Library") { model.send(.reveal) }
            Button("Choose Another…") { model.send(.chooseExisting) }
            Button("Close Library") { model.send(.close) }
        }
    }

    private func profileDescription(_ profile: ActiveLibrarySnapshot.ProfileSummary) -> String {
        switch profile {
        case let .nullProfile(statementCount):
            "Development Profile · \(statementCount) statements"
        case let .selected(_, statementGeneration):
            "Development Profile · generation \(statementGeneration)"
        }
    }

    private func activityText(_ activity: LibraryFeatureState.Activity) -> String {
        switch activity {
        case .restoring: "Restoring Library…"
        case .creating: "Creating Library…"
        case .opening: "Opening Library…"
        case .revealing: "Revealing Library…"
        case .closing: "Closing Library…"
        }
    }

    private func noticeText(_ notice: LibraryNotice) -> String {
        switch notice {
        case .candidateCorrupt: "The selected Library is not valid."
        case .candidateUnavailable: "The Library is unavailable. Select it again."
        case .identityMismatch: "The recent location no longer contains the same Library."
        case .unsupportedOlderSchema: "This older Library schema is not supported."
        case .selectionRequired: "Select the Library again."
        case .createDestinationExists: "A Library already exists at that destination."
        case .createFailed: "The Library could not be created."
        case .locatorUpdateFailed: "The Library is open, but it may need to be selected again later."
        case .revealFailed: "The Library could not be revealed."
        case .closeFailed: "The Library could not be closed safely."
        case .multipleExternalOpenRequests: "Open one Library at a time."
        case .externalOpenRequestExpired: "That open request is no longer available."
        }
    }
}
