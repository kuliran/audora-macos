@testable import AudoraApplication
import AudoraContracts
import AudoraDomain
import Foundation
import XCTest

final class RecordingFeatureScenarioTests: XCTestCase {
    func testAllEighteenRecordingScenariosDecodeStrictlyAndExecute() async throws {
        let executedCount = try await executeAllRecordingScenarioFixtures()
        XCTAssertEqual(executedCount, 18)
    }

    func testScenarioInventoryPinsEveryRequiredBehavior() throws {
        XCTAssertEqual(
            Set(recordingScenarioResources.map(\.rawValue)),
            [
                "honest-live-state.v1.json",
                "live-mute-acknowledgement.v1.json",
                "mute-gap-unavailable.v1.json",
                "five-minute-warning.v1.json",
                "one-minute-countdown.v1.json",
                "duration-limit-seals.v1.json",
                "user-stop-seals.v1.json",
                "stop-limit-race.v1.json",
                "cancel-keeps-recording.v1.json",
                "confirmed-cancel-discards.v1.json",
                "discard-failure-honest.v1.json",
                "start-failure-no-publication.v1.json",
                "interruption-recovery.v1.json",
                "recovered-seal-idempotent.v1.json",
                "recovery-discard-only.v1.json",
                "another-take-new-session.v1.json",
                "late-events-fenced.v1.json",
                "library-switch-serialized.v1.json",
            ]
        )
    }

    func testSemanticIntervalRejectionsUseApplicationAndDomainValidation() throws {
        let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
        let request = MicrophoneRecordingRequest(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T120000000Z-1ABC")
            ),
            recordingID: try RecordingID("rec-20260830T120000000Z-2ABC"),
            sessionID: try SessionID("ses-20260830T120000000Z-3DEF"),
            startedAt: instant
        )
        let resources: [ContractResource] = [
            .rejectedRecordingUnorderedIntervals,
            .rejectedRecordingOverlappingIntervals,
            .rejectedRecordingOutOfBoundsInterval,
        ]

        for resource in resources {
            let fixture = try JSONDecoder().decode(
                RejectedAudioFixture.self,
                from: ContractResources.data(for: resource)
            )
            let candidate = StagedRecordingSealCandidate(
                recordingID: request.recordingID.rawValue,
                sessionID: request.sessionID.rawValue,
                libraryID: request.libraryScope.libraryID.rawValue,
                startedAt: request.startedAt.rawValue,
                terminalReason: CaptureTerminalReason.userStop.rawValue,
                sourceKind: fixture.sourceKind,
                canonicalAudioPath: fixture.canonicalAudioPath,
                sampleRateHz: fixture.canonicalFormat.sampleRateHz,
                channelCount: fixture.canonicalFormat.channelCount,
                encoding: fixture.canonicalFormat.encoding,
                frameCount: fixture.frameCount,
                canonicalSHA256: fixture.canonicalSha256,
                unavailableIntervals: fixture.unavailableIntervals.map {
                    StagedUnavailableInterval(
                        startFrame: $0.startFrame,
                        endFrame: $0.endFrame,
                        reasons: $0.reasons
                    )
                }
            )

            XCTAssertThrowsError(
                try RecordingSealCandidateValidator.validate(candidate, expected: request),
                "\(resource.rawValue) reached publication"
            ) { error in
                XCTAssertEqual(
                    error as? RecordingFailure,
                    .sealValidationFailedRecoverable
                )
            }
        }
    }
}

private struct RejectedAudioFixture: Decodable {
    struct Format: Decodable {
        let sampleRateHz: UInt32
        let channelCount: UInt8
        let encoding: String
    }

    struct Interval: Decodable {
        let startFrame: UInt64
        let endFrame: UInt64
        let reasons: [String]
    }

    let sourceKind: String
    let canonicalAudioPath: String
    let canonicalFormat: Format
    let frameCount: UInt64
    let canonicalSha256: String
    let unavailableIntervals: [Interval]
}

@discardableResult
func executeAllRecordingScenarioFixtures() async throws -> Int {
    guard recordingScenarioResources.count == 18 else {
        throw ScenarioTestError.invalid("expected exactly 18 recording scenarios")
    }
    var scenarioIDs: Set<String> = []
    for resource in recordingScenarioResources {
        let scenario = try StrictScenarioDecoder.decode(
            try ContractResources.data(for: resource)
        )
        guard scenarioIDs.insert(scenario.scenarioId).inserted else {
            throw ScenarioTestError.invalid("duplicate scenario: \(scenario.scenarioId)")
        }
        try await ScenarioExecutor(scenario: scenario).run()
    }
    return scenarioIDs.count
}

private let recordingScenarioResources: [ContractResource] = [
    .recordingHonestLiveScenario,
    .recordingMuteScenario,
    .recordingMuteGapScenario,
    .recordingFiveMinuteWarningScenario,
    .recordingCountdownScenario,
    .recordingDurationLimitScenario,
    .recordingUserStopScenario,
    .recordingStopLimitRaceScenario,
    .recordingCancelScenario,
    .recordingConfirmedCancelScenario,
    .recordingDiscardFailureScenario,
    .recordingStartFailureScenario,
    .recordingInterruptionScenario,
    .recordingRecoveredSealScenario,
    .recordingDiscardOnlyScenario,
    .recordingAnotherTakeScenario,
    .recordingLateEventsScenario,
    .recordingLibrarySwitchScenario,
]

