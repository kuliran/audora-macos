import AudoraApplication
import AudoraDomain
import CryptoKit
import Darwin
import Foundation

public enum RecordingPersistenceFaultPoint: String, CaseIterable, Sendable {
    case afterStagingDirectoryCreate
    case afterIdentityFlush
    case afterRecordFlush
    case afterWatermarkFlush
    case beforeSealScan
    case afterCanonicalAudioFlush
    case afterAudioManifestFlush
    case afterSessionManifestFlush
    case beforeSessionInstall
    case afterSessionInstall
    case afterSessionsDirectoryFlush
    case beforeInstalledSessionValidation
    case beforeStagingCleanup
}

enum RecordingPersistenceError: Error, Equatable {
    case invalidLibraryAuthority
    case stagingCollision
    case invalidStaging
    case recordStreamTooLarge
    case emptyRecording
    case durationExceeded
    case destinationCollision
    case unsafeEntry
    case ioFailure
    case injectedFault(RecordingPersistenceFaultPoint)
}

/// Descriptor-owned capability for exactly one staging aggregate. It is kept
/// internal so machine-local paths and file descriptors cannot cross into
/// portable Domain/Application values.
final class RecordingStagingHandle: @unchecked Sendable {
    let rootDescriptor: Int32
    let recordingsDescriptor: Int32
    let sessionsDescriptor: Int32
    let stagingDescriptor: Int32
    private(set) var streamDescriptor: Int32
    let request: MicrophoneRecordingRequest
    var durableFrameCount: UInt64

    init(
        rootDescriptor: Int32,
        recordingsDescriptor: Int32,
        sessionsDescriptor: Int32,
        stagingDescriptor: Int32,
        streamDescriptor: Int32,
        request: MicrophoneRecordingRequest,
        durableFrameCount: UInt64
    ) {
        self.rootDescriptor = rootDescriptor
        self.recordingsDescriptor = recordingsDescriptor
        self.sessionsDescriptor = sessionsDescriptor
        self.stagingDescriptor = stagingDescriptor
        self.streamDescriptor = streamDescriptor
        self.request = request
        self.durableFrameCount = durableFrameCount
    }

    deinit {
        closeCaptureStream()
        Darwin.close(stagingDescriptor)
        Darwin.close(sessionsDescriptor)
        Darwin.close(recordingsDescriptor)
        Darwin.close(rootDescriptor)
    }

    func closeCaptureStream() {
        guard streamDescriptor >= 0 else { return }
        Darwin.close(streamDescriptor)
        streamDescriptor = -1
    }
}

struct RecordingPersistence: @unchecked Sendable {
    /// At 384 kHz a 45-minute capture contains 1,012,500 configured 1,024-frame
    /// tap callbacks. One callback can yield a gap record plus an observed/muted
    /// record. This ceiling covers both envelopes and all 43,200,000 canonical
    /// S16LE frames while remaining finite and preflightable.
    static let configuredTapFrames: UInt64 = 1_024
    static let maximumAcceptedInputSampleRate: UInt64 = 384_000
    static let recordEnvelopeBytes: UInt64 = 49
    static let maximumRecordStreamBytes: Int = {
        let inputFrames = maximumAcceptedInputSampleRate * 45 * 60
        let callbacks = (inputFrames + configuredTapFrames - 1) / configuredTapFrames
        let envelopes = callbacks * 2 * recordEnvelopeBytes
        let canonicalPayload = CanonicalRecordingLimits.maximumFrames * 2
        return Int(8 + envelopes + canonicalPayload)
    }()
    static let maximumRecordCount = 2_100_000
    static let maximumUnavailableIntervalCount =
        StagedRecordingSealCandidate.maximumUnavailableIntervalCount
    static let maximumRecordingStagingEntryCount = 128
    static let maximumOwnedDirectoryEntryCount = 16
    private static let recordMagic = Data("AUDRREC1".utf8)
    private static let wavHeaderBytes = 44

    private let fault: @Sendable (RecordingPersistenceFaultPoint) throws -> Void
    private let recordLimit: Int
    private let unavailableIntervalLimit: Int

    init(
        fault: @escaping @Sendable (RecordingPersistenceFaultPoint) throws -> Void = { _ in },
        recordLimit: Int = Self.maximumRecordCount,
        unavailableIntervalLimit: Int = Self.maximumUnavailableIntervalCount
    ) {
        self.fault = fault
        self.recordLimit = recordLimit
        self.unavailableIntervalLimit = unavailableIntervalLimit
    }

    private var confined: ConfinedPersistencePrimitives<RecordingPersistenceError> {
        ConfinedPersistencePrimitives(
            ioFailure: .ioFailure,
            invalidLayout: .unsafeEntry,
            expectedPathIsSymlink: .unsafeEntry,
            rootTooLarge: .recordStreamTooLarge,
            invalidJSON: .invalidStaging,
            invalidSchemaVersion: .invalidStaging,
            unknownKey: .invalidStaging
        )
    }

    func prepare(
        _ request: MicrophoneRecordingRequest,
        under root: URL
    ) throws -> RecordingStagingHandle {
        guard request.canonicalFormat == .versionOne,
              request.maximumFrames == CanonicalRecordingLimits.maximumFrames
        else {
            throw RecordingPersistenceError.invalidStaging
        }

        let rootFD = try openDirectory(at: root)
        var owned: [Int32] = [rootFD]
        var cleanupRecordingsFD: Int32?
        var cleanupStagingFD: Int32?
        var cleanupCandidateName: String?
        var stagingInstalled = false
        do {
            try validateLibraryIdentity(request.libraryScope.libraryID, under: rootFD)
            let recordingsFD = try openDirectory(
                components: ["staging", "recordings"],
                under: rootFD
            )
            owned.append(recordingsFD)
            cleanupRecordingsFD = recordingsFD
            let sessionsFD = try openDirectory(components: ["sessions"], under: rootFD)
            owned.append(sessionsFD)

            let stagingName = request.recordingID.rawValue
            guard try !entryExists(named: request.sessionID.rawValue, under: sessionsFD) else {
                throw RecordingPersistenceError.stagingCollision
            }
            let candidateName = ".\(stagingName).\(UUID().uuidString).partial"
            cleanupCandidateName = candidateName
            guard mkdirat(recordingsFD, candidateName, 0o700) == 0 else {
                throw RecordingPersistenceError.ioFailure
            }
            let stagingFD = try openDirectory(components: [candidateName], under: recordingsFD)
            owned.append(stagingFD)
            cleanupStagingFD = stagingFD
            try fault(.afterStagingDirectoryCreate)

            let identity = RecordingIdentityDTO(request: request)
            try writeExclusive(
                deterministicJSON(identity),
                named: "identity.json",
                under: stagingFD
            )
            try fault(.afterIdentityFlush)
            try writeExclusive(Self.recordMagic, named: "records.bin", under: stagingFD)
            let streamFD = try openRegular(
                named: "records.bin",
                under: stagingFD,
                flags: O_RDWR | O_APPEND
            )
            owned.append(streamFD)
            try replaceManifest(
                RecordingManifestDTO(request: request, durableFrameCount: 0, phase: .capturing),
                under: stagingFD
            )
            try flush(stagingFD)
            do {
                try noReplaceRename(
                    from: candidateName,
                    to: stagingName,
                    under: recordingsFD
                )
                stagingInstalled = true
            } catch RecordingPersistenceError.destinationCollision {
                throw RecordingPersistenceError.stagingCollision
            }
            try flush(recordingsFD)

            owned.removeAll(keepingCapacity: false)
            return RecordingStagingHandle(
                rootDescriptor: rootFD,
                recordingsDescriptor: recordingsFD,
                sessionsDescriptor: sessionsFD,
                stagingDescriptor: stagingFD,
                streamDescriptor: streamFD,
                request: request,
                durableFrameCount: 0
            )
        } catch {
            if !stagingInstalled,
               let cleanupRecordingsFD,
               let cleanupStagingFD,
               let cleanupCandidateName
            {
                try? removeExactStaging(
                    named: cleanupCandidateName,
                    stagingDescriptor: cleanupStagingFD,
                    recordingsDescriptor: cleanupRecordingsFD
                )
            }
            for descriptor in owned.reversed() { Darwin.close(descriptor) }
            throw error
        }
    }

    @discardableResult
    func append(
        _ span: CanonicalPCMSpan,
        to handle: RecordingStagingHandle
    ) throws -> UInt64 {
        guard span.frameCount > 0 else { return handle.durableFrameCount }
        let (newFrameCount, overflow) = handle.durableFrameCount.addingReportingOverflow(
            span.frameCount
        )
        guard !overflow,
              newFrameCount <= handle.request.maximumFrames
        else {
            throw RecordingPersistenceError.durationExceeded
        }

        let payload: Data
        let observed: Bool
        if let pcm = span.pcmLittleEndian {
            let (expectedBytes, byteOverflow) = span.frameCount.multipliedReportingOverflow(by: 2)
            guard !byteOverflow,
                  expectedBytes <= UInt64(Int.max),
                  pcm.count == Int(expectedBytes),
                  span.reasons.isEmpty
            else {
                throw RecordingPersistenceError.invalidStaging
            }
            payload = pcm
            observed = true
        } else {
            guard !span.reasons.isEmpty else {
                throw RecordingPersistenceError.invalidStaging
            }
            payload = Data()
            observed = false
        }

        let record = encodeRecord(
            frameCount: span.frameCount,
            observed: observed,
            reasons: span.reasons,
            payload: payload
        )
        try writeAll(record, to: handle.streamDescriptor)
        try flush(handle.streamDescriptor)
        try fault(.afterRecordFlush)

        try replaceManifest(
            RecordingManifestDTO(
                request: handle.request,
                durableFrameCount: newFrameCount,
                phase: .capturing
            ),
            under: handle.stagingDescriptor
        )
        handle.durableFrameCount = newFrameCount
        try fault(.afterWatermarkFlush)
        return newFrameCount
    }

