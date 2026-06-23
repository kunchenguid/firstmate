#!/usr/bin/env bash
# Idempotently ensure the persistent firstmate tmux session exists.
#
# This is the recovery half of crash resilience (AGENTS.md section 5): a WSL VM
# teardown (host sleep, idle timeout, or a Windows Update reboot) kills the tmux
# server and every process in it, including firstmate and any crewmates. systemd
# survives the reboot but nothing relaunched firstmate - so it stayed dead until
# the captain reconnected. This script, run at boot and on a self-heal timer by
# firstmate.service (see systemd/), brings the session back automatically. The
# captain then attaches to a live, state-intact firstmate instead of a cold start.
#
# It is deliberately idempotent and safe to run repeatedly: if the session is
# already alive it is a no-op. It does NOT relaunch crewmate workers - their
# autonomous processes died with the VM and re-spawning them is firstmate's job
# via its recovery protocol once the captain is back. Worker state on disk
# (data/, state/, backlog) is untouched and survives regardless.
#
# Usage:
#   fm-resume.sh            ensure the session once, then exit
#   fm-resume.sh --watch    ensure forever, re-checking every FM_RESUME_INTERVAL
#                           seconds (the long-running ExecStart for the service)
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# How firstmate itself is launched. These mirror the captain's live session
# exactly (verified from the running process): the REAL claude binary, not the
# round-robin crew shim on PATH; the orchestrator account; sandbox + skip-perms
# because firstmate runs as root inside an isolated WSL VM.
SESSION="${FM_SESSION:-firstmate}"
FM_CLAUDE_BIN="${FM_CLAUDE_BIN:-$HOME/.local/bin/claude}"
FM_CONFIG_DIR="${FM_CONFIG_DIR:-/mnt/c/Users/Owenz/.claude-orchestrator}"
FM_RESUME_INTERVAL="${FM_RESUME_INTERVAL:-60}"

ensure_session() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    return 0
  fi

  # Build the firstmate launch command. Single-quoted values are expanded in the
  # tmux pane's shell, not here. We exec the real binary by absolute path so a
  # PATH that prefers the crew shim cannot misroute firstmate onto a worker account.
  local launch
  printf -v launch \
    'cd %q && CLAUDE_CONFIG_DIR=%q IS_SANDBOX=1 exec %q --dangerously-skip-permissions' \
    "$FM_ROOT" "$FM_CONFIG_DIR" "$FM_CLAUDE_BIN"

  # Target the session (active window) rather than a hardcoded ":0": tmux configs
  # commonly set base-index 1, so the first window is not always index 0.
  tmux new-session -d -s "$SESSION" -c "$FM_ROOT"
  tmux send-keys -t "$SESSION" "$launch" Enter
  echo "fm-resume: created session '$SESSION' running firstmate"
  return 0
}

if [ "${1:-}" = "--watch" ]; then
  while :; do
    ensure_session || true
    sleep "$FM_RESUME_INTERVAL"
  done
else
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "fm-resume: session '$SESSION' already live"
  else
    ensure_session
  fi
fi
