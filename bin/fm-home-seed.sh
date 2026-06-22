#!/usr/bin/env bash
# Provision and route persistent sub-firstmate homes.
#
# Usage:
#   fm-home-seed.sh <id> <home|-> <project>...
#       Provision <home> as an isolated firstmate home. If <home> is "-", acquire
#       a fresh firstmate worktree via treehouse get. Projects are cloned
#       from this home into the sub-home's projects/ directory.
#       That project list is non-exclusive provisioning data. The charter brief
#       is copied to data/charter.md, no-mistakes projects are initialized,
#       a .fm-sub-firstmate-home marker is written, and data/firstmates.md is updated.
#       Set FM_FIRSTMATE_SCOPE='<scope>' to write the registry routing scope.
#       FM_FIRSTMATE_CHARTER can provide the registry summary and fallback scope.
#   fm-home-seed.sh validate
#       Refuse duplicate home assignments in data/firstmates.md.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
REG="$DATA/firstmates.md"
SUB_HOME_MARKER=".fm-sub-firstmate-home"

usage() {
  echo "usage: fm-home-seed.sh <id> <home|-> <project>..." >&2
  echo "       fm-home-seed.sh validate" >&2
}

registry_home_for_line() {
  sed -n 's/.*home: \([^;)]*\).*/\1/p'
}

path_key() {
  local path=$1 parent base
  if [ -d "$path" ]; then
    cd "$path" && pwd -P
    return
  fi
  parent=$(dirname "$path")
  base=$(basename "$path")
  if [ -d "$parent" ]; then
    cd "$parent" && printf '%s/%s\n' "$(pwd -P)" "$base"
    return
  fi
  printf '%s\n' "$path"
}

owner_for_home() {
  local home=$1 target line id registered_home registered_key
  [ -f "$REG" ] || return 1
  target=$(path_key "$home")
  while IFS= read -r line; do
    case "$line" in
      "- "*)
        id=${line#- }
        id=${id%% *}
        registered_home=$(printf '%s\n' "$line" | registry_home_for_line)
        [ -n "$registered_home" ] || continue
        registered_key=$(path_key "$registered_home")
        if [ "$registered_key" = "$target" ]; then
          printf '%s\n' "$id"
          return 0
        fi
        ;;
    esac
  done < "$REG"
  return 1
}

