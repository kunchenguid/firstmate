#!/usr/bin/env bash
# Real-Herdr regression for the created-workspace leak.
# Cleanup used to close only its own task pane and rely on Herdr removing a
# workspace whose last tab went with it, so any task workspace that also held a
# pane firstmate does not own survived every teardown.
# Part A MEASURES that leak on the installed release: the production
# focus-preserving pane close removes the task pane and the workspace stays
# behind.
# Part B PROVES the fix on every release, so it builds its own subject rather
# than reusing Part A's outcome: the created-workspace cleanup removes the
# workspace itself, never the foreign pane, and never moves the captain's focus.
# Every structural verdict here comes from a positive present-or-absent read; an
# unreadable probe fails the run instead of passing as a removal.
# Part C covers the other reproduction case, a workspace holding only the task
# pane, where Herdr's own last-tab removal already applies and the cleanup must
# be a silent no-op rather than a second close.
# Part D proves the created-versus-adopted boundary against a live workspace:
# without the created proof nothing is closed at all.
# Every CLI operation is routed through one guarded named non-default lab, and
# lab teardown verifies that the default fleet session is byte-identical.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-ws-retire-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-ws-retire-l3)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH
SAMPLER_PID=
SAMPLER_STOP=
cleanup() {
  local status=$?
  if [ -n "$SAMPLER_STOP" ]; then
    : > "$SAMPLER_STOP"
  fi
  if [ -n "$SAMPLER_PID" ]; then
    wait "$SAMPLER_PID" 2>/dev/null || true
  fi
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
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
mkws() {  # <label> -> "<workspace_id> <tab_id> <pane_id>"
  lab workspace create --cwd "$ROOT" --label "$1" --no-focus \
    | jq -er '"\(.result.workspace.workspace_id) \(.result.tab.tab_id) \(.result.root_pane.pane_id)"'
}
# One extra tab firstmate does not own, standing in for any plugin, second
# plugin, or hand-added pane that keeps a workspace alive. Nothing below ever
# matches on its label.
mktab() {  # <workspace_id> <label> -> "<tab_id> <pane_id>"
  lab tab create --workspace "$1" --cwd "$ROOT" --label "$2" --no-focus \
    | jq -er '"\(.result.tab.tab_id) \(.result.root_pane.pane_id)"'
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
ws_order() { lab workspace list | jq -er '[.result.workspaces[].workspace_id] | join(",")'; }
# Positive tri-state presence for one exact workspace, mirroring the adapter's
# own fm_backend_herdr_workspace_presence_state. A failed or unparseable probe
# reads `unreadable`, never `absent`: treating it as absent would let a broken
# transport masquerade as a release that removed the workspace, and every
# structural verdict this guard draws would go quietly vacuous.
ws_state() {  # <workspace_id> -> present|absent|unreadable
  local list matches
  list=$(lab workspace list 2>/dev/null) || { printf 'unreadable'; return 0; }
  matches=$(printf '%s' "$list" | jq -r --arg workspace "$1" '
    select((.result.workspaces | type) == "array")
    | [.result.workspaces[] | select(.workspace_id == $workspace)] | length
  ' 2>/dev/null) || matches=
  case "$matches" in
    0) printf 'absent' ;;
    1) printf 'present' ;;
    *) printf 'unreadable' ;;
  esac
}
# The same tri-state for one exact pane, mirroring
# fm_backend_herdr_pane_presence_state's structured not-found contract.
pane_state() {  # <pane_id> -> present|absent|unreadable
  local out code
  out=$(lab pane get "$1" 2>&1) || true
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null) || code=
  if [ -n "$code" ]; then
    [ "$code" = pane_not_found ] && printf 'absent' || printf 'unreadable'
    return 0
  fi
  if printf '%s' "$out" | jq -e --arg pane "$1" '.result.pane.pane_id == $pane' >/dev/null 2>&1; then
    printf 'present'
  else
    printf 'unreadable'
  fi
}
# Wait for a POSITIVE absence confirmation. An unreadable probe is retried and
# then reported as itself, so it can never pass as a removal.
wait_ws_gone() {  # <workspace_id>
  local i=0 state=
  while [ "$i" -lt 80 ]; do
    state=$(ws_state "$1")
    [ "$state" != absent ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s' "$state"
  return 1
}
# The geometry every part shares: the anchor holds the captain's focus, the
# doomed workspace sits after it so no repositioning is ever in play, and a
# spacer sits immediately right of the doomed workspace so a release that lands
# focus on the removed workspace's neighbour cannot land on the anchor by
# coincidence.
assert_geometry() {  # <part> <doomed> <spacer> <anchor>
  local part=$1 doomed=$2 spacer=$3 anchor=$4 order neighbour
  order=$(ws_order) || fail "$part: could not read the workspace order"
  neighbour=$(printf '%s' "$order" | tr ',' '\n' | grep -A1 -Fx "$doomed" | tail -1)
  [ "$neighbour" = "$spacer" ] \
    || fail "$part needs the spacer immediately right of the doomed workspace, got '$neighbour'"
  [ "$neighbour" != "$anchor" ] \
    || fail "$part geometry is vacuous: the right neighbour of the doomed workspace is the anchor"
  printf '%s' "$order" | tr ',' '\n' | grep -v "^$doomed\$" | paste -sd, -
}
# The retiring task's own durable record, which is still on disk when cleanup
# runs. Cleanup must skip exactly this one and no other, or nothing would ever
# be retired.
retiring_state_dir() {  # <dir> <workspace_id> <pane_id> -> <state-dir>
  local state="$1/state"
  mkdir -p "$state"
  printf '%s\n' 'backend=herdr' "herdr_session=$HERDR_LAB_SESSION" \
    "herdr_workspace_id=$2" "herdr_pane_id=$3" 'herdr_workspace_created=1' \
    > "$state/task-retiring.meta"
  printf '%s\n' "$state"
}
SAMPLE_LOG=
OPERATION_ACTIVE=
start_focus_sampler() {  # <name>
  local ready="$TMP_ROOT/$1.ready"
  SAMPLE_LOG="$TMP_ROOT/$1.samples"
  OPERATION_ACTIVE="$TMP_ROOT/$1.active"
  SAMPLER_STOP="$TMP_ROOT/$1.stop"
  : > "$SAMPLE_LOG"
  (
    : > "$ready"
    while [ ! -e "$SAMPLER_STOP" ]; do
      if [ -e "$OPERATION_ACTIVE" ]; then
        if SAMPLE=$(focus_snapshot); then
          printf '%s\n' "$SAMPLE" >> "$SAMPLE_LOG"
        else
          printf '%s\n' UNREADABLE >> "$SAMPLE_LOG"
        fi
      fi
    done
  ) &
  SAMPLER_PID=$!
  local attempt=0
  while [ ! -e "$ready" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.01
    attempt=$((attempt + 1))
  done
  [ -e "$ready" ] || fail "the $1 focus sampler did not start"
  : > "$OPERATION_ACTIVE"
}
stop_focus_sampler() {
  rm -f "$OPERATION_ACTIVE"
  : > "$SAMPLER_STOP"
  wait "$SAMPLER_PID" 2>/dev/null || true
  SAMPLER_PID=
}
# Drive the production adapter with the lab shim in PATH and every call recorded,
# so what the fix did and did not close is evidence rather than inference.
adapter() {  # <call-log> <function> [args...]
  local log=$1; shift
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" FM_RETIRE_CALL_LOG="$log" bash -c '
    . "$1/bin/backends/herdr.sh"
    fm_backend_herdr_cli() {
      local session=$1
      shift
      printf "%s\n" "$*" >> "$FM_RETIRE_CALL_LOG"
      HERDR_SESSION="$session" herdr "$@" --session "$session"
    }
    function=$2
    shift 2
    "$function" "$@"
  ' _ "$ROOT" "$@" 2>&1
}

# LIVE_CLOSE records whether the retirement was actually driven to a real
# workspace close against this release, so a run that never exercised it cannot
# read identically to one that did.
LIVE_CLOSE=0

# --- Part A: the leak, live ------------------------------------------------
read -r A_ANCHOR_WS A_ANCHOR_TAB _ <<<"$(mkws retire-a-anchor)" || fail 'could not create the Part A anchor workspace'
read -r A_DOOMED_WS _ A_TASK_PANE <<<"$(mkws retire-a-doomed)" || fail 'could not create the Part A doomed workspace'
read -r A_SPACER_WS _ _ <<<"$(mkws retire-a-spacer)" || fail 'could not create the Part A spacer workspace'
read -r _ _ _ <<<"$(mkws retire-a-tail)" || fail 'could not create the Part A tail workspace'
read -r _ _ <<<"$(mktab "$A_DOOMED_WS" retire-a-plugin)" || fail 'could not create the Part A foreign tab'
lab tab focus "$A_ANCHOR_TAB" >/dev/null || fail 'could not focus the Part A anchor'
A_BEFORE=$(focus_snapshot) || fail 'could not capture the Part A pre-close focus'
[ "$A_BEFORE" = "$(printf '%s\t%s' "$A_ANCHOR_WS" "$A_ANCHOR_TAB")" ] \
  || fail 'Part A anchor focus does not match the intended workspace and tab'
assert_geometry 'Part A' "$A_DOOMED_WS" "$A_SPACER_WS" "$A_ANCHOR_WS" >/dev/null

A_CLOSE_LOG="$TMP_ROOT/close-a.log"
: > "$A_CLOSE_LOG"
A_OUT=$(adapter "$A_CLOSE_LOG" fm_backend_herdr_projection_close_pane_focus_preserving \
  "$HERDR_LAB_SESSION" "$A_TASK_PANE")
A_STATUS=$?
[ "$A_STATUS" -eq 0 ] || fail "the production task-pane close failed (status $A_STATUS): $A_OUT"
A_TASK_PANE_STATE=$(pane_state "$A_TASK_PANE")
[ "$A_TASK_PANE_STATE" = absent ] \
  || fail "Part A needs a confirmed-gone task pane to measure the leak, got '$A_TASK_PANE_STATE'"
LEAK_LIVE=0
case "$(ws_state "$A_DOOMED_WS")" in
  present)
    LEAK_LIVE=1
    pass 'leak reproduced: closing the task pane left the whole workspace behind because a foreign pane remained'
    ;;
  absent)
    pass 'leak note: this Herdr release removed the workspace despite the remaining foreign pane; Part B still proves the retirement'
    ;;
  *)
    fail 'Part A could not read the doomed workspace, so this release measurement is inconclusive rather than leak-free'
    ;;
