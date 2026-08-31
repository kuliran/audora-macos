public enum CanonicalRecordingLimits {
    public static let sampleRate: UInt64 = 16_000
    public static let fiveMinuteWarningFrame: UInt64 = 38_400_000
    public static let oneMinuteCountdownFrame: UInt64 = 42_240_000
    public static let maximumFrames: UInt64 = 43_200_000

    public static func phase(at frameCount: UInt64) -> RecordingLimitPhase {
        if frameCount >= maximumFrames {
            return .automaticStop
        }
        if frameCount >= oneMinuteCountdownFrame {
            let remainingFrames = maximumFrames - frameCount
            let seconds = (remainingFrames + sampleRate - 1) / sampleRate
            return .oneMinuteCountdown(secondsRemaining: UInt8(seconds))
        }
        if frameCount >= fiveMinuteWarningFrame {
            return .fiveMinuteWarning
        }
        return .ordinary
    }
}

public enum RecordingLimitPhase: Equatable, Sendable {
    case ordinary
    case fiveMinuteWarning
    case oneMinuteCountdown(secondsRemaining: UInt8)
    case automaticStop
}

public enum CanonicalFrameRangeError: Error, Equatable, Sendable {
    case emptyOrReversed
    case outOfBounds
}

public struct CanonicalFrameRange: Hashable, Sendable {
    public let startFrame: UInt64
    public let endFrame: UInt64

    public init(
        startFrame: UInt64,
        endFrame: UInt64,
        durationFrames: UInt64? = nil
    ) throws {
        guard startFrame < endFrame else {
            throw CanonicalFrameRangeError.emptyOrReversed
        }
        if let durationFrames, endFrame > durationFrames {
            throw CanonicalFrameRangeError.outOfBounds
        }
        self.startFrame = startFrame
        self.endFrame = endFrame
    }

    public var frameCount: UInt64 { endFrame - startFrame }
}

public enum UnavailableReason: String, CaseIterable, Comparable, Sendable {
    case captureGap
    case muted

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum UnavailableIntervalError: Error, Equatable, Sendable {
    case emptyReasons
}

public struct UnavailableInterval: Equatable, Sendable {
    public let range: CanonicalFrameRange
    public let reasons: Set<UnavailableReason>

    public init(
        range: CanonicalFrameRange,
        reasons: Set<UnavailableReason>
    ) throws {
        guard !reasons.isEmpty else {
            throw UnavailableIntervalError.emptyReasons
        }
        self.range = range
        self.reasons = reasons
    }
}

public enum UnavailableIntervalNormalizer {
    private struct BoundaryDelta {
        var starts: [UnavailableReason: Int] = [:]
        var ends: [UnavailableReason: Int] = [:]
    }

    public static func normalize(
        _ intervals: [UnavailableInterval],
        durationFrames: UInt64
    ) throws -> [UnavailableInterval] {
        var boundaries: [UInt64: BoundaryDelta] = [:]
        for interval in intervals {
            guard interval.range.endFrame <= durationFrames else {
                throw CanonicalFrameRangeError.outOfBounds
            }
            for reason in interval.reasons {
                boundaries[interval.range.startFrame, default: BoundaryDelta()]
                    .starts[reason, default: 0] += 1
                boundaries[interval.range.endFrame, default: BoundaryDelta()]
                    .ends[reason, default: 0] += 1
            }
        }

        var active: [UnavailableReason: Int] = [:]
        var previous: UInt64?
        var result: [UnavailableInterval] = []

        for position in boundaries.keys.sorted() {
            if let previous, previous < position {
                let reasons = Set(active.compactMap { reason, count in
                    count > 0 ? reason : nil
                })
                if !reasons.isEmpty {
                    let range = try CanonicalFrameRange(
                        startFrame: previous,
                        endFrame: position,
                        durationFrames: durationFrames
                    )
                    if let last = result.last,
                       last.range.endFrame == range.startFrame,
                       last.reasons == reasons
                    {
                        result.removeLast()
                        result.append(
                            try UnavailableInterval(
                                range: CanonicalFrameRange(
                                    startFrame: last.range.startFrame,
                                    endFrame: range.endFrame,
                                    durationFrames: durationFrames
                                ),
                                reasons: reasons
                            )
                        )
                    } else {
                        result.append(try UnavailableInterval(range: range, reasons: reasons))
                    }
                }
            }

            guard let delta = boundaries[position] else { continue }
            for (reason, count) in delta.ends {
                let updated = active[reason, default: 0] - count
                if updated > 0 {
                    active[reason] = updated
                } else {
                    active.removeValue(forKey: reason)
                }
            }
            for (reason, count) in delta.starts {
                active[reason, default: 0] += count
            }
            previous = position
        }

        return result
    }
}

public enum AudioSourceKind: String, Equatable, Sendable {
    case microphone
}

public enum AudioFingerprintError: Error, Equatable, Sendable {
    case invalidSHA256
}

public struct AudioFingerprint: Hashable, Sendable, CustomStringConvertible {
    public let sha256: String

    public init(sha256: String) throws {
        guard sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              })
        else {
            throw AudioFingerprintError.invalidSHA256
        }
        self.sha256 = sha256
    }

    public var description: String { sha256 }
}

public enum SealedAudioAssetError: Error, Equatable, Sendable {
    case empty
    case exceedsMaximumDuration
    case nonCanonicalFormat
    case invalidUnavailableIntervals
    case invalidRelativeReference
}

public struct SealedAudioAsset: Equatable, Sendable {
    public let source: AudioSourceKind
    public let format: CanonicalAudioFormat
    public let frameCount: UInt64
    public let canonicalAudioPath: LibraryRelativePath
    public let fingerprint: AudioFingerprint
    public let unavailableIntervals: [UnavailableInterval]

    public init(
        source: AudioSourceKind,
        format: CanonicalAudioFormat,
        frameCount: UInt64,
        canonicalAudioPath: LibraryRelativePath,
        fingerprint: AudioFingerprint,
        unavailableIntervals: [UnavailableInterval]
    ) throws {
        guard frameCount > 0 else { throw SealedAudioAssetError.empty }
        guard frameCount <= CanonicalRecordingLimits.maximumFrames else {
            throw SealedAudioAssetError.exceedsMaximumDuration
        }
        guard format == .versionOne else {
            throw SealedAudioAssetError.nonCanonicalFormat
        }
        guard canonicalAudioPath.description == "audio/audio.wav" else {
            throw SealedAudioAssetError.invalidRelativeReference
        }
        let normalized = try UnavailableIntervalNormalizer.normalize(
            unavailableIntervals,
            durationFrames: frameCount
        )
        guard normalized == unavailableIntervals else {
            throw SealedAudioAssetError.invalidUnavailableIntervals
        }
        self.source = source
        self.format = format
        self.frameCount = frameCount
        self.canonicalAudioPath = canonicalAudioPath
        self.fingerprint = fingerprint
        self.unavailableIntervals = unavailableIntervals
    }
}

public enum SealedSessionError: Error, Equatable, Sendable {
    case invalidAudioReference
}

public struct SealedSession: Equatable, Sendable {
    public let sessionID: SessionID
    public let createdAt: UTCInstant
    public let audioManifestPath: LibraryRelativePath
    public let audio: SealedAudioAsset

    public init(
        sessionID: SessionID,
        createdAt: UTCInstant,
        audioManifestPath: LibraryRelativePath,
        audio: SealedAudioAsset
    ) throws {
        guard audioManifestPath.description == "audio/audio.json" else {
            throw SealedSessionError.invalidAudioReference
        }
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.audioManifestPath = audioManifestPath
        self.audio = audio
    }
}