    func markRecoverable(
        _ handle: RecordingStagingHandle,
        availability: RecordingRecoveryAvailability
    ) throws {
        guard availability == .sealOrDiscard || availability == .discardOnly else {
            throw RecordingPersistenceError.invalidStaging
        }
        let identity = try readIdentity(under: handle.stagingDescriptor)
        if let current = try? readManifest(
            under: handle.stagingDescriptor,
            identity: identity
        ) {
            switch RecordingManifestPhase(rawValue: current.phase)! {
            case .publishing, .committed:
                // These phases carry the final fingerprint and exactly-once
                // publication authority. Never downgrade them to recoverable.
                return
            case .recoverable where current.availability ==
                RecordingRecoveryAvailability.discardOnly.rawValue:
                // A durable discard-only decision cannot be upgraded merely
                // because a later stream scan happens to succeed.
                return
            case .capturing, .recoverable, .sealing:
                break
            }
        }
        try replaceManifest(
            RecordingManifestDTO(
                request: handle.request,
                durableFrameCount: handle.durableFrameCount,
                phase: .recoverable,
                availability: availability
            ),
            under: handle.stagingDescriptor
        )
    }

    /// Classifies the durable aggregate after a failed seal without mutating
    /// publication authority. In particular, a publishing/committed manifest
    /// that already names an installed final can only be retried for cleanup;
    /// Recording Cancel never gains authority over that immutable Session.
    func recoveryAvailability(
        for handle: RecordingStagingHandle
    ) -> RecordingRecoveryAvailability {
        guard let identity = try? readIdentity(under: handle.stagingDescriptor),
              let manifest = try? readManifest(
                  under: handle.stagingDescriptor,
                  identity: identity
              ),
              let phase = RecordingManifestPhase(rawValue: manifest.phase)
        else {
            return .discardOnly
        }
        switch phase {
        case .publishing:
            return installedSessionMatches(manifest: manifest, under: handle.rootDescriptor)
                ? .committedCleanup
                : .sealOrDiscard
        case .committed:
            return .committedCleanup
        case .recoverable where manifest.availability ==
            RecordingRecoveryAvailability.discardOnly.rawValue:
            return .discardOnly
        case .capturing, .recoverable, .sealing:
            return handle.durableFrameCount > 0 ? .sealOrDiscard : .discardOnly
        }
    }

    func discard(_ handle: RecordingStagingHandle) throws {
        try fault(.beforeStagingCleanup)
        try removeExactStaging(
            named: handle.request.recordingID.rawValue,
            stagingDescriptor: handle.stagingDescriptor,
            recordingsDescriptor: handle.recordingsDescriptor
        )
    }

    func inspectRecovery(
        in scope: LibraryScope,
        under root: URL
    ) -> RecordingRecoveryCatalog {
        guard let rootFD = try? openDirectory(at: root) else {
            return RecordingRecoveryCatalog(
                items: [],
                inspectionStatus: .blocked(.libraryAuthorityUnavailable)
            )
        }
        defer { Darwin.close(rootFD) }
        guard (try? validateLibraryIdentity(scope.libraryID, under: rootFD)) != nil else {
            return RecordingRecoveryCatalog(
                items: [],
                inspectionStatus: .blocked(.libraryAuthorityUnavailable)
            )
        }
        guard let recordingsFD = try? openDirectory(
            components: ["staging", "recordings"],
            under: rootFD
        ) else {
            return RecordingRecoveryCatalog(
                items: [],
                inspectionStatus: .blocked(.stagingListingUnavailable)
            )
        }
        defer { Darwin.close(recordingsFD) }

        guard let names = try? directoryNames(
            under: recordingsFD,
            maximumCount: Self.maximumRecordingStagingEntryCount
        ) else {
            return RecordingRecoveryCatalog(
                items: [],
                inspectionStatus: .blocked(.stagingListingUnavailable)
            )
        }
        // Enumeration is completed successfully before any mutation. If
        // `readdir` reports an error or the finite root budget is exceeded,
        // this function returns above and preserves every byte.
        var unresolvedOwnedPartial = false
        for name in names.sorted() where isOwnedStagingPartialName(name) {
            do {
                try reconcileOwnedStagingPartial(
                    named: name,
                    libraryID: scope.libraryID,
                    under: recordingsFD
                )
                if try entryExists(named: name, under: recordingsFD) {
                    unresolvedOwnedPartial = true
                }
            } catch {
                unresolvedOwnedPartial = true
            }
        }
        var unresolvedUnrecognizedEntry = false
        var items: [RecordingRecoveryItem] = []
        var reconciledSeals: [SessionSealedReceipt] = []
        for name in names.sorted() {
            if isOwnedStagingPartialName(name) { continue }
            guard let pathRecordingID = try? RecordingID(name) else {
                // `staging/recordings` is Audora-owned. An entry that is not a
                // current RecordingID and is not one of our exact partial
                // names is ambiguous authority: preserve it and block capture.
                unresolvedUnrecognizedEntry = true
                continue
            }
            guard let stagingFD = try? openDirectory(components: [name], under: recordingsFD) else {
                items.append(
                    RecordingRecoveryItem(
                        recordingID: pathRecordingID,
                        durableFrameCount: 0,
                        availability: .readOnlyUnsupported
                    )
                )
                continue
            }
            defer { Darwin.close(stagingFD) }
            if let identityVersion = try? jsonSchemaVersion(
                named: "identity.json",
                under: stagingFD
            ), identityVersion > 1 {
                items.append(
                    RecordingRecoveryItem(
                        recordingID: pathRecordingID,
                        durableFrameCount: 0,
                        availability: .readOnlyNewerSchema
                    )
                )
                continue
            }
            guard let identity = try? readIdentity(under: stagingFD),
                  identity.libraryID == scope.libraryID,
                  identity.recordingID == pathRecordingID
            else {
                items.append(
                    RecordingRecoveryItem(
                        recordingID: pathRecordingID,
                        durableFrameCount: 0,
                        availability: .readOnlyUnsupported
                    )
                )
                continue
            }
            guard (try? reconcileOwnedManifestPartials(
                identity: identity,
                under: stagingFD
            )) == true else {
                items.append(
                    RecordingRecoveryItem(
                        recordingID: identity.recordingID,
                        sessionID: identity.sessionID,
                        startedAt: identity.startedAt,
                        durableFrameCount: 0,
                        availability: .readOnlyUnsupported
                    )
                )
                continue
            }

            if let version = try? manifestSchemaVersion(under: stagingFD), version > 1 {
                items.append(
                    RecordingRecoveryItem(
                        recordingID: identity.recordingID,
                        sessionID: identity.sessionID,
                        startedAt: identity.startedAt,
                        durableFrameCount: 0,
                        availability: .readOnlyNewerSchema
                    )
                )
                continue
            }

            let manifest = try? readManifest(under: stagingFD, identity: identity)
            if let manifest,
               installedSessionMatches(
                   manifest: manifest,
                   under: rootFD
               )
            {
                if let receipt = receipt(from: manifest, identity: identity) {
                    // The installed and reread immutable Session is already
                    // authoritative. Expose that fact even when exact staging
                    // cleanup must be retried; Application bounds and dedupes
                    // the ephemeral notification for this active instance.
                    reconciledSeals.append(receipt)
                    do {
                        try removeExactStaging(
                            named: name,
                            stagingDescriptor: stagingFD,
                            recordingsDescriptor: recordingsFD
                        )
                    } catch {
                        items.append(
                            RecordingRecoveryItem(
                                recordingID: identity.recordingID,
                                sessionID: identity.sessionID,
                                startedAt: identity.startedAt,
                                durableFrameCount: manifest.durableFrameCount,
                                availability: .committedCleanup
                            )
                        )
                    }
                }
                continue
            }

            let durableFrameCount = manifest?.durableFrameCount ?? 0
            let streamIsValid: Bool
            if durableFrameCount > 0,
               let streamFD = try? openRegular(
                   named: "records.bin",
                   under: stagingFD,
                   flags: O_RDONLY
               )
            {
                defer { Darwin.close(streamFD) }
                streamIsValid = (try? scanRecords(
                    descriptor: streamFD,
                    durableFrameCount: durableFrameCount
                )) != nil
            } else {
                streamIsValid = false
            }
            let availability: RecordingRecoveryAvailability
            if manifest?.availability == RecordingRecoveryAvailability.discardOnly.rawValue {
                availability = .discardOnly
            } else {
                availability = streamIsValid ? .sealOrDiscard : .discardOnly
            }
            items.append(
                RecordingRecoveryItem(
                    recordingID: identity.recordingID,
                    sessionID: identity.sessionID,
                    startedAt: identity.startedAt,
                    durableFrameCount: durableFrameCount,
                    availability: availability
                )
            )
        }
        return RecordingRecoveryCatalog(
            items: items,
            reconciledSeals: reconciledSeals,
            inspectionStatus: unresolvedOwnedPartial || unresolvedUnrecognizedEntry
                ? .blocked(.stagingListingUnavailable)
                : .complete
        )
    }

