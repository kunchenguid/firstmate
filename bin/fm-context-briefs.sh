#!/usr/bin/env bash
# fm-context-briefs.sh - regenerate the derived halves of the captain's context
# briefs under FM_HOME/data/briefs/.
#
# A context brief is a captain-facing reading surface with two kinds of content.
# The narrative and the pointers are written by hand and this script never
# touches a byte of them. Two sections are derived from records this home
# already keeps, and this script owns those two:
#
#   "Waiting on you"  captain-held backlog items for that context's repositories,
#                     read through tasks-axi, never by parsing data/backlog.md.
#   "Running now"     live task state, from state/<id>.meta reconciled by
#                     bin/fm-crew-state.sh.
#
# Each derived section is bounded by explicit markers. The generator rewrites
# only the bytes strictly between a begin and end marker. A file whose markers
# are missing, duplicated, out of order, or overlapping is REFUSED and left
# untouched: the generator never guesses a boundary and never appends.
#
#   <!-- fm:brief:waiting-on-you:begin -->  ...  <!-- fm:brief:waiting-on-you:end -->
#   <!-- fm:brief:running-now:begin -->     ...  <!-- fm:brief:running-now:end -->
#
# Every generated block opens with its own generation date in plain words plus a
# machine-readable stamp comment. That stamp IS the staleness probe: a block
# whose date is not recent says so on the page the captain is reading, so a
# generator that stopped running cannot hide behind a page that still looks
# current. `--check` reads those same stamps and writes nothing.
#
# A section whose source could not be read at all says exactly that and names
# what it could not reach. It never says nothing is waiting or nothing is
# running, because this platform does not assert that something does not exist,
# only that it could not find one and what it checked. Such a block carries an
# unread marker INSTEAD of a generation stamp, because a fresh stamp over a
# source that was never read is a lie the staleness probe cannot catch.
#
#   <!-- fm:brief:unread waiting-on-you -->
#
# The backlog is read only when the shared backend decision in
# bin/fm-tasks-axi-lib.sh says tasks-axi is usable here, which is the same owner
# bin/fm-session-start.sh, bin/fm-teardown.sh and bin/fm-decision-hold.sh
# consult. Live work is read only when the task state directory can be listed.
#
# The narrative's own review date is the "*Current as at ...*" line each brief
# already carries. This script READS it, for --check, and never writes it.
#
# Context to repository mapping lives in FM_HOME/config/context-briefs.conf, a
# gitignored plain-text file a human edits. See docs/configuration.md and
# docs/examples/context-briefs.conf. A repository that appears in the records
# but in no context is reported as an explicit unmapped line, never dropped.
#
# Persistent secondmates are deliberately absent from "Running now": a
# secondmate is a standing direct report rather than a work item, and an idle
# one is healthy (AGENTS.md section 10).
#
# Usage:
#   fm-context-briefs.sh                 regenerate every configured brief
#   fm-context-briefs.sh --after-event   the same, quiet, and never non-zero
#                                        (lifecycle call sites use this)
#   fm-context-briefs.sh --check         read-only audit of block and review ages
#   fm-context-briefs.sh --install-markers
#                                        insert the four markers around the two
#                                        existing headings, once, deleting nothing
#   fm-context-briefs.sh --help
#
# Exit status: 0 on success, 1 on any refusal or failure, 2 on a usage error.
# `--check` exits 1 when any block is stale, unreadable, or missing. Both paths
# report an unmapped repository as an explicit line and neither ever exits
# non-zero merely because one exists, which is a reported fact rather than a
# failure. `--after-event` always exits 0 so a lifecycle command never fails
# because a reading surface could not refresh.
#
# `--after-event` runs the whole refresh as one bounded child, because it fires
# inside spawn, teardown, and every landing, and the record reads underneath it
# are subprocesses of tools that can hang. A refresh that hits the bound leaves
# the brief it was part way through exactly as it found it, because each brief is
# staged in full and moved into place in one step. Briefs the same run had
# already moved into place keep their new content, which is the guarantee this
# staging offers: no brief is ever left half rewritten.
#
# `--check` writes nothing at all, so it neither creates a directory nor stages a
# file, and it reads live task state only as far as the repository identities it
# reports. `--after-event` prints nothing on either stream.
#
# Environment:
#   FM_HOME                          the operational home to read and write
#   FM_CONTEXT_BRIEFS_MAX_AGE_HOURS  --check staleness bound (default 24)
#   FM_CONTEXT_BRIEFS_TIMEOUT        per-task current-state bound in seconds
#                                    (default 20)
#   FM_CONTEXT_BRIEFS_AFTER_EVENT_TIMEOUT
#                                    aggregate bound in seconds on one
#                                    --after-event refresh (default 60)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BRIEFS="$DATA/briefs"
MAP="$CONFIG/context-briefs.conf"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# fm-wake-lib.sh, which owns the lock, is sourced lazily by acquire_briefs_lock
# rather than here. Sourcing it creates the state directory as a side effect, and
# this script has two paths that must not do that: --check writes nothing and
# --after-event says nothing. bin/fm-crew-state.sh, this repository's other
# read-only reader, keeps that library off its file scope for the same reason.

