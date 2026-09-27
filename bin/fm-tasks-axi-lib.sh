# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap,
# teardown, and secondmate backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
#
# Compatible means tasks-axi --version reports FM_TASKS_AXI_MIN or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs.
# FM_TASKS_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
# The feature probes are a separate concern and stay as defense in depth for
# stripped or forked builds that advertise a current version without those flags.
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.
# fm_tasks_axi_backend_resolve owns backend precedence: TASKS_AXI_BACKEND when
# set, then a backend in the working root's .tasks.toml, then one in
# $HOME/.tasks-axi/config.toml, then markdown. Lower-priority sources are read
# only when no earlier source supplies a backend; absent files keep that fallback.
# A detected unreadable or nonregular configuration file, including a dangling
# symlink, returns 2 with a path diagnostic on stderr and no backend on stdout.
# fm_tasks_axi_backend delegates to that resolver and preserves its status;
# callers must check it before selecting backend-specific flags or exemptions.
#
# This file is the single owner of FM_TASKS_AXI_MIN. bin/fm-bootstrap.sh turns a
# failing check into the operator-facing MISSING diagnostic.
#
# COMPATIBILITY VERDICT REUSE. fm_tasks_axi_compatible costs three tasks-axi
# subprocesses, and one session start needs the same verdict twice: once in
# bin/fm-session-start.sh's backlog listing and once in the bin/fm-bootstrap.sh
# child it runs. Two reuse layers collapse that to a single probe:
#   - Within a process the first probe's answer is memoised.
#   - Across ONE process hop, a parent that already holds the verdict passes it
#     in FM_TASKS_AXI_COMPATIBLE=0|1. Sourcing this file CONSUMES that variable
#     (it is unset from the environment and kept only as a private shell
#     variable), so the verdict reaches the child that needs it and never leaks
#     onward into a spawned agent's environment, where it could outlive a
#     tasks-axi upgrade. Any value other than exactly 0 or 1 is ignored and the
#     probe runs normally.
# Both layers are bounded by process lifetime, so a tasks-axi install or upgrade
# is picked up by the next process rather than being cached to disk.

FM_TASKS_AXI_MIN=0.2.6

FM_TASKS_AXI_COMPATIBLE_MEMO=${FM_TASKS_AXI_COMPATIBLE:-}
unset FM_TASKS_AXI_COMPATIBLE
case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
  0|1) ;;
  *) FM_TASKS_AXI_COMPATIBLE_MEMO= ;;
esac

fm_tasks_axi_version_parts() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_tasks_axi_compatible() {
  case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  if fm_tasks_axi_compatible_probe; then
    FM_TASKS_AXI_COMPATIBLE_MEMO=1
    return 0
  fi
  FM_TASKS_AXI_COMPATIBLE_MEMO=0
  return 1
}

fm_tasks_axi_compatible_probe() {
  local parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(fm_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_TASKS_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  if [ "$major" -gt "$min_major" ] ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -gt "$min_minor" ]; } ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -eq "$min_minor" ] && [ "$patch" -ge "$min_patch" ]; }; then
    fm_tasks_axi_update_has_archive_body && fm_tasks_axi_mv_has_multi_id
    return $?
  fi
  return 1
}

fm_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_tasks_axi_backend_from_toml() {  # <toml-path>
  fm_tasks_axi_toml_value "$1" '' backend
}

# One quoted scalar out of a .tasks.toml, read the way tasks-axi reads it.
# <table> is the table the key must sit under, empty for the root table, so a
# `backend` at the root and an `archive` under `[markdown]` come from the same
# parser instead of two hand-rolled ones.
fm_tasks_axi_toml_value() {  # <toml-path> <table> <key>
  local toml=$1 table=$2 key=$3
  [ -f "$toml" ] || return 1
  LC_ALL=C awk -v want_table="$table" -v want_key="$key" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    BEGIN { table=""; found=0; single=sprintf("%c", 39) }
    {
      line=$0
      sub(/[[:space:]]*#.*/, "", line)
      line=trim(line)
      if (line ~ /^\[[^]]+\]$/) {
        table=substr(line, 2, length(line) - 2)
        next
      }
      if (table == want_table && line ~ "^" want_key "[[:space:]]*=") {
        sub("^" want_key "[[:space:]]*=[[:space:]]*", "", line)
        line=trim(line)
        if ((substr(line, 1, 1) == "\"" && substr(line, length(line), 1) == "\"") ||
            (substr(line, 1, 1) == single && substr(line, length(line), 1) == single)) {
          print substr(line, 2, length(line) - 2)
          found=1
          exit
        }
      }
    }
    END { if (!found) exit 1 }
  ' "$toml"
}

