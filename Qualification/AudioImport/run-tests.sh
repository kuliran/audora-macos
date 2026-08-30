#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
qualification_tmp_dir=$(mktemp -d)

cleanup() {
  rm -rf -- "$qualification_tmp_dir"
}

trap cleanup EXIT HUP INT TERM

cd "$project_dir"

SWIFTPM_MODULECACHE_OVERRIDE="$qualification_tmp_dir/module-cache" \
  CLANG_MODULE_CACHE_PATH="$qualification_tmp_dir/clang-cache" \
  swift test --package-path Packages/AudoraCore --parallel

SWIFTPM_MODULECACHE_OVERRIDE="$qualification_tmp_dir/module-cache" \
  CLANG_MODULE_CACHE_PATH="$qualification_tmp_dir/clang-cache" \
  swift test --package-path Packages/AudoraMac --parallel
