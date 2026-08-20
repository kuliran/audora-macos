#if AUDORA_LOCAL_SETUP
import Darwin
import Foundation
import SwiftUI

enum AudoraLocalLaunchArgument {
    static let prepareModelsAndExit = "--prepare-local-models-and-exit"
}

private final class LocalModelPreparationProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPrintedPercentage = -5

    func report(status: String) {
        lock.lock()
        defer { lock.unlock() }
        print("[models] \(status)")
    }

    func report(progress: Double) {
        guard progress.isFinite else { return }
        let percentage = Int((max(0, min(1, progress)) * 100).rounded(.down))

        lock.lock()
        defer { lock.unlock() }
        guard percentage == 100 || percentage >= lastPrintedPercentage + 5 else { return }
        lastPrintedPercentage = percentage
        print("[models] \(percentage)%")
    }
}

/// A short-lived app mode used only by `scripts/setup-local.mjs`.
///
/// Launching the signed app is important: FluidAudio then resolves and validates
/// its assets in the exact App Sandbox container used by normal recordings.
struct LocalModelPreparationView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Preparing offline transcription")
                .font(.headline)
            Text("Parakeet and voice activity models are being checked on this Mac.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(width: 430, height: 190)
        .task {
            let reporter = LocalModelPreparationProgressReporter()
            do {
                try await LocalTranscriptionModelPreparation.prepare(
                    onStatus: { reporter.report(status: $0) },
                    onProgress: { reporter.report(progress: $0) }
                )
                reporter.report(status: "Preparation completed successfully.")
                fflush(nil)
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                reporter.report(status: "Preparation failed: \(error.localizedDescription)")
                fflush(nil)
                Darwin.exit(EXIT_FAILURE)
            }
        }
    }
}
#endif
