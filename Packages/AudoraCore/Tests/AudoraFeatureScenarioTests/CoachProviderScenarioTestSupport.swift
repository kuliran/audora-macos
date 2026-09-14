@testable @_spi(CoachContextQualification) @_spi(InvocationInfrastructure) import AudoraApplication
import Foundation

extension CoachProviderCompleteResponse {
    static func scenarioMarkdown(_ markdown: String) -> Self {
        CoachProviderCompleteResponse(
            body: CanonicalJSON.serialize(
                .object([
                    "messageBlocks": .array([
                        .object([
                            "kind": .string("markdown"),
                            "markdown": .string(markdown),
                        ]),
                    ]),
                ])
            )
        )
    }
}
