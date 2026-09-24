#!/usr/bin/env bash
# fm-jcode-preflight.sh - refuse a jcode spawn that would wedge or go unsupervised.
#
# jcode's first-run surfaces (the onboarding wizard, and the "How would you like
# to begin?" chooser) put their options on a horizontal row and need ARROW keys
# to move the selection. Firstmate's key plane carries only Enter, Escape, and
# C-c, so it cannot answer either one - the same class of blocker Claude's
# workspace-trust dialog poses, which bin/fm-claude-trust.sh solves by
# pre-registering state before launch.
#
# jcode's gates are per-HOME rather than per-worktree, so there is nothing to
# pre-register per task: once a human has completed onboarding once, no fresh
# worktree re-opens it. That makes this a CHECK, not a fixer. It refuses rather
# than synthesising undocumented state files, matching the house rule that an
# unverified adapter is refused rather than guessed at.
#
# Usage: fm-jcode-preflight.sh [--fix] [--static]
#   --fix     set display.debug_socket = true in config.toml (the one repair
#             that is documented and reversible); everything else still only
#             reports.
#   --static  run only the checks that answer from the jcode home alone (steps
#             1-3b) and skip the live daemon probe (step 4). fm-spawn runs this
#             BEFORE the pane launch and the full check AFTER it: only a
#             launched jcode client brings the daemon up, and `jcode debug`
#             against a machine with no running server fails and starts
#             nothing, so a pre-launch live probe would refuse the first jcode
#             spawn after every reboot. Do not move the live probe pre-launch.
#
# Environment:
#   FM_JCODE_DEBUG_WAIT  seconds to keep retrying the daemon's debug query
#                        before refusing (default 10, 0 disables the retry).
#
# Exit: 0 safe to spawn; 1 refused, with the reason on stderr.
set -u

jcode_home=${JCODE_HOME:-$HOME/.jcode}
cfg="$jcode_home/config.toml"
hints="$jcode_home/setup_hints.json"
debug_wait_s=${FM_JCODE_DEBUG_WAIT:-10}
case "$debug_wait_s" in ''|*[!0-9]*) debug_wait_s=10 ;; esac
fix=0
static_only=0
for arg in "$@"; do
  case "$arg" in
    --fix) fix=1 ;;
    --static) static_only=1 ;;
    *) printf 'usage: fm-jcode-preflight.sh [--fix] [--static]\n' >&2; exit 2 ;;
  esac
done

fail() { printf 'fm-jcode-preflight: %s\n' "$1" >&2; exit 1; }

command -v jcode >/dev/null 2>&1 || fail "jcode is not on PATH"

