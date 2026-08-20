#!/usr/bin/env bash
# tests/fm-progress-probe-live-e2e.test.sh - the live guard for the one thing
# about supervision's progress measurement that only a real harness can answer
# (live-harness-optin family).
#
# The measurement itself is a kernel fact and needs no vendor cooperation. What
# IS a vendor fact is where each harness's own two states fall against the
# threshold, and it is a fact that a release can change:
#
#   IDLE at an empty composer must measure BELOW FM_PROGRESS_CPU_MIN_PCT, or the
#   `stalled` verdict is unreachable for that harness and a worker stopped by a
#   provider session limit goes back to being invisible - a TUI that repaints a
#   clock or a spinner while idle is all it would take.
#   MID-TURN must measure AT OR ABOVE it, or the `progressing` verdict is
#   unreachable and every long turn goes back to being escalated as a wedge.
#
# Both are measured here against every INSTALLED verified harness, on real panes,
# and the guard fails naming the harness and its version. An absent harness is
# reported explicitly rather than passed over silently, and a run that measured
# nothing fails rather than passing vacuously.
#
# It submits one prompt per harness and therefore spends model tokens, which is
# why it is opt-in. Run it after every harness upgrade, and refresh
# docs/verification/supervision.md "Progress probe" from its output.
#
# Isolation: every Herdr call goes through bin/fm-herdr-lab.sh's named
# non-default lab session, which records the live default session before
# provisioning and requires an identical fleet state after teardown.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_PROGRESS_PROBE_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_PROGRESS_PROBE_LIVE=1 to run the live progress-probe guard (spends model tokens)"
  exit 0
fi

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

command -v herdr >/dev/null 2>&1 || { echo "not ok - FM_PROGRESS_PROBE_LIVE=1 but herdr is not installed" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "not ok - FM_PROGRESS_PROBE_LIVE=1 but jq is not installed" >&2; exit 1; }

LAB=$(fm_herdr_lab_name progress-probe) || exit 1
CHECKED=0
FAILED=0
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-progress-live.XXXXXX")

