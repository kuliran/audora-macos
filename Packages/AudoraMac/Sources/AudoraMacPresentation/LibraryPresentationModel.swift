import AudoraApplication
import Combine

@MainActor
public final class LibraryPresentationModel: ObservableObject {
    @Published public private(set) var snapshot: LibraryFeatureState?

    private let feature: any LibraryFeature
    private let librarySelection: any LibrarySelectionCommandDispatching

    private var hasStarted = false

    public init(
        feature: any LibraryFeature,
        librarySelection: any LibrarySelectionCommandDispatching
    ) {
        self.feature = feature
        self.librarySelection = librarySelection
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
        _ = await librarySelection.sendAndWait(.start)

        while !Task.isCancelled, let nextSnapshot = await states.next() {
            snapshot = nextSnapshot
        }
    }

    public func reveal() {
        Task { await feature.send(.reveal) }
    }
}
