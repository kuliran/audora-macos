import "./portable-library.tsp";
import "@typespec/json-schema";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  @jsonSchema
  @id("ChatManifest.json")
  union ChatManifest {
    newChat: NewChatManifest,
    sessionAnalysis: SessionAnalysisChatManifest,
  }

  model NewChatManifest {
    ...ChatManifestFields;
    creationKind: "newChat";
  }

  model SessionAnalysisChatManifest {
    ...ChatManifestFields;
    creationKind: "sessionAnalysis";
    originAttachmentId: ChatSessionAttachmentId;
  }

  model ChatManifestFields {
    schemaVersion: 1;
    chatId: ChatId;
    manifestRevision: NonnegativeWholeNumber;
    title: ChatTitleText;
    createdAt: UTCInstant;
    updatedAt: UTCInstant;
    profileStatementGenerationAtCreation: NonnegativeWholeNumber;
    attachments: ChatSessionAttachment[];
    draft: PersistedChatDraft;
    messageIds: ChatMessageId[];
    currentMemoryId: CoachMemoryId;
  }

  model ChatSessionAttachment {
    attachmentId: ChatSessionAttachmentId;
    sessionId: SessionId;
    transcriptRevisionId: TranscriptRevisionId;
  }

  model PersistedChatDraft {
    draftId: ChatDraftId;
    version: NonnegativeWholeNumber;
    text: ChatDraftText;
    updatedAt: UTCInstant;
  }

  @jsonSchema
  @id("PendingUserTurn.json")
  model PendingUserTurn {
    schemaVersion: 1;
    pendingUserTurnId: PendingUserTurnId;
    draftId: ChatDraftId;
    draftVersion: NonnegativeWholeNumber;
    responsePositionId: ChatResponsePositionId;
    failure?: PendingUserTurnFailure;
  }

  union PendingUserTurnFailure {
    coachContextCannotFit: "coachContextCannotFit",
    coachResponseInterrupted: "coachResponseInterrupted",
  }

  @pattern("^cht-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar ChatId extends string;

  @pattern("^drf-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar ChatDraftId extends string;

  @pattern("^ptu-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar PendingUserTurnId extends string;

  @pattern("^rsp-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar ChatResponsePositionId extends string;

  @pattern("^mem-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar CoachMemoryId extends string;

  @pattern("^msg-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar ChatMessageId extends string;

  @minLength(1)
  @maxLength(64)
  @pattern("^[0-9A-Za-z_-]+$")
  scalar ChatSessionAttachmentId extends string;

  @minLength(1)
  @maxLength(256)
  scalar ChatTitleText extends string;

  @maxLength(32768)
  scalar ChatDraftText extends string;

  @jsonSchema
  @id("CoachMemoryEnvelope.json")
  model CoachMemoryEnvelope {
    schemaVersion: 1;
    memoryId: CoachMemoryId;
    chatId: ChatId;

    @maxLength(32768)
    generalNotes: string;

    sessionSummaries: PersistedCoachMemorySessionSummary[];
  }

  model PersistedCoachMemorySessionSummary {
    sessionAttachmentId: ChatSessionAttachmentId;

    @maxLength(32768)
    notes: string;
  }

  /** Portable zero-Session Development Chat behavior shared by feature implementations. */
  @jsonSchema
  @id("DevelopmentChatFeatureScenario.json")
  model DevelopmentChatFeatureScenario {
    schemaVersion: 1;
    scenarioId: string;
    libraryId: LibraryId;
    initialChats: DevelopmentChatScenarioSnapshot[];
    commands: DevelopmentChatScenarioCommand[];
    dependencyTrace: DevelopmentChatDependencyEvent[];
    expectedState: DevelopmentChatScenarioState;
    expectedProviderCalls: NonnegativeWholeNumber;
    expectedInvocationCalls: NonnegativeWholeNumber;
    expectedAdmissionCalls: NonnegativeWholeNumber;
    providerAvailability?: DevelopmentChatScenarioProviderAvailability;
    contextCapacityMode?: DevelopmentChatScenarioContextCapacityMode;
    suspendedEffect?: DevelopmentChatScenarioSuspendedEffect;
  }

  model DevelopmentChatScenarioSnapshot {
    chatId: ChatId;
    draftId: ChatDraftId;
    memoryId: CoachMemoryId;
    manifestRevision: NonnegativeWholeNumber;
    title: ChatTitleText;
    createdAt: UTCInstant;
    updatedAt: UTCInstant;
    creationKind: "newChat";
    attachments: ChatSessionAttachment[];
    draftText: ChatDraftText;
    draftVersion: NonnegativeWholeNumber;
    messageIds: ChatMessageId[];
    memoryGeneralNotes: string;
    memorySessionSummaries: PersistedCoachMemorySessionSummary[];
  }

  @oneOf
  union DevelopmentChatScenarioCommand {
    createDevelopmentChat: CreateDevelopmentChatScenarioCommand,
    rename: RenameDevelopmentChatScenarioCommand,
    setFilter: SetDevelopmentChatFilterScenarioCommand,
    open: OpenDevelopmentChatScenarioCommand,
    editDraft: EditDevelopmentChatDraftScenarioCommand,
    refreshContextQuote: RefreshDevelopmentChatContextQuoteScenarioCommand,
    sendDraft: SendDevelopmentChatDraftScenarioCommand,
    retryPendingUserTurn: RetryPendingUserTurnScenarioCommand,
    createNewChatFromCapacityFailure: CreateNewChatFromCapacityFailureScenarioCommand,
    discardPendingUserTurn: DiscardPendingUserTurnScenarioCommand,
    start: StartDevelopmentChatScenarioCommand,
  }

  @oneOf
  union DevelopmentChatDependencyEvent {
    catalogLoaded: ChatStoreCatalogLoadedEvent,
    catalogFailed: ChatStoreCatalogFailedEvent,
    chatLoaded: ChatStoreChatLoadedEvent,
    chatFrozen: ChatStoreChatFrozenEvent,
    chatCreated: ChatStoreChatCreatedEvent,
    createCollision: ChatStoreCreateCollisionEvent,
    chatRenamed: ChatStoreChatRenamedEvent,
    renameStale: ChatStoreRenameStaleEvent,
    draftSaved: ChatStoreDraftSavedEvent,
    pendingUserTurnLocked: ChatStorePendingUserTurnLockedEvent,
    pendingUserTurnReplaced: ChatStorePendingUserTurnReplacedEvent,
    pendingUserTurnDiscarded: ChatStorePendingUserTurnDiscardedEvent,
    profileStatementGenerationRead: ProfileStatementGenerationReadEvent,
    currentInstantRead: CurrentInstantReadEvent,
    chatIdGenerated: ChatIdGeneratedEvent,
    chatDraftIdGenerated: ChatDraftIdGeneratedEvent,
    coachMemoryIdGenerated: CoachMemoryIdGeneratedEvent,
    pendingUserTurnIdGenerated: PendingUserTurnIdGeneratedEvent,
    chatResponsePositionIdGenerated: ChatResponsePositionIdGeneratedEvent,
  }

  model DevelopmentChatScenarioState {
    allChatIds: ChatId[];
    visibleChatIds: ChatId[];
    catalogStatus?: DevelopmentChatScenarioCatalogStatus;
    selectedChatId?: ChatId;
    selectedTitle?: ChatTitleText;
    selectedRevision?: NonnegativeWholeNumber;
    selectedAvailability?: DevelopmentChatScenarioSelectionAvailability;
    selectedFrozenReason?: DevelopmentChatScenarioFrozenReason;
    selectedDraftText?: ChatDraftText;
    selectedDraftVersion?: NonnegativeWholeNumber;
    selectedMessageIds?: ChatMessageId[];
    composerStatus?: DevelopmentChatScenarioComposerStatus;
    pendingUserTurnId?: PendingUserTurnId;
    responsePositionId?: ChatResponsePositionId;
    pendingFailure?: PendingUserTurnFailure;
    notice?: DevelopmentChatScenarioNotice;
  }

  model CreateDevelopmentChatScenarioCommand {
    kind: "createDevelopmentChat";
  }

  model RenameDevelopmentChatScenarioCommand {
    kind: "rename";
    chatId: ChatId;
    title: string;
    expectedRevision: NonnegativeWholeNumber;
  }

  model SetDevelopmentChatFilterScenarioCommand {
    kind: "setFilter";
    query: string;
  }

  model OpenDevelopmentChatScenarioCommand {
    kind: "open";
    chatId: ChatId;
  }

  model EditDevelopmentChatDraftScenarioCommand {
    kind: "editDraft";
    text: ChatDraftText;
  }

  model SendDevelopmentChatDraftScenarioCommand {
    kind: "sendDraft";
  }

  model RefreshDevelopmentChatContextQuoteScenarioCommand {
    kind: "refreshContextQuote";
  }

  model DiscardPendingUserTurnScenarioCommand {
    kind: "discardPendingUserTurn";
    pendingUserTurnId: PendingUserTurnId;
  }

  model RetryPendingUserTurnScenarioCommand {
    kind: "retryPendingUserTurn";
    pendingUserTurnId: PendingUserTurnId;
  }

  model CreateNewChatFromCapacityFailureScenarioCommand {
    kind: "createNewChatFromCapacityFailure";
    pendingUserTurnId: PendingUserTurnId;
  }

  model StartDevelopmentChatScenarioCommand {
    kind: "start";
    libraryId: LibraryId;
  }

  model ChatStoreCatalogLoadedEvent {
    port: "chatStore";
    effect: "loadCatalog";
    outcome: "loaded";
    libraryId?: LibraryId;
    chatIds?: ChatId[];
  }

  model ChatStoreCatalogFailedEvent {
    port: "chatStore";
    effect: "loadCatalog";
    outcome: "failed";
    reason: "wrongLibrary";
    libraryId?: LibraryId;
  }

  model ChatStoreChatLoadedEvent {
    port: "chatStore";
    effect: "load";
    outcome: "loaded";
  }

  model ChatStoreChatFrozenEvent {
    port: "chatStore";
    effect: "load";
    outcome: "frozen";
    reason: DevelopmentChatScenarioFrozenReason;
  }

  model ChatStoreChatCreatedEvent {
    port: "chatStore";
    effect: "create";
    outcome: "committed";
    chat: DevelopmentChatScenarioSnapshot;
  }

  model ChatStoreCreateCollisionEvent {
    port: "chatStore";
    effect: "create";
    outcome: "collision";
  }

  model ChatStoreChatRenamedEvent {
    port: "chatStore";
    effect: "rename";
    outcome: "committed";
  }

  model ChatStoreRenameStaleEvent {
    port: "chatStore";
    effect: "rename";
    outcome: "stale";
  }

  model ChatStoreDraftSavedEvent {
    port: "chatStore";
    effect: "saveDraft";
    outcome: "committed";
  }

  model ChatStorePendingUserTurnLockedEvent {
    port: "chatStore";
    effect: "lockPendingUserTurn";
    outcome: "committed";
  }

  model ChatStorePendingUserTurnDiscardedEvent {
    port: "chatStore";
    effect: "discardPendingUserTurn";
    outcome: "committed";
  }

  model ChatStorePendingUserTurnReplacedEvent {
    port: "chatStore";
    effect: "replacePendingUserTurn";
    outcome: "committed";
  }

  model ProfileStatementGenerationReadEvent {
    port: "profileHead";
    effect: "readStatementGeneration";
    outcome: NonnegativeWholeNumber;
  }

  model CurrentInstantReadEvent {
    port: "clock";
    effect: "now";
    outcome: UTCInstant;
  }

  model ChatIdGeneratedEvent {
    port: "chatIdGenerator";
    effect: "next";
    outcome: ChatId;
  }

  model ChatDraftIdGeneratedEvent {
    port: "chatDraftIdGenerator";
    effect: "next";
    outcome: ChatDraftId;
  }

  model CoachMemoryIdGeneratedEvent {
    port: "coachMemoryIdGenerator";
    effect: "next";
    outcome: CoachMemoryId;
  }

  model PendingUserTurnIdGeneratedEvent {
    port: "pendingUserTurnIdGenerator";
    effect: "next";
    outcome: PendingUserTurnId;
  }

  model ChatResponsePositionIdGeneratedEvent {
    port: "chatResponsePositionIdGenerator";
    effect: "next";
    outcome: ChatResponsePositionId;
  }

  union DevelopmentChatScenarioProviderAvailability {
    available: "available",
    unavailable: "unavailable",
  }

  union DevelopmentChatScenarioContextCapacityMode {
    alwaysFits: "alwaysFits",
    cannotFitThenFits: "cannotFitThenFits",
  }

  union DevelopmentChatScenarioSuspendedEffect {
    firstCatalogLoad: "firstCatalogLoad",
  }

  union DevelopmentChatScenarioCatalogStatus {
    ready: "ready",
    failed: "failed",
  }

  union DevelopmentChatScenarioSelectionAvailability {
    open: "open",
    frozen: "frozen",
  }

  union DevelopmentChatScenarioComposerStatus {
    editable: "editable",
    locked: "locked",
  }

  union DevelopmentChatScenarioFrozenReason {
    newerSchema: "newerSchema",
    unsupportedSchema: "unsupportedSchema",
    corrupt: "corrupt",
  }

  union DevelopmentChatScenarioNotice {
    invalidTitle: "invalidTitle",
    createFailed: "createFailed",
    createCollisionLimitReached: "createCollisionLimitReached",
    renameFailed: "renameFailed",
    staleRename: "staleRename",
    chatMissing: "chatMissing",
    chatOpenFailed: "chatOpenFailed",
    chatFrozen: "chatFrozen",
    catalogFailed: "catalogFailed",
    readOnlyLibrary: "readOnlyLibrary",
    invalidDraft: "invalidDraft",
    draftSaveFailed: "draftSaveFailed",
    draftChanged: "draftChanged",
    pendingUserTurnFailed: "pendingUserTurnFailed",
    coachContextUnavailable: "coachContextUnavailable",
    messageMustBeShortened: "messageMustBeShortened",
  }
}