# Resolve the active tasks-axi backend with the same precedence as tasks-axi.
fm_tasks_axi_backend_resolve() {  # <tasks-axi-working-directory>
  local root=$1 backend
  if [ "${TASKS_AXI_BACKEND+x}" = x ]; then
    printf '%s\n' "$TASKS_AXI_BACKEND"
    return 0
  fi
  local config="$root/.tasks.toml"
  if { [ -d "${config%/*}" ] && [ ! -x "${config%/*}" ]; } ||
    { { [ -e "$config" ] || [ -L "$config" ]; } && { [ ! -f "$config" ] || [ ! -r "$config" ]; }; }; then
    printf 'tasks-axi backend configuration cannot be read at %s\n' "$config" >&2
    return 2
  fi
  if backend=$(fm_tasks_axi_backend_from_toml "$config"); then
    printf '%s\n' "$backend"
    return 0
  fi
  if [ -n "${HOME:-}" ]; then
    config="$HOME/.tasks-axi/config.toml"
    if { [ -d "${config%/*}" ] && [ ! -x "${config%/*}" ]; } ||
      { { [ -e "$config" ] || [ -L "$config" ]; } && { [ ! -f "$config" ] || [ ! -r "$config" ]; }; }; then
      printf 'tasks-axi backend configuration cannot be read at %s\n' "$config" >&2
      return 2
    fi
    if backend=$(fm_tasks_axi_backend_from_toml "$config"); then
      printf '%s\n' "$backend"
      return 0
    fi
  fi
  printf '%s\n' markdown
}

fm_tasks_axi_backend() {  # <tasks-axi-working-directory>
  fm_tasks_axi_backend_resolve "$1"
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}

# fm_tasks_axi_archive_show <data-dir> <id> [flag...]
# `tasks-axi show <id>` against the ARCHIVE of the backlog <data-dir> owns,
# for an id that is no longer in the active backlog. tasks-axi prunes a done
# row out of data/backlog.md into data/done-archive.md once it ages past
# done_keep, so a resolved-and-archived captain hold is absent from every
# active-backlog read; without this fallback each completion gate and
# idempotent replay built on that read reports it as permanently gone.
#
# This is the archive HALF of a lookup, never the whole lookup: callers run
# their own active-backlog read first (bin/fm-captain-hold.sh through
# fm_backlog_row_show, bin/fm-decision-hold.sh through bin/fm-tasks-axi.sh)
# and only reach here when that read genuinely found nothing. Keeping the
# fallback in one function keeps its contract single-owner while each caller
# keeps the active read - and the read bound - it already had.
#
# The archive path is derived from the SAME <data-dir> the caller resolved its
# active read against, and is never taken as a separate argument: an
# independently computed archive path could point the archive half of one
# lookup at a different base than the active half ever checked.
# fm_tasks_axi_markdown_archive owns that derivation and reproduces tasks-axi's
# own rule rather than assuming the archive sits beside the backlog, because it
# need not: tasks-axi resolves a configured `[markdown] archive` against the
# BACKLOG ROOT, independently of where the backlog file itself was addressed,
# so a relocated FM_DATA_OVERRIDE archives into the configured directory and
# not into the relocated one.
#
# Scoped to the markdown backend, and inert on every other one: done-archive.md
# is a markdown-backlog artifact, and a configured adapter (Beads) keeps its
# own history in its own store, where an archived row is still an ordinary
# `tasks-axi show`. A non-markdown backend therefore returns 1 with no error
# and no behavior change, exactly as if the row were absent.
#
# tasks-axi's own markdown parser only recognizes "in flight", "queued", and
# "done"-prefixed section headers; the archive's literal "## Archived <date>"
# headers parse as inert raw text, so `tasks-axi show --file <archive>` finds
# nothing even pointed straight at the archive. Normalizing just that header
# text to "## Done" in a throwaway copy lets tasks-axi's own parser and
# renderer do the real work, so this never re-implements its markdown grammar.
#
# The read is bounded whenever the caller has already sourced
# bin/fm-timeout-lib.sh (fm-backlog-transition-lib.sh does), so this inherits
# the caller's existing bound posture rather than introducing an unbounded
# backend read into a sweep that had bounded every other one.
#
# Every active-backlog miss reaches here, and the sweeps that miss most are the
# ones this fallback must not slow down: fm-captain-hold.sh's resolver tries an
# exact id and then a legacy one per key, and the reconcile and answer scans
# repeat that per item. So a copy of the whole archive plus a backend spawn is
# spent only once the id literally appears in the archive, which an archived row
# always does. The grep is a COST guard and never the authority on whether the
# hold exists: a candidate that passes it is still answered by tasks-axi's own
# parser and renderer, and a grep that could not run at all (any status but a
# clean "no match") falls through to the full read rather than inventing an
# absence the archive was never consulted for.
fm_tasks_axi_archive_show() {  # <data-dir> <id> [flag...]
  local data=$1 id=$2 root archive normalized out status precheck=0
  shift 2
  case "$data" in
    */*)
      root=${data%/*}
      [ -n "$root" ] || root=/
      ;;
    *) root=. ;;
  esac
  [ "$(fm_tasks_axi_backend "$root" 2>/dev/null)" = markdown ] || return 1
  archive=$(fm_tasks_axi_markdown_archive "$root" "$data")
  [ -f "$archive" ] || return 1
  [ -s "$archive" ] || return 1
  LC_ALL=C grep -qF -- "$id" "$archive" 2>/dev/null || precheck=$?
  [ "$precheck" -ne 1 ] || return 1
  normalized=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tasks-axi-archive.XXXXXX") || return 1
  if ! sed 's/^## Archived .*/## Done/' "$archive" > "$normalized" 2>/dev/null; then
    rm -f -- "$normalized"
    return 1
  fi
  # tasks-axi writes its own "not found" text to stdout rather than stderr, so
  # the result is captured and only printed once the status says it is a row.
  if declare -F fm_run_timed >/dev/null 2>&1; then
    out=$(cd "$root" && fm_run_timed "$(fm_tasks_axi_read_bound)" \
      tasks-axi show "$id" "$@" --file "$normalized" 2>/dev/null)
  else
    out=$(cd "$root" && tasks-axi show "$id" "$@" --file "$normalized" 2>/dev/null)
  fi
  status=$?
  rm -f -- "$normalized"
  [ "$status" -eq 0 ] || return "$status"
  printf '%s\n' "$out"
}

