#!/usr/bin/env bash
# fm-tracker.sh - the single owner of firstmate's GitHub Issues project layer.
#
# GitHub Issues carries firstmate's project state: the destination, the
# decisions, the known unknowns, and the tasks, with real blocking edges between
# them. tasks-axi remains the execution layer and is untouched by this script.
#
# This script exists because a half-adopted convention produces confident wrong
# answers rather than obvious failures. Two defects observed in a hand-rolled
# run of this structure are made structurally impossible here:
#
#   1. Blocking edges written as prose. GitHub builds a queryable trackedIssues
#      edge only from a markdown task-list reference, so a prose
#      "Blocked by: #144" is invisible to the frontier query and the blocked
#      ticket reports READY. Every write path emits the task-list form under one
#      fixed heading, and a body carrying a prose blocker is REFUSED.
#   2. Ticket type parsed out of the title string, so a reworded title silently
#      reclassified a ticket. Type is a label (fm:destination, fm:decision,
#      fm:unknown, fm:task) and is never read from, or written into, a title.
#
# Because this script is the only writer of that structure, `validate` is a real
# guard rather than a linter over free text.
#
# GitHub Projects is deliberately out of scope: this builds on Issues only.
#
# Requires gh, authenticated. gh-axi cannot serve this script: it exposes
# neither the GraphQL endpoint the issue graph needs nor response headers.
#
# Usage:
#   fm-tracker.sh init <owner/repo> --destination <title> [--body-file <path>]
#   fm-tracker.sh add <owner/repo> --type <destination|decision|unknown|task>
#                     --title <title> [--body <text>|--body-file <path>]
#                     [--parent <n>] [--blocked-by <n[,n...]>]
#   fm-tracker.sh frontier <owner/repo>
#   fm-tracker.sh claim <owner/repo> <n>
#   fm-tracker.sh release <owner/repo> <n>
#   fm-tracker.sh answer <owner/repo> <n> --decision <text>
#                     [--settles <text>] [--does-not-settle <text>]
#   fm-tracker.sh validate <owner/repo>
#   fm-tracker.sh watch --task <task-id> <owner/repo> [more owner/repo...]
#   fm-tracker.sh unwatch --task <task-id>
#   fm-tracker.sh --help
#
# Exit status: 0 on success, 1 on a refused or failed operation, 2 on invalid
# usage. `validate` exits 1 when it reports any malformed ticket.
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-tracker-lib.sh
. "$SCRIPT_DIR/fm-tracker-lib.sh"

GH=${FM_TRACKER_GH:-gh}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage_die() { printf 'error: %s\n' "$*" >&2; printf 'run: fm-tracker.sh --help\n' >&2; exit 2; }

print_help() {
  sed -n '3,/^set -u$/p' "$SCRIPT_DIR/fm-tracker.sh" | sed 's/^#\{1\} \{0,1\}//; $d'
}

require_gh() {
  command -v "$GH" >/dev/null 2>&1 || die "$GH is not on PATH"
}

parse_repo() {  # <owner/repo>
  local spec=${1-}
  fm_tracker_repo_parse "$spec" || usage_die "invalid repository '$spec' (expected owner/repo)"
  OWNER=$FM_TRACKER_OWNER
  REPO=$FM_TRACKER_REPO
}

gh_api() { "$GH" api "$@"; }

# ---------------------------------------------------------------------------
# Body assembly and the blocked-by contract
# ---------------------------------------------------------------------------

# The caller's prose first, then the one fixed blocked-by section. The task-list
# form is what GitHub turns into a real trackedIssues edge, and GitHub ticks the
# checkbox as each blocker closes, so the graph and the rendered issue cannot
# disagree.
compose_body() {  # <body> <blocker-csv>
  local body=$1 blockers=$2 n
  printf '%s' "$body"
  [ -z "$body" ] || printf '\n'
  [ -n "$blockers" ] || return 0
  printf '\n%s\n' "$FM_TRACKER_BLOCKED_HEADING"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    printf -- '- [ ] #%s\n' "$n"
  done <<EOF
$(printf '%s' "$blockers" | tr ',' '\n')
EOF
}

