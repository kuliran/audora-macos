import AudoraApplication
import AudoraContracts
import AudoraDomain
import Foundation
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class SessionProcessingRaceScenarioTests: XCTestCase {
    func testScenarioInventoryPinsEveryPortableBehavior() {
        let resources = ContractResource.allCases.filter {
            $0.subdirectory == "Scenarios/SessionProcessing"
        }

        XCTAssertEqual(
            Set(resources.map(\.rawValue)),
            [
                "cancel-reaps-retains-session.v1.json",
                "candidate-rejected-no-publication.v1.json",
                "model-prepare-start.v1.json",
                "progress-monotonic-eta-approximate.v1.json",
                "qualification-blocked-no-fallback.v1.json",
                "qualified-offline-success.v1.json",
                "race-cancel-wins-candidate-rejection.v1.json",
                "race-cancel-wins-candidate.v1.json",
                "race-cancel-wins-engine-failure.v1.json",
                "race-candidate-rejection-wins-cancel.v1.json",
                "race-candidate-wins-cancel.v1.json",
                "race-engine-failure-wins-cancel.v1.json",
                "relaunch-queued-interrupted.v1.json",
                "relaunch-running-absent-interrupted.v1.json",
                "relaunch-validating-resumes-idempotently.v1.json",
                "relaunch-validating-stale-selection.v1.json",
            ]
        )
    }

    func testEveryPortableNonRaceScenarioDrivesTheSwiftFeature() async throws {
        let resources = ContractResource.allCases.filter {
            $0.subdirectory == "Scenarios/SessionProcessing" &&
                !$0.rawValue.hasPrefix("race-")
        }
        XCTAssertFalse(resources.isEmpty)

        for resource in resources {
            let scenario = try SessionProcessingFeatureScenario(
                JSONDecoder().decode(
                    SessionProcessingFeatureScenarioDTO.self,
                    from: ContractResources.data(for: resource)
                )
            )
            let observation = try await SessionProcessingFeatureScenarioRunner(
                scenario: scenario
            ).run()

            XCTAssertEqual(observation.initialState, scenario.initialState, scenario.id)
            XCTAssertEqual(observation.trace, scenario.dependencyTrace, scenario.id)
            XCTAssertEqual(observation.finalState, scenario.expectedState, scenario.id)
            if scenario.hasExpectedJobs {
                XCTAssertEqual(observation.durableJobs, scenario.expectedJobs, scenario.id)
            }
            XCTAssertEqual(observation.effects, scenario.expectedEffects, scenario.id)
        }
    }

    func testEveryPortableTerminalRaceDrivesTheSwiftFeature() async throws {
        let resources = ContractResource.allCases.filter {
            $0.subdirectory == "Scenarios/SessionProcessing" &&
                $0.rawValue.hasPrefix("race-")
        }
        XCTAssertFalse(resources.isEmpty)

        for resource in resources {
            let scenario = try SessionProcessingRaceScenario(
                JSONDecoder().decode(
                    SessionProcessingRaceScenarioDTO.self,
                    from: ContractResources.data(for: resource)
                )
            )
            let observation = try await SessionProcessingRaceRunner(
                scenario: scenario
            ).run()

            XCTAssertEqual(
                observation.initialState,
                scenario.initialState,
                scenario.id
            )
            XCTAssertEqual(
                observation.trace,
                scenario.dependencyTrace,
                scenario.id
            )
            XCTAssertEqual(
                observation.finalState,
                scenario.expectedState,
                scenario.id
            )
            XCTAssertEqual(
                observation.durableJob,
                scenario.expectedJob,
                scenario.id
            )
            XCTAssertEqual(
                observation.effects,
                scenario.expectedEffects,
                scenario.id
            )
        }
    }
}

private struct SessionProcessingFeatureScenarioDTO: Decodable {
    let schemaVersion: UInt32
    let scenarioId: String
    let initialJobs: [JobDTO]?
    let initialState: StateDTO
    let commands: [CommandDTO]
    let dependencyTrace: [EventDTO]
    let expectedState: StateDTO
    let expectedJobs: [JobDTO]?
    let expectedEffects: [EffectDTO]

    struct JobDTO: Decodable {
        let jobId: String
        let revisionId: String
        let state: String
        let failure: String?
    }

    struct StateDTO: Decodable {
        let status: String
        let jobId: String?
        let revisionId: String?
        let selectedRevisionId: String?
        let phase: String?
        let progress: ProgressDTO?
        let reason: String?
        let actions: [String]?
    }

    struct ProgressDTO: Decodable, Equatable {
        let completedWindows: UInt32
        let totalWindows: UInt32
        let approximateEtaSeconds: UInt32?
    }

    struct CommandDTO: Decodable { let kind: String }

    struct EventDTO: Decodable {
        let port: String
        let effect: String
        let outcome: String
    }

    struct EffectDTO: Decodable { let kind: String }
}

private struct SessionProcessingFeatureScenario {
    enum Kind: String {
        case qualifiedSuccess = "qualified-offline-success"
        case qualificationBlocked = "qualification-blocked-no-fallback"
        case candidateRejected = "candidate-rejected-no-publication"
        case modelPrepareStart = "model-prepare-start"
        case cancellation = "cancel-reaps-retains-session"
        case progress = "progress-monotonic-eta-approximate"
        case relaunchQueued = "relaunch-queued-interrupted"
        case relaunchRunning = "relaunch-running-absent-interrupted"
        case relaunchValidation = "relaunch-validating-resumes-idempotently"
        case relaunchStaleSelection = "relaunch-validating-stale-selection"
    }

    let id: String
    let kind: Kind
    let initialJobs: [FeatureScenarioJob]
    let initialState: FeatureScenarioState
    let commands: [String]
    let dependencyTrace: [ObservedEvent]
    let expectedState: FeatureScenarioState
    let hasExpectedJobs: Bool
    let expectedJobs: [FeatureScenarioJob]
    let expectedEffects: Set<String>

    init(_ dto: SessionProcessingFeatureScenarioDTO) throws {
        let prefix = "session-processing."
        guard dto.schemaVersion == 1,
              dto.scenarioId.hasPrefix(prefix),
              let kind = Kind(
                rawValue: String(dto.scenarioId.dropFirst(prefix.count))
              )
        else { throw FeatureScenarioError.invalidEnvelope }

        id = dto.scenarioId
        self.kind = kind
        initialJobs = try (dto.initialJobs ?? []).map(FeatureScenarioJob.init)
        initialState = FeatureScenarioState(dto.initialState)
        commands = dto.commands.map(\.kind)
        dependencyTrace = dto.dependencyTrace.map {
            ObservedEvent(port: $0.port, effect: $0.effect, outcome: $0.outcome)
        }
        expectedState = FeatureScenarioState(dto.expectedState)
        hasExpectedJobs = dto.expectedJobs != nil
        expectedJobs = try (dto.expectedJobs ?? []).map(FeatureScenarioJob.init)
        expectedEffects = Set(dto.expectedEffects.map(\.kind))
    }
}

private enum FeatureScenarioError: Error {
    case invalidEnvelope
    case invalidIdentifier
    case invalidState
}

private struct FeatureScenarioJob: Equatable, Sendable {
    let jobID: String
    let revisionID: String
    let state: SessionProcessingJobState
    let failure: SessionProcessingFailureReason?

    init(_ dto: SessionProcessingFeatureScenarioDTO.JobDTO) throws {
        guard (try? TranscriptionJobID(dto.jobId)) != nil,
              (try? TranscriptRevisionID(dto.revisionId)) != nil,
              let state = SessionProcessingJobState(rawValue: dto.state),
              dto.failure == nil ||
                dto.failure.flatMap(SessionProcessingFailureReason.init) != nil
        else { throw FeatureScenarioError.invalidIdentifier }
        jobID = dto.jobId
        revisionID = dto.revisionId
        self.state = state
        failure = dto.failure.flatMap(SessionProcessingFailureReason.init)
    }

    init(_ job: SessionProcessingJob) {
        jobID = job.jobID.rawValue
        revisionID = job.revisionID.rawValue
        state = job.state
        failure = job.failure
    }
}

private struct FeatureScenarioState: Equatable, Sendable {
    struct Progress: Equatable, Sendable {
        let completedWindows: UInt32
        let totalWindows: UInt32
        let approximateETASeconds: UInt32?
    }

    let status: String
    let jobID: String?
    let revisionID: String?
    let selectedRevisionID: String?
    let phase: String?
    let progress: Progress?
    let reason: String?
    let actions: [String]

