@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
@testable @_spi(InvocationInfrastructure) import AudoraMacInfrastructure
import CryptoKit
import Darwin
import Foundation
import XCTest

private enum TestInvocationReservationOutcome: Equatable {
    case acquired
    case blockedByActiveInvocation
    case ineligible
    case unavailable
}

private extension PortableInvocationStore {
    func reserveInvocation(
        _ request: PendingCoachInvocationRequest
    ) async -> TestInvocationReservationOutcome {
        switch await acquirePendingInvocation(request) {
        case .acquired: .acquired
        case .activeExists: .blockedByActiveInvocation
        case .ineligible: .ineligible
        case .unavailable: .unavailable
        }
    }
}

final class PortableInvocationStoreTests: XCTestCase {
    func testV3InvocationAndProofPersistNoProviderTransportAuthority() async throws {
        try await withTemporaryParent { parent in
            let handle = try CoachProviderTranscriptHandle(
                "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            )
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                transcriptHandles: [handle]
            )
            let transport = try XCTUnwrap(
                fixture.install.invocation.attempt.transportAuthority
            )
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)

            let invocationRoot = fixture.root
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(
                    fixture.install.invocation.id.rawValue,
                    isDirectory: true
                )
            let invocationData = try Data(contentsOf: invocationRoot
                .appendingPathComponent("invocation.json"))
            let proofData = try Data(contentsOf: invocationRoot
                .appendingPathComponent("publication-proof.json"))
            for data in [invocationData, proofData] {
                let text = try XCTUnwrap(String(data: data, encoding: .utf8))
                XCTAssertFalse(text.contains("providerIdempotencyValue"))
                XCTAssertFalse(text.contains("transcriptHandles"))
                XCTAssertFalse(
                    text.contains(transport.providerIdempotencyValue.rawValue)
                )
                XCTAssertFalse(text.contains(handle.rawValue))
            }

            let root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: invocationData) as? [String: Any]
            )
            let attempts = try XCTUnwrap(root["attempts"] as? [[String: Any]])
            XCTAssertEqual(Set(try XCTUnwrap(attempts.first).keys), [
                "attemptId", "ordinal", "kind", "userMessageId",
                "coachMessageId", "freshDraftId",
            ])
        }
    }

    func testRetryInstallReturnsOnlyAfterPendingIsDurablyProcessing() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                pendingFailure: .coachProviderError
            )
            let store = PortableInvocationStore(workspace: fixture.workspace)
            guard case let .opened(pendingSession) = await store
                .openPendingInvocation(fixture.install.authority.request),
                case let .installed(activeSession) = await pendingSession.install(
                    fixture.install
                )
            else { return XCTFail("Retry Invocation was not installed") }

            XCTAssertNil(activeSession.processingAggregate.pendingUserTurn?.failure)
            let chats = PortableChatStore(workspace: fixture.workspace)
            guard case let .loaded(persisted) = await chats.load(
                fixture.locked.chat.id,
                in: fixture.scope
            ) else { return XCTFail("processing Retry was not readable") }
            XCTAssertNil(persisted.pendingUserTurn?.failure)

            _ = await activeSession.abort()
        }
    }

    func testRetryProcessingFaultsReconcileBeforeProviderAuthorityReturns() async throws {
        let points: [PortableChatFaultPoint] = [
            .afterInvocationInstall,
            .beforeRetryProcessingPendingPartialWrite,
            .afterRetryProcessingPendingPartialWrite,
            .afterRetryProcessingPendingFileFlush,
            .afterRetryProcessingPendingInstall,
            .afterRetryProcessingPendingDirectoryFlush,
            .afterRetryProcessingAuthorityRebind,
        ]
        try await withTemporaryParent { parent in
            for (index, point) in points.enumerated() {
                let caseParent = parent.appendingPathComponent(
                    "processing-fault-\(index)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: caseParent,
                    withIntermediateDirectories: false
                )
                let fixture = try await makeInvocationStoreFixture(
                    in: caseParent,
                    libraryID: "lib-20260830T12005\(index)000Z-2ABC",
                    pendingFailure: .coachProviderError
                )
                let injected = OneShot()
                let trace = SynchronousInvocationFaultTrace()
                let store = PortableInvocationStore(
                    persistence: PortableChatPersistence { reached in
                        trace.append(reached)
                        if reached == point, injected.take() {
                            throw PortableChatPersistenceError.injectedFault(reached)
                        }
                    },
                    workspace: fixture.workspace
                )
                guard case let .opened(pendingSession) = await store
                    .openPendingInvocation(fixture.install.authority.request),
                    case let .installed(activeSession) = await pendingSession.install(
                        fixture.install
                    )
                else { return XCTFail("processing uncertainty did not reconcile: \(point)") }
                XCTAssertFalse(injected.take(), "fault was not reached: \(point)")
                XCTAssertNil(
                    activeSession.processingAggregate.pendingUserTurn?.failure,
                    String(describing: point)
                )
                let chats = PortableChatStore(workspace: fixture.workspace)
                guard case let .loaded(persisted) = await chats.load(
                    fixture.locked.chat.id,
                    in: fixture.scope
                ) else { return XCTFail("processing state unavailable: \(point)") }
                XCTAssertNil(
                    persisted.pendingUserTurn?.failure,
                    String(describing: point)
                )
                if point == .afterRetryProcessingPendingInstall {
                    XCTAssertTrue(
                        trace.containsInOrder(
                            .afterRetryProcessingPendingInstall,
                            .afterRetryProcessingPendingDirectoryFlush,
                            .afterRetryProcessingAuthorityRebind
                        ),
                        "provider authority returned without a post-recovery directory flush"
                    )
                }
                if point == .afterInvocationInstall {
                    XCTAssertTrue(
                        trace.containsInOrder(
                            .afterInvocationInstall,
                            .afterReconciledInvocationRootFlush,
                            .afterReconciledInvocationDirectoryFlush,
                            .afterRetryProcessingPendingInstall,
                            .afterRetryProcessingPendingDirectoryFlush,
                            .afterRetryProcessingAuthorityRebind
                        ),
                        "Retry Pending became processing before its reconciled Invocation marker was durable"
                    )
                }
                _ = await activeSession.abort()
            }
        }
    }

    func testRetryTerminalFailureReplacesEveryPriorFailureReason() async throws {
        let priorFailures: [PendingUserTurnFailure] = [
            .coachContextCannotFit,
            .coachResponseInterrupted,
            .coachProviderError,
            .coachResponseInvalid,
        ]
        let terminalFailures: [PendingUserTurnFailure] = [
            .coachProviderError,
            .coachResponseInvalid,
        ]

        try await withTemporaryParent { parent in
            for (index, priorFailure) in priorFailures.enumerated() {
                for (terminalIndex, terminalFailure) in terminalFailures.enumerated() {
                    let caseParent = parent.appendingPathComponent(
                        "prior-\(index)-terminal-\(terminalIndex)",
                        isDirectory: true
                    )
                    try FileManager.default.createDirectory(
                        at: caseParent,
                        withIntermediateDirectories: false
                    )
                    let fixture = try await makeInvocationStoreFixture(
                        in: caseParent,
                        libraryID: "lib-20260830T1200\(index)\(terminalIndex)000Z-2ABC",
                        pendingFailure: priorFailure
                    )
                    let store = PortableInvocationStore(workspace: fixture.workspace)
                    guard case let .opened(pendingSession) = await store
                        .openPendingInvocation(fixture.install.authority.request),
                        case let .installed(activeSession) = await pendingSession.install(
                            fixture.install
                        )
                    else { return XCTFail("Retry Invocation was not installed") }

                    guard case let .committed(aggregate) = await activeSession.abort(
                        failure: terminalFailure
                    ) else { return XCTFail("typed Retry terminal was not committed") }
                    XCTAssertEqual(
                        aggregate.pendingUserTurn?.failure,
                        terminalFailure,
                        "prior: \(priorFailure); terminal: \(terminalFailure)"
                    )
                }
            }
        }
    }

    func testRelaunchPreservesCurrentRetryTerminalWriteAfterCrash() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                pendingFailure: .coachProviderError
            )
            let terminalWriteFault = OneShot()
            let persistence = PortableChatPersistence { point in
                if point == .afterInvocationAbortPendingFailureInstall,
                   terminalWriteFault.take()
                {
                    throw PortableChatPersistenceError.injectedFault(point)
                }
            }
            let lease = try XCTUnwrap(
                persistence.acquireInvocationLivenessLease(
                    at: fixture.root,
                    in: fixture.scope,
                    for: fixture.install.authority.request
                )
            )
            guard case .installed = try persistence.installInvocation(
                fixture.install,
                at: fixture.root,
                holding: lease
            ) else { return XCTFail("Retry Invocation was not installed") }

            XCTAssertThrowsError(
                try persistence.abortInstalledNewSend(
                    fixture.install.invocation,
                    failure: .coachResponseInvalid,
                    at: fixture.root,
                    in: fixture.scope,
                    holding: lease
                )
            )
            XCTAssertFalse(terminalWriteFault.take(), "terminal fault was not reached")
            lease.release()

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let chats = PortableChatStore(workspace: relaunchedWorkspace)
            guard case let .loaded(reopened) = await chats.load(
                fixture.locked.chat.id,
                in: fixture.scope
            ) else { return XCTFail("relaunch did not reconcile typed Retry terminal") }

            XCTAssertEqual(
                reopened.pendingUserTurn?.failure,
                .coachResponseInvalid
            )
            XCTAssertEqual(reopened.chat.messageIDs, [])
        }
    }

    func testTypedTerminalIntentIsDurableBeforePendingMutationAndCannotBeDowngraded()
        async throws
    {
        let cases: [(PortableChatFaultPoint, PendingUserTurnFailure)] = [
            (
                .beforeInvocationTerminalIntentPartialWrite,
                .coachResponseInterrupted
            ),
            (
                .afterInvocationTerminalIntentPartialWrite,
                .coachResponseInterrupted
            ),
            (
                .afterInvocationTerminalIntentFileFlush,
                .coachResponseInterrupted
            ),
            (
                .afterInvocationTerminalIntentInstall,
                .coachResponseInvalid
            ),
            (
                .afterInvocationTerminalIntentDirectoryFlush,
                .coachResponseInvalid
            ),
        ]
        try await withTemporaryParent { parent in
            for (index, testCase) in cases.enumerated() {
                let (point, expectedFailure) = testCase
                let label = String(describing: point)
                let caseParent = parent.appendingPathComponent(
                    "terminal-intent-\(index)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: caseParent,
                    withIntermediateDirectories: false
                )
                let transcriptHandle = try CoachProviderTranscriptHandle(
                    "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
                )
                let fixture = try await makeInvocationStoreFixture(
                    in: caseParent,
                    libraryID: "lib-20260830T12010\(index)000Z-2ABC",
                    pendingFailure: .coachContextCannotFit,
                    transcriptHandles: [transcriptHandle]
                )
                let transport = try XCTUnwrap(
                    fixture.install.invocation.attempt.transportAuthority
                )
                let intentFault = OneShot()
                let persistence = PortableChatPersistence { reached in
                    if reached == point, intentFault.take() {
                        throw PortableChatPersistenceError.injectedFault(reached)
                    }
                }
                let lease = try XCTUnwrap(
                    persistence.acquireInvocationLivenessLease(
                        at: fixture.root,
                        in: fixture.scope,
                        for: fixture.install.authority.request
                    )
                )
                guard case .installed = try persistence.installInvocation(
                    fixture.install,
                    at: fixture.root,
                    holding: lease
                ) else { return XCTFail("Retry Invocation was not installed: \(label)") }

                XCTAssertThrowsError(
                    try persistence.abortInstalledNewSend(
                        fixture.install.invocation,
                        failure: .coachResponseInvalid,
                        at: fixture.root,
                        in: fixture.scope,
                        holding: lease
                    ),
                    label
                )
                XCTAssertFalse(
                    intentFault.take(),
                    "terminal-intent fault was not reached: \(label)"
                )

                let chatRoot = fixture.root
                    .appendingPathComponent("chats", isDirectory: true)
                    .appendingPathComponent(
                        fixture.locked.chat.id.rawValue,
                        isDirectory: true
                    )
                let pendingObject = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: Data(contentsOf: chatRoot.appendingPathComponent(
                            "pending-user-turn.json"
                        ))
                    ) as? [String: Any]
                )
                XCTAssertNil(
                    pendingObject["failure"],
                    "terminal intent must precede Pending mutation: \(label)"
                )

                let invocationRoot = fixture.root
                    .appendingPathComponent("invocations", isDirectory: true)
                    .appendingPathComponent(
                        fixture.install.invocation.id.rawValue,
                        isDirectory: true
                    )
                let invocationURL = invocationRoot.appendingPathComponent(
                    "invocation.json"
                )
                let invocationText = try XCTUnwrap(
                    String(data: Data(contentsOf: invocationURL), encoding: .utf8)
                )
                XCTAssertEqual(
                    invocationText.contains("coachResponseInvalid"),
                    expectedFailure == .coachResponseInvalid,
                    "rename is the terminal-intent commit boundary: \(label)"
                )
                XCTAssertFalse(
                    invocationText.contains("providerIdempotencyValue"),
                    label
                )
                XCTAssertFalse(
                    invocationText.contains(transport.providerIdempotencyValue.rawValue),
                    label
                )
                XCTAssertFalse(invocationText.contains("transcriptHandles"), label)
                XCTAssertFalse(invocationText.contains(transcriptHandle.rawValue), label)
                XCTAssertFalse(
                    try FileManager.default.contentsOfDirectory(
                        atPath: invocationRoot.path
                    ).contains(where: { $0.hasSuffix(".partial") }),
                    label
                )

                lease.release()
                let relaunchedWorkspace = PortableLibraryWorkspace(
                    locations: QueueLocations(existing: [fixture.root]),
                    bookmarks: SyntheticBookmarks(),
                    access: RecordingAccessGrantor(),
                    locatorStore: MemoryLocatorStore(),
                    revealer: RecordingRevealer()
                )
                _ = await relaunchedWorkspace.chooseLibrary()
                let chats = PortableChatStore(workspace: relaunchedWorkspace)
                guard case let .loaded(reopened) = await chats.load(
                    fixture.locked.chat.id,
                    in: fixture.scope
                ) else { return XCTFail("terminal intent was not reconciled: \(label)") }

                XCTAssertEqual(
                    reopened.pendingUserTurn,
                    fixture.locked.pendingUserTurn?.replacingFailure(expectedFailure),
                    label
                )
                XCTAssertNotEqual(
                    reopened.pendingUserTurn?.failure,
                    .coachContextCannotFit,
                    "recovery must not restore the stale pre-Retry failure: \(label)"
                )
                XCTAssertEqual(reopened.chat.messageIDs, [], label)
                XCTAssertFalse(
                    try PortableChatPersistence().hasActiveInvocation(
                        at: fixture.root,
                        in: fixture.scope
                    ),
                    label
                )
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: invocationRoot.path),
                    label
                )
                let chatNames = try FileManager.default.contentsOfDirectory(
                    atPath: chatRoot.path
                )
                XCTAssertFalse(chatNames.contains("aborting-invocation.json"), label)
                XCTAssertFalse(
                    chatNames.contains(where: { $0.hasSuffix(".partial") }),
                    label
                )
            }
        }
    }

    func testRelaunchInterruptsActiveRetryRegardlessOfPriorFailure() async throws {
        let priorFailures: [PendingUserTurnFailure] = [
            .coachContextCannotFit,
            .coachResponseInterrupted,
            .coachProviderError,
            .coachResponseInvalid,
        ]
        try await withTemporaryParent { parent in
            for (index, priorFailure) in priorFailures.enumerated() {
                let caseParent = parent.appendingPathComponent(
                    "active-retry-\(index)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: caseParent,
                    withIntermediateDirectories: false
                )
                let fixture = try await makeInvocationStoreFixture(
                    in: caseParent,
                    libraryID: "lib-20260830T12001\(index)000Z-2ABC",
                    pendingFailure: priorFailure
                )
                let persistence = PortableChatPersistence()
                let lease = try XCTUnwrap(
                    persistence.acquireInvocationLivenessLease(
                        at: fixture.root,
                        in: fixture.scope,
                        for: fixture.install.authority.request
                    )
                )
                guard case .installed = try persistence.installInvocation(
                    fixture.install,
                    at: fixture.root,
                    holding: lease
                ) else { return XCTFail("Retry Invocation was not installed") }
                lease.release()

                let relaunchedWorkspace = PortableLibraryWorkspace(
                    locations: QueueLocations(existing: [fixture.root]),
                    bookmarks: SyntheticBookmarks(),
                    access: RecordingAccessGrantor(),
                    locatorStore: MemoryLocatorStore(),
                    revealer: RecordingRevealer()
                )
                _ = await relaunchedWorkspace.chooseLibrary()
                let chats = PortableChatStore(workspace: relaunchedWorkspace)
                guard case let .loaded(reopened) = await chats.load(
                    fixture.locked.chat.id,
                    in: fixture.scope
                ) else { return XCTFail("active Retry was not reconciled") }
                XCTAssertEqual(
                    reopened.pendingUserTurn?.failure,
                    .coachResponseInterrupted,
                    "prior failure: \(priorFailure)"
                )
                XCTAssertEqual(reopened.chat.messageIDs, [])
            }
        }
    }

    func testActiveSessionPersistsNextAttemptBeforeReturningFreshAuthority() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let store = PortableInvocationStore(workspace: fixture.workspace)
            guard case let .opened(pendingSession) = await store.openPendingInvocation(
                fixture.install.authority.request
            ) else { return XCTFail("Pending session was not opened") }
            guard case let .installed(firstSession) = await pendingSession.install(
                fixture.install
            ) else { return XCTFail("first Attempt was not installed") }

            let nextIdentity = InvocationAttemptIdentity(
                attemptID: try CoachProviderAttemptID(
                    "atm-20260830T120004000Z-0ABC"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "synthetic-attempt-0ABC"
                ),
                userMessageID: try ChatMessageID(
                    "msg-20260830T120004000Z-1BCD"
                ),
                coachMessageID: try ChatMessageID(
                    "msg-20260830T120004000Z-2CDE"
                ),
                freshDraftID: try ChatDraftID(
                    "drf-20260830T120004000Z-3DEF"
                )
            )
            let mutation = try InstallNextCoachProviderAttemptMutation(
                base: firstSession.invocation,
                identity: nextIdentity,
                kind: .standard
            )
            guard case let .installed(nextSession) = await firstSession
                .installNextAttempt(mutation)
            else { return XCTFail("next Attempt CAS was not installed") }

            XCTAssertEqual(nextSession.invocation, mutation.replacement)
            let invocationURL = fixture.root
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(
                    mutation.base.id.rawValue,
                    isDirectory: true
                )
                .appendingPathComponent("invocation.json")
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: invocationURL)
                ) as? [String: Any]
            )
            XCTAssertEqual(object["schemaVersion"] as? Int, 3)
            XCTAssertEqual((object["attempts"] as? [[String: Any]])?.count, 2)

            guard case let .committed(aggregate) = await nextSession.abort(
                failure: .coachProviderError
            ) else { return XCTFail("typed terminal failure was not committed") }
            XCTAssertEqual(
                aggregate.pendingUserTurn?.failure,
                .coachProviderError
            )
            XCTAssertEqual(aggregate.chat.messageIDs, [])
        }
    }

    func testNextAttemptFaultsReturnProviderAuthorityOnlyAfterDurableReconciliation()
        async throws
    {
        let cases: [(PortableChatFaultPoint, Bool)] = [
            (.beforeNextAttemptPartialWrite, false),
            (.afterNextAttemptPartialWrite, false),
            (.afterNextAttemptFileFlush, false),
            (.afterNextAttemptInstall, true),
            (.afterNextAttemptDirectoryFlush, true),
        ]
        try await withTemporaryParent { parent in
            for (index, testCase) in cases.enumerated() {
                let (point, committed) = testCase
                let caseParent = parent.appendingPathComponent(
                    "next-fault-\(index)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: caseParent,
                    withIntermediateDirectories: false
                )
                let fixture = try await makeInvocationStoreFixture(
                    in: caseParent,
                    libraryID: "lib-20260830T12004\(index)000Z-2ABC"
                )
                let injected = OneShot()
                let persistence = PortableChatPersistence { reached in
                    if reached == point, injected.take() {
                        throw PortableChatPersistenceError.injectedFault(reached)
                    }
                }
                let lease = try XCTUnwrap(
                    persistence.acquireInvocationLivenessLease(
                        at: fixture.root,
                        in: fixture.scope,
                        for: fixture.install.authority.request
                    )
                )
                guard case .installed = try persistence.installInvocation(
                    fixture.install,
                    at: fixture.root,
                    holding: lease
                ) else { return XCTFail("Attempt 1 was not installed") }
                let mutation = try InstallNextCoachProviderAttemptMutation(
                    base: fixture.install.invocation,
                    identity: InvocationAttemptIdentity(
                        attemptID: try CoachProviderAttemptID(
                            "atm-20260830T12004\(index)000Z-0ABC"
                        ),
                        idempotencyValue: try ProviderIdempotencyValue(
                            "fault-next-\(index)"
                        ),
                        userMessageID: try ChatMessageID(
                            "msg-20260830T12004\(index)000Z-1BCD"
                        ),
                        coachMessageID: try ChatMessageID(
                            "msg-20260830T12004\(index)000Z-2CDE"
                        ),
                        freshDraftID: try ChatDraftID(
                            "drf-20260830T12004\(index)000Z-3DEF"
                        )
                    ),
                    kind: .standard
                )

                XCTAssertThrowsError(
                    try persistence.installNextAttempt(
                        mutation,
                        at: fixture.root,
                        in: fixture.scope,
                        holding: lease
                    ),
                    String(describing: point)
                )
                let reconciled = try persistence.reconcileInstalledNextAttempt(
                    mutation,
                    at: fixture.root,
                    in: fixture.scope,
                    holding: lease
                )
                XCTAssertEqual(
                    reconciled?.hasSameDurableProjection(as: mutation.replacement),
                    committed ? true : nil,
                    String(describing: point)
                )

                let invocationURL = fixture.root
                    .appendingPathComponent("invocations", isDirectory: true)
                    .appendingPathComponent(
                        mutation.base.id.rawValue,
                        isDirectory: true
                    )
                    .appendingPathComponent("invocation.json")
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: Data(contentsOf: invocationURL)
                    ) as? [String: Any]
                )
                XCTAssertEqual(
                    (object["attempts"] as? [[String: Any]])?.count,
                    committed ? 2 : 1,
                    String(describing: point)
                )

                lease.release()
                let relaunchedWorkspace = PortableLibraryWorkspace(
                    locations: QueueLocations(existing: [fixture.root]),
                    bookmarks: SyntheticBookmarks(),
                    access: RecordingAccessGrantor(),
                    locatorStore: MemoryLocatorStore(),
                    revealer: RecordingRevealer()
                )
                _ = await relaunchedWorkspace.chooseLibrary()
                let chats = PortableChatStore(workspace: relaunchedWorkspace)
                guard case let .loaded(reopened) = await chats.load(
                    fixture.locked.chat.id,
                    in: fixture.scope
                ) else { return XCTFail("latest Attempt was not retired") }
                XCTAssertEqual(
                    reopened.pendingUserTurn?.failure,
                    .coachResponseInterrupted,
                    String(describing: point)
                )
            }
        }
    }

    func testNextAttemptIsolatesCorruptSiblingChatsAndHealthyChatPublishes() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let persistence = PortableChatPersistence()
            let missingMessages = try persistence.create(
                NewDevelopmentChatSeed(
                    library: fixture.scope,
                    chatID: ChatID("cht-20260830T120020000Z-3DEF"),
                    draftID: ChatDraftID("drf-20260830T120020000Z-4GHJ"),
                    memoryID: CoachMemoryID("mem-20260830T120020000Z-5KMN"),
                    instant: UTCInstant("2026-08-30T12:00:20.000Z"),
                    profileStatementGeneration: 0
                ),
                at: fixture.root
            )
            let missingManifest = try persistence.create(
                NewDevelopmentChatSeed(
                    library: fixture.scope,
                    chatID: ChatID("cht-20260830T120021000Z-6PQR"),
                    draftID: ChatDraftID("drf-20260830T120021000Z-7STV"),
                    memoryID: CoachMemoryID("mem-20260830T120021000Z-8WXY"),
                    instant: UTCInstant("2026-08-30T12:00:21.000Z"),
                    profileStatementGeneration: 0
                ),
                at: fixture.root
            )
            let chatsRoot = fixture.root.appendingPathComponent("chats", isDirectory: true)
            try FileManager.default.removeItem(
                at: chatsRoot
                    .appendingPathComponent(
                        missingMessages.chat.id.rawValue,
                        isDirectory: true
                    )
                    .appendingPathComponent("messages", isDirectory: true)
            )
            try FileManager.default.removeItem(
                at: chatsRoot
                    .appendingPathComponent(
                        missingManifest.chat.id.rawValue,
                        isDirectory: true
                    )
                    .appendingPathComponent("chat.json")
            )

            let store = PortableInvocationStore(
                persistence: persistence,
                workspace: fixture.workspace
            )
            guard case let .opened(pendingSession) = await store.openPendingInvocation(
                fixture.install.authority.request
            ), case let .installed(firstSession) = await pendingSession.install(
                fixture.install
            ) else { return XCTFail("first Attempt was not installed") }
            let nextIdentity = InvocationAttemptIdentity(
                attemptID: try CoachProviderAttemptID("atm-20260830T120022000Z-9YZ0"),
                idempotencyValue: try ProviderIdempotencyValue("synthetic-attempt-9YZ0"),
                userMessageID: try ChatMessageID("msg-20260830T120022000Z-0ABC"),
                coachMessageID: try ChatMessageID("msg-20260830T120022000Z-1BCD"),
                freshDraftID: try ChatDraftID("drf-20260830T120022000Z-2CDE")
            )
            let nextMutation = try InstallNextCoachProviderAttemptMutation(
                base: firstSession.invocation,
                identity: nextIdentity,
                kind: .standard
            )
            guard case let .installed(nextSession) = await firstSession
                .installNextAttempt(nextMutation)
            else { return XCTFail("corrupt sibling blocked the next Attempt") }
            let publication = try PublishCoachInvocationMutation(
                base: fixture.locked,
                invocation: nextSession.invocation,
                coachMarkdown: "Healthy Chat response.",
                completedAt: UTCInstant("2026-08-30T12:00:23.000Z")
            )
            guard case let .committed(published) = await nextSession.publish(publication)
            else { return XCTFail("healthy Chat did not publish") }
            XCTAssertEqual(published, publication.replacement)
            XCTAssertEqual(
                try persistence.load(
                    missingMessages.chat.id,
                    at: fixture.root,
                    in: fixture.scope
                ),
                .frozen(FrozenChatSnapshot(
                    chatID: missingMessages.chat.id,
                    reason: .corrupt
                ))
            )
            XCTAssertEqual(
                try persistence.load(
                    missingManifest.chat.id,
                    at: fixture.root,
                    in: fixture.scope
                ),
                .frozen(FrozenChatSnapshot(
                    chatID: missingManifest.chat.id,
                    reason: .corrupt
                ))
            )
        }
    }

    func testNextAttemptDecodesEscapedFrozenChatPublicIDsWithDocumentWhitespace()
        async throws
    {
        let cases: [(String, Bool, InvocationLaunchIdentityCollision)] = [
            ("newer-message", true, .userMessageID),
            ("newer-draft", true, .freshDraftID),
            ("corrupt-message", false, .userMessageID),
            ("corrupt-draft", false, .freshDraftID),
        ]
        for (index, testCase) in cases.enumerated() {
            try await withTemporaryParent { parent in
                let (label, newerSchema, expected) = testCase
                let fixture = try await makeInvocationStoreFixture(
                    in: parent,
                    libraryID: "lib-20260902T10010\(index)000Z-2ABC",
                    includeCompetingPending: true
                )
                let store = PortableInvocationStore(workspace: fixture.workspace)
                guard case let .opened(pendingSession) = await store
                    .openPendingInvocation(fixture.install.authority.request),
                    case let .installed(firstSession) = await pendingSession.install(
                        fixture.install
                    )
                else { return XCTFail("first Attempt was not installed: \(label)") }
                let candidate = InvocationAttemptIdentity(
                    attemptID: try CoachProviderAttemptID(
                        "atm-20260902T10010\(index)000Z-0ABC"
                    ),
                    idempotencyValue: try ProviderIdempotencyValue(
                        "escaped-chat-next-\(index)"
                    ),
                    userMessageID: try ChatMessageID(
                        "msg-20260902T10010\(index)000Z-1BCD"
                    ),
                    coachMessageID: try ChatMessageID(
                        "msg-20260902T10010\(index)000Z-2CDE"
                    ),
                    freshDraftID: try ChatDraftID(
                        "drf-20260902T10010\(index)000Z-3DEF"
                    )
                )
                try writeEscapedFrozenSiblingChatRoot(
                    in: fixture,
                    newerSchema: newerSchema,
                    messageID: expected == .userMessageID
                        ? candidate.userMessageID
                        : nil,
                    draftID: expected == .freshDraftID
                        ? candidate.freshDraftID
                        : nil
                )
                let mutation = try InstallNextCoachProviderAttemptMutation(
                    base: firstSession.invocation,
                    identity: candidate,
                    kind: .standard
                )
                let outcome = await firstSession.installNextAttempt(mutation)
                guard case let .collision(actual) = outcome else {
                    return XCTFail("escaped Chat collision was missed: \(label)")
                }
                XCTAssertEqual(actual, expected, label)
                guard case .committed = await firstSession.abort(
                    failure: .coachProviderError
                ) else { return XCTFail("first Attempt did not retire: \(label)") }
            }
        }
    }

    func testNextAttemptDoesNotReserveOpaqueFrozenChatStrings() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let store = PortableInvocationStore(workspace: fixture.workspace)
            guard case let .opened(pendingSession) = await store
                .openPendingInvocation(fixture.install.authority.request),
                case let .installed(firstSession) = await pendingSession.install(
                    fixture.install
                )
            else { return XCTFail("first Attempt was not installed") }
            let candidate = InvocationAttemptIdentity(
                attemptID: try CoachProviderAttemptID(
                    "atm-20260902T100500000Z-0ABC"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "opaque-chat-next"
                ),
                userMessageID: try ChatMessageID(
                    "msg-20260902T100500000Z-1BCD"
                ),
                coachMessageID: try ChatMessageID(
                    "msg-20260902T100500000Z-2CDE"
                ),
                freshDraftID: try ChatDraftID(
                    "drf-20260902T100500000Z-3DEF"
                )
            )
            try writeOpaqueFrozenSiblingChatRoot(in: fixture, identity: candidate)
            let mutation = try InstallNextCoachProviderAttemptMutation(
                base: firstSession.invocation,
                identity: candidate,
                kind: .standard
            )

            guard case let .installed(installed) = await firstSession
                .installNextAttempt(mutation)
            else { return XCTFail("opaque strings reserved a public identity") }
            guard case .committed = await installed.abort(
                failure: .coachProviderError
            ) else { return XCTFail("next Attempt did not retire") }
        }
    }

    func testNextAttemptFailsClosedForAmbiguousSiblingChatPublicIDs() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let store = PortableInvocationStore(workspace: fixture.workspace)
            guard case let .opened(pendingSession) = await store
                .openPendingInvocation(fixture.install.authority.request),
                case let .installed(firstSession) = await pendingSession.install(
                    fixture.install
                )
            else { return XCTFail("first Attempt was not installed") }
            let candidate = InvocationAttemptIdentity(
                attemptID: try CoachProviderAttemptID(
                    "atm-20260902T100600000Z-0ABC"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "ambiguous-chat-next"
                ),
                userMessageID: try ChatMessageID(
                    "msg-20260902T100600000Z-1BCD"
                ),
                coachMessageID: try ChatMessageID(
                    "msg-20260902T100600000Z-2CDE"
                ),
                freshDraftID: try ChatDraftID(
                    "drf-20260902T100600000Z-3DEF"
                )
            )
            try writeAmbiguousSiblingChatRoot(
                in: fixture,
                messageID: candidate.userMessageID
            )
            let mutation = try InstallNextCoachProviderAttemptMutation(
                base: firstSession.invocation,
                identity: candidate,
                kind: .standard
            )

            guard case .failed = await firstSession.installNextAttempt(mutation)
            else { return XCTFail("ambiguous public identity did not fail closed") }
        }
    }

    func testIdentityCollisionScansPreserveCallerSpecificFailurePrecedence() async throws {
        try await withTemporaryParent { parent in
            let nextParent = parent.appendingPathComponent("next", isDirectory: true)
            try FileManager.default.createDirectory(
                at: nextParent,
                withIntermediateDirectories: false
            )
            let nextFixture = try await makeInvocationStoreFixture(
                in: nextParent,
                libraryID: "lib-20260902T180000000Z-2ABC",
                includeCompetingPending: true
            )
            let nextStore = PortableInvocationStore(workspace: nextFixture.workspace)
            guard case let .opened(pendingSession) = await nextStore
                .openPendingInvocation(nextFixture.install.authority.request),
                case let .installed(firstSession) = await pendingSession.install(
                    nextFixture.install
                )
            else { return XCTFail("first Attempt was not installed") }
            let nextIdentity = InvocationAttemptIdentity(
                attemptID: try CoachProviderAttemptID(
                    "atm-20260902T180001000Z-3BCD"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "failure-precedence-next"
                ),
                userMessageID: try ChatMessageID(
                    "msg-20260902T180001000Z-4CDE"
                ),
                coachMessageID: try ChatMessageID(
                    "msg-20260902T180001000Z-5DEF"
                ),
                freshDraftID: try ChatDraftID(
                    "drf-20260902T180001000Z-6EFG"
                )
            )
            let nextActiveMessages = nextFixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(
                    nextFixture.install.invocation.chatID.rawValue,
                    isDirectory: true
                )
                .appendingPathComponent("messages", isDirectory: true)
            try Data("{}".utf8).write(
                to: nextActiveMessages.appendingPathComponent(
                    "\(nextIdentity.userMessageID.rawValue).json"
                )
            )
            let nextUnreadableMessages = nextFixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(
                    nextFixture.competingAuthority.request.chatID.rawValue,
                    isDirectory: true
                )
                .appendingPathComponent("messages", isDirectory: true)
            XCTAssertEqual(
                nextUnreadableMessages.path.withCString { Darwin.chmod($0, 0) },
                0
            )
            defer {
                _ = nextUnreadableMessages.path.withCString {
                    Darwin.chmod($0, 0o700)
                }
            }

            let nextMutation = try InstallNextCoachProviderAttemptMutation(
                base: firstSession.invocation,
                identity: nextIdentity,
                kind: .standard
            )
            guard case let .collision(nextCollision) = await firstSession
                .installNextAttempt(nextMutation)
            else {
                return XCTFail("next Attempt must return its early collision")
            }
            XCTAssertEqual(nextCollision, .userMessageID)
            XCTAssertEqual(
                nextUnreadableMessages.path.withCString { Darwin.chmod($0, 0o700) },
                0
            )
            guard case .committed = await firstSession.abort(
                failure: .coachProviderError
            ) else { return XCTFail("first Attempt did not retire") }

            let launchParent = parent.appendingPathComponent("launch", isDirectory: true)
            try FileManager.default.createDirectory(
                at: launchParent,
                withIntermediateDirectories: false
            )
            let launchFixture = try await makeInvocationStoreFixture(
                in: launchParent,
                libraryID: "lib-20260902T180100000Z-7FGH",
                includeCompetingPending: true
            )
            let launchStore = PortableInvocationStore(
                workspace: launchFixture.workspace
            )
            let launchReservation = await launchStore.reserveInvocation(
                launchFixture.install.authority.request
            )
            XCTAssertEqual(
                launchReservation,
                .acquired
            )
            let launchInvocation = launchFixture.install.invocation
            let launchCandidate = InvocationLaunchIdentity(
                invocationID: launchInvocation.id,
                attemptID: launchInvocation.attemptID,
                idempotencyValue: try XCTUnwrap(
                    launchInvocation.providerIdempotencyValue
                ),
                userMessageID: nextIdentity.userMessageID,
                coachMessageID: nextIdentity.coachMessageID,
                freshDraftID: nextIdentity.freshDraftID
            )
            let launchActiveMessages = launchFixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(
                    launchFixture.install.invocation.chatID.rawValue,
                    isDirectory: true
                )
                .appendingPathComponent("messages", isDirectory: true)
            try Data("{}".utf8).write(
                to: launchActiveMessages.appendingPathComponent(
                    "\(launchCandidate.userMessageID.rawValue).json"
                )
            )
            let launchUnreadableMessages = launchFixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(
                    launchFixture.competingAuthority.request.chatID.rawValue,
                    isDirectory: true
                )
                .appendingPathComponent("messages", isDirectory: true)
            XCTAssertEqual(
                launchUnreadableMessages.path.withCString { Darwin.chmod($0, 0) },
                0
            )
            defer {
                _ = launchUnreadableMessages.path.withCString {
                    Darwin.chmod($0, 0o700)
                }
            }

            let launchAvailability = await launchStore.checkLaunchIdentity(
                launchCandidate,
                for: launchFixture.install.authority
            )
            XCTAssertEqual(
                launchAvailability,
                .unavailable,
                "launch preflight must keep scanning after an early collision"
            )
            await launchStore.cancelInvocationReservation(
                launchFixture.install.authority.request
            )
        }
    }

    func testNextAttemptChecksSupportedInvocationRootDraftID() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let store = PortableInvocationStore(workspace: fixture.workspace)
            guard case let .opened(pendingSession) = await store
                .openPendingInvocation(fixture.install.authority.request),
                case let .installed(firstSession) = await pendingSession.install(
                    fixture.install
                )
            else { return XCTFail("first Attempt was not installed") }
            let candidate = InvocationAttemptIdentity(
                attemptID: try CoachProviderAttemptID(
                    "atm-20260902T100200000Z-0ABC"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "supported-root-next"
                ),
                userMessageID: try ChatMessageID(
                    "msg-20260902T100200000Z-1BCD"
                ),
                coachMessageID: try ChatMessageID(
                    "msg-20260902T100200000Z-2CDE"
                ),
                freshDraftID: try ChatDraftID(
                    "drf-20260902T100200000Z-3DEF"
                )
            )
            try writeSupportedInvocation(
                in: fixture,
                rootDraftID: candidate.freshDraftID
            )
            let mutation = try InstallNextCoachProviderAttemptMutation(
                base: firstSession.invocation,
                identity: candidate,
                kind: .standard
            )

            let outcome = await firstSession.installNextAttempt(mutation)
            guard case let .collision(collision) = outcome else {
                return XCTFail("supported Invocation root Draft collision was missed")
            }
            XCTAssertEqual(collision, .freshDraftID)
            guard case .committed = await firstSession.abort(
                failure: .coachProviderError
            ) else { return XCTFail("first Attempt did not retire") }
        }
    }

    func testNextAttemptScansFrozenFutureInvocationAndRegeneratesAfterCollision()
        async throws
    {
        let cases: [InvocationLaunchIdentityCollision?] = [
            nil,
            .attemptID,
            .userMessageID,
            .coachMessageID,
            .freshDraftID,
        ]
        try await withTemporaryParent { parent in
            for (index, expected) in cases.enumerated() {
                let caseParent = parent.appendingPathComponent(
                    "future-next-\(index)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: caseParent,
                    withIntermediateDirectories: false
                )
                let fixture = try await makeInvocationStoreFixture(
                    in: caseParent,
                    libraryID: "lib-20260830T12120\(index)000Z-2ABC",
                    includeCompetingPending: true
                )
                let candidate = InvocationAttemptIdentity(
                    attemptID: try CoachProviderAttemptID(
                        "atm-20260830T12120\(index)000Z-0ABC"
                    ),
                    idempotencyValue: try ProviderIdempotencyValue(
                        "future-next-candidate-\(index)"
                    ),
                    userMessageID: try ChatMessageID(
                        "msg-20260830T12120\(index)000Z-1BCD"
                    ),
                    coachMessageID: try ChatMessageID(
                        "msg-20260830T12120\(index)000Z-2CDE"
                    ),
                    freshDraftID: try ChatDraftID(
                        "drf-20260830T12120\(index)000Z-3DEF"
                    )
                )
                try writeFutureInvocation(
                    in: fixture,
                    chatID: fixture.competingAuthority.request.chatID,
                    attemptID: expected == .attemptID
                        ? candidate.attemptID.rawValue
                        : "atm-20260830T121209000Z-4GHJ",
                    userMessageID: expected == .userMessageID
                        ? candidate.userMessageID.rawValue
                        : "msg-20260830T121209000Z-5KMN",
                    coachMessageID: expected == .coachMessageID
                        ? candidate.coachMessageID.rawValue
                        : "msg-20260830T121209000Z-6PQR",
                    freshDraftID: expected == .freshDraftID
                        ? candidate.freshDraftID.rawValue
                        : "drf-20260830T121209000Z-7STV"
                )

                let store = PortableInvocationStore(workspace: fixture.workspace)
                guard case let .opened(pendingSession) = await store
                    .openPendingInvocation(fixture.install.authority.request),
                    case let .installed(firstSession) = await pendingSession.install(
                        fixture.install
                    )
                else { return XCTFail("first Attempt was blocked: \(index)") }
                let mutation = try InstallNextCoachProviderAttemptMutation(
                    base: firstSession.invocation,
                    identity: candidate,
                    kind: .standard
                )
                let firstOutcome = await firstSession.installNextAttempt(mutation)
                let installedSession: any InvocationActivePersistenceSession
                if let expected {
                    guard case let .collision(actual) = firstOutcome else {
                        return XCTFail("future collision was missed: \(expected)")
                    }
                    XCTAssertEqual(actual, expected)
                    let replacement = try InstallNextCoachProviderAttemptMutation(
                        base: firstSession.invocation,
                        identity: InvocationAttemptIdentity(
                            attemptID: try CoachProviderAttemptID(
                                "atm-20260830T12120\(index)000Z-8WXY"
                            ),
                            idempotencyValue: try ProviderIdempotencyValue(
                                "future-next-replacement-\(index)"
                            ),
                            userMessageID: try ChatMessageID(
                                "msg-20260830T12120\(index)000Z-9YZ0"
                            ),
                            coachMessageID: try ChatMessageID(
                                "msg-20260830T12120\(index)000Z-0BCD"
                            ),
                            freshDraftID: try ChatDraftID(
                                "drf-20260830T12120\(index)000Z-1CDE"
                            )
                        ),
                        kind: .standard
                    )
                    guard case let .installed(session) = await firstSession
                        .installNextAttempt(replacement)
                    else { return XCTFail("regenerated Attempt failed: \(expected)") }
                    installedSession = session
                } else {
                    guard case let .installed(session) = firstOutcome else {
                        return XCTFail("noncolliding future Invocation blocked next Attempt")
                    }
                    installedSession = session
                }
                guard case .committed = await installedSession.abort(
                    failure: .coachProviderError
                ) else { return XCTFail("installed next Attempt did not retire") }
            }
        }
    }

    func testNextAttemptScansEscapedFutureInvocationRootDraftIDWithDocumentWhitespaceAndRegenerates()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let candidate = InvocationAttemptIdentity(
                attemptID: try CoachProviderAttemptID(
                    "atm-20260830T121719000Z-0ABC"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "root-draft-next-candidate"
                ),
                userMessageID: try ChatMessageID(
                    "msg-20260830T121719000Z-1BCD"
                ),
                coachMessageID: try ChatMessageID(
                    "msg-20260830T121719000Z-2CDE"
                ),
                freshDraftID: try ChatDraftID(
                    "drf-20260830T121719000Z-3DEF"
                )
            )
            let competingDraft = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(
                    fixture.competingAuthority.request.chatID.rawValue,
                    isDirectory: true
                )
                .appendingPathComponent("draft.json")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: competingDraft.path)
            )

            let futureInvocationID = try writeFutureInvocation(
                in: fixture,
                chatID: fixture.competingAuthority.request.chatID,
                attemptID: "atm-20260830T121719000Z-4GHJ",
                userMessageID: "msg-20260830T121719000Z-5KMN",
                coachMessageID: "msg-20260830T121719000Z-6PQR",
                freshDraftID: "drf-20260830T121719000Z-7STV",
                draftID: candidate.freshDraftID.rawValue
            )
            let futureURL = fixture.root
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(futureInvocationID.rawValue, isDirectory: true)
                .appendingPathComponent("invocation.json")
            let canonicalText = try XCTUnwrap(
                String(data: Data(contentsOf: futureURL), encoding: .utf8)
            )
            let property = "\"draftId\":\"" + candidate.freshDraftID.rawValue + "\""
            let escapedID = "\\u0064" + candidate.freshDraftID.rawValue.dropFirst()
            let escapedText = canonicalText.replacingOccurrences(
                of: property,
                with: "\"draftId\":\"" + escapedID + "\""
            )
            XCTAssertNotEqual(escapedText, canonicalText)
            XCTAssertFalse(escapedText.contains(candidate.freshDraftID.rawValue))
            try Data(("\n\t " + escapedText + " \r\n").utf8).write(to: futureURL)

            let store = PortableInvocationStore(workspace: fixture.workspace)
            guard case let .opened(pendingSession) = await store
                .openPendingInvocation(fixture.install.authority.request),
                case let .installed(firstSession) = await pendingSession.install(
                    fixture.install
                )
            else { return XCTFail("first Attempt was blocked") }
            let mutation = try InstallNextCoachProviderAttemptMutation(
                base: firstSession.invocation,
                identity: candidate,
                kind: .standard
            )
            let firstOutcome = await firstSession.installNextAttempt(mutation)
            guard case let .collision(collision) = firstOutcome else {
                return XCTFail("future root Draft collision was missed")
            }
            XCTAssertEqual(collision, .freshDraftID)

            let replacement = try InstallNextCoachProviderAttemptMutation(
                base: firstSession.invocation,
                identity: InvocationAttemptIdentity(
                    attemptID: try CoachProviderAttemptID(
                        "atm-20260830T121719000Z-8WXY"
                    ),
                    idempotencyValue: try ProviderIdempotencyValue(
                        "root-draft-next-replacement"
                    ),
                    userMessageID: try ChatMessageID(
                        "msg-20260830T121719000Z-9YZ0"
                    ),
                    coachMessageID: try ChatMessageID(
                        "msg-20260830T121719000Z-0BCD"
                    ),
                    freshDraftID: try ChatDraftID(
                        "drf-20260830T121719000Z-1CDE"
                    )
                ),
                kind: .standard
            )
            guard case let .installed(installed) = await firstSession
                .installNextAttempt(replacement)
            else { return XCTFail("regenerated Attempt failed") }
            guard case .committed = await installed.abort(
                failure: .coachProviderError
            ) else { return XCTFail("regenerated Attempt did not retire") }
        }
    }

    func testRelaunchRetiresLatestDurableAttemptWithoutResumingWork() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let persistence = PortableChatPersistence()
            let lease = try XCTUnwrap(
                persistence.acquireInvocationLivenessLease(
                    at: fixture.root,
                    in: fixture.scope,
                    for: fixture.install.authority.request
                )
            )
            guard case .installed = try persistence.installInvocation(
                fixture.install,
                at: fixture.root,
                holding: lease
            ) else { return XCTFail("first Attempt was not installed") }
            let next = try InstallNextCoachProviderAttemptMutation(
                base: fixture.install.invocation,
                identity: InvocationAttemptIdentity(
                    attemptID: CoachProviderAttemptID(
                        "atm-20260830T120004000Z-0ABC"
                    ),
                    idempotencyValue: ProviderIdempotencyValue(
                        "synthetic-attempt-0ABC"
                    ),
                    userMessageID: ChatMessageID(
                        "msg-20260830T120004000Z-1BCD"
                    ),
                    coachMessageID: ChatMessageID(
                        "msg-20260830T120004000Z-2CDE"
                    ),
                    freshDraftID: ChatDraftID(
                        "drf-20260830T120004000Z-3DEF"
                    )
                ),
                kind: .standard
            )
            XCTAssertEqual(
                try persistence.installNextAttempt(
                    next,
                    at: fixture.root,
                    in: fixture.scope,
                    holding: lease
                ),
                .installed(next.replacement)
            )
            lease.release() // Simulates kernel liveness loss at process death.

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let chats = PortableChatStore(workspace: relaunchedWorkspace)
            guard case let .loaded(reopened) = await chats.load(
                fixture.locked.chat.id,
                in: fixture.scope
            ) else { return XCTFail("relaunch did not reconcile the Invocation") }

            XCTAssertEqual(
                reopened.pendingUserTurn?.failure,
                .coachResponseInterrupted
            )
            XCTAssertEqual(reopened.chat.messageIDs, [])
            XCTAssertEqual(reopened.chat.draft, fixture.locked.chat.draft)
            XCTAssertFalse(
                try persistence.hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
        }
    }

    func testRelaunchRollsBackEveryPrecommitPublicationCrashToRetryablePending() async throws {
        let cases: [(PortableChatFaultPoint, String)] = [
            (.afterPublicationProofInstall, "lib-20260830T120000000Z-2ABC"),
            (.afterPublicationProofDirectoryFlush, "lib-20260830T120000000Z-3DEF"),
            (.afterUserMessageInstall, "lib-20260830T120000000Z-4GHJ"),
            (.afterCoachMessageInstall, "lib-20260830T120000000Z-5KMN"),
            (.afterPublicationManifestFileFlush, "lib-20260830T120000000Z-6PQR"),
        ]

        try await withTemporaryParent { parent in
            for (index, faultCase) in cases.enumerated() {
                let (point, libraryID) = faultCase
                let caseParent = parent.appendingPathComponent(
                    "precommit-case-\(index)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: caseParent,
                    withIntermediateDirectories: false
                )
                let fixture = try await makeInvocationStoreFixture(
                    in: caseParent,
                    libraryID: libraryID
                )
                let crash = await leavePrecommitPublicationForRelaunch(
                    fixture,
                    at: point
                )
                XCTAssertEqual(crash.outcome, .failed, String(describing: point))
                XCTAssertTrue(
                    crash.publicationFaultReached,
                    "publication fault was not reached: \(point)"
                )
                XCTAssertTrue(
                    crash.reconciliationFaultReached,
                    "immediate reconciliation was not blocked: \(point)"
                )
                XCTAssertTrue(crash.livenessReleased, String(describing: point))
                try assertPrecommitPublicationCrashArtifacts(
                    fixture,
                    at: point
                )

                let relaunchedWorkspace = PortableLibraryWorkspace(
                    locations: QueueLocations(existing: [fixture.root]),
                    bookmarks: SyntheticBookmarks(),
                    access: RecordingAccessGrantor(),
                    locatorStore: MemoryLocatorStore(),
                    revealer: RecordingRevealer()
                )
                _ = await relaunchedWorkspace.chooseLibrary()
                let chats = PortableChatStore(workspace: relaunchedWorkspace)
                guard case let .loaded(reopened) = await chats.load(
                    fixture.locked.chat.id,
                    in: fixture.scope
                ) else {
                    XCTFail("precommit crash froze the Chat at \(point)")
                    continue
                }

                try await assertRetryablePrecommitRecovery(
                    reopened,
                    fixture: fixture,
                    workspace: relaunchedWorkspace,
                    label: String(describing: point)
                )
            }
        }
    }

    func testRelaunchRollsBackPrecommitPublicationCASConflictAfterOwnerDeath() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let rename = try RenameChatMutation(
                library: fixture.scope,
                base: fixture.locked,
                title: ChatTitle("Renamed while publishing"),
                updatedAt: UTCInstant("2026-08-30T12:00:02.500Z")
            )
            let crash = await leavePrecommitCASConflictForRelaunch(
                fixture,
                rename: rename
            )
            XCTAssertEqual(crash.outcome, .stale(fixture.locked))
            XCTAssertTrue(crash.conflictReached)
            XCTAssertTrue(crash.livenessReleased)
            try assertPrecommitPublicationCrashArtifacts(
                fixture,
                at: .afterPublicationManifestFileFlush
            )

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let chats = PortableChatStore(workspace: relaunchedWorkspace)
            guard case let .loaded(reopened) = await chats.load(
                fixture.locked.chat.id,
                in: fixture.scope
            ) else {
                return XCTFail("precommit CAS conflict froze the Chat")
            }
            XCTAssertEqual(reopened.chat.title, rename.replacement.chat.title)
            XCTAssertEqual(
                reopened.chat.manifestRevision,
                rename.replacement.chat.manifestRevision
            )

            try await assertRetryablePrecommitRecovery(
                reopened,
                fixture: fixture,
                workspace: relaunchedWorkspace,
                label: "precommit CAS conflict"
            )
        }
    }

    func testPreparedNewPendingIsNeverRecoverableBetweenExactBindingAndHandoff() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let baseline = PortableChatPersistence()
            guard case let .committed(unlocked) = try baseline.discardPendingUserTurn(
                DiscardPendingUserTurnMutation(
                    library: fixture.scope,
                    chatID: fixture.locked.chat.id,
                    pendingUserTurn: fixture.install.authority.pendingUserTurn
                ),
                at: fixture.root
            ) else { return XCTFail("Pending setup did not unlock") }
            guard case .committed = try baseline.discardPendingUserTurn(
                DiscardPendingUserTurnMutation(
                    library: fixture.scope,
                    chatID: fixture.competingAuthority.request.chatID,
                    pendingUserTurn: fixture.competingAuthority.pendingUserTurn
                ),
                at: fixture.root
            ) else { return XCTFail("sibling Pending setup did not unlock") }
            let request = try NewPendingCoachInvocationRequest(
                library: fixture.scope,
                observedAggregate: unlocked,
                pendingUserTurn: fixture.install.authority.pendingUserTurn
            )
            let suspension = SuspendedInvocationAcquisition()
            let owner = PortableInvocationStore(
                persistence: PortableChatPersistence { point in
                    guard point == .afterPendingInvocationAuthorityBound else { return }
                    suspension.suspend()
                },
                workspace: fixture.workspace
            )
            let recoveryWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await recoveryWorkspace.chooseLibrary()
            let recoveringChats = PortableChatStore(workspace: recoveryWorkspace)

            async let preparation = owner.prepareNewPendingInvocation(request)
            await suspension.waitUntilSuspended()

            guard case let .loaded(entries) = await recoveringChats.loadCatalog(
                in: fixture.scope
            ) else {
                suspension.resume()
                return XCTFail("catalog recovery did not load")
            }
            let live = entries.compactMap { entry -> ChatAggregate? in
                guard case let .available(aggregate) = entry,
                      aggregate.chat.id == request.chatID
                else { return nil }
                return aggregate
            }.first
            XCTAssertEqual(live?.pendingUserTurn, request.pendingUserTurn)
            XCTAssertNil(live?.pendingUserTurn?.failure)

            suspension.resume()
            guard case let .prepared(authority) = await preparation else {
                return XCTFail("new Send did not retain its bound authority")
            }
            XCTAssertEqual(authority.aggregate.pendingUserTurn, request.pendingUserTurn)
            XCTAssertNil(authority.pendingUserTurn.failure)
            await owner.cancelInvocationReservation(authority.request)
        }
    }

    func testRecoveryOwnerPreventsPendingInstallAndLeavesDraftUnchanged() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let baseline = PortableChatPersistence()
            guard case let .committed(unlocked) = try baseline.discardPendingUserTurn(
                DiscardPendingUserTurnMutation(
                    library: fixture.scope,
                    chatID: fixture.locked.chat.id,
                    pendingUserTurn: fixture.install.authority.pendingUserTurn
                ),
                at: fixture.root
            ) else { return XCTFail("Pending setup did not unlock") }
            let request = try NewPendingCoachInvocationRequest(
                library: fixture.scope,
                observedAggregate: unlocked,
                pendingUserTurn: fixture.install.authority.pendingUserTurn
            )
            let suspension = SuspendedInvocationAcquisition()
            let recoveryWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await recoveryWorkspace.chooseLibrary()
            let recoveringChats = PortableChatStore(
                persistence: PortableChatPersistence { point in
                    guard point == .beforeInvocationReconciliation else { return }
                    suspension.suspend()
                },
                workspace: recoveryWorkspace
            )
            let owner = PortableInvocationStore(workspace: fixture.workspace)

            async let catalog = recoveringChats.loadCatalog(in: fixture.scope)
            await suspension.waitUntilSuspended()

            let preparation = await owner.prepareNewPendingInvocation(request)
            XCTAssertEqual(
                preparation,
                .activeExists
            )
            guard case let .readWrite(duringRecovery) = try baseline.load(
                request.chatID,
                at: fixture.root,
                in: fixture.scope
            ) else {
                suspension.resume()
                return XCTFail("Chat did not remain readable")
            }
            XCTAssertEqual(duringRecovery, unlocked)

            suspension.resume()
            guard case .loaded = await catalog else {
                return XCTFail("recovery did not finish")
            }
        }
    }

    func testPreparedNewPendingReconcilesEveryPostcommitLockFaultWhileStillOwned() async throws {
        let points: [PortableChatFaultPoint] = [
            .afterPendingInstall,
            .afterPendingDirectoryFlush,
            .beforePendingFinalRead,
            .afterPendingInvocationAuthorityBound,
        ]
        for point in points {
            try await withTemporaryParent { parent in
                let fixture = try await makeInvocationStoreFixture(
                    in: parent,
                    includeCompetingPending: true
                )
                let baseline = PortableChatPersistence()
                guard case let .committed(unlocked) = try baseline
                    .discardPendingUserTurn(
                        DiscardPendingUserTurnMutation(
                            library: fixture.scope,
                            chatID: fixture.locked.chat.id,
                            pendingUserTurn: fixture.install.authority.pendingUserTurn
                        ),
                        at: fixture.root
                    ),
                    case .committed = try baseline.discardPendingUserTurn(
                        DiscardPendingUserTurnMutation(
                            library: fixture.scope,
                            chatID: fixture.competingAuthority.request.chatID,
                            pendingUserTurn: fixture.competingAuthority.pendingUserTurn
                        ),
                        at: fixture.root
                    )
                else { return XCTFail("Pending setup did not unlock") }
                let request = try NewPendingCoachInvocationRequest(
                    library: fixture.scope,
                    observedAggregate: unlocked,
                    pendingUserTurn: fixture.install.authority.pendingUserTurn
                )
                let store = PortableInvocationStore(
                    persistence: PortableChatPersistence { reached in
                        if reached == point {
                            throw PortableChatPersistenceError.injectedFault(point)
                        }
                    },
                    workspace: fixture.workspace
                )

                guard case let .prepared(authority) = await store
                    .prepareNewPendingInvocation(request)
                else {
                    return XCTFail("exact committed Pending was lost at \(point)")
                }
                XCTAssertEqual(authority.aggregate.pendingUserTurn, request.pendingUserTurn)
                XCTAssertNil(authority.pendingUserTurn.failure)
                await store.cancelInvocationReservation(authority.request)
            }
        }
    }

    func testCatalogLoadCannotReconcilePendingBetweenAtomicResolutionAndOwnership() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let suspension = SuspendedInvocationAcquisition()
            let persistence = PortableChatPersistence { point in
                guard point == .beforeInvocationReconciliation else { return }
                suspension.suspend()
            }
            let invocations = PortableInvocationStore(
                persistence: persistence,
                workspace: fixture.workspace
            )
            let catalogWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await catalogWorkspace.chooseLibrary()
            let chats = PortableChatStore(workspace: catalogWorkspace)

            async let acquisition = invocations.acquirePendingInvocation(
                fixture.install.authority.request
            )
            await suspension.waitUntilSuspended()

            guard case let .loaded(entries) = await chats.loadCatalog(
                in: fixture.scope
            ) else {
                suspension.resume()
                return XCTFail("catalog did not retain the live Chat")
            }
            let duringAcquisition = entries.compactMap { entry -> ChatAggregate? in
                guard case let .available(aggregate) = entry,
                      aggregate.chat.id == fixture.locked.chat.id
                else { return nil }
                return aggregate
            }.first
            guard let duringAcquisition else {
                suspension.resume()
                return XCTFail("catalog did not retain the live Chat")
            }
            XCTAssertNil(duringAcquisition.pendingUserTurn?.failure)

            suspension.resume()
            let acquired = await acquisition
            XCTAssertEqual(
                acquired,
                .acquired(fixture.install.authority)
            )
        }
    }

    func testIneligibleAtomicAcquisitionReleasesLibraryLivenessAuthority() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            try Data("{}".utf8).write(
                to: fixture.root
                    .appendingPathComponent("chats", isDirectory: true)
                    .appendingPathComponent(
                        fixture.locked.chat.id.rawValue,
                        isDirectory: true
                    )
                    .appendingPathComponent("chat.json"),
                options: .atomic
            )
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)

            let ineligible = await owner.acquirePendingInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(ineligible, .ineligible(nil))
            let acquired = await contender.acquirePendingInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(acquired, .acquired(fixture.competingAuthority))
        }
    }

    func testInterruptedTerminalMutationReleasesLibraryLivenessAuthority() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)
            let acquired = await owner.acquirePendingInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(acquired, .acquired(fixture.install.authority))

            guard case .committed = await owner.markInterruptedNewSend(
                fixture.install.authority
            ) else { return XCTFail("interruption did not persist") }

            let next = await contender.acquirePendingInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(next, .acquired(fixture.competingAuthority))
        }
    }

    func testConcurrentInvocationStoresReserveExactlyOneLibraryLivenessAuthorityBeforeInstall() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let first = PortableInvocationStore(workspace: fixture.workspace)
            let second = PortableInvocationStore(workspace: fixture.workspace)

            async let firstCheck = first.reserveInvocation(
                fixture.install.authority.request
            )
            async let secondCheck = second.reserveInvocation(
                fixture.install.authority.request
            )
            let outcomes = await [firstCheck, secondCheck]

            XCTAssertEqual(outcomes.filter { $0 == .acquired }.count, 1, "\(outcomes)")
            XCTAssertEqual(
                outcomes.filter { $0 == .blockedByActiveInvocation }.count,
                1,
                "\(outcomes)"
            )
        }
    }

    func testSecondLiveInvocationStoreCannotReapAnotherStoresActiveInvocation() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let first = PortableInvocationStore(workspace: fixture.workspace)
            let second = PortableInvocationStore(workspace: fixture.workspace)

            let firstCheck = await first.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(firstCheck, .acquired)
            guard case .installed = await first.installInvocation(fixture.install) else {
                return XCTFail("first store did not install its Invocation")
            }

            let secondCheck = await second.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(secondCheck, .blockedByActiveInvocation)
            XCTAssertTrue(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
            guard case let .readWrite(reopened) = try PortableChatPersistence().load(
                fixture.locked.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("live Invocation froze its Chat") }
            XCTAssertEqual(reopened, fixture.locked)
        }
    }

    func testCrossChatReservationReconcilesCrashedInvocationWithItsOwnPendingLease() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            guard case .installed = try PortableChatPersistence().installInvocation(
                fixture.install,
                at: fixture.root
            ) else { return XCTFail("crashed Invocation fixture did not install") }
            let store = PortableInvocationStore(workspace: fixture.workspace)

            let reservation = await store.reserveInvocation(
                fixture.competingAuthority.request
            )

            XCTAssertEqual(reservation, .acquired)
            guard case let .readWrite(reopened) = try PortableChatPersistence().load(
                fixture.locked.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("recovery froze the interrupted Chat") }
            XCTAssertEqual(
                reopened.pendingUserTurn?.failure,
                .coachResponseInterrupted
            )
            XCTAssertFalse(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
            await store.cancelInvocationReservation(
                fixture.competingAuthority.request
            )
        }
    }

    func testIdenticalContenderCannotDiscardPendingWhileWinningProviderIsSuspended() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)

            let winningReservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(winningReservation, .acquired)
            let competingReservation = await contender.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(competingReservation, .blockedByActiveInvocation)
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("winning store did not install its Invocation")
            }

            let competingRejection = await contender.rejectNewSend(
                fixture.install.authority
            )
            XCTAssertEqual(competingRejection, .stale(fixture.locked))

            guard case let .committed(published) = await owner.publish(
                fixture.publication
            ) else { return XCTFail("winning Invocation did not publish") }
            XCTAssertEqual(published, fixture.publication.replacement)
        }
    }

    func testIdenticalContenderCannotReplacePendingWhileWinningProviderIsSuspended() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)

            let reservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("winning store did not install its Invocation")
            }

            let competingReplacement = await contender.markContextCapacityFailure(
                fixture.install.authority
            )
            XCTAssertEqual(competingReplacement, .stale(fixture.locked))

            guard case let .committed(published) = await owner.publish(
                fixture.publication
            ) else { return XCTFail("winning Invocation did not publish") }
            XCTAssertEqual(published, fixture.publication.replacement)
        }
    }

    func testRejectedCompetingRequestDoesNotReleaseWinningRequestLivenessAuthority() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)

            let winningReservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            let competingReservation = await owner.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(winningReservation, .acquired)
            XCTAssertEqual(competingReservation, .blockedByActiveInvocation)
            guard case .committed = await owner.rejectNewSend(fixture.competingAuthority) else {
                return XCTFail("competing request was not rejected")
            }

            let contenderReservation = await contender.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(contenderReservation, .blockedByActiveInvocation)
        }
    }

    func testReservationCancellationReleasesOnlyTheExactPendingRequest() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)

            await owner.cancelInvocationReservation(
                fixture.competingAuthority.request
            )
            let stillBlocked = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(stillBlocked, .blockedByActiveInvocation)

            await owner.cancelInvocationReservation(
                fixture.install.authority.request
            )
            let released = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(released, .acquired)
        }
    }

    func testInvocationInstallRejectsLibraryRootReplacementAfterReservation() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let store = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await store.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)

            let original = parent.appendingPathComponent(
                "Reserved-Library-Root.audoralibrary"
            )
            try FileManager.default.moveItem(at: fixture.root, to: original)
            try FileManager.default.copyItem(at: original, to: fixture.root)

            let outcome = await store.installInvocation(fixture.install)
            XCTAssertEqual(outcome, .failed)
            let cleanup = await store.rejectNewSend(fixture.install.authority)
            XCTAssertEqual(cleanup, .failed)
            XCTAssertFalse(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
            guard case let .readWrite(current) = try PortableChatPersistence().load(
                fixture.locked.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("replacement Library did not retain its Chat") }
            XCTAssertEqual(current, fixture.locked)
        }
    }

    func testInvocationPublicationRejectsInvocationsDirectoryReplacement() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let store = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await store.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)
            guard case .installed = await store.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }

            let invocations = fixture.root.appendingPathComponent(
                "invocations",
                isDirectory: true
            )
            let ownedInvocations = parent.appendingPathComponent(
                "Reserved-Invocations",
                isDirectory: true
            )
            try FileManager.default.moveItem(at: invocations, to: ownedInvocations)
            try FileManager.default.copyItem(at: ownedInvocations, to: invocations)

            let outcome = await store.publish(fixture.publication)
            XCTAssertEqual(outcome, .failed)
            guard case let .readWrite(current) = try PortableChatPersistence().load(
                fixture.locked.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("replacement Library did not retain its Chat") }
            XCTAssertEqual(current, fixture.locked)
        }
    }

    func testReservedPendingMutationRejectsLibraryRootReplacement() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let store = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await store.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)

            let original = parent.appendingPathComponent(
                "Reserved-Pending-Library.audoralibrary"
            )
            try FileManager.default.moveItem(at: fixture.root, to: original)
            try FileManager.default.copyItem(at: original, to: fixture.root)

            let outcome = await store.rejectNewSend(fixture.install.authority)
            XCTAssertEqual(outcome, .failed)
            guard case let .readWrite(current) = try PortableChatPersistence().load(
                fixture.locked.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("replacement Library did not retain its Chat") }
            XCTAssertEqual(current, fixture.locked)
        }
    }

    func testReservationRejectsLibraryRootReplacementBeforeReconciliation() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let original = parent.appendingPathComponent(
                "Reserved-Reconciliation-Library.audoralibrary"
            )
            let persistence = PortableChatPersistence { point in
                guard point == .beforeInvocationReconciliation else { return }
                try FileManager.default.moveItem(at: fixture.root, to: original)
                try FileManager.default.copyItem(at: original, to: fixture.root)
            }
            let store = PortableInvocationStore(
                persistence: persistence,
                workspace: fixture.workspace
            )

            let outcome = await store.reserveInvocation(
                fixture.install.authority.request
            )

            XCTAssertEqual(outcome, .unavailable)
            XCTAssertFalse(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
        }
    }

    func testReconciliationRevalidatesLibraryAuthorityAtDestructiveCommit() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            do {
                let crashed = PortableInvocationStore(workspace: fixture.workspace)
                let reservation = await crashed.reserveInvocation(
                    fixture.install.authority.request
                )
                XCTAssertEqual(reservation, .acquired)
                guard case .installed = await crashed.installInvocation(fixture.install) else {
                    return XCTFail("Invocation was not installed")
                }
            }

            let original = parent.appendingPathComponent(
                "Reserved-Reconciliation-Commit.audoralibrary"
            )
            let oneShot = OneShot()
            let persistence = PortableChatPersistence { point in
                guard point == .beforeInvocationReconciliationCommit,
                      oneShot.take()
                else { return }
                try FileManager.default.moveItem(at: fixture.root, to: original)
                try FileManager.default.copyItem(at: original, to: fixture.root)
            }
            let recovering = PortableInvocationStore(
                persistence: persistence,
                workspace: fixture.workspace
            )

            let outcome = await recovering.reserveInvocation(
                fixture.competingAuthority.request
            )

            XCTAssertEqual(outcome, .unavailable)
            XCTAssertTrue(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
            guard case let .readWrite(current) = try PortableChatPersistence().load(
                fixture.locked.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("replacement Library did not retain its Chat") }
            XCTAssertEqual(current, fixture.locked)
        }
    }

    func testAbortRevalidatesLibraryAuthorityBetweenDestructiveCommits() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let original = parent.appendingPathComponent(
                "Reserved-Abort-Commit.audoralibrary"
            )
            let oneShot = OneShot()
            let persistence = PortableChatPersistence { point in
                guard point == .afterInvocationAbortPendingFailureInstall,
                      oneShot.take()
                else { return }
                try FileManager.default.moveItem(at: fixture.root, to: original)
                try FileManager.default.copyItem(at: original, to: fixture.root)
            }
            let store = PortableInvocationStore(
                persistence: persistence,
                workspace: fixture.workspace
            )
            let reservation = await store.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)
            guard case let .installed(invocation) = await store.installInvocation(
                fixture.install
            ) else { return XCTFail("Invocation was not installed") }

            let outcome = await store.abortInstalledNewSend(invocation)

            XCTAssertEqual(outcome, .failed)
            let invocationURL = original
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(invocation.id.rawValue, isDirectory: true)
                .appendingPathComponent("invocation.json")
            let invocationObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: invocationURL))
                    as? [String: Any]
            )
            XCTAssertEqual(
                invocationObject["terminalFailure"] as? String,
                "coachResponseInterrupted"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: original
                        .appendingPathComponent("chats", isDirectory: true)
                        .appendingPathComponent(invocation.chatID.rawValue, isDirectory: true)
                        .appendingPathComponent("aborting-invocation.json")
                        .path
                ),
                "the detached Library must not receive a second destructive commit"
            )
        }
    }

    func testLibraryLoadReconcilesCrashedInvocationBeforeAnyNewReservation() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let release = InvocationLivenessReleaseObservation()
            let diagnostics = RecordingPortableInvocationRetryDiagnostics()
            let recoveredAt = try UTCInstant("2026-08-30T12:05:00.000Z")
            let persistence = PortableChatPersistence(
                fault: { _ in },
                invocationLivenessReleased: release.didRelease,
                retryDiagnostics: diagnostics,
                retryDiagnosticNow: { recoveredAt }
            )
            do {
                let store = PortableInvocationStore(
                    persistence: persistence,
                    workspace: fixture.workspace
                )
                let reservation = await store.reserveInvocation(
                    fixture.install.authority.request
                )
                XCTAssertEqual(reservation, .acquired)
                guard case .installed = await store.installInvocation(fixture.install) else {
                    return XCTFail("Invocation was not installed")
                }
            }
            await release.waitUntilReleased()

            let relaunched = PortableChatStore(
                persistence: persistence,
                workspace: fixture.workspace
            )
            guard case let .loaded(reopened) = await relaunched.load(
                fixture.locked.chat.id,
                in: fixture.scope
            ) else { return XCTFail("reconciled Chat was unavailable") }
            XCTAssertFalse(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
            XCTAssertEqual(
                reopened.pendingUserTurn?.failure,
                .coachResponseInterrupted
            )
            XCTAssertEqual(reopened.chat.draft, fixture.locked.chat.draft)
            XCTAssertEqual(reopened.chat.messageIDs, [])
            let event = try XCTUnwrap(diagnostics.recordedEvents().first)
            XCTAssertEqual(diagnostics.recordedEvents().count, 1)
            XCTAssertEqual(event.reason, .relaunchedInvocationInterrupted)
            XCTAssertEqual(event.classification, .interruption)
            XCTAssertEqual(event.disposition, .userRetryableFailure)
            XCTAssertEqual(event.invocationID, fixture.install.invocation.id)
            XCTAssertEqual(event.attemptID, fixture.install.invocation.attempt.id)
            XCTAssertEqual(event.attemptOrdinal, 1)
            XCTAssertEqual(event.retryNumber, 1)
            XCTAssertEqual(event.occurredAt, recoveredAt)
            XCTAssertEqual(event.context, .unavailable)
        }
    }

    func testLibraryLoadReconcilesPreinstallCrashToRetryablePendingIntent() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            XCTAssertFalse(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
            let diagnostics = RecordingPortableInvocationRetryDiagnostics()
            let recoveredAt = try UTCInstant("2026-08-30T12:05:00.000Z")
            let persistence = PortableChatPersistence(
                retryDiagnostics: diagnostics,
                retryDiagnosticNow: { recoveredAt }
            )
            let competing = fixture.competingAuthority.pendingUserTurn
            guard case .committed = try persistence.replacePendingUserTurn(
                ReplacePendingUserTurnMutation(
                    library: fixture.scope,
                    chatID: fixture.competingAuthority.request.chatID,
                    base: competing,
                    replacement: competing.replacingFailure(
                        .coachContextCannotFit
                    )
                ),
                at: fixture.root
            ) else { return XCTFail("failed to install existing recovery state") }

            let relaunched = PortableChatStore(
                persistence: persistence,
                workspace: fixture.workspace
            )
            guard case let .loaded(reopened) = await relaunched.load(
                fixture.locked.chat.id,
                in: fixture.scope
            ) else { return XCTFail("reconciled Chat was unavailable") }

            XCTAssertEqual(reopened.pendingUserTurn?.id, fixture.locked.pendingUserTurn?.id)
            XCTAssertEqual(
                reopened.pendingUserTurn?.failure,
                .coachResponseInterrupted
            )
            XCTAssertEqual(reopened.chat.draft, fixture.locked.chat.draft)
            XCTAssertEqual(reopened.chat.messageIDs, [])
            guard case let .readWrite(competingReopened) = try persistence.load(
                fixture.competingAuthority.request.chatID,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("existing recovery Chat did not reopen") }
            XCTAssertEqual(
                competingReopened.pendingUserTurn?.failure,
                .coachContextCannotFit
            )
            let event = try XCTUnwrap(diagnostics.recordedEvents().first)
            XCTAssertEqual(diagnostics.recordedEvents().count, 1)
            XCTAssertEqual(event.reason, .relaunchedInvocationInterrupted)
            XCTAssertEqual(event.classification, .interruption)
            XCTAssertNil(event.invocationID)
            XCTAssertNil(event.attemptID)
            XCTAssertNil(event.attemptOrdinal)
            XCTAssertNil(event.retryNumber)
            XCTAssertEqual(event.occurredAt, recoveredAt)
            XCTAssertEqual(event.context, .unavailable)
        }
    }

    func testCatalogReconcilesHealthyPreinstallPendingWhenSiblingChatIsCorrupt() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let corruptChatID = fixture.competingAuthority.request.chatID
            try Data("not-json".utf8).write(
                to: fixture.root
                    .appendingPathComponent("chats", isDirectory: true)
                    .appendingPathComponent(corruptChatID.rawValue, isDirectory: true)
                    .appendingPathComponent("chat.json")
            )

            let relaunched = PortableChatStore(workspace: fixture.workspace)
            guard case let .loaded(entries) = await relaunched.loadCatalog(
                in: fixture.scope
            ) else { return XCTFail("one corrupt Chat must not fail the catalog") }

            XCTAssertEqual(entries.count, 2)
            XCTAssertTrue(entries.contains(.frozen(
                FrozenChatSnapshot(chatID: corruptChatID, reason: .corrupt)
            )))
            guard let healthy = entries.compactMap({ entry -> ChatAggregate? in
                guard case let .available(aggregate) = entry,
                      aggregate.chat.id == fixture.locked.chat.id
                else { return nil }
                return aggregate
            }).first else { return XCTFail("healthy sibling was hidden") }
            XCTAssertEqual(healthy.pendingUserTurn?.failure, .coachResponseInterrupted)
            XCTAssertEqual(healthy.chat.draft, fixture.locked.chat.draft)
            XCTAssertEqual(healthy.chat.messageIDs, [])
        }
    }

    func testCatalogReconcilesHealthyPendingWhenSiblingHasMalformedDomainIdentity() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let malformedChatID = fixture.competingAuthority.request.chatID
            let manifest = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(malformedChatID.rawValue, isDirectory: true)
                .appendingPathComponent("chat.json")
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: manifest)
                ) as? [String: Any]
            )
            object["messageIds"] = ["not-a-message-id"]
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ).write(to: manifest)

            let relaunched = PortableChatStore(workspace: fixture.workspace)
            guard case let .loaded(entries) = await relaunched.loadCatalog(
                in: fixture.scope
            ) else { return XCTFail("malformed sibling identity must remain isolated") }

            XCTAssertTrue(entries.contains(.frozen(
                FrozenChatSnapshot(chatID: malformedChatID, reason: .corrupt)
            )))
            let healthy = entries.compactMap { entry -> ChatAggregate? in
                guard case let .available(aggregate) = entry,
                      aggregate.chat.id == fixture.locked.chat.id
                else { return nil }
                return aggregate
            }.first
            XCTAssertEqual(
                healthy?.pendingUserTurn?.failure,
                .coachResponseInterrupted
            )
        }
    }

    func testInvocationGatewayAcquisitionDoesNotMisclassifyItsLivePendingAsCrashed() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let store = PortableInvocationStore(workspace: fixture.workspace)

            let resolution = await store.acquirePendingInvocation(
                fixture.install.authority.request
            )

            XCTAssertEqual(resolution, .acquired(fixture.install.authority))
            guard case let .readWrite(reopened) = try PortableChatPersistence().load(
                fixture.locked.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("live Pending did not reopen") }
            XCTAssertNil(reopened.pendingUserTurn?.failure)
            await store.cancelInvocationReservation(
                fixture.install.authority.request
            )
        }
    }

    func testPendingRejectionReleasesLibraryLivenessAuthority() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)
            guard case .committed = await owner.rejectNewSend(
                fixture.install.authority
            ) else { return XCTFail("Pending User Turn was not rejected") }

            let next = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(next, .acquired)
        }
    }

    func testFailedInstallKeepsLivenessUntilItsPendingTerminalMutation() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let persistence = PortableChatPersistence { point in
                guard point == .beforeInvocationPartialWrite else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            let owner = PortableInvocationStore(
                persistence: persistence,
                workspace: fixture.workspace
            )
            let contender = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)
            let install = await owner.installInvocation(fixture.install)
            XCTAssertEqual(install, .failed)

            let blocked = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(blocked, .blockedByActiveInvocation)
            guard case .committed = await owner.rejectNewSend(
                fixture.install.authority
            ) else { return XCTFail("failed Invocation did not terminate") }
            let released = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(released, .acquired)
        }
    }

    func testContextCapacityFailureReleasesLibraryLivenessAuthority() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)
            guard case .committed = await owner.markContextCapacityFailure(
                fixture.install.authority
            ) else { return XCTFail("capacity failure was not persisted") }

            let next = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(next, .acquired)
        }
    }

    func testInvocationAbortReleasesLibraryLivenessAuthority() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)
            guard case let .installed(invocation) = await owner.installInvocation(
                fixture.install
            ) else { return XCTFail("Invocation was not installed") }
            guard case .committed = await owner.abortInstalledNewSend(invocation) else {
                return XCTFail("Invocation was not aborted")
            }

            let next = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(next, .acquired)
        }
    }

    func testLaunchIdentityPreflightOwnsEveryDurableNamespaceIncludingOrphans() async throws {
        let durableCollisions: [InvocationLaunchIdentityCollision] = [
            .invocationID,
            .attemptID,
            .userMessageID,
            .coachMessageID,
            .freshDraftID,
        ]
        for expected in durableCollisions {
            try await withTemporaryParent { parent in
                let fixture = try await makeInvocationStoreFixture(in: parent)
                let persistence = PortableChatPersistence()
                let store = PortableInvocationStore(
                    persistence: persistence,
                    workspace: fixture.workspace
                )
                let reservation = await store.reserveInvocation(
                    fixture.install.authority.request
                )
                XCTAssertEqual(reservation, .acquired)
                let transcriptHandle = try CoachProviderTranscriptHandle(
                    "01234567-89ab-cdef-0123-456789abcdef"
                )
                let candidate = InvocationLaunchIdentity(
                    invocationID: fixture.install.invocation.id,
                    attemptIdentity: InvocationAttemptIdentity(
                        attemptID: fixture.install.invocation.attemptID,
                        idempotencyValue:
                            try XCTUnwrap(
                                fixture.install.invocation.providerIdempotencyValue
                            ),
                        userMessageID: fixture.publication.userMessage.id,
                        coachMessageID: fixture.publication.coachMessage.id,
                        freshDraftID: expected == .freshDraftID
                            ? fixture.locked.chat.draft.draftID
                            : fixture.publication.freshDraft.draftID,
                        transcriptHandles: [transcriptHandle]
                    )
                )
                let invocationsRoot = fixture.root.appendingPathComponent(
                    "invocations",
                    isDirectory: true
                )
                let messagesRoot = fixture.root
                    .appendingPathComponent("chats", isDirectory: true)
                    .appendingPathComponent(
                        fixture.locked.chat.id.rawValue,
                        isDirectory: true
                    )
                    .appendingPathComponent("messages", isDirectory: true)

                switch expected {
                case .invocationID:
                    try FileManager.default.createDirectory(
                        at: invocationsRoot.appendingPathComponent(
                            candidate.invocationID.rawValue,
                            isDirectory: true
                        ),
                        withIntermediateDirectories: false
                    )
                case .attemptID:
                    let alternateAttempt = try CoachProviderAttempt(
                        id: candidate.attemptID,
                        ordinal: 1,
                        kind: .standard,
                        providerIdempotencyValue:
                            ProviderIdempotencyValue("alternate-8WXY"),
                        transcriptHandles: [],
                        publicationAuthority: CoachProviderAttemptPublicationAuthority(
                            userMessageID: ChatMessageID(
                                "msg-20260830T120002000Z-9YZ0"
                            ),
                            coachMessageID: ChatMessageID(
                                "msg-20260830T120002000Z-0ABC"
                            ),
                            freshDraftID: ChatDraftID(
                                "drf-20260830T120002000Z-1BCD"
                            )
                        )
                    )
                    let alternate = try CoachInvocation(
                        id: CoachInvocationID("inv-20260830T120002000Z-7STV"),
                        attempt: alternateAttempt,
                        library: fixture.scope,
                        chatID: fixture.locked.chat.id,
                        pendingUserTurn: fixture.locked.pendingUserTurn!,
                        preparedProfile: fixture.install.invocation.preparedProfile,
                        expectedManifestRevision:
                            fixture.locked.chat.manifestRevision,
                        admittedAt: fixture.install.invocation.admittedAt
                    )
                    let root = invocationsRoot.appendingPathComponent(
                        alternate.id.rawValue,
                        isDirectory: true
                    )
                    try FileManager.default.createDirectory(
                        at: root,
                        withIntermediateDirectories: false
                    )
                    try persistence.encodeInvocation(alternate).write(
                        to: root.appendingPathComponent("invocation.json")
                    )
                case .providerIdempotencyValue, .transcriptHandle:
                    return XCTFail("process-live transport is not a durable namespace")
                case .userMessageID:
                    try persistence.encodeMessage(fixture.publication.userMessage).write(
                        to: messagesRoot.appendingPathComponent(
                            "\(candidate.userMessageID.rawValue).json"
                        )
                    )
                case .coachMessageID:
                    try persistence.encodeMessage(fixture.publication.coachMessage).write(
                        to: messagesRoot.appendingPathComponent(
                            "\(candidate.coachMessageID.rawValue).json"
                        )
                    )
                case .freshDraftID:
                    break
                }

                let availability = await store.checkLaunchIdentity(
                    candidate,
                    for: fixture.install.authority
                )
                XCTAssertEqual(
                    availability,
                    .collision(expected),
                    String(describing: expected)
                )
                await store.cancelInvocationReservation(
                    fixture.install.authority.request
                )
            }
        }
    }

    func testLaunchIdentityPreflightDecodesEscapedFrozenChatPublicIDs() async throws {
        let cases: [(String, Bool, InvocationLaunchIdentityCollision)] = [
            ("newer-message", true, .userMessageID),
            ("newer-draft", true, .freshDraftID),
            ("corrupt-message", false, .userMessageID),
            ("corrupt-draft", false, .freshDraftID),
        ]
        for (index, testCase) in cases.enumerated() {
            try await withTemporaryParent { parent in
                let (label, newerSchema, expected) = testCase
                let fixture = try await makeInvocationStoreFixture(
                    in: parent,
                    libraryID: "lib-20260902T10000\(index)000Z-2ABC",
                    includeCompetingPending: true
                )
                let invocation = fixture.install.invocation
                let candidate = InvocationLaunchIdentity(
                    invocationID: invocation.id,
                    attemptID: invocation.attemptID,
                    idempotencyValue: try XCTUnwrap(
                        invocation.providerIdempotencyValue
                    ),
                    userMessageID: fixture.publication.userMessage.id,
                    coachMessageID: fixture.publication.coachMessage.id,
                    freshDraftID: fixture.publication.freshDraft.draftID
                )
                try writeEscapedFrozenSiblingChatRoot(
                    in: fixture,
                    newerSchema: newerSchema,
                    messageID: expected == .userMessageID
                        ? candidate.userMessageID
                        : nil,
                    draftID: expected == .freshDraftID
                        ? candidate.freshDraftID
                        : nil
                )

                let store = PortableInvocationStore(workspace: fixture.workspace)
                let reservation = await store.reserveInvocation(
                    fixture.install.authority.request
                )
                XCTAssertEqual(
                    reservation,
                    .acquired,
                    label
                )
                let availability = await store.checkLaunchIdentity(
                    candidate,
                    for: fixture.install.authority
                )
                XCTAssertEqual(
                    availability,
                    .collision(expected),
                    label
                )
                await store.cancelInvocationReservation(
                    fixture.install.authority.request
                )
            }
        }
    }

    func testLaunchIdentityPreflightDoesNotReserveOpaqueFrozenChatStrings()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let invocation = fixture.install.invocation
            let candidate = InvocationLaunchIdentity(
                invocationID: invocation.id,
                attemptID: invocation.attemptID,
                idempotencyValue: try XCTUnwrap(
                    invocation.providerIdempotencyValue
                ),
                userMessageID: fixture.publication.userMessage.id,
                coachMessageID: fixture.publication.coachMessage.id,
                freshDraftID: fixture.publication.freshDraft.draftID
            )
            try writeOpaqueFrozenSiblingChatRoot(
                in: fixture,
                identity: candidate.attemptIdentity
            )
            let store = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await store.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)

            let availability = await store.checkLaunchIdentity(
                candidate,
                for: fixture.install.authority
            )
            XCTAssertEqual(availability, .available)
            await store.cancelInvocationReservation(
                fixture.install.authority.request
            )
        }
    }

    func testLaunchIdentityPreflightFailsClosedForAmbiguousSiblingChatPublicIDs()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let invocation = fixture.install.invocation
            let candidate = InvocationLaunchIdentity(
                invocationID: invocation.id,
                attemptID: invocation.attemptID,
                idempotencyValue: try XCTUnwrap(
                    invocation.providerIdempotencyValue
                ),
                userMessageID: fixture.publication.userMessage.id,
                coachMessageID: fixture.publication.coachMessage.id,
                freshDraftID: fixture.publication.freshDraft.draftID
            )
            try writeAmbiguousSiblingChatRoot(
                in: fixture,
                messageID: candidate.userMessageID
            )
            let store = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await store.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)

            let availability = await store.checkLaunchIdentity(
                candidate,
                for: fixture.install.authority
            )
            XCTAssertEqual(availability, .unavailable)
            await store.cancelInvocationReservation(
                fixture.install.authority.request
            )
        }
    }

    func testLaunchIdentityPreflightChecksSupportedInvocationRootDraftID() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let invocation = fixture.install.invocation
            let candidate = InvocationLaunchIdentity(
                invocationID: invocation.id,
                attemptID: invocation.attemptID,
                idempotencyValue: try XCTUnwrap(
                    invocation.providerIdempotencyValue
                ),
                userMessageID: fixture.publication.userMessage.id,
                coachMessageID: fixture.publication.coachMessage.id,
                freshDraftID: try ChatDraftID(
                    "drf-20260902T100300000Z-3DEF"
                )
            )
            let store = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await store.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)
            try writeSupportedInvocation(
                in: fixture,
                rootDraftID: candidate.freshDraftID
            )

            let availability = await store.checkLaunchIdentity(
                candidate,
                for: fixture.install.authority
            )
            XCTAssertEqual(availability, .collision(.freshDraftID))
            await store.cancelInvocationReservation(
                fixture.install.authority.request
            )
        }
    }

    func testLaunchIdentityPreflightUsesReadableFrozenRootAndFailsClosedWhenUnreadable()
        async throws
    {
        for (corruption, expected) in [
            ("corrupt", InvocationLaunchIdentityAvailabilityOutcome.unavailable),
            ("newer", InvocationLaunchIdentityAvailabilityOutcome.available),
        ] {
            try await withTemporaryParent { parent in
                let fixture = try await makeInvocationStoreFixture(
                    in: parent,
                    includeCompetingPending: true
                )
                let persistence = PortableChatPersistence()
                let store = PortableInvocationStore(
                    persistence: persistence,
                    workspace: fixture.workspace
                )
                let reservation = await store.reserveInvocation(
                    fixture.install.authority.request
                )
                XCTAssertEqual(reservation, .acquired)
                let siblingManifest = fixture.root
                    .appendingPathComponent("chats", isDirectory: true)
                    .appendingPathComponent(
                        fixture.competingAuthority.request.chatID.rawValue,
                        isDirectory: true
                    )
                    .appendingPathComponent("chat.json")
                if corruption == "corrupt" {
                    try Data("not-json".utf8).write(to: siblingManifest)
                } else {
                    var object = try XCTUnwrap(
                        JSONSerialization.jsonObject(
                            with: Data(contentsOf: siblingManifest)
                        ) as? [String: Any]
                    )
                    object["schemaVersion"] = Chat.schemaVersion + 1
                    try JSONSerialization.data(
                        withJSONObject: object,
                        options: [.sortedKeys]
                    ).write(to: siblingManifest)
                }

                let invocation = fixture.install.invocation
                let candidate = InvocationLaunchIdentity(
                    invocationID: invocation.id,
                    attemptID: invocation.attemptID,
                    idempotencyValue: try XCTUnwrap(
                        invocation.providerIdempotencyValue
                    ),
                    userMessageID: fixture.publication.userMessage.id,
                    coachMessageID: fixture.publication.coachMessage.id,
                    freshDraftID: fixture.publication.freshDraft.draftID
                )

                let availability = await store.checkLaunchIdentity(
                    candidate,
                    for: fixture.install.authority
                )
                XCTAssertEqual(availability, expected, corruption)
                await store.cancelInvocationReservation(
                    fixture.install.authority.request
                )
            }
        }
    }

    func testLaunchIdentityPreflightFailsClosedWhenSiblingNamespaceHasIOFailure() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let persistence = PortableChatPersistence()
            let store = PortableInvocationStore(
                persistence: persistence,
                workspace: fixture.workspace
            )
            let reservation = await store.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)
            let candidate = InvocationLaunchIdentity(
                invocationID: fixture.install.invocation.id,
                attemptID: fixture.install.invocation.attemptID,
                idempotencyValue: try XCTUnwrap(
                    fixture.install.invocation.providerIdempotencyValue
                ),
                userMessageID: fixture.publication.userMessage.id,
                coachMessageID: fixture.publication.coachMessage.id,
                freshDraftID: fixture.publication.freshDraft.draftID
            )
            let messages = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(
                    fixture.competingAuthority.request.chatID.rawValue,
                    isDirectory: true
                )
                .appendingPathComponent("messages", isDirectory: true)
            let collisionFile = messages.appendingPathComponent(
                "\(candidate.userMessageID.rawValue).json"
            )
            try persistence.encodeMessage(fixture.publication.userMessage).write(
                to: collisionFile
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: collisionFile.path))
            XCTAssertEqual(messages.path.withCString { Darwin.chmod($0, 0) }, 0)
            defer {
                _ = messages.path.withCString { Darwin.chmod($0, 0o700) }
            }
            let permissionProbe = messages.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            }
            if permissionProbe >= 0 { Darwin.close(permissionProbe) }
            XCTAssertLessThan(permissionProbe, 0)

            let availability = await store.checkLaunchIdentity(
                candidate,
                for: fixture.install.authority
            )
            XCTAssertEqual(availability, .unavailable)
            await store.cancelInvocationReservation(
                fixture.install.authority.request
            )
        }
    }

    func testLaunchIdentityPreflightScansFrozenFutureInvocationPublicIDs() async throws {
        let cases: [InvocationLaunchIdentityCollision?] = [
            nil,
            .attemptID,
            .userMessageID,
            .coachMessageID,
            .freshDraftID,
        ]
        try await withTemporaryParent { parent in
            for (index, expected) in cases.enumerated() {
                let caseParent = parent.appendingPathComponent(
                    "future-preflight-\(index)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: caseParent,
                    withIntermediateDirectories: false
                )
                let fixture = try await makeInvocationStoreFixture(
                    in: caseParent,
                    libraryID: "lib-20260830T12110\(index)000Z-2ABC",
                    includeCompetingPending: true
                )
                let invocation = fixture.install.invocation
                let opaqueHandle = try CoachProviderTranscriptHandle(
                    "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
                )
                let candidate = InvocationLaunchIdentity(
                    invocationID: invocation.id,
                    attemptIdentity: InvocationAttemptIdentity(
                        attemptID: invocation.attemptID,
                        idempotencyValue: try XCTUnwrap(
                            invocation.providerIdempotencyValue
                        ),
                        userMessageID: fixture.publication.userMessage.id,
                        coachMessageID: fixture.publication.coachMessage.id,
                        freshDraftID: fixture.publication.freshDraft.draftID,
                        transcriptHandles: [opaqueHandle]
                    )
                )
                try writeFutureInvocation(
                    in: fixture,
                    chatID: fixture.competingAuthority.request.chatID,
                    attemptID: expected == .attemptID
                        ? candidate.attemptID.rawValue
                        : "atm-20260830T121109000Z-0ABC",
                    userMessageID: expected == .userMessageID
                        ? candidate.userMessageID.rawValue
                        : "msg-20260830T121109000Z-1BCD",
                    coachMessageID: expected == .coachMessageID
                        ? candidate.coachMessageID.rawValue
                        : "msg-20260830T121109000Z-2CDE",
                    freshDraftID: expected == .freshDraftID
                        ? candidate.freshDraftID.rawValue
                        : "drf-20260830T121109000Z-3DEF",
                    opaqueTransportValues: expected == nil
                        ? [
                            candidate.attemptID.rawValue,
                            candidate.idempotencyValue.rawValue,
                            opaqueHandle.rawValue,
                        ]
                        : [
                            candidate.idempotencyValue.rawValue,
                            opaqueHandle.rawValue,
                        ]
                )

                let store = PortableInvocationStore(workspace: fixture.workspace)
                let reservation = await store.reserveInvocation(
                    fixture.install.authority.request
                )
                XCTAssertEqual(
                    reservation,
                    .acquired,
                    String(describing: expected)
                )
                let availability = await store.checkLaunchIdentity(
                    candidate,
                    for: fixture.install.authority
                )
                if let expected {
                    XCTAssertEqual(
                        availability,
                        .collision(expected),
                        String(describing: expected)
                    )
                } else {
                    XCTAssertEqual(availability, .available, "noncollision")
                }
                await store.cancelInvocationReservation(
                    fixture.install.authority.request
                )
            }
        }
    }

    func testLaunchIdentityPreflightDecodesEscapedFutureInvocationPublicID() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let invocation = fixture.install.invocation
            let candidate = InvocationLaunchIdentity(
                invocationID: invocation.id,
                attemptID: invocation.attemptID,
                idempotencyValue: try XCTUnwrap(invocation.providerIdempotencyValue),
                userMessageID: fixture.publication.userMessage.id,
                coachMessageID: fixture.publication.coachMessage.id,
                freshDraftID: fixture.publication.freshDraft.draftID
            )
            let futureInvocationID = try writeFutureInvocation(
                in: fixture,
                chatID: fixture.competingAuthority.request.chatID,
                attemptID: candidate.attemptID.rawValue,
                userMessageID: "msg-20260830T121509000Z-1BCD",
                coachMessageID: "msg-20260830T121509000Z-2CDE",
                freshDraftID: "drf-20260830T121509000Z-3DEF"
            )
            let futureURL = fixture.root
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(futureInvocationID.rawValue, isDirectory: true)
                .appendingPathComponent("invocation.json")
            let canonicalText = try XCTUnwrap(
                String(data: Data(contentsOf: futureURL), encoding: .utf8)
            )
            let escapedAttemptID = "\\u0061" + candidate.attemptID.rawValue.dropFirst()
            let escapedText = canonicalText.replacingOccurrences(
                of: candidate.attemptID.rawValue,
                with: escapedAttemptID
            )
            XCTAssertNotEqual(escapedText, canonicalText)
            try Data(escapedText.utf8).write(to: futureURL)

            let store = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await store.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)
            let availability = await store.checkLaunchIdentity(
                candidate,
                for: fixture.install.authority
            )
            XCTAssertEqual(availability, .collision(.attemptID))
            await store.cancelInvocationReservation(
                fixture.install.authority.request
            )
        }
    }

    func testLaunchIdentityPreflightScansEscapedFutureInvocationRootDraftID()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let invocation = fixture.install.invocation
            let candidate = InvocationLaunchIdentity(
                invocationID: invocation.id,
                attemptID: invocation.attemptID,
                idempotencyValue: try XCTUnwrap(invocation.providerIdempotencyValue),
                userMessageID: fixture.publication.userMessage.id,
                coachMessageID: fixture.publication.coachMessage.id,
                freshDraftID: try ChatDraftID("drf-20260830T121709000Z-4GHJ")
            )
            let competingDraft = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(
                    fixture.competingAuthority.request.chatID.rawValue,
                    isDirectory: true
                )
                .appendingPathComponent("draft.json")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: competingDraft.path)
            )

            let futureInvocationID = try writeFutureInvocation(
                in: fixture,
                chatID: fixture.competingAuthority.request.chatID,
                attemptID: "atm-20260830T121709000Z-0ABC",
                userMessageID: "msg-20260830T121709000Z-1BCD",
                coachMessageID: "msg-20260830T121709000Z-2CDE",
                freshDraftID: "drf-20260830T121709000Z-3DEF",
                draftID: candidate.freshDraftID.rawValue
            )
            let futureURL = fixture.root
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(futureInvocationID.rawValue, isDirectory: true)
                .appendingPathComponent("invocation.json")
            let canonicalText = try XCTUnwrap(
                String(data: Data(contentsOf: futureURL), encoding: .utf8)
            )
            let property = "\"draftId\":\"" + candidate.freshDraftID.rawValue + "\""
            let escapedID = "\\u0064" + candidate.freshDraftID.rawValue.dropFirst()
            let escapedText = canonicalText.replacingOccurrences(
                of: property,
                with: "\"draftId\":\"" + escapedID + "\""
            )
            XCTAssertNotEqual(escapedText, canonicalText)
            XCTAssertFalse(escapedText.contains(candidate.freshDraftID.rawValue))
            try Data(escapedText.utf8).write(to: futureURL)

            let store = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await store.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)
            let availability = await store.checkLaunchIdentity(
                candidate,
                for: fixture.install.authority
            )
            XCTAssertEqual(availability, .collision(.freshDraftID))
            await store.cancelInvocationReservation(
                fixture.install.authority.request
            )
        }
    }

    func testLaunchIdentityReservationFencesFreshDraftNamespaceWriterBeforeProvider() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let store = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await store.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)
            let invocation = fixture.install.invocation
            let identity = InvocationLaunchIdentity(
                invocationID: invocation.id,
                attemptID: invocation.attemptID,
                idempotencyValue: try XCTUnwrap(
                    invocation.providerIdempotencyValue
                ),
                userMessageID: fixture.publication.userMessage.id,
                coachMessageID: fixture.publication.coachMessage.id,
                freshDraftID: fixture.publication.freshDraft.draftID
            )
            let identityAvailability = await store.checkLaunchIdentity(
                identity,
                for: fixture.install.authority
            )
            XCTAssertEqual(identityAvailability, .available)
            let conflictingSeed = try NewDevelopmentChatSeed(
                library: fixture.scope,
                chatID: ChatID("cht-20260830T120020000Z-3DEF"),
                draftID: fixture.publication.freshDraft.draftID,
                memoryID: CoachMemoryID("mem-20260830T120020000Z-5KMN"),
                instant: UTCInstant("2026-08-30T12:00:20.000Z"),
                profileStatementGeneration: 0
            )

            XCTAssertThrowsError(
                try PortableChatPersistence().create(
                    conflictingSeed,
                    at: fixture.root
                )
            ) { error in
                XCTAssertEqual(error as? PortableChatPersistenceError, .ioFailure)
            }

            await store.cancelInvocationReservation(
                fixture.install.authority.request
            )
            XCTAssertNoThrow(
                try PortableChatPersistence().create(
                    conflictingSeed,
                    at: fixture.root
                )
            )
        }
    }

    func testInvocationPublicationReleasesLibraryLivenessAuthority() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }
            guard case .committed = await owner.publish(fixture.publication) else {
                return XCTFail("Invocation was not published")
            }

            let next = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(next, .acquired)
        }
    }

    func testLivePublicationProofPartialDoesNotFreezeOrMutatePendingRead() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            guard case .acquired = await owner.acquirePendingInvocation(
                fixture.install.authority.request
            ) else { return XCTFail("Pending authority was not acquired") }
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }
            let partial = fixture.root
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(
                    fixture.install.invocation.id.rawValue,
                    isDirectory: true
                )
                .appendingPathComponent(
                    ".publication-proof.json.11111111-1111-1111-1111-111111111111.partial"
                )
            try Data("in-progress".utf8).write(to: partial)

            let readingWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await readingWorkspace.chooseLibrary()
            let reader = PortableChatStore(workspace: readingWorkspace)
            let load = await reader.load(fixture.locked.chat.id, in: fixture.scope)

            XCTAssertEqual(load, .loaded(fixture.locked))
            XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
            _ = await owner.abortInstalledNewSend(fixture.install.invocation)
        }
    }

    func testCommittedPublicationSurvivesFailedImmediateReconciliationAndRecoveryReread() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let persistence = PortableChatPersistence { point in
                if point == .afterPublicationManifestInstall
                    || point == .beforePublicationReconciliationRead
                {
                    throw PortableChatPersistenceError.injectedFault(point)
                }
            }
            let store = PortableInvocationStore(
                persistence: persistence,
                workspace: fixture.workspace
            )
            let acquired = await store.acquirePendingInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(acquired, .acquired(fixture.install.authority))
            guard case .installed = await store.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }

            let publish = await store.publish(fixture.publication)
            XCTAssertEqual(publish, .failed)
            let abort = await store.abortInstalledNewSend(
                fixture.install.invocation
            )
            XCTAssertEqual(abort, .stale(fixture.publication.replacement))
            let recovery = await store.recoverPendingAfterTerminalFailure(
                fixture.install.authority.request
            )
            XCTAssertEqual(
                recovery,
                .ineligible(fixture.publication.replacement)
            )
        }
    }

    func testTypedRecoveryRejectsBoundButDifferentDurablePublicationProof() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let publicationFault = OneShot()
            let reconciliationFault = OneShot()
            let owner = PortableInvocationStore(
                persistence: PortableChatPersistence { point in
                    if point == .afterPublicationManifestInstall,
                       publicationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                    if point == .beforePublicationReconciliationRead,
                       reconciliationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                },
                workspace: fixture.workspace
            )
            guard case .acquired = await owner.acquirePendingInvocation(
                fixture.install.authority.request
            ) else { return XCTFail("Pending authority was not acquired") }
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }
            let publication = await owner.publish(fixture.publication)
            XCTAssertEqual(publication, .failed)

            let invocationRoot = fixture.root
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(
                    fixture.install.invocation.id.rawValue,
                    isDirectory: true
                )
            let proofURL = invocationRoot.appendingPathComponent("publication-proof.json")
            var proof = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: proofURL)
                ) as? [String: Any]
            )
            proof["coachMessageSha256"] = String(repeating: "0", count: 64)
            try JSONSerialization.data(
                withJSONObject: proof,
                options: [.sortedKeys]
            ).write(to: proofURL)

            let recovery = await owner.recoverPublishedInvocation(fixture.publication)

            XCTAssertEqual(recovery, .unavailable)
            XCTAssertTrue(FileManager.default.fileExists(atPath: proofURL.path))
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent("chats", isDirectory: true)
                        .appendingPathComponent(
                            fixture.locked.chat.id.rawValue,
                            isDirectory: true
                        )
                        .appendingPathComponent("pending-user-turn.json").path
                )
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: invocationRoot.path))
        }
    }

    func testExactPublishedRecoveryAllowsLaterRenameAndFreshDraftEdit() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let publicationFault = OneShot()
            let reconciliationFault = OneShot()
            let owner = PortableInvocationStore(
                persistence: PortableChatPersistence { point in
                    if point == .afterPublicationManifestInstall,
                       publicationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                    if point == .beforePublicationReconciliationRead,
                       reconciliationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                },
                workspace: fixture.workspace
            )
            let editingWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await editingWorkspace.chooseLibrary()
            let editor = PortableChatStore(workspace: editingWorkspace)
            let acquired = await owner.acquirePendingInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(acquired, .acquired(fixture.install.authority))
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }
            let publish = await owner.publish(fixture.publication)
            XCTAssertEqual(publish, .failed)

            guard case let .loaded(published) = await editor.load(
                fixture.locked.chat.id,
                in: fixture.scope
            ) else { return XCTFail("Published Chat was not readable") }
            let rename = try RenameChatMutation(
                library: fixture.scope,
                base: published,
                title: ChatTitle("Later title"),
                updatedAt: UTCInstant("2026-08-30T12:00:04.000Z")
            )
            guard case let .committed(renamed) = await editor.rename(rename) else {
                return XCTFail("Later rename did not commit")
            }
            let laterDraft = try renamed.chat.draft.edited(
                text: "A later fresh Draft edit.",
                at: UTCInstant("2026-08-30T12:00:05.000Z")
            )
            guard case let .committed(evolved) = await editor.saveDraft(
                SaveChatDraftMutation(
                    library: fixture.scope,
                    chatID: renamed.chat.id,
                    replacement: laterDraft
                )
            ) else { return XCTFail("Later Draft edit did not commit") }

            let recovery = await owner.recoverPublishedInvocation(
                fixture.publication
            )
            XCTAssertEqual(recovery, .published(evolved))
        }
    }

    func testExactPublishedRecoveryRejectsIDOnlyMessageImpostor() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let publicationFault = OneShot()
            let reconciliationFault = OneShot()
            let owner = PortableInvocationStore(
                persistence: PortableChatPersistence { point in
                    if point == .afterPublicationManifestInstall,
                       publicationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                    if point == .beforePublicationReconciliationRead,
                       reconciliationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                },
                workspace: fixture.workspace
            )
            let readingWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await readingWorkspace.chooseLibrary()
            let reader = PortableChatStore(workspace: readingWorkspace)
            guard case .acquired = await owner.acquirePendingInvocation(
                fixture.install.authority.request
            ) else { return XCTFail("Pending authority was not acquired") }
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }
            let publish = await owner.publish(fixture.publication)
            XCTAssertEqual(publish, .failed)
            guard case .loaded = await reader.load(
                fixture.locked.chat.id,
                in: fixture.scope
            ) else { return XCTFail("Published Chat was not readable") }

            let expected = fixture.publication.coachMessage
            let impostor = try ChatMessage(
                id: expected.id,
                responsePositionID: expected.responsePositionID,
                content: .coach(markdown: "Altered immutable response."),
                coachProfile: expected.coachProfile,
                createdAt: expected.createdAt
            )
            let messageURL = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(fixture.locked.chat.id.rawValue, isDirectory: true)
                .appendingPathComponent("messages", isDirectory: true)
                .appendingPathComponent("\(expected.id.rawValue).json")
            try PortableChatPersistence().encodeMessage(impostor).write(to: messageURL)

            let recovery = await owner.recoverPublishedInvocation(
                fixture.publication
            )
            XCTAssertEqual(recovery, .notPublished)
            _ = await owner.abortInstalledNewSend(fixture.install.invocation)
        }
    }

    func testRelaunchPreservesPendingAndInvocationForAlteredPublishedMessage() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let publicationFault = OneShot()
            let reconciliationFault = OneShot()
            let release = InvocationLivenessReleaseObservation()
            do {
                let crashed = PortableInvocationStore(
                    persistence: PortableChatPersistence(
                        fault: { point in
                            if point == .afterPublicationManifestInstall,
                               publicationFault.take()
                            {
                                throw PortableChatPersistenceError.injectedFault(point)
                            }
                            if point == .beforePublicationReconciliationRead,
                               reconciliationFault.take()
                            {
                                throw PortableChatPersistenceError.injectedFault(point)
                            }
                        },
                        invocationLivenessReleased: release.didRelease
                    ),
                    workspace: fixture.workspace
                )
                guard case .acquired = await crashed.acquirePendingInvocation(
                    fixture.install.authority.request
                ) else { return XCTFail("Pending authority was not acquired") }
                guard case .installed = await crashed.installInvocation(fixture.install) else {
                    return XCTFail("Invocation was not installed")
                }
                let publication = await crashed.publish(fixture.publication)
                XCTAssertEqual(publication, .failed)
            }
            await release.waitUntilReleased()

            let expected = fixture.publication.coachMessage
            let impostor = try ChatMessage(
                id: expected.id,
                responsePositionID: expected.responsePositionID,
                content: .coach(markdown: "Altered immutable response."),
                coachProfile: expected.coachProfile,
                createdAt: expected.createdAt
            )
            let chatRoot = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(fixture.locked.chat.id.rawValue, isDirectory: true)
            try PortableChatPersistence().encodeMessage(impostor).write(
                to: chatRoot
                    .appendingPathComponent("messages", isDirectory: true)
                    .appendingPathComponent("\(expected.id.rawValue).json")
            )

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let relaunched = PortableChatStore(workspace: relaunchedWorkspace)

            let load = await relaunched.load(fixture.locked.chat.id, in: fixture.scope)
            XCTAssertEqual(load, .failed)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: chatRoot.appendingPathComponent("pending-user-turn.json").path
                )
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent("invocations", isDirectory: true)
                        .appendingPathComponent(
                            fixture.install.invocation.id.rawValue,
                            isDirectory: true
                        ).path
                )
            )
        }
    }

    func testRelaunchPreservesPendingAndInvocationForAlteredCoachProvenance() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.livenessReleased)

            let expected = fixture.publication.coachMessage
            let impostor = try ChatMessage(
                id: expected.id,
                responsePositionID: expected.responsePositionID,
                content: expected.content,
                coachProfile: CoachProfileProvenance(
                    revisionID: expected.coachProfile?.revisionID,
                    statementGeneration: 10
                ),
                createdAt: expected.createdAt
            )
            let chatRoot = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(fixture.locked.chat.id.rawValue, isDirectory: true)
            try PortableChatPersistence().encodeMessage(impostor).write(
                to: chatRoot
                    .appendingPathComponent("messages", isDirectory: true)
                    .appendingPathComponent("\(expected.id.rawValue).json")
            )

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let relaunched = PortableChatStore(workspace: relaunchedWorkspace)
            let load = await relaunched.load(fixture.locked.chat.id, in: fixture.scope)

            XCTAssertEqual(load, .failed)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: chatRoot.appendingPathComponent("pending-user-turn.json").path
                )
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent("invocations", isDirectory: true)
                        .appendingPathComponent(
                            fixture.install.invocation.id.rawValue,
                            isDirectory: true
                        ).path
                )
            )
        }
    }

    func testRelaunchRecognizesExactCommittedPublicationAndFinishesCleanup() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.livenessReleased)

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let diagnostics = RecordingPortableInvocationRetryDiagnostics()
            let relaunched = PortableChatStore(
                persistence: PortableChatPersistence(
                    retryDiagnostics: diagnostics,
                    retryDiagnosticNow: {
                        try! UTCInstant("2026-08-30T12:05:00.000Z")
                    }
                ),
                workspace: relaunchedWorkspace
            )

            let load = await relaunched.load(fixture.locked.chat.id, in: fixture.scope)
            XCTAssertEqual(load, .loaded(fixture.publication.replacement))
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent("chats", isDirectory: true)
                        .appendingPathComponent(
                            fixture.locked.chat.id.rawValue,
                            isDirectory: true
                        )
                        .appendingPathComponent("pending-user-turn.json").path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent("invocations", isDirectory: true)
                        .appendingPathComponent(
                            fixture.install.invocation.id.rawValue,
                            isDirectory: true
                        ).path
                )
            )
            XCTAssertEqual(
                diagnostics.recordedEvents(),
                [],
                "exact publication recovery must not manufacture a Retry event"
            )
        }
    }

    func testRelaunchRecognizesCommittedV3RetryPublicationForTypedFailures() async throws {
        let priorFailures: [PendingUserTurnFailure] = [
            .coachContextCannotFit,
            .coachResponseInterrupted,
            .coachProviderError,
            .coachResponseInvalid,
        ]
        try await withTemporaryParent { parent in
            for (index, priorFailure) in priorFailures.enumerated() {
                let caseParent = parent.appendingPathComponent(
                    "published-retry-\(index)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: caseParent,
                    withIntermediateDirectories: false
                )
                let fixture = try await makeInvocationStoreFixture(
                    in: caseParent,
                    libraryID: "lib-20260830T12002\(index)000Z-2ABC",
                    pendingFailure: priorFailure
                )
                let crash = await leaveCommittedPublicationForRelaunch(fixture)
                XCTAssertEqual(crash.outcome, .failed)
                XCTAssertTrue(crash.livenessReleased)

                let relaunchedWorkspace = PortableLibraryWorkspace(
                    locations: QueueLocations(existing: [fixture.root]),
                    bookmarks: SyntheticBookmarks(),
                    access: RecordingAccessGrantor(),
                    locatorStore: MemoryLocatorStore(),
                    revealer: RecordingRevealer()
                )
                _ = await relaunchedWorkspace.chooseLibrary()
                let relaunched = PortableChatStore(workspace: relaunchedWorkspace)
                let load = await relaunched.load(
                    fixture.locked.chat.id,
                    in: fixture.scope
                )
                XCTAssertEqual(
                    load,
                    .loaded(fixture.publication.replacement),
                    "prior failure: \(priorFailure)"
                )
            }
        }
    }

    func testRelaunchRecognizesLegacyV2CommittedPublicationWithoutResumingWork() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                pendingFailure: .coachResponseInterrupted
            )
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.livenessReleased)

            let invocationRoot = fixture.root
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(
                    fixture.install.invocation.id.rawValue,
                    isDirectory: true
                )
            let invocationURL = invocationRoot.appendingPathComponent("invocation.json")
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: invocationURL))
                    as? [String: Any]
            )
            object["schemaVersion"] = 2
            let attempts = try XCTUnwrap(object["attempts"] as? [[String: Any]])
            let attempt = try XCTUnwrap(attempts.first)
            object["attemptId"] = attempt["attemptId"]
            object["providerIdempotencyValue"] = try XCTUnwrap(
                fixture.install.invocation.attempt.transportAuthority
            ).providerIdempotencyValue.rawValue
            object.removeValue(forKey: "attempts")
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ).write(to: invocationURL, options: .atomic)

            // Reproduce the prior binary's exact v2 Retry boundary: the
            // committed proof hashes an interrupted Pending rather than the v3
            // failure-free processing projection.
            let pendingURL = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(
                    fixture.locked.chat.id.rawValue,
                    isDirectory: true
                )
                .appendingPathComponent("pending-user-turn.json")
            var pendingObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: pendingURL))
                    as? [String: Any]
            )
            pendingObject["schemaVersion"] = 2
            pendingObject["failure"] = PendingUserTurnFailure
                .coachResponseInterrupted.rawValue
            let legacyPending = try JSONSerialization.data(
                withJSONObject: pendingObject,
                options: [.sortedKeys]
            )
            try legacyPending.write(to: pendingURL, options: .atomic)

            let proofURL = invocationRoot.appendingPathComponent(
                "publication-proof.json"
            )
            var proofObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: proofURL))
                    as? [String: Any]
            )
            proofObject["pendingUserTurnSha256"] = SHA256
                .hash(data: legacyPending)
                .map { String(format: "%02x", $0) }
                .joined()
            try JSONSerialization.data(
                withJSONObject: proofObject,
                options: [.sortedKeys]
            ).write(to: proofURL, options: .atomic)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: proofURL.path
                )
            )

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let relaunched = PortableChatStore(workspace: relaunchedWorkspace)
            let load = await relaunched.load(
                fixture.locked.chat.id,
                in: fixture.scope
            )

            XCTAssertEqual(
                load,
                .loaded(fixture.publication.replacement)
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: invocationRoot.path))
        }
    }

    func testRelaunchPreservesPostSwitchInvocationWithoutPublicationProof() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.livenessReleased)

            let invocationRoot = fixture.root
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(
                    fixture.install.invocation.id.rawValue,
                    isDirectory: true
                )
            try FileManager.default.removeItem(
                at: invocationRoot.appendingPathComponent("publication-proof.json")
            )
            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let relaunched = PortableChatStore(workspace: relaunchedWorkspace)

            let load = await relaunched.load(fixture.locked.chat.id, in: fixture.scope)
            XCTAssertEqual(load, .failed)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent("chats", isDirectory: true)
                        .appendingPathComponent(
                            fixture.locked.chat.id.rawValue,
                            isDirectory: true
                        )
                        .appendingPathComponent("pending-user-turn.json").path
                )
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: invocationRoot.path))
        }
    }

    func testInvocationCommonIdentityFreezesOnlyNewerOrCorruptBodyTargetInCatalog()
        async throws
    {
        try await withTemporaryParent { parent in
            for (index, mode) in ["newer", "corrupt"].enumerated() {
                let caseParent = parent.appendingPathComponent(
                    "invocation-body-\(mode)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: caseParent,
                    withIntermediateDirectories: false
                )
                let fixture = try await makeInvocationStoreFixture(
                    in: caseParent,
                    libraryID: "lib-20260830T12100\(index)000Z-2ABC",
                    includeCompetingPending: true
                )
                let persistence = PortableChatPersistence()
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: persistence.encodeInvocation(fixture.install.invocation)
                    ) as? [String: Any]
                )
                if mode == "newer" {
                    object["schemaVersion"] = CoachInvocation.schemaVersion + 1
                    object["futureAttemptHistory"] = ["opaque": true]
                } else {
                    object["attempts"] = "permanently-corrupt-supported-body"
                }
                let invocationRoot = fixture.root
                    .appendingPathComponent("invocations", isDirectory: true)
                    .appendingPathComponent(
                        fixture.install.invocation.id.rawValue,
                        isDirectory: true
                    )
                try FileManager.default.createDirectory(
                    at: invocationRoot,
                    withIntermediateDirectories: false
                )
                try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]
                ).write(to: invocationRoot.appendingPathComponent("invocation.json"))

                let relaunchedWorkspace = PortableLibraryWorkspace(
                    locations: QueueLocations(existing: [fixture.root]),
                    bookmarks: SyntheticBookmarks(),
                    access: RecordingAccessGrantor(),
                    locatorStore: MemoryLocatorStore(),
                    revealer: RecordingRevealer()
                )
                _ = await relaunchedWorkspace.chooseLibrary()
                let store = PortableChatStore(workspace: relaunchedWorkspace)
                guard case let .loaded(entries) = await store.loadCatalog(
                    in: fixture.scope
                ) else { return XCTFail("\(mode) sibling blocked the catalog") }

                XCTAssertEqual(entries.count, 2, mode)
                XCTAssertTrue(entries.contains(.frozen(FrozenChatSnapshot(
                    chatID: fixture.locked.chat.id,
                    reason: mode == "newer" ? .newerSchema : .corrupt
                ))), mode)
                XCTAssertTrue(entries.contains { entry in
                    guard case let .available(aggregate) = entry else { return false }
                    return aggregate.chat.id == fixture.competingAuthority.request.chatID
                }, mode)
            }
        }
    }

    func testInvocationDuplicateUnrelatedBodyKeyFreezesOnlyItsBoundChat()
        async throws
    {
        try await withTemporaryParent { parent in
            for (index, mode) in ["newer", "supported"].enumerated() {
                let caseParent = parent.appendingPathComponent(
                    "duplicate-body-\(mode)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: caseParent,
                    withIntermediateDirectories: false
                )
                let fixture = try await makeInvocationStoreFixture(
                    in: caseParent,
                    libraryID: "lib-20260830T12160\(index)000Z-2ABC",
                    includeCompetingPending: true
                )
                let invocation = fixture.install.invocation
                let data: Data
                if mode == "newer" {
                    data = Data(
                        """
                        {"schemaVersion":4,"invocationId":"\(invocation.id.rawValue)","libraryId":"\(fixture.scope.libraryID.rawValue)","chatId":"\(fixture.locked.chat.id.rawValue)","futureBody":"first","futureBody":"second"}
                        """.utf8
                    )
                } else {
                    let canonical = try XCTUnwrap(
                        String(
                            data: PortableChatPersistence().encodeInvocation(invocation),
                            encoding: .utf8
                        )
                    )
                    let property = "\"admittedAt\":\"\(invocation.admittedAt.rawValue)\""
                    let duplicated = canonical.replacingOccurrences(
                        of: property,
                        with: "\(property),\(property)"
                    )
                    XCTAssertNotEqual(duplicated, canonical)
                    data = Data(duplicated.utf8)
                }
                let invocationRoot = fixture.root
                    .appendingPathComponent("invocations", isDirectory: true)
                    .appendingPathComponent(invocation.id.rawValue, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: invocationRoot,
                    withIntermediateDirectories: false
                )
                let invocationURL = invocationRoot.appendingPathComponent(
                    "invocation.json"
                )
                try data.write(to: invocationURL)

                let store = PortableChatStore(workspace: fixture.workspace)
                guard case let .loaded(entries) = await store.loadCatalog(
                    in: fixture.scope
                ) else { return XCTFail("duplicate \(mode) body blocked catalog routing") }
                XCTAssertTrue(entries.contains(.frozen(FrozenChatSnapshot(
                    chatID: fixture.locked.chat.id,
                    reason: mode == "newer" ? .newerSchema : .corrupt
                ))), mode)
                XCTAssertTrue(entries.contains { entry in
                    guard case let .available(aggregate) = entry else { return false }
                    return aggregate.chat.id == fixture.competingAuthority.request.chatID
                }, mode)
                XCTAssertEqual(try Data(contentsOf: invocationURL), data, mode)
            }
        }
    }

    func testInvocationDuplicateNestedSupportedBodyKeyFreezesOnlyItsBoundChat()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let invocation = fixture.install.invocation
            let canonical = try XCTUnwrap(
                String(
                    data: PortableChatPersistence().encodeInvocation(invocation),
                    encoding: .utf8
                )
            )
            let property = "\"attemptId\":\"" + invocation.attemptID.rawValue + "\""
            let duplicated = canonical.replacingOccurrences(
                of: property,
                with: "\(property),\(property)"
            )
            XCTAssertNotEqual(duplicated, canonical)
            let data = Data(duplicated.utf8)
            let invocationRoot = fixture.root
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(invocation.id.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(
                at: invocationRoot,
                withIntermediateDirectories: false
            )
            let invocationURL = invocationRoot.appendingPathComponent(
                "invocation.json"
            )
            try data.write(to: invocationURL)

            let store = PortableChatStore(workspace: fixture.workspace)
            guard case let .loaded(entries) = await store.loadCatalog(
                in: fixture.scope
            ) else { return XCTFail("nested duplicate blocked catalog routing") }
            XCTAssertTrue(entries.contains(.frozen(FrozenChatSnapshot(
                chatID: fixture.locked.chat.id,
                reason: .corrupt
            ))))
            XCTAssertTrue(entries.contains { entry in
                guard case let .available(aggregate) = entry else { return false }
                return aggregate.chat.id == fixture.competingAuthority.request.chatID
            })
            XCTAssertEqual(try Data(contentsOf: invocationURL), data)
        }
    }

    func testInvocationCommonIdentityFailuresRemainLibraryWide() async throws {
        let cases = [
            "missing-chat",
            "malformed-chat",
            "mismatched-invocation",
            "mismatched-library",
            "malformed-schema",
            "duplicate-common-key",
            "non-object-root",
        ]
        try await withTemporaryParent { parent in
            for (index, identityCase) in cases.enumerated() {
                let caseParent = parent.appendingPathComponent(
                    "common-identity-\(identityCase)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: caseParent,
                    withIntermediateDirectories: false
                )
                let fixture = try await makeInvocationStoreFixture(
                    in: caseParent,
                    libraryID: "lib-20260830T12130\(index)000Z-2ABC"
                )
                let invocationID = fixture.install.invocation.id
                let common: [String: Any] = [
                    "schemaVersion": CoachInvocation.schemaVersion + 1,
                    "invocationId": invocationID.rawValue,
                    "libraryId": fixture.scope.libraryID.rawValue,
                    "chatId": fixture.locked.chat.id.rawValue,
                ]
                let data: Data
                switch identityCase {
                case "missing-chat":
                    var object = common
                    object.removeValue(forKey: "chatId")
                    data = try JSONSerialization.data(withJSONObject: object)
                case "malformed-chat":
                    var object = common
                    object["chatId"] = 7
                    data = try JSONSerialization.data(withJSONObject: object)
                case "mismatched-invocation":
                    var object = common
                    object["invocationId"] = "inv-20260830T121309000Z-3DEF"
                    data = try JSONSerialization.data(withJSONObject: object)
                case "mismatched-library":
                    var object = common
                    object["libraryId"] = "lib-20260830T121309000Z-4GHJ"
                    data = try JSONSerialization.data(withJSONObject: object)
                case "malformed-schema":
                    var object = common
                    object["schemaVersion"] = "4"
                    data = try JSONSerialization.data(withJSONObject: object)
                case "duplicate-common-key":
                    data = Data(
                        """
                        {"schemaVersion":4,"invocationId":"\(invocationID.rawValue)","libraryId":"\(fixture.scope.libraryID.rawValue)","chatId":"\(fixture.locked.chat.id.rawValue)","chatId":"\(fixture.locked.chat.id.rawValue)"}
                        """.utf8
                    )
                case "non-object-root":
                    data = Data("[]".utf8)
                default:
                    return XCTFail("unknown common identity case")
                }
                let invocationRoot = fixture.root
                    .appendingPathComponent("invocations", isDirectory: true)
                    .appendingPathComponent(invocationID.rawValue, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: invocationRoot,
                    withIntermediateDirectories: false
                )
                let invocationURL = invocationRoot.appendingPathComponent(
                    "invocation.json"
                )
                try data.write(to: invocationURL)

                let store = PortableChatStore(workspace: fixture.workspace)
                let catalog = await store.loadCatalog(in: fixture.scope)
                XCTAssertEqual(
                    catalog,
                    .failed,
                    identityCase
                )
                XCTAssertEqual(try Data(contentsOf: invocationURL), data, identityCase)
            }
        }
    }

    func testInvocationCommonIdentityTransientReadFailureRemainsLibraryWide()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            try writeFutureInvocation(
                in: fixture,
                chatID: fixture.competingAuthority.request.chatID,
                attemptID: "atm-20260830T121409000Z-0ABC",
                userMessageID: "msg-20260830T121409000Z-1BCD",
                coachMessageID: "msg-20260830T121409000Z-2CDE",
                freshDraftID: "drf-20260830T121409000Z-3DEF"
            )
            let injected = OneShot()
            let persistence = PortableChatPersistence { point in
                if point == .beforeInvocationIdentityRead, injected.take() {
                    throw PortableChatPersistenceError.ioFailure
                }
            }
            let store = PortableChatStore(
                persistence: persistence,
                workspace: fixture.workspace
            )
            let catalog = await store.loadCatalog(in: fixture.scope)

            XCTAssertEqual(catalog, .failed)
            XCTAssertFalse(injected.take(), "identity read fault was not reached")
        }
    }

    func testCorruptPublicationProofFreezesOnlyItsTargetChatInCatalog() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.livenessReleased)

            let invocationRoot = fixture.root
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(
                    fixture.install.invocation.id.rawValue,
                    isDirectory: true
                )
            let proofURL = invocationRoot.appendingPathComponent("publication-proof.json")
            var proof = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: proofURL)
                ) as? [String: Any]
            )
            proof["schemaVersion"] = 2
            try JSONSerialization.data(
                withJSONObject: proof,
                options: [.sortedKeys]
            ).write(to: proofURL)
            let invocationURL = invocationRoot.appendingPathComponent("invocation.json")
            let pendingURL = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(
                    fixture.locked.chat.id.rawValue,
                    isDirectory: true
                )
                .appendingPathComponent("pending-user-turn.json")
            let proofBytes = try Data(contentsOf: proofURL)
            let invocationBytes = try Data(contentsOf: invocationURL)
            let pendingBytes = try Data(contentsOf: pendingURL)

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let store = PortableChatStore(workspace: relaunchedWorkspace)

            guard case let .loaded(entries) = await store.loadCatalog(
                in: fixture.scope
            ) else { return XCTFail("corrupt target blocked the production catalog") }

            XCTAssertEqual(entries.count, 2)
            XCTAssertTrue(entries.contains(.frozen(
                FrozenChatSnapshot(chatID: fixture.locked.chat.id, reason: .corrupt)
            )))
            XCTAssertTrue(entries.contains { entry in
                guard case let .available(aggregate) = entry else { return false }
                return aggregate.chat.id == fixture.competingAuthority.request.chatID
            })
            XCTAssertEqual(try Data(contentsOf: proofURL), proofBytes)
            XCTAssertEqual(try Data(contentsOf: invocationURL), invocationBytes)
            XCTAssertEqual(try Data(contentsOf: pendingURL), pendingBytes)
        }
    }

    func testCorruptPublicationProofDoesNotBlockHealthySiblingInvocationStart() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.livenessReleased)

            let invocationRoot = fixture.root
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(
                    fixture.install.invocation.id.rawValue,
                    isDirectory: true
                )
            let proofURL = invocationRoot.appendingPathComponent("publication-proof.json")
            var proof = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: proofURL)
                ) as? [String: Any]
            )
            proof["schemaVersion"] = 2
            try JSONSerialization.data(
                withJSONObject: proof,
                options: [.sortedKeys]
            ).write(to: proofURL)

            let targetChatRoot = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(
                    fixture.locked.chat.id.rawValue,
                    isDirectory: true
                )
            let evidenceURLs = [
                invocationRoot.appendingPathComponent("invocation.json"),
                proofURL,
                targetChatRoot.appendingPathComponent("chat.json"),
                targetChatRoot.appendingPathComponent("pending-user-turn.json"),
                targetChatRoot.appendingPathComponent("memory", isDirectory: true)
                    .appendingPathComponent(
                        "\(fixture.locked.memory.memoryID.rawValue).json"
                    ),
                targetChatRoot.appendingPathComponent("messages", isDirectory: true)
                    .appendingPathComponent(
                        "\(fixture.publication.userMessage.id.rawValue).json"
                    ),
                targetChatRoot.appendingPathComponent("messages", isDirectory: true)
                    .appendingPathComponent(
                        "\(fixture.publication.coachMessage.id.rawValue).json"
                    ),
            ]
            let evidenceBytes = try evidenceURLs.map { try Data(contentsOf: $0) }
            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let store = PortableInvocationStore(workspace: relaunchedWorkspace)

            let acquired = await store.acquirePendingInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(acquired, .acquired(fixture.competingAuthority))
            let identity = InvocationLaunchIdentity(
                invocationID: try CoachInvocationID(
                    "inv-20260830T120012000Z-7STV"
                ),
                attemptID: try CoachProviderAttemptID(
                    "atm-20260830T120012000Z-8WXY"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "synthetic-competing-9YZ0"
                ),
                userMessageID: try ChatMessageID(
                    "msg-20260830T120013000Z-0ABC"
                ),
                coachMessageID: try ChatMessageID(
                    "msg-20260830T120013000Z-1BCD"
                ),
                freshDraftID: try ChatDraftID(
                    "drf-20260830T120013000Z-2CDE"
                )
            )
            let identityAvailability = await store.checkLaunchIdentity(
                identity,
                for: fixture.competingAuthority
            )
            XCTAssertEqual(identityAvailability, .available)
            let install = try InstallCoachInvocationMutation(
                authority: fixture.competingAuthority,
                identity: identity,
                preparedProfile: try XCTUnwrap(
                    fixture.install.invocation.preparedProfile
                ),
                admittedAt: UTCInstant("2026-08-30T12:00:12.000Z")
            )
            let installation = await store.installInvocation(install)
            XCTAssertEqual(installation, .installed(install.invocation))

            XCTAssertTrue(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
            let reader = PortableChatStore(workspace: relaunchedWorkspace)
            let frozenTarget = await reader.load(
                fixture.locked.chat.id,
                in: fixture.scope
            )
            XCTAssertEqual(
                frozenTarget,
                .frozen(FrozenChatSnapshot(
                    chatID: fixture.locked.chat.id,
                    reason: .corrupt
                ))
            )
            for (url, expected) in zip(evidenceURLs, evidenceBytes) {
                XCTAssertEqual(try Data(contentsOf: url), expected, url.path)
            }
        }
    }

    func testMixedFrozenInvocationRootsCoalesceToOneCorruptChatInCatalog() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.livenessReleased)

            let invocationsRoot = fixture.root.appendingPathComponent(
                "invocations",
                isDirectory: true
            )
            let originalRoot = invocationsRoot.appendingPathComponent(
                fixture.install.invocation.id.rawValue,
                isDirectory: true
            )
            let proofURL = originalRoot.appendingPathComponent("publication-proof.json")
            var proof = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: proofURL)
                ) as? [String: Any]
            )
            proof["schemaVersion"] = 2
            let corruptProof = try JSONSerialization.data(
                withJSONObject: proof,
                options: [.sortedKeys]
            )
            try corruptProof.write(to: proofURL)

            let alternateIdentity = InvocationLaunchIdentity(
                invocationID: try CoachInvocationID(
                    "inv-20260830T120001000Z-9YZ0"
                ),
                attemptID: try CoachProviderAttemptID(
                    "atm-20260830T120002000Z-0ABC"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "synthetic-duplicate-1BCD"
                ),
                userMessageID: try ChatMessageID(
                    "msg-20260830T120003000Z-2CDE"
                ),
                coachMessageID: try ChatMessageID(
                    "msg-20260830T120003000Z-3DEF"
                ),
                freshDraftID: try ChatDraftID(
                    "drf-20260830T120003000Z-4GHJ"
                )
            )
            let alternate = try InstallCoachInvocationMutation(
                authority: fixture.install.authority,
                identity: alternateIdentity,
                preparedProfile: try XCTUnwrap(
                    fixture.install.invocation.preparedProfile
                ),
                admittedAt: UTCInstant("2026-08-30T12:00:02.000Z")
            ).invocation
            let alternateRoot = invocationsRoot.appendingPathComponent(
                alternate.id.rawValue,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: alternateRoot,
                withIntermediateDirectories: false
            )
            var alternateObject = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: PortableChatPersistence().encodeInvocation(alternate)
                ) as? [String: Any]
            )
            alternateObject["schemaVersion"] = CoachInvocation.schemaVersion + 1
            let newerBody = try JSONSerialization.data(
                withJSONObject: alternateObject,
                options: [.sortedKeys]
            )
            let alternateInvocationURL = alternateRoot.appendingPathComponent(
                "invocation.json"
            )
            try newerBody.write(to: alternateInvocationURL)

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let store = PortableChatStore(workspace: relaunchedWorkspace)

            guard case let .loaded(catalog) = await store.loadCatalog(
                in: fixture.scope
            ) else { return XCTFail("repeated frozen roots blocked the catalog") }
            XCTAssertEqual(catalog.count, 2)
            XCTAssertTrue(catalog.contains(.frozen(FrozenChatSnapshot(
                chatID: fixture.locked.chat.id,
                reason: .corrupt
            ))))
            XCTAssertTrue(catalog.contains { entry in
                guard case let .available(aggregate) = entry else { return false }
                return aggregate.chat.id == fixture.competingAuthority.request.chatID
            })
            XCTAssertEqual(try Data(contentsOf: proofURL), corruptProof)
            XCTAssertEqual(try Data(contentsOf: alternateInvocationURL), newerBody)
        }
    }

    func testFrozenInvocationRootPreservesAvailableSameChatEvidenceDuringRecovery()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.livenessReleased)

            let invocationsRoot = fixture.root.appendingPathComponent(
                "invocations",
                isDirectory: true
            )
            let originalRoot = invocationsRoot.appendingPathComponent(
                fixture.install.invocation.id.rawValue,
                isDirectory: true
            )
            let proofURL = originalRoot.appendingPathComponent(
                "publication-proof.json"
            )
            let proofBytes = try Data(contentsOf: proofURL)
            let alternateIdentity = InvocationLaunchIdentity(
                invocationID: try CoachInvocationID(
                    "inv-20260830T120002000Z-9YZ0"
                ),
                attemptID: try CoachProviderAttemptID(
                    "atm-20260830T120002000Z-0ABC"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "synthetic-overlap-1BCD"
                ),
                userMessageID: try ChatMessageID(
                    "msg-20260830T120003000Z-2CDE"
                ),
                coachMessageID: try ChatMessageID(
                    "msg-20260830T120003000Z-3DEF"
                ),
                freshDraftID: try ChatDraftID(
                    "drf-20260830T120003000Z-4GHJ"
                )
            )
            let alternate = try InstallCoachInvocationMutation(
                authority: fixture.install.authority,
                identity: alternateIdentity,
                preparedProfile: try XCTUnwrap(
                    fixture.install.invocation.preparedProfile
                ),
                admittedAt: UTCInstant("2026-08-30T12:00:02.000Z")
            ).invocation
            let alternateRoot = invocationsRoot.appendingPathComponent(
                alternate.id.rawValue,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: alternateRoot,
                withIntermediateDirectories: false
            )
            try PortableChatPersistence().encodeInvocation(alternate).write(
                to: alternateRoot.appendingPathComponent("invocation.json")
            )
            try proofBytes.write(
                to: alternateRoot.appendingPathComponent(
                    "publication-proof.json"
                )
            )
            let proofPartialURL = originalRoot.appendingPathComponent(
                ".publication-proof.json.33333333-3333-3333-3333-333333333333.partial"
            )
            let invocationPartialURL = originalRoot.appendingPathComponent(
                ".invocation.json.44444444-4444-4444-4444-444444444444.partial"
            )
            try proofBytes.write(to: proofPartialURL)
            try Data(contentsOf: originalRoot.appendingPathComponent("invocation.json"))
                .write(to: invocationPartialURL)

            let targetPendingURL = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(
                    fixture.locked.chat.id.rawValue,
                    isDirectory: true
                )
                .appendingPathComponent("pending-user-turn.json")
            let evidenceURLs = [
                originalRoot.appendingPathComponent("invocation.json"),
                proofURL,
                proofPartialURL,
                invocationPartialURL,
                alternateRoot.appendingPathComponent("invocation.json"),
                alternateRoot.appendingPathComponent("publication-proof.json"),
                targetPendingURL,
            ]
            let evidenceBytes = try evidenceURLs.map { try Data(contentsOf: $0) }
            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let invocationStore = PortableInvocationStore(
                workspace: relaunchedWorkspace
            )

            let acquired = await invocationStore.acquirePendingInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(acquired, .acquired(fixture.competingAuthority))
            XCTAssertFalse(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
            for (url, expected) in zip(evidenceURLs, evidenceBytes) {
                XCTAssertEqual(try Data(contentsOf: url), expected, url.path)
            }
            await invocationStore.cancelInvocationReservation(
                fixture.competingAuthority.request
            )

            let chatStore = PortableChatStore(workspace: relaunchedWorkspace)
            guard case let .loaded(catalog) = await chatStore.loadCatalog(
                in: fixture.scope
            ) else { return XCTFail("same-Chat frozen evidence blocked the catalog") }
            XCTAssertEqual(catalog.count, 2)
            XCTAssertTrue(catalog.contains(.frozen(FrozenChatSnapshot(
                chatID: fixture.locked.chat.id,
                reason: .corrupt
            ))))
            XCTAssertTrue(catalog.contains { entry in
                guard case let .available(aggregate) = entry else { return false }
                return aggregate.chat.id == fixture.competingAuthority.request.chatID
            })
        }
    }

    func testRelaunchPreservesPendingAndInvocationForDifferentPublishedMessageIDs() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.livenessReleased)

            let published = fixture.publication.replacement.chat
            let userID = try ChatMessageID("msg-20260830T120004000Z-3DEF")
            let coachID = try ChatMessageID("msg-20260830T120004000Z-4GHJ")
            let user = try ChatMessage(
                id: userID,
                responsePositionID: fixture.install.invocation.responsePositionID,
                content: fixture.publication.userMessage.content,
                createdAt: fixture.publication.userMessage.createdAt
            )
            let coach = try ChatMessage(
                id: coachID,
                responsePositionID: fixture.install.invocation.responsePositionID,
                content: fixture.publication.coachMessage.content,
                coachProfile: fixture.publication.coachMessage.coachProfile,
                createdAt: fixture.publication.coachMessage.createdAt
            )
            let impostor = try Chat(
                id: published.id,
                manifestRevision: published.manifestRevision,
                title: published.title,
                createdAt: published.createdAt,
                updatedAt: published.updatedAt,
                creation: published.creation,
                profileStatementGenerationAtCreation:
                    published.profileStatementGenerationAtCreation,
                attachments: published.attachments,
                draft: published.draft,
                messageIDs: Array(published.messageIDs.dropLast(2)) + [userID, coachID],
                currentMemoryID: published.currentMemoryID
            )
            let chatRoot = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(published.id.rawValue, isDirectory: true)
            let messages = chatRoot.appendingPathComponent("messages", isDirectory: true)
            try PortableChatPersistence().encodeMessage(user).write(
                to: messages.appendingPathComponent("\(userID.rawValue).json")
            )
            try PortableChatPersistence().encodeMessage(coach).write(
                to: messages.appendingPathComponent("\(coachID.rawValue).json")
            )
            try PortableChatPersistence().encodeChat(impostor).write(
                to: chatRoot.appendingPathComponent("chat.json")
            )

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let relaunched = PortableChatStore(workspace: relaunchedWorkspace)
            let load = await relaunched.load(published.id, in: fixture.scope)

            XCTAssertEqual(load, .failed)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: chatRoot.appendingPathComponent("pending-user-turn.json").path
                )
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent("invocations", isDirectory: true)
                        .appendingPathComponent(
                            fixture.install.invocation.id.rawValue,
                            isDirectory: true
                        ).path
                )
            )
        }
    }

    func testRelaunchPreservesPendingAndInvocationForUnrelatedTwoMessageTail() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.livenessReleased)

            let published = fixture.publication.replacement.chat
            let userID = try ChatMessageID("msg-20260830T120005000Z-5KMN")
            let coachID = try ChatMessageID("msg-20260830T120005000Z-6PQR")
            let user = try ChatMessage(
                id: userID,
                responsePositionID: fixture.install.invocation.responsePositionID,
                content: .user(text: "Unrelated later user message."),
                createdAt: try UTCInstant("2026-08-30T12:00:05.000Z")
            )
            let coach = try ChatMessage(
                id: coachID,
                responsePositionID: fixture.install.invocation.responsePositionID,
                content: .coach(markdown: "Unrelated later coach message."),
                coachProfile: fixture.install.invocation.preparedProfile,
                createdAt: try UTCInstant("2026-08-30T12:00:05.000Z")
            )
            let impostor = try Chat(
                id: published.id,
                manifestRevision: published.manifestRevision + 1,
                title: published.title,
                createdAt: published.createdAt,
                updatedAt: try UTCInstant("2026-08-30T12:00:05.000Z"),
                creation: published.creation,
                profileStatementGenerationAtCreation:
                    published.profileStatementGenerationAtCreation,
                attachments: published.attachments,
                draft: published.draft,
                messageIDs: published.messageIDs + [userID, coachID],
                currentMemoryID: published.currentMemoryID
            )
            let chatRoot = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(published.id.rawValue, isDirectory: true)
            let messages = chatRoot.appendingPathComponent("messages", isDirectory: true)
            try PortableChatPersistence().encodeMessage(user).write(
                to: messages.appendingPathComponent("\(userID.rawValue).json")
            )
            try PortableChatPersistence().encodeMessage(coach).write(
                to: messages.appendingPathComponent("\(coachID.rawValue).json")
            )
            try PortableChatPersistence().encodeChat(impostor).write(
                to: chatRoot.appendingPathComponent("chat.json")
            )

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let relaunched = PortableChatStore(workspace: relaunchedWorkspace)
            let load = await relaunched.load(published.id, in: fixture.scope)

            XCTAssertEqual(load, .failed)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: chatRoot.appendingPathComponent("pending-user-turn.json").path
                )
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent("invocations", isDirectory: true)
                        .appendingPathComponent(
                            fixture.install.invocation.id.rawValue,
                            isDirectory: true
                        ).path
                )
            )
        }
    }

    func testExactPublishedRecoveryRejectsFreshDraftChangeWithoutManifestRevision() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let publicationFault = OneShot()
            let reconciliationFault = OneShot()
            let owner = PortableInvocationStore(
                persistence: PortableChatPersistence { point in
                    if point == .afterPublicationManifestInstall,
                       publicationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                    if point == .beforePublicationReconciliationRead,
                       reconciliationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                },
                workspace: fixture.workspace
            )
            guard case .acquired = await owner.acquirePendingInvocation(
                fixture.install.authority.request
            ) else { return XCTFail("Pending authority was not acquired") }
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }
            let publish = await owner.publish(fixture.publication)
            XCTAssertEqual(publish, .failed)

            let published = fixture.publication.replacement.chat
            let unversionedDraft = try published.draft.edited(
                text: "This edit has no manifest lineage.",
                at: UTCInstant("2026-08-30T12:00:05.000Z")
            )
            let impostor = try Chat(
                id: published.id,
                manifestRevision: published.manifestRevision,
                title: published.title,
                createdAt: published.createdAt,
                updatedAt: unversionedDraft.updatedAt,
                creation: published.creation,
                profileStatementGenerationAtCreation:
                    published.profileStatementGenerationAtCreation,
                attachments: published.attachments,
                draft: unversionedDraft,
                messageIDs: published.messageIDs,
                currentMemoryID: published.currentMemoryID
            )
            let chatURL = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(fixture.locked.chat.id.rawValue, isDirectory: true)
                .appendingPathComponent("chat.json")
            try PortableChatPersistence().encodeChat(impostor).write(to: chatURL)

            let recovery = await owner.recoverPublishedInvocation(
                fixture.publication
            )
            XCTAssertEqual(recovery, .unavailable)
            _ = await owner.abortInstalledNewSend(fixture.install.invocation)
        }
    }

    func testExactPublishedRecoveryReacquiresAuthorityAfterAbortReleasedLease() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let publicationFault = OneShot()
            let firstReconciliationFault = OneShot()
            let secondReconciliationFault = OneShot()
            let owner = PortableInvocationStore(
                persistence: PortableChatPersistence { point in
                    if point == .afterPublicationManifestInstall,
                       publicationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                    if point == .beforePublicationReconciliationRead,
                       firstReconciliationFault.take()
                            || secondReconciliationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                },
                workspace: fixture.workspace
            )
            let editingWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await editingWorkspace.chooseLibrary()
            let editor = PortableChatStore(workspace: editingWorkspace)
            guard case .acquired = await owner.acquirePendingInvocation(
                fixture.install.authority.request
            ) else { return XCTFail("Pending authority was not acquired") }
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }
            let publish = await owner.publish(fixture.publication)
            XCTAssertEqual(publish, .failed)

            guard case let .loaded(published) = await editor.load(
                fixture.locked.chat.id,
                in: fixture.scope
            ) else { return XCTFail("Published Chat was not readable") }
            let rename = try RenameChatMutation(
                library: fixture.scope,
                base: published,
                title: ChatTitle("Later title"),
                updatedAt: UTCInstant("2026-08-30T12:00:04.000Z")
            )
            guard case let .committed(renamed) = await editor.rename(rename) else {
                return XCTFail("Later rename did not commit")
            }
            let laterDraft = try renamed.chat.draft.edited(
                text: "A later fresh Draft edit.",
                at: UTCInstant("2026-08-30T12:00:05.000Z")
            )
            guard case let .committed(evolved) = await editor.saveDraft(
                SaveChatDraftMutation(
                    library: fixture.scope,
                    chatID: renamed.chat.id,
                    replacement: laterDraft
                )
            ) else { return XCTFail("Later Draft edit did not commit") }

            let unavailable = await owner.recoverPublishedInvocation(
                fixture.publication
            )
            XCTAssertEqual(unavailable, .unavailable)
            let abort = await owner.abortInstalledNewSend(
                fixture.install.invocation
            )
            XCTAssertEqual(abort, .stale(evolved))

            let recovered = await owner.recoverPublishedInvocation(
                fixture.publication
            )
            XCTAssertEqual(recovered, .published(evolved))
        }
    }

    func testSameIDInvocationCannotConsumeAnotherInvocationLivenessAuthority() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(
                in: parent,
                includeCompetingPending: true
            )
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .acquired)
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }
            let alternateIdentity = InvocationLaunchIdentity(
                invocationID: fixture.install.invocation.id,
                attemptID: try CoachProviderAttemptID(
                    "atm-20260830T120002000Z-7STV"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "synthetic-attempt-7STV"
                ),
                userMessageID: try ChatMessageID(
                    "msg-20260830T120003000Z-8WXY"
                ),
                coachMessageID: try ChatMessageID(
                    "msg-20260830T120003000Z-9YZ0"
                ),
                freshDraftID: try ChatDraftID(
                    "drf-20260830T120003000Z-0ABC"
                )
            )
            let alternateInstall = try InstallCoachInvocationMutation(
                authority: fixture.install.authority,
                identity: alternateIdentity,
                preparedProfile: fixture.install.invocation.preparedProfile!,
                admittedAt: UTCInstant("2026-08-30T12:00:02.000Z")
            )
            let alternatePublication = try PublishCoachInvocationMutation(
                base: fixture.locked,
                invocation: alternateInstall.invocation,
                identity: alternateIdentity,
                coachMarkdown: "Unowned response.",
                completedAt: UTCInstant("2026-08-30T12:00:03.000Z")
            )

            let malformedAbort = await owner.abortInstalledNewSend(
                alternateInstall.invocation
            )
            let malformedPublication = await owner.publish(alternatePublication)
            XCTAssertEqual(malformedAbort, .failed)
            XCTAssertEqual(malformedPublication, .failed)
            let blocked = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(blocked, .blockedByActiveInvocation)
            XCTAssertTrue(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
        }
    }
    private func leavePrecommitPublicationForRelaunch(
        _ fixture: InvocationStoreFixture,
        at point: PortableChatFaultPoint
    ) async -> (
        outcome: InvocationPublicationOutcome,
        publicationFaultReached: Bool,
        reconciliationFaultReached: Bool,
        livenessReleased: Bool
    ) {
        let publicationFault = OneShot()
        let reconciliationFault = OneShot()
        let release = InvocationLivenessReleaseObservation()
        var outcome = InvocationPublicationOutcome.failed
        do {
            let crashed = PortableInvocationStore(
                persistence: PortableChatPersistence(
                    fault: { reached in
                        if reached == point, publicationFault.take() {
                            throw PortableChatPersistenceError.injectedFault(point)
                        }
                        if reached == .beforePublicationReconciliationRead,
                           reconciliationFault.take()
                        {
                            throw PortableChatPersistenceError.injectedFault(reached)
                        }
                    },
                    invocationLivenessReleased: release.didRelease
                ),
                workspace: fixture.workspace
            )
            guard case .acquired = await crashed.acquirePendingInvocation(
                fixture.install.authority.request
            ), case .installed = await crashed.installInvocation(fixture.install)
            else { return (.failed, false, false, false) }
            outcome = await crashed.publish(fixture.publication)
        }
        await release.waitUntilReleased()
        return (
            outcome,
            publicationFault.wasTaken,
            reconciliationFault.wasTaken,
            true
        )
    }

    private func leavePrecommitCASConflictForRelaunch(
        _ fixture: InvocationStoreFixture,
        rename: RenameChatMutation
    ) async -> (
        outcome: InvocationPublicationOutcome,
        conflictReached: Bool,
        livenessReleased: Bool
    ) {
        let conflict = OneShot()
        let release = InvocationLivenessReleaseObservation()
        var outcome = InvocationPublicationOutcome.failed
        do {
            let crashed = PortableInvocationStore(
                persistence: PortableChatPersistence(
                    fault: { reached in
                        guard reached == .afterPublicationManifestFileFlush,
                              conflict.take()
                        else { return }
                        let manifest = fixture.root
                            .appendingPathComponent("chats", isDirectory: true)
                            .appendingPathComponent(rename.chatID.rawValue, isDirectory: true)
                            .appendingPathComponent("chat.json")
                        try PortableChatPersistence()
                            .encodeChat(rename.replacement.chat)
                            .write(to: manifest, options: .atomic)
                    },
                    invocationLivenessReleased: release.didRelease
                ),
                workspace: fixture.workspace
            )
            guard case .acquired = await crashed.acquirePendingInvocation(
                fixture.install.authority.request
            ), case .installed = await crashed.installInvocation(fixture.install)
            else { return (.failed, false, false) }
            outcome = await crashed.publish(fixture.publication)
        }
        await release.waitUntilReleased()
        return (outcome, conflict.wasTaken, true)
    }

    private func assertPrecommitPublicationCrashArtifacts(
        _ fixture: InvocationStoreFixture,
        at point: PortableChatFaultPoint
    ) throws {
        let label = String(describing: point)
        let invocationRoot = fixture.root
            .appendingPathComponent("invocations", isDirectory: true)
            .appendingPathComponent(
                fixture.install.invocation.id.rawValue,
                isDirectory: true
            )
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: invocationRoot.path)),
            ["invocation.json", "publication-proof.json"],
            label
        )

        let chatRoot = fixture.root
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent(fixture.locked.chat.id.rawValue, isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: chatRoot.appendingPathComponent("pending-user-turn.json").path
            ),
            label
        )
        let messagesRoot = chatRoot.appendingPathComponent(
            "messages",
            isDirectory: true
        )
        let expectedMessages: Set<String>
        switch point {
        case .afterPublicationProofInstall,
             .afterPublicationProofDirectoryFlush:
            expectedMessages = []
        case .afterUserMessageInstall:
            expectedMessages = [
                "\(fixture.publication.userMessage.id.rawValue).json"
            ]
        case .afterCoachMessageInstall,
             .afterPublicationManifestFileFlush:
            expectedMessages = [
                "\(fixture.publication.userMessage.id.rawValue).json",
                "\(fixture.publication.coachMessage.id.rawValue).json",
            ]
        default:
            XCTFail("unsupported precommit fault point: \(point)")
            return
        }
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: messagesRoot.path)),
            expectedMessages,
            label
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: chatRoot.path)
                .contains(where: {
                    $0.hasPrefix(".chat.json.") && $0.hasSuffix(".partial")
                }),
            label
        )
    }

    private func assertRetryablePrecommitRecovery(
        _ reopened: ChatAggregate,
        fixture: InvocationStoreFixture,
        workspace: PortableLibraryWorkspace,
        label: String
    ) async throws {
        XCTAssertEqual(
            reopened.pendingUserTurn,
            fixture.locked.pendingUserTurn?.replacingFailure(
                .coachResponseInterrupted
            ),
            label
        )
        XCTAssertEqual(
            reopened.pendingUserTurn?.id,
            fixture.locked.pendingUserTurn?.id,
            label
        )
        XCTAssertEqual(reopened.chat.draft, fixture.locked.chat.draft, label)
        XCTAssertEqual(
            reopened.chat.draft.draftID,
            fixture.locked.chat.draft.draftID,
            label
        )
        XCTAssertEqual(reopened.chat.messageIDs, [], label)

        let invocationRoot = fixture.root
            .appendingPathComponent("invocations", isDirectory: true)
            .appendingPathComponent(
                fixture.install.invocation.id.rawValue,
                isDirectory: true
            )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: invocationRoot.path),
            label
        )
        let messagesRoot = fixture.root
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent(reopened.chat.id.rawValue, isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: messagesRoot.path),
            [],
            label
        )
        let chatRoot = messagesRoot.deletingLastPathComponent()
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: chatRoot.path)
                .contains(where: {
                    $0.hasPrefix(".chat.json.") && $0.hasSuffix(".partial")
                }),
            label
        )

        let retry = PortableInvocationStore(workspace: workspace)
        guard case let .acquired(authority) = await retry.acquirePendingInvocation(
            fixture.install.authority.request
        ) else {
            return XCTFail("recovered Pending was not retryable: \(label)")
        }
        XCTAssertEqual(authority.aggregate, reopened, label)
        XCTAssertEqual(authority.pendingUserTurn, reopened.pendingUserTurn, label)
        await retry.cancelInvocationReservation(authority.request)
    }

    private struct InvocationStoreFixture {
        let root: URL
        let scope: LibraryScope
        let workspace: PortableLibraryWorkspace
        let locked: ChatAggregate
        let install: InstallCoachInvocationMutation
        let publication: PublishCoachInvocationMutation
        private let optedInCompetingAuthority: InvocationPendingAuthority?

        init(
            root: URL,
            scope: LibraryScope,
            workspace: PortableLibraryWorkspace,
            locked: ChatAggregate,
            install: InstallCoachInvocationMutation,
            publication: PublishCoachInvocationMutation,
            competingAuthority: InvocationPendingAuthority?
        ) {
            self.root = root
            self.scope = scope
            self.workspace = workspace
            self.locked = locked
            self.install = install
            self.publication = publication
            optedInCompetingAuthority = competingAuthority
        }

        var competingAuthority: InvocationPendingAuthority {
            guard let optedInCompetingAuthority else {
                preconditionFailure("fixture did not opt in to a competing Pending")
            }
            return optedInCompetingAuthority
        }
    }

    private func writeEscapedFrozenSiblingChatRoot(
        in fixture: InvocationStoreFixture,
        newerSchema: Bool,
        messageID: ChatMessageID?,
        draftID: ChatDraftID?
    ) throws {
        precondition((messageID != nil) != (draftID != nil))
        let manifest = fixture.root
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent(
                fixture.competingAuthority.request.chatID.rawValue,
                isDirectory: true
            )
            .appendingPathComponent("chat.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: manifest)
            ) as? [String: Any]
        )
        if newerSchema {
            object["schemaVersion"] = Chat.schemaVersion + 1
        } else {
            object["title"] = ["unsupported": true]
        }
        let rawID: String
        if let messageID {
            rawID = messageID.rawValue
            object["messageIds"] = [rawID]
        } else {
            let draftID = try XCTUnwrap(draftID)
            rawID = draftID.rawValue
            var draft = try XCTUnwrap(object["draft"] as? [String: Any])
            draft["draftId"] = rawID
            object["draft"] = draft
        }
        let canonical = try XCTUnwrap(String(
            data: JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ),
            encoding: .utf8
        ))
        let firstByte = try XCTUnwrap(rawID.utf8.first)
        let escapedID = String(format: "\\u%04X", firstByte) + rawID.dropFirst()
        let escaped = canonical.replacingOccurrences(
            of: "\"\(rawID)\"",
            with: "\"\(escapedID)\""
        )
        XCTAssertNotEqual(escaped, canonical)
        XCTAssertFalse(escaped.contains(rawID))
        try Data(("\n\t " + escaped + " \r\n").utf8).write(to: manifest)
    }

    private func writeOpaqueFrozenSiblingChatRoot(
        in fixture: InvocationStoreFixture,
        identity: InvocationAttemptIdentity
    ) throws {
        let manifest = fixture.root
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent(
                fixture.competingAuthority.request.chatID.rawValue,
                isDirectory: true
            )
            .appendingPathComponent("chat.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: manifest)
            ) as? [String: Any]
        )
        object["schemaVersion"] = Chat.schemaVersion + 1
        var draft = try XCTUnwrap(object["draft"] as? [String: Any])
        draft["text"] = identity.freshDraftID.rawValue
        object["draft"] = draft
        object["futurePrivateValues"] = [
            identity.userMessageID.rawValue,
            identity.coachMessageID.rawValue,
        ]
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: manifest)
    }

    private func writeAmbiguousSiblingChatRoot(
        in fixture: InvocationStoreFixture,
        messageID: ChatMessageID
    ) throws {
        let manifest = fixture.root
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent(
                fixture.competingAuthority.request.chatID.rawValue,
                isDirectory: true
            )
            .appendingPathComponent("chat.json")
        let canonical = try XCTUnwrap(
            String(data: Data(contentsOf: manifest), encoding: .utf8)
        )
        guard canonical.first == "{" else {
            return XCTFail("Chat root was not an object")
        }
        let ambiguous = "{\"messageIds\":[\"\(messageID.rawValue)\"]," +
            canonical.dropFirst()
        try Data(ambiguous.utf8).write(to: manifest)
    }

    private func writeSupportedInvocation(
        in fixture: InvocationStoreFixture,
        rootDraftID: ChatDraftID
    ) throws {
        let invocationID = try CoachInvocationID(
            "inv-20260902T100400000Z-4GHJ"
        )
        let attempt = try CoachProviderAttempt(
            id: CoachProviderAttemptID(
                "atm-20260902T100400000Z-5KMN"
            ),
            ordinal: 1,
            kind: .standard,
            providerIdempotencyValue: ProviderIdempotencyValue(
                "supported-root-orphan"
            ),
            transcriptHandles: [],
            publicationAuthority: CoachProviderAttemptPublicationAuthority(
                userMessageID: ChatMessageID(
                    "msg-20260902T100400000Z-6PQR"
                ),
                coachMessageID: ChatMessageID(
                    "msg-20260902T100400000Z-7STV"
                ),
                freshDraftID: ChatDraftID(
                    "drf-20260902T100400000Z-8WXY"
                )
            )
        )
        let pending = PendingUserTurn(
            id: try PendingUserTurnID(
                "ptu-20260902T100400000Z-9YZ0"
            ),
            draftID: rootDraftID,
            draftVersion: 1,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260902T100400000Z-0ABC"
            )
        )
        let invocation = try CoachInvocation(
            id: invocationID,
            attempt: attempt,
            library: fixture.scope,
            chatID: fixture.locked.chat.id,
            pendingUserTurn: pending,
            preparedProfile: fixture.install.invocation.preparedProfile,
            expectedManifestRevision: fixture.locked.chat.manifestRevision,
            admittedAt: UTCInstant("2026-09-02T10:04:00.000Z")
        )
        let root = fixture.root
            .appendingPathComponent("invocations", isDirectory: true)
            .appendingPathComponent(invocationID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        try PortableChatPersistence().encodeInvocation(invocation).write(
            to: root.appendingPathComponent("invocation.json")
        )
    }

    @discardableResult
    private func writeFutureInvocation(
        in fixture: InvocationStoreFixture,
        chatID: ChatID,
        attemptID: String,
        userMessageID: String,
        coachMessageID: String,
        freshDraftID: String,
        draftID: String = "drf-20260830T121109000Z-8WXY",
        opaqueTransportValues: [String] = []
    ) throws -> CoachInvocationID {
        let invocationID = try CoachInvocationID(
            "inv-20260830T121109000Z-4GHJ"
        )
        let root = fixture.root
            .appendingPathComponent("invocations", isDirectory: true)
            .appendingPathComponent(invocationID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        let object: [String: Any] = [
            "schemaVersion": CoachInvocation.schemaVersion + 1,
            "invocationId": invocationID.rawValue,
            "libraryId": fixture.scope.libraryID.rawValue,
            "chatId": chatID.rawValue,
            "draftId": draftID,
            "futureAttemptHistory": [[
                "attemptId": attemptID,
                "userMessageId": userMessageID,
                "coachMessageId": coachMessageID,
                "freshDraftId": freshDraftID,
                "futureOnly": true,
            ]],
            "futureTransportOpaque": opaqueTransportValues,
        ]
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: root.appendingPathComponent("invocation.json"))
        return invocationID
    }

    private func leaveCommittedPublicationForRelaunch(
        _ fixture: InvocationStoreFixture
    ) async -> (outcome: InvocationPublicationOutcome, livenessReleased: Bool) {
        let publicationFault = OneShot()
        let reconciliationFault = OneShot()
        let release = InvocationLivenessReleaseObservation()
        var outcome = InvocationPublicationOutcome.failed
        do {
            let crashed = PortableInvocationStore(
                persistence: PortableChatPersistence(
                    fault: { point in
                        if point == .afterPublicationManifestInstall,
                           publicationFault.take()
                        {
                            throw PortableChatPersistenceError.injectedFault(point)
                        }
                        if point == .beforePublicationReconciliationRead,
                           reconciliationFault.take()
                        {
                            throw PortableChatPersistenceError.injectedFault(point)
                        }
                    },
                    invocationLivenessReleased: release.didRelease
                ),
                workspace: fixture.workspace
            )
            guard case .acquired = await crashed.acquirePendingInvocation(
                fixture.install.authority.request
            ), case .installed = await crashed.installInvocation(fixture.install)
            else { return (.failed, false) }
            outcome = await crashed.publish(fixture.publication)
        }
        await release.waitUntilReleased()
        return (outcome, true)
    }

    private func makeInvocationStoreFixture(
        in parent: URL,
        libraryID: String = "lib-20260830T120000000Z-2ABC",
        includeCompetingPending: Bool = false,
        pendingFailure: PendingUserTurnFailure? = nil,
        transcriptHandles: [CoachProviderTranscriptHandle] = []
    ) async throws -> InvocationStoreFixture {
        let root = parent.appendingPathComponent("Invocation.audoralibrary")
        let library = try PortableLibraryPersistence().create(
            at: root,
            seed: makeSeed(id: libraryID)
        )
        let scope = LibraryScope(libraryID: library.manifest.libraryID)
        let workspace = PortableLibraryWorkspace(
            locations: QueueLocations(existing: [root]),
            bookmarks: SyntheticBookmarks(),
            access: RecordingAccessGrantor(),
            locatorStore: MemoryLocatorStore(),
            revealer: RecordingRevealer()
        )
        _ = await workspace.chooseLibrary()
        let persistence = PortableChatPersistence()
        let seed = try makeChatSeed(scope: scope)
        let created = try persistence.create(seed, at: root)
        let editedDraft = try created.chat.draft.edited(
            text: "Please help me say this more naturally.",
            at: UTCInstant("2026-08-30T12:00:00.500Z")
        )
        guard case let .committed(drafted) = try persistence.saveDraft(
            SaveChatDraftMutation(
                library: scope,
                chatID: created.chat.id,
                replacement: editedDraft
            ),
            at: root
        ) else { throw CocoaError(.fileWriteUnknown) }
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
            draftID: drafted.chat.draft.draftID,
            draftVersion: drafted.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120001000Z-6PQR"
            ),
            failure: pendingFailure
        )
        let lock = LockPendingUserTurnMutation(
            library: scope,
            chatID: drafted.chat.id,
            pendingUserTurn: pending
        )
        guard case let .committed(locked) = try persistence.lockPendingUserTurn(
            lock,
            at: root
        ) else { throw CocoaError(.fileWriteUnknown) }
        let request = PendingCoachInvocationRequest(
            library: scope,
            chatID: locked.chat.id,
            pendingUserTurnID: pending.id
        )
        let authority = try InvocationPendingAuthority(
            request: request,
            aggregate: locked
        )
        let identity = InvocationLaunchIdentity(
            invocationID: try CoachInvocationID("inv-20260830T120002000Z-5KMN"),
            attemptIdentity: InvocationAttemptIdentity(
                attemptID: try CoachProviderAttemptID(
                    "atm-20260830T120002000Z-6PQR"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "synthetic-attempt-6PQR"
                ),
                userMessageID: try ChatMessageID(
                    "msg-20260830T120003000Z-7STV"
                ),
                coachMessageID: try ChatMessageID(
                    "msg-20260830T120003000Z-8WXY"
                ),
                freshDraftID: try ChatDraftID(
                    "drf-20260830T120003000Z-9YZ0"
                ),
                transcriptHandles: transcriptHandles
            )
        )
        let competingAuthority: InvocationPendingAuthority?
        if includeCompetingPending {
            let competingSeed = try NewDevelopmentChatSeed(
                library: scope,
                chatID: ChatID("cht-20260830T120010000Z-3DEF"),
                draftID: ChatDraftID("drf-20260830T120010000Z-4GHJ"),
                memoryID: CoachMemoryID("mem-20260830T120010000Z-5KMN"),
                instant: UTCInstant("2026-08-30T12:00:10.000Z"),
                profileStatementGeneration: 0
            )
            let competingCreated = try persistence.create(competingSeed, at: root)
            let competingPending = PendingUserTurn(
                id: try PendingUserTurnID("ptu-20260830T120011000Z-6PQR"),
                draftID: competingCreated.chat.draft.draftID,
                draftVersion: competingCreated.chat.draft.version,
                responsePositionID: try ChatResponsePositionID(
                    "rsp-20260830T120011000Z-7STV"
                )
            )
            guard case let .committed(competingLocked) = try persistence.lockPendingUserTurn(
                LockPendingUserTurnMutation(
                    library: scope,
                    chatID: competingCreated.chat.id,
                    pendingUserTurn: competingPending
                ),
                at: root
            ) else { throw CocoaError(.fileWriteUnknown) }
            let competingRequest = PendingCoachInvocationRequest(
                library: scope,
                chatID: competingLocked.chat.id,
                pendingUserTurnID: competingPending.id
            )
            competingAuthority = try InvocationPendingAuthority(
                request: competingRequest,
                aggregate: competingLocked
            )
        } else {
            competingAuthority = nil
        }
        let install = try InstallCoachInvocationMutation(
            authority: authority,
            identity: identity,
            preparedProfile: CoachProfileProvenance(
                revisionID: try ProfileRevisionID("prf-20260830T115900000Z-4GHJ"),
                statementGeneration: 9
            ),
            admittedAt: UTCInstant("2026-08-30T12:00:02.000Z")
        )
        return InvocationStoreFixture(
            root: root,
            scope: scope,
            workspace: workspace,
            locked: locked,
            install: install,
            publication: try PublishCoachInvocationMutation(
                base: install.processingAggregate,
                invocation: install.invocation,
                identity: identity,
                coachMarkdown: "Synthetic coaching response.",
                completedAt: UTCInstant("2026-08-30T12:00:03.000Z")
            ),
            competingAuthority: competingAuthority
        )
    }
}

