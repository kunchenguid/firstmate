#!/usr/bin/env bash
# fm-kill-pretool-check.sh - PreToolUse/Bash TOR for AGENTS.md HR3'
# ("Destruction is mechanically secured, not forbidden"): "kill targets
# outside registered ownership are refused by bin/fm-kill-pretool-check.sh
# (state/<task>.owned via bin/fm-owned.sh)" - that clause names this file and
# bin/fm-owned.sh by path, so this TOR IS the reader HR3' points at. HR3'
# itself continues the older forensics lesson L86 (data/forensik-2026-08/
# lehren-ledger.md): a broad pattern command acts on whatever matches instead
# of on what the actor itself created - a training run got killed by a
# neighbour's `pkill -f python3 -`. This TOR denies pkill and killall
# unconditionally, and denies a plain `kill <pid...>` unless every pid is
# fm-owned.sh pid-erlaubt (registered by the calling task, or a descendant of
# a registered pid - see bin/fm-owned.sh).
#
# Transport modeled on bin/fm-arm-pretool-check.sh: same stdin JSON payload
# (Grok's .toolInput.command vs Claude/Codex's .tool_input.command), the same
# foreign-host skip via fm-hook-host-lib.sh (a Cursor-delivered payload is the
# Claude-settings duplicate Cursor's own registration already evaluated), the
# same --command CLI escape hatch, and the same fail-open posture: malformed
# or empty stdin, missing jq, or any transport surprise allows rather than
# blocking the turn. It never executes, sources, evaluates, or expands the
# submitted command - only bash's own `[[ =~ ]]` matching and word-splitting.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-kill-pretool-check.sh
#   bin/fm-kill-pretool-check.sh --command '<cmd>' [--claude]
#
# Scharfschalt-Flag (transitional gate, TOR contract point 1): this TOR is
# built but stands down silently - exit 0, nothing read, nothing logged -
# unless $FM_HOME/state/.tor-kill-scharf exists. Once whole-chain verification
# arms that flag, the checks below become live.
#
# Escape hatch, spelled out in the deny message itself: prefix the exact
# command with FM_KILL_FREMD='<reason>' (e.g. `FM_KILL_FREMD='cleaning up a
# stuck neighbour task, captain confirmed' kill 4242`). The guard recognizes
# that prefix on the specific kill/pkill/killall clause it precedes and lets
# only that clause through; the reason travels into the tor log as the
# ausweg-genutzt field so the bypass is auditable, never silent.
#
# Tor log: every clause this TOR actually classifies (pkill/killall/kill at
# command position, after stripping env-var prefixes) gets one JSONL decision
# via fm_tor_log "kill" "HR3'" <gruen|rot|warn> <ausweg-genutzt|-> <kontext>,
# sourced from bin/fm-tor-log-lib.sh (or $FM_TOR_LOG_LIB_OVERRIDE for tests).
# fm-tor-log-lib.sh is owned by a separate change; until it exists this file
# defines a local no-op fallback (see TOR-LOG-LIB below) so this guard's
# allow/deny behavior never depends on that lib landing first.
#
# Scope, named so nobody relies on more than this: chain-splitting is done by
# a plain substring split on `&&`, `||`, `;`, `|` - real shell quoting inside
# a chain is not parsed, matching the same "simple chains" scope as
# tools/writ-fm/hooks/bash-guard.sh's git-add guard. Env-var prefix skipping
# handles unquoted values (`X=1 kill ...`) and, for FM_KILL_FREMD
# specifically, single- or double-quoted values with spaces. `kill`'s pid
# arguments are extracted by skipping flag-shaped tokens (anything starting
# with `-`, plus the option value after -s/--signal/-n/--queue/-q/--pid/
# --timeout); a legacy `kill -<pid>` targeting a process group by a bare
# negative pid is out of scope and reads as a signal flag instead.
#
# Exit/output contract (identical shape to bin/fm-arm-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY  - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#           deny object on stdout unless --claude was supplied.
#   FAIL OPEN - flag absent, malformed/empty stdin, missing jq, or nothing in
#               the command matches kill/pkill/killall at command position.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FLAG="$STATE/.tor-kill-scharf"
OWNED_SCRIPT="$SCRIPT_DIR/fm-owned.sh"

usage() {
  cat <<'EOF'
Usage: fm-kill-pretool-check.sh [--command <cmd>] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex tool_input.command).
Exits 0 to allow, 2 to deny a kill/pkill/killall of a process this task does
not own (bin/fm-owned.sh). Silent no-op (exit 0) unless
$FM_HOME/state/.tor-kill-scharf exists.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
Malformed transport, missing jq, and a command with no kill/pkill/killall all
fail open.
EOF
}

# TOR RULE 1: scharf-flag gate, checked before anything else in the file -
# absent flag means a fully silent pass, no payload read, no log written.
[ -f "$FLAG" ] || exit 0

CMD=""
CMD_SET=0
CLAUDE_MODE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/fm-hook-host-lib.sh"
  # A Cursor-delivered payload is the Claude-settings duplicate Cursor's own
  # registration already evaluated - allow without re-classifying.
  if fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

