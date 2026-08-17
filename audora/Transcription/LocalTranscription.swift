@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import OSLog

private let localTranscriptionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "studio.orbitlabs.audora",
    category: "LocalTranscription"
)

enum TranscriptionProviderStatus: Equatable {
    case ready
    case needsDownload(prompt: String)
}

enum TranscriptionProviderError: LocalizedError {
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "The transcription model has not finished loading."
        }
    }
}

protocol TranscriptionProvider: Sendable {
    var displayName: String { get }

    func checkStatus() -> TranscriptionProviderStatus
    func prepare(
        onStatus: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws
    func transcribe(_ samples: [Float], previousContext: String?) async throws -> String
    func clearModelCache()
}

final class ParakeetTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    static var modelReadinessText: String {
        let exists = AsrModels.modelsExist(
            at: AudoraLocalModelStore.parakeetDirectory(),
            version: .v3
        )
        return exists
            ? "Model ready on this Mac."
            : "Model downloads the first time Local Parakeet is used."
    }

    let displayName = "Parakeet TDT v3"
    private var asrManager: AsrManager?

    func checkStatus() -> TranscriptionProviderStatus {
        let exists = AsrModels.modelsExist(
            at: AudoraLocalModelStore.parakeetDirectory(),
            version: .v3
        )
        return exists ? .ready : .needsDownload(prompt: "Transcription requires a one-time model download.")
    }

    func clearModelCache() {
        AudoraLocalModelStore.clearParakeetCache()
    }

    func prepare(
        onStatus: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let modelsDirectory = AudoraLocalModelStore.parakeetDirectory()
        let models: AsrModels

        if AsrModels.modelsExist(at: modelsDirectory, version: .v3) {
            onStatus("Initializing \(displayName)...")
            models = try await AsrModels.load(from: modelsDirectory, version: .v3)
        } else {
            onStatus("Downloading \(displayName)...")
            models = try await AsrModels.downloadAndLoad(to: modelsDirectory, version: .v3) { progress in
                onProgress(progress.fractionCompleted)
            }
            onStatus("Initializing \(displayName)...")
        }

        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        self.asrManager = asr
    }

    func transcribe(_ samples: [Float], previousContext: String? = nil) async throws -> String {
        guard let asrManager else {
            throw TranscriptionProviderError.notPrepared
        }

        let result = try await asrManager.transcribe(samples)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AudoraLocalModelStore {
    static func parakeetDirectory(
        baseDirectory: URL = defaultBaseDirectory(),
        fluidAudioModelsRoot: URL = MLModelConfigurationUtils.defaultModelsDirectory()
    ) -> URL {
        let wrapper = baseDirectory
            .appendingPathComponent("parakeet", isDirectory: true)
            .appendingPathComponent("parakeet-v3", isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)

        _ = migrateParakeetIfNeeded(
            wrapperDirectory: wrapper,
            fluidAudioModelsRoot: fluidAudioModelsRoot
        )
        return wrapper
    }

    static func clearParakeetCache(
        baseDirectory: URL = defaultBaseDirectory(),
        fluidAudioModelsRoot: URL = MLModelConfigurationUtils.defaultModelsDirectory()
    ) {
        let fileManager = FileManager.default
        let wrapper = baseDirectory
            .appendingPathComponent("parakeet", isDirectory: true)
            .appendingPathComponent("parakeet-v3", isDirectory: true)
        try? fileManager.removeItem(at: wrapper)

        parakeetMigrationCandidates(fluidAudioModelsRoot: fluidAudioModelsRoot).forEach {
            try? fileManager.removeItem(at: $0)
        }
    }

    static func defaultBaseDirectory(appSupportDirectory: URL? = nil) -> URL {
        let fileManager = FileManager.default
        let appSupport =
            appSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return appSupport
            .appendingPathComponent("Audora", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("Transcription", isDirectory: true)
    }

    private static func migrateParakeetIfNeeded(
        wrapperDirectory: URL,
        fluidAudioModelsRoot: URL
    ) -> URL {
        let fileManager = FileManager.default
        let targetDirectory = wrapperDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(Repo.parakeet.folderName, isDirectory: true)

        if fileManager.fileExists(atPath: targetDirectory.path) {
            return wrapperDirectory
        }

        for candidate in parakeetMigrationCandidates(fluidAudioModelsRoot: fluidAudioModelsRoot) {
            if fileManager.fileExists(atPath: candidate.path) {
                moveDirectoryIfNeeded(from: candidate, to: targetDirectory)
                break
            }
        }

        return wrapperDirectory
    }

    private static func parakeetMigrationCandidates(fluidAudioModelsRoot: URL) -> [URL] {
        candidateDirectories(
            currentRelativePath: Repo.parakeet.folderName,
            legacyRelativePath: Repo.parakeet.name,
            root: fluidAudioModelsRoot
        )
    }

    private static func candidateDirectories(
        currentRelativePath: String,
        legacyRelativePath: String,
        root: URL
    ) -> [URL] {
        var seen: Set<String> = []
        return [currentRelativePath, legacyRelativePath]
            .map { append(relativePath: $0, to: root) }
            .filter { url in
                let key = url.standardizedFileURL.path
                return seen.insert(key).inserted
            }
    }

    private static func append(relativePath: String, to base: URL) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(base) { partial, component in
                partial.appendingPathComponent(String(component), isDirectory: true)
            }
    }

    private static func moveDirectoryIfNeeded(from source: URL, to destination: URL) {
        let fileManager = FileManager.default
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        guard fileManager.fileExists(atPath: source.path) else { return }
        guard !fileManager.fileExists(atPath: destination.path) else { return }

        try? fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            do {
                try fileManager.copyItem(at: source, to: destination)
                try? fileManager.removeItem(at: source)
            } catch {
                return
            }
        }
    }
}

final class LocalTranscriptionSession: @unchecked Sendable {
    private let micTranscriber: LocalStreamingTranscriber
    private let systemTranscriber: LocalStreamingTranscriber

