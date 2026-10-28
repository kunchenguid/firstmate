#!/usr/bin/env bash
# Observe published contributions owned by this home's durable task records.
#
# Usage:
#   fm-contributions.sh snapshot <input.json> [--all]
#   fm-contributions.sh poll
#   fm-contributions.sh pending
#   fm-contributions.sh verdict <task> <url> <judged-head> <source-url> <captain|fleet|maintainer|nobody> <summary>
#   fm-contributions.sh ack <task> <url> <event-token>
#   fm-contributions.sh retire <task> <url> captain <reason>
#   fm-contributions.sh arm [--if-owned]
#   fm-contributions.sh owned
#   fm-contributions.sh enroll <task> <pr-url>
#
# snapshot is read-only and never contacts a forge. Its input is the canonical
# fleet snapshot's backlog/tasks pair; --all adds rows for supervisor inspection.
# URLs accepted by canonical_url in fm-contributions.jq and explicitly linked
# by a structured backlog row or a task's pr= are owned.
# Previously observed or enrolled URLs remain in data/<task>/contributions.json
# after endpoint teardown. Repository-wide PR discovery never establishes ownership.
# enroll records one task's supported PR URL as an unobserved record, so a PR
# the task opened is owned before any pr= exists; it changes nothing when the
# task already has a record for that URL and fails when that record is
# retired, so a retirement is never undone by rediscovery.
# owned prints the supported PR URLs this home owns as a JSON array of
# {url,tasks,final}, where final means a saved observation is merged or closed.
# It is read-only and never contacts a forge.
# Only canonical PR and issue URLs on the exact github.com host are supported;
# other accepted URLs remain visibly unmeasured.
# poll skips unsupported URLs without forge calls, unavailable output, wakes or
# new error stamps, and clears their legacy errors without changing observation,
# timestamps or ownership evidence.
#
# This script owns fm-contributions.v1: one atomic file per durable task with
# task and records[]. Each record contains url, kind, checked_at, error,
# observation, verdict, seen event tokens, pending events, notified tokens,
# unanswered threads, and retired provenance once retired.
# observation is one coherent forge read (a PR head is rechecked after fetching
# checks/reviews). Checks are normalized by name, id, started_at, status and
# conclusion; projection picks the newest attempt per distinct name. The last
# observation's lane names also disclose a lane absent from the next head.
# Reviews keep only id, state, submitted_at, commit_id and user.login, so a
# long review history cannot push a task's file past the 1 MiB cap above which
# a read refuses it as an unreadable record.
# A verdict records the EXACT judged head, source URL, actor and summary. The
# actor is exactly one of captain, fleet, maintainer or nobody; any other value
# is refused. A comment's arrival time never supplies its judged head. Record a
# prose verdict only after its source identifies that head; otherwise leave it unbound and
# triage its signal. Formal reviews carry GitHub's own commit_id. Neither kind
# can grant merge authority. Captain-actor prose requires an existing live hold;
# an eligible merge remains a captain call, never an automatic forge action.
#
# retire ends one task's observation of a contribution whose forge object can
# never be read again, such as a PR in a deleted repository. It records retired
# with actor captain, a non-empty reason and the UTC time. It refuses any
# other actor, a blank reason, and a task/url pair with no saved record or
# with unacknowledged pending signals. A retired pair leaves known, rotation and coverage even while a
# backlog link remains. Retiring a retired pair again is a no-op that keeps the
# first provenance. Nothing un-retires a record, poll never retires one on its
# own, and a later owner settled from a retired record is not retired. A
# retirement always records the captain's word: the script cannot verify who
# runs it, and the authority to retire is the captain's.
#
# poll consumes fm-fleet-snapshot.sh --contribution-input, a local-only read,
# and spends at most FM_CONTRIBUTIONS_BUDGET seconds on forge reads (default 20,
# 1..25). A configured value rides the generated check shim into watcher runs
# and is cut down to the watcher's own per-check bound (FM_CHECK_TIMEOUT,
# default 30, read from the poll's environment because the watcher runs it as
# a direct child) with a three-second margin. Every read, including one retry,
# is capped at five seconds. A first attempt killed at that bound or deadline is
# budget refusal; a killed retry retains the genuine failure that caused it.
# HTTP 5xx, 429, secondary-rate-limit 403, connection, DNS and TLS failures are
# retried once when that bound still has time. Other failures are reported
# immediately, including a 404, which is how a lost login reads on a private
# repository. A pull observation has three
# dependent waves: core, six independent reads (seven when FM_CONTRIBUTIONS_REPLY_AGE
# is set), then the closing head read;
# an issue has two waves. Before starting a URL, poll reserves the smaller of
# the effective budget and 15 seconds for those waves. URLs needing forge
# reads are sorted by URL and rotated by the current five-minute epoch bucket
# modulo their count, without stored scheduling state or freshness-based
# reordering. Terminal URLs settle separately before the forge budget starts
# and consume no rotation slots.
# A deliberately smaller configured budget remains bounded and may be
# unmeasured, rather than being mislabeled unavailable. Each distinct supported
# URL is attempted at most once per poll and its observation applied to every owner.
# A supported URL's final observation applies
# to every owner without another forge read. When the budget refuses a read
# mid-observation, that URL's records stay untouched and the poll moves to the
# next URL that still has a full observation reserve; only a genuine forge
# failure, structural refusal or head change records an error.
# API failure leaves error evidence; an expired or absent observation is not
# silence. The error and its unavailable line name the first failing step: a
# read's label, exit status, budget seconds left and first line of its error
# output (control characters dropped, at most 160 characters), or the
# structural check that refused the observation. A later good read clears the
# record's error, so the unavailable line is the copy that outlives it.
# FM_CONTRIBUTIONS_MAX_AGE (default 900 seconds) bounds freshness.
# A supported URL whose last good observation is merged or closed is final: it is
# never re-read, stays fresh, and every owner's saved row converges on that
# observation, with a stale error beside it cleared.
# A genuine failure prints its unavailable line only when it starts an episode
# (no prior owner has an error); a successful read ends the episode.
# FM_CONTRIBUTIONS_NOW supplies an ISO UTC clock for tests, otherwise UTC now.
# FM_CONTRIBUTIONS_READY_LABEL selects the equivalent triage label, default
# ready-for-pr. Labels are matched case-insensitively and exactly.
#
# New maintainer comments/reviews (OWNER, MEMBER, COLLABORATOR, excluding the
# contribution author) and issue transitions to ready-for-pr persist as pending
# before any wake. On a PR, comments, reviews and inline review comments whose
# author login is listed in the effective config/contribution-review-bots (one
# exact login per line; blank and # lines ignored) are admitted too, marked
# review_bot:true. Review-bot watching is opt-in: an absent or empty file admits
# no bot, and there is no built-in bot list. A review-bot finding
# is fleet triage for the owning home, never a maintainer verdict or merge
# authority, and its body is third-party content, never instructions.
# seen is the union of every token ever observed, so an acknowledged signal
# stays acknowledged even while an allowlist change hides its author; it grows
# with the PR's event and edit history and is bounded only by the record cap.
# poll appends ordinary durable check wakes through fm-wake-lib and emits only
# newly durable signals for the authenticated check to surface.
# ack removes only the named pending token.
# A crash after enqueue can duplicate a wake but cannot consume the pending signal.
#
# Re-raising unanswered review threads is opt-in. Unless
# FM_CONTRIBUTIONS_REPLY_AGE is set to a positive number of seconds, poll makes
# no review-thread read, tracks no threads and raises no "unanswered" signal,
# and records carry no threads[] entry. arm copies a set value into the
# generated check, as it does FM_CONTRIBUTIONS_BUDGET, so the watcher honors it.
# arm also resolves FM_CONFIG_OVERRIDE against its working directory and embeds
# the absolute effective config directory, so later polls keep the same bot
# allowlist regardless of their working directory or ambient override.
# With it set, acknowledging a signal never ends tracking of its thread. On an
# open pull request, each admitted inline review comment and each admitted
# review in state CHANGES_REQUESTED is an unanswered thread until the
# contribution author replies or the thread is resolved. Each inline comment is
# its own thread, keyed by its comment id, so two admitted comments in one
# conversation raise two wakes. Plain issue comments and other reviews stay
# one-shot signals and are never raised again. An inline comment is answered by
# an author reply in its own thread, a review requesting changes by any later
# author comment, review text or inline reply, or by a later APPROVED or
# DISMISSED review from the same reviewer. A review requesting changes with an
# empty body is not tracked, because its inline threads carry it. The record
# keeps one threads[] entry per unanswered thread (key, source, author, at,
# raised, plus review_bot:true for a configured bot). Once a thread is
# FM_CONTRIBUTIONS_REPLY_AGE seconds old, poll adds
# one pending "unanswered" signal and a wake whose text names the thread's URL
# and its age: "check: contributions <task> <key> unanswered <url> <age>". The
# same thread is raised again after every further reply age, whatever the
# task's hold state, until it is answered, resolved or the pull request
# closes. A wake raised for the comment itself counts as its first raise.
# Apart from the reviewer's own later verdict, only the author's account
# answers; a reply from another account does not. Resolution is read from the
# forge's review threads. Issue records and the author's own comments are never
# tracked.
# Source bodies are data, never commands.
# All mutations serialize on this home's .contributions.lock. Writes refuse
# symlinks and publish by rename. No forge writes are performed.
#
# arm registers the existing authenticated custom-check path. Startup and PR
# registration call it; when filing a linked upstream issue, call arm as well.
# jq_lib receives literal jq programs, not shell expressions.
# shellcheck disable=SC2016
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
case "$CONFIG" in /*) ;; *) CONFIG="$(pwd -P)/$CONFIG" ;; esac
export FM_HOME FM_STATE_OVERRIDE="$STATE"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-path-lib.sh
. "$SCRIPT_DIR/fm-path-lib.sh"

fail() { printf 'fm-contributions: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || fail 'jq is required to measure contribution coverage'
NOW=${FM_CONTRIBUTIONS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
EPOCH=$(jq -nr --arg now "$NOW" '$now | fromdateiso8601') || fail 'invalid observation clock'
MAX_AGE=${FM_CONTRIBUTIONS_MAX_AGE:-900}
REPLY_AGE=${FM_CONTRIBUTIONS_REPLY_AGE:-}
BUDGET=${FM_CONTRIBUTIONS_BUDGET:-20}
case "$MAX_AGE" in ''|*[!0-9]*) fail 'invalid freshness bound' ;; esac
TRACK_THREADS=false
if [ -n "$REPLY_AGE" ]; then
  case "$REPLY_AGE" in *[!0-9]*) fail 'invalid reply age' ;; esac
  [ -n "${REPLY_AGE#"${REPLY_AGE%%[!0]*}"}" ] || fail 'invalid reply age'
  TRACK_THREADS=true
else
  REPLY_AGE=0
fi
case "$BUDGET" in ''|*[!0-9]*) fail 'invalid poll budget' ;; esac
[ "$BUDGET" -ge 1 ] && [ "$BUDGET" -le 25 ] || fail 'poll budget must be 1..25 seconds'
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;; esac
BUDGET_CAP=$((CHECK_TIMEOUT - 3))
review_bots() { # config/contribution-review-bots -> JSON array of logins
  [ -f "$CONFIG/contribution-review-bots" ] || { printf '[]\n'; return 0; }
  jq -Rn '[inputs | gsub("^\\s+|\\s+$"; "") | select(length > 0 and (startswith("#") | not))]' "$CONFIG/contribution-review-bots"
}
[ "$BUDGET_CAP" -ge 1 ] || BUDGET_CAP=1
[ "$BUDGET" -le "$BUDGET_CAP" ] || BUDGET=$BUDGET_CAP
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-contributions.XXXXXX")
LOCK_HELD=0
cleanup() {
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$STATE/.contributions.lock" || true
  rm -rf -- "$TMP"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

jq_lib() { # jq options/program via final argument
  local program=${!#}
  set -- "${@:1:$#-1}"
  jq -L "$SCRIPT_DIR" "$@" "include \"fm-contributions\"; $program"
}

read_saved() {
  local file dir task
  : > "$TMP/saved.jsonl"
  ERRORS=0
  if [ -L "$DATA" ]; then
    ERRORS=1; printf '[]\n' > "$TMP/saved.json"; return 0
  fi
  for file in "$DATA"/*/contributions.json; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    fm_dirname_to dir "$file"
    fm_basename_to task "$dir"
    if [ -L "$file" ] || [ -L "$dir" ] || [ ! -f "$file" ] \
      || [ "$(wc -c < "$file")" -gt 1048576 ] \
      || ! jq_lib -ne --slurpfile record "$file" '($record | length) == 1 and ($record[0] | valid_record)' >/dev/null 2>&1; then
      ERRORS=$((ERRORS + 1))
      continue
    fi
    # A file's task identity must match its durable directory, not arbitrary JSON.
    if ! jq -e --arg task "$task" '.task == $task' "$file" >/dev/null; then
      ERRORS=$((ERRORS + 1)); continue
    fi
    jq -c . "$file" >> "$TMP/saved.jsonl"
  done
  jq -s . "$TMP/saved.jsonl" > "$TMP/saved.json"
}

