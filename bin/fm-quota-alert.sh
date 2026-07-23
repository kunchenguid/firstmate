#!/usr/bin/env bash
# Read the CUSTOM quota sources declared in config/harness-overrides.json and
# report which launch identities are running out, plus where the captain could
# switch instead. Quota drives a REMINDER here and nothing else: this script is
# never consulted by dispatch, spawn, or any selector, so no reading it produces
# can move work onto a different billing identity. Only the captain's word or an
# explicit config change switches identities (docs/configuration.md).
#
# Usage:
#   fm-quota-alert.sh [--threshold <percent>] [--all] [--json] [--validate]
#                     [--overrides <file>] [--dispatch <file>]
#
#   --threshold <percent>  remaining-percent at or below which a lane is low
#                          (default 10, or FM_QUOTA_THRESHOLD)
#   --all                  also print lanes that are fine (QUOTA_OK)
#   --json                 machine-readable readings instead of report lines
#   --validate             check the declared quota blocks and exit without
#                          running any of them; this script owns that schema and
#                          bootstrap reports whatever it says
#   --overrides <file>     read launch identities from this file instead of
#                          config/harness-overrides.json
#   --dispatch <file>      read model/effort defaults from this file instead of
#                          config/crew-dispatch.json
#   -h, --help             print this header
#
# WHY THIS EXISTS: quota-axi reads local subscription credentials, so a gateway
# or otherwise third-party-billed identity is invisible to it - the exact lane
# that ran dry three times in one afternoon on 2026-07-23 with no warning. A
# custom source is declared where that identity is already defined, next to the
# command that launches it, so one file answers both "what is this identity" and
# "how do I read its balance".
#
# DECLARING A SOURCE (config/harness-overrides.json; full schema in
# docs/configuration.md "Custom quota sources"):
#   "quota": { "command": "llm-quota", "args": ["--json"], "key": "claude_code" }
# It sits on a variant when the harness declares variants, and on the harness
# entry when it declares none - never on both, because a lane must not inherit
# another lane's balance.
#
# THIS HEADER OWNS THE READING CONTRACT:
#   - The command runs with its args, bounded by FM_QUOTA_TIMEOUT seconds
#     (default 15), and must exit 0 with JSON on stdout.
#   - Entries are the top-level array, or, for an object, its single
#     array-valued field. Two array fields are ambiguous and unreadable.
#   - `key` selects an entry: normalized (lowercased, non-alphanumerics dropped)
#     it must equal the normalized value of the entry's key, id, label, name,
#     slug, or suffix field, and it must match EXACTLY ONE entry.
#   - Remaining percent comes from the first of these an entry supplies:
#     remain_pct, remaining_pct, percentRemaining, 100 - used_pct,
#     100 - percentUsed, or 100 * (limit - cost|used|spend) / limit.
#     The result is clamped to 0..100.
#   - Anything that fails - no command, non-zero exit, timeout, unparseable
#     JSON, ambiguous entries, no match, several matches, no usable numbers -
#     is reported as QUOTA_UNREADABLE with its reason and never as a healthy
#     lane, because silence about a lane must never read as "plenty left".
#   - Entries a source reports that no declared identity claims are printed as
#     QUOTA_UNCLAIMED: a real billed lane that cannot be selected because no
#     launch identity declares it.
#
# Report lines (stdout), each one evidence for firstmate to translate into plain
# captain-facing language, never to relay verbatim (AGENTS.md section 9):
#   QUOTA_LOW: <lane> remaining=<pct>% threshold=<pct>% [spend=<cost>/<limit>]
#   QUOTA_ALT: <lane> -> <lane> harness=<h> [model=<m>] [effort=<e>] remaining=<pct>%|unknown
#   QUOTA_OK: <lane> remaining=<pct>%          (--all only)
#   QUOTA_UNREADABLE: <lane> <reason>
#   QUOTA_UNCLAIMED: <command> <identity> remaining=<pct>%|unknown
# A lane is "<harness>.<variant>", or "<harness>" when it declares no variants.
# QUOTA_ALT lists the other declared identities, skipping any that is itself low,
# with the model and effort config/crew-dispatch.json would use for it: an exact
# harness+launch profile wins, then a harness-only profile, default before rules.
#
# Exit status: 2 for a configuration or environment error (bad JSON, invalid
# quota block, no jq), 0 for everything else INCLUDING every runtime read
# failure, so a quota reading can never become a reason to hold up work.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

