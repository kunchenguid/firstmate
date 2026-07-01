#!/usr/bin/env bash
# Poll PR-linked tasks for new GitHub PR comments/reviews and inject them into
# the owning crewmate with fm-send. Intended to be called by state/pr-comments.check.sh
# (created by fm-pr-comments.sh enable), but safe to run by hand.
# Usage: fm-pr-comments-poll.sh [--enabled|--all|--task <id>] [--prime]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
STORE="$STATE/.pr-comments"
SEEN_DIR="$STORE/seen"
ERR_DIR="$STORE/errors"
LOCK_DIR="$STORE/locks"
ENABLED_DIR="$STORE/enabled"
GH_CMD=${FM_PR_COMMENTS_GH:-gh}
SEND_CMD=${FM_PR_COMMENTS_SEND:-$FM_ROOT/bin/fm-send.sh}
SELF_LOGIN=${FM_PR_COMMENTS_SELF_LOGIN-}
IGNORE_AUTH_USER=${FM_PR_COMMENTS_IGNORE_AUTH_USER:-1}
MAX_BODY_CHARS=${FM_PR_COMMENTS_MAX_BODY_CHARS:-12000}
MODE=enabled
PRIME=0
TASK=

usage() {
  cat <<'EOF'
Usage: fm-pr-comments-poll.sh [--enabled|--all|--task <id>] [--prime]

Poll GitHub for issue comments, PR review comments, and PR review bodies on
PR-linked tasks. New comments are delivered to the task window with fm-send and
recorded in state/.pr-comments/seen/<id>.seen only after successful delivery.
--prime records currently visible comments as seen without injecting them.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --enabled) MODE=enabled; shift ;;
    --all) MODE=all; shift ;;
    --task) MODE=task; TASK=${2:-}; [ -n "$TASK" ] || { usage >&2; exit 2; }; shift 2 ;;
    --prime) PRIME=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

mkdir -p "$SEEN_DIR" "$ERR_DIR" "$LOCK_DIR" "$ENABLED_DIR"

need_tool() {
  command -v "$1" >/dev/null 2>&1
}

emit_error_once() {
  local key=$1 msg=$2 marker
  marker="$ERR_DIR/$(printf '%s' "$key" | tr '/: ' '____')"
  if [ ! -e "$marker" ] || [ "$(cat "$marker" 2>/dev/null)" != "$msg" ]; then
    printf '%s\n' "$msg" > "$marker"
    printf '%s\n' "$msg"
  fi
}

clear_error() {
  local key=$1 marker
  marker="$ERR_DIR/$(printf '%s' "$key" | tr '/: ' '____')"
  rm -f "$marker" 2>/dev/null || true
}

