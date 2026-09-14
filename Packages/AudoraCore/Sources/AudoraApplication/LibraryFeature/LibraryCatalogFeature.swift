import AudoraDomain

/// One portable aggregate that can move between active Library storage and
/// persistent Trash without changing its identity or any referring record.
public enum LibraryAggregate: Comparable, Hashable, Sendable {
    case session(SessionID)
    case chat(ChatID)

    private var stableOrder: (kind: UInt8, identifier: String) {
        switch self {
        case let .session(sessionID):
            (0, sessionID.rawValue)
        case let .chat(chatID):
            (1, chatID.rawValue)
        }
    }

    public static func < (left: Self, right: Self) -> Bool {
        left.stableOrder < right.stableOrder
    }
}

public enum LibrarySessionCatalogAcquisition: Equatable, Sendable {
    case imported
    case recorded
}

/// Manifest-owned Session facts used to project a Library row. Session v1 has
/// no persisted title, so Presentation derives its human label from `createdAt`
/// instead of presenting the storage identity as a title.
public struct LibrarySessionCatalogMetadata: Equatable, Sendable {
    public let acquisition: LibrarySessionCatalogAcquisition
    public let createdAt: UTCInstant
    public let hasSelectedTranscript: Bool

    public init(
        acquisition: LibrarySessionCatalogAcquisition,
        createdAt: UTCInstant,
        hasSelectedTranscript: Bool
    ) {
        self.acquisition = acquisition
        self.createdAt = createdAt
        self.hasSelectedTranscript = hasSelectedTranscript
    }
}

/// Manifest-owned Chat facts used to project a Library row.
public struct LibraryChatCatalogMetadata: Equatable, Sendable {
    public let title: ChatTitle
    public let createdAt: UTCInstant
    public let updatedAt: UTCInstant

