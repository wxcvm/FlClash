#!/usr/bin/env bash
# Only pure Dart source/test changes can use the short branch validation.
# Main, dev, tags and manual runs are always full in build.yaml.
set -euo pipefail
changes=$(mktemp)
trap 'rm -f "$changes"' EXIT
if ! git diff --no-renames --name-only -z "${1:?base}...${2:?head}" > "$changes"; then
  echo false
  exit 0
fi
found=false
while IFS= read -r -d '' path; do
  found=true
  case "$path" in
    # Desktop core ownership/liveness changes require native desktop builds.
    lib/core/desktop/process_probe.dart|test/core/desktop/process_probe_test.dart) echo false; exit 0 ;;
    lib/*.dart|test/*.dart) ;;
    *) echo false; exit 0 ;;
  esac
done < "$changes"
echo "$found"
