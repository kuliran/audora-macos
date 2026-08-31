import AudoraApplication
import AudoraDomain
import Darwin
import Foundation

@_silgen_name("flock")
private func sessionProcessingJobFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Portable, descriptor-confined durable job state. Each state change is a
/// compare-and-swap under the job directory lock; no caller can replace an
/// unobserved state. Issue #16 can deepen reconciliation behind this same port.
public struct PortableSessionProcessingJobRepository: SessionProcessingJobPort,
    @unchecked Sendable
{
    private static let maximumJobBytes = 65_536
    private static let maximumJobCount = 10_000

    private let root: URL
    private let libraryID: LibraryID

    public init(root: URL, libraryID: LibraryID) {
        self.root = root
        self.libraryID = libraryID
    }

    public func latest(
        for selection: SessionProcessingSelection
    ) async -> SessionProcessingJobLoadResult {
        latestSynchronously(for: selection)
    }

    func latestSynchronously(
        for selection: SessionProcessingSelection
    ) -> SessionProcessingJobLoadResult {
        guard selection.scope.libraryID == libraryID else { return .unavailable }
        do {
            return try withJobs(exclusive: false) { authority in
                let names = try confined.listEntryNames(
                    under: authority.jobsDescriptor,
                    maximumCount: Self.maximumJobCount
                )
                var latest: SessionProcessingJob?
                for name in names {
                    guard let jobID = try? TranscriptionJobID(name) else {
                        throw JobPersistenceError.integrityMismatch
                    }
                    let job = try loadJob(
                        named: name,
                        under: authority.jobsDescriptor
                    )
                    guard job.jobID == jobID else {
                        throw JobPersistenceError.integrityMismatch
                    }
                    guard job.sessionID == selection.sessionID else { continue }
                    if let current = latest {
                        if (job.createdAt.rawValue, job.jobID.rawValue) >
                            (current.createdAt.rawValue, current.jobID.rawValue)
                        {
                            latest = job
                        }
                    } else {
                        latest = job
                    }
                }
                try revalidate(authority)
                return latest.map(SessionProcessingJobLoadResult.loaded) ?? .none
            }
        } catch JobPersistenceError.unavailable {
            return .unavailable
        } catch {
            return .integrityMismatch
        }
    }

    public func create(
        _ job: SessionProcessingJob
    ) async -> SessionProcessingJobWriteResult {
        createSynchronously(job)
    }

    func createSynchronously(
        _ job: SessionProcessingJob
    ) -> SessionProcessingJobWriteResult {
        guard isValid(job), job.state == .queued else { return .failed }
        do {
            return try withJobs(exclusive: true) { authority in
                let name = job.jobID.rawValue
                let partial = ".\(name).partial"
                guard try !confined.entryExists(named: name, under: authority.jobsDescriptor),
                      try !confined.entryExists(
                        named: partial,
                        under: authority.jobsDescriptor
                      )
                else { return .collision }

                guard mkdirat(authority.jobsDescriptor, partial, 0o700) == 0 else {
                    return errno == EEXIST ? .collision : .failed
                }
                var ownsPartial = true
                defer {
                    if ownsPartial {
                        removePartial(named: partial, under: authority.jobsDescriptor)
                    }
                }
                let partialDescriptor = try confined.openDirectory(
                    named: partial,
                    under: authority.jobsDescriptor
                )
                defer { Darwin.close(partialDescriptor) }
                let data = try confined.deterministicJSON(JobDTO(job))
                guard data.count <= Self.maximumJobBytes else { return .failed }
                try confined.writeExclusive(
                    data,
                    named: "job.json",
                    under: partialDescriptor,
                    flushBeforeClose: true
                )
                try confined.flush(partialDescriptor)
                try revalidate(authority)
                try confined.renameNoReplace(
                    from: partial,
                    under: authority.jobsDescriptor,
                    to: name,
                    under: authority.jobsDescriptor,
                    collision: .collision
                )
                ownsPartial = false
                try confined.flush(authority.jobsDescriptor)
                return .written(job)
            }
        } catch JobPersistenceError.collision {
            return .collision
        } catch {
            return .failed
        }
    }

    public func transition(
        _ job: SessionProcessingJob,
        from expected: SessionProcessingJobState
    ) async -> SessionProcessingJobWriteResult {
        transitionSynchronously(job, from: expected)
    }

    func transitionSynchronously(
        _ job: SessionProcessingJob,
        from expected: SessionProcessingJobState
    ) -> SessionProcessingJobWriteResult {
        guard isValid(job) else { return .failed }
        do {
            return try withJobs(exclusive: false) { authority in
                let jobDescriptor = try confined.openDirectory(
                    named: job.jobID.rawValue,
                    under: authority.jobsDescriptor
                )
                defer { Darwin.close(jobDescriptor) }
                let jobIdentity = try identity(jobDescriptor)
                try lock(jobDescriptor, operation: LOCK_EX)
                defer { _ = sessionProcessingJobFlock(jobDescriptor, LOCK_UN) }

                guard try confined.listEntryNames(
                    under: jobDescriptor,
                    maximumCount: 1
                ) == ["job.json"] else { return .failed }
                let currentData = try confined.boundedData(
                    named: "job.json",
                    under: jobDescriptor,
                    maximumBytes: Self.maximumJobBytes
                )
                let current = try decode(currentData)
                guard current.state == expected,
                      sameIdentity(current, job)
                else { return .stale }
                guard isAllowedTransition(from: expected, to: job.state),
                      preservesCandidateIntegrity(from: current, to: job)
                else { return .failed }

                let data = try confined.deterministicJSON(JobDTO(job))
                guard data.count <= Self.maximumJobBytes,
                      try !confined.entryExists(
                        named: "job.json.partial",
                        under: jobDescriptor
                      )
                else { return .failed }
                var ownsPartial = true
                defer {
                    if ownsPartial {
                        _ = unlinkat(jobDescriptor, "job.json.partial", 0)
                    }
                }
                try confined.writeExclusive(
                    data,
                    named: "job.json.partial",
                    under: jobDescriptor,
                    flushBeforeClose: true
                )
                let reread = try confined.boundedData(
                    named: "job.json",
                    under: jobDescriptor,
                    maximumBytes: Self.maximumJobBytes
                )
                guard reread == currentData else { return .stale }
                try revalidate(authority)
                try revalidateJob(
                    named: job.jobID.rawValue,
                    identity: jobIdentity,
                    under: authority.jobsDescriptor
                )
                let renameResult = "job.json.partial".withCString { source in
                    "job.json".withCString { destination in
                        Darwin.renameat(
                            jobDescriptor,
                            source,
                            jobDescriptor,
                            destination
                        )
                    }
                }
                guard renameResult == 0 else { return .failed }
                ownsPartial = false
                try confined.flush(jobDescriptor)
                return .written(job)
            }
        } catch JobPersistenceError.unavailable {
            return .failed
        } catch {
            return .failed
        }
    }
}

