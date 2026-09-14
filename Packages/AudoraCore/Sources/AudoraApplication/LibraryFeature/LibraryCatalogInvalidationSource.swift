import AudoraDomain

public enum LibraryCatalogMutation: Equatable, Sendable {
    case importedSession(SessionID)
    case selectedTranscript(sessionID: SessionID, revisionID: TranscriptRevisionID)

    public var aggregate: LibraryAggregate {
        switch self {
        case let .importedSession(sessionID),
             let .selectedTranscript(sessionID, _):
            .session(sessionID)
        }
    }
}

public enum LibraryCatalogMutationConfirmation: Equatable, Sendable {
    case confirmed
    /// The durable authority switch completed, but its mandatory verification
    /// reopen did not. Catalog reread is still required because canonical bytes
    /// have already changed.
    case installedNeedsRefresh
}

/// A mutation fact offered by the Application feature that crossed the durable
/// authority boundary. The broker resolves its exact Library activation before
/// it can become an event; an expected-scope mismatch is dropped fail-closed.
public struct LibraryCatalogMutationCommit: Equatable, Sendable {
    public let expectedScope: LibraryScope
    public let mutation: LibraryCatalogMutation
    public let confirmation: LibraryCatalogMutationConfirmation

    public init(
        expectedScope: LibraryScope,
        mutation: LibraryCatalogMutation,
        confirmation: LibraryCatalogMutationConfirmation
    ) {
        self.expectedScope = expectedScope
        self.mutation = mutation
        self.confirmation = confirmation
    }
}

/// Application-owned, generation-exact notice that persistent catalog truth
/// changed. It is an invalidation signal only; persisted Library state remains
/// authoritative and consumers must reread it.
public struct LibraryCatalogMutationEvent: Equatable, Sendable {
    public let activation: LibraryActivation
    public let mutation: LibraryCatalogMutation
    public let confirmation: LibraryCatalogMutationConfirmation

    public var aggregate: LibraryAggregate { mutation.aggregate }

    public init(
        activation: LibraryActivation,
        mutation: LibraryCatalogMutation,
        confirmation: LibraryCatalogMutationConfirmation
    ) {
        self.activation = activation
        self.mutation = mutation
        self.confirmation = confirmation
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol LibraryCatalogMutationCommitPublishing: Sendable {
    func publish(_ commit: LibraryCatalogMutationCommit) async
}

/// Turns durable mutation commits into one generation-exact Application event
/// stream. The stream deliberately keeps only the newest undelivered event:
/// every event causes the same authoritative catalog reread, so coalescing is
/// lossless while keeping memory bounded.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor ApplicationLibraryCatalogMutationEventBroker:
    LibraryCatalogMutationCommitPublishing
{
    private let library: any LibraryFeature
    private var continuation: AsyncStream<LibraryCatalogMutationEvent>.Continuation?
    private var continuationID: UInt64?
    private var nextContinuationID: UInt64 = 1
    private var pendingEvent: LibraryCatalogMutationEvent?

    public init(library: any LibraryFeature) {
        self.library = library
    }

    public nonisolated var events: AsyncStream<LibraryCatalogMutationEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task { await self.addSubscriber(continuation) }
        }
    }

    public func publish(_ commit: LibraryCatalogMutationCommit) async {
        guard case let .active(snapshot) = await library.currentState.selection,
              snapshot.activationGeneration > 0,
              snapshot.libraryID == commit.expectedScope.libraryID
        else { return }
        let event = LibraryCatalogMutationEvent(
            activation: LibraryActivation(
                scope: LibraryScope(libraryID: snapshot.libraryID),
                generation: snapshot.activationGeneration
            ),
            mutation: commit.mutation,
            confirmation: commit.confirmation
        )
        guard let continuation else {
            pendingEvent = event
            return
        }
        continuation.yield(event)
    }

    private func addSubscriber(
        _ continuation: AsyncStream<LibraryCatalogMutationEvent>.Continuation
    ) {
        guard self.continuation == nil, nextContinuationID > 0 else {
            continuation.finish()
            return
        }
        let identifier = nextContinuationID
        nextContinuationID = nextContinuationID == .max ? 0 : nextContinuationID + 1
        self.continuation = continuation
        continuationID = identifier
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(identifier) }
        }
        if let pendingEvent {
            self.pendingEvent = nil
            continuation.yield(pendingEvent)
        }
    }

    private func removeSubscriber(_ identifier: UInt64) {
        guard continuationID == identifier else { return }
        continuation = nil
        continuationID = nil
    }
}

public enum LibraryCatalogInvalidationReason: Equatable, Sendable {
    case audioImported
    case recordingSealed
    case transcriptPublished
    case chatCatalogChanged
}

/// A durable aggregate change observed after its owning Application feature has
/// published authoritative state. The exact activation prevents a delayed event
/// from refreshing a replacement Library root that happens to share an ID.
public struct LibraryCatalogInvalidation: Equatable, Sendable {
    public let activation: LibraryActivation
    public let reason: LibraryCatalogInvalidationReason

