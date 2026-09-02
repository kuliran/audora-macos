import AudoraDomain
import Foundation

public enum ChatAttachmentDelivery: String, Equatable, Sendable {
    case inline
    case onDemand
}

public enum ChatAttachmentCandidateError: Error, Equatable, Sendable {
    case invalidDisplayLabel
    case invalidDuration
    case invalidTranscriptCost
}

public enum ChatAttachmentCatalogError: Error, Equatable, Sendable {
    case tooManyCandidates
}

/// One selected Transcript Revision eligible for a prospective Chat.
///
/// The Session/Revision pair is the immutable identity. Presentation metadata is
/// advisory and is reloaded without changing that pair when an existing Chat opens.
public struct ChatAttachmentCandidate: Equatable, Sendable {
    public static let maximumCatalogCount = 32_768
    public static let maximumDisplayLabelUnicodeScalars = 256
    public static let maximumApproximateTranscriptTokens =
        CoachContextInputLimits.maximumCanonicalValueUTF8Bytes
    public let sessionID: SessionID
    public let transcriptRevisionID: TranscriptRevisionID
    public let displayLabel: String
    public let durationMilliseconds: UInt64
    public let approximateTranscriptTokens: Int
    public let delivery: ChatAttachmentDelivery

    public init(
        sessionID: SessionID,
        transcriptRevisionID: TranscriptRevisionID,
        displayLabel: String,
        durationMilliseconds: UInt64,
        approximateTranscriptTokens: Int,
        delivery: ChatAttachmentDelivery
    ) throws {
        guard !displayLabel.isEmpty,
              displayLabel.unicodeScalars.count <=
                Self.maximumDisplayLabelUnicodeScalars,
              !displayLabel.unicodeScalars.contains(where: {
                  $0.value == 0 || $0.properties.generalCategory == .control
              })
        else {
            throw ChatAttachmentCandidateError.invalidDisplayLabel
        }
        guard durationMilliseconds > 0, durationMilliseconds <= 2_700_000 else {
            throw ChatAttachmentCandidateError.invalidDuration
        }
        guard approximateTranscriptTokens >= 0,
              approximateTranscriptTokens <= Self.maximumApproximateTranscriptTokens
        else {
            throw ChatAttachmentCandidateError.invalidTranscriptCost
        }
        self.sessionID = sessionID
        self.transcriptRevisionID = transcriptRevisionID
        self.displayLabel = displayLabel
        self.durationMilliseconds = durationMilliseconds
        self.approximateTranscriptTokens = approximateTranscriptTokens
        self.delivery = delivery
    }
}

public enum ChatAttachmentFilterQueryError: Error, Equatable, Sendable {
    case tooLong
    case invalidCharacter
}

public struct ChatAttachmentFilterQuery: Hashable, Sendable {
    public static let empty = try! ChatAttachmentFilterQuery("")
    public static let maximumUnicodeScalars = 256

    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue.unicodeScalars.count <= Self.maximumUnicodeScalars else {
            throw ChatAttachmentFilterQueryError.tooLong
        }
        guard !rawValue.unicodeScalars.contains(where: {
            $0.value == 0 || $0.properties.generalCategory == .control
        }) else {
            throw ChatAttachmentFilterQueryError.invalidCharacter
        }
        self.rawValue = rawValue
    }
}

public struct ChatAttachmentPickerRow: Equatable, Identifiable, Sendable {
    public let attachment: ChatSessionAttachment
    public let displayLabel: String
    public let durationMilliseconds: UInt64
    public let approximateTranscriptTokens: Int
    public let delivery: ChatAttachmentDelivery

    public var id: ChatSessionAttachmentID { attachment.attachmentID }

    init(attachment: ChatSessionAttachment, candidate: ChatAttachmentCandidate) {
        self.attachment = attachment
        displayLabel = candidate.displayLabel
        durationMilliseconds = candidate.durationMilliseconds
        approximateTranscriptTokens = candidate.approximateTranscriptTokens
        delivery = candidate.delivery
    }
}

public enum ChatCreationFeasibility: Equatable, Sendable {
    case quoting
    case available(ChatCreationQuote)
    case providerUnavailable(ChatCreationCapacityLowerBound)
    case unavailable(CoachContextUnavailableReason)

    public var permitsCreation: Bool {
        switch self {
        case .quoting:
            false
        case let .available(quote):
            quote.context.fits
        case let .providerUnavailable(lowerBound):
            !lowerBound.provesImpossible
        case .unavailable:
            false
        }
    }
}