private final class SuspendedInvocationAcquisition: @unchecked Sendable {
    private let condition = NSCondition()
    private var isSuspended = false
    private var isResumed = false

    func suspend() {
        condition.lock()
        isSuspended = true
        condition.broadcast()
        while !isResumed { condition.wait() }
        condition.unlock()
    }

    func waitUntilSuspended() async {
        while !suspendedSnapshot() { await Task.yield() }
    }

    private func suspendedSnapshot() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return isSuspended
    }

    func resume() {
        condition.lock()
        isResumed = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class SynchronousInvocationFaultTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var points: [PortableChatFaultPoint] = []

    func append(_ point: PortableChatFaultPoint) {
        lock.lock()
        points.append(point)
        lock.unlock()
    }

    func containsInOrder(_ expected: PortableChatFaultPoint...) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var remaining = expected[...]
        for point in points where remaining.first == point {
            remaining = remaining.dropFirst()
        }
        return remaining.isEmpty
    }
}

private final class RecordingPortableInvocationRetryDiagnostics:
    @unchecked Sendable,
    InvocationRetryDiagnostics
{
    private let lock = NSLock()
    private var events: [InvocationRetryDiagnosticEvent] = []

    func enqueue(_ event: InvocationRetryDiagnosticEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func recordedEvents() -> [InvocationRetryDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
