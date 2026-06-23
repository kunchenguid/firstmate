#!/usr/bin/env bash
# Provision and route persistent secondmate homes.
#
# Usage:
#   fm-home-seed.sh <id> <home|-> <project>...
#       Provision <home> as an isolated firstmate home. If <home> is "-", acquire
#       a fresh firstmate worktree via "treehouse get --lease", which durably
#       leases the worktree under the secondmate <id> so the home survives with
#       no live process and is never recycled until the lease is released with
#       "treehouse return". Projects are cloned
#       from the active home into the secondmate home's projects/ directory.
#       That project list is non-exclusive provisioning data. The charter brief
#       is copied to data/charter.md, newly cloned no-mistakes projects are
#       initialized, a .fm-secondmate-home marker is written, and
#       data/secondmates.md is updated.
#       Seeding is transactional: on validation, clone, init, or registry failure,
#       generated briefs, new homes, new project clones, and registry edits are
#       rolled back. Treehouse-acquired homes are returned only when the rollback
#       target is safe; a failed return warns because the lease may still be held.
#       Set FM_SECONDMATE_CHARTER='<charter>' to seed from inline charter text
#       when no filled charter brief exists. Set FM_SECONDMATE_SCOPE='<scope>'
#       to override the registry routing scope. Otherwise the registry summary
#       and scope are derived from the filled charter brief.
#   fm-home-seed.sh validate
#       Refuse duplicate ids, duplicate homes, and nested or overlapping homes in
#       data/secondmates.md.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
REG="$DATA/secondmates.md"
SUB_HOME_MARKER=".fm-secondmate-home"

usage() {
  echo "usage: fm-home-seed.sh <id> <home|-> <project>..." >&2
  echo "       fm-home-seed.sh validate" >&2
}

registry_home_for_line() {
  sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p'
}

normalize_registry_text() {
  awk '
    {
      gsub(/[;()]/, " ")
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, "")
      sub(/ $/, "")
      if ($0 != "") {
        out = out (out == "" ? "" : " ") $0
      }
    }
    END { print out }
  '
}

brief_section_text() {
  local brief=$1 heading=$2
  awk -v heading="# $heading" '
    $0 == heading { in_section=1; next }
    in_section && /^# / { exit }
    in_section { print }
  ' "$brief"
}

registry_summary_for_brief() {
  local brief=$1
  if [ -n "${FM_SECONDMATE_CHARTER:-}" ]; then
    printf '%s\n' "$FM_SECONDMATE_CHARTER" | normalize_registry_text
  else
    brief_section_text "$brief" "Charter" | normalize_registry_text
  fi
}

registry_scope_for_brief() {
  local brief=$1
  if [ -n "${FM_SECONDMATE_SCOPE:-}" ]; then
    printf '%s\n' "$FM_SECONDMATE_SCOPE" | normalize_registry_text
  else
    brief_section_text "$brief" "Routing scope" | normalize_registry_text
  fi
}

validate_registry_home_text() {
  local home=$1
  case "$home" in
    *';'*|*')'*|*$'\n'*)
      echo "error: secondmate home path contains registry delimiters: $home" >&2
      return 1
      ;;
  esac
}

