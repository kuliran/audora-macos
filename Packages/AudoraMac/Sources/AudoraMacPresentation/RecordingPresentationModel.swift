import AppKit
import AudoraApplication
import AudoraDomain
import Combine

public enum RecordingPresentationStatus: Equatable, Sendable {
    case unavailable
    case selectingLibrary
    case idle
    case starting
    case active
    case finishing
    case sealing
    case recoveryRequired
    case resolvingRecovery
    case completed
    case failed
}

public struct RecordingRecoveryPresentation: Equatable, Sendable, Identifiable {
    public let recordingID: RecordingID
    public let sessionID: SessionID?
    public let elapsed: String
    public let canSeal: Bool
    public let canDiscard: Bool
    public let sealActionLabel: String
    public let statusText: String?

    public var id: String { recordingID.rawValue }
}

public struct RecordingPresentationState: Equatable, Sendable {
    public let status: RecordingPresentationStatus
    public let title: String
    public let detail: String?
    public let elapsed: String
    public let levelValue: String
    public let levelFraction: Double?
    public let muteStateValue: String
    public let muteActionLabel: String
    public let muteTarget: Bool
    public let warningText: String?
    public let persistentExplanation: String?
    public let canRecord: Bool
    public let canMute: Bool
    public let canStop: Bool
    public let canCancel: Bool
    public let showsDiscardConfirmation: Bool
    public let recoveryItems: [RecordingRecoveryPresentation]
    public let announcementKey: String?
    public let announcement: String?
}

public enum RecordingPresentationMapper {
    public static func map(_ state: RecordingFeatureState) -> RecordingPresentationState {
        switch state {
        case let .unavailable(failure):
            return base(
                status: .unavailable,
                title: "Recording unavailable",
                detail: failureText(failure)
            )
        case .selectingLibrary:
            return base(
                status: .selectingLibrary,
                title: "Opening Library…",
                detail: "Checking for an incomplete recording before Record becomes available."
            )
        case .idle:
            return base(status: .idle, title: "Ready to record", canRecord: true)
        case .starting:
            return base(status: .starting, title: "Starting microphone…")
        case let .active(snapshot, confirmation):
            return mapSnapshot(
                snapshot,
                status: .active,
                title: "Recording",
                canMute: confirmation == .none,
                canStop: confirmation == .none,
                canCancel: confirmation == .none,
                confirmation: confirmation == .discardRecording
            )
        case let .finishing(snapshot, reason):
            return mapSnapshot(
                snapshot,
                status: .finishing,
                title: "Finishing recording…",
                terminalReason: reason
            )
        case let .sealing(snapshot, reason):
            return mapSnapshot(
                snapshot,
                status: .sealing,
                title: "Sealing audio…",
                terminalReason: reason
            )
        case let .recoveryRequired(catalog):
            let items = recoveryItems(catalog)
            let cleanupOnly = !catalog.items.isEmpty && catalog.items.allSatisfy {
                $0.availability == .committedCleanup
            }
            let newerOnly = !catalog.items.isEmpty && catalog.items.allSatisfy {
                $0.availability == .readOnlyNewerSchema
            }
            let inspectionBlocked = catalog.inspectionStatus != .complete
            return base(
                status: .recoveryRequired,
                title: "Recording recovery required",
                detail: inspectionBlocked
                    ? "Recording staging could not be inspected safely. Nothing was changed."
                    : cleanupOnly
                    ? "The Session is sealed. Retry exact staging cleanup."
                    : newerOnly
                        ? "This staged recording was created by a newer Audora and is preserved read-only."
                        : "Choose an available recovery action. Capture stays stopped.",
                recoveryItems: items
            )
        case let .resolvingRecovery(catalog, _, action):
            return base(
                status: .resolvingRecovery,
                title: action == .seal
                    ? "Finishing recovered recording…"
                    : "Discarding recovered recording…",
                detail: "The current recovery action is completing safely.",
                recoveryItems: recoveryItems(catalog)
            )
        case let .completed(snapshot, notice):
            let durationNotice = notice == .durationLimit
                ? "Recording stopped at the 45-minute limit. The immutable Session was sealed."
                : nil
            return base(
                status: .completed,
                title: "Session sealed",
                detail: "Audio was flushed and verified before the Session became available.",
                elapsed: elapsed(frames: snapshot.receipt.frameCount),
                persistentExplanation: durationNotice,
                canRecord: true,
                announcementKey: durationNotice == nil
                    ? nil
                    : "duration-\(snapshot.receipt.recordingID.rawValue)",
                announcement: durationNotice
            )
        case let .failed(failure):
            return base(
                status: .failed,
                title: "Recording could not start",
                detail: failureText(failure),
                canRecord: failure != .noWritableLibrary && failure != .libraryBecameReadOnly
            )
        }
    }