esac

# --- Part B: the created-workspace cleanup ---------------------------------
#
# Part A above is the release MEASUREMENT of the leak. This part is the fix
# PROOF, and it must drive a real `workspace close` on every release rather than
# only on one where Part A's leak reproduced, so it builds its own subject from
# scratch instead of reusing whatever Part A happened to leave behind.
# The subject is the exact shape the intent names: a firstmate-created workspace
# holding a task pane plus one tab firstmate does not own. Only the task pane is
# closed, so the foreign tab keeps the workspace alive under Herdr's own
# last-tab rule and the retirement always has a live workspace to close.
read -r B_ANCHOR_WS B_ANCHOR_TAB _ <<<"$(mkws retire-b-anchor)" || fail 'could not create the Part B anchor workspace'
read -r B_DOOMED_WS _ B_TASK_PANE <<<"$(mkws retire-b-doomed)" || fail 'could not create the Part B doomed workspace'
read -r B_SPACER_WS _ _ <<<"$(mkws retire-b-spacer)" || fail 'could not create the Part B spacer workspace'
read -r _ _ _ <<<"$(mkws retire-b-tail)" || fail 'could not create the Part B tail workspace'
read -r _ B_FOREIGN_PANE <<<"$(mktab "$B_DOOMED_WS" retire-b-plugin)" || fail 'could not create the Part B foreign tab'
lab tab focus "$B_ANCHOR_TAB" >/dev/null || fail 'could not focus the Part B anchor'
B_BEFORE=$(focus_snapshot) || fail 'could not capture the Part B pre-cleanup focus'
[ "$B_BEFORE" = "$(printf '%s\t%s' "$B_ANCHOR_WS" "$B_ANCHOR_TAB")" ] \
  || fail 'Part B anchor focus does not match the intended workspace and tab'
