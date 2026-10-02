# shellcheck shell=bash
# Compact MAIN-owned continuation state embedded in the existing backlog row.
# The task body is the only active progress store.  Its whole-body digest is a
# read token for concurrent correction safety, not an evidence reference.

FM_TASK_PROGRESS_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$FM_TASK_PROGRESS_BIN/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$FM_TASK_PROGRESS_BIN/fm-backlog-transition-lib.sh"

fm_task_progress_decode_scalar() {
  LC_ALL=C perl -MJSON::PP -e '
    local $/;
    my $shown = <STDIN>;
    $shown =~ s/\s+\z//;
    exit 0 if $shown eq "" || $shown eq "-";
    my $encoded = $shown =~ /\A"/;
    my $value = $encoded
      ? JSON::PP->new->utf8->allow_nonref->decode($shown) : $shown;
    binmode STDOUT, ":raw";
    utf8::encode($value) if utf8::is_utf8($value);
    print $value if $encoded || $value ne "-";
  '
}

fm_task_progress_sha256_file() { # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo 'REFUSED: shasum or sha256sum is required for task progress' >&2
    return 1
  fi
}

fm_task_progress_detail() { # <task>; sets FM_TASK_PROGRESS_BODY/GOAL/STATE/HELD/BLOCKED
  local data=${FM_DATA_OVERRIDE:-${FM_HOME:?}/data} out status
  FM_TASK_PROGRESS_BODY=
  FM_TASK_PROGRESS_GOAL=
  FM_TASK_PROGRESS_STATE=
  FM_TASK_PROGRESS_HELD=
  FM_TASK_PROGRESS_BLOCKED=
  out=$(fm_backlog_row_show "$data" "$1" --full)
  status=$?
  [ "$status" -eq 0 ] || {
    printf '%s\n' "${out:-task $1 is not present in the current backlog}" >&2
    return "$status"
  }
  FM_TASK_PROGRESS_STATE=$(printf '%s\n' "$out" | sed -n 's/^  state: *//p' | head -1)
  FM_TASK_PROGRESS_HELD=$(printf '%s\n' "$out" | sed -n 's/^  held: *//p' | head -1)
  FM_TASK_PROGRESS_BLOCKED=$(printf '%s\n' "$out" | sed -n 's/^  blocked: *//p' | head -1)
  FM_TASK_PROGRESS_GOAL=$(printf '%s\n' "$out" | sed -n 's/^  title: //p' | head -1 \
    | fm_task_progress_decode_scalar) || {
    echo "REFUSED: could not decode task $1 goal" >&2
    return 1
  }
  FM_TASK_PROGRESS_BODY=$(printf '%s\n' "$out" | sed -n 's/^  body: //p' | head -1 \
    | fm_task_progress_decode_scalar) || {
    echo "REFUSED: could not decode task $1 body" >&2
    return 1
  }
  [ -n "$FM_TASK_PROGRESS_STATE" ] || {
    echo "REFUSED: task $1 has no readable state" >&2
    return 1
  }
  [ -n "$FM_TASK_PROGRESS_GOAL" ] || {
    echo "REFUSED: task $1 has no readable goal" >&2
    return 1
  }
  case "$FM_TASK_PROGRESS_HELD:$FM_TASK_PROGRESS_BLOCKED" in
    yes:yes|yes:no|no:yes|no:no) ;;
    *) echo "REFUSED: task $1 has unreadable hold or block state" >&2; return 1 ;;
  esac
}

fm_task_progress_read() ( # <task>
  local context
  # Keep configured-backend reads off the unbounded Pi event path.
  # shellcheck disable=SC2030 # This reader is intentionally isolated in a subshell.
  local FM_TASKS_AXI_TIMEOUT=${FM_TASKS_AXI_TIMEOUT:-10}
  fm_task_progress_detail "$1" || return $?
  context=$(fm_task_progress_context "$1") || return $?
  printf '%s' "$FM_TASK_PROGRESS_BODY" | python3 "$FM_TASK_PROGRESS_BIN/fm-task-progress.py" \
    read --task "$1" --goal "$FM_TASK_PROGRESS_GOAL" --state "$FM_TASK_PROGRESS_STATE" \
    --held "$FM_TASK_PROGRESS_HELD" --blocked "$FM_TASK_PROGRESS_BLOCKED" --context "$context"
)

