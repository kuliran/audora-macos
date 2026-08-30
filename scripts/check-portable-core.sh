#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

cd "$project_dir"

swift --version

swift build --package-path Packages/AudoraCore \
  --configuration release --product AudoraDomain
swift build --package-path Packages/AudoraCore \
  --configuration release --product AudoraApplication
swift build --package-path Packages/AudoraCore \
  --configuration release --product AudoraContracts
swift test --package-path Packages/AudoraCore --parallel
swift test --package-path Packages/AudoraCore \
  --filter AudoraFeatureScenarioTests

forbidden_imports='^import (SwiftUI|AppKit|AVFoundation|Combine|Observation|CoreAudio|Metal|MetalPerformanceShaders|Network|FoundationNetworking|Darwin|Glibc)$'

if command -v rg >/dev/null 2>&1; then
  if rg -n "$forbidden_imports" Packages/AudoraCore/Sources; then
    echo 'platform import entered portable core' >&2
    exit 1
  fi
else
  if grep -R -n -E "$forbidden_imports" Packages/AudoraCore/Sources; then
    echo 'platform import entered portable core' >&2
    exit 1
  fi
fi
