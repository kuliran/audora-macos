import AudoraApplication
import Combine

@MainActor
public final class ChatCommandDispatcher: ObservableObject {
    @Published public private(set) var admissionState: ApplicationCommandAdmissionState

    let feature: any ApplicationCommandFeature
    private var admissionStateConsumer: Task<Void, Never>?

    public init(feature: any ApplicationCommandFeature) {
        self.feature = feature
        admissionState = feature.admissionState
        let states = feature.admissionStates
        admissionStateConsumer = Task { @MainActor [weak self] in
            for await state in states {
                guard !Task.isCancelled else { return }
                self?.admissionState = state
            }
        }
    }

    deinit {
        admissionStateConsumer?.cancel()
    }

    public var isLibraryNavigationPending: Bool {
        admissionState.isLibraryNavigationPending
    }

    public var isChatBoundaryPending: Bool {
        admissionState.isChatBoundaryPending
    }

    public var isOrderlyTerminationPending: Bool {
        admissionState.isOrderlyTerminationPending
    }

    @discardableResult
    public func enqueue(_ command: ChatCommand) -> ApplicationCommandReceipt<Void> {
        let receipt = feature.enqueue(command)
        admissionState = feature.admissionState
        return receipt
    }

    public func sendAndWait(_ command: ChatCommand) async {
        await enqueue(command).value
    }

    @discardableResult
    fileprivate func enqueue(
        _ intent: LibrarySelectionIntent
    ) -> ApplicationCommandReceipt<Bool> {
        let receipt = feature.enqueue(intent)
        admissionState = feature.admissionState
        return receipt
    }
}

@MainActor
public final class LibrarySelectionCommandDispatcher {
    private let commandDispatcher: ChatCommandDispatcher

    public init(commandDispatcher: ChatCommandDispatcher) {
        self.commandDispatcher = commandDispatcher
    }

    @discardableResult
    public func enqueue(
        _ intent: LibrarySelectionIntent
    ) -> ApplicationCommandReceipt<Bool> {
        commandDispatcher.enqueue(intent)
    }

    @discardableResult
    public func sendAndWait(_ intent: LibrarySelectionIntent) async -> Bool {
        await enqueue(intent).value
    }
}