# A bound that cannot be read is not a bound, so an unusable value falls back to
# the default rather than silently removing the limit it was meant to impose.
MAX_AGE_HOURS=${FM_CONTEXT_BRIEFS_MAX_AGE_HOURS:-24}
case "$MAX_AGE_HOURS" in
  '' | 0 | *[!0-9]*) MAX_AGE_HOURS=24 ;;
esac
STATE_TIMEOUT=${FM_CONTEXT_BRIEFS_TIMEOUT:-20}
case "$STATE_TIMEOUT" in
  '' | 0 | *[!0-9]*) STATE_TIMEOUT=20 ;;
esac
AFTER_EVENT_TIMEOUT=${FM_CONTEXT_BRIEFS_AFTER_EVENT_TIMEOUT:-60}
case "$AFTER_EVENT_TIMEOUT" in
  '' | 0 | *[!0-9]*) AFTER_EVENT_TIMEOUT=60 ;;
esac

WOU_BEGIN='<!-- fm:brief:waiting-on-you:begin -->'
WOU_END='<!-- fm:brief:waiting-on-you:end -->'
RN_BEGIN='<!-- fm:brief:running-now:begin -->'
RN_END='<!-- fm:brief:running-now:end -->'
WOU_HEADING='## Waiting on you'
RN_HEADING='## Running now'
STAMP_PREFIX='<!-- fm:brief:generated '
UNREAD_PREFIX='<!-- fm:brief:unread '
# The lock sits beside what it guards rather than in state/, so a home whose
# task state cannot be read can still rewrite its briefs and say so.
BRIEFS_LOCK="$BRIEFS/.context-briefs.lock"
LOCK_TRIES=100
TAB=$'\t'

QUIET=0
RC=0
BACKLOG_UNREAD=
RUNNING_UNREAD=
TEMP_PATHS=()

# Staging files live beside the brief, in the directory the captain browses
# through his Obsidian symlink, and the aggregate bound on --after-event makes a
# killed run a designed outcome rather than an accident. Every staged path is
# tracked and removed on the way out, including when the bound signals this
# process. A path already moved into place is gone, so removing it is a no-op.
track_temp() {
  TEMP_PATHS+=("$1")
}

# shellcheck disable=SC2329 # Invoked by the exit and signal traps below.
clean_temps() {
  local path
  [ "${#TEMP_PATHS[@]}" -gt 0 ] || return 0
  for path in "${TEMP_PATHS[@]}"; do
    [ -n "$path" ] || continue
    rm -rf -- "$path" 2>/dev/null || true
  done
  TEMP_PATHS=()
}

trap 'clean_temps' EXIT
trap 'clean_temps; exit 129' HUP
trap 'clean_temps; exit 130' INT
trap 'clean_temps; exit 143' TERM

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

