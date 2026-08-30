# Audora macOS

Audora is being rebuilt as a private, local-first macOS speech coach. The
[product RFC](rfc/README.md) is the canonical product and architecture
specification.

The native target currently provides the new composition root: one singleton
Library window with a static placeholder. It depends only on Apple platform SDKs
and intentionally performs no startup work. Product features will be added as
vertical slices against the RFC's Domain, Application, and adapter boundaries.

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
