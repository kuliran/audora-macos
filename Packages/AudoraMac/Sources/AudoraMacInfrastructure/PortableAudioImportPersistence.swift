import AudoraApplication
import AudoraDomain
import CryptoKit
import Darwin
import Foundation

enum AudioImportPersistenceFault: Hashable, Sendable {
    case stagingCreated
    case beforeSourceFinalValidation
    case afterSourceCopy
    case afterCanonicalWrite
    case afterAudioManifestInstall
    case afterSessionManifestInstall
    case beforeStagedValidation
    case beforeSessionInstall
    case afterSessionInstall
    case beforeFinalReopen
}

enum AudioImportCapacity: Equatable, Sendable {
    case available(UInt64)
    case unavailable
}

enum LoadedImportedSession: Equatable, Sendable {
    case readWrite(ImportedSession)
    case readOnly(sessionID: SessionID?)
}

final class AudioImportStagingLocation: @unchecked Sendable {
    let root: URL
    let rootDescriptor: Int32
    let stagingID: AudioStagingID
    let libraryID: LibraryID
    let sessionID: SessionID
    let container: ImportedAudioContainer
    private let lock = NSLock()
    private var closed = false

    init(
        root: URL,
        rootDescriptor: Int32,
        stagingID: AudioStagingID,
        libraryID: LibraryID,
        sessionID: SessionID,
        container: ImportedAudioContainer
    ) {
        self.root = root
        self.rootDescriptor = rootDescriptor
        self.stagingID = stagingID
        self.libraryID = libraryID
        self.sessionID = sessionID
        self.container = container
    }

    var stagedSessionComponents: [String] {
        ["staging", "publications", stagingID.rawValue, sessionID.rawValue]
    }

    var originalRelativeName: String { "original.\(container.rawValue)" }

    var originalURL: URL {
        root
            .appendingPathComponent("staging/publications")
            .appendingPathComponent(stagingID.rawValue)
            .appendingPathComponent(sessionID.rawValue)
            .appendingPathComponent("audio")
            .appendingPathComponent(originalRelativeName)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(rootDescriptor)
    }

    deinit { close() }
}

final class OpenedAudioImportSource: @unchecked Sendable {
    let descriptor: Int32
    let metadata: stat
    let container: ImportedAudioContainer
    private let lock = NSLock()
    private var closed = false

    init(descriptor: Int32, metadata: stat, container: ImportedAudioContainer) {
        self.descriptor = descriptor
        self.metadata = metadata
        self.container = container
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(descriptor)
    }

    deinit { close() }
}

struct PortableAudioImportPersistence: @unchecked Sendable {
    static let maximumManifestBytes = 65_536
    static let canonicalWAVHeaderBytes = 44

    private let fault: @Sendable (AudioImportPersistenceFault) throws -> Void
    private let capacityProbe: @Sendable (Int32) -> AudioImportCapacity

    init(
        fault: @escaping @Sendable (AudioImportPersistenceFault) throws -> Void = { _ in }
    ) {
        self.fault = fault
        capacityProbe = Self.descriptorCapacity
    }

    init(capacity: @escaping @Sendable (Int32) -> AudioImportCapacity) {
        fault = { _ in }
        capacityProbe = capacity
    }

    private var confinedRead: ConfinedPersistencePrimitives<AudioImportFailure> {
        ConfinedPersistencePrimitives(
            ioFailure: .candidateCorrupt,
            invalidLayout: .candidateCorrupt,
            expectedPathIsSymlink: .candidateCorrupt,
            rootTooLarge: .candidateCorrupt,
            invalidJSON: .candidateCorrupt,
            invalidSchemaVersion: .candidateCorrupt,
            unknownKey: .candidateCorrupt
        )
    }

    private var confinedWrite: ConfinedPersistencePrimitives<AudioImportFailure> {
        ConfinedPersistencePrimitives(
            ioFailure: .writeFailed,
            invalidLayout: .candidateCorrupt,
            expectedPathIsSymlink: .candidateCorrupt,
            rootTooLarge: .candidateCorrupt,
            invalidJSON: .candidateCorrupt,
            invalidSchemaVersion: .candidateCorrupt,
            unknownKey: .candidateCorrupt
        )
    }

    func sessionIDIsAvailable(
        at root: URL,
        libraryID: LibraryID,
        sessionID: SessionID
    ) throws -> Bool {
        let rootDescriptor = try openDirectory(at: root)
        defer { Darwin.close(rootDescriptor) }
        try requireWritableLibrary(
            rootDescriptor: rootDescriptor,
            libraryID: libraryID
        )
        let sessions = try openDirectory(
            components: ["sessions"],
            under: rootDescriptor
        )
        defer { Darwin.close(sessions) }
        let exists = try confinedRead.entryExists(
            named: sessionID.rawValue,
            under: sessions
        )
        return !exists
    }

    func begin(
        root: URL,
        stagingID: AudioStagingID,
        seed: ImportedSessionSeed,
        container: ImportedAudioContainer
    ) throws -> AudioImportStagingLocation {
        let rootDescriptor = try openDirectory(at: root)
        let location = AudioImportStagingLocation(
            root: root,
            rootDescriptor: rootDescriptor,
            stagingID: stagingID,
            libraryID: seed.scope.libraryID,
            sessionID: seed.sessionID,
            container: container
        )
        do {
            try requireWritableLibrary(location)
            let publications = try openDirectory(
                components: ["staging", "publications"],
                under: rootDescriptor
            )
            defer { Darwin.close(publications) }
            guard mkdirat(publications, stagingID.rawValue, 0o700) == 0 else {
                if errno == EEXIST { throw AudioImportFailure.destinationCollision }
                throw AudioImportFailure.writeFailed
            }
            let transaction = try openDirectory(
                components: [stagingID.rawValue],
                under: publications
            )
            defer { Darwin.close(transaction) }
            try makeDirectory(seed.sessionID.rawValue, under: transaction)
            let session = try openDirectory(
                components: [seed.sessionID.rawValue],
                under: transaction
            )
            defer { Darwin.close(session) }
            for name in ["audio", "transcripts", "annotations"] {
                try makeDirectory(name, under: session)
            }
            try flush(transaction)
            try flush(publications)
            try fault(.stagingCreated)
            return location
        } catch {
            discard(location)
            location.close()
            throw error
        }
    }

