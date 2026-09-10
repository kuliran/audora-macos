import "./chat.tsp";
import "@typespec/json-schema";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  /** Durable Chat-owned authority for one Reconsider Invocation. */
  @jsonSchema
  @id("ProfileReconsideration.json")
  @oneOf
  union ProfileReconsideration {
    legacyActive: LegacyActiveProfileReconsideration,
    legacyFailed: LegacyFailedProfileReconsideration,
    legacyTranscriptReadFailed: LegacyTranscriptReadFailedProfileReconsideration,
    active: ActiveProfileReconsideration,
    failed: FailedProfileReconsideration,
    transcriptReadFailed: TranscriptReadFailedProfileReconsideration,
  }

  model ActiveProfileReconsideration {
    ...ProfileReconsiderationFields;
  }

  model FailedProfileReconsideration {
    ...ProfileReconsiderationFields;
    failure: ProfileReconsiderationFailure;
  }

  model TranscriptReadFailedProfileReconsideration {
    ...ProfileReconsiderationFields;
    failure: "coachTranscriptReadFailed";
    transcriptReadFailure: CoachTranscriptReadFailureSummary;
  }

  model LegacyActiveProfileReconsideration {
    ...LegacyProfileReconsiderationFields;
  }

  model LegacyFailedProfileReconsideration {
    ...LegacyProfileReconsiderationFields;
    failure: ProfileReconsiderationFailure;
  }

  model LegacyTranscriptReadFailedProfileReconsideration {
    ...LegacyProfileReconsiderationFields;
    failure: "coachTranscriptReadFailed";
    transcriptReadFailure: CoachTranscriptReadFailureSummary;
  }

  model ProfileReconsiderationFields {
    schemaVersion: 2;
    sourceEffectIdentity: ChatProfileEffectIdentity;
    resultResponsePositionId: ChatResponsePositionId;
    preparedProfileStatementGeneration?: NonnegativeWholeNumber;
  }

  model LegacyProfileReconsiderationFields {
    schemaVersion: 1;
    sourceEffectIdentity: ChatProfileEffectIdentity;
    resultResponsePositionId: ChatResponsePositionId;
  }

  @oneOf
  union ChatProfileEffectIdentity {
    proposal: ChatProfileProposalEffectIdentity,
    evidencePublication: ChatProfileEvidencePublicationEffectIdentity,
  }

  model ChatProfileProposalEffectIdentity {
    kind: "proposal";
    proposalId: ProfileChangeProposalId;
  }

  model ChatProfileEvidencePublicationEffectIdentity {
    kind: "evidencePublication";
    responsePositionId: ChatResponsePositionId;
  }

  union ProfileReconsiderationFailure {
    coachContextCannotFit: "coachContextCannotFit",
    coachResponseInterrupted: "coachResponseInterrupted",
    coachProviderError: "coachProviderError",
    coachResponseInvalid: "coachResponseInvalid",
  }

  @pattern("^prp-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar ProfileChangeProposalId extends string;
}
