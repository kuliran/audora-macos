import AudoraApplication
import AudoraDomain
import AudoraMacPresentation
import XCTest

@MainActor
final class LibraryCatalogPresentationModelTests: XCTestCase {
    func testActivationRefreshesTheSelectedLibraryThroughTheTypedFeature()
        async throws
    {
        let scope = try makeScope("lib-20260830T120000000Z-2ABC")
        let activation = LibraryActivation(scope: scope, generation: 1)
        let session = LibraryAggregate.session(
            try SessionID("ses-20260822T153045123Z-P4R7")
        )
        let catalog = LibraryCatalogSnapshot(
            active: [presentationCatalogRow(session)],
            trash: []
        )
        let feature = ScriptedLibraryCatalogFeature(
            results: [.catalog(.available(catalog))]
        )
        let model = makeCatalogModel(feature: feature)

        await model.activate(activation)

        XCTAssertEqual(
            model.state,
            LibraryCatalogPresentationState(
                scope: scope,
                catalog: catalog,
                availability: .available
            )
        )
        let commands = await feature.commands
        XCTAssertEqual(commands, [.refresh(activation)])
    }

    func testBatchMoveProjectsFailedAndCommitUncertainResultsOnlyAfterRefresh()
        async throws
    {
        let scope = try makeScope("lib-20260830T120000000Z-2ABC")
        let activation = LibraryActivation(scope: scope, generation: 1)
        let session = LibraryAggregate.session(
            try SessionID("ses-20260822T153045123Z-P4R7")
        )
        let chat = LibraryAggregate.chat(
            try ChatID("cht-20260822T160201044Z-9NQF")
        )
        let initial = LibraryCatalogSnapshot(
            active: [
                presentationCatalogRow(session),
                presentationCatalogRow(chat),
            ],
            trash: []
        )
        let refreshed = LibraryCatalogSnapshot(
            active: [presentationCatalogRow(chat)],
            trash: [presentationCatalogRow(session)]
        )
        let mutationResults = [
            LibraryAggregateMutationResult(
                aggregate: session,
                outcome: .commitUncertain
            ),
            LibraryAggregateMutationResult(
                aggregate: chat,
                outcome: .failed
            ),
        ]
        let feature = ScriptedLibraryCatalogFeature(
            results: [
                .catalog(.available(initial)),
                .mutation(mutationResults, catalog: .available(refreshed)),
            ]
        )
        let model = makeCatalogModel(feature: feature)
        await model.activate(activation)

        await model.moveToTrash([chat, session])

        XCTAssertEqual(model.state.catalog, refreshed)
        XCTAssertEqual(model.state.availability, .available)
        XCTAssertNil(model.state.activity)
        XCTAssertEqual(
            model.state.mutationNotice,
            LibraryCatalogMutationNotice(
                action: .movedToTrash,
                results: mutationResults,
                catalogVerification: .verifiedCurrentContents
            )
        )
        let commands = await feature.commands
        XCTAssertEqual(
            commands,
            [
                .refresh(activation),
                .moveToTrash(activation, [chat, session]),
            ]
        )
    }

    func testRestoreProjectsTheAuthoritativeRefreshedCatalog() async throws {
        let scope = try makeScope("lib-20260830T120000000Z-2ABC")
        let activation = LibraryActivation(scope: scope, generation: 1)
        let session = LibraryAggregate.session(
            try SessionID("ses-20260822T153045123Z-P4R7")
        )
        let initial = LibraryCatalogSnapshot(
            active: [],
            trash: [presentationCatalogRow(session)]
        )
        let refreshed = LibraryCatalogSnapshot(
            active: [presentationCatalogRow(session)],
            trash: []
        )
        let mutationResults = [
            LibraryAggregateMutationResult(
                aggregate: session,
                outcome: .succeeded
            ),
        ]
        let feature = ScriptedLibraryCatalogFeature(
            results: [
                .catalog(.available(initial)),
                .mutation(mutationResults, catalog: .available(refreshed)),
            ]
        )
        let model = makeCatalogModel(feature: feature)
        await model.activate(activation)

        await model.restore(session)

        XCTAssertEqual(model.state.catalog, refreshed)
        XCTAssertEqual(
            model.state.mutationNotice,
            LibraryCatalogMutationNotice(
                action: .restored,
                results: mutationResults
            )
        )
        let commands = await feature.commands
        XCTAssertEqual(
            commands,
            [
                .refresh(activation),
                .restore(activation, [session]),
            ]
        )
    }

    func testFailedMutationWithUnavailableRefreshDoesNotKeepAStaleCatalog()
        async throws
    {
        let scope = try makeScope("lib-20260830T120000000Z-2ABC")
        let activation = LibraryActivation(scope: scope, generation: 1)
        let chat = LibraryAggregate.chat(
            try ChatID("cht-20260822T160201044Z-9NQF")
        )
        let initial = LibraryCatalogSnapshot(
            active: [presentationCatalogRow(chat)],
            trash: []
        )
        let failed = LibraryAggregateMutationResult(
            aggregate: chat,
            outcome: .failed
        )
        let feature = ScriptedLibraryCatalogFeature(
            results: [
                .catalog(.available(initial)),
                .mutation([failed], catalog: .unavailable),
            ]
        )
        let model = makeCatalogModel(feature: feature)
        await model.activate(activation)

        await model.moveToTrash(chat)

        XCTAssertNil(model.state.catalog)
        XCTAssertEqual(model.state.availability, .unavailable)
        XCTAssertEqual(
            model.state.mutationNotice,
            LibraryCatalogMutationNotice(
                action: .movedToTrash,
                results: [failed]
            )
        )
    }

