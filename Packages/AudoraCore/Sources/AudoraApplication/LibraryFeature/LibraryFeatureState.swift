public struct LibraryFeatureState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case awaitingBootstrap
        case noLibrarySelected
    }

    public let phase: Phase

    public init(phase: Phase) {
        self.phase = phase
    }
}
