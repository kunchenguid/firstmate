# shellcheck shell=bash
# Fused backlog transitions for the scripts that own a task's physical record.
# Usage: . bin/fm-tasks-axi-lib.sh; . bin/fm-backlog-transition-lib.sh
# (this library reads that one's backend gate and never sources it itself, so a
# caller that already sourced it keeps its memoised compatibility verdict).
#
# INVARIANT. In ordinary successful lifecycle state, `state/<id>.meta` exists
# <=> this home's backlog row for <id> is In flight; the one teardown crash
# window is represented by `state/<id>.backlog-close`. The script performing the
# mechanical record change owns the paired backlog transition and runs it in the
# same process, under the per-task meta lock it already holds, before it reports
# success. Nothing else - not a later agent turn, not a printed reminder - is
# load-bearing for the pairing.
#   bin/fm-spawn.sh      meta published => `tasks-axi start`
#   bin/fm-teardown.sh   meta removed => `tasks-axi done`, or `tasks-axi reopen`
#                        with the deliverable recorded when the row is still an
#                        open captain call (bin/fm-captain-hold.sh `open`), so
#                        cleanup never retires the captain's own question
#   bin/fm-bootstrap.sh  replays whatever a crash left behind, THIS HOME ONLY.
# bin/fm-fleet-snapshot.sh's classifier and bin/fm-secondmate-reconcile.sh's
# cross-home nudge stay defense in depth, not the primary mechanism.
#
# SCOPE. fm_backlog_transition_applies is the single gate. It excludes
# secondmates (persistent agents are never backlog items, AGENTS.md section 10),
# and homes whose configured backlog backend is manual. Markdown homes that
# keep no backlog file at all are likewise exempt. Those return-1 exemptions
# are never errors; a home on any other configured backend has no markdown
# file requirement at all. An unresolvable configured data directory or
# incompatible tasks-axi instead returns 2 so callers refuse before mutation.
#
# ADDRESSING. The markdown backend owns the explicit `--file <data>/backlog.md`
# on every mutation and row probe so the change lands in the home that owns
# the task regardless of the caller's working directory. Every other
# configured backend is addressed from that data directory's parent - the
# addressing root - with no markdown file override, so the same home's
# `.tasks.toml` supplies its backend, done_keep, and the archive path and
# backend-owned state remains discoverable. The parent of the data directory
# is the addressing root rather than FM_HOME, so a home whose data directory
# is relocated keeps its backlog and its archive together. A root with no
# `.tasks.toml` gets tasks-axi's built-in defaults.
#
# CRASH RECOVERY. Only teardown needs a durable record: it removes the meta and
# with it the completion links, so a process killed between the two halves would
# leave nothing to reconstruct the close from. It writes
# `state/<id>.backlog-close` first, and removes it once the close lands.
# The writer and replay share one complete-record validator, and teardown stages
# that record before destructive cleanup, so it never publishes or acts on a close
# replay would reject. The validator pins the data path to this home's configured
# root before any recovery mutation, then re-runs exactly that close.
# `tasks-axi done` on an already-closed task backfills links
# without moving the close date, so replay is idempotent. Spawn needs no marker:
# it publishes the meta first, so a crash
# leaves the meta itself as the evidence that the row is owed a start.
# A captain-held row uses the same record with a `mode=retain` line: replay then
# records the deliverable and reopens the row instead of closing it, and never
# closes a row that reads as an open captain call. An answer that closed the row
# first simply retires the record.

# Set by fm_backlog_transition_applies for a return-1 exemption.
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_BACKLOG_TRANSITION_SKIP=
# Set by the mutating helpers when they return non-zero.
FM_BACKLOG_TRANSITION_ERROR=
FM_BACKLOG_ROW_RESULT=
FM_BACKLOG_ROW_STATE=
FM_BACKLOG_ROW_ERROR=
# Set by fm_backlog_row_probe on a found row: the tasks-axi hold kind, empty when
# the row is not held.
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_BACKLOG_ROW_HOLD_KIND=
# Set by fm_backlog_close_marker_replay: closed | closed_incomplete | retained |
# retained_incomplete | answered | stale | noop.
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_BACKLOG_CLOSE_REPLAY_RESULT=

# Emit each byte of a value as a decimal number, locale-independently.
# Deliberately perl rather than od: the spawn and teardown lifecycle runs under a
# curated PATH (tests/fm-teardown.test.sh make_path_without_lsof pins that set)
# that excludes od, and a validator that cannot run must never wedge dispatch or
# cleanup. perl is already in that curated set and is already used elsewhere in
# this repo for the same portability reason.
fm_backlog_bytes_of_string() {  # <string>
  perl -e 'print join(" ", unpack("C*", $ARGV[0])), "\n"' -- "$1"
}

fm_backlog_bytes_of_file() {  # <path>
  perl -e 'open(my $f, "<", $ARGV[0]) or exit 1; binmode $f; local $/; my $c = <$f>; $c = "" unless defined $c; print join(" ", unpack("C*", $c)), "\n"' -- "$1"
}

fm_backlog_control_bytes_valid() {  # <allow-newline: 0|1> <od-bytes>
  printf '%s\n' "$2" | awk -v allow_newline="$1" '
    { for (i = 1; i <= NF; i++) if (($i < 32 && !(allow_newline && $i == 10)) || $i == 127) exit 1 }
  '
}

fm_backlog_directory_present() {
  local path=$1 label=$2 check=$1
  while [ "$check" != / ] && [ "${check%/}" != "$check" ]; do
    check=${check%/}
  done
  if [ ! -d "$check" ] || [ -L "$check" ]; then
    FM_BACKLOG_TRANSITION_ERROR="$label is not a real directory at $path"
    return 1
  fi
}

