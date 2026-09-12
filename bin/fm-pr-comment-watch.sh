#!/usr/bin/env bash
# Poll owner-authored pull requests on monalee-inc/artemis and
# pedromuller-del/firstmate for review-thread changes, gate re-review requests,
# and record explicit thread defers.
#
# Usage:
#   fm-pr-comment-watch.sh poll
#   fm-pr-comment-watch.sh rereview-ready --url <pr-url>
#   fm-pr-comment-watch.sh rerequest-reviewers --url <pr-url> --code-fix --thread-id <id> [...]
#   fm-pr-comment-watch.sh defer --url <pr-url> --thread-id <id>
#   fm-pr-comment-watch.sh arm
#   fm-pr-comment-watch.sh disarm
#   fm-pr-comment-watch.sh --help
#
# poll stays silent on errors and prints one wake line per changed pull request.
# Registered context monitors own their PRs exclusively; this poll covers the rest.
# rereview-ready exits 0 only when every open thread has an owner inline reply
# and either a GitHub resolution or a recorded defer.
# After landing, run `bin/fm-pr-comment-watch.sh arm` in the Firstmate home that should watch these repositories; this tracked change does not alter live state.
# In a home with the previous hand-written check, `arm` replaces its shim and keeps the existing registration on this tracked owner.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID=pr-comment-watch
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
GH_CMD=${FM_PCW_GH_CMD:-gh}

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pr-comment-watch-lib.sh
. "$SCRIPT_DIR/fm-pr-comment-watch-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'fm-pr-comment-watch: %s\n' "$1" >&2
  usage >&2
  exit 2
}

require_tools() {
  command -v "$GH_CMD" >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
}

list_open_owner_prs() {
  local repo=$1 owner name payload
  owner=${repo%%/*}
  name=${repo#*/}
  payload=$("$GH_CMD" pr list --repo "$repo" --author "$FM_PCW_OWNER_AUTHOR" --state open \
    --limit 1000 --json number,url 2>/dev/null) || return 1
  printf '%s' "$payload" | jq -c --arg owner "$owner" --arg name "$name" '
    [.[] | {owner:$owner, name:$name, number:.number, url:.url}]
  ' 2>/dev/null
}

collect_snapshot() {
  local state=$1 repo prs items item owner name number url payload record digest records='[]'
  for repo in "${FM_PCW_OWNER_REPOS[@]+"${FM_PCW_OWNER_REPOS[@]}"}"; do
    prs=$(list_open_owner_prs "$repo") || return 1
    items=$(printf '%s' "$prs" | jq -c '.[]?') || return 1
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      owner=$(printf '%s' "$item" | jq -r '.owner') || return 1
      name=$(printf '%s' "$item" | jq -r '.name') || return 1
      number=$(printf '%s' "$item" | jq -r '.number') || return 1
      url=$(printf '%s' "$item" | jq -r '.url') || return 1
      if FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$state" \
          "$SCRIPT_DIR/fm-pr-context-watch.sh" owns "$url" >/dev/null 2>&1; then
        continue
      fi
      payload=$(fm_pcw_fetch_pr_payload "$owner" "$name" "$number" "$GH_CMD") || return 1
      record=$(fm_pcw_build_pr_record "$state" "$FM_HOME" "$FM_PCW_OWNER_AUTHOR" "$owner" "$name" "$number" "$payload") \
        || return 1
      digest=$(fm_pcw_record_digest "$record") || return 1
      records=$(printf '%s' "$records" | jq -c --argjson row "$digest" '. + [$row]') || return 1
    done <<< "$items"
  done
  jq -cn \
    --arg schema "$FM_PCW_SNAPSHOT_SCHEMA" \
    --arg author "$FM_PCW_OWNER_AUTHOR" \
    --argjson pulls "$records" \
    '{schema:$schema, author:$author, pulls:($pulls | sort_by(.owner, .name, .number))}'
}

