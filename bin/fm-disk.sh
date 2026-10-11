#!/usr/bin/env bash
# fm-disk.sh - disk hygiene for task work copies: a free-space floor checked
# before work that writes heavily, and reclaim of rebuildable build output when
# a task's work copy goes back to the pool.
#
# Usage:
#   fm-disk.sh check <path>      exit 0 when the filesystem holding <path> has at
#                                least the configured floor free; otherwise print
#                                the shortfall and exit 1. A floor of 0 disables
#                                the check. A free figure df cannot report exits 0
#                                with a warning, because an unmeasurable disk is
#                                not proof of a full one.
#   fm-disk.sh reclaim <worktree>
#                                delete each directory under <worktree> whose
#                                name is in the reclaim list and that git confirms
#                                is ignored and holds no tracked file, then print
#                                what was freed. Best effort: it always exits 0
#                                once its arguments are valid, so it never blocks
#                                the cleanup that calls it.
#
# Why: a pooled work copy keeps gitignored files across `treehouse return`, so a
# finished task's node_modules and framework build output (for example a Next.js
# .next directory) survive in the pool and accumulate, and a full disk then fails
# every worker's tests with ENOSPC at once. bin/fm-teardown.sh runs `reclaim` on a
# task's own work copy just before returning it, after every unlanded-work refusal
# has passed and the copy's processes are reaped, and bin/fm-spawn.sh runs `check`
# on the disk that will hold a new work copy before it acquires that copy.
#
# What reclaim may delete, and only this:
#   - a real directory (never a symlink) whose base name is in the reclaim list,
#   - that `git check-ignore` reports ignored in <worktree>'s repository,
#   - under which `git ls-files` lists no tracked file,
#   - and that holds no nested repository (no .git directory or file anywhere
#     inside it), whose own tracked files and history the outer git cannot see;
#     a search for one that fails anywhere leaves the directory alone.
# The walk never enters .git and stops at the first matching directory on each
# branch, so nested matches are removed with their parent. Everything it deletes
# is rebuilt by the project's install or build step; a path git cannot vouch for
# (an error, a nested repository, a tracked file inside) is left alone.
#
# Configuration (local, gitignored, under the effective config directory):
#   config/min-free-disk-gib     one integer, the floor in GiB (1024^3 bytes).
#                                Absent means 5; 0 disables the check.
#   config/reclaim-build-output  directory base names to reclaim, one per line;
#                                blank lines and #-comments are ignored. Absent
#                                means node_modules, .next and .turbo; a file with
#                                no names disables reclaim.
# FM_HOME and FM_CONFIG_OVERRIDE select the config directory as in every other
# bin/ script (docs/configuration.md "FM_HOME").
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

DEFAULT_MIN_FREE_GIB=5
DEFAULT_RECLAIM_NAMES="node_modules .next .turbo"

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-disk: %s\n' "$*" >&2
  exit 2
}

# min_free_gib: print the configured floor, refusing a malformed file rather
# than guessing a number.
min_free_gib() {
  local file="$CONFIG/min-free-disk-gib" value
  if [ ! -e "$file" ]; then
    printf '%s\n' "$DEFAULT_MIN_FREE_GIB"
    return 0
  fi
  value=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$file" | grep -v '^$')
  case "$value" in
    '' | *[!0-9]*) die "$file must hold one non-negative integer (GiB); found '${value}'" ;;
  esac
  printf '%s\n' "$((10#$value))"
}

# reclaim_names: print the reclaim list, one name per line.
reclaim_names() {
  local file="$CONFIG/reclaim-build-output" name
  if [ ! -e "$file" ]; then
    for name in $DEFAULT_RECLAIM_NAMES; do printf '%s\n' "$name"; done
    return 0
  fi
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$file" | grep -v '^$' | while IFS= read -r name; do
    case "$name" in
      . | .. | */* | .git) die "$file names '$name', which is not a plain build-output directory name" ;;
    esac
    printf '%s\n' "$name"
  done
}

human_kib() {
  awk -v k="$1" 'BEGIN {
    if (k >= 1048576) printf "%.1f GiB", k / 1048576
    else if (k >= 1024) printf "%.0f MiB", k / 1024
    else printf "%d KiB", k
  }'
}

cmd_check() {
  local path="$1" floor free_kib
  [ -e "$path" ] || die "check: no such path '$path'"
  floor=$(min_free_gib) || exit 2
  [ "$floor" -gt 0 ] || return 0
  free_kib=$(df -Pk "$path" 2>/dev/null | awk 'NR == 2 { print $4 }')
  case "$free_kib" in
    '' | *[!0-9]*)
      printf 'fm-disk: warning: could not read free space for %s; skipping the %s GiB floor check\n' "$path" "$floor" >&2
      return 0
      ;;
  esac
  if [ "$free_kib" -lt $((floor * 1048576)) ]; then
    printf 'fm-disk: only %s free on the disk holding %s, under the %s GiB floor (config/min-free-disk-gib); free space - idle work copies often hold rebuildable build output - or lower the floor, then retry\n' \
      "$(human_kib "$free_kib")" "$path" "$floor" >&2
    return 1
  fi
}

cmd_reclaim() {
  local wt="$1" names find_args=() name p nested kib total_kib=0 count=0
  [ -d "$wt" ] || die "reclaim: no such directory '$wt'"
  wt=$(cd "$wt" && pwd -P) || die "reclaim: cannot resolve '$wt'"
  if [ "$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)" != "$wt" ]; then
    printf 'fm-disk: reclaim skipped: %s is not the top of a git work tree\n' "$wt" >&2
    return 0
  fi
  names=$(reclaim_names) || exit 2
  [ -n "$names" ] || return 0
  while IFS= read -r name; do
    if [ "${#find_args[@]}" -gt 0 ]; then find_args+=(-o); fi
    find_args+=(-name "$name")
  done <<EOF
$names
EOF
  while IFS= read -r -d '' p; do
    git -C "$wt" check-ignore -q -- "$p" 2>/dev/null || continue
    [ -z "$(git -C "$wt" ls-files -- "$p" 2>/dev/null | head -n 1)" ] || continue
    nested=$(find "$p" -name .git -prune -print 2>/dev/null) || continue
    [ -z "$nested" ] || continue
    kib=$(du -sk "$p" 2>/dev/null | awk '{ print $1 }')
    rm -rf -- "$p" 2>/dev/null || true
    if [ -e "$p" ]; then
      printf 'fm-disk: warning: could not fully remove %s\n' "$p" >&2
      continue
    fi
    total_kib=$((total_kib + ${kib:-0}))
    count=$((count + 1))
  done < <(find "$wt" -name .git -prune -o -type d \( "${find_args[@]}" \) -prune -print0 2>/dev/null)
  if [ "$count" -gt 0 ]; then
    printf 'fm-disk: reclaimed %s of rebuildable build output (%s director%s) from %s\n' \
      "$(human_kib "$total_kib")" "$count" "$([ "$count" -eq 1 ] && echo y || echo ies)" "$wt" >&2
  fi
  return 0
}

case "${1:-}" in
  check)
    [ "$#" -eq 2 ] || die "usage: fm-disk.sh check <path>"
    cmd_check "$2"
    ;;
  reclaim)
    [ "$#" -eq 2 ] || die "usage: fm-disk.sh reclaim <worktree>"
    cmd_reclaim "$2"
    ;;
  -h | --help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
