#!/usr/bin/env bash
# Real restored-shell E2E for session-start Herdr leftover task-workspace cleanup.
# It covers a journal-correlated leftover, an unjournaled leftover, and the
# foreign, claimed, busy, and captain workspaces the cleanup must leave alone.
# Every CLI operation is routed through one guarded named non-default lab, and
# lab teardown verifies that the default fleet session is byte-identical.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-session-cleanup-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config"
touch "$HOME_DIR/config/herdr-presentation-spaces"
printf '%s\n' herdr > "$HOME_DIR/config/backend"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-session-start-stale-projection-cleanup-r1)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# Keep the lab helper as the only CLI transport. Production adapter calls have
# already appended the exact session; this shim strips that pair, refuses every
# other caller-supplied session, and delegates the command to helper run.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
production_process_proof() {  # [pane]
  FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1 PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    bash -c '. "$1"; fm_backend_herdr_pane_idle_shell_pid "$2" "$3" >/dev/null' \
      _ "$ROOT/bin/fm-herdr-session-cleanup.sh" "$HERDR_LAB_SESSION" "${1:-$PANE}"
}
await_idle_shell() {  # <pane>
  local attempt=0
  while [ "$attempt" -lt 50 ]; do
    production_process_proof "$1" && return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}
make_workspace() {  # <label> [cwd]; prints "<workspace-id> <root-pane-id>"
  local out
  out=$(lab workspace create --cwd "${2:-$ROOT}" --label "$1" --no-focus) || return 1
  printf '%s %s' "$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id')" \
    "$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')"
}
focus_snapshot() {
  local list workspace tab tabs
  list=$(lab workspace list) || return 1
  workspace=$(printf '%s' "$list" | jq -er '[.result.workspaces[] | select(.focused == true)] | select(length == 1) | .[0].workspace_id') || return 1
  tab=$(printf '%s' "$list" | jq -er --arg workspace "$workspace" '[.result.workspaces[] | select(.workspace_id == $workspace)] | select(length == 1) | .[0].active_tab_id') || return 1
  tabs=$(lab tab list --workspace "$workspace") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '([.result.tabs[] | select(.focused == true)] | length) == 1 and ([.result.tabs[] | select(.focused == true)][0].tab_id == $tab)' >/dev/null || return 1
  printf '%s\t%s' "$workspace" "$tab"
}

ANCHOR=$(lab workspace create --cwd "$ROOT" --label captain-anchor --focus) || fail 'could not create focus anchor'
ANCHOR_TAB=$(printf '%s' "$ANCHOR" | jq -r '.result.tab.tab_id')
TOKEN=AbCdEfGhIjKlMnOpQrStUv
ID=restored-idle-shell
TITLE="└ $ID · p:$TOKEN"
CANDIDATE=$(lab workspace create --cwd "$ROOT" --label "$TITLE" --no-focus) || fail 'could not create projected child fixture'
WS=$(printf '%s' "$CANDIDATE" | jq -r '.result.workspace.workspace_id')
PANE=$(printf '%s' "$CANDIDATE" | jq -r '.result.root_pane.pane_id')
{
  printf 'version=1\n'
  printf 'task_id=%s\n' "$ID"
  printf 'projection_id=%s\n' "$TOKEN"
} > "$HOME_DIR/state/$ID.herdr-presentation"
# An unjournaled leftover: its task and journal were already cleaned up. Its
# cwd sits inside this home, which is the ownership proof the path requires.
mkdir -p "$HOME_DIR/projects/lost"
read -r LOST_WS LOST_PANE <<EOF
$(make_workspace "└ lost-journal · p:LoStJoUrNaLlEfToVeR001" "$HOME_DIR/projects/lost")
EOF
[ -n "$LOST_WS" ] && [ -n "$LOST_PANE" ] || fail 'could not create unjournaled leftover fixture'
# An unjournaled leftover whose cwd is outside every local home, as another
# Firstmate home sharing the session would leave it.
mkdir -p "$TMP_ROOT/foreign-home/work"
read -r FOREIGN_WS FOREIGN_PANE <<EOF
$(make_workspace "└ foreign · p:FoReIgNlEfToVeR0000001" "$TMP_ROOT/foreign-home/work")
EOF
[ -n "$FOREIGN_WS" ] && [ -n "$FOREIGN_PANE" ] || fail 'could not create foreign leftover fixture'
# A leftover another task record still names.
read -r CLAIMED_WS CLAIMED_PANE <<EOF
$(make_workspace "└ claimed · p:ClAiMeDlEfToVeR0000001")
EOF
[ -n "$CLAIMED_WS" ] && [ -n "$CLAIMED_PANE" ] || fail 'could not create claimed leftover fixture'
printf 'backend=herdr\nherdr_workspace_id=%s\n' "$CLAIMED_WS" > "$HOME_DIR/state/claimant.meta"
# A task-grammar workspace whose pane runs a foreground command.
read -r BUSY_WS BUSY_PANE <<EOF
$(make_workspace "└ busy · p:BuSyLeFtOvEr0000000001")
EOF
[ -n "$BUSY_WS" ] && [ -n "$BUSY_PANE" ] || fail 'could not create busy leftover fixture'
# A captain workspace outside the task grammar holding the same idle shell shape.
read -r CAPTAIN_WS CAPTAIN_PANE <<EOF
$(make_workspace "captain-scratch")
EOF
[ -n "$CAPTAIN_WS" ] && [ -n "$CAPTAIN_PANE" ] || fail 'could not create captain workspace fixture'

