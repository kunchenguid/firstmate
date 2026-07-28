#!/usr/bin/env bash
# Shared private-artifact primitives for firstmate's generated local state.
#
# This file is sourced, never executed. It is the single owner of how a script
# creates, replaces, and validates a private file under an owner-only directory,
# so every channel that stores untrusted or secret-adjacent material (X mode,
# the Telegram bridge) enforces the same guarantees instead of re-deriving them.
#
# The guarantees a published artifact carries:
#   - its parent directory is a real directory, not a symlink, mode 0700;
#   - the artifact itself is a real file, not a symlink, with exactly one link;
#   - the artifact lives on the same device as its directory, so a swapped
#     mount point cannot redirect a later read;
#   - its mode is exactly the requested 0600 or 0700;
#   - publication is atomic, so a concurrent reader never sees a partial write.
#
# It defines:
#   fm_private_single_link_file_valid <file> [device]
#       - real file, not a symlink, link count 1, optional device match
#   fm_private_single_link_file_mode_valid <file> <mode> [device]
#       - the above plus an exact mode match
#   fm_private_artifact_dir_device <dir>
#       - print the device id of an existing owner-only (0700) real directory
#   fm_private_artifact_dir_prepare <dir>
#       - create the directory chain with umask 077 when needed, then print its
#         device id; refuses a symlinked directory or parent
#   fm_private_artifact_publish_stdin <dir> <base> <600|700>
#       - atomically (re)publish stdin as <dir>/<base>
#   fm_private_artifact_publish_stdin_once <dir> <base> <600|700>
#       - publish only when the destination does not already exist;
#         0 = this caller created it, 1 = a valid artifact already owns the path,
#         2 = unsafe path or publication failure
#   fm_private_artifact_file_valid <dir> <base> <600|700>
#       - validate an already-published artifact
#   fm_private_artifact_remove <dir> <base>
#       - unlink a published artifact only after revalidating the same
#         directory/device/link boundary publication enforces
#   fm_private_artifact_remove_all <dir> [glob]
#       - the same boundary applied to every published artifact under <dir>
#   fm_private_artifact_sweep_temps <dir> <now> <min-age>
#       - remove publication temporaries orphaned by a killed publish
#
# <base> must be a plain file name: no leading dot, no slash. <mode> must be
# exactly 600 or 700. Both are rejected rather than sanitized, so a caller
# cannot smuggle a traversal or a permissive mode through a variable.

# Resolve the platform ONCE, lazily.
#
# Every validator below needs to know whether this is BSD or GNU stat, and
# re-running `uname` per call turned a per-record validation into a per-record
# fork. That cost lands inside the Telegram poll's own check budget, where a
# large retained set could outrun the budget and get the whole check killed.
# The first call forks once; every later call is a pure builtin comparison.
# Detection stays lazy so sourcing this file remains free for a home that never
# touches a private artifact.
fm_private_artifact_is_darwin() {
  if [ -z "${FM_PRIVATE_ARTIFACT_UNAME:-}" ]; then
    FM_PRIVATE_ARTIFACT_UNAME=$(uname 2>/dev/null) || FM_PRIVATE_ARTIFACT_UNAME=unknown
    [ -n "$FM_PRIVATE_ARTIFACT_UNAME" ] || FM_PRIVATE_ARTIFACT_UNAME=unknown
  fi
  [ "$FM_PRIVATE_ARTIFACT_UNAME" = Darwin ]
}

fm_private_single_link_file_valid() {
  local file=$1 expected_device=${2-} links device
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  if fm_private_artifact_is_darwin; then
    links=$(stat -f %l "$file" 2>/dev/null) || return 1
    device=$(stat -f %d "$file" 2>/dev/null) || return 1
  else
    links=$(stat -c %h "$file" 2>/dev/null) || return 1
    device=$(stat -c %d "$file" 2>/dev/null) || return 1
  fi
  [ "$links" = 1 ] || return 1
  [ -z "$expected_device" ] || [ "$device" = "$expected_device" ]
}

fm_private_single_link_file_mode_valid() {
  local file=$1 expected_mode=$2 expected_device=${3-} mode
  fm_private_single_link_file_valid "$file" "$expected_device" || return 1
  if fm_private_artifact_is_darwin; then
    mode=$(stat -f %Lp "$file" 2>/dev/null) || return 1
  else
    mode=$(stat -c %a "$file" 2>/dev/null) || return 1
  fi
  [ "$mode" = "$expected_mode" ]
}

