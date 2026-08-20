#!/usr/bin/env bash
# tests/fm-spawn-relaunch-worktree-e2e.test.sh - isolated real-herdr regression
# test for where a RELAUNCH REPLACEMENT endpoint comes up.
#
# When a relaunch adopts a still-present endpoint, that endpoint is already
# sitting in the task's worktree and there is nothing to place. When the
# recorded endpoint is provably gone, the relaunch creates a replacement, and
# that replacement used to be created exactly like a fresh spawn's: in the
# project directory. A fresh spawn recovers from that by running `treehouse
# get`, which acquires a worktree and moves the shell into it. A relaunch must
# never do that - allocating a second copy for one task is the hazard the
# worktree assertion exists to prevent - so nothing moved the replacement, and
# the assertion refused every one of them. Recovery was unreachable for exactly
# the case it exists for.
#
# The replacement is now created directly in the worktree the task's own record
# already names. This suite proves that against the REAL herdr CLI, because the
# claim is a herdr fact: that a pane created with --cwd reports that directory
# as its own. A canned fake can only replay the assumption already written into
# it, which is what let the original defect ship. The companion portable
# regression lives in tests/fm-spawn-relaunch.test.sh.
#
# The pane this recovers from is killed for real. A live pane exercises the
# adopt path, not the replacement path, so a test that only killed the AGENT
# would pass without touching the code under test.
#
# The harness is a plain shell command rather than a vendor agent: nothing here
# depends on what runs in the pane, only on where the pane is. That is the same
# raw-launch-command escape hatch tests/fm-backend-herdr-launcher-workspace-e2e.test.sh
# uses.
#
# Safety: every herdr call goes through bin/fm-herdr-lab.sh against this suite's
# own isolated session, which appends the required trailing --session and
# re-checks refuse-default before each lifecycle step. The live `default`
# session is never touched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CLEANED=0
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-relaunch-wt) || {
  printf 'not ok - could not generate an isolated herdr lab session name\n' >&2
  exit 1
}
export HERDR_SESSION="$HERDR_LAB_SESSION"
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-relaunch-wt-e2e.XXXXXX")