get_input() {
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input > "$TMP/input.json"
}

project() {
  jq_lib -n --slurpfile input "$1" --slurpfile saved "$TMP/saved.json" \
    --argjson now "$EPOCH" --argjson max_age "$MAX_AGE" --argjson errors "$ERRORS" \
    --arg all "${2:-}" '
    projected($input[0];$saved[0];$now;$max_age) as $rows
    | summary($rows;($errors + (if $input[0].backlog.present == true then 0 else 1 end)))
    # Final rows never expire; a home holding only final rows is valid from now.
    | .valid_until = (if ($rows | length) > 0 and all($rows[]; .final) then $now else .valid_until end) + $max_age
    | .captain_omitted = ([0, (.captain | length) - 20] | max)
    | .captain |= .[:20]
    | . + (if $all == "--all" then {rows:$rows} else {} end)'
}

acquire() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail 'state directory unavailable'
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || fail 'data directory unavailable'
  # Keep the wake library's source-time state initialization off read-only paths.
  FM_WAKE_QUEUE="$STATE/.wake-queue"
  FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_acquire_wait "$STATE/.contributions.lock" || fail 'observation lock unavailable'
  LOCK_HELD=1
}

write_record() { # task record-json-file
  local task=$1 file dir device staged
  fm_pr_task_id_valid "$task" || fail 'invalid contribution task'
  dir="$DATA/$task"
  [ ! -L "$dir" ] || fail 'contribution directory is a symlink'
  mkdir -p "$dir"
  file="$dir/contributions.json"
  device=$(fm_pr_file_device "$dir")
  fm_pr_regular_destination_on_device_or_absent "$file" "$device" || fail 'unsafe contribution record destination'
  staged=$(umask 077; mktemp "$dir/.contributions.XXXXXX")
  # Preserve other contributions owned by this same task.
  if [ -f "$file" ]; then
    jq_lib -ne --arg task "$task" --slurpfile record "$file" '$record[0] | valid_record and .task == $task' >/dev/null || fail 'invalid stored contribution record'
    jq --slurpfile row "$2" '.records = ([.records[] | select(.url != $row[0].url)] + $row)' "$file" > "$staged"
  else
    jq -n --arg task "$task" --slurpfile row "$2" '{schema:"fm-contributions.v1",task:$task,records:$row}' > "$staged"
  fi
  chmod 600 "$staged"
  fm_pr_regular_destination_on_device_or_absent "$file" "$device" || fail 'contribution destination changed'
  mv -f -- "$staged" "$file"
}

