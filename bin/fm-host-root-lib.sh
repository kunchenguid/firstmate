#!/usr/bin/env bash
# fm-host-root-lib.sh - validation and command rendering for optional host-root mode.
#
# FM_HOST_ROOT is opt-in. When unset or empty, every helper preserves the normal
# FirstMate-root behavior. When set, the value must resolve to an existing
# physical directory with the cross-harness AGENTS.md instruction surface, must
# differ from FM_ROOT, and must be safe for line-based task metadata.
#
# fm_host_root_enabled
# fm_host_root_resolve <fm-root>       # prints the physical host root
# fm_host_root_assert_session_cwd <fm-root>
# fm_host_root_assert_session_authority <fm-root> <state-dir>
# fm_host_root_assert_task_cwd <fm-root> <task-meta>
# fm_host_root_persist_task_owner <task-meta> <owner-file>
# fm_host_root_paths_overlap <physical-host-root> <physical-target-root>
# fm_host_root_assert_operational_roots <physical-host-root> <physical-fm-root> [physical-fm-home]
# fm_host_root_command <fm-root> <repo-relative-command>

fm_host_root_enabled() {
  [ -n "${FM_HOST_ROOT:-}" ]
}

fm_host_root_resolve() {
  local fm_root=${1:-.} host home root_real host_real home_real
  fm_host_root_enabled || return 1
  host=$FM_HOST_ROOT
  case "$host" in
    *[$'\001'-$'\037'$'\177']*)
      echo "error: FM_HOST_ROOT contains a control character unsafe for task metadata" >&2
      return 2
      ;;
  esac
  [ -d "$host" ] || {
    echo "error: FM_HOST_ROOT is not an existing directory: $host" >&2
    return 2
  }
  host_real=$(cd "$host" 2>/dev/null && pwd -P) || {
    echo "error: FM_HOST_ROOT cannot be resolved: $host" >&2
    return 2
  }
  case "$host_real" in
    *[$'\001'-$'\037'$'\177']*)
      echo "error: resolved FM_HOST_ROOT contains a control character unsafe for task metadata" >&2
      return 2
      ;;
  esac
  root_real=$(cd "$fm_root" 2>/dev/null && pwd -P) || {
    echo "error: FM_ROOT cannot be resolved while validating FM_HOST_ROOT: $fm_root" >&2
    return 2
  }
  home=${FM_HOME:-$fm_root}
  home_real=$(cd "$home" 2>/dev/null && pwd -P) || {
    echo "error: FM_HOME cannot be resolved while validating FM_HOST_ROOT: $home" >&2
    return 2
  }
  fm_host_root_assert_operational_roots "$host_real" "$root_real" "$home_real" || return $?
  if [ ! -f "$host_real/AGENTS.md" ]; then
    echo "error: FM_HOST_ROOT has no cross-harness instruction surface (expected AGENTS.md): $host_real" >&2
    return 2
  fi
  printf '%s\n' "$host_real"
}

fm_host_root_assert_session_cwd() {
  local fm_root=${1:-.} host cwd
  fm_host_root_enabled || return 0
  host=$(fm_host_root_resolve "$fm_root") || return $?
  cwd=$(pwd -P) || return 2
  [ "$cwd" = "$host" ] || {
    echo "error: host-root mode requires the supervisor cwd to be $host (current physical cwd: $cwd)" >&2
    return 2
  }
}

fm_host_root_assert_session_authority() {  # <fm-root> <state-dir>
  local fm_root=$1 state=$2 meta owner status ambient=
  if fm_host_root_enabled; then
    fm_host_root_assert_session_cwd "$fm_root" || return $?
    ambient=$(fm_host_root_resolve "$fm_root") || return $?
  fi
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    if owner=$(fm_host_root_recorded_owner "$meta"); then
      if [ -n "$ambient" ] && [ "$owner" = "$ambient" ]; then
        continue
      elif [ -z "$ambient" ]; then
        echo "error: FM_HOST_ROOT is unset, but task metadata $(basename "$meta") is owned by host root $owner; start from that directory with FM_HOST_ROOT set" >&2
      else
        echo "error: FM_HOST_ROOT $ambient does not match task metadata $(basename "$meta") owned by host root $owner" >&2
      fi
      return 2
    fi
    status=$?
    [ "$status" -eq 1 ] || return "$status"
  done
}