private extension PortableSessionProcessingJobRepository {
    struct RootAuthority {
        let parentDescriptor: Int32
        let rootDescriptor: Int32
        let rootName: String
        let rootIdentity: FileIdentity
        let jobsDescriptor: Int32
        let jobsIdentity: FileIdentity
    }

    struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    struct JobDTO: Codable {
        let schemaVersion: UInt32
        let jobId: String
        let sessionId: String
        let revisionId: String
        let profileId: String
        let createdAt: String
        let state: String
        let candidateArtifactSha256: String?
        let failure: String?

        init(_ job: SessionProcessingJob) {
            schemaVersion = 1
            jobId = job.jobID.rawValue
            sessionId = job.sessionID.rawValue
            revisionId = job.revisionID.rawValue
            profileId = job.profileID
            createdAt = job.createdAt.rawValue
            state = job.state.rawValue
            candidateArtifactSha256 = job.candidateArtifactSHA256
            failure = job.failure?.rawValue
        }
    }

    func withJobs<T>(
        exclusive: Bool,
        _ body: (RootAuthority) throws -> T
    ) throws -> T {
        let authority = try openAuthority()
        defer {
            Darwin.close(authority.jobsDescriptor)
            Darwin.close(authority.rootDescriptor)
            Darwin.close(authority.parentDescriptor)
        }
        try lock(
            authority.jobsDescriptor,
            operation: exclusive ? LOCK_EX : LOCK_SH
        )
        defer { _ = sessionProcessingJobFlock(authority.jobsDescriptor, LOCK_UN) }
        try revalidate(authority)
        return try body(authority)
    }

