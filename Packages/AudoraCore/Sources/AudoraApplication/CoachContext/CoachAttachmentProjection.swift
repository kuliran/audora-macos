import AudoraDomain
import Foundation

@_spi(CoachContextQualification)
public enum CoachAttachmentProjectionPolicyError: Error, Equatable, Sendable {
    case invalidMaximumInlineTranscriptTokens
}

enum CoachAttachmentProjectionError: Error, Equatable, Sendable {
    case canonicalTranscriptTooLarge
}

/// A provider-facing label derived at the same boundary that replaces local
/// Session/Revision identity with the Chat-scoped attachment identity.
private struct CoachProviderAttachmentDisplayLabel: Equatable, Sendable {
    private static let fallback = "Attached Session"
    private static let edgeSeparators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "·•|,;:/()[]{}"))

    let rawValue: String

    init(evidence: ChatAttachmentEvidence) {
        let localIdentifiers = [
            evidence.sessionID.rawValue,
            evidence.transcriptRevisionID.rawValue,
        ]
        var projected = evidence.displayLabel
        for identifier in localIdentifiers {
            projected = projected.replacingOccurrences(
                of: identifier,
                with: "",
                options: [.caseInsensitive, .literal]
            )
        }
        projected = projected
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: Self.edgeSeparators)

        let containsLocalIdentifier = localIdentifiers.contains { identifier in
            projected.range(of: identifier, options: [.caseInsensitive, .literal])
                != nil
        }
        guard !projected.isEmpty,
              projected.unicodeScalars.count <=
                ChatAttachmentCandidate.maximumDisplayLabelUnicodeScalars,
              !projected.unicodeScalars.contains(where: {
                  $0.value == 0 || $0.properties.generalCategory == .control
              }),
              !containsLocalIdentifier
        else {
            rawValue = Self.fallback
            return
        }
        rawValue = projected
    }
}

/// Measures the exact canonical representation before permitting its serialized
/// byte allocation.
/// The internal seam keeps the production 64 MiB limit fixed while allowing tests
/// to prove that serialization and token estimation never run after a failed bound.
struct BoundedCanonicalTranscriptEncoder: Sendable {
    private let measure:
        @Sendable (CanonicalJSONValue, Int) throws -> Int
    private let serialize: @Sendable (CanonicalJSONValue) -> Data

    init(
        measure: @escaping @Sendable (CanonicalJSONValue, Int) throws -> Int,
        serialize: @escaping @Sendable (CanonicalJSONValue) -> Data
    ) {
        self.measure = measure
        self.serialize = serialize
    }

    func encode(
        _ value: CanonicalJSONValue,
        maximumByteCount: Int
    ) throws -> Data {
        let measuredByteCount = try measure(value, maximumByteCount)
        guard measuredByteCount >= 0 else {
            throw CanonicalJSONMeasurementError.integerOverflow
        }
        guard measuredByteCount <= maximumByteCount else {
            throw CanonicalJSONMeasurementError.byteLimitExceeded
        }
        return serialize(value)
    }

    static let canonicalJSON = BoundedCanonicalTranscriptEncoder(
        measure: { value, maximumByteCount in
            try CanonicalJSON.byteCount(
                of: value,
                maximumByteCount: maximumByteCount
            )
        },
        serialize: CanonicalJSON.serialize
    )
}

/// The qualified provider/model policy shared by picker estimates and final
/// context preparation. It measures one complete canonical `SessionTranscript`
/// value, preserving tokenizer boundaries and JSON overhead.
@_spi(CoachContextQualification)
public struct CoachAttachmentProjectionPolicy: Sendable {
    public let maximumInlineTranscriptTokens: Int
    public let tokenEstimator: CoachTokenEstimator
    private let canonicalTranscriptEncoder: BoundedCanonicalTranscriptEncoder

    public init(
        maximumInlineTranscriptTokens: Int,
        tokenEstimator: CoachTokenEstimator
    ) throws {
        try self.init(
            maximumInlineTranscriptTokens: maximumInlineTranscriptTokens,
            tokenEstimator: tokenEstimator,
            canonicalTranscriptEncoder: .canonicalJSON
        )
    }

