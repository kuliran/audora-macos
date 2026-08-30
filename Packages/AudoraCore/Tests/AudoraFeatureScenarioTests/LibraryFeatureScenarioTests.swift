import AudoraApplication
import AudoraContracts
import AudoraDomain
import Foundation
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class LibraryFeatureScenarioTests: XCTestCase {
    func testEveryPortableLibraryLifecycleScenarioMatchesTheSwiftFeature() async throws {
        let resources: [ContractResource] = [
            .libraryLaunchNoSelectionScenario,
            .libraryCreateScenario,
            .libraryRelaunchScenario,
            .libraryFailedSwitchScenario,
            .libraryCloseReopenScenario,
            .libraryRevealScenario,
            .libraryExternalOpenScenario,
            .libraryNewerRootScenario,
        ]

        for resource in resources {
            let data = try ContractResources.data(for: resource)
            let dto = try JSONDecoder().decode(LibraryFeatureScenarioDTO.self, from: data)
            let scenario = try LibraryFeatureScenario(dto)
            let recorder = ScenarioTraceRecorder(events: scenario.dependencyTrace)
            let workspace = ScenarioWorkspace(
                recorder: recorder,
                preparation: scenario.initialState.preparationOutcome
            )
            let feature = DefaultLibraryFeature(
                workspace: workspace,
                clock: ScenarioClock(recorder: recorder),
                idGenerator: ScenarioIDGenerator(recorder: recorder)
            )

            if scenario.initialState.requiresPreparation {
                await feature.send(.start)
            }
            let initial = await feature.currentState
            XCTAssertEqual(
                initial,
                scenario.initialState.applicationState,
                scenario.scenarioID
            )

            for command in scenario.commands {
                await feature.send(command)
            }

            let final = await feature.currentState
            XCTAssertEqual(
                final,
                scenario.expectedState.applicationState,
                scenario.scenarioID
            )
            let status = await recorder.status
            XCTAssertEqual(status.effects, scenario.expectedEffects, scenario.scenarioID)
            XCTAssertEqual(status.consumedCount, scenario.dependencyTrace.count, scenario.scenarioID)
            XCTAssertEqual(status.errors, [], scenario.scenarioID)
        }
    }

    func testScenarioEnvelopeRejectsUnsupportedVersionOrAmbiguousCommandShape() throws {
        let data = try ContractResources.data(for: .libraryCreateScenario)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["schemaVersion"] = 2
        XCTAssertThrowsError(
            try LibraryFeatureScenario(
                JSONDecoder().decode(
                    LibraryFeatureScenarioDTO.self,
                    from: JSONSerialization.data(withJSONObject: object)
                )
            )
        )

        object["schemaVersion"] = 1
        object["commands"] = [["kind": "create"]]
        XCTAssertThrowsError(
            try LibraryFeatureScenario(
                JSONDecoder().decode(
                    LibraryFeatureScenarioDTO.self,
                    from: JSONSerialization.data(withJSONObject: object)
                )
            )
        )
    }
}

private struct LibraryFeatureScenarioDTO: Decodable {
    let schemaVersion: UInt32
    let scenarioId: String
    let initialState: ScenarioStateDTO
    let command: ScenarioCommandDTO?
    let commands: [ScenarioCommandDTO]?
    let dependencyTrace: [ScenarioEventDTO]
    let expectedState: ScenarioStateDTO
    let expectedEffects: [ScenarioEffectDTO]
}

private struct ScenarioStateDTO: Decodable {
    let kind: String
    let recentAvailable: Bool?
    let library: ScenarioLibraryDTO?
    let libraryId: String?
    let reason: String?
    let notice: String?
}

private struct ScenarioLibraryDTO: Decodable {
    struct Preferences: Decodable {
        let language: String
        let annotationsVisible: Bool
        let playbackRate: Double
    }

    let libraryId: String
    let preferences: Preferences
    let profileKind: String
    let statementCount: UInt64
}

private struct ScenarioCommandDTO: Decodable {
    let kind: String
    let token: String?
}

private struct ScenarioEventDTO: Decodable {
    let port: String
    let effect: String
    let outcome: String
    let library: ScenarioLibraryDTO?
    let notice: String?
}

private struct ScenarioEffectDTO: Decodable {
    let kind: String
}

private struct LibraryFeatureScenario {
    let scenarioID: String
    let initialState: ScenarioState
    let commands: [LibraryCommand]
    let dependencyTrace: [ScenarioEvent]
    let expectedState: ScenarioState
    let expectedEffects: [String]

