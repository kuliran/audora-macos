import AudoraApplication
import AudoraDomain
@testable import AudoraMacInfrastructure
import Foundation
import XCTest

final class PortableAudioImportWorkspaceTests: XCTestCase {
    func testVerticalSliceCopiesExactOriginalNormalizesValidatesInstallsAndReopens() async throws {
        try await withFixture { fixture in
            let workspace = fixture.makeWorkspace(
                decoder: ScriptedPCMDecoder(
                    inspected: fixture.inspected,
                    chunks: [
                        DecodedPCMChunk(
                            interleavedSamples: [1, -1, 0.5, 0.5],
                            frameCount: 2,
                            channelCount: 2,
                            sampleRateHz: 16_000
                        ),
                    ]
                )
            )

            let selection = await workspace.choose()
            guard case let .selected(token, scope) = selection else {
                return XCTFail("synthetic source was not selected")
            }
            let seed = try fixture.seed(scope: scope)
            let reservation = try await workspace.reserveSessionID(
                seed.sessionID,
                for: token,
                in: scope
            )
            XCTAssertEqual(reservation, .reserved)
            let phaseRecorder = AudioPhaseRecorder()
            let candidate = try await workspace.prepare(
                token,
                seed: seed,
                policy: .versionOne
            ) { phase in
                phaseRecorder.append(phase)
            }
            let validated = try AudioImportCandidateValidator.validate(
                candidate,
                expectedSeed: seed,
                policy: .versionOne
            )
            let snapshot = try await workspace.install(validated)

            XCTAssertEqual(phaseRecorder.snapshot(), [.copying, .inspecting, .normalizing])
            XCTAssertEqual(snapshot.session, validated.session)
            XCTAssertEqual(snapshot.session.audio.canonical.frameCount, 2)
            XCTAssertEqual(snapshot.session.audio.canonical.durationMilliseconds, 1)
            XCTAssertEqual(snapshot.session.audio.sources.count, 1)
            XCTAssertEqual(snapshot.session.audio.sources[0].timelineOffsetMilliseconds, 0)
            let installed = fixture.root.appendingPathComponent("sessions")
                .appendingPathComponent(snapshot.session.sessionID.rawValue)
            XCTAssertEqual(
                try Data(contentsOf: installed.appendingPathComponent("audio/original.wav")),
                fixture.sourceBytes
            )
            XCTAssertEqual(
                try PortableAudioImportPersistence().openSession(
                    at: fixture.root,
                    sessionID: snapshot.session.sessionID
                ),
                .readWrite(snapshot.session)
            )
            let pendingCount = await workspace.pendingSelectionCount
            let stagedCount = await workspace.stagedCandidateCount
            XCTAssertEqual(pendingCount, 0)
            XCTAssertEqual(stagedCount, 0)
            XCTAssertEqual(fixture.events.snapshot().filter { $0 == "release-source" }.count, 1)
            XCTAssertEqual(fixture.events.snapshot().filter { $0 == "release-library" }.count, 1)
        }
    }

    func testSelectionCancellationAndRepeatedSelectionKeepNoMoreThanOneCapability() async throws {
        try await withFixture(sourceCount: 2) { fixture in
            let workspace = fixture.makeWorkspace(decoder: ScriptedPCMDecoder.empty)

            let first = await workspace.choose()
            guard case .selected = first else { return XCTFail("first selection failed") }
            let firstPendingCount = await workspace.pendingSelectionCount
            XCTAssertEqual(firstPendingCount, 1)
            let second = await workspace.choose()
            guard case let .selected(secondToken, _) = second else {
                return XCTFail("second selection failed")
            }
            let secondPendingCount = await workspace.pendingSelectionCount
            XCTAssertEqual(secondPendingCount, 1)
            XCTAssertEqual(fixture.events.snapshot().filter { $0 == "release-source" }.count, 1)
            XCTAssertEqual(fixture.events.snapshot().filter { $0 == "release-library" }.count, 1)

            await workspace.revokeSelection(secondToken)
            let finalPendingCount = await workspace.pendingSelectionCount
            XCTAssertEqual(finalPendingCount, 0)
            XCTAssertEqual(fixture.events.snapshot().filter { $0 == "release-source" }.count, 2)
            XCTAssertEqual(fixture.events.snapshot().filter { $0 == "release-library" }.count, 2)
        }

        try await withFixture(cancelSelection: true) { fixture in
            let workspace = fixture.makeWorkspace(decoder: ScriptedPCMDecoder.empty)
            let selection = await workspace.choose()
            XCTAssertEqual(selection, .cancelled)
            XCTAssertEqual(fixture.events.snapshot(), ["acquire-library", "release-library"])
        }
    }