# Every blocker must be a real issue in this repository. A typo'd number would
# leave a task-list entry GitHub never resolves into an edge - defect 1 arriving
# through a different door: a ticket that looks blocked and queries as ready.
verify_blockers_exist() {  # <csv>
  local csv=$1 n
  [ -n "$csv" ] || return 0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    gh_api "/repos/$OWNER/$REPO/issues/$n" --jq .number >/dev/null 2>&1 \
      || die "blocker #$n does not exist in $OWNER/$REPO"
  done <<EOF
$(printf '%s' "$csv" | tr ',' '\n')
EOF
}

ensure_labels() {
  local t name desc color
  for t in $FM_TRACKER_TYPES; do
    name=$(fm_tracker_type_label "$t")
    case "$t" in
      destination) desc='firstmate: the destination this project steers toward'; color=0e8a16 ;;
      decision) desc='firstmate: a decision the captain owns'; color=b60205 ;;
      unknown) desc='firstmate: a known unknown to be resolved'; color=fbca04 ;;
      *) desc='firstmate: executable work'; color=1d76db ;;
    esac
    gh_api -X POST "/repos/$OWNER/$REPO/labels" \
      -f "name=$name" -f "description=$desc" -f "color=$color" >/dev/null 2>&1 || true
  done
}

create_issue() {  # <title> <body> <type>
  local title=$1 body=$2 type=$3 label num
  label=$(fm_tracker_type_label "$type")
  num=$(gh_api -X POST "/repos/$OWNER/$REPO/issues" \
    -f "title=$title" -f "body=$body" -f "labels[]=$label" --jq .number) \
    || die "could not create the issue in $OWNER/$REPO"
  fm_tracker_issue_number_valid "$num" || die "GitHub returned no usable issue number"
  printf '%s\n' "$num"
}

node_id_for() {  # <number>
  gh_api "/repos/$OWNER/$REPO/issues/$1" --jq .node_id 2>/dev/null
}

# Native sub-issue attachment, so hierarchy and completion rollup come from
# GitHub rather than from a convention this script would have to re-derive.
attach_parent() {  # <child> <parent>
  local child=$1 parent=$2 child_id parent_id
  child_id=$(node_id_for "$child") || true
  parent_id=$(node_id_for "$parent") || true
  [ -n "$child_id" ] && [ -n "$parent_id" ] \
    || die "could not resolve #$child or #$parent for attachment"
  gh_api graphql -f "query=$FM_TRACKER_ADD_SUB_ISSUE" \
    -F "parentId=$parent_id" -F "subIssueId=$child_id" >/dev/null \
    || die "could not attach #$child under #$parent"
}

# ONE GraphQL query answers the whole frontier: ready, blocked, and what each
# blocked ticket waits on. trackedIssues is GitHub's own resolution of the
# task-list edges, so no body is ever re-parsed to find a blocker.
graph_json() {
  gh_api graphql --paginate -f "query=$FM_TRACKER_GRAPH_QUERY" \
    -F "owner=$OWNER" -F "repo=$REPO" --jq "$FM_TRACKER_GRAPH_JQ"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_init() {
  local dest='' body_file='' body num
  parse_repo "${1-}"; shift
  while [ "$#" -gt 0 ]; do
    case $1 in
      --destination) [ "$#" -gt 1 ] || usage_die "--destination requires a title"; dest=$2; shift 2 ;;
      --destination=*) dest=${1#--destination=}; shift ;;
      --body-file) [ "$#" -gt 1 ] || usage_die "--body-file requires a path"; body_file=$2; shift 2 ;;
      --body-file=*) body_file=${1#--body-file=}; shift ;;
      *) usage_die "unexpected argument '$1'" ;;
    esac
  done
  [ -n "$dest" ] || usage_die "init requires --destination <title>"
  if [ -n "$body_file" ]; then
    [ -f "$body_file" ] || die "no such body file: $body_file"
    body=$(cat "$body_file")
  else
    body=$(fm_tracker_destination_template)
  fi
  fm_tracker_body_prose_blocker_refuse "$body" || exit 1
  require_gh
  ensure_labels
  num=$(create_issue "$dest" "$body" destination) || exit 1
  printf 'created destination #%s in %s/%s\n' "$num" "$OWNER" "$REPO"
  printf 'labels ensured: %s\n' "$(fm_tracker_all_labels)"
}

