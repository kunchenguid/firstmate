#!/usr/bin/env bash
# Shared discovery and removal of Next.js build output inside a task worktree.
#
# Why this exists: a pooled worktree returns to the pool carrying its Next.js
# build output, and nothing ever removes it. Measured 2026-08-18: one idle
# Artemis copy held a 15 GB packages/frontend/.next on a volume with 11 GB free;
# removing that one directory took free space to 27 GB. An earlier sweep on
# 2026-08-07 found ~25.6 GB of it spread across eight copies. The output
# regenerates from source on the next build, so it is the largest reclaim in the
# pool that costs nothing to give up.
#
# Sourced by bin/fm-teardown.sh (which reclaims a copy before returning it) and
# bin/fm-next-cache-sweep.sh (which reclaims copies already sitting idle in the
# pool). Both get the same discovery rule from here, so "what counts as
# reclaimable" is stated once.
#
# WHAT IS RECLAIMED. Exactly directories named .next that pass BOTH proofs:
#   1. git ignores the directory in the repo that contains it
#      (`git check-ignore`). Tracked content can never match, so no source, no
#      git data, and no committed fixture is reachable by this rule.
#   2. its parent is a Next.js app root: a next.config.{js,cjs,mjs,ts,cts,mts}
#      sits beside it, or the parent's package.json names `next`. This is what
#      makes the claim "regenerable build output" true rather than assumed - a
#      gitignored directory that merely happens to be called .next is left alone.
# Nothing else is ever removed. node_modules, source, and git data are out of
# scope by construction, not by exclusion list: the walk prunes node_modules and
# .git outright, and neither could pass proof 2 anyway.
#
# OTHER CACHES WERE MEASURED AND DELIBERATELY LEFT OUT. Surveying the whole pool
# on 2026-08-18 turned up one other large gitignored directory: a project's .tmp
# scratch root, ~8.7 GB across the copies, holding audit output, coverage JSON,
# browser recordings, and review artifacts. That is agent work product, not build
# output - nothing regenerates it - so it is not this rule's business, and the
# same goes for a `dist` (~102 MB pooled, and tracked in some projects). Every
# other candidate measured zero: .turbo, .cache, .parcel-cache, .vite, .output.
# Widening this rule by pattern would trade a large, provably safe reclaim for a
# small, unprovable one; add a directory only by naming it and its measured size.
#
# Next.js documents .next as the build output directory (`distDir` defaults to
# '.next') and clears it itself on every production build (`cleanDistDir`
# defaults to true, preserving only .next/cache). Removing it is therefore the
# same operation the framework already performs on itself, one build earlier.
# A project that sets a custom `distDir` is deliberately NOT discovered: reading
# a build config to decide what to delete would make the deletion set depend on
# untrusted project code. Such a project keeps its cache until someone names the
# directory, which is the safe direction to be wrong in.
#
# The walk prunes node_modules and .git, and stops descending at each .next it
# finds, so a nested .next under .next/standalone is reclaimed with its parent
# rather than counted twice. Measured cost on the largest live Artemis copy
# (5.1 GB of loose scratch, full node_modules): 214 ms.
#
# This library never decides WHETHER a worktree may be touched. Teardown proves
# that through its own landed-work checks; the sweep proves it through pool
# lease state, task records, and a clean tree. Sourcing this file grants no
# authority to remove anything.

# Bytes-to-human, matching the units du -h prints, so a reclaim line reads the
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
  local parent=$1 ext grep_status
  for ext in js cjs mjs ts cts mts; do
    [ -f "$parent/next.config.$ext" ] && return 0
  done
  [ -f "$parent/package.json" ] || return 1
  if grep -Eq '"next"[[:space:]]*:' "$parent/package.json" 2>/dev/null; then
    return 0
  else
    grep_status=$?
  fi
  [ "$grep_status" -eq 1 ] && return 1
  return 2
}

# Does <dir> pass both proofs, as a real directory inside repo <root>?
fm_next_cache_is_build_output() {  # <repo-root> <dir>
  local root=$1 dir=$2 real parent ignore_status app_status
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then return 2; fi
  [ -d "$dir" ] || return 1
  # A symlink is never removed: the target may live outside the worktree
  # entirely, and rm -rf on it would follow the operator's intent nowhere good.
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

# Print each reclaimable Next.js build-output directory in <worktree>, one
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

# Remove every reclaimable directory in <worktree>, printing one line each with
# the space it gave back. Silent when there is nothing to reclaim, so a caller
# that runs this on every teardown stays quiet on projects that never build.
# Sets FM_NEXT_CACHE_TOTAL_KB to the reclaimed total.
# Returns non-zero if any removal failed, having reported which - a failed
# reclaim is worth seeing, but it is never a reason to fail the caller's own
# work, so callers report it rather than abort on it.
fm_next_cache_reclaim() {  # <worktree> <label>
  local wt=$1 label=$2 dir kb human rc=0 plan
  if ! fm_next_cache_inspect "$wt"; then
    printf '%s: could not inspect Next.js build output (%s)\n' \
      "$label" "$FM_NEXT_CACHE_INSPECTION_ERROR" >&2
    return 1
  fi
  plan=$FM_NEXT_CACHE_PLAN
  FM_NEXT_CACHE_TOTAL_KB=0
  while IFS=$'\t' read -r kb dir; do
    if [ -n "$dir" ]; then
      human=$(fm_next_cache_human_kb "$kb") || return 1
      if rm -rf -- "$dir" 2>/dev/null && [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
        FM_NEXT_CACHE_TOTAL_KB=$(( FM_NEXT_CACHE_TOTAL_KB + kb ))
        printf '%s: reclaimed %s of Next.js build output from %s\n' \
          "$label" "$human" "$dir"
      else
        printf '%s: could not remove Next.js build output at %s\n' "$label" "$dir" >&2
        rc=1
      fi
    fi
  done <<EOT
$plan
EOT
  return "$rc"
}
