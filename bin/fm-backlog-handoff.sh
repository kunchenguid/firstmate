#!/usr/bin/env bash
# Hand already-identified, in-scope backlog items off from the main firstmate
# backlog to a secondmate's own home backlog. Use this when a secondmate is
# created (or whenever an existing queued item should become its domain's work)
# so the secondmate owns its queue from day one instead of the item staying
# stranded in the main backlog.
#
# Scope-matching is firstmate's JUDGMENT: you pass the task-id keys you have
# already judged in-scope for the secondmate. This script performs only the
# mechanical move - it removes each matched line from data/backlog.md under the
# active firstmate home and appends it, under the same section heading, to the
# secondmate home's data/backlog.md (home resolved from data/secondmates.md). It
# never changes a line's text, never writes into a project (it refuses a home
# that is not a firstmate home), and is idempotent: a key already present in the
# secondmate backlog is reported and skipped, so re-running converges. If any key
# matches neither backlog, nothing is moved. See AGENTS.md sections 6-7.
# Usage: fm-backlog-handoff.sh <secondmate-id> <item-key>...
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/secondmates.md"
MAIN_BACKLOG="$DATA/backlog.md"

[ $# -ge 2 ] || { echo "usage: fm-backlog-handoff.sh <secondmate-id> <item-key>..." >&2; exit 1; }
ID=$1
shift

secondmate_home() {
  local id=$1 line
  [ -f "$REG" ] || { echo "error: no secondmate registry at $REG" >&2; return 1; }
  line=$(grep -E "^- $id( |$)" "$REG" | tail -1 || true)
  [ -n "$line" ] || { echo "error: secondmate $id is not registered in $REG" >&2; return 1; }
  printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p'
}

# A backlog task line is "- [ ] <id> - ..." or "- [x] <id> - ..."; the key is the
# first whitespace-delimited token after the checkbox.
backlog_has_key() {
  local file=$1 key=$2
  [ -f "$file" ] || return 1
  awk -v key="$key" '
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (id == key) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

RAW_HOME=$(secondmate_home "$ID") || exit 1
[ -n "$RAW_HOME" ] || { echo "error: secondmate $ID has no home in $REG" >&2; exit 1; }
[ -d "$RAW_HOME" ] || { echo "error: secondmate home does not exist or is not a directory: $RAW_HOME" >&2; exit 1; }
SUB_HOME=$(cd "$RAW_HOME" && pwd -P)
# A move may only land in a genuine seeded secondmate home. The .fm-secondmate-home
# marker is that home's authoritative signal (projects never carry it), and its id
# must match, so a move can never write into a project or the wrong home.
SUB_MARKER="$SUB_HOME/.fm-secondmate-home"
[ -f "$SUB_MARKER" ] || { echo "error: $SUB_HOME is not a seeded secondmate home (missing .fm-secondmate-home marker); refusing to write its backlog" >&2; exit 1; }
MARKER_ID=$(cat "$SUB_MARKER" 2>/dev/null || true)
[ "$MARKER_ID" = "$ID" ] || { echo "error: $SUB_HOME is marked for secondmate '${MARKER_ID:-unknown}', not '$ID'; refusing to write its backlog" >&2; exit 1; }
SUB_BACKLOG="$SUB_HOME/data/backlog.md"

# Classify every key before changing anything: move-from-main, already-in-sub, or
# missing. Abort with no changes if any key matches neither backlog.
TO_MOVE=()
ALREADY=()
MISSING=()
for key in "$@"; do
  if backlog_has_key "$SUB_BACKLOG" "$key"; then
    ALREADY+=("$key")
  elif backlog_has_key "$MAIN_BACKLOG" "$key"; then
    TO_MOVE+=("$key")
  else
    MISSING+=("$key")
  fi
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "error: no backlog item matched these keys in $MAIN_BACKLOG: ${MISSING[*]}" >&2
  echo "       nothing was moved." >&2
  exit 1
fi

if [ "${#TO_MOVE[@]}" -eq 0 ]; then
  echo "nothing to move: ${ALREADY[*]:-no keys} already present in $SUB_BACKLOG"
  exit 0
fi

mkdir -p "$SUB_HOME/data"
if [ ! -f "$SUB_BACKLOG" ]; then
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$SUB_BACKLOG"
fi

KEYS_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-handoff-keys.XXXXXX")
MOVED_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-handoff-moved.XXXXXX")
KEPT_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-handoff-kept.XXXXXX")
SUB_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-handoff-sub.XXXXXX")
cleanup() { rm -f "$KEYS_FILE" "$MOVED_FILE" "$KEPT_FILE" "$SUB_TMP"; }
trap cleanup EXIT
printf '%s\n' "${TO_MOVE[@]}" > "$KEYS_FILE"

# Pass 1: drop the matched lines from the main backlog, capturing each removed
# line tagged with the "## " section heading it lived under.
: > "$MOVED_FILE"
awk -v keysfile="$KEYS_FILE" -v movedfile="$MOVED_FILE" '
  BEGIN {
    while ((getline k < keysfile) > 0) { if (k != "") want[k] = 1 }
    section = "## Queued"
  }
  /^## / { section = $0; print; next }
  /^- \[[ x]\] / {
    rest = $0
    sub(/^- \[[ x]\] +/, "", rest)
    id = rest
    sub(/[ \t].*/, "", id)
    if (id in want) { print section "\t" $0 > movedfile; next }
  }
  { print }
' "$MAIN_BACKLOG" > "$KEPT_FILE"

# Pass 2: insert each moved line at the end of its section in the sub backlog,
# creating the section heading if the sub backlog lacks it.
awk -v movedfile="$MOVED_FILE" '
  function flush(sec) {
    if (sec != "" && (sec in items) && !(sec in flushed)) {
      printf "%s", items[sec]
      flushed[sec] = 1
    }
  }
  BEGIN {
    nsec = 0
    while ((getline rec < movedfile) > 0) {
      tab = index(rec, "\t")
      if (tab == 0) continue
      sec = substr(rec, 1, tab - 1)
      line = substr(rec, tab + 1)
      if (!(sec in items)) { order[++nsec] = sec }
      items[sec] = items[sec] line "\n"
    }
    cur = ""
  }
  /^## / { flush(cur); cur = $0; print; next }
  { print }
  END {
    flush(cur)
    for (i = 1; i <= nsec; i++) {
      s = order[i]
      if (!(s in flushed)) {
        print ""
        print s
        printf "%s", items[s]
        flushed[s] = 1
      }
    }
  }
' "$SUB_BACKLOG" > "$SUB_TMP"

mv "$KEPT_FILE" "$MAIN_BACKLOG"
mv "$SUB_TMP" "$SUB_BACKLOG"

echo "handed off ${#TO_MOVE[@]} item(s) to $ID: ${TO_MOVE[*]}"
echo "  into $SUB_BACKLOG"
if [ "${#ALREADY[@]}" -gt 0 ]; then
  echo "  already present (skipped): ${ALREADY[*]}"
fi
