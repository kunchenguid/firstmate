#!/usr/bin/env bash
# fm-gate-refuse-lib.sh - fail-closed refusal that keeps a no-mistakes GATE agent
# out of firstmate's fleet lifecycle.
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
# THIS is the firstmate capability-removal half: an enforceable script refusal,
# not a prose rule the neutralized agent would never read. It is sourced at the
# top of the three fleet-lifecycle entrypoints and called before any fleet
# mutation, so a gate agent that still reaches for the fleet is stopped cold.
#
# Two independent signals, either of which refuses (fail closed):
#
#   1. NO_MISTAKES_GATE set - the durable env marker no-mistakes stamps into every
#      gate agent. This is the primary signal and covers a relocated NM_HOME.
#   2. The current worktree's git-common-dir resolves under a no-mistakes gate
#      repo (.../.no-mistakes/repos/*.git) - the UNSPOOFABLE backstop. It derives
#      from the checkout's real filesystem location, which the agent cannot
#      relocate without breaking the gate's own git operations, so it still
#      refuses even if the agent tampered NO_MISTAKES_GATE away. Its limit: the
#      literal-path match only fires for the default NM_HOME (~/.no-mistakes); a
#      relocated NM_HOME is covered by signal 1.
#
# A NORMAL firstmate session - a real primary checkout, a real treehouse/Orca
# crew worktree - has NEITHER signal and is COMPLETELY unaffected: the function
# returns 0 and the lifecycle proceeds exactly as before.
#
# This mirrors the unspoofable-marker precedent in bin/fm-marker-lib.sh: a signal
# the agent cannot forge, keyed on at a chokepoint, keeping the pattern familiar
# to firstmate maintainers. It layers ABOVE no-mistakes' separately-shipping
# HEAD-continuity guard, which remains the adversarial/residual backstop.
#
# TEST-HARNESS ESCAPE HATCH (FM_GATE_REFUSE_BYPASS=1): firstmate's own test suite
# must exercise the REAL fm-spawn/fm-send/fm-teardown, but the no-mistakes gate
# runs that suite FROM a gate worktree (cwd git-common-dir under
# .no-mistakes/repos/*.git, and possibly NO_MISTAKES_GATE set) - the exact
# environment this guard refuses. So both signals would fire during firstmate's
# own validation and break unrelated tests. FM_GATE_REFUSE_BYPASS=1 makes the
# guard a no-op; firstmate's shared test helpers (tests/lib.sh and the backend
# safety helpers) export it, so every test that drives these scripts against its
# temp-sandbox fleet is exempt. This does NOT weaken the boundary against the
# real hazard: the threat is a CONFUSED-not-adversarial gate agent that runs
# bin/fm-spawn.sh directly after adopting firstmate's identity - it never sources
# firstmate's test helpers, so it never carries the bypass; and the adversarial
# case (an agent that would deliberately set it) is covered by no-mistakes'
# neutral-execution-context and the HEAD-continuity guard. The dedicated
# tests/fm-gate-refuse.test.sh strips the bypass so it still verifies real refusal.
#
# Sourced by bin/fm-spawn.sh, bin/fm-send.sh, bin/fm-teardown.sh,
# bin/fm-sessionstart-nudge.sh, and the tests.
# No side effects on source. set -u / set -e safe. The refusal is a hard exit,
# not a return, because there is no safe way to continue a fleet mutation from a
# gate context.

# The exit code every refusal uses, distinct enough to recognize in a caller or
# test as "the gate refusal fired" rather than an ordinary usage error.
FM_GATE_REFUSE_EXIT=3

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
# this process looks like a no-mistakes gate agent. Call before any fleet
# mutation. No-ops (returns 0) for a normal firstmate session, or when firstmate's
# own test harness sets FM_GATE_REFUSE_BYPASS=1 (see the header).
fm_refuse_if_gate_agent() {
  fm_is_gate_agent "${1:-.}" || return 0
  if [ "$FM_GATE_REFUSE_REASON" = env ]; then
    echo "error: no-mistakes gate agent must not drive the fleet (NO_MISTAKES_GATE set)" >&2
  else
    echo "error: refusing fleet lifecycle from inside a no-mistakes gate worktree ($FM_GATE_REFUSE_COMMON)" >&2
  fi
  exit "$FM_GATE_REFUSE_EXIT"
}
