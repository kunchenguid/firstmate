#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

FM_HARNESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# Known harness command names; extend when a new adapter is verified. OMP's
# exact Bun-script shape is verified alongside its primary and worker adapter.
# shellcheck disable=SC2034 # Sourced callers use this public harness pattern.
FM_HARNESS_RE='^(claude|codex|opencode|grok|kimi)(-|$)|^pi$|^pi-signed$|^omp$'

# Exact executable names for the stricter path evidence below. Keep in sync
# with the non-interpreter names in FM_HARNESS_RE. The exact-component check
# avoids treating ordinary
# firstmate paths such as bin/fm-claude-stop-autoarm.sh as harness processes.
# OMP's Bun shape is matched by its canonical executable or script path below.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

fm_harness_read_regular_nofollow() {
  local path=${1:-} directory name
  [ "$#" -eq 1 ] && [ -n "$path" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  case "$path" in
    */*) directory=${path%/*}; name=${path##*/}; [ -n "$directory" ] || directory=/ ;;
    *) directory=.; name=$path ;;
  esac
  case "$name" in ''|.|..|*/*) return 1 ;; esac
  python3 "$FM_HARNESS_LIB_DIR/fm-omp-fs.py" read-file "$directory" "$name" ""
}

fm_harness_regular_identity_nofollow() {
  local path=${1:-} directory name
  [ "$#" -eq 1 ] && [ -n "$path" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  case "$path" in
    */*) directory=${path%/*}; name=${path##*/}; [ -n "$directory" ] || directory=/ ;;
    *) directory=.; name=$path ;;
  esac
  case "$name" in ''|.|..|*/*) return 1 ;; esac
  python3 "$FM_HARNESS_LIB_DIR/fm-omp-fs.py" identity-file "$directory" "$name" ""
}

fm_harness_unlink_regular_nofollow_at() {
  local directory=${1:-} name=${2:-} expected_directory=${3:-} expected_entry=${4:-}
  [ "$#" -ge 2 ] && [ -n "$directory" ] && [ -n "$name" ] || return 1
  case "$name" in */*|.|..) return 1 ;; esac
  command -v python3 >/dev/null 2>&1 || return 1
  python3 "$FM_HARNESS_LIB_DIR/fm-omp-fs.py" \
    remove-file "$directory" "$name" "$expected_directory" "$expected_entry"
}

fm_harness_rmdir_nofollow_at() {
  local directory=${1:-} name=${2:-} expected_directory=${3:-} expected_entry=${4:-}
  [ "$#" -ge 2 ] && [ -n "$directory" ] && [ -n "$name" ] || return 1
  case "$name" in */*|.|..) return 1 ;; esac
  command -v python3 >/dev/null 2>&1 || return 1
  python3 "$FM_HARNESS_LIB_DIR/fm-omp-fs.py" \
    remove-directory "$directory" "$name" "$expected_directory" "$expected_entry"
}

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

fm_harness_omp_attribution_allowed() {
  [ -z "${FM_HARNESS_UNVERIFIED:-}" ]
}

fm_harness_omp_resolve_path() {  # <path>
  local path=$1 target dir base
  [ -n "$path" ] || return 1
  dir=${path%/*}
  [ "$dir" != "$path" ] || dir=.
  [ -n "$dir" ] || dir=/
  base=${path##*/}
  path=$(CDPATH='' cd -- "$dir" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$base") || return 1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    if [ ! -L "$path" ]; then
      [ -f "$path" ] && [ -x "$path" ] || return 1
      printf '%s' "$path"
      return 0
    fi
    target=$(readlink "$path" 2>/dev/null) || return 1
    case "$target" in
      /*) path=$target ;;
      *) path="${path%/*}/$target" ;;
    esac
    dir=${path%/*}
    [ "$dir" != "$path" ] || dir=.
    [ -n "$dir" ] || dir=/
    base=${path##*/}
    path=$(CDPATH='' cd -- "$dir" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$base") || return 1
  done
  return 1
}

fm_harness_omp_command_path() {
  local command_path
  command_path=$(command -v omp 2>/dev/null) || return 1
  fm_harness_omp_resolve_path "$command_path"
}

fm_harness_bun_command_path() {
  local command_path
  command_path=$(command -v bun 2>/dev/null) || return 1
  fm_harness_omp_resolve_path "$command_path"
}