    func testRefusedMutationKeepsTheKnownCatalogAndReportsBusyRows() async throws {
        let scope = try makeScope("lib-20260830T120000000Z-2ABC")
        let activation = LibraryActivation(scope: scope, generation: 1)
        let session = LibraryAggregate.session(
            try SessionID("ses-20260822T153045123Z-P4R7")
        )
        let initial = LibraryCatalogSnapshot(
            active: [presentationCatalogRow(session)],
            trash: []
        )
        let busy = LibraryAggregateMutationResult(
            aggregate: session,
            outcome: .busy
        )
        let feature = ScriptedLibraryCatalogFeature(
            results: [
                .catalog(.available(initial)),
                .mutationRefused([busy]),
            ]
        )
        let model = makeCatalogModel(feature: feature)
        await model.activate(activation)

        await model.moveToTrash(session)

        XCTAssertEqual(model.state.catalog, initial)
        XCTAssertEqual(model.state.availability, .available)
        XCTAssertNil(model.state.activity)
        XCTAssertEqual(
            model.state.mutationNotice,
            LibraryCatalogMutationNotice(
                action: .movedToTrash,
                results: [busy]
            )
        )
    }

    func testLibraryDeactivationRejectsALateCatalogResult() async throws {
        let scope = try makeScope("lib-20260830T120000000Z-2ABC")
        let feature = SuspendedLibraryCatalogFeature()
        let model = makeCatalogModel(feature: feature)
        let activation = Task {
            await model.activate(LibraryActivation(scope: scope, generation: 1))
        }
        await feature.waitUntilCalled()

        await model.activate(nil)
        await feature.resolve(
            .catalog(
                .available(LibraryCatalogSnapshot(active: [], trash: []))
            )
        )
        await activation.value

        XCTAssertEqual(model.state, .inactive)
    }

    func testSameIDReplacementGenerationReloadsInsteadOfKeepingStaleRows()
        async throws
    {
        let scope = try makeScope("lib-20260830T120000000Z-2ABC")
        let oldSession = LibraryAggregate.session(
            try SessionID("ses-20260822T153045123Z-P4R7")
        )
        let replacementSession = LibraryAggregate.session(
            try SessionID("ses-20260822T153145123Z-Q5S8")
        )
        let feature = ScriptedLibraryCatalogFeature(
            results: [
                .catalog(
                    .available(
                        LibraryCatalogSnapshot(
                            active: [presentationCatalogRow(oldSession)],
                            trash: []
                        )
                    )
                ),
                .catalog(
                    .available(
                        LibraryCatalogSnapshot(
                            active: [
                                presentationCatalogRow(replacementSession),
                            ],
                            trash: []
                        )
                    )
                ),
            ]
        )
        let model = makeCatalogModel(feature: feature)

        let firstActivation = LibraryActivation(scope: scope, generation: 1)
        let replacementActivation = LibraryActivation(scope: scope, generation: 2)
        await model.activate(firstActivation)
        await model.activate(replacementActivation)

        XCTAssertEqual(
            model.state.catalog?.active,
            [presentationCatalogRow(replacementSession)]
        )
        let commands = await feature.commands
        XCTAssertEqual(
            commands,
            [.refresh(firstActivation), .refresh(replacementActivation)]
        )
    }

    func testCommitUncertainNoticePersistsUntilAnAvailableRefreshVerifiesIt()
        async throws
    {
        let scope = try makeScope("lib-20260830T120000000Z-2ABC")
        let activation = LibraryActivation(scope: scope, generation: 1)
        let session = LibraryAggregate.session(
            try SessionID("ses-20260822T153045123Z-P4R7")
        )
        let initial = LibraryCatalogSnapshot(
            active: [presentationCatalogRow(session)],
            trash: []
        )
        let verified = LibraryCatalogSnapshot(
            active: [],
            trash: [presentationCatalogRow(session)]
        )
        let uncertain = LibraryAggregateMutationResult(
            aggregate: session,
            outcome: .commitUncertain
        )
        let feature = ScriptedLibraryCatalogFeature(
            results: [
                .catalog(.available(initial)),
                .mutation([uncertain], catalog: .unavailable),
                .catalog(.integrityMismatch),
                .catalog(.available(verified)),
            ]
        )
        let model = makeCatalogModel(feature: feature)
        await model.activate(activation)

        await model.moveToTrash(session)

        let unresolvedNotice = LibraryCatalogMutationNotice(
            action: .movedToTrash,
            results: [uncertain],
            catalogVerification: .unverified
        )
        XCTAssertEqual(model.state.availability, .unavailable)
        XCTAssertEqual(model.state.mutationNotice, unresolvedNotice)

        await model.refresh()

        XCTAssertEqual(model.state.availability, .integrityMismatch)
        XCTAssertEqual(model.state.mutationNotice, unresolvedNotice)

        await model.refresh()

        XCTAssertEqual(model.state.catalog, verified)
        XCTAssertEqual(model.state.availability, .available)
        XCTAssertNil(model.state.mutationNotice)
    }

