// RecordingSessionManager.swift
// Manages recording sessions with backend integration

import Foundation
import SwiftUI
import Combine

/// Manages recording sessions at the app level, coordinates audio recording with Convex backend
@MainActor
class RecordingSessionManager: ObservableObject {
    static let shared = RecordingSessionManager()

    @Published var isRecording = false
    @Published var activeMeetingId: UUID?
    @Published var errorMessage: String?
    @Published var activeRecordingTranscriptChunksUpdated: [TranscriptChunk] = []
    @Published var currentConversationId: String?

    private let audioManager = AudioManager.shared
    private var cancellables = Set<AnyCancellable>()
    private let transcriptUpdateSubject = PassthroughSubject<[TranscriptChunk], Never>()

    // Store transcript chunks for the active recording session
    private var activeRecordingTranscriptChunks: [TranscriptChunk] = []
    private var isStoppingRecording = false

    private init() {
        setupAudioManagerBindings()
        setupDebouncedSaving()
    }

    private func setupAudioManagerBindings() {
        // Bind to audio manager state
        audioManager.$isRecording
            .sink { [weak self] isRecording in
                self?.isRecording = isRecording
            }
            .store(in: &cancellables)

        audioManager.$errorMessage
            .sink { [weak self] errorMessage in
                self?.errorMessage = errorMessage
            }
            .store(in: &cancellables)

        // When transcript chunks change, store them for the active recording and send to debouncer
        audioManager.$transcriptChunks
            .sink { [weak self] newChunks in
                guard let self = self, self.isRecording, self.activeMeetingId != nil else { return }
                self.activeRecordingTranscriptChunks = newChunks
                self.activeRecordingTranscriptChunksUpdated = newChunks

                self.transcriptUpdateSubject.send(newChunks)

            }
            .store(in: &cancellables)
    }