fm_backlog_data_absolute() {
  local data=$1 raw_bytes check
  raw_bytes=$(fm_backlog_bytes_of_string "$data") || return 1
  if ! fm_backlog_control_bytes_valid 0 "$raw_bytes"; then
    printf 'error: data directory contains an invalid control byte\n' >&2
    return 2
  fi
  check=$data
  while [ "$check" != / ] && [ "${check%/}" != "$check" ]; do
    check=${check%/}
  done
  if [ ! -d "$check" ]; then
    FM_BACKLOG_TRANSITION_ERROR="data directory is not a directory at $data"
    return 1
  fi
  if ! data=$(CDPATH='' cd -- "$data" 2>/dev/null && pwd -P); then
    return 1
  fi
  printf '%s\n' "$data"
}

fm_backlog_file() {  # <data-dir>
  local data
  data=$(fm_backlog_data_absolute "$1") || {
    FM_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $1"
    return 1
  }
  if [ "$data" = / ]; then
    printf '/backlog.md\n'
  else
    printf '%s/backlog.md\n' "$data"
  fi
}

# The directory a backlog's own `.tasks.toml` is resolved from.
fm_backlog_root() {  # <data-dir>
  local data parent
  data=$(fm_backlog_data_absolute "$1") || {
    FM_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $1"
    return 1
  }
  case "$data" in
    */*)
      parent=${data%/*}
      [ -n "$parent" ] || parent=/
      ;;
    *) parent=. ;;
  esac
  printf '%s\n' "$parent"
}

fm_backlog_data_relative() {  # <data-dir>
  local data root
  data=$(fm_backlog_data_absolute "$1") || {
    FM_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $1"
    return 1
  }
  root=$(fm_backlog_root "$data") || return 1
  if [ "$data" = "$root" ]; then
    printf '.\n'
    return 0
  fi
  if [ "$root" = / ]; then
    printf '%s\n' "${data#/}"
    return 0
  fi
  case "$data" in
    "$root"/*) printf '%s\n' "${data#"$root"/}" ;;
    *) printf '%s\n' "$data" ;;
  esac
}

fm_backlog_transition_applies() {  # <config-dir> <data-dir> <kind>
  local config=$1 data authorized_data=$2 kind=$3 file root
  FM_BACKLOG_TRANSITION_SKIP=
  if [ "$kind" = secondmate ]; then
    FM_BACKLOG_TRANSITION_SKIP="secondmates are not backlog items"
    return 1
  fi
  if fm_backlog_backend_manual "$config"; then
    FM_BACKLOG_TRANSITION_SKIP="config/backlog-backend selects manual editing"
    return 1
  fi
  if ! data=$(fm_backlog_data_absolute "$2"); then
    FM_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $2"
    return 2
  fi
  root=$(fm_backlog_root "$data") || return 2
  if [ "$(fm_tasks_axi_backend "$root")" = markdown ]; then
    file=$(fm_backlog_file "$data")
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
      FM_BACKLOG_TRANSITION_SKIP="this home keeps no backlog at $file"
      return 1
    fi
    if ! fm_backlog_record_present "$file" "backlog file" "$authorized_data"; then
      return 2
    fi
  fi
  if ! fm_tasks_axi_compatible; then
    FM_BACKLOG_TRANSITION_ERROR="automatic backlog transitions require tasks-axi $FM_TASKS_AXI_MIN or newer with the required update and mv features"
    return 2
  fi
  return 0
}

# Print one row's `tasks-axi show` output (plus stderr) from the backlog root,
# with `--file` only for the markdown backend; the exit status is tasks-axi's.
# Extra flags (such as --full) are passed through.
fm_backlog_row_show() {  # <resolved-data-dir> <id> [flag...]
  local data=$1 id=$2 file root
  shift 2
  file=$(fm_backlog_file "$data") || return 1
  root=$(fm_backlog_root "$data") || return 1
  if [ "$(fm_tasks_axi_backend "$root")" = markdown ]; then
    (cd "$root" 2>/dev/null && tasks-axi show "$id" "$@" --file "$file" 2>&1)
  else
    (cd "$root" 2>/dev/null && tasks-axi show "$id" "$@" 2>&1)
  fi
}

fm_backlog_row_list() {  # <resolved-data-dir> [flag...]
  local data=$1 file root
  shift
  file=$(fm_backlog_file "$data") || return 1
  root=$(fm_backlog_root "$data") || return 1
  if [ "$(fm_tasks_axi_backend "$root")" = markdown ]; then
    (cd "$root" 2>/dev/null && tasks-axi list "$@" --file "$file" 2>&1)
  else
    (cd "$root" 2>/dev/null && tasks-axi list "$@" 2>&1)
  fi
}

fm_backlog_row_probe() {  # <data-dir> <id>
  local data authorized_data=$1 file id=$2 out state held blocked hold_kind command_status root
  if ! data=$(fm_backlog_data_absolute "$1"); then
    FM_BACKLOG_ROW_RESULT=error
    FM_BACKLOG_ROW_STATE=
    FM_BACKLOG_ROW_ERROR="data directory cannot be resolved: $1"
    return 1
  fi
  FM_BACKLOG_ROW_RESULT=error
  FM_BACKLOG_ROW_STATE=
  FM_BACKLOG_ROW_HOLD_KIND=
  FM_BACKLOG_ROW_ERROR=
  root=$(fm_backlog_root "$data") || {
    FM_BACKLOG_ROW_ERROR=$FM_BACKLOG_TRANSITION_ERROR
    return 1
  }
  if [ "$(fm_tasks_axi_backend "$root")" = markdown ]; then
    file=$(fm_backlog_file "$data") || {
      FM_BACKLOG_ROW_ERROR=$FM_BACKLOG_TRANSITION_ERROR
      return 1
    }
    if ! fm_backlog_record_present "$file" "backlog file" "$authorized_data"; then
      FM_BACKLOG_ROW_ERROR=$FM_BACKLOG_TRANSITION_ERROR
      return 1
    fi
  fi
  out=$(fm_backlog_row_show "$data" "$id")
  command_status=$?
  if [ "$command_status" -ne 0 ]; then
    if printf '%s\n' "$out" | grep -q '^code: NOT_FOUND$'; then
      FM_BACKLOG_ROW_RESULT=not_found
    else
      FM_BACKLOG_ROW_ERROR=$(printf '%s\n' "$out" | sed -n '1p')
      [ -n "$FM_BACKLOG_ROW_ERROR" ] \
        || FM_BACKLOG_ROW_ERROR="tasks-axi show $id failed with no output"
    fi
    return "$command_status"
  fi
  state=$(printf '%s\n' "$out" | sed -n 's/^  state: *//p' | head -1)
  held=$(printf '%s\n' "$out" | sed -n 's/^  held: *//p' | head -1)
  blocked=$(printf '%s\n' "$out" | sed -n 's/^  blocked: *//p' | head -1)
  hold_kind=$(printf '%s\n' "$out" | sed -n 's/^  hold_kind: *//p' | head -1)
  if [ -z "$state" ]; then
    FM_BACKLOG_ROW_ERROR="tasks-axi show $id returned no state"
    return 1
  fi
  FM_BACKLOG_ROW_RESULT=found
  FM_BACKLOG_ROW_STATE="$state ${held:-no} ${blocked:-no}"
  case "$hold_kind" in
    ''|'"-"'|-) FM_BACKLOG_ROW_HOLD_KIND= ;;
    *) FM_BACKLOG_ROW_HOLD_KIND=$hold_kind ;;
  esac
  return 0
}

