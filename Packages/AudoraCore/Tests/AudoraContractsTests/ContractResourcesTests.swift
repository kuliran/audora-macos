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
        let controlledJob = try XCTUnwrap(
            jobDefinitions["ControlledTranscriptionJobManifest"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(controlledJob["required"] as? [String] ?? []),
            [
                "schemaVersion", "expectedSelectedRevisionId",
                "cancellationAuthorityId",
            ]
        )
        let controlledProperties = try XCTUnwrap(
            controlledJob["properties"] as? [String: Any]
        )
        XCTAssertNotNil(controlledProperties["expectedSelectedRevisionId"])
        let sequencedJob = try XCTUnwrap(
            jobDefinitions["SequencedTranscriptionJobManifest"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(sequencedJob["required"] as? [String] ?? []),
            [
                "schemaVersion", "attemptSequence", "expectedSelectedRevisionId",
                "cancellationAuthorityId",
            ]
        )
        let sequencedProperties = try XCTUnwrap(
            sequencedJob["properties"] as? [String: Any]
        )
        XCTAssertNotNil(sequencedProperties["attemptSequence"])

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
        for resource in [
            ContractResource.sessionProcessingQualifiedSuccessScenario,
            .sessionProcessingCandidateRejectedScenario,
            .sessionProcessingModelPrepareStartScenario,
        ] {
            let scenario = try jsonObject(resource)
            let trace = try XCTUnwrap(
                scenario["dependencyTrace"] as? [[String: Any]]
            )
            let identityAndCreationEffects = trace.compactMap {
                $0["effect"] as? String
            }.filter {
                [
                    "generateJobId", "generateRevisionId",
                    "generateCancellationAuthorityId", "create",
                ].contains($0)
            }
            XCTAssertEqual(
                identityAndCreationEffects,
                [
                    "generateJobId", "generateRevisionId",
                    "generateCancellationAuthorityId", "create",
                ],
                resource.bundlePath
            )
            let authorityEvent = try XCTUnwrap(
                trace.first {
                    $0["effect"] as? String == "generateCancellationAuthorityId"
                }
            )
            XCTAssertEqual(authorityEvent["port"] as? String, "identifiers")
            XCTAssertEqual(
                authorityEvent["outcome"] as? String,
                "cancel-synthetic-authority"
            )
        }

        let cancellation = try jsonObject(.sessionProcessingCancellationScenario)
        let cancellationEffects = try XCTUnwrap(
            cancellation["expectedEffects"] as? [[String: Any]]
        )
        XCTAssertTrue(
            cancellationEffects.contains { $0["kind"] as? String == "workerReaped" }
        )
        XCTAssertTrue(
            cancellationEffects.contains { $0["kind"] as? String == "lateCandidateRejected" }
        )
        let queuedRelaunch = try jsonObject(
            .sessionProcessingRelaunchQueuedInterruptedScenario
        )
        let queuedInitial = try XCTUnwrap(
            queuedRelaunch["initialState"] as? [String: Any]
        )
        let queuedExpected = try XCTUnwrap(
            queuedRelaunch["expectedState"] as? [String: Any]
        )
        XCTAssertEqual(queuedInitial["status"] as? String, "unavailable")
        XCTAssertEqual(queuedInitial["reason"] as? String, "noSession")
        XCTAssertEqual(queuedInitial["actions"] as? [String], [])
        XCTAssertEqual(queuedExpected["status"] as? String, "unavailable")
        XCTAssertEqual(queuedExpected["reason"] as? String, "noSession")
        XCTAssertEqual(queuedExpected["actions"] as? [String], [])
        let queuedInitialJobs = try XCTUnwrap(
            queuedRelaunch["initialJobs"] as? [[String: Any]]
        )
        let queuedExpectedJobs = try XCTUnwrap(
            queuedRelaunch["expectedJobs"] as? [[String: Any]]
        )
        XCTAssertEqual(queuedInitialJobs.count, 1)
        XCTAssertEqual(queuedExpectedJobs.count, 1)
        XCTAssertEqual(queuedInitialJobs[0]["state"] as? String, "queued")
        XCTAssertEqual(queuedExpectedJobs[0]["state"] as? String, "interrupted")
        XCTAssertEqual(
            queuedExpectedJobs[0]["jobId"] as? String,
            queuedInitialJobs[0]["jobId"] as? String
        )
        XCTAssertEqual(
            queuedExpectedJobs[0]["revisionId"] as? String,
            queuedInitialJobs[0]["revisionId"] as? String
        )
        let queuedCommands = try XCTUnwrap(
            queuedRelaunch["commands"] as? [[String: Any]]
        )
        XCTAssertEqual(queuedCommands.compactMap { $0["kind"] as? String }, [
            "activateLibrary",
        ])

        let queuedTrace = try XCTUnwrap(
            queuedRelaunch["dependencyTrace"] as? [[String: Any]]
        )
        XCTAssertEqual(
            queuedTrace.filter { $0["effect"] as? String == "transitionInterrupted" }
                .count,
            1
        )
        let queuedTransition = queuedTrace.first {
            $0["effect"] as? String == "transitionInterrupted"
        }
        XCTAssertEqual(queuedTransition?["outcome"] as? String, "cas-written-once")
        XCTAssertFalse(
            queuedTrace.contains { $0["effect"] as? String == "workerPresence" }
        )
        XCTAssertFalse(queuedTrace.contains { $0["effect"] as? String == "transcribe" })
        XCTAssertTrue(
            queuedTrace.contains {
                $0["port"] as? String == "jobs" &&
                    $0["effect"] as? String == "inventory" &&
                    $0["outcome"] as? String == "all-durable-jobs-bounded"
            }
        )
        XCTAssertFalse(queuedTrace.contains { $0["port"] as? String == "source" })
        let queuedEffects = try XCTUnwrap(
            queuedRelaunch["expectedEffects"] as? [[String: Any]]
        )
        XCTAssertEqual(
            Set(queuedEffects.compactMap { $0["kind"] as? String }),
            [
                "allDurableJobsReconciled", "queuedInterrupted", "sessionRetained",
                "noEngineLaunch", "noPublication",
            ]
        )
        let runningRelaunch = try jsonObject(
            .sessionProcessingRelaunchInterruptedScenario
        )
        let runningInitial = try XCTUnwrap(
            runningRelaunch["initialState"] as? [String: Any]
        )
        let runningExpected = try XCTUnwrap(
            runningRelaunch["expectedState"] as? [String: Any]
        )
        XCTAssertEqual(runningInitial["status"] as? String, "unavailable")
        XCTAssertEqual(runningInitial["reason"] as? String, "noSession")
        XCTAssertEqual(runningExpected["status"] as? String, "unavailable")
        XCTAssertEqual(runningExpected["reason"] as? String, "noSession")
        let runningInitialJobs = try XCTUnwrap(
            runningRelaunch["initialJobs"] as? [[String: Any]]
        )
        let runningExpectedJobs = try XCTUnwrap(
            runningRelaunch["expectedJobs"] as? [[String: Any]]
        )
        XCTAssertEqual(runningInitialJobs.map { $0["state"] as? String }, ["running"])
        XCTAssertEqual(
            runningExpectedJobs.map { $0["state"] as? String },
            ["interrupted"]
        )

        let stale = try jsonObject(
            .sessionProcessingRelaunchStaleSelectionScenario
        )
        let staleState = try XCTUnwrap(stale["expectedState"] as? [String: Any])
        XCTAssertEqual(staleState["status"] as? String, "unavailable")
        XCTAssertEqual(staleState["reason"] as? String, "noSession")
        let staleInitialJobs = try XCTUnwrap(
            stale["initialJobs"] as? [[String: Any]]
        )
        let staleExpectedJobs = try XCTUnwrap(
            stale["expectedJobs"] as? [[String: Any]]
        )
        XCTAssertEqual(staleInitialJobs.map { $0["state"] as? String }, ["validating"])
        XCTAssertEqual(staleExpectedJobs.map { $0["state"] as? String }, ["failed"])
        XCTAssertEqual(staleExpectedJobs[0]["failure"] as? String, "staleSelection")
        let staleEffects = try XCTUnwrap(stale["expectedEffects"] as? [[String: Any]])
        XCTAssertTrue(
            staleEffects.contains {
                $0["kind"] as? String == "startSelectionBaselinePreserved"
            }
        )
        let progress = try jsonObject(.sessionProcessingProgressScenario)
        let progressState = try XCTUnwrap(progress["expectedState"] as? [String: Any])
        let measured = try XCTUnwrap(progressState["progress"] as? [String: Any])
        XCTAssertEqual(measured["completedWindows"] as? Int, 2)
        XCTAssertEqual(measured["totalWindows"] as? Int, 4)
        XCTAssertEqual(measured["approximateEtaSeconds"] as? Int, 5)

        let feature = try jsonObject(.sessionProcessingFeatureScenarioSchema)
        let featureDefinitions = try XCTUnwrap(feature["$defs"] as? [String: Any])
        let commandSchema = try XCTUnwrap(
            featureDefinitions["SessionProcessingScenarioCommand"] as? [String: Any]
        )
        let commandSchemaData = try JSONSerialization.data(withJSONObject: commandSchema)
        let commandSchemaText = try XCTUnwrap(
            String(data: commandSchemaData, encoding: .utf8)
        )
        XCTAssertTrue(commandSchemaText.contains("activateLibrary"))

        let featureProperties = try XCTUnwrap(feature["properties"] as? [String: Any])
        XCTAssertEqual(
            (featureProperties["initialJobs"] as? [String: Any])?["minItems"] as? Int,
            1
        )
        XCTAssertEqual(
            (featureProperties["initialJobs"] as? [String: Any])?["maxItems"] as? Int,
            10_000
        )
        XCTAssertEqual(
            (featureProperties["expectedJobs"] as? [String: Any])?["minItems"] as? Int,
            1
        )
        XCTAssertEqual(
            (featureProperties["expectedJobs"] as? [String: Any])?["maxItems"] as? Int,
            10_000
        )
        let durableJobSchema = try XCTUnwrap(
            featureDefinitions["SessionProcessingScenarioDurableJob"]
                as? [String: Any]
        )
        XCTAssertEqual(
            Set(durableJobSchema["required"] as? [String] ?? []),
            ["jobId", "revisionId", "state"]
        )

        let completedSchema = try XCTUnwrap(
            featureDefinitions["SessionProcessingScenarioCompletedState"]
                as? [String: Any]
        )
        XCTAssertEqual(
            Set(completedSchema["required"] as? [String] ?? []),
            ["status", "revisionId", "selectedRevisionId"]
        )
        let completedSchemaData = try JSONSerialization.data(withJSONObject: completedSchema)
        let completedSchemaText = try XCTUnwrap(
            String(data: completedSchemaData, encoding: .utf8)
        )
        XCTAssertTrue(completedSchemaText.contains("\"type\":\"null\""))

        let validationRelaunch = try jsonObject(
            .sessionProcessingRelaunchValidationScenario
        )
        let relaunchCommands = try XCTUnwrap(
            validationRelaunch["commands"] as? [[String: Any]]
        )
        XCTAssertEqual(relaunchCommands.compactMap { $0["kind"] as? String }, [
            "activateLibrary",
        ])
        let relaunchTrace = try XCTUnwrap(
            validationRelaunch["dependencyTrace"] as? [[String: Any]]
        )
        XCTAssertTrue(
            relaunchTrace.contains {
                $0["port"] as? String == "jobs" &&
                    $0["effect"] as? String == "inventory" &&
                    $0["outcome"] as? String == "all-durable-jobs-bounded"
            }
        )
        XCTAssertTrue(
            relaunchTrace.contains {
                $0["port"] as? String == "publisher" &&
                    $0["effect"] as? String == "reopenRevision" &&
                    $0["outcome"] as? String == "exact-job-revision"
            }
        )
        XCTAssertFalse(
            relaunchTrace.contains { $0["effect"] as? String == "reopenSelected" }
        )
        let relaunchExpected = try XCTUnwrap(
            validationRelaunch["expectedState"] as? [String: Any]
        )
        XCTAssertEqual(relaunchExpected["status"] as? String, "unavailable")
        XCTAssertEqual(relaunchExpected["reason"] as? String, "noSession")
        let validationInitialJobs = try XCTUnwrap(
            validationRelaunch["initialJobs"] as? [[String: Any]]
        )
        let validationExpectedJobs = try XCTUnwrap(
            validationRelaunch["expectedJobs"] as? [[String: Any]]
        )
        XCTAssertEqual(
            validationInitialJobs.map { $0["state"] as? String },
            ["validating"]
        )
        XCTAssertEqual(
            validationExpectedJobs.map { $0["state"] as? String },
            ["completed"]
        )
        XCTAssertEqual(
            validationExpectedJobs[0]["jobId"] as? String,
            validationInitialJobs[0]["jobId"] as? String
        )
        XCTAssertEqual(
            validationExpectedJobs[0]["revisionId"] as? String,
            validationInitialJobs[0]["revisionId"] as? String
        )
        let relaunchEffects = try XCTUnwrap(
            validationRelaunch["expectedEffects"] as? [[String: Any]]
        )
        XCTAssertFalse(
            relaunchEffects.contains { $0["kind"] as? String == "selectedAtomically" }
        )
        XCTAssertTrue(
            relaunchEffects.contains {
                $0["kind"] as? String == "allDurableJobsReconciled"
            }
        )
    }

    func testSessionProcessingAttemptIndexContractMatchesItsAuthoritativeRoot()
        throws
    {
        let schema = try jsonObject(.sessionProcessingAttemptIndexSchema)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(
            (properties["schemaVersion"] as? [String: Any])?["const"] as? Int,
            1
        )
        XCTAssertEqual(
            (properties["sessions"] as? [String: Any])?["maxItems"] as? Int,
            10_000
        )

        let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let session = try XCTUnwrap(
            definitions["SessionProcessingSessionAttempts"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(session["required"] as? [String] ?? []),
            [
                "sessionId", "legacyJobIds", "attempts", "currentJobId",
                "pendingAttempt",
            ]
        )
        XCTAssertNotNil(session["unevaluatedProperties"])
        let pointer = try XCTUnwrap(
            definitions["SessionProcessingAttemptPointer"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(pointer["required"] as? [String] ?? []),
            ["sequence", "jobId"]
        )
        XCTAssertNotNil(pointer["unevaluatedProperties"])

        let accepted = try jsonObject(.sessionProcessingAttemptIndexExample)
        XCTAssertEqual(accepted["schemaVersion"] as? Int, 1)
        XCTAssertEqual((accepted["sessions"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(
            try jsonObject(.rejectedNewerSessionProcessingAttemptIndex)[
                "schemaVersion"
            ] as? Int,
            2
        )
        XCTAssertEqual(
            try jsonObject(.rejectedZeroSessionProcessingAttemptSequence)[
                "schemaVersion"
            ] as? Int,
            1
        )
        XCTAssertNotNil(
            try jsonObject(.rejectedUnknownSessionProcessingAttemptIndexKey)[
                "futureCoordination"
            ]
        )
    }

    func testSessionProcessingRaceContractsPreserveTheFirstDurableWinner() throws {
        let cases: [(
            file: String,
            kind: String,
            winner: String,
            finalState: String,
            failure: String?,
            cancellationWon: Bool
        )] = [
            (
                "race-candidate-wins-cancel.v1.json",
                "candidateVsCancel",
                "candidate",
                "failed",
                "staleSelection",
                false
            ),
            (
                "race-cancel-wins-candidate.v1.json",
                "candidateVsCancel",
                "cancellation",
                "cancelled",
                nil,
                true
            ),
            (
                "race-engine-failure-wins-cancel.v1.json",
                "engineFailureVsCancel",
                "engineFailure",
                "failed",
                "engineFailed",
                false
            ),
            (
                "race-cancel-wins-engine-failure.v1.json",
                "engineFailureVsCancel",
                "cancellation",
                "cancelled",
                nil,
                true
            ),
            (
                "race-candidate-rejection-wins-cancel.v1.json",
                "candidateRejectionVsCancel",
                "candidateRejection",
                "failed",
                "candidateRejected",
                false
            ),
            (
                "race-cancel-wins-candidate-rejection.v1.json",
                "candidateRejectionVsCancel",
                "cancellation",
                "cancelled",
                nil,
                true
            ),
        ]
        let registered = Dictionary(
            uniqueKeysWithValues: ContractResource.allCases.map {
                ($0.bundlePath, $0)
            }
        )

        let feature = try jsonObject(.sessionProcessingFeatureScenarioSchema)
        let definitions = try XCTUnwrap(feature["$defs"] as? [String: Any])
        let raceSchema = try XCTUnwrap(
            definitions["SessionProcessingScenarioRace"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(raceSchema["required"] as? [String] ?? []),
            ["kind", "firstDurableWinner", "losingCompareAndSwap"]
        )

        for expected in cases {
            let path = "Scenarios/SessionProcessing/\(expected.file)"
            let resource = try XCTUnwrap(registered[path], path)
            let scenario = try jsonObject(resource)
            let race = try XCTUnwrap(scenario["race"] as? [String: Any])
            XCTAssertEqual(race["kind"] as? String, expected.kind, path)
            XCTAssertEqual(
                race["firstDurableWinner"] as? String,
                expected.winner,
                path
            )
            XCTAssertEqual(race["losingCompareAndSwap"] as? String, "stale", path)

            let initialJobs = try XCTUnwrap(
                scenario["initialJobs"] as? [[String: Any]]
            )
            let expectedJobs = try XCTUnwrap(
                scenario["expectedJobs"] as? [[String: Any]]
            )
            XCTAssertEqual(initialJobs.count, 1, path)
            XCTAssertEqual(expectedJobs.count, 1, path)
            XCTAssertLessThanOrEqual(initialJobs.count, 10_000, path)
            XCTAssertLessThanOrEqual(expectedJobs.count, 10_000, path)
            XCTAssertEqual(initialJobs[0]["state"] as? String, "running", path)
            XCTAssertEqual(
                initialJobs[0]["jobId"] as? String,
                expectedJobs[0]["jobId"] as? String,
                path
            )
            XCTAssertEqual(expectedJobs[0]["state"] as? String, expected.finalState, path)
            XCTAssertEqual(expectedJobs[0]["failure"] as? String, expected.failure, path)

            let state = try XCTUnwrap(scenario["expectedState"] as? [String: Any])
            XCTAssertEqual(state["status"] as? String, expected.finalState, path)
            XCTAssertEqual(state["reason"] as? String, expected.failure, path)
            let trace = try XCTUnwrap(
                scenario["dependencyTrace"] as? [[String: Any]]
            )
            let effects = try XCTUnwrap(
                scenario["expectedEffects"] as? [[String: Any]]
            )
            let effectKinds = Set(effects.compactMap { $0["kind"] as? String })
            XCTAssertTrue(effectKinds.contains("firstDurableWinnerPreserved"), path)
            XCTAssertTrue(effectKinds.contains("noAutomaticRerun"), path)

            if expected.cancellationWon {
                XCTAssertTrue(
                    trace.contains {
                        $0["effect"] as? String == "persistCancellationRequest" &&
                            $0["outcome"] as? String == "written-first"
                    },
                    path
                )
                XCTAssertTrue(
                    trace.contains {
                        guard let effect = $0["effect"] as? String else {
                            return false
                        }
                        return ["transitionValidating", "transitionFailed"]
                            .contains(effect) &&
                            $0["outcome"] as? String == "stale-lost"
                    },
                    path
                )
                XCTAssertTrue(
                    trace.contains {
                        $0["effect"] as? String == "cancelAndReap" &&
                            $0["outcome"] as? String == "reaped"
                    },
                    path
                )
                XCTAssertTrue(effectKinds.contains("workerReaped"), path)
                XCTAssertFalse(effectKinds.contains("noWorkerCancellation"), path)
            } else {
                XCTAssertTrue(
                    trace.contains {
                        $0["effect"] as? String == "persistCancellationRequest" &&
                            $0["outcome"] as? String == "stale-lost"
                    },
                    path
                )
                XCTAssertTrue(
                    trace.contains {
                        $0["effect"] as? String == "loadExact" &&
                            $0["outcome"] as? String == "first-durable-winner"
                    },
                    path
                )
                XCTAssertFalse(
                    trace.contains { $0["effect"] as? String == "cancelAndReap" },
                    path
                )
                XCTAssertTrue(effectKinds.contains("noWorkerCancellation"), path)
                XCTAssertEqual(state["actions"] as? [String], ["retry"], path)
            }
        }
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
        let variants = try XCTUnwrap(
            (definitions[name] as? [String: Any])?["anyOf"] as? [[String: Any]]
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

    func testDevelopmentChatGoldenIsCanonicalEmptyAndHasNoMachineAuthority() throws {
        let data = try ContractResources.data(for: .developmentChatExample)
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

        let schema = try XCTUnwrap(
            String(
                data: ContractResources.data(for: .pendingUserTurnSchema),
                encoding: .utf8
            )
        )
        XCTAssertTrue(schema.contains("PendingUserTurnId"))
        XCTAssertTrue(schema.contains("ChatResponsePositionId"))
        XCTAssertTrue(schema.contains("unevaluatedProperties"))
    }

    func testEveryDevelopmentChatScenarioForbidsProviderAndAdmissionEffects() throws {
        let resources: [ContractResource] = [
            .createDevelopmentChatScenario,
            .draftSendDiscardDevelopmentChatScenario,
            .renameDevelopmentChatScenario,
            .filterDevelopmentChatsScenario,
            .relaunchDevelopmentChatScenario,
            .staleRenameDevelopmentChatScenario,
            .wrongLibraryDevelopmentChatScenario,
            .corruptDevelopmentChatScenario,
            .newerDevelopmentChatScenario,
            .collisionDevelopmentChatScenario,
            .providerUnavailableDevelopmentChatScenario,
            .suspendedLibrarySwitchDevelopmentChatScenario,
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

    func testDevelopmentChatScenarioSchemaClosesEffectsOutcomesAndNotices() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ContractResources.data(for: .developmentChatFeatureScenarioSchema)
            ) as? [String: Any]
        )
        let definitions = try XCTUnwrap(object["$defs"] as? [String: Any])
        let event = try XCTUnwrap(
            definitions["DevelopmentChatDependencyEvent"] as? [String: Any]
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
            definitions["DevelopmentChatScenarioNotice"] as? [String: Any]
        )
        let noticeVariants = try XCTUnwrap(notice["anyOf"] as? [[String: Any]])
        XCTAssertEqual(
            Set(noticeVariants.compactMap { $0["const"] as? String }),
            [
                "invalidTitle", "createFailed", "createCollisionLimitReached",
                "renameFailed", "staleRename", "chatMissing", "chatOpenFailed",
                "chatFrozen", "catalogFailed", "readOnlyLibrary", "invalidDraft",
                "draftSaveFailed", "draftChanged", "pendingUserTurnFailed",
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
