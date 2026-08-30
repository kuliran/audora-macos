import AudoraApplication
import SwiftUI

public struct LibraryRootView: View {
    @State private var model: LibraryPresentationModel

    public init(feature: any LibraryFeature) {
        _model = State(
            initialValue: LibraryPresentationModel(feature: feature)
        )
    }

    public var body: some View {
        Group {
            switch model.snapshot?.phase {
            case nil, .some(.awaitingBootstrap):
                ProgressView("Preparing Audora…")
                    .controlSize(.large)

            case .some(.noLibrarySelected):
                ContentUnavailableView(
                    "No Library Selected",
                    systemImage: "waveform",
                    description: Text(
                        "Audora has no local speech library to show yet."
                    )
                )
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .task {
            await model.start()
        }
    }
}