    func testSessionIDReservationIsLibraryScopedAndCollisionCreatesNoStaging() async throws {
        try await withFixture { fixture in
            let workspace = fixture.makeWorkspace(decoder: ScriptedPCMDecoder.empty)
            guard case let .selected(token, scope) = await workspace.choose() else {
                return XCTFail("selection failed")
            }
            let collidedID = try fixture.seed(scope: scope).sessionID
            let existing = fixture.root.appendingPathComponent("sessions")
                .appendingPathComponent(collidedID.rawValue)
            try FileManager.default.createDirectory(
                at: existing,
                withIntermediateDirectories: false
            )

            let collision = try await workspace.reserveSessionID(
                collidedID,
                for: token,
                in: scope
            )
            XCTAssertEqual(collision, .collision)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: fixture.root.appendingPathComponent("staging/publications").path
                ),
                []
            )
            let pendingCount = await workspace.pendingSelectionCount
            XCTAssertEqual(pendingCount, 1)

            let regeneratedID = try SessionID("ses-20260830T120000000Z-C014")
            let reservation = try await workspace.reserveSessionID(
                regeneratedID,
                for: token,
                in: scope
            )
            XCTAssertEqual(reservation, .reserved)
            await workspace.revokeSelection(token)
        }
    }

    func testRevokedSelectionCannotBeRestoredBySuspendedSessionIDReservation() async throws {
        try await withFixture { fixture in
            let workspace = fixture.makeWorkspace(decoder: ScriptedPCMDecoder.empty)
            guard case let .selected(token, scope) = await workspace.choose() else {
                return XCTFail("selection failed")
            }
            let sessionID = try fixture.seed(scope: scope).sessionID
            await fixture.scopes.suspendNextCurrentScopeOperation()

            let reservation = Task {
                try await workspace.reserveSessionID(sessionID, for: token, in: scope)
            }
            await fixture.scopes.waitForCurrentScopeOperationSuspension()
            await workspace.revokeSelection(token)
            await fixture.scopes.resumeCurrentScopeOperation()

            await XCTAssertThrowsErrorAsyncMac(try await reservation.value) { error in
                XCTAssertEqual(error as? AudioImportFailure, .libraryChanged)
            }
            let pendingSelectionCount = await workspace.pendingSelectionCount
            XCTAssertEqual(pendingSelectionCount, 0)
            await workspace.revokeSelection(token)
            let events = fixture.events.snapshot()
            XCTAssertEqual(events.filter { $0 == "release-source" }.count, 1)
            XCTAssertEqual(events.filter { $0 == "release-library" }.count, 1)
        }
    }

    func testReplacementSelectionRemainsAuthoritativeWhenPriorReservationResumes() async throws {
        try await withFixture(sourceCount: 2) { fixture in
            let workspace = fixture.makeWorkspace(decoder: ScriptedPCMDecoder.empty)
            guard case let .selected(firstToken, firstScope) = await workspace.choose() else {
                return XCTFail("first selection failed")
            }
            let firstSessionID = try fixture.seed(scope: firstScope).sessionID
            await fixture.scopes.suspendNextCurrentScopeOperation()

            let firstReservation = Task {
                try await workspace.reserveSessionID(
                    firstSessionID,
                    for: firstToken,
                    in: firstScope
                )
            }
            await fixture.scopes.waitForCurrentScopeOperationSuspension()
            guard case let .selected(replacementToken, replacementScope) = await workspace.choose()
            else {
                return XCTFail("replacement selection failed")
            }
            await fixture.scopes.resumeCurrentScopeOperation()

            await XCTAssertThrowsErrorAsyncMac(try await firstReservation.value) { error in
                XCTAssertEqual(error as? AudioImportFailure, .libraryChanged)
            }
            let pendingReplacementCount = await workspace.pendingSelectionCount
            XCTAssertEqual(pendingReplacementCount, 1)
            let replacementSessionID = try SessionID("ses-20260830T120000000Z-C014")
            let replacementReservation = try await workspace.reserveSessionID(
                replacementSessionID,
                for: replacementToken,
                in: replacementScope
            )
            XCTAssertEqual(replacementReservation, .reserved)

            await workspace.revokeSelection(replacementToken)
            let pendingSelectionCount = await workspace.pendingSelectionCount
            XCTAssertEqual(pendingSelectionCount, 0)
            let events = fixture.events.snapshot()
            XCTAssertEqual(events.filter { $0 == "release-source" }.count, 2)
            XCTAssertEqual(events.filter { $0 == "release-library" }.count, 2)
        }
    }

    func testLibraryChangeDuringInspectionReleasesOnlyCandidateScopeAndPublishesNothing() async throws {
        try await withFixture { fixture in
            let decoder = ScriptedPCMDecoder(
                inspected: fixture.inspected,
                chunks: [],
                afterInspect: {
                    await fixture.scopes.invalidate()
                }
            )
            let workspace = fixture.makeWorkspace(decoder: decoder)
            guard case let .selected(token, scope) = await workspace.choose() else {
                return XCTFail("selection failed")
            }
            let seed = try fixture.seed(scope: scope)
            let reservation = try await workspace.reserveSessionID(
                seed.sessionID,
                for: token,
                in: scope
            )
            XCTAssertEqual(reservation, .reserved)

            await XCTAssertThrowsErrorAsyncMac(
                try await workspace.prepare(
                    token,
                    seed: seed,
                    policy: .versionOne,
                    progress: { _ in }
                )
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .libraryChanged)
            }

            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: fixture.root.appendingPathComponent("sessions").path
                ),
                []
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: fixture.root.appendingPathComponent("staging/publications").path
                ),
                []
            )
            let events = fixture.events.snapshot()
            XCTAssertLessThan(
                try XCTUnwrap(events.firstIndex(of: "scope-invalidated")),
                try XCTUnwrap(events.firstIndex(of: "release-library"))
            )
        }
    }

    func testDecodeFailureAndFrameLimitLeaveNoSessionOrStagingCandidate() async throws {
        let variants: [ScriptedPCMDecoder] = [
            ScriptedPCMDecoder(
                inspected: InspectedAudio(
                    codec: .linearPCM,
                    sampleRateHz: 16_000,
                    channelCount: 1,
                    metadataDurationSeconds: 0.001
                ),
                chunks: [],
                decodeFailure: .decodeFailed
            ),
            ScriptedPCMDecoder(
                inspected: InspectedAudio(
                    codec: .linearPCM,
                    sampleRateHz: 16_000,
                    channelCount: 1,
                    metadataDurationSeconds: 0.001
                ),
                chunks: [
                    DecodedPCMChunk(
                        interleavedSamples: [0, 0, 0, 0],
                        frameCount: 4,
                        channelCount: 1,
                        sampleRateHz: 16_000
                    ),
                ]
            ),
        ]
        for (index, decoder) in variants.enumerated() {
            try await withFixture { fixture in
                let workspace = fixture.makeWorkspace(decoder: decoder)
                guard case let .selected(token, scope) = await workspace.choose() else {
                    return XCTFail("selection failed")
                }
                let policy = index == 0
                    ? AudioImportPolicy.versionOne
                    : AudioImportPolicy(maximumCanonicalFrames: 3, maximumSourceBytes: 1_024)
                let seed = try fixture.seed(scope: scope)
                let reservation = try await workspace.reserveSessionID(
                    seed.sessionID,
                    for: token,
                    in: scope
                )
                XCTAssertEqual(reservation, .reserved)
                await XCTAssertThrowsErrorAsyncMac(
                    try await workspace.prepare(
                        token,
                        seed: seed,
                        policy: policy,
                        progress: { _ in }
                    )
                ) { error in
                    XCTAssertEqual(
                        error as? AudioImportFailure,
                        index == 0 ? .decodeFailed : .durationExceeded
                    )
                }
                let stagedCount = await workspace.stagedCandidateCount
                XCTAssertEqual(stagedCount, 0)
                XCTAssertEqual(
                    try FileManager.default.contentsOfDirectory(
                        atPath: fixture.root.appendingPathComponent("sessions").path
                    ),
                    []
                )
            }
        }
    }

    func testUnavailableOrInsufficientDescriptorCapacityPublishesNothing() async throws {
        let cases: [(AudioImportCapacity, AudioImportFailure)] = [
            (.unavailable, .unavailable),
            (.available(0), .insufficientSpace),
        ]
        for (capacity, expectedFailure) in cases {
            try await withFixture { fixture in
                let persistence = PortableAudioImportPersistence(
                    capacity: { _ in capacity }
                )
                let workspace = fixture.makeWorkspace(
                    decoder: ScriptedPCMDecoder.empty,
                    persistence: persistence
                )
                guard case let .selected(token, scope) = await workspace.choose() else {
                    return XCTFail("selection failed")
                }
                let seed = try fixture.seed(scope: scope)
                let reservation = try await workspace.reserveSessionID(
                    seed.sessionID,
                    for: token,
                    in: scope
                )
                XCTAssertEqual(reservation, .reserved)

                await XCTAssertThrowsErrorAsyncMac(
                    try await workspace.prepare(
                        token,
                        seed: seed,
                        policy: .versionOne,
                        progress: { _ in }
                    )
                ) { error in
                    XCTAssertEqual(error as? AudioImportFailure, expectedFailure)
                }
                XCTAssertEqual(
                    try FileManager.default.contentsOfDirectory(
                        atPath: fixture.root.appendingPathComponent("sessions").path
                    ),
                    []
                )
                XCTAssertEqual(
                    try FileManager.default.contentsOfDirectory(
                        atPath: fixture.root.appendingPathComponent("staging/publications").path
                    ),
                    []
                )
            }
        }
    }

    func testCandidateIsRevalidatedAndCurrentScopeIsRequiredImmediatelyBeforeInstall() async throws {
        for mutation in ["bytes", "scope"] {
            try await withFixture { fixture in
                let workspace = fixture.makeWorkspace(
                    decoder: ScriptedPCMDecoder(
                        inspected: fixture.inspected,
                        chunks: [
                            DecodedPCMChunk(
                                interleavedSamples: [0, 0, 0],
                                frameCount: 3,
                                channelCount: 1,
                                sampleRateHz: 16_000
                            ),
                        ]
                    )
                )
                guard case let .selected(token, scope) = await workspace.choose() else {
                    return XCTFail("selection failed")
                }
                let seed = try fixture.seed(scope: scope)
                let reservation = try await workspace.reserveSessionID(
                    seed.sessionID,
                    for: token,
                    in: scope
                )
                XCTAssertEqual(reservation, .reserved)
                let raw = try await workspace.prepare(
                    token,
                    seed: seed,
                    policy: .versionOne,
                    progress: { _ in }
                )
                let validated = try AudioImportCandidateValidator.validate(
                    raw,
                    expectedSeed: seed,
                    policy: .versionOne
                )
                if mutation == "bytes" {
                    let canonical = fixture.root.appendingPathComponent(
                        "staging/publications/\(raw.stagingID.rawValue)/\(raw.sessionID)/audio/audio.wav"
                    )
                    var bytes = try Data(contentsOf: canonical)
                    bytes[bytes.count - 1] ^= 0xFF
                    try bytes.write(to: canonical)
                } else {
                    await fixture.scopes.invalidate()
                }

                await XCTAssertThrowsErrorAsyncMac(
                    try await workspace.install(validated)
                ) { error in
                    XCTAssertEqual(
                        error as? AudioImportFailure,
                        mutation == "bytes" ? .candidateCorrupt : .libraryChanged
                    )
                }
                XCTAssertEqual(
                    try FileManager.default.contentsOfDirectory(
                        atPath: fixture.root.appendingPathComponent("sessions").path
                    ),
                    []
                )
                let stagedBeforeDiscard = await workspace.stagedCandidateCount
                XCTAssertEqual(stagedBeforeDiscard, 1)
                await workspace.discard(raw.stagingID)
                let stagedAfterDiscard = await workspace.stagedCandidateCount
                XCTAssertEqual(stagedAfterDiscard, 0)
            }
        }
    }

    func testContainerComesFromOwnedBytesRatherThanTheFilenameExtension() async throws {
        try await withFixture(sourceExtension: "mp3") { fixture in
            let workspace = fixture.makeWorkspace(
                decoder: ScriptedPCMDecoder(
                    inspected: InspectedAudio(
                        codec: .linearPCM,
                        sampleRateHz: 16_000,
                        channelCount: 1,
                        metadataDurationSeconds: 0.001
                    ),
                    chunks: [
                        DecodedPCMChunk(
                            interleavedSamples: [0],
                            frameCount: 1,
                            channelCount: 1,
                            sampleRateHz: 16_000
                        ),
                    ],
                    expectedContainer: .wav
                )
            )
            guard case let .selected(token, scope) = await workspace.choose() else {
                return XCTFail("selection hint was treated as authority")
            }
            let seed = try fixture.seed(scope: scope)
            let reservation = try await workspace.reserveSessionID(
                seed.sessionID,
                for: token,
                in: scope
            )
            XCTAssertEqual(reservation, .reserved)
            let candidate = try await workspace.prepare(
                token,
                seed: seed,
                policy: .versionOne,
                progress: { _ in }
            )
            XCTAssertEqual(candidate.originalContainer, "wav")
            XCTAssertEqual(candidate.originalRelativePath, "audio/original.wav")
        }
    }
}