    func openAuthority() throws -> RootAuthority {
        let parent = root.deletingLastPathComponent()
        let rootName = root.lastPathComponent
        guard !rootName.isEmpty, rootName != ".", rootName != "..",
              !rootName.contains("/"), !rootName.contains("\\")
        else { throw JobPersistenceError.unavailable }
        let parentDescriptor = parent.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else { throw JobPersistenceError.unavailable }
        let rootDescriptor = rootName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard rootDescriptor >= 0 else {
            Darwin.close(parentDescriptor)
            throw JobPersistenceError.unavailable
        }
        do {
            let loaded = try PortableLibraryPersistence().load(
                from: rootDescriptor,
                reconcileAbandonedImports: false
            )
            guard case let .readWrite(library) = loaded,
                  library.manifest.libraryID == libraryID
            else { throw JobPersistenceError.unavailable }
            let jobsDescriptor = try confined.openDirectory(
                named: "jobs",
                under: rootDescriptor
            )
            do {
                return RootAuthority(
                    parentDescriptor: parentDescriptor,
                    rootDescriptor: rootDescriptor,
                    rootName: rootName,
                    rootIdentity: try identity(rootDescriptor),
                    jobsDescriptor: jobsDescriptor,
                    jobsIdentity: try identity(jobsDescriptor)
                )
            } catch {
                Darwin.close(jobsDescriptor)
                throw error
            }
        } catch {
            Darwin.close(rootDescriptor)
            Darwin.close(parentDescriptor)
            throw error
        }
    }

    func revalidate(_ authority: RootAuthority) throws {
        guard try identity(authority.rootDescriptor) == authority.rootIdentity,
              try identity(authority.jobsDescriptor) == authority.jobsIdentity
        else { throw JobPersistenceError.integrityMismatch }
        let reopenedRoot = authority.rootName.withCString {
            Darwin.openat(
                authority.parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard reopenedRoot >= 0 else { throw JobPersistenceError.integrityMismatch }
        defer { Darwin.close(reopenedRoot) }
        guard try identity(reopenedRoot) == authority.rootIdentity else {
            throw JobPersistenceError.integrityMismatch
        }
        let reopenedJobs = try confined.openDirectory(named: "jobs", under: reopenedRoot)
        defer { Darwin.close(reopenedJobs) }
        guard try identity(reopenedJobs) == authority.jobsIdentity else {
            throw JobPersistenceError.integrityMismatch
        }
    }

    func loadJob(under descriptor: Int32) throws -> SessionProcessingJob {
        try decode(
            confined.boundedData(
                named: "job.json",
                under: descriptor,
                maximumBytes: Self.maximumJobBytes
            )
        )
    }

    func loadJob(named name: String, under parent: Int32) throws
        -> SessionProcessingJob
    {
        let descriptor = try confined.openDirectory(named: name, under: parent)
        defer { Darwin.close(descriptor) }
        guard try confined.listEntryNames(
            under: descriptor,
            maximumCount: 1
        ) == ["job.json"] else {
            throw JobPersistenceError.integrityMismatch
        }
        return try loadJob(under: descriptor)
    }

    func revalidateJob(
        named name: String,
        identity expectedIdentity: FileIdentity,
        under parent: Int32
    ) throws {
        let reopened = try confined.openDirectory(named: name, under: parent)
        defer { Darwin.close(reopened) }
        guard try identity(reopened) == expectedIdentity else {
            throw JobPersistenceError.integrityMismatch
        }
    }

    func decode(_ data: Data) throws -> SessionProcessingJob {
        let dictionary = try confined.jsonDictionary(data)
        let required: Set<String> = [
            "schemaVersion", "jobId", "sessionId", "revisionId", "profileId",
            "createdAt", "state",
        ]
        let optional: Set<String> = ["candidateArtifactSha256", "failure"]
        guard required.isSubset(of: dictionary.keys),
              Set(dictionary.keys).isSubset(of: required.union(optional))
        else { throw JobPersistenceError.integrityMismatch }
        let dto = try confined.decode(JobDTO.self, from: data)
        guard dto.schemaVersion == 1,
              let state = SessionProcessingJobState(rawValue: dto.state)
        else { throw JobPersistenceError.integrityMismatch }
        let failure: SessionProcessingFailureReason?
        if let rawFailure = dto.failure {
            guard let parsed = SessionProcessingFailureReason(rawValue: rawFailure) else {
                throw JobPersistenceError.integrityMismatch
            }
            failure = parsed
        } else {
            failure = nil
        }
        let job = SessionProcessingJob(
            jobID: try TranscriptionJobID(dto.jobId),
            sessionID: try SessionID(dto.sessionId),
            revisionID: try TranscriptRevisionID(dto.revisionId),
            profileID: dto.profileId,
            createdAt: try UTCInstant(dto.createdAt),
            state: state,
            candidateArtifactSHA256: dto.candidateArtifactSha256,
            failure: failure
        )
        guard isValid(job) else { throw JobPersistenceError.integrityMismatch }
        return job
    }

    func isValid(_ job: SessionProcessingJob) -> Bool {
        guard (1...128).contains(job.profileID.utf8.count),
              job.profileID.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) ||
                      (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
              }),
              job.candidateArtifactSHA256.map(AudioArtifactFingerprint.isSHA256) ?? true
        else { return false }
        switch job.state {
        case .queued, .preparing, .running, .cancelled, .interrupted:
            return job.candidateArtifactSHA256 == nil && job.failure == nil
        case .validating, .completed:
            return job.candidateArtifactSHA256 != nil && job.failure == nil
        case .failed:
            return job.failure != nil
        }
    }