    public init(
        title: ChatTitle,
        createdAt: UTCInstant,
        updatedAt: UTCInstant
    ) {
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum LibraryCatalogRowUnavailableReason: Equatable, Sendable {
    case corrupt
    case newerSchema
    case unsupportedSchema
}

/// One catalog row whose mutation identity remains separate from the trusted
/// metadata read from its aggregate manifest. A damaged manifest stays visible
/// without turning a raw storage ID into a substitute display title.
public enum LibraryCatalogRow: Equatable, Sendable {
    case session(SessionID, LibrarySessionCatalogMetadata)
    case chat(ChatID, LibraryChatCatalogMetadata)
    case unavailable(LibraryAggregate, LibraryCatalogRowUnavailableReason)

    public var aggregate: LibraryAggregate {
        switch self {
        case let .session(sessionID, _): .session(sessionID)
        case let .chat(chatID, _): .chat(chatID)
        case let .unavailable(aggregate, _): aggregate
        }
    }
}

public struct LibraryCatalogSnapshot: Equatable, Sendable {
    public let active: [LibraryCatalogRow]
    public let trash: [LibraryCatalogRow]

    public init(active: [LibraryCatalogRow], trash: [LibraryCatalogRow]) {
        self.active = active
        self.trash = trash
    }
}

public enum LibraryCatalogLoadResult: Equatable, Sendable {
    case available(LibraryCatalogSnapshot)
    case readOnly
    case unavailable
    case integrityMismatch
}

public enum LibraryAggregateMutationOutcome: Equatable, Sendable {
    case succeeded
    case sourceMissing
    case targetCollision
    case busy
    case readOnly
    case unsupportedSchema
    case unavailable
    case integrityMismatch
    /// The atomic rename committed, but durability of one parent-directory
    /// update could not be proven. Callers must refresh instead of retrying
    /// blindly because the aggregate may already be at its destination.
    case commitUncertain
    case failed
}

public struct LibraryAggregateMutationResult: Equatable, Sendable {
    public let aggregate: LibraryAggregate
    public let outcome: LibraryAggregateMutationOutcome

    public init(
        aggregate: LibraryAggregate,
        outcome: LibraryAggregateMutationOutcome
    ) {
        self.aggregate = aggregate
        self.outcome = outcome
    }
}

/// The portable persistence seam for catalog reads and identity-preserving
/// whole-aggregate Trash moves. Deliberately absent: purge, expiry, or cleanup.
public protocol LibraryAggregateTrashPort: Sendable {
    func loadCatalog(
        for activation: LibraryActivation
    ) async -> LibraryCatalogLoadResult
    func moveToTrash(
        _ aggregate: LibraryAggregate,
        for activation: LibraryActivation
    ) async -> LibraryAggregateMutationOutcome
    func restore(
        _ aggregate: LibraryAggregate,
        for activation: LibraryActivation
    ) async -> LibraryAggregateMutationOutcome
}

public enum LibraryCatalogCommand: Equatable, Sendable {
    case refresh(LibraryActivation)
    case moveToTrash(LibraryActivation, Set<LibraryAggregate>)
    case restore(LibraryActivation, Set<LibraryAggregate>)
}

extension LibraryCatalogCommand {
    var activation: LibraryActivation {
        switch self {
        case let .refresh(activation),
             let .moveToTrash(activation, _),
             let .restore(activation, _):
            activation
        }
    }

    var isMutation: Bool {
        switch self {
        case .refresh: false
        case .moveToTrash, .restore: true
        }
    }

    var unavailableResult: LibraryCatalogCommandResult {
        switch self {
        case .refresh:
            .catalog(.unavailable)
        case let .moveToTrash(_, aggregates),
             let .restore(_, aggregates):
            .mutation(
                aggregates.sorted().map {
                    LibraryAggregateMutationResult(
                        aggregate: $0,
                        outcome: .unavailable
                    )
                },
                catalog: .unavailable
            )
        }
    }

    var refusedResult: LibraryCatalogCommandResult {
        switch self {
        case .refresh:
            .catalog(.unavailable)
        case let .moveToTrash(_, aggregates),
             let .restore(_, aggregates):
            .mutationRefused(
                aggregates.sorted().map {
                    LibraryAggregateMutationResult(
                        aggregate: $0,
                        outcome: .busy
                    )
                }
            )
        }
    }
}

public enum LibraryCatalogCommandResult: Equatable, Sendable {
    case catalog(LibraryCatalogLoadResult)
    /// Admission was refused before any aggregate write. The caller's known
    /// catalog therefore remains valid and may stay presented.
    case mutationRefused([LibraryAggregateMutationResult])
    case mutation(
        [LibraryAggregateMutationResult],
        catalog: LibraryCatalogLoadResult
    )
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol LibraryCatalogFeature: Sendable {
    func send(_ command: LibraryCatalogCommand) async -> LibraryCatalogCommandResult
}

/// Internal mutation authority. Only the Application coordinator may combine
/// the portable catalog operation with the dependent-feature lifecycle.
protocol LibraryCatalogMutationFeature: Sendable {
    /// Runs a mutation only after exact catalog activity authority has been
    /// reserved, keeping that authority through dependent-feature reloads.
    func send(
        _ command: LibraryCatalogCommand,
        lifecycle: any LibraryCatalogMutationLifecycle
    ) async -> LibraryCatalogCommandResult
}

enum LibraryCatalogMutationPreparationResult: Equatable, Sendable {
    case prepared
    /// A dependent feature currently owns conflicting authority. No write was
    /// attempted and a previously loaded catalog remains valid.
    case refused
    /// Required lifecycle authority could not be established or verified.
    case unavailable
}

protocol LibraryCatalogMutationLifecycle: Sendable {
    func prepareForLibraryCatalogMutation(
        _ command: LibraryCatalogCommand
    ) async -> LibraryCatalogMutationPreparationResult
    func reloadAfterLibraryCatalogMutation(
        _ command: LibraryCatalogCommand,
        result: LibraryCatalogCommandResult
    ) async -> Bool
}

/// Stateless orchestration keeps selection/search presentation independent
/// from the portable mutation transaction. A multi-selection is processed in
/// stable order and followed by one authoritative catalog refresh.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor DefaultLibraryCatalogFeature:
    LibraryCatalogFeature,
    LibraryCatalogMutationFeature
{
    private let port: any LibraryAggregateTrashPort
    private let activityCoordinator: any LibraryActivityCoordinating

    public init(
        port: any LibraryAggregateTrashPort,
        activityCoordinator: any LibraryActivityCoordinating
    ) {
        self.port = port
        self.activityCoordinator = activityCoordinator
    }

    public func send(
        _ command: LibraryCatalogCommand
    ) async -> LibraryCatalogCommandResult {
        guard !command.isMutation else { return command.unavailableResult }
        return await sendRead(command)
    }

    func send(
        _ command: LibraryCatalogCommand,
        lifecycle: any LibraryCatalogMutationLifecycle
    ) async -> LibraryCatalogCommandResult {
        guard command.isMutation else { return await sendRead(command) }
        let activation = command.activation
        let lease: LibraryActivityLease
        switch await activityCoordinator.acquireCatalogAccess(for: activation) {
        case let .acquired(acquiredLease):
            lease = acquiredLease
        case .busy:
            return command.refusedResult
        case .unavailable:
            return command.unavailableResult
        }
        switch await lifecycle.prepareForLibraryCatalogMutation(command) {
        case .prepared:
            break
        case .refused:
            await activityCoordinator.release(lease)
            return command.refusedResult
        case .unavailable:
            await activityCoordinator.release(lease)
            return command.unavailableResult
        }

        let result: LibraryCatalogCommandResult
        switch command {
        case .refresh:
            result = command.unavailableResult
        case let .moveToTrash(activation, aggregates):
            result = await mutate(aggregates, for: activation) {
                await port.moveToTrash($0, for: activation)
            }
        case let .restore(activation, aggregates):
            result = await mutate(aggregates, for: activation) {
                await port.restore($0, for: activation)
            }
        }
        let didReload = await lifecycle.reloadAfterLibraryCatalogMutation(
            command,
            result: result
        )
        await activityCoordinator.release(lease)
        return didReload ? result : result.withUnavailableCatalog
    }

    private func sendRead(
        _ command: LibraryCatalogCommand
    ) async -> LibraryCatalogCommandResult {
        guard case let .refresh(activation) = command else {
            return command.unavailableResult
        }
        let lease: LibraryActivityLease
        switch await activityCoordinator.acquireCatalogAccess(for: activation) {
        case let .acquired(acquiredLease):
            lease = acquiredLease
        case .busy, .unavailable:
            return command.unavailableResult
        }
        let result = LibraryCatalogCommandResult.catalog(
            await port.loadCatalog(for: activation)
        )
        await activityCoordinator.release(lease)
        return result
    }

    private func mutate(
        _ aggregates: Set<LibraryAggregate>,
        for activation: LibraryActivation,
        operation: (LibraryAggregate) async -> LibraryAggregateMutationOutcome
    ) async -> LibraryCatalogCommandResult {
        let ordered = aggregates.sorted()
        var results: [LibraryAggregateMutationResult] = []
        results.reserveCapacity(ordered.count)
        for aggregate in ordered {
            results.append(
                LibraryAggregateMutationResult(
                    aggregate: aggregate,
                    outcome: await operation(aggregate)
                )
            )
        }
        return .mutation(
            results,
            catalog: await port.loadCatalog(for: activation)
        )
    }
}

private extension LibraryCatalogCommandResult {
    var withUnavailableCatalog: Self {
        switch self {
        case .catalog:
            .catalog(.unavailable)
        case .mutationRefused:
            self
        case let .mutation(results, _):
            .mutation(results, catalog: .unavailable)
        }
    }
}
