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
# matches neither backlog, nothing is moved. See AGENTS.md project management
# and task lifecycle.
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

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

validate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

validate_secondmate_home() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/.fm-secondmate-home" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/.fm-secondmate-home" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_backlog_file() {
  local label=$1 path=$2
  if [ -L "$path" ]; then
    echo "error: $label must not be a symlink: $path" >&2
    return 1
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    echo "error: $label is not a regular file: $path" >&2
    return 1
  fi
}

backlog_key_section() {
  local file=$1 key=$2
  [ -f "$file" ] || return 1
  awk -v key="$key" '
    BEGIN { section = "## Queued" }
    /^## / { section = $0; next }
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (id == key) { print section; found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

RAW_HOME=$(secondmate_home "$ID") || exit 1
[ -n "$RAW_HOME" ] || { echo "error: secondmate $ID has no home in $REG" >&2; exit 1; }
SUB_HOME=$(validate_secondmate_home "$ID" "$RAW_HOME") || exit 1
SUB_BACKLOG="$SUB_HOME/data/backlog.md"
validate_backlog_file "main backlog" "$MAIN_BACKLOG" || exit 1
validate_backlog_file "secondmate backlog" "$SUB_BACKLOG" || exit 1

# Classify every key before changing anything: move-from-main, already-in-sub, or
# missing. Abort with no changes if any key matches neither backlog.
TO_MOVE=()
ALREADY=()
MISSING=()
IN_FLIGHT=()
for key in "$@"; do
  if backlog_key_section "$SUB_BACKLOG" "$key" >/dev/null; then
    ALREADY+=("$key")
  elif section=$(backlog_key_section "$MAIN_BACKLOG" "$key"); then
    if [ "$section" = "## In flight" ]; then
      IN_FLIGHT+=("$key")
    else
      TO_MOVE+=("$key")
    fi
  else
    MISSING+=("$key")
  fi
done

FAILED=0
if [ "${#IN_FLIGHT[@]}" -gt 0 ]; then
  echo "error: refusing to hand off in-flight backlog items: ${IN_FLIGHT[*]}" >&2
  FAILED=1
fi
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "error: no backlog item matched these keys in $MAIN_BACKLOG: ${MISSING[*]}" >&2
  FAILED=1
fi
if [ "$FAILED" -ne 0 ]; then
  echo "       nothing was moved." >&2
  exit 1
fi

if [ "${#TO_MOVE[@]}" -eq 0 ]; then
  echo "nothing to move: ${ALREADY[*]:-no keys} already present in $SUB_BACKLOG"
  exit 0
fi

mkdir -p "$SUB_HOME/data"
SUB_EXISTED=0
if [ ! -f "$SUB_BACKLOG" ]; then
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$SUB_BACKLOG"
else
  SUB_EXISTED=1
fi

MAIN_DIR=$(dirname "$MAIN_BACKLOG")
SUB_DIR=$(dirname "$SUB_BACKLOG")
KEYS_FILE=$(mktemp "$MAIN_DIR/.fm-handoff-keys.XXXXXX")
MOVED_FILE=$(mktemp "$MAIN_DIR/.fm-handoff-moved.XXXXXX")
KEPT_FILE=$(mktemp "$MAIN_DIR/.fm-handoff-kept.XXXXXX")
SUB_TMP=$(mktemp "$SUB_DIR/.fm-handoff-sub.XXXXXX")
MAIN_BAK=$(mktemp "$MAIN_DIR/.fm-handoff-main-bak.XXXXXX")
SUB_BAK=$(mktemp "$SUB_DIR/.fm-handoff-sub-bak.XXXXXX")
CHANGES_STARTED=0
COMMITTED=0
cleanup() {
  if [ "$CHANGES_STARTED" -eq 1 ] && [ "$COMMITTED" -eq 0 ]; then
    cp "$MAIN_BAK" "$MAIN_BACKLOG" 2>/dev/null || true
    if [ "$SUB_EXISTED" -eq 1 ]; then
      cp "$SUB_BAK" "$SUB_BACKLOG" 2>/dev/null || true
    else
      rm -f "$SUB_BACKLOG"
    fi
  fi
  rm -f "$KEYS_FILE" "$MOVED_FILE" "$KEPT_FILE" "$SUB_TMP" "$MAIN_BAK" "$SUB_BAK"
}
trap cleanup EXIT
printf '%s\n' "${TO_MOVE[@]}" > "$KEYS_FILE"
cp "$MAIN_BACKLOG" "$MAIN_BAK"
if [ "$SUB_EXISTED" -eq 1 ]; then
  cp "$SUB_BACKLOG" "$SUB_BAK"
fi

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

CHANGES_STARTED=1
mv "$SUB_TMP" "$SUB_BACKLOG"
mv "$KEPT_FILE" "$MAIN_BACKLOG"
COMMITTED=1

echo "handed off ${#TO_MOVE[@]} item(s) to $ID: ${TO_MOVE[*]}"
echo "  into $SUB_BACKLOG"
if [ "${#ALREADY[@]}" -gt 0 ]; then
  echo "  already present (skipped): ${ALREADY[*]}"
fi
