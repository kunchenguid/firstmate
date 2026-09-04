#!/usr/bin/env bash
# Implementation helpers for the merge-front queue whose public contract and
# private state schema are owned by bin/fm-merge-front.sh's header.

_FM_MERGE_FRONT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v fm_pr_url_parse >/dev/null 2>&1; then
  # shellcheck source=bin/fm-pr-lib.sh
  . "$_FM_MERGE_FRONT_LIB_DIR/fm-pr-lib.sh"
fi
if ! command -v fm_lock_acquire_wait >/dev/null 2>&1; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_MERGE_FRONT_LIB_DIR/fm-wake-lib.sh"
fi
if ! command -v fm_run_timed >/dev/null 2>&1; then
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$_FM_MERGE_FRONT_LIB_DIR/fm-timeout-lib.sh"
fi

FM_MERGE_FRONT_ROOT=
FM_MERGE_FRONT_FILE=
FM_MERGE_FRONT_LOCK=
FM_MERGE_FRONT_STATE_DEVICE=
FM_MERGE_FRONT_TASKS=()
FM_MERGE_FRONT_URLS=()
FM_MERGE_FRONT_EXISTS=0
FM_MERGE_FRONT_DROPPED_TASK=
FM_MERGE_FRONT_DROPPED_URL=

fm_merge_front_project_key_valid() {
  local key=${1-}
  fm_task_id_path_safe "$key" && [ "${#key}" -le 100 ]
}

fm_merge_front_root_prepare() {  # <state> <create: 0|1>
  local state=$1 create=$2 mode created=0
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  FM_MERGE_FRONT_STATE_DEVICE=$(fm_pr_file_device "$state") || return 1
  FM_MERGE_FRONT_ROOT="$state/merge-front"
  if [ ! -e "$FM_MERGE_FRONT_ROOT" ] && [ ! -L "$FM_MERGE_FRONT_ROOT" ]; then
    [ "$create" -eq 1 ] || return 2
    if (umask 077; mkdir "$FM_MERGE_FRONT_ROOT" 2>/dev/null); then
      created=1
    fi
  fi
  [ -d "$FM_MERGE_FRONT_ROOT" ] && [ ! -L "$FM_MERGE_FRONT_ROOT" ] || return 1
  [ "$created" -eq 0 ] || chmod 0700 "$FM_MERGE_FRONT_ROOT" 2>/dev/null || return 1
  mode=$(fm_pr_file_mode "$FM_MERGE_FRONT_ROOT") || return 1
  [ "$mode" = 700 ] || return 1
  [ "$(fm_pr_file_device "$FM_MERGE_FRONT_ROOT")" = "$FM_MERGE_FRONT_STATE_DEVICE" ]
}

fm_merge_front_paths() {  # <state> <project-key> <create: 0|1>
  local state=$1 project=$2 create=$3
  fm_merge_front_project_key_valid "$project" || return 1
  fm_merge_front_root_prepare "$state" "$create" || return $?
  FM_MERGE_FRONT_FILE="$FM_MERGE_FRONT_ROOT/$project.queue"
  FM_MERGE_FRONT_LOCK="$FM_MERGE_FRONT_ROOT/.$project.lock"
}

fm_merge_front_file_load() {  # <project-key>
  local project=$1 line version='' stored_project='' task url tab
  local line_number=0 bytes seen_tasks seen_urls
  FM_MERGE_FRONT_TASKS=()
  FM_MERGE_FRONT_URLS=()
  FM_MERGE_FRONT_EXISTS=0
  [ -e "$FM_MERGE_FRONT_FILE" ] || [ -L "$FM_MERGE_FRONT_FILE" ] || return 0
  fm_pr_private_file_valid "$FM_MERGE_FRONT_FILE" 600 "$FM_MERGE_FRONT_STATE_DEVICE" || return 1
  bytes=$(wc -c < "$FM_MERGE_FRONT_FILE" 2>/dev/null | tr -d '[:space:]') || return 1
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le 1048576 ] || return 1
  tab=$'\t'
  seen_tasks=$'\n'
  seen_urls=$'\n'
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    case "$line_number" in
      1) version=$line ;;
      2) stored_project=${line#project=} ;;
      *)
        case "$line" in
          task=*"$tab"url=*) ;;
          *) return 1 ;;
        esac
        task=${line%%"$tab"*}
        task=${task#task=}
        url=${line#*"$tab"}
        url=${url#url=}
        case "$url" in *"$tab"*) return 1 ;; esac
        fm_pr_task_id_valid "$task" || return 1
        fm_pr_url_parse "$url" || return 1
        case "$seen_tasks" in *$'\n'"$task"$'\n'*) return 1 ;; esac
        case "$seen_urls" in *$'\n'"$url"$'\n'*) return 1 ;; esac
        seen_tasks="${seen_tasks}${task}"$'\n'
        seen_urls="${seen_urls}${url}"$'\n'
        FM_MERGE_FRONT_TASKS+=("$task")
        FM_MERGE_FRONT_URLS+=("$url")
        ;;
    esac
  done < "$FM_MERGE_FRONT_FILE"
  [ "$line_number" -ge 2 ] || return 1
  [ "$version" = fm-merge-front-v1 ] || return 1
  [ "$stored_project" = "$project" ] || return 1
  FM_MERGE_FRONT_EXISTS=1
}