    private init(
        micTranscriber: LocalStreamingTranscriber,
        systemTranscriber: LocalStreamingTranscriber
    ) {
        self.micTranscriber = micTranscriber
        self.systemTranscriber = systemTranscriber
    }

    static func make(
        onStatus: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void,
        onFinal: @escaping @Sendable (AudioSource, String) async -> Void
    ) async throws -> LocalTranscriptionSession {
        let micProvider = ParakeetTranscriptionProvider()
        let systemProvider = ParakeetTranscriptionProvider()

        do {
            print("🔧 [Parakeet] Step 1/3: Preparing mic ASR provider...")
            try await micProvider.prepare(onStatus: onStatus, onProgress: onProgress)
            try Task.checkCancellation()
            print("✅ [Parakeet] Mic ASR provider ready")

            print("🔧 [Parakeet] Step 2/3: Preparing system ASR provider...")
            try await systemProvider.prepare(
                onStatus: { status in
                    onStatus(status.replacingOccurrences(of: "Initializing", with: "Initializing system"))
                },
                onProgress: { _ in }
            )
            try Task.checkCancellation()
            print("✅ [Parakeet] System ASR provider ready")

            print("🔧 [Parakeet] Step 3/3: Loading VAD model...")
            onStatus("Loading VAD model...")
            // FluidAudio's default 0.85 threshold is conservative enough to
            // miss quiet syllables in ordinary laptop-microphone speech.
            // Silero's usual operating point is around 0.5; 0.55 keeps a
            // little noise rejection while preserving softer words.
            let vadManager = try await VadManager(
                config: VadConfig(defaultThreshold: 0.55)
            ) { progress in
                onProgress(progress.fractionCompleted)
            }
            try Task.checkCancellation()
            print("✅ [Parakeet] VAD model loaded")

            let micTranscriber = LocalStreamingTranscriber(
                provider: micProvider,
                vadManager: vadManager,
                source: .mic,
                onFinal: onFinal
            )
            let systemTranscriber = LocalStreamingTranscriber(
                provider: systemProvider,
                vadManager: vadManager,
                source: .system,
                onFinal: onFinal
            )

            print("✅ [Parakeet] All models loaded, session ready")
            return LocalTranscriptionSession(
                micTranscriber: micTranscriber,
                systemTranscriber: systemTranscriber
            )
        } catch {
            print("❌ [Parakeet] Session creation failed: \(error)")
            throw error
        }
    }

