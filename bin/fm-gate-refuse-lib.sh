#!/usr/bin/env bash
# fm-gate-refuse-lib.sh - refuse no-mistakes gate lifecycle calls against the
# real fleet while allowing marked disposable lab homes.
#
# The hazard (data/nm-gate-ambient-authority-containment-c3/report.md): a
# no-mistakes gate agent runs inside a firstmate checkout with a free shell, so
# it auto-loads firstmate's AGENTS.md, adopts the captain identity, and - seeing
# crew "in flight" - reaches for fm-spawn.sh/fm-send.sh/fm-teardown.sh to
# "delegate" and "reconcile" the shared worktree. It has real capability because
# those entrypoints self-locate their home and never knew a gate context existed.
#
# no-mistakes owns the authority-removal half (it neutralizes the project
# instructions and stamps NO_MISTAKES_GATE into the gate agent's environment).
# THIS is the firstmate capability boundary: an enforceable script check,
# not a prose rule the neutralized agent would never read. It is sourced by the
# four fleet-lifecycle entrypoints and called before their fleet mutation, so
# a gate agent that reaches for the real fleet is stopped cold.
#
# Two independent gate-context signals, either of which triggers the check:
#
#   1. NO_MISTAKES_GATE set - the durable env marker no-mistakes stamps into every
#      gate agent. This is the primary signal and covers a relocated NM_HOME.
#   2. The current worktree's git-common-dir resolves under a no-mistakes gate
#      repo (.../.no-mistakes/repos/*.git) - the UNSPOOFABLE backstop. It derives
#      from the checkout's real filesystem location, which the agent cannot
#      relocate without breaking the gate's own git operations, so it still
#      detects a gate even if the agent tampered NO_MISTAKES_GATE away. Its limit: the
#      literal-path match only fires for the default NM_HOME (~/.no-mistakes); a
#      relocated NM_HOME is covered by signal 1.
#
# A NORMAL firstmate session - a real primary checkout, a real treehouse/Orca
# crew worktree - has NEITHER signal and is COMPLETELY unaffected: the function
# returns 0 and the lifecycle proceeds exactly as before.
#
# THE ONE AUTHORIZED EXCEPTION - a disposable lab home: a gate agent may drive
# lifecycle against an FM_HOME that carries the FM_GATE_LAB_MARKER file, because
# bin/fm-lab-home.sh stamps it only on an empty directory
# (fm_gate_lab_mark refuses a populated dir, so the helper cannot mark a real home).
# The allowance additionally requires every FM_*_OVERRIDE to be empty or unset,
# so the lab call uses the marked home's stock layout and no override can split
# part of the "lab" back onto the real fleet. The threat model stays a CONFUSED
# agent: a hostile agent that would hand-forge the marker file is the
# adversarial case no-mistakes' neutral-execution-context and the
# HEAD-continuity guard already own, so the check is a plain token file, not a
# bound record. This is an allowance on the CAPABILITY side only:
# fm_is_gate_agent still reports the gate context, so the sessionstart
# stand-downs that read it directly are unaffected by the marker.
#
# The gate-context backstop mirrors the unspoofable-marker precedent in
# bin/fm-marker-lib.sh; the lab-home marker is deliberately not unspoofable.
# This boundary layers above no-mistakes' separately-shipping HEAD-continuity
# guard, which remains the adversarial/residual backstop.
#
# TEST-HARNESS ESCAPE HATCH (FM_GATE_REFUSE_BYPASS=1): firstmate's own test suite
# must exercise the real fleet entrypoints, but the no-mistakes gate
# runs that suite FROM a gate worktree (cwd git-common-dir under
# .no-mistakes/repos/*.git, and possibly NO_MISTAKES_GATE set) - the exact
# environment this guard refuses. So both signals would fire during firstmate's
# own validation and break unrelated tests. FM_GATE_REFUSE_BYPASS=1 makes the
# guard a no-op; firstmate's shared test helpers (tests/lib.sh and the backend
# safety helpers) export it for temp-sandbox fleet tests. The disposable lab
# primary recipe in .no-mistakes.yaml uses the marked-home allowance instead.
# This does NOT weaken the boundary against the real hazard: the threat is a
# CONFUSED-not-adversarial gate agent that runs bin/fm-spawn.sh directly after
# adopting firstmate's identity outside a lab - it never sources firstmate's
# test helpers or sets the bypass; and the adversarial
# case (an agent that would deliberately set it) is covered by no-mistakes'
# neutral-execution-context and the HEAD-continuity guard. The dedicated
# tests/fm-gate-refuse.test.sh strips the bypass so it still verifies real refusal.
#
# Sourced by the fleet lifecycle entrypoints, session-start hooks,
# bin/fm-lab-home.sh, and the tests.
# No side effects on source. set -u / set -e safe. The refusal is a hard exit,
# not a return, because an unpermitted gate call cannot safely mutate the fleet.

