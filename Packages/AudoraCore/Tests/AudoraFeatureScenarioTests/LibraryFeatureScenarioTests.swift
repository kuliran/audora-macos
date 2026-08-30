import AudoraApplication
import AudoraContracts
import AudoraDomain
import Foundation
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class LibraryFeatureScenarioTests: XCTestCase {
    func testLaunchWithoutASelectedLibraryMatchesThePortableScenario() async throws {
        let data = try ContractResources.data(
            for: .libraryLaunchNoSelectionScenario
        )
        let dto = try JSONDecoder().decode(
            LibraryFeatureScenarioDTO.self,
            from: data
        )
        let scenario = try LibraryFeatureScenario(dto: dto)
        let port = ScriptedLibraryBootstrapPort(
            events: scenario.dependencyTrace
        )
        let feature = DefaultLibraryFeature(bootstrapPort: port)

        let initialState = await feature.currentState
        XCTAssertEqual(initialState, scenario.initialState.applicationState)

        await feature.send(scenario.command.applicationCommand)

        let finalState = await feature.currentState
        XCTAssertEqual(finalState, scenario.expectedState.applicationState)

        let firstRun = await port.status
        XCTAssertEqual(firstRun.calls, scenario.dependencyTrace.map(\.call))
        XCTAssertEqual(firstRun.effects, scenario.expectedEffects)
        XCTAssertEqual(firstRun.consumedEventCount, 1)
        XCTAssertEqual(firstRun.remainingEventCount, 0)

        await feature.send(scenario.command.applicationCommand)

        let secondRun = await port.status
        XCTAssertEqual(secondRun, firstRun)
    }

    func testScenarioRejectsAnUnknownSchemaVersion() {
        XCTAssertThrowsError(
            try LibraryFeatureScenario(
                dto: LibraryFeatureScenarioDTO(schemaVersion: 2)
            )
        ) { error in
            XCTAssertEqual(
                error as? LibraryFeatureScenarioError,
                .unsupportedSchemaVersion(2)
            )
        }
    }

    func testScenarioRejectsAnUnknownCommand() {
        XCTAssertThrowsError(
            try LibraryFeatureScenario(
                dto: LibraryFeatureScenarioDTO(command: KindDTO(kind: "open"))
            )
        ) { error in
            XCTAssertEqual(
                error as? LibraryFeatureScenarioError,
                .unsupportedCommand("open")
            )
        }
    }

    func testScenarioRejectsAnUnknownState() {
        XCTAssertThrowsError(
            try LibraryFeatureScenario(
                dto: LibraryFeatureScenarioDTO(
                    initialState: KindDTO(kind: "loading")
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? LibraryFeatureScenarioError,
                .unsupportedState("loading")
            )
        }
    }

    func testScenarioRejectsAnUnknownDependencyPort() {
        let event = DependencyEventDTO(
            port: "filesystem",
            effect: KindDTO(kind: "resolveInitialLibrary"),
            outcome: KindDTO(kind: "noLibrarySelected")
        )

        XCTAssertThrowsError(
            try LibraryFeatureScenario(
                dto: LibraryFeatureScenarioDTO(dependencyTrace: [event])
            )
        ) { error in
            XCTAssertEqual(
                error as? LibraryFeatureScenarioError,
                .unsupportedPort("filesystem")
            )
        }
    }

    func testScenarioRejectsAnUnknownEffect() {
        let event = DependencyEventDTO(
            port: "libraryBootstrap",
            effect: KindDTO(kind: "loadLibrary"),
            outcome: KindDTO(kind: "noLibrarySelected")
        )

        XCTAssertThrowsError(
            try LibraryFeatureScenario(
                dto: LibraryFeatureScenarioDTO(dependencyTrace: [event])
            )
        ) { error in
            XCTAssertEqual(
                error as? LibraryFeatureScenarioError,
                .unsupportedEffect("loadLibrary")
            )
        }
    }

    func testScenarioRejectsAnUnknownOutcome() {
        let event = DependencyEventDTO(
            port: "libraryBootstrap",
            effect: KindDTO(kind: "resolveInitialLibrary"),
            outcome: KindDTO(kind: "librarySelected")
        )

        XCTAssertThrowsError(
            try LibraryFeatureScenario(
                dto: LibraryFeatureScenarioDTO(dependencyTrace: [event])
            )
        ) { error in
            XCTAssertEqual(
                error as? LibraryFeatureScenarioError,
                .unsupportedOutcome("librarySelected")
            )
        }
    }
}

private struct LibraryFeatureScenarioDTO: Decodable {
    let schemaVersion: Int32
    let scenarioId: String
    let initialState: KindDTO
    let command: KindDTO
    let dependencyTrace: [DependencyEventDTO]
    let expectedState: KindDTO
    let expectedEffects: [KindDTO]

    init(
        schemaVersion: Int32 = 1,
        scenarioId: String = "library.launch.no-selection",
        initialState: KindDTO = KindDTO(kind: "awaitingBootstrap"),
        command: KindDTO = KindDTO(kind: "start"),
        dependencyTrace: [DependencyEventDTO] = [
            DependencyEventDTO(
                port: "libraryBootstrap",
                effect: KindDTO(kind: "resolveInitialLibrary"),
                outcome: KindDTO(kind: "noLibrarySelected")
            ),
        ],
        expectedState: KindDTO = KindDTO(kind: "noLibrarySelected"),
        expectedEffects: [KindDTO] = [
            KindDTO(kind: "resolveInitialLibrary"),
        ]
    ) {
        self.schemaVersion = schemaVersion
        self.scenarioId = scenarioId
        self.initialState = initialState
        self.command = command
        self.dependencyTrace = dependencyTrace
        self.expectedState = expectedState
        self.expectedEffects = expectedEffects
    }
}

private struct KindDTO: Decodable {
    let kind: String
}

private struct DependencyEventDTO: Decodable {
    let port: String
    let effect: KindDTO
    let outcome: KindDTO
}

private struct LibraryFeatureScenario {
    let initialState: ScenarioState
    let command: ScenarioCommand
    let dependencyTrace: [ScenarioDependencyEvent]
    let expectedState: ScenarioState
    let expectedEffects: [ScenarioEffect]

    init(dto: LibraryFeatureScenarioDTO) throws {
        guard dto.schemaVersion == 1 else {
            throw LibraryFeatureScenarioError.unsupportedSchemaVersion(
                dto.schemaVersion
            )
        }
        guard dto.scenarioId == "library.launch.no-selection" else {
            throw LibraryFeatureScenarioError.unsupportedScenarioID(
                dto.scenarioId
            )
        }
        guard dto.dependencyTrace.count == 1 else {
            throw LibraryFeatureScenarioError.unexpectedDependencyCount(
                dto.dependencyTrace.count
            )
        }
        guard dto.expectedEffects.count == 1 else {
            throw LibraryFeatureScenarioError.unexpectedExpectedEffectCount(
                dto.expectedEffects.count
            )
        }

        initialState = try Self.mapState(dto.initialState)
        command = try Self.mapCommand(dto.command)
        dependencyTrace = try dto.dependencyTrace.map(Self.mapDependencyEvent)
        expectedState = try Self.mapState(dto.expectedState)
        expectedEffects = try dto.expectedEffects.map(Self.mapEffect)
    }

    private static func mapState(_ dto: KindDTO) throws -> ScenarioState {
        switch dto.kind {
        case "awaitingBootstrap":
            .awaitingBootstrap
        case "noLibrarySelected":
            .noLibrarySelected
        default:
            throw LibraryFeatureScenarioError.unsupportedState(dto.kind)
        }
    }

    private static func mapCommand(_ dto: KindDTO) throws -> ScenarioCommand {
        guard dto.kind == "start" else {
            throw LibraryFeatureScenarioError.unsupportedCommand(dto.kind)
        }
        return .start
    }

    private static func mapDependencyEvent(
        _ dto: DependencyEventDTO
    ) throws -> ScenarioDependencyEvent {
        guard dto.port == "libraryBootstrap" else {
            throw LibraryFeatureScenarioError.unsupportedPort(dto.port)
        }
        return ScenarioDependencyEvent(
            port: .libraryBootstrap,
            effect: try mapEffect(dto.effect),
            outcome: try mapOutcome(dto.outcome)
        )
    }

    private static func mapEffect(_ dto: KindDTO) throws -> ScenarioEffect {
        guard dto.kind == "resolveInitialLibrary" else {
            throw LibraryFeatureScenarioError.unsupportedEffect(dto.kind)
        }
        return .resolveInitialLibrary
    }

    private static func mapOutcome(_ dto: KindDTO) throws -> ScenarioOutcome {
        guard dto.kind == "noLibrarySelected" else {
            throw LibraryFeatureScenarioError.unsupportedOutcome(dto.kind)
        }
        return .noLibrarySelected
    }
}

private enum LibraryFeatureScenarioError: Error, Equatable {
    case unsupportedSchemaVersion(Int32)
    case unsupportedScenarioID(String)
    case unsupportedCommand(String)
    case unsupportedState(String)
    case unsupportedPort(String)
    case unsupportedEffect(String)
    case unsupportedOutcome(String)
    case unexpectedDependencyCount(Int)
    case unexpectedExpectedEffectCount(Int)
}

private enum ScenarioState: Equatable, Sendable {
    case awaitingBootstrap
    case noLibrarySelected

    var applicationState: LibraryFeatureState {
        switch self {
        case .awaitingBootstrap:
            LibraryFeatureState(phase: .awaitingBootstrap)
        case .noLibrarySelected:
            LibraryFeatureState(phase: .noLibrarySelected)
        }
    }
}

private enum ScenarioCommand: Equatable, Sendable {
    case start

    var applicationCommand: LibraryCommand {
        switch self {
        case .start:
            .start
        }
    }
}

private enum ScenarioPort: Equatable, Sendable {
    case libraryBootstrap
}

private enum ScenarioEffect: Equatable, Sendable {
    case resolveInitialLibrary
}

private enum ScenarioOutcome: Equatable, Sendable {
    case noLibrarySelected

    var domainValue: LibraryAvailability {
        switch self {
        case .noLibrarySelected:
            .noLibrarySelected
        }
    }
}

private struct ScenarioDependencyEvent: Equatable, Sendable {
    let port: ScenarioPort
    let effect: ScenarioEffect
    let outcome: ScenarioOutcome

    var call: ScenarioDependencyCall {
        ScenarioDependencyCall(port: port, effect: effect)
    }
}

private struct ScenarioDependencyCall: Equatable, Sendable {
    let port: ScenarioPort
    let effect: ScenarioEffect
}

private struct ScriptedPortStatus: Equatable, Sendable {
    let calls: [ScenarioDependencyCall]
    let effects: [ScenarioEffect]
    let consumedEventCount: Int
    let remainingEventCount: Int
}

private actor ScriptedLibraryBootstrapPort: LibraryBootstrapPort {
    private let events: [ScenarioDependencyEvent]
    private var calls: [ScenarioDependencyCall] = []
    private var nextEventIndex = 0

    init(events: [ScenarioDependencyEvent]) {
        self.events = events
    }

    var status: ScriptedPortStatus {
        ScriptedPortStatus(
            calls: calls,
            effects: calls.map(\.effect),
            consumedEventCount: nextEventIndex,
            remainingEventCount: events.count - nextEventIndex
        )
    }

    func resolveInitialLibrary() async -> LibraryAvailability {
        let call = ScenarioDependencyCall(
            port: .libraryBootstrap,
            effect: .resolveInitialLibrary
        )
        calls.append(call)

        guard nextEventIndex < events.count else {
            return .noLibrarySelected
        }
        let event = events[nextEventIndex]
        nextEventIndex += 1
        return event.outcome.domainValue
    }
}
