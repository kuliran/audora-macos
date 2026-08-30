@testable import AudoraApplication
import AudoraDomain
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class LibraryFeatureTests: XCTestCase {
    func testStartRestoresExactPortableAuthorityWithoutGeneratingDefaults() async throws {
        let restored = try snapshot(
            id: "lib-20260830T120000000Z-2ABC",
            annotationsVisible: false,
            playbackRate: 1.25
        )
        let workspace = ScriptedWorkspace(restore: [.opened(restored)])
        let clock = RecordingClock()
        let ids = RecordingIDGenerator()
        let feature = DefaultLibraryFeature(
            workspace: workspace,
            clock: clock,
            idGenerator: ids
        )

        await feature.send(.start)
        await feature.send(.start)

        let finalState = await feature.currentState
        let calls = await workspace.calls
        let clockCalls = await clock.callCount
        let idCalls = await ids.callCount
        XCTAssertEqual(finalState, LibraryFeatureState(selection: .active(restored)))
        XCTAssertEqual(calls, [.restore])
        XCTAssertEqual(clockCalls, 0)
        XCTAssertEqual(idCalls, 0)
    }

    func testCreateUsesOneClockAndTypedIDAndInstallsNullProfileSeed() async throws {
        let created = try snapshot(id: "lib-20260830T120000000Z-2ABC")
        let workspace = ScriptedWorkspace(
            restore: [.noLibrarySelected(recentAvailable: false)],
            create: [.opened(created)]
        )
        let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
        let clock = RecordingClock(value: instant)
        let ids = RecordingIDGenerator(
            value: try LibraryID("lib-20260830T120000000Z-2ABC")
        )
        let feature = DefaultLibraryFeature(
            workspace: workspace,
            clock: clock,
            idGenerator: ids
        )
        await feature.send(.start)

        await feature.send(.create)

        let finalState = await feature.currentState
        XCTAssertEqual(finalState, LibraryFeatureState(selection: .active(created)))
        let seeds = await workspace.createSeeds
        XCTAssertEqual(seeds.count, 1)
        XCTAssertEqual(seeds[0].libraryID, try LibraryID("lib-20260830T120000000Z-2ABC"))
        XCTAssertEqual(seeds[0].createdAt, instant)
        XCTAssertEqual(seeds[0].preferences, .defaults)
        XCTAssertEqual(seeds[0].profileHead.selection, .null)
        XCTAssertEqual(seeds[0].profileHead.generation, 0)
        XCTAssertEqual(seeds[0].profileHead.statementGeneration, 0)
    }

    func testFailedCandidateAndCancellationRetainTheOldActiveScope() async throws {
        let original = try snapshot(id: "lib-20260830T120000000Z-2ABC")
        let workspace = ScriptedWorkspace(
            restore: [.opened(original)],
            choose: [.failed(.candidateCorrupt), .cancelled]
        )
        let feature = makeFeature(workspace)
        await feature.send(.start)

        await feature.send(.chooseExisting)
        let failedState = await feature.currentState
        XCTAssertEqual(
            failedState,
            LibraryFeatureState(selection: .active(original), notice: .candidateCorrupt)
        )

        await feature.send(.chooseExisting)
        let cancelledState = await feature.currentState
        XCTAssertEqual(cancelledState, LibraryFeatureState(selection: .active(original)))
    }

    func testCloseAndReopenRecentRestoreTheIdenticalSnapshot() async throws {
        let original = try snapshot(id: "lib-20260830T120000000Z-2ABC")
        let workspace = ScriptedWorkspace(
            restore: [.opened(original)],
            reopen: [.opened(original)],
            close: [.succeeded(recentAvailable: true)]
        )
        let feature = makeFeature(workspace)
        await feature.send(.start)

        await feature.send(.close)
        let closedState = await feature.currentState
        XCTAssertEqual(
            closedState,
            LibraryFeatureState(selection: .noLibrarySelected(recentAvailable: true))
        )
        await feature.send(.reopenRecent)
        let reopenedState = await feature.currentState
        XCTAssertEqual(reopenedState, LibraryFeatureState(selection: .active(original)))
    }

    func testRevealDoesNotMutateAuthority() async throws {
        let original = try snapshot(id: "lib-20260830T120000000Z-2ABC")
        let workspace = ScriptedWorkspace(
            restore: [.opened(original)],
            reveal: [.succeeded()]
        )
        let feature = makeFeature(workspace)
        await feature.send(.start)

        await feature.send(.reveal)

        let finalState = await feature.currentState
        let calls = await workspace.calls
        XCTAssertEqual(finalState, LibraryFeatureState(selection: .active(original)))
        XCTAssertEqual(calls, [.restore, .reveal])
    }

    func testExternalOpenSwitchesOnlyAfterSuccessfulOutcome() async throws {
        let original = try snapshot(id: "lib-20260830T120000000Z-2ABC")
        let replacement = try snapshot(id: "lib-20260830T121000000Z-3DEF")
        let token = LibraryOpenRequestToken("token_B")!
        let workspace = ScriptedWorkspace(
            restore: [.opened(original)],
            external: [.opened(replacement)]
        )
        let feature = makeFeature(workspace)
        await feature.send(.start)

        await feature.send(.openExternal(token))

        let finalState = await feature.currentState
        let tokens = await workspace.externalTokens
        XCTAssertEqual(finalState, LibraryFeatureState(selection: .active(replacement)))
        XCTAssertEqual(tokens, [token])
    }

    func testNewerRootProducesReadOnlyRevealableSelection() async throws {
        let libraryID = try LibraryID("lib-20260830T120000000Z-2ABC")
        let readOnly = ReadOnlyLibrarySnapshot(libraryID: libraryID)
        let workspace = ScriptedWorkspace(
            restore: [.readOnly(readOnly, reason: .newerSchema)],
            reveal: [.succeeded()]
        )
        let feature = makeFeature(workspace)

        await feature.send(.start)
        await feature.send(.reveal)

        let finalState = await feature.currentState
        XCTAssertEqual(
            finalState,
            LibraryFeatureState(selection: .readOnly(readOnly, reason: .newerSchema))
        )
    }

    func testConcurrentLifecycleCommandsLaunchOnlyOneWorkspaceEffect() async throws {
        let created = try snapshot(id: "lib-20260830T120000000Z-2ABC")
        let workspace = ScriptedWorkspace(
            restore: [.noLibrarySelected(recentAvailable: false)],
            create: [.opened(created)],
            suspendFirstCreate: true
        )
        let feature = makeFeature(workspace)
        await feature.send(.start)

        let first = Task { await feature.send(.create) }
        await workspace.waitForCreateCall()
        let second = Task { await feature.send(.create) }
        await second.value

        let callsWhileSuspended = await workspace.calls
        XCTAssertEqual(callsWhileSuspended.filter { $0 == .create }.count, 1)
        await workspace.resumeCreate()
        await first.value
        let finalCalls = await workspace.calls
        XCTAssertEqual(finalCalls.filter { $0 == .create }.count, 1)
    }

    func testExternalOpenDuringSuspendedRestoreIsReplayedAfterBootstrap() async throws {
        let restored = try snapshot(id: "lib-20260830T120000000Z-2ABC")
        let external = try snapshot(id: "lib-20260830T121000000Z-3DEF")
        let token = LibraryOpenRequestToken("startup_external")!
        let workspace = ScriptedWorkspace(
            restore: [.opened(restored)],
            external: [.opened(external)],
            suspendFirstRestore: true
        )
        let feature = makeFeature(workspace)
        let completion = CompletionProbe()

        let startup = Task { await feature.send(.start) }
        await workspace.waitForRestoreCall()
        let callback = Task {
            await feature.send(.openExternal(token))
            await completion.markCompleted()
        }
        await waitForQueuedExternalOpen(in: feature)

        let callsWhileRestoring = await workspace.calls
        let returnedWhileRestoring = await completion.isCompleted
        XCTAssertEqual(callsWhileRestoring, [.restore])
        XCTAssertFalse(returnedWhileRestoring)
        await workspace.resumeRestore()
        await startup.value
        await callback.value

        let calls = await workspace.calls
        let externalTokens = await workspace.externalTokens
        let finalState = await feature.currentState
        let returnedAfterReplay = await completion.isCompleted
        XCTAssertEqual(calls, [.restore, .external])
        XCTAssertEqual(externalTokens, [token])
        XCTAssertEqual(finalState, LibraryFeatureState(selection: .active(external)))
        XCTAssertTrue(returnedAfterReplay)
    }

    func testRepeatedExternalCallbacksDuringSuspendedRestoreKeepOnlyLatestRequest() async throws {
        let restored = try snapshot(id: "lib-20260830T120000000Z-2ABC")
        let external = try snapshot(id: "lib-20260830T122000000Z-4GHJ")
        let firstToken = LibraryOpenRequestToken("external_first")!
        let latestToken = LibraryOpenRequestToken("external_latest")!
        let workspace = ScriptedWorkspace(
            restore: [.opened(restored)],
            external: [.opened(external)],
            suspendFirstRestore: true
        )
        let feature = makeFeature(workspace)
        let latestCompletion = CompletionProbe()

        let startup = Task { await feature.send(.start) }
        await workspace.waitForRestoreCall()
        let firstCallback = Task { await feature.send(.openExternal(firstToken)) }
        await waitForQueuedExternalOpen(in: feature)
        let latestCallback = Task {
            await feature.send(.openExternal(latestToken))
            await latestCompletion.markCompleted()
        }

        // Superseding the only queue slot releases the first caller, while the
        // latest caller stays suspended until its request is actually replayed.
        await firstCallback.value
        let queuedCount = await feature.queuedExternalOpenCount
        let callsWhileRestoring = await workspace.calls
        let latestReturnedWhileRestoring = await latestCompletion.isCompleted
        XCTAssertEqual(queuedCount, 1)
        XCTAssertEqual(callsWhileRestoring, [.restore])
        XCTAssertFalse(latestReturnedWhileRestoring)

        await workspace.resumeRestore()
        await startup.value
        await latestCallback.value

        let calls = await workspace.calls
        let externalTokens = await workspace.externalTokens
        let finalState = await feature.currentState
        XCTAssertEqual(calls, [.restore, .external])
        XCTAssertEqual(externalTokens, [latestToken])
        XCTAssertEqual(finalState, LibraryFeatureState(selection: .active(external)))
    }

    func testMultipleExternalRequestPublishesBoundedNoticeWithoutWorkspaceCall() async {
        let workspace = ScriptedWorkspace(
            restore: [.noLibrarySelected(recentAvailable: false)]
        )
        let feature = makeFeature(workspace)
        await feature.send(.start)

        await feature.send(.rejectMultipleExternalOpenRequests)

        let finalState = await feature.currentState
        let calls = await workspace.calls
        XCTAssertEqual(
            finalState,
            LibraryFeatureState(
                selection: .noLibrarySelected(recentAvailable: false),
                notice: .multipleExternalOpenRequests
            )
        )
        XCTAssertEqual(calls, [.restore])
    }

    private func makeFeature(_ workspace: ScriptedWorkspace) -> DefaultLibraryFeature {
        DefaultLibraryFeature(
            workspace: workspace,
            clock: RecordingClock(),
            idGenerator: RecordingIDGenerator()
        )
    }

    private func waitForQueuedExternalOpen(
        in feature: DefaultLibraryFeature
    ) async {
        while await feature.queuedExternalOpenCount == 0 {
            await Task.yield()
        }
    }

    private func snapshot(
        id: String,
        annotationsVisible: Bool = true,
        playbackRate: Double = 1.0
    ) throws -> ActiveLibrarySnapshot {
        ActiveLibrarySnapshot(
            libraryID: try LibraryID(id),
            preferences: try LibraryPreferences(
                language: .english,
                annotationsVisible: annotationsVisible,
                playbackRate: playbackRate
            ),
            profile: .nullProfile(statementCount: 0)
        )
    }
}