    func openRecovery(
        recordingID: RecordingID,
        in scope: LibraryScope,
        under root: URL
    ) throws -> RecordingStagingHandle {
        let rootFD = try openDirectory(at: root)
        var owned: [Int32] = [rootFD]
        do {
            try validateLibraryIdentity(scope.libraryID, under: rootFD)
            let recordingsFD = try openDirectory(
                components: ["staging", "recordings"],
                under: rootFD
            )
            owned.append(recordingsFD)
            let sessionsFD = try openDirectory(components: ["sessions"], under: rootFD)
            owned.append(sessionsFD)

            let name = recordingID.rawValue
            let stagingFD = try openDirectory(components: [name], under: recordingsFD)
            owned.append(stagingFD)
            let identity = try readIdentity(under: stagingFD)
            guard identity.recordingID == recordingID,
                  identity.libraryID == scope.libraryID,
                  try manifestSchemaVersion(under: stagingFD) == 1
            else {
                throw RecordingPersistenceError.invalidStaging
            }
            let manifest = try readManifest(under: stagingFD, identity: identity)
            let streamFD = try openRegular(
                named: "records.bin",
                under: stagingFD,
                flags: O_RDWR | O_APPEND
            )
            owned.append(streamFD)
            owned.removeAll(keepingCapacity: false)
            return RecordingStagingHandle(
                rootDescriptor: rootFD,
                recordingsDescriptor: recordingsFD,
                sessionsDescriptor: sessionsFD,
                stagingDescriptor: stagingFD,
                streamDescriptor: streamFD,
                request: identity.request,
                durableFrameCount: manifest.durableFrameCount
            )
        } catch {
            for descriptor in owned.reversed() { Darwin.close(descriptor) }
            throw error
        }
    }

    /// Deletes a recovery aggregate by its immutable identity. Unlike sealing,
    /// discard must remain available when the mutable manifest or record stream
    /// is corrupt, because the catalog intentionally exposes that case as
    /// `discardOnly`.
    func discardRecovery(
        recordingID: RecordingID,
        in scope: LibraryScope,
        under root: URL
    ) throws {
        let rootFD = try openDirectory(at: root)
        defer { Darwin.close(rootFD) }
        try validateLibraryIdentity(scope.libraryID, under: rootFD)
        let recordingsFD = try openDirectory(
            components: ["staging", "recordings"],
            under: rootFD
        )
        defer { Darwin.close(recordingsFD) }

        for name in try directoryNames(
            under: recordingsFD,
            maximumCount: Self.maximumRecordingStagingEntryCount
        ).sorted() {
            guard (try? RecordingID(name)) != nil,
                  let stagingFD = try? openDirectory(components: [name], under: recordingsFD)
            else { continue }
            defer { Darwin.close(stagingFD) }
            guard let identity = try? readIdentity(under: stagingFD),
                  identity.recordingID == recordingID,
                  identity.libraryID == scope.libraryID,
                  identity.recordingID.rawValue == name
            else { continue }
            if let version = try? manifestSchemaVersion(under: stagingFD), version > 1 {
                throw RecordingPersistenceError.invalidStaging
            }
            if let manifest = try? readManifest(under: stagingFD, identity: identity),
               [.publishing, .committed].contains(
                   RecordingManifestPhase(rawValue: manifest.phase)!
               ),
               installedSessionMatches(manifest: manifest, under: rootFD)
            {
                throw RecordingPersistenceError.invalidStaging
            }
            try removeExactStaging(
                named: name,
                stagingDescriptor: stagingFD,
                recordingsDescriptor: recordingsFD
            )
            return
        }
        throw RecordingPersistenceError.invalidStaging
    }

    func stageSeal(
        _ handle: RecordingStagingHandle,
        reason: CaptureTerminalReason
    ) throws -> StagedRecordingSealCandidate {
        guard handle.durableFrameCount > 0 else {
            throw RecordingPersistenceError.emptyRecording
        }
        try validateLibraryIdentity(
            handle.request.libraryScope.libraryID,
            under: handle.rootDescriptor
        )
        let identity = try readIdentity(under: handle.stagingDescriptor)
        let currentManifest = try readManifest(
            under: handle.stagingDescriptor,
            identity: identity
        )
        let currentPhase = RecordingManifestPhase(rawValue: currentManifest.phase)!
        if currentPhase == .committed || currentPhase == .publishing {
            if installedSessionMatches(manifest: currentManifest, under: handle.rootDescriptor) {
                return try candidateFromInstalled(
                    manifest: currentManifest,
                    identity: identity,
                    under: handle.rootDescriptor
                )
            }
        }
        if currentPhase == .recoverable,
           currentManifest.availability == RecordingRecoveryAvailability.discardOnly.rawValue
        {
            throw RecordingPersistenceError.invalidStaging
        }

        let effectiveReason = currentManifest.terminalReason
            .flatMap(CaptureTerminalReason.init(rawValue:)) ?? reason
        try replaceManifest(
            RecordingManifestDTO(
                request: handle.request,
                durableFrameCount: handle.durableFrameCount,
                phase: .sealing,
                terminalReason: effectiveReason
            ),
            under: handle.stagingDescriptor
        )
        let candidateName = "seal-candidate"
        var candidateFD: Int32 = -1
        do {
            try removeExactSealCandidateIfPresent(under: handle.stagingDescriptor)
            guard mkdirat(handle.stagingDescriptor, candidateName, 0o700) == 0 else {
                throw RecordingPersistenceError.ioFailure
            }
            candidateFD = try openDirectory(
                components: [candidateName],
                under: handle.stagingDescriptor
            )
            guard mkdirat(candidateFD, "audio", 0o700) == 0 else {
                throw RecordingPersistenceError.ioFailure
            }
            let audioFD = try openDirectory(components: ["audio"], under: candidateFD)
            defer { Darwin.close(audioFD) }

            try fault(.beforeSealScan)
            let canonical = try writeCanonicalWAV(
                recordDescriptor: handle.streamDescriptor,
                durableFrameCount: handle.durableFrameCount,
                named: "audio.wav",
                under: audioFD
            )
            try fault(.afterCanonicalAudioFlush)
            try flush(audioFD)
            try flush(candidateFD)
            if candidateFD >= 0 { Darwin.close(candidateFD) }
            candidateFD = -1
            return StagedRecordingSealCandidate(
                recordingID: identity.recordingID.rawValue,
                sessionID: identity.sessionID.rawValue,
                libraryID: identity.libraryID.rawValue,
                startedAt: identity.startedAt.rawValue,
                terminalReason: effectiveReason.rawValue,
                sourceKind: AudioSourceKind.microphone.rawValue,
                canonicalAudioPath: "audio/audio.wav",
                sampleRateHz: CanonicalAudioFormat.versionOne.sampleRateHz,
                channelCount: CanonicalAudioFormat.versionOne.channelCount,
                encoding: CanonicalAudioFormat.versionOne.encoding.rawValue,
                frameCount: handle.durableFrameCount,
                canonicalSHA256: canonical.fingerprint.sha256,
                unavailableIntervals: canonical.intervals.map { interval in
                    StagedUnavailableInterval(
                        startFrame: interval.range.startFrame,
                        endFrame: interval.range.endFrame,
                        reasons: interval.reasons.sorted().map(\.rawValue)
                    )
                }
            )
        } catch {
            if candidateFD >= 0 { Darwin.close(candidateFD) }
            try? removeExactSealCandidateIfPresent(under: handle.stagingDescriptor)
            throw error
        }
    }

    func install(
        _ publication: ValidatedRecordingPublication,
        using handle: RecordingStagingHandle
    ) throws -> SessionSealedReceipt {
        try validateLibraryIdentity(
            handle.request.libraryScope.libraryID,
            under: handle.rootDescriptor
        )
        let identity = try readIdentity(under: handle.stagingDescriptor)
        let currentManifest = try readManifest(
            under: handle.stagingDescriptor,
            identity: identity
        )
        if [.publishing, .committed].contains(RecordingManifestPhase(rawValue: currentManifest.phase)!),
           installedSessionMatches(manifest: currentManifest, under: handle.rootDescriptor)
        {
            guard publication.receipt.libraryID == identity.libraryID,
                  publication.receipt.recordingID == identity.recordingID,
                  publication.receipt.sessionID == identity.sessionID,
                  publication.receipt.frameCount == currentManifest.durableFrameCount,
                  publication.receipt.fingerprint.sha256 == currentManifest.canonicalSha256
            else { throw RecordingPersistenceError.invalidStaging }
            return try reconcileCommittedPublication(currentManifest, handle: handle)
        }
        guard RecordingManifestPhase(rawValue: currentManifest.phase) == .sealing,
              try publicationMatches(
                  publication,
                  identity: identity,
                  durableFrameCount: currentManifest.durableFrameCount,
                  streamDescriptor: handle.streamDescriptor,
                  stagingDescriptor: handle.stagingDescriptor
              )
        else {
            throw RecordingPersistenceError.invalidStaging
        }

        let candidateName = "seal-candidate"
        let candidateFD = try openDirectory(
            components: [candidateName],
            under: handle.stagingDescriptor
        )
        defer { Darwin.close(candidateFD) }
        let audioFD = try openDirectory(components: ["audio"], under: candidateFD)
        defer { Darwin.close(audioFD) }
        try writeExclusive(
            deterministicJSON(AudioManifestDTO(asset: publication.session.audio)),
            named: "audio.json",
            under: audioFD
        )
        try fault(.afterAudioManifestFlush)
        try flush(audioFD)
        try writeExclusive(
            deterministicJSON(SessionManifestDTO(session: publication.session)),
            named: "session.json",
            under: candidateFD
        )
        try fault(.afterSessionManifestFlush)
        try flush(candidateFD)

        let publishing = RecordingManifestDTO(
            request: handle.request,
            durableFrameCount: publication.session.audio.frameCount,
            phase: .publishing,
            terminalReason: publication.terminalReason,
            canonicalSHA256: publication.session.audio.fingerprint.sha256
        )
        try replaceManifest(publishing, under: handle.stagingDescriptor)
        try fault(.beforeSessionInstall)
        try validateLibraryIdentity(
            handle.request.libraryScope.libraryID,
            under: handle.rootDescriptor
        )
        do {
            try noReplaceRename(
                from: candidateName,
                under: handle.stagingDescriptor,
                to: handle.request.sessionID.rawValue,
                under: handle.sessionsDescriptor
            )
        } catch RecordingPersistenceError.destinationCollision {
            guard installedSessionMatches(
                manifest: publishing,
                under: handle.rootDescriptor
            ) else {
                throw RecordingPersistenceError.destinationCollision
            }
            try removeExactSealCandidateIfPresent(under: handle.stagingDescriptor)
        }
        do {
            try fault(.afterSessionInstall)
            try flush(handle.sessionsDescriptor)
            try fault(.afterSessionsDirectoryFlush)
            try fault(.beforeInstalledSessionValidation)
            try validateLibraryIdentity(
                handle.request.libraryScope.libraryID,
                under: handle.rootDescriptor
            )
            guard installedSessionMatches(
                manifest: publishing,
                under: handle.rootDescriptor
            ) else {
                throw RecordingPersistenceError.invalidStaging
            }
            return try reconcileCommittedPublication(
                publishing,
                handle: handle,
                injectCleanupFault: true
            )
        } catch {
            if installedSessionMatches(manifest: publishing, under: handle.rootDescriptor) {
                return try reconcileCommittedPublication(publishing, handle: handle)
            }
            throw error
        }
    }
}

