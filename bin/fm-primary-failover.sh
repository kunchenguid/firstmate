#!/usr/bin/env bash
# fm-primary-failover.sh - keep a home's primary firstmate session alive across
# Claude limit exhaustion: relaunch the primary on another verified harness in
# the SAME terminal pane, then switch back to Claude when its window resets.
#
# Usage: fm-primary-failover.sh <command> [options]
#   check         one watchdog cycle (what launchd runs): detect, debounce, act
#   status        print lock holder, host pane, Claude quota, failover state and
#                 the preflight verdict for each failover candidate
#   failover      force a relaunch on the best failover harness (or --to <h>)
#   switch-back   force a relaunch on Claude
# Options (any command that acts):
#   --dry-run     print the plan and change nothing (no keys sent, no state)
#   --to <h>      failover target: grok, opencode, or pi (never codex)
#   --pane <id>   host pane when it cannot be read from the lock holder's env
#   --host <h>    herdr or tmux (default: read from the holder's env)
#   --help        this text
#
# Detection of Claude exhaustion (either signal, each debounced over
# FM_PF_CONFIRM consecutive cycles, default 2):
#   quota: `quota-axi --json` claude all_models effective percent remaining, or
#          the five_hour window, at or below FM_PF_EXHAUST_PCT (default 2).
#   pane:  the primary pane's last lines show Claude's own limit banner
#          ("You've hit your limit", "usage limit reached", HTTP 429 ...) while
#          the pane is not mid-turn.
# Switch-back needs both the effective percent and the five_hour window at or
# above FM_PF_RESUME_PCT (default 15) for FM_PF_CONFIRM cycles, and at least
# FM_PF_MIN_DWELL seconds (default 300) on the failover harness.
#
# SESSION LOCK HANDOVER. state/.lock line 1 is the owning session's anchor pid
# and state/.lock-session an optional Claude session id (bin/fm-lock.sh owns
# both). A new session reclaims the lock only when the recorded pid is dead, so
# the relaunch is strictly ordered:
#   1. ask the old harness to exit through its own exit command (/exit, /quit),
#      waiting while it is mid-turn; Escape once only after FM_PF_BUSY_WAIT;
#   2. wait for that exact pid to be gone. This script NEVER signals a harness:
#      if it does not exit within FM_PF_EXIT_WAIT the handover aborts (exit 3),
#      nothing is launched, and the next cycle retries;
#   3. confirm fm-lock.sh reports the lock free or stale, not held;
#   4. type the new harness command into the same pane and wait for the new
#      session to claim the lock (its first prompt runs bin/fm-session-start.sh).
# A grok or pi folder-trust dialog is answered with Enter (at most 3 times), the
# documented route in .agents/skills/harness-adapters/references/harness/{grok,pi}.md; pre-trusting the
# home avoids that. `status` reports whether each candidate is ready.
#
# Failover order comes from config/primary-failover-order (default
# "grok opencode pi"); a candidate must be installed and, where quota-axi has a
# row for it, above FM_PF_CANDIDATE_MIN_PCT (default 5). Claude's launch command
# prefix can be set in config/primary-failover-claude-cmd (default
# `claude --dangerously-skip-permissions`).
#
# Files: state/primary-failover.state (mode, counters, pane), state/primary-
# failover.log, state/primary-failover.prompt. Run it periodically with the
# launchd template docs/examples/com.firstmate.primary-failover.plist.
# Exit: 0 ok or nothing to do, 2 usage, 3 old session did not exit, 4 new
# session launched but never claimed the lock, 5 no usable target, 6 no host pane.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="$FM_HOME/config"
SF="$STATE/primary-failover.state"
LOG="$STATE/primary-failover.log"
PROMPT_FILE="$STATE/primary-failover.prompt"
RUN_LOCK="$STATE/.primary-failover.lock"