# Where tasks-axi archives a pruned done row for the markdown backend, resolved
# exactly as tasks-axi resolves it: a `[markdown] archive` in the backlog root's
# own .tasks.toml, else one in $HOME/.tasks-axi/config.toml (the same two
# sources, in the same order, that fm_tasks_axi_backend_resolve reads), else
# tasks-axi's own default of done-archive.md beside the backlog file.
#
# A configured value is relative to the backlog ROOT, not to <data-dir>: with a
# relocated FM_DATA_OVERRIDE the backlog is addressed as <data-dir>/backlog.md
# while its archive still lands under the configured path, so deriving the
# archive from <data-dir> alone would look for it in a directory tasks-axi
# never writes.
fm_tasks_axi_markdown_archive() {  # <backlog-root> <data-dir>
  local root=$1 data=$2 archive=''
  archive=$(fm_tasks_axi_toml_value "$root/.tasks.toml" markdown archive 2>/dev/null) || archive=''
  if [ -z "$archive" ] && [ -n "${HOME:-}" ]; then
    archive=$(fm_tasks_axi_toml_value "$HOME/.tasks-axi/config.toml" markdown archive 2>/dev/null) || archive=''
  fi
  case "$archive" in
    '') printf '%s/done-archive.md\n' "$data" ;;
    /*) printf '%s\n' "$archive" ;;
    *) printf '%s/%s\n' "$root" "$archive" ;;
  esac
}

# The one owner of the backlog read bound, for the active-backlog read
# (fm_backlog_row_show) and the archive read above alike. A non-positive or
# unparseable value is not a bound at all (bin/fm-timeout-lib.sh), and a padded
# zero such as 00 is still zero, so the digits test alone would let the very
# unbounded read the bound exists to prevent back in: compare arithmetically,
# tolerating a value too large for the shell to compare at all.
fm_tasks_axi_read_bound() {
  local secs=${FM_BACKLOG_ROW_TIMEOUT_SECS:-10}
  case "$secs" in ''|*[!0-9]*) secs=10 ;; esac
  [ "$secs" -gt 0 ] 2>/dev/null || secs=10
  printf '%s\n' "$secs"
}
