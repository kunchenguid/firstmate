#!/usr/bin/env bash
# fm-worker-table.sh - the cross-home worker table: one row per worker in
# this home and in every registered secondmate home.
#
# Why this exists: bin/fm-capacity.sh counts this home's lanes only, so the
# captain and firstmate cannot see how many workers really run across the
# secondmates and main, nor which of them are working rather than parked
# listeners. This table answers that in one read: per home, per worker -
# task id, harness and model, working / parked / idle, age of last progress,
# and the PR when there is one.
#
# Data sources, one per side:
#   - this home: every state/<id>.meta whose kind is not secondmate
#     (secondmates hold no lane), state read live through
#     bin/fm-crew-state.sh bounded by FM_WORKER_TABLE_CREW_STATE_TIMEOUT
#     (default 10 s per worker, so the worst case is workers x that bound),
#     harness, model and pr= from the meta itself, and the PR otherwise from
#     the first pull-request URL in state/<id>.status;
#   - each registered secondmate (data/secondmates.md, parsed by
#     bin/fm-secondmate-registry-lib.sh): that home's workers come from the
#     newest fm-live-board-input.v1 copy in the secondmate summary cache
#     (state/secondmate-summary-cache/, written by bin/fm-fleet-snapshot.sh
#     --live-board-input), validated for schema, home identity and a
#     generated_epoch not in the future; a remote home (a host= record) has
#     no locally cached worker rows and is reported as remote. No secondmate
#     home is read live, so the table never spawns work in another home.
#
# Busy counting: a worker is counted working only when its current state is
# exactly working. A parked listener, a held or paused crew, a done or failed
# lane and an unprovable state are never working; the parked bucket holds
# parked, paused and blocked, the idle bucket holds done, failed and unknown.
# Secondmate rows are that home's own crew-state classifications as of the
# cache's generation, and every cached home discloses cache_age_s so a stale
# count is never read as live.
#
# Last progress is the newest meaningful status event
# (status_last_meaningful_event in bin/fm-classify-lib.sh) with its explicit
# [at=<epoch>] emission time; an unstamped or missing event reports an
# unknown age, never a guessed one. For cached secondmate rows the age is
# recomputed against this run's clock from the same event's emission time.
#
# Usage:
#   fm-worker-table.sh            the table: one key=value line, then per-home
#                                 worker blocks in plain text
#   fm-worker-table.sh --json     the fm-worker-table.v1 document on stdout
#   fm-worker-table.sh --refresh [--max-age SECONDS]
#                                 refresh the secondmate summary cache the table
#                                 reads when it is older than SECONDS (default
#                                 300); prints nothing and exits 0 when it is
#                                 fresh or no secondmate home is registered
#
# Plain text: the first line is machine-readable and fixed-order:
#   workers: total=<N> working=<W> parked=<P> idle=<I> homes=<H>
# where working counts busy workers only. Then one block per home:
#   <home-id> (<path> - live|cached <age> ago|<status>: <reason>)
#   <n> workers, <w> working
#     <id>  <harness[/model]>  <state>  <last> [(<verb>)]  [<pr-url>]
# where <last> is the age of the last meaningful status event. A home with
# no worker rows prints `  (no workers)` so an empty home is never confused
# with an unreadable one.
#
# --json prints one fm-worker-table.v1 object (needs jq): schema,
# generated_epoch, fm_home, home_id ("main", or the id in
# .fm-secondmate-home), homes[], and totals. Each home carries id, home
# path, status local|cached|unreadable|invalid|remote, reason, cache_age_s,
# observed_at_epoch (the cache generation for cached homes), workers[] and
# counts{total,working,parked,idle}. Each worker carries id, kind, harness,
# model, state, state_class (working|parked|idle), source, detail, pr,
# pr_source, and last_progress {verb, emitted_at_epoch, age_seconds, note}
# or null. The document carries labels and derived states only, never paths
# beyond the home directories themselves, commands, or tokens.
#
# --refresh is the one writing mode: it runs `bin/fm-fleet-snapshot.sh
# --live-board-input` (the only writer of the cache, which reads each local
# secondmate home read-only and refreshes its cached copy) at the lowest CPU
# priority, bounded by FM_WORKER_TABLE_REFRESH_TIMEOUT seconds (default 300),
# under state/.worker-table-refresh.lock so overlapping runs do not pile up.
# Cadence uses the last successful sweep, not one home's newest cache mtime,
# so a fresh home cannot indefinitely hide missing or stale sibling rows.
# bin/fm-watch.sh runs it detached regardless of admission configuration;
# successful sweeps refresh the cross-home count on a five-minute cadence.
#
# Read-only: apart from --refresh, the command acquires no lock, drains no wakes, arms nothing and
# changes no operational state; it reads this home's state, the registry, the
# summary cache, and bounded fm-crew-state.sh child reads for this home's
# workers. Assembly uses a private temporary directory removed on exit.
# jq is required for both modes (the cache is JSON); without it the command
# exits 2 naming it.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE and
# FM_SNAPSHOT_CACHE_DIR resolve the home exactly as the other bin/
# scripts do; FM_SNAPSHOT_CACHE_DIR defaults to
# $STATE/secondmate-summary-cache, and FM_WORKER_TABLE_NOW_EPOCH pins the
# clock for tests exactly like fm-fleet-snapshot.sh's FM_SNAPSHOT_NOW_EPOCH.
#
# Exit status: 0 on a table, 1 on a clock or assembly failure, 2 on a usage
# error or missing jq.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CACHE_DIR="${FM_SNAPSHOT_CACHE_DIR:-$STATE/secondmate-summary-cache}"
REGISTRY="$DATA/secondmates.md"