    init(_ dto: SessionProcessingFeatureScenarioDTO.StateDTO) {
        status = dto.status
        jobID = dto.jobId
        revisionID = dto.revisionId
        selectedRevisionID = dto.selectedRevisionId
        phase = dto.phase
        progress = dto.progress.map {
            Progress(
                completedWindows: $0.completedWindows,
                totalWindows: $0.totalWindows,
                approximateETASeconds: $0.approximateEtaSeconds
            )
        }
        reason = dto.reason
        actions = dto.actions ?? []
    }

    init(_ state: SessionProcessingFeatureState) {
        switch state {
        case let .unavailable(snapshot):
            status = "unavailable"
            jobID = nil
            revisionID = nil
            selectedRevisionID = nil
            phase = nil
            progress = nil
            reason = Self.unavailableReason(snapshot.reason)
            actions = snapshot.actions.map(\.rawValue)
        case .ready:
            status = "ready"
            jobID = nil
            revisionID = nil
            selectedRevisionID = nil
            phase = nil
            progress = nil
            reason = nil
            actions = []
        case let .preparing(_, action):
            status = "preparing"
            jobID = nil
            revisionID = nil
            selectedRevisionID = nil
            phase = "preparing"
            progress = nil
            reason = nil
            actions = [action.rawValue]
        case let .queued(snapshot):
            status = "queued"
            jobID = snapshot.job.jobID.rawValue
            revisionID = nil
            selectedRevisionID = nil
            phase = nil
            progress = nil
            reason = nil
            actions = snapshot.actions.map(\.rawValue)
        case let .running(snapshot), let .cancelling(snapshot),
             let .validating(snapshot):
            status = switch state {
            case .running: "running"
            case .cancelling: "cancelling"
            default: "validating"
            }
            jobID = snapshot.job.jobID.rawValue
            revisionID = nil
            selectedRevisionID = nil
            phase = snapshot.phase.rawValue
            progress = snapshot.progress.map {
                Progress(
                    completedWindows: $0.completedWindows,
                    totalWindows: $0.totalWindows,
                    approximateETASeconds: $0.approximateETASeconds
                )
            }
            reason = nil
            actions = status == "running" ? ["cancel"] : []
        case let .completed(snapshot):
            status = "completed"
            jobID = nil
            revisionID = snapshot.revisionID.rawValue
            selectedRevisionID = snapshot.selectedRevisionID?.rawValue
            phase = nil
            progress = nil
            reason = nil
            actions = []
        case let .failed(snapshot):
            status = "failed"
            jobID = nil
            revisionID = nil
            selectedRevisionID = nil
            phase = nil
            progress = nil
            reason = snapshot.reason.rawValue
            actions = snapshot.actions.map(\.rawValue)
        case let .cancelled(snapshot):
            status = "cancelled"
            jobID = snapshot.job.jobID.rawValue
            revisionID = nil
            selectedRevisionID = nil
            phase = nil
            progress = nil
            reason = nil
            actions = snapshot.actions.map(\.rawValue)
        case let .interrupted(snapshot):
            status = "interrupted"
            jobID = snapshot.job.jobID.rawValue
            revisionID = nil
            selectedRevisionID = nil
            phase = nil
            progress = nil
            reason = nil
            actions = snapshot.actions.map(\.rawValue)
        case let .recoveryRequired(job):
            status = "recoveryRequired"
            jobID = job.jobID.rawValue
            revisionID = nil
            selectedRevisionID = nil
            phase = nil
            progress = nil
            reason = nil
            actions = []
        }
    }

    private static func unavailableReason(
        _ reason: SessionProcessingUnavailableReason
    ) -> String {
        switch reason {
        case .noSession: "noSession"
        case .jobIndexSchemaNewer: "jobIndexSchemaNewer"
        case .sourceUnavailable: "sourceUnavailable"
        case .sourceIntegrityMismatch: "sourceIntegrityMismatch"
        case .acousticEvidenceUnavailable: "acousticEvidenceUnavailable"
        case .qualificationBlocked: "qualificationBlocked"
        case .runtimeMissing: "runtimeMissing"
        case .runtimeLockMismatch: "runtimeLockMismatch"
        case .modelMissing: "modelMissing"
        case .modelCorrupt: "modelCorrupt"
        case .modelLockMismatch: "modelLockMismatch"
        }
    }
}

private struct SessionProcessingFeatureScenarioObservation {
    let initialState: FeatureScenarioState
    let trace: [ObservedEvent]
    let finalState: FeatureScenarioState
    let durableJobs: [FeatureScenarioJob]
    let effects: Set<String>
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
private struct SessionProcessingFeatureScenarioRunner {
    let scenario: SessionProcessingFeatureScenario

    func run() async throws -> SessionProcessingFeatureScenarioObservation {
        let fixture = try RaceFixture()
        let trace = FeatureScenarioTrace()
        let sourceValue = try fixture.source(for: scenario.kind)
        let initialJobs = try scenario.initialJobs.map {
            try fixture.job(from: $0)
        }
        let source = FeatureScenarioSource(
            source: sourceValue,
            kind: scenario.kind,
            trace: trace
        )
        let runtime = FeatureScenarioRuntime(
            profile: fixture.profile,
            kind: scenario.kind,
            trace: trace
        )
        let model = FeatureScenarioModel(kind: scenario.kind, trace: trace)
        let acoustics = FeatureScenarioAcoustics(
            evidence: fixture.evidence,
            trace: trace
        )
        let jobs = FeatureScenarioJobStore(
            initialJobs: initialJobs,
            scope: fixture.selection.scope,
            kind: scenario.kind,
            trace: trace
        )
        let engine = FeatureScenarioEngine(
            kind: scenario.kind,
            fixture: fixture,
            trace: trace
        )
        let revisions = try FeatureScenarioRevisionRepository(
            kind: scenario.kind,
            fixture: fixture,
            trace: trace
        )
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: runtime,
            model: model,
            acoustics: acoustics,
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: try FeatureScenarioClock(fixture: fixture, trace: trace),
            identifiers: try FeatureScenarioIdentifiers(fixture: fixture, trace: trace)
        )

        let initialState: FeatureScenarioState
        var processing: Task<Void, Never>?
        switch scenario.kind {
        case .progress:
            await trace.setEnabled(false)
            await feature.send(.selectSession(fixture.selection))
            initialState = FeatureScenarioState(await feature.currentState)
            await trace.resetAndEnable()
            processing = Task { await feature.send(.start) }
            await engine.waitUntilHeld()
        case .cancellation:
            await trace.setEnabled(false)
            processing = Task {
                await feature.send(.selectSession(fixture.selection))
                await feature.send(.start)
            }
            await engine.waitUntilHeld()
            initialState = FeatureScenarioState(await feature.currentState)
            await trace.resetAndEnable()
        case .qualifiedSuccess, .qualificationBlocked, .candidateRejected,
             .modelPrepareStart, .relaunchQueued, .relaunchRunning,
             .relaunchValidation, .relaunchStaleSelection:
            initialState = FeatureScenarioState(await feature.currentState)
        }

        if scenario.kind == .progress {
            // Start is already suspended after delivering the fixture's progress.
        } else {
            for rawCommand in scenario.commands {
                await feature.send(try featureCommand(rawCommand, fixture: fixture))
            }
        }
        let finalState = FeatureScenarioState(await feature.currentState)

        if scenario.kind == .progress {
            await trace.setEnabled(false)
            await engine.releaseHeldRunAsFailure()
        }
        await processing?.value

        let durable = await jobs.jobs.map(FeatureScenarioJob.init)
        let observedTrace = await trace.events
        let effects = await observedEffects(
            fixture: fixture,
            finalState: finalState,
            durableJobs: durable,
            source: source,
            runtime: runtime,
            model: model,
            jobs: jobs,
            engine: engine,
            revisions: revisions
        )
        return SessionProcessingFeatureScenarioObservation(
            initialState: initialState,
            trace: observedTrace,
            finalState: finalState,
            durableJobs: durable,
            effects: effects
        )
    }

    private func featureCommand(
        _ rawValue: String,
        fixture: RaceFixture
    ) throws -> SessionProcessingCommand {
        switch rawValue {
        case "activateLibrary": .activateLibrary(fixture.selection.scope)
        case "selectSession": .selectSession(fixture.selection)
        case "start": .start
        case "cancel": .cancel
        case "prepare": .prepare
        default: throw FeatureScenarioError.invalidEnvelope
        }
    }

