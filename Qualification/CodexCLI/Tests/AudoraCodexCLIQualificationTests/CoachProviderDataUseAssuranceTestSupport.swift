@testable @_spi(CoachContextQualification) import AudoraApplication
import Foundation

extension CoachProviderDataUseAssurance {
    static let testProhibited = try! CoachProviderDataUseAssurance(
        identifier: "test-no-training-v1",
        policyReference: "urn:audora:test:no-training:v1",
        policySHA256: String(repeating: "a", count: 64),
        submittedContentTrainingAndModelImprovementProhibited: true
    )
}
