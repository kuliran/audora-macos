import AudoraApplication
import AudoraDomain
import Combine

public struct LibraryCatalogMutationNotice: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case movedToTrash
        case restored
    }

    public enum CatalogVerification: Equatable, Sendable {
        case verifiedCurrentContents
        case unverified
    }

    public let action: Action
    public let results: [LibraryAggregateMutationResult]
    public let catalogVerification: CatalogVerification

    public init(
        action: Action,
        results: [LibraryAggregateMutationResult],
        catalogVerification: CatalogVerification = .verifiedCurrentContents
    ) {
        self.action = action
        self.results = results
        self.catalogVerification = catalogVerification
    }

    var requiresCatalogVerification: Bool {
        catalogVerification == .unverified && results.contains {
            $0.outcome == .commitUncertain
        }
    }
}

public struct LibraryCatalogPresentationState: Equatable, Sendable {
    public enum Availability: Equatable, Sendable {
        case inactive
        case loading
        case available
        case readOnly
        case unavailable
        case integrityMismatch
    }

    public enum Activity: Equatable, Sendable {
        case refreshing
        case movingToTrash
        case restoring
    }

    public let scope: LibraryScope?
    public let catalog: LibraryCatalogSnapshot?
    public let availability: Availability
    public let activity: Activity?
    public let mutationNotice: LibraryCatalogMutationNotice?

    public init(
        scope: LibraryScope?,
        catalog: LibraryCatalogSnapshot?,
        availability: Availability,
        activity: Activity? = nil,
        mutationNotice: LibraryCatalogMutationNotice? = nil
    ) {
        self.scope = scope
        self.catalog = catalog
        self.availability = availability
        self.activity = activity
        self.mutationNotice = mutationNotice
    }

    public static let inactive = LibraryCatalogPresentationState(
        scope: nil,
        catalog: nil,
        availability: .inactive
    )
}

/// Projects the authoritative Application catalog result without keeping a
/// second catalog or optimistically moving rows between Active and Trash.
@MainActor
public final class LibraryCatalogPresentationModel: ObservableObject {
    @Published public private(set) var state =
        LibraryCatalogPresentationState.inactive

    private let feature: any LibraryCatalogFeature
    private let invalidationSource: any LibraryCatalogInvalidationSource
    private var selectedActivation: LibraryActivation?
    private var selectionGeneration: UInt64 = 0
    private var isObservingInvalidations = false
    private var isDrainingInvalidations = false
    private var refreshPending = false

    public init(
        feature: any LibraryCatalogFeature,
        invalidationSource: any LibraryCatalogInvalidationSource
    ) {
        self.feature = feature
        self.invalidationSource = invalidationSource
    }

    public var isBusy: Bool { state.activity != nil }

    /// Keeps the projected catalog synchronized with durably committed mutations
    /// owned by Audio Import, Recording, Session Processing, and Chat. Each event is
    /// only a reason to perform an authoritative catalog read.
    public func observeInvalidations() async {
        guard !isObservingInvalidations else { return }
        isObservingInvalidations = true
        defer { isObservingInvalidations = false }
        for await invalidation in invalidationSource.invalidations {
            guard !Task.isCancelled else { return }
            guard selectedActivation == invalidation.activation else { continue }
            refreshPending = true
            await drainInvalidationsIfPossible()
        }
    }

    public func activate(_ activation: LibraryActivation?) async {
        guard activation != selectedActivation else {
            if activation != nil, state.availability != .available, !isBusy {
                await refresh()
            }
            return
        }

        selectionGeneration &+= 1
        selectedActivation = activation
        guard let activation else {
            refreshPending = false
            state = .inactive
            return
        }
        let scope = activation.scope

        let generation = selectionGeneration
        state = LibraryCatalogPresentationState(
            scope: scope,
            catalog: nil,
            availability: .loading,
            activity: .refreshing
        )
        let result = await feature.send(.refresh(activation))
        guard isCurrent(scope, generation: generation) else { return }
        guard case let .catalog(catalog) = result else {
            project(
                LibraryCatalogPresentationState.Availability.unavailable,
                in: scope
            )
            await drainInvalidationsIfPossible()
            return
        }
        project(catalog, in: scope)
        await drainInvalidationsIfPossible()
    }

    public func refresh() async {
        guard selectedActivation != nil else { return }
        guard !isBusy else {
            refreshPending = true
            return
        }
        await refreshCurrentActivation()
        await drainInvalidationsIfPossible()
    }

    private func refreshCurrentActivation() async {
        guard let activation = selectedActivation, !isBusy else { return }
        let scope = activation.scope
        let generation = selectionGeneration
        let unresolvedNotice = state.mutationNotice.flatMap {
            $0.requiresCatalogVerification ? $0 : nil
        }
        state = LibraryCatalogPresentationState(
            scope: scope,
            catalog: state.catalog,
            availability: state.catalog == nil ? .loading : .available,
            activity: .refreshing,
            mutationNotice: unresolvedNotice
        )
        let result = await feature.send(.refresh(activation))
        guard isCurrent(scope, generation: generation) else { return }
        guard case let .catalog(catalog) = result else {
            project(
                LibraryCatalogPresentationState.Availability.unavailable,
                in: scope
            )
            return
        }
        switch catalog {
        case .available:
            project(catalog, in: scope)
        case .readOnly, .unavailable, .integrityMismatch:
            project(catalog, in: scope, mutationNotice: unresolvedNotice)
        }
    }

