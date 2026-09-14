@testable import AudoraApplication
import AudoraDomain
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class LibraryCatalogFeatureTests: XCTestCase {
    func testRefreshReturnsThePortableCatalog() async throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC")
        )
        let activation = LibraryActivation(scope: scope, generation: 1)
        let catalog = LibraryCatalogSnapshot(
            active: [
                catalogRow(
                    .session(try SessionID("ses-20260822T153045123Z-P4R7"))
                ),
            ],
            trash: [
                catalogRow(
                    .chat(try ChatID("cht-20260822T160201044Z-9NQF"))
                ),
            ]
        )
        let port = ScriptedLibraryAggregateTrashPort(catalog: .available(catalog))
        let activityCoordinator = LibraryActivityCoordinator()
        await activate(activation, on: activityCoordinator)
        let feature = DefaultLibraryCatalogFeature(
            port: port,
            activityCoordinator: activityCoordinator
        )

        let result = await feature.send(.refresh(activation))

        XCTAssertEqual(result, .catalog(.available(catalog)))
        let calls = await port.calls
        XCTAssertEqual(calls, [.loadCatalog(activation)])
    }

    func testMoveToTrashProcessesUniqueSelectionInStableOrderThenRefreshes() async throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC")
        )
        let activation = LibraryActivation(scope: scope, generation: 1)
        let session = LibraryAggregate.session(
            try SessionID("ses-20260822T153045123Z-P4R7")
        )
        let chat = LibraryAggregate.chat(
            try ChatID("cht-20260822T160201044Z-9NQF")
        )
        let refreshed = LibraryCatalogSnapshot(
            active: [],
            trash: [catalogRow(session), catalogRow(chat)]
        )
        let port = ScriptedLibraryAggregateTrashPort(
            catalog: .available(refreshed),
            moveOutcomes: [session: .succeeded, chat: .busy]
        )
        let activityCoordinator = LibraryActivityCoordinator()
        await activate(activation, on: activityCoordinator)
        let feature = DefaultLibraryCatalogFeature(
            port: port,
            activityCoordinator: activityCoordinator
        )

        let result = await feature.send(
            .moveToTrash(activation, [chat, session, chat]),
            lifecycle: SuccessfulLibraryCatalogMutationLifecycle()
        )

        XCTAssertEqual(
            result,
            .mutation(
                [
                    LibraryAggregateMutationResult(
                        aggregate: session,
                        outcome: .succeeded
                    ),
                    LibraryAggregateMutationResult(
                        aggregate: chat,
                        outcome: .busy
                    ),
                ],
                catalog: .available(refreshed)
            )
        )
        let calls = await port.calls
        XCTAssertEqual(
            calls,
            [
                .moveToTrash(session, activation),
                .moveToTrash(chat, activation),
                .loadCatalog(activation),
            ]
        )
    }

    func testRestoreReportsEachIdentityWithoutHidingACollision() async throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC")
        )
        let activation = LibraryActivation(scope: scope, generation: 1)
        let session = LibraryAggregate.session(
            try SessionID("ses-20260822T153045123Z-P4R7")
        )
        let chat = LibraryAggregate.chat(
            try ChatID("cht-20260822T160201044Z-9NQF")
        )
        let catalog = LibraryCatalogSnapshot(
            active: [catalogRow(session)],
            trash: [catalogRow(chat)]
        )
        let port = ScriptedLibraryAggregateTrashPort(
            catalog: .available(catalog),
            restoreOutcomes: [session: .targetCollision, chat: .succeeded]
        )
        let activityCoordinator = LibraryActivityCoordinator()
        await activate(activation, on: activityCoordinator)

        let result = await DefaultLibraryCatalogFeature(
            port: port,
            activityCoordinator: activityCoordinator
        ).send(
            .restore(activation, [chat, session]),
            lifecycle: SuccessfulLibraryCatalogMutationLifecycle()
        )

        XCTAssertEqual(
            result,
            .mutation(
                [
                    LibraryAggregateMutationResult(
                        aggregate: session,
                        outcome: .targetCollision
                    ),
                    LibraryAggregateMutationResult(
                        aggregate: chat,
                        outcome: .succeeded
                    ),
                ],
                catalog: .available(catalog)
            )
        )
    }

    func testFailedAndCommitUncertainMovesStillReceiveOneAuthoritativeRefresh()
        async throws
    {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC")
        )
        let activation = LibraryActivation(scope: scope, generation: 1)
        let session = LibraryAggregate.session(
            try SessionID("ses-20260822T153045123Z-P4R7")
        )
        let chat = LibraryAggregate.chat(
            try ChatID("cht-20260822T160201044Z-9NQF")
        )
        let refreshed = LibraryCatalogSnapshot(
            active: [catalogRow(chat)],
            trash: [catalogRow(session)]
        )
        let port = ScriptedLibraryAggregateTrashPort(
            catalog: .available(refreshed),
            moveOutcomes: [
                session: .commitUncertain,
                chat: .failed,
            ]
        )
        let activityCoordinator = LibraryActivityCoordinator()
        await activate(activation, on: activityCoordinator)

        let result = await DefaultLibraryCatalogFeature(
            port: port,
            activityCoordinator: activityCoordinator
        ).send(
            .moveToTrash(activation, [chat, session]),
            lifecycle: SuccessfulLibraryCatalogMutationLifecycle()
        )

        XCTAssertEqual(
            result,
            .mutation(
                [
                    LibraryAggregateMutationResult(
                        aggregate: session,
                        outcome: .commitUncertain
                    ),
                    LibraryAggregateMutationResult(
                        aggregate: chat,
                        outcome: .failed
                    ),
                ],
                catalog: .available(refreshed)
            )
        )
        let calls = await port.calls
        XCTAssertEqual(
            calls,
            [
                .moveToTrash(session, activation),
                .moveToTrash(chat, activation),
                .loadCatalog(activation),
            ]
        )
    }

    func testStaleActivationIsRejectedWithoutCallingThePort() async throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC")
        )
        let staleActivation = LibraryActivation(scope: scope, generation: 1)
        let currentActivation = LibraryActivation(scope: scope, generation: 2)
        let session = LibraryAggregate.session(
            try SessionID("ses-20260822T153045123Z-P4R7")
        )
        let chat = LibraryAggregate.chat(
            try ChatID("cht-20260822T160201044Z-9NQF")
        )
        let port = ScriptedLibraryAggregateTrashPort(
            catalog: .available(.init(active: [], trash: []))
        )
        let activityCoordinator = LibraryActivityCoordinator()
        await activate(currentActivation, on: activityCoordinator)
        let feature = DefaultLibraryCatalogFeature(
            port: port,
            activityCoordinator: activityCoordinator
        )

        let result = await feature.send(
            .moveToTrash(staleActivation, [chat, session]),
            lifecycle: SuccessfulLibraryCatalogMutationLifecycle()
        )

        XCTAssertEqual(
            result,
            .mutation(
                [
                    LibraryAggregateMutationResult(
                        aggregate: session,
                        outcome: .unavailable
                    ),
                    LibraryAggregateMutationResult(
                        aggregate: chat,
                        outcome: .unavailable
                    ),
                ],
                catalog: .unavailable
            )
        )
        let calls = await port.calls
        XCTAssertEqual(calls, [])
    }

    func testBusyLibraryActivityRejectsMutationBeforeDependentFeaturesQuiesce()
        async throws
    {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC")
        )
        let activation = LibraryActivation(scope: scope, generation: 1)
        let aggregate = LibraryAggregate.chat(
            try ChatID("cht-20260822T160201044Z-9NQF")
        )
        let port = ScriptedLibraryAggregateTrashPort(
            catalog: .available(
                .init(active: [catalogRow(aggregate)], trash: [])
            )
        )
        let activityCoordinator = LibraryActivityCoordinator()
        await activate(activation, on: activityCoordinator)
        let acquiredRecordingLease = await activityCoordinator.acquireRecording(
            in: scope
        )
        let recordingLease = try XCTUnwrap(acquiredRecordingLease)
        let lifecycle = RecordingLibraryCatalogMutationLifecycle()
        let feature = DefaultLibraryCatalogFeature(
            port: port,
            activityCoordinator: activityCoordinator
        )

        let result = await feature.send(
            .moveToTrash(activation, [aggregate]),
            lifecycle: lifecycle
        )

        XCTAssertEqual(
            result,
            .mutationRefused([
                LibraryAggregateMutationResult(
                    aggregate: aggregate,
                    outcome: .busy
                ),
            ])
        )
        let prepareCallCount = await lifecycle.prepareCallCount
        let reloadCallCount = await lifecycle.reloadCallCount
        let portCalls = await port.calls
        XCTAssertEqual(prepareCallCount, 0)
        XCTAssertEqual(reloadCallCount, 0)
        XCTAssertEqual(portCalls, [])
        await activityCoordinator.release(recordingLease)
    }

    func testRefusedLifecycleReleasesCatalogLeaseWithoutTouchingStorage()
        async throws
    {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC")
        )
        let activation = LibraryActivation(scope: scope, generation: 1)
        let aggregate = LibraryAggregate.session(
            try SessionID("ses-20260822T153045123Z-P4R7")
        )
        let port = ScriptedLibraryAggregateTrashPort(
            catalog: .available(.init(active: [catalogRow(aggregate)], trash: []))
        )
        let activityCoordinator = LibraryActivityCoordinator()
        await activate(activation, on: activityCoordinator)
        let feature = DefaultLibraryCatalogFeature(
            port: port,
            activityCoordinator: activityCoordinator
        )

        let result = await feature.send(
            .moveToTrash(activation, [aggregate]),
            lifecycle: RefusingLibraryCatalogMutationLifecycle()
        )

        XCTAssertEqual(
            result,
            .mutationRefused([
                LibraryAggregateMutationResult(
                    aggregate: aggregate,
                    outcome: .busy
                ),
            ])
        )
        let calls = await port.calls
        XCTAssertEqual(calls, [])
        let leaseAfterRefusal = await activityCoordinator.acquireSelectionMutation()
        XCTAssertNotNil(leaseAfterRefusal)
        if let leaseAfterRefusal {
            await activityCoordinator.release(leaseAfterRefusal)
        }
    }

    func testCatalogLeaseCoversTheEntireBatchAndAuthoritativeRefresh() async throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC")
        )
        let activation = LibraryActivation(scope: scope, generation: 1)
        let session = LibraryAggregate.session(
            try SessionID("ses-20260822T153045123Z-P4R7")
        )
        let chat = LibraryAggregate.chat(
            try ChatID("cht-20260822T160201044Z-9NQF")
        )
        let refreshed = LibraryCatalogSnapshot(
            active: [],
            trash: [catalogRow(session), catalogRow(chat)]
        )
        let port = SuspendingLibraryAggregateTrashPort(
            catalog: .available(refreshed)
        )
        let activityCoordinator = LibraryActivityCoordinator()
        await activate(activation, on: activityCoordinator)
        let feature = DefaultLibraryCatalogFeature(
            port: port,
            activityCoordinator: activityCoordinator
        )

        let batch = Task {
            await feature.send(
                .moveToTrash(activation, [chat, session]),
                lifecycle: SuccessfulLibraryCatalogMutationLifecycle()
            )
        }
        await port.waitUntilFirstMoveStarts()

        let interleavingSelectionLease = await activityCoordinator
            .acquireSelectionMutation()
        XCTAssertNil(interleavingSelectionLease)

        await port.resumeFirstMove()
        await port.waitUntilRefreshStarts()

        let interleavingSelectionLeaseDuringRefresh = await activityCoordinator
            .acquireSelectionMutation()
        XCTAssertNil(interleavingSelectionLeaseDuringRefresh)

        await port.resumeRefresh()
        let result = await batch.value

        XCTAssertEqual(
            result,
            .mutation(
                [
                    LibraryAggregateMutationResult(
                        aggregate: session,
                        outcome: .succeeded
                    ),
                    LibraryAggregateMutationResult(
                        aggregate: chat,
                        outcome: .succeeded
                    ),
                ],
                catalog: .available(refreshed)
            )
        )
        let calls = await port.calls
        XCTAssertEqual(
            calls,
            [
                .moveToTrash(session, activation),
                .moveToTrash(chat, activation),
                .loadCatalog(activation),
            ]
        )
        let selectionLeaseAfterBatch = await activityCoordinator
            .acquireSelectionMutation()
        XCTAssertNotNil(selectionLeaseAfterBatch)
        if let selectionLeaseAfterBatch {
            await activityCoordinator.release(selectionLeaseAfterBatch)
        }
    }

    private func activate(
        _ activation: LibraryActivation,
        on activityCoordinator: any LibraryActivityCoordinating,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard let lease = await activityCoordinator.acquireSelectionMutation()
        else {
            XCTFail(
                "Expected to acquire a selection mutation lease",
                file: file,
                line: line
            )
            return
        }
        await activityCoordinator.finishSelectionMutation(
            lease,
            authorityUpdate: .activate(activation)
        )
    }
}

