#!/usr/bin/env bash
# Collect and verify evidence-backed GitHub pull-request feedback triage.
#
# Usage:
#   fm-pr-review.sh snapshot <task-id> <pr-url>
#   fm-pr-review.sh record <task-id> <pr-url> <assessment-json>
#   fm-pr-review.sh verify <task-id> <pr-url>
#
# `snapshot` fully paginates pull-request conversation comments, submitted
# reviews, review threads, and every thread's comments. It writes the latest
# complete observation to data/<task-id>/pr-review-snapshot.json. `record`
# refetches that observation, validates an assessment against the live head and
# semantic fingerprint, then writes data/<task-id>/pr-review.json. `verify`
# refetches again and returns 0 only when checks are green, no active
# CHANGES_REQUESTED decision exists, every source has a current disposition, no
# disposition needs action, and two identical complete snapshots were observed
# at least 120 seconds apart. A one-shot invocation never sleeps; the worker's
# existing bounded wait owns retries (project timeout when documented, otherwise
# 15 minutes).
#
# Snapshot schema: fm-pr-review-snapshot.v1. It binds task_id, optional
# spawn_gen, canonical pr_url, head, review_decision, checks, sorted source
# records, collected_at/epoch, a semantic fingerprint, and settling state. Each
# source has a stable GitHub-derived id, URL, retained content/state, and its own
# content fingerprint. Fetch time and reactions are excluded from fingerprints.
#
# Assessment schema: fm-pr-review-assessment.v1. It binds task_id, optional
# spawn_gen, pr_url, head, snapshot_fingerprint, and exactly one entry for every
# snapshot source. Each entry carries id, source_fingerprint, disposition
# (`fixed`, `not-actionable`, or `needs-action`), rationale, and evidence.
# `fixed` evidence is an object with the current head plus nonempty `behavior`
# and `verification` strings. `not-actionable` requires nonempty concrete
# evidence. One source containing several findings remains one source entry, but
# its rationale must account for every finding. The script proves coverage and
# freshness, not the quality of that judgment; source content remains retained.
#
# Exit status: snapshot/record return 0 only after complete collection/valid
# persistence. verify returns 0 ready, 1 pending/unaddressed/stale, and 2 for
# invalid input or unavailable proof. Collection never evaluates GitHub or
# assessment text as shell code and never changes review discussions.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA_RAW="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat <<'EOF'
usage:
  fm-pr-review.sh snapshot <task-id> <github-pr-url>
  fm-pr-review.sh record <task-id> <github-pr-url> <assessment-json>
  fm-pr-review.sh verify <task-id> <github-pr-url>
EOF
}

invalid() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

unavailable() {
  printf 'error: review proof unavailable: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
COMMAND=${1:-}
case "$COMMAND" in
  snapshot|verify) [ "$#" -eq 3 ] || { usage >&2; exit 2; } ;;
  record) [ "$#" -eq 4 ] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac
ID=$2
RAW_URL=$3
ASSESSMENT_INPUT=${4:-}

fm_pr_task_id_valid "$ID" || invalid "invalid task id"
fm_pr_url_parse "$RAW_URL" || invalid "invalid pull request URL"
[ "$FM_PR_PROVIDER" = github ] || invalid "review evidence collection supports GitHub pull requests only"
URL=$FM_PR_URL
OWNER=$FM_PR_OWNER
REPO=$FM_PR_REPO
NUMBER=$FM_PR_NUMBER
command -v gh >/dev/null 2>&1 || unavailable "gh is required on PATH"
command -v jq >/dev/null 2>&1 || unavailable "jq is required on PATH"
command -v mktemp >/dev/null 2>&1 || unavailable "mktemp is required on PATH"

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || invalid "task metadata is unavailable"
META_IDENTITY=$(fm_pr_file_identity "$META") || invalid "task metadata identity is unavailable"
META_HASH=$(fm_pr_sha256 "$META") || invalid "task metadata hash is unavailable"

metadata_values() {
  local spawn_count head_count value
  fm_pr_metadata_identity_parse "$META" || return 1
  [ "$FM_PR_META_PROVIDER" = github ] && [ "$FM_PR_META_URL" = "$URL" ] \
    && [ "$FM_PR_META_HOST" = github.com ] && [ "$FM_PR_META_PATH" = "$OWNER/$REPO" ] \
    && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || return 1
  spawn_count=$(grep -c '^spawn_gen=' "$META" 2>/dev/null || true)
  case "$spawn_count" in
    0) SPAWN_GEN= ;;
    1)
      SPAWN_GEN=$(sed -n 's/^spawn_gen=//p' "$META")
      case "$SPAWN_GEN" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  head_count=$(grep -c '^pr_head=' "$META" 2>/dev/null || true)
  case "$head_count" in
    0) RECORDED_HEAD= ;;
    1)
      value=$(sed -n 's/^pr_head=//p' "$META")
      fm_pr_head_valid "$value" || return 1
      RECORDED_HEAD=$value
      ;;
    *) return 1 ;;
  esac
}

