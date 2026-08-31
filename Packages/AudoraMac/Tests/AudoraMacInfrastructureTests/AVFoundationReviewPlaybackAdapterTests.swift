import AudoraApplication
import AudoraDomain
@testable import AudoraMacInfrastructure
import Foundation
import XCTest

final class AVFoundationReviewPlaybackAdapterTests: XCTestCase {
    func testLoadsOnlyResolvedCanonicalAudioAndClampsSeeks() async throws {
        let selection = ReviewSelection(
            scope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T120000000Z-1ABC")
            ),
            sessionID: try SessionID("ses-20260830T120000000Z-2DEF")
        )
        let capabilityID = try ReviewAudioCapabilityID("review-synthetic")
        let source = ReviewAudioSource(
            selection: selection,
            audioCapabilityID: capabilityID,
            durationMilliseconds: 100
        )
        let adapter = AVFoundationReviewPlaybackAdapter(
            resolver: SyntheticReviewAudioResolver(
                source: source,
                canonicalWAV: canonicalWAV(frameCount: 1_600)
            )
        )

        let loaded = await adapter.load(source)
        XCTAssertEqual(
            loaded,
            ReviewPlaybackSnapshot(
                audioCapabilityID: capabilityID,
                positionMilliseconds: 0,
                durationMilliseconds: 100,
                status: .paused
            )
        )
        let midpoint = await adapter.seek(toMilliseconds: 50)
        XCTAssertEqual(midpoint?.positionMilliseconds, 50)
        let clamped = await adapter.seek(toMilliseconds: 500)
        XCTAssertEqual(clamped?.positionMilliseconds, 100)
        XCTAssertEqual(clamped?.status, .ended)
    }

    func testRejectsUnresolvedCapability() async throws {
        let source = ReviewAudioSource(
            selection: ReviewSelection(
                scope: LibraryScope(
                    libraryID: try LibraryID("lib-20260830T120000000Z-1ABC")
                ),
                sessionID: try SessionID("ses-20260830T120000000Z-2DEF")
            ),
            audioCapabilityID: try ReviewAudioCapabilityID("review-missing"),
            durationMilliseconds: 100
        )
        let adapter = AVFoundationReviewPlaybackAdapter(
            resolver: SyntheticReviewAudioResolver(source: nil, canonicalWAV: Data())
        )

        let loaded = await adapter.load(source)
        let played = await adapter.play()
        XCTAssertNil(loaded)
        XCTAssertNil(played)
    }
}

private struct SyntheticReviewAudioResolver: ReviewCanonicalAudioResolving {
    let source: ReviewAudioSource?
    let canonicalWAV: Data

    func resolveCanonicalAudio(for source: ReviewAudioSource) async -> Data? {
        source == self.source ? canonicalWAV : nil
    }
}

private func canonicalWAV(frameCount: UInt32) -> Data {
    let payloadBytes = frameCount * 2
    var data = Data()
    data.append(contentsOf: "RIFF".utf8)
    data.appendLittleEndian(36 + payloadBytes)
    data.append(contentsOf: "WAVEfmt ".utf8)
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt32(16_000))
    data.appendLittleEndian(UInt32(32_000))
    data.appendLittleEndian(UInt16(2))
    data.appendLittleEndian(UInt16(16))
    data.append(contentsOf: "data".utf8)
    data.appendLittleEndian(payloadBytes)
    data.append(Data(repeating: 0, count: Int(payloadBytes)))
    return data
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
