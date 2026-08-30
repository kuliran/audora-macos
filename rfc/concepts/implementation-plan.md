# Implementation plan

Each phase must be independently testable and leave saved audio recoverable.
The contract and persistence work starts only after the RFC, TypeSpec, generated
schemas, examples, and readiness fixtures describe the same model.

0. **Feasibility gates:** prove the selected signed Release profile and worker
   confinement; qualify the pinned transcription runtime and its downstream-
   coaching use; prove Codex structured output, the single transcript-read
   capability, cancellation, and safe provider-error extraction; and qualify a
   conservative context estimator against the exact serialized provider envelopes.
1. **Boundaries and contracts:** create the Domain, Application, Contracts,
   Infrastructure, and Presentation targets plus a clean composition root. Compile
   the TypeSpec-authored provider contract into checked-in JSON Schemas, add fake
   adapters and fixtures, and keep provider DTOs separate from versioned persisted
   records.
2. **Persistence kernel:** implement typed IDs, root-record schema migrations,
   sibling-partial writes, flush/install/compare-and-swap operations, staging
   reconciliation, one-main-window writer ownership, Library isolation, reference
   resolution, persistent Trash, metadata-only rotating diagnostics capped at
   100 MiB, and opening a copied Library.
3. **Session evidence:** implement the Session aggregate, microphone recording,
   mono/stereo M4A/WAV import, deterministic downmix, the 45-minute admission
   limit, canonical audio, interruption recovery, transcription jobs, immutable
   Transcript Revisions, Words, Textual Events, Audio Events, seeking, and review
   UI.
4. **Development Profile:** implement `profile/head.json`, immutable
   `revision.json` snapshots with detached `revision.sha256`, structured
   Statements and Evidence References, `generation`, `statementGeneration`, and
   the Library-scoped Profile commit coordinator. Add Profile health checks and
   the Library banner that excludes every colliding generation, publishes a fresh
   monotonic copy of the highest remaining healthy revision, or selects the null
   Profile when none is eligible, while retaining all broken and colliding revision
   bundles.
5. **Chat persistence:** implement immutable Session attachments, the shared
   multi-select creation picker, `creationKind`, `originAttachmentId`, the
   Analyze-seeded ordinary singular/plural Draft, dirty Draft autosave, Pending
   User Turn, successful messages, current structured Coach Memory, and one
   unresolved Proposal or Profile-publication failure per Chat. Derive and
   coalesce Profile-update dividers from `statementGeneration`; do not persist
   them as audit events. Persist neither `analysisDraftSeed` nor resolved
   operational records.
6. **Invocation module:** expose one Application gateway for every Coach action.
   `Invocations.tryInvoke` checks intent eligibility, the one-active-Invocation
   Library invariant, exact context fit, and the persisted one-per-rolling-minute
   admission ledger before it admits an immutable answer or Reconsider intent.
   Persist the admitted Invocation before launch. Give each Provider Attempt fresh
   identity, idempotency data, transcript handles, and read capability; implement
   bounded 5/10/15-second automatic retry, cancellation, late-result rejection,
   and relaunch conversion of active work to interruption. Delete resolved
   Invocations and Attempts.
7. **Coach adapter and response publication:** build every current provider request
   from persisted app state, including the structured Profile, current Memory,
   eligible Chat history, trigger, and immutable Session attachments. Send small
   transcripts inline and expose large transcripts through one optional atomic
   batch read. Validate each complete `CoachResponse` atomically. A valid answer
   atomically publishes the locked user Draft, coach message, and optional
   `newMemory`; omission or canonical equality retains the current Memory. Replace
   the single current Memory atomically and remove the superseded snapshot after
   the switch is recoverable. A crash before publication interrupts the turn—there
   is no durable complete-response staging or response-resume path.
8. **Profile proposal lifecycle:** classify each valid response as no Profile
   effect, one reviewed semantic-or-mixed Proposal, or a pure evidence append.
   Apply pure evidence appends silently with `(statementId, sessionId)`
   deduplication; expose their local publication failure through the ordinary
   UserRetryable Retry/Discard flow. Accept reviewed Proposals through one durable
   Profile commit intent and the Profile coordinator. Reconsider stale Proposals
   through a normal Invocation and require review again. Delete accepted,
   discarded, withdrawn, and otherwise resolved Proposals; accepted-Proposal audit
   UI remains backlog.
9. **Presentation and packaging:** implement processing/interrupted Chat-row state,
   disabled controls during processing or admission cooldown, locked-Draft
   Retry/Discard behavior, accessible evidence inset blocks and controls, Profile
   health and Profile-update UI, one main Library window, signing, model
   preparation, offline behavior, and removal of Convex/Clerk/web/live-ASR
   dependencies from the native target.

History compaction, Coach Memory compaction, infinite Chats, Trash cleanup,
Profile Inspector, accepted-Proposal audit UI, and alternate coach-provider modes
remain backlog. Their seams must not add inactive states or provider fields to the
current implementation.

## Repository strategy

Changes to `apps/macos`, including RFC edits, are committed in the macOS
repository. The outer repository then records the new submodule commit. A third
repository is not needed: `apps/macos` already has its own history and remote, and
the worker should version atomically with the application until it has independent
clients or releases.