cmd_add() {
  local type='' title='' body='' body_file='' parent='' blockers='' num
  parse_repo "${1-}"; shift
  while [ "$#" -gt 0 ]; do
    case $1 in
      --type) [ "$#" -gt 1 ] || usage_die "--type requires a value"; type=$2; shift 2 ;;
      --type=*) type=${1#--type=}; shift ;;
      --title) [ "$#" -gt 1 ] || usage_die "--title requires a value"; title=$2; shift 2 ;;
      --title=*) title=${1#--title=}; shift ;;
      --body) [ "$#" -gt 1 ] || usage_die "--body requires a value"; body=$2; shift 2 ;;
      --body=*) body=${1#--body=}; shift ;;
      --body-file) [ "$#" -gt 1 ] || usage_die "--body-file requires a path"; body_file=$2; shift 2 ;;
      --body-file=*) body_file=${1#--body-file=}; shift ;;
      --parent) [ "$#" -gt 1 ] || usage_die "--parent requires an issue number"; parent=$2; shift 2 ;;
      --parent=*) parent=${1#--parent=}; shift ;;
      --blocked-by) [ "$#" -gt 1 ] || usage_die "--blocked-by requires issue numbers"; blockers=$2; shift 2 ;;
      --blocked-by=*) blockers=${1#--blocked-by=}; shift ;;
      *) usage_die "unexpected argument '$1'" ;;
    esac
  done
  [ -n "$type" ] || usage_die "add requires --type <${FM_TRACKER_TYPES// /|}>"
  fm_tracker_type_valid "$type" \
    || usage_die "invalid --type '$type' (expected one of: ${FM_TRACKER_TYPES// /, })"
  [ -n "$title" ] || usage_die "add requires --title <title>"
  if [ -n "$body_file" ]; then
    [ -z "$body" ] || usage_die "pass --body or --body-file, not both"
    [ -f "$body_file" ] || die "no such body file: $body_file"
    body=$(cat "$body_file")
  fi
  if [ -n "$parent" ]; then
    fm_tracker_issue_number_valid "$parent" \
      || usage_die "invalid --parent '$parent' (expected a positive issue number)"
  fi
  if [ -n "$blockers" ]; then
    fm_tracker_blocker_csv_valid "$blockers" \
      || usage_die "invalid --blocked-by '$blockers' (expected comma-separated issue numbers)"
  fi

  # Refuse before any network call, so a rejected body never leaves a partly
  # created ticket behind.
  fm_tracker_body_prose_blocker_refuse "$body" || exit 1

  require_gh
  verify_blockers_exist "$blockers"
  if [ -n "$parent" ]; then
    gh_api "/repos/$OWNER/$REPO/issues/$parent" --jq .number >/dev/null 2>&1 \
      || die "parent #$parent does not exist in $OWNER/$REPO"
  fi

  ensure_labels
  num=$(create_issue "$title" "$(compose_body "$body" "$blockers")" "$type") || exit 1
  [ -z "$parent" ] || attach_parent "$num" "$parent"
  printf 'created #%s [%s] %s\n' "$num" "$(fm_tracker_type_label "$type")" "$title"
  [ -z "$parent" ] || printf '  attached under #%s\n' "$parent"
  if [ -n "$blockers" ]; then
    printf '  blocked by: %s\n' "$(printf '%s' "$blockers" | sed 's/[0-9][0-9]*/#&/g; s/,/ /g')"
  fi
}

