import AudoraApplication
import AudoraDomain
import CryptoKit
import Foundation

public enum TranscriptionWorkerNetworkAccess: String, Equatable, Sendable {
    case disabled
}

public struct ConfinedTranscriptionWorkerLimits: Equatable, Sendable {
    public let standardOutputBytes: UInt64
    public let standardErrorBytes: UInt64
    public let candidateArtifactBytes: UInt64
    public let maximumProtocolMessages: Int
    public let terminationGraceMilliseconds: UInt32

    public init(
        standardOutputBytes: UInt64,
        standardErrorBytes: UInt64,
        candidateArtifactBytes: UInt64,
        maximumProtocolMessages: Int,
        terminationGraceMilliseconds: UInt32
    ) {
        self.standardOutputBytes = standardOutputBytes
        self.standardErrorBytes = standardErrorBytes
        self.candidateArtifactBytes = candidateArtifactBytes
        self.maximumProtocolMessages = maximumProtocolMessages
        self.terminationGraceMilliseconds = terminationGraceMilliseconds
    }

    public static let versionOne = ConfinedTranscriptionWorkerLimits(
        standardOutputBytes: 1_048_576,
        standardErrorBytes: 65_536,
        candidateArtifactBytes: UInt64(TranscriptRevisionLimits.maximumSerializedBytes),
        maximumProtocolMessages: 100_004,
        terminationGraceMilliseconds: 5_000
    )
}

/// Startup input to the OS-specific execution host. The durable execution
/// authority is bound before launch so even a worker stalled before `hello`
/// remains exactly targetable for bounded termination and reap. A conforming
/// production host also fixes the executable and arguments, uses anonymous
/// pipes, supplies an allowlisted empty environment/home, confines relative
/// job/model paths, and applies these bounds before returning any bytes.
public struct ConfinedTranscriptionWorkerInvocation: Sendable {
    public let execution: TranscriptionExecutionReference
    public let profile: QualifiedTranscriptionProfile
    public let runtime: any ConfinedTranscriptionRuntimeExecutionCapability
    public let networkAccess: TranscriptionWorkerNetworkAccess
    public let limits: ConfinedTranscriptionWorkerLimits

    public init(
        execution: TranscriptionExecutionReference,
        profile: QualifiedTranscriptionProfile,
        runtime: any ConfinedTranscriptionRuntimeExecutionCapability,
        networkAccess: TranscriptionWorkerNetworkAccess,
        limits: ConfinedTranscriptionWorkerLimits
    ) {
        self.execution = execution
        self.profile = profile
        self.runtime = runtime
        self.networkAccess = networkAccess
        self.limits = limits
    }
}

/// Private inputs granted only after the adapter accepts the exact startup
/// hello. A worker that fails qualification never receives either authority.
public struct ConfinedTranscriptionWorkerExecution: Sendable {
    public let execution: TranscriptionExecutionReference
    public let requestJSON: Data
    public let canonicalAudio: ConfinedCanonicalAudioInput
    public let model: any ConfinedTranscriptionModelExecutionCapability

    public init(
        execution: TranscriptionExecutionReference,
        requestJSON: Data,
        canonicalAudio: ConfinedCanonicalAudioInput,
        model: any ConfinedTranscriptionModelExecutionCapability
    ) {
        self.execution = execution
        self.requestJSON = requestJSON
        self.canonicalAudio = canonicalAudio
        self.model = model
    }
}

/// A regular, descriptor-confined artifact already read by the execution host.
/// The relative path remains attached so the JSONL reference can be matched
/// exactly without admitting an arbitrary worker-supplied path.
public struct ConfinedTranscriptionWorkerArtifact: Equatable, Sendable {
    public let relativePath: String
    public let data: Data

    public init(relativePath: String, data: Data) {
        self.relativePath = relativePath
        self.data = data
    }
}

public struct ConfinedTranscriptionWorkerResult: Equatable, Sendable {
    /// Exact bounded audit copy of the lines already delivered live through
    /// `execute`. The adapter rejects a missing, reordered, or changed copy.
    public let stdoutLines: [Data]
    public let candidateArtifact: ConfinedTranscriptionWorkerArtifact?
    public let exitStatus: Int32

    public init(
        stdoutLines: [Data],
        candidateArtifact: ConfinedTranscriptionWorkerArtifact?,
        exitStatus: Int32
    ) {
        self.stdoutLines = stdoutLines
        self.candidateArtifact = candidateArtifact
        self.exitStatus = exitStatus
    }
}

public struct ConfinedTranscriptionCandidateRecoveryRequest: Equatable, Sendable {
    public let execution: TranscriptionExecutionReference
    public let expectedArtifactSHA256: String
    public let maximumArtifactBytes: UInt64

    public init(
        execution: TranscriptionExecutionReference,
        expectedArtifactSHA256: String,
        maximumArtifactBytes: UInt64
    ) {
        self.execution = execution
        self.expectedArtifactSHA256 = expectedArtifactSHA256
        self.maximumArtifactBytes = maximumArtifactBytes
    }
}

