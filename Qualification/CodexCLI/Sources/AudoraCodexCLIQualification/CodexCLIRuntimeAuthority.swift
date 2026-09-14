import Foundation

/// A stable digest of the complete runtime manifest enforced by one runtime
/// authority. The manifest must cover every executable component that can receive
/// provider authorization, including non-system dynamic libraries, runtime-loaded
/// code, and helper executables.
struct CodexCLIQualificationRuntimeAuthorityIdentity: Hashable, Sendable {
    let manifestSHA256: String

    init?(manifestSHA256: String) {
        guard manifestSHA256.utf8.count == 64,
              manifestSHA256.utf8.allSatisfy({ byte in
                  (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte)
              })
        else { return nil }
        self.manifestSHA256 = manifestSHA256
    }
}

/// A module-sealed capability proving that one exact CLI artifact belongs to the
/// complete runtime identified by `runtimeIdentity`. Its initializer is not
/// public: callers cannot turn an observed version or entry-file hash into
/// execution authority.
final class CodexCLIQualificationRuntimeAuthorityProof: Sendable {
    let runtimeIdentity: CodexCLIQualificationRuntimeAuthorityIdentity
    private let cliVersion: String
    private let executableIdentity: CodexCLIExecutableArtifact.Identity

    init(
        runtimeIdentity: CodexCLIQualificationRuntimeAuthorityIdentity,
        cliVersion: String,
        executableIdentity: CodexCLIExecutableArtifact.Identity
    ) {
        self.runtimeIdentity = runtimeIdentity
        self.cliVersion = cliVersion
        self.executableIdentity = executableIdentity
    }

    func binds(
        cliVersion: String,
        executableArtifact: CodexCLIExecutableArtifact
    ) -> Bool {
        self.cliVersion == cliVersion
            && executableIdentity == executableArtifact.identity
    }

    func binds(
        cliVersion: String,
        executableIdentity: CodexCLIExecutableArtifact.Identity
    ) -> Bool {
        self.cliVersion == cliVersion
            && self.executableIdentity == executableIdentity
    }
}

/// Durable seam for the future security-metadata-preserving runtime. A real
/// implementation must retain or otherwise protect every component named by its
/// manifest for the lifetime of the proof, and `revalidate` must fail closed if
/// any part of that authority is no longer current.
protocol CodexCLIQualificationRuntimeAuthority: Sendable {
    func proveRuntime(
        executableArtifact: CodexCLIExecutableArtifact,
        cliVersion: String
    ) -> CodexCLIQualificationRuntimeAuthorityProof?

    func revalidate(
        _ proof: CodexCLIQualificationRuntimeAuthorityProof,
        executableArtifact: CodexCLIExecutableArtifact,
        cliVersion: String
    ) -> Bool
}
