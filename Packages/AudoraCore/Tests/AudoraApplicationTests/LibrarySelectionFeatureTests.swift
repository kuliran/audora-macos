@testable import AudoraApplication
import AudoraDomain
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@MainActor
final class ApplicationCommandFeatureTests: XCTestCase {
    func testChatBoundaryAdmissionIsSynchronousAndRejectsLateDraftMutation() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedBoundaryChatFeature(trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        var admissionStates = feature.admissionStates.makeAsyncIterator()
        let initialAdmission = await admissionStates.next()
        XCTAssertEqual(initialAdmission, .idle)
        let context = ChatCommandContext(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let chatID = try ChatID("cht-20260830T120000000Z-2ABC")
        let draftID = try ChatDraftID("drf-20260830T120000000Z-3DEF")

        let boundary = feature.enqueue(.open(context, chatID))
        XCTAssertEqual(
            feature.admissionState,
            ApplicationCommandAdmissionState(isChatBoundaryPending: true)
        )
        let pendingAdmission = await admissionStates.next()
        XCTAssertEqual(pendingAdmission, feature.admissionState)
        await chat.waitUntilCommandStarts()

        let lateEdit = feature.enqueue(
            .editDraft(context, chatID, draftID, text: "must be rejected")
        )
        await lateEdit.value
        let commandsWhileSuspended = await chat.commands
        XCTAssertEqual(commandsWhileSuspended, [.open(context, chatID)])

        await chat.resume()
        await boundary.value
        XCTAssertEqual(feature.admissionState, .idle)
        let finalAdmission = await admissionStates.next()
        XCTAssertEqual(finalAdmission, .idle)
    }

    func testOneApplicationFIFOOrdersDraftSendDeferredStartAndTermination() async throws {
        let firstScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let secondScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T121000000Z-3DEF")
        )
        let firstContext = ChatCommandContext(libraryScope: firstScope, generation: 1)
        let secondContext = ChatCommandContext(libraryScope: secondScope, generation: 2)
        let chatID = try ChatID("cht-20260830T120000000Z-2ABC")
        let draft = try ChatDraft(
            draftID: ChatDraftID("drf-20260830T120000000Z-3DEF"),
            version: 0,
            text: "",
            updatedAt: UTCInstant("2026-08-30T12:00:00.000Z")
        )
        let trace = LibrarySelectionTrace()
        let chat = SuspendedOrderedApplicationChatFeature()
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)

        await feature.enqueue(.start(firstContext)).value
        let firstEdit = feature.enqueue(
            .editDraft(firstContext, chatID, draft.draftID, text: "A")
        )
        await chat.waitUntilFirstEditStarts()
        let secondEdit = feature.enqueue(
            .editDraft(firstContext, chatID, draft.draftID, text: "AB")
        )
        let send = feature.enqueue(.sendDraft(firstContext, chatID, draft))
        let deferredStart = feature.enqueue(.start(secondContext))
        let termination = feature.flushForOrderlyTermination()

        XCTAssertEqual(
            feature.admissionState,
            ApplicationCommandAdmissionState(
                isChatBoundaryPending: true,
                isOrderlyTerminationPending: true
            )
        )
        let commandsWhileSuspended = await chat.commands
        let flushesWhileSuspended = await chat.flushCallCount
        XCTAssertEqual(
            commandsWhileSuspended,
            [
                .start(firstContext),
                .editDraft(firstContext, chatID, draft.draftID, text: "A"),
            ]
        )
        XCTAssertEqual(flushesWhileSuspended, 0)

        await chat.resumeFirstEdit()
        await firstEdit.value
        await secondEdit.value
        await send.value
        await deferredStart.value
        let terminationSucceeded = await termination.value