fm_task_progress_execution_generation() { # <task>
  local id=$1 data=${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}
  local state=${FM_STATE_OVERRIDE:-${FM_HOME:?}/state} meta executor provider generation
  meta="$state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  executor=$(sed -n 's/^executor=//p' "$meta" | tail -1)
  case "${executor:-local-agent}" in
    local-agent)
      # Match the metadata owner's canonical last-value semantics without
      # importing the wider backend surface into this focused helper.
      generation=$(sed -n 's/^spawn_gen=//p' "$meta" | tail -1)
      [ -n "$generation" ] || {
        echo "REFUSED: task $id has no current local execution generation" >&2
        return 1
      }
      printf '%s' "$generation"
      ;;
    cloud-worker)
      provider=$(sed -n 's/^provider=//p' "$meta" | tail -1)
      [ "$provider" = aime ] || {
        echo "REFUSED: task $id has an unsupported cloud execution identity" >&2
        return 1
      }
      (
        STATE=$state DATA=$data
        export STATE DATA
        # shellcheck source=bin/fm-aime-cloud-lib.sh
        . "$FM_TASK_PROGRESS_BIN/fm-aime-cloud-lib.sh"
        if ! fm_aime_state_load "$id" || ! fm_aime_meta_validate "$id" "$AIME_STATE_RESULT_MODE"; then
          echo "REFUSED: task $id has no validated cloud execution identity" >&2
          exit 1
        fi
        generation=$(jq -r '.execution_generation // empty' "$AIME_STATE_FILE")
        [ -n "$generation" ] || {
          echo "REFUSED: task $id has no current cloud execution generation" >&2
          exit 1
        }
        printf 'cloud-worker:aime:%s' "$generation"
      )
      ;;
    remote-agent)
      provider=$(sed -n 's/^provider=//p' "$meta" | tail -1)
      case "$provider" in
        aime)
          (
            STATE=$state DATA=$data
            export STATE DATA
            # shellcheck source=bin/fm-aime-cloud-lib.sh
            . "$FM_TASK_PROGRESS_BIN/fm-aime-cloud-lib.sh"
            if ! fm_aime_state_load "$id" || ! fm_aime_meta_validate "$id" "$AIME_STATE_RESULT_MODE"; then
              echo "REFUSED: task $id has no validated remote execution identity" >&2
              exit 1
            fi
            generation=$(jq -r '.execution_generation // empty' "$AIME_STATE_FILE")
            [ -n "$generation" ] || {
              echo "REFUSED: task $id has no current remote execution generation" >&2
              exit 1
            }
            printf 'remote-agent:aime:%s' "$generation"
          )
          ;;
        ida)
          (
            STATE=$state DATA=$data
            export STATE DATA
            # shellcheck source=bin/fm-remote-agent-lib.sh
            . "$FM_TASK_PROGRESS_BIN/fm-remote-agent-lib.sh"
            if ! fm_remote_state_load "$id" || ! fm_remote_meta_validate "$id" ida "$REMOTE_STATE_TASK_TYPE"; then
              echo "REFUSED: task $id has no validated remote execution identity" >&2
              exit 1
            fi
            generation=$(jq -r '.generation // 1' "$REMOTE_STATE_FILE")
            printf 'remote-agent:ida:%s' "$generation"
          )
          ;;
        *)
          echo "REFUSED: task $id has an unsupported remote execution identity" >&2
          return 1
          ;;
      esac
      ;;
    *)
      echo "REFUSED: task $id has an unsupported executor identity" >&2
      return 1
      ;;
  esac
}

