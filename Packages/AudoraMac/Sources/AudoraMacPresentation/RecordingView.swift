import AudoraApplication
import SwiftUI

public struct RecordingView: View {
    @ObservedObject private var model: RecordingPresentationModel

    public init(model: RecordingPresentationModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 12) {
            Divider()
            Text(model.snapshot.title)
                .font(.headline)
            if let detail = model.snapshot.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            switch model.snapshot.status {
            case .idle, .completed, .failed:
                if let explanation = model.snapshot.persistentExplanation {
                    explanationText(explanation)
                }
                Button("Record") { model.send(.record) }
                    .disabled(!model.snapshot.canRecord)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .accessibilityHint("Starts a new Session and microphone Recording.")

            case .selectingLibrary, .starting, .finishing, .sealing:
                recordingReadout
                if let explanation = model.snapshot.persistentExplanation {
                    explanationText(explanation)
                }
                ProgressView()
                    .accessibilityLabel(model.snapshot.title)

            case .active:
                recordingReadout
                HStack {
                    Button(model.snapshot.muteActionLabel) {
                        model.send(.setMuted(model.snapshot.muteTarget))
                    }
                    .disabled(!model.snapshot.canMute)
                    .accessibilityValue(model.snapshot.muteStateValue)

                    Button("Stop") { model.send(.stop) }
                        .disabled(!model.snapshot.canStop)
                        .keyboardShortcut(".", modifiers: [.command])

                    Button("Cancel…", role: .destructive) { model.send(.cancel) }
                        .disabled(!model.snapshot.canCancel)
                }

            case .recoveryRequired:
                recoveryList

            case .resolvingRecovery:
                recoveryList
                    .disabled(true)
                ProgressView()
                    .accessibilityLabel(model.snapshot.title)

            case .unavailable:
                EmptyView()
            }
        }
        .confirmationDialog(
            "Discard incomplete recording?",
            isPresented: Binding(
                get: { model.snapshot.showsDiscardConfirmation },
                set: { presented in
                    if !presented, model.snapshot.showsDiscardConfirmation {
                        model.send(.keepRecording)
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Keep Recording") { model.send(.keepRecording) }
                .keyboardShortcut(.defaultAction)
            Button("Discard Recording", role: .destructive) {
                model.send(.discardRecording)
            }
        } message: {
            Text("Recording is still in progress. Discard removes only this incomplete staging; no Session will be created.")
        }
    }

    private var recordingReadout: some View {
        VStack(spacing: 8) {
            Text(model.snapshot.elapsed)
                .font(.system(.title, design: .monospaced))
                .accessibilityLabel("Elapsed time")
                .accessibilityValue(model.snapshot.elapsed)

            if let value = model.snapshot.levelFraction {
                ProgressView(value: value)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Microphone level")
                    .accessibilityValue(model.snapshot.levelValue)
            } else {
                ProgressView(value: 0)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Microphone level")
                    .accessibilityValue("Unavailable")
            }
            Text("Microphone level: \(model.snapshot.levelValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("Microphone: \(model.snapshot.muteStateValue)")
                .accessibilityLabel("Mute state")
                .accessibilityValue(model.snapshot.muteStateValue)

            if let warning = model.snapshot.warningText {
                Text(warning)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Recording limit warning")
                    .accessibilityValue(warning)
            }
        }
    }

    private var recoveryList: some View {
        VStack(spacing: 10) {
            ForEach(model.snapshot.recoveryItems) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text("Interrupted recording")
                        Text(item.elapsed)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if let status = item.statusText {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if item.canSeal {
                        Button(item.sealActionLabel) {
                            model.send(.sealRecovered(item.recordingID))
                        }
                    }
                    if item.canDiscard {
                        Button("Discard", role: .destructive) {
                            model.send(.discardRecovered(item.recordingID))
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording recovery")
    }

    private func explanationText(_ value: String) -> some View {
        Text(value)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .accessibilityLabel("Recording status")
            .accessibilityValue(value)
    }
}