B_SURVIVOR_ORDER=$(assert_geometry 'Part B' "$B_DOOMED_WS" "$B_SPACER_WS" "$B_ANCHOR_WS")

B_CLOSE_LOG="$TMP_ROOT/close-b.log"
: > "$B_CLOSE_LOG"
B_CLOSE_OUT=$(adapter "$B_CLOSE_LOG" fm_backend_herdr_projection_close_pane_focus_preserving \
  "$HERDR_LAB_SESSION" "$B_TASK_PANE")
B_CLOSE_STATUS=$?
[ "$B_CLOSE_STATUS" -eq 0 ] \
  || fail "the Part B task-pane close failed (status $B_CLOSE_STATUS): $B_CLOSE_OUT"
B_TASK_PANE_STATE=$(pane_state "$B_TASK_PANE")
[ "$B_TASK_PANE_STATE" = absent ] \
  || fail "Part B needs a confirmed-gone task pane before the retirement, got '$B_TASK_PANE_STATE'"
B_SUBJECT_STATE=$(ws_state "$B_DOOMED_WS")
[ "$B_SUBJECT_STATE" = present ] \
  || fail "Part B could not stand up a live retirement subject: a workspace still holding a foreign tab read '$B_SUBJECT_STATE' after only its task pane was closed, so this run would prove nothing about the workspace close"

