import AudoraApplication
import AudoraDomain
import AudoraMacPresentation
import XCTest

@MainActor
final class ReviewPresentationModelTests: XCTestCase {
    func testModelProjectsStateAndSendsTypedReviewCommands() async throws {
        let feature = ScriptedReviewFeature()
        let model = ReviewPresentationModel(feature: feature)
        let selection = ReviewSelection(
            scope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T120000000Z-1ABC")
            ),
            sessionID: try SessionID("ses-20260830T120100000Z-2CDE")
        )

        await model.start()
        model.selectSession(selection)
        model.play()
        model.pause()
        model.setAnnotationsVisible(false)
        model.retranscribe()
        model.clearSelection()
        await feature.waitForCommandCount(6)

        guard case let .unavailable(_, reason) = model.state else {
            return XCTFail("expected initial Review projection")
        }
        XCTAssertEqual(reason, .noSession)
        let commands = await feature.recordedCommands()
        XCTAssertEqual(
            commands,
            [
                .selectSession(selection),
                .play,
                .pause,
                .setAnnotationsVisible(false),
                .retranscribe,
                .clearSelection,
            ]
        )
    }
}

private actor ScriptedReviewFeature: ReviewFeature {
    nonisolated let states: AsyncStream<ReviewFeatureState>
    private let state: ReviewFeatureState
    private var commands: [ReviewCommand] = []

    init() {
        let state = ReviewFeatureState.unavailable(
            selection: nil,
            reason: .noSession
        )
        self.state = state
        states = AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    var currentState: ReviewFeatureState { state }

    func send(_ command: ReviewCommand) { commands.append(command) }

    func recordedCommands() -> [ReviewCommand] { commands }

    func waitForCommandCount(_ expected: Int) async {
        while commands.count < expected { await Task.yield() }
    }
}
