#!/usr/bin/env bash
# Kiro CLI lifecycle-hook adapter shared by every Firstmate Kiro session.
#
# V3 registers this tracked script from task-specific project hooks under
# .kiro/hooks/; the primary uses the tracked project hook in this repository.
# Explicit V2 fallback agents register the same script through legacy embedded
# hooks. Kiro waits for each command hook (verified on kiro-cli 2.22.1).
#
# Worker/scout lifecycle, generation-bound to the current task incarnation:
#   UserPromptSubmit  -> busy kiro-hook
#   PreToolUse        -> native progress marker
#   PostToolUse       -> native progress marker
#   Stop              -> idle kiro-hook plus the guarded turn-ended notification
#
# The launch supplies FM_KIRO_TASK_ID, FM_KIRO_STATE, and FM_KIRO_BUSY_GEN.
# The exact generation is inherited by the Kiro process and therefore cannot be
# replaced underneath a late hook from an older incarnation; fm-busy-event.sh
# rejects it after a relaunch arms a new generation. The isolated-home pointer
# and per-KIRO_HOME token registry independently bind the hook to this task
# before any state mutation; the workspace pointer is migration-only.
#
# Primary/secondmate Stop handling retains the existing best-effort watcher
# re-arm after the task binding fails primary scope. SessionStart and
# UserPromptSubmit are registered for the primary too; their context-delivery
# behavior is added by the primary wake owner, not by the busy-state branch.
#
# Usage: fm-kiro-turnend-hook.sh [<turn-end-registry-dir>]
#   The registry defaults to $KIRO_HOME/agents/fm-turn-end.d.
#
# Every path exits 0 and stays quiet unless a primary context hook deliberately
# writes context. A lifecycle writer refusal must never break Kiro's own turn.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"

# Isolated live-test probe: records arrival before payload parsing, scope checks,
# lock work, or endpoint publication. Only explicitly selected FM/KIRO/tmux
# fields are retained so credentials and unrelated process environment never
# enter the artifact.
if [ -n "${FM_KIRO_HOOK_PROBE_FILE:-}" ]; then
  {
    printf 'at=%s pid=%s ppid=%s pwd=%s\n' "$(date +%s)" "$$" "$PPID" "$PWD"
    env | LC_ALL=C grep -E '^(FM_(HOME|ROOT_OVERRIDE|STATE_OVERRIDE|KIRO_[A-Z0-9_]+)|KIRO_(HOME|DATA_DIR|CHAT_LOG_FILE|SESSION_ID|VERSION|CLI_ACP_CLIENT_NAME)|HOME|PWD|TMUX|TMUX_PANE|HERDR_ENV|HERDR_SESSION|HERDR_PANE_ID)=' \
      | LC_ALL=C sort
    printf '%s\n' --
  } >> "$FM_KIRO_HOOK_PROBE_FILE" 2>/dev/null || true
fi

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
EVENT=$(printf '%s' "$PAYLOAD" | awk '
  BEGIN { RS = "\"" }
  seen == 2 { print; exit }
  seen == 1 && $0 ~ /^[[:space:]]*:[[:space:]]*$/ { seen = 2; next }
  seen == 1 { seen = 0 }
  $0 == "hook_event_name" { seen = 1 }
')
case "$EVENT" in
  agentSpawn|SessionStart) EVENT_KIND='session-start' ;;
  userPromptSubmit|UserPromptSubmit) EVENT_KIND=user-prompt-submit ;;
  preToolUse|PreToolUse) EVENT_KIND=pre-tool-use ;;
  postToolUse|PostToolUse) EVENT_KIND=post-tool-use ;;
  stop|agentStop|Stop|SessionEnd) EVENT_KIND=stop ;;
  *) exit 0 ;;
esac

# The tracked primary hook carries an explicit marker. A Firstmate worker
# worktree inherits the tracked .kiro/hooks file from the repository, but the
# shared primary-scope predicate makes that inherited invocation inert; its
# task-specific generated hook (without this marker) owns worker lifecycle.
if [ "${FM_KIRO_PRIMARY_HOOK:-0}" = 1 ]; then
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
  case "$EVENT_KIND" in
    session-start)
      DIGEST=$("$SCRIPT_DIR/fm-sessionstart-run.sh" --source startup 2>&1 || true)
      # shellcheck source=bin/fm-primary-endpoint-lib.sh
      . "$SCRIPT_DIR/fm-primary-endpoint-lib.sh"
      if fm_primary_endpoint_publish "$STATE" "$FM_ROOT" "$FM_HOME"; then
        DIGEST="${DIGEST}${DIGEST:+$'\n'}KIRO_PRIMARY_ENDPOINT: structural wake doorbell published; the background watcher rings this pane for every actionable wake, so keep one cycle armed with bin/fm-watch-arm.sh and do not run foreground checkpoints."
      else
        DIGEST="${DIGEST}${DIGEST:+$'\n'}KIRO_PRIMARY_ENDPOINT: structural wake doorbell unavailable ($FM_PRIMARY_ENDPOINT_ERROR); use the foreground checkpoint fallback."
      fi
      [ -z "$DIGEST" ] || printf '%s\n' "$DIGEST"
      exit 0
      ;;
    user-prompt-submit)
      # The queue remains durable until the model runs the exact
      # WAKE_ACK_REQUIRED command this drain prints after handling its context.
      [ -s "$STATE/.wake-queue" ] || exit 0
      # shellcheck source=bin/fm-session-lock-lib.sh
      . "$SCRIPT_DIR/fm-session-lock-lib.sh"
      fm_session_lock_owned_by_self "$STATE" || exit 0
      "$SCRIPT_DIR/fm-wake-drain.sh" 2>&1 || true
      exit 0
      ;;
    pre-tool-use|post-tool-use)
      exit 0
      ;;
    stop)
      # Continue to the shared primary re-arm block below, but never run the
      # task-bound semantic writer from this static hook invocation.
      ;;
  esac