        XCTAssertTrue(terminationSucceeded)
        let commands = await chat.commands
        XCTAssertEqual(
            commands,
            [
                .start(firstContext),
                .editDraft(firstContext, chatID, draft.draftID, text: "A"),
                .editDraft(firstContext, chatID, draft.draftID, text: "AB"),
                .sendDraft(firstContext, chatID, draft),
                .start(secondContext),
            ]
        )
        let finalFlushCount = await chat.flushCallCount
        XCTAssertEqual(finalFlushCount, 1)
    }

    func testSelectionFlushesChatBeforeSendingOneTypedLibraryIntent() async {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)

        let succeeded = await feature.enqueue(.close).value

        XCTAssertTrue(succeeded)
        let events = await trace.events
        XCTAssertEqual(events, ["chat.flush", "library.close"])
    }

    func testChatAndLibraryIntentsShareOneFIFOAndFenceLaterChatIngress() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedCrossFeatureChatFeature(trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        let edit = try makeEditCommand(text: "accepted before Library selection")
        let lateEdit = try makeEditCommand(text: "rejected after Library selection")

        let editReceipt = feature.enqueue(edit)
        await chat.waitUntilCommandStarts()
        let selectionReceipt = feature.enqueue(.close)
        await feature.enqueue(lateEdit).value

        let eventsWhileChatIsSuspended = await trace.events
        XCTAssertEqual(eventsWhileChatIsSuspended, ["chat.edit"])
        XCTAssertTrue(feature.admissionState.isLibraryNavigationPending)

        await chat.resume()
        await editReceipt.value
        let selectionSucceeded = await selectionReceipt.value

        XCTAssertTrue(selectionSucceeded)
        let events = await trace.events
        XCTAssertEqual(events, ["chat.edit", "chat.flush", "library.close"])
        let commands = await chat.commands
        XCTAssertEqual(commands, [edit])
    }

    func testFailedChatFlushRejectsLibrarySelectionInsideApplication() async {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: false, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)

        let succeeded = await feature.enqueue(.chooseExisting).value

        XCTAssertFalse(succeeded)
        let events = await trace.events
        XCTAssertEqual(events, ["chat.flush"])
    }

    func testProcessingAuthorityRejectsLibrarySelectionBeforeChatOrRootMutation()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let job = SessionProcessingJob(
            jobID: try TranscriptionJobID("job-20260830T120200000Z-3DEF"),
            sessionID: try SessionID("ses-20260830T120100000Z-2CDE"),
            revisionID: try TranscriptRevisionID("trv-20260830T120300000Z-4FGH"),
            profileID: "synthetic-qualified-v1",
            createdAt: try UTCInstant("2026-08-30T12:03:00.000Z"),
            state: .running,
            cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                "cancel-library-selection"
            )
        )
        let processing = FixedSessionProcessingFeature(.recoveryRequired(job))
        let feature = DefaultApplicationCommandFeature(
            library: library,
            chat: chat,
            sessionProcessing: processing
        )

        let succeeded = await feature.enqueue(.close).value

        XCTAssertFalse(succeeded)
        let events = await trace.events
        XCTAssertEqual(events, [])
    }

    func testReservedLibraryNavigationRejectsStartRacingSuspendedChatFlush()
        async
    {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedTerminationChatFeature(flushResult: true, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let processing = NavigationReservationProcessingProbe()
        let feature = DefaultApplicationCommandFeature(
            library: library,
            chat: chat,
            sessionProcessing: processing
        )

        let navigation = feature.enqueue(LibrarySelectionIntent.close)
        await chat.waitUntilFlushStarts()
        await processing.send(.start)
        await chat.resume()

        let succeeded = await navigation.value
        let acceptedStartCount = await processing.acceptedStartCount
        let isReserved = await processing.isNavigationReserved
        XCTAssertTrue(succeeded)
        XCTAssertEqual(acceptedStartCount, 0)
        XCTAssertFalse(isReserved)
        let events = await trace.events
        XCTAssertEqual(events, ["chat.flush", "library.close"])
    }

    func testSuccessfulIdenticalLibraryReplacementExplicitlyActivatesProcessing()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let snapshot = ActiveLibrarySnapshot(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC"),
            preferences: .defaults,
            profile: .nullProfile(statementCount: 0)
        )
        let library = IdenticalReplacementLibraryFeature(
            snapshot: snapshot,
            trace: trace
        )
        let processing = NavigationActivationProcessingProbe()
        let feature = DefaultApplicationCommandFeature(
            library: library,
            chat: chat,
            sessionProcessing: processing
        )

        let succeeded = await feature.enqueue(.chooseExisting).value

        XCTAssertTrue(succeeded)
        let commands = await processing.commands
        XCTAssertEqual(
            commands,
            [
                .activateLibraryAuthority(
                    LibraryActivation(
                        scope: LibraryScope(libraryID: snapshot.libraryID),
                        generation: 2
                    )
                ),
            ]
        )
        let navigationMutations = await processing.navigationMutations
        XCTAssertEqual(navigationMutations, [true])
    }

    func testInitialRestoreExplicitlyActivatesProcessingThroughApplicationCoordinator()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let snapshot = ActiveLibrarySnapshot(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC"),
            preferences: .defaults,
            profile: .nullProfile(statementCount: 0)
        )
        let library = IdenticalReplacementLibraryFeature(
            snapshot: snapshot,
            activationGeneration: 1,
            trace: trace
        )
        let processing = NavigationActivationProcessingProbe()
        let feature = DefaultApplicationCommandFeature(
            library: library,
            chat: chat,
            sessionProcessing: processing
        )

        let succeeded = await feature.enqueue(.start).value

        XCTAssertTrue(succeeded)
        let libraryCommands = await library.commands
        XCTAssertEqual(libraryCommands, [.start])
        let processingCommands = await processing.commands
        XCTAssertEqual(
            processingCommands,
            [
                .activateLibraryAuthority(
                    LibraryActivation(
                        scope: LibraryScope(libraryID: snapshot.libraryID),
                        generation: 1
                    )
                ),
            ]
        )
        let navigationMutations = await processing.navigationMutations
        XCTAssertEqual(navigationMutations, [true])
    }

    func testExternalOpenQueuedDuringInitialRestoreActivatesBothExactAuthorities()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let initialScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC")
        )
        let externalScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T121000000Z-3DEF")
        )
        let library = SuspendedActivationLibraryFeature(
            results: [
                .activated(LibraryActivation(scope: initialScope, generation: 1)),
                .activated(LibraryActivation(scope: externalScope, generation: 2)),
            ]
        )
        let processing = NavigationActivationProcessingProbe()
        let feature = DefaultApplicationCommandFeature(
            library: library,
            chat: chat,
            sessionProcessing: processing
        )
        let token = try XCTUnwrap(LibraryOpenRequestToken("queued_external"))

        let startup = feature.enqueue(LibrarySelectionIntent.start)
        await library.waitForCommandCount(1)
        let external = feature.enqueue(.openExternal(token))
        let externalCompletion = BooleanReceiptProbe()
        let externalWaiter = Task {
            await externalCompletion.complete(await external.value)
        }

        XCTAssertTrue(feature.admissionState.isLibraryNavigationPending)
        for _ in 0..<100 { await Task.yield() }
        if let earlyResult = await externalCompletion.result {
            await library.resumeNextCommand()
            _ = await startup.value
            await externalWaiter.value
            return XCTFail(
                "queued external open returned early with \(earlyResult)"
            )
        }
        await library.resumeNextCommand()
        await library.waitForCommandCount(2)
        XCTAssertTrue(feature.admissionState.isLibraryNavigationPending)
        await library.resumeNextCommand()

        let startupSucceeded = await startup.value
        await externalWaiter.value
        let externalSucceeded = await externalCompletion.result
        XCTAssertTrue(startupSucceeded)
        XCTAssertEqual(externalSucceeded, true)
        XCTAssertEqual(feature.admissionState, .idle)
        let libraryCommands = await library.commands
        XCTAssertEqual(libraryCommands, [.start, .openExternal(token)])
        let processingCommands = await processing.commands
        XCTAssertEqual(
            processingCommands,
            [
                .activateLibraryAuthority(
                    LibraryActivation(scope: initialScope, generation: 1)
                ),
                .activateLibraryAuthority(
                    LibraryActivation(scope: externalScope, generation: 2)
                ),
            ]
        )
    }

    func testFailedLibraryNavigationDoesNotActivateOrInvalidateProcessing()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let snapshot = ActiveLibrarySnapshot(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC"),
            preferences: .defaults,
            profile: .nullProfile(statementCount: 0)
        )
        let library = FailedReplacementLibraryFeature(
            snapshot: snapshot,
            trace: trace
        )
        let processing = NavigationActivationProcessingProbe()
        let feature = DefaultApplicationCommandFeature(
            library: library,
            chat: chat,
            sessionProcessing: processing
        )

        let succeeded = await feature.enqueue(.chooseExisting).value

        XCTAssertFalse(succeeded)
        let commands = await processing.commands
        XCTAssertEqual(commands, [])
        let navigationMutations = await processing.navigationMutations
        XCTAssertEqual(navigationMutations, [false])
    }

    func testSelectionFencesLateChatIngressUntilLibrarySendCompletes() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let library = SuspendedSelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        let context = ChatCommandContext(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let chatID = try ChatID("cht-20260830T120000000Z-2ABC")
        let draftID = try ChatDraftID("drf-20260830T120000000Z-3DEF")

        let selection = feature.enqueue(.close)
        await library.waitUntilSendStarts()
        await feature.enqueue(
            .editDraft(context, chatID, draftID, text: "late edit")
        ).value
        await library.resume()

        let succeeded = await selection.value
        XCTAssertTrue(succeeded)
        let commands = await chat.commands
        XCTAssertTrue(commands.isEmpty, "late Chat ingress crossed the Application boundary")
    }

    func testSuccessfulTerminationFencesChatIngressDuringFlushAndAfterReturn() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedTerminationChatFeature(flushResult: true, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        let edit = try makeEditCommand(text: "late edit")

        let termination = feature.flushForOrderlyTermination()
        await chat.waitUntilFlushStarts()
        await feature.enqueue(edit).value
        await chat.resume()

        let succeeded = await termination.value
        XCTAssertTrue(succeeded)
        await feature.enqueue(edit).value
        let selectionSucceeded = await feature.enqueue(.close).value

        XCTAssertFalse(selectionSucceeded)
        let commands = await chat.commands
        XCTAssertTrue(commands.isEmpty, "Chat ingress reopened after successful termination flush")
        let events = await trace.events
        XCTAssertEqual(events, ["chat.flush"])
    }

    func testFailedTerminationReopensChatIngressAfterRejectingCommandsDuringFlush() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedTerminationChatFeature(flushResult: false, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        let edit = try makeEditCommand(text: "edit after failure")

        let termination = feature.flushForOrderlyTermination()
        await chat.waitUntilFlushStarts()
        await feature.enqueue(edit).value
        await chat.resume()

        let succeeded = await termination.value
        XCTAssertFalse(succeeded)
        await feature.enqueue(edit).value

        let commands = await chat.commands
        XCTAssertEqual(commands, [edit])
    }

    private func makeEditCommand(text: String) throws -> ChatCommand {
        let context = ChatCommandContext(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        return try .editDraft(
            context,
            ChatID("cht-20260830T120000000Z-2ABC"),
            ChatDraftID("drf-20260830T120000000Z-3DEF"),
            text: text
        )
    }
}

