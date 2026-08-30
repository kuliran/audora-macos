# Codex CLI qualification spike

This self-contained Swift package exercises the process and trust-boundary
assumptions required by Audora's future Codex-backed `CoachProvider` adapter. It
uses only the committed synthetic `CoachRequest` fixture and deliberately does
not read a Library, a credential value, browser state, user configuration, or raw
provider diagnostics.

This is a feasibility harness, not the production provider adapter. Its current
qualification decision is **not qualified**.

## Reproduce

Requirements:

- macOS with Swift 6;
- an absolute path to Codex CLI 0.143.0 or a version being requalified; and
- an existing ChatGPT-authenticated Codex installation. The harness lets Codex
  use its authentication normally but never reads, copies, prints, or modifies
  the credential store.

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

Run the synthetic authenticated cases:

```sh
swift run codex-cli-qualification \
  --codex /absolute/path/to/codex \
  --model gpt-5.4 \
  --case all
```

`--case` also accepts `structuredResponse`, `cancellation`, or `timeout`. The
command emits a metadata-only JSON report and exits nonzero when an exercised
case misses its expected outcome. It never emits the Coach Response or raw
standard error.

The implementation follows the documented Codex non-interactive controls:
`--ephemeral`, `--ignore-user-config`, `--ignore-rules`, `--output-schema`, an
empty `--cd`, and inline configuration overrides. See the official
[Codex developer-command reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli)
and [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).

## Confinement

Each case creates a unique temporary scope with two siblings:

- an empty `workspace/`, which is the CLI working directory; and
- `transport/`, containing only the synthetic response schema and a generated,
  text-only model catalog.

The process plan then applies these defenses:

| Boundary | Enforcement |
| --- | --- |
| User/project instructions | `--ignore-user-config`, `--ignore-rules`, zero project-doc bytes, no fallback names or root markers, and an empty workspace |
| Rollout/history | `--ephemeral` and history persistence disabled |
| Shell and patch | shell/unified-exec features disabled; generated model metadata sets `shell_type` to `disabled` and has no apply-patch tool |
| Browser, web, and generic model network | browser/app/web/image features disabled and top-level web search set to `disabled`; only the Codex client itself can contact its provider |
| Plugins and MCP | user config ignored, plugin/app/tool-suggestion features disabled, and empty plugin, marketplace, and MCP maps |
| Environment | only `HOME`, `CODEX_HOME`, `PATH`, temporary-directory and locale values may pass through; token/key/secret/browser/session variables are dropped |
| Files | the model catalog is text-only, so the CLI's residual `view_image` entry rejects before reading; any emitted file/tool event fails the case |
| Output | one strict Markdown-only subset of `CoachResponse`; complete JSON, reported token use, event stream, response bytes, duration, and stderr inspection are bounded |

The prompt travels over standard input instead of process arguments. Raw stderr
is kept in a bounded, in-memory classifier only until the child is reaped. Public
results contain a closed reason, retry disposition, duration, sizes, and reaping
state—never provider prose, request content, paths, credentials, or raw output.

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

Signals normalize to bounded reasons:

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

## Exact context-estimation gate

The package also contains the provider-independent context planner needed before a
Coach process may launch. It serializes the contract JSON itself instead of
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

## Qualification result — 30 August 2026

Environment: Apple Silicon macOS, Codex CLI 0.143.0, ChatGPT login reported as
available by `codex login status`.

- The deterministic Swift suite passed 27 tests.
- The real synthetic cancellation case passed and reaped the CLI in 128 ms.
- The real synthetic timeout case passed and reaped the CLI in 137 ms.
- Both real cases left the initially empty scoped workspace empty.
- The authenticated structured-response case exited as sanitized
  `processFailure` after 4.3 seconds. No response was accepted and raw stderr was
  intentionally neither displayed nor retained.

The production adapter remains blocked on all of the following:

1. one authenticated valid `CoachResponse` under the pinned byte/token limits;
2. a provider-side output-token ceiling at or below `responseReservedTokens`;
3. a Codex surface that can reduce the model-visible tool list to no core tools
   plus, later, only Audora's scoped transcript read; and
4. real-environment qualification of authentication, quota, transient, and
   unavailable-model signals without weakening diagnostic redaction.

Until those points pass on the exact shipping CLI/model pair, Audora must not wire
this spike into the application composition root.
