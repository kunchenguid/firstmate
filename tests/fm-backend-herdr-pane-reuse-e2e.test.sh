#!/usr/bin/env bash
# Real-Herdr regression: Herdr reissues a closed pane's id, so a task record
# that binds only <session>:<pane> can point at an unrelated live pane.
#
# Reproduction, in an isolated lab session: a task's workspace closes (its
# worker finished and the pane went away), the server restarts, and the next
# new workspace receives the same workspace id and therefore the same pane ids.
# An unrelated agent then runs in the reissued pane. Without the endpoint
# identity check, the finished task's record reads that agent as its own live
# agent (the identity-free pane classifier below still does), and cleanup,
# steering, and control would act on the stranger's pane.
#
# The record binds the pane's terminal_id (herdr_terminal_id=), which Herdr
# never reissues, so every consumer reads the reissued pane as this task's
# endpoint gone and leaves it untouched. A legacy record written before that
# field matches only while the pane works inside the task's own worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
fm_live_gate default-on FM_HERDR_PANE_REUSE_E2E herdr jq

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: live: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-herdr-pane-reuse-e2e)
FAKEBIN="$TMP_ROOT/fakebin"
PROJECT="$TMP_ROOT/project"
WT_OLD="$TMP_ROOT/wt-finished"
WT_NEW="$TMP_ROOT/wt-other"
mkdir -p "$FAKEBIN" "$PROJECT" "$WT_OLD" "$WT_NEW"
WT_OLD=$(cd "$WT_OLD" && pwd -P)
WT_NEW=$(cd "$WT_NEW" && pwd -P)

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-pane-reuse)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH

cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# Route every adapter call through the lab helper, which re-appends the lab
# session; any other session flag is refused.
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

# adapter <state-dir> <shell snippet> [args...]: run the real adapter against
# the lab, with <state-dir> as this home's task records.
adapter() {
  local state=$1 snippet=$2
  shift 2
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" FM_STATE_OVERRIDE="$state" bash -c '
    set -u
    root=$1 snippet=$2
    shift 2
    . "$root/bin/fm-backend.sh"
    fm_backend_source herdr || exit 97
    eval "$snippet"
  ' _ "$ROOT" "$snippet" "$@"
}

write_record() {  # <state-dir> <task-id> <workspace> <tab> <pane> <worktree> [terminal-id]
  local state=$1 id=$2 ws=$3 tab=$4 pane=$5 wt=$6 term=${7:-}
  mkdir -p "$state"
  {
    printf 'window=%s:%s\n' "$HERDR_LAB_SESSION" "$pane"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$PROJECT"
    printf 'harness=claude\nkind=ship\nbackend=herdr\n'
    printf 'herdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' \
      "$HERDR_LAB_SESSION" "$ws" "$tab" "$pane"
    [ -z "$term" ] || printf 'herdr_terminal_id=%s\n' "$term"
  } > "$state/$id.meta"
}

pane_present() { lab pane get "$1" >/dev/null 2>&1; }

# --- 1. a finished task's endpoint, then its workspace closes --------------
lab workspace create --cwd "$PROJECT" --label home --no-focus >/dev/null \
  || fail 'could not create the home workspace'
CREATE=$(lab workspace create --cwd "$WT_OLD" --label task --no-focus) \
  || fail 'could not create the task workspace'
WS_OLD=$(printf '%s' "$CREATE" | jq -er '.result.workspace.workspace_id') \
  || fail 'could not read the task workspace id'
TAB=$(lab tab create --workspace "$WS_OLD" --cwd "$WT_OLD" --label fm-finished --no-focus) \
  || fail 'could not create the task tab'
PANE=$(printf '%s' "$TAB" | jq -er '.result.root_pane.pane_id') || fail 'could not read the task pane id'
TAB_ID=$(printf '%s' "$TAB" | jq -er '.result.root_pane.tab_id') || fail 'could not read the task tab id'
TERM_OLD=$(printf '%s' "$TAB" | jq -er '.result.root_pane.terminal_id') || fail 'could not read the task terminal id'

