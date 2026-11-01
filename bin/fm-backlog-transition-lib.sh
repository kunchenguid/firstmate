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
# homes whose configured backlog backend is manual and markdown homes that keep
# no backlog file. Those return-1 exemptions are never errors; an
# unresolvable configured data directory, a backend resolution error, or
# incompatible tasks-axi instead returns 2 so callers refuse before mutation.
#
# ADDRESSING. Every call runs from the configured data directory's parent so
# that home's `.tasks.toml` supplies the adapter selection, done_keep, and the
# archive path. A markdown backlog also passes `--file <data>/backlog.md` so the
# change lands in the home that owns the task regardless of the caller's working
# directory. A configured non-markdown adapter is addressed by that root alone,
# because `--file` would override the adapter's own workspace path. The parent of
# the data directory is the addressing root rather than FM_HOME, so a home whose
# data directory is relocated keeps its backlog and its archive together. A root
# with no `.tasks.toml` gets tasks-axi's built-in defaults.
# bin/fm-tasks-axi-lib.sh owns backend precedence and configuration failures.
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
# closes a row that reads as an open captain call. An answer that closes the row
# first applies any supported retained artifact from the validated record, then
# replay simply retires the record.

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

# Bounded execution is fm-timeout-lib.sh's alone; source it rather than
# re-deriving a deadline here. It is stateless, so the memoisation reason this
# library does not source fm-tasks-axi-lib.sh does not apply.
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
# fm-pr-lib.sh owns which URL is a Gerrit change or a GitLab merge request. It
# is functions and empty globals only, so it is sourced once rather than
# re-initialising a caller's parsed identity.
if ! declare -F fm_pr_url_parse >/dev/null 2>&1; then
  # shellcheck source=bin/fm-pr-lib.sh disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-pr-lib.sh"
fi

# Latched when a row read hits its bound. fm_backlog_row_show runs inside a
# command substitution, so the subshell can READ this latch but cannot set it;
# the callers that capture its status own the write.
FM_BACKLOG_ROW_SHOW_WEDGED=0

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


