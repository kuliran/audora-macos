import AudoraApplication
import AudoraDomain

struct ProfileUpdateDividerPresentation: Equatable, Hashable, Sendable {
    static let text = "Profile was updated"

    let statementGeneration: UInt64

    var visibleText: String { Self.text }
    var accessibilityLabel: String { Self.text }
}

enum ChatTimelineEntryPresentation: Equatable, Sendable, Identifiable {
    enum ID: Hashable {
        case profileUpdate(UInt64)
        case message(ChatMessageID)
    }

    case profileUpdate(ProfileUpdateDividerPresentation)
    case message(ChatMessage)

    var id: ID {
        switch self {
        case let .profileUpdate(divider):
            .profileUpdate(divider.statementGeneration)
        case let .message(message):
            .message(message.id)
        }
    }
}

enum ChatTimelineTailPlacement: Equatable, Sendable {
    case afterSuccessfulContent
    case afterPendingUserTurn
    case afterProfileEffectCard
    case afterProfileReconsideration
    case deferred
}

enum ChatTimelinePendingActionPlacement: Equatable, Sendable {
    case beforePendingUserTurn
    case beforeProfileReconsiderationResult
}

/// A pure projection of durable Chat/Profile provenance. Divider entries never
/// become Chat events and never depend on wall-clock ordering.
struct ChatTimelinePresentation: Equatable, Sendable {
    let successfulHistory: [ChatTimelineEntryPresentation]
    let profileEffectProfileUpdate: ProfileUpdateDividerPresentation?
    let pendingActionProfileUpdate: ProfileUpdateDividerPresentation?
    let pendingActionPlacement: ChatTimelinePendingActionPlacement?
    let tailProfileUpdate: ProfileUpdateDividerPresentation?
    let tailPlacement: ChatTimelineTailPlacement?

    static func project(
        _ aggregate: ChatAggregate,
        state: ChatFeatureState
    ) -> Self {
        // An aggregate may deliberately omit loaded message bodies. Without
        // their per-turn Profile provenance, deriving a divider would invent
        // chronology, so wait until the complete successful history is open.
        guard aggregate.chat.messageIDs.count == aggregate.messages.count else {
            return Self(
                successfulHistory: aggregate.messages.map(Self.messageEntry),
                profileEffectProfileUpdate: nil,
                pendingActionProfileUpdate: nil,
                pendingActionPlacement: nil,
                tailProfileUpdate: nil,
                tailPlacement: nil
            )
        }

        let history = projectSuccessfulHistory(aggregate)
        var latestPresentedGeneration = history.latestGeneration

        let profileEffectProfileUpdate: ProfileUpdateDividerPresentation?
        if let generation = messageFreeProfileEffectGeneration(in: aggregate),
            generation > latestPresentedGeneration
        {
            profileEffectProfileUpdate = ProfileUpdateDividerPresentation(
                statementGeneration: generation
            )
            latestPresentedGeneration = generation
        } else {
            profileEffectProfileUpdate = nil
        }

        let pendingAction = pendingAction(in: aggregate, state: state)
        let pendingActionProfileUpdate: ProfileUpdateDividerPresentation?
        let pendingActionPlacement: ChatTimelinePendingActionPlacement?
        if let preparedGeneration = pendingAction?.preparedGeneration,
            preparedGeneration > latestPresentedGeneration
        {
            pendingActionProfileUpdate = ProfileUpdateDividerPresentation(
                statementGeneration: preparedGeneration
            )
            pendingActionPlacement = pendingAction?.placement
            latestPresentedGeneration = preparedGeneration
        } else {
            pendingActionProfileUpdate = nil
            pendingActionPlacement = nil
        }

        guard let currentGeneration = state.currentProfileStatementGeneration,
            currentGeneration > latestPresentedGeneration
        else {
            return Self(
                successfulHistory: history.entries,
                profileEffectProfileUpdate: profileEffectProfileUpdate,
                pendingActionProfileUpdate: pendingActionProfileUpdate,
                pendingActionPlacement: pendingActionPlacement,
                tailProfileUpdate: nil,
                tailPlacement: nil
            )
        }

        let placement: ChatTimelineTailPlacement
        switch pendingAction {
        case .none:
            placement = aggregate.profileEffect == nil
                ? .afterSuccessfulContent
                : .afterProfileEffectCard
        case .pendingUserTurn(_, isProcessing: true),
            .profileReconsideration(_, isProcessing: true):
            placement = .deferred
        case .pendingUserTurn:
            placement = .afterPendingUserTurn
        case .profileReconsideration:
            placement = .afterProfileReconsideration
        }

        return Self(
            successfulHistory: history.entries,
            profileEffectProfileUpdate: profileEffectProfileUpdate,
            pendingActionProfileUpdate: pendingActionProfileUpdate,
            pendingActionPlacement: pendingActionPlacement,
            tailProfileUpdate: ProfileUpdateDividerPresentation(
                statementGeneration: currentGeneration
            ),
            tailPlacement: placement
        )
    }