fm_merge_front_file_write() {  # <project-key>
  local project=$1 tmp='' index
  fm_pr_regular_destination_on_device_or_absent \
    "$FM_MERGE_FRONT_FILE" "$FM_MERGE_FRONT_STATE_DEVICE" || return 1
  tmp=$(mktemp "$FM_MERGE_FRONT_ROOT/.$project.queue.XXXXXX") || return 1
  if ! {
      printf 'fm-merge-front-v1\nproject=%s\n' "$project"
      index=0
      while [ "$index" -lt "${#FM_MERGE_FRONT_TASKS[@]}" ]; do
        printf 'task=%s\turl=%s\n' \
          "${FM_MERGE_FRONT_TASKS[$index]}" "${FM_MERGE_FRONT_URLS[$index]}"
        index=$((index + 1))
      done
    } > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$FM_MERGE_FRONT_STATE_DEVICE"; then
    rm -f -- "$tmp"
    return 1
  fi
  FM_MERGE_FRONT_FILE=$tmp
  if ! fm_merge_front_file_load "$project"; then
    FM_MERGE_FRONT_FILE="$FM_MERGE_FRONT_ROOT/$project.queue"
    rm -f -- "$tmp"
    return 1
  fi
  FM_MERGE_FRONT_FILE="$FM_MERGE_FRONT_ROOT/$project.queue"
  if ! fm_pr_regular_destination_on_device_or_absent \
      "$FM_MERGE_FRONT_FILE" "$FM_MERGE_FRONT_STATE_DEVICE" \
    || ! mv -f -- "$tmp" "$FM_MERGE_FRONT_FILE" \
    || ! fm_merge_front_file_load "$project"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Every queue lock wait is bounded. greptile-kick deliberately holds this lock
# across live GitHub reads, and the shared merge-outcome path runs inside the
# watcher, which must refuse rather than wedge behind a stuck holder.
_fm_merge_front_bounded_seconds() {  # <value> <default>
  local seconds=$1 fallback=$2
  case "$seconds" in ''|*[!0-9]*|0) seconds=$fallback ;; esac
  printf '%s\n' "$seconds"
}

_fm_merge_front_lock_acquire() {
  local seconds
  seconds=$(_fm_merge_front_bounded_seconds "${FM_MERGE_FRONT_LOCK_TIMEOUT:-30}" 30)
  fm_lock_acquire_wait_bounded "$FM_MERGE_FRONT_LOCK" "$seconds"
}

_fm_merge_front_gh() {  # <gh-argument...>
  local seconds
  seconds=$(_fm_merge_front_bounded_seconds "${FM_MERGE_FRONT_GH_TIMEOUT:-60}" 60)
  fm_run_timed "$seconds" env GH_PAGER=cat GH_PROMPT_DISABLED=1 "$@"
}

fm_merge_front_lock_and_load() {  # <state> <project-key> <create: 0|1>
  local state=$1 project=$2 create=$3 rc
  if fm_merge_front_paths "$state" "$project" "$create"; then
    :
  else
    rc=$?
    return "$rc"
  fi
  _fm_merge_front_lock_acquire || return 1
  if ! fm_merge_front_file_load "$project"; then
    fm_lock_release "$FM_MERGE_FRONT_LOCK"
    return 1
  fi
}

fm_merge_front_unlock() {
  fm_lock_release "$FM_MERGE_FRONT_LOCK"
}

