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
    public static let maximumDisplayLabelUTF8Bytes = 256
    public static let maximumApproximateTranscriptTokens = 16 * 1_024 * 1_024
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
              displayLabel.utf8.count <= Self.maximumDisplayLabelUTF8Bytes,
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

    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue.utf8.count <= 256 else {
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
    case unavailable(CoachContextUnavailableReason)

    public var permitsCreation: Bool {
        switch self {
        case .quoting:
            false
        case let .available(quote):
            quote.context.fits
        case .unavailable(.providerUnavailable):
            true
        case .unavailable:
            false
        }
    }
}

public struct ChatAttachmentPickerSnapshot: Equatable, Sendable {
    public let allRows: [ChatAttachmentPickerRow]
    public let visibleRows: [ChatAttachmentPickerRow]
    public let selectedAttachmentIDs: Set<ChatSessionAttachmentID>
    public let filterQuery: ChatAttachmentFilterQuery
    public let feasibility: ChatCreationFeasibility

    public var selectionCount: Int { selectedAttachmentIDs.count }

    init(
        allRows: [ChatAttachmentPickerRow],
        visibleRows: [ChatAttachmentPickerRow],
        selectedAttachmentIDs: Set<ChatSessionAttachmentID>,
        filterQuery: ChatAttachmentFilterQuery,
        feasibility: ChatCreationFeasibility
    ) {
        self.allRows = allRows
        self.visibleRows = visibleRows
        self.selectedAttachmentIDs = selectedAttachmentIDs
        self.filterQuery = filterQuery
        self.feasibility = feasibility
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

public enum ChatAttachmentCatalogOutcome: Equatable, Sendable {
    case loaded([ChatAttachmentCandidate])
    case readOnlyLibrary
    case failed
}

public enum ChatAttachmentResolutionOutcome: Equatable, Sendable {
    case resolved([ResolvedChatAttachment])
    case readOnlyLibrary
    case failed
}

/// The single local seam for listing selected revisions and reopening exact pins.
public protocol ChatSessionAttachmentSource: Sendable {
    func loadCandidates(in library: LibraryScope) async -> ChatAttachmentCatalogOutcome
    func resolve(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome
}

public struct UnavailableChatSessionAttachmentSource: ChatSessionAttachmentSource {
    public init() {}

    public func loadCandidates(
        in library: LibraryScope
    ) async -> ChatAttachmentCatalogOutcome {
        .failed
    }

    public func resolve(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome {
        .failed
    }
}
