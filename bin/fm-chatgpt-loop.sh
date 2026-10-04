#!/usr/bin/env bash
# fm-chatgpt-loop.sh - Firstmate-owned ChatGPT -> worker -> ChatGPT -> worker
# orchestration state machine.
# Usage: fm-chatgpt-loop.sh init --task ID --objective-file FILE [--context-file FILE] [--thread ID]
#        fm-chatgpt-loop.sh consult --stage audit|plan --task ID
#        fm-chatgpt-loop.sh dispatch --stage audit|plan --task ID -- <fm-spawn args>
#        fm-chatgpt-loop.sh record-findings --task ID --file FILE
#        fm-chatgpt-loop.sh record-result --task ID --file FILE
#        fm-chatgpt-loop.sh record-worker-failure --task ID --stage audit|plan --reason TEXT
#        fm-chatgpt-loop.sh next-round --task ID
#        fm-chatgpt-loop.sh status --task ID
#        fm-chatgpt-loop.sh bridge status|start|stop [--task ID]
#
# Firstmate owns everything about this workflow: the per-task state file, the
# ChatGPT consultation lifecycle, worker dispatch, worker results, iteration
# between audit and planning, and the bridge daemon lifecycle. The worker is
# an ordinary low-thinking spawn (fm-spawn.sh with --effort low) and never
# touches the bridge; nothing in the dispatch path starts, stops, or probes
# it. The bridge is the already-installed codex-chatgpt-web daemon and is
# never installed, authenticated, or repaired here.
#
# State file: $FM_HOME/data/<task-id>/chatgpt-loop.json, one JSON object with
# task_id, objective, context, thread, phase, iteration, audit_prompt,
# audit_result, findings, plan, worker_result, last_error, and updated_at.
# Phases: audit-consult -> audit-dispatch -> audit-worker -> plan-consult ->
# plan-dispatch -> plan-worker -> complete. next-round increments iteration
# and returns to audit-consult so further audit/plan cycles stay possible.
# A wrong-phase call refuses with a nonzero exit and no state change.
#
# The bridge keeps no conversation history keyed by thread id alone: every
# consultation is one self-contained turn, so consult assembles prior context
# into the prompt file itself. The audit prompt carries the user objective
# plus Firstmate context; the plan prompt carries the objective, context,
# stored audit prompt, audit result, and worker findings, all explicitly
# included. bin/fm-chatgpt-consult.sh owns the transport and its fail-closed
# contract; this script owns state, prompts, and dispatch. On consult or
# bridge failure the phase is unchanged (retryable), last_error records the
# cause, and dispatch issues nothing.
#
# Test seam: FM_CHATGPT_LOOP_SPAWN overrides the fm-spawn.sh path, and
# FM_CHATGPT_LOOP_CONSULT overrides the fm-chatgpt-consult.sh path. Both
# default to the sibling scripts beside this file. docs/configuration.md
# "ChatGPT consultation channel" owns the user-facing contract.
set -u

LIBDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-chatgpt-bridge-lib.sh
. "$LIBDIR/fm-chatgpt-bridge-lib.sh"

FM_HOME="${FM_HOME:-$(cd "$LIBDIR/.." && pwd)}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SPAWN="${FM_CHATGPT_LOOP_SPAWN:-$LIBDIR/fm-spawn.sh}"
CONSULT_BIN="${FM_CHATGPT_LOOP_CONSULT:-$LIBDIR/fm-chatgpt-consult.sh}"
BRIDGE_PID_FILE="$STATE/chatgpt-loop-bridge.pid"

usage() {
  printf 'usage: %s init --task ID --objective-file FILE [--context-file FILE] [--thread ID]\n' "$(basename "$0")" >&2
  printf '       %s consult --stage audit|plan --task ID\n' "$(basename "$0")" >&2
  printf '       %s dispatch --stage audit|plan --task ID -- <fm-spawn args>\n' "$(basename "$0")" >&2
  printf '       %s record-findings --task ID --file FILE\n' "$(basename "$0")" >&2
  printf '       %s record-result --task ID --file FILE\n' "$(basename "$0")" >&2
  printf '       %s record-worker-failure --task ID --stage audit|plan --reason TEXT\n' "$(basename "$0")" >&2
  printf '       %s next-round --task ID\n' "$(basename "$0")" >&2
  printf '       %s status --task ID\n' "$(basename "$0")" >&2
  printf '       %s bridge status|start|stop\n' "$(basename "$0")" >&2
}

