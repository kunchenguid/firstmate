# shellcheck shell=bash
# Shared tasks-axi backend selection, compatibility probe, and archive reads for
# bootstrap, teardown, secondmate backlog handoff, and captain holds.
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

FM_TASKS_AXI_MIN=0.2.4

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

# ARCHIVE READS.
#
# Retention does not delete a closed task, it MOVES it: `tasks-axi prune` and the
# `done_keep` trim carry a Done row out of the active backlog and into the
# configured archive. Both files therefore hold real records, and any check that
# asks "does this record still exist?" has to look in both or it will report
# safely archived work as missing.
#
# These helpers are that second lookup and they are strictly read-only. Every
# tasks-axi mutation targets the active backlog alone, so a caller that found a
# record here must not try to write to it.
#
# tasks-axi exposes no archive-aware read, and `--file <archive>` is refused
# while that same path is the configured archive, so an archived row is read from
# a private copy whose `## Archived <date>` headings are rewritten to the
# `## Done` heading the parser accepts. tasks-axi stays the single owner of the
# backlog format; the copy only makes the archive's own section headings legible
# to it, and fm_tasks_axi_archive_show reports a copy it cannot parse as a
# distinct failure rather than as an absent record.

# One `[markdown]` file path from <home>'s own tasks-axi config, resolved the way
# tasks-axi resolves it: the configured value when present, else the default the
# tracked .tasks.toml pins. A relative value resolves against <home>, because
# that is the directory tasks-axi runs in.
fm_tasks_axi_markdown_path() {  # <home> <key> <default-relative>
  local home=$1 key=$2 default=$3 config="$1/.tasks.toml" value=''
  if [ -f "$config" ] && [ ! -L "$config" ]; then
    value=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
      "$config" 2>/dev/null | head -1)
  fi
  [ -n "$value" ] || value=$default
  case "$value" in
    /*) printf '%s\n' "$value" ;;
    *) printf '%s/%s\n' "$home" "$value" ;;
  esac
}

fm_tasks_axi_backlog_file() {  # <home>
  fm_tasks_axi_markdown_path "$1" path data/backlog.md
}

fm_tasks_axi_archive_file() {  # <home>
  fm_tasks_axi_markdown_path "$1" archive data/done-archive.md
}

# Does the archive carry a task ENTRY for this id? Two jobs: it keeps the common
# "no such record anywhere" answer from paying for a copy and a parse, and it is
# the signal that separates an unreadable archive from an absent record below.
# Deliberately over-inclusive is fine and under-inclusive is not, so it matches
# the canonical entry line and lets tasks-axi give the real answer.
fm_tasks_axi_archive_has_entry() {  # <archive-file> <id>
  local file=$1 id=$2 pattern
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  pattern=$(printf '%s' "$id" | sed 's/[][\\.*^$+?(){}|/]/\\&/g')
  grep -Eq "^- \[[ x]\] $pattern - " "$file" 2>/dev/null
}

# One archived task, printed as `tasks-axi show --full` output.
#   0 - the record is printed on stdout
#   1 - the archive carries no entry for this id
#   2 - the archive carries the entry but it could not be read back through
#       tasks-axi; the archive layout moved, and a caller must say so loudly
#       rather than treat a record that exists as absent
fm_tasks_axi_archive_show() {  # <home> <id>
  local home=$1 id=$2 archive view out rc=0
  archive=$(fm_tasks_axi_archive_file "$home")
  fm_tasks_axi_archive_has_entry "$archive" "$id" || return 1
  view=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-archive-view.XXXXXX") || return 2
  if ! sed 's/^## Archived .*/## Done/' "$archive" > "$view" 2>/dev/null; then
    rm -f -- "$view"
    return 2
  fi
  out=$( (cd "$home" && tasks-axi show "$id" --full --file "$view") 2>/dev/null ) || rc=$?
  rm -f -- "$view"
  { [ "$rc" -eq 0 ] && [ -n "$out" ]; } || return 2
  printf '%s\n' "$out"
}
