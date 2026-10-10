#!/usr/bin/env bash
# fm-place.sh - advise which home should take a new lane, from each candidate
# home's published lane facts. Advisory only: it never spawns, routes, sends,
# or moves anything, and firstmate still decides.
#
# Usage:
#   fm-place.sh --task <id> --project <name> --delivery <no-mistakes|direct-PR|local-only>
#               --fitting <home>[,<home>...] [--fallback <home>[,<home>...]]
#               [--profile <name>] [--requires <tag>[,<tag>...]] [--captain <home>] [--json]
#   fm-place.sh outcome <task-id> <home> [--by firstmate|captain] [--reason <text>]
#   fm-place.sh review [--since <N>d] [--json]
#
# Firstmate runs the first form at intake after it has routed by scope:
# --fitting names the homes whose scope fits, --fallback the homes to use only
# when every fitting home is blocked (in practice main), and --captain the home
# the captain named for this lane, which is always the answer. A home id is
# main (this home) or a secondmate id in data/secondmates.md, and must also be
# declared in config/lane-placement.json.
#
# Opt-in: config/lane-placement.json present with "mode": "advise".
#   Off is one "place: off (<why>)" line on stderr, nothing on stdout, exit 0:
#   FM_PLACE=off, an absent config file, or "mode": "off".
#   docs/configuration.md "Lane placement (config/lane-placement.json)" owns
#   the config members, the operator contract, and the decision rules.
#
# Facts: each candidate's state/lane-capacity.json (fm-lane-capacity.v1, owned
#   by bin/fm-capacity.sh). main is read from this home's state; a local
#   secondmate from its registered home; a remote secondmate through
#   bin/fm-on.sh <id> fm-remote-file.sh get state/lane-capacity.json, all remote
#   reads concurrent and each bounded by facts_budget_s. A missing, unreadable,
#   foreign, stale, future-dated, or unreachable document makes that home
#   unknown for this one decision; nothing is guessed.
#
# Output (stdout, TOON-style block):
#   place:
#     status: <status>   mode: advise   task: <id>   project: <name> (<delivery>)   profile: <name> <GB> GB
#     candidate: <home>[ (fallback)| (captain)] -> eligible score <n>: mem <a>/40 cpu <b>/25 room <c>/20[ captain <t>][ quota <t>][ unstable <t>]  [lanes <l>[+<pending>]/<cap>, <GB> GB free, runq <x>/core, facts <s> s]
#     candidate: <home> -> eligible, unranked: <reason>
#     candidate: <home> -> unknown: <reason>
#     candidate: <home> -> error: <reason>
#     candidate: <home> -> not eligible: <reason>[; <reason>...]
#     reason: <why the status is not clear>
#     note: <tie-break, fallback, or the captain's-choice facts>
#     place: <home>                       (clear and captain only)
#     log: <decision-id> | unwritten (<why>)
#   clear     -> one best home: the best fitting home, or the best fallback when every fitting home is blocked
#   captain   -> the captain named the home; its facts are shown for the record only
#   ambiguous -> no home is rankable on known facts; decide as today
#   full      -> every candidate is refused for a temporary reason; keep the item queued
#   escalate  -> every candidate is refused for a permanent reason; ask the captain as today
#   error     -> the task already runs in a candidate, or the decision failed; decide as today
#   --json prints the decision-log object instead of the block.
#
# Decision log: state/lane-placement.jsonl, one JSON object per line, mode
#   0600, append-only, rotated to state/lane-placement.jsonl.1 past 5 MB.
#   Each decision appends one {"v":1,"event":"place.advice",...} line naming
#   every candidate, its class, its reasons, and its score terms. Reasons are
#   fixed codes with ids and numbers; ssh and fm-on.sh error text goes to
#   stderr only. A log that
#   cannot be written leaves the advice printed with "log: unwritten (<why>)".
#
# outcome records the home firstmate actually chose as one place.outcome line:
#   followed is true or false against the latest advice for that task (null
#   with no advice) and outcome is the fixed code followed, override, or
#   no-advice; --by captain marks the captain's direction, and --reason text
#   goes to stderr only, never to the log. Recent outcomes whose task is not yet among
#   that home's published lanes count as pending lanes there for pending_ttl_s.
#
# review summarizes the log over the span (default 14d): advice by status,
#   agreement of outcomes with advice, every override and who made it, and per
#   home how often it was advised, chosen, unknown, unreachable, and refused,
#   with the refusal reasons.
#
# Environment:
#   FM_PLACE=off      one-call kill switch.
#   FM_PLACE_NOW      epoch seconds to judge facts and the log against, for
#                     tests and replays; defaults to this host's clock.
#   FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, and FM_DATA_OVERRIDE resolve
#   the home exactly as the other bin/ scripts do.
#
# Exit status: 0 for every placement outcome, including off, ambiguous, and
#   error, so intake is never blocked; 2 for a usage or configuration error
#   (an unknown flag, a home id that is not main or registered, a home or
#   profile missing from config/lane-placement.json, a malformed config, or
#   missing jq), which is actionable and never selected around. outcome exits
#   0 when recorded, 1 when the log cannot be written, 2 on a usage error;
#   review exits 0 with a report, 1 when there is no log, 2 on a usage error.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/secondmates.md"
POLICY="$CONFIG/lane-placement.json"
LOG="$STATE/lane-placement.jsonl"
FACTS_FILE=state/lane-capacity.json

