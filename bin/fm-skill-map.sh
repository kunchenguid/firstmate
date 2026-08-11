#!/usr/bin/env bash
# Generate the private firstmate skill discovery map.
#
# Scans only skill frontmatter from:
#   - this firstmate repo's .agents/skills/
#   - every registered project clone's .claude/skills/ and .agents/skills/
#   - the Claude user skill directory, ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills
#
# The output is a flat, regenerated registry at data/skill-map.md by default.
# It is private operational state, not a committed artifact. The map is for
# discovery and for fm-skill-compose.sh name resolution; the skill folders stay
# in their canonical source locations.
#
# Registry line format:
#   - <skill-name> — <one-line-description> — <absolute-canonical-skill-folder>
#
# Usage: fm-skill-map.sh [--output <path>] [--stdout] [--quiet]
#   --output <path>  Write the map to this path instead of data/skill-map.md.
#   --stdout         Print to stdout instead of writing the map file.
#   --quiet          Suppress the summary line when writing succeeds.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
OUTPUT="$DATA/skill-map.md"
STDOUT=0
QUIET=0

usage() { sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//; $d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --output)
      shift
      [ $# -gt 0 ] || { printf 'error: --output requires a path\n' >&2; exit 2; }
      OUTPUT=$1
      ;;
    --stdout) STDOUT=1 ;;
    --quiet) QUIET=1 ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

trim() {
  # shellcheck disable=SC2001
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

strip_quotes() {
  local value=$1 first last len
  value=$(trim "$value")
  len=${#value}
  if [ "$len" -ge 2 ]; then
    first=${value:0:1}
    last=${value: -1}
    if { [ "$first" = '"' ] && [ "$last" = '"' ]; } || { [ "$first" = "'" ] && [ "$last" = "'" ]; }; then
      value=${value#?}
      value=${value%?}
    fi
  fi
  printf '%s' "$value"
}

collapse_ws() {
  printf '%s' "$1" | tr '\n\t' '  ' | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

sanitize_description() {
  local value
  value=$(collapse_ws "$1")
  value=${value// — / - }
  [ -n "$value" ] || value='(no description)'
  printf '%s' "$value"
}

extract_frontmatter() {  # <SKILL.md>; prints name<TAB>description
  local file=$1 line value name='' desc='' desc_block=0 first=1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" -eq 1 ]; then
      first=0
      [ "$line" = '---' ] || return 1
      continue
    fi
    [ "$line" = '---' ] && break
    case "$line" in
      name:*)
        value=${line#name:}
        name=$(strip_quotes "$value")
        desc_block=0
        ;;
      description:*)
        value=$(strip_quotes "${line#description:}")
        case "$value" in
          '>'|'>-'|'>+'|\||\|-|\|+)
            desc=
            desc_block=1
            ;;
          \>*|\|*)
            desc=
            desc_block=1
            ;;
          *)
            desc=$value
            desc_block=0
            ;;
        esac
        ;;
      ' '*|$'\t'*)
        if [ "$desc_block" = 1 ]; then
          value=$(strip_quotes "$line")
          if [ -n "$value" ]; then
            desc="${desc}${desc:+ }$value"
          fi
        fi
        ;;
      *)
        desc_block=0
        ;;
    esac
  done < "$file"
  name=$(collapse_ws "$name")
  desc=$(sanitize_description "$desc")
  [ -n "$name" ] || return 1
  printf '%s\t%s\n' "$name" "$desc"
}

canonical_dir() {  # <dir>
  (cd "$1" 2>/dev/null && pwd -P)
}

