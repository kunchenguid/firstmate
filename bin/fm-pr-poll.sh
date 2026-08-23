#!/usr/bin/env bash
# Authoritative forge outcome extractor and formatter for ready and merged PRs.
# The static watcher program accepts only a validated provider-tagged identity,
# asks the forge for the PR state and destination branch, and asks for the
# repository default branch only after observing an exact merge.
# Ready callers use --validated-machine ready and receive the same extraction
# and wording path before publishing the merge poll.
#
# Machine output is one control-character-delimited record consumed only by
# trusted Firstmate scripts. Sidecar-driven and legacy --validated invocations
# print only the human outcome. Every lookup error in poll mode stays silent, so
# an unreadable PR can never be reported as merged; a ready caller instead gets
# an explicitly unavailable outcome, so arming never depends on a reachable
# forge. Missing destination/default evidence, drafts, and non-review terminal
# states are surfaced explicitly rather than inferred or folded into "ready".
set -u
LC_ALL=C
export LC_ALL

machine=0
phase=poll
if [ "$#" -eq 7 ] && [ "$1" = --validated-machine ]; then
  machine=1
  phase=$2
  provider=$3
  url=$4
  host=$5
  path=$6
  number=$7
  case "$phase" in ready|poll) ;; *) exit 0 ;; esac
elif [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
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

branch_valid() {
  [ -n "${1-}" ] && git check-ref-format --branch "$1" >/dev/null 2>&1
}

parse_forge_record() {
  local record=${1-} separator extra
  case "$record" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  separator=$(printf '\037')
  IFS="$separator" read -r state draft base head extra <<< "$record"
  [ -z "$extra" ] && [ -n "$state" ] || return 1
  case "$draft" in 0|1) ;; *) return 1 ;; esac
}

state=
draft=
base=
default_branch=
head=
project_url=

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must be exactly reconstructible from those components, so a
# doctored sidecar cannot redirect this lookup at another host or project. Those
# identity refusals exit outright and report nothing in either phase. A lookup
# that merely could not establish the forge's answer returns non-zero instead,
# so the caller can stay silent while polling and qualify while arming.
extract_forge_state() {
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
    pr_record=$(gh pr view "$url" --json state,isDraft,baseRefName,headRefOid \
      --jq '[.state // "", (if .isDraft == true then "1" else "0" end), .baseRefName // "", ((.headRefOid // "") | if test("^[0-9a-f]{40}$|^[0-9a-f]{64}$") then . else "" end)] | join("\u001f")' \
      2>/dev/null) || return 1
    parse_forge_record "$pr_record" || return 1
    case "$state" in
      MERGED) state=merged ;;
      OPEN) state=ready ;;
      CLOSED) state=closed ;;
      *) return 1 ;;
    esac
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
    command -v jq >/dev/null 2>&1 || return 1
    project_url="https://$host/$path"
    mr_json=$(GITLAB_HOST="$host" glab mr view "$number" -R "$project_url" -F json 2>/dev/null) \
      || return 1
    pr_record=$(printf '%s' "$mr_json" | jq -jr '
      if type == "object"
        and (.state | type == "string")
        and ((.target_branch | type) == "string" or (.target_branch | type) == "null")
        and ((.draft | type) == "boolean" or (.draft | type) == "null")
        and ((.work_in_progress | type) == "boolean" or (.work_in_progress | type) == "null")
      then [(.state),
            (if (.draft // .work_in_progress // false) then "1" else "0" end),
            (.target_branch // ""), ""] | join("\u001f")
      else error("invalid merge request outcome")
      end' 2>/dev/null) || return 1
    parse_forge_record "$pr_record" || return 1
    case "$state" in
      merged) ;;
      opened) state=ready ;;
      closed) state=closed ;;
      locked) state=locked ;;
      *) return 1 ;;
    esac
    ;;
  *) exit 0 ;;
  esac
  # A draft is open but explicitly not offered for review, so it is qualified
  # separately rather than folded into the ready outcome.
  if [ "$state" = ready ] && [ "$draft" = 1 ]; then
    state=draft
  fi
}

