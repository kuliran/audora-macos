import AudoraApplication
import AudoraDomain
import Darwin
import Foundation

@_silgen_name("flock")
private func sessionProcessingJobFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

enum JobReconciliationFault: Hashable, Sendable {
    case beforeJobMutationCommit
    case afterAttemptReservationBeforeJobInstall
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
    private static let maximumAttemptIndexBytes = 4_194_304
    /// Mirrors `SessionProcessingAttemptSequence` in the portable contract and
    /// stays exactly representable by every supported JSON consumer.
    private static let maximumAttemptSequence: UInt64 = 9_007_199_254_740_991
    private static let attemptIndexName = ".attempts.json"
    private static let attemptIndexPartialName = ".attempts.json.partial"

    private let root: URL
    private let libraryID: LibraryID
    private let expectedRootIdentity: SessionProcessingRootIdentity?
    private let creationJobCountLimit: Int
    private let reconciliationFault: @Sendable (JobReconciliationFault) throws -> Void

    public init(root: URL, libraryID: LibraryID) {
        self.init(
            root: root,
            libraryID: libraryID,
            expectedRootIdentity: SessionProcessingRootIdentity.capture(root),
            creationJobCountLimit: Self.maximumJobCount,
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
            creationJobCountLimit: Self.maximumJobCount,
            reconciliationFault: reconciliationFault
        )
    }

    init(
        root: URL,
        libraryID: LibraryID,
        creationJobCountLimit: Int
    ) {
        self.init(
            root: root,
            libraryID: libraryID,
            expectedRootIdentity: SessionProcessingRootIdentity.capture(root),
            creationJobCountLimit: creationJobCountLimit
        )
    }

