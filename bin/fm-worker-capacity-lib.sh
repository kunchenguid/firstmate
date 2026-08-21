#!/usr/bin/env bash
# fm-worker-capacity-lib.sh - fail-closed local worker-capacity guard.
#
# A FirstMate home can set config/max-active-workers to one positive base-10
# integer. fm-spawn consults this guard while holding the host admission lock,
# before it creates a new endpoint. The guard counts each recorded direct
# report whose endpoint is alive, ambiguous, unreadable, or not yet verifiable.
# It excludes only endpoints proven dead or missing. This protects a small host
# from an otherwise independent batch of agent launches exhausting memory.
#
# A malformed or unsafe file is an error, never an implicit unlimited value. The config is
# inherited by secondmate homes through fm-config-inherit-lib.sh.
#
# Source after fm-backend.sh. Public functions:
#   fm_worker_capacity_limit <config-dir>       -> positive integer
#   fm_worker_capacity_active <state-dir>       -> active count
#   fm_worker_capacity_active_host <state-dir>  -> active local-host count
#   fm_worker_capacity_pending_reserve <state-dir> <task-id>
#   fm_worker_capacity_pending_release <state-dir> <task-id>
#   fm_worker_capacity_pending_until_started <state-dir> <task-id>

fm_worker_capacity_file_valid() {  # <file>
  local file=$1 value links bytes
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    links=$(stat -f %l "$file" 2>/dev/null) || return 1
  else
    links=$(stat -c %h "$file" 2>/dev/null) || return 1
  fi
  [ "$links" = 1 ] || return 1
  value=$(<"$file")
  case "$value" in
    [1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;;
    *) return 1 ;;
  esac
  bytes=$(LC_ALL=C wc -c < "$file") || return 1
  bytes=${bytes//[[:space:]]/}
  [ "$bytes" = "$(( ${#value} + 1 ))" ]
}

fm_worker_capacity_limit() {  # <config-dir>
  local config=$1 file value
  if [ -e "$config" ] || [ -L "$config" ]; then
    [ -d "$config" ] && [ ! -L "$config" ] || return 1
  fi
  file="$config/max-active-workers"
  [ -e "$file" ] || [ -L "$file" ] || { printf '1'; return 0; }
  fm_worker_capacity_file_valid "$file" || return 1
  value=$(<"$file")
  printf '%s' "$value"
}

fm_worker_capacity_pending_path() {  # <state-dir> <task-id>
  local state=$1 id=$2
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s/.worker-capacity-%s.pending\n' "$state" "$id"
}

fm_worker_capacity_pending_reserve() {  # <state-dir> <task-id>
  local state=$1 id=$2 pending
  pending=$(fm_worker_capacity_pending_path "$state" "$id") || return 1
  [ ! -e "$pending" ] && [ ! -L "$pending" ] || return 1
  (umask 077; printf '%s\n' "$id" > "$pending") || return 1
  [ -f "$pending" ] && [ ! -L "$pending" ]
}

fm_worker_capacity_pending_release() {  # <state-dir> <task-id>
  local state=$1 id=$2 pending
  pending=$(fm_worker_capacity_pending_path "$state" "$id") || return 1
  [ ! -e "$pending" ] && [ ! -L "$pending" ] && return 0
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 1
  rm -f -- "$pending"
}

fm_worker_capacity_pending_until_started() {  # <state-dir> <task-id>
  local state=$1 id=$2 meta backend target verdict i=0 limit=${FM_WORKER_CAPACITY_START_POLLS:-100}
  case "$limit" in [1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;; *) return 1 ;; esac
  meta="$state/$id.meta"
  while [ "$i" -lt "$limit" ]; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
    backend=$(fm_backend_of_meta "$meta") || return 1
    target=$(fm_backend_target_of_meta "$meta") || return 1
    [ -n "$target" ] || return 1
    verdict=$(fm_backend_agent_state "$backend" "$target") || return 1
    case "$verdict" in
      alive|ambiguous|unreadable|unverified) return 0 ;;
      dead|missing) sleep 0.1 ;;
      *) return 1 ;;
    esac
    i=$((i + 1))
  done
  return 1
}