publish_snapshot() {
  local state=$1 content=$2 path device tmp
  fm_pcw_state_valid "$state" "$FM_HOME" || return 1
  path=$(fm_pcw_snapshot_path "$state")
  device=$(fm_pr_file_device "$state") || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    fm_pr_private_file_valid "$path" 600 "$device" || return 1
  fi
  umask 077
  tmp=$(mktemp "$state/.fm-pcw-snapshot.XXXXXX") || return 1
  printf '%s\n' "$content" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_pr_private_file_valid "$tmp" 600 "$device" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

action_poll() {
  local state=$1 prior='' current='' path changed
  require_tools || exit 0
  fm_pcw_state_prepare "$state" "$FM_HOME" || exit 0
  current=$(collect_snapshot "$state") || exit 0
  path=$(fm_pcw_snapshot_path "$state")
  if [ -e "$path" ] || [ -L "$path" ]; then
    fm_pr_private_file_valid "$path" 600 "$(fm_pr_file_device "$state")" || exit 0
    prior=$(cat "$path" 2>/dev/null) || prior=''
  fi
  if [ -n "$prior" ] && [ "$prior" = "$current" ]; then
    exit 0
  fi
  if [ -n "$prior" ]; then
    while IFS= read -r changed; do
      [ -n "$changed" ] || continue
      printf 'owner-pr-review-thread %s/%s#%s %s changed\n' \
        "$(printf '%s' "$changed" | jq -r '.owner')" \
        "$(printf '%s' "$changed" | jq -r '.name')" \
        "$(printf '%s' "$changed" | jq -r '.number')" \
        "https://github.com/$(printf '%s' "$changed" | jq -r '.owner')/$(printf '%s' "$changed" | jq -r '.name')/pull/$(printf '%s' "$changed" | jq -r '.number')"
    done < <(jq -c -n \
      --slurpfile old <(printf '%s' "$prior") \
      --slurpfile new <(printf '%s' "$current") '
        def key($p): ($p.owner + "/" + $p.name + "#" + ($p.number|tostring));
        ($old[0].pulls // []) as $oldp |
        ($new[0].pulls // []) as $newp |
        ($oldp | map({(key(.)): .}) | add // {}) as $oldm |
        [ $newp[] | select(($oldm[key(.)] // null) != .) ] | .[]
      ')
  fi
  publish_snapshot "$state" "$current" || exit 0
}

action_rereview_ready() {
  local url='' payload record rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --url) url=$2; shift 2 ;;
      --url=*) url=${1#--url=}; shift ;;
      *) die_usage "unknown argument: $1" ;;
    esac
  done
  [ -n "$url" ] || die_usage "rereview-ready requires --url <pr-url>"
  fm_pcw_pr_url_parse "$url" || die_usage "unsupported pull request URL: $url"
  require_tools || {
    echo "error: rereview-ready requires gh and jq on PATH" >&2
    exit 1
  }
  payload=$(fm_pcw_fetch_pr_payload "$FM_PCW_REPO_OWNER" "$FM_PCW_REPO_NAME" "$FM_PCW_PR_NUMBER" "$GH_CMD") \
    || {
      echo "error: could not read review threads for $url" >&2
      exit 1
    }
  record=$(fm_pcw_build_pr_record "$STATE" "$FM_HOME" "$FM_PCW_OWNER_AUTHOR" \
    "$FM_PCW_REPO_OWNER" "$FM_PCW_REPO_NAME" "$FM_PCW_PR_NUMBER" "$payload")
  rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "error: $url is not authored by $FM_PCW_OWNER_AUTHOR" >&2
    exit 1
  fi
  [ "$rc" -eq 0 ] || {
    echo "error: malformed review-thread payload for $url" >&2
    exit 1
  }
  if fm_pcw_record_blocks_rereview "$record"; then
    echo "error: $url is not ready for re-review; every open review thread needs an inline reply and either a resolution or a recorded defer" >&2
    printf '%s\n' "$record" | jq -c '.threads[] | select((.ownerReply|not) or ((.isResolved|not) and (.deferred|not)))' >&2
    exit 1
  fi
}

action_rerequest_reviewers() {
  local url='' code_fix=false arg reviewer rc
  local -a thread_ids=() reviewers=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --url) url=${2-}; shift 2 ;;
      --url=*) url=${1#--url=}; shift ;;
      --code-fix) code_fix=true; shift ;;
      --thread-id) thread_ids+=("${2-}"); shift 2 ;;
      --thread-id=*) thread_ids+=("${1#--thread-id=}"); shift ;;
      *) die_usage "unknown argument: $1" ;;
    esac
  done
  [ "$code_fix" = true ] || die_usage "--code-fix is required"
  [ -n "$url" ] && [ "${#thread_ids[@]}" -gt 0 ] || die_usage "--url and --thread-id are required"
  fm_pcw_pr_url_parse "$url" || { echo "error: pull request is not fleet-owned" >&2; exit 1; }
  for arg in "${thread_ids[@]+"${thread_ids[@]}"}"; do
    reviewer=$(fm_pcw_thread_reviewer "$FM_PCW_REPO_OWNER" "$FM_PCW_REPO_NAME" "$FM_PCW_PR_NUMBER" "$arg" "$GH_CMD") || exit 1
    fm_pcw_reviewer_eligible "$reviewer" || continue
    case " ${reviewers[*]+"${reviewers[*]}"} " in *" $reviewer "*) ;; *) reviewers+=("$reviewer") ;; esac
  done
  for reviewer in "${reviewers[@]+"${reviewers[@]}"}"; do
    fm_pcw_request_reviewer "$FM_PCW_REPO_OWNER" "$FM_PCW_REPO_NAME" "$FM_PCW_PR_NUMBER" "$reviewer" "$GH_CMD"
    rc=$?
    [ "$rc" -eq 0 ] || printf 'warning: could not re-request review from %s\n' "$reviewer" >&2
  done
}