loop_state_file() {
  printf '%s/%s/chatgpt-loop.json' "$DATA" "$1"
}

now_iso() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

read_field() {
  jq -r --arg k "$2" '.[$k] // empty' "$1"
}

write_field() {
  local file=$1 key=$2 value=$3 tmp
  tmp=$(mktemp) || return 1
  jq --arg k "$key" --arg v "$value" '.[$k] = $v | .updated_at = $now' --arg now "$(now_iso)" "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
}

need_state() {
  local file
  file=$(loop_state_file "$1")
  [ -f "$file" ] || { printf 'fm-chatgpt-loop: no loop state for task %s (run init first)\n' "$1" >&2; return 1; }
  printf '%s\n' "$file"
}

require_phase() {
  local file=$1 want=$2 actual
  actual=$(read_field "$file" phase)
  [ "$actual" = "$want" ] || { printf 'fm-chatgpt-loop: task %s is in phase %s, need %s; no state changed\n' "$3" "$actual" "$want" >&2; return 1; }
}

cmd_init() {
  local task="" objective_file="" context_file="" thread=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) task=${2:-}; shift 2 ;;
      --objective-file) objective_file=${2:-}; shift 2 ;;
      --context-file) context_file=${2:-}; shift 2 ;;
      --thread) thread=${2:-}; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) printf 'fm-chatgpt-loop: unknown init argument %s\n' "$1" >&2; usage; return 2 ;;
    esac
  done
  [ -n "$task" ] || { printf 'fm-chatgpt-loop: init needs --task\n' >&2; usage; return 2; }
  [ -n "$objective_file" ] || { printf 'fm-chatgpt-loop: init needs --objective-file\n' >&2; usage; return 2; }
  [ -f "$objective_file" ] || { printf 'fm-chatgpt-loop: objective file not found: %s\n' "$objective_file" >&2; return 2; }
  [ -z "$thread" ] && thread="chatgpt-loop-$task"
  local context=""
  if [ -n "$context_file" ]; then
    [ -f "$context_file" ] || { printf 'fm-chatgpt-loop: context file not found: %s\n' "$context_file" >&2; return 2; }
    context=$(cat "$context_file")
  fi
  local dir file objective tmp
  dir="$DATA/$task"
  mkdir -p "$dir" || return 1
  file=$(loop_state_file "$task")
  objective=$(cat "$objective_file")
  tmp=$(mktemp) || return 1
  jq -n --arg t "$task" --arg o "$objective" --arg c "$context" --arg th "$thread" --arg u "$(now_iso)" \
    '{task_id: $t, objective: $o, context: $c, thread: $th, phase: "audit-consult", iteration: 1, audit_prompt: "", audit_result: "", findings: "", plan: "", worker_result: "", last_error: "", updated_at: $u}' > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
  printf 'initialized task %s in phase audit-consult\n' "$task"
}

build_audit_prompt() {
  local file=$1 out=$2
  {
    printf 'User objective:\n%s\n\n' "$(read_field "$file" objective)"
    printf 'Firstmate context:\n%s\n' "$(read_field "$file" context)"
  } > "$out"
}

build_plan_prompt() {
  local file=$1 out=$2
  {
    printf 'User objective:\n%s\n\n' "$(read_field "$file" objective)"
    printf 'Firstmate context:\n%s\n\n' "$(read_field "$file" context)"
    printf 'Audit prompt sent earlier:\n%s\n\n' "$(read_field "$file" audit_prompt)"
    printf 'ChatGPT audit result:\n%s\n\n' "$(read_field "$file" audit_result)"
    printf 'Worker audit findings:\n%s\n' "$(read_field "$file" findings)"
  } > "$out"
}