public enum ConfinedStagedCandidateResolution: Equatable, Sendable {
    case available(ConfinedTranscriptionWorkerArtifact)
    case unavailable
    case integrityMismatch
}

public protocol ConfinedTranscriptionWorkerSession: Sendable {
    func execute(
        _ execution: ConfinedTranscriptionWorkerExecution,
        receiveStandardOutputLine: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> ConfinedTranscriptionWorkerResult

    /// Requests the worker's cooperative stop first, then applies the bounded
    /// termination grace and synchronously reaps before reporting success.
    func cancelAndReap(
        graceMilliseconds: UInt32
    ) async -> TranscriptionCancellationOutcome

    /// Idempotently terminates and reaps a started worker that has not entered
    /// execution, and releases any remaining session resources after execute.
    func close() async
}

public struct ConfinedTranscriptionWorkerStarted: Sendable {
    public let helloLine: Data
    public let session: any ConfinedTranscriptionWorkerSession

    public init(
        helloLine: Data,
        session: any ConfinedTranscriptionWorkerSession
    ) {
        self.helloLine = helloLine
        self.session = session
    }
}

public protocol ConfinedTranscriptionWorkerHost: Sendable {
    func start(
        _ invocation: ConfinedTranscriptionWorkerInvocation
    ) async throws -> ConfinedTranscriptionWorkerStarted

    func cancelAndReap(
        _ execution: TranscriptionExecutionReference,
        graceMilliseconds: UInt32
    ) async -> TranscriptionCancellationOutcome

    func workerPresence(
        for execution: TranscriptionExecutionReference
    ) async -> TranscriptionWorkerPresence

    func recoverCandidate(
        _ request: ConfinedTranscriptionCandidateRecoveryRequest
    ) async -> ConfinedStagedCandidateResolution
}

public extension ConfinedTranscriptionWorkerHost {
    func cancelAndReap(
        _ execution: TranscriptionExecutionReference,
        graceMilliseconds: UInt32
    ) async -> TranscriptionCancellationOutcome { .unableToConfirm }

    func workerPresence(
        for execution: TranscriptionExecutionReference
    ) async -> TranscriptionWorkerPresence { .unknown }

