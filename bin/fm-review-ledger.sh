#!/usr/bin/env bash
# The coverage ledger that lets a tending pass (/code-shape, /docs-sync) review a
# project a bounded slice at a time instead of all at once, and never re-review a
# slice that has not moved since its last clean pass.
# Ledgers live at data/reviews/<project>/<track>.md under the active firstmate
# home, one row per reviewed unit (the unit, the commit it was reviewed at, the
# date, and a one-line verdict). They are firstmate-private (data/ is gitignored),
# because what firstmate has reviewed for the user is the user's operational
# record, not the project's. <track> is codebase or docs.
# Selection is git-based against the stored commit and time-based against the 
# review date: a unit that has not moved and has not expired is skipped. A unit 
# that has moved, has untracked changes, or has exceeded its TTL (FM_LEDGER_TTL_DAYS) 
# is a candidate. Units are then greedily filled into one bounded run by an 
# estimated-token budget.
# Usage: fm-review-ledger.sh select <project> <track> [--paths]
#              print the next slice to review and why, within the token budget.
#              --paths prints only the selected git pathspecs (one per line), for
#              feeding a brief; default mode also prints head=<sha> and reasons.
#              Prints NOTHING_TO_REVIEW and exits 0 when every unit is covered and
#              unchanged. Exits non-zero only on a real error (bad project/track).
#        fm-review-ledger.sh record <project> <track> <unit> --sha <sha> --verdict <text>
#              mark a unit reviewed at <sha> with a one-line verdict (e.g. a PR
#              url, or "clean" when the slice needed no change). Replaces any prior
#              row for that unit; the file stays sorted by unit for stable diffs.
#        fm-review-ledger.sh status <project> <track>
#              coverage and staleness overview across every current unit, plus any
#              ledger row whose unit no longer exists (ORPHAN).
#        fm-review-ledger.sh units <project> <track>
#              print the current unit set (auto-derived, or the override), one per
#              line, for debugging a selection.
# Units: by default a unit is each top-level tracked directory of the project,
# plus a synthetic <root> unit covering the top-level tracked files. A project
# whose defaults are too coarse (or a docs track that should point at a doc tree)
# overrides them with data/reviews/<project>/<track>.units, one pathspec per line.
# Budget: the run is capped by an estimated token count (FM_LEDGER_TOKEN_CAP,
# default 25000), estimated as source bytes / 4. At least one unit is always
# selected; a single unit larger than the cap is selected alone and flagged.
# Robustness: a stored sha stops being an ancestor of HEAD after a history
# rewrite; selection then falls back to the stored date (git log --since), so a
# rebase degrades selection instead of breaking it.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

TOKEN_CAP=${FM_LEDGER_TOKEN_CAP:-25000}
# Estimate source tokens as bytes / BYTES_PER_TOKEN. 4 is the usual rough ratio
# for code; it only needs to be good enough to keep a run near the cap.
BYTES_PER_TOKEN=4
ROOT_UNIT='<root>'

die() { echo "error: $*" >&2; exit 1; }

# --- paths ------------------------------------------------------------------

review_dir() { printf '%s\n' "$DATA/reviews/$1"; }
ledger_file() { printf '%s\n' "$DATA/reviews/$1/$2.md"; }
units_override() { printf '%s\n' "$DATA/reviews/$1/$2.units"; }
repo_dir() { printf '%s\n' "$PROJECTS/$1"; }

assert_track() {
  case "$1" in
    codebase|docs) : ;;
    *) die "unknown track '$1' (expected codebase or docs)" ;;
  esac
}

assert_repo() {
  local repo=$1
  [ -d "$repo/.git" ] || git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
    || die "no git repo at $repo"
}

git_r() { git -C "$REPO" "$@"; }

# --- units ------------------------------------------------------------------

