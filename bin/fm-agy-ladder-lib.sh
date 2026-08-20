#!/usr/bin/env bash
# fm-agy-ladder-lib.sh - the agy model ladder, enforced at the dispatch layer.
# Usage: . bin/fm-agy-ladder-lib.sh
# Sourced by bin/fm-spawn.sh. This file has no side effects on source beyond
# pulling in its own quota-reading dependency.
#
# THE POLICY. The captain's standing rule for agy dispatch is a fixed three-rung
# ladder run by STRICT EXHAUSTION, not load balancing:
#
#   rung 1  Claude Opus 4.6 (Thinking)   claude-opus-4-6-thinking
#   rung 2  Gemini 3.1 Pro (High)        gemini-3.1-pro-high
#   rung 3  Gemini 3.7 Flash (High)      gemini-3.7-flash-high
#
# Work runs on the highest non-exhausted rung. A lower rung is valid only once
# EVERY rung above it is exhausted, and work climbs straight back the moment a
# rung above resets. Rung 1's exhaustion floor is 25 percent remaining, because
# that last quarter of Opus 4.6 is reserved for the captain on explicit request
# and automatic dispatch never touches it. Rungs 2 and 3 exhaust to 0.
#
# This file gates LAUNCHES. bin/fm-agy-descent-lib.sh applies the same rule, in
# both directions, to a worker already running, by putting each candidate rung
# to the gate below rather than keeping rungs or floors of its own.
#
# The authoritative statement of the policy is the captain-private
# config/crew-dispatch.json "_ladder_note"; this file is its enforcement, not a
# second copy of it. The rung order and the floors are restated here because a
# gate cannot consult a gitignored file that a fresh home may not have.
#
# WHY A GATE AND NOT PROSE. The ladder used to live only in instructions, so
# every dispatch depended on an agent remembering it. The captain asked for it
# to be enforced in tooling instead (2026-08-16: "i don't think its currently
# strictly enforced so it is something i want you to enforce"). This library is
# the decision; bin/fm-spawn.sh is where it is applied, which is the single
# path every crewmate and scout launch already takes, so an ordinary dispatch
# cannot route around it.
#
# THE EVIDENCE. quota-axi does not model agy at all, so agy answers for itself.
# bin/fm-agy-quota-lib.sh owns every part of that: the live intake poll this
# gate runs at dispatch time, the opportunistic pane-footer reading
# bin/fm-watch.sh records, the format both write, and the freshness rule that
# ages a reading out. The percentage is the SESSION-WINDOW quota, which is the
# only thing that governs a rung; a transient per-minute or per-request throttle
# is not exhaustion and never appears here.
#
# WHY THE POLL IS PART OF THE GATE. One `agy --print /quota` call answers EVERY
# model at once, and this gate needs exactly that, because it makes two
# decisions and they lean on different rungs:
#
#   - Is the requested rung above its own floor? That needs the requested rung.
#   - Is it the HIGHEST available rung? That needs every rung above it.
#
# Before the poll, evidence refreshed only when a live agy pane happened to
# redraw, so a home with no agy pane running had none. That did not merely fail
# the floor open. It ALSO blocked every descent, because a descent is refused
# unless the rungs above are proven exhausted - so rung 1 launched unchecked
# below its floor while rung 2 was refused for lack of proof, and dispatch
# escaped the ladder upward to a more expensive model outside it entirely. The
# fix for both halves is the same fresh reading, which is why the poll runs once
# here, ahead of both decisions, rather than beside either one.
#
# Readings are per-home, because state/ is. The quota itself is per-account, so
# a secondmate that has never drawn an agy pane of its own knows nothing about
# the rungs even while the primary home does. That resolves to rung 1 under the
# rule below, which is the right answer anyway: a home with no evidence starts
# at the top of the ladder rather than assuming somebody else spent it.
#
# THE ASYMMETRY, WHICH IS THE WHOLE DESIGN. Quota evidence can still be absent
# after the poll: agy may not be installed, jq may be missing, the call may time
# out, or the account may report no quota summary. The captain ruled on
# 2026-08-19 that this must not stop work - "we should not allow the fleet to
# stall" - so absence is never a refusal to launch at the top. Nor is it a
# licence to descend. Absence is resolved by direction of travel:
#
#   - Climbing or staying at the top needs no evidence. Rung 1 is the ladder's
#     first choice anyway, and no rung sits above it to exhaust. That is a rule
#     about STARTING there. Moving an already-running worker back UP is a
#     different move - it spends the reserve rather than merely declining to
#     descend - so bin/fm-agy-descent-lib.sh requires positive evidence for it,
#     plus hysteresis, and it reaches that decision by asking this gate about
#     each candidate rung rather than by keeping a floor of its own.
#   - DESCENDING needs positive evidence. A lower rung is refused unless every
#     rung above it has a current reading that proves it exhausted. Descending
#     is exactly the move the policy exists to constrain, so an unknown rung
#     above blocks it rather than excusing it.
#   - A rung's OWN floor refuses only on positive evidence. An unknown reading
#     for the requested rung is not proof it is spent, and treating it as such
#     would wedge the fleet for the same reason as above.
#
# WHEN THE POLL ITSELF IS UNAVAILABLE, that asymmetry is what the gate falls
# back to, and it says which of the two it did. Rung 1 still launches, so agy
# work never stalls; a descent is still refused, because nothing proved the rung
# above spent. The refusal names the failed live read rather than reporting a
# bare absence, so the reader can tell "never observed" from "could not reach
# agy just now" and reaches for FM_AGY_LADDER_OVERRIDE instead of quietly
# abandoning the ladder for a costlier model outside it.
#
# HEADROOM FOR LAUNCHES IN FLIGHT. A reading describes the account at the moment
# it was taken, so concurrent launches are invisible to it and a burst at 26%
# could all clear a 25% floor before any of them was counted. Each authorized
# launch is recorded, and FM_AGY_LADDER_INFLIGHT_MARGIN percentage points are
# reserved per launch still unreflected in the reading. The comparison is
# against that reserved figure, not the bare reading.
#
# OFF-LADDER MODELS. agy offers models the ladder does not name (Gemini 3.1 Pro
# (Low), Claude Sonnet 4.6, GPT-OSS 120B, and so on), and a launch with no
# --model at all lets agy pick its own. The ladder governs the three rungs; it
# does not silently extend to models the captain never ranked, so those launches
# are ALLOWED - but they are reported, because an unranked model is also the
# obvious way to end up outside the policy without noticing.
#
# THE OVERRIDE. FM_AGY_LADDER_OVERRIDE, set to a non-empty reason, turns any
# refusal into a launch and prints what it overrode. It is an environment
# variable rather than a flag deliberately: config/crew-dispatch.json profiles
# carry only harness, model, and effort, so a routine profile-driven dispatch
# has no way to express it, and reaching the captain's reserved last quarter of
# Opus 4.6 stays a deliberate act at the command line.

