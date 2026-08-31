# Audora macOS

Audora is being rebuilt as a private, local-first macOS speech coach. The
[product RFC](rfc/README.md) is the canonical product and architecture
specification.

The native target provides one singleton Library window and the first vertical
slices through the new architecture. At launch, Presentation sends typed
commands, Application resolves state through injected macOS adapters, and SwiftUI
renders immutable Library and Recording snapshots. Recording stages a locked
16 kHz mono `pcmS16LE` representation, records unavailable intervals explicitly,
and publishes one immutable Session only after flush, atomic install, and strict
reread. The portable Domain, Application, and Contracts products remain separate
from the macOS-only Infrastructure and Presentation products.

## Requirements

- Apple Silicon Mac
- macOS 15 or newer
- Full Xcode (Command Line Tools alone are insufficient)

## Build and run

Open `audora.xcodeproj`, select the shared `Audora` scheme and **My Mac**, then
run. The target uses the `com.audora.local` bundle identifier and keeps Hardened
Runtime enabled.

For a signing-free command-line build:

```sh
xcodebuild \
  -project audora.xcodeproj \
  -scheme Audora \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/audora-debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Qualification gates are kept under [`Qualification/`](Qualification/). They are
development evidence and are not part of the native application target.

## Tests and contracts

Run the portable Swift 6 release builds, tests, golden scenario, and dependency
guard with:

```sh
scripts/check-portable-core.sh
```

Run the macOS adapter and Presentation tests with:

```sh
swift test --package-path Packages/AudoraMac --parallel
```

Those tests use synthetic input buffers and disposable Libraries. They do not
request microphone permission or qualify physical microphone capture; see the
[Recording qualification note](Qualification/Recording/README.md).

Contract schemas and fixtures are package resources generated from TypeSpec. With
the pinned Node 24 and pnpm toolchain installed, verify them with:

```sh
pnpm contracts:check
```
