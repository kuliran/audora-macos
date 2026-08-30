import AudoraApplication
import AudoraMacInfrastructure
import AudoraMacPresentation
import SwiftUI

@main
struct AudoraApp: App {
    private let feature: DefaultLibraryFeature

    init() {
        feature = DefaultLibraryFeature(
            bootstrapPort: NoSelectedLibraryBootstrapAdapter()
        )
    }

    var body: some Scene {
        Window("Audora", id: "library") {
            LibraryRootView(feature: feature)
        }
        .defaultSize(width: 720, height: 480)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
