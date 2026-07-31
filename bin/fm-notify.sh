#!/usr/bin/env bash
# Emit Firstmate's optional, transport-neutral task lifecycle notification.
#
# Configuration:
#   - The effective home is FM_HOME, then FM_ROOT_OVERRIDE, then the tracked root.
#   - FM_CONFIG_OVERRIDE may select an alternate configuration directory.
#   - config/notification-hook contains exactly one absolute executable path.
#   - The file is a path, not a command: no arguments, quoting syntax, variable
#     expansion, or shell evaluation is accepted.
#   - An absent configuration file disables notifications silently.
#
# Interface:
#   fm-notify.sh status <task-id>
#     Read the task's current status and emit task.ready only at the delivery-mode
#     ready boundary: any scout done event, direct-PR PR readiness, local-only
#     branch readiness, or a no-mistakes PR whose checks are green.
#   fm-notify.sh completed <task-id>
#     Emit task.completed after the lifecycle owner has formally completed the
#     task. Callers must establish that lifecycle truth before invoking this path.
#
# Hook contract:
#   - The executable receives one UTF-8 firstmate.notification.v1 JSON object on
#     standard input and no arguments.
#   - Payloads are at most 512 bytes. task_id and project are privacy-safe slugs
#     of at most 64 bytes; event_id is a stable SHA-256 identity derived only from
#     schema, project, task id, kind, and event; no prompt, status prose, path,
#     endpoint, credential, or environment value is forwarded.
#   - FM_NOTIFICATION_TIMEOUT_SECS is a positive integer timeout in seconds and
#     defaults to 5. Invalid values use the default; values above 60 clamp to 60.
#   - Hook output is discarded. Absence, malformed configuration, timeout,
#     execution failure, or payload-construction failure is non-fatal and exits 0.
#   - Bounded diagnostics use fixed reason tokens in
#     state/notification-hook.log, never hook output, configured paths, or
#     environment values. The mode-0600 log is capped by retaining its newest
#     200 lines whenever it exceeds 65536 bytes.
#
# Usage: fm-notify.sh <status|completed> <task-id>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
HOOK_CONFIG="$CONFIG/notification-hook"
DIAG_LOG="$STATE/notification-hook.log"
SCHEMA=firstmate.notification.v1
PAYLOAD_MAX_BYTES=512

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fm_notify_slug_valid() {  # <value>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

fm_notify_diag() {  # <fixed-reason> <event> <task-id>
  local reason=$1 event=${2:-unknown} task=${3:-unknown} tmp size
  fm_notify_slug_valid "$task" || task=unknown
  case "$event" in task.ready|task.completed) ;; *) event=unknown ;; esac
  case "$reason" in
    config-unreadable|config-malformed|hook-not-executable|hash-unavailable|payload-invalid|hook-timeout|hook-failed) ;;
    *) reason=internal-error ;;
  esac
  mkdir -p "$STATE" 2>/dev/null || return 0
  [ ! -L "$DIAG_LOG" ] || return 0
  umask 077
  printf '%s event=%s task=%s result=%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf unknown)" \
    "$event" "$task" "$reason" >> "$DIAG_LOG" 2>/dev/null || return 0
  chmod 0600 "$DIAG_LOG" 2>/dev/null || true
  size=$(LC_ALL=C wc -c < "$DIAG_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -le 65536 ] && return 0
  tmp="$DIAG_LOG.tmp.$$"
  if tail -n 200 "$DIAG_LOG" > "$tmp" 2>/dev/null \
    && chmod 0600 "$tmp" 2>/dev/null \
    && mv "$tmp" "$DIAG_LOG" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
}

FM_NOTIFY_HOOK=
fm_notify_load_hook() {
  local bytes lines hook
  [ -e "$HOOK_CONFIG" ] || return 1
  [ -f "$HOOK_CONFIG" ] || {
    fm_notify_diag config-malformed unknown unknown
    return 2
  }
  bytes=$(LC_ALL=C wc -c < "$HOOK_CONFIG" 2>/dev/null | tr -d '[:space:]') || {
    fm_notify_diag config-unreadable unknown unknown
    return 2
  }
  case "$bytes" in ''|*[!0-9]*) bytes=4097 ;; esac
  [ "$bytes" -le 4096 ] || {
    fm_notify_diag config-malformed unknown unknown
    return 2
  }
  lines=$(awk 'END { print NR + 0 }' "$HOOK_CONFIG" 2>/dev/null) || {
    fm_notify_diag config-unreadable unknown unknown
    return 2
  }
  [ "$lines" -eq 1 ] || {
    fm_notify_diag config-malformed unknown unknown
    return 2
  }
  IFS= read -r hook < "$HOOK_CONFIG" || [ -n "$hook" ] || {
    fm_notify_diag config-unreadable unknown unknown
    return 2
  }
  case "$hook" in
    /*) ;;
    *) fm_notify_diag config-malformed unknown unknown; return 2 ;;
  esac
  case "$hook" in *$'\r'*|*$'\n'*) fm_notify_diag config-malformed unknown unknown; return 2 ;; esac
  [ -f "$hook" ] && [ -x "$hook" ] || {
    fm_notify_diag hook-not-executable unknown unknown
    return 2
  }
  FM_NOTIFY_HOOK=$hook
  return 0
}

fm_notify_meta_value() {  # <meta> <key>
  local meta=$1 key=$2
  sed -n "s/^${key}=//p" "$meta" 2>/dev/null | tail -1
}

fm_notify_project_slug() {  # <project-value>
  local project=$1
  project=${project%/}
  project=${project##*/}
  project=$(printf '%s' "$project" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
  project=${project:0:64}
  [ -n "$project" ] || project=unknown
  printf '%s' "$project"
}