    func recoverCandidate(
        _ request: ConfinedTranscriptionCandidateRecoveryRequest
    ) async -> ConfinedStagedCandidateResolution { .unavailable }
}

/// Production fail-closed host used while the reviewed Crisper qualification
/// artifact records blocked cached inference. It performs no process launch;
/// a future release must replace it together with passing confinement and
/// qualification evidence.
public struct QualificationBlockedTranscriptionWorkerHost:
    ConfinedTranscriptionWorkerHost
{
    public init() {}

    public func start(
        _ invocation: ConfinedTranscriptionWorkerInvocation
    ) async throws -> ConfinedTranscriptionWorkerStarted {
        throw TranscriptionEngineFailure.launchFailed
    }
}

/// Version-one offline JSONL adapter. It does not discover runtimes or models:
/// each request carries the exact profile already admitted by qualification.
/// The worker result stays untrusted after shape/hash verification and can only
/// become canonical through TranscriptCandidateValidator/RevisionPublisher.
public actor ConfinedJSONLTranscriptionEngine: TranscriptionEngine {
    private static let maximumLineBytes = 65_536

    private let host: any ConfinedTranscriptionWorkerHost
    private let audio: any ConfinedTranscriptionAudioResolving
    private let runtime: any ConfinedTranscriptionRuntimeResolving
    private let model: any ConfinedTranscriptionModelResolving
    private let limits: ConfinedTranscriptionWorkerLimits
    private struct ActiveExecution {
        var session: (any ConfinedTranscriptionWorkerSession)?
        var hostStartInFlight = false
        var cancellationRequested = false
        var cancellationStarted = false
        var outputBytes: UInt64 = 0
        var protocolLines: [Data] = []
        var terminal: TerminalMessage?
        var waiters: [CheckedContinuation<TranscriptionCancellationOutcome, Never>] = []
    }

    private var activeExecutions: [TranscriptionExecutionReference: ActiveExecution] = [:]
    private var completedCancellations: [
        TranscriptionExecutionReference: TranscriptionCancellationOutcome
    ] = [:]
    private var completedCancellationOrder: [TranscriptionExecutionReference] = []

    public init(
        host: any ConfinedTranscriptionWorkerHost,
        audio: any ConfinedTranscriptionAudioResolving,
        runtime: any ConfinedTranscriptionRuntimeResolving,
        model: any ConfinedTranscriptionModelResolving,
        limits: ConfinedTranscriptionWorkerLimits = .versionOne
    ) {
        self.host = host
        self.audio = audio
        self.runtime = runtime
        self.model = model
        self.limits = limits
    }

    public func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> VerifiedTranscriptionCandidate {
        guard requestMatchesProfile(request), request.sourceIDs.count == 1,
              request.execution.jobID == request.jobID,
              request.execution.cancellationAuthorityID != nil,
              limits.maximumProtocolMessages >= 2,
              limits.standardOutputBytes >= 2,
              limits.candidateArtifactBytes > 0
        else {
            throw TranscriptionEngineFailure.profileMismatch
        }
        let execution = request.execution
        guard begin(execution) else {
            throw TranscriptionEngineFailure.cancelled
        }
        guard let runtimeInput = await runtime.resolveRuntime(
            request.runtimeCapability,
            profile: request.profile
        ) else {
            if cancellationWasRequested(execution) {
                finishCancellation(execution, outcome: .alreadyAbsent)
                throw TranscriptionEngineFailure.cancelled
            }
            finishNormally(execution)
            throw TranscriptionEngineFailure.candidateUnavailable
        }
        if cancellationWasRequested(execution) {
            finishCancellation(execution, outcome: .alreadyAbsent)
            throw TranscriptionEngineFailure.cancelled
        }
        markHostStartInFlight(execution)
        let started: ConfinedTranscriptionWorkerStarted
        do {
            started = try await host.start(
                ConfinedTranscriptionWorkerInvocation(
                    execution: execution,
                    profile: request.profile,
                    runtime: runtimeInput,
                    networkAccess: .disabled,
                    limits: limits
                )
            )
        } catch let failure as TranscriptionEngineFailure {
            if cancellationWasRequested(execution) {
                _ = await cancel(execution)
                throw TranscriptionEngineFailure.cancelled
            }
            finishNormally(execution)
            throw failure
        } catch {
            if cancellationWasRequested(execution) {
                _ = await cancel(execution)
                throw TranscriptionEngineFailure.cancelled
            }
            finishNormally(execution)
            throw TranscriptionEngineFailure.launchFailed
        }
        attach(started.session, to: execution)
        if cancellationWasRequested(execution) {
            _ = await cancel(execution)
            await started.session.close()
            throw TranscriptionEngineFailure.cancelled
        }
        let helloBytes: UInt64
        do {
            helloBytes = try validateStartupHello(
                started.helloLine,
                profile: request.profile
            )
            beginProtocol(afterHelloBytes: helloBytes, for: execution)
        } catch {
            await started.session.close()
            if cancellationWasRequested(execution) {
                finishCancellation(execution, outcome: .reaped)
                throw TranscriptionEngineFailure.cancelled
            }
            finishNormally(execution)
            throw error
        }
        guard let modelInput = await model.resolveModel(
            request.modelCapability,
            profile: request.profile
        ), let canonicalAudio = await audio.resolveAudio(
            capabilityID: request.audioCapabilityID,
            selection: request.selection,
            fingerprint: request.audioFingerprint
        ) else {
            await started.session.close()
            if cancellationWasRequested(execution) {
                finishCancellation(execution, outcome: .reaped)
                throw TranscriptionEngineFailure.cancelled
            }
            finishNormally(execution)
            throw TranscriptionEngineFailure.candidateUnavailable
        }
        if cancellationWasRequested(execution) {
            let outcome = await started.session.cancelAndReap(
                graceMilliseconds: limits.terminationGraceMilliseconds
            )
            await started.session.close()
            finishCancellation(execution, outcome: outcome)
            throw TranscriptionEngineFailure.cancelled
        }
        let requestJSON: Data
        do {
            requestJSON = try makeRequestJSON(request)
        } catch {
            await started.session.close()
            if cancellationWasRequested(execution) {
                finishCancellation(execution, outcome: .reaped)
                throw TranscriptionEngineFailure.cancelled
            }
            finishNormally(execution)
            throw error
        }
        let result: ConfinedTranscriptionWorkerResult
        do {
            result = try await started.session.execute(
                ConfinedTranscriptionWorkerExecution(
                    execution: execution,
                    requestJSON: requestJSON,
                    canonicalAudio: canonicalAudio,
                    model: modelInput
                ),
                receiveStandardOutputLine: { [weak self] line in
                    guard let self else {
                        throw TranscriptionEngineFailure.cancelled
                    }
                    try await self.acceptProtocolLine(
                        line,
                        request: request,
                        execution: execution,
                        events: events
                    )
                }
            )
        } catch let failure as TranscriptionEngineFailure {
            await started.session.close()
            if cancellationWasRequested(execution) {
                finishCancellation(execution, outcome: .reaped)
                throw TranscriptionEngineFailure.cancelled
            }
            finishNormally(execution)
            throw failure
        } catch {
            await started.session.close()
            if cancellationWasRequested(execution) {
                finishCancellation(execution, outcome: .reaped)
                throw TranscriptionEngineFailure.cancelled
            }
            finishNormally(execution)
            throw TranscriptionEngineFailure.launchFailed
        }
        await started.session.close()
        markWorkerReaped(execution)
        if cancellationWasRequested(execution) {
            finishCancellation(execution, outcome: .reaped)
            throw TranscriptionEngineFailure.cancelled
        }
        do {
            let candidate = try finalize(
                result,
                execution: execution
            )
            guard !cancellationWasRequested(execution) else {
                finishCancellation(execution, outcome: .alreadyAbsent)
                throw TranscriptionEngineFailure.cancelled
            }
            finishNormally(execution)
            return candidate
        } catch {
            if cancellationWasRequested(execution) {
                finishCancellation(execution, outcome: .alreadyAbsent)
                throw TranscriptionEngineFailure.cancelled
            }
            finishNormally(execution)
            throw error
        }
    }

    public func cancel(
        _ execution: TranscriptionExecutionReference
    ) async -> TranscriptionCancellationOutcome {
        guard execution.cancellationAuthorityID != nil else {
            return .unableToConfirm
        }
        if let completed = completedCancellations[execution] { return completed }
        guard var active = activeExecutions[execution] else {
            let outcome = await host.cancelAndReap(
                execution,
                graceMilliseconds: limits.terminationGraceMilliseconds
            )
            rememberCancellation(execution, outcome: outcome)
            return outcome
        }

        if !active.cancellationRequested {
            active.cancellationRequested = true
        }
        if active.session == nil, !active.hostStartInFlight {
            activeExecutions[execution] = active
            finishCancellation(execution, outcome: .alreadyAbsent)
            return .alreadyAbsent
        }

        return await withCheckedContinuation { continuation in
            active.waiters.append(continuation)
            let session = active.session
            let shouldCancelSession = session != nil && !active.cancellationStarted
            let shouldCancelStartup = session == nil && active.hostStartInFlight &&
                !active.cancellationStarted
            if shouldCancelSession || shouldCancelStartup {
                active.cancellationStarted = true
            }
            activeExecutions[execution] = active
            if shouldCancelSession, let session {
                Task {
                    let outcome = await session.cancelAndReap(
                        graceMilliseconds: self.limits.terminationGraceMilliseconds
                    )
                    self.finishCancellation(execution, outcome: outcome)
                }
            } else if shouldCancelStartup {
                Task {
                    let outcome = await self.host.cancelAndReap(
                        execution,
                        graceMilliseconds: self.limits.terminationGraceMilliseconds
                    )
                    self.finishCancellation(execution, outcome: outcome)
                }
            }
        }
    }

    public func workerPresence(
        for execution: TranscriptionExecutionReference
    ) async -> TranscriptionWorkerPresence {
        guard execution.cancellationAuthorityID != nil else { return .unknown }
        if activeExecutions[execution] != nil { return .present }
        if let completed = completedCancellations[execution],
           completed == .reaped || completed == .alreadyAbsent
        {
            return .absent
        }
        return await host.workerPresence(for: execution)
    }

    public func recoverCandidate(
        for job: SessionProcessingJob
    ) async -> StagedTranscriptionCandidateResolution {
        guard job.state == .validating,
              let expectedHash = job.candidateArtifactSHA256,
              AudioArtifactFingerprint.isSHA256(expectedHash)
        else { return .integrityMismatch }
        let recovery = ConfinedTranscriptionCandidateRecoveryRequest(
            execution: job.executionReference,
            expectedArtifactSHA256: expectedHash,
            maximumArtifactBytes: limits.candidateArtifactBytes
        )
        switch await host.recoverCandidate(recovery) {
        case .unavailable:
            return .unavailable
        case .integrityMismatch:
            return .integrityMismatch
        case let .available(artifact):
            guard artifact.relativePath == "result.json",
                  !artifact.data.isEmpty,
                  UInt64(artifact.data.count) <= limits.candidateArtifactBytes,
                  sha256(artifact.data) == expectedHash
            else { return .integrityMismatch }
            do {
                let candidate = try decodeCandidate(
                    artifact.data,
                    artifactSHA256: expectedHash
                )
                guard candidate.jobID == job.jobID.rawValue,
                      candidate.sessionID == job.sessionID.rawValue,
                      candidate.revisionID == job.revisionID.rawValue,
                      candidate.candidateArtifactSHA256 == expectedHash,
                      let fingerprint = try? AudioFingerprint(sha256: expectedHash)
                else { return .integrityMismatch }
                return .available(
                    VerifiedTranscriptionCandidate(
                        candidate: candidate,
                        artifactFingerprint: fingerprint
                    )
                )
            } catch {
                return .integrityMismatch
            }
        }
    }
}

private extension ConfinedJSONLTranscriptionEngine {
    func begin(_ execution: TranscriptionExecutionReference) -> Bool {
        guard activeExecutions[execution] == nil,
              completedCancellations[execution] == nil
        else { return false }
        activeExecutions[execution] = ActiveExecution()
        return true
    }

