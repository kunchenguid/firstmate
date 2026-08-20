#!/usr/bin/env bash
# fm-agy-quota-lib.sh - the EVIDENCE the agy model ladder decides on: how a
# quota reading is obtained, recorded, aged out, and how many launches are
# already in flight against it.
# Usage: . bin/fm-agy-quota-lib.sh
# bin/fm-agy-ladder-lib.sh owns the policy that consumes all of this; this file
# owns nothing but the evidence and never decides whether a launch may proceed.
#
# WHERE A READING COMES FROM. Two sources, in order of authority:
#
#   1. THE INTAKE POLL (fm_agy_quota_poll). `agy --print /quota --output-format
#      json` answers the account's live quota for EVERY model without running a
#      turn - verified against agy 1.1.15, which reports "num_turns":0 and
#      "total_tokens":0 on that call - so reading the floor costs none of the
#      budget the floor exists to protect. This is the primary source, and
#      bin/fm-agy-ladder-lib.sh runs it at dispatch time.
#   2. THE PANE FOOTER (fm_agy_quota_observe). bin/fm-watch.sh records the
#      footer of a live agy pane as it redraws. Opportunistic: it refreshes
#      only while an agy pane exists and happens to redraw, so it can never be
#      the only source.
#
# Before the intake poll existed, source 2 was the only writer. A home with no
# agy pane running therefore refreshed nothing at all, and a single reading
# authorised every launch until its own reset window rolled over - hours, during
# which quota only falls. That is what the max-age ceiling below closes.
#
# THE FRESHNESS RULE, WHICH IS TWO RULES. A reading reads back as `unknown`
# when EITHER bound is crossed:
#
#   - FM_AGY_QUOTA_MAX_AGE, an absolute ceiling in seconds. This is the
#     load-bearing one. Quota falls monotonically inside a reset window, so a
#     reading taken early in that window systematically OVERSTATES what is left
#     for the rest of it. The ceiling is what makes one reading authorise
#     minutes instead of hours.
#   - The reading's own reported reset window, when it is parseable. A window
#     that has rolled over describes quota that no longer exists.
#
# A reset window that does NOT parse no longer discards the reading. The window
# is a refinement; the ceiling is the guarantee, and throwing away a valid
# percentage because its window was written "0m" or "soon" was a silent
# fail-open at exactly the moment the percentage mattered.
#
# FAILING SOFT IS DELIBERATE. Every path here degrades to "no reading" rather
# than to a wrong reading, and never to an error that stops a spawn. The captain
# ruled on 2026-08-19 that missing evidence must not stall the fleet: "we should
# not allow the fleet to stall but there has to be a way to quickly poll the
# quota before going in and launching a crewmate". So the answer to thin
# evidence is this file's poll, not a refusal in bin/fm-agy-ladder-lib.sh.

# Resolve this library's own directory so it can pull in the agy binary and
# bounded-subprocess helpers whether it was sourced by a bin/ script or directly
# by a test.
_FM_AGY_QUOTA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_AGY_QUOTA_LIB_DIR="."
if ! declare -f fm_agy_resolve_binary >/dev/null 2>&1; then
  # shellcheck source=bin/fm-agy-lib.sh
  . "$_FM_AGY_QUOTA_LIB_DIR/fm-agy-lib.sh"
fi

# FM_AGY_QUOTA_MAX_AGE: seconds after which a recorded reading is no longer
# evidence, whatever its own reset window says. Minutes, not hours: the intake
# poll refreshes on demand, so a short ceiling costs a 3-second subprocess
# rather than a wedged fleet. Set to 0 to disable the ceiling, which restores
# the window-only rule and is never what a dispatch path wants.
FM_AGY_QUOTA_MAX_AGE=${FM_AGY_QUOTA_MAX_AGE:-300}

# FM_AGY_QUOTA_POLL: set to `off` to skip the live intake poll entirely and
# decide on whatever is already recorded. Tests that pin the decision matrix
# against hand-written readings set it; nothing in production should.
FM_AGY_QUOTA_POLL=${FM_AGY_QUOTA_POLL:-on}

# FM_AGY_INFLIGHT_TTL: how long a recorded launch counts as unreflected in a
# reading. A launch older than this has had its consumption counted by the
# account's own quota service, so any reading fresh enough to pass the ceiling
# above already includes it; counting it twice would reserve headroom that is
# not at risk. Defaulting it to the ceiling keeps the two definitions of
# "recent enough to matter" from drifting apart.
FM_AGY_INFLIGHT_TTL=${FM_AGY_INFLIGHT_TTL:-$FM_AGY_QUOTA_MAX_AGE}