private extension RecordingPersistence {
    struct RecordScan {
        let intervals: [UnavailableInterval]
        let canonicalFingerprint: AudioFingerprint?
    }

    func encodeRecord(
        frameCount: UInt64,
        observed: Bool,
        reasons: Set<UnavailableReason>,
        payload: Data
    ) -> Data {
        var flags: UInt8 = observed ? 1 : 0
        if reasons.contains(.muted) { flags |= 1 << 1 }
        if reasons.contains(.captureGap) { flags |= 1 << 2 }
        var data = Data([flags])
        data.appendLittleEndian(frameCount)
        data.appendLittleEndian(UInt64(payload.count))
        data.append(contentsOf: SHA256.hash(data: payload))
        data.append(payload)
        return data
    }

    func scanRecords(
        descriptor: Int32,
        durableFrameCount: UInt64,
        canonicalDescriptor: Int32? = nil
    ) throws -> RecordScan {
        guard durableFrameCount > 0,
              durableFrameCount <= CanonicalRecordingLimits.maximumFrames
        else {
            throw RecordingPersistenceError.invalidStaging
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= Int64(Self.recordMagic.count),
              metadata.st_size <= Int64(Self.maximumRecordStreamBytes)
        else {
            throw RecordingPersistenceError.recordStreamTooLarge
        }
        var cursor: Int64 = 0
        let magic = try preadExact(
            count: Self.recordMagic.count,
            from: descriptor,
            offset: &cursor
        )
        guard magic == Self.recordMagic else {
            throw RecordingPersistenceError.invalidStaging
        }

        var frameCursor: UInt64 = 0
        var recordCount = 0
        var intervals: [UnavailableInterval] = []
        var canonicalHasher = SHA256()
        if let canonicalDescriptor {
            try writeAndHash(
                try wavHeader(frameCount: durableFrameCount),
                to: canonicalDescriptor,
                hasher: &canonicalHasher
            )
        }
        let zeroChunk = Data(repeating: 0, count: 64 * 1_024)
        while frameCursor < durableFrameCount {
            recordCount += 1
            guard recordCount <= recordLimit else {
                throw RecordingPersistenceError.recordStreamTooLarge
            }
            let header = try preadExact(count: 49, from: descriptor, offset: &cursor)
            let flags = header[header.startIndex]
            guard flags & 0b1111_1000 == 0 else {
                throw RecordingPersistenceError.invalidStaging
            }
            let observed = flags & 1 != 0
            var headerCursor = 1
            let frames = header.readLittleEndianUInt64(at: &headerCursor)
            let payloadCount = header.readLittleEndianUInt64(at: &headerCursor)
            let expectedDigest = Data(header[headerCursor..<(headerCursor + 32)])
            guard frames > 0 else { throw RecordingPersistenceError.invalidStaging }
            let (endFrame, overflow) = frameCursor.addingReportingOverflow(frames)
            guard !overflow, endFrame <= durableFrameCount else {
                throw RecordingPersistenceError.invalidStaging
            }
            let reasons = unavailableReasons(from: flags)
            if observed {
                let (expectedBytes, byteOverflow) = frames.multipliedReportingOverflow(by: 2)
                guard !byteOverflow,
                      payloadCount == expectedBytes,
                      reasons.isEmpty,
                      payloadCount <= UInt64(Int.max)
                else {
                    throw RecordingPersistenceError.invalidStaging
                }
            } else {
                guard payloadCount == 0, !reasons.isEmpty else {
                    throw RecordingPersistenceError.invalidStaging
                }
            }
            if observed {
                var remaining = payloadCount
                var payloadHasher = SHA256()
                while remaining > 0 {
                    let count = Int(min(remaining, UInt64(64 * 1_024)))
                    let chunk = try preadExact(
                        count: count,
                        from: descriptor,
                        offset: &cursor
                    )
                    payloadHasher.update(data: chunk)
                    if let canonicalDescriptor {
                        try writeAndHash(
                            chunk,
                            to: canonicalDescriptor,
                            hasher: &canonicalHasher
                        )
                    }
                    remaining -= UInt64(count)
                }
                guard Data(payloadHasher.finalize()) == expectedDigest else {
                    throw RecordingPersistenceError.invalidStaging
                }
            } else {
                guard Data(SHA256.hash(data: Data())) == expectedDigest else {
                    throw RecordingPersistenceError.invalidStaging
                }
                let range = try CanonicalFrameRange(
                    startFrame: frameCursor,
                    endFrame: endFrame,
                    durationFrames: durableFrameCount
                )
                if let last = intervals.last,
                   last.range.endFrame == range.startFrame,
                   last.reasons == reasons
                {
                    intervals.removeLast()
                    intervals.append(
                        try UnavailableInterval(
                            range: CanonicalFrameRange(
                                startFrame: last.range.startFrame,
                                endFrame: range.endFrame,
                                durationFrames: durableFrameCount
                            ),
                            reasons: reasons
                        )
                    )
                } else {
                    guard intervals.count < unavailableIntervalLimit else {
                        throw RecordingPersistenceError.recordStreamTooLarge
                    }
                    intervals.append(try UnavailableInterval(range: range, reasons: reasons))
                }
                if let canonicalDescriptor {
                    var remaining = frames * 2
                    while remaining > 0 {
                        let count = min(remaining, UInt64(zeroChunk.count))
                        let bytes = count == UInt64(zeroChunk.count)
                            ? zeroChunk
                            : Data(zeroChunk.prefix(Int(count)))
                        try writeAndHash(
                            bytes,
                            to: canonicalDescriptor,
                            hasher: &canonicalHasher
                        )
                        remaining -= count
                    }
                }
            }
            frameCursor = endFrame
        }
        // The durable watermark and append stream must describe the same exact
        // prefix. Any complete, arbitrary, or truncated bytes beyond it are
        // ambiguous evidence and therefore cannot be silently dropped.
        guard cursor == metadata.st_size else {
            throw RecordingPersistenceError.invalidStaging
        }
        let fingerprint = canonicalDescriptor == nil
            ? nil
            : try AudioFingerprint(sha256: Data(canonicalHasher.finalize()).hexLowercase)
        return RecordScan(
            intervals: intervals,
            canonicalFingerprint: fingerprint
        )
    }

    func unavailableReasons(from flags: UInt8) -> Set<UnavailableReason> {
        var reasons: Set<UnavailableReason> = []
        if flags & (1 << 1) != 0 { reasons.insert(.muted) }
        if flags & (1 << 2) != 0 { reasons.insert(.captureGap) }
        return reasons
    }

    func writeCanonicalWAV(
        recordDescriptor: Int32,
        durableFrameCount: UInt64,
        named name: String,
        under directory: Int32
    ) throws -> (intervals: [UnavailableInterval], fingerprint: AudioFingerprint) {
        let descriptor = try createRegular(named: name, under: directory)
        var closeRequired = true
        defer { if closeRequired { Darwin.close(descriptor) } }
        let scan = try scanRecords(
            descriptor: recordDescriptor,
            durableFrameCount: durableFrameCount,
            canonicalDescriptor: descriptor
        )
        try flush(descriptor)
        guard Darwin.close(descriptor) == 0 else {
            closeRequired = false
            throw RecordingPersistenceError.ioFailure
        }
        closeRequired = false
        guard let fingerprint = scan.canonicalFingerprint else {
            throw RecordingPersistenceError.ioFailure
        }
        return (scan.intervals, fingerprint)
    }

    func writeAndHash(
        _ data: Data,
        to descriptor: Int32,
        hasher: inout SHA256
    ) throws {
        try writeAll(data, to: descriptor)
        hasher.update(data: data)
    }

    func wavHeader(frameCount: UInt64) throws -> Data {
        let (audioBytes, overflow) = frameCount.multipliedReportingOverflow(by: 2)
        guard !overflow,
              audioBytes <= UInt64(UInt32.max) - 36
        else {
            throw RecordingPersistenceError.durationExceeded
        }
        var result = Data("RIFF".utf8)
        result.appendLittleEndian(UInt32(audioBytes + 36))
        result.append(Data("WAVEfmt ".utf8))
        result.appendLittleEndian(UInt32(16))
        result.appendLittleEndian(UInt16(1))
        result.appendLittleEndian(UInt16(1))
        result.appendLittleEndian(UInt32(16_000))
        result.appendLittleEndian(UInt32(32_000))
        result.appendLittleEndian(UInt16(2))
        result.appendLittleEndian(UInt16(16))
        result.append(Data("data".utf8))
        result.appendLittleEndian(UInt32(audioBytes))
        guard result.count == Self.wavHeaderBytes else {
            throw RecordingPersistenceError.ioFailure
        }
        return result
    }
}

private extension RecordingPersistence {
    func replaceManifest(
        _ manifest: RecordingManifestDTO,
        under stagingDescriptor: Int32
    ) throws {
        let name = ".recording.\(UUID().uuidString).partial"
        do {
            try writeExclusive(
                deterministicJSON(manifest),
                named: name,
                under: stagingDescriptor
            )
            guard renameat(stagingDescriptor, name, stagingDescriptor, "recording.json") == 0 else {
                throw RecordingPersistenceError.ioFailure
            }
            try flush(stagingDescriptor)
        } catch {
            _ = unlinkat(stagingDescriptor, name, 0)
            throw error
        }
    }

