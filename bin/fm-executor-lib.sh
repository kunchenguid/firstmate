#!/usr/bin/env bash
# fm-executor-lib.sh - shared mechanics for kind=executor tasks: the one-shot,
# headless worker that closes exactly one GitHub issue, opens a pull request,
# and exits (AGENTS.md section 7, the executor-dispatch skill).
#
# Sourced by bin/fm-spawn.sh, bin/fm-executor-poll.sh, bin/fm-watch.sh,
# bin/fm-crew-state.sh, bin/fm-control.sh, and bin/fm-teardown.sh. Callers must
# already have sourced bin/fm-backend.sh (fm_meta_get, fm_backend_agent_state,
# fm_backend_of_meta, fm_backend_target_of_meta) and bin/fm-pr-lib.sh (the file
# validators and fm_pr_url_parse). This file has no side effects on source.
#
# An executor writes no status line, arms no busy-state hook, and reads no
# steering inbox, so its state is derived from two structural facts and nothing
# the worker itself says:
#   1. Process exit. bin/fm-spawn.sh appends `; printf '%s\n' "$?" >
#      state/<id>.executor-exit` to the launch line, so the PANE SHELL - never
#      the model - records that the one-shot command returned, on every
#      adapter, raw command, and spawn-capable backend alike. Until that marker
#      exists the process is running, except that an endpoint the backend
#      reports authoritatively missing also reads as exited (nothing is left
#      to finish the work). A pane whose foreground is a bare shell but whose
#      marker is absent is the transient between launch delivery and the
#      command starting, or a relaunch that just cleared the previous marker,
#      and stays "running" until the runtime bound below.
#   2. Pull-request presence on the task branch fm/<id>, read live with
#      `gh pr list --head` from inside the task worktree. A CLOSED pull request
#      (a bounced attempt) never counts; OPEN wins over MERGED.
# fm_executor_classify combines them:
#   working <minutes>                 process running inside the bound
#   stale <minutes-past-bound>        process running past FM_EXECUTOR_MAX_RUNTIME
#   ready <url> <draft|ready|merged>  exited with a pull request on fm/<id>
#   failed-no-commits                 exited, no pull request, branch at its base
#   failed-no-pr                      exited, no pull request, commits on the branch
# It returns 0 with one of those verdicts, 2 when gh could not answer (the
# caller stays silent and non-zero rather than reading "no PR"), and 1 when the
# task has nothing left to classify (worktree gone, unreadable git state).
#
# FM_EXECUTOR_MAX_RUNTIME (seconds, default 7200) bounds a running executor;
# docs/configuration.md "Environment variables" documents it. A value that is
# not a positive integer falls back to the default.
#
# The poll's validated private record is the task's own state/<id>.meta, which
# bin/fm-spawn.sh writes under the task's meta lock: kind=executor, spawn_gen=,
# worktree=, the endpoint, executor_base= (the branch's base commit at launch)
# and executor_launched= (the launch epoch). state/<id>.check.sh is a byte copy
# of bin/fm-executor-poll.sh; fm_executor_poll_snapshot_capture proves the copy
# is byte-identical to the tracked template, then reads and shape-validates
# those meta fields into FM_EXECUTOR_* so the watcher runs the TRACKED script
# with them as arguments. No task data is ever interpolated into shell source.
#
# Each distinct outcome wakes firstmate once per incarnation: the watcher keys a
# private state/<id>.executor-notified marker on (spawn_gen, outcome key) after
# the durable wake is appended, the same shape bin/fm-pr-lib.sh uses for merge
# notification. A relaunch mints a new spawn_gen, so the next incarnation's
# outcomes wake again.

FM_EXECUTOR_MAX_RUNTIME_DEFAULT=7200
FM_EXECUTOR_HEADLESS_HARNESSES='claude codex opencode'
FM_EXECUTOR_GEN=
FM_EXECUTOR_WORKTREE=
FM_EXECUTOR_BACKEND=
FM_EXECUTOR_TARGET=
FM_EXECUTOR_BASE=
FM_EXECUTOR_LAUNCHED=

fm_executor_issue_valid() {  # <n>
  local n=${1-}
  local LC_ALL=C
  case "$n" in
    ''|*[!0-9]*|0*) return 1 ;;
  esac
  [ "${#n}" -le 9 ]
}

