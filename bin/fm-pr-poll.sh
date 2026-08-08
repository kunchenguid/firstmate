#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a merge. The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub and glab
# for GitLab, so an upstream checkout needs no extra tooling to follow either.
set -u
LC_ALL=C
export LC_ALL

# The check.sh copy derives the task id and state dir from $0; the --validated
# run (the watcher's production path) finds the task by matching its private
# sidecar. SCRIPT_DIR is bin/ for the --validated run and the state dir for the
# copied check.sh; the journal helper falls back to FM_ROOT_OVERRIDE for the
# latter, and silently skips when the attempt library cannot be located.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Provisionally journal a merged forge observation into the task's attempt
# record when the task is discoverable and its meta carries attempt=. The
# journal is append-only and never a receipt; the final landing receipt is
# written only by the disposition step. Every failure here is silent on stdout
# (and only best-effort on stderr) so the poll's one-line merged contract and
# exit status are never affected.
fm_pr_poll_journal_merged() {  # <provider> <url> <path>
  local provider=$1 url=$2 path=$3
  local state_dir id meta attempt gen lib evidence
  case "$0" in
    *.check.sh)
      id=$(basename "${0%.check.sh}")
      state_dir=$(dirname "$0")
      ;;
    *)
      state_dir="${FM_STATE_OVERRIDE:-${FM_HOME:-}/state}"
      [ -n "$state_dir" ] || return 0
      id=$(fm_pr_poll_find_task "$state_dir" "$provider" "$url") || return 0
      [ -n "$id" ] || return 0
      ;;
  esac
  meta="$state_dir/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  attempt=$(sed -n 's/^attempt=//p' "$meta" 2>/dev/null | head -1)
  [ -n "$attempt" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  if [ -z "${FM_ATTEMPT_LIB_SOURCED:-}" ]; then
    if [ -f "$SCRIPT_DIR/fm-attempt-lib.sh" ]; then
      lib="$SCRIPT_DIR/fm-attempt-lib.sh"
    elif [ -n "${FM_ROOT_OVERRIDE:-}" ] && [ -f "$FM_ROOT_OVERRIDE/bin/fm-attempt-lib.sh" ]; then
      lib="$FM_ROOT_OVERRIDE/bin/fm-attempt-lib.sh"
    else
      return 0
    fi
    # shellcheck source=bin/fm-attempt-lib.sh
    . "$lib" 2>/dev/null || return 0
  fi
  gen=$(fm_attempt_generation "$attempt" 2>/dev/null) || return 0
  evidence=$(jq -nc \
    --arg provider "$provider" --arg repo "$path" --arg source "$id" --arg pr "$url" \
    '{provider:$provider,repo:$repo,source:$source,target:null,head:null,state:"merged",before_sha:null,after_sha:null,pr:$pr}') || return 0
  if ! fm_attempt_observe "$attempt" "$gen" forge "$evidence" 2>/dev/null; then
    echo "fm-pr-poll: failed to journal merged forge observation for attempt $attempt" >&2
  fi
  return 0
}

# Find the single task whose private sidecar matches the validated identity, so
# a --validated poll can attribute its observation without guessing. Zero or
# multiple matches are refused: an unattributable observation is never journaled.
fm_pr_poll_find_task() {  # <state> <provider> <url> -> prints the single matching task id
  local state=$1 provider=$2 url=$3
  local file id matches=0 found p u
  [ -d "$state" ] || return 1
  for file in "$state"/*.pr-poll; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    { IFS= read -r p && IFS= read -r u; } < "$file" || continue
    [ "$p" = "$provider" ] && [ "$u" = "$url" ] || continue
    id=$(basename "$file" .pr-poll)
    case "$id" in
      ''|*[!A-Za-z0-9._-]*) continue ;;
    esac
    matches=$((matches + 1))
    found=$id
  done
  [ "$matches" -eq 1 ] || return 1
  printf '%s\n' "$found"
}

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

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
    if [ "$state" = MERGED ]; then
      printf '%s\n' merged
      fm_pr_poll_journal_merged github "$url" "$path"
    fi
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
    if [ "$state" = merged ]; then
      printf '%s\n' merged
      fm_pr_poll_journal_merged gitlab "$url" "$path"
    fi
    ;;
  *) exit 0 ;;
esac
exit 0
