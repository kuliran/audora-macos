import AVFoundation
import AudoraApplication
import Foundation

/// AVFoundation playback for exactly one opaque canonical-audio capability.
/// The adapter exposes only bounded transport state to Application.
public actor AVFoundationReviewPlaybackAdapter: ReviewPlaybackPort {
    private let resolver: any ReviewCanonicalAudioResolving
    private var source: ReviewAudioSource?
    private var player: AVAudioPlayer?
    private var positionMilliseconds: UInt64 = 0
    private var ticker: Task<Void, Never>?
    private var continuations: [UInt64: AsyncStream<ReviewPlaybackSnapshot>.Continuation]
        = [:]
    private var nextSubscriberID: UInt64 = 1

    public init(resolver: any ReviewCanonicalAudioResolving) {
        self.resolver = resolver
    }

    deinit {
        ticker?.cancel()
        for continuation in continuations.values { continuation.finish() }
    }

    public nonisolated var states: AsyncStream<ReviewPlaybackSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task { await self.addSubscriber(continuation) }
        }
    }

    public func load(_ source: ReviewAudioSource) async -> ReviewPlaybackSnapshot? {
        clearLoadedAudio()
        guard source.durationMilliseconds > 0,
              let data = await resolver.resolveCanonicalAudio(for: source)
        else { return nil }
        do {
            let candidate = try AVAudioPlayer(data: data)
            let measured = candidate.duration * 1_000
            guard measured.isFinite, measured > 0,
                  abs(measured - Double(source.durationMilliseconds)) < 1.0
            else { return nil }
            candidate.prepareToPlay()
            self.source = source
            player = candidate
            positionMilliseconds = 0
            return publish(status: .paused)
        } catch {
            return nil
        }
    }

    public func play() async -> ReviewPlaybackSnapshot? {
        guard let source, let player else { return nil }
        if positionMilliseconds >= source.durationMilliseconds {
            positionMilliseconds = 0
            player.currentTime = 0
        }
        let started = player.play()
        if started { startTicker() }
        return publish(status: started ? .playing : .paused)
    }

    public func pause() async -> ReviewPlaybackSnapshot? {
        guard let source, let player else { return nil }
        player.pause()
        stopTicker()
        positionMilliseconds = measuredPosition(
            player: player,
            durationMilliseconds: source.durationMilliseconds
        )
        return publish(
            status: positionMilliseconds >= source.durationMilliseconds
                ? .ended
                : .paused
        )
    }

    public func seek(
        toMilliseconds milliseconds: UInt64
    ) async -> ReviewPlaybackSnapshot? {
        guard let source, let player else { return nil }
        let clamped = min(milliseconds, source.durationMilliseconds)
        let wasPlaying = player.isPlaying
        player.currentTime = Double(clamped) / 1_000
        positionMilliseconds = clamped
        if clamped == source.durationMilliseconds {
            player.pause()
            stopTicker()
            return publish(status: .ended)
        }
        if wasPlaying {
            let resumed = player.play()
            if resumed { startTicker() } else { stopTicker() }
            return publish(status: resumed ? .playing : .paused)
        }
        return publish(status: .paused)
    }

    public func clear(_ audioCapabilityID: ReviewAudioCapabilityID?) async {
        guard audioCapabilityID == nil ||
                audioCapabilityID == source?.audioCapabilityID
        else { return }
        clearLoadedAudio()
    }

    private func clearLoadedAudio() {
        stopTicker()
        player?.stop()
        player = nil
        source = nil
        positionMilliseconds = 0
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard let source, let player else {
            stopTicker()
            return
        }
        positionMilliseconds = measuredPosition(
            player: player,
            durationMilliseconds: source.durationMilliseconds
        )
        if player.isPlaying {
            _ = publish(status: .playing)
        } else {
            let reachedEnd = player.duration.isFinite && player.duration > 0 &&
                player.currentTime >= max(player.duration - 0.001, 0)
            if reachedEnd {
                positionMilliseconds = source.durationMilliseconds
            }
            _ = publish(
                status: reachedEnd ||
                    positionMilliseconds >= source.durationMilliseconds
                    ? .ended
                    : .paused
            )
            stopTicker()
        }
    }

    private func measuredPosition(
        player: AVAudioPlayer,
        durationMilliseconds: UInt64
    ) -> UInt64 {
        let measured = player.currentTime * 1_000
        guard measured.isFinite, measured > 0 else { return 0 }
        return min(UInt64(measured.rounded(.down)), durationMilliseconds)
    }

    @discardableResult
    private func publish(status: ReviewPlaybackStatus) -> ReviewPlaybackSnapshot? {
        guard let snapshot = snapshot(status: status) else { return nil }
        for continuation in continuations.values { continuation.yield(snapshot) }
        return snapshot
    }

    private func snapshot(status: ReviewPlaybackStatus) -> ReviewPlaybackSnapshot? {
        guard let source else { return nil }
        return ReviewPlaybackSnapshot(
            audioCapabilityID: source.audioCapabilityID,
            positionMilliseconds: positionMilliseconds,
            durationMilliseconds: source.durationMilliseconds,
            status: status
        )
    }

    private func addSubscriber(
        _ continuation: AsyncStream<ReviewPlaybackSnapshot>.Continuation
    ) {
        let subscriberID = nextSubscriberID
        nextSubscriberID &+= 1
        continuations[subscriberID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(subscriberID) }
        }
        if let status = currentStatus, let snapshot = snapshot(status: status) {
            continuation.yield(snapshot)
        }
    }

    private func removeSubscriber(_ subscriberID: UInt64) {
        continuations.removeValue(forKey: subscriberID)
    }

    private var currentStatus: ReviewPlaybackStatus? {
        guard let source, let player else { return nil }
        if player.isPlaying { return .playing }
        return positionMilliseconds >= source.durationMilliseconds ? .ended : .paused
    }
}
