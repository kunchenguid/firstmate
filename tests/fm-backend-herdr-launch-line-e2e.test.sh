#!/usr/bin/env bash
# tests/fm-backend-herdr-launch-line-e2e.test.sh - isolated real-Herdr
# regression test for pre-launch line submission during a spawn.
#
# The guarantee under test: every line bin/fm-spawn.sh writes into a worker's
# pane before the launch command lands as its OWN submitted shell command, and
# the launch command then actually runs.
#
# Regression (2026-09-21, herdr 0.9.1): writing the pre-launch exports into a
# pane whose shell had not finished taking over the tty - the window between
# `treehouse get`'s nested shell appearing in `foreground_cwd` and its line
# editor accepting input - let the shell absorb the carriage return between two
# consecutive lines. The next line concatenated onto the same input line
# (`export COMPACT_ADVISER_DISABLE=1export FM_TASK_ID=<id>`), the staged launch
# command concatenated after that, and the whole thing died as one shell syntax
# error with no agent ever started. The Herdr backend was unusable for every
# spawn and every bin/fm-control.sh relaunch, which shares this same code path.
#
# This drives the REAL bin/fm-spawn.sh against real Herdr and real treehouse,
# because the defect lives in the interaction between the spawn sequence's
# timing and a live shell taking over a live pty. A unit assertion against a
# scripted fake CLI cannot produce that race and would have passed throughout.
# The pane is read through bin/fm-herdr-lab.sh rather than through the adapter
# primitive under test, so the observation is independent of the fix.
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): every lifecycle
# operation goes through bin/fm-herdr-lab.sh, which appends the named session
# flag and verifies the default fleet session is unchanged after teardown.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate default-on FM_HERDR_LAUNCH_LINE_E2E herdr jq treehouse git

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# Each spawn below places its worker from the lab session alone, so a Herdr pane
# inherited from the terminal this suite was started in must not follow it in as
# a cross-session parent identity.
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-launch-line.XXXXXX")
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-launch-line) || {
  rm -rf "$TMP_ROOT"
  printf 'not ok - could not generate an isolated Herdr lab session name\n' >&2
  exit 1
}
export HERDR_SESSION="$HERDR_LAB_SESSION"

