#!/usr/bin/env bash
# Herdr-only unconfigured startup, raw-command dispatch and exact teardown.
# The historical filename remains registered for existing CI selections.
# Retired explicit selections are covered by fm-retired-backends.test.sh.
#
# Safety (2026-07-02 incident): every test-owned Herdr operation goes through
# bin/fm-herdr-lab.sh, which appends the named session flag and verifies the
# default fleet session is unchanged after teardown. Never replace the helper
# with an ambient HERDR_SESSION-only command.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
  esac
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

export FM_GATE_REFUSE_BYPASS=1

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# This suite asserts that HERDR_ENV=1 alone selects the backend, and it runs
# against its own isolated lab session. A Herdr pane inherited from the terminal
# it was launched in must not follow spawn into that session as a cross-session
# parent identity; the spawn below sets HERDR_ENV explicitly.
herdr_forget_inherited_pane

# TMP_ROOT is physically resolved (mktemp -d "$(pwd -P)"-relative) to keep this
# real-herdr smoke fixture free of unrelated OS symlink noise.
# The old fm-spawn bug that originally motivated this fixture shape was fixed in
# fm-spawn-symlink-guard-s8: fm-spawn.sh now normalizes PROJ_ABS and observed
# backend cwd reads before the worktree-discovery comparison.
# The dedicated regression is
# tests/fm-backend.test.sh:test_spawn_symlinked_project_prefix_avoids_false_refusal.
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-backend-autodetect-smoke.XXXXXX")
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
CLEAN_PATH=$PATH
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name "${FM_HERDR_LAB_TASK:-default-herdr-smoke}") || {
  rm -rf "$TMP_ROOT"
  fail "could not generate an isolated Herdr lab session name"
}
export HERDR_SESSION="$HERDR_LAB_SESSION"
ID="autodetectsmoke1"
WT=
cleanup_all() {
  local cleanup_status=0
  [ -n "$WT" ] && command -v treehouse >/dev/null 2>&1 && treehouse return "$WT" >/dev/null 2>&1
  PATH="$CLEAN_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || cleanup_status=$?
  rm -rf "$TMP_ROOT"
  return "$cleanup_status"
}
on_exit() {
  local status=$?
  cleanup_all || status=$?
  trap - EXIT
  exit "$status"
}
trap on_exit EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab session"
herdr_test_guard_cli "$HERDR_LAB_SESSION" "$TMP_ROOT/guard" "$HERDR_LAB_HELPER" || fail "lab guard failed"
export PATH="$TMP_ROOT/guard:$PATH"

# --- scratch world: FM_HOME with NO backend config, one throwaway project ---

STATE="$TMP_ROOT/state"; DATA="$TMP_ROOT/data"; CONFIG="$TMP_ROOT/config"
mkdir -p "$STATE" "$DATA/$ID" "$CONFIG"
# Keep the default projection path enabled so this real spawn also proves that
# its durable endpoint identity can make the ordinary cleanup round trip.
printf 'on\n' > "$CONFIG/herdr-presentation-spaces"
cat > "$DATA/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Herdr backend auto-detection.

## Firstmate spec
Verify the real spawn path selects Herdr.
EOF

PROJ="$TMP_ROOT/scratch-project"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

# A projected child needs one unambiguous parent workspace in the named lab.
# It is fixture-only and disappears with the guarded whole-lab teardown.
PATH="$CLEAN_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" \
  workspace create --label firstmate --cwd "$PROJ" --focus >/dev/null \
  || fail 'could not create the exact presentation parent fixture'

# --- spawn with NO explicit backend config; HERDR_ENV=1 is the only marker --

OUT_FILE="$TMP_ROOT/spawn.out"; ERR_FILE="$TMP_ROOT/spawn.err"
env -u TMUX -u FM_BACKEND PATH="$PATH" HERDR_ENV=1 \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP_ROOT" \
  FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
  FM_CONFIG_OVERRIDE="$CONFIG" FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" \
  FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" "sh -c 'touch $TMP_ROOT/command-acted; sleep 300'" --mode no-mistakes --yolo off \
  >"$OUT_FILE" 2>"$ERR_FILE"
status=$?
[ "$status" -eq 0 ] || fail "fm-spawn.sh did not succeed auto-detecting herdr"$'\n'"--- stdout ---"$'\n'"$(cat "$OUT_FILE")"$'\n'"--- stderr ---"$'\n'"$(cat "$ERR_FILE")"

pass "real Herdr: unconfigured intake selects the retained backend"

META="$STATE/$ID.meta"
[ -f "$META" ] || fail "fm-spawn.sh did not write a meta file for $ID"
assert_contains_local "$(cat "$META")" "backend=herdr" \
  "auto-detected spawn did not record backend=herdr in meta"
assert_contains_local "$(cat "$META")" "herdr_session=$HERDR_LAB_SESSION" \
  "auto-detected spawn did not record the isolated herdr_session in meta"

