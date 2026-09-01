import AudoraApplication
import AudoraDomain
import Foundation

/// Wall-clock adapter for refreshing a cooldown at its persisted UTC deadline.
/// Application owns the scheduling policy; the macOS composition supplies time
/// conversion and suspension.
public struct SystemChatAdmissionRefreshScheduler: ChatAdmissionRefreshScheduling {
    private let now: @Sendable () -> Date
    private let sleepNanoseconds: @Sendable (UInt64) async throws -> Void

    public init() {
        now = Date.init
        sleepNanoseconds = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    }

    init(
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (UInt64) async throws -> Void
    ) {
        self.now = now
        sleepNanoseconds = sleep
    }

    public func sleep(until deadline: UTCInstant) async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let deadlineDate = formatter.date(from: deadline.rawValue) else {
            throw SystemChatAdmissionRefreshSchedulerError.invalidDeadline
        }
        let interval = max(0, deadlineDate.timeIntervalSince(now()))
        let nanoseconds = interval * 1_000_000_000
        guard nanoseconds.isFinite,
              nanoseconds <= Double(UInt64.max)
        else {
            throw SystemChatAdmissionRefreshSchedulerError.invalidDeadline
        }
        try await sleepNanoseconds(UInt64(nanoseconds.rounded(.up)))
    }
}

public enum SystemChatAdmissionRefreshSchedulerError: Error, Equatable, Sendable {
    case invalidDeadline
}
