#!/usr/bin/env bash
# Resolve one named skill inside one already-resolved project.
#
# Usage:
#   fm-project-skill-resolve.sh <project-root> <skill-name>
#   fm-project-skill-resolve.sh -- <project-root> <skill-name>
#   fm-project-skill-resolve.sh -h | --help
#
# Search roots are direct children of <project-root>/.agents/skills,
# <project-root>/.codex/skills, and <project-root>/skills when that directory
# contains project skills.
# Hidden directories are searched normally.
#
# A candidate matches when its directory basename normalized to lowercase
# ASCII hyphen form equals the normalized query, or when its SKILL.md front
# matter has a name value exactly equal to the original query.
# Normalization lowercases ASCII, replaces each non-alphanumeric run with one
# hyphen, and trims leading or trailing hyphens.
# Partial matches are never accepted.
#
# All local roots have equal rank.
# One unique local match succeeds, duplicate evidence for the same file is
# deduplicated, and multiple matching files are ambiguous.
# Global and plugin catalogs are outside this resolver; its caller gives a
# unique local match precedence before consulting them.
#
# The project and every returned file are canonicalized.
# Symlinked search roots and matching symlink candidates are unsafe and stop
# resolution rather than allowing discovery outside the project.
#
# Success prints the canonical absolute SKILL.md path and nothing else.
# Diagnostics go to stderr.
# Exit codes: 0 resolved, 1 absent, 2 invalid input, 3 ambiguous, 4 unsafe path.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

diagnose() {
  printf 'fm-project-skill-resolve: %s\n' "$*" >&2
}

normalize_slug() {
  LC_ALL=C printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

frontmatter_name() {
  awk '
    NR == 1 {
      sub(/\r$/, "")
      if ($0 != "---") exit
      inside = 1
      next
    }
    inside {
      sub(/\r$/, "")
      if ($0 == "---") exit
      if ($0 ~ /^[[:space:]]*name[[:space:]]*:/) {
        sub(/^[[:space:]]*name[[:space:]]*:[[:space:]]*/, "")
        sub(/[[:space:]]+$/, "")
        if (($0 ~ /^".*"$/) || ($0 ~ /^\047.*\047$/)) {
          print substr($0, 2, length($0) - 2)
        } else {
          print
        }
        exit
      }
    }
  ' "$1"
}

inside_project() {
  case "$1" in
    "$PROJECT"/*) return 0 ;;
    *) return 1 ;;
  esac
}

append_match() {
  local existing
  for existing in "${MATCHES[@]-}"; do
    [ "$existing" = "$1" ] && return 0
  done
  MATCHES+=("$1")
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --)
    shift
    ;;
esac

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 2
fi

PROJECT_INPUT=$1
QUERY=$2

if [ -z "$QUERY" ]; then
  diagnose "invalid empty skill name"
  exit 2
fi

PROJECT=$(realpath -e -- "$PROJECT_INPUT" 2>/dev/null) || {
  diagnose "invalid project root: $PROJECT_INPUT"
  exit 2
}
if [ ! -d "$PROJECT" ]; then
  diagnose "project root is not a directory: $PROJECT_INPUT"
  exit 2
fi

QUERY_SLUG=$(normalize_slug "$QUERY")
if [ -z "$QUERY_SLUG" ]; then
  diagnose "skill name has no normalizable slug: $QUERY"
  exit 2
fi

MATCHES=()
for relative_root in .agents/skills .codex/skills skills; do
  search_root="$PROJECT/$relative_root"
  if [ -L "$search_root" ]; then
    diagnose "unsafe symlinked search root: $search_root"
    exit 4
  fi
  [ -d "$search_root" ] || continue

  while IFS= read -r -d '' entry; do
    entry_slug=$(normalize_slug "$(basename "$entry")")
    [ "$entry_slug" = "$QUERY_SLUG" ] || continue
    diagnose "unsafe matching symlink candidate: $entry"
    exit 4
  done < <(find -P "$search_root" -mindepth 1 -maxdepth 1 -type l -print0)

  while IFS= read -r -d '' skill_dir; do
    candidate="$skill_dir/SKILL.md"
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    dir_slug=$(normalize_slug "$(basename "$skill_dir")")

    if [ -L "$candidate" ]; then
      if [ "$dir_slug" = "$QUERY_SLUG" ]; then
        diagnose "unsafe matching symlink candidate: $candidate"
        exit 4
      fi
      continue
    fi
    [ -f "$candidate" ] || continue

    canonical=$(realpath -e -- "$candidate" 2>/dev/null) || {
      diagnose "unsafe unreadable candidate: $candidate"
      exit 4
    }
    inside_project "$canonical" || {
      diagnose "unsafe candidate outside project: $candidate"
      exit 4
    }

    declared_name=$(frontmatter_name "$canonical")
    if [ "$dir_slug" = "$QUERY_SLUG" ] || [ "$declared_name" = "$QUERY" ]; then
      append_match "$canonical"
    fi
  done < <(find -P "$search_root" -mindepth 1 -maxdepth 1 -type d -print0)
done

case "${#MATCHES[@]}" in
  0)
    diagnose "absent project skill '$QUERY' under $PROJECT"
    exit 1
    ;;
  1)
    printf '%s\n' "${MATCHES[0]}"
    exit 0
    ;;
  *)
    diagnose "ambiguous project skill '$QUERY' under $PROJECT"
    printf '%s\n' "${MATCHES[@]}" | LC_ALL=C sort | sed 's/^/  /' >&2
    exit 3
    ;;
esac
