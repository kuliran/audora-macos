import AudoraContracts
import Foundation
import XCTest

final class ContractResourcesTests: XCTestCase {
    func testEveryContractResourceLoadsFromThePackageBundle() throws {
        for resource in ContractResource.allCases {
            let data = try ContractResources.data(for: resource)
            XCTAssertFalse(data.isEmpty, resource.rawValue)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        }
    }

    func testPortableGoldenRootsContainNoMachineLocalAuthority() throws {
        let resources: [ContractResource] = [
            .portableLibraryManifestExample,
            .portableLibraryPreferencesExample,
            .portableProfileNullExample,
            .portableProfileSelectedExample,
        ]
        let forbidden = [
            "bookmark", "absolutePath", "modelPath", "cachePath", "credential",
            "permissionGrant", "hardwareId",
        ]

        for resource in resources {
            let data = try ContractResources.data(for: resource)
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            for field in forbidden {
                XCTAssertFalse(text.contains(field), "\(resource.rawValue): \(field)")
            }
        }
    }

    func testProfileHeadSchemaIsASealedNullOrSelectedStructuralUnion() throws {
        let data = try ContractResources.data(for: .profileHeadSchema)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(object["anyOf"])
        let serialized = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(serialized.contains("NullProfileHead"))
        XCTAssertTrue(serialized.contains("SelectedProfileHead"))
        XCTAssertTrue(serialized.contains("unevaluatedProperties"))
    }

