#!/usr/bin/env bash
# Behavior tests for bin/fm-dash.sh - the read-only live fleet dashboard.
#
# Hermetic over a throwaway FM_STATE_OVERRIDE with a fake `tmux` (pane source)
# and fake `no-mistakes` (run-step source) on PATH, mirroring
# tests/fm-crew-state.test.sh:
#   (a) empty fleet --once prints the friendly message, not a table
#   (b) a ship task row renders id, project, kind, state, and pr= URL
#   (c) kind=secondmate renders home= instead of worktree=
#   (d) OSC 8 hyperlink: FM_DASH_HYPERLINK=1 emits <scheme>://file/<path> with
#       percent-encoded spaces; FM_DASH_EDITOR_SCHEME overrides vscode; and
#       FM_DASH_HYPERLINK=0 (the non-tty default) prints the plain path
#   (e) a pane printing "Usage ...% | Weekly ...%" surfaces as the row's gauge
#   (f) resilience: a hanging per-row helper degrades to a placeholder within
#       FM_DASH_STATE_TIMEOUT instead of wedging the render
#   (g) live mode: `q` quits cleanly with exit 0 after rendering, and a closed
#       stdin (EOF) also exits instead of spinning
#   (h) live mode: pressing a row's number opens that worktree via
#       FM_DASH_OPEN_CMD
#   (i) an invalid FM_DASH_INTERVAL is refused with exit 2
#   (j) read-only: a render creates no files under state/
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-dash.sh"
TMP_ROOT=$(fm_test_tmproot fm-dash)
fm_git_identity fmtest fmtest@example.invalid

# Fake tmux: display-message answers pane liveness, capture-pane serves the
# pane text (busy footer plus an optional FM_FAKE_GAUGE_LINE). Fake
# no-mistakes serves FM_FAKE_AXI_STATUS, sleeping FM_FAKE_NM_SLEEP first so
# the hang case (f) can simulate a wedged helper.
make_fakebin() {  # <dir> -> echoes fakebin path
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    printf '%%1\n' ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    if [ "${FM_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
    else printf 'all quiet\n> \n'; fi
    [ -n "${FM_FAKE_GAUGE_LINE:-}" ] && printf '%s\n' "$FM_FAKE_GAUGE_LINE" ;;
esac
exit 0
SH
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_NM_SLEEP:-}" ] && sleep "$FM_FAKE_NM_SLEEP"
case "${1:-}" in
  axi) printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  cat > "$fb/record-open" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_FAKE_OPEN_LOG"
SH
  chmod +x "$fb/tmux" "$fb/no-mistakes" "$fb/record-open"
  printf '%s\n' "$fb"
}

FAKEBIN=$(make_fakebin "$TMP_ROOT")
export PATH="$FAKEBIN:$PATH"

