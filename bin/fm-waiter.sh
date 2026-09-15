#!/usr/bin/env bash
# Watch backgrounded work so its completion wakes the invoking worker within seconds.
# Usage: FM_HOME=<home> fm-waiter.sh [--fm-home <home>] register [--hold <seconds>] [--interval <seconds>] [--tail <lines>] [--log <path>] <task-id> -- <pid> [<pid>...]
#        FM_HOME=<home> fm-waiter.sh [--fm-home <home>] register [--hold <seconds>] [--interval <seconds>] [--tail <lines>] [--log <path>] <task-id> -- <command> [...]
#        (register flags may come before or after <task-id>.)
#        FM_HOME=<home> fm-waiter.sh [--fm-home <home>] wait <registration-id> [--interval <seconds>] [--budget <seconds>]
#        FM_HOME=<home> fm-waiter.sh [--fm-home <home>] cancel <registration-id>
# register records one live wait under this home's state/ and prints its registration id plus, for the command form, the log path.
# The command-form child is launched fully detached (stdin, stdout, and stderr off the caller's pipe), so register returns at once even when the caller's output is captured.
# The pid form watches worker-backgrounded pids the worker started itself (e.g. `long-cmd >log 2>&1 & echo $!`): every token after -- is numeric, so each names a pid, and at least one must still be alive or registration is refused.
# The command form (any non-numeric token after --) launches the command backgrounded in its own process group with stdout/stderr captured to a log (TMPDIR scratch by default, --log to choose) and watches that child.
# Completion is decided by one marker convention per mode, stored in the record: pid-form completes when every watched pid fails kill -0; command-form completes when its exit-code file appears or, failing that, when its pid fails kill -0.
# wait sweeps every --interval seconds (record default 2, clamped to the 1..15 range) until every watched pid is done or the registration hold expires.
# A wait that finds every pid already done returns at once with exit 145 and prints the capture state; it sends no message because the requesting worker is already awake.
# A wait that observes completion sends exactly one durable steering message through fm-send.sh to the owning task reporting command, status, exit code, elapsed, log path, and the bounded tail, then exits with the watched exit code (0 when a pid-form watch cannot know it).
# A wait that reaches the registration --hold (default 3600) sends the same shaped message reporting expiry with the capture state and exits 124; expiry kills the command-form process group, while pid-form pids are left running because they are not ours to kill.
# A wait that reaches its own --budget (default 540) sends nothing, keeps the registration live, and exits 142 so the worker re-invokes wait under a fresh harness command cap.
# The send is best-effort with one exact retry: when both attempts fail, one fallback line is printed to the pane and nothing else is written, so a lost notification stays observable instead of silently dropped.
# cancel stops a live wait: it kills the command-form process group, removes the record, and sends nothing.
# Only one live registration per owning task: a second register for the same task is refused loudly, as is any register or wait naming an id outside [A-Za-z0-9._-].
# Every path stays under FM_HOME: the record lives at state/.wait-<registration-id>, the command-form log under TMPDIR scratch or a --log inside FM_HOME or TMPDIR, and the inbox record fm-send.sh owns; a pid-form --log is read-only tail source and may live anywhere readable; nothing is ever removed recursively and no other task's records are touched.
# Worker pairing under the harness command cap (about ten minutes per tool call): register once, then run `wait <id>` about once per slice; each wait returns on completion (message sent), on hold expiry (message sent, exit 124), or on budget (re-invoke, exit 142).
# A wait killed outright by the cap leaves the durable record behind, so re-invoking wait resumes the same watch; a wait that returns 145 means the work already finished and the state it prints is the whole result.
# fm-babysit.sh remains the valid simpler path for one foreground command that fits a single tool call; reach for fm-waiter.sh when the job outlasts one call or several jobs share one completion wake.
# Exit 142 and 145 are waiter-protocol codes: a watched command that dies with exactly one of those codes is still reported truthfully in the message text.
# The send home comes from --fm-home first and FM_HOME second; an absent or non-directory home is refused loudly before anything runs.
# The send binary defaults to the fm-send.sh beside this script and must be executable; FM_WAITER_SEND overrides it (a test hook).
# The hold-expiry kill grace is FM_WAITER_KILL_GRACE seconds (default 5, also a test hook).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