private actor FixedSessionProcessingFeature: SessionProcessingFeature {
    nonisolated let states: AsyncStream<SessionProcessingFeatureState>
    private let state: SessionProcessingFeatureState

    init(_ state: SessionProcessingFeatureState) {
        self.state = state
        states = AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    var currentState: SessionProcessingFeatureState { state }

    func send(_ command: SessionProcessingCommand) async {}

    func reserveLibraryNavigation() async -> Bool {
        !state.ownsLibraryMutationAuthority
    }

    func finishLibraryNavigation(didMutateLibrary: Bool) async {}
}

private actor NavigationReservationProcessingProbe: SessionProcessingFeature {
    nonisolated let states = AsyncStream<SessionProcessingFeatureState> { continuation in
        continuation.finish()
    }
    private var navigationReserved = false
    private(set) var acceptedStartCount = 0

    var currentState: SessionProcessingFeatureState {
        .unavailable(
            SessionProcessingUnavailableSnapshot(
                selection: nil,
                reason: .noSession,
                actions: []
            )
        )
    }

    var isNavigationReserved: Bool { navigationReserved }

    func send(_ command: SessionProcessingCommand) async {
        if command == .start, !navigationReserved { acceptedStartCount += 1 }
    }

    func reserveLibraryNavigation() async -> Bool {
        guard !navigationReserved else { return false }
        navigationReserved = true
        return true
    }

    func finishLibraryNavigation(didMutateLibrary: Bool) async {
        navigationReserved = false
    }
}

private actor NavigationActivationProcessingProbe: SessionProcessingFeature {
    nonisolated let states = AsyncStream<SessionProcessingFeatureState> { continuation in
        continuation.finish()
    }
    private(set) var commands: [SessionProcessingCommand] = []
    private(set) var navigationMutations: [Bool] = []

    var currentState: SessionProcessingFeatureState {
        .unavailable(
            SessionProcessingUnavailableSnapshot(
                selection: nil,
                reason: .noSession,
                actions: []
            )
        )
    }

    func send(_ command: SessionProcessingCommand) async {
        commands.append(command)
    }

    func reserveLibraryNavigation() async -> Bool { true }

    func finishLibraryNavigation(didMutateLibrary: Bool) async {
        navigationMutations.append(didMutateLibrary)
    }
}

private actor LibrarySelectionTrace {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

private actor SelectionChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { continuation in
        continuation.finish()
    }

    private let flushResult: Bool
    private let trace: LibrarySelectionTrace
    private(set) var commands: [ChatCommand] = []

    init(flushResult: Bool, trace: LibrarySelectionTrace) {
        self.flushResult = flushResult
        self.trace = trace
    }

    var currentState: ChatFeatureState { ChatFeatureState() }

    func currentState(in scope: LibraryScope) -> ChatFeatureState? { nil }

    func send(_ command: ChatCommand) async {
        commands.append(command)
    }

    func flushForOrderlyTermination() async -> Bool {
        await trace.append("chat.flush")
        return flushResult
    }
}

private actor SuspendedBoundaryChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { continuation in
        continuation.finish()
    }

    private let trace: LibrarySelectionTrace
    private var commandStarted = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var commands: [ChatCommand] = []

    init(trace: LibrarySelectionTrace) {
        self.trace = trace
    }

    var currentState: ChatFeatureState { ChatFeatureState() }

    func currentState(in scope: LibraryScope) -> ChatFeatureState? { nil }

    func send(_ command: ChatCommand) async {
        commands.append(command)
        commandStarted = true
        await withCheckedContinuation { continuation = $0 }
    }

    func flushForOrderlyTermination() async -> Bool { true }

    func waitUntilCommandStarts() async {
        while !commandStarted { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SuspendedOrderedApplicationChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { continuation in
        continuation.finish()
    }

    private var firstEditStarted = false
    private var firstEditContinuation: CheckedContinuation<Void, Never>?
    private(set) var commands: [ChatCommand] = []
    private(set) var flushCallCount = 0

    var currentState: ChatFeatureState { ChatFeatureState() }

    func currentState(in scope: LibraryScope) -> ChatFeatureState? { nil }

    func send(_ command: ChatCommand) async {
        commands.append(command)
        guard case .editDraft = command, !firstEditStarted else { return }
        firstEditStarted = true
        await withCheckedContinuation { firstEditContinuation = $0 }
    }

    func flushForOrderlyTermination() async -> Bool {
        flushCallCount += 1
        return true
    }

    func waitUntilFirstEditStarts() async {
        while !firstEditStarted { await Task.yield() }
    }

    func resumeFirstEdit() {
        firstEditContinuation?.resume()
        firstEditContinuation = nil
    }
}

private actor SuspendedCrossFeatureChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { continuation in
        continuation.finish()
    }

    private let trace: LibrarySelectionTrace
    private var commandStarted = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var commands: [ChatCommand] = []

    init(trace: LibrarySelectionTrace) {
        self.trace = trace
    }

    var currentState: ChatFeatureState { ChatFeatureState() }

    func currentState(in scope: LibraryScope) -> ChatFeatureState? { nil }

    func send(_ command: ChatCommand) async {
        commands.append(command)
        await trace.append("chat.edit")
        commandStarted = true
        await withCheckedContinuation { continuation = $0 }
    }

    func flushForOrderlyTermination() async -> Bool {
        await trace.append("chat.flush")
        return true
    }

    func waitUntilCommandStarts() async {
        while !commandStarted { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SuspendedTerminationChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { continuation in
        continuation.finish()
    }

    private let flushResult: Bool
    private let trace: LibrarySelectionTrace
    private var flushStarted = false
    private var flushCount = 0
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var commands: [ChatCommand] = []

    init(flushResult: Bool, trace: LibrarySelectionTrace) {
        self.flushResult = flushResult
        self.trace = trace
    }

    var currentState: ChatFeatureState { ChatFeatureState() }

    func currentState(in scope: LibraryScope) -> ChatFeatureState? { nil }

    func send(_ command: ChatCommand) async {
        commands.append(command)
    }

    func flushForOrderlyTermination() async -> Bool {
        await trace.append("chat.flush")
        flushCount += 1
        guard flushCount == 1 else { return flushResult }
        flushStarted = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilFlushStarts() async {
        while !flushStarted { await Task.yield() }
    }

    func resume() {
        continuation?.resume(returning: flushResult)
        continuation = nil
    }
}

private actor SuspendedSelectionLibraryFeature: LibraryFeature {
    nonisolated let states = AsyncStream<LibraryFeatureState> { continuation in
        continuation.finish()
    }

    private let trace: LibrarySelectionTrace
    private var sendStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(trace: LibrarySelectionTrace) {
        self.trace = trace
    }

    var currentState: LibraryFeatureState {
        LibraryFeatureState(selection: .awaitingBootstrap)
    }

    func send(_ command: LibraryCommand) async -> LibraryCommandResult {
        await trace.append("library.suspended")
        sendStarted = true
        await withCheckedContinuation { continuation = $0 }
        return .deactivated
    }

    func waitUntilSendStarts() async {
        while !sendStarted { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SelectionLibraryFeature: LibraryFeature {
    nonisolated let states = AsyncStream<LibraryFeatureState> { continuation in
        continuation.finish()
    }

    private let trace: LibrarySelectionTrace

    init(trace: LibrarySelectionTrace) {
        self.trace = trace
    }

    var currentState: LibraryFeatureState {
        LibraryFeatureState(selection: .awaitingBootstrap)
    }

    func send(_ command: LibraryCommand) async -> LibraryCommandResult {
        switch command {
        case .close:
            await trace.append("library.close")
            return .deactivated
        default:
            await trace.append("library.other")
            return .deactivated
        }
    }
}

private actor IdenticalReplacementLibraryFeature: LibraryFeature {
    nonisolated let states = AsyncStream<LibraryFeatureState> { continuation in
        continuation.finish()
    }

    private let snapshot: ActiveLibrarySnapshot
    private let activationGeneration: UInt64
    private let trace: LibrarySelectionTrace
    private(set) var commands: [LibraryCommand] = []

    init(
        snapshot: ActiveLibrarySnapshot,
        activationGeneration: UInt64 = 2,
        trace: LibrarySelectionTrace
    ) {
        self.snapshot = snapshot
        self.activationGeneration = activationGeneration
        self.trace = trace
    }

    var currentState: LibraryFeatureState {
        LibraryFeatureState(selection: .active(snapshot))
    }

    func send(_ command: LibraryCommand) async -> LibraryCommandResult {
        commands.append(command)
        await trace.append("library.identicalReplacement")
        return .activated(
            LibraryActivation(
                scope: LibraryScope(libraryID: snapshot.libraryID),
                generation: activationGeneration
            )
        )
    }
}

private actor FailedReplacementLibraryFeature: LibraryFeature {
    nonisolated let states = AsyncStream<LibraryFeatureState> { continuation in
        continuation.finish()
    }

    private let snapshot: ActiveLibrarySnapshot
    private let trace: LibrarySelectionTrace

    init(snapshot: ActiveLibrarySnapshot, trace: LibrarySelectionTrace) {
        self.snapshot = snapshot
        self.trace = trace
    }

    var currentState: LibraryFeatureState {
        LibraryFeatureState(
            selection: .active(snapshot),
            notice: .candidateUnavailable
        )
    }

    func send(_ command: LibraryCommand) async -> LibraryCommandResult {
        await trace.append("library.failedReplacement")
        return .noSelectionMutation
    }
}

private actor SuspendedActivationLibraryFeature: LibraryFeature {
    nonisolated let states = AsyncStream<LibraryFeatureState> { continuation in
        continuation.finish()
    }

    private var results: [LibraryCommandResult]
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var commands: [LibraryCommand] = []

    init(results: [LibraryCommandResult]) {
        self.results = results
    }

    var currentState: LibraryFeatureState {
        LibraryFeatureState(selection: .awaitingBootstrap)
    }

    func send(_ command: LibraryCommand) async -> LibraryCommandResult {
        commands.append(command)
        await withCheckedContinuation { continuations.append($0) }
        return results.removeFirst()
    }

    func waitForCommandCount(_ count: Int) async {
        while commands.count < count { await Task.yield() }
    }

    func resumeNextCommand() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor BooleanReceiptProbe {
    private(set) var result: Bool?

    func complete(_ result: Bool) {
        self.result = result
    }
}
