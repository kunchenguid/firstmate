#!/usr/bin/env bash
# fm-branch-outcome.sh - the durable outcome store for the Pi supervision
# branch (docs/pi-supervision-branch.md).
#
# CONTRACT (this header is the one owner of the store's format).
#   - Store: $STATE/branch-outcomes.jsonl, strictly APPEND-ONLY. One JSON
#     object per line: {"seq":N,"epoch":N,"task":"...","wake":"...",
#     "verdict":"routine"|"captain","summary":"...","silent":true|false,
#     "anchor":"..."}.
#     Legacy rows without `silent` remain valid and are treated as visible;
#     legacy rows without `anchor` remain valid and are never treated as stale.
#     Existing lines are never rewritten, reordered, or deleted by any
#     subcommand; the read state lives
#     entirely in the cursor sidecar so marking outcomes read cannot disturb
#     the log. Retention: the log is small (one line per handled fleet event)
#     and truncation, if ever needed, is a captain-approved manual act.
#   - Cursor: $STATE/.branch-outcomes-cursor holds the highest seq handed to
#     Pi as an append-only merge note, deliberately dropped as a stale routine
#     note at the delivery boundary, emitted by the locked session-start
#     replay, or silently consumed there because `silent` is true. Records
#     above the cursor are "unread": the branch stored them but did not reach
#     a delivery boundary or replay. A crash inside Pi's delivery window after
#     cursor advancement does not auto-replay the row; it remains durable and
#     available through the main session's fm_branch_outcomes tool.
#   - Every mutation runs under $STATE/.branch-outcomes.lock so the branch
#     extension and a concurrent session-start replay cannot interleave.
#   - The store is written BEFORE the delivery boundary can append a merge
#     note to main (store-first durability): nothing about a handled event
#     depends on conversation memory.
#   - CLAIM ANCHOR (freshness). An outcome is recorded when its claim is true
#     and delivered later, so every delivery re-checks the claim instead of
#     trusting the recorded text. `anchor` is the task's claim anchor at
#     append time: the durable records that decide whether a task-local claim
#     is still current, which are the task metadata's presence and recorded
#     `pr=`, plus whether the task's PR merge poll is still armed. Teardown
#     and a merged PR both move it; ordinary status appends do not, so a
#     routine note is not invalidated by mere progress. `fleet` has no
#     task-local claim and anchors to the constant `fleet`. An anchor that
#     cannot be computed is empty, which never reads as stale: an
#     unverifiable claim is delivered unchanged rather than suppressed, so
#     uncertainty never loses a captain-relevant outcome.
#
# Usage:
#   fm-branch-outcome.sh append --task <id> --verdict routine|captain \
#       --summary <text> [--wake <text>] [--silent true|false] \
#       [--anchor <text>]
#     Append one outcome record; prints the assigned seq.
#   fm-branch-outcome.sh claim-anchor --task <id>
#     Print the task's claim anchor right now. Compare a stored anchor with a
#     fresh one to decide whether a recorded outcome is still current.
#   fm-branch-outcome.sh unread
#     Print every unread record (raw JSONL). Exit 0 with no output when none.
#   fm-branch-outcome.sh mark-read --through <seq>
#     Advance the cursor (never backwards) after accounting for records at the
#     delivery boundary.
#   fm-branch-outcome.sh list [--recent <n>]
#     Print the last n records (default 20), read or not.
#   fm-branch-outcome.sh startup-replay
#     Session-start recovery: print visible unread records under a labeled
#     header into the locked startup digest, skip rows whose `silent` field is
#     true, and mark every unread row read. A row whose stored anchor no longer
#     matches its task's current anchor is emitted with "superseded":true added
#     so the replay cannot relay a stale claim as current; the stored line is
#     not rewritten. Prints nothing when nothing visible
#     is unread, so a home that never ran the branch stays silent. Run it only
#     when the session holds the lock (fm-session-start.sh owns the call site).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# fm_task_id_path_safe: the shared owner of task-id path safety.
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

STORE="$STATE/branch-outcomes.jsonl"
CURSOR="$STATE/.branch-outcomes-cursor"
LOCK="$STATE/.branch-outcomes.lock"

usage() {
  echo "usage: fm-branch-outcome.sh append --task <id> --verdict routine|captain --summary <text> [--wake <text>] [--silent true|false] [--anchor <text>] | claim-anchor --task <id> | unread | mark-read --through <seq> | list [--recent <n>] | startup-replay" >&2
  exit 2
}

json_escape() { # <text> -> escaped JSON string content on stdout
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) print "\\n"
      line = $0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      # Any remaining C0 control character would break the JSON line record.
      gsub(/[\001-\010\013\014\016-\037]/, "", line)
      print line
    }'
}

read_cursor() {
  local value
  value=$(head -n 1 "$CURSOR" 2>/dev/null | tr -cd '0-9' || true)
  printf '%s\n' "${value:-0}"
}

