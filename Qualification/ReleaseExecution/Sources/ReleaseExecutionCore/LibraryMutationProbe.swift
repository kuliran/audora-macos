import Foundation

public struct LibraryMutationRecord: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let generation: Int
  public let lastRunID: String
  public let updatedAt: String

  public init(
    schemaVersion: Int = 1,
    generation: Int,
    lastRunID: String,
    updatedAt: String
  ) {
    self.schemaVersion = schemaVersion
    self.generation = generation
    self.lastRunID = lastRunID
    self.updatedAt = updatedAt
  }
}

public enum LibraryMutationProbeError: Error, Equatable {
  case libraryIsNotDirectory
  case cannotCreateHarnessDirectory
  case corruptExistingRecord
  case cannotEncodeRecord
}

public struct LibraryMutationProbe: Sendable {
  public static let harnessDirectoryName = ".audora-release-execution"
  public static let recordFileName = "library-mutation.json"

  private let writer: AtomicFileWriter

  public init(writer: AtomicFileWriter = AtomicFileWriter()) {
    self.writer = writer
  }

  /// Reopens and mutates a probe-owned record inside a user-selected Library.
  /// It never edits an authoritative Audora manifest.
  public func mutate(
    libraryURL: URL,
    runID: String = UUID().uuidString,
    now: Date = Date()
  ) throws -> LibraryMutationRecord {
    let libraryURL = libraryURL.standardizedFileURL
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: libraryURL.path,
        isDirectory: &isDirectory
      ), isDirectory.boolValue
    else {
      throw LibraryMutationProbeError.libraryIsNotDirectory
    }

    let harnessDirectoryURL = libraryURL.appendingPathComponent(
      Self.harnessDirectoryName,
      isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(
        at: harnessDirectoryURL,
        withIntermediateDirectories: true
      )
    } catch {
      throw LibraryMutationProbeError.cannotCreateHarnessDirectory
    }

    let recordURL = harnessDirectoryURL.appendingPathComponent(
      Self.recordFileName,
      isDirectory: false
    )
    let previousRecord: LibraryMutationRecord?
    if let previousData = try writer.readInstalledFile(at: recordURL) {
      do {
        previousRecord = try JSONDecoder().decode(
          LibraryMutationRecord.self,
          from: previousData
        )
      } catch {
        throw LibraryMutationProbeError.corruptExistingRecord
      }
    } else {
      previousRecord = nil
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let newRecord = LibraryMutationRecord(
      generation: (previousRecord?.generation ?? 0) + 1,
      lastRunID: runID,
      updatedAt: formatter.string(from: now)
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data: Data
    do {
      data = try encoder.encode(newRecord)
    } catch {
      throw LibraryMutationProbeError.cannotEncodeRecord
    }
    try writer.write(data, to: recordURL)
    return newRecord
  }
}
