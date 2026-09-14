@_spi(CoachContextQualification) @_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
import Foundation

/// Reopens the exact Chat attachment and immutable Transcript Revision at the
/// Attempt read boundary. Nonblocking lock contention and transient local read
/// failures receive a small cancellable retry; durable absence is still reported
/// as one atomic unavailable result.
@_spi(InvocationInfrastructure)
public enum PortableAttemptTranscriptAvailabilitySource {
    private static let maximumReadAttempts = 3

    public static func make(
        workspace: PortableLibraryWorkspace,
        persistence: PortableChatPersistence
    ) -> AttemptTranscriptAvailabilitySource {
        make(
            workspace: workspace,
            persistence: persistence,
            transcriptRevisionFault: { _ in }
        )
    }

    static func make(
        workspace: PortableLibraryWorkspace,
        persistence: PortableChatPersistence,
        transcriptRevisionFault: @escaping @Sendable
            (TranscriptRevisionPersistenceFaultPoint) throws -> Void
    ) -> AttemptTranscriptAvailabilitySource {
        make(maximumAttempts: maximumReadAttempts) { queries in
            try await inspect(
                queries,
                workspace: workspace,
                persistence: persistence,
                transcriptRevisionFault: transcriptRevisionFault
            )
        }
    }

    private static func make(
        maximumAttempts: Int,
        batchInspection: @escaping @Sendable ([AttemptTranscriptAvailabilityQuery])
            async throws -> [AttemptTranscriptAvailability]?
    ) -> AttemptTranscriptAvailabilitySource {
        precondition(maximumAttempts > 0)
        return AttemptTranscriptAvailabilitySource(
            batchImplementation: { queries in
                guard !queries.isEmpty else { return [] }
                for attempt in 1 ... maximumAttempts {
                    try Task.checkCancellation()
                    if let availabilities = try await batchInspection(queries) {
                        return availabilities
                    }
                    guard attempt < maximumAttempts else { break }
                    await Task.yield()
                }
                return Array(repeating: .unavailable, count: queries.count)
            }
        )
    }

    static func make(
        maximumAttempts: Int,
        inspection: @escaping @Sendable (AttemptTranscriptAvailabilityQuery)
            async throws -> AttemptTranscriptAvailability?
    ) -> AttemptTranscriptAvailabilitySource {
        precondition(maximumAttempts > 0)
        return AttemptTranscriptAvailabilitySource { query in
            for attempt in 1 ... maximumAttempts {
                try Task.checkCancellation()
                if let availability = try await inspection(query) {
                    return availability
                }
                guard attempt < maximumAttempts else { break }
                await Task.yield()
            }
            return .unavailable
        }
    }

    fileprivate enum StorageInspection: Sendable {
        case resolved([AttemptTranscriptAvailability])
        case retry
    }

    private static func inspect(
        _ queries: [AttemptTranscriptAvailabilityQuery],
        workspace: PortableLibraryWorkspace,
        persistence: PortableChatPersistence,
        transcriptRevisionFault: @escaping @Sendable
            (TranscriptRevisionPersistenceFaultPoint) throws -> Void
    ) async throws -> [AttemptTranscriptAvailability]? {
        try Task.checkCancellation()
        guard let first = queries.first else { return [] }
        guard queries.allSatisfy({
            $0.library == first.library && $0.chatID == first.chatID
        }) else {
            return Array(repeating: .unavailable, count: queries.count)
        }
        guard let active = await workspace.acquireSessionProcessingScope(
            for: first.library
        ) else { return nil }
        let inspection: StorageInspection
        do {
            inspection = try await workspace.withCurrentSessionProcessingScope(
                active.identity
            ) {
                try Task.checkCancellation()
                guard let loaded = try persistence.loadForAttemptTranscriptAvailability(
                    first.chatID,
                    at: active.root,
                    in: first.library
                ) else { return .retry }
                let aggregate: ChatAggregate
                switch loaded {
                case let .readWrite(value):
                    aggregate = value
                case let .frozen(snapshot):
                    return snapshot.reason == .corrupt
                        ? .retry
                        : .resolved(
                            Array(repeating: .unavailable, count: queries.count)
                        )
                }
                var attachments: [ChatSessionAttachment] = []
                attachments.reserveCapacity(queries.count)
                for query in queries {
                    guard let attachment = aggregate.chat.attachments.values
                        .first(where: {
                            $0.attachmentID == query.sessionAttachmentID
                        }),
                        attachment == query.sourceAttachment
                    else {
                        return .resolved(
                            Array(repeating: .unavailable, count: queries.count)
                        )
                    }
                    attachments.append(attachment)
                }
                let expectedFingerprints = zip(attachments, queries).map {
                    attachment, query in
                    PortableChatAttachmentFingerprint(
                        attachment: attachment,
                        revisionSHA256: query.revisionSHA256
                    )
                }
                let availabilities = try PortableTranscriptRevisionRepository(
                    root: active.root,
                    libraryID: first.library.libraryID,
                    expectedRootIdentity: active.identity.rootIdentity,
                    fault: transcriptRevisionFault
                ).inspectChatAttachmentFingerprintsSynchronously(
                    expectedFingerprints
                )
                guard let availabilities else { return .retry }
                return .resolved(
                    availabilities.map { availability in
                        switch availability {
                        case .available:
                            .available
                        case .unavailable:
                            .unavailable
                        case .externalProcessingDisallowed:
                            .externalProcessingDisallowed
                        }
                    }
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch PortableChatPersistenceError.chatMissing {
            return Array(repeating: .unavailable, count: queries.count)
        } catch {
            return nil
        }
        try Task.checkCancellation()
        switch inspection {
        case let .resolved(availabilities):
            return availabilities
        case .retry:
            return nil
        }
    }
}