cmd_consult() {
  local stage="" task=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage) stage=${2:-}; shift 2 ;;
      --task) task=${2:-}; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) printf 'fm-chatgpt-loop: unknown consult argument %s\n' "$1" >&2; usage; return 2 ;;
    esac
  done
  case "$stage" in
    audit|plan) ;;
    *) printf 'fm-chatgpt-loop: consult needs --stage audit|plan\n' >&2; usage; return 2 ;;
  esac
  [ -n "$task" ] || { printf 'fm-chatgpt-loop: consult needs --task\n' >&2; usage; return 2; }
  local file thread
  file=$(need_state "$task") || return 1
  if [ "$stage" = audit ]; then
    require_phase "$file" audit-consult "$task" || return 1
  else
    require_phase "$file" plan-consult "$task" || return 1
  fi
  command -v jq >/dev/null 2>&1 || { printf 'fm-chatgpt-loop: consultation needs jq\n' >&2; return 1; }
  thread=$(read_field "$file" thread)
  local work prompt answer rc
  work=$(mktemp -d) || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN
  prompt="$work/prompt.txt"
  if [ "$stage" = audit ]; then
    build_audit_prompt "$file" "$prompt"
  else
    build_plan_prompt "$file" "$prompt"
  fi
  if [ -n "${FM_CHATGPT_LOOP_PROMPT_COPY:-}" ]; then
    cp "$prompt" "$FM_CHATGPT_LOOP_PROMPT_COPY"
  fi
  if answer=$("$CONSULT_BIN" --prompt-file "$prompt" --mode "$stage" --thread "$thread" 2>"$work/stderr.txt"); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    write_field "$file" last_error "$(cat "$work/stderr.txt")"
    cat "$work/stderr.txt" >&2
    return "$rc"
  fi
  if [ "$stage" = audit ]; then
    write_field "$file" audit_prompt "$(cat "$prompt")" || return 1
    write_field "$file" audit_result "$answer" || return 1
    write_field "$file" phase audit-dispatch || return 1
  else
    write_field "$file" plan "$answer" || return 1
    write_field "$file" phase plan-dispatch || return 1
  fi
  write_field "$file" last_error "" || return 1
  printf '%s\n' "$answer"
}

cmd_dispatch() {
  local stage="" task="" after_dash=0
  local -a spawn_args=()
  while [ $# -gt 0 ]; do
    if [ "$after_dash" = 1 ]; then
      spawn_args+=("$1"); shift
    else
      case "$1" in
        --stage) stage=${2:-}; shift 2 ;;
        --task) task=${2:-}; shift 2 ;;
        --) after_dash=1; shift ;;
        -h|--help) usage; return 0 ;;
        *) printf 'fm-chatgpt-loop: unknown dispatch argument %s\n' "$1" >&2; usage; return 2 ;;
      esac
    fi
  done
  case "$stage" in
    audit|plan) ;;
    *) printf 'fm-chatgpt-loop: dispatch needs --stage audit|plan\n' >&2; usage; return 2 ;;
  esac
  [ -n "$task" ] || { printf 'fm-chatgpt-loop: dispatch needs --task\n' >&2; usage; return 2; }
  [ "${#spawn_args[@]}" -gt 0 ] || { printf 'fm-chatgpt-loop: dispatch needs spawn args after --\n' >&2; usage; return 2; }
  local file
  file=$(need_state "$task") || return 1
  if [ "$stage" = audit ]; then
    require_phase "$file" audit-dispatch "$task" || return 1
  else
    require_phase "$file" plan-dispatch "$task" || return 1
  fi
  # Worker boundary: no spawned argv element or brief content may reference
  # the ChatGPT bridge. Refuse before launching. Bridge-related ambient
  # variables are scrubbed from the spawn environment below rather than
  # refused, so the loop's own bridge configuration never reaches the worker.
  local bad='chatgpt|CHATGPT_WEB_BRIDGE_URL|fm-chatgpt|codex-chatgpt-web|17841'
  local a
  for a in "${spawn_args[@]}"; do
    if printf '%s' "$a" | grep -Eiq "$bad"; then
      printf 'fm-chatgpt-loop: refusing dispatch: spawn arg references the bridge: %s\n' "$a" >&2
      return 2
    fi
  done
  # The low-thinking worker is this workflow's definition: always --effort low.
  # Bridge lifecycle stays Firstmate-owned: the worker environment never
  # carries the bridge URL, and nothing here starts, stops, or probes it.
  env -u CHATGPT_WEB_BRIDGE_URL -u FM_CHATGPT_LOOP_SPAWN -u FM_CHATGPT_LOOP_CONSULT -u FM_CHATGPT_LOOP_PROMPT_COPY -u FM_CHATGPT_LOOP_DAEMON_DIR "$SPAWN" "${spawn_args[@]}" --effort low || return $?
  if [ "$stage" = audit ]; then
    write_field "$file" phase audit-worker || return 1
  else
    write_field "$file" phase plan-worker || return 1
  fi
  write_field "$file" last_error "" || return 1
  printf 'dispatched %s worker for task %s with --effort low\n' "$stage" "$task"
}