    public init(
        activation: LibraryActivation,
        reason: LibraryCatalogInvalidationReason
    ) {
        self.activation = activation
        self.reason = reason
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol LibraryCatalogInvalidationSource: Sendable {
    var invalidations: AsyncStream<LibraryCatalogInvalidation> { get }
}

/// Merges the authoritative completion streams of every current aggregate
/// owner. Presentation receives only invalidation facts; it always rereads the
/// catalog instead of constructing or patching rows from these events.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor ApplicationLibraryCatalogInvalidationSource:
    LibraryCatalogInvalidationSource
{
    private let library: any LibraryFeature
    private let catalogMutations: AsyncStream<LibraryCatalogMutationEvent>
    private let recordingSeals: SessionSealedNotifications
    private let chatStates: AsyncStream<ChatFeatureState>

    private var observers: [Task<Void, Never>] = []
    private var continuations:
        [UInt64: AsyncStream<LibraryCatalogInvalidation>.Continuation] = [:]
    private var nextContinuationID: UInt64 = 1
    private var lastRecordingReceipt: SessionSealedReceipt?
    private var lastChatCatalog: ChatFeatureState.Catalog?

    public init(
        library: any LibraryFeature,
        catalogMutations: AsyncStream<LibraryCatalogMutationEvent>,
        recordingSeals: SessionSealedNotifications,
        chatStates: AsyncStream<ChatFeatureState>
    ) {
        self.library = library
        self.catalogMutations = catalogMutations
        self.recordingSeals = recordingSeals
        self.chatStates = chatStates
    }

    public nonisolated var invalidations: AsyncStream<LibraryCatalogInvalidation> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task { await self.addSubscriber(continuation) }
        }
    }

    private func addSubscriber(
        _ continuation: AsyncStream<LibraryCatalogInvalidation>.Continuation
    ) {
        let identifier = nextContinuationID
        nextContinuationID &+= 1
        guard identifier > 0, nextContinuationID > 0 else {
            continuation.finish()
            return
        }
        continuations[identifier] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(identifier) }
        }
        startObserversIfNeeded()
    }

    private func removeSubscriber(_ identifier: UInt64) {
        continuations[identifier] = nil
    }

    private func startObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let catalogMutations = catalogMutations
        observers.append(Task { [weak self] in
            for await event in catalogMutations {
                guard !Task.isCancelled, let self else { return }
                await self.observeCatalogMutation(event)
            }
        })
        let recordingSeals = recordingSeals
        observers.append(Task { [weak self] in
            for await receipt in recordingSeals {
                guard !Task.isCancelled, let self else { return }
                await self.observeRecordingSeal(receipt)
            }
        })
        let chatStates = chatStates
        observers.append(Task { [weak self] in
            for await state in chatStates {
                guard !Task.isCancelled, let self else { return }
                await self.observeChat(state)
            }
        })
    }

    private func observeCatalogMutation(_ event: LibraryCatalogMutationEvent) async {
        guard await isCurrent(event.activation) else { return }
        let reason: LibraryCatalogInvalidationReason = switch event.mutation {
        case .importedSession: .audioImported
        case .selectedTranscript: .transcriptPublished
        }
        publish(event.activation, reason: reason)
    }

    private func observeRecordingSeal(_ receipt: SessionSealedReceipt) async {
        guard receipt != lastRecordingReceipt else { return }
        lastRecordingReceipt = receipt
        await publishCurrentActivation(
            matching: receipt.libraryID,
            reason: .recordingSealed
        )
    }

    private func observeChat(_ state: ChatFeatureState) async {
        guard state.catalog != lastChatCatalog else { return }
        lastChatCatalog = state.catalog
        guard case .ready = state.catalog else { return }
        await publishCurrentActivation(reason: .chatCatalogChanged)
    }

    private func publishCurrentActivation(
        matching expectedLibraryID: LibraryID? = nil,
        reason: LibraryCatalogInvalidationReason
    ) async {
        guard case let .active(snapshot) = await library.currentState.selection,
              snapshot.activationGeneration > 0,
              expectedLibraryID == nil || snapshot.libraryID == expectedLibraryID
        else { return }
        publish(
            LibraryActivation(
                scope: LibraryScope(libraryID: snapshot.libraryID),
                generation: snapshot.activationGeneration
            ),
            reason: reason
        )
    }

    private func isCurrent(_ activation: LibraryActivation) async -> Bool {
        guard case let .active(snapshot) = await library.currentState.selection else {
            return false
        }
        return snapshot.libraryID == activation.scope.libraryID
            && snapshot.activationGeneration == activation.generation
    }

    private func publish(
        _ activation: LibraryActivation,
        reason: LibraryCatalogInvalidationReason
    ) {
        let invalidation = LibraryCatalogInvalidation(
            activation: activation,
            reason: reason
        )
        for continuation in continuations.values {
            continuation.yield(invalidation)
        }
    }
}