# 1. Onboarding must already be complete. launch_count is jcode's own counter;
#    a home that has never launched will open the wizard on the crewmate's pane.
[ -f "$hints" ] || fail "no $hints - run jcode once interactively to clear onboarding"
launches=$(python3 -c "
import json,sys
try: print(json.load(open(sys.argv[1])).get('launch_count',0))
except Exception: print(0)" "$hints" 2>/dev/null)
[ "${launches:-0}" -gt 0 ] 2>/dev/null \
  || fail "onboarding not complete (launch_count=${launches:-0}); run jcode once interactively"

# 2. A provider must be connected, or every crewmate turn dies at the prompt.
#    Existence only - this never reads credential material.
[ -s "$jcode_home/auth.json" ] || fail "no provider connected; run: jcode login --provider claude"

# 3. Debug control must be on for the daemon, or fm-jcode-busy-bridge.sh
#    publishes nothing and the task can never be classified idle. That matters
#    more for jcode than for any other adapter: its interrupt key doubles as
#    quit when idle, so a task stuck at unknown must never be interrupted.
debug_on=0
[ -f "$cfg" ] && grep -qE '^[[:space:]]*debug_socket[[:space:]]*=[[:space:]]*true' "$cfg" && debug_on=1
if [ "$debug_on" -eq 0 ]; then
  if [ "$fix" -eq 1 ] && [ -f "$cfg" ]; then
    cp "$cfg" "$cfg.fm-bak.$(date +%s)"
    sed -i 's/^\([[:space:]]*\)debug_socket[[:space:]]*=[[:space:]]*false/\1debug_socket = true/' "$cfg"
    grep -qE '^[[:space:]]*debug_socket[[:space:]]*=[[:space:]]*true' "$cfg" \
      || fail "could not set display.debug_socket in $cfg"
    printf 'fm-jcode-preflight: set display.debug_socket = true (daemon restart required)\n' >&2
  else
    fail "display.debug_socket is not true in $cfg; re-run with --fix"
  fi
fi

# 3b. Firstmate owns dispatch. jcode can spawn and coordinate its OWN swarm
#     workers (the `swarm` tool: "spawn workers with a prompt"; config allows up
#     to swarm_max_concurrent_agents, default 32), and can queue future runs via
#     `schedule` / `initiative`, and run unattended via [ambient]. Any of those
#     produce agents with NO task record, NO worktree, and NO supervision - work
#     firstmate cannot see, steer, interrupt, or tear down.
#
#     These are refused rather than fixed: silently rewriting a captain's own
#     jcode config would change their interactive sessions too. bin/fm-lint and
#     the adapter doc record the required values.
swarm_on=0
grep -qE '^[[:space:]]*swarm[[:space:]]*=[[:space:]]*true' "$cfg" 2>/dev/null && swarm_on=1
if [ "$swarm_on" -eq 1 ]; then
  fail "[features] swarm = true in $cfg; firstmate owns dispatch. Set swarm = false so a crewmate cannot spawn unsupervised workers"
fi
for t in swarm schedule initiative; do
  grep -qE "^[[:space:]]*disabled[[:space:]]*=.*\"$t\"" "$cfg" 2>/dev/null     || fail "[tools] disabled in $cfg must list \"$t\"; without it a crewmate can start work firstmate cannot supervise"
done
if grep -qE '^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true' "$cfg" 2>/dev/null; then
  if sed -n '/^\[ambient\]/,/^\[/p' "$cfg" 2>/dev/null | grep -qE '^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true'; then
    fail "[ambient] enabled = true in $cfg; ambient mode runs unattended turns outside firstmate's dispatch"
  fi
fi

if [ "$static_only" -eq 1 ]; then
  printf 'fm-jcode-preflight: ok (onboarding done, provider connected, dispatch owned by firstmate)\n'
  exit 0
fi

# 4. The daemon must actually answer a debug query. This is the only check that
#    proves the bridge will work, rather than inferring it from config.
#
#    Bounded RETRY rather than a single call: jcode's daemon is started lazily
#    and a cold one loses the first query while it is still binding its debug
#    socket. Observed 2026-09-23 - this check refused a legitimate spawn with
#    "daemon did not answer", and the identical command run seconds later
#    reported ok with no intervention. A first-call miss is therefore a cold
#    daemon, not a misconfigured one, and refusing on it costs a real spawn.
#    A daemon that is genuinely down still fails, just after the window: every
#    attempt in it must miss, so this widens the evidence rather than weakening
#    the check. The window is bounded so a wedged daemon cannot stall a spawn.
debug_answered=0
waited=0
while :; do
  if JCODE_DEBUG_CONTROL=1 jcode debug sessions >/dev/null 2>&1; then
    debug_answered=1
    break
  fi
  [ "$waited" -lt "$debug_wait_s" ] || break
  waited=$((waited + 1))
  sleep 1
done
[ "$debug_answered" -eq 1 ] \
  || fail "daemon did not answer 'jcode debug sessions' within ${debug_wait_s}s; restart it so the new setting takes effect"

printf 'fm-jcode-preflight: ok (onboarding done, provider connected, debug control live)\n'
exit 0
