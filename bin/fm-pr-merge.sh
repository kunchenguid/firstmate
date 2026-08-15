#!/usr/bin/env bash
# ABOUTME: Records a task's canonical GitHub PR metadata and enforces the review-feedback gate.
# ABOUTME: Merges only past forge-confirmed inline resolution or a logged explicit human override.
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# --review-comments-override requires a non-empty human decision reason. It is
# consumed here, recorded before merge, and never forwarded to the forge.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--review-comments-override <reason>] [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2

OVERRIDE_SET=0
OVERRIDE_REASON=
forward_args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --review-comments-override)
      if [ "$OVERRIDE_SET" -eq 1 ] || [ "$#" -lt 2 ]; then
        echo "error: --review-comments-override requires one non-empty reason" >&2
        exit 2
      fi
      OVERRIDE_SET=1
      OVERRIDE_REASON=$2
      shift 2
      ;;
    --review-comments-override=*)
      if [ "$OVERRIDE_SET" -eq 1 ]; then
        echo "error: --review-comments-override may be supplied only once" >&2
        exit 2
      fi
      OVERRIDE_SET=1
      OVERRIDE_REASON=${1#*=}
      shift
      ;;
    --)
      shift
      forward_args+=("$@")
      break
      ;;
    *)
      forward_args+=("$1")
      shift
      ;;
  esac
done
set -- "${forward_args[@]+"${forward_args[@]}"}"

if [ "$OVERRIDE_SET" -eq 1 ]; then
  if [ -z "$OVERRIDE_REASON" ] || [[ "$OVERRIDE_REASON" =~ [[:cntrl:]] ]]; then
    echo "error: --review-comments-override requires a single-line non-empty reason" >&2
    exit 2
  fi
fi

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

# gh-axi renders every API response as TOON. A table's field positions are
# always read from that table's own header instead of assuming a key order.
TOON_COUNT=0
TOON_KEYS=

# Read a TOON table header such as `label[3]{a,b,c}:` into TOON_COUNT/TOON_KEYS.
toon_read_header() {
  local line=$1 label=$2
  [[ "$line" =~ ^"$label"\[([0-9]+)\]\{([A-Za-z0-9_]+(,[A-Za-z0-9_]+)*)\}:$ ]] || return 1
  TOON_COUNT=${BASH_REMATCH[1]}
  TOON_KEYS=${BASH_REMATCH[2]}
  [ "$TOON_COUNT" -ge 1 ] && [ "$TOON_COUNT" -le 100 ]
}

# Echo the named columns of one TOON data row, tab separated, resolving each
# name through TOON_KEYS so a reordered response cannot shift a field silently.
toon_read_row() {
  local row=$1
  shift
  local keys=() values=() out= want key index found
  case "$row" in
    '  '*) row=${row#  } ;;
    *) return 1 ;;
  esac
  IFS=, read -r -a keys <<< "$TOON_KEYS"
  IFS=, read -r -a values <<< "$row"
  [ "${#keys[@]}" -eq "${#values[@]}" ] || return 1
  for want in "$@"; do
    found=
    index=0
    for key in "${keys[@]}"; do
      if [ "$key" = "$want" ]; then
        found=${values[$index]}
        break
      fi
      index=$((index + 1))
    done
    case "$found" in
      \"*\") found=${found#\"}; found=${found%\"} ;;
    esac
    [ -n "$found" ] || return 1
    [ -z "$out" ] || out+=$'\t'
    out+=$found
  done
  printf '%s\n' "$out"
}

