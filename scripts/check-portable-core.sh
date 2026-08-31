#!/bin/sh

set -eu

portable_gate_stage=initialization

report_portable_gate_failure() {
  portable_gate_status=$?
  trap - 0
  if [ "$portable_gate_status" -ne 0 ]; then
    printf '::error title=Portable core gate::Failed stage: %s\n' \
      "$portable_gate_stage" >&2
  fi
  exit "$portable_gate_status"
}

trap report_portable_gate_failure 0

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

cd "$project_dir"

portable_gate_stage='Swift toolchain'
swift --version

portable_gate_stage='AudoraDomain release build'
swift build --package-path Packages/AudoraCore \
  --configuration release --product AudoraDomain
portable_gate_stage='AudoraApplication release build'
swift build --package-path Packages/AudoraCore \
  --configuration release --product AudoraApplication
portable_gate_stage='AudoraContracts release build'
swift build --package-path Packages/AudoraCore \
  --configuration release --product AudoraContracts
portable_gate_stage='portable Core tests'
swift test --package-path Packages/AudoraCore --parallel
portable_gate_stage='feature scenario tests'
swift test --package-path Packages/AudoraCore \
  --filter AudoraFeatureScenarioTests

portable_gate_stage='coach context interface guard'
sh scripts/check-coach-context-interface.sh

forbidden_imports='^import (SwiftUI|AppKit|AVFoundation|Combine|Observation|CoreAudio|Metal|MetalPerformanceShaders|Network|FoundationNetworking|Darwin|Glibc)$'
portable_gate_stage='platform import guard'

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
