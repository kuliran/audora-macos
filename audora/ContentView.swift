import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.tint)

            Text("Audora")
                .font(.largeTitle.weight(.semibold))

            Text("Your local, native speech library is taking shape.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(48)
        .frame(minWidth: 560, minHeight: 360)
    }
}