fm_host_root_recorded_owner() {
  local meta=$1 count recorded
  count=$(grep -c '^host_root=' "$meta" 2>/dev/null || true)
  case "$count" in
    0) return 1 ;;
    1) recorded=$(sed -n 's/^host_root=//p' "$meta" 2>/dev/null) ;;
    *)
      echo "error: task metadata $meta has ambiguous host_root ownership" >&2
      return 2
      ;;
  esac
  [ -n "$recorded" ] || {
    echo "error: task metadata $meta has empty host_root ownership" >&2
    return 2
  }
  printf '%s\n' "$recorded"
}

fm_host_root_assert_task_cwd() {
  local fm_root=$1 meta=$2 recorded kind='' host ambient cwd status kind_count
  if recorded=$(fm_host_root_recorded_owner "$meta"); then
    :
  else
    status=$?
    [ "$status" -eq 1 ] || return "$status"
    recorded=
  fi
  kind_count=$(grep -c '^kind=' "$meta" 2>/dev/null || true)
  [ "$kind_count" -ne 1 ] || kind=$(sed -n 's/^kind=//p' "$meta" 2>/dev/null)
  if [ -z "$recorded" ]; then
    if [ "$kind" = secondmate ] || fm_host_root_enabled; then
      fm_host_root_assert_session_cwd "$fm_root"
      return $?
    fi
    return 0
  fi
  host=$(FM_HOST_ROOT=$recorded fm_host_root_resolve "$fm_root") || return $?
  [ "$host" = "$recorded" ] || {
    echo "error: task metadata host_root is not the recorded physical path: $recorded" >&2
    return 2
  }
  if fm_host_root_enabled; then
    ambient=$(fm_host_root_resolve "$fm_root") || return $?
    [ "$ambient" = "$host" ] || {
      echo "error: ambient FM_HOST_ROOT $ambient does not match task metadata host_root $host" >&2
      return 2
    }
  fi
  cwd=$(pwd -P) || return 2
  [ "$cwd" = "$host" ] || {
    echo "error: task action requires the recorded host root cwd $host (current physical cwd: $cwd)" >&2
    return 2
  }
}

fm_host_root_persist_task_owner() {
  local meta=$1 owner=$2 recorded tmp status
  if recorded=$(fm_host_root_recorded_owner "$meta"); then
    :
  else
    status=$?
    [ "$status" -eq 1 ] && return 0
    return "$status"
  fi
  if [ -e "$owner" ] || [ -L "$owner" ]; then
    [ -f "$owner" ] && [ ! -L "$owner" ] || {
      echo "error: host owner is not a regular file: $owner" >&2
      return 2
    }
    [ "$(cat "$owner")" = "host_root=$recorded" ] || {
      echo "error: host owner does not match task metadata: $owner" >&2
      return 2
    }
    return 0
  fi
  tmp=$(umask 077; mktemp "$owner.tmp.XXXXXX" 2>/dev/null) || {
    echo "error: could not persist host owner: $owner" >&2
    return 2
  }
  if ! printf 'host_root=%s\n' "$recorded" > "$tmp" \
     || ! chmod 0600 "$tmp" 2>/dev/null \
     || ! mv -f -- "$tmp" "$owner" 2>/dev/null; then
    rm -f -- "$tmp"
    echo "error: could not persist host owner: $owner" >&2
    return 2
  fi
}

fm_host_root_paths_overlap() {
  local host=$1 target=$2
  [ "$host" = "$target" ] && return 0
  [ "$host" = / ] && return 0
  [ "$target" = / ] && return 0
  case "$target" in "$host"/*) return 0 ;; esac
  case "$host" in "$target"/*) return 0 ;; esac
  return 1
}

fm_host_root_assert_operational_roots() {
  local host=$1 root=$2 home=${3:-}
  if fm_host_root_paths_overlap "$host" "$root"; then
    echo "error: FM_HOST_ROOT must not overlap FM_ROOT; unset FM_HOST_ROOT for normal FirstMate-root operation" >&2
    return 2
  fi
  if [ -n "$home" ] && fm_host_root_paths_overlap "$host" "$home"; then
    echo "error: FM_HOST_ROOT must not overlap FM_HOME; keep FirstMate state outside the host repository" >&2
    return 2
  fi
}

fm_host_root_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_host_root_command() {
  local fm_root=$1 command=$2 root_real
  if fm_host_root_enabled; then
    root_real=$(cd "$fm_root" 2>/dev/null && pwd -P) || return 1
    fm_host_root_shell_quote "$root_real/$command"
    printf '\n'
  else
    printf '%s\n' "$command"
  fi
}
