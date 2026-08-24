#!/usr/bin/env bash
# Behavioral coverage for fm-teardown.sh --close-pane: a confirmed-exited
# ship or scout pane closes while the isolated copy stays, a live agent is
# left alone, and landed teardown still returns the copy.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-close-pane)
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-close-pane-$$"
SESSION=closepane

cleanup_tmux() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
}
trap cleanup_tmux EXIT

mkdir -p "$TMP_ROOT/shim"
cat > "$TMP_ROOT/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$TMP_ROOT/shim/tmux"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n seed -c "$TMP_ROOT" \
  || fail "could not start the private tmux server"

WNAME=fm-task-x1

kill_task_window() {
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "=$SESSION:=$WNAME" 2>/dev/null || true
}

open_shell_window() {  # <cwd>
  kill_task_window
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$WNAME" -c "$1" \
    || fail "could not create shell window $WNAME"
}

open_agent_window() {  # <cwd> <cmd>
  local cwd=$1 cmd=$2
  kill_task_window
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$WNAME" -c "$cwd" \
    "exec $(printf '%q' "$cmd")" \
    || fail "could not create agent window $WNAME"
}

window_exists() {
  "$REAL_TMUX" -L "$SOCKET" list-windows -t "$SESSION" -F '#{window_name}' | grep -Fqx "$WNAME"
}

