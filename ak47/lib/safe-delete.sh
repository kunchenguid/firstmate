#!/usr/bin/env bash
# ak47/lib/safe-delete.sh - guarded removal for anything the ak47 tick deletes.
#
# Sourced, never executed. Self-contained: it depends on nothing outside this
# file, so the same bytes can be copied into H-DevOps unchanged.
#
# The contract, in order, for every removal:
#   1. PATH IDENTITY. Both sides of any path comparison are canonicalised by
#      ak47_path_identity() before they are compared, and a mismatch prints both
#      spellings. A guard that compares "/tmp/fm-x" to "/tmp//fm-x/" without
#      normalising is a guard that silently allows the thing it exists to stop.
#   2. MOUNT HAZARD. A path that is a mountpoint, or that contains one, is never
#      removed: rm --one-file-system treats a mountpoint argument as that
#      filesystem's root.
#   3. OPEN HANDLES. lsof must prove nothing holds a file under the path. A probe
#      that errors is "held", never "free" - fail closed.
#   4. QUARANTINE FIRST. The path is renamed into a private sibling name, the
#      handle scan runs again against the new name, and only then is it removed.
#      A rename is atomic and reversible; an rm is neither.
#
# Public:
#   ak47_path_identity <path>        canonical absolute path, symlinks resolved
#   ak47_path_same <a> <b>           0 when both spell the same path
#   ak47_path_under <path> <root>    0 when path is root or inside it
#   ak47_has_open_handles <path>     0 held, 1 free, 2 could not tell
#   ak47_mount_hazard <path>         0 hazard, 1 clear
#   ak47_safe_delete <path>          guarded removal; echoes freed KiB
#
# Seams (read at call time; tests set them, production does not):
#   AK47_MOUNTS_FILE        default /proc/self/mounts
#   AK47_QUARANTINE_PREFIX  default .ak47-quarantine.
#   AK47_HANDLE_CHECK       function used for the post-rename scan
# Out-vars: AK47_SD_ERROR (last refusal reason), AK47_SD_QPATH (quarantine name).

AK47_SD_ERROR=""
AK47_SD_QPATH=""