    init(_ dto: LibraryFeatureScenarioDTO) throws {
        guard dto.schemaVersion == 1 else { throw ScenarioError.unsupportedVersion }
        guard (dto.command == nil) != (dto.commands == nil) else {
            throw ScenarioError.ambiguousCommands
        }
        scenarioID = dto.scenarioId
        initialState = try ScenarioState(dto.initialState)
        let commandDTOs = dto.command.map { [$0] } ?? dto.commands ?? []
        guard !commandDTOs.isEmpty else { throw ScenarioError.ambiguousCommands }
        commands = try commandDTOs.map(Self.mapCommand)
        dependencyTrace = try dto.dependencyTrace.map(ScenarioEvent.init)
        expectedState = try ScenarioState(dto.expectedState)
        expectedEffects = dto.expectedEffects.map(\.kind)
    }

    private static func mapCommand(_ dto: ScenarioCommandDTO) throws -> LibraryCommand {
        switch dto.kind {
        case "start": return .start
        case "create": return .create
        case "chooseExisting": return .chooseExisting
        case "reopenRecent": return .reopenRecent
        case "reveal": return .reveal
        case "close": return .close
        case "openExternal":
            guard let raw = dto.token, let token = LibraryOpenRequestToken(raw) else {
                throw ScenarioError.invalidCommand
            }
            return .openExternal(token)
        default: throw ScenarioError.invalidCommand
        }
    }
}

private enum ScenarioError: Error {
    case unsupportedVersion
    case ambiguousCommands
    case invalidState
    case invalidCommand
    case invalidEvent
}

private enum ScenarioState {
    case awaiting
    case noLibrary(recent: Bool, notice: LibraryNotice?)
    case active(ActiveLibrarySnapshot, notice: LibraryNotice?)
    case readOnly(ReadOnlyLibrarySnapshot, notice: LibraryNotice?)

    init(_ dto: ScenarioStateDTO) throws {
        let notice = try dto.notice.map(mapNotice)
        switch dto.kind {
        case "awaitingBootstrap": self = .awaiting
        case "noLibrarySelected":
            self = .noLibrary(recent: dto.recentAvailable ?? false, notice: notice)
        case "active":
            self = .active(try ScenarioState.snapshot(dto.library), notice: notice)
        case "readOnly":
            guard dto.reason == "newerSchema" else { throw ScenarioError.invalidState }
            self = .readOnly(
                ReadOnlyLibrarySnapshot(
                    libraryID: try dto.libraryId.map(LibraryID.init)
                ),
                notice: notice
            )
        default: throw ScenarioError.invalidState
        }
    }

    var requiresPreparation: Bool {
        if case .awaiting = self { return false }
        return true
    }

    var preparationOutcome: LibraryOpenOutcome? {
        switch self {
        case .awaiting: nil
        case let .noLibrary(recent, _): .noLibrarySelected(recentAvailable: recent)
        case let .active(snapshot, _): .opened(snapshot)
        case let .readOnly(snapshot, _): .readOnly(snapshot, reason: .newerSchema)
        }
    }

    var applicationState: LibraryFeatureState {
        switch self {
        case .awaiting:
            LibraryFeatureState(selection: .awaitingBootstrap)
        case let .noLibrary(recent, notice):
            LibraryFeatureState(
                selection: .noLibrarySelected(recentAvailable: recent),
                notice: notice
            )
        case let .active(snapshot, notice):
            LibraryFeatureState(selection: .active(snapshot), notice: notice)
        case let .readOnly(snapshot, notice):
            LibraryFeatureState(
                selection: .readOnly(snapshot, reason: .newerSchema),
                notice: notice
            )
        }
    }

    fileprivate static func snapshot(_ dto: ScenarioLibraryDTO?) throws -> ActiveLibrarySnapshot {
        guard let dto,
              dto.preferences.language == "en",
              dto.profileKind == "null"
        else {
            throw ScenarioError.invalidState
        }
        return ActiveLibrarySnapshot(
            libraryID: try LibraryID(dto.libraryId),
            preferences: try LibraryPreferences(
                language: .english,
                annotationsVisible: dto.preferences.annotationsVisible,
                playbackRate: dto.preferences.playbackRate
            ),
            profile: .nullProfile(statementCount: dto.statementCount)
        )
    }
}

private struct ScenarioEvent: Sendable {
    let port: String
    let effect: String
    let outcome: String
    let library: ActiveLibrarySnapshot?
    let notice: LibraryNotice?

    init(_ dto: ScenarioEventDTO) throws {
        guard ["libraryWorkspace", "clock", "libraryIdGenerator"].contains(dto.port) else {
            throw ScenarioError.invalidEvent
        }
        port = dto.port
        effect = dto.effect
        outcome = dto.outcome
        library = try dto.library.map { try ScenarioState.snapshot($0) }
        notice = try dto.notice.map(mapNotice)
    }
}

