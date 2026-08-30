public struct AudioImportFeatureState: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case idle
        case selecting
        case copying
        case inspecting
        case normalizing
        case installing
        case succeeded(ReopenedImportedSessionSnapshot)
        case failed(AudioImportFailure)
    }

    public let status: Status

    public init(status: Status) {
        self.status = status
    }

    public var isImporting: Bool {
        switch status {
        case .selecting, .copying, .inspecting, .normalizing, .installing:
            true
        case .idle, .succeeded, .failed:
            false
        }
    }
}