# Auto units: each top-level tracked directory, plus a synthetic <root> unit when
# there are top-level tracked files. Top-level paths with spaces are skipped (with
# a warning) rather than corrupting a space-delimited pathspec; no real project
# names a top-level entry with a space.
auto_units() {
  local has_root_files=0 name type
  local -A seen=()
  while read -r type name; do
    case "$name" in
      *' '*) echo "warning: skipping top-level path with space: $name" >&2; continue ;;
    esac
    seen["$name"]=1
    if [ "$type" = tree ]; then
      printf '%s\n' "$name"
    else
      has_root_files=1
    fi
  done < <(git_r ls-tree HEAD --format='%(objecttype) %(path)')
  
  while read -r name; do
    name="${name%%/*}"
    case "$name" in *' '*) continue ;; esac
    [ -n "${seen["$name"]:-}" ] && continue
    seen["$name"]=1
    if [ -d "$REPO/$name" ]; then
      printf '%s\n' "$name"
    else
      has_root_files=1
    fi
  done < <(git_r ls-files --others --exclude-standard)

  [ "$has_root_files" -eq 1 ] && printf '%s\n' "$ROOT_UNIT"
  return 0
}

units_for() {
  local project=$1 track=$2 override
  override=$(units_override "$project" "$track")
  if [ -f "$override" ]; then
    grep -vE '^[[:space:]]*(#|$)' "$override"
    return 0
  fi
  auto_units
}

# The git pathspec(s) for a unit. The <root> unit expands to the live list of
# top-level tracked files; every other unit is its own name.
unit_pathspec() {
  local unit=$1
  if [ "$unit" = "$ROOT_UNIT" ]; then
    git_r ls-tree HEAD --format='%(objecttype) %(path)' \
      | awk '$1 == "blob" { $1=""; sub(/^ /,""); print }'
    return 0
  fi
  printf '%s\n' "$unit"
}

# Estimated tokens for a unit at HEAD: summed blob sizes / BYTES_PER_TOKEN.
unit_tokens() {
  local unit=$1 bytes
  # shellcheck disable=SC2046  # word-splitting the pathspec list is intended.
  bytes=$(git_r ls-tree -r -l HEAD -- $(unit_pathspec "$unit") 2>/dev/null \
    | awk '{ s += $4 } END { print s + 0 }')
  printf '%s\n' "$(( bytes / BYTES_PER_TOKEN ))"
}

# --- ledger read/write ------------------------------------------------------

# Emit data rows as unit<TAB>sha<TAB>date<TAB>verdict. Tolerates a missing file.
ledger_rows() {
  local f=$1
  [ -f "$f" ] || return 0
  awk -F'|' '
    /^\| *unit *\|/ { next }
    /^\| *:?-+ *\|/ { next }
    /^\|/ {
      for (i = 2; i <= 5; i++) { gsub(/^ +| +$/, "", $i) }
      print $2 "\t" $3 "\t" $4 "\t" $5
    }
  ' "$f"
}

ledger_lookup() {
  local f=$1 unit=$2
  ledger_rows "$f" | awk -F'\t' -v u="$unit" '$1 == u { print; exit }'
}

# Replace (or add) the row for <unit>, keeping the file sorted by unit.
ledger_upsert() {
  local f=$1 unit=$2 sha=$3 date=$4 verdict=$5 dir tmp
  dir=$(dirname "$f")
  mkdir -p "$dir"
  # A verdict is one line and must not contain the field delimiter.
  verdict=$(printf '%s' "$verdict" | tr '\n' ' ' | tr '|' '/')
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-ledger.XXXXXX") || die "mktemp failed"
  {
    ledger_rows "$f" | awk -F'\t' -v u="$unit" '$1 != u'
    printf '%s\t%s\t%s\t%s\n' "$unit" "$sha" "$date" "$verdict"
  } | sort -t"$(printf '\t')" -k1,1 > "$tmp.rows"

  {
    printf '# %s - %s review ledger\n' "$PROJECT" "$TRACK"
    printf '# Managed by bin/fm-review-ledger.sh. One row per reviewed unit.\n\n'
    printf '| unit | sha | date | verdict |\n'
    printf '| --- | --- | --- | --- |\n'
    awk -F'\t' '{ printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }' "$tmp.rows"
  } > "$tmp"
  mv -f "$tmp" "$f"
  rm -f "$tmp.rows"
}

# --- selection --------------------------------------------------------------