# Run one tasks-axi mutation against <home>'s backlog, capturing its first
# output line in FM_BACKLOG_TRANSITION_ERROR on failure. The markdown backend
# keeps its explicit <data>/backlog.md file and presence requirement; every
# other configured backend is addressed by the root's own tasks-axi
# configuration, so passing the markdown-era path would write the wrong store.
fm_backlog_mutate() {  # <data-dir> <verb> <id> [flag...]
  local data authorized_data=$1 file verb=$2 id=$3 out command_status root
  if ! data=$(fm_backlog_data_absolute "$1"); then
    FM_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $1"
    return 1
  fi
  shift 3
  FM_BACKLOG_TRANSITION_ERROR=
  root=$(fm_backlog_root "$data") || return 1
  if [ "$(fm_tasks_axi_backend "$root")" != markdown ]; then
    out=$(cd "$root" 2>/dev/null && tasks-axi "$verb" "$id" "$@" 2>&1)
    command_status=$?
  else
    file=$(fm_backlog_file "$data") || return 1
    fm_backlog_record_present "$file" "backlog file" "$authorized_data" || return 1
    out=$(cd "$root" 2>/dev/null && tasks-axi "$verb" "$id" \
        --file "$file" "$@" 2>&1)
    command_status=$?
  fi
  [ "$command_status" -ne 0 ] || return 0
  FM_BACKLOG_TRANSITION_ERROR=$(printf '%s\n' "$out" | sed -n '1p')
  [ -n "$FM_BACKLOG_TRANSITION_ERROR" ] \
    || FM_BACKLOG_TRANSITION_ERROR="tasks-axi $verb $id failed with no output"
  return "$command_status"
}

fm_backlog_start() {  # <data-dir> <id>
  fm_backlog_mutate "$1" start "$2"
}

fm_backlog_done() {  # <data-dir> <id> [flag...]
  local data=$1 id=$2
  shift 2
  fm_backlog_mutate "$data" "done" "$id" "$@"
}

fm_backlog_row_artifact_supported() {
  local id=$1 flag=${2:-} value=${3:-}
  case "$flag" in
    --pr) return 0 ;;
    --report) [ "$value" = "data/$id/report.md" ] ;;
    *) return 1 ;;
  esac
}

