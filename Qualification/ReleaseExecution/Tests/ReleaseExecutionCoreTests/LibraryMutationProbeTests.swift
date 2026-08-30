import Foundation
import XCTest

@testable import ReleaseExecutionCore

final class LibraryMutationProbeTests: XCTestCase {
  private var libraryURL: URL!

  override func setUpWithError() throws {
    libraryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".audoralibrary", isDirectory: true)
    try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let libraryURL {
      try? FileManager.default.removeItem(at: libraryURL)
    }
  }

  func testReopenMutatesProbeOwnedRecordByOneGeneration() throws {
    let firstDate = Date(timeIntervalSince1970: 1_000)
    let secondDate = Date(timeIntervalSince1970: 2_000)

    let first = try LibraryMutationProbe().mutate(
      libraryURL: libraryURL,
      runID: "first",
      now: firstDate
    )
    let second = try LibraryMutationProbe().mutate(
      libraryURL: libraryURL,
      runID: "second",
      now: secondDate
    )

    XCTAssertEqual(first.generation, 1)
    XCTAssertEqual(second.generation, 2)
    XCTAssertEqual(second.lastRunID, "second")

    let recordURL =
      libraryURL
      .appendingPathComponent(LibraryMutationProbe.harnessDirectoryName)
      .appendingPathComponent(LibraryMutationProbe.recordFileName)
    let persisted = try JSONDecoder().decode(
      LibraryMutationRecord.self,
      from: Data(contentsOf: recordURL)
    )
    XCTAssertEqual(persisted, second)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: AtomicFileWriter().siblingPartialURL(for: recordURL).path
      )
    )
  }

  func testProbeDoesNotEditAuthoritativeLibraryManifest() throws {
    let manifestURL = libraryURL.appendingPathComponent("library.json")
    let manifest = Data("authoritative".utf8)
    try manifest.write(to: manifestURL)

    _ = try LibraryMutationProbe().mutate(libraryURL: libraryURL)

    XCTAssertEqual(try Data(contentsOf: manifestURL), manifest)
  }
}