# Resolve this library's own directory so it can pull in the quota reader
# whether it was sourced by a bin/ script or directly by a test.
_FM_AGY_LADDER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_AGY_LADDER_LIB_DIR="."
if ! declare -f fm_agy_quota_read >/dev/null 2>&1; then
  # shellcheck source=bin/fm-agy-quota-lib.sh
  . "$_FM_AGY_LADDER_LIB_DIR/fm-agy-quota-lib.sh"
fi

# fm_agy_ladder_rung: the rung number a model sits on, or failure when the model
# is not on the ladder. BOTH spellings agy accepts are honoured - the kebab id
# and the display name - matching fm_agy_catalog_has_model's exact-match
# contract, so the gate and the catalogue check agree on what a model name is.
fm_agy_ladder_rung() {  # <model>
  case "$1" in
    'Claude Opus 4.6 (Thinking)'|claude-opus-4-6-thinking) printf '1' ;;
    'Gemini 3.1 Pro (High)'|gemini-3.1-pro-high) printf '2' ;;
    'Gemini 3.7 Flash (High)'|gemini-3.7-flash-high) printf '3' ;;
    *) return 1 ;;
  esac
}

# fm_agy_ladder_display: a rung's display name. This is the spelling the pane
# footer draws, so it is also the key bin/fm-agy-quota-lib.sh stores readings
# under; a lookup by kebab id would never find one.
fm_agy_ladder_display() {  # <rung>
  case "$1" in
    1) printf 'Claude Opus 4.6 (Thinking)' ;;
    2) printf 'Gemini 3.1 Pro (High)' ;;
    3) printf 'Gemini 3.7 Flash (High)' ;;
    *) return 1 ;;
  esac
}