# The parent an authorized data directory was named from, kept in the caller's
# own path shape. fm_backlog_record_parent_authorized only applies its FM_HOME
# containment guard to a root that still spells out `$FM_HOME`, so a root
# already resolved through `pwd -P` would skip that guard whenever the data
# directory is a symlink.
fm_backlog_authorized_root() {  # <authorized-data-dir>
  local data=$1 parent
  while [ "$data" != / ] && [ "${data%/}" != "$data" ]; do
    data=${data%/}
  done
  case "$data" in
    /) parent=/ ;;
    */*)
      parent=${data%/*}
      [ -n "$parent" ] || parent=/
      ;;
    *) parent=. ;;
  esac
  printf '%s\n' "$parent"
}

# Any adapter selection or exemption derived from a home's `.tasks.toml` is only
# as safe as that file, so validate it before reading it.
fm_backlog_config_present() {  # <root> <authorized-root>
  local root=$1 authorized_root=$2 tasks_config="$1/.tasks.toml"
  if [ -e "$tasks_config" ] || [ -L "$tasks_config" ]; then
    # Leave a dangling config symlink for the backend resolver to diagnose as
    # unreadable; reject an existing special file through the home-bound
    # validator before any backend parser can touch it.
    if [ -L "$tasks_config" ] && [ ! -e "$tasks_config" ]; then
      return 0
    fi
    fm_backlog_record_present "$tasks_config" "tasks-axi config" "$authorized_root" || return 1
  fi
  return 0
}

# Every home is bound to its own data directory, whichever adapter it configures,
# so the boundary is authorized first and unconditionally. Only the markdown
# backlog's regular-file requirement is adapter-specific: another adapter keeps
# its rows in its own workspace and need not carry <data>/backlog.md at all.
fm_backlog_source_present() {  # <data-dir> <authorized-data-dir> [root authorized-root]
  local data=$1 authorized_data=$2 root=${3:-} authorized_root=${4:-} file backend
  if [ -z "$root" ]; then
    root=$(fm_backlog_root "$data") || return 1
    authorized_root=$(fm_backlog_authorized_root "$authorized_data")
  fi
  if [ -z "$authorized_root" ]; then
    authorized_root=$(fm_backlog_authorized_root "$authorized_data")
  fi
  fm_backlog_config_present "$root" "$authorized_root" || return 1
  backend=$(fm_tasks_axi_backend "$root" 2>&1) || {
    FM_BACKLOG_TRANSITION_ERROR=$backend
    return 2
  }
  file=$(fm_backlog_file "$data") || return 1
  if [ "$backend" = markdown ]; then
    fm_backlog_record_present "$file" "backlog file" "$authorized_data"
    return $?
  fi
  fm_backlog_record_parent_authorized "$file" "backlog data directory" "$authorized_data" parent-only
}

# Resolve how the owning home's backlog is addressed, for reads and mutations
# alike: sets FM_BACKLOG_AXI_ROOT to the cd target and FM_BACKLOG_AXI_FILE to
# the markdown --file path, empty for every other backend. This is the single
# place that decision is made. A markdown backlog is addressed as
# <data>/backlog.md so the change lands in the home that owns the task
# regardless of the caller's working directory; any other configured adapter
# is addressed by that root alone, because --file would override the adapter's
# own workspace path. The caller invokes fm_tasks_axi inside its own subshell
# - the bound wrapper execs, so a nested subshell here would add a process
# layer between tasks-axi and the caller, which the lock-holding callers'
# interruption contract counts on not existing.
fm_backlog_tasks_axi_addressing() {  # <data-dir>
  FM_BACKLOG_AXI_FILE=
  local data root backend
  data=$(fm_backlog_data_absolute "$1") || return $?
  root=$(fm_backlog_root "$data") || return $?
  backend=$(fm_tasks_axi_backend "$root" 2>&1) || {
    FM_BACKLOG_TRANSITION_ERROR=$backend
    return 2
  }
  FM_BACKLOG_AXI_ROOT=$root
  if [ "$backend" = markdown ]; then
    FM_BACKLOG_AXI_FILE=$(fm_backlog_file "$data") || return 1
  fi
}

fm_backlog_transition_applies() {  # <config-dir> <data-dir> <kind>
  local config=$1 data authorized_data=$2 kind=$3 file root backend authorized_root
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
  authorized_root=$(fm_backlog_authorized_root "$authorized_data")
  fm_backlog_config_present "$root" "$authorized_root" || return 2
  backend=$(fm_tasks_axi_backend "$root" 2>&1) || {
    FM_BACKLOG_TRANSITION_ERROR=$backend
    return 2
  }
  if [ "$backend" = markdown ]; then
    file=$(fm_backlog_file "$data") || return 2
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
      FM_BACKLOG_TRANSITION_SKIP="this home keeps no markdown backlog at $file"
      return 1
    fi
  fi
  if ! fm_backlog_source_present "$data" "$authorized_data" "$root" "$authorized_root"; then
    return 2
  fi
  if ! fm_tasks_axi_compatible; then
    FM_BACKLOG_TRANSITION_ERROR="automatic backlog transitions require tasks-axi ${FM_TASKS_AXI_MIN:-(unknown minimum)} or newer with the required update and mv features"
    return 2
  fi
  return 0
}

# Run `tasks-axi` with an optional FM_TASKS_AXI_TIMEOUT bound. A caller that
# holds a lock across the call - the spawn commit and its preservation
# read-back run under the per-task meta lock - sets the bound, so an
# unresponsive tasks-axi cannot hold that lock open indefinitely. The bound is
# fm_exec_timed's (bin/fm-timeout-lib.sh), with one further bound of grace
# before KILL so a tasks-axi that ignores SIGTERM cannot outlive it either; the
# callers treat fm_timed_out statuses as the bound expiring and report the
# timeout as the reason through their existing error plumbing. A bound that
# cannot be enforced on this host fails closed instead of running unbounded.
# Must be the last command of a subshell: the exec keeps the tasks-axi process
# exactly where the plain call sat, and the bound kills the child, not the
# caller.
fm_tasks_axi_timeout_expired() {  # <status>
  fm_timed_out "$1"
}

fm_tasks_axi() {
  local bound=${FM_TASKS_AXI_TIMEOUT:-}
  if [ -z "$bound" ]; then
    exec tasks-axi "$@"
  fi
  fm_exec_timed "$bound" "$bound" tasks-axi "$@"
}

# Print one row's `tasks-axi show` output (plus stderr) from the addressing
# fm_backlog_tasks_axi_addressing resolved, with `--file` only for the markdown
# backend. Addressing or backend-resolution errors return before tasks-axi runs;
# otherwise its exit status is preserved. Extra flags (--full) pass through.
#
# Every read is bounded, because a wedged backend read here is what blinds a
# whole session start: bin/fm-bootstrap.sh's reconcile and close-replay sweeps
# call this once per item, and one unbounded read consumes the entire
# FM_SESSION_START_TIMEOUT and truncates the digest before the wake queue,
# supervision instructions, fleet state and context sections ever print. The
# bound turns that into a loud partial reconcile: the caller reports the item it
# could not read and moves to the next one.
#
# A per-item bound alone is not enough on a home carrying a large fleet, because
# N wedged items still cost N bounds and the digest is truncated anyway. So the
# first bound hit latches FM_BACKLOG_ROW_SHOW_WEDGED and every later read in the
# same sweep returns immediately, still naming its own item so nothing is
# silently skipped. This function only READS that latch: it runs inside a
# command substitution, and a write here would die with the subshell, so the
# callers that capture its status set it. The latch is deliberately
# process-wide because these scripts are short-lived and a backend that wedged
# once will wedge again within the same run.
fm_backlog_row_show() {  # <resolved-data-dir> <id> [flag...]
  local data=$1 id=$2 out status addressing_status secs=${FM_BACKLOG_ROW_TIMEOUT_SECS:-10}
  shift 2
  # A non-positive bound is not a bound (fm-timeout-lib.sh), and a padded zero
  # such as 00 is still zero, so the digits test alone would let the very read
  # this bound exists to prevent back in. Compare arithmetically, tolerating a
  # value too large for the shell to compare at all.
  case "$secs" in ''|*[!0-9]*) secs=10 ;; esac
  [ "$secs" -gt 0 ] 2>/dev/null || secs=10
  fm_backlog_tasks_axi_addressing "$data"
  addressing_status=$?
  if [ "$addressing_status" -ne 0 ]; then
    [ -z "${FM_BACKLOG_TRANSITION_ERROR:-}" ] || printf '%s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2
    return "$addressing_status"
  fi
  if [ "$FM_BACKLOG_ROW_SHOW_WEDGED" = 1 ]; then
    printf 'tasks-axi show %s skipped: the backlog backend already exceeded its %ss read bound\n' "$id" "$secs"
    return 124
  fi
  if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
    set -- "$@" --file "$FM_BACKLOG_AXI_FILE"
  fi
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  out=$(fm_run_timed "$secs" bash -c 'cd "$1" 2>/dev/null || exit 1; shift; exec tasks-axi show "$@"' \
    _ "$FM_BACKLOG_AXI_ROOT" "$id" "$@" 2>&1)
  status=$?
  # A backend that wrote a header or a progress line before wedging leaves that
  # fragment as the first output line, and every caller reads the first line as
  # the failure reason. Whatever a timed-out read managed to emit is incomplete
  # by definition, so the bound speaks for it instead.
  if [ "$status" -eq 124 ]; then
    printf 'tasks-axi show %s exceeded its %ss backlog read bound\n' "$id" "$secs"
  else
    printf '%s\n' "$out"
  fi
  return "$status"
}

fm_backlog_row_list() {  # <resolved-data-dir> [flag...]
  local data=$1 addressing_status
  shift
  fm_backlog_tasks_axi_addressing "$data"
  addressing_status=$?
  if [ "$addressing_status" -ne 0 ]; then
    [ -z "${FM_BACKLOG_TRANSITION_ERROR:-}" ] || printf '%s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2
    return "$addressing_status"
  fi
  if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
    (cd "$FM_BACKLOG_AXI_ROOT" 2>/dev/null && fm_tasks_axi list "$@" --file "$FM_BACKLOG_AXI_FILE" 2>&1)
  else
    (cd "$FM_BACKLOG_AXI_ROOT" 2>/dev/null && fm_tasks_axi list "$@" 2>&1)
  fi
}

fm_backlog_row_probe() {  # <data-dir> <id>
  local data authorized_data=$1 id=$2 out state held blocked hold_kind command_status source_status
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
  fm_backlog_source_present "$data" "$authorized_data"
  source_status=$?
  if [ "$source_status" -ne 0 ]; then
    FM_BACKLOG_ROW_ERROR=$FM_BACKLOG_TRANSITION_ERROR
    return "$source_status"
  fi
  out=$(fm_backlog_row_show "$data" "$id")
  command_status=$?
  [ "$command_status" -ne 124 ] || FM_BACKLOG_ROW_SHOW_WEDGED=1
  if [ "$command_status" -ne 0 ]; then
    if printf '%s\n' "$out" | grep -q '^code: NOT_FOUND$'; then
      FM_BACKLOG_ROW_RESULT=not_found
    else
      FM_BACKLOG_ROW_ERROR=$(printf '%s\n' "$out" | sed -n '1p')
      if [ -z "$FM_BACKLOG_ROW_ERROR" ]; then
        if fm_tasks_axi_timeout_expired "$command_status" && [ -n "${FM_TASKS_AXI_TIMEOUT:-}" ]; then
          FM_BACKLOG_ROW_ERROR="tasks-axi show $id did not finish within ${FM_TASKS_AXI_TIMEOUT}s"
        else
          FM_BACKLOG_ROW_ERROR="tasks-axi show $id failed with no output"
        fi
      fi
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
# output line in FM_BACKLOG_TRANSITION_ERROR on failure. The home boundary is
# authorized through fm_backlog_source_present first; fm_backlog_tasks_axi owns
# how the selected adapter is addressed (ADDRESSING above).
fm_backlog_mutate() {  # <data-dir> <verb> <id> [flag...]
  local data authorized_data=$1 verb=$2 id=$3 out command_status source_status
  if ! data=$(fm_backlog_data_absolute "$1"); then
    FM_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $1"
    return 1
  fi
  shift 3
  FM_BACKLOG_TRANSITION_ERROR=
  fm_backlog_source_present "$data" "$authorized_data"
  source_status=$?
  [ "$source_status" -eq 0 ] || return "$source_status"
  fm_backlog_tasks_axi_addressing "$data"
  source_status=$?
  [ "$source_status" -eq 0 ] || return "$source_status"
  if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
    out=$(cd "$FM_BACKLOG_AXI_ROOT" 2>/dev/null && fm_tasks_axi "$verb" "$id" "$@" --file "$FM_BACKLOG_AXI_FILE" 2>&1)
  else
    out=$(cd "$FM_BACKLOG_AXI_ROOT" 2>/dev/null && fm_tasks_axi "$verb" "$id" "$@" 2>&1)
  fi
  command_status=$?
  [ "$command_status" -ne 0 ] || return 0
  FM_BACKLOG_TRANSITION_ERROR=$(printf '%s\n' "$out" | sed -n '1p')
  if [ -z "$FM_BACKLOG_TRANSITION_ERROR" ]; then
    if fm_tasks_axi_timeout_expired "$command_status" && [ -n "${FM_TASKS_AXI_TIMEOUT:-}" ]; then
      FM_BACKLOG_TRANSITION_ERROR="tasks-axi $verb $id did not finish within ${FM_TASKS_AXI_TIMEOUT}s"
    else
      FM_BACKLOG_TRANSITION_ERROR="tasks-axi $verb $id failed with no output"
    fi
  fi
  return "$command_status"
}

fm_backlog_start() {  # <data-dir> <id>
  fm_backlog_mutate "$1" start "$2"
}

# tasks-axi takes a --pr link only as a canonical GitHub or Forgejo pull request
# and refuses anything else, so a Gerrit change or GitLab merge request URL is
# recorded on the row as a note instead. Prints the note's label for such a URL
# and fails for one tasks-axi accepts. The subshell keeps the parse from
# overwriting a caller's FM_PR_* identity.
fm_backlog_pr_note_label() {  # <url>
  ( fm_pr_url_parse "$1" || exit 1
    case "$FM_PR_PROVIDER" in
      gerrit) printf 'Gerrit change\n' ;;
      gitlab) printf 'GitLab merge request\n' ;;
      *) exit 1 ;;
    esac )
}

# The pending-close record is a line-oriented file holding one `arg=` line per
# flag, and a `--note` value is prose that lands in the task body, so without one
# shared encoding the reader could not tell the value's own spaces from the
# record's structure. The writer encodes every `--note` value and every reader
# decodes it, so a replay reproduces the note byte for byte. The accepted byte
# set is the one firstmate's own notes use - a sentence over letters, digits, and
# the punctuation below - and validation requires that re-encoding the decoded
# value reproduces the recorded text, so a value outside it is refused rather
# than silently altered.
#
# The bound is the `--pr` bound the validator below enforces (2048) plus the
# fixed prose a completion note composes around that link ("Delivered, merge not
# confirmed because <reason>: " and the trailing historical-record sentence, at
# most 161 bytes). A shorter bound would make a long-but-recordable pull-request
# URL unstageable, turning cleanup of otherwise landed work into a refusal even
# though the link itself is acceptable.
FM_BACKLOG_NOTE_MAX=2400
# Set by fm_backlog_pr_link_note, and through it by fm_backlog_pr_link_downgrade:
# the unverified pull request links a caller may take off the title, one per line,
# and the sentence that keeps them in the body. They are globals rather than
# printed output because a caller runs in the same shell and needs the link list
# to tell whether its own note already names them.
FM_BACKLOG_DOWNGRADE_LINKS=
FM_BACKLOG_DOWNGRADE_NOTE=
fm_backlog_note_encode() {  # <text>
  local text=$1 out='' ch encoded i=0
  [ -n "$text" ] || return 1
  [ "${#text}" -le "$FM_BACKLOG_NOTE_MAX" ] || return 1
  case "$text" in -*) return 1 ;; esac
  while [ "$i" -lt "${#text}" ]; do
    ch=${text:$i:1}
    case "$ch" in
      ' ') encoded=%20 ;;
      [A-Za-z0-9]) encoded=$ch ;;
      "/"|":"|"?"|"&"|"="|"_"|"."|"+"|"@"|","|"-") encoded=$ch ;;
      *) return 1 ;;
    esac
    out=$out$encoded
    i=$((i + 1))
  done
  printf '%s' "$out"
}

fm_backlog_note_decode() {  # <encoded-note>
  local encoded=$1 out=''
  [ -n "$encoded" ] || return 1
  [ "${#encoded}" -le $((FM_BACKLOG_NOTE_MAX * 3)) ] || return 1
  while [ -n "$encoded" ]; do
    case "$encoded" in
      *%*)
        out=$out${encoded%%%*}
        encoded=${encoded#*%}
        case "$encoded" in
          20*) out="$out "; encoded=${encoded#20} ;;
          *) return 1 ;;
        esac
        ;;
      *)
        out=$out$encoded
        encoded=
        ;;
    esac
  done
  printf '%s' "$out"
}

fm_backlog_done() {  # <data-dir> <id> [flag...]
  local data=$1 id=$2 previous='' arg label pr_close=0 pr_url='' note_text=''
  local sentence='' body_line='' strip_after=0 drop_note=0
  local -a close_args=() kept_args=()
  shift 2
  for arg in "$@"; do
    case "$previous" in
      --note)
        note_text=$arg
        close_args+=(--note "$arg")
        previous=$arg
        continue
        ;;
      --pr)
        if label=$(fm_backlog_pr_note_label "$arg"); then
          # tasks-axi takes only a canonical pull request as a pr link, so a
          # GitLab merge request or Gerrit change is recorded as a note.
          note_text="$label $arg"
          close_args+=(--note "$label $arg")
        elif [ -n "$pr_url" ]; then
          # One verified link per close: a second one is prose.
          note_text="${note_text:+$note_text; }PR $arg"
          close_args+=(--note "$note_text")
        else
          pr_close=1
          pr_url=$arg
          close_args+=(--pr "$arg")
        fi
        previous=$arg
        continue
        ;;
    esac
    case "$arg" in
      --note|--pr) previous=$arg ;;
      *) close_args+=("$arg"); previous=$arg ;;
    esac
  done
  if [ "$pr_close" = 1 ]; then
    # A verified close keeps its own link and may not keep another one no run
    # verified: tasks-axi writes "merged" for any link it finds, so a still-open
    # link beside it would claim a merge nobody read. That link keeps its URL in
    # the body note instead.
    FM_BACKLOG_PR_LINK_EXCLUDE=$pr_url
    fm_backlog_pr_link_note "$data" "$id" "the row carried a link no run verified" || {
      FM_BACKLOG_PR_LINK_EXCLUDE=
      return 1
    }
    FM_BACKLOG_PR_LINK_EXCLUDE=
    sentence=$FM_BACKLOG_DOWNGRADE_NOTE
    [ -z "$FM_BACKLOG_DOWNGRADE_LINKS" ] || strip_after=1
  else
    fm_backlog_pr_link_note "$data" "$id" "this close recorded no merge" || return 1
    sentence=$FM_BACKLOG_DOWNGRADE_NOTE
    [ -z "$FM_BACKLOG_DOWNGRADE_LINKS" ] || strip_after=1
  fi
  # A close that has to take a link off the title writes the prose it records into
  # the body FIRST, so a close that fails or is killed cannot take the only copy
  # of a URL with it, and only then closes the row. A close with no link to remove
  # touches nothing but the row itself and keeps passing its note as an argument,
  # which is the shape every adapter supports.
  if [ "$strip_after" = 1 ]; then
    body_line=$note_text
    if [ -n "$sentence" ]; then
      if [ -z "$body_line" ]; then
        body_line=$sentence
      elif ! fm_backlog_text_names_links "$body_line" "$FM_BACKLOG_DOWNGRADE_LINKS"; then
        body_line="$body_line; $sentence"
      fi
    fi
    [ -z "$body_line" ] || fm_backlog_body_append_line "$data" "$id" "$body_line" || return 1
    drop_note=1
    # A verified close keeps its own link on the title: it is the link tasks-axi
    # renders as merged, and a close that fails after this point must still find
    # it there, or a retry reads no merge and downgrades a verified fact.
    [ "$pr_close" = 0 ] || FM_BACKLOG_PR_LINK_EXCLUDE=$pr_url
    fm_backlog_pr_title_strip "$data" "$id" || {
      FM_BACKLOG_PR_LINK_EXCLUDE=
      return 1
    }
    FM_BACKLOG_PR_LINK_EXCLUDE=
  elif [ -n "$note_text" ]; then
    # A retry finds the note an interrupted attempt already wrote; passing it
    # again would duplicate the line, so this close owes nothing for it.
    fm_backlog_row_title_body "$data" "$id" || return 1
    case $'\n'"$FM_BACKLOG_ROW_BODY"$'\n' in
      *$'\n'"$note_text"$'\n'*|*$'\n'"$note_text"'; '*) drop_note=1 ;;
    esac
  fi
  if [ "$drop_note" = 1 ]; then
    # The note lives in the body, so it is not owed as a close argument.
    previous=''
    for arg in "${close_args[@]+"${close_args[@]}"}"; do
      if [ "$previous" = --note ]; then
        previous=''
        continue
      fi
      [ "$arg" = --note ] || kept_args+=("$arg")
      previous=$arg
    done
    close_args=("${kept_args[@]+"${kept_args[@]}"}")
  fi
  fm_backlog_mutate "$data" "done" "$id" "${close_args[@]+"${close_args[@]}"}"
}

# Decode one `tasks-axi show` scalar. The field arrives as a JSON-encoded bare
# string, so ask JSON::PP for allow_nonref instead of inheriting an older
# library's default, and write raw bytes so a non-ASCII title survives the
# round-trip this library makes to rewrite it.
fm_backlog_shown_value() {  # <shown-field>
  local value=$1
  case "$value" in
    \"*\")
      printf '%s' "$value" | LC_ALL=C perl -MJSON::PP -e '
        local $/;
        my $value = JSON::PP->new->utf8->allow_nonref->decode(<STDIN>);
        binmode STDOUT, ":raw";
        utf8::encode($value) if utf8::is_utf8($value);
        print $value;
      '
      ;;
    *) printf '%s' "$value" ;;
  esac
}

# Split <title> into its prose and the canonical pull request links tasks-axi
# derives from it. Sets FM_BACKLOG_TITLE_PROSE (that prose, with the links removed
# and the spacing normalized) and FM_BACKLOG_TITLE_PR_LINKS (one URL per line,
# empty when there are none). tasks-axi trims sentence punctuation from the end of
# each URL before classifying it, so the walk does the same and leaves every other
# URL in the prose.
FM_BACKLOG_TITLE_PROSE=
FM_BACKLOG_TITLE_PR_LINKS=
fm_backlog_title_split_pr_links() {  # <title>
  local rest=$1 out='' url trailing
  FM_BACKLOG_TITLE_PROSE=
  FM_BACKLOG_TITLE_PR_LINKS=
  while :; do
    case "$rest" in
      *https://*) ;;
      *) out=$out$rest; break ;;
    esac
    out=$out${rest%%https://*}
    rest=https://${rest#*https://}
    case "$rest" in
      *[[:space:]]*) url=${rest%%[[:space:]]*}; rest=${rest#"$url"} ;;
      *) url=$rest; rest= ;;
    esac
    trailing=
    while :; do
      case "$url" in
        *[\)\".,\;]) trailing=${url: -1}$trailing; url=${url%?} ;;
        *) break ;;
      esac
    done
    if ( fm_pr_url_parse "$url" \
         && { [ "$FM_PR_PROVIDER" = forgejo ] \
              || { [ "$FM_PR_PROVIDER" = github ] && [ "$FM_PR_HOST" = github.com ]; }; } ); then
      # Keep the separating space that sat before the link; the trailing trim
      # below removes it when the link ended the title.
      case "$rest" in \ *) rest=${rest# } ;; esac
      FM_BACKLOG_TITLE_PR_LINKS=${FM_BACKLOG_TITLE_PR_LINKS:+$FM_BACKLOG_TITLE_PR_LINKS$'\n'}$url
    else
      out=$out$url$trailing
    fi
  done
  FM_BACKLOG_TITLE_PROSE=$(printf '%s' "$out" | tr -s ' ' | sed 's/^ *//;s/ *$//')
}