# Keep a captain-held row open across the removal of the work record that
# discovered it: record the finished work's deliverable as one line at the end
# of the task body (a line already present is left alone), preserve supported
# artifacts on the row, and return it to Queued, the conventional post-cleanup
# shape for an open captain call.
# bin/fm-fleet-snapshot.sh classifies that retained hold from its structured
# fields; only bin/fm-captain-hold.sh answer closes the call.
fm_backlog_retain() {  # <data-dir> <id> [flag...]
  local data authorized_data=$1 id=$2 out command_status previous_arg=''
  local arg deliverable='' line body new_body tmp
  local -a row_args=()
  if ! data=$(fm_backlog_data_absolute "$1"); then
    FM_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $1"
    return 1
  fi
  shift 2
  FM_BACKLOG_TRANSITION_ERROR=
  for arg in "$@"; do
    case "$previous_arg" in
      --report)
        deliverable="${deliverable:+$deliverable; }report $arg"
        if fm_backlog_row_artifact_supported "$id" --report "$arg"; then
          row_args=(--report "$arg")
        fi
        ;;
      --pr)
        deliverable="${deliverable:+$deliverable; }PR $arg"
        row_args=(--pr "$arg")
        ;;
      --note) deliverable="${deliverable:+$deliverable; }$arg" ;;
    esac
    previous_arg=$arg
  done
  if [ -n "$deliverable" ]; then
    out=$(fm_backlog_row_show "$data" "$id" --full)
    command_status=$?
    if [ "$command_status" -ne 0 ]; then
      FM_BACKLOG_TRANSITION_ERROR=$(printf '%s\n' "$out" | sed -n '1p')
      [ -n "$FM_BACKLOG_TRANSITION_ERROR" ] \
        || FM_BACKLOG_TRANSITION_ERROR="tasks-axi show $id failed with no output"
      return "$command_status"
    fi
    body=$(printf '%s\n' "$out" | sed -n 's/^  body: //p' | head -1 \
      | LC_ALL=C perl -MJSON::PP -e '
        local $/;
        my $shown = <STDIN>;
        $shown =~ s/\s+\z//;
        exit 0 if $shown eq "" || $shown eq "-";
        my $value = $shown =~ /\A"/ ? decode_json($shown) : $shown;
        print $value unless $value eq "-";
      ') || {
      FM_BACKLOG_TRANSITION_ERROR="could not decode the task body of $id"
      return 1
    }
    line="Deliverable of the finished work: $deliverable"
    case $'\n'"$body"$'\n' in
      *$'\n'"$line"$'\n'*) ;;
      *)
        new_body=$line
        [ -z "$body" ] || new_body=$(printf '%s\n\n%s' "$body" "$line")
        tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-backlog-retain-body.XXXXXX") || {
          FM_BACKLOG_TRANSITION_ERROR="cannot stage the deliverable for $id"
          return 1
        }
        if ! printf '%s\n' "$new_body" > "$tmp"; then
          rm -f -- "$tmp"
          FM_BACKLOG_TRANSITION_ERROR="cannot stage the deliverable for $id"
          return 1
        fi
        if ! fm_backlog_mutate "$authorized_data" update "$id" --body-file "$tmp"; then
          rm -f -- "$tmp"
          return 1
        fi
        rm -f -- "$tmp"
        ;;
    esac
  fi
  if [ "${#row_args[@]}" -gt 0 ]; then
    fm_backlog_mutate "$authorized_data" update "$id" "${row_args[@]}" || return 1
  fi
  fm_backlog_mutate "$authorized_data" reopen "$id"
}

fm_backlog_canonical_existing() {
  LC_ALL=C perl -MCwd=realpath -e '
    my $resolved = realpath($ARGV[0]);
    exit 1 unless defined $resolved;
    print $resolved;
  ' "$1" 2>/dev/null
}