# The adapters whose non-interactive one-shot form bin/fm-spawn.sh's
# launch_template carries and docs/verification/executor.md records. Every
# other adapter is refused for --executor rather than launched interactively.
fm_executor_harness_headless() {  # <harness>
  case " $FM_EXECUTOR_HEADLESS_HARNESSES " in
    *" ${1-} "*) return 0 ;;
  esac
  return 1
}

fm_executor_gen_valid() {  # <spawn_gen>
  local gen=${1-}
  local LC_ALL=C
  case "$gen" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#gen}" -le 128 ]
}

fm_executor_commit_valid() {  # <sha>
  local sha=${1-}
  local LC_ALL=C
  [ "${#sha}" -eq 40 ] || return 1
  case "$sha" in
    *[!0-9a-f]*) return 1 ;;
  esac
}

fm_executor_epoch_valid() {  # <epoch>
  local epoch=${1-}
  local LC_ALL=C
  case "$epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#epoch}" -le 12 ]
}

fm_executor_max_runtime() {
  local bound=${FM_EXECUTOR_MAX_RUNTIME:-}
  case "$bound" in
    ''|*[!0-9]*|0*) bound=$FM_EXECUTOR_MAX_RUNTIME_DEFAULT ;;
  esac
  printf '%s' "$bound"
}

fm_executor_exit_marker_path() {  # <state> <id>
  printf '%s/%s.executor-exit' "$1" "$2"
}

fm_executor_notified_path() {  # <state> <id>
  printf '%s/%s.executor-notified' "$1" "$2"
}

