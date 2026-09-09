#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a merge. The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI: gh for GitHub, glab for
# GitLab, and tea for Gitea/Forgejo, so an upstream checkout needs no extra
# tooling to follow any of them. Forgejo is a protocol-compatible fork of
# Gitea, so tea serves both under the "gitea" provider tag; the captain found
# tea more reliable than Forgejo's own fj CLI in manual testing against a real
# Forgejo instance, so tea is used here rather than fj.
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
    [ "$host" != github.com ] || exit 0
    [ "$host" != gitlab.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
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
    [ "$url" = "https://$host/$owner/$repo/pulls/$number" ] || exit 0
    # tea addresses a self-hosted instance through a configured login rather
    # than through the URL the way gh and glab do, so the login whose own
    # endpoint matches this record's endpoint is picked here. Any ambiguity or
    # missing login stays silent rather than guessing or prompting: an absent
    # or misconfigured login is indistinguishable from "not merged yet".
    # The comparison uses endpoint identity rather than raw URL text. A
    # scheme's default port (https :443, http :80) is stripped from the
    # login's URL, because this record's host never carries a port (the
    # gitea URL pattern above excludes ":" from the host class) and so names
    # the default-port endpoint, which a default-ported login is the same
    # endpoint as. Any other port names a different endpoint and is kept,
    # so a login for a non-default port can never stand in for this record.
    # The scheme itself is compared too: this record's URL is always https
    # (validated above against the literal "https://$host/..." form), so a
    # login on http, even for the identical host, names a different endpoint
    # and must never match.
    login=
    matches=0
    logins=$(tea login list -o csv 2>/dev/null) || exit 0
    [ -n "$logins" ] || exit 0
    while IFS=, read -r name login_url _rest; do
      [ -n "$name" ] || continue
      lscheme=
      lurl=$login_url
      case "$lurl" in
        http://*) lscheme=http; lurl=${lurl#http://} ;;
        https://*) lscheme=https; lurl=${lurl#https://} ;;
      esac
      lhost=${lurl%%/*}
      case "$lhost" in
        *[A-Z]*) lhost=$(printf '%s' "$lhost" | tr '[:upper:]' '[:lower:]') ;;
      esac
      case "$lscheme:$lhost" in
        https:*:443) lhost=${lhost%:443} ;;
        http:*:80) lhost=${lhost%:80} ;;
      esac
      if [ "$lscheme" = https ] && [ "$lhost" = "$host" ]; then
        matches=$((matches + 1))
        login=$name
      fi
    done < <(printf '%s\n' "$logins" | tail -n +2)
    [ "$matches" -eq 1 ] && [ -n "$login" ] || exit 0
    # tea's list command has no per-index field selector: "tea pulls <index>"
    # ignores -f/-o and prints a fixed detail view, so the closed+merged list
    # is read instead and matched down to the one recorded index. --state
    # closed already includes merged results because merged is a derived
    # display value over the same underlying closed state, so no open pull
    # request can ever be misread as merged. A single page can miss an old
    # merge once enough newer pull requests have since closed, so pages are
    # walked until the recorded index turns up or the server returns a
    # genuinely empty page marking the end of the list. Whether a page is
    # "full" is never inferred from the requested --limit: a server that
    # clamps its own page size below 1000 would then look short on every
    # page, and stopping on that would give up after page one even though
    # more pages remain. The walk carries no row or page budget: a watched
    # pull request stays valid however many newer pull requests have since
    # closed, and a cap would silently strand the watcher armed forever past
    # a merge that fell beyond it. "Empty" is judged by data rows rather than
    # raw output: tea's CSV always includes the header line, so a page with
    # zero pull requests still yields nonempty raw text, and stopping on raw
    # alone would never terminate once the list is exhausted.
    page=1
    state=
    while :; do
      raw=$(tea pulls list --repo "$owner/$repo" --login "$login" --state closed \
        --page "$page" --limit 1000 -f index,state -o csv 2>/dev/null) || exit 0
      rows=0
      while IFS=, read -r idx st; do
        rows=$((rows + 1))
        [ "$idx" = "$number" ] || continue
        state=$st
        break 2
      done < <(printf '%s\n' "$raw" | tail -n +2)
      [ "$rows" -gt 0 ] || break
      page=$((page + 1))
    done
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