say() {  # operator-facing line, suppressed under --after-event
  [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"
}

# note_refusal prints only. Every caller sets RC itself, because a refusal
# discovered inside a command substitution cannot carry a variable back out.
note_refusal() {
  [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2
}

# --- the context to repository mapping --------------------------------------

# repo_key <name>: the comparison form of a repository name. Records spell the
# same repository as "owner/Name", "Name", and a clone directory basename, so
# matching uses the last path segment, lowercased.
repo_key() {
  local n=${1##*/}
  printf '%s\n' "$n" | tr '[:upper:]' '[:lower:]'
}

# read_map: prints "<context><TAB><repo_key><TAB><repo_display>" in file order.
# Format is "<context>: <repo>, <repo>". Blank lines and #-comments are ignored.
read_map() {
  local line ctx repos repo
  [ -f "$MAP" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    case "$line" in
      *:*) ;;
      *) continue ;;
    esac
    ctx=${line%%:*}
    repos=${line#*:}
    ctx=$(printf '%s\n' "$ctx" | tr -d '[:space:]')
    [ -n "$ctx" ] || continue
    printf '%s\n' "$repos" | tr ',' '\n' | while IFS= read -r repo; do
      repo=$(printf '%s\n' "$repo" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      [ -n "$repo" ] || continue
      printf '%s\t%s\t%s\n' "$ctx" "$(repo_key "$repo")" "$repo"
    done
  done < "$MAP"
}

require_map() {
  if [ ! -f "$MAP" ]; then
    note_refusal "refused: no context mapping at $MAP. Copy docs/examples/context-briefs.conf there and list each context's repositories."
    return 1
  fi
  if [ -z "$(read_map)" ]; then
    note_refusal "refused: $MAP names no context. Each line reads '<context>: <repo>, <repo>'."
    return 1
  fi
  return 0
}

contexts() {  # unique context names, in file order
  read_map | cut -f1 | awk '!seen[$0]++'
}

context_repos() {  # <context> -> "<repo_key><TAB><repo_display>" in file order
  read_map | awk -F'\t' -v c="$1" '$1 == c { print $2 "\t" $3 }'
}

# --- dates ------------------------------------------------------------------

MONTHS='January February March April May June July August September October November December'

# fmt_epoch <epoch> <strftime-body>: BSD date takes -r <epoch>, GNU date takes
# -d @<epoch> and reads -r as a file, so the GNU form is the fallback.
fmt_epoch() {
  date -r "$1" "+$2" 2>/dev/null || date -d "@$1" "+$2" 2>/dev/null
}

human_date() {  # <epoch> -> "Friday 7 August 2026"
  fmt_epoch "$1" '%A %e %B %Y' | tr -s ' '
}

human_time() {  # <epoch> -> "4:04pm"
  fmt_epoch "$1" '%l:%M%p' | tr -d ' ' | tr '[:upper:]' '[:lower:]'
}

iso_stamp() {  # <epoch> -> "2026-08-07T16:04:09+1000"
  fmt_epoch "$1" '%Y-%m-%dT%H:%M:%S%z'
}

# iso_day_to_human <YYYY-MM-DD> -> "20 August 2026", or the input verbatim when
# it does not parse. Never invents a date it could not read.
iso_day_to_human() {
  local d=$1 name
  case "$d" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) printf '%s\n' "$d"; return 0 ;;
  esac
  name=$(printf '%s\n' "$MONTHS" | tr ' ' '\n' | sed -n "$((10#${d:5:2}))p")
  [ -n "$name" ] || { printf '%s\n' "$d"; return 0; }
  printf '%s %s %s\n' "$((10#${d:8:2}))" "$name" "${d%%-*}"
}

# --- record reads -----------------------------------------------------------

# tasks: run tasks-axi against THIS home's backlog rather than the caller's
# working directory, the same way bin/fm-decision-hold.sh resolves it.
tasks() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

# backlog_available: whether this home's backlog can be read at all. The decision
# belongs to bin/fm-tasks-axi-lib.sh, which already owns the version floor, the
# feature probes for stripped builds, and the manual-backend opt-out. It is asked
# here rather than re-derived, so a home that reads its backlog one way in
# session start cannot read it another way in a brief.
backlog_available() {
  fm_tasks_axi_backend_available "$CONFIG"
}

# backlog_unread_reason: what could not be reached, in the reader's words. Only
# ever called once backlog_available has already said no.
backlog_unread_reason() {
  if fm_backlog_backend_manual "$CONFIG"; then
    printf 'This home is set to the manual backlog backend in %s/backlog-backend, so the backlog tooling was not read.\n' "$CONFIG"
  elif ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'The backlog tool tasks-axi is not installed on this machine, so the captain-held items could not be read.\n'
  else
    printf 'The tasks-axi on this machine cannot be used by this home, which needs version %s or newer carrying the flags firstmate relies on, so the captain-held items could not be read.\n' "$FM_TASKS_AXI_MIN"
  fi
}

# running_readable: whether live work can be enumerated at all. A directory that
# exists and can be listed holding no records is a genuine empty. A directory
# that cannot be listed is not an answer.
running_readable() {
  [ -d "$STATE" ] && [ -r "$STATE" ] && [ -x "$STATE" ]
}

running_unread_reason() {
  printf 'The task state directory at %s could not be listed, so live work could not be read.\n' "$STATE"
}

# tasks_field <show-output> <key>: one scalar field from `tasks-axi show --full`.
# Values are bare or double-quoted with backslash escapes, and "-" means empty.
tasks_field() {
  local out=$1 key=$2 v
  v=$(printf '%s\n' "$out" | sed -n "s/^  $key: //p" | head -1)
  case "$v" in
    '"'*'"') v=${v#\"}; v=${v%\"} ;;
  esac
  v=$(printf '%s' "$v" | sed 's/\\"/"/g; s/\\n/ /g; s/\\\\/\\/g')
  [ "$v" = '-' ] && v=''
  printf '%s\n' "$v"
}

# held <value>: the field form written into the intermediate records below. A
# tab is IFS whitespace, so bash `read` collapses two adjacent tabs into one and
# an empty field would silently shift every later column. Absent values are
# therefore written as "-", the same marker tasks-axi itself uses, and read back
# through `given`.
held() {
  [ -n "${1:-}" ] && printf '%s\n' "$1" || printf -- '-\n'
}

# given <field>: the value a record field carries, empty when it carries none.
given() {
  [ "${1:-}" = '-' ] && printf '' || printf '%s' "${1:-}"
}

# sentence <text>: <text> closed with a full stop unless it already ends in
# sentence punctuation. Titles are written both ways in the backlog. The
# terminators are quoted because an unquoted ? is a case-pattern wildcard, so
# *? would match every non-empty title and suppress every full stop.
sentence() {
  case "$1" in
    '') printf '' ;;
    *'.' | *'?' | *'!' | *':') printf '%s' "$1" ;;
    *) printf '%s.' "$1" ;;
  esac
}

task_title() {  # <id> -> full title, or empty when the backlog does not know it
  local out
  backlog_available || return 0
  out=$(tasks show "$1" --full 2>/dev/null) || return 0
  tasks_field "$out" title
}