    func openSource(
        at source: URL,
        maximumBytes: UInt64
    ) throws -> OpenedAudioImportSource {
        let descriptor = source.path.withCString { pointer -> Int32 in
            while true {
                let result = Darwin.open(
                    pointer,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard descriptor >= 0 else { throw AudioImportFailure.unavailable }
        var shouldClose = true
        defer { if shouldClose { Darwin.close(descriptor) } }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_size > 0,
              UInt64(initial.st_size) <= maximumBytes
        else {
            if initial.st_size > 0, UInt64(initial.st_size) > maximumBytes {
                throw AudioImportFailure.sourceTooLarge
            }
            throw AudioImportFailure.unsupportedMedia
        }
        var prefix = [UInt8](repeating: 0, count: min(16, Int(initial.st_size)))
        guard preadAll(descriptor, into: &prefix, offset: 0),
              let container = detectedContainer(prefix)
        else {
            throw AudioImportFailure.unsupportedMedia
        }
        shouldClose = false
        return OpenedAudioImportSource(
            descriptor: descriptor,
            metadata: initial,
            container: container
        )
    }

    func copySource(
        from source: URL,
        into location: AudioImportStagingLocation,
        maximumBytes: UInt64
    ) throws -> AudioArtifactFingerprint {
        let opened = try openSource(at: source, maximumBytes: maximumBytes)
        defer { opened.close() }
        guard opened.container == location.container else {
            throw AudioImportFailure.unsupportedMedia
        }
        return try copySource(from: opened, into: location, maximumBytes: maximumBytes)
    }

    func copySource(
        from source: OpenedAudioImportSource,
        into location: AudioImportStagingLocation,
        maximumBytes: UInt64
    ) throws -> AudioArtifactFingerprint {
        let sourceDescriptor = source.descriptor
        let initial = source.metadata
        guard source.container == location.container,
              UInt64(initial.st_size) <= maximumBytes,
              lseek(sourceDescriptor, 0, SEEK_SET) == 0
        else {
            throw AudioImportFailure.candidateCorrupt
        }

        let audioDirectory = try openDirectory(
            components: location.stagedSessionComponents + ["audio"],
            under: location.rootDescriptor
        )
        defer { Darwin.close(audioDirectory) }
        let destination = try openExclusiveFile(
            named: location.originalRelativeName,
            under: audioDirectory
        )
        var destinationOpen = true
        defer { if destinationOpen { Darwin.close(destination) } }

        var hasher = SHA256()
        var copied: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.read(sourceDescriptor, base, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw AudioImportFailure.unavailable
            }
            copied += UInt64(count)
            guard copied <= maximumBytes, copied <= UInt64(initial.st_size) else {
                throw AudioImportFailure.sourceChanged
            }
            let chunk = Data(buffer[0..<count])
            hasher.update(data: chunk)
            try writeAll(chunk, to: destination)
        }
        guard copied == UInt64(initial.st_size) else {
            throw AudioImportFailure.sourceChanged
        }
        try fault(.beforeSourceFinalValidation)
        var final = stat()
        guard fstat(sourceDescriptor, &final) == 0,
              sameSource(initial, final)
        else {
            throw AudioImportFailure.sourceChanged
        }
        try flush(destination)
        guard Darwin.close(destination) == 0 else {
            destinationOpen = false
            throw AudioImportFailure.writeFailed
        }
        destinationOpen = false
        try flush(audioDirectory)
        try fault(.afterSourceCopy)
        let digest = Self.hexDigest(hasher.finalize())
        return try AudioArtifactFingerprint(byteCount: copied, sha256: digest)
    }

    func createCanonicalDescriptor(
        in location: AudioImportStagingLocation
    ) throws -> Int32 {
        let audioDirectory = try openDirectory(
            components: location.stagedSessionComponents + ["audio"],
            under: location.rootDescriptor
        )
        defer { Darwin.close(audioDirectory) }
        return try openExclusiveFile(named: "audio.wav", under: audioDirectory)
    }

    func openOriginalForDecoding(
        in location: AudioImportStagingLocation,
        expected: AudioArtifactFingerprint
    ) throws -> OwnedAudioFile {
        let audioDirectory = try openDirectory(
            components: location.stagedSessionComponents + ["audio"],
            under: location.rootDescriptor
        )
        defer { Darwin.close(audioDirectory) }
        let descriptor = try openRegularFile(
            named: location.originalRelativeName,
            under: audioDirectory,
            nonblocking: true
        )
        do {
            guard try fingerprint(
                descriptor: descriptor,
                maximumBytes: expected.byteCount
            ) == expected else {
                throw AudioImportFailure.candidateCorrupt
            }
            guard lseek(descriptor, 0, SEEK_SET) == 0 else {
                throw AudioImportFailure.candidateCorrupt
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return OwnedAudioFile(
            takingOwnershipOf: descriptor,
            byteCount: Int64(expected.byteCount)
        )
    }

    func didFinishCanonicalWrite(in location: AudioImportStagingLocation) throws {
        let audioDirectory = try openDirectory(
            components: location.stagedSessionComponents + ["audio"],
            under: location.rootDescriptor
        )
        defer { Darwin.close(audioDirectory) }
        try flush(audioDirectory)
        try fault(.afterCanonicalWrite)
    }

    func availableCapacity(at location: AudioImportStagingLocation) -> AudioImportCapacity {
        capacityProbe(location.rootDescriptor)
    }

    private static func descriptorCapacity(_ descriptor: Int32) -> AudioImportCapacity {
        var statistics = statvfs()
        var result: Int32
        repeat {
            result = fstatvfs(descriptor, &statistics)
        } while result != 0 && errno == EINTR
        guard result == 0 else { return .unavailable }
        let (bytes, overflow) = UInt64(statistics.f_bavail).multipliedReportingOverflow(
            by: UInt64(statistics.f_frsize)
        )
        guard !overflow else { return .unavailable }
        return .available(bytes)
    }

    func fingerprint(
        components: [String],
        under location: AudioImportStagingLocation,
        maximumBytes: UInt64
    ) throws -> AudioArtifactFingerprint {
        try fingerprint(
            components: components,
            under: location.rootDescriptor,
            maximumBytes: maximumBytes
        )
    }

    func writeManifests(
        for session: ImportedSession,
        in location: AudioImportStagingLocation
    ) throws -> ImportedSession {
        let audioData = try encodeAudioManifest(session.audio)
        let audioHash = Self.sha256(audioData)
        let rebound = try ImportedSession(
            sessionID: session.sessionID,
            createdAt: session.createdAt,
            durationMilliseconds: session.durationMilliseconds,
            audioManifestSHA256: audioHash,
            audio: session.audio
        )
        try writeRoot(
            audioData,
            named: "audio.json",
            parentComponents: location.stagedSessionComponents + ["audio"],
            under: location.rootDescriptor
        )
        try fault(.afterAudioManifestInstall)
        try writeRoot(
            encodeSessionManifest(rebound),
            named: "session.json",
            parentComponents: location.stagedSessionComponents,
            under: location.rootDescriptor
        )
        try fault(.afterSessionManifestInstall)
        return rebound
    }

    func validateStaged(
        _ location: AudioImportStagingLocation,
        expected: ImportedSession
    ) throws -> ImportedSession {
        try fault(.beforeStagedValidation)
        let loaded = try loadSession(
            components: location.stagedSessionComponents,
            under: location.rootDescriptor,
            expectedSessionID: location.sessionID
        )
        guard case let .readWrite(session) = loaded, session == expected else {
            throw AudioImportFailure.candidateCorrupt
        }
        return session
    }

    func install(
        _ location: AudioImportStagingLocation,
        expected: ImportedSession
    ) throws -> ReopenedImportedSessionSnapshot {
        let transaction = try openDirectory(
            components: ["staging", "publications", location.stagingID.rawValue],
            under: location.rootDescriptor
        )
        defer { Darwin.close(transaction) }
        let stagedSession = try openDirectory(
            components: [location.sessionID.rawValue],
            under: transaction
        )
        defer { Darwin.close(stagedSession) }
        let stagedIdentity = try directoryIdentity(stagedSession)
        let revalidated = try loadSession(
            components: [],
            under: stagedSession,
            expectedSessionID: location.sessionID
        )
        guard case let .readWrite(staged) = revalidated, staged == expected else {
            throw AudioImportFailure.candidateCorrupt
        }
        try fault(.beforeSessionInstall)
        try requireWritableLibrary(location)
        guard try entryIdentity(
            named: location.sessionID.rawValue,
            under: transaction
        ) == stagedIdentity else {
            throw AudioImportFailure.candidateCorrupt
        }
        let sessions = try openDirectory(
            components: ["sessions"],
            under: location.rootDescriptor
        )
        defer { Darwin.close(sessions) }
        try confinedWrite.renameNoReplace(
            from: location.sessionID.rawValue,
            under: transaction,
            to: location.sessionID.rawValue,
            under: sessions,
            collision: .destinationCollision
        )
        do {
            guard try entryIdentity(
                named: location.sessionID.rawValue,
                under: sessions
            ) == stagedIdentity else {
                throw AudioImportFailure.installedNeedsRefresh
            }
            try flush(sessions)
            try fault(.afterSessionInstall)
            let publications = try openDirectory(
                components: ["staging", "publications"],
                under: location.rootDescriptor
            )
            defer { Darwin.close(publications) }
            guard unlinkat(
                publications,
                location.stagingID.rawValue,
                AT_REMOVEDIR
            ) == 0 else {
                throw AudioImportFailure.installedNeedsRefresh
            }
            try flush(publications)
            try fault(.beforeFinalReopen)
            let finalSession = try openDirectory(
                components: [location.sessionID.rawValue],
                under: sessions
            )
            defer { Darwin.close(finalSession) }
            guard try directoryIdentity(finalSession) == stagedIdentity else {
                throw AudioImportFailure.installedNeedsRefresh
            }
            let final = try loadSession(
                components: [],
                under: finalSession,
                expectedSessionID: location.sessionID
            )
            guard case let .readWrite(session) = final, session == expected else {
                throw AudioImportFailure.installedNeedsRefresh
            }
            return ReopenedImportedSessionSnapshot(session: session)
        } catch AudioImportFailure.installedNeedsRefresh {
            throw AudioImportFailure.installedNeedsRefresh
        } catch {
            throw AudioImportFailure.installedNeedsRefresh
        }
    }

    func openSession(
        at root: URL,
        sessionID: SessionID
    ) throws -> LoadedImportedSession {
        let rootDescriptor = try openDirectory(at: root)
        defer { Darwin.close(rootDescriptor) }
        return try loadSession(
            components: ["sessions", sessionID.rawValue],
            under: rootDescriptor,
            expectedSessionID: sessionID
        )
    }

    /// Removes only bounded, exact v1 import publication trees. Anything that
    /// is unknown, too large to inspect, or carries a newer root version stays
    /// byte-identical for a newer Audora to understand.
    func reconcileAbandonedStaging(under rootDescriptor: Int32) {
        guard let publications = try? openDirectory(
            components: ["staging", "publications"],
            under: rootDescriptor
        ) else {
            return
        }
        defer { Darwin.close(publications) }
        guard let transactionNames = try? confinedRead.listEntryNames(
            under: publications,
            maximumCount: 128
        ) else {
            return
        }

        for transactionName in transactionNames where Self.isGeneratedStagingName(transactionName) {
            guard let transaction = try? confinedRead.openDirectory(
                named: transactionName,
                under: publications
            ) else {
                continue
            }
            defer { Darwin.close(transaction) }
            guard let entries = try? confinedRead.listEntryNames(
                under: transaction,
                maximumCount: 8
            ), entries.count == 1,
                let sessionName = entries.first,
                (try? SessionID(sessionName)) != nil,
                let session = try? confinedRead.openDirectory(
                    named: sessionName,
                    under: transaction
                )
            else {
                continue
            }
            let reclaimable = canReconcileAbandonedSession(session)
            Darwin.close(session)
            guard reclaimable else { continue }
            removeReconciledSession(
                named: sessionName,
                under: transaction
            )
            guard unlinkat(publications, transactionName, AT_REMOVEDIR) == 0 else {
                continue
            }
            try? flush(publications)
        }
    }

    private func canReconcileAbandonedSession(_ session: Int32) -> Bool {
        guard let entries = try? confinedRead.listEntryNames(
            under: session,
            maximumCount: 16
        ) else {
            return false
        }
        for name in entries {
            switch name {
            case "session.json":
                guard isCurrentOrIncompleteManifest(named: name, under: session) else {
                    return false
                }
            case "audio":
                guard let audio = try? confinedRead.openDirectory(named: name, under: session)
                else { return false }
                let safe = canReconcileAudioDirectory(audio)
                Darwin.close(audio)
                guard safe else { return false }
            case "transcripts", "annotations":
                guard let directory = try? confinedRead.openDirectory(named: name, under: session)
                else { return false }
                let children = try? confinedRead.listEntryNames(
                    under: directory,
                    maximumCount: 1
                )
                Darwin.close(directory)
                guard children?.isEmpty == true else { return false }
            default:
                guard Self.isManifestPartial(name, rootName: "session.json"),
                      isCurrentOrIncompleteManifest(named: name, under: session)
                else {
                    return false
                }
            }
        }
        return true
    }

    private func canReconcileAudioDirectory(_ audio: Int32) -> Bool {
        guard let entries = try? confinedRead.listEntryNames(
            under: audio,
            maximumCount: 16
        ) else {
            return false
        }
        for name in entries {
            switch name {
            case "audio.json":
                guard isCurrentOrIncompleteManifest(named: name, under: audio) else {
                    return false
                }
            case "audio.wav", "original.wav", "original.m4a":
                guard isBoundedRegularFile(named: name, under: audio) else {
                    return false
                }
            default:
                guard Self.isManifestPartial(name, rootName: "audio.json"),
                      isCurrentOrIncompleteManifest(named: name, under: audio)
                else {
                    return false
                }
            }
        }
        return true
    }

    private func isCurrentOrIncompleteManifest(named name: String, under parent: Int32) -> Bool {
        guard let size = regularFileSize(named: name, under: parent),
              size <= UInt64(Self.maximumManifestBytes),
              let data = try? confinedRead.boundedData(
                  named: name,
                  under: parent,
                  maximumBytes: Self.maximumManifestBytes
              )
        else {
            return false
        }
        guard let version = try? confinedRead.schemaVersion(in: data) else {
            return true
        }
        return version == 1
    }

    private func isBoundedRegularFile(named name: String, under parent: Int32) -> Bool {
        guard let size = regularFileSize(named: name, under: parent) else { return false }
        return size <= AudioImportPolicy.versionOne.maximumSourceBytes
    }

    private func regularFileSize(named name: String, under parent: Int32) -> UInt64? {
        var metadata = stat()
        let result = name.withCString {
            fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0
        else {
            return nil
        }
        return UInt64(metadata.st_size)
    }

    private func removeReconciledSession(named sessionName: String, under transaction: Int32) {
        guard let session = try? confinedRead.openDirectory(named: sessionName, under: transaction)
        else { return }
        if let names = try? confinedRead.listEntryNames(under: session, maximumCount: 16) {
            for name in names where name == "session.json" ||
                Self.isManifestPartial(name, rootName: "session.json")
            {
                _ = unlinkat(session, name, 0)
            }
        }
        if let audio = try? confinedRead.openDirectory(named: "audio", under: session) {
            if let names = try? confinedRead.listEntryNames(under: audio, maximumCount: 16) {
                for name in names {
                    _ = unlinkat(audio, name, 0)
                }
            }
            Darwin.close(audio)
            _ = unlinkat(session, "audio", AT_REMOVEDIR)
        }
        for name in ["transcripts", "annotations"] {
            _ = unlinkat(session, name, AT_REMOVEDIR)
        }
        Darwin.close(session)
        _ = unlinkat(transaction, sessionName, AT_REMOVEDIR)
    }

    private static func isGeneratedStagingName(_ name: String) -> Bool {
        let prefix = "audio_staging_"
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        return suffix.utf8.count == 32 && suffix.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70)
        }
    }

    private static func isManifestPartial(_ name: String, rootName: String) -> Bool {
        let prefix = ".\(rootName)."
        let suffix = ".partial"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let uuidStart = name.index(name.startIndex, offsetBy: prefix.count)
        let uuidEnd = name.index(name.endIndex, offsetBy: -suffix.count)
        return UUID(uuidString: String(name[uuidStart..<uuidEnd])) != nil
    }

    func discard(_ location: AudioImportStagingLocation) {
        let rootDescriptor = location.rootDescriptor
        guard let transaction = try? openDirectory(
            components: ["staging", "publications", location.stagingID.rawValue],
            under: rootDescriptor
        ) else {
            return
        }
        if let session = try? openDirectory(
            components: [location.sessionID.rawValue],
            under: transaction
        ) {
            if let audio = try? openDirectory(components: ["audio"], under: session) {
                for file in [
                    location.originalRelativeName,
                    "audio.wav",
                    "audio.json",
                ] {
                    _ = unlinkat(audio, file, 0)
                }
                Darwin.close(audio)
            }
            _ = unlinkat(session, "session.json", 0)
            for directory in ["audio", "transcripts", "annotations"] {
                _ = unlinkat(session, directory, AT_REMOVEDIR)
            }
            Darwin.close(session)
            _ = unlinkat(transaction, location.sessionID.rawValue, AT_REMOVEDIR)
        }
        Darwin.close(transaction)
        if let publications = try? openDirectory(
            components: ["staging", "publications"],
            under: rootDescriptor
        ) {
            _ = unlinkat(publications, location.stagingID.rawValue, AT_REMOVEDIR)
            try? flush(publications)
            Darwin.close(publications)
        }
    }

    func encodeAudioManifest(_ audio: ImportedAudioAsset) throws -> Data {
        let original = audio.original
        let canonical = audio.canonical
        let source = audio.sources[0]
        return try deterministicJSON(
            AudioManifestDTO(
                schemaVersion: 1,
                acquisitionKind: "imported",
                original: OriginalAudioDTO(
                    relativePath: original.relativePath.description,
                    container: original.container.rawValue,
                    byteCount: original.fingerprint.byteCount,
                    sha256: original.fingerprint.sha256,
                    decodedCodec: original.decodedCodec.rawValue,
                    sourceSampleRateHz: original.sourceSampleRateHz,
                    sourceChannelCount: original.sourceChannelCount
                ),
                canonical: CanonicalAudioDTO(
                    relativePath: canonical.relativePath.description,
                    byteCount: canonical.fingerprint.byteCount,
                    sha256: canonical.fingerprint.sha256,
                    frameCount: canonical.frameCount,
                    durationMs: canonical.durationMilliseconds,
                    container: canonical.format.container,
                    encoding: canonical.format.encoding.rawValue,
                    sampleRateHz: canonical.format.sampleRateHz,
                    channelCount: canonical.format.channelCount,
                    bitsPerSample: canonical.format.bitsPerSample
                ),
                sources: [
                    AudioSourceDTO(
                        audioSourceId: source.audioSourceID.rawValue,
                        role: source.role.rawValue,
                        timelineOffsetMs: source.timelineOffsetMilliseconds
                    ),
                ],
                normalization: NormalizationDTO(
                    algorithmId: audio.normalization.algorithmID,
                    algorithmVersion: audio.normalization.algorithmVersion,
                    stereoRule: audio.normalization.stereoRule,
                    resamplerVersion: audio.normalization.resamplerVersion,
                    quantizerVersion: audio.normalization.quantizerVersion
                )
            )
        )
    }

    func encodeSessionManifest(_ session: ImportedSession) throws -> Data {
        try deterministicJSON(
            SessionManifestDTO(
                schemaVersion: 1,
                sessionId: session.sessionID.rawValue,
                createdAt: session.createdAt.rawValue,
                durationMs: session.durationMilliseconds,
                audioManifestSha256: session.audioManifestSHA256,
                transcriptRevisionIds: []
            )
        )
    }

    private func loadSession(
        components: [String],
        under rootDescriptor: Int32,
        expectedSessionID: SessionID
    ) throws -> LoadedImportedSession {
        let sessionData = try boundedFileData(
            components: components + ["session.json"],
            under: rootDescriptor,
            maximumBytes: UInt64(Self.maximumManifestBytes)
        )
        let sessionVersion = try schemaVersion(sessionData)
        guard sessionVersion >= 1 else {
            throw AudioImportFailure.candidateCorrupt
        }
        let identity = try decode(SessionIdentityEnvelopeDTO.self, sessionData)
        guard (try? SessionID(identity.sessionId)) != nil,
              identity.sessionId == expectedSessionID.rawValue
        else {
            throw AudioImportFailure.candidateCorrupt
        }
        if sessionVersion > 1 {
            return .readOnly(sessionID: expectedSessionID)
        }

        let sessionDTO = try decodeSession(sessionData)
        let audioData = try boundedFileData(
            components: components + ["audio", "audio.json"],
            under: rootDescriptor,
            maximumBytes: UInt64(Self.maximumManifestBytes)
        )
        let audioVersion = try schemaVersion(audioData)
        guard audioVersion >= 1 else {
            throw AudioImportFailure.candidateCorrupt
        }
        guard sessionDTO.audioManifestSha256 == Self.sha256(audioData) else {
            throw AudioImportFailure.candidateCorrupt
        }
        if audioVersion > 1 {
            return .readOnly(sessionID: expectedSessionID)
        }
        let audio = try decodeAudio(audioData)
        guard sessionDTO.sessionId == expectedSessionID.rawValue,
              sessionDTO.durationMs == audio.canonical.durationMilliseconds
        else {
            throw AudioImportFailure.candidateCorrupt
        }
        let original = try fingerprint(
            components: components + ["audio", audio.original.relativePath.components.last!],
            under: rootDescriptor,
            maximumBytes: audio.original.fingerprint.byteCount
        )
        let canonical = try fingerprint(
            components: components + ["audio", "audio.wav"],
            under: rootDescriptor,
            maximumBytes: audio.canonical.fingerprint.byteCount
        )
        guard original == audio.original.fingerprint,
              canonical == audio.canonical.fingerprint
        else {
            throw AudioImportFailure.candidateCorrupt
        }
        try validateCanonicalWAV(
            components: components + ["audio", "audio.wav"],
            under: rootDescriptor,
            expected: audio.canonical
        )
        do {
            return .readWrite(
                try ImportedSession(
                    sessionID: expectedSessionID,
                    createdAt: UTCInstant(sessionDTO.createdAt),
                    durationMilliseconds: sessionDTO.durationMs,
                    audioManifestSHA256: sessionDTO.audioManifestSha256,
                    audio: audio
                )
            )
        } catch {
            throw AudioImportFailure.candidateCorrupt
        }
    }

    private func requireWritableLibrary(_ location: AudioImportStagingLocation) throws {
        try requireWritableLibrary(
            rootDescriptor: location.rootDescriptor,
            libraryID: location.libraryID
        )
    }

    private func requireWritableLibrary(
        rootDescriptor: Int32,
        libraryID: LibraryID
    ) throws {
        do {
            let loaded = try PortableLibraryPersistence().load(
                from: rootDescriptor,
                reconcileAbandonedImports: false
            )
            guard case let .readWrite(authority) = loaded,
                  authority.manifest.libraryID == libraryID
            else {
                throw AudioImportFailure.libraryChanged
            }
        } catch let failure as AudioImportFailure {
            throw failure
        } catch {
            throw AudioImportFailure.candidateCorrupt
        }
    }

    private func decodeSession(_ data: Data) throws -> SessionManifestDTO {
        let dictionary = try jsonDictionary(data)
        guard Set(dictionary.keys) == Set([
            "schemaVersion",
            "sessionId",
            "createdAt",
            "durationMs",
            "audioManifestSha256",
            "transcriptRevisionIds",
        ]) else {
            throw AudioImportFailure.candidateCorrupt
        }
        let dto: SessionManifestDTO = try decode(SessionManifestDTO.self, data)
        guard dto.schemaVersion == 1,
              dto.durationMs > 0,
              dto.durationMs <= 2_700_000,
              dto.transcriptRevisionIds.isEmpty,
              (try? SessionID(dto.sessionId)) != nil,
              (try? UTCInstant(dto.createdAt)) != nil,
              AudioArtifactFingerprint.isSHA256(dto.audioManifestSha256)
        else {
            throw AudioImportFailure.candidateCorrupt
        }
        return dto
    }

    private func decodeAudio(_ data: Data) throws -> ImportedAudioAsset {
        do {
            return try decodeAudioValidated(data)
        } catch let failure as AudioImportFailure {
            throw failure
        } catch {
            throw AudioImportFailure.candidateCorrupt
        }
    }

    private func decodeAudioValidated(_ data: Data) throws -> ImportedAudioAsset {
        let dictionary = try jsonDictionary(data)
        guard Set(dictionary.keys) == Set([
            "schemaVersion", "acquisitionKind", "original", "canonical", "sources",
            "normalization",
        ]),
            let originalDictionary = dictionary["original"] as? [String: Any],
            Set(originalDictionary.keys) == Set([
                "relativePath", "container", "byteCount", "sha256", "decodedCodec",
                "sourceSampleRateHz", "sourceChannelCount",
            ]),
            let canonicalDictionary = dictionary["canonical"] as? [String: Any],
            Set(canonicalDictionary.keys) == Set([
                "relativePath", "byteCount", "sha256", "frameCount", "durationMs",
                "container", "encoding", "sampleRateHz", "channelCount", "bitsPerSample",
            ]),
            let sourceDictionaries = dictionary["sources"] as? [[String: Any]],
            sourceDictionaries.count == 1,
            Set(sourceDictionaries[0].keys) == Set([
                "audioSourceId", "role", "timelineOffsetMs",
            ]),
            let normalizationDictionary = dictionary["normalization"] as? [String: Any],
            Set(normalizationDictionary.keys) == Set([
                "algorithmId", "algorithmVersion", "stereoRule", "resamplerVersion",
                "quantizerVersion",
            ])
        else {
            throw AudioImportFailure.candidateCorrupt
        }
        let dto: AudioManifestDTO = try decode(AudioManifestDTO.self, data)
        guard dto.schemaVersion == 1,
              dto.acquisitionKind == "imported",
              let container = ImportedAudioContainer(rawValue: dto.original.container),
              let codec = DecodedAudioCodec(rawValue: dto.original.decodedCodec),
              let role = AudioSourceRole(rawValue: dto.sources[0].role),
              let normalization = AudioNormalizationProvenance(
                  algorithmID: dto.normalization.algorithmId,
                  algorithmVersion: dto.normalization.algorithmVersion,
                  stereoRule: dto.normalization.stereoRule,
                  resamplerVersion: dto.normalization.resamplerVersion,
                  quantizerVersion: dto.normalization.quantizerVersion
              ),
              dto.canonical.container == CanonicalAudioFormat.v1.container,
              dto.canonical.encoding == CanonicalAudioFormat.v1.encoding.rawValue,
              dto.canonical.sampleRateHz == CanonicalAudioFormat.sampleRateHz,
              dto.canonical.channelCount == CanonicalAudioFormat.channelCount,
              dto.canonical.bitsPerSample == CanonicalAudioFormat.bitsPerSample
        else {
            throw AudioImportFailure.candidateCorrupt
        }
        let original = try OriginalAudioArtifact(
            relativePath: LibraryRelativePath(dto.original.relativePath),
            container: container,
            fingerprint: AudioArtifactFingerprint(
                byteCount: dto.original.byteCount,
                sha256: dto.original.sha256
            ),
            decodedCodec: codec,
            sourceSampleRateHz: dto.original.sourceSampleRateHz,
            sourceChannelCount: dto.original.sourceChannelCount
        )
        let canonical = try CanonicalAudioArtifact(
            relativePath: LibraryRelativePath(dto.canonical.relativePath),
            fingerprint: AudioArtifactFingerprint(
                byteCount: dto.canonical.byteCount,
                sha256: dto.canonical.sha256
            ),
            frameCount: dto.canonical.frameCount,
            durationMilliseconds: dto.canonical.durationMs
        )
        let source = try SessionAudioSource(
            audioSourceID: AudioSourceID(dto.sources[0].audioSourceId),
            role: role,
            timelineOffsetMilliseconds: dto.sources[0].timelineOffsetMs
        )
        return try ImportedAudioAsset(
            original: original,
            canonical: canonical,
            sources: [source],
            normalization: normalization
        )
    }

    private func validateCanonicalWAV(
        components: [String],
        under rootDescriptor: Int32,
        expected: CanonicalAudioArtifact
    ) throws {
        let parent = try openDirectory(
            components: Array(components.dropLast()),
            under: rootDescriptor
        )
        defer { Darwin.close(parent) }
        let descriptor = try openRegularFile(
            named: components.last!,
            under: parent,
            nonblocking: true
        )
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_size == off_t(expected.fingerprint.byteCount),
              metadata.st_size == off_t(44 + expected.frameCount * 2)
        else {
            throw AudioImportFailure.candidateCorrupt
        }
        var header = [UInt8](repeating: 0, count: 44)
        guard preadAll(descriptor, into: &header, offset: 0),
              Array(header[0..<4]) == Array("RIFF".utf8),
              littleUInt32(header, 4) == UInt32(36 + expected.frameCount * 2),
              Array(header[8..<12]) == Array("WAVE".utf8),
              Array(header[12..<16]) == Array("fmt ".utf8),
              littleUInt32(header, 16) == 16,
              littleUInt16(header, 20) == 1,
              littleUInt16(header, 22) == 1,
              littleUInt32(header, 24) == 16_000,
              littleUInt32(header, 28) == 32_000,
              littleUInt16(header, 32) == 2,
              littleUInt16(header, 34) == 16,
              Array(header[36..<40]) == Array("data".utf8),
              littleUInt32(header, 40) == UInt32(expected.frameCount * 2)
        else {
            throw AudioImportFailure.candidateCorrupt
        }
        var firstFrame = [UInt8](repeating: 0, count: 2)
        var finalFrame = [UInt8](repeating: 0, count: 2)
        guard preadAll(descriptor, into: &firstFrame, offset: 44),
              preadAll(
                  descriptor,
                  into: &finalFrame,
                  offset: off_t(44 + (expected.frameCount - 1) * 2)
              )
        else {
            throw AudioImportFailure.candidateCorrupt
        }
    }

    private func fingerprint(
        components: [String],
        under rootDescriptor: Int32,
        maximumBytes: UInt64
    ) throws -> AudioArtifactFingerprint {
        let parent = try openDirectory(
            components: Array(components.dropLast()),
            under: rootDescriptor
        )
        defer { Darwin.close(parent) }
        let descriptor = try openRegularFile(
            named: components.last!,
            under: parent,
            nonblocking: true
        )
        defer { Darwin.close(descriptor) }
        return try fingerprint(descriptor: descriptor, maximumBytes: maximumBytes)
    }

    private func fingerprint(
        descriptor: Int32,
        maximumBytes: UInt64
    ) throws -> AudioArtifactFingerprint {
        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              initial.st_size > 0,
              UInt64(initial.st_size) <= maximumBytes
        else {
            throw AudioImportFailure.candidateCorrupt
        }

        var hasher = SHA256()
        var byteCount: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                while true {
                    let result = Darwin.read(descriptor, base, bytes.count)
                    if result < 0, errno == EINTR { continue }
                    return result
                }
            }
            guard count >= 0 else { throw AudioImportFailure.candidateCorrupt }
            if count == 0 { break }
            byteCount += UInt64(count)
            guard byteCount <= maximumBytes,
                  byteCount <= UInt64(initial.st_size)
            else {
                throw AudioImportFailure.candidateCorrupt
            }
            hasher.update(data: Data(buffer[0..<count]))
        }
        var final = stat()
        guard byteCount == UInt64(initial.st_size),
              fstat(descriptor, &final) == 0,
              sameSource(initial, final)
        else {
            throw AudioImportFailure.candidateCorrupt
        }
        return try AudioArtifactFingerprint(
            byteCount: byteCount,
            sha256: Self.hexDigest(hasher.finalize())
        )
    }

    private func schemaVersion(_ data: Data) throws -> UInt64 {
        try confinedRead.schemaVersion(in: data)
    }

    private func jsonDictionary(_ data: Data) throws -> [String: Any] {
        try confinedRead.jsonDictionary(data)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try confinedRead.decode(type, from: data)
    }

    private func deterministicJSON<T: Encodable>(_ value: T) throws -> Data {
        try confinedWrite.deterministicJSON(value)
    }

    private func writeRoot(
        _ data: Data,
        named name: String,
        parentComponents: [String],
        under rootDescriptor: Int32
    ) throws {
        guard data.count <= Self.maximumManifestBytes else {
            throw AudioImportFailure.writeFailed
        }
        let parent = try openDirectory(
            components: parentComponents,
            under: rootDescriptor
        )
        defer { Darwin.close(parent) }
        let partial = ".\(name).\(UUID().uuidString).partial"
        let descriptor = try openExclusiveFile(named: partial, under: parent)
        var open = true
        defer { if open { Darwin.close(descriptor) } }
        do {
            try writeAll(data, to: descriptor)
            try flush(descriptor)
            guard Darwin.close(descriptor) == 0 else {
                open = false
                throw AudioImportFailure.writeFailed
            }
            open = false
            try confinedWrite.renameNoReplace(
                from: partial,
                under: parent,
                to: name,
                under: parent,
                collision: .destinationCollision
            )
            try flush(parent)
        } catch {
            _ = unlinkat(parent, partial, 0)
            throw error
        }
    }

    private func boundedFileData(
        components: [String],
        under rootDescriptor: Int32,
        maximumBytes: UInt64
    ) throws -> Data {
        let parent = try openDirectory(
            components: Array(components.dropLast()),
            under: rootDescriptor
        )
        defer { Darwin.close(parent) }
        guard maximumBytes <= UInt64(Int.max) else {
            throw AudioImportFailure.candidateCorrupt
        }
        return try confinedRead.boundedData(
            named: components.last!,
            under: parent,
            maximumBytes: Int(maximumBytes)
        )
    }

    private func openDirectory(at url: URL) throws -> Int32 {
        let descriptor = url.path.withCString { pointer -> Int32 in
            while true {
                let result = Darwin.open(
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard descriptor >= 0 else { throw AudioImportFailure.unavailable }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR
        else {
            Darwin.close(descriptor)
            throw AudioImportFailure.unavailable
        }
        return descriptor
    }

    private func openDirectory(
        components: [String],
        under rootDescriptor: Int32
    ) throws -> Int32 {
        var current = Darwin.openat(
            rootDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else { throw AudioImportFailure.unavailable }
        do {
            for component in components {
                guard Self.isSafeComponent(component) else {
                    throw AudioImportFailure.candidateCorrupt
                }
                let next = try confinedRead.openDirectory(named: component, under: current)
                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private func openRegularFile(
        named name: String,
        under parent: Int32,
        nonblocking: Bool
    ) throws -> Int32 {
        guard Self.isSafeComponent(name), nonblocking else {
            throw AudioImportFailure.candidateCorrupt
        }
        return try confinedRead.openRegularFile(named: name, under: parent)
    }

    private func openExclusiveFile(named name: String, under parent: Int32) throws -> Int32 {
        guard Self.isSafeComponent(name) else { throw AudioImportFailure.writeFailed }
        let descriptor = name.withCString { pointer in
            Darwin.openat(
                parent,
                pointer,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard descriptor >= 0 else {
            if errno == EEXIST { throw AudioImportFailure.destinationCollision }
            throw AudioImportFailure.writeFailed
        }
        return descriptor
    }

    private func makeDirectory(_ name: String, under parent: Int32) throws {
        guard Self.isSafeComponent(name), mkdirat(parent, name, 0o700) == 0 else {
            if errno == EEXIST { throw AudioImportFailure.destinationCollision }
            throw AudioImportFailure.writeFailed
        }
    }

    private func directoryIdentity(_ descriptor: Int32) throws -> ConfinedEntryIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR
        else {
            throw AudioImportFailure.candidateCorrupt
        }
        return ConfinedEntryIdentity(metadata)
    }

    private func entryIdentity(
        named name: String,
        under parent: Int32
    ) throws -> ConfinedEntryIdentity {
        guard Self.isSafeComponent(name) else {
            throw AudioImportFailure.candidateCorrupt
        }
        var metadata = stat()
        let result = name.withCString {
            fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw AudioImportFailure.candidateCorrupt
        }
        return ConfinedEntryIdentity(metadata)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        let succeeded = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if count == 0 { return false }
                offset += count
            }
            return true
        }
        guard succeeded else {
            if errno == ENOSPC { throw AudioImportFailure.insufficientSpace }
            throw AudioImportFailure.writeFailed
        }
    }

    private func flush(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            if errno == ENOSPC { throw AudioImportFailure.insufficientSpace }
            throw AudioImportFailure.writeFailed
        }
    }

    private func sameSource(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev &&
            lhs.st_ino == rhs.st_ino &&
            lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func detectedContainer(_ bytes: [UInt8]) -> ImportedAudioContainer? {
        guard bytes.count >= 12 else { return nil }
        if Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WAVE".utf8)
        {
            return .wav
        }
        if Array(bytes[4..<8]) == Array("ftyp".utf8) { return .m4a }
        return nil
    }

    private func preadAll(_ descriptor: Int32, into bytes: inout [UInt8], offset: off_t) -> Bool {
        let isEmpty = bytes.isEmpty
        return bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return isEmpty }
            var readOffset = 0
            while readOffset < buffer.count {
                let count = Darwin.pread(
                    descriptor,
                    base.advanced(by: readOffset),
                    buffer.count - readOffset,
                    offset + off_t(readOffset)
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if count == 0 { return false }
                readOffset += count
            }
            return true
        }
    }

    private func littleUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func littleUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) |
            UInt32(bytes[offset + 1]) << 8 |
            UInt32(bytes[offset + 2]) << 16 |
            UInt32(bytes[offset + 3]) << 24
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
            !value.contains("/") && !value.contains("\\") &&
            !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func sha256(_ data: Data) -> String {
        hexDigest(SHA256.hash(data: data))
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct ConfinedEntryIdentity: Equatable {
    let device: UInt64
    let inode: UInt64

    init(_ metadata: stat) {
        device = UInt64(truncatingIfNeeded: metadata.st_dev)
        inode = UInt64(truncatingIfNeeded: metadata.st_ino)
    }
}

private struct SessionIdentityEnvelopeDTO: Decodable {
    let sessionId: String
}

private struct SessionManifestDTO: Codable {
    let schemaVersion: UInt64
    let sessionId: String
    let createdAt: String
    let durationMs: UInt64
    let audioManifestSha256: String
    let transcriptRevisionIds: [String]
}

private struct AudioManifestDTO: Codable {
    let schemaVersion: UInt64
    let acquisitionKind: String
    let original: OriginalAudioDTO
    let canonical: CanonicalAudioDTO
    let sources: [AudioSourceDTO]
    let normalization: NormalizationDTO
}

private struct OriginalAudioDTO: Codable {
    let relativePath: String
    let container: String
    let byteCount: UInt64
    let sha256: String
    let decodedCodec: String
    let sourceSampleRateHz: UInt32
    let sourceChannelCount: UInt32
}

private struct CanonicalAudioDTO: Codable {
    let relativePath: String
    let byteCount: UInt64
    let sha256: String
    let frameCount: UInt64
    let durationMs: UInt64
    let container: String
    let encoding: String
    let sampleRateHz: UInt32
    let channelCount: UInt32
    let bitsPerSample: UInt32
}

private struct AudioSourceDTO: Codable {
    let audioSourceId: String
    let role: String
    let timelineOffsetMs: UInt64
}

private struct NormalizationDTO: Codable {
    let algorithmId: String
    let algorithmVersion: UInt32
    let stereoRule: String
    let resamplerVersion: String
    let quantizerVersion: String
}
