// RecordingSessionManager.swift
// Manages recording sessions with backend integration

import Foundation
import SwiftUI
import Combine

enum RecordingLifecycle: Equatable {
    case idle
    case preparing(UUID)
    case recording(UUID)
    case stopping(UUID)

    var meetingId: UUID? {
        switch self {
        case .idle:
            return nil
        case .preparing(let id), .recording(let id), .stopping(let id):
            return id
        }
    }
}

/// Manages recording sessions at the app level, coordinates audio recording with Convex backend
@MainActor
class RecordingSessionManager: ObservableObject {
    static let shared = RecordingSessionManager()

    @Published private(set) var lifecycle: RecordingLifecycle = .idle
    @Published private(set) var isRecording = false
    @Published private(set) var activeMeetingId: UUID?
    @Published var errorMessage: String?
    @Published var activeRecordingTranscriptChunksUpdated: [TranscriptChunk] = []
    @Published private(set) var currentConversationId: String?

    private let audioManager = AudioManager.shared
    private var cancellables = Set<AnyCancellable>()
    private let transcriptUpdateSubject = PassthroughSubject<[TranscriptChunk], Never>()

    // Store transcript chunks for the active recording session
    private var activeRecordingTranscriptChunks: [TranscriptChunk] = []
    private var preparationTask: Task<Void, Never>?
    private var preparationID: UUID?
    private var finalizationTask: Task<Void, Never>?
    private var finalizationID: UUID?

    private init() {
        setupAudioManagerBindings()
        setupDebouncedSaving()
    }

    private func setupAudioManagerBindings() {
        // AudioManager owns capture mechanics; this manager owns the user-visible
        // lifecycle. A capture that dies unexpectedly is finalized through the
        // same path as an explicit stop.
        audioManager.$isRecording
            .dropFirst()
            .sink { [weak self] audioIsRecording in
                guard let self, !audioIsRecording else { return }
                guard case .recording = self.lifecycle else { return }
                self.stopRecording()
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

    @discardableResult
    func startRecording(for meetingId: UUID, title: String? = nil, calendarEventId: String? = nil) -> Bool {
        guard lifecycle == .idle else { return false }

        print("🎙️ Starting recording for meeting: \(meetingId)")

        errorMessage = nil
        setLifecycle(.preparing(meetingId))
        currentConversationId = nil
        let thisPreparationID = UUID()
        preparationID = thisPreparationID

        // Load the meeting to get existing transcript chunks
        if let existingMeeting = LocalStorageManager.shared.loadMeetings().first(where: { $0.id == meetingId }) {
            activeRecordingTranscriptChunks = existingMeeting.transcriptChunks
            audioManager.transcriptChunks = existingMeeting.transcriptChunks
            currentConversationId = existingMeeting.convexConversationId
        }

        preparationTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await self.audioManager.startRecording(
                    onCaptureWillStart: {
                        AudioRecordingManager.shared.startRecording(for: meetingId)
                    }
                )
                try Task.checkCancellation()

                guard self.preparationID == thisPreparationID,
                      self.lifecycle == .preparing(meetingId) else {
                    return
                }

                self.preparationID = nil
                self.preparationTask = nil
                self.setLifecycle(.recording(meetingId))
            } catch {
                self.finishFailedStart(
                    for: meetingId,
                    preparationID: thisPreparationID,
                    error: error
                )
            }
        }

        return true
    }

    func cancelPendingStart(for meetingId: UUID) {
        guard lifecycle == .preparing(meetingId) else { return }

        let taskToCancel = preparationTask
        preparationID = nil
        preparationTask = nil
        taskToCancel?.cancel()
        audioManager.cancelPendingStart()
        AudioRecordingManager.shared.cancelRecording(for: meetingId)
        activeRecordingTranscriptChunks = []
        currentConversationId = nil
        setLifecycle(.idle)
    }

    func stopRecording() {
        if case .preparing(let meetingId) = lifecycle {
            cancelPendingStart(for: meetingId)
            return
        }
        guard case .recording(let meetingId) = lifecycle else { return }
        setLifecycle(.stopping(meetingId))

        let thisFinalizationID = UUID()
        finalizationID = thisFinalizationID
        finalizationTask = Task { [weak self] in
            await self?.stopRecordingAndSave(
                for: meetingId,
                finalizationID: thisFinalizationID
            )
        }
    }