FACTS_MAX_BYTES=65536
LOG_ROTATE_BYTES=5242880
DECISION_TIMEOUT=10

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"

die() { printf 'fm-place: %s\n' "$1" >&2; exit 2; }
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}
safe_id() { case "$1" in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
flat() { printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-"${2:-200}"; }

NOW=${FM_PLACE_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) die "FM_PLACE_NOW must be epoch seconds: $NOW" ;; esac

# A home id is main or a registered secondmate. Sets HOME_KIND (main, local,
# remote) and HOME_PATH (the local home directory).
HOME_KIND='' HOME_PATH=''
resolve_home() {
  HOME_KIND='' HOME_PATH=''
  safe_id "$1" || return 1
  if [ "$1" = main ]; then
    HOME_KIND=main
    return 0
  fi
  secondmate_registry_line_for_id "$REG" "$1" || return 1
  if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
    HOME_KIND=remote
  else
    HOME_KIND=local HOME_PATH=$SECONDMATE_REGISTRY_HOME
  fi
}

# Appends one JSON line to the log, rotating it first past LOG_ROTATE_BYTES.
# Prints why on failure.
append_log() {
  local line=$1 size
  if [ ! -d "$STATE" ]; then
    printf 'no state directory'
    return 1
  fi
  if [ -L "$LOG" ]; then
    printf 'the log is a symlink'
    return 1
  fi
  if [ -f "$LOG" ]; then
    size=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    if [ "$size" -gt "$LOG_ROTATE_BYTES" ]; then
      mv -f "$LOG" "$LOG.1" 2>/dev/null || { printf 'could not rotate the log'; return 1; }
    fi
  fi
  if ! (umask 077; printf '%s\n' "$line" >> "$LOG") 2>/dev/null; then
    printf 'could not append to the log'
    return 1
  fi
  chmod 600 "$LOG" 2>/dev/null || true
}

log_lines() {  # the log as one JSON array, skipping lines that are not JSON objects
  if [ -f "$LOG" ] && [ ! -L "$LOG" ]; then
    jq -cnR '[inputs | (try fromjson catch null) | objects]' "$LOG" 2>/dev/null || printf '[]'
  else
    printf '[]'
  fi
}

# --- outcome -----------------------------------------------------------------
cmd_outcome() {
  local task='' home='' by=firstmate reason='' advice line why
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) [ $# -ge 2 ] || die "--by needs a value"; by=$2; shift 2 ;;
      --reason) [ $# -ge 2 ] || die "--reason needs a value"; reason=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) die "unknown flag $1" ;;
      *)
        if [ -z "$task" ]; then task=$1
        elif [ -z "$home" ]; then home=$1
        else die "outcome takes one task id and one home"
        fi
        shift
        ;;
    esac
  done
  [ -n "$task" ] && [ -n "$home" ] || die "outcome needs <task-id> <home> (see --help)"
  safe_id "$task" || die "unsafe task id: $task"
  resolve_home "$home" || die "unknown home '$home': not main and not one registered secondmate in data/secondmates.md"
  case "$by" in firstmate|captain) ;; *) die "--by must be firstmate or captain" ;; esac
  command -v jq >/dev/null 2>&1 || die "jq required"
  reason=$(flat "$reason" 300)
  [ -z "$reason" ] || printf 'fm-place: outcome reason (not logged): %s\n' "$reason" >&2
  advice=$(log_lines | jq -c --arg t "$task" '[.[] | select(.event == "place.advice" and .task == $t)] | last // null')
  line=$(jq -cn --argjson now "$NOW" --arg task "$task" --arg home "$home" --arg by "$by" \
    --argjson advice "${advice:-null}" '
    (if $advice == null or ($advice.place // null) == null then null else $advice.place == $home end) as $followed |
    {v: 1, ts: $now, event: "place.outcome", id: ($advice.id // null), task: $task, home: $home, by: $by,
     followed: $followed,
     outcome: (if $followed == null then "no-advice" elif $followed then "followed" else "override" end)}') || die "could not assemble the outcome"
  if ! why=$(append_log "$line"); then
    printf 'fm-place: outcome not recorded: %s\n' "$why" >&2
    exit 1
  fi
  printf '%s\n' "$line" | jq -r '"place-outcome: recorded \(.task) -> \(.home) by \(.by) (followed: \(if .followed == null then "no advice" elif .followed then "yes" else "no" end))"'
  exit 0
}

# --- review ------------------------------------------------------------------
cmd_review() {
  local since=14d json=0 days
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) [ $# -ge 2 ] || die "--since needs a value"; since=$2; shift 2 ;;
      --json) json=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown review argument $1" ;;
    esac
  done
  days=${since%d}
  case "$since:$days" in *d:[0-9]*) ;; *) die "--since must be a number of days such as 14d" ;; esac
  case "$days" in *[!0-9]*) die "--since must be a number of days such as 14d" ;; esac
  command -v jq >/dev/null 2>&1 || die "jq required"
  if [ ! -f "$LOG" ] || [ -L "$LOG" ]; then
    echo "fm-place: no decision log yet ($LOG)" >&2
    exit 1
  fi
  local report
  report=$(log_lines | jq -c --argjson now "$NOW" --argjson days "$((10#$days))" '
    ($now - $days * 86400) as $from |
    [.[] | select((.ts | type) == "number" and .ts >= $from)] as $all |
    [$all[] | select(.event == "place.advice")] as $adv |
    [$all[] | select(.event == "place.outcome")] as $out |
    def kind: if test("\\(warming\\)") then "warming" else (split(":")[0]) end;
    def counts: group_by(.) | map({key: .[0], value: length}) | sort_by(-.value, .key) | from_entries;
    ([$adv[].candidates[]?.home] + [$out[].home] | unique) as $homes |
    {since_days: $days, advice: ($adv | length), outcomes: ($out | length),
     status: ([$adv[].status] | counts),
     agreement: {judged: ([$out[] | select(.followed != null)] | length),
                 followed: ([$out[] | select(.followed == true)] | length)},
     overrides: [$out[] | select(.followed == false) | . as $o |
       {task, chose: .home, by,
        advised: ([$adv[] | select(.id == $o.id)] | last | .place // null)}],
     homes: [$homes[] as $h |
       [$adv[].candidates[]? | select(.home == $h)] as $c |
       {home: $h,
        advised: ([$adv[] | select(.place == $h)] | length),
        chosen: ([$out[] | select(.home == $h)] | length),
        listed: ($c | length),
        unknown: ([$c[] | select(.class == "unknown")] | length),
        unreachable: ([$c[] | select(.class == "unknown" and any(.reasons[]?; startswith("facts unreachable")))] | length),
        refused: ([$c[] | select(.class == "refused") | .reasons[]? | kind] | counts)}]}') || die "could not read the decision log"
  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$report"
    exit 0
  fi
  printf '%s\n' "$report" | jq -r '
    def pairs: to_entries | map("\(.key) \(.value)") | join(", ");
    "place-review:",
    "  span: \(.since_days) d   advice: \(.advice)   outcomes: \(.outcomes)",
    (if (.status | length) > 0 then "  status: \(.status | pairs)" else empty end),
    "  agreement: \(.agreement.followed) of \(.agreement.judged) followed" +
      (if .agreement.judged > 0 then " (\((.agreement.followed * 100 / .agreement.judged) | floor)%)" else "" end),
    (.overrides[] | "  override: \(.task) advised \(.advised // "nothing") chose \(.chose) by \(.by)"),
    (.homes[] | "  home: \(.home)   advised \(.advised)   chosen \(.chosen)   listed \(.listed)   unknown \(.unknown) (unreachable \(.unreachable))" +
      (if (.refused | length) > 0 then "   refused: \(.refused | pairs)" else "" end))'
  exit 0
}

case "${1:-}" in
  outcome) shift; cmd_outcome "$@" ;;
  review) shift; cmd_review "$@" ;;
esac

# --- placement: arguments ------------------------------------------------------
TASK='' PROJECT='' DELIVERY='' FITTING='' FALLBACK='' PROFILE=default REQUIRES='' CAPTAIN='' JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --task|--project|--delivery|--fitting|--fallback|--profile|--requires|--captain)
      [ $# -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --task) TASK=$2 ;;
        --project) PROJECT=$2 ;;
        --delivery) DELIVERY=$2 ;;
        --fitting) FITTING=$2 ;;
        --fallback) FALLBACK=$2 ;;
        --profile) PROFILE=$2 ;;
        --requires) REQUIRES=$2 ;;
        --captain) CAPTAIN=$2 ;;
      esac
      shift 2
      ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument $1 (see --help)" ;;
  esac
