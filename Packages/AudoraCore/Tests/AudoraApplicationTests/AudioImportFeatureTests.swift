@testable import AudoraApplication
import AudoraDomain
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class AudioImportFeatureTests: XCTestCase {
    func testSuccessfulImportPublishesOnlyReopenedValidatedSession() async throws {
        let fixture = try AudioFixture()
        let port = ScriptedAudioPort(
            chooseOutcome: .selected(fixture.token, scope: fixture.scope),
            preparedCandidate: fixture.candidate,
            installResult: .success(fixture.snapshot)
        )
        let clock = AudioClock(value: fixture.instant)
        let ids = AudioSessionIDGenerator(value: fixture.session.sessionID)
        let feature = DefaultAudioImportFeature(
            port: port,
            clock: clock,
            sessionIDGenerator: ids
        )

        await feature.send(.chooseAudio)
        let state = await waitForTerminal(feature)
        let recording = await port.recording
        let clockCalls = await clock.callCount
        let idCalls = await ids.callCount

        XCTAssertEqual(state.status, .succeeded(fixture.snapshot))
        XCTAssertEqual(recording.calls, [.choose, .reserveSessionID, .prepare, .install])
        XCTAssertEqual(recording.phases, [.copying, .inspecting, .normalizing])
        XCTAssertEqual(recording.seeds, [fixture.seed])
        XCTAssertEqual(clockCalls, 1)
        XCTAssertEqual(idCalls, 1)
    }

    func testSelectionCancellationPublishesBoundedFailureWithoutCreatingIdentity() async throws {
        let port = ScriptedAudioPort(chooseOutcome: .cancelled)
        let clock = AudioClock()
        let ids = AudioSessionIDGenerator()
        let feature = DefaultAudioImportFeature(
            port: port,
            clock: clock,
            sessionIDGenerator: ids
        )

        await feature.send(.chooseAudio)
        let state = await waitForTerminal(feature)
        let recording = await port.recording
        let clockCalls = await clock.callCount
        let idCalls = await ids.callCount

        XCTAssertEqual(state.status, .failed(.cancelled))
        XCTAssertEqual(recording.calls, [.choose])
        XCTAssertEqual(clockCalls, 0)
        XCTAssertEqual(idCalls, 0)
    }

    func testUntrustedCandidateMismatchIsDiscardedBeforeInstall() async throws {
        let fixture = try AudioFixture()
        let corrupt = fixture.candidate.replacing(canonicalSampleRateHz: 48_000)
        let port = ScriptedAudioPort(
            chooseOutcome: .selected(fixture.token, scope: fixture.scope),
            preparedCandidate: corrupt,
            installResult: .success(fixture.snapshot)
        )
        let feature = makeFeature(port, fixture)

        await feature.send(.chooseAudio)
        let state = await waitForTerminal(feature)
        let recording = await port.recording

        XCTAssertEqual(state.status, .failed(.candidateCorrupt))
        XCTAssertEqual(recording.calls, [.choose, .reserveSessionID, .prepare, .discard])
        XCTAssertEqual(recording.discarded, [fixture.stagingID])
    }

    func testPreparationFailureNeverInstallsOrPublishesSession() async throws {
        let fixture = try AudioFixture()
        let port = ScriptedAudioPort(
            chooseOutcome: .selected(fixture.token, scope: fixture.scope),
            preparedCandidate: fixture.candidate,
            prepareFailure: .durationExceeded
        )
        let feature = makeFeature(port, fixture)

        await feature.send(.chooseAudio)
        let state = await waitForTerminal(feature)
        let recording = await port.recording

        XCTAssertEqual(state.status, .failed(.durationExceeded))
        XCTAssertEqual(recording.calls, [.choose, .reserveSessionID, .prepare])
    }

    func testPrecommitInstallFailureDiscardsOnlyItsStagedCandidate() async throws {
        let fixture = try AudioFixture()
        let port = ScriptedAudioPort(
            chooseOutcome: .selected(fixture.token, scope: fixture.scope),
            preparedCandidate: fixture.candidate,
            installResult: .failure(.writeFailed)
        )
        let feature = makeFeature(port, fixture)

        await feature.send(.chooseAudio)
        let state = await waitForTerminal(feature)
        let recording = await port.recording

        XCTAssertEqual(state.status, .failed(.writeFailed))
        XCTAssertEqual(
            recording.calls,
            [.choose, .reserveSessionID, .prepare, .install, .discard]
        )
        XCTAssertEqual(recording.discarded, [fixture.stagingID])
    }

    func testPostcommitReopenFailureDoesNotRequestDeletion() async throws {
        let fixture = try AudioFixture()
        let port = ScriptedAudioPort(
            chooseOutcome: .selected(fixture.token, scope: fixture.scope),
            preparedCandidate: fixture.candidate,
            installResult: .failure(.installedNeedsRefresh)
        )
        let feature = makeFeature(port, fixture)

        await feature.send(.chooseAudio)
        let state = await waitForTerminal(feature)
        let recording = await port.recording

        XCTAssertEqual(state.status, .failed(.installedNeedsRefresh))
        XCTAssertEqual(recording.calls, [.choose, .reserveSessionID, .prepare, .install])
        XCTAssertTrue(recording.discarded.isEmpty)
    }

    func testCancellationAfterPrepareDiscardsStagedCandidateBeforePublication() async throws {
        let fixture = try AudioFixture()
        let port = ScriptedAudioPort(
            chooseOutcome: .selected(fixture.token, scope: fixture.scope),
            preparedCandidate: fixture.candidate,
            installResult: .success(fixture.snapshot),
            suspendPrepare: true
        )
        let feature = makeFeature(port, fixture)

        await feature.send(.chooseAudio)
        await port.waitForPrepareCall()
        await feature.send(.cancelImport)
        await port.resumePrepare()
        let state = await waitForTerminal(feature)
        let recording = await port.recording

        XCTAssertEqual(state.status, .failed(.cancelled))
        XCTAssertEqual(recording.calls, [.choose, .reserveSessionID, .prepare, .discard])
        XCTAssertEqual(recording.discarded, [fixture.stagingID])
    }

    func testSuccessfulInstallWinsCancellationRaceAtAuthorityBoundary() async throws {
        let fixture = try AudioFixture()
        let port = ScriptedAudioPort(
            chooseOutcome: .selected(fixture.token, scope: fixture.scope),
            preparedCandidate: fixture.candidate,
            installResult: .success(fixture.snapshot),
            suspendInstall: true
        )
        let feature = makeFeature(port, fixture)

        await feature.send(.chooseAudio)
        await port.waitForInstallCall()
        await feature.send(.cancelImport)
        await port.resumeInstall()
        let state = await waitForTerminal(feature)
        let recording = await port.recording

        XCTAssertEqual(state.status, .succeeded(fixture.snapshot))
        XCTAssertEqual(recording.calls, [.choose, .reserveSessionID, .prepare, .install])
        XCTAssertTrue(recording.discarded.isEmpty)
    }

    func testConcurrentChooseCommandsLaunchOneEffect() async throws {
        let fixture = try AudioFixture()
        let port = ScriptedAudioPort(
            chooseOutcome: .selected(fixture.token, scope: fixture.scope),
            preparedCandidate: fixture.candidate,
            installResult: .success(fixture.snapshot),
            suspendPrepare: true
        )
        let feature = makeFeature(port, fixture)

        await feature.send(.chooseAudio)
        await port.waitForPrepareCall()
        await feature.send(.chooseAudio)
        let callsWhileSuspended = await port.recording.calls
        XCTAssertEqual(callsWhileSuspended.filter { $0 == .choose }.count, 1)

        await port.resumePrepare()
        _ = await waitForTerminal(feature)
        let finalCalls = await port.recording.calls
        XCTAssertEqual(finalCalls.filter { $0 == .choose }.count, 1)
    }

    func testSessionIDCollisionRegeneratesBeforeAnyPreparationSideEffect() async throws {
        let fixture = try AudioFixture()
        let collidedID = try SessionID("ses-20260830T120000000Z-C011")
        let port = ScriptedAudioPort(
            chooseOutcome: .selected(fixture.token, scope: fixture.scope),
            reservationOutcomes: [.collision, .reserved],
            preparedCandidate: fixture.candidate,
            installResult: .success(fixture.snapshot)
        )
        let ids = AudioSessionIDGenerator(values: [collidedID, fixture.session.sessionID])
        let feature = DefaultAudioImportFeature(
            port: port,
            clock: AudioClock(value: fixture.instant),
            sessionIDGenerator: ids
        )

        await feature.send(.chooseAudio)
        let state = await waitForTerminal(feature)
        let recording = await port.recording
        let idCalls = await ids.callCount

        XCTAssertEqual(state.status, .succeeded(fixture.snapshot))
        XCTAssertEqual(
            recording.calls,
            [.choose, .reserveSessionID, .reserveSessionID, .prepare, .install]
        )
        XCTAssertEqual(recording.reservedSessionIDs, [collidedID, fixture.session.sessionID])
        XCTAssertEqual(recording.seeds, [fixture.seed])
        XCTAssertEqual(idCalls, 2)
    }

    func testSessionIDCollisionRetriesAreBoundedAndNeverPrepare() async throws {
        let fixture = try AudioFixture()
        let collidedIDs = try [
            SessionID("ses-20260830T120000000Z-C011"),
            SessionID("ses-20260830T120000000Z-C012"),
            SessionID("ses-20260830T120000000Z-C013"),
        ]
        let port = ScriptedAudioPort(
            chooseOutcome: .selected(fixture.token, scope: fixture.scope),
            reservationOutcomes: [.collision, .collision, .collision]
        )
        let ids = AudioSessionIDGenerator(values: collidedIDs)
        let feature = DefaultAudioImportFeature(
            port: port,
            clock: AudioClock(value: fixture.instant),
            sessionIDGenerator: ids
        )

        await feature.send(.chooseAudio)
        let state = await waitForTerminal(feature)
        let recording = await port.recording
        let idCalls = await ids.callCount

        XCTAssertEqual(state.status, .failed(.destinationCollision))
        XCTAssertEqual(
            recording.calls,
            [.choose, .reserveSessionID, .reserveSessionID, .reserveSessionID, .revoke]
        )
        XCTAssertEqual(recording.reservedSessionIDs, collidedIDs)
        XCTAssertTrue(recording.seeds.isEmpty)
        XCTAssertEqual(idCalls, 3)
    }

    private func makeFeature(
        _ port: ScriptedAudioPort,
        _ fixture: AudioFixture
    ) -> DefaultAudioImportFeature {
        DefaultAudioImportFeature(
            port: port,
            clock: AudioClock(value: fixture.instant),
            sessionIDGenerator: AudioSessionIDGenerator(value: fixture.session.sessionID)
        )
    }

    private func waitForTerminal(
        _ feature: DefaultAudioImportFeature
    ) async -> AudioImportFeatureState {
        for _ in 0..<20_000 {
            let state = await feature.currentState
            if !state.isImporting { return state }
            await Task.yield()
        }
        XCTFail("audio import did not reach a terminal state")
        return await feature.currentState
    }
}

