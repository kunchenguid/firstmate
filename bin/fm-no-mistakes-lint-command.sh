#!/usr/bin/env bash
# fm-no-mistakes-lint-command.sh - run CI-equivalent pre-push lint scope.
#
# Match required CI's full or focused ShellCheck scope, then always preserve
# the locked Agent Fleet Python lint.
# Unknown repository identity or scope fails closed to the complete shell
# inventory.
#
# Usage: fm-no-mistakes-lint-command.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

run_full() {
  bin/fm-lint.sh
  exec uv run --directory tools/agent-fleet --locked ruff check .
}

head=$(git rev-parse HEAD 2>/dev/null) || run_full
remote_head=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
if [ -z "$remote_head" ] && git rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1; then
  remote_head=refs/remotes/origin/main
fi
if [ -z "$remote_head" ]; then
  run_full
fi
base=$(git merge-base "$head" "$remote_head" 2>/dev/null) || run_full
mode=$(python3 bin/fm-azure-service-test-scope.py mode "$base" "$head" 2>/dev/null) || run_full
if [ "$mode" != focused ]; then
  run_full
fi

files=()
while IFS= read -r path; do
  [ -n "$path" ] && files+=("$path")
done < <(python3 bin/fm-azure-service-test-scope.py shell "$base" "$head")
if [ "${#files[@]}" -gt 0 ]; then
  bin/fm-lint.sh "${files[@]}"
else
  printf 'fm-no-mistakes-lint-command: no changed shell files in focused Azure service diff\n' >&2
fi
exec uv run --directory tools/agent-fleet --locked ruff check .
