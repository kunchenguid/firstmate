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
FM_MERGE_FRONT_DROPPED_TASK=
FM_MERGE_FRONT_DROPPED_URL=
FM_MERGE_FRONT_CONFLICT_TASK=
FM_MERGE_FRONT_SNAPSHOT_TASK=
FM_MERGE_FRONT_SNAPSHOT_URL=

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

# Every queue lock wait is bounded and every hold is local: no path holds this
# lock across a live GitHub call, so the longest hold is a state read plus an
# atomic rewrite. The shared merge-outcome path runs inside the watcher, which
# must refuse rather than wedge behind a stuck holder.
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

# Map a project checkout path onto its durable queue key. The key is the
# path-safe remnant of the checkout basename joined to a digest of the whole
# path, so an ordinary basename such as "my repo" or "app (v2)" registers
# instead of refusing, while two checkouts that share a basename keep separate
# queues. The mapping is pure and deterministic, so every caller that holds the
# same project path resolves the same key without consulting shared state.
fm_merge_front_project_key_from_path() {  # <project-path>
  local project=${1-} base hash key
  [ -n "$project" ] || return 1
  while [ "$project" != "${project%/}" ]; do
    project=${project%/}
  done
  [ -n "$project" ] || project=/
  base=${project##*/}
  base=$(printf '%s' "$base" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-' | cut -c1-40) || return 1
  while :; do
    case "$base" in
      ''|[A-Za-z0-9]*) break ;;
      *) base=${base#?} ;;
    esac
  done
  [ -n "$base" ] || base=project
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$project" | shasum -a 256 | awk '{print substr($1,1,12)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$project" | sha256sum | awk '{print substr($1,1,12)}')
  else
    hash=$(printf '%s' "$project" | cksum | awk '{printf "%08x-%s", $1, $2}')
  fi
  [ -n "$hash" ] || return 1
  key="$base-$hash"
  fm_merge_front_project_key_valid "$key" || return 1
  printf '%s\n' "$key"
}

fm_merge_front_project_key_from_meta() {  # <state> <task-id>
  local state=$1 id=$2 meta line project='' count=0
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
  fm_merge_front_project_key_from_path "$project"
}

# Pure read of durable queue state: report whether this PR URL is already bound
# to a different task in this project. PR registration consults it before it
# rewrites task metadata or publishes a poll, so a conflict - which no retry can
# clear - refuses over untouched state instead of over a half-applied
# registration. Returns 0 when the URL is free or already this task's, 3 on a
# conflict (with FM_MERGE_FRONT_CONFLICT_TASK naming the holder), 2 on an
# invalid request, and 1 when the queue cannot be read.
fm_merge_front_url_conflict() {  # <state> <project-key> <task-id> <pr-url>
  local state=$1 project=$2 task=$3 raw_url=$4 url index rc=0
  FM_MERGE_FRONT_CONFLICT_TASK=
  fm_merge_front_project_key_valid "$project" || return 2
  fm_pr_task_id_valid "$task" || return 2
  fm_pr_url_parse "$raw_url" || return 2
  url=$FM_PR_URL
  if fm_merge_front_paths "$state" "$project" 0; then
    :
  else
    rc=$?
    [ "$rc" -eq 2 ] && return 0
    return 1
  fi
  _fm_merge_front_lock_acquire || return 1
  if ! fm_merge_front_file_load "$project"; then
    fm_merge_front_unlock
    return 1
  fi
  index=0
  while [ "$index" -lt "${#FM_MERGE_FRONT_TASKS[@]}" ]; do
    if [ "${FM_MERGE_FRONT_URLS[$index]}" = "$url" ] \
      && [ "${FM_MERGE_FRONT_TASKS[$index]}" != "$task" ]; then
      FM_MERGE_FRONT_CONFLICT_TASK=${FM_MERGE_FRONT_TASKS[$index]}
      rc=3
      break
    fi
    index=$((index + 1))
  done
  fm_merge_front_unlock
  return "$rc"
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
  local state=$1 project=$2 task url next_task=none next_url= rc
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
  task=${FM_MERGE_FRONT_TASKS[0]}
  url=${FM_MERGE_FRONT_URLS[0]}
  fm_merge_front_unlock
  fm_pr_url_parse "$url" || return 1
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  merged=$(_fm_merge_front_gh "$_FM_MERGE_FRONT_LIB_DIR/fm-pr-poll.sh" --validated \
    "$provider" "$url" "$host" "$path" "$number" 2>/dev/null) || merged=
  if [ "$merged" != merged ]; then
    printf 'error: merge-front PR is not confirmed merged: %s\n' "$url" >&2
    return 1
  fi
  _fm_merge_front_lock_acquire || return 1
  if ! fm_merge_front_file_load "$project"; then
    fm_merge_front_unlock
    return 1
  fi
  if [ "${#FM_MERGE_FRONT_TASKS[@]}" -eq 0 ] \
    || [ "${FM_MERGE_FRONT_TASKS[0]}" != "$task" ] \
    || [ "${FM_MERGE_FRONT_URLS[0]}" != "$url" ]; then
    fm_merge_front_unlock
    printf 'error: merge-front PR is no longer the front of project %s\n' "$project" >&2
    return 1
  fi
  if ! _fm_merge_front_drop_locked "$project" "$task" "$url"; then
    fm_merge_front_unlock
    return 1
  fi
  if [ "${#FM_MERGE_FRONT_TASKS[@]}" -gt 0 ]; then
    next_task=${FM_MERGE_FRONT_TASKS[0]}
    next_url=${FM_MERGE_FRONT_URLS[0]}
  fi
  fm_merge_front_unlock
  printf 'promoted=%s\t%s\n' "$task" "$url"
  if [ "$next_task" = none ]; then
    printf 'front=none\n'
  else
    printf 'front=%s\t%s\n' "$next_task" "$next_url"
  fi
}