EXHAUST_PCT=${FM_PF_EXHAUST_PCT:-2}
RESUME_PCT=${FM_PF_RESUME_PCT:-15}
CANDIDATE_MIN_PCT=${FM_PF_CANDIDATE_MIN_PCT:-5}
CONFIRM=${FM_PF_CONFIRM:-2}
MIN_DWELL=${FM_PF_MIN_DWELL:-300}
BUSY_WAIT=${FM_PF_BUSY_WAIT:-120}
EXIT_WAIT=${FM_PF_EXIT_WAIT:-90}
START_WAIT=${FM_PF_START_WAIT:-90}
HERDR_BIN=${FM_PF_HERDR_BIN:-herdr}
TMUX_BIN=${FM_PF_TMUX_BIN:-tmux}
LIMIT_RE=${FM_PF_LIMIT_RE:-"(hit your (usage |session |weekly |org(anization)? )?limit|usage limit reached|(5-hour|five-hour|session|weekly|opus|sonnet) limit reached|API Error: 429|rate_limit_error|credit balance is too low)"}

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() { sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
log() { mkdir -p "$STATE"; printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; echo "fm-primary-failover: $*" >&2; }
now() { date +%s; }

# --- state ----------------------------------------------------------------
st_get() {  # <key> [default]
  local v=
  [ -f "$SF" ] && v=$(sed -n "s/^$1=//p" "$SF" | tail -n 1)
  printf '%s' "${v:-${2:-}}"
}
st_set() {  # <key=value>...
  local tmp kv k
  mkdir -p "$STATE"
  tmp=$(mktemp "$STATE/.primary-failover.state.XXXXXX") || return 1
  [ -f "$SF" ] && cat "$SF" >"$tmp"
  for kv in "$@"; do
    k=${kv%%=*}
    { grep -v "^$k=" "$tmp" || true; } >"$tmp.n"
    printf '%s\n' "$kv" >>"$tmp.n"
    mv "$tmp.n" "$tmp"
  done
  mv "$tmp" "$SF"
}

# --- lock holder ----------------------------------------------------------
LOCK_STATE=''
LOCK_PID=''
inspect_lock() {
  fm_session_lock_inspect "$STATE"
  LOCK_STATE=$FM_LOCK_INSPECT_STATE LOCK_PID=$FM_LOCK_INSPECT_PID
}

# Normalized harness name of live pid $1 (claude, grok, opencode, pi), or empty.
harness_of_pid() {
  local pid=$1 comm args argv0 tok n
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 0
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  argv0=${args%% *}
  for tok in "$(basename -- "$comm")" "$(basename -- "$argv0")" "$(fm_harness_path_name "$comm")" "$(fm_harness_path_name "$argv0")"; do
    case "$tok" in
      claude) n=claude ;; grok) n=grok ;; opencode) n=opencode ;;
      pi|pi-signed|pi-launcher) n=pi ;; codex) n=codex ;; omp) n=omp ;; kimi) n=kimi ;;
      *) continue ;;
    esac
    printf '%s' "$n"
    return 0
  done
  # interpreter running a harness script (node, python, bash shim)
  case "$(basename -- "$comm")" in
    node|python*|bash|bun)
      for n in claude grok opencode pi; do
        case " $args " in *"/$n "*|*" $n "*) printf '%s' "$n"; return 0 ;; esac
      done ;;
  esac
}

# Environment value $2 of process $1 (own-uid processes only).
pid_env() {
  ps eww -p "$1" 2>/dev/null | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n 1
}

# --- host pane ------------------------------------------------------------
HOST=''
PANE=''
PANE_SOCK=''
resolve_host() {  # <holder-pid> [forced-host] [forced-pane]
  local pid=$1
  HOST=${2:-} PANE=${3:-} PANE_SOCK=
  if [ -z "$PANE" ] && [ -n "$pid" ]; then
    PANE=$(pid_env "$pid" HERDR_PANE_ID)
    if [ -n "$PANE" ]; then
      HOST=herdr
      PANE_SOCK=$(pid_env "$pid" HERDR_SOCKET_PATH)
    else
      PANE=$(pid_env "$pid" TMUX_PANE)
      if [ -n "$PANE" ]; then
        HOST=tmux
        PANE_SOCK=$(pid_env "$pid" TMUX)
        PANE_SOCK=${PANE_SOCK%%,*}
      fi
    fi
  elif [ -n "$PANE" ] && [ -n "$pid" ]; then
    # forced pane: still take the server socket from the holder's own env
    case "$HOST" in
      herdr) PANE_SOCK=$(pid_env "$pid" HERDR_SOCKET_PATH) ;;
      tmux) PANE_SOCK=$(pid_env "$pid" TMUX); PANE_SOCK=${PANE_SOCK%%,*} ;;
    esac
  fi
  [ -n "$PANE" ] || PANE=$(st_get pane)
  [ -n "$HOST" ] || HOST=$(st_get host)
  # no live holder (relaunch after the primary died): reuse the recorded socket
  [ -n "$PANE_SOCK" ] || [ "$HOST" != "$(st_get host)" ] || PANE_SOCK=$(st_get sock)
  [ -n "$PANE" ] && [ -n "$HOST" ]
}