fm_worker_capacity_pending_expired() {  # <pending-path>
  local pending=$1 grace now modified
  grace=${FM_WORKER_CAPACITY_PENDING_GRACE_SECONDS:-120}
  case "$grace" in 0|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;; *) return 1 ;; esac
  if [ "$(uname)" = Darwin ]; then
    modified=$(stat -f %m "$pending" 2>/dev/null) || return 1
  else
    modified=$(stat -c %Y "$pending" 2>/dev/null) || return 1
  fi
  case "$modified" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s 2>/dev/null) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ "$now" -ge "$modified" ] && [ $((now - modified)) -ge "$grace" ]
}

fm_worker_capacity_pending_counts() {  # <state-dir> <pending-path>
  local state=$1 pending=$2 name id meta backend target verdict
  name=${pending##*/}
  case "$name" in
    .worker-capacity-*.pending)
      id=${name#.worker-capacity-}
      id=${id%.pending}
      ;;
    *) return 2 ;;
  esac
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 2 ;; esac
  [ "$(<"$pending")" = "$id" ] || return 2
  meta="$state/$id.meta"
  if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
    if [ "${FM_WORKER_CAPACITY_RECONCILE:-0}" = 1 ] \
      && fm_worker_capacity_pending_expired "$pending"; then
      fm_worker_capacity_pending_release "$state" "$id" || return 2
      return 1
    fi
    return 0
  fi
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 2
  backend=$(fm_backend_of_meta "$meta") || return 2
  target=$(fm_backend_target_of_meta "$meta") || return 2
  [ -n "$target" ] || return 2
  verdict=$(fm_backend_agent_state "$backend" "$target") || return 2
  case "$verdict" in
    dead|missing)
      if [ "${FM_WORKER_CAPACITY_RECONCILE:-0}" = 1 ] \
        && fm_worker_capacity_pending_expired "$pending"; then
        fm_worker_capacity_pending_release "$state" "$id" || return 2
        return 1
      fi
      return 0
      ;;
    alive|ambiguous|unreadable|unverified) ;;
    *) return 2 ;;
  esac
  if [ "${FM_WORKER_CAPACITY_RECONCILE:-0}" = 1 ]; then
    fm_worker_capacity_pending_release "$state" "$id" || return 2
  fi
  return 1
}

fm_worker_capacity_active() {  # <state-dir>
  fm_worker_capacity_active_in_state "$1" 0
}

fm_worker_capacity_active_in_state() {  # <state-dir> <skip-remote-secondmates>
  local state=$1 skip_remote=$2 meta pending backend target verdict kind remote_host count=0 pending_status
  [ -d "$state" ] || { printf '0'; return 0; }
  shopt -s nullglob
  for pending in "$state"/.worker-capacity-*.pending; do
    [ -f "$pending" ] && [ ! -L "$pending" ] || return 1
    if fm_worker_capacity_pending_counts "$state" "$pending"; then
      count=$((count + 1))
    else
      pending_status=$?
      [ "$pending_status" = 1 ] || { shopt -u nullglob; return 1; }
    fi
  done
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
    if [ "$skip_remote" = 1 ]; then
      kind=$(fm_meta_get "$meta" kind)
      remote_host=$(fm_meta_get "$meta" remote_host)
      [ "$kind" = secondmate ] && [ -n "$remote_host" ] && continue
    fi
    backend=$(fm_backend_of_meta "$meta") || return 1
    target=$(fm_backend_target_of_meta "$meta") || return 1
    [ -n "$target" ] || return 1
    verdict=$(fm_backend_agent_state "$backend" "$target") || return 1
    case "$verdict" in
      dead|missing) ;;
      alive|ambiguous|unreadable|unverified) count=$((count + 1)) ;;
      *) return 1 ;;
    esac
  done
  shopt -u nullglob
  printf '%s' "$count"
}