WORKSPACE=$(grep '^herdr_workspace_id=' "$META" | cut -d= -f2-)
[ -n "$WORKSPACE" ] || fail "auto-detected spawn meta is missing herdr_workspace_id"

TAB=$(grep '^herdr_tab_id=' "$META" | cut -d= -f2-)
[ -n "$TAB" ] || fail "auto-detected spawn meta is missing herdr_tab_id"

WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  fail "auto-detected spawn did not report a real worktree path"
fi

PANE=$(grep '^herdr_pane_id=' "$META" | cut -d= -f2-)
[ -n "$PANE" ] || fail "auto-detected spawn meta is missing herdr_pane_id"
pass "real herdr: auto-detected spawn records backend=herdr and herdr_session/workspace/tab/pane fields in meta"

JOURNAL="$STATE/$ID.herdr-presentation"
[ -f "$JOURNAL" ] || fail 'projected real spawn did not publish an endpoint journal'
FM_HOME="$TMP_ROOT" FM_ROOT_OVERRIDE="$ROOT" bash -c '
  . "$1/bin/backends/herdr.sh"
  fm_backend_herdr_projection_journal_snapshot "$2" "$3"
  [ "$FM_BACKEND_HERDR_JOURNAL_HAS_ENDPOINT" = 1 ] &&
    [ "$FM_BACKEND_HERDR_JOURNAL_HAS_LAUNCH_IDENTITY" = 1 ]
' _ "$ROOT" "$JOURNAL" "$ID" || fail "newly launched task did not retain structural launch identity"$'\n'"--- journal ---"$'\n'"$(cat "$JOURNAL")"$'\n'"--- spawn stderr ---"$'\n'"$(cat "$ERR_FILE")"
pass 'real Herdr: a new launch retains cleanup-usable structural launch identity'

# --- confirm the trivial launch command actually ran in the herdr pane ------

for _ in $(seq 1 100); do [ ! -f "$TMP_ROOT/command-acted" ] || break; sleep 0.1; done
[ -f "$TMP_ROOT/command-acted" ] || fail "the dispatched command did not write its independent marker"
pass "real Herdr: raw command dispatch acted in the isolated pane"
PATH="$CLEAN_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane close "$PANE" >/dev/null \
  || fail 'could not model the completed fixture endpoint disappearing through its exact lab pane'

# The production cleanup boundary requires semantic acceptance independently
# from endpoint identity. Reconcile the synthetic task to that terminal state.
LIFECYCLE="$DATA/$ID/lifecycle.json"
if [ ! -f "$LIFECYCLE" ]; then
  FM_HOME="$TMP_ROOT" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
    "$ROOT/bin/fm-task-state.sh" init "$ID" >/dev/null || fail 'could not initialize lifecycle for cleanup round trip'
fi
REVISION=$(jq -r '.revision' "$LIFECYCLE")
jq '.disposition="accepted" | .assessment.remaining_gap=""' "$LIFECYCLE" > "$TMP_ROOT/accepted.json"
chmod 600 "$TMP_ROOT/accepted.json"
FM_HOME="$TMP_ROOT" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
  "$ROOT/bin/fm-task-state.sh" reconcile "$ID" --expected-revision "$REVISION" --record "$TMP_ROOT/accepted.json" >/dev/null \
  || fail 'could not accept the synthetic completed task'

# The ordinary cleanup path must consume the launch identity idempotently after
# the exact lab pane has disappeared.
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail 'could not load Herdr presence reader'

# --- teardown completes the trivial spawn/teardown cycle --------------------

TEARDOWN_OUT="$TMP_ROOT/teardown.out"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP_ROOT" \
  FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
  FM_CONFIG_OVERRIDE="$CONFIG" \
  "$ROOT/bin/fm-teardown.sh" "$ID" >"$TEARDOWN_OUT" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "fm-teardown.sh failed for the auto-detected herdr task"$'\n'"$(cat "$TEARDOWN_OUT")"
[ -f "$META" ] && fail "fm-teardown.sh did not remove $META"
# An error-only CLI response can leave jq with an empty input and exit zero.
# Require the shared structural absence verdict, not a pipeline exit status.
# shellcheck source=bin/fm-backend.sh
presence=$(fm_backend_herdr_pane_presence_state "$HERDR_LAB_SESSION" "$PANE")
[ "$presence" = dead ] || { cat "$TEARDOWN_OUT" >&2; fail "exact pane disappearance is unproven: $presence"; }

WT=
pass "real herdr: new launch completes the ordinary spawn-to-cleanup round trip (meta cleared, pane closed)"

if ! cleanup_all; then
  trap - EXIT
  fail "isolated Herdr lab teardown failed or the default fleet session changed"
fi
trap - EXIT
pass "real herdr: isolated lab session removed and default fleet session unchanged"
