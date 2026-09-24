#!/usr/bin/env bash
# fm-gh-mention.sh - the GitHub mention plane: route a tagged comment in a
# watched repository into firstmate's durable wake queue.
#
# Usage:
#   fm-gh-mention.sh poll             read every watched repo's new activity and accept qualifying mentions
#   fm-gh-mention.sh pending          print the accepted-but-unhandled records as JSON
#   fm-gh-mention.sh ack <record-id>  move one handled record into gh-mention-inbox/handled/
#   fm-gh-mention.sh status           local-only summary: config, watched repos, cursors, pending count
#   fm-gh-mention.sh cadence          print the watcher interval this plane asks for, or nothing
#   fm-gh-mention.sh arm              write and register state/gh-mention.check.sh
#   fm-gh-mention.sh disarm           remove the check shim and its trust binding
#   fm-gh-mention.sh --help           print this help
#
# INERT BY DEFAULT. Without config/gh-mentions.json this plane is a complete
# no-op: nothing is armed, poll exits 0 in silence, and no existing path pays
# for it. docs/configuration.md "GitHub mentions" owns the configuration schema.
#
# WHAT IS WATCHED IS REPOSITORIES, NOT ACCOUNTS. The watched set is this home's
# registered projects (each project's projects/<name> clone contributes its
# github.com origin as owner/name) plus every owner/name in the config's `repos`
# array, which covers a repo that should be watched without being cloned here.
# Which account owns a watched repo is irrelevant: a qualifying mention is
# handled identically in all of them.
#
# TRUST IS THE SAFETY CORE. A body qualifies only when BOTH hold on that same
# body: its author's GitHub login is on `trusted_logins` (matched exactly,
# case-insensitively, by login and never by display name), and that body carries
# one of the configured `markers` (matched case-insensitively as a literal
# substring). The marker is what separates a request meant for firstmate from
# ordinary conversation by a trusted account. Only the body's OWN author is
# checked, so a marker quoted from an untrusted account never qualifies on its
# own; a trusted collaborator who posts a body carrying a marker - including by
# quote-reply - authored that body deliberately, and it is treated as a request,
# which is correct rather than a gap. What is excluded is a body firstmate
# published itself, recognized by the PUBLISH_STAMP it begins with rather than
# by who posted it, so every authorized account stays able to tag.
# Everything else is ignored silently: no record, no wake, no forge write.
# Authorizing a collaborator is exactly adding their login to `trusted_logins`,
# and every listed login carries the same authority.
#
# THE POLL PERFORMS NO FORGE WRITES AT ALL. It reads three repo-scoped listings
# per repo per poll, each bounded by its own durable `since` cursor:
#   repos/<o>/<r>/issues/comments  issue and PR conversation comments
#   repos/<o>/<r>/pulls/comments   PR review comments
#   repos/<o>/<r>/issues           bodies of threads OPENED in the window read
# Full listings are paged until two complete passes return the same identities
# and timestamps. An interrupted or changing listing keeps its durable cursor,
# so the next poll rescans from page one and processed record identities make
# that overlap harmless. GitHub filters all three by `since` on updated_at, and
# a thread's updated_at
# moves on ANY activity - a new comment, a label, a reopen. For a comment that
# is what is wanted, because only editing THAT comment moves its own stamp. For
# a body it is not: an issue tagged months ago and bumped today would be filed
# as if it were newly asked. So a body qualifies only when it was OPENED inside
# the window this poll is actually reading.
#
# That window starts at the EARLIER of two floors, and neither alone is right.
# The backfill floor alone drops a tag opened while this home was not polling,
# because a cursor further behind than FM_GH_MENTION_BACKFILL reads a window
# that starts before it. The read cursor alone drops a tag opened inside the
# window but cut off from page one, because creation and update are different
# clocks and the cursor bounds only the second. Taking the earlier of the two
# admits both without adding a forge read - the same listing traversal applies
# either way - while `processed` and gh-mention-inbox/handled/ keep a
# body from being filed twice. What is left out: a body edited after it was
# opened, and a thread opened before BOTH floors, which needs it to have stayed
# beyond page one until the cursor passed its opening. Tagging a thread that
# already exists is done by POSTING A COMMENT on it, which the two comment
# listings above already cover and which has neither limit.
# Repos are read least-recently-ATTEMPTED first and at most
# FM_GH_MENTION_MAX_REPOS of them per sweep, so a watched set too large for one
# sweep rotates across sweeps instead of starving its tail. Every attempt is
# stamped, including one that failed, so a repo nobody can read yields its slot
# on the next sweep rather than holding one forever; that clock is separate
# from the read cursor, which a repo whose reads do not all complete keeps, so
# nothing is skipped. The cap bounds repositories attempted per sweep. A
# one-page repository costs three calls; an active repository may use more
# while paging, within the poll's time budget. A larger or busier watched set
# can increase pickup time rather than causing unbounded repository fan-out
# shared with every other gh-backed plane on this host.
#
# DURABLE STATE (all under state/, all gitignored):
#   gh-mention-inbox/<record-id>.json          one accepted mention, pending
#   gh-mention-inbox/handled/<record-id>.json  the same record after ack
#   gh-mention-cursor.json                     per-listing since cursors,
#                                              the per-repo attempt clock that
#                                              orders sweeps, and the bounded
#                                              processed-id list
#   gh-mention.reported                        one scope-keyed line per failure
#                                              standing after the last poll, so
#                                              a condition that outlives one
#                                              poll - or the sweep cap skipping
#                                              its repo - is reported once
#   gh-mention.watched-set                     what the last arm said about the
#                                              watched set, so an unchanged
#                                              picture is quiet every session
# A record id is the mention's own GitHub identity - issue-<id> for an issue or
# PR body, comment-<id> for a conversation comment, review-comment-<id> for a PR
# review comment - so a repeated poll re-derives the same id and never files the
# same mention twice. Record fields (schema fm-gh-mention.v1): record_id,
# repository, subject_type (issue|pull), subject_number, subject_url,
# comment_kind (body|comment|review-comment), comment_id, comment_url, author,
# marker, body, accepted_at.
#
# Each accepted record appends exactly one durable `check: gh-mention
# <record-id>` wake through bin/fm-wake-lib.sh, keyed so a poll that runs again
# before the drain does not queue it twice. The record is written BEFORE the
# wake and the processed-id list is extended AFTER it, so a crash can duplicate
# a wake but can never consume a pending record.
#
# AN UNWRITABLE state/ STOPS THIS PLANE, IT DOES NOT DEGRADE IT. Every durable
# step fails closed: a bound that cannot be spent refuses its mention, a mention
# that cannot be filed holds its repo at its cursor, and a lapse that cannot be
# recorded is not announced. The hold is what keeps a mention from being stepped
# over, but a permanently unwritable state/ means that repo re-reads and pages
# through the same window until the time budget prevents a complete traversal.
# The condition is reported once, so this is loud exactly once: a `could not`
# line from this plane is blocking, and the repo resumes from its cursor once
# state/ is writable again.
#
# RESPONSE LATENCY. An enabled plane asks the home's watcher for a 30s sweep
# instead of the default 300, so a one-page repo reached in that sweep can be
# picked up in tens of seconds; pagination and later repos can take longer.
# That request goes through the one
# cadence config/x-mode.env that bin/fm-bootstrap.sh already owns for Relay: a
# home running both planes gets one interval, the fastest either asked for,
# never two. A tight cadence is affordable because each capped repo starts with
# three reads and pagination stays inside the same time budget;
# FM_GH_MENTION_MAX_REPOS is what buys the host headroom.
#
# Environment:
#   FM_GH_MENTION_BUDGET    seconds one poll may spend on forge reads
#                           (default 20, valid 1..25, cut down to fit
#                           FM_CHECK_TIMEOUT); each call is additionally bounded
#   FM_GH_MENTION_BACKFILL  seconds of history read for a repo that has no
#                           cursor yet (default 3600)
#   FM_GH_MENTION_MAX_REPOS watched repos one sweep may read (default 5); the
#                           rest are read on the following sweeps, oldest first
#   FM_GH_MENTION_KEEP      processed ids retained in the cursor (default 500)
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="$CONFIG_DIR/gh-mentions.json"
CHECK_ID=gh-mention
INBOX="$STATE/gh-mention-inbox"
CURSOR="$STATE/gh-mention-cursor.json"
REPORT_RECORD="$STATE/gh-mention.reported"
WATCHED_SET_RECORD="$STATE/gh-mention.watched-set"
LOCK="$STATE/.gh-mention.lock"
CURSOR_SCHEMA=fm-gh-mention-cursor.v1
RECORD_SCHEMA=fm-gh-mention.v1
BODY_MAX=4000
# What every body firstmate publishes on a watched repo begins with - a thread
# reply, a pull-request description, a review comment, anything a later step
# adds. The responder contract writes it; the poll reads it back and never
# treats a body carrying it as a request, which is what stops firstmate
# answering its own work. It is an HTML comment, so it renders as nothing.
PUBLISH_STAMP='<!-- firstmate:gh-mention -->'
PER_PAGE=100
WATCH_INTERVAL=30

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-check-shim-lib.sh
. "$SCRIPT_DIR/fm-check-shim-lib.sh"

