import AudoraApplication
import Combine

@MainActor
private final class DeferredChatCommandCompletion {
    private var isFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isFinished else { return }
        await withCheckedContinuation { continuation in
            guard !isFinished else {
                continuation.resume()
                return
            }
            waiters.append(continuation)
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        let currentWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

@MainActor
public final class ChatCommandDispatcher: ObservableObject {
    @Published public private(set) var isLibraryNavigationPending = false

    let feature: any ChatFeature
    private var commandTail: Task<Void, Never>?
    private var deferredStartCommands: [(ChatCommand, DeferredChatCommandCompletion)] = []
    private var navigationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var admittedCommandCount = 0

    public init(feature: any ChatFeature) {
        self.feature = feature
    }

    @discardableResult
    public func enqueue(_ command: ChatCommand) -> Task<Void, Never> {
        guard !isLibraryNavigationPending else {
            guard case .start = command else { return Task {} }
            let completion = DeferredChatCommandCompletion()
            deferredStartCommands.append((command, completion))
            return Task { await completion.wait() }
        }
        return enqueueAccepted(command)
    }

    private func enqueueAccepted(_ command: ChatCommand) -> Task<Void, Never> {
        admittedCommandCount += 1
        let predecessor = commandTail
        let feature = feature
        let task = Task {
            await predecessor?.value
            await feature.send(command)
        }
        commandTail = task
        return task
    }

    public func sendAndWait(_ command: ChatCommand) async {
        await enqueue(command).value
    }

    public func drain() async {
        while true {
            let observedCommandCount = admittedCommandCount
            await commandTail?.value
            guard observedCommandCount == admittedCommandCount else { continue }
            return
        }
    }

    public func flushForOrderlyTermination() async -> Bool {
        await waitForLibraryNavigation()
        return await prepareForLibraryNavigation()
    }

    public func prepareForLibraryNavigation() async -> Bool {
        await drain()
        return await feature.flushForOrderlyTermination()
    }

    fileprivate func beginLibraryNavigation() -> Bool {
        guard !isLibraryNavigationPending else { return false }
        isLibraryNavigationPending = true
        return true
    }

    fileprivate func finishLibraryNavigation() {
        guard isLibraryNavigationPending else { return }
        isLibraryNavigationPending = false

        let starts = deferredStartCommands
        deferredStartCommands.removeAll(keepingCapacity: false)
        for (command, completion) in starts {
            let task = enqueueAccepted(command)
            Task {
                await task.value
                completion.finish()
            }
        }

        let currentWaiters = navigationWaiters
        navigationWaiters.removeAll(keepingCapacity: false)
        for waiter in currentWaiters {
            waiter.resume()
        }
    }

    private func waitForLibraryNavigation() async {
        guard isLibraryNavigationPending else { return }
        await withCheckedContinuation { continuation in
            guard isLibraryNavigationPending else {
                continuation.resume()
                return
            }
            navigationWaiters.append(continuation)
        }
    }
}

@MainActor
public final class LibrarySelectionCommandDispatcher {
    private let feature: any LibraryFeature
    private let chatDispatcher: ChatCommandDispatcher
    private var commandTail: Task<Bool, Never>?

    public init(
        feature: any LibraryFeature,
        chatDispatcher: ChatCommandDispatcher
    ) {
        self.feature = feature
        self.chatDispatcher = chatDispatcher
    }

    @discardableResult
    public func enqueue(_ command: LibraryCommand) -> Task<Bool, Never> {
        guard chatDispatcher.beginLibraryNavigation() else {
            return Task { false }
        }
        let predecessor = commandTail
        let feature = feature
        let chatDispatcher = chatDispatcher
        let task = Task {
            _ = await predecessor?.value
            guard await chatDispatcher.prepareForLibraryNavigation() else {
                chatDispatcher.finishLibraryNavigation()
                return false
            }
            await feature.send(command)
            chatDispatcher.finishLibraryNavigation()
            return true
        }
        commandTail = task
        return task
    }

    @discardableResult
    public func sendAndWait(_ command: LibraryCommand) async -> Bool {
        await enqueue(command).value
    }
}
