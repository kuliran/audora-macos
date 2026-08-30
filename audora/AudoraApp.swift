import SwiftUI

@main
struct AudoraApp: App {
    var body: some Scene {
        Window("Audora", id: "library") {
            ContentView()
        }
        .defaultSize(width: 720, height: 480)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
