#!/usr/bin/env bash
# Pull-request lifecycle follow-through adapter for the generic process-event
# runner: register one persistent source per PR Firstmate raised, poll the forge
# for new review activity on a quiet cadence, and publish every detected change
# as one durable wake that survives task cleanup, merge, and restart.
#
# Usage:
#   fm-procevent-pr-follow.sh arm <task-id> <pr-url> [--backfill]
#   fm-procevent-pr-follow.sh backfill
#   fm-procevent-pr-follow.sh run <source-id>
#   fm-procevent-pr-follow.sh handle <source-id> <sequence> <result-file>
#   fm-procevent-pr-follow.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-pr-follow.sh classify <result-file>
#   fm-procevent-pr-follow.sh terminal <result-file>
#   fm-procevent-pr-follow.sh self-announcing
#   fm-procevent-pr-follow.sh source-id <pr-url>
#   fm-procevent-pr-follow.sh retire <source-id> [--force]
#
# arm        Register lifecycle tracking for one PR identity (the same
#            provider-tagged identity fm-pr-lib.sh validates everywhere). The
#            canonical source id is "prf-gh-<hash12>" or "prf-gl-<hash12>",
#            where hash12 is the first 12 hex digits of the SHA-256 over
#            "<host>/<path>#<number>" (GitHub) or "<host>/<path>!<number>"
#            (GitLab). Registration persists in state/procevent/ independent of
#            any task; the private cursor seed is written under state/pr-follow/.
#            --backfill additionally makes the next poll surface currently
#            unanswered inline review threads (see the backfill contract below)
#            instead of only baselining silently. Re-running arm for an already
#            tracked identity succeeds without changing anything.
# backfill   Guarded migration sweep: arm every PR currently recorded in this
#            home (state/*.meta with a validated pr= identity) that has no
#            lifecycle registration yet, each with --backfill. Bounded, local
#            only, and idempotent; it never talks to a forge.
# run        The blocking child the generic runner executes; never run it in a
#            conversational turn. It loads the durable cursor, polls the forge
#            through gh (GitHub) or glab (GitLab) with fixed argv plus
#            structural field selection, and on the first new event prints one
#            bounded result document and exits. A no-change poll prints nothing
#            and keeps waiting. A bounded run of consecutive failed fetches
#            prints a diagnostic error document that invents no forge result.
# handle     Apply one captured result and acknowledge it: merge the document's
#            cursor into the durable cursor (monotonic, receipt-bound per
#            sequence, idempotent under byte-identical replay), then record the
#            generic handled acknowledgement. The runner calls the same logic
#            through autohandle right after capture, so cursor advance never
#            depends on a handler remembering.
# classify   Print the captured document class: events, backfill, error, or
#            unknown.
# terminal   Always refuses (exit 1): tracking never ends by itself. A merged,
#            closed, or long-dead PR keeps its registration until the explicit
#            retire below; the runner therefore never auto-retires this source.
# retire     The one explicit, auditable retirement command. It stops the
#            runner through the generic retirement path, then removes the
#            cursor and per-sequence receipts. Refuses while unhandled captured
#            results exist unless --force. Never invoked by a merge.
#
# Detection contract (per poll, for the current head unless stated):
#   new issue/PR comments; new inline review comments and replies; new review
#   submissions and their state changes (GitHub review states including
#   DISMISSED; GitLab thread resolved/unresolved transitions and approval
#   grants/revocations); head SHA replacement; check-run (GitHub) or pipeline
#   (GitLab, current head only) additions, pending transitions, regressions,
#   and recoveries; PR merge, close, and reopen; and every comment, review, or
#   relevant check change after merge, because the cursor keeps advancing for
#   the PR's whole retained lifetime.
#
# Cursor contract: every event is identified by its stable forge id (comment,
#   review, check-run, pipeline, thread, or approval identity) plus, where
#   meaningful, the head SHA and PR state it belongs to; per-collection maxima
#   plus bounded state maps form one durable cursor per PR. Restart, duplicate
#   API pages, and retried polls recompute the same delta from the same cursor,
#   so nothing is lost and nothing already announced is re-announced; a
#   document whose cursor merge was interrupted stays announced until a
#   successful handle, which the monotonic merge makes safe to repeat.
# Vocabulary contract: one shared word list per mapped field owns both halves
#   of every writer-versus-reader pair. The poll projections normalize unknown
#   forge words to a safe explicit catch-all ("unknown" status or review
#   state, "none" absent conclusion) BEFORE composing a stored token, and the
#   cursor and document validators accept exactly what those same lists plus
#   the catch-alls can compose, so an ordinary forge vocabulary change can
#   never emit a token the reader refuses, silently drop an event, or make a
#   tracked PR unreadable. A mapped value that is not in the shared vocabulary
#   after normalization means the stored record was tampered with, not that
#   the forge evolved.
# Monitoring-loss contract: a captured document that claims this adapter's
#   schema and source but fails its own validation is an adapter defect, not
#   tampering, and is refused with a distinct diagnostic naming that class.
#   After FM_PR_FOLLOW_APPLY_BOUND such refusals the source is quarantined: the
#   failing capture is acknowledged so re-announcement stops, a private
#   quarantine record pauses polling, and exactly one bounded monitoring-loss
#   error document (fixed text, no forge bytes) surfaces the pause until it is
#   applied. A document that does not claim this schema and source is tampered
#   or foreign input and is refused loudly every time without a latch, because
#   only an operator can resolve it; re-arm with arm clears a quarantine and
#   resumes tracking once the adapter is repaired.
# Baseline contract: arm writes a pending-baseline seed; the first poll stores
#   the PR's current maxima and maps silently and emits nothing, so registering
#   a brand-new PR replays no creation noise. --backfill instead surfaces each
#   currently unanswered inline thread (a thread whose chronologically last
#   comment author is not the PR author and which GitLab does not mark
#   resolved) as one backfill-thread event, up to the per-document event bound,
#   and sets an applied backfill=done latch only through handle.
# Failure contract: one failed fetch advances a persisted error streak; past
#   the budget the child prints an error document carrying only fixed
#   diagnostic text - never a forged forge result - waits one cadence so a
#   persistent failure cannot wake per reconcile, and resets the streak. The
#   cursor is untouched, so the next healthy poll resumes exactly where the
#   cursor says.
# Untrusted-data contract: every remote title, author, path, name, URL, ref,
#   and identifier is data. All forge queries are fixed argv built only from
#   the validated identity components re-derived from the cursor; output is
#   consumed as structural field rows, sanitized (control bytes dropped,
#   bounded), and validated before use. Nothing remote is ever executed,
#   sourced, interpolated into a command, or allowed to choose one, and the
#   wake line carries only the fixed event "procevent pr-follow <sid> <seq>" -
#   remote prose reaches firstmate only as stored result data.
# Merge authority: this tracker notifies and records only. It never approves,
#   merges, closes, reopens, comments, pushes, dismisses, or otherwise modifies
#   a PR; no such capability exists in this script.
# Bounded polling: one no-change poll costs one core fetch plus one page per
#   collection that still has entries above the cursor, each page capped at 100
#   rows and FM_PR_FOLLOW_MAX_PAGES pages per collection; state maps keep the
#   FM_PR_FOLLOW_MAP_LIMIT highest ids, and the durable per-collection maximum
#   keeps an id the bound evicted from reading back as one nobody announced;
#   one document carries at most
#   FM_PR_FOLLOW_MAX_EVENTS events plus the head and pr-state lines, which are
#   exempt because their cursor advance is not re-announced, and per-collection
#   maxima advance only to what was announced, so an overflowed poll
#   re-announces its remainder next poll instead of losing it. GitHub reviews come from one fixed GraphQL
#   last-100 query, so more than 100 reviews between two polls can only be
#   partially observed; the announced-only maximum keeps the remainder bounded
#   to that same shape.
# Aggregate bound (rotation): tracked PRs poll through a deterministic modular
#   rotation, never one hot loop per PR. Time is divided into
#   FM_PR_FOLLOW_ROTATION_SLOT-second slots; the sorted roster of registered
#   pr-follow sources assigns slot t to roster index (t mod N), so at most one
#   source polls per slot regardless of how many PRs are tracked and no source
#   can be starved: every source owns exactly one slot per N-slot cycle.
#   Worst case at the defaults (slot 300 s, a full 13-fetch burst): 156 forge
#   requests per hour for the whole home, independent of the tracked count;
#   per-PR poll interval is at most N x slot while open and N x slot x
#   FM_PR_FOLLOW_SETTLED_EVERY once merged or closed, because settled sources
#   poll only every SETTLED_EVERY-th visit of their slot. The first poll after
#   a child starts is immediate (baseline and post-restart verification), and
#   roster churn re-derives every duty assignment from the current roster on
#   each wake, costing at most one extra cycle. Registration is never capped:
#   every open, closed-unmerged, merged, and post-merge PR stays tracked until
#   the explicit retire.
#
# Result document (the captured result named by the wake):
#   schema: fm-pr-follow-event-v1
#   source: <sid>
#   provider: <github|gitlab>
#   url: <validated PR url>
#   number: <n>
#   status: events|backfill|error
#   head: <sha>                (absent on error documents)
#   state: <open|closed|merged>
#   dropped: <0|1>             (1 = a bound truncated this poll's delta)
#   events: <count>
#   event: <type> <key>=<value>...
#   cursor:                    (absent on error documents)
#   <key>=<value> lines the handle step merges into the durable cursor
#
# Environment: FM_PR_FOLLOW_INTERVAL (minimum pause in seconds between
#   diagnostic documents and quarantine re-checks, default 300),
#   FM_PR_FOLLOW_FETCH_TIMEOUT (per-fetch bound, default 60),
#   FM_PR_FOLLOW_ERROR_BUDGET (consecutive failed fetches before an error
#   document, default 3), FM_PR_FOLLOW_MAX_PAGES (per-collection page bound,
#   default 5), FM_PR_FOLLOW_MAX_EVENTS (per-document event bound, default 60,
#   at most 198 so a document plus its two exempt lifecycle lines stays inside
#   the 200-event document limit the reader enforces),
#   FM_PR_FOLLOW_MAP_LIMIT (bounded review/check/thread map size, default 40,
#   at most 2048; a map is trimmed to the reader's 8192-character limit too),
#   FM_PR_FOLLOW_ROTATION_SLOT (rotation slot seconds, default 300),
#   FM_PR_FOLLOW_SETTLED_EVERY (settled sources poll every N-th duty visit,
#   default 3), FM_PR_FOLLOW_APPLY_BOUND (adapter-validation failures before
#   quarantine, default 2).
# Ownership, durable capture, publication, restart recovery, and the handled
# acknowledgement all belong to bin/fm-procevent.sh; this adapter owns only the
# PR lifecycle semantics above. docs/configuration.md "Process-to-event
# sources" owns the operating contract.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

FOLLOW_DIR="$STATE/pr-follow"
REG_DIR=$(fm_procevent_registry_dir "$STATE")
CURSOR_SCHEMA=fm-pr-follow-cursor-v1
DOC_SCHEMA=fm-pr-follow-event-v1

# The reader's hard limits on one captured document and on one stored map or
# set. They own both halves of the writer-versus-reader boundary: the
# validators below enforce them, the writer trims to them, and env_bounds_valid
# refuses any configured bound that could compose bytes past them.
DOC_EVENT_LIMIT=200
DOC_EXEMPT_EVENTS=2
MAP_CHARS_LIMIT=8192
MAP_MIN_ENTRY_CHARS=4
APPROVAL_SET_CHARS_LIMIT=4096

INTERVAL=${FM_PR_FOLLOW_INTERVAL:-300}
FETCH_TIMEOUT=${FM_PR_FOLLOW_FETCH_TIMEOUT:-60}
ERROR_BUDGET=${FM_PR_FOLLOW_ERROR_BUDGET:-3}
MAX_PAGES=${FM_PR_FOLLOW_MAX_PAGES:-5}
MAX_EVENTS=${FM_PR_FOLLOW_MAX_EVENTS:-60}
MAP_LIMIT=${FM_PR_FOLLOW_MAP_LIMIT:-40}
ROTATION_SLOT=${FM_PR_FOLLOW_ROTATION_SLOT:-300}
SETTLED_EVERY=${FM_PR_FOLLOW_SETTLED_EVERY:-3}
APPLY_FAIL_BOUND=${FM_PR_FOLLOW_APPLY_BOUND:-2}
GL_HOST=

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^# Environment:/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

cursor_file()   { printf '%s/%s.cursor\n' "$FOLLOW_DIR" "$1"; }
applied_file()  { printf '%s/%s.%s.applied\n' "$FOLLOW_DIR" "$1" "$2"; }
lifecycle_lock_path() { printf '%s/.%s.lock\n' "$FOLLOW_DIR" "$1"; }

