#!/usr/bin/env bash
# Native Orca supervised-worker primitives.
#
# This adapter is deliberately separate from the terminal adapter.  The native
# Run/Task/Dispatch ids own a supervised attempt; terminal handles and PTY
# details are only rebindable evidence.

FM_ORCA_SUPERVISED_AGENT_SET='claude codex cursor'

FM_ORCA_SUPERVISED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_backend_orca_supervised_control_value() {  # <field> (JSON arrives on stdin)
  node "$FM_ORCA_SUPERVISED_DIR/orca-supervised-json.js" "$1"
}

# shellcheck disable=SC2034 # capability globals are consumed by callers.
fm_backend_orca_supervised_capability_check() {  # <harness>
  local harness=${1:-} context
  # shellcheck disable=SC2034 # output globals are consumed by the caller.
  FM_ORCA_SUPERVISED_REASON=
  FM_ORCA_SUPERVISED_SCHEMA=
  # shellcheck disable=SC2034 # output global is consumed by the caller.
  FM_ORCA_SUPERVISED_COMMAND_COUNT=
  fm_backend_orca_runtime_check || {
    FM_ORCA_SUPERVISED_REASON='runtime-not-ready'
    return 1
  }
  case " $FM_ORCA_SUPERVISED_AGENT_SET " in
    *" $harness "*) ;;
    *) FM_ORCA_SUPERVISED_REASON="agent-$harness-not-supported"; return 1 ;;
  esac
  context=$(orca agent-context --json 2>/dev/null) || {
    FM_ORCA_SUPERVISED_REASON='agent-context-unavailable'
    return 1
  }
  if ! FM_ORCA_SUPERVISED_SCHEMA=$(printf '%s' "$context" | fm_backend_orca_supervised_control_value schema-version 2>/dev/null); then
    FM_ORCA_SUPERVISED_REASON='agent-context-invalid-json'
    return 1
  fi
  [ "$FM_ORCA_SUPERVISED_SCHEMA" = 1 ] || {
    FM_ORCA_SUPERVISED_REASON="unsupported-schema-${FM_ORCA_SUPERVISED_SCHEMA:-unknown}"
    return 1
  }
  # shellcheck disable=SC2034 # output global is consumed by the caller.
  FM_ORCA_SUPERVISED_COMMAND_COUNT=$(printf '%s' "$context" | node -e '
const fs = require("fs");
let d;
try { d = JSON.parse(fs.readFileSync(0, "utf8")); } catch (_) { process.exit(1); }
const r = d.result || d;
const commands = Array.isArray(r.commands) ? r.commands : [];
const wanted = {
  "orchestration run-create": ["objective"],
  "orchestration worker-start": ["task", "spec", "worktree", "agent", "terminal", "run"],
  "orchestration worker-show": ["dispatch"],
  "orchestration worker-read": ["dispatch", "source", "cursor", "limit"],
  "orchestration worker-abandon": ["dispatch"],
  "orchestration worker-stop": ["dispatch"],
  "orchestration worker-list": ["run"],
  "orchestration worker-release": ["dispatch"],
  "orchestration send": ["subject", "to", "body", "dispatch-id"],
  "orchestration check": ["run", "ack"],
  "terminal wait": ["terminal", "for", "timeout-ms"],
  "worktree ps": []
};
const seen = new Set();
for (const c of commands) {
  const name = Array.isArray(c.path) ? c.path.join(" ") : String(c.command || "");
  if (wanted[name]) {
    const flags = new Set(Array.isArray(c.flags) ? c.flags : []);
    if (wanted[name].every((f) => flags.has(f))) seen.add(name);
  }
}
const missing = Object.keys(wanted).filter((name) => !seen.has(name));
if (missing.length) { console.error("missing:" + missing.join(",")); process.exit(2); }
process.stdout.write(String(commands.length));
' 2>/dev/null) || {
    # shellcheck disable=SC2034 # output global is consumed by the caller.
    FM_ORCA_SUPERVISED_REASON='required-command-missing-or-malformed'
    return 1
  }
  return 0
}