# Read every page of a paginated TOON list endpoint into FETCHED_RECORDS, one
# tab-separated record per row carrying the named columns in the order asked for.
FETCHED_RECORDS=
fetch_paged_records() {
  local endpoint=$1 jq_filter=$2
  shift 2
  local page=1 response rows row record seen
  FETCHED_RECORDS=
  while :; do
    response=$(gh-axi api "$endpoint?per_page=100&page=$page" --jq "$jq_filter") || return 1
    [ "$response" != "[]" ] || return 0
    toon_read_header "${response%%$'\n'*}" '' || return 1
    rows=${response#*$'\n'}
    seen=0
    while IFS= read -r row; do
      record=$(toon_read_row "$row" "$@") || return 1
      [ -z "$FETCHED_RECORDS" ] || FETCHED_RECORDS+=$'\n'
      FETCHED_RECORDS+=$record
      seen=$((seen + 1))
    done <<< "$rows"
    [ "$seen" -eq "$TOON_COUNT" ] || return 1
    [ "$TOON_COUNT" -eq 100 ] || return 0
    page=$((page + 1))
  done
}

# The blocking surface is deliberately narrow. It covers inline diff review
# comments from /pulls/<number>/comments whose forge thread is still unresolved,
# plus every review /pulls/<number>/reviews currently returns in a
# changes-requested state. The merge-past-feedback failure this gate exists to
# stop reached main as an unread inline review comment, which is exactly what
# that surface catches.
#
# Whole-PR conversation comments live on the distinct /issues/<number>/comments
# surface. They are fetched and printed in full so a human sees them, but they
# never block: that surface is dominated by automated notices -
# twilwa/session-bored#167 carried a review guide and a preview link - so
# blocking on it would fire on essentially every PR and train humans to override
# reflexively, which destroys the protection the block is here to provide.
#
# Feedback from bots counts exactly as feedback from people does, and severity
# badges in a comment body are never read as authority over what blocks.
INLINE_COMMENTS=
INLINE_API_FAILED=0
if fetch_paged_records "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER/comments" \
  '[.[] | {id, root_id: (.in_reply_to_id // .id), author: .user.login}]' \
  id root_id author; then
  INLINE_COMMENTS=$FETCHED_RECORDS
else
  INLINE_API_FAILED=1
fi

# GitHub returns the full review history in chronological order. COMMENTED and
# PENDING entries do not change a reviewer's standing verdict; APPROVED,
# CHANGES_REQUESTED, and DISMISSED do. Folding that history per reviewer honors
# dismissals and prevents a superseded change request from blocking forever.
CHANGES_REQUESTED_REVIEWS=
REVIEW_API_FAILED=0
CURRENT_REVIEW_VERDICTS=

derive_current_review_verdicts() {
  local records=$1 review_id review_state review_author extra
  local current_id current_state current_author current_extra updated
  CURRENT_REVIEW_VERDICTS=
  while IFS=$'\t' read -r review_id review_state review_author extra; do
    [ -n "$review_id" ] || continue
    [ -z "$extra" ] || return 1
    case "$review_id" in
      *[!0-9]*) return 1 ;;
    esac
    [ -n "$review_author" ] || return 1
    case "$review_state" in
      COMMENTED|PENDING)
        continue
        ;;
      APPROVED|CHANGES_REQUESTED|DISMISSED)
        ;;
      *)
        return 1
        ;;
    esac

    updated=
    while IFS=$'\t' read -r current_id current_state current_author current_extra; do
      [ -n "$current_id" ] || continue
      [ -z "$current_extra" ] || return 1
      [ "$current_author" = "$review_author" ] && continue
      [ -z "$updated" ] || updated+=$'\n'
      updated+="$current_id"$'\t'"$current_state"$'\t'"$current_author"
    done <<< "$CURRENT_REVIEW_VERDICTS"
    CURRENT_REVIEW_VERDICTS=$updated
    [ -z "$CURRENT_REVIEW_VERDICTS" ] || CURRENT_REVIEW_VERDICTS+=$'\n'
    CURRENT_REVIEW_VERDICTS+="$review_id"$'\t'"$review_state"$'\t'"$review_author"
  done <<< "$records"
}

if fetch_paged_records "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER/reviews" \
  '[.[] | {id, state, author: .user.login}]' id state author; then
  if derive_current_review_verdicts "$FETCHED_RECORDS"; then
    while IFS=$'\t' read -r review_id review_state review_author; do
      [ -n "$review_id" ] || continue
      [ "$review_state" = CHANGES_REQUESTED ] || continue
      [ -z "$CHANGES_REQUESTED_REVIEWS" ] || CHANGES_REQUESTED_REVIEWS+=$'\n'
      CHANGES_REQUESTED_REVIEWS+="$review_id"$'\t'"$review_author"
    done <<< "$CURRENT_REVIEW_VERDICTS"
  else
    REVIEW_API_FAILED=1
  fi
else
  REVIEW_API_FAILED=1
fi

# Pull requests are issues on GitHub. This REST endpoint covers whole-PR
# conversation comments, which are not returned by /pulls/<number>/comments.
CONVERSATION_COMMENTS=
CONVERSATION_API_FAILED=0
if fetch_paged_records "/repos/$PR_OWNER/$PR_REPO/issues/$PR_NUMBER/comments" \
  '[.[] | {id, author: .user.login}]' id author; then
  CONVERSATION_COMMENTS=$FETCHED_RECORDS
else
  CONVERSATION_API_FAILED=1
fi

