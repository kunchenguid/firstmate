#!/usr/bin/env bash
# fm-continuation-lib.sh - the single owner of the cross-harness continuation
# record's schema, atomic write, field/block reading, validation, and Markdown
# rendering. Sourced by bin/fm-control.sh (which builds and updates the record
# as part of its transactional relaunch) and bin/fm-spawn.sh (which renders it
# into a persistent secondmate's launch instructions without ever rewriting
# the charter).
#
# WHY. A relaunch replaces the running agent in the same endpoint and
# worktree (bin/fm-control.sh), but the outgoing agent's own reasoning -
# what it was trying to do, what it already tried, what it found, what is
# still open, and exactly what to do next - would otherwise exist only in
# the conversation that is about to be discarded. The continuation record is
# the harness-neutral, versioned note that survives that discard: built once
# per relaunch from the caller's explicit operational context (never parsed
# or inferred from a transcript), merged onto whatever the previous relaunch
# already recorded, and delivered to the replacement alongside its existing
# durable instructions (brief.md or a secondmate's charter, never rewritten).
#
# RECORD (state/<id>.continuation; written only through fm_continuation_write,
# below; YAML-shaped so a human can read it, but parsed only by the readers in
# this file). Ten single-line fields come first, in this fixed order, followed
# by nine block-scalar fields. A block field is either "<name>: -" (empty) or
# "<name>: |" followed by every content line prefixed with two spaces; the
# block ends at the next unindented line. The single-line-field readers stop
# scanning at the first block boundary ("modified_files: ") so free-text block
# content can never be misread as a top-level field:
#
#   schema: 1
#   task: <task id>
#   kind: ship | scout | secondmate
#   role: <one-line logical identity, e.g. "ship task <id>">
#   provenance: <who/what produced this update>
#   timestamp: <UTC ISO 8601, the moment this update was written>
#   branch: <branch name, or - for a detached worktree>
#   revision: <HEAD sha, or "unborn">
#   worktree: <absolute path>
#   worktree_dirty: yes | no
#   modified_files: |            paths from `git status --porcelain`, or -
#   tests_status: |              validation/test state at this moment, or -
#   durable_refs: |              pointers only: brief.md, report.md, a PR URL,
#                                 a backlog id - never a copy of their content
#   objective: |
#   completed: |
#   decisions: |
#   findings: |
#   unresolved: |
#   next_action: |
#
# Every field is optional content-wise (an absent or refused narrative reads
# as empty), but the record itself always carries all nineteen field markers -
# fm_continuation_write is the only writer and always emits the full shape, so
# a record either has the complete shape or is not one this file produced.
set -u

FM_CONTINUATION_SCHEMA=1

fm_continuation_path() {  # <state-dir> <task-id>
  printf '%s/%s.continuation' "$1" "$2"
}

fm_continuation_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# fm_continuation_oneline: collapse a caller-supplied value to one line so it
# can never corrupt a single-line field's shape.
fm_continuation_oneline() {  # <text>
  printf '%s' "$1" | tr '\n\r' '  '
}

# fm_continuation_write_atomic: write stdin to <path> via tmp-then-mv so a
# reader never observes a partial record.
fm_continuation_write_atomic() {  # <path>
  local path=$1 pending
  mkdir -p "$(dirname "$path")" || return 1
  pending=$(mktemp "$(dirname "$path")/.continuation.pending.XXXXXX") || return 1
  if ! cat > "$pending"; then
    rm -f "$pending"
    return 1
  fi
  mv "$pending" "$path" || { rm -f "$pending"; return 1; }
}

# --- record reading (the only parsers) --------------------------------------

# fm_continuation_read_field: the value of a single-line header field. Scans
# only the header region (everything before the first block-field marker), so
# free-text block content can never be misread as a field.
fm_continuation_read_field() {  # <path> <name>
  local path=$1 name=$2
  [ -f "$path" ] || return 1
  awk -v field="$name" '
    /^modified_files: / { exit }
    index($0, field ": ") == 1 { print substr($0, length(field) + 3); exit }
  ' "$path"
}

# fm_continuation_read_block: the stored content of a block-scalar field
# (empty when the field is the empty form "<name>: -" or is absent).
fm_continuation_read_block() {  # <path> <name>
  local path=$1 name=$2
  [ -f "$path" ] || return 1
  awk -v field="$name" '
    {
      if (found && inblock) {
        if ($0 ~ /^  /) { print substr($0, 3); next }
        exit
      }
      if (!found && $0 == field ": -") { found = 1; exit }
      if (!found && $0 == field ": |") { found = 1; inblock = 1; next }
    }
  ' "$path"
}

FM_CONTINUATION_BLOCK_FIELDS='modified_files tests_status durable_refs objective completed decisions findings unresolved next_action'