# shellcheck disable=SC2034 # identity and read globals are consumed by callers.
fm_backend_orca_supervised_set_from_json() {  # <json> <prefix>
  local json=$1 prefix=${2:-} field value
  case "$prefix" in
    start|show)
      FM_ORCA_SUPERVISED_RUN_ID=
      FM_ORCA_SUPERVISED_TASK_ID=
      FM_ORCA_SUPERVISED_DISPATCH_ID=
      FM_ORCA_SUPERVISED_WORKER_ID=
      FM_ORCA_SUPERVISED_TERMINAL=
      FM_ORCA_SUPERVISED_TERMINAL_INCAR=
      FM_ORCA_SUPERVISED_PANE_KEY=
      FM_ORCA_SUPERVISED_WORKTREE_ID=
      FM_ORCA_SUPERVISED_WORKTREE_PATH=
      ;;
  esac
  case "$prefix" in
    show)
      FM_ORCA_SUPERVISED_EXACT_WORKER=
      FM_ORCA_SUPERVISED_WORKER_STATE=
      FM_ORCA_SUPERVISED_DISPATCH_STATUS=
      FM_ORCA_SUPERVISED_LIVENESS=
      FM_ORCA_SUPERVISED_NEXT_ACTION=
      FM_ORCA_SUPERVISED_OBSERVATION_STATUS=
      FM_ORCA_SUPERVISED_OWNED=
      FM_ORCA_SUPERVISED_SETTLED=
      ;;
    read)
      FM_ORCA_SUPERVISED_READ_SOURCE=
      FM_ORCA_SUPERVISED_READ_SOURCE_IDENTITY=
      FM_ORCA_SUPERVISED_READ_CURSOR=
      FM_ORCA_SUPERVISED_READ_COMPLETE=
      FM_ORCA_SUPERVISED_READ_CLIPPED=
      FM_ORCA_SUPERVISED_READ_EXACT=
      FM_ORCA_SUPERVISED_READ_SOURCE_CHANGED=
      FM_ORCA_SUPERVISED_READ_HAS_TRANSCRIPT=
      ;;
  esac
  for field in run-id task-id dispatch-id worker-id terminal-handle terminal-incarnation pane-key \
    worktree-id worktree-path exact-worker source source-identity next-cursor \
    content-complete clipping source-exact source-changed worker-state dispatch-status \
    liveness next-action observation-status owned settled has-transcript; do
    value=$(printf '%s' "$json" | fm_backend_orca_supervised_control_value "$field" 2>/dev/null || true)
    case "$prefix:$field" in
      start:run-id|show:run-id) FM_ORCA_SUPERVISED_RUN_ID=$value ;;
      start:task-id|show:task-id) FM_ORCA_SUPERVISED_TASK_ID=$value ;;
      start:dispatch-id|show:dispatch-id) FM_ORCA_SUPERVISED_DISPATCH_ID=$value ;;
      start:worker-id|show:worker-id) FM_ORCA_SUPERVISED_WORKER_ID=$value ;;
      start:terminal-handle|show:terminal-handle) FM_ORCA_SUPERVISED_TERMINAL=$value ;;
      start:terminal-incarnation|show:terminal-incarnation) FM_ORCA_SUPERVISED_TERMINAL_INCAR=$value ;;
      start:pane-key|show:pane-key) FM_ORCA_SUPERVISED_PANE_KEY=$value ;;
      start:worktree-id|show:worktree-id) FM_ORCA_SUPERVISED_WORKTREE_ID=$value ;;
      start:worktree-path|show:worktree-path) FM_ORCA_SUPERVISED_WORKTREE_PATH=$value ;;
      show:exact-worker) FM_ORCA_SUPERVISED_EXACT_WORKER=$value ;;
      read:source) FM_ORCA_SUPERVISED_READ_SOURCE=$value ;;
      read:source-identity) FM_ORCA_SUPERVISED_READ_SOURCE_IDENTITY=$value ;;
      read:next-cursor) FM_ORCA_SUPERVISED_READ_CURSOR=$value ;;
      read:content-complete) FM_ORCA_SUPERVISED_READ_COMPLETE=$value ;;
      read:clipping) FM_ORCA_SUPERVISED_READ_CLIPPED=$value ;;
      read:source-exact) FM_ORCA_SUPERVISED_READ_EXACT=$value ;;
      read:source-changed) FM_ORCA_SUPERVISED_READ_SOURCE_CHANGED=$value ;;
      read:has-transcript) FM_ORCA_SUPERVISED_READ_HAS_TRANSCRIPT=$value ;;
      show:worker-state) FM_ORCA_SUPERVISED_WORKER_STATE=$value ;;
      show:dispatch-status) FM_ORCA_SUPERVISED_DISPATCH_STATUS=$value ;;
      show:liveness) FM_ORCA_SUPERVISED_LIVENESS=$value ;;
      show:next-action) FM_ORCA_SUPERVISED_NEXT_ACTION=$value ;;
      show:observation-status) FM_ORCA_SUPERVISED_OBSERVATION_STATUS=$value ;;
      show:owned) FM_ORCA_SUPERVISED_OWNED=$value ;;
      show:settled) FM_ORCA_SUPERVISED_SETTLED=$value ;;
    esac
  done
}