    init(
        maximumInlineTranscriptTokens: Int,
        tokenEstimator: CoachTokenEstimator,
        canonicalTranscriptEncoder: BoundedCanonicalTranscriptEncoder
    ) throws {
        guard maximumInlineTranscriptTokens > 0 else {
            throw CoachAttachmentProjectionPolicyError
                .invalidMaximumInlineTranscriptTokens
        }
        self.maximumInlineTranscriptTokens = maximumInlineTranscriptTokens
        self.tokenEstimator = tokenEstimator
        self.canonicalTranscriptEncoder = canonicalTranscriptEncoder
    }

    public func project(
        evidence: ChatAttachmentEvidence
    ) throws -> CoachAttachmentProjection {
        let canonicalTranscript = Self.canonicalTranscript(evidence.revision)
        let canonicalBytes: Data
        do {
            canonicalBytes = try canonicalTranscriptEncoder.encode(
                canonicalTranscript,
                maximumByteCount:
                    CoachContextInputLimits.maximumCanonicalValueUTF8Bytes
            )
        } catch CanonicalJSONMeasurementError.byteLimitExceeded {
            throw CoachAttachmentProjectionError.canonicalTranscriptTooLarge
        }
        let approximateTranscriptTokens = try tokenEstimator.tokenCount(
            forUTF8: canonicalBytes
        )
        return CoachAttachmentProjection(
            evidence: evidence,
            providerDisplayLabel: CoachProviderAttachmentDisplayLabel(
                evidence: evidence
            ),
            canonicalTranscript: canonicalTranscript,
            canonicalTranscriptUTF8ByteCount: canonicalBytes.count,
            approximateTranscriptTokens: approximateTranscriptTokens,
            delivery: approximateTranscriptTokens <= maximumInlineTranscriptTokens
                ? .inline
                : .onDemand
        )
    }

    private static func canonicalTranscript(
        _ revision: TranscriptRevision
    ) -> CanonicalJSONValue {
        .object([
            "audioEvents": .array(revision.audioEvents.map { event in
                .object([
                    "audioEventId": .string(event.audioEventID.rawValue),
                    "category": .string(event.category.rawValue),
                    "timeRange": canonicalTimeRange(event.timeRange),
                ])
            }),
            "lines": .array(revision.lines.map { line in
                .object([
                    "text": .string(line.text),
                    "timeRange": canonicalTimeRange(line.timeRange),
                    "words": .array(line.words.map(canonicalWord)),
                ])
            }),
        ])
    }

    private static func canonicalWord(_ word: TranscriptWord) -> CanonicalJSONValue {
        var fields: [String: CanonicalJSONValue] = [
            "text": .string(word.text),
            "wordId": .string(word.wordID.rawValue),
        ]
        if let timeRange = word.timeRange {
            fields["timeRange"] = canonicalTimeRange(timeRange)
        }
        return .object(fields)
    }

    private static func canonicalTimeRange(
        _ range: SessionTimeRange
    ) -> CanonicalJSONValue {
        .object([
            "endMs": .integer(Int64(range.endMilliseconds)),
            "startMs": .integer(Int64(range.startMilliseconds)),
        ])
    }
}

@_spi(CoachContextQualification)
public struct CoachAttachmentProjection: Equatable, Sendable {
    public let canonicalTranscript: CanonicalJSONValue
    public let canonicalTranscriptUTF8ByteCount: Int
    public let approximateTranscriptTokens: Int
    public let delivery: ChatAttachmentDelivery
    private let evidence: ChatAttachmentEvidence
    private let providerDisplayLabel: CoachProviderAttachmentDisplayLabel

