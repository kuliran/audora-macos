import Foundation

// MARK: - Backward Compatibility
// Type alias for existing code that references Meeting
typealias Meeting = TranscriptionSession

// MARK: - Audio & Transcription Enums

enum AudioSource: String, Codable, CaseIterable, Sendable {
    case mic = "MIC"
    case system = "SYS"

    var displayName: String {
        switch self {
        case .mic:
            return "Me"
        case .system:
            return "Them"
        }
    }

    var copyPrefix: String {
        switch self {
        case .mic:
            return "Me"
        case .system:
            return "Them"
        }
    }

    var icon: String {
        switch self {
        case .mic:
            return "mic.fill"
        case .system:
            return "speaker.wave.2.fill"
        }
    }
}

enum TranscriptionSource: String, Codable {
    case manual = "manual"           // User manually started recording
    case micFollowing = "micFollowing"  // Auto-started from mic following mode
    case autoRecording = "autoRecording" // Auto-started from auto recording mode

    var displayName: String {
        switch self {
        case .manual:
            return "Manual Recording"
        case .micFollowing:
            return "Mic Following"
        case .autoRecording:
            return "Auto Recording"
        }
    }

    var icon: String {
        switch self {
        case .manual:
            return "record.circle"
        case .micFollowing:
            return "waveform.circle"
        case .autoRecording:
            return "bolt.circle"
        }
    }
}

struct WordTiming: Codable, Hashable, Sendable {
    let word: String
    let startTime: Double
    let endTime: Double
    let wordId: String
    let confidence: Double?

    init(
        word: String,
        startTime: Double,
        endTime: Double,
        wordId: String,
        confidence: Double? = nil
    ) {
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
        self.wordId = wordId
        self.confidence = confidence
    }
}

struct TranscriptChunk: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let source: AudioSource
    let text: String
    let isFinal: Bool
    let words: [WordTiming]?
    let startTime: TimeInterval?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: AudioSource,
        text: String,
        isFinal: Bool = false,
        words: [WordTiming]? = nil,
        startTime: TimeInterval? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.text = text
        self.isFinal = isFinal
        self.words = words
        self.startTime = startTime
    }
}

struct CollapsedTranscriptChunk: Identifiable {
    let id: UUID
    let timestamp: Date
    let source: AudioSource
    let combinedText: String
    let startTime: TimeInterval?

    init(
        id: UUID = UUID(),
        timestamp: Date,
        source: AudioSource,
        combinedText: String,
        startTime: TimeInterval? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.combinedText = combinedText
        self.startTime = startTime
    }
}