fm_worker_capacity_remote_route_register_one() {  # <host-state> <route-state> <id> <home>
  local host_state=$1 route_state=$2 id=$3 home=$4 meta meta_home route_file tmp existing
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -d "$route_state" ] && [ ! -L "$route_state" ] || return 1
  route_state=$(CDPATH='' cd -- "$route_state" 2>/dev/null && pwd -P) || return 1
  [ -d "$home" ] && [ ! -L "$home" ] || return 1
  home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  [ "$route_state" = "$home/state/parent-route" ] \
    && [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] \
    && [ "$(<"$home/.fm-secondmate-home")" = "$id" ] || return 1
  meta="$route_state/$id.meta"
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    [ -f "$meta" ] && [ ! -L "$meta" ] \
      && [ "$(fm_meta_get "$meta" kind)" = secondmate ] || return 1
    meta_home=$(fm_meta_get "$meta" home)
    meta_home=$(CDPATH='' cd -- "$meta_home" 2>/dev/null && pwd -P) || return 1
    [ "$meta_home" = "$home" ] || return 1
  fi
  if [ -e "$host_state" ] || [ -L "$host_state" ]; then
    [ -d "$host_state" ] && [ ! -L "$host_state" ] || return 1
  else
    mkdir "$host_state" 2>/dev/null || true
    [ -d "$host_state" ] && [ ! -L "$host_state" ] || return 1
  fi
  host_state=$(CDPATH='' cd -- "$host_state" 2>/dev/null && pwd -P) || return 1
  route_file="$host_state/.worker-capacity-route-$id.state"
  if [ -e "$route_file" ] || [ -L "$route_file" ]; then
    [ -f "$route_file" ] && [ ! -L "$route_file" ] || return 1
    existing=$(<"$route_file")
    [ "$existing" = "$route_state" ] || return 1
    return 0
  fi
  tmp="$route_file.tmp.$$"
  (umask 077; printf '%s\n' "$route_state" > "$tmp") || return 1
  [ -f "$tmp" ] && [ ! -L "$tmp" ] || { rm -f -- "$tmp"; return 1; }
  if ! mv -n -- "$tmp" "$route_file" 2>/dev/null; then
    rm -f -- "$tmp"
    [ -f "$route_file" ] && [ ! -L "$route_file" ] \
      && [ "$(<"$route_file")" = "$route_state" ] || return 1
  fi
}

fm_worker_capacity_remote_route_record_home() {  # <host-state> <id> <home>
  local host_state=$1 id=$2 home=$3 routes record tmp existing
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -d "$host_state" ] && [ ! -L "$host_state" ] || return 1
  host_state=$(CDPATH='' cd -- "$host_state" 2>/dev/null && pwd -P) || return 1
  [ -d "$home" ] && [ ! -L "$home" ] || return 1
  home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  case "$home" in *$'\n'*|*$'\r'*) return 1 ;; esac
  routes="$host_state/routes"
  if [ -e "$routes" ] || [ -L "$routes" ]; then
    [ -d "$routes" ] && [ ! -L "$routes" ] || return 1
  else
    mkdir "$routes" 2>/dev/null || true
    [ -d "$routes" ] && [ ! -L "$routes" ] || return 1
  fi
  record="$routes/$id.home"
  if [ -e "$record" ] || [ -L "$record" ]; then
    [ -f "$record" ] && [ ! -L "$record" ] || return 1
    existing=$(<"$record")
    [ "$existing" = "$home" ]
    return
  fi
  tmp=$(umask 077; mktemp "$routes/.route-$id.XXXXXX") || return 1
  printf '%s\n' "$home" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! mv -n -- "$tmp" "$record" 2>/dev/null; then
    rm -f -- "$tmp"
    [ -f "$record" ] && [ ! -L "$record" ] && [ "$(<"$record")" = "$home" ] || return 1
  fi
}

