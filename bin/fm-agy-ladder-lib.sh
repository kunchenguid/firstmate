#!/usr/bin/env bash
# fm-agy-ladder-lib.sh - the agy model ladder, enforced at the dispatch layer.
# Usage: . bin/fm-agy-ladder-lib.sh
# Sourced by bin/fm-spawn.sh. This file has no side effects on source beyond
# pulling in its own quota-reading dependency and loading the ladder from config.
#
# THE POLICY. The captain's standing rule for agy dispatch is a fixed three-rung
# ladder run by STRICT EXHAUSTION, not load balancing.
# The rung order is DERIVED from config/crew-dispatch.json's "agy_ladder"
# array, which is the one place the captain sets it. The "default" array in
# that config is the dispatch profile set ONLY and no longer carries the rung
# order.
# When the config file is absent (a fresh home, a test), the built-in default
# order applies.
#
# Work runs on the highest non-exhausted rung. A lower rung is valid only once
# EVERY rung above it is exhausted. A worker that descends stays on the lower
# rung for the rest of its run: there is no recovery direction back up. The
# exhaustion floor is a property of the MODEL, not the
# rung position: Claude Opus 4.6 (Thinking) stops at 25 percent remaining
# wherever it sits on the ladder, because that last quarter is reserved for the
# captain on explicit request and automatic dispatch never touches it. Every
# other model exhausts to 0.
#
# This file gates LAUNCHES. bin/fm-agy-descent-lib.sh applies the same rule, in
# the downward direction only, to a worker already running, by putting each
# candidate rung to the gate below rather than keeping rungs or floors of its
# own.
#
# The authoritative statement of the policy is the captain-private
# config/crew-dispatch.json "_ladder_note"; this file is its enforcement, not a
# second copy of it. The rung order derives from that config's "agy_ladder"
# array at load time, so a reorder there is a reorder here with no second edit.
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
# at the top of the ladder rather than assuming somebody else spent it - and the
# poll above then gives it the account's own current figures before it decides,
# so no home decides on another home's staleness.
#
# THE ASYMMETRY, WHICH IS THE WHOLE DESIGN. Quota evidence can still be absent
# after the poll: agy may not be installed, jq may be missing, the call may time
# out, or the account may report no quota summary. The captain ruled on
# 2026-08-19 that this must not stop work - "we should not allow the fleet to
# stall" - so absence is never a refusal to launch at the top. Nor is it a
# licence to descend. Absence is resolved by direction of travel:
#
#   - Starting at the top needs no evidence. Rung 1 is the ladder's first
#     choice anyway, and no rung sits above it to exhaust.
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
# against that reserved figure, not the bare reading. That ledger is scoped to
# the AGY ACCOUNT and not to this home, so the launches it counts are every
# home's on this machine; bin/fm-agy-quota-lib.sh owns that scope, what it does
# and does not reach, and why. fm_agy_ladder_gate below records the reservation
# itself, under the same lock it decides on.
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

# --- the ladder: derived from config, not restated ---------------------------
#
# THE ORDER comes from config/crew-dispatch.json's "agy_ladder" array, which is
# the single place the captain sets the rung sequence. This file reads it once
# at load time and derives the enforcement tables from it, so a reorder there
# takes effect here with no second edit - the one-owner rule. The "default"
# array in that config is the dispatch profile set and is read here only as a
# legacy fallback for a home whose config predates the agy_ladder field; it is
# NOT where the rung order is set, so agy rows must not be added back to it.
#
# THE FLOOR is a property of the MODEL, not of the rung position. When the
# captain moved Opus from rung 1 to rung 2, the 25 percent reserve must travel
# with the model rather than staying pinned to whatever rung number it used to
# occupy. _FM_LADDER_MODEL_FLOOR is the table, keyed by display name.
#
# THE KEBAB IDS are the alternative spellings agy accepts for each display name.
# They are properties of the model catalogue, not of the order, and cannot be
# derived mechanically from a display name (e.g. "4.6" becomes "4-6" in Claude
# but stays "3.1" in Gemini). _fm_agy_ladder_kebab_to_display is that map, and
# _fm_agy_ladder_is_known_display is the set it draws from; both are stated
# once, as arms of a case, so the two spellings of one model cannot drift.
#
# When the config file is absent - a fresh home, a secondmate that has not been
# seeded, a test that does not set FM_AGY_LADDER_CONFIG - the built-in default
# order applies. That default matches the captain's current order so a fleet
# that has never had the config is correct by default.

