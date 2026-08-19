#!/usr/bin/env bash
# fm-pr-delivery.sh - bounded main-home PR delivery discovery and classification.
#
# Usage:
#   fm-pr-delivery.sh scan [--startup]
#   fm-pr-delivery.sh show
#   fm-pr-delivery.sh accelerate <pr-url>
#
# Adjunct to the watcher poll loop and locked session start, not a watcher or
# PR poll of its own. `scan` evaluates at most once per FM_PR_DELIVERY_SECS
# (default 300, valid 60..1800) per home, except --startup performs the same
# cheap scan immediately during a locked session start. Each scan uses an
# aggregate FM_PR_DELIVERY_BUDGET_SECS deadline (default 15, valid 1..30) and
# resumes after its last visited repository on the next scan.
#
# Enumerates open PRs for every merge-capable registered project independently
# of secondmate status, classifies each head with live gh evidence, maintains a
# reason-coded blocked queue, and prints ONE actionable stdout line when a
# merge-eligible PR needs firstmate action or a newly merged PR needs post-merge
# routing. Never invokes fm-pr-poll or executes state *.check.sh.
#
# Main home only; secondmate homes refuse scan/show/accelerate.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
DELIVERY_DIR="$STATE/pr-delivery"
QUEUE_FILE="$DELIVERY_DIR/blocked-queue.tsv"
SCAN_MARKER="$DELIVERY_DIR/.scan-marker"
SCAN_LOCK="$STATE/.pr-delivery-scan.lock"
FINGERPRINT_DIR="$DELIVERY_DIR/fingerprints"
DELIVERED_DIR="$DELIVERY_DIR/delivered"
ACCELERATE_DIR="$DELIVERY_DIR/accelerate"
MERGED_DIR="$DELIVERY_DIR/merged"
GH_BIN="${GH_BIN:-gh}"
PROJECT_MODE_BIN="${FM_PROJECT_MODE_BIN:-$SCRIPT_DIR/fm-project-mode.sh}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

FM_PR_DELIVERY_SECS=${FM_PR_DELIVERY_SECS:-300}
case "$FM_PR_DELIVERY_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-pr-delivery: FM_PR_DELIVERY_SECS must be a whole number from 60 to 1800\n' >&2
    exit 2
    ;;
esac
if [ "$FM_PR_DELIVERY_SECS" -lt 60 ] || [ "$FM_PR_DELIVERY_SECS" -gt 1800 ]; then
  printf 'fm-pr-delivery: FM_PR_DELIVERY_SECS must be a whole number from 60 to 1800\n' >&2
  exit 2
fi
FM_PR_DELIVERY_BUDGET_SECS=${FM_PR_DELIVERY_BUDGET_SECS:-15}
case "$FM_PR_DELIVERY_BUDGET_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-pr-delivery: FM_PR_DELIVERY_BUDGET_SECS must be a whole number from 1 to 30\n' >&2
    exit 2
    ;;
esac
if [ "$FM_PR_DELIVERY_BUDGET_SECS" -gt 30 ]; then
  printf 'fm-pr-delivery: FM_PR_DELIVERY_BUDGET_SECS must be a whole number from 1 to 30\n' >&2
  exit 2
fi

if [ "$(uname)" = Darwin ]; then
  file_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

delivery_now() {
  case "${FM_PR_DELIVERY_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_PR_DELIVERY_NOW" ;;
  esac
}

clean_field() {
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-800
}

valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 32)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1, 1, 32)}'
  else
    printf '%s' "$1" | cksum | awk '{printf "%08x%08x", $1, $2}'
  fi
}

repo_slug() {
  printf '%s' "$1" | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)#\1#p' | sed 's#\.git$##; s#/pull/.*$##; s#/$##'
}

home_secondmate_id() {
  local marker="$FM_HOME/.fm-secondmate-home" id
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 1
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  id=$(cat "$marker" 2>/dev/null) || return 2
  valid_id "$id" || return 2
  printf '%s\n' "$id"
}

