import AppKit

@MainActor
public protocol MainWindowAccess: AnyObject {
    var mainWindowIdentity: ObjectIdentifier? { get }
    func focusMainWindow()
}

@MainActor
public final class MainWindowCoordinator {
    private let access: any MainWindowAccess
    private var reopenAction: (@MainActor () -> Void)?

    public init(access: any MainWindowAccess) {
        self.access = access
    }

    public func registerReopenAction(_ action: @escaping @MainActor () -> Void) {
        reopenAction = action
    }

    @discardableResult
    public func focusExistingMainWindow() -> ObjectIdentifier? {
        if access.mainWindowIdentity == nil {
            reopenAction?()
        }
        access.focusMainWindow()
        return access.mainWindowIdentity
    }
}

@MainActor
public final class AppKitMainWindowAccess: MainWindowAccess {
    private var pendingFocus = false
    private var windowObserver: NSObjectProtocol?

    public init() {}

    public var mainWindowIdentity: ObjectIdentifier? {
        mainWindow.map(ObjectIdentifier.init)
    }

    public func focusMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = mainWindow else {
            pendingFocus = true
            if windowObserver == nil {
                windowObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didUpdateNotification,
                    object: NSApp,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.focusPendingWindowIfAvailable()
                    }
                }
            }
            return
        }
        finishFocus(window)
    }

    private func focusPendingWindowIfAvailable() {
        guard pendingFocus, let window = mainWindow else { return }
        finishFocus(window)
    }

    private func finishFocus(_ window: NSWindow) {
        pendingFocus = false
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { window in
            window.identifier?.rawValue == "library" || window.title == "Audora"
        }
    }
}
