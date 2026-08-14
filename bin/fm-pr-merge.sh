#!/usr/bin/env bash
# ABOUTME: Records a task's canonical GitHub PR metadata and enforces review-feedback gates.
# ABOUTME: Merges only after forge resolution evidence or a logged explicit human override.
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

# The REST pulls endpoint covers inline diff review comments. It is distinct
# from the issues endpoint below and does not report thread resolution state.
INLINE_COMMENTS=
INLINE_API_FAILED=0

fetch_inline_comments() {
  local page=1 response header count row author comment_id root_id extra seen
  INLINE_COMMENTS=
  while :; do
    response=$(gh-axi api "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER/comments?per_page=100&page=$page" \
      --jq '[.[] | {id, root_id: (.in_reply_to_id // .id), author: .user.login}]') || return 1
    [ "$response" != "[]" ] || return 0
    header=${response%%$'\n'*}
    [[ "$header" =~ ^\[([0-9]+)\]\{author,id,root_id\}:$ ]] || return 1
    count=${BASH_REMATCH[1]}
    [ "$count" -ge 1 ] && [ "$count" -le 100 ] || return 1
    response=${response#*$'\n'}
    seen=0
    while IFS= read -r row; do
      case "$row" in
        '  '*) row=${row#  } ;;
        *) return 1 ;;
      esac
      IFS=, read -r author comment_id root_id extra <<< "$row"
      [ -z "$extra" ] || return 1
      case "$comment_id$root_id" in
        ''|*[!0-9]*) return 1 ;;
      esac
      case "$author" in
        \"*\") author=${author#\"}; author=${author%\"} ;;
      esac
      [ -n "$author" ] || return 1
      [ -z "$INLINE_COMMENTS" ] || INLINE_COMMENTS+=$'\n'
      INLINE_COMMENTS+="$comment_id"$'\t'"$root_id"$'\t'"$author"
      seen=$((seen + 1))
    done <<< "$response"
    [ "$seen" -eq "$count" ] || return 1
    [ "$count" -eq 100 ] || return 0
    page=$((page + 1))
  done
}

if ! fetch_inline_comments; then
  INLINE_API_FAILED=1
fi

# Pull requests are issues on GitHub. This REST endpoint covers whole-PR
# conversation comments, which are not returned by /pulls/<number>/comments.
CONVERSATION_COMMENTS=
CONVERSATION_API_FAILED=0

fetch_conversation_comments() {
  local page=1 response header count row author comment_id extra seen
  CONVERSATION_COMMENTS=
  while :; do
    response=$(gh-axi api "/repos/$PR_OWNER/$PR_REPO/issues/$PR_NUMBER/comments?per_page=100&page=$page" \
      --jq '[.[] | {id, author: .user.login}]') || return 1
    [ "$response" != "[]" ] || return 0
    header=${response%%$'\n'*}
    [[ "$header" =~ ^\[([0-9]+)\]\{author,id\}:$ ]] || return 1
    count=${BASH_REMATCH[1]}
    [ "$count" -ge 1 ] && [ "$count" -le 100 ] || return 1
    response=${response#*$'\n'}
    seen=0
    while IFS= read -r row; do
      case "$row" in
        '  '*) row=${row#  } ;;
        *) return 1 ;;
      esac
      IFS=, read -r author comment_id extra <<< "$row"
      [ -z "$extra" ] || return 1
      case "$comment_id" in
        ''|*[!0-9]*) return 1 ;;
      esac
      case "$author" in
        \"*\") author=${author#\"}; author=${author%\"} ;;
      esac
      [ -n "$author" ] || return 1
      [ -z "$CONVERSATION_COMMENTS" ] || CONVERSATION_COMMENTS+=$'\n'
      CONVERSATION_COMMENTS+="$comment_id"$'\t'"$author"
      seen=$((seen + 1))
    done <<< "$response"
    [ "$seen" -eq "$count" ] || return 1
    [ "$count" -eq 100 ] || return 0
    page=$((page + 1))
  done
}

