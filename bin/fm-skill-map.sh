#!/usr/bin/env bash
# Generate the private firstmate skill discovery map.
#
# Scans only skill frontmatter from:
#   - this firstmate repo's .agents/skills/
#   - every registered project clone's .claude/skills/ and .agents/skills/
#   - the Claude user skill directory, ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills
#
# A SKILL.md is read once, only as far as MAX_FRONTMATTER_BYTES (plus the one
# byte that distinguishes a truncated file from one ending exactly at the bound). A skill is skipped,
# with a named SKILL_MAP: line on stderr and a final exit status of 3, when its
# folder or SKILL.md cannot be read, its frontmatter is never closed within that
# bound, it carries no usable name, or its name contains the map's own field
# separator. The map itself is still written, so one bad skill degrades to a
# reported gap, never a silent one and never an unbounded read of the skill body.
#
# A closing delimiter is only trusted on a newline-terminated line when the bound
# actually truncated the file, because truncation can cut a longer run of dashes
# down to exactly three and would otherwise manufacture the close this requires.
# A delimiter at a real end of file needs no trailing newline.
#
# Neither emitted field may contain the em dash that forms the record separator:
# a description has every one replaced, and a name carrying one is refused. A
# name is refused rather than rewritten because a rewritten name would resolve
# to the wrong skill, and a legitimate skill name never contains an em dash.
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
SKIPPED=0
# The em dash that forms the record separator ' — '. Neither field may contain one,
# at any position: at a field boundary the renderer would join it with the
# surrounding spaces into a separator the reader then splits on.
MAP_SEPARATOR_DASH='—'
# Frontmatter is a handful of short lines; anything past this is skill body.
MAX_FRONTMATTER_BYTES=65536

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
  # Replace every em dash, not just a fully spaced separator: a trailing or
  # doubled one would re-form the separator once the record is rendered.
  value=${value//"$MAP_SEPARATOR_DASH"/-}
  value=$(collapse_ws "$value")
  [ -n "$value" ] || value='(no description)'
  printf '%s' "$value"
}

extract_frontmatter() {  # <SKILL.md>; prints name<TAB>description
  local file=$1 line delim value name='' desc='' desc_block=0 first=1 closed=0 unterminated=0
  local prefix bytes truncated=0
  # Read the bounded prefix exactly once. Reading the size separately let a file
  # that grew between the two reads be parsed as if it had not been truncated.
  prefix="$TMP/frontmatter.$$"
  head -c "$((MAX_FRONTMATTER_BYTES + 1))" "$file" > "$prefix" 2>/dev/null || return 1
  bytes=$(wc -c < "$prefix" | tr -d ' ')
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le "$MAX_FRONTMATTER_BYTES" ] || truncated=1
  while IFS= read -r line || { [ -n "$line" ] && unterminated=1; }; do
    line=${line%$'\r'}
    # Compare delimiters against a trailing-whitespace-trimmed copy; the raw line
    # still drives the block-scalar continuation case, which keys on indentation.
    delim=${line%%[[:space:]]}
    while [ "$delim" != "${delim%[[:space:]]}" ]; do delim=${delim%[[:space:]]}; done
    if [ "$first" -eq 1 ]; then
      first=0
      [ "$delim" = '---' ] || return 1
      continue
    fi
    if [ "$delim" = '---' ]; then
      # A delimiter at a real end of file is genuine; only distrust an
      # unterminated final line when the bound actually cut the file short.
      if [ "$unterminated" -eq 0 ] || [ "$truncated" -eq 0 ]; then
        closed=1
      fi
      break
    fi
    case "$line" in
      name:*)
        value=$(strip_quotes "${line#name:}")
        case "$value" in
          # A multi-line name is meaningless here and the old code emitted the
          # block indicator itself as the skill name, so refuse it instead.
          '>'|'>-'|'>+'|\||\|-|\|+|\>*|\|*) return 1 ;;
        esac
        name=$value
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
  done < "$prefix"
  rm -f "$prefix"
  [ "$closed" -eq 1 ] || return 1
  name=$(collapse_ws "$name")
  desc=$(sanitize_description "$desc")
  [ -n "$name" ] || return 1
  # Any em dash in the name can become a separator once the record is rendered,
  # which would shadow or redirect another skill when the map is read back.
  case "$name" in *"$MAP_SEPARATOR_DASH"*) return 1 ;; esac
  printf '%s\t%s\n' "$name" "$desc"
}

canonical_dir() {  # <dir>
  (cd "$1" 2>/dev/null && pwd -P)
}

