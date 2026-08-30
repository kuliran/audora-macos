import AudoraApplication
import Observation

@MainActor
@Observable
public final class LibraryPresentationModel {
    public private(set) var snapshot: LibraryFeatureState?

    @ObservationIgnored
    private let feature: any LibraryFeature

    @ObservationIgnored
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
}