metadata_values || invalid "task metadata does not bind this canonical pull request"
ORIGINAL_SPAWN_GEN=$SPAWN_GEN
ORIGINAL_RECORDED_HEAD=$RECORDED_HEAD

[ -d "$DATA_RAW" ] && [ ! -L "$DATA_RAW" ] || invalid "task data root is unavailable"
DATA=$(cd -P -- "$DATA_RAW" 2>/dev/null && pwd -P) || invalid "task data root is unavailable"
DATA_DEVICE=$(fm_pr_file_device "$DATA") || invalid "task data root identity is unavailable"
TASK_DATA="$DATA/$ID"
umask 077
if [ ! -e "$TASK_DATA" ]; then
  mkdir -m 0700 -- "$TASK_DATA" 2>/dev/null || invalid "task data directory cannot be created"
fi
[ -d "$TASK_DATA" ] && [ ! -L "$TASK_DATA" ] \
  && [ "$(fm_pr_file_device "$TASK_DATA")" = "$DATA_DEVICE" ] \
  || invalid "task data directory is unsafe"
SNAPSHOT="$TASK_DATA/pr-review-snapshot.json"
ASSESSMENT="$TASK_DATA/pr-review.json"
WORK=$(mktemp -d "$TASK_DATA/.pr-review.XXXXXX") || unavailable "temporary review directory cannot be created"
META_LOCK=
META_LOCK_HELD=0
cleanup() {
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" >/dev/null 2>&1 || true
    META_LOCK_HELD=0
  fi
  rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'exit 2' HUP INT TERM

metadata_still_matches() { # [live-head]
  local live_head=${1:-}
  [ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] || return 1
  [ "$(fm_pr_file_identity "$META")" = "$META_IDENTITY" ] || return 1
  [ "$(fm_pr_sha256 "$META")" = "$META_HASH" ] || return 1
  metadata_values || return 1
  [ "$SPAWN_GEN" = "$ORIGINAL_SPAWN_GEN" ] || return 1
  [ "$RECORDED_HEAD" = "$ORIGINAL_RECORDED_HEAD" ] || return 1
  [ -z "$live_head" ] || [ -z "$RECORDED_HEAD" ] || [ "$RECORDED_HEAD" = "$live_head" ]
}

publish_private_json() { # <source> <destination> <live-head>
  local source=$1 destination=$2 live_head=$3 tmp
  META_LOCK=$(fm_meta_lock_path "$META") || return 1
  fm_lock_acquire_wait "$META_LOCK" || return 1
  META_LOCK_HELD=1
  metadata_still_matches "$live_head" || return 1
  fm_pr_regular_destination_on_device_or_absent "$destination" "$DATA_DEVICE" || return 1
  tmp=$(mktemp "$TASK_DATA/.pr-review-publish.XXXXXX") || return 1
  if ! jq -S '.' "$source" > "$tmp" 2>/dev/null \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$DATA_DEVICE" \
    || ! metadata_still_matches "$live_head" \
    || ! fm_pr_regular_destination_on_device_or_absent "$destination" "$DATA_DEVICE" \
    || ! mv -f -- "$tmp" "$destination"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_private_file_valid "$destination" 600 "$DATA_DEVICE" || return 1
  fm_lock_release "$META_LOCK" || return 1
  META_LOCK_HELD=0
  META_LOCK=
}

PR_VIEW_QUERY='headRefOid,reviewDecision,statusCheckRollup'
read_pr_view() { # <destination>
  gh pr view "$URL" --json "$PR_VIEW_QUERY" > "$1" 2>/dev/null \
    && jq -e '
      type == "object"
      and (.headRefOid | type == "string")
      and ((.reviewDecision == null) or (.reviewDecision | type == "string"))
      and (.statusCheckRollup | type == "array")
    ' "$1" >/dev/null 2>&1
}

COMMENTS_QUERY='query ReviewCommentsPage($owner:String!,$name:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){comments(first:100,after:$cursor){nodes{id url body createdAt updatedAt isMinimized minimizedReason author{login __typename} authorAssociation}pageInfo{hasNextPage endCursor}}}}}'
REVIEWS_QUERY='query ReviewsPage($owner:String!,$name:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviews(first:100,after:$cursor){nodes{id url body state submittedAt updatedAt author{login __typename} authorAssociation commit{oid}}pageInfo{hasNextPage endCursor}}}}}'
THREADS_QUERY='query ReviewThreadsPage($owner:String!,$name:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$cursor){nodes{id isResolved isOutdated path line originalLine startLine originalStartLine diffSide startDiffSide}pageInfo{hasNextPage endCursor}}}}}'
THREAD_COMMENTS_QUERY='query ThreadCommentsPage($id:ID!,$cursor:String){node(id:$id){__typename ... on PullRequestReviewThread{id comments(first:100,after:$cursor){nodes{id url body createdAt updatedAt isMinimized minimizedReason author{login __typename} authorAssociation path line originalLine diffHunk pullRequestReview{id commit{oid}}}pageInfo{hasNextPage endCursor}}}}}'

connection_expr() {
  case "$1" in
    comments) printf '.data.repository.pullRequest.comments' ;;
    reviews) printf '.data.repository.pullRequest.reviews' ;;
    threads) printf '.data.repository.pullRequest.reviewThreads' ;;
    thread-comments) printf '.data.node.comments' ;;
    *) return 1 ;;
  esac
}