    private func observedEffects(
        fixture: RaceFixture,
        finalState: FeatureScenarioState,
        durableJobs: [FeatureScenarioJob],
        source: FeatureScenarioSource,
        runtime: FeatureScenarioRuntime,
        model: FeatureScenarioModel,
        jobs: FeatureScenarioJobStore,
        engine: FeatureScenarioEngine,
        revisions: FeatureScenarioRevisionRepository
    ) async -> Set<String> {
        let sourceSelections = await source.selections
        let runtimeMetrics = await runtime.metrics
        let modelMetrics = await model.metrics
        let jobMetrics = await jobs.metrics
        let engineMetrics = await engine.metrics
        let revisionMetrics = await revisions.metrics
        var effects: Set<String> = []

        switch scenario.kind {
        case .qualifiedSuccess, .modelPrepareStart:
            if engineMetrics.transcriptionCount == 1 { effects.insert("networkDisabled") }
            if engineMetrics.usedExactProfile { effects.insert("exactProfileOnly") }
            if engineMetrics.transcriptionCount == 1,
               scenario.kind == .qualifiedSuccess
            {
                effects.insert("oneUntrustedCandidate")
            }
            if revisionMetrics.publishCount == 1 {
                effects.insert("publishedThroughValidator")
            }
            if revisionMetrics.successfulPublicationCount == 1,
               finalState.revisionID == finalState.selectedRevisionID
            {
                effects.insert("selectedAtomically")
            }
        case .qualificationBlocked:
            if jobMetrics.createCount == 0 { effects.insert("noJobCreated") }
            if engineMetrics.transcriptionCount == 0 { effects.insert("noEngineLaunch") }
            if revisionMetrics.successfulPublicationCount == 0 {
                effects.insert("noPublication")
            }
            if runtimeMetrics.blockedResolutionCount == 1,
               modelMetrics.verifyCount == 0,
               engineMetrics.transcriptionCount == 0
            {
                effects.insert("noFallback")
            }
        case .candidateRejected:
            if engineMetrics.transcriptionCount == 1 {
                effects.insert("oneUntrustedCandidate")
            }
            if finalState.reason == "candidateRejected" {
                effects.insert("publishedThroughValidator")
            }
            if revisionMetrics.successfulPublicationCount == 0 {
                effects.insert("noPublication")
            }
        case .cancellation:
            if durableJobs.first?.state == .cancelled,
               jobMetrics.sawCancellationRequest
            {
                effects.insert("cancellationAuthorityPersisted")
            }
            if engineMetrics.cancellationCount == 1 { effects.insert("workerReaped") }
            if finalState.status == "cancelled",
               engineMetrics.transcriptionCount == 1
            {
                effects.insert("lateCandidateRejected")
            }
            if sourceSelections.contains(fixture.selection) {
                effects.insert("sessionRetained")
            }
            if revisionMetrics.successfulPublicationCount == 0 {
                effects.insert("noPublication")
            }
        case .progress:
            if finalState.progress?.completedWindows == 2,
               finalState.progress?.totalWindows == 4
            {
                effects.insert("progressMonotonic")
            }
            if finalState.progress?.approximateETASeconds == 5 {
                effects.insert("etaApproximate")
            }
            if revisionMetrics.successfulPublicationCount == 0 {
                effects.insert("noPublication")
            }
        case .relaunchQueued, .relaunchRunning, .relaunchValidation,
             .relaunchStaleSelection:
            if jobMetrics.inventoryCount == 1,
               durableJobs.count == scenario.initialJobs.count
            {
                effects.insert("allDurableJobsReconciled")
            }
            if scenario.kind == .relaunchQueued || scenario.kind == .relaunchRunning {
                if durableJobs.allSatisfy({ $0.jobID == fixture.jobID.rawValue }) {
                    effects.insert("sessionRetained")
                }
                if engineMetrics.transcriptionCount == 0 {
                    effects.insert("noEngineLaunch")
                }
            }
            if revisionMetrics.successfulPublicationCount == 0 {
                effects.insert("noPublication")
            }
            if scenario.kind == .relaunchQueued,
               durableJobs.first?.state == .interrupted
            {
                effects.insert("queuedInterrupted")
            }
            if scenario.kind == .relaunchRunning,
               engineMetrics.presenceCount == 1
            {
                effects.insert("processAbsenceConfirmed")
            }
            if scenario.kind == .relaunchValidation,
               revisionMetrics.reopenCount == 1
            {
                effects.insert("canonicalRevisionReopened")
                if revisionMetrics.publishCount == 0,
                   durableJobs.first?.state == .completed
                {
                    effects.insert("publicationIdempotent")
                }
            }
            if scenario.kind == .relaunchStaleSelection {
                if engineMetrics.recoveryCount == 1 {
                    effects.insert("stagedCandidateRevalidated")
                }
                if revisionMetrics.lastExpectedSelection == nil,
                   sourceSelections.first == fixture.selection
                {
                    effects.insert("startSelectionBaselinePreserved")
                }
                if durableJobs.first?.failure == .staleSelection {
                    effects.insert("staleSelectionRejected")
                }
            }
        }
        return effects
    }
}

private actor FeatureScenarioTrace {
    private(set) var events: [ObservedEvent] = []
    private var isEnabled = true

    func setEnabled(_ enabled: Bool) { isEnabled = enabled }

    func resetAndEnable() {
        events.removeAll(keepingCapacity: false)
        isEnabled = true
    }

    func append(port: String, effect: String, outcome: String) {
        guard isEnabled else { return }
        events.append(ObservedEvent(port: port, effect: effect, outcome: outcome))
    }
}

private extension RaceFixture {
    func source(
        for kind: SessionProcessingFeatureScenario.Kind
    ) throws -> SessionTranscriptionSource {
        let selectedRevisionID: TranscriptRevisionID? = kind == .relaunchStaleSelection
            ? try TranscriptRevisionID("trv-20260830T121000000Z-9XYZ")
            : nil
        return SessionTranscriptionSource(
            selection: selection,
            audioCapabilityID: source.audioCapabilityID,
            durationMilliseconds: source.durationMilliseconds,
            audioFingerprint: source.audioFingerprint,
            sourceFingerprints: source.sourceFingerprints,
            expectedSelectedRevisionID: selectedRevisionID
        )
    }

    func job(from observed: FeatureScenarioJob) throws -> SessionProcessingJob {
        guard observed.jobID == jobID.rawValue,
              observed.revisionID == revisionID.rawValue
        else { throw FeatureScenarioError.invalidIdentifier }
        return SessionProcessingJob(
            jobID: jobID,
            sessionID: selection.sessionID,
            revisionID: revisionID,
            profileID: profile.profileID,
            createdAt: createdAt,
            state: observed.state,
            expectedSelectedRevisionID: nil,
            cancellationAuthorityID: cancellationAuthorityID,
            candidateArtifactSHA256: observed.state == .validating
                ? candidateFingerprint.sha256
                : nil,
            failure: observed.failure
        )
    }

    func verifiedCandidate(rejected: Bool = false) -> VerifiedTranscriptionCandidate {
        let output: TranscriptionCandidate
        if rejected {
            output = TranscriptionCandidate(
                schemaVersion: candidate.schemaVersion,
                jobID: candidate.jobID,
                sessionID: "ses-20260830T121100000Z-9XYZ",
                revisionID: candidate.revisionID,
                durationMilliseconds: candidate.durationMilliseconds,
                audioFingerprintSHA256: candidate.audioFingerprintSHA256,
                sourceFingerprints: candidate.sourceFingerprints,
                candidateArtifactSHA256: candidate.candidateArtifactSHA256,
                engine: candidate.engine,
                lines: candidate.lines,
                audioEvents: candidate.audioEvents
            )
        } else {
            output = candidate
        }
        return VerifiedTranscriptionCandidate(
            candidate: output,
            artifactFingerprint: candidateFingerprint
        )
    }

    func validatedRevision() throws -> TranscriptRevision {
        try TranscriptCandidateValidator().validate(
            candidate,
            against: TranscriptPublicationContext(
                jobID: jobID,
                sessionID: selection.sessionID,
                revisionID: revisionID,
                createdAt: createdAt,
                durationMilliseconds: source.durationMilliseconds,
                audioFingerprint: source.audioFingerprint,
                sourceFingerprints: source.sourceFingerprints,
                verifiedCandidateArtifactFingerprint: candidateFingerprint,
                engine: profile.engine,
                voicedRanges: evidence.voicedRanges
            )
        )
    }
}

private actor FeatureScenarioSource: SessionTranscriptionSourcePort {
    private let source: SessionTranscriptionSource
    private let kind: SessionProcessingFeatureScenario.Kind
    private let trace: FeatureScenarioTrace
    private(set) var selections: [SessionProcessingSelection] = []

    init(
        source: SessionTranscriptionSource,
        kind: SessionProcessingFeatureScenario.Kind,
        trace: FeatureScenarioTrace
    ) {
        self.source = source
        self.kind = kind
        self.trace = trace
    }

    func load(_ selection: SessionProcessingSelection) async
        -> SessionTranscriptionSourceResult
    {
        await loaded(selection)
    }

    func load(
        _ selection: SessionProcessingSelection,
        reconciliationID: SessionProcessingReconciliationID
    ) async -> SessionTranscriptionSourceResult {
        await loaded(selection)
    }

    private func loaded(
        _ selection: SessionProcessingSelection
    ) async -> SessionTranscriptionSourceResult {
        selections.append(selection)
        let outcome = kind == .relaunchStaleSelection ? "newer-selection" : "available"
        await trace.append(port: "source", effect: "load", outcome: outcome)
        return selection == source.selection ? .available(source) : .unavailable
    }
}