pane_cmd() {  # <subcommand...> via the host's CLI
  case "$HOST" in
    herdr) HERDR_SOCKET_PATH=${PANE_SOCK:-${HERDR_SOCKET_PATH:-}} "$HERDR_BIN" pane "$@" ;;
    tmux) return 1 ;;
  esac
}
pane_tail() {  # [lines]
  local n=${1:-15}
  case "$HOST" in
    herdr) pane_cmd read "$PANE" --lines "$n" 2>/dev/null ;;
    tmux) "$TMUX_BIN" ${PANE_SOCK:+-S "$PANE_SOCK"} capture-pane -p -t "$PANE" -S "-$n" 2>/dev/null ;;
  esac
}
pane_busy() {  # true when the pane's agent is mid-turn (herdr only; tmux has no signal)
  [ "$HOST" = herdr ] || return 1
  pane_cmd get "$PANE" 2>/dev/null | grep -q '"agent_status":"working"'
}
pane_line() {  # <text>: type text and Enter
  case "$HOST" in
    herdr) pane_cmd run "$PANE" "$1" >/dev/null ;;
    tmux) "$TMUX_BIN" ${PANE_SOCK:+-S "$PANE_SOCK"} send-keys -t "$PANE" -l "$1" &&
          "$TMUX_BIN" ${PANE_SOCK:+-S "$PANE_SOCK"} send-keys -t "$PANE" Enter ;;
  esac
}
pane_key() {  # <Enter|esc>
  case "$HOST" in
    herdr) pane_cmd send-keys "$PANE" "$1" >/dev/null ;;
    tmux) "$TMUX_BIN" ${PANE_SOCK:+-S "$PANE_SOCK"} send-keys -t "$PANE" "$([ "$1" = esc ] && echo Escape || echo "$1")" ;;
  esac
}

# --- quota ----------------------------------------------------------------
QUOTA_JSON=
load_quota() {
  QUOTA_JSON=$(fm_run_timed 30 quota-axi --json 2>/dev/null </dev/null) || QUOTA_JSON=
  printf '%s' "$QUOTA_JSON" | jq -e '.providers' >/dev/null 2>&1 || QUOTA_JSON=
  [ -n "$QUOTA_JSON" ]
}
# "<effective-pct> <five-hour-pct> <resetsAt>" for a provider's all-scope row.
quota_row() {  # <provider> <scope>
  printf '%s' "$QUOTA_JSON" | jq -r --arg p "$1" --arg s "$2" '
    [.providers[]? | select(.provider == $p)] as $r
    | (($r | map(select(.accountKey == "default")) | first) // ($r | first)) as $x
    | if $x == null then "" else
      "\([$x.quotaSemantics.effectiveAvailability[]? | select(.scope == $s)][0].effectivePercentRemaining // "") \([$x.windows[]? | select(.id == "five_hour")][0].percentRemaining // "") \([$x.windows[]? | select(.id == "five_hour")][0].resetsAt // "")" end' 2>/dev/null
}
CL_EFF=''
CL_FIVE=''
CL_RESETS=''
claude_quota() {
  CL_EFF=''
  CL_FIVE=''
  CL_RESETS=''
  [ -n "$QUOTA_JSON" ] || return 1
  read -r CL_EFF CL_FIVE CL_RESETS <<EOF
$(quota_row claude all_models)
EOF
  [ -n "$CL_EFF$CL_FIVE" ]
}
num_le() { [ -n "$1" ] && awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 <= b+0)}'; }
num_ge() { [ -n "$1" ] && awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }

claude_exhausted_by_quota() { claude_quota && { num_le "$CL_EFF" "$EXHAUST_PCT" || num_le "$CL_FIVE" "$EXHAUST_PCT"; }; }
claude_has_headroom() {
  claude_quota || return 1
  { [ -z "$CL_EFF" ] || num_ge "$CL_EFF" "$RESUME_PCT"; } && { [ -z "$CL_FIVE" ] || num_ge "$CL_FIVE" "$RESUME_PCT"; }
}
pane_shows_limit() {
  pane_busy && return 1
  pane_tail 12 | grep -Eiq "$LIMIT_RE"
}