    private func setupDebouncedSaving() {
        transcriptUpdateSubject
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] chunks in
                guard let self = self, let activeMeetingId = self.activeMeetingId else { return }
                print("💾 Debounced save triggered for meeting: \(activeMeetingId.uuidString)")
                self.updateActiveMeetingTranscript(meetingId: activeMeetingId, chunks: chunks)
            }
            .store(in: &cancellables)
    }

    func startRecording(for meetingId: UUID, title: String? = nil, calendarEventId: String? = nil) {
        guard !isRecording else { return }

        print("🎙️ Starting recording for meeting: \(meetingId)")

        isRecording = true
        activeMeetingId = meetingId
        currentConversationId = nil

        // Load the meeting to get existing transcript chunks
        if let existingMeeting = LocalStorageManager.shared.loadMeetings().first(where: { $0.id == meetingId }) {
            activeRecordingTranscriptChunks = existingMeeting.transcriptChunks
            audioManager.transcriptChunks = existingMeeting.transcriptChunks
            currentConversationId = existingMeeting.convexConversationId
        }

        AudioRecordingManager.shared.startRecording(for: meetingId)
        audioManager.startRecording()
    }

    func stopRecording() {
        guard isRecording, !isStoppingRecording else { return }

        isStoppingRecording = true

        Task {
            await stopRecordingAndSave()
        }
    }

    private func stopRecordingAndSave() async {
        defer {
            isStoppingRecording = false
        }

        print("🛑 Stopping recording for meeting: \(activeMeetingId?.uuidString ?? "unknown")")

        let capturedMeetingId = activeMeetingId
        let capturedConversationId = currentConversationId
        let capturedTitle = titleForBackend(meetingId: capturedMeetingId)
        let capturedCalendarEventId = calendarEventIdForBackend(meetingId: capturedMeetingId)

        let finalizedAudioManagerChunks = await audioManager.stopRecordingAndFinalizeTranscription()
        let transcriptSnapshot = finalizedAudioManagerChunks.isEmpty
            ? activeRecordingTranscriptChunks
            : finalizedAudioManagerChunks
        let finalTranscriptChunks = finalizedTranscriptChunks(transcriptSnapshot)
        if finalTranscriptChunks != activeRecordingTranscriptChunks {
            activeRecordingTranscriptChunks = finalTranscriptChunks
            activeRecordingTranscriptChunksUpdated = finalTranscriptChunks
            audioManager.transcriptChunks = finalTranscriptChunks
            transcriptUpdateSubject.send(finalTranscriptChunks)
        }

        isRecording = false
        let capturedTranscriptChunks = finalTranscriptChunks

        var audioFileURL: String? = nil
        if let activeMeetingId = capturedMeetingId {
            // Stop recording and get the audio file URL
            if let savedAudioURL = AudioRecordingManager.shared.stopRecordingAndSave(for: activeMeetingId) {
                audioFileURL = savedAudioURL.path
                print("✅ Audio file saved: \(savedAudioURL.path)")
            }

            updateActiveMeeting(meetingId: activeMeetingId, chunks: capturedTranscriptChunks, audioFileURL: audioFileURL)

            Task {
                await saveFinishedRecordingToBackend(
                    meetingId: activeMeetingId,
                    existingConversationId: capturedConversationId,
                    title: capturedTitle,
                    calendarEventId: capturedCalendarEventId,
                    chunks: capturedTranscriptChunks,
                    audioFileURL: audioFileURL
                )
            }
        }

        // Reset state after capturing values for the Task
        activeMeetingId = nil
        currentConversationId = nil
        activeRecordingTranscriptChunks = []
    }

    private func finalizedTranscriptChunks(_ chunks: [TranscriptChunk]) -> [TranscriptChunk] {
        chunks.compactMap { chunk in
            guard !chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            guard !chunk.isFinal else {
                return chunk
            }

            return TranscriptChunk(
                id: chunk.id,
                timestamp: chunk.timestamp,
                source: chunk.source,
                text: chunk.text,
                isFinal: true,
                words: chunk.words
            )
        }
    }

    func isRecordingMeeting(_ meetingId: UUID) -> Bool {
        return isRecording && activeMeetingId == meetingId
    }

    private func updateActiveMeetingTranscript(meetingId: UUID, chunks: [TranscriptChunk]) {
        updateActiveMeeting(meetingId: meetingId, chunks: chunks, audioFileURL: nil)
    }

    private func updateActiveMeeting(meetingId: UUID, chunks: [TranscriptChunk], audioFileURL: String?) {
        // Load all meetings
        var meetings = LocalStorageManager.shared.loadMeetings()

        // Find and update the active meeting
        if let index = meetings.firstIndex(where: { $0.id == meetingId }) {
            meetings[index].transcriptChunks = chunks
            if let audioFileURL = audioFileURL {
                meetings[index].audioFileURL = audioFileURL
            }

            // Save the updated meeting
            let success = LocalStorageManager.shared.saveMeeting(meetings[index])
            if success {
                print("✅ Saved meeting: \(meetingId.uuidString)")
                NotificationCenter.default.post(name: .meetingSaved, object: meetings[index])
            } else {
                print("❌ Failed to save meeting: \(meetingId.uuidString)")
            }
        }
    }

    func getActiveRecordingTranscriptChunks() -> [TranscriptChunk] {
        return activeRecordingTranscriptChunks
    }

    /// Get transcript chunks for a specific meeting, ensuring proper data separation
    func getTranscriptChunks(for meetingId: UUID) -> [TranscriptChunk] {
        if isRecording && activeMeetingId == meetingId {
            // Return live transcript chunks for the active recording
            return activeRecordingTranscriptChunks
        } else {
            // Load saved transcript chunks from storage for non-active meetings
            if let savedMeeting = LocalStorageManager.shared.loadMeetings().first(where: { $0.id == meetingId }) {
                return savedMeeting.transcriptChunks
            }
            return []
        }
    }

    // MARK: - Backend Sync

    private func saveFinishedRecordingToBackend(
        meetingId: UUID,
        existingConversationId: String?,
        title: String?,
        calendarEventId: String?,
        chunks: [TranscriptChunk],
        audioFileURL: String?
    ) async {
        do {
            let transcriptTurns = backendTranscriptTurns(from: chunks)

            guard !transcriptTurns.isEmpty else {
                print("⚠️ No transcript to sync")
                return
            }

            let conversationId: String
            if let existingConversationId {
                conversationId = existingConversationId
            } else {
                conversationId = try await ConvexService.shared.createConversation(
                    title: title,
                    calendarEventId: calendarEventId
                )
                await MainActor.run {
                    self.saveMeetingConversationId(meetingId: meetingId, conversationId: conversationId)
                }
            }

            if let audioFileURL {
                do {
                    try await ConvexService.shared.uploadAudioFile(
                        audioFileURL: URL(fileURLWithPath: audioFileURL),
                        conversationId: conversationId
                    )
                } catch {
                    print("❌ Backend audio upload failed: \(error)")
                }
            } else {
                print("⚠️ No audio file available to upload")
            }

            print("📤 Saving transcript to backend conversation...")
            try await ConvexService.shared.saveTranscriptData(
                conversationId: conversationId,
                transcriptTurns: transcriptTurns,
                summary: backendSummary(title: title, turnCount: transcriptTurns.count)
            )

            print("✅ Backend conversation saved: \(conversationId)")
        } catch {
            print("❌ Backend transcript sync failed: \(error)")
        }
    }

    private func backendTranscriptTurns(from chunks: [TranscriptChunk]) -> [[String: Any]] {
        let finalChunks = chunks.filter(\.isFinal)
        let recordingStartTime = finalChunks.first?.timestamp ?? chunks.first?.timestamp ?? Date()

        return finalChunks.enumerated().compactMap { _, chunk in
            let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let fallbackStartTime = max(0, chunk.timestamp.timeIntervalSince(recordingStartTime))
            let words = chunk.words?.map { word in
                [
                    "word": word.word,
                    "startTime": word.startTime,
                    "endTime": word.endTime,
                    "wordId": word.wordId
                ] as [String: Any]
            }

            var turn: [String: Any] = [
                "speaker": chunk.source == .mic ? "S1" : "S2",
                "text": text,
                "startTime": fallbackStartTime
            ]

            if let words, !words.isEmpty {
                turn["words"] = words
            }

            return turn
        }
    }

    private func backendSummary(title: String?, turnCount: Int) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        return "Mac recording with \(turnCount) transcript turns"
    }

    private func titleForBackend(meetingId: UUID?) -> String? {
        guard let meetingId,
              let meeting = LocalStorageManager.shared.loadMeetings().first(where: { $0.id == meetingId }) else {
            return nil
        }

        let trimmedTitle = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? nil : trimmedTitle
    }

    private func calendarEventIdForBackend(meetingId: UUID?) -> String? {
        guard let meetingId,
              let meeting = LocalStorageManager.shared.loadMeetings().first(where: { $0.id == meetingId }) else {
            return nil
        }

        return meeting.calendarEventId
    }

    /// Helper method to save conversation ID to meeting record
    private func saveMeetingConversationId(meetingId: UUID, conversationId: String) {
        var meetings = LocalStorageManager.shared.loadMeetings()
        if let index = meetings.firstIndex(where: { $0.id == meetingId }) {
            meetings[index].convexConversationId = conversationId
            let success = LocalStorageManager.shared.saveMeeting(meetings[index])
            if success {
                print("✅ Saved conversation ID to meeting: \(meetingId)")
                NotificationCenter.default.post(name: .meetingSaved, object: meetings[index])
            } else {
                print("❌ Failed to save conversation ID to meeting: \(meetingId)")
            }
        }
    }
}