private struct SuccessfulLibraryCatalogMutationLifecycle:
    LibraryCatalogMutationLifecycle
{
    func prepareForLibraryCatalogMutation(
        _ command: LibraryCatalogCommand
    ) async -> LibraryCatalogMutationPreparationResult {
        .prepared
    }

    func reloadAfterLibraryCatalogMutation(
        _ command: LibraryCatalogCommand,
        result: LibraryCatalogCommandResult
    ) async -> Bool {
        true
    }
}

private struct RefusingLibraryCatalogMutationLifecycle:
    LibraryCatalogMutationLifecycle
{
    func prepareForLibraryCatalogMutation(
        _ command: LibraryCatalogCommand
    ) async -> LibraryCatalogMutationPreparationResult {
        .refused
    }

    func reloadAfterLibraryCatalogMutation(
        _ command: LibraryCatalogCommand,
        result: LibraryCatalogCommandResult
    ) async -> Bool {
        XCTFail("A refused mutation must not enter reload")
        return false
    }
}

private actor RecordingLibraryCatalogMutationLifecycle:
    LibraryCatalogMutationLifecycle
{
    private(set) var prepareCallCount = 0
    private(set) var reloadCallCount = 0

    func prepareForLibraryCatalogMutation(
        _ command: LibraryCatalogCommand
    ) async -> LibraryCatalogMutationPreparationResult {
        prepareCallCount += 1
        return .prepared
    }

    func reloadAfterLibraryCatalogMutation(
        _ command: LibraryCatalogCommand,
        result: LibraryCatalogCommandResult
    ) async -> Bool {
        reloadCallCount += 1
        return true
    }
}