"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail 'could not stop named lab for restored-shell reproduction'
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not restore named lab layout'
lab tab focus "$ANCHOR_TAB" >/dev/null || fail 'could not restore the anchor focus after lab restart'
BEFORE_FOCUS=$(focus_snapshot) || fail 'could not capture exact pre-cleanup focus'
[ "$BEFORE_FOCUS" = "$(printf '%s\t%s' "$(printf '%s' "$ANCHOR" | jq -r '.result.workspace.workspace_id')" "$ANCHOR_TAB")" ] \
  || fail 'anchor focus does not match the exact intended workspace and tab'

WORKSPACES=$(lab workspace list) || fail 'could not inspect restored workspaces'
TABS=$(lab tab list --workspace "$WS") || fail 'could not inspect restored tabs'
PANES=$(lab pane list --workspace "$WS") || fail 'could not inspect restored panes'
[ "$(printf '%s' "$WORKSPACES" | jq --arg title "$TITLE" '[.result.workspaces[] | select(.label == $title)] | length')" = 1 ] \
  || fail 'restored projected title is not unique'
[ "$(printf '%s' "$TABS" | jq '.result.tabs | length')" = 1 ] || fail 'restored child is not one tab'
[ "$(printf '%s' "$PANES" | jq '.result.panes | length')" = 1 ] || fail 'restored child is not one pane'
if lab agent get "$PANE" >/dev/null 2>&1; then
  fail 'restored child unexpectedly retained a registered agent'
fi
attempt=0
while [ "$attempt" -lt 50 ]; do
  if production_process_proof; then
    break
  fi
  sleep 0.1
  attempt=$((attempt + 1))
done
[ "$attempt" -lt 50 ] || fail 'restored child did not converge to the exact childless idle-shell process-group shape'
for fixture_pane in "$LOST_PANE" "$FOREIGN_PANE" "$CLAIMED_PANE" "$CAPTAIN_PANE" "$BUSY_PANE"; do
  lab pane get "$fixture_pane" >/dev/null || fail "restored fixture pane $fixture_pane is missing after the lab restart"
  await_idle_shell "$fixture_pane" || fail "restored fixture pane $fixture_pane did not converge to an idle shell"
done
lab pane run "$BUSY_PANE" 'sleep 600' >/dev/null || fail 'could not start the busy fixture command'
attempt=0
while [ "$attempt" -lt 50 ] && production_process_proof "$BUSY_PANE"; do
  sleep 0.1
  attempt=$((attempt + 1))
done
[ "$attempt" -lt 50 ] || fail 'busy fixture pane still reads as an idle shell'
pass 'real named lab reproduced the exact restored one-tab one-pane childless no-agent shell shape'

FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$ROOT/bin/fm-herdr-session-cleanup.sh" \
  || fail 'session-start cleanup command failed'
AFTER_FOCUS=$(focus_snapshot) || fail 'could not capture exact post-cleanup focus'
[ "$AFTER_FOCUS" = "$BEFORE_FOCUS" ] || fail 'exact workspace/tab focus changed during cleanup'
if lab pane get "$PANE" >/dev/null 2>&1; then
  fail 'exact stale pane survived cleanup'
fi
if lab workspace get "$WS" >/dev/null 2>&1; then
  fail 'last-pane side effect did not remove the stale projected child workspace'
fi
[ ! -e "$HOME_DIR/state/$ID.herdr-presentation" ] || fail 'matching journal survived confirmed exact pane closure'
if lab workspace get "$LOST_WS" >/dev/null 2>&1; then
  fail 'unjournaled restored leftover survived cleanup'
fi
lab workspace get "$FOREIGN_WS" >/dev/null 2>&1 || fail 'cleanup closed a leftover whose cwd is outside every local home'
lab pane get "$FOREIGN_PANE" >/dev/null 2>&1 || fail 'cleanup closed the foreign leftover pane'
lab workspace get "$CLAIMED_WS" >/dev/null 2>&1 || fail 'cleanup closed a leftover another task record names'
lab pane get "$CLAIMED_PANE" >/dev/null 2>&1 || fail 'cleanup closed the claimed leftover pane'
lab workspace get "$BUSY_WS" >/dev/null 2>&1 || fail 'cleanup closed a workspace running a foreground command'
lab pane get "$BUSY_PANE" >/dev/null 2>&1 || fail 'cleanup closed the busy pane'
lab workspace get "$CAPTAIN_WS" >/dev/null 2>&1 || fail 'cleanup closed a captain workspace outside the task grammar'
[ -e "$HOME_DIR/state/claimant.meta" ] || fail 'cleanup touched a task record'
pass 'real named lab cleanup closes journal-correlated and owned unjournaled leftovers, leaves foreign, claimed, busy, and captain workspaces, and preserves exact focus'

FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$ROOT/bin/fm-herdr-session-cleanup.sh" \
  || fail 'idempotent repeat failed'
[ "$(focus_snapshot)" = "$BEFORE_FOCUS" ] || fail 'idempotent repeat changed focus'
lab pane get "$(printf '%s' "$ANCHOR" | jq -r '.result.root_pane.pane_id')" >/dev/null \
  || fail 'anchor pane was touched by cleanup'
STATUS=$(lab status --json) || fail 'could not read final named-lab version evidence'
pass 'real named lab cleanup is idempotent and leaves the default fleet session to the teardown tripwire'
printf 'evidence: herdr=%s protocol=%s default-session-tripwire=armed\n' \
  "$(printf '%s' "$STATUS" | jq -r '.client.version')" \
  "$(printf '%s' "$STATUS" | jq -r '.server.protocol')"