    func markHostStartInFlight(_ execution: TranscriptionExecutionReference) {
        guard var active = activeExecutions[execution] else { return }
        active.hostStartInFlight = true
        activeExecutions[execution] = active
    }

    func attach(
        _ session: any ConfinedTranscriptionWorkerSession,
        to execution: TranscriptionExecutionReference
    ) {
        guard var active = activeExecutions[execution] else { return }
        active.hostStartInFlight = false
        active.session = session
        activeExecutions[execution] = active
    }

    func markWorkerReaped(_ execution: TranscriptionExecutionReference) {
        guard var active = activeExecutions[execution] else { return }
        active.session = nil
        active.hostStartInFlight = false
        activeExecutions[execution] = active
    }

    func beginProtocol(
        afterHelloBytes bytes: UInt64,
        for execution: TranscriptionExecutionReference
    ) {
        guard var active = activeExecutions[execution] else { return }
        active.outputBytes = bytes
        activeExecutions[execution] = active
    }

    func cancellationWasRequested(
        _ execution: TranscriptionExecutionReference
    ) -> Bool {
        activeExecutions[execution]?.cancellationRequested == true ||
            completedCancellations[execution] != nil
    }

    func finishNormally(_ execution: TranscriptionExecutionReference) {
        guard activeExecutions[execution]?.cancellationRequested != true else { return }
        activeExecutions.removeValue(forKey: execution)
    }

