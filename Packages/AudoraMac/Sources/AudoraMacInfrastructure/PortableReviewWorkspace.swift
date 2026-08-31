import AudoraApplication
import AudoraDomain
import Foundation

/// Infrastructure-only resolver for an opaque, already-verified canonical
/// audio snapshot. Application and Presentation never receive a filesystem URL.
public protocol ReviewCanonicalAudioResolving: Sendable {
    func resolveCanonicalAudio(for source: ReviewAudioSource) async -> Data?
}

/// Binds Review reads, selection CAS operations, and canonical playback bytes
/// to one currently active Library authority.
public actor PortableReviewWorkspace: ReviewSessionPort,
    ReviewCanonicalAudioResolving
{
    private struct Binding: Sendable {
        let selection: ReviewSelection
        let scope: ActiveLibraryProcessingScope
        let revisions: PortableTranscriptRevisionRepository
        let audioCapabilityID: ReviewAudioCapabilityID
        let durationMilliseconds: UInt64
        let canonicalWAV: Data
    }

    private let scopes: any SessionProcessingLibraryScopeProviding
    private var binding: Binding?

    public init(scopes: any SessionProcessingLibraryScopeProviding) {
        self.scopes = scopes
    }

    public func load(_ selection: ReviewSelection) async -> ReviewSessionReadResult {
        binding = nil
        guard let active = await scopes.acquireSessionProcessingScope(
            for: selection.scope
        ) else { return .unavailable }
        let revisions = PortableTranscriptRevisionRepository(
            root: active.root,
            libraryID: selection.scope.libraryID
        )
        let read: PortableSessionReviewRead
        do {
            read = try await scopes.withCurrentSessionProcessingScope(active.identity) {
                revisions.loadReviewSynchronously(for: selection)
            }
        } catch {
            return .unavailable
        }
        guard await scopes.isCurrentSessionProcessingScope(active.identity) else {
            return .unavailable
        }
        switch read {
        case let .available(verified):
            do {
                let capabilityID = try ReviewAudioCapabilityID(
                    "review-\(UUID().uuidString)"
                )
                let snapshot = try ReviewSessionSnapshot(
                    selection: selection,
                    revisionIDs: verified.revision.revisionIDs,
                    selectedRevision: verified.revision.selectedRevision,
                    audioCapabilityID: capabilityID,
                    canonicalAudioDurationMilliseconds: verified.durationMilliseconds
                )
                guard await scopes.isCurrentSessionProcessingScope(active.identity)
                else { return .unavailable }
                binding = Binding(
                    selection: selection,
                    scope: active,
                    revisions: revisions,
                    audioCapabilityID: capabilityID,
                    durationMilliseconds: verified.durationMilliseconds,
                    canonicalWAV: verified.canonicalWAV
                )
                return .available(snapshot)
            } catch {
                return .integrityMismatch
            }
        case .unavailable:
            return .unavailable
        case .integrityMismatch:
            return .integrityMismatch
        }
    }

    public func selectRevision(
        _ revisionID: TranscriptRevisionID,
        for selection: ReviewSelection,
        expectedSelectedRevisionID: TranscriptRevisionID
    ) async -> ReviewRevisionSelectionResult {
        guard let binding, binding.selection == selection,
              await scopes.isCurrentSessionProcessingScope(binding.scope.identity)
        else { return .unavailable }
        do {
            let reopened = try await scopes.withCurrentSessionProcessingScope(
                binding.scope.identity
            ) {
                try binding.revisions.selectExistingRevisionSynchronously(
                    revisionID,
                    sessionID: selection.sessionID,
                    expectedSelectedRevisionID: expectedSelectedRevisionID
                )
            }
            guard await scopes.isCurrentSessionProcessingScope(binding.scope.identity)
            else { return .unavailable }
            return .selected(
                try ReviewSessionSnapshot(
                    selection: selection,
                    revisionIDs: reopened.revisionIDs,
                    selectedRevision: reopened.selectedRevision,
                    audioCapabilityID: binding.audioCapabilityID,
                    canonicalAudioDurationMilliseconds: binding.durationMilliseconds
                )
            )
        } catch let failure as TranscriptRevisionRepositoryFailure {
            switch failure {
            case .staleSelection, .installedNeedsRefresh:
                return .stale
            case .sessionUnavailable, .unsupportedSchema:
                return .unavailable
            case .sessionIntegrityMismatch, .revisionCollision:
                return .integrityMismatch
            case .writeFailed:
                return .failed
            }
        } catch let error as ReviewSnapshotError {
            _ = error
            return .integrityMismatch
        } catch {
            return .failed
        }
    }

    public func resolveCanonicalAudio(for source: ReviewAudioSource) async -> Data? {
        guard let binding,
              binding.selection == source.selection,
              binding.audioCapabilityID == source.audioCapabilityID,
              binding.durationMilliseconds == source.durationMilliseconds,
              await scopes.isCurrentSessionProcessingScope(binding.scope.identity)
        else { return nil }
        return binding.canonicalWAV
    }
}