# captain_items: TSV of every open captain-held item. The backlog is read only
# through tasks-axi, never by parsing data/backlog.md.
#   id <TAB> repo_key <TAB> repo_display <TAB> deadline <TAB> created <TAB> title
captain_items() {
  local ids id out state repo title deadline created
  backlog_available || return 0
  ids=$(tasks list --kind captain 2>/dev/null |
    sed -n 's/^  \([A-Za-z0-9][A-Za-z0-9._-]*\),.*/\1/p') || return 0
  for id in $ids; do
    out=$(tasks show "$id" --full 2>/dev/null) || continue
    state=$(tasks_field "$out" state)
    [ "$state" = "done" ] && continue
    repo=$(tasks_field "$out" repo)
    title=$(tasks_field "$out" title)
    deadline=$(tasks_field "$out" hold_until)
    created=$(tasks_field "$out" created)
    [ -n "$title" ] || title=$id
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$(repo_key "$repo")" "$(held "$repo")" "$(held "$deadline")" \
      "$(held "$created")" "$(held "$title")"
  done
}

meta_field() {  # <meta-file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# running_items: TSV of every live work item recorded in this home.
#   id <TAB> repo_key <TAB> state <TAB> pr <TAB> title
# running_identities: which live work items exist and whose repository each one
# belongs to, from the metadata alone and with no current-state or backlog read.
# This owns the "what counts as a live work item" decision, including leaving a
# standing secondmate out, so running_items below does not restate it.
#   id <TAB> repo_key
running_identities() {
  local meta id kind project
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(meta_field "$meta" kind)
    [ "$kind" = secondmate ] && continue
    project=$(meta_field "$meta" project)
    printf '%s\t%s\n' "$id" "$(repo_key "$project")"
  done
}

# running_items: the same items with what they are actually doing, which costs
# one bounded current-state read and one backlog read apiece. Only a rendered
# brief needs that, so only the generate path asks for it.
#   id <TAB> repo_key <TAB> state <TAB> pr <TAB> title
running_items() {
  local id rk meta state pr title
  while IFS="$TAB" read -r id rk; do
    [ -n "$id" ] || continue
    meta="$STATE/$id.meta"
    pr=$(meta_field "$meta" pr)
    state=$(fm_run_timed "$STATE_TIMEOUT" "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null |
      sed -n 's/^state: \([a-z-]*\).*/\1/p' | head -1)
    [ -n "$state" ] || state=unknown
    title=$(task_title "$id")
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$rk" "$state" "$(held "$pr")" "$(held "$title")"
  done < <(running_identities)
}

# --- rendering --------------------------------------------------------------

stamp_lines() {  # <epoch>
  printf '%s%s epoch=%s -->\n' "$STAMP_PREFIX" "$(iso_stamp "$1")" "$1"
  printf '*Generated %s at %s. If that date is not recent this section stopped updating, so do not trust it.*\n' \
    "$(human_date "$1")" "$(human_time "$1")"
}

# Backticks in the format string below are a Markdown code span, which a shell
# linter cannot tell from command substitution.
# shellcheck disable=SC2016
# render_unread <section> <reason>: the block a section gets when its source
# could not be read. It carries the unread marker rather than a generation
# stamp, because a stamp here would tell the captain's own staleness probe that
# a read succeeded when none happened.
render_unread() {
  printf '%s%s -->\n' "$UNREAD_PREFIX" "$1"
  printf 'This section could not be read, so it is not telling you there is nothing here.\n\n'
  printf '%s\n\n' "$2"
  printf 'Until that is sorted this block has no generation date, because nothing was generated. Run `fm-context-briefs.sh` again once it can be read.\n'
}

state_words() {  # <crew-state> -> plain English
  case "$1" in
    working) printf 'under way' ;;
    parked) printf 'waiting on a decision' ;;
    done) printf 'finished and waiting to be tidied up' ;;
    blocked) printf 'stuck and needs a hand' ;;
    paused) printf 'waiting on something outside' ;;
    failed) printf 'stopped after a failure' ;;
    *) printf 'in a state that could not be read' ;;
  esac
}

# tally <total> <dated>: the one-line count that opens a "Waiting on you" block.
tally() {
  local total=$1 dated=$2
  if [ "$total" -eq 1 ]; then
    if [ "$dated" -eq 1 ]; then
      printf 'One decision is sitting on this side, and it has a date.\n'
    else
      printf 'One decision is sitting on this side.\n'
    fi
  elif [ "$dated" -eq 0 ]; then
    printf '%s decisions are sitting on this side.\n' "$total"
  elif [ "$dated" -eq 1 ]; then
    printf '%s decisions are sitting on this side, one of them with a date.\n' "$total"
  else
    printf '%s decisions are sitting on this side, %s of them with a date.\n' "$total" "$dated"
  fi
}

