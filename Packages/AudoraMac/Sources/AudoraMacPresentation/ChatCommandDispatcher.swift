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
    @Published public private(set) var isChatBoundaryPending = false
    @Published public private(set) var isOrderlyTerminationPending = false

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
        guard !isOrderlyTerminationPending else { return Task {} }
        guard !isLibraryNavigationPending else {
            guard case .start = command else { return Task {} }
            let completion = DeferredChatCommandCompletion()
            deferredStartCommands.append((command, completion))
            return Task { await completion.wait() }
        }
        guard !isChatBoundaryPending else {
            guard case .start = command else { return Task {} }
            let completion = DeferredChatCommandCompletion()
            deferredStartCommands.append((command, completion))
            return Task { await completion.wait() }
        }
        let beginsChatBoundary = command.beginsChatBoundary
        if beginsChatBoundary {
            isChatBoundaryPending = true
        }
        return enqueueAccepted(command, finishesChatBoundary: beginsChatBoundary)
    }

    private func enqueueAccepted(
        _ command: ChatCommand,
        finishesChatBoundary: Bool = false
    ) -> Task<Void, Never> {
        admittedCommandCount += 1
        let predecessor = commandTail
        let feature = feature
        let task = Task {
            await predecessor?.value
            await feature.send(command)
            if finishesChatBoundary {
                finishChatBoundary()
            }
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
        guard !isOrderlyTerminationPending else { return false }
        isOrderlyTerminationPending = true
        await waitForLibraryNavigation()
        await drain()
        let succeeded = await feature.flushForOrderlyTermination()
        if !succeeded {
            isOrderlyTerminationPending = false
        }
        return succeeded
    }

    fileprivate func drainForLibrarySelection() async {
        await drain()
    }

    fileprivate func beginLibraryNavigation() -> Bool {
        guard !isLibraryNavigationPending,
              !isChatBoundaryPending,
              !isOrderlyTerminationPending
        else {
            return false
        }
        isLibraryNavigationPending = true
        return true
    }

    fileprivate func finishLibraryNavigation() {
        guard isLibraryNavigationPending else { return }
        isLibraryNavigationPending = false

        releaseDeferredStartsIfPossible()

        let currentWaiters = navigationWaiters
        navigationWaiters.removeAll(keepingCapacity: false)
        for waiter in currentWaiters {
            waiter.resume()
        }
    }

    private func finishChatBoundary() {
        guard isChatBoundaryPending else { return }
        isChatBoundaryPending = false
        releaseDeferredStartsIfPossible()
    }

    private func releaseDeferredStartsIfPossible() {
        guard !isLibraryNavigationPending, !isChatBoundaryPending else { return }
        let starts = deferredStartCommands
        deferredStartCommands.removeAll(keepingCapacity: false)
        for (command, completion) in starts {
            let task = enqueueAccepted(command)
            Task {
                await task.value
                completion.finish()
            }
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

private extension ChatCommand {
    var beginsChatBoundary: Bool {
        switch self {
        case .createDevelopmentChat, .open, .sendDraft:
            true
        case .start, .rename, .setFilter, .editDraft, .discardPendingUserTurn:
            false
        }
    }
}

@MainActor
public final class LibrarySelectionCommandDispatcher {
    private let feature: any LibrarySelectionFeature
    private let chatDispatcher: ChatCommandDispatcher
    private var commandTail: Task<Bool, Never>?

    public init(
        feature: any LibrarySelectionFeature,
        chatDispatcher: ChatCommandDispatcher
    ) {
        self.feature = feature
        self.chatDispatcher = chatDispatcher
    }

    @discardableResult
    public func enqueue(_ intent: LibrarySelectionIntent) -> Task<Bool, Never> {
        guard chatDispatcher.beginLibraryNavigation() else {
            return Task { false }
        }
        let predecessor = commandTail
        let feature = feature
        let chatDispatcher = chatDispatcher
        let task = Task {
            _ = await predecessor?.value
            await chatDispatcher.drainForLibrarySelection()
            guard await feature.send(intent) else {
                chatDispatcher.finishLibraryNavigation()
                return false
            }
            chatDispatcher.finishLibraryNavigation()
            return true
        }
        commandTail = task
        return task
    }

    @discardableResult
    public func sendAndWait(_ intent: LibrarySelectionIntent) async -> Bool {
        await enqueue(intent).value
    }
}
