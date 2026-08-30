import AudoraApplication
import AudoraDomain
import Combine

@MainActor
public final class ChatPresentationModel: ObservableObject {
    @Published public private(set) var snapshot = ChatFeatureState()
    @Published public var filterText = ""

    private let feature: any ChatFeature
    private var startedLibrary: LibraryID?
    private var startGeneration: UInt64 = 0
    private var projectedStateGeneration: UInt64?
    private var stateConsumer: Task<Void, Never>?

    public init(feature: any ChatFeature) {
        self.feature = feature
    }

    public func start(in scope: LibraryScope) async {
        guard startedLibrary != scope.libraryID else { return }
        startedLibrary = scope.libraryID
        startGeneration &+= 1
        let generation = startGeneration

        stateConsumer?.cancel()
        snapshot = ChatFeatureState(
            catalog: .loading,
            filterQuery: .empty,
            selection: .none
        )
        filterText = ""

        let stream = feature.states
        let consumer = Task { @MainActor [weak self] in
            guard let self else { return }
            var states = stream.makeAsyncIterator()
            while !Task.isCancelled, let next = await states.next() {
                guard generation == startGeneration else { return }
                if projectedStateGeneration != generation {
                    guard await feature.currentState(in: scope) == next else { continue }
                    guard generation == startGeneration, !Task.isCancelled else { return }
                    projectedStateGeneration = generation
                }
                snapshot = next
            }
        }
        stateConsumer = consumer

        await withTaskCancellationHandler {
            await feature.send(.start(scope))
            guard !Task.isCancelled else {
                consumer.cancel()
                return
            }
            if let current = await feature.currentState(in: scope) {
                guard generation == startGeneration, !Task.isCancelled else {
                    consumer.cancel()
                    return
                }
                projectedStateGeneration = generation
                snapshot = current
            }
            await consumer.value
        } onCancel: {
            consumer.cancel()
        }
        guard generation == startGeneration, !Task.isCancelled else { return }
        stateConsumer = nil
    }

    public func send(_ command: ChatCommand) {
        Task { await feature.send(command) }
    }

    public func updateFilter(_ value: String) {
        filterText = value
        guard let query = try? ChatFilterQuery(value) else { return }
        send(.setFilter(query))
    }

    public func clearFilter() {
        updateFilter("")
    }
}
