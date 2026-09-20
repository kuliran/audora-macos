# Transcript-read broker qualification result

Recorded 8 September 2026 on Apple Silicon macOS with Swift 6.

- All 34 deterministic broker, MCP, schema, lifecycle, sanitization, concurrency,
  and live loopback tests passed.
- The loopback listener bound only `127.0.0.1` on an OS-selected ephemeral port,
  returned no redirect or CORS authority, and was closed on normal completion and
  protocol failure.
- A partial HTTP body was stopped by the fixed request timeout, returned one
  sanitized closed error, touched no transcript storage, and revoked the Attempt.
- Forced descriptor reuse after stop could not induce a late listener or accepted-
  connection syscall; overflowing configuration and Content-Length values failed
  closed without storage access or reflected input.
- Complete responses were canonical and byte-identical on the sole allowed replay;
  replay required the same bounded transport request identity and exact request
  bytes, while a new identity, changed bytes, and non-exact numeric RPC identity
  failed closed before another storage read.
- Unavailable, corrupt, and budget-failed batches returned no partial transcript.
- Zero-length, reversed, negative, out-of-duration, and parent-escaping timed
  evidence returned no transcript; explicitly untimed Words remained valid.
- Provider-visible requests, responses, discovery, errors, and the public report
  contained no capability, Library path, Session ID, or Transcript Revision ID
  canary.
- The metadata-only synthetic qualification command passed five runtime checks and
  reported `productionQualified: false` and `realCodexExercise: notRun`.

The broker gate passes for synthetic fixtures. The Codex Coach Provider remains
unqualified until the exact shipping CLI/model pair proves an authenticated valid
structured response, provider-side output ceiling, scoped model-visible tool
surface, pinned tokenizer, complete hidden framing, and a qualification-bound
assurance that submitted content is prohibited from provider training/model-
improvement use.
