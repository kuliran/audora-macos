import SwiftUI

struct HarnessView: View {
  @ObservedObject var model: HarnessViewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text("Release execution gate")
          .font(.largeTitle.weight(.semibold))
        Text(
          "This small harness proves Audora’s macOS execution assumptions in the signed Release profile. It owns exactly one writer window."
        )
        .foregroundStyle(.secondary)

        GroupBox("1. User-chosen Library") {
          VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Selected", value: model.libraryName)
            Text(model.libraryStatus)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
            HStack {
              Button("Choose & Mutate Library") {
                model.chooseAndMutateLibrary()
              }
              Button("Mutate Again") {
                try? model.mutateSelectedLibrary()
              }
            }
            .disabled(model.isRunning)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 4)
        }

        GroupBox("2. Microphone permission") {
          VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Status", value: model.microphoneStatus)
            Button("Request Microphone Permission") {
              model.requestMicrophonePermission()
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 4)
        }

        GroupBox("3. Child process and atomic interruption") {
          VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Status", value: model.automatedStatus)
            Button("Run Automated Qualification") {
              model.runAutomatedQualification()
            }
            .disabled(model.isRunning)

            ForEach(model.automatedDetails, id: \.self) { detail in
              Label(detail, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 4)
        }

        Text(
          "Close and reopen the app—or choose Window › Focus Writer Window—to verify every open request returns to this same writer."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      .padding(28)
    }
    .frame(minWidth: 680, minHeight: 560)
  }
}
