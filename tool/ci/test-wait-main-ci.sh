#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GITHUB_REPOSITORY=example/FlClash GITHUB_SHA=exact-sha
export MOCK_COUNT="$tmp/count"
cat > "$tmp/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'/workflows/build.yaml/runs'* ]]; then
  n=0; [[ ! -f "$MOCK_COUNT" ]] || n=$(cat "$MOCK_COUNT")
  n=$((n+1)); echo "$n" > "$MOCK_COUNT"
  case "$SCENARIO:$n" in
    wait:1) echo '{"workflow_runs":[]}' ;;
    wait:2) echo '{"workflow_runs":[{"id":17,"head_sha":"exact-sha","run_number":3,"status":"in_progress"}]}' ;;
    timeout:*) echo '{"workflow_runs":[{"id":17,"head_sha":"other-sha","run_number":4,"status":"completed"}]}' ;;
    *) echo '{"workflow_runs":[{"id":17,"head_sha":"exact-sha","run_number":3,"status":"completed"}]}' ;;
  esac
else
  [[ "$*" == *'/runs/17/jobs?'* ]] || exit 2
  jq -n --arg scenario "$SCENARIO" '{jobs: (["Dart","Plugins","Desktop linux","Desktop windows","Go core","Android unit tests","Windows helper test","Rust","Desktop macos"] | map({name: ., status: "completed", conclusion: (if . == "Desktop windows" and $scenario == "failure" then "failure" elif . == "Desktop macos" and $scenario == "mac-cancel" then "cancelled" else "success" end)}))}'
fi
MOCK
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/sleep"
chmod +x "$tmp/gh" "$tmp/sleep"
export PATH="$tmp:$PATH"
run_case() {
  export SCENARIO=$1
  rm -f "$MOCK_COUNT"
  local rc=0
  bash "$root/wait-main-ci.sh" > "$tmp/output" 2>&1 || rc=$?
  if [[ "$rc" != "$2" ]]; then cat "$tmp/output"; exit 1; fi
  if [[ "$SCENARIO" == wait ]]; then
    [[ $(cat "$MOCK_COUNT") == 3 ]]
    grep -q 'Verified main CI run 17' "$tmp/output"
  fi
  if [[ "$SCENARIO" == timeout ]]; then [[ $(cat "$MOCK_COUNT") == 60 ]]; fi
  echo "PASS: $SCENARIO"
}
run_case wait 0
run_case success 0
run_case failure 1
run_case mac-cancel 0
run_case timeout 1