# Bind a compact admission to authenticated intent and executor identity
# without persisting either in the task body. A later brief correction or
# worker replacement invalidates the read token and forces MAIN to publish a
# fresh material next step before Branch can act again.
fm_task_progress_context() { # <task>
  local id=$1 data=${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}
  local brief brief_digest='' generation=''
  brief="$data/$id/brief.md"
  if [ -f "$brief" ] && [ ! -L "$brief" ]; then
    brief_digest=$(fm_task_progress_sha256_file "$brief") || return 1
  fi
  generation=$(fm_task_progress_execution_generation "$id") || return 1
  jq -cn --arg goal "$FM_TASK_PROGRESS_GOAL" --arg brief_sha256 "$brief_digest" \
    --arg execution_generation "$generation" --arg task_state "$FM_TASK_PROGRESS_STATE" \
    --arg held "$FM_TASK_PROGRESS_HELD" \
    --arg blocked "$FM_TASK_PROGRESS_BLOCKED" \
    '{goal:$goal,brief_sha256:$brief_sha256,execution_generation:$execution_generation,task_state:$task_state,held:$held,blocked:$blocked}'
}

fm_task_progress_update() ( # <task> <expected-record-token> <progress-json>
  local id=$1 expected=$2 progress=$3 data=${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}
  local state=${FM_STATE_OVERRIDE:-${FM_HOME:?}/state} lock tmp current context rc=0
  # shellcheck disable=SC2030,SC2031 # This mutator is intentionally isolated in a subshell.
  local FM_TASKS_AXI_TIMEOUT=${FM_TASKS_AXI_TIMEOUT:-10}
  [ "${FM_SUPERVISION_ACTOR:-main}" = main ] || {
    echo 'REFUSED: task progress belongs to MAIN' >&2
    exit 6
  }
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_TASK_PROGRESS_BIN/fm-wake-lib.sh"
  # shellcheck source=bin/fm-lease-lib.sh
  . "$FM_TASK_PROGRESS_BIN/fm-lease-lib.sh"
  fm_lease_valid_id "$id" || exit 2
  fm_lease_guard "$id" 'task progress update' || exit $?
  lock=$(fm_meta_lock_path "$state/$id.meta") || exit 1
  trap 'rc=$?; [ -z "${tmp:-}" ] || rm -f -- "$tmp"; fm_lock_release "$lock"; fm_lease_guard_release; exit "$rc"' EXIT
  fm_lock_acquire_wait "$lock" || exit 1
  fm_task_progress_detail "$id" || exit $?
  context=$(fm_task_progress_context "$id") || exit $?
  [ "$FM_TASK_PROGRESS_STATE" != "done" ] || {
    echo "REFUSED: completed task $id cannot receive progress updates" >&2
    exit 6
  }
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-task-progress.XXXXXX") || exit 1
  printf '%s' "$FM_TASK_PROGRESS_BODY" | python3 "$FM_TASK_PROGRESS_BIN/fm-task-progress.py" \
    replace --task "$id" --goal "$FM_TASK_PROGRESS_GOAL" --state "$FM_TASK_PROGRESS_STATE" \
    --held "$FM_TASK_PROGRESS_HELD" --blocked "$FM_TASK_PROGRESS_BLOCKED" \
    --context "$context" --expected-token "$expected" --progress-json "$progress" > "$tmp" || exit $?
  current=$(mktemp "${TMPDIR:-/tmp}/fm-task-progress-current.XXXXXX") || exit 1
  trap 'rc=$?; rm -f -- "$tmp" "$current"; fm_lock_release "$lock"; fm_lease_guard_release; exit "$rc"' EXIT
  printf '%s\n' "$FM_TASK_PROGRESS_BODY" > "$current" || exit 1
  if ! cmp -s "$current" "$tmp"; then
    fm_backlog_mutate "$data" update "$id" --body-file "$tmp" || {
      printf '%s\n' "${FM_BACKLOG_TRANSITION_ERROR:-task progress update failed}" >&2
      exit 1
    }
  fi
  fm_task_progress_read "$id"
)