STATE_BOUND="$TMP_ROOT/state-bound"
STATE_LEGACY="$TMP_ROOT/state-legacy"
write_record "$STATE_BOUND" finished "$WS_OLD" "$TAB_ID" "$PANE" "$WT_OLD" "$TERM_OLD"
write_record "$STATE_LEGACY" finished "$WS_OLD" "$TAB_ID" "$PANE" "$WT_OLD"
TARGET="$HERDR_LAB_SESSION:$PANE"

# shellcheck disable=SC2016 # Positional parameters expand in the adapter shell.
[ "$(adapter "$STATE_BOUND" 'fm_backend_herdr_endpoint_identity "$1"' "$TARGET")" = match ] \
  || fail 'the bound record did not match its own live pane'
# shellcheck disable=SC2016 # Positional parameters expand in the adapter shell.
[ "$(adapter "$STATE_LEGACY" 'fm_backend_herdr_endpoint_identity "$1"' "$TARGET")" = match ] \
  || fail 'the legacy record did not match its own pane working inside its worktree'
pass 'a task record matches its own live pane, bound or legacy'

lab workspace close "$WS_OLD" >/dev/null || fail 'could not close the finished task workspace'

# --- 2. restart, and Herdr reissues the ids -----------------------------------
env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
  || fail 'could not stop the lab session for the restart'
# shellcheck disable=SC2016 # Positional parameters expand in the inner bash -c.
env PATH="$HERDR_ORIGINAL_PATH" bash -c '
  . "$1/bin/fm-backend.sh"
  fm_backend_source herdr && fm_backend_herdr_server_ensure "$2"
' _ "$ROOT" "$HERDR_LAB_SESSION" || fail 'the lab session did not come back after the restart'

CREATE=$(lab workspace create --cwd "$WT_NEW" --label other --no-focus) \
  || fail 'could not create the unrelated workspace'
WS_NEW=$(printf '%s' "$CREATE" | jq -er '.result.workspace.workspace_id') || fail 'could not read the new workspace id'
TAB=$(lab tab create --workspace "$WS_NEW" --cwd "$WT_NEW" --label other-agent --no-focus) \
  || fail 'could not create the unrelated tab'
PANE_NEW=$(printf '%s' "$TAB" | jq -er '.result.root_pane.pane_id') || fail 'could not read the new pane id'
TERM_NEW=$(printf '%s' "$TAB" | jq -er '.result.root_pane.terminal_id') || fail 'could not read the new terminal id'
TAB_ID_NEW=$(printf '%s' "$TAB" | jq -er '.result.root_pane.tab_id') || fail 'could not read the new tab id'
[ "$WS_NEW" = "$WS_OLD" ] && [ "$PANE_NEW" = "$PANE" ] \
  || fail "repro: Herdr did not reissue the closed ids (workspace $WS_OLD->$WS_NEW, pane $PANE->$PANE_NEW); the premise of this regression changed"
[ "$TERM_NEW" != "$TERM_OLD" ] || fail 'repro: the reissued pane kept the old terminal id'
pass "repro: after a restart Herdr reissued pane $PANE to an unrelated terminal"

# An unrelated agent runs in the reissued pane: a harness-named foreground
# process plus a live registration.
lab pane run "$PANE" "bash -c 'exec -a claude sleep 600'" >/dev/null || fail 'could not start the unrelated agent'
for _ in $(seq 1 50); do
  lab pane process-info --pane "$PANE" 2>/dev/null \
    | jq -e '.result.process_info.foreground_processes[]? | select(.argv0 == "claude")' >/dev/null 2>&1 && break
  sleep 0.1
done
lab pane report-agent --source fm-pane-reuse-e2e --agent claude --state idle "$PANE" >/dev/null \
  || fail 'could not register the unrelated agent'
# shellcheck disable=SC2016 # Positional parameters expand in the adapter shell.
RAW=$(adapter "$STATE_BOUND" 'fm_backend_herdr_pane_agent_state "$1" "$2"' "$HERDR_LAB_SESSION" "$PANE")
[ "$RAW" = live ] || fail "repro: the identity-free classifier read '$RAW' for the reissued pane, want live"
pass 'repro: read by pane id alone, the finished task record names a live agent'