# fm_continuation_validate: prints nothing and returns 0 for a usable record;
# prints one concrete error and returns 1 otherwise. <expected-task>, when
# non-empty, refuses a record whose task field names a different task - the
# no-duplicate-identity guard that keeps a stale or foreign record from ever
# being merged onto the wrong task's continuation.
fm_continuation_validate() {  # <path> [expected-task]
  local path=$1 expected=${2:-} schema task field
  [ -f "$path" ] || { echo "no continuation record at $path"; return 1; }
  [ -r "$path" ] || { echo "continuation record $path is not readable"; return 1; }
  schema=$(fm_continuation_read_field "$path" schema)
  [ "$schema" = "$FM_CONTINUATION_SCHEMA" ] || {
    echo "continuation record $path has schema '${schema:-none}', which this firstmate does not support (expected $FM_CONTINUATION_SCHEMA)"
    return 1
  }
  task=$(fm_continuation_read_field "$path" task)
  [ -n "$task" ] || { echo "continuation record $path has no task field"; return 1; }
  if [ -n "$expected" ] && [ "$task" != "$expected" ]; then
    echo "continuation record $path records task '$task', not the expected '$expected'; refusing to merge a record for a different task"
    return 1
  fi
  case "$(fm_continuation_read_field "$path" worktree_dirty)" in
    yes|no) ;;
    *) echo "continuation record $path has an invalid worktree_dirty field"; return 1 ;;
  esac
  for field in $FM_CONTINUATION_BLOCK_FIELDS; do
    if ! grep -Fqx -e "$field: -" -e "$field: |" "$path"; then
      echo "continuation record $path is missing its $field block marker"
      return 1
    fi
  done
  return 0
}

# fm_continuation_render_block: print one block-scalar field (its marker line,
# then every content line prefixed with two spaces).
fm_continuation_render_block() {  # <name> <text>
  local name=$1 text=$2
  if [ -z "$text" ]; then
    printf '%s: -\n' "$name"
    return 0
  fi
  printf '%s: |\n' "$name"
  printf '%s\n' "$text" | sed 's/^/  /'
}

# fm_continuation_write: build and print the complete record to stdout, from
# the explicit arguments below (positional, not caller-set globals, so every
# call site states its full content at the call). Callers pipe the output
# into fm_continuation_write_atomic.
fm_continuation_write() {  # <task> <kind> <role> <provenance> <branch> <revision> <worktree> <dirty> <modified_files> <tests_status> <durable_refs> <objective> <completed> <decisions> <findings> <unresolved> <next_action>
  local task=$1 kind=$2 role=$3 provenance=$4 branch=$5 revision=$6 worktree=$7 dirty=$8
  local modified_files=$9 tests_status=${10} durable_refs=${11} objective=${12}
  local completed=${13} decisions=${14} findings=${15} unresolved=${16} next_action=${17}
  printf 'schema: %s\n' "$FM_CONTINUATION_SCHEMA"
  printf 'task: %s\n' "$(fm_continuation_oneline "$task")"
  printf 'kind: %s\n' "$(fm_continuation_oneline "$kind")"
  printf 'role: %s\n' "$(fm_continuation_oneline "$role")"
  printf 'provenance: %s\n' "$(fm_continuation_oneline "$provenance")"
  printf 'timestamp: %s\n' "$(fm_continuation_now_iso)"
  printf 'branch: %s\n' "$(fm_continuation_oneline "${branch:--}")"
  printf 'revision: %s\n' "$(fm_continuation_oneline "$revision")"
  printf 'worktree: %s\n' "$(fm_continuation_oneline "$worktree")"
  printf 'worktree_dirty: %s\n' "$(fm_continuation_oneline "$dirty")"
  fm_continuation_render_block modified_files "$modified_files"
  fm_continuation_render_block tests_status "$tests_status"
  fm_continuation_render_block durable_refs "$durable_refs"
  fm_continuation_render_block objective "$objective"
  fm_continuation_render_block completed "$completed"
  fm_continuation_render_block decisions "$decisions"
  fm_continuation_render_block findings "$findings"
  fm_continuation_render_block unresolved "$unresolved"
  fm_continuation_render_block next_action "$next_action"
}

# fm_continuation_render_markdown: render a validated record as a Markdown
# section for embedding into the replacement's instructions (a ship/scout
# brief's progress note, or a secondmate's launch-only charter overlay).
fm_continuation_render_markdown() {  # <path>
  local path=$1 field label name text
  echo "A structured continuation record from the previous incarnation is durably kept at $path. Its content follows."
  echo
  printf -- '- role: %s\n' "$(fm_continuation_read_field "$path" role)"
  printf -- '- branch: %s  revision: %s  worktree dirty: %s\n' \
    "$(fm_continuation_read_field "$path" branch)" \
    "$(fm_continuation_read_field "$path" revision)" \
    "$(fm_continuation_read_field "$path" worktree_dirty)"
  printf -- '- provenance: %s (recorded %s)\n' \
    "$(fm_continuation_read_field "$path" provenance)" \
    "$(fm_continuation_read_field "$path" timestamp)"
  echo
  for field in "objective:Objective" "completed:Completed work" "decisions:Decisions" \
    "findings:Findings/evidence" "unresolved:Unresolved questions/blockers" \
    "modified_files:Modified/uncommitted files" "tests_status:Test/validation status" \
    "durable_refs:Durable-record references" "next_action:Exact next action"; do
    name=${field%%:*}
    label=${field#*:}
    text=$(fm_continuation_read_block "$path" "$name")
    printf '**%s:**\n' "$label"
    if [ -n "$text" ]; then
      printf '%s\n' "$text"
    else
      echo "(none recorded)"
    fi
    echo
  done
}
