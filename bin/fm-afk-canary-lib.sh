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
# WHICH pane gets probed is its own question, and the wrong answer is a false
# all-clear. A live daemon's target is whatever pane it was launched with, not the
# pane its observers happen to be running in - see fm_afk_canary_daemon_endpoint.
# Resolving the pane from the running process is still a live read, not a cache:
# the verdict for that pane is probed fresh every single time.
#
# Callers: bin/fm-supervise-daemon.sh (arm time, for its startup log record; it
# already holds its own validated endpoint, so it calls fm_afk_canary_warn directly),
# bin/fm-afk-launch.sh (the FOREGROUND arm path, the channel firstmate actually
# reads), and bin/fm-bootstrap.sh (session start, as the AFK_INJECTION_DISABLED
# diagnostic, so a cold or restarted session still surfaces it). The latter two are
# OBSERVERS - they must both enter through fm_afk_canary_resolve, so they cannot
# drift into disagreeing about the same supervisor.
#
# Source bin/fm-backend.sh (fm_backend_agent_alive, fm_backend_target_exists) and
# bin/fm-supervisor-target-lib.sh (discover_supervisor_target/_backend) first.

FM_AFK_CANARY_RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
FM_AFK_CANARY_TAB=$(printf '\t')

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
# `unknown` are DIFFERENT problems and must never share one line.
#
# `dead` is definite: the probe read the target's foreground process and it is a
# bare shell, while firstmate is provably running somewhere. The TARGET points at
# the wrong pane - a fixable misconfiguration.
#
# `unknown` is genuinely AMBIGUOUS and must be worded as such. fm_backend_agent_alive
# returns it for any foreground command outside its known set - an unattributable
# harness (pi execs into a generic `node`), but equally a wrapper, another runtime,
# or a pane it could not read at all - and fm_afk_canary_verdict normalizes a probe
# error into it too. Only the first of those is the accepted degradation, so naming
# it as the cause would send a captain whose pane is simply unreadable off to accept
# a problem they could have fixed.
fm_afk_canary_cause() {  # <verdict> <backend> <target>
  case "$1" in
    dead)
      printf "supervisor target '%s' on backend '%s' is a bare shell, not the pane running firstmate" "$3" "$2"
      ;;
    *)
      printf "liveness could not be confirmed for target '%s' on backend '%s' - either firstmate's harness cannot be attributed there (pi runs as a generic node) or that pane could not be read" "$3" "$2"
      ;;
  esac
}

# fm_afk_canary_fix: what to do about it, branched on the same distinction. The
# `unknown` remediation must cover BOTH of its causes and must not open with a
# confident "do nothing" - that is only right once the target is confirmed.
fm_afk_canary_fix() {  # <verdict>
  case "$1" in
    dead)
      printf "point FM_SUPERVISOR_TARGET at firstmate's own pane and re-arm away mode"
      ;;
    *)
      printf "check that FM_SUPERVISOR_TARGET still names firstmate's own pane and re-arm away mode; if it does, this harness is simply unattributable on this backend - an accepted degradation, and escalations still reach the captain through the wedge alarm and the afk-exit catch-up, or arm away mode on an attributable harness (claude, codex, opencode, grok)"
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
#
# For the DAEMON, which already holds its own validated backend/target. The two
# observing surfaces must go through fm_afk_canary_resolve instead, because they
# do not know the endpoint yet.
fm_afk_canary_warn() {  # <backend> <target>
  local verdict
  verdict=$(fm_afk_canary_verdict "$1" "$2")
  printf '%s' "$verdict"
  [ "$verdict" = alive ] && return 0
  fm_afk_canary_banner "$verdict" "$1" "$2" >&2
  return 1
}

# fm_afk_canary_daemon_endpoint: the endpoint a LIVE away-mode daemon is actually
# injecting into, printed as "<backend>\t<target>". Returns 1 when no live daemon
# owns the lock, or when it left no endpoint record.
#
# The daemon fixes its target ONCE, at launch, and the launcher's already-running
# path refuses to retarget a live one - so after firstmate restarts into a new pane
# with state/.afk still set, the daemon is still injecting into the OLD pane. Asking
# the current pane whether an agent is alive would answer a question nobody asked,
# and answer it reassuringly. The daemon publishes the real endpoint into its lock
# dir (bin/fm-supervise-daemon.sh), which exists only while it holds the lock.
#
# Reading it is not a cached verdict: this resolves WHICH pane to probe, and the
# probe itself still runs live below. The pid gate keeps a crashed daemon's leftover
# lock from speaking for a process that is gone.
fm_afk_canary_daemon_endpoint() {  # <state-dir>
  local lock="$1/.supervise-daemon.lock" pid record
  pid=$(cat "$lock/pid" 2>/dev/null) || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  case "$(ps -p "$pid" -o command= 2>/dev/null)" in
    *fm-supervise-daemon*) ;;
    *) return 1 ;;
  esac
  record=$(cat "$lock/supervisor-endpoint" 2>/dev/null) || return 1
  case "$record" in
    *"$FM_AFK_CANARY_TAB"*) printf '%s' "$record" ;;
    *) return 1 ;;
  esac
}

# fm_afk_canary_resolve: THE resolve -> existence-gate -> probe sequence, owned
# once so the two observable surfaces (bin/fm-afk-launch.sh's foreground arm path,
# bin/fm-bootstrap.sh's session-start diagnostic) cannot answer differently about
# the same supervisor. Each caller decides only how to render the result.
#
# Prints "<backend>\t<target>\t<verdict>" and returns:
#   0 - injection is live (verdict `alive`); say nothing.
#   1 - injection is disabled; report it with fm_afk_canary_cause/_fix or the banner.
#   2 - nothing to report. The supervisor pane could not be resolved, or does not
#       exist on its backend. An unresolvable pane stays QUIET rather than inventing
#       a failure: without a pane there is no foreground process to read, so every
#       verdict it could produce would be a guess dressed up as a diagnosis.
fm_afk_canary_resolve() {  # <state-dir>
  local record backend target verdict
  if record=$(fm_afk_canary_daemon_endpoint "$1"); then
    backend=${record%%"$FM_AFK_CANARY_TAB"*}
    target=${record#*"$FM_AFK_CANARY_TAB"}
  else
    target=$(discover_supervisor_target) || return 2
    backend=$(discover_supervisor_backend) || return 2
  fi
  [ -n "$backend" ] && [ -n "$target" ] || return 2
  fm_backend_target_exists "$backend" "$target" || return 2
  verdict=$(fm_afk_canary_verdict "$backend" "$target")
  printf '%s%s%s%s%s' "$backend" "$FM_AFK_CANARY_TAB" "$target" "$FM_AFK_CANARY_TAB" "$verdict"
  [ "$verdict" = alive ] && return 0
  return 1
}
