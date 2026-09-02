import AppKit
@_spi(InvocationInfrastructure) @_spi(CoachContextQualification) import AudoraApplication
@_spi(InvocationInfrastructure) @_spi(CoachContextQualification) import AudoraMacInfrastructure
import AudoraMacPresentation
import SwiftUI

@main
struct AudoraApp: App {
    @NSApplicationDelegateAdaptor(AudoraAppDelegate.self)
    private var appDelegate

    private let workspace: PortableLibraryWorkspace
    private let feature: DefaultLibraryFeature
    private let audioImportFeature: DefaultAudioImportFeature
    private let recordingFeature: DefaultRecordingFeature
    private let reviewFeature: DefaultReviewFeature
    private let applicationCommands: DefaultApplicationCommandFeature
    private let chatDispatcher: ChatCommandDispatcher
    private let librarySelectionDispatcher: LibrarySelectionCommandDispatcher
    private let windowCoordinator: MainWindowCoordinator

    init() {
        let locatorStore = MachineLibraryLocatorFactory.live()
        let access = SecurityScopedLibraryAccessGrantor()
        let workspace = PortableLibraryWorkspace(
            locations: AppKitLibraryLocationChooser(),
            bookmarks: SecurityScopedLibraryBookmarks(),
            access: access,
            locatorStore: locatorStore,
            revealer: NSWorkspaceLibraryRevealer()
        )
        let activityCoordinator = LibraryActivityCoordinator()
        let feature = DefaultLibraryFeature(
            workspace: workspace,
            clock: SystemLibraryClock(),
            idGenerator: RandomLibraryIDGenerator(),
            activityCoordinator: activityCoordinator
        )
        let recordingCapture = AVFoundationAudioCaptureAdapter(
            roots: workspace,
            sources: AVFoundationMicrophoneInputSourceFactory()
        )
        let recordingFeature = DefaultRecordingFeature(
            capture: recordingCapture,
            clock: SystemRecordingClock(),
            idGenerator: RandomRecordingIDGenerator(),
            activity: activityCoordinator
        )
        let processingWorkspace = PortableSessionProcessingWorkspace(scopes: workspace)
        let transcriptionRuntime = CrisperPinnedQualificationRuntime()
        let transcriptionModel = PinnedLocalTranscriptionModelRepository(
            root: PinnedLocalTranscriptionModelRepository.defaultInstalledRoot()
        )
        let sessionProcessingFeature = DefaultSessionProcessingFeature(
            source: processingWorkspace,
            runtime: transcriptionRuntime,
            model: transcriptionModel,
            acoustics: QualificationBlockedSessionAcousticEvidence(),
            jobs: processingWorkspace,
            engine: ConfinedJSONLTranscriptionEngine(
                host: QualificationBlockedTranscriptionWorkerHost(),
                audio: processingWorkspace,
                runtime: transcriptionRuntime,
                model: transcriptionModel
            ),
            publisher: TranscriptRevisionPublisher(repository: processingWorkspace),
            clock: SystemLibraryClock(),
            identifiers: RandomSessionProcessingIDGenerator()
        )
        let reviewWorkspace = PortableReviewWorkspace(scopes: workspace)
        let audioImportWorkspace = PortableAudioImportWorkspace(
            workspace: workspace,
            chooser: AppKitAudioFileChooser(),
            sourceAccess: access
        )
        let audioImportFeature = DefaultAudioImportFeature(
            port: audioImportWorkspace,
            clock: SystemLibraryClock(),
            sessionIDGenerator: RandomSessionIDGenerator(),
            activityCoordinator: activityCoordinator
        )
        let chatIdentityGenerator = RandomChatIdentityGenerator()
        let retryDiagnostics = MachineInvocationRetryDiagnosticsFactory.live()
        let retryDiagnosticClock = SystemInvocationRetryDiagnosticClock()
        let chatPersistence = PortableChatPersistence(
            retryDiagnostics: retryDiagnostics,
            retryDiagnosticNow: { retryDiagnosticClock.now() }
        )
        let chatStore = PortableChatStore(
            persistence: chatPersistence,
            workspace: workspace
        )
        let invocations = DefaultInvocations(
            persistence: PortableInvocationStore(
                persistence: chatPersistence,
                workspace: workspace
            ),
            admission: MachineInvocationAdmissionFactory.live(),
            clock: SystemLibraryClock(),
            identities: RandomInvocationIdentityGenerator(),
            retryDiagnostics: retryDiagnostics
        )
        let chatFeature = DefaultChatFeature(
            store: chatStore,
            profileReader: ActiveLibraryProfileStatementGenerationReader(
                workspace: workspace
            ),
            clock: SystemLibraryClock(),
            chatIDGenerator: chatIdentityGenerator,
            draftIDGenerator: chatIdentityGenerator,
            memoryIDGenerator: chatIdentityGenerator,
            pendingUserTurnIDGenerator: chatIdentityGenerator,
            responsePositionIDGenerator: chatIdentityGenerator,
            admissionRefreshScheduler: SystemChatAdmissionRefreshScheduler(),
            invocations: invocations,
            attachmentEvidenceSource:
                PortableChatSessionAttachmentSource(workspace: workspace)
        )
        let applicationCommands = DefaultApplicationCommandFeature(
            library: feature,
            chat: chatFeature,
            sessionProcessing: sessionProcessingFeature
        )
        let reviewFeature = DefaultReviewFeature(
            sessions: reviewWorkspace,
            playback: AVFoundationReviewPlaybackAdapter(resolver: reviewWorkspace),
            retranscriber: SessionProcessingReviewRetranscriber(
                feature: applicationCommands
            ),
            annotationVisibility: workspace
        )
        let chatDispatcher = ChatCommandDispatcher(feature: applicationCommands)
        let librarySelectionDispatcher = LibrarySelectionCommandDispatcher(
            commandDispatcher: chatDispatcher
        )
        let windowCoordinator = MainWindowCoordinator(
            access: AppKitMainWindowAccess()
        )
        self.workspace = workspace
        self.feature = feature
        self.audioImportFeature = audioImportFeature
        self.recordingFeature = recordingFeature
        self.reviewFeature = reviewFeature
        self.applicationCommands = applicationCommands
        self.chatDispatcher = chatDispatcher
        self.librarySelectionDispatcher = librarySelectionDispatcher
        self.windowCoordinator = windowCoordinator
        appDelegate.configure(
            feature: feature,
            applicationCommands: applicationCommands,
            librarySelectionDispatcher: librarySelectionDispatcher,
            workspace: workspace,
            windowCoordinator: windowCoordinator
        )
    }

