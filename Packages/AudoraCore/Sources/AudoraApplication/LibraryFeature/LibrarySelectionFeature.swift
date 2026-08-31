import AudoraDomain

public enum LibrarySelectionIntent: Equatable, Sendable {
    case create
    case chooseExisting
    case reopenRecent
    case openExternal(LibraryOpenRequestToken)
    case close

    fileprivate var command: LibraryCommand {
        switch self {
        case .create: .create
        case .chooseExisting: .chooseExisting
        case .reopenRecent: .reopenRecent
        case let .openExternal(token): .openExternal(token)
        case .close: .close
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol LibrarySelectionFeature: Sendable {
    @discardableResult
    func send(_ intent: LibrarySelectionIntent) async -> Bool
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol ApplicationCommandFeature: ChatFeature, LibrarySelectionFeature {}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor DefaultLibrarySelectionFeature: ApplicationCommandFeature {
    private let library: any LibraryFeature
    private nonisolated let chat: any ChatFeature
    private var isSelectingLibrary = false
    private var isOrderlyTerminationPending = false
    private var pendingStart: ChatCommand?

    public init(library: any LibraryFeature, chat: any ChatFeature) {
        self.library = library
        self.chat = chat
    }

    public nonisolated var states: AsyncStream<ChatFeatureState> { chat.states }

    public var currentState: ChatFeatureState {
        get async { await chat.currentState }
    }

    public func currentState(in scope: LibraryScope) async -> ChatFeatureState? {
        await chat.currentState(in: scope)
    }

    public func send(_ command: ChatCommand) async {
        guard !isSelectingLibrary, !isOrderlyTerminationPending else {
            deferStart(command)
            return
        }
        await chat.send(command)
    }

    public func flushForOrderlyTermination() async -> Bool {
        guard !isSelectingLibrary, !isOrderlyTerminationPending else { return false }
        isOrderlyTerminationPending = true
        let succeeded = await chat.flushForOrderlyTermination()
        guard !succeeded else {
            pendingStart = nil
            return true
        }
        await finishFailedOrderlyTermination()
        return false
    }

    @discardableResult
    public func send(_ intent: LibrarySelectionIntent) async -> Bool {
        guard !isSelectingLibrary, !isOrderlyTerminationPending else { return false }
        isSelectingLibrary = true
        guard await chat.flushForOrderlyTermination() else {
            await finishLibrarySelection()
            return false
        }
        await library.send(intent.command)
        await finishLibrarySelection()
        return true
    }

    private func deferStart(_ command: ChatCommand) {
        guard case let .start(context) = command else { return }
        guard case let .start(pendingContext) = pendingStart else {
            pendingStart = command
            return
        }
        if context.generation > pendingContext.generation {
            pendingStart = command
        }
    }

    private func finishLibrarySelection() async {
        while let start = pendingStart {
            pendingStart = nil
            await chat.send(start)
        }
        isSelectingLibrary = false
    }

    private func finishFailedOrderlyTermination() async {
        while let start = pendingStart {
            pendingStart = nil
            await chat.send(start)
        }
        isOrderlyTerminationPending = false
    }
}