public enum ChatAttachmentPickerIssue: Equatable, Sendable {
    case selectionLimitReached(maximum: Int)
    case attachmentUnavailable
    case contextCannotFit
    case contextUnavailable(CoachContextUnavailableReason)
    case qualifiedConfigurationUnavailable

    public var blocksConfirmation: Bool {
        switch self {
        case .selectionLimitReached:
            false
        case .attachmentUnavailable, .contextCannotFit, .contextUnavailable,
             .qualifiedConfigurationUnavailable:
            true
        }
    }
}

/// Opaque authority for one exact new-Chat proposal and its displayed quote.
/// Presentation may only carry this value back; it has no stable serialization.
public struct NewChatConfirmationToken: Equatable, Sendable {
    private let value: UUID

    init() {
        value = UUID()
    }

    @_spi(ChatConfirmationTesting)
    public init(testingValue: UUID) {
        value = testingValue
    }
}

/// Opaque Infrastructure-issued authority binding one quoted new-Chat proposal
/// to the exact active Library workspace and verified transcript bytes. The
/// Application may compare and carry this value, but cannot derive filesystem
/// location or evidence fingerprints from it.
public struct ChatCreationEvidenceAuthority: Equatable, Sendable {
    private enum Provenance: Equatable, Sendable {
        case portablePersistence
        case testFixture
    }

    private let opaqueIdentifier: UUID
    private let provenance: Provenance

    @_spi(CoachContextQualification)
    public init(portableOpaqueIdentifier: UUID) {
        opaqueIdentifier = portableOpaqueIdentifier
        provenance = .portablePersistence
    }

    @_spi(CoachContextQualification)
    public var portableOpaqueIdentifier: UUID { opaqueIdentifier }

    @_spi(ChatCreationAuthorityTesting)
    public init(testingValue: UUID) {
        opaqueIdentifier = testingValue
        provenance = .testFixture
    }

    var requiresExactPreparedEvidence: Bool {
        provenance == .portablePersistence
    }
}

public struct ChatAttachmentPickerSnapshot: Equatable, Sendable {
    public let allRows: [ChatAttachmentPickerRow]
    public let visibleRows: [ChatAttachmentPickerRow]
    public let selectedAttachmentIDs: Set<ChatSessionAttachmentID>
    public let filterQuery: ChatAttachmentFilterQuery
    public let feasibility: ChatCreationFeasibility
    public let issue: ChatAttachmentPickerIssue?
    public let confirmationToken: NewChatConfirmationToken?

    public var selectionCount: Int { selectedAttachmentIDs.count }
    public var permitsConfirmation: Bool {
        confirmationToken != nil && feasibility.permitsCreation &&
            issue?.blocksConfirmation != true
    }

    public init(
        allRows: [ChatAttachmentPickerRow],
        visibleRows: [ChatAttachmentPickerRow],
        selectedAttachmentIDs: Set<ChatSessionAttachmentID>,
        filterQuery: ChatAttachmentFilterQuery,
        feasibility: ChatCreationFeasibility,
        issue: ChatAttachmentPickerIssue? = nil,
        confirmationToken: NewChatConfirmationToken? = nil
    ) {
        self.allRows = allRows
        self.visibleRows = visibleRows
        self.selectedAttachmentIDs = selectedAttachmentIDs
        self.filterQuery = filterQuery
        self.feasibility = feasibility
        self.issue = issue
        self.confirmationToken = confirmationToken
    }
}

public enum NewChatAttachmentPickerState: Equatable, Sendable {
    case closed
    case loading
    case ready(ChatAttachmentPickerSnapshot)
    case failed
}

public enum OpenedChatAttachmentsState: Equatable, Sendable {
    case notRequested
    case resolving(ChatAttachments)
    case resolved([ResolvedChatAttachment])
    case failed
}

public enum ChatAttachmentUnavailableReason: String, Equatable, Sendable {
    case missing
    case inTrash
    case corrupt
    case unsupportedSchema
}

public enum ChatAttachmentResolution: Equatable, Sendable {
    case available(ChatAttachmentCandidate)
    case unavailable(ChatAttachmentUnavailableReason)
}

public enum ChatAttachmentResolutionError: Error, Equatable, Sendable {
    case identityMismatch
}

public struct ResolvedChatAttachment: Equatable, Sendable {
    public let attachment: ChatSessionAttachment
    public let resolution: ChatAttachmentResolution

    public init(
        attachment: ChatSessionAttachment,
        resolution: ChatAttachmentResolution
    ) throws {
        if case let .available(candidate) = resolution {
            guard candidate.sessionID == attachment.sessionID,
                  candidate.transcriptRevisionID == attachment.transcriptRevisionID
            else {
                throw ChatAttachmentResolutionError.identityMismatch
            }
        }
        self.attachment = attachment
        self.resolution = resolution
    }
}

