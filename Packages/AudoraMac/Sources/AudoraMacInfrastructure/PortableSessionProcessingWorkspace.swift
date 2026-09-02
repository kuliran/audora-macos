import AudoraApplication
import AudoraDomain
import CryptoKit
import Darwin
import Foundation

public enum ConfinedCanonicalAudioInputError: Error, Equatable, Sendable {
    case invalidCanonicalAudio
    case snapshotUnavailable
}

/// Anonymous, read-only descriptor authority for one already-verified
/// canonical WAV. No filesystem path survives construction, so an execution
/// host can bind this exact open description as `input/audio.wav` without
/// rediscovering Session state from ambient identifiers.
public final class ConfinedCanonicalAudioInput: @unchecked Sendable, Equatable {
    public let capabilityID: SessionTranscriptionAudioCapabilityID
    public let fingerprint: AudioFingerprint
    public let byteCount: UInt64
    private let descriptor: Int32

    init(
        copyingVerifiedCanonicalWAV data: Data,
        capabilityID: SessionTranscriptionAudioCapabilityID,
        fingerprint: AudioFingerprint
    ) throws {
        guard Self.sha256(data) == fingerprint.sha256,
              Self.isCanonicalWAV(data)
        else { throw ConfinedCanonicalAudioInputError.invalidCanonicalAudio }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-transcription-\(UUID().uuidString).wav",
            isDirectory: false
        )
        let writer = temporary.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard writer >= 0 else {
            throw ConfinedCanonicalAudioInputError.snapshotUnavailable
        }
        var reader: Int32 = -1
        defer {
            Darwin.close(writer)
            if reader < 0 {
                temporary.withUnsafeFileSystemRepresentation { path in
                    if let path { _ = Darwin.unlink(path) }
                }
            }
        }
        do {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else {
                    throw ConfinedCanonicalAudioInputError.snapshotUnavailable
                }
                var written = 0
                while written < raw.count {
                    let count = Darwin.write(
                        writer,
                        base.advanced(by: written),
                        raw.count - written
                    )
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw ConfinedCanonicalAudioInputError.snapshotUnavailable
                    }
                    guard count > 0 else {
                        throw ConfinedCanonicalAudioInputError.snapshotUnavailable
                    }
                    written += count
                }
            }
            while fsync(writer) != 0 {
                if errno == EINTR { continue }
                throw ConfinedCanonicalAudioInputError.snapshotUnavailable
            }
            while fchmod(writer, S_IRUSR) != 0 {
                if errno == EINTR { continue }
                throw ConfinedCanonicalAudioInputError.snapshotUnavailable
            }
            reader = temporary.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard reader >= 0 else {
                throw ConfinedCanonicalAudioInputError.snapshotUnavailable
            }
            var writerMetadata = stat()
            var readerMetadata = stat()
            guard fstat(writer, &writerMetadata) == 0,
                  fstat(reader, &readerMetadata) == 0,
                  (writerMetadata.st_mode & S_IFMT) == S_IFREG,
                  (readerMetadata.st_mode & S_IFMT) == S_IFREG,
                  writerMetadata.st_dev == readerMetadata.st_dev,
                  writerMetadata.st_ino == readerMetadata.st_ino,
                  writerMetadata.st_size == data.count,
                  readerMetadata.st_size == data.count,
                  try Self.sha256(descriptor: reader) == fingerprint.sha256
            else {
                throw ConfinedCanonicalAudioInputError.snapshotUnavailable
            }
            temporary.withUnsafeFileSystemRepresentation { path in
                if let path { _ = Darwin.unlink(path) }
            }
        } catch {
            if reader >= 0 {
                Darwin.close(reader)
                reader = -1
            }
            throw error
        }
        self.capabilityID = capabilityID
        self.fingerprint = fingerprint
        byteCount = UInt64(data.count)
        descriptor = reader
    }

    deinit { Darwin.close(descriptor) }

    /// The caller owns the returned descriptor. It is a distinct read-only
    /// open description positioned at byte zero, so concurrent worker staging
    /// cannot move another invocation's file offset.
    public func duplicateReadOnlyFileDescriptor() throws -> Int32 {
        var sourceMetadata = stat()
        guard fstat(descriptor, &sourceMetadata) == 0,
              (sourceMetadata.st_mode & S_IFMT) == S_IFREG,
              sourceMetadata.st_size >= 0,
              UInt64(sourceMetadata.st_size) == byteCount
        else {
            throw ConfinedCanonicalAudioInputError.snapshotUnavailable
        }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-transcription-duplicate-\(UUID().uuidString).wav",
            isDirectory: false
        )
        let writer = temporary.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard writer >= 0 else {
            throw ConfinedCanonicalAudioInputError.snapshotUnavailable
        }
        var reader: Int32 = -1
        defer {
            Darwin.close(writer)
            temporary.withUnsafeFileSystemRepresentation { path in
                if let path { _ = Darwin.unlink(path) }
            }
        }
        do {
            var offset = 0
            var buffer = [UInt8](repeating: 0, count: 1_048_576)
            while offset < Int(sourceMetadata.st_size) {
                let requested = min(
                    buffer.count,
                    Int(sourceMetadata.st_size) - offset
                )
                let readCount = buffer.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.pread(
                        descriptor,
                        base,
                        requested,
                        off_t(offset)
                    )
                }
                if readCount < 0 {
                    if errno == EINTR { continue }
                    throw ConfinedCanonicalAudioInputError.snapshotUnavailable
                }
                guard readCount > 0 else {
                    throw ConfinedCanonicalAudioInputError.snapshotUnavailable
                }
                var chunkOffset = 0
                while chunkOffset < readCount {
                    let written = buffer.withUnsafeBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return -1 }
                        return Darwin.write(
                            writer,
                            base.advanced(by: chunkOffset),
                            readCount - chunkOffset
                        )
                    }
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw ConfinedCanonicalAudioInputError.snapshotUnavailable
                    }
                    guard written > 0 else {
                        throw ConfinedCanonicalAudioInputError.snapshotUnavailable
                    }
                    chunkOffset += written
                }
                offset += readCount
            }
            var finalSourceMetadata = stat()
            guard fstat(descriptor, &finalSourceMetadata) == 0,
                  finalSourceMetadata.st_dev == sourceMetadata.st_dev,
                  finalSourceMetadata.st_ino == sourceMetadata.st_ino,
                  finalSourceMetadata.st_size == sourceMetadata.st_size
            else { throw ConfinedCanonicalAudioInputError.snapshotUnavailable }
            while fsync(writer) != 0 {
                if errno == EINTR { continue }
                throw ConfinedCanonicalAudioInputError.snapshotUnavailable
            }
            while fchmod(writer, S_IRUSR) != 0 {
                if errno == EINTR { continue }
                throw ConfinedCanonicalAudioInputError.snapshotUnavailable
            }
            reader = temporary.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard reader >= 0 else {
                throw ConfinedCanonicalAudioInputError.snapshotUnavailable
            }
            var writerMetadata = stat()
            var readerMetadata = stat()
            guard fstat(writer, &writerMetadata) == 0,
                  fstat(reader, &readerMetadata) == 0,
                  (writerMetadata.st_mode & S_IFMT) == S_IFREG,
                  (readerMetadata.st_mode & S_IFMT) == S_IFREG,
                  writerMetadata.st_dev == readerMetadata.st_dev,
                  writerMetadata.st_ino == readerMetadata.st_ino,
                  writerMetadata.st_size == sourceMetadata.st_size,
                  readerMetadata.st_size == sourceMetadata.st_size,
                  try Self.sha256(descriptor: reader) == fingerprint.sha256
            else {
                throw ConfinedCanonicalAudioInputError.snapshotUnavailable
            }
            temporary.withUnsafeFileSystemRepresentation { path in
                if let path { _ = Darwin.unlink(path) }
            }
            let result = reader
            reader = -1
            return result
        } catch {
            if reader >= 0 {
                Darwin.close(reader)
                reader = -1
            }
            throw error
        }
    }

    public static func == (
        lhs: ConfinedCanonicalAudioInput,
        rhs: ConfinedCanonicalAudioInput
    ) -> Bool {
        lhs.capabilityID == rhs.capabilityID &&
            lhs.fingerprint == rhs.fingerprint &&
            lhs.byteCount == rhs.byteCount
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(descriptor: Int32) throws -> String {
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var offset = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.pread(descriptor, base, raw.count, off_t(offset))
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ConfinedCanonicalAudioInputError.snapshotUnavailable
            }
            digest.update(data: Data(buffer[0..<count]))
            offset += count
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isCanonicalWAV(_ data: Data) -> Bool {
        guard data.count >= 46,
              Array(data[0..<4]) == Array("RIFF".utf8),
              Array(data[8..<12]) == Array("WAVE".utf8),
              Array(data[12..<16]) == Array("fmt ".utf8),
              littleEndianUInt32(data, 4) == UInt32(data.count - 8),
              littleEndianUInt32(data, 16) == 16,
              littleEndianUInt16(data, 20) == 1,
              littleEndianUInt16(data, 22) == 1,
              littleEndianUInt32(data, 24) == 16_000,
              littleEndianUInt32(data, 28) == 32_000,
              littleEndianUInt16(data, 32) == 2,
              littleEndianUInt16(data, 34) == 16,
              Array(data[36..<40]) == Array("data".utf8),
              let payload = littleEndianUInt32(data, 40),
              Int(payload) == data.count - 44,
              payload > 0,
              payload.isMultiple(of: 2)
        else { return false }
        return UInt64(payload / 2) <= CanonicalAudioFormat.maximumFrameCount
    }

    private static func littleEndianUInt16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func littleEndianUInt32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}