cmd_frontier() {
  local json
  parse_repo "${1-}"; shift
  [ "$#" -eq 0 ] || usage_die "unexpected argument '$1'"
  require_gh
  json=$(graph_json) || die "could not read the issue graph for $OWNER/$REPO"
  printf '%s\n' "$json" | fm_tracker_render_frontier "$OWNER/$REPO"
}

cmd_validate() {
  local json
  parse_repo "${1-}"; shift
  [ "$#" -eq 0 ] || usage_die "unexpected argument '$1'"
  require_gh
  json=$(graph_json) || die "could not read the issue graph for $OWNER/$REPO"
  printf '%s\n' "$json" | fm_tracker_render_validate "$OWNER/$REPO"
}

cmd_claim() {
  local num me holder
  parse_repo "${1-}"; shift
  num=${1-}
  fm_tracker_issue_number_valid "$num" || usage_die "claim requires an issue number"
  shift
  [ "$#" -eq 0 ] || usage_die "unexpected argument '$1'"
  require_gh
  me=$(gh_api /user --jq .login) || die "could not resolve the authenticated GitHub login"
  holder=$(gh_api "/repos/$OWNER/$REPO/issues/$num" --jq '[.assignees[].login]|join(",")' 2>/dev/null) \
    || die "#$num does not exist in $OWNER/$REPO"
  # Assignment IS the claim, so an existing assignee is a lock another session
  # holds. Overwriting it would let two agents work the same ticket, which is
  # the exact failure the claim exists to prevent.
  if [ -n "$holder" ] && [ "$holder" != "$me" ]; then
    die "#$num is already claimed by $holder"
  fi
  gh_api -X POST "/repos/$OWNER/$REPO/issues/$num/assignees" -f "assignees[]=$me" >/dev/null \
    || die "could not claim #$num"
  printf 'claimed #%s as %s\n' "$num" "$me"
}

cmd_release() {
  local num me
  parse_repo "${1-}"; shift
  num=${1-}
  fm_tracker_issue_number_valid "$num" || usage_die "release requires an issue number"
  shift
  [ "$#" -eq 0 ] || usage_die "unexpected argument '$1'"
  require_gh
  me=$(gh_api /user --jq .login) || die "could not resolve the authenticated GitHub login"
  gh_api -X DELETE "/repos/$OWNER/$REPO/issues/$num/assignees" -f "assignees[]=$me" >/dev/null \
    || die "could not release #$num"
  printf 'released #%s\n' "$num"
}

