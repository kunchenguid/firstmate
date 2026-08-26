#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a merge. The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
#
# The PRIMARY merge detector is git, for every provider: has the task
# worktree's HEAD already landed in the recorded destination branch, or the
# repository's default branch when no destination was recorded (bin/fm-pr-lib.sh
# and bin/fm-pr-check.sh's headers own where that destination comes from;
# bin/fm-teardown.sh's header owns the equivalent teardown-time test)? Each
# forge's own API - gh for GitHub, glab for GitLab - runs only as a FALLBACK
# when the git test could not run at all (no worktree, no resolvable
# destination or default branch, or a git failure), never as a second vote
# once the git test has already answered. Bitbucket gets no forge case at all
# below: the git test is its only path to a merged verdict, so watching a
# Bitbucket pull request needs no Bitbucket credential or CLI.
#
# The git test stays cheap enough for FM_CHECK_TIMEOUT (enforced by the
# caller, which runs this whole script under a timeout, per
# bin/fm-watch.sh's run_check/run_check_capture) by probing the destination's
# advertised tip with `ls-remote` - which transfers no objects, so its cost
# does not grow with repository size - before ever fetching. The single-branch
# fetch, and the merge-base/merge-tree tests that need it, run only when that
# tip has moved since the last cached value. The cache is written only AFTER
# an evaluation completes, never before the fetch, so a transient fetch
# failure retries next cycle instead of being remembered as "already checked".
#
# This script deliberately sources nothing, including bin/fm-pr-lib.sh: its
# behavior is fully captured by its own hash-registered bytes (bin/fm-pr-lib.sh's
# header owns the registration/migration contract), so the GitHub and GitLab
# validation below intentionally re-derives what bin/fm-pr-lib.sh's
# fm_pr_url_parse already checked, and the git-landed helpers below are not
# shared with bin/fm-teardown.sh's own copies for the same reason.
set -u
LC_ALL=C
export LC_ALL

if [ "$#" -eq 9 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
  worktree=$7
  dest=$8
  tip_cache=$9
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) base=${0%.check.sh} ;;
    *) exit 0 ;;
  esac
  data="$base.pr-poll"
  meta="$base.meta"
  tip_cache="$base.pr-poll-git-tip"

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-

  worktree=
  dest=
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    worktree=$(grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    dest=$(grep '^pr_dest=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  fi
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# <worktree> must be a real, still-present git working tree; an absent or
# already-torn-down one makes the git test unusable rather than merged.
git_worktree_valid() {
  local wt=${1-}
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  [ -d "$wt/.git" ] || [ -f "$wt/.git" ]
}

# The repository's default branch, resolved the same way
# bin/fm-teardown.sh's default_branch does: the remote's advertised HEAD
# symref, falling back to a local main or master.
git_default_branch() {
  local wt=$1 ref branch
  ref=$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$wt" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# Has <wt>'s HEAD landed in the already-fetched remote-tracking <ref>? True
# when HEAD is an ancestor (a merge commit or a fast-forward), else when the
# change is squash-safe present: 3-way merging <ref> with HEAD introduces
# nothing <ref> does not already contain. Returns non-zero, never printing
# anything, whenever the answer is inconclusive (no HEAD, no <ref> tree, or a
# merge conflict) as well as when it is genuinely not landed - the caller does
# not distinguish the two, and both fall back to the forge check.
git_ref_contains_head() {
  local wt=$1 ref=$2 current dest_tree merged_tree
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  git -C "$wt" merge-base --is-ancestor "$current" "$ref" 2>/dev/null && return 0
  dest_tree=$(git -C "$wt" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$dest_tree" ] || return 1
  merged_tree=$(git -C "$wt" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$dest_tree" ]
}

# The destination's current tip, read with no object transfer so this is cheap
# every cycle regardless of repository size. Empty on any failure (no origin,
# no such branch, network error).
git_dest_tip() {
  local wt=$1 dest=$2
  git -C "$wt" ls-remote --exit-code origin "refs/heads/$dest" 2>/dev/null \
    | awk '{ print $1; exit }'
}

# <cache>'s single stored line, or empty if it is absent, a symlink, or
# unreadable - never a hard failure, since a missing cache just means
# "evaluate this cycle" rather than anything unsafe.
git_tip_cache_read() {
  local cache=${1-} value=
  [ -n "$cache" ] && [ -f "$cache" ] && [ ! -L "$cache" ] || return 0
  IFS= read -r value < "$cache" 2>/dev/null
  printf '%s\n' "$value"
}

# Persist <tip> to <cache>. Called only after an evaluation actually ran
# (never before the fetch it gates next cycle), and best-effort: a write
# failure here means only that the next cycle re-evaluates, never that a
# result is lost or invented.
git_tip_cache_write() {
  local cache=${1-} tip=$2 tmp
  [ -n "$cache" ] && [ ! -L "$cache" ] || return 0
  tmp="$cache.tmp.$$"
  if ! ( umask 077 && printf '%s\n' "$tip" > "$tmp" ) 2>/dev/null; then
    rm -f -- "$tmp" 2>/dev/null
    return 0
  fi
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 0; }
  mv -f -- "$tmp" "$cache" 2>/dev/null || rm -f -- "$tmp" 2>/dev/null
  return 0
}

# The primary, provider-agnostic merge detector. <dest> is a branch NAME, not
# a full ref; empty means "use the repository's default branch". Returns
# non-zero - printing nothing - when the test cannot run at all or ran and
# found HEAD not yet landed, so the caller always has a forge fallback to try.
git_merge_check() {
  local wt=$1 dest=$2 cache=$3 cached tip landed=1
  git_worktree_valid "$wt" || return 1
  if [ -z "$dest" ]; then
    dest=$(git_default_branch "$wt") || return 1
  fi
  git check-ref-format --branch "$dest" >/dev/null 2>&1 || return 1
  git -C "$wt" remote get-url origin >/dev/null 2>&1 || return 1
  cached=$(git_tip_cache_read "$cache")
  tip=$(git_dest_tip "$wt" "$dest")
  [ -n "$tip" ] || return 1
  if [ -n "$cached" ] && [ "$tip" = "$cached" ]; then
    return 1
  fi
  git -C "$wt" fetch --quiet origin "+refs/heads/$dest:refs/remotes/origin/$dest" >/dev/null 2>&1 || return 1
  git_ref_contains_head "$wt" "refs/remotes/origin/$dest" && landed=0
  git_tip_cache_write "$cache" "$tip"
  return "$landed"
}

if git_merge_check "$worktree" "$dest" "$tip_cache"; then
  printf '%s\n' merged
  exit 0
fi

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
    [ "$state" = MERGED ] && printf '%s\n' merged
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
