#!/usr/bin/env bash
# Shared discovery and reporting of Next.js build output inside a task worktree.
#
# Why this exists: a pooled worktree can return to the pool carrying Next.js
# build output, and Firstmate does not remove it on return. The output
# regenerates from source on the next build, so identifying and measuring it
# gives operators a useful view of accumulated, regenerable disk usage.
#
# Sourced by bin/fm-next-cache-sweep.sh, which reports build output and ownership
# state for every copy announced by a project's pool. The discovery rule is
# stated here once.
#
# WHAT IS REPORTED. Exactly directories named .next that pass BOTH proofs:
#   1. git ignores the directory in the repo that contains it
#      (`git check-ignore`). Tracked content can never match, so no source, no
#      git data, and no committed fixture is reachable by this rule.
#   2. its parent is a Next.js app root: a next.config.{js,cjs,mjs,ts,cts,mts}
#      sits beside it, or the parent's valid package.json names `next` in a
#      recognized dependency table. This is what makes the claim "regenerable
#      build output" true rather than assumed - a gitignored directory that
#      merely happens to be called .next is left alone.
# Nothing is removed. node_modules, source, and git data are out of reporting
# scope by construction, not by exclusion list: the walk prunes node_modules
# and .git outright, and neither could pass proof 2 anyway.
#
# OTHER CACHES ARE DELIBERATELY OUT OF SCOPE. A project's gitignored `.tmp`
# scratch root can hold audit output, coverage JSON, browser recordings, and
# review artifacts that do not regenerate from source, while `dist` can be
# tracked content. A generic cache-like name does not prove regenerability;
# extend this rule only when a specific directory has that proof.
#
# Next.js documents .next as the build output directory (`distDir` defaults to
# '.next') and clears it itself on every production build (`cleanDistDir`
# defaults to true, preserving only .next/cache). That establishes the output as
# regenerable without granting this code authority to remove it.
# A project that sets a custom `distDir` is deliberately NOT discovered: reading
# a build config to decide what to report would make eligibility depend on
# untrusted project code. Such a project remains unreported, which is the safe
# direction to be wrong in.
#
# The walk prunes node_modules and .git, and stops descending at each .next it
# finds, so a nested .next under .next/standalone is reported with its parent
# rather than counted twice.
#
# This library only inspects and reports. The sweep combines its measurements
# with pool state, task records, and tree state to classify each copy. Sourcing
# this file grants no authority to remove anything.