# Classify a unit against the ledger. Prints: state<TAB>touch_date<TAB>churn
#   state: never | changed | clean
#   touch_date: commit date (%cs) of the unit's most recent change, or empty
#   churn: commit count since last review (0 for never/clean)
classify_unit() {
  local unit=$1 row sha date state churn touch ttl_days dirty=0
  row=$(ledger_lookup "$LEDGER" "$unit")
  # shellcheck disable=SC2046
  touch=$(git_r log -1 --format='%cs' -- $(unit_pathspec "$unit") 2>/dev/null || true)
  if [ -z "$row" ]; then
    printf 'never\t%s\t0\n' "$touch"
    return 0
  fi
  sha=$(printf '%s\n' "$row" | cut -f2)
  date=$(printf '%s\n' "$row" | cut -f3)
  if [ -n "$sha" ] && git_r merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
    # shellcheck disable=SC2046
    churn=$(git_r rev-list --count "$sha"..HEAD -- $(unit_pathspec "$unit") 2>/dev/null || echo 0)
  else
    # History rewrite (or a missing sha): fall back to the stored date.
    # shellcheck disable=SC2046
    churn=$(git_r log --oneline --since="$date" -- $(unit_pathspec "$unit") 2>/dev/null | wc -l | tr -d ' ')
  fi
  
  if [ -n "$(git_r status --porcelain -- "$(unit_pathspec "$unit")" 2>/dev/null)" ]; then
    dirty=1
  fi
  
  ttl_days=${FM_LEDGER_TTL_DAYS:-30}
  local now then diff=0
  now=$(date +%s)
  if [ -n "$date" ] && then=$(date -d "$date" +%s 2>/dev/null); then
    diff=$(( (now - then) / 86400 ))
  fi

  if [ "${churn:-0}" -gt 0 ] || [ "$dirty" -eq 1 ]; then
    state=changed
  elif [ "$diff" -gt "$ttl_days" ]; then
    state=expired
  else
    state=clean
  fi
  printf '%s\t%s\t%s\n' "$state" "$touch" "$churn"
}

# Build the priority-ordered candidate list. Tier 1 (changed) ranked by most
# recent touch then churn; tier 2 (never reviewed) ranked by most recent touch;
# clean units are dropped (skipped). Emits: unit<TAB>state<TAB>touch<TAB>churn.
ranked_candidates() {
  local unit line state touch churn
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    line=$(classify_unit "$unit")
    state=$(printf '%s\n' "$line" | cut -f1)
    touch=$(printf '%s\n' "$line" | cut -f2)
    churn=$(printf '%s\n' "$line" | cut -f3)
    case "$state" in
      changed) printf '1\t%s\t%s\t%s\t%s\n' "$touch" "$churn" "$unit" "$state" ;;
      expired) printf '2\t%s\t%s\t%s\t%s\n' "$touch" "$churn" "$unit" "$state" ;;
      never)   printf '3\t%s\t%s\t%s\t%s\n' "$touch" "$churn" "$unit" "$state" ;;
      clean)   : ;;
    esac
  done < <(units_for "$PROJECT" "$TRACK")
  # Sort by tier asc, then touch date desc, then churn desc.
}

cmd_select() {
  local paths_only=0
  case "${3:-}" in
    --paths) paths_only=1 ;;
    '') : ;;
    *) die "select: unknown option '${3:-}'" ;;
  esac

  local head candidates chosen_units="" chosen_tokens=0 any=0
  head=$(git_r rev-parse HEAD)
  candidates=$(ranked_candidates | sort -t"$(printf '\t')" -k1,1n -k2,2r -k3,3nr)

  if [ -z "$candidates" ]; then
    [ "$paths_only" -eq 1 ] || echo "NOTHING_TO_REVIEW: every unit is covered and unchanged (head $head)"
    return 0
  fi

  local tier touch churn unit state tokens reason
  # shellcheck disable=SC2034  # tier is consumed by the sort key, not the body.
  while IFS="$(printf '\t')" read -r tier touch churn unit state; do
    [ -n "$unit" ] || continue
    tokens=$(unit_tokens "$unit")
    # Greedy budget fill: always take the first unit; stop before a unit that
    # would push the run over the cap. A lone oversized first unit is flagged.
    if [ "$any" -eq 1 ] && [ $(( chosen_tokens + tokens )) -gt "$TOKEN_CAP" ]; then
      continue
    fi
    any=1
    chosen_tokens=$(( chosen_tokens + tokens ))
    chosen_units="$chosen_units$unit"$'\n'
    if [ "$paths_only" -eq 0 ]; then
      case "$state" in
        changed) reason="changed since review ($churn commit(s), last touched $touch)" ;;
        expired) reason="expired (last reviewed > ${FM_LEDGER_TTL_DAYS:-30} days ago)" ;;
        never)   reason="never reviewed (last touched ${touch:-unknown})" ;;
      esac
      local flag=""
      [ "$tokens" -gt "$TOKEN_CAP" ] && flag=" [OVERSIZED - crew must sub-scope]"
      printf '  %s\treason=%s\t~%s tokens%s\n' "$unit" "$reason" "$tokens" "$flag" >> "$SELECT_BODY"
    fi
  done <<EOF
