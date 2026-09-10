import "./coach-invocation.tsp";
import "./coach-provider-protocol.tsp";
import "@typespec/json-schema";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  // PORTABLE PROFILE STORAGE
  /** Complete immutable Development Profile snapshot. */
  @jsonSchema
  @id("ProfileRevision.json")
  model ProfileRevision {
    schemaVersion: 1;
    revisionId: ProfileRevisionId;
    parentRevisionId?: ProfileRevisionId;
    generation: NonnegativeWholeNumber;
    statementGeneration: NonnegativeWholeNumber;
    createdAt: UTCInstant;
    statements: PersistedProfileStatement[];
  }

  model PersistedProfileStatement {
    statementId: ProfileStatementId;
    statementKind: ProfileStatementKind;
    wording: NonEmptyText;
    supportingSessionCount: NonnegativeWholeNumber;
    evidence: PersistedEvidenceReference[];
  }

  // CHAT-OWNED PROFILE PROPOSAL STORAGE
  /** One validated reviewed Profile proposal awaiting Speaker review. */
  @jsonSchema
  @id("ProfileChangeProposal.json")
  @oneOf
  union ProfileChangeProposal {
    semanticOrMixed: SemanticOrMixedProfileChangeProposal,
    reconsideredEvidenceOnly: ReconsideredEvidenceOnlyProfileChangeProposal,
  }

  model SemanticOrMixedProfileChangeProposal {
    ...ProfileChangeProposalFields;

    @minItems(1)
    changes: ProfileProposalChange[];

    /** Standalone appends retained inside the reviewed transaction. */
    @minItems(1)
    evidenceAppends?: ProfileProposalEvidenceAppend[];
  }

  /** Evidence-only replacement created only by Reconsider and still reviewed. */
  model ReconsideredEvidenceOnlyProfileChangeProposal {
    ...ProfileChangeProposalFields;

    @maxItems(0)
    changes: ProfileProposalChange[];

    @minItems(1)
    evidenceAppends: ProfileProposalEvidenceAppend[];
  }

  model ProfileChangeProposalFields {
    schemaVersion: 1;
    proposalId: ProfileChangeProposalId;
    chatId: ChatId;
    responsePositionId: ChatResponsePositionId;
    baseProfile: ProfileProposalBase;
    createdAt: UTCInstant;
  }

  model ProfileProposalBase {
    revisionId?: ProfileRevisionId;
    statementGeneration: NonnegativeWholeNumber;
  }

  @oneOf
  union ProfileProposalChange {
    add: ProfileProposalAdd,
    replace: ProfileProposalReplace,
    retire: ProfileProposalRetire,
  }

  model ProfileProposalEvidenceAppend {
    target: ProfileProposalTarget;

    @minItems(1)
    evidence: PersistedEvidenceReference[];
  }

  // CHAT-OWNED PURE-EVIDENCE PUBLICATION STORAGE
  /** One validated pure-evidence Profile operation awaiting local publication. */
  @jsonSchema
  @id("ProfileEvidencePublication.json")
  model ProfileEvidencePublication {
    schemaVersion: 1;
    chatId: ChatId;
    responsePositionId: ChatResponsePositionId;

    @minItems(1)
    evidenceAppends: ProfileProposalEvidenceAppend[];

    createdAt: UTCInstant;
  }

  model ProfileProposalAdd {
    kind: "add";
    statement: ProfileProposedStatement;
  }

  model ProfileProposalReplace {
    kind: "replace";
    target: ProfileProposalTarget;
    replacement: ProfileProposedStatement;
  }

  model ProfileProposalRetire {
    kind: "retire";
    target: ProfileProposalTarget;

    /** Ordered evidence basis retained for Reconsider; it may be empty. */
    evidence: PersistedEvidenceReference[];
  }

  model ProfileProposalTarget {
    statementId: ProfileStatementId;
    statementKind: ProfileStatementKind;
    wording: NonEmptyText;
  }

  model ProfileProposedStatement {
    /** Allocated by Application, never by the coach. */
    statementId: ProfileStatementId;

    statementKind: ProfileStatementKind;
    wording: NonEmptyText;
    evidence: PersistedEvidenceReference[];
  }

  // PROFILE COMMIT-RECOVERY STORAGE
  /** Immutable authority required to reconcile one accepted Proposal exactly once. */
  @jsonSchema
  @id("ProfileWriteIntent.json")
  model ProfileWriteIntent {
    schemaVersion: 1;
    intentId: ProfileWriteIntentId;
    proposalId: ProfileChangeProposalId;
    chatId: ChatId;
    expectedHead: ProfileWriteExpectedHead;
    intendedRevisionId: ProfileRevisionId;
    createdAt: UTCInstant;
  }

  @oneOf
  union ProfileWriteExpectedHead {
    nullProfile: ProfileWriteExpectedNullHead,
    selectedProfile: ProfileWriteExpectedSelectedHead,
  }

  model ProfileWriteExpectedNullHead {
    generation: NonnegativeWholeNumber;
    statementGeneration: NonnegativeWholeNumber;
  }

  model ProfileWriteExpectedSelectedHead {
    generation: NonnegativeWholeNumber;
    statementGeneration: NonnegativeWholeNumber;
    revisionId: ProfileRevisionId;
    revisionSha256: Sha256Hex;
  }

  @pattern("^stm-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar ProfileStatementId extends string;

  @pattern("^pwi-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar ProfileWriteIntentId extends string;
}