private struct WorkspaceFixture: @unchecked Sendable {
    let parent: URL
    let root: URL
    let sources: [URL]
    let sourceBytes: Data
    let events: LockedAudioEvents
    let scopes: TestImportScopes
    let chooser: QueuedAudioChooser
    let inspected: InspectedAudio

    func seed(scope: AudioImportScopeIdentity) throws -> ImportedSessionSeed {
        ImportedSessionSeed(
            scope: scope,
            sessionID: try SessionID("ses-20260830T120000000Z-3DEF"),
            createdAt: try UTCInstant("2026-08-30T12:00:00.000Z")
        )
    }

    func makeWorkspace(
        decoder: ScriptedPCMDecoder,
        persistence: PortableAudioImportPersistence = PortableAudioImportPersistence()
    ) -> PortableAudioImportWorkspace {
        PortableAudioImportWorkspace(
            scopes: scopes,
            chooser: chooser,
            sourceAccess: TestSourceAccess(events: events),
            decoder: decoder,
            persistence: persistence
        )
    }
}

private func withFixture(
    sourceCount: Int = 1,
    sourceExtension: String = "wav",
    cancelSelection: Bool = false,
    _ body: (WorkspaceFixture) async throws -> Void
) async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
        "audora-audio-workspace-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("Synthetic.audoralibrary")
    let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
    let libraryID = try LibraryID("lib-20260830T120000000Z-2ABC")
    _ = try PortableLibraryPersistence().create(
        at: root,
        seed: NewLibrarySeed(
            libraryID: libraryID,
            createdAt: instant,
            preferences: .defaults,
            profileHead: ProfileHead(
                generation: 0,
                statementGeneration: 0,
                selection: .null,
                updatedAt: instant
            )
        )
    )
    let sourceBytes = Data("RIFF\u{4}\0\0\0WAVEworkspace-source".utf8)
    var sources: [URL] = []
    for index in 0..<sourceCount {
        let source = parent.appendingPathComponent("source-\(index).\(sourceExtension)")
        try sourceBytes.write(to: source)
        sources.append(source)
    }
    let events = LockedAudioEvents()
    let identity = AudioImportScopeIdentity(libraryID: libraryID, workspaceGeneration: 1)
    let scopes = TestImportScopes(root: root, identity: identity, events: events)
    let chooser = QueuedAudioChooser(urls: cancelSelection ? [nil] : sources.map(Optional.some))
    try await body(
        WorkspaceFixture(
            parent: parent,
            root: root,
            sources: sources,
            sourceBytes: sourceBytes,
            events: events,
            scopes: scopes,
            chooser: chooser,
            inspected: InspectedAudio(
                codec: .linearPCM,
                sampleRateHz: 16_000,
                channelCount: 2,
                metadataDurationSeconds: 0.001
            )
        )
    )
}