# Read this row's title and body into FM_BACKLOG_ROW_TITLE and
# FM_BACKLOG_ROW_BODY, decoded, so a caller can decide what a change needs before
# it changes anything.
FM_BACKLOG_ROW_TITLE=
FM_BACKLOG_ROW_BODY=
fm_backlog_row_title_body() {  # <data-dir> <id>
  local data=$1 id=$2 out command_status title body
  FM_BACKLOG_ROW_TITLE=
  FM_BACKLOG_ROW_BODY=
  data=$(fm_backlog_data_absolute "$data") || return 1
  out=$(fm_backlog_row_show "$data" "$id" --full)
  command_status=$?
  [ "$command_status" -ne 124 ] || FM_BACKLOG_ROW_SHOW_WEDGED=1
  if [ "$command_status" -ne 0 ]; then
    FM_BACKLOG_TRANSITION_ERROR=$(printf '%s\n' "$out" | sed -n '1p')
    [ -n "$FM_BACKLOG_TRANSITION_ERROR" ] \
      || FM_BACKLOG_TRANSITION_ERROR="tasks-axi show $id failed with no output"
    return "$command_status"
  fi
  title=$(printf '%s\n' "$out" | sed -n 's/^  title: //p' | head -1)
  body=$(printf '%s\n' "$out" | sed -n 's/^  body: //p' | head -1)
  if [ -n "$title" ]; then
    title=$(fm_backlog_shown_value "$title") || {
      FM_BACKLOG_TRANSITION_ERROR="could not decode the task title of $id"
      return 1
    }
  fi
  body=$(fm_backlog_shown_value "$body") || {
    FM_BACKLOG_TRANSITION_ERROR="could not decode the task body of $id"
    return 1
  }
  [ "$body" != "-" ] || body=
  FM_BACKLOG_ROW_TITLE=$title
  FM_BACKLOG_ROW_BODY=$body
}