# fm_agy_ladder_floor: the percent-remaining at or below which a rung counts as
# exhausted. Rung 1 stops at the captain's reserved quarter; the rest run dry.
fm_agy_ladder_floor() {  # <rung>
  case "$1" in
    1) printf '25' ;;
    2|3) printf '0' ;;
    *) return 1 ;;
  esac
}

# fm_agy_ladder_at_or_below: numeric comparison of two decimal percentages.
# awk rather than shell arithmetic because the footer reports one decimal place.
fm_agy_ladder_at_or_below() {  # <percent> <floor>
  awk -v p="$1" -v f="$2" 'BEGIN { exit !(p <= f) }'
}

# FM_AGY_LADDER_INFLIGHT_MARGIN: percentage points reserved for each authorized
# launch a current reading cannot have seen yet. One point is deliberately
# coarse: the figure it protects is a reserve, and reserving slightly too much
# costs a launch that can be made a moment later, while reserving too little
# costs the captain's quarter.
FM_AGY_LADDER_INFLIGHT_MARGIN=${FM_AGY_LADDER_INFLIGHT_MARGIN:-1}

# fm_agy_ladder_reserved: a rung's percentage minus the headroom owed to
# launches already in flight against it.
fm_agy_ladder_reserved() {  # <percent> <in-flight>
  awk -v p="$1" -v n="$2" -v m="$FM_AGY_LADDER_INFLIGHT_MARGIN" \
    'BEGIN { v = p - (n * m); printf "%.1f", (v < 0 ? 0 : v) }'
}

# fm_agy_ladder_state: what the current evidence says about one rung.
# Prints "<verdict> <percent> <in-flight>", where verdict is `exhausted` or
# `available`, or the bare word "unknown".
#
# The percentage printed is always the READING, so a caller reports the evidence
# it actually has; the verdict is decided on that reading MINUS the headroom
# owed to in-flight launches, which is the figure the account will really be at
# once they land. The in-flight count is printed too so a refusal can explain
# the gap between the two rather than appearing to contradict its own number.
#
# "unknown" covers a rung never observed, a reading past the max-age ceiling,
# and a reading whose own reset window has elapsed - bin/fm-agy-quota-lib.sh
# collapses all three, and it is right to: none of them says what is left now.
fm_agy_ladder_state() {  # <rung> <state-dir> [<now>]
  local rung=$1 state_dir=$2 now=${3:-}
  local display reading percent in_flight effective
  display=$(fm_agy_ladder_display "$rung") || return 1
  reading=$(fm_agy_quota_read "$display" "$state_dir" "$now")
  case "$reading" in
    unknown|'') printf 'unknown'; return 0 ;;
  esac
  percent=${reading%% *}
  in_flight=$(fm_agy_inflight_count "$rung" "$state_dir" "$now")
  effective=$(fm_agy_ladder_reserved "$percent" "$in_flight")
  if fm_agy_ladder_at_or_below "$effective" "$(fm_agy_ladder_floor "$rung")"; then
    printf 'exhausted %s %s' "$percent" "$in_flight"
  else
    printf 'available %s %s' "$percent" "$in_flight"
  fi
}

