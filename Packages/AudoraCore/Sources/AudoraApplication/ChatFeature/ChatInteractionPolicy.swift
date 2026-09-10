public enum ChatInteractionPolicy {
    public static func allowsNavigationAndMutation(in state: ChatFeatureState) -> Bool {
        guard case .ready = state.catalog, state.activity == nil else { return false }
        if case .opening = state.selection { return false }
        return true
    }

    public static func allowsCoachInvocation(in state: ChatFeatureState) -> Bool {
        guard state.admissionAvailability == .available else { return false }
        if case let .open(aggregate) = state.selection {
            return aggregate.profileEffect == nil
        }
        return true
    }

    public static func allowsComposerEditing(in state: ChatFeatureState) -> Bool {
        guard case let .open(aggregate) = state.selection else { return false }
        return aggregate.pendingUserTurn == nil &&
            aggregate.profileEffect == nil
    }

    public static func allowsProfileReconsideration(
        in state: ChatFeatureState
    ) -> Bool {
        guard case let .open(aggregate) = state.selection,
              let review = state.profileEffectReview,
              case .stale = review,
              aggregate.profileEffect?.identity == review.sourceEffectIdentity,
              aggregate.profileReconsideration == nil
        else { return false }
        return aggregate.pendingUserTurn == nil && state.activity == nil &&
            state.admissionAvailability == .available
    }
}
