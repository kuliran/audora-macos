import AudoraApplication
import AudoraDomain
@testable import AudoraMacInfrastructure
import Darwin
import Foundation
import XCTest

final class CompatibleWAVImportBenchmarkTests: XCTestCase {
    func testProductionPersistenceTransaction() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AUDORA_RUN_COMPATIBLE_WAV_BENCHMARK"] == "1" else {
            throw XCTSkip("run through Qualification/AudioImport/run-compatible-wav-benchmark.sh")
        }
        let seconds = environment["AUDORA_BENCHMARK_SECONDS"].flatMap(Int.init) ?? 600
        let iterations = environment["AUDORA_BENCHMARK_ITERATIONS"].flatMap(Int.init) ?? 5
        guard seconds > 0, iterations > 0 else { throw BenchmarkFailure.invalidArguments }

        try withTemporaryParent { parent in
            let dataByteCount = UInt64(seconds) * 16_000 * 2
            let fixtures: [FixtureKind: Fixture] = [
                .strict: try createFixture(
                    at: parent.appendingPathComponent("strict.wav"),
                    dataByteCount: dataByteCount,
                    metadataByteCount: 0
                ),
                .optionalChunks: try createFixture(
                    at: parent.appendingPathComponent("optional.wav"),
                    dataByteCount: dataByteCount,
                    metadataByteCount: 1_048_576
                ),
            ]

            for scenario in Scenario.allCases {
                let root = parent.appendingPathComponent(
                    "warmup-\(scenario.identifier).audoralibrary"
                )
                try createLibrary(at: root)
                _ = try performImport(
                    fixture: fixtures[scenario.fixture]!,
                    model: scenario.model,
                    root: root
                )
                try FileManager.default.removeItem(at: root)
            }

            var elapsedByScenario: [Scenario: [Double]] = [:]
            var storageByScenario: [Scenario: Storage] = [:]
            for index in 0..<iterations {
                let order = index.isMultiple(of: 2)
                    ? Scenario.allCases
                    : Array(Scenario.allCases.reversed())
                for scenario in order {
                    let root = parent.appendingPathComponent(
                        "sample-\(scenario.identifier)-\(index).audoralibrary"
                    )
                    try createLibrary(at: root)
                    let start = DispatchTime.now().uptimeNanoseconds
                    let sessionRoot = try performImport(
                        fixture: fixtures[scenario.fixture]!,
                        model: scenario.model,
                        root: root
                    )
                    let end = DispatchTime.now().uptimeNanoseconds
                    elapsedByScenario[scenario, default: []].append(
                        Double(end - start) / 1_000_000
                    )
                    storageByScenario[scenario] = try storage(in: sessionRoot)
                    try FileManager.default.removeItem(at: root)
                }
            }

            print("AUDORA_COMPATIBLE_WAV_BENCHMARK_BEGIN")
            print("fixture_seconds=\(seconds)")
            print("iterations=\(iterations) plus one warmup")
            print("pcm_bytes=\(dataByteCount)")
            print("strict_source_bytes=\(fixtures[.strict]!.byteCount)")
            print("optional_source_bytes=\(fixtures[.optionalChunks]!.byteCount)")
            print("| Path | Median import ms | Final Session logical bytes | " +
                "Final Session allocated bytes |")
            print("|---|---:|---:|---:|")
            for scenario in Scenario.allCases {
                let ordered = elapsedByScenario[scenario]!.sorted()
                let measuredStorage = storageByScenario[scenario]!
                print(
                    "| \(scenario.label) | " +
                        String(format: "%.3f", ordered[ordered.count / 2]) + " | " +
                        "\(measuredStorage.logicalBytes) | " +
                        "\(measuredStorage.allocatedBytes) |"
                )
            }
            print("AUDORA_COMPATIBLE_WAV_BENCHMARK_END")
        }
    }

    private func performImport(
        fixture: Fixture,
        model: StorageModel,
        root: URL
    ) throws -> URL {
        let persistence = PortableAudioImportPersistence()
        let seed = try importedSeed()
        let location = try persistence.begin(
            root: root,
            stagingID: AudioStagingID("staging_benchmark")!,
            seed: seed,
            container: .wav
        )
        var committed = false
        defer {
            if !committed { persistence.discard(location) }
            location.close()
        }
        let source = try persistence.copySource(
            from: fixture.url,
            into: location,
            maximumBytes: AudioImportPolicy.versionOne.maximumSourceBytes
        )
        guard let description = try persistence.inspectCompatiblePCMWAV(
            in: location,
            expected: source,
            maximumFrameCount: AudioImportPolicy.versionOne.maximumCanonicalFrames
        ) else {
            throw BenchmarkFailure.fixtureRejected
        }

        let normalized: CanonicalNormalizationResult
        let canonical: AudioArtifactFingerprint
        switch model {
        case .singleArtifact:
            let result = try persistence.canonicalizeCompatiblePCMWAV(
                description,
                in: location,
                expectedSource: source
            )
            normalized = result.normalization
            canonical = result.fingerprint
        case .retainedOriginal:
            normalized = try writeRetainedCanonical(
                description: description,
                source: source,
                persistence: persistence,
                location: location
            )
            canonical = try persistence.fingerprint(
                components: location.stagedSessionComponents + ["audio", "audio.wav"],
                under: location,
                maximumBytes: normalized.byteCount
            )
        }

        let provisional = try makeSession(
            seed: seed,
            source: source,
            canonical: canonical,
            normalized: normalized,
            model: model
        )
        let rebound = try persistence.writeManifests(for: provisional, in: location)
        let validated = try persistence.validateStaged(location, expected: rebound)
        let reopened = try persistence.install(location, expected: validated)
        guard reopened.session == validated else { throw BenchmarkFailure.reopenMismatch }
        committed = true
        return root.appendingPathComponent("sessions/\(seed.sessionID.rawValue)")
    }

    private func writeRetainedCanonical(
        description: CompatiblePCMWAVDescription,
        source: AudioArtifactFingerprint,
        persistence: PortableAudioImportPersistence,
        location: AudioImportStagingLocation
    ) throws -> CanonicalNormalizationResult {
        let ownedSource = try persistence.openOriginalForDecoding(
            in: location,
            expected: source
        )
        let input = try ownedSource.duplicateDescriptor()
        defer { Darwin.close(input) }
        let output = try persistence.createCanonicalDescriptor(in: location)
        var outputOpen = true
        defer { if outputOpen { Darwin.close(output) } }

        if description.isStrictCanonical {
            try copyBytes(
                from: input,
                offset: 0,
                byteCount: description.sourceByteCount,
                to: output
            )
        } else {
            try writeAll(
                canonicalHeader(dataByteCount: description.dataByteCount),
                to: output
            )
            try copyBytes(
                from: input,
                offset: description.dataOffset,
                byteCount: description.dataByteCount,
                to: output
            )
        }
        try synchronize(output)
        guard Darwin.close(output) == 0 else {
            outputOpen = false
            throw BenchmarkFailure.io("close canonical: \(errno)")
        }
        outputOpen = false
        try persistence.didFinishCanonicalWrite(in: location)
        return CanonicalNormalizationResult(
            frameCount: description.frameCount,
            durationMilliseconds: try CanonicalAudioFormat.durationMilliseconds(
                forFrameCount: description.frameCount
            ),
            byteCount: UInt64(44) + description.dataByteCount
        )
    }

    private func makeSession(
        seed: ImportedSessionSeed,
        source: AudioArtifactFingerprint,
        canonical: AudioArtifactFingerprint,
        normalized: CanonicalNormalizationResult,
        model: StorageModel
    ) throws -> ImportedSession {
        let isSingle = model == .singleArtifact
        let original = try OriginalAudioArtifact(
            relativePath: LibraryRelativePath(
                isSingle ? "audio/audio.wav" : "audio/original.wav"
            ),
            container: .wav,
            fingerprint: isSingle ? canonical : source,
            decodedCodec: .linearPCM,
            sourceSampleRateHz: CanonicalAudioFormat.sampleRateHz,
            sourceChannelCount: CanonicalAudioFormat.channelCount,
            retention: isSingle ? .canonicalizedPCM : .byteExact,
            sourceFingerprint: source
        )
        let audio = try ImportedAudioAsset(
            original: original,
            canonical: CanonicalAudioArtifact(
                relativePath: LibraryRelativePath("audio/audio.wav"),
                fingerprint: canonical,
                frameCount: normalized.frameCount,
                durationMilliseconds: normalized.durationMilliseconds
            ),
            sources: [
                try SessionAudioSource(
                    audioSourceID: .microphone,
                    role: .microphone,
                    timelineOffsetMilliseconds: 0
                ),
            ],
            normalization: isSingle ? .compatiblePCMWAVV1 : .v1
        )
        return try ImportedSession(
            sessionID: seed.sessionID,
            createdAt: seed.createdAt,
            durationMilliseconds: normalized.durationMilliseconds,
            audioManifestSHA256: String(repeating: "0", count: 64),
            audio: audio
        )
    }

    private func createLibrary(at root: URL) throws {
        let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
        _ = try PortableLibraryPersistence().create(
            at: root,
            seed: NewLibrarySeed(
                libraryID: try LibraryID("lib-20260830T120000000Z-2ABC"),
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
    }

    private func importedSeed() throws -> ImportedSessionSeed {
        ImportedSessionSeed(
            scope: AudioImportScopeIdentity(
                libraryID: try LibraryID("lib-20260830T120000000Z-2ABC"),
                workspaceGeneration: 1
            ),
            sessionID: try SessionID("ses-20260830T120000000Z-3DEF"),
            createdAt: try UTCInstant("2026-08-30T12:00:00.000Z")
        )
    }

    private func withTemporaryParent(_ body: (URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-compatible-wav-benchmark-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        try body(parent)
    }
}

private enum FixtureKind: CaseIterable, Hashable {
    case strict
    case optionalChunks
}

private enum StorageModel: CaseIterable, Hashable {
    case retainedOriginal
    case singleArtifact
}

private struct Scenario: Hashable {
    let fixture: FixtureKind
    let model: StorageModel

    static let allCases: [Scenario] = FixtureKind.allCases.flatMap { fixture in
        StorageModel.allCases.map { Scenario(fixture: fixture, model: $0) }
    }

    var identifier: String {
        let fixtureName = fixture == .strict ? "strict" : "optional"
        let modelName = model == .retainedOriginal ? "two" : "one"
        return "\(fixtureName)-\(modelName)"
    }

    var label: String {
        let fixtureName = fixture == .strict ? "strict" : "optional chunks"
        let modelName = model == .retainedOriginal ? "two artifacts" : "one artifact"
        return "\(fixtureName) / \(modelName)"
    }
}

private struct Fixture {
    let url: URL
    let byteCount: UInt64
}

private struct Storage {
    let logicalBytes: UInt64
    let allocatedBytes: UInt64
}

private enum BenchmarkFailure: Error {
    case invalidArguments
    case fixtureRejected
    case reopenMismatch
    case io(String)
}

private func createFixture(
    at url: URL,
    dataByteCount: UInt64,
    metadataByteCount: UInt32
) throws -> Fixture {
    guard dataByteCount <= UInt64(UInt32.max) - 36 else {
        throw BenchmarkFailure.invalidArguments
    }
    var prefix = [UInt8]()
    prefix.append(contentsOf: "RIFF".utf8)
    appendLittleEndian(UInt32(0), to: &prefix)
    prefix.append(contentsOf: "WAVEfmt ".utf8)
    appendLittleEndian(UInt32(16), to: &prefix)
    appendLittleEndian(UInt16(1), to: &prefix)
    appendLittleEndian(UInt16(1), to: &prefix)
    appendLittleEndian(UInt32(16_000), to: &prefix)
    appendLittleEndian(UInt32(32_000), to: &prefix)
    appendLittleEndian(UInt16(2), to: &prefix)
    appendLittleEndian(UInt16(16), to: &prefix)
    if metadataByteCount > 0 {
        prefix.append(contentsOf: "JUNK".utf8)
        appendLittleEndian(metadataByteCount, to: &prefix)
        for index in 0..<Int(metadataByteCount) {
            prefix.append(UInt8(truncatingIfNeeded: index &* 31 &+ 7))
        }
        if !metadataByteCount.isMultiple(of: 2) { prefix.append(0) }
    }
    prefix.append(contentsOf: "data".utf8)
    appendLittleEndian(UInt32(dataByteCount), to: &prefix)
    let totalByteCount = UInt64(prefix.count) + dataByteCount
    guard totalByteCount - 8 <= UInt64(UInt32.max) else {
        throw BenchmarkFailure.invalidArguments
    }
    let riffByteCount = UInt32(totalByteCount - 8)
    prefix[4] = UInt8(truncatingIfNeeded: riffByteCount)
    prefix[5] = UInt8(truncatingIfNeeded: riffByteCount >> 8)
    prefix[6] = UInt8(truncatingIfNeeded: riffByteCount >> 16)
    prefix[7] = UInt8(truncatingIfNeeded: riffByteCount >> 24)

    let descriptor = Darwin.open(
        url.path,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        0o600
    )
    guard descriptor >= 0 else { throw BenchmarkFailure.io("create fixture: \(errno)") }
    defer { Darwin.close(descriptor) }
    try writeAll(prefix, to: descriptor)
    var remaining = dataByteCount
    let pcm = (0..<(64 * 1_024)).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) }
    while remaining > 0 {
        let count = Int(min(UInt64(pcm.count), remaining))
        try pcm.withUnsafeBytes { bytes in
            try writeAll(bytes.baseAddress!, count: count, to: descriptor)
        }
        remaining -= UInt64(count)
    }
    try synchronize(descriptor)
    return Fixture(url: url, byteCount: totalByteCount)
}