parse_pr_url() {
  # Echo owner<TAB>repo<TAB>number for canonical GitHub PR URLs.
  local url=$1 rest owner repo num
  case "$url" in
    https://github.com/*/pull/*|http://github.com/*/pull/*) ;;
    *) return 1 ;;
  esac
  rest=${url#*github.com/}
  owner=${rest%%/*}; rest=${rest#*/}
  repo=${rest%%/*}; rest=${rest#*/}
  [ "${rest%%/*}" = pull ] || return 1
  rest=${rest#pull/}
  num=${rest%%[/?#]*}
  case "$owner:$repo:$num" in *$'\n'*|*' '*|*::*|*:|::* ) return 1 ;; esac
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\t%s\t%s\n' "$owner" "$repo" "$num"
}

meta_value() {
  local key=$1 file=$2
  grep "^$key=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

all_pr_tasks() {
  local meta id pr window
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    pr=$(meta_value pr "$meta")
    window=$(meta_value window "$meta")
    [ -n "$pr" ] && [ -n "$window" ] || continue
    printf '%s\n' "$id"
  done
}

enabled_tasks() {
  local f id seen=
  if [ -e "$ENABLED_DIR/all" ]; then
    all_pr_tasks
    return 0
  fi
  for f in "$ENABLED_DIR"/*; do
    [ -e "$f" ] || continue
    id=$(basename "$f")
    case "$seen" in *"|$id|"*) continue ;; esac
    seen="$seen|$id|"
    [ -f "$STATE/$id.meta" ] || continue
    [ -n "$(meta_value pr "$STATE/$id.meta")" ] || continue
    [ -n "$(meta_value window "$STATE/$id.meta")" ] || continue
    printf '%s\n' "$id"
  done
}

selected_tasks() {
  case "$MODE" in
    all) all_pr_tasks ;;
    task) printf '%s\n' "$TASK" ;;
    enabled) enabled_tasks ;;
  esac
}

json_lines_for_pr() {
  local owner=$1 repo=$2 num=$3 endpoint
  endpoint="/repos/$owner/$repo/issues/$num/comments"
  "$GH_CMD" api --paginate "$endpoint" --jq '.[] | {type:"issue_comment", id:(.id|tostring), author:(.user.login // ""), url:(.html_url // ""), path:"", line:"", state:"", body:(.body // "")} | @json'
  endpoint="/repos/$owner/$repo/pulls/$num/comments"
  "$GH_CMD" api --paginate "$endpoint" --jq '.[] | {type:"review_comment", id:(.id|tostring), author:(.user.login // ""), url:(.html_url // ""), path:(.path // ""), line:((.line // .original_line // .position // "")|tostring), state:"", body:(.body // "")} | @json'
  endpoint="/repos/$owner/$repo/pulls/$num/reviews"
  "$GH_CMD" api --paginate "$endpoint" --jq '.[] | {type:"review", id:(.id|tostring), author:(.user.login // ""), url:(.html_url // ""), path:"", line:"", state:(.state // ""), body:(.body // "")} | @json'
}

is_ignored_author() {
  local author=$1 lower self_lower
  lower=$(printf '%s' "$author" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    ''|*'[bot]'|github-actions*|dependabot*|renovate*) return 0 ;;
  esac
  if [ "$IGNORE_AUTH_USER" != 0 ] && [ -n "$SELF_LOGIN" ]; then
    self_lower=$(printf '%s' "$SELF_LOGIN" | tr '[:upper:]' '[:lower:]')
    [ "$lower" = "$self_lower" ] && return 0
  fi
  return 1
}

truncate_body() {
  awk -v max="$MAX_BODY_CHARS" 'BEGIN { body="" } { body = body (NR == 1 ? "" : "\n") $0 } END { if (length(body) > max) print substr(body, 1, max) "\n...[truncated]"; else print body }'
}

format_message() {
  local id=$1 pr=$2 event=$3 type author url path line state body loc label
  type=$(printf '%s' "$event" | jq -r '.type')
  author=$(printf '%s' "$event" | jq -r '.author')
  url=$(printf '%s' "$event" | jq -r '.url')
  path=$(printf '%s' "$event" | jq -r '.path')
  line=$(printf '%s' "$event" | jq -r '.line')
  state=$(printf '%s' "$event" | jq -r '.state')
  body=$(printf '%s' "$event" | jq -r '.body')
  body=$(printf '%s' "$body" | truncate_body)
  case "$type" in
    issue_comment) label="PR issue comment" ;;
    review_comment) label="PR review comment" ;;
    review) label="PR review" ;;
    *) label="PR comment" ;;
  esac
  loc=
  [ -n "$path" ] && loc="\nLocation: $path"
  [ -n "$line" ] && [ "$line" != null ] && loc="$loc:$line"
  [ -n "$state" ] && [ "$state" != null ] && loc="$loc\nReview state: $state"
  [ -n "$body" ] || body="(no body)"
  cat <<EOF
PR feedback for this task ($id): $label
Author: $author
PR: $pr
URL: $url$loc

$body

Please review the feedback, update the branch if changes are requested, reply on GitHub when appropriate, and append a supervisor-actionable status only if blocked, failed, needing a decision, or done.
EOF
}

merge_seen() {
  local seen=$1 key=$2 tmp
  tmp="$seen.tmp.$$"
  { [ -f "$seen" ] && cat "$seen"; printf '%s\n' "$key"; } | awk 'NF && !seen[$0]++' > "$tmp" && mv -f "$tmp" "$seen"
}

process_task() {
  local id=$1 meta pr window parsed owner repo num lock seen events rc=0 event key author body state msg
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || return 0
  pr=$(meta_value pr "$meta")
  window=$(meta_value window "$meta")
  [ -n "$pr" ] && [ -n "$window" ] || return 0
  parsed=$(parse_pr_url "$pr") || { emit_error_once "$id-parse" "pr-comment-watch-error $id: unsupported PR URL"; return 0; }
  owner=$(printf '%s' "$parsed" | cut -f1)
  repo=$(printf '%s' "$parsed" | cut -f2)
  num=$(printf '%s' "$parsed" | cut -f3)
  lock="$LOCK_DIR/$id.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    return 0
  fi
  trap 'rm -rf "$lock" 2>/dev/null || true' RETURN
  seen="$SEEN_DIR/$id.seen"
  events="$STORE/$id.events.$$"
  if ! json_lines_for_pr "$owner" "$repo" "$num" > "$events" 2>"$events.err"; then
    emit_error_once "$id-gh" "pr-comment-watch-error $id: GitHub comment poll failed"
    rm -f "$events" "$events.err"
    return 0
  fi
  clear_error "$id-gh"
  clear_error "$id-parse"
  [ -f "$seen" ] || : > "$seen"
  while IFS= read -r event; do
    [ -n "$event" ] || continue
    key=$(printf '%s' "$event" | jq -r '.type + ":" + .id' 2>/dev/null) || continue
    [ -n "$key" ] && [ "$key" != null ] || continue
    grep -qxF "$key" "$seen" 2>/dev/null && continue
    author=$(printf '%s' "$event" | jq -r '.author // ""')
    if is_ignored_author "$author"; then
      merge_seen "$seen" "$key"
      continue
    fi
    body=$(printf '%s' "$event" | jq -r '.body // ""')
    state=$(printf '%s' "$event" | jq -r '.state // ""')
    # Empty non-stateful reviews are notification noise; mark them seen.
    if [ -z "$body" ] && [ -z "$state" ]; then
      merge_seen "$seen" "$key"
      continue
    fi
    if [ "$PRIME" = 1 ]; then
      merge_seen "$seen" "$key"
      continue
    fi
    msg=$(format_message "$id" "$pr" "$event")
    if "$SEND_CMD" "fm-$id" "$msg" >/dev/null 2>&1; then
      merge_seen "$seen" "$key"
    else
      emit_error_once "$id-send" "pr-comment-watch-error $id: failed to inject PR feedback"
      rc=0
      break
    fi
  done < "$events"
  rm -f "$events" "$events.err"
  rm -rf "$lock" 2>/dev/null || true
  trap - RETURN
  return "$rc"
}

if ! need_tool jq; then
  emit_error_once tools "pr-comment-watch-error missing jq"
  exit 0
fi
if ! command -v "$GH_CMD" >/dev/null 2>&1; then
  emit_error_once tools "pr-comment-watch-error missing GitHub CLI"
  exit 0
fi
if [ -z "$SELF_LOGIN" ] && [ "$IGNORE_AUTH_USER" != 0 ]; then
  SELF_LOGIN=$("$GH_CMD" api user --jq .login 2>/dev/null || true)
fi

selected_tasks | while IFS= read -r id; do
  [ -n "$id" ] || continue
  process_task "$id"
done