    private static func mapSnapshot(
        _ snapshot: RecordingSnapshot,
        status: RecordingPresentationStatus,
        title: String,
        canMute: Bool = false,
        canStop: Bool = false,
        canCancel: Bool = false,
        confirmation: Bool = false,
        terminalReason: CaptureTerminalReason? = nil
    ) -> RecordingPresentationState {
        let level: (String, Double?)
        switch snapshot.level {
        case let .measured(value):
            let bounded = min(1, max(0, value))
            level = ("\(Int((bounded * 100).rounded())) percent", bounded)
        case .unavailable:
            level = ("Unavailable", nil)
        }
        let mute: (state: String, action: String, target: Bool, enabled: Bool)
        switch snapshot.mute {
        case .live:
            mute = ("Live", "Mute microphone", true, canMute)
        case let .changing(toMuted):
            mute = (toMuted ? "Muting" : "Unmuting", toMuted ? "Mute microphone" : "Unmute microphone", toMuted, false)
        case .muted:
            mute = ("Muted", "Unmute microphone", false, canMute)
        }

        var warning: String?
        var announcement: String?
        switch snapshot.limitPhase {
        case .ordinary:
            break
        case .fiveMinuteWarning:
            warning = "5 minutes remaining"
            announcement = warning
        case let .oneMinuteCountdown(seconds):
            warning = "Automatic stop in \(seconds) seconds"
            if seconds == 60 || [30, 10, 5, 4, 3, 2, 1].contains(Int(seconds)) {
                announcement = warning
            }
        case .automaticStop:
            warning = "45-minute limit reached"
            announcement = "Recording stopped at the 45-minute limit"
        }
        let durationExplanation = terminalReason == .durationLimit
            ? "Recording stopped at the 45-minute limit. Your audio is being sealed."
            : nil
        return base(
            status: status,
            title: title,
            elapsed: elapsed(frames: snapshot.elapsedFrames),
            levelValue: level.0,
            levelFraction: level.1,
            muteStateValue: mute.state,
            muteActionLabel: mute.action,
            muteTarget: mute.target,
            warningText: warning,
            persistentExplanation: durationExplanation,
            canMute: mute.enabled,
            canStop: canStop,
            canCancel: canCancel,
            showsDiscardConfirmation: confirmation,
            announcementKey: announcement.map {
                "\(snapshot.recordingID.rawValue)-\(snapshot.noticeID)-\($0)"
            },
            announcement: announcement
        )
    }

    private static func base(
        status: RecordingPresentationStatus,
        title: String,
        detail: String? = nil,
        elapsed: String = "00:00",
        levelValue: String = "Unavailable",
        levelFraction: Double? = nil,
        muteStateValue: String = "Live",
        muteActionLabel: String = "Mute microphone",
        muteTarget: Bool = true,
        warningText: String? = nil,
        persistentExplanation: String? = nil,
        canRecord: Bool = false,
        canMute: Bool = false,
        canStop: Bool = false,
        canCancel: Bool = false,
        showsDiscardConfirmation: Bool = false,
        recoveryItems: [RecordingRecoveryPresentation] = [],
        announcementKey: String? = nil,
        announcement: String? = nil
    ) -> RecordingPresentationState {
        RecordingPresentationState(
            status: status,
            title: title,
            detail: detail,
            elapsed: elapsed,
            levelValue: levelValue,
            levelFraction: levelFraction,
            muteStateValue: muteStateValue,
            muteActionLabel: muteActionLabel,
            muteTarget: muteTarget,
            warningText: warningText,
            persistentExplanation: persistentExplanation,
            canRecord: canRecord,
            canMute: canMute,
            canStop: canStop,
            canCancel: canCancel,
            showsDiscardConfirmation: showsDiscardConfirmation,
            recoveryItems: recoveryItems,
            announcementKey: announcementKey,
            announcement: announcement
        )
    }

