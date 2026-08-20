#if AUDORA_LOCAL_SETUP
import AppKit
import Combine
import Foundation

/// Coordinates local web-to-native handoffs without treating the URL as an
/// authentication credential or starting capture on the user's behalf.
@MainActor
final class LocalConversationDeepLinkCoordinator: ObservableObject {
    static let shared = LocalConversationDeepLinkCoordinator()

    @Published private(set) var meetingToOpen: Meeting?
    @Published private(set) var errorMessage: String?

    private var pendingConversationID: String?
    private var processingConversationID: String?

    private init() {}

    func receive(_ url: URL) {
        bringAppForward()

        guard let deepLink = LocalConversationDeepLink.parse(url) else {
            // The newest external event wins. Do not let an older valid link
            // finish binding after the user/browser has sent a newer invalid
            // request.
            pendingConversationID = nil
            errorMessage = "The local conversation link is invalid."
            return
        }

        errorMessage = nil
        pendingConversationID = deepLink.conversationID
        resumeIfReady()
    }

    /// Called as onboarding and authentication state changes. A deep link can
    /// arrive during launch, so it remains queued until both prerequisites are
    /// ready instead of bypassing either gate.
    func resumeIfReady() {
        guard UserDefaultsManager.shared.hasCompletedOnboarding,
              case .authenticated = ConvexService.shared.authState,
              processingConversationID == nil,
              let conversationID = pendingConversationID else {
            return
        }

        processingConversationID = conversationID
        Task {
            await process(conversationID: conversationID)
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    /// MeetingListView acknowledges a selection request after applying it.
    /// Clearing it makes a later handoff to the same conversation observable.
    func acknowledgeMeetingSelection(_ meetingID: UUID) {
        guard meetingToOpen?.id == meetingID else { return }
        meetingToOpen = nil
    }

    private func process(conversationID: String) async {
        defer {
            processingConversationID = nil
            // If another URL arrived during verification, process that newest
            // request after this one has fully released its subscription.
            resumeIfReady()
        }

        do {
            let reference = try await ConvexService.shared.verifyLocalConversationAccess(
                conversationID: conversationID
            )

            // A newer deep link supersedes an older request still in flight.
            guard pendingConversationID == conversationID else {
                return
            }

            let storedMeetings = LocalStorageManager.shared.loadMeetings()
            let meeting: Meeting
            if let existingMeeting = storedMeetings.first(where: {
                $0.convexConversationId == reference.id
            }) {
                meeting = existingMeeting
            } else {
                guard reference.status != .ended else {
                    throw HandoffError.conversationAlreadyEnded
                }

                let newMeeting = Meeting(
                    title: meetingTitle(from: reference.location),
                    convexConversationId: reference.id
                )
                guard LocalStorageManager.shared.saveMeeting(newMeeting) else {
                    throw HandoffError.localPersistenceFailed
                }
                meeting = newMeeting
                NotificationCenter.default.post(name: .meetingSaved, object: newMeeting)
            }

            pendingConversationID = nil
            meetingToOpen = meeting
            bringAppForward()
        } catch let error as HandoffError {
            guard pendingConversationID == conversationID else { return }
            pendingConversationID = nil
            errorMessage = error.localizedDescription
        } catch {
            guard pendingConversationID == conversationID else { return }
            pendingConversationID = nil
            errorMessage = "The conversation does not exist or is not available to this local user."
        }
    }

    private func meetingTitle(from location: String?) -> String {
        let normalizedLocation = location?
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let normalizedLocation, !normalizedLocation.isEmpty {
            return String(normalizedLocation.prefix(160))
        }

        return "Web conversation - \(Date.now.formatted(date: .abbreviated, time: .shortened))"
    }

    private func bringAppForward() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

private enum HandoffError: LocalizedError {
    case conversationAlreadyEnded
    case localPersistenceFailed

    var errorDescription: String? {
        switch self {
        case .conversationAlreadyEnded:
            return "This conversation has already ended and cannot be attached to a new recording."
        case .localPersistenceFailed:
            return "Audora could not save the local meeting for this conversation."
        }
    }
}
#endif