    func readIdentity(under stagingDescriptor: Int32) throws -> DecodedRecordingIdentity {
        let data = try readBoundedRegular(
            named: "identity.json",
            under: stagingDescriptor,
            maximumBytes: 16_384
        )
        try requireExactKeys(
            data,
            [
                "schemaVersion", "recordingId", "sessionId", "libraryId",
                "startedAt", "canonicalFormat", "maximumFrames", "recordStreamFormat",
            ]
        )
        let dictionary = try jsonDictionary(data)
        try requireCanonicalFormatShape(dictionary["canonicalFormat"])
        let dto = try decode(RecordingIdentityDTO.self, data)
        guard dto.schemaVersion == 1,
              dto.recordStreamFormat == "audora-record-stream-v1",
              dto.maximumFrames == CanonicalRecordingLimits.maximumFrames,
              dto.canonicalFormat == .versionOne,
              let recordingID = try? RecordingID(dto.recordingId),
              let sessionID = try? SessionID(dto.sessionId),
              let libraryID = try? LibraryID(dto.libraryId),
              let startedAt = try? UTCInstant(dto.startedAt)
        else {
            throw RecordingPersistenceError.invalidStaging
        }
        return DecodedRecordingIdentity(
            recordingID: recordingID,
            sessionID: sessionID,
            libraryID: libraryID,
            startedAt: startedAt
        )
    }

    func readManifest(
        under stagingDescriptor: Int32,
        identity: DecodedRecordingIdentity
    ) throws -> RecordingManifestDTO {
        let data = try readBoundedRegular(
            named: "recording.json",
            under: stagingDescriptor,
            maximumBytes: 16_384
        )
        guard try confined.schemaVersion(in: data) == 1 else {
            throw RecordingPersistenceError.invalidStaging
        }
        let dictionary = try jsonDictionary(data)
        let common: Set<String> = [
            "schemaVersion", "recordingId", "sessionId", "libraryId", "startedAt",
            "canonicalFormat", "maximumFrames", "recordStreamFormat", "durableFrameCount",
            "phase",
        ]
        guard let phase = dictionary["phase"] as? String else {
            throw RecordingPersistenceError.invalidStaging
        }
        try requireCanonicalFormatShape(dictionary["canonicalFormat"])
        let extra: Set<String>
        switch phase {
        case "capturing":
            extra = []
        case "recoverable":
            extra = ["availability"]
        case "sealing":
            extra = ["terminalReason"]
        case "publishing", "committed":
            extra = ["terminalReason", "canonicalSha256"]
        default:
            throw RecordingPersistenceError.invalidStaging
        }
        guard Set(dictionary.keys) == common.union(extra) else {
            throw RecordingPersistenceError.invalidStaging
        }
        let dto = try decode(RecordingManifestDTO.self, data)
        guard dto.schemaVersion == 1,
              dto.recordingId == identity.recordingID.rawValue,
              dto.sessionId == identity.sessionID.rawValue,
              dto.libraryId == identity.libraryID.rawValue,
              dto.startedAt == identity.startedAt.rawValue,
              dto.canonicalFormat == .versionOne,
              dto.maximumFrames == CanonicalRecordingLimits.maximumFrames,
              dto.recordStreamFormat == "audora-record-stream-v1",
              dto.durableFrameCount <= dto.maximumFrames,
              RecordingManifestPhase(rawValue: dto.phase) != nil
        else {
            throw RecordingPersistenceError.invalidStaging
        }
        switch RecordingManifestPhase(rawValue: dto.phase)! {
        case .capturing:
            guard dto.availability == nil,
                  dto.terminalReason == nil,
                  dto.canonicalSha256 == nil
            else { throw RecordingPersistenceError.invalidStaging }
        case .recoverable:
            guard dto.availability == RecordingRecoveryAvailability.sealOrDiscard.rawValue ||
                    dto.availability == RecordingRecoveryAvailability.discardOnly.rawValue,
                  dto.terminalReason == nil,
                  dto.canonicalSha256 == nil
            else { throw RecordingPersistenceError.invalidStaging }
        case .sealing:
            guard dto.availability == nil,
                  dto.terminalReason.flatMap(CaptureTerminalReason.init(rawValue:)) != nil,
                  dto.canonicalSha256 == nil
            else { throw RecordingPersistenceError.invalidStaging }
        case .publishing, .committed:
            guard dto.availability == nil,
                  dto.terminalReason.flatMap(CaptureTerminalReason.init(rawValue:)) != nil,
                  dto.canonicalSha256 != nil
            else { throw RecordingPersistenceError.invalidStaging }
        }
        if let sha = dto.canonicalSha256,
           (try? AudioFingerprint(sha256: sha)) == nil
        {
            throw RecordingPersistenceError.invalidStaging
        }
        return dto
    }

    func manifestSchemaVersion(under stagingDescriptor: Int32) throws -> UInt64 {
        try jsonSchemaVersion(named: "recording.json", under: stagingDescriptor)
    }

    func jsonSchemaVersion(named name: String, under descriptor: Int32) throws -> UInt64 {
        let data = try readBoundedRegular(
            named: name,
            under: descriptor,
            maximumBytes: 16_384
        )
        return try confined.schemaVersion(in: data)
    }

    func installedSessionMatches(
        manifest: RecordingManifestDTO,
        under rootDescriptor: Int32
    ) -> Bool {
        guard let expectedSHA = manifest.canonicalSha256,
              let sessionFD = try? openDirectory(
                  components: ["sessions", manifest.sessionId],
                  under: rootDescriptor
              )
        else {
            return false
        }
        defer { Darwin.close(sessionFD) }
        guard let sessionData = try? readBoundedRegular(
                  named: "session.json",
                  under: sessionFD,
                  maximumBytes: 16_384
              ),
              (try? requireExactKeys(
                  sessionData,
                  ["schemaVersion", "sessionId", "createdAt", "audioManifestPath"]
              )) != nil,
              let sessionDTO = try? decode(SessionManifestDTO.self, sessionData),
              sessionDTO.schemaVersion == 1,
              sessionDTO.sessionId == manifest.sessionId,
              sessionDTO.createdAt == manifest.startedAt,
              sessionDTO.audioManifestPath == "audio/audio.json",
              let audioFD = try? openDirectory(components: ["audio"], under: sessionFD)
        else {
            return false
        }
        defer { Darwin.close(audioFD) }
        guard let audioData = try? readBoundedRegular(
                  named: "audio.json",
                  under: audioFD,
                  maximumBytes: 1_048_576
              ),
              let audioDTO = try? decodeAndValidateAudioManifest(audioData),
              audioDTO.frameCount == manifest.durableFrameCount,
              audioDTO.canonicalSha256 == expectedSHA,
              let wavFD = try? openRegular(named: "audio.wav", under: audioFD, flags: O_RDONLY)
        else {
            return false
        }
        defer { Darwin.close(wavFD) }
        guard validateCanonicalWAV(
            descriptor: wavFD,
            frameCount: audioDTO.frameCount
        ) else {
            return false
        }
        guard let digest = try? sha256OfRegular(
            descriptor: wavFD,
            maximumBytes: CanonicalRecordingLimits.maximumFrames * 2 + 44
        ) else {
            return false
        }
        return digest == expectedSHA
    }

