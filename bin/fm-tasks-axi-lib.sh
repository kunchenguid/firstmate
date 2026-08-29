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
# a private copy whose `## Archived <date>` headings become the one `## Done`
# heading the parser accepts: the first dated heading is rewritten and the rest
# are dropped, so every archived row lands under a single section and the read
# never depends on the parser tolerating a repeated section heading. tasks-axi
# stays the single owner of the backlog format; the copy only makes the archive's
# own section headings legible to it.
# That copy is staged at most once per process and reused across lookups, and
# this file removes it at exit itself, without displacing a sourcing script's own
# exit handler, so an entry point that reads a record wires up nothing; see the
# memo below.
#
# THE OUTCOMES ARE KEPT APART, and fm_tasks_axi_record_show below is the one
# owner of the whole two-file read so a caller never has to compose it again: a
# record found in the backlog, a record found in the archive, no record in
# either, a copy that cannot be parsed, a copy that could not be staged, and an
# archive path that could not be read at all are six separate answers. Only "no
# record" is quiet, because only that one is honest: a home that has never had a
# row trimmed has no archive file, which is the healthy normal state, while an
# archive that exists and cannot be read is a record that may well be there and
# must never be reported as absent. Each caller owns its own wording for these.

# One `[markdown]` file path from <home>'s own tasks-axi config, resolved the way
# tasks-axi resolves it: the configured value when present, else the default the
# tracked .tasks.toml pins. A relative value resolves against <home>, because
# that is the directory tasks-axi runs in.
# Only the `[markdown]` table is read. `backend =` is a top-level key, so another
# backend may carry its own `path`/`archive`, and an unscoped scan would hand
# back that other backend's file: the archive lookup would read the wrong file
# and report an archived record as absent, which is the failure this whole read
# exists to remove.
# tasks-axi is this file's real reader, so what tasks-axi accepts FROM
# <home>/.tasks.toml is what this resolver accepts from it, and that bounds it in
# BOTH directions. Missing a form tasks-axi honors falls back to the default,
# which for a home that configured its own paths names a file that does not
# exist; honoring a form tasks-axi ignores resolves a configured path retention
# never writes. Either way the lookup searches a file that is never written and
# reports an archived record as absent, which is the failure this whole read
# exists to remove.
# So, measured against 0.2.4 (the FM_TASKS_AXI_MIN floor) and 0.2.5: a trailing
# comment, a carriage return, and whitespace inside the brackets all still name
# this table; a quoted `["markdown"]` key does NOT, because tasks-axi falls back
# to its own defaults under it; and a value may be a double-quoted basic string
# or a single-quoted literal string, because tasks-axi honors both. An
# `[[markdown]]` array-of-tables header needs no carve-out: tasks-axi rejects
# that whole config, so such a home has no backlog for a record to be archived
# from in the first place.
#
# THAT MIRROR CLAIM IS SCOPED TO <home>/.tasks.toml AND NOTHING ELSE. tasks-axi
# resolves `path` and `archive` from TWO config layers: that project file and a
# user-level `~/.tasks-axi/config.toml` under the invoking user's own home
# directory. This resolver does not read the user-level layer at all. So a home
# that sets `path` in its own .tasks.toml but leaves `archive` to that
# user-level file has retention writing one file while this read searches
# another, which is the same false "no record" the whole two-file read exists to
# remove. Measured against 0.2.5: with the project layer silent on `archive` and
# the user-level layer naming one, tasks-axi archived into the user-level path
# while this resolver returned <home>/data/done-archive.md.
# It is LATENT rather than live, which is why it is written down here instead of
# fixed: the PROJECT layer WINS whenever both layers set the key, so a home whose
# .tasks.toml pins `archive`, as firstmate's tracked config does, cannot be
# reached through the user-level layer at all. Measured the same way: with both
# layers naming an `archive`, tasks-axi archived into the project path and this
# resolver agreed.
# One more divergence sits in the same gap. Within ONE `[markdown]` table
# tasks-axi lets a repeated key win LAST, while the awk below stops at the first
# match and takes the FIRST. Measured the same way: with `archive` listed twice
# in one table, tasks-axi archived into the second path while this resolver
# returned the first. Latent for the same reason, since the tracked config
# declares each key exactly once.
# Work item tasks-config-fallback-divergence-f4 owns the whole question of where
# this resolver looks when the project file is silent, that layer and this
# ordering both.
fm_tasks_axi_markdown_path() {  # <home> <key> <default-relative>
  local home=$1 key=$2 default=$3 config="$1/.tasks.toml" value='' quotes="\"'"
  if [ -f "$config" ] && [ ! -L "$config" ]; then
    value=$(awk -v key="$key" -v quotes="$quotes" '
      /^[ \t]*\[/ {
        section = $0
        sub(/\r$/, "", section)
        sub(/#.*$/, "", section)
        sub(/^[ \t]*\[+[ \t]*/, "", section)
        sub(/[ \t]*\]+[ \t]*$/, "", section)
        in_markdown = (section == "markdown")
        next
      }
      !in_markdown { next }
      {
        eq = index($0, "=")
        if (eq == 0) next
        name = substr($0, 1, eq - 1)
        sub(/^[ \t]+/, "", name)
        sub(/[ \t]+$/, "", name)
        if (name != key) next
        value = substr($0, eq + 1)
        sub(/^[ \t]+/, "", value)
        if (length(value) < 2) next
        quote = substr(value, 1, 1)
        if (index(quotes, quote) == 0) next
        value = substr(value, 2)
        endq = index(value, quote)
        if (endq == 0) next
        print substr(value, 1, endq - 1)
        exit
      }
    ' "$config" 2>/dev/null)
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
#   0 - the archive carries an entry for this id
#   1 - it does not, which INCLUDES there being no archive file at all: a home
#       that has never had a row trimmed has nothing to search, and that is the
#       healthy normal state rather than a failure
#   4 - the archive path exists but is not a readable regular file, or the read
#       itself failed, so the question was never asked; a caller must not read
#       this as no entry, and a caller using this as a fail-closed guard must
#       refuse rather than proceed
# Only those three ever escape. The guards below answer whether the path can be
# opened, but a read can still fail after it opens, and `grep` reports that with
# a status of its own: a file unlinked under the open, an EIO, a stale network
# handle. Passing that status through would make "the read broke" arrive at a
# caller as one of the two ANSWERS, and the ownership check in
# bin/fm-captain-hold.sh reads "no entry" as "another home owns this origin", so
# a leaked read error would disown a home from its own investigation. A read that
# did not complete is therefore folded into 4, which every caller already treats
# as having settled nothing.
fm_tasks_axi_archive_has_entry() {  # <archive-file> <id>
  local file=$1 id=$2 pattern rc=0
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 1
  fi
  { [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ]; } || return 4
  pattern=$(printf '%s' "$id" | sed 's/[][\\.*^$+?(){}|/]/\\&/g')
  grep -Eq "^- \[[ x]\] $pattern - " "$file" 2>/dev/null || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 4 ;;
  esac
}

# ONE STAGED VIEW PER PROCESS. Every archived lookup needs the same
# parser-legible copy of the same archive, and the archive only ever grows, so
# staging it per lookup made an inventory loop or a redelivered `answers` batch
# copy the whole file once per archived row it touched. The memo is keyed on the
# RESOLVED archive path and on that file's byte size:
#   - the path, so two homes in one process, or a reconfigured path, can never be
#     served each other's view;
#   - the size, because the archive can GROW mid-process. `tasks-axi done` prunes
#     by default, so closing one row can archive another between two lookups, and
#     a view staged before that append must not answer for the row it added. An
#     archive is only ever appended to, so a changed size is exactly the signal
#     that a retention move landed.
FM_TASKS_AXI_ARCHIVE_VIEW=''
FM_TASKS_AXI_ARCHIVE_VIEW_KEY=''

# Drop the staged view, if one was staged. Idempotent and quiet, so an exit path
# may call it unconditionally and it never disturbs the status being exited with.
fm_tasks_axi_archive_view_release() {
  local view=$FM_TASKS_AXI_ARCHIVE_VIEW
  FM_TASKS_AXI_ARCHIVE_VIEW=''
  FM_TASKS_AXI_ARCHIVE_VIEW_KEY=''
  if [ -n "$view" ]; then
    rm -f -- "$view" 2>/dev/null || true
  fi
  return 0
}

# REMOVING THE VIEW IS THIS FILE'S OWN JOB, not a convention a sourcing script
# has to remember. The view outlives the call that staged it, so only an EXIT
# trap can remove it, and a shell has exactly one. Claiming that trap outright
# would throw away whatever handler the sourcing script installed, so this arms
# itself the first time a view is actually staged and CHAINS instead: it reads
# the handler installed at that moment, puts itself in front of it, and runs the
# captured handler afterwards. A script has finished its own setup long before it
# reads a record, so the handler it wants is the one that gets captured. Nothing
# to wire per entry point, and no caller loses its own cleanup.
FM_TASKS_AXI_ARCHIVE_VIEW_CHAINED_EXIT=''

fm_tasks_axi_archive_view_exit() {
  local status=$?
  fm_tasks_axi_archive_view_release
  if [ -n "$FM_TASKS_AXI_ARCHIVE_VIEW_CHAINED_EXIT" ]; then
    eval "$FM_TASKS_AXI_ARCHIVE_VIEW_CHAINED_EXIT" || true
  fi
  return "$status"
}

fm_tasks_axi_archive_view_arm_release() {
  local spec
  spec=$(trap -p EXIT 2>/dev/null) || spec=''
  case "$spec" in
    *fm_tasks_axi_archive_view_exit*) return 0 ;;
  esac
  FM_TASKS_AXI_ARCHIVE_VIEW_CHAINED_EXIT=''
  if [ -n "$spec" ]; then
    # `trap -p` prints a command that would reinstall the handler, so re-reading
    # that command as shell words hands the handler back exactly as the shell
    # holds it, quoting and all: `trap -- '<handler>' EXIT` puts it in $3.
    eval "set -- $spec" 2>/dev/null || set -- '' '' ''
    FM_TASKS_AXI_ARCHIVE_VIEW_CHAINED_EXIT=${3:-}
  fi
  trap fm_tasks_axi_archive_view_exit EXIT
}

# The current staged view of <archive-file>, in FM_TASKS_AXI_ARCHIVE_VIEW.
#   0 - FM_TASKS_AXI_ARCHIVE_VIEW names a readable view of this archive
#   3 - no readable copy of it could be staged, so nothing was read at all
fm_tasks_axi_archive_view() {  # <archive-file>
  local archive=$1 size key view
  size=$(wc -c < "$archive" 2>/dev/null) || return 3
  size=${size//[![:digit:]]/}
  [ -n "$size" ] || return 3
  key="$size:$archive"
  if [ "$key" = "$FM_TASKS_AXI_ARCHIVE_VIEW_KEY" ] && [ -f "$FM_TASKS_AXI_ARCHIVE_VIEW" ]; then
    return 0
  fi
  fm_tasks_axi_archive_view_release
  view=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-archive-view.XXXXXX") || return 3
  # Every archived row under ONE section: the first dated heading becomes the
  # `## Done` heading the parser accepts and the later ones are dropped, so their
  # rows join that same section.
  if ! awk '
    /^## Archived / {
      if (done_heading) next
      done_heading = 1
      print "## Done"
      next
    }
    { print }
  ' "$archive" > "$view" 2>/dev/null; then
    rm -f -- "$view"
    return 3
  fi
  FM_TASKS_AXI_ARCHIVE_VIEW=$view
  FM_TASKS_AXI_ARCHIVE_VIEW_KEY=$key
  fm_tasks_axi_archive_view_arm_release
  return 0
}

# One archived task, as `tasks-axi show --full` prints it, in
# FM_TASKS_AXI_ARCHIVE_RECORD. It reports through a global rather than stdout for
# the reason fm_tasks_axi_record_show below does, plus one of its own: the staged
# view above is memoised in this process's shell variables, and a command
# substitution would run the staging inside a subshell whose memo dies with it,
# restaging on every lookup and leaving every copy behind.
#   0 - the record is in FM_TASKS_AXI_ARCHIVE_RECORD
#   1 - the archive carries no entry for this id
#   2 - the archive carries the entry but it could not be read back through
#       tasks-axi; the archive layout moved, and a caller must say so loudly
#       rather than treat a record that exists as absent
#   3 - the archive carries the entry but no readable copy of it could be staged,
#       so nothing was read at all; the repair is this machine's temp space
#       rather than the archive, and a caller must blame neither the layout nor
#       an absent record
#   4 - the archive path could not be read at all, so whether it carries the
#       entry is unknown; passed through from fm_tasks_axi_archive_has_entry
FM_TASKS_AXI_ARCHIVE_RECORD=''
fm_tasks_axi_archive_show() {  # <home> <id>
  local home=$1 id=$2 archive out rc=0
  FM_TASKS_AXI_ARCHIVE_RECORD=''
  archive=$(fm_tasks_axi_archive_file "$home")
  fm_tasks_axi_archive_has_entry "$archive" "$id" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  fm_tasks_axi_archive_view "$archive" || return 3
  out=$( (cd "$home" && tasks-axi show "$id" --full --file "$FM_TASKS_AXI_ARCHIVE_VIEW") 2>/dev/null ) \
    || rc=$?
  { [ "$rc" -eq 0 ] && [ -n "$out" ]; } || return 2
  FM_TASKS_AXI_ARCHIVE_RECORD=$out
  return 0
}

# One task record from wherever it lives: the active backlog first, then the
# archive retention moved a closed row into. This is the whole two-file read in
# one place, so no caller composes it again and a new outcome is added here once.
# It sets globals rather than printing because a caller also needs to know WHICH
# file answered, which a command substitution could not carry back out.
#   0 - found; FM_TASKS_AXI_RECORD is the record and FM_TASKS_AXI_RECORD_ARCHIVED
#       is 1 when the archive answered and 0 when the active backlog did
#   1 - no record in either file
#   2 - the archive carries the entry but it could not be read back
#   3 - the archive carries the entry but no readable copy of it could be staged
#   4 - the archive path could not be read at all
FM_TASKS_AXI_RECORD=''
FM_TASKS_AXI_RECORD_ARCHIVED=0
# shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
fm_tasks_axi_record_show() {  # <home> <id>
  local home=$1 id=$2 rc=0
  FM_TASKS_AXI_RECORD=''
  FM_TASKS_AXI_RECORD_ARCHIVED=0
  if FM_TASKS_AXI_RECORD=$( (cd "$home" && tasks-axi show "$id" --full) 2>/dev/null ); then
    return 0
  fi
  # Called directly, never through a command substitution: the archive read
  # memoises its staged view in this process's shell variables, and a subshell
  # could carry neither the memo nor the copy's path back out.
  fm_tasks_axi_archive_show "$home" "$id" || rc=$?
  if [ "$rc" -eq 0 ]; then
    FM_TASKS_AXI_RECORD=$FM_TASKS_AXI_ARCHIVE_RECORD
    FM_TASKS_AXI_RECORD_ARCHIVED=1
    return 0
  fi
  FM_TASKS_AXI_RECORD=''
  return "$rc"
}