# --- 3. every consumer reads the reissued pane as the task's endpoint gone ----
# shellcheck disable=SC2016 # Positional parameters expand in the adapter shell.
for state in "$STATE_BOUND" "$STATE_LEGACY"; do
  label=${state##*/}
  identity=$(adapter "$state" 'fm_backend_herdr_endpoint_identity "$1"' "$TARGET")
  [ "$identity" = mismatch ] || fail "$label: identity read '$identity', want mismatch"
  verdict=$(adapter "$state" 'fm_backend_agent_state herdr "$1"' "$TARGET")
  [ "$verdict" = missing ] || fail "$label: liveness read '$verdict' for another agent's pane, want missing"
  adapter "$state" 'fm_backend_target_exists herdr "$1"' "$TARGET" \
    && fail "$label: the digest existence read reported the reissued pane as this task's endpoint"
  adapter "$state" 'fm_backend_capture herdr "$1" 5 >/dev/null' "$TARGET" \
    && fail "$label: a capture read the stranger's pane"
  verdict=$(adapter "$state" 'fm_backend_send_text_submit herdr "$1" "fm-pane-reuse-doorbell" 1 0.1 0.1' "$TARGET")
  [ "$verdict" = send-failed ] || fail "$label: a steer into the stranger's pane returned '$verdict', want send-failed"
  adapter "$state" 'fm_backend_send_key herdr "$1" C-c' "$TARGET" \
    && fail "$label: an interrupt key was sent to the stranger's pane"
  adapter "$state" 'fm_backend_kill herdr "$1"' "$TARGET" \
    || fail "$label: closing an already-gone endpoint should succeed without closing anything"
  pane_present "$PANE" || fail "$label: cleanup closed the stranger's pane"
  adapter "$state" '
    fm_backend_validate_task_endpoint "$FM_STATE_OVERRIDE/finished.meta" finished || exit 98
    fm_backend_herdr_parse_target "$1" || exit 98
    fm_backend_herdr_kill_serialized "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE"
    fm_backend_herdr_endpoint_confirmed_gone "$1"
  ' "$TARGET" || fail "$label: teardown's close did not treat the reissued pane as this task's endpoint gone"
  pane_present "$PANE" || fail "$label: teardown's close removed the stranger's pane"
done
lab pane read "$PANE" --source recent --lines 200 2>/dev/null | grep -q 'fm-pane-reuse-doorbell' \
  && fail "the steer text reached the stranger's pane"
pass 'liveness, existence, capture, steering, interrupt, and cleanup all treat the reissued pane as the finished task endpoint gone, and leave it untouched'

# --- 4. the pane's real owner still reads alive --------------------------------
STATE_OWNER="$TMP_ROOT/state-owner"
write_record "$STATE_OWNER" other "$WS_NEW" "$TAB_ID_NEW" "$PANE" "$WT_NEW" "$TERM_NEW"
# shellcheck disable=SC2016 # Positional parameters expand in the adapter shell.
verdict=$(adapter "$STATE_OWNER" 'fm_backend_agent_state herdr "$1"' "$TARGET")
[ "$verdict" = alive ] || fail "the reissued pane's own record read '$verdict', want alive"
STATE_OWNER_LEGACY="$TMP_ROOT/state-owner-legacy"
write_record "$STATE_OWNER_LEGACY" other "$WS_NEW" "$TAB_ID_NEW" "$PANE" "$WT_NEW"
# shellcheck disable=SC2016 # Positional parameters expand in the adapter shell.
verdict=$(adapter "$STATE_OWNER_LEGACY" 'fm_backend_agent_state herdr "$1"' "$TARGET")
[ "$verdict" = alive ] || fail "a legacy record working inside its own worktree read '$verdict', want alive"
pass 'the record that owns the pane, bound or legacy, still reads its agent alive'