    func start() {
        print("🎙️ [Parakeet] Starting mic and system transcribers...")
        micTranscriber.start()
        systemTranscriber.start()
    }

    func submit(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
        switch source {
        case .mic:
            micTranscriber.submit(buffer)
        case .system:
            systemTranscriber.submit(buffer)
        }
    }

    func stop() {
        micTranscriber.stop()
        systemTranscriber.stop()
    }

    func finish() async {
        print("🎙️ [Parakeet] Finishing transcription session (flushing remaining audio)...")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.micTranscriber.finish() }
            group.addTask { await self.systemTranscriber.finish() }
        }
        print("✅ [Parakeet] Transcription session finished")
    }
}

final class LocalStreamingTranscriber: @unchecked Sendable {
    private let provider: any TranscriptionProvider
    private let vadManager: VadManager
    private let source: AudioSource
    private let onFinal: @Sendable (AudioSource, String) async -> Void
    private let flushInterval = 12 * 16_000

    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var task: Task<Void, Never>?
    private var previousContext: String?
    private var previousEmittedText: String?

    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private var rateTrackingStartDate: Date?
    private var rateTrackingTotalFrames: Int64 = 0
    private var effectiveSampleRate: Double?

    // VAD fallback tracking
    private var vadFailureCount = 0
    private var bufferCount = 0
    private static let maxVadFailuresBeforeFallback = 5
    private static let fallbackFlushInterval = 3 * 16_000 // 3s at 16kHz

    private static let vadChunkSize = 4096
    private static let minimumSpeechSamples = 16_000
    private static let flushOverlapSamples = 16_000
    private static let prerollChunkCount = 2
    private static let contextWordCount = 5
    private static let maximumDeduplicationWords = 12
    private static let rateWarmupSeconds: Double = 3.0
    private static let rateDivergenceThreshold: Double = 0.05
    private static let vadSegmentationConfig = VadSegmentationConfig(
        minSpeechDuration: 0.15,
        minSilenceDuration: 1.25,
        maxSpeechDuration: 14.0,
        speechPadding: 0.15,
        silenceThresholdForSplit: 0.3,
        negativeThreshold: nil,
        negativeThresholdOffset: 0.2,
        minSilenceAtMaxSpeech: 0.098,
        useMaxPossibleSilenceAtMaxSpeech: true
    )

    private enum SegmentBoundary {
        case natural
        case continuation
    }

    init(
        provider: any TranscriptionProvider,
        vadManager: VadManager,
        source: AudioSource,
        onFinal: @escaping @Sendable (AudioSource, String) async -> Void
    ) {
        self.provider = provider
        self.vadManager = vadManager
        self.source = source
        self.onFinal = onFinal
    }

    func start() {
        let stream = AsyncStream(AVAudioPCMBuffer.self) { continuation in
            self.continuation = continuation
        }

        task = Task(priority: .userInitiated) { [weak self] in
            await self?.run(stream: stream)
        }
    }

    func submit(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copyPCMBuffer(buffer) else {
            if bufferCount < 5 {
                print("⚠️ [\(source)] copyPCMBuffer returned nil, buffer dropped")
            }
            return
        }
        if continuation == nil {
            if bufferCount < 5 {
                print("⚠️ [\(source)] continuation is nil, buffer dropped (stream not started?)")
            }
            return
        }
        continuation?.yield(copy)
    }

    func stop() {
        continuation?.finish()
        continuation = nil
        task?.cancel()
        task = nil
    }

    func finish() async {
        continuation?.finish()
        continuation = nil
        await task?.value
        task = nil
    }

