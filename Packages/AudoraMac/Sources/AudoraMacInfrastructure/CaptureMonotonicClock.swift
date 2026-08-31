import AudioToolbox
import Darwin
import Foundation

/// One capture-timeline origin represented in both coordinates needed at the
/// macOS input seam. `uptimeNanoseconds` drives application deadlines and UI
/// projection; `audioHostTime` is the matching AVFoundation callback tick.
/// Synthetic clocks need only the public uptime coordinate.
public struct CaptureMonotonicStart: Equatable, Sendable {
    public let uptimeNanoseconds: UInt64
    let audioHostTime: UInt64?

    public init(uptimeNanoseconds: UInt64) {
        self.uptimeNanoseconds = uptimeNanoseconds
        audioHostTime = nil
    }

    fileprivate init(uptimeNanoseconds: UInt64, audioHostTime: UInt64) {
        self.uptimeNanoseconds = uptimeNanoseconds
        self.audioHostTime = audioHostTime
    }
}

/// Monotonic time at the capture boundary. It is deliberately independent of
/// input callbacks, so an open but stalled microphone feed cannot suppress a
/// duration warning or the mandatory 45-minute stop.
public protocol CaptureMonotonicClock: Sendable {
    func now() async -> UInt64
    /// Samples the authoritative capture origin. Input sources call this only
    /// after authorization and preparation, immediately before capture starts.
    func captureStart() async -> CaptureMonotonicStart
    /// Suspends until `deadlineNanoseconds`, or throws `CancellationError`
    /// promptly when the waiting task is cancelled.
    func sleep(until deadlineNanoseconds: UInt64) async throws
}

public extension CaptureMonotonicClock {
    func captureStart() async -> CaptureMonotonicStart {
        CaptureMonotonicStart(uptimeNanoseconds: await now())
    }
}

public struct SystemCaptureMonotonicClock: CaptureMonotonicClock {
    public init() {}

    public func now() -> UInt64 {
        AudioConvertHostTimeToNanos(mach_absolute_time())
    }

    public func captureStart() -> CaptureMonotonicStart {
        let hostTime = mach_absolute_time()
        return CaptureMonotonicStart(
            uptimeNanoseconds: AudioConvertHostTimeToNanos(hostTime),
            audioHostTime: hostTime
        )
    }

    public func sleep(until deadlineNanoseconds: UInt64) async throws {
        let current = AudioConvertHostTimeToNanos(mach_absolute_time())
        guard deadlineNanoseconds > current else { return }
        try await Task.sleep(nanoseconds: deadlineNanoseconds - current)
    }
}