    func publicationMatches(
        _ publication: ValidatedRecordingPublication,
        identity: DecodedRecordingIdentity,
        durableFrameCount: UInt64,
        streamDescriptor: Int32,
        stagingDescriptor: Int32
    ) throws -> Bool {
        let candidate = publication.candidate
        let session = publication.session
        guard candidate.recordingID == identity.recordingID.rawValue,
              candidate.sessionID == identity.sessionID.rawValue,
              candidate.libraryID == identity.libraryID.rawValue,
              candidate.startedAt == identity.startedAt.rawValue,
              candidate.terminalReason == publication.terminalReason.rawValue,
              session.sessionID == identity.sessionID,
              session.createdAt == identity.startedAt,
              session.audioManifestPath.description == "audio/audio.json",
              session.audio.source == .microphone,
              session.audio.format == .versionOne,
              session.audio.canonicalAudioPath.description == "audio/audio.wav",
              session.audio.frameCount == durableFrameCount,
              session.audio.fingerprint.sha256 == candidate.canonicalSHA256,
              candidate.frameCount == durableFrameCount,
              candidate.unavailableIntervals.count <=
                StagedRecordingSealCandidate.maximumUnavailableIntervalCount
        else {
            return false
        }
        let expectedIntervals = session.audio.unavailableIntervals.map { interval in
            StagedUnavailableInterval(
                startFrame: interval.range.startFrame,
                endFrame: interval.range.endFrame,
                reasons: interval.reasons.sorted().map(\.rawValue)
            )
        }
        guard candidate.unavailableIntervals == expectedIntervals else { return false }
        let scan = try scanRecords(
            descriptor: streamDescriptor,
            durableFrameCount: durableFrameCount
        )
        guard scan.intervals == session.audio.unavailableIntervals else { return false }
        let audioFD = try openDirectory(
            components: ["seal-candidate", "audio"],
            under: stagingDescriptor
        )
        defer { Darwin.close(audioFD) }
        let wavFD = try openRegular(named: "audio.wav", under: audioFD, flags: O_RDONLY)
        defer { Darwin.close(wavFD) }
        guard validateCanonicalWAV(descriptor: wavFD, frameCount: durableFrameCount) else {
            return false
        }
        return try sha256OfRegular(
            descriptor: wavFD,
            maximumBytes: CanonicalRecordingLimits.maximumFrames * 2 + 44
        ) == candidate.canonicalSHA256
    }

    func candidateFromInstalled(
        manifest: RecordingManifestDTO,
        identity: DecodedRecordingIdentity,
        under rootDescriptor: Int32
    ) throws -> StagedRecordingSealCandidate {
        guard installedSessionMatches(manifest: manifest, under: rootDescriptor),
              let reason = manifest.terminalReason,
              let sha = manifest.canonicalSha256
        else {
            throw RecordingPersistenceError.invalidStaging
        }
        let sessionFD = try openDirectory(
            components: ["sessions", identity.sessionID.rawValue],
            under: rootDescriptor
        )
        defer { Darwin.close(sessionFD) }
        let audioFD = try openDirectory(components: ["audio"], under: sessionFD)
        defer { Darwin.close(audioFD) }
        let audioData = try readBoundedRegular(
            named: "audio.json",
            under: audioFD,
            maximumBytes: 1_048_576
        )
        let audio = try decodeAndValidateAudioManifest(audioData)
        guard audio.frameCount == manifest.durableFrameCount,
              audio.canonicalSha256 == sha,
              audio.unavailableIntervals.count <=
                StagedRecordingSealCandidate.maximumUnavailableIntervalCount
        else {
            throw RecordingPersistenceError.invalidStaging
        }
        return StagedRecordingSealCandidate(
            recordingID: identity.recordingID.rawValue,
            sessionID: identity.sessionID.rawValue,
            libraryID: identity.libraryID.rawValue,
            startedAt: identity.startedAt.rawValue,
            terminalReason: reason,
            sourceKind: audio.sourceKind,
            canonicalAudioPath: audio.canonicalAudioPath,
            sampleRateHz: audio.canonicalFormat.sampleRateHz,
            channelCount: audio.canonicalFormat.channelCount,
            encoding: audio.canonicalFormat.encoding,
            frameCount: audio.frameCount,
            canonicalSHA256: audio.canonicalSha256,
            unavailableIntervals: audio.unavailableIntervals.map {
                StagedUnavailableInterval(
                    startFrame: $0.startFrame,
                    endFrame: $0.endFrame,
                    reasons: $0.reasons
                )
            }
        )
    }

    func decodeAndValidateAudioManifest(_ data: Data) throws -> AudioManifestDTO {
        try requireExactKeys(
            data,
            [
                "schemaVersion", "sourceKind", "canonicalAudioPath", "canonicalFormat",
                "frameCount", "canonicalSha256", "unavailableIntervals",
            ]
        )
        let dictionary = try jsonDictionary(data)
        try requireCanonicalFormatShape(dictionary["canonicalFormat"])
        guard let intervalObjects = dictionary["unavailableIntervals"] as? [[String: Any]],
              intervalObjects.count <= Self.maximumUnavailableIntervalCount
        else {
            throw RecordingPersistenceError.invalidStaging
        }
        for interval in intervalObjects {
            guard Set(interval.keys) == ["startFrame", "endFrame", "reasons"],
                  interval["reasons"] is [String]
            else {
                throw RecordingPersistenceError.invalidStaging
            }
        }
        let dto = try decode(AudioManifestDTO.self, data)
        guard dto.schemaVersion == 1,
              dto.sourceKind == "microphone",
              dto.canonicalAudioPath == "audio/audio.wav",
              dto.canonicalFormat == .versionOne,
              dto.frameCount > 0,
              dto.frameCount <= CanonicalRecordingLimits.maximumFrames,
              (try? AudioFingerprint(sha256: dto.canonicalSha256)) != nil
        else {
            throw RecordingPersistenceError.invalidStaging
        }
        let intervals = try dto.unavailableIntervals.map { try $0.domain(duration: dto.frameCount) }
        guard try UnavailableIntervalNormalizer.normalize(
            intervals,
            durationFrames: dto.frameCount
        ) == intervals else {
            throw RecordingPersistenceError.invalidStaging
        }
        return dto
    }

    func validateLibraryIdentity(_ expected: LibraryID, under rootDescriptor: Int32) throws {
        do {
            guard case let .readWrite(authority) = try PortableLibraryPersistence()
                .load(from: rootDescriptor),
                authority.manifest.libraryID == expected
            else {
                throw RecordingPersistenceError.invalidLibraryAuthority
            }
        } catch {
            throw RecordingPersistenceError.invalidLibraryAuthority
        }
    }

    func receipt(
        from manifest: RecordingManifestDTO,
        identity: DecodedRecordingIdentity
    ) -> SessionSealedReceipt? {
        guard let sha = manifest.canonicalSha256,
              manifest.durableFrameCount > 0,
              let fingerprint = try? AudioFingerprint(sha256: sha)
        else { return nil }
        return SessionSealedReceipt(
            libraryID: identity.libraryID,
            recordingID: identity.recordingID,
            sessionID: identity.sessionID,
            frameCount: manifest.durableFrameCount,
            fingerprint: fingerprint
        )
    }

    func reconcileCommittedPublication(
        _ publishing: RecordingManifestDTO,
        handle: RecordingStagingHandle,
        injectCleanupFault: Bool = false
    ) throws -> SessionSealedReceipt {
        try validateLibraryIdentity(
            handle.request.libraryScope.libraryID,
            under: handle.rootDescriptor
        )
        try flush(handle.sessionsDescriptor)
        guard installedSessionMatches(
            manifest: publishing,
            under: handle.rootDescriptor
        ),
            let sha = publishing.canonicalSha256,
            let fingerprint = try? AudioFingerprint(sha256: sha)
        else {
            throw RecordingPersistenceError.invalidStaging
        }
        try replaceManifest(
            RecordingManifestDTO(
                request: handle.request,
                durableFrameCount: publishing.durableFrameCount,
                phase: .committed,
                terminalReason: publishing.terminalReason
                    .flatMap(CaptureTerminalReason.init(rawValue:)) ?? .interruption,
                canonicalSHA256: sha
            ),
            under: handle.stagingDescriptor
        )
        let receipt = SessionSealedReceipt(
            libraryID: handle.request.libraryScope.libraryID,
            recordingID: handle.request.recordingID,
            sessionID: handle.request.sessionID,
            frameCount: publishing.durableFrameCount,
            fingerprint: fingerprint
        )
        do {
            if injectCleanupFault { try fault(.beforeStagingCleanup) }
            try removeExactStaging(
                named: handle.request.recordingID.rawValue,
                stagingDescriptor: handle.stagingDescriptor,
                recordingsDescriptor: handle.recordingsDescriptor
            )
        } catch {
            // Cleanup cannot revoke an already installed, structurally reread
            // Session. Its committed staging identity remains the durable,
            // exact retry authority discovered by `inspectRecovery`.
        }
        return receipt
    }

    func requireCanonicalFormatShape(_ value: Any?) throws {
        guard let format = value as? [String: Any],
              Set(format.keys) == ["sampleRateHz", "channelCount", "encoding"]
        else {
            throw RecordingPersistenceError.invalidStaging
        }
    }

    func validateCanonicalWAV(descriptor: Int32, frameCount: UInt64) -> Bool {
        let (audioBytes, overflow) = frameCount.multipliedReportingOverflow(by: 2)
        guard !overflow else { return false }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_size == Int64(audioBytes + UInt64(Self.wavHeaderBytes)),
              let expectedHeader = try? wavHeader(frameCount: frameCount)
        else {
            return false
        }
        var offset: Int64 = 0
        return (try? preadBoundedExact(
            count: Self.wavHeaderBytes,
            from: descriptor,
            offset: &offset,
            maximumBytes: Self.wavHeaderBytes
        )) == expectedHeader
    }