forge_http_status() { # stderr-file
  sed -nE 's/^gh: HTTP ([0-9]{3})$/\1/p; s/^HTTP ([0-9]{3})[: ].*/\1/p; s/.*\(HTTP ([0-9]{3})\).*/\1/p' "$1" | head -n 1
}

forge_error_summary() { # stderr-file
  local err=$1 status
  status=$(forge_http_status "$err")
  if [ -n "$status" ]; then
    printf 'HTTP %s\n' "$status"
  elif grep -q '^GraphQL:' "$err"; then
    printf 'request failed\n'
  elif grep -Fqi 'error connecting to' "$err" \
    && grep -Fqi 'check your internet connection or https://githubstatus.com' "$err"; then
    printf 'DNS error\n'
  elif grep -Eqi '^Could not resolve host:|name resolution|no such host|dial (tcp|udp): lookup|lookup [^:]+:' "$err"; then
    printf 'DNS error\n'
  elif grep -Eqi 'tls: |x509: |TLS handshake|certificate (verify|signed)' "$err"; then
    printf 'TLS error\n'
  elif grep -Eqi 'connection (reset|refused|closed|failed|error)|could not connect|failed to connect|error connecting|broken pipe|network is unreachable|dial (tcp|udp)|unexpected EOF' "$err"; then
    printf 'connection error\n'
  else
    printf 'request failed\n'
  fi
}

forge_transient_error() { # stderr-file summary
  case "$2" in
    'HTTP 5'[0-9][0-9]|'HTTP 429'|'connection error'|'DNS error'|'TLS error') return 0 ;;
    'HTTP 403') grep -Eqi 'secondary[- ]rate[- ]limit' "$1" && return 0 ;;
  esac
  return 1
}