usage() { sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"; }
say() { printf 'gh-mention: %s\n' "$1"; }
die() { printf 'fm-gh-mention: %s\n' "$1" >&2; exit 2; }

# ------------------------------------------------------- reported-once failures
#
# The watcher wakes firstmate on ANY non-empty check output, so a failure that
# outlives one poll - an unreadable repo, a missing tool, a broken config -
# must be reported once rather than on every cycle, or it tears the watcher
# down at this plane's own 30s cadence forever. bin/fm-x-poll.sh and
# bin/fm-mail-check.sh keep the same contract against the same watcher.
# Diagnostics therefore go to diag() and are flushed once at the end of a poll;
# news (an accepted mention, a grant that just lapsed) is a one-off event that
# always prints through say().
#
# Every diagnostic is filed under the SCOPE whose condition it describes: a
# watched repo, or POLL_SCOPE for a whole-cycle condition - a repo scope is
# always owner/name, so the two can never collide. That is what makes
# report-once survive the sweep cap. A sweep reads at most
# FM_GH_MENTION_MAX_REPOS repos, so it learns nothing about the ones it skipped,
# and a record keyed by nothing but the whole blob would show a standing failure
# in the rotating tail as cleared on every sweep that skips it and as new on
# every sweep that reaches it - a wake every other cycle, forever. So a repo
# this sweep evaluated is replaced by what that sweep found, a repo it never
# reached keeps what was reported for it, and a repo that is no longer watched
# is forgotten. A whole-cycle condition is re-derived on every poll, because
# every poll that gets far enough to have one evaluates it.
POLL_SCOPE=poll
DIAGNOSTICS=
DIAG_WATCHED=
DIAG_EVALUATED=

diag() {  # <scope> <message>
  DIAGNOSTICS="${DIAGNOSTICS}$1"$'\t'"gh-mention: $2"$'\n'
  diag_evaluated "$1"
}

# This sweep learned <scope>'s condition, so what was reported for it last time
# is replaced rather than carried forward. A read the budget or a refused
# allowance cut short learns nothing about its repo and must not call this.
diag_evaluated() {  # <scope>
  DIAG_EVALUATED="${DIAG_EVALUATED}$1"$'\n'
}

report_record_read() {  # <path>
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  cat "$1" 2>/dev/null
}

report_record_write() {  # <path> <text>; empty text forgets what was reported
  local path=$1 staged
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  if [ -z "$2" ]; then
    rm -f -- "$path"
    return 0
  fi
  staged=$(umask 077; mktemp "$STATE/.gh-mention-report.XXXXXX") || return 1
  if ! printf '%s\n' "$2" > "$staged" || ! chmod 0600 "$staged" \
    || ! mv -f -- "$staged" "$path"; then
    rm -f -- "$staged"
    return 1
  fi
}

# The conditions this poll found that the last record does not already hold.
diag_unreported() {  # <previous-record> <pending>
  printf '%s\n' "$2" | awk -F'\t' '
    NR == FNR { reported[$0] = 1; next }
    $0 != "" && !($0 in reported) { print $2 }' <(printf '%s\n' "$1") -
}

# What the record holds for a watched repo this sweep never evaluated. That is
# what must survive into the new record, or the next sweep that reaches the repo
# reports its standing failure all over again.
diag_retained() {  # <previous-record>
  printf '%s\n' "$1" | awk -F'\t' -v watched="$DIAG_WATCHED" -v evaluated="$DIAG_EVALUATED" '
    BEGIN {
      split(watched, w, "\n"); for (i in w) if (w[i] != "") is_watched[w[i]] = 1
      split(evaluated, e, "\n"); for (i in e) if (e[i] != "") is_evaluated[e[i]] = 1
    }
    $0 != "" && ($1 in is_watched) && !($1 in is_evaluated)'
}

# Print what the last record does not already hold, then record everything that
# is standing now. A condition that clears is forgotten, so it is reported again
# if it returns. Reporting before recording makes a record that cannot be
# written cost a repeated report rather than a lost one.
diag_flush() {
  local pending=${DIAGNOSTICS%$'\n'} previous new standing
  DIAGNOSTICS=
  previous=$(report_record_read "$REPORT_RECORD")
  new=$(diag_unreported "$previous" "$pending")
  standing=$(printf '%s\n%s\n' "$(diag_retained "$previous")" "$pending" | sed '/^$/d' | sort)
  [ -z "$new" ] || printf '%s\n' "$new"
  [ "$standing" != "$previous" ] || return 0
  report_record_write "$REPORT_RECORD" "$standing" || true
}

TMP=
LOCK_HELD=0
cleanup() {
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$LOCK" || true
  [ -z "$TMP" ] || rm -rf -- "$TMP"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------- config

# Sets CFG_* on success. Return 0 valid, 1 absent (the inert default), 2
# invalid. An invalid config is reported by every caller and stops the plane; it
# is never repaired by a guessed default, because a typo in `trusted_logins`
# would otherwise silently widen or narrow who firstmate obeys.
CONFIG_PROBLEM=
config_load() {
  local parsed
  CONFIG_PROBLEM=
  CFG_ENABLED=false
  CFG_TRUSTED=
  CFG_MARKERS=
  CFG_REPOS=
  CFG_TRUSTED_JSON='[]'
  CFG_MARKERS_JSON='[]'
  [ -e "$CONFIG" ] || return 1
  if [ -L "$CONFIG" ] || [ ! -f "$CONFIG" ] || [ ! -r "$CONFIG" ]; then
    CONFIG_PROBLEM='config/gh-mentions.json is not a readable regular file'
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    CONFIG_PROBLEM='jq is required to read config/gh-mentions.json'
    return 2
  fi
  if [ ! -f "$SCRIPT_DIR/fm-gh-mention-config.jq" ]; then
    CONFIG_PROBLEM="the configuration validator is missing at $SCRIPT_DIR/fm-gh-mention-config.jq"
    return 2
  fi
  if ! parsed=$(jq -r -f "$SCRIPT_DIR/fm-gh-mention-config.jq" "$CONFIG" 2>/dev/null); then
    CONFIG_PROBLEM='config/gh-mentions.json is not valid JSON'
    return 2
  fi
  case "$parsed" in
    'invalid: '*) CONFIG_PROBLEM="config/gh-mentions.json ${parsed#invalid: }"; return 2 ;;
  esac
  CFG_ENABLED=$(printf '%s\n' "$parsed" | sed -n '1p')
  CFG_TRUSTED=$(printf '%s\n' "$parsed" | sed -n '/^--trusted$/,/^--markers$/p' | sed '1d;$d')
  CFG_MARKERS=$(printf '%s\n' "$parsed" | sed -n '/^--markers$/,/^--repos$/p' | sed '1d;$d')
  CFG_REPOS=$(printf '%s\n' "$parsed" | sed -n '/^--repos$/,$p' | sed '1d')
  # The forms the selection filter consumes, built once here rather than once
  # per watched repository. CFG_TRUSTED is one compact grant object per line.
  CFG_TRUSTED_JSON=$(printf '%s\n' "$CFG_TRUSTED" | jq -sc '.') || return 2
  CFG_MARKERS_JSON=$(printf '%s\n' "$CFG_MARKERS" \
    | jq -Rsc 'split("\n") | map(select(length > 0))') || return 2
  return 0
}

# Refuse to act on a config this home cannot read the way it was written.
config_require() {
  local rc=0
  config_load || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) diag "$POLL_SCOPE" "$CONFIG_PROBLEM"; return 2 ;;
  esac
}