validate_registry() {
  local tmp line id registered_home home_key duplicates
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-firstmates.XXXXXX")
  if [ -f "$REG" ]; then
    while IFS= read -r line; do
      case "$line" in
        "- "*)
          id=${line#- }
          id=${id%% *}
          registered_home=$(printf '%s\n' "$line" | registry_home_for_line)
          [ -n "$registered_home" ] || continue
          home_key=$(path_key "$registered_home")
          printf '%s\t%s\n' "$home_key" "$id" >> "$tmp"
          ;;
      esac
    done < "$REG"
  fi
  duplicates=$(awk -F '\t' '
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
    printf 'error: duplicate sub-firstmate home assignment:\n%s\n' "$duplicates" >&2
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
  local path=$1 parent base
  parent=$(dirname "$path")
  base=$(basename "$path")
  mkdir -p "$parent"
  parent=$(cd "$parent" && pwd -P)
  printf '%s/%s\n' "$parent" "$base"
}

resolved_path() {
  local path=$1 parent base
  if [ -d "$path" ]; then
    cd "$path" && pwd -P
    return
  fi
  parent=$(dirname "$path")
  base=$(basename "$path")
  parent=$(cd "$parent" && pwd -P)
  printf '%s/%s\n' "$parent" "$base"
}

refuse_active_home_path() {
  local home=$1 abs_home abs_active_home abs_root
  abs_home=$(resolved_path "$home")
  abs_active_home=$(resolved_path "$FM_HOME")
  abs_root=$(resolved_path "$FM_ROOT")
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: sub-firstmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: sub-firstmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
}

acquire_treehouse_home() {
  local tmp runner home
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-home-path.XXXXXX")
  runner=$(mktemp "${TMPDIR:-/tmp}/fm-home-shell.XXXXXX")
  cat > "$runner" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PWD" > "$FM_HOME_SEED_PATH_FILE"
exit 0
SH
  chmod +x "$runner"
  (cd "$FM_ROOT" && FM_HOME_SEED_PATH_FILE="$tmp" SHELL="$runner" treehouse get >/dev/null)
  home=$(cat "$tmp" 2>/dev/null || true)
  rm -f "$tmp" "$runner"
  [ -n "$home" ] || { echo "error: treehouse get did not report a firstmate home" >&2; return 1; }
  printf '%s\n' "$home"
}

ensure_home() {
  local requested=$1 home
  if [ "$requested" = "-" ]; then
    home=$(acquire_treehouse_home)
    refuse_active_home_path "$home" || return 1
    printf '%s\n' "$home"
    return
  fi

  home=$(abs_path_for_new "$requested")
  refuse_active_home_path "$home" || return 1
  if [ -e "$home" ]; then
    [ -d "$home" ] || { echo "error: $home exists and is not a directory" >&2; return 1; }
  else
    git clone --quiet "$FM_ROOT" "$home"
  fi
  [ -f "$home/AGENTS.md" ] || { echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2; return 1; }
  [ -d "$home/bin" ] || { echo "error: $home is not a firstmate home (missing bin/)" >&2; return 1; }
  printf '%s\n' "$(cd "$home" && pwd -P)"
}

validate_home_assignment() {
  local id=$1 home=$2 marker_id owner
  if [ -f "$home/$SUB_HOME_MARKER" ]; then
    marker_id=$(cat "$home/$SUB_HOME_MARKER" 2>/dev/null || true)
    if [ "$marker_id" != "$id" ]; then
      echo "error: sub-firstmate home $home is already marked for ${marker_id:-unknown}" >&2
      return 1
    fi
  fi
  owner=$(owner_for_home "$home" || true)
  if [ -n "$owner" ] && [ "$owner" != "$id" ]; then
    echo "error: sub-firstmate home $home is already registered to $owner" >&2
    return 1
  fi
}

clone_project() {
  local project=$1 home=$2 src dst url dst_url mode
  src="$PROJECTS/$project"
  dst="$home/projects/$project"
  [ -d "$src" ] || { echo "error: project $project not found at $src" >&2; return 1; }
  git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: project $project is not a git repo" >&2; return 1; }
  read -r mode _ <<EOF
$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$FM_ROOT/bin/fm-project-mode.sh" "$project")
EOF
  if [ "$mode" = local-only ]; then
    echo "error: project $project is local-only; sub-firstmate routes support only no-mistakes and direct-PR projects" >&2
    return 1
  fi
  if [ -e "$dst" ]; then
    [ -d "$dst" ] || { echo "error: seeded project $project exists at $dst but is not a directory" >&2; return 1; }
    git -C "$dst" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: seeded project $project at $dst is not a git repo" >&2; return 1; }
    url=$(git -C "$src" remote get-url origin 2>/dev/null || true)
    [ -n "$url" ] || { echo "error: project $project is $mode but has no origin remote" >&2; return 1; }
    dst_url=$(git -C "$dst" remote get-url origin 2>/dev/null || true)
    [ -n "$dst_url" ] || { echo "error: seeded project $project at $dst has no origin remote; expected $url" >&2; return 1; }
    [ "$dst_url" = "$url" ] || {
      echo "error: seeded project $project at $dst has origin $dst_url; expected $url" >&2
      return 1
    }
    return 0
  fi
  url=$(git -C "$src" remote get-url origin 2>/dev/null || true)
  [ -n "$url" ] || { echo "error: project $project is $mode but has no origin remote" >&2; return 1; }
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
    echo "error: project $project is local-only; sub-firstmate routes support only no-mistakes and direct-PR projects" >&2
    return 1
  fi
  url=$(git -C "$src" remote get-url origin 2>/dev/null || true)
  [ -n "$url" ] || { echo "error: project $project is $mode but has no origin remote" >&2; return 1; }
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
  local home=$1 project=$2 mode dst
  mode=$(project_mode_in_home "$home" "$project")
  [ "$mode" = no-mistakes ] || return 0
  command -v no-mistakes >/dev/null 2>&1 || {
    echo "error: no-mistakes command not found; cannot initialize $project in $home" >&2
    return 1
  }
  dst="$home/projects/$project"
  ( cd "$dst" && no-mistakes init && no-mistakes doctor ) || {
    echo "error: failed to initialize no-mistakes for $project at $dst" >&2
    return 1
  }
}

write_registry() {
  local id=$1 home=$2 projects_csv=$3 scope summary tmp today
  mkdir -p "$DATA"
  scope=${FM_FIRSTMATE_SCOPE:-${FM_FIRSTMATE_CHARTER:-"sub-firstmate for $projects_csv"}}
  summary=${FM_FIRSTMATE_CHARTER:-$scope}
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
  local id=$1 requested_home=$2 home projects_csv project
  shift 2
  [ $# -gt 0 ] || { echo "error: sub-firstmate needs at least one project" >&2; return 1; }

  mkdir -p "$DATA"
  validate_registry
  for project in "$@"; do
    validate_seed_project "$project"
  done

  home=$(ensure_home "$requested_home")
  validate_home_assignment "$id" "$home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/$SUB_HOME_MARKER"
  for project in "$@"; do
    clone_project "$project" "$home"
  done
  sync_project_registry "$home" "$@"
  for project in "$@"; do
    initialize_no_mistakes_project "$home" "$project"
  done

  if [ ! -f "$DATA/$id/brief.md" ]; then
    "$FM_ROOT/bin/fm-brief.sh" "$id" --firstmate "$@"
  fi
  cp "$DATA/$id/brief.md" "$home/data/charter.md"

  projects_csv=$(join_projects "$@")
  write_registry "$id" "$home" "$projects_csv"
  validate_registry
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