    func finishCancellation(
        _ execution: TranscriptionExecutionReference,
        outcome: TranscriptionCancellationOutcome
    ) {
        if completedCancellations[execution] != nil { return }
        let waiters = activeExecutions.removeValue(forKey: execution)?.waiters ?? []
        rememberCancellation(execution, outcome: outcome)
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    func rememberCancellation(
        _ execution: TranscriptionExecutionReference,
        outcome: TranscriptionCancellationOutcome
    ) {
        guard completedCancellations[execution] == nil else { return }
        completedCancellations[execution] = outcome
        completedCancellationOrder.append(execution)
        while completedCancellationOrder.count > 256 {
            let expired = completedCancellationOrder.removeFirst()
            completedCancellations.removeValue(forKey: expired)
        }
    }

    struct CandidateReference {
        let result: String
        let sha256: String
    }

    enum TerminalMessage {
        case candidate(CandidateReference)
        case failed
    }

    func requestMatchesProfile(_ request: TranscriptionRequest) -> Bool {
        let profile = request.profile
        return request.profileID == profile.profileID &&
            request.protocolVersion == profile.protocolVersion &&
            request.runtimeVersion == profile.runtimeVersion &&
            request.modelRevision == profile.modelRevision &&
            request.compatibilityPatchID == profile.compatibilityPatchID &&
            request.runtimeCapability.isValid(for: profile) &&
            request.modelCapability.isValid(for: profile)
    }

    func makeRequestJSON(_ request: TranscriptionRequest) throws -> Data {
        let profile = request.profile
        let sourceID = request.sourceIDs[0].rawValue
        let qualification = profile.qualification
        let value: [String: Any] = [
            "v": 1,
            "type": "transcribe",
            "jobId": request.jobID.rawValue,
            "sessionId": request.selection.sessionID.rawValue,
            "revisionId": request.revisionID.rawValue,
            "durationMs": request.durationMilliseconds,
            "qualificationProfileId": profile.profileID,
            "engine": [
                "provider": profile.engine.provider,
                "model": profile.engine.model,
                "revision": profile.engine.revision,
            ],
            "qualification": [
                "schemaVersion": TranscriptEngineQualification.schemaVersion,
                "engineLockSha256": qualification.engineLockSHA256,
                "runtimeIdentity": qualification.runtimeIdentity,
                "runtimeLockSha256": qualification.runtimeLockSHA256,
                "compatibilityPatchId": qualification.compatibilityPatchID,
            ],
            "sources": [
                [
                    "audioSourceId": sourceID,
                    "role": "microphone",
                    "path": "input/audio.wav",
                    "timelineOffsetMs": 0,
                ],
            ],
            "options": [
                "language": profile.engine.language,
                "mode": profile.engine.mode,
                "wordTimestamps": true,
            ],
            "networkAccess": TranscriptionWorkerNetworkAccess.disabled.rawValue,
        ]
        do {
            return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        } catch {
            throw TranscriptionEngineFailure.malformedProtocol
        }
    }

    func acceptProtocolLine(
        _ line: Data,
        request: TranscriptionRequest,
        execution: TranscriptionExecutionReference,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws {
        guard var active = activeExecutions[execution] else {
            throw completedCancellations[execution] == nil
                ? TranscriptionEngineFailure.malformedProtocol
                : TranscriptionEngineFailure.cancelled
        }
        guard !active.cancellationRequested else {
            throw TranscriptionEngineFailure.cancelled
        }
        let lineBytes = try protocolLineBytes(line)
        let (nextBytes, overflow) = active.outputBytes.addingReportingOverflow(lineBytes)
        let nextCount = active.protocolLines.count + 1
        guard !overflow, nextBytes <= limits.standardOutputBytes,
              nextCount < limits.maximumProtocolMessages
        else { throw TranscriptionEngineFailure.outputLimitExceeded }
        guard active.terminal == nil else {
            throw TranscriptionEngineFailure.malformedProtocol
        }

        let message = try dictionary(line)
        guard let type = message["type"] as? String else {
            throw TranscriptionEngineFailure.malformedProtocol
        }
        var event: TranscriptionEvent?
        switch type {
        case "phase":
            try exactKeys(message, ["v", "type", "jobId", "phase"])
            try validateEnvelope(message, request: request)
            guard let raw = message["phase"] as? String,
                  let phase = TranscriptionPhase(rawValue: raw)
            else { throw TranscriptionEngineFailure.malformedProtocol }
            event = .phase(phase)
        case "progress":
            let keys = Set(message.keys)
            let required: Set<String> = [
                "v", "type", "jobId", "completed", "total", "unit",
            ]
            guard required.isSubset(of: keys),
                  keys.isSubset(of: required.union(["etaSeconds"]))
            else { throw TranscriptionEngineFailure.malformedProtocol }
            try validateEnvelope(message, request: request)
            guard message["unit"] as? String == "window",
                  let completed = uint32(message["completed"]),
                  let total = uint32(message["total"]),
                  total > 0, completed <= total
            else { throw TranscriptionEngineFailure.malformedProtocol }
            let eta: UInt32?
            if let rawETA = message["etaSeconds"] {
                guard !(rawETA is NSNull), let parsed = uint32(rawETA) else {
                    throw TranscriptionEngineFailure.malformedProtocol
                }
                eta = parsed
            } else {
                eta = nil
            }
            event = .progress(completed: completed, total: total, etaSeconds: eta)
        case "candidate_ready":
            try exactKeys(
                message,
                ["v", "type", "jobId", "result", "sha256"]
            )
            try validateEnvelope(message, request: request)
            guard let relativePath = message["result"] as? String,
                  relativePath == "result.json",
                  let hash = message["sha256"] as? String,
                  AudioArtifactFingerprint.isSHA256(hash)
            else { throw TranscriptionEngineFailure.malformedProtocol }
            active.terminal = .candidate(
                CandidateReference(result: relativePath, sha256: hash)
            )
        case "failed":
            try exactKeys(message, ["v", "type", "jobId", "error"])
            try validateEnvelope(message, request: request)
            guard let error = message["error"] as? [String: Any] else {
                throw TranscriptionEngineFailure.malformedProtocol
            }
            try exactKeys(error, ["code", "retryable"])
            guard let code = error["code"] as? String,
                  (1...64).contains(code.utf8.count),
                  error["retryable"] is Bool
            else { throw TranscriptionEngineFailure.malformedProtocol }
            active.terminal = .failed
        default:
            throw TranscriptionEngineFailure.malformedProtocol
        }
        active.outputBytes = nextBytes
        active.protocolLines.append(line)
        activeExecutions[execution] = active
        if let event {
            await events(event)
            guard !cancellationWasRequested(execution) else {
                throw TranscriptionEngineFailure.cancelled
            }
        }
    }

    func finalize(
        _ result: ConfinedTranscriptionWorkerResult,
        execution: TranscriptionExecutionReference
    ) throws -> VerifiedTranscriptionCandidate {
        guard let active = activeExecutions[execution],
              !active.cancellationRequested
        else { throw TranscriptionEngineFailure.cancelled }
        guard !active.protocolLines.isEmpty,
              active.protocolLines == result.stdoutLines
        else { throw TranscriptionEngineFailure.malformedProtocol }
        guard result.exitStatus == 0 else {
            throw TranscriptionEngineFailure.workerFailed
        }
        guard let terminal = active.terminal else {
            throw TranscriptionEngineFailure.candidateUnavailable
        }
        guard case let .candidate(candidateReference) = terminal else {
            throw TranscriptionEngineFailure.workerFailed
        }
        guard let artifact = result.candidateArtifact,
              artifact.relativePath == candidateReference.result,
              !artifact.data.isEmpty,
              UInt64(artifact.data.count) <= limits.candidateArtifactBytes
        else { throw TranscriptionEngineFailure.candidateUnavailable }
        let digest = sha256(artifact.data)
        guard digest == candidateReference.sha256 else {
            throw TranscriptionEngineFailure.candidateIntegrityMismatch
        }
        let candidate = try decodeCandidate(artifact.data, artifactSHA256: digest)
        guard let fingerprint = try? AudioFingerprint(sha256: digest) else {
            throw TranscriptionEngineFailure.candidateIntegrityMismatch
        }
        return VerifiedTranscriptionCandidate(
            candidate: candidate,
            artifactFingerprint: fingerprint
        )
    }

    func validateStartupHello(
        _ line: Data,
        profile: QualifiedTranscriptionProfile
    ) throws -> UInt64 {
        let bytes = try protocolLineBytes(line)
        guard bytes <= limits.standardOutputBytes else {
            throw TranscriptionEngineFailure.outputLimitExceeded
        }
        try validateHello(dictionary(line), profile: profile)
        return bytes
    }

    func protocolLineBytes(_ line: Data) throws -> UInt64 {
        let (bytes, overflow) = UInt64(line.count).addingReportingOverflow(1)
        guard !line.isEmpty, line.count <= Self.maximumLineBytes,
              !line.contains(0x0A), !line.contains(0x0D), !overflow
        else { throw TranscriptionEngineFailure.outputLimitExceeded }
        return bytes
    }

    func validateHello(
        _ hello: [String: Any],
        profile: QualifiedTranscriptionProfile
    ) throws {
        try exactKeys(
            hello,
            [
                "v", "type", "qualificationProfileId",
                "engineLockSha256", "runtimeIdentity", "runtimeLockSha256",
                "modelRevision", "compatibilityPatchId",
            ]
        )
        let qualification = profile.qualification
        guard uint32(hello["v"]) == profile.protocolVersion,
              hello["type"] as? String == "hello",
              hello["qualificationProfileId"] as? String == profile.profileID,
              hello["engineLockSha256"] as? String == qualification.engineLockSHA256,
              hello["runtimeIdentity"] as? String == profile.runtimeVersion,
              hello["runtimeLockSha256"] as? String == profile.packageLockSHA256,
              hello["modelRevision"] as? String == profile.modelRevision,
              hello["compatibilityPatchId"] as? String ==
                profile.compatibilityPatchID
        else { throw TranscriptionEngineFailure.handshakeMismatch }
    }

    func validateEnvelope(
        _ message: [String: Any],
        request: TranscriptionRequest
    ) throws {
        let profile = request.profile
        guard uint32(message["v"]) == profile.protocolVersion,
              message["jobId"] as? String == request.jobID.rawValue
        else { throw TranscriptionEngineFailure.malformedProtocol }
    }

    func dictionary(_ data: Data) throws -> [String: Any] {
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw TranscriptionEngineFailure.malformedProtocol }
            return value
        } catch let failure as TranscriptionEngineFailure {
            throw failure
        } catch {
            throw TranscriptionEngineFailure.malformedProtocol
        }
    }

