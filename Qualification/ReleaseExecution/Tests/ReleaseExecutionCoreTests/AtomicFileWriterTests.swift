import Foundation
import XCTest

@testable import ReleaseExecutionCore

final class AtomicFileWriterTests: XCTestCase {
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

  func testEveryInterruptionExposesOnlyCompleteOldOrNewState() throws {
    let writer = AtomicFileWriter()
    let oldState = AtomicFixtureState(state: "old", payload: String(repeating: "o", count: 8_192))
    let newState = AtomicFixtureState(state: "new", payload: String(repeating: "n", count: 8_192))
    let encoder = JSONEncoder()
    let oldData = try encoder.encode(oldState)
    let newData = try encoder.encode(newState)

    for checkpoint in AtomicWriteCheckpoint.allCases {
      let checkpointDirectoryURL = temporaryDirectoryURL.appendingPathComponent(
        checkpoint.rawValue,
        isDirectory: true
      )
      let stateURL = checkpointDirectoryURL.appendingPathComponent("state.json")
      try writer.write(oldData, to: stateURL)

      XCTAssertThrowsError(
        try writer.write(newData, to: stateURL) { reachedCheckpoint in
          if reachedCheckpoint == checkpoint {
            throw InjectedInterruption()
          }
        }
      )

      let installedData = try XCTUnwrap(writer.readInstalledFile(at: stateURL))
      let installedState = try JSONDecoder().decode(
        AtomicFixtureState.self,
        from: installedData
      )
      let expectedState = checkpoint.expectedVisibleState == "old" ? oldState : newState
      XCTAssertEqual(installedState, expectedState, checkpoint.rawValue)

      let partialExists = FileManager.default.fileExists(
        atPath: writer.siblingPartialURL(for: stateURL).path
      )
      XCTAssertEqual(
        partialExists,
        checkpoint == .partialWritten || checkpoint == .partialFlushed,
        checkpoint.rawValue
      )
    }
  }

  func testReadNeverSelectsOrParsesLeftoverPartial() throws {
    let writer = AtomicFileWriter()
    let stateURL = temporaryDirectoryURL.appendingPathComponent("state.json")
    let installed = Data("complete-old".utf8)
    try writer.write(installed, to: stateURL)
    try Data("truncated-new".utf8).write(
      to: writer.siblingPartialURL(for: stateURL)
    )

    XCTAssertEqual(try writer.readInstalledFile(at: stateURL), installed)
  }
}

private struct InjectedInterruption: Error {}
