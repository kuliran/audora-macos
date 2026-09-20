@testable @_spi(CoachContextQualification) import AudoraApplication
import Foundation

extension CoachProviderFraming {
    static let testZero = CoachProviderFraming(
        initialRequestPrefix: Data(),
        initialRequestSuffix: Data(),
        transcriptReadRequestPrefix: Data(),
        transcriptReadRequestSuffix: Data(),
        transcriptReadResponsePrefix: Data(),
        transcriptReadResponseSuffix: Data(),
        minimumResponsePrefix: Data(),
        minimumResponseSuffix: Data(),
        initialRequestHiddenTokens: 0,
        transcriptReadExchangeHiddenTokens: 0,
        minimumResponseHiddenTokens: 0
    )
}

extension CoachProviderDataUseAssurance {
    static let testProhibited = try! CoachProviderDataUseAssurance(
        identifier: "test-no-training-v1",
        policyReference: "urn:audora:test:no-training:v1",
        policySHA256: String(repeating: "a", count: 64),
        submittedContentTrainingAndModelImprovementProhibited: true
    )
}
