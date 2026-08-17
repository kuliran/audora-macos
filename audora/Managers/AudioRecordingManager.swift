// AudioRecordingManager.swift
// Handles saving audio recordings to disk

import AVFoundation
import Combine
import Foundation

/// Manages audio file recording and saving.
///
/// Microphone and system audio are captured to independent lossless files. When a
/// take ends, both files are rendered onto one shared timeline and mixed into the
/// meeting's speech-optimized WAV. Keeping the raw files separate until the final
/// file has been atomically installed prevents a failed export from destroying the
/// only copy.
final class AudioRecordingManager: ObservableObject {
    static let shared = AudioRecordingManager()

    private struct RecordedSegment {
        let micURL: URL?
        let micOffset: TimeInterval
        let systemURL: URL?
        let systemOffset: TimeInterval

        var sourceURLs: [URL] {
            [micURL, systemURL].compactMap { $0 }
        }
    }

    private struct TimelineSource {
        let url: URL
        let offset: TimeInterval
        let gain: Float
    }

    private enum RecordingError: LocalizedError {
        case renderStalled
        case renderFailed
        case operationFailed(String, Error)

        var errorDescription: String? {
            switch self {
            case .renderStalled:
                return "The audio renderer stopped making progress."
            case .renderFailed:
                return "The audio renderer failed."
            case let .operationFailed(operation, error):
                let cocoaError = error as NSError
                var details = "[\(cocoaError.domain) \(cocoaError.code)]"
                if let underlying = cocoaError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    details += " [\(underlying.domain) \(underlying.code)]"
                }
                return "\(operation) failed: \(error.localizedDescription) \(details)"
            }
        }
    }

    private let stateLock = NSLock()
    private var currentMeetingID: UUID?
    private var recordingStartedAt: TimeInterval?
    private var micAudioFile: AVAudioFile?
    private var systemAudioFile: AVAudioFile?
    private var micFileURL: URL?
    private var systemFileURL: URL?
    private var micFormat: AVAudioFormat?
    private var systemFormat: AVAudioFormat?
    private var micStartOffset: TimeInterval?
    private var systemStartOffset: TimeInterval?

    // Segments remain here after a failed render so the next finalization can
    // retry them instead of silently losing either source.
    private var pendingSegments: [UUID: [RecordedSegment]] = [:]
    private var micWriteCount = 0
    private var systemWriteCount = 0

    private let recordingsDirectory: URL

    private init() {
        let documentsDirectory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        recordingsDirectory = documentsDirectory.appendingPathComponent("Recordings")

        do {
            try FileManager.default.createDirectory(
                at: recordingsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            print("Failed to create recordings directory: \(error.localizedDescription)")
        }
    }

    /// Gets the folder URL for a specific meeting's audio files.
    private func getMeetingFolder(for meetingId: UUID) -> URL {
        recordingsDirectory.appendingPathComponent(meetingId.uuidString)
    }

    /// Starts recording audio for a meeting.
    @discardableResult
    @MainActor
    func startRecording(for meetingId: UUID) -> Bool {
        let meetingFolder = getMeetingFolder(for: meetingId)

        do {
            try FileManager.default.createDirectory(
                at: meetingFolder,
                withIntermediateDirectories: true
            )
        } catch {
            print("Failed to create meeting audio folder: \(error.localizedDescription)")
            return false
        }

        removeDerivedTemporaryFiles(in: meetingFolder)

        let segmentID = UUID().uuidString
        let newMicURL = meetingFolder.appendingPathComponent("mic_\(segmentID).caf")
        let newSystemURL = meetingFolder.appendingPathComponent("system_\(segmentID).caf")

        stateLock.lock()
        let abandonedURLs = activeSourceURLsLocked()
        resetActiveSegmentLocked()

        currentMeetingID = meetingId
        recordingStartedAt = ProcessInfo.processInfo.systemUptime
        micFileURL = newMicURL
        systemFileURL = newSystemURL
        micWriteCount = 0
        systemWriteCount = 0
        stateLock.unlock()

        // A second start should never occur, but if it does, do not leave the
        // previous partial take orphaned on disk.
        removeFiles(at: abandonedURLs)
        print("Started local audio recording")
        return true
    }

    /// Records a microphone audio buffer.
    func recordMicBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard currentMeetingID != nil else { return }

        if micAudioFile == nil, let fileURL = micFileURL {
            do {
                micAudioFile = try makeLosslessFile(at: fileURL, format: format)
                micFormat = format
                micStartOffset = startOffsetLocked(for: buffer, format: format)
            } catch {
                print("Failed to create microphone audio file: \(error.localizedDescription)")
            }
        }

        guard let file = micAudioFile else { return }

        do {
            try file.write(from: buffer)
            micWriteCount += 1
        } catch {
            print("Failed to write microphone audio: \(error.localizedDescription)")
        }
    }

    /// Records a system audio buffer.
    func recordSystemBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard currentMeetingID != nil else { return }

        if systemAudioFile == nil, let fileURL = systemFileURL {
            do {
                systemAudioFile = try makeLosslessFile(at: fileURL, format: format)
                systemFormat = format
                systemStartOffset = startOffsetLocked(for: buffer, format: format)
            } catch {
                print("Failed to create system audio file: \(error.localizedDescription)")
            }
        }

        guard let file = systemAudioFile else { return }

        do {
            try file.write(from: buffer)
            systemWriteCount += 1
        } catch {
            print("Failed to write system audio: \(error.localizedDescription)")
        }
    }

    /// Stops recording and saves a time-aligned mix of all available sources.
    @MainActor
    func stopRecordingAndSave(for meetingId: UUID) -> URL? {
        stateLock.lock()

        guard currentMeetingID == meetingId else {
            stateLock.unlock()
            print("Ignored audio finalization for a meeting that is not active")
            return existingRecordingURL(for: meetingId)
        }

        // Releasing AVAudioFile closes each raw file before it is opened by the
        // offline renderer.
        micAudioFile = nil
        systemAudioFile = nil

        let segment = makeCurrentSegmentLocked()
        if !segment.sourceURLs.isEmpty {
            pendingSegments[meetingId, default: []].append(segment)
        }
        let segmentsToRender = pendingSegments[meetingId] ?? []
        resetActiveSegmentLocked()
        stateLock.unlock()

        let outputURL = getMeetingFolder(for: meetingId)
            .appendingPathComponent("recording.wav")
        let priorRecordingURL = existingRecordingURL(for: meetingId)

        guard !segmentsToRender.isEmpty else {
            removeMeetingFolderIfEmpty(for: meetingId)
            return priorRecordingURL
        }

        do {
            let timeline = try makeTimeline(
                existingRecordingURL: priorRecordingURL,
                segments: segmentsToRender
            )
            let temporaryURL = outputURL.deletingLastPathComponent()
                .appendingPathComponent("recording-\(UUID().uuidString).tmp.wav")

            defer {
                try? FileManager.default.removeItem(at: temporaryURL)
            }

            try renderMix(timeline, to: temporaryURL)
            try installRenderedFile(from: temporaryURL, at: outputURL)

            if let priorRecordingURL, priorRecordingURL != outputURL {
                try? FileManager.default.removeItem(at: priorRecordingURL)
            }

            let rawURLs = segmentsToRender.flatMap(\.sourceURLs)
            removeFiles(at: rawURLs)

            stateLock.lock()
            pendingSegments[meetingId] = nil
            stateLock.unlock()

            print("Saved mixed microphone and system audio")
            return outputURL
        } catch {
            // The raw CAF files are intentionally retained for a later retry.
            print("Failed to finalize audio; raw sources were retained: \(error.localizedDescription)")
            return priorRecordingURL
        }
    }

    /// Cancels the active take without touching a previously finalized recording.
    /// Partial microphone and system files are removed together.
    @MainActor
    func cancelRecording(for meetingId: UUID) {
        stateLock.lock()
        guard currentMeetingID == meetingId else {
            stateLock.unlock()
            return
        }

        micAudioFile = nil
        systemAudioFile = nil
        let partialURLs = activeSourceURLsLocked()
        resetActiveSegmentLocked()
        stateLock.unlock()

        removeFiles(at: partialURLs)
        removeMeetingFolderIfEmpty(for: meetingId)
        print("Cancelled partial local audio recording")
    }

    /// Deletes all audio files associated with a meeting.
    func deleteAudioFiles(for meetingId: UUID) {
        stateLock.lock()
        if currentMeetingID == meetingId {
            micAudioFile = nil
            systemAudioFile = nil
            resetActiveSegmentLocked()
        }
        pendingSegments[meetingId] = nil
        stateLock.unlock()

        let meetingFolder = getMeetingFolder(for: meetingId)
        guard FileManager.default.fileExists(atPath: meetingFolder.path) else { return }

        do {
            try FileManager.default.removeItem(at: meetingFolder)
            print("Deleted meeting audio folder")
        } catch {
            print("Failed to delete meeting audio folder: \(error.localizedDescription)")
        }
    }

    private func makeLosslessFile(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var fileSettings = format.settings
        // AVAudioFile accepts non-interleaved client buffers but persists PCM
        // files interleaved. Keeping the hardware flag in file settings causes
        // Core Audio to warn and ignore it.
        fileSettings[AVLinearPCMIsNonInterleaved] = false

        return try AVAudioFile(
            forWriting: url,
            settings: fileSettings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    private func startOffsetLocked(
        for buffer: AVAudioPCMBuffer,
        format: AVAudioFormat
    ) -> TimeInterval {
        guard let recordingStartedAt else { return 0 }

        // The callback occurs after this buffer has been captured. Subtract its
        // duration so the scheduled start approximates the first sample rather
        // than the callback delivery time.
        let bufferDuration = format.sampleRate > 0
            ? Double(buffer.frameLength) / format.sampleRate
            : 0
        return max(
            0,
            ProcessInfo.processInfo.systemUptime - recordingStartedAt - bufferDuration
        )
    }

    private func makeCurrentSegmentLocked() -> RecordedSegment {
        let fileManager = FileManager.default
        let validMicURL = micFileURL.flatMap {
            fileManager.fileExists(atPath: $0.path) ? $0 : nil
        }
        let validSystemURL = systemFileURL.flatMap {
            fileManager.fileExists(atPath: $0.path) ? $0 : nil
        }

        return RecordedSegment(
            micURL: validMicURL,
            micOffset: micStartOffset ?? 0,
            systemURL: validSystemURL,
            systemOffset: systemStartOffset ?? 0
        )
    }

    private func makeTimeline(
        existingRecordingURL: URL?,
        segments: [RecordedSegment]
    ) throws -> [TimelineSource] {
        var timeline: [TimelineSource] = []
        var cursor: TimeInterval = 0

        if let existingRecordingURL,
           FileManager.default.fileExists(atPath: existingRecordingURL.path) {
            let existingDuration = try duration(of: existingRecordingURL)
            if existingDuration > 0 {
                timeline.append(
                    TimelineSource(url: existingRecordingURL, offset: 0, gain: 1)
                )
                cursor = existingDuration
            }
        }

        for segment in segments {
            let availableSources: [(url: URL, offset: TimeInterval)] = [
                segment.micURL.map { ($0, segment.micOffset) },
                segment.systemURL.map { ($0, segment.systemOffset) }
            ].compactMap { $0 }

            // A -6 dB gain per source prevents two correlated full-scale inputs
            // from clipping. A single-source take remains at its original level.
            let gain: Float = availableSources.count > 1 ? 0.5 : 1
            var segmentDuration: TimeInterval = 0

            for source in availableSources {
                let sourceDuration = try duration(of: source.url)
                guard sourceDuration > 0 else { continue }

                timeline.append(
                    TimelineSource(
                        url: source.url,
                        offset: cursor + source.offset,
                        gain: gain
                    )
                )
                segmentDuration = max(segmentDuration, source.offset + sourceDuration)
            }

            cursor += segmentDuration
        }

        return timeline
    }

    private func duration(of url: URL) throws -> TimeInterval {
        let file = try withAudioContext("Opening an audio source") {
            try AVAudioFile(forReading: url)
        }
        guard file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func renderMix(_ timeline: [TimelineSource], to outputURL: URL) throws {
        guard !timeline.isEmpty else { throw RecordingError.renderFailed }

        guard let renderFormat = AVAudioFormat(
            standardFormatWithSampleRate: 16_000,
            channels: 1
        ) else {
            throw RecordingError.renderFailed
        }

        var normalizedSources: [(
            url: URL,
            startFrame: AVAudioFramePosition,
            gain: Float
        )] = []
        var normalizedURLs: [URL] = []
        defer { removeFiles(at: normalizedURLs) }

        for source in timeline {
            let normalizedURL = outputURL.deletingLastPathComponent()
                .appendingPathComponent("normalized-\(UUID().uuidString).caf")
            // Track the path before conversion so a partially-created file is
            // also removed if normalization fails.
            normalizedURLs.append(normalizedURL)
            try normalizeAudio(
                at: source.url,
                to: normalizedURL,
                format: renderFormat
            )
            normalizedSources.append(
                (
                    normalizedURL,
                    AVAudioFramePosition(
                        (source.offset * renderFormat.sampleRate).rounded()
                    ),
                    source.gain
                )
            )
        }

        guard !normalizedSources.isEmpty else { throw RecordingError.renderFailed }

        var openedSources: [(
            file: AVAudioFile,
            startFrame: AVAudioFramePosition,
            gain: Float
        )] = []
        var totalFrames: AVAudioFramePosition = 0

        for source in normalizedSources {
            let file = try withAudioContext("Opening a normalized audio source") {
                try AVAudioFile(forReading: source.url)
            }
            openedSources.append((file, source.startFrame, source.gain))
            totalFrames = max(totalFrames, source.startFrame + file.length)
        }

        guard totalFrames > 0 else { throw RecordingError.renderFailed }
        let frameCapacity: AVAudioFrameCount = 4_096
        var sourceStates: [(
            file: AVAudioFile,
            startFrame: AVAudioFramePosition,
            gain: Float,
            buffer: AVAudioPCMBuffer
        )] = []

        for source in openedSources {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: renderFormat,
                frameCapacity: frameCapacity
            ) else {
                throw RecordingError.renderFailed
            }
            sourceStates.append((source.file, source.startFrame, source.gain, buffer))
        }

        guard let mixBuffer = AVAudioPCMBuffer(
            pcmFormat: renderFormat,
            frameCapacity: frameCapacity
        ) else {
            throw RecordingError.renderFailed
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: renderFormat.sampleRate,
            AVNumberOfChannelsKey: renderFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let outputFile = try withAudioContext("Creating the mixed WAV file") {
            try AVAudioFile(
                forWriting: outputURL,
                settings: outputSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        }

        var outputFrame: AVAudioFramePosition = 0
        while outputFrame < totalFrames {
            let framesThisPass = AVAudioFrameCount(
                min(AVAudioFramePosition(frameCapacity), totalFrames - outputFrame)
            )
            mixBuffer.frameLength = framesThisPass

            guard let outputChannels = mixBuffer.floatChannelData else {
                throw RecordingError.renderFailed
            }
            for channel in 0..<Int(renderFormat.channelCount) {
                outputChannels[channel].initialize(repeating: 0, count: Int(framesThisPass))
            }

            let passEndFrame = outputFrame + AVAudioFramePosition(framesThisPass)
            for state in sourceStates {
                let sourceEndFrame = state.startFrame + state.file.length
                let overlapStart = max(outputFrame, state.startFrame)
                let overlapEnd = min(passEndFrame, sourceEndFrame)
                guard overlapStart < overlapEnd else { continue }

                let sourceFrame = overlapStart - state.startFrame
                let outputOffset = Int(overlapStart - outputFrame)
                let overlapFrames = AVAudioFrameCount(overlapEnd - overlapStart)
                state.file.framePosition = sourceFrame
                state.buffer.frameLength = 0
                try withAudioContext("Reading normalized audio") {
                    try state.file.read(into: state.buffer, frameCount: overlapFrames)
                }

                guard let sourceChannels = state.buffer.floatChannelData else {
                    throw RecordingError.renderFailed
                }
                let readableFrames = Int(state.buffer.frameLength)
                for channel in 0..<Int(renderFormat.channelCount) {
                    let input = sourceChannels[channel]
                    let output = outputChannels[channel].advanced(by: outputOffset)
                    for frame in 0..<readableFrames {
                        output[frame] += input[frame] * state.gain
                    }
                }
            }

            // Avoid integer conversion overflow if unexpectedly loud sources
            // are supplied despite the per-source headroom.
            for channel in 0..<Int(renderFormat.channelCount) {
                let output = outputChannels[channel]
                for frame in 0..<Int(framesThisPass) {
                    output[frame] = min(1, max(-1, output[frame]))
                }
            }

            try withAudioContext("Writing mixed WAV audio") {
                try outputFile.write(from: mixBuffer)
            }
            outputFrame += AVAudioFramePosition(framesThisPass)
        }
    }

    private func normalizeAudio(
        at sourceURL: URL,
        to outputURL: URL,
        format outputFormat: AVAudioFormat
    ) throws {
        let inputFile = try withAudioContext("Opening audio for normalization") {
            try AVAudioFile(forReading: sourceURL)
        }
        guard let converter = AVAudioConverter(
            from: inputFile.processingFormat,
            to: outputFormat
        ) else {
            throw RecordingError.renderFailed
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: outputFormat.sampleRate,
            AVNumberOfChannelsKey: outputFormat.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false
        ]
        let outputFile = try withAudioContext("Creating normalized audio") {
            try AVAudioFile(
                forWriting: outputURL,
                settings: outputSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        }

        let inputCapacity: AVAudioFrameCount = 4_096
        let rateRatio = outputFormat.sampleRate / inputFile.processingFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(inputCapacity) * max(1, rateRatio)) + 256
        )
        var reachedEndOfInput = false
        var inputReadError: Error?
        var retainedInputBuffer: AVAudioPCMBuffer?
        var stalledConversionCount = 0

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            ) else {
                throw RecordingError.renderFailed
            }

            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, inputStatus in
                if reachedEndOfInput {
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                let remainingInputFrames = inputFile.length - inputFile.framePosition
                guard remainingInputFrames > 0 else {
                    reachedEndOfInput = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFile.processingFormat,
                    frameCapacity: inputCapacity
                ) else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }

                do {
                    try inputFile.read(
                        into: inputBuffer,
                        frameCount: AVAudioFrameCount(
                            min(AVAudioFramePosition(inputCapacity), remainingInputFrames)
                        )
                    )
                } catch {
                    inputReadError = error
                    inputStatus.pointee = .noDataNow
                    return nil
                }

                guard inputBuffer.frameLength > 0 else {
                    reachedEndOfInput = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                retainedInputBuffer = inputBuffer
                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if let inputReadError {
                throw RecordingError.operationFailed("Reading audio for normalization", inputReadError)
            }
            if let conversionError {
                throw RecordingError.operationFailed("Normalizing audio", conversionError)
            }
            if outputBuffer.frameLength > 0 {
                try withAudioContext("Writing normalized audio") {
                    try outputFile.write(from: outputBuffer)
                }
                stalledConversionCount = 0
            } else {
                stalledConversionCount += 1
            }

            switch status {
            case .haveData, .inputRanDry:
                if stalledConversionCount > 100 {
                    throw RecordingError.renderStalled
                }
            case .endOfStream:
                return
            case .error:
                throw RecordingError.renderFailed
            @unknown default:
                throw RecordingError.renderFailed
            }

            // Keep the most recently supplied input alive through the converter
            // call. It can be released before the next pass.
            withExtendedLifetime(retainedInputBuffer) {}
            retainedInputBuffer = nil
        }
    }

    private func installRenderedFile(from temporaryURL: URL, at outputURL: URL) throws {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(
                outputURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: outputURL)
        }
    }

    private func withAudioContext<T>(
        _ operation: String,
        _ body: () throws -> T
    ) throws -> T {
        do {
            return try body()
        } catch {
            throw RecordingError.operationFailed(operation, error)
        }
    }

    private func activeSourceURLsLocked() -> [URL] {
        [micFileURL, systemFileURL].compactMap { $0 }
    }

    private func resetActiveSegmentLocked() {
        currentMeetingID = nil
        recordingStartedAt = nil
        micAudioFile = nil
        systemAudioFile = nil
        micFileURL = nil
        systemFileURL = nil
        micFormat = nil
        systemFormat = nil
        micStartOffset = nil
        systemStartOffset = nil
        micWriteCount = 0
        systemWriteCount = 0
    }

    private func existingRecordingURL(for meetingId: UUID) -> URL? {
        let folder = getMeetingFolder(for: meetingId)
        let candidates = [
            folder.appendingPathComponent("recording.wav"),
            folder.appendingPathComponent("recording.m4a")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func removeFiles(at urls: [URL]) {
        for url in Set(urls) where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                print("Failed to remove temporary audio file: \(error.localizedDescription)")
            }
        }
    }

    private func removeMeetingFolderIfEmpty(for meetingId: UUID) {
        let folder = getMeetingFolder(for: meetingId)
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            ),
            contents.isEmpty
        else {
            return
        }

        try? FileManager.default.removeItem(at: folder)
    }

    private func removeDerivedTemporaryFiles(in folder: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        let derivedFiles = contents.filter { url in
            let name = url.lastPathComponent
            return (name.hasPrefix("normalized-") && name.hasSuffix(".caf"))
                || (name.hasPrefix("recording-") && name.contains(".tmp."))
        }
        removeFiles(at: derivedFiles)
    }
}