private struct RecordingScenario: Decodable, Sendable {
    let schemaVersion: Int
    let scenarioId: String
    let initialState: ScenarioSnapshot
    let commands: [ScenarioCommand]
    let dependencyTrace: [ScenarioDependency]
    let expectedState: ScenarioSnapshot
    let expectedEffects: [ScenarioEffect]
}

private struct ScenarioSnapshot: Decodable, Equatable, Sendable {
    let kind: ScenarioStateKind
    let elapsedFrames: UInt64?
    let mute: ScenarioMute?
    let limitPhase: ScenarioLimitPhase?
    let secondsRemaining: UInt8?
    let confirmation: ScenarioConfirmation?
    let terminalReason: ScenarioTerminalReason?
    let notice: ScenarioNotice?
}

private enum ScenarioStateKind: String, Decodable, Sendable {
    case unavailable, selectingLibrary, idle, starting, active, finishing, sealing
    case recoveryRequired, resolvingRecovery, completed, failed
}

private enum ScenarioMute: String, Decodable, Sendable {
    case live, muting, muted, unmuting
}

private enum ScenarioLimitPhase: String, Decodable, Sendable {
    case ordinary, fiveMinuteWarning, oneMinuteCountdown, automaticStop
}

private enum ScenarioConfirmation: String, Decodable, Sendable {
    case none, discardRecording
}

private enum ScenarioTerminalReason: String, Decodable, Sendable {
    case userStop, durationLimit, interruption
}

private enum ScenarioNotice: String, Decodable, Sendable {
    case durationLimit
}

private struct ScenarioCommand: Decodable, Sendable {
    let kind: ScenarioCommandKind
}

private enum ScenarioCommandKind: String, Decodable, Sendable {
    case selectLibrary, record, mute, unmute, stop, cancel, keepRecording
    case discardRecording, sealRecovered, discardRecovered
}

private struct ScenarioDependency: Decodable, Equatable, Sendable {
    let port: ScenarioPort
    let effect: ScenarioDependencyEffect
    let outcome: ScenarioDependencyOutcome
    let afterCommand: Int
    let frameCount: UInt64?
    let level: Double?
}

private enum ScenarioPort: String, Decodable, Sendable {
    case clock, recordingIdGenerator, audioCapture, libraryActivity, domain
}

private enum ScenarioDependencyEffect: String, Decodable, Sendable {
    case inspectRecovery, begin, progress, setMuted, muteChanged
    case normalizeUnavailableIntervals, finishing, sealing, sealed, stop
    case discardConfirmed, discarded, recoveryRequired, resolveSeal
}

private enum ScenarioDependencyOutcome: String, Decodable, Sendable {
    case none, started, measured, accepted, muted, live, captureGap
    case mutedGapOverlap, durationLimit, userStop, discarded
    case stagingDiscardFailed, microphonePermissionDenied, sealOrDiscard
    case committedCleanup, sealed, discardOnly
}

private struct ScenarioEffect: Decodable, Sendable {
    let kind: ScenarioEffectKind
}

private enum ScenarioEffectKind: String, Decodable, Sendable {
    case captureStarted, liveLevelMeasured, muteCommandsAcknowledged
    case mutedLevelUnavailable, normalizedUnavailablePartition
    case gapLevelUnavailable, warningPersistsAfterBoundary
    case countdownUsesCeilingAtExactFrames, sessionSealedExactlyOnce
    case persistentDurationLimitExplanation, neverExceedsMaximumFrames
    case noPublicationBeforeCommittedReceipt, bothTerminalOrderingsDeterministic
    case twoTakesProduceTwoSeals, noDiscardCommand
    case timelineContinuesBehindConfirmation, discardedWithoutSeal
    case discardCommandSentOnce, discardFailureDoesNotClaimIdle
    case permissionFailurePublishesNothing, recoveryOffersSealAndDiscard
    case resumeAbsent, sameRecoveredSessionPublishedOnce, offerDiscardOnly
    case newRecordingAndSessionIdentity, firstSessionSealedOnce
    case lateEventsCannotMutateCompletion, librarySwitchBlockedWhileActive
}

private enum ScenarioTestError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case let .invalid(message): message
        }
    }
}

