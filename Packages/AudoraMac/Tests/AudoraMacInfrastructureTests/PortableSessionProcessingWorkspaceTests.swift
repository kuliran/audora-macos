import AudoraApplication
import AudoraDomain
@testable import AudoraMacInfrastructure
import Foundation
import XCTest

final class PortableSessionProcessingWorkspaceTests: XCTestCase {
    func testExactJobLookupKeepsOriginalWhenNewerSameSessionJobExists()
        async throws
    {
        try await withLibrary { root, libraryID in
            let receipt = try installRecordedSession(
                root: root,
                libraryID: libraryID,
                recordingID: "rec-20260830T120100000Z-1ABC",
                sessionID: "ses-20260830T120100000Z-2CDE",
                instant: "2026-08-30T12:01:00.000Z"
            )
            let selection = SessionProcessingSelection(
                scope: LibraryScope(libraryID: libraryID),
                sessionID: receipt.sessionID
            )
            let original = SessionProcessingJob(
                jobID: try TranscriptionJobID("job-20260830T120300000Z-3DEF"),
                sessionID: selection.sessionID,
                revisionID: try TranscriptRevisionID(
                    "trv-20260830T120300000Z-4EFG"
                ),
                profileID: "synthetic-qualified-v1",
                createdAt: try UTCInstant("2026-08-30T12:03:00.000Z"),
                state: .queued,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-workspace-original"
                )
            )
            let newer = SessionProcessingJob(
                jobID: try TranscriptionJobID("job-20260830T120400000Z-5GHJ"),
                sessionID: selection.sessionID,
                revisionID: try TranscriptRevisionID(
                    "trv-20260830T120400000Z-6JKM"
                ),
                profileID: original.profileID,
                createdAt: try UTCInstant("2026-08-30T12:04:00.000Z"),
                state: .queued,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-workspace-newer"
                )
            )
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let originalWrite = await repository.create(original)
            let newerWrite = await repository.create(newer)
            XCTAssertEqual(originalWrite, .written(original))
            XCTAssertEqual(newerWrite, .written(newer))
            let active = ActiveLibraryProcessingScope(
                identity: SessionProcessingScopeIdentity(
                    libraryID: libraryID,
                    workspaceGeneration: 1,
                    rootIdentity: try XCTUnwrap(
                        SessionProcessingRootIdentity.capture(root)
                    )
                ),
                root: root,
                lease: WorkspaceTestLease(url: root)
            )
            let workspace = PortableSessionProcessingWorkspace(
                scopes: FixedProcessingScopeProvider(active: active)
            )

            guard case .available = await workspace.load(selection) else {
                return XCTFail("expected sealed source binding")
            }
            let latest = await workspace.latest(for: selection)
            let exact = await workspace.load(
                jobID: original.jobID,
                for: selection
            )