normalize_joined_path() {
  local prefix=$1 tail=$2 component out old_ifs
  out=${prefix%/}
  [ -n "$out" ] || out=/
  old_ifs=$IFS
  IFS=/
  for component in $tail; do
    case "$component" in
      ''|.) ;;
      ..)
        if [ "$out" != "/" ]; then
          out=${out%/*}
          [ -n "$out" ] || out=/
        fi
        ;;
      *)
        if [ "$out" = "/" ]; then
          out="/$component"
        else
          out="$out/$component"
        fi
        ;;
    esac
  done
  IFS=$old_ifs
  printf '%s\n' "$out"
}

canonical_path_for_check() {
  local path=$1 probe tail prefix parent base
  case "$path" in
    /*) probe=$path ;;
    *) probe="$(pwd -P)/$path" ;;
  esac
  while [ "$probe" != "/" ] && [ "${probe%/}" != "$probe" ]; do
    probe=${probe%/}
  done
  if [ -e "$probe" ]; then
    if [ -d "$probe" ]; then
      cd "$probe" && pwd -P
    else
      parent=$(dirname "$probe")
      base=$(basename "$probe")
      cd "$parent" && printf '%s/%s\n' "$(pwd -P)" "$base"
    fi
    return
  fi
  tail=
  while [ ! -e "$probe" ] && [ "$probe" != "/" ]; do
    tail="$(basename "$probe")${tail:+/$tail}"
    probe=$(dirname "$probe")
  done
  if [ -d "$probe" ]; then
    prefix=$(cd "$probe" && pwd -P)
  elif [ -e "$probe" ]; then
    parent=$(dirname "$probe")
    base=$(basename "$probe")
    prefix=$(cd "$parent" && printf '%s/%s\n' "$(pwd -P)" "$base")
  else
    prefix=/
  fi
  normalize_joined_path "$prefix" "$tail"
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

registry_home_conflict_for_assignment() {
  local id=$1 home=$2 target line registered_id registered_home registered_key
  [ -f "$REG" ] || return 1
  target=$(resolved_path "$home")
  while IFS= read -r line; do
    case "$line" in
      "- "*)
        registered_id=${line#- }
        registered_id=${registered_id%% *}
        registered_home=$(printf '%s\n' "$line" | registry_home_for_line)
        [ -n "$registered_home" ] || continue
        registered_key=$(resolved_path "$registered_home")
        if [ "$registered_key" = "$target" ]; then
          [ "$registered_id" = "$id" ] && continue
          printf 'exact\t%s\t%s\n' "$registered_id" "$registered_key"
          return 0
        fi
        if path_is_ancestor_of "$registered_key" "$target" || path_is_ancestor_of "$target" "$registered_key"; then
          printf 'overlap\t%s\t%s\n' "$registered_id" "$registered_key"
          return 0
        fi
        ;;
    esac
  done < "$REG"
  return 1
}

registry_id_conflict_for_assignment() {
  local id=$1 home=$2 target line registered_id registered_home registered_key
  [ -f "$REG" ] || return 1
  target=$(resolved_path "$home")
  while IFS= read -r line; do
    case "$line" in
      "- "*)
        registered_id=${line#- }
        registered_id=${registered_id%% *}
        [ "$registered_id" = "$id" ] || continue
        registered_home=$(printf '%s\n' "$line" | registry_home_for_line)
        [ -n "$registered_home" ] || continue
        registered_key=$(resolved_path "$registered_home")
        [ "$registered_key" = "$target" ] && continue
        printf '%s\n' "$registered_key"
        return 0
        ;;
    esac
  done < "$REG"
  return 1
}

validate_registry() {
  local tmp line id registered_home home_key duplicate_homes duplicate_ids overlaps
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-firstmates.XXXXXX")
  if [ -f "$REG" ]; then
    while IFS= read -r line; do
      case "$line" in
        "- "*)
          id=${line#- }
          id=${id%% *}
          registered_home=$(printf '%s\n' "$line" | registry_home_for_line)
          [ -n "$registered_home" ] || continue
          home_key=$(resolved_path "$registered_home")
          printf '%s\t%s\n' "$home_key" "$id" >> "$tmp"
          ;;
      esac
    done < "$REG"
  fi
  duplicate_homes=$(awk -F '\t' '
    {
      if (($1 in owner) && owner[$1] != $2) {
        print $1 ": " owner[$1] ", " $2
        bad=1
      } else {
        owner[$1]=$2
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$tmp" 2>/dev/null) || {
    rm -f "$tmp"
    printf 'error: duplicate secondmate home assignment:\n%s\n' "$duplicate_homes" >&2
    return 1
  }
  duplicate_ids=$(awk -F '\t' '
    {
      if ($2 in home) {
        print $2 ": " home[$2] ", " $1
        bad=1
      } else {
        home[$2]=$1
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$tmp" 2>/dev/null) || {
    rm -f "$tmp"
    printf 'error: duplicate secondmate id assignment:\n%s\n' "$duplicate_ids" >&2
    return 1
  }
  overlaps=$(awk -F '\t' '
    function ancestor(a, b) { return a != b && index(b, a "/") == 1 }
    {
      for (i = 1; i <= count; i++) {
        if (ancestor($1, path[i])) {
          print $1 " (" $2 ") contains " path[i] " (" id[i] ")"
          bad=1
        } else if (ancestor(path[i], $1)) {
          print path[i] " (" id[i] ") contains " $1 " (" $2 ")"
          bad=1
        }
      }
      count++
      path[count]=$1
      id[count]=$2
    }
    END { exit bad ? 1 : 0 }
  ' "$tmp" 2>/dev/null) || {
    rm -f "$tmp"
    printf 'error: overlapping secondmate home assignment:\n%s\n' "$overlaps" >&2
    return 1
  }
  rm -f "$tmp"
  return 0
}

join_projects() {
  local out="" project
  for project in "$@"; do
    out="${out}${out:+, }$project"
  done
  printf '%s\n' "$out"
}

abs_path_for_new() {
  canonical_path_for_check "$1"
}

resolved_path() {
  canonical_path_for_check "$1"
}

refuse_active_home_path() {
  local home=$1 abs_home abs_active_home abs_root
  abs_home=$(resolved_path "$home")
  abs_active_home=$(resolved_path "$FM_HOME")
  abs_root=$(resolved_path "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
}

validate_operational_dir() {
  local home=$1 name=$2 dir abs_home abs_dir abs_active_home abs_root
  dir="$home/$name"
  if [ -L "$dir" ] && [ ! -e "$dir" ]; then
    echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
    return 1
  fi
  abs_home=$(resolved_path "$home")
  abs_dir=$(resolved_path "$dir")
  abs_active_home=$(resolved_path "$FM_HOME")
  abs_root=$(resolved_path "$FM_ROOT")
  if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
    echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
    return 1
  fi
  if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
    echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
    return 1
  fi
  if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
    echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
    return 1
  fi
}

validate_operational_dirs() {
  local home=$1 name
  for name in data state config projects; do
    validate_operational_dir "$home" "$name" || return 1
  done
}

validate_seed_leaf_files() {
  local home=$1 label path abs_home abs_path
  abs_home=$(resolved_path "$home")
  for label in "data/projects.md" "data/charter.md" "$SUB_HOME_MARKER"; do
    path="$home/$label"
    if [ -L "$path" ]; then
      echo "error: secondmate leaf file must not be a symlink: $path" >&2
      return 1
    fi
    [ -e "$path" ] || continue
    abs_path=$(resolved_path "$path")
    case "$abs_path" in
      "$abs_home"/*) ;;
      *)
        echo "error: secondmate leaf file must resolve inside the secondmate home: $path" >&2
        return 1
        ;;
    esac
  done
}

validate_project_destination() {
  local home=$1 project=$2 dst projects_dir abs_home abs_projects abs_dst abs_active_home abs_root
  projects_dir="$home/projects"
  dst="$projects_dir/$project"
  abs_home=$(resolved_path "$home")
  abs_projects=$(resolved_path "$projects_dir")
  abs_dst=$(resolved_path "$dst")
  abs_active_home=$(resolved_path "$FM_HOME")
  abs_root=$(resolved_path "$FM_ROOT")
  if ! path_is_ancestor_of "$abs_home" "$abs_projects"; then
    echo "error: secondmate projects directory must resolve inside the secondmate home: $projects_dir" >&2
    return 1
  fi
  if ! path_is_ancestor_of "$abs_projects" "$abs_dst"; then
    echo "error: seeded project $project destination must resolve inside the secondmate projects directory: $dst" >&2
    return 1
  fi
  if [ "$abs_dst" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dst"; then
    echo "error: seeded project $project destination cannot be inside the active firstmate home: $dst" >&2
    return 1
  fi
  if [ "$abs_dst" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dst"; then
    echo "error: seeded project $project destination cannot be inside the firstmate repo: $dst" >&2
    return 1
  fi
  printf '%s\n' "$abs_dst"
}

normalize_origin_url() {
  local repo=$1 url=$2 prefix
  case "$url" in
    file://*|*://*)
      printf '%s\n' "$url"
      return
      ;;
    *:*)
      prefix=${url%%:*}
      case "$prefix" in
        */*) ;;
        *)
          printf '%s\n' "$url"
          return
          ;;
      esac
      ;;
  esac
  ( cd "$repo" && canonical_path_for_check "$url" )
}