    private static func recoveryItems(
        _ catalog: RecordingRecoveryCatalog
    ) -> [RecordingRecoveryPresentation] {
        catalog.items.map {
            let committedCleanup = $0.availability == .committedCleanup
            let readOnly = $0.availability == .readOnlyNewerSchema ||
                $0.availability == .readOnlyUnsupported
            return RecordingRecoveryPresentation(
                recordingID: $0.recordingID,
                sessionID: $0.sessionID,
                elapsed: elapsed(frames: $0.durableFrameCount),
                canSeal: $0.availability == .sealOrDiscard || committedCleanup,
                canDiscard: !committedCleanup && !readOnly,
                sealActionLabel: committedCleanup
                    ? "Retry Cleanup"
                    : "Seal Recovered Recording",
                statusText: $0.availability == .readOnlyNewerSchema
                    ? "Requires a newer Audora"
                    : $0.availability == .readOnlyUnsupported
                        ? "Preserved because this recording cannot be interpreted safely"
                        : nil
            )
        }
    }

    private static func elapsed(frames: UInt64) -> String {
        let seconds = frames / CanonicalRecordingLimits.sampleRate
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%02llu:%02llu:%02llu", hours, minutes, remainder)
        }
        return String(format: "%02llu:%02llu", minutes, remainder)
    }

    private static func failureText(_ failure: RecordingFailure) -> String {
        switch failure {
        case .noWritableLibrary: "Open a writable Library before recording."
        case .anotherLibraryActivity: "Finish the current Library operation first."
        case .microphonePermissionDenied: "Microphone access was not granted."
        case .microphoneUnavailable: "No qualified microphone input is available."
        case .unsupportedInputFormat: "The microphone format changed and staged audio needs recovery."
        case .captureInterruptedRecoverable: "Capture was interrupted; staged audio needs recovery."
        case .captureClockInvalidRecoverable: "The capture timeline became invalid; staged audio needs recovery."
        case .stagingWriteFailedRecoverable: "Staged audio could not be written safely."
        case .sealValidationFailedRecoverable: "The staged recording did not pass seal validation."
        case .sessionDestinationCollision: "That Session identity already exists."
        case .stagingDiscardFailed: "Incomplete staging could not be removed safely."
        case .libraryBecameReadOnly: "The selected Library is not writable."
        case .staleCommand: "That recording command is no longer current."
        }
    }
}

@MainActor
public protocol AccessibilityAnnouncementPosting: AnyObject {
    func post(_ announcement: String)
}

@MainActor
public final class SystemAccessibilityAnnouncementPoster: AccessibilityAnnouncementPosting {
    public init() {}

    public func post(_ announcement: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

@MainActor
public final class RecordingPresentationModel: ObservableObject {
    @Published public private(set) var snapshot: RecordingPresentationState

    private let feature: any RecordingFeature
    private let announcements: any AccessibilityAnnouncementPosting
    private var started = false
    private var lastAnnouncementKey: String?

    public init(
        feature: any RecordingFeature,
        announcements: (any AccessibilityAnnouncementPosting)? = nil
    ) {
        self.feature = feature
        self.announcements = announcements ?? SystemAccessibilityAnnouncementPoster()
        snapshot = RecordingPresentationMapper.map(.unavailable(.noWritableLibrary))
    }

    public func start() async {
        guard !started else { return }
        started = true
        for await state in feature.states {
            guard !Task.isCancelled else { return }
            let mapped = RecordingPresentationMapper.map(state)
            snapshot = mapped
            if let key = mapped.announcementKey,
               key != lastAnnouncementKey,
               let announcement = mapped.announcement
            {
                lastAnnouncementKey = key
                announcements.post(announcement)
            }
        }
    }

    public func selectLibrary(_ selection: RecordingLibrarySelection) {
        Task { await feature.send(.selectLibrary(selection)) }
    }

    public func send(_ command: RecordingCommand) {
        Task { await feature.send(command) }
    }
}