    private struct SuccessfulHistoryProjection {
        let entries: [ChatTimelineEntryPresentation]
        let latestGeneration: UInt64
    }

    private enum PendingAction {
        case pendingUserTurn(
            preparedGeneration: UInt64?,
            isProcessing: Bool
        )
        case profileReconsideration(
            preparedGeneration: UInt64?,
            isProcessing: Bool
        )

        var preparedGeneration: UInt64? {
            switch self {
            case let .pendingUserTurn(generation, _),
                 let .profileReconsideration(generation, _):
                generation
            }
        }

        var placement: ChatTimelinePendingActionPlacement {
            switch self {
            case .pendingUserTurn:
                .beforePendingUserTurn
            case .profileReconsideration:
                .beforeProfileReconsiderationResult
            }
        }
    }

    private static func projectSuccessfulHistory(
        _ aggregate: ChatAggregate
    ) -> SuccessfulHistoryProjection {
        var entries: [ChatTimelineEntryPresentation] = []
        var latestGeneration =
            aggregate.chat.profileStatementGenerationAtCreation
        var index = aggregate.messages.startIndex

        while index < aggregate.messages.endIndex {
            let first = aggregate.messages[index]
            let groupEnd: Int
            let coachMessage: ChatMessage

            switch first.content {
            case .coach:
                coachMessage = first
                groupEnd = index + 1
            case .user:
                let coachIndex = index + 1
                guard coachIndex < aggregate.messages.endIndex else {
                    // ChatAggregate validation normally makes this impossible.
                    // Keeping the partial projection marker-free is safer than
                    // fabricating an action boundary from malformed input.
                    entries.append(.message(first))
                    return SuccessfulHistoryProjection(
                        entries: entries,
                        latestGeneration: latestGeneration
                    )
                }
                coachMessage = aggregate.messages[coachIndex]
                groupEnd = coachIndex + 1
            }

            if let generation = coachMessage.coachProfile?.statementGeneration,
                generation > latestGeneration
            {
                entries.append(
                    .profileUpdate(
                        ProfileUpdateDividerPresentation(
                            statementGeneration: generation
                        )
                    )
                )
                latestGeneration = generation
            }

            for messageIndex in index ..< groupEnd {
                entries.append(.message(aggregate.messages[messageIndex]))
            }
            index = groupEnd
        }

        return SuccessfulHistoryProjection(
            entries: entries,
            latestGeneration: latestGeneration
        )
    }

    private static func pendingAction(
        in aggregate: ChatAggregate,
        state: ChatFeatureState
    ) -> PendingAction? {
        if let pending = aggregate.pendingUserTurn {
            let authorityGeneration: UInt64?
            if let authority = state.coachInvocationStopAuthority,
                authority.chatID == aggregate.chat.id,
                authority.pendingUserTurnID == pending.id
            {
                authorityGeneration =
                    authority.preparedProfile.statementGeneration
            } else {
                authorityGeneration = nil
            }
            let preparedGeneration =
                latestGeneration(
                    pending.preparedProfileStatementGeneration,
                    authorityGeneration
                )
            return .pendingUserTurn(
                preparedGeneration: preparedGeneration,
                isProcessing: pending.failure == nil
                    && !state.isCoachResponseRetryableFailure(pending)
            )
        }

        if let reconsideration = aggregate.profileReconsideration {
            let authorityGeneration: UInt64?
            if let authority = state.profileReconsiderationStopAuthority,
                authority.chatID == aggregate.chat.id,
                authority.sourceEffectIdentity ==
                    reconsideration.sourceEffectIdentity,
                authority.resultResponsePositionID ==
                    reconsideration.resultResponsePositionID
            {
                authorityGeneration =
                    authority.preparedProfile.statementGeneration
            } else {
                authorityGeneration = nil
            }
            let preparedGeneration =
                latestGeneration(
                    reconsideration.preparedProfileStatementGeneration,
                    authorityGeneration
                )
            return .profileReconsideration(
                preparedGeneration: preparedGeneration,
                isProcessing: reconsideration.failure == nil
                    && !state.isProfileReconsiderationRetryableFailure(
                        reconsideration
                    )
            )
        }

        return nil
    }

    private static func messageFreeProfileEffectGeneration(
        in aggregate: ChatAggregate
    ) -> UInt64? {
        guard let proposal = aggregate.profileProposal,
            !aggregate.messages.contains(where: {
                $0.responsePositionID == proposal.responsePositionID
            })
        else { return nil }

        return proposal.baseProfile.statementGeneration
    }

    private static func latestGeneration(
        _ first: UInt64?,
        _ second: UInt64?
    ) -> UInt64? {
        switch (first, second) {
        case let (.some(first), .some(second)):
            max(first, second)
        case let (.some(first), .none):
            first
        case let (.none, .some(second)):
            second
        case (.none, .none):
            nil
        }
    }

    private static func messageEntry(
        _ message: ChatMessage
    ) -> ChatTimelineEntryPresentation {
        .message(message)
    }
}
