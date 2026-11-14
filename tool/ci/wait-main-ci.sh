#!/usr/bin/env bash
# Wait for the exact main push's CI, then enforce the existing release checks.
set -euo pipefail
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
sha="${GITHUB_SHA:?GITHUB_SHA required}"
run=''
for ((poll=1; poll<=60; poll++)); do
  if runs=$(gh api --method GET "repos/$repo/actions/workflows/build.yaml/runs" -f branch=main -f head_sha="$sha" -f event=push -f per_page=100); then
    latest=$(jq -c --arg sha "$sha" '[.workflow_runs[] | select(.head_sha == $sha)] | max_by(.run_number) // {}' <<< "$runs")
    id=$(jq -r '.id // empty' <<< "$latest")
    status=$(jq -r '.status // "not-found"' <<< "$latest")
    if [[ "$status" == completed ]]; then
      run=$id
      break
    fi
    echo "Waiting for exact main CI ${id:-not-yet-created} ($status), poll $poll/60."
  else
    echo '::warning::Could not query main CI; will retry.'
  fi
  if (( poll < 60 )); then sleep 30; fi
done
if [[ -z "$run" ]]; then
  echo "::error::Timed out waiting for CI on $sha. Check Actions and rerun this release attempt."
  exit 1
fi
jobs=$(gh api "repos/$repo/actions/runs/$run/jobs?filter=latest&per_page=100")
# Preserve the Windows/Android release's existing checks and macOS cancellation exception.
if ! jq -e '
  .jobs as $jobs |
  (["Dart","Plugins","Desktop linux","Desktop windows","Go core","Android unit tests","Windows helper test","Rust"] |
    all(.[]; . as $name | any($jobs[]; .name == $name and .status == "completed" and .conclusion == "success"))) and
  any($jobs[]; .name == "Desktop macos" and .status == "completed" and (.conclusion == "success" or .conclusion == "cancelled")) and
  all($jobs[]; .status == "completed" and (.conclusion == "success" or .conclusion == "skipped" or (.name == "Desktop macos" and .conclusion == "cancelled")))
' <<< "$jobs" >/dev/null; then
  jq -r '.jobs[] | "\(.name): \(.status)/\(.conclusion // "none")"' <<< "$jobs"
  echo "::error::Required main CI jobs did not all succeed: https://github.com/$repo/actions/runs/$run"
  exit 1
fi
if jq -e 'any(.jobs[]; .name == "Desktop macos" and .conclusion == "cancelled")' <<< "$jobs" >/dev/null; then
  echo '::warning::macOS build was cancelled; this Windows/Android-only preview does not ship macOS.'
fi
echo "Verified main CI run $run for $sha."