$candidates
EOF

  if [ "$paths_only" -eq 1 ]; then
    printf '%s' "$chosen_units" | while IFS= read -r unit; do
      [ -n "$unit" ] || continue
      unit_pathspec "$unit"
    done
    return 0
  fi

  printf 'SELECTED (track=%s project=%s head=%s budget=%s tokens chosen=~%s tokens)\n' \
    "$TRACK" "$PROJECT" "$head" "$TOKEN_CAP" "$chosen_tokens"
  cat "$SELECT_BODY"
  echo "next: scope a $TRACK crew to the unit(s) above; record each at the merge sha after it lands."
}

# --- record -----------------------------------------------------------------

cmd_record() {
  local unit=${1:-} sha="" verdict=""
  shift || true
  [ -n "$unit" ] || die "record needs a unit"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --sha) sha=${2:-}; shift 2 ;;
      --verdict) verdict=${2:-}; shift 2 ;;
      *) die "record: unknown option '$1'" ;;
    esac
  done
  [ -n "$sha" ] || die "record needs --sha"
  [ -n "$verdict" ] || die "record needs --verdict"
  local date=${FM_LEDGER_DATE:-$(date +%F)}
  ledger_upsert "$LEDGER" "$unit" "$sha" "$date" "$verdict"
  echo "recorded: $unit at $sha ($date) - $verdict"
}

# --- status -----------------------------------------------------------------

cmd_status() {
  local total=0 reviewed=0 changed=0 expired=0 never=0 unit line state
  local -A seen=()
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    seen["$unit"]=1
    total=$(( total + 1 ))
    line=$(classify_unit "$unit")
    state=$(printf '%s\n' "$line" | cut -f1)
    local row date sha
    row=$(ledger_lookup "$LEDGER" "$unit")
    if [ -n "$row" ]; then
      reviewed=$(( reviewed + 1 ))
      sha=$(printf '%s\n' "$row" | cut -f2)
      date=$(printf '%s\n' "$row" | cut -f3)
      printf '  %-24s %s  (reviewed %s at %s)\n' "$unit" "$state" "$date" "${sha:0:8}"
    else
      printf '  %-24s %s\n' "$unit" "$state"
    fi
    [ "$state" = changed ] && changed=$(( changed + 1 ))
    [ "$state" = expired ] && expired=$(( expired + 1 ))
    [ "$state" = never ] && never=$(( never + 1 ))
  done < <(units_for "$PROJECT" "$TRACK")

  # Ledger rows whose unit no longer exists in the current set.
  local orphans
  orphans=$(ledger_rows "$LEDGER" | cut -f1 | while IFS= read -r u; do
    [ -n "${seen[$u]:-}" ] || printf '  %-24s ORPHAN (unit no longer present)\n' "$u"
  done)
  [ -n "$orphans" ] && printf '%s\n' "$orphans"

  printf 'coverage: %s/%s units reviewed, %s changed, %s expired, %s never reviewed\n' \
    "$reviewed" "$total" "$changed" "$expired" "$never"
}

# --- dispatch ---------------------------------------------------------------

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
esac

ACTION=$1
shift || true

[ "$#" -ge 2 ] || die "$ACTION needs a project and a track"
PROJECT=$1
TRACK=$2
shift 2
assert_track "$TRACK"
REPO=$(repo_dir "$PROJECT")
assert_repo "$REPO"
LEDGER=$(ledger_file "$PROJECT" "$TRACK")

case "$ACTION" in
  select)
    SELECT_BODY=$(mktemp "${TMPDIR:-/tmp}/fm-ledger-sel.XXXXXX") || die "mktemp failed"
    trap 'rm -f "$SELECT_BODY"' EXIT
    cmd_select "$PROJECT" "$TRACK" "${1:-}"
    ;;
  record) cmd_record "$@" ;;
  status) cmd_status ;;
  units)  units_for "$PROJECT" "$TRACK" ;;
  *) die "unknown action '$ACTION' (see --help)" ;;
esac
