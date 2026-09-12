# Codex CLI qualification spike

This self-contained Swift package exercises the process and trust-boundary
assumptions required by Audora's future Codex-backed `CoachProvider` adapter. It
uses only the committed synthetic `CoachRequest` fixture and deliberately does
not read a Library, a credential value, browser state, user configuration, or raw
provider diagnostics.

This is a feasibility harness, not the production provider adapter. Reports keep
behavioral case results separate from qualification decisions. `issueGateAccepted`
requires every case to pass under the exact fixed limits and independently proven
model-facing tool-surface confinement. `modelFacingToolSurfaceQualified` is fixed
to false for stock Codex CLI 0.143, and `productionProviderQualified` remains false
until the separately listed production limits are resolved. The legacy
`fullyQualifiedForProduction` field mirrors the latter decision.

## Reproduce

Requirements:

- macOS with Swift 6;
- an absolute path to Codex CLI 0.143.0 or a version being requalified.

No existing login is promised or required by the currently safe public path.
On 12 September 2026, the locally installed CLI was probed only with isolated
`--version` and help commands and reported `codex-cli 0.143.0`. That release
cannot accept the required
`tools.view_image=false` strict override. Its documented token input is a separate
`login` command, while an ephemeral credential exists only in the process that
received it, so it also has no verified nonpersistent path into the later `exec`
process. Restoring the ordinary home would allow ambient global instruction files
to be loaded and is not an acceptable workaround.

Run deterministic tests:

```sh
cd Qualification/CodexCLI
swift test
```

When SwiftPM itself is already running inside a sandbox, its nested sandbox may
need to be disabled and its build caches redirected to writable temporary
directories:

```sh
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/audora-codex-module-cache \
CLANG_MODULE_CACHE_PATH=/tmp/audora-codex-clang-cache \
swift test --disable-sandbox
```

Run the public compatibility check:

```sh
swift run codex-cli-qualification \
  --codex /absolute/path/to/codex \
  --model gpt-5.4
```

The bundled command performs only a bounded, isolated `--version` probe, emits a
sanitized preflight report, and exits nonzero before any provider case can launch.
The report records `providerCasesLaunched: 0`, separate status for image-tool
suppression and same-process ephemeral authorization, closed blocker codes, and
the manual handoff actions below. Unknown future versions remain `unverified`;
version/help output alone cannot prove that strict runtime configuration is
accepted. The single-case launch surface and lower-level invocation runner are
internal and exist only for deterministic process-fixture tests. No fabricated
case result is emitted by the blocked public path.

Fixture reports include only an allowlisted model identifier and a normalized
CLI product/ASCII-numeric version; untrusted version build metadata is discarded,
while malformed or prerelease identities become `unavailable`. They never emit
the Coach Response or raw standard error. Decoding rejects unsupported report
schemas, forged tool-surface evidence, and decisions that contradict the
schema-two payload; schema-one reports decode with conservative false decisions.

