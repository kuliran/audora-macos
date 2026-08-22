# Coaching and chat

## Provider port

Coaching is independent of transcription and annotation:

```swift
protocol CoachProvider {
    func descriptor() -> CoachDescriptor
    func health() async -> ProviderHealth
    func run(
        request: CoachRequest,
        events: @escaping (CoachEvent) -> Void
    ) async throws -> CoachCandidate
    func cancel(jobID: JobID) async
}
```

Version one implements only a ChatGPT-authenticated Codex CLI adapter. The provider
is invoked from a use case, not directly from a view, and cannot change the
canonical transcript. `CoachCandidate` contains untrusted report/annotation drafts;
Application validates every anchor, limit, and field before publishing a
`CoachResult`.

## Consent and payload

Local annotation runs automatically. Coaching does not.

Before every materially different coaching context, the UI identifies the
destination as OpenAI via the user's Codex login and lists the included fields.
The request and disclosure are generated from the same bounded structure:

```text
CoachPayloadEnvelope
  task and schema version
  current user message or Analyze action
  explicitly selected prior chat messages
  selected transcript lines/words and anchor IDs
  optional rounded local metrics
  fixed provider-instruction version and structured-output schema
```

The UI shows source/session labels and counts, offers a payload preview, and never
constructs a separate optimistic description. Positive and negative egress
fixtures prove that selected fields are included and unrelated entities are not.
Before constructing the envelope, Application checks the transcript engine's
`externalProcessingAllowed` policy. Crisper output remains blocked from Codex until
its output-use license is explicitly cleared for this purpose.

Excluded by policy:

- raw or encoded audio;
- absolute local paths and library IDs not needed for returned anchors;
- credentials, Codex state, and provider diagnostics;
- raw pitch contours, absolute median pitch, and voice embeddings;
- unrelated sessions, chat messages, app configuration, project context, and
  instructions other than the fixed disclosed provider-instruction version;
- system audio, which does not exist in version one.

Consent records the destination, envelope hash, selected entity/message IDs, field
classes, counts, and provider-instruction version—not a duplicate plaintext
payload.

## Structured result

A recording report may contain topic, short description, strengths, improvements,
action items, and exact anchored comments. The provider returns only IDs from the
submitted slice:

```text
Anchor
  word range: startWordId, endWordId
  line: lineId
  event: eventId
```

The application validates anchor membership and ordering, then derives displayed
quotes and times from the immutable revision. Unknown anchors reject the result or
the affected item; model-returned timestamps and unverified quotes are not trusted.

## Chat persistence

Chats are local entities independent of Codex session history. A chat can reference
zero or more app sessions and transcript revisions. Messages have stable IDs,
sequence numbers, roles, timestamps, provider provenance, and optional validated
anchors.

If a linked session is missing, the chat remains readable, shows a missing-context
chip, and excludes that session from future requests. Provider failure preserves
the user's message and records a retryable local error without inventing an
assistant response.

General chat defaults to no recording context. The user explicitly adds or removes
sessions. Prior chat history is bounded before sending, and the UI shows which
context is active.

## Limits and execution

- One Codex request runs at a time.
- Default admission is at most five requests in a rolling five-minute window; the
  preference may lower but not silently raise this safety default.
- Inputs, outputs, duration, and process lifetime are bounded.
- Transcript text is untrusted; Codex uses a pinned non-interactive profile with an
  empty scoped working directory, allowlisted environment, bounded structured
  output, and user configuration, rules, tools, browser, plugins, shell, and
  project context disabled. The adapter startup-verifies the profile and tests
  hostile transcript fixtures. See the official
  [`codex exec` documentation](https://learn.chatgpt.com/docs/non-interactive-mode).
- Model and reasoning effort are selected from an application allowlist and shown
  in settings; UI input never becomes arbitrary CLI flags.
- Cancellation terminates and reaps the provider process after a bounded grace
  period.

A future verified local coach implements the same port and can use a different
consent/data-boundary descriptor. It is backlog, not an alternate code path hidden
inside the Codex adapter.

`--ephemeral` prevents Codex from persisting its local session rollout file; it is
not a promise about OpenAI-side retention or training. Remote handling follows the
signed-in account's applicable OpenAI terms and data controls, which the consent UI
links without restating as an Audora guarantee.