    fileprivate init(
        evidence: ChatAttachmentEvidence,
        providerDisplayLabel: CoachProviderAttachmentDisplayLabel,
        canonicalTranscript: CanonicalJSONValue,
        canonicalTranscriptUTF8ByteCount: Int,
        approximateTranscriptTokens: Int,
        delivery: ChatAttachmentDelivery
    ) {
        self.evidence = evidence
        self.providerDisplayLabel = providerDisplayLabel
        self.canonicalTranscript = canonicalTranscript
        self.canonicalTranscriptUTF8ByteCount = canonicalTranscriptUTF8ByteCount
        self.approximateTranscriptTokens = approximateTranscriptTokens
        self.delivery = delivery
    }

    public func makeCandidate() throws -> ChatAttachmentCandidate {
        try ChatAttachmentCandidate(
            sessionID: evidence.sessionID,
            transcriptRevisionID: evidence.transcriptRevisionID,
            displayLabel: evidence.displayLabel,
            durationMilliseconds: evidence.durationMilliseconds,
            approximateTranscriptTokens: approximateTranscriptTokens,
            delivery: delivery
        )
    }

    public func prepareAttachment(
        attachment: ChatSessionAttachment,
        transcriptHandle: PreparedCoachTranscriptHandle
    ) throws -> PreparedCoachAttachment {
        guard attachment.sessionID == evidence.sessionID,
              attachment.transcriptRevisionID == evidence.transcriptRevisionID
        else {
            throw ChatAttachmentResolutionError.identityMismatch
        }
        let sessionAttachmentID = attachment.attachmentID
        let base: [String: CanonicalJSONValue] = [
            "displayLabel": .string(providerDisplayLabel.rawValue),
            "sessionAttachmentId": .string(sessionAttachmentID.rawValue),
        ]
        switch delivery {
        case .inline:
            return .inline(
                requestValue: .object(base.merging([
                    "kind": .string("inline"),
                    "transcript": canonicalTranscript,
                ]) { _, new in new })
            )
        case .onDemand:
            return .onDemand(
                requestValue: .object(base.merging([
                    "kind": .string("onDemand"),
                    "sessionTranscriptHandle": .string(transcriptHandle.rawValue),
                ]) { _, new in new }),
                sessionTranscriptHandle: transcriptHandle,
                transcriptDisclosure: .object([
                    "sessionAttachmentId": .string(sessionAttachmentID.rawValue),
                    "transcript": canonicalTranscript,
                ])
            )
        }
    }
}

enum ChatAttachmentCapacityPreparationOutcome: Sendable {
    case prepared(
        [PreparedCoachAttachment],
        configuration: CoachContextConfigurationStamp,
        evidenceAuthority: ChatCreationEvidenceAuthority
    )
    case configurationChanged
    case qualifiedConfigurationUnavailable
    case attachmentUnavailable
    case invalidContext
    case failed
}

