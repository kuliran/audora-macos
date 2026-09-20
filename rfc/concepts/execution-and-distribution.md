# Execution, engine qualification, and distribution

This document defines gates that must be answered with working Release-mode spikes.
It is not legal advice and does not assume that a development setup is suitable for
distribution.

Version one is a private, non-commercial personal-use build. “Release-mode” below
means the optimized, signed execution path used for acceptance; it does not imply
public distribution.

## App and worker execution profiles

Version one selects a signed, Hardened Runtime, deliberately non-App-Sandbox native
build. It needs persistent read/write access to a user-selected Audora Library, a
separately constrained local transcription worker, and the user's installed
ChatGPT-authenticated Codex CLI. The current legacy target's read-only App Sandbox
entitlement is not carried forward.

App Sandbox with bundled, signed helper/XPC privilege separation is backlog. It is
not a hidden alternate version-one profile. See Apple's
[`macOS distribution comparison`](https://developer.apple.com/macos/distribution/)
and [`Hardened Runtime`](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime)
documentation. Hardened Runtime is part of the selected signing profile; it is not
a filesystem or network sandbox.

The spike passes only if an unsigned-development shortcut is not required for the
selected profile and a Release build can:

- create, reopen, and mutate a user-selected Library;
- launch and terminate the worker through `ExecutionHostPort`;
- limit transcription access to job staging plus read-only runtime/model assets;
- deny worker reads of unrelated fixtures and deny outbound network connections;
- survive cancellation, crash, app restart, and missing model/runtime state;
- report bounded redacted failures without transcript or path content;
- launch Codex through the existing ChatGPT-authenticated CLI without reading or
  copying credentials, expose only Audora's transcript-read tool, obtain one valid
  structured result, cancel cleanly, revoke the Attempt capability, and leave no
  local rollout file;
- identify safe provider-error text without displaying raw CLI stderr; and
- reject a context budget whose response reserve plus safety margin reaches the
  context window; and
- prove the maximum valid structured Coach Memory fits inside both the minimum
  Request's usable input and the minimum Response's `responseReservedTokens` and
  collector byte ceiling.

The ticket-scoped
[`WorkerConfinement` qualification](../../Qualification/WorkerConfinement/README.md)
provides the deny-by-default launch profile, bounded process host, synthetic
attack worker, and recorded result for the transcription subset of this gate. Its
synthetic restriction proof passes on the recorded host, but production Crisper
execution admission remains blocked until the exact runtime/model and a non-null
compatibility patch are supplied and real cached MPS inference passes on the
supported macOS 26 execution profile.

Transcription and Codex need different policies. Cached ASR is no-network and must
pass the stronger worker-confinement tests above. Codex has intentional OpenAI
network access. Audora passes a bounded structured envelope through standard input
from an empty scoped working directory, disables inherited tools, and exposes no
model-facing shell, browser, plugin, project, Library, or filesystem tool. The
envelope contains the current structured Profile, current structured Coach Memory,
successful Chat history, current trigger, attachment metadata, and any small inline
transcripts. Every field is untrusted data, not an instruction.

The allowlisted transcript operation accepts one nonempty array of fresh
`SessionTranscriptHandle`s and atomically returns every requested immutable Chat
attachment or no transcript content. It accepts no path, arbitrary Session ID,
query, write, audio, Profile, or listing request. A complete Coach Response may
contain message blocks, optional `newMemory`, and proposed Profile effects, but only
Application can publish a Chat turn or commit a Profile Revision.

One hidden bearer capability is created per Provider Attempt, scoped to the Chat's
immutable attachments, configured outside model content, and revoked when the
Attempt ends. The model sees stable Chat-scoped attachment IDs plus fresh temporary
handles for on-demand attachments. The app-only Session/Transcript Revision key
never enters provider JSON. Transcript responses are admitted against remaining
context as a whole and terminate as `complete`, `sessionUnavailable`, or
`contextCannotFit`; no variant contains partial content. A failure terminates the
Attempt and becomes the ordinary UserRetryable turn failure. Application owns
transport retry, context limits, and Provider Attempt retry.

Every automatic Attempt and user Retry receives a fresh Attempt ID,
provider-idempotency key, handles, and capability. Adapter-local redelivery of the
same live call may reuse its idempotency key and cached tool Response. Provider
output is not durably staged for relaunch: unfinished work becomes interrupted and
user Retry creates a new Invocation.

Chat creation shows Session duration and estimated transcript cost. Every
Invocation measures the actual Profile, Memory, successful history, trigger, fixed
overhead, and conservative full on-demand exchange. Any requested subset therefore
fits an admitted Invocation without model-visible estimates. If the prepared turn
does not fit, Application creates the local capacity failure without launching
Codex; the read-time check remains a fail-closed defense against qualification or
state-integrity drift.

This is task-level Codex confinement. Because the selected host is not App
Sandboxed, Audora does not claim that macOS prevents the authenticated CLI process
from every unrelated filesystem read. The CLI retains the ordinary OS access it
needs for its executable, authentication state, and OpenAI connection; Audora does
not inspect, read, or copy that authentication state. The official
[`codex exec` documentation](https://learn.chatgpt.com/docs/non-interactive-mode)
defines the non-interactive controls; Audora pins and startup-verifies its full
profile instead of inheriting user CLI configuration. It uses an empty scoped
working directory and a pinned `--skip-git-repo-check` flag; it does not initialize
or expose an Audora/user repository merely to satisfy Codex's default Git check.
The official [Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)
defines the supported local STDIO and Streamable HTTP transports; the qualified
Codex adapter may choose either without changing the provider contract.

## Engine-use policy

Every transcription revision stores an engine descriptor and a reviewed policy:

```text
EngineUsePolicy
  policyID
  coveredArtifacts
  privateLocalUseAllowed
  privateExportAllowed
  externalProcessingAllowed
  publicDistributionAllowed
  commercialUseAllowed
  licenseReference
  licenseSHA256
```

Application use cases enforce this policy before export, coaching, or distribution
features. Presentation only explains a decision; it cannot override one.
Accepted Profile Statements derived from covered engine Output retain a reference
or snapshot of that policy. Acceptance, moving a Session to Trash, and externally
missing source evidence do not erase the obligation. When the complete Profile is mandatory
coaching context, any active Statement with `externalProcessingAllowed = false`
blocks the entire coaching request rather than being silently omitted.

The CrisperWhisper inference code and model assets have different terms. The
inference software is MIT-licensed. The v2 Small model license separately covers
the weights and broadly defined Outputs, including transcripts, timestamps,
confidence values, intermediate representations, and derived annotations.

The license does not name Codex, OpenAI, external inference, or cloud processors,
and it does not categorically prohibit passing Output to another AI for
inference. It does, however:

- permit model and Output use only within its defined Non-Commercial Use;
- exclude production or operational deployment of Licensed Materials and
  Derivative Works from that definition, leaving routine personal-product use of
  the weights unresolved;
- prohibit using Outputs to train, fine-tune, distill, or otherwise improve a
  machine-learning model intended for commercial use or distribution; and
- require non-commercial Output distribution/publication to mark the Output and
  contractually bind recipients to the applicable license restrictions.

The product owner has fixed version one to a private, non-commercial personal
build and accepts Crisper Small for that scope. The corresponding selected
`EngineUsePolicy` permits private local use, private export, and user-triggered
external processing by the qualified Codex provider. It continues to prohibit
commercial use and public distribution.

External processing is conditional on the qualified provider configuration using
an account or service policy under which submitted content is not used to train or
improve the provider's models. Absence of audio is useful data minimization, but it
is not the training safeguard: transcript text alone could be training material
for a language model. The provider's no-training data control is the operative
condition. Audora sends transcript evidence only after an explicit Speaker action
and never sends the source audio.

For the selected ChatGPT-authenticated Codex CLI on a personal plan, the product
owner attested on 20 September 2026 that **Improve the model for everyone** is
off. The self-reported evidence is recorded under
[`Qualification/CodexCLI/evidence`](../../Qualification/CodexCLI/evidence/chatgpt-data-controls-owner-attestation-2026-09-20.json)
without inspecting account or browser state. OpenAI documents that this account
setting applies to Codex tasks. `--ephemeral` does not prove the account setting,
and the attestation alone does not qualify a provider: its exact content hash must
still be bound to the shipping authentication/runtime configuration. A future
managed workspace or API adapter may instead bind its applicable no-training
policy to the same provider-neutral assurance. See OpenAI's
[`Data Controls FAQ`](https://help.openai.com/en/articles/7730893-data-controls-faq).

This is the product owner's recorded policy decision and accepted licensing risk
for the private personal build, including the license's separately worded
operational-use and recipient obligations. It is not legal advice or a general
interpretation granting commercial or public rights. A future provider or account
posture that cannot establish the same no-training condition fails closed at
provider qualification even though the persisted engine policy permits external
processing in principle.

Previously persisted Transcript Revisions whose immutable policy records
`externalProcessingAllowed = false` are not rewritten by this decision. They stay
ineligible for Coach context unless the Speaker deliberately reprocesses the
source into a new Revision carrying the reviewed policy and exact execution
provenance.

The authoritative terms are the
[`CrisperWhisper2.0 Small model license`](https://huggingface.co/nyralabs/CrisperWhisper2.0_small/blob/4c0619bf87d2d4b7e15e68292dd8402aae4101f8/LICENSE.md).
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

Qualification has two deliberately separate milestones. Real implementation may
proceed after **execution admission** proves the exact runtime/model lock, non-null
compatibility patch, worker confinement, cached offline inference, cancellation,
and candidate-validation boundary. Execution admission must use real Crisper
inference and cannot be replaced with a fixture provider or a bypass flag.

Before Audora is declared release-ready, **release qualification** must additionally
run Release-mode offline tests on the supported Apple Silicon/macOS baseline that
cover:

- short clips and at least 1-, 12-, and 45-minute recordings;
- quiet speech, fillers, repetitions, cutoffs, laughter, long pauses, and final
  underfilled/tail speech;
- word-timestamp monotonicity, end coverage, and playback seeking;
- substitutions, omissions, pathological n-gram loops, and output collapse;
- cold/warm real-time factor, peak memory footprint, thermals, cancellation, and
  worker reclamation;
- missing/corrupt model behavior and no-network cached inference.

The product owner's prior testing on personal recordings selects Crisper as the
implementation target; it is not reproducible corpus evidence and is not recorded
as a benchmark pass. Hand-labeled fixtures, the full 45-minute run, and their
quality/timing/performance thresholds remain deferred release evidence. Their
missing state must stay explicit in the manifest and reports until the real run is
performed. The pinned profile, predeclared thresholds, reproducible runner, and
current blocked release preflight are published under
[`Qualification/CrisperBenchmark`](../../Qualification/CrisperBenchmark/README.md).
That blocked release result no longer prevents construction of the real adapter;
it does prevent claiming the 45-minute workflow and release thresholds have
passed. If Crisper later fails execution admission or deferred release
qualification, the engine contract remains and the replacement decision updates
the central RFC.