source_origin_url() {
  local project=$1 mode=$2 src=$3 url
  url=$(git -C "$src" remote get-url origin 2>/dev/null || true)
  [ -n "$url" ] || { echo "error: project $project is $mode but has no origin remote" >&2; return 1; }
  normalize_origin_url "$src" "$url"
}

seeded_origin_url() {
  local project=$1 dst=$2 expected=$3 url
  url=$(git -C "$dst" remote get-url origin 2>/dev/null || true)
  [ -n "$url" ] || { echo "error: seeded project $project at $dst has no origin remote; expected $expected" >&2; return 1; }
  normalize_origin_url "$dst" "$url"
}

acquire_treehouse_home() {
  local id=$1 home
  # Durably lease a firstmate worktree from the pool. The lease persists with no
  # live process and is skipped by later get/prune, so the home survives restarts
  # until teardown or rollback returns it. treehouse prints only the worktree path
  # to stdout (banners go to stderr), so command substitution captures the path.
  home=$(cd "$FM_ROOT" && treehouse get --lease --lease-holder "$id") || {
    echo "error: treehouse get --lease failed to lease a firstmate home" >&2
    return 1
  }
  [ -n "$home" ] || { echo "error: treehouse get --lease did not report a firstmate home" >&2; return 1; }
  printf '%s\n' "$home"
}

