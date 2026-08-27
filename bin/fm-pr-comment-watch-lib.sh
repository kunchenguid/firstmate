#!/usr/bin/env bash
# Shared owner for owner-PR review-thread monitoring and re-review readiness.
# Callers must not interpolate untrusted data into shell source; every forge
# response is parsed as data through jq.
#
# Contract:
# - Owner repositories: monalee-inc/artemis and pedromuller-del/firstmate.
# - Owner pull requests: GitHub pull requests whose author login is pedromuller-del.
# - An open review thread blocks re-review until the owner has an inline reply on
#   that thread and the thread is either resolved on GitHub or carries a recorded
#   defer in state/.pr-review-thread-defers/.
# - A recorded defer never substitutes for the inline reply.

FM_PCW_OWNER_AUTHOR=pedromuller-del
FM_PCW_OWNER_REPOS=(
  monalee-inc/artemis
  pedromuller-del/firstmate
)
if [ -n "${FM_PCW_OWNER_REPOS_OVERRIDE:-}" ]; then
  # Test-only narrowing of the owner repository set; production callers never set this.
  IFS=' ' read -ra FM_PCW_OWNER_REPOS <<< "$FM_PCW_OWNER_REPOS_OVERRIDE"
fi
FM_PCW_SNAPSHOT_BASENAME=.pr-comment-watch-snapshot.json
FM_PCW_DEFER_DIRNAME=.pr-review-thread-defers
# shellcheck disable=SC2034 # Consumed by scripts that source this library.
FM_PCW_SNAPSHOT_SCHEMA=fm-pr-comment-watch-snapshot-v1

FM_PCW_REPO_OWNER=
FM_PCW_REPO_NAME=
FM_PCW_PR_NUMBER=
FM_PCW_PR_URL=

fm_pcw_repo_valid() {
  local repo=${1-} candidate
  case "$repo" in
    */*) ;;
    *) return 1 ;;
  esac
  for candidate in "${FM_PCW_OWNER_REPOS[@]+"${FM_PCW_OWNER_REPOS[@]}"}"; do
    [ "$repo" = "$candidate" ] && return 0
  done
  return 1
}

fm_pcw_pr_url_parse() {
  local raw=${1-} pattern
  local LC_ALL=C
  FM_PCW_REPO_OWNER=
  FM_PCW_REPO_NAME=
  FM_PCW_PR_NUMBER=
  FM_PCW_PR_URL=
  pattern='^https://github\.com/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])/([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]*)$'
  [[ "$raw" =~ $pattern ]] || return 1
  [[ "${BASH_REMATCH[1]}" != *--* ]] || return 1
  [ "${BASH_REMATCH[2]}" != . ] && [ "${BASH_REMATCH[2]}" != .. ] || return 1
  fm_pcw_repo_valid "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}" || return 1
  # shellcheck disable=SC2034 # Outputs consumed by scripts that source this library.
  FM_PCW_REPO_OWNER=${BASH_REMATCH[1]}
  # shellcheck disable=SC2034 # Outputs consumed by scripts that source this library.
  FM_PCW_REPO_NAME=${BASH_REMATCH[2]}
  # shellcheck disable=SC2034 # Outputs consumed by scripts that source this library.
  FM_PCW_PR_NUMBER=${BASH_REMATCH[3]}
  FM_PCW_PR_URL=$raw
}

fm_pcw_defer_root() {
  local state=$1
  printf '%s/%s\n' "$state" "$FM_PCW_DEFER_DIRNAME"
}

fm_pcw_path_has_no_symlink_components() {
  local path=$1 logical rest component current=/
  logical=$(CDPATH='' cd -L -- "$path" 2>/dev/null && pwd -L) || return 1
  case "$logical" in
    /*) ;;
    *) return 1 ;;
  esac
  rest=${logical#/}
  while [ -n "$rest" ]; do
    component=${rest%%/*}
    if [ "$rest" = "$component" ]; then
      rest=
    else
      rest=${rest#*/}
    fi
    current="${current%/}/$component"
    [ -d "$current" ] && [ ! -L "$current" ] || return 1
  done
}

