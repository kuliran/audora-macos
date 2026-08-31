import AudoraApplication
import AudoraDomain
import CoreFoundation
import CryptoKit
import Darwin
import Foundation

@_silgen_name("flock")
private func transcriptRevisionFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

public enum TranscriptRevisionPersistenceFaultPoint: Equatable, Sendable {
    case afterTranscriptsDirectoryFlush
    case afterRevisionFilesFlush
    case afterRevisionDirectoryInstall
    case afterSessionManifestPartialFlush
    case afterSessionManifestInstall
    case afterSessionDirectoryFlush
}

enum PortableSessionTranscriptionRead: Sendable {
    case available(PortableVerifiedSessionAudio)
    case unavailable
    case integrityMismatch
}

struct PortableVerifiedSessionAudio: Sendable {
    let durationMilliseconds: UInt64
    let audioFingerprint: AudioFingerprint
    let sourceFingerprints: [TranscriptSourceFingerprint]
    let expectedSelectedRevisionID: TranscriptRevisionID?
    let canonicalWAV: Data
}

enum PortableSessionReviewRead: Sendable {
    case available(PortableVerifiedReviewSession)
    case unavailable
    case integrityMismatch
}

struct PortableVerifiedReviewSession: Sendable {
    let revision: ReopenedTranscriptRevisionSnapshot
    let durationMilliseconds: UInt64
    let canonicalWAV: Data
}

enum PortableChatAttachmentRead: Sendable {
    case available(ChatAttachmentCandidate)
    case unavailable(ChatAttachmentUnavailableReason)
}

