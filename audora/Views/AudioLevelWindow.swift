import SwiftUI

// MARK: - Logo Audio Visualizer
struct LogoAudioVisualizer: View {
    let micLevel: Float
    let systemLevel: Float

    var body: some View {
        let maxLevel = max(micLevel, systemLevel)
        let scale: CGFloat = maxLevel > 0.05 ? 1.0 + CGFloat(maxLevel) * 0.15 : 1.0

        Image("Icon32")
            .resizable()
            .scaledToFit()
            .frame(width: 32, height: 32)
            .scaleEffect(scale)
            .animation(.easeInOut(duration: 0.1), value: scale)
            .padding(4)
    }
}

// MARK: - Audio Level Window View
struct AudioLevelWindowView: View {
    @StateObject private var audioLevelManager = AudioLevelManager.shared

    var body: some View {
        let micLevel = audioLevelManager.isRecording ? audioLevelManager.micAudioLevel * 30 : 0
        let systemLevel = audioLevelManager.isRecording ? audioLevelManager.systemAudioLevel * 5 : 0
        return LogoAudioVisualizer(
                micLevel: micLevel,
                systemLevel: systemLevel
            )
            .padding(2)
            .background(.regularMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.2), radius: 3)
    }
}

// MARK: - Audio Level Manager (Singleton to share data)
@MainActor
class AudioLevelManager: ObservableObject {
    static let shared = AudioLevelManager()

    @Published var micAudioLevel: Float = 0.0
    @Published var systemAudioLevel: Float = 0.0
    @Published var isRecording: Bool = false

    private init() {}

    func updateMicLevel(_ level: Float) {
        DispatchQueue.main.async {
            self.micAudioLevel = level
        }
    }

    func updateSystemLevel(_ level: Float) {
        DispatchQueue.main.async {
            self.systemAudioLevel = level
        }
    }

    func updateRecordingState(_ isRecording: Bool) {
        DispatchQueue.main.async {
            self.isRecording = isRecording
            if isRecording {
                // Check setting before showing
                if UserDefaultsManager.shared.showLiveMeetingIndicator {
                    AudioLevelWindowManager.shared.showWindow()
                }
            } else {
                // Auto-hide the window when recording stops
                AudioLevelWindowManager.shared.hideWindow()
            }
        }
    }

    func checkSettingAndHideIfNeeded() {
        if isRecording && !UserDefaultsManager.shared.showLiveMeetingIndicator {
            AudioLevelWindowManager.shared.hideWindow()
        } else if isRecording && UserDefaultsManager.shared.showLiveMeetingIndicator {
             AudioLevelWindowManager.shared.showWindow()
        }
    }
}

// MARK: - Audio Level Window Manager using NSPanel
@MainActor
class AudioLevelWindowManager: ObservableObject {
    static let shared = AudioLevelWindowManager()

    private var audioLevelPanel: NSPanel?

    private init() {
        setupPanel()
    }

    private func setupPanel() {
        let panelRect = NSRect(x: 0, y: 0, width: 60, height: 80)

        audioLevelPanel = NSPanel(
            contentRect: panelRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )

        guard let panel = audioLevelPanel else { return }

        // Configure panel properties inspired by the provided code
        panel.level = .mainMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.identifier = NSUserInterfaceItemIdentifier("audio-levels")

        // Set up the SwiftUI hosting view
        let hostingView = NSHostingView(rootView: AudioLevelWindowView())
        hostingView.frame = panelRect
        panel.contentView = hostingView

        // Position the panel in the top-right corner of the screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelFrame = NSRect(
                x: screenFrame.maxX - panelRect.width - 20,
                y: screenFrame.maxY - panelRect.height - 20,
                width: panelRect.width,
                height: panelRect.height
            )
            panel.setFrame(panelFrame, display: false)
        }
    }

    func showWindow() {
        guard let panel = audioLevelPanel else {
            setupPanel()
            showWindow()
            return
        }

        panel.orderFrontRegardless()
    }

    func hideWindow() {
        audioLevelPanel?.orderOut(nil)
    }
}
