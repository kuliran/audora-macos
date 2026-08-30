import AppKit
import Foundation
import SwiftUI

/// Owns the harness's only writer window. Every launch/reopen intent calls
/// `focusWriterWindow`; none creates a second Library writer.
@MainActor
final class WriterWindowCoordinator {
  private let executableURL: URL
  private var windowController: NSWindowController?

  init(executableURL: URL) {
    self.executableURL = executableURL
  }

  func focusWriterWindow() {
    let controller: NSWindowController
    if let windowController {
      controller = windowController
    } else {
      let model = HarnessViewModel(executableURL: executableURL)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
      )
      window.title = "Audora Release Execution Spike"
      window.isReleasedWhenClosed = false
      window.minSize = NSSize(width: 680, height: 560)
      window.center()
      window.contentView = NSHostingView(rootView: HarnessView(model: model))
      controller = NSWindowController(window: window)
      windowController = controller
    }

    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
