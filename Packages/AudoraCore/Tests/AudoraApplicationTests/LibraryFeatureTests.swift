import AudoraApplication
import AudoraDomain
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class LibraryFeatureTests: XCTestCase {
    func testStartResolvesTheInitialLibraryAndReplacesTheSnapshot() async {
        let port = RecordingLibraryBootstrapPort()
        let feature = DefaultLibraryFeature(bootstrapPort: port)

        let initialState = await feature.currentState
        XCTAssertEqual(initialState, LibraryFeatureState(phase: .awaitingBootstrap))

        await feature.send(.start)

        let finalState = await feature.currentState
        XCTAssertEqual(finalState, LibraryFeatureState(phase: .noLibrarySelected))
        let effects = await port.effects
        XCTAssertEqual(effects, [.resolveInitialLibrary])
    }

    func testStateStreamYieldsCurrentSnapshotAndPublishedReplacement() async {
        let feature = DefaultLibraryFeature(
            bootstrapPort: RecordingLibraryBootstrapPort()
        )
        var states = feature.states.makeAsyncIterator()

        let initialState = await states.next()
        XCTAssertEqual(initialState, LibraryFeatureState(phase: .awaitingBootstrap))

        await feature.send(.start)

        let replacementState = await states.next()
        XCTAssertEqual(replacementState, LibraryFeatureState(phase: .noLibrarySelected))
    }

    func testStartAfterBootstrapIsANoOp() async {
        let port = RecordingLibraryBootstrapPort()
        let feature = DefaultLibraryFeature(bootstrapPort: port)

        await feature.send(.start)
        await feature.send(.start)

        let effects = await port.effects
        XCTAssertEqual(effects, [.resolveInitialLibrary])
    }

    func testConcurrentStartsResolveTheInitialLibraryOnlyOnce() async {
        let port = SuspendedLibraryBootstrapPort()
        let feature = DefaultLibraryFeature(bootstrapPort: port)

        let firstStart = Task {
            await feature.send(.start)
        }
        await port.waitForFirstCall()

        let secondStart = Task {
            await feature.send(.start)
        }
        await secondStart.value

        let effectsWhileFirstStartIsSuspended = await port.effects
        XCTAssertEqual(
            effectsWhileFirstStartIsSuspended,
            [.resolveInitialLibrary]
        )

        await port.resumeFirstCall()
        await firstStart.value
    }
}

private actor RecordingLibraryBootstrapPort: LibraryBootstrapPort {
    enum Effect: Equatable {
        case resolveInitialLibrary
    }

    private(set) var effects: [Effect] = []

    func resolveInitialLibrary() async -> LibraryAvailability {
        effects.append(.resolveInitialLibrary)
        return .noLibrarySelected
    }
}

private actor SuspendedLibraryBootstrapPort: LibraryBootstrapPort {
    private(set) var effects: [RecordingLibraryBootstrapPort.Effect] = []
    private var firstCallContinuation: CheckedContinuation<Void, Never>?

    func resolveInitialLibrary() async -> LibraryAvailability {
        effects.append(.resolveInitialLibrary)
        if effects.count == 1 {
            await withCheckedContinuation { continuation in
                firstCallContinuation = continuation
            }
        }
        return .noLibrarySelected
    }

    func waitForFirstCall() async {
        while effects.isEmpty {
            await Task.yield()
        }
    }

    func resumeFirstCall() {
        firstCallContinuation?.resume()
        firstCallContinuation = nil
    }
}