struct TranscriptionSession: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    var title: String
    var transcriptChunks: [TranscriptChunk]
    var userNotes: String
    var generatedNotes: String
    var templateId: UUID?  // Template used for this session
    var source: TranscriptionSource  // How this session was created
    var analytics: SpeechAnalytics?  // Speech analytics for this session
    var audioFileURL: String?  // Path to the saved audio recording file
    var calendarEventId: String?  // Link to source calendar event (if created from calendar)
    var convexConversationId: String?  // Backend conversation ID for transcript processing
    var localAcousticMetrics: LocalAcousticMetrics?  // Detailed local voice/cadence analysis; no embeddings or contours
    // MARK: - Data versioning
    /// Version of this TranscriptionSession record on disk. Useful for migration.
    var dataVersion: Int
    /// Current app data version. Increment whenever you make a breaking change to `TranscriptionSession` that requires migration.
    static let currentDataVersion = 6  // Incremented for local acoustic metrics

    init(id: UUID = UUID(),
         date: Date = Date(),
         title: String = "",
         transcriptChunks: [TranscriptChunk] = [],
         userNotes: String = "",
         generatedNotes: String = "",
         templateId: UUID? = nil,
         source: TranscriptionSource = .manual,
         analytics: SpeechAnalytics? = nil,
         audioFileURL: String? = nil,
         calendarEventId: String? = nil,
         convexConversationId: String? = nil,
         localAcousticMetrics: LocalAcousticMetrics? = nil,
         dataVersion: Int = TranscriptionSession.currentDataVersion) {
        self.id = id
        self.date = date
        self.title = title
        self.transcriptChunks = transcriptChunks
        self.userNotes = userNotes
        self.generatedNotes = generatedNotes
        self.templateId = templateId
        self.source = source
        self.analytics = analytics
        self.audioFileURL = audioFileURL
        self.calendarEventId = calendarEventId
        self.convexConversationId = convexConversationId
        self.localAcousticMetrics = localAcousticMetrics
        self.dataVersion = dataVersion
    }

    // `Codable` conformance now uses the compiler-synthesised implementation.

    // Computed property for backward compatibility with existing code
    var transcript: String {
        return transcriptChunks
            .filter { $0.isFinal }
            .map { "[\($0.source.rawValue)] \($0.text)" }
            .joined(separator: " ")
    }

    // Formatted transcript for copying with collapsed sequential chunks
    var formattedTranscript: String {
        let finalChunks = transcriptChunks.filter { $0.isFinal }

        guard !finalChunks.isEmpty else { return "" }

        var result: [String] = []
        var currentSource: AudioSource?
        var currentTexts: [String] = []

        for chunk in finalChunks {
            if chunk.source != currentSource {
                // Finish previous section if exists
                if let source = currentSource, !currentTexts.isEmpty {
                    let combinedText = currentTexts.joined(separator: " ")
                    result.append("\(source.copyPrefix): \(combinedText)")
                }

                // Start new section
                currentSource = chunk.source
                currentTexts = [chunk.text]
            } else {
                // Same source, add to current section
                currentTexts.append(chunk.text)
            }
        }

        // Finish last section
        if let source = currentSource, !currentTexts.isEmpty {
            let combinedText = currentTexts.joined(separator: " ")
            result.append("\(source.copyPrefix): \(combinedText)")
        }

        return result.joined(separator: "  \n")
    }

    // Collapsed chunks for UI display
    var collapsedTranscriptChunks: [CollapsedTranscriptChunk] {
        guard !transcriptChunks.isEmpty else { return [] }

        var result: [CollapsedTranscriptChunk] = []
        var currentSource: AudioSource?
        var currentTexts: [String] = []
        var currentTimestamp: Date?
        var currentStartTime: TimeInterval?

        for chunk in transcriptChunks {
            if chunk.source != currentSource {
                // Finish previous section if exists
                if let source = currentSource, !currentTexts.isEmpty, let timestamp = currentTimestamp {
                    let combinedText = currentTexts.joined(separator: " ")
                    result.append(CollapsedTranscriptChunk(
                        timestamp: timestamp,
                        source: source,
                        combinedText: combinedText,
                        startTime: currentStartTime
                    ))
                }

                // Start new section
                currentSource = chunk.source
                currentTexts = [chunk.text]
                currentTimestamp = chunk.timestamp
                currentStartTime = chunk.words?.first?.startTime ?? chunk.startTime
            } else {
                // Same source, add to current section
                currentTexts.append(chunk.text)
            }
        }

        // Finish last section
        if let source = currentSource, !currentTexts.isEmpty, let timestamp = currentTimestamp {
            let combinedText = currentTexts.joined(separator: " ")
            result.append(CollapsedTranscriptChunk(
                timestamp: timestamp,
                source: source,
                combinedText: combinedText,
                startTime: currentStartTime
            ))
        }

        return result
    }

    /// Phrase-sized rows for timestamp seeking. Unlike the copy-oriented
    /// collapsed view, consecutive phrases from the same source stay separate.
    var timestampedTranscriptChunks: [CollapsedTranscriptChunk] {
        transcriptChunks.compactMap { chunk in
            let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return CollapsedTranscriptChunk(
                id: chunk.id,
                timestamp: chunk.timestamp,
                source: chunk.source,
                combinedText: text,
                startTime: chunk.words?.first?.startTime ?? chunk.startTime
            )
        }
    }

    // Separate computed properties for mic and system transcripts
    var micTranscript: String {
        return transcriptChunks
            .filter { $0.source == .mic && $0.isFinal }
            .map { $0.text }
            .joined(separator: " ")
    }

    var systemTranscript: String {
        return transcriptChunks
            .filter { $0.source == .system && $0.isFinal }
            .map { $0.text }
            .joined(separator: " ")
    }
}
