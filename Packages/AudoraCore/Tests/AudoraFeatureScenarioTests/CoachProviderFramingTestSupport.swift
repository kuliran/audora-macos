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
