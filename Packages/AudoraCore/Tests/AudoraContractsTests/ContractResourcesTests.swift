import AudoraContracts
import Foundation
import XCTest

final class ContractResourcesTests: XCTestCase {
    func testEveryContractResourceLoadsFromThePackageBundle() throws {
        for resource in ContractResource.allCases {
            let data = try ContractResources.data(for: resource)
            XCTAssertFalse(data.isEmpty, resource.rawValue)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        }
    }

    func testPortableGoldenRootsContainNoMachineLocalAuthority() throws {
        let resources: [ContractResource] = [
            .portableLibraryManifestExample,
            .portableLibraryPreferencesExample,
            .portableProfileNullExample,
            .portableProfileSelectedExample,
        ]
        let forbidden = [
            "bookmark", "absolutePath", "modelPath", "cachePath", "credential",
            "permissionGrant", "hardwareId",
        ]

        for resource in resources {
            let data = try ContractResources.data(for: resource)
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            for field in forbidden {
                XCTAssertFalse(text.contains(field), "\(resource.rawValue): \(field)")
            }
        }
    }

    func testProfileHeadSchemaIsASealedNullOrSelectedStructuralUnion() throws {
        let data = try ContractResources.data(for: .profileHeadSchema)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(object["anyOf"])
        let serialized = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(serialized.contains("NullProfileHead"))
        XCTAssertTrue(serialized.contains("SelectedProfileHead"))
        XCTAssertTrue(serialized.contains("unevaluatedProperties"))
    }

    func testImportedSessionGoldensBindExactAudioBytesAndContainOnlyPortableReferences() throws {
        let audio = try ContractResources.data(for: .importedAudioManifestExample)
        let session = try ContractResources.data(for: .importedSessionManifestExample)
        let audioObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: audio) as? [String: Any]
        )
        let sessionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: session) as? [String: Any]
        )
        let original = try XCTUnwrap(audioObject["original"] as? [String: Any])
        let canonical = try XCTUnwrap(audioObject["canonical"] as? [String: Any])

        XCTAssertEqual(sessionObject["audioManifestSha256"] as? String, SHA256Fixture.hex(audio))
        XCTAssertEqual(sessionObject["transcriptRevisionIds"] as? [String], [])
        XCTAssertNil(sessionObject["selectedTranscriptRevisionId"])
        XCTAssertEqual(original["relativePath"] as? String, "audio/original.wav")
        XCTAssertEqual(canonical["relativePath"] as? String, "audio/audio.wav")
        XCTAssertEqual(canonical["encoding"] as? String, "pcmS16LE")
        XCTAssertEqual(canonical["sampleRateHz"] as? Int, 16_000)
        XCTAssertEqual(canonical["channelCount"] as? Int, 1)
        XCTAssertEqual(canonical["bitsPerSample"] as? Int, 16)
        XCTAssertEqual(canonical["byteCount"] as? Int, 50)
        XCTAssertEqual(canonical["frameCount"] as? Int, 3)

        let combined = try XCTUnwrap(String(data: audio + session, encoding: .utf8))
        for forbidden in [
            "bookmark", "absolutePath", "modelPath", "cachePath", "credential",
            "permissionGrant", "hardwareId", "file://", "/Users/", "\\",
        ] {
            XCTAssertFalse(combined.contains(forbidden), forbidden)
        }
    }

    func testAudioSchemasSealRootsAndEncodeContainerCodecUnionAndV1Limits() throws {
        let audio = try ContractResources.data(for: .audioManifestSchema)
        let session = try ContractResources.data(for: .sessionManifestSchema)
        let vectors = try ContractResources.data(for: .audioNormalizationVectorsSchema)
        let serialized = try XCTUnwrap(
            String(data: audio + session + vectors, encoding: .utf8)
        )

        XCTAssertTrue(serialized.contains("unevaluatedProperties"))
        XCTAssertTrue(serialized.contains("WAVOriginalAudioArtifact"))
        XCTAssertTrue(serialized.contains("AACOriginalAudioArtifact"))
        XCTAssertTrue(serialized.contains("ALACOriginalAudioArtifact"))
        XCTAssertTrue(serialized.contains("pcmS16LE"))
        XCTAssertTrue(serialized.contains("43200000"))
        XCTAssertTrue(serialized.contains("2700000"))
        let sessionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: session) as? [String: Any]
        )
        let properties = try XCTUnwrap(sessionObject["properties"] as? [String: Any])
        XCTAssertNil(properties["selectedTranscriptRevisionId"])
    }

    func testNormalizationGoldenLocksDownmixQuantizerAndExactDurationBoundary() throws {
        let data = try ContractResources.data(for: .audioNormalizationVectorsExample)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let downmix = try XCTUnwrap(object["downmixVectors"] as? [[String: Any]])
        let quantization = try XCTUnwrap(
            object["quantizationVectors"] as? [[String: Any]]
        )
        let durations = try XCTUnwrap(
            object["frameDurationVectors"] as? [[String: Any]]
        )

        XCTAssertEqual(downmix.count, 3)
        XCTAssertEqual(quantization.first?["output"] as? Int, -32_768)
        XCTAssertEqual(quantization.last?["output"] as? Int, 32_767)
        XCTAssertEqual(durations.first?["frameCount"] as? Int, 1)
        XCTAssertEqual(durations.first?["durationMs"] as? Int, 1)
        XCTAssertEqual(durations.last?["frameCount"] as? Int, 43_200_000)
        XCTAssertEqual(durations.last?["durationMs"] as? Int, 2_700_000)
    }
}

private enum SHA256Fixture {
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hex(_ data: Data) -> String {
        var message = Array(data)
        let bitCount = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
        }

        var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                words[index] = UInt32(message[offset]) << 24 |
                    UInt32(message[offset + 1]) << 16 |
                    UInt32(message[offset + 2]) << 8 |
                    UInt32(message[offset + 3])
            }
            for index in 16..<64 {
                let s0 = rotate(words[index - 15], by: 7) ^
                    rotate(words[index - 15], by: 18) ^
                    (words[index - 15] >> 3)
                let s1 = rotate(words[index - 2], by: 17) ^
                    rotate(words[index - 2], by: 19) ^
                    (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ s0 &+
                    words[index - 7] &+ s1
            }
            var working = state
            for index in 0..<64 {
                let s1 = rotate(working[4], by: 6) ^ rotate(working[4], by: 11) ^
                    rotate(working[4], by: 25)
                let choice = (working[4] & working[5]) ^ (~working[4] & working[6])
                let temporary1 = working[7] &+ s1 &+ choice &+
                    constants[index] &+ words[index]
                let s0 = rotate(working[0], by: 2) ^ rotate(working[0], by: 13) ^
                    rotate(working[0], by: 22)
                let majority = (working[0] & working[1]) ^
                    (working[0] & working[2]) ^ (working[1] & working[2])
                let temporary2 = s0 &+ majority
                working = [
                    temporary1 &+ temporary2,
                    working[0], working[1], working[2],
                    working[3] &+ temporary1,
                    working[4], working[5], working[6],
                ]
            }
            for index in 0..<8 { state[index] &+= working[index] }
        }
        return state.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotate(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
