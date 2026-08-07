#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one line and stays silent otherwise, including on every
# error, so a failed lookup can never be read as a merge or as review activity.
# The provider-tagged identity is data in the sidecar and is never interpolated
# into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub and glab
# for GitLab, so an upstream checkout needs no extra tooling to follow either.
#
# Reported lines:
#   merged
#     the pull request or merge request is merged. Terminal and exclusive: a
#     merged result is reported alone so its existing retirement stays exact.
#   review-activity reviews=<n> comments=<n> latest=<iso8601>
#     GitHub only. The pull request's current review-activity totals and the
#     newest activity instant, as a stateless observation of right now, counting
#     only what someone else did: a comment firstmate itself posted is excluded,
#     because waking firstmate to tell it about its own comment is exactly the
#     cry-wolf noise the cursor below exists to prevent.
#     Suppressing an unchanged repeat is deliberately NOT this program's job:
#     the watcher treats every non-empty check output as actionable, so it owns
#     the per-task cursor (bin/fm-pr-lib.sh's fm_pr_activity_filter). A check is
#     invoked with no task identity and must never write task state, so a cursor
#     kept here could not be addressed or trusted.
#     Every remote string stays out of this line: only validated counts and one
#     validated instant are reported, and firstmate reads the pull request
#     itself for the content.
#     GitLab reports merge state only. Its plain CLI has no field selector and
#     firstmate does not require a JSON processor, the same constraint that
#     already leaves a GitLab task without a recorded pr_head.
#
# The forge-CLI facts this program depends on - that the fields below exist,
# that they carry those instants, and that a review row exists for every inline
# review comment including a thread reply - are established by running the real
# CLI in docs/verification/pr-review-activity.md. Refresh that record after a gh
# upgrade: the colocated tests stub gh and cannot notice a real field going away.
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
    # Review activity is read in its own call, so a change to the shape below
    # can never turn a working merge lookup silent. Every review row covers one
    # unit of review activity: gh's reviews field carries submitted reviews and
    # the COMMENTED review GitHub creates for a standalone inline comment or a
    # reply in an existing review thread, and its comments field carries the
    # pull request's issue comments.
    # A comment firstmate itself posted is not news it needs waking for, so
    # viewerDidAuthor drops it from the count AND from the instant: excluding it
    # from only one of the two would let firstmate's own comment move the marker
    # and wake firstmate about itself. The test is "!= true" rather than
    # "== false" so a field that stops being reported counts the comment instead
    # of silently suppressing it. Reviews carry no such field (their keys are
    # recorded in the verification record below), so a review stays counted
    # whoever submitted it; comparing author logins instead would put a remote
    # string in the decision, which this deliberately does not do.
    # shellcheck disable=SC2016 # $c is a jq binding, and must not expand here.
    activity=$(gh pr view "$url" --json reviews,comments \
      -q '(.comments // []|map(select(.viewerDidAuthor != true))) as $c|[(.reviews|length|tostring),($c|length|tostring),(([(.reviews[]?.submittedAt),($c[]?.createdAt)]|map(select(. != null and . != ""))|max) // "")]|join(" ")' \
      2>/dev/null) || exit 0
    reviews=${activity%% *}
    rest=${activity#* }
    comments=${rest%% *}
    latest=${rest#* }
    # The three field patterns below are what constrain the shape, and they
    # constrain it completely: latest is everything past the second space, so a
    # missing, extra, padded, tab-joined, or multi-line result leaves it holding
    # a space or a newline and no instant pattern can match it, while a short
    # result leaves a count holding a non-digit. Reconstructing the string to
    # re-check the field count on top of that rejects nothing these do not, so
    # there is deliberately no such check to mistake for a live one.
    case "$reviews" in ''|*[!0-9]*) exit 0 ;; esac
    case "$comments" in ''|*[!0-9]*) exit 0 ;; esac
    [ "${#reviews}" -le 9 ] && [ "${#comments}" -le 9 ] || exit 0
    # An empty instant is the no-activity-yet case and reports nothing.
    case "$latest" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
      *) exit 0 ;;
    esac
    printf 'review-activity reviews=%s comments=%s latest=%s\n' "$reviews" "$comments" "$latest"
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
