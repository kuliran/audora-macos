import Foundation

public struct WorkerProbeRecord: Codable, Equatable, Sendable {
  public let workingDirectory: String
  public let environmentKeys: [String]

  public init(workingDirectory: String, environmentKeys: [String]) {
    self.workingDirectory = workingDirectory
    self.environmentKeys = environmentKeys
  }
}

public struct AtomicFixtureState: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let state: String
  public let payload: String

  public init(schemaVersion: Int = 1, state: String, payload: String) {
    self.schemaVersion = schemaVersion
    self.state = state
    self.payload = payload
  }
}

public struct AtomicQualificationOutcome: Equatable, Sendable {
  public let checkpoint: AtomicWriteCheckpoint
  public let expectedState: String
  public let observedState: String
  public let childTerminationStatus: Int32

  public init(
    checkpoint: AtomicWriteCheckpoint,
    expectedState: String,
    observedState: String,
    childTerminationStatus: Int32
  ) {
    self.checkpoint = checkpoint
    self.expectedState = expectedState
    self.observedState = observedState
    self.childTerminationStatus = childTerminationStatus
  }

  public var passed: Bool {
    childTerminationStatus == 86 && observedState == expectedState
  }
}

public struct ChildQualificationOutcome: Equatable, Sendable {
  public let launched: Bool
  public let becameReady: Bool
  public let usedScopedWorkingDirectory: Bool
  public let usedScrubbedEnvironment: Bool
  public let cancelled: Bool
  public let reaped: Bool

  public init(
    launched: Bool,
    becameReady: Bool,
    usedScopedWorkingDirectory: Bool,
    usedScrubbedEnvironment: Bool,
    cancelled: Bool,
    reaped: Bool
  ) {
    self.launched = launched
    self.becameReady = becameReady
    self.usedScopedWorkingDirectory = usedScopedWorkingDirectory
    self.usedScrubbedEnvironment = usedScrubbedEnvironment
    self.cancelled = cancelled
    self.reaped = reaped
  }

  public var passed: Bool {
    launched
      && becameReady
      && usedScopedWorkingDirectory
      && usedScrubbedEnvironment
      && cancelled
      && reaped
  }
}
