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
# merge-eligible PR needs firstmate action. Never invokes fm-pr-poll or executes
# state *.check.sh.
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
PR_CURSOR_DIR="$DELIVERY_DIR/pr-cursors"
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

ensure_dir() {
  local dir=$1
  [ ! -L "$dir" ] || return 1
  if [ ! -e "$dir" ]; then
    mkdir "$dir" || return 1
  fi
  [ -d "$dir" ] && [ ! -L "$dir" ]
}

ensure_dirs() {
  ensure_dir "$DELIVERY_DIR" || return 1
  ensure_dir "$FINGERPRINT_DIR" || return 1
  ensure_dir "$DELIVERED_DIR" || return 1
  ensure_dir "$ACCELERATE_DIR" || return 1
  ensure_dir "$PR_CURSOR_DIR"
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
  local meta id pr project
  TASK_BY_PR=''
  TASK_PROJECT=''
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_id "$id" || continue
    [ "$(meta_field "$meta" kind)" = secondmate ] && continue
    pr=$(meta_field "$meta" pr)
    project=$(meta_field "$meta" project)
    if [ -n "$pr" ]; then
      TASK_BY_PR="${TASK_BY_PR}${pr}"$'\t'"$id"$'\n'
    fi
    TASK_PROJECT="${TASK_PROJECT}${id}"$'\t'"$project"$'\n'
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

task_for_pr_url() { # <url> <project>
  local url=$1 project=$2 line task found=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$url"$'\t'*)
        task=${line#*$'\t'}
        if task_matches_project "$task" "$project"; then
          [ -z "$found" ] || return 2
          found=$task
        fi
        ;;
    esac
  done <<EOF
${TASK_BY_PR:-}
EOF
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

match_task() { # <url> <project>
  local url=$1 project=$2 task
  task=$(task_for_pr_url "$url" "$project") || return $?
  printf '%s\n' "$task"
}

task_hold_reason() { # <task-id>
  local task=$1 status open line verb key note lower
  status="$STATE/$task.status"
  [ -f "$status" ] || return 1
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
    if [ "$verb" = needs-decision ]; then
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
    def text:
      ((.body // "") | gsub("^\\s+|\\s+$"; "") | ascii_downcase);
    def resolution_comment:
      text | test("^(resolved|fixed|addressed|this is now resolved|the concern has been addressed)([.![:space:]]|$)");
    def work_action:
      "(fix|fixing|update|updating|change|changing|revise|revising|address|addressing|rework|reworking|re-review|rereview|add|adding|remove|removing|test|testing|cover|covering|validate|validating|use|using|refactor|refactoring|implement|implementing|replace|replacing|move|moving|rename|renaming|extract|extracting|simplify|simplifying|split|splitting|combine|combining|document|documenting|handle|handling|guard|guarding|check|checking|assert|asserting|wire|wiring|configure|configuring|helper|function|method|class|module|api|schema|query)";
    def imperative_work_action:
      "(fix|update|change|revise|address|rework|re-review|rereview|add|remove|test|cover|validate|use|refactor|implement|replace|move|rename|extract|simplify|split|combine|document|handle|guard|check|assert|wire|configure)";
    def neutral_feedback:
      text | test("(^|[[:space:]])(looks?|seems?|feels?|sounds?)[[:space:]]+(good|great|fine|ready|correct|ok)([.![:space:]]|$)");
    def change_request:
      text as $text
      | ($text | test("(^|[^[:alnum:]])(please|must|should|need|needs|required|require|could you|can you|would you|can we|could we|kindly)([[:space:]]+[^[:space:]]+){0,3}[[:space:]]+" + work_action + "([^[:alnum:]]|$)"))
        or ($text | test("(^|[.?!][[:space:]]+)(could|can|would)([[:space:]]+[^[:space:]?!.]+){0,6}[[:space:]]+" + work_action + "([^[:alnum:]]|$)"))
        or ($text | test("(^|[.?!][[:space:]]+)(could|can|would)[[:space:]]+(you|we|this|that|it)[[:space:]]+(make|keep|turn|render)[[:space:]]+(this|that|it|the[[:space:]]+[^[:space:]?!.]+)[[:space:]]+(simpler|clearer|safer|faster|smaller|cleaner)([?!.]|$)"))
        or ($text | test("(^|[.?!][[:space:]]+)(consider|suggest|recommend)([[:space:]]+[^[:space:]?!.]+){0,3}[[:space:]]+" + work_action + "([^[:alnum:]]|$)"))
        or (($text | test("^" + imperative_work_action + "[[:space:]]+")) and (neutral_feedback | not))
        or ($text | test("(^|[^[:alnum:]])(changes?|updates?|fixes?|re-?review)([[:space:]]+(are|is|were|be))?[[:space:]]+(needed|required|requested)([^[:alnum:]]|$)"));
    def reviewer_request:
      (.state == "CHANGES_REQUESTED")
      or (.state == "COMMENTED" and change_request);
    def review_requests:
      (.reviews // []) as $reviews
      | (.comments // []) as $comments
      | [$reviews[]? | .author] | unique as $authors
      | [
          $authors[] as $author
          | ($reviews | map(select(.author == $author)) | sort_by(.submittedAt // "")) as $history
          | ($history | map(select(reviewer_request)) | last) as $request
          | select($request != null)
          | select(([
              ($history[] | select((.state == "APPROVED" or resolution_comment) and ((.submittedAt // "") > ($request.submittedAt // "")))),
              ($comments[]? | select(.author == $author and resolution_comment and ((.createdAt // "") > ($request.submittedAt // ""))))
            ] | length) == 0)
        ] | length;
    def comment_request:
      change_request;
    def conversation_requests:
      .prAuthor as $pr_author
      | (.reviews // []) as $reviews
      | (.comments // []) as $comments
      | [$comments[]? | select(.author != "" and .author != $pr_author) | .author] | unique as $authors
      | [
          $authors[] as $author
          | ($comments | map(select(.author == $author)) | sort_by(.createdAt // "")) as $history
          | ($history | map(select(comment_request)) | last) as $request
          | select($request != null)
          | select(([$history[] | select(resolution_comment and ((.createdAt // "") > ($request.createdAt // "")))] | length) == 0)
          | select(([$reviews[] | select(.author == $author and .state == "APPROVED" and ((.submittedAt // "") > ($request.createdAt // "")))] | length) == 0)
        ] | length;
    def check_pending:
      ((.status // "") | ascii_upcase) as $status
      | ((.state // "") | ascii_upcase) as $state
      | (($status != "" and $status != "COMPLETED")
        or ($status == "" and ($state == "PENDING" or $state == "EXPECTED")));
    def check_green:
      ((.conclusion // "") | ascii_upcase) as $conclusion
      | ((.state // "") | ascii_upcase) as $state
      | ($conclusion == "SUCCESS" or $conclusion == "NEUTRAL" or $conclusion == "SKIPPED"
        or ($conclusion == "" and $state == "SUCCESS"));
    {
      repo: $repo,
      prAuthor: (.prAuthor // ""),
      state: (.state // "UNKNOWN"),
      number: (.number | tostring),
      url: (.url // "-"),
      head: (.headRefOid // ""),
      base: (.baseRefName // ""),
      review: (.reviewDecision // "none"),
      mergeable: (.mergeable // "UNKNOWN"),
      checks: (
        (.statusCheckRollup // []) as $c
        | if .checksTruncated then "incomplete"
          elif ($c | length) == 0 then "none"
          elif any($c[]; (check_green or check_pending) | not) then "failing"
          elif any($c[]; check_pending) then "pending"
          elif all($c[]; check_green) then "passing"
          else "failing" end),
      unresolved: unresolved_threads,
      review_requests: review_requests,
      conversation_requests: conversation_requests,
      reviews_truncated: (.reviewsTruncated // false),
      comments_truncated: (.commentsTruncated // false),
      evidence_changed: (.evidenceChanged // false)
    }'
}

reason_for_pr() { # <classified-json> <task-id-or-empty> <task-match-status> -> reason_code reason_detail
  local classified=$1 task=${2:-} task_status=${3:-0}
  local state checks review mergeable unresolved review_requests conversation_requests reviews_truncated comments_truncated evidence_changed hold
  state=$(printf '%s' "$classified" | jq -r '.state')
  checks=$(printf '%s' "$classified" | jq -r '.checks')
  review=$(printf '%s' "$classified" | jq -r '.review')
  mergeable=$(printf '%s' "$classified" | jq -r '.mergeable')
  unresolved=$(printf '%s' "$classified" | jq -r '.unresolved')
  review_requests=$(printf '%s' "$classified" | jq -r '.review_requests')
  conversation_requests=$(printf '%s' "$classified" | jq -r '.conversation_requests')
  reviews_truncated=$(printf '%s' "$classified" | jq -r '.reviews_truncated')
  comments_truncated=$(printf '%s' "$classified" | jq -r '.comments_truncated')
  evidence_changed=$(printf '%s' "$classified" | jq -r '.evidence_changed')
  if [ "$state" != OPEN ]; then
    REASON_CODE=not-open
    REASON_DETAIL="snapshot state is $state"
    return 0
  fi
  case "$checks" in
    none) REASON_CODE='checks-missing'; REASON_DETAIL='no successful checks reported'; return 0 ;;
    incomplete) REASON_CODE='checks-incomplete'; REASON_DETAIL='check evidence is truncated'; return 0 ;;
    pending) REASON_CODE='checks-pending'; REASON_DETAIL='checks still running'; return 0 ;;
    failing) REASON_CODE='checks-failing'; REASON_DETAIL='one or more checks failed'; return 0 ;;
  esac
  if [ "$mergeable" != MERGEABLE ]; then
    REASON_CODE=not-mergeable
    REASON_DETAIL="merge state is $mergeable"
    return 0
  fi
  if [ "$review" = CHANGES_REQUESTED ] || [ "$unresolved" -gt 0 ] \
    || [ "$review_requests" -gt 0 ] || [ "$conversation_requests" -gt 0 ] \
    || [ "$reviews_truncated" = true ] || [ "$comments_truncated" = true ]; then
    REASON_CODE='review-issue'
    REASON_DETAIL='review requests, comments, or unresolved threads'
    return 0
  fi
  if [ "$evidence_changed" = true ]; then
    REASON_CODE='evidence-changing'
    REASON_DETAIL='PR evidence changed during capture; defer to next cycle'
    return 0
  fi
  if [ "$task_status" -eq 2 ]; then
    REASON_CODE='ambiguous-task'
    REASON_DETAIL='multiple recorded task metadata files match this PR'
    return 0
  fi
  if [ -z "$task" ]; then
    REASON_CODE='no-task'
    REASON_DETAIL='no recorded pr= meta match'
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

pr_is_listed() { # <number> <numbers...>
  local number=$1 listed
  shift
  for listed in "$@"; do
    [ "$listed" = "$number" ] && return 0
  done
  return 1
}

retire_absent_pr_state() { # <repo> <open-numbers...>
  local repo=$1 key path base number marker marker_url retained line row_repo row_number
  retained=
  shift
  key=$(repo_state_key "$repo")
  for path in "$FINGERPRINT_DIR/$key-"*.fp "$DELIVERED_DIR/$key-"*.delivered; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    base=${path##*/}
    number=${base#"$key-"}
    number=${number%%.*}
    pr_is_listed "$number" "$@" || rm -f "$path" || return 1
  done
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    row_repo=${line%%$'\t'*}
    row_number=${line#*$'\t'}
    row_number=${row_number%%$'\t'*}
    if [ "$row_repo" = "$repo" ] && ! pr_is_listed "$row_number" "$@"; then
      continue
    fi
    retained="${retained}${line}"$'\n'
  done <<EOF
${QUEUE_ROWS:-}
EOF
  QUEUE_ROWS=$retained
  for marker in "$ACCELERATE_DIR"/*.marker; do
    [ -f "$marker" ] && [ ! -L "$marker" ] || continue
    marker_url=$(read_fingerprint "$marker" 2>/dev/null || true)
    fm_pr_url_parse "$marker_url" || continue
    [ "$FM_PR_PROVIDER" = github ] || continue
    [ "$FM_PR_OWNER/$FM_PR_REPO" = "$repo" ] || continue
    pr_is_listed "$FM_PR_NUMBER" "$@" || rm -f "$marker" || return 1
  done
}

pr_cursor_path() { # <repo>
  printf '%s/%s.cursor\n' "$PR_CURSOR_DIR" "$(repo_state_key "$1")"
}

read_pr_cursor() { # <repo>
  local cursor
  cursor=$(read_fingerprint "$(pr_cursor_path "$1")" 2>/dev/null || true)
  case "$cursor" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$cursor"
}

write_pr_cursor() { # <repo> <number>
  write_fingerprint "$(pr_cursor_path "$1")" "$2"
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
  local repo=$1 owner name pages
  owner=${repo%%/*}
  name=${repo#*/}
  [ -n "$owner" ] && [ -n "$name" ] && [ "$owner" != "$name" ] || return 1
  # shellcheck disable=SC2016 # GraphQL variables must reach GitHub literally.
  pages=$(fm_run_timed 10 env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    "$GH_BIN" api graphql --paginate \
    -f owner="$owner" -f name="$name" \
    -f query='query($owner: String!, $name: String!, $endCursor: String) { repository(owner: $owner, name: $name) { pullRequests(first: 100, after: $endCursor, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number } pageInfo { hasNextPage endCursor } } } }' \
    2>/dev/null) || return 1
  printf '%s\n' "$pages" | jq -sec \
    '[.[].data.repository.pullRequests.nodes[]?] | unique_by(.number)'
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
  local repo=$1 number=$2 first second
  first=$(gh_fetch_pr_snapshot_once "$repo" "$number") || return 1
  second=$(gh_fetch_pr_snapshot_once "$repo" "$number") || return 1
  if [ "$first" != "$second" ]; then
    printf '%s\n%s\n' "$first" "$second" | jq -sc '
      .[0] as $first | .[1] as $second
      | $first + {
          evidenceChanged: true,
          reviewThreads: {
            nodes: ([$first.reviewThreads.nodes[]?, $second.reviewThreads.nodes[]?]
              | group_by(.id)
              | map({id: .[0].id, isResolved: all(.[]; .isResolved)}))
          }
        }'
    return 0
  fi
  printf '%s\n' "$second"
}

gh_fetch_pr_snapshot_once() { # <repo> <number>
  local repo=$1 number=$2 owner name pages
  owner=${repo%%/*}
  name=${repo#*/}
  [ -n "$owner" ] && [ -n "$name" ] && [ "$owner" != "$name" ] || return 1
  # shellcheck disable=SC2016 # GraphQL variables must reach GitHub literally.
  pages=$(fm_run_timed 10 env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    "$GH_BIN" api graphql --paginate \
    -f owner="$owner" -f name="$name" -F number="$number" \
    -f query='query($owner: String!, $name: String!, $number: Int!, $endCursor: String) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { number url headRefName headRefOid baseRefName reviewDecision mergeable state author { login } commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes { ... on CheckRun { conclusion status } ... on StatusContext { state } } pageInfo { hasNextPage } } } } } } reviews(last: 100) { nodes { state body submittedAt author { login } } pageInfo { hasPreviousPage } } comments(last: 100) { nodes { body createdAt author { login } } pageInfo { hasPreviousPage } } reviewThreads(first: 100, after: $endCursor) { nodes { id isResolved } pageInfo { hasNextPage endCursor } } } } }' \
    2>/dev/null) || return 1
  printf '%s\n' "$pages" | jq -sec '
    def evidence:
      .data.repository.pullRequest
      | {
          number, url, headRefName, headRefOid, baseRefName, reviewDecision,
          mergeable, state,
          prAuthor: (.author.login // ""),
          statusCheckRollup: [
            (.commits.nodes[-1].commit.statusCheckRollup.contexts.nodes[]? | {
              conclusion, status, state
            })
          ],
          checksTruncated: (.commits.nodes[-1].commit.statusCheckRollup.contexts.pageInfo.hasNextPage // false),
          reviews: [(.reviews.nodes[]? | {author: (.author.login // ""), state, body, submittedAt})],
          reviewsTruncated: (.reviews.pageInfo.hasPreviousPage // false),
          comments: [(.comments.nodes[]? | {author: (.author.login // ""), body, createdAt})],
          commentsTruncated: (.comments.pageInfo.hasPreviousPage // false)
        };
    [ .[] | evidence ] as $evidence
    | ($evidence[0]) as $first
    | select(($first.headRefOid // "") != "")
    | select(($evidence | all(. == $first)))
    | $first + {
        reviewThreads: {
          nodes: ([.[].data.repository.pullRequest.reviewThreads.nodes[]?] | sort_by(.id))
        }
      }'
}

QUEUE_ROWS=''

load_blocked_queue() {
  QUEUE_ROWS=
  [ -f "$QUEUE_FILE" ] && [ ! -L "$QUEUE_FILE" ] || return 0
  QUEUE_ROWS=$(awk 'NR > 1 { print }' "$QUEUE_FILE")
  [ -z "$QUEUE_ROWS" ] || QUEUE_ROWS="${QUEUE_ROWS}"$'\n'
}

queue_add_row() { # <repo> <num> <url> <task> <reason> <detail>
  local row key
  row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(clean_field "$1")" "$(clean_field "$2")" "$(clean_field "$3")" \
    "$(clean_field "$4")" "$(clean_field "$5")" "$(clean_field "$6")")
  key="$(clean_field "$1")"$'\t'"$(clean_field "$2")"
  QUEUE_ROWS=$(printf '%s' "$QUEUE_ROWS" | awk -F '\t' -v key="$key" '$1 "\t" $2 != key { print }')
  [ -z "$QUEUE_ROWS" ] || QUEUE_ROWS="${QUEUE_ROWS}"$'\n'
  QUEUE_ROWS="${QUEUE_ROWS}${row}"
}

queue_remove_row() { # <repo> <num>
  local key
  key="$(clean_field "$1")"$'\t'"$(clean_field "$2")"
  QUEUE_ROWS=$(printf '%s' "$QUEUE_ROWS" | awk -F '\t' -v key="$key" '$1 "\t" $2 != key { print }')
  [ -z "$QUEUE_ROWS" ] || QUEUE_ROWS="${QUEUE_ROWS}"$'\n'
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
  local classified num url head task task_rc=0 fp_path delivered marker_fp new_fp accel_path
  [ "$(date +%s)" -lt "$deadline" ] || return 3
  classified=$(classify_pr_json "$repo" "$pr_json") || return 0
  num=$(printf '%s' "$classified" | jq -r '.number')
  url=$(printf '%s' "$classified" | jq -r '.url')
  head=$(printf '%s' "$classified" | jq -r '.head')
  task=$(match_task "$url" "$project" 2>/dev/null) || task_rc=$?
  reason_for_pr "$classified" "$task" "$task_rc"
  if [ "$REASON_CODE" = eligible ]; then
    queue_remove_row "$repo" "$num"
  else
    queue_add_row "$repo" "$num" "$url" "${task:--}" "$REASON_CODE" "$REASON_DETAIL"
  fi
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
  return 0
}

commit_actionable_state() {
  if [ -n "${PENDING_DELIVERED_PATH:-}" ]; then
    write_fingerprint "$PENDING_DELIVERED_PATH" "$PENDING_DELIVERED_VALUE" || return 1
    rm -f "$PENDING_ACCEL_PATH" || return 1
  fi
}

consume_accelerate_markers() {
  local marker
  for marker in "$ACCELERATE_DIR"/*.marker; do
    [ -f "$marker" ] && [ ! -L "$marker" ] || continue
    rm -f "$marker" || return 1
  done
}

scan_repo() { # <project> <repo> <deadline>
  local project=$1 repo=$2 deadline=$3 cursor
  local list_json pr_json start=0 i offset count
  local -a numbers
  list_json=$(gh_fetch_open_prs "$repo") || return 0
  [ -n "$list_json" ] || list_json='[]'
  mapfile -t numbers < <(printf '%s' "$list_json" | jq -r '.[].number | tostring')
  count=${#numbers[@]}
  cursor=$(read_pr_cursor "$repo" 2>/dev/null || true)
  if [ -n "$cursor" ]; then
    for ((i = 0; i < count; i++)); do
      if [ "${numbers[$i]}" = "$cursor" ]; then
        start=$(((i + 1) % count))
        break
      fi
    done
  fi
  for ((offset = 0; offset < count; offset++)); do
    i=$(((start + offset) % count))
    num=${numbers[$i]}
    [ -n "$num" ] || continue
    [ "$(date +%s)" -lt "$deadline" ] || return 3
    pr_json=$(gh_fetch_pr_view "$repo" "$num") || {
      write_pr_cursor "$repo" "$num" || return 1
      continue
    }
    process_pr_record "$repo" "$project" "$pr_json" "$deadline" || {
      case "$?" in
        3) return 3 ;;
        *) return 1 ;;
      esac
    }
    write_pr_cursor "$repo" "$num" || return 1
    [ -z "${ACTIONABLE:-}" ] || return 0
  done
  retire_absent_pr_state "$repo" "${numbers[@]}" || return 1
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
  load_blocked_queue
  command -v jq >/dev/null 2>&1 || { printf 'fm-pr-delivery: jq not found\n' >&2; return 1; }
  command -v "$GH_BIN" >/dev/null 2>&1 || return 0
  refuse_secondmate || return $?
  ensure_dirs || return 1
  build_task_index
  if [ "$startup" != 1 ] && [ "$(scan_marker_age)" -lt "$FM_PR_DELIVERY_SECS" ]; then
    accelerated=0
    for _accel in "$ACCELERATE_DIR"/*; do
      [ -f "$_accel" ] && [ ! -L "$_accel" ] || continue
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
  elif [ "$rc" -eq 0 ]; then
    consume_accelerate_markers || return 1
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
  write_fingerprint "$(accelerate_path "$url")" "$url"
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