fm_backend_orca_supervised_run_create() {  # <objective>
  local objective=${1:-} out run_id
  [ -n "$objective" ] || { echo 'error: native Orca Run objective is empty' >&2; return 1; }
  out=$(orca orchestration run-create --objective "$objective" --json) || return 1
  fm_backend_orca_json_ok <<<"$out" || return 1
  run_id=$(printf '%s' "$out" | fm_backend_orca_supervised_control_value run-id 2>/dev/null || true)
  [ -n "$run_id" ] || { echo 'error: native Orca Run receipt omitted run id' >&2; return 1; }
  printf '%s' "$run_id"
}

fm_backend_orca_supervised_worker_start() {  # <run-id> <spec> <worktree-id> <agent> [model] [effort] [task-id] [retry-of]
  local run_id=$1 spec=$2 worktree_id=$3 agent=$4 model=${5:-} effort=${6:-} task_id=${7:-} retry_of=${8:-} out
  local -a args=(orca orchestration worker-start --worktree "id:$worktree_id" --agent "$agent" --run "$run_id" --setup skip --json)
  if [ -n "$task_id" ]; then
    args+=(--task "$task_id")
  else
    args+=(--spec "$spec")
  fi
  [ -z "$retry_of" ] || args+=(--retry-of "$retry_of")
  [ -z "$model" ] || args+=(--model "$model")
  [ -z "$effort" ] || { [ -n "$model" ] || { echo 'error: native Orca effort requires a model' >&2; return 1; }; args+=(--effort "$effort"); }
  out=$("${args[@]}") || return 1
  fm_backend_orca_json_ok <<<"$out" || return 1
  fm_backend_orca_supervised_set_from_json "$out" start
  [ -n "${FM_ORCA_SUPERVISED_TASK_ID:-}" ] || return 1
  [ -n "${FM_ORCA_SUPERVISED_DISPATCH_ID:-}" ] || return 1
  [ -n "${FM_ORCA_SUPERVISED_RUN_ID:-}" ] || FM_ORCA_SUPERVISED_RUN_ID=$run_id
  [ -n "${FM_ORCA_SUPERVISED_RUN_ID:-}" ] || return 1
  [ -n "${FM_ORCA_SUPERVISED_TERMINAL:-}" ] || return 1
  [ -n "${FM_ORCA_SUPERVISED_TERMINAL_INCAR:-}" ] || return 1
  [ -n "${FM_ORCA_SUPERVISED_PANE_KEY:-}" ] || return 1
  [ -n "${FM_ORCA_SUPERVISED_WORKTREE_ID:-}" ] || FM_ORCA_SUPERVISED_WORKTREE_ID=$worktree_id
  [ "$FM_ORCA_SUPERVISED_WORKTREE_ID" = "$worktree_id" ] || return 1
}

fm_backend_orca_supervised_worker_show() {  # <dispatch-id>
  local dispatch_id=$1 out
  [ -n "$dispatch_id" ] || return 1
  out=$(orca orchestration worker-show --dispatch "$dispatch_id" --json) || return 1
  fm_backend_orca_json_ok <<<"$out" || return 1
  FM_ORCA_SUPERVISED_SHOW_JSON=$out
  fm_backend_orca_supervised_set_from_json "$out" show
  [ "$FM_ORCA_SUPERVISED_DISPATCH_ID" = "$dispatch_id" ] || return 1
  printf '%s' "$out"
}

fm_backend_orca_supervised_dispatch_from_target() {  # <dispatch:id>
  local target=${1:-} dispatch
  case "$target" in
    dispatch:*) dispatch=${target#dispatch:} ;;
    *) return 1 ;;
  esac
  [ -n "$dispatch" ] || return 1
  case "$dispatch" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
  printf '%s' "$dispatch"
}

fm_backend_orca_supervised_send_dispatch() {  # <dispatch-id> <body>
  local dispatch_id=$1 body=$2
  [ -n "$dispatch_id" ] && [ -n "$body" ] || return 1
  fm_backend_orca_run_json orca orchestration send --to "dispatch:$dispatch_id" \
    --subject 'Firstmate task instruction' --body "$body" --type dispatch \
    --dispatch-id "$dispatch_id" --json
}

