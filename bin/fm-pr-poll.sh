#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a merge. The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub and glab
# for GitLab, so an upstream checkout needs no extra tooling to follow either.
#
# The optional 7th --validated field is the poll's published path under state/,
# which names the task the PR belongs to and the state directory holding its
# records. It is passed straight to bin/fm-poll-extra.sh, an optional local
# extension that answers a checkout's own extra questions about that task from
# the same wake; see that script's header. The field stays optional so a watcher
# still running the older 6-field call keeps polling for merges instead of being
# rejected, and the merge answer below never depends on it. That extension is the
# one thing that can add a line to this program's output; the merge answer above
# stays exactly as described whether or not a checkout has it.
set -u
LC_ALL=C
export LC_ALL

if { [ "$#" -eq 6 ] || [ "$#" -eq 7 ]; } && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
  check=${7:-}
elif [ "$#" -eq 0 ]; then
  check=
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

# The optional local extension point. It is resolved beside THIS program, never
# beside the published copy the state directory holds, so nothing dropped into
# state/ can be executed here; and it is resolved only when the caller passed the
# poll's published path, which the self-reading branch above never has. A
# checkout without the script, or one whose script fails, polls for merges
# exactly as before: every call is best effort and its errors are discarded, so
# an extension that cannot answer stays silent instead of colouring the merge
# answer. Phases: "begin" before the provider lookup, then exactly one of
# "merged", "open", or "unknown" once the lookup has answered or failed to.
extra=
if [ -n "$check" ]; then
  extra=$(dirname "$0")/fm-poll-extra.sh
  [ -f "$extra" ] && [ ! -L "$extra" ] && [ -x "$extra" ] || extra=
fi

poll_extra() {  # <phase>
  [ -n "$extra" ] || return 0
  "$extra" "$1" "$check" "$provider" "$url" "$host" "$path" "$number" 2>/dev/null || true
}

# A lookup that could not answer. Never a merge, and never silence that reads as
# "not merged": the extension counts it so a persistently broken poll is visible.
unanswered() {
  poll_extra unknown
  exit 0
}

merged=0

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
    poll_extra begin
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || unanswered
    [ "$state" = MERGED ] && merged=1
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
    poll_extra begin
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || unanswered
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || unanswered
    [ "$state" = merged ] && merged=1
    ;;
  codebase)
    case "$host" in
      code.byted.org|code-tx.byted.org) ;;
      *) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
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
        .|..|-*|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/merge_requests/$number" ] || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    poll_extra begin
    raw=$(bytedcli --json codebase mr get "$number" -R "$path" 2>/dev/null) || unanswered
    state=$(printf '%s\n' "$raw" | jq -r 'if .status == "success" then (.data.merge_request.Status // .data.merge_request.status // "") else "" end' 2>/dev/null) || unanswered
    case "$state" in
      merged|MERGED) merged=1 ;;
    esac
    ;;
  *) exit 0 ;;
esac

if [ "$merged" = 1 ]; then
  printf '%s\n' merged
  poll_extra merged
else
  poll_extra open
fi
exit 0
