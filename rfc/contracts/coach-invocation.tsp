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
    legacy: CoachInvocationV1,
    current: CoachInvocationV2,
  }

  model CoachInvocationV1 {
    ...CoachInvocationFields;
    schemaVersion: 1;
  }

  model CoachInvocationV2 {
    ...CoachInvocationFields;
    schemaVersion: 2;
    profileRevisionId?: ProfileRevisionId;
    profileStatementGeneration: NonnegativeWholeNumber;
  }

  model CoachInvocationFields {
    invocationId: CoachInvocationId;
    attemptId: CoachProviderAttemptId;
    providerIdempotencyValue: ProviderIdempotencyValue;
    libraryId: LibraryId;
    chatId: ChatId;
    pendingUserTurnId: PendingUserTurnId;
    draftId: ChatDraftId;
    draftVersion: NonnegativeWholeNumber;
    responsePositionId: ChatResponsePositionId;
    expectedManifestRevision: NonnegativeWholeNumber;
    admittedAt: UTCInstant;
  }

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

  @pattern("^inv-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar CoachInvocationId extends string;

  @pattern("^atm-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar CoachProviderAttemptId extends string;

  @minLength(1)
  @maxLength(128)
  @pattern("^[0-9A-Za-z._-]+$")
  scalar ProviderIdempotencyValue extends string;
}
