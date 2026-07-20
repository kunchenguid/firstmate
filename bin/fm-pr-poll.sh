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

# The number is provider-agnostic and validated first. The remaining field
# validation is applied per provider below; owner/repo/number were already
# validated end-to-end against this URL by fm_pr_url_parse when the sidecar was
# prepared, so these are the byte-static poll's own reinforcement before it
# passes the fields to a provider CLI.
case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

if [ "$url" = "https://github.com/$owner/$repo/pull/$number" ]; then
  [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
  case "$owner" in
    *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
  esac
  [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
  case "$repo" in
    .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
  esac
  state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
  [ "$state" = MERGED ] && printf '%s\n' merged
  exit 0
fi

# Bitbucket Data Center. Re-derive the host from the URL and select the bkt
# context whose host matches; bkt silently queries the default context's
# repository when --project/--repo are omitted, so they are always passed
# explicitly. This mirrors fm_pr_dc_context_for_host and fm_pr_dc_pr_field in
# fm-pr-lib.sh; the byte-static poll cannot source the lib, so the context
# resolution is repeated here as the one allowed execution-seam reinforcement.
dc_re='^https://([A-Za-z0-9][A-Za-z0-9.-]*)/(users|projects)/[A-Za-z0-9][A-Za-z0-9._-]*/repos/[A-Za-z0-9._-]{1,100}/pull-requests/[1-9][0-9]*$'
[[ "$url" =~ $dc_re ]] || exit 0
host=${BASH_REMATCH[1]}
[[ "$host" == *.* ]] || exit 0
case "$host" in
  *.|*-) exit 0 ;;
esac
[ "${#owner}" -ge 1 ] && [ "${#owner}" -le 255 ] || exit 0
case "$owner" in
  *[!A-Za-z0-9._~-]*) exit 0 ;;
esac
[ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
case "$repo" in
  .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
command -v bkt >/dev/null 2>&1 || exit 0
tail=" (host: $host)"
ctx=
ctx_count=0
while IFS= read -r _line; do
  case "$_line" in
    *"$tail") ;;
    *) continue ;;
  esac
  _name=${_line#"${_line%%[! *]*}"}
  _name=${_name%"$tail"}
  [ -n "$_name" ] || continue
  ctx=$_name
  ctx_count=$((ctx_count + 1))
done < <(bkt context list 2>/dev/null)
[ "$ctx_count" -eq 1 ] || exit 0
state=$(bkt pr view "$number" --project "$owner" --repo "$repo" -c "$ctx" --json --jq '.pull_request.state' 2>/dev/null) || exit 0
case "$state" in
  '"'*'"')
    state=${state#?}
    state=${state%?}
    ;;
esac
[ "$state" = MERGED ] && printf '%s\n' merged
exit 0