# The exit code every refusal uses, distinct enough to recognize in a caller or
# test as "the gate refusal fired" rather than an ordinary usage error.
FM_GATE_REFUSE_EXIT=3

# The disposable-lab-home marker file and the token line it must carry. The
# format is owned here; bin/fm-lab-home.sh is the supported writer.
FM_GATE_LAB_MARKER='.fm-lab-home'
FM_GATE_LAB_TOKEN='fm-lab-home v1'

# fm_gate_lab_home <dir>: return 0 when <dir> is a marked disposable lab home.
fm_gate_lab_home() {
  local home=${1:-}
  [ -n "$home" ] || return 1
  [ -f "$home/$FM_GATE_LAB_MARKER" ] || return 1
  [ "$(sed -n '1p' "$home/$FM_GATE_LAB_MARKER" 2>/dev/null || true)" = "$FM_GATE_LAB_TOKEN" ]
}

# fm_gate_lab_mark <dir>: stamp <dir> as a disposable lab home. Fails closed on
# any dir that is not empty, so this can never mark a populated real home.
fm_gate_lab_mark() {
  local home=${1:-} listing
  [ -n "$home" ] && [ -d "$home" ] || return 1
  listing=$(find "$home" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) || return 1
  [ -z "$listing" ] || return 1
  printf '%s\n' "$FM_GATE_LAB_TOKEN" > "$home/$FM_GATE_LAB_MARKER"
}

# fm_gate_lab_permitted: return 0 when the current call targets a marked lab
# home through a stock layout - $FM_HOME carries the marker and no
# FM_*_OVERRIDE relocation has a nonempty value.
fm_gate_lab_permitted() {
  local v
  fm_gate_lab_home "${FM_HOME:-}" || return 1
  for v in "${!FM_@}"; do
    case "$v" in
      *_OVERRIDE) [ -z "${!v}" ] || return 1 ;;
    esac
  done
  return 0
}

# fm_is_gate_agent: return 0 without output when this process looks like a
# no-mistakes gate agent. An optional root anchors the git-common-dir check;
# callers that omit it retain the historical current-worktree behavior.
fm_is_gate_agent() {
  local anchor=${1:-.} common
  if [ "${FM_GATE_REFUSE_BYPASS:-}" = 1 ]; then
    return 1
  fi
  if [ "${NO_MISTAKES_GATE+x}" = x ]; then
    FM_GATE_REFUSE_REASON='env'
    return 0
  fi
  common=$(cd "$anchor" 2>/dev/null \
    && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo /nonexistent)" 2>/dev/null \
    && pwd -P || true)
  case "$common" in
    */.no-mistakes/repos/*.git)
      FM_GATE_REFUSE_REASON='path'
      FM_GATE_REFUSE_COMMON=$common
      return 0 ;;
  esac
  return 1
}

# fm_refuse_if_gate_agent: exit FM_GATE_REFUSE_EXIT with a clear stderr message if
# this process looks like a no-mistakes gate agent without a permitted lab home.
# Call before any fleet mutation. No-ops (returns 0) for a normal firstmate
# session, a permitted lab home, or when firstmate's own test harness sets
# FM_GATE_REFUSE_BYPASS=1 (see the header).
fm_refuse_if_gate_agent() {
  fm_is_gate_agent "${1:-.}" || return 0
  if fm_gate_lab_permitted; then
    echo "fm-gate-refuse: gate agent lifecycle permitted only against lab home $FM_HOME" >&2
    return 0
  fi
  if [ "$FM_GATE_REFUSE_REASON" = env ]; then
    echo "error: no-mistakes gate agent must not drive the fleet (NO_MISTAKES_GATE set)" >&2
  else
    echo "error: refusing fleet lifecycle from inside a no-mistakes gate worktree ($FM_GATE_REFUSE_COMMON)" >&2
  fi
  exit "$FM_GATE_REFUSE_EXIT"
}