positive_int() { case "${1-}" in ''|*[!0-9]*) return 1 ;; 0) return 1 ;; *) return 0 ;; esac }
nonnegative_int() { case "${1-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac }

positive_number() {
  local n=${1-}
  local LC_ALL=C
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [ "$n" != 0 ] && [[ ! "$n" =~ ^0+(\.0+)?$ ]]
}

env_bounds_valid() {
  positive_number "$INTERVAL" || return 1
  positive_int "$FETCH_TIMEOUT" || return 1
  positive_int "$ERROR_BUDGET" || return 1
  positive_int "$MAX_PAGES" || return 1
  positive_int "$MAX_EVENTS" || return 1
  [ "$MAX_EVENTS" -le "$((DOC_EVENT_LIMIT - DOC_EXEMPT_EVENTS))" ] || return 1
  positive_int "$MAP_LIMIT" || return 1
  [ "$MAP_LIMIT" -le "$((MAP_CHARS_LIMIT / MAP_MIN_ENTRY_CHARS))" ] || return 1
  positive_int "$ROTATION_SLOT" || return 1
  positive_int "$SETTLED_EVERY" || return 1
  positive_int "$APPLY_FAIL_BOUND"
}

# --- forge status vocabulary (single owner) ----------------------------------
# These lists are the one owner of every word a stored check, review, or
# thread token may contain. The poll projections normalize forge words into
# these lists (with "unknown" as the universal catch-all) before composing a
# stored token, and the validators below accept exactly these lists plus the
# catch-all, so the write side and the read side cannot drift apart. Adding a
# forge word means adding it here and only here.
PRF_GH_STATUS_WORDS='queued in_progress waiting requested pending completed'
PRF_GH_CONCLUSION_WORDS='none success failure neutral cancelled skipped timed_out action_required stale'
PRF_GH_REVIEW_STATES='APPROVED CHANGES_REQUESTED COMMENTED DISMISSED PENDING'
PRF_GL_PIPELINE_WORDS='created waiting_for_resource preparing pending running success failed canceled skipped'
PRF_GL_THREAD_STATES='resolved unresolved'

prf_word_in_list() {  # <word> <space-separated list>
  local w
  for w in $2; do
    [ "$w" = "$1" ] && return 0
  done
  return 1
}

# "unknown" is the catch-all every normalizer maps unrecognized words onto, so
# it is valid everywhere without being a member of any list.
prf_status_word_valid()    { [ "${1-}" = unknown ] || prf_word_in_list "${1-}" "$PRF_GH_STATUS_WORDS"; }
prf_conclusion_word_valid() { [ "${1-}" = unknown ] || prf_word_in_list "${1-}" "$PRF_GH_CONCLUSION_WORDS"; }
prf_pipeline_word_valid()  { [ "${1-}" = unknown ] || prf_word_in_list "${1-}" "$PRF_GL_PIPELINE_WORDS"; }
prf_review_state_word_valid() { [ "${1-}" = unknown ] || prf_word_in_list "${1-}" "$PRF_GH_REVIEW_STATES"; }
prf_thread_state_word_valid() { [ "${1-}" = unknown ] || prf_word_in_list "${1-}" "$PRF_GL_THREAD_STATES"; }

# prf_jq_membership <list>: the jq boolean expression ". == "w1" or . ==
# "w2" ..." over the lists above, so the forge-side normalization filter and
# the validators read the same vocabulary.
prf_jq_membership() {
  local w first=1 expr=
  for w in $1; do
    if [ "$first" -eq 1 ]; then first=0; else expr+=' or '; fi
    expr+=". == \"$w\""
  done
  printf '%s' "$expr"
}

# The GitLab pipeline normalizer reads the same shared list through this
# environment binding; "unknown" is appended as the catch-all there too.
GL_PIPELINE_RE="$(printf '%s' "$PRF_GL_PIPELINE_WORDS" | tr ' ' '|')|unknown"
export GL_PIPELINE_RE

# --- identity ----------------------------------------------------------------

sha256_string() {
  local LC_ALL=C
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

# prf_source_id <provider> <host> <path> <number>: the canonical, bounded,
# stable source id for one validated PR identity.
prf_source_id() {
  local provider=$1 host=$2 path=$3 number=$4 hash short rest
  case "$provider" in
    github) hash=$(sha256_string "$host/$path#$number") || return 1 ;;
    gitlab) hash=$(sha256_string "$host/$path!$number") || return 1 ;;
    *) return 1 ;;
  esac
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  rest=${hash#????????????}
  short=${hash%"$rest"}
  case "$provider" in
    github) printf 'prf-gh-%s\n' "$short" ;;
    gitlab) printf 'prf-gl-%s\n' "$short" ;;
  esac
}

prf_source_id_valid() {
  local id=${1-}
  fm_procevent_source_id_valid "$id" || return 1
  case "$id" in
    prf-gh-????????????|prf-gl-????????????) ;;
    *) return 1 ;;
  esac
}

# --- bounded field hygiene ---------------------------------------------------

# prf_sanitize <max-chars>: one line of bounded, control-free data text on
# stdout. Field values are data only; this keeps them structurally safe.
prf_sanitize() {
  local max=$1
  local LC_ALL=C
  tr '\000-\010\013\014\016-\037\177' '?' | tr '\t' ' ' | tr -d '\n' | cut -c 1-"$max"
}

prf_login_valid() {
  local v=${1-}
  local LC_ALL=C
  case "$v" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#v}" -le 60 ]
}

prf_state_valid() {
  case "${1-}" in
    open|closed|merged|unknown) return 0 ;;
  esac
  return 1
}

prf_head_valid() { fm_pr_head_valid "${1-}"; }

# prf_check_token_valid <token>: one stored check token is either a bare
# GitLab pipeline word or the composite "<gh-status>:<gh-conclusion>", each
# half from the shared vocabulary (with "unknown" as the catch-all). This is
# the reader half of the single-owner vocabulary contract.
prf_check_token_valid() {
  local token=${1-} status conclusion
  [ "${#token}" -le 40 ] || return 1
  case "$token" in *[!a-z_:]*) return 1 ;; esac
  status=${token%%:*}
  if [ "$status" = "$token" ]; then
    prf_pipeline_word_valid "$token"
    return $?
  fi
  conclusion=${token#*:}
  prf_status_word_valid "$status" && prf_conclusion_word_valid "$conclusion"
}

prf_map_valid() {
  local map=${1-} rest entry id token
  [ -n "$map" ] || return 0
  [ "${#map}" -le "$MAP_CHARS_LIMIT" ] || return 1
  rest=$map
  while [ -n "$rest" ]; do
    entry=${rest%%,*}
    case "$rest" in
      *,*) rest=${rest#*,} ;;
      *) rest= ;;
    esac
    id=${entry%%:*}
    token=${entry#*:}
    [ "$token" != "$entry" ] || return 1
    nonnegative_int "$id" || return 1
    prf_check_token_valid "$token" || return 1
  done
  return 0
}

prf_review_map_valid() {
  local map=${1-} rest entry id state
  [ -n "$map" ] || return 0
  [ "${#map}" -le "$MAP_CHARS_LIMIT" ] || return 1
  rest=$map
  while [ -n "$rest" ]; do
    entry=${rest%%,*}
    case "$rest" in
      *,*) rest=${rest#*,} ;;
      *) rest= ;;
    esac
    id=${entry%%:*}
    state=${entry#*:}
    [ "$state" != "$entry" ] || return 1
    nonnegative_int "$id" || return 1
    prf_review_state_word_valid "$state" || return 1
  done
  return 0
}

# GitLab discussion ids are forge-opaque strings, not integers.
prf_thread_map_valid() {
  local map=${1-} rest entry id state
  [ -n "$map" ] || return 0
  [ "${#map}" -le "$MAP_CHARS_LIMIT" ] || return 1
  rest=$map
  while [ -n "$rest" ]; do
    entry=${rest%%,*}
    case "$rest" in
      *,*) rest=${rest#*,} ;;
      *) rest= ;;
    esac
    id=${entry%%:*}
    state=${entry#*:}
    [ "$state" != "$entry" ] || return 1
    case "$id" in
      ''|*[!A-Za-z0-9_-]*) return 1 ;;
    esac
    [ "${#id}" -le 64 ] || return 1
    prf_thread_state_word_valid "$state" || return 1
  done
  return 0
}

prf_approval_set_valid() {
  local set=${1-} rest entry
  [ -n "$set" ] || return 0
  [ "${#set}" -le "$APPROVAL_SET_CHARS_LIMIT" ] || return 1
  rest=$set
  while [ -n "$rest" ]; do
    entry=${rest%%,*}
    case "$rest" in
      *,*) rest=${rest#*,} ;;
      *) rest= ;;
    esac
    prf_login_valid "$entry" || return 1
  done
  return 0
}

# --- id-keyed state maps -----------------------------------------------------

# map_get <map> <id>: print the value for id, or nothing.
map_get() {
  printf '%s' "$1" | tr ',' '\n' | awk -F: -v want="$2" '
    $1 == want { sub(/^[^:]*:/, ""); print; exit }
  '
}

# map_put <map> <id> <value>: set or replace one entry; prints the new map.
map_put() {
  printf '%s' "$1" | tr ',' '\n' | awk -F: -v want="$2" -v val="$3" '
    $1 == want { print want ":" val; found = 1; next }
    NF > 0 { print }
    END { if (!found) print want ":" val }
  ' | tr '\n' ',' | sed 's/,$//'
}

# max_map_entries <map> <limit>: keep the limit highest-id entries that also
# fit the reader's character limit, so no configured bound and no forge id
# length can compose a map the validators refuse.
max_map_entries() {
  [ -n "$1" ] || return 0
  printf '%s' "$1" | tr ',' '\n' | awk -F: '{print $1 + 0 " " $0}' \
    | sort -n -r | head -n "$2" \
    | awk -v budget="$MAP_CHARS_LIMIT" '{
        entry = substr($0, index($0, " ") + 1)
        need = length(entry) + (used == 0 ? 0 : 1)
        if (used + need > budget) next
        printf "%s%s", sep, entry
        sep = ","
        used += need
      }'
}

# max_check_id <check rows> <floor>: the highest validated id in the rows,
# never below the floor. The check map is bounded, so this watermark is what
# keeps an evicted id from reading back as a check nobody has announced yet.
max_check_id() {
  local rows=$1 highest=$2 id rest
  while IFS=$'\t' read -r id rest; do
    [ -n "$id" ] || continue
    nonnegative_int "$id" || continue
    [ "$id" -gt "$highest" ] && highest=$id
  done <<< "$rows"
  printf '%s' "$highest"
}

# reverse_rows <rows-var-name>: print the rows oldest first. Descending API
# pages arrive newest first; thread reconstruction wants parents before
# replies.
reverse_rows() {
  printf '%s' "$1" | awk '{a[i++] = $0} END {for (j = i - 1; j >= 0; j--) print a[j]}'
}

# --- snapshot plumbing -------------------------------------------------------
# One poll fills SN_* scalars plus newline-separated TSV rows. Every field is
# validated or sanitized when it is consumed, never trusted from the wire.

SN_STATE=unknown
SN_HEAD=
SN_AUTHOR=
SN_ROWS=
SN_RC_ROWS=
SN_REVIEW_ROWS=
SN_CHECK_ROWS=
SN_THREAD_ROWS=
SN_NOTE_ROWS=
SN_APPROVAL_ROWS=
SN_APPROVALS_OK=0
SN_FETCH_ERROR=
GH_OUT=

sn_reset() {
  SN_STATE=unknown
  SN_HEAD=''
  SN_AUTHOR=''
  SN_ROWS=''
  SN_RC_ROWS=''
  SN_REVIEW_ROWS=''
  SN_CHECK_ROWS=''
  SN_THREAD_ROWS=''
  SN_NOTE_ROWS=''
  SN_APPROVAL_ROWS=''
  SN_APPROVALS_OK=0
  SN_FETCH_ERROR=
}

fetch_fail() {  # <fixed step label> <exit code>: records a fixed diagnostic
  SN_FETCH_ERROR="fetch failed at $1 (exit $2)"
  return 1
}

# gh_rows <jq-filter> <gh args...>: one fixed gh call, structural rows in GH_OUT.
gh_rows() {
  local filter=$1 out rc
  shift
  out=$(fm_run_timed "$FETCH_TIMEOUT" gh "$@" --jq "$filter" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || { fetch_fail "gh ${1:-api}" "$rc"; return 1; }
  GH_OUT=$out
  return 0
}

# gh_descending_pages <filter> <api-path-base> <cursor-max> <outvar>
# Walks sort=created&direction=desc pages, newest first, stopping on an empty
# page, a short page, an all-old page, or the page bound. Duplicate or
# reordered pages are harmless: event selection deduplicates by id against the
# durable cursor.
gh_descending_pages() {
  local filter=$1 base=$2 cursor_max=$3 outvar=$4 page lines id rest all_old n out=
  page=1
  while [ "$page" -le "$MAX_PAGES" ]; do
    gh_rows "$filter" api "${base}?per_page=100&sort=created&direction=desc&page=${page}" || return 1
    lines=$GH_OUT
    if [ -z "$lines" ]; then
      break
    fi
    out+=$lines$'\n'
    n=$(printf '%s\n' "$lines" | grep -c .)
    [ "$n" -eq 100 ] || break
    all_old=1
    while IFS=$'\t' read -r id rest; do
      [ -n "$id" ] || continue
      if nonnegative_int "$id" && [ "$id" -gt "$cursor_max" ]; then
        all_old=0
        break
      fi
    done <<< "$lines"
    [ "$all_old" -eq 1 ] && break
    page=$((page + 1))
  done
  printf -v "$outvar" '%s' "$out"
  return 0
}

poll_github() {
  local url=$1 owner=$2 repo=$3 number=$4
  local out rc state head author login filter
  local gh_status_test gh_conclusion_test gh_review_test
  sn_reset
  gh_status_test=$(prf_jq_membership "$PRF_GH_STATUS_WORDS")
  gh_conclusion_test=$(prf_jq_membership "$PRF_GH_CONCLUSION_WORDS")
  gh_review_test=$(prf_jq_membership "$PRF_GH_REVIEW_STATES")
  out=$(fm_run_timed "$FETCH_TIMEOUT" gh pr view "$url" --json state,headRefOid,author \
        -q '[.state, (.headRefOid // ""), (.author.login // "ghost")] | @tsv' 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || { fetch_fail "gh pr view" "$rc"; return 1; }
  state=$(printf '%s' "$out" | cut -f1)
  head=$(printf '%s' "$out" | cut -f2)
  author=$(printf '%s' "$out" | cut -f3)
  # An unrecognized lifecycle word is ordinary forge evolution, not a fetch
  # failure: it normalizes to the "unknown" catch-all and round-trips through
  # the whole production path (vocabulary contract).
  case "$state" in
    OPEN) SN_STATE=open ;;
    CLOSED) SN_STATE=closed ;;
    MERGED) SN_STATE=merged ;;
    *) SN_STATE=unknown ;;
  esac
  prf_head_valid "$head" || { fetch_fail "gh pr view head" 1; return 1; }
  SN_HEAD=$head
  login=$(printf '%s' "$author" | prf_sanitize 60)
  prf_login_valid "$login" || login=invalid
  SN_AUTHOR=$login

  gh_descending_pages '.[] | [.id, (.user.login // "ghost")] | @tsv' \
    "repos/$owner/$repo/issues/$number/comments" "$CUR_MAX_ISSUE_COMMENT" SN_ROWS || return 1

  gh_descending_pages \
    '.[] | [.id, (.in_reply_to_id // 0), (.user.login // "ghost"), (.path // ""), ((.line // .original_line) // 0)] | @tsv' \
    "repos/$owner/$repo/pulls/$number/comments" "$CUR_MAX_REVIEW_COMMENT" SN_RC_ROWS || return 1

  # The normalization tests below are generated from the same shared lists the
  # validators read (vocabulary contract), so only a token the cursor accepts
  # can ever be stored.
  filter=".data.repository.pullRequest.reviews.nodes[] | [.databaseId, ((.state // \"unknown\") | if $gh_review_test then . else \"unknown\" end), (.author.login // \"ghost\")] | @tsv"
  # shellcheck disable=SC2016 # The GraphQL query is fixed text; its $ arguments are gh variables.
  gh_rows "$filter" \
    api graphql \
    -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviews(last:100){nodes{databaseId state author{login}}}}}}' \
    -F "owner=$owner" -F "name=$repo" -F "number=$number" || return 1
  SN_REVIEW_ROWS=$GH_OUT

  filter=".check_runs[] | [.id, (((.status // \"unknown\") | if $gh_status_test then . else \"unknown\" end) + \":\" + ((.conclusion // \"none\") | if $gh_conclusion_test then . else \"unknown\" end)), (.name // \"check\")] | @tsv"
  gh_rows "$filter" \
    api "repos/$owner/$repo/commits/$SN_HEAD/check-runs?per_page=100" || return 1
  SN_CHECK_ROWS=$GH_OUT
  return 0
}

