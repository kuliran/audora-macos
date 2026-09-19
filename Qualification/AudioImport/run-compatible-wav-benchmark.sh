#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
benchmark_tmp_dir=$(mktemp -d)
seconds=600
iterations=5

while [ "$#" -gt 0 ]; do
  case "$1" in
    --seconds)
      seconds=$2
      shift 2
      ;;
    --iterations)
      iterations=$2
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

cleanup() {
  rm -rf -- "$benchmark_tmp_dir"
}

trap cleanup EXIT HUP INT TERM

sw_vers
uname -m
swift --version

cd "$project_dir"
AUDORA_RUN_COMPATIBLE_WAV_BENCHMARK=1 \
AUDORA_BENCHMARK_SECONDS="$seconds" \
AUDORA_BENCHMARK_ITERATIONS="$iterations" \
SWIFTPM_MODULECACHE_OVERRIDE="$benchmark_tmp_dir/module-cache" \
CLANG_MODULE_CACHE_PATH="$benchmark_tmp_dir/clang-cache" \
swift test --package-path Packages/AudoraMac \
  --scratch-path "$benchmark_tmp_dir/build" \
  --filter CompatibleWAVImportBenchmarkTests.testProductionPersistenceTransaction
