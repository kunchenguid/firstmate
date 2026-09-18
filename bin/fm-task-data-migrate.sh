#!/usr/bin/env bash
# Move eligible legacy data/<task-id>/ artifacts to data/tasks/<task-id>.
#
# The migration inventories every data child before classifying it. Reserved
# home-global directories, active ship/scout records, malformed ids, and
# directories without recognized task artifacts are left untouched.
# Re-running after an interruption merges only identical or still-missing
# entries, so it never overwrites an artifact or a symlink.
#
# Usage: fm-task-data-migrate.sh [--dry-run]
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=${FM_HOME:-$FM_ROOT}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
DRY_RUN=0
case "${1:-}" in
  '') ;;
  --dry-run) DRY_RUN=1 ;;
  -h|--help)
    sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
    exit 0
    ;;
  *) echo "usage: fm-task-data-migrate.sh [--dry-run]" >&2; exit 2 ;;
esac

# shellcheck source=bin/fm-task-path-lib.sh
. "$SCRIPT_DIR/fm-task-path-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fail() { printf 'fm-task-data-migrate: %s\n' "$*" >&2; exit 1; }

[ -d "$DATA" ] && [ ! -L "$DATA" ] || fail "data directory is unavailable: $DATA"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable: $STATE"

LOCK="$STATE/.task-data-migrate.lock"
LOCK_HELD=0
if [ "$DRY_RUN" -eq 0 ]; then
  fm_lock_try_acquire "$LOCK" || fail "another task-data migration is already running"
  LOCK_HELD=1
  trap 'if [ "$LOCK_HELD" -eq 1 ]; then fm_lock_release "$LOCK" || true; fi' EXIT
fi

case "$DATA" in
  /) TASKS_DIR=/tasks ;;
  *) TASKS_DIR="$DATA/tasks" ;;
esac
if [ -e "$TASKS_DIR" ] || [ -L "$TASKS_DIR" ]; then
  [ -d "$TASKS_DIR" ] && [ ! -L "$TASKS_DIR" ] || fail "canonical task directory is not a real directory: $TASKS_DIR"
elif [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$TASKS_DIR" || fail "cannot create canonical task directory: $TASKS_DIR"
fi

reserved_entry() {  # <basename>
  case "$1" in
    tasks|handoff|remote-secondmates|closed-tasks|task-lifecycle|projects|config|captain|backlog|secondmates|learnings) return 0 ;;
    *) return 1 ;;
  esac
}

task_tree_safe() {  # <task-dir>
  local dir=$1 link
  link=$(find -P "$dir" -type l -print -quit 2>/dev/null) \
    || fail "cannot inspect task artifacts safely: $dir"
  [ -z "$link" ] || fail "refusing symlinked task artifact: $link"
}

recognized_artifacts() {  # <legacy-dir>
  local dir=$1 rel
  for rel in brief.md launch-brief.md report.md ship-instructions.md contributions.json review.html review.json; do
    [ -e "$dir/$rel" ] || [ -L "$dir/$rel" ] || continue
    return 0
  done
  find -P "$dir" -maxdepth 1 -type f \( \
    -name 'nm-*-findings.txt' -o -name '.brief.md.*' -o \
    -name '.launch-brief.md.*' -o -name '.ship-instructions.md.*' \
  \) -print -quit 2>/dev/null | grep -q .
}

state_kind() {  # <id>
  sed -n 's/^kind=//p' "$STATE/$1.meta" 2>/dev/null | head -1
}

active_task() {  # <id>
  local kind
  [ -f "$STATE/$1.meta" ] && [ ! -L "$STATE/$1.meta" ] || return 1
  kind=$(state_kind "$1")
  case "$kind" in ship|scout) return 0 ;; *) return 1 ;; esac
}

merge_dir() {  # <source-dir> <destination-dir>
  local source=$1 destination=$2 entry name target
  for entry in "$source"/* "$source"/.[!.]* "$source"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=${entry##*/}
    target="$destination/$name"
    [ ! -L "$entry" ] || fail "refusing symlinked legacy artifact: $entry"
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
      [ "$DRY_RUN" -eq 1 ] || mv -- "$entry" "$target"
    elif [ -d "$entry" ] && [ -d "$target" ] && [ ! -L "$target" ]; then
      merge_dir "$entry" "$target"
    elif [ -f "$entry" ] && [ -f "$target" ] && cmp -s "$entry" "$target"; then
      [ "$DRY_RUN" -eq 1 ] || rm -f -- "$entry"
    else
      fail "conflicting task artifacts: $entry and $target"
    fi
  done
  if [ "$DRY_RUN" -eq 0 ]; then
    rmdir -- "$source" 2>/dev/null || fail "legacy task directory is not empty after migration: $source"
  fi
}

rewrite_instruction_paths() {  # <id> <canonical-dir>
  local id=$1 dir=$2 file legacy canonical
  legacy=$(fm_task_legacy_dir "$DATA" "$id")
  canonical=$(fm_task_dir "$DATA" "$id")
  for file in brief.md launch-brief.md ship-instructions.md; do
    file="$dir/$file"
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    [ "$DRY_RUN" -eq 1 ] && { printf 'would-rewrite: %s\n' "$file"; continue; }
    FM_TASK_OLD_DIR=$legacy FM_TASK_NEW_DIR=$canonical FM_TASK_ID=$id \
      perl -0pi -e '
        my ($old, $new, $task) = @ENV{qw(FM_TASK_OLD_DIR FM_TASK_NEW_DIR FM_TASK_ID)};
        s/\Q$old\E/$new/g;
        s#data/\Q$task\E/#data/tasks/$task/#g;
      ' -- "$file" || fail "cannot update task instructions: $file"
  done
}