    func testApplicationInvalidationRereadsInsteadOfPatchingCatalogRows()
        async throws
    {
        let scope = try makeScope("lib-20260830T120000000Z-2ABC")
        let activation = LibraryActivation(scope: scope, generation: 1)
        let initialSession = LibraryAggregate.session(
            try SessionID("ses-20260822T153045123Z-P4R7")
        )
        let importedSession = LibraryAggregate.session(
            try SessionID("ses-20260822T153145123Z-Q5S8")
        )
        let initial = LibraryCatalogSnapshot(
            active: [presentationCatalogRow(initialSession)],
            trash: []
        )
        let refreshed = LibraryCatalogSnapshot(
            active: [
                presentationCatalogRow(initialSession),
                presentationCatalogRow(importedSession),
            ],
            trash: []
        )
        let feature = ScriptedLibraryCatalogFeature(
            results: [
                .catalog(.available(initial)),
                .catalog(.available(refreshed)),
            ]
        )
        let invalidations = CatalogInvalidationSourceProbe()
        let model = makeCatalogModel(
            feature: feature,
            invalidationSource: invalidations
        )
        await model.activate(activation)
        let observation = Task { await model.observeInvalidations() }

        invalidations.send(
            LibraryCatalogInvalidation(
                activation: activation,
                reason: .audioImported
            )
        )
        while await feature.commands.count < 2 { await Task.yield() }

        XCTAssertEqual(model.state.catalog, refreshed)
        let commands = await feature.commands
        XCTAssertEqual(
            commands,
            [.refresh(activation), .refresh(activation)]
        )
        invalidations.finish()
        await observation.value
    }
}

@MainActor
private func makeCatalogModel(
    feature: any LibraryCatalogFeature,
    invalidationSource: any LibraryCatalogInvalidationSource =
        FinishedLibraryCatalogInvalidationSource()
) -> LibraryCatalogPresentationModel {
    LibraryCatalogPresentationModel(
        feature: feature,
        invalidationSource: invalidationSource
    )
}

private struct FinishedLibraryCatalogInvalidationSource:
    LibraryCatalogInvalidationSource
{
    var invalidations: AsyncStream<LibraryCatalogInvalidation> {
        AsyncStream { $0.finish() }
    }
}

private final class CatalogInvalidationSourceProbe:
    LibraryCatalogInvalidationSource,
    @unchecked Sendable
{
    let invalidations: AsyncStream<LibraryCatalogInvalidation>
    private let continuation:
        AsyncStream<LibraryCatalogInvalidation>.Continuation

    init() {
        let pair = AsyncStream<LibraryCatalogInvalidation>.makeStream()
        invalidations = pair.stream
        continuation = pair.continuation
    }

    func send(_ invalidation: LibraryCatalogInvalidation) {
        continuation.yield(invalidation)
    }

    func finish() {
        continuation.finish()
    }
}

private func makeScope(_ rawValue: String) throws -> LibraryScope {
    LibraryScope(libraryID: try LibraryID(rawValue))
}

private func presentationCatalogRow(
    _ aggregate: LibraryAggregate
) -> LibraryCatalogRow {
    let instant = try! UTCInstant("2026-08-30T12:00:00.000Z")
    switch aggregate {
    case let .session(sessionID):
        return .session(
            sessionID,
            LibrarySessionCatalogMetadata(
                acquisition: .recorded,
                createdAt: instant,
                hasSelectedTranscript: true
            )
        )
    case let .chat(chatID):
        return .chat(
            chatID,
            LibraryChatCatalogMetadata(
                title: .newChat,
                createdAt: instant,
                updatedAt: instant
            )
        )
    }
}

private actor ScriptedLibraryCatalogFeature: LibraryCatalogFeature {
    private var results: [LibraryCatalogCommandResult]
    private(set) var commands: [LibraryCatalogCommand] = []

    init(results: [LibraryCatalogCommandResult]) {
        self.results = results
    }

    func send(_ command: LibraryCatalogCommand) -> LibraryCatalogCommandResult {
        commands.append(command)
        guard !results.isEmpty else {
            return .catalog(.unavailable)
        }
        return results.removeFirst()
    }
}

private actor SuspendedLibraryCatalogFeature: LibraryCatalogFeature {
    private var continuation: CheckedContinuation<LibraryCatalogCommandResult, Never>?
    private var called = false

    func send(_ command: LibraryCatalogCommand) async -> LibraryCatalogCommandResult {
        called = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilCalled() async {
        while !called { await Task.yield() }
    }

    func resolve(_ result: LibraryCatalogCommandResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
