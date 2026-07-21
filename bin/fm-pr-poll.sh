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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The published poll is a link into the state directory, so the shared quota
# guard is located from the candidates that can name a firstmate bin directory.
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
    # A GitHub read goes through the shared quota guard: while the account is
    # walled the last cached state answers instead of another rejected call.
    state=
    if quota_bin=$(find_quota_bin 2>/dev/null); then
      github_route=${FM_GITHUB_ROUTE:-default}
      cache_key="pr-state:$url"
      quota_out=$(FM_SHARED_GITHUB_QUOTA_DERIVE_ACCOUNT=0 \
        "$quota_bin" check --provider github --route "$github_route" 2>/dev/null || true)
      quota_state=$(printf '%s\n' "$quota_out" | sed -n 's/^state=//p' | tail -1)
      if [ "$quota_state" = defer ]; then
        state=$(FM_SHARED_GITHUB_QUOTA_DERIVE_ACCOUNT=0 \
          "$quota_bin" cache-get --provider github --route "$github_route" --key "$cache_key" \
          --max-age-secs "${FM_GITHUB_QUOTA_DEFER_CACHE_MAX_AGE_SECS:-86400}" 2>/dev/null || true)
      else
        gh_err=$(mktemp "${TMPDIR:-/tmp}/fm-gh-pr.XXXXXXXX") || exit 0
        if state=$(gh pr view "$url" --json state -q .state 2>"$gh_err"); then
          printf '%s\n' "$state" | FM_SHARED_GITHUB_QUOTA_DERIVE_ACCOUNT=0 \
            "$quota_bin" cache-put --provider github --route "$github_route" \
            --key "$cache_key" >/dev/null 2>&1 || true
        else
          FM_SHARED_GITHUB_QUOTA_DERIVE_ACCOUNT=0 \
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