# _FM_LADDER_DISPLAYS: newline-separated display names, rung 1 first.
# Populated by _fm_agy_ladder_init below.
_FM_LADDER_DISPLAYS=''
# _FM_LADDER_COUNT: how many rungs the ladder has.
_FM_LADDER_COUNT=0

# _fm_agy_ladder_model_floor: the floor for a model by display name, and the
# ONE place the captain's reserved quarter is written down. Only a model with a
# non-zero floor needs an arm; every other model exhausts to 0. The reserve
# follows the MODEL, not the rung position.
_fm_agy_ladder_model_floor() {  # <display-name>
  case "$1" in
    'Claude Opus 4.6 (Thinking)') printf '25' ;;
    *) printf '0' ;;
  esac
}

# _fm_agy_ladder_kebab_to_display: if <model> is a known kebab ID, print the
# display name. Returns 1 when no match. A property of agy's catalogue, not of
# the rung order, stated here so the gate can match either spelling without a
# network call.
_fm_agy_ladder_kebab_to_display() {  # <model>
  case "$1" in
    claude-opus-4-6-thinking)  printf 'Claude Opus 4.6 (Thinking)' ;;
    gemini-3.1-pro-high)       printf 'Gemini 3.1 Pro (High)' ;;
    gemini-3.7-flash-high)     printf 'Gemini 3.7 Flash (High)' ;;
    *) return 1 ;;
  esac
}

# _fm_agy_ladder_init: populate the rung order from config or defaults.
# Called once at source time.
_fm_agy_ladder_init() {
  local config_file displays='' count=0 line

  # The config path: tests override with FM_AGY_LADDER_CONFIG; production uses
  # FM_CONFIG_OVERRIDE (set by fm-spawn.sh's test harness) or FM_HOME/config.
  config_file="${FM_AGY_LADDER_CONFIG:-${FM_CONFIG_OVERRIDE:-${FM_HOME:+$FM_HOME/config}}/crew-dispatch.json}"

  if [ -f "$config_file" ] && command -v jq >/dev/null 2>&1; then
    # The rung order lives in the "agy_ladder" array, in rung order, one display
    # name (or kebab id) per entry. A config that predates that field carries no
    # rung order at all: fall back to the legacy derivation - agy rows filtered
    # out of the "default" dispatch profile set - and only then to the built-in
    # order below. The legacy path exists so an unmigrated home keeps working;
    # it is not where new orders are set.
    displays=$(jq -r '.agy_ladder[]? | select(. != null and . != "")' "$config_file" 2>/dev/null) || displays=''
    if [ -z "$displays" ]; then
      displays=$(jq -r '.default[]? | select(.harness == "agy" and .model != null and .model != "") | .model' "$config_file" 2>/dev/null) || displays=''
    fi
  fi

  # Validate: every model from config must be one the ladder knows about.
  # An unknown model in the config is a configuration error, not a silent
  # acceptance of something the gate cannot enforce. Fall back to defaults
  # if validation fails.
  #
  # The fallback is deliberate here and is NOT where the error is reported.
  # This function runs at source time inside bin/fm-spawn.sh, bin/fm-watch.sh,
  # and bin/fm-agy-ladder-tick.sh, whose output is parsed; a library that
  # complained on load would put its complaint into a wake reason. So the
  # runtime stays safe and silent, and fm_agy_ladder_config_problem below is
  # what bin/fm-bootstrap.sh asks at session start to make the same condition
  # loud once, where a person is reading.
  if [ -n "$displays" ]; then
    local validated='' m
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      # The model must be a display name we know, or a kebab ID we can resolve.
      if ! _fm_agy_ladder_is_known_display "$m"; then
        local resolved
        if resolved=$(_fm_agy_ladder_kebab_to_display "$m"); then
          m=$resolved
        else
          # Unknown model in config - fall back to defaults entirely.
          displays=''
          break
        fi
      fi
      if [ -n "$validated" ]; then
        validated="$validated
$m"
      else
        validated="$m"
      fi
    done <<EOF
$displays
EOF
    displays=$validated
  fi

  # Fall back to built-in defaults when the config is absent or unusable.
  if [ -z "$displays" ]; then
    displays='Gemini 3.1 Pro (High)
Claude Opus 4.6 (Thinking)
Gemini 3.7 Flash (High)'
  fi

  # Count the rungs.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    count=$((count + 1))
  done <<EOF
$displays
EOF

  _FM_LADDER_DISPLAYS=$displays
  _FM_LADDER_COUNT=$count
}

