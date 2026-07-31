#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR, exactly one
# "dirty <head>" line for an open GitHub pull request the forge reports as
# conflicting, and stays silent otherwise, including on every error, so a
# failed lookup can never be read as either result. The provider-tagged
# identity is data in the sidecar and is never interpolated into this source:
# these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub and glab
# for GitLab, so an upstream checkout needs no extra tooling to follow either.
set -u
LC_ALL=C
export LC_ALL

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
    # One request carries all three fields, so conflict detection adds no call
    # to the merge poll. The stable GraphQL "mergeable" field is read rather
    # than mergeStateStatus: the two agree on a conflict, but mergeStateStatus
    # rides a preview header and is likelier to be absent on GitHub Enterprise
    # Server, and its non-conflict values also report failing or pending checks,
    # which are a different signal this poll must stay silent about.
    # A base push makes GitHub recompute mergeability on its own, so by the time
    # this poll runs the answer is normally settled; the transient UNKNOWN it can
    # return meanwhile is silence here and resolves on the next poll rather than
    # costing this static program a retry and a timing dependency.
    raw=$(gh pr view "$url" --json state,mergeable,headRefOid \
      -q '[.state,.mergeable,.headRefOid]|@tsv' 2>/dev/null) || exit 0
    tab=$(printf '\t')
    # Exactly three tab-separated fields, revalidated below against exact
    # allowlists rather than trusted, so unexpected output stays silent.
    case "$raw" in
      *"$tab"*"$tab"*) ;;
      *) exit 0 ;;
    esac
    state=${raw%%"$tab"*}
    rest=${raw#*"$tab"}
    mergeable=${rest%%"$tab"*}
    head=${rest#*"$tab"}
    case "$head" in
      *"$tab"*) exit 0 ;;
    esac
    # Merged is decided first and alone, so a merged or closed pull request
    # keeps the exact result it had before conflict reporting existed.
    if [ "$state" = MERGED ]; then
      printf '%s\n' merged
      exit 0
    fi
    [ "$state" = OPEN ] || exit 0
    [ "$mergeable" = CONFLICTING ] || exit 0
    # The head commit identifies the conflict episode for the watcher's dedupe.
    # An unreadable head is reported as such instead of suppressing the wake.
    case "$head" in
      ''|*[!0-9a-f]*) head=unknown ;;
      *) [ "${#head}" -ge 7 ] && [ "${#head}" -le 64 ] || head=unknown ;;
    esac
    printf 'dirty %s\n' "$head"
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
