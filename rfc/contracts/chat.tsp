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

    @maxItems(128)
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

  /** Portable Chat behavior across zero or more immutable Session attachments. */
  @jsonSchema
  @id("ChatFeatureScenario.json")
  model ChatFeatureScenario {
    schemaVersion: 1;
    scenarioId: string;
    libraryId: LibraryId;
    initialChats: ChatScenarioSnapshot[];
    commands: ChatScenarioCommand[];
    dependencyTrace: ChatDependencyEvent[];
    expectedState: ChatScenarioState;
    expectedProviderCalls: 0;
    expectedInvocationCalls: 0;
    expectedAdmissionCalls: 0;
    contextCapacityMode?: ChatScenarioContextCapacityMode;
    suspendedEffect?: ChatScenarioSuspendedEffect;
  }

  model ChatScenarioSnapshot {
    chatId: ChatId;
    draftId: ChatDraftId;
    memoryId: CoachMemoryId;
    manifestRevision: NonnegativeWholeNumber;
    title: ChatTitleText;
    createdAt: UTCInstant;
    updatedAt: UTCInstant;
    creationKind: "newChat";

    @maxItems(128)
    attachments: ChatSessionAttachment[];

    draftText: ChatDraftText;
    draftVersion: NonnegativeWholeNumber;
    messageIds: ChatMessageId[];
    memoryGeneralNotes: string;
    memorySessionSummaries: PersistedCoachMemorySessionSummary[];
  }

  @oneOf
  union ChatScenarioCommand {
    beginNewChat: BeginNewChatScenarioCommand,
    setNewChatAttachmentFilter: SetNewChatAttachmentFilterScenarioCommand,
    toggleNewChatAttachment: ToggleNewChatAttachmentScenarioCommand,
    cancelNewChat: CancelNewChatScenarioCommand,
    confirmNewChat: ConfirmNewChatScenarioCommand,
    rename: RenameChatScenarioCommand,
    setFilter: SetChatFilterScenarioCommand,
    open: OpenChatScenarioCommand,
    editDraft: EditChatDraftScenarioCommand,
    refreshContextQuote: RefreshChatContextQuoteScenarioCommand,
    sendDraft: SendChatDraftScenarioCommand,
    retryPendingUserTurn: RetryPendingUserTurnScenarioCommand,
    createNewChatFromCapacityFailure: CreateNewChatFromCapacityFailureScenarioCommand,
    discardPendingUserTurn: DiscardPendingUserTurnScenarioCommand,
    start: StartChatScenarioCommand,
  }

  @oneOf
  union ChatDependencyEvent {
    catalogLoaded: ChatStoreCatalogLoadedEvent,
    catalogFailed: ChatStoreCatalogFailedEvent,
    attachmentCatalogLoaded: NewChatAttachmentCatalogLoadedEvent,
    attachmentCatalogReadOnly: NewChatAttachmentCatalogReadOnlyEvent,
    attachmentCatalogFailed: NewChatAttachmentCatalogFailedEvent,
    newChatQuoteAvailable: NewChatQuoteAvailableEvent,
    newChatQuoteUnavailable: NewChatQuoteUnavailableEvent,
    chatAttachmentsResolved: ChatAttachmentsResolvedEvent,
    chatAttachmentResolutionReadOnly: ChatAttachmentResolutionReadOnlyEvent,
    chatAttachmentResolutionFailed: ChatAttachmentResolutionFailedEvent,
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

  model ChatScenarioState {
    allChatIds: ChatId[];
    visibleChatIds: ChatId[];
    catalogStatus?: ChatScenarioCatalogStatus;
    selectedChatId?: ChatId;
    selectedTitle?: ChatTitleText;
    selectedRevision?: NonnegativeWholeNumber;
    selectedAvailability?: ChatScenarioSelectionAvailability;
    selectedFrozenReason?: ChatScenarioFrozenReason;
    selectedDraftText?: ChatDraftText;
    selectedDraftVersion?: NonnegativeWholeNumber;
    composerStatus?: ChatScenarioComposerStatus;
    pendingUserTurnId?: PendingUserTurnId;
    responsePositionId?: ChatResponsePositionId;
    pendingFailure?: PendingUserTurnFailure;
    notice?: ChatScenarioNotice;
    newChatPickerStatus?: NewChatPickerStatus;
    newChatFilterQuery?: NewChatAttachmentFilterText;

    @maxItems(32768)
    newChatAllAttachmentIds?: ChatSessionAttachmentId[];

    @maxItems(32768)
    newChatVisibleAttachmentIds?: ChatSessionAttachmentId[];

    @maxItems(128)
    newChatSelectedAttachmentIds?: ChatSessionAttachmentId[];

    newChatFeasibility?: NewChatCreationFeasibility;
    newChatIssue?: NewChatPickerIssue;

    @maxItems(128)
    openedAttachmentStatuses?: ChatOpenedAttachmentStatus[];
  }

  model BeginNewChatScenarioCommand {
    kind: "beginNewChat";
  }

  model SetNewChatAttachmentFilterScenarioCommand {
    kind: "setNewChatAttachmentFilter";
    query: NewChatAttachmentFilterText;
  }

  model ToggleNewChatAttachmentScenarioCommand {
    kind: "toggleNewChatAttachment";
    attachmentId: ChatSessionAttachmentId;
  }

  model CancelNewChatScenarioCommand {
    kind: "cancelNewChat";
  }

  model ConfirmNewChatScenarioCommand {
    kind: "confirmNewChat";
  }

  model RenameChatScenarioCommand {
    kind: "rename";
    chatId: ChatId;
    title: string;
    expectedRevision: NonnegativeWholeNumber;
  }

  model SetChatFilterScenarioCommand {
    kind: "setFilter";
    query: string;
  }

  model OpenChatScenarioCommand {
    kind: "open";
    chatId: ChatId;
  }

  model EditChatDraftScenarioCommand {
    kind: "editDraft";
    text: ChatDraftText;
  }

  model SendChatDraftScenarioCommand {
    kind: "sendDraft";
  }

  model RefreshChatContextQuoteScenarioCommand {
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

  model StartChatScenarioCommand {
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

  model NewChatAttachmentCatalogLoadedEvent {
    port: "attachmentSource";
    effect: "loadCandidates";
    outcome: "loaded";

    @maxItems(32768)
    candidates: NewChatAttachmentCandidate[];
  }

  model NewChatAttachmentCatalogReadOnlyEvent {
    port: "attachmentSource";
    effect: "loadCandidates";
    outcome: "readOnlyLibrary";
  }

  model NewChatAttachmentCatalogFailedEvent {
    port: "attachmentSource";
    effect: "loadCandidates";
    outcome: "failed";
  }

  model NewChatQuoteAvailableEvent {
    port: "coachContext";
    effect: "quoteNewChat";
    outcome: "available";
    fits: boolean;
  }

  model NewChatQuoteUnavailableEvent {
    port: "coachContext";
    effect: "quoteNewChat";
    outcome: NewChatQuoteUnavailableReason;
  }

  model ChatAttachmentsResolvedEvent {
    port: "attachmentSource";
    effect: "resolveAttachments";
    outcome: "resolved";

    @maxItems(128)
    resolutions: ChatAttachmentResolution[];
  }

  model ChatAttachmentResolutionReadOnlyEvent {
    port: "attachmentSource";
    effect: "resolveAttachments";
    outcome: "readOnlyLibrary";
  }

  model ChatAttachmentResolutionFailedEvent {
    port: "attachmentSource";
    effect: "resolveAttachments";
    outcome: "failed";
  }

  model NewChatAttachmentCandidate {
    sessionId: SessionId;
    transcriptRevisionId: TranscriptRevisionId;
    displayLabel: NewChatAttachmentDisplayLabel;

    @minValue(1)
    @maxValue(2700000)
    durationMilliseconds: integer;

    @minValue(0)
    @maxValue(67108864)
    approximateTranscriptTokens: integer;

    delivery: NewChatAttachmentDelivery;
  }

  @oneOf
  union ChatAttachmentResolution {
    available: ChatAvailableAttachmentResolution,
    unavailable: ChatUnavailableAttachmentResolution,
  }

  model ChatAvailableAttachmentResolution {
    attachment: ChatSessionAttachment;
    status: "available";
    candidate: NewChatAttachmentCandidate;
  }

  model ChatUnavailableAttachmentResolution {
    attachment: ChatSessionAttachment;
    status: ChatAttachmentUnavailableReason;
  }

  model ChatOpenedAttachmentStatus {
    attachmentId: ChatSessionAttachmentId;
    status: ChatOpenedAttachmentAvailability;
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
    reason: ChatScenarioFrozenReason;
  }

  model ChatStoreChatCreatedEvent {
    port: "chatStore";
    effect: "create";
    outcome: "committed";
    chat: ChatScenarioSnapshot;
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

  union ChatScenarioContextCapacityMode {
    alwaysFits: "alwaysFits",
    cannotFitThenFits: "cannotFitThenFits",
  }

  union ChatScenarioSuspendedEffect {
    firstCatalogLoad: "firstCatalogLoad",
  }

  union ChatScenarioCatalogStatus {
    ready: "ready",
    failed: "failed",
  }

  union NewChatPickerStatus {
    closed: "closed",
    loading: "loading",
    ready: "ready",
    failed: "failed",
  }

  union NewChatCreationFeasibility {
    quoting: "quoting",
    fits: "fits",
    cannotFit: "cannotFit",
    providerUnavailable: "providerUnavailable",
    sourceUnavailable: "sourceUnavailable",
    staleState: "staleState",
    invalidContext: "invalidContext",
  }

  union NewChatQuoteUnavailableReason {
    providerUnavailable: "providerUnavailable",
    sourceUnavailable: "sourceUnavailable",
    staleState: "staleState",
    invalidContext: "invalidContext",
  }

  union NewChatPickerIssue {
    selectionLimitReached: "selectionLimitReached",
    attachmentUnavailable: "attachmentUnavailable",
    contextCannotFit: "contextCannotFit",
    providerUnavailable: "providerUnavailable",
    sourceUnavailable: "sourceUnavailable",
    staleState: "staleState",
    invalidContext: "invalidContext",
  }

  union NewChatAttachmentDelivery {
    inline: "inline",
    onDemand: "onDemand",
  }

  union ChatAttachmentUnavailableReason {
    missing: "missing",
    inTrash: "inTrash",
    corrupt: "corrupt",
    unsupportedSchema: "unsupportedSchema",
  }

  union ChatOpenedAttachmentAvailability {
    available: "available",
    missing: "missing",
    inTrash: "inTrash",
    corrupt: "corrupt",
    unsupportedSchema: "unsupportedSchema",
  }

  union ChatScenarioSelectionAvailability {
    open: "open",
    frozen: "frozen",
  }

  union ChatScenarioComposerStatus {
    editable: "editable",
    locked: "locked",
  }

  union ChatScenarioFrozenReason {
    newerSchema: "newerSchema",
    unsupportedSchema: "unsupportedSchema",
    corrupt: "corrupt",
  }

  union ChatScenarioNotice {
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
    attachmentCatalogFailed: "attachmentCatalogFailed",
  }

  @minLength(1)
  @maxLength(256)
  @pattern("^[^\\u0000-\\u001F\\u007F-\\u009F]*$")
  scalar NewChatAttachmentDisplayLabel extends string;

  @maxLength(256)
  @pattern("^[^\\u0000-\\u001F\\u007F-\\u009F]*$")
  scalar NewChatAttachmentFilterText extends string;
}
