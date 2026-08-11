#!/usr/bin/env bash
# Compose a curated skill subset into a mate/home by symlinking canonical skill folders.
#
# This helper never copies skill folders and never clones repositories. It reads
# data/skill-map.md, resolves each requested skill name to its one canonical
# source folder, and creates symlinks in a per-home composition overlay.
#
# Claude composition point:
#   <target-home>/config/skill-compose/claude/<set>/.claude/skills/<skill>
#
# Launch Claude with `--add-dir <target-home>/config/skill-compose/claude/<set>`
# to load the composed skills without changing the target repo's tracked
# .claude/skills or .agents/skills directories. fm-spawn.sh does this when its
# --skills flag is used for a Claude-backed spawn.
#
# Re-running compose with a skill list reconciles that set exactly: requested
# symlinks are created or updated, and stale symlinks in the set directory are
# removed. Non-symlink entries are refused instead of clobbered.
#
# Usage:
#   fm-skill-compose.sh --target-home <home> [--set <name>] [--map <path>] <skill>...
#   fm-skill-compose.sh --target-home <home> [--set <name>] --remove <skill>...
#   fm-skill-compose.sh --target-home <home> [--set <name>] --clear
#
# Options:
#   --harness claude  Select the load mechanism. Only claude is supported today.
#   --set <name>      Name the curated subset within the home (default: home).
#   --map <path>      Resolve skills from this map (default: data/skill-map.md).
#   --refresh-map     Regenerate the default map before resolving names.
#   --print-add-dir   Print only the directory that Claude should receive via --add-dir.
set -eu
shopt -s dotglob nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
TARGET_HOME=
SET_NAME=home
HARNESS=claude
MAP="$DATA/skill-map.md"
MAP_EXPLICIT=0
REFRESH_MAP=0
MODE=compose
PRINT_ADD_DIR=0
SKILLS=()

usage() { sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//; $d'; }

split_skill_arg() {  # <arg>
  local raw=$1 part
  local -a parts
  raw=${raw//,/ }
  read -r -a parts <<< "$raw"
  for part in "${parts[@]}"; do
    [ -n "$part" ] && SKILLS+=("$part")
  done
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --target-home)
      shift
      [ $# -gt 0 ] || { printf 'error: --target-home requires a directory\n' >&2; exit 2; }
      TARGET_HOME=$1
      ;;
    --set)
      shift
      [ $# -gt 0 ] || { printf 'error: --set requires a name\n' >&2; exit 2; }
      SET_NAME=$1
      ;;
    --harness)
      shift
      [ $# -gt 0 ] || { printf 'error: --harness requires a name\n' >&2; exit 2; }
      HARNESS=$1
      ;;
    --map)
      shift
      [ $# -gt 0 ] || { printf 'error: --map requires a path\n' >&2; exit 2; }
      MAP=$1
      MAP_EXPLICIT=1
      ;;
    --refresh-map) REFRESH_MAP=1 ;;
    --remove) MODE=remove ;;
    --clear) MODE=clear ;;
    --print-add-dir) PRINT_ADD_DIR=1 ;;
    --*) printf 'error: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *) split_skill_arg "$1" ;;
  esac
  shift
done

case "$HARNESS" in
  claude) ;;
  *) printf 'error: skill composition currently supports --harness claude only; %s has no verified per-home load point\n' "$HARNESS" >&2; exit 2 ;;
esac