# GitHub's REST review-comment representation has no resolved field. GraphQL's
# review thread is the forge evidence for isResolved and, separately,
# isOutdated. Outdated is never inferred from a missing position or commit.
THREAD_STATES=
THREAD_API_FAILED=0
if [ "$INLINE_API_FAILED" -eq 0 ] && [ -n "$INLINE_COMMENTS" ]; then
  REVIEW_THREADS_QUERY='query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $number) {
        reviewThreads(first: 100, after: $endCursor) {
          nodes {
            isResolved
            isOutdated
            comments(first: 1) { nodes { databaseId } }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }'
  fetch_thread_states() {
    local cursor=null previous_cursor= response end_cursor has_next
    local lines=() line index record root_id resolved outdated
    THREAD_STATES=
    while :; do
      response=$(gh-axi api POST graphql \
        --field owner="$PR_OWNER" \
        --field repo="$PR_REPO" \
        --field number="$PR_NUMBER" \
        --field endCursor="$cursor" \
        --field query="$REVIEW_THREADS_QUERY" \
        --jq '{end_cursor: .data.repository.pullRequest.reviewThreads.pageInfo.endCursor, has_next: .data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage, threads: [.data.repository.pullRequest.reviewThreads.nodes[] | {root_id: .comments.nodes[0].databaseId, resolved: .isResolved, outdated: .isOutdated}]}') || return 1
      lines=()
      while IFS= read -r line; do
        lines+=("$line")
      done <<< "$response"
      [ "${#lines[@]}" -ge 3 ] || return 1
      case "${lines[0]}" in
        'end_cursor: '*) end_cursor=${lines[0]#end_cursor: } ;;
        *) return 1 ;;
      esac
      case "${lines[1]}" in
        'has_next: true') has_next=true ;;
        'has_next: false') has_next=false ;;
        *) return 1 ;;
      esac
      if [ "${lines[2]}" = 'threads: []' ]; then
        TOON_COUNT=0
      else
        toon_read_header "${lines[2]}" threads || return 1
      fi
      [ "${#lines[@]}" -eq $((3 + TOON_COUNT)) ] || return 1
      index=0
      while [ "$index" -lt "$TOON_COUNT" ]; do
        record=$(toon_read_row "${lines[$((3 + index))]}" root_id resolved outdated) || return 1
        IFS=$'\t' read -r root_id resolved outdated <<< "$record"
        case "$root_id" in
          ''|*[!0-9]*) return 1 ;;
        esac
        case "$resolved:$outdated" in
          true:true|true:false|false:true|false:false) ;;
          *) return 1 ;;
        esac
        [ -z "$THREAD_STATES" ] || THREAD_STATES+=$'\n'
        THREAD_STATES+="$root_id"$'\t'"$resolved"$'\t'"$outdated"
        index=$((index + 1))
      done
      [ "$has_next" = true ] || return 0
      [ "$end_cursor" != null ] && [ -n "$end_cursor" ] \
        && [ "$end_cursor" != "$previous_cursor" ] || return 1
      previous_cursor=$end_cursor
      cursor=$end_cursor
    done
  }

  if ! fetch_thread_states; then
    THREAD_API_FAILED=1
  fi
fi

inline_thread_state() {
  local wanted_root=$1 root resolved outdated extra found=
  while IFS=$'\t' read -r root resolved outdated extra; do
    [ -n "$root" ] || continue
    [ "$root" = "$wanted_root" ] || continue
    [ -z "$extra" ] || return 1
    case "$resolved:$outdated" in
      true:true|true:false|false:true|false:false) ;;
      *) return 1 ;;
    esac
    [ -z "$found" ] || return 1
    found="$resolved:$outdated"
  done <<< "$THREAD_STATES"
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

print_feedback() {
  local surface=$1 state=$2 author=$3 url=$4 body_path=$5 body_output
  printf '  %s (%s) by @%s\n' "$surface" "$state" "$author" >&2
  printf '    %s\n' "$url" >&2
  printf '    body (complete, chunked at 1000 characters):\n' >&2
  if ! body_output=$(gh-axi api "$body_path" \
    --jq '{body_chunks: [range(0; ((.body // "") | length); 1000) as $offset | (.body // "")[$offset:$offset + 1000]]}'); then
    echo "    [feedback body unavailable because its API request failed]" >&2
    return 1
  fi
  printf '%s\n' "$body_output" >&2
}

REVIEW_GATE_BLOCKED=0
if [ "$INLINE_API_FAILED" -eq 1 ]; then
  echo "error: could not read inline review comments from /pulls/$PR_NUMBER/comments" >&2
  REVIEW_GATE_BLOCKED=1
fi
if [ "$REVIEW_API_FAILED" -eq 1 ]; then
  echo "error: could not read review states from /pulls/$PR_NUMBER/reviews" >&2
  REVIEW_GATE_BLOCKED=1
