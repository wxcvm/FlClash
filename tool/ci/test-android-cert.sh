#!/usr/bin/env bash
set -euo pipefail
script="$(dirname "$0")/verify-android-cert.sh"
expected=$(printf '%064d' 1)
other=$(printf '%064d' 2)
check() {
  local output="$1"
  [[ "$(printf '%s\n' "$output" | bash "$script" "$expected")" == "$expected" ]]
}
reject() {
  if printf '%s\n' "$1" | bash "$script" "$expected" >/dev/null 2>&1; then
    echo "Unexpected certificate acceptance" >&2
    exit 1
  fi
}
check "Signer #1 certificate SHA-256 digest: $expected"
check "V2 Signer: certificate SHA-256 digest: $expected"
check "V3 Signer #1: certificate SHA-256 digest: $expected"
check "$(printf 'V2 Signer: certificate SHA-256 digest: %s\nV3 Signer: certificate SHA-256 digest: %s' "$expected" "$expected")"
reject "V2 Signer: certificate SHA-256 digest: $other"
reject "V2 Signer: certificate SHA-1 digest: $expected"
reject "$(printf 'Signer #1 certificate SHA-256 digest: %s\nSigner #2 certificate SHA-256 digest: %s' "$expected" "$other")"
reject ""
echo "Android certificate output parser: 8 cases passed."