last_seq() {
  local value
  [ -s "$STORE" ] || { printf '0\n'; return 0; }
  value=$(tail -n 1 "$STORE" 2>/dev/null | jq -er '
    select(type == "object")
    | select((keys - ["anchor", "silent"]) == ["epoch", "seq", "summary", "task", "verdict", "wake"])
    | select((has("silent") | not) or (.silent | type) == "boolean")
    | select((has("anchor") | not) or (.anchor | type) == "string")
    | select((.seq | type) == "number" and .seq >= 1 and .seq == (.seq | floor))
    | select((.epoch | type) == "number" and .epoch >= 0 and .epoch == (.epoch | floor))
    | select((.task | type) == "string" and (.wake | type) == "string")
    | select((.summary | type) == "string" and (.verdict == "routine" or .verdict == "captain"))
    | .seq
  ') || return 1
  printf '%s\n' "$value"
}

# The task's claim anchor: the durable records that decide whether a
# task-local outcome is still current (header CONTRACT owns the semantics).
# Fails only for a task id that is not path-safe, so a caller that cannot
# compute one treats the claim as unverifiable rather than stale.
claim_anchor() { # <task-id>
  local id=$1 meta=0 poll=0 pr='' path
  if [ "$id" = fleet ]; then
    printf 'fleet\n'
    return 0
  fi
  fm_task_id_path_safe "$id" || return 1
  path="$STATE/$id.meta"
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    meta=1
    pr=$(sed -n 's/^pr=//p' "$path" | head -n 1 | tr -d '\r')
  fi
  path="$STATE/$id.pr-poll"
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    poll=1
  fi
  printf 'meta=%s;poll=%s;pr=%s\n' "$meta" "$poll" "$pr"
}

# Annotate replayed rows whose stored anchor no longer matches the task's
# current one. The stored line is never rewritten; the marker is added only to
# what the replay emits.
annotate_superseded() { # reads rows on stdin
  local line task anchor current
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    task=$(printf '%s\n' "$line" | jq -r '.task // ""')
    anchor=$(printf '%s\n' "$line" | jq -r '.anchor // ""')
    if [ -n "$anchor" ] && current=$(claim_anchor "$task") && [ "$current" != "$anchor" ]; then
      printf '%s\n' "$line" | jq -c '. + {superseded: true}'
    else
      printf '%s\n' "$line"
    fi
  done
}

record_seq() { # <jsonl-line>
  printf '%s\n' "$1" | sed -n 's/^{"seq":\([0-9]*\),.*/\1/p'
}

print_unread() {
  local cursor seq line
  cursor=$(read_cursor)
  [ -s "$STORE" ] || return 0
  while IFS= read -r line; do
    seq=$(record_seq "$line")
    [ -n "$seq" ] || continue
    [ "$seq" -gt "$cursor" ] || continue
    printf '%s\n' "$line"
  done < "$STORE"
}

advance_cursor() { # <seq>
  local through=$1 cursor tmp
  cursor=$(read_cursor)
  [ "$through" -gt "$cursor" ] || return 0
  tmp=$(mktemp "$STATE/.branch-outcomes-cursor.XXXXXX")
  printf '%s\n' "$through" > "$tmp"
  mv -f -- "$tmp" "$CURSOR"
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  append)
    TASK=''
    VERDICT=''
    SUMMARY=''
    WAKE=''
    SILENT=false
    ANCHOR=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) TASK=${2:-}; shift 2 || usage ;;
        --verdict) VERDICT=${2:-}; shift 2 || usage ;;
        --summary) SUMMARY=${2:-}; shift 2 || usage ;;
        --wake) WAKE=${2:-}; shift 2 || usage ;;
        --silent) SILENT=${2:-}; shift 2 || usage ;;
        --anchor) ANCHOR=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$TASK" ] || usage
    [ -n "$SUMMARY" ] || usage
    case "$VERDICT" in routine|captain) ;; *) usage ;; esac
    case "$SILENT" in true|false) ;; *) usage ;; esac
    fm_lock_acquire_wait "$LOCK"
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the outcome store has a malformed final record" >&2
      exit 1
    fi
    SEQ=$(( LAST_SEQ + 1 ))
    printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s","silent":%s,"anchor":"%s"}\n' \
      "$SEQ" "$(date +%s)" "$(json_escape "$TASK")" "$(json_escape "$WAKE")" \
      "$VERDICT" "$(json_escape "$SUMMARY")" "$SILENT" "$(json_escape "$ANCHOR")" >> "$STORE"
    fm_lock_release "$LOCK"
    printf '%s\n' "$SEQ"
    ;;
  claim-anchor)
    [ "${1:-}" = --task ] || usage
    [ "$#" -eq 2 ] || usage
    [ -n "${2:-}" ] || usage
    claim_anchor "$2" || {
      echo "error: task id is not path-safe" >&2
      exit 1
    }
    ;;
  unread)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    print_unread
    fm_lock_release "$LOCK"
    ;;
  mark-read)
    [ "${1:-}" = --through ] || usage
    THROUGH=${2:-}
    case "$THROUGH" in ''|*[!0-9]*) usage ;; esac
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    advance_cursor "$THROUGH"
    fm_lock_release "$LOCK"
    ;;
  list)
    RECENT=20
    if [ "${1:-}" = --recent ]; then
      RECENT=${2:-}
      case "$RECENT" in ''|*[!0-9]*|0) usage ;; esac
      shift 2 || usage
    fi
    [ "$#" -eq 0 ] || usage
    [ -s "$STORE" ] || exit 0
    tail -n "$RECENT" "$STORE"
    ;;
  startup-replay)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    UNREAD=$(print_unread)
    if [ -n "$UNREAD" ]; then
      VISIBLE=$(printf '%s\n' "$UNREAD" | jq -c 'select(.silent != true)' | annotate_superseded)
      if [ -n "$VISIBLE" ]; then
        printf 'BRANCH OUTCOMES (handled by the supervision branch, not yet seen by this session):\n'
        printf '%s\n' "$VISIBLE"
      fi
      LAST=$(record_seq "$(printf '%s\n' "$UNREAD" | tail -n 1)")
      [ -z "$LAST" ] || advance_cursor "$LAST"
    fi
    fm_lock_release "$LOCK"
    ;;
  *) usage ;;
esac
