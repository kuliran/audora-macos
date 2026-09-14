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
        case let .contextUnavailable(reason):
            CoachContextUnavailablePresentation.recoveryText(for: reason)
        case .qualifiedConfigurationUnavailable:
            "No qualified Coach configuration is available. Check again after installing a configuration update."
        }
    }

    static func accessibilityAnnouncement(for issue: ChatAttachmentPickerIssue) -> String {
        "New Chat: \(recoveryText(for: issue))"
    }
}

enum CoachContextUnavailablePresentation {
    static func recoveryText(for reason: CoachContextUnavailableReason) -> String {
        switch reason {
        case .externalProcessingDisallowed:
            "Coach processing is blocked because this context includes transcript-derived material whose engine policy does not permit external processing."
        case .externalProcessingPolicyUnavailable:
            "Coach processing is blocked because the engine policy for supporting transcript evidence could not be verified."
        case .providerUnavailable:
            "Coach transport is temporarily unavailable. Try again later."
        case .sourceUnavailable:
            "Current Coach context could not be loaded. Reopen the Chat and try again."
        case .staleState:
            "Current Coach context changed while it was being prepared. Refresh and try again."
        case .invalidContext:
            "Current Coach context could not be verified. Change the selection or reopen the Chat to try again."
        }
    }
}

struct NewChatCreationContextPresentation: Equatable, Sendable {
    private enum Basis: Equatable, Sendable {
        case live
        case lowerBound
    }

    let usedTokens: Int
    let maximumTokens: Int
    let profileContribution: String?
    private let basis: Basis

    var summary: String {
        switch basis {
        case .live:
            "~\(usedTokens) / \(maximumTokens) total context tokens"
        case .lowerBound:
            "At least ~\(usedTokens) / \(maximumTokens) total context tokens"
        }
    }

    var accessibilityLabel: String {
        switch basis {
        case .live:
            "Estimated total context, \(usedTokens) of \(maximumTokens) tokens"
        case .lowerBound:
            "Minimum total context, at least \(usedTokens) of \(maximumTokens) tokens"
        }
    }

    init(_ quote: CoachContextQuote) {
        self.init(
            totalContextTokens: quote.totalContextTokens,
            inputCeilingTokens: quote.inputCeilingTokens,
            reservedResponseTokens: quote.reservedResponseTokens,
            safetyMarginTokens: quote.safetyMarginTokens,
            profileTokens: quote.categoryCosts[.profile]?.estimatedTokenCount
        )
    }

    init(
        totalContextTokens: Int,
        inputCeilingTokens: Int,
        reservedResponseTokens: Int,
        safetyMarginTokens: Int,
        profileTokens: Int?
    ) {
        self.init(
            basis: .live,
            usedTokens: totalContextTokens,
            inputCeilingTokens: inputCeilingTokens,
            reservedResponseTokens: reservedResponseTokens,
            safetyMarginTokens: safetyMarginTokens,
            profileContribution: profileTokens.map {
                "Current Profile: ~\($0) tokens"
            }
        )
    }

    init(_ lowerBound: ChatCreationCapacityLowerBound) {
        self.init(
            minimumTotalContextTokens: lowerBound.minimumTotalContextTokens,
            inputCeilingTokens: lowerBound.inputCeilingTokens,
            reservedResponseTokens: lowerBound.reservedResponseTokens,
            safetyMarginTokens: lowerBound.safetyMarginTokens,
            minimumProfileTokens:
                lowerBound.minimumCategoryCosts[.profile]?.estimatedTokenCount
        )
    }

    init(
        minimumTotalContextTokens: Int,
        inputCeilingTokens: Int,
        reservedResponseTokens: Int,
        safetyMarginTokens: Int,
        minimumProfileTokens: Int?
    ) {
        self.init(
            basis: .lowerBound,
            usedTokens: minimumTotalContextTokens,
            inputCeilingTokens: inputCeilingTokens,
            reservedResponseTokens: reservedResponseTokens,
            safetyMarginTokens: safetyMarginTokens,
            profileContribution: minimumProfileTokens.map {
                "Profile lower bound: ~\($0) tokens"
            }
        )
    }

    private init(
        basis: Basis,
        usedTokens: Int,
        inputCeilingTokens: Int,
        reservedResponseTokens: Int,
        safetyMarginTokens: Int,
        profileContribution: String?
    ) {
        self.usedTokens = usedTokens
        maximumTokens = inputCeilingTokens + reservedResponseTokens + safetyMarginTokens
        self.profileContribution = profileContribution
        self.basis = basis
    }
}
