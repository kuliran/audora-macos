# Qualification result — 2026-08-30

## Host

- Apple Silicon (`arm64`)
- macOS 26.6.2 (build 25G83)
- Xcode 26.6 (build 17F113)
- Apple Swift 6.3.3

## Reproducible commands

```bash
cd Qualification/ReleaseExecution
swift test
./Scripts/qualify.sh
```

## Recorded automated outcome

The unit suite passed 7 tests with 0 failures. The Release qualification emitted:

```text
release-build: PASS configuration=Release architecture=arm64
signature: PASS hardened-runtime=true app-sandbox=false identity=-
library-mutation: PASS generation 1 -> 2 after reopen
child-process: PASS launched=true ready=true working-directory=scoped environment=scrubbed cancelled=true reaped=true
atomic-partialWritten: PASS visible=old expected=old interruption-status=86
atomic-partialFlushed: PASS visible=old expected=old interruption-status=86
atomic-finalInstalled: PASS visible=new expected=new interruption-status=86
atomic-directoryFlushed: PASS visible=new expected=new interruption-status=86
overall: PASS
automated-qualification: PASS
```

Independent inspection reported an arm64 app bundle, empty entitlements, and code
directory flags `adhoc,runtime`. The script's signature verification and
designated-requirement check both passed.

## External manual qualification still required

The host run used the ad-hoc **Sign to Run Locally** identity because no signing
certificate name was supplied; the build script intentionally does not enumerate
or inspect the user's Keychain. Before treating an identity-backed personal build
as qualified, rerun with `AUDORA_RELEASE_EXECUTION_CODESIGN_IDENTITY` set to the
intended certificate name.

The visible `NSOpenPanel`, microphone TCC decision, and Launch Services focus
behavior require a human desktop run. Follow the interactive steps in
[`README.md`](README.md) and record the chosen test Library, permission result,
and one-window observation without committing the Library path. The minimum
supported macOS 15 baseline also remains to be exercised; this recorded run was on
macOS 26.6.2.