# Poll mode stays silent on every lookup error, so an unreadable PR can never be
# read as merged. Arming instead reports an explicitly unavailable outcome: the
# PR identity and the merge watch must not depend on a reachable forge, and an
# unread state is qualified as such rather than presented as a review outcome.
if ! extract_forge_state; then
  [ "$phase" = ready ] || exit 0
  state=unavailable
  draft=
  base=
  head=
fi

branch_valid "$base" || base=
case "$head" in
  ''|*[!0-9a-f]*) head= ;;
  *)
    [ "${#head}" -eq 40 ] || [ "${#head}" -eq 64 ] || head=
    ;;
esac

if [ "$phase" = poll ]; then
  [ "$state" = merged ] || exit 0
fi
# Each forge names this object differently, and the outcome sentence is relayed
# to the captain verbatim, so it uses the forge's own noun.
case "$provider" in
  github) subject=PR ;;
  gitlab) subject=MR ;;
  *) exit 0 ;;
esac
outcome_state=$state
case "$outcome_state" in
  merged) verb=merged ;;
  ready) verb="is ready for review" ;;
  draft) verb="is open as a draft and not yet ready for review" ;;
  closed) verb="is closed without merging" ;;
  locked) verb="is locked by the forge and not merged" ;;
  *) verb= ;;
esac

# Default-branch evidence has no bearing on a ready outcome. Defer this second
# forge lookup until an exact merge needs default-delivery classification.
if [ "$outcome_state" = merged ]; then
  case "$provider" in
    github)
      default_branch=$(gh repo view "$path" --json defaultBranchRef \
        --jq '.defaultBranchRef.name // ""' 2>/dev/null) || default_branch=
      ;;
    gitlab)
      repo_json=$(GITLAB_HOST="$host" glab repo view "$project_url" -F json 2>/dev/null) \
        || repo_json=
      if [ -n "$repo_json" ]; then
        default_branch=$(printf '%s' "$repo_json" | jq -jr '
          if type == "object"
            and ((.default_branch | type) == "string" or (.default_branch | type) == "null")
          then (.default_branch // "")
          else error("invalid repository outcome")
          end' 2>/dev/null) || default_branch=
      fi
      ;;
  esac
  branch_valid "$default_branch" || default_branch=
fi

if [ "$outcome_state" = unavailable ]; then
  human="$subject $url is unavailable from the forge; neither its state nor its destination branch could be established."
elif [ "$outcome_state" = ready ]; then
  if [ -n "$base" ]; then
    human="$subject $url $verb into '$base'."
  else
    human="$subject $url $verb, but its destination branch is unavailable from the forge."
  fi
elif [ "$outcome_state" != merged ]; then
  if [ -n "$base" ]; then
    human="$subject $url $verb; its destination branch is '$base'."
  else
    human="$subject $url $verb, and its destination branch is unavailable from the forge."
  fi
elif [ -n "$base" ] && [ -n "$default_branch" ] && [ "$base" = "$default_branch" ]; then
  human="$subject $url $verb into '$base', the repository default branch."
elif [ -n "$base" ] && [ -n "$default_branch" ]; then
  human="$subject $url $verb into '$base'; the repository default branch is '$default_branch'. This is not default-branch delivery."
elif [ -n "$base" ]; then
  human="$subject $url $verb into '$base'; the repository default branch could not be established. Default-branch delivery is unverified."
elif [ -n "$default_branch" ]; then
  human="$subject $url $verb, but its destination branch is unavailable from the forge; the repository default branch is '$default_branch'. Default-branch delivery is unverified."
else
  human="$subject $url $verb, but its destination branch and the repository default branch are unavailable from the forge. Default-branch delivery is unverified."
fi

if [ "$machine" -eq 1 ]; then
  unit_separator=$(printf '\037')
  printf 'fm-pr-outcome-v1%s%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$unit_separator" "$outcome_state" \
    "$unit_separator" "$url" \
    "$unit_separator" "$base" \
    "$unit_separator" "$default_branch" \
    "$unit_separator" "$head" \
    "$unit_separator" "$human"
else
  printf '%s\n' "$human"
fi
exit 0