add_skill_source() {  # <group> <skills-dir> <records-file> <seen-file>
  local group=$1 source_dir=$2 records=$3 seen=$4 skill_dir skill_real front name desc
  [ -d "$source_dir" ] || return 0
  # An unreadable source directory yields no glob matches at all, so without this
  # every skill inside it would vanish with nothing reported.
  if [ ! -r "$source_dir" ] || [ ! -x "$source_dir" ]; then
    printf 'SKILL_MAP: skipped unreadable skill source directory: %q\n' "$source_dir" >&2
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  for skill_dir in "$source_dir"/*; do
    if [ ! -d "$skill_dir" ] && [ -L "$skill_dir" ]; then
      printf 'SKILL_MAP: skipped skill folder symlink that does not resolve: %q\n' \
        "$skill_dir" >&2
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    [ -d "$skill_dir" ] || continue
    # A folder with no SKILL.md at all is not a skill, so it is not reported. A
    # folder whose SKILL.md exists but is not a readable regular file IS a skill
    # this scan cannot read, so it joins the reported-skip path below rather than
    # disappearing. The regular-file test also keeps the parser off a FIFO, which
    # would otherwise block the whole refresh waiting for a writer.
    if [ ! -x "$skill_dir" ] || ! skill_real=$(canonical_dir "$skill_dir"); then
      printf 'SKILL_MAP: skipped unreadable skill folder: %q\n' "$skill_dir" >&2
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    # The path is emitted raw into a tab-separated record and is also the dedupe
    # key, so a tab or a newline in a folder name must be refused before it reaches
    # either. A newline is the dangerous one: grep -F reads it as a pattern
    # separator, so such a path would match, and seed, unrelated seen entries and
    # silently erase a real skill that shares its pre-newline prefix. An em dash is
    # NOT refused here: the reader takes everything after the second separator, so
    # one inside the path stays part of the path.
    case "$skill_real" in
      *$'\t'*|*$'\n'*)
        # Quote it: printing the raw path would render its own newline and make
        # the line read as the innocent prefix plus a stray line of its own.
        printf 'SKILL_MAP: skipped skill folder whose path breaks the map record: %q\n' \
          "$skill_real" >&2
        SKIPPED=$((SKIPPED + 1))
        continue
        ;;
    esac
    [ -e "$skill_real/SKILL.md" ] || [ -L "$skill_real/SKILL.md" ] || continue
    if grep -Fx -- "$skill_real" "$seen" >/dev/null 2>&1; then
      continue
    fi
    printf '%s\n' "$skill_real" >> "$seen"
    if [ ! -f "$skill_real/SKILL.md" ] \
      || ! front=$(extract_frontmatter "$skill_real/SKILL.md" 2>/dev/null) \
      || [ -z "$front" ]; then
      printf 'SKILL_MAP: skipped unreadable, unclosed, or unusably named skill frontmatter: %q\n' \
        "$skill_real/SKILL.md" >&2
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    name=${front%%$'\t'*}
    desc=${front#*$'\t'}
    printf '%s\t%s\t%s\t%s\n' "$group" "$name" "$desc" "$skill_real" >> "$records"
  done
}

project_names() {
  [ -f "$DATA/projects.md" ] || return 0
  awk '
    # A registered name may contain spaces; it ends at " [" or " - " (fm-project-mode.sh).
    $1 == "-" && $2 != "" {
      name = $0
      sub(/^[[:space:]]*-[[:space:]]+/, "", name)
      i = index(name, " ["); if (i) name = substr(name, 1, i - 1)
      i = index(name, " - "); if (i) name = substr(name, 1, i - 1)
      sub(/[[:space:]]+$/, "", name)
      if (name != "") print name
      next
    }
    /^[^#[:space:]][^[:space:]]*[[:space:]]+\[/ { print $1; next }
  ' "$DATA/projects.md" | sort -u
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-skill-map.XXXXXX") || {
  printf 'SKILL_MAP: cannot create a temporary directory for the refresh\n' >&2
  exit 1
}
trap 'rm -rf "$TMP"' EXIT INT TERM
RECORDS="$TMP/records.tsv"
SEEN="$TMP/seen-paths"
: > "$RECORDS"
: > "$SEEN"

add_skill_source firstmate "$FM_ROOT/.agents/skills" "$RECORDS" "$SEEN"

while IFS= read -r project; do
  [ -n "$project" ] || continue
  case "$project" in */*|''|.|..) continue ;; esac
  add_skill_source "projects/$project" "$PROJECTS/$project/.claude/skills" "$RECORDS" "$SEEN"
  add_skill_source "projects/$project" "$PROJECTS/$project/.agents/skills" "$RECORDS" "$SEEN"
done <<EOF
$(project_names)
EOF

if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  add_skill_source user "$CLAUDE_CONFIG_DIR/skills" "$RECORDS" "$SEEN"
elif [ -n "${HOME:-}" ]; then
  add_skill_source user "$HOME/.claude/skills" "$RECORDS" "$SEEN"
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
    count=$(grep -c '^- ' "$MAP_TMP" 2>/dev/null) || count=0
    printf 'wrote %s (%s skill(s))\n' "$OUTPUT" "$count"
  fi
fi

if [ "$SKIPPED" -gt 0 ]; then
  printf 'SKILL_MAP: %s skill(s) skipped; the map above omits them\n' "$SKIPPED" >&2
  exit 3
fi
