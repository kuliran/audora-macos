import AudoraApplication
import AudoraDomain
import Foundation

public protocol RecordingLibraryRootProviding: Sendable {
    func recordingRoot(for scope: LibraryScope) async -> URL?
}

extension PortableLibraryWorkspace: RecordingLibraryRootProviding {}

public struct SystemRecordingClock: RecordingClock {
    public init() {}

    public func now() async -> UTCInstant {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return try! UTCInstant(formatter.string(from: Date()))
    }
}

public struct RandomRecordingIDGenerator: RecordingIDGenerator {
    private static let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public init() {}

    public func generateRecordingID(at instant: UTCInstant) async -> RecordingID {
        try! RecordingID("rec-\(Self.compact(instant))-\(Self.suffix())")
    }

    public func generateSessionID(at instant: UTCInstant) async -> SessionID {
        try! SessionID("ses-\(Self.compact(instant))-\(Self.suffix())")
    }

    private static func compact(_ instant: UTCInstant) -> String {
        instant.rawValue
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
    }

    private static func suffix() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<4).map { _ in
            crockford.randomElement(using: &generator)!
        })
    }
}