private enum StrictScenarioDecoder {
    static func decode(_ data: Data) throws -> RecordingScenario {
        let root = try object(try JSONSerialization.jsonObject(with: data), "root")
        try exactKeys(
            root,
            required: [
                "schemaVersion", "scenarioId", "initialState", "commands",
                "dependencyTrace", "expectedState", "expectedEffects",
            ],
            optional: [],
            at: "root"
        )
        try validateSnapshot(root["initialState"], at: "initialState")
        try validateSnapshot(root["expectedState"], at: "expectedState")

        let commands = try array(root["commands"], "commands")
        guard !commands.isEmpty else { throw ScenarioTestError.invalid("empty commands") }
        for (index, value) in commands.enumerated() {
            try exactKeys(
                try object(value, "commands[\(index)]"),
                required: ["kind"],
                optional: [],
                at: "commands[\(index)]"
            )
        }

        let trace = try array(root["dependencyTrace"], "dependencyTrace")
        for (index, value) in trace.enumerated() {
            try exactKeys(
                try object(value, "dependencyTrace[\(index)]"),
                required: ["port", "effect", "outcome", "afterCommand"],
                optional: ["frameCount", "level"],
                at: "dependencyTrace[\(index)]"
            )
        }

        let effects = try array(root["expectedEffects"], "expectedEffects")
        guard !effects.isEmpty else { throw ScenarioTestError.invalid("empty expectedEffects") }
        for (index, value) in effects.enumerated() {
            try exactKeys(
                try object(value, "expectedEffects[\(index)]"),
                required: ["kind"],
                optional: [],
                at: "expectedEffects[\(index)]"
            )
        }

        let decoded = try JSONDecoder().decode(RecordingScenario.self, from: data)
        guard decoded.schemaVersion == 1,
              decoded.scenarioId.hasPrefix("recording."),
              !decoded.scenarioId.contains("/")
        else { throw ScenarioTestError.invalid("invalid scenario envelope") }
        var previousCommand = 0
        for dependency in decoded.dependencyTrace {
            guard dependency.afterCommand >= previousCommand,
                  dependency.afterCommand < decoded.commands.count,
                  dependency.frameCount.map({ $0 <= CanonicalRecordingLimits.maximumFrames }) ?? true,
                  dependency.level.map({ (0...1).contains($0) }) ?? true
            else { throw ScenarioTestError.invalid("invalid dependency ordering or value") }
            previousCommand = dependency.afterCommand
        }
        return decoded
    }

    private static func validateSnapshot(_ value: Any?, at path: String) throws {
        try exactKeys(
            try object(value, path),
            required: ["kind"],
            optional: [
                "elapsedFrames", "mute", "limitPhase", "secondsRemaining",
                "confirmation", "terminalReason", "notice",
            ],
            at: path
        )
    }

    private static func object(_ value: Any?, _ path: String) throws -> [String: Any] {
        guard let value = value as? [String: Any] else {
            throw ScenarioTestError.invalid("\(path) is not an object")
        }
        return value
    }

    private static func array(_ value: Any?, _ path: String) throws -> [Any] {
        guard let value = value as? [Any] else {
            throw ScenarioTestError.invalid("\(path) is not an array")
        }
        return value
    }

    private static func exactKeys(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String>,
        at path: String
    ) throws {
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            throw ScenarioTestError.invalid("\(path) has non-schema keys: \(keys)")
        }
    }
}

private struct ExecutionEvidence {
    var normalizedUnavailablePartition = false
    var sawMutedUnavailable = false
    var sawGapUnavailable = false
    var noPublicationBeforeReceipt = false
    var ignoredLateEvents = 0
    var progressPhases: [(UInt64, RecordingLimitPhase)] = []
    var acceptedSealReasons: [CaptureTerminalReason] = []
}

private struct ScenarioExecutor {
    let scenario: RecordingScenario

    func run() async throws {
        let capture = StrictScriptedCapturePort(script: scenario.dependencyTrace)
        let ids = ScenarioIDs()
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: ScenarioClock(),
            idGenerator: ids,
            activity: LibraryActivityCoordinator()
        )
        let receipts = ReceiptCollector()
        var receiptIterator = feature.sealedSessions.makeAsyncIterator()
        let receiptTask = Task {
            while let receipt = await receiptIterator.next() {
                await receipts.append(receipt)
            }
        }
        defer { receiptTask.cancel() }

        let initialState = await feature.currentState
        try require(
            project(initialState) == scenario.initialState,
            "\(scenario.scenarioId): initial state mismatch"
        )
        var evidence = ExecutionEvidence()

        for (index, command) in scenario.commands.enumerated() {
            await capture.beginCommand(index)
            await feature.send(
                try featureCommand(command.kind, index: index)
            )
            while let dependency = await capture.takeDriverEvent(for: index) {
                try await drive(
                    dependency,
                    capture: capture,
                    feature: feature,
                    receipts: receipts,
                    evidence: &evidence
                )
            }
            await capture.finishCommand(index)
        }

