#!/usr/bin/env bash
# fm-afk-canary-lib.sh - the single owner of the away-mode injection canary: can
# the daemon's fail-closed agent-liveness guard deliver an escalation to THIS
# supervisor at all?
#
# inject_msg (bin/fm-supervise-daemon.sh) types a digest into the supervisor pane
# only on a confident `alive` from fm_backend_agent_alive, because an empty agent
# composer and an empty shell prompt are indistinguishable by content (starship's
# default prompt glyph is the one claude draws for its own composer). That guard
# fails closed, so a supervisor whose harness a backend cannot attribute (pi execs
# into a generic `node`) refuses EVERY escalation for the whole away session, not
# for one tick. The captain has to hear that while away mode is being armed - not
# FM_MAX_DEFER_SECS later, from a wedge alarm.
#
# ALWAYS RE-DERIVED, NEVER CACHED. Every caller probes the live backend+target,
# the same way bin/fm-guard.sh's worktree-tangle check re-reads the branch instead
# of trusting a marker. A respawned agent, a retargeted supervisor pane, or a
# harness swap must change the answer on the spot, and a stored flag would answer
# from a world that no longer exists.
#
# Callers: bin/fm-supervise-daemon.sh (arm time, for its startup log record),
# bin/fm-afk-launch.sh (the FOREGROUND arm path, the channel firstmate actually
# reads), and bin/fm-bootstrap.sh (session start, as the AFK_INJECTION_DISABLED
# diagnostic, so a cold or restarted session still surfaces it).
# Source bin/fm-backend.sh first: this library calls fm_backend_agent_alive.

FM_AFK_CANARY_RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

# fm_afk_canary_verdict: the live liveness verdict for the supervisor pane,
# normalized so a probe error or an empty read becomes `unknown` - the fail-closed
# verdict inject_msg itself applies - rather than an empty string a caller could
# mistake for a passing check.
fm_afk_canary_verdict() {  # <backend> <target>
  local verdict
  verdict=$(fm_backend_agent_alive "$1" "$2" 2>/dev/null) || verdict=""
  printf '%s' "${verdict:-unknown}"
}

# fm_afk_canary_cause: why this supervisor cannot receive injections. `dead` and
# `unknown` are DIFFERENT problems and must never share one line. At arm time
# firstmate is provably running in the pane it resolved, so `dead` (a bare shell)
# means the resolved TARGET points somewhere else - a fixable misconfiguration -
# while `unknown` means the harness's process cannot be attributed on this backend,
# which is an accepted degradation and not something to repoint.
fm_afk_canary_cause() {  # <verdict> <backend> <target>
  case "$1" in
    dead)
      printf "supervisor target '%s' on backend '%s' is a bare shell, not the pane running firstmate" "$3" "$2"
      ;;
    *)
      printf "firstmate's harness cannot be attributed on backend '%s' (pi runs as a generic node), so target '%s' can never read alive" "$2" "$3"
      ;;
  esac
}

# fm_afk_canary_fix: what to do about it, branched on the same distinction.
fm_afk_canary_fix() {  # <verdict>
  case "$1" in
    dead)
      printf "point FM_SUPERVISOR_TARGET at firstmate's own pane and re-arm away mode"
      ;;
    *)
      printf 'accepted degradation, not a misconfiguration: escalations still reach the captain through the wedge alarm and the afk-exit catch-up, or arm away mode on an attributable harness (claude, codex, opencode, grok)'
      ;;
  esac
}

# fm_afk_canary_banner: the loud, bordered arm-time warning, in the same shape as
# bin/fm-guard.sh's alarms so it cannot be skimmed past in tool output. Printed on
# stdout; callers redirect it to the channel their reader actually watches.
fm_afk_canary_banner() {  # <verdict> <backend> <target>
  printf '●%s\n' "$FM_AFK_CANARY_RULE"
  printf '●  AWAY-MODE INJECTION IS DISABLED FOR THIS SUPERVISOR\n'
  printf "●  The agent-liveness probe reads '%s' (not alive) for '%s' on backend '%s',\n" "$1" "$3" "$2"
  printf '●  even though firstmate is running right now. Injection fails closed, so it will\n'
  printf '●  refuse EVERY escalation this away session rather than risk typing into a shell.\n'
  printf '●  Nothing is lost: escalations buffer, raise the wedge alarm past FM_MAX_DEFER_SECS,\n'
  printf '●  and flush on afk exit - but none will reach the pane while the captain is away.\n'
  printf '●  Cause: %s.\n' "$(fm_afk_canary_cause "$@")"
  printf '●  Fix:   %s.\n' "$(fm_afk_canary_fix "$1")"
  printf '●%s\n' "$FM_AFK_CANARY_RULE"
}

# fm_afk_canary_warn: probe live, print the banner on STDERR when this supervisor
# cannot receive injections, and echo the verdict on stdout so a caller can record
# it. Returns 0 when injection is live, 1 when it is disabled. ADVISORY ONLY: no
# caller may turn a non-alive verdict into a refusal to arm - degraded away-mode
# supervision (buffer, wedge alarm, afk-exit flush) beats none at all.
fm_afk_canary_warn() {  # <backend> <target>
  local verdict
  verdict=$(fm_afk_canary_verdict "$1" "$2")
  printf '%s' "$verdict"
  [ "$verdict" = alive ] && return 0
  fm_afk_canary_banner "$verdict" "$1" "$2" >&2
  return 1
}