mode=text
refresh_max_age=300
USAGE="usage: fm-worker-table.sh [--json|--refresh [--max-age SECONDS]|--help]"
case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  --json) mode=json ;;
  --refresh)
    mode=refresh
    if [ "$#" -eq 3 ] && [ "$2" = --max-age ]; then
      case "$3" in ''|*[!0-9]*) echo "$USAGE" >&2; exit 2 ;; esac
      refresh_max_age=$3
      set -- --refresh
    fi
    ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "$USAGE" >&2; exit 2; }

if [ "$mode" = refresh ]; then
  refresh_sweep_age() {  # prints the last successful sweep age, or nothing
    local marker="$STATE/.worker-table-refresh-complete" m t
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 0
    m=$(stat -c %Y "$marker" 2>/dev/null) || m=$(/usr/bin/stat -f %m "$marker" 2>/dev/null) || return 0
    t=$(date +%s)
    [ "$t" -ge "$m" ] || return 0
    printf '%s\n' $((t - m))
  }
  # Only a registered local secondmate home has rows to refresh.
  [ -f "$REGISTRY" ] && [ ! -L "$REGISTRY" ] && grep -q '^- ' "$REGISTRY" 2>/dev/null || exit 0
  cache_age=$(refresh_sweep_age)
  if [ -n "$cache_age" ] && [ "$cache_age" -lt "$refresh_max_age" ]; then
    exit 0
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  refresh_lock="$STATE/.worker-table-refresh.lock"
  fm_lock_try_acquire "$refresh_lock" || exit 0
  refresh_timeout=${FM_WORKER_TABLE_REFRESH_TIMEOUT:-300}
  case "$refresh_timeout" in ''|0|*[!0-9]*) refresh_timeout=300 ;; esac
  refresh_rc=0
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_SNAPSHOT_CACHE_DIR="$CACHE_DIR" \
    fm_run_timed "$refresh_timeout" nice -n 19 "${FM_WORKER_TABLE_SNAPSHOT:-$SCRIPT_DIR/fm-fleet-snapshot.sh}" --live-board-input \
    >/dev/null 2>&1 </dev/null || refresh_rc=$?
  if [ "$refresh_rc" -eq 0 ]; then
    [ ! -L "$STATE/.worker-table-refresh-complete" ] && touch "$STATE/.worker-table-refresh-complete" || refresh_rc=1
  fi
  fm_lock_release "$refresh_lock"
  if [ "$refresh_rc" -ne 0 ]; then
    echo "fm-worker-table: the cache refresh failed (exit $refresh_rc)" >&2
    exit 1
  fi
  exit 0
fi

command -v jq >/dev/null 2>&1 || {
  echo "fm-worker-table: needs jq" >&2
  exit 2
}

now=${FM_WORKER_TABLE_NOW_EPOCH:-$(date +%s)}
case "$now" in ''|*[!0-9]*) echo "fm-worker-table: no clock" >&2; exit 1 ;; esac

FM_WORKER_TABLE_CREW_STATE_TIMEOUT=${FM_WORKER_TABLE_CREW_STATE_TIMEOUT:-10}
case "$FM_WORKER_TABLE_CREW_STATE_TIMEOUT" in
  ''|0|*[!0-9]*)
    echo "fm-worker-table: FM_WORKER_TABLE_CREW_STATE_TIMEOUT must be a positive integer" >&2
    exit 2
    ;;
esac

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# The classifier also loads fm_run_timed; reuse that bounded-execution owner.
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"  # validate_secondmate_home: shared seeded-home boundary checks
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

