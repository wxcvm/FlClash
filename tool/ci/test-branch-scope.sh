#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/branch-scope.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q
git -c user.name=CI -c user.email=ci@example.invalid commit --allow-empty -qm base
base=$(git rev-parse HEAD)
check() {
  local expected=$1
  test "$(bash "$script" "$base" HEAD)" = "$expected"
}
commit() {
  git add -A
  git -c user.name=CI -c user.email=ci@example.invalid commit -qm change
}
check false
mkdir -p lib/common test/common
touch lib/common/request.dart test/common/request_test.dart
commit
check true
git reset -q --hard "$base"
mkdir -p lib/core/desktop
touch lib/core/desktop/process_probe.dart
commit
check false
git reset -q --hard "$base"
mkdir -p test/core/desktop
touch test/core/desktop/process_probe_test.dart
commit
check false
git reset -q --hard "$base"
mkdir -p lib/core/desktop test/core/desktop
touch lib/core/desktop/process_probe.dart test/core/desktop/process_probe_test.dart
commit
check false
git reset -q --hard "$base"
mkdir -p core
touch core/main.go
commit
check false
git reset -q --hard "$base"
mkdir -p .github/workflows
touch .github/workflows/build.yaml
commit
check false
test "$(bash "$script" nonexistent HEAD 2>/dev/null)" = false
echo 'CI branch scope tests passed'
