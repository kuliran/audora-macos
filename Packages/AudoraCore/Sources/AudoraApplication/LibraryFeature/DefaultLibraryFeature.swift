import AudoraDomain

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor DefaultLibraryFeature: LibraryFeature {
    private let bootstrapPort: any LibraryBootstrapPort
    private var state = LibraryFeatureReducer.initialState
    private var isBootstrapResolutionInFlight = false
    private var continuations: [Int: AsyncStream<LibraryFeatureState>.Continuation] = [:]
    private var nextSubscriberID = 0

    public init(bootstrapPort: any LibraryBootstrapPort) {
        self.bootstrapPort = bootstrapPort
    }

    public var currentState: LibraryFeatureState {
        state
    }

    public nonisolated var states: AsyncStream<LibraryFeatureState> {
        AsyncStream { continuation in
            Task {
                await self.addSubscriber(continuation)
            }
        }
    }

    public func send(_ command: LibraryCommand) async {
        for effect in LibraryFeatureReducer.effects(for: command, state: state) {
            switch effect {
            case .resolveInitialLibrary:
                guard !isBootstrapResolutionInFlight else {
                    continue
                }
                isBootstrapResolutionInFlight = true
                let availability = await bootstrapPort.resolveInitialLibrary()
                state = LibraryFeatureReducer.reduce(state, availability: availability)
                isBootstrapResolutionInFlight = false
                publish(state)
            }
        }
    }

    private func addSubscriber(
        _ continuation: AsyncStream<LibraryFeatureState>.Continuation
    ) {
        let subscriberID = nextSubscriberID
        nextSubscriberID += 1

        continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.removeSubscriber(subscriberID)
            }
        }
        continuations[subscriberID] = continuation
        continuation.yield(state)
    }

    private func removeSubscriber(_ subscriberID: Int) {
        continuations.removeValue(forKey: subscriberID)
    }

    private func publish(_ snapshot: LibraryFeatureState) {
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }
}
