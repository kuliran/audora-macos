@testable @_spi(CoachContextQualification) @_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
import XCTest

final class DefaultInvocationsTests: XCTestCase {
    func testSuccessDebitsAndInstallsBeforeOneProviderLaunchThenPublishesOneTurn() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .published(aggregate, quote) = outcome else {
            return XCTFail("expected one complete publication, got \(outcome)")
        }
        XCTAssertTrue(quote.fits)
        XCTAssertEqual(aggregate.chat.messageIDs, [fixture.userMessageID, fixture.coachMessageID])
        XCTAssertEqual(aggregate.chat.draft.draftID, fixture.freshDraftID)
        XCTAssertEqual(aggregate.chat.draft.text, "")
        XCTAssertNil(aggregate.pendingUserTurn)
        let launchCount = await fixture.provider.launchCount
        let claimCount = await fixture.admission.claimCount
        let events = await fixture.recorder.events
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(claimCount, 1)
        XCTAssertEqual(
            events,
            ["resolve", "active", "resolve", "admission", "install", "provider", "publish"]
        )
        let exactBytes = await fixture.provider.serializedRequests
        XCTAssertEqual(exactBytes.count, 1)
        XCTAssertFalse(exactBytes[0].isEmpty)
    }

    func testContextCapacityFailureIsDurableAndConsumesNoAdmissionOrProviderLaunch() async throws {
        let fixture = try InvocationFixture(contextWindow: 8)

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .contextCapacityFailure(aggregate, quote) = outcome else {
            return XCTFail("expected the #21 durable recovery")
        }
        XCTAssertFalse(quote.fits)
        XCTAssertEqual(aggregate.pendingUserTurn?.id, fixture.pending.id)
        XCTAssertEqual(aggregate.pendingUserTurn?.failure, .coachContextCannotFit)
        XCTAssertEqual(aggregate.chat.draft, fixture.initial.chat.draft)
        let claimCount = await fixture.admission.claimCount
        let launchCount = await fixture.provider.launchCount
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(claimCount, 0)
        XCTAssertEqual(launchCount, 0)
        XCTAssertEqual(publicationCount, 0)
    }

    func testAdmissionRejectionLaunchesNothingAndUnlocksTheSamePopulatedDraft() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            admissionDecision: .cooldown(
                lastAdmittedAt: UTCInstant("2026-08-30T11:59:30.001Z"),
                reopensAt: UTCInstant("2026-08-30T12:00:30.001Z")
            )
        )

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .rejected(aggregate, .admissionCooldown) = outcome else {
            return XCTFail("expected a typed cooldown rejection")
        }
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        XCTAssertNil(aggregate?.pendingUserTurn)
        let launchCount = await fixture.provider.launchCount
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(launchCount, 0)
        XCTAssertEqual(publicationCount, 0)
    }

    func testInstallFailureAfterDurableDebitNeverLaunchesAndUnlocksNewSend() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.failNextInstall()

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .rejected(aggregate, .persistenceUnavailable) = outcome else {
            return XCTFail("expected an install rejection")
        }
        let claimCount = await fixture.admission.claimCount
        let launchCount = await fixture.provider.launchCount
        XCTAssertEqual(claimCount, 1)
        XCTAssertEqual(launchCount, 0)
        XCTAssertNil(aggregate?.pendingUserTurn)
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
    }

    func testInstallStaleOutcomeUnlocksAStillMatchingPendingDraft() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.staleNextInstall()

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .rejected(aggregate, .eligibilityChanged) = outcome else {
            return XCTFail("a stale install must reject through the matching Pending authority")
        }
        XCTAssertNil(aggregate?.pendingUserTurn)
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        let launchCount = await fixture.provider.launchCount
        XCTAssertEqual(launchCount, 0)
    }

    func testCASConflictAfterProviderLaunchPublishesNeitherMessageAndRetiresInvocation() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.conflictNextPublication()

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .interrupted(aggregate, .publicationConflict) = outcome else {
            return XCTFail("expected a typed publication conflict")
        }
        let launchCount = await fixture.provider.launchCount
        let activeInvocation = await fixture.persistence.activeInvocation
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(aggregate?.chat.messageIDs, [])
        XCTAssertNil(aggregate?.pendingUserTurn)
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        XCTAssertNil(activeInvocation)
    }

    func testOversizedLockedMessageUsesLocalLimitBeforeContextAdmissionOrProvider() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            draftText: String(
                repeating: "x",
                count: CoachContextInputLimits.maximumUserMessageUTF8Bytes + 1
            )
        )

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .rejected(aggregate, .messageMustBeShortened(maximum)) = outcome else {
            return XCTFail("expected concise local shortening guidance")
        }
        XCTAssertEqual(maximum, CoachContextInputLimits.maximumUserMessageUTF8Bytes)
        XCTAssertNil(aggregate?.pendingUserTurn)
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        let resolutionCount = await fixture.contextSource.pendingResolutionCount
        let claimCount = await fixture.admission.claimCount
        let launchCount = await fixture.provider.launchCount
        XCTAssertEqual(resolutionCount, 0)
        XCTAssertEqual(claimCount, 0)
        XCTAssertEqual(launchCount, 0)
    }

    func testChangedExactContextAfterDurableInstallAbortsAndUnlocksBeforeProvider() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000, contextIsCurrent: false)

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .rejected(aggregate, .contextChanged) = outcome else {
            return XCTFail("stale exact context must abort before launch")
        }
        XCTAssertNil(aggregate?.pendingUserTurn)
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        let claimCount = await fixture.admission.claimCount
        let launchCount = await fixture.provider.launchCount
        let active = await fixture.persistence.activeInvocation
        XCTAssertEqual(claimCount, 1)
        XCTAssertEqual(launchCount, 0)
        XCTAssertNil(active)
    }

    func testProviderCrashPublishesNeitherSideAndRetiresInvocation() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.provider.failNextLaunch()

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .interrupted(aggregate, .providerFailed) = outcome else {
            return XCTFail("provider crash must retire the interrupted Invocation")
        }
        XCTAssertEqual(aggregate?.chat.messageIDs, [])
        XCTAssertNil(aggregate?.pendingUserTurn)
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        let active = await fixture.persistence.activeInvocation
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertNil(active)
        XCTAssertEqual(publicationCount, 0)
    }

    func testInvalidProviderResponsePublishesNeitherSideAndRetiresInvocation() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.provider.returnInvalidResponseNextLaunch()

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .interrupted(aggregate, .invalidProviderResponse) = outcome else {
            return XCTFail("invalid response must retire the interrupted Invocation")
        }
        XCTAssertEqual(aggregate?.chat.messageIDs, [])
        XCTAssertNil(aggregate?.pendingUserTurn)
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        let active = await fixture.persistence.activeInvocation
        XCTAssertNil(active)
    }

    func testPublicationFailurePublishesNeitherSideAndRetiresInvocation() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.failNextPublication()

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .interrupted(aggregate, .persistenceUnavailable) = outcome else {
            return XCTFail("publication failure must retire the interrupted Invocation")
        }
        XCTAssertEqual(aggregate?.chat.messageIDs, [])
        XCTAssertNil(aggregate?.pendingUserTurn)
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        let active = await fixture.persistence.activeInvocation
        XCTAssertNil(active)
    }

    func testConcurrentDuplicateRequestUsesOneAdmissionOneLaunchAndOnePublication() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.provider.suspendNextLaunch()

        async let first = fixture.invocations.tryInvoke(fixture.request)
        await fixture.provider.waitUntilLaunchStarts()
        let duplicate = await fixture.invocations.tryInvoke(fixture.request)

        XCTAssertEqual(duplicate, .rejected(nil, .activeInvocation))
        let claimCountWhileSuspended = await fixture.admission.claimCount
        let launchCountWhileSuspended = await fixture.provider.launchCount
        XCTAssertEqual(claimCountWhileSuspended, 1)
        XCTAssertEqual(launchCountWhileSuspended, 1)

        await fixture.provider.resumeLaunch()
        guard case .published = await first else {
            return XCTFail("the original Invocation must publish exactly once")
        }
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(publicationCount, 1)
    }
}

