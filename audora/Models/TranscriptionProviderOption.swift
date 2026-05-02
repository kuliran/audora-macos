import Foundation

enum TranscriptionProviderOption: String, Codable, CaseIterable, Identifiable {
    case speechmatics
    case parakeet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speechmatics:
            return "Speechmatics"
        case .parakeet:
            return "Local Parakeet"
        }
    }

    var detailText: String {
        switch self {
        case .speechmatics:
            return "Cloud transcription through Speechmatics."
        case .parakeet:
            return "Local transcription on this Mac after a one-time model download."
        }
    }
}