OVERRIDES="$CONFIG/harness-overrides.json"
DISPATCH="$CONFIG/crew-dispatch.json"
THRESHOLD=${FM_QUOTA_THRESHOLD:-10}
TIMEOUT=${FM_QUOTA_TIMEOUT:-15}
SHOW_ALL=0
AS_JSON=0
VALIDATE_ONLY=0

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-quota-alert: %s\n' "$1" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --threshold)
      [ "$#" -gt 1 ] || die "--threshold requires a value"
      THRESHOLD=$2
      shift 2
      ;;
    --threshold=*) THRESHOLD=${1#--threshold=}; shift ;;
    --overrides)
      [ "$#" -gt 1 ] || die "--overrides requires a file"
      OVERRIDES=$2
      shift 2
      ;;
    --overrides=*) OVERRIDES=${1#--overrides=}; shift ;;
    --dispatch)
      [ "$#" -gt 1 ] || die "--dispatch requires a file"
      DISPATCH=$2
      shift 2
      ;;
    --dispatch=*) DISPATCH=${1#--dispatch=}; shift ;;
    --all) SHOW_ALL=1; shift ;;
    --json) AS_JSON=1; shift ;;
    --validate) VALIDATE_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"
printf '%s\n' "$THRESHOLD" | jq -e 'numbers' >/dev/null 2>&1 || die "--threshold must be a number"

[ -f "$OVERRIDES" ] || exit 0
jq -e . "$OVERRIDES" >/dev/null 2>&1 || die "malformed JSON in $OVERRIDES"
# The shape every later query assumes. Bootstrap reports the same two problems
# from its own validation of this file; refusing here keeps a standalone run from
# turning a malformed file into an empty, healthy-looking report.
jq -e 'type == "object" and (to_entries | map(.value | type == "object") | all)' "$OVERRIDES" >/dev/null 2>&1 \
  || die "each harness entry in $OVERRIDES must be an object"