# Retire the one queue entry bound to this task. With a canonical URL the task
# and the URL must both match, so a stale or mismatched identity retires nothing
# rather than silently dropping some other task's live entry; that is the only
# mode the operator-facing remove command uses. With an empty URL the row is
# identified by the trusted task identity alone, which the internal
# teardown/missing-metadata retirement uses to clear a row whose recorded URL
# has diverged. Task IDs and URLs are each unique within a queue, so either mode
# identifies at most one row. Sets FM_MERGE_FRONT_DROPPED_* to the retired
# identity and leaves the loaded arrays holding the survivors. Returns 3 when no
# row matched.
_fm_merge_front_drop_locked() {  # <project-key> <task-id> <canonical-url-or-empty>
  local project=$1 task=$2 url=$3 index=0 removed=0
  local tasks=() urls=()
  FM_MERGE_FRONT_DROPPED_TASK=
  FM_MERGE_FRONT_DROPPED_URL=
  while [ "$index" -lt "${#FM_MERGE_FRONT_TASKS[@]}" ]; do
    if [ "${FM_MERGE_FRONT_TASKS[$index]}" = "$task" ] \
      && { [ -z "$url" ] || [ "${FM_MERGE_FRONT_URLS[$index]}" = "$url" ]; }; then
      FM_MERGE_FRONT_DROPPED_TASK=${FM_MERGE_FRONT_TASKS[$index]}
      FM_MERGE_FRONT_DROPPED_URL=${FM_MERGE_FRONT_URLS[$index]}
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

# Shared identity-bound retirement. An empty URL selects the trusted task-scoped
# mode described on _fm_merge_front_drop_locked. Returns 0 when an entry was
# removed, 3 when the identity is absent (including a project with no queue at
# all), 1 on a lock or state failure, and 2 on an invalid request.
_fm_merge_front_drop_scoped() {  # <state> <project-key> <task-id> <pr-url-or-empty>
  local state=$1 project=$2 task=$3 raw_url=$4 url='' rc
  fm_merge_front_project_key_valid "$project" || return 2
  fm_pr_task_id_valid "$task" || return 2
  if [ -n "$raw_url" ]; then
    fm_pr_url_parse "$raw_url" || return 2
    url=$FM_PR_URL
  fi
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

# The exact task-and-URL retirement every operator-facing path uses.
fm_merge_front_drop() {  # <state> <project-key> <task-id> <pr-url>
  [ -n "${4-}" ] || return 2
  _fm_merge_front_drop_scoped "$@"
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

# Retire an identity from whichever project queue holds it when the task's own
# project key is no longer derivable. The scan stops at the first queue that
# yields the drop, so FM_MERGE_FRONT_DROPPED_* keeps the retired identity and no
# unrelated project's lock is taken once the row is gone. One busy or unreadable
# queue never aborts the scan: the remaining queues are still examined, and the
# failure only surfaces when none of them yielded the drop. Returns 3 when
# nothing matched anywhere, 1 when the target could not be safely retired.
fm_merge_front_drop_anywhere() {  # <state> <task-id> <pr-url-or-empty>
  local state=$1 task=$2 url=${3-} file project rc failed=0
  if fm_merge_front_root_prepare "$state" 0; then
    :
  else
    rc=$?
    [ "$rc" -eq 2 ] && return 3
    return 1
  fi
  for file in "$FM_MERGE_FRONT_ROOT"/*.queue; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    project=${file##*/}
    project=${project%.queue}
    fm_merge_front_project_key_valid "$project" || continue
    rc=0
    _fm_merge_front_drop_scoped "$state" "$project" "$task" "$url" || rc=$?
    case "$rc" in
      0) return 0 ;;
      3) ;;
      *) failed=1 ;;
    esac
  done
  [ "$failed" -eq 0 ] || return 1
  return 3
}

