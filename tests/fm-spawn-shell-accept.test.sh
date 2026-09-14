#!/usr/bin/env bash
# Spawn-path regression for launch-scoped shell acceptance.
#
# The public fm-spawn.sh path must commit every interactive-shell command with
# the backend's launch-shell operation, not only the final worker command.
# This fake tmux records actual adapter calls so a final-key-only fix fails on
# treehouse entry or either export while generic Enter remains unchanged.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-trace-context-lib.sh
. "$ROOT/bin/fm-trace-context-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-shell-accept)
HOME_DIR="$TMP_ROOT/home"
PROJ_DIR="$TMP_ROOT/project"
WT_DIR="$TMP_ROOT/worktree"
LOG="$TMP_ROOT/tmux.log"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
ID=shell-accept-z1
US=$'\037'

make_tmux() {
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    for arg in "$@"; do printf '%s\037' "$arg" >> "${FM_FAKE_TMUX_LOG:?}"; done
    printf '\n' >> "${FM_FAKE_TMUX_LOG:?}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/tmux"
}

assert_line_with_accept() {  # <fixed shell line>
  local line=$1
  grep -Fq -- "${US}${line}${US}C-j${US}" "$LOG" \
    || fail "spawn did not send and commit '$line' atomically with native tmux C-j"
}

make_tmux
fm_fake_exit0 "$FAKEBIN" treehouse pi
fm_test_spawn_home "$HOME_DIR" pi
fm_test_spawn_brief "$HOME_DIR" "$ID" "Exercise launch-scoped shell acceptance."
fm_git_worktree "$PROJ_DIR" "$WT_DIR" shell-accept-worktree
: > "$HOME_DIR/config/trace-context"
printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
FM_TRACE_CONTEXT=on fm_trace_context_session_start \
  "$HOME_DIR/config" "$HOME_DIR/state/.trace-context-effective"
: > "$LOG"

out=$(FM_FAKE_TMUX_LOG="$LOG" FM_TRACE_CONTEXT=on \
  fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" \
    "$ID" "$PROJ_DIR" --scout --harness pi --backend tmux)
status=$?
expect_code 0 "$status" "spawn should succeed through the recording tmux adapter"
assert_contains "$out" "spawned $ID" "spawn did not report success"

assert_line_with_accept 'treehouse get'
assert_line_with_accept "export GOTMPDIR=/tmp/fm-$ID/gotmp"
assert_line_with_accept "export FM_TASK_ID=$ID"
trace_line=$(grep -F "${US}export TRACEPARENT=" "$LOG" | tail -1)
[ -n "$trace_line" ] || fail "spawn did not send the optional TRACEPARENT export"
printf '%s\n' "$trace_line" | grep -Fq "${US}C-j${US}" \
  || fail "spawn did not commit the optional TRACEPARENT export with native tmux C-j"
launch_number=$(grep -nF "${US}-l${US}" "$LOG" | tail -1 | cut -d: -f1)
grep -F 'pi' "$LOG" | tail -1 >/dev/null \
  || fail "spawn did not send the final worker launch literally"
sed -n "$((launch_number + 1))p" "$LOG" | grep -Fq "${US}C-j${US}" \
  || fail "spawn did not commit the final worker launch with native tmux C-j"
pass "fm-spawn commits treehouse, environment, trace, and worker launch shell commands with tmux C-j"

before=$(wc -l < "$LOG" | tr -d ' ')
FM_FAKE_TMUX_LOG="$LOG" PATH="$FAKEBIN:$PATH" bash -c \
  '. "$1/bin/fm-backend.sh"; fm_backend_send_key tmux smoke:generic Enter' _ "$ROOT"
after=$(wc -l < "$LOG" | tr -d ' ')
[ "$after" -eq $((before + 1)) ] || fail "generic Enter did not emit exactly one tmux key call"
tail -1 "$LOG" | grep -Fq "${US}Enter${US}" \
  || fail "generic Enter no longer reaches tmux as physical Enter"
pass "generic tmux Enter remains physical Enter outside launch-shell submission"

fallback=$(bash -c '
  . "$1/bin/fm-backend.sh"
  fm_backend_source() { return 0; }
  fm_backend_zellij_send_text_line() { printf "zellij-line:%s:%s:%s\n" "$1" "$2" "$3"; }
  fm_backend_zellij_send_key() { printf "zellij-key:%s:%s:%s\n" "$1" "$2" "$3"; }
  fm_backend_orca_send_text_line() { printf "orca-line:%s:%s\n" "$1" "$2"; }
  fm_backend_orca_send_key() { printf "orca-key:%s:%s\n" "$1" "$2"; }
  fm_backend_cmux_send_text_line() { printf "cmux-line:%s:%s:%s\n" "$1" "$2" "$3"; }
  fm_backend_cmux_send_key() { printf "cmux-key:%s:%s:%s\n" "$1" "$2" "$3"; }
  for backend in zellij orca cmux; do
    fm_backend_launch_shell_line "$backend" target "echo retained" label
    fm_backend_launch_shell_accept "$backend" target label
  done
' _ "$ROOT")
assert_contains "$fallback" 'zellij-line:target:echo retained:label' "Zellij launch shell line changed without a proved mapping"
assert_contains "$fallback" 'zellij-key:target:Enter:label' "Zellij launch shell accept guessed a non-Enter mapping"
assert_contains "$fallback" 'orca-line:target:echo retained' "Orca launch shell line changed without a proved mapping"
assert_contains "$fallback" 'orca-key:target:Enter' "Orca launch shell accept guessed a non-Enter mapping"
assert_contains "$fallback" 'cmux-line:target:echo retained:label' "cmux launch shell line changed without a proved mapping"
assert_contains "$fallback" 'cmux-key:target:Enter:label' "cmux launch shell accept guessed a non-Enter mapping"
pass "unavailable Zellij, Orca, and cmux mappings retain their existing physical-Enter behavior"

printf '# all fm-spawn-shell-accept tests passed\n'