first_pr_url_in_file() {  # <file>
  [ -f "$1" ] || return 1
  grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' "$1" 2>/dev/null | head -1
}

# One main-home worker row, printed as one jq -c object on one line.
main_worker_json() {  # <id> <meta-file>
  local id=$1 meta=$2 kind harness model pr pr_source raw rest state source detail sep
  local last_raw last_verb last_epoch last_age last_note last_json
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  harness=$(fm_meta_get "$meta" harness)
  model=$(fm_meta_get "$meta" model)
  pr=$(fm_meta_get "$meta" pr)
  pr_source=meta
  if [ -z "$pr" ]; then
    pr=$(first_pr_url_in_file "$STATE/$id.status" || true)
    pr_source=status_event
  fi
  [ -n "$pr" ] || { pr_source=absent; pr=; }

  raw=$(
    fm_run_timed "$FM_WORKER_TABLE_CREW_STATE_TIMEOUT" \
      env FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" \
      FM_SNAPSHOT_NOW_EPOCH="$now" \
      FM_CREW_STATE_NM_TIMEOUT="$(((FM_WORKER_TABLE_CREW_STATE_TIMEOUT + 1) / 2))" \
      "${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}" "$id" 2>/dev/null || true
  )
  raw=$(printf '%s\n' "$raw" | head -1)
  sep=' · '
  state=unknown
  source=none
  detail=
  case "$raw" in
    state:\ *"$sep"source:\ *)
      rest=${raw#state: }
      state=${rest%%"$sep"source: *}
      rest=${rest#*"$sep"source: }
      case "$rest" in
        *"$sep"*) source=${rest%%"$sep"*}; detail=${rest#*"$sep"} ;;
        *) source=$rest ;;
      esac
      ;;
  esac
  case "$state" in
    working|parked|done|blocked|paused|failed|unknown) ;;
    *) state=unknown ;;
  esac

  last_verb='' last_epoch='' last_age='' last_note=''
  last_json=null
  last_raw=$(status_last_meaningful_event "$STATE/$id.status")
  if [ -n "$last_raw" ]; then
    last_verb=$(status_line_verb "$last_raw")
    last_note=$(status_line_note "$last_raw")
    if last_epoch=$(status_line_at_epoch "$last_raw"); then
      if [ "$last_epoch" -le "$now" ]; then
        last_age=$((now - last_epoch))
      else
        last_epoch=
      fi
    else
      last_epoch=
    fi
  fi
  if [ -n "$last_verb" ]; then
    last_json=$(jq -cn --arg verb "$last_verb" --arg note "$last_note" \
      --arg epoch "$last_epoch" --arg age "$last_age" '
      {verb:$verb, note:(if $note == "" then null else $note end),
       emitted_at_epoch:(if $epoch == "" then null else ($epoch | tonumber) end),
       age_seconds:(if $age == "" then null else ($age | tonumber) end)}')
  fi
  jq -cn \
    --arg id "$id" --arg kind "$kind" --arg harness "$harness" --arg model "$model" \
    --arg state "$state" --arg source "$source" --arg detail "$detail" \
    --arg pr "$pr" --arg pr_source "$pr_source" --argjson last "$last_json" '
    {id:$id, kind:$kind,
     harness:(if $harness == "" then null else $harness end),
     model:(if $model == "" then null else $model end),
     state:$state, state_class:($state |
       if . == "working" then "working"
       elif . == "parked" or . == "paused" or . == "blocked" then "parked"
       else "idle" end),
     source:(if $source == "" then null else $source end),
     detail:(if $detail == "" then null else $detail end),
     pr:(if $pr == "" then null else $pr end),
     pr_source:(if $pr_source == "absent" then null else $pr_source end),
     last_progress:$last}'
}