fm_merge_front_project_key_from_meta() {  # <state> <task-id>
  local state=$1 id=$2 meta line project='' count=0 key
  fm_pr_task_id_valid "$id" || return 1
  meta="$state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ "$(fm_pr_file_link_count "$meta")" = 1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      project=*)
        count=$((count + 1))
        project=${line#project=}
        ;;
    esac
  done < "$meta"
  [ "$count" -eq 1 ] && [ -n "$project" ] || return 1
  while [ "$project" != "${project%/}" ]; do
    project=${project%/}
  done
  key=${project##*/}
  fm_merge_front_project_key_valid "$key" || return 1
  printf '%s\n' "$key"
}

fm_merge_front_enqueue() {  # <state> <project-key> <task-id> <pr-url>
  local state=$1 project=$2 task=$3 raw_url=$4 url index role
  local task_index=-1 url_index=-1
  fm_merge_front_project_key_valid "$project" || return 2
  fm_pr_task_id_valid "$task" || return 2
  fm_pr_url_parse "$raw_url" || return 2
  url=$FM_PR_URL
  fm_merge_front_lock_and_load "$state" "$project" 1 || return 1
  index=0
  while [ "$index" -lt "${#FM_MERGE_FRONT_TASKS[@]}" ]; do
    [ "${FM_MERGE_FRONT_TASKS[$index]}" != "$task" ] || task_index=$index
    [ "${FM_MERGE_FRONT_URLS[$index]}" != "$url" ] || url_index=$index
    index=$((index + 1))
  done
  if [ "$url_index" -ge 0 ] && [ "$url_index" -ne "$task_index" ]; then
    printf 'error: merge-front queue conflict for project %s\n' "$project" >&2
    fm_merge_front_unlock
    return 1
  fi
  if [ "$task_index" -ge 0 ]; then
    if [ "$url_index" -lt 0 ]; then
      FM_MERGE_FRONT_URLS[$task_index]=$url
      if ! fm_merge_front_file_write "$project"; then
        fm_merge_front_unlock
        return 1
      fi
    fi
    index=$task_index
  else
    FM_MERGE_FRONT_TASKS+=("$task")
    FM_MERGE_FRONT_URLS+=("$url")
    if ! fm_merge_front_file_write "$project"; then
      fm_merge_front_unlock
      return 1
    fi
    index=$((${#FM_MERGE_FRONT_TASKS[@]} - 1))
  fi
  role=parked
  [ "$index" -ne 0 ] || role=front
  fm_merge_front_unlock
  printf '%s=%s\t%s\n' "$role" "$task" "$url"
}

fm_merge_front_status() {  # <state> <project-key>
  local state=$1 project=$2 index rc
  fm_merge_front_project_key_valid "$project" || return 2
  if fm_merge_front_paths "$state" "$project" 0; then
    :
  else
    rc=$?
    [ "$rc" -eq 2 ] || return 1
    printf 'project=%s\nfront=none\n' "$project"
    return 0
  fi
  _fm_merge_front_lock_acquire || return 1
  if ! fm_merge_front_file_load "$project"; then
    fm_merge_front_unlock
    return 1
  fi
  printf 'project=%s\n' "$project"
  if [ "${#FM_MERGE_FRONT_TASKS[@]}" -eq 0 ]; then
    printf 'front=none\n'
  else
    printf 'front=%s\t%s\n' "${FM_MERGE_FRONT_TASKS[0]}" "${FM_MERGE_FRONT_URLS[0]}"
    index=1
    while [ "$index" -lt "${#FM_MERGE_FRONT_TASKS[@]}" ]; do
      printf 'parked=%s\t%s\n' \
        "${FM_MERGE_FRONT_TASKS[$index]}" "${FM_MERGE_FRONT_URLS[$index]}"
      index=$((index + 1))
    done
  fi
  fm_merge_front_unlock
}

fm_merge_front_promote() {  # <state> <project-key>
  local state=$1 project=$2 old_task old_url next_task=none next_url= rc
  local provider host path number merged
  fm_merge_front_project_key_valid "$project" || return 2
  if fm_merge_front_paths "$state" "$project" 0; then
    :
  else
    rc=$?
    [ "$rc" -eq 2 ] || return 1
    printf 'promoted=none\nfront=none\n'
    return 0
  fi
  _fm_merge_front_lock_acquire || return 1
  if ! fm_merge_front_file_load "$project"; then
    fm_merge_front_unlock
    return 1
  fi
  if [ "${#FM_MERGE_FRONT_TASKS[@]}" -eq 0 ]; then
    fm_merge_front_unlock
    printf 'promoted=none\nfront=none\n'
    return 0
  fi
  old_task=${FM_MERGE_FRONT_TASKS[0]}
  old_url=${FM_MERGE_FRONT_URLS[0]}
  fm_pr_url_parse "$old_url" || {
    fm_merge_front_unlock
    return 1
  }
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  merged=$("$_FM_MERGE_FRONT_LIB_DIR/fm-pr-poll.sh" --validated \
    "$provider" "$old_url" "$host" "$path" "$number" 2>/dev/null) || merged=
  if [ "$merged" != merged ]; then
    fm_merge_front_unlock
    printf 'error: merge-front PR is not confirmed merged: %s\n' "$old_url" >&2
    return 1
  fi
  FM_MERGE_FRONT_TASKS=("${FM_MERGE_FRONT_TASKS[@]:1}")
  FM_MERGE_FRONT_URLS=("${FM_MERGE_FRONT_URLS[@]:1}")
  if ! fm_merge_front_file_write "$project"; then
    fm_merge_front_unlock
    return 1
  fi
  if [ "${#FM_MERGE_FRONT_TASKS[@]}" -gt 0 ]; then
    next_task=${FM_MERGE_FRONT_TASKS[0]}
    next_url=${FM_MERGE_FRONT_URLS[0]}
  fi
  fm_merge_front_unlock
  printf 'promoted=%s\t%s\n' "$old_task" "$old_url"
  if [ "$next_task" = none ]; then
    printf 'front=none\n'
  else
    printf 'front=%s\t%s\n' "$next_task" "$next_url"
  fi
}

# Retire the queue entries bound to one task or one PR URL, wherever they sit.
# Sets FM_MERGE_FRONT_DROPPED_* to the first retired identity and leaves the
# loaded queue arrays holding the survivors. Returns 3 when nothing matched.
_fm_merge_front_drop_locked() {  # <project-key> <task-id> <canonical-url>
  local project=$1 task=$2 url=$3 index=0 removed=0
  local tasks=() urls=()
  FM_MERGE_FRONT_DROPPED_TASK=
  FM_MERGE_FRONT_DROPPED_URL=
  while [ "$index" -lt "${#FM_MERGE_FRONT_TASKS[@]}" ]; do
    if [ "${FM_MERGE_FRONT_TASKS[$index]}" = "$task" ] \
      || [ "${FM_MERGE_FRONT_URLS[$index]}" = "$url" ]; then
      if [ "$removed" -eq 0 ]; then
        FM_MERGE_FRONT_DROPPED_TASK=${FM_MERGE_FRONT_TASKS[$index]}
        FM_MERGE_FRONT_DROPPED_URL=${FM_MERGE_FRONT_URLS[$index]}
      fi
      removed=$((removed + 1))
    else
      tasks+=("${FM_MERGE_FRONT_TASKS[$index]}")
      urls+=("${FM_MERGE_FRONT_URLS[$index]}")
    fi
    index=$((index + 1))
  done
  [ "$removed" -ne 0 ] || return 3
  # shellcheck disable=SC2206 # Validated slug and URL elements never split.
  FM_MERGE_FRONT_TASKS=(${tasks[@]+"${tasks[@]}"})
  # shellcheck disable=SC2206 # Validated slug and URL elements never split.
  FM_MERGE_FRONT_URLS=(${urls[@]+"${urls[@]}"})
  fm_merge_front_file_write "$project"
}

# Shared identity-bound retirement. Returns 0 when an entry was removed, 3 when
# the identity is absent (including a project with no queue at all), 1 on a
# lock or state failure, and 2 on an invalid request.
fm_merge_front_drop() {  # <state> <project-key> <task-id> <pr-url>
  local state=$1 project=$2 task=$3 raw_url=$4 url rc
  fm_merge_front_project_key_valid "$project" || return 2
  fm_pr_task_id_valid "$task" || return 2
  fm_pr_url_parse "$raw_url" || return 2
  url=$FM_PR_URL
  FM_MERGE_FRONT_DROPPED_TASK=
  FM_MERGE_FRONT_DROPPED_URL=
  if fm_merge_front_paths "$state" "$project" 0; then
    :
  else
    rc=$?
    [ "$rc" -eq 2 ] && return 3
    return 1
  fi
  _fm_merge_front_lock_acquire || return 1
  if ! fm_merge_front_file_load "$project"; then
    fm_merge_front_unlock
    return 1
  fi
  rc=0
  _fm_merge_front_drop_locked "$project" "$task" "$url" || rc=$?
  fm_merge_front_unlock
  return "$rc"
}

# Reconcile one already-confirmed merged PR. A merge is a fact the queue may
# never veto: the exact entry is removed wherever it sits, an out-of-order
# merge leaves the current front untouched, and an identity that is not queued
# is simply nothing to do.
fm_merge_front_reconcile_merged() {  # <state> <project-key> <task-id> <pr-url>
  local rc=0
  fm_merge_front_drop "$@" || rc=$?
  [ "$rc" -ne 3 ] || rc=0
  return "$rc"
}

# Operator recovery for a front or parked PR that will never merge: a closed or
# superseded PR, or a torn-down task. Removal never advances anything by itself;
# it only retires the named entry, so a retired front simply exposes the next.
fm_merge_front_remove() {  # <state> <project-key> <task-id> <pr-url>
  local rc=0
  fm_merge_front_drop "$@" || rc=$?
  case "$rc" in
    0) printf 'removed=%s\t%s\n' \
         "$FM_MERGE_FRONT_DROPPED_TASK" "$FM_MERGE_FRONT_DROPPED_URL" ;;
    3)
      printf 'removed=none\n'
      rc=0
      ;;
    *) return "$rc" ;;
  esac
  if [ "${#FM_MERGE_FRONT_TASKS[@]}" -eq 0 ]; then
    printf 'front=none\n'
  else
    printf 'front=%s\t%s\n' "${FM_MERGE_FRONT_TASKS[0]}" "${FM_MERGE_FRONT_URLS[0]}"
  fi
  return "$rc"
}

fm_merge_front_promote_task() {  # <state> <task-id> <pr-url>
  local state=$1 task=$2 url=$3 project
  [ -e "$state/merge-front" ] || [ -L "$state/merge-front" ] || return 0
  project=$(fm_merge_front_project_key_from_meta "$state" "$task") || return 0
  fm_merge_front_reconcile_merged "$state" "$project" "$task" "$url"
}

fm_merge_front_checks_json() {  # <github-check-command...>
  local output
  if output=$(_fm_merge_front_gh "$@" 2>&1); then
    :
  fi
  if printf '%s\n' "$output" | jq -e \
      'type == "array" and all(.[]; type == "object" and (.name | type == "string") and (.state | type == "string"))' \
      >/dev/null 2>&1; then
    printf '%s\n' "$output"
    return 0
  fi
  case "$output" in
    "no required checks reported on "*" branch"|"no checks reported on "*" branch")
      printf '[]\n'
      ;;
    *)
      printf 'error: GitHub checks could not be read: %s\n' "${output:-no output}" >&2
      return 1
      ;;
  esac
}