# glab_rows <api-path> <perl-row-program>: one fixed glab api call; its JSON is
# structurally decoded and reduced to rows. Malformed JSON or an unexpected
# shape is a fetch failure, never a result.
glab_rows() {
  local path=$1 program=$2 out rc
  out=$(fm_run_timed "$FETCH_TIMEOUT" env GITLAB_HOST="$GL_HOST" glab api "$path" 2>/dev/null \
        | perl -MJSON::PP -e "$program")
  rc=$?
  [ "$rc" -eq 0 ] || { fetch_fail "glab api ${path%%\?*}" "$rc"; return 1; }
  GH_OUT=$out
  return 0
}

# shellcheck disable=SC2016 # Perl owns every $ expression in this program.
GL_DISCUSSIONS_PROGRAM='
use strict; use warnings;
my $d = eval { local $/; decode_json(scalar <STDIN>) };
exit 3 unless $d && ref $d eq "ARRAY";
my $clean = sub { my $s = shift // ""; $s =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/ /g; $s =~ s/\s+/ /g; $s = substr($s, 0, 120); return $s; };
for my $disc (@$d) {
  next unless ref $disc eq "HASH";
  my $did = $disc->{id} // "";
  next unless $did =~ /^[A-Za-z0-9_-]{1,64}\z/;
  my $resolved = $disc->{resolved} ? "resolved" : "unresolved";
  my $notes = $disc->{notes} // [];
  next unless ref $notes eq "ARRAY";
  my $i = 0;
  for my $nt (@$notes) {
    next unless ref $nt eq "HASH";
    next if ($nt->{system} // 0);
    my $nid = $nt->{id} // "";
    next unless $nid =~ /^[0-9]+\z/;
    my $author = $nt->{author}{username} // "ghost";
    $author = "invalid" unless $author =~ /^[A-Za-z0-9._-]{1,60}\z/;
    my $isdiff = (($nt->{type} // "") ne "" || defined $nt->{position}) ? 1 : 0;
    my $path = ""; my $line = 0;
    if (defined $nt->{position}) {
      $path = $clean->($nt->{position}{new_path} // "");
      $line = int(($nt->{position}{new_line} // $nt->{position}{old_line} // 0) || 0);
    }
    print join("\t", $nid, $author, $isdiff ? "inline" : "note", $path, $line, $did, ($i == 0 ? 1 : 0)), "\n";
    $i++;
  }
  print join("\t", "T", $did, $resolved), "\n";
}
'

poll_gitlab() {
  local host=$1 path=$2 number=$3
  local enc state head author page rows n note_rows thread_rows
  GL_HOST=$host
  sn_reset
  enc=${path//\//%2F}
  # shellcheck disable=SC2016 # Perl owns every $ expression in this program.
  glab_rows "projects/$enc/merge_requests/$number" '
    use strict; use warnings;
    my $d = eval { local $/; decode_json(scalar <STDIN>) };
    exit 3 unless $d && ref $d eq "HASH";
    my $state = $d->{state} // ""; my $sha = $d->{sha} // ""; my $author = $d->{author}{username} // "ghost";
    exit 3 unless $sha =~ /^[0-9a-f]{40,64}\z/;
    $author = "invalid" unless $author =~ /^[A-Za-z0-9._-]{1,60}\z/;
    # An unrecognized lifecycle word normalizes to the "unknown" catch-all so
    # it round-trips through the whole production path (vocabulary contract).
    if    ($state eq "opened" || $state eq "locked") { $state = "open" }
    elsif ($state eq "closed") { $state = "closed" }
    elsif ($state eq "merged") { $state = "merged" }
    else   { $state = "unknown" }
    print join("\t", $state, $sha, $author), "\n";
  ' || return 1
  state=$(printf '%s' "$GH_OUT" | cut -f1)
  head=$(printf '%s' "$GH_OUT" | cut -f2)
  author=$(printf '%s' "$GH_OUT" | cut -f3)
  SN_STATE=$state
  SN_HEAD=$head
  SN_AUTHOR=$author

  page=1
  note_rows=
  thread_rows=
  while [ "$page" -le "$MAX_PAGES" ]; do
    glab_rows "projects/$enc/merge_requests/$number/discussions?per_page=100&page=$page" \
      "$GL_DISCUSSIONS_PROGRAM" || return 1
    rows=$GH_OUT
    if [ -z "$rows" ]; then
      break
    fi
    note_rows+=$(printf '%s\n' "$rows" | awk -F '\t' '$1 != "T"')$'\n'
    thread_rows+=$(printf '%s\n' "$rows" | awk -F '\t' '$1 == "T" {print $2 "\t" $3}')$'\n'
    n=$(printf '%s\n' "$rows" | awk -F '\t' '$1 == "T"' | grep -c .)
    [ "$n" -eq 100 ] || break
    page=$((page + 1))
  done
  SN_NOTE_ROWS=$note_rows
  SN_THREAD_ROWS=$thread_rows

  # shellcheck disable=SC2016 # Perl owns every $ expression in this program.
  glab_rows "projects/$enc/merge_requests/$number/pipelines?per_page=100" '
    use strict; use warnings;
    my $d = eval { local $/; decode_json(scalar <STDIN>) };
    exit 3 unless $d && ref $d eq "ARRAY";
    # GL_PIPELINE_RE is generated from the same shared list the validators
    # read, with "unknown" as the catch-all (vocabulary contract).
    my $re = qr/^(?:$ENV{GL_PIPELINE_RE})\z/;
    for my $p (@$d) {
      next unless ref $p eq "HASH";
      my $id = $p->{id} // ""; my $status = $p->{status} // ""; my $sha = $p->{sha} // "";
      next unless $id =~ /^[0-9]+\z/ && $sha =~ /^[0-9a-f]{40,64}\z/;
      $status = "unknown" unless $status =~ $re;
      print join("\t", $id, $sha, $status), "\n";
    }
  ' || return 1
  # Keep the check map provider-shaped: only the current head's pipelines,
  # reduced to the same two-field id/status rows the GitHub engine produces.
  local pipeline_id pipeline_sha pipeline_status pipeline_rows=''
  while IFS=$'\t' read -r pipeline_id pipeline_sha pipeline_status; do
    [ -n "$pipeline_id" ] || continue
    nonnegative_int "$pipeline_id" || continue
    [ "$pipeline_sha" = "$SN_HEAD" ] || continue
    pipeline_rows+="$pipeline_id"$'\t'"$pipeline_status"$'\n'
  done <<< "$GH_OUT"
  SN_CHECK_ROWS=$pipeline_rows

  # Approvals are GitLab's review-submission surface. A project without the
  # approvals feature refuses this call, and so does a transient endpoint
  # failure; neither counts as a poll failure, and neither is evidence that
  # anybody withdrew an approval, so the whole approval comparison is skipped
  # unless this fetch actually answered (documented boundary).
  # shellcheck disable=SC2016 # Perl owns every $ expression in this program.
  if glab_rows "projects/$enc/merge_requests/$number/approvals" '
      use strict; use warnings;
      my $d = eval { local $/; decode_json(scalar <STDIN>) };
      exit 3 unless $d && ref $d eq "HASH";
      my $users = $d->{approved_by} // [];
      exit 3 unless ref $users eq "ARRAY";
      for my $u (@$users) {
        next unless ref $u eq "HASH" && ref $u->{user} eq "HASH";
        my $name = $u->{user}{username} // "";
        next unless $name =~ /^[A-Za-z0-9._-]{1,60}\z/;
        print "$name\n";
      }
    '; then
    SN_APPROVAL_ROWS=$(printf '%s\n' "$GH_OUT" | grep . | sort || true)
    SN_APPROVALS_OK=1
    SN_FETCH_ERROR=
  fi
  return 0
}

# --- delta computation -------------------------------------------------------
# EV_LINES holds "<sortkey>\t<event line>" pairs plus NEW_* cursor values.
# Announced-only advancement: maxima and maps move only to what the document
# actually announces, so an overflowed poll re-announces its remainder next
# poll instead of losing it.

EV_LINES=
NEW_HEAD=''
NEW_STATE=''
NEW_MAX_ISSUE_COMMENT=''
NEW_MAX_REVIEW=''
NEW_MAX_REVIEW_COMMENT=''
NEW_MAX_CHECK=''
NEW_REVIEWS=''
NEW_CHECKS=''
NEW_THREADS=''
NEW_APPROVALS=''
CHECKS_REBASELINED=0
EVENTS_DROPPED=0

ev_add() { EV_LINES+="$1"$'\n'; }

# Lines carrying the exempt sort key sort ahead of everything else and are
# kept without consuming the bound, so the head and pr-state announcements
# their cursor advancement depends on can never be truncated.
EV_KEY_EXEMPT=-1

ev_sort_and_cap() {
  local key line kept=0 budget=$MAX_EVENTS sorted=''
  local total=0 exempt=0
  EVENTS_DROPPED=0
  if [ -n "$EV_LINES" ]; then
    total=$(printf '%s\n' "$EV_LINES" | grep -c .)
    exempt=$(printf '%s\n' "$EV_LINES" | awk -F '\t' -v k="$EV_KEY_EXEMPT" '$1 == k' | grep -c . || true)
    sorted=$(printf '%s\n' "$EV_LINES" | sort -n -k1,1)
  fi
  [ "$((total - exempt))" -gt "$budget" ] && EVENTS_DROPPED=1
  EV_LINES=
  while IFS=$'\t' read -r key line; do
    [ -n "$line" ] || continue
    if [ "$key" != "$EV_KEY_EXEMPT" ]; then
      [ "$kept" -lt "$budget" ] || break
      kept=$((kept + 1))
    fi
    EV_LINES+="$line"$'\n'
  done <<< "$sorted"
}

check_key() {  # <stored status> -> green|red|pending|skipped
  case "$1" in
    completed:success|completed:neutral|completed:skipped|success) printf 'green' ;;
    completed:failure|completed:timed_out|completed:action_required|completed:stale|completed:unknown|failed) printf 'red' ;;
    completed:cancelled|completed:none|canceled|skipped) printf 'skipped' ;;
    *) printf 'pending' ;;
  esac
}

# Per-poll seen-id sets: duplicate or reordered rows within one poll announce
# each forge event exactly once.
# A seen-set value is only ever read through the seen_add indirection, which
# the linter cannot follow, so the loop stands in for four unused warnings.
for SEEN_INIT in SEEN_ISSUE SEEN_RC SEEN_REVIEW SEEN_NOTE; do
  printf -v "$SEEN_INIT" '%s' ''
done
unset SEEN_INIT

seen_add() {  # <set-var-name> <id>: SEEN_HIT=1 when already present, else appends
  # shellcheck disable=SC2086 # The set holds bare validated ids.
  case ",${!1}," in
    *",$2,"*) SEEN_HIT=1 ;;
    *)
      SEEN_HIT=0
      printf -v "$1" '%s' "${!1:+${!1},}$2"
      ;;
  esac
}

delta_common_start() {
  # shellcheck disable=SC2034 # Read through the seen_add indirection.
  SEEN_ISSUE=''
  # shellcheck disable=SC2034 # Read through the seen_add indirection.
  SEEN_RC=''
  # shellcheck disable=SC2034 # Read through the seen_add indirection.
  SEEN_REVIEW=''
  # shellcheck disable=SC2034 # Read through the seen_add indirection.
  SEEN_NOTE=''
  EV_LINES=
  NEW_HEAD=$CUR_HEAD
  NEW_STATE=$CUR_STATE
  NEW_MAX_ISSUE_COMMENT=$CUR_MAX_ISSUE_COMMENT
  NEW_MAX_REVIEW=$CUR_MAX_REVIEW
  NEW_MAX_REVIEW_COMMENT=$CUR_MAX_REVIEW_COMMENT
  NEW_MAX_CHECK=$CUR_MAX_CHECK
  NEW_REVIEWS=$CUR_REVIEWS
  NEW_CHECKS=$CUR_CHECKS
  NEW_THREADS=$CUR_THREADS
  NEW_APPROVALS=$CUR_APPROVALS
  CHECKS_REBASELINED=0
  EVENTS_DROPPED=0
}

# Announce the state change and, on a head move, rebaseline the check map
# silently for the new head. Both lines are exempt from the event bound.
# Returns 0 when the head moved (check map is already the new head's), 1 when
# the head is unchanged and per-transition detection must run.
delta_head_and_state() {
  local check_id check_sc check_name
  if [ "$CUR_BASELINE" = "done" ] && [ "$CUR_STATE" != "$SN_STATE" ]; then
    ev_add "$EV_KEY_EXEMPT	event: pr-state from=$CUR_STATE state=$SN_STATE"
  fi
  NEW_STATE=$SN_STATE
  if [ -z "$SN_HEAD" ] || [ "$SN_HEAD" = "$CUR_HEAD" ]; then
    return 1
  fi
  if [ -n "$CUR_HEAD" ]; then
    ev_add "$EV_KEY_EXEMPT	event: head from=${CUR_HEAD%"${CUR_HEAD#????????????}"} to=${SN_HEAD%"${SN_HEAD#????????????}"}"
  fi
  NEW_HEAD=$SN_HEAD
  NEW_CHECKS=
  while IFS=$'\t' read -r check_id check_sc check_name; do
    [ -n "$check_id" ] || continue
    nonnegative_int "$check_id" || continue
    NEW_CHECKS=$(map_put "$NEW_CHECKS" "$check_id" "$check_sc")
  done <<< "$SN_CHECK_ROWS"
  NEW_CHECKS=$(max_map_entries "$NEW_CHECKS" "$MAP_LIMIT")
  NEW_MAX_CHECK=$(max_check_id "$SN_CHECK_ROWS" "$NEW_MAX_CHECK")
  CHECKS_REBASELINED=1
  return 0
}

# Post-cap announced-only map and maximum rebuild: every collection's stored
# state advances only to what the surviving event lines announce.
# approval_set_insert <set-variable-name> <user>: 1 when the reader's set
# limit refuses the user, so a grant this cursor cannot record is never
# announced as one nobody has seen yet.
approval_set_insert() {
  local current=${!1} candidate
  case ",$current," in
    *",$2,"*) return 0 ;;
  esac
  candidate="${current:+$current,}$2"
  [ "${#candidate}" -le "$APPROVAL_SET_CHARS_LIMIT" ] || return 1
  printf -v "$1" '%s' "$candidate"
}

approval_set_add() {  # <user>
  approval_set_insert NEW_APPROVALS "$1"
}

approval_set_del() {  # <user>
  local rest=$NEW_APPROVALS entry out=
  while [ -n "$rest" ]; do
    entry=${rest%%,*}
    case "$rest" in
      *,*) rest=${rest#*,} ;;
      *) rest= ;;
    esac
    [ "$entry" = "$1" ] || out+="${out:+,}$entry"
  done
  NEW_APPROVALS=$out
}

advance_from_surviving() {
  local line ev_id ev_state ev_status ev_user
  NEW_MAX_ISSUE_COMMENT=$CUR_MAX_ISSUE_COMMENT
  NEW_MAX_REVIEW=$CUR_MAX_REVIEW
  NEW_MAX_REVIEW_COMMENT=$CUR_MAX_REVIEW_COMMENT
  if [ "$CHECKS_REBASELINED" -eq 0 ]; then
    NEW_CHECKS=$CUR_CHECKS
    NEW_MAX_CHECK=$CUR_MAX_CHECK
  fi
  NEW_REVIEWS=$CUR_REVIEWS
  NEW_THREADS=$CUR_THREADS
  NEW_APPROVALS=$CUR_APPROVALS
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      'event: comment '*|'event: review-comment '*)
        ev_id=${line#*id=}
        ev_id=${ev_id%% *}
        nonnegative_int "$ev_id" || continue
        case "$line" in
          'event: comment '*)
            [ "$ev_id" -gt "$NEW_MAX_ISSUE_COMMENT" ] && NEW_MAX_ISSUE_COMMENT=$ev_id
            ;;
          *)
            [ "$ev_id" -gt "$NEW_MAX_REVIEW_COMMENT" ] && NEW_MAX_REVIEW_COMMENT=$ev_id
            ;;
        esac
        ;;
      'event: review id=approval-'*)
        ev_user=${line#event: review id=approval-}
        ev_user=${ev_user%% *}
        case "$line" in
          *' state=APPROVED'*) approval_set_add "$ev_user" ;;
          *' state=DISMISSED'*) approval_set_del "$ev_user" ;;
        esac
        ;;
      'event: review '*)
        ev_id=${line#event: review id=}
        ev_id=${ev_id%% *}
        ev_state=${line#*state=}
        ev_state=${ev_state%% *}
        nonnegative_int "$ev_id" || continue
        NEW_REVIEWS=$(map_put "$NEW_REVIEWS" "$ev_id" "$ev_state")
        [ "$ev_id" -gt "$NEW_MAX_REVIEW" ] && NEW_MAX_REVIEW=$ev_id
        ;;
      'event: review-state '*)
        ev_id=${line#event: review-state id=}
        ev_id=${ev_id%% *}
        ev_state=${line#*state=}
        ev_state=${ev_state%% *}
        nonnegative_int "$ev_id" || continue
        NEW_REVIEWS=$(map_put "$NEW_REVIEWS" "$ev_id" "$ev_state")
        ;;
      'event: check '*)
        [ "$CHECKS_REBASELINED" -eq 1 ] && continue
        ev_id=${line#event: check id=}
        ev_id=${ev_id%% *}
        ev_status=${line##* status=}
        nonnegative_int "$ev_id" || continue
        [ -n "$ev_status" ] || continue
        NEW_CHECKS=$(map_put "$NEW_CHECKS" "$ev_id" "$ev_status")
        [ "$ev_id" -gt "$NEW_MAX_CHECK" ] && NEW_MAX_CHECK=$ev_id
        ;;
      'event: thread '*)
        ev_id=${line#event: thread id=}
        ev_id=${ev_id%% *}
        ev_state=${line#*state=}
        ev_state=${ev_state%% *}
        [ -n "$ev_id" ] && [ -n "$ev_state" ] || continue
        NEW_THREADS=$(map_put "$NEW_THREADS" "$ev_id" "$ev_state")
        ;;
    esac
  done <<< "$EV_LINES"
  NEW_CHECKS=$(max_map_entries "$NEW_CHECKS" "$MAP_LIMIT")
  NEW_REVIEWS=$(max_map_entries "$NEW_REVIEWS" "$MAP_LIMIT")
  NEW_THREADS=$(max_map_entries "$NEW_THREADS" "$MAP_LIMIT")
}

compute_delta_github() {
  delta_common_start
  if ! delta_head_and_state; then
    # Check transitions for the unchanged head.
    local check_id check_sc check_name key_v old oldkey
    while IFS=$'\t' read -r check_id check_sc check_name; do
      [ -n "$check_id" ] || continue
      nonnegative_int "$check_id" || continue
      key_v=$(check_key "$check_sc")
      old=$(map_get "$CUR_CHECKS" "$check_id")
      if [ -z "$old" ]; then
        if [ "$check_id" -gt "$CUR_MAX_CHECK" ]; then
          ev_add "$check_id	event: check id=$check_id name=$(printf '%s' "$check_name" | prf_sanitize 80) change=none->$key_v status=$check_sc"
        fi
      else
        oldkey=$(check_key "$old")
        if [ "$oldkey" != "$key_v" ]; then
          ev_add "$check_id	event: check id=$check_id name=$(printf '%s' "$check_name" | prf_sanitize 80) change=$oldkey->$key_v status=$check_sc"
        fi
      fi
    done <<< "$SN_CHECK_ROWS"
  fi

  # Reviews: new submissions and state changes. The projection normalizes
  # unrecognized states to "unknown", which round-trips through the map and
  # announces instead of silently dropping the event (vocabulary contract).
  local review_id review_state review_author old review_seeds=''
  while IFS=$'\t' read -r review_id review_state review_author; do
    [ -n "$review_id" ] || continue
    nonnegative_int "$review_id" || continue
    prf_review_state_word_valid "$review_state" || review_state=unknown
    review_author=$(printf '%s' "$review_author" | prf_sanitize 60)
    prf_login_valid "$review_author" || review_author=invalid
    old=$(map_get "$CUR_REVIEWS" "$review_id")
    seen_add SEEN_REVIEW "$review_id"
    [ "$SEEN_HIT" -eq 0 ] || continue
    if [ -z "$old" ]; then
      if [ "$review_id" -gt "$CUR_MAX_REVIEW" ]; then
        ev_add "$review_id	event: review id=$review_id state=$review_state author=$review_author"
      else
        review_seeds+="$review_id"$'\t'"$review_state"$'\n'
      fi
    elif [ "$old" != "$review_state" ]; then
      ev_add "$review_id	event: review-state id=$review_id state=$review_state author=$review_author"
    fi
  done <<< "$SN_REVIEW_ROWS"

  # Inline review comments and replies.
  local rc_id rc_replyto rc_author rc_path rc_line
  while IFS=$'\t' read -r rc_id rc_replyto rc_author rc_path rc_line; do
    [ -n "$rc_id" ] || continue
    nonnegative_int "$rc_id" || continue
    nonnegative_int "$rc_replyto" || rc_replyto=0
    rc_author=$(printf '%s' "$rc_author" | prf_sanitize 60)
    prf_login_valid "$rc_author" || rc_author=invalid
    rc_path=$(printf '%s' "$rc_path" | prf_sanitize 120)
    nonnegative_int "$rc_line" || rc_line=0
    if [ "$rc_id" -gt "$CUR_MAX_REVIEW_COMMENT" ]; then
      seen_add SEEN_RC "$rc_id"
      if [ "$SEEN_HIT" -eq 0 ]; then
        ev_add "$rc_id	event: review-comment id=$rc_id author=$rc_author$( [ "$rc_replyto" -gt 0 ] && printf ' reply-to=%s' "$rc_replyto") path=$rc_path line=$rc_line"
      fi
    fi
  done <<< "$SN_RC_ROWS"

  # Issue/PR comments.
  local c_id c_author
  while IFS=$'\t' read -r c_id c_author; do
    [ -n "$c_id" ] || continue
    nonnegative_int "$c_id" || continue
    c_author=$(printf '%s' "$c_author" | prf_sanitize 60)
    prf_login_valid "$c_author" || c_author=invalid
    if [ "$c_id" -gt "$CUR_MAX_ISSUE_COMMENT" ]; then
      seen_add SEEN_ISSUE "$c_id"
      [ "$SEEN_HIT" -eq 0 ] && ev_add "$c_id	event: comment id=$c_id author=$c_author"
    fi
  done <<< "$SN_ROWS"

  ev_sort_and_cap
  advance_from_surviving
  while IFS=$'\t' read -r review_id review_state; do
    [ -n "$review_id" ] || continue
    [ -z "$(map_get "$NEW_REVIEWS" "$review_id")" ] || continue
    NEW_REVIEWS=$(map_put "$NEW_REVIEWS" "$review_id" "$review_state")
  done <<< "$review_seeds"
  NEW_REVIEWS=$(max_map_entries "$NEW_REVIEWS" "$MAP_LIMIT")
  return 0
}

compute_backfill_github() {
  # Reconstruct inline threads from the full review-comment rows, oldest
  # first, and surface each thread whose chronologically last comment author
  # is not the PR author.
  local -a root_ids=() last_author=() last_path=() last_line=() thread_count=()
  local rc_id rc_replyto rc_author rc_path rc_line root found i root_n=0
  while IFS=$'\t' read -r rc_id rc_replyto rc_author rc_path rc_line; do
    [ -n "$rc_id" ] || continue
    nonnegative_int "$rc_id" || continue
    nonnegative_int "$rc_replyto" || rc_replyto=0
    rc_author=$(printf '%s' "$rc_author" | prf_sanitize 60)
    prf_login_valid "$rc_author" || rc_author=invalid
    rc_path=$(printf '%s' "$rc_path" | prf_sanitize 120)
    nonnegative_int "$rc_line" || rc_line=0
    if [ "$rc_replyto" -gt 0 ]; then
      root=$rc_replyto
      found=0
      for ((i = 0; i < root_n; i++)); do
        [ "${root_ids[$i]}" = "$root" ] && { found=1; break; }
      done
      if [ "$found" -eq 0 ]; then
        # The parent is not among the fetched rows; root the chain here so it
        # is still surfaced.
        root=$rc_id
      fi
    else
      root=$rc_id
    fi
    found=0
    for ((i = 0; i < root_n; i++)); do
      if [ "${root_ids[$i]}" = "$root" ]; then
        found=1
        last_author[i]=$rc_author
        last_path[i]=$rc_path
        last_line[i]=$rc_line
        thread_count[i]=$(( thread_count[i] + 1 ))
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      root_ids+=("$root")
      last_author+=("$rc_author")
      last_path+=("$rc_path")
      last_line+=("$rc_line")
      thread_count+=(1)
      root_n=$((root_n + 1))
    fi
  done <<< "$(reverse_rows "$SN_RC_ROWS")"
  EV_LINES=
  for ((i = 0; i < root_n; i++)); do
    if [ "${last_author[$i]}" != "$SN_AUTHOR" ]; then
      ev_add "0	event: backfill-thread id=${root_ids[$i]} last-author=${last_author[$i]} comments=${thread_count[$i]} path=${last_path[$i]} line=${last_line[$i]}"
    fi
  done
  ev_sort_and_cap
  return 0
}

compute_delta_gitlab() {
  delta_common_start
  if ! delta_head_and_state; then
    # Pipelines for the current head only: provider-shaped id/status rows.
    local check_id check_status key_v old oldkey
    while IFS=$'\t' read -r check_id check_status; do
      [ -n "$check_id" ] || continue
      nonnegative_int "$check_id" || continue
      key_v=$(check_key "$check_status")
      old=$(map_get "$CUR_CHECKS" "$check_id")
      if [ -z "$old" ]; then
        if [ -n "$CUR_HEAD" ] && [ "$check_id" -gt "$CUR_MAX_CHECK" ]; then
          ev_add "$check_id	event: check id=$check_id change=none->$key_v status=$check_status"
        fi
      else
        oldkey=$(check_key "$old")
        if [ "$oldkey" != "$key_v" ]; then
          ev_add "$check_id	event: check id=$check_id change=$oldkey->$key_v status=$check_status"
        fi
      fi
    done <<< "$SN_CHECK_ROWS"
  fi

  # Threads: resolved-state transitions. A thread opened after the baseline
  # has no map entry yet; it is seeded silently below (its notes are already
  # announced by the notes pass) so its later transition is detected.
  local thread_id thread_state old thread_seeds=''
  while IFS=$'\t' read -r thread_id thread_state; do
    [ -n "$thread_id" ] || continue
    case "$thread_state" in resolved|unresolved) ;; *) continue ;; esac
    case "$thread_id" in *[!A-Za-z0-9_-]*) continue ;; esac
    old=$(map_get "$CUR_THREADS" "$thread_id")
    if [ -z "$old" ]; then
      thread_seeds+="$thread_id"$'\t'"$thread_state"$'\n'
    elif [ "$old" != "$thread_state" ]; then
      ev_add "0	event: thread id=$thread_id state=$thread_state"
    fi
  done <<< "$SN_THREAD_ROWS"

  # Approvals: grants and revocations against the durable set, compared only
  # against an approval list this poll actually read, and only for grants the
  # bounded set can still record.
  local user found u approvals_truncated=0
  # shellcheck disable=SC2034 # Written through the approval_set_insert indirection.
  local projected=$CUR_APPROVALS
  local -a users_now=()
  local rest
  if [ "$SN_APPROVALS_OK" -eq 1 ]; then
    while IFS= read -r user; do
      [ -n "$user" ] || continue
      prf_login_valid "$user" || continue
      users_now+=("$user")
      case ",$CUR_APPROVALS," in
        *",$user,"*) ;;
        *)
          if approval_set_insert projected "$user"; then
            ev_add "0	event: review id=approval-$user state=APPROVED author=$user"
          else
            approvals_truncated=1
          fi
          ;;
      esac
    done <<< "$SN_APPROVAL_ROWS"
    rest=$CUR_APPROVALS
    while [ -n "$rest" ]; do
      user=${rest%%,*}
      case "$rest" in
        *,*) rest=${rest#*,} ;;
        *) rest= ;;
      esac
      found=0
      for u in ${users_now[@]+"${users_now[@]}"}; do
        [ "$u" = "$user" ] && found=1
      done
      if [ "$found" -eq 0 ]; then
        ev_add "0	event: review id=approval-$user state=DISMISSED author=$user"
      fi
    done
  fi

  # Notes (plain comments, inline diff notes, and replies).
  local n_id n_author n_kind n_path n_line n_thread n_first
  while IFS=$'\t' read -r n_id n_author n_kind n_path n_line n_thread n_first; do
    [ -n "$n_id" ] || continue
    nonnegative_int "$n_id" || continue
    case "$n_kind" in note|inline) ;; *) continue ;; esac
    n_author=$(printf '%s' "$n_author" | prf_sanitize 60)
    prf_login_valid "$n_author" || n_author=invalid
    n_path=$(printf '%s' "$n_path" | prf_sanitize 120)
    nonnegative_int "$n_line" || n_line=0
    if [ "$n_id" -gt "$CUR_MAX_REVIEW_COMMENT" ]; then
      seen_add SEEN_NOTE "$n_id"
      [ "$SEEN_HIT" -eq 1 ] && continue
      if [ "$n_kind" = inline ]; then
        ev_add "$n_id	event: review-comment id=$n_id author=$n_author$( [ "$n_first" = 0 ] && printf ' reply-to=%s' "$n_thread") path=$n_path line=$n_line"
      else
        ev_add "$n_id	event: comment id=$n_id author=$n_author"
      fi
    fi
  done <<< "$SN_NOTE_ROWS"

  ev_sort_and_cap
  if [ "$approvals_truncated" -eq 1 ] && [ -n "$EV_LINES" ]; then
    EVENTS_DROPPED=1
  fi
  advance_from_surviving
  while IFS=$'\t' read -r thread_id thread_state; do
    [ -n "$thread_id" ] || continue
    [ -z "$(map_get "$NEW_THREADS" "$thread_id")" ] || continue
    NEW_THREADS=$(map_put "$NEW_THREADS" "$thread_id" "$thread_state")
  done <<< "$thread_seeds"
  NEW_THREADS=$(max_map_entries "$NEW_THREADS" "$MAP_LIMIT")
  return 0
}