# ---------------------------------------------------------------- watched set

# A registered project contributes the github.com repository its clone points
# at. Rows are typed so a caller chooses what to do with each kind: "repo" is a
# watched repository, "skip" is a registered project this home cannot resolve to
# one. Silently watching fewer repos than the captain registered is the failure
# this plane must not have, so a skip is never dropped on the floor - the poll
# stays quiet about it and status and arm report it.
registry_repos() {
  local name url
  [ -f "$DATA/projects.md" ] && [ ! -L "$DATA/projects.md" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ ! -e "$PROJECTS/$name/.git" ]; then
      printf 'skip\t%s\t%s\n' "$name" 'has no clone here'
      continue
    fi
    url=$(git -C "$PROJECTS/$name" remote get-url origin 2>/dev/null) || url=
    case "$url" in
      https://github.com/*|git@github.com:*|ssh://git@github.com/*) ;;
      '') printf 'skip\t%s\t%s\n' "$name" 'has no origin remote'; continue ;;
      *) printf 'skip\t%s\t%s\n' "$name" 'is not on github.com'; continue ;;
    esac
    url=${url#https://github.com/}
    url=${url#git@github.com:}
    url=${url#ssh://git@github.com/}
    url=${url%.git}
    url=${url%/}
    case "$url" in
      */*/*) printf 'skip\t%s\t%s\n' "$name" 'has an origin this plane cannot read as owner/name' ;;
      */*) printf 'repo\t%s\n' "$url" ;;
      *) printf 'skip\t%s\t%s\n' "$name" 'has an origin this plane cannot read as owner/name' ;;
    esac
  done < <(awk '$1 == "-" && $2 ~ /^[A-Za-z0-9._-]+$/ { print $2 }' "$DATA/projects.md")
}

# The watched set: every resolvable registered project plus every repo the
# config lists outright, deduped into a stable order.
watched_repos_from() {  # <registry-rows>
  { printf '%s\n' "$1" | awk -F'\t' '$1 == "repo" { print $2 }'; printf '%s\n' "$CFG_REPOS"; } \
    | sed '/^$/d' | sort -u
}

watched_repos() { watched_repos_from "$(registry_repos)"; }

# One human-readable line per registered project that contributes no repository.
registry_skip_rows() {  # <registry-rows>
  printf '%s\n' "$1" | awk -F'\t' \
    '$1 == "skip" { printf "registered project %s %s; it is not watched\n", $2, $3 }'
}