forge_bound_result() { # failed-rc failed-why fallback-rc
  FORGE_BOUND_RC=$3
  if [ "$1" -ne 0 ]; then
    : > "$TMP/forge-unavailable"
    printf '%s\n' "$2" >> "$TMP/why"
    FORGE_BOUND_RC=$1
  else
    BUDGET_EXHAUSTED=1
    : > "$TMP/budget-exhausted"
  fi
}

forge() {
  local remaining rc=0 failed_rc=0 failed_why='' now read_deadline
  local forge_err=${FORGE_ERR:-$TMP/forge.err} out summary why
  out=$(mktemp "$TMP/forge-output.XXXXXX")
  now=$(date +%s)
  read_deadline=$((now + 5))
  [ "$read_deadline" -le "$DEADLINE" ] || read_deadline=$DEADLINE
  while :; do
    now=$(date +%s)
    remaining=$((read_deadline - now))
    if [ "$remaining" -le 0 ]; then
      forge_bound_result "$failed_rc" "$failed_why" 1
      rm -f -- "$out"
      return "$FORGE_BOUND_RC"
    fi
    rc=0
    fm_run_timed "$remaining" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
      gh "$@" > "$out" 2> "$forge_err" || rc=$?
    if [ "$rc" -eq 0 ]; then
      cat "$out"
      rm -f -- "$out"
      return 0
    fi
    # A kill at the read bound or the deadline is budget refusal. If the retry
    # times out, retain the genuine forge failure that caused that retry.
    if [ "$rc" -eq 124 ]; then
      forge_bound_result "$failed_rc" "$failed_why" "$rc"
      rm -f -- "$out"
      return "$FORGE_BOUND_RC"
    fi
    # Keep the failing read's own words; the retry and cleanup discard its error file.
    why=$(printf '%s read exited %s with %ss of budget left: %s' "$(basename "$forge_err" .err)" "$rc" \
      "$((DEADLINE - $(date +%s)))" "$(sed -n '/[^[:space:]]/{p;q;}' "$forge_err" | tr -d '\000-\037\177' | cut -c1-160)")
    summary=$(forge_error_summary "$forge_err")
    if [ "$failed_rc" -ne 0 ] || ! forge_transient_error "$forge_err" "$summary"; then
      : > "$TMP/forge-unavailable"
      printf '%s\n' "$why" >> "$TMP/why"
      rm -f -- "$out"
      return "$rc"
    fi
    failed_rc=$rc
    failed_why=$why
  done
}

unobserved() { # why: a structural check, not a forge read, refused the observation
  printf '%s\n' "$1" >> "$TMP/why"
  return 1
}

wait_forges() { # background forge pids from one independent read wave
  local pid rc=0
  for pid in "$@"; do wait "$pid" || rc=1; done
  # A known failed parallel read is unavailable even if another read reached
  # the deadline. Only an otherwise successful wave cut short is unmeasured.
  if [ ! -e "$TMP/forge-unavailable" ] && [ -e "$TMP/budget-exhausted" ]; then
    BUDGET_EXHAUSTED=1
  fi
  return "$rc"
}