# The worker rows of one cached secondmate home, printed as one jq -c array.
# Ages are recomputed against this run's clock from each event's own
# emission time; a future emission time keeps its age unknown.
cache_workers_json() {  # <cache-file>
  jq -c --argjson now "$now" '
    def cls:
      if . == "working" then "working"
      elif . == "parked" or . == "paused" or . == "blocked" then "parked"
      else "idle" end;
    [.tasks[]? | select((.kind // "ship") != "secondmate")
     | {id, kind:(.kind // "ship"),
        harness:(if (.harness // "") == "" then null else .harness end),
        model:(.model // null),
        state:(.current_state.state // "unknown"),
        source:((.current_state.source // "") | if . == "" then null else . end),
        detail:(.current_state.detail // null),
        pr:(.pr.url // null),
        pr_source:(if (.pr.url // null) == null then null else .pr.source end),
        last_progress:(.last_meaningful_event // null |
          if . == null then null
          else {verb:(.verb // null), note:(.note // null),
            emitted_at_epoch:(.emitted_at_epoch // null),
            age_seconds:(if (.emitted_at_epoch | type) == "number" and .emitted_at_epoch <= $now
              then ($now - .emitted_at_epoch) else null end)} end)}
     | .state_class = (.state | cls)]' "$1"
}

counts_of() {  # <workers-array-json>
  printf '%s' "$1" | jq -c '
    {total:length,
     working:([.[] | select(.state == "working")] | length),
     parked:([.[] | select(.state_class == "parked")] | length),
     idle:([.[] | select(.state_class == "idle")] | length)}'
}

cache_route_key() {  # <id> <host> <home> -> sha256 hex, or fail
  local id=$1 host=$2 home=$3 key
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  if command -v shasum >/dev/null 2>&1; then
    key=$(printf '%s\n%s\n%s\n' "$id" "$host" "$home" | shasum -a 256 | awk '{print $1}') || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    key=$(printf '%s\n%s\n%s\n' "$id" "$host" "$home" | sha256sum | awk '{print $1}') || return 1
  else
    return 1
  fi
  case "$key" in ''|*[!A-Fa-f0-9]*) return 1 ;; esac
  [ "${#key}" -eq 64 ] || return 1
  printf '%s' "$key"
}

# Validate a cached board input the same way the collector's stale fallback
# does: right schema, right home, a generation not in the future.
cache_input_ok() {  # <cache-file> <home>
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  jq -e --arg home "$2" --argjson now "$now" \
    '.schema == "fm-live-board-input.v1"
     and .fm_home == $home
     and (.generated_epoch | type == "number" and . >= 0 and . <= $now and floor == .)
     and (.tasks | type == "array")
     and all(.tasks[];
       (.id | type == "string")
       and (.current_state | type == "object")
       and (.current_state.state | type == "string"))' "$1" >/dev/null 2>&1
}

home_id=main
if [ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ]; then
  IFS= read -r v < "$FM_HOME/.fm-secondmate-home" 2>/dev/null || v=
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  case "$v" in ''|*[!A-Za-z0-9._-]*) ;; *) home_id=$v ;; esac
fi

TABLE_TMP=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-worker-table.XXXXXX") || {
  echo "fm-worker-table: could not create a temporary directory" >&2
  exit 1
}
cleanup_table_tmp() { rm -rf -- "$TABLE_TMP"; }
trap cleanup_table_tmp EXIT INT TERM

HOMES_FILE="$TABLE_TMP/homes.jsonl"
: > "$HOMES_FILE"

home_block() {  # <id> <home> <status> <reason> <observed-epoch|''> <workers-array-json>
  local id=$1 home=$2 status=$3 reason=$4 observed=$5 workers=$6 counts cache_age
  cache_age=
  if [ "$status" = cached ] && [ -n "$observed" ]; then
    cache_age=$((now - observed))
    [ "$cache_age" -ge 0 ] || cache_age=0
  fi
  counts=$(counts_of "$workers") || counts='{"total":0,"working":0,"parked":0,"idle":0}'
  jq -cn --arg id "$id" --arg home "$home" --arg status "$status" \
    --arg reason "$reason" --arg observed "$observed" --arg cache_age "$cache_age" \
    --arg workers "$workers" --argjson counts "$counts" '
    {id:$id, home:$home, status:$status,
     reason:(if $reason == "" then null else $reason end),
     cache_age_s:(if $cache_age == "" then null else ($cache_age | tonumber) end),
     observed_at_epoch:(if $observed == "" then null else ($observed | tonumber) end),
     workers:($workers | fromjson),
     counts:$counts}' >> "$HOMES_FILE"
}

# --- this home ---------------------------------------------------------------
MAIN_WORKERS="$TABLE_TMP/main-workers.jsonl"
: > "$MAIN_WORKERS"
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  grep -qx 'kind=secondmate' "$meta" 2>/dev/null && continue
  id=$(basename "$meta" .meta)
  main_worker_json "$id" "$meta" >> "$MAIN_WORKERS" || true
done
MAIN_ARRAY=$(jq -s -c 'sort_by(.id)' "$MAIN_WORKERS") || MAIN_ARRAY=
[ -n "$MAIN_ARRAY" ] || MAIN_ARRAY='[]'
home_block "$home_id" "$FM_HOME" local '' '' "$MAIN_ARRAY"

# --- registered secondmate homes --------------------------------------------
if [ -f "$REGISTRY" ] && [ ! -L "$REGISTRY" ]; then
  while IFS= read -r reg_line || [ -n "$reg_line" ]; do
    secondmate_registry_parse_line "$reg_line" || continue
    sm_id=$SECONDMATE_REGISTRY_ID
    sm_home=$SECONDMATE_REGISTRY_HOME
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      home_block "$sm_id" "$sm_home" remote 'the home is on another machine' '' '[]'
      continue
    fi
    case "$sm_home" in
      /*) : ;;
      *)
        home_block "$sm_id" "$sm_home" invalid 'registered path is not absolute' '' '[]'
        continue
        ;;
    esac
    if validate_secondmate_home "$sm_id" "$sm_home" 2>/dev/null; then
      sm_home=$VALIDATED_HOME
    else
      home_block "$sm_id" "$sm_home" invalid "${VALIDATION_ERROR:-not a seeded secondmate home}" '' '[]'
      continue
    fi
    if ! key=$(cache_route_key "$sm_id" '' "$sm_home"); then
      home_block "$sm_id" "$sm_home" unreadable 'no sha256 tool for the cache route' '' '[]'
      continue
    fi
    cache="$CACHE_DIR/$key.board-input.json"
    if ! cache_input_ok "$cache" "$sm_home"; then
      home_block "$sm_id" "$sm_home" unreadable 'no valid cached worker rows for this home' '' '[]'
      continue
    fi
    observed=$(jq -r 'if (.generated_epoch | type) == "number" then .generated_epoch else "" end' "$cache") || observed=
    case "$observed" in ''|*[!0-9]*) observed= ;; esac
    workers=$(cache_workers_json "$cache") || workers=
    [ -n "$workers" ] || workers='[]'
    home_block "$sm_id" "$sm_home" cached '' "$observed" "$workers"
  done < "$REGISTRY"
fi

# --- document ----------------------------------------------------------------
DOC=$(jq -n --argjson now "$now" --arg fm_home "$FM_HOME" --arg home_id "$home_id" \
  --slurpfile homes "$HOMES_FILE" '
  ($homes | if length == 0 then [{id:"main",home:"",status:"local",reason:null,cache_age_s:null,observed_at_epoch:null,workers:[],counts:{total:0,working:0,parked:0,idle:0}}] else . end) as $homes
  | {schema:"fm-worker-table.v1", generated_epoch:$now, fm_home:$fm_home, home_id:$home_id,
     homes:$homes,
     totals:{homes:($homes | length),
       working:([$homes[].counts.working] | add // 0),
       parked:([$homes[].counts.parked] | add // 0),
       idle:([$homes[].counts.idle] | add // 0),
       workers:([$homes[].counts.total] | add // 0)}}') || {
  echo "fm-worker-table: could not assemble the worker table document" >&2
  exit 1
}

if [ "$mode" = json ]; then
  printf '%s\n' "$DOC"
  exit 0
fi

# --- plain text --------------------------------------------------------------
printf '%s' "$DOC" | jq -r '
  def age_text:
    if . == null then "unknown"
    elif . < 60 then "\(.)s"
    elif . < 3600 then "\(. / 60 | floor)m"
    elif . < 86400 then "\(. / 3600 | floor)h"
    else "\(. / 86400 | floor)d" end;
  def worker_rows($home):
    (($home.counts.total | tostring) + " worker" + (if $home.counts.total == 1 then "" else "s" end) + ", " + ($home.counts.working | tostring) + " working"),
    (if ($home.workers | length) == 0 then "  (no workers)"
     else $home.workers[]
     | "  " + .id + "  " + (if .harness == null then "-" else .harness end)
       + (if .model == null then "" else "/" + .model end)
       + "  " + .state + "  "
       + (if .last_progress == null then "unknown"
          else ((.last_progress.age_seconds | age_text) + " (" + (.last_progress.verb // "?") + ")") end)
       + "  " + (if .pr == null then "-" else .pr end)
     end);
  .totals as $totals
  | "workers: total=\($totals.workers) working=\($totals.working) parked=\($totals.parked) idle=\($totals.idle) homes=\($totals.homes)",
    (.homes[]
     | . as $home
     | ("\n" + $home.id + " (" + $home.home +
        (if $home.status == "cached" and $home.cache_age_s != null
           then " - cached " + ($home.cache_age_s | age_text) + " ago"
         elif $home.status == "local" then " - live"
         else " - " + $home.status + ": " + ($home.reason // "no worker rows") end) + ")"),
       (if ($home.status == "remote" or $home.status == "invalid" or $home.status == "unreadable")
        then empty
        else worker_rows($home)
        end))'

exit 0
