#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
BUILD_OUTPUT_DIRECTORY="$PACKAGE_DIRECTORY/.build/release-app"
APP_PATH="$BUILD_OUTPUT_DIRECTORY/Audora Release Execution Spike.app"
CONTENTS_PATH="$APP_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$PACKAGE_DIRECTORY/Resources"
SIGNING_IDENTITY="${AUDORA_RELEASE_EXECUTION_CODESIGN_IDENTITY:--}"

case "$APP_PATH" in
    "$PACKAGE_DIRECTORY/.build/"*) ;;
    *)
        echo "Refusing an unexpected build output path." >&2
        exit 2
        ;;
esac

swift build \
    --package-path "$PACKAGE_DIRECTORY" \
    --configuration release \
    --product release-execution-spike

SWIFT_BINARY_DIRECTORY="$(
    swift build \
        --package-path "$PACKAGE_DIRECTORY" \
        --configuration release \
        --show-bin-path
)"
SWIFT_BINARY_PATH="$SWIFT_BINARY_DIRECTORY/release-execution-spike"

if [[ ! -x "$SWIFT_BINARY_PATH" ]]; then
    echo "Release executable was not produced." >&2
    exit 3
fi

rm -rf "$APP_PATH"
mkdir -p "$MACOS_PATH"
cp "$SWIFT_BINARY_PATH" "$MACOS_PATH/release-execution-spike"
cp "$RESOURCES_PATH/Info.plist" "$CONTENTS_PATH/Info.plist"
chmod 0755 "$MACOS_PATH/release-execution-spike"

plutil -lint "$CONTENTS_PATH/Info.plist"
plutil -lint "$RESOURCES_PATH/ReleaseExecutionSpike.entitlements"

SIGNING_ARGUMENTS=(
    --force
    --options runtime
    --entitlements "$RESOURCES_PATH/ReleaseExecutionSpike.entitlements"
    --sign "$SIGNING_IDENTITY"
)
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    SIGNING_ARGUMENTS+=(--timestamp)
fi

codesign "${SIGNING_ARGUMENTS[@]}" "$APP_PATH"
codesign --verify --strict --verbose=2 "$APP_PATH"

SIGNATURE_DESCRIPTION="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
if [[ ! "$SIGNATURE_DESCRIPTION" =~ flags=.*\(.*runtime.*\) ]]; then
    echo "Signature does not enable Hardened Runtime." >&2
    exit 4
fi

SIGNED_ENTITLEMENTS="$(codesign --display --entitlements :- "$APP_PATH" 2>/dev/null)"
if [[ "$SIGNED_ENTITLEMENTS" == *"com.apple.security.app-sandbox"* ]]; then
    echo "App Sandbox entitlement is present in the selected non-sandbox profile." >&2
    exit 5
fi

ARCHITECTURES="$(lipo -archs "$MACOS_PATH/release-execution-spike")"
if [[ " $ARCHITECTURES " != *" arm64 "* ]]; then
    echo "Release harness does not contain the required arm64 architecture." >&2
    exit 6
fi

echo "release-build: PASS configuration=Release architecture=arm64"
echo "signature: PASS hardened-runtime=true app-sandbox=false identity=$SIGNING_IDENTITY"
echo "artifact: $APP_PATH"