    func testRecordingPortableRootsContainNoMachineLocalOrPermissionAuthority() throws {
        let resources: [ContractResource] = [
            .recordingSessionExample,
            .recordingAudioExample,
            .recordingMaximumDurationAudioExample,
            .recordingCapturingExample,
            .recordingRecoverableExample,
            .recordingDiscardOnlyExample,
            .recordingCommittedExample,
        ]
        let forbidden = [
            "bookmark", "absolutePath", "deviceId", "hardwareId", "permission",
            "authorization", "modelPath", "credential", "cachePath",
        ]
        for resource in resources {
            let data = try ContractResources.data(for: resource)
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            for field in forbidden {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(field), resource.rawValue)
            }
        }
    }

    func testRecordingSchemasSealCanonicalFormatAndAggregateReferences() throws {
        let audio = try XCTUnwrap(
            String(
                data: ContractResources.data(for: .audioManifestSchema),
                encoding: .utf8
            )
        )
        XCTAssertTrue(audio.contains(#""const": "pcmS16LE""#))
        XCTAssertTrue(audio.contains(#""const": 16000"#))
        XCTAssertTrue(audio.contains(#""const": 1"#))
        XCTAssertTrue(audio.contains(#""const": "audio/audio.wav""#))
        XCTAssertTrue(audio.contains("unevaluatedProperties"))

        let session = try XCTUnwrap(
            String(
                data: ContractResources.data(for: .sessionManifestSchema),
                encoding: .utf8
            )
        )
        XCTAssertTrue(session.contains(#""const": "audio/audio.json""#))
        XCTAssertTrue(session.contains("unevaluatedProperties"))
    }

    func testRecordingGoldensUseCanonicalRelativeReferencesAndHalfOpenIntervals() throws {
        let audioData = try ContractResources.data(for: .recordingAudioExample)
        let audio = try XCTUnwrap(
            JSONSerialization.jsonObject(with: audioData) as? [String: Any]
        )
        XCTAssertEqual(audio["canonicalAudioPath"] as? String, "audio/audio.wav")
        XCTAssertEqual(audio["frameCount"] as? Int, 16_000)
        let intervals = try XCTUnwrap(audio["unavailableIntervals"] as? [[String: Any]])
        XCTAssertEqual(intervals.count, 3)
        XCTAssertEqual(intervals[0]["startFrame"] as? Int, 1_600)
        XCTAssertEqual(intervals[0]["endFrame"] as? Int, 3_000)
        XCTAssertEqual(intervals[1]["startFrame"] as? Int, 3_000)
        XCTAssertEqual(intervals[1]["endFrame"] as? Int, 3_200)

        let sessionData = try ContractResources.data(for: .recordingSessionExample)
        let session = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sessionData) as? [String: Any]
        )
        XCTAssertEqual(session["audioManifestPath"] as? String, "audio/audio.json")
        XCTAssertFalse((session["sessionId"] as? String ?? "").contains("/"))
    }

    func testRecordingScenarioSchemaClosesEffectsOutcomesNoticesAndInventoryKeys() throws {
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ContractResources.data(for: .recordingFeatureScenarioSchema)
            ) as? [String: Any]
        )
        let definitions = try XCTUnwrap(root["$defs"] as? [String: Any])
        let rootProperties = try XCTUnwrap(root["properties"] as? [String: Any])
        XCTAssertEqual(
            (rootProperties["commands"] as? [String: Any])?["minItems"] as? Int,
            1
        )
        XCTAssertEqual(
            (rootProperties["expectedEffects"] as? [String: Any])?["minItems"] as? Int,
            1
        )
        XCTAssertEqual(
            (definitions["RecordingScenarioId"] as? [String: Any])?["pattern"] as? String,
            #"^recording\.[a-z0-9]+(?:-[a-z0-9]+)*$"#
        )
        let dependencyVariants = try unionReferences(
            "RecordingScenarioDependencyEvent",
            in: definitions
        )
        XCTAssertEqual(dependencyVariants.count, 17)
        let dependencyProperties = try dependencyVariants.map {
            try schemaProperties($0, in: definitions)
        }
        XCTAssertEqual(
            Set(dependencyProperties.flatMap { literalValues(in: $0["effect"]) }),
            [
                "inspectRecovery", "begin", "progress", "setMuted", "muteChanged",
                "normalizeUnavailableIntervals", "finishing", "sealing", "sealed",
                "stop", "discardConfirmed", "discarded", "recoveryRequired", "resolveSeal",
            ]
        )
        XCTAssertEqual(
            Set(dependencyProperties.flatMap { literalValues(in: $0["outcome"]) }),
            [
                "none", "started", "measured", "accepted", "muted", "live",
                "captureGap", "mutedGapOverlap", "durationLimit", "userStop",
                "discarded", "stagingDiscardFailed", "microphonePermissionDenied",
                "sealOrDiscard", "committedCleanup", "sealed", "discardOnly",
            ]
        )
        let required = try XCTUnwrap(
            (definitions["RecordingScenarioDependencyBase"] as? [String: Any])?["required"]
                as? [String]
        )
        XCTAssertTrue(required.contains("afterCommand"))
        let measured = try schemaProperties(
            "RecordingMeasuredProgressDependency",
            in: definitions
        )
        XCTAssertEqual((measured["level"] as? [String: Any])?["minimum"] as? Int, 0)
        XCTAssertEqual((measured["level"] as? [String: Any])?["maximum"] as? Int, 1)

        let effect = try schemaProperties("RecordingScenarioEffect", in: definitions)
        XCTAssertEqual(constants(in: effect["kind"]), scenarioEffectVocabulary)

        let snapshotVariants = try unionReferences(
            "RecordingScenarioSnapshot",
            in: definitions
        )
        XCTAssertTrue(snapshotVariants.contains("RecordingScenarioSelectingLibrarySnapshot"))
        XCTAssertTrue(snapshotVariants.contains("RecordingScenarioResolvingRecoverySnapshot"))
        let completed = try schemaProperties(
            "RecordingScenarioCompletedSnapshot",
            in: definitions
        )
        XCTAssertEqual(
            (completed["notice"] as? [String: Any])?["const"] as? String,
            "durationLimit"
        )
        let countdown = try schemaProperties(
            "RecordingScenarioActiveCountdownSnapshot",
            in: definitions
        )
        XCTAssertEqual(
            (countdown["secondsRemaining"] as? [String: Any])?["minimum"] as? Int,
            1
        )
        XCTAssertEqual(
            (countdown["secondsRemaining"] as? [String: Any])?["maximum"] as? Int,
            60
        )
    }

    private func schemaProperties(
        _ name: String,
        in definitions: [String: Any]
    ) throws -> [String: Any] {
        try XCTUnwrap((definitions[name] as? [String: Any])?["properties"] as? [String: Any])
    }

    private func unionReferences(
        _ name: String,
        in definitions: [String: Any]
    ) throws -> [String] {
        let variants = try XCTUnwrap(
            (definitions[name] as? [String: Any])?["anyOf"] as? [[String: Any]]
        )
        return try variants.map { variant in
            let reference = try XCTUnwrap(variant["$ref"] as? String)
            return String(reference.dropFirst("#/$defs/".count))
        }
    }

    private func constants(in schema: Any?) -> Set<String> {
        guard let variants = (schema as? [String: Any])?["anyOf"] as? [[String: Any]] else {
            return []
        }
        return Set(variants.compactMap { $0["const"] as? String })
    }

    private func literalValues(in schema: Any?) -> Set<String> {
        if let literal = (schema as? [String: Any])?["const"] as? String {
            return [literal]
        }
        return constants(in: schema)
    }
}

private let scenarioEffectVocabulary: Set<String> = [
    "captureStarted", "liveLevelMeasured", "muteCommandsAcknowledged",
    "mutedLevelUnavailable", "normalizedUnavailablePartition", "gapLevelUnavailable",
    "warningPersistsAfterBoundary", "countdownUsesCeilingAtExactFrames",
    "sessionSealedExactlyOnce", "persistentDurationLimitExplanation",
    "neverExceedsMaximumFrames", "noPublicationBeforeCommittedReceipt",
    "bothTerminalOrderingsDeterministic", "twoTakesProduceTwoSeals",
    "noDiscardCommand", "timelineContinuesBehindConfirmation", "discardedWithoutSeal",
    "discardCommandSentOnce", "discardFailureDoesNotClaimIdle",
    "permissionFailurePublishesNothing", "recoveryOffersSealAndDiscard", "resumeAbsent",
    "sameRecoveredSessionPublishedOnce", "offerDiscardOnly",
    "newRecordingAndSessionIdentity", "firstSessionSealedOnce",
    "lateEventsCannotMutateCompletion", "librarySwitchBlockedWhileActive",
]
