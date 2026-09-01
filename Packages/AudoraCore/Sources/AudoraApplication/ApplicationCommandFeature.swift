import AudoraDomain

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct ApplicationCommandAdmissionState: Equatable, Sendable {
    public static let idle = ApplicationCommandAdmissionState()

    public let isLibraryNavigationPending: Bool
    public let isChatBoundaryPending: Bool
    public let isOrderlyTerminationPending: Bool

    public init(
        isLibraryNavigationPending: Bool = false,
        isChatBoundaryPending: Bool = false,
        isOrderlyTerminationPending: Bool = false
    ) {
        self.isLibraryNavigationPending = isLibraryNavigationPending
        self.isChatBoundaryPending = isChatBoundaryPending
        self.isOrderlyTerminationPending = isOrderlyTerminationPending
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct ApplicationCommandReceipt<Outcome: Sendable>: Sendable {
    private let task: Task<Outcome, Never>

    fileprivate init(task: Task<Outcome, Never>) {
        self.task = task
    }

    public var value: Outcome {
        get async { await task.value }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@MainActor
public protocol ApplicationCommandFeature: AnyObject, Sendable {
    var admissionState: ApplicationCommandAdmissionState { get }
    var admissionStates: AsyncStream<ApplicationCommandAdmissionState> { get }
    var chatStates: AsyncStream<ChatFeatureState> { get }

    func currentChatState() async -> ChatFeatureState
    func currentChatState(in scope: LibraryScope) async -> ChatFeatureState?

    @discardableResult
    func enqueue(_ command: ChatCommand) -> ApplicationCommandReceipt<Void>

    @discardableResult
    func enqueue(_ intent: LibrarySelectionIntent) -> ApplicationCommandReceipt<Bool>

    @discardableResult
    func flushForOrderlyTermination() -> ApplicationCommandReceipt<Bool>
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@MainActor
public final class DefaultApplicationCommandFeature: ApplicationCommandFeature {
    private nonisolated let chat: any ChatFeature
    private nonisolated let sessionProcessing: (any SessionProcessingFeature)?
    private let library: any LibraryFeature
    public private(set) var admissionState = ApplicationCommandAdmissionState.idle

    private var commandTail: Task<Void, Never>?
    private var admittedCommandCount = 0
    private var pendingLibraryNavigationCount = 0
    private var deferredStarts: [(ChatCommand, DeferredApplicationCommandCompletion)] = []
    private var admissionContinuations:
        [Int: AsyncStream<ApplicationCommandAdmissionState>.Continuation] = [:]
    private var nextAdmissionContinuationID = 0

    public init(
        library: any LibraryFeature,
        chat: any ChatFeature,
        sessionProcessing: (any SessionProcessingFeature)? = nil
    ) {
        self.library = library
        self.chat = chat
        self.sessionProcessing = sessionProcessing
    }

    public var admissionStates: AsyncStream<ApplicationCommandAdmissionState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = nextAdmissionContinuationID
            nextAdmissionContinuationID += 1
            admissionContinuations[id] = continuation
            continuation.yield(admissionState)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.admissionContinuations[id] = nil }
            }
        }
    }

    public var chatStates: AsyncStream<ChatFeatureState> { chat.states }

    public func currentChatState() async -> ChatFeatureState {
        await chat.currentState
    }

    public func currentChatState(in scope: LibraryScope) async -> ChatFeatureState? {
        await chat.currentState(in: scope)
    }

    @discardableResult
    public func enqueue(_ command: ChatCommand) -> ApplicationCommandReceipt<Void> {
        guard !admissionState.isOrderlyTerminationPending else {
            return completedReceipt()
        }
        guard !admissionState.isLibraryNavigationPending,
              !admissionState.isChatBoundaryPending
        else {
            return deferStart(command)
        }
        let beginsBoundary = command.beginsApplicationChatBoundary
        if beginsBoundary {
            updateAdmissionState(isChatBoundaryPending: true)
        }
        return enqueueAccepted(command, finishesChatBoundary: beginsBoundary)
    }

    @discardableResult
    public func enqueue(
        _ intent: LibrarySelectionIntent
    ) -> ApplicationCommandReceipt<Bool> {
        guard !admissionState.isOrderlyTerminationPending,
              !admissionState.isChatBoundaryPending
        else {
            return completedReceipt(false)
        }
        if admissionState.isLibraryNavigationPending {
            guard case .openExternal = intent else {
                return completedReceipt(false)
            }
        }
        pendingLibraryNavigationCount += 1
        updateAdmissionState(isLibraryNavigationPending: true)
        admittedCommandCount += 1
        let predecessor = commandTail
        let chat = chat
        let library = library
        let sessionProcessing = sessionProcessing
        let operation = Task<Bool, Never> {
            await predecessor?.value
            if let sessionProcessing,
               !(await sessionProcessing.reserveLibraryNavigation())
            {
                finishLibraryNavigation()
                return false
            }
            guard await chat.flushForOrderlyTermination() else {
                await sessionProcessing?.finishLibraryNavigation(
                    didMutateLibrary: false
                )
                finishLibraryNavigation()
                return false
            }
            let result = await library.send(intent.command)
            if let activation = result.activation {
                await sessionProcessing?.activateLibrary(activation)
            }
            await sessionProcessing?.finishLibraryNavigation(
                didMutateLibrary: result.didMutateSelection
            )
            finishLibraryNavigation()
            return result.didMutateSelection
        }
        commandTail = Task { _ = await operation.value }
        return ApplicationCommandReceipt(task: operation)
    }

    @discardableResult
    public func flushForOrderlyTermination() -> ApplicationCommandReceipt<Bool> {
        guard !admissionState.isOrderlyTerminationPending else {
            return completedReceipt(false)
        }
        updateAdmissionState(isOrderlyTerminationPending: true)
        let chat = chat
        let operation = Task<Bool, Never> {
            await drainAcceptedCommands()
            let succeeded = await chat.flushForOrderlyTermination()
            if !succeeded {
                updateAdmissionState(isOrderlyTerminationPending: false)
            }
            return succeeded
        }
        return ApplicationCommandReceipt(task: operation)
    }

    private func enqueueAccepted(
        _ command: ChatCommand,
        finishesChatBoundary: Bool = false
    ) -> ApplicationCommandReceipt<Void> {
        admittedCommandCount += 1
        let predecessor = commandTail
        let chat = chat
        let operation = Task<Void, Never> {
            await predecessor?.value
            await chat.send(command)
            if finishesChatBoundary {
                finishChatBoundary()
            }
        }
        commandTail = operation
        return ApplicationCommandReceipt(task: operation)
    }

    private func deferStart(_ command: ChatCommand) -> ApplicationCommandReceipt<Void> {
        guard case .start = command else { return completedReceipt() }
        let completion = DeferredApplicationCommandCompletion()
        deferredStarts.append((command, completion))
        return ApplicationCommandReceipt(task: Task { await completion.wait() })
    }

    private func finishChatBoundary() {
        updateAdmissionState(isChatBoundaryPending: false)
        releaseDeferredStartsIfPossible()
    }

    private func finishLibraryNavigation() {
        precondition(pendingLibraryNavigationCount > 0)
        pendingLibraryNavigationCount -= 1
        guard pendingLibraryNavigationCount == 0 else { return }
        updateAdmissionState(isLibraryNavigationPending: false)
        releaseDeferredStartsIfPossible()
    }

    private func releaseDeferredStartsIfPossible() {
        guard !admissionState.isLibraryNavigationPending,
              !admissionState.isChatBoundaryPending
        else {
            return
        }
        let starts = deferredStarts
        deferredStarts.removeAll(keepingCapacity: false)
        for (command, completion) in starts {
            let receipt = enqueueAccepted(command)
            Task {
                await receipt.value
                completion.finish()
            }
        }
    }

    private func drainAcceptedCommands() async {
        while true {
            let observedCommandCount = admittedCommandCount
            await commandTail?.value
            guard observedCommandCount == admittedCommandCount else { continue }
            return
        }
    }

    private func updateAdmissionState(
        isLibraryNavigationPending: Bool? = nil,
        isChatBoundaryPending: Bool? = nil,
        isOrderlyTerminationPending: Bool? = nil
    ) {
        let replacement = ApplicationCommandAdmissionState(
            isLibraryNavigationPending: isLibraryNavigationPending
                ?? admissionState.isLibraryNavigationPending,
            isChatBoundaryPending: isChatBoundaryPending
                ?? admissionState.isChatBoundaryPending,
            isOrderlyTerminationPending: isOrderlyTerminationPending
                ?? admissionState.isOrderlyTerminationPending
        )
        guard replacement != admissionState else { return }
        admissionState = replacement
        for continuation in admissionContinuations.values {
            continuation.yield(replacement)
        }
    }

    private func completedReceipt() -> ApplicationCommandReceipt<Void> {
        ApplicationCommandReceipt(task: Task {})
    }

    private func completedReceipt<Outcome: Sendable>(
        _ outcome: Outcome
    ) -> ApplicationCommandReceipt<Outcome> {
        ApplicationCommandReceipt(task: Task { outcome })
    }
}

@MainActor
private final class DeferredApplicationCommandCompletion {
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

private extension ChatCommand {
    var beginsApplicationChatBoundary: Bool {
        switch self {
        case .createDevelopmentChat, .open, .sendDraft:
            true
        case .start, .rename, .setFilter, .editDraft, .discardPendingUserTurn:
            false
        }
    }
}