refuse_secondmate() {
  local rc=0
  home_secondmate_id >/dev/null 2>&1 || rc=$?
  case "$rc" in
    1) return 0 ;;
    0)
      printf 'fm-pr-delivery: main home only\n' >&2
      return 1
      ;;
    *)
      printf 'fm-pr-delivery: invalid .fm-secondmate-home marker\n' >&2
      return 2
      ;;
  esac
}

ensure_dirs() {
  mkdir -p "$DELIVERY_DIR" "$FINGERPRINT_DIR" "$DELIVERED_DIR" "$ACCELERATE_DIR" "$MERGED_DIR" || return 1
  [ ! -L "$DELIVERY_DIR" ] || return 1
}

scan_marker_age() {
  local now m
  [ -e "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || { printf '999999\n'; return; }
  now=$(delivery_now)
  m=$(file_mtime "$SCAN_MARKER" 2>/dev/null || true)
  case "$m" in ''|*[!0-9]*) printf '999999\n'; return ;; esac
  if [ "$now" -lt "$m" ]; then printf '0\n'; else printf '%s\n' $((now - m)); fi
}

scan_marker_cursor() {
  [ -f "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || return 0
  grep '^cursor=' "$SCAN_MARKER" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

write_scan_marker() { # <cursor>
  local cursor=$1 marker_tmp
  marker_tmp=$(mktemp "$DELIVERY_DIR/.scan-marker.XXXXXX") || return 1
  {
    printf 'epoch=%s\n' "$(delivery_now)"
    printf 'cursor=%s\n' "$cursor"
  } > "$marker_tmp" || { rm -f "$marker_tmp"; return 1; }
  chmod 600 "$marker_tmp" 2>/dev/null || true
  mv -f "$marker_tmp" "$SCAN_MARKER" || { rm -f "$marker_tmp"; return 1; }
}

meta_field() {
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

list_merge_capable_projects() {
  local reg="$DATA/projects.md" line name mode
  [ -f "$reg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      -*)
        name=$(printf '%s' "$line" | awk '{print $2}')
        [ -n "$name" ] || continue
        mode=$("$PROJECT_MODE_BIN" "$name" 2>/dev/null | awk '{print $1}') || mode=no-mistakes
        [ "$mode" != local-only ] || continue
        printf '%s\n' "$name"
        ;;
    esac
  done < "$reg"
}

project_repo_slug() { # <project>
  local project=$1 clone url
  clone="$PROJECTS/$project"
  [ -d "$clone" ] || return 1
  url=$(git -C "$clone" remote get-url origin 2>/dev/null) || return 1
  repo_slug "$url"
}

build_task_index() {
  local meta id pr project yolo
  TASK_BY_PR=''
  TASK_PROJECT=''
  TASK_YOLO=''
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_id "$id" || continue
    [ "$(meta_field "$meta" kind)" = secondmate ] && continue
    yolo=$(meta_field "$meta" yolo)
    pr=$(meta_field "$meta" pr)
    project=$(meta_field "$meta" project)
    if [ -n "$pr" ]; then
      TASK_BY_PR="${TASK_BY_PR}${pr}"$'\t'"$id"$'\n'
    fi
    TASK_PROJECT="${TASK_PROJECT}${id}"$'\t'"$project"$'\n'
    TASK_YOLO="${TASK_YOLO}${id}=${yolo:-off}"$'\n'
  done
}

task_matches_project() { # <task-id> <project>
  local task=$1 project=$2 line task_project project_path task_project_path
  while IFS= read -r line; do
    case "$line" in
      "$task"$'\t'*) task_project=${line#*$'\t'} ;;
      *) continue ;;
    esac
    [ "$task_project" = "$project" ] && return 0
    project_path=$(cd "$PROJECTS/$project" 2>/dev/null && pwd -P) || continue
    task_project_path=$(cd "$task_project" 2>/dev/null && pwd -P) || continue
    [ "$task_project_path" = "$project_path" ] && return 0
  done <<EOF
${TASK_PROJECT:-}
EOF
  return 1
}

task_for_head() { # <headRefName> <project>
  local head=$1 project=$2 id
  case "$head" in
    fm/*)
      id=${head#fm/}
      valid_id "$id" && task_matches_project "$id" "$project" \
        && { printf '%s\n' "$id"; return 0; }
      ;;
  esac
  return 1
}

task_for_pr_url() { # <url> <project>
  local url=$1 project=$2 line task
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$url"$'\t'*)
        task=${line#*$'\t'}
        if task_matches_project "$task" "$project"; then
          printf '%s\n' "$task"
          return 0
        fi
        ;;
    esac
  done <<EOF
${TASK_BY_PR:-}
EOF
  return 1
}

match_task() { # <headRefName> <url> <project>
  local head=$1 url=$2 project=$3 task
  if task=$(task_for_head "$head" "$project"); then
    printf '%s\n' "$task"
    return 0
  fi
  if task=$(task_for_pr_url "$url" "$project"); then
    printf '%s\n' "$task"
    return 0
  fi
  return 1
}

task_yolo() { # <task-id>
  local task=$1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$task="*) printf '%s\n' "${line#*=}"; return 0 ;;
    esac
  done <<EOF
${TASK_YOLO:-}
EOF
  printf 'off\n'
}

task_hold_reason() { # <task-id>
  local task=$1 status yolo open line verb key note lower
  status="$STATE/$task.status"
  [ -f "$status" ] || return 1
  yolo=$(task_yolo "$task")
  open=$(status_open_decisions "$status" 2>/dev/null || true)
  if [ -z "$open" ]; then
    return 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    verb=${line#*$'\t'}; verb=${verb%%$'\t'*}
    key=${line%%$'\t'*}
    note=${line#*$'\t'}; note=${note#*$'\t'}
    lower=$(printf '%s %s %s' "$key" "$note" "$verb" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      *destructive*) printf 'destructive-hold\t%s\n' "$(clean_field "$note")"; return 0 ;;
      *real-contact*|*real_contact*) printf 'real-contact-hold\t%s\n' "$(clean_field "$note")"; return 0 ;;
      *migration-gate*|*migration*)
        printf 'migration-hold\t%s\n' "$(clean_field "$note")"
        return 0
        ;;
    esac
    if [ "$verb" = needs-decision ] && [ "$yolo" != on ]; then
      printf 'authority-hold\t%s\n' "$(clean_field "$note")"
      return 0
    fi
    if [ "$verb" = blocked ]; then
      case "$lower" in
        *migration*) printf 'migration-hold\t%s\n' "$(clean_field "$note")"; return 0 ;;
      esac
    fi
  done <<EOF
$open
EOF
  return 1
}

classify_pr_json() { # <repo> <pr-json-object>
  local repo=$1 pr_json=$2
  printf '%s' "$pr_json" | jq -r --arg repo "$repo" '
    def unresolved_threads:
      ((.reviewThreads.nodes // []) | map(select(.isResolved == false)) | length);
    {
      repo: $repo,
      number: (.number | tostring),
      url: (.url // "-"),
      head: (.headRefOid // ""),
      base: (.baseRefName // ""),
      review: (.reviewDecision // "none"),
      mergeable: (.mergeable // "UNKNOWN"),
      checks: (
        (.statusCheckRollup // []) as $c
        | if ($c | length) == 0 then "none"
          elif any($c[]; ((.conclusion // .state // "") | ascii_upcase) as $s
            | ($s == "FAILURE" or $s == "ERROR" or $s == "TIMED_OUT" or $s == "CANCELLED" or $s == "ACTION_REQUIRED")) then "failing"
          elif any($c[]; ((.status // "") != "COMPLETED") and ((.state // "") != "SUCCESS")) then "pending"
          else "passing" end),
      unresolved: unresolved_threads
    }'
}

reason_for_pr() { # <classified-json> <task-id-or-empty> -> reason_code reason_detail
  local classified=$1 task=${2:-}
  local checks review mergeable unresolved hold
  checks=$(printf '%s' "$classified" | jq -r '.checks')
  review=$(printf '%s' "$classified" | jq -r '.review')
  mergeable=$(printf '%s' "$classified" | jq -r '.mergeable')
  unresolved=$(printf '%s' "$classified" | jq -r '.unresolved')
  case "$checks" in
    pending) REASON_CODE=checks-pending; REASON_DETAIL='checks still running'; return 0 ;;
    failing) REASON_CODE=checks-failing; REASON_DETAIL='one or more checks failed'; return 0 ;;
  esac
  if [ "$mergeable" != MERGEABLE ]; then
    REASON_CODE=not-mergeable
    REASON_DETAIL="merge state is $mergeable"
    return 0
  fi
  if [ "$review" = CHANGES_REQUESTED ] || [ "$unresolved" -gt 0 ]; then
    REASON_CODE=review-issue
    REASON_DETAIL='review changes or unresolved threads'
    return 0
  fi
  if [ -z "$task" ]; then
    REASON_CODE=no-task
    REASON_DETAIL='no fm/<id> branch or pr= meta match'
    return 0
  fi
  if hold=$(task_hold_reason "$task"); then
    REASON_CODE=${hold%%$'\t'*}
    REASON_DETAIL=${hold#*$'\t'}
    return 0
  fi
  REASON_CODE=eligible
  REASON_DETAIL='ready under authority'
}

fingerprint_for() { # <classified-json> <task> <reason-code>
  local classified=$1 task=${2:-} reason=$3
  sha256_text "$(printf '%s' "$classified" | jq -c '.')|task=${task:-}|reason=$reason"
}

repo_state_key() { # <repo>
  sha256_text "$1"
}

fingerprint_path() { # <repo> <number>
  printf '%s/%s-%s.fp\n' "$FINGERPRINT_DIR" "$(repo_state_key "$1")" "$2"
}

delivered_path() { # <repo> <number>
  printf '%s/%s-%s.delivered\n' "$DELIVERED_DIR" "$(repo_state_key "$1")" "$2"
}

accelerate_path() { # <url>
  local url=$1
  printf '%s/%s.marker\n' "$ACCELERATE_DIR" "$(sha256_text "$url")"
}

merged_notice_path() { # <repo> <number>
  printf '%s/%s-%s.noticed\n' "$MERGED_DIR" "$(repo_state_key "$1")" "$2"
}

read_fingerprint() { # <path>
  local path=$1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  head -1 "$path" 2>/dev/null
}

write_fingerprint() { # <path> <value>
  local path=$1 value=$2 tmp
  tmp=$(mktemp "${path%/*}/.state.XXXXXX") || return 1
  printf '%s\n' "$value" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$path"
}

gh_fetch_open_prs() { # <repo>
  local repo=$1
  fm_run_timed 10 env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    "$GH_BIN" pr list --repo "$repo" --state open --limit 50 \
    --json number,url,headRefName,headRefOid,baseRefName,reviewDecision,mergeable,statusCheckRollup 2>/dev/null
}

gh_fetch_pr_view() { # <repo> <number>
  local repo=$1 number=$2 snapshot attempt=0
  while [ "$attempt" -lt 2 ]; do
    snapshot=$(gh_fetch_pr_snapshot "$repo" "$number") || {
      attempt=$((attempt + 1))
      continue
    }
    if [ -n "$snapshot" ]; then
      printf '%s\n' "$snapshot"
      return 0
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

gh_fetch_pr_snapshot() { # <repo> <number>
  local repo=$1 number=$2 owner name pages
  owner=${repo%%/*}
  name=${repo#*/}
  [ -n "$owner" ] && [ -n "$name" ] && [ "$owner" != "$name" ] || return 1
  pages=$(fm_run_timed 10 env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    "$GH_BIN" api graphql --paginate \
    -f owner="$owner" -f name="$name" -F number="$number" \
    -f query='query($owner: String!, $name: String!, $number: Int!, $endCursor: String) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { number url headRefName headRefOid baseRefName reviewDecision mergeable state commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes { ... on CheckRun { conclusion status } ... on StatusContext { state } } } } } } } reviewThreads(first: 100, after: $endCursor) { nodes { isResolved } pageInfo { hasNextPage endCursor } } } } }' \
    2>/dev/null) || return 1
  printf '%s\n' "$pages" | jq -sec '
    def evidence:
      .data.repository.pullRequest
      | {
          number, url, headRefName, headRefOid, baseRefName, reviewDecision,
          mergeable, state,
          statusCheckRollup: [
            (.commits.nodes[-1].commit.statusCheckRollup.contexts.nodes[]? | {
              conclusion, status, state
            })
          ]
        };
    [ .[] | evidence ] as $evidence
    | ($evidence[0]) as $first
    | select(($first.headRefOid // "") != "")
    | select(($evidence | all(. == $first)))
    | $first + {
        reviewThreads: {
          nodes: [.[].data.repository.pullRequest.reviewThreads.nodes[]?]
        }
      }'
}

gh_fetch_merged_state() { # <repo> <number>
  local repo=$1 number=$2
  fm_run_timed 10 env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    "$GH_BIN" pr view "$number" --repo "$repo" --json state,mergedAt 2>/dev/null
}

QUEUE_ROWS=''

queue_add_row() { # <repo> <num> <url> <task> <reason> <detail>
  local row
  row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(clean_field "$1")" "$(clean_field "$2")" "$(clean_field "$3")" \
    "$(clean_field "$4")" "$(clean_field "$5")" "$(clean_field "$6")")
  case "$QUEUE_ROWS" in
    *"$row"*) ;;
    *) QUEUE_ROWS="${QUEUE_ROWS}${row}" ;;
  esac
}

write_blocked_queue() {
  local tmp
  tmp=$(mktemp "$DELIVERY_DIR/.blocked-queue.XXXXXX") || return 1
  {
    printf 'repo\tpr#\turl\ttask_id\treason_code\treason_detail\n'
    printf '%s' "$QUEUE_ROWS"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$QUEUE_FILE"
}

process_pr_record() { # <repo> <project> <pr-json> <deadline> -> sets ACTIONABLE
  local repo=$1 project=$2 pr_json=$3 deadline=$4
  local classified num url head task fp_path delivered marker_fp new_fp accel_path
  [ "$(date +%s)" -lt "$deadline" ] || return 3
  classified=$(classify_pr_json "$repo" "$pr_json") || return 0
  num=$(printf '%s' "$classified" | jq -r '.number')
  url=$(printf '%s' "$classified" | jq -r '.url')
  head=$(printf '%s' "$classified" | jq -r '.head')
  task=$(match_task "$(printf '%s' "$pr_json" | jq -r '.headRefName // ""')" "$url" "$project" 2>/dev/null || true)
  reason_for_pr "$classified" "$task"
  queue_add_row "$repo" "$num" "$url" "${task:--}" "$REASON_CODE" "$REASON_DETAIL"
  new_fp=$(fingerprint_for "$classified" "$task" "$REASON_CODE")
  fp_path=$(fingerprint_path "$repo" "$num")
  write_fingerprint "$fp_path" "$new_fp" || return 1
  delivered=$(delivered_path "$repo" "$num")
  marker_fp=$(read_fingerprint "$delivered" 2>/dev/null || true)
  accel_path=$(accelerate_path "$url")
  if [ "$REASON_CODE" = eligible ]; then
    if [ "$new_fp" != "$marker_fp" ] || [ -f "$accel_path" ]; then
      ACTIONABLE="merge-eligible: project=$project repo=$repo pr=$num task=${task:-} url=$url head=$head"
      PENDING_DELIVERED_PATH=$delivered
      PENDING_DELIVERED_VALUE=$new_fp
      PENDING_ACCEL_PATH=$accel_path
    fi
  else
    rm -f "$delivered" || return 1
  fi
  OPEN_PR_NUMS="${OPEN_PR_NUMS} ${num}"
  return 0
}

retire_pr_state() { # <repo> <number> <url>
  rm -f -- \
    "$(fingerprint_path "$1" "$2")" \
    "$(delivered_path "$1" "$2")" \
    "$(accelerate_path "$3")"
}

check_post_merge() { # <repo> <project> <number> <url> <task>
  local repo=$1 project=$2 number=$3 url=$4 task=$5
  local notice state_json state notice_path
  notice_path=$(merged_notice_path "$repo" "$number")
  if [ -f "$notice_path" ]; then
    retire_pr_state "$repo" "$number" "$url"
    return $?
  fi
  state_json=$(gh_fetch_merged_state "$repo" "$number") || return 0
  state=$(printf '%s' "$state_json" | jq -r '.state // empty' 2>/dev/null)
  case "$state" in
    MERGED)
      ACTIONABLE="post-merge: project=$project repo=$repo pr=$number task=${task:-} url=$url"
      PENDING_NOTICE_PATH=$notice_path
      PENDING_RETIRE_REPO=$repo
      PENDING_RETIRE_NUMBER=$number
      PENDING_RETIRE_URL=$url
      ;;
    CLOSED)
      retire_pr_state "$repo" "$number" "$url"
      ;;
  esac
}

write_merged_notice() { # <path>
  local path=$1 tmp
  tmp=$(mktemp "$MERGED_DIR/.noticed.XXXXXX") || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$path"
}

commit_actionable_state() {
  if [ -n "${PENDING_DELIVERED_PATH:-}" ]; then
    write_fingerprint "$PENDING_DELIVERED_PATH" "$PENDING_DELIVERED_VALUE" || return 1
    rm -f "$PENDING_ACCEL_PATH" || return 1
  fi
  if [ -n "${PENDING_NOTICE_PATH:-}" ]; then
    write_merged_notice "$PENDING_NOTICE_PATH" || return 1
    retire_pr_state "$PENDING_RETIRE_REPO" "$PENDING_RETIRE_NUMBER" "$PENDING_RETIRE_URL" || return 1
  fi
}

scan_repo() { # <project> <repo> <deadline>
  local project=$1 repo=$2 deadline=$3 safe num fp url task
  local list_json pr_json
  OPEN_PR_NUMS=
  list_json=$(gh_fetch_open_prs "$repo") || return 0
  [ -n "$list_json" ] || list_json='[]'
  while IFS= read -r num; do
    [ -n "$num" ] || continue
    [ "$(date +%s)" -lt "$deadline" ] || return 3
    pr_json=$(gh_fetch_pr_view "$repo" "$num") || continue
    process_pr_record "$repo" "$project" "$pr_json" "$deadline" || {
      case "$?" in
        3) return 3 ;;
        *) return 1 ;;
      esac
    }
    [ -z "${ACTIONABLE:-}" ] || return 0
  done < <(printf '%s' "$list_json" | jq -r '.[].number | tostring')
  safe=$(repo_state_key "$repo")
  for fp in "$FINGERPRINT_DIR"/"$safe"-*.fp; do
    [ -e "$fp" ] || continue
    [ "$(date +%s)" -lt "$deadline" ] || return 3
    num=${fp##*/}; num=${num#"$safe"-}; num=${num%.fp}
    case " ${OPEN_PR_NUMS:-} " in
      *" $num "*) continue ;;
    esac
    url="https://github.com/$repo/pull/$num"
    task=$(task_for_pr_url "$url" "$project" 2>/dev/null || true)
    check_post_merge "$repo" "$project" "$num" "$url" "$task" || return 1
    [ -z "${ACTIONABLE:-}" ] || return 0
  done
  return 0
}