# The canonical issue URL derived from the project's origin remote, printed
# only when that remote is github.com; any other host or shape prints nothing
# and returns 1, so the caller records no issue_url= rather than a guess.
fm_executor_origin_issue_url() {  # <project-dir> <issue>
  local project=$1 issue=$2 remote owner repo
  local LC_ALL=C
  fm_executor_issue_valid "$issue" || return 1
  remote=$(git -C "$project" remote get-url origin 2>/dev/null) || return 1
  case "$remote" in
    https://github.com/*/*) remote=${remote#https://github.com/} ;;
    ssh://git@github.com/*/*) remote=${remote#ssh://git@github.com/} ;;
    git@github.com:*/*) remote=${remote#git@github.com:} ;;
    *) return 1 ;;
  esac
  remote=${remote%/}
  remote=${remote%.git}
  owner=${remote%%/*}
  repo=${remote#*/}
  case "$repo" in */*) return 1 ;; esac
  fm_pr_url_parse "https://github.com/$owner/$repo/pull/1" || return 1
  printf 'https://github.com/%s/%s/issues/%s' "$owner" "$repo" "$issue"
}

# Publish the byte-static poll as this task's slow check. A previous
# incarnation's merge poll for a bounced pull request may still own the check
# name and its private sidecar and registration; the relaunched executor's poll
# replaces all three, because the next pull request is a new one that
# bin/fm-pr-check.sh records afresh on the executor-ready wake.
fm_executor_poll_publish() {  # <state> <id> <template>
  local state=$1 id=$2 template=$3 dest tmp device
  fm_pr_task_id_valid "$id" || return 1
  [ -f "$template" ] && [ ! -L "$template" ] || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  device=$(fm_pr_file_device "$state") || return 1
  dest="$state/$id.check.sh"
  fm_pr_regular_destination_on_device_or_absent "$dest" "$device" || return 1
  fm_pr_regular_destination_on_device_or_absent "$state/$id.pr-poll" "$device" || return 1
  fm_pr_regular_destination_on_device_or_absent "$state/$id.pr-poll-registration" "$device" || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-executor-check.XXXXXX") || return 1
  if ! cp "$template" "$tmp" || ! chmod 0600 "$tmp" || ! cmp -s "$template" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$state/$id.pr-poll" "$state/$id.pr-poll-registration" || { rm -f -- "$tmp"; return 1; }
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_private_file_valid "$dest" 600 "$device" && cmp -s "$template" "$dest"
}

# Prove state/<id>.check.sh is the tracked executor poll and read the task's
# validated record into FM_EXECUTOR_*. Every field is shape-checked here and
# again by fm_executor_classify, so a doctored record cannot point the poll at
# another worktree, branch, or endpoint.
fm_executor_poll_snapshot_capture() {  # <state> <id> <template>
  local state=$1 id=$2 template=$3 device check meta
  FM_EXECUTOR_GEN=
  FM_EXECUTOR_WORKTREE=
  FM_EXECUTOR_BACKEND=
  FM_EXECUTOR_TARGET=
  FM_EXECUTOR_BASE=
  FM_EXECUTOR_LAUNCHED=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  [ -f "$template" ] && [ ! -L "$template" ] || return 1
  device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  meta="$state/$id.meta"
  fm_pr_private_file_valid "$check" 600 "$device" || return 1
  cmp -s "$template" "$check" || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_pr_file_link_count "$meta")" = 1 ] || return 1
  [ "$(fm_pr_file_device "$meta")" = "$device" ] || return 1
  [ "$(fm_meta_get "$meta" kind)" = executor ] || return 1
  FM_EXECUTOR_GEN=$(fm_meta_get "$meta" spawn_gen)
  FM_EXECUTOR_WORKTREE=$(fm_meta_get "$meta" worktree)
  FM_EXECUTOR_BACKEND=$(fm_backend_of_meta "$meta")
  FM_EXECUTOR_TARGET=$(fm_backend_target_of_meta "$meta")
  FM_EXECUTOR_BASE=$(fm_meta_get "$meta" executor_base)
  FM_EXECUTOR_LAUNCHED=$(fm_meta_get "$meta" executor_launched)
  fm_executor_fields_valid "$FM_EXECUTOR_GEN" "$FM_EXECUTOR_WORKTREE" "$FM_EXECUTOR_BACKEND" \
    "$FM_EXECUTOR_TARGET" "$FM_EXECUTOR_BASE" "$FM_EXECUTOR_LAUNCHED"
}

fm_executor_fields_valid() {  # <gen> <worktree> <backend> <target> <base> <launched>
  local gen=$1 worktree=$2 backend=$3 target=$4 base=$5 launched=$6
  local LC_ALL=C
  fm_executor_gen_valid "$gen" || return 1
  case "$worktree" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$worktree" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  fm_backend_is_known "$backend" || return 1
  [ -n "$target" ] || return 1
  case "$target" in
    *[[:space:][:cntrl:]]*) return 1 ;;
  esac
  fm_executor_commit_valid "$base" || return 1
  fm_executor_epoch_valid "$launched"
}

# One live pull-request read for the task branch. Prints "<url>\t<draft|ready|merged>"
# for the best match (OPEN before MERGED, CLOSED never), nothing when there is
# no pull request, and returns 2 when gh could not answer. gh's built-in --jq
# iterates the array, so an empty result prints nothing rather than a literal
# null.
fm_executor_pr_lookup() {  # <worktree> <id>
  local worktree=$1 id=$2 out url draft state open='' merged=''
  command -v gh >/dev/null 2>&1 || return 2
  out=$(cd "$worktree" 2>/dev/null && gh pr list --head "fm/$id" --state all \
    --json url,isDraft,state \
    --jq '.[] | select(.state != "CLOSED") | [.url, (.isDraft | tostring), .state] | @tsv' 2>/dev/null) \
    || return 2
  while IFS=$'\t' read -r url draft state; do
    [ -n "$url" ] || continue
    fm_pr_url_parse "$url" || continue
    case "$state" in
      OPEN)
        [ -n "$open" ] && continue
        if [ "$draft" = true ]; then open="$url"$'\t'draft; else open="$url"$'\t'ready; fi
        ;;
      MERGED)
        [ -n "$merged" ] || merged="$url"$'\t'merged
        ;;
    esac
  done <<EOF
$out
EOF
  if [ -n "$open" ]; then
    printf '%s\n' "$open"
  elif [ -n "$merged" ]; then
    printf '%s\n' "$merged"
  fi
  return 0
}

fm_executor_classify() {  # <state> <id> <gen> <worktree> <backend> <target> <base> <launched>
  local state=$1 id=$2 gen=$3 worktree=$4 backend=$5 target=$6 base=$7 launched=$8
  local marker exited=0 agent_state now age bound pr url flag ahead
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  fm_executor_fields_valid "$gen" "$worktree" "$backend" "$target" "$base" "$launched" || return 1
  marker=$(fm_executor_exit_marker_path "$state" "$id")
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    exited=1
  else
    agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || agent_state=unreadable
    [ "$agent_state" != missing ] || exited=1
  fi
  if [ "$exited" -eq 0 ]; then
    now=$(date +%s)
    age=$((now - launched))
    [ "$age" -ge 0 ] || age=0
    bound=$(fm_executor_max_runtime)
    if [ "$age" -gt "$bound" ]; then
      printf 'stale %s\n' "$(((age - bound) / 60))"
    else
      printf 'working %s\n' "$((age / 60))"
    fi
    return 0
  fi
  [ -d "$worktree" ] || return 1
  pr=$(fm_executor_pr_lookup "$worktree" "$id") || return 2
  if [ -n "$pr" ]; then
    url=${pr%%$'\t'*}
    flag=${pr#*$'\t'}
    printf 'ready %s %s\n' "$url" "$flag"
    return 0
  fi
  ahead=$(git -C "$worktree" rev-list --count "$base..HEAD" 2>/dev/null) || return 1
  case "$ahead" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$ahead" -eq 0 ]; then
    printf 'failed-no-commits\n'
  else
    printf 'failed-no-pr\n'
  fi
}

# Render a classify verdict as the poll's single wake line; the working verdict
# renders nothing, which is the poll's silence.
fm_executor_poll_line() {  # <verdict-line>
  local verdict=$1 word rest
  word=${verdict%% *}
  rest=${verdict#* }
  case "$word" in
    working) return 0 ;;
    stale) printf 'executor-stale: running %sm past the bound\n' "$rest" ;;
    ready)
      case "${rest##* }" in
        draft) printf 'executor-ready: PR %s draft\n' "${rest% *}" ;;
        *) printf 'executor-ready: PR %s ready\n' "${rest% *}" ;;
      esac
      ;;
    failed-no-commits) printf 'executor-failed: no commits and no PR (verify likely failed before commit)\n' ;;
    failed-no-pr) printf 'executor-failed: committed but no PR\n' ;;
    *) return 1 ;;
  esac
}

# The dedupe key for one printed poll line; fails on a line the poll never
# prints so the watcher treats it as an ordinary check line.
fm_executor_outcome_key() {  # <poll-line>
  case "$1" in
    'executor-ready: PR '*' draft') printf 'ready-draft' ;;
    'executor-ready: PR '*' ready') printf 'ready-ready' ;;
    'executor-failed: no commits and no PR'*) printf 'failed-no-commits' ;;
    'executor-failed: committed but no PR') printf 'failed-no-pr' ;;
    'executor-stale: running '*) printf 'stale' ;;
    *) return 1 ;;
  esac
}

fm_executor_notified_marker_matches() {  # <marker> <device> <gen> <key>
  local marker=$1 device=$2 gen=$3 key=$4 version got_gen got_key
  fm_pr_private_file_valid "$marker" 600 "$device" || return 1
  exec 8< "$marker" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r got_gen <&8 || { exec 8<&-; return 1; }
  IFS= read -r got_key <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  [ "$version" = fm-executor-notified-v1 ] && [ "$got_gen" = "$gen" ] && [ "$got_key" = "$key" ]
}

fm_executor_outcome_already_notified() {  # <state> <id> <gen> <key>
  local state=$1 id=$2 gen=$3 key=$4 device
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  device=$(fm_pr_file_device "$state") || return 1
  fm_executor_notified_marker_matches "$(fm_executor_notified_path "$state" "$id")" "$device" "$gen" "$key"
}

fm_executor_outcome_mark_notified() {  # <state> <id> <gen> <key>
  local state=$1 id=$2 gen=$3 key=$4 device marker tmp
  fm_pr_task_id_valid "$id" || return 1
  fm_executor_gen_valid "$gen" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  device=$(fm_pr_file_device "$state") || return 1
  marker=$(fm_executor_notified_path "$state" "$id")
  fm_pr_regular_destination_on_device_or_absent "$marker" "$device" || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-executor-notified.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n' fm-executor-notified-v1 "$gen" "$key" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_executor_notified_marker_matches "$tmp" "$device" "$gen" "$key" \
    || ! fm_pr_regular_destination_on_device_or_absent "$marker" "$device" \
    || ! mv -f -- "$tmp" "$marker" \
    || ! fm_executor_notified_marker_matches "$marker" "$device" "$gen" "$key"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Remove the per-incarnation records: at relaunch so the next run starts with
# no exit evidence and no delivered outcome, and at teardown with the rest of
# the volatile state. Never touches the check, which the caller owns.
fm_executor_incarnation_records_remove() {  # <state> <id>
  local state=$1 id=$2 path
  fm_pr_task_id_valid "$id" || return 1
  for path in "$(fm_executor_exit_marker_path "$state" "$id")" "$(fm_executor_notified_path "$state" "$id")"; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    rm -f -- "$path" || return 1
  done
}
