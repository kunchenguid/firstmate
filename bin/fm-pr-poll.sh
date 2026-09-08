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

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 1 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 1
  { exec 3< "$data"; } 2>/dev/null || exit 1
  IFS= read -r provider <&3 || exit 1
  IFS= read -r url <&3 || exit 1
  IFS= read -r host <&3 || exit 1
  IFS= read -r path <&3 || exit 1
  IFS= read -r number <&3 || exit 1
  if IFS= read -r _extra <&3; then
    exit 1
  fi
  exec 3<&-
else
  exit 1
fi

case "$number" in
  [1-9]*) ;;
  *) exit 1 ;;
esac
case "$number" in
  *[!0-9]*) exit 1 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 1
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 1
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 1 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 1
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 1 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 1
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 1
    case "$state" in
      MERGED) printf '%s\n' merged ;;
      OPEN|CLOSED) ;;
      *) exit 1 ;;
    esac
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 1
    [ "$host" != github.com ] || exit 1
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 1 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 1
    case "$path" in
      /*|*/|*//*) exit 1 ;;
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
      [ "$segments" -le 20 ] || exit 1
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 1
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 1 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 1
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 1
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 1
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 1
    case "$state" in
      merged) printf '%s\n' merged ;;
      opened|closed|locked) ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
exit 0
