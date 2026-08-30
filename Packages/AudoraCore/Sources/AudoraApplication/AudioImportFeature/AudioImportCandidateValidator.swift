import AudoraDomain

public enum AudioImportCandidateValidator {
    public static func validate(
        _ candidate: StagedAudioCandidate,
        expectedSeed: ImportedSessionSeed,
        policy: AudioImportPolicy
    ) throws -> ValidatedImportedSession {
        guard candidate.scope == expectedSeed.scope,
              candidate.sessionID == expectedSeed.sessionID.rawValue,
              candidate.createdAt == expectedSeed.createdAt.rawValue,
              candidate.canonicalFrameCount <= policy.maximumCanonicalFrames,
              candidate.originalByteCount <= policy.maximumSourceBytes,
              candidate.canonicalContainer == CanonicalAudioFormat.v1.container,
              candidate.canonicalEncoding == CanonicalAudioFormat.v1.encoding,
              candidate.canonicalSampleRateHz == CanonicalAudioFormat.sampleRateHz,
              candidate.canonicalChannelCount == CanonicalAudioFormat.channelCount,
              candidate.canonicalBitsPerSample == CanonicalAudioFormat.bitsPerSample
        else {
            throw AudioImportFailure.candidateCorrupt
        }

        do {
            guard let container = ImportedAudioContainer(rawValue: candidate.originalContainer),
                  let codec = DecodedAudioCodec(rawValue: candidate.decodedCodec),
                  let role = AudioSourceRole(rawValue: candidate.audioSourceRole),
                  let normalization = AudioNormalizationProvenance(
                      algorithmID: candidate.normalizationAlgorithmID,
                      algorithmVersion: candidate.normalizationAlgorithmVersion,
                      stereoRule: candidate.stereoRule,
                      resamplerVersion: candidate.resamplerVersion,
                      quantizerVersion: candidate.quantizerVersion
                  )
            else {
                throw AudioImportFailure.candidateCorrupt
            }
            let original = try OriginalAudioArtifact(
                relativePath: LibraryRelativePath(candidate.originalRelativePath),
                container: container,
                fingerprint: AudioArtifactFingerprint(
                    byteCount: candidate.originalByteCount,
                    sha256: candidate.originalSHA256
                ),
                decodedCodec: codec,
                sourceSampleRateHz: candidate.sourceSampleRateHz,
                sourceChannelCount: candidate.sourceChannelCount
            )
            let canonical = try CanonicalAudioArtifact(
                relativePath: LibraryRelativePath(candidate.canonicalRelativePath),
                fingerprint: AudioArtifactFingerprint(
                    byteCount: candidate.canonicalByteCount,
                    sha256: candidate.canonicalSHA256
                ),
                frameCount: candidate.canonicalFrameCount,
                durationMilliseconds: candidate.canonicalDurationMilliseconds
            )
            let source = try SessionAudioSource(
                audioSourceID: AudioSourceID(candidate.audioSourceID),
                role: role,
                timelineOffsetMilliseconds: candidate.timelineOffsetMilliseconds
            )
            let audio = try ImportedAudioAsset(
                original: original,
                canonical: canonical,
                sources: [source],
                normalization: normalization
            )
            let session = try ImportedSession(
                sessionID: SessionID(candidate.sessionID),
                createdAt: UTCInstant(candidate.createdAt),
                durationMilliseconds: candidate.canonicalDurationMilliseconds,
                audioManifestSHA256: candidate.audioManifestSHA256,
                audio: audio
            )
            return ValidatedImportedSession(
                stagedCandidate: candidate,
                session: session
            )
        } catch let failure as AudioImportFailure {
            throw failure
        } catch {
            throw AudioImportFailure.candidateCorrupt
        }
    }
}
