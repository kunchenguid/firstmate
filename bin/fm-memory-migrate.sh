#!/usr/bin/env bash
# fm-memory-migrate.sh - split data/learnings.md into atomic notes under
# data/memory/notes/, then freeze and archive the original.
#
# Usage:
#   fm-memory-migrate.sh [--dry-run] [--keep-learnings]
#   fm-memory-migrate.sh -h | --help
#
# One `## ` heading in data/learnings.md becomes one note, because that is the
# grain the file already had; a heading is a claim and its body is the evidence
# for that claim.  The split is entirely mechanical.  It does not rewrite a
# claim, merge two claims, or invent a better title, so nothing here can quietly
# change what the fleet believes.
#
# WHAT EACH NOTE GETS.  A front matter block bin/fm-memory-compile.sh reads:
#   title:    the heading text, with its tier marker stripped
#   triggers: match terms derived from the heading (see TRIGGERS below)
#   updated:  the date in the heading's `<!--a:YYYY-MM-DD-->` marker, or a
#             leading `YYYY-MM-DD - ` or trailing `(YYYY-MM-DD)` in the heading,
#             or empty when the entry carried none of the three
#   tier:     the raw stow tier marker (`<!--g-->`, `<!--P-->`, ...) when the
#             entry carried one, so the stow skill's scheme survives the move
#   source:   data/learnings.md, as provenance for the claim
#
# TRIGGERS.  Derived from the heading only, and deliberately SPECIFIC: every
# backticked identifier, every compound identifier carrying a dash, dot or
# underscore, and every mid-heading proper noun, lowercased, deduplicated, and
# capped at six.  Ordinary long words are not triggers, because `agent`, `test`
# and `check` appear in almost every backlog and would make almost every note
# hot - which spends the whole budget without telling a session anything.  A
# note that yields no trigger is never hot and is still in the catalog, which is
# what tells the next turn it exists.  This is a mechanical first draft, not a
# judgement: triggers are the one field worth revising by hand, because they
# decide which notes a session actually sees.
#
# IDEMPOTENT.  An existing note file is never overwritten and never re-derived;
# it is reported as kept.  Re-running after hand-editing triggers is safe.
#
# HISTORY IS NEVER DELETED.  Before data/learnings.md is removed, the run
# writes the whole original to data/memory/raw/learnings-<YYYY-MM-DD>.md and
# appends it to data/memory-archive.md under a dated banner, and it verifies
# both landed first.  --keep-learnings skips the removal entirely; note that
# bin/fm-memory-compile.sh then keeps reporting the file as present and not
# injected, which is the correct warning while two copies exist.
#
# NOT MIGRATED: data/captain.md.  Splitting standing preferences from this
# shift's operating picture is a judgement about what the captain still means,
# not a mechanical split, and a script that copied captain.md to
# data/memory/core.md would create two owners of standing preferences that
# drift the moment the captain states one.  The compiler already uses
# data/captain.md as the core while data/memory/core.md is absent, so a home
# that never writes core.md loses nothing by waiting.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
MEMORY="$DATA/memory"
NOTES_DIR="$MEMORY/notes"
RAW_DIR="$MEMORY/raw"
DROP_DIR="$MEMORY/drop"
LEARNINGS="$DATA/learnings.md"
ARCHIVE="$DATA/memory-archive.md"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  printf 'fm-memory-migrate: %s\n' "$1" >&2
  exit 1
}

DRY_RUN=0
KEEP_LEARNINGS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --keep-learnings) KEEP_LEARNINGS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

TODAY=${FM_MEMORY_MIGRATE_DATE:-$(date -u +%Y-%m-%d)}
case "$TODAY" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) die "invalid migration date: $TODAY" ;;
esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/.fm-memory-migrate.XXXXXX") || die 'could not create a working directory'
# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# The layout itself is the first deliverable: a home with the directories but no
# notes yet is a valid, compilable home.
if [ "$DRY_RUN" -eq 0 ]; then
  for dir in "$MEMORY" "$NOTES_DIR" "$DROP_DIR"; do
    [ -d "$dir" ] || mkdir -p "$dir" || die "could not create $dir"
  done
  if [ ! -e "$DROP_DIR/README.md" ]; then
    cat > "$DROP_DIR/README.md" <<'DROP'
# Drop tray

Candidate claims land here. One file per claim, no format required.

Nothing in this directory is ever injected into a session: `bin/fm-memory-compile.sh`
ignores it by design, so leaving a claim here is free and cannot change what any
session reads. A later curation pass promotes what survives into
`data/memory/notes/` and drops the rest.
DROP
  fi
fi

if [ ! -f "$LEARNINGS" ] || [ -L "$LEARNINGS" ]; then
  printf 'migrate: data/learnings.md is absent - the data/memory/ layout is in place and there is nothing to split.\n'
  exit 0
fi

# --- split ------------------------------------------------------------------

# Each heading becomes one record file in $TMP/parts, named by index so the
# original order is preserved and a duplicate slug can be disambiguated.
mkdir -p "$TMP/parts"
awk -v out="$TMP/parts" '
  /^## / {
    n++
    file = sprintf("%s/%04d", out, n)
    print $0 > file
    next
  }
  n > 0 { print $0 >> file }
