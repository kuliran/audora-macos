import Darwin
import Foundation

public enum ReleaseQualificationRunnerError: Error, Equatable {
  case cannotPrepareFixture
  case cannotEncodeFixture
  case atomicChildDidNotInterrupt(AtomicWriteCheckpoint, Int32)
  case atomicStateMissing(AtomicWriteCheckpoint)
  case atomicStateCorrupt(AtomicWriteCheckpoint)
  case atomicStateMismatch(AtomicWriteCheckpoint)
  case workerDidNotBecomeReady
  case workerReportCorrupt
  case workerScopeMismatch
  case workerEnvironmentNotScrubbed
  case workerDidNotCancel
}

public struct ReleaseQualificationOutcome: Equatable, Sendable {
  public let firstLibraryGeneration: Int
  public let reopenedLibraryGeneration: Int
  public let child: ChildQualificationOutcome
  public let atomicWrites: [AtomicQualificationOutcome]

  public init(
    firstLibraryGeneration: Int,
    reopenedLibraryGeneration: Int,
    child: ChildQualificationOutcome,
    atomicWrites: [AtomicQualificationOutcome]
  ) {
    self.firstLibraryGeneration = firstLibraryGeneration
    self.reopenedLibraryGeneration = reopenedLibraryGeneration
    self.child = child
    self.atomicWrites = atomicWrites
  }

  public var passed: Bool {
    firstLibraryGeneration >= 1
      && reopenedLibraryGeneration == firstLibraryGeneration + 1
      && child.passed
      && atomicWrites.count == AtomicWriteCheckpoint.allCases.count
      && atomicWrites.allSatisfy(\.passed)
  }
}

/// Runs the non-UI release execution checks against a caller-owned fixture root.
/// The executable must be this package's release-execution-spike binary because
/// child modes are intentionally private to the harness.
public struct ReleaseQualificationRunner: Sendable {
  private let writer = AtomicFileWriter()
  private let mutationProbe = LibraryMutationProbe()

  public init() {}

  public func run(
    executableURL: URL,
    libraryURL: URL
  ) throws -> ReleaseQualificationOutcome {
    do {
      try FileManager.default.createDirectory(
        at: libraryURL,
        withIntermediateDirectories: true
      )
    } catch {
      throw ReleaseQualificationRunnerError.cannotPrepareFixture
    }

    let firstMutation = try mutationProbe.mutate(libraryURL: libraryURL)
    // A fresh probe instance models reopening the same chosen Library.
    let reopenedMutation = try LibraryMutationProbe().mutate(libraryURL: libraryURL)

    let harnessRootURL = libraryURL.appendingPathComponent(
      LibraryMutationProbe.harnessDirectoryName,
      isDirectory: true
    )
    let childOutcome = try runChildLifecycle(
      executableURL: executableURL,
      harnessRootURL: harnessRootURL
    )
    let atomicOutcomes = try runAtomicMatrix(
      executableURL: executableURL,
      harnessRootURL: harnessRootURL
    )

    return ReleaseQualificationOutcome(
      firstLibraryGeneration: firstMutation.generation,
      reopenedLibraryGeneration: reopenedMutation.generation,
      child: childOutcome,
      atomicWrites: atomicOutcomes
    )
  }

  public func runChildLifecycle(
    executableURL: URL,
    harnessRootURL: URL
  ) throws -> ChildQualificationOutcome {
    let workingDirectoryURL = harnessRootURL.appendingPathComponent(
      "worker-scope",
      isDirectory: true
    )
    let temporaryDirectoryURL = workingDirectoryURL.appendingPathComponent(
      "tmp",
      isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(
        at: temporaryDirectoryURL,
        withIntermediateDirectories: true
      )
    } catch {
      throw ReleaseQualificationRunnerError.cannotPrepareFixture
    }

    let readyFileName = "worker-ready.json"
    let readyFileURL = workingDirectoryURL.appendingPathComponent(
      readyFileName,
      isDirectory: false
    )
    if FileManager.default.fileExists(atPath: readyFileURL.path) {
      do {
        try FileManager.default.removeItem(at: readyFileURL)
      } catch {
        throw ReleaseQualificationRunnerError.cannotPrepareFixture
      }
    }

    let child = ControlledProcess(
      executableURL: executableURL,
      arguments: ["worker-probe", "--ready-file", readyFileName],
      workingDirectoryURL: workingDirectoryURL,
      environment: ControlledProcess.scrubbedEnvironment(
        temporaryDirectoryURL: temporaryDirectoryURL
      )
    )
    let processIdentifier = try child.launch()

    let deadline = Date().addingTimeInterval(5)
    var reportData: Data?
    while Date() < deadline {
      reportData = try writer.readInstalledFile(at: readyFileURL)
      if reportData != nil {
        break
      }
      Thread.sleep(forTimeInterval: 0.02)
    }

    guard let reportData else {
      _ = try? child.cancelAndReap(gracePeriod: 2)
      throw ReleaseQualificationRunnerError.workerDidNotBecomeReady
    }
    let report: WorkerProbeRecord
    do {
      report = try JSONDecoder().decode(WorkerProbeRecord.self, from: reportData)
    } catch {
      _ = try? child.cancelAndReap(gracePeriod: 2)
      throw ReleaseQualificationRunnerError.workerReportCorrupt
    }

    let reportedWorkingDirectoryURL = URL(
      fileURLWithPath: report.workingDirectory,
      isDirectory: true
    ).resolvingSymlinksInPath()
    let expectedWorkingDirectoryURL = workingDirectoryURL.resolvingSymlinksInPath()
    let usedScopedWorkingDirectory =
      reportedWorkingDirectoryURL.path
      == expectedWorkingDirectoryURL.path
    guard usedScopedWorkingDirectory else {
      _ = try? child.cancelAndReap(gracePeriod: 2)
      throw ReleaseQualificationRunnerError.workerScopeMismatch
    }

    let reportedEnvironmentKeys = Set(report.environmentKeys)
    let unexpectedEnvironmentKeys = reportedEnvironmentKeys.subtracting(
      ControlledProcess.allowedEnvironmentKeys.union(
        ControlledProcess.platformInjectedEnvironmentKeys
      )
    )
    let usedScrubbedEnvironment =
      unexpectedEnvironmentKeys.isEmpty
      && ControlledProcess.allowedEnvironmentKeys.isSubset(
        of: reportedEnvironmentKeys
      )
    guard usedScrubbedEnvironment else {
      _ = try? child.cancelAndReap(gracePeriod: 2)
      throw ReleaseQualificationRunnerError.workerEnvironmentNotScrubbed
    }

    let result = try child.cancelAndReap(gracePeriod: 2)
    let cancelled =
      result.terminationReason == "signal"
      && (result.terminationStatus == SIGTERM || result.terminationStatus == SIGKILL)
    guard cancelled else {
      throw ReleaseQualificationRunnerError.workerDidNotCancel
    }

    return ChildQualificationOutcome(
      launched: processIdentifier > 0,
      becameReady: true,
      usedScopedWorkingDirectory: usedScopedWorkingDirectory,
      usedScrubbedEnvironment: usedScrubbedEnvironment,
      cancelled: cancelled,
      reaped: result.reaped
    )
  }