fm_worker_capacity_remote_route_register_known() {  # <host-state>
  local host_state=$1 routes record id home route_state
  [ -d "$host_state" ] && [ ! -L "$host_state" ] || return 1
  host_state=$(CDPATH='' cd -- "$host_state" 2>/dev/null && pwd -P) || return 1
  routes="$host_state/routes"
  [ ! -e "$routes" ] && [ ! -L "$routes" ] && return 0
  [ -d "$routes" ] && [ ! -L "$routes" ] || return 1
  shopt -s nullglob
  for record in "$routes"/*.home; do
    [ -f "$record" ] && [ ! -L "$record" ] || { shopt -u nullglob; return 1; }
    id=${record##*/}
    id=${id%.home}
    case "$id" in ''|*[!A-Za-z0-9._-]*) shopt -u nullglob; return 1 ;; esac
    home=$(<"$record")
    case "$home" in /*) ;; *) shopt -u nullglob; return 1 ;; esac
    case "$home" in *$'\n'*|*$'\r'*) shopt -u nullglob; return 1 ;; esac
    [ -d "$home" ] && [ ! -L "$home" ] || continue
    home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || { shopt -u nullglob; return 1; }
    route_state="$home/state/parent-route"
    fm_worker_capacity_remote_route_register_one "$host_state" "$route_state" "$id" "$home" \
      || { shopt -u nullglob; return 1; }
  done
  shopt -u nullglob
}

fm_worker_capacity_remote_route_release() {  # <host-state> <id>
  local host_state=$1 id=$2 route routes record
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -d "$host_state" ] && [ ! -L "$host_state" ] || return 1
  host_state=$(CDPATH='' cd -- "$host_state" 2>/dev/null && pwd -P) || return 1
  route="$host_state/.worker-capacity-route-$id.state"
  if [ -e "$route" ] || [ -L "$route" ]; then
    [ -f "$route" ] && [ ! -L "$route" ] || return 1
    rm -f -- "$route" || return 1
  fi
  routes="$host_state/routes"
  if [ -e "$routes" ] || [ -L "$routes" ]; then
    [ -d "$routes" ] && [ ! -L "$routes" ] || return 1
    record="$routes/$id.home"
    if [ -e "$record" ] || [ -L "$record" ]; then
      [ -f "$record" ] && [ ! -L "$record" ] || return 1
      rm -f -- "$record" || return 1
    fi
  fi
}

fm_worker_capacity_remote_route_register() {  # <host-state> <route-state> <id> <home>
  local host_state=$1 route_state=$2 id=$3 home=$4 parent candidate candidate_id candidate_route candidate_meta
  fm_worker_capacity_remote_route_register_one "$host_state" "$route_state" "$id" "$home" || return 1
  fm_worker_capacity_remote_route_record_home "$host_state" "$id" "$home" || return 1
  fm_worker_capacity_remote_route_register_known "$host_state" || return 1
  parent=$(dirname "$home")
  parent=$(CDPATH='' cd -- "$parent" 2>/dev/null && pwd -P) || return 1
  shopt -s nullglob
  for candidate in "$parent"/*; do
    [ -d "$candidate" ] && [ ! -L "$candidate" ] \
      && [ -f "$candidate/.fm-secondmate-home" ] && [ ! -L "$candidate/.fm-secondmate-home" ] || continue
    candidate_id=$(<"$candidate/.fm-secondmate-home")
    case "$candidate_id" in ''|*[!A-Za-z0-9._-]*) shopt -u nullglob; return 1 ;; esac
    candidate_route="$candidate/state/parent-route"
    candidate_meta="$candidate_route/$candidate_id.meta"
    [ -e "$candidate_meta" ] || [ -L "$candidate_meta" ] || continue
    fm_worker_capacity_remote_route_register_one "$host_state" "$candidate_route" "$candidate_id" "$candidate" \
      || { shopt -u nullglob; return 1; }
    fm_worker_capacity_remote_route_record_home "$host_state" "$candidate_id" "$candidate" \
      || { shopt -u nullglob; return 1; }
  done
  shopt -u nullglob
}

fm_worker_capacity_active_host() {  # <primary-state-dir>
  fm_worker_capacity_active_host_state "$1" $'\n'
}

fm_worker_capacity_active_host_state() {  # <state-dir> <visited-homes>
  local state=$1 visited=$2 meta id kind home remote_host active count=0 route route_state route_home
  [ -d "$state" ] || { printf '0'; return 0; }
  active=$(fm_worker_capacity_active_in_state "$state" 1) || return 1
  count=$active
  shopt -s nullglob
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || { shopt -u nullglob; return 1; }
    kind=$(fm_meta_get "$meta" kind)
    remote_host=$(fm_meta_get "$meta" remote_host)
    [ "$kind" = secondmate ] && [ -z "$remote_host" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    case "$id" in ''|*[!A-Za-z0-9._-]*) shopt -u nullglob; return 1 ;; esac
    home=$(fm_meta_get "$meta" home)
    case "$home" in /*) ;; *) shopt -u nullglob; return 1 ;; esac
    case "$home" in *$'\n'*|*$'\r'*) shopt -u nullglob; return 1 ;; esac
    home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || { shopt -u nullglob; return 1; }
    [ -d "$home" ] && [ ! -L "$home" ] \
      && [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] \
      && [ "$(<"$home/.fm-secondmate-home")" = "$id" ] \
      && [ -d "$home/state" ] || { shopt -u nullglob; return 1; }
    case "$visited" in *$'\n'"$home"$'\n'*) shopt -u nullglob; return 1 ;; esac
    active=$(fm_worker_capacity_active_host_state "$home/state" "$visited$home"$'\n') || { shopt -u nullglob; return 1; }
    count=$((count + active))
  done
  for route in "$state"/.worker-capacity-route-*.state; do
    [ -f "$route" ] && [ ! -L "$route" ] || { shopt -u nullglob; return 1; }
    id=${route##*/}
    id=${id#.worker-capacity-route-}
    id=${id%.state}
    case "$id" in ''|*[!A-Za-z0-9._-]*) shopt -u nullglob; return 1 ;; esac
    route_state=$(<"$route")
    case "$route_state" in /*) ;; *) shopt -u nullglob; return 1 ;; esac
    case "$route_state" in *$'\n'*|*$'\r'*) shopt -u nullglob; return 1 ;; esac
    route_state=$(CDPATH='' cd -- "$route_state" 2>/dev/null && pwd -P) || { shopt -u nullglob; return 1; }
    [ -d "$route_state" ] && [ ! -L "$route_state" ] || { shopt -u nullglob; return 1; }
    case "$route_state" in */state/parent-route) route_home=${route_state%/state/parent-route} ;; *) shopt -u nullglob; return 1 ;; esac
    [ -d "$route_home" ] && [ ! -L "$route_home" ] \
      && [ -f "$route_home/.fm-secondmate-home" ] && [ ! -L "$route_home/.fm-secondmate-home" ] \
      && [ "$(<"$route_home/.fm-secondmate-home")" = "$id" ] || { shopt -u nullglob; return 1; }
    if [ -e "$route_state/$id.meta" ] || [ -L "$route_state/$id.meta" ]; then
      [ -f "$route_state/$id.meta" ] && [ ! -L "$route_state/$id.meta" ] \
        && [ "$(fm_meta_get "$route_state/$id.meta" kind)" = secondmate ] || { shopt -u nullglob; return 1; }
      home=$(fm_meta_get "$route_state/$id.meta" home)
      home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || { shopt -u nullglob; return 1; }
      [ "$home" = "$route_home" ] || { shopt -u nullglob; return 1; }
    fi
    case "$visited" in *$'\n'"$route_state"$'\n'*) shopt -u nullglob; return 1 ;; esac
    active=$(fm_worker_capacity_active_host_state "$route_state" "$visited$route_state"$'\n') || { shopt -u nullglob; return 1; }
    count=$((count + active))
  done
  shopt -u nullglob
  printf '%s' "$count"
}