private extension LibraryCatalogCommandResult {
    static func moveUnavailable(
        _ aggregate: LibraryAggregate
    ) -> LibraryCatalogCommandResult {
        .mutation(
            [
                LibraryAggregateMutationResult(
                    aggregate: aggregate,
                    outcome: .unavailable
                ),
            ],
            catalog: .unavailable
        )
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
private actor ScriptedLibraryAggregateTrashPort: LibraryAggregateTrashPort {
    enum Call: Equatable {
        case loadCatalog(LibraryActivation)
        case moveToTrash(LibraryAggregate, LibraryActivation)
        case restore(LibraryAggregate, LibraryActivation)
    }

    private(set) var calls: [Call] = []
    private let catalog: LibraryCatalogLoadResult
    private let moveOutcomes: [LibraryAggregate: LibraryAggregateMutationOutcome]
    private let restoreOutcomes: [LibraryAggregate: LibraryAggregateMutationOutcome]

    init(
        catalog: LibraryCatalogLoadResult,
        moveOutcomes: [LibraryAggregate: LibraryAggregateMutationOutcome] = [:],
        restoreOutcomes: [LibraryAggregate: LibraryAggregateMutationOutcome] = [:]
    ) {
        self.catalog = catalog
        self.moveOutcomes = moveOutcomes
        self.restoreOutcomes = restoreOutcomes
    }

    func loadCatalog(
        for activation: LibraryActivation
    ) -> LibraryCatalogLoadResult {
        calls.append(.loadCatalog(activation))
        return catalog
    }

    func moveToTrash(
        _ aggregate: LibraryAggregate,
        for activation: LibraryActivation
    ) -> LibraryAggregateMutationOutcome {
        calls.append(.moveToTrash(aggregate, activation))
        return moveOutcomes[aggregate] ?? .succeeded
    }

    func restore(
        _ aggregate: LibraryAggregate,
        for activation: LibraryActivation
    ) -> LibraryAggregateMutationOutcome {
        calls.append(.restore(aggregate, activation))
        return restoreOutcomes[aggregate] ?? .succeeded
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
private actor SuspendingLibraryAggregateTrashPort: LibraryAggregateTrashPort {
    typealias Call = ScriptedLibraryAggregateTrashPort.Call

    private(set) var calls: [Call] = []
    private let catalog: LibraryCatalogLoadResult
    private var didStartFirstMove = false
    private var firstMoveStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstMoveContinuation: CheckedContinuation<Void, Never>?
    private var didStartRefresh = false
    private var refreshStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var refreshContinuation: CheckedContinuation<Void, Never>?

    init(catalog: LibraryCatalogLoadResult) {
        self.catalog = catalog
    }

    func waitUntilFirstMoveStarts() async {
        if didStartFirstMove { return }
        await withCheckedContinuation { continuation in
            firstMoveStartWaiters.append(continuation)
        }
    }

    func resumeFirstMove() {
        firstMoveContinuation?.resume()
        firstMoveContinuation = nil
    }

    func waitUntilRefreshStarts() async {
        if didStartRefresh { return }
        await withCheckedContinuation { continuation in
            refreshStartWaiters.append(continuation)
        }
    }

    func resumeRefresh() {
        refreshContinuation?.resume()
        refreshContinuation = nil
    }

    func loadCatalog(
        for activation: LibraryActivation
    ) async -> LibraryCatalogLoadResult {
        calls.append(.loadCatalog(activation))
        didStartRefresh = true
        let waiters = refreshStartWaiters
        refreshStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            refreshContinuation = continuation
        }
        return catalog
    }

    func moveToTrash(
        _ aggregate: LibraryAggregate,
        for activation: LibraryActivation
    ) async -> LibraryAggregateMutationOutcome {
        calls.append(.moveToTrash(aggregate, activation))
        guard !didStartFirstMove else { return .succeeded }

        didStartFirstMove = true
        let waiters = firstMoveStartWaiters
        firstMoveStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            firstMoveContinuation = continuation
        }
        return .succeeded
    }

    func restore(
        _ aggregate: LibraryAggregate,
        for activation: LibraryActivation
    ) -> LibraryAggregateMutationOutcome {
        calls.append(.restore(aggregate, activation))
        return .succeeded
    }
}

private func catalogRow(_ aggregate: LibraryAggregate) -> LibraryCatalogRow {
    let instant = try! UTCInstant("2026-08-30T12:00:00.000Z")
    switch aggregate {
    case let .session(sessionID):
        return .session(
            sessionID,
            LibrarySessionCatalogMetadata(
                acquisition: .recorded,
                createdAt: instant,
                hasSelectedTranscript: true
            )
        )
    case let .chat(chatID):
        return .chat(
            chatID,
            LibraryChatCatalogMetadata(
                title: .newChat,
                createdAt: instant,
                updatedAt: instant
            )
        )
    }
}