private struct AudioFixture {
    let token = AudioSelectionToken("audio_fixture")!
    let stagingID = AudioStagingID("staging_fixture")!
    let scope: AudioImportScopeIdentity
    let instant: UTCInstant
    let session: ImportedSession
    let seed: ImportedSessionSeed
    let candidate: StagedAudioCandidate
    let snapshot: ReopenedImportedSessionSnapshot

    init() throws {
        let libraryID = try LibraryID("lib-20260830T120000000Z-2ABC")
        scope = AudioImportScopeIdentity(libraryID: libraryID, workspaceGeneration: 7)
        instant = try UTCInstant("2026-08-30T12:00:00.000Z")
        let sessionID = try SessionID("ses-20260830T120000000Z-3DEF")
        let hashA = String(repeating: "a", count: 64)
        let hashB = String(repeating: "b", count: 64)
        let hashC = String(repeating: "c", count: 64)
        let original = try OriginalAudioArtifact(
            relativePath: LibraryRelativePath("audio/original.wav"),
            container: .wav,
            fingerprint: AudioArtifactFingerprint(byteCount: 12, sha256: hashA),
            decodedCodec: .linearPCM,
            sourceSampleRateHz: 16_000,
            sourceChannelCount: 1
        )
        let canonical = try CanonicalAudioArtifact(
            relativePath: LibraryRelativePath("audio/audio.wav"),
            fingerprint: AudioArtifactFingerprint(byteCount: 46, sha256: hashB),
            frameCount: 1,
            durationMilliseconds: 1
        )
        let source = try SessionAudioSource(
            audioSourceID: .microphone,
            role: .microphone,
            timelineOffsetMilliseconds: 0
        )
        let audio = try ImportedAudioAsset(
            original: original,
            canonical: canonical,
            sources: [source],
            normalization: .v1
        )
        session = try ImportedSession(
            sessionID: sessionID,
            createdAt: instant,
            durationMilliseconds: 1,
            audioManifestSHA256: hashC,
            audio: audio
        )
        seed = ImportedSessionSeed(scope: scope, sessionID: sessionID, createdAt: instant)
        candidate = StagedAudioCandidate(
            stagingID: stagingID,
            scope: scope,
            sessionID: sessionID.rawValue,
            createdAt: instant.rawValue,
            audioManifestSHA256: hashC,
            originalRelativePath: "audio/original.wav",
            originalContainer: "wav",
            originalByteCount: 12,
            originalSHA256: hashA,
            decodedCodec: "linearPCM",
            sourceSampleRateHz: 16_000,
            sourceChannelCount: 1,
            canonicalRelativePath: "audio/audio.wav",
            canonicalByteCount: 46,
            canonicalSHA256: hashB,
            canonicalFrameCount: 1,
            canonicalDurationMilliseconds: 1,
            canonicalContainer: "wav",
            canonicalEncoding: "pcmS16LE",
            canonicalSampleRateHz: 16_000,
            canonicalChannelCount: 1,
            canonicalBitsPerSample: 16,
            audioSourceID: "src-0001",
            audioSourceRole: "microphone",
            timelineOffsetMilliseconds: 0,
            normalizationAlgorithmID: "audora-avfoundation",
            normalizationAlgorithmVersion: 1,
            stereoRule: "arithmeticMean",
            resamplerVersion: "av-audio-converter-normal-max-normal-prime-v1",
            quantizerVersion: "s16-round-away-saturate-v1"
        )
        snapshot = ReopenedImportedSessionSnapshot(session: session)
    }
}

