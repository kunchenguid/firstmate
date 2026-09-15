#!/usr/bin/env bash
# A project's recipe catalog: what an agent can do in this project, and exactly
# how each capability is asked for.
#
# Some projects stop being software and become a toolbox whose only user is an
# agent - diagnose an assistant bug, audit a conversation corpus, change a
# prompt, run a realistic test. For a project like that the operational recipes
# ARE the product, and today they survive only inside one long conversation with
# the captain. This file's catalog is where they are written down instead, and
# `digest` is the bounded summary every worker reads before touching anything.
#
# The catalog lives WITH THE PROJECT at <project>/.agents/recipes.md, reachable
# from the agent memory file the project already keeps - its AGENTS.md, or its
# CLAUDE.md when that is what the project has - so it serves the captain's
# individual sessions exactly as much as a firstmate-dispatched worker. It is
# deliberately not a firstmate-private channel. When a project's canonical home
# is a local checkout rather than its repository, the catalog lives in that
# checkout; bin/fm-project-memory.sh's `home` command is what resolves which
# directory that is.
#
# Usage:
#   fm-project-recipes.sh init <project-dir>
#   fm-project-recipes.sh digest <project-dir> [--absolute]
#   fm-project-recipes.sh check <project-dir>
#
# `init` is the only subcommand that writes, and it writes only into the
# directory it is given. It refuses while a git operation is in flight there,
# because that directory can be a live folder the captain is working in at the
# same time. It always creates the catalog, then adds one pointer line to every
# memory file the catalog has to be reachable from: AGENTS.md when there is
# one, and CLAUDE.md when it is a real file that does not import AGENTS.md
# through an `@AGENTS.md` line - the captain's own sessions load CLAUDE.md, so
# a pointer only in an AGENTS.md they never import would serve workers alone.
# It never renames, converts, or reconciles those files - a project that keeps
# both as distinct real files is left exactly as it is apart from the pointer -
# and it calls bin/fm-ensure-agents-md.sh only when the project has neither.
# It never writes through a symlink that leaves the directory: the only link it
# accepts between the two memory files is one pointing at the other, which is
# one file that gets the pointer once. A memory file linked anywhere else is
# refused, because writing through it would land the pointer outside the
# directory this command was given.
# `digest` and `check` never write anything.
#
# `digest --absolute` names the catalog by its absolute path instead of the
# project-relative one, for a reader that works somewhere other than
# <project-dir> - a worker in a task copy whose project's home is a live local
# folder - so it never takes its own copy's stale catalog for the real one.
#
# Entry format - one capability per `##` section:
#
#   ## Find the production bug behind one conversation
#   - when: a lead reports the assistant misbehaved and you have the lead id
#   - ask: `synthetic-evals replay --lead <id>`, then read the scored turns
#   - gives: the reproduced turn and the rule that fired
#   - notes: needs CLOSEBOT_TOKEN in .env
#   <!--r:2026-09-09-->
#
# `when:` and `ask:` are what the digest carries, because they answer the two
# questions a worker has before it starts: is this the situation, and how do I
# invoke it. Everything else is read from the catalog itself when the worker
# gets there.
#
# CURATION - the catalog prunes and corrects, it never only accumulates:
#   - Every entry carries `<!--r:YYYY-MM-DD-->`, the date it was last verified
#     against the real project. Verified means exercised or re-derived in that
#     session, not believed.
#   - An entry unverified for 90 days is stale. The digest still carries it, but
#     marked UNVERIFIED, so a worker never reads a lapsed recipe as current fact.
#     `check` names it, and the next
#     session that touches that capability either re-verifies it and refreshes
#     the date or deletes it. A recipe that stopped being true is worse than no
#     recipe, so inertia is not a reason to keep one.
#   - Rewrite an entry that changed. Never leave a superseded entry beside its
#     replacement.
#   - The digest has a token budget, so the catalog cannot grow into the wall of
#     text that recreates the original problem inverted. When the catalog
#     outgrows it, that is the signal to consolidate, not to raise the ceiling.
#
# The digest budget is config/project-recipe-budget in the active firstmate home
# (one positive integer plus one newline); absent means the built-in default
# below. The estimate is the same conservative ceil(bytes/3) local approximation
# bin/fm-startup-memory-budget-lib.sh owns for firstmate's own startup memory.
#
# `check` measures what the digest actually renders - the `when:`/`ask:` blocks,
# never the full entries - against that same budget, and reports how many of
# the catalog's entries the digest can show. It exits 1 when the digest cannot
# carry every entry or the catalog holds a stale entry, so it can gate as well
# as report; 0 when the catalog is clean or absent.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"