fm_backlog_record_parent_authorized() {
  local path=$1 label=$2 root=$3 parent base parent_resolved expected_path
  local path_resolved root_resolved home_resolved final_matches=1
  parent=${path%/*}
  [ "$parent" != "$path" ] || parent=.
  base=${path##*/}
  root_resolved=$(fm_backlog_canonical_existing "$root") || {
    FM_BACKLOG_TRANSITION_ERROR="$label authorized directory cannot be resolved at $root"
    return 1
  }
  [ -d "$root_resolved" ] || {
    FM_BACKLOG_TRANSITION_ERROR="$label authorized directory is not a directory at $root"
    return 1
  }
  if [ -n "${FM_HOME:-}" ]; then
    case "$root" in
      "$FM_HOME"|"$FM_HOME"/*)
        home_resolved=$(fm_backlog_canonical_existing "$FM_HOME") || {
          FM_BACKLOG_TRANSITION_ERROR="$label home directory cannot be resolved at $FM_HOME"
          return 1
        }
        case "$root_resolved" in
          "$home_resolved"|"$home_resolved"/*) ;;
          *)
            FM_BACKLOG_TRANSITION_ERROR="$label authorized directory resolves outside this home at $root"
            return 1
            ;;
        esac
        ;;
    esac
  fi
  parent_resolved=$(fm_backlog_canonical_existing "$parent") || {
    FM_BACKLOG_TRANSITION_ERROR="$label parent directory cannot be resolved at $path"
    return 1
  }
  expected_path=${parent_resolved%/}/$base
  if [ -e "$path" ] || [ -L "$path" ]; then
    path_resolved=$(fm_backlog_canonical_existing "$path") || {
      FM_BACKLOG_TRANSITION_ERROR="$label cannot be resolved at $path"
      return 1
    }
    [ "$path_resolved" = "$expected_path" ] || final_matches=0
  else
    path_resolved=$expected_path
  fi
  case "$path_resolved" in
    "$root_resolved"/*) ;;
    *)
      FM_BACKLOG_TRANSITION_ERROR="$label resolves outside its authorized directory at $path"
      return 1
      ;;
  esac
  if [ "$final_matches" != 1 ]; then
    FM_BACKLOG_TRANSITION_ERROR="$label resolves through a different final path at $path"
    return 1
  fi
}

fm_backlog_record_present() {
  local path=$1 label=${2:-record} root=$3
  fm_backlog_record_parent_authorized "$path" "$label" "$root" || return 1
  if [ ! -f "$path" ]; then
    FM_BACKLOG_TRANSITION_ERROR="$label is not a regular file at $path"
    return 1
  fi
  return 0
}

fm_backlog_record_remove() {
  local path=$1 label=$2 root=$3
  fm_backlog_record_parent_authorized "$path" "$label" "$root" || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    fm_backlog_record_present "$path" "$label" "$root" || return 1
  fi
  if ! rm -f "$path" 2>/dev/null || [ -e "$path" ] || [ -L "$path" ]; then
    FM_BACKLOG_TRANSITION_ERROR="$label could not be removed at $path"
    return 1
  fi
  return 0
}

fm_backlog_record_publish() {
  local source=$1 target=$2 label=$3 root=$4
  fm_backlog_record_present "$source" "$label staged record" "$root" || return 1
  fm_backlog_record_parent_authorized "$target" "$label target" "$root" || return 1
  if [ -e "$target" ] || [ -L "$target" ]; then
    fm_backlog_record_present "$target" "$label target" "$root" || return 1
  fi
  if ! mv -f "$source" "$target" 2>/dev/null || ! fm_backlog_record_present "$target" "$label" "$root"; then
    [ -n "$FM_BACKLOG_TRANSITION_ERROR" ] \
      || FM_BACKLOG_TRANSITION_ERROR="$label publication failed at $target"
    return 1
  fi
  return 0
}

fm_backlog_meta_spawn_gen() {
  local meta=$1 state=$2 count value
  FM_BACKLOG_META_SPAWN_GEN=
  fm_backlog_record_present "$meta" "task record" "$state" || return 1
  count=$(LC_ALL=C awk -F= '$1 == "spawn_gen" { count++ } END { print count + 0 }' "$meta" 2>/dev/null) || {
    FM_BACKLOG_TRANSITION_ERROR="unreadable spawn generation in task record $meta"
    return 1
  }
  if [ "$count" -ne 1 ]; then
    FM_BACKLOG_TRANSITION_ERROR="task record $meta has $count spawn generation fields; exactly one is required"
    return 1
  fi
  value=$(LC_ALL=C awk -F= '$1 == "spawn_gen" { sub(/^[^=]*=/, ""); print }' "$meta" 2>/dev/null) || {
    FM_BACKLOG_TRANSITION_ERROR="unreadable spawn generation in task record $meta"
    return 1
  }
  case "$value" in
    ''|.*|*[!A-Za-z0-9._-]*)
      FM_BACKLOG_TRANSITION_ERROR="invalid spawn generation in task record $meta"
      return 1
      ;;
  esac
  FM_BACKLOG_META_SPAWN_GEN=$value
}

fm_backlog_row_dispatchable() {
  case "$1" in
    in_flight\ no\ no|queued\ no\ no) return 0 ;;
    *) return 1 ;;
  esac
}

fm_backlog_dispatch_transition() {
  local meta=$1 data=$2 id=$3 state=$4 row row_status
  fm_backlog_record_present "$meta" "task record" "$state" || return 1
  fm_backlog_row_probe "$data" "$id"
  row_status=$?
  if [ "$row_status" -ne 0 ]; then
    if [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
      FM_BACKLOG_TRANSITION_ERROR="backlog item $id vanished before dispatch commit"
    else
      FM_BACKLOG_TRANSITION_ERROR=$FM_BACKLOG_ROW_ERROR
    fi
    return "$row_status"
  fi
  row=$FM_BACKLOG_ROW_STATE
  if ! fm_backlog_row_dispatchable "$row"; then
    FM_BACKLOG_TRANSITION_ERROR="backlog item $id is not dispatchable in state $row"
    return 1
  fi
  case "$row" in
    in_flight\ no\ no) return 0 ;;
    queued\ no\ no) fm_backlog_start "$data" "$id" ;;
  esac
}

fm_backlog_dispatch_rollback() {
  local meta=$1 busy_script=$2 state=$3 id=$4 gen=$5 failed=0
  fm_backlog_record_remove "$meta" "provisional task record" "$state" || failed=1
  if [ -n "$gen" ]; then
    "$busy_script" retire "$state" "$id" --gen "$gen" >/dev/null 2>&1 || failed=1
    if [ -e "$state/$id.busy-state" ] || [ -L "$state/$id.busy-state" ] \
       || [ -e "$state/$id.busy-gen" ] || [ -L "$state/$id.busy-gen" ]; then
      failed=1
    fi
  fi
  if [ "$failed" -ne 0 ]; then
    FM_BACKLOG_TRANSITION_ERROR="failed-dispatch cleanup did not remove both task and busy records for $id"
    return 1
  fi
  return 0
}

fm_backlog_close_transition() {
  local meta=$1 marker=$2 data=$3 id=$4 state=$5
  shift 5
  [ -z "$meta" ] || fm_backlog_record_remove "$meta" "task record" "$state" || return 1
  fm_backlog_done "$data" "$id" "$@" || return 1
  fm_backlog_record_remove "$marker" "pending-close record" "$state"
}

# The captain-held twin of the close transition: same record, same ordering,
# `reopen` with the deliverable recorded instead of `done`.
fm_backlog_retain_transition() {
  local meta=$1 marker=$2 data=$3 id=$4 state=$5
  shift 5
  [ -z "$meta" ] || fm_backlog_record_remove "$meta" "task record" "$state" || return 1
  fm_backlog_retain "$data" "$id" "$@" || return 1
  fm_backlog_record_remove "$marker" "pending-close record" "$state"
}

fm_backlog_atomic_transition() {
  local operation=$1
  shift
  case "$operation" in
    publish) fm_backlog_record_publish "$@" ;;
    remove) fm_backlog_record_remove "$@" ;;
    dispatch) fm_backlog_dispatch_transition "$@" ;;
    rollback) fm_backlog_dispatch_rollback "$@" ;;
    close) fm_backlog_close_transition "$@" ;;
    retain) fm_backlog_retain_transition "$@" ;;
    *) FM_BACKLOG_TRANSITION_ERROR="unknown backlog atomic transition $operation"; return 2 ;;
  esac
}

fm_backlog_close_marker_path() {  # <state-dir> <id>
  printf '%s/%s.backlog-close\n' "$1" "$2"
}

fm_backlog_close_marker_validate() {  # <marker-path> <authorized-data-dir> <expected-id> <state-dir>
  local marker=$1 authorized_data data_resolved expected_id=$3 state=$4
  local id='' data='' marker_spawn_gen='' cleanup_incomplete=0 mode=close line raw_bytes arg_value
  local url_tail url_authority url_path url_host url_port host_rest host_label host_valid
  local percent_tail percent_valid
  local id_count=0 data_count=0 spawn_gen_count=0 cleanup_incomplete_count=0 mode_count=0
  local args=()
  FM_BACKLOG_CLOSE_VALIDATED_ID=
  FM_BACKLOG_CLOSE_VALIDATED_DATA=
  FM_BACKLOG_CLOSE_VALIDATED_SPAWN_GEN=
  FM_BACKLOG_CLOSE_VALIDATED_CLEANUP_INCOMPLETE=0
  FM_BACKLOG_CLOSE_VALIDATED_MODE=close
  FM_BACKLOG_CLOSE_VALIDATED_ARGS=()
  fm_backlog_record_present "$marker" "pending-close record" "$state" || return 1
  raw_bytes=$(fm_backlog_bytes_of_file "$marker" 2>/dev/null) || {
    FM_BACKLOG_TRANSITION_ERROR="unreadable pending-close record $marker"
    return 1
  }
  if ! fm_backlog_control_bytes_valid 1 "$raw_bytes"; then
    FM_BACKLOG_TRANSITION_ERROR="invalid control byte in pending-close record $marker"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      id=*) id=${line#id=}; id_count=$((id_count + 1)) ;;
      data=*) data=${line#data=}; data_count=$((data_count + 1)) ;;
      spawn_gen=*) marker_spawn_gen=${line#spawn_gen=}; spawn_gen_count=$((spawn_gen_count + 1)) ;;
      cleanup_incomplete=*) cleanup_incomplete=${line#cleanup_incomplete=}; cleanup_incomplete_count=$((cleanup_incomplete_count + 1)) ;;
      mode=*) mode=${line#mode=}; mode_count=$((mode_count + 1)) ;;
      arg=*) args+=("${line#arg=}") ;;
      *) FM_BACKLOG_TRANSITION_ERROR="unreadable pending-close record $marker"; return 1 ;;
    esac
  done < "$marker"
  if [ "$mode_count" -gt 1 ]; then
    FM_BACKLOG_TRANSITION_ERROR="unreadable pending-close record $marker"
    return 1
  fi
  case "$mode" in
    close|retain) ;;
    *)
      FM_BACKLOG_TRANSITION_ERROR="invalid transition mode in pending-close record $marker"
      return 1
      ;;
  esac
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*)
      FM_BACKLOG_TRANSITION_ERROR="invalid task identity in pending-close record $marker"
      return 1
      ;;
  esac
  if [ "$id_count" -ne 1 ] || [ "$id" != "$expected_id" ] \
     || [ "$data_count" -ne 1 ] || [ -z "$data" ] \
     || [ "$spawn_gen_count" -ne 1 ]; then
    FM_BACKLOG_TRANSITION_ERROR="unreadable pending-close record $marker"
    return 1
  fi
  case "$marker_spawn_gen" in
    ''|.*|*[!A-Za-z0-9._-]*)
      FM_BACKLOG_TRANSITION_ERROR="invalid spawn generation in pending-close record $marker"
      return 1
      ;;
  esac
  if [ "$cleanup_incomplete_count" -gt 1 ]; then
    FM_BACKLOG_TRANSITION_ERROR="unreadable pending-close record $marker"
    return 1
  fi
  case "$cleanup_incomplete" in
    0|1) ;;
    *)
      FM_BACKLOG_TRANSITION_ERROR="invalid cleanup state in pending-close record $marker"
      return 1
      ;;
  esac
  case "$data" in
    /*) ;;
    *) FM_BACKLOG_TRANSITION_ERROR="invalid data directory in pending-close record $marker"; return 1 ;;
  esac
  case "$data" in
    */../*|*/..)
      FM_BACKLOG_TRANSITION_ERROR="invalid data directory in pending-close record $marker"
      return 1
      ;;
  esac
  authorized_data=$(fm_backlog_data_absolute "$2") || {
    FM_BACKLOG_TRANSITION_ERROR="authorized data directory cannot be resolved: $2"
    return 1
  }
  data_resolved=$(fm_backlog_data_absolute "$data") || {
    FM_BACKLOG_TRANSITION_ERROR="data directory in pending-close record cannot be resolved: $data"
    return 1
  }
  if [ "$data_resolved" != "$authorized_data" ]; then
    FM_BACKLOG_TRANSITION_ERROR="foreign data directory in pending-close record $marker"
    return 1
  fi
  case "${#args[@]}" in
    0) ;;
    2)
      case "${args[0]}" in
        --note) [ "${args[1]}" = "local%20main" ] ;;
        --pr)
          arg_value=${args[1]}
          [ "${#arg_value}" -le 2048 ] \
            && case "$arg_value" in https://*) true ;; *) false ;; esac \
            && case "$arg_value" in
              *[[:space:]]*|*[!A-Za-z0-9:/?\&=._#%+~@-]*) false ;;
              *) true ;;
            esac \
            && {
              url_tail=${arg_value#https://}
              url_authority=${url_tail%%/*}
              url_path=${url_tail#*/}
              url_host=$url_authority
              url_port=
              case "$url_authority" in
                *:*) url_host=${url_authority%%:*}; url_port=${url_authority#*:} ;;
              esac
              [ "$url_path" != "$url_tail" ] \
                && case "$url_host" in
                  ''|[-.]*|*[-.]|*..*|*[!A-Za-z0-9.-]*) false ;;
                  *[A-Za-z0-9]*) true ;;
                  *) false ;;
                esac \
                && {
                  host_rest=$url_host
                  host_valid=1
                  while :; do
                    host_label=${host_rest%%.*}
                    case "$host_label" in ''|-*|*-) host_valid=0; break ;; esac
                    [ "$host_rest" = "$host_label" ] && break
                    host_rest=${host_rest#*.}
                  done
                  [ "$host_valid" = 1 ]
                } \
                && case "$url_authority" in
                  *:*) case "$url_port" in ''|*[!0-9]*|??????*) false ;; *) true ;; esac ;;
                  *) true ;;
                esac \
                && case "$url_path" in *[A-Za-z0-9]*) true ;; *) false ;; esac \
                && {
                  percent_tail=$url_path
                  percent_valid=1
                  while case "$percent_tail" in *%*) true ;; *) false ;; esac; do
                    percent_tail=${percent_tail#*%}
                    case "$percent_tail" in
                      [0-9A-Fa-f][0-9A-Fa-f]*) percent_tail=${percent_tail#??} ;;
                      *) percent_valid=0; break ;;
                    esac
                  done
                  [ "$percent_valid" = 1 ]
                }
            }
          ;;
        --report)
          arg_value=${args[1]}
          [ "${#arg_value}" -le 4096 ] \
            && [ -n "${arg_value// /}" ] \
            && case "$arg_value" in .|..|-*|/*|../*|*/../*|*/..) false ;; *) true ;; esac
          ;;
        *) false ;;
      esac || { FM_BACKLOG_TRANSITION_ERROR="invalid pending-close arguments in $marker"; return 1; }
      ;;
    *) FM_BACKLOG_TRANSITION_ERROR="invalid pending-close arguments in $marker"; return 1 ;;
  esac
  FM_BACKLOG_CLOSE_VALIDATED_ID=$id
  FM_BACKLOG_CLOSE_VALIDATED_DATA=$data_resolved
  FM_BACKLOG_CLOSE_VALIDATED_SPAWN_GEN=$marker_spawn_gen
  FM_BACKLOG_CLOSE_VALIDATED_CLEANUP_INCOMPLETE=$cleanup_incomplete
  FM_BACKLOG_CLOSE_VALIDATED_MODE=$mode
  FM_BACKLOG_CLOSE_VALIDATED_ARGS=("${args[@]+"${args[@]}"}")
}

