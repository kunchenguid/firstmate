#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a merge. The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# GitHub is read through gh and GitLab through glab, so an upstream checkout
# needs no extra tooling to follow either. Bitbucket Cloud has no comparable
# CLI, so it is read with curl and jq instead, authenticated with a Workspace
# or Repository Access Token read from FM_BITBUCKET_TOKEN or the calling
# home's gitignored .env (bitbucket_token below, the same lookup
# bin/fm-pr-lib.sh's fm_pr_bitbucket_token owns); a home with neither stays
# silent rather than polling unauthenticated. FM_HOME is read from the
# environment when the caller already set it (bin/fm-watch.sh's --validated
# invocation does), and otherwise derived from this script's own path, which
# is $FM_HOME/state/<id>.check.sh when copied out as a task's own poll.
set -u
LC_ALL=C
export LC_ALL

bitbucket_home() {
  local state_dir
  if [ -n "${FM_HOME:-}" ]; then
    printf '%s' "$FM_HOME"
    return 0
  fi
  case "$0" in
    *.check.sh)
      state_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || return 1
      [ -n "$state_dir" ] || return 1
      printf '%s' "${state_dir%/state}"
      ;;
    *) return 1 ;;
  esac
}

bitbucket_token() {
  local home line val
  if [ -n "${FM_BITBUCKET_TOKEN:-}" ]; then
    printf '%s' "$FM_BITBUCKET_TOKEN"
    return 0
  fi
  home=$(bitbucket_home) || return 1
  [ -n "$home" ] && [ -f "$home/.env" ] || return 1
  line=$(grep -E '^[[:space:]]*(export[[:space:]]+)?FM_BITBUCKET_TOKEN=' "$home/.env" 2>/dev/null | tail -n1) || return 1
  [ -n "$line" ] || return 1
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}
  val=${val%"${val##*[![:space:]]}"}
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  [ -n "$val" ] || return 1
  printf '%s' "$val"
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
  bitbucket)
    [ "$host" = bitbucket.org ] || exit 0
    workspace=${path%%/*}
    repo=${path#*/}
    [ "${#workspace}" -ge 1 ] && [ "${#workspace}" -le 62 ] || exit 0
    case "$workspace" in
      .|..|-*|*-|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 62 ] || exit 0
    case "$repo" in
      .|..|-*|*-|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://bitbucket.org/$workspace/$repo/pull-requests/$number" ] || exit 0
    command -v curl >/dev/null 2>&1 || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    token=$(bitbucket_token) || exit 0
    [ -n "$token" ] || exit 0
    tmp=$(mktemp "${TMPDIR:-/tmp}/fm-pr-poll-bitbucket.XXXXXX") || exit 0
    cfg=$(mktemp "${TMPDIR:-/tmp}/fm-pr-poll-bitbucket-cfg.XXXXXX") || { rm -f "$tmp"; exit 0; }
    chmod 600 "$cfg" 2>/dev/null
    printf 'header = "Authorization: Bearer %s"\n' "$token" > "$cfg"
    http_status=$(curl -sS -K "$cfg" -o "$tmp" -w '%{http_code}' \
      -H 'Accept: application/json' \
      "https://api.bitbucket.org/2.0/repositories/$workspace/$repo/pullrequests/$number" 2>/dev/null) \
      || { rm -f "$tmp" "$cfg"; exit 0; }
    rm -f "$cfg"
    case "$http_status" in
      2??) ;;
      *) rm -f "$tmp"; exit 0 ;;
    esac
    state=$(jq -r 'if type == "object" and (.state | type == "string") then .state else empty end' "$tmp" 2>/dev/null)
    rm -f "$tmp"
    [ "$state" = MERGED ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