private final class InvocationFixture: @unchecked Sendable {
    let scope = LibraryScope(
        libraryID: try! LibraryID("lib-20260830T115900000Z-1ABC")
    )
    let instant = try! UTCInstant("2026-08-30T12:00:00.000Z")
    let initial: ChatAggregate
    let pending: PendingUserTurn
    let request: PendingCoachInvocationRequest
    let recorder = InvocationEventRecorder()
    let persistence: MemoryInvocationPersistence
    let admission: ScriptedInvocationAdmission
    let provider: RecordingSyntheticCoachProvider
    let contextSource: InvocationContextSource
    let invocations: DefaultInvocations

    let userMessageID = try! ChatMessageID("msg-20260830T120000000Z-7RST")
    let coachMessageID = try! ChatMessageID("msg-20260830T120000000Z-8VWX")
    let freshDraftID = try! ChatDraftID("drf-20260830T120000000Z-9YZ0")

    init(
        contextWindow: Int,
        admissionDecision: InvocationAdmissionClaimOutcome = .admitted,
        draftText: String = "Keep this exact user Draft",
        contextIsCurrent: Bool = true
    ) throws {
        let empty = try ChatAggregate.emptyDevelopmentChat(
            chatID: ChatID("cht-20260830T120000000Z-1ABC"),
            draftID: ChatDraftID("drf-20260830T120000000Z-2DEF"),
            memoryID: CoachMemoryID("mem-20260830T120000000Z-3GHJ"),
            instant: instant,
            profileStatementGeneration: 7
        )
        let draft = try empty.chat.draft.edited(text: draftText, at: instant)
        let unlocked = try ChatAggregate(
            chat: empty.chat.replacingDraft(with: draft),
            memory: empty.memory
        )
        pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120000000Z-4JKM"),
            draftID: draft.draftID,
            draftVersion: draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120000000Z-5MNP"
            )
        )
        initial = try ChatAggregate(
            chat: unlocked.chat,
            memory: unlocked.memory,
            pendingUserTurn: pending
        )
        request = PendingCoachInvocationRequest(
            library: scope,
            chatID: initial.chat.id,
            pendingUserTurnID: pending.id
        )
        persistence = MemoryInvocationPersistence(initial: initial, recorder: recorder)
        admission = ScriptedInvocationAdmission(
            decision: admissionDecision,
            recorder: recorder
        )
        provider = RecordingSyntheticCoachProvider(recorder: recorder)
        contextSource = InvocationContextSource(
            contextWindow: contextWindow,
            isCurrent: contextIsCurrent
        )
        invocations = DefaultInvocations(
            persistence: persistence,
            admission: admission,
            provider: provider,
            coachContext: DefaultCoachContextFeature(source: contextSource),
            clock: FixedInvocationClock(instant: instant),
            identities: FixedInvocationIdentities(
                invocationID: try CoachInvocationID(
                    "inv-20260830T120000000Z-5KMN"
                ),
                attemptID: try CoachProviderAttemptID(
                    "atm-20260830T120000000Z-6NPQ"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "synthetic-attempt-6NPQ"
                ),
                userMessageID: userMessageID,
                coachMessageID: coachMessageID,
                freshDraftID: freshDraftID
            )
        )
    }
}

