public enum LibraryCommand: Equatable, Sendable {
    case start
    case create
    case chooseExisting
    case reopenRecent
    case openExternal(LibraryOpenRequestToken)
    case reveal
    case close
    case rejectMultipleExternalOpenRequests
}
