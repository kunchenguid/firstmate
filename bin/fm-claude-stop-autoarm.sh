#!/usr/bin/env bash
# Claude Stop-owned watcher auto-arm (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "asyncRewake": true and an explicit multi-hour timeout. Claude Code fires it
# in the background on EVERY Stop of a Claude primary session, with no
# deduplication across firings. It owns routine tokenless watcher continuity
# for Claude primaries (main home and marked secondmate homes):
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session's harness ancestor holds state/.lock, so
#     a scratch or read-only session in the same checkout never arms or rewakes.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms only while work is in flight (state/*.meta) or X mode has a
#     relay poll to run (state/x-watch.check.sh); an idle home exits 0.
#   - Single-flight: Claude does not dedupe async hooks, so a home-scoped owner
#     lock (state/.claude-autoarm.lock) admits exactly one owner. One contending
#     later Stop waits as the coalesced handoff; it starts the next cycle only
#     when the predecessor closes cleanly, while duplicate firings leave after
#     the predecessor records a rewake.
#   - Foreground arm: the owner runs bin/fm-watch-arm.sh in the FOREGROUND of
#     this hook-owned process tree (never shell &); Claude owns the process
#     group, so its timeout/session teardown kills arm and watcher together.
#   - Translation: while supervision is still needed and AFK remains inactive,
#     an actionable arm close (signal:/stale:/check:/heartbeat) or a typed
#     watcher: FAILED prints one rewake banner to stderr and exits 2, which
#     wakes Claude even while idle ("Stop hook feedback"). A clean close exits
#     silently only after any overlapping Stop has a live handoff owner.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim and
# outcome so the synchronous Stop guard (bin/fm-turnend-guard.sh --claude) can
# allow a stop whose recovery this hook already owns, instead of forcing a
# duplicate continuation for the same event epoch.
#
# This hook never blocks the Stop decision itself and never prints to stdout:
# exit 0 is always silent, and exit 2 carries the rewake banner on stderr.
# Unresolvable session ancestry exits 0 and leaves continuity to the synchronous
# guard, while an ambiguous queued handoff exits 2 with an alarm.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
OWNER_LOCK="$STATE/.claude-autoarm.lock"
HANDOFF_LOCK="$STATE/.claude-autoarm-handoff.lock"
EPOCH="$STATE/.claude-autoarm-epoch"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# Consume the Stop payload once. The decisions below are state-based; the
# payload is read so a slow writer can never wedge on a full pipe.
cat >/dev/null 2>&1 || true

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may arm ------------------
fm_session_lock_owned_by_self "$STATE" || exit 0

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
[ -e "$STATE/.afk" ] && exit 0

# --- need: in-flight work or an X-mode relay poll ----------------------------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

