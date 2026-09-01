import AudoraDomain

public struct LibraryActivation: Equatable, Sendable {
    public let scope: LibraryScope
    public let generation: UInt64

    public init(scope: LibraryScope, generation: UInt64) {
        self.scope = scope
        self.generation = generation
    }
}

public enum LibraryCommandResult: Equatable, Sendable {
    case noSelectionMutation
    case activated(LibraryActivation)
    case deactivated

    public var didMutateSelection: Bool {
        switch self {
        case .noSelectionMutation: false
        case .activated, .deactivated: true
        }
    }

    public var activation: LibraryActivation? {
        guard case let .activated(activation) = self else { return nil }
        return activation
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol LibraryFeature: Sendable {
    var currentState: LibraryFeatureState { get async }
    var states: AsyncStream<LibraryFeatureState> { get }

    @discardableResult
    func send(_ command: LibraryCommand) async -> LibraryCommandResult
}
