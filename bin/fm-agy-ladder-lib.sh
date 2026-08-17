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
# THE EVIDENCE. quota-axi does not model agy at all, so the only live source is
# the agy pane footer ("<model> | ctx: <n>% | quota: <percent remaining>
# (<time to reset>)"). bin/fm-watch.sh records it into this home's state/ as the
# panes redraw, and bin/fm-agy-quota-lib.sh owns that format and its freshness
# rule: a reading older than its own reported reset window reads back as
# `unknown`, because the window it described has rolled over. That footer
# percentage is the SESSION-WINDOW quota, which is the only thing that governs a
# rung; a transient per-minute or per-request throttle is not exhaustion and
# never appears here.
#
# Readings are per-home, because state/ is. The quota itself is per-account, so
# a secondmate that has never drawn an agy pane of its own knows nothing about
# the rungs even while the primary home does. That resolves to rung 1 under the
# rule below, which is the right answer anyway: a home with no evidence starts
# at the top of the ladder rather than assuming somebody else spent it.
#
# THE ASYMMETRY, WHICH IS THE WHOLE DESIGN. Quota evidence is frequently absent:
# a fresh home has never drawn an agy pane, and a reading expires on its own
# window. Refusing every agy launch without evidence would wedge the fleet, and
# allowing every launch without evidence would enforce nothing. So absence is
# resolved by direction of travel:
#
#   - Climbing or staying at the top needs no evidence. Rung 1 is the ladder's
#     first choice anyway, and no rung sits above it to exhaust.
#   - DESCENDING needs positive evidence. A lower rung is refused unless every
#     rung above it has a current reading that proves it exhausted. Descending
#     is exactly the move the policy exists to constrain, so an unknown rung
#     above blocks it rather than excusing it.
#   - A rung's OWN floor refuses only on positive evidence. An unknown reading
#     for the requested rung is not proof it is spent, and treating it as such
#     would wedge the fleet for the same reason as above.
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

# fm_agy_ladder_state: what the recorded evidence says about one rung.
# Prints "exhausted <percent>", "available <percent>", or "unknown".
# "unknown" covers both a rung never observed and a reading whose own reset
# window has since elapsed - bin/fm-agy-quota-lib.sh collapses the two, and it
# is right to: a window that rolled over says nothing about what is left now.
fm_agy_ladder_state() {  # <rung> <state-dir> [<now>]
  local rung=$1 state_dir=$2 now=${3:-}
  local display reading percent
  display=$(fm_agy_ladder_display "$rung") || return 1
  reading=$(fm_agy_quota_read "$display" "$state_dir" "$now")
  case "$reading" in
    unknown|'') printf 'unknown'; return 0 ;;
  esac
  percent=${reading%% *}
  if fm_agy_ladder_at_or_below "$percent" "$(fm_agy_ladder_floor "$rung")"; then
    printf 'exhausted %s' "$percent"
  else
    printf 'available %s' "$percent"
  fi
}

# fm_agy_ladder_check: the decision, with no override applied. Always prints one
# line naming the rung and the evidence it acted on.
#   0  allow: the requested rung is the highest available one
#   1  refuse: the launch violates the ladder
#   2  allow, but the model is not on the ladder and is not governed by it
fm_agy_ladder_check() {  # <model> <state-dir> [<now>]
  local model=$1 state_dir=$2 now=${3:-}
  local rung above state percent floor display above_display

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

  # Descending: every rung above must be PROVEN exhausted. Absence of evidence
  # refuses here, because this is the move the policy constrains.
  above=1
  while [ "$above" -lt "$rung" ]; do
    state=$(fm_agy_ladder_state "$above" "$state_dir" "$now")
    above_display=$(fm_agy_ladder_display "$above")
    case "$state" in
      exhausted*) ;;
      available*)
        percent=${state#available }
        printf 'rung %s (%s) still has %s%% remaining above its %s%% floor, so rung %s (%s) is not the highest available rung' \
          "$above" "$above_display" "$percent" "$(fm_agy_ladder_floor "$above")" "$rung" "$display"
        return 1
        ;;
      *)
        printf 'rung %s (%s) has no current quota reading, so rung %s (%s) cannot be shown to be the highest available rung; run rung 1 first, or record a reading by opening an agy pane on rung %s' \
          "$above" "$above_display" "$rung" "$display" "$above"
        return 1
        ;;
    esac
    above=$((above + 1))
  done

  # The requested rung's own floor. Refuses only on positive evidence.
  state=$(fm_agy_ladder_state "$rung" "$state_dir" "$now")
  floor=$(fm_agy_ladder_floor "$rung")
  case "$state" in
    exhausted*)
      percent=${state#exhausted }
      if [ "$rung" = 1 ]; then
        printf 'rung 1 (%s) is at %s%% remaining, at or below the %s%% floor reserved for the captain; automatic dispatch never takes that last quarter' \
          "$display" "$percent" "$floor"
      else
        printf 'rung %s (%s) is exhausted at %s%% remaining (floor %s%%), so it cannot take this launch' \
          "$rung" "$display" "$percent" "$floor"
      fi
      return 1
      ;;
    available*)
      percent=${state#available }
      printf 'rung %s (%s) has %s%% remaining above its %s%% floor and every rung above it is exhausted' \
        "$rung" "$display" "$percent" "$floor"
      ;;
    *)
      printf 'rung %s (%s) has no current quota reading; nothing shows it spent, and every rung above it is exhausted' \
        "$rung" "$display"
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
  reason=$(fm_agy_ladder_check "$@") || rc=$?
  case "$rc" in
    0) return 0 ;;
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
