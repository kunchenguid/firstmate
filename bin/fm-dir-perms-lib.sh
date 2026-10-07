#!/usr/bin/env bash
# fm-dir-perms-lib.sh - portable owner-only directory creation and validation.
#
# Single owner for the "create a private directory with an explicit mode, then
# prove it is private" contract that machine-shared lock, state, and cache
# namespaces rely on, including stable ancestors that cannot be replaced by
# other users. Callers that only read a directory use
# fm_dir_owner_only_valid; callers that create or repair one use
# fm_dir_owner_only_ensure.
#
# Why this exists: a shared temporary parent can carry a setgid bit, making
# every directory created beneath it inherit that bit, so `mkdir -m 700`
# actually yields mode 2700. Two further surprises make a naive fix wrong:
#   - GNU chmod preserves a directory's special bits unless a symbolic mode
#     mentions them, so `chmod 700` can leave 2700; `chmod a-st` clears setuid,
#     setgid, and sticky bits on a directory.
#   - A validator that demands exactly 700 then refuses a directory that is
#     still owner-only - group and other have no permission bits - so the
#     lifecycle preflight fails until someone fixes the mode by hand.
# The setgid bit does not by itself grant access; only group/other permission
# bits do. Validation therefore tolerates a special bit, while ensure clears it
# so a freshly created namespace is exactly 0700.
#
# Contract:
#   fm_dir_perms_mode <dir>          print the octal mode, or fail
#   fm_dir_perms_uid <dir>           print the numeric owner uid, or fail
#   fm_dir_perms_owner <dir>         print "<mode>/<uid>", or "unknown/unknown"
#   fm_dir_owner_only_valid <dir>    success iff <dir> is a real directory (not
#                                    a symlink), owned by this user, with no
#                                    group or other permission bits set; a
#                                    special bit such as setgid is tolerated
#   fm_dir_owner_only_ensure <dir> <label>
#                                    create <dir> as mode 0700 when absent,
#                                    normalize an existing owner-only directory,
#                                    and refuse an existing open directory or
#                                    replaceable parent before changing it. On
#                                    failure print one precise
#                                    diagnostic naming <label>, the observed
#                                    owner and mode, and what refused.

# fm_dir_perms_stat_style: select the platform's stat syntax once per call site
# so a BSD/GNU mismatch can never silently yield an empty mode. GNU stat treats
# -f as a filesystem report, so the Darwin branch is checked first.
fm_dir_perms_mode() {  # <dir>
  local dir=$1 raw
  [ -n "$dir" ] || return 1
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    raw=$(/usr/bin/stat -f '%p' "$dir" 2>/dev/null) || return 1
    case "$raw" in ''|*[!0-7]*) return 1 ;; esac
    printf '%o\n' "$((8#$raw & 07777))"
  else
    stat -c '%a' "$dir" 2>/dev/null
  fi
}

fm_dir_perms_uid() {  # <dir>
  local dir=$1
  [ -n "$dir" ] || return 1
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    /usr/bin/stat -f '%u' "$dir" 2>/dev/null
  else
    stat -c '%u' "$dir" 2>/dev/null
  fi
}

# fm_dir_perms_owner: one display token for diagnostics. Never fails; an
# unreadable directory reports unknown rather than an empty string.
fm_dir_perms_owner() {  # <dir>
  local dir=$1 mode uid
  mode=$(fm_dir_perms_mode "$dir") || mode=
  uid=$(fm_dir_perms_uid "$dir") || uid=
  printf '%s/%s' "${mode:-unknown}" "${uid:-unknown}"
}

