import Foundation
import SwiftUI
import Combine
import PostHog
import AppKit

// Add notification name for meeting saved events
extension Notification.Name {
    static let meetingSaved = Notification.Name("MeetingSaved")
    static let meetingDeleted = Notification.Name("MeetingDeleted")
    static let createNewRecording = Notification.Name("CreateNewRecording")
    static let openSettings = Notification.Name("OpenSettings")
    static let onboardingReset = Notification.Name("OnboardingReset")
    static let meetingsDeleted = Notification.Name("com.audora.notification.meetingsDeleted")
}

@MainActor
class MeetingViewModel: ObservableObject {
    @Published var meeting: Meeting
    @Published var errorMessage: String?
    @Published private var recordingStateChanged = false // Trigger SwiftUI updates
    @Published var isValidatingKey = false // Indicates API key validation in progress
    @Published var isStartingRecording = false // Indicates recording start in progress

    // Computed property to determine if Transcribe button should animate
    var shouldAnimateTranscribeButton: Bool {
        return !isRecording && meeting.transcriptChunks.isEmpty && !isStartingRecording
    }

    // Computed property that always uses the direct RecordingSessionManager check
    var isRecording: Bool {
        return recordingSessionManager.isRecordingMeeting(meeting.id)
    }

    @Published var isDeleted = false

    private let recordingSessionManager = RecordingSessionManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var isNewMeeting = false

