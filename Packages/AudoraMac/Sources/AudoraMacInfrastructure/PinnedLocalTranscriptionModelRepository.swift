import AudoraApplication
import AudoraDomain
import CryptoKit
import Darwin
import Foundation

public enum PinnedTranscriptionModelManifestError: Error, Equatable, Sendable {
    case invalidManifest
}

public enum ConfinedTranscriptionModelCapabilityError: Error, Equatable, Sendable {
    case snapshotUnavailable
}

/// Exact, path-free model authority handed to a post-handshake worker session.
/// The caller owns every descriptor returned by `duplicateReadOnlyFileDescriptors`.
public protocol ConfinedTranscriptionModelExecutionCapability: Sendable {
    var capabilityID: TranscriptionModelCapabilityID { get }
    var profileID: String { get }
    var modelRevision: String { get }
    func duplicateReadOnlyFileDescriptors() throws -> [String: Int32]
}

public protocol ConfinedTranscriptionModelResolving: Sendable {
    func resolveModel(
        _ capability: VerifiedTranscriptionModel,
        profile: QualifiedTranscriptionProfile
    ) async -> (any ConfinedTranscriptionModelExecutionCapability)?
}

fileprivate struct RetainedModelFile: Sendable {
    let descriptor: Int32
    let device: UInt64
    let inode: UInt64
    let byteCount: UInt64
}

private struct PrivateModelSnapshotDirectory {
    let url: URL
    let descriptor: Int32
}

public final class ConfinedPinnedTranscriptionModel:
    ConfinedTranscriptionModelExecutionCapability,
    @unchecked Sendable
{
    public let capabilityID: TranscriptionModelCapabilityID
    public let profileID: String
    public let modelRevision: String
    private let files: [String: RetainedModelFile]

    fileprivate init(
        capabilityID: TranscriptionModelCapabilityID,
        profileID: String,
        modelRevision: String,
        files: [String: RetainedModelFile]
    ) {
        self.capabilityID = capabilityID
        self.profileID = profileID
        self.modelRevision = modelRevision
        self.files = files
    }

    deinit { files.values.forEach { Darwin.close($0.descriptor) } }

    public func duplicateReadOnlyFileDescriptors() throws -> [String: Int32] {
        var duplicates: [String: Int32] = [:]
        do {
            for name in files.keys.sorted() {
                guard let retained = files[name] else {
                    throw ConfinedTranscriptionModelCapabilityError.snapshotUnavailable
                }
                let duplicate = fcntl(retained.descriptor, F_DUPFD_CLOEXEC, 0)
                guard duplicate >= 0 else {
                    throw ConfinedTranscriptionModelCapabilityError.snapshotUnavailable
                }
                duplicates[name] = duplicate
                var metadata = stat()
                guard fstat(duplicate, &metadata) == 0,
                      (metadata.st_mode & S_IFMT) == S_IFREG,
                      UInt64(truncatingIfNeeded: metadata.st_dev) == retained.device,
                      UInt64(truncatingIfNeeded: metadata.st_ino) == retained.inode,
                      metadata.st_size >= 0,
                      UInt64(metadata.st_size) == retained.byteCount,
                      fcntl(duplicate, F_GETFL) & O_ACCMODE == O_RDONLY,
                      lseek(duplicate, 0, SEEK_SET) == 0
                else {
                    throw ConfinedTranscriptionModelCapabilityError.snapshotUnavailable
                }
            }
            return duplicates
        } catch {
            duplicates.values.forEach { Darwin.close($0) }
            throw error
        }
    }
}

public struct PinnedTranscriptionModelManifest: Equatable, Sendable {
    public let profileID: String
    public let modelRevision: String
    public let files: [String: String]

    public init(
        profileID: String,
        modelRevision: String,
        files: [String: String]
    ) throws {
        guard (1...128).contains(profileID.utf8.count),
              (1...128).contains(modelRevision.utf8.count),
              (1...64).contains(files.count),
              files.allSatisfy({ name, hash in
                  !name.isEmpty && name.utf8.count <= 255 &&
                      name != "." && name != ".." &&
                      !name.contains("/") && !name.contains("\\") &&
                      AudioArtifactFingerprint.isSHA256(hash)
              })
        else {
            throw PinnedTranscriptionModelManifestError.invalidManifest
        }
        self.profileID = profileID
        self.modelRevision = modelRevision
        self.files = files
    }

