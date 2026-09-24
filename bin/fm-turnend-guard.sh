#!/usr/bin/env bash
# Turn-end supervision guard for Pi and Codex primary sessions.
# Exit 2 requests one bounded continuation when supervision is required but
# neither the watcher nor the authorized away daemon proves current ownership.
# Pi supplies the passive-event continuation; Codex preserves the hook status.
# Linked worker worktrees remain exempt under fm-primary-scope-lib.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
[ "$#" -eq 0 ] || { echo "usage: $(basename "$0")" >&2; exit 2; }

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then error("payload")
  elif has("stopHookActive") then
    if ((.stopHookActive | type) == "boolean") then .stopHookActive else error("stopHookActive") end
  elif has("stop_hook_active") then
    if ((.stop_hook_active | type) == "boolean") then .stop_hook_active else error("stop_hook_active") end
  else false
  end
' 2>/dev/null) || exit 0
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# --- scope precisely to a PRIMARY checkout ----------------------------------
# A genuinely-marked secondmate home runs its OWN primary firstmate session, so
# force-INCLUDE it as a guarded primary whether treehouse leased it as a linked
# worktree (git-dir != git-common-dir) or it is a git-cloned plain checkout. This
# mirrors the cd-guard's intent that a secondmate's own session is a guarded
# primary. Only an UNMARKED checkout (or one with an invalid marker) falls
# through to the linked-worktree exemption: firstmate hands out crewmate/scout
# task worktrees as genuine linked `git worktree`s (bin/fm-spawn.sh aborts
# otherwise), whose git-dir lives under the parent repo's .git/worktrees/<name>
# and differs from the common (shared) git-dir, while a main, non-worktree
# checkout has the two equal. Child worktrees never carry the gitignored marker,
# so this exempts them while guarding every real secondmate home.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_supervision_status "$STATE" "$GRACE"
if [ "$FM_SUP_NEEDED" = false ]; then
  exit 0
fi
# One owner of the "supervision is on, let this turn end" exit contract, shared
# by every proof of supervision below.
allow_supervised_stop() { exit 0; }

if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  allow_supervised_stop
fi

# Away mode transfers supervision ownership from the watcher to the away-mode
# daemon, which runs the watcher one-shot and starts its replacement after every
# wake (bin/fm-supervise-daemon.sh). A turn boundary regularly lands in that
# hand-off, when no watcher process holds the lock and nothing is wrong, so
# requiring one here alarmed on healthy away-mode supervision. A live
# identity-matched daemon holding this home is the right owner to test for.
# The beacon half of the predicate still applies: a daemon that stops
# restarting its watcher still blocks once the beacon passes grace, and a home
# with no daemon and no watcher blocks exactly as before. It uses AFK_GRACE
# (poll-cadence-derived, see the comment above) instead of the flat $GRACE
# every other check on this page uses, so a daemon that is genuinely still
# cycling - just slower than a fixed 300s window - is not misread as down.
AFK_GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}
if [ "$(fm_path_age "$STATE/.last-watcher-beat")" -lt "$AFK_GRACE" ] \
  && fm_afk_daemon_owns_supervision "$STATE"; then
  allow_supervised_stop
fi

block_stop() {
  local afk x_mode reason rule
  afk=0
  [ -e "$STATE/.afk" ] && afk=1
  x_mode=0
  [ -f "$CONFIG/x-mode.env" ] && x_mode=1
  reason=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
    || printf '%s\n' 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn')
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$rule"
    printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
    if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
      printf '●  %s task(s) in flight, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_IN_FLIGHT" "$FM_SUP_BEACON_DESC"
    elif [ "$FM_SUP_SOURCES" -gt 0 ]; then
      printf '●  %s process-event source(s) registered, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_SOURCES" "$FM_SUP_BEACON_DESC"
    elif [ "$FM_SUP_CHECKS" -gt 0 ]; then
      printf '●  %s registered custom check(s), but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_CHECKS" "$FM_SUP_BEACON_DESC"
    else
      printf '●  X-mode relay polling needs supervision, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_BEACON_DESC"
    fi
    printf '●  %s\n' "$reason"
    printf '●%s\n' "$rule"
  } >&2
  exit 2
}

block_stop