public protocol ConfinedTranscriptionAudioResolving: Sendable {
    func resolveAudio(
        capabilityID: SessionTranscriptionAudioCapabilityID,
        selection: SessionProcessingSelection,
        fingerprint: AudioFingerprint
    ) async -> ConfinedCanonicalAudioInput?
}

/// Active-Library composition boundary shared by source reconstruction, jobs,
/// immutable Revision publication, and worker-audio capability resolution.
/// Binding these roles in one actor prevents a command from mixing roots.
public actor PortableSessionProcessingWorkspace:
    SessionTranscriptionSourcePort,
    SessionProcessingJobPort,
    TranscriptRevisionRepository,
    ConfinedTranscriptionAudioResolving
{
    private struct Binding {
        let selection: SessionProcessingSelection
        let scope: ActiveLibraryProcessingScope
        let reconciliationID: SessionProcessingReconciliationID?
        let revisions: PortableTranscriptRevisionRepository
        let jobs: PortableSessionProcessingJobRepository
        let audio: ConfinedCanonicalAudioInput
    }

    /// Source reconstruction can fail while a durable validating Job still
    /// needs a deterministic terminal transition. Keep that source-independent
    /// authority separate from the audio/publication binding so failure never
    /// grants transcription or publication capabilities.
    private struct JobBinding {
        let selection: SessionProcessingSelection
        let scope: ActiveLibraryProcessingScope
        let jobs: PortableSessionProcessingJobRepository
    }

    private struct ReconciliationBinding {
        let reconciliationID: SessionProcessingReconciliationID
        let scope: LibraryScope
        let active: ActiveLibraryProcessingScope
        let jobs: PortableSessionProcessingJobRepository
        let jobIDs: Set<TranscriptionJobID>
    }

    private let scopes: any SessionProcessingLibraryScopeProviding
    private var binding: Binding?
    private var jobBinding: JobBinding?
    private var reconciliationBinding: ReconciliationBinding?
    private var reconciliationSessionBinding: Binding?

    public init(scopes: any SessionProcessingLibraryScopeProviding) {
        self.scopes = scopes
    }

    public func load(
        _ selection: SessionProcessingSelection
    ) async -> SessionTranscriptionSourceResult {
        binding = nil
        jobBinding = nil
        reconciliationBinding = nil
        reconciliationSessionBinding = nil
        guard let active = await scopes.acquireSessionProcessingScope(
            for: selection.scope
        ) else {
            return .unavailable
        }
        jobBinding = JobBinding(
            selection: selection,
            scope: active,
            jobs: PortableSessionProcessingJobRepository(
                root: active.root,
                libraryID: selection.scope.libraryID,
                expectedRootIdentity: active.identity.rootIdentity
            )
        )
        return await load(
            selection,
            active: active,
            reconciliationID: nil
        )
    }

    public func load(
        _ selection: SessionProcessingSelection,
        reconciliationID: SessionProcessingReconciliationID
    ) async -> SessionTranscriptionSourceResult {
        guard let reconciliationBinding,
              reconciliationBinding.reconciliationID == reconciliationID,
              reconciliationBinding.scope == selection.scope,
              await scopes.isCurrentSessionProcessingScope(
                  reconciliationBinding.active.identity
              )
        else { return .unavailable }
        return await load(
            selection,
            active: reconciliationBinding.active,
            reconciliationID: reconciliationID
        )
    }

    public func inventory(
        for scope: LibraryScope
    ) async -> SessionProcessingJobInventoryResult {
        reconciliationBinding = nil
        reconciliationSessionBinding = nil
        guard let active = await scopes.acquireSessionProcessingScope(for: scope) else {
            return .unavailable
        }
        guard let reconciliationID = try? SessionProcessingReconciliationID(
            "reconcile-\(UUID().uuidString)"
        ) else { return .integrityMismatch }
        let repository = PortableSessionProcessingJobRepository(
            root: active.root,
            libraryID: scope.libraryID,
            expectedRootIdentity: active.identity.rootIdentity
        )
        let result: SessionProcessingJobInventoryResult
        do {
            result = try await scopes.withCurrentSessionProcessingScope(active.identity) {
                repository.inventorySynchronously(
                    for: scope,
                    reconciliationID: reconciliationID
                )
            }
        } catch {
            return .unavailable
        }
        guard await scopes.isCurrentSessionProcessingScope(active.identity) else {
            return .unavailable
        }
        guard case let .available(inventory) = result,
              inventory.reconciliationID == reconciliationID,
              inventory.scope == scope
        else { return result }
        reconciliationBinding = ReconciliationBinding(
            reconciliationID: reconciliationID,
            scope: scope,
            active: active,
            jobs: repository,
            jobIDs: Set(inventory.jobs.map(\.jobID))
        )
        return result
    }

    public func finishReconciliation(
        _ reconciliationID: SessionProcessingReconciliationID
    ) async {
        guard reconciliationBinding?.reconciliationID == reconciliationID else {
            return
        }
        reconciliationBinding = nil
        if reconciliationSessionBinding?.reconciliationID == reconciliationID {
            reconciliationSessionBinding = nil
        }
    }

    private func load(
        _ selection: SessionProcessingSelection,
        active: ActiveLibraryProcessingScope,
        reconciliationID: SessionProcessingReconciliationID?
    ) async -> SessionTranscriptionSourceResult {
        if reconciliationID == nil {
            binding = nil
        } else {
            reconciliationSessionBinding = nil
        }
        let root = active.root
        let revisions = PortableTranscriptRevisionRepository(
            root: root,
            libraryID: selection.scope.libraryID,
            expectedRootIdentity: active.identity.rootIdentity
        )
        let read: PortableSessionTranscriptionRead
        do {
            read = try await scopes.withCurrentSessionProcessingScope(
                active.identity
            ) {
                revisions.loadTranscriptionAudioSynchronously(for: selection)
            }
        } catch {
            return .unavailable
        }
        guard await scopes.isCurrentSessionProcessingScope(active.identity) else {
            return .unavailable
        }
        switch read {
        case let .available(verified):
            do {
                let capabilityID = try SessionTranscriptionAudioCapabilityID(
                    "cap-\(UUID().uuidString)"
                )
                let audio = try ConfinedCanonicalAudioInput(
                    copyingVerifiedCanonicalWAV: verified.canonicalWAV,
                    capabilityID: capabilityID,
                    fingerprint: verified.audioFingerprint
                )
                guard await scopes.isCurrentSessionProcessingScope(active.identity)
                else { return .unavailable }
                let nextBinding = Binding(
                    selection: selection,
                    scope: active,
                    reconciliationID: reconciliationID,
                    revisions: revisions,
                    jobs: PortableSessionProcessingJobRepository(
                        root: root,
                        libraryID: selection.scope.libraryID,
                        expectedRootIdentity: active.identity.rootIdentity
                    ),
                    audio: audio
                )
                if reconciliationID == nil {
                    binding = nextBinding
                } else {
                    reconciliationSessionBinding = nextBinding
                }
                return .available(
                    SessionTranscriptionSource(
                        selection: selection,
                        audioCapabilityID: capabilityID,
                        durationMilliseconds: verified.durationMilliseconds,
                        audioFingerprint: verified.audioFingerprint,
                        sourceFingerprints: verified.sourceFingerprints,
                        expectedSelectedRevisionID: verified.expectedSelectedRevisionID
                    )
                )
            } catch {
                if reconciliationID == nil {
                    binding = nil
                } else {
                    reconciliationSessionBinding = nil
                }
                return .integrityMismatch
            }
        case .unavailable:
            return .unavailable
        case .integrityMismatch:
            return .integrityMismatch
        }
    }

    public func latest(
        for selection: SessionProcessingSelection
    ) async -> SessionProcessingJobLoadResult {
        guard let jobBinding = await jobBinding(for: selection) else {
            return .unavailable
        }
        do {
            let result = try await scopes.withCurrentSessionProcessingScope(
                jobBinding.scope.identity
            ) {
                jobBinding.jobs.latestSynchronously(for: selection)
            }
            guard await scopes.isCurrentSessionProcessingScope(
                jobBinding.scope.identity
            )
            else { return .unavailable }
            return result
        } catch {
            return .unavailable
        }
    }

    public func load(
        jobID: TranscriptionJobID,
        for selection: SessionProcessingSelection
    ) async -> SessionProcessingJobLoadResult {
        if let reconciliationBinding,
           reconciliationBinding.scope == selection.scope
        {
            guard reconciliationBinding.jobIDs.contains(jobID) else { return .none }
            guard await scopes.isCurrentSessionProcessingScope(
                reconciliationBinding.active.identity
            ) else { return .unavailable }
            do {
                let result = try await scopes.withCurrentSessionProcessingScope(
                    reconciliationBinding.active.identity
                ) {
                    reconciliationBinding.jobs.loadSynchronously(
                        jobID: jobID,
                        for: selection
                    )
                }
                guard await scopes.isCurrentSessionProcessingScope(
                    reconciliationBinding.active.identity
                ) else { return .unavailable }
                return result
            } catch {
                return .unavailable
            }
        }
        guard let jobBinding = await jobBinding(for: selection) else {
            return .unavailable
        }
        do {
            let result = try await scopes.withCurrentSessionProcessingScope(
                jobBinding.scope.identity
            ) {
                jobBinding.jobs.loadSynchronously(jobID: jobID, for: selection)
            }
            guard await scopes.isCurrentSessionProcessingScope(
                jobBinding.scope.identity
            ) else { return .unavailable }
            return result
        } catch {
            return .unavailable
        }
    }

    /// Durable Job identity is readable without first reconstructing sealed
    /// Session audio. Validation recovery must prove its staged artifact before
    /// consulting that mutable source capability.
    private func jobBinding(
        for selection: SessionProcessingSelection
    ) async -> JobBinding? {
        if let jobBinding,
           jobBinding.selection == selection,
           await scopes.isCurrentSessionProcessingScope(jobBinding.scope.identity)
        {
            return jobBinding
        }
        guard let active = await scopes.acquireSessionProcessingScope(
            for: selection.scope
        ) else {
            jobBinding = nil
            return nil
        }
        let next = JobBinding(
            selection: selection,
            scope: active,
            jobs: PortableSessionProcessingJobRepository(
                root: active.root,
                libraryID: selection.scope.libraryID,
                expectedRootIdentity: active.identity.rootIdentity
            )
        )
        jobBinding = next
        return next
    }

    public func create(
        _ job: SessionProcessingJob
    ) async -> SessionProcessingJobWriteResult {
        guard let binding, binding.selection.sessionID == job.sessionID,
              await scopes.isCurrentSessionProcessingScope(binding.scope.identity)
        else { return .failed }
        do {
            let result = try await scopes.withCurrentSessionProcessingScope(
                binding.scope.identity
            ) {
                binding.jobs.createSynchronously(job)
            }
            guard await scopes.isCurrentSessionProcessingScope(binding.scope.identity)
            else { return .failed }
            return result
        } catch {
            return .failed
        }
    }

    public func transition(
        _ job: SessionProcessingJob,
        from expected: SessionProcessingJobState
    ) async -> SessionProcessingJobWriteResult {
        if let reconciliationBinding,
           reconciliationBinding.jobIDs.contains(job.jobID),
           await scopes.isCurrentSessionProcessingScope(
               reconciliationBinding.active.identity
           )
        {
            do {
                let result = try await scopes.withCurrentSessionProcessingScope(
                    reconciliationBinding.active.identity
                ) {
                    reconciliationBinding.jobs.transitionSynchronously(
                        job,
                        from: expected
                    )
                }
                guard await scopes.isCurrentSessionProcessingScope(
                    reconciliationBinding.active.identity
                ) else { return .failed }
                return result
            } catch {
                return .failed
            }
        }
        guard let jobBinding, jobBinding.selection.sessionID == job.sessionID,
              await scopes.isCurrentSessionProcessingScope(jobBinding.scope.identity)
        else { return .failed }
        do {
            let result = try await scopes.withCurrentSessionProcessingScope(
                jobBinding.scope.identity
            ) {
                jobBinding.jobs.transitionSynchronously(job, from: expected)
            }
            guard await scopes.isCurrentSessionProcessingScope(
                jobBinding.scope.identity
            )
            else { return .failed }
            return result
        } catch {
            return .failed
        }
    }

    public func publishAndSelect(
        _ revision: TranscriptRevision,
        expectedSelectedRevisionID: TranscriptRevisionID?
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        guard let binding = sessionBinding(for: revision.sessionID),
              await scopes.isCurrentSessionProcessingScope(binding.scope.identity)
        else { throw TranscriptRevisionRepositoryFailure.sessionUnavailable }
        let result = try await scopes.withCurrentSessionProcessingScope(
            binding.scope.identity
        ) {
            try binding.revisions.publishAndSelectSynchronously(
                revision,
                expectedSelectedRevisionID: expectedSelectedRevisionID
            )
        }
        guard await scopes.isCurrentSessionProcessingScope(binding.scope.identity)
        else { throw TranscriptRevisionRepositoryFailure.installedNeedsRefresh }
        return result
    }

    public func reopenSelected(
        sessionID: SessionID
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        guard let binding = sessionBinding(for: sessionID),
              await scopes.isCurrentSessionProcessingScope(binding.scope.identity)
        else { throw TranscriptRevisionRepositoryFailure.sessionUnavailable }
        let result = try await scopes.withCurrentSessionProcessingScope(
            binding.scope.identity
        ) {
            try binding.revisions.reopenSelectedSynchronously(sessionID: sessionID)
        }
        guard await scopes.isCurrentSessionProcessingScope(binding.scope.identity)
        else { throw TranscriptRevisionRepositoryFailure.sessionUnavailable }
        return result
    }

    public func reopenRevision(
        sessionID: SessionID,
        revisionID: TranscriptRevisionID
    ) async throws -> TranscriptRevision {
        guard let binding = sessionBinding(for: sessionID),
              await scopes.isCurrentSessionProcessingScope(binding.scope.identity)
        else { throw TranscriptRevisionRepositoryFailure.sessionUnavailable }
        let result = try await scopes.withCurrentSessionProcessingScope(
            binding.scope.identity
        ) {
            try binding.revisions.reopenRevisionSynchronously(
                sessionID: sessionID,
                revisionID: revisionID
            )
        }
        guard await scopes.isCurrentSessionProcessingScope(binding.scope.identity)
        else { throw TranscriptRevisionRepositoryFailure.sessionUnavailable }
        return result
    }

    public func resolveAudio(
        capabilityID: SessionTranscriptionAudioCapabilityID,
        selection: SessionProcessingSelection,
        fingerprint: AudioFingerprint
    ) async -> ConfinedCanonicalAudioInput? {
        let candidates = [reconciliationSessionBinding, binding].compactMap { $0 }
        guard let binding = candidates.first(where: {
            $0.selection == selection && $0.audio.capabilityID == capabilityID &&
                $0.audio.fingerprint == fingerprint
        }),
              await scopes.isCurrentSessionProcessingScope(binding.scope.identity)
        else { return nil }
        return binding.audio
    }

    private func sessionBinding(for sessionID: SessionID) -> Binding? {
        if let reconciliationSessionBinding,
           reconciliationSessionBinding.selection.sessionID == sessionID
        {
            return reconciliationSessionBinding
        }
        guard let binding, binding.selection.sessionID == sessionID else { return nil }
        return binding
    }
}

