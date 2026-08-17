import AppKit
import Combine

/// Tracks the frontmost application.
final class FrontmostAppMonitor: ObservableObject {
    @Published private(set) var frontmostApp: NSRunningApplication?

    private var observer: NSObjectProtocol?

    init() {
        frontmostApp = NSWorkspace.shared.frontmostApplication
        print("📱 FrontmostAppMonitor initialized")

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }

            print("📱 FrontmostAppMonitor observed an app activation")
            self?.frontmostApp = app
        }
    }

    deinit {
        if let observer = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