struct CoachContextConfigurationStamp: Equatable, Sendable {
    let authorityID: UUID
    let generation: UInt64
}

enum ChatAttachmentCatalogOutcome: Equatable, Sendable {
    case loaded(
        [ChatAttachmentCandidate],
        configuration: CoachContextConfigurationStamp
    )
    case configurationChanged
    case qualifiedConfigurationUnavailable
    case readOnlyLibrary
    case failed
}

enum ChatAttachmentResolutionOutcome: Equatable, Sendable {
    case resolved(
        [ResolvedChatAttachment],
        configuration: CoachContextConfigurationStamp
    )
    case configurationChanged
    case qualifiedConfigurationUnavailable
    case readOnlyLibrary
    case failed
}

/// Hash-verified canonical evidence returned by a persistence adapter before any
/// provider/model policy is applied.
@_spi(CoachContextQualification)
public struct ChatAttachmentEvidence: Equatable, Sendable {
    /// A persistence adapter must reject a Revision larger than this before
    /// allocating its encoded bytes for Chat projection.
    public static let maximumLoadedRevisionBytes =
        CoachContextInputLimits.maximumCanonicalValueUTF8Bytes

    public let displayLabel: String
    public let revision: TranscriptRevision

    public var sessionID: SessionID { revision.sessionID }
    public var transcriptRevisionID: TranscriptRevisionID { revision.revisionID }
    public var durationMilliseconds: UInt64 { revision.durationMilliseconds }

    public init(displayLabel: String, revision: TranscriptRevision) {
        self.displayLabel = displayLabel
        self.revision = revision
    }
}

@_spi(CoachContextQualification)
public enum ChatAttachmentEvidenceResolution: Equatable, Sendable {
    case available(ChatAttachmentEvidence)
    case unavailable(ChatAttachmentUnavailableReason)
}

@_spi(CoachContextQualification)
public struct ResolvedChatAttachmentEvidence: Equatable, Sendable {
    public let attachment: ChatSessionAttachment
    public let resolution: ChatAttachmentEvidenceResolution

    public init(
        attachment: ChatSessionAttachment,
        resolution: ChatAttachmentEvidenceResolution
    ) throws {
        if case let .available(evidence) = resolution {
            guard evidence.sessionID == attachment.sessionID,
                  evidence.transcriptRevisionID == attachment.transcriptRevisionID
            else {
                throw ChatAttachmentResolutionError.identityMismatch
            }
        }
        self.attachment = attachment
        self.resolution = resolution
    }
}

@_spi(CoachContextQualification)
public enum ChatAttachmentEvidenceTraversalOutcome: Equatable, Sendable {
    case completed
    case completedWithAuthority(ChatCreationEvidenceAuthority)
    case readOnlyLibrary
    case failed
}

/// Persistence-only seam. Provider token estimation and delivery policy are
/// intentionally applied by the visitor supplied by the Application decorator,
/// never by this port. Implementations must invoke the visitor serially and
/// release each full Transcript Revision before loading the next one. A thrown
/// visitor or cancelled traversal must terminate with `.failed`.
@_spi(CoachContextQualification)
public protocol ChatSessionAttachmentEvidenceSource: Sendable {
    func forEachEvidence(
        in library: LibraryScope,
        _ visit: @escaping @Sendable (ChatAttachmentEvidence) throws -> Void
    ) async -> ChatAttachmentEvidenceTraversalOutcome
    func forEachResolvedEvidence(
        _ attachments: ChatAttachments,
        in library: LibraryScope,
        _ visit: @escaping @Sendable (ResolvedChatAttachmentEvidence) throws -> Void
    ) async -> ChatAttachmentEvidenceTraversalOutcome
}

/// The single local seam for listing selected revisions and reopening exact pins.
protocol ChatSessionAttachmentSource: Sendable {
    func loadCandidates(in library: LibraryScope) async -> ChatAttachmentCatalogOutcome
    func resolve(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome
}

struct UnavailableChatSessionAttachmentSource: ChatSessionAttachmentSource {
    init() {}

    func loadCandidates(
        in library: LibraryScope
    ) async -> ChatAttachmentCatalogOutcome {
        .failed
    }

    func resolve(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome {
        .failed
    }
}

struct MissingQualifiedConfigurationChatSessionAttachmentSource:
    ChatSessionAttachmentSource
{
    init() {}

    func loadCandidates(
        in library: LibraryScope
    ) async -> ChatAttachmentCatalogOutcome {
        .qualifiedConfigurationUnavailable
    }

    func resolve(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome {
        .qualifiedConfigurationUnavailable
    }
}