cmd_answer() {
  local num='' decision='' settles='' not_settles='' labels comment json
  parse_repo "${1-}"; shift
  num=${1-}
  fm_tracker_issue_number_valid "$num" || usage_die "answer requires an issue number"
  shift
  while [ "$#" -gt 0 ]; do
    case $1 in
      --decision) [ "$#" -gt 1 ] || usage_die "--decision requires text"; decision=$2; shift 2 ;;
      --decision=*) decision=${1#--decision=}; shift ;;
      --settles) [ "$#" -gt 1 ] || usage_die "--settles requires text"; settles=$2; shift 2 ;;
      --settles=*) settles=${1#--settles=}; shift ;;
      --does-not-settle) [ "$#" -gt 1 ] || usage_die "--does-not-settle requires text"; not_settles=$2; shift 2 ;;
      --does-not-settle=*) not_settles=${1#--does-not-settle=}; shift ;;
      *) usage_die "unexpected argument '$1'" ;;
    esac
  done
  [ -n "$decision" ] || usage_die "answer requires --decision <text>"
  require_gh
  labels=$(gh_api "/repos/$OWNER/$REPO/issues/$num" --jq '[.labels[].name]|join(" ")' 2>/dev/null) \
    || die "#$num does not exist in $OWNER/$REPO"
  # An answer is meaningful only on a ticket typed as a question. Refusing here
  # keeps a decision record off a task, where nothing would read it.
  fm_tracker_labels_answerable "$labels" \
    || die "#$num is not a decision or unknown (labels: ${labels:-none}); only those can be answered"

  comment=$(fm_tracker_answer_comment "$decision" "$settles" "$not_settles")
  gh_api -X POST "/repos/$OWNER/$REPO/issues/$num/comments" -f "body=$comment" --jq .id >/dev/null \
    || die "could not record the decision on #$num"
  gh_api -X PATCH "/repos/$OWNER/$REPO/issues/$num" \
    -f state=closed -f state_reason=completed --jq .number >/dev/null \
    || die "could not close #$num"
  printf 'answered #%s: decision recorded and closed\n' "$num"

  if ! json=$(graph_json); then
    printf 'warning: could not re-read the graph to report what became unblocked\n' >&2
    return 0
  fi
  printf '%s\n' "$json" | fm_tracker_render_unblocked "$num"
}

# ---------------------------------------------------------------------------
# The notification-driven wake
# ---------------------------------------------------------------------------

cmd_watch() {
  local task='' spec device check data tmp
  local -a repos=()
  while [ "$#" -gt 0 ]; do
    case $1 in
      --task) [ "$#" -gt 1 ] || usage_die "--task requires a task id"; task=$2; shift 2 ;;
      --task=*) task=${1#--task=}; shift ;;
      -*) usage_die "unexpected option '$1'" ;;
      *) repos+=("$1"); shift ;;
    esac
  done
  [ -n "$task" ] || usage_die "watch requires --task <task-id>"
  fm_pr_task_id_valid "$task" || usage_die "invalid task id '$task'"
  [ "${#repos[@]}" -gt 0 ] || usage_die "watch requires at least one owner/repo"
  [ "${#repos[@]}" -le "$FM_TRACKER_MAX_WATCHED_REPOS" ] \
    || die "watch accepts at most $FM_TRACKER_MAX_WATCHED_REPOS repositories, so one poll stays inside FM_CHECK_TIMEOUT"
  for spec in "${repos[@]}"; do
    fm_tracker_repo_parse "$spec" || usage_die "invalid repository '$spec' (expected owner/repo)"
  done

  fm_tracker_state_root_valid "$STATE" \
    || die "state directory is unavailable: '${STATE}' is not an existing directory"

  # The poll is silent on every error by design, so a missing dependency would
  # be indistinguishable from an inbox where nothing happened. Arming is the one
  # point where that can be reported, so it is refused here instead.
  command -v "${FM_TRACKER_PYTHON:-python3}" >/dev/null 2>&1 \
    || die "watching GitHub issue comments requires python3 on PATH"
  [ -f "$SCRIPT_DIR/fm-tracker-parse.py" ] && [ ! -L "$SCRIPT_DIR/fm-tracker-parse.py" ] \
    || die "bin/fm-tracker-parse.py is missing; the wake cannot filter a response without it"
  fm_tracker_artifact_path "$STATE" "$task" .check.sh || die "could not resolve the check path"
  check=$FM_TRACKER_ARTIFACT
  fm_tracker_artifact_path "$STATE" "$task" .tracker-watch || die "could not resolve the sidecar path"
  data=$FM_TRACKER_ARTIFACT
  device=$(fm_pr_file_device "$STATE") || die "state directory is unavailable"

  # A check already armed at this path belongs to whoever armed it. Overwriting
  # a PR merge poll, or any other check, would silently disarm it, so this
  # refuses unless the file is absent or is already this task's own shim.
  if [ -e "$check" ] || [ -L "$check" ]; then
    fm_tracker_shim_matches "$check" "$FM_HOME" "$FM_ROOT" "$task" \
      || die "a different check is already armed at state/$task.check.sh; disarm its owner first"
  fi
  fm_pr_regular_destination_on_device_or_absent "$data" "$device" \
    || die "the watch sidecar path is unavailable"

  umask 077
  tmp=$(mktemp "$STATE/.fm-tracker-watch.XXXXXX") || die "could not stage the watch sidecar"
  { printf '%s\n' "$FM_TRACKER_WATCH_MAGIC"
    for spec in "${repos[@]}"; do printf '%s\n' "$spec"; done
  } > "$tmp" || die "could not write the watch sidecar"
  chmod 0600 "$tmp" || die "could not secure the watch sidecar"
  mv -f -- "$tmp" "$data" || die "could not publish the watch sidecar"

  tmp=$(mktemp "$STATE/.fm-tracker-check.XXXXXX") || die "could not stage the check"
  fm_tracker_shim_content "$FM_HOME" "$FM_ROOT" "$task" > "$tmp" || die "could not write the check"
  chmod 0700 "$tmp" || die "could not secure the check"
  mv -f -- "$tmp" "$check" || die "could not publish the check"

  "$SCRIPT_DIR/fm-check-register.sh" "$task" >/dev/null || die "could not register the check"
  printf 'watching:%s for %s\n' "$(printf ' %s' "${repos[@]}")" "$task"
  printf 'armed: state/%s.check.sh (registered)\n' "$task"
}