wait_for_state() {  # <target> <expected> [tries]
  local target=$1 expected=$2 tries=${3:-100} got i=0
  while [ "$i" -lt "$tries" ]; do
    got=$(PATH="$TMP_ROOT/shim:$PATH" bash -c '
      . "$1"
      fm_backend_agent_state tmux "$2"
    ' _ "$ROOT/bin/fm-backend.sh" "$target")
    [ "$got" = "$expected" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  fail "agent state for $target never became $expected (last $got)"
}

make_case() {  # <name>
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:?}"
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '0.2.4\n'; exit 0; }
exit 0
SH
  chmod +x "$fakebin"/*
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b "fm/$name" "$case_dir/wt" main
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_ship_meta() {  # <case_dir> [extra=]
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=$SESSION:$WNAME" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "$@"
}

run_teardown() {  # <case_dir> [args...]
  local case_dir=$1
  shift
  FM_TREEHOUSE_LOG="$case_dir/treehouse.log" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$TMP_ROOT/shim:$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

test_exited_pr_open_closes_pane_keeps_copy() {
  local case_dir rc
  case_dir=$(make_case exited-pr-open)
  open_shell_window "$case_dir/wt"
  wait_for_state "$SESSION:$WNAME" dead
  write_ship_meta "$case_dir" \
    'pr=https://github.com/example/repo/pull/7'
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "task work"
  : > "$case_dir/treehouse.log"

  set +e
  run_teardown "$case_dir" --close-pane > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "close-pane refused an exited PR-open worker: $(cat "$case_dir/stderr")"
  window_exists && fail "exited pane was still open after --close-pane"
  [ -d "$case_dir/wt" ] || fail "close-pane discarded the isolated copy"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "close-pane removed task records"
  grep -qx 'pane_closed=1' "$case_dir/state/task-x1.meta" \
    || fail "close-pane did not record pane_closed=1"
  [ ! -s "$case_dir/treehouse.log" ] \
    || fail "close-pane returned the copy: $(cat "$case_dir/treehouse.log")"
  pass "exited worker with PR still open: pane closed, copy retained"
}

test_live_agent_keeps_pane() {
  local case_dir rc
  case_dir=$(make_case live-agent)
  cat > "$case_dir/claude" <<'SH'
#!/bin/bash
read -r _
SH
  chmod +x "$case_dir/claude"
  open_agent_window "$case_dir/wt" "$case_dir/claude"
  wait_for_state "$SESSION:$WNAME" alive
  write_ship_meta "$case_dir" \
    'pr=https://github.com/example/repo/pull/7'
  : > "$case_dir/treehouse.log"

  set +e
  run_teardown "$case_dir" --close-pane > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "close-pane closed a live agent"
  grep -q 'live agent' "$case_dir/stderr" \
    || fail "live-agent refusal did not name the live agent: $(cat "$case_dir/stderr")"
  window_exists || fail "live agent pane was closed"
  [ -d "$case_dir/wt" ] || fail "live-agent close-pane discarded the copy"
  grep -q 'pane_closed=1' "$case_dir/state/task-x1.meta" \
    && fail "live-agent close-pane recorded pane_closed"
  kill_task_window
  pass "live agent: pane kept"
}

test_unsubmitted_typed_text_keeps_pane() {
  local case_dir rc
  case_dir=$(make_case unsubmitted-text)
  open_shell_window "$case_dir/wt"
  wait_for_state "$SESSION:$WNAME" dead
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:$WNAME" -l 'rm -rf /tmp/not-yet-submitted'
  write_ship_meta "$case_dir" \
    'pr=https://github.com/example/repo/pull/7'
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "task work"
  : > "$case_dir/treehouse.log"

  set +e
  run_teardown "$case_dir" --close-pane > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "close-pane closed a pane with unsubmitted typed text: $(cat "$case_dir/stdout")"
  grep -q 'pending composer' "$case_dir/stderr" \
    || fail "unsubmitted-text refusal did not name pending composer text: $(cat "$case_dir/stderr")"
  window_exists || fail "pane with unsubmitted typed text was closed"
  [ ! -s "$case_dir/treehouse.log" ] \
    || fail "close-pane returned the copy for an unsubmitted-text refusal: $(cat "$case_dir/treehouse.log")"
  kill_task_window
  pass "unsubmitted typed text in the shell: pane kept"
}

test_wrapped_unsubmitted_glyph_keeps_pane() {
  local case_dir rc target cursor_x width remaining pad_len text
  case_dir=$(make_case wrapped-glyph)
  open_shell_window "$case_dir/wt"
  wait_for_state "$SESSION:$WNAME" dead
  target="$SESSION:$WNAME"

  # Build one long unsubmitted token that soft-wraps across several
  # terminal rows and ends in a single trailing shell-glyph character
  # ('>'), landing that glyph on the LAST physical row together with 9
  # other non-glyph characters - so that row alone reads as an
  # ordinary "text then one trailing glyph" line, same as a real idle
  # prompt, while the real prompt's own glyph lives on an earlier
  # physical row invisible to a last-row-only check (task
  # fm-close-exited-panes review, Greptile P1: bin/fm-composer-lib.sh:503).
  cursor_x=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$target" '#{cursor_x}')
  width=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$target" '#{pane_width}')
  remaining=$((width - cursor_x))
  pad_len=$((remaining + width * 2 + 10))
  text=$(printf 'x%.0s' $(seq 1 $((pad_len - 1))))
  text="${text}>"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" -l "$text"

  write_ship_meta "$case_dir" \
    'pr=https://github.com/example/repo/pull/7'
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "task work"
  : > "$case_dir/treehouse.log"

  set +e
  run_teardown "$case_dir" --close-pane > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "close-pane closed a pane with wrapped unsubmitted text: $(cat "$case_dir/stdout")"
  grep -q 'pending composer' "$case_dir/stderr" \
    || fail "wrapped-text refusal did not name pending composer text: $(cat "$case_dir/stderr")"
  window_exists || fail "pane with wrapped unsubmitted text was closed"
  [ ! -s "$case_dir/treehouse.log" ] \
    || fail "close-pane returned the copy for a wrapped-text refusal: $(cat "$case_dir/treehouse.log")"
  kill_task_window
  pass "wrapped unsubmitted text ending in a shell glyph: pane kept"
}

test_unfinished_exit_keeps_pane() {
  local case_dir rc
  case_dir=$(make_case unfinished)
  open_shell_window "$case_dir/wt"
  wait_for_state "$SESSION:$WNAME" dead
  write_ship_meta "$case_dir"

  set +e
  run_teardown "$case_dir" --close-pane > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "close-pane closed an unfinished exit husk"
  window_exists || fail "unfinished exit pane was closed"
  kill_task_window
  pass "unfinished exit: pane kept for recovery"
}

test_teardown_after_close_still_returns_copy() {
  local case_dir rc
  case_dir=$(make_case teardown-after-close)
  open_shell_window "$case_dir/wt"
  wait_for_state "$SESSION:$WNAME" dead
  write_ship_meta "$case_dir" \
    'pr=https://github.com/example/repo/pull/7'
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "landed work"
  git -C "$case_dir/wt" push -q origin "fm/teardown-after-close"
  git -C "$case_dir/wt" fetch -q origin
  : > "$case_dir/treehouse.log"

  run_teardown "$case_dir" --close-pane > "$case_dir/close.out" 2> "$case_dir/close.err" \
    || fail "close-pane failed before landed teardown: $(cat "$case_dir/close.err")"
  [ ! -s "$case_dir/treehouse.log" ] \
    || fail "close-pane returned the copy early: $(cat "$case_dir/treehouse.log")"
  [ -d "$case_dir/wt" ] || fail "close-pane discarded the copy before landed teardown"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "landed teardown after close-pane failed: $(cat "$case_dir/stderr")"
  grep -q 'return' "$case_dir/treehouse.log" \
    || fail "landed teardown did not return the copy: $(cat "$case_dir/treehouse.log")"
  [ ! -f "$case_dir/state/task-x1.meta" ] \
    || fail "landed teardown left task records"
  pass "teardown after merge still returns the copy"
}

test_recorded_windows_skips_closed_panes() {
  local home w
  home="$TMP_ROOT/watch-skip"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/open.meta" "window=$SESSION:open-win" "kind=ship"
  fm_write_meta "$home/state/closed.meta" \
    "window=$SESSION:closed-win" "kind=ship" "pane_closed=1"
  w=$(STATE="$home/state" FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" \
    bash -c '
      SCRIPT_DIR="$1"
      STATE="$2"
      # shellcheck source=/dev/null
      . "$SCRIPT_DIR/fm-watch.sh"
      recorded_windows
    ' _ "$ROOT/bin" "$home/state")
  case "$w" in
    *"$SESSION:open-win"*) ;;
    *) fail "recorded_windows dropped the open pane: $w" ;;
  esac
  case "$w" in
    *"$SESSION:closed-win"*) fail "recorded_windows still listed a closed pane: $w" ;;
  esac
  pass "watcher inventory skips pane_closed endpoints"
}

test_exited_pr_open_closes_pane_keeps_copy
test_unsubmitted_typed_text_keeps_pane
test_wrapped_unsubmitted_glyph_keeps_pane
test_live_agent_keeps_pane
test_unfinished_exit_keeps_pane
test_teardown_after_close_still_returns_copy
test_recorded_windows_skips_closed_panes