    func removeExactStaging(
        named name: String,
        stagingDescriptor: Int32,
        recordingsDescriptor: Int32
    ) throws {
        let ownedChildren: Set<String> = [
            "recording.json", "identity.json", "records.bin", "seal-candidate",
        ]
        let presentChildren = Set(try directoryNames(under: stagingDescriptor))
        guard presentChildren.isSubset(of: ownedChildren) else {
            // Never partially clean an aggregate whose contents are no longer
            // exactly the files owned by this implementation.
            throw RecordingPersistenceError.unsafeEntry
        }
        // Preflight the complete candidate subtree before any mutation.
        try validateExactSealCandidateLayoutIfPresent(under: stagingDescriptor)
        try removeExactSealCandidateIfPresent(under: stagingDescriptor)
        for child in ownedChildren.subtracting(["seal-candidate"]).sorted() {
            if unlinkat(stagingDescriptor, child, 0) != 0, errno != ENOENT {
                throw RecordingPersistenceError.ioFailure
            }
        }
        guard unlinkat(recordingsDescriptor, name, AT_REMOVEDIR) == 0 else {
            throw RecordingPersistenceError.ioFailure
        }
        try flush(recordingsDescriptor)
    }

    func removeExactSealCandidateIfPresent(under stagingDescriptor: Int32) throws {
        let name = "seal-candidate"
        guard try entryExists(named: name, under: stagingDescriptor) else { return }
        try validateExactSealCandidateLayoutIfPresent(under: stagingDescriptor)
        guard let candidateFD = try? openDirectory(
            components: [name],
            under: stagingDescriptor
        ) else { throw RecordingPersistenceError.unsafeEntry }
        defer { Darwin.close(candidateFD) }
        guard Set(try directoryNames(under: candidateFD)).isSubset(
            of: Set(["audio", "session.json"])
        )
        else { throw RecordingPersistenceError.unsafeEntry }
        if let audioFD = try? openDirectory(components: ["audio"], under: candidateFD) {
            defer { Darwin.close(audioFD) }
            guard Set(try directoryNames(under: audioFD)).isSubset(
                of: Set(["audio.wav", "audio.json"])
            )
            else { throw RecordingPersistenceError.unsafeEntry }
            _ = unlinkat(audioFD, "audio.wav", 0)
            _ = unlinkat(audioFD, "audio.json", 0)
        }
        _ = unlinkat(candidateFD, "session.json", 0)
        _ = unlinkat(candidateFD, "audio", AT_REMOVEDIR)
        guard unlinkat(stagingDescriptor, name, AT_REMOVEDIR) == 0 else {
            throw RecordingPersistenceError.ioFailure
        }
        try flush(stagingDescriptor)
    }

    func validateExactSealCandidateLayoutIfPresent(
        under stagingDescriptor: Int32
    ) throws {
        let name = "seal-candidate"
        guard try entryExists(named: name, under: stagingDescriptor) else { return }
        let candidateFD = try openDirectory(components: [name], under: stagingDescriptor)
        defer { Darwin.close(candidateFD) }
        let candidateChildren = Set(try directoryNames(under: candidateFD))
        guard candidateChildren.isSubset(of: Set(["audio", "session.json"])) else {
            throw RecordingPersistenceError.unsafeEntry
        }
        if candidateChildren.contains("audio") {
            let audioFD = try openDirectory(components: ["audio"], under: candidateFD)
            defer { Darwin.close(audioFD) }
            guard Set(try directoryNames(under: audioFD)).isSubset(
                of: Set(["audio.wav", "audio.json"])
            ) else {
                throw RecordingPersistenceError.unsafeEntry
            }
        }
    }

    func isOwnedStagingPartialName(_ name: String) -> Bool {
        ownedRecordingID(fromPartialName: name) != nil
    }

    func ownedRecordingID(fromPartialName name: String) -> RecordingID? {
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0].isEmpty,
              components[3] == "partial",
              UUID(uuidString: String(components[2])) != nil
        else { return nil }
        return try? RecordingID(String(components[1]))
    }

    func isOwnedManifestPartialName(_ name: String) -> Bool {
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 4 &&
            components[0].isEmpty &&
            components[1] == "recording" &&
            components[3] == "partial" &&
            UUID(uuidString: String(components[2])) != nil
    }

    /// Reaps only an exact prepare-time directory generated by this version.
    /// Unknown children, newer JSON, malformed durable roots, and oversized
    /// directories are preserved without partial deletion.
    func reconcileOwnedStagingPartial(
        named name: String,
        libraryID: LibraryID,
        under recordingsDescriptor: Int32
    ) throws {
        guard let pathRecordingID = ownedRecordingID(fromPartialName: name) else { return }
        let partialFD = try openDirectory(components: [name], under: recordingsDescriptor)
        defer { Darwin.close(partialFD) }
        let children = try directoryNames(
            under: partialFD,
            maximumCount: Self.maximumOwnedDirectoryEntryCount
        )
        if children.isEmpty {
            guard unlinkat(recordingsDescriptor, name, AT_REMOVEDIR) == 0 else {
                throw RecordingPersistenceError.ioFailure
            }
            try flush(recordingsDescriptor)
            return
        }

        guard children.contains("identity.json"),
              let identity = try? readIdentity(under: partialFD),
              identity.recordingID == pathRecordingID,
              identity.libraryID == libraryID
        else { return }
        let allowed = Set(["identity.json", "records.bin", "recording.json"])
        guard children.allSatisfy({ allowed.contains($0) || isOwnedManifestPartialName($0) })
        else { return }

        for child in children {
            let descriptor = try openRegular(named: child, under: partialFD, flags: O_RDONLY)
            Darwin.close(descriptor)
            if child == "recording.json" {
                guard (try? jsonSchemaVersion(named: child, under: partialFD)) == 1,
                      (try? readManifest(under: partialFD, identity: identity)) != nil
                else { return }
            } else if isOwnedManifestPartialName(child),
                      let version = try? jsonSchemaVersion(named: child, under: partialFD),
                      version > 1 {
                return
            }
        }
        for child in children.sorted() {
            guard unlinkat(partialFD, child, 0) == 0 else {
                throw RecordingPersistenceError.ioFailure
            }
        }
        guard unlinkat(recordingsDescriptor, name, AT_REMOVEDIR) == 0 else {
            throw RecordingPersistenceError.ioFailure
        }
        try flush(recordingsDescriptor)
    }

    /// Deletes only replaceManifest scratch files in a validated current-v1
    /// Recording root. A newer scratch schema is retained byte-for-byte.
    func reconcileOwnedManifestPartials(
        identity: DecodedRecordingIdentity,
        under stagingDescriptor: Int32
    ) throws -> Bool {
        _ = identity
        let children = try directoryNames(
            under: stagingDescriptor,
            maximumCount: Self.maximumOwnedDirectoryEntryCount
        )
        var removed = false
        for name in children.sorted() where isOwnedManifestPartialName(name) {
            let descriptor = try openRegular(named: name, under: stagingDescriptor, flags: O_RDONLY)
            Darwin.close(descriptor)
            if let version = try? jsonSchemaVersion(named: name, under: stagingDescriptor),
               version > 1 {
                return false
            }
            guard unlinkat(stagingDescriptor, name, 0) == 0 else {
                throw RecordingPersistenceError.ioFailure
            }
            removed = true
        }
        if removed { try flush(stagingDescriptor) }
        return true
    }
}