new_state() {  # <name> -> echoes a fresh state dir
  local d="$TMP_ROOT/$1/state"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

# --- (a) empty fleet ---------------------------------------------------------

STATE_A=$(new_state a)
out=$(FM_STATE_OVERRIDE="$STATE_A" "$DASH" --once)
expect_code 0 $? 'empty fleet --once exits 0'
assert_contains "$out" 'No tasks in flight' 'empty fleet prints the friendly message'
assert_contains "$out" '0 in flight' 'empty fleet header still shows the count'
pass '(a) empty fleet --once prints the friendly message'

# --- (b) ship task row: id, project, kind, state, pr -------------------------

STATE_B=$(new_state b)
fm_write_meta "$STATE_B/fix-login-k3.meta" \
  'window=firstmate:fm-fix-login-k3' \
  "worktree=$TMP_ROOT/b/gone-worktree" \
  'project=projects/yourapp' \
  'harness=claude' \
  'kind=ship' \
  'mode=no-mistakes' \
  'yolo=off' \
  'pr=https://github.com/o/r/pull/123'
out=$(FM_STATE_OVERRIDE="$STATE_B" "$DASH" --once)
expect_code 0 $? 'ship row --once exits 0'
assert_contains "$out" '1 in flight' 'header counts the ship task'
assert_contains "$out" 'fix-login-k3' 'row shows the task id'
assert_contains "$out" 'yourapp' 'row shows the project basename'
assert_contains "$out" 'ship' 'row shows the kind'
assert_contains "$out" 'worktree gone' 'row shows the fm-crew-state current-state line'
assert_contains "$out" 'https://github.com/o/r/pull/123' 'row shows the recorded PR URL'
pass '(b) ship task row renders id, project, kind, state, and pr'

# --- (c) secondmate row shows home= ------------------------------------------

STATE_C=$(new_state c)
mkdir -p "$TMP_ROOT/c/sm-home"
fm_write_secondmate_meta "$STATE_C/domain-sm.meta" "$TMP_ROOT/c/sm-home"
out=$(FM_STATE_OVERRIDE="$STATE_C" FM_DASH_HYPERLINK=0 "$DASH" --once)
assert_contains "$out" 'secondmate' 'row shows kind=secondmate'
assert_contains "$out" "$TMP_ROOT/c/sm-home" 'secondmate row shows the home= path'
pass '(c) secondmate row shows home='

# --- (d) hyperlink scheme, encoding, and plain fallback ----------------------

STATE_D=$(new_state d)
mkdir -p "$TMP_ROOT/d/wt with space"
fm_write_meta "$STATE_D/enc-x1.meta" \
  'window=firstmate:fm-enc-x1' \
  "worktree=$TMP_ROOT/d/wt with space" \
  'project=projects/alpha' \
  'kind=scout'
out=$(FM_STATE_OVERRIDE="$STATE_D" FM_DASH_HYPERLINK=1 "$DASH" --once)
assert_contains "$out" "vscode://file/$TMP_ROOT/d/wt%20with%20space" \
  'hyperlink uses the vscode scheme with percent-encoded spaces'
out=$(FM_STATE_OVERRIDE="$STATE_D" FM_DASH_HYPERLINK=1 FM_DASH_EDITOR_SCHEME=cursor "$DASH" --once)
assert_contains "$out" "cursor://file/$TMP_ROOT/d/wt%20with%20space" \
  'FM_DASH_EDITOR_SCHEME overrides the hyperlink scheme'
out=$(FM_STATE_OVERRIDE="$STATE_D" FM_DASH_HYPERLINK=0 "$DASH" --once)
assert_not_contains "$out" 'vscode://file/' 'FM_DASH_HYPERLINK=0 emits no OSC 8 URL'
assert_contains "$out" "$TMP_ROOT/d/wt with space" 'plain mode still prints the worktree path'
pass '(d) hyperlink scheme, encoding, and plain fallback'

# --- (e) pane gauge line ------------------------------------------------------

out=$(FM_STATE_OVERRIDE="$STATE_D" FM_DASH_HYPERLINK=0 \
  FM_FAKE_GAUGE_LINE='ctx 12% · Usage 42% | Weekly 12% · main' "$DASH" --once)
assert_contains "$out" 'Usage 42% | Weekly 12%' 'row surfaces the pane gauge line'
pass '(e) pane gauge line surfaces on the row'

# --- (f) hanging helper degrades to a placeholder ----------------------------

STATE_F=$(new_state f)
mkdir -p "$TMP_ROOT/f/wt"
git -C "$TMP_ROOT/f/wt" init -q
git -C "$TMP_ROOT/f/wt" -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$TMP_ROOT/f/wt" checkout -q -b fm/hang-x1
fm_write_meta "$STATE_F/hang-x1.meta" \
  'window=firstmate:fm-hang-x1' \
  "worktree=$TMP_ROOT/f/wt" \
  'project=projects/alpha' \
  'kind=ship'
start=$(date +%s)
out=$(FM_STATE_OVERRIDE="$STATE_F" FM_DASH_HYPERLINK=0 FM_DASH_STATE_TIMEOUT=1 \
  FM_CREW_STATE_NM_TIMEOUT=30 FM_FAKE_NM_SLEEP=30 "$DASH" --once)
elapsed=$(( $(date +%s) - start ))
expect_code 0 $? 'hanging helper still exits 0'
assert_contains "$out" 'hang-x1' 'hanging row still renders its id'
assert_contains "$out" 'state read slow or failed' 'hanging row degrades to the placeholder'
[ "$elapsed" -lt 15 ] || fail "render wedged: took ${elapsed}s with a 1s per-row budget"
pass '(f) hanging helper degrades to a placeholder without wedging'

# --- (g) live mode: q quits cleanly, EOF exits -------------------------------

STATE_G=$(new_state g)
out=$(printf 'q' | FM_STATE_OVERRIDE="$STATE_G" FM_DASH_FORCE_TTY=1 FM_DASH_INTERVAL=1 "$DASH")
expect_code 0 $? 'live mode exits 0 on q'
assert_contains "$out" 'No tasks in flight' 'live mode rendered a frame before quitting'
out=$(printf '' | FM_STATE_OVERRIDE="$STATE_G" FM_DASH_FORCE_TTY=1 FM_DASH_INTERVAL=1 "$DASH")
expect_code 0 $? 'live mode exits 0 on stdin EOF instead of spinning'
pass '(g) live mode q quits cleanly and EOF exits'

# --- (h) number keypress opens the row worktree ------------------------------

export FM_FAKE_OPEN_LOG="$TMP_ROOT/opened.log"
printf '1' | FM_STATE_OVERRIDE="$STATE_D" FM_DASH_FORCE_TTY=1 FM_DASH_INTERVAL=1 \
  FM_DASH_OPEN_CMD='record-open' "$DASH" > /dev/null
expect_code 0 $? 'live mode exits 0 after a number keypress'
tries=0
until [ -s "$FM_FAKE_OPEN_LOG" ] || [ "$tries" -ge 20 ]; do sleep 0.1; tries=$((tries + 1)); done
assert_present "$FM_FAKE_OPEN_LOG" 'number keypress ran FM_DASH_OPEN_CMD'
assert_grep "$TMP_ROOT/d/wt with space" "$FM_FAKE_OPEN_LOG" \
  'FM_DASH_OPEN_CMD received the row worktree path'
pass '(h) number keypress opens the row worktree via FM_DASH_OPEN_CMD'

# --- (i) invalid FM_DASH_INTERVAL refused ------------------------------------

FM_STATE_OVERRIDE="$STATE_G" FM_DASH_INTERVAL=soon "$DASH" --once >/dev/null 2>&1
expect_code 2 $? 'invalid FM_DASH_INTERVAL exits 2'
pass '(i) invalid FM_DASH_INTERVAL refused'

# --- (j) read-only: no files created under state/ ----------------------------

before=$(find "$STATE_B" -type f | sort)
FM_STATE_OVERRIDE="$STATE_B" FM_DASH_HYPERLINK=0 "$DASH" --once > /dev/null
after=$(find "$STATE_B" -type f | sort)
[ "$before" = "$after" ] || fail "dashboard wrote under state/: before=[$before] after=[$after]"
pass '(j) render creates no files under state/'

echo 'fm-dash tests passed'