action_defer() {
  local url='' thread_id='' ts
  while [ $# -gt 0 ]; do
    case "$1" in
      --url) url=$2; shift 2 ;;
      --url=*) url=${1#--url=}; shift ;;
      --thread-id) thread_id=$2; shift 2 ;;
      --thread-id=*) thread_id=${1#--thread-id=}; shift ;;
      *) die_usage "unknown argument: $1" ;;
    esac
  done
  [ -n "$url" ] || die_usage "defer requires --url <pr-url>"
  [ -n "$thread_id" ] || die_usage "defer requires --thread-id <thread-id>"
  fm_pcw_pr_url_parse "$url" || die_usage "unsupported pull request URL: $url"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || die_usage "could not read UTC time"
  fm_pcw_defer_record "$STATE" "$FM_HOME" "$thread_id" "$FM_PCW_REPO_OWNER" "$FM_PCW_REPO_NAME" "$FM_PCW_PR_NUMBER" "$ts" \
    || {
      echo "error: could not record defer for thread $thread_id on $url" >&2
      exit 1
    }
  printf 'deferred: %s thread %s at %s\n' "$url" "$thread_id" "$ts"
}

shim_write() {
  local want=$1 device tmp
  fm_pcw_state_valid "$STATE" "$FM_HOME" || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    chmod 0700 "$CHECK_SHIM" 2>/dev/null || true
    return 0
  fi
  umask 077
  tmp=$(mktemp "$STATE/.fm-pcw-shim.XXXXXX") || return 1
  printf '%s\n' "$want" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0700 "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_pr_private_file_valid "$tmp" 700 "$device" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$CHECK_SHIM"
}

action_arm() {
  local want home
  fm_pcw_state_prepare "$STATE" "$FM_HOME" || {
    echo "error: invalid private state directory: $STATE" >&2
    return 1
  }
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        echo "error: cannot resolve FM_HOME $FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(fm_pcw_poll_shim_content "$home" "$FM_ROOT")
  shim_write "$want" || {
    echo "error: could not write $CHECK_SHIM" >&2
    return 1
  }
  fm_pcw_state_valid "$STATE" "$FM_HOME" || {
    echo "error: invalid private state directory: $STATE" >&2
    return 1
  }
  FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null || {
    if fm_pcw_state_valid "$STATE" "$FM_HOME" \
      && fm_pr_private_file_valid "$CHECK_SHIM" 700 "$(fm_pr_file_device "$STATE")"; then
      rm -f -- "$CHECK_SHIM"
    fi
    echo "error: could not register $CHECK_SHIM" >&2
    return 1
  }
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  FM_HOME="$FM_HOME" "$REGISTER_BIN" retire "$CHECK_ID"
}

SUBCOMMAND=${1:-poll}
shift || true

case "$SUBCOMMAND" in
  -h|--help|help) usage; exit 0 ;;
  poll|check) action_poll "$STATE" ;;
  rereview-ready) action_rereview_ready "$@" ;;
  rerequest-reviewers) action_rerequest_reviewers "$@" ;;
  defer) action_defer "$@" ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  *) die_usage "unknown subcommand: $SUBCOMMAND" ;;
esac