    init(
        root: URL,
        libraryID: LibraryID,
        expectedRootIdentity: SessionProcessingRootIdentity?,
        creationJobCountLimit: Int = Self.maximumJobCount,
        reconciliationFault: @escaping @Sendable (JobReconciliationFault) throws
            -> Void = { _ in }
    ) {
        precondition(creationJobCountLimit > 0)
        self.root = root
        self.libraryID = libraryID
        self.expectedRootIdentity = expectedRootIdentity
        self.creationJobCountLimit = creationJobCountLimit
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
            let state = try withJobs(exclusive: true) {
                try loadRepositoryState($0)
            }
            return .available(
                SessionProcessingJobInventory(
                    reconciliationID: reconciliationID,
                    scope: scope,
                    jobs: state.orderedJobs
                )
            )
        } catch let JobPersistenceError.unsupportedSchema(version) {
            return .unsupportedSchema(version: version)
        } catch JobPersistenceError.unavailable {
            return .unavailable
        } catch {
            do {
                let jobs = try withJobs(exclusive: true) {
                    try loadClassifiedInventoryJobs($0)
                }
                return .available(
                    SessionProcessingJobInventory(
                        reconciliationID: reconciliationID,
                        scope: scope,
                        jobs: jobs,
                        isComplete: false
                    )
                )
            } catch JobPersistenceError.unavailable {
                return .unavailable
            } catch {
                return .integrityMismatch
            }
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
                let state = try loadRepositoryState(authority)
                let latest = state.currentJob(for: selection.sessionID)
                try revalidate(authority)
                return latest.map(SessionProcessingJobLoadResult.loaded) ?? .none
            }
        } catch let JobPersistenceError.unsupportedSchema(version) {
            return .unsupportedSchema(version: version)
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
                let state = try loadRepositoryState(authority)
                guard let job = state.jobsByID[jobID] else {
                    try revalidate(authority)
                    return .none
                }
                guard job.sessionID == selection.sessionID else {
                    return .integrityMismatch
                }
                try revalidate(authority)
                return .loaded(job)
            }
        } catch let JobPersistenceError.unsupportedSchema(version) {
            return .unsupportedSchema(version: version)
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
                var state = try loadRepositoryState(authority)
                guard state.jobsByID.count < creationJobCountLimit else {
                    return .failed
                }
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
                let partialDescriptor = try confined.openDirectory(
                    named: partial,
                    under: authority.jobsDescriptor
                )
                let partialIdentity = try identity(partialDescriptor)
                var manifest: OpenedRegularFile?
                var manifestData: Data?
                defer {
                    if ownsPartial {
                        removePreparedCreationPartialIfUnchanged(
                            named: partial,
                            directoryDescriptor: partialDescriptor,
                            directoryIdentity: partialIdentity,
                            manifest: manifest,
                            manifestData: manifestData,
                            authority: authority
                        )
                    }
                    if let manifest { Darwin.close(manifest.descriptor) }
                    Darwin.close(partialDescriptor)
                }
                let attemptSequence = try state.reserve(job)
                let data = try encoded(job, attemptSequence: attemptSequence)
                guard data.count <= Self.maximumJobBytes else { return .failed }
                try confined.writeExclusive(
                    data,
                    named: "job.json",
                    under: partialDescriptor,
                    flushBeforeClose: true
                )
                try confined.flush(partialDescriptor)
                let openedManifest = try openRegularFile(
                    named: "job.json",
                    under: partialDescriptor
                )
                manifest = openedManifest
                let writtenData = try boundedData(
                    from: openedManifest.descriptor,
                    maximumBytes: Self.maximumJobBytes
                )
                manifestData = writtenData
                guard writtenData == data,
                      try confined.listEntryNames(
                        under: partialDescriptor,
                        maximumCount: 2
                      ) == ["job.json"]
                else { return .failed }
                try reconciliationFault(.beforeJobMutationCommit)
                try revalidatePreparedCreationPartial(
                    named: partial,
                    directoryDescriptor: partialDescriptor,
                    directoryIdentity: partialIdentity,
                    manifest: openedManifest,
                    manifestData: writtenData,
                    under: authority.jobsDescriptor
                )
                try revalidate(authority)
                try replaceAttemptIndex(state.index, authority: authority)
                try reconciliationFault(.afterAttemptReservationBeforeJobInstall)
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
                try state.commitReservation(job)
                try replaceAttemptIndex(state.index, authority: authority)
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
                // Transition does not load the aggregate repository state, so
                // it must independently fence the causal attempt root before
                // entering or mutating an otherwise readable Job directory.
                try requireSupportedAttemptIndexes(authority)
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
                let currentFile = try openRegularFile(
                    named: "job.json",
                    under: jobDescriptor
                )
                defer { Darwin.close(currentFile.descriptor) }
                let currentData = try boundedData(
                    from: currentFile.descriptor,
                    maximumBytes: Self.maximumJobBytes
                )
                let current = try decode(currentData)
                let currentAttemptSequence = try attemptSequence(in: currentData)
                guard current.state == expected,
                      current.reconciliationIdentity == job.reconciliationIdentity
                else { return .stale }
                guard isAllowedTransition(from: current, to: job),
                      preservesCandidateIntegrity(from: current, to: job),
                      preservesControlIntegrity(from: current, to: job)
                else { return .failed }

                let data = try encoded(
                    job,
                    attemptSequence: currentAttemptSequence
                )
                guard data.count <= Self.maximumJobBytes,
                      try !confined.entryExists(
                        named: "job.json.partial",
                        under: jobDescriptor
                      )
                else { return .failed }
                try confined.writeExclusive(
                    data,
                    named: "job.json.partial",
                    under: jobDescriptor,
                    flushBeforeClose: true
                )
                let partialFile = try openRegularFile(
                    named: "job.json.partial",
                    under: jobDescriptor
                )
                var ownsPartial = true
                defer {
                    if ownsPartial {
                        removePreparedTransitionPartialIfUnchanged(
                            jobName: job.jobID.rawValue,
                            jobDescriptor: jobDescriptor,
                            jobIdentity: jobIdentity,
                            currentFile: currentFile,
                            currentData: currentData,
                            partialFile: partialFile,
                            partialData: data,
                            authority: authority
                        )
                    }
                    Darwin.close(partialFile.descriptor)
                }
                let writtenData = try boundedData(
                    from: partialFile.descriptor,
                    maximumBytes: Self.maximumJobBytes
                )
                guard writtenData == data,
                      try boundedData(
                        from: currentFile.descriptor,
                        maximumBytes: Self.maximumJobBytes
                      ) == currentData,
                      try confined.listEntryNames(
                        under: jobDescriptor,
                        maximumCount: 3
                      ) == ["job.json", "job.json.partial"]
                else { return .stale }
                try reconciliationFault(.beforeJobMutationCommit)
                try revalidatePreparedTransitionPartial(
                    jobName: job.jobID.rawValue,
                    jobDescriptor: jobDescriptor,
                    jobIdentity: jobIdentity,
                    currentFile: currentFile,
                    currentData: currentData,
                    partialFile: partialFile,
                    partialData: writtenData,
                    under: authority.jobsDescriptor
                )
                try revalidate(authority)
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

    struct AttemptIndexDTO: Codable, Equatable {
        let schemaVersion: UInt32
        var sessions: [SessionAttemptsDTO]

        init(sessions: [SessionAttemptsDTO]) {
            schemaVersion = 1
            self.sessions = sessions
        }
    }

    struct SessionAttemptsDTO: Codable, Equatable {
        let sessionId: String
        var legacyJobIds: [String]
        var attempts: [AttemptDTO]
        var currentJobId: String?
        var pendingAttempt: AttemptDTO?

        enum CodingKeys: String, CodingKey {
            case sessionId, legacyJobIds, attempts, currentJobId, pendingAttempt
        }

        init(
            sessionId: String,
            legacyJobIds: [String],
            attempts: [AttemptDTO],
            currentJobId: String?,
            pendingAttempt: AttemptDTO?
        ) {
            self.sessionId = sessionId
            self.legacyJobIds = legacyJobIds
            self.attempts = attempts
            self.currentJobId = currentJobId
            self.pendingAttempt = pendingAttempt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard values.contains(.currentJobId), values.contains(.pendingAttempt) else {
                throw JobPersistenceError.integrityMismatch
            }
            sessionId = try values.decode(String.self, forKey: .sessionId)
            legacyJobIds = try values.decode([String].self, forKey: .legacyJobIds)
            attempts = try values.decode([AttemptDTO].self, forKey: .attempts)
            currentJobId = try values.decodeIfPresent(String.self, forKey: .currentJobId)
            pendingAttempt = try values.decodeIfPresent(
                AttemptDTO.self,
                forKey: .pendingAttempt
            )
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(sessionId, forKey: .sessionId)
            try values.encode(legacyJobIds, forKey: .legacyJobIds)
            try values.encode(attempts, forKey: .attempts)
            if let currentJobId {
                try values.encode(currentJobId, forKey: .currentJobId)
            } else {
                try values.encodeNil(forKey: .currentJobId)
            }
            if let pendingAttempt {
                try values.encode(pendingAttempt, forKey: .pendingAttempt)
            } else {
                try values.encodeNil(forKey: .pendingAttempt)
            }
        }
    }

    struct AttemptDTO: Codable, Equatable {
        let sequence: UInt64
        let jobId: String
    }

    struct RepositoryState {
        var index: AttemptIndexDTO
        let jobsByID: [TranscriptionJobID: SessionProcessingJob]

        var orderedJobs: [SessionProcessingJob] {
            index.sessions.flatMap { session in
                let identifiers = session.legacyJobIds +
                    session.attempts.map(\.jobId)
                return identifiers.compactMap { raw -> SessionProcessingJob? in
                    guard let identifier = try? TranscriptionJobID(raw) else {
                        return nil
                    }
                    return jobsByID[identifier]
                }
            }
        }

        func currentJob(for sessionID: SessionID) -> SessionProcessingJob? {
            guard let raw = index.sessions.first(where: {
                $0.sessionId == sessionID.rawValue
            })?.currentJobId,
                let jobID = try? TranscriptionJobID(raw)
            else { return nil }
            return jobsByID[jobID]
        }

        mutating func reserve(_ job: SessionProcessingJob) throws -> UInt64 {
            guard !jobsByID.keys.contains(job.jobID) else {
                throw JobPersistenceError.collision
            }
            let sessionIndex: Int
            if let existing = index.sessions.firstIndex(where: {
                $0.sessionId == job.sessionID.rawValue
            }) {
                sessionIndex = existing
            } else {
                index.sessions.append(
                    SessionAttemptsDTO(
                        sessionId: job.sessionID.rawValue,
                        legacyJobIds: [],
                        attempts: [],
                        currentJobId: nil,
                        pendingAttempt: nil
                    )
                )
                index.sessions.sort { $0.sessionId < $1.sessionId }
                sessionIndex = index.sessions.firstIndex(where: {
                    $0.sessionId == job.sessionID.rawValue
                })!
            }
            guard index.sessions[sessionIndex].pendingAttempt == nil else {
                throw JobPersistenceError.integrityMismatch
            }
            let previous = index.sessions[sessionIndex].attempts.last?.sequence ?? 0
            guard previous < PortableSessionProcessingJobRepository
                .maximumAttemptSequence
            else {
                throw JobPersistenceError.integrityMismatch
            }
            let sequence = previous + 1
            index.sessions[sessionIndex].pendingAttempt = AttemptDTO(
                sequence: sequence,
                jobId: job.jobID.rawValue
            )
            return sequence
        }

        mutating func commitReservation(_ job: SessionProcessingJob) throws {
            guard let sessionIndex = index.sessions.firstIndex(where: {
                $0.sessionId == job.sessionID.rawValue
            }),
                index.sessions[sessionIndex].pendingAttempt?.jobId == job.jobID.rawValue,
                let pending = index.sessions[sessionIndex].pendingAttempt
            else { throw JobPersistenceError.integrityMismatch }
            index.sessions[sessionIndex].attempts.append(pending)
            index.sessions[sessionIndex].currentJobId = pending.jobId
            index.sessions[sessionIndex].pendingAttempt = nil
        }
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

    struct JobV3DTO: Codable {
        let schemaVersion: UInt32
        let attemptSequence: UInt64
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
            case schemaVersion, attemptSequence, jobId, sessionId, revisionId
            case profileId, createdAt, state, expectedSelectedRevisionId
            case cancellationAuthorityId, cancellationRequestedAt
            case candidateArtifactSha256, failure
        }

        init(_ job: SessionProcessingJob, attemptSequence: UInt64) throws {
            guard attemptSequence > 0,
                  attemptSequence <= PortableSessionProcessingJobRepository
                    .maximumAttemptSequence,
                  let cancellationAuthorityID = job.cancellationAuthorityID,
                  job.hasCapturedSelectionBaseline
            else { throw JobPersistenceError.integrityMismatch }
            schemaVersion = 3
            self.attemptSequence = attemptSequence
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
            attemptSequence = try values.decode(UInt64.self, forKey: .attemptSequence)
            jobId = try values.decode(String.self, forKey: .jobId)
            sessionId = try values.decode(String.self, forKey: .sessionId)
            revisionId = try values.decode(String.self, forKey: .revisionId)
            profileId = try values.decode(String.self, forKey: .profileId)
            createdAt = try values.decode(String.self, forKey: .createdAt)
            state = try values.decode(String.self, forKey: .state)
            guard values.contains(.expectedSelectedRevisionId) else {
                throw JobPersistenceError.integrityMismatch
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
            try values.encode(attemptSequence, forKey: .attemptSequence)
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
        let loaded = try PortableLibraryPersistence().load(
            from: authority.rootDescriptor,
            reconcileAbandonedImports: false
        )
        guard case let .readWrite(library) = loaded,
              library.manifest.libraryID == libraryID
        else { throw JobPersistenceError.integrityMismatch }
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

    func loadRepositoryState(_ authority: RootAuthority) throws -> RepositoryState {
        // The attempt index is the causal authority for every job mutation.
        // Classify both its installed and crash-staged roots before reconciling
        // any repository-owned partial, otherwise a newer index could be
        // collapsed into a writable compatibility inventory.
        try requireSupportedAttemptIndexes(authority)
        let jobs = try reconcileOwnedPartialsAndLoadJobs(authority)
        let jobsByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.jobID, $0) })
        let sequencesByID = try loadAttemptSequences(
            for: jobs,
            authority: authority
        )
        var index: AttemptIndexDTO
        var needsWrite = false

        if try confined.entryExists(
            named: Self.attemptIndexPartialName,
            under: authority.jobsDescriptor
        ) {
            try discardVerifiedAttemptIndexPartial(authority)
        }

        if try confined.entryExists(
            named: Self.attemptIndexName,
            under: authority.jobsDescriptor
        ) {
            index = try decodeAttemptIndex(
                confined.boundedData(
                    named: Self.attemptIndexName,
                    under: authority.jobsDescriptor,
                    maximumBytes: Self.maximumAttemptIndexBytes
                )
            )
        } else {
            guard sequencesByID.isEmpty else {
                throw JobPersistenceError.integrityMismatch
            }
            index = try migratedAttemptIndex(for: jobs)
            needsWrite = !jobs.isEmpty
        }

        let repaired = try validateAndRepairAttemptIndex(
            index,
            jobsByID: jobsByID,
            sequencesByID: sequencesByID
        )
        index = repaired.index
        needsWrite = needsWrite || repaired.changed
        if needsWrite {
            try replaceAttemptIndex(index, authority: authority)
        }
        try revalidate(authority)
        return RepositoryState(index: index, jobsByID: jobsByID)
    }

    func loadAttemptSequences(
        for jobs: [SessionProcessingJob],
        authority: RootAuthority
    ) throws -> [TranscriptionJobID: UInt64] {
        var sequences: [TranscriptionJobID: UInt64] = [:]
        for job in jobs {
            let data: Data
            do {
                let descriptor = try confined.openDirectory(
                    named: job.jobID.rawValue,
                    under: authority.jobsDescriptor
                )
                defer { Darwin.close(descriptor) }
                data = try confined.boundedData(
                    named: "job.json",
                    under: descriptor,
                    maximumBytes: Self.maximumJobBytes
                )
            }
            if let sequence = try attemptSequence(in: data) {
                sequences[job.jobID] = sequence
            }
        }
        return sequences
    }

    /// A malformed sibling must retain the activation fence, but it does not
    /// erase exact Jobs that can still be independently confined and decoded.
    /// This path never repairs the causal index or claims a complete inventory.
    func loadClassifiedInventoryJobs(
        _ authority: RootAuthority
    ) throws -> [SessionProcessingJob] {
        try requireNoUnknownNewerAttemptIndexes(authority)
        let names = try confined.listEntryNames(
            under: authority.jobsDescriptor,
            maximumCount: Self.maximumJobCount + 2
        )
        let jobNames = names.compactMap { name -> (String, TranscriptionJobID)? in
            guard let jobID = try? TranscriptionJobID(name) else { return nil }
            return (name, jobID)
        }
        guard jobNames.count <= Self.maximumJobCount else {
            throw JobPersistenceError.integrityMismatch
        }

        var validByID: [TranscriptionJobID: SessionProcessingJob] = [:]
        for (name, expectedJobID) in jobNames {
            guard let job = try? loadJobReconcilingTransitionPartial(
                named: name,
                expectedJobID: expectedJobID,
                authority: authority
            ) else { continue }
            guard validByID.updateValue(job, forKey: job.jobID) == nil else {
                throw JobPersistenceError.integrityMismatch
            }
        }
        try revalidate(authority)
        let sequencesByID = try loadAttemptSequences(
            for: Array(validByID.values),
            authority: authority
        )

        guard try confined.entryExists(
            named: Self.attemptIndexName,
            under: authority.jobsDescriptor
        ) else {
            return compatibilityOrderedJobs(
                validByID: validByID,
                sequencesByID: sequencesByID
            )
        }
        do {
            let index = try decodeAttemptIndex(
                confined.boundedData(
                    named: Self.attemptIndexName,
                    under: authority.jobsDescriptor,
                    maximumBytes: Self.maximumAttemptIndexBytes
                )
            )
            return try classifiedJobs(
                in: index,
                validByID: validByID,
                sequencesByID: sequencesByID
            )
        } catch {
            return compatibilityOrderedJobs(
                validByID: validByID,
                sequencesByID: sequencesByID
            )
        }
    }

    func compatibilityOrderedJobs(
        validByID: [TranscriptionJobID: SessionProcessingJob],
        sequencesByID: [TranscriptionJobID: UInt64]
    ) -> [SessionProcessingJob] {
        validByID.values.sorted { left, right in
            if left.sessionID != right.sessionID {
                return left.sessionID.rawValue < right.sessionID.rawValue
            }
            switch (sequencesByID[left.jobID], sequencesByID[right.jobID]) {
            case let (.some(leftSequence), .some(rightSequence)):
                return (leftSequence, left.jobID.rawValue) <
                    (rightSequence, right.jobID.rawValue)
            case (.none, .some):
                return true
            case (.some, .none):
                return false
            case (.none, .none):
                return (left.createdAt.rawValue, left.jobID.rawValue) <
                    (right.createdAt.rawValue, right.jobID.rawValue)
            }
        }
    }

    func classifiedJobs(
        in index: AttemptIndexDTO,
        validByID: [TranscriptionJobID: SessionProcessingJob],
        sequencesByID: [TranscriptionJobID: UInt64]
    ) throws -> [SessionProcessingJob] {
        guard index.schemaVersion == 1,
              index.sessions.map(\.sessionId) == index.sessions.map(\.sessionId).sorted(),
              Set(index.sessions.map(\.sessionId)).count == index.sessions.count
        else { throw JobPersistenceError.integrityMismatch }
        var observed = Set<TranscriptionJobID>()
        var result: [SessionProcessingJob] = []
        for session in index.sessions {
            let sessionID = try SessionID(session.sessionId)
            var expectedSequence: UInt64 = 1
            let committed = session.legacyJobIds + session.attempts.map(\.jobId)
            guard session.currentJobId == committed.last else {
                throw JobPersistenceError.integrityMismatch
            }
            for attempt in session.attempts {
                guard attempt.sequence == expectedSequence,
                      attempt.sequence <= Self.maximumAttemptSequence,
                      expectedSequence < Self.maximumAttemptSequence
                else { throw JobPersistenceError.integrityMismatch }
                expectedSequence += 1
            }
            if let pending = session.pendingAttempt {
                guard pending.sequence == expectedSequence,
                      pending.sequence <= Self.maximumAttemptSequence
                else {
                    throw JobPersistenceError.integrityMismatch
                }
            }
            let orderedRaw = committed + [session.pendingAttempt?.jobId].compactMap { $0 }
            for raw in orderedRaw {
                let jobID = try TranscriptionJobID(raw)
                guard observed.insert(jobID).inserted else {
                    throw JobPersistenceError.integrityMismatch
                }
                if let job = validByID[jobID] {
                    guard job.sessionID == sessionID else {
                        throw JobPersistenceError.integrityMismatch
                    }
                    if let attempt = session.attempts.first(where: {
                        $0.jobId == raw
                    }) ?? (session.pendingAttempt?.jobId == raw
                        ? session.pendingAttempt : nil)
                    {
                        guard sequencesByID[jobID] == attempt.sequence else {
                            throw JobPersistenceError.integrityMismatch
                        }
                    } else if sequencesByID[jobID] != nil {
                        throw JobPersistenceError.integrityMismatch
                    }
                    result.append(job)
                }
            }
        }
        guard Set(validByID.keys).isSubset(of: observed) else {
            throw JobPersistenceError.integrityMismatch
        }
        return result
    }

    func migratedAttemptIndex(
        for jobs: [SessionProcessingJob]
    ) throws -> AttemptIndexDTO {
        let grouped = Dictionary(grouping: jobs, by: \SessionProcessingJob.sessionID)
        let sessions = grouped.keys.sorted { $0.rawValue < $1.rawValue }.map { sessionID in
            // Schema-v1/v2 repositories recorded no causal sequence. Preserve
            // their former visible order only as a migration compatibility set;
            // every post-migration create receives an explicit sequence instead.
            let legacy = grouped[sessionID]!.sorted {
                ($0.createdAt.rawValue, $0.jobID.rawValue) <
                    ($1.createdAt.rawValue, $1.jobID.rawValue)
            }
            return SessionAttemptsDTO(
                sessionId: sessionID.rawValue,
                legacyJobIds: legacy.map(\.jobID.rawValue),
                attempts: [],
                currentJobId: legacy.last?.jobID.rawValue,
                pendingAttempt: nil
            )
        }
        return AttemptIndexDTO(sessions: sessions)
    }

    func validateAndRepairAttemptIndex(
        _ value: AttemptIndexDTO,
        jobsByID: [TranscriptionJobID: SessionProcessingJob],
        sequencesByID: [TranscriptionJobID: UInt64]
    ) throws -> (index: AttemptIndexDTO, changed: Bool) {
        guard value.schemaVersion == 1,
              value.sessions.count <= Self.maximumJobCount,
              value.sessions.map(\.sessionId) == value.sessions.map(\.sessionId).sorted(),
              Set(value.sessions.map(\.sessionId)).count == value.sessions.count
        else { throw JobPersistenceError.integrityMismatch }

        var index = value
        var changed = false
        var indexedJobIDs = Set<TranscriptionJobID>()
        for offset in index.sessions.indices {
            var session = index.sessions[offset]
            let sessionID = try SessionID(session.sessionId)
            guard session.legacyJobIds.count + session.attempts.count <=
                Self.maximumJobCount
            else { throw JobPersistenceError.integrityMismatch }

            var localIDs = Set<TranscriptionJobID>()
            for raw in session.legacyJobIds {
                let jobID = try TranscriptionJobID(raw)
                guard localIDs.insert(jobID).inserted,
                      indexedJobIDs.insert(jobID).inserted,
                      jobsByID[jobID]?.sessionID == sessionID,
                      sequencesByID[jobID] == nil
                else { throw JobPersistenceError.integrityMismatch }
            }

            var expectedSequence: UInt64 = 1
            for attempt in session.attempts {
                let jobID = try TranscriptionJobID(attempt.jobId)
                guard attempt.sequence == expectedSequence,
                      attempt.sequence <= Self.maximumAttemptSequence,
                      localIDs.insert(jobID).inserted,
                      indexedJobIDs.insert(jobID).inserted,
                      jobsByID[jobID]?.sessionID == sessionID,
                      sequencesByID[jobID] == attempt.sequence
                else { throw JobPersistenceError.integrityMismatch }
                guard expectedSequence < Self.maximumAttemptSequence else {
                    throw JobPersistenceError.integrityMismatch
                }
                expectedSequence += 1
            }

            let committedCurrent = session.attempts.last?.jobId ??
                session.legacyJobIds.last
            guard session.currentJobId == committedCurrent else {
                throw JobPersistenceError.integrityMismatch
            }

            if let pending = session.pendingAttempt {
                let pendingID = try TranscriptionJobID(pending.jobId)
                guard pending.sequence == expectedSequence,
                      pending.sequence <= Self.maximumAttemptSequence,
                      !localIDs.contains(pendingID),
                      !indexedJobIDs.contains(pendingID)
                else { throw JobPersistenceError.integrityMismatch }
                if let pendingJob = jobsByID[pendingID] {
                    guard pendingJob.sessionID == sessionID else {
                        throw JobPersistenceError.integrityMismatch
                    }
                    guard sequencesByID[pendingID] == pending.sequence else {
                        throw JobPersistenceError.integrityMismatch
                    }
                    session.attempts.append(pending)
                    session.currentJobId = pending.jobId
                    _ = indexedJobIDs.insert(pendingID)
                }
                session.pendingAttempt = nil
                index.sessions[offset] = session
                changed = true
            }
        }

        index.sessions.removeAll {
            $0.legacyJobIds.isEmpty && $0.attempts.isEmpty &&
                $0.pendingAttempt == nil
        }
        guard indexedJobIDs == Set(jobsByID.keys) else {
            throw JobPersistenceError.integrityMismatch
        }
        return (index, changed)
    }

    func decodeAttemptIndex(_ data: Data) throws -> AttemptIndexDTO {
        let object = try confined.jsonDictionary(data)
        guard Set(object.keys) == ["schemaVersion", "sessions"],
              let sessions = object["sessions"] as? [[String: Any]]
        else { throw JobPersistenceError.integrityMismatch }
        for session in sessions {
            guard Set(session.keys) == [
                "sessionId", "legacyJobIds", "attempts", "currentJobId",
                "pendingAttempt",
            ], let attempts = session["attempts"] as? [[String: Any]]
            else { throw JobPersistenceError.integrityMismatch }
            for attempt in attempts {
                guard Set(attempt.keys) == ["sequence", "jobId"] else {
                    throw JobPersistenceError.integrityMismatch
                }
            }
            if let pending = session["pendingAttempt"] as? [String: Any] {
                guard Set(pending.keys) == ["sequence", "jobId"] else {
                    throw JobPersistenceError.integrityMismatch
                }
            } else if !(session["pendingAttempt"] is NSNull) {
                throw JobPersistenceError.integrityMismatch
            }
        }
        do {
            return try JSONDecoder().decode(AttemptIndexDTO.self, from: data)
        } catch {
            throw JobPersistenceError.integrityMismatch
        }
    }

    /// Partial inventory may classify independently valid Jobs beside a corrupt
    /// causal root, but it must never reinterpret a root that proves it belongs
    /// to a newer writer.
    func requireNoUnknownNewerAttemptIndexes(
        _ authority: RootAuthority
    ) throws {
        for name in [Self.attemptIndexName, Self.attemptIndexPartialName] {
            guard try confined.entryExists(
                named: name,
                under: authority.jobsDescriptor
            ) else { continue }
            let data = try confined.boundedData(
                named: name,
                under: authority.jobsDescriptor,
                maximumBytes: Self.maximumAttemptIndexBytes
            )
            if let version = declaredAttemptIndexSchemaVersion(in: data),
               version > 1
            {
                throw JobPersistenceError.unsupportedSchema(version)
            }
        }
    }

    /// Mutation and read-write recovery require a fully decodable supported
    /// causal root. This is intentionally stricter than partial inventory.
    func requireSupportedAttemptIndexes(_ authority: RootAuthority) throws {
        for name in [Self.attemptIndexName, Self.attemptIndexPartialName] {
            guard try confined.entryExists(
                named: name,
                under: authority.jobsDescriptor
            ) else { continue }
            let data = try confined.boundedData(
                named: name,
                under: authority.jobsDescriptor,
                maximumBytes: Self.maximumAttemptIndexBytes
            )
            guard let version = declaredAttemptIndexSchemaVersion(in: data) else {
                throw JobPersistenceError.integrityMismatch
            }
            guard version == 1 else {
                if version > 1 {
                    throw JobPersistenceError.unsupportedSchema(version)
                }
                throw JobPersistenceError.integrityMismatch
            }
            _ = try decodeAttemptIndex(data)
        }
    }

    func declaredAttemptIndexSchemaVersion(in data: Data) -> UInt32? {
        guard let object = try? confined.jsonDictionary(data),
              let number = object["schemaVersion"] as? NSNumber,
              String(cString: number.objCType) != "c",
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.uint64Value <= UInt64(UInt32.max)
        else { return nil }
        return UInt32(number.uint64Value)
    }

    func replaceAttemptIndex(
        _ index: AttemptIndexDTO,
        authority: RootAuthority
    ) throws {
        let data = try confined.deterministicJSON(index)
        guard data.count <= Self.maximumAttemptIndexBytes,
              try !confined.entryExists(
                named: Self.attemptIndexPartialName,
                under: authority.jobsDescriptor
              )
        else { throw JobPersistenceError.integrityMismatch }
        let installed: OpenedRegularFile?
        if try confined.entryExists(
            named: Self.attemptIndexName,
            under: authority.jobsDescriptor
        ) {
            let opened = try openRegularFile(
                named: Self.attemptIndexName,
                under: authority.jobsDescriptor
            )
            do {
                _ = try decodeAttemptIndex(
                    try boundedData(
                        from: opened.descriptor,
                        maximumBytes: Self.maximumAttemptIndexBytes
                    )
                )
                installed = opened
            } catch {
                Darwin.close(opened.descriptor)
                throw error
            }
        } else {
            installed = nil
        }
        defer {
            if let installed { Darwin.close(installed.descriptor) }
        }
        try confined.writeExclusive(
            data,
            named: Self.attemptIndexPartialName,
            under: authority.jobsDescriptor,
            flushBeforeClose: true
        )
        let partial = try openRegularFile(
            named: Self.attemptIndexPartialName,
            under: authority.jobsDescriptor
        )
        var ownsPartial = true
        defer {
            if ownsPartial,
               (try? revalidateRegularFile(
                named: Self.attemptIndexPartialName,
                identity: partial.identity,
                under: authority.jobsDescriptor
               )) != nil
            {
                _ = unlinkat(
                    authority.jobsDescriptor,
                    Self.attemptIndexPartialName,
                    0
                )
            }
            Darwin.close(partial.descriptor)
        }
        guard try boundedData(
            from: partial.descriptor,
            maximumBytes: Self.maximumAttemptIndexBytes
        ) == data else { throw JobPersistenceError.integrityMismatch }
        _ = try decodeAttemptIndex(data)
        try revalidate(authority)
        try revalidateRegularFile(
            named: Self.attemptIndexPartialName,
            identity: partial.identity,
            under: authority.jobsDescriptor
        )
        if let installed {
            try revalidateRegularFile(
                named: Self.attemptIndexName,
                identity: installed.identity,
                under: authority.jobsDescriptor
            )
        } else {
            guard try !confined.entryExists(
                named: Self.attemptIndexName,
                under: authority.jobsDescriptor
            ) else { throw JobPersistenceError.integrityMismatch }
        }
        let result = Self.attemptIndexPartialName.withCString { source in
            Self.attemptIndexName.withCString { destination in
                Darwin.renameat(
                    authority.jobsDescriptor,
                    source,
                    authority.jobsDescriptor,
                    destination
                )
            }
        }
        guard result == 0 else { throw JobPersistenceError.io }
        ownsPartial = false
        try confined.flush(authority.jobsDescriptor)
    }

    func discardVerifiedAttemptIndexPartial(
        _ authority: RootAuthority
    ) throws {
        let partial = try openRegularFile(
            named: Self.attemptIndexPartialName,
            under: authority.jobsDescriptor
        )
        defer { Darwin.close(partial.descriptor) }
        let data = try boundedData(
            from: partial.descriptor,
            maximumBytes: Self.maximumAttemptIndexBytes
        )
        _ = try decodeAttemptIndex(data)
        try revalidate(authority)
        try revalidateRegularFile(
            named: Self.attemptIndexPartialName,
            identity: partial.identity,
            under: authority.jobsDescriptor
        )
        guard unlinkat(
            authority.jobsDescriptor,
            Self.attemptIndexPartialName,
            0
        ) == 0 else { throw JobPersistenceError.io }
        try confined.flush(authority.jobsDescriptor)
    }

    /// Reconciles only byte-exact repository-owned crash names. Every entry is
    /// classified before mutation, so an unknown or near-match name preserves
    /// the directory unchanged and fails closed.
    func reconcileOwnedPartialsAndLoadJobs(
        _ authority: RootAuthority
    ) throws -> [SessionProcessingJob] {
        let names = try confined.listEntryNames(
            under: authority.jobsDescriptor,
            maximumCount: Self.maximumJobCount + 2
        )
        var jobNames: [(String, TranscriptionJobID)] = []
        var creationPartials: [(String, TranscriptionJobID)] = []
        for name in names {
            if name == Self.attemptIndexName ||
                name == Self.attemptIndexPartialName
            {
                continue
            }
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
        guard jobNames.count + creationPartials.count <= Self.maximumJobCount else {
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
                  try attemptSequence(in: partialData) ==
                    attemptSequence(in: currentData),
                  current.reconciliationIdentity == replacement.reconciliationIdentity,
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
        case 3:
            let required = commonRequired.union([
                "attemptSequence", "expectedSelectedRevisionId",
                "cancellationAuthorityId",
            ])
            let optional: Set<String> = [
                "cancellationRequestedAt", "candidateArtifactSha256", "failure",
            ]
            guard required.isSubset(of: dictionary.keys),
                  Set(dictionary.keys).isSubset(of: required.union(optional))
            else { throw JobPersistenceError.integrityMismatch }
            let dto = try confined.decode(JobV3DTO.self, from: data)
            guard dto.schemaVersion == 3, dto.attemptSequence > 0,
                  dto.attemptSequence <= Self.maximumAttemptSequence,
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

    func attemptSequence(in data: Data) throws -> UInt64? {
        let dictionary = try confined.jsonDictionary(data)
        guard let schemaNumber = dictionary["schemaVersion"] as? NSNumber,
              String(cString: schemaNumber.objCType) != "c"
        else { throw JobPersistenceError.integrityMismatch }
        switch schemaNumber.uint32Value {
        case 1, 2:
            return nil
        case 3:
            let dto = try confined.decode(JobV3DTO.self, from: data)
            guard dto.schemaVersion == 3, dto.attemptSequence > 0,
                  dto.attemptSequence <= Self.maximumAttemptSequence
            else {
                throw JobPersistenceError.integrityMismatch
            }
            return dto.attemptSequence
        default:
            throw JobPersistenceError.integrityMismatch
        }
    }

    func encoded(
        _ job: SessionProcessingJob,
        attemptSequence: UInt64? = nil
    ) throws -> Data {
        if let attemptSequence {
            return try confined.deterministicJSON(
                try JobV3DTO(job, attemptSequence: attemptSequence)
            )
        }
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

    func revalidatePreparedCreationPartial(
        named name: String,
        directoryDescriptor: Int32,
        directoryIdentity: FileIdentity,
        manifest: OpenedRegularFile,
        manifestData: Data,
        under parent: Int32
    ) throws {
        guard try identity(directoryDescriptor) == directoryIdentity,
              try boundedData(
                from: manifest.descriptor,
                maximumBytes: Self.maximumJobBytes
              ) == manifestData,
              try confined.listEntryNames(
                under: directoryDescriptor,
                maximumCount: 2
              ) == ["job.json"]
        else { throw JobPersistenceError.integrityMismatch }
        try revalidateDirectory(
            named: name,
            identity: directoryIdentity,
            under: parent
        )
        try revalidateRegularFile(
            named: "job.json",
            identity: manifest.identity,
            under: directoryDescriptor
        )
    }

    func removePreparedCreationPartialIfUnchanged(
        named name: String,
        directoryDescriptor: Int32,
        directoryIdentity: FileIdentity,
        manifest: OpenedRegularFile?,
        manifestData: Data?,
        authority: RootAuthority
    ) {
        guard let manifest, let manifestData else { return }
        do {
            try revalidate(authority)
            try revalidatePreparedCreationPartial(
                named: name,
                directoryDescriptor: directoryDescriptor,
                directoryIdentity: directoryIdentity,
                manifest: manifest,
                manifestData: manifestData,
                under: authority.jobsDescriptor
            )
            guard unlinkat(directoryDescriptor, "job.json", 0) == 0 else {
                return
            }
            var metadata = stat()
            guard fstat(manifest.descriptor, &metadata) == 0,
                  metadata.st_nlink == 0,
                  unlinkat(authority.jobsDescriptor, name, AT_REMOVEDIR) == 0
            else { return }
            try confined.flush(authority.jobsDescriptor)
        } catch {
            // Once ownership cannot be proved, preserve the suspect entry for
            // bounded relaunch reconciliation instead of deleting by name.
        }
    }

    func revalidatePreparedTransitionPartial(
        jobName: String,
        jobDescriptor: Int32,
        jobIdentity: FileIdentity,
        currentFile: OpenedRegularFile,
        currentData: Data,
        partialFile: OpenedRegularFile,
        partialData: Data,
        under jobsDescriptor: Int32
    ) throws {
        guard try identity(jobDescriptor) == jobIdentity,
              try boundedData(
                from: currentFile.descriptor,
                maximumBytes: Self.maximumJobBytes
              ) == currentData,
              try boundedData(
                from: partialFile.descriptor,
                maximumBytes: Self.maximumJobBytes
              ) == partialData,
              try confined.listEntryNames(
                under: jobDescriptor,
                maximumCount: 3
              ) == ["job.json", "job.json.partial"]
        else { throw JobPersistenceError.integrityMismatch }
        try revalidateJob(
            named: jobName,
            identity: jobIdentity,
            under: jobsDescriptor
        )
        try revalidateRegularFile(
            named: "job.json",
            identity: currentFile.identity,
            under: jobDescriptor
        )
        try revalidateRegularFile(
            named: "job.json.partial",
            identity: partialFile.identity,
            under: jobDescriptor
        )
    }

    func removePreparedTransitionPartialIfUnchanged(
        jobName: String,
        jobDescriptor: Int32,
        jobIdentity: FileIdentity,
        currentFile: OpenedRegularFile,
        currentData: Data,
        partialFile: OpenedRegularFile,
        partialData: Data,
        authority: RootAuthority
    ) {
        do {
            try revalidate(authority)
            try revalidatePreparedTransitionPartial(
                jobName: jobName,
                jobDescriptor: jobDescriptor,
                jobIdentity: jobIdentity,
                currentFile: currentFile,
                currentData: currentData,
                partialFile: partialFile,
                partialData: partialData,
                under: authority.jobsDescriptor
            )
            guard unlinkat(jobDescriptor, "job.json.partial", 0) == 0 else {
                return
            }
            var metadata = stat()
            guard fstat(partialFile.descriptor, &metadata) == 0,
                  metadata.st_nlink == 0
            else { return }
            try confined.flush(jobDescriptor)
        } catch {
            // Preserve any entry whose exact ownership changed after staging.
        }
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
    case unsupportedSchema(UInt32)
    case integrityMismatch
    case collision
    case io
}