' "$LEARNINGS"

# A literal backtick, built rather than quoted so the sed and grep patterns
# below stay free of shell quoting hazards.
BACKTICK=$(printf '\140')

# slugify <text>: lowercase, non-alphanumeric collapsed to single dashes,
# trimmed, bounded to 60 characters so a long heading still yields a readable
# file name.
slugify() {
  printf '%s\n' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | tr -d "$BACKTICK" | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' \
    | cut -c1-60 | sed -e 's/-$//'
}

# Sentence-start and connective words that look like proper nouns once a
# heading capitalises them.  A trigger drawn from one of these matches almost
# every session, which is the same as having no trigger at all.
STOPWORDS=' that this with from when what which have been will they their there
 into over under only never always your ours than then them those these ever
 more most less some such very just also does done make made take takes
 without within about after before because while where whose whom here
 captain worker runs run every each once still even both single
 rebasing telling suspect parallel mutation crewmate pipeline environmental '

# triggers_for <heading>: SPECIFIC terms only, in descending specificity -
# backticked identifiers, then compound identifiers (a token carrying `-`, `_`
# or `.`), then proper nouns.  Ordinary long words are deliberately NOT
# triggers: `agent`, `test`, `host` and `check` appear in nearly every backlog
# and would make almost every note hot, which spends the budget without telling
# a session anything it did not already have.  A note that yields no trigger is
# never hot, and that is a correct outcome: it is still in the catalog, which is
# what tells the next turn it exists.
triggers_for() {
  local heading=$1 out=() token seen
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    [ "${#token}" -ge 3 ] || continue
    out+=("$token")
  done < <(printf '%s\n' "$heading" \
    | grep -o "${BACKTICK}[^${BACKTICK}]\{1,\}${BACKTICK}" 2>/dev/null \
    | tr -d "$BACKTICK" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9._-]\{1,\}/ /g' | tr ' ' '\n')

  # Compound identifiers outside backticks: no-mistakes, chrome-devtools-axi,
  # pytest-xvfb, n_live_tup.
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    [ "${#token}" -ge 4 ] || continue
    case "$token" in *[-._]*) ;; *) continue ;; esac
    case "$token" in [0-9]*) continue ;; esac
    out+=("$token")
  done < <(printf '%s\n' "$heading" \
    | sed -e "s/${BACKTICK}[^${BACKTICK}]*${BACKTICK}//g" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9._-]\{1,\}/ /g' | tr ' ' '\n')

  # Proper nouns: a capitalised word with at least one lowercase letter after
  # it, so Healthlog and VoiceMaster qualify and PR and CI do not.  A heading
  # capitalises its first word whatever that word is, so the stopword list above
  # is what keeps `Never`, `Rebasing` and `Suspect` from becoming triggers that
  # match every session.
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    case "$token" in
      [A-Z]*[a-z]*) ;;
      *) continue ;;
    esac
    [ "${#token}" -ge 4 ] || continue
    token=$(printf '%s\n' "$token" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    # The stopword test also tries the singular, so `Crewmates` is rejected by
    # the `crewmate` entry - but the TRIGGER keeps its original spelling,
    # because matching is whole-token and a stemmed `window` would stop
    # matching the `windows` it came from.
    case "$STOPWORDS" in
      *" $token "*|*" ${token%s} "*) continue ;;
    esac
    out+=("$token")
  done < <(printf '%s\n' "$heading" \
    | sed -e "s/${BACKTICK}[^${BACKTICK}]*${BACKTICK}//g" \
    | sed -e 's/[^A-Za-z0-9]\{1,\}/ /g' | tr ' ' '\n')

  seen=' '
  local kept=0 result=
  for token in "${out[@]-}"; do
    [ -n "$token" ] || continue
    case "$seen" in *" $token "*) continue ;; esac
    seen="$seen$token "
    result="${result:+$result, }$token"
    kept=$((kept + 1))
    [ "$kept" -lt 6 ] || break
  done
  printf '%s\n' "$result"
}

CREATED=0
KEPT=0
TOTAL_HEADINGS=0
: > "$TMP/report"
mkdir -p "$TMP/claimed"