fm_notify_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | sed 's/^.*= //'
  else
    return 1
  fi
}

FM_NOTIFY_TASK=
FM_NOTIFY_PROJECT=
FM_NOTIFY_KIND=
FM_NOTIFY_MODE=
fm_notify_load_task() {  # <task-id>
  local id=$1 meta project kind mode
  fm_notify_slug_valid "$id" || return 1
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  project=$(fm_notify_meta_value "$meta" project)
  kind=$(fm_notify_meta_value "$meta" kind)
  mode=$(fm_notify_meta_value "$meta" mode)
  [ -n "$kind" ] || kind=ship
  [ -n "$mode" ] || mode=no-mistakes
  case "$kind" in ship|scout) ;; *) return 1 ;; esac
  case "$mode" in no-mistakes|direct-PR|local-only) ;; *) [ "$kind" = scout ] || return 1 ;; esac
  FM_NOTIFY_TASK=$id
  FM_NOTIFY_PROJECT=$(fm_notify_project_slug "$project")
  FM_NOTIFY_KIND=$kind
  FM_NOTIFY_MODE=$mode
}

fm_notify_status_ready() {  # <task-id>
  local status line verb
  status="$STATE/$1.status"
  [ -f "$status" ] && [ ! -L "$status" ] || return 1
  line=$(last_status_line "$status")
  verb=$(status_line_verb "$line")
  [ "$verb" = "done" ] || return 1
  if [ "$FM_NOTIFY_KIND" = scout ]; then
    return 0
  fi
  case "$FM_NOTIFY_MODE" in
    local-only) printf '%s' "$line" | grep -qE '^done([^:]*)?:[[:space:]]+ready in branch fm/' ;;
    direct-PR) printf '%s' "$line" | grep -qE '^done([^:]*)?:[[:space:]]+PR https://[^[:space:]]+' ;;
    no-mistakes) printf '%s' "$line" | grep -qE '^done([^:]*)?:[[:space:]]+PR https://[^[:space:]]+ checks green([[:space:]]|$)' ;;
    *) return 1 ;;
  esac
}

fm_notify_timeout() {
  local timeout_secs=${FM_NOTIFICATION_TIMEOUT_SECS:-5}
  case "$timeout_secs" in ''|*[!0-9]*|0) timeout_secs=5 ;; esac
  [ "$timeout_secs" -le 60 ] || timeout_secs=60
  printf '%s' "$timeout_secs"
}

fm_notify_run_hook() {  # <hook> <timeout-secs>
  local hook=$1 timeout_secs=$2
  if command -v timeout >/dev/null 2>&1; then
    exec timeout --kill-after=1 "$timeout_secs" "$hook"
  elif command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout --kill-after=1 "$timeout_secs" "$hook"
  else
    # shellcheck disable=SC2016
    exec perl -e 'my $t = shift; my $pid = fork; exit 125 unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV; exit 126 } my $stop = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" "$hook"
  fi
}

fm_notify_emit() {  # <task.ready|task.completed>
  local event=$1 outcome identity event_id occurred payload bytes timeout_secs rc
  case "$event" in
    task.ready) outcome=ready ;;
    task.completed) outcome=completed ;;
    *) return 0 ;;
  esac
  identity=$(printf '%s\n%s\n%s\n%s\n%s' \
    "$SCHEMA" "$FM_NOTIFY_PROJECT" "$FM_NOTIFY_TASK" "$FM_NOTIFY_KIND" "$event")
  event_id=$(printf '%s' "$identity" | fm_notify_sha256) || {
    fm_notify_diag hash-unavailable "$event" "$FM_NOTIFY_TASK"
    return 0
  }
  case "$event_id" in ''|*[!0-9a-f]*) fm_notify_diag hash-unavailable "$event" "$FM_NOTIFY_TASK"; return 0 ;; esac
  occurred=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || occurred=1970-01-01T00:00:00Z
  payload=$(printf '{"schema":"%s","event_id":"%s","event":"%s","task_id":"%s","project":"%s","kind":"%s","outcome":"%s","occurred_at":"%s"}\n' \
    "$SCHEMA" "$event_id" "$event" "$FM_NOTIFY_TASK" "$FM_NOTIFY_PROJECT" \
    "$FM_NOTIFY_KIND" "$outcome" "$occurred")
  bytes=$(printf '%s\n' "$payload" | LC_ALL=C wc -c | tr -d '[:space:]')
  case "$bytes" in ''|*[!0-9]*) bytes=$((PAYLOAD_MAX_BYTES + 1)) ;; esac
  if [ "$bytes" -gt "$PAYLOAD_MAX_BYTES" ]; then
    fm_notify_diag payload-invalid "$event" "$FM_NOTIFY_TASK"
    return 0
  fi
  timeout_secs=$(fm_notify_timeout)
  printf '%s\n' "$payload" | (fm_notify_run_hook "$FM_NOTIFY_HOOK" "$timeout_secs") >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) ;;
    124|137) fm_notify_diag hook-timeout "$event" "$FM_NOTIFY_TASK" ;;
    *) fm_notify_diag hook-failed "$event" "$FM_NOTIFY_TASK" ;;
  esac
  return 0
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [ "$#" -ne 2 ]; then
  usage >&2
  exit 2
fi
COMMAND=$1
TASK_ID=$2
case "$COMMAND" in status|completed) ;; *) usage >&2; exit 2 ;; esac

fm_notify_load_hook
HOOK_RESULT=$?
[ "$HOOK_RESULT" -eq 0 ] || exit 0
fm_notify_load_task "$TASK_ID" || exit 0

case "$COMMAND" in
  status)
    fm_notify_status_ready "$TASK_ID" || exit 0
    fm_notify_emit task.ready
    ;;
  completed)
    fm_notify_emit task.completed
    ;;
esac
exit 0
