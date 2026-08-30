# Audora

Audora helps one Speaker reflect on and improve their own recorded speech while
preserving the evidence from which feedback is derived.

## Core language

**Speaker**:
The person whose own speech is recorded or imported for reflection and coaching.
_Avoid_: Attendee, participant, meeting member

**Session**:
The durable unit of solo reflection. It owns one sealed Audio Asset and the
Transcript Revisions and Annotations derived from it.
_Avoid_: Meeting, conversation, recording

**Recording**:
An in-progress microphone acquisition whose evidence has not yet been sealed into
a Session.
_Avoid_: Meeting, Session

**Library**:
An isolated, copyable project containing its own Sessions, preferences,
Development Profile, and Chats.
_Avoid_: Database, workspace, account

## Audio evidence

**Audio Source**:
One origin-tagged stream of audio evidence on a Session timeline. Its origin does
not establish a speaker identity.
_Avoid_: Participant, speaker track

**Audio Asset**:
A Session-owned collection of Audio Sources, including the canonical
representation and any retained import original.
_Avoid_: File path, recording session

**Sealed Audio**:
An Audio Asset whose writes and validation completed before transcription uses
it.
_Avoid_: Finished transcript, live buffer

**Canonical Timeline**:
The shared zero-based time coordinate system used by audio, transcript words,
annotations, and playback.
_Avoid_: Playback position, wall-clock time

**Muted Interval**:
Elapsed time during which the Speaker deliberately withheld microphone input. It
is unavailable evidence, not observed silence.
_Avoid_: Pause, silence

**Capture Gap**:
Elapsed time for which audio evidence is unavailable because capture failed or
was interrupted.
_Avoid_: Pause, Muted Interval, silence

## Transcript evidence

**Transcript Candidate**:
A complete but semantically untrusted transcription result staged for validation.
_Avoid_: Draft transcript, live transcript

**Transcript Revision**:
A complete, immutable, validated transcription of Session audio produced under a
specific engine and Engine-use Policy.
_Avoid_: Editable transcript, notes

**Selected Transcript Revision**:
The Transcript Revision currently used for review, annotation, and new Chat
attachments. Selection does not make it mutable.
_Avoid_: Latest transcript, canonical edit

**Transcript Word**:
An ordered, independently addressable spoken-word unit in one Transcript Revision.
A Word may lack a reliable audio span; punctuation is not a Word.
_Avoid_: Token, punctuation mark, rendered substring

**Punctuation**:
Display syntax in transcript line text. It has no independent identity or audio
span.
_Avoid_: Transcript Word, timed token

**Annotation**:
A non-destructive interpretation represented as either a Textual Event or an Audio
Event. It never changes a Transcript Revision.
_Avoid_: Correction, transcript edit

**Textual Event**:
An Annotation anchored to an exact ordered Word range in one Transcript Revision.
_Avoid_: Text edit, rewritten phrase

**Audio Event**:
An Annotation anchored to one Audio Source and a Session Time Range, including
observed sound, silence, or unavailable evidence.
_Avoid_: Transcript token, word gap

**Session Time Range**:
A half-open interval on a Session's Canonical Timeline. Its owner identifies an
Audio Source when one matters.
_Avoid_: Audio Source range, wall-clock interval

**Pause**:
A measured interval without eligible detected speech after unavailable evidence
is excluded.
_Avoid_: Muted Interval, Capture Gap, punctuation gap

## Coaching

**Evidence-backed Observation**:
A coach-message block pairing a provider-authored interpretation with exact
Evidence References. It belongs to its Chat, not a Session.
_Avoid_: Anchored comment, transcript comment, Annotation

**Chat Session Attachment**:
An immutable relationship chosen at Chat creation that pins one Session and one
Transcript Revision under a Chat-scoped attachment identity.
_Avoid_: Mutable selection, Session ownership

**Chat Creation Kind**:
App-owned provenance distinguishing an ordinary New Chat from Session Analysis.
It does not create a different coach mode or request trigger.
_Avoid_: Coach mode, Analyze trigger

**Coach Memory**:
The current bounded, structured, provider-authored continuity snapshot for one
Chat. It is replaceable context, not Chat history, Profile state, or evidence.
_Avoid_: Chat history, source of truth, Development Profile

