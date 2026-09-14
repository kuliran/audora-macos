@testable import AudoraApplication
import AudoraDomain
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class LibraryCatalogInvalidationSourceTests: XCTestCase {
    func testCommittedMutationEventCarriesExactCurrentLibraryActivation() async throws {
        let activation = LibraryActivation(
            scope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T120000000Z-2ABC")
            ),
            generation: 7
        )
        let sessionID = try SessionID("ses-20260830T120000000Z-3DEF")
        let broker = ApplicationLibraryCatalogMutationEventBroker(
            library: CatalogInvalidationLibraryFeature(activation: activation)
        )
        var events = broker.events.makeAsyncIterator()

        await broker.publish(
            LibraryCatalogMutationCommit(
                expectedScope: activation.scope,
                mutation: .importedSession(sessionID),
                confirmation: .installedNeedsRefresh
            )
        )

        let event = await events.next()
        XCTAssertEqual(
            event,
            LibraryCatalogMutationEvent(
                activation: activation,
                mutation: .importedSession(sessionID),
                confirmation: .installedNeedsRefresh
            )
        )
    }

    func testInstalledTranscriptMutationInvalidatesItsExactActivation() async throws {
        let activation = LibraryActivation(
            scope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T120000000Z-2ABC")
            ),
            generation: 7
        )
        let sessionID = try SessionID("ses-20260830T120000000Z-3DEF")
        let revisionID = try TranscriptRevisionID("trv-20260830T120100000Z-4GHJ")
        let catalogMutations = AsyncStream<LibraryCatalogMutationEvent>.makeStream()
        let source = ApplicationLibraryCatalogInvalidationSource(
            library: CatalogInvalidationLibraryFeature(activation: activation),
            catalogMutations: catalogMutations.stream,
            recordingSeals: .finished,
            chatStates: finishedStream()
        )
        var invalidations = source.invalidations.makeAsyncIterator()

        catalogMutations.continuation.yield(
            LibraryCatalogMutationEvent(
                activation: activation,
                mutation: .selectedTranscript(
                    sessionID: sessionID,
                    revisionID: revisionID
                ),
                confirmation: .installedNeedsRefresh
            )
        )

        let invalidation = await invalidations.next()
        XCTAssertEqual(
            invalidation,
            LibraryCatalogInvalidation(
                activation: activation,
                reason: .transcriptPublished
            )
        )
        catalogMutations.continuation.finish()
    }

    func testReadyChatCatalogInvalidatesOnlyTheExactActiveLibraryGeneration()
        async throws
    {
        let activation = LibraryActivation(
            scope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T120000000Z-2ABC")
            ),
            generation: 7
        )
        let chatStates = AsyncStream<ChatFeatureState>.makeStream()
        let source = ApplicationLibraryCatalogInvalidationSource(
            library: CatalogInvalidationLibraryFeature(activation: activation),
            catalogMutations: finishedStream(),
            recordingSeals: .finished,
            chatStates: chatStates.stream
        )
        var invalidations = source.invalidations.makeAsyncIterator()

        chatStates.continuation.yield(
            ChatFeatureState(
                catalog: .ready(
                    ChatCatalogSnapshot(allRows: [], visibleRows: [])
                )
            )
        )

        let invalidation = await invalidations.next()
        XCTAssertEqual(
            invalidation,
            LibraryCatalogInvalidation(
                activation: activation,
                reason: .chatCatalogChanged
            )
        )
        chatStates.continuation.finish()
    }
}

private func finishedStream<Element: Sendable>() -> AsyncStream<Element> {
    AsyncStream { $0.finish() }
}

private actor CatalogInvalidationLibraryFeature: LibraryFeature {
    nonisolated let states = AsyncStream<LibraryFeatureState> { $0.finish() }
    private let activation: LibraryActivation

    init(activation: LibraryActivation) {
        self.activation = activation
    }

    var currentState: LibraryFeatureState {
        LibraryFeatureState(
            selection: .active(
                ActiveLibrarySnapshot(
                    libraryID: activation.scope.libraryID,
                    preferences: .defaults,
                    profile: .nullProfile(statementCount: 0),
                    activationGeneration: activation.generation
                )
            )
        )
    }

    func send(_ command: LibraryCommand) async -> LibraryCommandResult {
        .noSelectionMutation
    }
}