# Idempotent: fail() cleans up before exiting and the EXIT trap fires after it,
# so a second teardown would otherwise report the already-consumed fleet-state
# tripwire as if the lab had gone wrong.
cleanup_all() {
  local status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  chmod 0755 "$TMP_ROOT"/*/unenterable 2>/dev/null || true
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup_all EXIT

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated herdr lab session"

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# real_dir: the physical path, matching what a pane reports for its own cwd.
real_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# new_case: a real project, a real git worktree, a real herdr workspace, and a
# real task pane in that worktree - the state a running task is actually in.
# Echoes "<dir> <workspace-id> <tab-id> <pane-id>".
new_case() {  # <name> <id>
  local name=$1 id=$2 dir ws_json ws tab_json tab pane
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/proj" "$dir/home/state" "$dir/home/data/$id"
  ( cd "$dir/proj" && git init -q \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base ) >/dev/null 2>&1 \
    || return 1
  git -C "$dir/proj" worktree add -q -b "task-$id" "$dir/wt" >/dev/null 2>&1 || return 1
  printf '# brief for %s\n\nStay put.\n' "$id" > "$dir/home/data/$id/brief.md"
  ws_json=$(lab workspace create --cwd "$dir/proj" --label firstmate --no-focus) || return 1
  ws=$(printf '%s' "$ws_json" | jq -r '.result.workspace.workspace_id // empty')
  [ -n "$ws" ] || return 1
  tab_json=$(lab tab create --workspace "$ws" --cwd "$dir/wt" --label "fm-$id" --no-focus) || return 1
  tab=$(printf '%s' "$tab_json" | jq -r '.result.tab.tab_id // empty')
  pane=$(printf '%s' "$tab_json" | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$tab" ] && [ -n "$pane" ] || return 1
  printf '%s %s %s %s' "$dir" "$ws" "$tab" "$pane"
}

write_meta() {  # <dir> <id> <workspace> <tab> <pane> <recorded-worktree>
  local dir=$1 id=$2 ws=$3 tab=$4 pane=$5 wt=$6
  cat > "$dir/home/state/$id.meta" <<META
window=$HERDR_LAB_SESSION:$pane
endpoint_task_id=$id
worktree=$wt
project=$dir/proj
harness=sh
kind=ship
mode=direct-PR
yolo=off
backend=herdr
herdr_session=$HERDR_LAB_SESSION
herdr_workspace_id=$ws
herdr_tab_id=$tab
herdr_pane_id=$pane
model=default
effort=default
META
}

# kill_pane_for_real: end the pane's own process, the way a pane dies out from
# under a running worker. herdr reaps the pane itself, so `pane get` answers
# pane_not_found - the "provably absent" endpoint --relaunch recovers from.
kill_pane_for_real() {  # <pane>
  local pane=$1 i pid
  pid=$(lab pane get "$pane" 2>/dev/null | jq -r '.result.pane.pid // empty')
  if [ -n "$pid" ]; then
    kill -9 "$pid" 2>/dev/null || true
  else
    lab pane close "$pane" >/dev/null 2>&1 || true
  fi
  for i in $(seq 1 40); do
    if lab pane get "$pane" 2>&1 | jq -e '.error.code == "pane_not_found"' >/dev/null 2>&1; then
      return 0
    fi
    : "$i"
    sleep 0.25
  done
  return 1
}

run_relaunch() {  # <dir> <id> -> echoes combined output; caller checks $?
  local dir=$1 id=$2
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    HERDR_SESSION="$HERDR_LAB_SESSION" FM_HOME="$dir/home" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --harness "sh -c 'sleep 600'" 2>&1
}

meta_field() {  # <dir> <id> <key>
  awk -F= -v k="$3" '$1 == k { sub(/^[^=]*=/, ""); print }' "$1/home/state/$2.meta"
}

# --- 1. the replacement comes up inside the recorded worktree ----------------

test_replacement_starts_in_the_recorded_worktree() {
  local id=rlwt1 fields dir ws tab pane out rc new_pane seen want
  fields=$(new_case starts-in-worktree "$id") || fail "could not build the real task case"
  read -r dir ws tab pane <<EOF
$fields
EOF
  write_meta "$dir" "$id" "$ws" "$tab" "$pane" "$dir/wt"
  kill_pane_for_real "$pane" || fail "the task's pane did not become provably absent"

  out=$(run_relaunch "$dir" "$id"); rc=$?
  printf '%s\n' "$out" | sed 's/^/    relaunch| /'
  [ "$rc" -eq 0 ] || fail "a relaunch onto a genuinely dead pane must complete (exit $rc)"
  case "$out" in
    *"provably absent"*) ;;
    *) fail "the relaunch should have reported the endpoint as provably absent" ;;
  esac
  case "$out" in
    *"refusing to relaunch an agent outside"*)
      fail "the worktree assertion refused the replacement it created" ;;
  esac
  case "$out" in
    *"treehouse get"*) fail "a relaunch must never acquire another worktree" ;;
  esac

  new_pane=$(meta_field "$dir" "$id" herdr_pane_id)
  [ -n "$new_pane" ] || fail "no replacement pane was recorded"
  [ "$new_pane" != "$pane" ] || fail "the record still points at the destroyed pane"

  seen=$(lab pane get "$new_pane" | jq -r '.result.pane.foreground_cwd // empty')
  want=$(real_dir "$dir/wt")
  printf '    replacement pane %s cwd: %s\n' "$new_pane" "$seen"
  [ "$(real_dir "$seen")" = "$want" ] \
    || fail "the replacement agent came up in '$seen', not the recorded worktree '$want'"
  [ "$(real_dir "$seen")" != "$(real_dir "$dir/proj")" ] \
    || fail "the replacement agent came up in the project directory"
  [ "$(meta_field "$dir" "$id" worktree)" = "$dir/wt" ] \
    || fail "the replacement was recorded against a different worktree"
  pass "fm-spawn --relaunch: a replacement for a genuinely dead pane comes up inside the recorded worktree"
}

# --- 2. and refuses, placing nothing, when that worktree cannot be reached ---
#
# The fix makes the worktree assertion's precondition true. It must not buy that
# by starting the agent somewhere reachable instead: a worktree herdr cannot
# enter has to end the relaunch, with no pane created anywhere.
test_relaunch_refuses_an_unreachable_worktree() {
  local id=rlwt2 fields dir ws tab pane out rc tabs
  fields=$(new_case unreachable-worktree "$id") || fail "could not build the real task case"
  read -r dir ws tab pane <<EOF
$fields
EOF
  mkdir -p "$dir/unenterable"
  chmod 000 "$dir/unenterable"
  write_meta "$dir" "$id" "$ws" "$tab" "$pane" "$dir/unenterable"
  kill_pane_for_real "$pane" || fail "the task's pane did not become provably absent"

  out=$(run_relaunch "$dir" "$id"); rc=$?
  printf '%s\n' "$out" | sed 's/^/    relaunch| /'
  [ "$rc" -ne 0 ] || fail "a relaunch that cannot reach the recorded worktree must refuse"

  tabs=$(lab tab list --workspace "$ws" | jq -r --arg want "fm-$id" \
    '[.result.tabs[]? | select(.label == $want)] | length')
  [ "$tabs" = 0 ] \
    || fail "a refused relaunch left $tabs endpoint(s) for $id behind in workspace $ws"
  [ "$(meta_field "$dir" "$id" herdr_pane_id)" = "$pane" ] \
    || fail "a refused relaunch must leave the task's record untouched"
  chmod 0755 "$dir/unenterable"
  pass "fm-spawn --relaunch: refuses and creates nothing when the recorded worktree cannot be entered"
}

test_replacement_starts_in_the_recorded_worktree
test_relaunch_refuses_an_unreachable_worktree

echo "all tests passed"
