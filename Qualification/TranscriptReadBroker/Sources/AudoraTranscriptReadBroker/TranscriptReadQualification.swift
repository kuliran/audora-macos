import AudoraCodexCLIQualification
import AudoraApplication
import Foundation

public struct TranscriptReadQualificationReport: Codable, Equatable, Sendable {
    public let qualification: String
    public let deterministicCasesPassed: Int
    public let allOrNothingVerified: Bool
    public let boundedRedeliveryVerified: Bool
    public let loopbackIPv4Only: Bool
    public let endpointStopped: Bool
    public let capabilityLeakDetected: Bool
    public let localIdentityLeakDetected: Bool
    public let realCodexExercise: String
    public let productionQualified: Bool
    public let blockers: [String]

    public static let failedClosed = TranscriptReadQualificationReport(
        qualification: "syntheticOnly",
        deterministicCasesPassed: 0,
        allOrNothingVerified: false,
        boundedRedeliveryVerified: false,
        loopbackIPv4Only: false,
        endpointStopped: true,
        capabilityLeakDetected: false,
        localIdentityLeakDetected: false,
        realCodexExercise: "notRun",
        productionQualified: false,
        blockers: Self.shippingBlockers
    )

    fileprivate static let shippingBlockers = [
        "shippingCodexCLIModelPairNotQualified",
        "shippingTokenizerAndHiddenFramingNotQualified",
        "providerOutputCeilingNotProven",
        "realCodexScopedToolSurfaceNotProven",
    ]
}

public enum TranscriptReadQualificationError: Error, Equatable, Sendable {
    case failed
}

public struct TranscriptReadQualificationRunner: Sendable {
    public init() {}

    /// Exercises only committed synthetic transcript data. It never launches
    /// Codex, reads authentication state, or opens a Library.
    public func run() async throws -> TranscriptReadQualificationReport {
        let budget = try CompleteToolResponseBudget(
            remainingInputTokens: 100_000,
            responsePrefix: Data(),
            responseSuffix: Data(),
            hiddenTokens: 0,
            tokenEstimator: .utf8ByteUpperBound()
        )
        let revision = FrozenTranscriptRevision(
            sessionID: "qualification-local-session-canary",
            revisionID: "qualification-local-revision-canary"
        )
        let attachment = FrozenTranscriptAttachment(
            sessionAttachmentID: "qualification-attachment",
            displayLabel: "Synthetic qualification fixture",
            revision: revision
        )
        let availableReader = FrozenTranscriptReader { requested in
            guard requested == revision else { return .unavailable }
            return .available(Self.syntheticTranscript)
        }
        let issuer = AttemptTranscriptGrantIssuer()
        let first = try issuer.issue(
            attachments: [attachment],
            reader: availableReader,
            completeResponseBudget: budget
        )
        let second = try issuer.issue(
            attachments: [attachment],
            reader: availableReader,
            completeResponseBudget: budget
        )
        guard first.capability != second.capability,
              first.providerAttachments[0].sessionTranscriptHandle
                != second.providerAttachments[0].sessionTranscriptHandle
        else {
            throw TranscriptReadQualificationError.failed
        }

        let request = Self.requestBody(
            handle: first.providerAttachments[0].sessionTranscriptHandle
        )
        let initial = await first.broker.read(
            capability: first.capability,
            requestBody: request
        )
        let replay = await first.broker.read(
            capability: first.capability,
            requestBody: request
        )
        let overDelivery = await first.broker.read(
            capability: first.capability,
            requestBody: request
        )
        guard case let .delivered(initialDelivery) = initial,
              case let .delivered(replayDelivery) = replay,
              initialDelivery.kind == .complete,
              replayDelivery.isReplay,
              replayDelivery.responseBody == initialDelivery.responseBody,
              overDelivery == .rejected(.closed)
        else {
            throw TranscriptReadQualificationError.failed
        }

        let unavailable = try issuer.issue(
            attachments: [attachment],
            reader: FrozenTranscriptReader { _ in .unavailable },
            completeResponseBudget: budget
        )
        let unavailableResult = await unavailable.broker.read(
            capability: unavailable.capability,
            requestBody: Self.requestBody(
                handle: unavailable.providerAttachments[0].sessionTranscriptHandle
            )
        )
        guard case let .delivered(unavailableDelivery) = unavailableResult,
              unavailableDelivery.kind == .sessionUnavailable,
              unavailableDelivery.terminatesAttempt,
              await unavailable.broker.status() == .revoked
        else {
            throw TranscriptReadQualificationError.failed
        }

        let capabilityEnvironment = try first.capability.installing(
            in: [:],
            variableName: "AUDORA_TRANSCRIPT_READ_CAPABILITY"
        )
        guard let capability = capabilityEnvironment["AUDORA_TRANSCRIPT_READ_CAPABILITY"] else {
            throw TranscriptReadQualificationError.failed
        }
        let providerBytes = initialDelivery.responseBody + unavailableDelivery.responseBody
        let providerText = String(decoding: providerBytes, as: UTF8.self)
        let capabilityLeak = providerText.contains(capability)
        let identityLeak = providerText.contains("qualification-local-session-canary")
            || providerText.contains("qualification-local-revision-canary")
        guard !capabilityLeak, !identityLeak else {
            throw TranscriptReadQualificationError.failed
        }

        let loopbackGrant = try issuer.issue(
            attachments: [attachment],
            reader: availableReader,
            completeResponseBudget: budget
        )
        let server = try await LoopbackTranscriptReadHTTPServer.start(grant: loopbackGrant)
        let loopbackIPv4Only = server.host == "127.0.0.1"
            && server.endpointURL.host == "127.0.0.1"
            && server.port != 0
        await server.stop(reason: .attemptCompleted)
        let endpointStopped = server.isStopped()
        guard loopbackIPv4Only,
              endpointStopped,
              await loopbackGrant.broker.status() == .revoked
        else {
            throw TranscriptReadQualificationError.failed
        }

        await second.broker.revoke(reason: .attemptCompleted)
        return TranscriptReadQualificationReport(
            qualification: "syntheticOnly",
            deterministicCasesPassed: 5,
            allOrNothingVerified: true,
            boundedRedeliveryVerified: true,
            loopbackIPv4Only: true,
            endpointStopped: true,
            capabilityLeakDetected: false,
            localIdentityLeakDetected: false,
            realCodexExercise: "notRun",
            productionQualified: false,
            blockers: TranscriptReadQualificationReport.shippingBlockers
        )
    }

    private static let syntheticTranscript = SessionTranscriptProjection(
        durationMs: 1_000,
        lines: [
            TranscriptLine(
                timeRange: TranscriptTimeRange(startMs: 0, endMs: 300),
                text: "Synthetic qualification transcript.",
                words: [
                    TranscriptWord(
                        wordID: "qualification-word",
                        text: "Synthetic qualification transcript.",
                        timeRange: TranscriptTimeRange(startMs: 0, endMs: 300)
                    ),
                ]
            ),
        ],
        audioEvents: []
    )

    private static func requestBody(handle: String) -> Data {
        try! JSONSerialization.data(
            withJSONObject: ["sessionTranscriptHandles": [handle]],
            options: [.sortedKeys]
        )
    }
}