# --- candidates -----------------------------------------------------------
launch_bin() { case "$1" in claude) echo claude ;; *) echo "$1" ;; esac; }
quota_provider() { case "$1" in grok) echo grok:all_products ;; opencode) echo opencode-go:all_models ;; *) echo ;; esac; }

# Print "ok" or the reason harness $1 cannot take the primary.
candidate_verdict() {
  local h=$1 qp row eff
  case "$h" in grok|opencode|pi) ;; *) echo "not a verified failover harness"; return ;; esac
  command -v "$(launch_bin "$h")" >/dev/null 2>&1 || { echo "not installed"; return; }
  qp=$(quota_provider "$h")
  if [ -n "$qp" ] && [ -n "$QUOTA_JSON" ]; then
    row=$(quota_row "${qp%%:*}" "${qp##*:}")
    eff=${row%% *}
    if [ -n "$eff" ] && ! num_ge "$eff" "$CANDIDATE_MIN_PCT"; then echo "quota ${eff}% remaining"; return; fi
  fi
  if [ "$h" = grok ] && ! grep -qF "\"$FM_HOME\"" "${GROK_TRUSTED_FOLDERS:-$HOME/.grok/trusted_folders.toml}" 2>/dev/null; then
    echo "ok (home not in grok trusted_folders; folder-trust dialog will be answered with Enter)"; return
  fi
  echo ok
}
pick_target() {
  local order h v
  order=$(cat "$CONFIG/primary-failover-order" 2>/dev/null)
  for h in ${order:-grok opencode pi}; do
    v=$(candidate_verdict "$h")
    case "$v" in ok*) printf '%s' "$h"; return 0 ;; esac
  done
  return 1
}

# --- launch ---------------------------------------------------------------
write_prompt() {  # <reason>
  mkdir -p "$STATE"
  printf '%s\n' "wake: $1. Run bin/fm-session-start.sh, reread OPENCLAW_TALK_PREP.md in the home root, append a status entry, and keep working." >"$PROMPT_FILE"
}
launch_line() {  # <harness>
  local p="\"\$(cat '$PROMPT_FILE')\"" prefix
  case "$1" in
    claude)
      prefix=$(cat "$CONFIG/primary-failover-claude-cmd" 2>/dev/null)
      printf "cd '%s' && %s %s" "$FM_HOME" "${prefix:-claude --dangerously-skip-permissions}" "$p" ;;
    grok) printf "cd '%s' && grok --always-approve %s" "$FM_HOME" "$p" ;;
    opencode) printf "cd '%s' && opencode --prompt %s" "$FM_HOME" "$p" ;;
    pi) printf "cd '%s' && pi -e .pi/extensions/fm-primary-turnend-guard.ts -e .pi/extensions/fm-primary-pi-watch.ts %s" "$FM_HOME" "$p" ;;
  esac
}
exit_cmd() { case "$1" in pi) echo /quit ;; *) echo /exit ;; esac; }

pid_gone() { ! kill -0 "$1" 2>/dev/null; }
wait_gone() {  # <pid> <seconds>
  local pid=$1 left=$2
  while [ "$left" -gt 0 ]; do pid_gone "$pid" && return 0; sleep 1; left=$((left - 1)); done
  pid_gone "$pid"
}

