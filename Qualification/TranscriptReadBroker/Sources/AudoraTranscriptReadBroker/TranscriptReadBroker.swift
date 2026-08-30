import AudoraCodexCLIQualification
import CryptoKit
import Foundation

public struct TranscriptTimeRange: Equatable, Sendable {
    public let startMs: Int
    public let endMs: Int

    public init(startMs: Int, endMs: Int) {
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct TranscriptWord: Equatable, Sendable {
    public let wordID: String
    public let text: String
    public let timeRange: TranscriptTimeRange?

    public init(wordID: String, text: String, timeRange: TranscriptTimeRange? = nil) {
        self.wordID = wordID
        self.text = text
        self.timeRange = timeRange
    }
}

public struct TranscriptLine: Equatable, Sendable {
    public let timeRange: TranscriptTimeRange
    public let text: String
    public let words: [TranscriptWord]

    public init(timeRange: TranscriptTimeRange, text: String, words: [TranscriptWord]) {
        self.timeRange = timeRange
        self.text = text
        self.words = words
    }
}

public enum TranscriptAudioEventCategory: String, CaseIterable, Equatable, Sendable {
    case nonSpeech
    case silentPause
    case untranscribedVoicedInterval
    case muted
    case captureGap
}

public struct TranscriptAudioEvent: Equatable, Sendable {
    public let audioEventID: String
    public let category: TranscriptAudioEventCategory
    public let timeRange: TranscriptTimeRange

    public init(
        audioEventID: String,
        category: TranscriptAudioEventCategory,
        timeRange: TranscriptTimeRange
    ) {
        self.audioEventID = audioEventID
        self.category = category
        self.timeRange = timeRange
    }
}

public struct SessionTranscriptProjection: Equatable, Sendable {
    public let lines: [TranscriptLine]
    public let audioEvents: [TranscriptAudioEvent]

    public init(lines: [TranscriptLine], audioEvents: [TranscriptAudioEvent]) {
        self.lines = lines
        self.audioEvents = audioEvents
    }
}

/// An app-only exact Session/Transcript Revision pair. This type deliberately
/// has no Codable or provider-projection conformance.
public struct FrozenTranscriptRevision: Hashable, Sendable {
    public let sessionID: String
    public let revisionID: String

    public init(sessionID: String, revisionID: String) {
        self.sessionID = sessionID
        self.revisionID = revisionID
    }
}

public struct FrozenTranscriptAttachment: Equatable, Sendable {
    public let sessionAttachmentID: String
    public let displayLabel: String
    public let revision: FrozenTranscriptRevision

    public init(
        sessionAttachmentID: String,
        displayLabel: String,
        revision: FrozenTranscriptRevision
    ) {
        self.sessionAttachmentID = sessionAttachmentID
        self.displayLabel = displayLabel
        self.revision = revision
    }
}

public enum FrozenTranscriptReadResult: Equatable, Sendable {
    case available(SessionTranscriptProjection)
    case unavailable
}

public struct FrozenTranscriptReader: Sendable {
    private let implementation: @Sendable (FrozenTranscriptRevision) throws -> FrozenTranscriptReadResult

    public init(
        implementation: @escaping @Sendable (FrozenTranscriptRevision) throws -> FrozenTranscriptReadResult
    ) {
        self.implementation = implementation
    }

    fileprivate func read(_ revision: FrozenTranscriptRevision) throws -> FrozenTranscriptReadResult {
        try implementation(revision)
    }
}

public struct ProviderOnDemandTranscriptAttachment: Equatable, Sendable {
    public let sessionAttachmentID: String
    public let displayLabel: String
    public let sessionTranscriptHandle: String

    fileprivate init(
        sessionAttachmentID: String,
        displayLabel: String,
        sessionTranscriptHandle: String
    ) {
        self.sessionAttachmentID = sessionAttachmentID
        self.displayLabel = displayLabel
        self.sessionTranscriptHandle = sessionTranscriptHandle
    }

    public var canonicalProviderValue: CanonicalJSONValue {
        .object([
            "displayLabel": .string(displayLabel),
            "kind": .string("onDemand"),
            "sessionAttachmentId": .string(sessionAttachmentID),
            "sessionTranscriptHandle": .string(sessionTranscriptHandle),
        ])
    }
}

public struct TranscriptReadCapability: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    private let value: Data

    fileprivate init(value: Data) {
        self.value = value
    }

    var digest: Data {
        Data(SHA256.hash(data: value))
    }

    fileprivate var bearerValue: String {
        value.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(bearerValue: String) {
        var encoded = bearerValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 {
            encoded.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let decoded = Data(base64Encoded: encoded), decoded.count == 32 else {
            return nil
        }
        value = decoded
    }

    public var description: String { "<redacted transcript-read capability>" }
    public var debugDescription: String { description }

    /// Installs the capability into an explicitly named child-environment field
    /// without exposing it through argv, a URL, or model-visible configuration.
    public func installing(
        in environment: [String: String],
        variableName: String
    ) throws -> [String: String] {
        guard Self.isSafeEnvironmentVariableName(variableName) else {
            throw TranscriptReadCapabilityEnvironmentError.invalidVariableName
        }
        var result = environment
        result[variableName] = bearerValue
        return result
    }

    private static func isSafeEnvironmentVariableName(_ value: String) -> Bool {
        value.range(of: #"^[A-Z][A-Z0-9_]{0,63}$"#, options: .regularExpression) != nil
    }
}

public enum TranscriptReadCapabilityEnvironmentError: Error, Equatable, Sendable {
    case invalidVariableName
}

public struct TranscriptReadBrokerLimits: Equatable, Sendable {
    public let maximumRequestBytes: Int
    public let maximumRequestedHandles: Int
    public let maximumDeliveries: Int

    public init(
        maximumRequestBytes: Int = 16 * 1_024,
        maximumRequestedHandles: Int = 32,
        maximumDeliveries: Int = 2
    ) {
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumRequestedHandles = maximumRequestedHandles
        self.maximumDeliveries = maximumDeliveries
    }
}

public enum TranscriptReadResponseKind: String, Equatable, Sendable {
    case complete
    case sessionUnavailable
    case contextCannotFit
}

public struct TranscriptReadDelivery: Equatable, Sendable {
    public let responseBody: Data
    public let kind: TranscriptReadResponseKind
    public let isReplay: Bool
    public let terminatesAttempt: Bool

    fileprivate init(
        responseBody: Data,
        kind: TranscriptReadResponseKind,
        isReplay: Bool,
        terminatesAttempt: Bool
    ) {
        self.responseBody = responseBody
        self.kind = kind
        self.isReplay = isReplay
        self.terminatesAttempt = terminatesAttempt
    }
}

/// Provider-visible adapters intentionally collapse every closed rejection to one
/// reason. Detailed storage, capability, and identity information never crosses
/// this boundary.
public enum TranscriptReadRejection: String, Equatable, Sendable {
    case closed
}

public enum TranscriptReadResult: Equatable, Sendable {
    case delivered(TranscriptReadDelivery)
    case rejected(TranscriptReadRejection)
}

public enum TranscriptReadRevocationReason: String, CaseIterable, Equatable, Sendable {
    case attemptCompleted
    case providerFailed
    case cancelled
    case timedOut
    case launchFailed
    case processExited
    case publicationAuthorityLost
    case protocolFailure
}

public enum TranscriptReadBrokerStatus: Equatable, Sendable {
    case open
    case replayable(deliveriesRemaining: Int)
    case revoked
}

public enum AttemptTranscriptGrantIssueError: Error, Equatable, Sendable {
    case emptyAttachmentSet
    case invalidAttachment
    case duplicateSessionAttachmentID
    case tooManyAttachments
    case invalidLimits
}

public struct AttemptTranscriptGrant: Sendable {
    public let capability: TranscriptReadCapability
    public let providerAttachments: [ProviderOnDemandTranscriptAttachment]
    public let broker: TranscriptReadBroker

    fileprivate init(
        capability: TranscriptReadCapability,
        providerAttachments: [ProviderOnDemandTranscriptAttachment],
        broker: TranscriptReadBroker
    ) {
        self.capability = capability
        self.providerAttachments = providerAttachments
        self.broker = broker
    }

    public func makeMCPBoundary(
        expectedAuthority: String,
        maximumBodyBytes: Int = 32 * 1_024
    ) -> TranscriptReadMCPBoundary {
        TranscriptReadMCPBoundary(
            broker: broker,
            capabilityDigest: capability.digest,
            expectedAuthority: expectedAuthority,
            maximumBodyBytes: maximumBodyBytes
        )
    }
}

public struct AttemptTranscriptGrantIssuer: Sendable {
    public init() {}

    public func issue(
        attachments: [FrozenTranscriptAttachment],
        reader: FrozenTranscriptReader,
        completeResponseBudget: CompleteToolResponseBudget,
        limits: TranscriptReadBrokerLimits = TranscriptReadBrokerLimits()
    ) throws -> AttemptTranscriptGrant {
        guard limits.maximumRequestBytes > 0,
              limits.maximumRequestedHandles > 0,
              (1 ... 2).contains(limits.maximumDeliveries)
        else {
            throw AttemptTranscriptGrantIssueError.invalidLimits
        }
        guard !attachments.isEmpty else {
            throw AttemptTranscriptGrantIssueError.emptyAttachmentSet
        }
        guard attachments.count <= limits.maximumRequestedHandles else {
            throw AttemptTranscriptGrantIssueError.tooManyAttachments
        }

        var attachmentIDs: Set<String> = []
        var frozenByHandle: [String: FrozenTranscriptAttachment] = [:]
        var providerAttachments: [ProviderOnDemandTranscriptAttachment] = []
        for attachment in attachments {
            guard !attachment.sessionAttachmentID.isEmpty,
                  !attachment.displayLabel.isEmpty,
                  !attachment.revision.sessionID.isEmpty,
                  !attachment.revision.revisionID.isEmpty
            else {
                throw AttemptTranscriptGrantIssueError.invalidAttachment
            }
            guard attachmentIDs.insert(attachment.sessionAttachmentID).inserted else {
                throw AttemptTranscriptGrantIssueError.duplicateSessionAttachmentID
            }

            var handle = makeCanonicalHandle()
            while frozenByHandle[handle] != nil {
                handle = makeCanonicalHandle()
            }
            frozenByHandle[handle] = attachment
            providerAttachments.append(
                ProviderOnDemandTranscriptAttachment(
                    sessionAttachmentID: attachment.sessionAttachmentID,
                    displayLabel: attachment.displayLabel,
                    sessionTranscriptHandle: handle
                )
            )
        }

        let capability = TranscriptReadCapability(value: randomBytes(count: 32))
        let broker = TranscriptReadBroker(
            capabilityDigest: capability.digest,
            frozenByHandle: frozenByHandle,
            reader: reader,
            completeResponseBudget: completeResponseBudget,
            limits: limits
        )
        return AttemptTranscriptGrant(
            capability: capability,
            providerAttachments: providerAttachments,
            broker: broker
        )
    }
}

public actor TranscriptReadBroker {
    private enum State {
        case open
        case replayable(
            requestHandles: [String],
            responseBody: Data,
            deliveriesRemaining: Int
        )
        case revoked
    }

    private var state: State = .open
    private var capabilityDigest: Data
    private var frozenByHandle: [String: FrozenTranscriptAttachment]
    private let reader: FrozenTranscriptReader
    private let completeResponseBudget: CompleteToolResponseBudget
    private let limits: TranscriptReadBrokerLimits

    fileprivate init(
        capabilityDigest: Data,
        frozenByHandle: [String: FrozenTranscriptAttachment],
        reader: FrozenTranscriptReader,
        completeResponseBudget: CompleteToolResponseBudget,
        limits: TranscriptReadBrokerLimits
    ) {
        self.capabilityDigest = capabilityDigest
        self.frozenByHandle = frozenByHandle
        self.reader = reader
        self.completeResponseBudget = completeResponseBudget
        self.limits = limits
    }

    /// Atomically processes one semantic read. The method has no suspension point,
    /// so a concurrent revocation linearizes wholly before or after disclosure.
    public func read(
        capability: TranscriptReadCapability,
        requestBody: Data
    ) -> TranscriptReadResult {
        guard case .revoked = state else {
            guard constantTimeEqual(capability.digest, capabilityDigest) else {
                revokeNow()
                return .rejected(.closed)
            }

            let request: ParsedReadRequest
            do {
                request = try parseRequest(requestBody)
            } catch {
                revokeNow()
                return .rejected(.closed)
            }

            switch state {
            case .open:
                return performFirstRead(handles: request.handles)
            case let .replayable(firstHandles, responseBody, deliveriesRemaining):
                guard request.handles == firstHandles, deliveriesRemaining > 0 else {
                    revokeNow()
                    return .rejected(.closed)
                }
                let deliveriesAfterThisOne = deliveriesRemaining - 1
                let exhausted = deliveriesAfterThisOne == 0
                if exhausted {
                    revokeNow()
                } else {
                    state = .replayable(
                        requestHandles: firstHandles,
                        responseBody: responseBody,
                        deliveriesRemaining: deliveriesAfterThisOne
                    )
                }
                return .delivered(
                    TranscriptReadDelivery(
                        responseBody: responseBody,
                        kind: .complete,
                        isReplay: true,
                        terminatesAttempt: exhausted
                    )
                )
            case .revoked:
                return .rejected(.closed)
            }
        }
        return .rejected(.closed)
    }

    public func revoke(reason _: TranscriptReadRevocationReason) {
        revokeNow()
    }

    public func status() -> TranscriptReadBrokerStatus {
        switch state {
        case .open:
            .open
        case let .replayable(_, _, deliveriesRemaining):
            .replayable(deliveriesRemaining: deliveriesRemaining)
        case .revoked:
            .revoked
        }
    }

    private func performFirstRead(handles: [String]) -> TranscriptReadResult {
        var requested: [(handle: String, attachment: FrozenTranscriptAttachment)] = []
        for handle in handles {
            guard let attachment = frozenByHandle[handle] else {
                revokeNow()
                return .rejected(.closed)
            }
            requested.append((handle, attachment))
        }

        var unavailable: [String] = []
        var disclosures: [CanonicalJSONValue] = []
        for item in requested {
            let result: FrozenTranscriptReadResult
            do {
                result = try reader.read(item.attachment.revision)
            } catch {
                result = .unavailable
            }

            switch result {
            case let .available(transcript) where transcript.isValid:
                disclosures.append(
                    .object([
                        "sessionAttachmentId": .string(item.attachment.sessionAttachmentID),
                        "transcript": transcript.canonicalValue,
                    ])
                )
            case .available, .unavailable:
                unavailable.append(item.handle)
            }
        }

        if !unavailable.isEmpty {
            let responseBody = CanonicalJSON.serialize(
                .object([
                    "kind": .string("sessionUnavailable"),
                    "unavailableSessionTranscriptHandles": .array(
                        unavailable.map(CanonicalJSONValue.string)
                    ),
                ])
            )
            revokeNow()
            return .delivered(
                TranscriptReadDelivery(
                    responseBody: responseBody,
                    kind: .sessionUnavailable,
                    isReplay: false,
                    terminatesAttempt: true
                )
            )
        }

        let completeBody = CanonicalJSON.serialize(
            .object([
                "kind": .string("complete"),
                "transcripts": .array(disclosures),
            ])
        )
        let fits: Bool
        do {
            fits = try completeResponseBudget.admits(canonicalResponse: completeBody)
        } catch {
            revokeNow()
            return .rejected(.closed)
        }
        guard fits else {
            let responseBody = CanonicalJSON.serialize(
                .object(["kind": .string("contextCannotFit")])
            )
            revokeNow()
            return .delivered(
                TranscriptReadDelivery(
                    responseBody: responseBody,
                    kind: .contextCannotFit,
                    isReplay: false,
                    terminatesAttempt: true
                )
            )
        }

        let deliveriesRemaining = limits.maximumDeliveries - 1
        let exhausted = deliveriesRemaining == 0
        if exhausted {
            revokeNow()
        } else {
            state = .replayable(
                requestHandles: handles,
                responseBody: completeBody,
                deliveriesRemaining: deliveriesRemaining
            )
        }
        return .delivered(
            TranscriptReadDelivery(
                responseBody: completeBody,
                kind: .complete,
                isReplay: false,
                terminatesAttempt: exhausted
            )
        )
    }

    private func parseRequest(_ body: Data) throws -> ParsedReadRequest {
        guard body.count <= limits.maximumRequestBytes else {
            throw RequestParsingError.invalid
        }
        guard !hasDuplicateObjectKeys(body),
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(object.keys) == ["sessionTranscriptHandles"],
              let handles = object["sessionTranscriptHandles"] as? [String],
              !handles.isEmpty,
              handles.count <= limits.maximumRequestedHandles,
              Set(handles).count == handles.count,
              handles.allSatisfy(isCanonicalHandle)
        else {
            throw RequestParsingError.invalid
        }
        return ParsedReadRequest(handles: handles)
    }

    private func revokeNow() {
        state = .revoked
        capabilityDigest.resetBytes(in: 0 ..< capabilityDigest.count)
        capabilityDigest.removeAll(keepingCapacity: false)
        frozenByHandle.removeAll(keepingCapacity: false)
    }
}

private struct ParsedReadRequest {
    let handles: [String]
}

private enum RequestParsingError: Error {
    case invalid
}

private extension SessionTranscriptProjection {
    var isValid: Bool {
        var evidenceIDs: Set<String> = []
        for line in lines {
            guard line.timeRange.isValid,
                  !line.text.isEmpty,
                  !line.words.isEmpty
            else {
                return false
            }
            for word in line.words {
                guard !word.wordID.isEmpty,
                      !word.text.isEmpty,
                      evidenceIDs.insert(word.wordID).inserted,
                      word.timeRange?.isValid ?? true
                else {
                    return false
                }
            }
        }
        for event in audioEvents {
            guard !event.audioEventID.isEmpty,
                  evidenceIDs.insert(event.audioEventID).inserted,
                  event.timeRange.isValid
            else {
                return false
            }
        }
        return true
    }

    var canonicalValue: CanonicalJSONValue {
        .object([
            "audioEvents": .array(audioEvents.map(\.canonicalValue)),
            "lines": .array(lines.map(\.canonicalValue)),
        ])
    }
}

private extension TranscriptTimeRange {
    var isValid: Bool {
        startMs >= 0 && startMs <= endMs && endMs <= Int(Int32.max)
    }

    var canonicalValue: CanonicalJSONValue {
        .object([
            "endMs": .integer(Int64(endMs)),
            "startMs": .integer(Int64(startMs)),
        ])
    }
}

private extension TranscriptWord {
    var canonicalValue: CanonicalJSONValue {
        var value: [String: CanonicalJSONValue] = [
            "text": .string(text),
            "wordId": .string(wordID),
        ]
        if let timeRange {
            value["timeRange"] = timeRange.canonicalValue
        }
        return .object(value)
    }
}

private extension TranscriptLine {
    var canonicalValue: CanonicalJSONValue {
        .object([
            "text": .string(text),
            "timeRange": timeRange.canonicalValue,
            "words": .array(words.map(\.canonicalValue)),
        ])
    }
}

private extension TranscriptAudioEvent {
    var canonicalValue: CanonicalJSONValue {
        .object([
            "audioEventId": .string(audioEventID),
            "category": .string(category.rawValue),
            "timeRange": timeRange.canonicalValue,
        ])
    }
}

private func randomBytes(count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}

private func makeCanonicalHandle() -> String {
    var bytes = [UInt8](randomBytes(count: 16))
    bytes[6] = (bytes[6] & 0x0f) | 0x40
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }
    return [
        hex[0 ... 3].joined(),
        hex[4 ... 5].joined(),
        hex[6 ... 7].joined(),
        hex[8 ... 9].joined(),
        hex[10 ... 15].joined(),
    ].joined(separator: "-")
}

private func isCanonicalHandle(_ value: String) -> Bool {
    value.range(
        of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
        options: .regularExpression
    ) != nil
}

private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    var difference = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
    let count = max(lhs.count, rhs.count)
    for index in 0 ..< count {
        let left = index < lhs.count ? lhs[index] : 0
        let right = index < rhs.count ? rhs[index] : 0
        difference |= left ^ right
    }
    return difference == 0
}

/// Detects duplicate keys in the top-level request object before Foundation can
/// collapse them. Nested values are arrays of strings, so only this object owns
/// provider-controlled keys at the broker seam.
func hasDuplicateObjectKeys(_ data: Data) -> Bool {
    guard let source = String(data: data, encoding: .utf8) else {
        return true
    }
    let scalars = Array(source.unicodeScalars)
    var index = 0
    struct ObjectFrame {
        var keys: Set<String> = []
        var expectsKey = true
    }
    enum ContainerFrame {
        case object(ObjectFrame)
        case array
    }
    var stack: [ContainerFrame] = []

    while index < scalars.count {
        let scalar = scalars[index]
        if scalar == "\"" {
            let start = index
            index += 1
            var escaped = false
            while index < scalars.count {
                let current = scalars[index]
                if escaped {
                    escaped = false
                } else if current == "\\" {
                    escaped = true
                } else if current == "\"" {
                    break
                }
                index += 1
            }
            guard index < scalars.count else { return true }
            if case var .object(frame) = stack.last, frame.expectsKey {
                let literal = String(String.UnicodeScalarView(scalars[start ... index]))
                guard let literalData = literal.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(String.self, from: literalData),
                      frame.keys.insert(decoded).inserted
                else {
                    return true
                }
                frame.expectsKey = false
                stack[stack.count - 1] = .object(frame)
            }
        } else {
            switch scalar {
            case "{":
                stack.append(.object(ObjectFrame()))
            case "}":
                guard case .object = stack.popLast() else { return true }
            case "[":
                stack.append(.array)
            case "]":
                guard case .array = stack.popLast() else { return true }
            case ",":
                if case var .object(frame) = stack.last {
                    frame.expectsKey = true
                    stack[stack.count - 1] = .object(frame)
                }
            default:
                break
            }
        }
        index += 1
    }
    return false
}