[ -n "$TARGET_HOME" ] || { printf 'error: --target-home is required\n' >&2; exit 2; }
[ -d "$TARGET_HOME" ] || { printf 'error: target home is not a directory: %s\n' "$TARGET_HOME" >&2; exit 1; }
case "$SET_NAME" in
  ''|.*|*/*|*[!A-Za-z0-9_.-]*) printf 'error: unsafe set name: %s\n' "$SET_NAME" >&2; exit 2 ;;
esac

TARGET_HOME=$(cd "$TARGET_HOME" && pwd -P)
COMPOSE_PARENT="$TARGET_HOME/config/skill-compose/claude"
COMPOSE_ROOT="$COMPOSE_PARENT/$SET_NAME"
SKILLS_DIR="$COMPOSE_ROOT/.claude/skills"
MANIFEST="$COMPOSE_ROOT/manifest.tsv"
COMPOSE_LOCK=
COMPOSE_LOCK_HELD=0
COMPOSE_TEMP_FILES=()

if [ "$PRINT_ADD_DIR" -eq 1 ] && [ "$MODE" = compose ] && [ "${#SKILLS[@]}" -eq 0 ]; then
  printf '%s\n' "$COMPOSE_ROOT"
  exit 0
fi

safe_skill_name() {  # <name>
  case "$1" in
    ''|.*|*/*|*'..'*|*[!A-Za-z0-9_.-]*) return 1 ;;
    *) return 0 ;;
  esac
}

canonical_dir() { (cd "$1" 2>/dev/null && pwd -P); }

ensure_map() {
  if [ "$REFRESH_MAP" -eq 1 ]; then
    if [ "$MAP_EXPLICIT" -eq 1 ]; then
      "$SCRIPT_DIR/fm-skill-map.sh" --output "$MAP" --quiet
    else
      "$SCRIPT_DIR/fm-skill-map.sh" --quiet
    fi
  elif [ ! -f "$MAP" ]; then
    if [ "$MAP_EXPLICIT" -eq 1 ]; then
      printf 'error: skill map does not exist: %s\n' "$MAP" >&2
      exit 1
    fi
    "$SCRIPT_DIR/fm-skill-map.sh" --quiet
  fi
  [ -f "$MAP" ] || { printf 'error: skill map does not exist after refresh: %s\n' "$MAP" >&2; exit 1; }
}

resolve_skill() {  # <name>; prints canonical path
  local name=$1 matches count path
  matches=$(awk -v n="$name" '
    BEGIN { separator = " — " }
    /^- / {
      line = substr($0, 3)
      first = index(line, separator)
      if (first == 0 || substr(line, 1, first - 1) != n) next
      remainder = substr(line, first + length(separator))
      second = index(remainder, separator)
      if (second > 0) print substr(remainder, second + length(separator))
    }
  ' "$MAP")
  count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')
  case "$count" in
    0) printf 'error: skill not found in %s: %s\n' "$MAP" "$name" >&2; return 1 ;;
    1) ;;
    *) printf 'error: skill name is ambiguous in %s: %s\n%s\n' "$MAP" "$name" "$matches" >&2; return 1 ;;
  esac
  path=$(printf '%s\n' "$matches" | sed '/^$/d')
  [ -d "$path" ] || { printf 'error: mapped skill path is not a directory for %s: %s\n' "$name" "$path" >&2; return 1; }
  [ -f "$path/SKILL.md" ] || { printf 'error: mapped skill path lacks SKILL.md for %s: %s\n' "$name" "$path" >&2; return 1; }
  canonical_dir "$path"
}

