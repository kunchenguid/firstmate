#!/usr/bin/env bash
# Bounded causal outcome-index reader shared by drain and inactive reconciliation.
# The store producer owns the schema; v1 remains readable but cannot prove spawn
# or processing coverage. A failed/contended read never grants suppression.

BRANCH_OUTCOME_INDEX_VERSION=fm-branch-outcome-index-v2
BRANCH_OUTCOME_INDEX_MAX_BYTES=512
BRANCH_OUTCOME_INDEX_STATE=ok
BRANCH_OUTCOME_INDEX_ENDPOINT=
BRANCH_OUTCOME_INDEX_IDENT=
outcome_index_ready_ok() { # <ready-path>
  local seq
  [ -f "$1" ] && [ -r "$1" ] && [ ! -L "$1" ] || return 1
  seq=$(LC_ALL=C command cat "$1" 2>/dev/null) || return 1
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

load_branch_outcome_index() { # <task>
  local task=$1 path data version seq endpoint ident spawn captain extra size
  BRANCH_OUTCOME_INDEX_STATE=ok
  BRANCH_OUTCOME_INDEX_ENDPOINT=
  BRANCH_OUTCOME_INDEX_IDENT=
  BRANCH_OUTCOME_INDEX_SEQ=0
  BRANCH_OUTCOME_INDEX_SPAWN=-
  BRANCH_OUTCOME_INDEX_CAPTAIN=0
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  path="$STATE/.$task.branch-outcome-index"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if [ ! -f "$path" ] || [ ! -r "$path" ] || [ -L "$path" ]; then
    BRANCH_OUTCOME_INDEX_STATE=invalid
    return 0
  fi
  size=$(_fm_status_file_size "$path") || { BRANCH_OUTCOME_INDEX_STATE=invalid; return 0; }
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) BRANCH_OUTCOME_INDEX_STATE=invalid; return 0 ;; esac
  if [ "$size" -gt "$BRANCH_OUTCOME_INDEX_MAX_BYTES" ]; then
    BRANCH_OUTCOME_INDEX_STATE=invalid
    return 0
  fi
  data=$(LC_ALL=C command cat "$path" 2>/dev/null) \
    || { BRANCH_OUTCOME_INDEX_STATE=invalid; return 0; }
  case "$data" in *$'\n'*) BRANCH_OUTCOME_INDEX_STATE=invalid; return 0 ;; esac
  IFS=$(printf '\t') read -r version seq endpoint ident spawn captain extra <<EOF
$data
EOF
  if [ "$version" = fm-branch-outcome-index-v1 ] && [ -z "$spawn$captain$extra" ]; then
    spawn=-; captain=0
  elif [ "$version" != "$BRANCH_OUTCOME_INDEX_VERSION" ] || [ -n "$extra" ]; then
    BRANCH_OUTCOME_INDEX_STATE=invalid
    return 0
  fi
  case "$seq:$endpoint" in *[!0-9:]*) BRANCH_OUTCOME_INDEX_STATE=invalid; return 0 ;; esac
  [ -n "$seq" ] && [ -n "$endpoint" ] && [ -n "$ident" ] \
    && [ "$seq" -gt 0 ] \
    && [ "${#seq}" -le 16 ] && [ "${#endpoint}" -le 16 ] \
    && [ "$seq" -le 9007199254740991 ] && [ "$endpoint" -le 9007199254740991 ] \
    || { BRANCH_OUTCOME_INDEX_STATE=invalid; return 0; }
  case "$spawn" in ''|*[!A-Za-z0-9._-]*) BRANCH_OUTCOME_INDEX_STATE=invalid; return 0 ;; esac
  case "$captain" in ''|*[!0-9]*) BRANCH_OUTCOME_INDEX_STATE=invalid; return 0 ;; esac
  if [ "${#captain}" -gt 16 ] || [ "$captain" -gt "$seq" ]; then
    BRANCH_OUTCOME_INDEX_STATE=invalid; return 0
  fi
  BRANCH_OUTCOME_INDEX_SEQ=$seq
  BRANCH_OUTCOME_INDEX_SPAWN=$spawn
  BRANCH_OUTCOME_INDEX_CAPTAIN=$captain
  BRANCH_OUTCOME_INDEX_ENDPOINT=$endpoint
  BRANCH_OUTCOME_INDEX_IDENT=$ident
}


branch_outcome_spawn_gen() { # <meta>
  local value
  [ -f "$1" ] && [ ! -L "$1" ] || { printf '-'; return; }
  value=$(sed -n 's/^spawn_gen=//p' "$1") || { printf '-'; return; }
  case "$value" in ''|*[!A-Za-z0-9._-]*) printf '-'; return ;; esac
  [ "${#value}" -le 128 ] || { printf '-'; return; }
  printf '%s' "$value"
}

branch_outcome_cursor() { # <path> <store-ready-seq>
  local value size
  [ -e "$1" ] || { printf '0'; return; }
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  size=$(_fm_status_file_size "$1") || return 1
  [ "$size" -le 32 ] || return 1
  value=$(cat "$1") || return 1
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#value}" -le 16 ] && [ "$value" -le "$2" ] || return 1
  printf '%s' "$value"
}

branch_outcome_delivery_covers() { # <task> <spawn> <status-endpoint> <status-identity>
  local task=$1 spawn=$2 endpoint=$3 ident=$4 lock ready cursor processed rc=1
  [ "$spawn" != - ] && [ -n "$spawn" ] || return 1
  case "$ident" in strong:*) ;; *) return 1 ;; esac
  [ -f "$STATE/branch-outcomes.jsonl" ] && [ ! -L "$STATE/branch-outcomes.jsonl" ] || return 1
  lock="$STATE/.branch-outcomes.lock"
  fm_lock_try_acquire "$lock" || return 1
  if ready=$(branch_outcome_cursor "$STATE/.branch-outcome-index-ready" 9007199254740991) \
    && cursor=$(branch_outcome_cursor "$STATE/.branch-outcomes-cursor" "$ready") \
    && processed=$(branch_outcome_cursor "$STATE/.branch-outcomes-processed" "$cursor"); then
    load_branch_outcome_index "$task"
    if [ "$BRANCH_OUTCOME_INDEX_STATE" = ok ] \
      && [ "$BRANCH_OUTCOME_INDEX_SPAWN" = "$spawn" ] \
      && [ "$BRANCH_OUTCOME_INDEX_IDENT" = "$ident" ] \
      && [ "$BRANCH_OUTCOME_INDEX_ENDPOINT" -ge "$endpoint" ] \
      && [ "$BRANCH_OUTCOME_INDEX_SEQ" -le "$cursor" ] \
      && [ "$BRANCH_OUTCOME_INDEX_CAPTAIN" -le "$processed" ] \
      && [ "$(_fm_status_file_size "$STATE/$task.status")" = "$endpoint" ] \
      && [ "$(_fm_open_decisions_file_ident "$STATE/$task.status")" = "$ident" ]; then
      rc=0
    fi
  fi
  fm_lock_release "$lock"
  return "$rc"
}