fm_dir_owner_only_valid() {  # <dir>
  local dir=$1 mode owner expected_uid
  [ -n "$dir" ] || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  expected_uid=$(id -u 2>/dev/null) || return 1
  [ -n "$expected_uid" ] || return 1
  owner=$(fm_dir_perms_uid "$dir") || return 1
  [ "$owner" = "$expected_uid" ] || return 1
  mode=$(fm_dir_perms_mode "$dir") || return 1
  case "$mode" in ''|*[!0-7]*) return 1 ;; esac
  # Owner-only means group and other hold no permission bits. The setgid bit a
  # parent may have imposed is deliberately not part of this test.
  [ $((8#$mode & 077)) -eq 0 ]
}

fm_dir_parent_stable() {  # <dir>
  local path=$1 parent resolved candidate mode owner expected_uid
  [ -n "$path" ] || return 1
  case "$path" in
    /*) ;;
    *) path="$PWD/$path" ;;
  esac
  parent=$(dirname -- "$path")
  resolved=$(CDPATH='' cd -P -- "$parent" 2>/dev/null && pwd -P) || return 1
  expected_uid=$(id -u 2>/dev/null) || return 1
  for candidate in "$parent" "$resolved"; do
    while :; do
      [ -d "$candidate" ] || return 1
      owner=$(fm_dir_perms_uid "$candidate") || return 1
      [ "$owner" = 0 ] || [ "$owner" = "$expected_uid" ] || return 1
      if [ ! -L "$candidate" ]; then
        mode=$(fm_dir_perms_mode "$candidate") || return 1
        case "$mode" in ''|*[!0-7]*) return 1 ;; esac
        if [ $((8#$mode & 022)) -ne 0 ] && [ $((8#$mode & 01000)) -eq 0 ]; then
          return 1
        fi
      fi
      [ "$candidate" != / ] || break
      candidate=$(dirname -- "$candidate")
    done
  done
}

fm_dir_namespace_parent() {  # <preferred-parent> <namespace-name>
  local preferred=$1 name=$2
  if fm_dir_parent_stable "$preferred/$name"; then
    printf '%s' "$preferred"
  elif [ -n "${HOME:-}" ] && fm_dir_parent_stable "$HOME/$name"; then
    printf '%s' "$HOME"
  else
    return 1
  fi
}

fm_dir_owner_only_ensure() {  # <dir> <label>
  local dir=$1 label=${2:-directory} parent parent_real
  [ -n "$dir" ] || {
    echo "error: $label path is empty" >&2
    return 1
  }
  # BSD chmod treats `--` as a filename. Keep relative paths from looking like
  # options so the same chmod invocation works on macOS and GNU systems.
  case "$dir" in
    /*|./*|../*) ;;
    *) dir="./$dir" ;;
  esac
  case "$dir" in
    */) dir=${dir%/} ;;
  esac
  [ -n "$dir" ] || {
    echo "error: $label path is empty" >&2
    return 1
  }
  parent=$(dirname -- "$dir")
  if ! fm_dir_parent_stable "$dir"; then
    echo "error: $label parent directory $parent is missing or replaceable by another user (observed $(fm_dir_perms_owner "$parent")); refusing to use it" >&2
    return 1
  fi
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    if [ -L "$dir" ] || [ ! -d "$dir" ]; then
      echo "error: $label $dir exists but is not a plain directory (observed $(fm_dir_perms_owner "$dir")); refusing to use it" >&2
      return 1
    fi
  else
    parent_real=$(CDPATH='' cd -P -- "$parent" 2>/dev/null && pwd -P) || {
      echo "error: $label parent directory ${parent:-<none>} does not resolve to a real directory" >&2
      return 1
    }
    mkdir -m 700 -- "$parent_real/$(basename -- "$dir")" 2>/dev/null || {
      [ -d "$dir" ] || {
        echo "error: $label $dir could not be created" >&2
        return 1
      }
    }
  fi
  # An existing open directory may already contain files planted while it was
  # writable by others. Refuse it before changing permissions; only an already
  # owner-only directory (including an inherited setgid bit) is safe to repair.
  if ! fm_dir_owner_only_valid "$dir"; then
    echo "error: $label $dir is not a private directory owned by this user (observed $(fm_dir_perms_owner "$dir")); refusing to use it" >&2
    return 1
  fi
  # GNU chmod preserves directory special bits, and a setgid parent imposes
  # one at creation, so clear setuid, setgid, and sticky after setting 0700.
  if ! chmod 700 "$dir" 2>/dev/null || ! chmod a-st "$dir" 2>/dev/null; then
    echo "error: $label $dir could not be secured to mode 0700 (observed $(fm_dir_perms_owner "$dir"))" >&2
    return 1
  fi
  if ! fm_dir_owner_only_valid "$dir" || [ "$(fm_dir_perms_mode "$dir")" != 700 ]; then
    echo "error: $label $dir could not be secured to mode 0700 (observed $(fm_dir_perms_owner "$dir"))" >&2
    return 1
  fi
  return 0
}
