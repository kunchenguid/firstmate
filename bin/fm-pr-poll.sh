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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_quota_bin() {
  local candidate
  for candidate in \
    "$script_dir/fm-shared-github-quota.sh" \
    "${FM_ROOT_OVERRIDE:-}/bin/fm-shared-github-quota.sh" \
    "${FM_HOME:-}/bin/fm-shared-github-quota.sh" \
    "$script_dir/../bin/fm-shared-github-quota.sh"; do
    [ -n "$candidate" ] || continue
    [ -x "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

state=
if quota_bin=$(find_quota_bin 2>/dev/null); then
  github_route=${FM_GITHUB_ROUTE:-default}
  cache_key="pr-state:$url"
  quota_out=$("$quota_bin" check --provider github --route "$github_route" 2>/dev/null || true)
  quota_state=$(printf '%s\n' "$quota_out" | sed -n 's/^state=//p' | tail -1)
  if [ "$quota_state" = defer ]; then
    state=$("$quota_bin" cache-get --provider github --route "$github_route" --key "$cache_key" \
      --max-age-secs "${FM_GITHUB_QUOTA_DEFER_CACHE_MAX_AGE_SECS:-86400}" 2>/dev/null || true)
  else
    gh_err=$(mktemp "${TMPDIR:-/tmp}/fm-gh-pr.XXXXXXXX") || exit 0
    if state=$(gh pr view "$url" --json state -q .state 2>"$gh_err"); then
      printf '%s\n' "$state" | "$quota_bin" cache-put --provider github --route "$github_route" \
        --key "$cache_key" >/dev/null 2>&1 || true
    else
      "$quota_bin" mark-from-text --provider github --route "$github_route" \
        --source "fm-pr-poll:$url" --file "$gh_err" >/dev/null 2>&1 || true
      state=
    fi
    rm -f "$gh_err"
  fi
else
  state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
fi

[ "$state" = MERGED ] && printf '%s\n' merged
exit 0
