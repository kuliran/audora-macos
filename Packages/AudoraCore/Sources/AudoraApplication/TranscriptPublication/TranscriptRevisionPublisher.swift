import AudoraDomain

public struct ReopenedTranscriptRevisionSnapshot: Equatable, Sendable {
    public let revisionIDs: [TranscriptRevisionID]
    public let selectedRevisionID: TranscriptRevisionID
    public let selectedRevision: TranscriptRevision

    public init(
        revisionIDs: [TranscriptRevisionID],
        selectedRevisionID: TranscriptRevisionID,
        selectedRevision: TranscriptRevision
    ) {
        self.revisionIDs = revisionIDs
        self.selectedRevisionID = selectedRevisionID
        self.selectedRevision = selectedRevision
    }
}

public enum TranscriptRevisionRepositoryFailure: Error, Equatable, Sendable {
    case sessionUnavailable
    case sessionIntegrityMismatch
    case unsupportedSchema
    case staleSelection
    case revisionCollision
    case writeFailed
    case installedNeedsRefresh
}

public protocol TranscriptRevisionRepository: Sendable {
    /// Installs the complete immutable Revision and switches the Session selection
    /// as one authority boundary. A failure before that switch retains the exact
    /// prior selection; a post-switch reopen failure reports `installedNeedsRefresh`.
    func publishAndSelect(
        _ revision: TranscriptRevision,
        expectedSelectedRevisionID: TranscriptRevisionID?
    ) async throws -> ReopenedTranscriptRevisionSnapshot

    func reopenSelected(
        sessionID: SessionID
    ) async throws -> ReopenedTranscriptRevisionSnapshot
}

public enum TranscriptPublicationFailure: Error, Equatable, Sendable {
    case invalidCandidate(TranscriptCandidateValidationError)
    case sessionUnavailable
    case sessionIntegrityMismatch
    case unsupportedSchema
    case staleSelection
    case revisionCollision
    case writeFailed
    case installedNeedsRefresh
    case inconsistentReopen
}

public enum TranscriptPublicationOutcome: Equatable, Sendable {
    case published(ReopenedTranscriptRevisionSnapshot)
    case rejected(TranscriptPublicationFailure)
}

public enum TranscriptRevisionReferenceResult: Equatable, Sendable {
    case available(ReopenedTranscriptRevisionSnapshot)
    case unavailable
    case unsupportedSchema
}

public struct TranscriptRevisionReferenceReader: Sendable {
    private let repository: any TranscriptRevisionRepository

    public init(repository: any TranscriptRevisionRepository) {
        self.repository = repository
    }

    public func reopenSelected(
        sessionID: SessionID
    ) async -> TranscriptRevisionReferenceResult {
        do {
            return .available(try await repository.reopenSelected(sessionID: sessionID))
        } catch TranscriptRevisionRepositoryFailure.unsupportedSchema {
            return .unsupportedSchema
        } catch {
            return .unavailable
        }
    }
}

public struct TranscriptRevisionPublisher: Sendable {
    private let validator: TranscriptCandidateValidator
    private let repository: any TranscriptRevisionRepository

    public init(
        validator: TranscriptCandidateValidator = TranscriptCandidateValidator(),
        repository: any TranscriptRevisionRepository
    ) {
        self.validator = validator
        self.repository = repository
    }

    public func publish(
        _ candidate: TranscriptionCandidate,
        context: TranscriptPublicationContext,
        expectedSelectedRevisionID: TranscriptRevisionID?
    ) async -> TranscriptPublicationOutcome {
        let revision: TranscriptRevision
        do {
            revision = try validator.validate(candidate, against: context)
        } catch let error as TranscriptCandidateValidationError {
            return .rejected(.invalidCandidate(error))
        } catch {
            return .rejected(.invalidCandidate(.integrityMismatch))
        }

        do {
            let reopened = try await repository.publishAndSelect(
                revision,
                expectedSelectedRevisionID: expectedSelectedRevisionID
            )
            guard reopened.selectedRevisionID == revision.revisionID,
                  reopened.selectedRevision == revision,
                  reopened.revisionIDs.contains(revision.revisionID)
            else {
                return .rejected(.inconsistentReopen)
            }
            return .published(reopened)
        } catch let failure as TranscriptRevisionRepositoryFailure {
            return .rejected(Self.map(failure))
        } catch {
            return .rejected(.writeFailed)
        }
    }

    private static func map(
        _ failure: TranscriptRevisionRepositoryFailure
    ) -> TranscriptPublicationFailure {
        switch failure {
        case .sessionUnavailable: .sessionUnavailable
        case .sessionIntegrityMismatch: .sessionIntegrityMismatch
        case .unsupportedSchema: .unsupportedSchema
        case .staleSelection: .staleSelection
        case .revisionCollision: .revisionCollision
        case .writeFailed: .writeFailed
        case .installedNeedsRefresh: .installedNeedsRefresh
        }
    }
}
