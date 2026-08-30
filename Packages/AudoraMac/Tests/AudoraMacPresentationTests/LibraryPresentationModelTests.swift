import AudoraApplication
import AudoraMacPresentation
import XCTest

@MainActor
final class LibraryPresentationModelTests: XCTestCase {
    func testStartSendsOneTypedCommandAndProjectsTheFinalSnapshot() async {
        let feature = ScriptedLibraryFeature(
            snapshots: [
                LibraryFeatureState(phase: .awaitingBootstrap),
                LibraryFeatureState(phase: .noLibrarySelected),
            ]
        )
        let model = LibraryPresentationModel(feature: feature)

        await model.start()
        await model.start()

        XCTAssertEqual(
            model.snapshot,
            LibraryFeatureState(phase: .noLibrarySelected)
        )
        let commands = await feature.commands
        XCTAssertEqual(commands, [.start])
    }
}

private actor ScriptedLibraryFeature: LibraryFeature {
    nonisolated let states: AsyncStream<LibraryFeatureState>

    private let state: LibraryFeatureState
    private(set) var commands: [LibraryCommand] = []

    init(snapshots: [LibraryFeatureState]) {
        state = snapshots.last ?? LibraryFeatureState(phase: .awaitingBootstrap)
        states = AsyncStream { continuation in
            for snapshot in snapshots {
                continuation.yield(snapshot)
            }
            continuation.finish()
        }
    }

    var currentState: LibraryFeatureState {
        state
    }

    func send(_ command: LibraryCommand) async {
        commands.append(command)
    }
}
