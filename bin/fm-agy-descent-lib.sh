#!/usr/bin/env bash
# fm-agy-descent-lib.sh - keep an ALREADY RUNNING agy worker on the ladder.
# Usage: . bin/fm-agy-descent-lib.sh
# Sourced by bin/fm-watch.sh and bin/fm-agy-ladder-tick.sh. Defining functions
# is all this file does; the only thing it pulls in on its own is the shared
# lock library it needs, and only when a caller has not already loaded it.
#
# THE HALF THE LAUNCH GATE CANNOT COVER. bin/fm-agy-ladder-lib.sh gates
# LAUNCHES: it refuses to start a worker on a rung at or below that rung's
# floor. Nothing watched a worker that was ALREADY RUNNING, and consumption
# happens during a run, not at the start of one. On 2026-08-20 a crewmate
# launched on rung 1 above the floor and drove Claude Opus 4.6 (Thinking) to
# remaining_fraction 0, which cost twice over: the captain lost the entire
# quarter the floor exists to reserve, and the worker then stalled outright
# ("You have exhausted your capacity on this model") instead of degrading.
# This file is the missing trigger and the missing action.
#
# THE POLICY IS NOT RESTATED HERE. bin/fm-agy-ladder-lib.sh owns the rungs, the
# floors, the freshness rules, and the direction-of-travel asymmetry that
# refuses a descent unless every rung above is PROVEN exhausted. Every decision
# below is delegated to fm_agy_ladder_check, so a policy change lands in one
# file and this one follows it. In particular the descent target is not
# computed from a rung number: it is the first rung below the worker's current
# one that the ladder gate itself authorizes, which is exactly the gate's own
# "highest available rung" rule applied one rung at a time. In the ordinary
# case that is a single step down; when the rung immediately below is also
# spent, the gate proves the rungs above the next one exhausted before that one
# is taken, so no worker is ever spread onto a rung the policy did not reach.
#
# THE READ COSTS NOTHING. fm_agy_quota_poll is `agy --print /quota
# --output-format json`, which answers every model at once and runs no turn
# (docs/verification/agy-quota-poll.md). It is therefore safe to run on a
# cadence against the budget it protects. It still costs a bounded subprocess,
# so FM_AGY_DESCENT_INTERVAL keeps the watcher from paying for it every poll,
# and nothing is read at all in a home with no live agy worker on a rung.
#
# THE ACTION IS AN IN-SESSION SWITCH, AND THAT IS THE WHOLE POINT. agy's
# `/model` command switches the model of a RUNNING conversation: the worker
# keeps its conversation, its context window, and its place in the task
# (verified live, agy 1.1.16 - docs/verification/agy-model-switch.md). The
# alternative, bin/fm-control.sh relaunch --model, is proven and preserves the
# worktree, branch, and commits, but it costs the conversation. A descent that
# has to be cheap enough to happen automatically, unsupervised, at the moment a
# floor is crossed should not destroy the worker's conversation to do it, so
# the in-session switch is the automatic path and relaunch stays the remedy an
# escalation names.
#
# WHY THIS IS FAIL-CLOSED AND NOT CLEVER. `/model` opens an interactive picker.
# It accepts no argument (verified: `/model gemini-3.7-flash-high` opens the
# same picker and discards the argument) and offers no type-to-filter, so the
# only way in is a keyboard walk over a rendered list whose membership and
# order come from the account's own catalogue. A miscounted walk would not
# merely fail - it would move a live worker onto some OTHER model, possibly
# back onto the very rung the descent was protecting. Every step below is
# therefore guarded, and every guard refuses rather than guesses:
#
#   0. `/model` is submitted with exactly ONE Enter, and every refusal from that
#      point on closes any modal and clears the composer. The shared submit
#      helper retries an unconfirmed Enter, which is right for a prompt and
#      wrong for a command that opens a modal: the retry lands INSIDE the picker
#      and commits whatever row is highlighted.
#   1. Nothing is sent to a worker that is not PROVABLY idle. Busy state comes
#      from agy's own lifecycle hooks (bin/fm-busy-lib.sh), not from rendered
#      text. A busy worker is left alone and retried on the next evaluation.
#   2. Not one navigation key is sent until the picker has been positively
#      identified: its title, its keyboard legend, exactly one selection
#      marker, and a `(current)` row. If `/model` did not open a picker, the
#      walk never starts, so stray keys can never land in the composer.
#   3. The number of moves is PARSED from the rendered list, never assumed.
#   4. The selection is re-read and must sit on the exact target row before
#      Enter is pressed. This is the guard that matters: it is checked before
#      anything is committed, so a wrong walk is abandoned, not shipped.
#   5. The result is confirmed from two independent signals - agy's own
#      "Model set to <model>" acknowledgement and the pane footer's model
#      field - and both must name the exact target.
#   6. Anything else escapes the picker, leaves the worker where it was, and
#      escalates.
#
# The one thing never re-derived from the pane is the FLOOR. Quota comes from
# the authenticated poll in bin/fm-agy-quota-lib.sh; the rendered footer is
# read here only to confirm WHICH MODEL is selected, never how much of it is
# left.
#
# EFFORT IS SATURATED, NOT COUNTED. Every rung on the ladder runs at its
# family's strongest effort, so the walk pushes the effort slider hard right
# rather than parsing its stops. That is robust against a slider gaining or
# losing a stop - but it is only correct while the ladder asks for the top of
# the range, so a target whose name carries any effort other than "(High)" is
# refused outright rather than silently saturated to something the captain did
# not ask for.
#
# CLIMBING BACK UP IS THE OTHER HALF, AND IT IS HERE NOW. The captain's ladder
# rule is two-directional - exhaust a rung, descend exactly one, climb back the
# moment the rung above resets - and only the descending half landed first,
# because that is the safety half. The climb needed two things the descent did
# not: hysteresis, or a rung hovering at its floor would flap a worker between
# models mid-task; and a ruling, because climbing INTO rung 1 mid-task starts
# spending the very reserve the descent exists to protect. The captain ruled on
# 2026-08-20: a running worker climbs back "as soon as rung 1 is above its 25%
# floor with hysteresis to stop flapping - so it climbs into the free three
# quarters, never into your reserve". The reserved quarter therefore keeps
# exactly the protection the descent gave it, and the space above it is where a
# running worker is allowed to return to. See the climbing-back section below.
#
# DOES THIS GENERALISE TO OTHER PROVIDERS? The shape does; nothing else here
# does, and the difference matters because the same failure has now happened on
# a second provider. Two Claude workers were stopped mid-task by a session limit
# on 2026-08-20; neither signalled, both panes simply went quiet, and the captain
# found them by looking rather than by any alarm.
#
# The evaluation below is three separable steps, and only the first is already
# provider-neutral:
#
#   1. Enumerate live workers from their durable records. Reads state/*.meta and
#      filters by harness; nothing about it is agy-specific.
#   2. Read each worker's remaining budget ON ITS OWN PROVIDER.
#   3. Compare against a declared floor, and act.
#
# Step 2 is where agy is unusually easy: it answers for its own account, for
# free, in one call. A Claude worker has no equivalent this can poll, and the
# fleet's general quota source (quota-axi) is a separate tool with its own shape
# and freshness that models account and product windows rather than what is left
# of a running session's window.
#
# Step 3 does not exist for Claude at all. The rungs and the reserved quarter are
# the captain's stated policy for agy MODELS. There is no declared ordering or
# floor for Claude models, and a floor nobody has declared cannot be enforced.
#
# The resource is also not the same kind of thing. A session limit stops the
# whole session whatever model is selected, so descending to a cheaper Claude
# model may buy nothing; whether those models draw on separate windows has to be
# established before any of this would be worth building. And the action would
# need its own verified switch: Claude has a /model command, but whether it can
# be driven into a running pane with the conversation intact is unproven, which
# is exactly the assumption this file's own live guard exists to stop anyone
# making for agy.
#
# So this stays agy-scoped, deliberately. The more valuable provider-neutral fix
# is a different one and belongs to supervision, not to quota: a worker stopped
# by ITS provider should be loud. bin/fm-watch.sh exempts a pane from staleness
# while its semantic busy record says busy, for up to FM_BUSY_TURN_MAX_SECS (an
# hour by default) - so a provider that cuts a turn off WITHOUT the harness
# firing its turn-end hook leaves the record stuck at busy and the worker reads
# as legitimately working for that entire hour. That mechanism is a hypothesis
# about the 2026-08-20 Claude stalls, not a measured cause, and it wants its own
# reproduction before anything is changed on the strength of it.