    /// Exact model snapshot declared by the reviewed Crisper engine lock.
    public static let crisperWhisperSmallV1 = try! PinnedTranscriptionModelManifest(
        profileID: "crisperwhisper-2-small-transformers-mps-v1",
        modelRevision: "bcaecf0a584a1f600d8897fe6032b9e2e56429a7",
        files: [
            "LICENSE.md": "c2457a89ec035bccf9ce76f240e1aa4864fef5e7e278b6537a1941649e810ec9",
            "added_tokens.json": "8fe391c3e28b7187905c636c9283dc074dcc4f4c1a2571cd4ff46563a9ebac53",
            "config.json": "b2416b6da125c4dd6f82bb795c8ca628333a5b2ac794ca93e0060d482d541fea",
            "generation_config.json": "6d3620eb703b3ea0c1afecff2cfd50efbf8a0aaf958ea9fe2efc3072060bf209",
            "merges.txt": "087b991adb6a824ca8a588d1aedd10c27eb57861bb428ef3eb49913390f9d5f8",
            "model.safetensors": "ecfcbd3d5dddebf9c79cd9ae774b6f6a5d68a500cdbe1b196ce5b2085912ebdf",
            "normalizer.json": "f8adcae1c635e1df3a0906c4ad0077965d0b14271ef575801395ff3729367a33",
            "preprocessor_config.json": "f0eb56ab411ce429ad4ce2b659ad69d88beea7ec86e6776be87cedabb4279b18",
            "special_tokens_map.json": "2042c39e4822a0dfd7fef9733179ac2b9469108e371ea8947b5b2f72f5faa4f2",
            "tokenizer.json": "53479f2761a4ce747c768a26994e1952736ccfee32baddc2fc44eef8e7228efa",
            "tokenizer_config.json": "dc13205cf65a43efaf2fe4b51c7eb8dbb6635e4acd143679731af8ae513a8823",
            "vocab.json": "f34f9127f6e24bab8ad443abc8b16c8fbca48505b927c8551a56b8315bf40d0b",
        ]
    )
}

/// Optional explicit preparation seam. Production may install only the exact
/// manifest through a separately authorized flow; this repository never
/// discovers caches or downloads on verification.
public protocol PinnedTranscriptionModelPreparing: Sendable {
    func prepare(
        _ action: SessionProcessingRecoveryAction,
        manifest: PinnedTranscriptionModelManifest
    ) async
}

