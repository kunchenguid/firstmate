#!/usr/bin/env bash
# Own firstmate's no-mistakes test command, preserving the ordinary full local
# suite while splitting only an explicitly Azure-selected test class into an
# uncredentialed heavy Linux shard plus the required local Herdr lifecycle set.
# A remote failure is never rerun locally.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DISPATCH="$ROOT/bin/fm-azure-runner-dispatch.sh"

run_full() {
  command -v tmux >/dev/null || { echo "tmux is required for e2e tests" >&2; return 1; }
  tmux -V
  local rc=0
  "$ROOT/tests/run.sh" || rc=1
  uv run --directory "$ROOT/tools/agent-fleet" --locked pytest || rc=1
  uv run --directory "$ROOT/tools/agent-fleet" --locked python -m compileall -q src || rc=1
  return "$rc"
}

# A daemon step inherits no FM_* selection variables from the operator. Ask the
# dispatch owner for the effective per-run decision instead of trying to infer
# it here. This validates every present routing-file field and explicit local
# recovery without spending a dispatch slot; only the real dispatch below may
# consume one. Any malformed or disagreeing authority exits before either the
# full-local suite or one half of the split can start.
set +e
selection_output=$("$DISPATCH" --inspect-selection test)
selection_rc=$?
set -e
[ "$selection_rc" -eq 0 ] || exit "$selection_rc"
selection_count=$(printf '%s\n' "$selection_output" | grep -c '^selection=' || true)
[ "$selection_count" -eq 1 ] \
  || { echo "azure-runner test selection inspection returned no unique decision" >&2; exit 1; }
selection=$(printf '%s\n' "$selection_output" | sed -n 's/^selection=//p')
case "$selection" in
  local)
    reason_count=$(printf '%s\n' "$selection_output" | grep -c '^reason=' || true)
    [ "$reason_count" -eq 1 ] \
      || { echo "azure-runner local test selection returned no unique reason" >&2; exit 1; }
    reason=$(printf '%s\n' "$selection_output" | sed -n 's/^reason=//p')
    [ -n "$reason" ] \
      || { echo "azure-runner local test selection returned an empty reason" >&2; exit 1; }
    printf 'azure-runner: class=test executed LOCALLY (%s)\n' "$reason" >&2
    run_full
    exit $?
    ;;
  remote) ;;
  *)
    printf 'azure-runner test selection inspection returned invalid decision: %s\n' "$selection" >&2
    exit 1
    ;;
esac
binding_count=$(printf '%s\n' "$selection_output" | grep -c '^selection_binding=' || true)
[ "$binding_count" -eq 1 ] \
  || { echo "azure-runner remote test selection returned no unique selection binding" >&2; exit 1; }
selection_binding=$(printf '%s\n' "$selection_output" | sed -n 's/^selection_binding=//p')
[[ "$selection_binding" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || { echo "azure-runner remote test selection returned an invalid selection binding" >&2; exit 1; }

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
"$DISPATCH" --require-selection-binding "$selection_binding" test -- \
  "$ROOT/bin/fm-azure-runner-command.sh" bash -c '
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
