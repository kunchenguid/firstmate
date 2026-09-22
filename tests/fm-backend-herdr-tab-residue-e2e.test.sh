#!/usr/bin/env bash
# tests/fm-backend-herdr-tab-residue-e2e.test.sh - isolated real-herdr
# regression test for issue #17: a task tab that outlived its own teardown.
#
# Herdr removes a tab only when its LAST pane closes, so firstmate's exact
# task-pane close left the whole fm-<id> tab alive whenever anything else sat
# in that tab - the herdr-sidebar plugin docks one into every tab within a
# second of its creation, and an operator split does the same. The registered
# pane really was gone, so teardown completed and removed every durable record,
# and the surviving tab was then named by nothing at all.
#
# The fixture here uses `herdr pane split` instead of a plugin, so the shape is
# reproduced deterministically wherever Herdr is installed. Presentation
# projection is deliberately disabled for the spawned cases: the reported
# residue is the flat tab, and the projected abort path is exercised directly
# against the adapter below.
#
# Safety: every Herdr call goes through bin/fm-herdr-lab.sh against a private
# fm-lab-* session, and the helper is the only process that appends the
# trailing --session flag (tests/herdr-test-safety.sh).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

REAL_HERDR=$(command -v herdr)
REAL_TREEHOUSE=$(command -v treehouse)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-tab-residue.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
export REAL_HERDR HERDR_ORIGINAL_PATH HERDR_LAB_HELPER

# Route every adapter call through the lab helper, which is the only process
# that appends the real trailing session flag. The adapter's session-independent
# version read cannot pass the helper's leading-option guard, so it goes to the
# absolute binary with the same explicit lab session.
# The wrapper also models a docking plugin: when $DOCK_CONTROL names a tab
# label, a successful `tab create` for that label immediately splits the new
# root pane, which is what herdr-sidebar 0.11.0 does within a second of every
# tab creation. That injection is what puts a foreign pane inside a projection
# before its shape is verified, with no plugin installed.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$(( ${#args[@]} - 1 ))
flag=$(( last - 1 ))
if [ "${#args[@]}" -ge 2 ] \
   && [ "${args[$flag]}" = --session ] \
   && [ "${args[$last]}" = "${HERDR_LAB_SESSION:?}" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in
    --session|--session=*)
      echo "test wrapper: unexpected caller-supplied session flag" >&2
      exit 1
      ;;
  esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
dock_label=$(cat "${DOCK_CONTROL:-/dev/null}" 2>/dev/null || true)
if [ -n "$dock_label" ] && [ "${1:-} ${2:-}" = "tab create" ]; then
  label=
  previous=
  for arg in "$@"; do
    [ "$previous" = --label ] && label=$arg
    previous=$arg
  done
  if [ "$label" = "$dock_label" ]; then
    if out=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"); then
      docked=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
      [ -z "$docked" ] || env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" \
        pane split "$docked" --direction right --cwd "${DOCK_CWD:-/tmp}" --no-focus >/dev/null 2>&1 || true
      [ -z "$out" ] || printf '%s\n' "$out"
      exit 0
    fi
    exit 1
  fi
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$PATH"
DOCK_CONTROL="$TMP_ROOT/dock-label"
DOCK_CWD="$TMP_ROOT"
: > "$DOCK_CONTROL"
export DOCK_CONTROL DOCK_CWD