err() {
  local code=$1
  shift
  printf 'fm-waiter: error: %s\n' "$*" >&2
  exit "$code"
}

fm_format_elapsed() {
  local s=$1
  if [ "$s" -lt 60 ]; then
    printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%sm%02ds' "$((s / 60))" "$((s % 60))"
  else
    printf '%sh%02dm%02ds' "$((s / 3600))" "$(((s % 3600) / 60))" "$((s % 60))"
  fi
}

need_pos_int() {
  case "${2:-}" in
    ''|*[!0-9]*|0) err 2 "$1 must be a positive integer: ${2:-empty}" ;;
  esac
}

valid_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_HOME_FLAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fm-home)
      [ $# -ge 2 ] || err 2 "--fm-home requires a value"
      FM_HOME_FLAG=$2
      shift 2
      ;;
    --fm-home=*) FM_HOME_FLAG=${1#--fm-home=} ; shift ;;
    --) shift; break ;;
    -*) break ;;
    *) break ;;
  esac
done

SUB=${1:-}
[ -n "$SUB" ] || err 2 "missing subcommand (register|wait|cancel)"
case "$SUB" in
  register|wait|cancel) ;;
  *) err 2 "unknown subcommand: $SUB" ;;
esac
shift

SEND_HOME=${FM_HOME_FLAG:-${FM_HOME:-}}
[ -n "$SEND_HOME" ] || err 1 "no send home: pass --fm-home <home> or set FM_HOME"
[ -d "$SEND_HOME" ] || err 1 "send home is not a directory: $SEND_HOME"
STATE="$SEND_HOME/state"
mkdir -p "$STATE" || err 1 "cannot create state dir: $STATE"

SEND_BIN=${FM_WAITER_SEND:-$SCRIPT_DIR/fm-send.sh}
[ -x "$SEND_BIN" ] || err 1 "send binary is not executable: $SEND_BIN"

KILL_GRACE=${FM_WAITER_KILL_GRACE:-5}
case "$KILL_GRACE" in
  *[!0-9]*) err 2 "FM_WAITER_KILL_GRACE must be a non-negative integer" ;;
esac

rec_path() {
  printf '%s/.wait-%s' "$STATE" "$1"
}

rec_get() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