fi

KIRO_TASK_TURNEND=
KIRO_TASK_STATE=
KIRO_TASK_ID=
kiro_task_binding() {  # [registry-dir]
  local auth_dir=${1-} workspace pointer first token auth target base id state
  auth_dir=${auth_dir:-${KIRO_HOME:-}/agents/fm-turn-end.d}
  [ -n "$auth_dir" ] && [ -d "$auth_dir" ] && [ ! -L "$auth_dir" ] || return 1
  workspace=${KIRO_WORKSPACE_ROOT:-$PWD}
  [ -n "$workspace" ] || return 1
  pointer=${FM_KIRO_TURNEND_POINTER:-$workspace/.fm-kiro-turnend}
  [ -f "$pointer" ] && [ ! -L "$pointer" ] || return 1
  first=
  IFS= read -r -n 256 first < "$pointer" 2>/dev/null || [ -n "$first" ] || return 1
  case "$first" in token=*) token=${first#token=} ;; *) return 1 ;; esac
  case "$token" in fm.????????????) : ;; *) return 1 ;; esac
  case "$token" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  auth="$auth_dir/$token"
  [ -f "$auth" ] && [ ! -L "$auth" ] || return 1
  IFS= read -r target < "$auth" 2>/dev/null || return 1
  case "$target" in /*.turn-ended) : ;; *) return 1 ;; esac
  state=${target%/*}
  base=${target##*/}
  id=${base%.turn-ended}
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -z "${FM_KIRO_TASK_ID:-}" ] || [ "$id" = "$FM_KIRO_TASK_ID" ] || return 1
  [ -z "${FM_KIRO_STATE:-}" ] || [ "$state" = "$FM_KIRO_STATE" ] || return 1
  KIRO_TASK_TURNEND=$target
  KIRO_TASK_STATE=$state
  KIRO_TASK_ID=$id
  return 0
}

KIRO_TASK_BOUND=0
if [ "${FM_KIRO_PRIMARY_HOOK:-0}" != 1 ] && kiro_task_binding "${1-}"; then
  KIRO_TASK_BOUND=1
fi

kiro_busy_apply() {  # <state> <event>
  [ "$KIRO_TASK_BOUND" = 1 ] || return 0
  [ -n "${FM_KIRO_BUSY_GEN:-}" ] || return 0
  "$SCRIPT_DIR/fm-busy-event.sh" apply "$KIRO_TASK_STATE" "$KIRO_TASK_ID" "$1" \
    --gen "$FM_KIRO_BUSY_GEN" --source kiro-hook --event "$2" \
    >/dev/null 2>&1 || true
}

kiro_busy_progress() {
  [ "$KIRO_TASK_BOUND" = 1 ] || return 0
  [ -n "${FM_KIRO_BUSY_GEN:-}" ] || return 0
  "$SCRIPT_DIR/fm-busy-event.sh" progress "$KIRO_TASK_STATE" "$KIRO_TASK_ID" \
    --gen "$FM_KIRO_BUSY_GEN" >/dev/null 2>&1 || true
}

case "$EVENT_KIND" in
  user-prompt-submit)
    kiro_busy_apply busy user-prompt-submit
    exit 0
    ;;
  pre-tool-use|post-tool-use)
    kiro_busy_progress
    exit 0
    ;;
  session-start)
    exit 0
    ;;
  stop)
    if [ "$KIRO_TASK_BOUND" = 1 ]; then
      touch "$KIRO_TASK_TURNEND" 2>/dev/null || true
      kiro_busy_apply idle stop
    fi
    ;;
esac

# Primary/secondmate Stop re-arm backstop. A linked worker/scout worktree fails
# the shared primary-scope predicate after making its task-bound updates above.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

[ -e "$STATE/.afk" ] && exit 0
fm_session_lock_owned_by_self "$STATE" || exit 0
fm_supervision_needed "$STATE" "$GRACE" || exit 0
fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" && exit 0

if command -v setsid >/dev/null 2>&1; then
  setsid "$SCRIPT_DIR/fm-watch-arm.sh" </dev/null >/dev/null 2>&1 || true
fi

exit 0
