#!/usr/bin/env bash
# Shared receipt contract for automatic terminal worker cleanup.
# fm-control writes one only after it proves an ordinary worker terminal and
# stopped; fm-teardown consumes it only while the same incarnation and status
# signature remain unchanged.

fm_auto_close_token_valid() { # <token>
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

fm_auto_close_receipt_path() { # <state> <task-id>
  printf '%s/%s.auto-close\n' "$1" "$2"
}

fm_auto_close_receipt_write() { # <state> <task-id> <incarnation> <terminal-state> <status-signature>
  local state=$1 id=$2 incarnation=$3 terminal=$4 signature=$5 path tmp
  fm_auto_close_token_valid "$id" || return 1
  fm_auto_close_token_valid "$incarnation" || return 1
  case "$terminal" in done|failed) ;; *) return 1 ;; esac
  case "$signature" in ''|*$'\n'*) return 1 ;; esac
  path=$(fm_auto_close_receipt_path "$state" "$id")
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
  tmp=$(umask 077; mktemp "$state/.auto-close.XXXXXX") || return 1
  {
    printf 'schema=fm-auto-close.v1\n'
    printf 'task_id=%s\n' "$id"
    printf 'incarnation=%s\n' "$incarnation"
    printf 'terminal_state=%s\n' "$terminal"
    printf 'status_signature=%s\n' "$signature"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -- "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

fm_auto_close_receipt_validate() { # <path> <task-id> <incarnation> <status-signature>
  local path=$1 id=$2 incarnation=$3 signature=$4 terminal expected actual
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  terminal=$(sed -n 's/^terminal_state=//p' "$path")
  case "$terminal" in done|failed) ;; *) return 1 ;; esac
  expected=$(printf 'schema=fm-auto-close.v1\ntask_id=%s\nincarnation=%s\nterminal_state=%s\nstatus_signature=%s' \
    "$id" "$incarnation" "$terminal" "$signature")
  actual=$(cat "$path") || return 1
  [ "$actual" = "$expected" ] || return 1
}