private func copyBytes(
    from input: Int32,
    offset: UInt64,
    byteCount: UInt64,
    to output: Int32
) throws {
    var copied: UInt64 = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while copied < byteCount {
        let requested = Int(min(UInt64(buffer.count), byteCount - copied))
        let count = buffer.withUnsafeMutableBytes { bytes -> Int in
            while true {
                let result = Darwin.pread(
                    input,
                    bytes.baseAddress!,
                    requested,
                    off_t(offset + copied)
                )
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard count > 0 else { throw BenchmarkFailure.io("pread: \(errno)") }
        try buffer.withUnsafeBytes { bytes in
            try writeAll(bytes.baseAddress!, count: count, to: output)
        }
        copied += UInt64(count)
    }
}

private func canonicalHeader(dataByteCount: UInt64) -> [UInt8] {
    var bytes = [UInt8]()
    bytes.append(contentsOf: "RIFF".utf8)
    appendLittleEndian(UInt32(36 + dataByteCount), to: &bytes)
    bytes.append(contentsOf: "WAVEfmt ".utf8)
    appendLittleEndian(UInt32(16), to: &bytes)
    appendLittleEndian(UInt16(1), to: &bytes)
    appendLittleEndian(UInt16(1), to: &bytes)
    appendLittleEndian(UInt32(16_000), to: &bytes)
    appendLittleEndian(UInt32(32_000), to: &bytes)
    appendLittleEndian(UInt16(2), to: &bytes)
    appendLittleEndian(UInt16(16), to: &bytes)
    bytes.append(contentsOf: "data".utf8)
    appendLittleEndian(UInt32(dataByteCount), to: &bytes)
    return bytes
}

private func storage(in root: URL) throws -> Storage {
    let enumerator = try XCTUnwrap(
        FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    )
    var logical: UInt64 = 0
    var allocated: UInt64 = 0
    for case let url as URL in enumerator {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw BenchmarkFailure.io("stat: \(errno)")
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else { continue }
        logical += UInt64(metadata.st_size)
        allocated += UInt64(metadata.st_blocks) * 512
    }
    return Storage(logicalBytes: logical, allocatedBytes: allocated)
}

private func synchronize(_ descriptor: Int32) throws {
    while fsync(descriptor) != 0 {
        if errno == EINTR { continue }
        throw BenchmarkFailure.io("fsync: \(errno)")
    }
}

private func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
    try bytes.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        try writeAll(base, count: buffer.count, to: descriptor)
    }
}

private func writeAll(_ base: UnsafeRawPointer, count: Int, to descriptor: Int32) throws {
    var offset = 0
    while offset < count {
        let result = Darwin.write(descriptor, base.advanced(by: offset), count - offset)
        if result < 0, errno == EINTR { continue }
        guard result > 0 else { throw BenchmarkFailure.io("write: \(errno)") }
        offset += result
    }
}

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
}
