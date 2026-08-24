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
#
# This file is the single owner of FM_TASKS_AXI_MIN. bin/fm-bootstrap.sh turns a
# failing check into the operator-facing MISSING diagnostic.
#
# ARCHIVED-TASK ACCESS. `tasks-axi show` and `tasks-axi update` read the ACTIVE
# backlog only. Retention prunes closed tasks out of it on every close once the
# `done_keep` window is full, and they persist permanently in the archive file,
# so a closed task older than that window reads as absent rather than as the
# durable record it still is. fm_tasks_axi_archive_path,
# fm_tasks_axi_show_archived, and fm_tasks_axi_update_archived_body_file are this
# file's single owner of reaching that archive.
#
# The path comes from the home's own `.tasks.toml`. Both operations work through
# tasks-axi itself on a throwaway copy whose `## Archived <date>` heading is
# normalized to `## Done`, because tasks-axi parses its own sections and refuses
# `--file` pointed at the configured archive itself; the archive's own format is
# never parsed or written by hand here beyond locating and restoring the heading
# line of the one section that holds the task. Reading copies the whole archive.
# Writing copies out exactly one section, lets tasks-axi rewrite that section,
# restores its original heading, splices it back at the same line range, and
# replaces the archive by atomic rename, so a task in another section is never
# rewritten and an interrupted write leaves the archive untouched.
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

fm_tasks_axi_archive_path() {  # <home>
  local home=$1 config="$1/.tasks.toml" value=''
  if [ -f "$config" ]; then
    value=$(sed -n 's/^[[:space:]]*archive[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$config" | head -1)
  fi
  [ -n "$value" ] || value=data/done-archive.md
  case "$value" in
    /*) printf '%s\n' "$value" ;;
    *) printf '%s/%s\n' "$home" "$value" ;;
  esac
}

fm_tasks_axi_show_archived() {  # <home> <id>; prints `tasks-axi show --full` output
  local home=$1 id=$2 archive tmp output rc=0
  archive=$(fm_tasks_axi_archive_path "$home")
  [ -f "$archive" ] || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/.fm-archive-view.XXXXXX") || return 1
  if ! sed 's/^## Archived .*/## Done/' "$archive" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  output=$( (cd "$home" && tasks-axi show "$id" --full --file "$tmp") 2>/dev/null ) || rc=1
  rm -f -- "$tmp"
  [ "$rc" -eq 0 ] || return 1
  [ -n "$output" ] || return 1
  printf '%s\n' "$output"
}

# Locate the one archive section holding <id>. Prints "<first-line> <last-line>";
# returns 1 unless exactly one archived entry matches, so an ambiguous or absent
# id is never written blind.
fm_tasks_axi_archive_section() {  # <archive> <id>
  local archive=$1 id=$2 matches count
  matches=$(awk -v id="$id" '
    /^## / { section++ }
    index($0, "- [x] " id " - ") == 1 { print section }
  ' "$archive")
  count=$(printf '%s' "$matches" | grep -c . || true)
  [ "$count" = 1 ] || return 1
  awk -v want="$matches" '
    /^## / { section++ }
    section == want { if (!first) first = NR; last = NR }
    END { if (first) print first, last }
  ' "$archive" | grep . || return 1
}

fm_tasks_axi_update_archived_body_file() {  # <home> <id> <body-file>
  local home=$1 id=$2 body_file=$3 archive first last heading tmp out trailing i rc=0
  archive=$(fm_tasks_axi_archive_path "$home")
  [ -f "$archive" ] || return 1
  read -r first last <<< "$(fm_tasks_axi_archive_section "$archive" "$id")" || return 1
  [ -n "${last:-}" ] || return 1
  heading=$(sed -n "${first}p" "$archive")
  case "$heading" in
    '## '*) ;;
    *) return 1 ;;
  esac
  tmp=$(mktemp "${TMPDIR:-/tmp}/.fm-archive-edit.XXXXXX") || return 1
  out=$(mktemp "${TMPDIR:-/tmp}/.fm-archive-out.XXXXXX") || { rm -f -- "$tmp"; return 1; }
  {
    printf '## Done\n'
    sed -n "$((first + 1)),${last}p" "$archive"
  } > "$tmp" || rc=1
  if [ "$rc" -eq 0 ]; then
    (cd "$home" && tasks-axi update "$id" --body-file "$body_file" --archive-body --file "$tmp") \
      >/dev/null 2>&1 || rc=1
  fi
  # The rewritten section must still be the one section it went in as, or the
  # splice below would corrupt the archive rather than repair one entry.
  if [ "$rc" -eq 0 ]; then
    [ "$(head -1 "$tmp")" = '## Done' ] || rc=1
    grep -F -- "- [x] $id - " "$tmp" >/dev/null || rc=1
    [ "$(grep -c '^## ' "$tmp")" = 1 ] || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    # Splice the rewritten section back under its own heading, restoring the
    # blank separator lines the original section ended with, so only the one
    # repaired body differs from the archive that went in.
    trailing=$(awk -v first="$first" -v last="$last" '
      NR >= first && NR <= last { lines[NR] = $0 }
      END { n = 0; for (i = last; i >= first && lines[i] == ""; i--) n++; print n }
    ' "$archive")
    {
      [ "$first" -gt 1 ] && sed -n "1,$((first - 1))p" "$archive"
      printf '%s\n' "$heading"
      sed -n '2,$p' "$tmp" | awk '
        { lines[NR] = $0 }
        END { end = NR; while (end > 0 && lines[end] == "") end--; for (i = 1; i <= end; i++) print lines[i] }
      '
      i=0
      while [ "$i" -lt "$trailing" ]; do printf '\n'; i=$((i + 1)); done
      sed -n "$((last + 1)),\$p" "$archive"
    } > "$out" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    mv -- "$out" "$archive" || rc=1
  fi
  rm -f -- "$tmp"
  [ ! -f "$out" ] || rm -f -- "$out"
  return "$rc"
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
