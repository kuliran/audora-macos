import AppKit
import Darwin
import Foundation
import ReleaseExecutionCore

@main
@MainActor
enum ReleaseExecutionSpike {
  private static var appDelegate: AppDelegate?

  static func main() {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      if arguments.isEmpty {
        runApplication()
      } else {
        try runCommand(arguments)
      }
    } catch {
      writeStandardError(
        "release-execution-spike failed: \(String(describing: type(of: error)))\n"
      )
      Darwin.exit(1)
    }
  }

  private static func runApplication() {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = AppDelegate(executableURL: resolvedExecutableURL())
    appDelegate = delegate
    application.delegate = delegate
    application.run()
  }

  private static func runCommand(_ arguments: [String]) throws {
    switch arguments.first {
    case "qualify":
      let libraryPath = try value(after: "--directory", in: arguments)
      let outcome = try ReleaseQualificationRunner().run(
        executableURL: resolvedExecutableURL(),
        libraryURL: URL(fileURLWithPath: libraryPath, isDirectory: true)
      )
      printQualificationOutcome(outcome)
      guard outcome.passed else {
        throw CommandError.qualificationFailed
      }

    case "atomic-interrupt":
      let filePath = try value(after: "--file", in: arguments)
      let checkpointValue = try value(after: "--checkpoint", in: arguments)
      guard let checkpoint = AtomicWriteCheckpoint(rawValue: checkpointValue) else {
        throw CommandError.invalidCheckpoint
      }

      let state = AtomicFixtureState(
        state: "new",
        payload: String(repeating: "new-evidence-", count: 1_024)
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(state)
      try AtomicFileWriter().write(
        data,
        to: URL(fileURLWithPath: filePath, isDirectory: false)
      ) { reachedCheckpoint in
        if reachedCheckpoint == checkpoint {
          Darwin._exit(86)
        }
      }
      throw CommandError.interruptionCheckpointNotReached

    case "worker-probe":
      let readyFileName = try value(after: "--ready-file", in: arguments)
      guard readyFileName == URL(fileURLWithPath: readyFileName).lastPathComponent,
        !readyFileName.contains("/")
      else {
        throw CommandError.invalidReadyFile
      }

      let environmentKeys = ProcessInfo.processInfo.environment.keys.sorted()
      let record = WorkerProbeRecord(
        workingDirectory: FileManager.default.currentDirectoryPath,
        environmentKeys: environmentKeys
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(record)
      let readyFileURL = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
      ).appendingPathComponent(readyFileName, isDirectory: false)
      try AtomicFileWriter().write(data, to: readyFileURL)
      while true {
        Darwin.pause()
      }

    case "help", "--help", "-h":
      printUsage()

    default:
      throw CommandError.unknownCommand
    }
  }

  private static func printQualificationOutcome(_ outcome: ReleaseQualificationOutcome) {
    print(
      "library-mutation: PASS generation \(outcome.firstLibraryGeneration) -> "
        + "\(outcome.reopenedLibraryGeneration) after reopen"
    )
    let childStatus = outcome.child.passed ? "PASS" : "FAIL"
    print(
      "child-process: \(childStatus) launched=\(outcome.child.launched) "
        + "ready=\(outcome.child.becameReady) "
        + "working-directory=scoped environment=scrubbed "
        + "cancelled=\(outcome.child.cancelled) reaped=\(outcome.child.reaped)"
    )
    for atomicWrite in outcome.atomicWrites {
      let status = atomicWrite.passed ? "PASS" : "FAIL"
      print(
        "atomic-\(atomicWrite.checkpoint.rawValue): \(status) "
          + "visible=\(atomicWrite.observedState) "
          + "expected=\(atomicWrite.expectedState) "
          + "interruption-status=\(atomicWrite.childTerminationStatus)"
      )
    }
    print("overall: \(outcome.passed ? "PASS" : "FAIL")")
  }

  private static func printUsage() {
    print(
      """
      Usage:
        release-execution-spike
        release-execution-spike qualify --directory <fixture-library>

      The atomic-interrupt and worker-probe commands are private child modes
      used by the qualification runner.
      """
    )
  }

  private static func value(after option: String, in arguments: [String]) throws -> String {
    guard let optionIndex = arguments.firstIndex(of: option),
      arguments.indices.contains(optionIndex + 1)
    else {
      throw CommandError.missingOption(option)
    }
    return arguments[optionIndex + 1]
  }

  private static func resolvedExecutableURL() -> URL {
    if let executableURL = Bundle.main.executableURL {
      return executableURL.standardizedFileURL
    }
    let argument = CommandLine.arguments[0]
    if argument.hasPrefix("/") {
      return URL(fileURLWithPath: argument, isDirectory: false).standardizedFileURL
    }
    return URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ).appendingPathComponent(argument, isDirectory: false).standardizedFileURL
  }

  private static func writeStandardError(_ value: String) {
    guard let data = value.data(using: .utf8) else {
      return
    }
    FileHandle.standardError.write(data)
  }
}

private enum CommandError: Error, Equatable {
  case unknownCommand
  case missingOption(String)
  case invalidCheckpoint
  case invalidReadyFile
  case interruptionCheckpointNotReached
  case qualificationFailed
}
