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
# forge's own API - gh for GitHub, glab for GitLab - is consulted as a safety
# net whenever the git test has not itself confirmed a merge: both when it
# could not run at all (no worktree, no resolvable destination or default
# branch, or a git failure) and when it ran to a conclusion and found HEAD not
# yet landed. Forge can only ever ADD a merged detection the git test missed;
# it never overrides or contradicts a merge the git test already confirmed.
# Bitbucket gets no forge case at all below: the git test is its only path to
# a merged verdict, so watching a Bitbucket pull request needs no Bitbucket
# credential or CLI.
#
# The git test stays cheap enough for FM_CHECK_TIMEOUT (enforced by the
# caller, which runs this whole script under a timeout, per
# bin/fm-watch.sh's run_check/run_check_capture) by probing the destination's
# advertised tip with `ls-remote` - which transfers no objects, so its cost
# does not grow with repository size - before ever fetching. The single-branch
# fetch, and the merge-base/merge-tree tests that need it, run only when the
# (tip, HEAD) pair has changed since the last cached value - HEAD is part of
# the cache key, not just the tip, because a not-landed verdict is only true
# for the HEAD it was computed against: a worktree that drops or rewrites its
# unpushed commits between cycles can turn a real "not landed" into a real
# "landed" with the destination tip never moving at all, and a tip-only key
# would then replay the stale negative forever. The cache is written only
# AFTER a conclusive NOT-landed evaluation completes, never before the fetch,
# never on a landed evaluation, and never on an inconclusive one (no HEAD, no
# destination tree, or a merge-tree conflict - git_ref_contains_head's own
# tri-state return tells the caller apart from a genuine negative): a landed
# verdict must reach bin/fm-watch.sh's durable wake queue before anything
# records that this tip was ever seen, and this script has no way to confirm
# that from inside one invocation. Caching the tip on a landed verdict would
# let a crash between this script's exit and the wake actually landing
# durably suppress that same merge forever, because the unchanged destination
# tip would then read as "already evaluated" on every later cycle. Leaving
# the tip uncached instead means only a bounded repeat of this cheap test next
# cycle - a duplicate detection, never a lost one - until bin/fm-watch.sh's
# retirement removes this poll altogether.
#
# The same git test also refuses to trust a same-named destination branch in
# just any repository called "origin": <wt>'s origin remote must resolve to
# the exact host and path the pull request was validated against, or the test
# is unusable rather than a false "landed" from an unrelated or forked
# repository that happens to carry equivalent content. That binding compares
# the EFFECTIVE URL git will actually fetch from (`git remote get-url origin`,
# which resolves any local `insteadOf` rewrite and picks the first value of a
# multi-valued `remote.origin.url`) against the CONFIGURED URL
# (`git config --get remote.origin.url`, which does neither): the two must be
# byte-identical before the host/path comparison even runs, because either
# rewrite mechanism can make the configured value name the real destination
# while a fetch actually goes somewhere else entirely - a label the operator
# or a task's own build tooling can silently repoint without ever touching
# what appears to be a matching identity.
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
# nothing <ref> does not already contain. Returns one of three distinct
# outcomes, never printing anything: 0 = landed, 1 = conclusively NOT landed
# (a real negative the caller may cache), 2 = inconclusive (no HEAD, no <ref>
# tree, or a merge conflict) - the caller must never cache an inconclusive
# result as though it were a real negative, since the same worktree can turn
# genuinely landed on a later cycle with the destination tip never moving.
git_ref_contains_head() {
  local wt=$1 ref=$2 current dest_tree merged_tree rc
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 2
  git -C "$wt" merge-base --is-ancestor "$current" "$ref" 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 1 ] || return 2
  dest_tree=$(git -C "$wt" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 2
  [ -n "$dest_tree" ] || return 2
  merged_tree=$(git -C "$wt" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 2
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ -n "$merged_tree" ] || return 2
  [ "$merged_tree" = "$dest_tree" ] && return 0
  return 1
}