compute_backfill_gitlab() {
  # GitLab threads whose last note author is not the MR author and which the
  # forge does not mark resolved. Rows arrive newest first per thread.
  local -a root_ids=() last_author=() last_path=() last_line=() thread_count=() thread_resolved=()
  local n_id n_author n_kind n_path n_line n_thread n_first
  local thread_id thread_state found i root_n=0
  while IFS=$'\t' read -r n_id n_author n_kind n_path n_line n_thread n_first; do
    [ -n "$n_id" ] || continue
    nonnegative_int "$n_id" || continue
    n_author=$(printf '%s' "$n_author" | prf_sanitize 60)
    prf_login_valid "$n_author" || n_author=invalid
    n_path=$(printf '%s' "$n_path" | prf_sanitize 120)
    nonnegative_int "$n_line" || n_line=0
    n_thread=${n_thread:-unknown}
    case "$n_thread" in *[!A-Za-z0-9_-]*) n_thread=unknown ;; esac
    found=0
    for ((i = 0; i < root_n; i++)); do
      if [ "${root_ids[$i]}" = "$n_thread" ]; then
        found=1
        last_author[i]=$n_author
        last_path[i]=$n_path
        last_line[i]=$n_line
        thread_count[i]=$(( thread_count[i] + 1 ))
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      root_ids+=("$n_thread")
      last_author+=("$n_author")
      last_path+=("$n_path")
      last_line+=("$n_line")
      thread_count+=(1)
      thread_resolved+=(unresolved)
      root_n=$((root_n + 1))
    fi
  done <<< "$(reverse_rows "$SN_NOTE_ROWS")"
  while IFS=$'\t' read -r thread_id thread_state; do
    [ -n "$thread_id" ] || continue
    for ((i = 0; i < root_n; i++)); do
      [ "${root_ids[$i]}" = "$thread_id" ] && thread_resolved[i]=$thread_state
    done
  done <<< "$SN_THREAD_ROWS"
  EV_LINES=
  for ((i = 0; i < root_n; i++)); do
    if [ "${last_author[$i]}" != "$SN_AUTHOR" ] && [ "${thread_resolved[$i]}" != resolved ]; then
      ev_add "0	event: backfill-thread id=${root_ids[$i]} last-author=${last_author[$i]} comments=${thread_count[$i]} path=${last_path[$i]} line=${last_line[$i]}"
    fi
  done
  ev_sort_and_cap
  return 0
}