fi
if [ "$CONVERSATION_API_FAILED" -eq 1 ]; then
  echo "error: could not read PR conversation comments from /issues/$PR_NUMBER/comments" >&2
  REVIEW_GATE_BLOCKED=1
fi
if [ "$THREAD_API_FAILED" -eq 1 ]; then
  echo "error: could not read inline review thread resolution state" >&2
  REVIEW_GATE_BLOCKED=1
fi

if [ "$INLINE_API_FAILED" -eq 0 ] && [ -n "$INLINE_COMMENTS" ]; then
  UNRESOLVED_HEADER_PRINTED=0
  while IFS=$'\t' read -r comment_id root_id comment_author extra; do
    [ -n "$comment_id" ] || continue
    comment_url="$URL#discussion_r$comment_id"
    comment_body_path="/repos/$PR_OWNER/$PR_REPO/pulls/comments/$comment_id"
    thread_state=
    if [ "$THREAD_API_FAILED" -eq 0 ] \
      && thread_state=$(inline_thread_state "$root_id"); then
      case "$thread_state" in
        true:true|true:false|false:true)
          continue
          ;;
        false:false)
          if [ "$UNRESOLVED_HEADER_PRINTED" -eq 0 ]; then
            echo "error: unresolved inline review comments block merge:" >&2
            UNRESOLVED_HEADER_PRINTED=1
          fi
          print_feedback "inline review comment" "unresolved" \
            "$comment_author" "$comment_url" "$comment_body_path" || true
          REVIEW_GATE_BLOCKED=1
          continue
          ;;
      esac
    fi
    echo "error: inline review comment resolution state unavailable:" >&2
    print_feedback "inline review comment" "resolution state unavailable" \
      "$comment_author" "$comment_url" "$comment_body_path" || true
    REVIEW_GATE_BLOCKED=1
  done <<< "$INLINE_COMMENTS"
fi

# A reviewer's current changes-requested verdict blocks until that reviewer
# submits a later verdict, the review is dismissed, or a human logs the override.
if [ "$REVIEW_API_FAILED" -eq 0 ] && [ -n "$CHANGES_REQUESTED_REVIEWS" ]; then
  echo "error: reviews requesting changes block merge:" >&2
  while IFS=$'\t' read -r review_id review_author extra; do
    [ -n "$review_id" ] || continue
    review_url="$URL#pullrequestreview-$review_id"
    review_body_path="/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER/reviews/$review_id"
    print_feedback "changes-requested review" "changes requested" \
      "$review_author" "$review_url" "$review_body_path" || true
    REVIEW_GATE_BLOCKED=1
  done <<< "$CHANGES_REQUESTED_REVIEWS"
fi

# Conversation comments are surfaced in full for the human but do not block; see
# the blocking-surface rationale above. A body this path cannot retrieve is
# still an unread comment, so an unreadable one falls back to the blocked path.
if [ "$CONVERSATION_API_FAILED" -eq 0 ] && [ -n "$CONVERSATION_COMMENTS" ]; then
  echo "PR conversation comments on this PR (informational, not blocking):" >&2
  while IFS=$'\t' read -r comment_id comment_author extra; do
    [ -n "$comment_id" ] || continue
    comment_url="$URL#issuecomment-$comment_id"
    comment_body_path="/repos/$PR_OWNER/$PR_REPO/issues/comments/$comment_id"
    print_feedback "PR conversation comment" "informational" \
      "$comment_author" "$comment_url" "$comment_body_path" \
      || REVIEW_GATE_BLOCKED=1
  done <<< "$CONVERSATION_COMMENTS"
fi

if [ "$REVIEW_GATE_BLOCKED" -eq 1 ]; then
  if [ "$OVERRIDE_SET" -eq 0 ]; then
    echo "error: merge blocked; after a human decision, rerun with --review-comments-override <reason>" >&2
    exit 1
  fi
  STATUS="$STATE/$ID.status"
  if [ -L "$STATUS" ] || { [ -e "$STATUS" ] && [ ! -f "$STATUS" ]; }; then
    echo "error: cannot record the review-comments override in task status" >&2
    exit 1
  fi
  umask 077
  if ! printf 'note: merge review-comments override: pr=%s reason=%s\n' \
    "$URL" "$OVERRIDE_REASON" >> "$STATUS"; then
    echo "error: cannot record the review-comments override in task status" >&2
    exit 1
  fi
  echo "review-comments override recorded; proceeding with the human-authorized merge" >&2
elif [ "$OVERRIDE_SET" -eq 1 ]; then
  echo "note: review-comments override was supplied but no blocking feedback was found; it was not used" >&2
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