node_contract() { # <kind>
  case "$1" in
    comments)
      printf 'all(.[]; (.id|type=="string" and length>0) and (.url|type=="string" and length>0) and (.body|type=="string") and (.createdAt|type=="string") and (.updatedAt|type=="string") and (.isMinimized|type=="boolean") and ((.author==null) or ((.author.login|type)=="string" and (.author.__typename|type)=="string")))'
      ;;
    reviews)
      printf 'all(.[]; (.id|type=="string" and length>0) and (.url|type=="string" and length>0) and (.body|type=="string") and (.state|type=="string") and ((.submittedAt==null) or (.submittedAt|type=="string")) and ((.updatedAt==null) or (.updatedAt|type=="string")) and ((.author==null) or ((.author.login|type)=="string" and (.author.__typename|type)=="string")) and ((.commit==null) or (.commit.oid|type=="string")))'
      ;;
    threads)
      printf 'all(.[]; (.id|type=="string" and length>0) and (.isResolved|type=="boolean") and (.isOutdated|type=="boolean") and (.path|type=="string"))'
      ;;
    thread-comments)
      printf 'all(.[]; (.id|type=="string" and length>0) and (.url|type=="string" and length>0) and (.body|type=="string") and (.createdAt|type=="string") and (.updatedAt|type=="string") and (.isMinimized|type=="boolean") and ((.author==null) or ((.author.login|type)=="string" and (.author.__typename|type)=="string")) and ((.pullRequestReview==null) or ((.pullRequestReview.id|type)=="string" and ((.pullRequestReview.commit==null) or (.pullRequestReview.commit.oid|type=="string")))) )'
      ;;
    *) return 1 ;;
  esac
}

collect_connection() { # <kind> <query> <jsonl-out> [thread-id]
  local kind=$1 query=$2 out=$3 thread_id=${4:-} cursor='' next seen='' response expr contract
  : > "$out" || return 1
  expr=$(connection_expr "$kind") || return 1
  contract=$(node_contract "$kind") || return 1
  while :; do
    response="$WORK/response.json"
    if [ "$kind" = thread-comments ]; then
      if [ -n "$cursor" ]; then
        gh api graphql -f query="$query" -F id="$thread_id" -f cursor="$cursor" > "$response" 2>/dev/null || return 1
      else
        gh api graphql -f query="$query" -F id="$thread_id" > "$response" 2>/dev/null || return 1
      fi
    elif [ -n "$cursor" ]; then
      gh api graphql -f query="$query" -F owner="$OWNER" -F name="$REPO" -F number="$NUMBER" -f cursor="$cursor" > "$response" 2>/dev/null || return 1
    else
      gh api graphql -f query="$query" -F owner="$OWNER" -F name="$REPO" -F number="$NUMBER" > "$response" 2>/dev/null || return 1
    fi
    if [ "$kind" = thread-comments ]; then
      jq -e --arg id "$thread_id" --argjson expr_ok true \
        "((.errors // []) | type == \"array\" and length == 0) and (.data.node.__typename == \"PullRequestReviewThread\") and (.data.node.id == \$id) and (($expr.nodes | type) == \"array\") and (($expr.nodes | $contract)) and (($expr.pageInfo.hasNextPage | type) == \"boolean\") and ((($expr.pageInfo.hasNextPage | not)) or (($expr.pageInfo.endCursor | type) == \"string\" and ($expr.pageInfo.endCursor | length) > 0))" \
        "$response" >/dev/null 2>&1 || return 1
    else
      jq -e \
        "((.errors // []) | type == \"array\" and length == 0) and (($expr.nodes | type) == \"array\") and (($expr.nodes | $contract)) and (($expr.pageInfo.hasNextPage | type) == \"boolean\") and ((($expr.pageInfo.hasNextPage | not)) or (($expr.pageInfo.endCursor | type) == \"string\" and ($expr.pageInfo.endCursor | length) > 0))" \
        "$response" >/dev/null 2>&1 || return 1
    fi
    jq -c "$expr.nodes[]" "$response" >> "$out" 2>/dev/null || return 1
    next=$(jq -r "if $expr.pageInfo.hasNextPage then $expr.pageInfo.endCursor else \"\" end" "$response" 2>/dev/null) || return 1
    [ -n "$next" ] || break
    case "$seen" in *$'\n'"$next"$'\n'*) return 1 ;; esac
    seen="$seen"$'\n'"$next"$'\n'
    cursor=$next
  done
}