WORKTREES=()
CLEANED=0
CHECKED=0
# Idempotent: fail() cleans up before exiting and the EXIT trap fires after it,
# so a second teardown would otherwise report the already-consumed fleet-state
# tripwire as if the lab had gone wrong.
cleanup_all() {
  local wt status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  for wt in ${WORKTREES[@]+"${WORKTREES[@]}"}; do
    [ -n "$wt" ] && treehouse return --force "$wt" >/dev/null 2>&1
  done
  WORKTREES=()
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab session"

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

HERDR_VER=$(herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

# --- scratch world ----------------------------------------------------------

PROJ="$TMP_ROOT/proj"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"
# The pool root is inside this test's own scratch directory so an acquired
# worktree never lands beside a real repository's pool.
printf 'max_trees = 4\nroot = "%s"\n' "$TMP_ROOT" > "$PROJ/treehouse.toml"
git -C "$PROJ" add README.md treehouse.toml
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm initial

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
# Presentation spaces are on by default; this suite asserts pane content, not
# layout, so it opts out to keep the spawn flat and cheap.
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"

RUNS=${FM_HERDR_LAUNCH_LINE_RUNS:-3}
case "$RUNS" in ''|*[!0-9]*) RUNS=3 ;; esac

# --- one real spawn ---------------------------------------------------------

# Each run asserts three independent things about the same pane:
#   1. the launch command ran at all (its receipt exists), which is exactly what
#      the captain lost - the pane sat at a shell prompt with no agent;
#   2. the launch inherited the pre-launch exports intact;
#   3. no rendered line merged two pre-launch commands, or a pre-launch command
#      with the staged launch source, which is the defect's visible signature
#      even in the runs where the launch itself survived.
run_once() {  # <n>
  local n=$1
  local id="launchline$n" brief out err rc meta window pane
  local tasktmp receipt cap i wt want got merged

  mkdir -p "$HOME_DIR/data/$id"
  brief="$HOME_DIR/data/$id/brief.md"
  cat > "$brief" <<EOF
# Task
## Captain's intent
Exercise Herdr pre-launch line submission for $id.

## Firstmate spec
Record the environment the launch command inherited, then idle briefly.
EOF

  receipt="$TMP_ROOT/receipt.$id"
  out="$TMP_ROOT/$id.out"
  err="$TMP_ROOT/$id.err"

  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
    HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" \
    "sh -c 'printf \"%s|%s\\n\" \"\$FM_TASK_ID\" \"\$GOTMPDIR\" > $receipt; sleep 300'" \
    --scout --backend herdr >"$out" 2>"$err"
  rc=$?
  [ "$rc" -eq 0 ] || fail "run $n: fm-spawn.sh on $HERDR_VER exited $rc"$'\n'"$(cat "$err")"

  meta="$HOME_DIR/state/$id.meta"
  [ -f "$meta" ] || fail "run $n: fm-spawn.sh recorded no task metadata"
  window=$(grep '^window=' "$meta" | cut -d= -f2-)
  [ -n "$window" ] || fail "run $n: the task record carries no endpoint"
  pane=${window#*:}
  tasktmp=$(grep '^tasktmp=' "$meta" | cut -d= -f2-)
  [ -n "$tasktmp" ] || fail "run $n: the task record carries no task temp directory"
  wt=$(grep '^worktree=' "$meta" | cut -d= -f2-)
  [ -n "$wt" ] && WORKTREES+=("$wt")

  # 1. the launch command actually started.
  i=0
  while [ "$i" -lt 60 ]; do
    [ -s "$receipt" ] && break
    i=$((i + 1))
    sleep 0.5
  done
  cap=$(lab pane read "$pane" --source recent-unwrapped 2>/dev/null || true)
  [ -s "$receipt" ] \
    || fail "run $n: the launch command never ran on $HERDR_VER; the pane was left at a shell prompt"$'\n'"--- pane ---"$'\n'"$cap"

  # 2. it inherited the pre-launch exports intact.
  want="$id|$tasktmp/gotmp"
  got=$(cat "$receipt")
  [ "$got" = "$want" ] \
    || fail "run $n: the launch command inherited '$got', want '$want'"$'\n'"--- pane ---"$'\n'"$cap"

  # 3. no rendered line merged two commands.
  merged=$(printf '%s\n' "$cap" | awk '{ if (gsub(/export /, "") > 1) print }')
  [ -z "$merged" ] \
    || fail "run $n: two pre-launch commands merged onto one input line on $HERDR_VER"$'\n'"$merged"
  merged=$(printf '%s\n' "$cap" | grep -F 'export ' | grep -F "$tasktmp" | grep -F '/launch.' || true)
  [ -z "$merged" ] \
    || fail "run $n: a pre-launch command merged with the staged launch source on $HERDR_VER"$'\n'"$merged"

  # The exports are only meaningful as evidence if they were rendered at all;
  # an empty capture must not pass checks 3 silently.
  printf '%s\n' "$cap" | grep -qF "export FM_TASK_ID=$id" \
    || fail "run $n: the pane never rendered its FM_TASK_ID export"$'\n'"--- pane ---"$'\n'"$cap"

  CHECKED=$((CHECKED + 1))
  pass "run $n: every pre-launch line landed as its own command and the launch ran on $HERDR_VER"
}

i=1
while [ "$i" -le "$RUNS" ]; do
  run_once "$i"
  i=$((i + 1))
done

# --- the relaunch half of the same handoff -----------------------------------
#
# bin/fm-control.sh relaunch drives bin/fm-spawn.sh --relaunch, which writes the
# same pre-launch lines into the task's existing pane. That path failed
# identically for the captain, so it is asserted here rather than assumed from
# the shared code. fm-control's own half needs a harness with verified control
# mechanics, which would cost model tokens; the launch half it delegates to is
# what carries the pre-launch lines.
relaunch_once() {
  local id="launchline$RUNS"
  local meta window pane receipt cap i wt want got merged tasktmp

  meta="$HOME_DIR/state/$id.meta"
  window=$(grep '^window=' "$meta" | cut -d= -f2-)
  pane=${window#*:}
  tasktmp=$(grep '^tasktmp=' "$meta" | cut -d= -f2-)
  receipt="$TMP_ROOT/receipt.$id.relaunch"

  # --relaunch refuses an endpoint that is not agent-free, so stop the
  # incarnation this task is already running.
  lab pane send-keys "$pane" ctrl+c >/dev/null 2>&1
  sleep 2

  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
    HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --harness \
    "sh -c 'printf \"%s|%s\\n\" \"\$FM_TASK_ID\" \"\$GOTMPDIR\" > $receipt; sleep 300'" \
    >"$TMP_ROOT/$id.relaunch.out" 2>"$TMP_ROOT/$id.relaunch.err"
  i=$?
  [ "$i" -eq 0 ] \
    || fail "relaunch: fm-spawn.sh --relaunch on $HERDR_VER exited $i"$'\n'"$(cat "$TMP_ROOT/$id.relaunch.err")"

  window=$(grep '^window=' "$meta" | cut -d= -f2-)
  pane=${window#*:}
  wt=$(grep '^worktree=' "$meta" | cut -d= -f2-)
  [ -n "$wt" ] && WORKTREES+=("$wt")

  i=0
  while [ "$i" -lt 60 ]; do
    [ -s "$receipt" ] && break
    i=$((i + 1))
    sleep 0.5
  done
  cap=$(lab pane read "$pane" --source recent-unwrapped 2>/dev/null || true)
  [ -s "$receipt" ] \
    || fail "relaunch: the replacement launch command never ran on $HERDR_VER"$'\n'"--- pane ---"$'\n'"$cap"
  want="$id|$tasktmp/gotmp"
  got=$(cat "$receipt")
  [ "$got" = "$want" ] \
    || fail "relaunch: the replacement inherited '$got', want '$want'"$'\n'"--- pane ---"$'\n'"$cap"
  merged=$(printf '%s\n' "$cap" | awk '{ if (gsub(/export /, "") > 1) print }')
  [ -z "$merged" ] \
    || fail "relaunch: two pre-launch commands merged onto one input line on $HERDR_VER"$'\n'"$merged"
  pass "relaunch: every pre-launch line landed as its own command and the replacement launch ran on $HERDR_VER"
}

relaunch_once

[ "$CHECKED" -eq "$RUNS" ] \
  || fail "expected $RUNS verified spawns on $HERDR_VER, verified $CHECKED"
pass "real Herdr ($HERDR_VER): $CHECKED consecutive spawns submitted every pre-launch line separately in isolated session $HERDR_LAB_SESSION"