        await feature.sealedSessions.waitUntilCurrentReceiptsAreObserved()
        let audit = await capture.audit
        try require(audit.violations.isEmpty, "\(scenario.scenarioId): \(audit.violations)")
        try require(audit.remaining == 0, "\(scenario.scenarioId): \(audit.remaining) trace events left")
        let finalState = await feature.currentState
        try require(
            project(finalState) == scenario.expectedState,
            "\(scenario.scenarioId): expected \(scenario.expectedState), got \(project(finalState))"
        )
        let sealed = await receipts.values
        try require(
            sealed.count == expectedReceiptCount,
            "\(scenario.scenarioId): expected \(expectedReceiptCount) sealed receipt(s), got \(sealed.count)"
        )
        try assertEffects(
            state: finalState,
            audit: audit,
            receipts: sealed,
            evidence: evidence
        )
    }

    private var expectedReceiptCount: Int {
        scenario.expectedEffects.reduce(into: 0) { count, effect in
            switch effect.kind {
            case .twoTakesProduceTwoSeals:
                count = max(count, 2)
            case .sessionSealedExactlyOnce, .sameRecoveredSessionPublishedOnce,
                 .firstSessionSealedOnce, .lateEventsCannotMutateCompletion:
                count = max(count, 1)
            case .captureStarted, .liveLevelMeasured, .muteCommandsAcknowledged,
                 .mutedLevelUnavailable, .normalizedUnavailablePartition,
                 .gapLevelUnavailable, .warningPersistsAfterBoundary,
                 .countdownUsesCeilingAtExactFrames,
                 .persistentDurationLimitExplanation, .neverExceedsMaximumFrames,
                 .noPublicationBeforeCommittedReceipt,
                 .bothTerminalOrderingsDeterministic, .noDiscardCommand,
                 .timelineContinuesBehindConfirmation, .discardedWithoutSeal,
                 .discardCommandSentOnce, .discardFailureDoesNotClaimIdle,
                 .permissionFailurePublishesNothing, .recoveryOffersSealAndDiscard,
                 .resumeAbsent, .offerDiscardOnly, .newRecordingAndSessionIdentity,
                 .librarySwitchBlockedWhileActive:
                break
            }
        }
    }

    private func featureCommand(
        _ kind: ScenarioCommandKind,
        index: Int
    ) throws -> RecordingCommand {
        switch kind {
        case .selectLibrary:
            return .selectLibrary(.writable(index == 0 ? try firstScope() : try secondScope()))
        case .record: return .record
        case .mute: return .setMuted(true)
        case .unmute: return .setMuted(false)
        case .stop: return .stop
        case .cancel: return .cancel
        case .keepRecording: return .keepRecording
        case .discardRecording: return .discardRecording
        case .sealRecovered: return .sealRecovered(try firstRecordingID())
        case .discardRecovered: return .discardRecovered(try firstRecordingID())
        }
    }

    private func drive(
        _ event: ScenarioDependency,
        capture: StrictScriptedCapturePort,
        feature: DefaultRecordingFeature,
        receipts: ReceiptCollector,
        evidence: inout ExecutionEvidence
    ) async throws {
        if event.effect == .normalizeUnavailableIntervals {
            let intervals = [
                try UnavailableInterval(
                    range: CanonicalFrameRange(startFrame: 1_000, endFrame: 3_000),
                    reasons: [.muted]
                ),
                try UnavailableInterval(
                    range: CanonicalFrameRange(startFrame: 2_000, endFrame: 4_000),
                    reasons: [.captureGap]
                ),
                try UnavailableInterval(
                    range: CanonicalFrameRange(startFrame: 4_000, endFrame: 4_800),
                    reasons: [.muted]
                ),
            ]
            let normalized = try UnavailableIntervalNormalizer.normalize(
                intervals,
                durationFrames: 4_800
            )
            let expected: [(UInt64, UInt64, Set<UnavailableReason>)] = [
                (1_000, 2_000, [.muted]),
                (2_000, 3_000, [.muted, .captureGap]),
                (3_000, 4_000, [.captureGap]),
                (4_000, 4_800, [.muted]),
            ]
            evidence.normalizedUnavailablePartition = normalized.count == expected.count &&
                zip(normalized, expected).allSatisfy { actual, expected in
                    actual.range.startFrame == expected.0 &&
                        actual.range.endFrame == expected.1 &&
                        actual.reasons == expected.2
                }
            return
        }

        let before = await feature.currentState
        let receiptCountBefore = await receipts.values.count
        let observation = try await capture.observation(for: event)
        await capture.emit(observation)

        if case .completed = before {
            try await settle()
            let after = await feature.currentState
            let receiptCountAfter = await receipts.values.count
            try require(after == before, "late event mutated completion")
            try require(receiptCountAfter == receiptCountBefore, "late event republished")
            evidence.ignoredLateEvents += 1
            return
        }

        switch event.effect {
        case .progress:
            let frame = try requiredFrame(event)
            try await eventually {
                currentSnapshot(await feature.currentState)?.elapsedFrames == frame
            }
            let state = await feature.currentState
            if let snapshot = currentSnapshot(state) {
                evidence.progressPhases.append((frame, snapshot.limitPhase))
                if snapshot.level == .unavailable(.muted) { evidence.sawMutedUnavailable = true }
                if snapshot.level == .unavailable(.captureGap) { evidence.sawGapUnavailable = true }
            }
        case .muteChanged:
            let muted = event.outcome == .muted
            try await eventually {
                guard case let .active(snapshot, _) = await feature.currentState else { return false }
                return snapshot.mute == (muted ? .muted : .live)
            }
        case .finishing:
            let reason = try terminalReason(event.outcome)
            try await eventually {
                guard case let .finishing(_, actual) = await feature.currentState else { return false }
                return actual == reason
            }
        case .sealing:
            let reason = try terminalReason(event.outcome)
            try await eventually {
                guard case let .sealing(_, actual) = await feature.currentState else { return false }
                return actual == reason
            }
            evidence.noPublicationBeforeReceipt = await receipts.values.count == evidence.acceptedSealReasons.count
        case .sealed:
            let reason = try terminalReason(event.outcome)
            try await eventually {
                if case .completed = await feature.currentState { return true }
                return false
            }
            try await eventually { await receipts.values.count == receiptCountBefore + 1 }
            evidence.acceptedSealReasons.append(reason)
        case .discarded:
            try await eventually { await feature.currentState == .idle }
        case .recoveryRequired:
            try await eventually {
                if case .recoveryRequired = await feature.currentState { return true }
                return false
            }
        case .normalizeUnavailableIntervals:
            break
        case .inspectRecovery, .begin, .setMuted, .stop, .discardConfirmed, .resolveSeal:
            throw ScenarioTestError.invalid("port call escaped into driver")
        }
    }

    private func assertEffects(
        state: RecordingFeatureState,
        audit: ScriptAudit,
        receipts: [SessionSealedReceipt],
        evidence: ExecutionEvidence
    ) throws {
        for effect in scenario.expectedEffects.map(\.kind) {
            switch effect {
            case .captureStarted:
                try require(audit.requests.count == 1, "capture did not start once")
            case .liveLevelMeasured:
                try require(currentSnapshot(state)?.level == .measured(0.625), "live level was not measured")
            case .muteCommandsAcknowledged:
                try require(audit.commands == [.setMuted(true), .setMuted(false)], "mute trace mismatch")
            case .mutedLevelUnavailable:
                try require(evidence.sawMutedUnavailable, "muted level was numeric")
            case .normalizedUnavailablePartition:
                try require(evidence.normalizedUnavailablePartition, "interval partition mismatch")
            case .gapLevelUnavailable:
                try require(evidence.sawGapUnavailable, "gap level was numeric")
            case .warningPersistsAfterBoundary:
                let phases = evidence.progressPhases.filter { $0.0 >= 38_400_000 }.map(\.1)
                try require(phases.allSatisfy { $0 == .fiveMinuteWarning }, "warning regressed")
            case .countdownUsesCeilingAtExactFrames:
                try require(
                    evidence.progressPhases.contains { $0 == (42_240_000, .oneMinuteCountdown(secondsRemaining: 60)) } &&
                        evidence.progressPhases.contains { $0 == (42_240_001, .oneMinuteCountdown(secondsRemaining: 60)) } &&
                        evidence.progressPhases.contains { $0 == (43_199_999, .oneMinuteCountdown(secondsRemaining: 1)) },
                    "countdown rounding mismatch"
                )
            case .sessionSealedExactlyOnce:
                try require(receipts.count == 1, "expected exactly one seal")
            case .persistentDurationLimitExplanation:
                guard case let .completed(_, notice) = state else { throw ScenarioTestError.invalid("not completed") }
                try require(notice == .durationLimit, "duration notice missing")
            case .neverExceedsMaximumFrames:
                try require(evidence.progressPhases.allSatisfy { $0.0 <= 43_200_000 }, "frame cap exceeded")
            case .noPublicationBeforeCommittedReceipt:
                try require(evidence.noPublicationBeforeReceipt, "published before sealed receipt")
            case .bothTerminalOrderingsDeterministic:
                try require(evidence.acceptedSealReasons == [.userStop, .durationLimit], "terminal authority mismatch")
            case .twoTakesProduceTwoSeals:
                try require(receipts.count == 2, "race fixture did not seal two takes")
            case .noDiscardCommand:
                try require(!audit.commands.contains(.discardConfirmed), "Cancel discarded implicitly")
            case .timelineContinuesBehindConfirmation:
                try require(currentSnapshot(state)?.elapsedFrames == 32_000, "timeline paused behind confirmation")
            case .discardedWithoutSeal:
                try require(state == .idle && receipts.isEmpty, "discard published a Session")
            case .discardCommandSentOnce:
                try require(audit.commands.filter { $0 == .discardConfirmed }.count == 1, "discard count mismatch")
            case .discardFailureDoesNotClaimIdle:
                guard case let .active(_, confirmation) = state else { throw ScenarioTestError.invalid("discard failure hid capture") }
                try require(confirmation == .discardRecording, "retry confirmation missing")
            case .permissionFailurePublishesNothing:
                try require(state == .failed(.microphonePermissionDenied) && receipts.isEmpty, "start failure was dishonest")
            case .recoveryOffersSealAndDiscard:
                try require(recoveryAvailability(state) == .sealOrDiscard, "recovery actions mismatch")
            case .resumeAbsent:
                try require(!scenario.commands.map(\.kind).contains { $0.rawValue == "resume" }, "Resume leaked")
            case .sameRecoveredSessionPublishedOnce:
                try require(receipts.count == 1 && audit.resolutions == [.seal], "recovery seal was not idempotent")
            case .offerDiscardOnly:
                try require(recoveryAvailability(state) == .discardOnly, "unsealable recovery offered Seal")
            case .newRecordingAndSessionIdentity:
                try require(
                    audit.requests.count == 2 &&
                        audit.requests[0].recordingID != audit.requests[1].recordingID &&
                        audit.requests[0].sessionID != audit.requests[1].sessionID,
                    "second take reused identity"
                )
            case .firstSessionSealedOnce:
                try require(receipts.count == 1, "first take publication mismatch")
            case .lateEventsCannotMutateCompletion:
                try require(evidence.ignoredLateEvents == 3 && receipts.count == 1, "late events escaped fencing")
            case .librarySwitchBlockedWhileActive:
                let expectedScope = try firstScope()
                try require(
                    audit.requests.count == 1 && audit.requests[0].libraryScope == expectedScope,
                    "capture crossed Library scope"
                )
            }
        }
    }
}

