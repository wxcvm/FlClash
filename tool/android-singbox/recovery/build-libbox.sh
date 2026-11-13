#!/usr/bin/env bash
# Build the same pinned, recovery-enabled ARM64 runtime for candidate and release APKs.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
upstream="$(cd "${1:?usage: build-libbox.sh UPSTREAM [--test]}" && pwd)"
python3 "$repo/tool/android-singbox/recovery/apply.py" "$upstream"
cd "$upstream"
gofmt -w protocol/group/urltest.go protocol/group/flclash_failure_gate*.go route/conn.go route/flclash_route_observer_test.go
if [[ "${2:-}" == --test ]]; then
  go test -race protocol/group/flclash_failure_gate.go protocol/group/flclash_failure_gate_test.go
  go test ./protocol/group
  go test ./route -run '^TestFlClashRouteObserver$'
  go run -tags 'with_quic,with_utls' ./cmd/sing-box check -c "$repo/tool/android-singbox/recovery/protocol-fixture.json"
fi
git tag -f v1.14.4
make lib_install
export PATH="$PATH:$(go env GOPATH)/bin"
go run ./cmd/internal/build_libbox -target android -platform android/arm64
unzip -t libbox.aar
