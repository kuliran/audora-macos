import AudoraDomain

public protocol LibraryWorkspacePort: Sendable {
    func restoreActiveLibrary() async -> LibraryOpenOutcome
    func createLibrary(_ seed: NewLibrarySeed) async -> LibraryOpenOutcome
    func chooseLibrary() async -> LibraryOpenOutcome
    func openExternalRequest(_ token: LibraryOpenRequestToken) async -> LibraryOpenOutcome
    func reopenRecentLibrary() async -> LibraryOpenOutcome
    func revealActiveLibrary() async -> LibraryActionOutcome
    func closeActiveLibrary() async -> LibraryActionOutcome
}

public protocol LibraryClock: Sendable {
    func now() async -> UTCInstant
}

public protocol LibraryIDGenerator: Sendable {
    func generateLibraryID(at instant: UTCInstant) async -> LibraryID
}

public struct NewLibrarySeed: Equatable, Sendable {
    public let libraryID: LibraryID
    public let createdAt: UTCInstant
    public let preferences: LibraryPreferences
    public let profileHead: ProfileHead

    public init(
        libraryID: LibraryID,
        createdAt: UTCInstant,
        preferences: LibraryPreferences,
        profileHead: ProfileHead
    ) {
        self.libraryID = libraryID
        self.createdAt = createdAt
        self.preferences = preferences
        self.profileHead = profileHead
    }
}

public struct LibraryOpenRequestToken: Hashable, Sendable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard (1...128).contains(rawValue.utf8.count),
              rawValue.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) ||
                      (97...122).contains($0) || $0 == 45 || $0 == 95
              })
        else {
            return nil
        }
        self.rawValue = rawValue
    }
}

public enum LibraryOpenOutcome: Equatable, Sendable {
    case noLibrarySelected(recentAvailable: Bool)
    case opened(ActiveLibrarySnapshot, notice: LibraryNotice? = nil)
    case readOnly(ReadOnlyLibrarySnapshot, reason: LibraryReadOnlyReason, notice: LibraryNotice? = nil)
    case cancelled
    case failed(LibraryNotice)
}

public enum LibraryActionOutcome: Equatable, Sendable {
    case succeeded(recentAvailable: Bool = true)
    case failed(LibraryNotice)
}