# --- document emit -----------------------------------------------------------

emit_doc() {  # <status> <head> <state>
  local status=$1 head=$2 doc_state=$3 count=0 line
  printf 'schema: %s\n' "$DOC_SCHEMA"
  printf 'source: %s\n' "$SID"
  printf 'provider: %s\n' "$CUR_PROVIDER"
  printf 'url: %s\n' "$CUR_URL"
  printf 'number: %s\n' "$CUR_NUMBER"
  printf 'status: %s\n' "$status"
  if [ -n "$head" ]; then
    printf 'head: %s\n' "$head"
    printf 'state: %s\n' "$doc_state"
  fi
  printf 'dropped: %s\n' "$EVENTS_DROPPED"
  if [ -n "$EV_LINES" ]; then
    count=$(printf '%s\n' "$EV_LINES" | grep -c .)
  fi
  printf 'events: %s\n' "$count"
  if [ -n "$EV_LINES" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && printf '%s\n' "$line"
    done <<< "$EV_LINES"
  fi
  printf 'cursor:\n'
  printf 'head=%s\n' "$NEW_HEAD"
  printf 'state=%s\n' "$NEW_STATE"
  printf 'max_issue_comment=%s\n' "$NEW_MAX_ISSUE_COMMENT"
  printf 'max_review=%s\n' "$NEW_MAX_REVIEW"
  printf 'max_review_comment=%s\n' "$NEW_MAX_REVIEW_COMMENT"
  printf 'max_check=%s\n' "$NEW_MAX_CHECK"
  printf 'reviews=%s\n' "$NEW_REVIEWS"
  printf 'checks=%s\n' "$NEW_CHECKS"
  printf 'threads=%s\n' "$NEW_THREADS"
  printf 'approvals=%s\n' "$NEW_APPROVALS"
  local doc_backfill=$CUR_BACKFILL
  if [ "$status" = backfill ]; then
    doc_backfill="done"
  fi
  printf 'backfill=%s\n' "$doc_backfill"
  printf 'generation=%s\n' "$CUR_GENERATION"
}

emit_error_doc() {  # <detail>
  printf 'schema: %s\n' "$DOC_SCHEMA"
  printf 'source: %s\n' "$SID"
  printf 'provider: %s\n' "$CUR_PROVIDER"
  printf 'url: %s\n' "$CUR_URL"
  printf 'number: %s\n' "$CUR_NUMBER"
  printf 'status: error\n'
  printf 'detail: %s\n' "$1"
  printf 'events: 0\n'
}

# --- durable cursor ----------------------------------------------------------

# cursor_load <source-id>: read and fully validate the durable cursor into
# CUR_* variables. CURSOR_PRESENT=0 when the file is absent. Every stored
# identity is re-derived through fm_pr_url_parse, so a tampered cursor cannot
# redirect the poll at another host, project, or number.
cursor_load() {
  local sid=$1 file line key value sid_check
  CUR_PROVIDER=''
  CUR_URL=''
  CUR_HOST=''
  CUR_PATH=''
  CUR_NUMBER=''
  CUR_HEAD=''
  CUR_STATE=unknown
  CUR_MAX_ISSUE_COMMENT=0 CUR_MAX_REVIEW=0 CUR_MAX_REVIEW_COMMENT=0 CUR_MAX_CHECK=0
  CUR_REVIEWS=''
  CUR_CHECKS=''
  CUR_THREADS=''
  CUR_APPROVALS=''
  CUR_BASELINE=pending CUR_BACKFILL=off CUR_GENERATION=0 CUR_ERROR_STREAK=0
  CURSOR_PRESENT=1
  file=$(cursor_file "$sid")
  if [ ! -e "$file" ]; then
    [ ! -L "$file" ] || return 1
    CURSOR_PRESENT=0
    return 0
  fi
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || return 1
    case "$key" in
      schema)      [ "$value" = "$CURSOR_SCHEMA" ] || return 1 ;;
      provider)    CUR_PROVIDER=$value ;;
      url)         CUR_URL=$value ;;
      host)        CUR_HOST=$value ;;
      path)        CUR_PATH=$value ;;
      number)      CUR_NUMBER=$value ;;
      head)        CUR_HEAD=$value ;;
      state)       CUR_STATE=$value ;;
      max_issue_comment)   CUR_MAX_ISSUE_COMMENT=$value ;;
      max_review)          CUR_MAX_REVIEW=$value ;;
      max_review_comment)  CUR_MAX_REVIEW_COMMENT=$value ;;
      max_check)           CUR_MAX_CHECK=$value ;;
      reviews)     CUR_REVIEWS=$value ;;
      checks)      CUR_CHECKS=$value ;;
      threads)     CUR_THREADS=$value ;;
      approvals)   CUR_APPROVALS=$value ;;
      baseline)    CUR_BASELINE=$value ;;
      backfill)    CUR_BACKFILL=$value ;;
      generation)  CUR_GENERATION=$value ;;
      error_streak) CUR_ERROR_STREAK=$value ;;
      *) return 1 ;;
    esac
  done < "$file"
  [ -n "$CUR_PROVIDER" ] && [ -n "$CUR_URL" ] || return 1
  fm_pr_url_parse "$CUR_URL" || return 1
  [ "$CUR_PROVIDER" = "$FM_PR_PROVIDER" ] || return 1
  [ "$CUR_HOST" = "$FM_PR_HOST" ] || return 1
  [ "$CUR_PATH" = "$FM_PR_PATH" ] || return 1
  [ "$CUR_NUMBER" = "$FM_PR_NUMBER" ] || return 1
  sid_check=$(prf_source_id "$CUR_PROVIDER" "$CUR_HOST" "$CUR_PATH" "$CUR_NUMBER") || return 1
  [ "$sid_check" = "$sid" ] || return 1
  prf_state_valid "$CUR_STATE" || return 1
  case "$CUR_HEAD" in '') ;; *) prf_head_valid "$CUR_HEAD" || return 1 ;; esac
  prf_bigint_valid_cursor || return 1
  prf_map_valid "$CUR_CHECKS" || return 1
  prf_review_map_valid "$CUR_REVIEWS" || return 1
  prf_thread_map_valid "$CUR_THREADS" || return 1
  prf_approval_set_valid "$CUR_APPROVALS" || return 1
  case "$CUR_BASELINE" in pending|done) ;; *) return 1 ;; esac
  case "$CUR_BACKFILL" in on|off|done) ;; *) return 1 ;; esac
  nonnegative_int "$CUR_GENERATION" || return 1
  nonnegative_int "$CUR_ERROR_STREAK" || return 1
  return 0
}

