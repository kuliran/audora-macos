import AudoraApplication

enum NewChatAttachmentPickerPresentation {
    static let contextCannotFitRecoveryText =
        "These Sessions cannot fit together in this coach's context. Remove a Session."
    static let providerUnavailableRecoveryText =
        "Coach transport is temporarily unavailable. You can create this Chat locally and try coaching later."

    static func recoveryText(for issue: ChatAttachmentPickerIssue) -> String {
        switch issue {
        case let .selectionLimitReached(maximum):
            "You can attach up to \(maximum) Sessions. Deselect a Session before adding another."
        case .attachmentUnavailable:
            "A selected Session changed or is no longer available. Change the selection and try again."
        case .contextCannotFit:
            contextCannotFitRecoveryText
        case .contextUnavailable:
            "Current Coach context could not be verified. Change the selection or reopen New Chat to try again."
        }
    }

    static func accessibilityAnnouncement(for issue: ChatAttachmentPickerIssue) -> String {
        "New Chat: \(recoveryText(for: issue))"
    }
}