send_completion() {
  if FM_HOME="$SEND_HOME" "$SEND_BIN" "$1" "$2" >/dev/null 2>&1; then
    return 0
  fi
  sleep 2
  if FM_HOME="$SEND_HOME" "$SEND_BIN" "$1" "$2" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

kill_group() {
  local pg=$1
  [ -n "$pg" ] || return 0
  kill -0 "$pg" 2>/dev/null || return 0
  kill -TERM "-$pg" 2>/dev/null || kill -TERM "$pg" 2>/dev/null || true
  sleep "$KILL_GRACE"
  kill -0 "$pg" 2>/dev/null || return 0
  kill -KILL "-$pg" 2>/dev/null || kill -KILL "$pg" 2>/dev/null || true
}

pids_all_dead() {
  local p
  for p in $1; do
    if kill -0 "$p" 2>/dev/null; then
      return 1
    fi
  done
  return 0
}

cmd_register() {
  local task="" hold=3600 interval=2 tail_n=50 log_given=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --hold|--interval|--tail|--log)
        [ $# -ge 2 ] || err 2 "$1 requires a value"
        case "$1" in
          --hold) hold=$2 ;;
          --interval) interval=$2 ;;
          --tail) tail_n=$2 ;;
          --log) log_given=$2 ;;
        esac
        shift 2
        ;;
      --hold=*) hold=${1#--hold=} ; shift ;;
      --interval=*) interval=${1#--interval=} ; shift ;;
      --tail=*) tail_n=${1#--tail=} ; shift ;;
      --log=*) log_given=${1#--log=} ; shift ;;
      --help|-h) usage; exit 0 ;;
      --) shift; break ;;
      --*) err 2 "unknown flag: $1" ;;
      *)
        if [ -n "$task" ]; then
          err 2 "unexpected argument: $1"
        fi
        task=$1
        shift
        ;;
    esac
  done
  [ -n "$task" ] || err 2 "missing <task-id>"
  valid_id "$task" || err 2 "invalid <task-id>: $task (use [A-Za-z0-9._-])"
  [ $# -gt 0 ] || err 2 "missing watched pids or <command> after '--'"

  need_pos_int "--hold" "$hold"
  case "$interval" in
    ''|*[!0-9]*|0) err 2 "--interval must be a positive integer number of seconds: ${interval:-empty}" ;;
  esac
  case "$tail_n" in
    *[!0-9]*|0) err 2 "--tail must be a positive integer number of lines" ;;
  esac
  case "$log_given" in
    -*) err 2 "--log must not start with '-'" ;;
  esac
  if [ "$interval" -gt 15 ]; then
    interval=15
    printf 'fm-waiter: interval clamped to 15s (maximum)\n'
  fi

  local mode pids cmd_text log codefile="" pgid="" wrapdir=""
  local tok all_numeric=1
  for tok in "$@"; do
    case "$tok" in
      ''|*[!0-9]*|0) all_numeric=0; break ;;
    esac
  done
  if [ "$all_numeric" -eq 1 ]; then
    mode="pid"
    pids="$*"
    if pids_all_dead "$pids"; then
      err 1 "no live pid among: $pids (inspect your log directly; nothing to watch)"
    fi
    cmd_text="pids $pids"
    log="$log_given"
  else
    mode="cmd"
    cmd_text=""
    for tok in "$@"; do
      cmd_text="${cmd_text:+$cmd_text }$tok"
    done
    if [ -n "$log_given" ]; then
      case "$log_given" in
        "$SEND_HOME"/*|"${TMPDIR:-/tmp}"/*|/tmp/*)
          log="$log_given"
          : > "$log" || err 1 "cannot write log file: $log"
          ;;
        *) err 1 "--log must live under FM_HOME or TMPDIR scratch: $log_given" ;;
      esac
    else
      log=$(mktemp "${TMPDIR:-/tmp}/fm-waiter-$task.XXXXXX.log") || err 1 "cannot create scratch log file"
    fi
  fi

  local rec owner
  for rec in "$STATE"/.wait-*; do
    [ -e "$rec" ] || break
    case "$rec" in
      *.tmp.*) continue ;;
    esac
    owner=$(rec_get "$rec" "owner")
    if [ "$owner" = "$task" ] && [ "$(rec_get "$rec" "status")" = "live" ]; then
      err 1 "task $task already has a live registration ($(basename "$rec" | sed 's/^\.wait-//')); wait for it or cancel it first"
    fi
  done

  if [ "$mode" = "cmd" ]; then
    wrapdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-waiter-$task.XXXXXX") || err 1 "cannot create scratch dir"
    codefile="$wrapdir/exit-code"
    if command -v setsid >/dev/null 2>&1; then
      # shellcheck disable=SC2016 # "$@" and "$LOG_PATH" expand in the child shell, not here.
      LOG_PATH="$log" CODE_PATH="$codefile" setsid sh -c '"$@" >>"$LOG_PATH" 2>&1; printf "%s\n" "$?" >"$CODE_PATH"' _ "$@" </dev/null >/dev/null 2>&1 &
      pids=$!
      pgid=$pids
    else
      # shellcheck disable=SC2016 # "$@" and "$LOG_PATH" expand in the child shell, not here.
      LOG_PATH="$log" CODE_PATH="$codefile" sh -c '"$@" >>"$LOG_PATH" 2>&1; printf "%s\n" "$?" >"$CODE_PATH"' _ "$@" </dev/null >/dev/null 2>&1 &
      pids=$!
      pgid=""
    fi
  fi

  local reg
  reg="w-$(date +%s)-$$-$RANDOM$RANDOM"
  local rec_tmp
  rec_tmp=$(mktemp "$STATE/.wait-tmp.XXXXXX") || err 1 "cannot create wait record"
  {
    printf 'owner=%s\n' "$task"
    printf 'mode=%s\n' "$mode"
    printf 'pids=%s\n' "$pids"
    printf 'pgid=%s\n' "$pgid"
    printf 'codefile=%s\n' "$codefile"
    printf 'wrapdir=%s\n' "$wrapdir"
    printf 'log=%s\n' "$log"
    printf 'cmd=%s\n' "$(printf '%s' "$cmd_text" | tr '\n' ' ')"
    printf 'created=%s\n' "$(date +%s)"
    printf 'hold=%s\n' "$hold"
    printf 'interval=%s\n' "$interval"
    printf 'tail=%s\n' "$tail_n"
    printf 'status=live\n'
    printf 'result=\n'
    printf 'summary=\n'
  } > "$rec_tmp"
  mv "$rec_tmp" "$(rec_path "$reg")" || err 1 "cannot publish wait record"

  printf 'fm-waiter: registration %s for task %s (%s watch on %s); log: %s\n' \
    "$reg" "$task" "$mode" "$cmd_text" "${log:-none}"
}

mark_done() {
  local rec=$1 result=$2 summary=$3 tmp
  tmp=$(mktemp "$STATE/.wait-tmp.XXXXXX") || return 0
  grep -v '^status=' "$rec" 2>/dev/null | grep -v '^result=' | grep -v '^summary=' > "$tmp" || true
  printf 'status=done\nresult=%s\nsummary=%s\n' "$result" "$(printf '%s' "$summary" | tr '\n' ' ')" >> "$tmp"
  mv "$tmp" "$rec" || true
}

compose_state() {
  local rec=$1 kind=$2 bodyfile=$3
  local owner mode pids codefile log cmd created hold tail_n
  local now elapsed elapsed_text code status exit_code sig_name tail_text
  owner=$(rec_get "$rec" "owner")
  mode=$(rec_get "$rec" "mode")
  pids=$(rec_get "$rec" "pids")
  codefile=$(rec_get "$rec" "codefile")
  log=$(rec_get "$rec" "log")
  cmd=$(rec_get "$rec" "cmd")
  created=$(rec_get "$rec" "created")
  hold=$(rec_get "$rec" "hold")
  tail_n=$(rec_get "$rec" "tail")

  code=""
  now=$(date +%s)
  elapsed=$((now - created))
  [ "$elapsed" -ge 0 ] || elapsed=0
  elapsed_text=$(fm_format_elapsed "$elapsed")
  if [ -n "$codefile" ] && [ -s "$codefile" ]; then
    code=$(head -n 1 "$codefile" 2>/dev/null | tr -dc '0-9')
  fi

  if [ "$kind" = "expired" ]; then
    if [ "$mode" = "cmd" ]; then
      status="expired after ${hold}s; watched process group killed"
    else
      status="expired after ${hold}s; watched pids left running (not ours to kill)"
    fi
    exit_code=124
  elif [ -n "$code" ]; then
    if [ "$code" -eq 0 ]; then
      status="completed ok"
      exit_code=0
    elif [ "$code" -gt 128 ]; then
      sig_name=$(kill -l "$((code - 128))" 2>/dev/null || printf '%s' "$((code - 128))")
      status="killed by signal $sig_name"
      exit_code=$code
    else
      status="failed"
      exit_code=$code
    fi
  elif pids_all_dead "$pids"; then
    status="exited (exit status unavailable: a $mode watch cannot reap)"
    exit_code=0
  else
    status="still running"
    exit_code=0
  fi

  local tail_text="(no log captured)"
  if [ -n "$log" ] && [ -r "$log" ]; then
    tail_text=$(tail -n "$tail_n" "$log" 2>/dev/null | tail -c 8000 || true)
    [ -n "$tail_text" ] || tail_text="(log empty)"
  fi

  {
    printf "fm-waiter: '%s' %s (exit %s, elapsed %s, log %s)\n--- last %s lines of the log ---\n%s\n" \
      "$cmd" "$status" "$exit_code" "$elapsed_text" "${log:-none}" "$tail_n" "$tail_text"
  } > "$bodyfile"
  printf '%s\n%s\n' "$status" "$exit_code"
}

cmd_wait() {
  local reg=${1:-}
  shift || true
  case "$reg" in
    ""|-*) err 2 "missing <registration-id>" ;;
  esac
  valid_id "$reg" || err 2 "invalid <registration-id>: $reg (use [A-Za-z0-9._-])"
  local interval="" budget=540
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval)
        [ $# -ge 2 ] || err 2 "--interval requires a value"
        interval=$2
        shift 2
        ;;
      --budget)
        [ $# -ge 2 ] || err 2 "--budget requires a value"
        budget=$2
        shift 2
        ;;
      --interval=*) interval=${1#--interval=} ; shift ;;
      --budget=*) budget=${1#--budget=} ; shift ;;
      --help|-h) usage; exit 0 ;;
      --*) err 2 "unknown flag: $1" ;;
      *) err 2 "unexpected argument: $1" ;;
    esac
  done

  local rec
  rec=$(rec_path "$reg")
  [ -f "$rec" ] || err 1 "unknown registration: $reg (already completed, expired, or cancelled)"

  if [ "$(rec_get "$rec" "status")" = "done" ]; then
    printf 'fm-waiter: registration %s already reported: %s\n' "$reg" "$(rec_get "$rec" "summary")"
    exit 145
  fi

  local owner mode pids codefile rec_interval
  owner=$(rec_get "$rec" "owner")
  mode=$(rec_get "$rec" "mode")
  pids=$(rec_get "$rec" "pids")
  codefile=$(rec_get "$rec" "codefile")
  rec_interval=$(rec_get "$rec" "interval")
  if [ -n "$interval" ]; then
    case "$interval" in
      ''|*[!0-9]*|0) err 2 "--interval must be a positive integer number of seconds: ${interval:-empty}" ;;
    esac
    if [ "$interval" -gt 15 ]; then
      interval=15
      printf 'fm-waiter: interval clamped to 15s (maximum)\n'
    fi
  else
    interval=$rec_interval
  fi
  need_pos_int "--budget" "$budget"

  local interrupted=""
  # shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
  waiter_trap() {
    interrupted=$1
  }
  trap 'waiter_trap TERM' TERM
  trap 'waiter_trap INT' INT

  cmd_complete_now() {
    if [ "$mode" = "cmd" ] && [ -n "$codefile" ] && [ -s "$codefile" ]; then
      return 0
    fi
    pids_all_dead "$pids"
  }

  local start now body bodyfile verdict status exit_code line1
  start=$(date +%s)
  bodyfile=$(mktemp "${TMPDIR:-/tmp}/fm-waiter-body.XXXXXX") || err 1 "cannot create scratch body file"

  if cmd_complete_now; then
    trap - TERM INT
    verdict=$(compose_state "$rec" "done" "$bodyfile")
    body=$(cat "$bodyfile")
    rm -f -- "$bodyfile"
    line1=$(printf '%s' "$body" | head -n 1)
    mark_done "$rec" "already-done" "$line1"
    printf '%s\n' "$body"
    exit 145
  fi

  while :; do
    sleep "$interval" || true
    if [ -n "$interrupted" ]; then
      trap - TERM INT
      rm -f -- "$bodyfile"
      printf 'fm-waiter: interrupted by SIG%s; registration %s kept (re-invoke wait to resume)\n' "$interrupted" "$reg"
      case "$interrupted" in
        TERM) exit 143 ;;
        INT) exit 130 ;;
        *) exit 143 ;;
      esac
    fi
    if cmd_complete_now; then
      break
    fi
    now=$(date +%s)
    if [ "$((now - $(rec_get "$rec" "created")))" -ge "$(rec_get "$rec" "hold")" ]; then
      trap - TERM INT
      if [ "$mode" = "cmd" ]; then
        kill_group "$(rec_get "$rec" "pgid")"
        sleep 1
      fi
      verdict=$(compose_state "$rec" "expired" "$bodyfile")
      body=$(cat "$bodyfile")
      rm -f -- "$bodyfile"
      line1=$(printf '%s' "$body" | head -n 1)
      status=$(printf '%s' "$verdict" | head -n 1)
      exit_code=$(printf '%s' "$verdict" | tail -n 1)
      mark_done "$rec" "expired" "$line1"
      if send_completion "$owner" "$body"; then
        printf 'fm-waiter: notified task %s: %s (registration %s)\n' "$owner" "$status" "$reg"
      else
        printf 'fm-waiter: FAILED to notify task %s (send failed twice); %s (registration %s, log %s)\n' \
          "$owner" "$status" "$reg" "$(rec_get "$rec" "log")"
      fi
      exit "$exit_code"
    fi
    if [ "$((now - start))" -ge "$budget" ]; then
      trap - TERM INT
      rm -f -- "$bodyfile"
      printf 'fm-waiter: registration %s still running after %ss budget; re-invoke wait to resume\n' \
        "$reg" "$budget"
      exit 142
    fi
  done

  trap - TERM INT
  verdict=$(compose_state "$rec" "done" "$bodyfile")
  body=$(cat "$bodyfile")
  rm -f -- "$bodyfile"
  line1=$(printf '%s' "$body" | head -n 1)
  status=$(printf '%s' "$verdict" | head -n 1)
  exit_code=$(printf '%s' "$verdict" | tail -n 1)
  mark_done "$rec" "completed" "$line1"
  if send_completion "$owner" "$body"; then
    printf 'fm-waiter: notified task %s: %s (exit %s, registration %s)\n' \
      "$owner" "$status" "$exit_code" "$reg"
  else
    printf 'fm-waiter: FAILED to notify task %s (send failed twice); %s (exit %s, registration %s, log %s)\n' \
      "$owner" "$status" "$exit_code" "$reg" "$(rec_get "$rec" "log")"
  fi
  exit "$exit_code"
}

cmd_cancel() {
  local reg=${1:-}
  [ -n "$reg" ] || err 2 "missing <registration-id>"
  case "$reg" in
    -*) err 2 "invalid <registration-id>: $reg" ;;
  esac
  [ $# -eq 1 ] || err 2 "unexpected argument: $2"
  valid_id "$reg" || err 2 "invalid <registration-id>: $reg (use [A-Za-z0-9._-])"
  local rec
  rec=$(rec_path "$reg")
  [ -f "$rec" ] || err 1 "unknown registration: $reg (already completed, expired, or cancelled)"
  if [ "$(rec_get "$rec" "status")" = "live" ] && [ "$(rec_get "$rec" "mode")" = "cmd" ]; then
    kill_group "$(rec_get "$rec" "pgid")"
  fi
  rm -f -- "$rec" || err 1 "cannot remove wait record: $rec"
  printf 'fm-waiter: registration %s cancelled (no message sent)\n' "$reg"
}

case "$SUB" in
  register) cmd_register "$@" ;;
  wait) cmd_wait "$@" ;;
  cancel) cmd_cancel "$@" ;;
esac
