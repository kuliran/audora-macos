# Signed Release execution spike

This ticket-scoped harness qualifies the macOS assumptions needed before Audora's
production composition root is built. It is intentionally independent of the
legacy app and has no third-party dependencies.

The Release app demonstrates:

- a signed, Hardened Runtime, deliberately non-App-Sandbox execution profile;
- one AppKit writer window that is focused for launch, reopen, and Window menu
  requests;
- an `NSOpenPanel` Library choice, a machine-local bookmark for reopen, and an
  atomically installed probe-owned mutation under
  `.audora-release-execution/`;
- an AVFoundation microphone-permission request with the required bundle purpose
  string;
- a child launched from a scoped working directory with an explicit environment
  containing only `PATH`, `LANG`, `LC_ALL`, and `TMPDIR`, then cancelled and
  synchronously reaped. macOS CoreFoundation may synthesize
  `__CF_USER_TEXT_ENCODING` inside the Foundation child; the runner permits that
  platform key and rejects every other addition; and
- real child termination immediately after partial write, partial flush, atomic
  install, and parent-directory flush. A new process then reads only `state.json`
  and verifies a complete old or complete new JSON value.

This is an execution-mechanics gate. It does **not** claim that a non-sandboxed
macOS process is OS-confined from unrelated files or the network; later worker
qualification supplies that stronger, engine-specific proof.

## Automated reproduction

From this directory:

```bash
./Scripts/qualify.sh
```

That command builds the optimized Swift product, assembles an app bundle, signs
it with Hardened Runtime, rejects an App Sandbox entitlement, verifies the
signature and arm64 slice, and runs the deterministic Library/process/atomic
checks in a disposable fixture Library.

The default identity is macOS ad-hoc signing (`-`), matching Xcode's **Sign to Run
Locally** profile. To qualify an identity-backed personal Release build, provide a
certificate name through the non-secret build setting (the script never searches
or reads the Keychain):

```bash
AUDORA_RELEASE_EXECUTION_CODESIGN_IDENTITY='Developer ID Application: Example (TEAMID)' \
  ./Scripts/qualify.sh
```

Unit tests can be run separately:

```bash
swift test
```

## Interactive reproduction

Build, then launch the signed bundle:

```bash
./Scripts/build-release.sh
open '.build/release-app/Audora Release Execution Spike.app'
```

In the window:

1. Choose a disposable `*.audoralibrary` directory. Confirm its generation is
   installed, quit/relaunch, and use **Mutate Again** to confirm reopen access.
2. Click **Request Microphone Permission** and record the TCC result. The harness
   requests access but never starts capture or writes audio.
3. Click **Run Automated Qualification**. It must report `PASS` and list all four
   complete-state interruption outcomes.
4. Close and reopen the app twice, then choose **Window → Focus Writer Window**.
   Activity Monitor and the app's Window menu should continue to show one process
   and one writer window.

The harness displays only the selected Library's basename and bounded error
categories. It does not log Library paths, child environment values, microphone
content, or user content.

## Expected atomic outcomes

| Injected child termination | Relaunch-visible state |
| --- | --- |
| After sibling partial write | Complete old state |
| After sibling partial flush | Complete old state |
| After atomic final install | Complete new state |
| After parent-directory flush | Complete new state |

Exit status `86` is reserved for the intentional atomic-write interruption. Any
other child status, malformed JSON, mixed payload, environment key, working
directory, cancellation, or reap mismatch fails qualification.