# Backticks in the format strings below are Markdown code spans, which a shell
# linter cannot tell from command substitution.
# shellcheck disable=SC2016
# render_waiting <context> <items-record> <epoch>
render_waiting() {
  local ctx=$1 items=$2 now=$3
  local id rk rd deadline title total dated undated group_count

  stamp_lines "$now"
  printf '\n'

  total=$(awk 'END { print NR + 0 }' "$items")
  dated=$(awk -F'\t' '$4 != "-" { n++ } END { print n + 0 }' "$items")
  undated=$((total - dated))

  if [ "$total" -eq 0 ]; then
    printf 'Nothing is waiting on you for this side.\n'
    return 0
  fi

  tally "$total" "$dated"

  if [ "$dated" -gt 0 ]; then
    printf '\n**These have a date on them**\n\n'
    awk -F'\t' '$4 != "-"' "$items" | LC_ALL=C sort -t"$TAB" -k4,4 -k1,1 |
      while IFS="$TAB" read -r id _rk rd deadline _created title; do
        printf -- '- **By %s.** %s (`%s`, %s)\n' \
          "$(iso_day_to_human "$deadline")" "$(sentence "$(given "$title")")" "$id" "$(given "$rd")"
      done
  fi

  if [ "$undated" -gt 0 ]; then
    # One group per repository, in the order the mapping declares them.
    while IFS="$TAB" read -r rk rd; do
      group_count=$(awk -F'\t' -v r="$rk" '$2 == r && $4 == "-" { n++ } END { print n + 0 }' "$items")
      [ "$group_count" -gt 0 ] || continue
      printf '\n**%s** (%s)\n' "$rd" "$group_count"
      render_repo_group "$rk" "$items"
    done < <(context_repos "$ctx")
  fi

  printf '\nRun `tasks-axi show <id>` for the full note on any of these.\n'
}