    var body: some Scene {
        Window("Audora", id: "library") {
            LibraryRootView(
                feature: feature,
                audioImportFeature: audioImportFeature,
                recordingFeature: recordingFeature,
                sessionProcessingFeature: applicationCommands,
                reviewFeature: reviewFeature,
                chatDispatcher: chatDispatcher,
                librarySelectionDispatcher: librarySelectionDispatcher,
                windowCoordinator: windowCoordinator
            )
        }
        .defaultSize(width: 980, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

@MainActor
final class AudoraAppDelegate: NSObject, NSApplicationDelegate {
    private var feature: DefaultLibraryFeature?
    private var applicationCommands: (any ApplicationCommandFeature)?
    private var librarySelectionDispatcher: LibrarySelectionCommandDispatcher?
    private var workspace: PortableLibraryWorkspace?
    private var windowCoordinator: MainWindowCoordinator?
    private var terminationTask: Task<Void, Never>?

    func configure(
        feature: DefaultLibraryFeature,
        applicationCommands: any ApplicationCommandFeature,
        librarySelectionDispatcher: LibrarySelectionCommandDispatcher,
        workspace: PortableLibraryWorkspace,
        windowCoordinator: MainWindowCoordinator
    ) {
        self.feature = feature
        self.applicationCommands = applicationCommands
        self.librarySelectionDispatcher = librarySelectionDispatcher
        self.workspace = workspace
        self.windowCoordinator = windowCoordinator
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let feature, let librarySelectionDispatcher, let workspace else { return }
        guard urls.count == 1, let url = urls.first else {
            Task {
                await feature.send(.rejectMultipleExternalOpenRequests)
                windowCoordinator?.focusExistingMainWindow()
            }
            return
        }

        Task {
            let token = await workspace.registerExternalOpenRequest(url)
            // A busy feature keeps this send suspended until the request is
            // replayed or superseded, so revocation cannot invalidate a queued
            // token. The workspace consumes accepted tokens and bounds pending
            // capabilities to one; this final revoke covers every other exit.
            _ = await librarySelectionDispatcher.sendAndWait(.openExternal(token))
            await workspace.revokeExternalOpenRequest(token)
            windowCoordinator?.focusExistingMainWindow()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        windowCoordinator?.focusExistingMainWindow()
        return true
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let applicationCommands else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { @MainActor [weak self] in
            let termination = applicationCommands.flushForOrderlyTermination()
            let draftIsDurable = await termination.value
            self?.terminationTask = nil
            sender.reply(toApplicationShouldTerminate: draftIsDurable)
        }
        return .terminateLater
    }
}