# Set the note that keeps this row's unverified pull request links in the body.
# It reads the row but changes nothing, so a caller can record the note durably
# before it takes the link off the title. Links passed as further arguments are
# recorded too, so a close replaying a recorded link names it even when it never
# reached the title, and the note is empty when there is no link to record. A
# note an interrupted earlier attempt already wrote is reused, so a retry
# rebuilds the same record from the body instead of losing the URL with the title
# it no longer carries.
FM_BACKLOG_PR_LINK_EXCLUDE=
fm_backlog_pr_link_note() {  # <data-dir> <id> <reason> [url...]
  local data=$1 id=$2 reason=$3 url collected='' skip seen recorded
  local -a links=() uniq=()
  shift 3
  data=$(fm_backlog_data_absolute "$data") || return 1
  fm_backlog_row_title_body "$data" "$id" || return 1
  for url in "$@"; do
    [ -z "$url" ] || [ "$url" = "$FM_BACKLOG_PR_LINK_EXCLUDE" ] || links+=("$url")
  done
  if [ -n "$FM_BACKLOG_ROW_TITLE" ]; then
    fm_backlog_title_split_pr_links "$FM_BACKLOG_ROW_TITLE"
    while IFS= read -r url; do
      [ -z "$url" ] || [ "$url" = "$FM_BACKLOG_PR_LINK_EXCLUDE" ] || links+=("$url")
    done <<EOF
$FM_BACKLOG_TITLE_PR_LINKS
EOF
  fi
  FM_BACKLOG_DOWNGRADE_LINKS=
  FM_BACKLOG_DOWNGRADE_NOTE=
  recorded=$(printf '%s\n' "$FM_BACKLOG_ROW_BODY" \
    | sed -n -e 's/^.*; \(Historical record: .*\)$/\1/p' -e 't' \
        -e '/^Historical record: /p' | head -1)
  [ "${#links[@]}" -gt 0 ] || { FM_BACKLOG_DOWNGRADE_NOTE=$recorded; return 0; }
  for url in "${links[@]}"; do
    skip=0
    for seen in "${uniq[@]+"${uniq[@]}"}"; do
      [ "$seen" = "$url" ] && { skip=1; break; }
    done
    [ "$skip" = 0 ] || continue
    uniq+=("$url")
    collected=${collected:+$collected, }$url
    FM_BACKLOG_DOWNGRADE_LINKS=${FM_BACKLOG_DOWNGRADE_LINKS:+$FM_BACKLOG_DOWNGRADE_LINKS$'\n'}$url
  done
  [ -n "$collected" ] || { FM_BACKLOG_DOWNGRADE_NOTE=$recorded; return 0; }
  # No parentheses in this prose: the pending-close record percent-encodes a note
  # value and refuses one whose bytes fall outside the set it can rebuild.
  FM_BACKLOG_DOWNGRADE_NOTE="Historical record: $collected - the merge was not verified in this run: $reason."
}

