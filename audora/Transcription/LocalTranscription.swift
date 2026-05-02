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
        onFinal: @escaping @Sendable (AudioSource, String) -> Void
    ) async throws -> LocalTranscriptionSession {
        let micProvider = ParakeetTranscriptionProvider()
        let systemProvider = ParakeetTranscriptionProvider()

        do {
            try await micProvider.prepare(onStatus: onStatus, onProgress: onProgress)
            try await systemProvider.prepare(
                onStatus: { status in
                    onStatus(status.replacingOccurrences(of: "Initializing", with: "Initializing system"))
                },
                onProgress: { _ in }
            )

            onStatus("Loading VAD model...")
            let vadManager = try await VadManager { progress in
                onProgress(progress.fractionCompleted)
            }

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

            return LocalTranscriptionSession(
                micTranscriber: micTranscriber,
                systemTranscriber: systemTranscriber
            )
        } catch {
            micProvider.clearModelCache()
            systemProvider.clearModelCache()
            throw error
        }
    }

    func start() {
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
}

final class LocalStreamingTranscriber: @unchecked Sendable {
    private let provider: any TranscriptionProvider
    private let vadManager: VadManager
    private let source: AudioSource
    private let onFinal: @Sendable (AudioSource, String) -> Void
    private let flushInterval = 5 * 16_000

    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var task: Task<Void, Never>?
    private var previousContext: String?

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

    private static let vadChunkSize = 4096
    private static let minimumSpeechSamples = 16_000
    private static let prerollChunkCount = 2
    private static let contextWordCount = 5
    private static let rateWarmupSeconds: Double = 3.0
    private static let rateDivergenceThreshold: Double = 0.05

    init(
        provider: any TranscriptionProvider,
        vadManager: VadManager,
        source: AudioSource,
        onFinal: @escaping @Sendable (AudioSource, String) -> Void
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
        guard let copy = Self.copyPCMBuffer(buffer) else { return }
        continuation?.yield(copy)
    }

    func stop() {
        continuation?.finish()
        continuation = nil
        task?.cancel()
        task = nil
    }

    private func run(stream: AsyncStream<AVAudioPCMBuffer>) async {
        var vadState = await vadManager.makeStreamState()
        var speechSamples: [Float] = []
        var vadBuffer: [Float] = []
        var vadReadIndex = 0
        var recentChunks: [[Float]] = []
        var isSpeaking = false

        for await buffer in stream {
            guard !Task.isCancelled else { break }

            updateRateTracking(buffer)
            guard let samples = extractSamples(buffer) else { continue }

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
                        config: .default,
                        returnSeconds: true,
                        timeResolution: 2
                    )
                    vadState = result.state

                    if let event = result.event {
                        switch event.kind {
                        case .speechStart:
                            if !wasSpeaking {
                                isSpeaking = true
                                startedSpeech = true
                                speechSamples = recentChunks.suffix(Self.prerollChunkCount).flatMap { $0 }
                            }
                        case .speechEnd:
                            endedSpeech = wasSpeaking || isSpeaking
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
                        if speechSamples.count > Self.minimumSpeechSamples {
                            let segment = speechSamples
                            speechSamples.removeAll(keepingCapacity: true)
                            await transcribeSegment(segment)
                        } else {
                            speechSamples.removeAll(keepingCapacity: true)
                        }
                    } else if isSpeaking, speechSamples.count >= flushInterval {
                        let segment = speechSamples
                        speechSamples.removeAll(keepingCapacity: true)
                        await transcribeSegment(segment)
                    }
                } catch {
                    localTranscriptionLogger.error("VAD error for \(self.source.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        if speechSamples.count > Self.minimumSpeechSamples {
            await transcribeSegment(speechSamples)
        }
    }

    private func transcribeSegment(_ samples: [Float]) async {
        do {
            try Task.checkCancellation()
            let text = try await provider.transcribe(samples, previousContext: previousContext)
            guard !text.isEmpty, !Task.isCancelled else { return }

            let words = text.split(separator: " ")
            previousContext = words.suffix(Self.contextWordCount).joined(separator: " ")
            onFinal(source, text)
        } catch {
            localTranscriptionLogger.error("ASR error for \(self.source.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
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