fm_harness_process_executable() {  # <pid> [ps-bin]
  local pid=$1 ps_bin=${2:-ps} path lsof_bin
  case "$pid" in
    ''|*[!0-9]*|0|1) return 1 ;;
  esac
  if [ -L "/proc/$pid/exe" ]; then
    path=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
    case "$path" in
      */*) [ -f "$path" ] && [ -x "$path" ] && { printf '%s' "$path"; return 0; } ;;
    esac
  fi
  path=$(LC_ALL=C "$ps_bin" -p "$pid" -o comm= 2>/dev/null) || path=
  path=$(printf '%s\n' "$path" | awk 'NF { sub(/^[[:space:]]+/, "", $0); sub(/[[:space:]]+$/, "", $0); print; count++ } END { if (count != 1) exit 2 }') || path=
  case "$path" in
    */*) [ -f "$path" ] && [ -x "$path" ] && { printf '%s' "$path"; return 0; } ;;
  esac
  lsof_bin=$(command -v lsof 2>/dev/null || true)
  if [ -n "$lsof_bin" ]; then
    path=$(LC_ALL=C "$lsof_bin" -n -P -a -p "$pid" -d txt -Fn 2>/dev/null | awk '/^n/ { print substr($0, 2); exit }')
    case "$path" in
      */*) [ -f "$path" ] && [ -x "$path" ] && { printf '%s' "$path"; return 0; } ;;
    esac
  fi
  return 1
}

fm_harness_omp_script_from_args() {  # <argv-text>
  local args=${1:-} rest target
  args=${args#"${args%%[![:space:]]*}"}
  [ -n "$args" ] || return 1
  rest=${args#"${args%%[[:space:]]*}"}
  rest=${rest#"${rest%%[![:space:]]*}"}
  [ -n "$rest" ] || return 1
  target=${rest%%[[:space:]]*}
  if [ "$target" = run ]; then
    rest=${rest#"$target"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || return 1
    target=${rest%%[[:space:]]*}
  fi
  printf '%s' "$target"
}

fm_harness_omp_script_matches() {  # <path>
  local path=$1 expected actual
  case "$path" in */*) ;; *) return 1 ;; esac
  fm_harness_omp_attribution_allowed || return 1
  expected=$(fm_harness_omp_command_path) || return 1
  actual=$(fm_harness_omp_resolve_path "$path") || return 1
  [ "$actual" = "$expected" ]
}

fm_harness_omp_process_matches() {  # <comm> <args> [executable] [script]
  local comm=$1 args=${2:-} executable=${3:-} script=${4:-} expected bun_path actual
  fm_harness_omp_attribution_allowed || return 1
  [ -n "$executable" ] || return 1
  expected=$(fm_harness_omp_command_path) || return 1
  actual=$(fm_harness_omp_resolve_path "$executable") || return 1
  [ "$actual" = "$expected" ] && return 0
  bun_path=$(fm_harness_bun_command_path) || return 1
  [ "$actual" = "$bun_path" ] || return 1
  [ -n "$script" ] || return 1
  fm_harness_omp_script_matches "$script"
}

fm_harness_identity_supported() {  # <identity>
  case "$1" in
    claude|codex|opencode|grok|kimi|muse|pi|pi-signed|omp) return 0 ;;
    *) return 1 ;;
  esac
}

fm_harness_identity_matches() {  # <expected> <actual>
  local expected=$1 actual=$2
  case "$expected" in
    omp) [ "$actual" = omp ] ;;
    pi|pi-signed) case "$actual" in pi|pi-signed) return 0 ;; *) return 1 ;; esac ;;
    claude*) [ "$actual" = claude ] ;;
    codex*) [ "$actual" = codex ] ;;
    opencode*) [ "$actual" = opencode ] ;;
    grok*) [ "$actual" = grok ] ;;
    kimi*) [ "$actual" = kimi ] ;;
    muse*) [ "$actual" = muse ] ;;
    ''|unknown) fm_harness_identity_supported "$actual" ;;
    *) [ "$expected" = "$actual" ] ;;
  esac
}

