#!/usr/bin/env bash
# Isolated real-Herdr E2E coverage for the default-off disposable single-task
# presentation projection.
# The test drives the real spawn and teardown scripts, a real Treehouse pool,
# and the guarded named-session lab helper.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
REAL_TREEHOUSE=$(command -v treehouse)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-presentation.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HERDR_CALL_LOG="$TMP_ROOT/herdr-calls.log"
TREEHOUSE_CALL_LOG="$TMP_ROOT/treehouse-calls.log"
mkdir -p "$FAKEBIN"
: > "$HERDR_CALL_LOG"
: > "$TREEHOUSE_CALL_LOG"
export REAL_HERDR REAL_TREEHOUSE HERDR_CALL_LOG TREEHOUSE_CALL_LOG HERDR_ORIGINAL_PATH HERDR_LAB_HELPER

# Log every production-adapter call, remove its already-validated trailing
# session flag, and send the operation through the lab helper so that helper
# remains the sole process which appends the real trailing session flag.
# The adapter's deliberately session-independent version read cannot pass the
# helper's leading-option guard, so the wrapper sends only that read straight
# to the absolute real binary with the same explicit trailing lab session.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 0 ] && printf '\t'
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "$HERDR_CALL_LOG"
args=("$@")
last_index=$((${#args[@]} - 1))
flag_index=$((last_index - 1))
if [ "${#args[@]}" -ge 2 ] \
   && [ "${args[$flag_index]}" = --session ] \
   && [ "${args[$last_index]}" = "${HERDR_LAB_SESSION:?}" ]; then
  unset "args[$last_index]" "args[$flag_index]"
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
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 0 ] && printf '\t'
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "$TREEHOUSE_CALL_LOG"
exec "$REAL_TREEHOUSE" "$@"
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/treehouse"
export PATH="$FAKEBIN:$PATH"

HERDR_LAB_SESSION=$(PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" name fm-herdr-presentation-projection)
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
    PATH="$HERDR_ORIGINAL_PATH" \
      "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
    LAB_READY=0
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT

PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab"
LAB_READY=1

lab() {
  PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

remember_meta_worktree() {  # <meta>
  local wt
  wt=$(grep '^worktree=' "$1" | cut -d= -f2-)
  [ -n "$wt" ] || fail "metadata did not record a worktree"
  RECORDED_WORKTREES="${RECORDED_WORKTREES}${wt}"$'\n'
  printf '%s' "$wt"
}

make_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# Herdr projection E2E fixture\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

spawn_task() {  # <id> <home> <project>
  local id=$1 home=$2 project=$3
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "sh -c 'sleep 120'" --backend herdr
}

teardown_task() {  # <id> <home>
  local id=$1 home=$2
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force
}

normalize_meta() {  # <meta>
  sed -E \
    -e 's|^window=.*$|window=<herdr-container-id>|' \
    -e 's|^herdr_workspace_id=.*$|herdr_workspace_id=<herdr-container-id>|' \
    -e 's|^herdr_tab_id=.*$|herdr_tab_id=<herdr-container-id>|' \
    -e 's|^herdr_pane_id=.*$|herdr_pane_id=<herdr-container-id>|' \
    "$1"
}

log_line_count() { wc -l < "$HERDR_CALL_LOG" | tr -d '[:space:]'; }

assert_no_projection_mutation_since() {  # <line-count> <case-name>
  local start=$1 name=$2 calls
  calls=$(sed -n "$((start + 1)),\$p" "$HERDR_CALL_LOG")
  if printf '%s\n' "$calls" | grep -E $'^(workspace\t(create|close|rename)|tab\t(create|close)|pane\tclose|session\t(stop|delete)|server)' >/dev/null 2>&1; then
    fail "$name performed a create, close, delete, rename, or lifecycle call during recovery inspection"
  fi
}

HOME_DIR="$TMP_ROOT/home"
PROJECT_DIR="$TMP_ROOT/project"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data/shape" "$HOME_DIR/data/restart1"
touch "$HOME_DIR/state/.last-watcher-beat"
printf 'Projection E2E fixture.\n' > "$HOME_DIR/data/shape/brief.md"
printf 'Projection restart fixture.\n' > "$HOME_DIR/data/restart1/brief.md"
make_project "$PROJECT_DIR"

NEIGHBOR_OUT=$(lab workspace create --cwd "$PROJECT_DIR" --label neighbor --focus) \
  || fail "could not create the focused neighboring workspace"
NEIGHBOR_WSID=$(printf '%s' "$NEIGHBOR_OUT" | jq -r '.result.workspace.workspace_id // empty')
NEIGHBOR_PANE=$(printf '%s' "$NEIGHBOR_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$NEIGHBOR_WSID" ] && [ -n "$NEIGHBOR_PANE" ] || fail "neighbor create returned incomplete IDs"

# The same task id and project run once with the flag absent and once with it
# present, so Treehouse commands and metadata can be compared directly.
: > "$TREEHOUSE_CALL_LOG"
spawn_task shape "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/off.out" 2> "$TMP_ROOT/off.err" \
  || fail "flag-off spawn failed: $(cat "$TMP_ROOT/off.err")"
OFF_META="$TMP_ROOT/off.meta"
cp "$HOME_DIR/state/shape.meta" "$OFF_META"
OFF_WT=$(remember_meta_worktree "$OFF_META")
teardown_task shape "$HOME_DIR" > "$TMP_ROOT/off-teardown.out" 2> "$TMP_ROOT/off-teardown.err" \
  || fail "flag-off teardown failed: $(cat "$TMP_ROOT/off-teardown.err")"
cp "$TREEHOUSE_CALL_LOG" "$TMP_ROOT/off-treehouse.log"

: > "$TREEHOUSE_CALL_LOG"
: > "$HOME_DIR/config/herdr-presentation-spaces"
spawn_task shape "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/on.out" 2> "$TMP_ROOT/on.err" \
  || fail "projected spawn failed: $(cat "$TMP_ROOT/on.err")"
ON_META="$TMP_ROOT/on.meta"
cp "$HOME_DIR/state/shape.meta" "$ON_META"
ON_WT=$(remember_meta_worktree "$ON_META")
JOURNAL="$HOME_DIR/state/shape.herdr-presentation"
[ -f "$JOURNAL" ] || fail "projected spawn did not publish its presentation journal"
TOKEN=$(grep '^projection_id=' "$JOURNAL" | cut -d= -f2-)
[ "${#TOKEN}" -eq 22 ] || fail "projection id is not the compact 22-character encoding of 128 bits"
PROJECTED_WSID=$(grep '^herdr_workspace_id=' "$ON_META" | cut -d= -f2-)
PROJECTED_TAB=$(grep '^herdr_tab_id=' "$ON_META" | cut -d= -f2-)
PROJECTED_PANE=$(grep '^herdr_pane_id=' "$ON_META" | cut -d= -f2-)
PROJECTED_INFO=$(lab workspace get "$PROJECTED_WSID") || fail "could not inspect the projected workspace"
PROJECTED_LABEL=$(printf '%s' "$PROJECTED_INFO" | jq -r '.result.workspace.label // empty')
[ "$PROJECTED_LABEL" = "firstmate/shape · p:$TOKEN" ] \
  || fail "projected workspace label did not contain the full visible token: $PROJECTED_LABEL"
PROJECTED_TABS=$(lab tab list --workspace "$PROJECTED_WSID")
PROJECTED_PANES=$(lab pane list --workspace "$PROJECTED_WSID")
[ "$(printf '%s' "$PROJECTED_TABS" | jq -r '.result.tabs | length')" = 1 ] \
  || fail "projected workspace retained a seeded or placeholder tab"
[ "$(printf '%s' "$PROJECTED_PANES" | jq -r '.result.panes | length')" = 1 ] \
  || fail "projected workspace did not contain exactly one task pane"
printf '%s' "$PROJECTED_TABS" | jq -e --arg tab "$PROJECTED_TAB" \
  '.result.tabs[0].tab_id == $tab and .result.tabs[0].label == "fm-shape"' >/dev/null 2>&1 \
  || fail "projected workspace's only tab was not the normal fm-shape task tab"
printf '%s' "$PROJECTED_PANES" | jq -e --arg pane "$PROJECTED_PANE" \
  '.result.panes[0].pane_id == $pane' >/dev/null 2>&1 \
  || fail "projected workspace's only pane was not the exact recorded task pane"
NEIGHBOR_INFO=$(lab workspace get "$NEIGHBOR_WSID") || fail "neighbor disappeared during projected create"
[ "$(printf '%s' "$NEIGHBOR_INFO" | jq -r '.result.workspace.focused')" = true ] \
  || fail "projected --no-focus create stole focus from the neighboring workspace"
pass "real Herdr lab: projected create leaves one normal task pane, no placeholder, and does not steal focus"

[ "$OFF_WT" = "$ON_WT" ] || fail "Treehouse did not reuse the same fixture worktree, so byte comparison is inconclusive"
normalize_meta "$OFF_META" > "$TMP_ROOT/off.meta.normalized"
normalize_meta "$ON_META" > "$TMP_ROOT/on.meta.normalized"
cmp -s "$TMP_ROOT/off.meta.normalized" "$TMP_ROOT/on.meta.normalized" \
  || fail "metadata changed beyond Herdr container IDs between flag-off and projected paths"

teardown_task shape "$HOME_DIR" > "$TMP_ROOT/on-teardown.out" 2> "$TMP_ROOT/on-teardown.err" \
  || fail "projected teardown failed: $(cat "$TMP_ROOT/on-teardown.err")"
cmp -s "$TMP_ROOT/off-treehouse.log" "$TREEHOUSE_CALL_LOG" \
  || fail "Treehouse command sequence changed between flag-off and projected paths"
pass "real Herdr lab: Treehouse commands and metadata shape are byte-identical except for Herdr container IDs"
if lab workspace get "$PROJECTED_WSID" >/dev/null 2>&1; then
  fail "closing the exact projected task pane did not remove its last-tab workspace"
fi
lab pane get "$NEIGHBOR_PANE" >/dev/null 2>&1 \
  || fail "projected teardown affected the neighboring workspace"
[ ! -e "$JOURNAL" ] || fail "confirmed projected teardown did not retire its presentation journal"
pass "real Herdr lab: exact task-pane close removes only the last-tab projection workspace and leaves its neighbor untouched"

# A restart preserves the label and structural pane but removes the registered
# agent.
# The next spawn must leave that old projection untouched and use the flat
# home workspace.
spawn_task restart1 "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/restart-first.out" 2> "$TMP_ROOT/restart-first.err" \
  || fail "restart fixture's projected spawn failed: $(cat "$TMP_ROOT/restart-first.err")"
RESTART_META="$HOME_DIR/state/restart1.meta"
OLD_RESTART_WT=$(remember_meta_worktree "$RESTART_META")
OLD_RESTART_WSID=$(grep '^herdr_workspace_id=' "$RESTART_META" | cut -d= -f2-)
OLD_RESTART_PANE=$(grep '^herdr_pane_id=' "$RESTART_META" | cut -d= -f2-)
OLD_RESTART_LABEL=$(lab workspace get "$OLD_RESTART_WSID" | jq -r '.result.workspace.label')
PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not stop the isolated session for restart validation"
PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not reprovision the isolated session after restart"
lab pane get "$OLD_RESTART_PANE" >/dev/null 2>&1 \
  || fail "restart did not preserve the projected pane structurally"
if lab agent get "$OLD_RESTART_PANE" >/dev/null 2>&1; then
  fail "restart fixture unexpectedly retained a registered agent"
fi
spawn_task restart1 "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/restart-flat.out" 2> "$TMP_ROOT/restart-flat.err" \
  || fail "flat fallback after restart failed: $(cat "$TMP_ROOT/restart-flat.err")"
NEW_RESTART_WT=$(remember_meta_worktree "$RESTART_META")
NEW_RESTART_WSID=$(grep '^herdr_workspace_id=' "$RESTART_META" | cut -d= -f2-)
[ "$NEW_RESTART_WSID" != "$OLD_RESTART_WSID" ] || fail "restart fallback reused the quarantined projection workspace"
NEW_RESTART_LABEL=$(lab workspace get "$NEW_RESTART_WSID" | jq -r '.result.workspace.label')
[ "$NEW_RESTART_LABEL" = firstmate ] || fail "restart fallback did not use the normal flat home workspace"
[ "$(lab workspace get "$OLD_RESTART_WSID" | jq -r '.result.workspace.label')" = "$OLD_RESTART_LABEL" ] \
  || fail "restart fallback renamed or replaced the old projection workspace"
lab pane get "$OLD_RESTART_PANE" >/dev/null 2>&1 \
  || fail "restart fallback closed the old projected pane"
pass "real Herdr lab: restart preserves the token label as an agent-free husk that is left untouched while the task respawns flat"

teardown_task restart1 "$HOME_DIR" > "$TMP_ROOT/restart-teardown.out" 2> "$TMP_ROOT/restart-teardown.err" \
  || fail "flat restart teardown failed: $(cat "$TMP_ROOT/restart-teardown.err")"
[ -e "$HOME_DIR/state/restart1.herdr-presentation" ] \
  || fail "flat fallback teardown should retain the quarantined projection journal for manual cleanup"
"$REAL_TREEHOUSE" return --force "$OLD_RESTART_WT" >/dev/null 2>&1 || true
"$REAL_TREEHOUSE" return --force "$NEW_RESTART_WT" >/dev/null 2>&1 || true

# Missing, renamed, and duplicate tokens are read-only recovery diagnostics.
# The duplicate case allows flat fallback only when every matching pane is
# positively agent-free.
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"

MISSING_STATE="$TMP_ROOT/missing-state"; mkdir -p "$MISSING_STATE"
fm_backend_herdr_projection_journal_create "$MISSING_STATE" missing1 >/dev/null
MISSING_JOURNAL=$(fm_backend_herdr_projection_journal_path "$MISSING_STATE" missing1)
START=$(log_line_count)
fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" "$MISSING_JOURNAL" missing1 \
  || fail "missing token match should degrade to flat"
assert_no_projection_mutation_since "$START" "missing-token recovery"

RENAMED_STATE="$TMP_ROOT/renamed-state"; mkdir -p "$RENAMED_STATE"
RENAMED_TOKEN=$(fm_backend_herdr_projection_journal_create "$RENAMED_STATE" renamed1)
RENAMED_JOURNAL=$(fm_backend_herdr_projection_journal_path "$RENAMED_STATE" renamed1)
RENAMED_OUT=$(lab workspace create --cwd "$PROJECT_DIR" --label "firstmate/renamed1 · p:$RENAMED_TOKEN" --no-focus)
RENAMED_WSID=$(printf '%s' "$RENAMED_OUT" | jq -r '.result.workspace.workspace_id')
lab workspace rename "$RENAMED_WSID" renamed-without-token >/dev/null
START=$(log_line_count)
fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" "$RENAMED_JOURNAL" renamed1 \
  || fail "renamed token match should degrade to flat"
assert_no_projection_mutation_since "$START" "renamed-token recovery"
lab workspace get "$RENAMED_WSID" >/dev/null 2>&1 || fail "renamed-token recovery removed or adopted the old workspace"

DUP_STATE="$TMP_ROOT/duplicate-state"; mkdir -p "$DUP_STATE"
DUP_TOKEN=$(fm_backend_herdr_projection_journal_create "$DUP_STATE" duplicate1)
DUP_JOURNAL=$(fm_backend_herdr_projection_journal_path "$DUP_STATE" duplicate1)
DUP1=$(lab workspace create --cwd "$PROJECT_DIR" --label "firstmate/duplicate1 · p:$DUP_TOKEN" --no-focus)
DUP2=$(lab workspace create --cwd "$PROJECT_DIR" --label "copy/duplicate1 · p:$DUP_TOKEN" --no-focus)
DUP1_WSID=$(printf '%s' "$DUP1" | jq -r '.result.workspace.workspace_id')
DUP2_WSID=$(printf '%s' "$DUP2" | jq -r '.result.workspace.workspace_id')
DUP1_PANE=$(printf '%s' "$DUP1" | jq -r '.result.root_pane.pane_id')
START=$(log_line_count)
fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" "$DUP_JOURNAL" duplicate1 \
  || fail "agent-free duplicate token matches should permit flat fallback"
assert_no_projection_mutation_since "$START" "agent-free duplicate-token recovery"
lab workspace get "$DUP1_WSID" >/dev/null 2>&1 || fail "duplicate-token recovery removed the first quarantined workspace"
lab workspace get "$DUP2_WSID" >/dev/null 2>&1 || fail "duplicate-token recovery removed the second quarantined workspace"

lab pane report-agent "$DUP1_PANE" --source fm-projection-e2e --agent test-agent --state idle >/dev/null \
  || fail "could not register the duplicate-live-agent risk fixture"
START=$(log_line_count)
if fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" "$DUP_JOURNAL" duplicate1; then
  fail "a duplicate token match with a registered agent should refuse fallback"
fi
assert_no_projection_mutation_since "$START" "live duplicate-token recovery"
lab workspace get "$DUP1_WSID" >/dev/null 2>&1 || fail "live duplicate refusal removed the first workspace"
lab workspace get "$DUP2_WSID" >/dev/null 2>&1 || fail "live duplicate refusal removed the second workspace"
pass "real Herdr lab: missing, renamed, and duplicate tokens trigger zero destructive or adoptive calls, and live duplicate risk refuses launch"

STATUS_JSON=$(lab status --json)
HERDR_VERSION=$(printf '%s' "$STATUS_JSON" | jq -r '.client.version // "unknown"')
PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" \
  || fail "guarded Herdr lab teardown or default-session tripwire verification failed"
LAB_READY=0
pass "real Herdr lab validation completed on Herdr $HERDR_VERSION with the default-session tripwire intact"

cleanup_all
trap - EXIT
