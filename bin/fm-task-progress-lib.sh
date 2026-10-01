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
    my $value = $shown =~ /\A"/
      ? JSON::PP->new->utf8->allow_nonref->decode($shown) : $shown;
    binmode STDOUT, ":raw";
    utf8::encode($value) if utf8::is_utf8($value);
    print $value unless $value eq "-";
  '
}

fm_task_progress_detail() { # <task>; sets FM_TASK_PROGRESS_BODY/GOAL/STATE
  local data=${FM_DATA_OVERRIDE:-${FM_HOME:?}/data} out status
  FM_TASK_PROGRESS_BODY=
  FM_TASK_PROGRESS_GOAL=
  FM_TASK_PROGRESS_STATE=
  out=$(fm_backlog_row_show "$data" "$1" --full)
  status=$?
  [ "$status" -eq 0 ] || {
    printf '%s\n' "${out:-task $1 is not present in the current backlog}" >&2
    return "$status"
  }
  FM_TASK_PROGRESS_STATE=$(printf '%s\n' "$out" | sed -n 's/^  state: *//p' | head -1)
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
}

fm_task_progress_read() { # <task>
  fm_task_progress_detail "$1" || return $?
  printf '%s' "$FM_TASK_PROGRESS_BODY" | python3 "$FM_TASK_PROGRESS_BIN/fm-task-progress.py" \
    read --task "$1" --goal "$FM_TASK_PROGRESS_GOAL" --state "$FM_TASK_PROGRESS_STATE"
}

fm_task_progress_update() ( # <task> <expected-record-token> <progress-json>
  local id=$1 expected=$2 progress=$3 data=${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}
  local state=${FM_STATE_OVERRIDE:-${FM_HOME:?}/state} lock tmp current rc=0
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
  [ "$FM_TASK_PROGRESS_STATE" != "done" ] || {
    echo "REFUSED: completed task $id cannot receive progress updates" >&2
    exit 6
  }
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-task-progress.XXXXXX") || exit 1
  printf '%s' "$FM_TASK_PROGRESS_BODY" | python3 "$FM_TASK_PROGRESS_BIN/fm-task-progress.py" \
    replace --task "$id" --goal "$FM_TASK_PROGRESS_GOAL" --state "$FM_TASK_PROGRESS_STATE" \
    --expected-token "$expected" --progress-json "$progress" > "$tmp" || exit $?
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

fm_task_progress_list() { # active task ids, one per line
  local data=${FM_DATA_OVERRIDE:-${FM_HOME:?}/data} listing
  listing=$(fm_backlog_row_list "$data" --state in_flight --limit 10000) || return $?
  printf '%s\n' "$listing" | awk '
    /^tasks\[[0-9]+\]\{id,state,/ { rows=1; next }
    rows && /^  [A-Za-z0-9][A-Za-z0-9._-]*,/ {
      line=$0; sub(/^  /,"",line); sub(/,.*/,"",line); print line; next
    }
    rows { rows=0 }
  ' | jq -Rsc '{tasks:(split("\n") | map(select(length > 0)))}'
}