fm_harness_muse_executable_matches() {  # <executable>
  local executable=${1:-} resolved base
  [ -n "$executable" ] || return 1
  resolved=$(fm_harness_omp_resolve_path "$executable") || return 1
  base=${resolved##*/}
  base=${base#-}
  case "$base" in
    muse|muse-bin-*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_harness_process_identity() {  # <comm> <args> [executable] [script] -> harness|shell|other
  local comm=$1 args=${2:-} executable=${3:-} script=${4:-} base name
  [ -n "$comm" ] || { printf 'unknown'; return 0; }
  if fm_harness_omp_process_matches "$comm" "$args" "$executable" "$script"; then
    printf 'omp'
    return 0
  fi
  base=$(basename -- "$comm")
  base=${base#-}
  case "$base" in
    claude|claude-*) printf 'claude'; return 0 ;;
    codex|codex-*) printf 'codex'; return 0 ;;
    opencode|opencode-*) printf 'opencode'; return 0 ;;
    grok|grok-*) printf 'grok'; return 0 ;;
    kimi|kimi-*) printf 'kimi'; return 0 ;;
    muse|muse-bin-*)
      if fm_harness_muse_executable_matches "$executable"; then
        printf 'muse'
        return 0
      fi
      ;;
    pi|pi-signed)
      printf '%s' "$base"
      return 0
      ;;
    pi-launcher|Pi) printf 'pi'; return 0 ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'shell'; return 0 ;;
  esac
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "${args%% *}"); then
    printf '%s' "$name"
    return 0
  fi
  case "$base" in
    node|nodejs|python|python3)
      script=${args#* }
      script=${script%% *}
      if name=$(fm_harness_path_name "$script"); then
        printf '%s' "$name"
        return 0
      fi
      ;;
  esac
  printf 'other'
}

fm_harness_process_owner_state() {
  local pid=$1 owner=$2 ps_bin=${3:-ps} environment rc
  case "$pid" in ''|*[!0-9]*|0|1) return 2 ;; esac
  case "$owner" in ''|*[!A-Za-z0-9._-]*) return 2 ;; esac
  if [ -r "/proc/$pid/environ" ]; then
    environment=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null) || return 2
  else
    environment=$(LC_ALL=C "$ps_bin" eww -p "$pid" -o command= 2>/dev/null) || return 2
  fi
  printf '%s\n' "$environment" | awk -v expected="FM_RAW_LAUNCH_OWNER=$owner" '
    { for (i = 1; i <= NF; i++) if ($i == expected) found = 1 }
    END { exit(found ? 0 : 1) }
  ' && return 0
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

fm_harness_raw_owner_state() {
  local root=$1 owner=$2 ps_bin=${3:-ps} foreground_pids=${4:-} current_identity=${5:-}
  local rows all_pids rc pid owner_state comm args executable script identity marker_count=0
  local foreground_count=0 owner_omp=0 owner_supported=
  case "$root" in ''|*[!0-9]*|0|1) printf 'unknown'; return 0 ;; esac
  case "$owner" in ''|*[!A-Za-z0-9._-]*) printf 'unknown'; return 0 ;; esac
  fm_harness_identity_supported "$current_identity" || {
    printf 'unknown'
    return 0
  }
  if fm_harness_process_owner_state "$root" "$owner" "$ps_bin" >/dev/null 2>&1; then
    :
  else
    printf 'unknown'
    return 0
  fi
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    case "$pid" in ''|*[!0-9]*|0|1) printf 'unknown'; return 0 ;; esac
    foreground_count=$((foreground_count + 1))
    owner_state=$(fm_harness_process_owner_state "$pid" "$owner" "$ps_bin")
    [ "$?" -eq 0 ] || { printf 'unknown'; return 0; }
  done <<EOF
