import "./development-chat.tsp";
import "@typespec/json-schema";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  @jsonSchema
  @id("ChatMessage.json")
  union ChatMessage {
    legacyUser: PersistedUserChatMessageV1,
    legacyCoach: PersistedCoachChatMessageV1,
    user: PersistedUserChatMessageV2,
    coach: PersistedCoachChatMessageV2,
  }

  model PersistedUserChatMessageV1 {
    ...PersistedChatMessageFieldsV1;
    role: "user";

    /** Legacy v1 used the 32,768-byte Draft ceiling; runtime preserves that reopen bound. */
    @maxLength(32768)
    text: string;
  }

  model PersistedCoachChatMessageV1 {
    ...PersistedChatMessageFieldsV1;
    role: "coach";

    /** Persistence also rejects an exact encoded envelope above its 64 KiB root cap. */
    @maxLength(64000)
    markdown: string;
  }

  model PersistedUserChatMessageV2 {
    ...PersistedChatMessageFieldsV2;
    role: "user";

    /** Application additionally enforces a 16,384 UTF-8-byte ceiling. */
    @maxLength(16384)
    text: string;
  }

  model PersistedCoachChatMessageV2 {
    ...PersistedChatMessageFieldsV2;
    role: "coach";

    /** Exact Profile authority used to prepare this Coach response. */
    profileRevisionId?: ProfileRevisionId;

    profileStatementGeneration: NonnegativeWholeNumber;

    /** Persistence also rejects an exact encoded envelope above its 64 KiB root cap. */
    @maxLength(64000)
    markdown: string;
  }

  model PersistedChatMessageFieldsV1 {
    schemaVersion: 1;
    messageId: ChatMessageId;
    responsePositionId: ChatResponsePositionId;
    createdAt: UTCInstant;
  }

  model PersistedChatMessageFieldsV2 {
    schemaVersion: 2;
    messageId: ChatMessageId;
    responsePositionId: ChatResponsePositionId;
    createdAt: UTCInstant;
  }

  @jsonSchema
  @id("CoachInvocation.json")
  union CoachInvocation {
    legacyV1: CoachInvocationV1,
    legacyV2: CoachInvocationV2,
    current: CoachInvocationV3,
  }

  model CoachInvocationV1 {
    ...LegacyCoachInvocationFields;
    schemaVersion: 1;
  }

  model CoachInvocationV2 {
    ...LegacyCoachInvocationFields;
    schemaVersion: 2;
    profileRevisionId?: ProfileRevisionId;
    profileStatementGeneration: NonnegativeWholeNumber;
  }

  model CoachInvocationV3 {
    ...CoachInvocationFields;
    schemaVersion: 3;
    profileRevisionId?: ProfileRevisionId;
    profileStatementGeneration: NonnegativeWholeNumber;
    terminalFailure?: CoachInvocationTerminalFailure;

    @minItems(1)
    @maxItems(4)
    attempts: CoachProviderAttempt[];
  }

  model LegacyCoachInvocationFields {
    ...CoachInvocationFields;
    attemptId: CoachProviderAttemptId;
    providerIdempotencyValue: ProviderIdempotencyValue;
  }

  model CoachInvocationFields {
    invocationId: CoachInvocationId;
    libraryId: LibraryId;
    chatId: ChatId;
    pendingUserTurnId: PendingUserTurnId;
    draftId: ChatDraftId;
    draftVersion: NonnegativeWholeNumber;
    responsePositionId: ChatResponsePositionId;
    expectedManifestRevision: NonnegativeWholeNumber;
    admittedAt: UTCInstant;
  }

  model CoachProviderAttempt {
    attemptId: CoachProviderAttemptId;

    @minValue(1)
    @maxValue(4)
    ordinal: integer;

    kind: CoachProviderAttemptKind;
    userMessageId: ChatMessageId;
    coachMessageId: ChatMessageId;
    freshDraftId: ChatDraftId;
  }

  union CoachProviderAttemptKind {
    standard: "standard",
    shorterRepair: "shorterRepair",
  }

  union CoachInvocationTerminalFailure {
    coachResponseInterrupted: "coachResponseInterrupted",
    coachProviderError: "coachProviderError",
    coachResponseInvalid: "coachResponseInvalid",
  }

  @pattern("^inv-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar CoachInvocationId extends string;

  @pattern("^atm-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar CoachProviderAttemptId extends string;

  @minLength(1)
  @maxLength(128)
  @pattern("^[0-9A-Za-z._-]+$")
  scalar ProviderIdempotencyValue extends string;

  @jsonSchema
  @id("InvocationAdmissionLedger.json")
  model InvocationAdmissionLedger {
    schemaVersion: 1;

    @maxItems(4096)
    entries: InvocationAdmissionEntry[];
  }

  model InvocationAdmissionEntry {
    libraryId: LibraryId;
    lastAdmittedAt: UTCInstant;
  }
}