# Take every canonical pull request link off this row's title, leaving the prose
# and any canonical tags intact. The link named by FM_BACKLOG_PR_LINK_EXCLUDE
# stays, so a close that verified that merge keeps it while the links no run
# verified leave. No flag or configuration overrides tasks-axi's renderer, which
# writes "merged" for any closed row whose title carries such a link, so this is
# how a row that records no verified merge stops claiming one.
fm_backlog_pr_title_strip() {  # <data-dir> <id>
  local data=$1 id=$2 prose url kept='' removed=0
  data=$(fm_backlog_data_absolute "$data") || return 1
  fm_backlog_row_title_body "$data" "$id" || return 1
  [ -n "$FM_BACKLOG_ROW_TITLE" ] || return 0
  fm_backlog_title_split_pr_links "$FM_BACKLOG_ROW_TITLE"
  [ -n "$FM_BACKLOG_TITLE_PR_LINKS" ] || return 0
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    if [ -n "$FM_BACKLOG_PR_LINK_EXCLUDE" ] && [ "$url" = "$FM_BACKLOG_PR_LINK_EXCLUDE" ]; then
      kept=${kept:+$kept }$url
    else
      removed=1
    fi
  done <<EOF
$FM_BACKLOG_TITLE_PR_LINKS
EOF
  [ "$removed" = 1 ] || return 0
  prose=$FM_BACKLOG_TITLE_PROSE
  [ -z "$kept" ] || prose=${prose:+$prose }$kept
  # A title made of nothing but that link would normalize to an empty title,
  # which tasks-axi refuses, so the task's own id stands in.
  [ -n "$prose" ] || prose=$id
  if ! fm_backlog_mutate "$data" update "$id" --title "$prose"; then
    # tasks-axi refuses a title whose tail is a canonical tag, which is what a row
    # that carried its tags before an appended link becomes once that link is
    # removed. A terminator ends the sentence instead of the tag, so the rewrite
    # still lands and the title keeps no pull request URL.
    fm_backlog_mutate "$data" update "$id" --title "$prose." || return 1
  fi
}