# WHO DRIVES IT, AND WHY IT IS NOT ONLY THE WATCHER. The evaluation was first
# driven from bin/fm-watch.sh alone. The watcher is armed by firstmate when
# firstmate goes to wait, and it exits the moment it has something to say, so it
# runs BETWEEN firstmate's turns and not during them. That made the captain's
# reserved quarter conditional on how long firstmate's turns happen to be, which
# is not a property anyone chose. Observed on 2026-08-21: the last evaluation ran
# at 18:48 and read 28.7%, correctly above the floor and correctly declining to
# move anyone; firstmate then spent about ten minutes inside one turn, nothing
# re-evaluated, and the rung was at 19.6% - inside the reserve, with workers
# still spending it - by the time anything looked again.
#
# The interval was never the problem, so shortening it fixes nothing: a driver
# that is not running cannot be run more often. What is needed is a driver
# firstmate's turn boundaries cannot starve, and the fleet already has exactly
# one - the spender itself. Every agy worker fires firstmate's own Stop hook at
# the end of every turn it takes (bin/fm-spawn.sh installs it; bin/fm-busy-lib.sh
# owns why). That hook runs in the WORKER's process tree, so it is scheduled by
# the thing consuming the quota rather than by the thing supervising it, and it
# fires however long firstmate stays inside a turn.
#
# Turn end is also the only moment this file can act at all: guard 1 refuses to
# drive a modal picker into a worker that is not provably idle, so the worker's
# own turn boundary is simultaneously the tightest useful cadence and the safest
# one. bin/fm-agy-ladder-tick.sh is the entry point that hook runs, detached so a
# worker's turn never waits on a quota read or a picker walk, and the two drivers
# share one evaluation because fm_agy_descent_tick is single-flight.
#
# THE OVERRIDE. FM_AGY_LADDER_OVERRIDE is the launch gate's deliberate escape
# and it is honoured here too: a worker launched past the ladder on the
# captain's explicit request is not dragged off its model behind their back.
# Its use is printed, exactly as the launch gate prints it.

_FM_AGY_DESCENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_AGY_DESCENT_LIB_DIR="."
if ! declare -f fm_agy_ladder_check >/dev/null 2>&1; then
  # shellcheck source=bin/fm-agy-ladder-lib.sh
  . "$_FM_AGY_DESCENT_LIB_DIR/fm-agy-ladder-lib.sh"
fi
# The shared mutex and per-task record lock, which this file uses to serialize
# concurrent evaluations against each other and its durable record update
# against bin/fm-spawn.sh's relaunch publication. Both drivers already load this
# library before this one, so the guarded source below fires only when this file
# is loaded on its own.
#
# Source analysis stops here. That library is a canonical lint root in its own
# right, so following it from this file adds no uncovered line - and it would be
# re-expanded inside every root that loads this one, including bin/fm-watch.sh,
# whose graph is already the most expensive one the bounded CI lint worker has
# to hold.
# shellcheck source=/dev/null
if ! declare -f fm_lock_try_acquire >/dev/null 2>&1; then
  . "$_FM_AGY_DESCENT_LIB_DIR/fm-wake-lib.sh"
fi

# FM_AGY_DESCENT: `off` disables the whole evaluation, leaving the launch gate
# as the only enforcement. Nothing in production sets it; it exists so a
# regression can pin the watcher's behaviour with the tick disabled.
FM_AGY_DESCENT=${FM_AGY_DESCENT:-on}

# FM_AGY_DESCENT_INTERVAL: seconds between evaluations. The gap between a
# rung's floor and its exhaustion is a quarter of a multi-hour window, so a
# minute is far tighter than it needs to be while keeping the bounded quota
# subprocess off most watcher polls.
FM_AGY_DESCENT_INTERVAL=${FM_AGY_DESCENT_INTERVAL:-60}

# FM_AGY_DESCENT_GRACE: how long a worker may sit below its floor without a
# completed descent before the captain is told. A worker that never goes idle
# cannot be switched safely (guard 1 above), and silently waiting forever would
# reproduce the original failure with extra steps.
FM_AGY_DESCENT_GRACE=${FM_AGY_DESCENT_GRACE:-900}

# Bounded waits, in seconds, for the two things agy has to draw before the walk
# may continue or be believed.
FM_AGY_DESCENT_PICKER_WAIT=${FM_AGY_DESCENT_PICKER_WAIT:-20}
FM_AGY_DESCENT_CONFIRM_WAIT=${FM_AGY_DESCENT_CONFIRM_WAIT:-30}

# FM_AGY_DESCENT_EFFORT_KEYS: how many right-arrow presses saturate the effort
# slider. Generously more than any observed stop count; the slider clamps at its
# maximum rather than wrapping (verified, agy 1.1.16), so overshooting is free
# and undershooting would select the wrong effort.
FM_AGY_DESCENT_EFFORT_KEYS=${FM_AGY_DESCENT_EFFORT_KEYS:-8}

# How many pane lines to read. The picker plus agy's banner and the last turn
# comfortably fit; the footer is always the last line.
FM_AGY_DESCENT_CAPTURE_LINES=${FM_AGY_DESCENT_CAPTURE_LINES:-60}

# --- the rendered picker ----------------------------------------------------
#
# Switch Model
#
#   Gemini 3.7 Flash
#   Gemini 3.6 Flash
#   Gemini 3.5 Flash
# > Gemini 3.1 Pro               (current)
#   Claude Sonnet 4.6 (Thinking)
#   Claude Opus 4.6 (Thinking)
#   GPT-OSS 120B (Medium)
#
#   Effort  <  *==============*==============O  >
#                  low          medium        high
#
# Keyboard: up/down Navigate  left/right Effort  enter Select  esc Go Back
#
# Note what the rows are and are not. A Gemini row names a model FAMILY and
# leaves the effort to the slider, while a Claude or GPT-OSS row carries its
# qualifier inline. A ladder display name therefore maps onto a row in one of
# two ways, and fm_agy_descent_row_for resolves which by matching against the
# picker's own rows rather than by taking the name apart with a rule.