    private func run(stream: AsyncStream<AVAudioPCMBuffer>) async {
        var vadState = await vadManager.makeStreamState()
        var speechSamples: [Float] = []
        var vadBuffer: [Float] = []
        var vadReadIndex = 0
        var recentChunks: [[Float]] = []
        var isSpeaking = false
        var useVadFallback = false
        var fallbackAccumulator: [Float] = []
        var extractFailCount = 0

        print("🎙️ [\(source)] Transcriber run loop started, waiting for audio buffers...")

        for await buffer in stream {
            guard !Task.isCancelled else { break }

            bufferCount += 1
            if bufferCount == 1 {
                print("🎙️ [\(source)] ✅ First buffer received (format: \(buffer.format.sampleRate)Hz, ch:\(buffer.format.channelCount), frames:\(buffer.frameLength))")
            }
            if bufferCount % 500 == 0 {
                print("🎙️ [\(source)] Processed \(bufferCount) buffers, vadFailures: \(vadFailureCount), fallback: \(useVadFallback)")
            }

            updateRateTracking(buffer)
            guard let samples = extractSamples(buffer) else {
                extractFailCount += 1
                if extractFailCount <= 3 {
                    print("⚠️ [\(source)] extractSamples returned nil (buffer #\(bufferCount), format: \(buffer.format))")
                }
                continue
            }

            if bufferCount == 1 {
                let maxAmp = samples.map { abs($0) }.max() ?? 0
                print("🎙️ [\(source)] First samples extracted: count=\(samples.count), maxAmplitude=\(String(format: "%.6f", maxAmp))")
            }

            // ── VAD fallback path: time-based chunking when VAD is broken ──
            if useVadFallback {
                fallbackAccumulator.append(contentsOf: samples)
                if fallbackAccumulator.count >= Self.fallbackFlushInterval {
                    let segment = fallbackAccumulator
                    fallbackAccumulator.removeAll(keepingCapacity: true)
                    let maxAmp = segment.map { abs($0) }.max() ?? 0
                    if maxAmp > 0.001 {
                        print("🔄 [\(source)] Fallback transcribing \(segment.count) samples (\(String(format: "%.1f", Double(segment.count) / 16000.0))s, peak: \(String(format: "%.4f", maxAmp)))")
                        await transcribeSegment(segment)
                    }
                }
                continue
            }

            // ── Normal VAD path ──
            vadBuffer.append(contentsOf: samples)

            while vadBuffer.count - vadReadIndex >= Self.vadChunkSize {
                let chunk = Array(vadBuffer[vadReadIndex..<(vadReadIndex + Self.vadChunkSize)])
                vadReadIndex += Self.vadChunkSize

                if vadReadIndex > vadBuffer.count / 2 {
                    vadBuffer.removeFirst(vadReadIndex)
                    vadReadIndex = 0
                }

                let wasSpeaking = isSpeaking
                var startedSpeech = false
                var endedSpeech = false

                do {
                    let result = try await vadManager.processStreamingChunk(
                        chunk,
                        state: vadState,
                        config: Self.vadSegmentationConfig,
                        returnSeconds: true,
                        timeResolution: 2
                    )
                    vadState = result.state

                    // Reset failure count on success
                    if vadFailureCount > 0 {
                        print("✅ [\(source)] VAD recovered after \(vadFailureCount) failures")
                        vadFailureCount = 0
                    }

                    if let event = result.event {
                        switch event.kind {
                        case .speechStart:
                            if !wasSpeaking {
                                isSpeaking = true
                                startedSpeech = true
                                speechSamples = recentChunks.suffix(Self.prerollChunkCount).flatMap { $0 }
                                print("🗣️ [\(source)] Speech started")
                            }
                        case .speechEnd:
                            endedSpeech = wasSpeaking || isSpeaking
                            print("🤫 [\(source)] Speech ended (\(speechSamples.count + chunk.count) samples)")
                        }
                    }

                    if wasSpeaking || startedSpeech || endedSpeech {
                        speechSamples.append(contentsOf: chunk)
                        recentChunks.removeAll(keepingCapacity: true)
                    } else {
                        recentChunks.append(chunk)
                        if recentChunks.count > Self.prerollChunkCount {
                            recentChunks.removeFirst(recentChunks.count - Self.prerollChunkCount)
                        }
                    }

                    if endedSpeech {
                        isSpeaking = false
                        if speechSamples.count >= Self.minimumSpeechSamples {
                            let segment = speechSamples
                            speechSamples.removeAll(keepingCapacity: true)
                            await transcribeSegment(segment)
                        } else {
                            print("⚠️ [\(source)] Speech too short (\(speechSamples.count) < \(Self.minimumSpeechSamples)), discarding")
                            speechSamples.removeAll(keepingCapacity: true)
                        }
                    } else if isSpeaking, speechSamples.count >= flushInterval {
                        let segment = speechSamples
                        // Preserve one second on both sides of an artificial
                        // model-window boundary. Without overlap, a word split
                        // exactly at the old five-second cut vanished from
                        // both independent Parakeet calls.
                        speechSamples = Array(segment.suffix(Self.flushOverlapSamples))
                        await transcribeSegment(segment, boundary: .continuation)
                    }
                } catch {
                    vadFailureCount += 1
                    localTranscriptionLogger.error("VAD error for \(self.source.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    print("❌ [\(source)] VAD error #\(vadFailureCount): \(error)")

                    if vadFailureCount >= Self.maxVadFailuresBeforeFallback {
                        print("⚠️ [\(source)] VAD failed \(vadFailureCount) times — switching to time-based fallback (no VAD)")
                        useVadFallback = true
                        // Move accumulated speech to fallback
                        fallbackAccumulator = speechSamples + chunk
                        speechSamples.removeAll()
                        break // exit the while loop to enter fallback path
                    }
                }
            }
        }

        print("🎙️ [\(source)] Run loop ended — buffers: \(bufferCount), vadFailures: \(vadFailureCount), fallback: \(useVadFallback)")

        // Flush remaining speech from VAD path
        if isSpeaking, vadReadIndex < vadBuffer.count {
            speechSamples.append(contentsOf: vadBuffer[vadReadIndex..<vadBuffer.count])
        }
        if speechSamples.count >= Self.minimumSpeechSamples {
            await transcribeSegment(speechSamples)
        }

        // Flush remaining fallback accumulator
        if !fallbackAccumulator.isEmpty, fallbackAccumulator.count >= Self.minimumSpeechSamples {
            print("🔄 [\(source)] Flushing final fallback: \(fallbackAccumulator.count) samples")
            await transcribeSegment(fallbackAccumulator)
        }
    }

    private func transcribeSegment(
        _ samples: [Float],
        boundary: SegmentBoundary = .natural
    ) async {
        let duration = String(format: "%.1f", Double(samples.count) / 16000.0)
        print("📝 [\(source)] Transcribing \(samples.count) samples (\(duration)s)...")
        do {
            try Task.checkCancellation()
            let text = try await provider.transcribe(samples, previousContext: previousContext)
            var emittedText = Self.removingRepeatedPrefix(
                from: text,
                previousText: previousEmittedText
            )
            if boundary == .continuation {
                emittedText = emittedText.trimmingCharacters(
                    in: CharacterSet(charactersIn: ".…")
                )
            }
            emittedText = emittedText.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !emittedText.isEmpty, !Task.isCancelled else {
                print("📝 [\(source)] Transcription returned empty or was cancelled")
                return
            }

            previousEmittedText = emittedText
            let words = emittedText.split(separator: " ")
            previousContext = words.suffix(Self.contextWordCount).joined(separator: " ")
            print("📝 [\(source)] ✅ Transcribed \(words.count) word(s)")
            await onFinal(source, emittedText)
        } catch {
            print("❌ [\(source)] ASR transcription failed: \(error)")
            localTranscriptionLogger.error("ASR error for \(self.source.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func removingRepeatedPrefix(
        from currentText: String,
        previousText: String?
    ) -> String {
        guard let previousText, !previousText.isEmpty else { return currentText }

        let previousWords = previousText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let currentWords = currentText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let maximumOverlap = min(
            maximumDeduplicationWords,
            previousWords.count,
            currentWords.count
        )
        guard maximumOverlap > 0 else { return currentText }

        func normalized(_ word: String) -> String {
            word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }

        for overlap in stride(from: maximumOverlap, through: 1, by: -1) {
            let previousSuffix = previousWords.suffix(overlap).map(normalized)
            let currentPrefix = currentWords.prefix(overlap).map(normalized)
            if previousSuffix == currentPrefix {
                return currentWords.dropFirst(overlap).joined(separator: " ")
            }
        }

        return currentText
    }

    private func updateRateTracking(_ buffer: AVAudioPCMBuffer) {
        let frames = Int64(buffer.frameLength)
        guard frames > 0 else { return }

        let now = Date()
        if rateTrackingStartDate == nil {
            rateTrackingStartDate = now
        }
        rateTrackingTotalFrames += frames

        guard effectiveSampleRate == nil,
              let start = rateTrackingStartDate else { return }

        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= Self.rateWarmupSeconds else { return }

        let measured = Double(rateTrackingTotalFrames) / elapsed
        let declared = buffer.format.sampleRate
        let divergence = abs(measured - declared) / declared

        if divergence > Self.rateDivergenceThreshold {
            effectiveSampleRate = measured
            converter = nil
            localTranscriptionLogger.warning(
                "Rate mismatch for \(self.source.rawValue, privacy: .public): declared=\(declared, privacy: .public), effective=\(measured, privacy: .public)"
            )
        }
    }

    private func extractSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let sourceFormat = buffer.format
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        let actualRate = effectiveSampleRate ?? sourceFormat.sampleRate

        if sourceFormat.commonFormat == .pcmFormatFloat32,
           abs(actualRate - 16_000) < 0.001,
           let channelData = buffer.floatChannelData {
            if sourceFormat.channelCount == 1 {
                return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            }

            let channelCount = Int(sourceFormat.channelCount)
            return (0..<frameLength).map { frameIndex in
                var sum: Float = 0
                for channelIndex in 0..<channelCount {
                    sum += channelData[channelIndex][frameIndex]
                }
                return sum / Float(channelCount)
            }
        }

        var inputBuffer = buffer
        let monoRate = actualRate

        if sourceFormat.channelCount > 1, let src = buffer.floatChannelData {
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: monoRate,
                channels: 1,
                interleaved: false
            )!
            if let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity),
               let dst = monoBuffer.floatChannelData?[0] {
                monoBuffer.frameLength = buffer.frameLength
                let channelCount = Int(sourceFormat.channelCount)
                let scale = 1.0 / Float(channelCount)
                for frameIndex in 0..<frameLength {
                    var sum: Float = 0
                    for channelIndex in 0..<channelCount {
                        sum += src[channelIndex][frameIndex]
                    }
                    dst[frameIndex] = sum * scale
                }
                inputBuffer = monoBuffer
            }
        } else if effectiveSampleRate != nil, sourceFormat.channelCount == 1 {
            let correctedFormat = AVAudioFormat(
                commonFormat: sourceFormat.commonFormat,
                sampleRate: monoRate,
                channels: 1,
                interleaved: sourceFormat.isInterleaved
            )!
            if let rewrapped = AVAudioPCMBuffer(pcmFormat: correctedFormat, frameCapacity: buffer.frameCapacity) {
                rewrapped.frameLength = buffer.frameLength
                Self.copyAudioData(from: buffer, to: rewrapped)
                inputBuffer = rewrapped
            }
        }

        let inputFormat = inputBuffer.format
        if converter == nil || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputFrames = AVAudioFrameCount(max(1, Double(inputBuffer.frameLength) * ratio))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrames
        ) else { return nil }

        var error: NSError?
        nonisolated(unsafe) var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let error {
            localTranscriptionLogger.error("Resample error for \(self.source.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))
    }

    private static func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }

        copy.frameLength = buffer.frameLength
        copyAudioData(from: buffer, to: copy)
        return copy
    }

    private static func copyAudioData(from source: AVAudioPCMBuffer, to destination: AVAudioPCMBuffer) {
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        let bufferCount = min(sourceBuffers.count, destinationBuffers.count)

        for index in 0..<bufferCount {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData else { continue }
            let byteCount = min(
                Int(sourceBuffers[index].mDataByteSize),
                Int(destinationBuffers[index].mDataByteSize)
            )
            memcpy(destinationData, sourceData, byteCount)
        }
    }
}
