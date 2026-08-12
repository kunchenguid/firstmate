#!/usr/bin/env bash
# Own firstmate's no-mistakes test command, preserving the ordinary full local
# suite while splitting only an explicitly Azure-selected test class into an
# uncredentialed heavy Linux shard plus the required local Herdr lifecycle set.
# A remote failure is never rerun locally.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DISPATCH="$ROOT/bin/fm-azure-runner-dispatch.sh"
remote_selected=0
local_recovery=0
entry='' name=''

IFS=, read -r -a entries <<<"${FM_AZURE_RUNNER_REMOTE_CLASSES:-}"
for entry in "${entries[@]:-}"; do
  name=${entry%%=*}
  [ "$name" != test ] || remote_selected=1
done
IFS=, read -r -a entries <<<"${FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES:-}"
for entry in "${entries[@]:-}"; do
  name=${entry%%=*}
  [ "$name" != test ] || local_recovery=1
done

run_full() {
  command -v tmux >/dev/null || { echo "tmux is required for e2e tests" >&2; return 1; }
  tmux -V
  local rc=0
  "$ROOT/tests/run.sh" || rc=1
  uv run --directory "$ROOT/tools/agent-fleet" --locked pytest || rc=1
  uv run --directory "$ROOT/tools/agent-fleet" --locked python -m compileall -q src || rc=1
  return "$rc"
}

if [ "$remote_selected" -ne 1 ] || [ "$local_recovery" -eq 1 ]; then
  run_full
  exit $?
fi

herdr_tests=()
while IFS=$'\t' read -r script capability; do
  case "$capability" in
    herdr-lab|herdr-mixed) herdr_tests+=("$ROOT/tests/$script") ;;
  esac
done < <(grep -v '^#' "$ROOT/tests/test-capabilities.tsv")
[ "${#herdr_tests[@]}" -gt 0 ] || { echo "Herdr test inventory is unexpectedly empty" >&2; exit 1; }

# The Azure shard excludes real Herdr by explicit sealed-suite admission while
# the local shard runs every Herdr declaration through its owned guarded lab.
# They run concurrently and report independently into this one command step.
# shellcheck disable=SC2016 # The command expands its variables inside the Azure guest shell.
"$DISPATCH" test -- "$ROOT/bin/fm-azure-runner-command.sh" bash -c '
  command -v tmux >/dev/null || { echo "tmux is required for e2e tests" >&2; exit 1; }
  tmux -V
  rc=0
  tests/run.sh --skip-herdr || rc=1
  uv run --directory tools/agent-fleet --locked pytest || rc=1
  uv run --directory tools/agent-fleet --locked python -m compileall -q src || rc=1
  exit "$rc"
' &
remote_pid=$!
local_rc=0
"$ROOT/tests/run.sh" "${herdr_tests[@]}" || local_rc=1
remote_rc=0
wait "$remote_pid" || remote_rc=$?
if [ "$remote_rc" -ne 0 ] || [ "$local_rc" -ne 0 ]; then
  printf 'no-mistakes test shards failed: azure=%s local-herdr=%s\n' "$remote_rc" "$local_rc" >&2
  exit 1
fi