# Record <line> as one body line of this row, leaving an identical line alone so a
# retry converges instead of duplicating it.
fm_backlog_body_append_line() {  # <data-dir> <id> <line>
  local data=$1 id=$2 line=$3 new_body tmp
  data=$(fm_backlog_data_absolute "$data") || return 1
  fm_backlog_row_title_body "$data" "$id" || return 1
  case $'\n'"$FM_BACKLOG_ROW_BODY"$'\n' in
    *$'\n'"$line"$'\n'*) return 0 ;;
  esac
  new_body=$line
  [ -z "$FM_BACKLOG_ROW_BODY" ] || new_body=$(printf '%s\n\n%s' "$FM_BACKLOG_ROW_BODY" "$line")
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-backlog-body-line.XXXXXX") || {
    FM_BACKLOG_TRANSITION_ERROR="cannot stage the completion note for $id"
    return 1
  }
  if ! printf '%s\n' "$new_body" > "$tmp"; then
    rm -f -- "$tmp"
    FM_BACKLOG_TRANSITION_ERROR="cannot stage the completion note for $id"
    return 1
  fi
  if ! fm_backlog_mutate "$data" update "$id" --body-file "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp"
}

# Take this row's unverified pull request links off the title and record the
# note that keeps them in the body: the shape every close that records no
# verified merge uses. The note names every link the title carried at this
# moment, so it is written to the body BEFORE the title loses any of them: a
# failed or interrupted write then leaves the title untouched and a retry
# rebuilds exactly the same note, instead of one naming only the link a pending
# record happened to carry. Callers therefore owe no second copy of that sentence.
fm_backlog_pr_link_downgrade() {  # <data-dir> <id> <reason> [url...]
  local data=$1 id=$2 reason=$3
  shift 3
  data=$(fm_backlog_data_absolute "$data") || return 1
  fm_backlog_pr_link_note "$data" "$id" "$reason" "$@" || return 1
  [ -z "$FM_BACKLOG_DOWNGRADE_NOTE" ] \
    || fm_backlog_body_append_line "$data" "$id" "$FM_BACKLOG_DOWNGRADE_NOTE" || return 1
  fm_backlog_pr_title_strip "$data" "$id"
}

# The durable merge-verification record for one task: `state/<id>.pr-merge`.
#
# A cleanup that reads a merge from the forge writes it beside the completion it
# records, because the pending-close record that carries the same fact is retired
# as soon as the transition lands. A captain-held row outlives both: the retained
# row keeps its structured link while the cleanup is gone, and the captain's
# answer arrives later, so the record is the only place the answer can still read
# "some run verified this merge". It is written only for a merge read in the run
# that recorded it, removed once the row is closed in the backlog, and never
# created by a read path. It carries the link and the time the verification
# happened - not the forge's own merge time, which nothing reads and which,
# required-present, would demote a verified merge whenever a writer omitted it.
fm_backlog_merge_fact_path() {  # <state-dir> <id>
  printf '%s/%s.pr-merge\n' "$1" "$2"
}

fm_backlog_merge_fact_write() {  # <state-dir> <id> <url> <verified-at>
  local state=$1 id=$2 url=$3 verified_at=$4 target tmp
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) FM_BACKLOG_TRANSITION_ERROR="invalid task identity for a merge-verification record"; return 1 ;;
  esac
  fm_backlog_row_artifact_supported "$id" --pr "$url" \
    || { FM_BACKLOG_TRANSITION_ERROR="the merge-verification record needs a canonical pull request URL"; return 1; }
  fm_backlog_merge_fact_time_valid "$verified_at" \
    || { FM_BACKLOG_TRANSITION_ERROR="invalid verification time for a merge-verification record"; return 1; }
  fm_backlog_directory_present "$state" "state directory" || return 1
  target=$(fm_backlog_merge_fact_path "$state" "$id")
  fm_backlog_record_parent_authorized "$target" "merge-verification record" "$state" || return 1
  tmp="$state/.$id.pr-merge.${BASHPID:-$$}"
  if ! { printf 'url=%s\n' "$url"
         printf 'verified_at=%s\n' "$verified_at"; } > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    FM_BACKLOG_TRANSITION_ERROR="cannot stage the merge-verification record for $id"
    return 1
  fi
  if ! mv -f "$tmp" "$target" 2>/dev/null; then
    rm -f -- "$tmp"
    FM_BACKLOG_TRANSITION_ERROR="cannot publish the merge-verification record for $id"
    return 1
  fi
}

fm_backlog_merge_fact_time_valid() {  # <timestamp>
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) return 0 ;;
    *) return 1 ;;
  esac
}