private struct ScriptAudit: Sendable {
    let violations: [String]
    let remaining: Int
    let requests: [MicrophoneRecordingRequest]
    let commands: [ActiveCaptureCommand]
    let resolutions: [RecordingRecoveryAction]
}

private actor StrictScriptedCapturePort: AudioCapturePort {
    private let script: [ScenarioDependency]
    private var cursor = 0
    private var commandIndex = -1
    private var violations: [String] = []
    private var continuation: AsyncStream<CaptureObservation>.Continuation?
    private(set) var requests: [MicrophoneRecordingRequest] = []
    private(set) var commands: [ActiveCaptureCommand] = []
    private(set) var resolutions: [RecordingRecoveryAction] = []

    init(script: [ScenarioDependency]) { self.script = script }

    func beginCommand(_ index: Int) { commandIndex = index }

    func finishCommand(_ index: Int) {
        if cursor < script.count, script[cursor].afterCommand == index {
            violations.append("unconsumed event \(script[cursor].effect.rawValue) after command \(index)")
        }
    }

    func takeDriverEvent(for index: Int) -> ScenarioDependency? {
        guard cursor < script.count, script[cursor].afterCommand == index else { return nil }
        let event = script[cursor]
        let calls: Set<ScenarioDependencyEffect> = [
            .inspectRecovery, .begin, .setMuted, .stop, .discardConfirmed, .resolveSeal,
        ]
        guard !calls.contains(event.effect) else { return nil }
        cursor += 1
        return event
    }

    var audit: ScriptAudit {
        ScriptAudit(
            violations: violations,
            remaining: script.count - cursor,
            requests: requests,
            commands: commands,
            resolutions: resolutions
        )
    }

    func begin(_ request: MicrophoneRecordingRequest) -> CaptureStartOutcome {
        guard let event = consumeCall(.begin) else { return .rejected(.staleCommand) }
        requests.append(request)
        switch event.outcome {
        case .started:
            let pair = AsyncStream<CaptureObservation>.makeStream()
            continuation = pair.continuation
            return .started(ActiveCaptureFeed(recordingID: request.recordingID, observations: pair.stream))
        case .microphonePermissionDenied:
            return .rejected(.microphonePermissionDenied)
        default:
            violations.append("unsupported begin outcome \(event.outcome.rawValue)")
            return .rejected(.staleCommand)
        }
    }

    func apply(
        _ command: ActiveCaptureCommand,
        to recordingID: RecordingID
    ) -> CaptureCommandOutcome {
        commands.append(command)
        let effect: ScenarioDependencyEffect
        switch command {
        case .setMuted: effect = .setMuted
        case .stop: effect = .stop
        case .discardConfirmed: effect = .discardConfirmed
        }
        guard let event = consumeCall(effect) else { return .rejected(.staleCommand) }
        return event.outcome == .accepted
            ? .accepted
            : .rejected(.stagingDiscardFailed)
    }

    func completeSeal(
        _ command: RecordingPublicationCommand
    ) -> RecordingPublicationOutcome {
        guard case let .publish(publication) = command else {
            return .failed(.sealValidationFailedRecoverable)
        }
        return .installed(publication.receipt)
    }

    func inspectRecovery(in library: LibraryScope) -> RecordingRecoveryCatalog {
        guard let event = consumeCall(.inspectRecovery) else {
            return RecordingRecoveryCatalog(items: [])
        }
        let availability: RecordingRecoveryAvailability?
        switch event.outcome {
        case .sealOrDiscard: availability = .sealOrDiscard
        case .discardOnly: availability = .discardOnly
        case .committedCleanup: availability = .committedCleanup
        case .none: availability = nil
        default:
            violations.append("unsupported inspection outcome \(event.outcome.rawValue)")
            availability = nil
        }
        guard let availability else { return RecordingRecoveryCatalog(items: []) }
        return RecordingRecoveryCatalog(items: [recoveryItem(availability, frameCount: event.frameCount)])
    }

    func resolveRecovery(
        _ action: RecordingRecoveryAction,
        recordingID: RecordingID,
        in library: LibraryScope
    ) -> RecordingRecoveryOutcome {
        resolutions.append(action)
        guard let event = consumeCall(.resolveSeal), action == .seal else {
            return .failed(.staleCommand)
        }
        guard event.outcome == .sealed else { return .failed(.sealValidationFailedRecoverable) }
        let request = MicrophoneRecordingRequest(
            libraryScope: library,
            recordingID: recordingID,
            sessionID: try! firstSessionID(),
            startedAt: try! UTCInstant("2026-08-30T12:00:00.000Z")
        )
        return .sealCandidate(
            stagedCandidate(
                request: request,
                frameCount: event.frameCount ?? 16_000,
                terminalReason: .interruption
            )
        )
    }

    func observation(for event: ScenarioDependency) throws -> CaptureObservation {
        let frame = event.frameCount ?? 0
        switch event.effect {
        case .progress:
            let level: CaptureLevel
            switch event.outcome {
            case .measured: level = .measured(event.level ?? 0)
            case .muted: level = .unavailable(.muted)
            case .captureGap: level = .unavailable(.captureGap)
            default: throw ScenarioTestError.invalid("unsupported progress outcome")
            }
            return .progress(frameCount: frame, level: level)
        case .muteChanged:
            return .muteChanged(isMuted: event.outcome == .muted, effectiveFrame: frame)
        case .finishing:
            return .finishing(reason: try terminalReason(event.outcome), frameCount: frame)
        case .sealing:
            return .sealing(reason: try terminalReason(event.outcome), frameCount: frame)
        case .sealed:
            guard let request = requests.last else { throw ScenarioTestError.invalid("seal before begin") }
            return .sealCandidate(
                stagedCandidate(
                    request: request,
                    frameCount: frame,
                    terminalReason: try terminalReason(event.outcome)
                )
            )
        case .discarded:
            guard let request = requests.last else { throw ScenarioTestError.invalid("discard before begin") }
            return .discarded(recordingID: request.recordingID)
        case .recoveryRequired:
            return .recoveryRequired(recoveryItem(.sealOrDiscard, frameCount: event.frameCount))
        default:
            throw ScenarioTestError.invalid("\(event.effect.rawValue) is not an observation")
        }
    }

    func emit(_ observation: CaptureObservation) { continuation?.yield(observation) }

    private func consumeCall(_ effect: ScenarioDependencyEffect) -> ScenarioDependency? {
        guard cursor < script.count else {
            violations.append("unexpected \(effect.rawValue) after trace end")
            return nil
        }
        let event = script[cursor]
        guard event.afterCommand == commandIndex,
              event.port == .audioCapture,
              event.effect == effect
        else {
            violations.append(
                "expected \(event.effect.rawValue)@\(event.afterCommand), got \(effect.rawValue)@\(commandIndex)"
            )
            return nil
        }
        cursor += 1
        return event
    }
}