fm_backend_orca_supervised_worker_stop() {  # <dispatch-id|dispatch:id>
  local dispatch_id=$1
  case "$dispatch_id" in dispatch:*) dispatch_id=${dispatch_id#dispatch:} ;; esac
  [ -n "$dispatch_id" ] || return 1
  fm_backend_orca_run_json orca orchestration worker-stop --dispatch "$dispatch_id" --json
}

fm_backend_orca_supervised_agent_state() {  # <dispatch:id>
  local target=$1 dispatch state liveness
  dispatch=$(fm_backend_orca_supervised_dispatch_from_target "$target") || { printf 'unverified'; return 0; }
  fm_backend_orca_supervised_worker_show "$dispatch" >/dev/null 2>&1 || { printf 'unverified'; return 0; }
  [ "$FM_ORCA_SUPERVISED_EXACT_WORKER" = true ] || { printf 'ambiguous'; return 0; }
  state=$(printf '%s:%s' "${FM_ORCA_SUPERVISED_WORKER_STATE:-}" "${FM_ORCA_SUPERVISED_DISPATCH_STATUS:-}" | tr '[:upper:]' '[:lower:]')
  liveness=$(printf '%s' "${FM_ORCA_SUPERVISED_LIVENESS:-}" | tr '[:upper:]' '[:lower:]')
  case "$state:$liveness" in
    *failed*:*|*cancelled*:*|*completed*:*|*succeeded*:*|*settled*:*|*done*:*|*:exited|*:stopped) printf 'dead' ;;
    *unknown*|*ambiguous*|*unverifiable*|*uncertain*) printf 'ambiguous' ;;
    *running*:*|*starting*:*|*working*:*|*active*:*|*ready*:*|*:live) printf 'alive' ;;
    *) printf 'unverified' ;;
  esac
}

fm_backend_orca_supervised_identity_matches() {  # <meta-file> <show-json>
  local meta=$1 json=$2 id dispatch task run worker wt wt_path exact
  id=$(fm_meta_get "$meta" endpoint_task_id)
  dispatch=$(fm_meta_get "$meta" orca_dispatch_id)
  task=$(fm_meta_get "$meta" orca_task_id)
  run=$(fm_meta_get "$meta" orca_run_id)
  worker=$(fm_meta_get "$meta" orca_worker_id)
  wt=$(fm_meta_get "$meta" orca_worktree_id)
  wt_path=$(fm_meta_get "$meta" worktree)
  [ -n "$id" ] && [ -n "$dispatch" ] && [ -n "$task" ] && [ -n "$run" ] && [ -n "$worker" ] && [ -n "$wt" ] && [ -n "$wt_path" ] || return 1
  fm_backend_orca_supervised_set_from_json "$json" show
  [ "$FM_ORCA_SUPERVISED_DISPATCH_ID" = "$dispatch" ] || return 1
  [ "$FM_ORCA_SUPERVISED_TASK_ID" = "$task" ] || return 1
  [ "$FM_ORCA_SUPERVISED_RUN_ID" = "$run" ] || return 1
  [ "$FM_ORCA_SUPERVISED_WORKER_ID" = "$worker" ] || return 1
  [ "$FM_ORCA_SUPERVISED_WORKTREE_ID" = "$wt" ] || return 1
  [ "$FM_ORCA_SUPERVISED_WORKTREE_PATH" = "$wt_path" ] || return 1
  exact=$FM_ORCA_SUPERVISED_EXACT_WORKER
  [ "$exact" = true ] || return 1
  return 0
}