# Read the record into FM_BACKLOG_MERGE_FACT_URL, _MERGED_AT, and _VERIFIED_AT.
# Succeeds only for a record whose every field is present and well formed, so an
# unreadable or hand-edited file reads as unverified rather than as a merge.
FM_BACKLOG_MERGE_FACT_URL=
FM_BACKLOG_MERGE_FACT_MERGED_AT=
FM_BACKLOG_MERGE_FACT_VERIFIED_AT=
fm_backlog_merge_fact_read() {  # <state-dir> <id>
  local state=$1 id=$2 target line url='' verified_at='' url_count=0 verified_count=0
  FM_BACKLOG_MERGE_FACT_URL=
  FM_BACKLOG_MERGE_FACT_VERIFIED_AT=
  target=$(fm_backlog_merge_fact_path "$state" "$id") || return 1
  [ -f "$target" ] && [ ! -L "$target" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      url=*) url=${line#url=}; url_count=$((url_count + 1)) ;;
      verified_at=*) verified_at=${line#verified_at=}; verified_count=$((verified_count + 1)) ;;
      *) return 1 ;;
    esac
  done < "$target"
  [ "$url_count" -eq 1 ] && [ "$verified_count" -eq 1 ] || return 1
  fm_backlog_row_artifact_supported "$id" --pr "$url" || return 1
  fm_backlog_merge_fact_time_valid "$verified_at" || return 1
  FM_BACKLOG_MERGE_FACT_URL=$url
  FM_BACKLOG_MERGE_FACT_VERIFIED_AT=$verified_at
}

# Print this row's canonical pull request links, one per line.
fm_backlog_row_pr_links() {  # <data-dir> <id>
  local data=$1 id=$2 url
  data=$(fm_backlog_data_absolute "$data") || return 1
  fm_backlog_row_title_body "$data" "$id" || return 1
  [ -n "$FM_BACKLOG_ROW_TITLE" ] || return 0
  fm_backlog_title_split_pr_links "$FM_BACKLOG_ROW_TITLE"
  while IFS= read -r url; do
    [ -z "$url" ] || printf '%s\n' "$url"
  done <<EOF
$FM_BACKLOG_TITLE_PR_LINKS
EOF
}

# Does this row's title still carry <url> as one of its pull request links? A
# durable merge fact is trusted only for the link the row still shows, so a fact
# left behind by an earlier cycle cannot close a later delivery as merged.
fm_backlog_row_carries_pr_link() {  # <data-dir> <id> <url>
  local seen links
  links=$(fm_backlog_row_pr_links "$1" "$2") || return 1
  [ -n "$links" ] || return 1
  while IFS= read -r seen; do
    [ "$seen" = "$3" ] && return 0
  done <<EOF
$links
EOF
  return 1
}

# Retire the record once the row's close has landed in the backlog: the fact is
# no longer needed, and the task's own retirement would otherwise leave it behind.
fm_backlog_merge_fact_remove() {  # <state-dir> <id>
  local target
  target=$(fm_backlog_merge_fact_path "$1" "$2") || return 0
  rm -f -- "$target" 2>/dev/null || return 0
  return 0
}

# Succeeds when <text> names every one of the links in <newline-separated-links>,
# compared as whole URLs. A caller may strip all those links from the title, so
# proceeding on a partial match would drop the URL it did not write to the body.
# An empty link list names nothing.
fm_backlog_text_names_links() {  # <text> <newline-separated-links>
  local text=$1 link token found seen=0
  local -a words=()
  local IFS=$' \t\n,;()<>"\''
  text=${text//$'\n'/ }
  read -r -a words <<<"$text" || :
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    seen=1
    found=0
    for token in "${words[@]+"${words[@]}"}"; do
      while :; do
        case "$token" in
          *[.:!?]) token=${token%?} ;;
          *) break ;;
        esac
      done
      [ "$token" = "$link" ] && { found=1; break; }
    done
    [ "$found" = 1 ] || return 1
  done <<EOF
$2
EOF
  [ "$seen" = 1 ]
}

fm_backlog_row_artifact_supported() {
  local id=$1 flag=${2:-} value=${3:-}
  case "$flag" in
    --pr) ! fm_backlog_pr_note_label "$value" >/dev/null ;;
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
# fields; only bin/fm-captain-hold.sh answer resolves the call.
fm_backlog_retain() {  # <data-dir> <id> [flag...]
  local data authorized_data=$1 id=$2 previous_arg=''
  local arg deliverable='' line body new_body tmp pr_args=0 note strip_after=0
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
        if fm_backlog_row_artifact_supported "$id" --pr "$arg"; then
          deliverable="${deliverable:+$deliverable; }PR $arg"
          row_args=(--pr "$arg")
          pr_args=1
        else
          deliverable="${deliverable:+$deliverable; }$(fm_backlog_pr_note_label "$arg") $arg"
        fi
        ;;
      --note) deliverable="${deliverable:+$deliverable; }$arg" ;;
    esac
    previous_arg=$arg
  done
  # A retention that records no verified pull-request link cannot leave an
  # earlier one on the row: the captain's later answer closes the row, and
  # tasks-axi renders a closed row carrying such a link as merged. The link moves
  # into the deliverable line, which is the body record this retention already
  # writes, so nothing is lost - and it is written before the title loses the
  # link, so a failed write cannot cost the URL. Callers pass `--pr` only for a
  # merge they read from the forge in the same run.
  if [ "$pr_args" = 0 ]; then
    fm_backlog_pr_link_note "$data" "$id" "this retention read no merge" || return 1
    note=$FM_BACKLOG_DOWNGRADE_NOTE
    if [ -n "$note" ] \
       && ! fm_backlog_text_names_links "$deliverable" "$FM_BACKLOG_DOWNGRADE_LINKS"; then
      deliverable="${deliverable:+$deliverable; }$note"
    fi
    [ -z "$FM_BACKLOG_DOWNGRADE_LINKS" ] || strip_after=1
  fi
  if [ -n "$deliverable" ]; then
    fm_backlog_row_title_body "$data" "$id" || return 1
    body=$FM_BACKLOG_ROW_BODY
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
  if [ "$strip_after" = 1 ]; then
    fm_backlog_pr_title_strip "$data" "$id" || return 1
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

fm_backlog_record_parent_authorized() {  # <path> <label> <root> [parent-only]
  local path=$1 label=$2 root=$3 parent_only=${4:-} parent base parent_resolved expected_path
  local path_resolved root_resolved root_prefix home_resolved final_matches=1
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
  if [ -z "$parent_only" ] && { [ -e "$path" ] || [ -L "$path" ]; }; then
    path_resolved=$(fm_backlog_canonical_existing "$path") || {
      FM_BACKLOG_TRANSITION_ERROR="$label cannot be resolved at $path"
      return 1
    }
    [ "$path_resolved" = "$expected_path" ] || final_matches=0
  else
    path_resolved=$expected_path
  fi
  root_prefix=${root_resolved%/}/
  case "$path_resolved" in
    "$root_prefix"*) ;;
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

