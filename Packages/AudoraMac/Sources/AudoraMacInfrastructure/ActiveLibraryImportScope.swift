import AudoraApplication
import Foundation

struct ActiveLibraryImportScope: @unchecked Sendable {
    let identity: AudioImportScopeIdentity
    let root: URL
    let lease: any LibraryAccessLease

    func release() {
        lease.release()
    }
}

protocol ActiveLibraryImportScopeProviding: Sendable {
    func acquireAudioImportScope() async -> ActiveLibraryImportScope?
    func isCurrentAudioImportScope(_ identity: AudioImportScopeIdentity) async -> Bool
    func withCurrentAudioImportScope<Result: Sendable>(
        _ identity: AudioImportScopeIdentity,
        perform operation: @Sendable () throws -> Result
    ) async throws -> Result
}

extension PortableLibraryWorkspace: ActiveLibraryImportScopeProviding {}