HERDR_LAB_SESSION=$(PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" name fm-herdr-tab-residue)
export HERDR_SESSION="$HERDR_LAB_SESSION" HERDR_LAB_SESSION
LAB_READY=0
RECORDED_WORKTREES=""
cleanup_all() {
  local wt
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ -d "$wt" ] || continue
    "$REAL_TREEHOUSE" return --force "$wt" >/dev/null 2>&1 || true
  done <<EOF
$RECORDED_WORKTREES
EOF
  if [ "$LAB_READY" -eq 1 ]; then
    PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
    LAB_READY=0
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT

PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab"
LAB_READY=1

lab() {
  PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

focus_now() {
  lab workspace list | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | if length == 1 then "\(.[0].workspace_id)/\(.[0].active_tab_id)" else "ambiguous" end
  '
}

# Herdr applies a focus change asynchronously, so a restore can land just after
# the call that triggered it returns. Poll briefly rather than sampling once.
assert_focus_settles_at() {  # <expected> <case-name>
  local expected=$1 case_name=$2 actual attempt=0
  while [ "$attempt" -lt 30 ]; do
    actual=$(focus_now)
    [ "$actual" = "$expected" ] && return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  fail "$case_name left the captain's active workspace and tab at $actual instead of $expected"
}

tab_count() {  # <workspace> <tab>
  lab workspace get "$1" >/dev/null 2>&1 || { printf 0; return 0; }
  lab tab list --workspace "$1" | jq -r --arg t "$2" '[.result.tabs[]? | select(.tab_id == $t)] | length'
}

HOME_DIR="$TMP_ROOT/home"
PROJECT_DIR="$TMP_ROOT/project"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
mkdir -p "$PROJECT_DIR"
git -C "$PROJECT_DIR" init -q
printf '# Herdr tab residue fixture\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJECT_DIR" "$PROJECT_DIR.origin.git"
git -C "$PROJECT_DIR" remote add origin "file://$PROJECT_DIR.origin.git"

# A freshly provisioned lab holds no workspace at all, so seed the captain's
# own anchor first: every assertion below reads focus against it, exactly as a
# captain's live session would sit beside the task tabs.
CAPTAIN_OUT=$(lab workspace create --cwd "$TMP_ROOT" --label captain) \
  || fail "could not seed the captain anchor workspace"
CAPTAIN_WS=$(printf '%s' "$CAPTAIN_OUT" | jq -r '.result.workspace.workspace_id // empty')
CAPTAIN_TAB=$(printf '%s' "$CAPTAIN_OUT" | jq -r '.result.tab.tab_id // empty')
[ -n "$CAPTAIN_WS" ] && [ -n "$CAPTAIN_TAB" ] \
  || fail "the captain anchor workspace returned no workspace or tab id"
CAPTAIN_FOCUS="$CAPTAIN_WS/$CAPTAIN_TAB"
lab tab focus "$CAPTAIN_TAB" >/dev/null || fail "could not focus the captain anchor tab"

RESIDUE_WS=
RESIDUE_TAB=
RESIDUE_PANE=
RESIDUE_SIBLING=
# Spawns one real task and splits its pane, so the task tab carries exactly the
# sibling that used to strand it. Sets the RESIDUE_* globals: a command
# substitution would run fail() in a subshell, where its exit cannot stop this
# suite.
residue_fixture() {  # <id>
  local id=$1 meta wt count
  mkdir -p "$HOME_DIR/data/$id"
  cat > "$HOME_DIR/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Tab residue fixture $id.

## Firstmate spec
Hold a task tab open while the fixture splits its pane.
EOF
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJECT_DIR" "sh -c 'while :; do sleep 60; done'" \
    --mode no-mistakes --yolo off --backend herdr \
    > "$TMP_ROOT/$id.out" 2> "$TMP_ROOT/$id.err" \
    || fail "residue fixture spawn $id failed: $(cat "$TMP_ROOT/$id.err")"
  meta="$HOME_DIR/state/$id.meta"
  wt=$(grep '^worktree=' "$meta" | cut -d= -f2-)
  [ -n "$wt" ] || fail "residue fixture $id recorded no worktree"
  RECORDED_WORKTREES="${RECORDED_WORKTREES}${wt}"$'\n'
  RESIDUE_WS=$(grep '^herdr_workspace_id=' "$meta" | cut -d= -f2-)
  RESIDUE_TAB=$(grep '^herdr_tab_id=' "$meta" | cut -d= -f2-)
  RESIDUE_PANE=$(grep '^herdr_pane_id=' "$meta" | cut -d= -f2-)
  [ -n "$RESIDUE_WS" ] && [ -n "$RESIDUE_TAB" ] && [ -n "$RESIDUE_PANE" ] \
    || fail "residue fixture $id recorded no exact herdr workspace, tab, and pane"
  # --cwd keeps the sibling's shell out of the task worktree, so teardown's
  # leaked-worktree-process sweep cannot end it: the pane that strands the tab
  # in the field is a plugin's, living wherever the plugin put it. --no-focus
  # keeps the captain where they were, which is the case under test.
  lab pane split "$RESIDUE_PANE" --direction right --cwd "$TMP_ROOT" --no-focus >/dev/null \
    || fail "could not split the task pane of residue fixture $id"
  count=$(lab pane list --workspace "$RESIDUE_WS" \
    | jq -r --arg t "$RESIDUE_TAB" '[.result.panes[]? | select(.tab_id == $t)] | length')
  [ "$count" -ge 2 ] || fail "the sibling pane of residue fixture $id did not land in its task tab"
  RESIDUE_SIBLING=$(lab pane list --workspace "$RESIDUE_WS" \
    | jq -r --arg t "$RESIDUE_TAB" --arg p "$RESIDUE_PANE" \
      '[.result.panes[]? | select(.tab_id == $t and .pane_id != $p) | .pane_id][0] // empty')
  [ -n "$RESIDUE_SIBLING" ] || fail "could not identify the sibling pane of residue fixture $id"
  # Put the captain back on their own tab and let that focus settle, so the
  # case under test is a docked pane in a task tab nobody is looking at.
  lab tab focus "$CAPTAIN_TAB" >/dev/null \
    || fail "could not restore captain focus for residue fixture $id"
  assert_focus_settles_at "$CAPTAIN_FOCUS" "residue fixture $id setup"
}

teardown_fixture() {  # <id>
  local id=$1
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force \
    > "$TMP_ROOT/$id-teardown.out" 2> "$TMP_ROOT/$id-teardown.err"
}

# --- 1. the reported leak path ----------------------------------------------
residue_fixture residue-flat
FOCUS_BEFORE=$CAPTAIN_FOCUS
teardown_fixture residue-flat \
  || fail "teardown of the residue fixture failed: $(cat "$TMP_ROOT/residue-flat-teardown.err")"
[ "$(tab_count "$RESIDUE_WS" "$RESIDUE_TAB")" = 0 ] \
  || fail "teardown left the task tab $RESIDUE_TAB behind with its sibling pane: $(grep -E '^(warning|error):' "$TMP_ROOT/residue-flat-teardown.err" | tr '\n' '|')"
if lab pane get "$RESIDUE_SIBLING" >/dev/null 2>&1; then
  fail "teardown left the sibling pane $RESIDUE_SIBLING behind"
fi
[ ! -e "$HOME_DIR/state/residue-flat.meta" ] || fail "teardown retained the task's durable records"
assert_focus_settles_at "$FOCUS_BEFORE" "the tab reclaim"
pass "real Herdr lab: a sibling pane in the task tab does not outlive teardown"

# --- 2. the close is unconditional, by decision -----------------------------
# A sibling that carries an agent dies with the task tab: a close conditioned on
# what sits in the tab would restore the residue in exactly the cases where it
# declined.
residue_fixture residue-agent
lab pane report-agent "$RESIDUE_SIBLING" --source fm-tab-residue-e2e --agent test-agent --state idle >/dev/null \
  || fail "could not register the agent-bearing sibling fixture"
teardown_fixture residue-agent \
  || fail "teardown with an agent-bearing sibling failed: $(cat "$TMP_ROOT/residue-agent-teardown.err")"
[ "$(tab_count "$RESIDUE_WS" "$RESIDUE_TAB")" = 0 ] \
  || fail "teardown left the task tab $RESIDUE_TAB behind because its sibling pane carried an agent"
if lab pane get "$RESIDUE_SIBLING" >/dev/null 2>&1; then
  fail "teardown left the agent-bearing sibling pane $RESIDUE_SIBLING behind"
fi
[ ! -e "$HOME_DIR/state/residue-agent.meta" ] || fail "teardown retained the task's durable records"
pass "real Herdr lab: an agent-bearing sibling dies with the task tab it was parked in"

# --- 3. a foreign pane does not fail a projection, and strands nothing ------
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
PROJECTION_TOKEN=$(fm_backend_herdr_projection_id)
PROJECTION_LABEL=$(fm_backend_herdr_projection_workspace_label converge1 "$PROJECTION_TOKEN")
printf '%s\n' fm-converge1 > "$DOCK_CONTROL"
CREATE_STATUS=0
FM_HOME="$HOME_DIR" fm_backend_herdr_projection_create_task \
  "$PROJECT_DIR" "$PROJECTION_LABEL" fm-converge1 2> "$TMP_ROOT/converge1-create.err" || CREATE_STATUS=$?
: > "$DOCK_CONTROL"
PROJECTION_WS=$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID
PROJECTION_TAB=$FM_BACKEND_HERDR_PROJECTION_TAB_ID
PROJECTION_PANE=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
PROJECTION_SEEDED_TAB=$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID
[ "$(lab pane list --workspace "$PROJECTION_WS" \
  | jq -r --arg t "$PROJECTION_TAB" '[.result.panes[]? | select(.tab_id == $t)] | length')" -ge 2 ] \
  || fail "the docked pane fixture did not land in the projected task tab"
lab pane get "$PROJECTION_PANE" >/dev/null 2>&1 \
  || fail "the projection reported a task pane that does not exist"
SEEDED_LABEL=$(lab tab list --workspace "$PROJECTION_WS" \
  | jq -r --arg t "$PROJECTION_SEEDED_TAB" '[.result.tabs[]? | select(.tab_id == $t) | .label][0] // empty')
if [ -z "$SEEDED_LABEL" ]; then
  [ "$CREATE_STATUS" = 0 ] \
    || fail "a pane docked into the task tab failed the projection: $(cat "$TMP_ROOT/converge1-create.err")"
  pass "real Herdr lab: a foreign pane in the task tab does not fail the projection's shape check"
elif [ "$SEEDED_LABEL" = 1 ]; then
  fail "the seeded tab survived its own prune with its original label: $(cat "$TMP_ROOT/converge1-create.err")"
else
  # Something outside Firstmate renamed the seeded default tab before the prune
  # could recognize it, so this Herdr cannot reach a converged projection at
  # all and the docked-pane verdict is unobservable here. Report that rather
  # than passing or failing on an unrelated cause; the projection's own label
  # guard owns the rename case.
  echo "skip: seeded tab $PROJECTION_SEEDED_TAB was renamed to '$SEEDED_LABEL' before its prune, so projection convergence cannot be observed in this Herdr"
fi

# The same projection, aborted: its disposable workspace must not survive the
# pane a plugin docked into it.
fm_backend_herdr_projection_cleanup_exact "$HERDR_LAB_SESSION" \
  "$PROJECTION_PANE" "$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID" \
  "$PROJECTION_WS" "$PROJECTION_TAB" "$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID" \
  2> "$TMP_ROOT/converge1-cleanup.err" || true
if lab workspace get "$PROJECTION_WS" >/dev/null 2>&1; then
  fail "the aborted projected attempt stranded its disposable workspace $PROJECTION_WS"
fi
pass "real Herdr lab: an aborted projected attempt leaves no disposable workspace behind"

PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" \
  || fail "guarded Herdr lab teardown or default-session tripwire verification failed"
LAB_READY=0
pass "real Herdr lab: tab-residue coverage completed with the default-session tripwire intact"

cleanup_all
trap - EXIT
