import Foundation

/// Monotonic time at the capture boundary. It is deliberately independent of
/// input callbacks, so an open but stalled microphone feed cannot suppress a
/// duration warning or the mandatory 45-minute stop.
public protocol CaptureMonotonicClock: Sendable {
    func now() async -> UInt64
    func sleep(until deadlineNanoseconds: UInt64) async
}

public struct SystemCaptureMonotonicClock: CaptureMonotonicClock {
    public init() {}

    public func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    public func sleep(until deadlineNanoseconds: UInt64) async {
        let current = DispatchTime.now().uptimeNanoseconds
        guard deadlineNanoseconds > current else { return }
        try? await Task.sleep(nanoseconds: deadlineNanoseconds - current)
    }
}