scan_pass() { # <cursor> <after|through> <deadline>
  local cursor=$1 range=$2 deadline=$3 project repo repos='' started=0 repo_rc
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    repo=$(project_repo_slug "$project") || continue
    repos="${repos}${project}"$'\t'"${repo}"$'\n'
  done < <(list_merge_capable_projects)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    project=${line%%$'\t'*}
    repo=${line#*$'\t'}
    case "$range" in
      after)
        if [ -z "$cursor" ]; then
          :
        elif [ "$started" -eq 0 ]; then
          [ "$project" = "$cursor" ] && started=1
          continue
        fi
        ;;
      through)
        :
        ;;
    esac
    repo_rc=0
    scan_repo "$project" "$repo" "$deadline" || repo_rc=$?
    case "$repo_rc" in
      0) ;;
      3) return 3 ;;
      *) return 1 ;;
    esac
    [ -z "${ACTIONABLE:-}" ] || return 0
    write_scan_marker "$project" || return 1
    if [ "$range" = through ] && [ -n "$cursor" ] && [ "$project" = "$cursor" ]; then
      return 0
    fi
  done <<EOF
$repos
EOF
}

scan() {
  local startup=${1:-0} cursor rc=0
  ACTIONABLE=
  PENDING_DELIVERED_PATH=
  PENDING_DELIVERED_VALUE=
  PENDING_ACCEL_PATH=
  PENDING_NOTICE_PATH=
  PENDING_RETIRE_REPO=
  PENDING_RETIRE_NUMBER=
  PENDING_RETIRE_URL=
  QUEUE_ROWS=
  command -v jq >/dev/null 2>&1 || { printf 'fm-pr-delivery: jq not found\n' >&2; return 1; }
  command -v "$GH_BIN" >/dev/null 2>&1 || return 0
  refuse_secondmate || return $?
  ensure_dirs || return 1
  build_task_index
  if [ "$startup" != 1 ] && [ "$(scan_marker_age)" -lt "$FM_PR_DELIVERY_SECS" ]; then
    accelerated=0
    for _accel in "$ACCELERATE_DIR"/*; do
      [ -f "$_accel" ] || continue
      accelerated=1
      break
    done
    [ "$accelerated" -eq 0 ] && return 0
  fi
  cursor=$(scan_marker_cursor)
  write_scan_marker "$cursor" || return 1
  deadline=$(( $(date +%s) + FM_PR_DELIVERY_BUDGET_SECS ))
  scan_pass "$cursor" after "$deadline" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$cursor" ]; then
    scan_pass "$cursor" through "$deadline" || rc=$?
  fi
  write_blocked_queue || return 1
  if [ "$rc" -eq 0 ]; then
    write_scan_marker '' || return 1
  elif [ "$rc" -ne 3 ]; then
    return "$rc"
  fi
  if [ -n "${ACTIONABLE:-}" ]; then
    fm_wake_append check pr-delivery "$ACTIONABLE" || return 1
    commit_actionable_state || return 1
    printf '%s\n' "$ACTIONABLE"
  fi
}

show() {
  refuse_secondmate || return $?
  if [ -f "$QUEUE_FILE" ] && [ ! -L "$QUEUE_FILE" ]; then
    cat "$QUEUE_FILE"
    return 0
  fi
  printf 'repo\tpr#\turl\ttask_id\treason_code\treason_detail\n'
}

accelerate() { # <url>
  local url=$1
  refuse_secondmate || return $?
  fm_pr_url_parse "$url" || {
    printf 'fm-pr-delivery: invalid PR URL\n' >&2
    return 2
  }
  ensure_dirs || return 1
  : > "$(accelerate_path "$url")"
}

mode=${1:-scan}
case "$mode" in
  scan)
    startup=0
    case "${2:-}" in
      '') ;;
      --startup) startup=1 ;;
      *) printf 'usage: fm-pr-delivery.sh scan [--startup]\n' >&2; exit 2 ;;
    esac
    if fm_run_timed $((FM_PR_DELIVERY_BUDGET_SECS + 1)) "$0" _scan-locked "$startup"; then
      :
    elif [ "$?" -ne 124 ]; then
      exit 1
    fi
    ;;
  _scan-locked)
    [ "$#" -eq 2 ] || exit 2
    fm_lock_acquire_wait "$SCAN_LOCK" || exit 1
    trap 'fm_lock_release "$SCAN_LOCK"' EXIT
    scan "$2" || exit $?
    ;;
  show)
    show
    ;;
  accelerate)
    [ "$#" -eq 2 ] || { printf 'usage: fm-pr-delivery.sh accelerate <pr-url>\n' >&2; exit 2; }
    accelerate "$2"
    ;;
  -h|--help)
    sed -n '2,25{s/^# \{0,1\}//;p;}' "$0"
    ;;
  *)
    printf 'usage: fm-pr-delivery.sh scan [--startup]\n' >&2
    printf '       fm-pr-delivery.sh show\n' >&2
    printf '       fm-pr-delivery.sh accelerate <pr-url>\n' >&2
    exit 2
    ;;
esac