            XCTAssertEqual(latest, .loaded(newer))
            XCTAssertEqual(exact, .loaded(original))
        }
    }

    func testSelectingValidatingJobWithMissingSourceRetainsJobAuthorityToInterrupt()
        async throws
    {
        try await withLibrary { root, libraryID in
            let scope = LibraryScope(libraryID: libraryID)
            let selection = SessionProcessingSelection(
                scope: scope,
                sessionID: try SessionID("ses-20260830T121500000Z-5GHJ")
            )
            let jobID = try TranscriptionJobID("job-20260830T121600000Z-6JKM")
            let revisionID = try TranscriptRevisionID(
                "trv-20260830T121600000Z-7MNP"
            )
            let authorityID = try TranscriptionCancellationAuthorityID(
                "cancel-missing-source-workspace"
            )
            let createdAt = try UTCInstant("2026-08-30T12:16:00.000Z")
            let queued = SessionProcessingJob(
                jobID: jobID,
                sessionID: selection.sessionID,
                revisionID: revisionID,
                profileID: "synthetic-qualified-v1",
                createdAt: createdAt,
                state: .queued,
                cancellationAuthorityID: authorityID
            )
            let running = SessionProcessingJob(
                jobID: jobID,
                sessionID: selection.sessionID,
                revisionID: revisionID,
                profileID: queued.profileID,
                createdAt: createdAt,
                state: .running,
                expectedSelectedRevisionID: nil,
                cancellationAuthorityID: authorityID
            )
            let validating = SessionProcessingJob(
                jobID: jobID,
                sessionID: selection.sessionID,
                revisionID: revisionID,
                profileID: queued.profileID,
                createdAt: createdAt,
                state: .validating,
                expectedSelectedRevisionID: nil,
                cancellationAuthorityID: authorityID,
                candidateArtifactSHA256: String(repeating: "a", count: 64)
            )
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let created = await repository.create(queued)
            let started = await repository.transition(running, from: .queued)
            let staged = await repository.transition(validating, from: .running)
            XCTAssertEqual(created, .written(queued))
            XCTAssertEqual(started, .written(running))
            XCTAssertEqual(staged, .written(validating))
            let active = ActiveLibraryProcessingScope(
                identity: SessionProcessingScopeIdentity(
                    libraryID: libraryID,
                    workspaceGeneration: 1,
                    rootIdentity: try XCTUnwrap(
                        SessionProcessingRootIdentity.capture(root)
                    )
                ),
                root: root,
                lease: WorkspaceTestLease(url: root)
            )
            let workspace = PortableSessionProcessingWorkspace(
                scopes: FixedProcessingScopeProvider(active: active)
            )
            let profile = try qualifiedProfile()
            let feature = DefaultSessionProcessingFeature(
                source: workspace,
                runtime: WorkspaceRuntime(profile: profile),
                model: WorkspaceModel(),
                acoustics: WorkspaceAcoustics(),
                jobs: workspace,
                engine: WorkspaceFailingEngine(),
                publisher: TranscriptRevisionPublisher(repository: workspace),
                clock: WorkspaceClock(instant: createdAt),
                identifiers: WorkspaceIdentifiers(
                    jobID: jobID,
                    revisionID: revisionID
                )
            )

            await feature.send(.selectSession(selection))

            guard case let .unavailable(snapshot) = await feature.currentState else {
                return XCTFail("expected missing sealed source to remain visible")
            }
            XCTAssertEqual(snapshot.reason, .sourceUnavailable)
            guard case let .loaded(reloaded) = await repository.latest(for: selection)
            else { return XCTFail("expected durable Job") }
            XCTAssertEqual(reloaded.state, .interrupted)
        }
    }

    func testActivationReconcilesPersistedJobAndRoutesRetryWithoutManualSelection()
        async throws
    {
        try await withLibrary { root, libraryID in
            let selectedReceipt = try installRecordedSession(
                root: root,
                libraryID: libraryID,
                recordingID: "rec-20260830T120100000Z-1ABC",
                sessionID: "ses-20260830T120100000Z-2CDE",
                instant: "2026-08-30T12:01:00.000Z"
            )
            let abandonedReceipt = try installRecordedSession(
                root: root,
                libraryID: libraryID,
                recordingID: "rec-20260830T120200000Z-3DEF",
                sessionID: "ses-20260830T120200000Z-4EFG",
                instant: "2026-08-30T12:02:00.000Z"
            )
            let scope = LibraryScope(libraryID: libraryID)
            let selected = SessionProcessingSelection(
                scope: scope,
                sessionID: selectedReceipt.sessionID
            )
            let abandoned = SessionProcessingSelection(
                scope: scope,
                sessionID: abandonedReceipt.sessionID
            )
            let abandonedJob = SessionProcessingJob(
                jobID: try TranscriptionJobID("job-20260830T120300000Z-5GHJ"),
                sessionID: abandoned.sessionID,
                revisionID: try TranscriptRevisionID(
                    "trv-20260830T120300000Z-6JKM"
                ),
                profileID: "synthetic-qualified-v1",
                createdAt: try UTCInstant("2026-08-30T12:03:00.000Z"),
                state: .queued,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-abandoned-workspace"
                )
            )
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let createResult = await repository.create(abandonedJob)
            XCTAssertEqual(createResult, .written(abandonedJob))
            let active = ActiveLibraryProcessingScope(
                identity: SessionProcessingScopeIdentity(
                    libraryID: libraryID,
                    workspaceGeneration: 1,
                    rootIdentity: try XCTUnwrap(
                        SessionProcessingRootIdentity.capture(root)
                    )
                ),
                root: root,
                lease: WorkspaceTestLease(url: root)
            )
            let workspace = PortableSessionProcessingWorkspace(
                scopes: FixedProcessingScopeProvider(active: active)
            )
            let profile = try qualifiedProfile()
            let engine = WorkspaceFailingEngine()
            let newJobID = try TranscriptionJobID(
                "job-20260830T120400000Z-7MNP"
            )
            let feature = DefaultSessionProcessingFeature(
                source: workspace,
                runtime: WorkspaceRuntime(profile: profile),
                model: WorkspaceModel(),
                acoustics: WorkspaceAcoustics(),
                jobs: workspace,
                engine: engine,
                publisher: TranscriptRevisionPublisher(repository: workspace),
                clock: WorkspaceClock(
                    instant: try UTCInstant("2026-08-30T12:04:00.000Z")
                ),
                identifiers: WorkspaceIdentifiers(
                    jobID: newJobID,
                    revisionID: try TranscriptRevisionID(
                        "trv-20260830T120400000Z-8NPQ"
                    )
                )
            )

            await feature.send(.selectSession(selected))
            guard case let .ready(beforeActivation) = await feature.currentState else {
                return XCTFail("expected selected Session to be ready")
            }
            XCTAssertEqual(beforeActivation.source.selection, selected)

            await feature.send(.activateLibrary(scope))
            guard case let .interrupted(afterActivation) = await feature.currentState
            else {
                return XCTFail("activation must expose the recovered Job")
            }
            XCTAssertEqual(afterActivation.source.selection, abandoned)
            XCTAssertEqual(afterActivation.job.jobID, abandonedJob.jobID)
            XCTAssertEqual(afterActivation.job.state, .interrupted)
            XCTAssertEqual(afterActivation.actions, [.retry])

            await feature.send(.retry)

            let requests = await engine.requests
            let abandonedReload = await repository.latest(for: abandoned)
            let selectedReload = await repository.latest(for: selected)
            XCTAssertEqual(requests.map(\.selection), [abandoned])
            XCTAssertEqual(requests.map(\.jobID), [newJobID])
            guard case let .loaded(retried) = abandonedReload else {
                return XCTFail("expected retried persisted Job")
            }
            XCTAssertEqual(retried.sessionID, abandoned.sessionID)
            XCTAssertEqual(retried.jobID, newJobID)
            XCTAssertEqual(retried.state, .failed)
            XCTAssertEqual(selectedReload, .none)
        }
    }

    private func withLibrary(
        _ body: (URL, LibraryID) async throws -> Void
    ) async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-processing-workspace-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent(
            "Practice.audoralibrary",
            isDirectory: true
        )
        let libraryID = try LibraryID("lib-20260830T120000000Z-0ABC")
        let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
        _ = try PortableLibraryPersistence().create(
            at: root,
            seed: NewLibrarySeed(
                libraryID: libraryID,
                createdAt: instant,
                preferences: .defaults,
                profileHead: ProfileHead(
                    generation: 0,
                    statementGeneration: 0,
                    selection: .null,
                    updatedAt: instant
                )
            )
        )
        try await body(root, libraryID)
    }

    private func installRecordedSession(
        root: URL,
        libraryID: LibraryID,
        recordingID: String,
        sessionID: String,
        instant: String
    ) throws -> SessionSealedReceipt {
        let startedAt = try UTCInstant(instant)
        let request = MicrophoneRecordingRequest(
            libraryScope: LibraryScope(libraryID: libraryID),
            recordingID: try RecordingID(recordingID),
            sessionID: try SessionID(sessionID),
            startedAt: startedAt
        )
        let persistence = RecordingPersistence()
        let handle = try persistence.prepare(request, under: root)
        try persistence.append(
            CanonicalPCMSpan(
                frameCount: 16,
                pcmLittleEndian: Data(repeating: 1, count: 32),
                reasons: [],
                level: 0.2
            ),
            to: handle
        )
        let candidate = try persistence.stageSeal(handle, reason: .userStop)
        let publication = try RecordingSealCandidateValidator.validate(
            candidate,
            expected: request
        )
        return try persistence.install(publication, using: handle)
    }

    private func qualifiedProfile() throws -> QualifiedTranscriptionProfile {
        let policy = try EngineUsePolicy(
            policyID: "synthetic-evaluation-v1",
            coveredArtifacts: [.transcriptRevision],
            privateLocalUseAllowed: true,
            privateExportAllowed: true,
            externalProcessingAllowed: false,
            publicDistributionAllowed: false,
            commercialUseAllowed: false,
            licenseReference: "https://example.invalid/pinned-license",
            licenseSHA256: String(repeating: "2", count: 64)
        )
        let qualification = try TranscriptEngineQualification(
            qualificationProfileID: "synthetic-qualified-v1",
            engineLockSHA256: String(repeating: "6", count: 64),
            runtimeIdentity: "synthetic-runtime-v1",
            runtimeLockSHA256: String(repeating: "4", count: 64),
            compatibilityPatchID: "synthetic-progress-patch-v1"
        )
        let provenance = try TranscriptEngineProvenance(
            provider: "crisperwhisper",
            model: "small",
            revision: "model-revision-v1",
            language: "en",
            mode: "verbatim",
            decodingOptionsSHA256: String(repeating: "3", count: 64),
            qualification: qualification,
            usePolicy: policy
        )
        return try QualifiedTranscriptionProfile(
            profileID: "synthetic-qualified-v1",
            protocolVersion: 1,
            runtimeVersion: "synthetic-runtime-v1",
            packageLockSHA256: String(repeating: "4", count: 64),
            modelRevision: "model-revision-v1",
            compatibilityPatchID: "synthetic-progress-patch-v1",
            engine: provenance
        )
    }
}