private extension StagedAudioCandidate {
    func replacing(canonicalSampleRateHz: UInt32) -> StagedAudioCandidate {
        StagedAudioCandidate(
            stagingID: stagingID,
            scope: scope,
            sessionID: sessionID,
            createdAt: createdAt,
            audioManifestSHA256: audioManifestSHA256,
            originalRelativePath: originalRelativePath,
            originalContainer: originalContainer,
            originalByteCount: originalByteCount,
            originalSHA256: originalSHA256,
            decodedCodec: decodedCodec,
            sourceSampleRateHz: sourceSampleRateHz,
            sourceChannelCount: sourceChannelCount,
            canonicalRelativePath: canonicalRelativePath,
            canonicalByteCount: canonicalByteCount,
            canonicalSHA256: canonicalSHA256,
            canonicalFrameCount: canonicalFrameCount,
            canonicalDurationMilliseconds: canonicalDurationMilliseconds,
            canonicalContainer: canonicalContainer,
            canonicalEncoding: canonicalEncoding,
            canonicalSampleRateHz: canonicalSampleRateHz,
            canonicalChannelCount: canonicalChannelCount,
            canonicalBitsPerSample: canonicalBitsPerSample,
            audioSourceID: audioSourceID,
            audioSourceRole: audioSourceRole,
            timelineOffsetMilliseconds: timelineOffsetMilliseconds,
            normalizationAlgorithmID: normalizationAlgorithmID,
            normalizationAlgorithmVersion: normalizationAlgorithmVersion,
            stereoRule: stereoRule,
            resamplerVersion: resamplerVersion,
            quantizerVersion: quantizerVersion
        )
    }
}