# Bytes-to-human, matching the units du -h prints, so a report line reads the
# same as what an operator would have measured by hand.
fm_next_cache_human_kb() {  # <kilobytes>
  local kb=${1:-} tenths
  case "$kb" in ''|*[!0-9]*) return 1 ;; esac
  kb=$((10#$kb))
  if [ "$kb" -lt 1024 ]; then
    printf '%dK\n' "$kb"
  elif [ "$kb" -lt 1048576 ]; then
    tenths=$(( (kb * 10 + 512) / 1024 ))
    printf '%d.%dM\n' "$(( tenths / 10 ))" "$(( tenths % 10 ))"
  else
    tenths=$(( (kb * 10 + 524288) / 1048576 ))
    printf '%d.%dG\n' "$(( tenths / 10 ))" "$(( tenths % 10 ))"
  fi
}

# Size of <dir> in kilobytes. An unreadable or malformed measurement is not zero.
fm_next_cache_size_kb() {  # <dir>
  local dir=$1 output kb rest
  output=$(du -sk -- "$dir" 2>/dev/null) || return 1
  kb=${output%%[!0-9]*}
  case "$kb" in ''|*[!0-9]*) return 1 ;; esac
  rest=${output#"$kb"}
  case "$rest" in
    $'\t'*|' '*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$kb"
}

# Is <parent> a Next.js app root? See proof 2 in the header.
fm_next_cache_parent_is_next_app() {  # <parent-dir>
  local parent=$1 ext package_status
  for ext in js cjs mjs ts cts mts; do
    [ -f "$parent/next.config.$ext" ] && return 0
  done
  [ -f "$parent/package.json" ] || return 1
  if python3 - "$parent/package.json" <<'PY'
import json
import sys

def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError()
        value[key] = item
    return value

def reject_constant(value):
    raise ValueError()

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        package = json.load(
            handle,
            object_pairs_hook=unique_object,
            parse_constant=reject_constant,
        )
except (OSError, UnicodeError, ValueError):
    sys.exit(2)

if not isinstance(package, dict):
    sys.exit(2)

has_next = False
for field in ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies"):
    if field not in package:
        continue
    dependencies = package[field]
    if not isinstance(dependencies, dict):
        sys.exit(2)
    if "next" in dependencies:
        has_next = True

sys.exit(0 if has_next else 1)
PY
  then
    return 0
  else
    package_status=$?
  fi
  [ "$package_status" -eq 1 ] && return 1
  return 2
}

# Does <dir> pass both proofs, as a real directory inside repo <root>?
fm_next_cache_is_build_output() {  # <repo-root> <dir>
  local root=$1 dir=$2 real parent ignore_status app_status
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then return 2; fi
  [ -d "$dir" ] || return 1
  # A symlink is never reported because its target may live outside the
  # worktree entirely.
  if [ -L "$dir" ]; then return 1; fi
  real=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || return 2
  # Containment: only ever a path physically under the worktree we were given.
  case "$real" in
    "$root"/*) ;;
    *) return 2 ;;
  esac
  if git -C "$root" check-ignore -q -- "$real" 2>/dev/null; then
    ignore_status=0
  else
    ignore_status=$?
  fi
  [ "$ignore_status" -eq 1 ] && return 1
  [ "$ignore_status" -eq 0 ] || return 2
  parent=${real%/*}
  if fm_next_cache_parent_is_next_app "$parent"; then
    return 0
  else
    app_status=$?
  fi
  [ "$app_status" -eq 1 ] && return 1
  return 2
}

FM_NEXT_CACHE_PLAN=
FM_NEXT_CACHE_TOTAL_KB=0
FM_NEXT_CACHE_INSPECTION_ERROR=

fm_next_cache_inspect() {  # <worktree>
  local wt=$1 root tmp dir candidate_status kb record rc=0
  FM_NEXT_CACHE_PLAN=
  FM_NEXT_CACHE_TOTAL_KB=0
  FM_NEXT_CACHE_INSPECTION_ERROR=
  if ! root=$(CDPATH='' cd -- "$wt" 2>/dev/null && pwd -P); then
    FM_NEXT_CACHE_INSPECTION_ERROR="cannot enter worktree: $wt"
    return 1
  fi
  if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    FM_NEXT_CACHE_INSPECTION_ERROR="not an inspectable git worktree: $wt"
    return 1
  fi
  if ! tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-next-cache-find.XXXXXX" 2>/dev/null); then
    FM_NEXT_CACHE_INSPECTION_ERROR="cannot stage build-output discovery for: $wt"
    return 1
  fi
  if ! find "$root" \( -name node_modules -o -name .git \) -prune -o \
    -type d -name .next -print0 -prune > "$tmp" 2>/dev/null; then
    FM_NEXT_CACHE_INSPECTION_ERROR="cannot walk worktree for build output: $wt"
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    while IFS= read -r -d '' dir; do
      case "$dir" in
        ''|*$'\t'*|*$'\r'*|*$'\n'*)
          FM_NEXT_CACHE_INSPECTION_ERROR="unsafe build-output path in worktree: $wt"
          rc=1
          break
          ;;
      esac
      if fm_next_cache_is_build_output "$root" "$dir"; then
        candidate_status=0
      else
        candidate_status=$?
      fi
      case "$candidate_status" in
        0)
          if ! kb=$(fm_next_cache_size_kb "$dir"); then
            FM_NEXT_CACHE_INSPECTION_ERROR="cannot measure build output at: $dir"
            rc=1
            break
          fi
          record="$kb"$'\t'"$dir"
          if [ -n "$FM_NEXT_CACHE_PLAN" ]; then
            FM_NEXT_CACHE_PLAN="$FM_NEXT_CACHE_PLAN"$'\n'"$record"
          else
            FM_NEXT_CACHE_PLAN=$record
          fi
          FM_NEXT_CACHE_TOTAL_KB=$(( FM_NEXT_CACHE_TOTAL_KB + kb ))
          ;;
        1) ;;
        *)
          FM_NEXT_CACHE_INSPECTION_ERROR="cannot establish build-output eligibility at: $dir"
          rc=1
          break
          ;;
      esac
    done < "$tmp"
  fi
  if ! rm -f -- "$tmp"; then
    FM_NEXT_CACHE_INSPECTION_ERROR="cannot clear build-output discovery state for: $wt"
    rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    FM_NEXT_CACHE_PLAN=
    FM_NEXT_CACHE_TOTAL_KB=0
    return 1
  fi
  return 0
}

# Print each reportable Next.js build-output directory in <worktree>, one
# absolute path per line. An incomplete inspection returns non-zero.
fm_next_cache_dirs() {  # <worktree>
  local wt=$1 dir
  fm_next_cache_inspect "$wt" || return 1
  while IFS=$'\t' read -r _ dir; do
    [ -n "$dir" ] && printf '%s\n' "$dir"
  done <<EOT
$FM_NEXT_CACHE_PLAN
EOT
}

# Total kilobytes <worktree> holds, without printing or removing anything.
# Sets FM_NEXT_CACHE_TOTAL_KB and prints it.
fm_next_cache_total_kb() {  # <worktree>
  local wt=$1
  fm_next_cache_inspect "$wt" || return 1
  printf '%s\n' "$FM_NEXT_CACHE_TOTAL_KB"
}

# Report what <worktree> holds without removing anything. One line per
# directory; nothing when there is none. Sets FM_NEXT_CACHE_TOTAL_KB.
fm_next_cache_report() {  # <worktree> <label>
  local wt=$1 label=$2 dir kb human
  if ! fm_next_cache_inspect "$wt"; then
    printf '%s: could not inspect Next.js build output (%s)\n' \
      "$label" "$FM_NEXT_CACHE_INSPECTION_ERROR" >&2
    return 1
  fi
  while IFS=$'\t' read -r kb dir; do
    if [ -n "$dir" ]; then
      human=$(fm_next_cache_human_kb "$kb") || return 1
      printf '%s: would reclaim %s from %s\n' "$label" "$human" "$dir"
    fi
  done <<EOT
$FM_NEXT_CACHE_PLAN
EOT
}
