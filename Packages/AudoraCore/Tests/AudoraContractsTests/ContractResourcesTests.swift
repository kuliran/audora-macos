import AudoraContracts
import AudoraDomain
import Foundation
import XCTest

final class ContractResourcesTests: XCTestCase {
    func testEveryContractResourceLoadsFromItsQualifiedPackagePath() throws {
        let resources = ContractResource.allCases
        XCTAssertEqual(Set(resources.map(\.bundlePath)).count, resources.count)

        for resource in resources {
            let data = try ContractResources.data(for: resource)
            XCTAssertFalse(data.isEmpty, resource.bundlePath)
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: data),
                resource.bundlePath
            )
        }
    }

    func testCoachContextQuoteLocksMessageLimitAndAllExplanatoryCategories() throws {
        let quote = try jsonObject(.coachContextQuoteExample)
        XCTAssertEqual(quote["maximumUserMessageUtf8Bytes"] as? Int, 16_384)
        XCTAssertEqual(quote["completeInputTokens"] as? Int, 642)
        XCTAssertEqual(quote["inputCeilingTokens"] as? Int, 4_032)
        let costs = try XCTUnwrap(quote["categoryCosts"] as? [[String: Any]])
        XCTAssertEqual(
            Set(costs.compactMap { $0["category"] as? String }),
            Set([
                "profile", "memory", "history", "draft", "framing", "attachments",
                "transcriptExchange", "responseReserve", "safetyMargin",
            ])
        )
        XCTAssertEqual(costs.count, 9)

        let schema = try jsonObject(.coachContextQuoteSchema)
        let serialized = try JSONSerialization.data(
            withJSONObject: schema,
            options: [.sortedKeys]
        )
        let text = try XCTUnwrap(String(data: serialized, encoding: .utf8))
        XCTAssertTrue(text.contains("16384"))
        XCTAssertFalse(text.contains("CanonicalCoachExchange"))
        XCTAssertFalse(text.contains("modelInputFrames"))
    }

    func testSameBasenameImportAndRecordingResourcesStayDistinct() throws {
        XCTAssertEqual(
            ContractResource.importedAudioManifestExample.rawValue,
            ContractResource.recordingAudioExample.rawValue
        )
        XCTAssertNotEqual(
            ContractResource.importedAudioManifestExample.bundlePath,
            ContractResource.recordingAudioExample.bundlePath
        )
        XCTAssertEqual(
            ContractResource.importedSessionManifestExample.rawValue,
            ContractResource.recordingSessionExample.rawValue
        )
        XCTAssertNotEqual(
            ContractResource.importedSessionManifestExample.bundlePath,
            ContractResource.recordingSessionExample.bundlePath
        )

        let importedAudio = try jsonObject(.importedAudioManifestExample)
        let recordedAudio = try jsonObject(.recordingAudioExample)
        XCTAssertEqual(importedAudio["acquisitionKind"] as? String, "imported")
        XCTAssertNil(importedAudio["sourceKind"])
        XCTAssertEqual(recordedAudio["sourceKind"] as? String, "microphone")
        XCTAssertNil(recordedAudio["acquisitionKind"])

        let importedSession = try jsonObject(.importedSessionManifestExample)
        let recordedSession = try jsonObject(.recordingSessionExample)
        XCTAssertNotNil(importedSession["audioManifestSha256"])
        XCTAssertNil(importedSession["audioManifestPath"])
        XCTAssertEqual(
            recordedSession["audioManifestPath"] as? String,
            "audio/audio.json"
        )
        XCTAssertNil(recordedSession["audioManifestSha256"])
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
                XCTAssertFalse(text.contains(field), "\(resource.bundlePath): \(field)")
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

    func testAudioAndSessionSchemasExposeOnlyTheFourClosedVariants() throws {
        let audioRoot = try jsonObject(.audioManifestSchema)
        let audioDefinitions = try XCTUnwrap(audioRoot["$defs"] as? [String: Any])
        XCTAssertEqual(
            try rootUnionReferences(in: audioRoot),
            ["ImportedAudioManifest", "MicrophoneAudioManifest"]
        )
        for name in ["ImportedAudioManifest", "MicrophoneAudioManifest"] {
            let schema = try XCTUnwrap(audioDefinitions[name] as? [String: Any])
            XCTAssertNotNil(schema["unevaluatedProperties"], name)
        }
        let importedAudioProperties = try schemaProperties(
            "ImportedAudioManifest",
            in: audioDefinitions
        )
        let microphoneAudioProperties = try schemaProperties(
            "MicrophoneAudioManifest",
            in: audioDefinitions
        )
        XCTAssertNotNil(importedAudioProperties["acquisitionKind"])
        XCTAssertNil(importedAudioProperties["sourceKind"])
        XCTAssertNotNil(microphoneAudioProperties["sourceKind"])
        XCTAssertNil(microphoneAudioProperties["acquisitionKind"])

        let sessionRoot = try jsonObject(.sessionManifestSchema)
        let sessionDefinitions = try XCTUnwrap(sessionRoot["$defs"] as? [String: Any])
        XCTAssertEqual(
            try rootUnionReferences(in: sessionRoot),
            ["ImportedSessionManifest", "RecordedSessionManifest"]
        )
        for name in ["ImportedSessionManifest", "RecordedSessionManifest"] {
            let schema = try XCTUnwrap(sessionDefinitions[name] as? [String: Any])
            XCTAssertNotNil(schema["unevaluatedProperties"], name)
        }
        let importedSessionProperties = try schemaProperties(
            "ImportedSessionManifest",
            in: sessionDefinitions
        )
        let recordedSessionProperties = try schemaProperties(
            "RecordedSessionManifest",
            in: sessionDefinitions
        )
        XCTAssertNotNil(importedSessionProperties["audioManifestSha256"])
        XCTAssertNil(importedSessionProperties["audioManifestPath"])
        XCTAssertNotNil(recordedSessionProperties["audioManifestPath"])
        XCTAssertNil(recordedSessionProperties["audioManifestSha256"])
        for properties in [importedSessionProperties, recordedSessionProperties] {
            XCTAssertNotNil(properties["transcriptRevisionIds"])
            XCTAssertNotNil(properties["selectedTranscriptRevision"])
            XCTAssertNil(properties["selectedTranscriptRevisionId"])
            XCTAssertEqual(
                (properties["transcriptRevisionIds"] as? [String: Any])?["maxItems"]
                    as? Int,
                TranscriptRevisionLimits.maximumSessionRevisionCount
            )
        }
    }

    func testTranscriptRevisionSchemaAndGoldenPreserveDisplayAndEvidenceSyntax() throws {
        let schema = try jsonObject(.transcriptRevisionSchema)
        let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
        XCTAssertEqual((schema["anyOf"] as? [[String: Any]])?.count, 2)
        for name in ["LegacyTranscriptRevision", "QualifiedTranscriptRevision"] {
            let variant = try XCTUnwrap(definitions[name] as? [String: Any])
            XCTAssertNotNil(variant["unevaluatedProperties"], name)
        }
        let lineProperties = try schemaProperties(
            "PersistedTranscriptLine",
            in: definitions
        )
        let wordProperties = try schemaProperties(
            "PersistedTranscriptWord",
            in: definitions
        )
        XCTAssertEqual(
            (lineProperties["text"] as? [String: Any])?["maxLength"] as? Int,
            131_072
        )
        XCTAssertEqual(
            (wordProperties["text"] as? [String: Any])?["maxLength"] as? Int,
            1_024
        )
        XCTAssertEqual(
            (wordProperties["confidence"] as? [String: Any])?["type"] as? String,
            "number"
        )

        let revision = try jsonObject(.transcriptRevisionExample)
        let legacyRevision = try jsonObject(.legacyTranscriptRevisionExample)
        XCTAssertEqual(revision["schemaVersion"] as? Int, 2)
        XCTAssertEqual(legacyRevision["schemaVersion"] as? Int, 1)
        XCTAssertNil((legacyRevision["engine"] as? [String: Any])?["qualification"])
        let lines = try XCTUnwrap(revision["lines"] as? [[String: Any]])
        let words = try XCTUnwrap(lines.first?["words"] as? [[String: Any]])
        let events = try XCTUnwrap(revision["audioEvents"] as? [[String: Any]])
        XCTAssertEqual(lines.first?["lineId"] as? String, "l000000")
        XCTAssertEqual(lines.first?["text"] as? String, "Hello, wörld.")
        XCTAssertEqual(words.compactMap { $0["wordId"] as? String }, [
            "w000000", "w000001",
        ])
        XCTAssertEqual(words.compactMap { $0["text"] as? String }, ["Hello", "wörld"])
        XCTAssertEqual(events.first?["audioEventId"] as? String, "a000000")

        let punctuation = try jsonObject(.rejectedTranscriptPunctuationWord)
        let punctuationLines = try XCTUnwrap(punctuation["lines"] as? [[String: Any]])
        let punctuationWords = try XCTUnwrap(
            punctuationLines.first?["words"] as? [[String: Any]]
        )
        XCTAssertEqual(punctuationWords.first?["text"] as? String, ".")

        let split = try jsonObject(.rejectedTranscriptUTF8Range)
        let splitLines = try XCTUnwrap(split["lines"] as? [[String: Any]])
        let splitWords = try XCTUnwrap(splitLines.first?["words"] as? [[String: Any]])
        let splitRange = try XCTUnwrap(
            splitWords.first?["displayRange"] as? [String: Any]
        )
        XCTAssertEqual(splitRange["endUtf8Byte"] as? Int, 2)
    }

    func testSessionProcessingContractsSealOfflineQualificationBoundary() throws {
        let request = try jsonObject(.transcriptionWorkerRequestSchema)
        let requestProperties = try XCTUnwrap(request["properties"] as? [String: Any])
        XCTAssertEqual(
            (requestProperties["networkAccess"] as? [String: Any])?["const"] as? String,
            "disabled"
        )
        XCTAssertEqual(
            (requestProperties["sources"] as? [String: Any])?["maxItems"] as? Int,
            1
        )
        let requestDefinitions = try XCTUnwrap(request["$defs"] as? [String: Any])
        let qualification = try schemaProperties(
            "TranscriptionWorkerQualification",
            in: requestDefinitions
        )
        XCTAssertNotNil(qualification["engineLockSha256"])
        XCTAssertNotNil(qualification["runtimeIdentity"])
        XCTAssertNotNil(qualification["runtimeLockSha256"])
        XCTAssertNotNil(qualification["compatibilityPatchId"])

        let candidate = try jsonObject(.transcriptionCandidateArtifactSchema)
        let candidateDefinitions = try XCTUnwrap(candidate["$defs"] as? [String: Any])
        let candidateEngine = try schemaProperties(
            "CandidateEngineProvenance",
            in: candidateDefinitions
        )
        XCTAssertNotNil(candidateEngine["qualification"])
        XCTAssertNil(candidateEngine["usePolicy"])

        let job = try jsonObject(.transcriptionJobManifestSchema)
        let jobDefinitions = try XCTUnwrap(job["$defs"] as? [String: Any])
        let jobState = try XCTUnwrap(
            jobDefinitions["TranscriptionJobState"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(jobState["enum"] as? [String] ?? []),
            [
                "queued", "preparing", "running", "validating", "completed",
                "failed", "cancelled", "interrupted",
            ]
        )

        let blocked = try jsonObject(.sessionProcessingQualificationBlockedScenario)
        let blockedEffects = try XCTUnwrap(
            blocked["expectedEffects"] as? [[String: Any]]
        )
        XCTAssertEqual(
            Set(blockedEffects.compactMap { $0["kind"] as? String }),
            ["noJobCreated", "noEngineLaunch", "noPublication", "noFallback"]
        )
        let success = try jsonObject(.sessionProcessingQualifiedSuccessScenario)
        let successEffects = try XCTUnwrap(
            success["expectedEffects"] as? [[String: Any]]
        )
        XCTAssertTrue(successEffects.contains { $0["kind"] as? String == "networkDisabled" })
        XCTAssertTrue(
            successEffects.contains { $0["kind"] as? String == "publishedThroughValidator" }
        )
    }

    func testImportedSessionGoldensPreservePortableV1Fields() throws {
        let audio = try jsonObject(.importedAudioManifestExample)
        let session = try jsonObject(.importedSessionManifestExample)
        let original = try XCTUnwrap(audio["original"] as? [String: Any])
        let canonical = try XCTUnwrap(audio["canonical"] as? [String: Any])

        XCTAssertEqual(
            session["audioManifestSha256"] as? String,
            "39873b844879dc24412388ef3e46f2b17b739e7742337967816a1e25fb436a4e"
        )
        XCTAssertEqual(session["transcriptRevisionIds"] as? [String], [])
        XCTAssertEqual(original["relativePath"] as? String, "audio/original.wav")
        XCTAssertEqual(canonical["relativePath"] as? String, "audio/audio.wav")
        XCTAssertEqual(canonical["encoding"] as? String, "pcmS16LE")
        XCTAssertEqual(canonical["sampleRateHz"] as? Int, 16_000)
        XCTAssertEqual(canonical["channelCount"] as? Int, 1)
        XCTAssertEqual(canonical["bitsPerSample"] as? Int, 16)
        XCTAssertEqual(canonical["byteCount"] as? Int, 50)
        XCTAssertEqual(canonical["frameCount"] as? Int, 3)

        let combined = try XCTUnwrap(
            String(
                data: ContractResources.data(for: .importedAudioManifestExample) +
                    ContractResources.data(for: .importedSessionManifestExample),
                encoding: .utf8
            )
        )
        for forbidden in [
            "bookmark", "absolutePath", "modelPath", "cachePath", "credential",
            "permissionGrant", "hardwareId", "file://", "/Users/", "\\",
        ] {
            XCTAssertFalse(combined.contains(forbidden), forbidden)
        }
    }

    func testNormalizationGoldenLocksDownmixQuantizerAndDurationBoundary() throws {
        let object = try jsonObject(.audioNormalizationVectorsExample)
        let downmix = try XCTUnwrap(object["downmixVectors"] as? [[String: Any]])
        let quantization = try XCTUnwrap(
            object["quantizationVectors"] as? [[String: Any]]
        )
        let durations = try XCTUnwrap(
            object["frameDurationVectors"] as? [[String: Any]]
        )

        XCTAssertEqual(downmix.count, 3)
        XCTAssertEqual(quantization.first?["output"] as? Int, -32_768)
        XCTAssertEqual(quantization.last?["output"] as? Int, 32_767)
        XCTAssertEqual(durations.first?["frameCount"] as? Int, 1)
        XCTAssertEqual(durations.first?["durationMs"] as? Int, 1)
        XCTAssertEqual(durations.last?["frameCount"] as? Int, 43_200_000)
        XCTAssertEqual(durations.last?["durationMs"] as? Int, 2_700_000)
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
                XCTAssertFalse(
                    text.localizedCaseInsensitiveContains(field),
                    resource.bundlePath
                )
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

    func testRecordingGoldensUseCanonicalReferencesAndHalfOpenIntervals() throws {
        let audio = try jsonObject(.recordingAudioExample)
        XCTAssertEqual(audio["canonicalAudioPath"] as? String, "audio/audio.wav")
        XCTAssertEqual(audio["frameCount"] as? Int, 16_000)
        let intervals = try XCTUnwrap(audio["unavailableIntervals"] as? [[String: Any]])
        XCTAssertEqual(intervals.count, 3)
        XCTAssertEqual(intervals[0]["startFrame"] as? Int, 1_600)
        XCTAssertEqual(intervals[0]["endFrame"] as? Int, 3_000)
        XCTAssertEqual(intervals[1]["startFrame"] as? Int, 3_000)
        XCTAssertEqual(intervals[1]["endFrame"] as? Int, 3_200)

        let session = try jsonObject(.recordingSessionExample)
        XCTAssertEqual(session["audioManifestPath"] as? String, "audio/audio.json")
        XCTAssertFalse((session["sessionId"] as? String ?? "").contains("/"))
    }

    func testRecordingScenarioSchemaClosesVocabularyAndInventoryKeys() throws {
        let root = try jsonObject(.recordingFeatureScenarioSchema)
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

    private func jsonObject(
        _ resource: ContractResource
    ) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ContractResources.data(for: resource)
            ) as? [String: Any]
        )
    }

    private func rootUnionReferences(
        in root: [String: Any]
    ) throws -> [String] {
        let variants = try XCTUnwrap(root["anyOf"] as? [[String: Any]])
        return try variants.map { variant in
            try definitionName(from: variant)
        }
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
        let union = try XCTUnwrap(definitions[name] as? [String: Any])
        let variants = try XCTUnwrap(
            (union["oneOf"] ?? union["anyOf"]) as? [[String: Any]]
        )
        return try variants.map { variant in
            try definitionName(from: variant)
        }
    }

    private func definitionName(from variant: [String: Any]) throws -> String {
        let reference = try XCTUnwrap(variant["$ref"] as? String)
        return String(reference.dropFirst("#/$defs/".count))
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

    func testChatManifestSchemaSealsNewAndSessionAnalysisCreationShapes() throws {
        let data = try ContractResources.data(for: .chatManifestSchema)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("NewChatManifest"))
        XCTAssertTrue(text.contains("SessionAnalysisChatManifest"))
        XCTAssertTrue(text.contains("originAttachmentId"))
        XCTAssertTrue(text.contains("unevaluatedProperties"))
        XCTAssertTrue(text.contains("creationKind"))
    }

    func testEmptyDevelopmentChatGoldenIsCanonicalAndHasNoMachineAuthority() throws {
        let data = try ContractResources.data(for: .emptyDevelopmentChatExample)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["creationKind"] as? String, "newChat")
        XCTAssertNil(object["originAttachmentId"])
        XCTAssertEqual((object["attachments"] as? [Any])?.count, 0)
        XCTAssertEqual((object["messageIds"] as? [Any])?.count, 0)
        let draft = try XCTUnwrap(object["draft"] as? [String: Any])
        XCTAssertEqual(draft["text"] as? String, "")

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in [
            "bookmark", "absolutePath", "modelPath", "cachePath", "credential",
            "permissionGrant", "hardwareId", "provider", "invocation",
        ] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testPendingUserTurnContractLocksExactDraftVersionAndResponsePosition() throws {
        let pending = try jsonObject(.pendingUserTurnExample)
        XCTAssertEqual(
            pending["pendingUserTurnId"] as? String,
            "ptu-20260830T120001000Z-5KMN"
        )
        XCTAssertEqual(
            pending["draftId"] as? String,
            "drf-20260830T120000000Z-3DEF"
        )
        XCTAssertEqual((pending["draftVersion"] as? NSNumber)?.uint64Value, 1)
        XCTAssertEqual(
            pending["responsePositionId"] as? String,
            "rsp-20260830T120001000Z-6PQR"
        )
        XCTAssertNil(pending["failure"])

        let failed = try jsonObject(.pendingUserTurnCapacityFailureExample)
        XCTAssertEqual(failed["pendingUserTurnId"] as? String,
                       pending["pendingUserTurnId"] as? String)
        XCTAssertEqual(failed["draftId"] as? String, pending["draftId"] as? String)
        XCTAssertEqual((failed["draftVersion"] as? NSNumber)?.uint64Value,
                       (pending["draftVersion"] as? NSNumber)?.uint64Value)
        XCTAssertEqual(failed["responsePositionId"] as? String,
                       pending["responsePositionId"] as? String)
        XCTAssertEqual(failed["failure"] as? String, "coachContextCannotFit")

        let schema = try XCTUnwrap(
            String(
                data: ContractResources.data(for: .pendingUserTurnSchema),
                encoding: .utf8
            )
        )
        XCTAssertTrue(schema.contains("PendingUserTurnId"))
        XCTAssertTrue(schema.contains("ChatResponsePositionId"))
        XCTAssertTrue(schema.contains("coachContextCannotFit"))
        XCTAssertTrue(schema.contains("unevaluatedProperties"))
    }

    func testEveryChatScenarioForbidsProviderAndAdmissionEffects() throws {
        let resources: [ContractResource] = [
            .createDevelopmentChatScenario,
            .draftSendDiscardChatScenario,
            .contextCapacityRecoveryChatScenario,
            .renameChatScenario,
            .filterChatsScenario,
            .relaunchChatScenario,
            .staleRenameChatScenario,
            .wrongLibraryChatScenario,
            .corruptChatScenario,
            .newerChatScenario,
            .collisionChatScenario,
            .providerUnavailableNewChatScenario,
            .invalidContextNewChatScenario,
            .attachmentDisappearsDuringCreateChatScenario,
            .cancelDuringNewChatQuoteScenario,
            .cancelDuringAttachmentResolutionScenario,
            .suspendedLibrarySwitchChatScenario,
        ]
        for resource in resources {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: ContractResources.data(for: resource)
                ) as? [String: Any]
            )
            XCTAssertEqual((object["expectedProviderCalls"] as? NSNumber)?.intValue, 0)
            XCTAssertEqual((object["expectedInvocationCalls"] as? NSNumber)?.intValue, 0)
            XCTAssertEqual((object["expectedAdmissionCalls"] as? NSNumber)?.intValue, 0)
        }
    }

    func testChatFeatureScenarioSchemaClosesEffectsOutcomesAndNotices() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ContractResources.data(for: .chatFeatureScenarioSchema)
            ) as? [String: Any]
        )
        let definitions = try XCTUnwrap(object["$defs"] as? [String: Any])
        let event = try XCTUnwrap(
            definitions["ChatDependencyEvent"] as? [String: Any]
        )
        let variants = try XCTUnwrap(event["oneOf"] as? [[String: Any]])
        XCTAssertFalse(variants.isEmpty)
        for variant in variants {
            let reference = try XCTUnwrap(variant["$ref"] as? String)
            let name = String(reference.split(separator: "/").last!)
            let shape = try XCTUnwrap(definitions[name] as? [String: Any])
            let properties = try XCTUnwrap(shape["properties"] as? [String: Any])
            let effect = try XCTUnwrap(properties["effect"] as? [String: Any])
            let outcome = try XCTUnwrap(properties["outcome"] as? [String: Any])
            XCTAssertNotNil(effect["const"], name)
            XCTAssertTrue(outcome["const"] != nil || outcome["$ref"] != nil, name)
        }

        let notice = try XCTUnwrap(
            definitions["ChatScenarioNotice"] as? [String: Any]
        )
        let noticeVariants = try XCTUnwrap(notice["anyOf"] as? [[String: Any]])
        XCTAssertEqual(
            Set(noticeVariants.compactMap { $0["const"] as? String }),
            [
                "invalidTitle", "createFailed", "createCollisionLimitReached",
                "renameFailed", "staleRename", "chatMissing", "chatOpenFailed",
                "chatFrozen", "catalogFailed", "readOnlyLibrary", "invalidDraft",
                "draftSaveFailed", "draftChanged", "pendingUserTurnFailed",
                "coachContextUnavailable", "messageMustBeShortened",
                "attachmentCatalogFailed",
            ]
        )
    }

    func testChatFeatureScenarioSchemaModelsBoundedNewChatAttachmentPickerWorkflow() throws {
        let root = try jsonObject(.chatFeatureScenarioSchema)
        let definitions = try XCTUnwrap(root["$defs"] as? [String: Any])

        let commandNames = try unionReferences(
            "ChatScenarioCommand",
            in: definitions
        )
        let commandKinds = try commandNames.flatMap { name in
            let properties = try schemaProperties(name, in: definitions)
            return literalValues(in: properties["kind"])
        }
        XCTAssertTrue(
            Set(commandKinds).isSuperset(of: [
                "beginNewChat", "setNewChatAttachmentFilter",
                "toggleNewChatAttachment", "cancelNewChat", "confirmNewChat",
            ])
        )

        let catalog = try schemaProperties(
            "NewChatAttachmentCatalogLoadedEvent",
            in: definitions
        )
        XCTAssertEqual(
            (catalog["candidates"] as? [String: Any])?["maxItems"] as? Int,
            32_768
        )
        let candidate = try schemaProperties(
            "NewChatAttachmentCandidate",
            in: definitions
        )
        XCTAssertEqual(
            (candidate["displayLabel"] as? [String: Any])?["$ref"] as? String,
            "#/$defs/NewChatAttachmentDisplayLabel"
        )
        let displayLabel = try XCTUnwrap(
            definitions["NewChatAttachmentDisplayLabel"] as? [String: Any]
        )
        XCTAssertEqual(displayLabel["minLength"] as? Int, 1)
        XCTAssertEqual(displayLabel["maxLength"] as? Int, 256)
        XCTAssertEqual(
            displayLabel["pattern"] as? String,
            #"^[^\u0000-\u001F\u007F-\u009F]*$"#
        )
        let filterText = try XCTUnwrap(
            definitions["NewChatAttachmentFilterText"] as? [String: Any]
        )
        XCTAssertEqual(filterText["maxLength"] as? Int, 256)
        XCTAssertEqual(
            filterText["pattern"] as? String,
            #"^[^\u0000-\u001F\u007F-\u009F]*$"#
        )
        XCTAssertEqual(
            (candidate["durationMilliseconds"] as? [String: Any])?["maximum"]
                as? Int,
            2_700_000
        )
        XCTAssertEqual(
            (candidate["approximateTranscriptTokens"] as? [String: Any])?["maximum"]
                as? Int,
            67_108_864
        )

        let expectedState = try schemaProperties(
            "ChatScenarioState",
            in: definitions
        )
        XCTAssertEqual(
            (expectedState["newChatSelectedAttachmentIds"]
                as? [String: Any])?["maxItems"] as? Int,
            128
        )
        XCTAssertNotNil(expectedState["newChatFeasibility"])
        XCTAssertNotNil(expectedState["newChatIssue"])
        XCTAssertNotNil(expectedState["openedAttachmentStatuses"])

        let dependencyNames = try unionReferences(
            "ChatDependencyEvent",
            in: definitions
        )
        let dependencyEffects = try dependencyNames.flatMap { name in
            let properties = try schemaProperties(name, in: definitions)
            return literalValues(in: properties["effect"])
        }
        XCTAssertTrue(
            Set(dependencyEffects).isSuperset(of: [
                "loadCandidates", "quoteNewChat", "resolveAttachments",
            ])
        )

        for (name, outcome) in [
            ("NewChatQuoteCancelledEvent", "cancelled"),
            ("ChatAttachmentResolutionCancelledEvent", "cancelled"),
            ("ChatStoreCreateAttachmentUnavailableEvent", "attachmentUnavailable"),
        ] {
            let properties = try schemaProperties(name, in: definitions)
            XCTAssertEqual(
                literalValues(in: properties["outcome"]),
                [outcome],
                name
            )
        }

        let suspendedEffect = try XCTUnwrap(
            definitions["ChatScenarioSuspendedEffect"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(suspendedEffect["anyOf"] as? [[String: Any]])
                .compactMap { $0["const"] as? String }),
            [
                "firstCatalogLoad", "firstAttachmentResolution",
                "newChatQuoteAfterAttachmentResolution",
            ]
        )
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
