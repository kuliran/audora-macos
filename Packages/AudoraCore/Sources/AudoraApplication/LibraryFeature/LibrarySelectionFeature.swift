public enum LibrarySelectionIntent: Equatable, Sendable {
    case start
    case create
    case chooseExisting
    case reopenRecent
    case openExternal(LibraryOpenRequestToken)
    case close

    var command: LibraryCommand {
        switch self {
        case .start: .start
        case .create: .create
        case .chooseExisting: .chooseExisting
        case .reopenRecent: .reopenRecent
        case let .openExternal(token): .openExternal(token)
        case .close: .close
        }
    }
}