prf_bigint_valid_cursor() {
  nonnegative_int "$CUR_MAX_ISSUE_COMMENT" || return 1
  nonnegative_int "$CUR_MAX_REVIEW" || return 1
  nonnegative_int "$CUR_MAX_REVIEW_COMMENT" || return 1
  nonnegative_int "$CUR_MAX_CHECK"
}

# cursor_store: atomically rewrite the cursor from CUR_*. The caller holds the
# lifecycle lock.
cursor_store() {
  local file tmp
  file=$(cursor_file "$SID")
  tmp=$(mktemp "$FOLLOW_DIR/.cursor.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$CURSOR_SCHEMA"
    printf 'provider=%s\n' "$CUR_PROVIDER"
    printf 'url=%s\n' "$CUR_URL"
    printf 'host=%s\n' "$CUR_HOST"
    printf 'path=%s\n' "$CUR_PATH"
    printf 'number=%s\n' "$CUR_NUMBER"
    printf 'head=%s\n' "$CUR_HEAD"
    printf 'state=%s\n' "$CUR_STATE"
    printf 'max_issue_comment=%s\n' "$CUR_MAX_ISSUE_COMMENT"
    printf 'max_review=%s\n' "$CUR_MAX_REVIEW"
    printf 'max_review_comment=%s\n' "$CUR_MAX_REVIEW_COMMENT"
    printf 'max_check=%s\n' "$CUR_MAX_CHECK"
    printf 'reviews=%s\n' "$CUR_REVIEWS"
    printf 'checks=%s\n' "$CUR_CHECKS"
    printf 'threads=%s\n' "$CUR_THREADS"
    printf 'approvals=%s\n' "$CUR_APPROVALS"
    printf 'baseline=%s\n' "$CUR_BASELINE"
    printf 'backfill=%s\n' "$CUR_BACKFILL"
    printf 'generation=%s\n' "$CUR_GENERATION"
    printf 'error_streak=%s\n' "$CUR_ERROR_STREAK"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
}

follow_dir_ready() {
  if [ -e "$FOLLOW_DIR" ] || [ -L "$FOLLOW_DIR" ]; then
    [ -d "$FOLLOW_DIR" ] && [ ! -L "$FOLLOW_DIR" ] || return 1
  else
    mkdir -p "$FOLLOW_DIR" || return 1
  fi
  chmod 0700 "$FOLLOW_DIR" 2>/dev/null || true
  [ "$(fm_pr_file_mode "$FOLLOW_DIR")" = 700 ] || return 1
  [ "$(fm_pr_file_device "$FOLLOW_DIR")" = "$(fm_pr_file_device "$STATE")" ] || return 1
}

# --- quarantine (bounded monitoring loss) ------------------------------------
# A quarantined source is paused, not retired: its registration and cursor
# stay, the run child emits no event documents, and one bounded monitoring-
# loss error document surfaces the pause. Re-arming clears the record and
# resumes tracking (monitoring-loss contract).

quarantine_file() { printf '%s/%s.quarantine\n' "$FOLLOW_DIR" "$1"; }
QUARANTINE_SCHEMA=fm-pr-follow-quarantine-v1
QUAR_COUNT=0
QUAR_SURFACED=0

quarantine_read() {  # <sid>: QUAR_COUNT / QUAR_SURFACED; 1 when absent or invalid
  local file=$1 line key value
  QUAR_COUNT=0
  QUAR_SURFACED=0
  file=$(quarantine_file "$1")
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      schema)   [ "$value" = "$QUARANTINE_SCHEMA" ] || return 1 ;;
      count)    nonnegative_int "$value" || return 1; QUAR_COUNT=$value ;;
      surfaced) case "$value" in 0|1) QUAR_SURFACED=$value ;; *) return 1 ;; esac ;;
      *) return 1 ;;
    esac
  done < "$file"
  return 0
}

quarantine_write() {  # <sid> <count> <surfaced>: caller holds the lifecycle lock
  local file tmp
  file=$(quarantine_file "$1")
  tmp=$(mktemp "$FOLLOW_DIR/.quar.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$QUARANTINE_SCHEMA"
    printf 'count=%s\n' "$2"
    printf 'surfaced=%s\n' "$3"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
}

# quarantine_active <sid>: 0 only when the recorded refusal count has reached
# FM_PR_FOLLOW_APPLY_BOUND. A record below the bound is a counted attempt, not
# a pause, so polling continues until the documented bound is reached.
quarantine_active() {
  quarantine_read "$1" || return 1
  [ "$QUAR_COUNT" -ge "$APPLY_FAIL_BOUND" ]
}

# prf_quarantine_gate: the run child's pause point. Returns 0 to proceed with
# polling, returns 1 after one pause sleep while quarantined, and exits after
# emitting the one monitoring-loss document that is still unsurfaced. The
# surfaced latch flips only when that document is applied, so a lost capture
# re-emits it (at least once, never indefinitely).
prf_quarantine_gate() {
  while :; do
    fm_lock_acquire_wait "$(lifecycle_lock_path "$SID")" || die "cannot lock the cursor"
    if quarantine_active "$SID"; then
      if [ "$QUAR_SURFACED" -eq 0 ]; then
        fm_lock_release "$(lifecycle_lock_path "$SID")"
        emit_error_doc "monitoring loss: source $SID paused after $QUAR_COUNT unapplicable captures; inspect the captured result and state/pr-follow/$SID.quarantine; rerun arm to resume after the adapter is repaired"
        sleep "$INTERVAL"
        exit 0
      fi
      fm_lock_release "$(lifecycle_lock_path "$SID")"
      sleep "$INTERVAL"
      continue
    fi
    fm_lock_release "$(lifecycle_lock_path "$SID")"
    return 0
  done
}

# --- deterministic rotation (aggregate bound) --------------------------------

rotation_roster() {
  local f id
  for f in "$REG_DIR"/prf-gh-????????????.source "$REG_DIR"/prf-gl-????????????.source; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    id=${f##*/}
    printf '%s\n' "${id%.source}"
  done | LC_ALL=C sort
}

# rotation_eval <sid> <cursor-state>: ROT_ON_DUTY=1 when this source owns the
# current slot; ROT_WAIT is the seconds until the next slot boundary. Roster
# membership is re-derived on every call, so arms and retires take effect on
# the next wake (aggregate-bound contract in the header).
rotation_eval() {
  local self=$1 cur_state=$2 now slot idx=-1 total=0 s cycle
  ROT_ON_DUTY=0
  ROT_WAIT=$INTERVAL
  now=$(date +%s) || { ROT_ON_DUTY=1; return 0; }
  slot=$(( now / ROTATION_SLOT ))
  ROT_WAIT=$(( (slot + 1) * ROTATION_SLOT - now + 1 ))
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    total=$((total + 1))
    [ "$s" = "$self" ] && idx=$((total - 1))
  done < <(rotation_roster)
  if [ "$total" -eq 0 ] || [ "$idx" -lt 0 ]; then
    # Not in the roster: the registration check at run startup owns refusal;
    # polling keeps this source observable rather than silently idle.
    ROT_ON_DUTY=1
    return 0
  fi
  [ $(( slot % total )) -eq "$idx" ] || return 0
  case "$cur_state" in
    merged|closed)
      cycle=$(( slot / total ))
      [ $(( cycle % SETTLED_EVERY )) -eq 0 ] || return 0
      ;;
  esac
  ROT_ON_DUTY=1
}

rotation_sleep_to_next_slot() {
  local now
  now=$(date +%s) || { sleep "$ROTATION_SLOT"; return 0; }
  ROT_WAIT=$(( ((now / ROTATION_SLOT) + 1) * ROTATION_SLOT - now + 1 ))
  sleep "$ROT_WAIT"
}

# --- the child ---------------------------------------------------------------

# poll_once: fill SN_* from the forge for the cursor's identity.
poll_once() {
  if [ "$CUR_PROVIDER" = github ]; then
    local owner repo
    owner=${CUR_PATH%%/*}
    repo=${CUR_PATH#*/}
    poll_github "$CUR_URL" "$owner" "$repo" "$CUR_NUMBER"
  else
    poll_gitlab "$CUR_HOST" "$CUR_PATH" "$CUR_NUMBER"
  fi
}

# error_tick: advance the persisted error streak and print an error document
# when the budget is exhausted, waiting one cadence before exiting so a
# persistent failure cannot wake once per reconcile.
error_tick() {
  local streak
  fm_lock_acquire_wait "$(lifecycle_lock_path "$SID")" || return 1
  cursor_load "$SID" || { fm_lock_release "$(lifecycle_lock_path "$SID")"; return 1; }
  streak=$(( CUR_ERROR_STREAK + 1 ))
  if [ "$streak" -ge "$ERROR_BUDGET" ]; then
    CUR_ERROR_STREAK=0
    cursor_store || { fm_lock_release "$(lifecycle_lock_path "$SID")"; return 1; }
    fm_lock_release "$(lifecycle_lock_path "$SID")"
    emit_error_doc "$SN_FETCH_ERROR"
    sleep "$INTERVAL"
    exit 0
  fi
  CUR_ERROR_STREAK=$streak
  cursor_store || { fm_lock_release "$(lifecycle_lock_path "$SID")"; return 1; }
  fm_lock_release "$(lifecycle_lock_path "$SID")"
  return 0
}

baseline_write() {
  # Store the first poll silently: current maxima, maps, head, and state. The
  # caller holds the lifecycle lock and the snapshot is fresh.
  CUR_HEAD=$SN_HEAD
  CUR_STATE=$SN_STATE
  CUR_MAX_ISSUE_COMMENT=0
  CUR_MAX_REVIEW=0
  CUR_MAX_REVIEW_COMMENT=0
  CUR_MAX_CHECK=0
  CUR_REVIEWS=
  CUR_CHECKS=
  CUR_THREADS=
  CUR_APPROVALS=
  local id rest
  while IFS=$'\t' read -r id rest; do
    [ -n "$id" ] || continue
    nonnegative_int "$id" || continue
    CUR_MAX_ISSUE_COMMENT=$(( id > CUR_MAX_ISSUE_COMMENT ? id : CUR_MAX_ISSUE_COMMENT ))
  done <<< "$SN_ROWS"
  while IFS=$'\t' read -r id rest; do
    [ -n "$id" ] || continue
    nonnegative_int "$id" || continue
    CUR_MAX_REVIEW_COMMENT=$(( id > CUR_MAX_REVIEW_COMMENT ? id : CUR_MAX_REVIEW_COMMENT ))
  done <<< "$SN_RC_ROWS"
  local review_state
  while IFS=$'\t' read -r id review_state rest; do
    [ -n "$id" ] || continue
    nonnegative_int "$id" || continue
    CUR_MAX_REVIEW=$(( id > CUR_MAX_REVIEW ? id : CUR_MAX_REVIEW ))
    prf_review_state_word_valid "$review_state" || review_state=unknown
    CUR_REVIEWS=$(map_put "$CUR_REVIEWS" "$id" "$review_state")
  done <<< "$SN_REVIEW_ROWS"
  CUR_REVIEWS=$(max_map_entries "$CUR_REVIEWS" "$MAP_LIMIT")
  local check_id check_sc check_name
  while IFS=$'\t' read -r check_id check_sc check_name; do
    [ -n "$check_id" ] || continue
    nonnegative_int "$check_id" || continue
    CUR_CHECKS=$(map_put "$CUR_CHECKS" "$check_id" "$check_sc")
  done <<< "$SN_CHECK_ROWS"
  CUR_CHECKS=$(max_map_entries "$CUR_CHECKS" "$MAP_LIMIT")
  CUR_MAX_CHECK=$(max_check_id "$SN_CHECK_ROWS" 0)
  if [ "$CUR_PROVIDER" = gitlab ]; then
    local thread_id thread_state n_id
    while IFS=$'\t' read -r thread_id thread_state; do
      [ -n "$thread_id" ] || continue
      case "$thread_id" in *[!A-Za-z0-9_-]*) continue ;; esac
      case "$thread_state" in resolved|unresolved) ;; *) continue ;; esac
      CUR_THREADS=$(map_put "$CUR_THREADS" "$thread_id" "$thread_state")
    done <<< "$SN_THREAD_ROWS"
    CUR_THREADS=$(max_map_entries "$CUR_THREADS" "$MAP_LIMIT")
    CUR_MAX_REVIEW_COMMENT=0
    while IFS=$'\t' read -r n_id _; do
      [ -n "$n_id" ] || continue
      nonnegative_int "$n_id" || continue
      CUR_MAX_REVIEW_COMMENT=$(( n_id > CUR_MAX_REVIEW_COMMENT ? n_id : CUR_MAX_REVIEW_COMMENT ))
    done <<< "$SN_NOTE_ROWS"
    local user
    if [ "$SN_APPROVALS_OK" -eq 1 ]; then
      while IFS= read -r user; do
        [ -n "$user" ] || continue
        prf_login_valid "$user" || continue
        approval_set_insert CUR_APPROVALS "$user"
      done <<< "$SN_APPROVAL_ROWS"
    fi
  fi
  CUR_BASELINE="done"
  cursor_store
}