# fm_agy_descent_picker_rows: the picker's model rows, in order, one
# "<marker><TAB><name>" line each, where <marker> is `>` for the selected row
# and empty otherwise. Prints nothing when <text> is not a picker.
#
# Every reader below splits these lines with parameter expansion rather than
# `read -r marker name`: an unselected row's marker is EMPTY, and `read` with a
# tab IFS discards a leading empty field as leading whitespace, which silently
# shifts the name into the marker and makes every row unfindable.
fm_agy_descent_picker_rows() {  # <text>
  printf '%s\n' "$1" | fm_agy_strip_ansi | LC_ALL=C awk '
    /^[[:space:]]*Switch Model[[:space:]]*$/ { inpicker = 1; next }
    !inpicker { next }
    /^[[:space:]]*Effort[[:space:]]/ { exit }
    /^[[:space:]]*$/ { next }
    {
      line = $0
      marker = ""
      if (line ~ /^[[:space:]]*>[[:space:]]/) {
        marker = ">"
        sub(/^[[:space:]]*>[[:space:]]+/, "", line)
      } else {
        sub(/^[[:space:]]+/, "", line)
      }
      sub(/[[:space:]]+\(current\)[[:space:]]*$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "" || line == ">") next
      printf "%s\t%s\n", marker, line
    }'
}

# fm_agy_descent_is_picker: 0 only when <text> positively shows agy's model
# picker. Every navigation key in this file is gated on this, so it demands
# more than one independent marker: the title, the keyboard legend that names
# the exact keys about to be sent, exactly one selection marker, and a
# `(current)` row proving the list is populated and bound to a live selection.
fm_agy_descent_is_picker() {  # <text>
  local clean rows selected
  clean=$(printf '%s\n' "$1" | fm_agy_strip_ansi)
  printf '%s\n' "$clean" | LC_ALL=C grep -qE '^[[:space:]]*Switch Model[[:space:]]*$' || return 1
  printf '%s\n' "$clean" | LC_ALL=C grep -q 'enter Select' || return 1
  printf '%s\n' "$clean" | LC_ALL=C grep -q 'esc Go Back' || return 1
  printf '%s\n' "$clean" | LC_ALL=C grep -q '(current)' || return 1
  rows=$(fm_agy_descent_picker_rows "$clean")
  [ -n "$rows" ] || return 1
  selected=$(printf '%s\n' "$rows" | LC_ALL=C grep -c '^>	' || true)
  [ "$selected" = 1 ] || return 1
  return 0
}

# fm_agy_descent_row_for: the picker row a ladder display name selects, printed
# as "<row-name><TAB><effort>", where <effort> is `high` when the slider must be
# driven and empty when the row already names the exact model.
#
# Resolved against the picker's OWN rows, so the split between a model family
# and an effort suffix is read from what agy drew rather than from a rule about
# how agy names things. An effort other than High is refused: this file
# saturates the slider rather than counting its stops, which is only correct at
# the top of the range.
fm_agy_descent_row_for() {  # <rows> <ladder-display>
  local rows=$1 want=$2 line name base
  while IFS= read -r line; do
    name=${line#*$'\t'}
    [ -n "$name" ] || continue
    if [ "$name" = "$want" ]; then
      printf '%s\t' "$name"
      return 0
    fi
  done <<EOF
$rows
EOF
  case "$want" in
    *' (High)') base=${want% (High)} ;;
    *) return 1 ;;
  esac
  while IFS= read -r line; do
    name=${line#*$'\t'}
    [ -n "$name" ] || continue
    if [ "$name" = "$base" ]; then
      printf '%s\thigh' "$name"
      return 0
    fi
  done <<EOF
$rows
EOF
  return 1
}

# fm_agy_descent_row_index: the 0-based position of <name> among <rows>, or a
# failure when it is absent or listed more than once. Ambiguity refuses: two
# identically named rows make every move count meaningless.
fm_agy_descent_row_index() {  # <rows> <name>
  local rows=$1 want=$2 line name i=0 found=-1 hits=0
  while IFS= read -r line; do
    name=${line#*$'\t'}
    [ -n "$name" ] || continue
    if [ "$name" = "$want" ]; then
      found=$i
      hits=$((hits + 1))
    fi
    i=$((i + 1))
  done <<EOF
$rows
EOF
  [ "$hits" -eq 1 ] || return 1
  printf '%s' "$found"
}

# fm_agy_descent_selected_row: the name of the row the picker currently marks.
fm_agy_descent_selected_row() {  # <rows>
  local rows=$1 line
  while IFS= read -r line; do
    case "$line" in
      '>'$'\t'*)
        printf '%s' "${line#*$'\t'}"
        return 0
        ;;
    esac
  done <<EOF
$rows
EOF
  return 1
}

# fm_agy_descent_plan: the exact key walk from the picker's current selection to
# <ladder-display>, printed as "<key> <count> <effort>" - for example
# "Up 3 high", or "Down 1 " when the target row already names the model. Fails
# when the target is not on the picker, is listed twice, or asks for an effort
# this walk will not set.
fm_agy_descent_plan() {  # <picker-text> <ladder-display>
  local text=$1 want=$2 rows resolved row effort from to delta key
  rows=$(fm_agy_descent_picker_rows "$text")
  [ -n "$rows" ] || return 1
  resolved=$(fm_agy_descent_row_for "$rows" "$want") || return 1
  row=${resolved%%	*}
  effort=${resolved#*	}
  to=$(fm_agy_descent_row_index "$rows" "$row") || return 1
  from=$(fm_agy_descent_selected_row "$rows") || return 1
  from=$(fm_agy_descent_row_index "$rows" "$from") || return 1
  delta=$((to - from))
  if [ "$delta" -lt 0 ]; then
    key=Up
    delta=$((-delta))
  else
    key=Down
  fi
  printf '%s %s %s' "$key" "$delta" "$effort"
}

# fm_agy_descent_confirms: 0 when <text> proves the running model is now
# <ladder-display>, from BOTH independent signals agy leaves behind - its own
# acknowledgement line and the pane footer's model field. The footer parse has
# one owner in bin/fm-agy-quota-lib.sh; only the model field is read here,
# never the percentage, because the floor is never re-derived from a pane.
fm_agy_descent_confirms() {  # <text> <ladder-display>
  local text=$1 want=$2 footer
  printf '%s\n' "$text" | fm_agy_strip_ansi \
    | LC_ALL=C grep -qF "Model set to $want" || return 1
  footer=$(fm_agy_footer_model "$text") || return 1
  [ "$footer" = "$want" ] || return 1
  return 0
}

# --- the decision -----------------------------------------------------------

# fm_agy_descent_target: the rung a worker currently on <rung> should move to,
# or a failure when no rung below it can be authorized.
#
# The choice is not made here. Each candidate is put to fm_agy_ladder_check,
# which applies the captain's policy in full: it refuses a rung whose own floor
# is spent, and refuses any rung it cannot PROVE every rung above exhausted.
# Walking downwards one rung at a time and taking the first authorized answer is
# that policy's "highest available rung" read from the gate rather than
# recomputed beside it.
fm_agy_descent_target() {  # <rung> <state-dir> [<now>]
  local rung=$1 state_dir=$2 now=${3:-} candidate display
  candidate=$((rung + 1))
  while display=$(fm_agy_ladder_display "$candidate" 2>/dev/null); do
    if fm_agy_ladder_check "$display" "$state_dir" "$now" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
    candidate=$((candidate + 1))
  done
  return 1
}

# fm_agy_descent_needed: 0 when the worker's own rung is at or below its floor
# on current evidence. Absence of evidence is NOT a crossing: the ladder's
# asymmetry says only positive evidence refuses a rung's own floor, and acting
# on an unknown reading here would move live workers for no reason.
fm_agy_descent_needed() {  # <rung> <state-dir> [<now>]
  local state
  state=$(fm_agy_ladder_state "$1" "$2" "${3:-}")
  case "$state" in
    exhausted*) return 0 ;;
  esac
  return 1
}