# A leading `--retain` flag records the captain-held transition (`mode=retain`)
# instead of a close; the remaining flags are the same completion links either
# transition records.
fm_backlog_close_marker_stage() {  # <temporary-path> <id> <data-dir> <spawn-gen> <state-dir> <cleanup-incomplete: 0|1> [--retain] [flag...]
  local tmp=$1 id=$2 data spawn_gen=$4 state=$5 cleanup_incomplete=$6 arg previous_arg=''
  local mode=close serialized_args=()
  data=$(fm_backlog_data_absolute "$3") || {
    FM_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $3"
    return 1
  }
  fm_backlog_record_parent_authorized "$tmp" "pending-close staging path" "$state" || return 1
  if [ -e "$tmp" ] || [ -L "$tmp" ]; then
    FM_BACKLOG_TRANSITION_ERROR="unsafe pending-close staging path $tmp"
    return 1
  fi
  case "$cleanup_incomplete" in
    0|1) ;;
    *) FM_BACKLOG_TRANSITION_ERROR="invalid pending-close cleanup state"; return 1 ;;
  esac
  shift 6
  if [ "${1:-}" = --retain ]; then
    mode=retain
    shift
  fi
  for arg in "$@"; do
    if [ "$previous_arg" = --note ] && [ "$arg" = "local main" ]; then
      serialized_args+=("local%20main")
    else
      serialized_args+=("$arg")
    fi
    previous_arg=$arg
  done
  {
    printf 'id=%s\n' "$id"
    printf 'data=%s\n' "$data"
    printf 'spawn_gen=%s\n' "$spawn_gen"
    printf 'cleanup_incomplete=%s\n' "$cleanup_incomplete"
    [ "$mode" = close ] || printf 'mode=%s\n' "$mode"
    for arg in "${serialized_args[@]+"${serialized_args[@]}"}"; do
      printf 'arg=%s\n' "$arg"
    done
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  fm_backlog_close_marker_validate "$tmp" "$data" "$id" "$state" \
    || { rm -f "$tmp"; return 1; }
}