# Does <wt>'s "origin" remote address the exact same forge repository as the
# validated PR identity (<host>, <path>)? A same-named destination branch
# existing in an unrelated project, or in a fork, must never look "landed"
# just because a remote called "origin" exists there too - this ties the git
# test to the pull request's actual destination repository instead of trusting
# the remote name alone. First requires the EFFECTIVE URL (`git remote
# get-url origin`, which resolves any local `insteadOf` rewrite and picks the
# first value of a multi-valued `remote.origin.url`) to be byte-identical to
# the CONFIGURED URL (`git config --get remote.origin.url`, which does
# neither): a mismatch means the string this function is about to parse does
# not name the repository git will actually fetch from, so the identity below
# would be bound to the wrong thing. Only once the two agree does the
# configured URL's shape get parsed: https(s)://[user[:token]@]host[:port]/
# path(.git)?/?, ssh://[user@]host[:port]/path(.git)?/? (also spelled
# git+ssh:// or ssh+git://), and the [user@]host:path(.git)?/? scp-like form
# (recognized, like git itself, only when the colon precedes any slash - a
# plain local path is never mistaken for it). Any other shape, or no origin
# remote at all, is unusable rather than a match.
git_origin_matches_repo() {
  local wt=$1 host=$2 path=$3 url effective rest host_part path_part before_colon
  url=$(git -C "$wt" config --get remote.origin.url 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  effective=$(git -C "$wt" remote get-url origin 2>/dev/null) || return 1
  [ "$url" = "$effective" ] || return 1
  case "$url" in
    *://*)
      case "$url" in
        https://*|http://*|ssh://*|git+ssh://*|ssh+git://*) ;;
        *) return 1 ;;
      esac
      rest=${url#*://}
      rest=${rest#*@}
      host_part=${rest%%/*}
      path_part=${rest#*/}
      ;;
    *:*)
      before_colon=${url%%:*}
      case "$before_colon" in
        */*) return 1 ;;
      esac
      rest=${url#*@}
      host_part=${rest%%:*}
      path_part=${rest#*:}
      ;;
    *)
      return 1
      ;;
  esac
  host_part=${host_part%%:*}
  path_part=${path_part%/}
  path_part=${path_part%.git}
  path_part=${path_part%/}
  [ -n "$host_part" ] && [ -n "$path_part" ] || return 1
  host_part=$(printf '%s' "$host_part" | tr '[:upper:]' '[:lower:]')
  [ "$host_part" = "$host" ] && [ "$path_part" = "$path" ]
}

# The destination's current tip, read with no object transfer so this is cheap
# every cycle regardless of repository size. Empty on any failure (no origin,
# no such branch, network error).
git_dest_tip() {
  local wt=$1 dest=$2
  git -C "$wt" ls-remote --exit-code origin "refs/heads/$dest" 2>/dev/null \
    | awk '{ print $1; exit }'
}

# <cache>'s single stored "<tip> <head>" line, or empty if it is absent, a
# symlink, or unreadable - never a hard failure, since a missing cache just
# means "evaluate this cycle" rather than anything unsafe.
git_tip_cache_read() {
  local cache=${1-} value=
  [ -n "$cache" ] && [ -f "$cache" ] && [ ! -L "$cache" ] || return 0
  IFS= read -r value < "$cache" 2>/dev/null
  printf '%s\n' "$value"
}

# Persist "<tip> <head>" to <cache>. Called only after a conclusive not-landed
# evaluation actually ran (never before the fetch it gates next cycle, and
# never on an inconclusive result), and best-effort: a write failure here
# means only that the next cycle re-evaluates, never that a result is lost or
# invented.
git_tip_cache_write() {
  local cache=${1-} value=$2 tmp
  [ -n "$cache" ] && [ ! -L "$cache" ] || return 0
  tmp="$cache.tmp.$$"
  if ! ( umask 077 && printf '%s\n' "$value" > "$tmp" ) 2>/dev/null; then
    rm -f -- "$tmp" 2>/dev/null
    return 0
  fi
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 0; }
  mv -f -- "$tmp" "$cache" 2>/dev/null || rm -f -- "$tmp" 2>/dev/null
  return 0
}

# The primary, provider-agnostic merge detector. <dest> is a branch NAME, not
# a full ref; empty means "use the repository's default branch". <host> and
# <path> are the validated PR identity, bound to <wt>'s origin below so a
# same-named destination in an unrelated repository can never read as landed.
# Returns one of three distinct outcomes so the caller can tell "confirmed not
# yet landed" apart from "could not run at all": 0 = landed, 1 = not-landed
# (the test ran to a conclusion - either a real negative or a cache-skip
# reusing a prior real negative for the exact same (tip, HEAD) pair - and HEAD
# is not yet contained), 2 = unusable (no worktree, no resolvable destination,
# origin does not address the PR's own repository, an unreadable destination
# tip, a failed fetch, or an inconclusive git_ref_contains_head result). The
# caller falls through to its forge fallback on both 1 and 2, since forge may
# only ever add a detection the git test missed and never override one it
# already confirmed. A landed (0) verdict deliberately never writes the tip
# cache - see the header comment on why that ordering is load-bearing. Nor
# does an inconclusive (2) evaluation: only a genuine negative is cached, so a
# merge-tree conflict or a momentarily missing HEAD next cycle is retried
# rather than frozen into a false "not landed" forever.
git_merge_check() {
  local wt=$1 dest=$2 cache=$3 host=$4 path=$5 cached tip head rc
  git_worktree_valid "$wt" || return 2
  if [ -z "$dest" ]; then
    dest=$(git_default_branch "$wt") || return 2
  fi
  git check-ref-format --branch "$dest" >/dev/null 2>&1 || return 2
  git_origin_matches_repo "$wt" "$host" "$path" || return 2
  head=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 2
  cached=$(git_tip_cache_read "$cache")
  tip=$(git_dest_tip "$wt" "$dest")
  [ -n "$tip" ] || return 2
  if [ -n "$cached" ] && [ "$cached" = "$tip $head" ]; then
    return 1
  fi
  git -C "$wt" fetch --quiet origin "+refs/heads/$dest:refs/remotes/origin/$dest" >/dev/null 2>&1 || return 2
  git_ref_contains_head "$wt" "refs/remotes/origin/$dest"
  rc=$?
  case $rc in
    0) return 0 ;;
    1) git_tip_cache_write "$cache" "$tip $head"; return 1 ;;
    *) return 2 ;;
  esac
}

git_merge_check "$worktree" "$dest" "$tip_cache" "$host" "$path"
git_status=$?
case $git_status in
  0)
    printf '%s\n' merged
    exit 0
    ;;
  1|2) ;;
esac

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
