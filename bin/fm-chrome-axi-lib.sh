#!/usr/bin/env bash
# Shared Chrome DevTools AXI environment and cleanup ownership for ordinary
# workers and scouts.
#
# fm-spawn.sh derives one deterministic named session from the canonical
# Firstmate home plus the full task id, records it as
# chrome_devtools_axi_session=, and puts the complete browser environment on the
# shared agent launch command before any verified harness starts.
# The readable task prefix is bounded and a digest of the untruncated home/id
# identity preserves isolation across long task ids and separate homes.
# Session names always satisfy chrome-devtools-axi's 1-64 character
# [A-Za-z0-9._-] contract and never use its shared default session.
#
# Chrome arguments are whitespace-separated tokens, matching
# chrome-devtools-axi's own contract.
# When the launching worker uid is 0, the exact --no-sandbox token is appended
# only when absent; every ambient argument is otherwise preserved byte-for-byte.
# Non-root launches receive the ambient arguments unchanged.
#
# fm-teardown.sh validates that any recorded session exactly matches the
# home/task-derived identity before cleanup can mutate anything.
# Legacy metadata without the field is a safe no-op and never falls back to the
# default session.
# After landed-work, report, and decision checks authorize destructive cleanup,
# teardown runs chrome-devtools-axi stop with only that exact recorded session.
# A failed stop aborts cleanup while its metadata still exists for a retry.

fm_chrome_axi_session_name_valid() {  # <name>
  local name=${1:-}
  [ -n "$name" ] || return 1
  [ "$name" != default ] || return 1
  [ "${#name}" -le 64 ] || return 1
  case "$name" in
    *[!A-Za-z0-9._-]*|.*) return 1 ;;
  esac
  case "$name" in
    *[!\.]*) : ;;
    *) return 1 ;;
  esac
}

fm_chrome_axi_session_name() {  # <firstmate-home> <task-id>
  local home=$1 id=$2 home_real digest prefix session
  home_real=$(cd "$home" 2>/dev/null && pwd -P) || {
    echo "error: cannot resolve Firstmate home for Chrome DevTools AXI isolation: $home" >&2
    return 1
  }
  digest=$(
    printf '%s\n%s\n' "$home_real" "$id" |
      (
        unset GIT_DIR GIT_WORK_TREE
        export GIT_DEFAULT_HASH=sha1
        cd / && git -c init.defaultObjectFormat=sha1 hash-object --stdin
      )
  ) || {
    echo "error: cannot derive Chrome DevTools AXI session identity" >&2
    return 1
  }
  case "$digest" in
    ''|*[!0-9a-f]*)
      echo "error: invalid Chrome DevTools AXI session identity digest" >&2
      return 1
      ;;
  esac
  prefix=${id:0:32}
  session="fm-$prefix-${digest:0:20}"
  fm_chrome_axi_session_name_valid "$session" || {
    echo "error: generated unsafe Chrome DevTools AXI session name" >&2
    return 1
  }
  printf '%s\n' "$session"
}

fm_chrome_axi_args_for_uid() {  # <uid> <ambient-arguments>
  local uid=$1 args=${2-}
  if [ "$uid" = 0 ] \
     && ! printf '%s\n' "$args" | grep -Eq '(^|[[:space:]])--no-sandbox([[:space:]]|$)'; then
    args="${args:+$args }--no-sandbox"
  fi
  printf '%s' "$args"
}

fm_chrome_axi_meta_session() {  # <meta-file>
  local meta=$1 count
  [ -f "$meta" ] || return 1
  count=$(grep -c '^chrome_devtools_axi_session=' "$meta" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep '^chrome_devtools_axi_session=' "$meta" | cut -d= -f2-
}

fm_chrome_axi_validate_meta_session() {  # <meta-file> <task-id> <firstmate-home>
  local meta=$1 id=$2 home=$3 count recorded expected
  count=$(grep -c '^chrome_devtools_axi_session=' "$meta" 2>/dev/null || true)
  if [ "$count" = 0 ]; then
    return 0
  fi
  if [ "$count" != 1 ]; then
    echo "REFUSED: Chrome DevTools AXI session metadata for task $id is ambiguous; preserving task state." >&2
    return 1
  fi
  recorded=$(fm_chrome_axi_meta_session "$meta") || {
    echo "REFUSED: Chrome DevTools AXI session metadata for task $id is unreadable; preserving task state." >&2
    return 1
  }
  if ! fm_chrome_axi_session_name_valid "$recorded"; then
    echo "REFUSED: Chrome DevTools AXI session metadata for task $id is unsafe; preserving task state." >&2
    return 1
  fi
  expected=$(fm_chrome_axi_session_name "$home" "$id") || return 1
  if [ "$recorded" != "$expected" ]; then
    echo "REFUSED: Chrome DevTools AXI session metadata for task $id does not match its home/task identity; preserving task state." >&2
    return 1
  fi
}

fm_chrome_axi_stop_meta_session() {  # <meta-file> <task-id> <firstmate-home>
  local meta=$1 id=$2 home=$3 session
  fm_chrome_axi_validate_meta_session "$meta" "$id" "$home" || return 1
  session=$(fm_chrome_axi_meta_session "$meta" 2>/dev/null || true)
  [ -n "$session" ] || return 0
  command -v chrome-devtools-axi >/dev/null 2>&1 || {
    echo "error: cannot stop Chrome DevTools AXI session $session for task $id: chrome-devtools-axi is unavailable; preserving task state" >&2
    return 1
  }
  if ! CHROME_DEVTOOLS_AXI_SESSION="$session" \
      CHROME_DEVTOOLS_AXI_PORT='' \
      CHROME_DEVTOOLS_AXI_AUTO_CONNECT='' \
      CHROME_DEVTOOLS_AXI_BROWSER_URL='' \
      CHROME_DEVTOOLS_AXI_USER_DATA_DIR='' \
      chrome-devtools-axi stop; then
    echo "error: failed to stop exact Chrome DevTools AXI session $session for task $id; preserving task state for retry" >&2
    return 1
  fi
}
