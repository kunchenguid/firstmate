#!/usr/bin/env bash
# Single owner of the rule that a recorded completion names the registered
# project's pull request, or declares a delivery that publishes none.
#
# Two recording paths accept a completion claim, and both call into here so the
# rule cannot drift between them:
#
#   fm_done_url_status_refusal   the status append path, through
#                                bin/fm-dod-lib.sh's ship done: gate. A done:
#                                that reports the delivery must name the
#                                registered project's pull request, so
#                                firstmate can read one off the line instead of
#                                assembling it from memory.
#   fm_done_url_backlog_refusal  the backlog done transition, through
#                                bin/fm-teardown.sh's completion-record builder.
#                                That record is the terminal one: it is written
#                                after landing is confirmed, so a Done row must
#                                name a pull request that has actually landed.
#
# WHY, WITH THE RECORD BEHIND IT (data/backlog.md and data/done-archive.md,
# counted, not estimated): of the ship-kind Done rows this home recorded for the
# night of 2026-10-01/02, 26 rows are dated to that window and ZERO of them
# carry a pull-request URL. Across all recorded ship-kind Done rows, 41 of 79
# carry none. A surviving status record from that window shows the shape the
# rows came from - state/orbbot-steer-into-running-turn-a1.status line 3 reads
# `done [at=1790869885]: steer shipped on fm/orbbot-steer-into-running-turn-a1
# (d269b60, fe8e26c): ...`, a completion naming a branch and commits and never
# a pull request, with the work living in that task's own copy. Each of those
# jobs was found by reading the forge by hand, because nothing refused the line.
# Those counts are the reason this is a check and not a paragraph.
#
# The no-mistakes pre-validation `done: {summary}` is deliberately NOT a
# completion claim: it is the documented pipeline handoff, it opens no pull
# request, and bin/fm-dod-lib.sh's fm_dod_should_gate_ship_done already declines
# to gate it. fm_done_url_status_refusal is only ever called on the branch that
# gate selected, so the handoff is untouched while the completion that follows it
# is not.
#
# Project identity is read from the task's registered clone's own origin, not
# from the registry and not from the URL under test, so the comparison cannot be
# satisfied by a URL that merely looks like the project's. An origin that names
# no forge host at all - a local path, a bare filesystem mirror - carries no
# identity to contradict, so the project check reports "unverifiable" and the
# caller keeps its existing behaviour instead of refusing on no evidence. Only a
# PROVABLE difference refuses.
#
# Landing is the caller's claim, never this file's guess. The only proof accepted
# is the one the merge path already performs: bin/fm-pr-lib.sh's merge-notified
# marker, which the merge poll and bin/fm-merge-outcome-lib.sh write only after a
# confirmed merge. A caller holding that proof passes it in; a caller without it
# has not proven landing, and "I pushed something" is not landed.
#
# Sourced by bin/fm-dod-lib.sh and bin/fm-teardown.sh. Every refusal prints one
# line on stdout naming what is missing, because these refusals are read by a
# human deciding what to do next.

_FM_DONE_URL_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd 2>/dev/null)" || _FM_DONE_URL_LIB_DIR="."
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$_FM_DONE_URL_LIB_DIR/fm-pr-lib.sh"

