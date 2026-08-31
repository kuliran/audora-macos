import AudoraApplication
import AudoraDomain
@testable import AudoraMacInfrastructure
import CryptoKit
import Darwin
import Foundation
import XCTest

final class ConfinedJSONLTranscriptionEngineTests: XCTestCase {
    func testExactHandshakeAndSingleHashVerifiedCandidateAreReturnedOffline() async throws {
        let fixture = try WorkerFixture()
        let artifact = try fixture.candidateArtifact()
        let hash = sha256(artifact)
        let host = WorkerHostProbe(
            helloLine: try fixture.hello(),
            result: .success(
                ConfinedTranscriptionWorkerResult(
                    stdoutLines: [
                        try line([
                            "v": 1, "type": "phase",
                            "jobId": fixture.request.jobID.rawValue,
                            "phase": "loading_model",
                        ]),
                        try line([
                            "v": 1, "type": "progress",
                            "jobId": fixture.request.jobID.rawValue,
                            "completed": 1, "total": 1, "unit": "window",
                            "etaSeconds": 0,
                        ]),
                        try fixture.candidateReady(hash: hash),
                    ],
                    candidateArtifact: ConfinedTranscriptionWorkerArtifact(
                        relativePath: "result.json",
                        data: artifact
                    ),
                    exitStatus: 0
                )
            )
        )
        let events = WorkerEventProbe()
        let engine = ConfinedJSONLTranscriptionEngine(
            host: host,
            audio: try WorkerAudioProbe(fixture: fixture),
            runtime: WorkerRuntimeProbe(fixture: fixture),
            model: WorkerModelProbe(fixture: fixture)
        )

        let verified = try await engine.transcribe(fixture.request) { event in
            await events.append(event)
        }

        XCTAssertEqual(verified.artifactFingerprint.sha256, hash)
        XCTAssertEqual(verified.candidate.jobID, fixture.request.jobID.rawValue)
        XCTAssertEqual(
            verified.candidate.engine.qualification.qualificationProfileID,
            fixture.profile.profileID
        )
        let capturedEvents = await events.values
        XCTAssertEqual(
            capturedEvents,
            [
                .phase(.loadingModel),
                .progress(completed: 1, total: 1, etaSeconds: 0),
            ]
        )
        let invocations = await host.invocations
        let invocation = try XCTUnwrap(invocations.first)
        XCTAssertEqual(invocation.networkAccess, .disabled)
        XCTAssertEqual(invocation.profile, fixture.profile)
        XCTAssertEqual(
            invocation.runtime.capabilityID,
            fixture.request.runtimeCapability.capabilityID
        )
        let executions = await host.executions
        let execution = try XCTUnwrap(executions.first)
        XCTAssertEqual(
            execution.canonicalAudio.capabilityID,
            fixture.request.audioCapabilityID
        )
        XCTAssertEqual(
            execution.model.capabilityID,
            fixture.request.modelCapability.capabilityID
        )
        let audioDescriptor = try execution.canonicalAudio
            .duplicateReadOnlyFileDescriptor()
        defer { Darwin.close(audioDescriptor) }
        XCTAssertEqual(fcntl(audioDescriptor, F_GETFL) & O_ACCMODE, O_RDONLY)
        XCTAssertEqual(try readToEnd(audioDescriptor), fixture.canonicalAudio)
        XCTAssertLessThanOrEqual(
            invocation.limits.candidateArtifactBytes,
            UInt64(TranscriptRevisionLimits.maximumSerializedBytes)
        )
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: execution.requestJSON) as? [String: Any]
        )
        XCTAssertEqual(request["jobId"] as? String, fixture.request.jobID.rawValue)
        XCTAssertEqual(request["qualificationProfileId"] as? String, fixture.profile.profileID)
        let closeCount = await host.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    func testPhaseIsValidatedAndDeliveredBeforeWorkerExecutionCompletes() async throws {
        let fixture = try WorkerFixture()
        let artifact = try fixture.candidateArtifact()
        let hash = sha256(artifact)
        let phase = try line([
            "v": 1, "type": "phase",
            "jobId": fixture.request.jobID.rawValue,
            "phase": "loading_model",
        ])
        let terminal = try fixture.candidateReady(hash: hash)
        let host = LiveStreamingWorkerHostProbe(
            helloLine: try fixture.hello(),
            phaseLine: phase,
            terminalLine: terminal,
            artifact: ConfinedTranscriptionWorkerArtifact(
                relativePath: "result.json",
                data: artifact
            )
        )
        let events = WorkerEventProbe()
        let engine = ConfinedJSONLTranscriptionEngine(
            host: host,
            audio: try WorkerAudioProbe(fixture: fixture),
            runtime: WorkerRuntimeProbe(fixture: fixture),
            model: WorkerModelProbe(fixture: fixture)
        )
        let run = Task {
            try await engine.transcribe(fixture.request) { event in
                await events.append(event)
            }
        }

        await host.waitUntilPhaseWasDelivered()
        let liveEvents = await events.values
        let executionReturned = await host.executionReturned()
        XCTAssertEqual(liveEvents, [.phase(.loadingModel)])
        XCTAssertFalse(executionReturned)

        await host.releaseExecution()
        let verified = try await run.value
        XCTAssertEqual(verified.artifactFingerprint.sha256, hash)
    }

    func testHandshakeRuntimeSubstitutionFailsBeforePrivateCapabilitiesAreGranted()
        async throws
    {
        let fixture = try WorkerFixture()
        let artifact = try fixture.candidateArtifact()
        var hello = fixture.helloDictionary()
        hello["runtimeIdentity"] = "substituted-runtime"
        let host = WorkerHostProbe(
            helloLine: try line(hello),
            result: .success(
                ConfinedTranscriptionWorkerResult(
                    stdoutLines: [
                        try fixture.candidateReady(hash: sha256(artifact)),
                    ],
                    candidateArtifact: ConfinedTranscriptionWorkerArtifact(
                        relativePath: "result.json",
                        data: artifact
                    ),
                    exitStatus: 0
                )
            )
        )
        let audio = try WorkerAudioProbe(fixture: fixture)
        let engine = ConfinedJSONLTranscriptionEngine(
            host: host,
            audio: audio,
            runtime: WorkerRuntimeProbe(fixture: fixture),
            model: WorkerModelProbe(fixture: fixture)
        )

        await XCTAssertThrowsErrorAsync(
            try await engine.transcribe(fixture.request) { _ in }
        ) { error in
            XCTAssertEqual(error as? TranscriptionEngineFailure, .handshakeMismatch)
        }
        let executionCount = await host.executions.count
        let audioResolutionCount = await audio.resolveCount
        let closeCount = await host.closeCount
        XCTAssertEqual(executionCount, 0)
        XCTAssertEqual(audioResolutionCount, 0)
        XCTAssertEqual(closeCount, 1)
    }

    func testSecondTerminalMessageIsRejected() async throws {
        let fixture = try WorkerFixture()
        let artifact = try fixture.candidateArtifact()
        let terminal = try fixture.candidateReady(hash: sha256(artifact))
        let host = WorkerHostProbe(
            helloLine: try fixture.hello(),
            result: .success(
                ConfinedTranscriptionWorkerResult(
                    stdoutLines: [terminal, terminal],
                    candidateArtifact: ConfinedTranscriptionWorkerArtifact(
                        relativePath: "result.json",
                        data: artifact
                    ),
                    exitStatus: 0
                )
            )
        )
        let engine = ConfinedJSONLTranscriptionEngine(
            host: host,
            audio: try WorkerAudioProbe(fixture: fixture),
            runtime: WorkerRuntimeProbe(fixture: fixture),
            model: WorkerModelProbe(fixture: fixture)
        )

        await XCTAssertThrowsErrorAsync(
            try await engine.transcribe(fixture.request) { _ in }
        ) { error in
            XCTAssertEqual(error as? TranscriptionEngineFailure, .malformedProtocol)
        }
    }

    func testCandidateArtifactHashMismatchIsRejected() async throws {
        let fixture = try WorkerFixture()
        let artifact = try fixture.candidateArtifact()
        let host = WorkerHostProbe(
            helloLine: try fixture.hello(),
            result: .success(
                ConfinedTranscriptionWorkerResult(
                    stdoutLines: [
                        try fixture.candidateReady(hash: String(repeating: "f", count: 64)),
                    ],
                    candidateArtifact: ConfinedTranscriptionWorkerArtifact(
                        relativePath: "result.json",
                        data: artifact
                    ),
                    exitStatus: 0
                )
            )
        )
        let engine = ConfinedJSONLTranscriptionEngine(
            host: host,
            audio: try WorkerAudioProbe(fixture: fixture),
            runtime: WorkerRuntimeProbe(fixture: fixture),
            model: WorkerModelProbe(fixture: fixture)
        )

        await XCTAssertThrowsErrorAsync(
            try await engine.transcribe(fixture.request) { _ in }
        ) { error in
            XCTAssertEqual(
                error as? TranscriptionEngineFailure,
                .candidateIntegrityMismatch
            )
        }
    }

    func testCancelCooperatesThenReapsOnceAndRejectsLateCandidate() async throws {
        let fixture = try WorkerFixture()
        let artifact = try fixture.candidateArtifact()
        let host = SuspendingWorkerHostProbe(
            helloLine: try fixture.hello(),
            lateResult: ConfinedTranscriptionWorkerResult(
                stdoutLines: [
                    try fixture.candidateReady(hash: sha256(artifact)),
                ],
                candidateArtifact: ConfinedTranscriptionWorkerArtifact(
                    relativePath: "result.json",
                    data: artifact
                ),
                exitStatus: 0
            )
        )
        let engine = ConfinedJSONLTranscriptionEngine(
            host: host,
            audio: try WorkerAudioProbe(fixture: fixture),
            runtime: WorkerRuntimeProbe(fixture: fixture),
            model: WorkerModelProbe(fixture: fixture)
        )
        let run = Task {
            do {
                _ = try await engine.transcribe(fixture.request) { _ in }
                return nil as TranscriptionEngineFailure?
            } catch {
                return error as? TranscriptionEngineFailure
            }
        }
        await host.waitUntilExecutionStarts()

        async let first = engine.cancel(fixture.request.execution)
        async let duplicate = engine.cancel(fixture.request.execution)
        let outcomes = await [first, duplicate]
        let failure = await run.value
        let cancelCount = await host.cancelCountValue()
        let closeCount = await host.closeCountValue()
        let graceValues = await host.graceValues()

        XCTAssertEqual(outcomes, [.reaped, .reaped])
        XCTAssertEqual(failure, .cancelled)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(
            graceValues,
            [ConfinedTranscriptionWorkerLimits.versionOne.terminationGraceMilliseconds]
        )
    }

    func testCancelReapsAuthorityWhileStartupIsSuspendedAndRejectsLateHello()
        async throws
    {
        let fixture = try WorkerFixture()
        let host = SuspendedStartupWorkerHostProbe(
            helloLine: try fixture.hello()
        )
        let engine = ConfinedJSONLTranscriptionEngine(
            host: host,
            audio: try WorkerAudioProbe(fixture: fixture),
            runtime: WorkerRuntimeProbe(fixture: fixture),
            model: WorkerModelProbe(fixture: fixture)
        )
        let run = Task {
            do {
                _ = try await engine.transcribe(fixture.request) { _ in }
                return nil as TranscriptionEngineFailure?
            } catch {
                return error as? TranscriptionEngineFailure
            }
        }
        await host.waitUntilStartupSuspends()

        let cancellation = Task {
            await engine.cancel(fixture.request.execution)
        }
        var reapedBeforeHello = false
        for _ in 0..<1_000 {
            if await host.startupCancellationCount() == 1 {
                reapedBeforeHello = true
                break
            }
            await Task.yield()
        }
        await host.releaseLateHello()

        let cancellationOutcome = await cancellation.value
        let runFailure = await run.value
        let cancelledExecutions = await host.cancelledExecutionReferences()
        let startupExecution = await host.startupExecutionReference()
        let executionCount = await host.executionCount()
        let closeCount = await host.closeCountValue()
        XCTAssertTrue(reapedBeforeHello)
        XCTAssertEqual(cancellationOutcome, .reaped)
        XCTAssertEqual(runFailure, .cancelled)
        XCTAssertEqual(cancelledExecutions, [fixture.request.execution])
        XCTAssertEqual(startupExecution, fixture.request.execution)
        XCTAssertEqual(executionCount, 0)
        XCTAssertEqual(closeCount, 1)
    }

    func testCancelWhileLiveEventIsObservedStillRejectsLaterCandidate() async throws {
        let fixture = try WorkerFixture()
        let artifact = try fixture.candidateArtifact()
        let host = WorkerHostProbe(
            helloLine: try fixture.hello(),
            result: .success(
                ConfinedTranscriptionWorkerResult(
                    stdoutLines: [
                        try line([
                            "v": 1, "type": "phase",
                            "jobId": fixture.request.jobID.rawValue,
                            "phase": "transcribing",
                        ]),
                        try fixture.candidateReady(hash: sha256(artifact)),
                    ],
                    candidateArtifact: ConfinedTranscriptionWorkerArtifact(
                        relativePath: "result.json",
                        data: artifact
                    ),
                    exitStatus: 0
                )
            )
        )
        let events = SuspendedWorkerEventProbe()
        let engine = ConfinedJSONLTranscriptionEngine(
            host: host,
            audio: try WorkerAudioProbe(fixture: fixture),
            runtime: WorkerRuntimeProbe(fixture: fixture),
            model: WorkerModelProbe(fixture: fixture)
        )
        let run = Task {
            do {
                _ = try await engine.transcribe(fixture.request) { event in
                    await events.receive(event)
                }
                return nil as TranscriptionEngineFailure?
            } catch {
                return error as? TranscriptionEngineFailure
            }
        }
        await events.waitUntilReceived()

        let outcome = await engine.cancel(fixture.request.execution)
        await events.release()
        let failure = await run.value
        let closeCount = await host.closeCount

        XCTAssertEqual(outcome, .reaped)
        XCTAssertEqual(failure, .cancelled)
        XCTAssertEqual(closeCount, 1)
    }

    func testRelaunchRecoveryRejectsEscapingAndCorruptCandidateArtifacts()
        async throws
    {
        let fixture = try WorkerFixture()
        let artifact = try fixture.candidateArtifact()
        let hash = sha256(artifact)
        let escaping = RecoveryWorkerHostProbe(
            resolution: .available(
                ConfinedTranscriptionWorkerArtifact(
                    relativePath: "../result.json",
                    data: artifact
                )
            )
        )
        let escapingEngine = ConfinedJSONLTranscriptionEngine(
            host: escaping,
            audio: try WorkerAudioProbe(fixture: fixture),
            runtime: WorkerRuntimeProbe(fixture: fixture),
            model: WorkerModelProbe(fixture: fixture)
        )

        let escapingResult = await escapingEngine.recoverCandidate(
            for: fixture.validatingJob(candidateArtifactSHA256: hash)
        )
        XCTAssertEqual(escapingResult, .integrityMismatch)

        var corrupt = artifact
        corrupt[corrupt.startIndex] ^= 0x01
        let corruptHost = RecoveryWorkerHostProbe(
            resolution: .available(
                ConfinedTranscriptionWorkerArtifact(
                    relativePath: "result.json",
                    data: corrupt
                )
            )
        )
        let corruptEngine = ConfinedJSONLTranscriptionEngine(
            host: corruptHost,
            audio: try WorkerAudioProbe(fixture: fixture),
            runtime: WorkerRuntimeProbe(fixture: fixture),
            model: WorkerModelProbe(fixture: fixture)
        )
        let corruptResult = await corruptEngine.recoverCandidate(
            for: fixture.validatingJob(candidateArtifactSHA256: hash)
        )
        XCTAssertEqual(corruptResult, .integrityMismatch)
    }
}

