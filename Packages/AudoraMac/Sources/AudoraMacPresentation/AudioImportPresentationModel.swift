import AudoraApplication
import Combine

@MainActor
public final class AudioImportPresentationModel: ObservableObject {
    @Published public private(set) var snapshot: AudioImportFeatureState?

    private let feature: any AudioImportFeature
    private var hasStarted = false

    public init(feature: any AudioImportFeature) {
        self.feature = feature
    }

    public var isImporting: Bool { snapshot?.isImporting == true }

    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        var states = feature.states.makeAsyncIterator()
        while !Task.isCancelled, let state = await states.next() {
            snapshot = state
        }
    }

    public func send(_ command: AudioImportCommand) {
        Task { await feature.send(command) }
    }

    public func restart() {
        Task {
            await feature.send(.clearResult)
            await feature.send(.chooseAudio)
        }
    }
}