# Move the primary from holder pid $1 (harness $2) to harness $3.
relaunch() {  # <old-pid|""> <old-harness> <new-harness> <reason>
  local old=$1 oldh=$2 new=$3 reason=$4 waited=0 tries=0 tail_text trust_re='' answered=0
  case "$new" in grok) trust_re='[Tt]rust' ;; pi) trust_re='Trust project folder' ;; esac
  if [ -n "$old" ]; then
    if pane_busy; then
      log "old $oldh pid $old is mid-turn; waiting up to ${BUSY_WAIT}s"
      while pane_busy && [ "$waited" -lt "$BUSY_WAIT" ]; do sleep 2; waited=$((waited + 2)); done
      pane_busy && { pane_key esc; sleep 3; }
    fi
    log "asking $oldh pid $old to exit ($(exit_cmd "$oldh"))"
    pane_line "$(exit_cmd "$oldh")" || return 6
    while [ "$tries" -lt "$EXIT_WAIT" ]; do
      pid_gone "$old" && break
      sleep 1; tries=$((tries + 1))
      # a slash-command popup can swallow the first Enter
      case "$tries" in 8|30) pid_gone "$old" || pane_key Enter ;; esac
    done
    if ! pid_gone "$old"; then
      log "ABORT: $oldh pid $old still alive after ${EXIT_WAIT}s; not launching, nothing signalled"
      return 3
    fi
    inspect_lock
    if [ "$LOCK_STATE" = held ]; then
      log "ABORT: lock still held by live harness pid $LOCK_PID after $oldh exit"
      return 3
    fi
    sleep 2
  fi
  write_prompt "$reason"
  log "launching $new in $HOST pane $PANE"
  pane_line "$(launch_line "$new")" || return 6
  waited=0
  while [ "$waited" -lt "$START_WAIT" ]; do
    inspect_lock
    if [ "$LOCK_STATE" = held ] && [ "$(harness_of_pid "$LOCK_PID")" = "$new" ]; then
      log "new $new session holds the lock (pid $LOCK_PID)"
      return 0
    fi
    if [ -n "$trust_re" ] && [ "$answered" -lt 3 ]; then
      tail_text=$(pane_tail 20)
      if printf '%s' "$tail_text" | grep -Eq "$trust_re"; then
        log "$new folder-trust dialog: answering Enter"; pane_key Enter; answered=$((answered + 1)); sleep 3
      fi
    fi
    sleep 2; waited=$((waited + 2))
  done
  log "WARN: $new launched but no lock claim within ${START_WAIT}s (dialog or slow start?)"
  return 4
}

# --- commands -------------------------------------------------------------
do_move() {  # <new-harness> <reason> <mode-after> ; uses globals DRY FORCE_HOST FORCE_PANE
  local newh=$1 reason=$2 mode=$3 oldpid="" oldh="" rc
  inspect_lock
  [ "$LOCK_STATE" = held ] && { oldpid=$LOCK_PID; oldh=$(harness_of_pid "$oldpid"); }
  if [ "$oldh" = "$newh" ]; then log "primary already on $newh; nothing to do"; return 0; fi
  resolve_host "$oldpid" "$FORCE_HOST" "$FORCE_PANE" || { log "no host pane resolvable (holder env, state, --pane/--host)"; return 6; }
  echo "plan: ${oldh:-none}${oldpid:+ pid $oldpid} -> $newh in $HOST pane $PANE (home $FM_HOME)"
  echo "plan: exit cmd: ${oldpid:+$(exit_cmd "$oldh")}"
  echo "plan: launch: $(launch_line "$newh")"
  [ "$DRY" -eq 1 ] && return 0
  relaunch "$oldpid" "$oldh" "$newh" "$reason"
  rc=$?
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 4 ]; then
    st_set "mode=$mode" "primary=$newh" "since=$(now)" "pane=$PANE" "host=$HOST" "sock=$PANE_SOCK" "exhaust_count=0" "resume_count=0" "claude_resets_at=${CL_RESETS:-}" "last_rc=$rc"
  fi
  return "$rc"
}

cmd_failover() {
  local target=${TARGET:-}
  [ -n "$QUOTA_JSON" ] || load_quota
  claude_quota
  [ -n "$target" ] || target=$(pick_target) || { log "no usable failover harness"; return 5; }
  case "$(candidate_verdict "$target")" in ok*) ;; *) log "$target not usable: $(candidate_verdict "$target")"; return 5 ;; esac
  do_move "$target" "Claude limit exhausted (resets ${CL_RESETS:-unknown}); primary moved to $target for continuity" failover
}
cmd_switch_back() {
  claude_quota
  do_move claude "Claude window reset; primary switched back to Claude from $(st_get primary unknown)" normal
}

cmd_status() {
  local h
  inspect_lock
  echo "lock: $LOCK_STATE${LOCK_PID:+ pid $LOCK_PID ($(harness_of_pid "$LOCK_PID"))}"
  resolve_host "$([ "$LOCK_STATE" = held ] && echo "$LOCK_PID")" "$FORCE_HOST" "$FORCE_PANE" && echo "host: $HOST pane $PANE" || echo "host: unresolved"
  echo "state: mode=$(st_get mode normal) primary=$(st_get primary -) since=$(st_get since -) exhaust_count=$(st_get exhaust_count 0) resume_count=$(st_get resume_count 0)"
  if load_quota && claude_quota; then echo "claude quota: effective=${CL_EFF:-?}% five_hour=${CL_FIVE:-?}% resets=${CL_RESETS:-?}"; else echo "claude quota: unavailable"; fi
  for h in $(cat "$CONFIG/primary-failover-order" 2>/dev/null || echo grok opencode pi); do echo "candidate $h: $(candidate_verdict "$h")"; done
  if pane_shows_limit 2>/dev/null; then echo "pane: limit banner visible"; else echo "pane: no limit banner"; fi
}

