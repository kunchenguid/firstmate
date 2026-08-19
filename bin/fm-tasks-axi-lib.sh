# shellcheck shell=bash
# Shared tasks-axi backend selection, compatibility probe, and archived-record
# read for bootstrap, teardown, secondmate backlog handoff, and the captain
# decision gate.
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
# ARCHIVED RECORDS. `tasks-axi prune` sweeps closed rows out of the active
# backlog into the archive file and offers no read path back: `show` and `list`
# see the active backlog only, `--file` cannot name the archive (its own default
# archive would then collide with it), and no flag or environment variable
# exposes the archive path. A closed row keeps every field it had, so a caller
# that asks whether a durable record EXISTS must look in both files or it will
# report a retained record as missing the moment retention runs. This file is the
# single owner of that read, so no caller reimplements tasks-axi's config
# resolution or its markdown grammar.
#
# fm_tasks_axi_archive_show reads the archive by handing tasks-axi a private
# throwaway copy whose `## Archived <stamp>` block headers are rewritten to the
# `## Done` section header its grammar recognises. Everything past that - entry
# parsing, body decoding, field rendering - stays owned by tasks-axi, so an
# archived record renders byte-identically to a live `show <id> --full`. Only
# closed rows are readable this way, which is what the decision gate needs;
# `prune --state queued` output stays invisible rather than being guessed at.
#
# fm_tasks_axi_backlog_path and fm_tasks_axi_archive_path mirror tasks-axi's own
# config precedence: the project `.tasks.toml` in the home, then
# `~/.tasks-axi/config.toml`, then tasks-axi's built-in defaults, with relative
# values resolved against the home exactly as tasks-axi resolves them against its
# working directory. They exist only because that path is the one part of the
# contract tasks-axi never prints; keep them in step with it. `docs/configuration.md`
# stays the operator-facing owner of what the tracked `.tasks.toml` selects.
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

# The last `<key> = "<value>"` assignment inside the `[markdown]` table of a
# tasks-axi config file, or nothing when the file, table, or key is absent.
# tasks-axi accepts only quoted strings for these keys, so an unquoted value is
# left unread here exactly as it is rejected there.
fm_tasks_axi_toml_markdown_value() {  # <toml-path> <key>
  local file=$1 key=$2
  [ -f "$file" ] || return 0
  awk -v want="$key" '
    {
      line = $0
      sub(/\r$/, "", line)
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
    }
    line ~ /^\[.*\]$/ {
      section = substr(line, 2, length(line) - 2)
      sub(/^[ \t]+/, "", section)
      sub(/[ \t]+$/, "", section)
      in_markdown = (section == "markdown")
      next
    }
    !in_markdown { next }
    {
      if (!match(line, "^" want "[ \t]*=[ \t]*")) next
      rest = substr(line, RLENGTH + 1)
      quote = substr(rest, 1, 1)
      if (quote != "\"" && quote != "'"'"'") next
      rest = substr(rest, 2)
      end = index(rest, quote)
      if (end < 1) next
      value = substr(rest, 1, end - 1)
      found = 1
    }
    END { if (found) print value }
  ' "$file" 2>/dev/null || true
}

# Absolute form of a configured path, resolved against <home> when relative,
# matching how tasks-axi resolves the same value against its working directory.
fm_tasks_axi_resolve_under() {  # <home> <path>
  case "$2" in
    /*) printf '%s\n' "$2" ;;
    *) printf '%s/%s\n' "${1%/}" "$2" ;;
  esac
}

# The active backlog file tasks-axi would use for <home>.
fm_tasks_axi_backlog_path() {  # <home>
  local home=$1 chosen='' candidate
  if [ -n "${TASKS_AXI_FILE:-}" ]; then
    chosen=$TASKS_AXI_FILE
  else
    chosen=$(fm_tasks_axi_toml_markdown_value "${home%/}/.tasks.toml" path)
    [ -n "$chosen" ] || chosen=$(fm_tasks_axi_toml_markdown_value "${HOME:-}/.tasks-axi/config.toml" path)
  fi
  if [ -n "$chosen" ]; then
    fm_tasks_axi_resolve_under "$home" "$chosen"
    return 0
  fi
  for candidate in backlog.md data/backlog.md; do
    if [ -f "${home%/}/$candidate" ]; then
      printf '%s/%s\n' "${home%/}" "$candidate"
      return 0
    fi
  done
  printf '%s/backlog.md\n' "${home%/}"
}

# The archive file tasks-axi would prune <home>'s closed rows into.
fm_tasks_axi_archive_path() {  # <home>
  local home=$1 archive
  archive=$(fm_tasks_axi_toml_markdown_value "${home%/}/.tasks.toml" archive)
  [ -n "$archive" ] || archive=$(fm_tasks_axi_toml_markdown_value "${HOME:-}/.tasks-axi/config.toml" archive)
  if [ -n "$archive" ]; then
    fm_tasks_axi_resolve_under "$home" "$archive"
    return 0
  fi
  printf '%s/done-archive.md\n' "$(dirname "$(fm_tasks_axi_backlog_path "$home")")"
}

# `tasks-axi show <id> --full` for a row retention has already archived, rendered
# by tasks-axi itself against a private throwaway copy. Nonzero, with no output,
# whenever <home> has no readable archived record for that id.
fm_tasks_axi_archive_show() {  # <home> <id>
  local home=$1 id=$2 archive dir view output status=0
  case "$id" in
    ''|-*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  command -v tasks-axi >/dev/null 2>&1 || return 1
  archive=$(fm_tasks_axi_archive_path "$home")
  [ -n "$archive" ] && [ -f "$archive" ] || return 1
  dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-tasks-archive.XXXXXX") || return 1
  view="$dir/archived-backlog.md"
  # The copy lives in its own directory so tasks-axi's default archive path for
  # it can never resolve back onto the real archive, and the read runs from that
  # directory so no project config joins in.
  if sed 's/^## Archived /## Done archived /' "$archive" > "$view" 2>/dev/null; then
    output=$(cd "$dir" && tasks-axi show "$id" --full --file "$view" 2>/dev/null) || status=1
  else
    status=1
  fi
  rm -rf -- "$dir"
  # A miss prints nothing at all: tasks-axi reports NOT_FOUND on stdout, and that
  # text names the throwaway copy, so it must never reach a caller as a record.
  # The identity line every rendered record carries is what tells the two apart.
  [ "$status" -eq 0 ] || return 1
  case $'\n'"$output" in
    *$'\n'"  id: $id"$'\n'*|*$'\n'"  id: $id") printf '%s\n' "$output" ;;
    *) return 1 ;;
  esac
}