ensure_home() {
  local id=$1 requested=$2 home
  if [ "$requested" = "-" ]; then
    home=$(acquire_treehouse_home "$id")
    verify_firstmate_home "$home"
    return
  fi

  home=$(abs_path_for_new "$requested")
  refuse_active_home_path "$home" || return 1
  if [ -e "$home" ]; then
    [ -d "$home" ] || { echo "error: $home exists and is not a directory" >&2; return 1; }
  else
    mkdir -p "$(dirname "$home")"
    git clone --quiet "$FM_ROOT" "$home"
  fi
  verify_firstmate_home "$home"
}

verify_firstmate_home() {
  local home=$1
  refuse_active_home_path "$home" || return 1
  [ -f "$home/AGENTS.md" ] || { echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2; return 1; }
  [ -d "$home/bin" ] || { echo "error: $home is not a firstmate home (missing bin/)" >&2; return 1; }
  validate_operational_dirs "$home" || return 1
  printf '%s\n' "$(cd "$home" && pwd -P)"
}

validate_home_assignment() {
  local id=$1 home=$2 marker_id id_conflict conflict conflict_type owner registered_home
  if [ -f "$home/$SUB_HOME_MARKER" ]; then
    marker_id=$(cat "$home/$SUB_HOME_MARKER" 2>/dev/null || true)
    if [ "$marker_id" != "$id" ]; then
      echo "error: secondmate home $home is already marked for ${marker_id:-unknown}" >&2
      return 1
    fi
  fi
  id_conflict=$(registry_id_conflict_for_assignment "$id" "$home" || true)
  if [ -n "$id_conflict" ]; then
    echo "error: secondmate id $id is already registered to home $id_conflict; retire it before assigning $home" >&2
    return 1
  fi
  conflict=$(registry_home_conflict_for_assignment "$id" "$home" || true)
  [ -n "$conflict" ] || return 0
  IFS=$'\t' read -r conflict_type owner registered_home <<EOF
$conflict
EOF
  if [ "$conflict_type" = exact ]; then
    echo "error: secondmate home $home is already registered to $owner" >&2
    return 1
  fi
  echo "error: secondmate home $home overlaps registered secondmate home $registered_home for $owner" >&2
  return 1
}

clone_project() {
  local project=$1 home=$2 src dst url dst_url mode
  src="$PROJECTS/$project"
  dst=$(validate_project_destination "$home" "$project") || return 1
  [ -d "$src" ] || { echo "error: project $project not found at $src" >&2; return 1; }
  git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: project $project is not a git repo" >&2; return 1; }
  read -r mode _ <<EOF
$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$FM_ROOT/bin/fm-project-mode.sh" "$project")
EOF
  if [ "$mode" = local-only ]; then
    echo "error: project $project is local-only; secondmate routes support only no-mistakes and direct-PR projects" >&2
    return 1
  fi
  if [ -e "$dst" ]; then
    [ -d "$dst" ] || { echo "error: seeded project $project exists at $dst but is not a directory" >&2; return 1; }
    git -C "$dst" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: seeded project $project at $dst is not a git repo" >&2; return 1; }
    url=$(source_origin_url "$project" "$mode" "$src") || return 1
    dst_url=$(seeded_origin_url "$project" "$dst" "$url") || return 1
    [ "$dst_url" = "$url" ] || {
      echo "error: seeded project $project at $dst has origin $dst_url; expected $url" >&2
      return 1
    }
    return 0
  fi
  url=$(source_origin_url "$project" "$mode" "$src") || return 1
  git clone --quiet "$url" "$dst"
}