    /// Discards any in-progress take for a meeting. This is used by deletion:
    /// finalizing and then deleting can otherwise let a stale finalizer recreate
    /// the meeting JSON after the user has removed it.
    func cancelActiveRecording(for meetingId: UUID) {
        if case .preparing = lifecycle {
            cancelPendingStart(for: meetingId)
            return
        }

        guard lifecycle == .recording(meetingId)
                || lifecycle == .stopping(meetingId) else { return }

        finalizationID = nil
        let taskToCancel = finalizationTask
        finalizationTask = nil

        // Move to idle before stopping AudioManager so its published false state
        // cannot start a second finalization through the lifecycle binding.
        setLifecycle(.idle)
        taskToCancel?.cancel()
        audioManager.stopRecording()
        AudioRecordingManager.shared.cancelRecording(for: meetingId)
        activeRecordingTranscriptChunks = []
        currentConversationId = nil
    }

    private func stopRecordingAndSave(
        for meetingId: UUID,
        finalizationID expectedFinalizationID: UUID
    ) async {
        print("🛑 Stopping recording for meeting: \(meetingId.uuidString)")

        let capturedMeetingId: UUID? = meetingId
        let capturedConversationId = currentConversationId
        let capturedTitle = titleForBackend(meetingId: capturedMeetingId)
        let capturedCalendarEventId = calendarEventIdForBackend(meetingId: capturedMeetingId)

        let finalizedAudioManagerChunks = await audioManager.stopRecordingAndFinalizeTranscription()

        // A deletion can cancel this generation while the local transcriber is
        // flushing. Never let that stale task render audio or recreate storage.
        guard finalizationID == expectedFinalizationID,
              lifecycle == .stopping(meetingId),
              !Task.isCancelled else { return }

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

        let capturedTranscriptChunks = finalTranscriptChunks

        var audioFileURL: String? = nil
        if let activeMeetingId = capturedMeetingId {
            // Stop recording and get the audio file URL
            if let savedAudioURL = AudioRecordingManager.shared.stopRecordingAndSave(for: activeMeetingId) {
                audioFileURL = savedAudioURL.path
                print("✅ Audio file saved locally")
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

        // Reset state after capturing values for the backend task.
        finalizationID = nil
        finalizationTask = nil
        currentConversationId = nil
        activeRecordingTranscriptChunks = []
        setLifecycle(.idle)
    }

    private func finishFailedStart(
        for meetingId: UUID,
        preparationID failedPreparationID: UUID,
        error: Error
    ) {
        // A cancelled model load can finish after the user has already started
        // another take for the same meeting. Never let that stale task cancel or
        // transition the newer take.
        guard preparationID == failedPreparationID,
              lifecycle == .preparing(meetingId) else { return }

        preparationID = nil
        AudioRecordingManager.shared.cancelRecording(for: meetingId)
        audioManager.cancelPendingStart()
        preparationTask = nil
        activeRecordingTranscriptChunks = []
        currentConversationId = nil
        setLifecycle(.idle)

        if !(error is CancellationError) {
            errorMessage = error.localizedDescription
        }
    }

    private func setLifecycle(_ newLifecycle: RecordingLifecycle) {
        lifecycle = newLifecycle
        activeMeetingId = newLifecycle.meetingId
        switch newLifecycle {
        case .recording, .stopping:
            isRecording = true
        case .idle, .preparing:
            isRecording = false
        }
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

    func isPreparingMeeting(_ meetingId: UUID) -> Bool {
        lifecycle == .preparing(meetingId)
    }

    func isStoppingMeeting(_ meetingId: UUID) -> Bool {
        lifecycle == .stopping(meetingId)
    }

    func isBusy(withOtherMeeting meetingId: UUID) -> Bool {
        guard let activeMeetingId else { return false }
        return activeMeetingId != meetingId
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
                    _ = try await ConvexService.shared.uploadAudioFile(
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
