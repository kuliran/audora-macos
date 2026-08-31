import AudoraDomain
import XCTest

final class ImportedSessionTests: XCTestCase {
    private let fixtureHash = String(repeating: "a", count: 64)

    func testTypedSessionAndSourceIdentitiesRejectCrossKindAndEscapes() throws {
        XCTAssertEqual(
            try SessionID("ses-20260830T120000000Z-2ABC").rawValue,
            "ses-20260830T120000000Z-2ABC"
        )
        XCTAssertEqual(AudioSourceID.microphone.rawValue, "src-0001")

        for invalid in [
            "lib-20260830T120000000Z-2ABC",
            "ses-20260230T120000000Z-2ABC",
            "../ses-20260830T120000000Z-2ABC",
        ] {
            XCTAssertThrowsError(try SessionID(invalid), invalid)
        }
        XCTAssertEqual(try AudioSourceID("src-0002").rawValue, "src-0002")
        for invalid in ["src-001", "src-00001", "src-ABCD", "../src-0001"] {
            XCTAssertThrowsError(try AudioSourceID(invalid), invalid)
        }
    }

    func testCanonicalFrameAndDurationBoundaryUsesExactIntegerCeiling() throws {
        XCTAssertEqual(CanonicalAudioFormat.v1, .versionOne)
        XCTAssertEqual(CanonicalAudioFormat.v1.container, "wav")
        XCTAssertEqual(CanonicalAudioFormat.v1.encoding.rawValue, "pcmS16LE")
        XCTAssertEqual(CanonicalAudioFormat.v1.bitsPerSample, 16)
        XCTAssertEqual(
            try CanonicalAudioFormat.durationMilliseconds(forFrameCount: 1),
            1
        )
        XCTAssertEqual(
            try CanonicalAudioFormat.durationMilliseconds(forFrameCount: 16_001),
            1_001
        )
        XCTAssertEqual(
            try CanonicalAudioFormat.durationMilliseconds(
                forFrameCount: CanonicalAudioFormat.maximumFrameCount
            ),
            2_700_000
        )
        XCTAssertThrowsError(
            try CanonicalAudioFormat.durationMilliseconds(forFrameCount: 0)
        )
        XCTAssertThrowsError(
            try CanonicalAudioFormat.durationMilliseconds(
                forFrameCount: CanonicalAudioFormat.maximumFrameCount + 1
            )
        )
    }

    func testCanonicalArtifactBindsExactV1WAVLengthAndPortablePath() throws {
        XCTAssertNoThrow(
            try CanonicalAudioArtifact(
                relativePath: LibraryRelativePath("audio/audio.wav"),
                fingerprint: AudioArtifactFingerprint(byteCount: 46, sha256: fixtureHash),
                frameCount: 1,
                durationMilliseconds: 1
            )
        )
        XCTAssertThrowsError(
            try CanonicalAudioArtifact(
                relativePath: LibraryRelativePath("audio/audio.wav"),
                fingerprint: AudioArtifactFingerprint(byteCount: 47, sha256: fixtureHash),
                frameCount: 1,
                durationMilliseconds: 1
            )
        )
        XCTAssertThrowsError(
            try CanonicalAudioArtifact(
                relativePath: LibraryRelativePath("../audio.wav"),
                fingerprint: AudioArtifactFingerprint(byteCount: 46, sha256: fixtureHash),
                frameCount: 1,
                durationMilliseconds: 1
            )
        )
    }

    func testOriginalArtifactRequiresContainerCodecPairAndExactPortableName() throws {
        XCTAssertNoThrow(
            try original(container: .m4a, codec: .aacLC, path: "audio/original.m4a")
        )
        XCTAssertNoThrow(
            try original(container: .m4a, codec: .alac, path: "audio/original.m4a")
        )
        XCTAssertNoThrow(
            try original(container: .wav, codec: .linearPCM, path: "audio/original.wav")
        )
        XCTAssertThrowsError(
            try original(container: .wav, codec: .aacLC, path: "audio/original.wav")
        )
        XCTAssertThrowsError(
            try original(container: .m4a, codec: .linearPCM, path: "audio/original.m4a")
        )
        XCTAssertThrowsError(
            try original(container: .wav, codec: .linearPCM, path: "audio/source.wav")
        )
    }

    func testImportedAudioHasOneMicrophoneSourceAtZeroAndFixedNormalization() throws {
        let source = try SessionAudioSource(
            audioSourceID: .microphone,
            role: .microphone,
            timelineOffsetMilliseconds: 0
        )
        let asset = try ImportedAudioAsset(
            original: original(
                container: .wav,
                codec: .linearPCM,
                path: "audio/original.wav"
            ),
            canonical: CanonicalAudioArtifact(
                relativePath: LibraryRelativePath("audio/audio.wav"),
                fingerprint: AudioArtifactFingerprint(byteCount: 46, sha256: fixtureHash),
                frameCount: 1,
                durationMilliseconds: 1
            ),
            sources: [source],
            normalization: .v1
        )

        XCTAssertEqual(asset.sources, [source])
        XCTAssertEqual(asset.normalization.stereoRule, "arithmeticMean")
        XCTAssertThrowsError(
            try ImportedAudioAsset(
                original: asset.original,
                canonical: asset.canonical,
                sources: [],
                normalization: .v1
            )
        )
        XCTAssertThrowsError(
            try SessionAudioSource(
                audioSourceID: .microphone,
                role: .microphone,
                timelineOffsetMilliseconds: 1
            )
        )
    }

    func testCanonicalTimeRangeCannotEscapeSessionTimeline() throws {
        let expected = try CanonicalTimeRange(
            startMilliseconds: 100,
            endMilliseconds: 900,
            sessionDurationMilliseconds: 1_000
        )
        XCTAssertEqual(
            try CanonicalTimeRange(
                startMilliseconds: 100,
                endMilliseconds: 900,
                sessionDurationMilliseconds: 1_000
            ),
            expected
        )
        XCTAssertThrowsError(
            try CanonicalTimeRange(
                startMilliseconds: 900,
                endMilliseconds: 100,
                sessionDurationMilliseconds: 1_000
            )
        )
        XCTAssertThrowsError(
            try CanonicalTimeRange(
                startMilliseconds: 0,
                endMilliseconds: 1_001,
                sessionDurationMilliseconds: 1_000
            )
        )
        let fullTimeline = try CanonicalTimeRange(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            sessionDurationMilliseconds: 1_000
        )
        XCTAssertEqual(fullTimeline.startMilliseconds, 0)
        XCTAssertEqual(fullTimeline.endMilliseconds, 1_000)
        XCTAssertThrowsError(
            try CanonicalTimeRange(
                startMilliseconds: 100,
                endMilliseconds: 100,
                sessionDurationMilliseconds: 1_000
            )
        )
    }

    private func original(
        container: ImportedAudioContainer,
        codec: DecodedAudioCodec,
        path: String
    ) throws -> OriginalAudioArtifact {
        try OriginalAudioArtifact(
            relativePath: LibraryRelativePath(path),
            container: container,
            fingerprint: AudioArtifactFingerprint(byteCount: 12, sha256: fixtureHash),
            decodedCodec: codec,
            sourceSampleRateHz: 48_000,
            sourceChannelCount: 2
        )
    }
}