private actor AudioClock: LibraryClock {
    private let value: UTCInstant
    private(set) var callCount = 0

    init(value: UTCInstant = try! UTCInstant("2026-08-30T12:00:00.000Z")) {
        self.value = value
    }

    func now() -> UTCInstant {
        callCount += 1
        return value
    }
}

private actor AudioSessionIDGenerator: SessionIDGenerator {
    private var values: [SessionID]
    private(set) var callCount = 0

    init(value: SessionID = try! SessionID("ses-20260830T120000000Z-3DEF")) {
        values = [value]
    }

    init(values: [SessionID]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    func generateSessionID(at instant: UTCInstant) -> SessionID {
        callCount += 1
        return values.count == 1 ? values[0] : values.removeFirst()
    }
}

private actor ScriptedAudioPort: AudioImportPort {
    enum Call: Equatable, Sendable {
        case choose
        case revoke
        case reserveSessionID
        case prepare
        case install
        case discard
    }

    private let chooseOutcome: AudioSelectionOutcome
    private var reservationOutcomes: [AudioImportSessionIDReservationOutcome]
    private let preparedCandidate: StagedAudioCandidate?
    private let prepareFailure: AudioImportFailure?
    private let installResult: Result<ReopenedImportedSessionSnapshot, AudioImportFailure>?
    private let suspendPrepare: Bool
    private let suspendInstall: Bool
    private var prepareContinuation: CheckedContinuation<Void, Never>?
    private var installContinuation: CheckedContinuation<Void, Never>?
    private(set) var calls: [Call] = []
    private(set) var phases: [AudioImportPreparationPhase] = []
    private(set) var reservedSessionIDs: [SessionID] = []
    private(set) var seeds: [ImportedSessionSeed] = []
    private(set) var discarded: [AudioStagingID] = []

    var recording: AudioPortRecording {
        AudioPortRecording(
            calls: calls,
            phases: phases,
            reservedSessionIDs: reservedSessionIDs,
            seeds: seeds,
            discarded: discarded
        )
    }

    init(
        chooseOutcome: AudioSelectionOutcome,
        reservationOutcomes: [AudioImportSessionIDReservationOutcome] = [.reserved],
        preparedCandidate: StagedAudioCandidate? = nil,
        prepareFailure: AudioImportFailure? = nil,
        installResult: Result<ReopenedImportedSessionSnapshot, AudioImportFailure>? = nil,
        suspendPrepare: Bool = false,
        suspendInstall: Bool = false
    ) {
        self.chooseOutcome = chooseOutcome
        self.reservationOutcomes = reservationOutcomes
        self.preparedCandidate = preparedCandidate
        self.prepareFailure = prepareFailure
        self.installResult = installResult
        self.suspendPrepare = suspendPrepare
        self.suspendInstall = suspendInstall
    }

    func choose() -> AudioSelectionOutcome {
        calls.append(.choose)
        return chooseOutcome
    }

    func revokeSelection(_ token: AudioSelectionToken) {
        calls.append(.revoke)
    }

    func reserveSessionID(
        _ sessionID: SessionID,
        for token: AudioSelectionToken,
        in scope: AudioImportScopeIdentity
    ) throws -> AudioImportSessionIDReservationOutcome {
        calls.append(.reserveSessionID)
        reservedSessionIDs.append(sessionID)
        guard !reservationOutcomes.isEmpty else {
            throw AudioImportFailure.unavailable
        }
        return reservationOutcomes.removeFirst()
    }

    func prepare(
        _ token: AudioSelectionToken,
        seed: ImportedSessionSeed,
        policy: AudioImportPolicy,
        progress: @escaping @Sendable (AudioImportPreparationPhase) async -> Void
    ) async throws -> StagedAudioCandidate {
        calls.append(.prepare)
        seeds.append(seed)
        for phase in [
            AudioImportPreparationPhase.copying,
            .inspecting,
            .normalizing,
        ] {
            phases.append(phase)
            await progress(phase)
        }
        if suspendPrepare {
            await withCheckedContinuation { continuation in
                prepareContinuation = continuation
            }
        }
        if let prepareFailure { throw prepareFailure }
        guard let preparedCandidate else { throw AudioImportFailure.unavailable }
        return preparedCandidate
    }

    func install(
        _ candidate: ValidatedImportedSession
    ) async throws -> ReopenedImportedSessionSnapshot {
        calls.append(.install)
        if suspendInstall {
            await withCheckedContinuation { continuation in
                installContinuation = continuation
            }
        }
        guard let installResult else { throw AudioImportFailure.writeFailed }
        return try installResult.get()
    }

    func discard(_ stagingID: AudioStagingID) {
        calls.append(.discard)
        discarded.append(stagingID)
    }

    func waitForPrepareCall() async {
        while !calls.contains(.prepare) { await Task.yield() }
    }

    func waitForInstallCall() async {
        while !calls.contains(.install) { await Task.yield() }
    }

    func resumePrepare() {
        prepareContinuation?.resume()
        prepareContinuation = nil
    }

    func resumeInstall() {
        installContinuation?.resume()
        installContinuation = nil
    }
}

private struct AudioPortRecording: Sendable {
    let calls: [ScriptedAudioPort.Call]
    let phases: [AudioImportPreparationPhase]
    let reservedSessionIDs: [SessionID]
    let seeds: [ImportedSessionSeed]
    let discarded: [AudioStagingID]
}