protocol ChatAttachmentCapacityPreparing: Sendable {
    func prepareCapacityAttachments(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentCapacityPreparationOutcome
}

struct UnavailableChatAttachmentCapacityPreparer:
    ChatAttachmentCapacityPreparing
{
    func prepareCapacityAttachments(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentCapacityPreparationOutcome {
        .failed
    }
}

/// Internal snapshot-fixture adapter used when context tests intentionally omit
/// portable attachment persistence. Product composition always installs the
/// projected persistence adapter below.
struct ConfigurationBoundEmptyChatAttachmentCapacityPreparer:
    ChatAttachmentCapacityPreparing
{
    let configurationAuthorityID: UUID
    private let evidenceAuthority = ChatCreationEvidenceAuthority(
        testingValue: UUID()
    )

    func prepareCapacityAttachments(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentCapacityPreparationOutcome {
        return .prepared(
            [],
            configuration: CoachContextConfigurationStamp(
                authorityID: configurationAuthorityID,
                generation: 0
            ),
            evidenceAuthority: evidenceAuthority
        )
    }
}

/// Application decorator that turns verified immutable transcript evidence into
/// the picker/reopen projection consumed by Chat use cases.
actor ProjectedChatSessionAttachmentSource:
    ChatSessionAttachmentSource,
    ChatAttachmentCapacityPreparing
{
    private let evidenceSource: any ChatSessionAttachmentEvidenceSource
    private let configurationAuthority:
        any CoachAttachmentProjectionConfigurationAuthority
    private let maximumAggregateCanonicalTranscriptBytes: Int

    init(
        evidenceSource: any ChatSessionAttachmentEvidenceSource,
        configurationAuthority:
            any CoachAttachmentProjectionConfigurationAuthority,
        maximumAggregateCanonicalTranscriptBytes: Int =
            CoachContextInputLimits.maximumAggregateCanonicalUTF8Bytes
    ) {
        self.evidenceSource = evidenceSource
        self.configurationAuthority = configurationAuthority
        self.maximumAggregateCanonicalTranscriptBytes =
            maximumAggregateCanonicalTranscriptBytes
    }

    func loadCandidates(
        in library: LibraryScope
    ) async -> ChatAttachmentCatalogOutcome {
        guard case let .configured(configuration) =
            await configurationAuthority
                .currentAttachmentProjectionConfiguration()
        else {
            return .qualifiedConfigurationUnavailable
        }
        let accumulator = ChatAttachmentCandidateProjectionAccumulator(
            policy: configuration.policy
        )
        switch await evidenceSource.forEachEvidence(
            in: library,
            accumulator.visit
        ) {
        case .completed, .completedWithAuthority:
            guard !Task.isCancelled else { return .failed }
            guard await configurationAuthority.isCurrent(configuration.stamp) else {
                return .configurationChanged
            }
            return .loaded(
                accumulator.candidates,
                configuration: configuration.stamp
            )
        case .readOnlyLibrary:
            return .readOnlyLibrary
        case .failed:
            return .failed
        }
    }

    func resolve(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome {
        guard case let .configured(configuration) =
            await configurationAuthority
                .currentAttachmentProjectionConfiguration()
        else {
            return .qualifiedConfigurationUnavailable
        }
        let accumulator = ResolvedChatAttachmentProjectionAccumulator(
            policy: configuration.policy
        )
        switch await evidenceSource.forEachResolvedEvidence(
            attachments,
            in: library,
            accumulator.visit
        ) {
        case .completed, .completedWithAuthority:
            guard !Task.isCancelled else { return .failed }
            guard await configurationAuthority.isCurrent(configuration.stamp) else {
                return .configurationChanged
            }
            return .resolved(
                accumulator.resolutions,
                configuration: configuration.stamp
            )
        case .readOnlyLibrary:
            return .readOnlyLibrary
        case .failed:
            return .failed
        }
    }

    func prepareCapacityAttachments(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentCapacityPreparationOutcome {
        guard case let .configured(configuration) =
            await configurationAuthority
                .currentAttachmentProjectionConfiguration()
        else {
            return .qualifiedConfigurationUnavailable
        }
        let accumulator = CapacityAttachmentProjectionAccumulator(
            attachments: attachments,
            policy: configuration.policy,
            maximumAggregateCanonicalTranscriptBytes:
                maximumAggregateCanonicalTranscriptBytes
        )
        switch await evidenceSource.forEachResolvedEvidence(
            attachments,
            in: library,
            accumulator.visit
        ) {
        case let .completedWithAuthority(evidenceAuthority):
            guard !Task.isCancelled else { return .failed }
            guard !accumulator.exhaustedAggregateTranscriptBudget else {
                return .invalidContext
            }
            guard await configurationAuthority.isCurrent(configuration.stamp) else {
                return .configurationChanged
            }
            guard let prepared = accumulator.prepared else {
                return .attachmentUnavailable
            }
            return .prepared(
                prepared,
                configuration: configuration.stamp,
                evidenceAuthority: evidenceAuthority
            )
        case .completed:
            // A persistence adapter that cannot bind the exact active root and
            // evidence bytes is not creation authority.
            return .failed
        case .failed where accumulator.exhaustedAggregateTranscriptBudget:
            return .invalidContext
        case .readOnlyLibrary, .failed:
            return .failed
        }
    }
}

private final class ChatAttachmentCandidateProjectionAccumulator:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let policy: CoachAttachmentProjectionPolicy
    private var projected: [ChatAttachmentCandidate] = []

    init(policy: CoachAttachmentProjectionPolicy) {
        self.policy = policy
    }

    func visit(_ evidence: ChatAttachmentEvidence) throws {
        try Task.checkCancellation()
        do {
            let candidate = try policy.project(evidence: evidence).makeCandidate()
            try lock.withLock {
                guard projected.count < ChatAttachmentCandidate.maximumCatalogCount
                else { throw ChatAttachmentCatalogError.tooManyCandidates }
                projected.append(candidate)
            }
        } catch is ChatAttachmentCandidateError {
            return
        } catch CoachAttachmentProjectionError.canonicalTranscriptTooLarge {
            return
        }
    }

    var candidates: [ChatAttachmentCandidate] {
        lock.withLock { projected }
    }
}

private final class ResolvedChatAttachmentProjectionAccumulator:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let policy: CoachAttachmentProjectionPolicy
    private var projected: [ResolvedChatAttachment] = []

    init(policy: CoachAttachmentProjectionPolicy) {
        self.policy = policy
    }

    func visit(_ item: ResolvedChatAttachmentEvidence) throws {
        try Task.checkCancellation()
        let resolution: ChatAttachmentResolution
        switch item.resolution {
        case let .available(evidence):
            resolution = .available(
                try policy.project(evidence: evidence).makeCandidate()
            )
        case let .unavailable(reason):
            resolution = .unavailable(reason)
        }
        let value = try ResolvedChatAttachment(
            attachment: item.attachment,
            resolution: resolution
        )
        try lock.withLock {
            guard projected.count < ChatAttachments.maximumCount else {
                throw ChatAttachmentsError.tooManyAttachments
            }
            projected.append(value)
        }
    }

    var resolutions: [ResolvedChatAttachment] {
        lock.withLock { projected }
    }
}

private final class CapacityAttachmentProjectionAccumulator:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let attachments: [ChatSessionAttachment]
    private let policy: CoachAttachmentProjectionPolicy
    private var values: [PreparedCoachAttachment] = []
    private var aggregateTranscriptBudget: CoachContextAggregateBudget
    private var invalid = false
    private var aggregateTranscriptBudgetExhausted = false

    init(
        attachments: ChatAttachments,
        policy: CoachAttachmentProjectionPolicy,
        maximumAggregateCanonicalTranscriptBytes: Int
    ) {
        self.attachments = attachments.values
        self.policy = policy
        aggregateTranscriptBudget = CoachContextAggregateBudget(
            maximumByteCount: maximumAggregateCanonicalTranscriptBytes
        )
    }

    func visit(_ item: ResolvedChatAttachmentEvidence) throws {
        try Task.checkCancellation()
        try lock.withLock {
            let index = values.count
            guard !invalid,
                  index < attachments.count,
                  item.attachment == attachments[index],
                  case let .available(evidence) = item.resolution
            else {
                invalid = true
                return
            }
            let projection = try policy.project(evidence: evidence)
            do {
                try aggregateTranscriptBudget.consume(
                    projection.canonicalTranscriptUTF8ByteCount
                )
            } catch {
                aggregateTranscriptBudgetExhausted = true
                throw error
            }
            values.append(
                try projection.prepareAttachment(
                    attachment: item.attachment,
                    transcriptHandle: capacityHandle(index: index)
                )
            )
        }
    }

    var prepared: [PreparedCoachAttachment]? {
        lock.withLock {
            guard !invalid, values.count == attachments.count else { return nil }
            return values
        }
    }

    var exhaustedAggregateTranscriptBudget: Bool {
        lock.withLock { aggregateTranscriptBudgetExhausted }
    }

    private func capacityHandle(index: Int) throws -> PreparedCoachTranscriptHandle {
        try PreparedCoachTranscriptHandle(
            String(format: "00000000-0000-0000-0000-%012x", index + 1)
        )
    }
}