cmd_run() {
  local sid=${1-} gen_seen gen_now events first_poll=1
  prf_source_id_valid "$sid" || die "invalid source id: $sid"
  SID=$sid
  env_bounds_valid || die "FM_PR_FOLLOW_* environment bounds are invalid"
  [ -d "$FOLLOW_DIR" ] && [ ! -L "$FOLLOW_DIR" ] || die "follow directory is unavailable"
  cursor_load "$SID" || die "cursor is unreadable or tampered: $SID"
  [ "$CURSOR_PRESENT" -eq 1 ] || die "cursor seed is missing: $SID (arm first)"
  [ -n "$CUR_PROVIDER" ] || die "cursor identity is incomplete: $SID"
  [ -f "$REG_DIR/$SID.source" ] \
    || die "source is not registered: $SID"

  while :; do
    prf_quarantine_gate || continue
    # The first poll after a child starts is immediate (baseline and
    # post-restart verification); every later poll waits for this source's
    # rotation slot, which bounds the aggregate request rate (header).
    if [ "$first_poll" -eq 0 ]; then
      rotation_eval "$SID" "$CUR_STATE"
      if [ "$ROT_ON_DUTY" -ne 1 ]; then
        sleep "$ROT_WAIT"
        continue
      fi
    fi
    first_poll=0
    gen_seen=$CUR_GENERATION
    if [ "$CUR_BASELINE" != "done" ]; then
      if poll_once; then
        fm_lock_acquire_wait "$(lifecycle_lock_path "$SID")" || die "cannot lock the cursor"
        cursor_load "$SID" || { fm_lock_release "$(lifecycle_lock_path "$SID")"; die "cursor is unreadable: $SID"; }
        if [ "$CUR_BASELINE" != "done" ]; then
          baseline_write || { fm_lock_release "$(lifecycle_lock_path "$SID")"; die "cannot store the baseline"; }
        fi
        fm_lock_release "$(lifecycle_lock_path "$SID")"
      else
        error_tick || die "cannot record the poll error"
        sleep "$INTERVAL"
        continue
      fi
    else
      if ! poll_once; then
        error_tick || die "cannot record the poll error"
        sleep "$INTERVAL"
        continue
      fi
      if [ "$CUR_ERROR_STREAK" != 0 ]; then
        fm_lock_acquire_wait "$(lifecycle_lock_path "$SID")" || die "cannot lock the cursor"
        cursor_load "$SID" || { fm_lock_release "$(lifecycle_lock_path "$SID")"; die "cursor is unreadable: $SID"; }
        if [ "$CUR_ERROR_STREAK" != 0 ]; then
          CUR_ERROR_STREAK=0
          cursor_store || { fm_lock_release "$(lifecycle_lock_path "$SID")"; die "cannot store the cursor"; }
        fi
        fm_lock_release "$(lifecycle_lock_path "$SID")"
      fi
      if [ "$CUR_PROVIDER" = github ]; then
        compute_delta_github
      else
        compute_delta_gitlab
      fi
      events=0
      if [ -n "$EV_LINES" ]; then
        events=$(printf '%s\n' "$EV_LINES" | grep -c . || true)
      fi
      if [ "$events" -eq 0 ] && [ "$EVENTS_DROPPED" -eq 0 ]; then
        : # fall through to the scheduled-backfill check below
      else
        # A concurrent apply advanced the cursor while this poll ran; recompute
        # against the fresh cursor so already-announced events are not repeated.
        gen_now=$(sed -n 's/^generation=//p' "$(cursor_file "$SID")" 2>/dev/null || printf '%s' "$gen_seen")
        if [ "$gen_now" != "$gen_seen" ]; then
          cursor_load "$SID" || die "cursor is unreadable or tampered: $SID"
          continue
        fi
        emit_doc events "$NEW_HEAD" "$NEW_STATE"
        exit 0
      fi
    fi

    # A scheduled backfill surfaces on the first poll that can see unanswered
    # threads, whether or not the baseline landed in the same poll.
    if [ "$CUR_BACKFILL" = on ]; then
      EV_LINES=''
      EVENTS_DROPPED=0
      if [ "$CUR_PROVIDER" = github ]; then
        compute_backfill_github
      else
        compute_backfill_gitlab
      fi
      if [ -n "$EV_LINES" ]; then
        NEW_HEAD=$CUR_HEAD
        NEW_STATE=$CUR_STATE
        NEW_MAX_ISSUE_COMMENT=$CUR_MAX_ISSUE_COMMENT
        NEW_MAX_REVIEW=$CUR_MAX_REVIEW
        NEW_MAX_REVIEW_COMMENT=$CUR_MAX_REVIEW_COMMENT
        NEW_MAX_CHECK=$CUR_MAX_CHECK
        NEW_REVIEWS=$CUR_REVIEWS
        NEW_CHECKS=$CUR_CHECKS
        NEW_THREADS=$CUR_THREADS
        NEW_APPROVALS=$CUR_APPROVALS
        gen_now=$(sed -n 's/^generation=//p' "$(cursor_file "$SID")" 2>/dev/null || printf '%s' "$gen_seen")
        if [ "$gen_now" != "$gen_seen" ]; then
          cursor_load "$SID" || die "cursor is unreadable or tampered: $SID"
          continue
        fi
        emit_doc backfill "$CUR_HEAD" "$CUR_STATE"
        exit 0
      fi
    fi
    rotation_sleep_to_next_slot
  done
}

# --- apply (handle / autohandle) ---------------------------------------------

# doc_header_field <file> <key>: print the single "key: value" occurrence from
# the leading block, refusing repeats or absence.
doc_header_field() {
  awk -v key="$2" '
    /^cursor:/ { exit }
    index($0, key) == 1 { count++; value = substr($0, length(key) + 2) }
    END { if (count != 1) exit 1; print value }
  ' "$1"
}

# parse_apply_doc <result-file>: structurally validate one captured document
# into DOC_* variables. Every value is validated before use; a document that
# carries invalid cursor values is refused whole, never partially merged.
parse_apply_doc() {
  local file=$1 line key value in_cursor=0 found_cursor=0
  DOC_STATUS=''
  DOC_HEAD=''
  DOC_STATE=''
  DOC_EVENTS=''
  DOC_C_GENERATION=''
  DOC_C_HEAD=''
  DOC_C_STATE=''
  DOC_C_MAXI=''
  DOC_C_MAXR=''
  DOC_C_MAXRC=''
  DOC_C_MAXCHK=0
  DOC_C_REVIEWS=''
  DOC_C_CHECKS=''
  DOC_C_THREADS=''
  DOC_C_APPROVALS=''
  DOC_C_BACKFILL=''
  [ "$(doc_header_field "$file" 'schema:')" = "$DOC_SCHEMA" ] || return 1
  [ "$(doc_header_field "$file" 'source:')" = "$SID" ] || return 1
  [ "$(doc_header_field "$file" 'provider:')" = "$CUR_PROVIDER" ] || return 1
  [ "$(doc_header_field "$file" 'url:')" = "$CUR_URL" ] || return 1
  [ "$(doc_header_field "$file" 'number:')" = "$CUR_NUMBER" ] || return 1
  DOC_STATUS=$(doc_header_field "$file" 'status:') || return 1
  case "$DOC_STATUS" in events|backfill|error) ;; *) return 1 ;; esac
  DOC_EVENTS=$(doc_header_field "$file" 'events:') || return 1
  nonnegative_int "$DOC_EVENTS" || return 1
  [ "$DOC_EVENTS" -le "$DOC_EVENT_LIMIT" ] || return 1
  if [ "$DOC_STATUS" = error ]; then
    # A diagnostic error document carries no cursor section and merges nothing;
    # applying it only commits its receipt and acknowledges the generation.
    return 0
  fi
  DOC_HEAD=$(doc_header_field "$file" 'head:') || return 1
  DOC_STATE=$(doc_header_field "$file" 'state:') || return 1
  prf_head_valid "$DOC_HEAD" || return 1
  prf_state_valid "$DOC_STATE" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_cursor" -eq 0 ]; then
      [ "$line" = 'cursor:' ] && { in_cursor=1; found_cursor=1; }
      continue
    fi
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || return 1
    case "$key" in
      head)               prf_head_valid "$value" || return 1; DOC_C_HEAD=$value ;;
      state)              prf_state_valid "$value" || return 1; DOC_C_STATE=$value ;;
      max_issue_comment)  nonnegative_int "$value" || return 1; DOC_C_MAXI=$value ;;
      max_review)         nonnegative_int "$value" || return 1; DOC_C_MAXR=$value ;;
      max_review_comment) nonnegative_int "$value" || return 1; DOC_C_MAXRC=$value ;;
      max_check)          nonnegative_int "$value" || return 1; DOC_C_MAXCHK=$value ;;
      reviews)            prf_review_map_valid "$value" || return 1; DOC_C_REVIEWS=$value ;;
      checks)             prf_map_valid "$value" || return 1; DOC_C_CHECKS=$value ;;
      threads)            prf_thread_map_valid "$value" || return 1; DOC_C_THREADS=$value ;;
      approvals)          prf_approval_set_valid "$value" || return 1; DOC_C_APPROVALS=$value ;;
      backfill)           case "$value" in on|off|done) ;; *) return 1 ;; esac; DOC_C_BACKFILL=$value ;;
      generation)         nonnegative_int "$value" || return 1; DOC_C_GENERATION=$value ;;
      *) return 1 ;;
    esac
  done < "$file"
  [ "$found_cursor" -eq 1 ] || return 1
  [ "$in_cursor" -eq 1 ] || return 1
  # The header and the cursor section must describe the same PR state.
  [ "$DOC_C_HEAD" = "$DOC_HEAD" ] || return 1
  [ "$DOC_C_STATE" = "$DOC_STATE" ] || return 1
  return 0
}

map_merge_entries() {  # <target> <doc-map>: doc entries win per entry
  local target=$1 doc=$2 rest entry id value
  rest=$doc
  while [ -n "$rest" ]; do
    entry=${rest%%,*}
    case "$rest" in
      *,*) rest=${rest#*,} ;;
      *) rest= ;;
    esac
    [ -n "$entry" ] || continue
    id=${entry%%:*}
    value=${entry#*:}
    target=$(map_put "$target" "$id" "$value")
  done
  printf '%s' "$target"
}

# apply_doc_cursor: merge the validated document cursor into CUR_*.
# Maxima merge monotonically. A document from the cursor's current generation
# or newer is authoritative for head, state, and the state maps - this is what
# lets a head move advance the cursor - while a document older than the last
# applied generation contributes its maxima only. An error document carries
# no cursor section and merges nothing; applying it only commits its receipt.
apply_doc_cursor() {
  local fresh=1
  if [ "$DOC_STATUS" = error ]; then
    CUR_GENERATION=$(( CUR_GENERATION + 1 ))
    return 0
  fi
  [ "$DOC_C_GENERATION" -ge "$CUR_GENERATION" ] || fresh=0
  if [ "$fresh" -eq 1 ]; then
    if [ -n "$DOC_C_HEAD" ]; then
      CUR_HEAD=$DOC_C_HEAD
      CUR_STATE=$DOC_C_STATE
    fi
    CUR_REVIEWS=$(map_merge_entries "$CUR_REVIEWS" "$DOC_C_REVIEWS")
    CUR_REVIEWS=$(max_map_entries "$CUR_REVIEWS" "$MAP_LIMIT")
    CUR_CHECKS=$(map_merge_entries "$CUR_CHECKS" "$DOC_C_CHECKS")
    CUR_CHECKS=$(max_map_entries "$CUR_CHECKS" "$MAP_LIMIT")
    CUR_THREADS=$(map_merge_entries "$CUR_THREADS" "$DOC_C_THREADS")
    CUR_THREADS=$(max_map_entries "$CUR_THREADS" "$MAP_LIMIT")
    CUR_APPROVALS=$DOC_C_APPROVALS
  fi
  [ "$DOC_C_MAXI" -gt "$CUR_MAX_ISSUE_COMMENT" ] && CUR_MAX_ISSUE_COMMENT=$DOC_C_MAXI
  [ "$DOC_C_MAXR" -gt "$CUR_MAX_REVIEW" ] && CUR_MAX_REVIEW=$DOC_C_MAXR
  [ "$DOC_C_MAXRC" -gt "$CUR_MAX_REVIEW_COMMENT" ] && CUR_MAX_REVIEW_COMMENT=$DOC_C_MAXRC
  [ "$DOC_C_MAXCHK" -gt "$CUR_MAX_CHECK" ] && CUR_MAX_CHECK=$DOC_C_MAXCHK
  if [ "$DOC_STATUS" = backfill ] || [ "$DOC_C_BACKFILL" = "done" ]; then
    CUR_BACKFILL="done"
  fi
  CUR_GENERATION=$(( CUR_GENERATION + 1 ))
}