# fm_agy_strip_ansi: drop ANSI escape sequences from stdin.
# The model name is the KEY a reading is stored under, so an escape sequence
# captured with it does not merely make the text ugly - it writes the reading
# under a key no reader will ever look up, and the floor silently loses the
# evidence it was about to enforce. Stripping happens before anything is
# extracted, so no key can ever carry one.
fm_agy_strip_ansi() {
  LC_ALL=C sed -E $'s/\033\\[[0-9;?]*[ -/]*[@-~]//g; s/\033[@-Z\\\\-_]//g; s/\r//g'
}

# fm_agy_is_number: 0 when the argument is a bare decimal percentage.
# A footer can render a percentage agy could not compute ("--", "n/a"). That is
# an absence of evidence, not a reading of zero, and must not be recorded as
# one: zero is the most consequential number on this scale.
fm_agy_is_number() {  # <value>
  case "$1" in
    ''|*[!0-9.]*) return 1 ;;
    .|*.*.*) return 1 ;;
  esac
  return 0
}

# fm_agy_quota_key: the on-disk key for a model's reading.
fm_agy_quota_key() {  # <model>
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 -q
  else
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  fi
}

# fm_agy_parse_reset_time: converts '4h 24m', '1d 2h', etc to seconds. Returns 0
# for anything it cannot read, which callers must treat as "no window stated"
# rather than as "the window has elapsed".
fm_agy_parse_reset_time() {
  local ts="$1"
  local total=0
  local d=0 h=0 m=0 s=0

  case "$ts" in
    *d*) d="${ts%%d*}"; d="${d##* }"; fm_agy_is_number "$d" && total=$((total + ${d%%.*} * 86400)) ;;
  esac
  case "$ts" in
    *h*) h="${ts%%h*}"; h="${h##* }"; fm_agy_is_number "$h" && total=$((total + ${h%%.*} * 3600)) ;;
  esac
  case "$ts" in
    *m*) m="${ts%%m*}"; m="${m##* }"; fm_agy_is_number "$m" && total=$((total + ${m%%.*} * 60)) ;;
  esac
  case "$ts" in
    *s*) s="${ts%%s*}"; s="${s##* }"; fm_agy_is_number "$s" && total=$((total + ${s%%.*})) ;;
  esac
  echo "$total"
}

# fm_agy_quota_record: write one reading. The single writer, so observe and poll
# cannot drift on the key, the field order, or the timestamp.
fm_agy_quota_record() {  # <model> <percent> <reset-window> <state_dir> [<now>]
  local model=$1 percent=$2 reset=$3 state_dir=$4 now=${5:-}
  [ -n "$model" ] || return 1
  fm_agy_is_number "$percent" || return 1
  [ -d "$state_dir" ] || return 1
  [ -n "$now" ] || now=$(date +%s)
  printf '%s|%s|%s|%s\n' "$model" "$percent" "$reset" "$now" \
    > "$state_dir/.agy-quota-$(fm_agy_quota_key "$model")"
}

# fm_agy_footer_fields: the ONE parse of an agy pane footer, printing
# "<model>\t<quota-percent>\t<reset-window>" for the last footer line in
# <text>, or nothing at all.
#
# Format: Gemini 3.1 Pro (High) | ctx: 10.5% | quota: 94.7% (4h 24m)
#
# One extraction for all three fields, so a partial match can never record a
# model against another line's percentage. The reset window is optional: the
# percentage is the evidence, and the ceiling in fm_agy_quota_read bounds it
# whether or not a window came with it.
#
# The separators are matched with tolerance for surrounding whitespace rather
# than as the exact literals " | ctx: " and " | quota: ". A renderer that pads a
# column differently is a cosmetic change to agy; it must not silently stop the
# floor being enforced, which is what an exact-literal match made it do.
#
# This is a SINGLE owner on purpose: bin/fm-agy-descent-lib.sh reads the same
# footer to confirm which model a running worker is actually on, and a second
# copy of this expression would drift the moment only one was updated.
fm_agy_footer_fields() {  # <text>
  local line
  line=$(printf '%s\n' "$1" | fm_agy_strip_ansi | LC_ALL=C grep -F 'quota:' | tail -1)
  [ -n "$line" ] || return 1
  printf '%s\n' "$line" | LC_ALL=C sed -nE \
    's/^[[:space:]]*(.*[^[:space:]])[[:space:]]*\|[[:space:]]*ctx:[^|]*\|[[:space:]]*quota:[[:space:]]*([0-9]+(\.[0-9]+)?)[[:space:]]*%?[[:space:]]*(\(([^)]*)\))?.*$/\1\t\2\t\5/p'
}