private actor ScenarioIDs: RecordingIDGenerator {
    private var recordings = [
        try! RecordingID("rec-20260830T120000000Z-2ABC"),
        try! RecordingID("rec-20260830T120001000Z-2ABD"),
        try! RecordingID("rec-20260830T120002000Z-2ABE"),
    ]
    private var sessions = [
        try! SessionID("ses-20260830T120000000Z-3DEF"),
        try! SessionID("ses-20260830T120001000Z-3DEG"),
        try! SessionID("ses-20260830T120002000Z-3DEH"),
    ]

    func generateRecordingID(at instant: UTCInstant) -> RecordingID { recordings.removeFirst() }
    func generateSessionID(at instant: UTCInstant) -> SessionID { sessions.removeFirst() }
}

private struct ScenarioClock: RecordingClock {
    func now() async -> UTCInstant { try! UTCInstant("2026-08-30T12:00:00.000Z") }
}

private actor ReceiptCollector {
    private(set) var values: [SessionSealedReceipt] = []
    func append(_ receipt: SessionSealedReceipt) { values.append(receipt) }
}

private func recoveryItem(
    _ availability: RecordingRecoveryAvailability,
    frameCount: UInt64?
) -> RecordingRecoveryItem {
    RecordingRecoveryItem(
        recordingID: try! firstRecordingID(),
        sessionID: try! firstSessionID(),
        startedAt: try! UTCInstant("2026-08-30T12:00:00.000Z"),
        durableFrameCount: frameCount ?? 16_000,
        availability: availability
    )
}