# Structural validation of the quota blocks only. Every other axis of this file
# belongs to fm-spawn.sh and bootstrap; a quota block is invalid config rather
# than a runtime read failure, so it exits 2 instead of degrading quietly.
config_error=$(jq -r '
  def quota_error($where; $q):
    if ($q | type) != "object" then "quota must be an object (" + $where + ")"
    elif (($q.command? | type) != "string") or (($q.command | length) == 0) then
      "quota needs a non-empty command (" + $where + ")"
    elif (($q.key? | type) != "string") or (($q.key | length) == 0) then
      "quota needs a non-empty key (" + $where + ")"
    elif ($q | has("args")) and (($q.args | type) != "array") then
      "quota args must be an array of strings (" + $where + ")"
    elif ($q | has("args")) and (($q.args | map(type == "string") | all) | not) then
      "quota args must be an array of strings (" + $where + ")"
    elif ($q | has("args")) and ($q.args | map(test("\n")) | any) then
      "quota args must not contain a newline (" + $where + ")"
    else empty
    end;
  [ to_entries[]
    | .key as $h
    | (if (.value.variants | type) == "object" and ((.value.variants | length) > 0)
       then (if (.value | has("quota"))
             then ["quota must be declared on each variant, not on " + $h + ", which declares variants"]
             else [] end)
         + [ .value.variants | to_entries[] | select(.value | has("quota"))
             | quota_error($h + "." + .key; .value.quota) ]
       else [ select(.value | has("quota")) | quota_error($h; .value.quota) ]
       end)
  ] | flatten | first // empty
' "$OVERRIDES" 2>/dev/null || true)
[ -z "$config_error" ] || die "$config_error"
[ "$VALIDATE_ONLY" -eq 0 ] || exit 0

# Every declared launch identity, whether or not it declares a quota source. The
# ones without a source are still switch candidates, reported with an unknown
# balance rather than dropped.
catalog=$(jq -c '
  [ to_entries[]
    | .key as $h
    | if (.value.variants | type) == "object" and ((.value.variants | length) > 0)
      then (.value.variants | to_entries[]
            | {lane: ($h + "." + .key), harness: $h, variant: .key, quota: (.value.quota? // null)})
      else {lane: $h, harness: $h, variant: null, quota: (.value.quota? // null)}
      end
  ]
' "$OVERRIDES")

sources=$(printf '%s\n' "$catalog" | jq -c '[.[] | select(.quota != null)]')
source_count=$(printf '%s\n' "$sources" | jq 'length')

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-alert.XXXXXX") || die "cannot create a temp directory"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

: >"$TMPD/readings.jsonl"

# Bounded run of one quota command. macOS ships no timeout(1), so the fallback is
# a plain watchdog around the direct child: a quota source is a short read-only
# fetch, not a process tree, so terminating that child is enough.
run_bounded() {  # <out-file> <cmd> [args...]
  local out=$1 pid ticks waited status
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" "$@" >"$out" 2>/dev/null
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$TIMEOUT" "$@" >"$out" 2>/dev/null
    return $?
  fi
  "$@" >"$out" 2>/dev/null &
  pid=$!
  ticks=$(printf '%s' "$TIMEOUT" | awk '{printf "%d", $1 * 10}')
  [ "$ticks" -gt 0 ] 2>/dev/null || ticks=1
  waited=0
  while [ "$waited" -lt "$ticks" ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null
    sleep 0.2
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 124
  fi
  wait "$pid"
  status=$?
  return "$status"
}

# Two identities may read the same source (one command listing every lane), so
# each distinct command+args runs once. bash 3.2 has no associative arrays; the
# cache is two parallel indexed arrays scanned linearly, which is right-sized for
# the handful of sources a home declares.
cache_sig=()
cache_slot=()

# Fetch one source into $TMPD/<slot>.out and record its outcome in
# $TMPD/<slot>.status ("ok" or a human reason). Sets FETCH_SLOT rather than
# printing, because a command substitution would run the cache updates in a
# subshell and every lane would re-fetch.
FETCH_SLOT=
fetch_source() {  # <command> <args-json>
  local cmd=$1 args_json=$2 sig slot arg status i
  local -a argv=()
  sig="$cmd"$'\x1f'"$args_json"
  i=0
  while [ "$i" -lt "${#cache_sig[@]}" ]; do
    if [ "${cache_sig[$i]}" = "$sig" ]; then
      FETCH_SLOT=${cache_slot[$i]}
      return 0
    fi
    i=$((i + 1))
  done
  slot="src$((${#cache_sig[@]} + 1))"
  cache_sig+=("$sig")
  cache_slot+=("$slot")
  FETCH_SLOT=$slot
  : >"$TMPD/$slot.out"
  if ! command -v "$cmd" >/dev/null 2>&1 && [ ! -x "$cmd" ]; then
    printf '%s\n' "quota command not found: $cmd" >"$TMPD/$slot.status"
    return 0
  fi
  while IFS= read -r arg; do
    argv+=("$arg")
  done < <(printf '%s' "$args_json" | jq -r '.[]?')
  # Stderr is dropped here, not inside run_bounded: killing a timed-out child
  # makes the shell itself announce "Terminated" when it reaps the job, and that
  # notice would otherwise land in the caller's output as a fake error.
  run_bounded "$TMPD/$slot.out" "$cmd" ${argv[@]+"${argv[@]}"} 2>/dev/null
  status=$?
  if [ "$status" -eq 124 ]; then
    printf '%s\n' "quota command timed out after ${TIMEOUT}s: $cmd" >"$TMPD/$slot.status"
  elif [ "$status" -ne 0 ]; then
    printf '%s\n' "quota command exited $status: $cmd" >"$TMPD/$slot.status"
  elif ! jq -e . "$TMPD/$slot.out" >/dev/null 2>&1; then
    printf '%s\n' "quota command did not print JSON: $cmd" >"$TMPD/$slot.status"
  else
    printf '%s\n' ok >"$TMPD/$slot.status"
  fi
}

# The shared jq prelude: entry selection, identity normalization, and the
# remaining-percent ladder documented in this script's header.
# shellcheck disable=SC2016  # single quotes are deliberate: jq expands its own $variables.
JQ_LIB='
  # round to one decimal without jq/1.6-only round/0: remaining is clamped to
  # 0..100, so a nonnegative +0.5|floor is exact and works on the older jq CI
  # ships.
  def round1: (. * 10 + 0.5 | floor) / 10;
  def norm: tostring | ascii_downcase | gsub("[^a-z0-9]"; "");
  def id_fields: ["key", "id", "label", "name", "slug", "suffix"];
  def entries:
    if type == "array" then (if (map(type == "object") | all) then . else null end)
    elif type == "object" then
      ([to_entries[] | select((.value | type) == "array") | .value]) as $arrays
      | if ($arrays | length) != 1 then null
        elif ($arrays[0] | map(type == "object") | all) then $arrays[0]
        else null
        end
    else null
    end;
  def matches($key): . as $e | any(id_fields[]; ($e[.]? // null) != null and (($e[.] | norm) == ($key | norm)));
  def identity: . as $e | first((["label", "id", "key", "slug", "name", "suffix"][] | $e[.]? | select(type == "string" and length > 0))) // "unnamed";
  def amount: (if (.cost | type) == "number" then .cost elif (.used | type) == "number" then .used elif (.spend | type) == "number" then .spend else null end);
  def remaining:
    (if (.remain_pct | type) == "number" then .remain_pct
     elif (.remaining_pct | type) == "number" then .remaining_pct
     elif (.percentRemaining | type) == "number" then .percentRemaining
     elif (.used_pct | type) == "number" then (100 - .used_pct)
     elif (.percentUsed | type) == "number" then (100 - .percentUsed)
     elif ((.limit | type) == "number") and (.limit > 0) and (amount != null) then
       (100 * (.limit - amount) / .limit)
     else null
     end)
    | if . == null then null elif . < 0 then 0 elif . > 100 then 100 else . end;
'

i=0
while [ "$i" -lt "$source_count" ]; do
  lane_json=$(printf '%s\n' "$sources" | jq -c --argjson i "$i" '.[$i]')
  i=$((i + 1))
  cmd=$(printf '%s\n' "$lane_json" | jq -r '.quota.command')
  args_json=$(printf '%s\n' "$lane_json" | jq -c '.quota.args // []')
  fetch_source "$cmd" "$args_json"
  slot=$FETCH_SLOT
  src_status=$(cat "$TMPD/$slot.status" 2>/dev/null || echo "quota command produced no result")
  printf '%s\n' "$lane_json" | jq -c \
    --arg slot "$slot" \
    --arg src_status "$src_status" \
    --slurpfile raw <(if [ "$src_status" = ok ]; then cat "$TMPD/$slot.out"; else echo null; fi) \
    "$JQ_LIB"'
    . as $lane
    | .quota.key as $key
    | {lane: $lane.lane, harness: $lane.harness, variant: $lane.variant,
       command: $lane.quota.command, key: $key, slot: $slot}
    + (if $src_status != "ok" then {status: "unreadable", reason: $src_status}
       else
         ($raw[0] | entries) as $entries
         | if $entries == null then {status: "unreadable", reason: "quota JSON has no single list of entries"}
           else ($entries | map(select(matches($key)))) as $hits
           | if ($hits | length) == 0 then {status: "unreadable", reason: ("no entry matches key \"" + $key + "\"")}
             elif ($hits | length) > 1 then {status: "unreadable", reason: ("key \"" + $key + "\" matches " + ($hits | length | tostring) + " entries")}
             else ($hits[0] | remaining) as $rem
             | if $rem == null then {status: "unreadable", reason: ("entry for \"" + $key + "\" carries no usable remaining, used, or limit numbers")}
               else {status: "read", remaining_pct: ($rem | round1),
                     cost: ($hits[0] | amount), limit: ($hits[0].limit? // null)}
               end
             end
           end
         end)
  ' >>"$TMPD/readings.jsonl"
done

# Entries a read source reports that no declared identity claims: a lane that is
# really being billed but that firstmate cannot select, because nothing in
# config/harness-overrides.json defines how to launch it.
: >"$TMPD/unclaimed.jsonl"
i=0
while [ "$i" -lt "${#cache_slot[@]}" ]; do
  slot=${cache_slot[$i]}
  i=$((i + 1))
  [ "$(cat "$TMPD/$slot.status" 2>/dev/null)" = ok ] || continue
  keys=$(jq -sc --arg slot "$slot" '[.[] | select(.slot == $slot) | .key]' "$TMPD/readings.jsonl")
  cmd=$(jq -rs --arg slot "$slot" 'map(select(.slot == $slot)) | .[0].command // ""' "$TMPD/readings.jsonl")
  jq -c --argjson keys "$keys" --arg cmd "$cmd" "$JQ_LIB"'
    (entries // []) as $entries
    | $entries
    | map(select(. as $e | (any($keys[]; . as $k | $e | matches($k))) | not))
    | map({command: $cmd, identity: identity, remaining_pct: (remaining | if . == null then null else round1 end)})
    | .[]
  ' "$TMPD/$slot.out" >>"$TMPD/unclaimed.jsonl" 2>/dev/null || true
done

[ -f "$DISPATCH" ] && jq -e . "$DISPATCH" >/dev/null 2>&1 || DISPATCH=/dev/null

render=$(jq -n \
  --slurpfile readings "$TMPD/readings.jsonl" \
  --slurpfile unclaimed "$TMPD/unclaimed.jsonl" \
  --slurpfile dispatch "$DISPATCH" \
  --argjson catalog "$catalog" \
  --argjson threshold "$THRESHOLD" '
  def profiles($d):
    [ ($d.default? | if type == "array" then .[] elif type == "object" then . else empty end) ]
    + [ ($d.rules // [])[]? | .use? | if type == "array" then .[] elif type == "object" then . else empty end ];
  ($dispatch[0] // {}) as $d
  | profiles($d) as $profiles
  | ($readings | map({key: .lane, value: .}) | from_entries) as $by_lane
  | {
      threshold: $threshold,
      lanes: [ $catalog[]
        | .lane as $lane
        | . as $c
        | ($by_lane[$lane] // null) as $r
        | {lane: $lane, harness: $c.harness, variant: $c.variant,
           status: (if $r == null then "undeclared"
                    elif $r.status != "read" then "unreadable"
                    elif ($r.remaining_pct <= $threshold) then "low"
                    else "ok" end),
           remaining_pct: ($r.remaining_pct? // null),
           cost: ($r.cost? // null), limit: ($r.limit? // null),
           reason: ($r.reason? // null),
           model: (first($profiles[]
                     | select(.harness == $c.harness and (.launch? // null) == $c.variant)
                     | .model?) // first($profiles[]
                     | select(.harness == $c.harness and (.launch? // null) == null)
                     | .model?) // null),
           effort: (first($profiles[]
                      | select(.harness == $c.harness and (.launch? // null) == $c.variant)
                      | .effort?) // first($profiles[]
                      | select(.harness == $c.harness and (.launch? // null) == null)
                      | .effort?) // null)}
      ],
      unclaimed: $unclaimed
    }
')

if [ "$AS_JSON" -eq 1 ]; then
  printf '%s\n' "$render" | jq .
  exit 0
fi

printf '%s\n' "$render" | jq -r --argjson all "$SHOW_ALL" '
  def pct($v): if $v == null then "unknown" else (($v | tostring) + "%") end;
  def spend($l): if ($l.cost != null and $l.limit != null) then " spend=" + ($l.cost | tostring) + "/" + ($l.limit | tostring) else "" end;
  def profile($l): " harness=" + $l.harness
    + (if $l.model != null then " model=" + $l.model else "" end)
    + (if $l.effort != null then " effort=" + $l.effort else "" end);
  . as $root
  | ([ $root.lanes[] | select(.status == "low")
      | ("QUOTA_LOW: " + .lane + " remaining=" + pct(.remaining_pct)
         + " threshold=" + ($root.threshold | tostring) + "%" + spend(.))
      , ( . as $low
        | $root.lanes[]
        | select(.lane != $low.lane) | select(.status != "low")
        | "QUOTA_ALT: " + $low.lane + " -> " + .lane + profile(.)
          + " remaining=" + pct(.remaining_pct))
    ]
    + [ $root.lanes[] | select(.status == "unreadable")
        | "QUOTA_UNREADABLE: " + .lane + " " + (.reason // "unknown reason") ]
    + [ $root.unclaimed[]
        | "QUOTA_UNCLAIMED: " + .command + " " + .identity + " remaining=" + pct(.remaining_pct) ]
    + (if $all == 1 then
        [ $root.lanes[] | select(.status == "ok") | "QUOTA_OK: " + .lane + " remaining=" + pct(.remaining_pct) ]
        + [ $root.lanes[] | select(.status == "undeclared") | "QUOTA_OK: " + .lane + " remaining=unknown (no quota source declared)" ]
       else [] end))
  | .[]
'
