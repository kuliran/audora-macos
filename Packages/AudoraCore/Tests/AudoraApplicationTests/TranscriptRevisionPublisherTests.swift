@testable import AudoraApplication
import AudoraDomain
import XCTest

final class TranscriptRevisionPublisherTests: XCTestCase {
    func testMalformedCandidateExposesNoPartialRevisionAndKeepsPriorSelection() async throws {
        let fixture = try TranscriptCandidateFixture()
        let priorID = try TranscriptRevisionID("trv-20260830T115000000Z-2CDE")
        let repository = ScriptedTranscriptRevisionRepository(selectedRevisionID: priorID)
        let publisher = TranscriptRevisionPublisher(repository: repository)
        let malformed = fixture.candidate.replacingIdentity(sessionID: "ses-20260830T120001000Z-9XYZ")

        let outcome = await publisher.publish(
            malformed,
            context: fixture.context,
            expectedSelectedRevisionID: priorID
        )

        XCTAssertEqual(outcome, .rejected(.invalidCandidate(.identityMismatch)))
        let publishCallCount = await repository.publishCallCount
        let selectedRevisionID = await repository.selectedRevisionID
        XCTAssertEqual(publishCallCount, 0)
        XCTAssertEqual(selectedRevisionID, priorID)
    }

    func testValidCandidateIsPublishedAndSelectedThroughOneAtomicRepositoryCall() async throws {
        let fixture = try TranscriptCandidateFixture()
        let repository = ScriptedTranscriptRevisionRepository(selectedRevisionID: nil)
        let publisher = TranscriptRevisionPublisher(repository: repository)

        let outcome = await publisher.publish(
            fixture.candidate,
            context: fixture.context,
            expectedSelectedRevisionID: nil
        )

        guard case let .published(snapshot) = outcome else {
            return XCTFail("expected complete publication, got \(outcome)")
        }
        XCTAssertEqual(snapshot.selectedRevisionID, fixture.context.revisionID)
        XCTAssertEqual(snapshot.selectedRevision.lines.count, 2)
        let publishCallCount = await repository.publishCallCount
        let selectedRevisionID = await repository.selectedRevisionID
        XCTAssertEqual(publishCallCount, 1)
        XCTAssertEqual(selectedRevisionID, fixture.context.revisionID)
    }

    func testAtomicRepositoryFailureCannotChangePriorSelection() async throws {
        let fixture = try TranscriptCandidateFixture()
        let priorID = try TranscriptRevisionID("trv-20260830T115000000Z-2CDE")
        let repository = ScriptedTranscriptRevisionRepository(
            selectedRevisionID: priorID,
            failure: .writeFailed
        )
        let publisher = TranscriptRevisionPublisher(repository: repository)

        let outcome = await publisher.publish(
            fixture.candidate,
            context: fixture.context,
            expectedSelectedRevisionID: priorID
        )

        XCTAssertEqual(outcome, .rejected(.writeFailed))
        let publishCallCount = await repository.publishCallCount
        let selectedRevisionID = await repository.selectedRevisionID
        XCTAssertEqual(publishCallCount, 1)
        XCTAssertEqual(selectedRevisionID, priorID)
    }

    func testUnsupportedRepositorySchemaRemainsDistinctAtApplicationBoundary() async throws {
        let fixture = try TranscriptCandidateFixture()
        let repository = ScriptedTranscriptRevisionRepository(
            selectedRevisionID: nil,
            failure: .unsupportedSchema
        )
        let publisher = TranscriptRevisionPublisher(repository: repository)

        let outcome = await publisher.publish(
            fixture.candidate,
            context: fixture.context,
            expectedSelectedRevisionID: nil
        )

        XCTAssertEqual(outcome, .rejected(.unsupportedSchema))
    }

    func testReferenceReaderDistinguishesUnsupportedSchemaFromUnavailableRevision() async throws {
        let sessionID = try SessionID("ses-20260830T120000000Z-3DEF")
        let unsupportedRepository = ScriptedTranscriptRevisionRepository(
            selectedRevisionID: nil,
            reopenFailure: .unsupportedSchema
        )
        let unavailableRepository = ScriptedTranscriptRevisionRepository(
            selectedRevisionID: nil,
            reopenFailure: .sessionIntegrityMismatch
        )

        let unsupported = await TranscriptRevisionReferenceReader(
            repository: unsupportedRepository
        ).reopenSelected(sessionID: sessionID)
        let unavailable = await TranscriptRevisionReferenceReader(
            repository: unavailableRepository
        ).reopenSelected(sessionID: sessionID)

        XCTAssertEqual(unsupported, .unsupportedSchema)
        XCTAssertEqual(unavailable, .unavailable)
    }
}

private actor ScriptedTranscriptRevisionRepository: TranscriptRevisionRepository {
    private(set) var selectedRevisionID: TranscriptRevisionID?
    private(set) var publishCallCount = 0
    private let failure: TranscriptRevisionRepositoryFailure?
    private let reopenFailure: TranscriptRevisionRepositoryFailure?

    init(
        selectedRevisionID: TranscriptRevisionID?,
        failure: TranscriptRevisionRepositoryFailure? = nil,
        reopenFailure: TranscriptRevisionRepositoryFailure? = nil
    ) {
        self.selectedRevisionID = selectedRevisionID
        self.failure = failure
        self.reopenFailure = reopenFailure
    }

    func publishAndSelect(
        _ revision: TranscriptRevision,
        expectedSelectedRevisionID: TranscriptRevisionID?
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        publishCallCount += 1
        guard selectedRevisionID == expectedSelectedRevisionID else {
            throw TranscriptRevisionRepositoryFailure.staleSelection
        }
        if let failure { throw failure }
        selectedRevisionID = revision.revisionID
        return ReopenedTranscriptRevisionSnapshot(
            revisionIDs: [revision.revisionID],
            selectedRevisionID: revision.revisionID,
            selectedRevision: revision
        )
    }

    func reopenSelected(
        sessionID _: SessionID
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        if let reopenFailure { throw reopenFailure }
        throw TranscriptRevisionRepositoryFailure.sessionUnavailable
    }

    func reopenRevision(
        sessionID _: SessionID,
        revisionID _: TranscriptRevisionID
    ) async throws -> TranscriptRevision {
        if let reopenFailure { throw reopenFailure }
        throw TranscriptRevisionRepositoryFailure.sessionUnavailable
    }
}

private extension TranscriptionCandidate {
    func replacingIdentity(sessionID: String) -> Self {
        Self(
            schemaVersion: schemaVersion,
            jobID: jobID,
            sessionID: sessionID,
            revisionID: revisionID,
            durationMilliseconds: durationMilliseconds,
            audioFingerprintSHA256: audioFingerprintSHA256,
            sourceFingerprints: sourceFingerprints,
            candidateArtifactSHA256: candidateArtifactSHA256,
            engine: engine,
            lines: lines,
            audioEvents: audioEvents
        )
    }
}