# Disarming removes files, so it asserts the facts that make them ours before it
# removes anything: a real state root, a path-safe task id, an armed tracker
# sidecar, and a check that is this task's own shim. An unarmed task, a foreign
# check, or an empty variable is refused rather than resolved into some path
# nobody named.
cmd_unwatch() {
  local task='' suffix check
  while [ "$#" -gt 0 ]; do
    case $1 in
      --task) [ "$#" -gt 1 ] || usage_die "--task requires a task id"; task=$2; shift 2 ;;
      --task=*) task=${1#--task=}; shift ;;
      *) usage_die "unexpected argument '$1'" ;;
    esac
  done
  [ -n "$task" ] || usage_die "unwatch requires --task <task-id>"
  fm_pr_task_id_valid "$task" || usage_die "invalid task id '$task'"
  fm_tracker_state_root_valid "$STATE" \
    || die "refusing to remove anything: '${STATE}' is not an existing state directory"
  fm_tracker_watch_armed "$STATE" "$task" \
    || die "refusing to remove anything: no tracker watch is armed for $task"

  fm_tracker_artifact_path "$STATE" "$task" .check.sh || die "could not resolve the check path"
  check=$FM_TRACKER_ARTIFACT
  if [ -e "$check" ] || [ -L "$check" ]; then
    fm_tracker_shim_matches "$check" "$FM_HOME" "$FM_ROOT" "$task" \
      || die "refusing to remove state/$task.check.sh: it is not this watch's own shim"
  fi

  for suffix in .check.sh .check-trust .tracker-watch .tracker-cursor; do
    fm_tracker_remove_artifact "$STATE" "$task" "$suffix" \
      || die "refusing to remove state/$task$suffix: it is not a plain file this watch published"
  done
  printf 'unwatched %s\n' "$task"
}

[ "$#" -gt 0 ] || usage_die "a command is required"
CMD=$1
shift
case $CMD in
  -h|--help|help) print_help ;;
  init) cmd_init "$@" ;;
  add) cmd_add "$@" ;;
  frontier) cmd_frontier "$@" ;;
  claim) cmd_claim "$@" ;;
  release) cmd_release "$@" ;;
  answer) cmd_answer "$@" ;;
  validate) cmd_validate "$@" ;;
  watch) cmd_watch "$@" ;;
  unwatch) cmd_unwatch "$@" ;;
  *) usage_die "unknown command '$CMD'" ;;
esac