fm_pcw_path_within_home() {
  local path=$1 home=$2 allow_home=${3:-0} home_logical home_real path_logical path_real relative
  [ -d "$home" ] && [ ! -L "$home" ] || return 1
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  fm_pcw_path_has_no_symlink_components "$home" || return 1
  fm_pcw_path_has_no_symlink_components "$path" || return 1
  home_logical=$(CDPATH='' cd -L -- "$home" 2>/dev/null && pwd -L) || return 1
  home_real=$(CDPATH='' cd -P -- "$home" 2>/dev/null && pwd -P) || return 1
  path_logical=$(CDPATH='' cd -L -- "$path" 2>/dev/null && pwd -L) || return 1
  path_real=$(CDPATH='' cd -P -- "$path" 2>/dev/null && pwd -P) || return 1
  case "$path_logical" in
    "$home_logical")
      [ "$allow_home" = 1 ] || return 1
      [ "$path_real" = "$home_real" ]
      return
      ;;
    "$home_logical"/*) relative=${path_logical#"$home_logical"/} ;;
    *) return 1 ;;
  esac
  [ "$path_real" = "$home_real/$relative" ]
}

fm_pcw_state_valid() {
  local state=$1 home=$2 state_device home_device
  fm_pcw_path_within_home "$state" "$home" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  [ "$(fm_pr_file_mode "$state")" = 700 ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  home_device=$(fm_pr_file_device "$home") || return 1
  [ "$state_device" = "$home_device" ]
}

fm_pcw_state_prepare() {
  local state=$1 home=$2 parent
  parent=$(dirname -- "$state") || return 1
  fm_pcw_path_within_home "$parent" "$home" 1 || return 1
  if [ ! -e "$state" ] && [ ! -L "$state" ]; then
    (umask 077; mkdir -- "$state") || return 1
  fi
  fm_pcw_state_valid "$state" "$home"
}

fm_pcw_defer_root_valid() {
  local state=$1 home=$2 root device
  fm_pcw_state_valid "$state" "$home" || return 1
  root=$(fm_pcw_defer_root "$state") || return 1
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  device=$(fm_pr_file_device "$state") || return 1
  [ "$(fm_pr_file_device "$root")" = "$device" ] || return 1
  [ "$(fm_pr_file_mode "$root")" = 700 ]
}

fm_pcw_defer_root_prepare() {
  local state=$1 home=$2 root
  fm_pcw_state_prepare "$state" "$home" || return 1
  root=$(fm_pcw_defer_root "$state") || return 1
  if [ ! -e "$root" ] && [ ! -L "$root" ]; then
    (umask 077; mkdir -- "$root") || return 1
  fi
  fm_pcw_defer_root_valid "$state" "$home"
}

fm_pcw_defer_file() {
  local state=$1 owner=$2 name=$3 number=$4
  printf '%s/%s__%s__%s.tsv\n' "$(fm_pcw_defer_root "$state")" "$owner" "$name" "$number"
}

fm_pcw_defer_record() {
  local state=$1 home=$2 thread_id=$3 owner=$4 name=$5 number=$6 ts=$7
  local root file tmp device
  case "$thread_id" in
    ''|*[!A-Za-z0-9:_-]*) return 1 ;;
  esac
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  root=$(fm_pcw_defer_root "$state") || return 1
  fm_pcw_defer_root_prepare "$state" "$home" || return 1
  file=$(fm_pcw_defer_file "$state" "$owner" "$name" "$number")
  device=$(fm_pr_file_device "$state") || return 1
  if [ -e "$file" ] || [ -L "$file" ]; then
    fm_pr_private_file_valid "$file" 600 "$device" || return 1
  fi
  umask 077
  tmp=$(mktemp "$state/.fm-pcw-defer.XXXXXX") || return 1
  if [ -f "$file" ]; then
    awk -F '\t' -v id="$thread_id" '$1 != id' "$file" > "$tmp" 2>/dev/null \
      || { rm -f -- "$tmp"; return 1; }
  else
    : >"$tmp"
  fi
  printf '%s\t%s\n' "$thread_id" "$ts" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_pr_private_file_valid "$tmp" 600 "$device" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
  fm_pr_private_file_valid "$file" 600 "$device"
}

fm_pcw_defer_has() {
  local state=$1 home=$2 thread_id=$3 owner=$4 name=$5 number=$6
  local file device
  fm_pcw_defer_root_valid "$state" "$home" || return 1
  file=$(fm_pcw_defer_file "$state" "$owner" "$name" "$number")
  device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$file" 600 "$device" || return 1
  awk -F '\t' -v id="$thread_id" '$1 == id { found=1 } END { exit !found }' "$file" 2>/dev/null
}

fm_pcw_threads_query() {
  cat <<'GRAPHQL'
query FmPrCommentWatchThreads($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      author { login }
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          comments(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes { id createdAt updatedAt author { login } }
          }
        }
      }
    }
  }
}
GRAPHQL
}

fm_pcw_comments_query() {
  cat <<'GRAPHQL'
query FmPrCommentWatchComments($id: ID!, $cursor: String) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      id
      comments(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { id createdAt updatedAt author { login } }
      }
    }
  }
}
GRAPHQL
}

fm_pcw_cursor_seen() {
  local candidate=$1 seen
  shift
  for seen in "$@"; do
    [ "$candidate" = "$seen" ] && return 0
  done
  return 1
}

fm_pcw_fetch_pr_payload() {
  local owner=$1 name=$2 number=$3
  shift 3
  local gh_cmd=${1:-gh}
  if [ $# -gt 0 ]; then shift; fi
  local payload cursor='' page all='[]' has_next thread_index thread_id comments comment_page
  local expected_author=${FM_PCW_OWNER_AUTHOR:?}
  local -a query_args thread_cursors=() comment_cursors=()
  while :; do
    query_args=(
      -f query="$(fm_pcw_threads_query)" \
      -f owner="$owner" \
      -f name="$name" \
      -F number="$number"
    )
    if [ -n "$cursor" ]; then
      query_args+=(-f cursor="$cursor")
    fi
    payload=$("$gh_cmd" api graphql "${query_args[@]+"${query_args[@]}"}" "$@") || return 1
    printf '%s' "$payload" | jq -e --arg expected_author "$expected_author" '
      def valid_page_info:
        type == "object" and
        (.hasNextPage | type == "boolean") and
        has("endCursor") and
        (if .hasNextPage then
          (.endCursor | type == "string" and length > 0)
        else
          (.endCursor == null) or (.endCursor | type == "string" and length > 0)
        end);
      (.data.repository | type == "object") and
      (.data.repository.pullRequest | type == "object") and
      (.data.repository.pullRequest.author.login | type == "string" and length > 0) and
      ((.data.repository.pullRequest.author.login | ascii_downcase) == ($expected_author | ascii_downcase)) and
      (.data.repository.pullRequest.reviewThreads | type == "object") and
      (.data.repository.pullRequest.reviewThreads.pageInfo | valid_page_info) and
      (.data.repository.pullRequest.reviewThreads.nodes | type == "array") and
      all(.data.repository.pullRequest.reviewThreads.nodes[];
        (.comments | type == "object") and
        (.comments.pageInfo | valid_page_info) and
        (.comments.nodes | type == "array") and
        all(.comments.nodes[];
          (.id | type == "string" and length > 0) and
          (.createdAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
          (.updatedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
          (.author.login | type == "string" and length > 0)))
    ' >/dev/null 2>&1 || return 1
    page=$(printf '%s' "$payload" | jq -c '.data.repository.pullRequest.reviewThreads') || return 1
    all=$(jq -cn --argjson old "$all" --argjson new "$(printf '%s' "$page" | jq -c '.nodes')" '$old + $new') || return 1
    has_next=$(printf '%s' "$page" | jq -r '.pageInfo.hasNextPage // false') || return 1
    [ "$has_next" = true ] || break
    cursor=$(printf '%s' "$page" | jq -r '.pageInfo.endCursor // empty') || return 1
    [ -n "$cursor" ] || return 1
    fm_pcw_cursor_seen "$cursor" "${thread_cursors[@]+"${thread_cursors[@]}"}" && return 1
    thread_cursors+=("$cursor")
  done

  for ((thread_index = 0; thread_index < $(printf '%s' "$all" | jq 'length'); thread_index++)); do
    comment_cursors=()
    has_next=$(printf '%s' "$all" | jq -r ".[$thread_index].comments.pageInfo.hasNextPage // false") || return 1
    cursor=$(printf '%s' "$all" | jq -r ".[$thread_index].comments.pageInfo.endCursor // empty") || return 1
    thread_id=$(printf '%s' "$all" | jq -r ".[$thread_index].id // empty") || return 1
    [ -n "$thread_id" ] || return 1
    while [ "$has_next" = true ]; do
      [ -n "$cursor" ] || return 1
      fm_pcw_cursor_seen "$cursor" "${comment_cursors[@]+"${comment_cursors[@]}"}" && return 1
      comment_cursors+=("$cursor")
      comment_page=$("$gh_cmd" api graphql \
        -f query="$(fm_pcw_comments_query)" \
        -f id="$thread_id" \
        -f cursor="$cursor" \
        "$@") || return 1
      printf '%s' "$comment_page" | jq -e --arg thread_id "$thread_id" '
        def valid_page_info:
          type == "object" and
          (.hasNextPage | type == "boolean") and
          has("endCursor") and
          (if .hasNextPage then
            (.endCursor | type == "string" and length > 0)
          else
            (.endCursor == null) or (.endCursor | type == "string" and length > 0)
          end);
        (.data.node | type == "object") and
        (.data.node.id == $thread_id) and
        (.data.node.comments | type == "object") and
        (.data.node.comments.pageInfo | valid_page_info) and
        (.data.node.comments.nodes | type == "array") and
        all(.data.node.comments.nodes[];
          (.id | type == "string" and length > 0) and
          (.createdAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
          (.updatedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
          (.author.login | type == "string" and length > 0))
      ' >/dev/null 2>&1 || return 1
      comments=$(printf '%s' "$comment_page" | jq -c '.data.node.comments') || return 1
      all=$(jq -cn --argjson rows "$all" --argjson more "$(printf '%s' "$comments" | jq -c '.nodes')" \
        --argjson index "$thread_index" '$rows | .[$index].comments.nodes += $more') || return 1
      has_next=$(printf '%s' "$comments" | jq -r '.pageInfo.hasNextPage // false') || return 1
      cursor=$(printf '%s' "$comments" | jq -r '.pageInfo.endCursor // empty') || return 1
    done
  done

  jq -cn \
    --argjson repository "$(printf '%s' "$payload" | jq -c '.data.repository')" \
    --argjson threads "$all" \
    '{data:{repository:($repository | .pullRequest.reviewThreads.nodes = $threads)}}'
}

fm_pcw_build_pr_record() {
  local state=$1 home=$2 author=$3 owner=$4 name=$5 number=$6 payload=$7
  local pr_author author_lc threads_json enriched tid row deferred
  printf '%s' "$payload" | jq -e '
    (.data.repository | type == "object") and
    (.data.repository.pullRequest | type == "object") and
    (.data.repository.pullRequest.author.login | type == "string" and length > 0) and
    (.data.repository.pullRequest.reviewThreads | type == "object") and
    (.data.repository.pullRequest.reviewThreads.nodes | type == "array") and
    all(.data.repository.pullRequest.reviewThreads.nodes[];
      (.id | type == "string" and length > 0) and
      (.isResolved | type == "boolean") and
      (.comments | type == "object") and
      (.comments.nodes | type == "array") and
      all(.comments.nodes[];
        (.id | type == "string" and length > 0) and
        (.createdAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
        (.updatedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
        (.author.login | type == "string" and length > 0)))
  ' >/dev/null 2>&1 || return 1
  pr_author=$(printf '%s' "$payload" | jq -r '.data.repository.pullRequest.author.login' 2>/dev/null) || return 1
  [ -n "$pr_author" ] || return 1
  [ "$(printf '%s' "$pr_author" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$author" | tr '[:upper:]' '[:lower:]')" ] || return 2
  author_lc=$(printf '%s' "$author" | tr '[:upper:]' '[:lower:]')
  threads_json=$(printf '%s' "$payload" | jq -c --arg author_lc "$author_lc" '
    [.data.repository.pullRequest.reviewThreads.nodes[]? |
      (.comments.nodes | sort_by(.createdAt, .id)) as $comments |
      ([range(0; ($comments | length)) |
        select(($comments[.].author.login | ascii_downcase) != $author_lc)] | last) as $reviewer_index |
      {
        id: .id,
        isResolved: (.isResolved == true),
        reviewer: (if $reviewer_index == null then "" else $comments[$reviewer_index].author.login end),
        commentRevisions: [.comments.nodes[] | {id: (.id // ""), updatedAt: (.updatedAt // "")}],
        ownerReply: ($reviewer_index == null or
          any(range($reviewer_index + 1; ($comments | length));
            ($comments[.].author.login | ascii_downcase) == $author_lc))
      }]
  ' 2>/dev/null) || return 1
  enriched='[]'
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    tid=$(printf '%s' "$row" | jq -r '.id')
    if fm_pcw_defer_has "$state" "$home" "$tid" "$owner" "$name" "$number"; then
      deferred=true
    else
      deferred=false
    fi
    enriched=$(printf '%s' "$enriched" | jq -c --argjson row "$row" --argjson deferred "$deferred" \
      '. + [($row + {deferred:$deferred})]')
  done < <(printf '%s' "$threads_json" | jq -c '.[]?')
  jq -cn \
    --arg owner "$owner" \
    --arg name "$name" \
    --argjson number "$number" \
    --arg url "https://github.com/$owner/$name/pull/$number" \
    --argjson threads "$enriched" \
    '{owner:$owner, name:$name, number:$number, url:$url, threads:$threads}'
}

fm_pcw_record_blocks_rereview() {
  local record=$1 count
  count=$(printf '%s' "$record" | jq '[.threads[] | select((.ownerReply|not) or ((.isResolved|not) and (.deferred|not)))] | length' 2>/dev/null) || return 1
  [ "${count:-0}" -gt 0 ]
}

fm_pcw_record_digest() {
  local record=$1
  printf '%s' "$record" | jq -c '
    {
      owner, name, number,
      threads: [
        .threads[] |
        {
          id,
          isResolved,
          ownerReply,
          deferred,
          commentRevisions: [.commentRevisions[] | {id, updatedAt}] | sort_by(.id)
        }
      ] | sort_by(.id)
    }
  ' 2>/dev/null
}

fm_pcw_thread_reviewer() {
  local owner=$1 name=$2 number=$3 thread_id=$4 gh_cmd=${5:-gh} payload
  case "$thread_id" in ''|*[!A-Za-z0-9:_-]*) return 1 ;; esac
  payload=$(fm_pcw_fetch_pr_payload "$owner" "$name" "$number" "$gh_cmd") || return 1
  printf '%s' "$payload" | jq -er --arg id "$thread_id" --arg owner "$FM_PCW_OWNER_AUTHOR" '
    [.data.repository.pullRequest.reviewThreads.nodes[] | select(.id == $id) |
      .comments.nodes[] | select((.author.login | ascii_downcase) != ($owner | ascii_downcase)) |
      .author.login] | first // empty
  ' 2>/dev/null
}

fm_pcw_reviewer_eligible() {
  local reviewer=$1 allowlist=",${FM_PCW_REREQUEST_BOT_ALLOWLIST:-},"
  [ -n "$reviewer" ] || return 1
  case "$reviewer" in
    *'[bot]') case "$allowlist" in *,"$reviewer",*) return 0 ;; *) return 1 ;; esac ;;
  esac
}

fm_pcw_request_reviewer() {
  local owner=$1 name=$2 number=$3 reviewer=$4 gh_cmd=${5:-gh} pending
  fm_pcw_repo_valid "$owner/$name" || return 1
  pending=$("$gh_cmd" api "repos/$owner/$name/pulls/$number/requested_reviewers" 2>/dev/null) || return 1
  printf '%s' "$pending" | jq -e --arg reviewer "$reviewer" \
    '[(.users // [])[].login] | index($reviewer) | not' >/dev/null 2>&1 || return 0
  "$gh_cmd" api --method POST "repos/$owner/$name/pulls/$number/requested_reviewers" -f "reviewers[]=$reviewer" >/dev/null
}

fm_pcw_snapshot_path() {
  local state=$1
  printf '%s/%s\n' "$state" "$FM_PCW_SNAPSHOT_BASENAME"
}

fm_pcw_poll_shim_content() {
  local home=$1 root=$2
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-pr-comment-watch.sh - owner PR review-thread poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted poll script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$root/bin/fm-pr-comment-watch.sh") poll"
}

fm_pcw_forge_command_is_rereview_request() {
  local arg
  [ $# -ge 3 ] || return 1
  case "${1##*/}" in
    gh|gh-axi) ;;
    *) return 1 ;;
  esac
  [ "$2" = pr ] || return 1
  case "$3" in
    ready|request-review) return 0 ;;
    edit)
      shift 3
      for arg in "$@"; do
        case "$arg" in
          --add-reviewer|--add-reviewer=*) return 0 ;;
        esac
      done
      return 1
      ;;
    *) return 1 ;;
  esac
}

fm_pcw_extract_pr_url_from_forge_argv() {
  local arg repo='' number='' url
  # shellcheck disable=SC2034 # Output consumed by scripts that source this library.
  FM_PCW_PR_URL=
  [ $# -ge 3 ] || return 1
  shift 3
  while [ $# -gt 0 ]; do
    arg=$1
    case "$arg" in
      --repo|-R)
        [ $# -ge 2 ] || return 1
        repo=$2
        shift 2
        ;;
      --repo=*)
        repo=${arg#--repo=}
        shift
        ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 1
  arg=$1
  case "$arg" in
    https://github.com/*)
      fm_pcw_pr_url_parse "$arg" || return 1
      return 0
      ;;
    [1-9]*)
      case "$arg" in
        *[!0-9]*) return 1 ;;
        *) number=$arg ;;
      esac
      ;;
    *) return 1 ;;
  esac
  if [ -n "$repo" ] && [ -n "$number" ]; then
    url="https://github.com/$repo/pull/$number"
    if fm_pcw_pr_url_parse "$url"; then
      return 0
    fi
  fi
  return 1
}