# Retire this task's row in its own project queue when the metadata still names
# one, otherwise anywhere. Returns 0 on a drop, 3 when nothing matched, 1 on a
# lock or state failure.
_fm_merge_front_retire_scoped() {  # <state> <task-id> <pr-url-or-empty>
  local state=$1 task=$2 url=$3 project rc=0
  if project=$(fm_merge_front_project_key_from_meta "$state" "$task" 2>/dev/null); then
    _fm_merge_front_drop_scoped "$state" "$project" "$task" "$url" || rc=$?
    case "$rc" in
      0|3) ;;
      *) return 1 ;;
    esac
    [ "$rc" -eq 3 ] || return 0
  fi
  rc=0
  fm_merge_front_drop_anywhere "$state" "$task" "$url" || rc=$?
  return "$rc"
}

# The one identity-bound retirement entry point for a task leaving the queue -
# a confirmed merge, or a teardown. A merge is a fact the queue may never veto:
# only the matching row is retired, wherever it sits, so an out-of-order merge
# leaves the current front untouched and an unqueued identity is nothing to do.
# It prefers the task's own project key and
# falls back to a scan of every project queue when the task metadata is already
# gone, so a completed or torn-down front can never stay queued in front of the
# live PRs behind it. The recorded URL is tried first; when it finds nothing the
# trusted task identity alone retires the row, because a replacement
# registration that committed the metadata but failed its enqueue leaves the
# queue holding a stale URL for this very task. A task with no queued row at all
# is nothing to do, never a failure.
fm_merge_front_retire_task() {  # <state> <task-id> <pr-url>
  local state=$1 task=$2 url=$3 rc=0
  [ -e "$state/merge-front" ] || [ -L "$state/merge-front" ] || return 0
  _fm_merge_front_retire_scoped "$state" "$task" "$url" || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) ;;
    *) return 1 ;;
  esac
  rc=0
  _fm_merge_front_retire_scoped "$state" "$task" '' || rc=$?
  case "$rc" in
    0|3) return 0 ;;
    *) return 1 ;;
  esac
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

