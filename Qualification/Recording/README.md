# Recording qualification

The automated Recording gate is reproducible and synthetic. It exercises the
actor-serialized capture port, canonical PCM conversion, mute and capture-gap
timelines, exact frame boundaries, append-only staging, fault injection,
no-replace Session publication, relaunch recovery, identity-scoped discard, and
the accessibility Presentation mapper against disposable Libraries.

It deliberately does **not** request microphone permission, open microphone
hardware, inspect device identifiers, or read user recordings. The shipping
composition implements an AVFoundation input source and requests access only in
response to the user choosing Record. Permission denial, unsupported input, and
engine-start failure become bounded semantic outcomes without raw errors or
device identity crossing the Infrastructure boundary.

Physical behavior remains an external qualification item. A signed Release build
must be tested on the supported macOS/hardware matrix for permission denial and
revocation, input-format changes, sleep/wake and device interruption, buffer
discontinuities, real-time level behavior, and the exact 40/44/45-minute
transitions. Implemented hardware support is not evidence that those cases passed;
that evidence cannot be inferred from fake-source CI.
