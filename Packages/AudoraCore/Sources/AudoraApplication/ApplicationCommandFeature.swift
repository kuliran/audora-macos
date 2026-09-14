import AudoraDomain

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct ApplicationCommandAdmissionState: Equatable, Sendable {
    public static let idle = ApplicationCommandAdmissionState()

    public let isLibraryNavigationPending: Bool
    public let isChatBoundaryPending: Bool
    public let isLibraryCatalogMutationPending: Bool
    public let isOrderlyTerminationPending: Bool

    public init(
        isLibraryNavigationPending: Bool = false,
        isChatBoundaryPending: Bool = false,
        isLibraryCatalogMutationPending: Bool = false,
        isOrderlyTerminationPending: Bool = false
    ) {
        self.isLibraryNavigationPending = isLibraryNavigationPending
        self.isChatBoundaryPending = isChatBoundaryPending
        self.isLibraryCatalogMutationPending = isLibraryCatalogMutationPending
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
public protocol ApplicationSessionProcessingFeature: AnyObject, Sendable {
    var sessionProcessingStates: AsyncStream<SessionProcessingFeatureState> { get }

    func currentSessionProcessingState() async -> SessionProcessingFeatureState?

    func isSessionProcessingCommandAdmitted(
        _ command: SessionProcessingCommand
    ) -> Bool

    @discardableResult
    func send(_ command: SessionProcessingCommand) async -> Bool

    func retranscribeExactly(
        _ selection: SessionProcessingSelection
    ) async -> SessionProcessingRetranscriptionResult
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@MainActor
public protocol ApplicationCommandFeature: ApplicationSessionProcessingFeature {
    var admissionState: ApplicationCommandAdmissionState { get }
    var admissionStates: AsyncStream<ApplicationCommandAdmissionState> { get }
    var chatStates: AsyncStream<ChatFeatureState> { get }

    func currentChatState() async -> ChatFeatureState
    func currentChatState(in context: ChatCommandContext) async -> ChatFeatureState?

    @discardableResult
    func enqueue(_ command: ChatCommand) -> ApplicationCommandReceipt<Void>

    @discardableResult
    func enqueue(_ intent: LibrarySelectionIntent) -> ApplicationCommandReceipt<Bool>

    @discardableResult
    func enqueue(
        _ command: LibraryCatalogCommand
    ) -> ApplicationCommandReceipt<LibraryCatalogCommandResult>

    @discardableResult
    func flushForOrderlyTermination() -> ApplicationCommandReceipt<Bool>
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@MainActor
public final class DefaultApplicationCommandFeature: ApplicationCommandFeature {
    private nonisolated let chat: any ChatFeature
    private nonisolated let libraryCatalog: (any LibraryCatalogFeature)?
    private nonisolated let libraryCatalogMutation:
        (any LibraryCatalogMutationFeature)?
    private nonisolated let sessionProcessing: (any SessionProcessingFeature)?
    private nonisolated let exactSessionRetranscription:
        (any SessionProcessingExactRetranscriptionFeature)?
    private let library: any LibraryFeature
    private var reviewLibraryNavigation:
        (any ReviewLibraryNavigationLifecycle)?
    public private(set) var admissionState = ApplicationCommandAdmissionState.idle

    private var commandTail: Task<Void, Never>?
    private var admittedCommandCount = 0
    private var pendingLibraryNavigationCount = 0
    private var reviewLibraryNavigationReserved = false
    private var reviewLibraryNavigationResult =
        LibraryCommandResult.noSelectionMutation
    private var isReviewLibraryNavigationFinalizing = false
    private var deferredStarts: [(ChatCommand, DeferredApplicationCommandCompletion)] = []
    private var admissionContinuations:
        [Int: AsyncStream<ApplicationCommandAdmissionState>.Continuation] = [:]
    private var nextAdmissionContinuationID = 0

    public init(
        library: any LibraryFeature,
        chat: any ChatFeature,
        libraryCatalog: (any LibraryCatalogFeature)? = nil,
        sessionProcessing: (any SessionProcessingFeature)? = nil
    ) {
        self.library = library
        self.chat = chat
        self.libraryCatalog = libraryCatalog
        libraryCatalogMutation = libraryCatalog as? any LibraryCatalogMutationFeature
        self.sessionProcessing = sessionProcessing
        exactSessionRetranscription = sessionProcessing as?
            any SessionProcessingExactRetranscriptionFeature
    }

    /// Completes the one circular composition seam: Review retranscription
    /// enters through Application commands, while Library navigation must in
    /// turn fence Review. Installation is allowed only before any command has
    /// been admitted, so every observable navigation has one stable set of
    /// lifecycle participants.
    public func installReviewLibraryNavigationLifecycle(
        _ lifecycle: any ReviewLibraryNavigationLifecycle
    ) {
        precondition(reviewLibraryNavigation == nil)
        precondition(admittedCommandCount == 0)
        reviewLibraryNavigation = lifecycle
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

    public var sessionProcessingStates: AsyncStream<SessionProcessingFeatureState> {
        guard let sessionProcessing else {
            return AsyncStream { continuation in continuation.finish() }
        }
        return sessionProcessing.states
    }

    public func currentSessionProcessingState() async
        -> SessionProcessingFeatureState?
    {
        await sessionProcessing?.currentState
    }

    public func currentChatState() async -> ChatFeatureState {
        await chat.currentState
    }

    public func currentChatState(
        in context: ChatCommandContext
    ) async -> ChatFeatureState? {
        await chat.currentState(in: context)
    }

    public func isSessionProcessingCommandAdmitted(
        _ command: SessionProcessingCommand
    ) -> Bool {
        guard sessionProcessing != nil,
              command.isApplicationIngress,
              !admissionState.isLibraryNavigationPending,
              !admissionState.isLibraryCatalogMutationPending,
              !admissionState.isOrderlyTerminationPending
        else {
            return false
        }
        return !admissionState.isChatBoundaryPending ||
            command.isAdmittedDuringChatBoundary
    }

    @discardableResult
    public func send(_ command: SessionProcessingCommand) async -> Bool {
        guard isSessionProcessingCommandAdmitted(command),
              let sessionProcessing
        else {
            return false
        }
        await sessionProcessing.send(command)
        return true
    }

    public func retranscribeExactly(
        _ selection: SessionProcessingSelection
    ) async -> SessionProcessingRetranscriptionResult {
        guard isSessionProcessingCommandAdmitted(.selectSession(selection)),
              isSessionProcessingCommandAdmitted(.start),
              let exactSessionRetranscription
        else { return .failed }
        return await exactSessionRetranscription.retranscribeExactly(selection)
    }

    @discardableResult
    public func enqueue(_ command: ChatCommand) -> ApplicationCommandReceipt<Void> {
        guard !admissionState.isOrderlyTerminationPending else {
            return completedReceipt()
        }
        if case .cancelNewChat = command {
            let chat = chat
            return ApplicationCommandReceipt(task: Task { await chat.send(command) })
        }
        if case .stopCoachResponse = command {
            let chat = chat
            return ApplicationCommandReceipt(task: Task { await chat.send(command) })
        }
        if case .stopProfileReconsideration = command {
            let chat = chat
            return ApplicationCommandReceipt(task: Task { await chat.send(command) })
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
            guard case .openExternal = intent,
                  !isReviewLibraryNavigationFinalizing
            else {
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
        let reviewLibraryNavigation = reviewLibraryNavigation
        let operation = Task<Bool, Never> {
            await predecessor?.value
            if let sessionProcessing,
               !(await sessionProcessing.reserveLibraryNavigation())
            {
                await finishReviewLibraryNavigationOperation(
                    .noSelectionMutation,
                    lifecycle: reviewLibraryNavigation
                )
                finishLibraryNavigation()
                return false
            }
            if let reviewLibraryNavigation,
               !reviewLibraryNavigationReserved
            {
                guard await reviewLibraryNavigation.reserveLibraryNavigation()
                else {
                    await sessionProcessing?.finishLibraryNavigation(
                        didMutateLibrary: false
                    )
                    finishLibraryNavigation()
                    return false
                }
                reviewLibraryNavigationReserved = true
                reviewLibraryNavigationResult = .noSelectionMutation
            }
            guard await chat.flushForOrderlyTermination() else {
                await finishReviewLibraryNavigationOperation(
                    .noSelectionMutation,
                    lifecycle: reviewLibraryNavigation
                )
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
            await finishReviewLibraryNavigationOperation(
                result,
                lifecycle: reviewLibraryNavigation
            )
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
    public func enqueue(
        _ command: LibraryCatalogCommand
    ) -> ApplicationCommandReceipt<LibraryCatalogCommandResult> {
        guard !admissionState.isOrderlyTerminationPending,
              let libraryCatalog
        else {
            return completedReceipt(command.unavailableResult)
        }

        // A mutation without the post-composition Review participant cannot
        // establish the complete Session lifecycle and therefore fails closed.
        guard !command.isMutation else {
            return completedReceipt(command.unavailableResult)
        }
        admittedCommandCount += 1
        let predecessor = commandTail
        let operation = Task<LibraryCatalogCommandResult, Never> {
            await predecessor?.value
            return await libraryCatalog.send(command)
        }
        commandTail = Task { _ = await operation.value }
        return ApplicationCommandReceipt(task: operation)
    }

    @discardableResult
    fileprivate func enqueueCatalogMutation(
        _ command: LibraryCatalogCommand,
        review: any ReviewFeature
    ) -> ApplicationCommandReceipt<LibraryCatalogCommandResult> {
        guard command.isMutation else { return enqueue(command) }
        guard !admissionState.isOrderlyTerminationPending,
              let libraryCatalogMutation
        else {
            return completedReceipt(command.unavailableResult)
        }

        guard !admissionState.isLibraryNavigationPending,
              !admissionState.isChatBoundaryPending,
              !admissionState.isLibraryCatalogMutationPending
        else {
            return completedReceipt(command.refusedResult)
        }

        updateAdmissionState(
            isChatBoundaryPending: true,
            isLibraryCatalogMutationPending: true
        )
        admittedCommandCount += 1
        let predecessor = commandTail
        let chat = chat
        let sessionProcessing = sessionProcessing
        let operation = Task<LibraryCatalogCommandResult, Never> {
            await predecessor?.value
            guard await isCurrentLibraryActivation(command.activation) else {
                finishLibraryCatalogMutationBoundary()
                return command.unavailableResult
            }
            let lifecycle = ApplicationLibraryCatalogMutationLifecycle(
                chat: chat,
                sessionProcessing: sessionProcessing,
                review: review
            )
            let result = await libraryCatalogMutation.send(
                command,
                lifecycle: lifecycle
            )
            finishLibraryCatalogMutationBoundary()
            return result
        }
        commandTail = Task { _ = await operation.value }
        return ApplicationCommandReceipt(task: operation)
    }

    private func isCurrentLibraryActivation(
        _ activation: LibraryActivation
    ) async -> Bool {
        guard activation.generation > 0,
              case let .active(snapshot) = await library.currentState.selection
        else {
            return false
        }
        return snapshot.libraryID == activation.scope.libraryID
            && snapshot.activationGeneration == activation.generation
    }

    @discardableResult
    public func flushForOrderlyTermination() -> ApplicationCommandReceipt<Bool> {
        guard !admissionState.isOrderlyTerminationPending else {
            return completedReceipt(false)
        }
        updateAdmissionState(isOrderlyTerminationPending: true)
        let chat = chat
        let operation = Task<Bool, Never> {
            await chat.beginOrderlyTermination()
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

    private func finishLibraryCatalogMutationBoundary() {
        updateAdmissionState(
            isChatBoundaryPending: false,
            isLibraryCatalogMutationPending: false
        )
        releaseDeferredStartsIfPossible()
    }

    private func finishLibraryNavigation() {
        precondition(pendingLibraryNavigationCount > 0)
        pendingLibraryNavigationCount -= 1
        guard pendingLibraryNavigationCount == 0 else { return }
        precondition(!reviewLibraryNavigationReserved)
        isReviewLibraryNavigationFinalizing = false
        updateAdmissionState(isLibraryNavigationPending: false)
        releaseDeferredStartsIfPossible()
    }

    private func finishReviewLibraryNavigationOperation(
        _ result: LibraryCommandResult,
        lifecycle: (any ReviewLibraryNavigationLifecycle)?
    ) async {
        guard reviewLibraryNavigationReserved, let lifecycle else { return }
        if result.didMutateSelection {
            reviewLibraryNavigationResult = result
        }
        // Queued external opens share one Application boundary. Keep Review
        // fenced across every already-admitted operation and reconcile it to
        // the last mutation in the batch. Otherwise a no-op trailing request
        // could incorrectly restore a selection from the superseded root.
        guard pendingLibraryNavigationCount == 1 else { return }
        isReviewLibraryNavigationFinalizing = true
        await lifecycle.finishLibraryNavigation(reviewLibraryNavigationResult)
        reviewLibraryNavigationReserved = false
        reviewLibraryNavigationResult = .noSelectionMutation
    }

    private func releaseDeferredStartsIfPossible() {
        guard !admissionState.isLibraryNavigationPending,
              !admissionState.isChatBoundaryPending,
              !admissionState.isLibraryCatalogMutationPending
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
        isLibraryCatalogMutationPending: Bool? = nil,
        isOrderlyTerminationPending: Bool? = nil
    ) {
        let replacement = ApplicationCommandAdmissionState(
            isLibraryNavigationPending: isLibraryNavigationPending
                ?? admissionState.isLibraryNavigationPending,
            isChatBoundaryPending: isChatBoundaryPending
                ?? admissionState.isChatBoundaryPending,
            isLibraryCatalogMutationPending: isLibraryCatalogMutationPending
                ?? admissionState.isLibraryCatalogMutationPending,
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

/// The Presentation-facing catalog seam. Reads and mutations enter the same
/// Application ordering boundary as Chat work and Library navigation.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct ApplicationCoordinatedLibraryCatalogFeature: LibraryCatalogFeature {
    private let application: DefaultApplicationCommandFeature
    private let review: any ReviewFeature

    public init(
        application: DefaultApplicationCommandFeature,
        review: any ReviewFeature
    ) {
        self.application = application
        self.review = review
    }

    public func send(
        _ command: LibraryCatalogCommand
    ) async -> LibraryCatalogCommandResult {
        let receipt = command.isMutation
            ? await application.enqueueCatalogMutation(
                command,
                review: review
            )
            : await application.enqueue(command)
        return await receipt.value
    }
}

private actor ApplicationLibraryCatalogMutationLifecycle:
    LibraryCatalogMutationLifecycle
{
    private let chat: any ChatFeature
    private let sessionProcessing: (any SessionProcessingFeature)?
    private let review: any LibraryCatalogSessionLifecycle
    private var preparedCommand: LibraryCatalogCommand?
    private var processingLease: LibraryCatalogSessionMutationLease?
    private var reviewLease: LibraryCatalogSessionMutationLease?

    init(
        chat: any ChatFeature,
        sessionProcessing: (any SessionProcessingFeature)?,
        review: any LibraryCatalogSessionLifecycle
    ) {
        self.chat = chat
        self.sessionProcessing = sessionProcessing
        self.review = review
    }

    func prepareForLibraryCatalogMutation(
        _ command: LibraryCatalogCommand
    ) async -> LibraryCatalogMutationPreparationResult {
        guard preparedCommand == nil else { return .refused }
        if let mutation = LibraryCatalogSessionMutation(command) {
            guard let sessionProcessing else { return .unavailable }
            guard let acquiredProcessing = await sessionProcessing
                .reserveLibraryCatalogSessionMutation(mutation)
            else { return .refused }
            processingLease = acquiredProcessing

            guard let acquiredReview = await review
                .reserveLibraryCatalogSessionMutation(mutation)
            else {
                _ = await sessionProcessing.finishLibraryCatalogSessionMutation(
                    acquiredProcessing,
                    completion: .aborted
                )
                processingLease = nil
                return .refused
            }
            reviewLease = acquiredReview
        }

        guard await chat.prepareForLibraryCatalogMutation(
            for: command.activation
        ) else {
            await abortSessionParticipants()
            return .unavailable
        }
        preparedCommand = command
        return .prepared
    }

    func reloadAfterLibraryCatalogMutation(
        _ command: LibraryCatalogCommand,
        result: LibraryCatalogCommandResult
    ) async -> Bool {
        guard preparedCommand == command else {
            await invalidateSessionParticipants()
            return false
        }
        let completion = LibraryCatalogSessionMutationCompletion.completed(
            result.catalogLoadResult
        )
        var didFinish = true
        if let processingLease, let sessionProcessing {
            let finishResult = await sessionProcessing
                .finishLibraryCatalogSessionMutation(
                    processingLease,
                    completion: completion
                )
            didFinish = finishResult.didFinishAuthoritativeState && didFinish
        }
        if let reviewLease {
            let finishResult = await review.finishLibraryCatalogSessionMutation(
                reviewLease,
                completion: completion
            )
            didFinish = finishResult.didFinishAuthoritativeState && didFinish
        }
        processingLease = nil
        reviewLease = nil
        preparedCommand = nil
        let didReloadChat = await chat.reloadAfterLibraryCatalogMutation(
            for: command.activation
        )
        return didFinish && didReloadChat
    }

    private func abortSessionParticipants() async {
        // Reverse acquisition order prevents Review from racing a processing
        // selection restored by the abort path.
        if let reviewLease {
            _ = await review.finishLibraryCatalogSessionMutation(
                reviewLease,
                completion: .aborted
            )
        }
        if let processingLease, let sessionProcessing {
            _ = await sessionProcessing.finishLibraryCatalogSessionMutation(
                processingLease,
                completion: .aborted
            )
        }
        reviewLease = nil
        processingLease = nil
    }

    private func invalidateSessionParticipants() async {
        let completion = LibraryCatalogSessionMutationCompletion.completed(
            .unavailable
        )
        if let reviewLease {
            _ = await review.finishLibraryCatalogSessionMutation(
                reviewLease,
                completion: completion
            )
        }
        if let processingLease, let sessionProcessing {
            _ = await sessionProcessing.finishLibraryCatalogSessionMutation(
                processingLease,
                completion: completion
            )
        }
        reviewLease = nil
        processingLease = nil
        preparedCommand = nil
    }
}

private extension LibraryCatalogCommandResult {
    var catalogLoadResult: LibraryCatalogLoadResult {
        switch self {
        case let .catalog(result), let .mutation(_, catalog: result): result
        case .mutationRefused: .unavailable
        }
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
        case .confirmNewChat, .open, .sendDraft, .retryPendingUserTurn,
             .acceptProfileProposal, .discardProfileProposal,
             .retryProfileEvidencePublication,
             .discardProfileEvidencePublication, .reconsiderProfileEffect,
             .retryProfileReconsideration,
             .discardProfileReconsiderationFailure:
            true
        case .start, .beginNewChat, .setNewChatAttachmentFilter,
             .toggleNewChatAttachment, .cancelNewChat,
             .rename, .setFilter, .editDraft, .refreshContextQuote,
             .stopCoachResponse, .stopProfileReconsideration,
             .createNewChatFromCapacityFailure,
             .discardPendingUserTurn:
            false
        }
    }
}

private extension SessionProcessingCommand {
    var isApplicationIngress: Bool {
        switch self {
        case .activateLibrary, .activateLibraryAuthority:
            false
        case .selectSession, .clearSelection, .start, .cancel, .prepare,
             .reinstall, .retry:
            true
        }
    }

    var isAdmittedDuringChatBoundary: Bool {
        switch self {
        case .selectSession, .clearSelection, .cancel:
            true
        case .activateLibrary, .activateLibraryAuthority, .start, .prepare,
             .reinstall, .retry:
            false
        }
    }
}