RECIPES_REL='.agents/recipes.md'
BUDGET_FILE='project-recipe-budget'
BUDGET_DEFAULT=1500
STALE_DAYS=90

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  echo "project-recipes: $1" >&2
  exit 1
}

read_budget() {
  local file="$CONFIG/$BUDGET_FILE" value
  if [ ! -e "$file" ]; then
    printf '%s\n' "$BUDGET_DEFAULT"
    return 0
  fi
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    die "config/$BUDGET_FILE must be an ordinary regular file"
  fi
  value=$(tr -d '\n' <"$file")
  case "$value" in
    '' | *[!0-9]*) die "config/$BUDGET_FILE must hold one positive integer" ;;
  esac
  [ "$value" -gt 0 ] || die "config/$BUDGET_FILE must hold one positive integer"
  printf '%s\n' "$value"
}

# Days since the civil epoch, so two dates can be compared without date(1)
# extensions that differ between GNU and BSD. Howard Hinnant's civil-from-days
# inverse, in shell arithmetic.
days_from_civil() {  # <YYYY> <MM> <DD>
  local y=$1 m=$2 d=$3 era yoe doy doe
  y=$((10#$y))
  m=$((10#$m))
  d=$((10#$d))
  [ "$m" -le 2 ] && y=$((y - 1))
  if [ "$y" -ge 0 ]; then
    era=$((y / 400))
  else
    era=$(((y - 399) / 400))
  fi
  yoe=$((y - era * 400))
  if [ "$m" -gt 2 ]; then
    doy=$(((153 * (m - 3) + 2) / 5 + d - 1))
  else
    doy=$(((153 * (m + 9) + 2) / 5 + d - 1))
  fi
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  printf '%s\n' $((era * 146097 + doe - 719468))
}

age_in_days() {  # <YYYY-MM-DD>; prints whole days since that date
  local date_str=$1 today ty tm td y m d
  case $date_str in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  y=${date_str%%-*}
  m=${date_str#*-}
  m=${m%%-*}
  d=${date_str##*-}
  today=$(date -u +%Y-%m-%d)
  ty=${today%%-*}
  tm=${today#*-}
  tm=${tm%%-*}
  td=${today##*-}
  printf '%s\n' "$(($(days_from_civil "$ty" "$tm" "$td") - $(days_from_civil "$y" "$m" "$d")))"
}

resolve_dir() {  # <dir>
  local dir=$1
  [ -d "$dir" ] || die "not a directory: $dir"
  (cd "$dir" && pwd -P)
}

RECIPE_BREAK='@@FM_RECIPE_BREAK@@'

skeleton() {  # <project-name>
  cat <<EOF
# Agent recipes - $1

<!-- firstmate:project-recipes v1 -->
What an agent can do in this project and how each capability is asked for.
Every session that learns a new repeatable way of working here records it below;
every session that finds an entry wrong rewrites or deletes it.
The format, the digest budget, and the re-verification horizon are owned by
\`fm-project-recipes.sh --help\`.

The shape of an entry, indented here so this catalog starts empty rather than
announcing a capability nobody has. Write the first real one below it, flush
left, starting with its own \`##\` heading:

    ## Find the production bug behind one conversation
    - when: a lead reports the assistant misbehaved and you have the lead id
    - ask: \`synthetic-evals replay --lead <id>\`, then read the scored turns
    - gives: the reproduced turn and the rule that fired
    - notes: needs CLOSEBOT_TOKEN in .env
    <!--r:$(date -u +%Y-%m-%d)-->
EOF
}

pointer_line() {
  printf '%s\n' "Agent recipes - what this project can do and how each capability is asked for: [\`$RECIPES_REL\`]($RECIPES_REL). Read it before starting work, and record what you learn there."
}

add_pointer() {  # <memory file>; appends the pointer once
  grep -qF "$RECIPES_REL" "$1" && return 0
  if [ -n "$(tail -c 1 "$1")" ]; then
    printf '\n' >>"$1"
  fi
  {
    printf '\n'
    pointer_line
  } >>"$1"
  echo "updated: added the recipe-catalog pointer to $1"
}

imports_agents_md() {  # <CLAUDE.md>; true when it carries an @AGENTS.md import line
  grep -qE '^@(\./)?AGENTS\.md[[:space:]]*$' "$1"
}

recipe_blocks() {  # <recipes file> [notes file]
  awk -v brk="$RECIPE_BREAK" -v notes="${2:-}" '
    BEGIN {
      if (notes != "") {
        while ((getline line < notes) > 0) {
          t = index(line, "\t")
          if (t > 0) note[substr(line, 1, t - 1)] = substr(line, t + 1)
        }
        close(notes)
      }
    }
    /^## / {
      if (n > 0) print brk
      n++
      h = substr($0, 4)
      if (h in note) print $0 " " note[h]
      else print $0
      next
    }
    n > 0 && /^[ \t]*-[ \t]*(when|ask):/ { print; next }
    { next }
    END { if (n > 0) print brk }
  ' "$1"
}

# An entry past the re-verification horizon still belongs in the digest - the
# worker may be exactly who confirms or corrects it - but it must never arrive
# looking as current as the rest. Marking it is what keeps the digest worth
# trusting; silently passing on a recipe that stopped being true is the failure
# the catalog exists to prevent.
unverified_notes() {  # <recipes file> <out file>
  local heading recorded age
  : >"$2"
  while IFS="$(printf '\t')" read -r heading recorded; do
    [ -n "$heading" ] || continue
    if [ -n "$recorded" ] && age=$(age_in_days "$recorded"); then
      if [ "$age" -ge "$STALE_DAYS" ]; then
        printf '%s\t(UNVERIFIED since %s - confirm it still holds before relying on it)\n' \
          "$heading" "$recorded" >>"$2"
      fi
    else
      printf '%s\t(UNVERIFIED - no date recorded)\n' "$heading" >>"$2"
    fi
  done < <(recipe_dates "$1")
}

# Pack the digest blocks into the budget: whole entries, in catalog order, and
# always at least the first one. Prints the body, then the size and count of
# what it let through, so `digest` renders and `check` measures the very same
# packing.
pack_blocks() {  # <blocks file> <limit bytes>
  local LC_ALL=C
  local used=0 shown=0 block='' block_bytes=0 line
  while IFS= read -r line; do
    if [ "$line" = "$RECIPE_BREAK" ]; then
      [ -n "$block" ] || continue
      if [ $((used + block_bytes)) -le "$2" ] || [ "$shown" -eq 0 ]; then
        printf '%s\n\n' "$block"
        used=$((used + block_bytes))
        shown=$((shown + 1))
      else
        break
      fi
      block=
      block_bytes=0
      continue
    fi
    if [ -z "$block" ]; then
      block=$line
    else
      block="$block
$line"
    fi
    block_bytes=$((block_bytes + ${#line} + 1))
  done <"$1"
  printf 'FM_RECIPE_BYTES=%s\nFM_RECIPE_SHOWN=%s\n' "$used" "$shown"
}

# What the digest carries for every entry of the catalog, before the budget
# cuts it: the same blocks `digest` packs, with the unverified marks.
render_digest_blocks() {  # <recipes file> <blocks out>
  local notes
  notes=$(mktemp "${TMPDIR:-/tmp}/fm-project-recipes-notes.XXXXXX") || die "could not create a scratch file"
  unverified_notes "$1" "$notes"
  recipe_blocks "$1" "$notes" >"$2"
  rm -f -- "$notes"
}

recipe_dates() {  # <recipes file>; prints "<heading>\t<date-or-empty>"
  awk '
    function flush() { if (h != "") printf "%s\t%s\n", h, d }
    /^## / { flush(); h = substr($0, 4); d = ""; next }
    match($0, /<!--r:[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-->/) {
      if (h != "" && d == "") d = substr($0, RSTART + 6, 10)
      next
    }
    END { flush() }
  ' "$1"
}

case "${1:-}" in
  -h | --help | '')
    usage
    exit 0
    ;;
esac

CMD=$1
shift
DIR=${1:-}
[ -n "$DIR" ] || die "usage: $CMD <project-dir>"
shift
ABSOLUTE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --absolute)
      [ "$CMD" = digest ] || die "--absolute applies only to digest"
      ABSOLUTE=1
      shift
      ;;
    *) die "unknown option: $1" ;;
  esac
done
BUDGET=$(read_budget)
LIMIT_BYTES=$((BUDGET * 3))

DIR=$(resolve_dir "$DIR")
RECIPES="$DIR/$RECIPES_REL"
CATALOG_REF=$RECIPES_REL
[ "$ABSOLUTE" -eq 0 ] || CATALOG_REF=$RECIPES

case "$CMD" in
  init)
    # `init` is the one command here that writes into a project directory, and
    # that directory can be a live folder someone else is working in right now -
    # a source-canonical home is shared, not an isolated copy. A git operation
    # in flight is unambiguous evidence of exactly that, and unlike a recent
    # write it is never produced by a worker's own quiet copy, so it is the one
    # signal worth refusing on rather than guessing with a lock.
    if ! "$SCRIPT_DIR/fm-project-memory.sh" activity --home "$DIR" --git-only >/dev/null 2>&1; then
      die "a git operation is in flight in $DIR; someone is working there right now. Wait for it to finish, or check with \`fm-project-memory.sh activity --home $DIR\`"
    fi
    if [ -L "$RECIPES" ]; then
      die "$RECIPES is a symlink; expected a regular file"
    fi
    if [ -e "$RECIPES" ] && [ ! -f "$RECIPES" ]; then
      die "$RECIPES exists and is not a regular file"
    fi
    if [ -L "$DIR/CLAUDE.md" ] && ! { [ -f "$DIR/AGENTS.md" ] && [ ! -L "$DIR/AGENTS.md" ] && [ "$DIR/CLAUDE.md" -ef "$DIR/AGENTS.md" ]; }; then
      die "$DIR/CLAUDE.md is a symlink that does not point to $DIR/AGENTS.md; refusing to write the pointer through it"
    fi
    if [ -L "$DIR/AGENTS.md" ] && ! { [ -f "$DIR/CLAUDE.md" ] && [ ! -L "$DIR/CLAUDE.md" ] && [ "$DIR/AGENTS.md" -ef "$DIR/CLAUDE.md" ]; }; then
      die "$DIR/AGENTS.md is a symlink that does not point to $DIR/CLAUDE.md; refusing to write the pointer through it"
    fi
    if [ ! -e "$RECIPES" ]; then
      mkdir -p "$DIR/.agents"
      skeleton "$(basename "$DIR")" >"$RECIPES"
      echo "created: $RECIPES"
    else
      echo "unchanged: $RECIPES"
    fi
    # The pointer goes into every memory file the catalog must be reachable
    # from. This directory can be the captain's own live folder, so the
    # project's memory files are never renamed or reconciled here: a CLAUDE.md
    # that holds his own words gets the pointer in place, and when it does not
    # import AGENTS.md both files get it, because workers read AGENTS.md while
    # his sessions load CLAUDE.md.
    if [ ! -f "$DIR/AGENTS.md" ] && [ ! -f "$DIR/CLAUDE.md" ]; then
      "$SCRIPT_DIR/fm-ensure-agents-md.sh" "$DIR" >/dev/null || die "could not establish AGENTS.md in $DIR"
    fi
    if [ -f "$DIR/AGENTS.md" ]; then
      add_pointer "$DIR/AGENTS.md"
    fi
    if [ -f "$DIR/CLAUDE.md" ] && [ ! -L "$DIR/CLAUDE.md" ]; then
      if [ ! -f "$DIR/AGENTS.md" ] || ! imports_agents_md "$DIR/CLAUDE.md"; then
        add_pointer "$DIR/CLAUDE.md"
      fi
    fi
    ;;
  digest)
    if [ ! -f "$RECIPES" ]; then
      exit 0
    fi
    TOTAL=$(grep -c '^## ' "$RECIPES" || true)
    [ "${TOTAL:-0}" -gt 0 ] || exit 0
    TMP=$(mktemp "${TMPDIR:-/tmp}/fm-project-recipes.XXXXXX") || die "could not create a scratch file"
    render_digest_blocks "$RECIPES" "$TMP"
    OUT=$(pack_blocks "$TMP" "$LIMIT_BYTES")
    rm -f -- "$TMP"
    SHOWN=${OUT##*FM_RECIPE_SHOWN=}
    BODY=${OUT%FM_RECIPE_BYTES=*}
    printf '# Project capabilities\n'
    # shellcheck disable=SC2016 # Markdown backticks in the digest text, not a command substitution.
    printf 'What this project is known to do and how each capability is asked for. The full entry for any of them, with its preconditions and sharp edges, is in `%s`.\n\n' "$CATALOG_REF"
    printf '%s' "$BODY"
    if [ "$SHOWN" -lt "$TOTAL" ]; then
      # shellcheck disable=SC2016 # Markdown backticks in the digest text, not a command substitution.
      printf '\n(%s of %s capabilities shown; the digest budget is %s estimated tokens - read `%s` for the rest.)\n' \
        "$SHOWN" "$TOTAL" "$BUDGET" "$CATALOG_REF"
    fi
    ;;
  check)
    if [ ! -f "$RECIPES" ]; then
      printf 'recipes: absent (%s)\n' "$RECIPES"
      # shellcheck disable=SC2016 # Markdown backticks in the report text, not a command substitution.
    printf 'run `fm-project-recipes.sh init %s` to start this project'"'"'s catalog\n' "$DIR"
      exit 0
    fi
    TOTAL=$(grep -c '^## ' "$RECIPES" || true)
    TOTAL=${TOTAL:-0}
    SHOWN=0
    TOKENS=0
    if [ "$TOTAL" -gt 0 ]; then
      TMP=$(mktemp "${TMPDIR:-/tmp}/fm-project-recipes.XXXXXX") || die "could not create a scratch file"
      render_digest_blocks "$RECIPES" "$TMP"
      OUT=$(pack_blocks "$TMP" "$LIMIT_BYTES")
      rm -f -- "$TMP"
      SHOWN=${OUT##*FM_RECIPE_SHOWN=}
      BYTES=${OUT##*FM_RECIPE_BYTES=}
      BYTES=${BYTES%%$'\n'*}
      TOKENS=$(fm_startup_memory_estimated_tokens_for_bytes "$BYTES") || die "could not estimate the digest size"
    fi
    printf 'recipes: %s\n' "$RECIPES"
    printf 'entries: %s\n' "$TOTAL"
    printf 'digest_estimated_tokens: %s\n' "$TOKENS"
    printf 'digest_budget_tokens: %s\n' "$BUDGET"
    printf 'digest_shown: %s of %s\n' "$SHOWN" "$TOTAL"
    RC=0
    if [ "$SHOWN" -lt "$TOTAL" ]; then
      printf 'OVER_BUDGET: the start-of-work digest can carry only %s of %s entries; consolidate entries rather than raising the ceiling\n' "$SHOWN" "$TOTAL"
      RC=1
    elif [ "$TOKENS" -gt "$BUDGET" ]; then
      printf 'OVER_BUDGET: the start-of-work digest costs %s estimated tokens against a budget of %s; consolidate entries rather than raising the ceiling\n' "$TOKENS" "$BUDGET"
      RC=1
    fi
    STALE=0
    UNDATED=0
    while IFS="$(printf '\t')" read -r heading recorded; do
      [ -n "$heading" ] || continue
      if [ -z "$recorded" ]; then
        printf 'UNDATED: %s\n' "$heading"
        UNDATED=$((UNDATED + 1))
        continue
      fi
      if AGE=$(age_in_days "$recorded"); then
        if [ "$AGE" -ge "$STALE_DAYS" ]; then
          printf 'STALE: %s (last verified %s, %s days ago)\n' "$heading" "$recorded" "$AGE"
          STALE=$((STALE + 1))
        fi
      else
        printf 'UNDATED: %s (unparseable date "%s")\n' "$heading" "$recorded"
        UNDATED=$((UNDATED + 1))
      fi
    done < <(recipe_dates "$RECIPES")
    printf 'stale: %s\n' "$STALE"
    printf 'undated: %s\n' "$UNDATED"
    if [ "$STALE" -gt 0 ] || [ "$UNDATED" -gt 0 ]; then
      printf 'Re-verify each entry above against the real project and refresh its date, or delete it.\n'
      RC=1
    fi
    exit "$RC"
    ;;
  *)
    die "unknown command: $CMD (try --help)"
    ;;
esac
