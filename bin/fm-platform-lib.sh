#!/usr/bin/env bash
# Small platform seam for OS checks and Windows/Git-Bash substrate helpers.
#
# Source this leaf helper when code needs OS detection, HOME/TMPDIR resolution,
# or process-table fields that must tolerate MSYS/Cygwin fixed-column `ps`.
# `fm_platform_is_windows` is the one narrow Windows branch point.
# `FM_PLATFORM_UNAME`, `FM_PLATFORM_IS_WINDOWS`, and legacy `FM_IS_WINDOWS`
# are test seams; production callers should leave them unset.

FM_PLATFORM_UNAME="${FM_PLATFORM_UNAME:-}"
fm_platform_uname() {
  if [ -z "$FM_PLATFORM_UNAME" ]; then
    FM_PLATFORM_UNAME=$(uname -s 2>/dev/null || echo unknown)
  fi
  printf '%s\n' "$FM_PLATFORM_UNAME"
}

FM_PLATFORM_IS_WINDOWS="${FM_PLATFORM_IS_WINDOWS:-${FM_IS_WINDOWS:-}}"
fm_platform_is_windows() {
  if [ -z "$FM_PLATFORM_IS_WINDOWS" ]; then
    case "$(fm_platform_uname)" in
      CYGWIN*|MINGW*|MSYS*) FM_PLATFORM_IS_WINDOWS=yes ;;
      *) FM_PLATFORM_IS_WINDOWS=no ;;
    esac
  fi
  [ "$FM_PLATFORM_IS_WINDOWS" = yes ]
}

fm_platform_is_macos() {
  [ "$(fm_platform_uname)" = Darwin ]
}

fm_platform_temp_root() {
  if fm_platform_is_windows; then
    printf '%s\n' "${TMPDIR:-/tmp}"
  else
    printf '%s\n' /tmp
  fi
}

fm_platform_userprofile_to_posix() {
  local p=$1 drive rest
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$p" 2>/dev/null && return 0
  fi
  case "$p" in
    [A-Za-z]:\\*)
      drive=$(printf '%s' "${p%%:*}" | tr '[:upper:]' '[:lower:]')
      rest=${p#?:\\}
      rest=${rest//\\//}
      printf '/%s/%s\n' "$drive" "$rest"
      ;;
    *) printf '%s\n' "$p" ;;
  esac
}

fm_platform_home_dir() {
  if [ -n "${HOME:-}" ]; then
    printf '%s\n' "$HOME"
    return 0
  fi
  if fm_platform_is_windows && [ -n "${USERPROFILE:-}" ]; then
    fm_platform_userprofile_to_posix "$USERPROFILE"
    return 0
  fi
  return 1
}

fm_platform_ps_fixed_line() {  # <pid>
  local pid=$1 line first second
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    [ -n "$line" ] || continue
    first=${line%%[[:space:]]*}
    case "$first" in
      I|S|O)
        line=${line#"$first"}
        line=${line#"${line%%[![:space:]]*}"}
        second=${line%%[[:space:]]*}
        first=$second
        ;;
    esac
    [ "$first" = "$pid" ] || continue
    printf '%s\n' "$line"
    return 0
  done <<EOF
$(ps -p "$pid" 2>/dev/null || true)
EOF
  return 1
}

# Parse MSYS/Cygwin fixed-column ps output:
# PID PPID PGID WINPID TTY UID STIME COMMAND
fm_platform_ps_fixed_field() {  # <pid> <field>
  local pid=$1 field=$2 line pid_f ppid _pgid _winpid _tty _uid stime command next
  line=$(fm_platform_ps_fixed_line "$pid") || return 1
  read -r pid_f ppid _pgid _winpid _tty _uid stime command <<EOF
$line
EOF
  [ "$pid_f" = "$pid" ] || return 1
  case "$stime" in
    Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)
      next=${command%%[[:space:]]*}
      [ "$next" != "$command" ] || return 1
      stime="$stime $next"
      command=${command#"$next"}
      command=${command#"${command%%[![:space:]]*}"}
      ;;
  esac
  case "$field" in
    pid) printf '%s\n' "$pid_f" ;;
    ppid) printf '%s\n' "$ppid" ;;
    comm) printf '%s\n' "$command" ;;
    args|command) printf '%s\n' "$command" ;;
    stime) printf '%s\n' "$stime" ;;
    *) return 1 ;;
  esac
}

fm_platform_ps_field() {  # <pid> <field>
  local pid=$1 field=$2 out
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$field" in
    ppid) out=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]') ;;
    comm) out=$(ps -o comm= -p "$pid" 2>/dev/null) ;;
    args) out=$(ps -o args= -p "$pid" 2>/dev/null) ;;
    *) return 1 ;;
  esac
  if [ -n "$out" ]; then
    case "$field:$out" in
      ppid:*[!0-9]*|*:*$'\n'*) : ;;
      *) printf '%s\n' "$out"; return 0 ;;
    esac
  fi
  fm_platform_ps_fixed_field "$pid" "$field"
}

fm_platform_pid_identity() {  # <pid>
  local pid=$1 out rest starttime cmd
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null)
  if [ -n "$out" ]; then
    case "$out" in
      *$'\n'*|PID[[:space:]]*) : ;;
      *) printf '%s\n' "$out" | sed 's/^[[:space:]]*//'; return 0 ;;
    esac
  fi
  if [ -r "/proc/$pid/stat" ]; then
    IFS= read -r out < "/proc/$pid/stat" 2>/dev/null || return 1
    rest=${out##*) }
    # shellcheck disable=SC2086 # deliberate word-splitting to index stat fields.
    set -- $rest
    starttime=${20:-}
    if [ -n "$starttime" ]; then
      cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
      printf '%s %s\n' "$starttime" "$cmd"
      return 0
    fi
  fi
  return 1
}