$foreground_pids
EOF
  [ "$foreground_count" -gt 0 ] || { printf 'unknown'; return 0; }

  rows=$(LC_ALL=C "$ps_bin" -axo pid=,ppid= 2>/dev/null) || {
    printf 'unknown'
    return 0
  }
  all_pids=$(printf '%s\n' "$rows" | awk -v root="$root" '
    NF == 0 { next }
    NF != 2 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { bad = 1; next }
    { if (seen[$1]++) bad = 1; if ($1 == root) root_count++; if ($1 > 1) print $1 }
    END { if (bad || root_count != 1) exit 2 }
  ')
  rc=$?
  [ "$rc" -eq 0 ] && [ -n "$all_pids" ] || {
    printf 'unknown'
    return 0
  }
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    owner_state=$(fm_harness_process_owner_state "$pid" "$owner" "$ps_bin")
    case "$?" in
      1) continue ;;
      2) printf 'unknown'; return 0 ;;
    esac
    marker_count=$((marker_count + 1))
    comm=$(LC_ALL=C "$ps_bin" -p "$pid" -o comm= 2>/dev/null) || {
      printf 'unknown'
      return 0
    }
    comm=$(printf '%s\n' "$comm" | awk 'NF { sub(/^[[:space:]]+/, "", $0); sub(/[[:space:]]+$/, "", $0); print; count++ } END { if (count != 1) exit 2 }') || {
      printf 'unknown'
      return 0
    }
    args=$(LC_ALL=C "$ps_bin" -p "$pid" -o args= 2>/dev/null) || {
      printf 'unknown'
      return 0
    }
    args=$(printf '%s\n' "$args" | awk 'NF { sub(/^[[:space:]]+/, "", $0); sub(/[[:space:]]+$/, "", $0); print; count++ } END { if (count != 1) exit 2 }') || {
      printf 'unknown'
      return 0
    }
    executable=$(fm_harness_process_executable "$pid" "$ps_bin" 2>/dev/null || true)
    script=
    if [ -n "$executable" ] && [ "$(basename -- "$executable")" = bun ]; then
      script=$(fm_harness_omp_script_from_args "$args" 2>/dev/null || true)
    fi
    identity=$(unset FM_HARNESS_UNVERIFIED; fm_harness_process_identity "$comm" "$args" "$executable" "$script")
    case "$identity" in
      omp) owner_omp=1 ;;
      shell) : ;;
      claude|codex|opencode|grok|kimi|muse|pi|pi-signed)
        if [ -z "$owner_supported" ]; then
          owner_supported=$identity
        elif ! fm_harness_identity_matches "$owner_supported" "$identity"; then
          printf 'unknown'
          return 0
        fi
        ;;
      *) : ;;
    esac
  done <<EOF
$all_pids
EOF
  [ "$marker_count" -gt 0 ] || { printf 'unknown'; return 0; }
  if [ "$owner_omp" -eq 1 ]; then
    printf 'omp'
    return 0
  fi
  case "$current_identity" in
    omp)
      printf 'unknown'
      ;;
    claude|codex|opencode|grok|kimi|muse|pi|pi-signed)
      if [ -n "$owner_supported" ] && fm_harness_identity_matches "$current_identity" "$owner_supported"; then
        printf '%s' "$current_identity"
      else
        printf 'unknown'
      fi
      ;;
    *) printf 'unknown' ;;
  esac
}

fm_harness_process_tree_identity() {  # <root-pid> [ps-bin] -> harness|shell|other|unknown
  local root=$1 ps_bin=${2:-ps} rows tree pid comm args executable script identity current_identity= shell_seen=0 rc
  case "$root" in
    ''|*[!0-9]*|0|1) printf 'unknown'; return 0 ;;
  esac
  command -v "$ps_bin" >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  rows=$(LC_ALL=C "$ps_bin" -axo pid=,ppid= 2>/dev/null) || {
    printf 'unknown'
    return 0
  }
  tree=$(printf '%s\n' "$rows" | awk -v root="$root" '
    NF == 0 { next }
    NF != 2 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { bad=1; next }
    {
      pid[++n]=$1
      ppid[n]=$2
      if (seen[$1]++) bad=1
      if ($1 == root) root_count++
    }
    END {
      if (bad || root_count != 1) exit 2
      found[root]=1
      for (round=0; round<=n; round++) {
        changed=0
        for (i=1; i<=n; i++) {
          if (found[ppid[i]] && !found[pid[i]]) {
            found[pid[i]]=1
            changed=1
          }
        }
        if (!changed) break
      }
      for (i=1; i<=n; i++) if (found[pid[i]]) print pid[i]
    }
  ')
  rc=$?
  [ "$rc" -eq 0 ] && [ -n "$tree" ] || {
    printf 'unknown'
    return 0
  }
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    comm=$(LC_ALL=C "$ps_bin" -p "$pid" -o comm= 2>/dev/null) || {
      printf 'unknown'
      return 0
    }
    comm=$(printf '%s\n' "$comm" | awk 'NF { sub(/^[[:space:]]+/, "", $0); sub(/[[:space:]]+$/, "", $0); print; count++ } END { if (count != 1) exit 2 }') || {
      printf 'unknown'
      return 0
    }
    args=$(LC_ALL=C "$ps_bin" -p "$pid" -o args= 2>/dev/null) || {
      printf 'unknown'
      return 0
    }
    args=$(printf '%s\n' "$args" | awk 'NF { sub(/^[[:space:]]+/, "", $0); sub(/[[:space:]]+$/, "", $0); print; count++ } END { if (count != 1) exit 2 }') || {
      printf 'unknown'
      return 0
    }
    executable=$(fm_harness_process_executable "$pid" "$ps_bin" 2>/dev/null || true)
    script=
    if [ -n "$executable" ] && [ "$(basename -- "$executable")" = bun ]; then
      script=$(fm_harness_omp_script_from_args "$args" 2>/dev/null || true)
    fi
    identity=$(fm_harness_process_identity "$comm" "$args" "$executable" "$script")
    case "$identity" in
      omp)
        printf 'omp'
        return 0
        ;;
      unknown)
        printf 'unknown'
        return 0
        ;;
      shell) shell_seen=1 ;;
      *)
        if fm_harness_identity_supported "$identity"; then
          if [ -z "$current_identity" ]; then
            current_identity=$identity
          elif ! fm_harness_identity_matches "$current_identity" "$identity"; then
            printf 'unknown'
            return 0
          fi
        fi
        ;;
    esac
  done <<EOF