fm_task_progress_list() ( # active task ids, one per line
  local data=${FM_DATA_OVERRIDE:-${FM_HOME:?}/data} listing
  # shellcheck disable=SC2030,SC2031 # This reader is intentionally isolated in a subshell.
  local FM_TASKS_AXI_TIMEOUT=${FM_TASKS_AXI_TIMEOUT:-10}
  listing=$(fm_backlog_row_list "$data" --state in_flight --limit 10000) || return $?
  printf '%s\n' "$listing" | awk '
    /^tasks\[[0-9]+\]\{id,state,/ { rows=1; next }
    rows && /^  [A-Za-z0-9][A-Za-z0-9._-]*,/ {
      line=$0; sub(/^  /,"",line); sub(/,.*/,"",line); print line; next
    }
    rows { rows=0 }
  ' | jq -Rsc '{tasks:(split("\n") | map(select(length > 0)))}'
)

# Legacy teardown remains available for records that never adopted compact
# continuation. Once the ordinary task body contains compact progress, cleanup
# requires the exact current MAIN-owned satisfied state. Explicit archives pass
# through the lifecycle owner's archived mode before this helper is consulted.
fm_task_progress_completion_guard() ( # <task>
  local id=$1 data=${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}
  local context projection detail_error detail_status root backend file
  # shellcheck disable=SC2031 # This guard is intentionally isolated in a subshell.
  local FM_TASKS_AXI_TIMEOUT=${FM_TASKS_AXI_TIMEOUT:-10}
  root=$(fm_backlog_root "$data") || return $?
  backend=$(fm_tasks_axi_backend "$root") || return $?
  if [ "$backend" = markdown ]; then
    file=$(fm_backlog_file "$data") || return $?
    # Legacy teardown historically supports homes that keep no backlog. Do not
    # introduce a tasks-axi runtime dependency when no ordinary record exists.
    [ -e "$file" ] || [ -L "$file" ] || return 0
  fi
  detail_error=$(mktemp "${TMPDIR:-/tmp}/fm-task-progress-guard.XXXXXX") || {
    echo 'REFUSED: could not allocate compact progress guard state' >&2
    return 1
  }
  trap 'rm -f "$detail_error"' EXIT
  fm_task_progress_detail "$id" 2>"$detail_error"
  detail_status=$?
  if [ "$detail_status" -ne 0 ]; then
    # Historical landed tasks may already have no ordinary backlog row. With
    # no row there can be no active compact progress block to accept; all
    # other backend/read failures remain safety-significant and fail closed.
    if grep -qx 'code: NOT_FOUND' "$detail_error"; then
      return 0
    fi
    cat "$detail_error" >&2
    return "$detail_status"
  fi
  case "$FM_TASK_PROGRESS_BODY" in
    *'<!-- firstmate-progress:v1'*|*'<!-- /firstmate-progress -->'*) ;;
    *) return 0 ;;
  esac
  context=$(fm_task_progress_context "$id") || return $?
  projection=$(printf '%s' "$FM_TASK_PROGRESS_BODY" | python3 "$FM_TASK_PROGRESS_BIN/fm-task-progress.py" \
    read --task "$id" --goal "$FM_TASK_PROGRESS_GOAL" --state "$FM_TASK_PROGRESS_STATE" \
    --held "$FM_TASK_PROGRESS_HELD" --blocked "$FM_TASK_PROGRESS_BLOCKED" --context "$context") || return $?
  printf '%s' "$projection" | jq -e \
    '.recorded == true and .task_state == "in_flight" and .task_held == "no" and
     .task_blocked == "no" and .remaining_gap == "" and .next_step == ""' >/dev/null || {
    echo "REFUSED: compact task $id is not MAIN-accepted; clear its current remaining gap or explicitly archive it before cleanup" >&2
    return 6
  }
)