cleanup() {
  fm_herdr_lab_teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

fm_herdr_lab_provision "$LAB" >/dev/null || fail "could not provision the isolated Herdr lab session"

export FM_BACKEND=herdr
export HERDR_SESSION="$LAB"
FM_BACKEND_LIB_DIR="$ROOT/bin"
export FM_BACKEND_LIB_DIR
# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-progress-lib.sh"

# The measurement span each direction is given here. Short by production
# standards on purpose, and conservative in the direction that matters: the
# threshold is a RATE, so a short window is the NOISIER one - a repaint or a
# background tick is a larger fraction of 45 seconds than of the 180 and 600 the
# library actually uses. An idle harness that stays under the threshold here
# stays under it over a production span; a working one that clears it here clears
# it there. The guard is asking where a harness's two states sit relative to the
# threshold, not re-deriving the spans.
SPAN=${FM_PROGRESS_LIVE_SPAN_SECS:-45}
BUSY_PROMPT='Without using any tools and without stopping, write a long detailed essay of at least 2000 words about the history of maritime navigation. Keep writing continuously and do not stop early.'

make_pane() {  # <label> -> pane id
  local label=$1 out ws
  out=$(fm_herdr_lab_cli "$LAB" workspace create --cwd "$WORKDIR" --label "$label" --no-focus) || return 1
  ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty')
  [ -n "$ws" ] || return 1
  out=$(fm_herdr_lab_cli "$LAB" tab create --workspace "$ws" --cwd "$WORKDIR" --label "$label" --no-focus) || return 1
  printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty'
}

harness_version() { "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'; }

# measure <target> - the CPU rate the probe reads over SPAN, in percent of one
# core, through the same subtree resolution supervision uses. Prints
# "<pct> <reading>"; returns 1 if the pane could not be measured at all.
#
# Samples directly rather than through fm_progress_probe: this guard is asking
# what a harness's two states MEASURE, and taking both readings itself keeps the
# span exactly SPAN instead of whatever a stored baseline happens to be.
measure() {
  local target=$1 pids base now delta span
  pids=$(fm_backend_agent_root_pids herdr "$target" 2>/dev/null) || return 1
  [ -n "$pids" ] || return 1
  # shellcheck disable=SC2086 # one pid per line, deliberately split into args
  base=$(fm_progress_sample $pids) || return 1
  sleep "$SPAN"
  # shellcheck disable=SC2086
  now=$(fm_progress_sample $pids) || return 1
  span=$(( $(printf '%s' "$now" | cut -d' ' -f2) - $(printf '%s' "$base" | cut -d' ' -f2) ))
  delta=$(( $(printf '%s' "$now" | cut -d' ' -f3) - $(printf '%s' "$base" | cut -d' ' -f3) ))
  [ "$span" -gt 0 ] || return 1
  printf '%s %s.%02ds of CPU over %ss' "$((delta / span))" "$((delta / 100))" "$((delta % 100))" "$span"
}

check_harness_progress() {  # <name> <launch-command-line>
  local name=$1 launch=$2 pane target version i=0 trusted=0
  local idle_reading idle_pct busy_reading busy_pct
  version=$(harness_version "$name")
  pane=$(make_pane "pp-$name") || {
    FAILED=1
    printf 'not ok - %s (%s): could not create an isolated lab pane\n' "$name" "$version" >&2
    return
  }
  target="$LAB:$pane"
  fm_herdr_lab_cli "$LAB" pane send-text "$pane" "$launch" >/dev/null || true
  sleep 0.5
  fm_herdr_lab_cli "$LAB" pane send-keys "$pane" enter >/dev/null || true
  while [ "$i" -lt 90 ]; do
    [ "$(fm_backend_herdr_composer_state "$target")" = empty ] && break
    if [ "$trusted" -eq 0 ] \
      && fm_backend_herdr_capture "$target" 25 2>/dev/null | grep -qi 'trust'; then
      fm_herdr_lab_cli "$LAB" pane send-keys "$pane" enter >/dev/null || true
      trusted=1
    fi
    i=$((i + 1))
    sleep 1
  done
  if [ "$(fm_backend_herdr_composer_state "$target")" != empty ]; then
    FAILED=1
    printf 'not ok - %s (%s): never reached an idle empty composer, so neither direction could be measured\n' \
      "$name" "$version" >&2
    return
  fi

  # Direction 1: idle at an empty composer - the shape a session-limited worker
  # is stuck in - must read BELOW the threshold, or it can never be surfaced.
  if ! idle_reading=$(measure "$target"); then
    FAILED=1
    printf 'not ok - %s (%s): an idle pane could not be measured at all; the stall alarm has no signal on this harness\n' \
      "$name" "$version" >&2
    return
  fi
  idle_pct=${idle_reading%% *}
  if [ "$idle_pct" -ge "$FM_PROGRESS_CPU_MIN_PCT" ]; then
    FAILED=1
    printf 'not ok - %s (%s): idle at an empty composer burns %s%% of a core (%s), at or above the %s%% threshold - a stopped worker on this harness would read as working and stay invisible\n' \
      "$name" "$version" "$idle_pct" "${idle_reading#* }" "$FM_PROGRESS_CPU_MIN_PCT" >&2
    return
  fi

  # Direction 2: mid-turn must read AT OR ABOVE the threshold, or every long
  # turn on this harness escalates as a possible wedge again.
  fm_backend_herdr_send_text_submit "$target" "$BUSY_PROMPT" 3 0.4 0.4 >/dev/null
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(fm_backend_herdr_agent_status_raw "$LAB" "$pane")" = working ] && break
    i=$((i + 1))
    sleep 1
  done
  if [ "$(fm_backend_herdr_agent_status_raw "$LAB" "$pane")" != working ]; then
    FAILED=1
    printf 'not ok - %s (%s): never entered a turn, so mid-turn progress could not be measured\n' \
      "$name" "$version" >&2
    return
  fi
  if ! busy_reading=$(measure "$target"); then
    FAILED=1
    printf 'not ok - %s (%s): a working pane could not be measured at all\n' "$name" "$version" >&2
    return
  fi
  busy_pct=${busy_reading%% *}
  if [ "$busy_pct" -lt "$FM_PROGRESS_CPU_MIN_PCT" ]; then
    FAILED=1
    printf 'not ok - %s (%s): a turn in flight measures only %s%% of a core (%s), below the %s%% threshold - long turns on this harness would escalate as possible wedges\n' \
      "$name" "$version" "$busy_pct" "${busy_reading#* }" "$FM_PROGRESS_CPU_MIN_PCT" >&2
    return
  fi
  CHECKED=$((CHECKED + 1))
  pass "$name ($version): idle ${idle_pct}% of a core (${idle_reading#* }), mid-turn ${busy_pct}% (${busy_reading#* }), threshold ${FM_PROGRESS_CPU_MIN_PCT}%"
}

for h in agy claude codex opencode pi grok kimi muse cursor; do
  if command -v "$h" >/dev/null 2>&1; then
    case "$h" in
      agy|claude) check_harness_progress "$h" "$h --dangerously-skip-permissions" ;;
      *) check_harness_progress "$h" "$h" ;;
    esac
  else
    note "harness absent, not verified here: $h"
  fi
done

[ "$CHECKED" -gt 0 ] || fail "the live progress-probe guard verified no harness at all; it must never pass vacuously"
[ "$FAILED" -eq 0 ] || fail "one or more installed harnesses failed the live progress-probe guard"
pass "live progress-probe guard: $CHECKED installed harness(es) separate idle from mid-turn across the threshold"
