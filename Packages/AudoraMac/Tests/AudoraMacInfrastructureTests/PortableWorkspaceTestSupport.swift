@_spi(ChatCreationAuthorityTesting) @_spi(CoachContextQualification) @_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
@testable @_spi(CoachContextQualification) @_spi(InvocationInfrastructure) import AudoraMacInfrastructure
import Foundation

func withTemporaryParent(
    _ body: (URL) async throws -> Void
) async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
        "audora-workspace-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    try await body(parent)
}

func makeSeed(
    id: String = "lib-20260830T120000000Z-2ABC"
) throws -> NewLibrarySeed {
    let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
    return NewLibrarySeed(
        libraryID: try LibraryID(id),
        createdAt: instant,
        preferences: .defaults,
        profileHead: ProfileHead(
            generation: 0,
            statementGeneration: 0,
            selection: .null,
            updatedAt: instant
        )
    )
}

func makeChatSeed(
    scope: LibraryScope,
    attachments: ChatAttachments = .empty
) throws -> NewChatSeed {
    try NewChatSeed(
        library: scope,
        chatID: ChatID("cht-20260830T120000000Z-2ABC"),
        draftID: ChatDraftID("drf-20260830T120000000Z-3DEF"),
        memoryID: CoachMemoryID("mem-20260830T120000000Z-4GHJ"),
        instant: UTCInstant("2026-08-30T12:00:00.000Z"),
        profileStatementGeneration: 0,
        attachments: attachments
    )
}

/// Creates setup state for persistence mutation scenarios through the same
/// evidence-authorized product command used by Chat creation.
func createAuthorizedChatForPersistenceScenario(
    _ seed: NewChatSeed,
    store: PortableChatStore,
    workspace: PortableLibraryWorkspace
) async -> ChatMutationOutcome {
    let traversal = await PortableChatSessionAttachmentSource(
        workspace: workspace
    ).forEachResolvedEvidence(
        seed.aggregate.chat.attachments,
        in: seed.library
    ) { _ in }
    switch traversal {
    case let .completedWithAuthority(authority):
        return await store.create(
            NewChatCommit(seed: seed, evidenceAuthority: authority)
        )
    case .readOnlyLibrary:
        return .readOnlyLibrary
    case .completed, .failed:
        return .failed
    }
}

func installRecordedChatAttachmentFixture(
    at root: URL,
    in scope: LibraryScope,
    attachmentID: String = "attachment-000001",
    recordingID: String = "rec-20260830T120000000Z-2ABC",
    sessionID: String = "ses-20260830T120000000Z-3DEF",
    revisionID: String = "trv-20260830T121000000Z-4FGH",
    jobID: String = "job-20260830T120500000Z-5GHJ",
    externalProcessingAllowed: Bool = true
) async throws -> ChatSessionAttachment {
    let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
    let request = MicrophoneRecordingRequest(
        libraryScope: scope,
        recordingID: try RecordingID(recordingID),
        sessionID: try SessionID(sessionID),
        startedAt: instant
    )
    let recordings = RecordingPersistence()
    let handle = try recordings.prepare(request, under: root)
    try recordings.append(
        CanonicalPCMSpan(
            frameCount: 4,
            pcmLittleEndian: Data(repeating: 1, count: 8),
            reasons: [],
            level: 0.2
        ),
        to: handle
    )
    let candidate = try recordings.stageSeal(handle, reason: .userStop)
    let publication = try RecordingSealCandidateValidator.validate(
        candidate,
        expected: request
    )
    let receipt = try recordings.install(publication, using: handle)
    let revision = try makeFixtureTranscriptRevision(
        for: receipt,
        revisionID: revisionID,
        jobID: jobID,
        externalProcessingAllowed: externalProcessingAllowed
    )
    _ = try await PortableTranscriptRevisionRepository(
        root: root,
        libraryID: scope.libraryID
    ).publishAndSelect(
        revision,
        expectedSelectedRevisionID: nil
    )
    return ChatSessionAttachment(
        attachmentID: try ChatSessionAttachmentID(attachmentID),
        sessionID: receipt.sessionID,
        transcriptRevisionID: revision.revisionID
    )
}

