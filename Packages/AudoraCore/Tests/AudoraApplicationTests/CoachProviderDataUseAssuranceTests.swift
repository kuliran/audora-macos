@testable @_spi(CoachContextQualification) import AudoraApplication
import Foundation
import XCTest

final class CoachProviderDataUseAssuranceTests: XCTestCase {
    func testProhibitedAssuranceIsBoundIntoQualifiedConfiguration() throws {
        let binding = try CoachProviderConfigurationBinding(
            descriptor: Self.descriptor,
            policy: policy(dataUseAssurance: .testProhibited)
        )

        XCTAssertEqual(binding.dataUseAssurance, .testProhibited)
        XCTAssertTrue(
            binding.dataUseAssurance
                .submittedContentTrainingAndModelImprovementProhibited
        )
    }

    func testMissingAssuranceIsRejected() throws {
        XCTAssertThrowsError(
            try CoachProviderConfigurationBinding(
                descriptor: Self.descriptor,
                policy: policy(dataUseAssurance: nil)
            )
        ) { error in
            XCTAssertEqual(
                error as? CoachProviderConfigurationBindingError,
                .missingDataUseAssurance
            )
        }
        XCTAssertThrowsError(
            try CoachContextConfiguration(
                descriptor: Self.descriptor,
                policy: policy(dataUseAssurance: nil)
            )
        ) { error in
            XCTAssertEqual(
                error as? CoachContextConfigurationError,
                .invalidDescriptor(.missingDataUseAssurance)
            )
        }
    }

    func testNonProhibitedAssuranceIsRejected() throws {
        let assurance = try CoachProviderDataUseAssurance(
            identifier: "test-training-permitted-v1",
            policyReference: "urn:audora:test:training-permitted:v1",
            policySHA256: String(repeating: "c", count: 64),
            submittedContentTrainingAndModelImprovementProhibited: false
        )

        XCTAssertThrowsError(
            try CoachProviderConfigurationBinding(
                descriptor: Self.descriptor,
                policy: policy(dataUseAssurance: assurance)
            )
        ) { error in
            XCTAssertEqual(
                error as? CoachProviderConfigurationBindingError,
                .submittedContentTrainingAndModelImprovementNotProhibited
            )
        }
        XCTAssertThrowsError(
            try CoachContextConfiguration(
                descriptor: Self.descriptor,
                policy: policy(dataUseAssurance: assurance)
            )
        ) { error in
            XCTAssertEqual(
                error as? CoachContextConfigurationError,
                .invalidDescriptor(
                    .submittedContentTrainingAndModelImprovementNotProhibited
                )
            )
        }
    }

    func testInvalidAssuranceIdentityReferenceAndDigestAreRejected() {
        XCTAssertThrowsError(
            try assurance(identifier: "contains spaces")
        ) { error in
            XCTAssertEqual(
                error as? CoachProviderDataUseAssuranceError,
                .invalidIdentifier
            )
        }
        XCTAssertThrowsError(
            try assurance(policyReference: "https://example.test/policy with space")
        ) { error in
            XCTAssertEqual(
                error as? CoachProviderDataUseAssuranceError,
                .invalidPolicyReference
            )
        }
        XCTAssertThrowsError(
            try assurance(policySHA256: "not-a-sha256")
        ) { error in
            XCTAssertEqual(
                error as? CoachProviderDataUseAssuranceError,
                .invalidPolicySHA256
            )
        }
    }

    private func policy(
        dataUseAssurance: CoachProviderDataUseAssurance?
    ) -> CoachProviderEstimationPolicy {
        CoachProviderEstimationPolicy(
            providerIdentifier: "data-use-assurance-test-provider-v1",
            responseCollectorByteCeiling: 8_192,
            framing: .testZero,
            attachmentProjectionPolicy: try! CoachAttachmentProjectionPolicy(
                maximumInlineTranscriptTokens: 1_024,
                tokenEstimator: .utf8ByteUpperBound()
            ),
            dataUseAssurance: dataUseAssurance
        )
    }

    private func assurance(
        identifier: String = "test-no-training-v1",
        policyReference: String = "urn:audora:test:no-training:v1",
        policySHA256: String = String(repeating: "a", count: 64)
    ) throws -> CoachProviderDataUseAssurance {
        try CoachProviderDataUseAssurance(
            identifier: identifier,
            policyReference: policyReference,
            policySHA256: policySHA256,
            submittedContentTrainingAndModelImprovementProhibited: true
        )
    }

    private static let descriptor = CoachProviderDescriptor(
        displayName: "Data-use assurance fixture",
        contextBudget: CoachContextBudget(
            contextWindowTokens: 4_096,
            responseReservedTokens: 512,
            safetyMarginTokens: 128
        ),
        coachMemoryMaxTokens: 256
    )
}
