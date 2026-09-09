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
# from the project's own AGENTS.md, so it serves the captain's individual
# sessions exactly as much as a firstmate-dispatched worker. It is deliberately
# not a firstmate-private channel. When a project's canonical home is a local
# checkout rather than its repository, the catalog lives in that checkout;
# bin/fm-project-memory.sh's `home` command is what resolves which directory
# that is.
#
# Usage:
#   fm-project-recipes.sh init <project-dir>
#   fm-project-recipes.sh digest <project-dir> [--budget <tokens>]
#   fm-project-recipes.sh check <project-dir> [--budget <tokens>]
#
# `init` is the only subcommand that writes, and it writes only into the
# directory it is given. `digest` and `check` never write anything.
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
#   - An entry unverified for 90 days is stale. `check` names it, and the next
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
# `check` exits 1 when the catalog is over budget or holds a stale entry, so it
# can gate as well as report; 0 when the catalog is clean or absent.
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

## Example - replace this with the first real capability
- when: the situation that calls for this capability
- ask: the exact command or the shape of the request that starts it
- gives: what comes back
- notes: the sharp edges, credentials, or preconditions
<!--r:$(date -u +%Y-%m-%d)-->
EOF
}

pointer_line() {
  printf '%s\n' "Agent recipes - what this project can do and how each capability is asked for: [\`$RECIPES_REL\`]($RECIPES_REL). Read it before starting work, and record what you learn there."
}

recipe_blocks() {  # <recipes file>
  awk -v brk="$RECIPE_BREAK" '
    /^## / { if (n > 0) print brk; n++; print; next }
    n > 0 && /^[ \t]*-[ \t]*(when|ask):/ { print; next }
    { next }
    END { if (n > 0) print brk }
  ' "$1"
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
BUDGET=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --budget)
      [ "$#" -gt 1 ] || die "--budget requires a token count"
      BUDGET=$2
      shift 2
      ;;
    *) die "unknown option: $1" ;;
  esac
done
if [ -n "$BUDGET" ]; then
  case "$BUDGET" in
    '' | *[!0-9]*) die "--budget requires a positive integer" ;;
  esac
  [ "$BUDGET" -gt 0 ] || die "--budget requires a positive integer"
else
  BUDGET=$(read_budget)
fi

DIR=$(resolve_dir "$DIR")
RECIPES="$DIR/$RECIPES_REL"

case "$CMD" in
  init)
    "$SCRIPT_DIR/fm-ensure-agents-md.sh" "$DIR" >/dev/null || die "could not establish AGENTS.md in $DIR"
    if [ -L "$RECIPES" ]; then
      die "$RECIPES is a symlink; expected a regular file"
    fi
    if [ -e "$RECIPES" ] && [ ! -f "$RECIPES" ]; then
      die "$RECIPES exists and is not a regular file"
    fi
    if [ ! -e "$RECIPES" ]; then
      mkdir -p "$DIR/.agents"
      skeleton "$(basename "$DIR")" >"$RECIPES"
      echo "created: $RECIPES"
    else
      echo "unchanged: $RECIPES"
    fi
    AGENTS="$DIR/AGENTS.md"
    if [ -f "$AGENTS" ] && ! grep -qF "$RECIPES_REL" "$AGENTS"; then
      if [ -n "$(tail -c 1 "$AGENTS")" ]; then
        printf '\n' >>"$AGENTS"
      fi
      {
        printf '\n'
        pointer_line
      } >>"$AGENTS"
      echo "updated: added the recipe-catalog pointer to $AGENTS"
    fi
    ;;
  digest)
    if [ ! -f "$RECIPES" ]; then
      exit 0
    fi
    TOTAL=$(grep -c '^## ' "$RECIPES" || true)
    [ "${TOTAL:-0}" -gt 0 ] || exit 0
    LIMIT_BYTES=$((BUDGET * 3))
    TMP=$(mktemp "${TMPDIR:-/tmp}/fm-project-recipes.XXXXXX") || die "could not create a scratch file"
    recipe_blocks "$RECIPES" >"$TMP"
    OUT=$(
      used=0
      shown=0
      block=
      block_bytes=0
      while IFS= read -r line; do
        if [ "$line" = "$RECIPE_BREAK" ]; then
          [ -n "$block" ] || continue
          if [ $((used + block_bytes)) -le "$LIMIT_BYTES" ] || [ "$shown" -eq 0 ]; then
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
      done <"$TMP"
      printf '%s\n' "FM_RECIPE_SHOWN=$shown"
    )
    rm -f -- "$TMP"
    SHOWN=${OUT##*FM_RECIPE_SHOWN=}
    BODY=${OUT%FM_RECIPE_SHOWN=*}
    printf '# Project capabilities\n'
    # shellcheck disable=SC2016 # Markdown backticks in the digest text, not a command substitution.
    printf 'What this project is known to do and how each capability is asked for. The full entry for any of them, with its preconditions and sharp edges, is in `%s`.\n\n' "$RECIPES_REL"
    printf '%s' "$BODY"
    if [ "$SHOWN" -lt "$TOTAL" ]; then
      # shellcheck disable=SC2016 # Markdown backticks in the digest text, not a command substitution.
      printf '\n(%s of %s capabilities shown; the digest budget is %s estimated tokens - read `%s` for the rest.)\n' \
        "$SHOWN" "$TOTAL" "$BUDGET" "$RECIPES_REL"
    fi
    ;;
  check)
    if [ ! -f "$RECIPES" ]; then
      printf 'recipes: absent (%s)\n' "$RECIPES"
      # shellcheck disable=SC2016 # Markdown backticks in the report text, not a command substitution.
    printf 'run `fm-project-recipes.sh init %s` to start this project'"'"'s catalog\n' "$DIR"
      exit 0
    fi
    fm_startup_memory_measure_file "$RECIPES" >/dev/null || die "$FM_STARTUP_MEMORY_BUDGET_ERROR"
    TOKENS=$FM_STARTUP_MEMORY_MEASURE_TOKENS
    TOTAL=$(grep -c '^## ' "$RECIPES" || true)
    printf 'recipes: %s\n' "$RECIPES"
    printf 'entries: %s\n' "${TOTAL:-0}"
    printf 'estimated_tokens: %s\n' "$TOKENS"
    printf 'digest_budget_tokens: %s\n' "$BUDGET"
    RC=0
    if [ "$TOKENS" -gt "$BUDGET" ]; then
      printf 'OVER_BUDGET: the catalog no longer fits the start-of-work digest; consolidate entries rather than raising the ceiling\n'
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
