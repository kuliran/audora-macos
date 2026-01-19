import Foundation
import SwiftUI
import Combine

/// Manages recording sessions at the app level to persist across navigation
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
        
        // Load the meeting to get existing transcript chunks
        if let existingMeeting = LocalStorageManager.shared.loadMeetings().first(where: { $0.id == meetingId }) {
            activeRecordingTranscriptChunks = existingMeeting.transcriptChunks
            // Seed the audio manager with existing chunks
            audioManager.transcriptChunks = existingMeeting.transcriptChunks
        }
        
        // Start audio recording immediately (don't block UX)
        AudioRecordingManager.shared.startRecording(for: meetingId)
        audioManager.startRecording()
        
        // Create backend conversation in background
        Task {
            do {
                let convexId = try await ConvexService.shared.createConversation(
                    title: title,
                    calendarEventId: calendarEventId
                )
                await MainActor.run {
                    self.currentConversationId = convexId
                    // ⚠️ CRITICAL: Save conversation ID to meeting record immediately
                    self.saveMeetingConversationId(meetingId: meetingId, conversationId: convexId)
                }
            } catch {
                print("❌ Failed to create conversation: \(error)")
                // Continue anyway - will save locally
            }
        }
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        print("🛑 Stopping recording for meeting: \(activeMeetingId?.uuidString ?? "unknown")")
        
        isRecording = false
        audioManager.stopRecording()
        
        // Save audio file and update meeting
        var audioFileURL: String? = nil
        if let activeMeetingId = activeMeetingId {
            // Stop recording and get the audio file URL
            if let savedAudioURL = AudioRecordingManager.shared.stopRecordingAndSave(for: activeMeetingId) {
                audioFileURL = savedAudioURL.path
                print("✅ Audio file saved: \(savedAudioURL.path)")
            }
            
            // Update meeting with transcript and audio file URL
            updateActiveMeeting(meetingId: activeMeetingId, chunks: activeRecordingTranscriptChunks, audioFileURL: audioFileURL)
            
            // Process with backend if we have a conversation ID
            Task {
                // ⚠️ TIMING FIX: Wait briefly for conversation ID if still being created
                if currentConversationId == nil {
                    print("⏳ Waiting for conversation creation...")
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s max wait
                }
                
                if let conversationId = currentConversationId {
                    // Load meeting with latest transcript
                    if let meeting = LocalStorageManager.shared.loadMeetings().first(where: { $0.id == activeMeetingId }) {
                        await processTranscriptWithBackend(
                            conversationId: conversationId,
                            meeting: meeting
                        )
                    }
                } else {
                    print("⚠️ No conversation ID available - skipping backend processing")
                }
            }
        }
        
        activeMeetingId = nil
        currentConversationId = nil
        activeRecordingTranscriptChunks = []
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
    
    // MARK: - Backend Processing
    
    /// Processes transcript with backend after recording completes
    private func processTranscriptWithBackend(
        conversationId: String,
        meeting: Meeting
    ) async {
        do {
            // Format transcript turns for backend
            // ⚠️ CRITICAL: Convert Date to Unix timestamp (milliseconds) - backend expects numbers
            let transcriptTurns: [[String: Any]] = meeting.transcriptChunks.map { chunk in
                let unixTimeMs = chunk.timestamp.timeIntervalSince1970 * 1000
                return [
                    "speaker": chunk.source == .mic ? "S1" : "S2",
                    "text": chunk.text,
                    "startTime": unixTimeMs,  // Unix timestamp in milliseconds
                    "endTime": unixTimeMs      // Same as start (TranscriptChunk has no duration field)
                ]
            }
            
            guard !transcriptTurns.isEmpty else {
                print("⚠️ No transcript to process")
                return
            }
            
            // Get user name from settings
            let userName = UserDefaultsManager.shared.userBlurb.isEmpty 
                ? "Me" 
                : UserDefaultsManager.shared.userBlurb
            
            print("📤 Processing transcript with backend...")
            let result = try await ConvexService.shared.processRealtimeTranscript(
                conversationId: conversationId,
                transcriptTurns: transcriptTurns,
                initiatorName: userName
            )
            
            print("✅ Backend processing complete")
            print("   - Transcript saved to database")
            print("   - Facts extracted with GPT-4")
            print("   - Knowledge graph updated")
            
            // Optionally parse and display facts
            if let s1Facts = result["S1_facts"] as? [String] {
                print("   - Extracted \(s1Facts.count) facts")
            }
            
        } catch {
            print("❌ Backend processing failed: \(error)")
            print("   - Meeting still saved locally")
        }
    }
    
    /// Helper method to save conversation ID to meeting record
    private func saveMeetingConversationId(meetingId: UUID, conversationId: String) {
        var meetings = LocalStorageManager.shared.loadMeetings()
        if let index = meetings.firstIndex(where: { $0.id == meetingId }) {
            meetings[index].convexConversationId = conversationId
            let success = LocalStorageManager.shared.saveMeeting(meetings[index])
            if success {
                print("✅ Saved conversation ID to meeting: \(meetingId)")
            } else {
                print("❌ Failed to save conversation ID to meeting: \(meetingId)")
            }
        }
    }
} 