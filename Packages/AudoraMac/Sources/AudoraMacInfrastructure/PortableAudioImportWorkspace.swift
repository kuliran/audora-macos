import AudoraApplication
import AudoraDomain
import Foundation

public protocol AudioFileChoosing: Sendable {
    func chooseAudioFile() async -> URL?
}

public actor PortableAudioImportWorkspace: AudioImportPort {
    private struct Selection: @unchecked Sendable {
        let generation: Int
        let source: any LibraryAccessLease
        let library: ActiveLibraryImportScope
        var reservedSessionID: SessionID?
    }

    private struct StagedRecord: @unchecked Sendable {
        let location: AudioImportStagingLocation
        let library: ActiveLibraryImportScope
        let candidate: StagedAudioCandidate
        let session: ImportedSession
    }

    private let scopes: any ActiveLibraryImportScopeProviding
    private let chooser: any AudioFileChoosing
    private let sourceAccess: any LibraryAccessGranting
    private let decoder: any AudioPCMDecoding
    private let persistence: PortableAudioImportPersistence
    private var selections: [AudioSelectionToken: Selection] = [:]
    private var stagedRecords: [AudioStagingID: StagedRecord] = [:]
    private var nextSelection = 0
    private var choosing = false

    public init(
        workspace: PortableLibraryWorkspace,
        chooser: any AudioFileChoosing,
        sourceAccess: any LibraryAccessGranting
    ) {
        scopes = workspace
        self.chooser = chooser
        self.sourceAccess = sourceAccess
        decoder = AVAssetPCMDecoder()
        persistence = PortableAudioImportPersistence()
    }

    init(
        scopes: any ActiveLibraryImportScopeProviding,
        chooser: any AudioFileChoosing,
        sourceAccess: any LibraryAccessGranting,
        decoder: any AudioPCMDecoding,
        persistence: PortableAudioImportPersistence = PortableAudioImportPersistence()
    ) {
        self.scopes = scopes
        self.chooser = chooser
        self.sourceAccess = sourceAccess
        self.decoder = decoder
        self.persistence = persistence
    }

    public func choose() async -> AudioSelectionOutcome {
        guard !choosing else { return .failed(.unavailable) }
        choosing = true
        defer { choosing = false }
        revokeAllSelections()

        guard let library = await scopes.acquireAudioImportScope() else {
            return .failed(.libraryChanged)
        }
        guard let selectedURL = await chooser.chooseAudioFile() else {
            library.release()
            return .cancelled
        }
        guard await scopes.isCurrentAudioImportScope(library.identity) else {
            library.release()
            return .failed(.libraryChanged)
        }

        let source: any LibraryAccessLease
        do {
            source = try sourceAccess.acquireAccess(to: selectedURL)
        } catch {
            library.release()
            return .failed(.unavailable)
        }
        nextSelection &+= 1
        guard let token = AudioSelectionToken("audio_selection_\(nextSelection)") else {
            source.release()
            library.release()
            return .failed(.unavailable)
        }
        selections[token] = Selection(
            generation: nextSelection,
            source: source,
            library: library,
            reservedSessionID: nil
        )
        return .selected(token, scope: library.identity)
    }

    public func revokeSelection(_ token: AudioSelectionToken) {
        guard let selection = selections.removeValue(forKey: token) else { return }
        selection.source.release()
        selection.library.release()
    }

    public func reserveSessionID(
        _ sessionID: SessionID,
        for token: AudioSelectionToken,
        in scope: AudioImportScopeIdentity
    ) async throws -> AudioImportSessionIDReservationOutcome {
        guard let selection = selections[token],
              selection.library.identity == scope
        else {
            throw AudioImportFailure.libraryChanged
        }
        if let reserved = selection.reservedSessionID {
            guard reserved == sessionID else {
                throw AudioImportFailure.candidateCorrupt
            }
            return .reserved
        }
        let libraryRoot = selection.library.root
        let available = try await scopes.withCurrentAudioImportScope(scope) {
            try persistence.sessionIDIsAvailable(
                at: libraryRoot,
                libraryID: scope.libraryID,
                sessionID: sessionID
            )
        }
        guard var currentSelection = selections[token],
              currentSelection.generation == selection.generation,
              currentSelection.library.identity == scope
        else {
            throw AudioImportFailure.libraryChanged
        }
        if let reserved = currentSelection.reservedSessionID {
            guard reserved == sessionID else {
                throw AudioImportFailure.candidateCorrupt
            }
            return .reserved
        }
        guard available else { return .collision }
        currentSelection.reservedSessionID = sessionID
        selections[token] = currentSelection
        return .reserved
    }

    public func prepare(
        _ token: AudioSelectionToken,
        seed: ImportedSessionSeed,
        policy: AudioImportPolicy,
        progress: @escaping @Sendable (AudioImportPreparationPhase) async -> Void
    ) async throws -> StagedAudioCandidate {
        guard let selection = selections.removeValue(forKey: token) else {
            throw AudioImportFailure.unavailable
        }
        var sourceReleased = false
        defer {
            if !sourceReleased {
                selection.source.release()
            }
        }

        guard seed.scope == selection.library.identity,
              selection.reservedSessionID == seed.sessionID,
              policy.maximumCanonicalFrames > 0,
              policy.maximumCanonicalFrames <= CanonicalAudioFormat.maximumFrameCount,
              policy.maximumSourceBytes > 0
        else {
            selection.library.release()
            throw AudioImportFailure.candidateCorrupt
        }

        var location: AudioImportStagingLocation?
        var retainedForInstall = false
        defer {
            if !retainedForInstall {
                if let location {
                    persistence.discard(location)
                    location.close()
                }
                selection.library.release()
            }
        }

        do {
            try await requireCurrent(selection.library.identity)
            let openedSource = try persistence.openSource(
                at: selection.source.url,
                maximumBytes: policy.maximumSourceBytes
            )
            defer { openedSource.close() }
            let container = openedSource.container
            let stagingID = try makeStagingID()
            revokeAllStagedRecords()
            let created = try persistence.begin(
                root: selection.library.root,
                stagingID: stagingID,
                seed: seed,
                container: container
            )
            location = created

            await progress(.copying)
            let originalFingerprint = try persistence.copySource(
                from: openedSource,
                into: created,
                maximumBytes: policy.maximumSourceBytes
            )
            selection.source.release()
            sourceReleased = true
            try await requireCurrent(selection.library.identity)

            await progress(.inspecting)
            let ownedSource = try persistence.openOriginalForDecoding(
                in: created,
                expected: originalFingerprint
            )
            let inspectedSource = try await decoder.inspect(
                ownedSource,
                container: container
            )
            let inspected = inspectedSource.description
            guard inspected.metadataDurationSeconds.isFinite,
                  inspected.metadataDurationSeconds > 0
            else {
                throw AudioImportFailure.malformedMedia
            }
            let maximumSeconds = Double(policy.maximumCanonicalFrames) /
                Double(CanonicalAudioFormat.sampleRateHz)
            guard inspected.metadataDurationSeconds <= maximumSeconds + 1 else {
                throw AudioImportFailure.durationExceeded
            }
            try requireCapacity(for: inspected, policy: policy, location: created)
            try await requireCurrent(selection.library.identity)

            await progress(.normalizing)
            let canonicalDescriptor = try persistence.createCanonicalDescriptor(in: created)
            let normalizer = try StreamingCanonicalAudioNormalizer(
                description: inspected,
                destinationDescriptor: canonicalDescriptor,
                maximumFrameCount: policy.maximumCanonicalFrames
            )
            try await decoder.decode(inspectedSource) { chunk in
                try normalizer.consume(chunk)
            }
            let normalized = try normalizer.finish()
            try persistence.didFinishCanonicalWrite(in: created)
            try await requireCurrent(selection.library.identity)

            let canonicalFingerprint = try persistence.fingerprint(
                components: created.stagedSessionComponents + ["audio", "audio.wav"],
                under: created,
                maximumBytes: normalized.byteCount
            )
            guard canonicalFingerprint.byteCount == normalized.byteCount else {
                throw AudioImportFailure.candidateCorrupt
            }

            let audio = try makeAudioAsset(
                container: container,
                inspected: inspected,
                originalFingerprint: originalFingerprint,
                canonicalFingerprint: canonicalFingerprint,
                normalized: normalized
            )
            let provisional = try ImportedSession(
                sessionID: seed.sessionID,
                createdAt: seed.createdAt,
                durationMilliseconds: normalized.durationMilliseconds,
                audioManifestSHA256: String(repeating: "0", count: 64),
                audio: audio
            )
            let rebound = try persistence.writeManifests(for: provisional, in: created)
            let validated = try persistence.validateStaged(created, expected: rebound)
            let candidate = Self.makeCandidate(
                stagingID: stagingID,
                scope: selection.library.identity,
                session: validated
            )
            stagedRecords[stagingID] = StagedRecord(
                location: created,
                library: selection.library,
                candidate: candidate,
                session: validated
            )
            retainedForInstall = true
            return candidate
        } catch is CancellationError {
            throw AudioImportFailure.cancelled
        } catch let failure as AudioImportFailure {
            throw failure
        } catch {
            throw AudioImportFailure.unavailable
        }
    }

    public func install(
        _ candidate: ValidatedImportedSession
    ) async throws -> ReopenedImportedSessionSnapshot {
        let stagingID = candidate.stagedCandidate.stagingID
        guard let record = stagedRecords[stagingID],
              record.candidate == candidate.stagedCandidate,
              record.session == candidate.session
        else {
            throw AudioImportFailure.candidateCorrupt
        }

        do {
            let snapshot = try await scopes.withCurrentAudioImportScope(
                record.library.identity
            ) {
                try persistence.install(record.location, expected: record.session)
            }
            stagedRecords.removeValue(forKey: stagingID)
            record.location.close()
            record.library.release()
            return snapshot
        } catch AudioImportFailure.installedNeedsRefresh {
            // The no-replace rename already committed. Consume the capability,
            // but never run staging cleanup against the installed Session.
            stagedRecords.removeValue(forKey: stagingID)
            record.location.close()
            record.library.release()
            throw AudioImportFailure.installedNeedsRefresh
        } catch let failure as AudioImportFailure {
            throw failure
        } catch {
            throw AudioImportFailure.writeFailed
        }
    }

    public func discard(_ stagingID: AudioStagingID) {
        guard let record = stagedRecords.removeValue(forKey: stagingID) else { return }
        persistence.discard(record.location)
        record.location.close()
        record.library.release()
    }

    var pendingSelectionCount: Int { selections.count }
    var stagedCandidateCount: Int { stagedRecords.count }

    private func requireCurrent(_ identity: AudioImportScopeIdentity) async throws {
        try Task.checkCancellation()
        guard await scopes.isCurrentAudioImportScope(identity) else {
            throw AudioImportFailure.libraryChanged
        }
    }

    private func requireCapacity(
        for inspected: InspectedAudio,
        policy: AudioImportPolicy,
        location: AudioImportStagingLocation
    ) throws {
        let available: UInt64
        switch persistence.availableCapacity(at: location) {
        case let .available(bytes):
            available = bytes
        case .unavailable:
            throw AudioImportFailure.unavailable
        }
        let estimatedFrames = min(
            Double(policy.maximumCanonicalFrames),
            ceil(inspected.metadataDurationSeconds * Double(CanonicalAudioFormat.sampleRateHz))
                + 4_096
        )
        let required = min(
            UInt64(Int64.max),
            UInt64(estimatedFrames) * 2 + 44 + 2 * UInt64(PortableAudioImportPersistence.maximumManifestBytes)
        )
        guard available >= required else {
            throw AudioImportFailure.insufficientSpace
        }
    }

    private func revokeAllSelections() {
        for selection in selections.values {
            selection.source.release()
            selection.library.release()
        }
        selections.removeAll(keepingCapacity: true)
    }

    private func revokeAllStagedRecords() {
        for record in stagedRecords.values {
            persistence.discard(record.location)
            record.location.close()
            record.library.release()
        }
        stagedRecords.removeAll(keepingCapacity: true)
    }

    private func makeStagingID() throws -> AudioStagingID {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard let identifier = AudioStagingID("audio_staging_\(suffix)") else {
            throw AudioImportFailure.unavailable
        }
        return identifier
    }

    private func makeAudioAsset(
        container: ImportedAudioContainer,
        inspected: InspectedAudio,
        originalFingerprint: AudioArtifactFingerprint,
        canonicalFingerprint: AudioArtifactFingerprint,
        normalized: CanonicalNormalizationResult
    ) throws -> ImportedAudioAsset {
        let original = try OriginalAudioArtifact(
            relativePath: LibraryRelativePath("audio/original.\(container.rawValue)"),
            container: container,
            fingerprint: originalFingerprint,
            decodedCodec: inspected.codec,
            sourceSampleRateHz: inspected.sampleRateHz,
            sourceChannelCount: inspected.channelCount
        )
        let canonical = try CanonicalAudioArtifact(
            relativePath: LibraryRelativePath("audio/audio.wav"),
            fingerprint: canonicalFingerprint,
            frameCount: normalized.frameCount,
            durationMilliseconds: normalized.durationMilliseconds
        )
        let source = try SessionAudioSource(
            audioSourceID: .microphone,
            role: .microphone,
            timelineOffsetMilliseconds: 0
        )
        return try ImportedAudioAsset(
            original: original,
            canonical: canonical,
            sources: [source],
            normalization: .v1
        )
    }

    private static func makeCandidate(
        stagingID: AudioStagingID,
        scope: AudioImportScopeIdentity,
        session: ImportedSession
    ) -> StagedAudioCandidate {
        let audio = session.audio
        return StagedAudioCandidate(
            stagingID: stagingID,
            scope: scope,
            sessionID: session.sessionID.rawValue,
            createdAt: session.createdAt.rawValue,
            audioManifestSHA256: session.audioManifestSHA256,
            originalRelativePath: audio.original.relativePath.description,
            originalContainer: audio.original.container.rawValue,
            originalByteCount: audio.original.fingerprint.byteCount,
            originalSHA256: audio.original.fingerprint.sha256,
            decodedCodec: audio.original.decodedCodec.rawValue,
            sourceSampleRateHz: audio.original.sourceSampleRateHz,
            sourceChannelCount: audio.original.sourceChannelCount,
            canonicalRelativePath: audio.canonical.relativePath.description,
            canonicalByteCount: audio.canonical.fingerprint.byteCount,
            canonicalSHA256: audio.canonical.fingerprint.sha256,
            canonicalFrameCount: audio.canonical.frameCount,
            canonicalDurationMilliseconds: audio.canonical.durationMilliseconds,
            canonicalContainer: audio.canonical.format.container,
            canonicalEncoding: audio.canonical.format.encoding.rawValue,
            canonicalSampleRateHz: audio.canonical.format.sampleRateHz,
            canonicalChannelCount: audio.canonical.format.channelCount,
            canonicalBitsPerSample: audio.canonical.format.bitsPerSample,
            audioSourceID: audio.sources[0].audioSourceID.rawValue,
            audioSourceRole: audio.sources[0].role.rawValue,
            timelineOffsetMilliseconds: audio.sources[0].timelineOffsetMilliseconds,
            normalizationAlgorithmID: audio.normalization.algorithmID,
            normalizationAlgorithmVersion: audio.normalization.algorithmVersion,
            stereoRule: audio.normalization.stereoRule,
            resamplerVersion: audio.normalization.resamplerVersion,
            quantizerVersion: audio.normalization.quantizerVersion
        )
    }
}
