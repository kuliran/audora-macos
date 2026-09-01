import AudoraApplication
import AudoraDomain
import Darwin
import Foundation

@_silgen_name("flock")
private func sessionProcessingJobFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

enum JobReconciliationFault: Hashable, Sendable {
    case beforeJobMutationCommit
    case beforeCreationPartialUnlink
    case beforeTransitionPartialUnlink
}

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
    private let expectedRootIdentity: SessionProcessingRootIdentity?
    private let reconciliationFault: @Sendable (JobReconciliationFault) throws -> Void

    public init(root: URL, libraryID: LibraryID) {
        self.init(
            root: root,
            libraryID: libraryID,
            expectedRootIdentity: SessionProcessingRootIdentity.capture(root),
            reconciliationFault: { _ in }
        )
    }

    init(
        root: URL,
        libraryID: LibraryID,
        reconciliationFault: @escaping @Sendable (JobReconciliationFault) throws
            -> Void
    ) {
        self.init(
            root: root,
            libraryID: libraryID,
            expectedRootIdentity: SessionProcessingRootIdentity.capture(root),
            reconciliationFault: reconciliationFault
        )
    }

    init(
        root: URL,
        libraryID: LibraryID,
        expectedRootIdentity: SessionProcessingRootIdentity?,
        reconciliationFault: @escaping @Sendable (JobReconciliationFault) throws
            -> Void = { _ in }
    ) {
        self.root = root
        self.libraryID = libraryID
        self.expectedRootIdentity = expectedRootIdentity
        self.reconciliationFault = reconciliationFault
    }

    public func inventory(
        for scope: LibraryScope
    ) async -> SessionProcessingJobInventoryResult {
        guard let reconciliationID = try? SessionProcessingReconciliationID(
            "reconcile-\(UUID().uuidString)"
        ) else { return .integrityMismatch }
        return inventorySynchronously(
            for: scope,
            reconciliationID: reconciliationID
        )
    }

    func inventorySynchronously(
        for scope: LibraryScope,
        reconciliationID: SessionProcessingReconciliationID
    ) -> SessionProcessingJobInventoryResult {
        guard scope.libraryID == libraryID else { return .unavailable }
        do {
            let jobs = try withJobs(exclusive: true) {
                try reconcileOwnedPartialsAndLoadJobs($0)
            }
            return .available(
                SessionProcessingJobInventory(
                    reconciliationID: reconciliationID,
                    scope: scope,
                    jobs: jobs
                )
            )
        } catch JobPersistenceError.unavailable {
            return .unavailable
        } catch {
            return .integrityMismatch
        }
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
            return try withJobs(exclusive: true) { authority in
                var latest: SessionProcessingJob?
                for job in try reconcileOwnedPartialsAndLoadJobs(authority) {
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

    public func load(
        jobID: TranscriptionJobID,
        for selection: SessionProcessingSelection
    ) async -> SessionProcessingJobLoadResult {
        loadSynchronously(jobID: jobID, for: selection)
    }

    func loadSynchronously(
        jobID: TranscriptionJobID,
        for selection: SessionProcessingSelection
    ) -> SessionProcessingJobLoadResult {
        guard selection.scope.libraryID == libraryID else { return .unavailable }
        do {
            return try withJobs(exclusive: true) { authority in
                let jobs = try reconcileOwnedPartialsAndLoadJobs(authority)
                guard let job = jobs.first(where: { $0.jobID == jobID }) else {
                    try revalidate(authority)
                    return .none
                }
                guard job.sessionID == selection.sessionID else {
                    return .integrityMismatch
                }
                try revalidate(authority)
                return .loaded(job)
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
        guard isValid(job), job.state == .queued,
              job.cancellationAuthorityID != nil,
              job.cancellationRequestedAt == nil
        else { return .failed }
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
                let data = try encoded(job)
                guard data.count <= Self.maximumJobBytes else { return .failed }
                try confined.writeExclusive(
                    data,
                    named: "job.json",
                    under: partialDescriptor,
                    flushBeforeClose: true
                )
                try confined.flush(partialDescriptor)
                try reconciliationFault(.beforeJobMutationCommit)
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
                guard isAllowedTransition(from: current, to: job),
                      preservesCandidateIntegrity(from: current, to: job),
                      preservesControlIntegrity(from: current, to: job)
                else { return .failed }

                let data = try encoded(job)
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
                try reconciliationFault(.beforeJobMutationCommit)
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

    struct OpenedRegularFile {
        let descriptor: Int32
        let identity: FileIdentity
    }

    struct JobV2DTO: Codable {
        let schemaVersion: UInt32
        let jobId: String
        let sessionId: String
        let revisionId: String
        let profileId: String
        let createdAt: String
        let state: String
        let expectedSelectedRevisionId: String?
        let cancellationAuthorityId: String
        let cancellationRequestedAt: String?
        let candidateArtifactSha256: String?
        let failure: String?

        enum CodingKeys: String, CodingKey {
            case schemaVersion, jobId, sessionId, revisionId, profileId, createdAt
            case state, expectedSelectedRevisionId, cancellationAuthorityId
            case cancellationRequestedAt, candidateArtifactSha256, failure
        }

        init(_ job: SessionProcessingJob) throws {
            guard let cancellationAuthorityID = job.cancellationAuthorityID,
                  job.hasCapturedSelectionBaseline
            else {
                throw JobPersistenceError.integrityMismatch
            }
            schemaVersion = 2
            jobId = job.jobID.rawValue
            sessionId = job.sessionID.rawValue
            revisionId = job.revisionID.rawValue
            profileId = job.profileID
            createdAt = job.createdAt.rawValue
            state = job.state.rawValue
            expectedSelectedRevisionId = job.expectedSelectedRevisionID?.rawValue
            cancellationAuthorityId = cancellationAuthorityID.rawValue
            cancellationRequestedAt = job.cancellationRequestedAt?.rawValue
            candidateArtifactSha256 = job.candidateArtifactSHA256
            failure = job.failure?.rawValue
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(UInt32.self, forKey: .schemaVersion)
            jobId = try values.decode(String.self, forKey: .jobId)
            sessionId = try values.decode(String.self, forKey: .sessionId)
            revisionId = try values.decode(String.self, forKey: .revisionId)
            profileId = try values.decode(String.self, forKey: .profileId)
            createdAt = try values.decode(String.self, forKey: .createdAt)
            state = try values.decode(String.self, forKey: .state)
            guard values.contains(.expectedSelectedRevisionId) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.expectedSelectedRevisionId,
                    DecodingError.Context(
                        codingPath: values.codingPath,
                        debugDescription: "missing captured selection baseline"
                    )
                )
            }
            expectedSelectedRevisionId = try values.decodeIfPresent(
                String.self,
                forKey: .expectedSelectedRevisionId
            )
            cancellationAuthorityId = try values.decode(
                String.self,
                forKey: .cancellationAuthorityId
            )
            cancellationRequestedAt = try values.decodeIfPresent(
                String.self,
                forKey: .cancellationRequestedAt
            )
            candidateArtifactSha256 = try values.decodeIfPresent(
                String.self,
                forKey: .candidateArtifactSha256
            )
            failure = try values.decodeIfPresent(String.self, forKey: .failure)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(schemaVersion, forKey: .schemaVersion)
            try values.encode(jobId, forKey: .jobId)
            try values.encode(sessionId, forKey: .sessionId)
            try values.encode(revisionId, forKey: .revisionId)
            try values.encode(profileId, forKey: .profileId)
            try values.encode(createdAt, forKey: .createdAt)
            try values.encode(state, forKey: .state)
            if let expectedSelectedRevisionId {
                try values.encode(
                    expectedSelectedRevisionId,
                    forKey: .expectedSelectedRevisionId
                )
            } else {
                try values.encodeNil(forKey: .expectedSelectedRevisionId)
            }
            try values.encode(cancellationAuthorityId, forKey: .cancellationAuthorityId)
            try values.encodeIfPresent(
                cancellationRequestedAt,
                forKey: .cancellationRequestedAt
            )
            try values.encodeIfPresent(
                candidateArtifactSha256,
                forKey: .candidateArtifactSha256
            )
            try values.encodeIfPresent(failure, forKey: .failure)
        }
    }

    struct JobV1DTO: Codable {
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
            let rootIdentity = try identity(rootDescriptor)
            guard let expectedRootIdentity,
                  rootIdentity.device == expectedRootIdentity.device,
                  rootIdentity.inode == expectedRootIdentity.inode
            else { throw JobPersistenceError.unavailable }
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
                    rootIdentity: rootIdentity,
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

    /// Reconciles only byte-exact repository-owned crash names. Every entry is
    /// classified before mutation, so an unknown or near-match name preserves
    /// the directory unchanged and fails closed.
    func reconcileOwnedPartialsAndLoadJobs(
        _ authority: RootAuthority
    ) throws -> [SessionProcessingJob] {
        let names = try confined.listEntryNames(
            under: authority.jobsDescriptor,
            maximumCount: Self.maximumJobCount
        )
        var jobNames: [(String, TranscriptionJobID)] = []
        var creationPartials: [(String, TranscriptionJobID)] = []
        for name in names {
            if let jobID = try? TranscriptionJobID(name) {
                jobNames.append((name, jobID))
                continue
            }
            if let jobID = creationPartialJobID(name) {
                creationPartials.append((name, jobID))
                continue
            }
            throw JobPersistenceError.integrityMismatch
        }

        // A create partial and installed directory for the same Job cannot be
        // produced by renameat; retaining both is adversarial ambiguity.
        let installedIDs = Set(jobNames.map(\.1))
        guard creationPartials.allSatisfy({ !installedIDs.contains($0.1) }) else {
            throw JobPersistenceError.integrityMismatch
        }
        for (name, jobID) in creationPartials {
            try discardVerifiedCreationPartial(
                named: name,
                jobID: jobID,
                authority: authority
            )
        }

        var jobs: [SessionProcessingJob] = []
        jobs.reserveCapacity(jobNames.count)
        for (name, jobID) in jobNames {
            let job = try loadJobReconcilingTransitionPartial(
                named: name,
                expectedJobID: jobID,
                authority: authority
            )
            guard job.jobID == jobID else {
                throw JobPersistenceError.integrityMismatch
            }
            jobs.append(job)
        }
        try revalidate(authority)
        return jobs
    }

    func creationPartialJobID(_ name: String) -> TranscriptionJobID? {
        let prefix = "."
        let suffix = ".partial"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix),
              name.utf8.count > prefix.utf8.count + suffix.utf8.count
        else { return nil }
        let start = name.index(after: name.startIndex)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        let raw = String(name[start..<end])
        guard let jobID = try? TranscriptionJobID(raw),
              name == ".\(jobID.rawValue).partial"
        else { return nil }
        return jobID
    }

    func discardVerifiedCreationPartial(
        named name: String,
        jobID: TranscriptionJobID,
        authority: RootAuthority
    ) throws {
        let descriptor = try confined.openDirectory(
            named: name,
            under: authority.jobsDescriptor
        )
        defer { Darwin.close(descriptor) }
        try lock(descriptor, operation: LOCK_EX)
        defer { _ = sessionProcessingJobFlock(descriptor, LOCK_UN) }
        let partialIdentity = try identity(descriptor)
        let entries = try confined.listEntryNames(
            under: descriptor,
            maximumCount: 1
        )
        guard entries.isEmpty || entries == ["job.json"] else {
            throw JobPersistenceError.integrityMismatch
        }
        var manifest: OpenedRegularFile?
        var manifestBytes: Data?
        defer {
            if let manifest { Darwin.close(manifest.descriptor) }
        }
        if entries == ["job.json"] {
            let opened = try openRegularFile(named: "job.json", under: descriptor)
            manifest = opened
            let bytes = try boundedData(
                from: opened.descriptor,
                maximumBytes: Self.maximumJobBytes
            )
            manifestBytes = bytes
            let staged = try decode(bytes)
            guard staged.jobID == jobID, staged.state == .queued else {
                throw JobPersistenceError.integrityMismatch
            }
        }
        try revalidate(authority)
        try revalidateDirectory(
            named: name,
            identity: partialIdentity,
            under: authority.jobsDescriptor
        )
        try reconciliationFault(.beforeCreationPartialUnlink)
        try revalidate(authority)
        try revalidateDirectory(
            named: name,
            identity: partialIdentity,
            under: authority.jobsDescriptor
        )
        if let manifest {
            guard let manifestBytes,
                  try boundedData(
                from: manifest.descriptor,
                maximumBytes: Self.maximumJobBytes
            ) == manifestBytes else {
                throw JobPersistenceError.integrityMismatch
            }
            try revalidateRegularFile(
                named: "job.json",
                identity: manifest.identity,
                under: descriptor
            )
        }
        guard try confined.listEntryNames(
            under: descriptor,
            maximumCount: 2
        ) == entries else {
            throw JobPersistenceError.integrityMismatch
        }
        if entries == ["job.json"], unlinkat(descriptor, "job.json", 0) != 0 {
            throw JobPersistenceError.io
        }
        if let manifest {
            var metadata = stat()
            guard fstat(manifest.descriptor, &metadata) == 0,
                  metadata.st_nlink == 0
            else { throw JobPersistenceError.integrityMismatch }
        }
        guard unlinkat(authority.jobsDescriptor, name, AT_REMOVEDIR) == 0 else {
            throw JobPersistenceError.io
        }
        try confined.flush(authority.jobsDescriptor)
    }

    func loadJobReconcilingTransitionPartial(
        named name: String,
        expectedJobID: TranscriptionJobID,
        authority: RootAuthority
    ) throws -> SessionProcessingJob {
        let descriptor = try confined.openDirectory(
            named: name,
            under: authority.jobsDescriptor
        )
        defer { Darwin.close(descriptor) }
        let jobIdentity = try identity(descriptor)
        try lock(descriptor, operation: LOCK_EX)
        defer { _ = sessionProcessingJobFlock(descriptor, LOCK_UN) }
        let entries = try confined.listEntryNames(
            under: descriptor,
            maximumCount: 2
        )
        guard entries == ["job.json"] ||
            entries == ["job.json", "job.json.partial"]
        else { throw JobPersistenceError.integrityMismatch }

        let currentFile = try openRegularFile(named: "job.json", under: descriptor)
        defer { Darwin.close(currentFile.descriptor) }
        let currentData = try boundedData(
            from: currentFile.descriptor,
            maximumBytes: Self.maximumJobBytes
        )
        let current = try decode(currentData)
        guard current.jobID == expectedJobID else {
            throw JobPersistenceError.integrityMismatch
        }
        if entries.contains("job.json.partial") {
            let partialFile = try openRegularFile(
                named: "job.json.partial",
                under: descriptor
            )
            defer { Darwin.close(partialFile.descriptor) }
            let partialData = try boundedData(
                from: partialFile.descriptor,
                maximumBytes: Self.maximumJobBytes
            )
            let replacement = try decode(partialData)
            guard replacement.jobID == expectedJobID,
                  sameIdentity(current, replacement),
                  isAllowedTransition(from: current, to: replacement),
                  preservesCandidateIntegrity(from: current, to: replacement),
                  preservesControlIntegrity(from: current, to: replacement)
            else { throw JobPersistenceError.integrityMismatch }
            try revalidate(authority)
            try revalidateJob(
                named: name,
                identity: jobIdentity,
                under: authority.jobsDescriptor
            )
            try reconciliationFault(.beforeTransitionPartialUnlink)
            try revalidate(authority)
            try revalidateJob(
                named: name,
                identity: jobIdentity,
                under: authority.jobsDescriptor
            )
            guard try boundedData(
                from: currentFile.descriptor,
                maximumBytes: Self.maximumJobBytes
            ) == currentData,
                try boundedData(
                    from: partialFile.descriptor,
                    maximumBytes: Self.maximumJobBytes
                ) == partialData
            else { throw JobPersistenceError.integrityMismatch }
            try revalidateRegularFile(
                named: "job.json",
                identity: currentFile.identity,
                under: descriptor
            )
            try revalidateRegularFile(
                named: "job.json.partial",
                identity: partialFile.identity,
                under: descriptor
            )
            guard try confined.listEntryNames(
                under: descriptor,
                maximumCount: 3
            ) == entries else {
                throw JobPersistenceError.integrityMismatch
            }
            guard unlinkat(descriptor, "job.json.partial", 0) == 0 else {
                throw JobPersistenceError.io
            }
            var partialMetadata = stat()
            guard fstat(partialFile.descriptor, &partialMetadata) == 0,
                  partialMetadata.st_nlink == 0
            else { throw JobPersistenceError.integrityMismatch }
            try confined.flush(descriptor)
        }
        return current
    }

    func revalidateDirectory(
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

    func openRegularFile(named name: String, under parent: Int32) throws
        -> OpenedRegularFile
    {
        let descriptor = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw JobPersistenceError.integrityMismatch }
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_nlink == 1
            else { throw JobPersistenceError.integrityMismatch }
            return OpenedRegularFile(
                descriptor: descriptor,
                identity: FileIdentity(
                    device: UInt64(metadata.st_dev),
                    inode: UInt64(metadata.st_ino)
                )
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func revalidateRegularFile(
        named name: String,
        identity expectedIdentity: FileIdentity,
        under parent: Int32
    ) throws {
        let reopened = try openRegularFile(named: name, under: parent)
        defer { Darwin.close(reopened.descriptor) }
        guard reopened.identity == expectedIdentity else {
            throw JobPersistenceError.integrityMismatch
        }
    }

    func boundedData(from descriptor: Int32, maximumBytes: Int) throws -> Data {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_size >= 0,
              metadata.st_size <= maximumBytes
        else { throw JobPersistenceError.integrityMismatch }
        let count = Int(metadata.st_size)
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                if count == 0 { return }
                throw JobPersistenceError.io
            }
            var offset = 0
            while offset < count {
                let readCount = Darwin.pread(
                    descriptor,
                    base.advanced(by: offset),
                    count - offset,
                    off_t(offset)
                )
                if readCount < 0 {
                    if errno == EINTR { continue }
                    throw JobPersistenceError.io
                }
                guard readCount > 0 else { throw JobPersistenceError.io }
                offset += readCount
            }
        }
        var finalMetadata = stat()
        guard fstat(descriptor, &finalMetadata) == 0,
              finalMetadata.st_size == metadata.st_size
        else { throw JobPersistenceError.integrityMismatch }
        return data
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
        let commonRequired: Set<String> = [
            "schemaVersion", "jobId", "sessionId", "revisionId", "profileId",
            "createdAt", "state",
        ]
        guard let schemaNumber = dictionary["schemaVersion"] as? NSNumber,
              String(cString: schemaNumber.objCType) != "c"
        else { throw JobPersistenceError.integrityMismatch }
        let schema = schemaNumber.uint32Value
        let job: SessionProcessingJob
        switch schema {
        case 1:
            let optional: Set<String> = ["candidateArtifactSha256", "failure"]
            guard commonRequired.isSubset(of: dictionary.keys),
                  Set(dictionary.keys).isSubset(of: commonRequired.union(optional))
            else { throw JobPersistenceError.integrityMismatch }
            let dto = try confined.decode(JobV1DTO.self, from: data)
            guard dto.schemaVersion == 1,
                  let state = SessionProcessingJobState(rawValue: dto.state)
            else { throw JobPersistenceError.integrityMismatch }
            job = .legacyV1(
                jobID: try TranscriptionJobID(dto.jobId),
                sessionID: try SessionID(dto.sessionId),
                revisionID: try TranscriptRevisionID(dto.revisionId),
                profileID: dto.profileId,
                createdAt: try UTCInstant(dto.createdAt),
                state: state,
                candidateArtifactSHA256: dto.candidateArtifactSha256,
                failure: try failure(dto.failure)
            )
        case 2:
            let required = commonRequired.union([
                "expectedSelectedRevisionId", "cancellationAuthorityId",
            ])
            let optional: Set<String> = [
                "cancellationRequestedAt", "candidateArtifactSha256", "failure",
            ]
            guard required.isSubset(of: dictionary.keys),
                  Set(dictionary.keys).isSubset(of: required.union(optional))
            else { throw JobPersistenceError.integrityMismatch }
            let dto = try confined.decode(JobV2DTO.self, from: data)
            guard dto.schemaVersion == 2,
                  let state = SessionProcessingJobState(rawValue: dto.state)
            else { throw JobPersistenceError.integrityMismatch }
            job = SessionProcessingJob(
                jobID: try TranscriptionJobID(dto.jobId),
                sessionID: try SessionID(dto.sessionId),
                revisionID: try TranscriptRevisionID(dto.revisionId),
                profileID: dto.profileId,
                createdAt: try UTCInstant(dto.createdAt),
                state: state,
                expectedSelectedRevisionID: try dto.expectedSelectedRevisionId.map(
                    TranscriptRevisionID.init
                ),
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    dto.cancellationAuthorityId
                ),
                cancellationRequestedAt: try dto.cancellationRequestedAt.map(
                    UTCInstant.init
                ),
                candidateArtifactSHA256: dto.candidateArtifactSha256,
                failure: try failure(dto.failure)
            )
        default:
            throw JobPersistenceError.integrityMismatch
        }
        guard isValid(job) else { throw JobPersistenceError.integrityMismatch }
        return job
    }

    func failure(_ raw: String?) throws -> SessionProcessingFailureReason? {
        guard let raw else { return nil }
        guard let parsed = SessionProcessingFailureReason(rawValue: raw) else {
            throw JobPersistenceError.integrityMismatch
        }
        return parsed
    }

    func encoded(_ job: SessionProcessingJob) throws -> Data {
        if job.cancellationAuthorityID != nil {
            return try confined.deterministicJSON(try JobV2DTO(job))
        }
        return try confined.deterministicJSON(JobV1DTO(job))
    }

    func isValid(_ job: SessionProcessingJob) -> Bool {
        guard (1...128).contains(job.profileID.utf8.count),
              job.profileID.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) ||
                      (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
              }),
              job.candidateArtifactSHA256.map(AudioArtifactFingerprint.isSHA256) ?? true,
              job.cancellationRequestedAt == nil || job.cancellationAuthorityID != nil,
              job.cancellationAuthorityID == nil || job.hasCapturedSelectionBaseline
        else { return false }
        switch job.state {
        case .queued:
            return job.candidateArtifactSHA256 == nil && job.failure == nil &&
                job.cancellationRequestedAt == nil
        case .preparing, .running:
            return job.candidateArtifactSHA256 == nil && job.failure == nil
        case .validating, .completed:
            return job.candidateArtifactSHA256 != nil && job.failure == nil &&
                job.cancellationRequestedAt == nil
        case .failed:
            return job.failure != nil && job.cancellationRequestedAt == nil
        case .cancelled:
            return job.candidateArtifactSHA256 == nil && job.failure == nil &&
                (job.cancellationAuthorityID == nil || job.cancellationRequestedAt != nil)
        case .interrupted:
            return job.failure == nil
        }
    }

    func sameIdentity(_ left: SessionProcessingJob, _ right: SessionProcessingJob) -> Bool {
        left.jobID == right.jobID && left.sessionID == right.sessionID &&
            left.revisionID == right.revisionID && left.profileID == right.profileID &&
            left.createdAt == right.createdAt &&
            left.hasCapturedSelectionBaseline == right.hasCapturedSelectionBaseline &&
            left.expectedSelectedRevisionID == right.expectedSelectedRevisionID &&
            left.cancellationAuthorityID == right.cancellationAuthorityID
    }

    func preservesCandidateIntegrity(
        from current: SessionProcessingJob,
        to next: SessionProcessingJob
    ) -> Bool {
        guard let currentHash = current.candidateArtifactSHA256 else { return true }
        return next.candidateArtifactSHA256 == currentHash
    }

    func preservesControlIntegrity(
        from current: SessionProcessingJob,
        to next: SessionProcessingJob
    ) -> Bool {
        guard current.cancellationAuthorityID == next.cancellationAuthorityID else {
            return false
        }
        switch (current.cancellationRequestedAt, next.cancellationRequestedAt) {
        case (.none, .none):
            return true
        case let (.some(current), .some(next)):
            return current == next
        case (.some, .none):
            return false
        case (.none, .some):
            return current.state == next.state &&
                (current.state == .preparing || current.state == .running)
        }
    }

    func isAllowedTransition(
        from current: SessionProcessingJob,
        to next: SessionProcessingJob
    ) -> Bool {
        if current.state == next.state {
            return current.cancellationRequestedAt == nil &&
                next.cancellationRequestedAt != nil
        }
        switch (current.state, next.state) {
        case (.queued, .preparing), (.queued, .running), (.queued, .failed),
             (.queued, .cancelled), (.queued, .interrupted),
             (.preparing, .running), (.preparing, .failed),
             (.preparing, .cancelled), (.preparing, .interrupted),
             (.running, .validating), (.running, .failed),
             (.running, .cancelled), (.running, .interrupted),
             (.validating, .completed), (.validating, .failed),
             (.validating, .interrupted):
            if next.state == .cancelled, next.cancellationAuthorityID != nil {
                return next.cancellationRequestedAt != nil
            }
            return true
        default:
            return false
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