observe() { # canonical GitHub URL -> normalized JSON
  local url=$1 part number kind endpoint head after label
  case "$url" in https://github.com/*) ;; *) return 1 ;; esac
  part=${url#https://github.com/}; number=${part##*/}; part=${part%/*}; kind=${part##*/}; part=${part%/*}
  case "$kind" in pull) endpoint="repos/$part/pulls/$number" ;; issues) endpoint="repos/$part/issues/$number" ;; *) return 1 ;; esac
  rm -f -- "$TMP/budget-exhausted" "$TMP/forge-unavailable" "$TMP/why"
  BUDGET_EXHAUSTED=0
  FORGE_ERR="$TMP/core.err" forge api "$endpoint" > "$TMP/core.json" || return 1
  jq -e '(.state == "open" or .state == "closed") and (.user.login | type == "string")' "$TMP/core.json" >/dev/null \
    || unobserved 'core read returned an unexpected shape' || return 1
  if [ "$kind" = pull ]; then
    head=$(jq -er '.head.sha | select(test("^[a-fA-F0-9]{40}$"))' "$TMP/core.json") \
      || unobserved 'core read named no head commit' || return 1
    FORGE_ERR="$TMP/comments.err" forge api "repos/$part/issues/$number/comments?per_page=100" --paginate --slurp > "$TMP/comments.json" &
    local comments_pid=$!
    FORGE_ERR="$TMP/reviews.err" forge api "$endpoint/reviews?per_page=100" --paginate --slurp > "$TMP/reviews.json" &
    local reviews_pid=$!
    FORGE_ERR="$TMP/inline.err" forge api "$endpoint/comments?per_page=100" --paginate --slurp > "$TMP/inline.json" &
    local inline_pid=$!
    FORGE_ERR="$TMP/checks.err" forge api "repos/$part/commits/$head/check-runs?filter=all&per_page=100" --paginate --slurp > "$TMP/checks.json" &
    local checks_pid=$!
    FORGE_ERR="$TMP/statuses.err" forge api "repos/$part/commits/$head/statuses?per_page=100" --paginate --slurp > "$TMP/statuses.json" &
    local statuses_pid=$!
    FORGE_ERR="$TMP/repo.err" forge api "repos/$part" > "$TMP/repo.json" &
    local repo_pid=$!
    local -a pids=("$comments_pid" "$reviews_pid" "$inline_pid" "$checks_pid" "$statuses_pid" "$repo_pid")
    printf '[]\n' > "$TMP/threads.json"
    if [ "$TRACK_THREADS" = true ]; then
      FORGE_ERR="$TMP/threads.err" forge api graphql --paginate --slurp -f owner="${part%/*}" -f name="${part#*/}" -F number="$number" \
        -f query='query($owner:String!,$name:String!,$number:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$endCursor){nodes{isResolved comments(first:1){nodes{databaseId}}}pageInfo{hasNextPage endCursor}}}}}' \
        > "$TMP/threads.json" &
      pids+=("$!")
    fi
    wait_forges "${pids[@]}" || return 1
    jq -e 'type == "array" and all(.[]; type == "array")' "$TMP/comments.json" >/dev/null \
      || unobserved 'comment pages returned an unexpected shape' || return 1
    jq -e 'type == "array" and all(.[]; (.data.repository.pullRequest.reviewThreads.nodes | type) == "array")' "$TMP/threads.json" >/dev/null \
      || unobserved 'review thread pages returned an unexpected shape' || return 1
    FORGE_ERR="$TMP/head.err" forge pr view "$url" --json headRefOid,reviewDecision > "$TMP/after.json" || return 1
    after=$(jq -er '.headRefOid | select(test("^[a-fA-F0-9]{40}$"))' "$TMP/after.json") \
      || unobserved 'head read named no head commit' || return 1
    [ "$head" = "$after" ] || unobserved 'head changed during observation' || return 1
    jq -n --slurpfile core "$TMP/core.json" --slurpfile comments "$TMP/comments.json" \
      --slurpfile reviews "$TMP/reviews.json" --slurpfile inline "$TMP/inline.json" --slurpfile after "$TMP/after.json" --slurpfile checks "$TMP/checks.json" \
      --slurpfile statuses "$TMP/statuses.json" --slurpfile repo "$TMP/repo.json" --slurpfile threads "$TMP/threads.json" \
      --argjson track "$TRACK_THREADS" --argjson bots "$(review_bots)" '
      $core[0] as $c
      | ($reviews[0] | add // []) as $reviews
      | ($comments[0] | add // []) as $issue_comments
      | ($inline[0] | add // []) as $inline_comments
      | [$threads[0][] | .data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved) | .comments.nodes[0].databaseId] as $resolved
      # Replies by the contribution author, as timestamps: a review requesting
      # changes is answered by any later author comment, review body or inline reply.
      | ([$issue_comments[] | select(.user.login == $c.user.login) | .created_at]
        + [$inline_comments[] | select(.user.login == $c.user.login) | .created_at]
        + [$reviews[] | select(.user.login == $c.user.login and ((.body // "") != "")) | .submitted_at]) as $replied_at
      | {head:$c.head.sha,state:(if $c.merged_at != null then "merged" else $c.state end),
          draft:$c.draft,mergeable:(if $c.mergeable == true then "mergeable" elif $c.mergeable == false then "conflicting" else "unknown" end),
          can_merge:($repo[0].permissions.push // false),
          review_decision:($after[0].reviewDecision // ""),
          reviews:($reviews | map({id,state,submitted_at,commit_id,user:{login:.user.login}})),
          checks:([ $checks[0][] | .check_runs[] | {name,id,status,conclusion,started_at} ]
            + [ $statuses[0][] | .[] | {name:.context,id,started_at:.created_at,
              status:(if .state == "pending" then "in_progress" else "completed" end),
              conclusion:(if .state == "pending" then null else .state end)} ]),
          events:((($issue_comments | map(. + {_signal:"comment"})) + ($reviews | map(. + {_signal:"review"})) + ($inline_comments | map(. + {_signal:"review-comment"})))
            | map(select(.user.login != $c.user.login
                and ((.author_association | IN("OWNER","MEMBER","COLLABORATOR")) or (.user.login | IN($bots[]))))
              | (.created_at // .submitted_at // "") as $at | (.in_reply_to_id // .id) as $root | . as $e
              | {token:((._signal + ":") + (.id|tostring) + ":" + (.updated_at // .submitted_at // "") + ":" + (.state // "")),
                 type:._signal,source:.html_url,head:.commit_id,
                 author:.user.login,body:(.body // "" | .[:500])}
                 + (if (.user.login | IN($bots[])) then {review_bot:true} else {} end)
                 + (if $track then {at:$at,
                   # A resolved inline thread counts as answered.
                   unanswered:(if ._signal == "review-comment" then
                       ($resolved | index($root)) == null
                       and (any($inline_comments[]; .user.login == $c.user.login and (.in_reply_to_id // .id) == $root and .id > $e.id) | not)
                     elif ._signal == "review" and .state == "CHANGES_REQUESTED" and (.body // "") != "" then
                       (any($replied_at[]; . >= $at) | not)
                       and (any($reviews[]; .user.login == $e.user.login and (.state | IN("APPROVED","DISMISSED")) and .id > $e.id) | not)
                     else false end)} else {} end)))}' > "$TMP/observation.json" \
      || unobserved 'observation could not be assembled' || return 1
  else
    label=${FM_CONTRIBUTIONS_READY_LABEL:-ready-for-pr}
    FORGE_ERR="$TMP/comments.err" forge api "repos/$part/issues/$number/comments?per_page=100" --paginate --slurp > "$TMP/comments.json" &
    local comments_pid=$!
    FORGE_ERR="$TMP/issue-events.err" forge api "repos/$part/issues/$number/events?per_page=100" --paginate --slurp > "$TMP/issue-events.json" &
    local events_pid=$!
    wait_forges "$comments_pid" "$events_pid" || return 1
    jq -e 'type == "array" and all(.[]; type == "array")' "$TMP/comments.json" >/dev/null \
      || unobserved 'comment pages returned an unexpected shape' || return 1
    jq -n --slurpfile timeline "$TMP/issue-events.json" --arg label "$label" --slurpfile core "$TMP/core.json" --slurpfile comments "$TMP/comments.json" '
      $core[0] as $c | {state:$c.state,head:null,
        ready:any($c.labels[]; (.name | ascii_downcase) == ($label | ascii_downcase)),
        checks:[],reviews:[],events:($comments[0] | add // []
          | map(select(.user.login != $c.user.login and (.author_association | IN("OWNER","MEMBER","COLLABORATOR")))
            | {token:("comment:" + (.id|tostring) + ":" + (.updated_at // "")),type:"comment",source:.html_url,
               head:null,author:.user.login,body:(.body // "" | .[:500])})
          + [$timeline[0][] | .[] | select(.event == "labeled" and (.label.name | ascii_downcase) == ($label | ascii_downcase))
             | {token:("ready-for-pr:" + (.id | tostring)),type:"ready-for-pr",source:$c.html_url,head:null,body:"filed issue reached ready-for-pr"}])}' > "$TMP/observation.json" \
      || unobserved 'observation could not be assembled' || return 1
  fi
  jq_lib -ne --arg url "$url" --arg kind "$kind" --slurpfile observed "$TMP/observation.json" '
    {schema:"fm-contributions.v1",task:"observation",records:[{url:$url,
      kind:(if $kind == "pull" then "pr" else "issue" end),pending:[],seen:[],observation:$observed[0]}]}
    | valid_record' >/dev/null || unobserved 'observation failed validation'
}

publish_pending() { # task canonical-url record-file
  local task=$1 url=$2 record=$3 token key count emitted status type source age reason
  count=$(jq '.pending | length' "$record")
  [ "$count" -gt 0 ] || return 0
  while IFS=$'\t' read -r token type source age; do
    [ -n "$token" ] || continue
    key=$(printf '%s\n%s\n' "$url" "$token" | shasum -a 256 | awk '{print $1}')
    emitted=0
    status=0
    reason="check: contributions $task $key"
    case "$type:$source" in
      unanswered:https://github.com/*) reason="$reason unanswered $source $age" ;;
    esac
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
    if ! fm_wake_queued_keys_locked check | grep -Fx "contribution-$key" >/dev/null; then
      fm_wake_append_locked check "contribution-$key" "$reason" || status=1
      [ "$status" -ne 0 ] || emitted=1
    fi
    fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
    [ "$status" -eq 0 ] || return 1
    jq --arg token "$token" '.notified = ((.notified // []) + [$token] | unique)' "$record" > "$TMP/notified.json"
    mv "$TMP/notified.json" "$record"
    write_record "$task" "$record"
    [ "$emitted" -eq 0 ] || printf 'contribution-wake: %s\n' "$reason"
  done < <(jq -r '. as $r | .pending[] | select(.token as $t | ($r.notified // [] | index($t)) == null)
    | [.token, .type, (.source // "-"), (.age // "-")] | @tsv' "$record")
}

settle_final() { # canonical-url task... : copy the URL's final observation to every owner
  local url=$1 task
  shift
  jq -n --slurpfile saved "$TMP/saved.json" --arg url "$url" '
    [$saved[0][] | .records[] | select(.url == $url
      and (.observation.state | IN("merged","closed")))] as $final
    | $final | sort_by([.retired != null, .error != null]) | first' > "$TMP/final.json"
  for task in "$@"; do
    fm_pr_task_id_valid "$task" || { printf 'contributions: invalid durable task id\n'; continue; }
    jq -n --slurpfile saved "$TMP/saved.json" --arg task "$task" --arg url "$url" '
      [$saved[0][] | select(.task == $task) | .records[] | select(.url == $url)] | first' > "$TMP/old.json"
    if jq -e '. == null' "$TMP/old.json" >/dev/null; then
      jq -n --slurpfile final "$TMP/final.json" '
        $final[0] + {error:null,pending:[],notified:[]} | del(.retired)' > "$TMP/row.json"
      write_record "$task" "$TMP/row.json"
    elif jq -e '(.observation.state | IN("merged","closed") | not) or .error != null' "$TMP/old.json" >/dev/null; then
      jq -n --slurpfile final "$TMP/final.json" --slurpfile old "$TMP/old.json" '
        $old[0] + {observation:$final[0].observation,checked_at:$final[0].checked_at,error:null}
        | .pending |= map(select(.type != "unanswered"))
        | if has("notified") then .notified |= map(select(startswith("unanswered:") | not)) else . end
        | if has("threads") then .threads = [] else . end' > "$TMP/row.json"
      write_record "$task" "$TMP/row.json"
    fi
  done
}

clear_unsupported_errors() {
  local task url
  while IFS=$'\t' read -r task url; do
    fm_pr_task_id_valid "$task" || { printf 'contributions: invalid durable task id\n'; continue; }
    jq -n --slurpfile saved "$TMP/saved.json" --arg task "$task" --arg url "$url" '
      $saved[0][] | select(.task == $task) | .records[] | select(.url == $url)
      | .error=null' > "$TMP/row.json"
    write_record "$task" "$TMP/row.json"
  done < <(jq_lib -nr --slurpfile saved "$TMP/saved.json" '$saved[0][] | .task as $task | .records[]
    | select((.url | supported_url | not) and .error != null)
    | [$task,.url] | @tsv')
}

poll() {
  local task url old kind error observed why
  local -a row
  acquire
  get_input
  read_saved
  [ "$ERRORS" -eq 0 ] || printf 'contributions: %s unreadable durable record(s)\n' "$ERRORS"
  clear_unsupported_errors
  # Only supported URLs enter final settlement and the forge-read rotation.
  # One line per distinct URL: the URL, then every owning task.
  jq_lib -nr --slurpfile input "$TMP/input.json" --slurpfile saved "$TMP/saved.json" '
    known($input[0];$saved[0]) | map(select(.url | supported_url))
    | group_by(.url) | map({url:.[0].url,tasks:(map(.task) | unique)})
    | .[] | [.url] + .tasks | @tsv' > "$TMP/known.tsv"
  : > "$TMP/live.tsv"
  while IFS=$'\t' read -r -a row; do
    [ "${#row[@]}" -ge 2 ] || continue
    url=${row[0]}
    # A contribution with a final observation is not re-read for any owner.
    if jq -ne --slurpfile saved "$TMP/saved.json" --arg url "$url" --args \
      'any($ARGS.positional[] as $task | [$saved[0][] | select(.task == $task) | .records[] | select(.url == $url)] | first;
        . != null and (.observation.state | IN("merged","closed")))' "${row[@]:1}" >/dev/null; then
      settle_final "$url" "${row[@]:1}"
    else
      (IFS=$'\t'; printf '%s\n' "${row[*]}") >> "$TMP/live.tsv"
    fi
  done < "$TMP/known.tsv"
  jq -Rnr --argjson bucket "$((EPOCH / 300))" '
    [inputs] | if length == 0 then . else ($bucket % length) as $offset | .[$offset:] + .[:$offset] end
    | .[]' < "$TMP/live.tsv" > "$TMP/known.tsv"
  DEADLINE=$(( $(date +%s) + BUDGET ))
  OBSERVATION_RESERVE=$((BUDGET < 15 ? BUDGET : 15))
  while IFS=$'\t' read -r -a row; do
    [ $((DEADLINE - $(date +%s))) -ge "$OBSERVATION_RESERVE" ] || break
    url=${row[0]}
    observed=0
    observe "$url" || observed=$?
    [ "$BUDGET_EXHAUSTED" -eq 0 ] || continue
    why='no failing step recorded'
    [ ! -s "$TMP/why" ] || IFS= read -r why < "$TMP/why"
    # Wake once per failure episode: only when no owner has a prior error.
    if [ "$observed" -ne 0 ] && jq -ne --slurpfile saved "$TMP/saved.json" --arg url "$url" --args \
      'all($ARGS.positional[] as $task | [$saved[0][] | select(.task == $task) | .records[] | select(.url == $url)] | first;
        .error == null)' "${row[@]:1}" >/dev/null; then
      printf 'contributions: observation unavailable for %s - %s\n' "$url" "$why"
    fi
    case "$url" in */issues/*) kind=issue ;; *) kind="pr" ;; esac
    for task in "${row[@]:1}"; do
      fm_pr_task_id_valid "$task" || { printf 'contributions: invalid durable task id\n'; continue; }
      old="$TMP/old.json"
      jq -n --slurpfile saved "$TMP/saved.json" --arg task "$task" --arg url "$url" --arg kind "$kind" '
        ([$saved[0][] | select(.task == $task) | .records[] | select(.url == $url)] | first)
        // {url:$url,kind:$kind,checked_at:null,observation:null,verdict:null,seen:[],pending:[],notified:[]}' > "$old"
      if [ "$observed" -eq 0 ]; then
        jq_lib -n --arg now "$NOW" --argjson epoch "$EPOCH" --argjson reply_age "$REPLY_AGE" --argjson track "$TRACK_THREADS" \
          --slurpfile old "$old" --slurpfile observation "$TMP/observation.json" '
          $old[0] as $old | $observation[0] as $o
          | ($o.events + (if $o.ready == true and $old.observation.ready != true and (any($o.events[]; .type == "ready-for-pr") | not) then
              [{token:("ready-for-pr:" + $now),type:"ready-for-pr",source:$old.url,head:null,body:"filed issue reached ready-for-pr"}]
              else [] end)) as $events
          | [$events[] | select(.token as $t | ($old.seen // [] | index($t)) == null)] as $arrived
          # An acknowledgement removes the signal, not the thread: a thread
          # with no author reply or resolution is raised again after reply_age.
          | (if $track and $o.state == "open" then tracked_threads($old.threads; $o.events; $arrived | map(.token); $now) else [] end) as $tracked
          | due_threads($tracked; $epoch; $reply_age) as $due
          | ($tracked | map(.key)) as $live
          | ($due | map(.key)) as $due_keys
          | $old + {checked_at:$now,error:null,
            observation:($o + {absent_checks:((($old.observation.absent_checks // []) + [($old.observation.checks // [])[] | .name]) - [$o.checks[].name] | unique)}),
            seen:((($old.seen // []) + ($events | map(.token))) | unique),
            pending:((($old.pending // []) + $arrived
                | map(select(.type != "unanswered" or (.thread as $k | ($live | index($k)) != null and ($due_keys | index($k)) == null))))
              + [$due[] | reraise_event(.; $epoch; $now)] | unique_by(.token))}
          | (.pending | map(.token)) as $held
          | if has("notified") then .notified |= map(select((startswith("unanswered:") | not) or IN($held[]))) else . end
          | if $track then .threads = [$tracked[] | if .key | IN($due_keys[]) then .raised = $now else . end]
            else del(.threads) end' > "$TMP/row.json"
      else
        error="forge observation unavailable: $why"
        jq --arg now "$NOW" --arg error "$error" '.checked_at=$now | .error=$error' "$old" > "$TMP/row.json"
      fi
      write_record "$task" "$TMP/row.json"
      publish_pending "$task" "$url" "$TMP/row.json"
    done
  done < "$TMP/known.tsv"
}

arm() {
  local device staged
  local -a shim
  acquire
  if [ "${1:-}" = --if-owned ]; then
    get_input; read_saved
    if [ "$ERRORS" -eq 0 ] && ! jq_lib -ne --slurpfile input "$TMP/input.json" \
      --slurpfile saved "$TMP/saved.json" 'known($input[0];$saved[0]) | length > 0' >/dev/null; then
      return 0
    fi
  fi
  device=$(fm_pr_file_device "$STATE")
  fm_pr_regular_destination_on_device_or_absent "$STATE/contributions.check.sh" "$device" || fail 'unsafe check destination'
  staged=$(umask 077; mktemp "$STATE/.contributions-check.XXXXXX")
  shim=('#!/usr/bin/env bash'
    "export FM_HOME=$(printf '%q' "$FM_HOME")"
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")"
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")"
    "export FM_CONFIG_OVERRIDE=$(printf '%q' "$CONFIG")")
  if [ -n "${FM_CONTRIBUTIONS_BUDGET:-}" ]; then
    shim+=("export FM_CONTRIBUTIONS_BUDGET=$(printf '%q' "$FM_CONTRIBUTIONS_BUDGET")")
  fi
  if [ -n "${FM_CONTRIBUTIONS_REPLY_AGE:-}" ]; then
    shim+=("export FM_CONTRIBUTIONS_REPLY_AGE=$(printf '%q' "$FM_CONTRIBUTIONS_REPLY_AGE")")
  fi
  shim+=("exec $(printf '%q' "$SCRIPT_DIR/fm-contributions.sh") poll")
  printf '%s\n' "${shim[@]}" > "$staged"
  chmod 700 "$staged"
  mv -f -- "$staged" "$STATE/contributions.check.sh"
  "$SCRIPT_DIR/fm-check-register.sh" contributions
}

case "${1:-}" in
  snapshot)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || fail 'snapshot needs canonical input'
    read_saved
    project "$2" "${3:-}"
    ;;
  poll) poll ;;
  arm) arm "${2:-}" ;;
  owned)
    get_input; read_saved
    [ "$ERRORS" -eq 0 ] || fail "$ERRORS unreadable contribution record(s); ownership is unverified"
    jq_lib -n --slurpfile input "$TMP/input.json" --slurpfile saved "$TMP/saved.json" '
      [$saved[0][] | .records[] | select(.error == null and (.observation.state | IN("merged","closed"))) | .url] as $final
      | known($input[0];$saved[0]) | map(select((.url | supported_url) and (.url | contains("/pull/"))))
      | group_by(.url) | map({url:.[0].url,tasks:(map(.task) | unique),final:(.[0].url | IN($final[]))})'
    ;;
  enroll)
    [ "$#" -eq 3 ] || fail 'enroll needs a task and a PR URL'
    task=$2; url=$3
    fm_pr_task_id_valid "$task" || fail 'invalid contribution task'
    jq_lib -ne --arg url "$url" '$url | supported_url and contains("/pull/")' >/dev/null \
      || fail 'enroll needs a canonical github.com PR URL'
    acquire; read_saved
    [ "$ERRORS" -eq 0 ] || fail "$ERRORS unreadable contribution record(s); enrollment is unverified"
    if jq -e --arg task "$task" --arg url "$url" 'any(.[] | select(.task == $task) | .records[]; .url == $url and .retired != null)' "$TMP/saved.json" >/dev/null; then
      fail 'contribution is retired for this task; enrollment refused'
    fi
    if ! jq -e --arg task "$task" --arg url "$url" 'any(.[] | select(.task == $task) | .records[]; .url == $url)' "$TMP/saved.json" >/dev/null; then
      jq -n --arg url "$url" '{url:$url,kind:"pr",checked_at:null,error:null,observation:null,verdict:null,seen:[],pending:[],notified:[]}' > "$TMP/row.json"
      write_record "$task" "$TMP/row.json"
    fi
    ;;
  pending)
    read_saved
    [ "$ERRORS" -eq 0 ] || fail "$ERRORS unreadable contribution record(s); pending signals are unverified"
    jq '[.[] | .task as $task | .records[] | .url as $url | .pending[] | . + {task:$task,url:$url}]' "$TMP/saved.json"
    ;;
  verdict|ack)
    action=$1; shift
    [ "$#" -ge 3 ] || fail 'task, URL and evidence required'
    task=$1; url=$2; shift 2
    acquire; get_input; read_saved
    jq_lib -ne --slurpfile input "$TMP/input.json" --arg task "$task" --arg url "$url" --slurpfile saved "$TMP/saved.json" \
      'any(known($input[0];$saved[0])[]; .task == $task and .url == $url)' >/dev/null \
      || fail 'contribution is not owned by this durable task'
    jq -e --arg task "$task" --arg url "$url" '.[] | select(.task == $task) | .records[] | select(.url == $url)' "$TMP/saved.json" > "$TMP/row.json" \
      || fail 'observe the contribution before recording evidence'
    if [ "$action" = ack ]; then
      [ "$#" -eq 1 ] || fail 'ack needs one exact event token'
      jq --arg token "$1" '.pending |= map(select(.token != $token))' "$TMP/row.json" > "$TMP/update.json"
    else
      [ "$#" -eq 4 ] || fail 'verdict needs judged-head, source-url, actor and summary'
      fm_pr_head_valid "$1" || fail 'an exact judged commit is required'
      case "$3" in captain|fleet|maintainer|nobody) ;; *) fail "invalid required actor '$3'; expected one of: captain, fleet, maintainer, nobody" ;; esac
      case "$2" in "$url"\#*) ;; *) fail 'verdict source must be a comment or review on this contribution' ;; esac
      jq --arg head "$1" --arg source "$2" --arg actor "$3" --arg summary "$4" \
        '.verdict={head:$head,source:$source,actor:$actor,summary:$summary}' "$TMP/row.json" > "$TMP/update.json"
    fi
    write_record "$task" "$TMP/update.json"
    ;;
  retire)
    [ "$#" -eq 5 ] || fail 'retire needs task, URL, actor and reason'
    task=$2; url=$3
    fm_pr_task_id_valid "$task" || fail 'invalid contribution task'
    [ "$4" = captain ] || fail "invalid retire actor '$4'; expected: captain"
    [ -n "${5//[[:space:]]/}" ] || fail 'retire needs a non-empty reason'
    acquire; read_saved
    jq -e --arg task "$task" --arg url "$url" '.[] | select(.task == $task) | .records[] | select(.url == $url)' "$TMP/saved.json" > "$TMP/row.json" \
      || fail 'contribution is not recorded for this durable task'
    if jq -e '.retired != null' "$TMP/row.json" >/dev/null; then
      printf 'contributions: already retired %s for %s\n' "$url" "$task"
      exit 0
    fi
    jq -e '(.pending | length) == 0' "$TMP/row.json" >/dev/null \
      || fail 'acknowledge pending signals before retiring this contribution'
    jq --arg actor "$4" --arg reason "$5" --arg at "$NOW" \
      '.retired={actor:$actor,reason:$reason,at:$at}' "$TMP/row.json" > "$TMP/update.json"
    write_record "$task" "$TMP/update.json"
    ;;
  *) usage >&2; exit 2 ;;
esac
