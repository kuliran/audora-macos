# Implementation plan

Each phase must be independently testable and leave saved audio recoverable.

0. **Feasibility gates:** prove the library/worker/Codex execution profile, pin and
   qualify the transcription runtime, and resolve the permitted uses of model
   outputs as described in
   [`execution-and-distribution.md`](execution-and-distribution.md).
1. **Boundaries and contracts:** create the Domain, Application, Contracts,
   Infrastructure, and Presentation targets; add schemas, fixtures, fake adapters,
   and command/state scenario suites without changing current behavior.
2. **Portable library:** implement manifests, IDs, atomic storage, preferences,
   reference resolution, Trash, and opening a copied library.
3. **Mono audio:** refactor microphone capture behind a port, add mono M4A/WAV
   import, canonical normalization, mute ranges, sealing, minimum voiced-coverage
   evidence for transcript validation, and recovery.
4. **Transcription:** add the qualified pinned worker and maintained compatibility
   patch, progress hook, ETA, cancellation, staged candidates, integrity
   validation, and offline preparation.
5. **Native review UI:** replace service-gated screens with library, recording,
   processing, playback, transcript, seeking, and failure states.
6. **Local analysis:** add deterministic annotations and local timing/delivery
   metrics with golden fixtures.
7. **Coaching and chat:** adapt the hardened Codex execution boundary to the coach
   port, require explicit consent, validate anchors, and persist chats locally.
8. **Removal and packaging:** remove Convex/Clerk/web/live-ASR dependencies from
   the native target, keep ordinary mono audio import as the only legacy recovery
   path in version one, then validate signing, model installation, offline
   operation, and long recordings.

## Repository strategy

Changes to `apps/macos`, including RFC edits, are committed in the macOS
repository. The outer repository then records the new submodule commit. A third
repository is not needed: `apps/macos` already has its own history and remote, and
the worker should version atomically with the application until it has independent
clients or releases.