extension SystemLibraryClock: SessionProcessingClock {}

public struct QualificationBlockedSessionAcousticEvidence:
    SessionAcousticEvidencePort
{
    public init() {}

    public func resolve(
        for source: SessionTranscriptionSource,
        profile: QualifiedTranscriptionProfile
    ) async -> SessionAcousticEvidenceResolution {
        .unavailable
    }
}

public struct RandomSessionProcessingIDGenerator: SessionProcessingIDGenerator {
    private static let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public init() {}

    public func generateJobID(at instant: UTCInstant) async -> TranscriptionJobID {
        try! TranscriptionJobID(Self.identifier(prefix: "job-", instant: instant))
    }

    public func generateRevisionID(at instant: UTCInstant) async -> TranscriptRevisionID {
        try! TranscriptRevisionID(Self.identifier(prefix: "trv-", instant: instant))
    }

    public func generateCancellationAuthorityID(
        at instant: UTCInstant
    ) async -> TranscriptionCancellationAuthorityID {
        try! TranscriptionCancellationAuthorityID(
            Self.identifier(prefix: "cancel-", instant: instant)
        )
    }

    private static func identifier(prefix: String, instant: UTCInstant) -> String {
        let compact = instant.rawValue
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
        var generator = SystemRandomNumberGenerator()
        let suffix = String((0..<4).map { _ in
            crockford.randomElement(using: &generator)!
        })
        return "\(prefix)\(compact)-\(suffix)"
    }
}
