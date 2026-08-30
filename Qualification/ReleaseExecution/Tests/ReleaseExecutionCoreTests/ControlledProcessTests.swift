import Darwin
import Foundation
import XCTest

@testable import ReleaseExecutionCore

final class ControlledProcessTests: XCTestCase {
  private var temporaryDirectoryURL: URL!

  override func setUpWithError() throws {
    temporaryDirectoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectoryURL,
      withIntermediateDirectories: true
    )
  }

  override func tearDownWithError() throws {
    if let temporaryDirectoryURL {
      try? FileManager.default.removeItem(at: temporaryDirectoryURL)
    }
  }

  func testScrubbedEnvironmentIsAnExactAllowlist() {
    let environment = ControlledProcess.scrubbedEnvironment(
      temporaryDirectoryURL: temporaryDirectoryURL
    )

    XCTAssertEqual(Set(environment.keys), ControlledProcess.allowedEnvironmentKeys)
    XCTAssertNil(environment["HOME"])
    XCTAssertNil(environment["SSH_AUTH_SOCK"])
    XCTAssertNil(environment["AUDORA_LEAK_SENTINEL"])
  }

  func testChildRunsToCompletionWithScrubbedEnvironment() throws {
    let child = ControlledProcess(
      executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: [],
      workingDirectoryURL: temporaryDirectoryURL,
      environment: ControlledProcess.scrubbedEnvironment(
        temporaryDirectoryURL: temporaryDirectoryURL
      )
    )

    try child.launch()
    let result = try child.waitAndReap(timeout: 2)

    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertEqual(result.terminationReason, "exit")
    XCTAssertTrue(result.reaped)
  }

  func testCancellationWaitsForAndReapsChild() throws {
    let child = ControlledProcess(
      executableURL: URL(fileURLWithPath: "/bin/sleep"),
      arguments: ["30"],
      workingDirectoryURL: temporaryDirectoryURL,
      environment: ControlledProcess.scrubbedEnvironment(
        temporaryDirectoryURL: temporaryDirectoryURL
      )
    )

    let processIdentifier = try child.launch()
    let result = try child.cancelAndReap(gracePeriod: 2)

    XCTAssertFalse(child.isRunning)
    XCTAssertEqual(result.processIdentifier, processIdentifier)
    XCTAssertEqual(result.terminationReason, "signal")
    XCTAssertTrue(result.terminationStatus == SIGTERM || result.terminationStatus == SIGKILL)
    XCTAssertTrue(result.reaped)
  }
}
