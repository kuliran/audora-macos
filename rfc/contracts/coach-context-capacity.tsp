import "./portable-library.tsp";
import "@typespec/json-schema";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  /** App-only advisory projection. It is not a provider request or durable Chat record. */
  @jsonSchema
  @id("CoachContextQuote.json")
  model CoachContextQuote {
    schemaVersion: 1;
    maximumUserMessageUtf8Bytes: 16384;
    completeInputTokens: NonnegativeWholeNumber;
    inputCeilingTokens: PositiveWholeNumber;
    responseReservedTokens: PositiveWholeNumber;
    safetyMarginTokens: NonnegativeWholeNumber;
    totalContextTokens: PositiveWholeNumber;
    fits: boolean;
    messageLength: CoachContextMessageLength;

    @minItems(9)
    @maxItems(9)
    categoryCosts: CoachContextCategoryCost[];

    @minLength(1)
    estimatorIdentifier: string;

    estimatorMode: CoachContextEstimatorMode;
  }

  @oneOf
  union CoachContextMessageLength {
    eligible: CoachContextEligibleMessage,
    mustShorten: CoachContextMessageMustShorten,
  }

  model CoachContextEligibleMessage {
    status: "eligible";
  }

  model CoachContextMessageMustShorten {
    status: "mustShorten";
    maximumUtf8Bytes: 16384;
  }

  model CoachContextCategoryCost {
    category: CoachContextCostCategory;
    utf8ByteCount: NonnegativeWholeNumber;
    estimatedTokenCount: NonnegativeWholeNumber;
  }

  union CoachContextCostCategory {
    profile: "profile",
    memory: "memory",
    history: "history",
    draft: "draft",
    framing: "framing",
    attachments: "attachments",
    transcriptExchange: "transcriptExchange",
    responseReserve: "responseReserve",
    safetyMargin: "safetyMargin",
  }

  union CoachContextEstimatorMode {
    exact: "exact",
    conservativeUpperBound: "conservativeUpperBound",
  }
}
