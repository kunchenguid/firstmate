#!/usr/bin/env bash
set -u
LC_ALL=C
export LC_ALL
[ "$#" -eq 5 ] || exit 1
provider=$1 url=$2 host=$3 path=$4 number=$5
case "$provider" in
  github)
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 1
    case "$state" in OPEN|CLOSED) ;; *) exit 1 ;; esac
    ;;
  gitlab)
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 1
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1)
    case "$state" in opened|closed|locked) ;; *) exit 1 ;; esac
    ;;
  *) exit 1 ;;
esac
printf '%s\n' healthy
