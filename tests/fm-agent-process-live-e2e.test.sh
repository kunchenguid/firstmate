#!/usr/bin/env bash
# Real process identities through Herdr, including kernel-name/argv divergence.
# No credentials or model calls. The guarded lab owns every terminal operation.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"
fm_live_gate default-on FM_AGENT_PROCESS_LIVE herdr jq
herdr_forget_inherited_pane
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
CLEAN_PATH=$PATH
SESSION=$("$HELPER" name "${FM_HERDR_LAB_TASK:-agent-process}") || exit 1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agent-process.XXXXXX")
cleanup() {
  PATH="$CLEAN_PATH" "$HELPER" teardown "$SESSION" || exit 1
  rm -rf "$LAB"
}
trap cleanup EXIT
"$HELPER" provision "$SESSION" || fail 'lab provision failed'
herdr_test_guard_cli "$SESSION" "$LAB/shim" "$HELPER" || fail 'guard failed'
export PATH="$LAB/shim:$PATH" HERDR_SESSION="$SESSION"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail 'Herdr source failed'
mkdir -p "$LAB/bin/codex" "$LAB/bin/decoy" "$LAB/wt"
container_raw=$(fm_backend_herdr_container_ensure "$LAB/wt") || fail 'container failed'
container=${container_raw%%$'\t'*}
for name in pi codex-test traex traecli extraex notaharness; do
  ln -s "$(command -v sleep)" "$LAB/bin/$name"
done
new_process() {
  local name=$1 ids cmd
  shift
  ids=$(fm_backend_herdr_create_task "$container" "fm-$name" "$LAB/wt") || fail 'pane creation failed'
  read -r _ PANE <<< "$ids"
  printf -v cmd '%q ' "$@"
  fm_backend_herdr_send_text_line "$SESSION:$PANE" "exec $cmd" || fail 'launch failed'
}
expect_process() {
  local expected=$1 actual='' i
  for i in $(seq 1 80); do
    actual=$(fm_backend_herdr_pane_process_state_sample "$SESSION" "$PANE")
    [ "$actual" = "$expected" ] && return 0
    sleep 0.1
  done
  fail "process verdict $actual, expected $expected for $PANE"
}
for name in pi codex-test traex traecli; do
  new_process "$name" "$LAB/bin/$name" 900
  expect_process agent
  pass "Herdr attributes real $name executable"
done
new_process extraex "$LAB/bin/extraex" 900
expect_process other
pass 'substring decoy remains unclassified'
cc_bin=$(command -v cc || command -v gcc || true)
[ -n "$cc_bin" ] || fail 'C compiler required for the non-vacuous version-name regression'
printf '%s\n' '#include <unistd.h>' 'int main(void){for(;;)sleep(60);return 0;}' > "$LAB/spin.c"
"$cc_bin" -o "$LAB/bin/codex/2.1.220" "$LAB/spin.c" || fail 'compile harness-path probe failed'
"$cc_bin" -o "$LAB/bin/decoy/2.1.220" "$LAB/spin.c" || fail 'compile decoy probe failed'
new_process version "$LAB/bin/codex/2.1.220"
expect_process agent
info=$("$HELPER" run "$SESSION" pane process-info --pane "$PANE")
name=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_processes[0].name')
argv0=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_processes[0] | (.argv[0] // .argv0 // "")')
[ "$(fm_agent_process_classify_name "$name")" = other ] || fail 'version name did not blind kernel-name evidence'
[ "$(fm_agent_process_classify_name "$argv0")" = agent ] || fail 'argv path did not carry surviving identity'
pass 'version-only process name and executable path genuinely disagree; surviving identity wins'
new_process decoy "$LAB/bin/decoy/2.1.220"
expect_process other
new_process unknown bash -c "exec -a 2.1.220 '$LAB/bin/notaharness' 900"
expect_process other
pass 'unattributed real processes remain other'
new_process launcher bash -c "'$LAB/bin/pi' 900 & wait"
expect_process agent
pass 'shell launcher retains its live harness child'
new_process idle /bin/sh
expect_process shell
pass 'idle shell is positively agent-free'
# Herdr intentionally preserves a harness descendant outside the foreground
# group: an idle-looking shell must not authorize duplicate launch or teardown.
new_process background bash -c "set -m; '$LAB/bin/codex-test' 900 & printf '%s\n' \"\$!\" > '$LAB/background.pid'; exec /bin/sh"
expect_process agent
bg_pid=$(cat "$LAB/background.pid")
kill -0 "$bg_pid" || fail 'background identity probe went vacuous'
pass 'background harness descendant prevents false agent-free classification'
[ "$(fm_backend_agent_state herdr "$SESSION:w999999:p999999")" = missing ] || fail 'missing exact pane borrowed another identity'
pass 'missing pane remains missing rather than inheriting another pane identity'