$tree
EOF
  if [ -n "$current_identity" ]; then
    printf '%s' "$current_identity"
  elif [ "$shell_seen" -eq 1 ]; then
    printf 'shell'
  else
    printf 'other'
  fi
}

fm_harness_process_tree_omp_state() {  # <root-pid> [ps-bin] -> omp|other|unknown
  case "$(fm_harness_process_tree_identity "$@")" in
    omp) printf 'omp' ;;
    unknown) printf 'unknown' ;;
    *) printf 'other' ;;
  esac
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python, bun) running the exact harness script.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args> [executable] [script]
  local comm=${1:-} args=${2:-} executable=${3:-} script=${4:-} base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  base=${base#-}
  if fm_harness_omp_process_matches "$comm" "$args" "$executable" "$script"; then
    return 0
  fi
  [ "$base" = omp ] && return 1
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare Node or Python interpreter: match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

fm_harness_lock_process_matches() {  # <comm> <args> [executable] [script]
  fm_harness_process_matches "${1:-}" "${2:-}" "${3:-}" "${4:-}"
}

# Walk the current process ancestry (up to 80 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args executable script ppid extending=0 printed=0 steps=0
  while [ "$steps" -lt 80 ]; do
    steps=$((steps + 1))
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    executable=$(fm_harness_process_executable "$pid" ps 2>/dev/null || true)
    script=
    if [ -n "$executable" ] && [ "$(basename -- "$executable")" = bun ]; then
      script=$(fm_harness_omp_script_from_args "$args" 2>/dev/null || true)
    fi
    if fm_harness_lock_process_matches "$comm" "$args" "$executable" "$script"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || break
    case "$ppid" in
      ''|*[!0-9]*) break ;;
      0|1) break ;;
    esac
    pid=$ppid
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid comm args executable script identity first_pid='' first_identity='' claude_owner=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
    executable=$(fm_harness_process_executable "$pid" ps 2>/dev/null || true)
    script=
    if [ -n "$executable" ] && [ "$(basename -- "$executable")" = bun ]; then
      script=$(fm_harness_omp_script_from_args "$args" 2>/dev/null || true)
    fi
    identity=$(fm_harness_process_identity "$comm" "$args" "$executable" "$script")
    if [ -z "$first_pid" ]; then
      first_pid=$pid
      first_identity=$identity
    fi
    [ "$identity" = claude ] && claude_owner=$pid
  done <<EOF
$pids
EOF
  if [ "$first_identity" = claude ] && [ "${CLAUDECODE:-}" = 1 ] && [ -n "$claude_owner" ]; then
    printf '%s\n' "$claude_owner"
  else
    printf '%s\n' "$first_pid"
  fi
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=${1:-} comm args executable script
  case "$pid" in
    ''|*[!0-9]*|0|1) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  executable=$(fm_harness_process_executable "$pid" ps 2>/dev/null || true)
  script=
  if [ -n "$executable" ] && [ "$(basename -- "$executable")" = bun ]; then
    script=$(fm_harness_omp_script_from_args "$args" 2>/dev/null || true)
  fi
  fm_harness_lock_process_matches "$comm" "$args" "$executable" "$script"
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