# The same incarnation, read for a caller that only needs to notice a CHANGE.
# A record predating the field carries no incarnation to compare, so it yields
# an empty value and proceeds instead of refusing; comparing that empty value
# across a wait still catches a record that gained, lost, or altered one. An
# ambiguous or unreadable field is still an error, because a record that cannot
# name one exact incarnation cannot be compared at all.
fm_backlog_meta_spawn_gen_optional() {  # <meta> <state>
  local meta=$1 state=$2 count
  FM_BACKLOG_META_SPAWN_GEN=
  fm_backlog_record_present "$meta" "task record" "$state" || return 1
  count=$(LC_ALL=C awk -F= '$1 == "spawn_gen" { count++ } END { print count + 0 }' "$meta" 2>/dev/null) || {
    FM_BACKLOG_TRANSITION_ERROR="unreadable spawn generation in task record $meta"
    return 1
  }
  [ "$count" -ne 0 ] || return 0
  fm_backlog_meta_spawn_gen "$meta" "$state"
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
  fm_backlog_merge_fact_remove "$state" "$id"
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
  local marker_merge_verified_at='' merge_verified_count=0
  local url_tail url_authority url_path url_host url_port host_rest host_label host_valid
  local percent_tail percent_valid
  local id_count=0 data_count=0 spawn_gen_count=0 cleanup_incomplete_count=0 mode_count=0
  local args=()
  FM_BACKLOG_CLOSE_VALIDATED_ID=
  FM_BACKLOG_CLOSE_VALIDATED_DATA=
  FM_BACKLOG_CLOSE_VALIDATED_SPAWN_GEN=
  FM_BACKLOG_CLOSE_VALIDATED_CLEANUP_INCOMPLETE=0
  FM_BACKLOG_CLOSE_VALIDATED_MODE=close
  FM_BACKLOG_CLOSE_VALIDATED_MERGE_VERIFIED_AT=
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
      pr_merge_verified_at=*)
        marker_merge_verified_at=${line#pr_merge_verified_at=}
        merge_verified_count=$((merge_verified_count + 1))
        ;;
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
  if [ "$merge_verified_count" -gt 1 ]; then
    FM_BACKLOG_TRANSITION_ERROR="unreadable pending-close record $marker"
    return 1
  fi
  if [ -n "$marker_merge_verified_at" ]; then
    case "$marker_merge_verified_at" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
      *)
        FM_BACKLOG_TRANSITION_ERROR="invalid verified-merge time in pending-close record $marker"
        return 1
        ;;
    esac
  fi
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
        # A note is accepted only when the decoder reconstructs a value the
        # encoder would emit from it again, so the recorded prose the replay
        # writes back is exactly the prose that was staged.
        --note)
          arg_value=$(fm_backlog_note_decode "${args[1]}") \
            && [ -n "$arg_value" ] \
            && [ "$(fm_backlog_note_encode "$arg_value")" = "${args[1]}" ]
          ;;
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
  FM_BACKLOG_CLOSE_VALIDATED_MERGE_VERIFIED_AT=$marker_merge_verified_at
  FM_BACKLOG_CLOSE_VALIDATED_ARGS=("${args[@]+"${args[@]}"}")
}

# A leading `--retain` flag records the captain-held transition (`mode=retain`)
# instead of a close; the remaining flags are the same completion links either
# transition records.
# Set by the writer to the moment this run read the merge from the forge, and by
# every reader to whatever the record carried. The record holds it so a later
# replay or captain answer can tell a merge some run verified from a link written
# before this check existed; empty means unverified, and so does a record without
# the field, which is how every record written before this field existed reads.
FM_BACKLOG_CLOSE_MERGE_VERIFIED_AT=

fm_backlog_close_marker_stage() {  # <temporary-path> <id> <data-dir> <spawn-gen> <state-dir> <cleanup-incomplete: 0|1> [--retain] [flag...]
  local tmp=$1 id=$2 data spawn_gen=$4 state=$5 cleanup_incomplete=$6 arg previous_arg='' serialized
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
    if [ "$previous_arg" = --note ]; then
      serialized=$(fm_backlog_note_encode "$arg") || {
        FM_BACKLOG_TRANSITION_ERROR="unrecordable note text for the pending-close record"
        return 1
      }
      serialized_args+=("$serialized")
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
    [ -z "$FM_BACKLOG_CLOSE_MERGE_VERIFIED_AT" ] \
      || printf 'pr_merge_verified_at=%s\n' "$FM_BACKLOG_CLOSE_MERGE_VERIFIED_AT"
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
  local note
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
  # Carry the recorded merge fact into this replay: it decides whether the
  # recorded link may close the row as a merge, and the re-staging below writes
  # the same fact back so a second replay reaches the same verdict.
  FM_BACKLOG_CLOSE_MERGE_VERIFIED_AT=$FM_BACKLOG_CLOSE_VALIDATED_MERGE_VERIFIED_AT
  args=("${FM_BACKLOG_CLOSE_VALIDATED_ARGS[@]+"${FM_BACKLOG_CLOSE_VALIDATED_ARGS[@]}"}")
  if [ "${args[0]-}" = --note ]; then
    args[1]=$(fm_backlog_note_decode "${args[1]}") || {
      FM_BACKLOG_TRANSITION_ERROR="unreadable note text in pending-close record $marker"
      return 1
    }
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
      ;;
    '')
      # Nothing this record described is still open, so the record is retired
      # without touching the row it names.
      fm_backlog_close_marker_remove "$marker" "$state" || return 1
      FM_BACKLOG_CLOSE_REPLAY_RESULT=stale
      return 0
      ;;
  esac
  # Only now, with the record known to still apply, may the replay change the
  # row. A record that cannot prove its own merge was staged before this check
  # existed, and reading the forge is not this path's job (session start must not
  # need the network), so its recorded link becomes a historical note naming the
  # URL and the row closes as a completion.
  if [ "${args[0]-}" = --pr ] && [ -z "$FM_BACKLOG_CLOSE_MERGE_VERIFIED_AT" ] \
     && fm_backlog_row_artifact_supported "$id" --pr "${args[1]-}"; then
    fm_backlog_pr_link_downgrade "$data" "$id" \
      "the recorded close predates the merge check" "${args[1]}" || return 1
    args=(--note "$FM_BACKLOG_DOWNGRADE_NOTE")
  fi
  case "$row_state" in
    done\ *)
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