**Chat Capacity Failure**:
A retryable attempted-turn failure created when the prepared coach context cannot
fit. It does not make the Chat permanently read-only.
_Avoid_: Provider error, automatic compaction, terminal Chat

**Session Transcript Handle**:
A temporary Provider-Attempt-local route to one on-demand Chat Session Attachment.
It is not a Library identity.
_Avoid_: Session ID, transcript token

**Session Read Capability**:
The Provider-Attempt-local authority permitting one bounded read from the
Invocation's immutable attachment set.
_Avoid_: Session Transcript Handle, Session ID, provider credential

**Coach Provider**:
An adapter/model composition that consumes Coach Requests and returns Coach
Responses.
_Avoid_: Model, Invocation, Provider Attempt

**Coach Response**:
One complete structured but semantically untrusted provider result. It may contain
message blocks, replacement Coach Memory, and proposed Profile effects.
_Avoid_: Coach Candidate, partial response, streamed prose

**Evidence Reference**:
A nested value locating exact transcript material and retaining a bounded label
for degraded display. It has no independent identity or lifecycle.
_Avoid_: Citation, citation ID, copied quote, file path

**Evidence Support**:
The relationship between a Profile Statement and an Evidence Reference. It adds
support without changing the Statement's wording.
_Avoid_: Proof, citation count

**Chat**:
Persisted but disposable reflection containing immutable Session Attachments,
successful messages, one Draft, current Coach Memory, and at most one unresolved
Profile Change Proposal or Profile-publication failure.
_Avoid_: Codex session, general chat

**Chat Draft**:
The one recoverable composer value belonging to a Chat. Sending locks its exact
version until the Pending User Turn succeeds or is discarded.
_Avoid_: Chat message, provider context

**Pending User Turn**:
An unanswered turn that locks one exact Chat Draft while coach work or its
retryable failure remains unresolved. It becomes history only with a successful
Coach Response.
_Avoid_: Pending Send, visible user message, abandoned message

**Invocation**:
One admitted unit of coach work for one immutable Invocation Intent. It may contain
bounded automatic Provider Attempts.
_Avoid_: Chat turn, provider request, unbounded retry loop

**Invocation Intent**:
The reason an Invocation exists, such as answering a Pending User Turn or
reconsidering a stale Profile Change Proposal.
_Avoid_: Coach mode, request family

**Provider Attempt**:
One external Coach Provider launch within an Invocation. Each Attempt has fresh
provider and transcript-access identity.
_Avoid_: Chat turn, Profile Proposal retry

**Analysis Chat**:
A Chat created from a Session's Analyze action with that Session locked in its
creation picker and an ordinary analysis Draft submitted automatically.
_Avoid_: Session report, Analyze mode

**Development Chat**:
A Chat created without Session Attachments and grounded in the Development Profile
and its own conversation context.
_Avoid_: Context-free chat

## Development Profile

**Development Profile**:
The compact Library-scoped set of current goals, preferences, accepted speaking
observations, and growth directions used in every Coach Request.
_Avoid_: User profile, hidden memory, personality profile

**Profile Statement**:
An individually addressable current goal, preference, assessment, observation, or
growth direction in the Development Profile.
_Avoid_: Fact, log line

**Self-Assessment**:
A Profile Statement expressing the Speaker's own assessment without claiming
Session evidence.
_Avoid_: Measured observation, inferred trait

**Profile Revision**:
An immutable structured snapshot of the Development Profile. Physical generation
may advance for evidence alone; Statement generation advances only when the active
Statement set or wording changes, except for explicit recovery invalidation.
_Avoid_: Codex memory, mutable profile

**Profile Retirement**:
A reviewed Profile change that removes a Statement from current coaching context
while older Profile Revisions retain it.
_Avoid_: Delete Session, erase evidence

**Profile Replacement**:
A reviewed atomic refinement of an existing Profile Statement. A materially
different claim is a retirement plus an addition.
_Avoid_: In-place edit, unrelated rewrite

**Profile Change Proposal**:
A Chat-owned, non-authoritative set of proposed Profile edits and evidence. It
changes the Development Profile only after the Speaker accepts it.
_Avoid_: Profile edit, automatic memory

**Engine-use Policy**:
The reviewed permissions attached to a Transcript Revision that govern private
use, export, external processing, and distribution.
_Avoid_: User consent, provider setting
