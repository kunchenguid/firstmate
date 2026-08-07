#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line only when a merged PR or MR still has its
# registered immutable head, emits one revision-mismatch diagnostic when the
# head moved, and stays silent on every lookup or parse error so failure can
# never be read as a merge. The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub and glab
# for GitLab, so an upstream checkout needs no extra tooling to follow either.
set -u
LC_ALL=C
export LC_ALL

if [ "$#" -eq 7 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
  expected_head=$7
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh)
      data=${0%.check.sh}.pr-poll
      meta=${0%.check.sh}.meta
      ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  [ -f "$meta" ] && [ ! -L "$meta" ] || exit 0
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
  [ "$(grep -c '^pr_head=' "$meta" 2>/dev/null || true)" -eq 1 ] || exit 0
  [ "$(grep -c '^ready_head=' "$meta" 2>/dev/null || true)" -eq 1 ] || exit 0
  expected_head=$(grep '^pr_head=' "$meta" | cut -d= -f2-)
  ready_head=$(grep '^ready_head=' "$meta" | cut -d= -f2-)
  [ "$expected_head" = "$ready_head" ] || exit 0
else
  exit 0
fi

case "$expected_head" in
  *[!0-9a-f]*|'') exit 0 ;;
esac
[ "${#expected_head}" -eq 40 ] || [ "${#expected_head}" -eq 64 ] || exit 0

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
    current_head=$(gh pr view "$url" --json headRefOid -q .headRefOid 2>/dev/null) || exit 0
    case "$current_head" in *[!0-9a-f]*|'') exit 0 ;; esac
    if [ "$current_head" != "$expected_head" ]; then
      printf 'revision-mismatch expected=%s current=%s\n' "$expected_head" "$current_head"
      exit 0
    fi
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
    command -v node >/dev/null 2>&1 || exit 0
    encoded=$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$path" 2>/dev/null) || exit 0
    api=$(glab api "projects/$encoded/merge_requests/$number" --hostname "$host" 2>/dev/null) || exit 0
    current_head=$(printf '%s' "$api" | node -e '
const fs = require("fs");
let data;
try { data = JSON.parse(fs.readFileSync(0, "utf8")); } catch (_) { process.exit(1); }
if (!data || typeof data.sha !== "string") process.exit(1);
process.stdout.write(data.sha);
' 2>/dev/null) || exit 0
    case "$current_head" in *[!0-9a-f]*|'') exit 0 ;; esac
    if [ "$current_head" != "$expected_head" ]; then
      printf 'revision-mismatch expected=%s current=%s\n' "$expected_head" "$current_head"
      exit 0
    fi
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