fm_private_artifact_dir_device() {
  local dir=$1 mode device
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  if fm_private_artifact_is_darwin; then
    mode=$(stat -f %Lp "$dir" 2>/dev/null) || return 1
    device=$(stat -f %d "$dir" 2>/dev/null) || return 1
  else
    mode=$(stat -c %a "$dir" 2>/dev/null) || return 1
    device=$(stat -c %d "$dir" 2>/dev/null) || return 1
  fi
  [ "$mode" = 700 ] || return 1
  printf '%s\n' "$device"
}

fm_private_artifact_dir_prepare() {
  local dir=$1 parent
  parent=${dir%/*}
  if [ "$parent" != "$dir" ]; then
    if [ -e "$parent" ] || [ -L "$parent" ]; then
      [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    else
      (umask 077; mkdir -p "$parent" 2>/dev/null) || return 1
      [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    fi
  fi
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  else
    (umask 077; mkdir -p "$dir" 2>/dev/null) || return 1
  fi
  fm_private_artifact_dir_device "$dir"
}

fm_private_artifact_publish_stdin() {
  local dir=$1 base=$2 mode=$3 device tmp dest
  case "$base" in
    ''|.*|*/*) return 1 ;;
  esac
  case "$mode" in
    600|700) ;;
    *) return 1 ;;
  esac
  device=$(fm_private_artifact_dir_prepare "$dir") || return 1
  dest="$dir/$base"
  tmp=$(umask 077; mktemp "$dir/.${base}.fm-private.XXXXXX" 2>/dev/null) || return 1
  if ! cat > "$tmp" \
    || ! chmod "$mode" "$tmp" 2>/dev/null \
    || ! fm_private_single_link_file_mode_valid "$tmp" "$mode" "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if { [ -e "$dest" ] || [ -L "$dest" ]; } \
    && ! fm_private_single_link_file_mode_valid "$dest" "$mode" "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fm_private_single_link_file_mode_valid "$dest" "$mode" "$device"; then
    rm -f -- "$dest"
    return 1
  fi
}

# Publish stdin as a new private artifact without replacing an existing path.
# The hard-link claim is atomic within the prepared directory, so concurrent
# callers cannot both create the destination. Returns 0 when this caller created
# it, 1 when another valid private artifact already owns the path, and 2 on an
# unsafe path or publication failure.
fm_private_artifact_publish_stdin_once() {
  local dir=$1 base=$2 mode=$3 device tmp dest
  case "$base" in
    ''|.*|*/*) return 2 ;;
  esac
  case "$mode" in
    600|700) ;;
    *) return 2 ;;
  esac
  device=$(fm_private_artifact_dir_prepare "$dir") || return 2
  dest="$dir/$base"
  tmp=$(umask 077; mktemp "$dir/.${base}.fm-private.XXXXXX" 2>/dev/null) || return 2
  if ! cat > "$tmp" \
    || ! chmod "$mode" "$tmp" 2>/dev/null \
    || ! fm_private_single_link_file_mode_valid "$tmp" "$mode" "$device"; then
    rm -f -- "$tmp"
    return 2
  fi
  if ln -- "$tmp" "$dest" 2>/dev/null; then
    rm -f -- "$tmp"
    if fm_private_single_link_file_mode_valid "$dest" "$mode" "$device"; then
      return 0
    fi
    rm -f -- "$dest"
    return 2
  fi
  rm -f -- "$tmp"
  if fm_private_single_link_file_mode_valid "$dest" "$mode" "$device"; then
    return 1
  fi
  return 2
}

fm_private_artifact_file_valid() {
  local dir=$1 base=$2 mode=$3 device
  case "$base" in
    ''|.*|*/*) return 1 ;;
  esac
  case "$mode" in
    600|700) ;;
    *) return 1 ;;
  esac
  device=$(fm_private_artifact_dir_device "$dir") || return 1
  fm_private_single_link_file_mode_valid "$dir/$base" "$mode" "$device"
}

