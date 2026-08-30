import AudoraDomain

public protocol LibraryBootstrapPort: Sendable {
    func resolveInitialLibrary() async -> LibraryAvailability
}
