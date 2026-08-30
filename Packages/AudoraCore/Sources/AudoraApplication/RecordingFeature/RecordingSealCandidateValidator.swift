import AudoraDomain

public enum RecordingSealCandidateValidator {
    public static func validate(
        _ candidate: StagedRecordingSealCandidate,
        expected request: MicrophoneRecordingRequest
    ) throws -> ValidatedRecordingPublication {
        guard candidate.recordingID == request.recordingID.rawValue,
              candidate.sessionID == request.sessionID.rawValue,
              candidate.libraryID == request.libraryScope.libraryID.rawValue,
              candidate.startedAt == request.startedAt.rawValue,
              candidate.sourceKind == AudioSourceKind.microphone.rawValue,
              candidate.canonicalAudioPath == "audio/audio.wav",
              candidate.sampleRateHz == CanonicalAudioFormat.versionOne.sampleRateHz,
              candidate.channelCount == CanonicalAudioFormat.versionOne.channelCount,
              candidate.encoding == CanonicalAudioFormat.versionOne.encoding.rawValue,
              candidate.frameCount > 0,
              candidate.frameCount <= request.maximumFrames,
              candidate.unavailableIntervals.count <=
                StagedRecordingSealCandidate.maximumUnavailableIntervalCount,
              let reason = CaptureTerminalReason(rawValue: candidate.terminalReason)
        else {
            throw RecordingFailure.sealValidationFailedRecoverable
        }

        let intervals: [UnavailableInterval]
        do {
            intervals = try candidate.unavailableIntervals.map { interval in
                let parsed = interval.reasons.compactMap(UnavailableReason.init(rawValue:))
                guard !parsed.isEmpty,
                      parsed.count == interval.reasons.count,
                      Set(parsed).count == parsed.count,
                      interval.reasons == parsed.sorted().map(\.rawValue)
                else {
                    throw RecordingFailure.sealValidationFailedRecoverable
                }
                return try UnavailableInterval(
                    range: CanonicalFrameRange(
                        startFrame: interval.startFrame,
                        endFrame: interval.endFrame,
                        durationFrames: candidate.frameCount
                    ),
                    reasons: Set(parsed)
                )
            }
            guard try UnavailableIntervalNormalizer.normalize(
                intervals,
                durationFrames: candidate.frameCount
            ) == intervals else {
                throw RecordingFailure.sealValidationFailedRecoverable
            }
            let fingerprint = try AudioFingerprint(sha256: candidate.canonicalSHA256)
            let asset = try SealedAudioAsset(
                source: .microphone,
                format: .versionOne,
                frameCount: candidate.frameCount,
                canonicalAudioPath: LibraryRelativePath(candidate.canonicalAudioPath),
                fingerprint: fingerprint,
                unavailableIntervals: intervals
            )
            let session = try SealedSession(
                sessionID: request.sessionID,
                createdAt: request.startedAt,
                audioManifestPath: LibraryRelativePath("audio/audio.json"),
                audio: asset
            )
            return ValidatedRecordingPublication(
                candidate: candidate,
                libraryID: request.libraryScope.libraryID,
                recordingID: request.recordingID,
                session: session,
                terminalReason: reason
            )
        } catch let failure as RecordingFailure {
            throw failure
        } catch {
            throw RecordingFailure.sealValidationFailedRecoverable
        }
    }
}