# --- climbing back up -------------------------------------------------------
#
# THE OTHER HALF OF THE CAPTAIN'S RULE. A worker moved down for its own safety
# must not stay down after the rung above it has reset. Everything below reuses
# the machinery already in this file - the same evidence, the same gate, the
# same guarded walk, the same refuse-and-escalate posture. Only the trigger is
# new.
#
# THE FLOOR IS THE SAME FLOOR. There is no second reading, no second floor, and
# no second notion of exhaustion. Each climb candidate is put to
# fm_agy_ladder_check exactly as a launch would be, so rung 1 is refused at or
# below the captain's reserved quarter for a RUNNING worker for precisely the
# reason it is refused for a new one. That is the captain's 2026-08-20 ruling in
# code: the free three quarters are where a running worker may return to, the
# reserved quarter is not, and FM_AGY_LADDER_OVERRIDE remains the only way past
# it in either direction.
#
# ABSENCE REFUSES HERE, WHICH IS NOT WHAT IT DOES AT A LAUNCH. The launch gate
# lets rung 1 START with no reading at all, because the top of the ladder is its
# first choice anyway and refusing would stall the fleet. A climb is the
# opposite case: it moves a worker that is already working INTO the rung whose
# reserve this file exists to protect, so it is a move the policy constrains,
# and the ladder's own asymmetry says a constrained move needs positive
# evidence. fm_agy_climb_clears_margin supplies that by refusing an unknown rung
# outright rather than reading absence as headroom.
#
# HYSTERESIS, IN TWO PARTS, BECAUSE A BARE THRESHOLD FLAPS. The descent fires at
# or below the floor. If the climb fired at anything above it, a rung sitting on
# the line would hand a worker back and forth between models mid-task, and each
# crossing costs a guarded modal walk into a live pane. Both parts are dead
# bands, and both are derived rather than picked:
#
#   FM_AGY_CLIMB_MARGIN, the gap in percentage points between the two triggers.
#   Descend at or below the floor, climb only at floor + margin, so the band
#   between them belongs to whichever side the worker is already on. Ten points
#   is the figure for three independent reasons:
#     - Quota falls monotonically inside a reset window (the freshness rule in
#       bin/fm-agy-quota-lib.sh turns on exactly that), so the only thing that
#       RAISES a rung is its window rolling over, which restores it toward 100%.
#       A rung a hair above its floor is one on its way DOWN, not one that has
#       reset - and the captain's rule names the reset as the trigger.
#     - A dead band has to be wider than the movement it must not react to. The
#       largest change in the reserved figure that is not consumption is the
#       headroom the launch gate holds back for launches in flight, at
#       FM_AGY_LADDER_INFLIGHT_MARGIN (one point) each, so ten points absorbs a
#       burst of ten concurrent launches without bookkeeping alone crossing it.
#     - It has to stay small enough to be worth having. Rung 1's usable band
#       above the captain's quarter is 75 points, so ten of them withhold the
#       last 13% of a reset window and the worker climbs back for the rest.
#
#   FM_AGY_CLIMB_DWELL, how long the condition must hold before it is acted on.
#   A margin rejects a reading that hovers; it does not reject one that jumps
#   the band and falls straight back. This defaults to FM_AGY_QUOTA_MAX_AGE for
#   the same reason FM_AGY_INFLIGHT_TTL does: that is this fleet's one
#   definition of how long a single reading is allowed to speak for, so
#   requiring the condition to outlive it means no climb is ever authorized by
#   one reading. At the default cadence that is five consecutive evaluations
#   agreeing. The timer is per RUNG rather than per worker, because the
#   condition is a property of the rung and every worker below it deserves the
#   same answer; and it is reset the instant the condition lapses, so a rung
#   oscillating across the line accumulates no dwell at all and every worker
#   below it simply holds.
#
# THE DWELL IS NOT SKIPPED FOR AN URGENT CLIMB. A worker whose own rung is spent
# is stalled, and making it wait out the dwell to be rescued is a real cost. It
# waits anyway: one rule with no exception is worth more than those minutes, and
# the exception would apply exactly when the evidence is least settled.
#
# THE OVERRIDE IS SILENT ON THIS SIDE. A worker the captain pinned with
# FM_AGY_LADDER_OVERRIDE is not climbed, exactly as it is not descended. The
# descent SAYS so, because a pinned worker below its floor is spending the
# reserve and the captain should hear about it. A pinned worker on a slower rung
# than it could have is not a harm - it is what they asked for - so this side
# says nothing rather than waking them about it.
#
# AND NOT HAVING CLIMBED IS NEVER ESCALATED ON ITS OWN. The descent escalates a
# worker it could never interrupt, because sitting below the floor is the harm
# this whole file exists to stop. Still being on rung 2 is not a harm; it is a
# slower model. Only a climb that was ATTEMPTED and failed is reported, and it
# is then not retried until the rung stops being climbable, so a refusal cannot
# turn into a modal walk into a live pane every minute.

# FM_AGY_CLIMB: `off` disables the climb half only, leaving the descent as the
# whole of live enforcement. FM_AGY_DESCENT=off still disables the entire
# evaluation, this half included, because it turns the tick itself off.
FM_AGY_CLIMB=${FM_AGY_CLIMB:-on}

# Percentage points a rung must stand clear of its own floor before a running
# worker is moved back onto it. Derived above; changing it changes how far a
# rung must have reset to be worth returning to.
FM_AGY_CLIMB_MARGIN=${FM_AGY_CLIMB_MARGIN:-10}

# Seconds the margin must hold continuously before the climb is acted on.
# Defaulted to the reading ceiling so the two definitions of "long enough to
# believe" cannot drift apart, exactly as FM_AGY_INFLIGHT_TTL is.
FM_AGY_CLIMB_DWELL=${FM_AGY_CLIMB_DWELL:-$FM_AGY_QUOTA_MAX_AGE}

fm_agy_climb_mark() {  # <state-dir> <name>
  printf '%s' "$1/.agy-climb-$2"
}

fm_agy_climb_clear_task() {  # <state-dir> <id>
  rm -f "$(fm_agy_climb_mark "$1" "failed-$2")" 2>/dev/null || true
}

# fm_agy_climb_clears_margin: 0 only when <rung> has a CURRENT reading putting it
# FM_AGY_CLIMB_MARGIN points clear of its own floor, after the same in-flight
# headroom the launch gate reserves. An unknown rung refuses; see the asymmetry
# note above.
fm_agy_climb_clears_margin() {  # <rung> <state-dir> [<now>]
  local rung=$1 state_dir=$2 now=${3:-}
  local display floor reading percent in_flight effective
  display=$(fm_agy_ladder_display "$rung") || return 1
  floor=$(fm_agy_ladder_floor "$rung") || return 1
  reading=$(fm_agy_quota_read "$display" "$state_dir" "$now")
  case "$reading" in
    unknown|'') return 1 ;;
  esac
  percent=${reading%% *}
  fm_agy_is_number "$percent" || return 1
  in_flight=$(fm_agy_inflight_count "$rung" "$state_dir" "$now")
  effective=$(fm_agy_ladder_reserved "$percent" "$in_flight")
  awk -v p="$effective" -v f="$floor" -v m="$FM_AGY_CLIMB_MARGIN" \
    'BEGIN { exit !(p >= f + m) }'
}

fm_agy_climb_dwell_path() {  # <state-dir> <rung>
  printf '%s/.agy-climb-since-%s' "$1" "$2"
}