show_title() {  # <show-output>
  local shown
  shown=$(printf '%s\n' "$1" | sed -n 's/^  title: //p' | head -1)
  case "$shown" in
    ""|-) return 1 ;;
    \"*)
      printf '%s\n' "$shown" | LC_ALL=C perl -MJSON::PP -e '
        local $/; my $v = <STDIN>; chomp $v;
        my $s = JSON::PP->new->utf8->decode($v);
        binmode STDOUT, ":raw"; utf8::encode($s) if utf8::is_utf8($s); print $s;
      '
      ;;
    *) printf '%s\n' "$shown" ;;
  esac
}

rewrite_backlog_link() {  # <id>
  local id=$1 backlog root backend old_rel new_rel shown title updated
  backlog=$(fm_backlog_file "$DATA" 2>/dev/null || true)
  [ -n "$backlog" ] && [ -f "$backlog" ] || return 0
  old_rel=$(fm_task_legacy_relpath "$id" report.md)
  new_rel=$(fm_task_relpath "$id" report.md)
  grep -F "$old_rel" "$backlog" >/dev/null 2>&1 || return 0
  fm_backlog_backend_manual "$CONFIG" && fail "manual backlog contains a legacy report link for $id; migrate that link through the configured backlog owner first"
  root=$(fm_backlog_root "$DATA") || fail "cannot resolve backlog root"
  backend=$(fm_tasks_axi_backend "$root") || fail "cannot resolve backlog backend"
  [ "$backend" = markdown ] || fail "cannot migrate report link for $id through non-markdown backlog backend $backend"
  fm_backlog_tasks_axi_addressing "$DATA" || fail "cannot address backlog for $id"
  shown=$(cd "$FM_BACKLOG_AXI_ROOT" && fm_tasks_axi show "$id" --full --file "$FM_BACKLOG_AXI_FILE" 2>&1) \
    || fail "tasks-axi could not read backlog task $id"
  title=$(show_title "$shown") || fail "tasks-axi returned no title for backlog task $id"
  case "$title" in *"$old_rel"*) ;; *) return 0 ;; esac
  updated=${title//"$old_rel"/"$new_rel"}
  [ "$DRY_RUN" -eq 1 ] && { printf 'would-update: %s %s -> %s\n' "$id" "$old_rel" "$new_rel"; return 0; }
  (cd "$FM_BACKLOG_AXI_ROOT" && fm_tasks_axi update "$id" --title "$updated" --file "$FM_BACKLOG_AXI_FILE") \
    || fail "tasks-axi could not update report link for backlog task $id"
}

printf '%s\n' "inventory: $DATA"
while IFS= read -r entry || [ -n "$entry" ]; do
  base=${entry##*/}
  if [ ! -d "$entry" ] || [ -L "$entry" ]; then
    printf 'skip: %s (not a real directory)\n' "$entry"
    continue
  fi
  if reserved_entry "$base"; then
    printf 'skip: %s (home-global or migration directory)\n' "$entry"
    continue
  fi
  if ! fm_task_path_id_valid "$base"; then
    printf 'skip: %s (unknown directory name)\n' "$entry"
    continue
  fi
  if ! recognized_artifacts "$entry"; then
    printf 'skip: %s (no recognized task artifact)\n' "$entry"
    continue
  fi
  if active_task "$base"; then
    printf 'skip: %s (active ship/scout; retry after it finishes)\n' "$entry"
    continue
  fi

  destination=$(fm_task_dir "$DATA" "$base")
  task_tree_safe "$entry"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    [ -d "$destination" ] && [ ! -L "$destination" ] || fail "canonical task destination is unsafe: $destination"
    task_tree_safe "$destination"
    printf '%s: %s -> %s\n' "$([ "$DRY_RUN" -eq 1 ] && printf would || printf merge)" "$entry" "$destination"
    [ "$DRY_RUN" -eq 1 ] || merge_dir "$entry" "$destination"
  else
    printf '%s: %s -> %s\n' "$([ "$DRY_RUN" -eq 1 ] && printf would || printf move)" "$entry" "$destination"
    if [ "$DRY_RUN" -eq 0 ]; then
      mv -- "$entry" "$destination" || fail "cannot move task directory $entry"
    fi
  fi
  rewrite_instruction_paths "$base" "$destination"
done < <(fm_task_legacy_entries "$DATA")

# A prior run may have moved a directory before a process interruption stopped
# its backlog update. Revisit every canonical task directory so that retrying is
# sufficient even when no legacy directory remains.
if [ -d "$TASKS_DIR" ] && [ ! -L "$TASKS_DIR" ]; then
  for entry in "$TASKS_DIR"/*; do
    [ -d "$entry" ] && [ ! -L "$entry" ] || continue
    base=${entry##*/}
    fm_task_path_id_valid "$base" || continue
    rewrite_instruction_paths "$base" "$entry"
    rewrite_backlog_link "$base"
  done
fi