validate_seed_project() {
  local project=$1 src mode url
  src="$PROJECTS/$project"
  [ -d "$src" ] || { echo "error: project $project not found at $src" >&2; return 1; }
  git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: project $project is not a git repo" >&2; return 1; }
  read -r mode _ <<EOF
$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$FM_ROOT/bin/fm-project-mode.sh" "$project")
EOF
  if [ "$mode" = local-only ]; then
    echo "error: project $project is local-only; secondmate routes support only no-mistakes and direct-PR projects" >&2
    return 1
  fi
  url=$(git -C "$src" remote get-url origin 2>/dev/null || true)
  [ -n "$url" ] || { echo "error: project $project is $mode but has no origin remote" >&2; return 1; }
}

SEED_ROLLBACK_ACTIVE=0
SEED_COMMITTED=0
SEED_HOME=
SEED_HOME_ACQUIRED=0
SEED_HOME_CREATED=0
SEED_HOME_BACKED_UP=0
SEED_BACKUP_DIR=
SEED_CREATED_PROJECTS_FILE=
SEED_PARENT_REG_EXISTED=0
SEED_PARENT_BRIEF=
SEED_PARENT_BRIEF_CREATED=0
SEED_PARENT_BRIEF_DIR_CREATED=0
SEED_SUB_REG_EXISTED=0
SEED_CHARTER_EXISTED=0
SEED_MARKER_EXISTED=0

restore_seed_file() {
  local existed=$1 backup=$2 path=$3
  if [ "$existed" = 1 ]; then
    mkdir -p "$(dirname "$path")"
    cp "$backup" "$path" 2>/dev/null || true
  else
    rm -f "$path" 2>/dev/null || true
  fi
}