private actor CompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

private actor RecordingClock: LibraryClock {
    private let value: UTCInstant
    private(set) var callCount = 0

    init(value: UTCInstant = try! UTCInstant("2026-08-30T12:00:00.000Z")) {
        self.value = value
    }

    func now() async -> UTCInstant {
        callCount += 1
        return value
    }
}

private actor RecordingIDGenerator: LibraryIDGenerator {
    private let value: LibraryID
    private(set) var callCount = 0

    init(value: LibraryID = try! LibraryID("lib-20260830T120000000Z-2ABC")) {
        self.value = value
    }

    func generateLibraryID(at instant: UTCInstant) async -> LibraryID {
        callCount += 1
        return value
    }
}

private actor ScriptedWorkspace: LibraryWorkspacePort {
    enum Call: Equatable {
        case restore
        case create
        case choose
        case external
        case reopen
        case reveal
        case close
    }

    private var restoreOutcomes: [LibraryOpenOutcome]
    private var createOutcomes: [LibraryOpenOutcome]
    private var chooseOutcomes: [LibraryOpenOutcome]
    private var externalOutcomes: [LibraryOpenOutcome]
    private var reopenOutcomes: [LibraryOpenOutcome]
    private var revealOutcomes: [LibraryActionOutcome]
    private var closeOutcomes: [LibraryActionOutcome]
    private let suspendFirstCreate: Bool
    private let suspendFirstRestore: Bool
    private var createContinuation: CheckedContinuation<Void, Never>?
    private var restoreContinuation: CheckedContinuation<Void, Never>?
    private(set) var calls: [Call] = []
    private(set) var createSeeds: [NewLibrarySeed] = []
    private(set) var externalTokens: [LibraryOpenRequestToken] = []

    init(
        restore: [LibraryOpenOutcome] = [],
        create: [LibraryOpenOutcome] = [],
        choose: [LibraryOpenOutcome] = [],
        external: [LibraryOpenOutcome] = [],
        reopen: [LibraryOpenOutcome] = [],
        reveal: [LibraryActionOutcome] = [],
        close: [LibraryActionOutcome] = [],
        suspendFirstCreate: Bool = false,
        suspendFirstRestore: Bool = false
    ) {
        restoreOutcomes = restore
        createOutcomes = create
        chooseOutcomes = choose
        externalOutcomes = external
        reopenOutcomes = reopen
        revealOutcomes = reveal
        closeOutcomes = close
        self.suspendFirstCreate = suspendFirstCreate
        self.suspendFirstRestore = suspendFirstRestore
    }

    func restoreActiveLibrary() async -> LibraryOpenOutcome {
        calls.append(.restore)
        if suspendFirstRestore, calls.filter({ $0 == .restore }).count == 1 {
            await withCheckedContinuation { continuation in
                restoreContinuation = continuation
            }
        }
        return pop(&restoreOutcomes, fallback: .noLibrarySelected(recentAvailable: false))
    }

    func createLibrary(_ seed: NewLibrarySeed) async -> LibraryOpenOutcome {
        calls.append(.create)
        createSeeds.append(seed)
        if suspendFirstCreate, calls.filter({ $0 == .create }).count == 1 {
            await withCheckedContinuation { continuation in
                createContinuation = continuation
            }
        }
        return pop(&createOutcomes, fallback: .failed(.createFailed))
    }

    func chooseLibrary() async -> LibraryOpenOutcome {
        calls.append(.choose)
        return pop(&chooseOutcomes, fallback: .cancelled)
    }

    func openExternalRequest(_ token: LibraryOpenRequestToken) async -> LibraryOpenOutcome {
        calls.append(.external)
        externalTokens.append(token)
        return pop(&externalOutcomes, fallback: .failed(.externalOpenRequestExpired))
    }

    func reopenRecentLibrary() async -> LibraryOpenOutcome {
        calls.append(.reopen)
        return pop(&reopenOutcomes, fallback: .failed(.selectionRequired))
    }

    func revealActiveLibrary() async -> LibraryActionOutcome {
        calls.append(.reveal)
        return pop(&revealOutcomes, fallback: .failed(.revealFailed))
    }

    func closeActiveLibrary() async -> LibraryActionOutcome {
        calls.append(.close)
        return pop(&closeOutcomes, fallback: .failed(.closeFailed))
    }

    func waitForCreateCall() async {
        while !calls.contains(.create) { await Task.yield() }
    }

    func waitForRestoreCall() async {
        while !calls.contains(.restore) { await Task.yield() }
    }

    func resumeCreate() {
        createContinuation?.resume()
        createContinuation = nil
    }

    func resumeRestore() {
        restoreContinuation?.resume()
        restoreContinuation = nil
    }

    private func pop<T>(_ values: inout [T], fallback: T) -> T {
        values.isEmpty ? fallback : values.removeFirst()
    }
}
