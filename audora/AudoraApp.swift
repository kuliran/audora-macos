import AppKit
import AudoraApplication
import AudoraMacInfrastructure
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
        let windowCoordinator = MainWindowCoordinator(
            access: AppKitMainWindowAccess()
        )
        self.workspace = workspace
        self.feature = feature
        self.audioImportFeature = audioImportFeature
        self.recordingFeature = recordingFeature
        self.windowCoordinator = windowCoordinator
        appDelegate.configure(
            feature: feature,
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
                windowCoordinator: windowCoordinator
            )
        }
        .defaultSize(width: 720, height: 480)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

@MainActor
final class AudoraAppDelegate: NSObject, NSApplicationDelegate {
    private var feature: DefaultLibraryFeature?
    private var workspace: PortableLibraryWorkspace?
    private var windowCoordinator: MainWindowCoordinator?

    func configure(
        feature: DefaultLibraryFeature,
        workspace: PortableLibraryWorkspace,
        windowCoordinator: MainWindowCoordinator
    ) {
        self.feature = feature
        self.workspace = workspace
        self.windowCoordinator = windowCoordinator
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let feature, let workspace else { return }
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
            await feature.send(.openExternal(token))
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
}