seed_rollback_target() {
  local target=$1 label=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 1
  [ "$target" != "/" ] || { echo "REFUSED: unsafe $label rollback target $target" >&2; return 1; }
  abs_target=$(resolved_path "$target")
  abs_home=$(resolved_path "$FM_HOME")
  abs_root=$(resolved_path "$FM_ROOT")
  if [ "$abs_target" = "$abs_home" ]; then
    echo "REFUSED: unsafe $label rollback target $target is the active firstmate home" >&2
    return 1
  fi
  if [ "$abs_target" = "$abs_root" ]; then
    echo "REFUSED: unsafe $label rollback target $target is the firstmate repo" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_target" "$abs_home"; then
    echo "REFUSED: unsafe $label rollback target $target is an ancestor of the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_target" "$abs_root"; then
    echo "REFUSED: unsafe $label rollback target $target is an ancestor of the firstmate repo" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_target"; then
    echo "REFUSED: unsafe $label rollback target $target is inside the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe $label rollback target $target is inside the firstmate repo" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

seed_return_treehouse_home() {
  local home=$1 abs_home
  abs_home=$(seed_rollback_target "$home" "treehouse-acquired home") || return 0
  if ! command -v treehouse >/dev/null 2>&1; then
    echo "warning: failed to return treehouse-acquired home $abs_home during seed rollback; treehouse command not found" >&2
    return 0
  fi
  ( cd "$FM_ROOT" && treehouse return --force "$abs_home" >/dev/null ) || {
    echo "warning: failed to return treehouse-acquired home $abs_home during seed rollback; lease may still be held" >&2
    return 0
  }
}

seed_remove_created_home() {
  local home=$1 abs_home
  abs_home=$(seed_rollback_target "$home" "created home") || return 0
  rm -rf -- "$abs_home" 2>/dev/null || true
}

seed_project_rollback_target() {
  local target=$1 abs_target abs_home abs_projects
  abs_target=$(seed_rollback_target "$target" "created project") || return 1
  abs_home=$(resolved_path "$SEED_HOME")
  abs_projects=$(resolved_path "$SEED_HOME/projects")
  if ! path_is_ancestor_of "$abs_home" "$abs_projects"; then
    echo "REFUSED: unsafe created project rollback target $target has projects directory outside the secondmate home" >&2
    return 1
  fi
  if ! path_is_ancestor_of "$abs_projects" "$abs_target"; then
    echo "REFUSED: unsafe created project rollback target $target is outside the secondmate projects directory" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

seed_remove_created_project() {
  local project_path=$1 abs_project
  abs_project=$(seed_project_rollback_target "$project_path") || return 0
  rm -rf -- "$abs_project" 2>/dev/null || true
}

seed_project_was_created() {
  local project_path=$1
  [ -n "${SEED_CREATED_PROJECTS_FILE:-}" ] || return 1
  [ -f "$SEED_CREATED_PROJECTS_FILE" ] || return 1
  grep -Fx -- "$project_path" "$SEED_CREATED_PROJECTS_FILE" >/dev/null 2>&1
}

seed_rollback() {
  local project_path
  [ "${SEED_ROLLBACK_ACTIVE:-0}" = 1 ] || return 0
  [ "${SEED_COMMITTED:-0}" = 0 ] || return 0

  if [ -n "${SEED_PARENT_BRIEF:-}" ] && [ "$SEED_PARENT_BRIEF_CREATED" = 1 ]; then
    rm -f "$SEED_PARENT_BRIEF" 2>/dev/null || true
  fi
  if [ -n "${SEED_PARENT_BRIEF:-}" ] && [ "$SEED_PARENT_BRIEF_DIR_CREATED" = 1 ]; then
    rmdir "$(dirname "$SEED_PARENT_BRIEF")" 2>/dev/null || true
  fi

  if [ -n "${SEED_HOME:-}" ] && [ "$SEED_HOME" != "/" ]; then
    if [ "$SEED_HOME_ACQUIRED" = 1 ]; then
      seed_return_treehouse_home "$SEED_HOME"
    elif [ "$SEED_HOME_CREATED" = 1 ]; then
      seed_remove_created_home "$SEED_HOME"
    else
      if [ -n "${SEED_CREATED_PROJECTS_FILE:-}" ] && [ -f "$SEED_CREATED_PROJECTS_FILE" ]; then
        while IFS= read -r project_path; do
          [ -n "$project_path" ] || continue
          seed_remove_created_project "$project_path"
        done < "$SEED_CREATED_PROJECTS_FILE"
      fi
      if [ -n "${SEED_BACKUP_DIR:-}" ] && [ "${SEED_HOME_BACKED_UP:-0}" = 1 ]; then
        restore_seed_file "$SEED_MARKER_EXISTED" "$SEED_BACKUP_DIR/marker" "$SEED_HOME/$SUB_HOME_MARKER"
        restore_seed_file "$SEED_CHARTER_EXISTED" "$SEED_BACKUP_DIR/charter.md" "$SEED_HOME/data/charter.md"
        restore_seed_file "$SEED_SUB_REG_EXISTED" "$SEED_BACKUP_DIR/sub-projects.md" "$SEED_HOME/data/projects.md"
      fi
    fi
  fi

  if [ -n "${SEED_BACKUP_DIR:-}" ]; then
    restore_seed_file "$SEED_PARENT_REG_EXISTED" "$SEED_BACKUP_DIR/parent-secondmates.md" "$REG"
    rm -rf -- "$SEED_BACKUP_DIR" 2>/dev/null || true
  fi
}

registry_line_for_project() {
  local project=$1 line
  [ -f "$DATA/projects.md" ] || return 1
  line=$(awk -v n="$project" '$1=="-" && $2==n { print; exit }' "$DATA/projects.md")
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

project_mode_in_home() {
  local home=$1 project=$2 mode
  read -r mode _ <<EOF
$(FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_HOME="$home" "$FM_ROOT/bin/fm-project-mode.sh" "$project")
EOF
  printf '%s\n' "$mode"
}

sync_project_registry() {
  local home=$1 sub_reg tmp project line today names
  shift
  sub_reg="$home/data/projects.md"
  tmp="$sub_reg.tmp.$$"
  names=$(printf '%s\n' "$@" | awk '{ printf "%s%s", sep, $0; sep="\034" }')
  if [ -f "$sub_reg" ]; then
    awk -v names="$names" '
      BEGIN {
        split(names, a, "\034")
        for (i in a) selected[a[i]]=1
      }
      !($1=="-" && ($2 in selected)) { print }
    ' "$sub_reg" > "$tmp"
  else
    : > "$tmp"
  fi
  today=$(date +%F)
  for project in "$@"; do
    line=$(registry_line_for_project "$project" || true)
    if [ -z "$line" ]; then
      line="- $project - cloned project (added $today)"
    fi
    printf '%s\n' "$line" >> "$tmp"
  done
  mv "$tmp" "$sub_reg"
}

initialize_no_mistakes_project() {
  local home=$1 project=$2 created=$3 mode dst
  mode=$(project_mode_in_home "$home" "$project")
  [ "$mode" = no-mistakes ] || return 0
  dst=$(validate_project_destination "$home" "$project") || return 1
  if git -C "$dst" remote get-url no-mistakes >/dev/null 2>&1; then
    return 0
  fi
  if [ "$created" != 1 ]; then
    echo "error: seeded project $project at $dst is not initialized for no-mistakes; refusing to mutate preexisting clone" >&2
    return 1
  fi
  command -v no-mistakes >/dev/null 2>&1 || {
    echo "error: no-mistakes command not found; cannot initialize $project in $home" >&2
    return 1
  }
  ( cd "$dst" && no-mistakes init && no-mistakes doctor ) || {
    echo "error: failed to initialize no-mistakes for $project at $dst" >&2
    return 1
  }
}

write_registry() {
  local id=$1 home=$2 projects_csv=$3 brief=$4 scope summary tmp today
  mkdir -p "$DATA"
  scope=$(registry_scope_for_brief "$brief")
  summary=$(registry_summary_for_brief "$brief")
  today=$(date +%F)
  tmp="$REG.tmp.$$"
  if [ -f "$REG" ]; then
    grep -vE "^- $id( |$)" "$REG" > "$tmp" || true
  else
    : > "$tmp"
  fi
  printf -- '- %s - %s (home: %s; scope: %s; projects: %s; added %s)\n' "$id" "$summary" "$home" "$scope" "$projects_csv" "$today" >> "$tmp"
  mv "$tmp" "$REG"
}

seed_home() {
  local id=$1 requested_home=$2 requested_abs home projects_csv project project_dst charter_summary charter_scope
  shift 2
  [ $# -gt 0 ] || { echo "error: secondmate needs at least one project" >&2; return 1; }

  mkdir -p "$DATA"
  validate_registry
  for project in "$@"; do
    validate_seed_project "$project"
  done

  SEED_ROLLBACK_ACTIVE=1
  SEED_COMMITTED=0
  SEED_HOME=
  SEED_HOME_ACQUIRED=0
  SEED_HOME_CREATED=0
  SEED_HOME_ACQUIRED=0
  SEED_HOME_BACKED_UP=0
  SEED_BACKUP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-home-seed.XXXXXX")
  SEED_CREATED_PROJECTS_FILE="$SEED_BACKUP_DIR/created-projects"
  : > "$SEED_CREATED_PROJECTS_FILE"
  SEED_PARENT_REG_EXISTED=0
  SEED_PARENT_BRIEF="$DATA/$id/brief.md"
  SEED_PARENT_BRIEF_CREATED=0
  SEED_PARENT_BRIEF_DIR_CREATED=0
  SEED_SUB_REG_EXISTED=0
  SEED_CHARTER_EXISTED=0
  SEED_MARKER_EXISTED=0
  trap seed_rollback EXIT
  if [ -f "$REG" ]; then
    SEED_PARENT_REG_EXISTED=1
    cp "$REG" "$SEED_BACKUP_DIR/parent-secondmates.md"
  fi

  if [ "$requested_home" = "-" ]; then
    SEED_HOME_ACQUIRED=1
    home=$(acquire_treehouse_home "$id")
    SEED_HOME="$home"
    home=$(verify_firstmate_home "$home")
  else
    requested_abs=$(abs_path_for_new "$requested_home")
    refuse_active_home_path "$requested_abs" || return 1
    validate_home_assignment "$id" "$requested_abs" || return 1
    SEED_HOME="$requested_abs"
    [ -e "$requested_abs" ] || SEED_HOME_CREATED=1
    home=$(ensure_home "$id" "$requested_abs")
  fi
  SEED_HOME="$home"
  validate_registry_home_text "$home" || return 1
  validate_home_assignment "$id" "$home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  validate_operational_dirs "$home" || return 1
  validate_seed_leaf_files "$home" || return 1
  if [ -f "$home/data/projects.md" ]; then
    SEED_SUB_REG_EXISTED=1
    cp "$home/data/projects.md" "$SEED_BACKUP_DIR/sub-projects.md"
  fi
  if [ -f "$home/data/charter.md" ]; then
    SEED_CHARTER_EXISTED=1
    cp "$home/data/charter.md" "$SEED_BACKUP_DIR/charter.md"
  fi
  if [ -f "$home/$SUB_HOME_MARKER" ]; then
    SEED_MARKER_EXISTED=1
    cp "$home/$SUB_HOME_MARKER" "$SEED_BACKUP_DIR/marker"
  fi
  SEED_HOME_BACKED_UP=1

  if [ ! -f "$SEED_PARENT_BRIEF" ]; then
    [ -n "${FM_SECONDMATE_CHARTER:-}" ] || {
      echo "error: no filled secondmate charter brief at $SEED_PARENT_BRIEF; set FM_SECONDMATE_CHARTER or scaffold one and replace {TASK}" >&2
      return 1
    }
    [ -d "$DATA/$id" ] || SEED_PARENT_BRIEF_DIR_CREATED=1
    "$FM_ROOT/bin/fm-brief.sh" "$id" --secondmate "$@"
    SEED_PARENT_BRIEF_CREATED=1
  fi
  if grep -F '{TASK}' "$SEED_PARENT_BRIEF" >/dev/null 2>&1; then
    echo "error: secondmate charter brief at $SEED_PARENT_BRIEF still contains {TASK}; fill it before seeding" >&2
    return 1
  fi
  charter_summary=$(registry_summary_for_brief "$SEED_PARENT_BRIEF")
  [ -n "$charter_summary" ] || {
    echo "error: secondmate charter brief at $SEED_PARENT_BRIEF has an empty Charter section; fill it before seeding" >&2
    return 1
  }
  charter_scope=$(registry_scope_for_brief "$SEED_PARENT_BRIEF")
  [ -n "$charter_scope" ] || {
    echo "error: secondmate charter brief at $SEED_PARENT_BRIEF has an empty Routing scope section; fill it before seeding" >&2
    return 1
  }

  for project in "$@"; do
    project_dst=$(validate_project_destination "$home" "$project") || return 1
    [ -e "$project_dst" ] || printf '%s\n' "$project_dst" >> "$SEED_CREATED_PROJECTS_FILE"
    clone_project "$project" "$home"
  done
  sync_project_registry "$home" "$@"
  for project in "$@"; do
    project_dst=$(validate_project_destination "$home" "$project") || return 1
    if seed_project_was_created "$project_dst"; then
      initialize_no_mistakes_project "$home" "$project" 1
    else
      initialize_no_mistakes_project "$home" "$project" 0
    fi
  done

  cp "$SEED_PARENT_BRIEF" "$home/data/charter.md"

  projects_csv=$(join_projects "$@")
  printf '%s\n' "$id" > "$home/$SUB_HOME_MARKER"
  write_registry "$id" "$home" "$projects_csv" "$SEED_PARENT_BRIEF"
  validate_registry
  SEED_COMMITTED=1
  trap - EXIT
  rm -rf -- "$SEED_BACKUP_DIR"
  printf 'home=%s\n' "$home"
}

case "${1:-}" in
  validate)
    [ $# -eq 1 ] || { usage; exit 1; }
    validate_registry
    ;;
  -h|--help|'')
    usage
    exit 0
    ;;
  *)
    [ $# -ge 3 ] || { usage; exit 1; }
    seed_home "$@"
    ;;
esac
