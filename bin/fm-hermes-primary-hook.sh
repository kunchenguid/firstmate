#!/usr/bin/env bash
# Hermes shell-hook bridge for firstmate PRIMARY transports.
#
# Hermes declares shell hooks in ~/.hermes/config.yaml (user-global), not in a
# project .hermes/ directory. These wrappers keep every policy decision inside
# firstmate-tracked scripts and fail open when the cwd is not a firstmate
# primary home.
#
# Wire protocol (stdin JSON from Hermes agent/shell_hooks.py):
#   {
#     "hook_event_name": "pre_tool_call" | "pre_llm_call" | "post_llm_call" | ...,
#     "tool_name": "...",
#     "tool_input": {...},
#     "session_id": "...",
#     "cwd": "/path",
#     "extra": {...}
#   }
#
# Usage (installed by bin/fm-hermes-install-primary-hooks.sh):
#   hooks.pre_tool_call   -> bin/fm-hermes-primary-hook.sh pre_tool_call
#   hooks.pre_llm_call    -> bin/fm-hermes-primary-hook.sh pre_llm_call
#   hooks.post_llm_call   -> bin/fm-hermes-primary-hook.sh post_llm_call
#
# See docs/hermes-primary.md for install, evidence, and residual gaps.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVENT="${1:-}"

# Always exit 0 to the outer shell-hook runner except when deliberately
# returning a structured block/continue JSON on stdout. Hermes treats a
# non-zero shell exit as a failed hook (logged), not a tool block.
payload=$(cat || true)
if [ -z "$payload" ]; then
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)
event=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
[ -n "$EVENT" ] || EVENT=$event

# Resolve the firstmate root that owns these wrappers.
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# Only act inside a firstmate-shaped primary home. Match the shared primary-scope
# idea loosely: AGENTS.md + bin/ + a state or data directory. Fail open elsewhere
# so a global Hermes hook never surprises non-firstmate projects. Linked task
# worktrees without state/data also fail open (crews must not inherit primary hooks).
is_firstmate_primary() {
  local root=$1
  [ -f "$root/AGENTS.md" ] || return 1
  [ -x "$root/bin/fm-session-start.sh" ] || return 1
  [ -d "$root/state" ] || [ -d "$root/data" ] || return 1
  return 0
}

# Require the payload cwd to be firstmate-shaped. Global Hermes hooks must not
# enforce firstmate policy on unrelated projects just because the wrapper lives
# inside a firstmate checkout.
if [ -z "$cwd" ] || ! is_firstmate_primary "$cwd"; then
  exit 0
fi
SCOPE_ROOT=$cwd

case "$EVENT" in
  pre_tool_call)
    tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)
    # Hermes terminal tool carries the shell command under tool_input.command.
    # Other tools are irrelevant to the arm/continuity seatbelts.
    case "$tool" in
      terminal|bash|shell) ;;
      *) exit 0 ;;
    esac
    cmd=$(printf '%s' "$payload" | jq -r '
      .tool_input.command // .tool_input.cmd // .extra.command // empty
    ' 2>/dev/null || true)
    [ -n "$cmd" ] || exit 0

    # Arm anti-patterns (shell &, truncating pipe, bundling, broad pkill).
    if [ -x "$FM_ROOT/bin/fm-arm-pretool-check.sh" ]; then
      if ! out=$(cd "$FM_ROOT" && FM_HOME="$SCOPE_ROOT" bin/fm-arm-pretool-check.sh --command "$cmd" 2>/dev/null); then
        # Deny object may be on stdout (Grok shape) or stderr; prefer stdout JSON.
        reason=$(printf '%s' "$out" | jq -r '.reason // .message // empty' 2>/dev/null || true)
        [ -n "$reason" ] || reason="firstmate arm policy denied this shell command"
        printf '%s\n' "{\"decision\":\"block\",\"reason\":$(printf '%s' "$reason" | jq -Rs .)}"
        exit 0
      fi
    fi

    # Continuity seatbelt: refuse other fleet commands while work is live and
    # no watcher holds the lock. The shared script already speaks Claude deny
    # shape on stderr and exit 2; translate that into Hermes block JSON.
    if [ -x "$FM_ROOT/bin/fm-continuity-pretool-check.sh" ]; then
      if ! err=$(cd "$FM_ROOT" && FM_HOME="$SCOPE_ROOT" bin/fm-continuity-pretool-check.sh --command "$cmd" 2>&1 >/dev/null); then
        reason=$(printf '%s' "$err" | jq -r '.systemMessage // .reason // .message // empty' 2>/dev/null || true)
        [ -n "$reason" ] || reason=$(printf '%s' "$err" | tr '\n' ' ' | head -c 400)
        [ -n "$reason" ] || reason="firstmate continuity gate refused this fleet command"
        printf '%s\n' "{\"decision\":\"block\",\"reason\":$(printf '%s' "$reason" | jq -Rs .)}"
        exit 0
      fi
    fi
    exit 0
    ;;

  pre_llm_call)
    # Inject the session-start nudge on the first turn of a new session only.
    # Hermes pre_llm_call accepts {"context":"..."} and folds it into the call.
    is_first=$(printf '%s' "$payload" | jq -r '.extra.is_first_turn // false' 2>/dev/null || true)
    case "$is_first" in
      true|True|1) ;;
      *) exit 0 ;;
    esac
    if [ -x "$FM_ROOT/bin/fm-sessionstart-nudge.sh" ]; then
      nudge=$(cd "$FM_ROOT" && FM_HOME="$SCOPE_ROOT" bin/fm-sessionstart-nudge.sh 2>/dev/null || true)
      if [ -n "$nudge" ]; then
        printf '%s\n' "{\"context\":$(printf '%s' "$nudge" | jq -Rs .)}"
      fi
    fi
    exit 0
    ;;

  post_llm_call|on_session_end)
    # Passive observer only: Hermes cannot force a same-session follow-up from
    # these events the way Claude/Codex Stop hooks can. Feed the shared predicate
    # the real turn-end payload so it actually evaluates (an empty stdin makes it
    # fail open immediately); when it would block - a blind turn end, tasks in
    # flight with no live watcher - record a durable, rate-limited marker under
    # this primary's state dir so the lapse outlives the discarded stderr banner.
    if [ -x "$FM_ROOT/bin/fm-turnend-guard.sh" ]; then
      if ! (cd "$FM_ROOT" && FM_HOME="$SCOPE_ROOT" bin/fm-turnend-guard.sh >/dev/null 2>&1 <<PAYLOAD
$payload
PAYLOAD
      ); then
        state_dir="$SCOPE_ROOT/state"
        alarm="$state_dir/.hermes-turnend-alarm"
        if [ -d "$state_dir" ]; then
          grace=${FM_GUARD_GRACE:-300}
          now=$(date +%s 2>/dev/null || echo 0)
          last=0
          [ -f "$alarm" ] && last=$(cut -d' ' -f1 "$alarm" 2>/dev/null || echo 0)
          case "$last" in ''|*[!0-9]*) last=0 ;; esac
          # Rate-limit: refresh at most once per grace window (single-line
          # overwrite) so a persistently blind session never spams the marker.
          if [ "$now" -eq 0 ] || [ "$last" -eq 0 ] || [ "$((now - last))" -ge "$grace" ]; then
            printf '%s blind-turn-end: tasks in flight, no live watcher (hermes post_llm_call observer)\n' \
              "$now" > "$alarm" 2>/dev/null || true
          fi
        fi
      fi
    fi
    exit 0
    ;;

  *)
    exit 0
    ;;
esac
