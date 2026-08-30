import AudoraDomain

public struct ActiveLibrarySnapshot: Equatable, Sendable {
    public enum ProfileSummary: Equatable, Sendable {
        case nullProfile(statementCount: UInt64)
        case selected(revisionID: ProfileRevisionID, statementGeneration: UInt64)
    }

    public let libraryID: LibraryID
    public let preferences: LibraryPreferences
    public let profile: ProfileSummary

    public init(
        libraryID: LibraryID,
        preferences: LibraryPreferences,
        profile: ProfileSummary
    ) {
        self.libraryID = libraryID
        self.preferences = preferences
        self.profile = profile
    }
}

public struct ReadOnlyLibrarySnapshot: Equatable, Sendable {
    public let libraryID: LibraryID?

    public init(libraryID: LibraryID?) {
        self.libraryID = libraryID
    }
}

public enum LibraryReadOnlyReason: String, Equatable, Sendable {
    case newerSchema
}

public enum LibraryNotice: String, Equatable, Sendable {
    case candidateCorrupt
    case candidateUnavailable
    case identityMismatch
    case unsupportedOlderSchema
    case selectionRequired
    case createDestinationExists
    case createFailed
    case locatorUpdateFailed
    case revealFailed
    case closeFailed
    case recordingInProgress
    case multipleExternalOpenRequests
    case externalOpenRequestExpired
}

public struct LibraryFeatureState: Equatable, Sendable {
    public enum Selection: Equatable, Sendable {
        case awaitingBootstrap
        case noLibrarySelected(recentAvailable: Bool)
        case active(ActiveLibrarySnapshot)
        case readOnly(ReadOnlyLibrarySnapshot, reason: LibraryReadOnlyReason)
    }

    public enum Activity: String, Equatable, Sendable {
        case restoring
        case creating
        case opening
        case revealing
        case closing
    }

    public let selection: Selection
    public let activity: Activity?
    public let notice: LibraryNotice?

    public init(
        selection: Selection,
        activity: Activity? = nil,
        notice: LibraryNotice? = nil
    ) {
        self.selection = selection
        self.activity = activity
        self.notice = notice
    }
}