public actor PinnedLocalTranscriptionModelRepository:
    TranscriptionModelPort,
    ConfinedTranscriptionModelResolving
{
    private static let maximumModelFileBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024
    private static let maximumModelSnapshotBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024

    private let root: URL?
    private let manifest: PinnedTranscriptionModelManifest
    private let preparation: (any PinnedTranscriptionModelPreparing)?
    private var binding: (
        verified: VerifiedTranscriptionModel,
        input: ConfinedPinnedTranscriptionModel
    )?

    public init(
        root: URL?,
        manifest: PinnedTranscriptionModelManifest = .crisperWhisperSmallV1,
        preparation: (any PinnedTranscriptionModelPreparing)? = nil
    ) {
        self.root = root
        self.manifest = manifest
        self.preparation = preparation
    }

    /// Exact app-owned installation location. Verification never searches
    /// external model caches or substitutes a neighboring revision.
    public nonisolated static func defaultInstalledRoot(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Audora", isDirectory: true)
            .appendingPathComponent("OfflineModels", isDirectory: true)
            .appendingPathComponent(
                PinnedTranscriptionModelManifest.crisperWhisperSmallV1.profileID,
                isDirectory: true
            )
            .appendingPathComponent(
                PinnedTranscriptionModelManifest.crisperWhisperSmallV1.modelRevision,
                isDirectory: true
            )
    }

    public func verify(_ profile: QualifiedTranscriptionProfile) async
        -> TranscriptionModelResolution
    {
        guard profile.profileID == manifest.profileID,
              profile.modelRevision == manifest.modelRevision
        else {
            binding = nil
            return .lockMismatch
        }
        return verifyInstalledSnapshot(profile: profile)
    }

    public func prepare(
        _ action: SessionProcessingRecoveryAction,
        profile: QualifiedTranscriptionProfile
    ) async -> TranscriptionModelResolution {
        guard action == .prepare || action == .reinstall,
              profile.profileID == manifest.profileID,
              profile.modelRevision == manifest.modelRevision
        else {
            binding = nil
            return .lockMismatch
        }
        await preparation?.prepare(action, manifest: manifest)
        return verifyInstalledSnapshot(profile: profile)
    }

    public func executionCapability(
        for profile: QualifiedTranscriptionProfile
    ) async -> VerifiedTranscriptionModel? {
        guard let binding, binding.verified.isValid(for: profile) else { return nil }
        return binding.verified
    }

    public func resolveModel(
        _ capability: VerifiedTranscriptionModel,
        profile: QualifiedTranscriptionProfile
    ) async -> (any ConfinedTranscriptionModelExecutionCapability)? {
        guard let binding, binding.verified == capability,
              capability.isValid(for: profile),
              binding.input.capabilityID == capability.capabilityID,
              binding.input.profileID == capability.profileID,
              binding.input.modelRevision == capability.modelRevision
        else { return nil }
        return binding.input
    }

    private func verifyInstalledSnapshot(
        profile: QualifiedTranscriptionProfile
    ) -> TranscriptionModelResolution {
        binding = nil
        guard let root else { return .missing }
        let descriptor = root.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            return errno == ENOENT ? .missing : .corrupt
        }
        defer { Darwin.close(descriptor) }
        var retained: [String: RetainedModelFile] = [:]
        var transferred = false
        defer {
            if !transferred {
                retained.values.forEach { Darwin.close($0.descriptor) }
            }
        }
        do {
            let entries = try confined.listEntryNames(
                under: descriptor,
                maximumCount: manifest.files.count
            )
            guard entries == manifest.files.keys.sorted() else { return .corrupt }
            let snapshotDirectory = try Self.createPrivateSnapshotDirectory()
            var snapshotDirectoryRemoved = false
            defer {
                Darwin.close(snapshotDirectory.descriptor)
                if !snapshotDirectoryRemoved {
                    _ = Self.removeSnapshotDirectory(snapshotDirectory.url)
                }
            }
            var snapshotByteCount: UInt64 = 0
            for name in manifest.files.keys.sorted() {
                guard let expectedHash = manifest.files[name] else {
                    return .corrupt
                }
                let (remainingSnapshotBytes, underflow) = Self
                    .maximumModelSnapshotBytes.subtractingReportingOverflow(
                        snapshotByteCount
                    )
                guard !underflow else { return .corrupt }
                let file = try Self.makeVerifiedSnapshot(
                    named: name,
                    sourceParent: descriptor,
                    snapshotParent: snapshotDirectory.descriptor,
                    expectedHash: expectedHash,
                    maximumSnapshotBytes: remainingSnapshotBytes
                )
                retained[name] = file
                let (nextSnapshotByteCount, overflow) = snapshotByteCount
                    .addingReportingOverflow(file.byteCount)
                guard !overflow,
                      nextSnapshotByteCount <= Self.maximumModelSnapshotBytes
                else { return .corrupt }
                snapshotByteCount = nextSnapshotByteCount
            }
            guard Self.removeSnapshotDirectory(snapshotDirectory.url) else {
                return .corrupt
            }
            snapshotDirectoryRemoved = true
            let capabilityID = try TranscriptionModelCapabilityID(
                "model-\(UUID().uuidString)"
            )
            let verified = VerifiedTranscriptionModel(
                capabilityID: capabilityID,
                profileID: profile.profileID,
                modelRevision: profile.modelRevision
            )
            let input = ConfinedPinnedTranscriptionModel(
                capabilityID: capabilityID,
                profileID: profile.profileID,
                modelRevision: profile.modelRevision,
                files: retained
            )
            binding = (verified, input)
            transferred = true
            return .ready
        } catch {
            return .corrupt
        }
    }

    private var confined: ConfinedPersistencePrimitives<ModelVerificationFailure> {
        ConfinedPersistencePrimitives(
            ioFailure: .failed,
            invalidLayout: .failed,
            expectedPathIsSymlink: .failed,
            rootTooLarge: .failed,
            invalidJSON: .failed,
            invalidSchemaVersion: .failed,
            unknownKey: .failed
        )
    }

    private static func createPrivateSnapshotDirectory() throws
        -> PrivateModelSnapshotDirectory
    {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            ".audora-model-snapshot-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ModelVerificationFailure.failed
        }
        let modeChanged = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return chmod(path, 0o700) == 0
        }
        guard modeChanged else {
            _ = removeSnapshotDirectory(url)
            throw ModelVerificationFailure.failed
        }
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            _ = removeSnapshotDirectory(url)
            throw ModelVerificationFailure.failed
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0
        else {
            Darwin.close(descriptor)
            _ = removeSnapshotDirectory(url)
            throw ModelVerificationFailure.failed
        }
        return PrivateModelSnapshotDirectory(url: url, descriptor: descriptor)
    }

    private static func removeSnapshotDirectory(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.rmdir(path) == 0
        }
    }

    private static func makeVerifiedSnapshot(
        named name: String,
        sourceParent: Int32,
        snapshotParent: Int32,
        expectedHash: String,
        maximumSnapshotBytes: UInt64
    ) throws -> RetainedModelFile {
        let source = name.withCString {
            Darwin.openat(
                sourceParent,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard source >= 0 else { throw ModelVerificationFailure.failed }
        defer { Darwin.close(source) }
        var sourceMetadata = stat()
        guard fstat(source, &sourceMetadata) == 0,
              (sourceMetadata.st_mode & S_IFMT) == S_IFREG,
              sourceMetadata.st_size >= 0,
              UInt64(sourceMetadata.st_size) <= maximumModelFileBytes,
              UInt64(sourceMetadata.st_size) <= maximumSnapshotBytes
        else {
            throw ModelVerificationFailure.failed
        }

        var writer = name.withCString { pointer -> Int32 in
            while true {
                let result = Darwin.openat(
                    snapshotParent,
                    pointer,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard writer >= 0 else { throw ModelVerificationFailure.failed }
        var snapshotLinked = true
        defer {
            if writer >= 0 { Darwin.close(writer) }
            if snapshotLinked { _ = unlinkat(snapshotParent, name, 0) }
        }

        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var copiedBytes: UInt64 = 0
        while true {
            let count = Darwin.read(source, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ModelVerificationFailure.failed
            }
            let (nextCopiedBytes, overflow) = copiedBytes.addingReportingOverflow(
                UInt64(count)
            )
            guard !overflow,
                  nextCopiedBytes <= UInt64(sourceMetadata.st_size),
                  nextCopiedBytes <= maximumSnapshotBytes
            else { throw ModelVerificationFailure.failed }
            try writeAll(buffer, byteCount: count, to: writer)
            digest.update(data: Data(buffer[0..<count]))
            copiedBytes = nextCopiedBytes
        }
        let measured = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard copiedBytes == UInt64(sourceMetadata.st_size),
              measured == expectedHash,
              fsync(writer) == 0,
              fchmod(writer, mode_t(S_IRUSR)) == 0
        else {
            throw ModelVerificationFailure.failed
        }
        let completedWriter = writer
        writer = -1
        guard Darwin.close(completedWriter) == 0 else {
            throw ModelVerificationFailure.failed
        }

        let snapshot = name.withCString {
            Darwin.openat(
                snapshotParent,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard snapshot >= 0 else { throw ModelVerificationFailure.failed }
        var snapshotTransferred = false
        defer { if !snapshotTransferred { Darwin.close(snapshot) } }
        var snapshotMetadata = stat()
        guard fstat(snapshot, &snapshotMetadata) == 0,
              (snapshotMetadata.st_mode & S_IFMT) == S_IFREG,
              snapshotMetadata.st_size == sourceMetadata.st_size,
              snapshotMetadata.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) == 0,
              fcntl(snapshot, F_GETFL) & O_ACCMODE == O_RDONLY,
              unlinkat(snapshotParent, name, 0) == 0,
              lseek(snapshot, 0, SEEK_SET) == 0
        else { throw ModelVerificationFailure.failed }
        snapshotLinked = false
        snapshotTransferred = true
        return RetainedModelFile(
            descriptor: snapshot,
            device: UInt64(truncatingIfNeeded: snapshotMetadata.st_dev),
            inode: UInt64(truncatingIfNeeded: snapshotMetadata.st_ino),
            byteCount: UInt64(snapshotMetadata.st_size)
        )
    }

    private static func writeAll(
        _ buffer: [UInt8],
        byteCount: Int,
        to descriptor: Int32
    ) throws {
        let success = buffer.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return byteCount == 0 }
            var offset = 0
            while offset < byteCount {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    byteCount - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if count == 0 { return false }
                offset += count
            }
            return true
        }
        guard success else { throw ModelVerificationFailure.failed }
    }
}

private enum ModelVerificationFailure: Error {
    case failed
}
