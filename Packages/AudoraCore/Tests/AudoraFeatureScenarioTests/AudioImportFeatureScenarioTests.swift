import AudoraApplication
import AudoraContracts
import AudoraDomain
import Foundation
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class AudioImportFeatureScenarioTests: XCTestCase {
    func testEveryPortableAudioImportScenarioMatchesTheSwiftFeature() async throws {
        let resources: [ContractResource] = [
            .audioImportSuccessScenario,
            .audioImportSelectionCancelledScenario,
            .audioImportNormalizationFailureScenario,
            .audioImportCorruptCandidateScenario,
            .audioImportInstallFailureScenario,
            .audioImportPostcommitFailureScenario,
            .audioImportCollisionRegenerationScenario,
        ]

        for resource in resources {
            let data = try ContractResources.data(for: resource)
            let scenario = try AudioScenario(
                JSONDecoder().decode(AudioScenarioDTO.self, from: data)
            )
            let fixture = try AudioScenarioFixture()
            let recorder = AudioScenarioTraceRecorder(events: scenario.trace)
            let feature = DefaultAudioImportFeature(
                port: AudioScenarioPort(recorder: recorder, fixture: fixture),
                clock: AudioScenarioClock(recorder: recorder),
                sessionIDGenerator: AudioScenarioIDGenerator(recorder: recorder)
            )

            let initial = await feature.currentState
            XCTAssertEqual(initial, scenario.initialState, scenario.id)
            for command in scenario.commands { await feature.send(command) }
            let final = await waitForTerminal(feature)
            XCTAssertEqual(final, scenario.expectedState(fixture: fixture), scenario.id)
            let status = await recorder.status
            XCTAssertEqual(status.consumed, scenario.trace.count, scenario.id)
            XCTAssertEqual(status.errors, [], scenario.id)
        }
    }

    func testScenarioEnvelopeRejectsUnknownVersionStateAndCommand() throws {
        let data = try ContractResources.data(for: .audioImportSuccessScenario)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["schemaVersion"] = 2
        XCTAssertThrowsError(
            try AudioScenario(
                JSONDecoder().decode(
                    AudioScenarioDTO.self,
                    from: JSONSerialization.data(withJSONObject: object)
                )
            )
        )
        object["schemaVersion"] = 1
        object["commands"] = [["kind": "transcribe"]]
        XCTAssertThrowsError(
            try AudioScenario(
                JSONDecoder().decode(
                    AudioScenarioDTO.self,
                    from: JSONSerialization.data(withJSONObject: object)
                )
            )
        )

        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var trace = try XCTUnwrap(object["dependencyTrace"] as? [[String: Any]])
        trace[0]["effect"] = "chooseByPath"
        object["dependencyTrace"] = trace
        XCTAssertThrowsError(
            try AudioScenario(
                JSONDecoder().decode(
                    AudioScenarioDTO.self,
                    from: JSONSerialization.data(withJSONObject: object)
                )
            )
        )

        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        trace = try XCTUnwrap(object["dependencyTrace"] as? [[String: Any]])
        trace[0]["outcome"] = "selectedFromPath"
        object["dependencyTrace"] = trace
        XCTAssertThrowsError(
            try AudioScenario(
                JSONDecoder().decode(
                    AudioScenarioDTO.self,
                    from: JSONSerialization.data(withJSONObject: object)
                )
            )
        )

        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["initialState"] = ["status": "copying", "failure": "writeFailed"]
        XCTAssertThrowsError(
            try AudioScenario(
                JSONDecoder().decode(
                    AudioScenarioDTO.self,
                    from: JSONSerialization.data(withJSONObject: object)
                )
            )
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
        XCTFail("scenario did not reach terminal state")
        return await feature.currentState
    }
}

private struct AudioScenarioDTO: Decodable {
    let schemaVersion: UInt32
    let scenarioId: String
    let initialState: AudioScenarioStateDTO
    let commands: [AudioScenarioCommandDTO]
    let dependencyTrace: [AudioScenarioEventDTO]
    let expectedState: AudioScenarioStateDTO
}

private struct AudioScenarioStateDTO: Decodable {
    let status: String
    let sessionId: String?
    let failure: String?
}

private struct AudioScenarioCommandDTO: Decodable { let kind: String }

private struct AudioScenarioEventDTO: Decodable {
    let port: String
    let effect: String
    let outcome: String
}

private struct AudioScenario {
    let id: String
    let initialState: AudioImportFeatureState
    let commands: [AudioImportCommand]
    let trace: [AudioScenarioEvent]
    private let expected: AudioScenarioStateDTO

    init(_ dto: AudioScenarioDTO) throws {
        guard dto.schemaVersion == 1, !dto.scenarioId.isEmpty else {
            throw AudioScenarioError.invalidEnvelope
        }
        id = dto.scenarioId
        initialState = try Self.state(dto.initialState, fixture: nil)
        commands = try dto.commands.map { command in
            switch command.kind {
            case "chooseAudio": .chooseAudio
            case "cancelImport": .cancelImport
            case "clearResult": .clearResult
            default: throw AudioScenarioError.invalidCommand
            }
        }
        guard !commands.isEmpty else { throw AudioScenarioError.invalidCommand }
        trace = try dto.dependencyTrace.map(AudioScenarioEvent.init)
        expected = dto.expectedState
        _ = try Self.validateStateShape(expected)
    }

    func expectedState(fixture: AudioScenarioFixture) -> AudioImportFeatureState {
        try! Self.state(expected, fixture: fixture)
    }

    private static func state(
        _ dto: AudioScenarioStateDTO,
        fixture: AudioScenarioFixture?
    ) throws -> AudioImportFeatureState {
        try validateStateShape(dto)
        switch dto.status {
        case "idle": return AudioImportFeatureState(status: .idle)
        case "selecting": return AudioImportFeatureState(status: .selecting)
        case "copying": return AudioImportFeatureState(status: .copying)
        case "inspecting": return AudioImportFeatureState(status: .inspecting)
        case "normalizing": return AudioImportFeatureState(status: .normalizing)
        case "installing": return AudioImportFeatureState(status: .installing)
        case "failed":
            guard let raw = dto.failure, let failure = AudioImportFailure(rawValue: raw) else {
                throw AudioScenarioError.invalidState
            }
            return AudioImportFeatureState(status: .failed(failure))
        case "succeeded":
            guard let fixture, dto.sessionId == fixture.session.sessionID.rawValue else {
                throw AudioScenarioError.invalidState
            }
            return AudioImportFeatureState(
                status: .succeeded(ReopenedImportedSessionSnapshot(session: fixture.session))
            )
        default: throw AudioScenarioError.invalidState
        }
    }

    private static func validateStateShape(_ dto: AudioScenarioStateDTO) throws {
        switch dto.status {
        case "idle", "selecting", "copying", "inspecting", "normalizing", "installing":
            guard dto.sessionId == nil, dto.failure == nil else {
                throw AudioScenarioError.invalidState
            }
        case "failed":
            guard dto.sessionId == nil,
                  let failure = dto.failure,
                  AudioImportFailure(rawValue: failure) != nil
            else {
                throw AudioScenarioError.invalidState
            }
        case "succeeded":
            guard dto.failure == nil, let id = dto.sessionId, (try? SessionID(id)) != nil else {
                throw AudioScenarioError.invalidState
            }
        default: throw AudioScenarioError.invalidState
        }
    }
}

private enum AudioScenarioError: Error {
    case invalidEnvelope
    case invalidState
    case invalidCommand
    case invalidEvent
}

private struct AudioScenarioEvent: Sendable {
    let port: String
    let effect: String
    let outcome: String

    init(_ dto: AudioScenarioEventDTO) throws {
        let valid: Bool
        switch (dto.port, dto.effect) {
        case ("audioImport", "choose"):
            valid = dto.outcome == "selected" || dto.outcome == "cancelled" ||
                AudioImportFailure(rawValue: dto.outcome) != nil
        case ("audioImport", "revokeSelection"):
            valid = dto.outcome == "revoked"
        case ("audioImport", "reserveSessionId"):
            valid = dto.outcome == "reserved" || dto.outcome == "collision" ||
                AudioImportFailure(rawValue: dto.outcome) != nil
        case ("audioImport", "prepare"):
            valid = dto.outcome == "candidate" || dto.outcome == "corruptCandidate" ||
                AudioImportFailure(rawValue: dto.outcome) != nil
        case ("audioImport", "install"):
            valid = dto.outcome == "reopened" ||
                AudioImportFailure(rawValue: dto.outcome) != nil
        case ("audioImport", "discard"):
            valid = dto.outcome == "discarded"
        case ("clock", "now"):
            valid = (try? UTCInstant(dto.outcome)) != nil
        case ("sessionIdGenerator", "generateSessionId"):
            valid = (try? SessionID(dto.outcome)) != nil
        default:
            valid = false
        }
        guard valid else {
            throw AudioScenarioError.invalidEvent
        }
        port = dto.port
        effect = dto.effect
        outcome = dto.outcome
    }
}

private actor AudioScenarioTraceRecorder {
    struct Status: Sendable {
        let consumed: Int
        let errors: [String]
    }

    private let events: [AudioScenarioEvent]
    private var index = 0
    private var errors: [String] = []

    init(events: [AudioScenarioEvent]) { self.events = events }

    func consume(port: String, effect: String) -> AudioScenarioEvent? {
        guard index < events.count else {
            errors.append("unexpected-effect")
            return nil
        }
        let event = events[index]
        index += 1
        if event.port != port || event.effect != effect {
            errors.append("trace-order-mismatch")
        }
        return event
    }

    var status: Status { Status(consumed: index, errors: errors) }
}

private actor AudioScenarioPort: AudioImportPort {
    private let recorder: AudioScenarioTraceRecorder
    private let fixture: AudioScenarioFixture

    init(recorder: AudioScenarioTraceRecorder, fixture: AudioScenarioFixture) {
        self.recorder = recorder
        self.fixture = fixture
    }

    func choose() async -> AudioSelectionOutcome {
        guard let event = await recorder.consume(port: "audioImport", effect: "choose") else {
            return .failed(.unavailable)
        }
        switch event.outcome {
        case "selected": return .selected(fixture.token, scope: fixture.scope)
        case "cancelled": return .cancelled
        default: return .failed(AudioImportFailure(rawValue: event.outcome) ?? .unavailable)
        }
    }

    func revokeSelection(_ token: AudioSelectionToken) async {
        _ = await recorder.consume(port: "audioImport", effect: "revokeSelection")
    }

    func reserveSessionID(
        _ sessionID: SessionID,
        for token: AudioSelectionToken,
        in scope: AudioImportScopeIdentity
    ) async throws -> AudioImportSessionIDReservationOutcome {
        guard let event = await recorder.consume(
            port: "audioImport",
            effect: "reserveSessionId"
        ) else {
            throw AudioImportFailure.unavailable
        }
        switch event.outcome {
        case "reserved": return .reserved
        case "collision": return .collision
        default: throw AudioImportFailure(rawValue: event.outcome) ?? .unavailable
        }
    }

    func prepare(
        _ token: AudioSelectionToken,
        seed: ImportedSessionSeed,
        policy: AudioImportPolicy,
        progress: @escaping @Sendable (AudioImportPreparationPhase) async -> Void
    ) async throws -> StagedAudioCandidate {
        guard let event = await recorder.consume(port: "audioImport", effect: "prepare") else {
            throw AudioImportFailure.unavailable
        }
        await progress(.copying)
        await progress(.inspecting)
        await progress(.normalizing)
        switch event.outcome {
        case "candidate": return fixture.candidate
        case "corruptCandidate": return fixture.corruptCandidate
        default: throw AudioImportFailure(rawValue: event.outcome) ?? .unavailable
        }
    }

    func install(
        _ candidate: ValidatedImportedSession
    ) async throws -> ReopenedImportedSessionSnapshot {
        guard let event = await recorder.consume(port: "audioImport", effect: "install") else {
            throw AudioImportFailure.writeFailed
        }
        guard event.outcome == "reopened" else {
            throw AudioImportFailure(rawValue: event.outcome) ?? .writeFailed
        }
        return ReopenedImportedSessionSnapshot(session: fixture.session)
    }

    func discard(_ stagingID: AudioStagingID) async {
        _ = await recorder.consume(port: "audioImport", effect: "discard")
    }
}

private actor AudioScenarioClock: LibraryClock {
    let recorder: AudioScenarioTraceRecorder

    init(recorder: AudioScenarioTraceRecorder) { self.recorder = recorder }

    func now() async -> UTCInstant {
        let event = await recorder.consume(port: "clock", effect: "now")
        return (try? UTCInstant(event?.outcome ?? ""))
            ?? (try! UTCInstant("2026-08-30T12:00:00.000Z"))
    }
}

private actor AudioScenarioIDGenerator: SessionIDGenerator {
    let recorder: AudioScenarioTraceRecorder

    init(recorder: AudioScenarioTraceRecorder) { self.recorder = recorder }

    func generateSessionID(at instant: UTCInstant) async -> SessionID {
        let event = await recorder.consume(
            port: "sessionIdGenerator",
            effect: "generateSessionId"
        )
        return (try? SessionID(event?.outcome ?? ""))
            ?? (try! SessionID("ses-20260830T120000000Z-3DEF"))
    }
}

private struct AudioScenarioFixture: Sendable {
    let token = AudioSelectionToken("scenario_audio")!
    let scope: AudioImportScopeIdentity
    let session: ImportedSession
    let candidate: StagedAudioCandidate
    let corruptCandidate: StagedAudioCandidate

    init() throws {
        scope = AudioImportScopeIdentity(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC"),
            workspaceGeneration: 1
        )
        let originalHash = String(repeating: "a", count: 64)
        let canonicalHash = String(repeating: "b", count: 64)
        let manifestHash = String(repeating: "c", count: 64)
        let audio = try ImportedAudioAsset(
            original: OriginalAudioArtifact(
                relativePath: LibraryRelativePath("audio/original.wav"),
                container: .wav,
                fingerprint: AudioArtifactFingerprint(
                    byteCount: 24,
                    sha256: originalHash
                ),
                decodedCodec: .linearPCM,
                sourceSampleRateHz: 48_000,
                sourceChannelCount: 2
            ),
            canonical: CanonicalAudioArtifact(
                relativePath: LibraryRelativePath("audio/audio.wav"),
                fingerprint: AudioArtifactFingerprint(
                    byteCount: 50,
                    sha256: canonicalHash
                ),
                frameCount: 3,
                durationMilliseconds: 1
            ),
            sources: [
                try SessionAudioSource(
                    audioSourceID: .microphone,
                    role: .microphone,
                    timelineOffsetMilliseconds: 0
                ),
            ],
            normalization: .v1
        )
        session = try ImportedSession(
            sessionID: SessionID("ses-20260830T120000000Z-3DEF"),
            createdAt: UTCInstant("2026-08-30T12:00:00.000Z"),
            durationMilliseconds: 1,
            audioManifestSHA256: manifestHash,
            audio: audio
        )
        let stagingID = AudioStagingID("scenario_staging")!
        candidate = Self.makeCandidate(
            stagingID: stagingID,
            scope: scope,
            session: session,
            sampleRate: 16_000
        )
        corruptCandidate = Self.makeCandidate(
            stagingID: stagingID,
            scope: scope,
            session: session,
            sampleRate: 48_000
        )
    }

    private static func makeCandidate(
        stagingID: AudioStagingID,
        scope: AudioImportScopeIdentity,
        session: ImportedSession,
        sampleRate: UInt32
    ) -> StagedAudioCandidate {
        let audio = session.audio
        return StagedAudioCandidate(
            stagingID: stagingID,
            scope: scope,
            sessionID: session.sessionID.rawValue,
            createdAt: session.createdAt.rawValue,
            audioManifestSHA256: session.audioManifestSHA256,
            originalRelativePath: audio.original.relativePath.description,
            originalContainer: audio.original.container.rawValue,
            originalByteCount: audio.original.fingerprint.byteCount,
            originalSHA256: audio.original.fingerprint.sha256,
            decodedCodec: audio.original.decodedCodec.rawValue,
            sourceSampleRateHz: audio.original.sourceSampleRateHz,
            sourceChannelCount: audio.original.sourceChannelCount,
            canonicalRelativePath: audio.canonical.relativePath.description,
            canonicalByteCount: audio.canonical.fingerprint.byteCount,
            canonicalSHA256: audio.canonical.fingerprint.sha256,
            canonicalFrameCount: audio.canonical.frameCount,
            canonicalDurationMilliseconds: audio.canonical.durationMilliseconds,
            canonicalContainer: audio.canonical.format.container,
            canonicalEncoding: audio.canonical.format.encoding,
            canonicalSampleRateHz: sampleRate,
            canonicalChannelCount: audio.canonical.format.channelCount,
            canonicalBitsPerSample: audio.canonical.format.bitsPerSample,
            audioSourceID: audio.sources[0].audioSourceID.rawValue,
            audioSourceRole: audio.sources[0].role.rawValue,
            timelineOffsetMilliseconds: audio.sources[0].timelineOffsetMilliseconds,
            normalizationAlgorithmID: audio.normalization.algorithmID,
            normalizationAlgorithmVersion: audio.normalization.algorithmVersion,
            stereoRule: audio.normalization.stereoRule,
            resamplerVersion: audio.normalization.resamplerVersion,
            quantizerVersion: audio.normalization.quantizerVersion
        )
    }
}