cmd_record_findings() {
  local task="" rfile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) task=${2:-}; shift 2 ;;
      --file) rfile=${2:-}; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) printf 'fm-chatgpt-loop: unknown record-findings argument %s\n' "$1" >&2; usage; return 2 ;;
    esac
  done
  [ -n "$task" ] || { printf 'fm-chatgpt-loop: record-findings needs --task\n' >&2; usage; return 2; }
  [ -n "$rfile" ] && [ -f "$rfile" ] || { printf 'fm-chatgpt-loop: record-findings needs an existing --file\n' >&2; usage; return 2; }
  local file
  file=$(need_state "$task") || return 1
  require_phase "$file" audit-worker "$task" || return 1
  write_field "$file" findings "$(cat "$rfile")" || return 1
  write_field "$file" phase plan-consult || return 1
  printf 'recorded audit findings for task %s\n' "$task"
}

cmd_record_result() {
  local task="" rfile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) task=${2:-}; shift 2 ;;
      --file) rfile=${2:-}; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) printf 'fm-chatgpt-loop: unknown record-result argument %s\n' "$1" >&2; usage; return 2 ;;
    esac
  done
  [ -n "$task" ] || { printf 'fm-chatgpt-loop: record-result needs --task\n' >&2; usage; return 2; }
  [ -n "$rfile" ] && [ -f "$rfile" ] || { printf 'fm-chatgpt-loop: record-result needs an existing --file\n' >&2; usage; return 2; }
  local file
  file=$(need_state "$task") || return 1
  require_phase "$file" plan-worker "$task" || return 1
  write_field "$file" worker_result "$(cat "$rfile")" || return 1
  write_field "$file" phase complete || return 1
  printf 'recorded execution result for task %s: complete\n' "$task"
}

cmd_record_worker_failure() {
  local task="" stage="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) task=${2:-}; shift 2 ;;
      --stage) stage=${2:-}; shift 2 ;;
      --reason) reason=${2:-}; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) printf 'fm-chatgpt-loop: unknown record-worker-failure argument %s\n' "$1" >&2; usage; return 2 ;;
    esac
  done
  [ -n "$task" ] || { printf 'fm-chatgpt-loop: record-worker-failure needs --task\n' >&2; usage; return 2; }
  case "$stage" in
    audit|plan) ;;
    *) printf 'fm-chatgpt-loop: record-worker-failure needs --stage audit|plan\n' >&2; usage; return 2 ;;
  esac
  [ -n "$reason" ] || { printf 'fm-chatgpt-loop: record-worker-failure needs --reason\n' >&2; usage; return 2; }
  local file want
  file=$(need_state "$task") || return 1
  want="$stage-worker"
  require_phase "$file" "$want" "$task" || return 1
  write_field "$file" last_error "worker $stage failure: $reason" || return 1
  printf 'recorded %s worker failure for task %s; phase unchanged at %s\n' "$stage" "$task" "$want" >&2
  return 1
}

cmd_next_round() {
  local task=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) task=${2:-}; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) printf 'fm-chatgpt-loop: unknown next-round argument %s\n' "$1" >&2; usage; return 2 ;;
    esac
  done
  [ -n "$task" ] || { printf 'fm-chatgpt-loop: next-round needs --task\n' >&2; usage; return 2; }
  local file iter tmp
  file=$(need_state "$task") || return 1
  require_phase "$file" complete "$task" || return 1
  iter=$(jq -r '.iteration // 1' "$file")
  tmp=$(mktemp) || return 1
  jq --argjson i "$((iter + 1))" --arg u "$(now_iso)" '.iteration = $i | .phase = "audit-consult" | .updated_at = $u' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
  printf 'task %s advanced to round %s\n' "$task" "$((iter + 1))"
}

cmd_status() {
  local task=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) task=${2:-}; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) printf 'fm-chatgpt-loop: unknown status argument %s\n' "$1" >&2; usage; return 2 ;;
    esac
  done
  [ -n "$task" ] || { printf 'fm-chatgpt-loop: status needs --task\n' >&2; usage; return 2; }
  local file
  file=$(need_state "$task") || return 1
  jq '.' "$file"
}

bridge_probe() {
  local url
  url=$(fm_chatgpt_bridge_url) || return 1
  curl -s -m 5 -o /dev/null "$url" 2>/dev/null
}

cmd_bridge_status() {
  if bridge_probe; then
    printf 'bridge up\n'
    return 0
  fi
  printf 'fm-chatgpt-loop: bridge unreachable; start the codex-chatgpt-web bridge before consulting\n' >&2
  return 1
}

