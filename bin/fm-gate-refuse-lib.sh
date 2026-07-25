#!/usr/bin/env bash
# fm-gate-refuse-lib.sh - fail-closed refusal that keeps a no-mistakes GATE agent
# out of firstmate's fleet lifecycle.
#
# The hazard (data/nm-gate-ambient-authority-containment-c3/report.md): a
# no-mistakes gate agent runs inside a firstmate checkout with a free shell, so
# it auto-loads firstmate's AGENTS.md, adopts the captain identity, and - seeing
# crewmate "in flight" - reaches for fm-spawn.sh/fm-send.sh/fm-teardown.sh to
# "delegate" and "reconcile" the shared worktree. It has real capability because
# those entrypoints self-locate their home and never knew a gate context existed.
#
# no-mistakes owns the authority-removal half (it neutralizes the project
# instructions and stamps NO_MISTAKES_GATE into the gate agent's environment).
# THIS is the firstmate capability-removal half: an enforceable script refusal,
# not a prose rule the neutralized agent would never read. It is sourced at the
# top of the fleet-lifecycle and merge entrypoints and called before any fleet
# mutation, so a gate agent that still reaches for the fleet is stopped cold.
#
# Two independent signals, either of which refuses (fail closed):
#
#   1. NO_MISTAKES_GATE set - the durable env marker no-mistakes stamps into every
#      gate agent. This is the primary signal and covers a relocated NM_HOME.
#   2. Either the caller's current checkout or this script's checkout has a
#      git-common-dir under a no-mistakes gate repo
#      (.../.no-mistakes/repos/*.git) - the UNSPOOFABLE backstop. Checking both
#      preserves refusal after cd-away and when a normal checkout's script is
#      invoked by absolute path from a gate worktree. Its limit: the literal-path
#      match only fires for the default NM_HOME (~/.no-mistakes); a relocated
#      NM_HOME is covered by signal 1.
#
# A NORMAL firstmate session - a real primary checkout, a real treehouse/Orca
# crewmate worktree - has NEITHER signal and is COMPLETELY unaffected: the function
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
# Guarded direct mutators: fm-account-continuation.sh,
# fm-account-session-sync.sh, fm-afk-launch.sh, fm-afk-start.sh,
# fm-backlog-handoff.sh, fm-bootstrap.sh, fm-brief.sh, fm-config-push.sh,
# fm-checkout-refresh.sh, fm-ensure-agents-md.sh, fm-fleet-sync.sh,
# fm-home-seed.sh, fm-lock.sh,
# fm-merge-local.sh, fm-pr-check.sh, fm-pr-merge.sh, fm-promote.sh,
# fm-report-retention.sh, fm-report-stack.mjs, fm-review-diff.sh, fm-send.sh,
# fm-session-start.sh, fm-spawn.sh, fm-supervise-daemon.sh,
# fm-task-file-append.mjs, fm-teardown.sh, fm-update.sh, fm-wake-drain.sh,
# fm-watch-arm.sh, fm-watch-checkpoint.sh, fm-watch.sh, fm-x-dismiss.sh,
# fm-x-followup.sh, fm-x-link.sh, fm-x-poll.sh, and fm-x-reply.sh.
# The Node entrypoints (fm-report-stack.mjs and fm-task-file-append.mjs)
# cannot source this library; each replicates the refusal in-process with the
# same signals, messages, and exit code - keep the replicas in lockstep.
# Excluded read-only entrypoints: fm-arm-command-policy.mjs,
# fm-arm-pretool-check.sh, fm-bearings-snapshot.sh, fm-cd-command-policy.mjs,
# fm-cd-pretool-check.sh, fm-crew-state.sh, fm-dispatch-select.sh,
# fm-fleet-snapshot.sh, fm-fleet-view.sh, fm-guard.sh, fm-harness.sh,
# fm-peek.sh, fm-project-mode.sh, and fm-supervision-instructions.sh.
# Excluded sourced libraries have no mutating command-line dispatch:
# backends/cmux.sh, backends/herdr.sh, backends/orca.sh, backends/tmux.sh,
# backends/zellij.sh, fm-account-routing-lib.sh, fm-backend-hometag-lib.sh,
# fm-backend.sh, fm-classify-lib.sh, fm-composer-lib.sh,
# fm-config-inherit-lib.sh, fm-ff-lib.sh, fm-gate-refuse-lib.sh,
# fm-lock-lib.sh, fm-marker-lib.sh, fm-report-contract-lib.sh,
# fm-supervision-lib.sh, fm-supervisor-target-lib.sh, fm-tangle-lib.sh,
# fm-tasks-axi-lib.sh, fm-tmux-lib.sh, fm-transition-lib.sh, fm-wake-lib.sh,
# and fm-x-lib.sh.
# Excluded pure helpers are not entrypoints: backends/herdr-eventwait.py,
# fm-contained-read.cjs, fm-contained-read.py, fm-file-transaction.cjs,
# fm-markdown-structure.cjs, and fm-prompt-exec.py carry no fleet dispatch of
# their own and are reached only through the entrypoints and libraries above,
# so they inherit the caller's refusal.
# fm-herdr-lab.sh is excluded because it accepts only isolated fm-lab-* sessions
# and protects the live default session with its own tripwire.
# fm-install-shellcheck.sh and fm-lint.sh are excluded developer verification
# tools and never mutate fleet, project, or captain data.
# fm-turnend-guard.sh and fm-turnend-guard-grok.sh are excluded harness hooks:
# the predicate is read-only, and the Grok adapter invokes that predicate rather
# than a fleet control-plane mutation.
# Sourced by those guarded shell entrypoints and the tests.
# No side effects on source. set -u / set -e safe. The refusal is a hard exit,
# not a return, because there is no safe way to continue a fleet mutation from a
# gate context.

