import AudoraApplication
import AudoraDomain

public struct NoSelectedLibraryBootstrapAdapter: LibraryBootstrapPort {
    public init() {}

    public func resolveInitialLibrary() async -> LibraryAvailability {
        .noLibrarySelected
    }
}