    public func moveToTrash(_ aggregate: LibraryAggregate) async {
        await moveToTrash([aggregate])
    }

    public func moveToTrash(_ aggregates: Set<LibraryAggregate>) async {
        guard !aggregates.isEmpty,
              let active = state.catalog?.active,
              aggregates.isSubset(of: Set(active.map(\.aggregate)))
        else { return }
        await mutate(
            aggregates,
            activity: .movingToTrash,
            action: .movedToTrash
        ) { activation, aggregates in
            .moveToTrash(activation, aggregates)
        }
    }

    public func restore(_ aggregate: LibraryAggregate) async {
        guard state.catalog?.trash.contains(where: {
            $0.aggregate == aggregate
        }) == true else { return }
        await mutate(
            [aggregate],
            activity: .restoring,
            action: .restored
        ) { activation, aggregates in
            .restore(activation, aggregates)
        }
    }

    private func mutate(
        _ aggregates: Set<LibraryAggregate>,
        activity: LibraryCatalogPresentationState.Activity,
        action: LibraryCatalogMutationNotice.Action,
        command: (
            LibraryActivation,
            Set<LibraryAggregate>
        ) -> LibraryCatalogCommand
    ) async {
        guard let activation = selectedActivation, !isBusy else { return }
        let scope = activation.scope
        let generation = selectionGeneration
        state = LibraryCatalogPresentationState(
            scope: scope,
            catalog: state.catalog,
            availability: .available,
            activity: activity
        )
        let result = await feature.send(command(activation, aggregates))
        guard isCurrent(scope, generation: generation) else { return }
        if case let .mutationRefused(results) = result {
            state = LibraryCatalogPresentationState(
                scope: scope,
                catalog: state.catalog,
                availability: .available,
                mutationNotice: LibraryCatalogMutationNotice(
                    action: action,
                    results: results
                )
            )
            await drainInvalidationsIfPossible()
            return
        }
        guard case let .mutation(results, catalog) = result else {
            project(
                LibraryCatalogPresentationState.Availability.unavailable,
                in: scope
            )
            await drainInvalidationsIfPossible()
            return
        }
        let hasUncertainCommit = results.contains {
            $0.outcome == .commitUncertain
        }
        let catalogVerification: LibraryCatalogMutationNotice.CatalogVerification =
            if hasUncertainCommit, case .available = catalog {
                .verifiedCurrentContents
            } else if hasUncertainCommit {
                .unverified
            } else {
                .verifiedCurrentContents
            }
        project(
            catalog,
            in: scope,
            mutationNotice: LibraryCatalogMutationNotice(
                action: action,
                results: results,
                catalogVerification: catalogVerification
            )
        )
        await drainInvalidationsIfPossible()
    }

    private func drainInvalidationsIfPossible() async {
        guard !isDrainingInvalidations else { return }
        isDrainingInvalidations = true
        defer { isDrainingInvalidations = false }
        while refreshPending, !isBusy, selectedActivation != nil {
            refreshPending = false
            await refreshCurrentActivation()
        }
    }

    private func isCurrent(
        _ scope: LibraryScope,
        generation: UInt64
    ) -> Bool {
        selectedActivation?.scope == scope && selectionGeneration == generation
    }

    private func project(
        _ result: LibraryCatalogLoadResult,
        in scope: LibraryScope,
        mutationNotice: LibraryCatalogMutationNotice? = nil
    ) {
        switch result {
        case let .available(catalog):
            state = LibraryCatalogPresentationState(
                scope: scope,
                catalog: catalog,
                availability: .available,
                mutationNotice: mutationNotice
            )
        case .readOnly:
            state = LibraryCatalogPresentationState(
                scope: scope,
                catalog: nil,
                availability: .readOnly,
                mutationNotice: mutationNotice
            )
        case .unavailable:
            project(
                LibraryCatalogPresentationState.Availability.unavailable,
                in: scope,
                mutationNotice: mutationNotice
            )
        case .integrityMismatch:
            state = LibraryCatalogPresentationState(
                scope: scope,
                catalog: nil,
                availability: .integrityMismatch,
                mutationNotice: mutationNotice
            )
        }
    }

    private func project(
        _ availability: LibraryCatalogPresentationState.Availability,
        in scope: LibraryScope,
        mutationNotice: LibraryCatalogMutationNotice? = nil
    ) {
        state = LibraryCatalogPresentationState(
            scope: scope,
            catalog: nil,
            availability: availability,
            mutationNotice: mutationNotice
        )
    }
}