fm_backend_orca_supervised_rebind_meta() {  # <meta-file>
  local meta=$1 dispatch show tmp lock acquired=0
  local terminal incarnation pane worktree_id worktree_path
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  dispatch=$(fm_meta_get "$meta" orca_dispatch_id)
  fm_backend_orca_supervised_worker_show "$dispatch" >/dev/null || return 1
  show=$FM_ORCA_SUPERVISED_SHOW_JSON
  fm_backend_orca_supervised_identity_matches "$meta" "$show" || return 1
  terminal=$FM_ORCA_SUPERVISED_TERMINAL
  incarnation=$FM_ORCA_SUPERVISED_TERMINAL_INCAR
  pane=$FM_ORCA_SUPERVISED_PANE_KEY
  worktree_id=$FM_ORCA_SUPERVISED_WORKTREE_ID
  worktree_path=$FM_ORCA_SUPERVISED_WORKTREE_PATH
  [ -n "$terminal" ] && [ -n "$incarnation" ] && [ -n "$pane" ] || return 1
  [ "$worktree_id" = "$(fm_meta_get "$meta" orca_worktree_id)" ] || return 1
  [ "$worktree_path" = "$(fm_meta_get "$meta" worktree)" ] || return 1
  if declare -F fm_meta_lock_path >/dev/null 2>&1 && declare -F fm_lock_acquire_wait >/dev/null 2>&1; then
    lock=$(fm_meta_lock_path "$meta") || return 1
    fm_lock_acquire_wait "$lock" || return 1
    acquired=1
  fi
  tmp="$meta.rebind.${BASHPID:-$$}"
  if ! awk -F= '$1 != "terminal" && $1 != "orca_terminal_incarnation" && $1 != "orca_pane_key"' "$meta" >"$tmp"; then
    rm -f "$tmp"
    [ "$acquired" = 0 ] || fm_lock_release "$lock" || true
    return 1
  fi
  if ! {
    printf 'terminal=%s\n' "$terminal"
    printf 'orca_terminal_incarnation=%s\n' "$incarnation"
    printf 'orca_pane_key=%s\n' "$pane"
  } >>"$tmp"; then
    rm -f "$tmp"
    [ "$acquired" = 0 ] || fm_lock_release "$lock" || true
    return 1
  fi
  if declare -F fm_backlog_atomic_transition >/dev/null 2>&1; then
    fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "${STATE:-${meta%/*}}" || {
      rm -f "$tmp"
      [ "$acquired" = 0 ] || fm_lock_release "$lock" || true
      return 1
    }
  else
    mv -f "$tmp" "$meta" || {
      rm -f "$tmp"
      [ "$acquired" = 0 ] || fm_lock_release "$lock" || true
      return 1
    }
  fi
  rm -f "$tmp"
  [ "$acquired" = 0 ] || fm_lock_release "$lock" || return 1
  printf '%s' "$terminal"
}

fm_backend_orca_supervised_wait_first_turn() {  # <dispatch-id>
  local dispatch_id=$1 polls=${FM_ORCA_FIRST_TURN_POLLS:-40} interval=${FM_ORCA_FIRST_TURN_INTERVAL:-0.5}
  local i=0 text tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-orca-first-turn.XXXXXX") || return 1
  while [ "$i" -lt "$polls" ]; do
    if fm_backend_orca_supervised_worker_read "$dispatch_id" '' 40 >"$tmp" 2>/dev/null; then
      text=$(<"$tmp")
      if [ "$FM_ORCA_SUPERVISED_READ_SOURCE" = transcript ] &&
        [ "$FM_ORCA_SUPERVISED_READ_HAS_TRANSCRIPT" = true ] &&
        [ "$FM_ORCA_SUPERVISED_READ_EXACT" = true ] &&
        [ "$FM_ORCA_SUPERVISED_READ_COMPLETE" = true ] &&
        [ "$FM_ORCA_SUPERVISED_READ_CLIPPED" != true ] && [ -n "$text" ]; then
        rm -f "$tmp"
        return 0
      fi
    fi
    i=$((i + 1))
    [ "$i" -ge "$polls" ] || sleep "$interval"
  done
  rm -f "$tmp"
  return 1
}

fm_backend_orca_supervised_worker_read() {  # <dispatch-id> [cursor] [limit]
  local dispatch_id=$1 cursor=${2:-} limit=${3:-40} out
  local -a args=(orca orchestration worker-read --dispatch "$dispatch_id" --source auto --limit "$limit" --json)
  [ -z "$cursor" ] || args+=(--cursor "$cursor")
  out=$("${args[@]}") || return 1
  fm_backend_orca_json_ok <<<"$out" || return 1
  fm_backend_orca_supervised_set_from_json "$out" read
  if [ "$FM_ORCA_SUPERVISED_READ_SOURCE_CHANGED" = true ]; then
    return 2
  fi
  printf '%s' "$out" | node "$FM_ORCA_SUPERVISED_DIR/orca-supervised-json.js" text
  if [ "$FM_ORCA_SUPERVISED_READ_SOURCE" != transcript ] ||
    [ "$FM_ORCA_SUPERVISED_READ_CLIPPED" = true ] ||
    [ "$FM_ORCA_SUPERVISED_READ_COMPLETE" != true ]; then
    printf '%s' $'\n[orca: terminal fallback or clipped output; transcript completeness is unproven]'
  fi
}

