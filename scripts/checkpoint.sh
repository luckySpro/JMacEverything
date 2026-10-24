#!/usr/bin/env bash
# Save progress to GitHub so no more than one step of work can ever be lost.
#
#   scripts/checkpoint.sh "M0" "Tauri skeleton builds on macOS" "Add Windows CI job"
#
# 1. appends a row to docs/v2/PROGRESS.md
# 2. commits everything on the current branch
# 3. pushes to origin (retries 3x)
# 4. verifies the remote branch now points at the new commit
set -euo pipefail

stage="${1:?stage, e.g. M0}"; done_msg="${2:?what was completed}"; next_msg="${3:?next step}"
root="$(git rev-parse --show-toplevel)"; cd "$root"
branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$branch" == "main" ]]; then
  echo "Refusing to checkpoint on main; 2.0 work lives on v2 (or v2-*)." >&2; exit 1
fi

now="$(TZ=Asia/Taipei date '+%Y-%m-%d %H:%M')"
row="| $now | $stage | ${done_msg//|/\\|} | ${next_msg//|/\\|} |"
echo "$row" >> docs/v2/PROGRESS.md

git add -A
git commit -q -m "checkpoint($stage): $done_msg" -m "Next: $next_msg"

for attempt in 1 2 3; do
  if git push -q origin "HEAD:$branch"; then break; fi
  echo "push failed (attempt $attempt), retrying..." >&2; sleep $((attempt * 5))
  [[ $attempt == 3 ]] && { echo "PUSH FAILED — work is committed locally only." >&2; exit 2; }
done

local_sha="$(git rev-parse HEAD)"
remote_sha="$(git ls-remote origin "refs/heads/$branch" | cut -f1)"
if [[ "$local_sha" != "$remote_sha" ]]; then
  echo "Remote $branch is $remote_sha, expected $local_sha" >&2; exit 3
fi
echo "Checkpoint saved: $branch @ ${local_sha:0:7}"
