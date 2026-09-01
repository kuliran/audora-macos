public enum ChatInteractionPolicy {
    public static func allowsNavigationAndMutation(in state: ChatFeatureState) -> Bool {
        guard case .ready = state.catalog, state.activity == nil else { return false }
        if case .opening = state.selection { return false }
        return true
    }

    public static func allowsCoachInvocation(in state: ChatFeatureState) -> Bool {
        state.admissionAvailability == .available
    }
}