write_epoch() {  # <outcome>
  local outcome=$1 seq tmp
  seq=$(sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$EPOCH" 2>/dev/null || true)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  tmp="$EPOCH.tmp.$$"
  printf 'epoch=%s owner_pid=%s owner_claim=%s outcome=%s updated_at=%s\n' \
    "$seq" "${BASHPID:-$$}" "$OWNER_CLAIM" "$outcome" "$(date +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$EPOCH" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

epoch_outcome_for_claim() {
  local final_newline
  final_newline=$(tail -c 1 "$EPOCH" 2>/dev/null | wc -l | tr -d '[:space:]')
  [ "$final_newline" = 1 ] || return 1
  awk -v want="$1" '
    {
      if (NR != 1 || NF != 5 ||
          $1 !~ /^epoch=[0-9][0-9]*$/ ||
          $2 !~ /^owner_pid=[0-9][0-9]*$/ ||
          $3 !~ /^owner_claim=[A-Za-z0-9._-][A-Za-z0-9._-]*$/ ||
          $4 !~ /^outcome=(arming|clean|rewake|afk)$/ ||
          $5 !~ /^updated_at=[0-9][0-9]*$/) {
        invalid = 1
        next
      }
      claim = ""; outcome = ""
      for (i = 1; i <= NF; i += 1) {
        if ($i ~ /^owner_claim=/) claim = substr($i, 13)
        else if ($i ~ /^outcome=/) outcome = substr($i, 9)
      }
      if (claim == want) found = outcome
    }
    END { if (!invalid && found != "") print found }
  ' "$EPOCH" 2>/dev/null
}

handoff_alarm() {
  write_epoch rewake
  printf 'firstmate watcher cycle FAILED - queued Stop re-arm handoff lost its predecessor outcome while this home still needs supervision.\n' >&2
  exit 2
}

OWNER_CLAIM=
PREDECESSOR_CLAIM=
if fm_lock_try_acquire "$OWNER_LOCK"; then
  OWNER_CLAIM=$(basename "${FM_LOCK_OWNER_DIR:-}")
else
  predecessor_target=$(readlink "$OWNER_LOCK" 2>/dev/null || true)
  PREDECESSOR_CLAIM=${predecessor_target##*/}
  case "$PREDECESSOR_CLAIM" in
    ''|*[!A-Za-z0-9._-]*)
      printf 'firstmate watcher cycle FAILED - queued Stop re-arm handoff could not identify its predecessor while this home still needs supervision.\n' >&2
      exit 2
      ;;
  esac

  handoff_wait=0
  while ! fm_lock_try_acquire "$HANDOFF_LOCK"; do
    handoff_pid=${FM_LOCK_HELD_PID:-}
    fm_pid_alive "$handoff_pid" && exit 0
    [ "$handoff_wait" -lt 20 ] || {
      printf 'firstmate watcher cycle FAILED - queued Stop re-arm handoff ownership is ambiguous while this home still needs supervision.\n' >&2
      exit 2
    }
    sleep 0.1
    handoff_wait=$((handoff_wait + 1))
  done
  trap 'fm_lock_release "$OWNER_LOCK"; fm_lock_release "$HANDOFF_LOCK"' EXIT

  while :; do
    [ -e "$STATE/.afk" ] && exit 0
    need_supervision || exit 0
    if fm_lock_try_acquire "$OWNER_LOCK"; then
      OWNER_CLAIM=$(basename "${FM_LOCK_OWNER_DIR:-}")
      predecessor_outcome=$(epoch_outcome_for_claim "$PREDECESSOR_CLAIM")
      case "$predecessor_outcome" in
        clean) break ;;
        rewake|afk) exit 0 ;;
        *) handoff_alarm ;;
      esac
    fi
    current_target=$(readlink "$OWNER_LOCK" 2>/dev/null || true)
    current_claim=${current_target##*/}
    if [ -n "$current_claim" ] && [ "$current_claim" != "$PREDECESSOR_CLAIM" ]; then
      current_owner=${FM_LOCK_HELD_PID:-}
      fm_pid_alive "$current_owner" && exit 0
    fi
    sleep 0.1
  done
  fm_lock_release "$HANDOFF_LOCK"
fi
trap 'fm_lock_release "$OWNER_LOCK"; fm_lock_release "$HANDOFF_LOCK"' EXIT
case "$OWNER_CLAIM" in ''|*[!A-Za-z0-9._-]*) handoff_alarm ;; esac

write_epoch arming

# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- foreground the real arm wrapper ------------------------------------------
# NO shell &: this hook process tree is the harness-owned lifecycle. The arm
# forks the watcher as its own tracked child exactly as it does for the
# model-driven background-task path, and propagates the wake reason on close.
OUT=$(mktemp "$STATE/.claude-autoarm-output.XXXXXX") || OUT=
if [ -n "$OUT" ]; then
  "$SCRIPT_DIR/fm-watch-arm.sh" >"$OUT" 2>&1
  RC=$?
else
  "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1
  RC=$?
fi

# --- classify and translate ---------------------------------------------------
# AFK may have appeared mid-cycle: the daemon owns triage now, so suppress the
# rewake even for an actionable close.
if [ -e "$STATE/.afk" ]; then
  write_epoch afk
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

ACTIONABLE=0
FAILED=0
if [ -n "$OUT" ]; then
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" 2>/dev/null && ACTIONABLE=1
  grep -q '^watcher: FAILED' "$OUT" 2>/dev/null && FAILED=1
fi
[ "$RC" -ne 0 ] && FAILED=1

if [ "$ACTIONABLE" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
  write_epoch clean
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# The need may have vanished mid-cycle (fleet torn down, X opted out): nothing
# left to supervise, so close quietly instead of waking the model.
if ! need_supervision; then
  write_epoch clean
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

write_epoch rewake
if [ "$FAILED" -eq 1 ]; then
  {
    printf 'firstmate watcher cycle FAILED - supervision is down while this home still needs it.\n'
    [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Run bin/fm-wake-drain.sh first. Then repair supervision with bin/fm-watch-arm.sh as its own Claude Code background task (never shell &). If the failure repeats, treat it as a blocker and report it instead of ending blind.\n'
  } >&2
else
  {
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    [ -n "$OUT" ] && grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Run bin/fm-wake-drain.sh first and handle the wake. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  } >&2
fi
[ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
exit 2
