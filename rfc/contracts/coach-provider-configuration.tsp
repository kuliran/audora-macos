import "./coach-provider-shared.tsp";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  // APPLICATION ONLY
  /** Capabilities and limits for one configured Coach Provider. */
  @jsonSchema
  @id("CoachProviderDescriptor.json")
  model CoachProviderDescriptor {
    displayName: NonEmptyText;
    contextBudget: CoachContextBudget;

    /** Hard token ceiling for one replacement Coach Memory. */
    @minValue(1)
    coachMemoryMaxTokens: int32;
  }

  model CoachContextBudget {
    @minValue(1)
    contextWindowTokens: int32;

    /** Space preserved for the current response. */
    @minValue(1)
    responseReservedTokens: int32;

    /** Allowance for provider framing and estimation uncertainty. */
    @minValue(0)
    safetyMarginTokens: int32;
  }
}
