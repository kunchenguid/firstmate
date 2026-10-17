#!/usr/bin/env bash
# fm-secondmate-inbox-lib.sh - the secondmate steering-backlog alarm owner.
#
# This library counts only unhandled *.msg records in the host-local steering
# inbox. A local secondmate uses state/<id>.inbox; a remote secondmate exposes
# the same calculation through fm-remote-secondmate-control.sh against its
# state/parent-route/<id>.inbox. It never moves, rewrites, or auto-handles a
# steering record.
#
# The alarm defaults are deliberately bounded above ordinary work: more than
# 20 unhandled instructions or an oldest instruction older than two hours is a
# backlog episode worth surfacing to the parent. The watcher owns durable wake
# publication and episode de-duplication; this library owns only measurement
# and the threshold decision.
#
# An absent inbox means no steering has ever been queued and reports zero.
# A symlink or a non-directory path is unsafe and returns nonzero.
#
# Output contract for fm_secondmate_inbox_health:
#   count=<n>\toldest_age=<seconds>\tnewest_ids=<comma-separated ids|->
#
# Source only. No side effects occur when this file is sourced.

FM_SECONDMATE_INBOX_MAX_DEFAULT=20
FM_SECONDMATE_INBOX_AGE_DEFAULT=7200

fm_secondmate_inbox_max() {
  local value=${FM_SECONDMATE_INBOX_MAX:-$FM_SECONDMATE_INBOX_MAX_DEFAULT}
  case "$value" in
    ''|*[!0-9]*) value=$FM_SECONDMATE_INBOX_MAX_DEFAULT ;;
  esac
  printf '%s\n' "$value"
}

fm_secondmate_inbox_age() {
  local value=${FM_SECONDMATE_INBOX_AGE_SECS:-$FM_SECONDMATE_INBOX_AGE_DEFAULT}
  case "$value" in
    ''|*[!0-9]*) value=$FM_SECONDMATE_INBOX_AGE_DEFAULT ;;
  esac
  printf '%s\n' "$value"
}

fm_secondmate_inbox_mtime() { # <path>
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_secondmate_inbox_health() { # <inbox-directory>
  local dir=$1 rec m now oldest_mtime=0 count=0 ids='' id age newest
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    printf 'count=0\toldest_age=0\tnewest_ids=-\n'
    return 0
  fi
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 2
  for rec in "$dir"/*.msg; do
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue
    m=$(fm_secondmate_inbox_mtime "$rec") || return 2
    case "$m" in
      ''|*[!0-9]*) return 2 ;;
    esac
    count=$((count + 1))
    if [ "$oldest_mtime" -eq 0 ] || [ "$m" -lt "$oldest_mtime" ]; then
      oldest_mtime=$m
    fi
    id=${rec##*/}
    id=${id%.msg}
    case "$id" in
      ''|*[!0-9]*) continue ;;
    esac
    ids="${ids}${ids:+$'\n'}$id"
  done
  if [ "$count" -eq 0 ]; then
    printf 'count=0\toldest_age=0\tnewest_ids=-\n'
    return 0
  fi
  now=$(date +%s)
  age=$((now - oldest_mtime))
  [ "$age" -ge 0 ] || age=0
  if [ -n "$ids" ]; then
    newest=$(printf '%s\n' "$ids" | sort -n | tail -3 | paste -sd, -)
  else
    newest=-
  fi
  [ -n "$newest" ] || newest=-
  printf 'count=%s\toldest_age=%s\tnewest_ids=%s\n' "$count" "$age" "$newest"
}

fm_secondmate_inbox_breached() { # <count> <oldest-age> [max-count] [max-age]
  local count=$1 age=$2 max_count=${3:-$(fm_secondmate_inbox_max)} max_age=${4:-$(fm_secondmate_inbox_age)}
  case "$count:$age:$max_count:$max_age" in
    *[!0-9:]*|*::* ) return 2 ;;
  esac
  [ "$count" -gt "$max_count" ] || [ "$age" -gt "$max_age" ]
}