# fm_agy_ladder_inflight_clause: the " (... in flight ...)" fragment a message
# carries when headroom was reserved, and nothing at all when it was not, so the
# ordinary single-launch reason stays exactly as short as it was.
fm_agy_ladder_inflight_clause() {  # <percent> <in-flight>
  # Guarded rather than compared directly: a caller that reached here with a
  # non-numeric count must add no clause, never abort the reason mid-sentence.
  case "${2:-}" in
    ''|*[!0-9]*) return 0 ;;
    0) return 0 ;;
  esac
  printf ' (%s launch(es) already in flight reserve %s%%, leaving %s%%)' \
    "$2" "$(awk -v n="$2" -v m="$FM_AGY_LADDER_INFLIGHT_MARGIN" 'BEGIN { printf "%.1f", n * m }')" \
    "$(fm_agy_ladder_reserved "$1" "$2")"
}

# fm_agy_ladder_check: the decision, with no override applied. Always prints one
# line naming the rung and the evidence it acted on.
#   0  allow: the requested rung is the highest available one
#   1  refuse: the launch violates the ladder
#   2  allow, but the model is not on the ladder and is not governed by it
fm_agy_ladder_check() {  # <model> <state-dir> [<now>]
  local model=$1 state_dir=$2 now=${3:-}
  local rung above state percent in_flight floor display above_display unreachable=

  if [ -z "$model" ] || [ "$model" = default ]; then
    printf 'no model was requested, so agy chooses its own and the ladder cannot be applied to this launch'
    return 2
  fi
  if ! rung=$(fm_agy_ladder_rung "$model"); then
    printf 'model %s is not on the ladder (rung 1 %s, rung 2 %s, rung 3 %s), so strict exhaustion does not govern this launch' \
      "$model" "$(fm_agy_ladder_display 1)" "$(fm_agy_ladder_display 2)" "$(fm_agy_ladder_display 3)"
    return 2
  fi
  display=$(fm_agy_ladder_display "$rung")

  # Distinguish "never observed" from "asked agy just now and could not reach
  # it". Both leave the same absence behind, but only the second tells a reader
  # that retrying, or the override, is the move - rather than concluding the
  # ladder is unusable and leaving it for a model outside the policy.
  if [ "${FM_AGY_LADDER_POLL_STATUS:-}" = unavailable ]; then
    unreachable=' (a live quota read was attempted just now and did not answer)'
  fi

  # Descending: every rung above must be PROVEN exhausted. Absence of evidence
  # refuses here, because this is the move the policy constrains.
  above=1
  while [ "$above" -lt "$rung" ]; do
    state=$(fm_agy_ladder_state "$above" "$state_dir" "$now")
    above_display=$(fm_agy_ladder_display "$above")
    percent=${state#* }
    in_flight=${percent#* }
    percent=${percent%% *}
    case "$state" in
      exhausted*) ;;
      available*)
        printf 'rung %s (%s) still has %s%% remaining above its %s%% floor%s, so rung %s (%s) is not the highest available rung' \
          "$above" "$above_display" "$percent" "$(fm_agy_ladder_floor "$above")" \
          "$(fm_agy_ladder_inflight_clause "$percent" "$in_flight")" "$rung" "$display"
        return 1
        ;;
      *)
        printf 'rung %s (%s) has no current quota reading%s, so rung %s (%s) cannot be shown to be the highest available rung; run rung 1 first, or set FM_AGY_LADDER_OVERRIDE=<reason> rather than leaving the ladder for a model outside it' \
          "$above" "$above_display" "$unreachable" "$rung" "$display"
        return 1
        ;;
    esac
    above=$((above + 1))
  done

  # The requested rung's own floor. Refuses only on positive evidence.
  state=$(fm_agy_ladder_state "$rung" "$state_dir" "$now")
  floor=$(fm_agy_ladder_floor "$rung")
  percent=${state#* }
  in_flight=${percent#* }
  percent=${percent%% *}
  case "$state" in
    exhausted*)
      if [ "$rung" = 1 ]; then
        printf 'rung 1 (%s) is at %s%% remaining%s, at or below the %s%% floor reserved for the captain; automatic dispatch never takes that last quarter' \
          "$display" "$percent" "$(fm_agy_ladder_inflight_clause "$percent" "$in_flight")" "$floor"
      else
        printf 'rung %s (%s) is exhausted at %s%% remaining%s (floor %s%%), so it cannot take this launch' \
          "$rung" "$display" "$percent" "$(fm_agy_ladder_inflight_clause "$percent" "$in_flight")" "$floor"
      fi
      return 1
      ;;
    available*)
      printf 'rung %s (%s) has %s%% remaining above its %s%% floor%s and every rung above it is exhausted' \
        "$rung" "$display" "$percent" "$floor" "$(fm_agy_ladder_inflight_clause "$percent" "$in_flight")"
      ;;
    *)
      printf 'rung %s (%s) has no current quota reading%s; nothing shows it spent, and every rung above it is exhausted' \
        "$rung" "$display" "$unreachable"
      ;;
  esac
  return 0
}

