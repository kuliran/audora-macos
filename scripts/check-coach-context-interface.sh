#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
core_package="$project_dir/Packages/AudoraCore"
module_cache="$core_package/.build/coach-context-interface-module-cache"

if [ -n "${AUDORA_APPLICATION_MODULES_DIR:-}" ]; then
  modules_dir=$AUDORA_APPLICATION_MODULES_DIR
else
  modules_dir=
  for candidate in \
    "$core_package"/.build/*/debug/Modules \
    "$core_package"/.build/debug/Modules \
    "$core_package"/.build/*/release/Modules \
    "$core_package"/.build/release/Modules
  do
    if [ -e "$candidate/AudoraApplication.swiftmodule" ]; then
      modules_dir=$candidate
      break
    fi
  done
fi

if [ -z "$modules_dir" ] || [ ! -e "$modules_dir/AudoraApplication.swiftmodule" ]; then
  echo 'AudoraApplication must be built before checking its client interface' >&2
  exit 1
fi

mkdir -p "$module_cache"

typecheck_client() {
  swiftc -typecheck \
    -module-cache-path "$module_cache" \
    -I "$modules_dir" \
    "$1"
}

typecheck_client \
  "$script_dir/fixtures/coach-context-public-client.swift"

for forbidden_symbol in \
  CanonicalJSONValue \
  CanonicalJSONMeasurementError \
  CanonicalJSON \
  CoachTokenEstimatorError \
  CoachTokenEstimator \
  CompleteToolResponseBudgetError \
  CompleteToolResponseBudget \
  CoachContextBudget \
  CoachProviderDescriptor \
  CoachProviderFraming \
  CoachProviderEstimationPolicy \
  PreparedCoachTranscriptHandleError \
  PreparedCoachTranscriptHandle \
  PreparedCoachAttachment \
  PreparedCoachContext \
  CanonicalCoachExchange \
  CoachContextEstimate \
  CoachContextEstimationError \
  CoachContextPlanner \
  CoachProviderDescriptorValidationError \
  QualifiedCoachProviderDescriptor \
  CoachProviderDescriptorQualifier \
  CoachContextQuoteInput \
  CoachContextConfiguration \
  CoachContextCapacity \
  MeasuredCoachLaunchContext \
  CoachContextResolvedSnapshot \
  CoachContextSnapshotAuthority \
  PreparedCoachLaunchContext \
  CoachContextPendingPreparing \
  CoachContextSnapshotPort
do
  if printf 'import AudoraApplication\nlet _ = %s.self\n' "$forbidden_symbol" \
    | swiftc -typecheck \
      -module-cache-path "$module_cache" \
      -I "$modules_dir" \
      - >/dev/null 2>&1
  then
    printf '%s is visible to a normal AudoraApplication client\n' \
      "$forbidden_symbol" >&2
    exit 1
  fi
done

typecheck_client \
  "$script_dir/fixtures/coach-context-qualification-client.swift"