B_STATE=$(retiring_state_dir "$TMP_ROOT/b" "$B_DOOMED_WS" "$B_TASK_PANE")
B_RETIRE_LOG="$TMP_ROOT/retire-b.log"
: > "$B_RETIRE_LOG"
start_focus_sampler retire-b
B_OUT=$(adapter "$B_RETIRE_LOG" fm_backend_herdr_workspace_retire_created \
  "$HERDR_LAB_SESSION" "$B_DOOMED_WS" created "$B_STATE" task-retiring)
B_STATUS=$?
stop_focus_sampler
[ "$B_STATUS" -eq 0 ] || fail "the created-workspace cleanup failed (status $B_STATUS): $B_OUT"
B_GONE_STATE=$(wait_ws_gone "$B_DOOMED_WS") \
  || fail "the created-workspace cleanup left the workspace behind (state: $B_GONE_STATE)"
LIVE_CLOSE=1
B_FOREIGN_STATE=$(pane_state "$B_FOREIGN_PANE")
[ "$B_FOREIGN_STATE" = absent ] \
  || fail "the created-workspace cleanup removed the workspace but its foreign pane read '$B_FOREIGN_STATE'"
grep -q '^workspace close' "$B_RETIRE_LOG" \
  || fail 'the created-workspace cleanup removed the workspace without closing it explicitly'
grep -q '^pane close' "$B_RETIRE_LOG" \
  && fail 'the cleanup closed a pane firstmate does not own to force the last-tab behaviour'
grep -q '^tab close' "$B_RETIRE_LOG" \
  && fail 'the cleanup closed a tab firstmate does not own to force the last-tab behaviour'