    // Computed property to check if meeting is empty
    var isEmpty: Bool {
        return meeting.transcriptChunks.isEmpty &&
               meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(meeting: Meeting = Meeting()) {
        // Load the latest version of the meeting from storage if it exists
        if let savedMeeting = LocalStorageManager.shared.loadMeetings().first(where: { $0.id == meeting.id }) {
            print("🔄 Loading latest version of meeting: \(meeting.id)")
            print("   audioFileURL: \(savedMeeting.audioFileURL ?? "nil")")
            if let audioPath = savedMeeting.audioFileURL {
                let fileExists = FileManager.default.fileExists(atPath: audioPath)
                print("   File exists: \(fileExists)")
            }
            self.meeting = savedMeeting
        } else {
            print("🆕 Using provided meeting: \(meeting.id)")
            self.meeting = meeting
        }



        // Detect if this is a new meeting based on content, not storage existence
        isNewMeeting = isEmpty

        // Trigger SwiftUI updates when recording state changes
        Publishers.CombineLatest(recordingSessionManager.$isRecording, recordingSessionManager.$activeMeetingId)
            .sink { [weak self] (isRecording, activeMeetingId) in
                guard let self = self else { return }

                // If recording started for this meeting, end starting state
                if isRecording && activeMeetingId == self.meeting.id {
                    self.isStartingRecording = false
                }
                // Toggle the dummy property to trigger SwiftUI re-render
                self.recordingStateChanged.toggle()
            }
            .store(in: &cancellables)

        // Update error message when recording session manager encounters errors
        recordingSessionManager.$errorMessage
            .compactMap { $0 }
            .sink { [weak self] errorMessage in
                // Suppress non-critical, self-healing errors that should not distract the user
                let lowercased = errorMessage.lowercased()
                if errorMessage == ErrorMessage.sessionExpired || lowercased.contains("socket is not connected") {
                    print("ℹ️ Suppressed non-critical error: \(errorMessage)")
                    return
                }
                self?.errorMessage = errorMessage
                print("🚨 Recording Session Manager Error: \(errorMessage)")
            }
            .store(in: &cancellables)

        // If currently recording this meeting, load live transcript chunks
        if recordingSessionManager.isRecordingMeeting(meeting.id) {
            self.meeting.transcriptChunks = recordingSessionManager.getTranscriptChunks(for: meeting.id)
        }

        // Listen to real-time transcript updates for this meeting if it's being recorded
        recordingSessionManager.$activeRecordingTranscriptChunksUpdated
            .dropFirst()
            .sink { [weak self] updatedChunks in
                guard let self = self else { return }
                // Only update if this meeting is the active recording
                if recordingSessionManager.isRecordingMeeting(self.meeting.id) {
                    self.meeting.transcriptChunks = updatedChunks
                }
            }
            .store(in: &cancellables)

        // Listen for meeting saved notifications to update local state after recording stops or backend sync completes.
        NotificationCenter.default.publisher(for: .meetingSaved)
            .compactMap { $0.object as? Meeting }
            .filter { [weak self] savedMeeting in
                // Only process if it's for this meeting
                savedMeeting.id == self?.meeting.id
            }
            .sink { [weak self] savedMeeting in
                guard let self = self else { return }

                if savedMeeting.transcriptChunks != self.meeting.transcriptChunks {
                    self.meeting.transcriptChunks = savedMeeting.transcriptChunks
                }

                if savedMeeting.audioFileURL != self.meeting.audioFileURL {
                    print("🔄 Updating audioFileURL in MeetingViewModel")
                    print("   Old: \(self.meeting.audioFileURL ?? "nil")")
                    print("   New: \(savedMeeting.audioFileURL ?? "nil")")

                    if let newPath = savedMeeting.audioFileURL {
                        let fileExists = FileManager.default.fileExists(atPath: newPath)
                        print("   File exists: \(fileExists)")
                    }

                    self.meeting.audioFileURL = savedMeeting.audioFileURL
                }

                if savedMeeting.convexConversationId != self.meeting.convexConversationId {
                    print("🔄 Updating backend conversation ID in MeetingViewModel")
                    self.meeting.convexConversationId = savedMeeting.convexConversationId
                }
            }
            .store(in: &cancellables)

        // Auto-save when meeting properties change
        $meeting
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] meeting in
                print("🔄 Auto-saving meeting: \(meeting.id) - title: '\(meeting.title)', notes: '\(meeting.userNotes.prefix(50))...'")
                self?.saveMeeting()
            }
            .store(in: &cancellables)


    }


    var recordingButtonText: String {
        // Use the same computed isRecording property for perfect consistency
        if isRecording {
            return "Stop"
        } else {
            // Check if there's existing transcript content
            return meeting.transcriptChunks.isEmpty ? "Transcribe" : "Resume"
        }
    }

    func toggleRecording() {
        // Prevent duplicate actions while validating API key or starting recording
        if isValidatingKey || isStartingRecording { return }
        // Use the same computed isRecording property for perfect consistency
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        // Check authentication before starting recording
        guard case .authenticated = ConvexService.shared.authState else {
            errorMessage = "Please sign in to start recording."
            return
        }

        isStartingRecording = true
        recordingSessionManager.startRecording(
            for: meeting.id,
            title: meeting.title.isEmpty ? nil : meeting.title,
            calendarEventId: meeting.calendarEventId
        )
    }

    func stopRecording() {
        saveMeeting()
        recordingSessionManager.stopRecording()
    }

    var conversationURL: URL? {
        guard let conversationId = meeting.convexConversationId else { return nil }
        return URL(string: "https://getaudora.app/dashboard/conversations/\(conversationId)")
    }

    func openConversationInWeb() {
        guard let conversationURL else { return }
        NSWorkspace.shared.open(conversationURL)
    }

    func copyConversationId() {
        guard let conversationId = meeting.convexConversationId else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(conversationId, forType: .string)
    }

    func saveMeeting() {
        if isDeleted { return }
        print("💾 Saving meeting: \(meeting.id)")
        let success = LocalStorageManager.shared.saveMeeting(meeting)
        print("💾 Save result: \(success ? "SUCCESS" : "FAILED")")
        if success {
            NotificationCenter.default.post(name: .meetingSaved, object: meeting)
        }
    }

    func deleteMeeting() {
        // If this meeting is currently being recorded, stop the recording first
        if recordingSessionManager.isRecordingMeeting(meeting.id) {
            print("🛑 Stopping recording for meeting being deleted: \(meeting.id)")
            recordingSessionManager.stopRecording()
        }

        let success = LocalStorageManager.shared.deleteMeeting(meeting)
        if success {
            isDeleted = true
            NotificationCenter.default.post(name: .meetingDeleted, object: meeting)
        }
    }

    func deleteIfEmpty() {
        if isEmpty && !isRecording {
            print("🗑️ Auto-deleting empty meeting")
            deleteMeeting()
        } else {
            saveMeeting()
        }
    }
}