canonical_checks() { # <pr-view> <output>
  jq -S '
    [ .statusCheckRollup[]
      | if .__typename == "CheckRun" then
          {__typename:"CheckRun", name:(.name // ""), status:(.status // null), conclusion:(.conclusion // null), startedAt:(.startedAt // null), completedAt:(.completedAt // null), detailsUrl:(.detailsUrl // null)}
        elif .__typename == "StatusContext" then
          {__typename:"StatusContext", context:(.context // ""), state:(.state // null), targetUrl:(.targetUrl // null), startedAt:(.startedAt // null)}
        else
          {__typename:(.__typename // null), raw:.}
        end
    ] | sort_by([.__typename // "", .name // .context // "", .startedAt // "", .detailsUrl // .targetUrl // ""])
  ' "$1" > "$2" 2>/dev/null
}

fingerprint_sources() { # <raw-jsonl> <array-output>
  local raw=$1 out=$2 source fp
  : > "$WORK/sources-fingerprinted.jsonl" || return 1
  while IFS= read -r source || [ -n "$source" ]; do
    [ -n "$source" ] || continue
    printf '%s\n' "$source" | jq -S '.' > "$WORK/source.json" 2>/dev/null || return 1
    fp=$(fm_pr_sha256 "$WORK/source.json") || return 1
    printf '%s\n' "$source" | jq -c --arg fp "$fp" '. + {fingerprint:$fp}' \
      >> "$WORK/sources-fingerprinted.jsonl" 2>/dev/null || return 1
  done < "$raw"
  jq -S -s '
    sort_by(.id)
    | if (map(.id) | length) == (map(.id) | unique | length) then . else error("duplicate source id") end
  ' "$WORK/sources-fingerprinted.jsonl" > "$out" 2>/dev/null
}

CURRENT_HEAD=
CURRENT_FINGERPRINT=
CURRENT_SETTLED=false
CURRENT_FIRST_SEEN=0
CURRENT_SAMPLES=0

collect_snapshot() {
  local initial="$WORK/pr-initial.json" final="$WORK/pr-final.json"
  local initial_head final_head review_decision source thread id
  local previous_info previous_fp previous_first previous_samples now_epoch now_iso first samples settled

  read_pr_view "$initial" || unavailable "GitHub pull request head, review decision, or check rollup could not be read"
  initial_head=$(jq -r '.headRefOid' "$initial")
  fm_pr_head_valid "$initial_head" || unavailable "GitHub returned an invalid pull request head"

  collect_connection comments "$COMMENTS_QUERY" "$WORK/comments.jsonl" \
    || unavailable "GitHub conversation comments were not completely paginated"
  collect_connection reviews "$REVIEWS_QUERY" "$WORK/reviews.jsonl" \
    || unavailable "GitHub submitted reviews were not completely paginated"
  collect_connection threads "$THREADS_QUERY" "$WORK/threads.jsonl" \
    || unavailable "GitHub review threads were not completely paginated"

  : > "$WORK/threads-complete.jsonl"
  while IFS= read -r thread || [ -n "$thread" ]; do
    [ -n "$thread" ] || continue
    id=$(printf '%s\n' "$thread" | jq -r '.id') || unavailable "a review thread id could not be read"
    collect_connection thread-comments "$THREAD_COMMENTS_QUERY" "$WORK/thread-comments.jsonl" "$id" \
      || unavailable "comments for GitHub review thread $id were not completely paginated"
    printf '%s\n' "$thread" > "$WORK/thread.json"
    jq -s 'sort_by(.id)' "$WORK/thread-comments.jsonl" > "$WORK/thread-comments.json" 2>/dev/null \
      || unavailable "comments for GitHub review thread $id could not be normalized"
    jq -c --slurpfile comments "$WORK/thread-comments.json" --arg pr "$URL" \
      '. + {comments:$comments[0], url:(($comments[0] | map(.url) | first) // $pr)}' \
      "$WORK/thread.json" >> "$WORK/threads-complete.jsonl" 2>/dev/null \
      || unavailable "GitHub review thread $id could not be normalized"
  done < "$WORK/threads.jsonl"

  read_pr_view "$final" || unavailable "GitHub pull request head, review decision, or check rollup could not be re-read"
  final_head=$(jq -r '.headRefOid' "$final")
  fm_pr_head_valid "$final_head" || unavailable "GitHub returned an invalid pull request head"
  [ "$initial_head" = "$final_head" ] \
    || unavailable "pull request head changed during collection ($initial_head -> $final_head)"
  [ -z "${FM_PR_REVIEW_EXPECT_HEAD:-}" ] || [ "$final_head" = "$FM_PR_REVIEW_EXPECT_HEAD" ] \
    || { printf 'pending: pull request head %s no longer matches required head %s: %s\n' "$final_head" "$FM_PR_REVIEW_EXPECT_HEAD" "$URL" >&2; return 1; }
  metadata_still_matches "$final_head" \
    || unavailable "task identity or recorded pull request head changed during collection"

  canonical_checks "$final" "$WORK/checks.json" \
    || unavailable "GitHub check rollup could not be normalized"
  review_decision=$(jq -c '.reviewDecision' "$final") \
    || unavailable "GitHub review decision could not be normalized"
  jq -S -s 'sort_by(.id)' "$WORK/comments.jsonl" > "$WORK/comments.json" 2>/dev/null \
    || unavailable "GitHub conversation comments could not be normalized"
  jq -S -s 'sort_by(.id)' "$WORK/reviews.jsonl" > "$WORK/reviews.json" 2>/dev/null \
    || unavailable "GitHub submitted reviews could not be normalized"
  jq -S -s 'sort_by(.id)' "$WORK/threads-complete.jsonl" > "$WORK/threads-complete.json" 2>/dev/null \
    || unavailable "GitHub review threads could not be normalized"

  : > "$WORK/sources-raw.jsonl"
  jq -c '.[] | {
      id:("comment:" + .id), github_id:.id, kind:"conversation-comment", url:.url,
      author:(if .author == null then null else {login:.author.login,type:.author.__typename} end),
      author_association:(.authorAssociation // null), body:.body, created_at:.createdAt,
      updated_at:.updatedAt, minimized:.isMinimized, minimized_reason:(.minimizedReason // null)
    }' "$WORK/comments.json" >> "$WORK/sources-raw.jsonl" 2>/dev/null \
    || unavailable "GitHub conversation comments could not be represented"
  jq -c '.[] | {
      id:("review:" + .id), github_id:.id, kind:"submitted-review", url:.url,
      author:(if .author == null then null else {login:.author.login,type:.author.__typename} end),
      author_association:(.authorAssociation // null), body:.body, state:.state,
      submitted_at:(.submittedAt // null), updated_at:(.updatedAt // null),
      commit:(if .commit == null then null else .commit.oid end)
    }' "$WORK/reviews.json" >> "$WORK/sources-raw.jsonl" 2>/dev/null \
    || unavailable "GitHub submitted reviews could not be represented"
  jq -c '.[] | {
      id:("thread:" + .id), github_id:.id, kind:"review-thread", url:.url,
      resolved:.isResolved, outdated:.isOutdated, path:.path, line:(.line // null),
      original_line:(.originalLine // null), start_line:(.startLine // null),
      original_start_line:(.originalStartLine // null), diff_side:(.diffSide // null),
      start_diff_side:(.startDiffSide // null),
      comments:[.comments[] | {
        id:.id, url:.url,
        author:(if .author == null then null else {login:.author.login,type:.author.__typename} end),
        author_association:(.authorAssociation // null), body:.body, created_at:.createdAt,
        updated_at:.updatedAt, minimized:.isMinimized, minimized_reason:(.minimizedReason // null),
        path:(.path // null), line:(.line // null), original_line:(.originalLine // null),
        diff_hunk:(.diffHunk // null), review_id:(.pullRequestReview.id // null),
        review_commit:(.pullRequestReview.commit.oid // null)
      }]
    }' "$WORK/threads-complete.json" >> "$WORK/sources-raw.jsonl" 2>/dev/null \
    || unavailable "GitHub review threads could not be represented"
  fingerprint_sources "$WORK/sources-raw.jsonl" "$WORK/sources.json" \
    || unavailable "GitHub feedback fingerprints could not be created"

  jq -S -n --arg pr "$URL" --arg head "$final_head" --argjson decision "$review_decision" \
    --slurpfile checks "$WORK/checks.json" --slurpfile sources "$WORK/sources.json" \
    '{pr_url:$pr,head:$head,review_decision:$decision,checks:$checks[0],sources:[$sources[0][]|{id,fingerprint}]}' \
    > "$WORK/semantic.json" 2>/dev/null || unavailable "review fingerprint input could not be created"
  CURRENT_FINGERPRINT=$(fm_pr_sha256 "$WORK/semantic.json") \
    || unavailable "review fingerprint could not be created"

  now_epoch=${FM_PR_REVIEW_NOW_EPOCH:-$(date +%s)}
  case "$now_epoch" in ''|*[!0-9]*) invalid "FM_PR_REVIEW_NOW_EPOCH must be an epoch second" ;; esac
  now_iso=${FM_PR_REVIEW_NOW_ISO:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}
  case "$now_iso" in *$'\n'*|*$'\r'*|'') invalid "FM_PR_REVIEW_NOW_ISO is invalid" ;; esac
  first=$now_epoch
  samples=1
  if [ -e "$SNAPSHOT" ] && fm_pr_private_file_valid "$SNAPSHOT" 600 "$DATA_DEVICE"; then
    previous_info=$(jq -er --arg task "$ID" --arg gen "$ORIGINAL_SPAWN_GEN" --arg pr "$URL" '
      select(.schema == "fm-pr-review-snapshot.v1" and .task_id == $task and (.spawn_gen // "") == $gen and .pr_url == $pr)
      | select((.fingerprint|type)=="string" and (.settling.first_seen_epoch|type)=="number" and (.settling.matching_samples|type)=="number")
      | [.fingerprint,.settling.first_seen_epoch,.settling.matching_samples] | @tsv
    ' "$SNAPSHOT" 2>/dev/null) || previous_info=
    if [ -n "$previous_info" ]; then
      previous_fp=${previous_info%%$'\t'*}
      previous_info=${previous_info#*$'\t'}
      previous_first=${previous_info%%$'\t'*}
      previous_samples=${previous_info#*$'\t'}
      if [ "$previous_fp" = "$CURRENT_FINGERPRINT" ] \
        && [ "$previous_first" -le "$now_epoch" ] 2>/dev/null \
        && [ "$previous_samples" -ge 1 ] 2>/dev/null; then
        first=$previous_first
        samples=$((previous_samples + 1))
      fi
    fi
  elif [ -e "$SNAPSHOT" ] || [ -L "$SNAPSHOT" ]; then
    fm_pr_regular_destination_on_device_or_absent "$SNAPSHOT" "$DATA_DEVICE" \
      || invalid "review snapshot destination is unsafe"
  fi
  settled=false
  if [ "$samples" -ge 2 ] && [ $((now_epoch - first)) -ge 120 ]; then settled=true; fi

  jq -S -n \
    --arg task "$ID" --arg gen "$ORIGINAL_SPAWN_GEN" --arg pr "$URL" --arg head "$final_head" \
    --argjson decision "$review_decision" --arg collected "$now_iso" --argjson epoch "$now_epoch" \
    --arg fingerprint "$CURRENT_FINGERPRINT" --argjson first "$first" --argjson samples "$samples" \
    --argjson settled "$settled" --slurpfile checks "$WORK/checks.json" --slurpfile sources "$WORK/sources.json" \
    '{schema:"fm-pr-review-snapshot.v1",task_id:$task,spawn_gen:$gen,pr_url:$pr,head:$head,
      review_decision:$decision,checks:$checks[0],sources:$sources[0],collected_at:$collected,
      collected_epoch:$epoch,fingerprint:$fingerprint,
      settling:{required_seconds:120,first_seen_epoch:$first,matching_samples:$samples,settled:$settled}}' \
    > "$WORK/snapshot.json" 2>/dev/null || unavailable "review snapshot could not be created"
  publish_private_json "$WORK/snapshot.json" "$SNAPSHOT" "$final_head" \
    || unavailable "review snapshot could not be published safely"
  CURRENT_HEAD=$final_head
  CURRENT_SETTLED=$settled
  CURRENT_FIRST_SEEN=$first
  CURRENT_SAMPLES=$samples
}

assessment_structurally_valid() { # <assessment>
  local assessed_head
  assessed_head=$(jq -r '.head // empty' "$1" 2>/dev/null || true)
  jq -e '
    def text: type == "string" and test("\\S");
    def concrete:
      . != null and (
        (type == "string" and test("\\S")) or
        (type == "object" and length > 0) or
        (type == "array" and length > 0) or
        (type == "number") or (type == "boolean")
      );
    type == "object"
    and .schema == "fm-pr-review-assessment.v1"
    and (.task_id | type == "string" and length > 0)
    and ((.spawn_gen // "") | type == "string")
    and (.pr_url | type == "string" and length > 0)
    and (.head | type == "string" and length > 0)
    and (.snapshot_fingerprint | type == "string" and test("^[0-9a-f]{64}$"))
    and (.sources | type == "array")
    and ((.sources | map(.id) | length) == (.sources | map(.id) | unique | length))
    and all(.sources[];
      (.id | type == "string" and length > 0)
      and (.source_fingerprint | type == "string" and test("^[0-9a-f]{64}$"))
      and (.disposition == "fixed" or .disposition == "not-actionable" or .disposition == "needs-action")
      and (.rationale | text)
      and (if .disposition == "fixed" then
             (.evidence | type == "object")
             and (.evidence.head == $head)
             and (.evidence.behavior | text)
             and (.evidence.verification | text)
           elif .disposition == "not-actionable" then
             (.evidence | concrete)
           else true end)
    )
  ' --arg head "$assessed_head" "$1" >/dev/null 2>&1
}

assessment_header_matches_snapshot() { # <assessment>
  jq -e --slurpfile snapshot "$SNAPSHOT" \
    --arg task "$ID" --arg gen "$ORIGINAL_SPAWN_GEN" --arg pr "$URL" '
      .task_id == $task
      and (.spawn_gen // "") == $gen
      and .pr_url == $pr
      and .head == $snapshot[0].head
      and .snapshot_fingerprint == $snapshot[0].fingerprint
    ' "$1" >/dev/null 2>&1
}

assessment_sources_match_snapshot() { # <assessment>
  jq -e --slurpfile snapshot "$SNAPSHOT" '
      (.sources | map({id, fingerprint:.source_fingerprint}) | sort_by(.id))
      == ($snapshot[0].sources | map({id,fingerprint}) | sort_by(.id))
    ' "$1" >/dev/null 2>&1
}

assessment_matches_snapshot() { # <assessment>
  assessment_header_matches_snapshot "$1" \
    && assessment_sources_match_snapshot "$1"
}

report_stale_sources() { # <assessment>
  jq -r --slurpfile assessment "$1" --arg pr "$URL" '
    .sources[] as $source
    | ([ $assessment[0].sources[] | select(.id == $source.id and .source_fingerprint == $source.fingerprint) ] | length) as $matches
    | select($matches != 1)
    | "pending: feedback source is new or edited: \($source.url // $pr) [\($source.id)]"
  ' "$SNAPSHOT" >&2 2>/dev/null || true
  jq -r --slurpfile snapshot "$SNAPSHOT" --arg pr "$URL" '
    .sources[] as $source
    | ([ $snapshot[0].sources[] | select(.id == $source.id) ] | length) as $matches
    | select($matches == 0)
    | "pending: assessed feedback source no longer exists: \($pr) [\($source.id)]"
  ' "$1" >&2 2>/dev/null || true
}

copy_assessment_input() {
  local identity hash
  [ -f "$ASSESSMENT_INPUT" ] && [ ! -L "$ASSESSMENT_INPUT" ] \
    && [ "$(fm_pr_file_link_count "$ASSESSMENT_INPUT")" = 1 ] \
    || invalid "assessment JSON is not a regular single-link file"
  identity=$(fm_pr_file_identity "$ASSESSMENT_INPUT") || invalid "assessment JSON identity is unavailable"
  hash=$(fm_pr_sha256 "$ASSESSMENT_INPUT") || invalid "assessment JSON hash is unavailable"
  cp -- "$ASSESSMENT_INPUT" "$WORK/assessment-input.json" 2>/dev/null \
    || invalid "assessment JSON could not be read"
  [ "$(fm_pr_file_identity "$ASSESSMENT_INPUT")" = "$identity" ] \
    && [ "$(fm_pr_sha256 "$ASSESSMENT_INPUT")" = "$hash" ] \
    || invalid "assessment JSON changed while it was read"
}

case "$COMMAND" in
  snapshot)
    collect_snapshot
    printf 'snapshot: %s head=%s fingerprint=%s settled=%s samples=%s\n' \
      "$SNAPSHOT" "$CURRENT_HEAD" "$CURRENT_FINGERPRINT" "$CURRENT_SETTLED" "$CURRENT_SAMPLES"
    ;;
  record)
    copy_assessment_input
    collect_snapshot
    assessment_structurally_valid "$WORK/assessment-input.json" \
      || invalid "assessment JSON is incomplete; every source needs a valid disposition, rationale, and required evidence"
    if ! assessment_header_matches_snapshot "$WORK/assessment-input.json"; then
      printf 'pending: supplied assessment is stale for %s\n' "$URL" >&2
      report_stale_sources "$WORK/assessment-input.json"
      exit 1
    fi
    if ! assessment_sources_match_snapshot "$WORK/assessment-input.json"; then
      report_stale_sources "$WORK/assessment-input.json"
      invalid "assessment JSON does not cover every current feedback source exactly once"
    fi
    NOW_ISO=${FM_PR_REVIEW_NOW_ISO:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}
    jq -S --arg recorded "$NOW_ISO" '.recorded_at=$recorded | .sources |= sort_by(.id)' \
      "$WORK/assessment-input.json" > "$WORK/assessment.json" 2>/dev/null \
      || invalid "assessment JSON could not be normalized"
    publish_private_json "$WORK/assessment.json" "$ASSESSMENT" "$CURRENT_HEAD" \
      || unavailable "review assessment could not be published safely"
    printf 'recorded: %s head=%s fingerprint=%s\n' "$ASSESSMENT" "$CURRENT_HEAD" "$CURRENT_FINGERPRINT"
    ;;
  verify)
    collect_snapshot || exit $?
    pending=0
    jq '{statusCheckRollup:.checks}' "$SNAPSHOT" > "$WORK/check-view.json" 2>/dev/null \
      || unavailable "stored check rollup could not be read"
    if ! red=$(fm_pr_github_checks_not_green "$(cat "$WORK/check-view.json")"); then
      unavailable "stored check rollup is invalid"
    fi
    if [ -n "$red" ]; then
      while IFS= read -r check; do
        [ -n "$check" ] || continue
        if [ -n "${FM_PR_REVIEW_EXPECT_HEAD:-}" ] \
          && [ -n "${FM_PR_REVIEW_ALLOW_RED_CHECK:-}" ] \
          && [ "$check" = "$FM_PR_REVIEW_ALLOW_RED_CHECK" ]; then
          continue
        fi
        printf 'pending: GitHub check is not green: %s (%s)\n' "$check" "$URL" >&2
        pending=1
      done <<EOF
$red
EOF
    fi
    decision=$(jq -r '.review_decision // ""' "$SNAPSHOT" 2>/dev/null) \
      || unavailable "stored review decision could not be read"
    if [ "$decision" = CHANGES_REQUESTED ]; then
      printf 'pending: GitHub review decision is CHANGES_REQUESTED: %s\n' "$URL" >&2
      pending=1
    fi
    if [ "$CURRENT_SETTLED" != true ]; then
      elapsed=$(( ${FM_PR_REVIEW_NOW_EPOCH:-$(date +%s)} - CURRENT_FIRST_SEEN ))
      [ "$elapsed" -ge 0 ] || elapsed=0
      printf 'pending: feedback has not remained unchanged for 120 seconds (%s seconds, %s matching sample(s)): %s\n' \
        "$elapsed" "$CURRENT_SAMPLES" "$URL" >&2
      pending=1
    fi
    if [ ! -e "$ASSESSMENT" ] && [ ! -L "$ASSESSMENT" ]; then
      printf 'pending: no review assessment recorded; run snapshot, assess every source, then record: %s\n' "$SNAPSHOT" >&2
      pending=1
    else
      fm_pr_private_file_valid "$ASSESSMENT" 600 "$DATA_DEVICE" \
        || unavailable "stored review assessment is not a private regular file"
      assessment_structurally_valid "$ASSESSMENT" \
        || unavailable "stored review assessment is invalid or lacks required evidence"
      if ! assessment_matches_snapshot "$ASSESSMENT"; then
        printf 'pending: review assessment is stale for current head, checks, or feedback: %s\n' "$URL" >&2
        report_stale_sources "$ASSESSMENT"
        pending=1
      else
        jq -r --slurpfile snapshot "$SNAPSHOT" --arg pr "$URL" '
          .sources[] | select(.disposition == "needs-action") as $assessment
          | ($snapshot[0].sources[] | select(.id == $assessment.id)) as $source
          | "pending: feedback needs action: \($source.url // $pr) [\($assessment.id)] \($assessment.rationale)"
        ' "$ASSESSMENT" > "$WORK/needs-action" 2>/dev/null \
          || unavailable "stored review dispositions could not be read"
        if [ -s "$WORK/needs-action" ]; then
          cat "$WORK/needs-action" >&2
          pending=1
        fi
      fi
    fi
    [ "$pending" -eq 0 ] || exit 1
    printf 'ready: %s head=%s review evidence=%s\n' "$URL" "$CURRENT_HEAD" "$ASSESSMENT"
    ;;
esac