# TOR-LOG-LIB: bin/fm-tor-log-lib.sh is owned by a separate change and may not
# exist yet. $FM_TOR_LOG_LIB_OVERRIDE lets tests supply a stand-in with the
# documented signature; without either, fall back to a local no-op so this
# guard's allow/deny behavior never depends on the log surviving.
TOR_LOG_LIB="${FM_TOR_LOG_LIB_OVERRIDE:-$SCRIPT_DIR/fm-tor-log-lib.sh}"
if [ -f "$TOR_LOG_LIB" ]; then
  # shellcheck source=bin/fm-tor-log-lib.sh
  . "$TOR_LOG_LIB"
else
  # TODO(TOR-LOG-LIB): fm-tor-log-lib.sh not built yet; no-op until it lands.
  fm_tor_log() { :; }
fi

DENY=0
DENY_DETAIL=""

# owned_pgrep_descendant-style chain split: a plain substring split on the
# simple-chain separators, matching the scope named in the header above.
CMD_LINES=$(printf '%s\n' "$CMD" | sed -E 's/(&&|\|\||;|\|)/\n/g')

decide_broad() { # <name> <clause> <fremd-reason>
  local name="$1" clause="$2" fremd="$3"
  if [ -n "$fremd" ]; then
    fm_tor_log "kill" "HR3'" "warn" "$fremd" "$name broad-pattern kill escaped via FM_KILL_FREMD: $clause"
    return 0
  fi
  fm_tor_log "kill" "HR3'" "rot" "-" "$name broad-pattern kill denied: $clause"
  DENY=1
  if [ -z "$DENY_DETAIL" ]; then
    DENY_DETAIL="'$name' matches processes by pattern or name, never only ones this task owns, so it is always denied (clause: $clause)"
  fi
}

decide_kill() { # <clause> <fremd-reason>
  local clause="$1" fremd="$2" args
  args="${clause#kill}"
  args="${args#"${args%%[![:space:]]*}"}"
  local -a toks=()
  read -ra toks <<< "$args"
  local -a pids=()
  local i=0 n=${#toks[@]} tok
  while [ "$i" -lt "$n" ]; do
    tok="${toks[$i]}"
    case "$tok" in
      -s|--signal|-n|--queue|-q|--pid|--timeout)
        i=$((i + 2))
        continue
        ;;
      -*)
        i=$((i + 1))
        continue
        ;;
      *)
        pids+=("$tok")
        i=$((i + 1))
        ;;
    esac
  done
  [ "${#pids[@]}" -gt 0 ] || return 0
  local unowned="" pid
  for pid in "${pids[@]}"; do
    if ! "$OWNED_SCRIPT" pid-erlaubt "$pid" >/dev/null 2>&1; then
      unowned="$unowned $pid"
    fi
  done
  if [ -z "$unowned" ]; then
    fm_tor_log "kill" "HR3'" "gruen" "-" "kill $args - every pid is fm-owned"
    return 0
  fi
  if [ -n "$fremd" ]; then
    fm_tor_log "kill" "HR3'" "warn" "$fremd" "kill $args - unowned pid(s):$unowned, escaped via FM_KILL_FREMD"
    return 0
  fi
  fm_tor_log "kill" "HR3'" "rot" "-" "kill $args - unowned pid(s):$unowned"
  DENY=1
  if [ -z "$DENY_DETAIL" ]; then
    DENY_DETAIL="pid(s)$unowned are not registered as owned (bin/fm-owned.sh pid-erlaubt) for 'kill $args'"
  fi
}

handle_segment() { # <raw-segment>
  local raw_seg="$1" seg fremd="" name val rest cur
  seg="${raw_seg#"${raw_seg%%[![:space:]]*}"}"
  [ -n "$seg" ] || return 0
  cur="$seg"
  while :; do
    if [[ "$cur" =~ ^([A-Za-z_][A-Za-z0-9_]*)=\'([^\']*)\'[[:space:]]+(.*)$ ]]; then
      name=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}; rest=${BASH_REMATCH[3]}
    elif [[ "$cur" =~ ^([A-Za-z_][A-Za-z0-9_]*)=\"([^\"]*)\"[[:space:]]+(.*)$ ]]; then
      name=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}; rest=${BASH_REMATCH[3]}
    elif [[ "$cur" =~ ^([A-Za-z_][A-Za-z0-9_]*)=([^[:space:]]*)[[:space:]]+(.*)$ ]]; then
      name=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}; rest=${BASH_REMATCH[3]}
    else
      break
    fi
    [ "$name" = "FM_KILL_FREMD" ] && fremd="$val"
    cur="$rest"
  done
  if [[ "$cur" =~ ^pkill([[:space:]]|$) ]]; then
    decide_broad "pkill" "$cur" "$fremd"
  elif [[ "$cur" =~ ^killall([[:space:]]|$) ]]; then
    decide_broad "killall" "$cur" "$fremd"
  elif [[ "$cur" =~ ^kill([[:space:]]|$) ]]; then
    decide_kill "$cur" "$fremd"
  fi
}

while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  handle_segment "$seg"
done <<< "$CMD_LINES"

[ "$DENY" -eq 1 ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[HR3'] $DENY_DETAIL. Source (AGENTS.md, HR3'): \"kill targets outside registered ownership are refused by bin/fm-kill-pretool-check.sh (state/<task>.owned via bin/fm-owned.sh)\". Way out, named here: prefix this exact command with FM_KILL_FREMD='<reason>' (e.g. FM_KILL_FREMD='explain why' kill 1234) - that lets this one kill through and records the reason in the tor log."
ESCAPED=$(json_escape "$DETAIL")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
