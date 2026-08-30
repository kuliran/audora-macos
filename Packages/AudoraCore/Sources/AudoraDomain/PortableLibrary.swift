public struct LibraryManifest: Equatable, Sendable {
    public static let formatName = "audora-library"
    public static let schemaVersion: UInt32 = 1

    public let libraryID: LibraryID
    public let createdAt: UTCInstant
    public let lastSuccessfulMigration: UInt64

    public init(
        libraryID: LibraryID,
        createdAt: UTCInstant,
        lastSuccessfulMigration: UInt64 = 1
    ) {
        self.libraryID = libraryID
        self.createdAt = createdAt
        self.lastSuccessfulMigration = lastSuccessfulMigration
    }
}

public enum LibraryLanguage: String, Equatable, Sendable {
    case english = "en"
}

public enum LibraryPreferencesError: Error, Equatable, Sendable {
    case invalidPlaybackRate
}

public struct LibraryPreferences: Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1
    public static let defaults = try! LibraryPreferences(
        language: .english,
        annotationsVisible: true,
        playbackRate: 1.0
    )

    public let language: LibraryLanguage
    public let annotationsVisible: Bool
    public let playbackRate: Double

    public init(
        language: LibraryLanguage,
        annotationsVisible: Bool,
        playbackRate: Double
    ) throws {
        guard playbackRate.isFinite, playbackRate > 0 else {
            throw LibraryPreferencesError.invalidPlaybackRate
        }
        self.language = language
        self.annotationsVisible = annotationsVisible
        self.playbackRate = playbackRate
    }
}

public struct ProfileRevisionPointer: Equatable, Sendable {
    public let revisionID: ProfileRevisionID
    public let sha256: String

    public init(revisionID: ProfileRevisionID, sha256: String) throws {
        guard sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else {
            throw ProfileHeadError.invalidSHA256
        }
        self.revisionID = revisionID
        self.sha256 = sha256
    }
}

public enum ProfileSelection: Equatable, Sendable {
    case null
    case revision(ProfileRevisionPointer)
}

public enum ProfileHeadError: Error, Equatable, Sendable {
    case invalidSHA256
}

public struct ProfileHead: Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1

    public let generation: UInt64
    public let statementGeneration: UInt64
    public let selection: ProfileSelection
    public let updatedAt: UTCInstant

    public init(
        generation: UInt64,
        statementGeneration: UInt64,
        selection: ProfileSelection,
        updatedAt: UTCInstant
    ) {
        self.generation = generation
        self.statementGeneration = statementGeneration
        self.selection = selection
        self.updatedAt = updatedAt
    }
}

public struct ProfileContext: Equatable, Sendable {
    public let statements: [ProfileStatement]

    public init(statements: [ProfileStatement]) {
        self.statements = statements
    }
}

public struct ProfileStatement: Equatable, Sendable {
    public init() {}
}

public enum ProfileProjection {
    public static func context(from head: ProfileHead) -> ProfileContext? {
        switch head.selection {
        case .null:
            ProfileContext(statements: [])
        case .revision:
            nil
        }
    }
}
