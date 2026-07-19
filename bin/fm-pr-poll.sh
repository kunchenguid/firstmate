#!/usr/bin/env bash
# Static watcher program for a validated PR poll sidecar.
# It emits exactly one merged line for MERGED and stays silent otherwise.
set -u
LC_ALL=C
export LC_ALL

if [ "$#" -eq 5 ] && [ "$1" = --validated ]; then
  url=$2
  owner=$3
  repo=$4
  number=$5
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r owner <&3 || exit 0
  IFS= read -r repo <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

[ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
case "$owner" in
  *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
esac
[ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
case "$repo" in
  .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac
[ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0

state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
[ "$state" = MERGED ] && printf '%s\n' merged
exit 0