  public func runAtomicMatrix(
    executableURL: URL,
    harnessRootURL: URL
  ) throws -> [AtomicQualificationOutcome] {
    var outcomes: [AtomicQualificationOutcome] = []
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    for checkpoint in AtomicWriteCheckpoint.allCases {
      let fixtureDirectoryURL =
        harnessRootURL
        .appendingPathComponent("atomic-fixtures", isDirectory: true)
        .appendingPathComponent(checkpoint.rawValue, isDirectory: true)
      do {
        try FileManager.default.createDirectory(
          at: fixtureDirectoryURL,
          withIntermediateDirectories: true
        )
      } catch {
        throw ReleaseQualificationRunnerError.cannotPrepareFixture
      }

      let stateURL = fixtureDirectoryURL.appendingPathComponent(
        "state.json",
        isDirectory: false
      )
      let oldState = AtomicFixtureState(
        state: "old",
        payload: String(repeating: "old-evidence-", count: 1_024)
      )
      let oldData: Data
      do {
        oldData = try encoder.encode(oldState)
      } catch {
        throw ReleaseQualificationRunnerError.cannotEncodeFixture
      }
      try writer.write(oldData, to: stateURL)

      let temporaryDirectoryURL = fixtureDirectoryURL.appendingPathComponent(
        "tmp",
        isDirectory: true
      )
      do {
        try FileManager.default.createDirectory(
          at: temporaryDirectoryURL,
          withIntermediateDirectories: true
        )
      } catch {
        throw ReleaseQualificationRunnerError.cannotPrepareFixture
      }

      let child = ControlledProcess(
        executableURL: executableURL,
        arguments: [
          "atomic-interrupt",
          "--file",
          stateURL.path,
          "--checkpoint",
          checkpoint.rawValue,
        ],
        workingDirectoryURL: fixtureDirectoryURL,
        environment: ControlledProcess.scrubbedEnvironment(
          temporaryDirectoryURL: temporaryDirectoryURL
        )
      )
      try child.launch()
      let result = try child.waitAndReap(timeout: 5)
      guard result.terminationStatus == 86 else {
        throw ReleaseQualificationRunnerError.atomicChildDidNotInterrupt(
          checkpoint,
          result.terminationStatus
        )
      }

      // This read is the simulated relaunch. Only the final path is a
      // selectable root; any sibling partial remains untrusted.
      guard let observedData = try writer.readInstalledFile(at: stateURL) else {
        throw ReleaseQualificationRunnerError.atomicStateMissing(checkpoint)
      }
      let observedState: AtomicFixtureState
      do {
        observedState = try JSONDecoder().decode(
          AtomicFixtureState.self,
          from: observedData
        )
      } catch {
        throw ReleaseQualificationRunnerError.atomicStateCorrupt(checkpoint)
      }

      let expectedState = checkpoint.expectedVisibleState
      let expectedPayloadPrefix = expectedState == "old" ? "old-evidence-" : "new-evidence-"
      guard observedState.state == expectedState,
        observedState.payload
          == String(
            repeating: expectedPayloadPrefix,
            count: 1_024
          )
      else {
        throw ReleaseQualificationRunnerError.atomicStateMismatch(checkpoint)
      }

      outcomes.append(
        AtomicQualificationOutcome(
          checkpoint: checkpoint,
          expectedState: expectedState,
          observedState: observedState.state,
          childTerminationStatus: result.terminationStatus
        )
      )
    }
    return outcomes
  }
}
