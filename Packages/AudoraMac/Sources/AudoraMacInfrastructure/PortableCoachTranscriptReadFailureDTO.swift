import AudoraDomain

struct PortableCoachTranscriptReadFailureSummaryDTO: Codable {
    let sessions: [PortableCoachTranscriptReadFailureSessionDTO]
    let additionalSessionCount: UInt8

    init(_ summary: CoachTranscriptReadFailureSummary) {
        sessions = summary.sessions.map(
            PortableCoachTranscriptReadFailureSessionDTO.init
        )
        additionalSessionCount = summary.additionalSessionCount
    }

    func domainValue() throws -> CoachTranscriptReadFailureSummary {
        try CoachTranscriptReadFailureSummary(
            sessions: sessions.map { try $0.domainValue() },
            additionalSessionCount: additionalSessionCount
        )
    }
}

struct PortableCoachTranscriptReadFailureSessionDTO: Codable {
    let sessionAttachmentId: String
    let displayLabel: String

    init(_ session: CoachTranscriptReadFailureSession) {
        sessionAttachmentId = session.sessionAttachmentID.rawValue
        displayLabel = session.displayLabel
    }

    func domainValue() throws -> CoachTranscriptReadFailureSession {
        try CoachTranscriptReadFailureSession(
            sessionAttachmentID: ChatSessionAttachmentID(sessionAttachmentId),
            displayLabel: displayLabel
        )
    }
}
