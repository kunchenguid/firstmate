#!/usr/bin/env bash
# Establish, verify, or clear Firstmate T3 primary binding (captain thread id).
#
# Usage:
#   fm-t3-primary-bind.sh                 # bind/verify (opt-in or refresh)
#   fm-t3-primary-bind.sh --verify        # verify existing binding only
#   fm-t3-primary-bind.sh --clear         # remove binding
#   fm-t3-primary-bind.sh --status        # print binding fields or ABSENT
#   fm-t3-primary-bind.sh --thread <id>   # bind explicit thread id
#
# Opt-in: local gitignored config/t3-primary must exist (or an existing binding
# is being refreshed). Absent opt-in with no binding → exit 0, print inactive.
# When opt-in is present and bind cannot resolve a unique thread, exit 1 (fail
# closed). See docs/t3-primary-supervision.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-t3-primary-lib.sh
. "$SCRIPT_DIR/fm-t3-primary-lib.sh"

MODE=bind
EXPLICIT_THREAD=

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --verify) MODE=verify; shift ;;
    --clear) MODE=clear; shift ;;
    --status) MODE=status; shift ;;
    --thread)
      [ "$#" -gt 1 ] || { echo "error: --thread requires a value" >&2; exit 2; }
      EXPLICIT_THREAD=$2
      shift 2
      ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

fm_t3_primary_paths

case "$MODE" in
  clear)
    fm_t3_primary_binding_clear
    printf 't3-primary: binding cleared\n'
    exit 0
    ;;
  status)
    if ! fm_t3_primary_binding_present; then
      printf 'ABSENT\n'
      exit 0
    fi
    cat "$FM_T3_BINDING"
    exit 0
    ;;
  verify)
    if ! fm_t3_primary_binding_active; then
      printf 't3-primary: no active binding\n' >&2
      exit 1
    fi
    thread=$(fm_t3_primary_binding_get thread_id)
    if ! err=$(fm_t3_primary_preflight "$thread" 2>&1); then
      printf 't3-primary: preflight failed: %s\n' "$err" >&2
      exit 1
    fi
    session=$(fm_t3_primary_binding_get cursor_session_id 2>/dev/null || true)
    if [ -n "$session" ]; then
      matched=$(fm_t3_primary_resolve_thread_by_session "$session" 2>/dev/null || true)
      if [ -n "$matched" ] && [ "$matched" != "$thread" ]; then
        printf 't3-primary: conversation now maps to %s, binding has %s\n' "$matched" "$thread" >&2
        exit 1
      fi
    fi
    printf 't3-primary: binding ok thread=%s\n' "$thread"
    exit 0
    ;;
esac

# MODE=bind
if ! fm_t3_primary_opt_in && ! fm_t3_primary_binding_present && [ -z "$EXPLICIT_THREAD" ]; then
  printf 't3-primary: inactive (no config/t3-primary and no binding)\n'
  exit 0
fi

if ! fm_t3_primary_opt_in && [ -z "$EXPLICIT_THREAD" ] && fm_t3_primary_binding_present; then
  # Refresh path without opt-in file: verify only.
  exec "$0" --verify
fi

if ! fm_t3_primary_cli; then
  printf 't3-primary: t3cli not on PATH\n' >&2
  exit 1
fi
if ! fm_t3_primary_auth_ok; then
  printf 't3-primary: t3cli auth status is not authenticated (run t3cli auth local)\n' >&2
  exit 1
fi

thread=$EXPLICIT_THREAD
bound_by=manual
[ -n "$thread" ] || thread=$(fm_t3_primary_config_thread_id 2>/dev/null || true)
[ -n "$thread" ] && bound_by=config

session=$(fm_t3_primary_cursor_session_id)
if [ -z "$thread" ]; then
  if [ -z "$session" ]; then
    printf 't3-primary: cannot resolve thread (no CURSOR_CONVERSATION_ID/--resume and no explicit thread)\n' >&2
    exit 1
  fi
  thread=$(fm_t3_primary_resolve_thread_by_session "$session") || {
    printf 't3-primary: no unique T3 thread matches cursor session %s\n' "$session" >&2
    exit 1
  }
  bound_by='session-start'
fi

if ! err=$(fm_t3_primary_preflight "$thread" 2>&1); then
  printf 't3-primary: preflight failed for %s: %s\n' "$thread" "$err" >&2
  exit 1
fi

# Optional project id from show
project_id=
show_json=$(t3cli show --thread "$thread" --format json 2>/dev/null || true)
if [ -n "$show_json" ]; then
  project_id=$(printf '%s' "$show_json" | jq -r '.projectId // empty' 2>/dev/null || true)
fi

[ -n "$session" ] || session=unknown
fm_t3_primary_binding_write "$thread" "$session" "$bound_by" "$project_id" || {
  printf 't3-primary: failed to write binding\n' >&2
  exit 1
}
printf 't3-primary: bound thread=%s session=%s by=%s\n' "$thread" "$session" "$bound_by"
exit 0
