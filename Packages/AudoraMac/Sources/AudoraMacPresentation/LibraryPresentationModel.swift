import AudoraApplication
import Combine

@MainActor
public final class LibraryPresentationModel: ObservableObject {
    @Published public private(set) var snapshot: LibraryFeatureState?

    private let feature: any LibraryFeature

    private var hasStarted = false

    public init(feature: any LibraryFeature) {
        self.feature = feature
    }

    public func start() async {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        var states = feature.states.makeAsyncIterator()
        guard let initialSnapshot = await states.next() else {
            return
        }
        snapshot = initialSnapshot

        guard !Task.isCancelled else {
            return
        }
        await feature.send(.start)

        while !Task.isCancelled, let nextSnapshot = await states.next() {
            snapshot = nextSnapshot
        }
    }

    public func send(_ command: LibraryCommand) {
        Task { await feature.send(command) }
    }
}