done

if [ "${FM_PLACE:-}" = off ]; then
  echo "place: off (FM_PLACE=off)" >&2
  exit 0
fi
if [ ! -e "$POLICY" ] && [ ! -L "$POLICY" ]; then
  echo "place: off (config/lane-placement.json absent)" >&2
  exit 0
fi
command -v jq >/dev/null 2>&1 || die "jq required"
[ -f "$POLICY" ] && [ -r "$POLICY" ] || die "config/lane-placement.json is not a readable regular file"

# --- placement: config ------------------------------------------------------------
POLICY_JSON=$(jq -c . "$POLICY" 2>/dev/null) || die "config/lane-placement.json is not valid JSON"
policy_error=$(printf '%s' "$POLICY_JSON" | jq -r '
  def nonneg: type == "number" and . >= 0;
  def posint: type == "number" and . >= 1 and . == floor;
  def strs: type == "array" and all(.[]; type == "string" and test("^[A-Za-z0-9._-]+$"));
  def only($allowed): [keys[] | select(. as $k | $allowed | index($k) | not)];
  if type != "object" then "must be one JSON object"
  elif (only(["schema","mode","homes","profiles","reserve_gb","facts_max_age_s","facts_budget_s","min_uptime_s","unstable_window_s","pending_ttl_s"]) | length) > 0
    then "unknown member \(only(["schema","mode","homes","profiles","reserve_gb","facts_max_age_s","facts_budget_s","min_uptime_s","unstable_window_s","pending_ttl_s"])[0])"
  elif .schema != "fm-lane-placement.v1" then "schema must be fm-lane-placement.v1"
  elif .mode == "enforce" then "mode enforce is not available in this version; use advise or off"
  elif (.mode | IN("off", "advise")) | not then "mode must be off or advise"
  elif (.homes | type) != "object" or (.homes | length) == 0 then "homes must be a non-empty object"
  elif any(.homes | keys[]; test("^[A-Za-z0-9._-]+$") | not) then "a home id holds characters outside A-Z a-z 0-9 . _ -"
  elif any(.homes[]; type != "object") then "every home must be an object"
  elif any(.homes[]; (only(["rank","captain_machine","tags"]) | length) > 0) then "a home has a member other than rank, captain_machine, and tags"
  elif any(.homes[]; has("rank") and ((.rank | posint) or .rank == 0 | not)) then "a home rank must be a non-negative integer"
  elif any(.homes[]; has("captain_machine") and ((.captain_machine | type) != "boolean")) then "captain_machine must be true or false"
  elif any(.homes[]; has("tags") and ((.tags | strs) | not)) then "tags must be an array of names"
  elif has("profiles") and ((.profiles | type) != "object") then "profiles must be an object"
  elif any((.profiles // {}) | keys[]; test("^[A-Za-z0-9._-]+$") | not) then "a profile name holds characters outside A-Z a-z 0-9 . _ -"
  elif any((.profiles // {})[]; type != "object" or (only(["footprint_gb","requires"]) | length) > 0) then "a profile has a member other than footprint_gb and requires"
  elif any((.profiles // {})[]; has("footprint_gb") and ((.footprint_gb | nonneg) | not)) then "footprint_gb must be a non-negative number"
  elif any((.profiles // {})[]; has("requires") and ((.requires | strs) | not)) then "requires must be an array of tag names"
  elif has("reserve_gb") and ((.reserve_gb | nonneg) | not) then "reserve_gb must be a non-negative number"
  elif any(("facts_max_age_s","facts_budget_s","min_uptime_s","unstable_window_s","pending_ttl_s") as $k | select(has($k)) | .[$k]; posint | not)
    then "facts_max_age_s, facts_budget_s, min_uptime_s, unstable_window_s, and pending_ttl_s must be positive integers"
  else "" end' 2>/dev/null) || die "config/lane-placement.json could not be checked"
[ -z "$policy_error" ] || die "config/lane-placement.json: $policy_error"

MODE=$(printf '%s' "$POLICY_JSON" | jq -r '.mode')
if [ "$MODE" = off ]; then
  echo "place: off (mode off in config/lane-placement.json)" >&2
  exit 0
fi

# --- placement: inputs ------------------------------------------------------------
[ -n "$TASK" ] || die "--task is required"
safe_id "$TASK" || die "unsafe task id: $TASK"
[ -n "$PROJECT" ] || die "--project is required"
safe_id "$PROJECT" || die "unsafe project name: $PROJECT"
case "$DELIVERY" in no-mistakes|direct-PR|local-only) ;; *) die "--delivery must be no-mistakes, direct-PR, or local-only" ;; esac
[ -n "$FITTING" ] || die "--fitting needs at least one home"
safe_id "$PROFILE" || die "unsafe profile name: $PROFILE"
if [ "$PROFILE" != default ] && ! printf '%s' "$POLICY_JSON" | jq -e --arg p "$PROFILE" '(.profiles // {}) | has($p)' >/dev/null; then
  die "profile '$PROFILE' is not declared in config/lane-placement.json"
fi
if [ -n "$REQUIRES" ]; then
  case ",$REQUIRES," in *,,*) die "--requires holds an empty tag" ;; esac
  case "$REQUIRES" in *[!A-Za-z0-9._,-]*) die "--requires holds characters outside A-Z a-z 0-9 . _ -" ;; esac
fi

# Every home: its id, its group, and where its facts live. One row per home,
# tab-separated: id, group, kind, local home path.
HOMES=''
add_home() {  # <id> <group>
  local id=$1 group=$2
  case "
$HOMES" in *"
$id	"*) die "home '$id' is named more than once" ;; esac
  resolve_home "$id" || die "unknown home '$id': not main and not one registered secondmate in data/secondmates.md"
  printf '%s' "$POLICY_JSON" | jq -e --arg h "$id" '.homes | has($h)' >/dev/null \
    || die "home '$id' is not declared in config/lane-placement.json"
  case "$HOME_KIND" in
    local) case "$HOME_PATH" in /*) ;; *) HOME_PATH='' ;; esac ;;
  esac
  HOMES="$HOMES$id	$group	$HOME_KIND	$HOME_PATH
"
}
split_list() { printf '%s' "$1" | tr ',' '\n'; }
case ",$FITTING," in *,,*) die "--fitting holds an empty home" ;; esac
case ",$FALLBACK," in ,,) ;; *,,*) die "--fallback holds an empty home" ;; esac
fitting_list='' fallback_list=''
while IFS= read -r h; do
  add_home "$h" fitting
  fitting_list="$fitting_list$h,"
done <<EOF
$(split_list "$FITTING")
EOF
if [ -n "$FALLBACK" ]; then
  while IFS= read -r h; do
    add_home "$h" fallback
    fallback_list="$fallback_list$h,"
  done <<EOF
$(split_list "$FALLBACK")
EOF
fi
if [ -n "$CAPTAIN" ]; then
  case "
$HOMES" in
    *"
$CAPTAIN	"*) ;;
    *) add_home "$CAPTAIN" captain ;;
  esac
fi

# --- placement: facts -------------------------------------------------------------
WORK=$(mktemp -d 2>/dev/null) || die "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
BUDGET=$(printf '%s' "$POLICY_JSON" | jq -r '.facts_budget_s // 5')

# Reads one local document into <slot>.doc, or writes the reason to <slot>.why.
read_local() {  # <slot> <file>
  local slot=$1 file=$2 bytes
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf 'no published facts\n' > "$WORK/$slot.missing"
    return
  fi
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    printf 'facts unreadable: not a regular file\n' > "$WORK/$slot.why"
    return
  fi
  if ! head -c "$((FACTS_MAX_BYTES + 1))" "$file" > "$WORK/$slot.doc" 2>/dev/null; then
    rm -f "$WORK/$slot.doc"
    printf 'facts unreadable\n' > "$WORK/$slot.why"
    return
  fi
  bytes=$(wc -c < "$WORK/$slot.doc" | tr -d ' ')
  if [ "$bytes" -gt "$FACTS_MAX_BYTES" ]; then
    rm -f "$WORK/$slot.doc"
    printf 'facts unreadable: over %s bytes\n' "$FACTS_MAX_BYTES" > "$WORK/$slot.why"
  fi
}

# Fetches one remote document through fm-on.sh, bounded by the budget.
read_remote() {  # <slot> <id>
  local slot=$1 id=$2 rc err
  fm_run_timed "$BUDGET" "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-file.sh get "$FACTS_FILE" "$FACTS_MAX_BYTES" \
    > "$WORK/$slot.doc" 2> "$WORK/$slot.err" < /dev/null
  rc=$?
  [ "$rc" -eq 0 ] && return
  rm -f "$WORK/$slot.doc"
  err=$(head -n 1 "$WORK/$slot.err" 2>/dev/null)
  err=$(flat "${err#error: }" 160)
  case "$rc" in
    124) printf 'facts unreachable: timeout after %s s (exit 124)\n' "$BUDGET" > "$WORK/$slot.unreachable" ;;
    255) printf 'facts unreachable (exit 255)\n' > "$WORK/$slot.unreachable" ;;
    *) printf 'no published facts: missing (exit %s)\n' "$rc" > "$WORK/$slot.missing" ;;
  esac
  printf 'fm-place: %s: fm-on.sh exit %s%s\n' "$id" "$rc" "${err:+: $err}" >&2
}

T0=$(fm_timing_now_ms)
slot=0
while IFS='	' read -r id group kind path; do
  [ -n "$id" ] || continue
  slot=$((slot + 1))
  printf '%s\n' "$id" > "$WORK/$slot.id"
  case "$kind" in
    main) read_local "$slot" "$STATE/lane-capacity.json" ;;
    local)
      if [ -n "$path" ]; then
        read_local "$slot" "$path/$FACTS_FILE"
      else
        printf 'facts unreadable: its registered home is not an absolute path\n' > "$WORK/$slot.why"
      fi
      ;;
    remote) read_remote "$slot" "$id" & ;;
  esac
done <<EOF
$HOMES
EOF
wait
T1=$(fm_timing_now_ms)
FACTS_MS=$((T1 - T0))
[ "$FACTS_MS" -ge 0 ] || FACTS_MS=0

# One object per home: {doc}, {unknown: why}, {unreachable: why}, or {missing: why}.
FACTS='{}'
i=0
while [ "$i" -lt "$slot" ]; do
  i=$((i + 1))
  id=$(cat "$WORK/$i.id")
  entry=
  if [ -f "$WORK/$i.doc" ]; then
    if entry=$(jq -c --arg h "$id" '
        if type != "object" or .schema != "fm-lane-capacity.v1" then {unknown: "facts unreadable: not an fm-lane-capacity.v1 document"}
        elif (.generated_epoch | type) != "number" then {unknown: "facts unreadable: no generated_epoch"}
        elif ($h != "main" and .home != $h) or ($h == "main" and .home != "main") then {unknown: "facts name home \(.home | tostring), not \($h)"}
        elif (.lanes.count | type) != "number" or (.pressure | type) != "object" or (.cap | type) != "object" then {unknown: "facts unreadable: lanes, cap, or pressure missing"}
        else {doc: .} end' "$WORK/$i.doc" 2>/dev/null) && [ -n "$entry" ]; then
      :
    else
      entry='{"unknown":"facts unreadable: not JSON"}'
    fi
  elif [ -f "$WORK/$i.unreachable" ]; then
    entry=$(jq -cn --arg w "$(head -n 1 "$WORK/$i.unreachable")" '{unreachable: $w}')
  elif [ -f "$WORK/$i.missing" ]; then
    entry=$(jq -cn --arg w "$(head -n 1 "$WORK/$i.missing")" '{missing: $w}')
  else
    entry=$(jq -cn --arg w "$(head -n 1 "$WORK/$i.why" 2>/dev/null || printf 'facts unreadable')" '{unknown: $w}')
  fi
  FACTS=$(printf '%s' "$FACTS" | jq -c --arg h "$id" --argjson e "$entry" '. + {($h): $e}')
done

# --- placement: decision ----------------------------------------------------------
printf '%s' "$POLICY_JSON" > "$WORK/policy.json"
printf '%s' "$FACTS" > "$WORK/facts.json"
log_lines > "$WORK/log.json"
cat > "$WORK/decide.jq" <<'JQ'
$cfg[0] as $c |
$facts[0] as $facts |
$logs[0] as $log |
($c.profiles // {}) as $profiles |
($profiles[$profile] // {footprint_gb: 1.0}) as $prof |
($prof.footprint_gb // 1.0) as $foot |
((($requires | split(",") | map(select(length > 0))) + ($prof.requires // [])) | unique) as $req |
($c.unstable_window_s // 21600) as $win |
def clamp($lo; $hi): if . < $lo then $lo elif . > $hi then $hi else . end;
def num: if . == null then "unknown" elif . == floor then (floor | tostring) else ((. * 100 | round) / 100 | tostring) end;
def evaluate($h; $group):
  ($c.homes[$h]) as $hc |
  ($facts[$h] // {missing: "no published facts"}) as $f |
  ($f.doc // null) as $d |
  (if $d == null then null else ($now - $d.generated_epoch) end) as $age |
  ([$log[] | select(.event == "place.outcome" and .home == $h and (.ts | type) == "number" and .ts > ($now - ($c.pending_ttl_s // 600)))
    | select(.task as $t | (($d.lanes.ids // []) | index($t)) == null) | .task] | unique | length) as $pending |
  ([$log[] | select(.event == "place.advice" and (.ts | type) == "number" and .ts > ($now - $win))
    | .candidates[]? | select(.home == $h and .class == "unknown" and any(.reasons[]?; startswith("facts unreachable")))] | length) as $recent_fail |
  (if $d == null then 0 else ([($d.boots // [])[] | numbers | select(. > ($d.generated_epoch - $win) and . <= $d.generated_epoch)] | length) end) as $restarts |
  {home: $h, group: $group, rank: ($hc.rank // 99)} as $base |
  if $delivery == "local-only" and $h != "main" then $base + {class: "refused", permanent: true, reasons: ["local-only work stays in the main home"]}
  elif $f.unreachable then $base + {class: "unknown", reasons: [$f.unreachable]}
  elif $f.missing then $base + {class: "unknown", reasons: [$f.missing]}
  elif $f.unknown then $base + {class: "unknown", reasons: [$f.unknown]}
  elif $age < -60 then $base + {class: "unknown", reasons: ["facts dated \(-$age) s in the future: clock skew"]}
  elif $age > ($c.facts_max_age_s // 120) then $base + {class: "unknown", reasons: ["facts \($age) s old (home not publishing)"]}
  elif ($d.watcher_beat_age_s | type) == "number" and $d.watcher_beat_age_s > 300 then $base + {class: "unknown", reasons: ["watcher beat \($d.watcher_beat_age_s) s old (home not supervising)"]}
  elif (($d.lanes.ids // []) | index($task)) != null then $base + {class: "error", reasons: ["task \($task) already runs here: placement is for new lanes only"]}
  else
    ($d.pressure) as $p |
    (if $d.cap.status == "ok" then $d.cap.target else null end) as $cap |
    ([$d.limits.min_avail_gb // 0, $c.reserve_gb // 2] | max) as $keep |
    ([
      (if ((($d.projects // []) | index($project)) == null) then {t: "perm", m: "no \($project) clone in this home"} else empty end),
      ($req[] as $tag | if ((($hc.tags // []) | index($tag)) == null) then {t: "perm", m: "lacks \($tag)"} else empty end),
      (if $d.reserve.flag == "present" then {t: "temp", m: "captain-reserve"} else empty end),
      (if (($d.uptime_s | type) == "number" and $d.uptime_s < ($c.min_uptime_s // 1800)) then {t: "temp", m: "booted \(($d.uptime_s / 60) | floor) min ago (warming)"} else empty end),
      (if $restarts >= 2 then {t: "temp", m: "unstable: restarted \($restarts) times in \($win / 3600 | num) h"} else empty end),
      (if $p.on_battery == true then {t: "temp", m: "on battery"} else empty end),
      (if $d.cap.status == "invalid" then {t: "temp", m: "its config/lane-capacity is unreadable"} else empty end),
      (if ($cap != null and ($d.lanes.count + $pending) >= $cap) then {t: "temp", m: "full: \($d.lanes.count)\(if $pending > 0 then "+\($pending) pending" else "" end) of \($cap) lanes"} else empty end),
      (if ($p.level == "warn" or $p.level == "critical") then {t: "temp", m: "pressure \($p.level): \(($p.why // []) | join("; "))"} else empty end),
      (if (($p.avail_gb | type) == "number" and ($p.avail_gb - $keep) < $foot) then {t: "temp", m: "no room for a \($foot | num) GB lane: \($p.avail_gb | num) GB available, \($keep | num) GB kept"} else empty end),
      (if ($d.quota.runway // "") == "exhausted_now" then {t: "temp", m: "quota exhausted now"} else empty end)
    ]) as $refuse0 |
    (if ($refuse0 | length) == 0 and $d.cap.status == "ok" and $d.verdict.admit == false
     then [{t: "temp", m: "its own verdict: \(($d.verdict.reasons // []) | join("; "))"}] else $refuse0 end) as $refuse |
    {lanes: $d.lanes.count, cap: $cap, pending: $pending, pressure: $p.level, basis: $p.basis, facts_age_s: $age,
     avail_gb: $p.avail_gb, runq_per_core: $p.runq_per_core, captain: $d.captain} as $ev |
    if ($refuse | length) > 0 then
      $base + $ev + {class: "refused", permanent: (all($refuse[]; .t == "perm")), reasons: [$refuse[].m]}
    else
      (if ($p.avail_gb | type) != "number" or ($p.total_gb | type) != "number" or $p.total_gb <= 0 then null
       else ((40 * ((($p.avail_gb - $keep - $foot) / ($p.total_gb * 0.5)) | clamp(0; 1))) | floor) end) as $mem |
      (if ($p.runq_per_core | type) != "number" then null else ((25 * ((1 - $p.runq_per_core / 3) | clamp(0; 1))) | floor) end) as $cpu |
      (if $cap == null or $cap == 0 then null else ((20 * (($cap - $d.lanes.count - $pending) / $cap)) | floor) end) as $room |
      (if ($hc.captain_machine // false) then (if ($d.captain == "idle" or $d.captain == "away") then -5 else -15 end) else 0 end) as $capt |
      (if ($d.quota.runway // "") == "projected_exhaustion" then -10 else 0 end) as $quota |
      (if ($recent_fail > 0 or $restarts == 1) then -10 else 0 end) as $unstable |
      if $p.level != "ok" or $mem == null or $cpu == null or $room == null then
        $base + $ev + {class: "unranked", reasons: [
          (if $p.level != "ok" then "pressure \($p.level // "unknown") (\($p.basis // "none"))" else empty end),
          (if $room == null then "no lane cap declared" else empty end),
          (if ($p.level == "ok" and ($mem == null or $cpu == null)) then "memory or run queue unknown" else empty end)]}
      else
        $base + $ev + {class: "eligible", reasons: [],
          terms: {mem: $mem, cpu: $cpu, room: $room, captain: $capt, quota: $quota, unstable: $unstable},
          score: ($mem + $cpu + $room + $capt + $quota + $unstable)}
      end
    end
  end;
($fitting | split(",") | map(select(length > 0))) as $list |
($fallback | split(",") | map(select(length > 0))) as $fb |
([($list[] | evaluate(.; "fitting")), ($fb[] | evaluate(.; "fallback"))]
 + (if $captain != "" and (($list + $fb) | index($captain)) == null then [evaluate($captain; "captain")] else [] end)) as $cs |
def best($g): [$cs[] | select(.group == $g and .class == "eligible")] | sort_by(-.score, .rank, .home);
def has($g; $cls): any($cs[]; .group == $g and .class == $cls);
def named($cls): [$cs[] | select(.group != "captain" and (.class | IN($cls[]))) | "\(.home): \(.reasons[0])"] | join("; ");
def tie($o): if ($o | length) > 1 and $o[1].score == $o[0].score
  then (if $o[0].rank == $o[1].rank
    then "tie at \($o[0].score) broken by the home id (\($o[0].home) and \($o[1].home) both rank \($o[0].rank))"
    else "tie at \($o[0].score) broken by the fixed rank in config/lane-placement (\($o[0].home) rank \($o[0].rank), \($o[1].home) rank \($o[1].rank))" end)
  else null end;
(best("fitting")) as $ok |
(best("fallback")) as $okf |
([$cs[] | select(.group != "captain" and .class == "error")]) as $err |
([$cs[] | select(.group == "fitting") | "\(.home): \(.reasons[0] // .class)"] | join("; ")) as $blocked |
(if $captain != "" then {status: "captain", place: $captain, reason: "the captain named this home"}
   + ([$cs[] | select(.home == $captain and .class != "eligible")] | if length > 0 then
       {note: "facts for the captain's choice, for the record only: \(.[0].reasons | join("; "))"} else {} end)
 elif ($err | length) > 0 then {status: "error", reason: $err[0].reasons[0]}
 elif ($ok | length) > 0 then {status: "clear", place: $ok[0].home} + (tie($ok) | if . then {note: .} else {} end)
 elif has("fitting"; "unranked") then {status: "ambiguous", reason: "a fitting home is not rankable on known facts (\(named(["unranked"]))); decide as today"}
 elif ($okf | length) > 0 then {status: "clear", place: $okf[0].home,
   note: ([if $delivery == "local-only" and $okf[0].home == "main" and all($cs[] | select(.group == "fitting"); .reasons == ["local-only work stays in the main home"])
           then "local-only work stays in the main home"
           else "every fitting home is blocked (\($blocked)); \($okf[0].home) is the fallback" end, tie($okf)] | map(select(. != null)) | join("; "))}
 elif has("fallback"; "unranked") or any($cs[] | select(.group != "captain"); .class == "unknown")
   then {status: "ambiguous", reason: "no home is rankable on known facts (\(named(["unknown", "unranked"])))\(if any($cs[]; .class == "refused") then "; every other home is refused" else "" end); decide as today"}
 elif all($cs[] | select(.group != "captain"); .class == "refused" and .permanent) then {status: "escalate", reason: "no in-scope home can run this lane"}
 else {status: "full", reason: "every in-scope home is full, under pressure or reserved; keep the item queued and re-evaluate at the next teardown or heartbeat"} end) as $sel |
{v: 1, ts: $now, event: "place.advice", id: "\($now)-\($task)", mode: $c.mode, task: $task, project: $project,
 delivery: $delivery, profile: $profile, footprint_gb: $foot, requires: $req,
 fitting: $list, fallback: $fb, captain_named: (if $captain == "" then null else $captain end), facts_ms: $facts_ms}
+ $sel + {candidates: $cs}
JQ

RESULT=$(fm_run_timed "$DECISION_TIMEOUT" jq -cn \
  --slurpfile cfg "$WORK/policy.json" --slurpfile facts "$WORK/facts.json" --slurpfile logs "$WORK/log.json" \
  --argjson now "$NOW" --argjson facts_ms "$FACTS_MS" --arg task "$TASK" --arg project "$PROJECT" \
  --arg delivery "$DELIVERY" --arg fitting "$fitting_list" --arg fallback "$fallback_list" \
  --arg profile "$PROFILE" --arg captain "$CAPTAIN" --arg requires "$REQUIRES" \
  -f "$WORK/decide.jq" 2> "$WORK/decide.err")
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$RESULT" ]; then
  why="decision failed"
  [ "$rc" -ne 124 ] || why="decision timed out after $DECISION_TIMEOUT s"
  RESULT=$(jq -cn --argjson now "$NOW" --arg task "$TASK" --arg project "$PROJECT" --arg delivery "$DELIVERY" \
    --arg profile "$PROFILE" --arg mode "$MODE" --arg why "$why" '
    {v: 1, ts: $now, event: "place.advice", id: "\($now)-\($task)", mode: $mode, task: $task, project: $project,
     delivery: $delivery, profile: $profile, status: "error", reason: "\($why); decide as today", candidates: []}')
  printf 'fm-place: %s: %s\n' "$why" "$(flat "$(head -n 1 "$WORK/decide.err" 2>/dev/null)" 200)" >&2
fi

LOG_NOTE=''
if ! why=$(append_log "$RESULT"); then
  LOG_NOTE="unwritten ($why)"
  printf 'fm-place: decision log unwritten: %s\n' "$why" >&2
fi

if [ "$JSON" -eq 1 ]; then
  printf '%s\n' "$RESULT"
  exit 0
fi
printf '%s\n' "$RESULT" | jq -r --arg log_note "$LOG_NOTE" '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def num: if . == null then "unknown" elif . == floor then (floor | tostring) else ((. * 100 | round) / 100 | tostring) end;
  "place:",
  "  status: \(.status)   mode: \(.mode)   task: \(.task)   project: \(.project) (\(.delivery))   profile: \(.profile) \(.footprint_gb // 1 | num) GB",
  (.candidates[] |
    "  candidate: \(.home)\(if .group == "fallback" then " (fallback)" elif .group == "captain" then " (captain)" else "" end) -> " +
    (if .class == "eligible" then "eligible score \(.score): mem \(.terms.mem)/40 cpu \(.terms.cpu)/25 room \(.terms.room)/20"
        + (if .terms.captain != 0 then " captain \(.terms.captain)" else "" end)
        + (if .terms.quota != 0 then " quota \(.terms.quota)" else "" end)
        + (if .terms.unstable != 0 then " unstable \(.terms.unstable)" else "" end)
        + "  [lanes \(.lanes)\(if .pending > 0 then "+\(.pending)" else "" end)/\(.cap), \(.avail_gb | num) GB free, runq \(.runq_per_core | num)/core, facts \(.facts_age_s) s]"
     elif .class == "unranked" then "eligible, unranked: \(.reasons | join("; "))"
     elif .class == "unknown" then "unknown: \(.reasons | join("; "))"
     elif .class == "error" then "error: \(.reasons | join("; "))"
     else "not eligible: \(.reasons | join("; "))" end) | flat),
  (if .reason then "  reason: \(.reason | flat)" else empty end),
  (if .note then "  note: \(.note | flat)" else empty end),
  (if .place then "  place: \(.place)" else empty end),
  "  log: \(if $log_note == "" then .id else $log_note end)"'
exit 0
