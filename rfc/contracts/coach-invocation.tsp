import "./development-chat.tsp";
import "@typespec/json-schema";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  @jsonSchema
  @id("ChatMessage.json")
  union ChatMessage {
    user: PersistedUserChatMessage,
    coach: PersistedCoachChatMessage,
  }

  model PersistedUserChatMessage {
    ...PersistedChatMessageFields;
    role: "user";

    /** Application additionally enforces a 16,384 UTF-8-byte ceiling. */
    @maxLength(16384)
    text: string;
  }

  model PersistedCoachChatMessage {
    ...PersistedChatMessageFields;
    role: "coach";

    /** Persistence also rejects an exact encoded envelope above its 64 KiB root cap. */
    @maxLength(64000)
    markdown: string;
  }

  model PersistedChatMessageFields {
    schemaVersion: 1;
    messageId: ChatMessageId;
    responsePositionId: ChatResponsePositionId;
    createdAt: UTCInstant;
  }

  @jsonSchema
  @id("CoachInvocation.json")
  model CoachInvocation {
    schemaVersion: 1;
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