cmd_apply() {  # <source-id> <sequence> <result-file>
  local sid=$1 seq=$2 result=$3 receipt stored actual already=0
  prf_source_id_valid "$sid" || die "invalid source id: $sid"
  nonnegative_int "$seq" || die "invalid sequence: $seq"
  [ -n "$result" ] && [ -f "$result" ] && [ ! -L "$result" ] \
    || die "result file is unavailable: $result"
  [ -d "$FOLLOW_DIR" ] && [ ! -L "$FOLLOW_DIR" ] || die "follow directory is unavailable"
  SID=$sid
  receipt=$(applied_file "$sid" "$seq")
  actual=$(fm_pr_sha256 "$result") \
    || die "cannot hash the captured result"
  fm_lock_acquire_wait "$(lifecycle_lock_path "$sid")" || die "cannot lock the cursor"
  if [ -e "$receipt" ] || [ -L "$receipt" ]; then
    [ -f "$receipt" ] && [ ! -L "$receipt" ] \
      || { fm_lock_release "$(lifecycle_lock_path "$sid")"; die "applied receipt is unsafe: $receipt"; }
    stored=$(sed -n 's/^result_sha256=//p' "$receipt")
    case "$stored" in ''|*[!0-9a-f]*) \
      fm_lock_release "$(lifecycle_lock_path "$sid")"; die "applied receipt is malformed: $receipt" ;; esac
    [ "${#stored}" -eq 64 ] \
      || { fm_lock_release "$(lifecycle_lock_path "$sid")"; die "applied receipt is malformed: $receipt"; }
    if [ "$stored" != "$actual" ]; then
      fm_lock_release "$(lifecycle_lock_path "$sid")"
      die "captured generation conflicts with its applied receipt: $sid $seq"
    fi
    already=1
  fi
  if cursor_load "$sid" && [ "$CURSOR_PRESENT" -eq 1 ]; then
    if [ "$already" -eq 0 ]; then
      if parse_apply_doc "$result"; then
        apply_doc_cursor
        if cursor_store; then
          local tmp
          tmp=$(mktemp "$FOLLOW_DIR/.applied.XXXXXX") || tmp=
          if [ -n "$tmp" ] \
            && printf 'result_sha256=%s\n' "$actual" > "$tmp" \
            && chmod 0600 "$tmp" \
            && mv -f -- "$tmp" "$receipt"; then
            :
          else
            [ -z "$tmp" ] || rm -f -- "$tmp"
            fm_lock_release "$(lifecycle_lock_path "$sid")"
            die "cannot commit the applied receipt: $sid $seq"
          fi
        else
          fm_lock_release "$(lifecycle_lock_path "$sid")"
          die "cannot store the cursor: $sid"
        fi
        # Applying a quarantined source's monitoring-loss document is what
        # latches it surfaced, so the bounded surface cannot repeat.
        if [ "$DOC_STATUS" = error ] \
           && quarantine_active "$sid" 2>/dev/null \
           && [ "$QUAR_SURFACED" -eq 0 ]; then
          quarantine_write "$sid" "$QUAR_COUNT" 1 || true
        fi
      else
        fm_lock_release "$(lifecycle_lock_path "$sid")"
        prf_apply_refusal "$sid" "$seq" "$result"
      fi
    fi
  else
    if [ "$already" -eq 0 ]; then
      fm_lock_release "$(lifecycle_lock_path "$sid")"
      die "cursor is missing or unreadable: $sid"
    fi
    # An already-applied generation survives cursor loss; acknowledge only.
  fi
  fm_lock_release "$(lifecycle_lock_path "$sid")"
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" >/dev/null 2>&1 \
    || die "cannot record the handled acknowledgement: $sid $seq"
  if [ "$already" -eq 1 ]; then
    printf 'already-applied: %s %s\n' "$sid" "$seq"
  else
    printf 'applied: %s %s\n' "$sid" "$seq"
  fi
}

# prf_apply_refusal <sid> <seq> <result>: classify a failed validation and
# keep the failure bounded (monitoring-loss contract in the header). Never
# returns on the tampered path; exits 0 after acknowledging at the bound.
prf_apply_refusal() {
  local sid=$1 seq=$2 result=$3 claims_schema claims_source count
  claims_schema=$(doc_header_field "$result" 'schema:' 2>/dev/null || true)
  claims_source=$(doc_header_field "$result" 'source:' 2>/dev/null || true)
  if [ "$claims_schema" != "$DOC_SCHEMA" ] || [ "$claims_source" != "$sid" ]; then
    die "captured document is tampered or foreign: refusing to apply: $sid $seq"
  fi
  # The document claims this adapter's schema and source, so this adapter
  # produced bytes its own validator refuses: an adapter defect, not tampering.
  fm_lock_acquire_wait "$(lifecycle_lock_path "$sid")" || die "cannot lock the cursor"
  if ! quarantine_read "$sid" 2>/dev/null; then
    QUAR_COUNT=0
  fi
  count=$(( QUAR_COUNT + 1 ))
  if ! quarantine_write "$sid" "$count" "${QUAR_SURFACED:-0}"; then
    fm_lock_release "$(lifecycle_lock_path "$sid")"
    die "cannot record the apply-failure count: $sid"
  fi
  fm_lock_release "$(lifecycle_lock_path "$sid")"
  if [ "$count" -lt "$APPLY_FAIL_BOUND" ]; then
    die "adapter-produced document failed its own validation contract (attempt $count of $APPLY_FAIL_BOUND): $sid $seq"
  fi
  # At the bound the re-announcement loop stops: acknowledge the capture,
  # leave the quarantine latch pausing the source, and surface the loss once.
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" >/dev/null 2>&1 \
    || die "cannot record the handled acknowledgement: $sid $seq"
  printf 'monitoring-loss: %s paused after %s unapplicable captures; inspect the captured result and state/pr-follow/%s.quarantine; rerun arm to resume after the adapter is repaired\n' \
    "$sid" "$count" "$sid"
  exit 0
}

# --- arm, backfill, retire ---------------------------------------------------

cmd_arm() {  # <task-id> <pr-url> [--backfill]
  local id=$1 url=$2 flag=${3-} sid reg_file backfill=off
  [ "$flag" = '' ] || [ "$flag" = --backfill ] || usage
  [ "$flag" = --backfill ] && backfill=on
  fm_pr_task_id_valid "$id" || die "invalid task id: $id"
  fm_pr_url_parse "$url" || die "invalid PR url: $url"
  sid=$(prf_source_id "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER") \
    || die "cannot derive the source id"
  follow_dir_ready || die "follow directory is unavailable"
  fm_procevent_source_lock_acquire "$sid" || die "cannot lock the source"
  reg_file="$REG_DIR/$sid.source"
  if [ -f "$reg_file" ] && [ ! -L "$reg_file" ]; then
    if cursor_load "$sid" && [ "$CURSOR_PRESENT" -eq 1 ]; then
      # Re-arming is the documented resume after a quarantine: clear the
      # latch so the run child polls again once the adapter is repaired.
      fm_lock_acquire_wait "$(lifecycle_lock_path "$sid")" || die "cannot lock the cursor"
      if cursor_load "$sid" \
         && { ! [ -e "$(quarantine_file "$sid")" ] || rm -f -- "$(quarantine_file "$sid")"; }; then
        fm_lock_release "$(lifecycle_lock_path "$sid")"
      else
        fm_lock_release "$(lifecycle_lock_path "$sid")"
        die "cannot clear the quarantine record: $sid"
      fi
      if [ "$backfill" = on ] && [ "$CUR_BACKFILL" = off ]; then
        SID=$sid
        fm_lock_acquire_wait "$(lifecycle_lock_path "$sid")" || die "cannot lock the cursor"
        if cursor_load "$sid"; then
          CUR_BACKFILL=on
          if ! cursor_store; then
            fm_lock_release "$(lifecycle_lock_path "$sid")"
            die "cannot schedule the backfill"
          fi
        else
          fm_lock_release "$(lifecycle_lock_path "$sid")"
          die "cannot schedule the backfill"
        fi
        fm_lock_release "$(lifecycle_lock_path "$sid")"
      fi
      fm_procevent_source_lock_release "$sid"
      printf 'already armed: %s\n' "$sid"
      return 0
    fi
    fm_procevent_source_lock_release "$sid"
    die "registration exists without a valid cursor seed: $sid"
  fi
  CUR_PROVIDER=$FM_PR_PROVIDER
  CUR_URL=$FM_PR_URL
  CUR_HOST=$FM_PR_HOST
  CUR_PATH=$FM_PR_PATH
  CUR_NUMBER=$FM_PR_NUMBER
  CUR_HEAD=
  CUR_STATE=unknown
  CUR_MAX_ISSUE_COMMENT=0
  CUR_MAX_REVIEW=0
  CUR_MAX_REVIEW_COMMENT=0
  CUR_MAX_CHECK=0
  CUR_REVIEWS=
  CUR_CHECKS=
  CUR_THREADS=
  CUR_APPROVALS=
  CUR_BASELINE=pending
  CUR_BACKFILL=$backfill
  CUR_GENERATION=1
  CUR_ERROR_STREAK=0
  SID=$sid
  if ! cursor_store; then
    fm_procevent_source_lock_release "$sid"
    die "cannot write the cursor seed: $sid"
  fi
  if ! fm_procevent_registration_publish_locked "$STATE" pr-follow "$sid" \
      "$SCRIPT_DIR/fm-procevent-pr-follow.sh" run "$sid"; then
    rm -f -- "$(cursor_file "$sid")"
    fm_procevent_source_lock_release "$sid"
    die "cannot register the source: $sid"
  fi
  fm_procevent_source_lock_release "$sid"
  printf 'armed: %s\n' "$sid"
  printf 'starts on the watcher'"'"'s next cycle; or run: bin/fm-procevent.sh reconcile\n'
}

FOLLOW_BACKFILL_SCAN_CAP=500

cmd_backfill() {
  local meta id sid out scanned=0 armed=0 already=0 skipped=0 capped=0
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  follow_dir_ready || die "follow directory is unavailable"
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    scanned=$((scanned + 1))
    if [ "$scanned" -gt "$FOLLOW_BACKFILL_SCAN_CAP" ]; then
      capped=1
      break
    fi
    id=${meta##*/}
    id=${id%.meta}
    fm_pr_task_id_valid "$id" || { skipped=$((skipped + 1)); continue; }
    grep -q '^pr=' "$meta" || continue
    if ! fm_pr_metadata_identity_parse "$meta"; then
      skipped=$((skipped + 1))
      printf 'backfill: skipped %s (its recorded PR identity is not canonical)\n' "$id" >&2
      continue
    fi
    sid=$(prf_source_id "$FM_PR_META_PROVIDER" "$FM_PR_META_HOST" "$FM_PR_META_PATH" "$FM_PR_META_NUMBER") \
      || { skipped=$((skipped + 1)); continue; }
    if [ -f "$REG_DIR/$sid.source" ] \
      && [ ! -L "$REG_DIR/$sid.source" ]; then
      already=$((already + 1))
      continue
    fi
    if out=$(cmd_arm "$id" "$FM_PR_META_URL" --backfill 2>&1); then
      armed=$((armed + 1))
      printf 'backfill: armed %s %s\n' "$sid" "$FM_PR_META_URL"
    else
      skipped=$((skipped + 1))
      printf 'backfill: refused %s: %s\n' "$id" "$out" >&2
    fi
  done
  printf 'backfill summary: scanned=%s armed=%s already=%s skipped=%s capped=%s\n' \
    "$scanned" "$armed" "$already" "$skipped" "$capped"
  [ "$capped" -eq 0 ] || printf 'backfill: the scan cap of %s metadata records was reached; rerun after the armed PRs are handled\n' "$FOLLOW_BACKFILL_SCAN_CAP" >&2
  return 0
}

cmd_retire() {  # <source-id> [--force]
  local sid=$1 force=${2-} pending receipt
  prf_source_id_valid "$sid" || die "invalid source id: $sid"
  [ -z "$force" ] || [ "$force" = --force ] || die "invalid retirement option: $force"
  # The refusal has to precede every destructive step: deregistering first
  # would stop monitoring the PR while telling the operator it refused to.
  pending=$(fm_procevent_pending "$STATE" | grep -c "/$sid\." || true)
  if [ "$pending" -gt 0 ] && [ "$force" != --force ]; then
    die "$sid has $pending unhandled captured result(s); resolve or acknowledge them, or retire again with --force"
  fi
  "$SCRIPT_DIR/fm-procevent.sh" retire "$sid" >/dev/null 2>&1 || true
  rm -f -- "$(cursor_file "$sid")"
  rm -f -- "$(quarantine_file "$sid")"
  for receipt in "$FOLLOW_DIR/$sid".*.applied; do
    [ -e "$receipt" ] || continue
    rm -f -- "$receipt" || die "cannot remove applied receipt: $receipt"
  done
  printf 'retired: %s\n' "$sid"
}

# --- dispatch ----------------------------------------------------------------

case "${1-}" in
  arm)       shift; [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage; cmd_arm "$@" ;;
  backfill)  shift; [ "$#" -eq 0 ] || usage; cmd_backfill ;;
  run)       shift; [ "$#" -eq 1 ] || usage; cmd_run "$@" ;;
  handle|autohandle) shift; [ "$#" -eq 3 ] || usage; cmd_apply "$@" ;;
  classify)  shift; [ "$#" -eq 1 ] || usage
             [ -f "$1" ] && [ ! -L "$1" ] || die "result file does not exist: ${1-}"
             status=$(doc_header_field "$1" 'status:' 2>/dev/null) || status=unknown
             case "$status" in events|backfill|error) printf '%s\n' "$status" ;; *) printf 'unknown\n' ;; esac ;;
  terminal)  shift; [ "$#" -eq 1 ] || usage
             { [ -f "$1" ] && [ ! -L "$1" ]; } || die "result file does not exist: ${1-}"
             # Lifecycle tracking never ends by itself; the runner must keep
             # this source armed across merge, close, and every later event.
             exit 1 ;;
  self-announcing) exit 1 ;;
  source-id) shift; [ "$#" -eq 1 ] || usage
             fm_pr_url_parse "${1-}" || die "invalid PR url: ${1-}"
             prf_source_id "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" \
               || die "cannot derive the source id" ;;
  retire)    shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