link_target_real() {  # <symlink>
  local target dir base
  target=$(readlink "$1") || return 1
  case "$target" in
    /*) canonical_dir "$target" ;;
    *)
      dir=$(dirname "$1")
      base="$dir/$target"
      canonical_dir "$base"
      ;;
  esac
}

skill_requested() {  # <name>
  local requested
  for requested in "${SKILLS[@]}"; do
    [ "$requested" = "$1" ] && return 0
  done
  return 1
}

validate_skill_args() {
  local name
  for name in "${SKILLS[@]}"; do
    safe_skill_name "$name" || { printf 'error: unsafe skill name: %s\n' "$name" >&2; return 2; }
  done
}

validate_managed_layout() {
  local path
  for path in \
    "$TARGET_HOME/config" \
    "$TARGET_HOME/config/skill-compose" \
    "$TARGET_HOME/config/skill-compose/claude" \
    "$COMPOSE_ROOT" \
    "$COMPOSE_ROOT/.claude" \
    "$SKILLS_DIR"; do
    if { [ -e "$path" ] || [ -L "$path" ]; } && [ ! -d "$path" ]; then
      printf 'error: managed composition path is not a directory: %s\n' "$path" >&2
      return 1
    fi
  done
  if [ -d "$MANIFEST" ]; then
    printf 'error: managed composition manifest is a directory: %s\n' "$MANIFEST" >&2
    return 1
  fi
}

validate_existing_skill_entries() {  # <compose|remove|clear>
  local context=$1 entry name
  [ -d "$SKILLS_DIR" ] || return 0
  for entry in "$SKILLS_DIR"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    [ -L "$entry" ] && continue
    name=$(basename "$entry")
    if skill_requested "$name"; then
      case "$context" in
        compose) printf 'error: refusing to replace non-symlink entry: %s\n' "$entry" >&2 ;;
        remove) printf 'error: refusing to remove non-symlink entry: %s\n' "$entry" >&2 ;;
        *) printf 'error: non-symlink entry in managed skill set: %s\n' "$entry" >&2 ;;
      esac
    else
      printf 'error: non-symlink entry in managed skill set: %s\n' "$entry" >&2
    fi
    return 1
  done
}

release_compose_lock() {
  [ "$COMPOSE_LOCK_HELD" -eq 1 ] || return 0
  COMPOSE_LOCK_HELD=0
  fm_lock_release "$COMPOSE_LOCK" || true
}

compose_exit() {
  local status=$? file
  for file in "${COMPOSE_TEMP_FILES[@]}"; do
    rm -f "$file" 2>/dev/null || true
  done
  release_compose_lock
  return "$status"
}

acquire_compose_lock() {
  local prior_state_set=0 prior_state= prior_override_set=0 prior_override=
  validate_managed_layout
  mkdir -p "$COMPOSE_PARENT"
  [ "${STATE+x}" = x ] && { prior_state_set=1; prior_state=$STATE; }
  [ "${FM_STATE_OVERRIDE+x}" = x ] && { prior_override_set=1; prior_override=$FM_STATE_OVERRIDE; }
  STATE=$COMPOSE_PARENT
  FM_STATE_OVERRIDE=$COMPOSE_PARENT
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  if [ "$prior_state_set" -eq 1 ]; then STATE=$prior_state; else unset STATE; fi
  if [ "$prior_override_set" -eq 1 ]; then FM_STATE_OVERRIDE=$prior_override; else unset FM_STATE_OVERRIDE; fi
  COMPOSE_LOCK="$COMPOSE_PARENT/.compose-$SET_NAME.lock"
  fm_lock_acquire_wait "$COMPOSE_LOCK"
  COMPOSE_LOCK_HELD=1
  validate_managed_layout
}

prevalidate_mode() {
  case "$MODE" in
    clear)
      [ "${#SKILLS[@]}" -eq 0 ] || { printf 'error: --clear does not accept skill names\n' >&2; return 2; }
      ;;
    remove)
      [ "${#SKILLS[@]}" -gt 0 ] || { printf 'error: --remove requires at least one skill name\n' >&2; return 2; }
      validate_skill_args
      ;;
    compose)
      [ "${#SKILLS[@]}" -gt 0 ] || { printf 'error: compose requires at least one skill name, or use --clear\n' >&2; return 2; }
      validate_skill_args
      ;;
    *) printf 'error: internal unknown mode: %s\n' "$MODE" >&2; return 2 ;;
  esac
}

write_manifest_from_symlinks() {
  local tmp entry name target
  mkdir -p "$COMPOSE_ROOT"
  tmp="$MANIFEST.tmp.$$"
  : > "$tmp"
  if [ -d "$SKILLS_DIR" ]; then
    for entry in "$SKILLS_DIR"/*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      name=$(basename "$entry")
      if [ -L "$entry" ]; then
        target=$(link_target_real "$entry" 2>/dev/null || readlink "$entry" || true)
        printf '%s\t%s\n' "$name" "$target" >> "$tmp"
      else
        rm -f "$tmp"
        printf 'error: non-symlink entry in managed skill set: %s\n' "$entry" >&2
        return 1
      fi
    done
  fi
  sort -f "$tmp" -o "$tmp"
  mv -f "$tmp" "$MANIFEST"
}

clear_set() {
  local entry
  validate_managed_layout
  validate_existing_skill_entries clear
  if [ -d "$SKILLS_DIR" ]; then
    for entry in "$SKILLS_DIR"/*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      rm -f -- "$entry"
    done
  fi
  rm -f "$MANIFEST"
  rmdir "$SKILLS_DIR" "$COMPOSE_ROOT/.claude" "$COMPOSE_ROOT" 2>/dev/null || true
  [ "$PRINT_ADD_DIR" -eq 1 ] && printf '%s\n' "$COMPOSE_ROOT" || printf 'cleared %s\n' "$COMPOSE_ROOT"
}

remove_skills() {
  local name entry
  validate_managed_layout
  validate_existing_skill_entries remove
  mkdir -p "$SKILLS_DIR"
  for name in "${SKILLS[@]}"; do
    entry="$SKILLS_DIR/$name"
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      rm -f -- "$entry"
    fi
  done
  write_manifest_from_symlinks
  [ "$PRINT_ADD_DIR" -eq 1 ] && printf '%s\n' "$COMPOSE_ROOT" || printf 'updated %s\n' "$COMPOSE_ROOT"
}

compose_exact() {
  local wanted names_file name path entry current requested=0 existing
  validate_managed_layout
  validate_existing_skill_entries compose
  ensure_map
  wanted=$(mktemp "${TMPDIR:-/tmp}/fm-skill-compose-wanted.XXXXXX") || exit 1
  COMPOSE_TEMP_FILES+=("$wanted")
  names_file=$(mktemp "${TMPDIR:-/tmp}/fm-skill-compose-names.XXXXXX") || exit 1
  COMPOSE_TEMP_FILES+=("$names_file")
  : > "$wanted"
  : > "$names_file"
  for name in "${SKILLS[@]}"; do
    if grep -Fx -- "$name" "$names_file" >/dev/null 2>&1; then
      continue
    fi
    printf '%s\n' "$name" >> "$names_file"
    path=$(resolve_skill "$name") || return 1
    printf '%s\t%s\n' "$name" "$path" >> "$wanted"
    requested=$((requested + 1))
  done

  mkdir -p "$SKILLS_DIR"
  for existing in "$SKILLS_DIR"/*; do
    [ -e "$existing" ] || [ -L "$existing" ] || continue
    name=$(basename "$existing")
    if ! grep -F -x -- "$name" "$names_file" >/dev/null 2>&1; then
      rm -f -- "$existing"
    fi
  done

  while IFS=$'\t' read -r name path; do
    [ -n "$name" ] || continue
    entry="$SKILLS_DIR/$name"
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      current=$(link_target_real "$entry" 2>/dev/null || true)
      [ "$current" = "$path" ] || { rm -f -- "$entry"; ln -s "$path" "$entry"; }
    else
      ln -s "$path" "$entry"
    fi
  done < "$wanted"

  sort -f "$wanted" > "$MANIFEST.tmp.$$"
  mv -f "$MANIFEST.tmp.$$" "$MANIFEST"
  if [ "$PRINT_ADD_DIR" -eq 1 ]; then
    printf '%s\n' "$COMPOSE_ROOT"
  else
    printf 'composed %s skill(s) into %s\n' "$requested" "$COMPOSE_ROOT"
    printf 'claude add-dir: %s\n' "$COMPOSE_ROOT"
  fi
}

prevalidate_mode
trap compose_exit EXIT
acquire_compose_lock

case "$MODE" in
  clear) clear_set ;;
  remove) remove_skills ;;
  compose) compose_exact ;;
esac
