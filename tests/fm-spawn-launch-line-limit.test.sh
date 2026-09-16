#!/usr/bin/env bash
# tests/fm-spawn-launch-line-limit.test.sh - the launch command must survive the
# terminal's canonical-mode line cap (bin/fm-spawn.sh, spawn_send_launch).
#
# A pane shell reads its command line in canonical mode, where the line
# discipline caps one line at MAX_CANON and DISCARDS the excess silently: 1024
# bytes on macOS, 4096 on Linux. A launch command past that cap reached the
# shell truncated mid-quote, leaving it on a continuation prompt with no agent
# ever started, and nothing in the spawn path noticed. Command length scales
# with the home's own path, so an ordinary home crosses the cap while a shorter
# one never does, which is why this went unseen.
#
# Three cases, because they fail for different reasons:
#   1. over the bound  - the pane receives a short line and the full command is
#      staged on disk intact
#   2. under the bound - the pane still receives the command literally, so no
#      launch that already worked changes shape
#   3. real tmux       - the divergence itself: a literal over-cap line really
#      is truncated by a real shell, and the staged shape really does execute
#      whole. Without this case the first two could agree on a fix for a
#      problem that does not exist.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-launch-line-limit)

ID1="launchcap-over-$$"
ID2="launchcap-under-$$"

# --- shared project ----------------------------------------------------------

PROJ="$TMP_ROOT/proj"
mkdir -p "$PROJ"
git init -q "$PROJ"
git -C "$PROJ" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# --- case 1: a command over the bound is staged, not typed -------------------

HOME_DIR="$TMP_ROOT/home1"
fm_test_spawn_home "$HOME_DIR"
fm_test_spawn_brief "$HOME_DIR" "$ID1"
WT="$TMP_ROOT/wt1"
git -C "$PROJ" worktree add -q "$WT" -b task1
FAKEBIN=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fb1")

# A raw launch command (the unverified-adapter escape hatch) sized well past
# every known MAX_CANON, so the assertion does not depend on the platform.
PAYLOAD=$(printf 'x%.0s' $(seq 1 4096))
RAW_LONG="/bin/echo $PAYLOAD"
STAGED="/tmp/fm-$ID1/launch.sh"

# The RAW log is what was typed at the pane, with no staging dereferenced -
# exactly the question this case asks.
LAUNCH_LOG="$TMP_ROOT/launch1.raw.log"
: > "$LAUNCH_LOG"
FM_FAKE_LAUNCH_RAW_LOG="$LAUNCH_LOG" \
  fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$ID1" "$PROJ" --scout "$RAW_LONG" \
  > "$TMP_ROOT/spawn1.out" 2>&1 || fail "case 1: spawn failed: $(cat "$TMP_ROOT/spawn1.out")"

[ -s "$LAUNCH_LOG" ] || fail "case 1: nothing was sent to the pane"

# Every line typed at the pane must fit under the smallest known cap.
while IFS= read -r line; do
  [ "${#line}" -le 1000 ] \
    || fail "case 1: a ${#line}-byte line was typed at the pane; it would be truncated at MAX_CANON"
done < "$LAUNCH_LOG"

[ -f "$STAGED" ] || fail "case 1: the long command was not staged at $STAGED"
grep -q "$PAYLOAD" "$STAGED" \
  || fail "case 1: the staged command does not carry the full payload"
grep -q 'launch\.sh' "$LAUNCH_LOG" \
  || fail "case 1: the pane was not pointed at the staged command"
rm -f "$STAGED"
rmdir "/tmp/fm-$ID1/gotmp" "/tmp/fm-$ID1" 2>/dev/null || true
pass "a launch command over the bound is staged and the pane receives a short line"

# --- case 2: a command under the bound is unchanged --------------------------

HOME2="$TMP_ROOT/home2"
fm_test_spawn_home "$HOME2"
fm_test_spawn_brief "$HOME2" "$ID2"
WT2="$TMP_ROOT/wt2"
git -C "$PROJ" worktree add -q "$WT2" -b task2
FAKEBIN2=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fb2")