private final class LockedAudioEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }

    func snapshot() -> [String] {
        lock.withLock { events }
    }
}

private final class AudioPhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [AudioImportPreparationPhase] = []

    func append(_ phase: AudioImportPreparationPhase) {
        lock.withLock { phases.append(phase) }
    }

    func snapshot() -> [AudioImportPreparationPhase] {
        lock.withLock { phases }
    }
}

private final class TestAudioLease: LibraryAccessLease, @unchecked Sendable {
    let url: URL
    private let event: String
    private let events: LockedAudioEvents
    private let lock = NSLock()
    private var released = false

    init(url: URL, event: String, events: LockedAudioEvents) {
        self.url = url
        self.event = event
        self.events = events
    }

    func release() {
        lock.withLock {
            guard !released else { return }
            released = true
            events.append(event)
        }
    }
}

private struct TestSourceAccess: LibraryAccessGranting {
    let events: LockedAudioEvents

    func acquireAccess(to url: URL) throws -> any LibraryAccessLease {
        events.append("acquire-source")
        return TestAudioLease(url: url, event: "release-source", events: events)
    }
}

private actor TestImportScopes: ActiveLibraryImportScopeProviding {
    private let root: URL
    private let identity: AudioImportScopeIdentity
    private let events: LockedAudioEvents
    private var current = true
    private var suspendNextOperation = false
    private var operationIsSuspended = false
    private var operationContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    init(root: URL, identity: AudioImportScopeIdentity, events: LockedAudioEvents) {
        self.root = root
        self.identity = identity
        self.events = events
    }

    func acquireAudioImportScope() -> ActiveLibraryImportScope? {
        guard current else { return nil }
        events.append("acquire-library")
        return ActiveLibraryImportScope(
            identity: identity,
            root: root,
            lease: TestAudioLease(
                url: root,
                event: "release-library",
                events: events
            )
        )
    }

    func isCurrentAudioImportScope(_ identity: AudioImportScopeIdentity) -> Bool {
        current && identity == self.identity
    }

    func withCurrentAudioImportScope<Result: Sendable>(
        _ identity: AudioImportScopeIdentity,
        perform operation: @Sendable () throws -> Result
    ) async throws -> Result {
        guard current, identity == self.identity else {
            throw AudioImportFailure.libraryChanged
        }
        events.append("commit-authorized")
        if suspendNextOperation {
            suspendNextOperation = false
            operationIsSuspended = true
            let waiters = suspensionWaiters
            suspensionWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { operationContinuation = $0 }
            operationIsSuspended = false
        }
        return try operation()
    }

    func suspendNextCurrentScopeOperation() {
        suspendNextOperation = true
    }

    func waitForCurrentScopeOperationSuspension() async {
        guard !operationIsSuspended else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func resumeCurrentScopeOperation() {
        operationContinuation?.resume()
        operationContinuation = nil
    }

    func invalidate() {
        current = false
        events.append("scope-invalidated")
    }
}

private actor QueuedAudioChooser: AudioFileChoosing {
    private var urls: [URL?]

    init(urls: [URL?]) {
        self.urls = urls
    }

    func chooseAudioFile() -> URL? {
        urls.isEmpty ? nil : urls.removeFirst()
    }
}

private struct ScriptedPCMDecoder: AudioPCMDecoding {
    static let empty = ScriptedPCMDecoder(
        inspected: InspectedAudio(
            codec: .linearPCM,
            sampleRateHz: 16_000,
            channelCount: 1,
            metadataDurationSeconds: 0.001
        ),
        chunks: []
    )

    let inspected: InspectedAudio
    let chunks: [DecodedPCMChunk]
    let inspectFailure: AudioImportFailure?
    let decodeFailure: AudioImportFailure?
    let expectedContainer: ImportedAudioContainer?
    let afterInspect: @Sendable () async -> Void

    init(
        inspected: InspectedAudio,
        chunks: [DecodedPCMChunk],
        inspectFailure: AudioImportFailure? = nil,
        decodeFailure: AudioImportFailure? = nil,
        expectedContainer: ImportedAudioContainer? = nil,
        afterInspect: @escaping @Sendable () async -> Void = {}
    ) {
        self.inspected = inspected
        self.chunks = chunks
        self.inspectFailure = inspectFailure
        self.decodeFailure = decodeFailure
        self.expectedContainer = expectedContainer
        self.afterInspect = afterInspect
    }

    func inspect(
        _ source: OwnedAudioFile,
        container: ImportedAudioContainer
    ) async throws -> InspectedAudioSource {
        if let inspectFailure { throw inspectFailure }
        if let expectedContainer, expectedContainer != container {
            throw AudioImportFailure.unsupportedMedia
        }
        await afterInspect()
        return InspectedAudioSource(description: inspected)
    }

    func decode(
        _ source: InspectedAudioSource,
        consume: (DecodedPCMChunk) throws -> Void
    ) async throws {
        if let decodeFailure { throw decodeFailure }
        for chunk in chunks { try consume(chunk) }
    }
}

private func XCTAssertThrowsErrorAsyncMac<Result>(
    _ expression: @autoclosure () async throws -> Result,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
