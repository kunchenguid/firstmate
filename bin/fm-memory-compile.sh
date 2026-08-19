#!/usr/bin/env bash
# fm-memory-compile.sh - compile the capped startup working-memory bundle.
#
# Usage:
#   fm-memory-compile.sh [compile] [--context <text>]... [--context-file <path>]...
#                        [--no-auto-context]
#   fm-memory-compile.sh catalog [--dry-run]
#   fm-memory-compile.sh -h | --help
#
# `compile` writes the bundle to stdout and never writes to disk, so a
# read-only session can run it.  `catalog` republishes data/memory/catalog.md
# from data/memory/notes/ for grep and for the captain's own reading; the
# injected catalog is always rendered fresh from the notes, so a stale file on
# disk costs nothing, is reported, and is never trusted.
#
# WHY THIS EXISTS.  Session start used to print data/captain.md and
# data/learnings.md whole, so the startup memory surface grew without any read
# path that could refuse it.  This script is that refusal: it selects, it
# accounts, and it caps.
#
# LAYOUT.  Everything lives under data/memory/ in the home selected by FM_HOME:
#   core.md      the standing constitution.  data/captain.md is the standing
#                constitution by default and is used as the core when core.md
#                is absent, so a home that never authors core.md loses nothing.
#                core.md takes precedence the moment it exists.
#   notes/*.md   atomic notes, one claim each.
#   catalog.md   the regenerable index, one line per note: claim title, file
#                name under notes/, first triggers, and updated date.
#   drop/        in-band candidate claims, deliberately IGNORED here: a worker
#                may leave a claim there without changing what any session
#                injects.
#
# NOTE FORMAT.  A note may open with a YAML-style front matter block delimited
# by a bare `---` on line 1 and the next bare `---`:
#   title:    the claim this note makes; the first `# ` heading is the fallback,
#             and the file name is the fallback for that
#   triggers: comma-separated match terms; a note with none is never hot
#   updated:  ISO date, used for catalog display and for hot ordering
# Every other key passes through untouched for a human or a later pass.
# Matching is case-insensitive and bounded by non-alphanumeric characters at
# both ends, so `lint` matches `commands.lint` but not `linting`.
#
# SELECTION AND CAP.  config/startup-memory-budget owns the cap and
# bin/fm-startup-memory-budget-lib.sh owns the ceil(UTF-8 bytes / 3) estimate.
# This script accounts memory CONTENT bytes against that cap, exactly as
# bin/fm-startup-memory-budget.sh report does, and excludes its own framing
# lines.  Precedence under pressure is core, then catalog, then hot notes:
#   - core is never dropped and never truncated;
#   - core alone over budget prints core plus a loud MEMORY_BUDGET_WARNING and
#     no catalog and no notes;
#   - the catalog is kept ahead of every hot note, because it is the thing that
#     tells the next turn a note exists at all;
#   - hot notes are added newest-updated first, and one that does not fit is
#     skipped rather than ending selection, so a single large note cannot
#     starve the smaller ones behind it.
# An unreadable budget is the one hard error, because a cap that cannot be read
# must never be silently assumed.  Everything else degrades to a printed notice
# so a session start still gets a bundle.
#
# The bundle's last line is a machine-readable MEMORY_ACCOUNTING record whose
# status is one of: within-budget (nothing was dropped), capped (everything
# printed fits, but content was dropped to make it fit), or over-budget (the
# core alone did not fit and is the only thing printed).
#
# AUTO CONTEXT.  Unless --no-auto-context is given, the match context is
# data/projects.md, data/backlog.md, and every state/*.meta, each bounded to
# FM_MEMORY_CONTEXT_BYTES (default 65536) so a large backlog cannot make this
# expensive.  --context and --context-file add to it and are repeatable.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
MEMORY="$DATA/memory"
NOTES_DIR="$MEMORY/notes"

