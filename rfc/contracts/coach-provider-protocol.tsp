import "./coach-provider-shared.tsp";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  // APPLICATION -> COACH
  @jsonSchema
  @id("CoachRequest.json")
  model CoachRequest {
    profile: ProfileContext;
    conversation: ConversationContext;
    sessionAttachments: SessionAttachment[];
  }

  model ProfileContext {
    statements: ProfileStatement[];
  }

  model ConversationContext {
    history: ChatTurn[];
    memory: CoachMemory;
    trigger: ConversationTrigger;
  }

  @oneOf
  union SessionAttachment {
    inline: SessionAttachmentInline,
    onDemand: SessionAttachmentOnDemand,
  }

  model ProfileStatement {
    statementId: EntityId;
    statementKind: ProfileStatementKind;
    wording: NonEmptyText;

    /** Total distinct supporting Sessions, including unattached Sessions. */
    @minValue(0)
    supportingSessionCount: int32;

    /** Evidence whose exact Session/Transcript Revision pair is attached. */
    @minItems(1)
    evidence?: CoachEvidencePointer[];
  }

  model ChatTurn {
    role: "user" | "coach";

    /** Exact user text or canonical coach-block prose projection. */
    text: NonEmptyText;
  }

  model CoachMemory {
    generalNotes: string;
    sessionSummaries: CoachMemorySessionSummary[];
  }

  @oneOf
  union ConversationTrigger {
    userMessage: ConversationTriggerUserMessage,
    reconsiderProfileChange: ConversationTriggerReconsiderProfileChange,
  }

  model SessionAttachmentInline {
    kind: "inline";
    ...SessionAttachmentBase;
    transcript: SessionTranscript;
  }

  model SessionAttachmentOnDemand {
    kind: "onDemand";
    ...SessionAttachmentBase;
    sessionTranscriptHandle: SessionTranscriptHandle;
  }

  enum ProfileStatementKind {
    goal,
    coachingPreference,
    selfAssessment,
    speakingObservation,
    growthDirection,
  }

  /** Pointer into an attached canonical transcript. Coach-returned values are untrusted. */
  model CoachEvidencePointer {
    sessionAttachmentId: SessionAttachmentId;
    target: CoachEvidenceTarget;
  }

  model CoachMemorySessionSummary {
    sessionAttachmentId: SessionAttachmentId;
    notes: NonEmptyText;
  }

  model ConversationTriggerUserMessage {
    kind: "userMessage";
    text: NonEmptyText;
  }

  model ConversationTriggerReconsiderProfileChange {
    kind: "reconsiderProfileChange";

    @minItems(1)
    previousEdits?: CoachProfileEditProposal[];

    /** Inactive targets referenced by the previous edits or pending evidence. */
    @minItems(1)
    inactiveEditTargets?: ProfileStatement[];

    @minItems(1)
    inactiveTargetsEvidence?: CoachProfileEvidenceAppend[];
  }

  model SessionTranscript {
    lines: TranscriptAttachmentLine[];
    audioEvents: AudioEvent[];
  }

  model SessionAttachmentBase {
    sessionAttachmentId: SessionAttachmentId;
    displayLabel: NonEmptyText;
  }

  @oneOf
  union CoachEvidenceTarget {
    wordRange: CoachEvidenceTargetWordRange,
    audioEvent: CoachEvidenceTargetAudioEvent,
  }

  model CoachProfileEditProposal {
    edit: CoachProfileEdit;

    @minItems(1)
    evidence?: CoachEvidencePointer[];
  }

  model CoachProfileEvidenceAppend {
    targetStatementId: EntityId;

    @minItems(1)
    evidence: CoachEvidencePointer[];
  }

  model TranscriptAttachmentLine {
    timeRange: SessionTimeRange;
    text: NonEmptyText;

    @minItems(1)
    words: TranscriptAttachmentWord[];
  }

  model AudioEvent {
    audioEventId: EntityId;
    category: AudioEventCategory;
    timeRange: SessionTimeRange;
  }

  model CoachEvidenceTargetWordRange {
    kind: "wordRange";
    startWordId: EntityId;
    endWordId: EntityId;
  }

  model CoachEvidenceTargetAudioEvent {
    kind: "audioEvent";
    audioEventId: EntityId;
  }

  @oneOf
  union CoachProfileEdit {
    add: CoachProfileEditAdd,
    replace: CoachProfileEditReplace,
    retire: CoachProfileEditRetire,
  }

  model SessionTimeRange {
    @minValue(0)
    startMs: int32;

    @minValue(0)
    endMs: int32;
  }

  model TranscriptAttachmentWord {
    wordId: EntityId;
    text: NonEmptyText;

    /** Missing when the Word has no reliable audio span. */
    timeRange?: SessionTimeRange;
  }

  enum AudioEventCategory {
    nonSpeech,
    silentPause,
    untranscribedVoicedInterval,
    muted,
    captureGap,
  }

  model CoachProfileEditAdd {
    kind: "add";
    statementKind: ProfileStatementKind;
    wording: NonEmptyText;
  }

  model CoachProfileEditReplace {
    kind: "replace";
    targetStatementId: EntityId;
    wording: NonEmptyText;
  }

  model CoachProfileEditRetire {
    kind: "retire";
    targetStatementId: EntityId;
  }

  // COACH TOOL CALL -> APPLICATION
  @jsonSchema
  @id("ReadSessionTranscriptsRequest.json")
  model ReadSessionTranscriptsRequest {
    @minItems(1)
    sessionTranscriptHandles: SessionTranscriptHandle[];
  }

  // APPLICATION -> COACH TOOL RESPONSE
  @jsonSchema
  @id("ReadSessionTranscriptsResponse.json")
  @oneOf
  union ReadSessionTranscriptsResponse {
    complete: ReadSessionTranscriptsResponseComplete,
    sessionUnavailable: ReadSessionTranscriptsResponseSessionUnavailable,
    contextCannotFit: ReadSessionTranscriptsResponseContextCannotFit,
  }

  model ReadSessionTranscriptsResponseComplete {
    kind: "complete";

    @minItems(1)
    transcripts: SessionTranscriptDisclosure[];
  }

  model ReadSessionTranscriptsResponseSessionUnavailable {
    kind: "sessionUnavailable";

    @minItems(1)
    unavailableSessionTranscriptHandles: SessionTranscriptHandle[];
  }

  model ReadSessionTranscriptsResponseContextCannotFit {
    kind: "contextCannotFit";
  }

  model SessionTranscriptDisclosure {
    sessionAttachmentId: SessionAttachmentId;
    transcript: SessionTranscript;
  }

  // COACH -> APPLICATION
  @jsonSchema
  @id("CoachResponse.json")
  model CoachResponse {
    @minItems(1)
    messageBlocks?: CoachResponseBlock[];

    /** Complete replacement; omission retains the current Coach Memory. */
    newMemory?: CoachMemory;

    @minItems(1)
    proposeProfileEdits?: CoachProfileEditProposal[];

    @minItems(1)
    appendProfileEvidence?: CoachProfileEvidenceAppend[];
  }

  @oneOf
  union CoachResponseBlock {
    markdown: CoachResponseBlockMarkdown,
    evidenceObservation: CoachResponseBlockEvidenceObservation,
  }

  model CoachResponseBlockMarkdown {
    kind: "markdown";

    /** Coaching prose that does not need evidence controls. */
    markdown: NonEmptyText;
  }

  model CoachResponseBlockEvidenceObservation {
    kind: "evidenceObservation";
    markdown: NonEmptyText;

    @minItems(1)
    evidence: CoachEvidencePointer[];
  }
}
