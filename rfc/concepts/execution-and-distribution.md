# Execution, engine qualification, and distribution

This document defines gates that must be answered with working Release-mode spikes.
It is not legal advice and does not assume that a development setup is suitable for
distribution.

## App and worker execution profiles

Version one needs persistent read/write access to a user-selected Audora library
and must run a local transcription worker. The current legacy target has App
Sandbox enabled with a user-selected read-only entitlement, so it is not proof that
the new workflow is feasible.

The phase-zero spike must choose and document one profile:

1. **Personal/development distribution:** a deliberately non-App-Sandbox native
   build plus a separately constrained worker execution mechanism; or
2. **Sandboxed distribution:** a read-write security-scoped library plus a bundled,
   signed helper/XPC/runtime design that satisfies App Sandbox restrictions.

The app may not silently fall from the second profile to the first. A separately
installed arbitrary Python or Codex executable is not assumed to be launchable from
a sandboxed release. See Apple's
[`Accessing files from the macOS App Sandbox`](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).

The spike passes only if an unsigned-development shortcut is not required for the
selected profile and a Release build can:

- create, reopen, and mutate a security-scoped library;
- launch and terminate the worker through `ExecutionHostPort`;
- limit transcription access to its job staging directory and read-only runtime/
  model assets;
- deny worker reads of unrelated fixtures and deny outbound network connections;
- survive cancellation, crash, app restart, and missing model/runtime state;
- report bounded redacted failures without transcript/path content.
- launch Codex through the existing ChatGPT-authenticated CLI without reading or
  copying its credentials, verify the pinned isolation profile, obtain one
  schema-valid fixture result, cancel cleanly, and leave no local rollout file.

Transcription and Codex need different policies. Cached ASR is no-network. Codex
has intentional OpenAI network access but no transcript-derived shell, browser,
plugin, project, or unrelated filesystem access. The official
[`codex exec` documentation](https://learn.chatgpt.com/docs/non-interactive-mode)
defines the non-interactive controls; Audora pins and startup-verifies its full
profile instead of inheriting user CLI configuration. It uses an empty scoped
working directory and a pinned `--skip-git-repo-check` flag; it does not initialize
or expose an Audora/user repository merely to satisfy Codex's default Git check.

## Engine-use policy

Every transcription revision stores an engine descriptor and a reviewed policy:

```text
EngineUsePolicy
  policyVersion
  licenseReference
  coveredArtifacts
  privateLocalEvaluationAllowed
  privateUserExportAllowed
  externalProcessingAllowed
  publicDistributionAllowed
  commercialUseAllowed
```

Application use cases enforce this policy before export, coaching, or distribution
features. Presentation only explains a decision; it cannot override one.

The CrisperWhisper inference code and model assets have different terms. The v2
Small model license restricts weights and generated outputs to non-commercial
research use unless separate written permission is obtained. Therefore:

- Crisper Small is the current personal evaluation candidate, not an unconditional
  distributable default;
- commercial/public Audora release is blocked on written permission or a
  compatible replacement engine;
- external transmission of its transcript, timestamps, confidence values, or
  derived annotations to Codex is disabled;
- copy/export is limited to the user's private local non-commercial evaluation;
  public sharing/distribution is disabled because Audora cannot impose the model
  license's recipient contracts merely by adding a notice.

The authoritative terms are the
[`CrisperWhisper2.0 Small model license`](https://huggingface.co/nyralabs/CrisperWhisper2.0_small/blob/4c0619b/LICENSE.md).
The stored engine policy records the reviewed license revision/content hash so a
later upstream edit cannot silently alter an existing decision.

## Runtime pin and compatibility patch

The evaluated macOS path is Python, PyTorch/MPS, and Transformers—not native Swift
or Core ML. The production descriptor pins hashes/versions for Python, package
lock, Transformers, PyTorch, model revision, decoding options, and Audora's patch.

The current evaluated upstream release has two integration gaps:

- its Transformers path can import CT2-only code from hallucination handling even
  when CT2 is not installed; and
- its long-form loop has no supported progress callback.

Audora must either pin a reviewed upstream fix or maintain a minimal tested patch.
An inert fake module, unbounded dependency range, or scraping stderr is not a
production solution. The worker `hello` reports the exact resolved versions and
patch ID; mismatches fail before audio processing.

## Qualification corpus

The provisional engine becomes the selected v1 engine only after Release-mode,
offline tests on the supported Apple Silicon/macOS baseline cover:

- short clips and at least 1-, 12-, and 30-minute recordings;
- quiet speech, fillers, repetitions, cutoffs, laughter, long pauses, and final
  underfilled/tail speech;
- word-timestamp monotonicity, end coverage, and playback seeking;
- substitutions, omissions, pathological n-gram loops, and output collapse;
- cold/warm real-time factor, peak memory footprint, thermals, cancellation, and
  worker reclamation;
- missing/corrupt model behavior and no-network cached inference.

Acceptance uses hand-labeled fixtures and thresholds. It does not claim perfect
word recovery. Gate zero must publish numeric corpus-coverage, integrity, runtime,
memory, and thermal thresholds in a versioned qualification fixture before the
engine is selected; this RFC intentionally does not invent them after one
benchmark. If Crisper fails qualification or licensing, the engine contract remains
and the replacement decision updates the central RFC before implementation.
