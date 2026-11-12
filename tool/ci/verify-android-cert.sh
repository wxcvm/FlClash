#!/usr/bin/env bash
# apksigner versions label the same certificate "Signer #1" or "V2 Signer".
# Require every reported signing certificate digest to match our pinned key.
set -euo pipefail
expected=${1,,}
[[ "$expected" =~ ^[0-9a-f]{64}$ ]]
fingerprints=$(sed -nE 's/^(Signer #[0-9]+|V[0-9]+ Signer( #[0-9]+)?):? certificate SHA-256 digest: ([0-9a-fA-F]{64})[[:space:]]*$/\3/p' | tr '[:upper:]' '[:lower:]' | sort -u)
if [[ "$fingerprints" != "$expected" ]]; then
  printf '::error::APK signing certificate differs from the pinned identity or cannot be parsed.\n' >&2
  exit 1
fi
printf '%s\n' "$fingerprints"