[ "$(ws_order)" = "$B_SURVIVOR_ORDER" ] \
  || fail "the cleanup left a lasting workspace order change ($B_SURVIVOR_ORDER -> $(ws_order))"
B_AFTER=$(focus_snapshot) || fail 'could not capture the Part B post-cleanup focus'
[ "$B_AFTER" = "$B_BEFORE" ] \
  || fail "the cleanup changed the exact focused workspace or tab ($B_BEFORE -> $B_AFTER)"
[ -s "$SAMPLE_LOG" ] || fail 'the Part B sampler captured no focus sample during the cleanup'
B_WRONG=$(grep -Fvxc -- "$B_BEFORE" "$SAMPLE_LOG" || true)
if [ "$B_WRONG" -eq 0 ]; then
  pass 'cleanup: the surviving created workspace was closed with exact focus preserved in every sample'
else
  # A release whose explicit close moves focus off a non-focused workspace is
  # exactly what the exact-tab restore backstop exists for. The window is
  # accepted only as a bounded one that the restore actually closed.
  grep -q '^tab focus' "$B_RETIRE_LOG" \
    || fail "the cleanup exposed $B_WRONG wrong-focus samples and never restored the exact prior tab"
  pass "cleanup: a bounded wrong-focus window of $B_WRONG samples was fully restored to the anchor"
fi

# --- Part C: the workspace that empties with its own task pane -------------
read -r C_ANCHOR_WS C_ANCHOR_TAB _ <<<"$(mkws retire-c-anchor)" || fail 'could not create the Part C anchor workspace'
read -r C_DOOMED_WS _ C_TASK_PANE <<<"$(mkws retire-c-doomed)" || fail 'could not create the Part C doomed workspace'
read -r C_SPACER_WS _ _ <<<"$(mkws retire-c-spacer)" || fail 'could not create the Part C spacer workspace'
read -r _ _ _ <<<"$(mkws retire-c-tail)" || fail 'could not create the Part C tail workspace'
lab tab focus "$C_ANCHOR_TAB" >/dev/null || fail 'could not focus the Part C anchor'
C_BEFORE=$(focus_snapshot) || fail 'could not capture the Part C pre-close focus'
C_SURVIVOR_ORDER=$(assert_geometry 'Part C' "$C_DOOMED_WS" "$C_SPACER_WS" "$C_ANCHOR_WS")

C_CLOSE_LOG="$TMP_ROOT/close-c.log"
: > "$C_CLOSE_LOG"
C_OUT=$(adapter "$C_CLOSE_LOG" fm_backend_herdr_projection_close_pane_focus_preserving \
  "$HERDR_LAB_SESSION" "$C_TASK_PANE")
C_STATUS=$?
[ "$C_STATUS" -eq 0 ] || fail "the production task-pane close failed (status $C_STATUS): $C_OUT"
C_GONE_STATE=$(wait_ws_gone "$C_DOOMED_WS") \
  || fail "a workspace holding only the task pane survived that pane going away (state: $C_GONE_STATE)"

C_STATE=$(retiring_state_dir "$TMP_ROOT/c" "$C_DOOMED_WS" "$C_TASK_PANE")
C_RETIRE_LOG="$TMP_ROOT/retire-c.log"
: > "$C_RETIRE_LOG"
C_RETIRE_OUT=$(adapter "$C_RETIRE_LOG" fm_backend_herdr_workspace_retire_created \
  "$HERDR_LAB_SESSION" "$C_DOOMED_WS" created "$C_STATE" task-retiring)
C_RETIRE_STATUS=$?
[ "$C_RETIRE_STATUS" -eq 0 ] \
  || fail "cleanup of an already-absent workspace reported failure (status $C_RETIRE_STATUS): $C_RETIRE_OUT"
[ -z "$C_RETIRE_OUT" ] \
  || fail "cleanup of an already-absent workspace was not silent: $C_RETIRE_OUT"
