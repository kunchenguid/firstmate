#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a merge. The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI: gh for GitHub, glab for
# GitLab, and tea for Gitea, so an upstream checkout needs no extra tooling to
# follow any of them.
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
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    case "$host" in
      github.com|gitlab.com) exit 0 ;;
    esac
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    case "$path" in
      */*) ;;
      *) exit 0 ;;
    esac
    owner=${path%%/*}
    repo=${path#*/}
    case "$repo" in
      */*) exit 0 ;;
    esac
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 40 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://$host/$owner/$repo/pulls/$number" ] || exit 0
    # tea addresses a login by name, not by URL, so the login bound to this
    # host is resolved from tea's own login table rather than an env var the
    # way GITLAB_HOST selects a glab credential. No jq is required: tea's
    # tsv output is one tab-separated record per line, which a plain read
    # loop parses without a JSON processor, matching the GitLab case above.
    # An absent or ambiguous login refuses exactly like an absent CLI: this
    # poll never guesses which server a merge result would come from.
    logins=$(tea logins list --output tsv 2>/dev/null) || exit 0
    login=
    matches=0
    header=1
    while IFS=$'\t' read -r lname lurl _rest; do
      if [ "$header" = 1 ]; then
        header=0
        continue
      fi
      [ "$lurl" = "https://$host" ] || continue
      matches=$((matches + 1))
      login=$lname
    done <<LOGINS
$logins
LOGINS
    [ "$matches" -eq 1 ] && [ -n "$login" ] || exit 0
    # tea addresses a single pull request directly by its index, the same
    # shape gh's view and glab's view already use above, so there is no list
    # to page through and no list ordering to reason about. hasMerged is read
    # out of tea's JSON with jq, which every other Gitea code path in this
    # project already requires unconditionally for the login table lookup, so
    # this costs no dependency the operator did not already need; a missing
    # jq, like a missing tea or an unreadable pull request, degrades silently
    # rather than reporting a merge.
    raw=$(tea pulls "$number" --login "$login" --repo "$owner/$repo" --output json 2>/dev/null) || exit 0
    state=$(printf '%s' "$raw" | jq -r '.hasMerged // empty' 2>/dev/null) || exit 0
    [ "$state" = true ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
