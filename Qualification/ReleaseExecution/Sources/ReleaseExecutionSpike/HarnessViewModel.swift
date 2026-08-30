import AVFoundation
import AppKit
import Foundation
import ReleaseExecutionCore
import SwiftUI

@MainActor
final class HarnessViewModel: ObservableObject {
  @Published private(set) var libraryName = "No Library selected"
  @Published private(set) var libraryStatus = "Choose an existing or new Library directory."
  @Published private(set) var microphoneStatus = "Not requested in this run"
  @Published private(set) var automatedStatus = "Not run"
  @Published private(set) var automatedDetails: [String] = []
  @Published private(set) var isRunning = false

  private let executableURL: URL
  private let locator = HarnessLibraryLocator()
  private var libraryURL: URL?

  init(executableURL: URL) {
    self.executableURL = executableURL
    if let restoredURL = locator.restore() {
      libraryURL = restoredURL
      libraryName = restoredURL.lastPathComponent
      libraryStatus = "Reopened the machine-local Library locator. Mutate it to verify access."
    }
    refreshMicrophoneStatus()
  }

  func chooseAndMutateLibrary() {
    let panel = NSOpenPanel()
    panel.title = "Choose an Audora Library"
    panel.prompt = "Choose Library"
    panel.message = "Choose a directory the non-sandboxed harness may reopen and mutate."
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true

    guard panel.runModal() == .OK, let selectedURL = panel.url else {
      libraryStatus = "Selection cancelled; no Library was changed."
      return
    }

    do {
      try locator.store(selectedURL)
      libraryURL = selectedURL
      libraryName = selectedURL.lastPathComponent
      try mutateSelectedLibrary()
    } catch {
      libraryStatus = "Library selection could not be saved or mutated (\(errorCategory(error)))."
    }
  }

  func mutateSelectedLibrary() throws {
    guard let libraryURL else {
      libraryStatus = "Choose a Library before mutation."
      return
    }
    let record = try LibraryMutationProbe().mutate(libraryURL: libraryURL)
    libraryStatus = "Mutation installed atomically at generation \(record.generation)."
  }

  func requestMicrophonePermission() {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      microphoneStatus = "Authorized"
    case .denied:
      microphoneStatus = "Denied in System Settings"
    case .restricted:
      microphoneStatus = "Restricted by the system"
    case .notDetermined:
      microphoneStatus = "Request in progress…"
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
        Task { @MainActor in
          self?.microphoneStatus = granted ? "Authorized" : "Denied"
        }
      }
    @unknown default:
      microphoneStatus = "Unknown system status"
    }
  }

  func runAutomatedQualification() {
    guard let libraryURL else {
      automatedStatus = "Choose a Library first."
      return
    }

    isRunning = true
    automatedStatus = "Running child lifecycle and interruption matrix…"
    automatedDetails = []
    let executableURL = executableURL

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        let outcome = try ReleaseQualificationRunner().run(
          executableURL: executableURL,
          libraryURL: libraryURL
        )
        let details = Self.details(for: outcome)
        DispatchQueue.main.async {
          self?.automatedStatus = outcome.passed ? "PASS" : "FAIL"
          self?.automatedDetails = details
          self?.isRunning = false
        }
      } catch {
        let category = Self.errorCategory(error)
        DispatchQueue.main.async {
          self?.automatedStatus = "FAIL (\(category))"
          self?.isRunning = false
        }
      }
    }
  }

  private func refreshMicrophoneStatus() {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      microphoneStatus = "Already authorized"
    case .denied:
      microphoneStatus = "Previously denied"
    case .restricted:
      microphoneStatus = "Restricted by the system"
    case .notDetermined:
      microphoneStatus = "Not requested in this run"
    @unknown default:
      microphoneStatus = "Unknown system status"
    }
  }

  nonisolated private static func details(
    for outcome: ReleaseQualificationOutcome
  ) -> [String] {
    var details = [
      "Library reopen mutation: generation \(outcome.firstLibraryGeneration) → \(outcome.reopenedLibraryGeneration)",
      "Child: scoped directory, scrubbed environment, cancelled and reaped",
    ]
    details.append(
      contentsOf: outcome.atomicWrites.map {
        "\($0.checkpoint.rawValue): complete \($0.observedState) state"
      }
    )
    return details
  }

  nonisolated private static func errorCategory(_ error: Error) -> String {
    String(describing: type(of: error))
  }

  private func errorCategory(_ error: Error) -> String {
    Self.errorCategory(error)
  }
}

private struct HarnessLibraryLocator {
  private let defaultsKey = "AudoraReleaseExecution.LibraryBookmark"

  func store(_ url: URL) throws {
    let bookmark = try url.bookmarkData(
      options: .minimalBookmark,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    UserDefaults.standard.set(bookmark, forKey: defaultsKey)
  }

  func restore() -> URL? {
    guard let bookmark = UserDefaults.standard.data(forKey: defaultsKey) else {
      return nil
    }
    var isStale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: bookmark,
        options: .withoutUI,
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      ), !isStale
    else {
      return nil
    }
    return url
  }
}