    func sameIdentity(_ left: SessionProcessingJob, _ right: SessionProcessingJob) -> Bool {
        left.jobID == right.jobID && left.sessionID == right.sessionID &&
            left.revisionID == right.revisionID && left.profileID == right.profileID &&
            left.createdAt == right.createdAt
    }

    func preservesCandidateIntegrity(
        from current: SessionProcessingJob,
        to next: SessionProcessingJob
    ) -> Bool {
        guard let currentHash = current.candidateArtifactSHA256 else { return true }
        return next.candidateArtifactSHA256 == currentHash
    }

    func isAllowedTransition(
        from current: SessionProcessingJobState,
        to next: SessionProcessingJobState
    ) -> Bool {
        switch (current, next) {
        case (.queued, .preparing), (.queued, .running), (.queued, .failed),
             (.queued, .cancelled), (.queued, .interrupted),
             (.preparing, .running), (.preparing, .failed),
             (.preparing, .cancelled), (.preparing, .interrupted),
             (.running, .validating), (.running, .failed),
             (.running, .cancelled), (.running, .interrupted),
             (.validating, .completed), (.validating, .failed),
             (.validating, .interrupted):
            true
        default:
            false
        }
    }

    func lock(_ descriptor: Int32, operation: Int32) throws {
        while sessionProcessingJobFlock(descriptor, operation) != 0 {
            if errno == EINTR { continue }
            throw JobPersistenceError.io
        }
    }

    func identity(_ descriptor: Int32) throws -> FileIdentity {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw JobPersistenceError.io }
        return FileIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
    }

    func removePartial(named name: String, under parent: Int32) {
        let descriptor = name.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if descriptor >= 0 {
            _ = unlinkat(descriptor, "job.json", 0)
            Darwin.close(descriptor)
        }
        _ = unlinkat(parent, name, AT_REMOVEDIR)
    }

    var confined: ConfinedPersistencePrimitives<JobPersistenceError> {
        ConfinedPersistencePrimitives(
            ioFailure: .io,
            invalidLayout: .integrityMismatch,
            expectedPathIsSymlink: .integrityMismatch,
            rootTooLarge: .integrityMismatch,
            invalidJSON: .integrityMismatch,
            invalidSchemaVersion: .integrityMismatch,
            unknownKey: .integrityMismatch
        )
    }
}

private enum JobPersistenceError: Error {
    case unavailable
    case integrityMismatch
    case collision
    case io
}
