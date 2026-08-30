@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol LibraryFeature: Sendable {
    var currentState: LibraryFeatureState { get async }
    var states: AsyncStream<LibraryFeatureState> { get }

    func send(_ command: LibraryCommand) async
}