# A symlinked data/memory would defeat every per-file symlink guard below in one
# step, because the files inside the link target are ordinary regular files.
# The directory itself is therefore checked exactly like the files in it.
MEMORY_DIR_OK=1
[ ! -L "$MEMORY" ] || MEMORY_DIR_OK=0

CONTEXT_BYTES=${FM_MEMORY_CONTEXT_BYTES:-65536}
case "$CONTEXT_BYTES" in ''|*[!0-9]*|0) CONTEXT_BYTES=65536 ;; esac

# One literal tab, so field splitting never depends on a tab surviving an
# edit as whitespace inside a quoted pattern.
TAB=$(printf '\t')

# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  printf 'fm-memory-compile: %s\n' "$1" >&2
  exit 1
}

MODE=compile
DRY_RUN=0
NO_AUTO_CONTEXT=0
CONTEXT_TEXTS=()
CONTEXT_FILES=()

case "${1:-}" in
  compile|catalog) MODE=$1; shift ;;
  -h|--help) usage; exit 0 ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --context)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      CONTEXT_TEXTS+=("$2"); shift 2 ;;
    --context-file)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      CONTEXT_FILES+=("$2"); shift 2 ;;
    --no-auto-context) NO_AUTO_CONTEXT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

# Each mode accepts only its own flags, so a mistyped invocation is an error
# rather than a silently ignored option.
if [ "$MODE" = catalog ]; then
  [ "${#CONTEXT_TEXTS[@]}" -eq 0 ] && [ "${#CONTEXT_FILES[@]}" -eq 0 ] \
    && [ "$NO_AUTO_CONTEXT" -eq 0 ] || { usage >&2; exit 2; }
else
  [ "$DRY_RUN" -eq 0 ] || { usage >&2; exit 2; }
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/.fm-memory-compile.XXXXXX") || die 'could not create a working directory'
# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# --- note metadata ----------------------------------------------------------

# note_inventory: prints "<file>\t<title>\t<triggers>\t<updated>\t<shown>" per
# note, by file name, where <shown> is the shortened trigger list the catalog
# displays.  A note that is not an ordinary regular file is skipped rather than
# read, so the bundle never follows a symlink out of the memory directory.
#
# Every note is read by ONE awk pass rather than one process per note: this runs
# on the session-start critical path, and a home with fifty notes paid for two
# hundred processes when each note was measured and formatted on its own.
note_inventory() {
  local path count=0
  [ "$MEMORY_DIR_OK" -eq 1 ] || return 0
  [ -d "$NOTES_DIR" ] && [ ! -L "$NOTES_DIR" ] || return 0
  : > "$TMP/notepaths"
  for path in "$NOTES_DIR"/*.md; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    printf '%s\n' "$path" >> "$TMP/notepaths"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || return 0
  (cd "$NOTES_DIR" && wc -c -- *.md > "$TMP/notebytes" 2>/dev/null) || true
  awk -v listfile="$TMP/notepaths" -v bytesfile="$TMP/notebytes" '
    function clean(s) {
      gsub(/\t/, " ", s)
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    # Only the first few triggers are shown.  The full list is what the
    # compiler matches on; a catalog line exists so a reader knows the note is
    # there, and 51 full trigger lists cost more budget than they return.
    function shown(s,   i, c) {
      c = 0
      for (i = 1; i <= length(s); i++) {
        if (substr(s, i, 1) != ",") continue
        if (++c == 3) { s = substr(s, 1, i - 1); break }
      }
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function flush(   t, tok) {
      if (base == "") return
      t = (title != "" ? title : heading)
      if (t == "") t = base
      tok = (base in notetokens ? notetokens[base] : 0)
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", base, t, triggers, updated, shown(triggers), tok
      base = ""
    }
    BEGIN {
      if (bytesfile != "") {
        while ((getline bline < bytesfile) > 0) {
          sub(/^[[:space:]]+/, "", bline)
          split(bline, bparts, /[[:space:]]+/)
          bpath = bparts[2]
          sub(/^.*\//, "", bpath)
          if (bpath != "total" && bpath != "") {
            bcount = bparts[1] + 0
            notetokens[bpath] = int((bcount + 2) / 3)
          }
        }
      }
      while ((getline path < listfile) > 0) {
        b = path
        sub(/^.*\//, "", b)
        order[++n] = b
        pending[b] = 1
        ARGV[n] = path
      }
      ARGC = n + 1
    }
    FNR == 1 {
      flush()
      base = FILENAME
      sub(/^.*\//, "", base)
      pending[base] = 0
      title = ""; triggers = ""; updated = ""; heading = ""; fm = 0
      if ($0 == "---") { fm = 1; next }
    }
    fm && $0 == "---" { fm = 0; next }
    fm {
      if (match($0, /^[A-Za-z_][A-Za-z0-9_-]*:/)) {
        key = substr($0, 1, RLENGTH - 1)
        val = clean(substr($0, RLENGTH + 1))
        if (key == "title") title = val
        else if (key == "triggers") triggers = val
        else if (key == "updated") updated = val
      }
      next
    }
    heading == "" && /^#+[[:space:]]/ {
      h = $0
      sub(/^#+[[:space:]]*/, "", h)
      heading = clean(h)
    }
    # An empty note file never triggers a rule, so it is emitted here rather
    # than falling out of the catalog that is supposed to list every note.
    END {
      flush()
      for (i = 1; i <= n; i++) {
        if (pending[order[i]]) {
          tok = (order[i] in notetokens ? notetokens[order[i]] : 0)
          printf "%s\t%s\t\t\t\t%s\n", order[i], order[i], tok
        }
      }
    }
  '
}