    func exactKeys(_ value: [String: Any], _ expected: Set<String>) throws {
        guard Set(value.keys) == expected else {
            throw TranscriptionEngineFailure.malformedProtocol
        }
    }

    func uint32(_ value: Any?) -> UInt32? {
        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "c"
        else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double,
              double >= 0, double <= Double(UInt32.max)
        else { return nil }
        return UInt32(double)
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension ConfinedJSONLTranscriptionEngine {
    struct CandidateArtifactDTO: Decodable {
        let schemaVersion: UInt32
        let jobId: String
        let sessionId: String
        let revisionId: String
        let durationMs: UInt64
        let audioFingerprintSha256: String
        let sourceFingerprints: [CandidateSourceDTO]
        let engine: CandidateEngineDTO
        let lines: [CandidateLineDTO]
        let audioEvents: [CandidateAudioEventDTO]
    }

    struct CandidateSourceDTO: Decodable {
        let audioSourceId: String
        let sha256: String
    }

    struct CandidateQualificationDTO: Decodable {
        let schemaVersion: UInt32
        let qualificationProfileId: String
        let engineLockSha256: String
        let runtimeIdentity: String
        let runtimeLockSha256: String
        let compatibilityPatchId: String
    }

    struct CandidateEngineDTO: Decodable {
        let provider: String
        let model: String
        let revision: String
        let language: String
        let mode: String
        let decodingOptionsSha256: String
        let qualification: CandidateQualificationDTO
    }

    struct CandidateLineDTO: Decodable {
        let lineId: String
        let order: Int
        let audioSourceId: String
        let startMs: UInt64
        let endMs: UInt64
        let text: String
        let words: [CandidateWordDTO]
    }

    struct CandidateWordDTO: Decodable {
        let wordId: String
        let ordinal: Int
        let text: String
        let startUtf8Byte: Int
        let endUtf8Byte: Int
        let startMs: UInt64?
        let endMs: UInt64?
        let confidence: Double?
        let wordKind: String
    }

    struct CandidateAudioEventDTO: Decodable {
        let audioEventId: String
        let category: String
        let audioSourceId: String
        let startMs: UInt64
        let endMs: UInt64
    }

    func decodeCandidate(
        _ data: Data,
        artifactSHA256: String
    ) throws -> TranscriptionCandidate {
        let dictionary = try dictionary(data)
        try validateCandidateShape(dictionary)
        let dto: CandidateArtifactDTO
        do {
            dto = try JSONDecoder().decode(CandidateArtifactDTO.self, from: data)
        } catch {
            throw TranscriptionEngineFailure.malformedProtocol
        }
        let lines = try dto.lines.map { line -> CandidateTranscriptLine in
            let words = try line.words.map { word -> CandidateTranscriptWord in
                let timeRange: CandidateSessionTimeRange?
                switch (word.startMs, word.endMs) {
                case let (.some(start), .some(end)):
                    timeRange = CandidateSessionTimeRange(
                        startMilliseconds: start,
                        endMilliseconds: end
                    )
                case (.none, .none):
                    timeRange = nil
                default:
                    throw TranscriptionEngineFailure.malformedProtocol
                }
                guard let kind = CandidateTranscriptWordKind(rawValue: word.wordKind)
                else { throw TranscriptionEngineFailure.malformedProtocol }
                return CandidateTranscriptWord(
                    wordID: word.wordId,
                    ordinal: word.ordinal,
                    text: word.text,
                    displayRange: CandidateLineTextRange(
                        startUTF8Byte: word.startUtf8Byte,
                        endUTF8Byte: word.endUtf8Byte
                    ),
                    timeRange: timeRange,
                    confidence: word.confidence,
                    wordKind: kind
                )
            }
            return CandidateTranscriptLine(
                lineID: line.lineId,
                order: line.order,
                audioSourceID: line.audioSourceId,
                timeRange: CandidateSessionTimeRange(
                    startMilliseconds: line.startMs,
                    endMilliseconds: line.endMs
                ),
                text: line.text,
                words: words
            )
        }
        let audioEvents = try dto.audioEvents.map { event in
            guard let category = TranscriptAudioEventCategory(rawValue: event.category)
            else { throw TranscriptionEngineFailure.malformedProtocol }
            return CandidateTranscriptAudioEvent(
                audioEventID: event.audioEventId,
                category: category,
                audioSourceID: event.audioSourceId,
                timeRange: CandidateSessionTimeRange(
                    startMilliseconds: event.startMs,
                    endMilliseconds: event.endMs
                )
            )
        }
        return TranscriptionCandidate(
            schemaVersion: dto.schemaVersion,
            jobID: dto.jobId,
            sessionID: dto.sessionId,
            revisionID: dto.revisionId,
            durationMilliseconds: dto.durationMs,
            audioFingerprintSHA256: dto.audioFingerprintSha256,
            sourceFingerprints: dto.sourceFingerprints.map {
                CandidateTranscriptSourceFingerprint(
                    audioSourceID: $0.audioSourceId,
                    sha256: $0.sha256
                )
            },
            candidateArtifactSHA256: artifactSHA256,
            engine: CandidateTranscriptEngineProvenance(
                provider: dto.engine.provider,
                model: dto.engine.model,
                revision: dto.engine.revision,
                language: dto.engine.language,
                mode: dto.engine.mode,
                decodingOptionsSHA256: dto.engine.decodingOptionsSha256,
                qualification: CandidateTranscriptEngineQualification(
                    schemaVersion: dto.engine.qualification.schemaVersion,
                    qualificationProfileID:
                        dto.engine.qualification.qualificationProfileId,
                    engineLockSHA256: dto.engine.qualification.engineLockSha256,
                    runtimeIdentity: dto.engine.qualification.runtimeIdentity,
                    runtimeLockSHA256: dto.engine.qualification.runtimeLockSha256,
                    compatibilityPatchID:
                        dto.engine.qualification.compatibilityPatchId
                )
            ),
            lines: lines,
            audioEvents: audioEvents
        )
    }

    func validateCandidateShape(_ root: [String: Any]) throws {
        try exactKeys(
            root,
            [
                "schemaVersion", "jobId", "sessionId", "revisionId", "durationMs",
                "audioFingerprintSha256", "sourceFingerprints", "engine", "lines",
                "audioEvents",
            ]
        )
        guard let sources = root["sourceFingerprints"] as? [[String: Any]],
              (1...32).contains(sources.count),
              let engine = root["engine"] as? [String: Any],
              let lines = root["lines"] as? [[String: Any]],
              (1...100_000).contains(lines.count),
              let audioEvents = root["audioEvents"] as? [[String: Any]],
              audioEvents.count <= 100_000
        else { throw TranscriptionEngineFailure.malformedProtocol }
        for source in sources {
            try exactKeys(source, ["audioSourceId", "sha256"])
        }
        try exactKeys(
            engine,
            [
                "provider", "model", "revision", "language", "mode",
                "decodingOptionsSha256", "qualification",
            ]
        )
        guard let qualification = engine["qualification"] as? [String: Any] else {
            throw TranscriptionEngineFailure.malformedProtocol
        }
        try exactKeys(
            qualification,
            [
                "schemaVersion", "qualificationProfileId", "engineLockSha256",
                "runtimeIdentity", "runtimeLockSha256", "compatibilityPatchId",
            ]
        )
        var wordCount = 0
        var textBytes = 0
        for line in lines {
            try exactKeys(
                line,
                [
                    "lineId", "order", "audioSourceId", "startMs", "endMs",
                    "text", "words",
                ]
            )
            guard let text = line["text"] as? String,
                  let words = line["words"] as? [[String: Any]],
                  textBytes <= TranscriptRevisionLimits.maximumAggregateTextUTF8Bytes -
                    text.utf8.count,
                  wordCount <= 1_000_000 - words.count
            else { throw TranscriptionEngineFailure.outputLimitExceeded }
            textBytes += text.utf8.count
            wordCount += words.count
            for word in words {
                try exactKeys(
                    word,
                    [
                        "wordId", "ordinal", "text", "startUtf8Byte", "endUtf8Byte",
                        "startMs", "endMs", "confidence", "wordKind",
                    ]
                )
            }
        }
        for event in audioEvents {
            try exactKeys(
                event,
                [
                    "audioEventId", "category", "audioSourceId", "startMs", "endMs",
                ]
            )
        }
    }
}