# _fm_agy_ladder_is_known_display: 0 when <name> is a display name the ladder
# knows about, regardless of whether it is currently ON the ladder.
_fm_agy_ladder_is_known_display() {  # <name>
  case "$1" in
    'Claude Opus 4.6 (Thinking)') return 0 ;;
    'Gemini 3.1 Pro (High)') return 0 ;;
    'Gemini 3.7 Flash (High)') return 0 ;;
    *) return 1 ;;
  esac
}

# fm_agy_ladder_config_problem: why <config-file>'s ladder order cannot be used,
# or nothing at all when it can.
#   0  the config states a usable ladder, or states none and the defaults apply
#   1  the config states a ladder this gate cannot enforce; the printed line is
#      the reason
#
# WHY THIS IS SEPARATE FROM THE LOADER. _fm_agy_ladder_init must never refuse:
# a home whose config it cannot read still has to dispatch, so it falls back to
# the built-in order and says nothing. That is safe and it is also silent, and a
# silently ignored config is how the captain reorders the ladder, mistypes one
# model, and gets the opposite order for weeks without a word. This function is
# the loud half, asked once per session by bin/fm-bootstrap.sh, so the two
# properties do not have to be traded against each other.
#
# It reports only what actually changes the enforced ladder. A config with no
# agy_ladder field and no agy entry in "default" is not an error - the built-in
# order is the right answer for a fleet that has not ranked one.
fm_agy_ladder_config_problem() {  # <config-file>
  local file=${1:-} models m seen='' dupes='' unknown='' field=agy_ladder

  [ -n "$file" ] && [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  if ! jq -e . "$file" >/dev/null 2>&1; then
    # Malformed JSON is already bin/fm-bootstrap.sh's own diagnostic, reported
    # once there rather than twice between us.
    return 0
  fi

  models=$(jq -r '.agy_ladder[]? | select(. != null and . != "")' "$file" 2>/dev/null) || return 0
  if [ -z "$models" ]; then
    field=default
    models=$(jq -r '.default[]? | select(.harness == "agy" and .model != null and .model != "") | .model' "$file" 2>/dev/null) || return 0
  fi
  [ -n "$models" ] || return 0

  while IFS= read -r m; do
    [ -n "$m" ] || continue
    if ! _fm_agy_ladder_is_known_display "$m"; then
      local resolved
      if resolved=$(_fm_agy_ladder_kebab_to_display "$m"); then
        m=$resolved
      else
        case "$unknown" in
          *"[$m]"*) ;;
          *) unknown="${unknown}[$m]" ;;
        esac
        continue
      fi
    fi
    case "$seen" in
      *"[$m]"*)
        case "$dupes" in
          *"[$m]"*) ;;
          *) dupes="${dupes}[$m]" ;;
        esac
        ;;
      *) seen="${seen}[$m]" ;;
    esac
  done <<EOF