private actor FeatureScenarioRuntime: TranscriptionRuntimePort {
    struct Metrics { let blockedResolutionCount: Int }

    private let profile: QualifiedTranscriptionProfile
    private let kind: SessionProcessingFeatureScenario.Kind
    private let trace: FeatureScenarioTrace
    private var blockedResolutionCount = 0

    init(
        profile: QualifiedTranscriptionProfile,
        kind: SessionProcessingFeatureScenario.Kind,
        trace: FeatureScenarioTrace
    ) {
        self.profile = profile
        self.kind = kind
        self.trace = trace
    }

    var metrics: Metrics { Metrics(blockedResolutionCount: blockedResolutionCount) }

    func resolve() async -> TranscriptionRuntimeResolution {
        if kind == .qualificationBlocked {
            blockedResolutionCount += 1
            await trace.append(
                port: "runtime",
                effect: "resolve",
                outcome: "qualificationBlocked"
            )
            return .unavailable(.qualificationBlocked(profileID: profile.profileID))
        }
        await trace.append(port: "runtime", effect: "resolve", outcome: "qualified")
        return .qualified(profile)
    }

    func prepare(_ action: SessionProcessingRecoveryAction) async
        -> TranscriptionRuntimeResolution
    {
        await trace.append(port: "runtime", effect: "prepare", outcome: "qualified")
        return .qualified(profile)
    }

    func executionCapability(
        for profile: QualifiedTranscriptionProfile
    ) async -> VerifiedTranscriptionRuntime? {
        guard profile == self.profile else { return nil }
        return VerifiedTranscriptionRuntime(
            capabilityID: try! TranscriptionRuntimeCapabilityID(
                "runtime-feature-scenario"
            ),
            profileID: profile.profileID,
            runtimeIdentity: profile.runtimeVersion
        )
    }
}

private actor FeatureScenarioModel: TranscriptionModelPort {
    struct Metrics { let verifyCount: Int }

    private let kind: SessionProcessingFeatureScenario.Kind
    private let trace: FeatureScenarioTrace
    private var verifyCount = 0

    init(kind: SessionProcessingFeatureScenario.Kind, trace: FeatureScenarioTrace) {
        self.kind = kind
        self.trace = trace
    }

    var metrics: Metrics { Metrics(verifyCount: verifyCount) }

    func verify(_ profile: QualifiedTranscriptionProfile) async
        -> TranscriptionModelResolution
    {
        verifyCount += 1
        let missing = kind == .modelPrepareStart && verifyCount == 1
        await trace.append(
            port: "model",
            effect: "verify",
            outcome: missing ? "missing" : "ready"
        )
        return missing ? .missing : .ready
    }

    func prepare(
        _ action: SessionProcessingRecoveryAction,
        profile: QualifiedTranscriptionProfile
    ) async -> TranscriptionModelResolution {
        await trace.append(port: "model", effect: "prepare", outcome: "ready")
        return .ready
    }

    func executionCapability(
        for profile: QualifiedTranscriptionProfile
    ) async -> VerifiedTranscriptionModel? {
        VerifiedTranscriptionModel(
            capabilityID: try! TranscriptionModelCapabilityID(
                "model-feature-scenario"
            ),
            profileID: profile.profileID,
            modelRevision: profile.modelRevision
        )
    }
}

private actor FeatureScenarioAcoustics: SessionAcousticEvidencePort {
    private let evidence: SessionVoicedRangeEvidence
    private let trace: FeatureScenarioTrace

    init(evidence: SessionVoicedRangeEvidence, trace: FeatureScenarioTrace) {
        self.evidence = evidence
        self.trace = trace
    }

    func resolve(
        for source: SessionTranscriptionSource,
        profile: QualifiedTranscriptionProfile
    ) async -> SessionAcousticEvidenceResolution {
        await trace.append(
            port: "acousticEvidence",
            effect: "resolve",
            outcome: "qualified"
        )
        return .qualified(evidence)
    }
}

private actor FeatureScenarioJobStore: SessionProcessingJobPort {
    struct Metrics {
        let inventoryCount: Int
        let createCount: Int
        let sawCancellationRequest: Bool
    }

    private let scope: LibraryScope
    private let kind: SessionProcessingFeatureScenario.Kind
    private let trace: FeatureScenarioTrace
    private var orderedIDs: [TranscriptionJobID]
    private var jobsByID: [TranscriptionJobID: SessionProcessingJob]
    private var inventoryCount = 0
    private var createCount = 0
    private var sawCancellationRequest = false

    init(
        initialJobs: [SessionProcessingJob],
        scope: LibraryScope,
        kind: SessionProcessingFeatureScenario.Kind,
        trace: FeatureScenarioTrace
    ) {
        self.scope = scope
        self.kind = kind
        self.trace = trace
        orderedIDs = initialJobs.map(\.jobID)
        jobsByID = Dictionary(uniqueKeysWithValues: initialJobs.map { ($0.jobID, $0) })
    }

    var jobs: [SessionProcessingJob] { orderedIDs.compactMap { jobsByID[$0] } }

    var metrics: Metrics {
        Metrics(
            inventoryCount: inventoryCount,
            createCount: createCount,
            sawCancellationRequest: sawCancellationRequest
        )
    }

    func inventory(
        for scope: LibraryScope
    ) async -> SessionProcessingJobInventoryResult {
        guard scope == self.scope else { return .unavailable }
        inventoryCount += 1
        await trace.append(
            port: "jobs",
            effect: "inventory",
            outcome: "all-durable-jobs-bounded"
        )
        return .available(
            SessionProcessingJobInventory(
                reconciliationID: try! SessionProcessingReconciliationID(
                    "reconcile-feature-scenario"
                ),
                scope: scope,
                jobs: jobs
            )
        )
    }

    func latest(
        for selection: SessionProcessingSelection
    ) async -> SessionProcessingJobLoadResult {
        let latest = jobs.last { $0.sessionID == selection.sessionID }
        await trace.append(
            port: "jobs",
            effect: "latest",
            outcome: latest == nil ? "none" : "loaded"
        )
        return latest.map(SessionProcessingJobLoadResult.loaded) ?? .none
    }

    func load(
        jobID: TranscriptionJobID,
        for selection: SessionProcessingSelection
    ) async -> SessionProcessingJobLoadResult {
        guard let job = jobsByID[jobID], job.sessionID == selection.sessionID else {
            return .none
        }
        return .loaded(job)
    }

    func create(_ job: SessionProcessingJob) async -> SessionProcessingJobWriteResult {
        guard jobsByID[job.jobID] == nil else { return .collision }
        createCount += 1
        orderedIDs.append(job.jobID)
        jobsByID[job.jobID] = job
        await trace.append(port: "jobs", effect: "create", outcome: "written")
        return .written(job)
    }

    func transition(
        _ job: SessionProcessingJob,
        from expected: SessionProcessingJobState
    ) async -> SessionProcessingJobWriteResult {
        guard let current = jobsByID[job.jobID], current.state == expected else {
            return .stale
        }
        let effect: String
        if job.state == .running, job.cancellationRequestedAt != nil {
            sawCancellationRequest = true
            effect = "persistCancellationRequest"
        } else {
            effect = switch job.state {
            case .running: "transitionRunning"
            case .validating: "transitionValidating"
            case .completed: "transitionCompleted"
            case .failed: "transitionFailed"
            case .cancelled: "transitionCancelled"
            case .interrupted: "transitionInterrupted"
            case .queued: "transitionQueued"
            case .preparing: "transitionPreparing"
            }
        }
        if kind == .candidateRejected,
           job.state == .failed,
           job.failure == .candidateRejected
        {
            await trace.append(
                port: "publisher",
                effect: "publish",
                outcome: "candidateRejected"
            )
        }
        let outcome = kind == .relaunchQueued && job.state == .interrupted
            ? "cas-written-once"
            : "written"
        jobsByID[job.jobID] = job
        await trace.append(port: "jobs", effect: effect, outcome: outcome)
        return .written(job)
    }
}

