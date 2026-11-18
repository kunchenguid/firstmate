#!/usr/bin/env bash
# Review Claude Code's auto-memory notes for this home and file approved ones as learnings.
#
# Usage: FM_HOME=<primary home> fm-memory-review.sh [--memory-dir DIR] [list|review]
#   review  (default) show each not-yet-reviewed note and ask: y = file it, n = never ask
#           again, q = stop (anything unread is asked next run; end of input also stops)
#   list    print the not-yet-reviewed notes' file names and change nothing
#
# This is the return path of the Claude <-> Firstmate memory flow. Firstmate's
# files stay the master copy: this script only appends to data/learnings.md and
# to its own record, data/claude-memory-reviewed.tsv. It never writes
# data/captain.md or data/captain-shared.md, and never edits or deletes anything
# under Claude's directory. A person approves each note; nothing is filed unasked.
#
# Source. Claude keeps auto memory per git repository at
# <CLAUDE_CONFIG_DIR or ~/.claude>/projects/<repo path with every non-alphanumeric
# character replaced by "-">/memory/ (one MEMORY.md index plus one topic .md file per
# note, optional YAML frontmatter with name, description, type). The repository is
# FM_HOME, which must be set explicitly so a copy run from a task worktree can never
# read a worker's store. Only that one store is read: stores of project clones and
# task worktrees are written by workers, whose "user" is Firstmate rather than the
# captain, so they are never listed. A task pane (FM_TASK_ID set) is refused, and so is an FM_HOME that
# fm_primary_root_matches (bin/fm-primary-scope-lib.sh) does not accept as a primary home.
# Unverified limitation: whether Claude Code shares one store between linked worktrees
# of the same repository is not confirmed, so a worker in a worktree of the firstmate
# repo itself might write into this store; nothing here detects that.
# --memory-dir names the directory directly, for a store moved with Claude's
# autoMemoryDirectory setting. Very long paths are hashed by Claude Code and are
# not derived here; use --memory-dir for those. MEMORY.md, symlinks and non-.md
# files are skipped.
#
# Filing. An approved note is appended to data/learnings.md as a `##` entry: its
# name, its body, a provenance line naming the source file and type, and the
# `<!--a:YYYY-MM-DD-->` aging marker the stow skill owns. Tier semantics stay with
# stow; stow curates the entry later like any other learning.
#
# Record. data/claude-memory-reviewed.tsv holds one tab-separated line per decided
# note: content sha256, filed|skipped, date, source file. Identity is the content
# hash, so an unchanged note is never asked twice and an edited one is asked again.
set -u

die() { echo "error: $*" >&2; exit 1; }

MODE=review
MEMORY_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --memory-dir) [ $# -ge 2 ] || die "--memory-dir needs a directory"; MEMORY_DIR=$2; shift 2 ;;
    review|list) MODE=$1; shift ;;
    -h|--help) sed -n '2,/^set -u$/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (usage: fm-memory-review.sh [--memory-dir DIR] [list|review])" ;;
  esac
done

[ -z "${FM_TASK_ID:-}" ] || die "refusing to run in a task pane: a worker's memory is not the captain's"
[ -n "${FM_HOME:-}" ] || die "FM_HOME must be set to the primary home explicitly"
[ -d "$FM_HOME" ] || die "FM_HOME is not a directory: $FM_HOME"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-primary-scope-lib.sh"
fm_primary_root_matches "$FM_HOME" || die "FM_HOME is not a primary home: $FM_HOME"

if [ -z "$MEMORY_DIR" ]; then
  home_real=$(cd "$FM_HOME" && pwd -P) || die "cannot resolve FM_HOME"
  project=$(printf '%s' "$home_real" | sed 's/[^A-Za-z0-9]/-/g')
  MEMORY_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$project/memory"
fi

LEARNINGS="$FM_HOME/data/learnings.md"
RECORD="$FM_HOME/data/claude-memory-reviewed.tsv"

if [ ! -d "$MEMORY_DIR" ]; then
  echo "no Claude memory directory at $MEMORY_DIR; nothing to review"
  exit 0
fi

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

# frontmatter_field <file> <key>: value of KEY inside a leading --- block, else empty.
frontmatter_field() {
  awk -v key="$2" '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    index($0, key ":") == 1 { sub(/^[^:]*:[ \t]*/, ""); print; exit }
  ' "$1"
}

# note_body <file>: the file without its leading --- block.
note_body() {
  awk '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm { if ($0 == "---") infm = 0; next }
    { print }
  ' "$1"
}

already_reviewed() {
  [ -f "$RECORD" ] && grep -q "^$1	" "$RECORD"
}

# Collect unreviewed notes as "sha<TAB>path" lines, in file-name order.
PENDING=()
for f in "$MEMORY_DIR"/*.md; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  [ "$(basename "$f")" != MEMORY.md ] || continue
  sha=$(sha256_file "$f") || die "cannot hash $f"
  already_reviewed "$sha" || PENDING+=("$sha	$f")
done

if [ "${#PENDING[@]}" -eq 0 ]; then
  echo "no unreviewed Claude memory notes in $MEMORY_DIR"
  exit 0
fi

if [ "$MODE" = list ]; then
  for item in "${PENDING[@]}"; do
    printf '%s\n' "${item#*	}"
  done
  exit 0
fi

today=$(date +%Y-%m-%d)

file_note() {
  local path=$1 name type body
  name=$(frontmatter_field "$path" name)
  [ -n "$name" ] || name=$(basename "$path" .md)
  type=$(frontmatter_field "$path" type)
  body=$(note_body "$path")
  [ -n "$body" ] || body=$(frontmatter_field "$path" description)
  mkdir -p "$FM_HOME/data" || return 1
  if [ ! -f "$LEARNINGS" ]; then
    printf '# Learnings\n\n<!-- memory tiers: see the stow skill -->\n' >"$LEARNINGS" || return 1
  fi
  printf '\n## %s\n\n%s\n\nSource: Claude auto memory %s (type: %s), approved %s. <!--a:%s-->\n' \
    "$name" "$body" "$path" "${type:-unknown}" "$today" "$today" >>"$LEARNINGS"
}

record() { # record <sha> <decision> <path>
  mkdir -p "$FM_HOME/data" || return 1
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$today" "$3" >>"$RECORD"
}

total=${#PENDING[@]}
i=0
for item in "${PENDING[@]}"; do
  i=$((i + 1))
  sha=${item%%	*}
  path=${item#*	}
  printf '\n--- %s/%s: %s\n' "$i" "$total" "$path"
  printf 'type: %s\n' "$(frontmatter_field "$path" type)"
  desc=$(frontmatter_field "$path" description)
  [ -z "$desc" ] || printf 'description: %s\n' "$desc"
  printf '\n%s\n\n' "$(note_body "$path")"
  printf 'File as a learning? [y]es / [n]o, do not ask again / [q]uit: '
  if ! read -r answer; then
    printf '\n'
    break
  fi
  case "$answer" in
    y|Y|yes)
      file_note "$path" || die "could not file $path"
      record "$sha" filed "$path" || die "could not record $path"
      echo "filed in data/learnings.md" ;;
    n|N|no) record "$sha" skipped "$path" || die "could not record $path"; echo "skipped" ;;
    q|Q|quit) break ;;
    *) echo "left for the next run" ;;
  esac
done
