#!/bin/sh

set -eu

contracts_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$contracts_dir/../.." && pwd)
schemas_dir=Packages/AudoraCore/Sources/AudoraContracts/Resources/Schemas
contract_tmp_dir=$(mktemp -d)

cleanup() {
  rm -rf -- "$contract_tmp_dir"
}

trap cleanup EXIT HUP INT TERM

cd "$project_dir"

find "$schemas_dir" -maxdepth 1 -type f -name '*.json' -print \
  | LC_ALL=C sort \
  | diff -u rfc/contracts/generated-json-files.txt -

pnpm exec tsp compile rfc/contracts \
  --option "@typespec/json-schema.emitter-output-dir=$contract_tmp_dir"

find "$contract_tmp_dir" -maxdepth 1 -type f -name '*.json' -print \
  | sed "s|$contract_tmp_dir/|$schemas_dir/|" \
  | LC_ALL=C sort \
  | diff -u rfc/contracts/generated-json-files.txt -

while IFS= read -r artifact_path; do
  [ -n "$artifact_path" ] || continue
  artifact_name=${artifact_path##*/}
  diff -u "$artifact_path" "$contract_tmp_dir/$artifact_name"
done < rfc/contracts/generated-json-files.txt