private final class WorkspaceTestLease: LibraryAccessLease, @unchecked Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    func release() {}
}

private struct FixedProcessingScopeProvider: SessionProcessingLibraryScopeProviding {
    let active: ActiveLibraryProcessingScope

    func acquireSessionProcessingScope(
        for scope: LibraryScope
    ) async -> ActiveLibraryProcessingScope? {
        scope.libraryID == active.identity.libraryID ? active : nil
    }

    func isCurrentSessionProcessingScope(
        _ identity: SessionProcessingScopeIdentity
    ) async -> Bool {
        identity == active.identity &&
            SessionProcessingRootIdentity.capture(active.root) == identity.rootIdentity
    }

    func withCurrentSessionProcessingScope<Result: Sendable>(
        _ identity: SessionProcessingScopeIdentity,
        perform operation: @Sendable () throws -> Result
    ) async throws -> Result {
        guard await isCurrentSessionProcessingScope(identity) else {
            throw SessionProcessingScopeError.changed
        }
        return try operation()
    }
}

private struct WorkspaceRuntime: TranscriptionRuntimePort {
    let profile: QualifiedTranscriptionProfile
    func resolve() async -> TranscriptionRuntimeResolution { .qualified(profile) }
    func prepare(_ action: SessionProcessingRecoveryAction) async
        -> TranscriptionRuntimeResolution { .qualified(profile) }
    func executionCapability(
        for profile: QualifiedTranscriptionProfile
    ) async -> VerifiedTranscriptionRuntime? {
        VerifiedTranscriptionRuntime(
            capabilityID: try! TranscriptionRuntimeCapabilityID(
                "runtime-workspace-test"
            ),
            profileID: profile.profileID,
            runtimeIdentity: profile.runtimeVersion
        )
    }
}

