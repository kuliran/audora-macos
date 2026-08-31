import AudoraApplication
import Combine
import SwiftUI

public enum SessionProcessingPresentationStatus: Equatable, Sendable {
    case unavailable
    case ready
    case preparing
    case running
    case validating
    case completed
    case failed
    case recoveryRequired
}

public enum SessionProcessingPresentationAction: String, Hashable, Sendable {
    case start
    case prepare
    case reinstall
    case retry

    public var label: String {
        switch self {
        case .start: "Transcribe"
        case .prepare: "Prepare"
        case .reinstall: "Reinstall"
        case .retry: "Retry"
        }
    }
}

public struct SessionProcessingPresentationState: Equatable, Sendable {
    public let status: SessionProcessingPresentationStatus
    public let title: String
    public let detail: String?
    public let actions: [SessionProcessingPresentationAction]

    public init(
        status: SessionProcessingPresentationStatus,
        title: String,
        detail: String?,
        actions: [SessionProcessingPresentationAction]
    ) {
        self.status = status
        self.title = title
        self.detail = detail
        self.actions = actions
    }
}

public enum SessionProcessingPresentationMapper {
    public static func map(
        _ state: SessionProcessingFeatureState
    ) -> SessionProcessingPresentationState {
        switch state {
        case let .unavailable(snapshot):
            let copy = unavailableCopy(snapshot.reason)
            return SessionProcessingPresentationState(
                status: .unavailable,
                title: copy.title,
                detail: copy.detail,
                actions: snapshot.actions.map(action)
            )
        case .ready:
            return SessionProcessingPresentationState(
                status: .ready,
                title: "Ready to transcribe",
                detail: "Audio and offline dependencies are ready.",
                actions: [.start]
            )
        case let .preparing(_, action):
            return SessionProcessingPresentationState(
                status: .preparing,
                title: action == .reinstall
                    ? "Reinstalling offline dependencies…"
                    : "Preparing offline dependencies…",
                detail: "Only the pinned runtime and model are accepted.",
                actions: []
            )
        case .running:
            return SessionProcessingPresentationState(
                status: .running,
                title: "Transcribing offline…",
                detail: "Audio remains on this Mac.",
                actions: []
            )
        case .validating:
            return SessionProcessingPresentationState(
                status: .validating,
                title: "Checking transcript…",
                detail: "The untrusted worker result is being validated before selection.",
                actions: []
            )
        case .completed:
            return SessionProcessingPresentationState(
                status: .completed,
                title: "Transcript ready",
                detail: "The validated revision is selected for this Session.",
                actions: []
            )
        case let .failed(snapshot):
            return SessionProcessingPresentationState(
                status: .failed,
                title: "Offline transcription failed",
                detail: failureText(snapshot.reason),
                actions: snapshot.actions.map(action)
            )
        case .recoveryRequired:
            return SessionProcessingPresentationState(
                status: .recoveryRequired,
                title: "Processing recovery required",
                detail: "An unfinished durable job was preserved. Recovery controls are not yet available.",
                actions: []
            )
        }
    }

    private static func unavailableCopy(
        _ reason: SessionProcessingUnavailableReason
    ) -> (title: String, detail: String?) {
        switch reason {
        case .noSession:
            ("Choose a Session", "Offline transcription needs a selected Session.")
        case .sourceUnavailable:
            ("Session audio is unavailable", "Retry after the sealed audio is available.")
        case .sourceIntegrityMismatch:
            ("Session audio could not be verified", "The audio was not changed.")
        case .acousticEvidenceUnavailable:
            (
                "Speech evidence isn’t qualified",
                "Audora will not infer voiced coverage with an unreviewed detector."
            )
        case let .qualificationBlocked(profileID):
            (
                "Offline transcription isn’t qualified",
                "The pinned profile \(profileID) has not passed qualification. Install an Audora update with qualified offline processing when one is available; Audora cannot repair or substitute this engine in place."
            )
        case .runtimeMissing:
            ("Offline runtime is not prepared", "Prepare the exact pinned runtime, then retry.")
        case .runtimeLockMismatch:
            ("Offline runtime needs reinstall", "The installed runtime does not match its pinned lock.")
        case .modelMissing:
            ("Offline model is not prepared", "Prepare the exact pinned model, then retry.")
        case .modelCorrupt:
            ("Offline model needs reinstall", "The installed model failed integrity verification.")
        case .modelLockMismatch:
            ("Offline model lock does not match", "Reinstall the exact pinned model before retrying.")
        }
    }

    private static func failureText(
        _ reason: SessionProcessingFailureReason
    ) -> String {
        switch reason {
        case .sourceUnavailable:
            "The sealed Session audio became unavailable."
        case .jobPersistenceFailed:
            "The durable processing job could not be verified or updated."
        case .engineUnavailable:
            "The exact offline engine could not be launched."
        case .engineFailed:
            "The offline worker ended without one complete candidate."
        case .candidateRejected:
            "The worker result did not pass transcript validation. Nothing was selected."
        case .publicationFailed:
            "The validated revision could not be published atomically."
        case .installedNeedsRefresh:
            "The revision was installed, but the refreshed selection could not be confirmed."
        }
    }

    private static func action(
        _ action: SessionProcessingRecoveryAction
    ) -> SessionProcessingPresentationAction {
        switch action {
        case .prepare: .prepare
        case .reinstall: .reinstall
        case .retry: .retry
        }
    }
}

@MainActor
public final class SessionProcessingPresentationModel: ObservableObject {
    @Published public private(set) var state: SessionProcessingPresentationState?

    private let feature: any SessionProcessingFeature
    private var hasStarted = false

    public init(feature: any SessionProcessingFeature) {
        self.feature = feature
    }

    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        var states = feature.states.makeAsyncIterator()
        while !Task.isCancelled, let next = await states.next() {
            state = SessionProcessingPresentationMapper.map(next)
        }
    }

    public func perform(_ action: SessionProcessingPresentationAction) {
        let command: SessionProcessingCommand
        switch action {
        case .start: command = .start
        case .prepare: command = .prepare
        case .reinstall: command = .reinstall
        case .retry: command = .retry
        }
        Task { await feature.send(command) }
    }

    public func selectSession(_ selection: SessionProcessingSelection) {
        Task { await feature.send(.selectSession(selection)) }
    }

    public func clearSelection() {
        Task { await feature.send(.clearSelection) }
    }
}

public struct SessionProcessingView: View {
    @ObservedObject private var model: SessionProcessingPresentationModel

    public init(model: SessionProcessingPresentationModel) {
        self.model = model
    }

    public var body: some View {
        GroupBox("Offline Transcript") {
            VStack(alignment: .leading, spacing: 8) {
                if let state = model.state {
                    HStack(spacing: 8) {
                        if state.status == .preparing || state.status == .running ||
                            state.status == .validating
                        {
                            ProgressView().controlSize(.small)
                        }
                        Text(state.title).font(.headline)
                    }
                    if let detail = state.detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if !state.actions.isEmpty {
                        HStack {
                            ForEach(state.actions, id: \.self) { action in
                                Button(action.label) { model.perform(action) }
                            }
                        }
                    }
                } else {
                    ProgressView("Loading processing state…")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
    }
}