if ! fetch_conversation_comments; then
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
    local cursor=null previous_cursor= response end_line next_line threads_line
    local end_cursor has_next count index row outdated resolved root_id extra
    THREAD_STATES=
    while :; do
      response=$(gh-axi api POST graphql \
        --field owner="$PR_OWNER" \
        --field repo="$PR_REPO" \
        --field number="$PR_NUMBER" \
        --field endCursor="$cursor" \
        --field query="$REVIEW_THREADS_QUERY" \
        --jq '{end_cursor: .data.repository.pullRequest.reviewThreads.pageInfo.endCursor, has_next: .data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage, threads: [.data.repository.pullRequest.reviewThreads.nodes[] | {root_id: .comments.nodes[0].databaseId, resolved: .isResolved, outdated: .isOutdated}]}') || return 1
      exec 7<<< "$response"
      IFS= read -r end_line <&7 || { exec 7<&-; return 1; }
      IFS= read -r next_line <&7 || { exec 7<&-; return 1; }
      IFS= read -r threads_line <&7 || { exec 7<&-; return 1; }
      case "$end_line" in
        'end_cursor: '*) end_cursor=${end_line#end_cursor: } ;;
        *) exec 7<&-; return 1 ;;
      esac
      case "$next_line" in
        'has_next: true') has_next=true ;;
        'has_next: false') has_next=false ;;
        *) exec 7<&-; return 1 ;;
      esac
      if [ "$threads_line" = 'threads: []' ]; then
        count=0
      elif [[ "$threads_line" =~ ^threads\[([0-9]+)\]\{outdated,resolved,root_id\}:$ ]]; then
        count=${BASH_REMATCH[1]}
        [ "$count" -ge 1 ] && [ "$count" -le 100 ] || { exec 7<&-; return 1; }
      else
        exec 7<&-
        return 1
      fi
      index=0
      while [ "$index" -lt "$count" ]; do
        IFS= read -r row <&7 || { exec 7<&-; return 1; }
        case "$row" in
          '  '*) row=${row#  } ;;
          *) exec 7<&-; return 1 ;;
        esac
        IFS=, read -r outdated resolved root_id extra <<< "$row"
        [ -z "$extra" ] || { exec 7<&-; return 1; }
        case "$root_id" in
          ''|*[!0-9]*) exec 7<&-; return 1 ;;
        esac
        case "$resolved:$outdated" in
          true:true|true:false|false:true|false:false) ;;
          *) exec 7<&-; return 1 ;;
        esac
        [ -z "$THREAD_STATES" ] || THREAD_STATES+=$'\n'
        THREAD_STATES+="$root_id"$'\t'"$resolved"$'\t'"$outdated"
        index=$((index + 1))
      done
      if IFS= read -r extra <&7 && [ -n "$extra" ]; then
        exec 7<&-
        return 1
      fi
      exec 7<&-
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

print_review_comment() {
  local surface=$1 state=$2 author=$3 url=$4 body_path=$5 body_output
  printf '  %s (%s) by @%s\n' "$surface" "$state" "$author" >&2
  printf '    %s\n' "$url" >&2
  printf '    body (complete, chunked at 1000 characters):\n' >&2
  if ! body_output=$(gh-axi api "$body_path" \
    --jq '{body_chunks: [range(0; ((.body // "") | length); 1000) as $offset | (.body // "")[$offset:$offset + 1000]]}'); then
    echo "    [comment body unavailable because its API request failed]" >&2
    return 1
  fi
  printf '%s\n' "$body_output" >&2
}

REVIEW_GATE_BLOCKED=0
if [ "$INLINE_API_FAILED" -eq 1 ]; then
  echo "error: could not read inline review comments from /pulls/$PR_NUMBER/comments" >&2
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
          print_review_comment "inline review comment" "unresolved" \
            "$comment_author" "$comment_url" "$comment_body_path" || true
          REVIEW_GATE_BLOCKED=1
          continue
          ;;
      esac
    fi
    echo "error: inline review comment resolution state unavailable:" >&2
    print_review_comment "inline review comment" "resolution state unavailable" \
      "$comment_author" "$comment_url" "$comment_body_path" || true
    REVIEW_GATE_BLOCKED=1
  done <<< "$INLINE_COMMENTS"
fi

# GitHub exposes no resolved or outdated state for whole-PR conversation
# comments. Each one therefore remains blocking unless a human explicitly
# supplies the logged override; authors and body badges never change that.
if [ "$CONVERSATION_API_FAILED" -eq 0 ] && [ -n "$CONVERSATION_COMMENTS" ]; then
  echo "error: PR conversation comments have no resolution state and block merge:" >&2
  while IFS=$'\t' read -r comment_id comment_author extra; do
    [ -n "$comment_id" ] || continue
    comment_url="$URL#issuecomment-$comment_id"
    comment_body_path="/repos/$PR_OWNER/$PR_REPO/issues/comments/$comment_id"
    print_review_comment "PR conversation comment" "resolution state unavailable" \
      "$comment_author" "$comment_url" "$comment_body_path" || true
    REVIEW_GATE_BLOCKED=1
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