private func receipt(
    recordingID: RecordingID,
    sessionID: SessionID? = nil,
    frameCount: UInt64
) -> SessionSealedReceipt {
    SessionSealedReceipt(
        libraryID: try! firstScope().libraryID,
        recordingID: recordingID,
        sessionID: sessionID ?? (try! firstSessionID()),
        frameCount: frameCount,
        fingerprint: try! AudioFingerprint(sha256: String(repeating: "a", count: 64))
    )
}

private func stagedCandidate(
    request: MicrophoneRecordingRequest,
    frameCount: UInt64,
    terminalReason: CaptureTerminalReason
) -> StagedRecordingSealCandidate {
    StagedRecordingSealCandidate(
        recordingID: request.recordingID.rawValue,
        sessionID: request.sessionID.rawValue,
        libraryID: request.libraryScope.libraryID.rawValue,
        startedAt: request.startedAt.rawValue,
        terminalReason: terminalReason.rawValue,
        sourceKind: "microphone",
        canonicalAudioPath: "audio/audio.wav",
        sampleRateHz: 16_000,
        channelCount: 1,
        encoding: "pcmS16LE",
        frameCount: frameCount,
        canonicalSHA256: String(repeating: "a", count: 64),
        unavailableIntervals: []
    )
}

private func terminalReason(
    _ outcome: ScenarioDependencyOutcome
) throws -> CaptureTerminalReason {
    switch outcome {
    case .userStop: .userStop
    case .durationLimit: .durationLimit
    default: throw ScenarioTestError.invalid("not a terminal reason: \(outcome.rawValue)")
    }
}

