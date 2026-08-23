#!/usr/bin/env bash
# Shared helpers for Firstmate T3 *primary* supervision (captain chat in T3 Code).
# Not the worker spawn backend. Script headers and docs/t3-primary-supervision.md
# own the operator contract; this file is source-only and has no side effects on source.
#
# Binding file state/.t3-primary-binding fields (one key=value per line):
#   thread_id=  cursor_session_id=  project_id=  bound_at=  bound_by=  seq=
set -u

FM_T3_PRIMARY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_T3_PRIMARY_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$FM_T3_PRIMARY_LIB_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_T3_PRIMARY_LIB_DIR/fm-session-lock-lib.sh"

fm_t3_primary_paths() {
  FM_T3_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_T3_PRIMARY_LIB_DIR/.." && pwd)}"
  FM_T3_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_T3_ROOT}}"
  FM_T3_STATE="${FM_STATE_OVERRIDE:-$FM_T3_HOME/state}"
  FM_T3_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_T3_HOME/config}"
  FM_T3_BINDING="$FM_T3_STATE/.t3-primary-binding"
  FM_T3_OPTIN="$FM_T3_CONFIG/t3-primary"
  # Park-owned paths: set here so bind/status callers share one resolver.
  # shellcheck disable=SC2034 # Consumed by fm-t3-primary-park.sh after sourcing this lib.
  FM_T3_PARK_OWNER="$FM_T3_STATE/.t3-primary-park-owner"
  # shellcheck disable=SC2034
  FM_T3_PARK_OWNER_LOCK="$FM_T3_STATE/.t3-primary-park-owner.lock"
  # shellcheck disable=SC2034
  FM_T3_PARK_LOCK="$FM_T3_STATE/.t3-primary-park.lock"
  # shellcheck disable=SC2034
  FM_T3_LOOP_FILE="$FM_T3_STATE/.t3-primary-loop"
  # shellcheck disable=SC2034
  FM_T3_BUDGET_FILE="$FM_T3_STATE/.turnend-t3-blocks"
}

fm_t3_primary_opt_in() {
  fm_t3_primary_paths
  [ -f "$FM_T3_OPTIN" ]
}

fm_t3_primary_binding_present() {
  fm_t3_primary_paths
  [ -f "$FM_T3_BINDING" ]
}

# True when a binding file exists and names a non-empty thread_id.
fm_t3_primary_binding_active() {
  local thread
  fm_t3_primary_paths
  [ -f "$FM_T3_BINDING" ] || return 1
  thread=$(fm_t3_primary_binding_get thread_id) || return 1
  [ -n "$thread" ]
}

fm_t3_primary_binding_get() {  # <key>
  local key=$1 line
  fm_t3_primary_paths
  [ -f "$FM_T3_BINDING" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) printf '%s\n' "${line#"$key="}"; return 0 ;;
    esac
  done < "$FM_T3_BINDING"
  return 1
}

fm_t3_primary_cli() {
  command -v t3cli >/dev/null 2>&1
}

# Print auth JSON on stdout; return 0 only when authenticated=true.
fm_t3_primary_auth_ok() {
  local out
  fm_t3_primary_cli || return 1
  out=$(t3cli auth status --format json 2>/dev/null) || out=$(t3cli auth status 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e '.authenticated == true' >/dev/null 2>&1
}

# Print session.status for a thread, or empty on failure.
fm_t3_primary_thread_status() {  # <thread-id>
  local thread=$1 out
  [ -n "$thread" ] || return 1
  fm_t3_primary_cli || return 1
  out=$(t3cli show --thread "$thread" --format json 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '.session.status // .status // empty' 2>/dev/null
}

# Wait until status is ready, or return 1 on timeout / error / deleted.
# Stand down (return 2) if status becomes running before ready while waiting
# for an inject window that must not queue behind a captain turn: callers that
# already know the wake is ours may pass allow-running=0 (default).
fm_t3_primary_wait_ready() {  # <thread-id> [timeout-seconds]
  local thread=$1 timeout=${2:-60} elapsed=0 status
  case "$timeout" in ''|*[!0-9]*) timeout=60 ;; esac
  while [ "$elapsed" -lt "$timeout" ]; do
    status=$(fm_t3_primary_thread_status "$thread") || return 1
    case "$status" in
      ready) return 0 ;;
      running|starting)
        # Another turn is active - do not send (queued inject hazard).
        return 2
        ;;
      error|'') return 1 ;;
    esac
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