# The exit code every refusal uses, distinct enough to recognize in a caller or
# test as "the gate refusal fired" rather than an ordinary usage error.
FM_GATE_REFUSE_EXIT=3

# fm_refuse_if_gate_agent: exit FM_GATE_REFUSE_EXIT with a clear stderr message if
# this process looks like a no-mistakes gate agent. Call before any fleet
# mutation. No-ops (returns 0) for a normal firstmate session, or when firstmate's
# own test harness sets FM_GATE_REFUSE_BYPASS=1 (see the header).
fm_refuse_if_gate_agent() {
  if [ "${FM_GATE_REFUSE_BYPASS:-}" = 1 ]; then
    return 0
  fi
  if [ "${NO_MISTAKES_GATE+x}" = x ]; then
    echo "error: no-mistakes gate agent must not drive the fleet (NO_MISTAKES_GATE set)" >&2
    exit "$FM_GATE_REFUSE_EXIT"
  fi
  local caller checkout common common_raw source_dir
  caller=$(pwd -P 2>/dev/null || true)
  source_dir=${BASH_SOURCE[0]%/*}
  [ "$source_dir" != "${BASH_SOURCE[0]}" ] || source_dir=.
  checkout=$(cd "$source_dir/.." 2>/dev/null && pwd -P || true)
  for checkout in "$caller" "$checkout"; do
    [ -n "$checkout" ] || continue
    common_raw=$(git -C "$checkout" rev-parse --git-common-dir 2>/dev/null || true)
    case "$common_raw" in
      /*) common=$(cd "$common_raw" 2>/dev/null && pwd -P || true) ;;
      '') common= ;;
      *) common=$(cd "$checkout/$common_raw" 2>/dev/null && pwd -P || true) ;;
    esac
    case "$common" in
      */.no-mistakes/repos/*.git)
        echo "error: refusing fleet lifecycle from inside a no-mistakes gate worktree ($common)" >&2
        exit "$FM_GATE_REFUSE_EXIT" ;;
    esac
  done
}
