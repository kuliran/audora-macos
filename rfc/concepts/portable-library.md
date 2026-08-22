# Portable library

## Source-of-truth layout

Version one uses one user-selected library directory:

```text
Audora Library.audoralibrary/
├── library.json
├── preferences.json
├── audio/
│   └── aud-20260822T153045123Z-K7M2/
│       ├── audio.json
│       ├── original.<ext>      # imported media only; always retained in v1
│       └── audio.wav          # canonical mono timeline
├── sessions/
│   └── ses-20260822T153045123Z-P4R7/
│       ├── session.json
│       ├── transcripts/
│       ├── annotations/
│       ├── metrics/
│       └── reports/
├── chats/
│   └── cht-20260822T160201044Z-9NQF/
│       ├── chat.json
│       └── messages.jsonl
├── jobs/
│   └── job-20260822T160300000Z-1ABC/
│       ├── job.json
│       └── candidate/          # untrusted/failed result until promoted
├── staging/                    # capability-scoped, recoverable partial work
└── trash/
    ├── audio/
    ├── sessions/
    └── chats/
```

Manifests and entity files are authoritative. A future SQLite/FTS index is a
rebuildable cache and cannot be required to restore a library.

`library.json` records the format name, schema version, library ID, creation time,
and last successful migration. Each entity manifest records its kind, schema
version, ID, creation/update times, and content-relative artifact paths.

## IDs

Entity IDs are typed and immutable:

```text
aud-20260822T153045123Z-K7M2
ses-20260822T153045123Z-P4R7
cht-20260822T160201044Z-9NQF
```

- The timestamp is fixed-width UTC with milliseconds.
- The suffix is four Crockford Base32 characters.
- The creator checks the target entity folder and regenerates on collision.
- Audio/session time is recording start or import start. Chat time is chat
  creation.
- Authoritative dates are separate fields. Code never derives relationships or
  business state by parsing an ID.

## References

References are explicit IDs, not paths or timestamp inference:

```text
session -> audioId
chat -> zero or more sessionIds and transcriptRevisionIds
annotation/report -> transcriptRevisionId and stable anchors
```

Only one direction is authoritative. Reverse relationships are derived at load or
by a rebuildable index, preventing two manifests from disagreeing after a crash.

Resolution returns an explicit state:

```swift
enum ReferenceResolution<Value> {
    case found(Value)
    case missing(id: EntityID)
    case inTrash(id: EntityID)
    case corrupt(id: EntityID, reason: String)
    case unsupportedSchema(id: EntityID, version: Int)
}
```

Fallback behavior is non-destructive:

| Reference problem | Behavior |
| --- | --- |
| Session audio missing | Keep transcript, metrics, reports, and chats; disable playback/retranscription; offer Restore, Relink, or Detach |
| Unreferenced audio | Show under Unlinked Audio; allow creating or attaching a session |
| Chat session missing | Preserve messages; show a missing-context chip; exclude it from new coaching context |
| Selected transcript missing | Choose newest valid completed revision; otherwise offer transcription if audio exists |
| Annotation word IDs missing | Hide only the stale overlay; retain the canonical transcript |
| Coach anchor missing | Show saved response as unverified; disable the anchor link |
| Required v1 model unavailable | Preserve the preference and audio; offer Prepare, Reinstall, or Retry; never silently switch engines |
| Last selected entity missing | Open the library home |

An unresolved ID is never erased automatically. Restoring a copied entity can heal
the relationship without editing the referring record.

## Atomicity and recovery

- Write JSON to a sibling `.partial`, flush it, then atomically replace the final
  file.
- Record/normalize audio to a partial artifact and publish `audio.json` last as the
  commit marker.
- Publish a transcript revision only after schema and integrity validation.
- Ignore incomplete final JSONL lines after a crash, retaining the file for repair.
- Move deletion targets atomically into `trash/`; IDs are never reused.
- Empty Trash is an explicit destructive action. Deleting a session never silently
  deletes audio or chats.
- Unknown newer root schemas open read-only. A corrupt individual entity does not
  prevent healthy entities from loading.

Durable job metadata lives under `jobs/`. Provider output remains an untrusted
candidate until Application validation promotes it into the owning session's
revision/report folder. Failed candidates can contain transcript data, so they are
portable private user data, never logs; they remain until the user dismisses the
failed job or a successful retry supersedes them. `staging/` contains only
capability-scoped partial artifacts. On launch, Audora reconciles staging against
durable jobs and either resumes, marks interrupted, or offers cleanup. Nothing in
staging is selected as canonical merely because it exists.

## Portability

Version one supports creating a library, choosing an existing copied library, and
revealing it for backup. Direct copying is documented as consistent only while the
app is closed. Live snapshot export and merging libraries are backlog.

The app imports audio by copying the exact source file into the library and keeps
it for the life of the audio entity. It also creates the canonical mono WAV. It
never relies on an external absolute URL. Every stored artifact path is relative
and validated against `..`, absolute paths, and symlinks. Retaining both files is a
deliberate evidence-preservation/storage tradeoff in version one, not a preference.

The only machine-local bootstrap state outside the library is the locator or
security-scoped bookmark needed to find it. The following are replaceable machine
state rather than portable user data:

- microphone permission and other macOS grants;
- Codex authentication and any credentials;
- Crisper/Python/model installation and caches;
- selected hardware device and performance history;
- window geometry and launch-at-login registration.

Portable preferences preserve user choices such as language, annotation
visibility, playback rate, and coaching limits. If the pinned dependency is
unavailable on the new Mac, the app reports it without rewriting user data or
substituting another engine. Engine selection becomes a preference only when
alternative engines leave backlog.
