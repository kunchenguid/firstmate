#!/usr/bin/env bash
# Real restored-shell E2E for home-local session-start Herdr projection cleanup.
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
production_process_proof() {
  FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1 PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    bash -c '. "$1"; fm_backend_herdr_pane_idle_shell_pid "$2" "$3" >/dev/null' \
      _ "$ROOT/bin/fm-herdr-session-cleanup.sh" "$HERDR_LAB_SESSION" "$PANE"
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
pass 'real named lab cleanup closes only the exact stale pane and preserves exact focus'

FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$ROOT/bin/fm-herdr-session-cleanup.sh" \
  || fail 'idempotent repeat failed'
[ "$(focus_snapshot)" = "$BEFORE_FOCUS" ] || fail 'idempotent repeat changed focus'
lab pane get "$(printf '%s' "$ANCHOR" | jq -r '.result.root_pane.pane_id')" >/dev/null \
  || fail 'anchor pane was touched by cleanup'
pass 'real named lab cleanup is idempotent and leaves the default fleet session to the teardown tripwire'

TERM_ID=terminal-worker-e2e
TERM_TOKEN=QrStUvWxYz0123456789Ab
TERM_TITLE="└ $TERM_ID · p:$TERM_TOKEN"
TERM_WORKSPACE=$(lab workspace create --cwd "$ROOT" --label "$TERM_TITLE" --no-focus) \
  || fail 'could not create the terminal-outcome workspace'
TERM_WS=$(printf '%s' "$TERM_WORKSPACE" | jq -r '.result.workspace.workspace_id')
TERM_TAB=$(printf '%s' "$TERM_WORKSPACE" | jq -r '.result.tab.tab_id')
TERM_PANE=$(printf '%s' "$TERM_WORKSPACE" | jq -r '.result.root_pane.pane_id')
[ -n "$TERM_WS" ] && [ -n "$TERM_TAB" ] && [ -n "$TERM_PANE" ] \
  || fail 'terminal-outcome workspace response omitted an exact endpoint id'
{
  printf 'version=2\n'
  printf 'task_id=%s\nprojection_id=%s\n' "$TERM_ID" "$TERM_TOKEN"
  printf 'home=%s\nsession=%s\nworkspace_id=%s\ntab_id=%s\npane_id=%s\n' \
    "$HOME_DIR" "$HERDR_LAB_SESSION" "$TERM_WS" "$TERM_TAB" "$TERM_PANE"
  printf 'parent_workspace_id=%s\nparent_label=captain-anchor\n' \
    "$(printf '%s' "$ANCHOR" | jq -r '.result.workspace.workspace_id')"
  printf 'workspace_label=%s\ntask_label=fm-%s\n' "$TERM_TITLE" "$TERM_ID"
} > "$HOME_DIR/state/$TERM_ID.herdr-presentation"
{
  printf 'window=%s:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\n' \
    "$HERDR_LAB_SESSION" "$TERM_PANE" "$TERM_ID" "$ROOT" "$ROOT"
  printf 'backend=herdr\nkind=ship\nherdr_session=%s\nherdr_workspace_id=%s\n' \
    "$HERDR_LAB_SESSION" "$TERM_WS"
  printf 'herdr_tab_id=%s\nherdr_pane_id=%s\n' "$TERM_TAB" "$TERM_PANE"
  printf 'pr=https://example.test/pull/terminal-worker-e2e\n'
} > "$HOME_DIR/state/$TERM_ID.meta"
printf 'done: terminal worker finished\n' > "$HOME_DIR/state/$TERM_ID.status"
PANE=$TERM_PANE
attempt=0
while [ "$attempt" -lt 50 ]; do
  if production_process_proof; then break; fi
  sleep 0.1
  attempt=$((attempt + 1))
done
[ "$attempt" -lt 50 ] || fail 'terminal-outcome pane did not converge to the idle-shell proof'
BEFORE_TERMINAL_FOCUS=$(focus_snapshot) || fail 'could not capture terminal pre-cleanup focus'
FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$ROOT/bin/fm-herdr-session-cleanup.sh" terminal "$TERM_ID" \
  || fail 'terminal-outcome cleanup command failed'
[ "$(focus_snapshot)" = "$BEFORE_TERMINAL_FOCUS" ] \
  || fail 'terminal-outcome cleanup changed the exact active focus'
if lab pane get "$TERM_PANE" >/dev/null 2>&1; then
  fail 'terminal-outcome cleanup left the exact worker pane open'
fi
[ -f "$HOME_DIR/state/$TERM_ID.meta" ] \
  || fail 'terminal-outcome cleanup removed the durable task metadata'
[ -f "$HOME_DIR/state/$TERM_ID.status" ] \
  || fail 'terminal-outcome cleanup removed the terminal status'
[ -f "$HOME_DIR/state/$TERM_ID.herdr-presentation" ] && fail \
  'terminal-outcome cleanup kept its retired presentation journal'
pass 'real named lab terminal done cleanup closes one exact worker pane and keeps durable records'

STATUS=$(lab status --json) || fail 'could not read final named-lab version evidence'
printf 'evidence: herdr=%s protocol=%s default-session-tripwire=armed\n' \
  "$(printf '%s' "$STATUS" | jq -r '.client.version')" \
  "$(printf '%s' "$STATUS" | jq -r '.server.protocol')"
