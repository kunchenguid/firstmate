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

# make_herdr_case: a project/worktree fixture like make_case, but with no
# tmux window - the herdr wrapped-input coverage below drives backend=herdr
# through a canned fake `herdr` CLI instead of a real tmux pane.
make_herdr_case() {  # <name> -> echoes case dir
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$case_dir/fakebin" "$case_dir/responses"
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

# make_herdr_fakebin: a `herdr` stub that logs every call (unit-separated, to
# $FM_HERDR_LOG) and answers `status --json` unconditionally, but otherwise
# returns the canned response read from <case_dir>/responses/<n>.out (or
# non-zero from <n>.exit), consumed IN CALL ORDER - same convention as
# tests/fm-backend-herdr.test.sh's make_herdr_fakebin, duplicated here rather
# than shared so this file's tmux-only cases stay untouched by herdr-only
# fixture code.
make_herdr_fakebin() {  # <case_dir>
  cat > "$1/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
RESP="${FM_HERDR_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
  exit 0
fi
n=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$1/fakebin/herdr"
}

run_herdr_teardown() {  # <case_dir> [args...]
  local case_dir=$1
  shift
  FM_TREEHOUSE_LOG="$case_dir/treehouse.log" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_HERDR_LOG="$case_dir/herdr.log" \
  FM_HERDR_RESPONSES="$case_dir/responses" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

# The Herdr adapter has no logical-line-join primitive (unlike tmux's
# `capture-pane -J`), so fm_backend_capture_joined falls back to its
# row-oriented plain capture for it. A long unsubmitted command that
# soft-wraps still splits across physical rows there, and a check that only
# proves the LAST physical row is a bare trailing prompt glyph would wrongly
# call that an empty composer - the same class of bug already fixed for tmux,
# left open on Herdr (Greptile P1: task fm-close-exited-panes review, PR
# #2970 - "Herdr reaches the same close logic through an unchanged
# row-oriented capture"). fm_backend_capture_joined_reliable (bin/fm-backend.sh)
# closes this by refusing to trust that fallback proof at all on Herdr: an
# `unknown` composer verdict blocks the close outright, the same as a
# genuine capture failure.
test_herdr_unknown_composer_keeps_pane() {
  local case_dir rc pane=w1:p2 target
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; return; }
  case_dir=$(make_herdr_case herdr-wrapped-glyph)
  make_herdr_fakebin "$case_dir"
  target="default:$pane"

  # Call 1: fm_backend_herdr_pane_agent_state's presence probe ("pane get").
  printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$pane" > "$case_dir/responses/1.out"
  # Call 2: the agent probe on that pane - no registered agent, so the
  # worker reads confirmed-exited (agent_state "dead"), same as a real
  # crewmate process that already quit.
  printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$pane" \
    > "$case_dir/responses/2.out"
  # Call 3: the composer's ANSI pane read. A bare trailing prompt glyph with
  # nothing else in view is exactly the shape a real idle shell PS1 draws
  # AND the shape the last physical row of a wrapped unsubmitted command
  # ending in that glyph would also show - fm-composer-lib.sh cannot tell
  # them apart from one physical row alone, which is why this must read
  # `unknown` rather than `empty` (mirrors
  # tests/fm-backend-herdr.test.sh:test_composer_state_unknown_when_no_composer_row_found).
  printf '> \n' > "$case_dir/responses/3.out"
  # Call 4: the fallback trailing-glyph-only proof's plain (row-oriented)
  # capture - only reached, and only trusted, pre-fix. It models a real
  # prompt row followed by a long unsubmitted command that soft-wrapped onto
  # a second physical row ending in a lone '>' - without the reliable-join
  # gate, inspecting just that last physical row would wrongly read as a
  # bare trailing glyph with nothing after it and "prove" the composer
  # empty, discarding the pending command on close.
  printf 'user@host:~$ echo hello world\nxxxxxxxxxxxxxxxxxxxx>\n' > "$case_dir/responses/4.out"

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=$target" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "backend=herdr" \
    "herdr_session=default" \
    "herdr_workspace_id=ws1" \
    "herdr_tab_id=t1" \
    "herdr_pane_id=$pane" \
    'pr=https://github.com/example/repo/pull/7'
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "task work"
  : > "$case_dir/treehouse.log"

  set +e
  run_herdr_teardown "$case_dir" --close-pane > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "close-pane closed a herdr pane whose composer could not be proven empty: $(cat "$case_dir/stdout")"
  grep -q 'pending composer' "$case_dir/stderr" \
    || fail "herdr unknown-composer refusal did not name pending composer text: $(cat "$case_dir/stderr")"
  grep -q 'pane_closed=1' "$case_dir/state/task-x1.meta" \
    && fail "herdr unknown-composer close-pane recorded pane_closed"
  [ ! -s "$case_dir/treehouse.log" ] \
    || fail "close-pane returned the copy for a herdr unknown-composer refusal: $(cat "$case_dir/treehouse.log")"
  pass "herdr backend, composer state unprovable: pane kept"
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
test_herdr_unknown_composer_keeps_pane
test_live_agent_keeps_pane
test_unfinished_exit_keeps_pane
test_teardown_after_close_still_returns_copy
test_recorded_windows_skips_closed_panes