$models
EOF

  if [ -n "$unknown" ]; then
    printf '%s names agy model(s) the ladder cannot rank: %s - the whole ladder order is being ignored and the built-in order used instead' \
      "$field" "$(printf '%s' "$unknown" | sed 's/\]\[/, /g; s/^\[//; s/\]$//')"
    return 1
  fi
  if [ -n "$dupes" ]; then
    printf '%s lists agy model(s) more than once: %s - a repeated model gives the ladder two rungs that exhaust together, so descending one rung no longer reaches a different model' \
      "$field" "$(printf '%s' "$dupes" | sed 's/\]\[/, /g; s/^\[//; s/\]$//')"
    return 1
  fi
  return 0
}

# Load the ladder on source. This runs once per shell that sources this file.
_fm_agy_ladder_init

# fm_agy_ladder_rung: the rung number a model sits on, or failure when the model
# is not on the ladder. BOTH spellings agy accepts are honoured - the kebab id
# and the display name - matching fm_agy_catalog_has_model's exact-match
# contract, so the gate and the catalogue check agree on what a model name is.
fm_agy_ladder_rung() {  # <model>
  local want=$1 display rung=0 line
  # Resolve a kebab ID to its display name first.
  if ! _fm_agy_ladder_is_known_display "$want"; then
    want=$(_fm_agy_ladder_kebab_to_display "$want") || return 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rung=$((rung + 1))
    if [ "$line" = "$want" ]; then
      printf '%s' "$rung"
      return 0
    fi
  done <<EOF
$_FM_LADDER_DISPLAYS
EOF
  return 1
}

# fm_agy_ladder_display: a rung's display name. This is the spelling the pane
# footer draws, so it is also the key bin/fm-agy-quota-lib.sh stores readings
# under; a lookup by kebab id would never find one.
fm_agy_ladder_display() {  # <rung>
  local target=$1 rung=0 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rung=$((rung + 1))
    if [ "$rung" -eq "$target" ]; then
      printf '%s' "$line"
      return 0
    fi
  done <<EOF
$_FM_LADDER_DISPLAYS
EOF
  return 1
}

