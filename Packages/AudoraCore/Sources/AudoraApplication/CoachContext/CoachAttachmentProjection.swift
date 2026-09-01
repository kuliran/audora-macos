import AudoraDomain
import Foundation

@_spi(CoachContextQualification)
public enum CoachAttachmentProjectionPolicyError: Error, Equatable, Sendable {
    case invalidMaximumInlineTranscriptTokens
}

enum CoachAttachmentProjectionError: Error, Equatable, Sendable {
    case canonicalTranscriptTooLarge
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
            canonicalTranscript: canonicalTranscript,
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
    public let approximateTranscriptTokens: Int
    public let delivery: ChatAttachmentDelivery
    private let evidence: ChatAttachmentEvidence

    init(
        evidence: ChatAttachmentEvidence,
        canonicalTranscript: CanonicalJSONValue,
        approximateTranscriptTokens: Int,
        delivery: ChatAttachmentDelivery
    ) {
        self.evidence = evidence
        self.canonicalTranscript = canonicalTranscript
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
            "displayLabel": .string(evidence.displayLabel),
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
        configuration: CoachContextConfigurationStamp
    )
    case configurationChanged
    case qualifiedConfigurationUnavailable
    case attachmentUnavailable
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

/// Application decorator that turns verified immutable transcript evidence into
/// the picker/reopen projection consumed by Chat use cases.
actor ProjectedChatSessionAttachmentSource:
    ChatSessionAttachmentSource,
    ChatAttachmentCapacityPreparing
{
    private let evidenceSource: any ChatSessionAttachmentEvidenceSource
    private let configurationAuthority:
        any CoachAttachmentProjectionConfigurationAuthority

    init(
        evidenceSource: any ChatSessionAttachmentEvidenceSource,
        configurationAuthority:
            any CoachAttachmentProjectionConfigurationAuthority
    ) {
        self.evidenceSource = evidenceSource
        self.configurationAuthority = configurationAuthority
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
        case .completed:
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
        case .completed:
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
            policy: configuration.policy
        )
        switch await evidenceSource.forEachResolvedEvidence(
            attachments,
            in: library,
            accumulator.visit
        ) {
        case .completed:
            guard !Task.isCancelled else { return .failed }
            guard await configurationAuthority.isCurrent(configuration.stamp) else {
                return .configurationChanged
            }
            guard let prepared = accumulator.prepared else {
                return .attachmentUnavailable
            }
            return .prepared(prepared, configuration: configuration.stamp)
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
    private var invalid = false

    init(
        attachments: ChatAttachments,
        policy: CoachAttachmentProjectionPolicy
    ) {
        self.attachments = attachments.values
        self.policy = policy
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

    private func capacityHandle(index: Int) throws -> PreparedCoachTranscriptHandle {
        try PreparedCoachTranscriptHandle(
            String(format: "00000000-0000-0000-0000-%012x", index + 1)
        )
    }
}
