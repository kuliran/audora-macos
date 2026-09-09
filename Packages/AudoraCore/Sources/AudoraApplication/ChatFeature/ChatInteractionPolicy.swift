public enum ChatInteractionPolicy {
    public static func allowsNavigationAndMutation(in state: ChatFeatureState) -> Bool {
        guard case .ready = state.catalog, state.activity == nil else { return false }
        if case .opening = state.selection { return false }
        return true
    }

    public static func allowsCoachInvocation(in state: ChatFeatureState) -> Bool {
        guard state.admissionAvailability == .available else { return false }
        if case let .open(aggregate) = state.selection {
            return aggregate.profileProposal == nil
        }
        return true
    }

    public static func allowsComposerEditing(in state: ChatFeatureState) -> Bool {
        guard case let .open(aggregate) = state.selection else { return false }
        return aggregate.pendingUserTurn == nil && aggregate.profileProposal == nil
    }
}
