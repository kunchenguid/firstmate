#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a merge. The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# GitHub and GitLab are each read through their own standard CLI, gh and glab,
# so an upstream checkout needs no extra tooling to follow either. Gitea has no
# CLI in that set, so it is read from its own REST API with curl and jq, using
# the credential the operator already holds for that instance in git's own
# credential helper chain; no firstmate-specific token or credential store is
# introduced. bin/fm-pr-check.sh requires all three tools and a resolvable
# credential before it arms a Gitea watch, because an unreadable merge state is
# silent here and silence must never be read as "not merged".
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
  gitea)
    # Gitea commonly serves a non-default port, so the stored authority is
    # host[:port] and both halves are revalidated before either is used.
    port=
    hostname=$host
    case "$host" in
      *:*) hostname=${host%%:*}; port=${host#*:} ;;
    esac
    if [ -n "$port" ]; then
      case "$port" in
        *[!0-9]*|0*) exit 0 ;;
      esac
      [ "${#port}" -ge 1 ] && [ "${#port}" -le 5 ] || exit 0
      [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || exit 0
    fi
    [ "${#hostname}" -ge 1 ] && [ "${#hostname}" -le 253 ] || exit 0
    [ "$hostname" != github.com ] || exit 0
    case "$hostname" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    # Gitea has no nested namespaces: the path is exactly owner/repository.
    case "$path" in
      */*/*|/*|*/) exit 0 ;;
      */*) ;;
      *) exit 0 ;;
    esac
    owner=${path%%/*}
    repo=${path#*/}
    for segment in "$owner" "$repo"; do
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 100 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$url" = "https://$host/$owner/$repo/pulls/$number" ] || exit 0
    command -v curl >/dev/null 2>&1 || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    command -v git >/dev/null 2>&1 || exit 0
    # The credential comes from git's helper chain for this exact authority, so
    # the instance's own stored login is reused rather than a second one being
    # invented. The prompt and askpass paths are pinned off: an unattended poll
    # cannot answer either, and a missing credential must fail rather than hang.
    filled=$(printf 'protocol=https\nhost=%s\n\n' "$host" \
      | GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false git credential fill 2>/dev/null) || exit 0
    user=$(printf '%s\n' "$filled" | sed -n 's/^username=//p' | head -1)
    secret=$(printf '%s\n' "$filled" | sed -n 's/^password=//p' | head -1)
    [ -n "$user" ] && [ -n "$secret" ] || exit 0
    # The credential is handed to curl on stdin as a config file rather than on
    # the command line, so it never appears in this process's arguments. curl's
    # config parser reads backslash and double quote as escapes inside a quoted
    # value, so both are escaped rather than assumed absent from a token.
    user=${user//\\/\\\\}
    user=${user//\"/\\\"}
    secret=${secret//\\/\\\\}
    secret=${secret//\"/\\\"}
    # --fail turns any HTTP error into a non-zero exit, so an unauthorized,
    # missing, or moved pull request stays silent instead of being parsed. Only
    # an exact JSON "merged": true wakes firstmate; every other body, including
    # one this build cannot parse, produces nothing rather than a false merge.
    body=$(printf 'user = "%s:%s"\n' "$user" "$secret" \
      | curl -sS --fail --max-time 20 -K - \
        "https://$host/api/v1/repos/$owner/$repo/pulls/$number" 2>/dev/null) || exit 0
    state=$(printf '%s' "$body" \
      | jq -r 'if type == "object" and .merged == true then "merged" else "open" end' 2>/dev/null) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
