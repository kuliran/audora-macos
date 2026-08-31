import AudoraApplication
import AudoraDomain
@testable import AudoraMacInfrastructure
import Darwin
import XCTest

final class PinnedLocalTranscriptionModelRepositoryTests: XCTestCase {
    func testExactExplicitSnapshotIsReady() async throws {
        try await withSyntheticModel { root, manifest, profile in
            try installSyntheticModel(at: root)
            let repository = PinnedLocalTranscriptionModelRepository(
                root: root,
                manifest: manifest
            )

            let resolution = await repository.verify(profile)

            XCTAssertEqual(resolution, .ready)
        }
    }

    func testMissingSnapshotUsesExplicitPreparationSeam() async throws {
        try await withSyntheticModel { root, manifest, profile in
            let preparation = SyntheticModelPreparation(root: root)
            let repository = PinnedLocalTranscriptionModelRepository(
                root: root,
                manifest: manifest,
                preparation: preparation
            )
            let before = await repository.verify(profile)

            let after = await repository.prepare(.prepare, profile: profile)
            let actions = await preparation.actions

            XCTAssertEqual(before, .missing)
            XCTAssertEqual(after, .ready)
            XCTAssertEqual(actions, [.prepare])
        }
    }

    func testHashDriftAndSymlinkAreNeverAcceptedAsPinnedModel() async throws {
        try await withSyntheticModel { root, manifest, profile in
            try installSyntheticModel(at: root)
            try Data("changed\n".utf8).write(
                to: root.appendingPathComponent("model.safetensors")
            )
            let drifted = PinnedLocalTranscriptionModelRepository(
                root: root,
                manifest: manifest
            )
            let driftedResolution = await drifted.verify(profile)
            XCTAssertEqual(driftedResolution, .corrupt)

            try FileManager.default.removeItem(
                at: root.appendingPathComponent("model.safetensors")
            )
            let unrelated = root.deletingLastPathComponent()
                .appendingPathComponent("unrelated-synthetic")
            try Data("synthetic-model\n".utf8).write(to: unrelated)
            defer { try? FileManager.default.removeItem(at: unrelated) }
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("model.safetensors"),
                withDestinationURL: unrelated
            )
            let symlinked = PinnedLocalTranscriptionModelRepository(
                root: root,
                manifest: manifest
            )

            let symlinkedResolution = await symlinked.verify(profile)
            XCTAssertEqual(symlinkedResolution, .corrupt)
        }
    }

    func testVerifiedCapabilityKeepsExactModelBytesAfterPathReplacement() async throws {
        try await withSyntheticModel { root, manifest, profile in
            try installSyntheticModel(at: root)
            let repository = PinnedLocalTranscriptionModelRepository(
                root: root,
                manifest: manifest
            )
            let resolution = await repository.verify(profile)
            XCTAssertEqual(resolution, .ready)
            let acquiredCapability = await repository.executionCapability(for: profile)
            let capability = try XCTUnwrap(acquiredCapability)

            try FileManager.default.removeItem(
                at: root.appendingPathComponent("model.safetensors")
            )
            try Data("replacement-model\n".utf8).write(
                to: root.appendingPathComponent("model.safetensors")
            )

            let acquiredModel = await repository.resolveModel(capability, profile: profile)
            let resolved = try XCTUnwrap(acquiredModel)
            let descriptors = try resolved.duplicateReadOnlyFileDescriptors()
            defer { descriptors.values.forEach { Darwin.close($0) } }
            let descriptor = try XCTUnwrap(descriptors["model.safetensors"])
            XCTAssertEqual(
                try readModelDescriptor(descriptor),
                Data("synthetic-model\n".utf8)
            )
        }
    }

    func testVerifiedCapabilityFreezesBytesAgainstSameInodeMutation() async throws {
        try await withSyntheticModel { root, manifest, profile in
            try installSyntheticModel(at: root)
            let modelURL = root.appendingPathComponent("model.safetensors")
            let originalIdentity = try fileIdentity(modelURL)
            let repository = PinnedLocalTranscriptionModelRepository(
                root: root,
                manifest: manifest
            )
            let resolution = await repository.verify(profile)
            XCTAssertEqual(resolution, .ready)
            let acquiredCapability = await repository.executionCapability(for: profile)
            let capability = try XCTUnwrap(acquiredCapability)

            try overwriteInPlace(
                modelURL,
                bytes: Data("tampered--model\n".utf8)
            )
            XCTAssertEqual(try fileIdentity(modelURL), originalIdentity)

            let acquiredModel = await repository.resolveModel(capability, profile: profile)
            let resolved = try XCTUnwrap(acquiredModel)
            let descriptors = try resolved.duplicateReadOnlyFileDescriptors()
            defer { descriptors.values.forEach { Darwin.close($0) } }
            let descriptor = try XCTUnwrap(descriptors["model.safetensors"])
            XCTAssertNotEqual(try fileIdentity(descriptor), originalIdentity)
            XCTAssertEqual(fcntl(descriptor, F_GETFL) & O_ACCMODE, O_RDONLY)
            XCTAssertEqual(
                try readModelDescriptor(descriptor),
                Data("synthetic-model\n".utf8)
            )
        }
    }

    private func withSyntheticModel(
        _ body: (URL, PinnedTranscriptionModelManifest, QualifiedTranscriptionProfile)
            async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-synthetic-model-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try PinnedTranscriptionModelManifest(
            profileID: "synthetic-qualified-v1",
            modelRevision: "synthetic-model-v1",
            files: [
                "config.json": "bc25ca8607844c62816c9091eb60b8b47adf9aa109cd1165f127366418f69708",
                "model.safetensors": "e40bd67b7a14c1f1483f7bb55965f3f9d7aa7f526e451e79bd033a025e98e3e2",
            ]
        )
        try await body(root, manifest, makeProfile())
    }

    private func installSyntheticModel(at root: URL) throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        try Data("synthetic-config\n".utf8).write(
            to: root.appendingPathComponent("config.json")
        )
        try Data("synthetic-model\n".utf8).write(
            to: root.appendingPathComponent("model.safetensors")
        )
    }

    private func makeProfile() throws -> QualifiedTranscriptionProfile {
        let qualification = try TranscriptEngineQualification(
            qualificationProfileID: "synthetic-qualified-v1",
            engineLockSHA256: String(repeating: "a", count: 64),
            runtimeIdentity: "synthetic-runtime-v1",
            runtimeLockSHA256: String(repeating: "b", count: 64),
            compatibilityPatchID: "synthetic-patch-v1"
        )
        let policy = try EngineUsePolicy(
            policyID: "synthetic-evaluation-v1",
            coveredArtifacts: [.transcriptRevision],
            privateLocalUseAllowed: true,
            privateExportAllowed: false,
            externalProcessingAllowed: false,
            publicDistributionAllowed: false,
            commercialUseAllowed: false,
            licenseReference: "synthetic-license",
            licenseSHA256: String(repeating: "c", count: 64)
        )
        let engine = try TranscriptEngineProvenance(
            provider: "crisperwhisper",
            model: "small",
            revision: "synthetic-model-v1",
            language: "en",
            mode: "verbatim",
            decodingOptionsSHA256: String(repeating: "d", count: 64),
            qualification: qualification,
            usePolicy: policy
        )
        return try QualifiedTranscriptionProfile(
            profileID: qualification.qualificationProfileID,
            protocolVersion: 1,
            runtimeVersion: qualification.runtimeIdentity,
            packageLockSHA256: qualification.runtimeLockSHA256,
            modelRevision: engine.revision,
            compatibilityPatchID: qualification.compatibilityPatchID,
            engine: engine
        )
    }
}