# fm_agy_climb_dwell_tick: advance every rung's dwell timer once for the whole
# home. A rung clear of its margin has its timer STARTED if one is not already
# running; a rung that is not has its timer removed outright, which is what
# makes an oscillating rung accumulate nothing. Called once per evaluation,
# before any worker is considered, so workers on the same rung read one shared
# answer instead of each starting a clock of its own.
#
# The rungs are walked through fm_agy_ladder_display rather than counted, so the
# ladder's length stays owned by bin/fm-agy-ladder-lib.sh.
fm_agy_climb_dwell_tick() {  # <state-dir> <now>
  local state_dir=$1 now=$2 rung=1 path
  while fm_agy_ladder_display "$rung" >/dev/null 2>&1; do
    path=$(fm_agy_climb_dwell_path "$state_dir" "$rung")
    if fm_agy_climb_clears_margin "$rung" "$state_dir" "$now"; then
      if [ ! -f "$path" ]; then
        printf '%s' "$now" > "$path" 2>/dev/null || true
      fi
    else
      rm -f "$path" 2>/dev/null || true
    fi
    rung=$((rung + 1))
  done
}

# fm_agy_climb_dwelt: 0 when <rung>'s timer has been running for at least
# FM_AGY_CLIMB_DWELL. No timer at all means the condition is not holding now,
# which is a refusal rather than an elapsed wait.
fm_agy_climb_dwelt() {  # <rung> <state-dir> <now>
  local path stamp
  path=$(fm_agy_climb_dwell_path "$2" "$1")
  [ -f "$path" ] || return 1
  stamp=$(cat "$path" 2>/dev/null || true)
  case "$stamp" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ $(($3 - stamp)) -ge "$FM_AGY_CLIMB_DWELL" ]
}

# fm_agy_climb_admits: 0 when <candidate> is a rung a running worker could be
# returned to on the CURRENT evidence - the gate authorizes it at all (strict
# exhaustion, and its own floor), and it stands clear of that floor by the
# margin. The dwell is deliberately not part of this: that is a question about
# time, and the two callers below ask this one for different reasons.
fm_agy_climb_admits() {  # <candidate> <state-dir> <now>
  local display
  display=$(fm_agy_ladder_display "$1") || return 1
  fm_agy_ladder_check "$display" "$2" "$3" >/dev/null 2>&1 || return 1
  fm_agy_climb_clears_margin "$1" "$2" "$3"
}

# fm_agy_climb_target: the rung a worker currently on <rung> should be moved
# back up to, or a failure when there is none.
#
# HIGHEST FIRST, so the answer is the ladder's own "highest available rung" and
# not merely one step.
fm_agy_climb_target() {  # <rung> <state-dir> [<now>]
  local rung=$1 state_dir=$2 now=${3:-} candidate=1
  [ "$FM_AGY_CLIMB" != off ] || return 1
  [ -n "$now" ] || now=$(date +%s)
  while [ "$candidate" -lt "$rung" ]; do
    if fm_agy_climb_admits "$candidate" "$state_dir" "$now" \
      && fm_agy_climb_dwelt "$candidate" "$state_dir" "$now"; then
      printf '%s' "$candidate"
      return 0
    fi
    candidate=$((candidate + 1))
  done
  return 1
}

# fm_agy_climb_pending: 0 when a rung above <rung> is already clear of its
# margin and is only waiting out the dwell.
#
# This exists so a refusal cannot say something untrue. A worker on a spent rung
# with nowhere to descend to is told the ladder has nowhere to put it - and
# while a rung above it is sitting clear and merely counting down, that sentence
# is false and the wake is spurious, because the wait resolves on its own.
fm_agy_climb_pending() {  # <rung> <state-dir> [<now>]
  local rung=$1 state_dir=$2 now=${3:-} candidate=1
  [ "$FM_AGY_CLIMB" != off ] || return 1
  [ -n "$now" ] || now=$(date +%s)
  while [ "$candidate" -lt "$rung" ]; do
    if fm_agy_climb_admits "$candidate" "$state_dir" "$now" \
      && ! fm_agy_climb_dwelt "$candidate" "$state_dir" "$now"; then
      return 0
    fi
    candidate=$((candidate + 1))
  done
  return 1
}

# --- the guarded walk -------------------------------------------------------

# fm_agy_descent_capture: a bounded plain-text read of the worker's pane.
fm_agy_descent_capture() {  # <backend> <target> <label>
  fm_backend_capture "$1" "$2" "$FM_AGY_DESCENT_CAPTURE_LINES" "${3:-}" 2>/dev/null
}

# fm_agy_descent_escape: abandon the switch without selecting anything, then
# prove nothing is left behind. Used on EVERY refusal from the moment `/model`
# is typed, including the path where the picker never appeared - if it opened a
# moment after the wait gave up, a live worker would otherwise be parked in a
# modal nobody is going to close.
#
# Two things are undone, not one. Escape closes the picker; C-u clears the
# composer, because a `/model` that was typed but never submitted would
# otherwise sit there and prefix whatever the supervisor sends next.
fm_agy_descent_escape() {  # <backend> <target> <label>
  local i text
  for i in 1 2 3 4 5; do
    fm_backend_send_key "$1" "$2" Escape "${3:-}" >/dev/null 2>&1 || true
    sleep 1
    text=$(fm_agy_descent_capture "$1" "$2" "${3:-}")
    if ! fm_agy_descent_is_picker "$text"; then
      fm_backend_send_key "$1" "$2" C-u "${3:-}" >/dev/null 2>&1 || true
      return 0
    fi
  done
  return 1
}

