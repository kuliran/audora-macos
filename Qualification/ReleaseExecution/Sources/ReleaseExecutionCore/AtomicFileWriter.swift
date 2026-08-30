import Darwin
import Foundation
import ReleaseExecutionPOSIX

public enum AtomicWriteCheckpoint: String, CaseIterable, Codable, Sendable {
  case partialWritten
  case partialFlushed
  case finalInstalled
  case directoryFlushed

  public var expectedVisibleState: String {
    switch self {
    case .partialWritten, .partialFlushed:
      return "old"
    case .finalInstalled, .directoryFlushed:
      return "new"
    }
  }
}

public enum AtomicFileWriterError: Error, Equatable {
  case destinationHasNoParent
  case cannotCreateParent
  case cannotOpenPartial(Int32)
  case cannotSecurePartial(Int32)
  case cannotWritePartial(Int32)
  case cannotFlushPartial(Int32)
  case cannotClosePartial(Int32)
  case cannotInstallFinal(Int32)
  case cannotOpenParent(Int32)
  case cannotFlushParent(Int32)
}

/// Installs a file with a sibling partial and an atomic rename.
///
/// The interruption callback is deliberately placed after the write, file flush,
/// install, and directory flush so the qualification harness can terminate a
/// child at each persistence boundary. A leftover partial is never selected by
/// `readInstalledFile(at:)`.
public struct AtomicFileWriter: Sendable {
  public init() {}

  public func write(
    _ data: Data,
    to destinationURL: URL,
    interruption: ((AtomicWriteCheckpoint) throws -> Void)? = nil
  ) throws {
    let destinationURL = destinationURL.standardizedFileURL
    let parentURL = destinationURL.deletingLastPathComponent()
    guard parentURL.path != destinationURL.path else {
      throw AtomicFileWriterError.destinationHasNoParent
    }

    do {
      try FileManager.default.createDirectory(
        at: parentURL,
        withIntermediateDirectories: true
      )
    } catch {
      throw AtomicFileWriterError.cannotCreateParent
    }

    let partialURL = siblingPartialURL(for: destinationURL)
    let fileDescriptor = partialURL.withUnsafeFileSystemRepresentation { path in
      audora_open_atomic_partial(path)
    }
    guard fileDescriptor >= 0 else {
      throw AtomicFileWriterError.cannotOpenPartial(errno)
    }

    var isOpen = true
    defer {
      if isOpen {
        audora_close_descriptor(fileDescriptor)
      }
    }

    guard audora_set_private_file_permissions(fileDescriptor) == 0 else {
      throw AtomicFileWriterError.cannotSecurePartial(errno)
    }

    try writeAll(data, to: fileDescriptor)
    try interruption?(.partialWritten)

    guard audora_sync_descriptor(fileDescriptor) == 0 else {
      throw AtomicFileWriterError.cannotFlushPartial(errno)
    }
    try interruption?(.partialFlushed)

    guard audora_close_descriptor(fileDescriptor) == 0 else {
      isOpen = false
      throw AtomicFileWriterError.cannotClosePartial(errno)
    }
    isOpen = false

    let renameResult = partialURL.withUnsafeFileSystemRepresentation { partialPath in
      destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
        audora_rename_atomic(partialPath, destinationPath)
      }
    }
    guard renameResult == 0 else {
      throw AtomicFileWriterError.cannotInstallFinal(errno)
    }
    try interruption?(.finalInstalled)

    try flushDirectory(parentURL)
    try interruption?(.directoryFlushed)
  }

  public func readInstalledFile(at destinationURL: URL) throws -> Data? {
    let destinationURL = destinationURL.standardizedFileURL
    guard FileManager.default.fileExists(atPath: destinationURL.path) else {
      return nil
    }
    return try Data(contentsOf: destinationURL)
  }

  public func siblingPartialURL(for destinationURL: URL) -> URL {
    destinationURL.deletingLastPathComponent().appendingPathComponent(
      destinationURL.lastPathComponent + ".partial",
      isDirectory: false
    )
  }

  private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        return
      }

      var writtenByteCount = 0
      while writtenByteCount < rawBuffer.count {
        let result = audora_write_bytes(
          fileDescriptor,
          baseAddress.advanced(by: writtenByteCount),
          rawBuffer.count - writtenByteCount
        )
        if result < 0 {
          if errno == EINTR {
            continue
          }
          throw AtomicFileWriterError.cannotWritePartial(errno)
        }
        guard result > 0 else {
          throw AtomicFileWriterError.cannotWritePartial(EIO)
        }
        writtenByteCount += result
      }
    }
  }

  private func flushDirectory(_ directoryURL: URL) throws {
    let directoryDescriptor = directoryURL.withUnsafeFileSystemRepresentation { path in
      audora_open_directory_for_sync(path)
    }
    guard directoryDescriptor >= 0 else {
      throw AtomicFileWriterError.cannotOpenParent(errno)
    }
    defer { audora_close_descriptor(directoryDescriptor) }

    guard audora_sync_descriptor(directoryDescriptor) == 0 else {
      throw AtomicFileWriterError.cannotFlushParent(errno)
    }
  }
}
