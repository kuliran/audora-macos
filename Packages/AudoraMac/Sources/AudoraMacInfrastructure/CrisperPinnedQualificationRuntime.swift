import AudoraApplication
import CryptoKit
import Foundation

/// Descriptor-backed authority for one exact runtime tree. The current
/// production profile cannot create one because qualification is blocked.
public protocol ConfinedTranscriptionRuntimeExecutionCapability: Sendable {
    var capabilityID: TranscriptionRuntimeCapabilityID { get }
    var profileID: String { get }
    var runtimeIdentity: String { get }
    func duplicateReadOnlyFileDescriptors() throws -> [String: Int32]
}

public protocol ConfinedTranscriptionRuntimeResolving: Sendable {
    func resolveRuntime(
        _ capability: VerifiedTranscriptionRuntime,
        profile: QualifiedTranscriptionProfile
    ) async -> (any ConfinedTranscriptionRuntimeExecutionCapability)?
}

/// Fail-closed verification of the reviewed Crisper lock and recorded Release
/// qualification artifact. The current checked-in profile is deliberately not
/// promotable: its compatibility patch is null and cached real inference is
/// blocked. Updating either artifact cannot silently select another engine;
/// this adapter's reviewed hashes must change in the same release.
public actor CrisperPinnedQualificationRuntime:
    TranscriptionRuntimePort,
    ConfinedTranscriptionRuntimeResolving
{
    public static let profileID = "crisperwhisper-2-small-transformers-mps-v1"

    private static let reviewedEngineLockFileSHA256 =
        "eb2328c9783cd2fcb83fe4a0779a054f1a3d8b4de2c9650f308537c38d9d6630"
    private static let reviewedCanonicalEngineLockSHA256 =
        "c26c6a97338544edc70d6e50d03f547adc820a488df6339ff0838cccbaceba5c"
    private static let reviewedQualificationArtifactSHA256 =
        "d42d85622d7a1eb03eac5af379e4b58fb78a6193d6943c37ea77dca56045582b"
    private static let reviewedRuntimeLockSHA256 =
        "3c13f64a78c85fd4a2e8319989739d3f89c57a4960117ddefffcc9924272ce19"

    private let engineLockData: Data?
    private let qualificationArtifactData: Data?

    public init(
        engineLockData: Data? = nil,
        qualificationArtifactData: Data? = nil
    ) {
        self.engineLockData = engineLockData
        self.qualificationArtifactData = qualificationArtifactData
    }

    public func resolve() async -> TranscriptionRuntimeResolution {
        evaluate()
    }

    public func prepare(_ action: SessionProcessingRecoveryAction) async
        -> TranscriptionRuntimeResolution
    {
        // Preparation and reinstall cannot promote an unqualified descriptor.
        // The explicit action remains useful UI, but selection changes only in
        // a reviewed release containing passing qualification evidence.
        evaluate()
    }

    public func executionCapability(
        for profile: QualifiedTranscriptionProfile
    ) async -> VerifiedTranscriptionRuntime? {
        // The reviewed artifact never qualifies this runtime, so no executable
        // authority can cross into a worker startup.
        nil
    }

    public func resolveRuntime(
        _ capability: VerifiedTranscriptionRuntime,
        profile: QualifiedTranscriptionProfile
    ) async -> (any ConfinedTranscriptionRuntimeExecutionCapability)? {
        nil
    }

    private func evaluate() -> TranscriptionRuntimeResolution {
        guard let engineLockData, let qualificationArtifactData else {
            return .unavailable(.qualificationBlocked(profileID: Self.profileID))
        }
        guard Self.sha256(engineLockData) == Self.reviewedEngineLockFileSHA256,
              Self.sha256(qualificationArtifactData) ==
                Self.reviewedQualificationArtifactSHA256,
              let lock = try? JSONDecoder().decode(EngineLock.self, from: engineLockData),
              let artifact = try? JSONDecoder().decode(
                QualificationArtifact.self,
                from: qualificationArtifactData
              ),
              lock.schemaVersion == 1,
              lock.qualificationProfileId == Self.profileID,
              lock.runtime.pythonVersion == "3.12.14",
              lock.runtime.platform == "arm64-apple-macos",
              lock.runtime.packageLock == "requirements-macos-arm64.lock",
              lock.runtime.packageLockSha256 == Self.reviewedRuntimeLockSHA256,
              lock.engine.provider == "crisperwhisper",
              lock.engine.package.name == "crisperwhisper",
              lock.engine.package.version == "2.0.0",
              lock.engine.backend == "transformers",
              lock.engine.device == "mps",
              lock.engine.computeType == "float16",
              lock.model.repository == "nyralabs/CrisperWhisper2.0_small",
              lock.model.revision == "bcaecf0a584a1f600d8897fe6032b9e2e56429a7",
              lock.decoding.language == "en",
              lock.decoding.mode == "verbatim",
              lock.decoding.wordTimestamps,
              artifact.engineLockSha256 == Self.reviewedCanonicalEngineLockSHA256,
              artifact.engineSelectionChanged == false,
              artifact.cachedOffline.status == "blocked",
              artifact.fixtures.count == 4,
              artifact.fixtures.allSatisfy({ $0.status == "blocked" })
        else {
            return .unavailable(.runtimeLockMismatch)
        }
        guard lock.engine.audoraCompatibilityPatchId != nil else {
            return .unavailable(.qualificationBlocked(profileID: Self.profileID))
        }

        // This reviewed artifact records blocked cached inference. Even a
        // syntactically non-null future patch cannot be promoted with it.
        return .unavailable(.qualificationBlocked(profileID: Self.profileID))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct EngineLock: Decodable {
    struct Runtime: Decodable {
        let pythonVersion: String
        let platform: String
        let packageLock: String
        let packageLockSha256: String
    }

    struct Engine: Decodable {
        struct Package: Decodable {
            let name: String
            let version: String
        }

        let provider: String
        let package: Package
        let backend: String
        let device: String
        let computeType: String
        let audoraCompatibilityPatchId: String?
    }

    struct Model: Decodable {
        let repository: String
        let revision: String
    }

    struct Decoding: Decodable {
        let language: String
        let mode: String
        let wordTimestamps: Bool
    }

    let schemaVersion: UInt32
    let qualificationProfileId: String
    let runtime: Runtime
    let engine: Engine
    let model: Model
    let decoding: Decoding
}

private struct QualificationArtifact: Decodable {
    struct Gate: Decodable {
        let status: String
    }

    let engineLockSha256: String
    let engineSelectionChanged: Bool
    let cachedOffline: Gate
    let fixtures: [Gate]
}