private actor FeatureScenarioEngine: TranscriptionEngine {
    struct Metrics {
        let transcriptionCount: Int
        let cancellationCount: Int
        let presenceCount: Int
        let recoveryCount: Int
        let usedExactProfile: Bool
    }

    private let kind: SessionProcessingFeatureScenario.Kind
    private let fixture: RaceFixture
    private let trace: FeatureScenarioTrace
    private var transcriptionCount = 0
    private var cancellationCount = 0
    private var presenceCount = 0
    private var recoveryCount = 0
    private var usedExactProfile = false
    private var heldContinuation:
        CheckedContinuation<VerifiedTranscriptionCandidate, any Error>?
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var isHeld = false

    init(
        kind: SessionProcessingFeatureScenario.Kind,
        fixture: RaceFixture,
        trace: FeatureScenarioTrace
    ) {
        self.kind = kind
        self.fixture = fixture
        self.trace = trace
    }

    var metrics: Metrics {
        Metrics(
            transcriptionCount: transcriptionCount,
            cancellationCount: cancellationCount,
            presenceCount: presenceCount,
            recoveryCount: recoveryCount,
            usedExactProfile: usedExactProfile
        )
    }

    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> VerifiedTranscriptionCandidate {
        transcriptionCount += 1
        usedExactProfile = request.profileID == fixture.profile.profileID &&
            request.runtimeVersion == fixture.profile.runtimeVersion &&
            request.modelRevision == fixture.profile.modelRevision

        if kind == .progress || kind == .cancellation {
            await events(.phase(.loadingModel))
            await events(.progress(completed: 1, total: 4, etaSeconds: 9))
            await events(.progress(completed: 0, total: 4, etaSeconds: 10))
            await events(.progress(completed: 2, total: 4, etaSeconds: 5))
            if kind == .progress {
                await trace.append(
                    port: "engine",
                    effect: "transcribe",
                    outcome: "loadingModel;1-of-4;0-of-4-ignored;2-of-4;eta-5"
                )
            }
            isHeld = true
            heldWaiter?.resume()
            heldWaiter = nil
            return try await withCheckedThrowingContinuation { continuation in
                heldContinuation = continuation
            }
        }

        await trace.append(port: "engine", effect: "transcribe", outcome: "candidate")
        return fixture.verifiedCandidate(rejected: kind == .candidateRejected)
    }

    func cancel(
        _ execution: TranscriptionExecutionReference
    ) async -> TranscriptionCancellationOutcome {
        cancellationCount += 1
        await trace.append(
            port: "engine",
            effect: "cancelAndReap",
            outcome: "reaped-once"
        )
        let continuation = heldContinuation
        heldContinuation = nil
        continuation?.resume(returning: fixture.verifiedCandidate())
        return .reaped
    }

    func workerPresence(
        for execution: TranscriptionExecutionReference
    ) async -> TranscriptionWorkerPresence {
        presenceCount += 1
        await trace.append(
            port: "engine",
            effect: "workerPresence",
            outcome: "absent"
        )
        return .absent
    }

    func recoverCandidate(
        for job: SessionProcessingJob
    ) async -> StagedTranscriptionCandidateResolution {
        recoveryCount += 1
        await trace.append(
            port: "engine",
            effect: "recoverCandidate",
            outcome: "confined-complete-hash-valid"
        )
        return .available(fixture.verifiedCandidate())
    }

    func waitUntilHeld() async {
        guard !isHeld else { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }

    func releaseHeldRunAsFailure() {
        let continuation = heldContinuation
        heldContinuation = nil
        continuation?.resume(throwing: TranscriptionEngineFailure.launchFailed)
    }
}

private actor FeatureScenarioRevisionRepository: TranscriptRevisionRepository {
    struct Metrics {
        let publishCount: Int
        let successfulPublicationCount: Int
        let reopenCount: Int
        let lastExpectedSelection: TranscriptRevisionID?
    }

    private let kind: SessionProcessingFeatureScenario.Kind
    private let revision: TranscriptRevision
    private let trace: FeatureScenarioTrace
    private var publishCount = 0
    private var successfulPublicationCount = 0
    private var reopenCount = 0
    private var lastExpectedSelection: TranscriptRevisionID?

    init(
        kind: SessionProcessingFeatureScenario.Kind,
        fixture: RaceFixture,
        trace: FeatureScenarioTrace
    ) throws {
        self.kind = kind
        revision = try fixture.validatedRevision()
        self.trace = trace
    }

    var metrics: Metrics {
        Metrics(
            publishCount: publishCount,
            successfulPublicationCount: successfulPublicationCount,
            reopenCount: reopenCount,
            lastExpectedSelection: lastExpectedSelection
        )
    }

    func publishAndSelect(
        _ revision: TranscriptRevision,
        expectedSelectedRevisionID: TranscriptRevisionID?
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        publishCount += 1
        lastExpectedSelection = expectedSelectedRevisionID
        if kind == .relaunchStaleSelection {
            await trace.append(
                port: "publisher",
                effect: "publish",
                outcome: "staleSelection"
            )
            throw TranscriptRevisionRepositoryFailure.staleSelection
        }
        successfulPublicationCount += 1
        await trace.append(port: "publisher", effect: "publish", outcome: "published")
        return ReopenedTranscriptRevisionSnapshot(
            revisionIDs: [revision.revisionID],
            selectedRevisionID: revision.revisionID,
            selectedRevision: revision
        )
    }

    func reopenSelected(
        sessionID: SessionID
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        throw TranscriptRevisionRepositoryFailure.sessionUnavailable
    }

    func reopenRevision(
        sessionID: SessionID,
        revisionID: TranscriptRevisionID
    ) async throws -> TranscriptRevision {
        guard kind == .relaunchValidation,
              sessionID == revision.sessionID,
              revisionID == revision.revisionID
        else { throw TranscriptRevisionRepositoryFailure.sessionUnavailable }
        reopenCount += 1
        await trace.append(
            port: "publisher",
            effect: "reopenRevision",
            outcome: "exact-job-revision"
        )
        return revision
    }
}

private actor FeatureScenarioClock: SessionProcessingClock {
    private let createdAt: UTCInstant
    private let cancelledAt: UTCInstant
    private let trace: FeatureScenarioTrace
    private var callCount = 0

    init(fixture: RaceFixture, trace: FeatureScenarioTrace) throws {
        createdAt = fixture.createdAt
        cancelledAt = try UTCInstant("2026-08-30T12:07:00.000Z")
        self.trace = trace
    }

    func now() async -> UTCInstant {
        defer { callCount += 1 }
        let instant = callCount == 0 ? createdAt : cancelledAt
        await trace.append(port: "clock", effect: "now", outcome: instant.rawValue)
        return instant
    }
}

private actor FeatureScenarioIdentifiers: SessionProcessingIDGenerator {
    private let fixture: RaceFixture
    private let authority: TranscriptionCancellationAuthorityID
    private let trace: FeatureScenarioTrace

    init(fixture: RaceFixture, trace: FeatureScenarioTrace) throws {
        self.fixture = fixture
        authority = try TranscriptionCancellationAuthorityID(
            "cancel-synthetic-authority"
        )
        self.trace = trace
    }

    func generateJobID(at instant: UTCInstant) async -> TranscriptionJobID {
        await trace.append(
            port: "identifiers",
            effect: "generateJobId",
            outcome: fixture.jobID.rawValue
        )
        return fixture.jobID
    }

    func generateRevisionID(at instant: UTCInstant) async -> TranscriptRevisionID {
        await trace.append(
            port: "identifiers",
            effect: "generateRevisionId",
            outcome: fixture.revisionID.rawValue
        )
        return fixture.revisionID
    }

    func generateCancellationAuthorityID(
        at instant: UTCInstant
    ) async -> TranscriptionCancellationAuthorityID {
        await trace.append(
            port: "identifiers",
            effect: "generateCancellationAuthorityId",
            outcome: authority.rawValue
        )
        return authority
    }
}

private struct SessionProcessingRaceScenarioDTO: Decodable {
    let schemaVersion: UInt32
    let scenarioId: String
    let race: RaceDTO
    let initialJobs: [JobDTO]
    let initialState: StateDTO
    let commands: [CommandDTO]
    let dependencyTrace: [EventDTO]
    let expectedState: StateDTO
    let expectedJobs: [JobDTO]
    let expectedEffects: [EffectDTO]

    struct RaceDTO: Decodable {
        let kind: String
        let firstDurableWinner: String
        let losingCompareAndSwap: String
    }

    struct JobDTO: Decodable {
        let jobId: String
        let revisionId: String
        let state: String
        let failure: String?
    }

    struct StateDTO: Decodable {
        let status: String
        let jobId: String?
        let phase: String?
        let reason: String?
        let actions: [String]
    }

    struct CommandDTO: Decodable { let kind: String }

    struct EventDTO: Decodable {
        let port: String
        let effect: String
        let outcome: String
    }

    struct EffectDTO: Decodable { let kind: String }
}

private struct SessionProcessingRaceScenario {
    enum RaceKind: String {
        case candidateVsCancel
        case engineFailureVsCancel
        case candidateRejectionVsCancel
    }

    enum Winner: String {
        case candidate
        case engineFailure
        case candidateRejection
        case cancellation
    }

    let id: String
    let kind: RaceKind
    let winner: Winner
    let initialJob: ObservedJob
    let initialState: ObservedState
    let dependencyTrace: [ObservedEvent]
    let expectedState: ObservedState
    let expectedJob: ObservedJob
    let expectedEffects: Set<String>

    init(_ dto: SessionProcessingRaceScenarioDTO) throws {
        guard dto.schemaVersion == 1,
              dto.scenarioId.hasPrefix("session-processing.race-"),
              let kind = RaceKind(rawValue: dto.race.kind),
              let winner = Winner(rawValue: dto.race.firstDurableWinner),
              dto.race.losingCompareAndSwap == "stale",
              dto.initialJobs.count == 1,
              dto.expectedJobs.count == 1,
              dto.commands.map(\.kind) == ["cancel"]
        else { throw RaceScenarioError.invalidEnvelope }

        id = dto.scenarioId
        self.kind = kind
        self.winner = winner
        initialJob = try ObservedJob(dto.initialJobs[0])
        initialState = try ObservedState(dto.initialState)
        dependencyTrace = dto.dependencyTrace.map(ObservedEvent.init)
        expectedState = try ObservedState(dto.expectedState)
        expectedJob = try ObservedJob(dto.expectedJobs[0])
        expectedEffects = Set(dto.expectedEffects.map(\.kind))

        guard initialJob.state == .running,
              initialState.status == .running,
              initialState.jobID == initialJob.jobID,
              initialState.phase == .transcribing,
              expectedState.jobID == expectedJob.jobID ||
                expectedState.status == .failed
        else { throw RaceScenarioError.invalidEnvelope }
    }

    var cancellationWins: Bool { winner == .cancellation }
}

private extension SessionProcessingRaceScenario.Winner {
    func matches(_ job: SessionProcessingJob) -> Bool {
        switch self {
        case .candidate:
            job.state == .failed && job.failure == .staleSelection
        case .engineFailure:
            job.state == .failed && job.failure == .engineFailed
        case .candidateRejection:
            job.state == .failed && job.failure == .candidateRejected
        case .cancellation:
            job.state == .cancelled && job.cancellationRequestedAt != nil
        }
    }
}

private enum RaceScenarioError: Error {
    case invalidEnvelope
    case invalidIdentifier
    case invalidState
}

private struct ObservedEvent: Equatable, Sendable {
    let port: String
    let effect: String
    let outcome: String

    init(_ dto: SessionProcessingRaceScenarioDTO.EventDTO) {
        port = dto.port
        effect = dto.effect
        outcome = dto.outcome
    }

    init(port: String, effect: String, outcome: String) {
        self.port = port
        self.effect = effect
        self.outcome = outcome
    }
}

private struct ObservedJob: Equatable, Sendable {
    let jobID: String
    let revisionID: String
    let state: SessionProcessingJobState
    let failure: SessionProcessingFailureReason?

    init(_ dto: SessionProcessingRaceScenarioDTO.JobDTO) throws {
        guard (try? TranscriptionJobID(dto.jobId)) != nil,
              (try? TranscriptRevisionID(dto.revisionId)) != nil,
              let state = SessionProcessingJobState(rawValue: dto.state)
        else { throw RaceScenarioError.invalidIdentifier }
        if let failure = dto.failure,
           SessionProcessingFailureReason(rawValue: failure) == nil
        {
            throw RaceScenarioError.invalidIdentifier
        }
        jobID = dto.jobId
        revisionID = dto.revisionId
        self.state = state
        failure = dto.failure.flatMap(SessionProcessingFailureReason.init)
    }

    init(_ job: SessionProcessingJob) {
        jobID = job.jobID.rawValue
        revisionID = job.revisionID.rawValue
        state = job.state
        failure = job.failure
    }
}

private struct ObservedState: Equatable, Sendable {
    enum Status: String, Sendable {
        case running, failed, cancelled
    }

    let status: Status
    let jobID: String?
    let phase: SessionProcessingActivePhase?
    let reason: SessionProcessingFailureReason?
    let actions: [String]

    init(_ dto: SessionProcessingRaceScenarioDTO.StateDTO) throws {
        guard let status = Status(rawValue: dto.status) else {
            throw RaceScenarioError.invalidState
        }
        self.status = status
        jobID = dto.jobId
        switch dto.phase {
        case nil: phase = nil
        case "transcribing": phase = .transcribing
        default: throw RaceScenarioError.invalidState
        }
        reason = dto.reason.flatMap(SessionProcessingFailureReason.init)
        actions = dto.actions
        switch status {
        case .running:
            guard jobID != nil, phase != nil, reason == nil, actions == ["cancel"]
            else { throw RaceScenarioError.invalidState }
        case .failed:
            guard jobID == nil, phase == nil, reason != nil, actions == ["retry"]
            else { throw RaceScenarioError.invalidState }
        case .cancelled:
            guard jobID != nil, phase == nil, reason == nil, actions == ["retry"]
            else { throw RaceScenarioError.invalidState }
        }
    }

    init(_ state: SessionProcessingFeatureState) throws {
        switch state {
        case let .running(snapshot):
            status = .running
            jobID = snapshot.job.jobID.rawValue
            phase = snapshot.phase
            reason = nil
            actions = ["cancel"]
        case let .failed(snapshot):
            status = .failed
            jobID = nil
            phase = nil
            reason = snapshot.reason
            actions = snapshot.actions.map(\.rawValue)
        case let .cancelled(snapshot):
            status = .cancelled
            jobID = snapshot.job.jobID.rawValue
            phase = nil
            reason = nil
            actions = snapshot.actions.map(\.rawValue)
        default:
            throw RaceScenarioError.invalidState
        }
    }
}

private struct SessionProcessingRaceObservation {
    let initialState: ObservedState
    let trace: [ObservedEvent]
    let finalState: ObservedState
    let durableJob: ObservedJob
    let effects: Set<String>
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
private struct SessionProcessingRaceRunner {
    let scenario: SessionProcessingRaceScenario

    func run() async throws -> SessionProcessingRaceObservation {
        let fixture = try RaceFixture()
        guard fixture.jobID.rawValue == scenario.initialJob.jobID,
              fixture.revisionID.rawValue == scenario.initialJob.revisionID
        else { throw RaceScenarioError.invalidIdentifier }

        let recorder = RaceTraceRecorder()
        let jobs = RaceJobStore(scenario: scenario, recorder: recorder)
        let engine = try RaceEngine(
            scenario: scenario,
            fixture: fixture,
            recorder: recorder
        )
        let revisions = RaceRevisionRepository(recorder: recorder)
        let source = RaceSource(fixture.source)
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RaceRuntime(fixture.profile),
            model: RaceModel(),
            acoustics: RaceAcoustics(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: try RaceClock(createdAt: fixture.createdAt, recorder: recorder),
            identifiers: RaceIdentifiers(fixture: fixture)
        )

        let processing = Task {
            await feature.send(.selectSession(fixture.selection))
            await feature.send(.start)
        }
        await engine.waitUntilTranscriptionStarts()
        let initialState = try ObservedState(await feature.currentState)
        guard let initialDurable = await jobs.currentJob,
              ObservedJob(initialDurable) == scenario.initialJob
        else { throw RaceScenarioError.invalidState }

        await engine.releaseTranscription()
        await jobs.waitUntilTerminalTransitionStarts()
        let cancellation = Task { await feature.send(.cancel) }
        await cancellation.value
        await processing.value

        let finalState = try ObservedState(await feature.currentState)
        guard let durable = await jobs.currentJob else {
            throw RaceScenarioError.invalidState
        }
        let trace = await recorder.events
        let cancellationCount = await engine.cancellationCount
        let transcriptionCount = await engine.transcriptionCount
        let successfulPublications = await revisions.successfulPublicationCount
        let sourceSelections = await source.selections

        var effects: Set<String> = []
        if scenario.winner.matches(durable) {
            effects.insert("firstDurableWinnerPreserved")
        }
        if transcriptionCount == 1 { effects.insert("noAutomaticRerun") }
        if sourceSelections == [fixture.selection] {
            effects.insert("sessionRetained")
        }
        if successfulPublications == 0 { effects.insert("noPublication") }
        if durable.cancellationRequestedAt != nil {
            effects.insert("cancellationAuthorityPersisted")
        }
        if cancellationCount == 1 { effects.insert("workerReaped") }
        if finalState.status == .cancelled,
           transcriptionCount == 1,
           successfulPublications == 0
        {
            effects.insert("lateCandidateRejected")
        }
        if cancellationCount == 0 { effects.insert("noWorkerCancellation") }

        return SessionProcessingRaceObservation(
            initialState: initialState,
            trace: trace,
            finalState: finalState,
            durableJob: ObservedJob(durable),
            effects: effects
        )
    }
}

private struct RaceFixture: Sendable {
    let selection: SessionProcessingSelection
    let source: SessionTranscriptionSource
    let evidence: SessionVoicedRangeEvidence
    let profile: QualifiedTranscriptionProfile
    let jobID: TranscriptionJobID
    let revisionID: TranscriptRevisionID
    let cancellationAuthorityID: TranscriptionCancellationAuthorityID
    let createdAt: UTCInstant
    let candidateFingerprint: AudioFingerprint
    let candidate: TranscriptionCandidate

    init() throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-1ABC")
        )
        let sessionID = try SessionID("ses-20260830T120100000Z-2CDE")
        let sourceID = try AudioSourceID("src-0001")
        let audioFingerprint = try AudioFingerprint(
            sha256: String(repeating: "1", count: 64)
        )
        let sourceFingerprint = TranscriptSourceFingerprint(
            audioSourceID: sourceID,
            fingerprint: audioFingerprint
        )
        let policy = try EngineUsePolicy(
            policyID: "crisper-evaluation-v1",
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
        profile = try QualifiedTranscriptionProfile(
            profileID: "synthetic-qualified-v1",
            protocolVersion: 1,
            runtimeVersion: "synthetic-runtime-v1",
            packageLockSHA256: String(repeating: "4", count: 64),
            modelRevision: "model-revision-v1",
            compatibilityPatchID: "synthetic-progress-patch-v1",
            engine: provenance
        )
        jobID = try TranscriptionJobID("job-20260830T120500000Z-5GHJ")
        revisionID = try TranscriptRevisionID("trv-20260830T120600000Z-6JKM")
        cancellationAuthorityID = try TranscriptionCancellationAuthorityID(
            "cancel-feature-scenario"
        )
        createdAt = try UTCInstant("2026-08-30T12:06:00.000Z")
        candidateFingerprint = try AudioFingerprint(
            sha256: String(repeating: "5", count: 64)
        )
        selection = SessionProcessingSelection(scope: scope, sessionID: sessionID)
        source = SessionTranscriptionSource(
            selection: selection,
            audioCapabilityID: try SessionTranscriptionAudioCapabilityID(
                "cap-feature-scenario-source"
            ),
            durationMilliseconds: 2_000,
            audioFingerprint: audioFingerprint,
            sourceFingerprints: [sourceFingerprint],
            expectedSelectedRevisionID: nil
        )
        evidence = SessionVoicedRangeEvidence(
            qualificationProfileID: profile.profileID,
            extractorID: "synthetic-vad-v1",
            audioFingerprint: audioFingerprint,
            voicedRanges: [
                try SessionTimeRange(
                    startMilliseconds: 0,
                    endMilliseconds: 2_000,
                    sessionDurationMilliseconds: 2_000
                ),
            ]
        )
        candidate = TranscriptionCandidate(
            schemaVersion: 1,
            jobID: jobID.rawValue,
            sessionID: sessionID.rawValue,
            revisionID: revisionID.rawValue,
            durationMilliseconds: 2_000,
            audioFingerprintSHA256: audioFingerprint.sha256,
            sourceFingerprints: [
                CandidateTranscriptSourceFingerprint(
                    audioSourceID: sourceID.rawValue,
                    sha256: audioFingerprint.sha256
                ),
            ],
            candidateArtifactSHA256: candidateFingerprint.sha256,
            engine: CandidateTranscriptEngineProvenance(
                provider: provenance.provider,
                model: provenance.model,
                revision: provenance.revision,
                language: provenance.language,
                mode: provenance.mode,
                decodingOptionsSHA256: provenance.decodingOptionsSHA256,
                qualification: CandidateTranscriptEngineQualification(
                    schemaVersion: TranscriptEngineQualification.schemaVersion,
                    qualificationProfileID: qualification.qualificationProfileID,
                    engineLockSHA256: qualification.engineLockSHA256,
                    runtimeIdentity: qualification.runtimeIdentity,
                    runtimeLockSHA256: qualification.runtimeLockSHA256,
                    compatibilityPatchID: qualification.compatibilityPatchID
                )
            ),
            lines: [
                CandidateTranscriptLine(
                    lineID: "l000000",
                    order: 0,
                    audioSourceID: sourceID.rawValue,
                    timeRange: CandidateSessionTimeRange(
                        startMilliseconds: 0,
                        endMilliseconds: 2_000
                    ),
                    text: "Hello world.",
                    words: [
                        CandidateTranscriptWord(
                            wordID: "w000000",
                            ordinal: 0,
                            text: "Hello",
                            displayRange: CandidateLineTextRange(
                                startUTF8Byte: 0,
                                endUTF8Byte: 5
                            ),
                            timeRange: CandidateSessionTimeRange(
                                startMilliseconds: 0,
                                endMilliseconds: 800
                            ),
                            confidence: 0.99,
                            wordKind: .lexical
                        ),
                        CandidateTranscriptWord(
                            wordID: "w000001",
                            ordinal: 1,
                            text: "world",
                            displayRange: CandidateLineTextRange(
                                startUTF8Byte: 6,
                                endUTF8Byte: 11
                            ),
                            timeRange: CandidateSessionTimeRange(
                                startMilliseconds: 900,
                                endMilliseconds: 1_800
                            ),
                            confidence: 0.98,
                            wordKind: .lexical
                        ),
                    ]
                ),
            ],
            audioEvents: []
        )
    }
}

private actor RaceTraceRecorder {
    private(set) var events: [ObservedEvent] = []

    func append(port: String, effect: String, outcome: String) {
        events.append(ObservedEvent(port: port, effect: effect, outcome: outcome))
    }
}

private actor RaceSource: SessionTranscriptionSourcePort {
    private let source: SessionTranscriptionSource
    private(set) var selections: [SessionProcessingSelection] = []

    init(_ source: SessionTranscriptionSource) { self.source = source }

    func load(_ selection: SessionProcessingSelection) async
        -> SessionTranscriptionSourceResult
    {
        selections.append(selection)
        return selection == source.selection ? .available(source) : .unavailable
    }
}

private actor RaceRuntime: TranscriptionRuntimePort {
    private let profile: QualifiedTranscriptionProfile

    init(_ profile: QualifiedTranscriptionProfile) { self.profile = profile }

    func resolve() async -> TranscriptionRuntimeResolution { .qualified(profile) }

    func prepare(_ action: SessionProcessingRecoveryAction) async
        -> TranscriptionRuntimeResolution
    {
        .qualified(profile)
    }

    func executionCapability(
        for profile: QualifiedTranscriptionProfile
    ) async -> VerifiedTranscriptionRuntime? {
        guard profile == self.profile else { return nil }
        return VerifiedTranscriptionRuntime(
            capabilityID: try! TranscriptionRuntimeCapabilityID(
                "runtime-feature-scenario"
            ),
            profileID: profile.profileID,
            runtimeIdentity: profile.runtimeVersion
        )
    }
}

private actor RaceModel: TranscriptionModelPort {
    func verify(_ profile: QualifiedTranscriptionProfile) async
        -> TranscriptionModelResolution
    {
        .ready
    }

    func prepare(
        _ action: SessionProcessingRecoveryAction,
        profile: QualifiedTranscriptionProfile
    ) async -> TranscriptionModelResolution {
        .ready
    }

    func executionCapability(
        for profile: QualifiedTranscriptionProfile
    ) async -> VerifiedTranscriptionModel? {
        VerifiedTranscriptionModel(
            capabilityID: try! TranscriptionModelCapabilityID(
                "model-feature-scenario"
            ),
            profileID: profile.profileID,
            modelRevision: profile.modelRevision
        )
    }
}

private actor RaceAcoustics: SessionAcousticEvidencePort {
    private let evidence: SessionVoicedRangeEvidence

    init(_ evidence: SessionVoicedRangeEvidence) { self.evidence = evidence }

    func resolve(
        for source: SessionTranscriptionSource,
        profile: QualifiedTranscriptionProfile
    ) async -> SessionAcousticEvidenceResolution {
        .qualified(evidence)
    }
}

private actor RaceJobStore: SessionProcessingJobPort {
    private let scenario: SessionProcessingRaceScenario
    private let recorder: RaceTraceRecorder
    private var durable: SessionProcessingJob?
    private var pendingTerminalJob: SessionProcessingJob?
    private var pendingTerminalContinuation:
        CheckedContinuation<SessionProcessingJobWriteResult, Never>?
    private var terminalTransitionStarted = false

    init(
        scenario: SessionProcessingRaceScenario,
        recorder: RaceTraceRecorder
    ) {
        self.scenario = scenario
        self.recorder = recorder
    }

    var currentJob: SessionProcessingJob? { durable }

    func inventory(
        for scope: LibraryScope
    ) async -> SessionProcessingJobInventoryResult {
        .unavailable
    }

    func finishReconciliation(
        _ reconciliationID: SessionProcessingReconciliationID
    ) async {}

    func latest(for selection: SessionProcessingSelection) async
        -> SessionProcessingJobLoadResult
    {
        durable.map(SessionProcessingJobLoadResult.loaded) ?? .none
    }

    func load(
        jobID: TranscriptionJobID,
        for selection: SessionProcessingSelection
    ) async -> SessionProcessingJobLoadResult {
        await recorder.append(
            port: "jobs",
            effect: "loadExact",
            outcome: "first-durable-winner"
        )
        guard let durable,
              durable.jobID == jobID,
              durable.sessionID == selection.sessionID
        else { return .none }
        return .loaded(durable)
    }

    func create(_ job: SessionProcessingJob) async -> SessionProcessingJobWriteResult {
        guard durable == nil, job.state == .queued else { return .collision }
        durable = job
        return .written(job)
    }

    func transition(
        _ job: SessionProcessingJob,
        from expected: SessionProcessingJobState
    ) async -> SessionProcessingJobWriteResult {
        if isRaceTerminal(job, expected: expected) {
            terminalTransitionStarted = true
            pendingTerminalJob = job
            return await withCheckedContinuation { continuation in
                pendingTerminalContinuation = continuation
            }
        }

        if isCancellationRequest(job, expected: expected) {
            guard let pendingTerminalJob,
                  let pendingTerminalContinuation
            else { return .failed }
            self.pendingTerminalJob = nil
            self.pendingTerminalContinuation = nil

            if scenario.cancellationWins {
                durable = job
                await recorder.append(
                    port: "jobs",
                    effect: "persistCancellationRequest",
                    outcome: "written-first"
                )
                await recorder.append(
                    port: "jobs",
                    effect: terminalEffect(for: pendingTerminalJob),
                    outcome: "stale-lost"
                )
                pendingTerminalContinuation.resume(returning: .stale)
                return .written(job)
            }

            durable = pendingTerminalJob
            await recorder.append(
                port: "jobs",
                effect: terminalEffect(for: pendingTerminalJob),
                outcome: "written-first"
            )
            pendingTerminalContinuation.resume(returning: .written(pendingTerminalJob))
            await recorder.append(
                port: "jobs",
                effect: "persistCancellationRequest",
                outcome: "stale-lost"
            )
            return .stale
        }

        guard let current = durable, current.state == expected else {
            return .stale
        }
        if job.state == .cancelled {
            durable = job
            await recorder.append(
                port: "jobs",
                effect: "transitionCancelled",
                outcome: "written"
            )
            return .written(job)
        }
        if job.state == .failed, expected == .validating {
            durable = job
            await recorder.append(
                port: "jobs",
                effect: "transitionFailed",
                outcome: "written"
            )
            return .written(job)
        }
        durable = job
        return .written(job)
    }

    func waitUntilTerminalTransitionStarts() async {
        while !terminalTransitionStarted { await Task.yield() }
    }

    private func isRaceTerminal(
        _ job: SessionProcessingJob,
        expected: SessionProcessingJobState
    ) -> Bool {
        expected == .running &&
            job.cancellationRequestedAt == nil &&
            (job.state == .validating || job.state == .failed)
    }

    private func isCancellationRequest(
        _ job: SessionProcessingJob,
        expected: SessionProcessingJobState
    ) -> Bool {
        expected == .running &&
            job.state == .running &&
            job.cancellationRequestedAt != nil
    }

    private func terminalEffect(for job: SessionProcessingJob) -> String {
        job.state == .validating ? "transitionValidating" : "transitionFailed"
    }
}

private actor RaceEngine: TranscriptionEngine {
    private let scenario: SessionProcessingRaceScenario
    private let candidate: VerifiedTranscriptionCandidate
    private let recorder: RaceTraceRecorder
    private var transcriptionContinuation: CheckedContinuation<Void, Never>?
    private(set) var transcriptionCount = 0
    private(set) var cancellationCount = 0

    init(
        scenario: SessionProcessingRaceScenario,
        fixture: RaceFixture,
        recorder: RaceTraceRecorder
    ) throws {
        self.scenario = scenario
        self.recorder = recorder
        let fingerprint: AudioFingerprint
        if scenario.kind == .candidateRejectionVsCancel {
            fingerprint = try AudioFingerprint(
                sha256: String(repeating: "9", count: 64)
            )
        } else {
            fingerprint = fixture.candidateFingerprint
        }
        candidate = VerifiedTranscriptionCandidate(
            candidate: fixture.candidate,
            artifactFingerprint: fingerprint
        )
    }

    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> VerifiedTranscriptionCandidate {
        transcriptionCount += 1
        await recorder.append(
            port: "engine",
            effect: "transcribe",
            outcome: transcribeOutcome
        )
        await events(.phase(.transcribing))
        await withCheckedContinuation { continuation in
            transcriptionContinuation = continuation
        }
        if scenario.kind == .engineFailureVsCancel {
            throw TranscriptionEngineFailure.launchFailed
        }
        return candidate
    }

    func cancel(
        _ execution: TranscriptionExecutionReference
    ) async -> TranscriptionCancellationOutcome {
        cancellationCount += 1
        await recorder.append(
            port: "engine",
            effect: "cancelAndReap",
            outcome: "reaped"
        )
        return .reaped
    }

    func recoverCandidate(
        for job: SessionProcessingJob
    ) async -> StagedTranscriptionCandidateResolution {
        .available(candidate)
    }

    func waitUntilTranscriptionStarts() async {
        while transcriptionContinuation == nil { await Task.yield() }
    }

    func releaseTranscription() {
        transcriptionContinuation?.resume()
        transcriptionContinuation = nil
    }

    private var transcribeOutcome: String {
        switch scenario.kind {
        case .candidateVsCancel: "candidate"
        case .engineFailureVsCancel: "engineFailed"
        case .candidateRejectionVsCancel: "candidate-hash-mismatch"
        }
    }
}

private actor RaceRevisionRepository: TranscriptRevisionRepository {
    private let recorder: RaceTraceRecorder
    private(set) var successfulPublicationCount = 0

    init(recorder: RaceTraceRecorder) { self.recorder = recorder }

    func publishAndSelect(
        _ revision: TranscriptRevision,
        expectedSelectedRevisionID: TranscriptRevisionID?
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        await recorder.append(
            port: "publisher",
            effect: "publish",
            outcome: "staleSelection"
        )
        throw TranscriptRevisionRepositoryFailure.staleSelection
    }

    func reopenSelected(
        sessionID: SessionID
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        throw TranscriptRevisionRepositoryFailure.sessionUnavailable
    }

    func reopenRevision(
        sessionID: SessionID,
        revisionID: TranscriptRevisionID
    ) async throws -> TranscriptRevision {
        throw TranscriptRevisionRepositoryFailure.sessionUnavailable
    }
}

private actor RaceClock: SessionProcessingClock {
    private let createdAt: UTCInstant
    private let cancelledAt: UTCInstant
    private let recorder: RaceTraceRecorder
    private var callCount = 0

    init(createdAt: UTCInstant, recorder: RaceTraceRecorder) throws {
        self.createdAt = createdAt
        cancelledAt = try UTCInstant("2026-08-30T12:07:00.000Z")
        self.recorder = recorder
    }

    func now() async -> UTCInstant {
        defer { callCount += 1 }
        guard callCount > 0 else { return createdAt }
        await recorder.append(
            port: "clock",
            effect: "now",
            outcome: cancelledAt.rawValue
        )
        return cancelledAt
    }
}

private actor RaceIdentifiers: SessionProcessingIDGenerator {
    private let fixture: RaceFixture

    init(fixture: RaceFixture) { self.fixture = fixture }

    func generateJobID(at instant: UTCInstant) async -> TranscriptionJobID {
        fixture.jobID
    }

    func generateRevisionID(at instant: UTCInstant) async -> TranscriptRevisionID {
        fixture.revisionID
    }

    func generateCancellationAuthorityID(
        at instant: UTCInstant
    ) async -> TranscriptionCancellationAuthorityID {
        fixture.cancellationAuthorityID
    }
}