# Snapshot the current front under the queue lock. The lock is never held
# across a live GitHub call, so an ordinary enqueue or a confirmed-merge
# retirement can never queue behind a slow forge read.
_fm_merge_front_snapshot_front() {  # <project-key>
  local project=$1
  FM_MERGE_FRONT_SNAPSHOT_TASK=
  FM_MERGE_FRONT_SNAPSHOT_URL=
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
  FM_MERGE_FRONT_SNAPSHOT_TASK=${FM_MERGE_FRONT_TASKS[0]}
  FM_MERGE_FRONT_SNAPSHOT_URL=${FM_MERGE_FRONT_URLS[0]}
  fm_merge_front_unlock
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
  _fm_merge_front_snapshot_front "$project" || return 1
  task=$FM_MERGE_FRONT_SNAPSHOT_TASK
  url=$FM_MERGE_FRONT_SNAPSHOT_URL
  fm_pr_url_parse "$url" || {
    echo 'error: merge-front PR identity is invalid' >&2
    return 1
  }
  provider=$FM_PR_PROVIDER
  repo_path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  if [ "$provider" != github ]; then
    echo 'error: greptile-kick supports GitHub pull requests only' >&2
    return 1
  fi
  if ! pr_row=$(_fm_merge_front_gh gh pr view "$number" \
      --repo "$repo_path" --json state,baseRefName,headRefOid \
      --jq '[.state,.baseRefName,.headRefOid] | @tsv' 2>/dev/null); then
    echo 'error: merge-front PR state could not be read' >&2
    return 1
  fi
  IFS=$'\t' read -r pr_state base head <<< "$pr_row"
  if [ "$pr_state" != OPEN ]; then
    printf 'error: merge-front PR is not open (state=%s)\n' "${pr_state:-unknown}" >&2
    return 1
  fi
  if [ "$base" != main ]; then
    printf 'error: merge-front PR targets %s, not main\n' "${base:-unknown}" >&2
    return 1
  fi
  if ! fm_pr_head_valid "$head"; then
    echo 'error: merge-front PR head could not be validated' >&2
    return 1
  fi
  if ! behind=$(_fm_merge_front_gh gh api \
      "repos/$repo_path/compare/main...$head" --jq .behind_by 2>/dev/null); then
    echo 'error: merge-front PR freshness could not be read' >&2
    return 1
  fi
  case "$behind" in ''|*[!0-9]*)
    echo 'error: merge-front PR freshness was not numeric' >&2
    return 1
    ;;
  esac
  if [ "$behind" -ne 0 ]; then
    printf 'error: merge-front PR is behind main (behind_by=%s)\n' "$behind" >&2
    return 1
  fi
  required_json=$(fm_merge_front_checks_json gh pr checks "$number" \
    --repo "$repo_path" --required --json name,state) || return 1
  blocked=$(printf '%s\n' "$required_json" | jq -r \
    '[.[] | select(((.name | ascii_downcase | contains("greptile")) | not) and (.state as $satisfied | ["SUCCESS","SKIPPED","NEUTRAL"] | index($satisfied) | not)) | "\(.name)=\(.state)"] | join(", ")') || {
      echo 'error: required check state could not be evaluated' >&2
      return 1
    }
  if [ -n "$blocked" ]; then
    printf 'error: non-Greptile required checks are not green: %s\n' "$blocked" >&2
    return 1
  fi
  all_json=$(fm_merge_front_checks_json gh pr checks "$number" \
    --repo "$repo_path" --json name,state) || return 1
  unknown=$(printf '%s\n' "$all_json" | jq -r \
    '[.[] | select(.name | ascii_downcase | contains("greptile")) | .state | select(. as $state | ["PENDING","QUEUED","IN_PROGRESS","WAITING","REQUESTED","EXPECTED","SUCCESS","FAILURE","ERROR","CANCELLED","SKIPPED","NEUTRAL","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE","STALE"] | index($state) | not)] | unique | join(", ")') || {
      echo 'error: Greptile check state could not be evaluated' >&2
      return 1
    }
  if [ -n "$unknown" ]; then
    printf 'error: unrecognised Greptile check state: %s\n' "$unknown" >&2
    return 1
  fi
  pending=$(printf '%s\n' "$all_json" | jq -r \
    '[.[] | select(.name | ascii_downcase | contains("greptile")) | .state | select(. == "PENDING" or . == "QUEUED" or . == "IN_PROGRESS" or . == "WAITING" or . == "REQUESTED" or . == "EXPECTED")] | length') || {
      echo 'error: Greptile pending state could not be evaluated' >&2
      return 1
    }
  if [ "$pending" -ne 0 ]; then
    echo 'error: Greptile review is already pending' >&2
    return 1
  fi
  # The structural gate is re-read under the lock immediately before the single
  # side effect: the queue may have promoted, rebound, or retired this identity
  # while the GitHub reads above ran, and only the current front may be kicked.
  _fm_merge_front_snapshot_front "$project" || return 1
  if [ "$FM_MERGE_FRONT_SNAPSHOT_TASK" != "$task" ] \
    || [ "$FM_MERGE_FRONT_SNAPSHOT_URL" != "$url" ]; then
    printf 'error: merge-front PR is no longer the front of project %s\n' "$project" >&2
    return 1
  fi
  if ! _fm_merge_front_gh gh pr comment "$number" \
      --repo "$repo_path" --body '@greptile review' >/dev/null; then
    echo 'error: Greptile review comment failed' >&2
    return 1
  fi
  printf 'kicked=%s\t%s\n' "$task" "$url"
}