# fm_agy_footer_model: just the model name the footer names, or nothing.
fm_agy_footer_model() {  # <text>
  local parsed
  parsed=$(fm_agy_footer_fields "$1") || return 1
  [ -n "$parsed" ] || return 1
  printf '%s' "${parsed%%	*}"
}

# fm_agy_quota_observe: record the quota an agy pane footer reports.
# fm_agy_footer_fields above owns the parse.
# The optional <now> stamps the reading instead of the wall clock, so a caller
# that must reason about a reading's exact age - a test pinning the max-age
# ceiling - can do so without racing the second hand.
fm_agy_quota_observe() {  # <text> <state_dir> [<now>]
  local text="$1" state_dir="$2" now="${3:-}" parsed model quota reset_time

  parsed=$(fm_agy_footer_fields "$text") || return 0
  [ -n "$parsed" ] || return 0

  model=${parsed%%	*}
  parsed=${parsed#*	}
  quota=${parsed%%	*}
  reset_time=${parsed#*	}

  fm_agy_quota_record "$model" "$quota" "$reset_time" "$state_dir" "$now" || return 0
}

# fm_agy_quota_read: the last known value for a model together with its age, or
# `unknown`. Both freshness bounds documented at the top of this file are
# applied here; the ceiling is the one that matters.
fm_agy_quota_read() {  # <model> <state_dir> [<now>]
  local model="$1" state_dir="$2" now_override="${3:-}"
  local file line file_model rest quota reset_time_str obs_ts now age reset_seconds

  file="$state_dir/.agy-quota-$(fm_agy_quota_key "$model")"
  if [ ! -f "$file" ]; then
    echo "unknown"
    return 0
  fi

  line=$(cat "$file" 2>/dev/null || true)
  if [ -z "$line" ]; then
    echo "unknown"
    return 0
  fi

  file_model="${line%%|*}"
  rest="${line#*|}"
  quota="${rest%%|*}"
  rest="${rest#*|}"
  reset_time_str="${rest%%|*}"
  obs_ts="${rest#*|}"
  quota="${quota%%%*}"

  # A reset window is no longer required. A record whose model, percentage, or
  # observation time is missing or unreadable still establishes nothing.
  if [ "$file_model" != "$model" ] || ! fm_agy_is_number "$quota" || ! fm_agy_is_number "$obs_ts"; then
    echo "unknown"
    return 0
  fi

  if [ -n "$now_override" ]; then
    now="$now_override"
  else
    now=$(date +%s)
  fi

  age=$((now - obs_ts))
  if [ "$age" -lt 0 ]; then
    age=0
  fi

  # The ceiling. Independent of the window, and checked first because it is the
  # bound that actually holds the floor up.
  if [ "$FM_AGY_QUOTA_MAX_AGE" -gt 0 ] && [ "$age" -ge "$FM_AGY_QUOTA_MAX_AGE" ]; then
    echo "unknown"
    return 0
  fi

  reset_seconds=$(fm_agy_parse_reset_time "$reset_time_str")
  if [ "$reset_seconds" -gt 0 ] && [ "$age" -ge "$reset_seconds" ]; then
    echo "unknown"
    return 0
  fi

  echo "$quota $age"
}

# fm_agy_reset_window: an absolute RFC3339 reset instant rendered as the
# "<n>h <n>m" window the recorded format speaks. Prints nothing when the instant
# cannot be read, which is not a failure: the ceiling still bounds the reading.
fm_agy_reset_window() {  # <rfc3339> [<now>]
  local stamp=$1 now=${2:-} epoch remain
  [ -n "$stamp" ] || return 0
  [ -n "$now" ] || now=$(date +%s)
  epoch=$(date -u -d "$stamp" +%s 2>/dev/null) \
    || epoch=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$stamp" +%s 2>/dev/null) \
    || return 0
  fm_agy_is_number "$epoch" || return 0
  remain=$((epoch - now))
  [ "$remain" -gt 0 ] || return 0
  printf '%dh %dm' $((remain / 3600)) $(((remain % 3600) / 60))
}

# fm_agy_quota_poll: ask agy for the account's live quota and record a reading
# for every model it reports. Prints nothing; the readings ARE the result.
#
#   0  at least one reading was recorded
#   1  no reading was obtained, for any reason
#
# Returning 1 is an ordinary outcome, not an error to escalate: agy may be
# absent, jq may be absent, the account may have no quota summary, or the call
# may time out. Each of those leaves whatever was already recorded in place and
# lets bin/fm-agy-ladder-lib.sh decide on that, which is the captain's no-stall
# ruling expressed in code.
fm_agy_quota_poll() {  # <state_dir> [<now>]
  local state_dir=$1 now=${2:-} bin out rows name fraction reset percent window recorded=1

  [ "$FM_AGY_QUOTA_POLL" != off ] || return 1
  [ -d "$state_dir" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  bin=$(fm_agy_resolve_binary 2>/dev/null) || return 1
  [ -n "$now" ] || now=$(date +%s)

  # `/quota` is answered locally by agy's own command runner against the quota
  # service. It runs no turn, so this costs no quota - which is the entire
  # reason the poll can sit on the dispatch path at all.
  out=$(fm_agy_bounded_output "$bin" --print /quota --output-format json) || return 1
  [ -n "$out" ] || return 1

  # remaining_fraction is the precise figure; the human-readable rows in
  # .response round to whole percents and would blur exactly the last point
  # above the floor.
  rows=$(printf '%s' "$out" | jq -r '
    .command.data.groups[]?.buckets[]?
    | select(.name != null and .remaining_fraction != null)
    | [.name, .remaining_fraction, (.reset_time // "")]
    | @tsv' 2>/dev/null) || return 1
  [ -n "$rows" ] || return 1

  while IFS=$'\t' read -r name fraction reset; do
    [ -n "$name" ] || continue
    # One decimal place, the same precision the pane footer reports, so a
    # reading's provenance never changes how it compares against a floor.
    percent=$(awk -v f="$fraction" 'BEGIN { printf "%.1f", f * 100 }' 2>/dev/null)
    fm_agy_is_number "$percent" || continue
    window=$(fm_agy_reset_window "$reset" "$now")
    if fm_agy_quota_record "$name" "$percent" "$window" "$state_dir" "$now"; then
      recorded=0
    fi
  done <<EOF
$rows
EOF

  return "$recorded"
}

# --- launches already in flight ---------------------------------------------
#
# A reading describes quota as of the moment it was taken. Launches made since
# then are spending against it and are invisible to it, so at 26% remaining an
# unbounded burst of concurrent workers can all pass a 25% floor and drive the
# true figure well under it before anything is re-read. The ledger below is how
# many launches a rung owes but no reading has yet seen.
#
# One append-only file per home, pruned on read. Appends of a single short line
# are atomic, and bin/fm-spawn.sh serializes agy dispatch behind its spawn
# locks, so the prune's read-rewrite cannot lose a concurrent record in
# practice; if it ever did, the loss is one reservation, which under-reserves by
# the margin rather than over-reserving, and the next poll corrects it.

fm_agy_inflight_path() {  # <state_dir>
  printf '%s/.agy-inflight' "$1"
}

# fm_agy_inflight_record: note that a launch on <rung> has been authorized.
fm_agy_inflight_record() {  # <rung> <state_dir> [<now>]
  local rung=$1 state_dir=$2 now=${3:-}
  [ -n "$rung" ] || return 1
  [ -d "$state_dir" ] || return 1
  [ -n "$now" ] || now=$(date +%s)
  printf '%s %s\n' "$now" "$rung" >> "$(fm_agy_inflight_path "$state_dir")"
}

# fm_agy_inflight_count: how many launches on <rung> are still unreflected in a
# current reading. Prints a count, always. Expired entries are dropped from the
# ledger as a side effect so it cannot grow without bound.
fm_agy_inflight_count() {  # <rung> <state_dir> [<now>]
  local rung=$1 state_dir=$2 now=${3:-} file ts entry count=0 kept tmp expired=0

  file=$(fm_agy_inflight_path "$state_dir")
  if [ ! -f "$file" ]; then
    printf '0'
    return 0
  fi
  [ -n "$now" ] || now=$(date +%s)

  kept=
  while read -r ts entry; do
    if ! fm_agy_is_number "$ts" || [ $((now - ts)) -ge "$FM_AGY_INFLIGHT_TTL" ]; then
      expired=1
      continue
    fi
    kept="$kept$ts $entry
"
    [ "$entry" = "$rung" ] && count=$((count + 1))
  done < "$file"

  if [ "$expired" -eq 1 ]; then
    tmp="$file.tmp.$$"
    if printf '%s' "$kept" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
      rm -f "$tmp" 2>/dev/null
    fi
  fi

  printf '%s' "$count"
}