# fm_agy_ladder_floor: the percent-remaining at or below which a rung counts as
# exhausted. The floor is a property of the MODEL, not the rung position:
# Claude Opus 4.6 (Thinking) carries the captain's reserved 25 percent wherever
# it sits on the ladder, and every other model exhausts to 0.
fm_agy_ladder_floor() {  # <rung>
  local display
  display=$(fm_agy_ladder_display "$1") || return 1
  _fm_agy_ladder_model_floor "$display"
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
  in_flight=$(fm_agy_inflight_count "$display" "$state_dir" "$now")
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
      if [ "$floor" = 25 ]; then
        printf 'rung %s (%s) is at %s%% remaining%s, at or below the %s%% floor reserved for the captain; automatic dispatch never takes that last quarter' \
          "$rung" "$display" "$percent" "$(fm_agy_ladder_inflight_clause "$percent" "$in_flight")" "$floor"
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

# fm_agy_ladder_gate: fm_agy_ladder_check with the captain override applied, the
# launch's own headroom reserved, and the output a caller should show. Prints
# nothing on an ordinary clean allow so routine dispatch stays quiet, and prints
# one line for everything a reader would want to know about: an off-ladder
# model, a used override, or a refusal.
#   0  launch may proceed
#   1  launch is refused; the printed line is the reason
#
# DECIDING AND RESERVING ARE ONE STEP, and that is why the reservation lives
# here rather than in bin/fm-spawn.sh where it used to. Between a gate that had
# decided and a caller that had not yet recorded, the reading both leaned on
# said the same thing to everyone, so two launches an instant apart could each
# be told they were the only one. Holding the account's reservation lock across
# the decision and the record closes that window instead of narrowing it, and
# because the lock and the ledger are scoped to the AGY ACCOUNT rather than to
# this home (bin/fm-agy-quota-lib.sh owns why), it closes it between homes too -
# which is the case that actually cost the captain the reserve on 2026-09-02.
#
# THE LOCK IS BOUNDED AND FAILING TO GET IT IS NOT A REFUSAL. bin/fm-spawn.sh
# calls this while holding its own spawn locks, so waiting indefinitely on
# another home would let one wedged home stall the whole fleet's dispatch. When
# the lock does not come, the decision is still made against the same shared
# ledger - every home's launches, not just this home's - and the reservation is
# still recorded. Only the serialization is lost.
#
# THE POLL STAYS OUTSIDE THE LOCK. It is the multi-second part, it reads the
# account rather than the ledger, and two homes polling at once is simply two
# reads of the same external truth.
fm_agy_ladder_gate() {  # <model> <state-dir> [<now>]
  local reason rc=0 gate=0 out='' display='' rung='' lock=''
  # Dynamically scoped for the duration of this call so fm_agy_inflight_count,
  # reached through fm_agy_ladder_check below, prunes under the hold this
  # function already has instead of reaching for the same lock again.
  local _FM_AGY_INFLIGHT_LOCK_HELD=

  # Refresh the evidence before deciding on it, once, for every rung at a time.
  # Only for a model the ladder actually ranks: an off-ladder or unmodelled
  # launch is not governed by any floor, so it must not pay for a network call
  # while bin/fm-spawn.sh holds the spawn locks. A poll that cannot run leaves
  # whatever was recorded in place and is remembered, not raised: the gate still
  # decides, and says which fallback it decided on.
  FM_AGY_LADDER_POLL_STATUS=skipped
  if [ "${1:-}" != '' ] && [ "${1:-}" != default ] && rung=$(fm_agy_ladder_rung "$1" 2>/dev/null); then
    display=$(fm_agy_ladder_display "$rung" 2>/dev/null) || display=''
    if [ "${FM_AGY_QUOTA_POLL:-on}" = off ]; then
      FM_AGY_LADDER_POLL_STATUS=off
    elif fm_agy_quota_poll "${2:-}" "${3:-}"; then
      FM_AGY_LADDER_POLL_STATUS=ok
    else
      FM_AGY_LADDER_POLL_STATUS=unavailable
    fi
  fi

  if [ -n "$display" ]; then
    if lock=$(fm_agy_inflight_lock "${2:-}"); then
      _FM_AGY_INFLIGHT_LOCK_HELD=1
    else
      lock=
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
            out=$(printf 'notice: agy ladder could not read current quota, so this launch is unchecked against the floor: %s\n' "$reason")
            ;;
        esac
      fi
      ;;
    2)
      out=$(printf 'notice: agy ladder not applied: %s\n' "$reason")
      ;;
    *)
      if [ -n "${FM_AGY_LADDER_OVERRIDE:-}" ]; then
        out=$(printf 'notice: agy ladder OVERRIDDEN by FM_AGY_LADDER_OVERRIDE=%s - launching anyway past: %s\n' \
          "$FM_AGY_LADDER_OVERRIDE" "$reason")
      else
        gate=1
        out=$(printf 'error: agy ladder refuses this launch: %s. Run the highest available rung instead, or set FM_AGY_LADDER_OVERRIDE=<reason> to launch on the captain'"'"'s explicit request (its use is printed).\n' \
          "$reason")
      fi
      ;;
  esac

  # Reserve this launch's headroom the moment it is authorized, before the lock
  # is dropped, so the next launch on this account sees it before any reading
  # could possibly reflect it. A launch the captain overrode is reserved too: it
  # spends the same quota, and leaving it uncounted would let the launches
  # BEHIND it read headroom that is already gone.
  if [ "$gate" -eq 0 ] && [ -n "$display" ]; then
    fm_agy_inflight_record "$display" "${2:-}" "${3:-}" || true
  fi
  [ -z "$lock" ] || fm_lock_release "$lock" || true

  [ -z "$out" ] || printf '%s\n' "$out"
  return "$gate"
}
