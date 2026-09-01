@_spi(CoachContextQualification) import AudoraApplication
import Foundation

private let qualificationTypes: [Any.Type] = [
    CanonicalJSONValue.self,
    CanonicalJSONMeasurementError.self,
    CanonicalJSON.self,
    CoachTokenEstimatorError.self,
    CoachTokenEstimator.self,
    CoachAttachmentProjectionPolicyError.self,
    CoachAttachmentProjectionPolicy.self,
    CoachAttachmentProjection.self,
    ChatAttachmentEvidence.self,
    ChatAttachmentEvidenceResolution.self,
    ResolvedChatAttachmentEvidence.self,
    ChatAttachmentEvidenceCatalogOutcome.self,
    ChatAttachmentEvidenceResolutionOutcome.self,
    ChatSessionAttachmentEvidenceSource.self,
    CompleteToolResponseBudgetError.self,
    CompleteToolResponseBudget.self,
    CoachContextBudget.self,
    CoachProviderDescriptor.self,
    CoachProviderFraming.self,
    CoachProviderEstimationPolicy.self,
    PreparedCoachTranscriptHandleError.self,
    PreparedCoachTranscriptHandle.self,
    PreparedCoachAttachment.self,
    PreparedCoachContext.self,
    CanonicalCoachExchange.self,
    CoachContextEstimate.self,
    CoachContextEstimationError.self,
    CoachContextPlanner.self,
    CoachProviderDescriptorValidationError.self,
    QualifiedCoachProviderDescriptor.self,
    CoachProviderDescriptorQualifier.self,
]

private func exerciseQualificationInterface(
    context: PreparedCoachContext,
    descriptor: CoachProviderDescriptor,
    policy: CoachProviderEstimationPolicy
) throws -> (Data, CoachContextEstimate) {
    let canonicalNull = CanonicalJSON.serialize(.null)
    let estimate = try CoachContextPlanner().estimate(
        context,
        descriptor: descriptor,
        policy: policy
    )
    return (canonicalNull, estimate)
}