grep -q '^workspace close' "$C_RETIRE_LOG" \
  && fail 'cleanup sent a close for a workspace that was already gone'
[ "$(ws_order)" = "$C_SURVIVOR_ORDER" ] \
  || fail "the lone-task-pane case left a lasting workspace order change ($C_SURVIVOR_ORDER -> $(ws_order))"
C_AFTER=$(focus_snapshot) || fail 'could not capture the Part C post-cleanup focus'
[ "$C_AFTER" = "$C_BEFORE" ] \
  || fail "the lone-task-pane case changed the exact focused workspace or tab ($C_BEFORE -> $C_AFTER)"
pass 'lone task pane: the workspace goes with it and cleanup stays a silent no-op'

# --- Part D: no created proof, no close ------------------------------------
read -r D_ANCHOR_WS D_ANCHOR_TAB _ <<<"$(mkws retire-d-anchor)" || fail 'could not create the Part D anchor workspace'
read -r D_ADOPTED_WS _ D_TASK_PANE <<<"$(mkws retire-d-adopted)" || fail 'could not create the Part D adopted workspace'
read -r D_SPACER_WS _ _ <<<"$(mkws retire-d-spacer)" || fail 'could not create the Part D spacer workspace'
read -r _ D_FOREIGN_PANE <<<"$(mktab "$D_ADOPTED_WS" retire-d-plugin)" || fail 'could not create the Part D foreign tab'
lab tab focus "$D_ANCHOR_TAB" >/dev/null || fail 'could not focus the Part D anchor'
D_BEFORE=$(focus_snapshot) || fail 'could not capture the Part D pre-cleanup focus'
assert_geometry 'Part D' "$D_ADOPTED_WS" "$D_SPACER_WS" "$D_ANCHOR_WS" >/dev/null
D_STATE=$(retiring_state_dir "$TMP_ROOT/d" "$D_ADOPTED_WS" "$D_TASK_PANE")
D_RETIRE_LOG="$TMP_ROOT/retire-d.log"
: > "$D_RETIRE_LOG"
D_OUT=$(adapter "$D_RETIRE_LOG" fm_backend_herdr_workspace_retire_created \
  "$HERDR_LAB_SESSION" "$D_ADOPTED_WS" adopted "$D_STATE" task-retiring)
D_STATUS=$?
[ "$D_STATUS" -ne 0 ] \
  || fail "cleanup accepted a workspace with no firstmate-created proof: $D_OUT"
D_WS_STATE=$(ws_state "$D_ADOPTED_WS")
[ "$D_WS_STATE" = present ] \
  || fail "a workspace the captain owns must still be positively present, got '$D_WS_STATE'"
D_FOREIGN_STATE=$(pane_state "$D_FOREIGN_PANE")
[ "$D_FOREIGN_STATE" = present ] \
  || fail "a foreign pane in a workspace the captain owns must still be positively present, got '$D_FOREIGN_STATE'"
[ ! -s "$D_RETIRE_LOG" ] \
  || fail "cleanup without the created proof still talked to Herdr: $(cat "$D_RETIRE_LOG")"
D_AFTER=$(focus_snapshot) || fail 'could not capture the Part D post-cleanup focus'
[ "$D_AFTER" = "$D_BEFORE" ] \
  || fail "refusing to clean up an adopted workspace still moved focus ($D_BEFORE -> $D_AFTER)"
pass 'adopted workspace: cleanup refuses before any Herdr call and leaves it exactly as it was'

STATUS=$(lab status --json) || fail 'could not read final named-lab version evidence'
printf 'evidence: herdr=%s protocol=%s leak_live=%s live_close=%s default-session-tripwire=armed\n' \
  "$(printf '%s' "$STATUS" | jq -r '.client.version')" \
  "$(printf '%s' "$STATUS" | jq -r '.client.protocol')" \
  "$LEAK_LIVE" "$LIVE_CLOSE"
