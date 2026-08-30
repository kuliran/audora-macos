# Attempt-scoped transcript-read broker qualification

This self-contained Swift package qualifies Audora's narrow, read-only transcript
egress boundary with committed synthetic data. It never opens a Library, reads
Codex authentication state, launches a user browser, or places a capability in a
URL, prompt, argument, report, or fixture.

This gate is **synthetic only**. It does not qualify the current Codex CLI/model
pair for production coaching.

## Reproduce

Run the deterministic broker, MCP, contract, and loopback attack suite on macOS:

```sh
cd Qualification/TranscriptReadBroker
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/audora-transcript-read-swiftpm-cache \
CLANG_MODULE_CACHE_PATH=/tmp/audora-transcript-read-clang-cache \
swift test --disable-sandbox
```

The loopback cases must be allowed to bind an OS-selected port on `127.0.0.1`.

Run the metadata-only synthetic qualification command:

```sh
swift run transcript-read-broker-qualification
```

The command emits one JSON object. It contains pass/fail metadata and closed
shipping blockers, never transcript text, app-only identities, handles,
capability material, paths, or raw diagnostics.

## Boundary

`TranscriptReadBroker` is one Swift actor with two lifecycle operations:

```swift
read(capability:requestBody:)
revoke(reason:)
```

Each grant creates a 256-bit capability and fresh lowercase UUID handles. The
broker stores only the capability digest and a frozen handle-to-revision map. It
accepts one unique nonempty ordered subset, stages every exact revision in memory,
revalidates every provider-visible timed range against the app-only canonical
duration and its enclosing line, then returns one canonical complete response or
no transcript content. Ranges are strictly half-open (`0 <= startMs < endMs <=
durationMs`); a Word may remain explicitly untimed. A complete response may be
replayed once for exact transport redelivery; any changed, reordered, split, or
third request closes the grant.

The response fit check uses `CompleteToolResponseBudget` from the issue-#6 context
estimation package. That seam frames and tokenizes the complete canonical tool
response as one model-visible message. The broker contains no token heuristic.

`TranscriptReadMCPBoundary` admits only MCP initialize/ping/tool discovery and
`tools/call` for `read_session_transcripts`. Its advertised input schema is checked
against the committed `ReadSessionTranscriptsRequest.json`. Semantic duplicate
rejection remains in the broker because the generated schema intentionally has no
`uniqueItems` constraint.

`LoopbackTranscriptReadHTTPServer` binds only IPv4 `127.0.0.1` on an ephemeral
port. It accepts one bounded HTTP/1.1 request per connection, uses close-on-exec
descriptors, rejects transfer encoding, duplicate headers, excess bytes, invalid
Host/content type/origin, and partial bodies after a fixed timeout, and emits no
redirect or CORS headers. The listener and every accepted connection have a
serialized descriptor owner: stop waits for any bounded in-flight syscall, closes
once, and makes later operations observe closed state before they can touch a
reused descriptor number. Configuration caps headers at 64 KiB, request bodies at
1 MiB, and request timeouts at 30 seconds; connection-backlog and byte arithmetic
use checked conversions. Every terminal MCP or Attempt path closes the listener,
connections, cached response, handles, and capability digest.

## Attack coverage

The suite covers fresh cross-Attempt authority, valid subset ordering, malformed
and duplicate requests, mixed valid/foreign scope, missing/corrupt/erroring exact
revisions, exact-budget failure, bounded byte-identical redelivery, second semantic
reads, simultaneous reads, cancellation races, all external revocation reasons,
forbidden data operations, MCP surface reduction, bearer/Host/origin attacks,
malformed and oversized messages, live loopback closure, partial-body timeout,
stop-versus-accept and stop-before-receive descriptor-reuse races, overflowing
configuration/content lengths, zero/reversed/negative/out-of-duration timing,
timed-Word parent containment, contract round trips, and recursive provider/report
canary scans.

All storage fixtures are synthetic. Storage failures containing transcript, path,
and token canaries are reduced to the closed `sessionUnavailable` response without
including the underlying error.

## Production status

The real Codex case is deliberately recorded as `notRun`. Issue #5 established
that Codex CLI 0.143.0 is not a qualified provider: an authenticated structured
response did not complete, no documented provider-side output ceiling exists, and
the shipping core tool surface was not proven reducible to only this scoped tool.
Issue #6 supplies exact estimation mechanics, but the shipping CLI/model pair still
lacks a qualified tokenizer and complete hidden-framing evidence. This package does
not weaken those blockers or use a different engine to manufacture a pass.

See [RESULTS.md](RESULTS.md) for the recorded gate result.
