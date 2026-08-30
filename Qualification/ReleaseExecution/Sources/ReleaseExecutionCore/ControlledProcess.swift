import Darwin
import Foundation

public enum ControlledProcessError: Error, Equatable {
  case alreadyLaunched
  case notLaunched
  case launchFailed
  case terminationTimedOut
}

public struct ControlledProcessResult: Equatable, Sendable {
  public let processIdentifier: Int32
  public let terminationStatus: Int32
  public let terminationReason: String
  public let reaped: Bool

  public init(
    processIdentifier: Int32,
    terminationStatus: Int32,
    terminationReason: String,
    reaped: Bool
  ) {
    self.processIdentifier = processIdentifier
    self.terminationStatus = terminationStatus
    self.terminationReason = terminationReason
    self.reaped = reaped
  }
}

/// A deliberately narrow process host for the execution spike.
///
/// Callers provide one executable, fixed arguments, and a scoped working
/// directory. The child receives an explicit allowlist environment instead of
/// inheriting the app's ambient credentials or configuration. Both normal waits
/// and cancellation synchronously reap the child before returning.
public final class ControlledProcess {
  public static let allowedEnvironmentKeys: Set<String> = [
    "LANG",
    "LC_ALL",
    "PATH",
    "TMPDIR",
  ]

  /// CoreFoundation synthesizes this locale-related key when a Foundation
  /// executable starts on macOS. It is not inherited from the parent and
  /// carries no credential or application configuration.
  public static let platformInjectedEnvironmentKeys: Set<String> = [
    "__CF_USER_TEXT_ENCODING"
  ]

  private let executableURL: URL
  private let arguments: [String]
  private let workingDirectoryURL: URL
  private let environment: [String: String]
  private let process = Process()
  private var wasLaunched = false

  public init(
    executableURL: URL,
    arguments: [String],
    workingDirectoryURL: URL,
    environment: [String: String]
  ) {
    self.executableURL = executableURL.standardizedFileURL
    self.arguments = arguments
    self.workingDirectoryURL = workingDirectoryURL.standardizedFileURL
    self.environment = environment
  }

  public static func scrubbedEnvironment(temporaryDirectoryURL: URL) -> [String: String] {
    [
      "LANG": "C",
      "LC_ALL": "C",
      "PATH": "/usr/bin:/bin",
      "TMPDIR": temporaryDirectoryURL.standardizedFileURL.path,
    ]
  }

  @discardableResult
  public func launch() throws -> Int32 {
    guard !wasLaunched else {
      throw ControlledProcessError.alreadyLaunched
    }
    wasLaunched = true

    do {
      try FileManager.default.createDirectory(
        at: workingDirectoryURL,
        withIntermediateDirectories: true
      )
    } catch {
      throw ControlledProcessError.launchFailed
    }

    process.executableURL = executableURL
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectoryURL
    process.environment = environment
    // Child diagnostics can contain paths or user content. This spike's narrow
    // protocol uses a bounded structured ready file and discards raw streams.
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      throw ControlledProcessError.launchFailed
    }
    return process.processIdentifier
  }

  public var isRunning: Bool {
    process.isRunning
  }

  public func waitAndReap(timeout: TimeInterval) throws -> ControlledProcessResult {
    guard wasLaunched else {
      throw ControlledProcessError.notLaunched
    }
    guard waitForExit(timeout: timeout) else {
      throw ControlledProcessError.terminationTimedOut
    }
    return collectResult()
  }

  public func cancelAndReap(gracePeriod: TimeInterval) throws -> ControlledProcessResult {
    guard wasLaunched else {
      throw ControlledProcessError.notLaunched
    }

    if process.isRunning {
      process.terminate()
    }
    if !waitForExit(timeout: gracePeriod) {
      Darwin.kill(process.processIdentifier, SIGKILL)
      guard waitForExit(timeout: gracePeriod) else {
        throw ControlledProcessError.terminationTimedOut
      }
    }
    return collectResult()
  }

  private func waitForExit(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    guard !process.isRunning else {
      return false
    }
    process.waitUntilExit()
    return true
  }

  private func collectResult() -> ControlledProcessResult {
    let reason: String
    switch process.terminationReason {
    case .exit:
      reason = "exit"
    case .uncaughtSignal:
      reason = "signal"
    @unknown default:
      reason = "unknown"
    }

    return ControlledProcessResult(
      processIdentifier: process.processIdentifier,
      terminationStatus: process.terminationStatus,
      terminationReason: reason,
      reaped: !process.isRunning
    )
  }
}