private func makeFixtureTranscriptRevision(
    for receipt: SessionSealedReceipt,
    revisionID: String,
    jobID: String,
    externalProcessingAllowed: Bool
) throws -> TranscriptRevision {
    let range = try SessionTimeRange(
        startMilliseconds: 0,
        endMilliseconds: 1,
        sessionDurationMilliseconds: 1
    )
    let policy = try EngineUsePolicy(
        policyID: "chat-attachment-fixture-v1",
        coveredArtifacts: [.transcriptRevision],
        privateLocalUseAllowed: true,
        privateExportAllowed: true,
        externalProcessingAllowed: externalProcessingAllowed,
        publicDistributionAllowed: false,
        commercialUseAllowed: false,
        licenseReference: "fixture-license",
        licenseSHA256: String(repeating: "e", count: 64)
    )
    return try TranscriptRevision(
        revisionID: TranscriptRevisionID(revisionID),
        sessionID: receipt.sessionID,
        jobID: TranscriptionJobID(jobID),
        createdAt: UTCInstant("2026-08-30T12:10:00.000Z"),
        durationMilliseconds: 1,
        audioFingerprint: receipt.fingerprint,
        sourceFingerprints: [
            TranscriptSourceFingerprint(
                audioSourceID: .microphone,
                fingerprint: receipt.fingerprint
            ),
        ],
        candidateArtifactFingerprint: AudioFingerprint(
            sha256: String(repeating: "b", count: 64)
        ),
        engine: TranscriptEngineProvenance(
            provider: "crisperwhisper",
            model: "small",
            revision: "fixture-revision",
            language: "en",
            mode: "verbatim",
            decodingOptionsSHA256: String(repeating: "c", count: 64),
            qualification: TranscriptEngineQualification(
                qualificationProfileID: "chat-attachment-fixture-v1",
                engineLockSHA256: String(repeating: "f", count: 64),
                runtimeIdentity: "fixture-runtime-v1",
                runtimeLockSHA256: String(repeating: "d", count: 64),
                compatibilityPatchID: "fixture-patch-v1"
            ),
            usePolicy: policy
        ),
        lines: [
            TranscriptLine(
                lineID: TranscriptLineID("l000000"),
                order: 0,
                audioSourceID: .microphone,
                timeRange: range,
                text: "Hi.",
                words: [
                    TranscriptWord(
                        wordID: TranscriptWordID("w000000"),
                        ordinal: 0,
                        text: "Hi",
                        displayRange: LineTextRange(
                            startUTF8Byte: 0,
                            endUTF8Byte: 2
                        ),
                        timeRange: range,
                        confidence: 0.95,
                        wordKind: .lexical
                    ),
                ]
            ),
        ],
        audioEvents: []
    )
}

final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func take() -> Bool {
        lock.withLock {
            guard !fired else { return false }
            fired = true
            return true
        }
    }

    var wasTaken: Bool { lock.withLock { fired } }
}

final class InvocationLivenessReleaseObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var didRelease: @Sendable () -> Void {
        { [weak self] in self?.recordRelease() }
    }

    func waitUntilReleased() async {
        if lock.withLock({ released }) { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if released { return true }
                waiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    private func recordRelease() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !released else { return [] }
            released = true
            defer { waiters.removeAll() }
            return waiters
        }
        continuations.forEach { $0.resume() }
    }
}

actor QueueLocations: LibraryLocationChoosing {
    private var createURLs: [URL]
    private var existingURLs: [URL]

    init(create: [URL] = [], existing: [URL] = []) {
        createURLs = create
        existingURLs = existing
    }

    func chooseCreateDestination() async -> URL? {
        createURLs.isEmpty ? nil : createURLs.removeFirst()
    }

    func chooseExistingLibrary() async -> URL? {
        existingURLs.isEmpty ? nil : existingURLs.removeFirst()
    }
}

final class SyntheticBookmarks: LibraryBookmarking, @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt8 = 1
    private var urls: [Data: URL] = [:]
    private let staleNames: Set<String>

    init(staleNames: Set<String> = []) {
        self.staleNames = staleNames
    }

    func makeBookmark(for url: URL) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let existing = urls.first(where: { $0.value == url })?.key { return existing }
        let value = Data([next])
        next &+= 1
        urls[value] = url
        return value
    }

    func resolveBookmark(_ bookmark: Data) throws -> LibraryBookmarkResolution {
        lock.lock()
        defer { lock.unlock() }
        guard let url = urls[bookmark] else { throw CocoaError(.fileNoSuchFile) }
        return LibraryBookmarkResolution(
            url: url,
            isStale: staleNames.contains(url.lastPathComponent)
        )
    }
}

final class RecordingAccessGrantor: LibraryAccessGranting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] {
        lock.withLock { recorded }
    }

    func acquireAccess(to url: URL) throws -> any LibraryAccessLease {
        let name = url.lastPathComponent
        lock.withLock { recorded.append("acquire:\(name)") }
        return RecordingLease(url: url) { [weak self] in
            self?.lock.withLock { self?.recorded.append("release:\(name)") }
        }
    }
}

final class RecordingLease: LibraryAccessLease, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var released = false
    private let onRelease: @Sendable () -> Void

    init(url: URL, onRelease: @escaping @Sendable () -> Void) {
        self.url = url
        self.onRelease = onRelease
    }

    func release() {
        lock.withLock {
            guard !released else { return }
            released = true
            onRelease()
        }
    }
}

actor MemoryLocatorStore: MachineLibraryLocatorStoring {
    private var value: MachineLibraryLocator?
    private(set) var saveCount = 0

    init(value: MachineLibraryLocator? = nil) { self.value = value }

    func load() async throws -> MachineLibraryLocator? { value }

    func save(_ locator: MachineLibraryLocator) async throws {
        value = locator
        saveCount += 1
    }
}

actor RecordingRevealer: LibraryRevealing {
    private let disposition: LibraryRevealRequestDisposition
    private(set) var revealedNames: [String] = []

    init(disposition: LibraryRevealRequestDisposition = .accepted) {
        self.disposition = disposition
    }

    func requestReveal(_ url: URL) async -> LibraryRevealRequestDisposition {
        revealedNames.append(url.lastPathComponent)
        return disposition
    }
}