/// The one persistence boundary that turns a validated Transcript Revision into
/// selected portable Session state. Revision bytes are installed immutably before
/// the Session manifest's logical compare-and-swap commit. All Audora Session
/// writers share the advisory Session-directory lock; the repository validates
/// the expected manifest and pinned revision authority as the final work before
/// rename. The advisory lock is the serialization authority, not a kernel
/// content-CAS against noncooperating processes.
public struct PortableTranscriptRevisionRepository: TranscriptRevisionRepository,
    @unchecked Sendable
{
    private static let maximumManifestBytes = 65_536
    private static let maximumRevisionBytes = 256 * 1_024 * 1_024

    private let root: URL
    private let libraryID: LibraryID
    private let fault: @Sendable (TranscriptRevisionPersistenceFaultPoint) throws -> Void

    public init(
        root: URL,
        libraryID: LibraryID,
        fault: @escaping @Sendable (TranscriptRevisionPersistenceFaultPoint) throws -> Void = {
            _ in
        }
    ) {
        self.root = root
        self.libraryID = libraryID
        self.fault = fault
    }

    public func publishAndSelect(
        _ revision: TranscriptRevision,
        expectedSelectedRevisionID: TranscriptRevisionID?
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        try publishAndSelectSynchronously(
            revision,
            expectedSelectedRevisionID: expectedSelectedRevisionID
        )
    }

    func publishAndSelectSynchronously(
        _ revision: TranscriptRevision,
        expectedSelectedRevisionID: TranscriptRevisionID?
    ) throws -> ReopenedTranscriptRevisionSnapshot {
        try withLockedSession(sessionID: revision.sessionID, exclusive: true) {
            authority in
            let sessionDescriptor = authority.sessionDescriptor
            var selectionInstalled = false
            do {
                let loaded = try loadSession(
                    sessionID: revision.sessionID,
                    sessionDescriptor: sessionDescriptor
                )
                guard loaded.manifest.selectedRevisionID == expectedSelectedRevisionID else {
                    throw TranscriptRevisionRepositoryFailure.staleSelection
                }
                try validate(revision, against: loaded.audio)

                let revisionData = try Self.deterministicJSON(
                    try TranscriptRevisionDTO(revision)
                )
                guard revisionData.count <= Self.maximumRevisionBytes else {
                    throw TranscriptRevisionRepositoryFailure.writeFailed
                }
                let revisionSHA256 = Self.sha256(revisionData)
                let selected = try SelectedTranscriptRevision(
                    revisionID: revision.revisionID,
                    revisionSHA256: revisionSHA256
                )
                let updatedManifest = try loaded.manifest.selecting(selected)
                let revisionIsInventoried = loaded.manifest.transcriptRevisionIDs.contains(
                    revision.revisionID
                )
                let transcriptsDescriptor: Int32
                if revisionIsInventoried {
                    do {
                        transcriptsDescriptor = try readConfined.openDirectory(
                            named: "transcripts",
                            under: sessionDescriptor
                        )
                    } catch {
                        throw TranscriptRevisionRepositoryFailure.revisionCollision
                    }
                } else {
                    transcriptsDescriptor = try openOrCreateTranscripts(
                        under: sessionDescriptor
                    )
                }
                defer { Darwin.close(transcriptsDescriptor) }
                let transcriptsIdentity = try Self.identity(of: transcriptsDescriptor)
                if revisionIsInventoried {
                    try requireExactInstalledRevision(
                        revisionData,
                        sha256: revisionSHA256,
                        revisionID: revision.revisionID,
                        under: transcriptsDescriptor
                    )
                } else {
                    try installRevisionIfNeeded(
                        revisionData,
                        sha256: revisionSHA256,
                        revisionID: revision.revisionID,
                        under: transcriptsDescriptor,
                        sessionDescriptor: sessionDescriptor,
                        expectedIdentity: transcriptsIdentity
                    )
                }
                let installedRevision = try openInstalledRevisionAuthority(
                    revisionID: revision.revisionID,
                    expectedData: revisionData,
                    expectedSHA256: revisionSHA256,
                    under: transcriptsDescriptor
                )
                defer { Darwin.close(installedRevision.descriptor) }

                try replaceSessionManifest(
                    updatedManifest,
                    under: sessionDescriptor,
                    precommit: {
                        try revalidate(
                            authority,
                            expectedSessionID: revision.sessionID
                        )
                        try revalidateDirectoryEntry(
                            named: "transcripts",
                            under: sessionDescriptor,
                            descriptor: transcriptsDescriptor,
                            expectedIdentity: transcriptsIdentity
                        )
                        try requireCurrentSessionManifest(
                            expectedData: loaded.manifestData,
                            expectedSelectedRevisionID: expectedSelectedRevisionID,
                            expectedSessionID: revision.sessionID,
                            under: sessionDescriptor
                        )
                        try revalidateInstalledRevision(
                            installedRevision,
                            revisionID: revision.revisionID,
                            expectedData: revisionData,
                            expectedSHA256: revisionSHA256,
                            under: transcriptsDescriptor
                        )
                    }
                )
                selectionInstalled = true
                try fault(.afterSessionManifestInstall)
                try Self.flush(sessionDescriptor)
                try fault(.afterSessionDirectoryFlush)

                try revalidate(authority, expectedSessionID: revision.sessionID)

                return try reopenSelectedLocked(
                    sessionID: revision.sessionID,
                    sessionDescriptor: sessionDescriptor
                )
            } catch let failure as TranscriptRevisionRepositoryFailure {
                if selectionInstalled {
                    throw TranscriptRevisionRepositoryFailure.installedNeedsRefresh
                }
                throw failure
            } catch {
                throw selectionInstalled
                    ? TranscriptRevisionRepositoryFailure.installedNeedsRefresh
                    : TranscriptRevisionRepositoryFailure.writeFailed
            }
        }
    }

    public func reopenSelected(
        sessionID: SessionID
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        try reopenSelectedSynchronously(sessionID: sessionID)
    }

    func reopenSelectedSynchronously(
        sessionID: SessionID
    ) throws -> ReopenedTranscriptRevisionSnapshot {
        try withLockedSession(sessionID: sessionID, exclusive: false) {
            let snapshot = try reopenSelectedLocked(
                sessionID: sessionID,
                sessionDescriptor: $0.sessionDescriptor
            )
            try revalidate($0, expectedSessionID: sessionID)
            return snapshot
        }
    }

    /// Switches only the selected-Revision pointer. The target must already be
    /// present in the Session inventory and its immutable bundle is verified
    /// before the manifest compare-and-swap commit.
    func selectExistingRevisionSynchronously(
        _ revisionID: TranscriptRevisionID,
        sessionID: SessionID,
        expectedSelectedRevisionID: TranscriptRevisionID
    ) throws -> ReopenedTranscriptRevisionSnapshot {
        try withLockedSession(sessionID: sessionID, exclusive: true) { authority in
            let sessionDescriptor = authority.sessionDescriptor
            var selectionInstalled = false
            do {
                let loaded = try loadSession(
                    sessionID: sessionID,
                    sessionDescriptor: sessionDescriptor
                )
                guard loaded.manifest.selectedRevisionID == expectedSelectedRevisionID else {
                    throw TranscriptRevisionRepositoryFailure.staleSelection
                }
                guard loaded.manifest.transcriptRevisionIDs.contains(revisionID) else {
                    throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
                }

                let transcriptsDescriptor = try readConfined.openDirectory(
                    named: "transcripts",
                    under: sessionDescriptor
                )
                defer { Darwin.close(transcriptsDescriptor) }
                let transcriptsIdentity = try Self.identity(of: transcriptsDescriptor)
                let target = try loadInstalledRevision(
                    revisionID: revisionID,
                    expectedSHA256: nil,
                    sessionID: sessionID,
                    audio: loaded.audio,
                    under: transcriptsDescriptor
                )
                defer { Darwin.close(target.authority.descriptor) }

                let selected = try SelectedTranscriptRevision(
                    revisionID: revisionID,
                    revisionSHA256: target.sha256
                )
                let updatedManifest = try loaded.manifest.selecting(selected)
                try replaceSessionManifest(
                    updatedManifest,
                    under: sessionDescriptor,
                    precommit: {
                        try revalidate(authority, expectedSessionID: sessionID)
                        try revalidateDirectoryEntry(
                            named: "transcripts",
                            under: sessionDescriptor,
                            descriptor: transcriptsDescriptor,
                            expectedIdentity: transcriptsIdentity
                        )
                        try requireCurrentSessionManifest(
                            expectedData: loaded.manifestData,
                            expectedSelectedRevisionID: expectedSelectedRevisionID,
                            expectedSessionID: sessionID,
                            under: sessionDescriptor
                        )
                        try revalidateInstalledRevision(
                            target.authority,
                            revisionID: revisionID,
                            expectedData: target.data,
                            expectedSHA256: target.sha256,
                            under: transcriptsDescriptor
                        )
                    }
                )
                selectionInstalled = true
                try fault(.afterSessionManifestInstall)
                try Self.flush(sessionDescriptor)
                try fault(.afterSessionDirectoryFlush)
                try revalidate(authority, expectedSessionID: sessionID)

                return try reopenSelectedLocked(
                    sessionID: sessionID,
                    sessionDescriptor: sessionDescriptor
                )
            } catch let failure as TranscriptRevisionRepositoryFailure {
                if selectionInstalled {
                    throw TranscriptRevisionRepositoryFailure.installedNeedsRefresh
                }
                throw failure
            } catch {
                throw selectionInstalled
                    ? TranscriptRevisionRepositoryFailure.installedNeedsRefresh
                    : TranscriptRevisionRepositoryFailure.writeFailed
            }
        }
    }

    /// Reconstructs trusted processing input from the same descriptor-confined
    /// Session boundary used for Revision publication. Canonical bytes remain
    /// in Infrastructure and are copied into an opaque execution capability by
    /// `PortableSessionProcessingWorkspace`.
    func loadTranscriptionAudio(
        for selection: SessionProcessingSelection
    ) async -> PortableSessionTranscriptionRead {
        loadTranscriptionAudioSynchronously(for: selection)
    }

    func loadTranscriptionAudioSynchronously(
        for selection: SessionProcessingSelection
    ) -> PortableSessionTranscriptionRead {
        guard selection.scope.libraryID == libraryID else { return .unavailable }
        do {
            return try withLockedSession(
                sessionID: selection.sessionID,
                exclusive: false
            ) { authority in
                let loaded = try loadSession(
                    sessionID: selection.sessionID,
                    sessionDescriptor: authority.sessionDescriptor
                )
                let wav = try loadCanonicalWAV(
                    audio: loaded.audio,
                    under: authority.sessionDescriptor
                )
                try revalidate(authority, expectedSessionID: selection.sessionID)
                return .available(
                    PortableVerifiedSessionAudio(
                        durationMilliseconds: loaded.audio.durationMilliseconds,
                        audioFingerprint: loaded.audio.audioFingerprint,
                        sourceFingerprints: loaded.audio.sourceFingerprints,
                        expectedSelectedRevisionID: loaded.manifest.selectedRevisionID,
                        canonicalWAV: wav
                    )
                )
            }
        } catch TranscriptRevisionRepositoryFailure.sessionUnavailable,
                TranscriptRevisionRepositoryFailure.unsupportedSchema {
            return .unavailable
        } catch {
            return .integrityMismatch
        }
    }

    /// Reads the manifest, selected immutable Revision, inventory, and
    /// canonical audio while holding one shared Session authority.
    func loadReviewSynchronously(
        for selection: ReviewSelection
    ) -> PortableSessionReviewRead {
        guard selection.scope.libraryID == libraryID else { return .unavailable }
        do {
            return try withLockedSession(
                sessionID: selection.sessionID,
                exclusive: false
            ) { authority in
                let loaded = try loadSession(
                    sessionID: selection.sessionID,
                    sessionDescriptor: authority.sessionDescriptor
                )
                guard let selected = loaded.manifest.selectedTranscriptRevision else {
                    throw TranscriptRevisionRepositoryFailure.sessionUnavailable
                }
                let transcriptsDescriptor = try readConfined.openDirectory(
                    named: "transcripts",
                    under: authority.sessionDescriptor
                )
                defer { Darwin.close(transcriptsDescriptor) }
                let transcriptsIdentity = try Self.identity(of: transcriptsDescriptor)
                let installed = try loadInstalledRevision(
                    revisionID: selected.revisionID,
                    expectedSHA256: selected.revisionSHA256,
                    sessionID: selection.sessionID,
                    audio: loaded.audio,
                    under: transcriptsDescriptor
                )
                defer { Darwin.close(installed.authority.descriptor) }
                let wav = try loadCanonicalWAV(
                    audio: loaded.audio,
                    under: authority.sessionDescriptor
                )
                try revalidate(authority, expectedSessionID: selection.sessionID)
                try revalidateDirectoryEntry(
                    named: "transcripts",
                    under: authority.sessionDescriptor,
                    descriptor: transcriptsDescriptor,
                    expectedIdentity: transcriptsIdentity
                )
                try requireCurrentSessionManifest(
                    expectedData: loaded.manifestData,
                    expectedSelectedRevisionID: selected.revisionID,
                    expectedSessionID: selection.sessionID,
                    under: authority.sessionDescriptor
                )
                try revalidateInstalledRevision(
                    installed.authority,
                    revisionID: selected.revisionID,
                    expectedData: installed.data,
                    expectedSHA256: installed.sha256,
                    under: transcriptsDescriptor
                )
                return .available(
                    PortableVerifiedReviewSession(
                        revision: ReopenedTranscriptRevisionSnapshot(
                            revisionIDs: loaded.manifest.transcriptRevisionIDs,
                            selectedRevisionID: selected.revisionID,
                            selectedRevision: installed.revision
                        ),
                        durationMilliseconds: loaded.audio.durationMilliseconds,
                        canonicalWAV: wav
                    )
                )
            }
        } catch TranscriptRevisionRepositoryFailure.sessionUnavailable,
                TranscriptRevisionRepositoryFailure.unsupportedSchema {
            return .unavailable
        } catch {
            return .integrityMismatch
        }
    }

    /// Lists only active Sessions and projects each currently selected immutable
    /// Transcript Revision. The descriptor-confined Session reader remains the
    /// authority for identity, hashes, duration, and revision integrity.
    func loadChatAttachmentCatalogSynchronously() throws -> [ChatAttachmentCandidate] {
        try activeSessionIDsSynchronously().compactMap { sessionID in
            switch loadChatAttachmentSynchronously(
                sessionID: sessionID,
                transcriptRevisionID: nil
            ) {
            case let .available(candidate): candidate
            // One unreadable independent entity must not hide healthy Sessions
            // from a creation catalog. Every selected pin is re-resolved before
            // the Chat is installed.
            case .unavailable: nil
            }
        }
    }

    /// Reopens the exact historical revision pinned by a Chat, even if the
    /// Session later selects a different revision.
    func resolveChatAttachmentsSynchronously(
        _ attachments: ChatAttachments
    ) -> [ResolvedChatAttachment] {
        attachments.values.map { attachment in
            let read = loadChatAttachmentSynchronously(
                sessionID: attachment.sessionID,
                transcriptRevisionID: attachment.transcriptRevisionID
            )
            let resolution: ChatAttachmentResolution
            switch read {
            case let .available(candidate): resolution = .available(candidate)
            case let .unavailable(reason): resolution = .unavailable(reason)
            }
            return try! ResolvedChatAttachment(
                attachment: attachment,
                resolution: resolution
            )
        }
    }

    private func activeSessionIDsSynchronously() throws -> [SessionID] {
        let authority = try openRoot()
        defer {
            Darwin.close(authority.rootDescriptor)
            Darwin.close(authority.parentDescriptor)
        }
        do {
            let loaded = try PortableLibraryPersistence().load(
                from: authority.rootDescriptor,
                reconcileAbandonedImports: false
            )
            guard case let .readWrite(library) = loaded,
                  library.manifest.libraryID == libraryID
            else {
                throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
            }
        } catch let failure as TranscriptRevisionRepositoryFailure {
            throw failure
        } catch {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        let sessions = try readConfined.openDirectory(
            named: "sessions",
            under: authority.rootDescriptor
        )
        defer { Darwin.close(sessions) }
        let sessionsIdentity = try Self.identity(of: sessions)
        let names = try readConfined.listEntryNames(
            under: sessions,
            maximumCount: 32_768
        )
        // A malformed independent entry is unavailable, not authority over the
        // healthy Session aggregates beside it.
        let identifiers = names.compactMap { try? SessionID($0) }
        guard try configuredRootIdentity() == authority.identity,
              try Self.identity(named: authority.name, under: authority.parentDescriptor)
                == authority.identity,
              try Self.identity(named: "sessions", under: authority.rootDescriptor)
                == sessionsIdentity,
              try Self.identity(of: sessions) == sessionsIdentity
        else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        return identifiers.sorted { $0.rawValue < $1.rawValue }
    }

    private func loadChatAttachmentSynchronously(
        sessionID: SessionID,
        transcriptRevisionID expectedRevisionID: TranscriptRevisionID?
    ) -> PortableChatAttachmentRead {
        do {
            return try withLockedSession(sessionID: sessionID, exclusive: false) {
                authority in
                let loaded = try loadSession(
                    sessionID: sessionID,
                    sessionDescriptor: authority.sessionDescriptor
                )
                let revisionID: TranscriptRevisionID
                let expectedSHA256: String?
                if let expectedRevisionID {
                    guard loaded.manifest.transcriptRevisionIDs.contains(expectedRevisionID)
                    else { return .unavailable(.missing) }
                    revisionID = expectedRevisionID
                    expectedSHA256 = loaded.manifest.selectedTranscriptRevision
                        .flatMap { $0.revisionID == expectedRevisionID ? $0.revisionSHA256 : nil }
                } else {
                    guard let selected = loaded.manifest.selectedTranscriptRevision else {
                        return .unavailable(.missing)
                    }
                    revisionID = selected.revisionID
                    expectedSHA256 = selected.revisionSHA256
                }
                let transcripts = try readConfined.openDirectory(
                    named: "transcripts",
                    under: authority.sessionDescriptor
                )
                defer { Darwin.close(transcripts) }
                let transcriptsIdentity = try Self.identity(of: transcripts)
                switch try directoryPresence(
                    named: revisionID.rawValue,
                    under: transcripts
                ) {
                case .absent:
                    try revalidate(authority, expectedSessionID: sessionID)
                    try revalidateDirectoryEntry(
                        named: "transcripts",
                        under: authority.sessionDescriptor,
                        descriptor: transcripts,
                        expectedIdentity: transcriptsIdentity
                    )
                    guard try directoryPresence(
                        named: revisionID.rawValue,
                        under: transcripts
                    ) == .absent else {
                        throw TranscriptRevisionRepositoryFailure
                            .sessionIntegrityMismatch
                    }
                    return .unavailable(.missing)
                case .invalid:
                    throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
                case .directory:
                    break
                }
                let installed = try loadInstalledRevision(
                    revisionID: revisionID,
                    expectedSHA256: expectedSHA256,
                    sessionID: sessionID,
                    audio: loaded.audio,
                    under: transcripts
                )
                defer { Darwin.close(installed.authority.descriptor) }
                try revalidate(authority, expectedSessionID: sessionID)
                try revalidateDirectoryEntry(
                    named: "transcripts",
                    under: authority.sessionDescriptor,
                    descriptor: transcripts,
                    expectedIdentity: transcriptsIdentity
                )
                try revalidateInstalledRevision(
                    installed.authority,
                    revisionID: revisionID,
                    expectedData: installed.data,
                    expectedSHA256: installed.sha256,
                    under: transcripts
                )
                return .available(
                    try ChatAttachmentCandidate(
                        sessionID: sessionID,
                        transcriptRevisionID: revisionID,
                        displayLabel: loaded.manifest.chatDisplayLabel,
                        durationMilliseconds: loaded.audio.durationMilliseconds,
                        approximateTranscriptTokens: Self.approximateTranscriptTokens(
                            installed.revision
                        ),
                        delivery: Self.chatDelivery(
                            for: installed.revision
                        )
                    )
                )
            }
        } catch TranscriptRevisionRepositoryFailure.unsupportedSchema {
            return .unavailable(.unsupportedSchema)
        } catch TranscriptRevisionRepositoryFailure.sessionUnavailable {
            return .unavailable(
                unavailableSessionReasonSynchronously(sessionID: sessionID)
            )
        } catch {
            return .unavailable(.corrupt)
        }
    }

    private func unavailableSessionReasonSynchronously(
        sessionID: SessionID
    ) -> ChatAttachmentUnavailableReason {
        do {
            let authority = try openRoot()
            defer {
                Darwin.close(authority.rootDescriptor)
                Darwin.close(authority.parentDescriptor)
            }
            do {
                let loaded = try PortableLibraryPersistence().load(
                    from: authority.rootDescriptor,
                    reconcileAbandonedImports: false
                )
                guard case let .readWrite(library) = loaded,
                      library.manifest.libraryID == libraryID
                else {
                    throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
                }
            } catch let failure as TranscriptRevisionRepositoryFailure {
                throw failure
            } catch {
                throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
            }

            let sessions = try readConfined.openDirectory(
                named: "sessions",
                under: authority.rootDescriptor
            )
            defer { Darwin.close(sessions) }
            let sessionsIdentity = try Self.identity(of: sessions)
            let trash = try readConfined.openDirectory(
                named: "trash",
                under: authority.rootDescriptor
            )
            defer { Darwin.close(trash) }
            let trashIdentity = try Self.identity(of: trash)
            let trashedSessions = try readConfined.openDirectory(
                named: "sessions",
                under: trash
            )
            defer { Darwin.close(trashedSessions) }
            let trashedSessionsIdentity = try Self.identity(of: trashedSessions)
            let activePresence = try directoryPresence(
                named: sessionID.rawValue,
                under: sessions
            )
            let trashPresence = try directoryPresence(
                named: sessionID.rawValue,
                under: trashedSessions
            )

            guard try configuredRootIdentity() == authority.identity,
                  try Self.identity(
                      named: authority.name,
                      under: authority.parentDescriptor
                  ) == authority.identity,
                  try Self.identity(of: authority.rootDescriptor) == authority.identity,
                  try Self.identity(
                      named: "sessions",
                      under: authority.rootDescriptor
                  ) == sessionsIdentity,
                  try Self.identity(of: sessions) == sessionsIdentity,
                  try Self.identity(
                      named: "trash",
                      under: authority.rootDescriptor
                  ) == trashIdentity,
                  try Self.identity(of: trash) == trashIdentity,
                  try Self.identity(
                      named: "sessions",
                      under: trash
                  ) == trashedSessionsIdentity,
                  try Self.identity(of: trashedSessions) == trashedSessionsIdentity,
                  try directoryPresence(
                      named: sessionID.rawValue,
                      under: sessions
                  ) == activePresence,
                  try directoryPresence(
                      named: sessionID.rawValue,
                      under: trashedSessions
                  ) == trashPresence
            else {
                throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
            }

            switch (activePresence, trashPresence) {
            case (.absent, .directory): return .inTrash
            case (.absent, .absent): return .missing
            case (.directory, _), (.invalid, _), (_, .invalid): return .corrupt
            }
        } catch {
            return .corrupt
        }
    }

    private func directoryPresence(
        named name: String,
        under parent: Int32
    ) throws -> DirectoryPresence {
        var metadata = stat()
        let result = name.withCString {
            Darwin.fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return .absent }
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else { return .invalid }
        return .directory(EntryIdentity(metadata))
    }

    private static func approximateTranscriptTokens(_ revision: TranscriptRevision) -> Int {
        var bytes = 0
        for line in revision.lines {
            let (sum, overflow) = bytes.addingReportingOverflow(line.text.utf8.count + 1)
            if overflow { return Int.max }
            bytes = sum
        }
        let eventBytes = revision.audioEvents.count.multipliedReportingOverflow(by: 48)
        if eventBytes.overflow { return Int.max }
        let total = bytes.addingReportingOverflow(eventBytes.partialValue)
        if total.overflow { return Int.max }
        return total.partialValue / 4 + (total.partialValue % 4 == 0 ? 0 : 1)
    }

    private static func chatDelivery(
        for revision: TranscriptRevision
    ) -> ChatAttachmentDelivery {
        approximateTranscriptTokens(revision) <= 8_192 ? .inline : .onDemand
    }

    private func reopenSelectedLocked(
        sessionID: SessionID,
        sessionDescriptor: Int32
    ) throws -> ReopenedTranscriptRevisionSnapshot {
        let loaded = try loadSession(
            sessionID: sessionID,
            sessionDescriptor: sessionDescriptor
        )
        return try reopenSelectedLocked(
            sessionID: sessionID,
            sessionDescriptor: sessionDescriptor,
            loaded: loaded
        )
    }

    private func reopenSelectedLocked(
        sessionID: SessionID,
        sessionDescriptor: Int32,
        loaded: LoadedSession
    ) throws -> ReopenedTranscriptRevisionSnapshot {
        guard let selected = loaded.manifest.selectedTranscriptRevision else {
            throw TranscriptRevisionRepositoryFailure.sessionUnavailable
        }
        let transcriptsDescriptor = try readConfined.openDirectory(
            named: "transcripts",
            under: sessionDescriptor
        )
        defer { Darwin.close(transcriptsDescriptor) }
        let installed = try loadInstalledRevision(
            revisionID: selected.revisionID,
            expectedSHA256: selected.revisionSHA256,
            sessionID: sessionID,
            audio: loaded.audio,
            under: transcriptsDescriptor
        )
        defer { Darwin.close(installed.authority.descriptor) }
        return ReopenedTranscriptRevisionSnapshot(
            revisionIDs: loaded.manifest.transcriptRevisionIDs,
            selectedRevisionID: selected.revisionID,
            selectedRevision: installed.revision
        )
    }

    private func withLockedSession<T>(
        sessionID: SessionID,
        exclusive: Bool,
        _ body: (LockedSessionAuthority) throws -> T
    ) throws -> T {
        let rootAuthority = try openRoot()
        defer {
            Darwin.close(rootAuthority.rootDescriptor)
            Darwin.close(rootAuthority.parentDescriptor)
        }
        do {
            let loaded = try PortableLibraryPersistence().load(
                from: rootAuthority.rootDescriptor,
                reconcileAbandonedImports: false
            )
            guard case let .readWrite(authority) = loaded,
                  authority.manifest.libraryID == libraryID
            else {
                throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
            }
        } catch let failure as TranscriptRevisionRepositoryFailure {
            throw failure
        } catch {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        let sessionsDescriptor = try readConfined.openDirectory(
            named: "sessions",
            under: rootAuthority.rootDescriptor
        )
        defer { Darwin.close(sessionsDescriptor) }
        let sessionsIdentity = try Self.identity(of: sessionsDescriptor)
        let sessionDescriptor: Int32
        do {
            sessionDescriptor = try readConfined.openDirectory(
                named: sessionID.rawValue,
                under: sessionsDescriptor
            )
        } catch {
            throw TranscriptRevisionRepositoryFailure.sessionUnavailable
        }
        defer { Darwin.close(sessionDescriptor) }
        let sessionIdentity = try Self.identity(of: sessionDescriptor)
        let operation = exclusive ? LOCK_EX : LOCK_SH
        while transcriptRevisionFlock(sessionDescriptor, operation) != 0 {
            if errno == EINTR { continue }
            throw TranscriptRevisionRepositoryFailure.writeFailed
        }
        defer { _ = transcriptRevisionFlock(sessionDescriptor, LOCK_UN) }
        let authority = LockedSessionAuthority(
            root: rootAuthority,
            sessionsDescriptor: sessionsDescriptor,
            sessionsIdentity: sessionsIdentity,
            sessionDescriptor: sessionDescriptor,
            sessionIdentity: sessionIdentity
        )
        try revalidate(authority, expectedSessionID: sessionID)
        return try body(authority)
    }

    private func openRoot() throws -> OpenedRootAuthority {
        let parentURL = root.deletingLastPathComponent()
        let name = root.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\")
        else {
            throw TranscriptRevisionRepositoryFailure.sessionUnavailable
        }
        let parentDescriptor: Int32 = parentURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else {
            throw TranscriptRevisionRepositoryFailure.sessionUnavailable
        }
        let rootDescriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard rootDescriptor >= 0 else {
            Darwin.close(parentDescriptor)
            throw TranscriptRevisionRepositoryFailure.sessionUnavailable
        }
        do {
            return OpenedRootAuthority(
                parentDescriptor: parentDescriptor,
                rootDescriptor: rootDescriptor,
                name: name,
                identity: try Self.identity(of: rootDescriptor)
            )
        } catch {
            Darwin.close(rootDescriptor)
            Darwin.close(parentDescriptor)
            throw error
        }
    }

    private var readConfined: ConfinedPersistencePrimitives<TranscriptRevisionRepositoryFailure> {
        ConfinedPersistencePrimitives(
            ioFailure: .sessionIntegrityMismatch,
            invalidLayout: .sessionIntegrityMismatch,
            expectedPathIsSymlink: .sessionIntegrityMismatch,
            rootTooLarge: .sessionIntegrityMismatch,
            invalidJSON: .sessionIntegrityMismatch,
            invalidSchemaVersion: .sessionIntegrityMismatch,
            unknownKey: .sessionIntegrityMismatch
        )
    }

    private var writeConfined: ConfinedPersistencePrimitives<TranscriptRevisionRepositoryFailure> {
        ConfinedPersistencePrimitives(
            ioFailure: .writeFailed,
            invalidLayout: .sessionIntegrityMismatch,
            expectedPathIsSymlink: .sessionIntegrityMismatch,
            rootTooLarge: .sessionIntegrityMismatch,
            invalidJSON: .sessionIntegrityMismatch,
            invalidSchemaVersion: .sessionIntegrityMismatch,
            unknownKey: .sessionIntegrityMismatch
        )
    }
}

private extension PortableTranscriptRevisionRepository {
    struct TrustedSessionAudio {
        let durationMilliseconds: UInt64
        let audioFingerprint: AudioFingerprint
        let sourceFingerprints: [TranscriptSourceFingerprint]
    }

    struct LoadedSession {
        let manifestData: Data
        let manifest: PortableSessionManifest
        let audio: TrustedSessionAudio
    }

    enum DirectoryPresence: Equatable {
        case absent
        case directory(EntryIdentity)
        case invalid
    }

    struct EntryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        init(_ metadata: stat) {
            device = UInt64(truncatingIfNeeded: metadata.st_dev)
            inode = UInt64(truncatingIfNeeded: metadata.st_ino)
        }
    }

    struct OpenedRootAuthority {
        let parentDescriptor: Int32
        let rootDescriptor: Int32
        let name: String
        let identity: EntryIdentity
    }

    struct LockedSessionAuthority {
        let root: OpenedRootAuthority
        let sessionsDescriptor: Int32
        let sessionsIdentity: EntryIdentity
        let sessionDescriptor: Int32
        let sessionIdentity: EntryIdentity
    }

    struct InstalledRevisionAuthority {
        let descriptor: Int32
        let directoryIdentity: EntryIdentity
        let revisionFileIdentity: EntryIdentity
        let hashFileIdentity: EntryIdentity
    }

    struct LoadedInstalledRevision {
        let data: Data
        let sha256: String
        let revision: TranscriptRevision
        let authority: InstalledRevisionAuthority
    }

    func loadSession(
        sessionID: SessionID,
        sessionDescriptor: Int32
    ) throws -> LoadedSession {
        let manifestData = try readConfined.boundedData(
            named: "session.json",
            under: sessionDescriptor,
            maximumBytes: Self.maximumManifestBytes
        )
        let manifest = try decodeSessionManifest(
            manifestData,
            expectedSessionID: sessionID
        )
        let audio: TrustedSessionAudio
        switch manifest {
        case .recorded:
            audio = try loadRecordedAudio(under: sessionDescriptor)
        case .imported:
            let reopened = try PortableAudioImportPersistence().openSession(
                under: sessionDescriptor,
                sessionID: sessionID
            )
            guard case let .readWrite(session) = reopened,
                  session.transcriptRevisionIDs == manifest.transcriptRevisionIDs,
                  session.selectedTranscriptRevision == manifest.selectedTranscriptRevision
            else {
                throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
            }
            let canonical = session.audio.canonical
            let fingerprint = try AudioFingerprint(sha256: canonical.fingerprint.sha256)
            audio = TrustedSessionAudio(
                durationMilliseconds: session.durationMilliseconds,
                audioFingerprint: fingerprint,
                sourceFingerprints: session.audio.sources.map {
                    TranscriptSourceFingerprint(
                        audioSourceID: $0.audioSourceID,
                        fingerprint: fingerprint
                    )
                }
            )
        }
        return LoadedSession(
            manifestData: manifestData,
            manifest: manifest,
            audio: audio
        )
    }

    func loadCanonicalWAV(
        audio: TrustedSessionAudio,
        under sessionDescriptor: Int32
    ) throws -> Data {
        let audioDescriptor = try readConfined.openDirectory(
            named: "audio",
            under: sessionDescriptor
        )
        defer { Darwin.close(audioDescriptor) }
        let wav = try readConfined.boundedData(
            named: "audio.wav",
            under: audioDescriptor,
            maximumBytes: Int(CanonicalAudioFormat.maximumFrameCount * 2 + 44)
        )
        guard Self.sha256(wav) == audio.audioFingerprint.sha256,
              let frameCount = Self.validateCanonicalWAV(wav),
              try CanonicalAudioFormat.durationMilliseconds(
                forFrameCount: frameCount
              ) == audio.durationMilliseconds
        else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        return wav
    }

    func loadInstalledRevision(
        revisionID: TranscriptRevisionID,
        expectedSHA256: String?,
        sessionID: SessionID,
        audio: TrustedSessionAudio,
        under transcriptsDescriptor: Int32
    ) throws -> LoadedInstalledRevision {
        let revisionDescriptor = try readConfined.openDirectory(
            named: revisionID.rawValue,
            under: transcriptsDescriptor
        )
        do {
            let authority = try captureRevisionAuthority(
                descriptor: revisionDescriptor
            )
            guard try readConfined.listEntryNames(
                under: revisionDescriptor,
                maximumCount: 2
            ) == ["revision.json", "revision.sha256"] else {
                throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
            }
            let revisionData = try readConfined.boundedData(
                named: "revision.json",
                under: revisionDescriptor,
                maximumBytes: Self.maximumRevisionBytes
            )
            let detachedData = try readConfined.boundedData(
                named: "revision.sha256",
                under: revisionDescriptor,
                maximumBytes: 64
            )
            guard let detached = String(data: detachedData, encoding: .utf8),
                  AudioArtifactFingerprint.isSHA256(detached),
                  expectedSHA256.map({ $0 == detached }) ?? true,
                  detached == Self.sha256(revisionData)
            else {
                throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
            }
            let revision = try decodeRevision(revisionData)
            guard revision.revisionID == revisionID,
                  revision.sessionID == sessionID
            else {
                throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
            }
            try validate(revision, against: audio)
            try revalidateInstalledRevision(
                authority,
                revisionID: revisionID,
                expectedData: revisionData,
                expectedSHA256: detached,
                under: transcriptsDescriptor
            )
            return LoadedInstalledRevision(
                data: revisionData,
                sha256: detached,
                revision: revision,
                authority: authority
            )
        } catch {
            Darwin.close(revisionDescriptor)
            throw error
        }
    }

    func revalidate(
        _ authority: LockedSessionAuthority,
        expectedSessionID: SessionID
    ) throws {
        guard try Self.identity(
            named: authority.root.name,
            under: authority.root.parentDescriptor
        ) == authority.root.identity,
            try configuredRootIdentity() == authority.root.identity,
            try Self.identity(of: authority.root.rootDescriptor) == authority.root.identity,
            try Self.identity(
                named: "sessions",
                under: authority.root.rootDescriptor
            ) == authority.sessionsIdentity,
            try Self.identity(of: authority.sessionsDescriptor) == authority.sessionsIdentity,
            try Self.identity(
                named: expectedSessionID.rawValue,
                under: authority.sessionsDescriptor
            ) == authority.sessionIdentity,
            try Self.identity(of: authority.sessionDescriptor) == authority.sessionIdentity
        else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        do {
            let loaded = try PortableLibraryPersistence().load(
                from: authority.root.rootDescriptor,
                reconcileAbandonedImports: false
            )
            guard case let .readWrite(library) = loaded,
                  library.manifest.libraryID == libraryID
            else {
                throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
            }
        } catch let failure as TranscriptRevisionRepositoryFailure {
            throw failure
        } catch {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
    }

    func configuredRootIdentity() throws -> EntryIdentity {
        let descriptor: Int32 = root.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        defer { Darwin.close(descriptor) }
        return try Self.identity(of: descriptor)
    }

    func revalidateDirectoryEntry(
        named name: String,
        under parent: Int32,
        descriptor: Int32,
        expectedIdentity: EntryIdentity
    ) throws {
        guard try Self.identity(named: name, under: parent) == expectedIdentity,
              try Self.identity(of: descriptor) == expectedIdentity
        else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
    }

    static func identity(of descriptor: Int32) throws -> EntryIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR
        else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        return EntryIdentity(metadata)
    }

    static func identity(named name: String, under parent: Int32) throws -> EntryIdentity {
        try identity(named: name, under: parent, expectedType: S_IFDIR)
    }

    static func identity(
        named name: String,
        under parent: Int32,
        expectedType: mode_t
    ) throws -> EntryIdentity {
        var metadata = stat()
        guard name.withCString({
            fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }) == 0,
            (metadata.st_mode & S_IFMT) == expectedType
        else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        return EntryIdentity(metadata)
    }

    func decodeSessionManifest(
        _ data: Data,
        expectedSessionID: SessionID
    ) throws -> PortableSessionManifest {
        let dictionary = try readConfined.jsonDictionary(data)
        try requireVersionOneSessionSchema(in: dictionary)
        let commonRequired: Set<String> = [
            "schemaVersion", "sessionId", "createdAt", "transcriptRevisionIds",
        ]
        let optional: Set<String> = ["selectedTranscriptRevision"]
        let keys = Set(dictionary.keys)
        if keys.contains("selectedTranscriptRevision") {
            guard let selected = dictionary["selectedTranscriptRevision"]
                as? [String: Any],
                Set(selected.keys) == ["revisionId", "revisionSha256"]
            else {
                throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
            }
        }
        let manifest: PortableSessionManifest
        do {
            if keys.contains("audioManifestPath") {
                guard commonRequired
                    .union(["audioManifestPath"])
                    .isSubset(of: keys),
                    keys.isSubset(of: commonRequired.union(["audioManifestPath"]).union(optional))
                else {
                    throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
                }
                let dto = try JSONDecoder().decode(RecordedSessionManifestDTO.self, from: data)
                guard dto.schemaVersion == 1,
                      dto.sessionId == expectedSessionID.rawValue,
                      dto.audioManifestPath == "audio/audio.json",
                      (try? UTCInstant(dto.createdAt)) != nil
                else {
                    throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
                }
                manifest = try validatedManifest(dto)
            } else {
                let required = commonRequired.union([
                    "durationMs", "audioManifestSha256",
                ])
                guard required.isSubset(of: keys),
                      keys.isSubset(of: required.union(optional))
                else {
                    throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
                }
                let dto = try JSONDecoder().decode(ImportedSessionManifestDTO.self, from: data)
                guard dto.schemaVersion == 1,
                      dto.sessionId == expectedSessionID.rawValue,
                      dto.durationMs > 0,
                      dto.durationMs <= 2_700_000,
                      AudioArtifactFingerprint.isSHA256(dto.audioManifestSha256),
                      (try? UTCInstant(dto.createdAt)) != nil
                else {
                    throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
                }
                manifest = try validatedManifest(dto)
            }
            return manifest
        } catch let failure as TranscriptRevisionRepositoryFailure {
            throw failure
        } catch {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
    }

    func requireVersionOneSessionSchema(in root: [String: Any]) throws {
        guard let schemaVersion = root["schemaVersion"] as? NSNumber,
              CFGetTypeID(schemaVersion) != CFBooleanGetTypeID(),
              schemaVersion.doubleValue.isFinite,
              schemaVersion.doubleValue.rounded() == schemaVersion.doubleValue
        else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        if schemaVersion.doubleValue > 1 {
            throw TranscriptRevisionRepositoryFailure.unsupportedSchema
        }
        guard schemaVersion.doubleValue == 1 else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
    }

    func loadRecordedAudio(under sessionDescriptor: Int32) throws -> TrustedSessionAudio {
        do {
            let audio = try RecordingPersistence().loadValidatedSealedAudio(
                under: sessionDescriptor
            )
            let duration = try CanonicalAudioFormat.durationMilliseconds(
                forFrameCount: audio.frameCount
            )
            return TrustedSessionAudio(
                durationMilliseconds: duration,
                audioFingerprint: audio.fingerprint,
                sourceFingerprints: [
                    TranscriptSourceFingerprint(
                        audioSourceID: .microphone,
                        fingerprint: audio.fingerprint
                    ),
                ]
            )
        } catch {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
    }

    func validate(
        _ revision: TranscriptRevision,
        against audio: TrustedSessionAudio
    ) throws {
        guard revision.durationMilliseconds == audio.durationMilliseconds,
              revision.audioFingerprint == audio.audioFingerprint,
              revision.sourceFingerprints.count == audio.sourceFingerprints.count
        else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        var expected: [AudioSourceID: AudioFingerprint] = [:]
        for source in audio.sourceFingerprints {
            guard expected.updateValue(
                source.fingerprint,
                forKey: source.audioSourceID
            ) == nil else {
                throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
            }
        }
        var actual: [AudioSourceID: AudioFingerprint] = [:]
        for source in revision.sourceFingerprints {
            guard actual.updateValue(
                source.fingerprint,
                forKey: source.audioSourceID
            ) == nil else {
                throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
            }
        }
        guard actual == expected else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
    }

    func openOrCreateTranscripts(under sessionDescriptor: Int32) throws -> Int32 {
        if mkdirat(sessionDescriptor, "transcripts", 0o700) != 0, errno != EEXIST {
            throw TranscriptRevisionRepositoryFailure.writeFailed
        }
        do {
            let descriptor = try writeConfined.openDirectory(
                named: "transcripts",
                under: sessionDescriptor
            )
            do {
                try Self.flush(sessionDescriptor)
                try fault(.afterTranscriptsDirectoryFlush)
                return descriptor
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        } catch let failure as TranscriptRevisionRepositoryFailure {
            throw failure
        } catch {
            throw TranscriptRevisionRepositoryFailure.writeFailed
        }
    }

    func installRevisionIfNeeded(
        _ data: Data,
        sha256: String,
        revisionID: TranscriptRevisionID,
        under transcriptsDescriptor: Int32,
        sessionDescriptor: Int32,
        expectedIdentity: EntryIdentity
    ) throws {
        try revalidateDirectoryEntry(
            named: "transcripts",
            under: sessionDescriptor,
            descriptor: transcriptsDescriptor,
            expectedIdentity: expectedIdentity
        )
        try reconcileOwnedRevisionPartials(
            for: revisionID,
            under: transcriptsDescriptor
        )
        if try readConfined.entryExists(
            named: revisionID.rawValue,
            under: transcriptsDescriptor
        ) {
            try requireExactInstalledRevision(
                data,
                sha256: sha256,
                revisionID: revisionID,
                under: transcriptsDescriptor
            )
            try Self.flush(transcriptsDescriptor)
            return
        }

        let partialName = ".\(revisionID.rawValue)-\(UUID().uuidString).partial"
        guard mkdirat(transcriptsDescriptor, partialName, 0o700) == 0 else {
            throw TranscriptRevisionRepositoryFailure.writeFailed
        }
        var installed = false
        defer {
            if !installed {
                removeOwnedRevisionPartial(
                    named: partialName,
                    under: transcriptsDescriptor
                )
            }
        }
        let partialDescriptor = try writeConfined.openDirectory(
            named: partialName,
            under: transcriptsDescriptor
        )
        do {
            try writeConfined.writeExclusive(
                data,
                named: "revision.json",
                under: partialDescriptor,
                flushBeforeClose: true
            )
            try writeConfined.writeExclusive(
                Data(sha256.utf8),
                named: "revision.sha256",
                under: partialDescriptor,
                flushBeforeClose: true
            )
            try Self.flush(partialDescriptor)
            let partialAuthority = try captureRevisionAuthority(
                descriptor: partialDescriptor
            )
            try fault(.afterRevisionFilesFlush)
            try revalidateDirectoryEntry(
                named: "transcripts",
                under: sessionDescriptor,
                descriptor: transcriptsDescriptor,
                expectedIdentity: expectedIdentity
            )
            try revalidateRevisionBundle(
                partialAuthority,
                name: partialName,
                expectedData: data,
                expectedSHA256: sha256,
                under: transcriptsDescriptor
            )
        } catch {
            Darwin.close(partialDescriptor)
            throw error
        }
        Darwin.close(partialDescriptor)
        do {
            try writeConfined.renameNoReplace(
                from: partialName,
                under: transcriptsDescriptor,
                to: revisionID.rawValue,
                under: transcriptsDescriptor,
                collision: .revisionCollision
            )
            installed = true
            try Self.flush(transcriptsDescriptor)
            try fault(.afterRevisionDirectoryInstall)
            try revalidateDirectoryEntry(
                named: "transcripts",
                under: sessionDescriptor,
                descriptor: transcriptsDescriptor,
                expectedIdentity: expectedIdentity
            )
        } catch TranscriptRevisionRepositoryFailure.revisionCollision {
            try requireExactInstalledRevision(
                data,
                sha256: sha256,
                revisionID: revisionID,
                under: transcriptsDescriptor
            )
        }
    }

    func requireExactInstalledRevision(
        _ data: Data,
        sha256: String,
        revisionID: TranscriptRevisionID,
        under transcriptsDescriptor: Int32
    ) throws {
        let revisionDescriptor: Int32
        do {
            revisionDescriptor = try readConfined.openDirectory(
                named: revisionID.rawValue,
                under: transcriptsDescriptor
            )
        } catch {
            throw TranscriptRevisionRepositoryFailure.revisionCollision
        }
        defer { Darwin.close(revisionDescriptor) }
        guard (try? readConfined.listEntryNames(
            under: revisionDescriptor,
            maximumCount: 2
        )) == ["revision.json", "revision.sha256"],
            (try? readConfined.boundedData(
                named: "revision.json",
                under: revisionDescriptor,
                maximumBytes: Self.maximumRevisionBytes
            )) == data,
            (try? readConfined.boundedData(
                named: "revision.sha256",
                under: revisionDescriptor,
                maximumBytes: 64
            )) == Data(sha256.utf8)
        else {
            throw TranscriptRevisionRepositoryFailure.revisionCollision
        }
    }

    func openInstalledRevisionAuthority(
        revisionID: TranscriptRevisionID,
        expectedData: Data,
        expectedSHA256: String,
        under transcriptsDescriptor: Int32
    ) throws -> InstalledRevisionAuthority {
        let descriptor = try readConfined.openDirectory(
            named: revisionID.rawValue,
            under: transcriptsDescriptor
        )
        do {
            let authority = try captureRevisionAuthority(descriptor: descriptor)
            try revalidateInstalledRevision(
                authority,
                revisionID: revisionID,
                expectedData: expectedData,
                expectedSHA256: expectedSHA256,
                under: transcriptsDescriptor
            )
            return authority
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func revalidateInstalledRevision(
        _ authority: InstalledRevisionAuthority,
        revisionID: TranscriptRevisionID,
        expectedData: Data,
        expectedSHA256: String,
        under transcriptsDescriptor: Int32
    ) throws {
        try revalidateRevisionBundle(
            authority,
            name: revisionID.rawValue,
            expectedData: expectedData,
            expectedSHA256: expectedSHA256,
            under: transcriptsDescriptor
        )
    }

    func captureRevisionAuthority(
        descriptor: Int32
    ) throws -> InstalledRevisionAuthority {
        InstalledRevisionAuthority(
            descriptor: descriptor,
            directoryIdentity: try Self.identity(of: descriptor),
            revisionFileIdentity: try Self.identity(
                named: "revision.json",
                under: descriptor,
                expectedType: S_IFREG
            ),
            hashFileIdentity: try Self.identity(
                named: "revision.sha256",
                under: descriptor,
                expectedType: S_IFREG
            )
        )
    }

    func revalidateRevisionBundle(
        _ authority: InstalledRevisionAuthority,
        name: String,
        expectedData: Data,
        expectedSHA256: String,
        under transcriptsDescriptor: Int32
    ) throws {
        guard try Self.identity(
            named: name,
            under: transcriptsDescriptor
        ) == authority.directoryIdentity,
            try Self.identity(of: authority.descriptor) == authority.directoryIdentity,
            try Self.identity(
                named: "revision.json",
                under: authority.descriptor,
                expectedType: S_IFREG
            ) == authority.revisionFileIdentity,
            try Self.identity(
                named: "revision.sha256",
                under: authority.descriptor,
                expectedType: S_IFREG
            ) == authority.hashFileIdentity,
            try readConfined.listEntryNames(
                under: authority.descriptor,
                maximumCount: 2
            ) == ["revision.json", "revision.sha256"],
            try readConfined.boundedData(
                named: "revision.json",
                under: authority.descriptor,
                maximumBytes: Self.maximumRevisionBytes
            ) == expectedData,
            try readConfined.boundedData(
                named: "revision.sha256",
                under: authority.descriptor,
                maximumBytes: 64
            ) == Data(expectedSHA256.utf8)
        else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
    }

    func requireCurrentSessionManifest(
        expectedData: Data,
        expectedSelectedRevisionID: TranscriptRevisionID?,
        expectedSessionID: SessionID,
        under sessionDescriptor: Int32
    ) throws {
        let currentData = try readConfined.boundedData(
            named: "session.json",
            under: sessionDescriptor,
            maximumBytes: Self.maximumManifestBytes
        )
        let current = try decodeSessionManifest(
            currentData,
            expectedSessionID: expectedSessionID
        )
        guard current.selectedRevisionID == expectedSelectedRevisionID else {
            throw TranscriptRevisionRepositoryFailure.staleSelection
        }
        guard currentData == expectedData else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
    }

    func replaceSessionManifest(
        _ manifest: PortableSessionManifest,
        under sessionDescriptor: Int32,
        precommit: () throws -> Void
    ) throws {
        let data: Data
        switch manifest {
        case let .recorded(dto, _, _):
            data = try Self.deterministicJSON(dto)
        case let .imported(dto, _, _):
            data = try Self.deterministicJSON(dto)
        }
        guard data.count <= Self.maximumManifestBytes else {
            throw TranscriptRevisionRepositoryFailure.writeFailed
        }
        try reconcileOwnedSessionPartials(under: sessionDescriptor)
        let partialName = ".session-\(UUID().uuidString).partial"
        var installed = false
        defer {
            if !installed { _ = unlinkat(sessionDescriptor, partialName, 0) }
        }
        try writeConfined.writeExclusive(
            data,
            named: partialName,
            under: sessionDescriptor,
            flushBeforeClose: true
        )
        let partialIdentity = try Self.identity(
            named: partialName,
            under: sessionDescriptor,
            expectedType: S_IFREG
        )
        try fault(.afterSessionManifestPartialFlush)
        guard try Self.identity(
            named: partialName,
            under: sessionDescriptor,
            expectedType: S_IFREG
        ) == partialIdentity,
            try readConfined.boundedData(
                named: partialName,
                under: sessionDescriptor,
                maximumBytes: Self.maximumManifestBytes
            ) == data
        else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        // Keep the current-manifest CAS and installed-bundle authority checks as
        // the final operations before the commit rename while holding LOCK_EX.
        try precommit()
        guard renameat(
            sessionDescriptor,
            partialName,
            sessionDescriptor,
            "session.json"
        ) == 0 else {
            throw TranscriptRevisionRepositoryFailure.writeFailed
        }
        installed = true
    }

    func reconcileOwnedRevisionPartials(
        for revisionID: TranscriptRevisionID,
        under parent: Int32
    ) throws {
        let prefix = ".\(revisionID.rawValue)-"
        let names = try readConfined.listEntryNames(under: parent, maximumCount: 32_768)
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".partial") {
            let uuidText = String(
                name.dropFirst(prefix.count).dropLast(".partial".count)
            )
            guard UUID(uuidString: uuidText) != nil else { continue }
            removeOwnedRevisionPartial(named: name, under: parent)
        }
    }

    func reconcileOwnedSessionPartials(under sessionDescriptor: Int32) throws {
        let names = try readConfined.listEntryNames(under: sessionDescriptor, maximumCount: 64)
        for name in names where name.hasPrefix(".session-") && name.hasSuffix(".partial") {
            let uuidText = String(
                name.dropFirst(".session-".count).dropLast(".partial".count)
            )
            guard UUID(uuidString: uuidText) != nil else { continue }
            var metadata = stat()
            guard name.withCString({
                fstatat(sessionDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }) == 0,
                (metadata.st_mode & S_IFMT) == S_IFREG,
                metadata.st_size >= 0,
                metadata.st_size <= Self.maximumManifestBytes
            else {
                continue
            }
            guard unlinkat(sessionDescriptor, name, 0) == 0 else {
                throw TranscriptRevisionRepositoryFailure.writeFailed
            }
        }
    }

    func removeOwnedRevisionPartial(named name: String, under parent: Int32) {
        guard let descriptor = try? readConfined.openDirectory(named: name, under: parent)
        else { return }
        defer { Darwin.close(descriptor) }
        guard let entries = try? readConfined.listEntryNames(
            under: descriptor,
            maximumCount: 2
        ), Set(entries).isSubset(of: ["revision.json", "revision.sha256"])
        else { return }
        _ = unlinkat(descriptor, "revision.json", 0)
        _ = unlinkat(descriptor, "revision.sha256", 0)
        _ = unlinkat(parent, name, AT_REMOVEDIR)
    }

    static func deterministicJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validateCanonicalWAV(_ data: Data) -> UInt64? {
        guard data.count >= 46,
              Array(data[0..<4]) == Array("RIFF".utf8),
              Array(data[8..<12]) == Array("WAVE".utf8),
              Array(data[12..<16]) == Array("fmt ".utf8),
              littleEndianUInt32(data, at: 4) == UInt32(data.count - 8),
              littleEndianUInt32(data, at: 16) == 16,
              littleEndianUInt16(data, at: 20) == 1,
              littleEndianUInt16(data, at: 22) == 1,
              littleEndianUInt32(data, at: 24) == CanonicalAudioFormat.sampleRateHz,
              littleEndianUInt32(data, at: 28) == 32_000,
              littleEndianUInt16(data, at: 32) == 2,
              littleEndianUInt16(data, at: 34) == 16,
              Array(data[36..<40]) == Array("data".utf8),
              let payloadBytes = littleEndianUInt32(data, at: 40),
              Int(payloadBytes) == data.count - 44,
              payloadBytes.isMultiple(of: 2)
        else { return nil }
        let frameCount = UInt64(payloadBytes / 2)
        guard frameCount > 0, frameCount <= CanonicalAudioFormat.maximumFrameCount else {
            return nil
        }
        return frameCount
    }

    static func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }

    static func flush(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw TranscriptRevisionRepositoryFailure.writeFailed
        }
    }
}

private extension PortableTranscriptRevisionRepository {
    func validateRevisionJSONShape(_ data: Data) throws {
        let root = try readConfined.jsonDictionary(data)
        guard let schemaVersion = root["schemaVersion"] as? NSNumber,
              CFGetTypeID(schemaVersion) != CFBooleanGetTypeID(),
              schemaVersion.doubleValue.isFinite,
              schemaVersion.doubleValue.rounded() == schemaVersion.doubleValue
        else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        if schemaVersion.doubleValue > 2 {
            throw TranscriptRevisionRepositoryFailure.unsupportedSchema
        }
        guard schemaVersion.doubleValue == 1 || schemaVersion.doubleValue == 2 else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        try requireExactKeys(root, [
            "schemaVersion", "revisionId", "sessionId", "jobId", "createdAt",
            "durationMs", "audioFingerprintSha256", "sourceFingerprints",
            "candidateArtifactSha256", "engine", "lines", "audioEvents",
        ])
        let sources = try dictionaries(root["sourceFingerprints"])
        guard sources.count <= 32 else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        for source in sources {
            try requireExactKeys(source, ["audioSourceId", "sha256"])
        }
        let engine = try dictionary(root["engine"])
        let commonEngineKeys: Set<String> = [
            "provider", "model", "revision", "language", "mode",
            "decodingOptionsSha256", "usePolicy",
        ]
        if schemaVersion.doubleValue == 1 {
            try requireExactKeys(engine, commonEngineKeys)
        } else {
            try requireExactKeys(engine, commonEngineKeys.union(["qualification"]))
            let qualification = try dictionary(engine["qualification"])
            try requireExactKeys(qualification, [
                "schemaVersion", "qualificationProfileId", "engineLockSha256",
                "runtimeIdentity", "runtimeLockSha256", "compatibilityPatchId",
            ])
        }
        let usePolicy = try dictionary(engine["usePolicy"])
        try requireExactKeys(usePolicy, [
            "policyId", "coveredArtifacts", "privateLocalUseAllowed",
            "privateExportAllowed", "externalProcessingAllowed",
            "publicDistributionAllowed", "commercialUseAllowed",
            "licenseReference", "licenseSha256",
        ])

        let lines = try dictionaries(root["lines"])
        guard !lines.isEmpty, lines.count <= 100_000 else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        var wordCount = 0
        for line in lines {
            try requireExactKeys(line, [
                "lineId", "order", "audioSourceId", "timeRange", "text", "words",
            ])
            try validateTimeRangeShape(line["timeRange"])
            let words = try dictionaries(line["words"])
            guard !words.isEmpty, wordCount <= 1_000_000 - words.count else {
                throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
            }
            wordCount += words.count
            for word in words {
                let required: Set<String> = [
                    "wordId", "ordinal", "text", "displayRange", "wordKind",
                ]
                let optional: Set<String> = ["timeRange", "confidence"]
                guard required.isSubset(of: Set(word.keys)),
                      Set(word.keys).isSubset(of: required.union(optional))
                else {
                    throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
                }
                let display = try dictionary(word["displayRange"])
                try requireExactKeys(display, ["startUtf8Byte", "endUtf8Byte"])
                if let timeRange = word["timeRange"] {
                    try validateTimeRangeShape(timeRange)
                }
                if let confidence = word["confidence"] {
                    guard let number = confidence as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID()
                    else {
                        throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
                    }
                }
            }
        }
        let events = try dictionaries(root["audioEvents"])
        guard events.count <= 100_000 else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        for event in events {
            try requireExactKeys(event, [
                "audioEventId", "category", "audioSourceId", "timeRange",
            ])
            try validateTimeRangeShape(event["timeRange"])
        }
    }

    func validateTimeRangeShape(_ value: Any?) throws {
        try requireExactKeys(try dictionary(value), ["startMs", "endMs"])
    }

    func dictionary(_ value: Any?) throws -> [String: Any] {
        guard let dictionary = value as? [String: Any] else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        return dictionary
    }

    func dictionaries(_ value: Any?) throws -> [[String: Any]] {
        guard let dictionaries = value as? [[String: Any]] else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        return dictionaries
    }

    func requireExactKeys(_ value: [String: Any], _ keys: Set<String>) throws {
        guard Set(value.keys) == keys else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
    }
}


private struct TranscriptRevisionDTO: Codable {
    let schemaVersion: UInt64
    let revisionId: String
    let sessionId: String
    let jobId: String
    let createdAt: String
    let durationMs: UInt64
    let audioFingerprintSha256: String
    let sourceFingerprints: [TranscriptSourceFingerprintDTO]
    let candidateArtifactSha256: String
    let engine: TranscriptEngineProvenanceDTO
    let lines: [PersistedTranscriptLineDTO]
    let audioEvents: [PersistedTranscriptAudioEventDTO]

    init(_ revision: TranscriptRevision) throws {
        guard revision.engine.qualification != nil else {
            throw TranscriptRevisionRepositoryFailure.writeFailed
        }
        schemaVersion = 2
        revisionId = revision.revisionID.rawValue
        sessionId = revision.sessionID.rawValue
        jobId = revision.jobID.rawValue
        createdAt = revision.createdAt.rawValue
        durationMs = revision.durationMilliseconds
        audioFingerprintSha256 = revision.audioFingerprint.sha256
        sourceFingerprints = revision.sourceFingerprints.map(
            TranscriptSourceFingerprintDTO.init
        )
        candidateArtifactSha256 = revision.candidateArtifactFingerprint.sha256
        engine = try TranscriptEngineProvenanceDTO(revision.engine)
        lines = revision.lines.map(PersistedTranscriptLineDTO.init)
        audioEvents = revision.audioEvents.map(PersistedTranscriptAudioEventDTO.init)
    }
}

private struct TranscriptSourceFingerprintDTO: Codable {
    let audioSourceId: String
    let sha256: String

    init(_ source: TranscriptSourceFingerprint) {
        audioSourceId = source.audioSourceID.rawValue
        sha256 = source.fingerprint.sha256
    }
}

private struct TranscriptEngineProvenanceDTO: Codable {
    let provider: String
    let model: String
    let revision: String
    let language: String
    let mode: String
    let decodingOptionsSha256: String
    let qualification: TranscriptEngineQualificationDTO?
    let usePolicy: TranscriptEngineUsePolicyDTO

    init(_ engine: TranscriptEngineProvenance) throws {
        guard let exactQualification = engine.qualification else {
            throw TranscriptRevisionRepositoryFailure.writeFailed
        }
        provider = engine.provider
        model = engine.model
        revision = engine.revision
        language = engine.language
        mode = engine.mode
        decodingOptionsSha256 = engine.decodingOptionsSHA256
        qualification = TranscriptEngineQualificationDTO(exactQualification)
        usePolicy = TranscriptEngineUsePolicyDTO(engine.usePolicy)
    }
}

private struct TranscriptEngineQualificationDTO: Codable {
    let schemaVersion: UInt32
    let qualificationProfileId: String
    let engineLockSha256: String
    let runtimeIdentity: String
    let runtimeLockSha256: String
    let compatibilityPatchId: String

    init(_ qualification: TranscriptEngineQualification) {
        schemaVersion = TranscriptEngineQualification.schemaVersion
        qualificationProfileId = qualification.qualificationProfileID
        engineLockSha256 = qualification.engineLockSHA256
        runtimeIdentity = qualification.runtimeIdentity
        runtimeLockSha256 = qualification.runtimeLockSHA256
        compatibilityPatchId = qualification.compatibilityPatchID
    }
}

private struct TranscriptEngineUsePolicyDTO: Codable {
    let policyId: String
    let coveredArtifacts: [String]
    let privateLocalUseAllowed: Bool
    let privateExportAllowed: Bool
    let externalProcessingAllowed: Bool
    let publicDistributionAllowed: Bool
    let commercialUseAllowed: Bool
    let licenseReference: String
    let licenseSha256: String

    init(_ policy: EngineUsePolicy) {
        policyId = policy.policyID
        coveredArtifacts = policy.coveredArtifacts.map(\.rawValue).sorted()
        privateLocalUseAllowed = policy.privateLocalUseAllowed
        privateExportAllowed = policy.privateExportAllowed
        externalProcessingAllowed = policy.externalProcessingAllowed
        publicDistributionAllowed = policy.publicDistributionAllowed
        commercialUseAllowed = policy.commercialUseAllowed
        licenseReference = policy.licenseReference
        licenseSha256 = policy.licenseSHA256
    }
}

private struct PersistedTranscriptLineDTO: Codable {
    let lineId: String
    let order: Int
    let audioSourceId: String
    let timeRange: SessionTimeRangeDTO
    let text: String
    let words: [PersistedTranscriptWordDTO]

    init(_ line: TranscriptLine) {
        lineId = line.lineID.rawValue
        order = line.order
        audioSourceId = line.audioSourceID.rawValue
        timeRange = SessionTimeRangeDTO(line.timeRange)
        text = line.text
        words = line.words.map(PersistedTranscriptWordDTO.init)
    }
}

private struct PersistedTranscriptWordDTO: Codable {
    let wordId: String
    let ordinal: Int
    let text: String
    let displayRange: LineTextRangeDTO
    let timeRange: SessionTimeRangeDTO?
    let confidence: Double?
    let wordKind: String

    init(_ word: TranscriptWord) {
        wordId = word.wordID.rawValue
        ordinal = word.ordinal
        text = word.text
        displayRange = LineTextRangeDTO(word.displayRange)
        timeRange = word.timeRange.map(SessionTimeRangeDTO.init)
        confidence = word.confidence
        wordKind = word.wordKind.rawValue
    }
}

private struct LineTextRangeDTO: Codable {
    let startUtf8Byte: Int
    let endUtf8Byte: Int

    init(_ range: LineTextRange) {
        startUtf8Byte = range.startUTF8Byte
        endUtf8Byte = range.endUTF8Byte
    }
}

private struct SessionTimeRangeDTO: Codable {
    let startMs: UInt64
    let endMs: UInt64

    init(_ range: SessionTimeRange) {
        startMs = range.startMilliseconds
        endMs = range.endMilliseconds
    }
}

private struct PersistedTranscriptAudioEventDTO: Codable {
    let audioEventId: String
    let category: String
    let audioSourceId: String
    let timeRange: SessionTimeRangeDTO

    init(_ event: TranscriptAudioEvent) {
        audioEventId = event.audioEventID.rawValue
        category = event.category.rawValue
        audioSourceId = event.audioSourceID.rawValue
        timeRange = SessionTimeRangeDTO(event.timeRange)
    }
}

private extension PortableTranscriptRevisionRepository {
    func decodeRevision(_ data: Data) throws -> TranscriptRevision {
        do {
            try validateRevisionJSONShape(data)
            let dto = try JSONDecoder().decode(TranscriptRevisionDTO.self, from: data)
            guard dto.schemaVersion == 1 || dto.schemaVersion == 2 else {
                throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
            }
            let usePolicyDTO = dto.engine.usePolicy
            let coveredArtifacts = usePolicyDTO.coveredArtifacts.compactMap(
                EngineCoveredArtifact.init(rawValue:)
            )
            guard coveredArtifacts.count == usePolicyDTO.coveredArtifacts.count,
                  Set(coveredArtifacts).count == coveredArtifacts.count
            else {
                throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
            }
            let usePolicy = try EngineUsePolicy(
                policyID: usePolicyDTO.policyId,
                coveredArtifacts: Set(coveredArtifacts),
                privateLocalUseAllowed: usePolicyDTO.privateLocalUseAllowed,
                privateExportAllowed: usePolicyDTO.privateExportAllowed,
                externalProcessingAllowed: usePolicyDTO.externalProcessingAllowed,
                publicDistributionAllowed: usePolicyDTO.publicDistributionAllowed,
                commercialUseAllowed: usePolicyDTO.commercialUseAllowed,
                licenseReference: usePolicyDTO.licenseReference,
                licenseSHA256: usePolicyDTO.licenseSha256
            )
            let engine: TranscriptEngineProvenance
            if dto.schemaVersion == 1 {
                guard dto.engine.qualification == nil else {
                    throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
                }
                engine = try TranscriptEngineProvenance.reopeningLegacyV1(
                    provider: dto.engine.provider,
                    model: dto.engine.model,
                    revision: dto.engine.revision,
                    language: dto.engine.language,
                    mode: dto.engine.mode,
                    decodingOptionsSHA256: dto.engine.decodingOptionsSha256,
                    usePolicy: usePolicy
                )
            } else {
                guard let qualificationDTO = dto.engine.qualification,
                      qualificationDTO.schemaVersion ==
                        TranscriptEngineQualification.schemaVersion
                else {
                    throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
                }
                let qualification = try TranscriptEngineQualification(
                    qualificationProfileID: qualificationDTO.qualificationProfileId,
                    engineLockSHA256: qualificationDTO.engineLockSha256,
                    runtimeIdentity: qualificationDTO.runtimeIdentity,
                    runtimeLockSHA256: qualificationDTO.runtimeLockSha256,
                    compatibilityPatchID: qualificationDTO.compatibilityPatchId
                )
                engine = try TranscriptEngineProvenance(
                    provider: dto.engine.provider,
                    model: dto.engine.model,
                    revision: dto.engine.revision,
                    language: dto.engine.language,
                    mode: dto.engine.mode,
                    decodingOptionsSHA256: dto.engine.decodingOptionsSha256,
                    qualification: qualification,
                    usePolicy: usePolicy
                )
            }
            return try TranscriptRevision(
                revisionID: TranscriptRevisionID(dto.revisionId),
                sessionID: SessionID(dto.sessionId),
                jobID: TranscriptionJobID(dto.jobId),
                createdAt: UTCInstant(dto.createdAt),
                durationMilliseconds: dto.durationMs,
                audioFingerprint: AudioFingerprint(
                    sha256: dto.audioFingerprintSha256
                ),
                sourceFingerprints: try dto.sourceFingerprints.map {
                    TranscriptSourceFingerprint(
                        audioSourceID: try AudioSourceID($0.audioSourceId),
                        fingerprint: try AudioFingerprint(sha256: $0.sha256)
                    )
                },
                candidateArtifactFingerprint: AudioFingerprint(
                    sha256: dto.candidateArtifactSha256
                ),
                engine: engine,
                lines: try dto.lines.map { line in
                    TranscriptLine(
                        lineID: try TranscriptLineID(line.lineId),
                        order: line.order,
                        audioSourceID: try AudioSourceID(line.audioSourceId),
                        timeRange: try decodeTimeRange(
                            line.timeRange,
                            durationMilliseconds: dto.durationMs
                        ),
                        text: line.text,
                        words: try line.words.map { word in
                            TranscriptWord(
                                wordID: try TranscriptWordID(word.wordId),
                                ordinal: word.ordinal,
                                text: word.text,
                                displayRange: LineTextRange(
                                    startUTF8Byte: word.displayRange.startUtf8Byte,
                                    endUTF8Byte: word.displayRange.endUtf8Byte
                                ),
                                timeRange: try word.timeRange.map {
                                    try decodeTimeRange(
                                        $0,
                                        durationMilliseconds: dto.durationMs
                                    )
                                },
                                confidence: word.confidence,
                                wordKind: try requireWordKind(word.wordKind)
                            )
                        }
                    )
                },
                audioEvents: try dto.audioEvents.map { event in
                    TranscriptAudioEvent(
                        audioEventID: try AudioEventID(event.audioEventId),
                        category: try requireAudioEventCategory(event.category),
                        audioSourceID: try AudioSourceID(event.audioSourceId),
                        timeRange: try decodeTimeRange(
                            event.timeRange,
                            durationMilliseconds: dto.durationMs
                        )
                    )
                }
            )
        } catch let failure as TranscriptRevisionRepositoryFailure {
            throw failure
        } catch {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
    }

    func decodeTimeRange(
        _ dto: SessionTimeRangeDTO,
        durationMilliseconds: UInt64
    ) throws -> SessionTimeRange {
        try SessionTimeRange(
            startMilliseconds: dto.startMs,
            endMilliseconds: dto.endMs,
            sessionDurationMilliseconds: durationMilliseconds
        )
    }

    func requireWordKind(_ value: String) throws -> TranscriptWordKind {
        guard let kind = TranscriptWordKind(rawValue: value) else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        return kind
    }

    func requireAudioEventCategory(
        _ value: String
    ) throws -> TranscriptAudioEventCategory {
        guard let category = TranscriptAudioEventCategory(rawValue: value) else {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
        return category
    }
}


private enum PortableSessionManifest {
    case recorded(
        RecordedSessionManifestDTO,
        revisionIDs: [TranscriptRevisionID],
        selected: SelectedTranscriptRevision?
    )
    case imported(
        ImportedSessionManifestDTO,
        revisionIDs: [TranscriptRevisionID],
        selected: SelectedTranscriptRevision?
    )

    var transcriptRevisionIDs: [TranscriptRevisionID] {
        switch self {
        case let .recorded(_, revisionIDs, _), let .imported(_, revisionIDs, _):
            revisionIDs
        }
    }

    var selectedTranscriptRevision: SelectedTranscriptRevision? {
        switch self {
        case let .recorded(_, _, selected), let .imported(_, _, selected):
            selected
        }
    }

    var selectedRevisionID: TranscriptRevisionID? {
        selectedTranscriptRevision?.revisionID
    }

    var chatDisplayLabel: String {
        switch self {
        case let .recorded(dto, _, _):
            "Session \(dto.createdAt) · \(dto.sessionId)"
        case let .imported(dto, _, _):
            "Session \(dto.createdAt) · \(dto.sessionId)"
        }
    }

    func selecting(_ selected: SelectedTranscriptRevision) throws -> Self {
        var revisionIDs = transcriptRevisionIDs
        if !revisionIDs.contains(selected.revisionID) {
            revisionIDs.append(selected.revisionID)
        }
        do {
            try SessionTranscriptSelectionValidator.validate(
                revisionIDs: revisionIDs,
                selected: selected
            )
        } catch {
            throw TranscriptRevisionRepositoryFailure.writeFailed
        }
        let rawRevisionIDs = revisionIDs.map(\.rawValue)
        let selectedDTO = SelectedTranscriptRevisionDTO(selected)
        switch self {
        case let .recorded(dto, _, _):
            return .recorded(
                RecordedSessionManifestDTO(
                    schemaVersion: dto.schemaVersion,
                    sessionId: dto.sessionId,
                    createdAt: dto.createdAt,
                    audioManifestPath: dto.audioManifestPath,
                    transcriptRevisionIds: rawRevisionIDs,
                    selectedTranscriptRevision: selectedDTO
                ),
                revisionIDs: revisionIDs,
                selected: selected
            )
        case let .imported(dto, _, _):
            return .imported(
                ImportedSessionManifestDTO(
                    schemaVersion: dto.schemaVersion,
                    sessionId: dto.sessionId,
                    createdAt: dto.createdAt,
                    durationMs: dto.durationMs,
                    audioManifestSha256: dto.audioManifestSha256,
                    transcriptRevisionIds: rawRevisionIDs,
                    selectedTranscriptRevision: selectedDTO
                ),
                revisionIDs: revisionIDs,
                selected: selected
            )
        }
    }
}

private struct SelectedTranscriptRevisionDTO: Codable {
    let revisionId: String
    let revisionSha256: String

    init(_ selected: SelectedTranscriptRevision) {
        revisionId = selected.revisionID.rawValue
        revisionSha256 = selected.revisionSHA256
    }
}

private struct RecordedSessionManifestDTO: Codable {
    let schemaVersion: UInt64
    let sessionId: String
    let createdAt: String
    let audioManifestPath: String
    let transcriptRevisionIds: [String]
    let selectedTranscriptRevision: SelectedTranscriptRevisionDTO?
}

private struct ImportedSessionManifestDTO: Codable {
    let schemaVersion: UInt64
    let sessionId: String
    let createdAt: String
    let durationMs: UInt64
    let audioManifestSha256: String
    let transcriptRevisionIds: [String]
    let selectedTranscriptRevision: SelectedTranscriptRevisionDTO?
}

private extension PortableTranscriptRevisionRepository {
    func validatedManifest(
        _ dto: RecordedSessionManifestDTO
    ) throws -> PortableSessionManifest {
        let (revisionIDs, selected) = try validatedSelection(
            revisionIDs: dto.transcriptRevisionIds,
            selected: dto.selectedTranscriptRevision
        )
        return .recorded(dto, revisionIDs: revisionIDs, selected: selected)
    }

    func validatedManifest(
        _ dto: ImportedSessionManifestDTO
    ) throws -> PortableSessionManifest {
        let (revisionIDs, selected) = try validatedSelection(
            revisionIDs: dto.transcriptRevisionIds,
            selected: dto.selectedTranscriptRevision
        )
        return .imported(dto, revisionIDs: revisionIDs, selected: selected)
    }

    func validatedSelection(
        revisionIDs rawRevisionIDs: [String],
        selected rawSelected: SelectedTranscriptRevisionDTO?
    ) throws -> ([TranscriptRevisionID], SelectedTranscriptRevision?) {
        do {
            let revisionIDs = try rawRevisionIDs.map(TranscriptRevisionID.init)
            let selected = try rawSelected.map {
                try SelectedTranscriptRevision(
                    revisionID: TranscriptRevisionID($0.revisionId),
                    revisionSHA256: $0.revisionSha256
                )
            }
            try SessionTranscriptSelectionValidator.validate(
                revisionIDs: revisionIDs,
                selected: selected
            )
            return (revisionIDs, selected)
        } catch {
            throw TranscriptRevisionRepositoryFailure.sessionIntegrityMismatch
        }
    }
}