private func project(_ state: RecordingFeatureState) -> ScenarioSnapshot {
    switch state {
    case .unavailable:
        ScenarioSnapshot(kind: .unavailable)
    case .selectingLibrary:
        ScenarioSnapshot(kind: .selectingLibrary)
    case .idle:
        ScenarioSnapshot(kind: .idle)
    case .starting:
        ScenarioSnapshot(kind: .starting)
    case let .active(snapshot, confirmation):
        ScenarioSnapshot(snapshot: snapshot, kind: .active, confirmation: confirmation)
    case let .finishing(snapshot, reason):
        ScenarioSnapshot(snapshot: snapshot, kind: .finishing, terminalReason: reason)
    case let .sealing(snapshot, reason):
        ScenarioSnapshot(snapshot: snapshot, kind: .sealing, terminalReason: reason)
    case .recoveryRequired:
        ScenarioSnapshot(kind: .recoveryRequired)
    case .resolvingRecovery:
        ScenarioSnapshot(kind: .resolvingRecovery)
    case let .completed(_, notice):
        ScenarioSnapshot(kind: .completed, notice: notice.map { _ in .durationLimit })
    case .failed:
        ScenarioSnapshot(kind: .failed)
    }
}

private extension ScenarioSnapshot {
    init(
        kind: ScenarioStateKind,
        notice: ScenarioNotice? = nil
    ) {
        self.init(
            kind: kind,
            elapsedFrames: nil,
            mute: nil,
            limitPhase: nil,
            secondsRemaining: nil,
            confirmation: nil,
            terminalReason: nil,
            notice: notice
        )
    }

    init(
        snapshot: RecordingSnapshot,
        kind: ScenarioStateKind,
        confirmation: RecordingConfirmation? = nil,
        terminalReason: CaptureTerminalReason? = nil
    ) {
        let mute: ScenarioMute = switch snapshot.mute {
        case .live: .live
        case .muted: .muted
        case .changing(true): .muting
        case .changing(false): .unmuting
        }
        let (phase, seconds): (ScenarioLimitPhase, UInt8?) = switch snapshot.limitPhase {
        case .ordinary: (.ordinary, nil)
        case .fiveMinuteWarning: (.fiveMinuteWarning, nil)
        case let .oneMinuteCountdown(value): (.oneMinuteCountdown, value)
        case .automaticStop: (.automaticStop, nil)
        }
        self.init(
            kind: kind,
            elapsedFrames: snapshot.elapsedFrames,
            mute: mute,
            limitPhase: phase,
            secondsRemaining: seconds,
            confirmation: confirmation.map {
                $0 == .none ? .none : .discardRecording
            },
            terminalReason: terminalReason.map {
                ScenarioTerminalReason(rawValue: $0.rawValue)!
            },
            notice: nil
        )
    }
}

private func currentSnapshot(_ state: RecordingFeatureState) -> RecordingSnapshot? {
    switch state {
    case let .active(snapshot, _), let .finishing(snapshot, _), let .sealing(snapshot, _):
        snapshot
    default:
        nil
    }
}

private func recoveryAvailability(
    _ state: RecordingFeatureState
) -> RecordingRecoveryAvailability? {
    guard case let .recoveryRequired(catalog) = state else { return nil }
    return catalog.items.first?.availability
}

private func requiredFrame(_ event: ScenarioDependency) throws -> UInt64 {
    guard let frame = event.frameCount else {
        throw ScenarioTestError.invalid("\(event.effect.rawValue) is missing frameCount")
    }
    return frame
}

private func firstScope() throws -> LibraryScope {
    LibraryScope(libraryID: try LibraryID("lib-20260830T120000000Z-1ABC"))
}

private func secondScope() throws -> LibraryScope {
    LibraryScope(libraryID: try LibraryID("lib-20260830T120001000Z-1ABD"))
}

private func firstRecordingID() throws -> RecordingID {
    try RecordingID("rec-20260830T120000000Z-2ABC")
}

private func firstSessionID() throws -> SessionID {
    try SessionID("ses-20260830T120000000Z-3DEF")
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ScenarioTestError.invalid(message) }
}

private func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<2_000 {
        if await condition() { return }
        await Task.yield()
    }
    throw ScenarioTestError.invalid("asynchronous scenario transition timed out")
}

private func settle() async throws {
    for _ in 0..<20 { await Task.yield() }
}