# fm_done_url_endpoint_identity <url>: the "<host>/<owner>/<repo>" the URL
# addresses, reduced from the three pull-request shapes this repository ships
# against. Shape, not provider allowlist, is the test: a GitHub Enterprise host
# is addressed exactly as github.com is, so a completion naming one is readable
# and comparable on any host. Prints the identity and returns 0; returns 1 with
# no output for anything that is not one of those shapes.
fm_done_url_endpoint_identity() {  # <url>
  local raw=${1-} host path
  local LC_ALL=C
  case "$raw" in
    *[[:space:]]* | *[![:print:]]*) return 1 ;;
  esac
  if [[ "$raw" =~ ^https://([^/@]+)/(.+)/pull/([1-9][0-9]*)$ ]]; then
    host=${BASH_REMATCH[1]}
    path=${BASH_REMATCH[2]}
  elif [[ "$raw" =~ ^https://([^/@]+)/(.+)/-/merge_requests/([1-9][0-9]*)$ ]]; then
    host=${BASH_REMATCH[1]}
    path=${BASH_REMATCH[2]}
  elif [[ "$raw" =~ ^https://([^/@]+)/c/(.+)/\+/([1-9][0-9]*)$ ]]; then
    host=${BASH_REMATCH[1]}
    path=${BASH_REMATCH[2]}
  else
    return 1
  fi
  case "$host" in
    '' | *[!A-Za-z0-9.:-]*) return 1 ;;
  esac
  printf '%s/%s\n' "$host" "$path"
}

# fm_done_url_origin_identity <repo-dir>: the "<host>/<owner>/<repo>" the
# registered project's own clone fetches from. Every accepted origin shape is
# reduced here, so a caller never has to know whether this host was cloned over
# https, ssh, or scp-like syntax: a scheme form loses its scheme and userinfo, an
# scp-like form loses its user, and both lose a trailing .git. Returns 1 for an
# origin that names no host - a local path, a file:// mirror, a missing or
# unreadable clone - because that carries no identity to compare.
fm_done_url_origin_identity() {  # <repo-dir>
  local repo=$1 url rest authority host path
  [ -n "$repo" ] && [ -d "$repo" ] || return 1
  url=$(git -C "$repo" remote get-url origin 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  rest=${url%/*}
  case "$url" in
    *://*)
      rest=${url#*://}
      authority=${rest%%/*}
      # An ssh:// URL keeps its path after the authority; an https:// one does
      # too. Strip any userinfo, then the optional numeric port.
      host=${authority##*@}
      case "$host" in
        *:*)
          case "${host##*:}" in
            '' | *[!0-9]*) return 1 ;;
          esac
          host=${host%%:*}
          ;;
      esac
      path=${rest#"$authority"}
      path=${path#/}
      ;;
    *:*)
      # scp-like [user@]host:path. Drop the user only when an "@" really
      # precedes the host, so a path containing "@" keeps its own colon.
      case "$url" in
        *@*) rest=${url##*@} ;;
      esac
      host=${rest%%:*}
      path=${rest#*:}
      ;;
    *) return 1 ;;
  esac
  case "$host" in
    '' | *[!A-Za-z0-9.-]*) return 1 ;;
  esac
  path=${path%.git}
  path=${path%/}
  [ -n "$path" ] || return 1
  printf '%s/%s\n' "$host" "$path"
}

# fm_done_url_foreign_project <url> <repo-dir>: 0 only when the URL and the
# registered project PROVABLY name different repositories. Both sides are
# compared case-insensitively, because host and repository naming are not
# case-sensitive on the forges this repository ships against and a comparison
# that could refuse on letter case alone would be refusing on no evidence.
# Returns 1 both when they agree and when the comparison is impossible - an
# unreadable URL, or an origin carrying no host - because "unverifiable" is
# never a reason to refuse.
fm_done_url_foreign_project() {  # <url> <repo-dir>
  local url_id project_id
  url_id=$(fm_done_url_endpoint_identity "$1") || return 1
  project_id=$(fm_done_url_origin_identity "$2") || return 1
  [ "$(printf '%s' "$url_id" | tr '[:upper:]' '[:lower:]')" \
    != "$(printf '%s' "$project_id" | tr '[:upper:]' '[:lower:]')" ]
}

# fm_done_url_from_note <note>: the first pull request or change URL the note
# names, wherever in the sentence it appears. A done line may carry a
# correlation key, a pipeline qualifier, or trailing punctuation around the URL,
# and a completion whose URL cannot be read off its own line is a completion
# firstmate cannot act on, so the scan is over whitespace-delimited tokens with
# the surrounding punctuation removed rather than a fixed prefix.
fm_done_url_from_note() {  # <note>
  local note=$1 token
  for token in $note; do
    token=${token#(}
    token=${token%,}
    token=${token%;}
    token=${token%:}
    token=${token%.}
    token=${token%)}
    if fm_done_url_endpoint_identity "$token" >/dev/null; then
      printf '%s\n' "$token"
      return 0
    fi
  done
  return 1
}

# fm_done_url_landed_proven <url> <state-dir> <task-id>: 0 when the merge path
# already recorded this exact pull request as merged. The marker is bound to the
# canonical provider, host, path, and number, so a merge recorded for one pull
# request never proves another. This is the only landing proof accepted; a caller
# that cannot produce it has not proven landing.
fm_done_url_landed_proven() {  # <url> <state-dir> <task-id>
  local url=$1 state=$2 id=$3
  fm_pr_url_parse "$url" || return 1
  fm_pr_poll_merge_already_notified "$state" "$id" \
    "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"
}

# fm_done_url_status_refusal <kind> <mode> <note> <project-dir>: the status
# append path. Returns 0 when the completion claim is acceptable, or 1 with one
# line on stdout naming what is missing.
#
# A scout delivers a report and publishes nothing, so its done: is untouched.
# A local-only ship publishes no pull request by construction, which is the one
# delivery mode the captain's rule exempts. Every other ship reports a pull
# request, so a completion that names none is refused rather than read as
# finished: that refusal is what keeps a job living only in its own copy from
# reaching the fleet as shipped work.
fm_done_url_status_refusal() {  # <kind> <mode> <note> <project-dir>
  local kind=$1 mode=$2 note=$3 project=$4 url
  [ "$kind" = ship ] || return 0
  [ "$mode" = local-only ] && return 0
  if ! url=$(fm_done_url_from_note "$note"); then
    printf '%s\n' "this done reports completion with no pull-request URL: name the pull request exactly as the forge printed its full https:// URL, or the task must be local-only delivery"
    return 1
  fi
  if fm_done_url_foreign_project "$url" "$project"; then
    printf '%s\n' "this done names $url, which is not a pull request on the registered project; a done must name this project's own pull request"
    return 1
  fi
  return 0
}

# fm_done_url_backlog_refusal <kind> <mode> <url> <landed:0|1> <project-dir>
# <worktree-dir> <state-dir> <task-id>: the backlog done transition. Returns 0
# when the terminal record is acceptable, or 1 with one line on stdout naming
# what is missing.
#
# This record is written after landing is confirmed, so it is the one place where
# "done" can mean landed rather than pushed. <landed> is the caller's own
# landed-work result, which is the same test this teardown already demands before
# it removes a copy; without it a pull request that is still open is refused,
# because a Done row naming an open pull request is how "I opened a PR" gets
# rendered as shipped work.
#
# A pull request that IS recorded is always checked against the registered
# project, and for landing whenever the task's mode publishes one at all. When
# none is recorded, the only honest Done rows are the ones with nothing a pull
# request could have carried:
#
#   landed=1   the caller proved the work is already in the default branch or
#              under a merged pull request, so there is no undelivered change
#              for a missing URL to be hiding.
#   no copy    the recorded worktree is gone: no branch, no commit, nothing
#              anywhere a Done row could be claiming. This is a retirement of a
#              dead leftover, not a delivery.
#
# A branch that is merely pushed, or that exists only in the disposable copy, is
# refused. That is the class the 26 ship Done rows of 2026-10-01/02 recorded with
# no pull-request URL at all came from.
fm_done_url_backlog_refusal() {  # <kind> <mode> <url> <landed:0|1> <project-dir> <worktree-dir> <state-dir> <task-id>
  local kind=$1 mode=$2 url=$3 landed=$4 project=$5 worktree=$6 state=$7 id=$8
  [ "$kind" = scout ] && return 0
  if [ "$mode" = local-only ]; then
    [ -z "$url" ] && return 0
  elif [ -z "$url" ]; then
    if [ "$landed" = 1 ]; then
      return 0
    fi
    if [ -n "$worktree" ] && [ ! -d "$worktree" ]; then
      return 0
    fi
    printf '%s\n' "this task records completion with no pull-request URL: record the landed pull request's full https:// URL, or the task must be local-only delivery"
    return 1
  fi
  fm_pr_url_parse "$url" || {
    printf '%s\n' "the recorded pull request URL ($url) is not a pull request this repository can address; record the full https:// URL exactly as the forge printed it"
    return 1
  }
  if fm_done_url_foreign_project "$url" "$project"; then
    printf '%s\n' "the recorded pull request $url is not a pull request on the registered project; a done must name this project's own pull request"
    return 1
  fi
  if [ "$mode" != local-only ] && [ "$landed" != 1 ]; then
    if fm_done_url_landed_proven "$url" "$state" "$id"; then
      return 0
    fi
    printf '%s\n' "the recorded pull request $url is not recorded as landed; a done must mean landed, not pushed - merge it through bin/fm-pr-merge.sh, or record a local-only landing"
    return 1
  fi
  return 0
}