skill_repo_label() {  # <skill-dir> <fallback-group>
  local dir=$1 fallback=$2 top remote base
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$top" ]; then
    remote=$(git -C "$top" remote get-url origin 2>/dev/null || true)
    if [ -n "$remote" ]; then
      base=${remote##*/}
      base=${base%.git}
      [ -n "$base" ] && { printf '%s\n' "$base"; return 0; }
    fi
    basename "$top"
    return 0
  fi
  printf '%s\n' "$fallback"
}

add_skill_source() {  # <group> <skills-dir> <records-file> <seen-file>
  local group=$1 source_dir=$2 records=$3 seen=$4 skill_dir skill_real front name desc repo_label
  [ -d "$source_dir" ] || return 0
  for skill_dir in "$source_dir"/*; do
    [ -d "$skill_dir" ] || continue
    [ -f "$skill_dir/SKILL.md" ] || continue
    skill_real=$(canonical_dir "$skill_dir") || continue
    if grep -Fx -- "$skill_real" "$seen" >/dev/null 2>&1; then
      continue
    fi
    printf '%s\n' "$skill_real" >> "$seen"
    front=$(extract_frontmatter "$skill_real/SKILL.md" 2>/dev/null || true)
    [ -n "$front" ] || continue
    name=${front%%$'\t'*}
    desc=${front#*$'\t'}
    repo_label=$(skill_repo_label "$skill_real" "$group")
    printf '%s\t%s\t%s\t%s\n' "$repo_label" "$name" "$desc" "$skill_real" >> "$records"
  done
}

project_names() {
  [ -f "$DATA/projects.md" ] || return 0
  awk '
    $1 == "-" && $2 != "" { print $2; next }
    /^[^#[:space:]][^[:space:]]*[[:space:]]+\[/ { print $1; next }
  ' "$DATA/projects.md" | sort -u
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-skill-map.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
RECORDS="$TMP/records.tsv"
SEEN="$TMP/seen-paths"
: > "$RECORDS"
: > "$SEEN"

add_skill_source firstmate "$FM_ROOT/.agents/skills" "$RECORDS" "$SEEN"

while IFS= read -r project; do
  [ -n "$project" ] || continue
  case "$project" in */*|.*|'') continue ;; esac
  add_skill_source "projects/$project" "$PROJECTS/$project/.claude/skills" "$RECORDS" "$SEEN"
  add_skill_source "projects/$project" "$PROJECTS/$project/.agents/skills" "$RECORDS" "$SEEN"
done <<EOF
$(project_names)
EOF

if [ -n "${HOME:-}" ]; then
  CLAUDE_USER_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  add_skill_source user "$CLAUDE_USER_ROOT/skills" "$RECORDS" "$SEEN"
fi

MAP_TMP="$TMP/skill-map.md"
{
  printf '# Skill map\n\n'
  printf '%s\n' "Generated by \`bin/fm-skill-map.sh\`."
  printf '%s\n' 'Do not hand-edit; rerun the generator.'
  printf '%s\n' "Format: \`- <name> — <description> — <absolute canonical skill folder>\`."
  printf '%s\n' 'The listed folder is the one canonical copy; composition symlinks point there.'
  if [ ! -s "$RECORDS" ]; then
    printf '\n(no skills found)\n'
  else
    sort -f -t $'\t' -k1,1 -k2,2 "$RECORDS" | awk -F '\t' '
      BEGIN { group = "" }
      $1 != group {
        group = $1
        printf "\n## %s\n", group
      }
      {
        printf "- %s — %s — %s\n", $2, $3, $4
      }
    '
  fi
} > "$MAP_TMP"

if [ "$STDOUT" -eq 1 ]; then
  cat "$MAP_TMP"
else
  mkdir -p "$(dirname "$OUTPUT")"
  if [ -f "$OUTPUT" ] && cmp -s "$MAP_TMP" "$OUTPUT"; then
    :
  else
    cp "$MAP_TMP" "$OUTPUT.tmp.$$"
    mv -f "$OUTPUT.tmp.$$" "$OUTPUT"
  fi
  if [ "$QUIET" -eq 0 ]; then
    count=$(grep -c '^- ' "$MAP_TMP" 2>/dev/null || printf '0')
    printf 'wrote %s (%s skill(s))\n' "$OUTPUT" "$count"
  fi
fi