private func readToEnd(_ descriptor: Int32) throws -> Data {
    guard lseek(descriptor, 0, SEEK_SET) == 0 else {
        throw TranscriptionEngineFailure.candidateUnavailable
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 32_768)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 { return result }
        if count < 0 {
            if errno == EINTR { continue }
            throw TranscriptionEngineFailure.candidateUnavailable
        }
        result.append(contentsOf: buffer[0..<count])
    }
}

private actor WorkerHostProbe:
    ConfinedTranscriptionWorkerHost,
    ConfinedTranscriptionWorkerSession
{
    private let helloLine: Data
    private let result: Result<ConfinedTranscriptionWorkerResult, TranscriptionEngineFailure>
    private(set) var invocations: [ConfinedTranscriptionWorkerInvocation] = []
    private(set) var executions: [ConfinedTranscriptionWorkerExecution] = []
    private(set) var closeCount = 0
    private var closed = false

    init(
        helloLine: Data,
        result: Result<ConfinedTranscriptionWorkerResult, TranscriptionEngineFailure>
    ) {
        self.helloLine = helloLine
        self.result = result
    }

    func start(
        _ invocation: ConfinedTranscriptionWorkerInvocation
    ) async throws -> ConfinedTranscriptionWorkerStarted {
        invocations.append(invocation)
        return ConfinedTranscriptionWorkerStarted(
            helloLine: helloLine,
            session: self
        )
    }

    func execute(
        _ execution: ConfinedTranscriptionWorkerExecution,
        receiveStandardOutputLine: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> ConfinedTranscriptionWorkerResult {
        executions.append(execution)
        let value = try result.get()
        for line in value.stdoutLines {
            try await receiveStandardOutputLine(line)
        }
        return value
    }

    func close() async {
        guard !closed else { return }
        closed = true
        closeCount += 1
    }

    func cancelAndReap(
        graceMilliseconds: UInt32
    ) async -> TranscriptionCancellationOutcome {
        await close()
        return .reaped
    }
}

private actor SuspendingWorkerHostProbe:
    ConfinedTranscriptionWorkerHost,
    ConfinedTranscriptionWorkerSession
{
    private let helloLine: Data
    private let lateResult: ConfinedTranscriptionWorkerResult
    private var executionContinuation: CheckedContinuation<Void, Never>?
    private var executionStarted = false
    private var cancelCount = 0
    private var closeCount = 0
    private var terminationGraces: [UInt32] = []

    init(helloLine: Data, lateResult: ConfinedTranscriptionWorkerResult) {
        self.helloLine = helloLine
        self.lateResult = lateResult
    }

    func start(
        _ invocation: ConfinedTranscriptionWorkerInvocation
    ) async throws -> ConfinedTranscriptionWorkerStarted {
        ConfinedTranscriptionWorkerStarted(helloLine: helloLine, session: self)
    }

    func execute(
        _ execution: ConfinedTranscriptionWorkerExecution,
        receiveStandardOutputLine: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> ConfinedTranscriptionWorkerResult {
        executionStarted = true
        await withCheckedContinuation { continuation in
            executionContinuation = continuation
        }
        for line in lateResult.stdoutLines {
            try await receiveStandardOutputLine(line)
        }
        return lateResult
    }

    func cancelAndReap(
        graceMilliseconds: UInt32
    ) async -> TranscriptionCancellationOutcome {
        cancelCount += 1
        terminationGraces.append(graceMilliseconds)
        executionContinuation?.resume()
        executionContinuation = nil
        return .reaped
    }

    func close() async {
        closeCount += 1
        executionContinuation?.resume()
        executionContinuation = nil
    }

    func waitUntilExecutionStarts() async {
        while !executionStarted { await Task.yield() }
    }

    func cancelCountValue() -> Int { cancelCount }
    func closeCountValue() -> Int { closeCount }
    func graceValues() -> [UInt32] { terminationGraces }
}

private actor SuspendedStartupWorkerHostProbe:
    ConfinedTranscriptionWorkerHost,
    ConfinedTranscriptionWorkerSession
{
    private let helloLine: Data
    private var startupContinuation: CheckedContinuation<Void, Never>?
    private var startupSuspended = false
    private var startupExecution: TranscriptionExecutionReference?
    private var cancelledExecutions: [TranscriptionExecutionReference] = []
    private var executions = 0
    private var closeCount = 0

    init(helloLine: Data) {
        self.helloLine = helloLine
    }

    func start(
        _ invocation: ConfinedTranscriptionWorkerInvocation
    ) async throws -> ConfinedTranscriptionWorkerStarted {
        startupExecution = invocation.execution
        startupSuspended = true
        await withCheckedContinuation { continuation in
            startupContinuation = continuation
        }
        return ConfinedTranscriptionWorkerStarted(
            helloLine: helloLine,
            session: self
        )
    }

    func cancelAndReap(
        _ execution: TranscriptionExecutionReference,
        graceMilliseconds: UInt32
    ) async -> TranscriptionCancellationOutcome {
        cancelledExecutions.append(execution)
        return .reaped
    }

    func execute(
        _ execution: ConfinedTranscriptionWorkerExecution,
        receiveStandardOutputLine: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> ConfinedTranscriptionWorkerResult {
        executions += 1
        throw TranscriptionEngineFailure.cancelled
    }

    func cancelAndReap(
        graceMilliseconds: UInt32
    ) async -> TranscriptionCancellationOutcome { .reaped }

    func close() async { closeCount += 1 }

    func waitUntilStartupSuspends() async {
        while !startupSuspended { await Task.yield() }
    }

    func releaseLateHello() {
        startupContinuation?.resume()
        startupContinuation = nil
    }

    func startupCancellationCount() -> Int { cancelledExecutions.count }
    func cancelledExecutionReferences() -> [TranscriptionExecutionReference] {
        cancelledExecutions
    }
    func startupExecutionReference() -> TranscriptionExecutionReference? {
        startupExecution
    }
    func executionCount() -> Int { executions }
    func closeCountValue() -> Int { closeCount }
}

private actor LiveStreamingWorkerHostProbe:
    ConfinedTranscriptionWorkerHost,
    ConfinedTranscriptionWorkerSession
{
    private let helloLine: Data
    private let phaseLine: Data
    private let terminalLine: Data
    private let artifact: ConfinedTranscriptionWorkerArtifact
    private var phaseWasDelivered = false
    private var didReturn = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(
        helloLine: Data,
        phaseLine: Data,
        terminalLine: Data,
        artifact: ConfinedTranscriptionWorkerArtifact
    ) {
        self.helloLine = helloLine
        self.phaseLine = phaseLine
        self.terminalLine = terminalLine
        self.artifact = artifact
    }

    func start(
        _ invocation: ConfinedTranscriptionWorkerInvocation
    ) async throws -> ConfinedTranscriptionWorkerStarted {
        ConfinedTranscriptionWorkerStarted(helloLine: helloLine, session: self)
    }

    func execute(
        _ execution: ConfinedTranscriptionWorkerExecution,
        receiveStandardOutputLine: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> ConfinedTranscriptionWorkerResult {
        try await receiveStandardOutputLine(phaseLine)
        phaseWasDelivered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        try await receiveStandardOutputLine(terminalLine)
        didReturn = true
        return ConfinedTranscriptionWorkerResult(
            stdoutLines: [phaseLine, terminalLine],
            candidateArtifact: artifact,
            exitStatus: 0
        )
    }

    func cancelAndReap(
        graceMilliseconds: UInt32
    ) async -> TranscriptionCancellationOutcome {
        continuation?.resume()
        continuation = nil
        return .reaped
    }

    func close() async {
        continuation?.resume()
        continuation = nil
    }

    func waitUntilPhaseWasDelivered() async {
        while !phaseWasDelivered { await Task.yield() }
    }

    func releaseExecution() {
        continuation?.resume()
        continuation = nil
    }

    func executionReturned() -> Bool { didReturn }
}

private actor RecoveryWorkerHostProbe: ConfinedTranscriptionWorkerHost {
    private let resolution: ConfinedStagedCandidateResolution

    init(resolution: ConfinedStagedCandidateResolution) {
        self.resolution = resolution
    }

    func start(
        _ invocation: ConfinedTranscriptionWorkerInvocation
    ) async throws -> ConfinedTranscriptionWorkerStarted {
        throw TranscriptionEngineFailure.launchFailed
    }

    func recoverCandidate(
        _ request: ConfinedTranscriptionCandidateRecoveryRequest
    ) async -> ConfinedStagedCandidateResolution {
        resolution
    }
}

private actor WorkerEventProbe {
    private(set) var values: [TranscriptionEvent] = []

    func append(_ event: TranscriptionEvent) { values.append(event) }
}

private actor SuspendedWorkerEventProbe {
    private var hasReceived = false
    private var continuation: CheckedContinuation<Void, Never>?

    func receive(_ event: TranscriptionEvent) async {
        hasReceived = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilReceived() async {
        while !hasReceived { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor WorkerAudioProbe: ConfinedTranscriptionAudioResolving {
    private let input: ConfinedCanonicalAudioInput
    private let selection: SessionProcessingSelection
    private(set) var resolveCount = 0

    init(fixture: WorkerFixture) throws {
        input = try ConfinedCanonicalAudioInput(
            copyingVerifiedCanonicalWAV: fixture.canonicalAudio,
            capabilityID: fixture.request.audioCapabilityID,
            fingerprint: fixture.request.audioFingerprint
        )
        selection = fixture.request.selection
    }

    func resolveAudio(
        capabilityID: SessionTranscriptionAudioCapabilityID,
        selection: SessionProcessingSelection,
        fingerprint: AudioFingerprint
    ) async -> ConfinedCanonicalAudioInput? {
        resolveCount += 1
        guard capabilityID == input.capabilityID,
              selection == self.selection,
              fingerprint == input.fingerprint
        else { return nil }
        return input
    }
}

private struct WorkerRuntimeInput:
    ConfinedTranscriptionRuntimeExecutionCapability
{
    let capabilityID: TranscriptionRuntimeCapabilityID
    let profileID: String
    let runtimeIdentity: String

    func duplicateReadOnlyFileDescriptors() throws -> [String: Int32] { [:] }
}

private actor WorkerRuntimeProbe: ConfinedTranscriptionRuntimeResolving {
    private let input: WorkerRuntimeInput

    init(fixture: WorkerFixture) {
        input = WorkerRuntimeInput(
            capabilityID: fixture.request.runtimeCapability.capabilityID,
            profileID: fixture.profile.profileID,
            runtimeIdentity: fixture.profile.runtimeVersion
        )
    }

    func resolveRuntime(
        _ capability: VerifiedTranscriptionRuntime,
        profile: QualifiedTranscriptionProfile
    ) async -> (any ConfinedTranscriptionRuntimeExecutionCapability)? {
        guard capability == VerifiedTranscriptionRuntime(
            capabilityID: input.capabilityID,
            profileID: input.profileID,
            runtimeIdentity: input.runtimeIdentity
        ), capability.isValid(for: profile) else { return nil }
        return input
    }
}

private struct WorkerModelInput: ConfinedTranscriptionModelExecutionCapability {
    let capabilityID: TranscriptionModelCapabilityID
    let profileID: String
    let modelRevision: String

    func duplicateReadOnlyFileDescriptors() throws -> [String: Int32] { [:] }
}

private actor WorkerModelProbe: ConfinedTranscriptionModelResolving {
    private let input: WorkerModelInput

    init(fixture: WorkerFixture) {
        input = WorkerModelInput(
            capabilityID: fixture.request.modelCapability.capabilityID,
            profileID: fixture.profile.profileID,
            modelRevision: fixture.profile.modelRevision
        )
    }

    func resolveModel(
        _ capability: VerifiedTranscriptionModel,
        profile: QualifiedTranscriptionProfile
    ) async -> (any ConfinedTranscriptionModelExecutionCapability)? {
        guard capability == VerifiedTranscriptionModel(
            capabilityID: input.capabilityID,
            profileID: input.profileID,
            modelRevision: input.modelRevision
        ), capability.isValid(for: profile) else { return nil }
        return input
    }
}

private struct WorkerFixture {
    let profile: QualifiedTranscriptionProfile
    let request: TranscriptionRequest
    let canonicalAudio: Data
    private let sourceFingerprint: String

    init() throws {
        canonicalAudio = syntheticCanonicalWAV(frameCount: 32_000)
        sourceFingerprint = sha256(canonicalAudio)
        let qualification = try TranscriptEngineQualification(
            qualificationProfileID: "synthetic-qualified-v1",
            engineLockSHA256: String(repeating: "6", count: 64),
            runtimeIdentity: "synthetic-runtime-v1",
            runtimeLockSHA256: String(repeating: "4", count: 64),
            compatibilityPatchID: "synthetic-progress-patch-v1"
        )
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
        let engine = try TranscriptEngineProvenance(
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
            profileID: qualification.qualificationProfileID,
            protocolVersion: 1,
            runtimeVersion: qualification.runtimeIdentity,
            packageLockSHA256: qualification.runtimeLockSHA256,
            modelRevision: engine.revision,
            compatibilityPatchID: qualification.compatibilityPatchID,
            engine: engine
        )
        let libraryID = try LibraryID("lib-20260830T120000000Z-1ABC")
        let sessionID = try SessionID("ses-20260830T120100000Z-2CDE")
        let sourceID = try AudioSourceID("src-0001")
        let fingerprint = try AudioFingerprint(sha256: sourceFingerprint)
        let source = SessionTranscriptionSource(
            selection: SessionProcessingSelection(
                scope: LibraryScope(libraryID: libraryID),
                sessionID: sessionID
            ),
            audioCapabilityID: try SessionTranscriptionAudioCapabilityID(
                "cap-jsonl-fixture"
            ),
            durationMilliseconds: 2_000,
            audioFingerprint: fingerprint,
            sourceFingerprints: [
                TranscriptSourceFingerprint(
                    audioSourceID: sourceID,
                    fingerprint: fingerprint
                ),
            ],
            expectedSelectedRevisionID: nil
        )
        let runtimeCapability = VerifiedTranscriptionRuntime(
            capabilityID: try TranscriptionRuntimeCapabilityID("runtime-jsonl-fixture"),
            profileID: profile.profileID,
            runtimeIdentity: profile.runtimeVersion
        )
        let modelCapability = VerifiedTranscriptionModel(
            capabilityID: try TranscriptionModelCapabilityID("model-jsonl-fixture"),
            profileID: profile.profileID,
            modelRevision: profile.modelRevision
        )
        request = TranscriptionRequest(
            source: source,
            jobID: try TranscriptionJobID("job-20260830T120500000Z-5GHJ"),
            revisionID: try TranscriptRevisionID("trv-20260830T120600000Z-6JKM"),
            createdAt: try UTCInstant("2026-08-30T12:06:00.000Z"),
            profile: profile,
            runtimeCapability: runtimeCapability,
            modelCapability: modelCapability,
            cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                "cancel-engine-fixture"
            )
        )
    }

    func hello() throws -> Data { try line(helloDictionary()) }

    func helloDictionary() -> [String: Any] {
        [
            "v": 1,
            "type": "hello",
            "qualificationProfileId": profile.profileID,
            "engineLockSha256": profile.qualification.engineLockSHA256,
            "runtimeIdentity": profile.runtimeVersion,
            "runtimeLockSha256": profile.packageLockSHA256,
            "modelRevision": profile.modelRevision,
            "compatibilityPatchId": profile.compatibilityPatchID,
        ]
    }

    func candidateReady(hash: String) throws -> Data {
        try line([
            "v": 1,
            "type": "candidate_ready",
            "jobId": request.jobID.rawValue,
            "result": "result.json",
            "sha256": hash,
        ])
    }

    func candidateArtifact() throws -> Data {
        let qualification = profile.qualification
        return try line([
            "schemaVersion": 1,
            "jobId": request.jobID.rawValue,
            "sessionId": request.selection.sessionID.rawValue,
            "revisionId": request.revisionID.rawValue,
            "durationMs": request.durationMilliseconds,
            "audioFingerprintSha256": sourceFingerprint,
            "sourceFingerprints": [
                ["audioSourceId": "src-0001", "sha256": sourceFingerprint],
            ],
            "engine": [
                "provider": profile.engine.provider,
                "model": profile.engine.model,
                "revision": profile.engine.revision,
                "language": profile.engine.language,
                "mode": profile.engine.mode,
                "decodingOptionsSha256": profile.engine.decodingOptionsSHA256,
                "qualification": [
                    "schemaVersion": 1,
                    "qualificationProfileId": qualification.qualificationProfileID,
                    "engineLockSha256": qualification.engineLockSHA256,
                    "runtimeIdentity": qualification.runtimeIdentity,
                    "runtimeLockSha256": qualification.runtimeLockSHA256,
                    "compatibilityPatchId": qualification.compatibilityPatchID,
                ],
            ],
            "lines": [
                [
                    "lineId": "l000000",
                    "order": 0,
                    "audioSourceId": "src-0001",
                    "startMs": 0,
                    "endMs": 2_000,
                    "text": "Hello world.",
                    "words": [
                        [
                            "wordId": "w000000", "ordinal": 0,
                            "text": "Hello", "startUtf8Byte": 0,
                            "endUtf8Byte": 5, "startMs": 0, "endMs": 800,
                            "confidence": 0.99, "wordKind": "lexical",
                        ],
                        [
                            "wordId": "w000001", "ordinal": 1,
                            "text": "world", "startUtf8Byte": 6,
                            "endUtf8Byte": 11, "startMs": 900, "endMs": 1_800,
                            "confidence": 0.98, "wordKind": "lexical",
                        ],
                    ],
                ],
            ],
            "audioEvents": [],
        ])
    }

    func validatingJob(candidateArtifactSHA256: String) -> SessionProcessingJob {
        SessionProcessingJob(
            jobID: request.jobID,
            sessionID: request.selection.sessionID,
            revisionID: request.revisionID,
            profileID: profile.profileID,
            createdAt: request.createdAt,
            state: .validating,
            cancellationAuthorityID: request.execution.cancellationAuthorityID!,
            candidateArtifactSHA256: candidateArtifactSHA256
        )
    }
}

private func line(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func syntheticCanonicalWAV(frameCount: UInt32) -> Data {
    let payloadBytes = frameCount * 2
    var data = Data()
    func appendASCII(_ value: String) { data.append(contentsOf: value.utf8) }
    func appendLE16(_ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }
    func appendLE32(_ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
    appendASCII("RIFF")
    appendLE32(36 + payloadBytes)
    appendASCII("WAVEfmt ")
    appendLE32(16)
    appendLE16(1)
    appendLE16(1)
    appendLE32(16_000)
    appendLE32(32_000)
    appendLE16(2)
    appendLE16(16)
    appendASCII("data")
    appendLE32(payloadBytes)
    for frame in 0..<frameCount {
        let sample: Int16 = frame.isMultiple(of: 2) ? 1_200 : -1_200
        appendLE16(UInt16(bitPattern: sample))
    }
    return data
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        handler(error)
    }
}
