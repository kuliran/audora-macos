import AudoraApplication
import AudoraDomain
import SwiftUI

public struct LibraryRootView: View {
    @StateObject private var model: LibraryPresentationModel
    @StateObject private var audioImportModel: AudioImportPresentationModel
    @StateObject private var recordingModel: RecordingPresentationModel
    @ObservedObject private var chatDispatcher: ChatCommandDispatcher
    @Environment(\.openWindow) private var openWindow
    private let librarySelectionDispatcher: LibrarySelectionCommandDispatcher
    private let windowCoordinator: MainWindowCoordinator

    public init(
        feature: any LibraryFeature,
        audioImportFeature: any AudioImportFeature,
        recordingFeature: any RecordingFeature,
        chatDispatcher: ChatCommandDispatcher,
        librarySelectionDispatcher: LibrarySelectionCommandDispatcher,
        windowCoordinator: MainWindowCoordinator
    ) {
        _model = StateObject(wrappedValue: LibraryPresentationModel(feature: feature))
        _audioImportModel = StateObject(
            wrappedValue: AudioImportPresentationModel(feature: audioImportFeature)
        )
        _recordingModel = StateObject(
            wrappedValue: RecordingPresentationModel(feature: recordingFeature)
        )
        _chatDispatcher = ObservedObject(wrappedValue: chatDispatcher)
        self.librarySelectionDispatcher = librarySelectionDispatcher
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
                audioImportActions
                    .disabled(!interactionAvailability.canUseAudioImportControls)
                RecordingView(model: recordingModel)
                    .disabled(!interactionAvailability.canUseRecordingControls)
                Divider()
                ChatRootView(
                    dispatcher: chatDispatcher,
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
        .disabled(
            model.snapshot?.activity != nil ||
                chatDispatcher.isLibraryNavigationPending
        )
        .task {
            windowCoordinator.registerReopenAction {
                openWindow(id: "library")
            }
            await model.start()
        }
        .task {
            await audioImportModel.start()
        }
        .task {
            await recordingModel.start()
        }
        .onChange(of: activeLibraryID) {
            audioImportModel.send(.clearResult)
        }
        .onChange(of: model.snapshot?.selection, initial: true) { _, selection in
            switch selection {
            case let .active(library):
                recordingModel.selectLibrary(
                    .writable(LibraryScope(libraryID: library.libraryID))
                )
            case .readOnly:
                recordingModel.selectLibrary(.readOnly)
            case .awaitingBootstrap, .noLibrarySelected, nil:
                recordingModel.selectLibrary(.none)
            }
        }
    }

    private var libraryActions: some View {
        HStack {
            Button("Reveal Library") { model.send(.reveal) }
                .disabled(!interactionAvailability.canRevealLibrary)
            Button("Choose Another…") {
                librarySelectionDispatcher.enqueue(.chooseExisting)
            }
                .disabled(!interactionAvailability.canMutateLibrarySelection)
            Button("Close Library") {
                librarySelectionDispatcher.enqueue(.close)
            }
                .disabled(!interactionAvailability.canMutateLibrarySelection)
        }
    }

    @ViewBuilder
    private var audioImportActions: some View {
        switch audioImportModel.snapshot?.status {
        case nil, .some(.idle):
            Button("Import Audio…") { audioImportModel.send(.chooseAudio) }
                .disabled(model.snapshot?.activity != nil)

        case let .some(.succeeded(snapshot)):
            VStack(spacing: 8) {
                Text("Audio imported")
                    .font(.headline)
                Text(snapshot.session.sessionID.rawValue)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button("Import Another…") { audioImportModel.restart() }
            }

        case let .some(.failed(failure)):
            VStack(spacing: 8) {
                Text(audioImportFailureText(failure))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Try Again") { audioImportModel.restart() }
                    Button("Dismiss") { audioImportModel.send(.clearResult) }
                }
            }

        case let .some(status):
            VStack(spacing: 8) {
                ProgressView(audioImportActivityText(status))
                Button("Cancel") { audioImportModel.send(.cancelImport) }
            }
        }
    }

    private var activeLibraryID: String? {
        guard case let .active(library) = model.snapshot?.selection else { return nil }
        return library.libraryID.rawValue
    }

    private var interactionAvailability: LibraryInteractionAvailability {
        LibraryInteractionPolicy.availability(
            library: model.snapshot,
            audioImport: audioImportModel.snapshot,
            recording: recordingModel.featureState
        )
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
        case .libraryActivityInProgress: "Finish the current Library activity before changing Libraries."
        case .multipleExternalOpenRequests: "Open one Library at a time."
        case .externalOpenRequestExpired: "That open request is no longer available."
        }
    }

    private func audioImportActivityText(
        _ status: AudioImportFeatureState.Status
    ) -> String {
        switch status {
        case .selecting: "Selecting audio…"
        case .copying: "Copying original audio…"
        case .inspecting: "Checking audio…"
        case .normalizing: "Creating canonical audio…"
        case .installing: "Installing Session…"
        case .idle, .succeeded, .failed: "Importing audio…"
        }
    }

    private func audioImportFailureText(_ failure: AudioImportFailure) -> String {
        switch failure {
        case .anotherLibraryActivity: "Finish the current Library activity before importing audio."
        case .cancelled: "Audio import was cancelled."
        case .unsupportedMedia: "Choose a supported mono or stereo M4A or WAV file."
        case .sourceTooLarge: "The selected audio file is too large to import."
        case .durationExceeded: "Audio must be 45 minutes or shorter."
        case .malformedMedia, .decodeFailed: "The selected audio could not be decoded."
        case .nonfiniteSamples: "The decoded audio contains invalid samples."
        case .insufficientSpace: "There is not enough space in the Library."
        case .sourceChanged: "The selected audio changed while it was being copied."
        case .libraryChanged: "The active Library changed before import completed."
        case .destinationCollision: "A Session with this identity already exists."
        case .installedNeedsRefresh: "The Session was installed. Reopen the Library to refresh it."
        case .candidateCorrupt, .writeFailed, .unavailable: "Audio import could not be completed."
        }
    }
}