# Remove a published artifact through the SAME boundary publication enforces.
#
# Deletion used to be a bare `rm -f "$dir/$base"` in every cleanup path, which
# followed a symlinked artifact directory and deleted whatever it pointed at.
# That made this file's documented "its parent directory is a real directory,
# not a symlink" guarantee false in exactly the direction the guarantee exists
# to prevent, with an attacker-chosen deletion set: replacing `state/telegram`
# with a symlink turned `revoke` into a delete of two files anywhere on disk.
# Every cleanup path now validates the directory and the target immediately
# before unlinking, so publication and deletion share one boundary.
#
# 0 when the path is absent (nothing to clean) or was removed; 1 when the
# boundary refuses - an existing directory that is a symlink, has the wrong
# mode, or sits on another device, or a target that is a symlink, is hard-linked
# elsewhere, or moved to another device since the directory was resolved.
fm_private_artifact_remove() {  # <dir> <base> [validated-device]
  local dir=$1 base=$2 device=${3-} dest
  case "$base" in
    ''|.*|*/*) return 1 ;;
  esac
  # A directory that was never created is vacuously clean, but one that exists
  # and fails validation is refused rather than followed.
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    return 0
  fi
  # A caller sweeping many files in one directory may pass the device it already
  # validated for that directory, so a bounded sweep does not re-stat it per
  # file. Passing nothing resolves and validates it here, which is what every
  # ordinary single-file caller does.
  [ -n "$device" ] || device=$(fm_private_artifact_dir_device "$dir") || return 1
  dest="$dir/$base"
  if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
    return 0
  fi
  fm_private_single_link_file_valid "$dest" "$device" || return 1
  rm -f -- "$dest" 2>/dev/null || return 1
  [ ! -e "$dest" ] && [ ! -L "$dest" ]
}

# Remove every published artifact under <dir> through the boundary above.
# Used by the explicit wipes (revoke, re-pair, opt-out) that must clear a whole
# class of records without ever reaching outside validated private state. The
# glob never matches a leading dot, so an in-flight publication temporary is
# left to fm_private_artifact_sweep_temps rather than raced here. Returns 1 if
# any single removal was refused, so a caller can report a partial wipe
# honestly instead of claiming the channel is clean.
fm_private_artifact_remove_all() {  # <dir> [glob]
  local dir=$1 pattern=${2:-*} file base device rc=0
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    return 0
  fi
  device=$(fm_private_artifact_dir_device "$dir") || return 1
  for file in "$dir"/$pattern; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    base=${file##*/}
    fm_private_artifact_remove "$dir" "$base" "$device" || rc=1
  done
  return "$rc"
}

fm_private_artifact_mtime() {
  if fm_private_artifact_is_darwin; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# Remove publication temporaries left under <dir> and its subdirectories.
#
# Publication writes ".<base>.fm-private.XXXXXX" next to its destination and
# removes it on every failure path, but a process that is KILLED between mktemp
# and the rename cannot - and the watcher does exactly that to a check that
# outruns its budget. The leftover still holds the content that was about to be
# published, and no <base>-shaped scan can see it, so nothing else would ever
# clean it up.
#
# Three further families are matched because they are the same kind of leftover
# written by the same kind of interruptible rewrite, and none of them was
# covered by the .fm-private. glob alone: ".fm-tg-meta.XXXXXX" from the task
# link rewrite, ".fm-generated.XXXXXX" from bootstrap's artifact writes, and
# ".fm-x.XXXXXX" left behind in homes deployed before X mode adopted the shared
# suffix.
#
# <min-age> in seconds protects a publication that is still running: only a
# temporary older than that is removed. Pass 0 only from a caller that knows no
# publish can be in flight, such as an explicit wipe. A temporary that is mid-
# hard-link (two links) is skipped in every case, because it is already becoming
# a real artifact.
fm_private_artifact_sweep_temps() {  # <dir> <now> <min-age>
  local dir=$1 now=$2 min_age=$3 file at cutoff
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  case "$min_age" in ''|*[!0-9]*) return 1 ;; esac
  cutoff=$(( now - min_age ))
  while IFS= read -r -d '' file; do
    fm_private_single_link_file_valid "$file" || continue
    at=$(fm_private_artifact_mtime "$file") || continue
    case "$at" in ''|*[!0-9]*) continue ;; esac
    [ "$at" -le "$cutoff" ] || continue
    rm -f -- "$file" 2>/dev/null || true
  done < <(find "$dir" -type f \
    \( -name '.*.fm-private.*' -o -name '.fm-tg-meta.*' -o -name '.fm-generated.*' -o -name '.fm-x.*' \) \
    -print0 2>/dev/null)
  return 0
}