# ---------------------------------------------------------------- cursor

cursor_read() {
  if [ -f "$CURSOR" ] && [ ! -L "$CURSOR" ] \
    && jq -e --arg s "$CURSOR_SCHEMA" '.schema == $s and (.repos|type=="object")
        and (.processed|type=="array")
        and ((.grants // {}) | type == "object") and ((.lapsed // []) | type == "array")
        and ((.attempted // {}) | type == "object")
        and ((.listings // {}) | type == "object")
        ' \
      "$CURSOR" >/dev/null 2>&1; then
    cat "$CURSOR"
    return 0
  fi
  jq -n --arg s "$CURSOR_SCHEMA" \
    '{schema:$s,repos:{},listings:{},processed:[],grants:{},lapsed:[],attempted:{}}'
}

cursor_write() {  # <cursor-json-file>
  local src=$1 device staged
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CURSOR" "$device" || return 1
  staged=$(umask 077; mktemp "$STATE/.gh-mention-cursor.XXXXXX") || return 1
  if ! cat "$src" > "$staged" || ! chmod 0600 "$staged" \
    || ! fm_pr_private_file_valid "$staged" 600 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$CURSOR" "$device" \
    || ! mv -f -- "$staged" "$CURSOR"; then
    rm -f -- "$staged"
    return 1
  fi
}

# ---------------------------------------------------------------- forge reads

# One bounded read. The budget, not GitHub, is what refuses a late call, and a
# read killed at the budget's own deadline counts as exhaustion rather than as a
# repo that failed.
BUDGET_EXHAUSTED=0
RATE_LIMITED=0
forge() {  # <api-path> <output-file>
  local path=$1 out=$2 remaining bounded=0 rc=0
  remaining=$((DEADLINE - $(date +%s)))
  [ "$remaining" -gt 0 ] || { BUDGET_EXHAUSTED=1; return 1; }
  if [ "$remaining" -le 5 ]; then bounded=1; else remaining=5; fi
  fm_run_timed "$remaining" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    gh api -H 'Accept: application/vnd.github+json' "$path" > "$out" 2>/dev/null || rc=$?
  [ "$rc" -ne 124 ] || [ "$bounded" -eq 0 ] || BUDGET_EXHAUSTED=1
  if [ "$rc" -ne 0 ]; then
    # A refused allowance is a whole-host condition, not one unreadable repo,
    # so it is recognized from the error body GitHub documents for 403 and 429.
    jq -e '(.message? // "") | ascii_downcase
      | test("rate limit|abuse detection")' "$out" >/dev/null 2>&1 && RATE_LIMITED=1
    return 1
  fi
  jq -e 'type == "array"' "$out" >/dev/null 2>&1
}

# Each listing has its own durable timestamp and no durable page number.
listing_since() {  # <cursor-json> <repo> <listing> <default-since>
  jq -r --arg r "$2" --arg k "$3" --arg s "$4" \
    '.listings[$r][$k].since // $s' "$1"
}

LISTING_WAS_PAGED=0
read_listing_pass() {  # <repo> <listing> <api-path> <since> <out>
  local repo=$1 key=$2 api=$3 since=$4 out=$5 page=1 q count
  [ -n "$since" ] || return 1
  : > "$TMP/listing-items.jsonl"
  LISTING_WAS_PAGED=0
  while :; do
    q="per_page=$PER_PAGE&sort=updated&direction=asc&since=$since&page=$page"
    [ "$key" != issues ] || q="state=all&$q"
    forge "repos/$repo/$api?$q" "$TMP/listing-page.json" || return 1
    jq -e 'all(.[]; (.id | type) == "number" and (.updated_at | type) == "string")' \
      "$TMP/listing-page.json" >/dev/null \
      || return 1
    count=$(jq 'length' "$TMP/listing-page.json") || return 1
    jq -c '.[]' "$TMP/listing-page.json" >> "$TMP/listing-items.jsonl" || return 1
    [ "$count" -ge "$PER_PAGE" ] || break
    LISTING_WAS_PAGED=1
    page=$((page + 1))
  done
  jq -s '.' "$TMP/listing-items.jsonl" > "$out" || return 1
}

listing_fingerprint() {  # <listing-json>
  jq -c 'map([.id,.updated_at]) | sort | unique' "$1"
}

read_listing() {  # <repo> <listing> <api-path> <default-since> <cursor-json> <out>
  local repo=$1 key=$2 api=$3 fallback=$4 state_json=$5 out=$6 since current next
  since=$(listing_since "$state_json" "$repo" "$key" "$fallback") || return 1
  read_listing_pass "$repo" "$key" "$api" "$since" "$TMP/listing-current.json" || return 1
  if [ "$LISTING_WAS_PAGED" -eq 0 ]; then
    mv -f -- "$TMP/listing-current.json" "$out" || return 1
  else
    current=$(listing_fingerprint "$TMP/listing-current.json") || return 1
    while :; do
      read_listing_pass "$repo" "$key" "$api" "$since" "$TMP/listing-rescan.json" || return 1
      next=$(listing_fingerprint "$TMP/listing-rescan.json") || return 1
      [ "$current" != "$next" ] || break
      current=$next
    done
    mv -f -- "$TMP/listing-rescan.json" "$out" || return 1
  fi
  jq -n --arg k "$key" --arg s "$OVERLAP_SINCE" '{key:$k,since:$s}' \
    >> "$TMP/listing-next.jsonl"
}

# Read every page from each listing and normalize them into one candidate stream.
read_repo() {  # <owner/name> <since-iso> <cursor-json> <candidates-out>
  local repo=$1 since=$2 state_json=$3 out=$4 issue_since
  : > "$TMP/listing-next.jsonl"
  read_listing "$repo" comments issues/comments "$since" "$state_json" "$TMP/comments.json" || return 1
  read_listing "$repo" review pulls/comments "$since" "$state_json" "$TMP/review.json" || return 1
  read_listing "$repo" issues issues "$since" "$state_json" "$TMP/issues.json" || return 1
  issue_since=$(listing_since "$state_json" "$repo" issues "$since") || return 1
  [ -n "$issue_since" ] || return 1
  jq -c -n --slurpfile c "$TMP/comments.json" --slurpfile r "$TMP/review.json" \
    --slurpfile i "$TMP/issues.json" --arg since "$issue_since" --arg backfill "$BACKFILL_SINCE" '
    def norm($kind; $prefix):
      map(select((.user.login | type) == "string" and (.body | type) == "string"
          and (.html_url | type) == "string" and (.id | type) == "number")
        | {record_id: ($prefix + (.id | tostring)), comment_kind: $kind,
           comment_id: .id, comment_url: .html_url,
           author: .user.login, body: .body});
    (if $since < $backfill then $since else $backfill end) as $floor
    | (($c[0] | norm("comment"; "comment-"))
      + ($r[0] | norm("review-comment"; "review-comment-"))
      + ($i[0]
         | map(select((.created_at | type) == "string" and .created_at >= $floor))
         | norm("body"; "issue-")))
    | unique_by(.record_id)[]' > "$out"
}

advance_listings() {  # <cursor-json> <repo> <out>
  jq -s 'map({key:.key,value:{since:.since}}) | from_entries' "$TMP/listing-next.jsonl" \
    > "$TMP/listing-next.json" || return 1
  jq --arg r "$2" --arg t "$OVERLAP_SINCE" --slurpfile n "$TMP/listing-next.json" \
    '.repos[$r] = $t | .listings[$r] = $n[0]' "$1" > "$3"
}

# ---------------------------------------------------------------- grants

# An authorization may be permanent or bounded. A bounded grant ends at its
# `until` time, after `remaining` accepted mentions, or at whichever of the two
# comes first. The configured count is the captain's; what this home has already
# spent lives in the cursor, so the plane never rewrites the captain's file and
# an entry is never deleted when it lapses.
#
# Prints the logins that are live right now, lowercased, one per line.
grants_live() {  # <cursor-json> <now-iso>
  jq -r --slurpfile c "$1" --arg now "$2" --argjson trusted "$CFG_TRUSTED_JSON" '
    ($now | fromdateiso8601) as $t
    | ($c[0].grants // {}) as $spent
    | $trusted[]
    | (.login | ascii_downcase) as $id
    | select((.until == null) or ((.until | fromdateiso8601) > $t))
    | select((.remaining == null)
        or (.remaining - (($spent[$id].spent_on // []) | length) > 0))
    | $id' "$1" 2>/dev/null
}

# The bounded grants that have ended and have not been reported yet, so a
# captain who stops being able to tag learns why once instead of guessing.
grants_lapsed_unreported() {  # <cursor-json> <now-iso>
  jq -r --slurpfile c "$1" --arg now "$2" --argjson trusted "$CFG_TRUSTED_JSON" '
    ($now | fromdateiso8601) as $t
    | ($c[0].grants // {}) as $spent
    | ($c[0].lapsed // []) as $reported
    | $trusted[]
    | select(.until != null or .remaining != null)
    | (.login | ascii_downcase) as $id
    | select(($reported | index($id)) == null)
    | select(((.until != null) and ((.until | fromdateiso8601) <= $t))
        or ((.remaining != null) and (.remaining - (($spent[$id].spent_on // []) | length) <= 0)))
    | $id + "\t" + (if (.until != null) and ((.until | fromdateiso8601) <= $t)
        then "its authorization expired at " + .until
        else "it used all " + (.remaining | tostring) + " of its authorized requests" end)' \
    "$1" 2>/dev/null
}

# One readable line per authorization, with its bound and whether it is still
# live, so the operator can see at a glance why an account can or cannot tag.
grants_describe() {  # <cursor-json> <now-iso>
  jq -r --slurpfile c "$1" --arg now "$2" --argjson trusted "$CFG_TRUSTED_JSON" '
    ($now | fromdateiso8601) as $t
    | ($c[0].grants // {}) as $spent
    | $trusted[]
    | (.login | ascii_downcase) as $id
    | (($spent[$id].spent_on // []) | length) as $used
    | ((.until != null) and ((.until | fromdateiso8601) <= $t)) as $expired
    | ((.remaining != null) and (.remaining - $used <= 0)) as $exhausted
    | .login
      + (if .until == null and .remaining == null then " - permanent" else
          " - " + ([(if .until != null then "until " + .until else empty end),
                    (if .remaining != null then
                       ((.remaining - $used | if . < 0 then 0 else . end) | tostring)
                       + " of " + (.remaining | tostring) + " requests left"
                     else empty end)] | join(", "))
        end)
      + (if $expired or $exhausted then " (LAPSED)" else "" end)' "$1" 2>/dev/null
}

# Report each bounded authorization that has ended and has not been reported
# yet, so a captain whose tagging stopped working learns why once instead of
# guessing. The entry is never deleted and never auto-renewed.
#
# The report is recorded durably BEFORE it is made, the same order grant_charge
# spends a bound in. This is news rather than a diagnostic, so nothing
# suppresses a repeat of it; an announcement this home cannot remember would
# repeat on every poll, and a repeated line is a repeated wake. A lapse whose
# record cannot be written therefore stays silent, and `status` still shows it.
grants_report_lapsed() {  # <cursor-json> <now-iso>
  local id why
  while IFS=$'\t' read -r id why; do
    [ -n "$id" ] || continue
    jq --arg id "$id" '.lapsed = (((.lapsed // []) + [$id]) | unique)' "$1" > "$TMP/lapsed.json" \
      || continue
    cursor_write "$TMP/lapsed.json" || continue
    mv -f -- "$TMP/lapsed.json" "$1" || continue
    say "the bounded authorization for $id has lapsed because $why; it no longer qualifies until the captain renews it"
  done < <(grants_lapsed_unreported "$1" "$2")
}

# Charge one accepted mention to a bounded grant, and persist that charge
# before the mention is accepted. Returns 0 when the author may be acted on, 2
# when the grant is not live, and 1 when the charge could not be made durable.
#
# The charge records WHICH mention it paid for, so it is idempotent: a poll that
# crashed between charging and filing re-derives the same record id and charges
# nothing further, and a grant with one request left can never fund two
# mentions. What remains is the configured count minus the mentions already
# funded, so the captain's own file is never rewritten.
#
# This fails closed on purpose: a count this home cannot read or durably record
# must not authorize work, so an unwritable cursor refuses the mention rather
# than accepting it on a bound nobody can verify. The poll holds this plane's
# lock throughout, so no concurrent poll can charge the same grant at once.
grant_charge() {  # <author-login> <record-id> <cursor-json> <now-iso>
  local login=$1 record=$2 out=$3 now=$4 id state
  id=$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')
  state=$(jq -rn --arg id "$id" --arg rec "$record" --arg now "$now" --slurpfile c "$out" \
    --argjson trusted "$CFG_TRUSTED_JSON" '
    ($now | fromdateiso8601) as $t
    | ($c[0].grants // {}) as $spent
    | (($spent[$id].spent_on // [])) as $funded
    | ([$trusted[] | select((.login | ascii_downcase) == $id)] | first)
    | if . == null then "absent"
      elif ($funded | index($rec)) != null then "already-charged"
      elif (.until != null) and ((.until | fromdateiso8601) <= $t) then "lapsed"
      elif .remaining == null then "permanent"
      elif (.remaining - ($funded | length)) <= 0 then "lapsed"
      else "bounded" end') || return 1
  case "$state" in
    permanent|already-charged) return 0 ;;
    bounded) ;;
    *) return 2 ;;
  esac
  jq --arg id "$id" --arg rec "$record" \
    '.grants[$id].spent_on = (((.grants[$id].spent_on) // []) + [$rec] | unique)' "$out" \
    > "$TMP/charge.json" || return 1
  mv -f -- "$TMP/charge.json" "$out" || return 1
  cursor_write "$out"
}

# ---------------------------------------------------------------- selection

# The safety core, stated once and declaratively: a candidate survives only when
# its author is currently trusted or this exact record already spent their
# grant, its body carries a marker, and firstmate did not publish that body.
#
# Its own work is recognized by the stamp the body begins with, never by who
# posted it: a home signs in as whatever account the captain gave it, and every
# account on `trusted_logins` must stay able to tag. This covers every body
# firstmate publishes, not just a thread reply - the issues listing carries
# pull-request descriptions too, so an unstamped PR body saying the merge is
# @captain's call would be a fresh mention. The stamp counts only at the START
# of a body, so quoting an earlier one and adding a real request is still a
# request - which is the common case on a thread firstmate is already on.
qualify() {  # <candidates-in> <repo> <cursor-json> <qualified-out>
  jq -c --arg repo "$2" --argjson trusted "$LIVE_LOGINS_JSON" \
    --argjson markers "$CFG_MARKERS_JSON" --argjson cap "$BODY_MAX" \
    --arg stamp "$PUBLISH_STAMP" --slurpfile cursor "$3" '
    . as $c
    | select(($c.body | sub("^[[:space:]]+"; "") | startswith($stamp)) | not)
    | ($c.author | ascii_downcase) as $login
    | select(any($trusted[]; . == $login)
        or ((($cursor[0].grants[$login].spent_on // []) | index($c.record_id)) != null))
    | [$markers[] as $m | select(($c.body | ascii_downcase) | contains($m | ascii_downcase)) | $m] as $hit
    | select(($hit | length) > 0)
    | ($c.comment_url | split("#")[0]) as $subject
    | ($subject | split("/")) as $seg
    | $c + {marker: $hit[0], repository: $repo, subject_url: $subject,
            subject_type: (if $seg[-2] == "pull" then "pull" else "issue" end),
            subject_number: (($seg[-1] | tonumber?) // 0),
            body: ($c.body[:$cap])}' "$1" > "$4"
}

# ---------------------------------------------------------------- records

record_write() {  # <record-id> <record-json-file>
  local id=$1 src=$2 device staged
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$INBOX" ] && [ ! -L "$INBOX" ] || return 1
  device=$(fm_pr_file_device "$INBOX") || return 1
  fm_pr_regular_destination_on_device_or_absent "$INBOX/$id.json" "$device" || return 1
  staged=$(umask 077; mktemp "$INBOX/.staging.XXXXXX") || return 1
  if ! cat "$src" > "$staged" || ! chmod 0600 "$staged" \
    || ! fm_pr_private_file_valid "$staged" 600 "$device" \
    || ! mv -f -- "$staged" "$INBOX/$id.json"; then
    rm -f -- "$staged"
    return 1
  fi
}

# Write the record, then wake, then remember the id. That order is what keeps a
# crash from consuming a pending mention: a repeated poll re-derives the same id
# and finishes the steps the interrupted one did not.
accept() {  # <record-json-file> <record-id> <accepted-at>
  local src=$1 id=$2 at=$3 status=0
  jq --arg s "$RECORD_SCHEMA" --arg at "$at" \
    '{schema:$s} + . + {accepted_at:$at}' "$src" > "$TMP/record.json" || return 1
  record_write "$id" "$TMP/record.json" || return 1
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if ! fm_wake_queued_keys_locked check | grep -Fx "gh-mention:$id" >/dev/null; then
    fm_wake_append_locked check "gh-mention:$id" "check: gh-mention $id" || status=1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
  return "$status"
}

# ---------------------------------------------------------------- poll

acquire() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die 'state directory is unavailable'
  FM_WAKE_QUEUE="$STATE/.wake-queue"
  FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_acquire_wait "$LOCK" || die 'mention lock unavailable'
  LOCK_HELD=1
}

# Sets BUDGET. fm_run_timed counts a whole second before it alarms, so the
# budget has to fit inside the watcher's own per-check bound with the alarm and
# kill margins left over; a budget larger than that is cut down rather than
# refused, while a budget that is not a whole number 1..25 is refused outright.
resolve_budget() {
  local timeout max
  timeout=${FM_CHECK_TIMEOUT:-30}
  case "$timeout" in ''|*[!0-9]*|0) timeout=30 ;; esac
  BUDGET=${FM_GH_MENTION_BUDGET:-20}
  case "$BUDGET" in
    ''|*[!0-9]*|0) die 'FM_GH_MENTION_BUDGET must be a whole number from 1 to 25' ;;
  esac
  [ "$BUDGET" -ge 1 ] && [ "$BUDGET" -le 25 ] \
    || die 'FM_GH_MENTION_BUDGET must be a whole number from 1 to 25'
  max=$((timeout - 3))
  [ "$max" -ge 1 ] || max=1
  [ "$BUDGET" -le "$max" ] || BUDGET=$max
}

# One repo's turn: read, qualify, file what is new. The cursor advances only
# after every read for that repo succeeded AND every qualifying mention in the
# window was filed, so a bounded read, a failed read, or a mention that could
# not be filed costs a repeat rather than a missed mention.
poll_repo() {  # <owner/name> <cursor-json> <poll-start-iso> <new-cursor-out>
  local repo=$1 state_json=$2 start=$3 out=$4 since line id charge unfiled=0
  since=$(jq -r --arg r "$repo" --arg b "$BACKFILL_SINCE" '.repos[$r] // $b' "$state_json")
  cp "$state_json" "$out" || return 1
  jq --arg r "$repo" --arg t "$start" '.attempted[$r] = $t' "$out" > "$TMP/attempt.json" \
    && mv -f -- "$TMP/attempt.json" "$out"
  if ! read_repo "$repo" "$since" "$state_json" "$TMP/candidates.jsonl"; then
    if [ "$RATE_LIMITED" -eq 1 ]; then
      diag "$POLL_SCOPE" "GitHub refused this host's API allowance, so this cycle stopped at the refused call; every gh-backed plane on this host is affected until the allowance resets"
    elif [ "$BUDGET_EXHAUSTED" -eq 0 ]; then
      diag "$repo" "could not read $repo this cycle; it is retried next cycle"
    fi
    return 1
  fi
  diag_evaluated "$repo"
  if ! qualify "$TMP/candidates.jsonl" "$repo" "$out" "$TMP/qualified.jsonl"; then
    diag "$repo" "could not read $repo's new activity; it is retried next cycle"
    return 1
  fi
  jq -c --slurpfile c "$state_json" '
    ($c[0].processed // []) as $seen
    | .record_id as $id
    | select(any($seen[]; . == $id) | not)' "$TMP/qualified.jsonl" > "$TMP/new.jsonl" || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" > "$TMP/one.json"
    id=$(jq -r '.record_id' "$TMP/one.json") || continue
    fm_pr_task_id_valid "$id" || continue
    [ ! -e "$INBOX/handled/$id.json" ] || continue
    grant_charge "$(jq -r '.author' "$TMP/one.json")" "$id" "$out" "$start"
    charge=$?
    case "$charge" in
      0) ;;
      2) continue ;;
      *) diag "$repo" "could not durably record a bounded authorization being spent; this mention is not accepted"
         unfiled=1
         continue ;;
    esac
    if accept "$TMP/one.json" "$id" "$start"; then
      say "$(jq -r '"\(.author) tagged \(.marker) on \(.subject_url)"' "$TMP/one.json") (record $id)"
      jq --arg id "$id" --argjson keep "$KEEP" \
        '.processed = ((.processed - [$id]) + [$id] | .[-$keep:])' "$out" > "$TMP/next.json" \
        && mv -f -- "$TMP/next.json" "$out"
    else
      diag "$repo" "could not file a mention from $repo; it stays unfiled until the next cycle"
      unfiled=1
    fi
  done < "$TMP/new.jsonl"
  # A mention this window qualified but could not file is only genuinely
  # retried if the window is read again, so the cursor stays where it was.
  [ "$unfiled" -eq 0 ] || return 1
  advance_listings "$out" "$repo" "$TMP/next.json" \
    && mv -f -- "$TMP/next.json" "$out"
}

# Every failure this cycle is collected rather than printed, so the one flush
# below decides what the watcher actually sees.
action_poll() {
  poll_cycle
  diag_flush
  return 0
}

poll_cycle() {
  local start repos repo state_json next swept
  config_require || return 0
  [ "$CFG_ENABLED" = true ] || return 0
  command -v gh >/dev/null 2>&1 || { diag "$POLL_SCOPE" 'gh is required to read watched repositories'; return 0; }
  command -v jq >/dev/null 2>&1 || { diag "$POLL_SCOPE" 'jq is required to read watched repositories'; return 0; }
  resolve_budget
  acquire
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-gh-mention.XXXXXX") || die 'no scratch directory'
  start=$(now_iso)
  # An unusable clock would send every listing an empty `since` and read each
  # repo's whole history, so it stops the poll instead.
  BACKFILL_SINCE=$(iso_shift "$start" "${FM_GH_MENTION_BACKFILL:-3600}") || BACKFILL_SINCE=
  OVERLAP_SINCE=$(iso_shift "$start" 60) || OVERLAP_SINCE=
  if [ -z "$BACKFILL_SINCE" ] || [ -z "$OVERLAP_SINCE" ]; then
    diag "$POLL_SCOPE" "cannot read the clock as a UTC timestamp ($start)"
    return 0
  fi
  KEEP=${FM_GH_MENTION_KEEP:-500}
  case "$KEEP" in ''|*[!0-9]*|0) KEEP=500 ;; esac
  MAX_REPOS=${FM_GH_MENTION_MAX_REPOS:-5}
  case "$MAX_REPOS" in ''|*[!0-9]*|0) MAX_REPOS=5 ;; esac
  repos=$(watched_repos)
  [ -n "$repos" ] || return 0
  DIAG_WATCHED=$repos
  mkdir -p "$INBOX" || die 'mention inbox unavailable'
  DEADLINE=$(( $(date +%s) + BUDGET ))
  state_json="$TMP/cursor.json"
  cursor_read > "$state_json"
  grants_report_lapsed "$state_json" "$start"
  LIVE_LOGINS_JSON=$(grants_live "$state_json" "$start" \
    | jq -Rsc 'split("\n") | map(select(length > 0))') || LIVE_LOGINS_JSON=
  if [ -z "$LIVE_LOGINS_JSON" ]; then
    diag "$POLL_SCOPE" 'could not read which authorizations are still live; no mention is accepted this cycle'
    return 0
  fi
  # A renewed grant becomes reportable again the next time it lapses.
  jq --argjson live "$LIVE_LOGINS_JSON" '.lapsed = (((.lapsed // []) - $live))' "$state_json" \
    > "$TMP/relive.json" && mv -f -- "$TMP/relive.json" "$state_json"
  next="$TMP/cursor-next.json"
  swept=0
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    [ "$swept" -lt "$MAX_REPOS" ] || break
    [ "$(date +%s)" -lt "$DEADLINE" ] || break
    poll_repo "$repo" "$state_json" "$start" "$next" || true
    swept=$((swept + 1))
    mv -f -- "$next" "$state_json"
    [ "$BUDGET_EXHAUSTED" -eq 0 ] && [ "$RATE_LIMITED" -eq 0 ] || break
  done < <(order_by_attempt "$state_json" "$repos")
  cursor_write "$state_json" || diag "$POLL_SCOPE" 'could not record how far the watched repositories were read'
  return 0
}

# Least-recently-attempted first, so one sweep's slots rotate through a watched
# set larger than the cap instead of starving its tail. This is the attempt
# clock, NOT the read cursor: a read that failed still counts as an attempt, so
# a repo that can never be read yields its slot on the next sweep, while its
# read cursor stays where it was and re-reads the window it never got through.
order_by_attempt() {  # <cursor-json> <repo-list>
  local state_json=$1 repos=$2 repos_json
  repos_json=$(printf '%s\n' "$repos" | jq -Rsc 'split("\n") | map(select(length > 0))') || return 1
  jq -r --argjson repos "$repos_json" '
    (.attempted // {}) as $a
    | $repos | map({r: ., t: ($a[.] // "")}) | sort_by(.t, .r)[] | .r' "$state_json"
}

iso_shift() {  # <iso-utc> <seconds-back>
  local iso=$1 back=$2 epoch
  epoch=$(jq -nr --arg t "$iso" '$t | fromdateiso8601' 2>/dev/null) || return 1
  case "$back" in ''|*[!0-9]*) back=0 ;; esac
  jq -nr --argjson e "$((epoch - back))" '$e | todateiso8601'
}

# ---------------------------------------------------------------- other actions

action_pending() {
  local f
  [ -d "$INBOX" ] || { printf '[]\n'; return 0; }
  { for f in "$INBOX"/*.json; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      jq -c . "$f" 2>/dev/null \
        || printf 'fm-gh-mention: %s is unreadable and is not listed\n' "$f" >&2
    done; } | jq -s 'sort_by(.accepted_at)'
}

action_ack() {  # <record-id>
  local id=${1:-}
  fm_pr_task_id_valid "$id" || die 'ack needs one valid record id'
  mkdir -p "$INBOX/handled" || die 'mention inbox unavailable'
  if [ -f "$INBOX/$id.json" ] && [ ! -L "$INBOX/$id.json" ]; then
    mv -f -- "$INBOX/$id.json" "$INBOX/handled/$id.json" || die "could not acknowledge $id"
    printf 'acked %s\n' "$id"
    return 0
  fi
  printf 'already-acked %s\n' "$id"
}

action_status() {
  local rc=0 rows repos pending=0
  config_load || rc=$?
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-gh-mention.XXXXXX") || die 'no scratch directory'
  TMP_STATUS="$TMP/cursor.json"
  case "$rc" in
    1) printf 'gh mentions: off (no config/gh-mentions.json)\n'; return 0 ;;
    2) printf 'gh mentions: stopped - %s\n' "$CONFIG_PROBLEM"; return 1 ;;
  esac
  printf 'gh mentions: %s\n' "$([ "$CFG_ENABLED" = true ] && echo on || echo 'off (enabled=false)')"
  printf 'authorized logins:\n'
  cursor_read > "$TMP_STATUS"
  grants_describe "$TMP_STATUS" "$(now_iso)" | sed 's/^/  /'
  printf 'markers: %s\n' "$(printf '%s\n' "$CFG_MARKERS" | paste -sd, -)"
  printf 'publish stamp: %s\n' "$PUBLISH_STAMP"
  rows=$(registry_repos)
  registry_skip_rows "$rows" | sed 's/^/unwatched: /'
  repos=$(watched_repos_from "$rows")
  if [ -z "$repos" ]; then
    printf 'watched repositories: none - nothing to watch until a project is registered here or a repo is listed in config/gh-mentions.json\n'
  else
    printf 'watched repositories:\n'
    printf '%s\n' "$repos" | sed 's/^/  /'
  fi
  if [ -d "$INBOX" ]; then
    pending=$(find "$INBOX" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  fi
  printf 'pending mentions: %s\n' "$pending"
  printf 'armed: %s\n' "$(fm_custom_check_registered "$STATE" "$CHECK_ID" && echo yes || echo no)"
}

# The cadence this plane asks the home's watcher for, or nothing when it is off.
# bin/fm-bootstrap.sh owns config/x-mode.env and reconciles this request with
# Relay's; this plane never writes a cadence or runs a timer of its own.
action_cadence() {
  local rc=0
  config_load || rc=$?
  [ "$rc" -eq 0 ] || return 0
  [ "$CFG_ENABLED" = true ] || return 0
  [ -n "$(watched_repos)" ] || return 0
  printf '%s\n' "$WATCH_INTERVAL"
}

# A registered project on another forge or cloned elsewhere, and a watched set
# that is still empty, are ordinary steady states rather than faults. Session
# start hears them when they CHANGE rather than on every start, so an unchanging
# line can never force a skill load every session; `status` lists the whole
# picture on demand either way.
watched_set_report() {
  local rows current previous line
  rows=$(registry_repos)
  current=$(
    registry_skip_rows "$rows"
    [ -n "$(watched_repos_from "$rows")" ] \
      || printf '%s\n' 'nothing to watch yet - no project registered here resolves to a GitHub repository and config/gh-mentions.json lists no repos'
  )
  previous=$(report_record_read "$WATCHED_SET_RECORD")
  [ "$current" != "$previous" ] || return 0
  while IFS= read -r line; do
    [ -z "$line" ] || say "$line"
  done <<EOF
$current
EOF
  report_record_write "$WATCHED_SET_RECORD" "$current" || true
}

action_arm() {
  local rc=0
  config_load || rc=$?
  case "$rc" in
    1) printf 'fm-gh-mention: no config/gh-mentions.json; nothing to arm\n' >&2; return 1 ;;
    2) printf 'fm-gh-mention: %s\n' "$CONFIG_PROBLEM" >&2; return 1 ;;
  esac
  # A deliberate enabled=false is a steady state, not a problem to report every
  # session; the caller still retires the shim on this non-zero exit.
  [ "$CFG_ENABLED" = true ] || return 1
  fm_check_shim_arm "$STATE" "$CHECK_ID" "$SCRIPT_DIR/fm-gh-mention.sh" \
    'GitHub mention poll shim' "$FM_HOME" || return 1
  watched_set_report
}

# The read cursor survives a disarm on purpose: re-arming then resumes where
# the plane left off instead of re-reading a backfill window and re-filing
# mentions the home has already seen. What was already reported does not
# survive, so a condition still standing at the re-arm is reported again.
action_disarm() {
  fm_check_shim_disarm "$STATE" "$CHECK_ID" "$REPORT_RECORD" "$WATCHED_SET_RECORD"
}

trap cleanup EXIT
trap 'cleanup; exit 1' HUP INT TERM

case "${1:-check}" in
  poll|check) action_poll ;;
  pending) action_pending ;;
  ack) shift; action_ack "$@" ;;
  status) action_status ;;
  cadence) action_cadence ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die "unknown action: $1" ;;
esac