for part in "$TMP/parts"/*; do
  [ -f "$part" ] || continue
  TOTAL_HEADINGS=$((TOTAL_HEADINGS + 1))
  heading=$(head -n 1 "$part")
  heading=${heading#\#\# }

  tier=$(printf '%s\n' "$heading" | grep -o '<!--[^>]*-->' | head -n 1 || true)
  updated=
  case "$tier" in
    '<!--a:'[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'-->')
      updated=${tier#<!--a:}
      updated=${updated%-->}
      ;;
  esac

  title=$heading
  title=${title%%<!--*}
  title=$(printf '%s\n' "$title" | sed -e 's/[[:space:]]\{1,\}$//')
  case "$title" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' - '*)
      [ -n "$updated" ] || updated=${title%% - *}
      ;;
    *'('[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]')')
      if [ -z "$updated" ]; then
        updated=${title##*(}
        updated=${updated%)}
      fi
      ;;
  esac

  slug=$(slugify "$title")
  [ -n "$slug" ] || slug="note-$(basename "$part")"

  candidate_slug="$slug"
  suffix=1
  while [ -f "$TMP/claimed/$candidate_slug" ]; do
    suffix=$((suffix + 1))
    candidate_slug="${slug}-${suffix}"
  done
  touch "$TMP/claimed/$candidate_slug"
  slug="$candidate_slug"

  target="$NOTES_DIR/$slug.md"
  if [ -e "$target" ] || [ -L "$target" ]; then
    if [ ! -f "$target" ] || [ -L "$target" ]; then
      die "refusing to overwrite non-regular file or symlink: $target"
    fi
    KEPT=$((KEPT + 1))
    printf 'kept    notes/%s.md\n' "$slug" >> "$TMP/report"
    continue
  fi

  triggers=$(triggers_for "$title")

  {
    printf -- '---\n'
    printf 'title: %s\n' "$title"
    printf 'triggers: %s\n' "$triggers"
    printf 'updated: %s\n' "$updated"
    [ -z "$tier" ] || printf 'tier: %s\n' "$tier"
    printf 'source: data/learnings.md\n'
    printf -- '---\n\n'
    printf '# %s\n' "$title"
    tail -n +2 "$part"
  } > "$TMP/note"

  CREATED=$((CREATED + 1))
  printf 'created notes/%s.md\n' "$slug" >> "$TMP/report"
  [ "$DRY_RUN" -eq 1 ] || cp "$TMP/note" "$target" || die "could not write $target"
done

cat "$TMP/report"
printf 'migrate: %s note(s) created, %s already present\n' "$CREATED" "$KEPT"

if [ "$TOTAL_HEADINGS" -eq 0 ]; then
  die 'refusing to remove data/learnings.md: no headings were found to migrate'
fi
if [ "$((CREATED + KEPT))" -ne "$TOTAL_HEADINGS" ]; then
  die "refusing to remove data/learnings.md: only $((CREATED + KEPT)) of $TOTAL_HEADINGS headings were accounted for"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'migrate: --dry-run, nothing was written and data/learnings.md was not touched\n'
  exit 0
fi

for claimed_file in "$TMP/claimed"/*; do
  [ -f "$claimed_file" ] || continue
  c_slug=$(basename "$claimed_file")
  c_target="$NOTES_DIR/$c_slug.md"
  if [ ! -f "$c_target" ] || [ -L "$c_target" ]; then
    die "refusing to remove data/learnings.md: expected note notes/$c_slug.md is missing or not a regular file"
  fi
done

# --- catalog ----------------------------------------------------------------

"$SCRIPT_DIR/fm-memory-compile.sh" catalog

# --- freeze and archive the original ---------------------------------------

[ -d "$RAW_DIR" ] || mkdir -p "$RAW_DIR" || die "could not create $RAW_DIR"
FROZEN="$RAW_DIR/learnings-$TODAY.md"
if [ -e "$FROZEN" ] || [ -L "$FROZEN" ]; then
  printf 'migrate: %s already exists; the original was frozen by an earlier run\n' \
    "data/memory/raw/learnings-$TODAY.md"
else
  cp "$LEARNINGS" "$FROZEN" || die "could not freeze the original at $FROZEN"
  cmp -s "$LEARNINGS" "$FROZEN" || die 'frozen copy does not match data/learnings.md'
  printf 'migrate: froze the original at data/memory/raw/learnings-%s.md\n' "$TODAY"
fi

BANNER="<!-- archived from data/learnings.md by bin/fm-memory-migrate.sh on $TODAY -->"
if [ -e "$ARCHIVE" ] && [ ! -f "$ARCHIVE" ]; then
  die 'data/memory-archive.md is not an ordinary regular file'
fi
if [ -f "$ARCHIVE" ] && grep -qF "$BANNER" "$ARCHIVE"; then
  printf 'migrate: data/memory-archive.md already carries this run banner\n'
else
  {
    printf '\n%s\n\n' "$BANNER"
    cat "$LEARNINGS"
  } >> "$ARCHIVE" || die 'could not append to data/memory-archive.md'
  grep -qF "$BANNER" "$ARCHIVE" || die 'archive append did not land'
  printf 'migrate: appended the original to data/memory-archive.md\n'
fi

if [ "$KEEP_LEARNINGS" -eq 1 ]; then
  printf 'migrate: --keep-learnings, data/learnings.md left in place\n'
  exit 0
fi

# Removal happens only after both durable copies are verified on disk.
if [ ! -f "$FROZEN" ] || ! cmp -s "$LEARNINGS" "$FROZEN"; then
  die 'refusing to remove data/learnings.md: the frozen copy is missing or differs'
fi
grep -qF "$BANNER" "$ARCHIVE" \
  || die 'refusing to remove data/learnings.md: the archive banner is missing'
rm -f "$LEARNINGS" || die 'could not remove data/learnings.md'
printf 'migrate: removed data/learnings.md (frozen at data/memory/raw/learnings-%s.md and archived in data/memory-archive.md)\n' "$TODAY"