# Record the exact close a teardown is about to perform.
fm_backlog_close_marker_write() {  # <state-dir> <id> <data-dir> <spawn-gen> [flag...]
  local state=$1 id=$2 data=$3 spawn_gen=$4 marker tmp
  fm_backlog_directory_present "$state" "state directory" || return 1
  shift 4
  marker=$(fm_backlog_close_marker_path "$state" "$id") || return 1
  tmp="$state/.$id.backlog-close.${BASHPID:-$$}"
  fm_backlog_close_marker_stage "$tmp" "$id" "$data" "$spawn_gen" "$state" 0 "$@" || return 1
  fm_backlog_atomic_transition publish "$tmp" "$marker" "pending-close record" "$state" \
    || { rm -f "$tmp"; return 1; }
}

fm_backlog_close_marker_mark_cleanup_incomplete() {  # <state-dir> <marker-path> <id> <data-dir> <spawn-gen> [flag...]
  local state=$1 marker=$2 id=$3 data=$4 spawn_gen=$5 tmp
  shift 5
  tmp="$state/.$id.backlog-close.${BASHPID:-$$}"
  fm_backlog_close_marker_stage "$tmp" "$id" "$data" "$spawn_gen" "$state" 1 "$@" || return 1
  fm_backlog_atomic_transition publish "$tmp" "$marker" "pending-close record" "$state" \
    || { rm -f "$tmp"; return 1; }
}

