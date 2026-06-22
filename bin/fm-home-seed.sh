#!/usr/bin/env bash
# Provision and route persistent sub-firstmate homes.
#
# Usage:
#   fm-home-seed.sh <id> <home|-> <owned-project>...
#       Provision <home> as an isolated firstmate home. If <home> is "-", acquire
#       a fresh firstmate worktree via treehouse get. Owned projects are cloned
#       from this home into the sub-home's projects/ directory, the charter brief
#       is copied to data/charter.md, and data/firstmates.md is updated.
#   fm-home-seed.sh owner <project>
#       Print the registered sub-firstmate id that owns <project>.
#   fm-home-seed.sh validate
#       Refuse duplicate project ownership in data/firstmates.md.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
REG="$DATA/firstmates.md"

usage() {
  echo "usage: fm-home-seed.sh <id> <home|-> <owned-project>..." >&2
  echo "       fm-home-seed.sh owner <project>" >&2
  echo "       fm-home-seed.sh validate" >&2
}

trim() {
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

registry_owns_for_line() {
  sed -n 's/.*owns: \([^;)]*\).*/\1/p'
}

owner_for_project() {
  local project=$1 line id owns item old_ifs
  [ -f "$REG" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "- "*)
        id=${line#- }
        id=${id%% *}
        owns=$(printf '%s\n' "$line" | registry_owns_for_line)
        [ -n "$owns" ] || continue
        old_ifs=$IFS
        IFS=,
        for item in $owns; do
          item=$(printf '%s' "$item" | trim)
          if [ "$item" = "$project" ]; then
            IFS=$old_ifs
            printf '%s\n' "$id"
            return 0
          fi
        done
        IFS=$old_ifs
        ;;
    esac
  done < "$REG"
  return 1
}

validate_registry() {
  local tmp line id owns item duplicates old_ifs
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-firstmates.XXXXXX")
  if [ -f "$REG" ]; then
    while IFS= read -r line; do
      case "$line" in
        "- "*)
          id=${line#- }
          id=${id%% *}
          owns=$(printf '%s\n' "$line" | registry_owns_for_line)
          [ -n "$owns" ] || continue
          old_ifs=$IFS
          IFS=,
          for item in $owns; do
            item=$(printf '%s' "$item" | trim)
            [ -n "$item" ] || continue
            printf '%s\t%s\n' "$item" "$id" >> "$tmp"
          done
          IFS=$old_ifs
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
    printf 'error: duplicate sub-firstmate ownership:\n%s\n' "$duplicates" >&2
    return 1
  }
  rm -f "$tmp"
  return 0
}

join_owned() {
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
  parent=$(cd "$parent" && pwd)
  printf '%s/%s\n' "$parent" "$base"
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
    acquire_treehouse_home
    return
  fi

  home=$(abs_path_for_new "$requested")
  if [ -e "$home" ]; then
    [ -d "$home" ] || { echo "error: $home exists and is not a directory" >&2; return 1; }
  else
    git clone --quiet "$FM_ROOT" "$home"
  fi
  [ -f "$home/AGENTS.md" ] || { echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2; return 1; }
  [ -d "$home/bin" ] || { echo "error: $home is not a firstmate home (missing bin/)" >&2; return 1; }
  printf '%s\n' "$(cd "$home" && pwd)"
}

clone_project() {
  local project=$1 home=$2 src dst url
  src="$PROJECTS/$project"
  dst="$home/projects/$project"
  [ -d "$src" ] || { echo "error: owned project $project not found at $src" >&2; return 1; }
  git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: owned project $project is not a git repo" >&2; return 1; }
  [ -e "$dst" ] && return 0
  url=$(git -C "$src" remote get-url origin 2>/dev/null || true)
  if [ -n "$url" ]; then
    git clone --quiet "$url" "$dst"
  else
    git clone --quiet "$src" "$dst"
  fi
}

write_registry() {
  local id=$1 home=$2 owned_csv=$3 charter tmp today
  mkdir -p "$DATA"
  charter=${FM_FIRSTMATE_CHARTER:-"sub-firstmate for $owned_csv"}
  today=$(date +%F)
  tmp="$REG.tmp.$$"
  if [ -f "$REG" ]; then
    grep -vE "^- $id( |$)" "$REG" > "$tmp" || true
  else
    : > "$tmp"
  fi
  printf -- '- %s - %s (home: %s; owns: %s; added %s)\n' "$id" "$charter" "$home" "$owned_csv" "$today" >> "$tmp"
  mv "$tmp" "$REG"
}

seed_home() {
  local id=$1 requested_home=$2 home owned_csv project owner
  shift 2
  [ $# -gt 0 ] || { echo "error: sub-firstmate needs at least one owned project" >&2; return 1; }

  mkdir -p "$DATA"
  validate_registry
  for project in "$@"; do
    owner=$(owner_for_project "$project" || true)
    if [ -n "$owner" ] && [ "$owner" != "$id" ]; then
      echo "error: project $project is already owned by sub-firstmate $owner" >&2
      return 1
    fi
  done

  home=$(ensure_home "$requested_home")
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  for project in "$@"; do
    clone_project "$project" "$home"
  done

  if [ ! -f "$DATA/$id/brief.md" ]; then
    "$FM_ROOT/bin/fm-brief.sh" "$id" --firstmate "$@"
  fi
  cp "$DATA/$id/brief.md" "$home/data/charter.md"

  owned_csv=$(join_owned "$@")
  write_registry "$id" "$home" "$owned_csv"
  validate_registry
  printf 'home=%s\n' "$home"
}

case "${1:-}" in
  owner)
    [ $# -eq 2 ] || { usage; exit 1; }
    owner_for_project "$2"
    ;;
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