# render_catalog: the compiled index, one line per note, rendered from the
# notes themselves so it is correct even when catalog.md on disk is stale.
render_catalog() {
  local base title updated shown line
  printf '<!-- compiled by bin/fm-memory-compile.sh from data/memory/notes/ -->\n\n'
  if [ ! -s "$TMP/inventory" ]; then
    printf 'No notes filed yet in data/memory/notes/.\n'
    return 0
  fi
  # Split by hand rather than with `read -r a b c`: IFS=tab is IFS WHITESPACE,
  # so bash would fold two adjacent tabs into one delimiter and silently shift
  # every column left the moment a note has no triggers.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    base=${line%%"$TAB"*}; line=${line#*"$TAB"}
    title=${line%%"$TAB"*}; line=${line#*"$TAB"}
    line=${line#*"$TAB"}
    updated=${line%%"$TAB"*}; line=${line#*"$TAB"}
    shown=${line%%"$TAB"*}
    [ -n "$updated" ] || updated='?'
    [ -n "$shown" ] || shown='-'
    printf -- '- %s (%s | %s | %s)\n' "$title" "$base" "$shown" "$updated"
  done < "$TMP/inventory"
}

note_inventory > "$TMP/inventory"

# --- catalog mode -----------------------------------------------------------

if [ "$MODE" = catalog ]; then
  render_catalog > "$TMP/catalog"
  if [ "$DRY_RUN" -eq 1 ]; then
    cat "$TMP/catalog"
    exit 0
  fi
  [ "$MEMORY_DIR_OK" -eq 1 ] || die 'data/memory is a symlink; refusing to publish through it'
  [ -d "$MEMORY" ] || mkdir -p "$MEMORY" || die "could not create $MEMORY"
  if [ -L "$MEMORY/catalog.md" ]; then
    die 'data/memory/catalog.md is a symlink; refusing to publish through it'
  fi
  cp "$TMP/catalog" "$MEMORY/.catalog.md.tmp" || die 'could not stage the catalog'
  mv -f "$MEMORY/.catalog.md.tmp" "$MEMORY/catalog.md" || die 'could not publish the catalog'
  printf 'catalog: published data/memory/catalog.md (%s note(s))\n' \
    "$(wc -l < "$TMP/inventory" | tr -d ' ')"
  exit 0
fi

# --- match context ----------------------------------------------------------

for path in "${CONTEXT_FILES[@]-}"; do
  [ -n "$path" ] || continue
  [ -f "$path" ] || die "context file not found: $path"
done

build_context() {
  local path
  if [ "$NO_AUTO_CONTEXT" -eq 0 ]; then
    for path in "$DATA/projects.md" "$DATA/backlog.md"; do
      [ -f "$path" ] && [ ! -L "$path" ] || continue
      head -c "$CONTEXT_BYTES" "$path"
      printf '\n'
    done
    for path in "$STATE"/*.meta; do
      [ -f "$path" ] && [ ! -L "$path" ] || continue
      head -c "$CONTEXT_BYTES" "$path"
      printf '\n'
    done
  fi
  for path in "${CONTEXT_FILES[@]-}"; do
    [ -n "$path" ] || continue
    head -c "$CONTEXT_BYTES" "$path"
    printf '\n'
  done
  for path in "${CONTEXT_TEXTS[@]-}"; do
    [ -n "$path" ] || continue
    printf '%s\n' "$path"
  done
}

build_context | LC_ALL=C tr '[:upper:]' '[:lower:]' > "$TMP/context"

# hot_notes: the trigger-matched subset, newest updated first, then by path.
# An unknown date sorts last without a special case because 0000-00-00 is below
# every real ISO date.
hot_notes() {
  awk -v ctxfile="$TMP/context" '
    function is_boundary(c) { return c == "" || c !~ /[a-z0-9]/ }
    function matches(t,   start, pos, p, before, after) {
      if (t == "") return 0
      start = 1
      while ((pos = index(substr(ctx, start), t)) > 0) {
        p = start + pos - 1
        before = (p == 1) ? "" : substr(ctx, p - 1, 1)
        after = substr(ctx, p + length(t), 1)
        if (is_boundary(before) && is_boundary(after)) return 1
        start = p + 1
      }
      return 0
    }
    BEGIN {
      FS = "\t"
      ctx = ""
      while ((getline line < ctxfile) > 0) ctx = ctx line "\n"
    }
    {
      n = split($3, parts, ",")
      hit = 0
      for (i = 1; i <= n; i++) {
        t = parts[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
        t = tolower(t)
        if (matches(t)) { hit = 1; break }
      }
      if (!hit) next
      updated = ($4 == "" ? "0000-00-00" : $4)
      printf "%s\t%s\t%s\n", updated, $1, $6
    }
  ' "$TMP/inventory" | LC_ALL=C sort -t"$TAB" -k1,1r -k2,2
}

hot_notes > "$TMP/hot"

# --- budget accounting ------------------------------------------------------

# Called without a command substitution on purpose: the library reports WHY a
# budget is unusable through a shell variable, and a subshell would throw that
# reason away and leave the operator with a bare failure.
if ! fm_startup_memory_budget_read "$CONFIG" >/dev/null; then
  die "invalid config/$FM_STARTUP_MEMORY_BUDGET_FILE - $FM_STARTUP_MEMORY_BUDGET_ERROR"
fi
BUDGET=$FM_STARTUP_MEMORY_BUDGET_VALUE

# tokens_of_file <path>: the ceil(UTF-8 bytes / 3) estimate for one file, from
# the same library bin/fm-startup-memory-budget.sh report uses.
tokens_of_file() {
  fm_startup_memory_measure_file "$1" >/dev/null \
    || die "$FM_STARTUP_MEMORY_BUDGET_ERROR"
  printf '%s\n' "$FM_STARTUP_MEMORY_MEASURE_TOKENS"
}

CORE_PATH=
CORE_LABEL=
CORE_TOKENS=0
NOTICES=()

if [ "$MEMORY_DIR_OK" -eq 1 ] && [ -f "$MEMORY/core.md" ] && [ ! -L "$MEMORY/core.md" ]; then
  CORE_PATH="$MEMORY/core.md"
  CORE_LABEL='data/memory/core.md'
  if [ -f "$DATA/captain.md" ] && [ ! -L "$DATA/captain.md" ] && [ -s "$DATA/captain.md" ]; then
    CAPTAIN_TOKENS=$(tokens_of_file "$DATA/captain.md")
    NOTICES+=("MEMORY_NOTICE: data/captain.md is still present (${CAPTAIN_TOKENS} estimated tokens) and is NOT injected because data/memory/core.md takes precedence. Fold standing preferences into data/memory/core.md, or remove data/captain.md.")
  fi
elif [ -f "$DATA/captain.md" ] && [ ! -L "$DATA/captain.md" ]; then
  CORE_PATH="$DATA/captain.md"
  CORE_LABEL='data/captain.md (standing constitution; data/memory/core.md is ABSENT)'
fi

if [ -n "$CORE_PATH" ]; then
  CORE_TOKENS=$(tokens_of_file "$CORE_PATH")
else
  NOTICES+=('MEMORY_NOTICE: no core memory - both data/memory/core.md and data/captain.md are ABSENT, so this home is running on the firstmate repo built-in defaults.')
fi

render_catalog > "$TMP/catalog"
CATALOG_TOKENS=$(tokens_of_file "$TMP/catalog")

if [ "$MEMORY_DIR_OK" -eq 1 ] && [ -f "$MEMORY/catalog.md" ] && [ ! -L "$MEMORY/catalog.md" ]; then
  cmp -s "$TMP/catalog" "$MEMORY/catalog.md" \
    || NOTICES+=('MEMORY_NOTICE: data/memory/catalog.md on disk is stale relative to data/memory/notes/. The catalog in this bundle was rendered fresh from the notes; republish the file with bin/fm-memory-compile.sh catalog.')
else
  NOTICES+=('MEMORY_NOTICE: data/memory/catalog.md is ABSENT. The catalog in this bundle was rendered fresh from data/memory/notes/; publish the file with bin/fm-memory-compile.sh catalog.')
fi

if [ -f "$DATA/learnings.md" ] && [ ! -L "$DATA/learnings.md" ]; then
  LEARNINGS_TOKENS=$(tokens_of_file "$DATA/learnings.md")
  NOTICES+=("MEMORY_NOTICE: data/learnings.md is still present (${LEARNINGS_TOKENS} estimated tokens) and is NOT injected. Migrate it into notes with bin/fm-memory-migrate.sh, or read it directly when a turn needs it.")
fi

# Precedence under pressure: core, then catalog, then hot notes.
TOTAL=$CORE_TOKENS
CORE_OVER=0
CATALOG_KEPT=1
if ! fm_startup_memory_decimal_le "$TOTAL" "$BUDGET"; then
  CORE_OVER=1
  CATALOG_KEPT=0
elif ! fm_startup_memory_decimal_le "$((TOTAL + CATALOG_TOKENS))" "$BUDGET"; then
  CATALOG_KEPT=0
else
  TOTAL=$((TOTAL + CATALOG_TOKENS))
fi

HOT_KEPT=0
HOT_DROPPED=0
HOT_TOKENS=0
line=
: > "$TMP/selected"
if [ "$CORE_OVER" -eq 0 ] && [ "$CATALOG_KEPT" -eq 1 ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    line=${line#*"$TAB"}
    base=${line%%"$TAB"*}
    note_tokens=${line#*"$TAB"}
    case "$note_tokens" in ''|*[!0-9]*) note_tokens=0 ;; esac
    if fm_startup_memory_decimal_le "$((TOTAL + note_tokens))" "$BUDGET"; then
      TOTAL=$((TOTAL + note_tokens))
      HOT_TOKENS=$((HOT_TOKENS + note_tokens))
      HOT_KEPT=$((HOT_KEPT + 1))
      printf '%s\n' "$base" >> "$TMP/selected"
    else
      HOT_DROPPED=$((HOT_DROPPED + 1))
    fi
  done < "$TMP/hot"
else
  HOT_DROPPED=$(wc -l < "$TMP/hot" | tr -d ' ')
fi

# --- bundle -----------------------------------------------------------------

RULE='--------------------------------------------------------------------------------'

printf 'COMPILED WORKING MEMORY (data/memory)\n%s\n' "$RULE"
cat <<EOF
Compiled by bin/fm-memory-compile.sh against a ${BUDGET}-estimated-token cap.
This is the whole startup memory surface: it is selected and capped, not dumped.
The catalog lists every note that exists, so when a title below matches what
this turn needs and its body was not injected, read that file by its path.
EOF

printf '\ncore: %s\n%s\n' "${CORE_LABEL:-ABSENT}" "$RULE"
if [ -n "$CORE_PATH" ]; then
  if [ -s "$CORE_PATH" ]; then
    cat "$CORE_PATH"
  else
    printf '(present, empty)\n'
  fi
else
  printf 'ABSENT\n'
fi

if [ "$CORE_OVER" -eq 1 ]; then
  printf '\nMEMORY_BUDGET_WARNING: the core alone is %s estimated tokens against a %s budget. It was printed in full and NOTHING else was: no catalog, no notes. Trim the core (data/memory/core.md, or data/captain.md when no core.md exists) or raise config/startup-memory-budget.\n' \
    "$CORE_TOKENS" "$BUDGET"
elif [ "$CATALOG_KEPT" -eq 0 ]; then
  printf '\nMEMORY_BUDGET_WARNING: the core plus catalog is %s estimated tokens against a %s budget, so the catalog and every note were dropped. Trim the core or raise config/startup-memory-budget; until then this session cannot see what notes exist.\n' \
    "$((CORE_TOKENS + CATALOG_TOKENS))" "$BUDGET"
else
  printf '\ncatalog (compiled from data/memory/notes/)\n%s\n' "$RULE"
  cat "$TMP/catalog"

  while IFS= read -r base; do
    [ -n "$base" ] || continue
    printf '\nhot note: notes/%s\n%s\n' "$base" "$RULE"
    cat "$NOTES_DIR/$base"
  done < "$TMP/selected"

  if [ "$HOT_DROPPED" -gt 0 ]; then
    printf '\nMEMORY_BUDGET_NOTICE: %s trigger-matched note(s) did not fit the budget and were not injected. Every one of them is still listed in the catalog above; read it by path when its title matches.\n' \
      "$HOT_DROPPED"
  fi
fi

for notice in "${NOTICES[@]-}"; do
  [ -n "$notice" ] || continue
  printf '\n%s\n' "$notice"
done

# One status word for the whole compile: over-budget means the core alone did
# not fit and is the only thing printed, capped means everything printed fits
# but content was dropped to make it fit, and within-budget means nothing was
# dropped at all.
STATUS=within-budget
if [ "$CORE_OVER" -eq 1 ]; then
  STATUS=over-budget
elif [ "$CATALOG_KEPT" -eq 0 ] || [ "$HOT_DROPPED" -gt 0 ]; then
  STATUS=capped
fi

printf '\nMEMORY_ACCOUNTING: budget=%s core=%s catalog=%s hot_notes=%s hot_notes_tokens=%s notes_total=%s hot_dropped=%s injected_total=%s status=%s\n' \
  "$BUDGET" "$CORE_TOKENS" \
  "$([ "$CATALOG_KEPT" -eq 1 ] && printf '%s' "$CATALOG_TOKENS" || printf '0')" \
  "$HOT_KEPT" "$HOT_TOKENS" \
  "$(wc -l < "$TMP/inventory" | tr -d ' ')" \
  "$HOT_DROPPED" "$TOTAL" "$STATUS"

exit 0