private func mapNotice(_ raw: String) throws -> LibraryNotice {
    guard let notice = LibraryNotice(rawValue: raw) else { throw ScenarioError.invalidState }
    return notice
}

private actor ScenarioTraceRecorder {
    struct Status: Sendable {
        let effects: [String]
        let consumedCount: Int
        let errors: [String]
    }

    private let events: [ScenarioEvent]
    private var index = 0
    private var effects: [String] = []
    private var errors: [String] = []

    init(events: [ScenarioEvent]) { self.events = events }

    func consume(port: String, effect: String) -> ScenarioEvent? {
        effects.append(effect)
        guard index < events.count else {
            errors.append("unexpected-effect")
            return nil
        }
        let event = events[index]
        index += 1
        if event.port != port || event.effect != effect {
            errors.append("trace-order-mismatch")
        }
        return event
    }

    var status: Status {
        Status(effects: effects, consumedCount: index, errors: errors)
    }
}

private actor ScenarioWorkspace: LibraryWorkspacePort {
    private let recorder: ScenarioTraceRecorder
    private var preparation: LibraryOpenOutcome?

    init(recorder: ScenarioTraceRecorder, preparation: LibraryOpenOutcome?) {
        self.recorder = recorder
        self.preparation = preparation
    }

    func restoreActiveLibrary() async -> LibraryOpenOutcome {
        if let preparation {
            self.preparation = nil
            return preparation
        }
        return await open(effect: "restoreActiveLibrary")
    }

    func createLibrary(_ seed: NewLibrarySeed) async -> LibraryOpenOutcome {
        await open(effect: "createLibrary")
    }

    func chooseLibrary() async -> LibraryOpenOutcome { await open(effect: "chooseLibrary") }

    func openExternalRequest(_ token: LibraryOpenRequestToken) async -> LibraryOpenOutcome {
        await open(effect: "openExternalRequest")
    }

    func reopenRecentLibrary() async -> LibraryOpenOutcome {
        await open(effect: "reopenRecentLibrary")
    }

    func revealActiveLibrary() async -> LibraryActionOutcome {
        await action(effect: "revealActiveLibrary")
    }

    func closeActiveLibrary() async -> LibraryActionOutcome {
        await action(effect: "closeActiveLibrary")
    }

    private func open(effect: String) async -> LibraryOpenOutcome {
        guard let event = await recorder.consume(port: "libraryWorkspace", effect: effect) else {
            return .failed(.candidateCorrupt)
        }
        switch event.outcome {
        case "noLibrarySelected": return .noLibrarySelected(recentAvailable: false)
        case "opened":
            guard let library = event.library else { return .failed(.candidateCorrupt) }
            return .opened(library)
        case "candidateCorrupt": return .failed(.candidateCorrupt)
        case "newerSchemaReadOnly":
            return .readOnly(
                ReadOnlyLibrarySnapshot(
                    libraryID: try? LibraryID("lib-20260830T120000000Z-2ABC")
                ),
                reason: .newerSchema
            )
        default: return .failed(event.notice ?? .candidateCorrupt)
        }
    }

    private func action(effect: String) async -> LibraryActionOutcome {
        guard let event = await recorder.consume(port: "libraryWorkspace", effect: effect) else {
            return .failed(.closeFailed)
        }
        return event.outcome == "succeeded"
            ? .succeeded(recentAvailable: true)
            : .failed(event.notice ?? .closeFailed)
    }
}

private actor ScenarioClock: LibraryClock {
    let recorder: ScenarioTraceRecorder

    init(recorder: ScenarioTraceRecorder) {
        self.recorder = recorder
    }

    func now() async -> UTCInstant {
        let event = await recorder.consume(port: "clock", effect: "now")
        return (try? UTCInstant(event?.outcome ?? ""))
            ?? (try! UTCInstant("2026-08-30T12:00:00.000Z"))
    }
}

private actor ScenarioIDGenerator: LibraryIDGenerator {
    let recorder: ScenarioTraceRecorder

    init(recorder: ScenarioTraceRecorder) {
        self.recorder = recorder
    }

    func generateLibraryID(at instant: UTCInstant) async -> LibraryID {
        let event = await recorder.consume(
            port: "libraryIdGenerator",
            effect: "generateLibraryId"
        )
        return (try? LibraryID(event?.outcome ?? ""))
            ?? (try! LibraryID("lib-20260830T120000000Z-2ABC"))
    }
}
