#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
APP_PATH="$PACKAGE_DIRECTORY/.build/release-app/Audora Release Execution Spike.app"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/release-execution-spike"
QUALIFICATION_ROOT="$(mktemp -d /tmp/audora-release-execution.XXXXXX)"
FIXTURE_LIBRARY="$QUALIFICATION_ROOT/Fixture Library.audoralibrary"

cleanup_qualification_root() {
    case "$QUALIFICATION_ROOT" in
        /tmp/audora-release-execution.*|/private/tmp/audora-release-execution.*)
            rm -rf "$QUALIFICATION_ROOT"
            ;;
        *)
            echo "Refusing to clean an unexpected qualification path." >&2
            ;;
    esac
}
trap cleanup_qualification_root EXIT

"$SCRIPT_DIRECTORY/build-release.sh"

mkdir -p "$FIXTURE_LIBRARY"
"$EXECUTABLE_PATH" qualify --directory "$FIXTURE_LIBRARY"

echo "automated-qualification: PASS"
echo "manual-ui-command: open '$APP_PATH'"