private extension RecordingPersistence {
    func openDirectory(at url: URL) throws -> Int32 {
        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw RecordingPersistenceError.ioFailure }
        return descriptor
    }

    func openDirectory(components: [String], under parent: Int32) throws -> Int32 {
        var current = Darwin.dup(parent)
        guard current >= 0 else { throw RecordingPersistenceError.ioFailure }
        do {
            for component in components {
                guard !component.isEmpty,
                      component != ".",
                      component != "..",
                      !component.contains("/")
                else {
                    throw RecordingPersistenceError.unsafeEntry
                }
                let next = try confined.openDirectory(named: component, under: current)
                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    func createRegular(named name: String, under parent: Int32) throws -> Int32 {
        guard safeName(name) else { throw RecordingPersistenceError.unsafeEntry }
        let descriptor = name.withCString { pointer in
            Darwin.openat(
                parent,
                pointer,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard descriptor >= 0 else { throw RecordingPersistenceError.ioFailure }
        return descriptor
    }

    func openRegular(named name: String, under parent: Int32, flags: Int32) throws -> Int32 {
        guard safeName(name) else { throw RecordingPersistenceError.unsafeEntry }
        let descriptor = name.withCString { pointer in
            Darwin.openat(parent, pointer, flags | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw RecordingPersistenceError.ioFailure }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG
        else {
            Darwin.close(descriptor)
            throw RecordingPersistenceError.unsafeEntry
        }
        return descriptor
    }

    func writeExclusive(_ data: Data, named name: String, under parent: Int32) throws {
        guard safeName(name) else { throw RecordingPersistenceError.unsafeEntry }
        try confined.writeExclusive(
            data,
            named: name,
            under: parent,
            flushBeforeClose: true
        )
    }

    func writeAll(_ data: Data, to descriptor: Int32) throws {
        let success = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if result == 0 { return false }
                offset += result
            }
            return true
        }
        guard success else { throw RecordingPersistenceError.ioFailure }
    }

    func preadExact(
        count: Int,
        from descriptor: Int32,
        offset: inout Int64
    ) throws -> Data {
        guard count >= 0,
              offset >= 0,
              offset <= Int64(Self.maximumRecordStreamBytes),
              Int64(count) <= Int64(Self.maximumRecordStreamBytes) - offset
        else {
            throw RecordingPersistenceError.recordStreamTooLarge
        }
        var data = Data(count: count)
        let readCount = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var total = 0
            while total < buffer.count {
                let result = Darwin.pread(
                    descriptor,
                    base.advanced(by: total),
                    buffer.count - total,
                    offset + Int64(total)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                if result == 0 { break }
                total += result
            }
            return total
        }
        guard readCount == count else { throw RecordingPersistenceError.invalidStaging }
        offset += Int64(count)
        return data
    }

    func readBoundedRegular(
        named name: String,
        under parent: Int32,
        maximumBytes: Int
    ) throws -> Data {
        guard safeName(name) else { throw RecordingPersistenceError.unsafeEntry }
        return try confined.boundedData(
            named: name,
            under: parent,
            maximumBytes: maximumBytes
        )
    }

    func preadBoundedExact(
        count: Int,
        from descriptor: Int32,
        offset: inout Int64,
        maximumBytes: Int
    ) throws -> Data {
        guard count >= 0, count <= maximumBytes else {
            throw RecordingPersistenceError.invalidStaging
        }
        var data = Data(count: count)
        let total = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var readTotal = 0
            while readTotal < buffer.count {
                let result = Darwin.pread(
                    descriptor,
                    base.advanced(by: readTotal),
                    buffer.count - readTotal,
                    offset + Int64(readTotal)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                if result == 0 { break }
                readTotal += result
            }
            return readTotal
        }
        guard total == count else { throw RecordingPersistenceError.ioFailure }
        offset += Int64(count)
        return data
    }

    func flush(_ descriptor: Int32) throws {
        try confined.flush(descriptor)
    }

    func noReplaceRename(from source: String, to destination: String, under parent: Int32) throws {
        try noReplaceRename(
            from: source,
            under: parent,
            to: destination,
            under: parent
        )
    }

    func noReplaceRename(
        from source: String,
        under sourceParent: Int32,
        to destination: String,
        under destinationParent: Int32
    ) throws {
        guard safeName(source), safeName(destination) else {
            throw RecordingPersistenceError.unsafeEntry
        }
        try confined.renameNoReplace(
            from: source,
            under: sourceParent,
            to: destination,
            under: destinationParent,
            collision: .destinationCollision
        )
    }

    func entryExists(named name: String, under parent: Int32) throws -> Bool {
        guard safeName(name) else { throw RecordingPersistenceError.unsafeEntry }
        return try confined.entryExists(named: name, under: parent)
    }

    func directoryNames(
        under descriptor: Int32,
        maximumCount: Int = Self.maximumOwnedDirectoryEntryCount
    ) throws -> [String] {
        // `dup` shares a directory stream offset with the source descriptor.
        // Reset before each bounded read so repeated preflight passes cannot
        // mistake an exhausted descriptor for an empty directory.
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw RecordingPersistenceError.ioFailure
        }
        let names = try confined.listEntryNames(
            under: descriptor,
            maximumCount: maximumCount
        )
        guard names.allSatisfy(safeName) else {
            throw RecordingPersistenceError.unsafeEntry
        }
        return names
    }

    func safeName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }

    func deterministicJSON<T: Encodable>(_ value: T) throws -> Data {
        try confined.deterministicJSON(value)
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try confined.decode(type, from: data)
    }

    func jsonDictionary(_ data: Data) throws -> [String: Any] {
        try confined.jsonDictionary(data)
    }

    func requireExactKeys(_ data: Data, _ expected: Set<String>) throws {
        try confined.requireExactKeys(try jsonDictionary(data), expected)
    }

    func sha256OfRegular(descriptor: Int32, maximumBytes: UInt64) throws -> String {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) <= maximumBytes
        else {
            throw RecordingPersistenceError.invalidStaging
        }
        var hasher = SHA256()
        var offset: Int64 = 0
        while offset < metadata.st_size {
            let count = min(64 * 1_024, Int(metadata.st_size - offset))
            var boundedOffset = offset
            let chunk = try preadBoundedExact(
                count: count,
                from: descriptor,
                offset: &boundedOffset,
                maximumBytes: 64 * 1_024
            )
            hasher.update(data: chunk)
            offset = boundedOffset
        }
        return Data(hasher.finalize()).hexLowercase
    }
}

private struct CanonicalAudioFormatDTO: Codable, Equatable {
    let sampleRateHz: UInt32
    let channelCount: UInt8
    let encoding: String

    init(_ format: CanonicalAudioFormat) {
        sampleRateHz = format.sampleRateHz
        channelCount = format.channelCount
        encoding = format.encoding.rawValue
    }

    static func == (lhs: Self, rhs: CanonicalAudioFormat) -> Bool {
        lhs.sampleRateHz == rhs.sampleRateHz &&
            lhs.channelCount == rhs.channelCount &&
            lhs.encoding == rhs.encoding.rawValue
    }
}

private struct RecordingIdentityDTO: Codable {
    let schemaVersion: UInt64
    let recordingId: String
    let sessionId: String
    let libraryId: String
    let startedAt: String
    let canonicalFormat: CanonicalAudioFormatDTO
    let maximumFrames: UInt64
    let recordStreamFormat: String

    init(request: MicrophoneRecordingRequest) {
        schemaVersion = 1
        recordingId = request.recordingID.rawValue
        sessionId = request.sessionID.rawValue
        libraryId = request.libraryScope.libraryID.rawValue
        startedAt = request.startedAt.rawValue
        canonicalFormat = CanonicalAudioFormatDTO(request.canonicalFormat)
        maximumFrames = request.maximumFrames
        recordStreamFormat = "audora-record-stream-v1"
    }
}

private enum RecordingManifestPhase: String, Codable {
    case capturing
    case recoverable
    case sealing
    case publishing
    case committed
}

private struct RecordingManifestDTO: Codable {
    let schemaVersion: UInt64
    let recordingId: String
    let sessionId: String
    let libraryId: String
    let startedAt: String
    let canonicalFormat: CanonicalAudioFormatDTO
    let maximumFrames: UInt64
    let recordStreamFormat: String
    let durableFrameCount: UInt64
    let phase: String
    let availability: String?
    let terminalReason: String?
    let canonicalSha256: String?

    init(
        request: MicrophoneRecordingRequest,
        durableFrameCount: UInt64,
        phase: RecordingManifestPhase,
        availability: RecordingRecoveryAvailability? = nil,
        terminalReason: CaptureTerminalReason? = nil,
        canonicalSHA256: String? = nil
    ) {
        schemaVersion = 1
        recordingId = request.recordingID.rawValue
        sessionId = request.sessionID.rawValue
        libraryId = request.libraryScope.libraryID.rawValue
        startedAt = request.startedAt.rawValue
        canonicalFormat = CanonicalAudioFormatDTO(request.canonicalFormat)
        maximumFrames = request.maximumFrames
        recordStreamFormat = "audora-record-stream-v1"
        self.durableFrameCount = durableFrameCount
        self.phase = phase.rawValue
        self.availability = availability?.rawValue
        self.terminalReason = terminalReason?.rawValue
        canonicalSha256 = canonicalSHA256
    }
}

private struct DecodedRecordingIdentity {
    let recordingID: RecordingID
    let sessionID: SessionID
    let libraryID: LibraryID
    let startedAt: UTCInstant

    var request: MicrophoneRecordingRequest {
        MicrophoneRecordingRequest(
            libraryScope: LibraryScope(libraryID: libraryID),
            recordingID: recordingID,
            sessionID: sessionID,
            startedAt: startedAt
        )
    }
}

private struct UnavailableIntervalDTO: Codable {
    let startFrame: UInt64
    let endFrame: UInt64
    let reasons: [String]

    init(_ interval: UnavailableInterval) {
        startFrame = interval.range.startFrame
        endFrame = interval.range.endFrame
        reasons = interval.reasons.sorted().map(\.rawValue)
    }

    func domain(duration: UInt64) throws -> UnavailableInterval {
        let parsedReasons = reasons.compactMap(UnavailableReason.init(rawValue:))
        guard parsedReasons.count == reasons.count,
              Set(parsedReasons).count == reasons.count,
              reasons == parsedReasons.sorted().map(\.rawValue)
        else {
            throw RecordingPersistenceError.invalidStaging
        }
        return try UnavailableInterval(
            range: CanonicalFrameRange(
                startFrame: startFrame,
                endFrame: endFrame,
                durationFrames: duration
            ),
            reasons: Set(parsedReasons)
        )
    }
}

private struct AudioManifestDTO: Codable {
    let schemaVersion: UInt64
    let sourceKind: String
    let canonicalAudioPath: String
    let canonicalFormat: CanonicalAudioFormatDTO
    let frameCount: UInt64
    let canonicalSha256: String
    let unavailableIntervals: [UnavailableIntervalDTO]

    init(asset: SealedAudioAsset) {
        schemaVersion = 1
        sourceKind = asset.source.rawValue
        canonicalAudioPath = asset.canonicalAudioPath.description
        canonicalFormat = CanonicalAudioFormatDTO(asset.format)
        frameCount = asset.frameCount
        canonicalSha256 = asset.fingerprint.sha256
        unavailableIntervals = asset.unavailableIntervals.map(UnavailableIntervalDTO.init)
    }
}

private struct SessionManifestDTO: Codable {
    let schemaVersion: UInt64
    let sessionId: String
    let createdAt: String
    let audioManifestPath: String

    init(session: SealedSession) {
        schemaVersion = 1
        sessionId = session.sessionID.rawValue
        createdAt = session.createdAt.rawValue
        audioManifestPath = session.audioManifestPath.description
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func readLittleEndianUInt64(at cursor: inout Int) -> UInt64 {
        let end = cursor + MemoryLayout<UInt64>.size
        let value = self[cursor..<end].withUnsafeBytes { raw in
            raw.loadUnaligned(as: UInt64.self)
        }
        cursor = end
        return UInt64(littleEndian: value)
    }

    var hexLowercase: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