bridge_daemon_dir() {
  if [ -n "${FM_CHATGPT_LOOP_DAEMON_DIR:-}" ]; then
    printf '%s\n' "$FM_CHATGPT_LOOP_DAEMON_DIR"
  else
    printf '%s/tools/codex-chatgpt-web\n' "$HOME"
  fi
}

cmd_bridge_start() {
  case " $* " in
    *' install '*|*' setup '*|*' login '*|*' uninstall '*)
      printf 'fm-chatgpt-loop: bridge start refuses install/setup/login/uninstall verbs; the bridge is already installed and authenticated externally\n' >&2
      return 2
      ;;
  esac
  if [ -f "$BRIDGE_PID_FILE" ]; then
    local old
    old=$(cat "$BRIDGE_PID_FILE" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
      printf 'fm-chatgpt-loop: bridge already started by this loop (pid %s)\n' "$old" >&2
      return 1
    fi
    rm -f "$BRIDGE_PID_FILE"
  fi
  if bridge_probe; then
    printf 'fm-chatgpt-loop: a bridge is already reachable; start refuses to take ownership of a foreign instance (stop only stops what start started)\n' >&2
    return 1
  fi
  local dir cli
  dir=$(bridge_daemon_dir)
  [ -d "$dir" ] || { printf 'fm-chatgpt-loop: bridge daemon not found at %s; install it externally first\n' "$dir" >&2; return 1; }
  if [ -x "$dir/bin/codex-chatgpt-web" ]; then
    cli="$dir/bin/codex-chatgpt-web"
  elif [ -f "$dir/src/cli.ts" ] && command -v bun >/dev/null 2>&1; then
    cli="bun run $dir/src/cli.ts"
  else
    printf 'fm-chatgpt-loop: cannot resolve the bridge serve entrypoint under %s\n' "$dir" >&2
    return 1
  fi
  # Visible browser by default: never force headless operation here.
  mkdir -p "$STATE" || return 1
  # shellcheck disable=SC2086
  nohup $cli serve >"$STATE/chatgpt-loop-bridge.log" 2>&1 &
  printf '%s\n' "$!" > "$BRIDGE_PID_FILE"
  printf 'bridge starting (pid %s, log %s/chatgpt-loop-bridge.log)\n' "$!" "$STATE"
}

cmd_bridge_stop() {
  case " $* " in
    *' install '*|*' setup '*|*' login '*|*' uninstall '*)
      printf 'fm-chatgpt-loop: bridge stop refuses install/setup/login/uninstall verbs\n' >&2
      return 2
      ;;
  esac
  [ -f "$BRIDGE_PID_FILE" ] || { printf 'fm-chatgpt-loop: no loop-owned bridge instance to stop; never killing a foreign process\n' >&2; return 1; }
  local pid
  pid=$(cat "$BRIDGE_PID_FILE" 2>/dev/null)
  [ -n "$pid" ] || { printf 'fm-chatgpt-loop: no loop-owned bridge instance to stop\n' >&2; rm -f "$BRIDGE_PID_FILE"; return 1; }
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    printf 'bridge instance %s stopped\n' "$pid"
  else
    printf 'bridge instance %s already exited\n' "$pid"
  fi
  rm -f "$BRIDGE_PID_FILE"
}

cmd_bridge() {
  local verb=${1:-}
  shift || true
  case "$verb" in
    status) cmd_bridge_status "$@" ;;
    start) cmd_bridge_start "$@" ;;
    stop) cmd_bridge_stop "$@" ;;
    install|setup|login|uninstall)
      printf 'fm-chatgpt-loop: bridge %s is refused; installation and authentication stay external\n' "$verb" >&2
      return 2
      ;;
    -h|--help|'') usage; [ -n "$verb" ] || return 2 ;;
    *) printf 'fm-chatgpt-loop: unknown bridge verb %s\n' "$verb" >&2; usage; return 2 ;;
  esac
}

sub=${1:-}
shift || true
case "$sub" in
  init) cmd_init "$@" ;;
  consult) cmd_consult "$@" ;;
  dispatch) cmd_dispatch "$@" ;;
  record-findings) cmd_record_findings "$@" ;;
  record-result) cmd_record_result "$@" ;;
  record-worker-failure) cmd_record_worker_failure "$@" ;;
  next-round) cmd_next_round "$@" ;;
  status) cmd_status "$@" ;;
  bridge) cmd_bridge "$@" ;;
  -h|--help|'') usage; [ -n "$sub" ] || exit 2 ;;
  *) printf 'fm-chatgpt-loop: unknown subcommand %s\n' "$sub" >&2; usage; exit 2 ;;
esac