cmd_check() {
  local mode holder_h="" n
  mode=$(st_get mode normal)
  inspect_lock
  [ "$LOCK_STATE" = held ] && holder_h=$(harness_of_pid "$LOCK_PID")
  load_quota
  claude_quota
  if [ "$mode" = normal ]; then
    [ "$holder_h" = claude ] || { echo "check: primary is ${holder_h:-not running}; nothing to do"; st_set exhaust_count=0 2>/dev/null; return 0; }
    resolve_host "$LOCK_PID" "$FORCE_HOST" "$FORCE_PANE" || true
    if claude_exhausted_by_quota || pane_shows_limit; then
      n=$(( $(st_get exhaust_count 0) + 1 ))
      echo "check: claude exhaustion signal $n/$CONFIRM (eff=${CL_EFF:-?} five=${CL_FIVE:-?})"
      if [ "$n" -ge "$CONFIRM" ]; then cmd_failover; return $?; fi
      [ "$DRY" -eq 1 ] || st_set "exhaust_count=$n"
    else
      echo "check: claude healthy (eff=${CL_EFF:-?} five=${CL_FIVE:-?})"
      [ "$DRY" -eq 1 ] || st_set exhaust_count=0
    fi
    return 0
  fi
  # failover mode
  if [ "$holder_h" = claude ]; then
    echo "check: claude is primary again; clearing failover mode"
    [ "$DRY" -eq 1 ] || st_set mode=normal primary=claude resume_count=0 exhaust_count=0
    return 0
  fi
  if claude_has_headroom && ! pane_shows_limit; then
    n=$(( $(st_get resume_count 0) + 1 ))
    echo "check: claude headroom $n/$CONFIRM (eff=${CL_EFF:-?} five=${CL_FIVE:-?})"
    if [ "$n" -ge "$CONFIRM" ] && [ $(( $(now) - $(st_get since 0) )) -ge "$MIN_DWELL" ]; then cmd_switch_back; return $?; fi
    [ "$DRY" -eq 1 ] || st_set "resume_count=$n"
  else
    echo "check: still on $(st_get primary -); claude not ready (eff=${CL_EFF:-?} five=${CL_FIVE:-?})"
    [ "$DRY" -eq 1 ] || st_set resume_count=0
  fi
  return 0
}

# --- main -----------------------------------------------------------------
CMD=${1:-}; [ $# -gt 0 ] && shift
DRY=0
TARGET=''
FORCE_HOST=''
FORCE_PANE=''
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --to) TARGET=${2:-}; shift ;;
    --pane) FORCE_PANE=${2:-}; shift ;;
    --host) FORCE_HOST=${2:-}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-primary-failover: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
case "$TARGET" in ''|grok|opencode|pi) ;; *) echo "fm-primary-failover: --to must be grok, opencode, or pi" >&2; exit 2 ;; esac
case "$FORCE_HOST" in ''|herdr|tmux) ;; *) echo "fm-primary-failover: --host must be herdr or tmux" >&2; exit 2 ;; esac

case "$CMD" in
  -h|--help|help) usage; exit 0 ;;
  status) cmd_status; exit 0 ;;
  check|failover|switch-back) ;;
  *) usage >&2; exit 2 ;;
esac

# One acting run at a time; a stale lock (dead pid) is reclaimed.
if [ "$DRY" -eq 0 ]; then
  mkdir -p "$STATE"
  if ! mkdir "$RUN_LOCK" 2>/dev/null; then
    other=$(cat "$RUN_LOCK/pid" 2>/dev/null)
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then echo "fm-primary-failover: another run (pid $other) is active"; exit 0; fi
    rm -rf "$RUN_LOCK"; mkdir "$RUN_LOCK" || exit 0
  fi
  echo $$ >"$RUN_LOCK/pid"
  trap 'rm -rf "$RUN_LOCK"' EXIT
fi

case "$CMD" in
  check) cmd_check ;;
  failover) cmd_failover ;;
  switch-back) load_quota; cmd_switch_back ;;
esac