# Resolve Cursor conversation / resume id from the environment.
fm_t3_primary_cursor_session_id() {
  local sid
  sid=${CURSOR_CONVERSATION_ID:-}
  if [ -z "$sid" ] && [ -n "${CURSOR_AGENT:-}" ]; then
    # Best-effort: some hosts only expose resume on the process argv.
    sid=$(ps -p "$$" -o args= 2>/dev/null | sed -n 's/.*--resume=\([A-Za-z0-9-][A-Za-z0-9-]*\).*/\1/p' | head -1)
  fi
  # Walk parents for --resume= when not in env (T3 often launches agent --resume=).
  if [ -z "$sid" ]; then
    local pid=$$ ppid args
    while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ]; do
      args=$(ps -p "$pid" -o args= 2>/dev/null || true)
      sid=$(printf '%s' "$args" | sed -n 's/.*--resume=\([A-Za-z0-9-][A-Za-z0-9-]*\).*/\1/p' | head -1)
      [ -n "$sid" ] && break
      ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      pid=$ppid
    done
  fi
  printf '%s' "$sid"
}

# Optional explicit thread id from config/t3-primary (first non-comment line that
# looks like a uuid, or thread_id=<uuid>).
fm_t3_primary_config_thread_id() {
  local line
  fm_t3_primary_paths
  [ -f "$FM_T3_OPTIN" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
      thread_id=*) printf '%s\n' "${line#thread_id=}"; return 0 ;;
      *[!A-Za-z0-9-]*) continue ;;
    esac
    case "$line" in
      [0-9a-fA-F]*-*) printf '%s\n' "$line"; return 0 ;;
    esac
  done < "$FM_T3_OPTIN"
  return 1
}

# Resolve project root for t3cli list: FM_HOME when it is a git checkout, else FM_ROOT.
fm_t3_primary_project_root() {
  fm_t3_primary_paths
  if git -C "$FM_T3_HOME" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$FM_T3_HOME" rev-parse --show-toplevel
    return 0
  fi
  printf '%s\n' "$FM_T3_ROOT"
}

# Match cursor session id to exactly one T3 thread via assistantMessageId.
# Prints thread_id on success.
fm_t3_primary_resolve_thread_by_session() {  # <cursor-session-id> [project-root]
  local sid=$1 project=${2:-} ids count
  [ -n "$sid" ] || return 1
  fm_t3_primary_cli || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [ -n "$project" ] || project=$(fm_t3_primary_project_root)
  ids=$(t3cli list --project "$project" --format json 2>/dev/null \
    | jq -r --arg sid "$sid" '
        map(select((.latestTurn.assistantMessageId // "") | contains($sid)) | .id)
        | .[]
      ' 2>/dev/null) || return 1
  count=$(printf '%s\n' "$ids" | grep -c . 2>/dev/null || printf 0)
  [ "$count" = 1 ] || return 1
  printf '%s\n' "$ids" | head -1
}

# Encode an operational follow-up body for t3cli send.
fm_t3_primary_encode_followup() {  # <kind> <body> -> stdout
  local kind=$1 body=$2 encoded
  fm_operational_input_encode "$kind" "$body" encoded || return 1
  printf '%s' "$encoded"
}

# Send without --force. Returns t3cli exit status.
fm_t3_primary_send() {  # <thread-id> <message>
  local thread=$1 message=$2
  [ -n "$thread" ] && [ -n "$message" ] || return 2
  fm_t3_primary_cli || return 1
  t3cli send --thread "$thread" --format json -- "$message"
}

# Write binding atomically. Args via env-style: thread_id cursor_session_id ...
fm_t3_primary_binding_write() {  # <thread_id> <cursor_session_id> <bound_by> [project_id]
  local thread=$1 session=$2 bound_by=$3 project_id=${4-} seq tmp
  fm_t3_primary_paths
  mkdir -p "$FM_T3_STATE" || return 1
  seq=$(fm_t3_primary_binding_get seq 2>/dev/null || printf 0)
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  seq=$((seq + 1))
  tmp="$FM_T3_BINDING.tmp.$$"
  {
    printf 'thread_id=%s\n' "$thread"
    printf 'cursor_session_id=%s\n' "$session"
    [ -n "$project_id" ] && printf 'project_id=%s\n' "$project_id"
    printf 'bound_at=%s\n' "$(date +%s)"
    printf 'bound_by=%s\n' "$bound_by"
    printf 'seq=%s\n' "$seq"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$FM_T3_BINDING"
}

fm_t3_primary_binding_clear() {
  fm_t3_primary_paths
  rm -f "$FM_T3_BINDING"
}

# Preflight for park/inject: cli + auth + show thread.
fm_t3_primary_preflight() {  # <thread-id>
  local thread=$1 status
  fm_t3_primary_cli || { printf 't3cli missing\n'; return 1; }
  fm_t3_primary_auth_ok || { printf 't3cli not authenticated\n'; return 1; }
  status=$(fm_t3_primary_thread_status "$thread") || { printf 'thread not found or show failed\n'; return 1; }
  case "$status" in
    ready|running|starting) return 0 ;;
    *) printf 'thread status=%s\n' "$status"; return 1 ;;
  esac
}