# fm_agy_descent_switch: move a running agy worker onto <ladder-display> through
# agy's own in-session model picker.
#   0  the worker is now on that model, confirmed from both signals
#   1  nothing was changed; the printed line is why
# Every refusal path leaves the picker closed and the worker on the model it
# was already running.
fm_agy_descent_switch() {  # <backend> <target> <label> <ladder-display>
  local backend=$1 target=$2 label=$3 want=$4
  local verdict text plan key count effort i waited selected rows

  # EXACTLY ONE Enter. The shared submit helper takes a retry count and, when it
  # cannot confirm a submission, presses Enter again - which is right for an
  # ordinary prompt and dangerous here, because `/model` opens a modal: the
  # first Enter opens the picker, the composer then reads as gone rather than as
  # submitted, and the RETRY lands inside the picker and commits whatever row
  # was highlighted. Observed exactly that against agy 1.1.16, where the retry
  # re-selected the very rung the descent was trying to leave. A retry count of
  # 1 is one attempt and no retry.
  #
  # Nothing here treats the helper's verdict as the confirmation, either. Its
  # verdicts describe a composer that submitted a turn, and `/model` does not
  # start one, so "pending" is its ordinary answer for a perfectly delivered
  # command. The picker guard below is the confirmation.
  verdict=$(fm_backend_send_text_submit "$backend" "$target" '/model' 1 1 2 "$label" 2>&1) \
    || verdict=send-failed

  # GUARD: not one navigation key is sent until agy has positively drawn the
  # picker. Without this, a version that renamed or removed /model would take
  # arrow keys and an Enter straight into the composer of a live worker.
  waited=0
  while [ "$waited" -lt "$FM_AGY_DESCENT_PICKER_WAIT" ]; do
    text=$(fm_agy_descent_capture "$backend" "$target" "$label")
    fm_agy_descent_is_picker "$text" && break
    sleep 2
    waited=$((waited + 2))
  done
  if ! fm_agy_descent_is_picker "$text"; then
    fm_agy_descent_escape "$backend" "$target" "$label" \
      || { printf 'the model picker did not open within %ss (delivery reported %s) and the worker could not be returned to a clean composer' "$FM_AGY_DESCENT_PICKER_WAIT" "${verdict:-nothing}"; return 1; }
    printf 'the model picker did not open within %ss (delivery reported %s), so no keys were sent' \
      "$FM_AGY_DESCENT_PICKER_WAIT" "${verdict:-nothing}"
    return 1
  fi

  plan=$(fm_agy_descent_plan "$text" "$want") || {
    fm_agy_descent_escape "$backend" "$target" "$label" \
      || { printf 'the model picker does not offer %s and could not be closed again; the worker is parked in it' "$want"; return 1; }
    printf 'the model picker does not offer %s in a form this switch will select' "$want"
    return 1
  }
  key=${plan%% *}
  count=${plan#* }
  effort=${count#* }
  count=${count%% *}

  i=0
  while [ "$i" -lt "$count" ]; do
    fm_backend_send_key "$backend" "$target" "$key" "$label" >/dev/null 2>&1 || {
      fm_agy_descent_escape "$backend" "$target" "$label" || true
      printf 'a navigation key could not be delivered to the worker'
      return 1
    }
    sleep 0.4
    i=$((i + 1))
  done

  if [ "$effort" = high ]; then
    i=0
    while [ "$i" -lt "$FM_AGY_DESCENT_EFFORT_KEYS" ]; do
      fm_backend_send_key "$backend" "$target" Right "$label" >/dev/null 2>&1 || true
      sleep 0.3
      i=$((i + 1))
    done
  fi

  # GUARD: re-read and require the selection to be sitting on the exact target
  # row BEFORE committing. This is the guard that makes the walk safe: a
  # miscount is abandoned here, never selected.
  sleep 1
  text=$(fm_agy_descent_capture "$backend" "$target" "$label")
  if ! fm_agy_descent_is_picker "$text"; then
    printf 'the model picker closed on its own before the switch was committed'
    return 1
  fi
  rows=$(fm_agy_descent_picker_rows "$text")
  selected=$(fm_agy_descent_selected_row "$rows") || selected=
  plan=$(fm_agy_descent_row_for "$rows" "$want") || plan=
  if [ -z "$selected" ] || [ -z "$plan" ] || [ "$selected" != "${plan%%	*}" ]; then
    fm_agy_descent_escape "$backend" "$target" "$label" \
      || { printf 'the model picker settled on %s instead of %s and could not be closed again; the worker is parked in it' "${selected:-nothing}" "$want"; return 1; }
    printf 'the model picker settled on %s instead of %s, so nothing was selected' "${selected:-nothing}" "$want"
    return 1
  fi

  fm_backend_send_key "$backend" "$target" Enter "$label" >/dev/null 2>&1 || {
    fm_agy_descent_escape "$backend" "$target" "$label" || true
    printf 'the selection could not be committed'
    return 1
  }

  # GUARD: believe the switch only from agy's own acknowledgement AND the pane
  # footer, both naming the exact target.
  waited=0
  while [ "$waited" -lt "$FM_AGY_DESCENT_CONFIRM_WAIT" ]; do
    sleep 2
    waited=$((waited + 2))
    text=$(fm_agy_descent_capture "$backend" "$target" "$label")
    fm_agy_descent_confirms "$text" "$want" && return 0
  done
  fm_agy_descent_escape "$backend" "$target" "$label" || true
  printf 'the worker did not confirm it is running on %s within %ss' "$want" "$FM_AGY_DESCENT_CONFIRM_WAIT"
  return 1
}

# --- the per-poll evaluation ------------------------------------------------
#
# One line per outcome on stdout, and nothing at all in the ordinary case where
# every live agy worker is on a healthy rung:
#
#   descended <id> <from> -> <to>   the worker was moved down and confirmed
#   climbed <id> <from> -> <to>     the worker was moved back up and confirmed
#   unrecorded <id> <reason>        it moved, but the move was not written down
#   refused <id> <reason>           it was not, and the captain needs to know
#   override <id> <reason>          the captain's own override is holding it
#
# The caller decides what a line means for supervision; bin/fm-watch.sh and
# bin/fm-agy-ladder-tick.sh each turn one into a wake. Keeping the queue out of
# this file is what lets the whole decision be exercised without the watcher's
# wake, lock, and recovery graph.

# fm_agy_descent_wake_reason: the supervision wake one outcome line becomes.
# One owner for the wording, because two drivers publish it - the watcher live,
# and the turn-end entry point into the durable queue only - and a supervisor
# should not be able to tell which of them noticed.
fm_agy_descent_wake_reason() {  # <outcome-line>
  printf 'check: agy ladder %s' "$1"
}

fm_agy_descent_mark() {  # <state-dir> <name>
  printf '%s' "$1/.agy-descent-$2"
}

# fm_agy_descent_record_model: make <meta> name <model>, or fail printing why.
#
# THE DURABLE RECORD IS THE PART THAT MUST NOT BE LOST. A ladder move changes
# which model a RUNNING worker is on, and recovery takes the model from
# state/<id>.meta - bin/fm-control.sh's relaunch reads it there, and so does
# every other reader. A record still naming the rung the worker was moved OFF
# brings that worker back onto the captain's reserved quarter after any crash,
# stall, or relaunch, silently undoing the move. Observed on 2026-08-21: two
# workers reported "Model set to Gemini 3.1 Pro (High)" while their records
# still said Claude Opus 4.6 (Thinking).
#
# It REPLACES the key rather than appending one. An append left the record
# naming two models at once, the first of them still the reserved rung, and only
# the tail-wins reading convention kept that from being read as the answer.
#
# It takes the SAME per-task lock bin/fm-spawn.sh's relaunch takes before
# publishing a replacement record, so an update landing mid-publication waits
# for it instead of writing into the file that publication is about to replace -
# which is how the move would be lost with nothing to show for it.
fm_agy_descent_record_model() {  # <meta> <model>
  local meta=$1 model=$2 lock tmp dir base status=0
  if ! declare -f fm_meta_lock_path >/dev/null 2>&1 \
    || ! declare -f fm_lock_acquire_wait >/dev/null 2>&1 \
    || ! declare -f fm_lock_release >/dev/null 2>&1; then
    printf 'the shared record-lock helpers are not loaded'
    return 1
  fi
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    printf 'there is no ordinary durable record at %s' "$meta"
    return 1
  fi
  lock=$(fm_meta_lock_path "$meta") || {
    printf '%s is not a task record path' "$meta"
    return 1
  }
  fm_lock_acquire_wait "$lock" || {
    printf 'the durable record could not be locked'
    return 1
  }
  # Dot-prefixed and beside the record, the same shape fm-spawn's own
  # replacement record uses: same filesystem, so the publish is a rename, and
  # nothing that enumerates task records can see it in between.
  dir=${meta%/*}
  base=${meta##*/}
  tmp="$dir/.$base.agy-model.${BASHPID:-$$}"
  FM_AGY_RECORD_MODEL=$model awk '
    BEGIN { done = 0 }
    /^model=/ {
      if (!done) { print "model=" ENVIRON["FM_AGY_RECORD_MODEL"]; done = 1 }
      next
    }
    { print }
    END { if (!done) print "model=" ENVIRON["FM_AGY_RECORD_MODEL"] }
  ' "$meta" > "$tmp" 2>/dev/null && mv -f "$tmp" "$meta" 2>/dev/null || status=1
  rm -f "$tmp" 2>/dev/null || true
  fm_lock_release "$lock" || true
  if [ "$status" -ne 0 ]; then
    printf 'the durable record at %s could not be rewritten' "$meta"
    return 1
  fi
  return 0
}

fm_agy_descent_clear_task() {  # <state-dir> <id>
  rm -f "$(fm_agy_descent_mark "$1" "below-$2")" \
        "$(fm_agy_descent_mark "$1" "escalated-$2")" 2>/dev/null || true
}

# fm_agy_descent_due: 0 when FM_AGY_DESCENT_INTERVAL has elapsed since the last
# evaluation. The marker is stamped by the caller only after an evaluation
# actually ran, so a home that never has an agy worker never starts a clock.
fm_agy_descent_due() {  # <state-dir> [<now>]
  local marker=$1/.agy-descent-last now=${2:-} stamp
  [ -f "$marker" ] || return 0
  [ -n "$now" ] || now=$(date +%s)
  stamp=$(cat "$marker" 2>/dev/null || true)
  case "$stamp" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ $((now - stamp)) -ge "$FM_AGY_DESCENT_INTERVAL" ]
}

# fm_agy_descent_tick: one evaluation of this home's live agy workers.
#
# SINGLE-FLIGHT, because there is more than one driver now. The watcher polls it
# between firstmate's turns and every agy worker's turn end drives it from the
# worker's own process tree, so two evaluations can genuinely overlap - and an
# overlap would pay for two quota subprocesses and, far worse, could drive two
# guarded picker walks into the SAME live pane at once. The lock is held for the
# whole evaluation and never waited on: a caller that finds an evaluation already
# running has nothing to add, because the running one reads the same fleet.
fm_agy_descent_tick() {  # <state-dir> [<now>]
  local state_dir=$1 now=${2:-} lock rc=0

  [ "$FM_AGY_DESCENT" != off ] || return 0
  [ -d "$state_dir" ] || return 0
  [ -n "$now" ] || now=$(date +%s)

  if ! declare -f fm_lock_try_acquire >/dev/null 2>&1 \
    || ! declare -f fm_lock_release >/dev/null 2>&1; then
    # Unreachable in production - this file loads that owner itself when a
    # caller has not - but a broken load must not degrade into an evaluation
    # that quietly never runs. Said once per home, because a wake per poll for
    # a condition nobody can clear from a notification is its own failure.
    if [ ! -f "$state_dir/.agy-descent-nolock" ]; then
      : > "$state_dir/.agy-descent-nolock" 2>/dev/null || true
      printf 'refused the ladder evaluation cannot run at all: its shared lock helpers are not loaded, so no running worker is being kept off the reserved rung\n'
    fi
    return 0
  fi
  rm -f "$state_dir/.agy-descent-nolock" 2>/dev/null || true
  lock="$state_dir/.agy-descent.lock"
  fm_lock_try_acquire "$lock" || return 0
  _fm_agy_descent_tick_locked "$state_dir" "$now" || rc=$?
  fm_lock_release "$lock" || true
  return "$rc"
}

_fm_agy_descent_tick_locked() {  # <state-dir> <now>
  local state_dir=$1 now=$2
  local meta id harness model rung target_rung target_display backend endpoint
  local label verdict text footer below stamp reason any=1 unrecorded
  local direction spent climb_failed moved

  # Cheap pre-filter: does this home run any agy worker on a rung at all? A home
  # with none must not pay for the quota subprocess, and must not start the
  # evaluation clock either.
  for meta in "$state_dir"/*.meta; do
    [ -e "$meta" ] || continue
    case "$(fm_meta_get "$meta" harness)" in agy*) ;; *) continue ;; esac
    fm_agy_ladder_rung "$(fm_meta_get "$meta" model)" >/dev/null 2>&1 || continue
    any=0
    break
  done
  [ "$any" -eq 0 ] || return 0
  fm_agy_descent_due "$state_dir" "$now" || return 0
  printf '%s' "$now" > "$state_dir/.agy-descent-last" 2>/dev/null || true

  # ONE refresh for the whole fleet, ahead of every decision, exactly as the
  # launch gate does it: the poll answers every rung at once, and each worker's
  # own floor and the rungs above it are read from that single reading.
  fm_agy_quota_poll "$state_dir" "$now" || true

  # Then advance the per-rung climb timers once, on that one reading, before any
  # worker is looked at. Doing it here rather than per worker is what makes two
  # workers on the same rung share one answer.
  fm_agy_climb_dwell_tick "$state_dir" "$now"

  for meta in "$state_dir"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    harness=$(fm_meta_get "$meta" harness)
    case "$harness" in agy*) ;; *) continue ;; esac
    model=$(fm_meta_get "$meta" model)
    rung=$(fm_agy_ladder_rung "$model") || continue
    endpoint=$(fm_backend_target_of_meta "$meta")
    [ -n "$endpoint" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    label="fm-$id"

    # WHERE DOES THE LADDER SAY THIS WORKER BELONGS? Up is asked first, and that
    # order is load-bearing rather than a preference. A worker whose own rung is
    # spent has two possible answers, and before the climb existed only one of
    # them was reachable: with rung 2 dead and rung 1 reset, descending to rung 3
    # is refused - correctly, because rung 1 is not exhausted and so rung 3 is
    # not the highest available rung - and the worker was reported stuck on a
    # spent ladder while the top of that ladder sat free. Asking upwards first
    # resolves that case instead of escalating it.
    spent=0
    if fm_agy_descent_needed "$rung" "$state_dir" "$now"; then
      spent=1
    fi

    direction=
    target_rung=
    climb_failed=$(fm_agy_climb_mark "$state_dir" "failed-$id")
    if target_rung=$(fm_agy_climb_target "$rung" "$state_dir" "$now"); then
      direction=up
    else
      # The rung stopped being climbable, so any earlier failure to reach it
      # belongs to a finished episode and must not suppress the next attempt.
      rm -f "$climb_failed" 2>/dev/null || true
    fi
    if [ "$direction" = up ] && [ -f "$climb_failed" ]; then
      # Already attempted and refused while this rung has been climbable.
      # Retrying would drive the modal picker into a live pane every minute for
      # an optimisation, so it waits for the rung to lapse and come back.
      direction=
      target_rung=
    fi
    if [ -z "$direction" ] && [ "$spent" = 1 ]; then
      if target_rung=$(fm_agy_descent_target "$rung" "$state_dir" "$now"); then
        direction=down
      else
        target_rung=
      fi
    fi

    if [ -z "$direction" ] && [ "$spent" = 0 ]; then
      # On a healthy rung with nowhere better to be: the ordinary case, silent,
      # and the end of whatever episode this worker was in.
      fm_agy_descent_clear_task "$state_dir" "$id"
      fm_agy_climb_clear_task "$state_dir" "$id"
      continue
    fi

    # The below-the-floor clock is the DESCENT's, and only a worker actually
    # below its floor starts one. A worker merely waiting to climb is not on a
    # clock, because not having climbed yet is not a harm to time out.
    below=$(fm_agy_descent_mark "$state_dir" "below-$id")
    stamp=$now
    if [ "$spent" = 1 ]; then
      if [ ! -f "$below" ]; then
        printf '%s' "$now" > "$below" 2>/dev/null || true
      else
        stamp=$(cat "$below" 2>/dev/null || true)
        case "$stamp" in ''|*[!0-9]*) stamp=$now ;; esac
      fi
    fi

    # The captain's own escape, honoured in BOTH directions: a worker they
    # deliberately put past the ladder is not quietly dragged off it either way.
    # Only the downward case is printed, and for the reason the launch gate
    # prints it - a pinned worker below its floor is spending the reserve. A
    # pinned worker on a slower rung than it could have is what they asked for,
    # so that case stays silent rather than waking them about it.
    if [ -n "${FM_AGY_LADDER_OVERRIDE:-}" ]; then
      if [ "$spent" = 1 ]; then
        fm_agy_descent_escalate_once "$state_dir" "$id" \
          && printf 'override %s %s is below its floor but FM_AGY_LADDER_OVERRIDE=%s is holding it there\n' \
            "$id" "$model" "$FM_AGY_LADDER_OVERRIDE"
      fi
      continue
    fi

    if [ -z "$direction" ]; then
      # A climb that is only waiting out its dwell is a bounded wait that clears
      # on its own, and while one is running the refusal below would be untrue.
      if fm_agy_climb_pending "$rung" "$state_dir" "$now"; then
        continue
      fi
      fm_agy_descent_escalate_once "$state_dir" "$id" \
        && printf 'refused %s %s is at or below its floor and the ladder has nowhere to move it: no lower rung can be shown to be available, and no rung above it has reset clear of its own floor\n' \
          "$id" "$model"
      continue
    fi
    target_display=$(fm_agy_ladder_display "$target_rung")

    # GUARD: act only on a worker whose turn state is POSITIVELY idle, from
    # agy's own lifecycle hooks. Driving a modal picker into a pane mid-turn is
    # exactly where a rendered walk is least safe, and a worker that has not
    # finished its turn will be caught on the next evaluation instead.
    text=$(fm_agy_descent_capture "$backend" "$endpoint" "$label")
    verdict=$(fm_busy_classify_meta "$meta" "$id" "$state_dir" "$text" 2>/dev/null || true)
    case "${verdict%% *}" in
      idle) ;;
      *)
        # A busy worker is retried on the next evaluation in both directions.
        # Only the downward case is ever escalated for never settling, because
        # only that one leaves a worker below its floor; a climb that has not
        # happened yet costs a slower model, which is not worth a wake.
        if [ "$spent" = 1 ] && [ $((now - stamp)) -ge "$FM_AGY_DESCENT_GRACE" ]; then
          fm_agy_descent_escalate_once "$state_dir" "$id" \
            && printf 'refused %s has been on %s below its floor for %ss without ever being safely interruptible (%s), so it was never moved to %s\n' \
              "$id" "$model" "$((now - stamp))" "${verdict:-unreadable}" "$target_display"
        fi
        continue
        ;;
    esac

    # GUARD: the durable record and the running worker must agree on which model
    # is loaded. A disagreement means firstmate's record does not describe this
    # worker, and every count below is derived from that record.
    footer=$(fm_agy_footer_model "$text" 2>/dev/null || true)
    if [ -n "$footer" ] && [ "$footer" != "$model" ]; then
      fm_agy_descent_escalate_once "$state_dir" "$id" \
        && printf 'refused %s is recorded on %s but its worker reports %s; nothing was changed while the two disagree\n' \
          "$id" "$model" "$footer"
      continue
    fi

    # The SAME guarded walk in both directions. It is one mechanism, and the
    # direction only decides which word the outcome is reported under - which
    # also means the climb inherits the one-Enter rule that stops the shared
    # submit helper's retry committing a row nobody chose.
    if reason=$(fm_agy_descent_switch "$backend" "$endpoint" "$label" "$target_display"); then
      # THE MOVE IS NOT FINISHED UNTIL IT IS WRITTEN DOWN. The worker is already
      # on the new model at this point, so the record is the only thing that can
      # still be lost - and losing it is not a missed notification, it is a
      # recovery that puts this worker straight back onto the model the ladder
      # just took it off. It is therefore written BEFORE the outcome is reported,
      # and a failure to write it is reported instead of the move, never
      # alongside a line that says the move succeeded.
      if ! unrecorded=$(fm_agy_descent_record_model "$meta" "$target_display"); then
        fm_agy_descent_escalate_once "$state_dir" "$id" \
          && printf 'unrecorded %s is now running on %s but its durable record still names %s (%s), so a relaunch would bring it back onto %s\n' \
            "$id" "$target_display" "$model" "$unrecorded" "$model"
        continue
      fi
      fm_agy_descent_clear_task "$state_dir" "$id"
      fm_agy_climb_clear_task "$state_dir" "$id"
      if [ "$direction" = up ]; then moved=climbed; else moved=descended; fi
      printf '%s %s %s -> %s\n' "$moved" "$id" "$model" "$target_display"
    else
      # A failed climb is reported once and then left alone until the rung stops
      # being climbable; a failed descent keeps retrying, because reaching a
      # safe rung matters more than the cost of trying again.
      if [ "$direction" = up ]; then
        : > "$climb_failed" 2>/dev/null || true
      fi
      fm_agy_descent_escalate_once "$state_dir" "$id" \
        && printf 'refused %s could not be moved from %s to %s: %s\n' \
          "$id" "$model" "$target_display" "$reason"
    fi
  done
}

# fm_agy_descent_turn_end: the evaluation a worker's own turn end drives, with
# its outcome published where firstmate will find it even though nothing is
# listening at the time.
#
# THIS IS THE DRIVER THE WATCHER CANNOT BE. bin/fm-watch.sh is armed by firstmate
# when firstmate goes to wait and exits as soon as it has something to say, so it
# runs between firstmate's turns and never during one - which made the captain's
# reserved quarter conditional on how long a turn happens to last. Every agy
# worker fires firstmate's own Stop hook at the end of every turn it takes, in
# the WORKER's process tree, so this runs on the schedule of the thing spending
# the quota rather than the thing supervising it.
#
# THE OUTCOME IS QUEUED, NEVER PRINTED AT ANYONE. There is no watcher process to
# wake here, so the durable queue is the whole delivery: firstmate reads it on
# its next wake-handling turn or at session start. The record is published even
# when a later one fails, because losing one outcome must not swallow the rest.
#
# The queue is addressed by <state-dir> rather than by whatever home the ambient
# environment happens to name, so this evaluates and publishes for exactly the
# home it was asked about.
fm_agy_descent_turn_end() {  # <state-dir> [<now>]
  local state_dir=$1 now=${2:-} line status=0
  # Deliberate dynamic scope: fm_wake_append resolves these from the environment
  # it was loaded into, and binding them here is what makes this function publish
  # for the home it was ASKED about rather than for whichever home the ambient
  # environment happens to name.
  # shellcheck disable=SC2034 # Read by fm_wake_append under bash's dynamic scope.
  local STATE=$state_dir
  # shellcheck disable=SC2034 # Read by fm_wake_append under bash's dynamic scope.
  local FM_WAKE_QUEUE="$state_dir/.wake-queue"
  # shellcheck disable=SC2034 # Read by fm_wake_append under bash's dynamic scope.
  local FM_WAKE_QUEUE_LOCK="$state_dir/.wake-queue.lock"

  declare -f fm_wake_append >/dev/null 2>&1 || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fm_wake_append check agy-ladder "$(fm_agy_descent_wake_reason "$line")" || status=1
  done < <(fm_agy_descent_tick "$state_dir" "$now" 2>/dev/null || true)
  return "$status"
}

# fm_agy_descent_escalate_once: 0 the first time a task needs escalating in this
# below-the-floor episode, 1 afterwards. An episode ends when the worker stops
# being below its floor, which clears the marker. Without this a refusal would
# wake the captain once a minute for as long as the condition lasted.
fm_agy_descent_escalate_once() {  # <state-dir> <id>
  local marker
  marker=$(fm_agy_descent_mark "$1" "escalated-$2")
  [ ! -f "$marker" ] || return 1
  : > "$marker" 2>/dev/null || true
  return 0
}
