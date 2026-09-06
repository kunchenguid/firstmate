#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR, or exactly one
# dequeued:<reason>:<timestamp> line when a GitHub pull request is OPEN and its
# latest merge-queue timeline event is a removal after the last enqueue, and
# stays silent otherwise, including on every error, so a failed lookup can
# never be read as a merge or an ejection. The provider-tagged identity is data
# in the sidecar and is never interpolated into this source: these bytes are
# identical for every task. Runtime sidecar values are passed only as gh/glab
# arguments, the same way the merge read already passes the reconstructed URL.
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
    if [ "$state" = MERGED ]; then
      printf '%s\n' merged
      exit 0
    fi
    # An OPEN pull request that left the merge queue is still blocked, but the
    # merge read above is silent on OPEN. The forge's RemovedFromMergeQueueEvent
    # carries the reason, but that reason is nullable and free-form, so a
    # current ejection the forge left unlabelled still wakes under the
    # unreported sentinel and one no reader can parse wakes under unreadable:
    # an ejection is never dropped for the shape of its reason. Silence stays
    # reserved for a pull request still in the queue and for a read that failed.
    [ "$state" = OPEN ] || exit 0
    # shellcheck disable=SC2016 # GraphQL variables are for gh, not the shell.
    gql_query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){isInMergeQueue timelineItems(last:20,itemTypes:[ADDED_TO_MERGE_QUEUE_EVENT,REMOVED_FROM_MERGE_QUEUE_EVENT]){nodes{__typename ... on AddedToMergeQueueEvent{createdAt} ... on RemovedFromMergeQueueEvent{createdAt reason}}}}}}'
    # shellcheck disable=SC2016 # jq owns every $ expression in this filter.
    gql_filter='.data.repository.pullRequest as $pr | if $pr == null then empty elif $pr.isInMergeQueue != false then empty else (($pr.timelineItems.nodes // []) | map(select(. != null and .createdAt != null)) | last) as $ev | if $ev.__typename == "RemovedFromMergeQueueEvent" then ((($ev.reason // "") | tostring) as $r | (if ($r | test("^[A-Za-z0-9_]+$")) then $r elif $r == "" then "unreported" else "unreadable" end) as $t | "\($t)\t\($ev.createdAt)") else empty end end'
    raw=$(gh api graphql -f query="$gql_query" -f owner="$owner" -f name="$repo" -F number="$number" -q "$gql_filter" 2>/dev/null) || exit 0
    [ -n "$raw" ] || exit 0
    case "$raw" in
      *$'\n'*) exit 0 ;;
    esac
    reason=${raw%%$'\t'*}
    created=${raw#*$'\t'}
    [ "$reason" != "$raw" ] || exit 0
    [ "$created" != "$raw" ] || exit 0
    case "$created" in
      *$'\t'*) exit 0 ;;
    esac
    case "$reason" in
      ''|*[!A-Za-z0-9_]*) exit 0 ;;
    esac
    [[ "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$ ]] || exit 0
    printf 'dequeued:%s:%s\n' "$reason" "$created"
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