# ak47_path_identity <path> - the one canonical spelling of a path.
# Resolves symlinks in every existing component, collapses //, /./ and /../,
# strips a trailing slash, and works for a path that does not exist yet.
ak47_path_identity() {
  local p=${1:-}
  [ -n "$p" ] || return 1
  case "$p" in
    /*) ;;
    *) p="$PWD/$p" ;;
  esac
  if command -v realpath >/dev/null 2>&1 && realpath -m -- "$p" >/dev/null 2>&1; then
    realpath -m -- "$p"
    return 0
  fi
  # Portable fallback: resolve the deepest existing prefix, then normalise the rest.
  python3 - "$p" <<'PY'
import os, sys
p = sys.argv[1]
head, tail = p, []
while head and not os.path.exists(head):
    head, base = os.path.split(head)
    if not base:
        break
    tail.append(base)
real = os.path.realpath(head) if head else "/"
for part in reversed(tail):
    real = os.path.join(real, part)
print(os.path.normpath(real))
PY
}

# ak47_path_same <a> <b> - 0 when both spell the same path.
# On a mismatch it prints both canonical spellings to stderr, so a guard that
# fires can be diagnosed without guessing which side was wrong.
ak47_path_same() {
  local a b
  a=$(ak47_path_identity "$1") || return 2
  b=$(ak47_path_identity "$2") || return 2
  if [ "$a" = "$b" ]; then return 0; fi
  printf 'ak47: path mismatch: %s != %s\n' "$a" "$b" >&2
  return 1
}

# ak47_path_under <path> <root> - 0 when path is root or lives inside it.
# Both sides are canonicalised first; the comparison is on whole components, so
# /tmp/fm-abc is not "under" /tmp/fm-ab.
ak47_path_under() {
  local p r
  p=$(ak47_path_identity "$1") || return 2
  r=$(ak47_path_identity "$2") || return 2
  [ "$p" = "$r" ] && return 0
  case "$p" in
    "$r"/*) return 0 ;;
  esac
  return 1
}

# ak47_mount_hazard <path> - 0 when the path is, or contains, a mountpoint.
# The kernel octal-escapes whitespace in mount paths, so decode before comparing.
ak47_mount_hazard() {
  local mounts=${AK47_MOUNTS_FILE:-/proc/self/mounts} p
  [ -r "$mounts" ] || return 0          # cannot prove absence of a mount -> hazard
  p=$(ak47_path_identity "$1") || return 0
  AK47_MH_P="$p" awk '
    {
      m = $2
      gsub(/\\040/, " ", m); gsub(/\\011/, "\t", m)
      gsub(/\\012/, "\n", m); gsub(/\\134/, "\\", m)
      if (m == ENVIRON["AK47_MH_P"]) found = 1
      if (index(m, ENVIRON["AK47_MH_P"] "/") == 1) found = 1
    }
    END { exit found ? 0 : 1 }' "$mounts"
}

# ak47_has_open_handles <path> - 0 held, 1 free, 2 could not tell.
# lsof -t prints a PID for every process holding anything open under the path.
# rc 1 with empty stderr is lsof's "no matches"; anything else fails closed.
ak47_has_open_handles() {
  local out err rc=0 errf
  command -v lsof >/dev/null 2>&1 || return 2
  errf=$(mktemp) || return 2
  if [ -d "$1" ]; then
    out=$(lsof -t +D "$1" 2>"$errf") || rc=$?
  else
    out=$(lsof -t -- "$1" 2>"$errf") || rc=$?   # +D only accepts directories
  fi
  err=$(cat "$errf" 2>/dev/null); rm -f "$errf"
  [ -n "$out" ] && return 0
  if [ -n "$err" ] || [ "$rc" -gt 1 ]; then return 2; fi
  return 1
}

# ak47_safe_delete <path> - guarded removal. Echoes freed KiB on success.
# Refuses (returns 1) with AK47_SD_ERROR set, and leaves the path untouched.
ak47_safe_delete() {
  local path=$1 id qdir qpath kib rc=0
  AK47_SD_ERROR=""; AK47_SD_QPATH=""
  [ -e "$path" ] || [ -L "$path" ] || { AK47_SD_ERROR="does not exist"; return 1; }
  id=$(ak47_path_identity "$path") || { AK47_SD_ERROR="cannot canonicalise path"; return 1; }
  # A symlink is never followed: removing the link is fine, removing its target
  # through it is not. Refuse anything that is not the canonical path itself.
  if ! ak47_path_same "$path" "$id"; then
    AK47_SD_ERROR="path is not its own canonical spelling (symlink or traversal)"
    return 1
  fi
  if ak47_mount_hazard "$id"; then AK47_SD_ERROR="mountpoint or contains one"; return 1; fi
  ak47_has_open_handles "$id" || rc=$?
  case "$rc" in
    0) AK47_SD_ERROR="open handles"; return 1 ;;
    2) AK47_SD_ERROR="could not prove no open handles"; return 1 ;;
  esac
  kib=$(du -sk -- "$id" 2>/dev/null | awk '{print $1}') || kib=0
  qdir=$(dirname "$id")
  qpath="$qdir/${AK47_QUARANTINE_PREFIX:-.ak47-quarantine.}$(basename "$id").$$"
  if ! mv -f -- "$id" "$qpath" 2>/dev/null; then
    AK47_SD_ERROR="could not quarantine (cross-device or permission)"
    return 1
  fi
  AK47_SD_QPATH=$qpath
  # Re-scan under the new name: a process that opened a file between the first
  # scan and the rename is now visible here, and the rename is reversible.
  rc=0
  ${AK47_HANDLE_CHECK:-ak47_has_open_handles} "$qpath" || rc=$?
  if [ "$rc" -ne 1 ]; then
    mv -f -- "$qpath" "$id" 2>/dev/null || true
    # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
    AK47_SD_ERROR="handle appeared during quarantine; restored"
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    AK47_SD_QPATH=""
    return 1
  fi
  if ! rm -rf --one-file-system -- "$qpath" 2>/dev/null; then
    rm -rf -- "$qpath" 2>/dev/null || true
  fi
  printf '%s' "${kib:-0}"
  return 0
}