private struct WorkspaceModel: TranscriptionModelPort {
    func verify(_ profile: QualifiedTranscriptionProfile) async
        -> TranscriptionModelResolution { .ready }
    func prepare(
        _ action: SessionProcessingRecoveryAction,
        profile: QualifiedTranscriptionProfile
    ) async -> TranscriptionModelResolution { .ready }
    func executionCapability(
        for profile: QualifiedTranscriptionProfile
    ) async -> VerifiedTranscriptionModel? {
        VerifiedTranscriptionModel(
            capabilityID: try! TranscriptionModelCapabilityID("model-workspace-test"),
            profileID: profile.profileID,
            modelRevision: profile.modelRevision
        )
    }
}

private struct WorkspaceAcoustics: SessionAcousticEvidencePort {
    func resolve(
        for source: SessionTranscriptionSource,
        profile: QualifiedTranscriptionProfile
    ) async -> SessionAcousticEvidenceResolution {
        guard let range = try? SessionTimeRange(
            startMilliseconds: 0,
            endMilliseconds: source.durationMilliseconds,
            sessionDurationMilliseconds: source.durationMilliseconds
        ) else { return .unavailable }
        return .qualified(
            SessionVoicedRangeEvidence(
                qualificationProfileID: profile.profileID,
                extractorID: "synthetic-vad-v1",
                audioFingerprint: source.audioFingerprint,
                voicedRanges: [range]
            )
        )
    }
}

private actor WorkspaceFailingEngine: TranscriptionEngine {
    private(set) var requests: [TranscriptionRequest] = []
    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> VerifiedTranscriptionCandidate {
        requests.append(request)
        throw TranscriptionEngineFailure.launchFailed
    }
}

private struct WorkspaceClock: SessionProcessingClock {
    let instant: UTCInstant
    func now() async -> UTCInstant { instant }
}

private struct WorkspaceIdentifiers: SessionProcessingIDGenerator {
    let jobID: TranscriptionJobID
    let revisionID: TranscriptRevisionID
    func generateJobID(at instant: UTCInstant) async -> TranscriptionJobID { jobID }
    func generateRevisionID(at instant: UTCInstant) async -> TranscriptRevisionID {
        revisionID
    }
    func generateCancellationAuthorityID(
        at instant: UTCInstant
    ) async -> TranscriptionCancellationAuthorityID {
        try! TranscriptionCancellationAuthorityID("cancel-workspace-start")
    }
}