The implementation follows the documented Codex non-interactive controls:
`--ephemeral`, `--ignore-user-config`, `--ignore-rules`, `--output-schema`, an
empty `--cd`, and inline configuration overrides. See the official
[Codex non-interactive-mode reference](https://learn.chatgpt.com/docs/non-interactive-mode)
and [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).
The [authentication reference](https://learn.chatgpt.com/docs/auth) documents
ephemeral credential storage and stdin token login, while the
[AGENTS.md reference](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
documents that global instructions are loaded from `CODEX_HOME`.

## Confinement

Each internal deterministic fixture case creates a unique temporary scope with
three siblings:

- an empty `workspace/`, which is the CLI working directory; and
- an empty `client-home/`, used for both `HOME` and `CODEX_HOME`; and
- `transport/`, containing only the synthetic response schema and a generated,
  text-only model catalog.

The process plan then applies these defenses:

| Boundary | Enforcement |
| --- | --- |
| User/project instructions | source `HOME`/`CODEX_HOME` are replaced by the empty per-case client home, so global `AGENTS.md` and `AGENTS.override.md` files are absent; `--ignore-user-config`, `--ignore-rules`, `skills.include_instructions=false`, an empty skill configuration, `tools.experimental_request_user_input={enabled=false}`, zero project-doc bytes, no fallback names or root markers, and an empty workspace add independent layers |
| Rollout/history | `--ephemeral` and history persistence disabled |
| Authentication | the dormant clean profile pins `cli_auth_credentials_store="ephemeral"`; no `auth.json` is copied or linked and no credential environment variable is inherited. The public path refuses because 0.143 has no verified way to deliver authorization to the same ephemeral `exec` process |
| Shell and patch | shell/unified-exec features disabled; generated model metadata sets `shell_type` to `disabled` and has no apply-patch tool |
| Browser, web, and generic model network | browser/app/web features disabled, top-level web search set to `disabled`, and generated model metadata advertises text-only input with no search support; only the Codex client itself can contact its provider |
| Plugins and MCP | user config ignored, plugin/app/tool-suggestion features disabled, and empty plugin, marketplace, and MCP maps |
| Environment | source `HOME` and `CODEX_HOME` never pass through; both are replaced with the fresh client-home path, while only `PATH`, temporary-directory, and locale values may be inherited; token/key/secret/browser/session variables are dropped |
| Files and images | the dormant clean profile pins the currently documented `tools.view_image=false`; 0.143 is rejected by preflight before that unsupported override can reach provider execution. The model catalog is text-only, image-related features are disabled where supported, and emitted file, image, or executable-tool items fail the case |
| Output | exactly one completed agent response in a strict UTF-8 JSONL and Markdown-only subset of `CoachResponse`; duplicate object keys are rejected recursively in both layers, and unknown item shapes, integer token use, event stream, response bytes, duration, and stderr inspection are bounded |

The prompt travels over standard input instead of process arguments, and its
writer runs concurrently with lifetime monitoring so a non-reading CLI cannot
delay timeout or cancellation. Lifetime, grace, and reap deadlines use a monotonic
clock, and reaping polls without an unbounded blocking wait. Native process
spawning launches the requested CLI suspended as a dedicated process session; a
native process-event watcher is installed before it resumes, and no helper
executable is introduced. Any observed fork makes whole-process-tree reclamation
unprovable and fails closed even if the original process group is empty. A fixture
with a descendant that starts a new session, closes its pipes, and survives group
termination verifies that such a run is never reported as reaped.
Normal completion, cancellation, timeout, overflow, and the version probe all
terminate and reap that process group before bounded pipe transfers finish. Raw
pipe-reader shutdown is also bounded if a descendant detaches into another
session while retaining an inherited pipe, including a descendant that writes
continuously. Readers honor the shutdown signal before every subsequent read.
If inherited pipes do not reach EOF naturally, forced reader shutdown is reported
as a sanitized process failure rather than accepting a valid-looking prefix. Raw
stderr is kept in a bounded, in-memory classifier only until the group is reaped.
Public results contain a closed reason, retry disposition, duration, sizes, and
reaping state—never provider prose, request content, paths, credentials, or raw
output.

Cancellation and timeout remain subject to the same confinement boundary as a
normal exit: complete captured JSONL capability events are inspected first, so
a tool, file, or network item emitted before the stop is reported as
`forbiddenCapabilityUsed` rather than being hidden by the expected stop reason.
That check reads the item capability before applying the surrounding event-shape
allowlist, so new or extra event fields cannot hide it. Any non-whitespace
trailing JSONL fragment left by a stopped process is conservatively reported as
`malformedOutput` rather than ignored.
Cancellation additionally requires a well-shaped safe reasoning or agent-message
event acknowledging provider work before the stop. An elapsed 50 ms timer or an
idle executable alone therefore cannot pass the cancellation case.

## Bounds and mappings

The version-one spike fixtures use these qualification bounds:

| Limit | Value |
| --- | ---: |
| Complete structured response | 4,096 bytes |
| Reported total output usage | 4,096 tokens |
| Codex JSONL event collector | 256 KiB |
| Stderr classifier input | 64 KiB |
| Process lifetime | 90 seconds |
| Grace before forced termination | 2 seconds |

These are spike fixtures, not yet a qualified production
`CoachProviderDescriptor`. Codex CLI 0.143.0 has no documented provider-side
maximum-output-token flag, so the harness can reject reported token excess and
stop byte overflow but cannot prove the RFC's provider-side output ceiling.

Codex CLI 0.143's `error`, `turn.failed`, and completed error-item events carry a
message and may omit a code. Their messages are bounded by the JSONL collector and
normalized through the same closed pattern matcher as bounded stderr. When a
recognized stable code is present, it takes precedence over provider prose.
Messages are never copied into the report, and unmatched text becomes the closed
`processFailure` reason. Signals normalize to bounded reasons:

| Signal | Reason | Retry disposition |
| --- | --- | --- |
| login, unauthorized, invalid API authentication | `authentication` | user |
| billing, usage limit, insufficient quota | `quota` | user |
| rate limit, timeout, connection loss, temporary/server failure | `transient` | automatic |
| unknown or unavailable configured model | `unavailableModel` | user |
| non-JSON, wrong schema, missing usage, oversized complete output | `malformedOutput` or a closed size reason | user |
| launch/exit/unknown CLI failure | `processFailure` | user |
| cancellation or harness timeout | `cancelled` / `timedOut` | user / automatic |

Synthetic subprocess fixtures cover every mapping without manufacturing account
or quota failures.

Schema-two report decoding validates each case as a coherent outcome. Response
and token counts must be paired and nonnegative, retry disposition must match the
observed reason, and `passed` must agree with the case-specific response,
cancellation, or timeout evidence plus the reaping, workspace, and privacy
fields. Gate acceptance is derived from those validated fields rather than
trusting an encoded `passed` value. The report also records the complete exercised
limit profile. Issue-gate acceptance requires exactly `4,096` response bytes,
`4,096` output tokens, a 256 KiB event stream, 64 KiB of failure signal, a
90-second process lifetime, and a 2-second termination grace; observed response
and token counts must fit those limits. A relaxed qualification run remains
useful evidence but cannot accept the gate. Acceptance also requires
`modelFacingToolSurfaceQualified`; the field is fixed false because stock 0.143
always registers a model-visible `ViewImage` filesystem tool when an environment
is present, provides no supported strict-config or feature switch to remove it,
and omits that item from its JSONL event mapping. Text-only model metadata blocks
image execution before path access, but does not prove absence from model context.

## Exact context-estimation gate

The package imports the provider-independent context planner and canonical JSON
implementation from `AudoraApplication/CoachContext`, so qualification vectors and
the shipping Application seam exercise identical bytes. It serializes the contract JSON itself instead of
estimating from Swift strings or object counts. Canonical serialization is compact
UTF-8, preserves string contents without normalization, orders object keys by UTF-8
bytes, and escapes JSON control characters before measurement.

One provider estimation policy supplies its pinned tokenizer (or a documented
conservative upper bound), complete visible framing, hidden framing-token counts,
and response-collector byte ceiling. The planner measures the complete
model-visible message sequence, tokenizing each full provider frame so tool-call
boundaries cannot disappear, including:

- the structured Profile and current structured Coach Memory;
- every eligible successful history turn and the current trigger;
- all inline attachment values;
- every on-demand attachment descriptor plus one complete all-attachments atomic
  transcript-read request and response;
- provider instructions, adapter/tool framing, and hidden special tokens; and
- the configured response reserve and safety margin.

The whole-exchange token count is authoritative. Component costs are explanatory
estimates and intentionally are not summed, because independently tokenized pieces
can behave differently at tokenizer boundaries. Exact fit is accepted; one token
over the usable input ceiling is rejected without trimming any component.

Descriptor qualification performs the cross-field checks that JSON Schema cannot:
reserve plus margin must be strictly below the context window, and a structural
maximum-Memory fixture must measure exactly to `coachMemoryMaxTokens`. The fixture
is then placed in the minimum Request and minimum Response. The Request must fit
the usable input; the Response must fit the token reserve; and the response JSON's
worst-case byte bound, derived from the tokenizer's qualified maximum UTF-8 bytes
per token, must fit the collector.

Deterministic fixtures cover exact fit, one-token overflow, JSON escaping,
multiple large on-demand Sessions, maximum Memory, all descriptor inequalities,
and independent response token/byte failures. The UTF-8-byte estimator is a
conservative upper bound for byte-level tokenizers; provider special tokens must
still be supplied explicitly as framing.

No production `CoachProviderDescriptor` is claimed for Codex CLI 0.143.0. The
`128,000`/`80%` values in the generated synthetic model catalog configure this
isolated client fixture; they are not evidence of the selected account/model's
shipping context limit. The CLI/model pair also lacks a pinned exact tokenizer and
complete hidden-framing measurement, exposes no provider-side output-token cap,
and cannot yet expose only the scoped transcript-read tool. Those unknowns cannot
be converted into optimistic zero-cost fields.

## Historical qualification result — 30 August 2026

Environment: Apple Silicon macOS, Codex CLI 0.143.0, ChatGPT login reported as
available by `codex login status`.

- The deterministic Swift suite passed 28 tests.
- The real synthetic cancellation case passed and reaped the CLI in 128 ms.
- The real synthetic timeout case passed and reaped the CLI in 137 ms.
- Both real cases left the initially empty scoped workspace empty.
- The authenticated structured-response case exited as sanitized
  `processFailure` after 4.3 seconds. No response was accepted and raw stderr was
  intentionally neither displayed nor retained.

That run did not accept the issue gate because its structured-response case
failed. Current stock 0.143 also cannot accept it because model-facing filesystem
tool confinement cannot be proven. The historical run also predates isolated
client homes and is not valid privacy/confinement evidence: its invocation
inherited the ordinary `CODEX_HOME`, which could expose ambient global
instructions. The production adapter remains blocked on:

1. one authenticated valid `CoachResponse` under the pinned byte/token limits;
2. a provider-side output-token ceiling at or below `responseReservedTokens`;
3. qualification of an exact model-facing tool allowlist containing, later,
   only Audora's scoped transcript read, with no ambient filesystem tool; and
4. real-environment qualification of authentication, quota, transient, and
   unavailable-model signals without weakening diagnostic redaction.

Until those points pass on the exact shipping CLI/model pair, Audora must not wire
this spike into the application composition root.

### Manual handoff for a future clean run

1. Obtain an exact Codex CLI build whose authoritative schema has been
   independently verified to accept `tools.view_image=false` with strict config.
   Do not infer support from `--version` or `--help`; those commands can return
   before runtime configuration is loaded.
2. Require a documented mechanism that supplies an access token or API key to
   that same `codex exec` process while
   `cli_auth_credentials_store="ephemeral"`. A separate ephemeral `codex login`
   process is insufficient because its in-memory credential ends when it exits.
3. Add only that exact normalized CLI version to the source compatibility matrix,
   preserving the fresh empty `HOME`/`CODEX_HOME`, every existing feature/tool
   disable, and the bounded JSONL process host.
4. Rerun the public preflight and confirm it permits launch before supplying a
   qualification-only credential through the newly documented channel.

Never copy or link `auth.json`, query a keyring, inherit an ordinary Codex home,
or pass a credential through process arguments. Until both capabilities are
verified, the preflight must continue to report zero launched provider cases.