fm_merge_front_greptile_kick() {  # <state> <project-key>
  local state=$1 project=$2 task url provider repo_path number pr_row pr_state base head
  local behind required_json blocked all_json unknown pending rc
  fm_merge_front_project_key_valid "$project" || return 2
  command -v gh >/dev/null 2>&1 || {
    echo 'error: greptile-kick requires gh on PATH' >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo 'error: greptile-kick requires jq on PATH' >&2
    return 1
  }
  if fm_merge_front_paths "$state" "$project" 0; then
    :
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      printf 'error: project %s has no merge-front queue\n' "$project" >&2
    fi
    return 1
  fi
  _fm_merge_front_lock_acquire || return 1
  if ! fm_merge_front_file_load "$project"; then
    fm_merge_front_unlock
    echo 'error: merge-front queue is invalid' >&2
    return 1
  fi
  if [ "${#FM_MERGE_FRONT_TASKS[@]}" -eq 0 ]; then
    fm_merge_front_unlock
    printf 'error: project %s has no merge-front PR\n' "$project" >&2
    return 1
  fi
  task=${FM_MERGE_FRONT_TASKS[0]}
  url=${FM_MERGE_FRONT_URLS[0]}
  fm_pr_url_parse "$url" || {
    fm_merge_front_unlock
    echo 'error: merge-front PR identity is invalid' >&2
    return 1
  }
  provider=$FM_PR_PROVIDER
  repo_path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  if [ "$provider" != github ]; then
    fm_merge_front_unlock
    echo 'error: greptile-kick supports GitHub pull requests only' >&2
    return 1
  fi
  if ! pr_row=$(_fm_merge_front_gh gh pr view "$number" \
      --repo "$repo_path" --json state,baseRefName,headRefOid \
      --jq '[.state,.baseRefName,.headRefOid] | @tsv' 2>/dev/null); then
    fm_merge_front_unlock
    echo 'error: merge-front PR state could not be read' >&2
    return 1
  fi
  IFS=$'\t' read -r pr_state base head <<< "$pr_row"
  if [ "$pr_state" != OPEN ]; then
    fm_merge_front_unlock
    printf 'error: merge-front PR is not open (state=%s)\n' "${pr_state:-unknown}" >&2
    return 1
  fi
  if [ "$base" != main ]; then
    fm_merge_front_unlock
    printf 'error: merge-front PR targets %s, not main\n' "${base:-unknown}" >&2
    return 1
  fi
  if ! fm_pr_head_valid "$head"; then
    fm_merge_front_unlock
    echo 'error: merge-front PR head could not be validated' >&2
    return 1
  fi
  if ! behind=$(_fm_merge_front_gh gh api \
      "repos/$repo_path/compare/main...$head" --jq .behind_by 2>/dev/null); then
    fm_merge_front_unlock
    echo 'error: merge-front PR freshness could not be read' >&2
    return 1
  fi
  case "$behind" in ''|*[!0-9]*)
    fm_merge_front_unlock
    echo 'error: merge-front PR freshness was not numeric' >&2
    return 1
    ;;
  esac
  if [ "$behind" -ne 0 ]; then
    fm_merge_front_unlock
    printf 'error: merge-front PR is behind main (behind_by=%s)\n' "$behind" >&2
    return 1
  fi
  if ! required_json=$(fm_merge_front_checks_json gh pr checks "$number" \
      --repo "$repo_path" --required --json name,state); then
    fm_merge_front_unlock
    return 1
  fi
  blocked=$(printf '%s\n' "$required_json" | jq -r \
    '[.[] | select(((.name | ascii_downcase | contains("greptile")) | not) and .state != "SUCCESS") | "\(.name)=\(.state)"] | join(", ")') || {
      fm_merge_front_unlock
      echo 'error: required check state could not be evaluated' >&2
      return 1
    }
  if [ -n "$blocked" ]; then
    fm_merge_front_unlock
    printf 'error: non-Greptile required checks are not green: %s\n' "$blocked" >&2
    return 1
  fi
  if ! all_json=$(fm_merge_front_checks_json gh pr checks "$number" \
      --repo "$repo_path" --json name,state); then
    fm_merge_front_unlock
    return 1
  fi
  unknown=$(printf '%s\n' "$all_json" | jq -r \
    '[.[] | select(.name | ascii_downcase | contains("greptile")) | .state | select(. as $state | ["PENDING","QUEUED","IN_PROGRESS","WAITING","REQUESTED","EXPECTED","SUCCESS","FAILURE","ERROR","CANCELLED","SKIPPED","NEUTRAL","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE","STALE"] | index($state) | not)] | unique | join(", ")') || {
      fm_merge_front_unlock
      echo 'error: Greptile check state could not be evaluated' >&2
      return 1
    }
  if [ -n "$unknown" ]; then
    fm_merge_front_unlock
    printf 'error: unrecognised Greptile check state: %s\n' "$unknown" >&2
    return 1
  fi
  pending=$(printf '%s\n' "$all_json" | jq -r \
    '[.[] | select(.name | ascii_downcase | contains("greptile")) | .state | select(. == "PENDING" or . == "QUEUED" or . == "IN_PROGRESS" or . == "WAITING" or . == "REQUESTED" or . == "EXPECTED")] | length') || {
      fm_merge_front_unlock
      echo 'error: Greptile pending state could not be evaluated' >&2
      return 1
    }
  if [ "$pending" -ne 0 ]; then
    fm_merge_front_unlock
    echo 'error: Greptile review is already pending' >&2
    return 1
  fi
  if ! _fm_merge_front_gh gh pr comment "$number" \
      --repo "$repo_path" --body '@greptile review'; then
    fm_merge_front_unlock
    echo 'error: Greptile review comment failed' >&2
    return 1
  fi
  fm_merge_front_unlock
  printf 'kicked=%s\t%s\n' "$task" "$url"
}