# fm_agy_ladder_gate: fm_agy_ladder_check with the captain override applied and
# the output a caller should show. Prints nothing on an ordinary clean allow so
# routine dispatch stays quiet, and prints one line for everything a reader
# would want to know about: an off-ladder model, a used override, or a refusal.
#   0  launch may proceed
#   1  launch is refused; the printed line is the reason
fm_agy_ladder_gate() {  # <model> <state-dir> [<now>]
  local reason rc=0

  # Refresh the evidence before deciding on it, once, for every rung at a time.
  # Only for a model the ladder actually ranks: an off-ladder or unmodelled
  # launch is not governed by any floor, so it must not pay for a network call
  # while bin/fm-spawn.sh holds the spawn locks. A poll that cannot run leaves
  # whatever was recorded in place and is remembered, not raised: the gate still
  # decides, and says which fallback it decided on.
  FM_AGY_LADDER_POLL_STATUS=skipped
  if [ "${1:-}" != '' ] && [ "${1:-}" != default ] && fm_agy_ladder_rung "$1" >/dev/null 2>&1; then
    if [ "${FM_AGY_QUOTA_POLL:-on}" = off ]; then
      FM_AGY_LADDER_POLL_STATUS=off
    elif fm_agy_quota_poll "${2:-}" "${3:-}"; then
      FM_AGY_LADDER_POLL_STATUS=ok
    else
      FM_AGY_LADDER_POLL_STATUS=unavailable
    fi
  fi

  reason=$(fm_agy_ladder_check "$@") || rc=$?
  case "$rc" in
    0)
      # An allow the floor could not actually check is the one allow worth
      # breaking the silence for, and only when the live read was tried and
      # failed - a home that has simply never observed this rung is the ordinary
      # first launch and stays quiet.
      if [ "$FM_AGY_LADDER_POLL_STATUS" = unavailable ]; then
        case "$reason" in
          *'no current quota reading'*)
            printf 'notice: agy ladder could not read current quota, so this launch is unchecked against the floor: %s\n' "$reason"
            ;;
        esac
      fi
      return 0
      ;;
    2)
      printf 'notice: agy ladder not applied: %s\n' "$reason"
      return 0
      ;;
  esac
  if [ -n "${FM_AGY_LADDER_OVERRIDE:-}" ]; then
    printf 'notice: agy ladder OVERRIDDEN by FM_AGY_LADDER_OVERRIDE=%s - launching anyway past: %s\n' \
      "$FM_AGY_LADDER_OVERRIDE" "$reason"
    return 0
  fi
  printf 'error: agy ladder refuses this launch: %s. Run the highest available rung instead, or set FM_AGY_LADDER_OVERRIDE=<reason> to launch on the captain'"'"'s explicit request (its use is printed).\n' \
    "$reason"
  return 1
}