fm_backend_orca_supervised_wait() {  # <terminal> <exit|tui-idle> <timeout-ms>
  local terminal=$1 condition=$2 timeout=${3:-1000}
  orca terminal wait --terminal "$terminal" --for "$condition" --timeout-ms "$timeout" --json
}

fm_backend_orca_supervised_send() {  # <run-id> <dispatch-id> <task-id> <body>
  local run_id=$1 dispatch_id=$2 task_id=$3 body=$4
  [ -n "$run_id" ] && [ -n "$dispatch_id" ] && [ -n "$task_id" ] && [ -n "$body" ] || return 1
  fm_backend_orca_run_json orca orchestration send --run "$run_id" --to "dispatch:$dispatch_id" \
    --subject 'Firstmate task instruction' --body "$body" --type status --task-id "$task_id" \
    --dispatch-id "$dispatch_id" --json
}

fm_backend_orca_supervised_abandon() {  # <dispatch-id|dispatch:id>
  local dispatch_id=$1
  case "$dispatch_id" in dispatch:*) dispatch_id=${dispatch_id#dispatch:} ;; esac
  [ -n "$dispatch_id" ] || return 1
  fm_backend_orca_run_json orca orchestration worker-abandon --dispatch "$dispatch_id" --json
}

fm_backend_orca_supervised_dispatch_owned() {  # <dispatch-id> <run-id> <task-id> <worker-id> <worktree-id> <worktree-path>
  local dispatch=$1 run=$2 task=$3 worker=$4 worktree_id=$5 worktree_path=$6
  fm_backend_orca_supervised_worker_show "$dispatch" >/dev/null || return 1
  [ "$FM_ORCA_SUPERVISED_DISPATCH_ID" = "$dispatch" ] || return 1
  [ "$FM_ORCA_SUPERVISED_RUN_ID" = "$run" ] || return 1
  [ "$FM_ORCA_SUPERVISED_TASK_ID" = "$task" ] || return 1
  [ "$FM_ORCA_SUPERVISED_WORKER_ID" = "$worker" ] || return 1
  [ "$FM_ORCA_SUPERVISED_WORKTREE_ID" = "$worktree_id" ] || return 1
  [ "$FM_ORCA_SUPERVISED_WORKTREE_PATH" = "$worktree_path" ] || return 1
  [ "$FM_ORCA_SUPERVISED_EXACT_WORKER" = true ] || return 1
  [ "$FM_ORCA_SUPERVISED_OWNED" = true ] || return 1
}

fm_backend_orca_supervised_dispatch_release() {  # <dispatch-id> <run-id> <task-id> <worker-id> <worktree-id> <worktree-path>
  local dispatch=$1
  shift
  fm_backend_orca_supervised_dispatch_owned "$dispatch" "$@" || {
    echo 'error: native Orca release refused: Dispatch identity or coordinator ownership is unproven' >&2
    return 1
  }
  [ "$FM_ORCA_SUPERVISED_SETTLED" = true ] || {
    echo 'error: native Orca release refused: worker is not settled' >&2
    return 1
  }
  fm_backend_orca_run_json orca orchestration worker-release --dispatch "$dispatch" --json
}

fm_backend_orca_supervised_owned() {  # <meta-file>
  local meta=$1
  fm_backend_orca_supervised_dispatch_owned \
    "$(fm_meta_get "$meta" orca_dispatch_id)" \
    "$(fm_meta_get "$meta" orca_run_id)" \
    "$(fm_meta_get "$meta" orca_task_id)" \
    "$(fm_meta_get "$meta" orca_worker_id)" \
    "$(fm_meta_get "$meta" orca_worktree_id)" \
    "$(fm_meta_get "$meta" worktree)"
}

fm_backend_orca_supervised_release() {  # <meta-file>
  local meta=$1 dispatch
  dispatch=$(fm_meta_get "$meta" orca_dispatch_id)
  fm_backend_orca_supervised_dispatch_release "$dispatch" \
    "$(fm_meta_get "$meta" orca_run_id)" \
    "$(fm_meta_get "$meta" orca_task_id)" \
    "$(fm_meta_get "$meta" orca_worker_id)" \
    "$(fm_meta_get "$meta" orca_worktree_id)" \
    "$(fm_meta_get "$meta" worktree)"
}