private actor InvocationEventRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private actor MemoryInvocationPersistence: InvocationPersistencePort {
    private var aggregate: ChatAggregate
    private let recorder: InvocationEventRecorder
    private var installFails = false
    private var installStales = false
    private var publicationConflicts = false
    private var publicationFails = false
    private(set) var activeInvocation: CoachInvocation?
    private(set) var publicationCount = 0

    init(initial: ChatAggregate, recorder: InvocationEventRecorder) {
        aggregate = initial
        self.recorder = recorder
    }

    func failNextInstall() { installFails = true }
    func staleNextInstall() { installStales = true }
    func conflictNextPublication() { publicationConflicts = true }
    func failNextPublication() { publicationFails = true }

    func resolvePending(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingResolutionOutcome {
        await recorder.record("resolve")
        guard request.chatID == aggregate.chat.id,
              request.pendingUserTurnID == aggregate.pendingUserTurn?.id
        else { return .ineligible(aggregate) }
        return .eligible(
            try! InvocationPendingAuthority(request: request, aggregate: aggregate)
        )
    }

    func checkActiveInvocation(
        in library: LibraryScope
    ) async -> InvocationActiveCheckOutcome {
        await recorder.record("active")
        return activeInvocation == nil ? .none : .exists
    }

    func installInvocation(
        _ mutation: InstallCoachInvocationMutation
    ) async -> InvocationInstallOutcome {
        await recorder.record("install")
        if installFails {
            installFails = false
            return .failed
        }
        if installStales {
            installStales = false
            return .stale(aggregate)
        }
        guard activeInvocation == nil else { return .activeExists }
        guard mutation.authority.aggregate == aggregate else { return .stale(aggregate) }
        activeInvocation = mutation.invocation
        return .installed(mutation.invocation)
    }

    func markContextCapacityFailure(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome {
        guard authority.aggregate == aggregate, let pending = aggregate.pendingUserTurn else {
            return .stale(aggregate)
        }
        aggregate = try! ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            pendingUserTurn: pending.replacingFailure(.coachContextCannotFit)
        )
        return .committed(aggregate)
    }

    func rejectNewSend(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome {
        guard aggregate.pendingUserTurn?.id == authority.request.pendingUserTurnID else {
            return .stale(aggregate)
        }
        aggregate = try! ChatAggregate(chat: aggregate.chat, memory: aggregate.memory)
        return .committed(aggregate)
    }

    func abortInstalledNewSend(
        _ invocation: CoachInvocation
    ) async -> InvocationPendingMutationOutcome {
        guard activeInvocation == invocation else { return .stale(aggregate) }
        activeInvocation = nil
        aggregate = try! ChatAggregate(chat: aggregate.chat, memory: aggregate.memory)
        return .committed(aggregate)
    }

    func publish(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationOutcome {
        await recorder.record("publish")
        publicationCount += 1
        guard activeInvocation == mutation.invocation else { return .stale(aggregate) }
        if publicationFails {
            publicationFails = false
            return .failed
        }
        if publicationConflicts {
            publicationConflicts = false
            return .stale(aggregate)
        }
        guard mutation.base == aggregate else { return .stale(aggregate) }
        aggregate = mutation.replacement
        activeInvocation = nil
        return .committed(aggregate)
    }
}

private actor ScriptedInvocationAdmission: InvocationAdmissionPort {
    private let decision: InvocationAdmissionClaimOutcome
    private let recorder: InvocationEventRecorder
    private(set) var claimCount = 0

    init(decision: InvocationAdmissionClaimOutcome, recorder: InvocationEventRecorder) {
        self.decision = decision
        self.recorder = recorder
    }

    func claim(
        library: LibraryScope,
        at instant: UTCInstant
    ) async -> InvocationAdmissionClaimOutcome {
        claimCount += 1
        await recorder.record("admission")
        return decision
    }
}

private actor RecordingSyntheticCoachProvider: SyntheticCoachProviderPort {
    private let recorder: InvocationEventRecorder
    private(set) var serializedRequests: [[UInt8]] = []
    private(set) var launchCount = 0
    private var shouldFail = false
    private var shouldReturnInvalidResponse = false
    private var shouldSuspend = false
    private var launchStarted = false
    private var launchContinuation: CheckedContinuation<Void, Never>?

    init(recorder: InvocationEventRecorder) { self.recorder = recorder }

    func failNextLaunch() { shouldFail = true }

    func returnInvalidResponseNextLaunch() { shouldReturnInvalidResponse = true }

    func suspendNextLaunch() { shouldSuspend = true }

    func waitUntilLaunchStarts() async {
        while !launchStarted { await Task.yield() }
    }

    func resumeLaunch() {
        launchContinuation?.resume()
        launchContinuation = nil
    }

    func run(_ request: SyntheticCoachProviderRequest) async throws -> String {
        launchCount += 1
        serializedRequests.append(Array(request.exchange.request))
        await recorder.record("provider")
        launchStarted = true
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { launchContinuation = $0 }
        }
        if shouldFail {
            shouldFail = false
            throw SyntheticProviderFailure.injected
        }
        if shouldReturnInvalidResponse {
            shouldReturnInvalidResponse = false
            return ""
        }
        return "A concise **synthetic** answer."
    }
}

private enum SyntheticProviderFailure: Error { case injected }

private actor InvocationContextSource: CoachContextSnapshotPort {
    private let contextWindow: Int
    private let current: Bool
    private(set) var pendingResolutionCount = 0
    private var currentCheckCount = 0

    init(contextWindow: Int, isCurrent: Bool) {
        self.contextWindow = contextWindow
        current = isCurrent
    }

    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome { .sourceUnavailable }

    func resolveChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome { .sourceUnavailable }

    func resolvePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextSnapshotOutcome {
        pendingResolutionCount += 1
        do {
            return .resolved(
                try CoachContextResolvedSnapshot(
                    input: CoachContextQuoteInput(
                        profile: .object(["statements": .array([])]),
                        memory: .object([
                            "generalNotes": .string(""),
                            "sessionSummaries": .array([]),
                        ]),
                        history: [],
                        currentDraft: request.draft.text
                    ),
                    configuration: try CoachContextConfiguration(
                        descriptor: CoachProviderDescriptor(
                            displayName: "Synthetic fixture",
                            contextBudget: CoachContextBudget(
                                contextWindowTokens: contextWindow,
                                responseReservedTokens: min(4, max(1, contextWindow - 2)),
                                safetyMarginTokens: 1
                            ),
                            coachMemoryMaxTokens: 1
                        ),
                        policy: CoachProviderEstimationPolicy(
                            providerIdentifier: "synthetic-fixture-v1",
                            responseCollectorByteCeiling: 8_192,
                            framing: CoachProviderFraming(),
                            tokenEstimator: .utf8ByteUpperBound()
                        )
                    ),
                    authority: CoachContextSnapshotAuthority(
                        binding: .pending(
                            library: request.library,
                            chatID: request.chatID,
                            draftID: request.draft.draftID,
                            draftVersion: request.draft.version,
                            pendingUserTurnID: request.pendingUserTurn.id,
                            responsePositionID: request.pendingUserTurn.responsePositionID
                        ),
                        contextGeneration: 1,
                        configurationGeneration: 1
                    )
                )
            )
        } catch {
            return .sourceUnavailable
        }
    }

    func isCurrent(_ authority: CoachContextSnapshotAuthority) async -> Bool {
        currentCheckCount += 1
        return currentCheckCount == 1 || current
    }
}

private struct FixedInvocationClock: ChatClock {
    let instant: UTCInstant
    func now() async -> UTCInstant { instant }
}

private struct FixedInvocationIdentities: InvocationIdentityGenerating {
    let invocationID: CoachInvocationID
    let attemptID: CoachProviderAttemptID
    let idempotencyValue: ProviderIdempotencyValue
    let userMessageID: ChatMessageID
    let coachMessageID: ChatMessageID
    let freshDraftID: ChatDraftID

    func generate(at instant: UTCInstant) async -> InvocationLaunchIdentity {
        InvocationLaunchIdentity(
            invocationID: invocationID,
            attemptID: attemptID,
            idempotencyValue: idempotencyValue,
            userMessageID: userMessageID,
            coachMessageID: coachMessageID,
            freshDraftID: freshDraftID
        )
    }
}
