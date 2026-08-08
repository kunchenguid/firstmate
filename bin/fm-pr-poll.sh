#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits an exact transition token and stays silent on every lookup or parse
# error.  GitHub validated calls can additionally carry the recorded head OID;
# that enables closed-unmerged, force-push, and changes-requested transitions.
# GitLab remains merge-only because its current CLI path supplies no exact head.
# Task data is never interpolated into these byte-static source bytes.
set -u
LC_ALL=C
export LC_ALL

expected_head=
if [ "$#" -eq 8 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
  expected_head=$7
  expected_review=$8
elif [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
  expected_review=
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
  expected_review=
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
case "$expected_head" in
  '') ;;
  *[!0-9a-f]*) exit 0 ;;
  *) [ "${#expected_head}" -eq 40 ] || [ "${#expected_head}" -eq 64 ] || exit 0 ;;
esac
[ -z "$expected_review" ] || [ "$expected_review" = CHANGES_REQUESTED ] || exit 0

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
    raw=$(gh pr view "$url" --json state,headRefOid,reviewDecision \
      -q '.state + "\t" + .headRefOid + "\t" + (.reviewDecision // "")' 2>/dev/null) || exit 0
    state=${raw%%$'\t'*}
    rest=${raw#*$'\t'}
    [ "$rest" != "$raw" ] || exit 0
    head=${rest%%$'\t'*}
    review=${rest#*$'\t'}
    [ "$review" != "$rest" ] || review=
    case "$head" in
      *[!0-9a-f]*) exit 0 ;;
      *) [ "${#head}" -eq 40 ] || [ "${#head}" -eq 64 ] || exit 0 ;;
    esac
    case "$state" in
      MERGED) printf '%s\n' merged ;;
      CLOSED) [ -z "$expected_head" ] || printf '%s\n' closed-unmerged ;;
      OPEN)
        if [ -n "$expected_head" ] && [ "$head" != "$expected_head" ]; then
          printf 'head-changed:%s\n' "$head"
        elif [ -n "$expected_head" ] && [ "$review" = CHANGES_REQUESTED ] && [ "$expected_review" != CHANGES_REQUESTED ]; then
          printf 'changes-requested:%s\n' "$head"
        fi
        ;;
    esac
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
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
