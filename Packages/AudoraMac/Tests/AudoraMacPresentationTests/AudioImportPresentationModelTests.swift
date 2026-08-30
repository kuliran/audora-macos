import AudoraApplication
import AudoraMacPresentation
import XCTest

@MainActor
final class AudioImportPresentationModelTests: XCTestCase {
    func testStartProjectsBoundedFeatureStatesWithoutLaunchingAnImport() async {
        let feature = ScriptedAudioFeature(
            snapshots: [
                AudioImportFeatureState(status: .idle),
                AudioImportFeatureState(status: .selecting),
                AudioImportFeatureState(status: .failed(.unsupportedMedia)),
            ]
        )
        let model = AudioImportPresentationModel(feature: feature)

        await model.start()
        await model.start()
        let commands = await feature.recordedCommands()

        XCTAssertEqual(model.snapshot?.status, .failed(.unsupportedMedia))
        XCTAssertFalse(model.isImporting)
        XCTAssertEqual(commands, [])
    }

    func testRestartSerializesClearBeforeChooseAndCancelUsesTypedCommand() async {
        let feature = ScriptedAudioFeature(
            snapshots: [AudioImportFeatureState(status: .failed(.decodeFailed))]
        )
        let model = AudioImportPresentationModel(feature: feature)
        await model.start()

        model.restart()
        await feature.waitForCommandCount(2)
        model.send(.cancelImport)
        await feature.waitForCommandCount(3)
        let commands = await feature.recordedCommands()

        XCTAssertEqual(commands, [.clearResult, .chooseAudio, .cancelImport])
    }
}

private actor ScriptedAudioFeature: AudioImportFeature {
    nonisolated let states: AsyncStream<AudioImportFeatureState>

    private let state: AudioImportFeatureState
    private var commands: [AudioImportCommand] = []

    init(snapshots: [AudioImportFeatureState]) {
        state = snapshots.last ?? AudioImportFeatureState(status: .idle)
        states = AsyncStream { continuation in
            for snapshot in snapshots { continuation.yield(snapshot) }
            continuation.finish()
        }
    }

    var currentState: AudioImportFeatureState { state }

    func send(_ command: AudioImportCommand) {
        commands.append(command)
    }

    func recordedCommands() -> [AudioImportCommand] { commands }

    func waitForCommandCount(_ expected: Int) async {
        while commands.count < expected { await Task.yield() }
    }
}
