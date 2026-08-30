import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let windowCoordinator: WriterWindowCoordinator

  init(executableURL: URL) {
    windowCoordinator = WriterWindowCoordinator(executableURL: executableURL)
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    installMainMenu()
    windowCoordinator.focusWriterWindow()
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    windowCoordinator.focusWriterWindow()
    return true
  }

  func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
    windowCoordinator.focusWriterWindow()
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  private func installMainMenu() {
    let mainMenu = NSMenu()
    let applicationItem = NSMenuItem()
    mainMenu.addItem(applicationItem)

    let applicationMenu = NSMenu()
    applicationMenu.addItem(
      withTitle: "About Audora Release Execution Spike",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: ""
    )
    applicationMenu.addItem(.separator())
    applicationMenu.addItem(
      withTitle: "Quit Audora Release Execution Spike",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    applicationItem.submenu = applicationMenu

    let windowItem = NSMenuItem()
    mainMenu.addItem(windowItem)
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      withTitle: "Focus Writer Window",
      action: #selector(focusWriterWindowFromMenu(_:)),
      keyEquivalent: "0"
    ).target = self
    windowItem.submenu = windowMenu
    NSApp.windowsMenu = windowMenu

    NSApp.mainMenu = mainMenu
  }

  @objc private func focusWriterWindowFromMenu(_ sender: Any?) {
    windowCoordinator.focusWriterWindow()
  }
}