fm_backlog_close_marker_remove() {  # <marker-path> <state-dir>
  fm_backlog_atomic_transition remove "$1" "pending-close record" "$2"
}

fm_backlog_close_marker_clear() {  # <state-dir> <id>
  local marker
  marker=$(fm_backlog_close_marker_path "$1" "$2") || return 1
  fm_backlog_close_marker_remove "$marker" "$1"
}

# Replay one recorded close or retention. Returns 0 when the row is closed (or
# retained), the marker is stale, or an answer already closed a retained row,
# and 1 when marker validation or recovery fails. Validation completes before
# any meta or backlog mutation.
fm_backlog_close_marker_replay() {  # <state-dir> <marker-path> <authorized-data-dir>
  local state=$1 marker=$2 marker_name expected_id
  local id data marker_spawn_gen meta meta_spawn_gen row_state cleanup_incomplete mode
  local args=() mode_flags=()
  FM_BACKLOG_CLOSE_REPLAY_RESULT=noop
  fm_backlog_directory_present "$state" "state directory" || return 1
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  marker_name=${marker##*/}
  case "$marker_name" in
    *.backlog-close) expected_id=${marker_name%.backlog-close} ;;
    *) FM_BACKLOG_TRANSITION_ERROR="invalid pending-close record name $marker"; return 1 ;;
  esac
  fm_backlog_close_marker_validate "$marker" "$3" "$expected_id" "$state" || return 1
  id=$FM_BACKLOG_CLOSE_VALIDATED_ID
  data=$FM_BACKLOG_CLOSE_VALIDATED_DATA
  marker_spawn_gen=$FM_BACKLOG_CLOSE_VALIDATED_SPAWN_GEN
  cleanup_incomplete=$FM_BACKLOG_CLOSE_VALIDATED_CLEANUP_INCOMPLETE
  mode=$FM_BACKLOG_CLOSE_VALIDATED_MODE
  [ "$mode" = close ] || mode_flags=(--retain)
  args=("${FM_BACKLOG_CLOSE_VALIDATED_ARGS[@]+"${FM_BACKLOG_CLOSE_VALIDATED_ARGS[@]}"}")
  if [ "${args[0]-}" = --note ]; then
    args[1]="local main"
  fi
  meta="$state/$id.meta"
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    if ! fm_backlog_record_present "$meta" "task record" "$state"; then
      FM_BACKLOG_TRANSITION_ERROR="unsafe interrupted task record at $meta"
      return 1
    fi
    fm_backlog_meta_spawn_gen "$meta" "$state" || return 1
    meta_spawn_gen=$FM_BACKLOG_META_SPAWN_GEN
    if [ "$meta_spawn_gen" != "$marker_spawn_gen" ]; then
      fm_backlog_close_marker_remove "$marker" "$state" || return 1
      FM_BACKLOG_CLOSE_REPLAY_RESULT=stale
      return 0
    fi
    fm_backlog_close_marker_mark_cleanup_incomplete "$state" "$marker" "$id" "$data" \
      "$marker_spawn_gen" "${mode_flags[@]+"${mode_flags[@]}"}" "${args[@]+"${args[@]}"}" \
      || return 1
    cleanup_incomplete=1
    fm_backlog_atomic_transition remove "$meta" "the interrupted task record" "$state" \
      || return 1
  fi
  if fm_backlog_row_probe "$data" "$id"; then
    row_state=$FM_BACKLOG_ROW_STATE
    if [ "${row_state%% *}" != "done" ] && [ "$FM_BACKLOG_ROW_HOLD_KIND" = captain ]; then
      mode=retain
    fi
  else
    if [ "$FM_BACKLOG_ROW_RESULT" != not_found ]; then
      FM_BACKLOG_TRANSITION_ERROR=$FM_BACKLOG_ROW_ERROR
      return 1
    fi
    row_state=
  fi
  case "$row_state" in
    done\ *)
      if [ "$mode" = retain ]; then
        # The captain's answer closed the row before this replay; the retained
        # transition owes it nothing more than retiring the record.
        fm_backlog_close_marker_remove "$marker" "$state" || return 1
        FM_BACKLOG_CLOSE_REPLAY_RESULT=answered
        return 0
      fi
      if fm_backlog_atomic_transition close '' "$marker" "$data" "$id" "$state" \
          "${args[@]+"${args[@]}"}"; then
        if [ "$cleanup_incomplete" = 1 ]; then
          FM_BACKLOG_CLOSE_REPLAY_RESULT=closed_incomplete
        else
          FM_BACKLOG_CLOSE_REPLAY_RESULT=closed
        fi
        return 0
      fi
      return 1
      ;;
    '')
      fm_backlog_close_marker_remove "$marker" "$state" || return 1
      FM_BACKLOG_CLOSE_REPLAY_RESULT=stale
      return 0
      ;;
  esac
  if fm_backlog_atomic_transition "$mode" '' "$marker" "$data" "$id" "$state" \
      "${args[@]+"${args[@]}"}"; then
    if [ "$mode" = retain ]; then
      if [ "$cleanup_incomplete" = 1 ]; then
        FM_BACKLOG_CLOSE_REPLAY_RESULT=retained_incomplete
      else
        FM_BACKLOG_CLOSE_REPLAY_RESULT=retained
      fi
    elif [ "$cleanup_incomplete" = 1 ]; then
      FM_BACKLOG_CLOSE_REPLAY_RESULT=closed_incomplete
    else
      FM_BACKLOG_CLOSE_REPLAY_RESULT=closed
    fi
    return 0
  fi
  return 1
}