private struct ModelFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let byteCount: UInt64
}

private func fileIdentity(_ url: URL) throws -> ModelFileIdentity {
    var metadata = stat()
    guard url.withUnsafeFileSystemRepresentation({ path in
        guard let path else { return false }
        return lstat(path, &metadata) == 0
    }), metadata.st_size >= 0 else {
        throw CocoaError(.fileReadUnknown)
    }
    return ModelFileIdentity(
        device: UInt64(truncatingIfNeeded: metadata.st_dev),
        inode: UInt64(truncatingIfNeeded: metadata.st_ino),
        byteCount: UInt64(metadata.st_size)
    )
}

private func fileIdentity(_ descriptor: Int32) throws -> ModelFileIdentity {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_size >= 0 else {
        throw CocoaError(.fileReadUnknown)
    }
    return ModelFileIdentity(
        device: UInt64(truncatingIfNeeded: metadata.st_dev),
        inode: UInt64(truncatingIfNeeded: metadata.st_ino),
        byteCount: UInt64(metadata.st_size)
    )
}

private func overwriteInPlace(_ url: URL, bytes: Data) throws {
    let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return Darwin.open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { Darwin.close(descriptor) }
    let written = bytes.withUnsafeBytes { buffer in
        Darwin.pwrite(descriptor, buffer.baseAddress, buffer.count, 0)
    }
    guard written == bytes.count, fsync(descriptor) == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private func readModelDescriptor(_ descriptor: Int32) throws -> Data {
    guard lseek(descriptor, 0, SEEK_SET) == 0 else {
        throw CocoaError(.fileReadUnknown)
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 { return result }
        if count < 0 {
            if errno == EINTR { continue }
            throw CocoaError(.fileReadUnknown)
        }
        result.append(contentsOf: buffer[0..<count])
    }
}

private actor SyntheticModelPreparation: PinnedTranscriptionModelPreparing {
    private let root: URL
    private(set) var actions: [SessionProcessingRecoveryAction] = []

    init(root: URL) { self.root = root }

    func prepare(
        _ action: SessionProcessingRecoveryAction,
        manifest: PinnedTranscriptionModelManifest
    ) async {
        actions.append(action)
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        try? Data("synthetic-config\n".utf8).write(
            to: root.appendingPathComponent("config.json")
        )
        try? Data("synthetic-model\n".utf8).write(
            to: root.appendingPathComponent("model.safetensors")
        )
    }
}