# Backticks in the format strings below are Markdown code spans, which a shell
# linter cannot tell from command substitution.
# shellcheck disable=SC2016
# render_repo_group <repo_key> <items-record>: the undated decisions for one
# repository, clustered under the work that raised them so the reader sees a few
# named groups rather than a flat list of ids. A cluster needs at least two
# members to be worth naming, and everything else falls to one closing group.
render_repo_group() {
  local rk=$1 items=$2 alone family id title label previous='__start__' clusters
  # A closing "On their own" header only earns its place when some named cluster
  # precedes it, so a repository with no clusters reads as one plain list.
  clusters=$(awk -F'\t' -v r="$rk" '
    function family(id,   p) {
      p = index(id, "-decision-")
      return p > 0 ? substr(id, 1, p - 1) : ""
    }
    $2 == r && $4 == "-" { f = family($1); if (f != "") kin[f]++ }
    END { n = 0; for (f in kin) if (kin[f] >= 2) n++; print n + 0 }
  ' "$items")
  awk -F'\t' -v r="$rk" '
    function family(id,   p) {
      p = index(id, "-decision-")
      return p > 0 ? substr(id, 1, p - 1) : ""
    }
    NR == FNR { if ($2 == r && $4 == "-") kin[family($1)]++; next }
    $2 == r && $4 == "-" {
      f = family($1)
      if (f == "" || kin[f] < 2) printf "1\t-\t%s\t%s\n", $1, $6
      else printf "0\t%s\t%s\t%s\n", f, $1, $6
    }
  ' "$items" "$items" | LC_ALL=C sort -t"$TAB" -k1,1 -k2,2 -k3,3 |
    while IFS="$TAB" read -r alone family id title; do
      label=$family
      [ "$alone" = 1 ] && label='__alone__'
      if [ "$label" != "$previous" ]; then
        if [ "$label" = '__alone__' ]; then
          if [ "$clusters" -eq 0 ]; then
            printf '\n'
          else
            printf '\n*On their own*\n\n'
          fi
        else
          printf '\n*Raised by `%s`*\n\n' "$family"
        fi
        previous=$label
      fi
      printf -- '- %s (`%s`)\n' "$(sentence "$(given "$title")")" "$id"
    done
}

# Backticks in the format strings below are Markdown code spans, which a shell
# linter cannot tell from command substitution.
# shellcheck disable=SC2016
# render_running <context> <items-record> <epoch>
render_running() {
  local ctx=$1 items=$2 now=$3 rk rd id item_rk state pr title any=0

  stamp_lines "$now"
  printf '\n'

  while IFS="$TAB" read -r rk rd; do
    while IFS="$TAB" read -r id item_rk state pr title; do
      [ "$item_rk" = "$rk" ] || continue
      any=1
      title=$(given "$title")
      pr=$(given "$pr")
      if [ -n "$title" ]; then
        printf -- '- **%s**, %s. %s (`%s`)\n' \
          "$rd" "$(state_words "$state")" "$(sentence "$title")" "$id"
      else
        printf -- '- **%s**, %s. (`%s`)\n' "$rd" "$(state_words "$state")" "$id"
      fi
      [ -n "$pr" ] && printf '  Its pull request: %s\n' "$pr"
    done < "$items"
  done < <(context_repos "$ctx")

  [ "$any" -eq 1 ] || printf 'Nothing is running for this side right now.\n'
}


# --- marker mechanics -------------------------------------------------------

# marker_line <file> <marker>: the 1-based line number of the sole exact match.
# Returns 1 when the marker appears zero times or more than once.
marker_line() {
  local n
  n=$(grep -n -x -F -- "$2" "$1" 2>/dev/null | cut -d: -f1)
  [ "$(printf '%s\n' "$n" | grep -c .)" = 1 ] || return 1
  printf '%s\n' "$n"
}

# check_markers <file>: prove all four markers are present exactly once, each
# pair ordered, and the two ranges disjoint. Prints the four line numbers.
check_markers() {
  local f=$1 wb we rb re
  wb=$(marker_line "$f" "$WOU_BEGIN") ||
    { note_refusal "refused: $f does not carry exactly one '$WOU_BEGIN' line, so it was left untouched."; return 1; }
  we=$(marker_line "$f" "$WOU_END") ||
    { note_refusal "refused: $f does not carry exactly one '$WOU_END' line, so it was left untouched."; return 1; }
  rb=$(marker_line "$f" "$RN_BEGIN") ||
    { note_refusal "refused: $f does not carry exactly one '$RN_BEGIN' line, so it was left untouched."; return 1; }
  re=$(marker_line "$f" "$RN_END") ||
    { note_refusal "refused: $f does not carry exactly one '$RN_END' line, so it was left untouched."; return 1; }
  if [ "$wb" -ge "$we" ] || [ "$rb" -ge "$re" ]; then
    note_refusal "refused: $f has a block whose end marker sits before its begin marker, so it was left untouched."
    return 1
  fi
  if [ "$we" -ge "$rb" ] && [ "$re" -ge "$wb" ]; then
    note_refusal "refused: $f has two generated blocks that overlap, so it was left untouched."
    return 1
  fi
  printf '%s\t%s\t%s\t%s\n' "$wb" "$we" "$rb" "$re"
}

# rewrite_blocks <file> <wb> <we> <rb> <re> <waiting-body> <running-body>
# Rewrites only the bytes strictly between each pair of marker lines. head, sed
# and tail reproduce the surrounding bytes exactly, including a file with no
# final newline, which is what keeps hand-written prose byte-identical.
#
# Both blocks are staged into ONE temporary file and moved into place in one
# step. A run that dies part way through, including one killed by the aggregate
# bound on --after-event, therefore leaves the brief exactly as it found it
# rather than with one block refreshed and the other stale.
rewrite_blocks() {
  local f=$1 wb=$2 we=$3 rb=$4 re=$5 wbody=$6 rbody=$7
  local first_begin first_end first_body second_begin second_end second_body tmp
  if [ "$wb" -lt "$rb" ]; then
    first_begin=$wb first_end=$we first_body=$wbody
    second_begin=$rb second_end=$re second_body=$rbody
  else
    first_begin=$rb first_end=$re first_body=$rbody
    second_begin=$wb second_end=$we second_body=$wbody
  fi
  tmp=$(mktemp "$(dirname "$f")/.fm-context-briefs.XXXXXX") || return 1
  track_temp "$tmp"
  {
    head -n "$first_begin" "$f" &&
      printf '\n' &&
      cat "$first_body" &&
      printf '\n' &&
      sed -n "$first_end,${second_begin}p" "$f" &&
      printf '\n' &&
      cat "$second_body" &&
      printf '\n' &&
      tail -n "+$second_end" "$f"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$f"
}

# --- commands ---------------------------------------------------------------

# collect_records <workdir> <depth>: fill captain.tsv and running.tsv, and record
# why either source could not be read. An unreadable source leaves an EMPTY
# record and a stated reason, which the renderers keep apart: no record plus no
# reason is a genuine empty, no record plus a reason is "could not find out".
#
# <depth> is "state" for a rendered brief, which needs what each live item is
# doing, or "identities" for the audit, which only reports which repositories
# appear. The audit asks for identities so it never waits on a current-state read
# whose answer it would discard, which on a degraded fleet is the difference
# between a file read and minutes of bounded subprocesses.
collect_records() {
  local work=$1 depth=$2
  BACKLOG_UNREAD=
  RUNNING_UNREAD=
  if backlog_available; then
    captain_items > "$work/captain.tsv"
  else
    BACKLOG_UNREAD=$(backlog_unread_reason)
    : > "$work/captain.tsv"
  fi
  if ! running_readable; then
    RUNNING_UNREAD=$(running_unread_reason)
    : > "$work/running.tsv"
  elif [ "$depth" = state ]; then
    running_items > "$work/running.tsv"
  else
    running_identities > "$work/running.tsv"
  fi
}

# brief_target <file> <context>: prove the path is a real file this run may
# rewrite. A symlink is refused on its own terms, because the briefs are already
# surfaced to the captain through one and an operator who linked a single file
# deserves to be told that rather than that the file is missing.
brief_target() {
  local file=$1 ctx=$2
  if [ -L "$file" ]; then
    note_refusal "refused: $file for context '$ctx' is a symbolic link, and this generator will not write through one, so it was left untouched."
    return 1
  fi
  if [ ! -f "$file" ]; then
    note_refusal "refused: there is no brief at $file for context '$ctx'."
    return 1
  fi
  return 0
}

# acquire_briefs_lock: take the rewrite lock, or refuse. fm_lock_try_acquire is
# the repository's owner of this decision, including reclaiming a lock whose
# holder is provably gone. The wait is bounded because this runs inside spawn and
# teardown, where waiting forever on a lock is worse than saying it could not be
# taken.
acquire_briefs_lock() {
  local tries=0
  # Sourced here rather than at file scope: this library creates the state
  # directory when it loads, and only the writing path may do that.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  while ! fm_lock_try_acquire "$BRIEFS_LOCK"; do
    if [ "$tries" -ge "$LOCK_TRIES" ]; then
      note_refusal "refused: could not take the brief rewrite lock at $BRIEFS_LOCK, so no brief was touched."
      return 1
    fi
    tries=$((tries + 1))
    sleep 0.1
  done
  return 0
}

generate() {
  local now ctx file lines wb we rb re work captain running status=0 locked=0
  require_map || return 1
  now=$(date +%s)
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-context-briefs.XXXXXX") || return 1
  track_temp "$work"

  captain="$work/captain.tsv"
  running="$work/running.tsv"
  collect_records "$work" state

  report_unmapped "$captain" "$running"

  # Five lifecycle commands can fire this refresh at once in a fleet. The line
  # numbers check_markers resolves are only true while the file holds still, so
  # the lock spans reading them and moving the rewritten file into place. With no
  # briefs directory there is nothing to guard and every context refuses below on
  # its own terms, which is the more useful message.
  if [ -d "$BRIEFS" ]; then
    acquire_briefs_lock || { rm -rf "$work"; return 1; }
    locked=1
  fi
  for ctx in $(contexts); do
    file="$BRIEFS/$ctx.md"
    brief_target "$file" "$ctx" || { status=1; continue; }
    lines=$(check_markers "$file") || { status=1; continue; }
    IFS="$TAB" read -r wb we rb re <<< "$lines"

    awk -F'\t' -v c="$ctx" \
      'NR == FNR { if ($1 == c) keep[$2] = 1; next } keep[$2]' \
      <(read_map) "$captain" | LC_ALL=C sort -t"$TAB" -k5,5 -k1,1 > "$work/wou.tsv"
    if [ -n "$BACKLOG_UNREAD" ]; then
      render_unread waiting-on-you "$BACKLOG_UNREAD" > "$work/wou.body"
    else
      render_waiting "$ctx" "$work/wou.tsv" "$now" > "$work/wou.body"
    fi
    if [ -n "$RUNNING_UNREAD" ]; then
      render_unread running-now "$RUNNING_UNREAD" > "$work/rn.body"
    else
      render_running "$ctx" "$running" "$now" > "$work/rn.body"
    fi

    rewrite_blocks "$file" "$wb" "$we" "$rb" "$re" "$work/wou.body" "$work/rn.body" ||
      { note_refusal "refused: could not rewrite $file."; status=1; continue; }
    say "updated $file"
  done
  [ "$locked" -eq 0 ] || fm_lock_release "$BRIEFS_LOCK"

  rm -rf "$work"
  return "$status"
}

# report_unmapped <captain-tsv> <running-tsv>: one explicit line per repository
# present in the records that no context claims, so it is never silently dropped.
report_unmapped() {
  local mapped seen key display
  mapped=$(read_map | cut -f2 | LC_ALL=C sort -u)
  seen=$( { cut -f2,3 "$1"; awk -F'\t' '{ print $2 "\t" $2 }' "$2"; } | LC_ALL=C sort -u)
  printf '%s\n' "$seen" | while IFS="$TAB" read -r key display; do
    [ -n "$key" ] || continue
    printf '%s\n' "$mapped" | grep -qx -F -- "$key" && continue
    printf 'unmapped: repository "%s" appears in the records but no context in %s claims it\n' \
      "${display:-$key}" "$MAP"
  done
}

check() {
  local ctx file epoch age now reviewed line stale=0 blocks unread work
  require_map || return 1
  now=$(date +%s)

  # The audit reads the same records the generator does, so an unmapped
  # repository surfaces here too. It reads them and writes nothing.
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-context-briefs-check.XXXXXX") || return 1
  track_temp "$work"
  collect_records "$work" identities
  report_unmapped "$work/captain.tsv" "$work/running.tsv"
  rm -rf "$work"
  [ -z "$BACKLOG_UNREAD" ] || printf 'the backlog cannot be read right now: %s\n' "$BACKLOG_UNREAD"
  [ -z "$RUNNING_UNREAD" ] || printf 'live work cannot be read right now: %s\n' "$RUNNING_UNREAD"

  for ctx in $(contexts); do
    file="$BRIEFS/$ctx.md"
    if [ ! -f "$file" ]; then
      printf '%s: there is no brief file at %s\n' "$ctx" "$file"
      stale=1
      continue
    fi
    if ! check_markers "$file" >/dev/null; then
      stale=1
      continue
    fi
    blocks=$(grep -c -F -- "$STAMP_PREFIX" "$file" 2>/dev/null || true)
    unread=$(grep -c -F -- "$UNREAD_PREFIX" "$file" 2>/dev/null || true)
    if [ "$unread" -gt 0 ]; then
      printf '%s: a generated block says its source could not be read, so it carries no date\n' "$ctx"
      stale=1
    fi
    if [ "$((blocks + unread))" -lt 2 ]; then
      printf '%s: a generated block carries no date of its own\n' "$ctx"
      stale=1
    fi
    while IFS= read -r line; do
      epoch=${line##*epoch=}
      epoch=${epoch%% *}
      case "$epoch" in
        '' | *[!0-9]*)
          printf '%s: a generated block carries a date that cannot be read\n' "$ctx"
          stale=1
          continue
          ;;
      esac
      age=$(((now - epoch) / 3600))
      if [ "$age" -ge "$MAX_AGE_HOURS" ]; then
        printf '%s: a generated block is %s hours old, so it has stopped updating\n' "$ctx" "$age"
        stale=1
      fi
    done < <(grep -F -- "$STAMP_PREFIX" "$file" 2>/dev/null || true)
    reviewed=$(sed -n 's/^\*Current as at \(.*\)\.\*$/\1/p' "$file" | head -1)
    if [ -n "$reviewed" ]; then
      printf '%s: the hand-written half was last reviewed %s\n' "$ctx" "$reviewed"
    else
      printf '%s: the hand-written half carries no "*Current as at ...*" review line\n' "$ctx"
    fi
  done
  return "$stale"
}

# install_markers: wrap the two existing headings once, deleting nothing. A
# block ends at the next "## " heading or "---" rule, whichever comes first.
#
# Each pair is guarded by its OWN begin marker, so a brief that only ever got
# one pair installed can still be repaired rather than growing a second copy of
# the pair it already had. Both insertions are staged on a copy and the copy
# replaces the brief only once both have succeeded, so a refusal on the second
# heading leaves the original byte-identical, exactly as the refusal says.
install_markers() {
  local ctx file staged status=0 need_waiting need_running
  require_map || return 1
  for ctx in $(contexts); do
    file="$BRIEFS/$ctx.md"
    brief_target "$file" "$ctx" || { status=1; continue; }
    need_waiting=1
    need_running=1
    grep -q -x -F -- "$WOU_BEGIN" "$file" && need_waiting=0
    grep -q -x -F -- "$RN_BEGIN" "$file" && need_running=0
    if [ "$need_waiting" -eq 0 ] && [ "$need_running" -eq 0 ]; then
      say "$file already carries its markers"
      continue
    fi
    staged=$(mktemp "$(dirname "$file")/.fm-context-briefs.XXXXXX") || { status=1; continue; }
    track_temp "$staged"
    if ! cp "$file" "$staged"; then
      rm -f "$staged"
      note_refusal "refused: could not stage $file, so it was left untouched."
      status=1
      continue
    fi
    if { [ "$need_waiting" -eq 0 ] ||
      install_one "$staged" "$file" "$WOU_HEADING" "$WOU_BEGIN" "$WOU_END"; } &&
      { [ "$need_running" -eq 0 ] ||
        install_one "$staged" "$file" "$RN_HEADING" "$RN_BEGIN" "$RN_END"; } &&
      mv "$staged" "$file"; then
      say "installed markers in $file"
    else
      rm -f "$staged"
      status=1
    fi
  done
  return "$status"
}

install_one() {  # <staged-file> <display-name> <heading> <begin> <end>
  local f=$1 display=$2 heading=$3 begin=$4 end=$5 h stop total tmp
  h=$(marker_line "$f" "$heading") || {
    note_refusal "refused: $display does not carry exactly one '$heading' line, so it was left untouched."
    return 1
  }
  total=$(awk 'END { print NR + 0 }' "$f")
  stop=$(awk -v h="$h" 'NR > h && ($0 ~ /^## / || $0 == "---") { print NR; exit }' "$f")
  [ -n "$stop" ] || stop=$((total + 1))
  tmp=$(mktemp "$(dirname "$f")/.fm-context-briefs.XXXXXX") || return 1
  track_temp "$tmp"
  # A heading immediately followed by the next heading or rule has an EMPTY
  # body. Asking sed for that range would ask it to print from h+1 back to h,
  # and a reversed range prints its first line, which the tail below prints
  # again. An empty body is copied as nothing at all.
  {
    head -n "$h" "$f" &&
      printf '%s\n' "$begin" &&
      { [ "$stop" -le "$((h + 1))" ] || sed -n "$((h + 1)),$((stop - 1))p" "$f"; } &&
      printf '%s\n\n' "$end" &&
      tail -n "+$stop" "$f"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$f"
}

# --- entry ------------------------------------------------------------------

case "${1:---generate}" in
  --generate) generate || RC=$? ;;
  --after-event)
    QUIET=1
    # One aggregate bound over the whole refresh, not one per subprocess. The
    # backlog read launches a process per captain-held item and the current-state
    # read launches one per live task, so a degraded backend with a full backlog
    # and several live tasks would otherwise stall the lifecycle command that
    # called this. The bound is imposed by re-entering this script as one bounded
    # child, the same shape bin/fm-session-start.sh uses over the same
    # subprocesses.
    if [ -z "${FM_CONTEXT_BRIEFS_BOUNDED:-}" ]; then
      fm_run_timed "$AFTER_EVENT_TIMEOUT" \
        env FM_CONTEXT_BRIEFS_BOUNDED=1 "$SCRIPT_DIR/fm-context-briefs.sh" --after-event \
        >/dev/null 2>&1 || true
      exit 0
    fi
    generate >/dev/null 2>&1 || true
    exit 0
    ;;
  --check) check || RC=$? ;;
  --install-markers) install_markers || RC=$? ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    printf 'usage: fm-context-briefs.sh [--after-event|--check|--install-markers|--help]\n' >&2
    exit 2
    ;;
esac

exit "$RC"