RAW_SHORT="/bin/echo hello-from-a-short-launch"
LOG2="$TMP_ROOT/launch2.raw.log"
: > "$LOG2"
FM_FAKE_LAUNCH_RAW_LOG="$LOG2" \
  fm_test_run_spawn "$HOME2" "$WT2" "$FAKEBIN2" "$ID2" "$PROJ" --scout "$RAW_SHORT" \
  > "$TMP_ROOT/spawn2.out" 2>&1 || fail "case 2: spawn failed: $(cat "$TMP_ROOT/spawn2.out")"

grep -q 'hello-from-a-short-launch' "$LOG2" \
  || fail "case 2: a short command no longer reaches the pane literally"
if [ -f "/tmp/fm-$ID2/launch.sh" ]; then
  fail "case 2: a short command was staged; staging must not change working launches"
fi
rmdir "/tmp/fm-$ID2/gotmp" "/tmp/fm-$ID2" 2>/dev/null || true
pass "a launch command under the bound still reaches the pane literally"

# --- case 3: the divergence, against a real tmux and a real shell ------------

if ! command -v tmux > /dev/null 2>&1; then
  echo "skip: tmux not found; the real-terminal divergence case did not run"
  exit 0
fi

REAL_TMUX=$(command -v tmux)
SOCKET="fm-launch-line-$$"
t() { "$REAL_TMUX" -L "$SOCKET" "$@"; }
cleanup_tmux() {
  t kill-server > /dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_tmux EXIT

MARKER_DIR="$TMP_ROOT/markers"
mkdir -p "$MARKER_DIR"

# Each shape gets its OWN pane. Sharing one pane let the truncated line's
# leftover input swallow whatever was sent next, which fails this case for a
# reason that is not the cap under test.
wait_for_file() { # <path> - returns 1 if it never appears
  local f=$1 i=0
  while [ "$i" -lt 100 ]; do
    [ -s "$f" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

open_pane() { # <session> - a real pane whose shell is proven to be reading input
  local ses=$1
  t new-session -d -s "$ses" -x 200 -y 50 || fail "case 3: real tmux new-session failed for $ses"
  t send-keys -t "$ses" -l "/bin/echo ready > $MARKER_DIR/$ses-ready.txt"
  t send-keys -t "$ses" Enter
  wait_for_file "$MARKER_DIR/$ses-ready.txt" \
    || fail "case 3: the real pane $ses never became ready"
}

# The same over-cap command, written two ways. Only the staged shape may survive.
BIG=$(printf 'y%.0s' $(seq 1 8192))
STAGE_FILE="$TMP_ROOT/staged-launch.sh"
printf '%s\n' "/bin/echo $BIG > $MARKER_DIR/staged.txt" > "$STAGE_FILE"

open_pane staged
t send-keys -t staged -l ". '$STAGE_FILE'"
t send-keys -t staged Enter
wait_for_file "$MARKER_DIR/staged.txt" \
  || fail "case 3: the staged command never executed in a real pane"
STAGED_LEN=$(wc -c < "$MARKER_DIR/staged.txt" | tr -d ' ')
[ "$STAGED_LEN" -ge 8192 ] \
  || fail "case 3: the staged command executed but lost bytes (got $STAGED_LEN of 8192)"

open_pane direct
t send-keys -t direct -l "/bin/echo $BIG > $MARKER_DIR/direct.txt"
t send-keys -t direct Enter
wait_for_file "$MARKER_DIR/direct.txt" || true

# The divergence: the direct line must NOT have made it through whole. If a
# platform ever raises MAX_CANON past this payload the case goes vacuous, so say
# so loudly rather than passing on an assertion that stopped meaning anything.
if [ -s "$MARKER_DIR/direct.txt" ]; then
  DIRECT_LEN=$(wc -c < "$MARKER_DIR/direct.txt" | tr -d ' ')
  [ "$DIRECT_LEN" -lt 8192 ] \
    || fail "case 3 is vacuous: an 8192-byte literal line survived this terminal, so the cap this fix exists for was not exercised"
fi
pass "a real pane truncates an over-cap literal line and executes the staged one whole"
