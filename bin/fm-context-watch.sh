#!/usr/bin/env bash
# fm-context-watch.sh — WATCH+FIRE component of the firstmate context watchdog.
#
# A presence/busy-gated daemon, modelled on fm-supervise-daemon.sh, that polls the
# ctx-<window>.json sentinels written by fm-ctx-statusline.sh / fm-ctx-stop-hook.sh
# and, when a session crosses its restart threshold AND its pane is not busy, drives
# the checkpoint -> handoff -> /clear cycle:
#   1. fm-send a "checkpoint now: write your leave-off doc to state/handoff-<win>.md
#      then stop" instruction into the pane.
#   2. poll until that handoff file exists (bounded by FM_CTX_HANDOFF_TIMEOUT).
#   3. send '/clear' into the pane (ONLY after the handoff exists — never wipe a
#      session that has not checkpointed).
#   4. mark a cooldown so the (now-stale) sentinel does not immediately re-fire.
#
# Thresholds live in fm-ctx-lib.sh: CAPTAIN fires at total context >= FM_CTX_CAPTAIN_FLOOR
# (~185k, a margin UNDER the 200k floor — fire before, never at, 200k);
# CREW/SECONDMATE fire at used_pct >= FM_CTX_CREW_PCT (~50).
#
# ONE SURFACE PER PANE, chosen by what the pane IS, never by ambience. Every
# fire-time touchpoint - the busy read, the checkpoint delivery, the /clear -
# routes through bin/fm-herdr.sh for a herdr pane and through the pre-cutover
# tmux path for a window still draining. The busy-guard is load-bearing on both:
# on tmux it reuses fm_pane_is_busy, the SAME detector the away-mode daemon and
# fm-send use; on herdr it reads agent_status directly, so a pane mid-turn is
# never interrupted on either.
#
# The pure decision functions below (fm_ctx_needs_restart / _ctx_eligible /
# fm_ctx_select / fm_ctx_can_fire) are sourceable and unit-tested; the main loop
# runs only when the script is executed.
#
# Env knobs:
#   FM_STATE_OVERRIDE        state dir (testing)
#   FM_CTX_POLL              seconds between polls (default 20)
#   FM_CTX_COOLDOWN          seconds a fired window is suppressed (default 600)
#   FM_CTX_HANDOFF_TIMEOUT   seconds to wait for the handoff file (default 120)
#   FM_CTX_HANDOFF_POLL      seconds between handoff existence checks (default 2)
#   FM_CTX_SEND_CMD          override the instruction-send command (testing); receives
#                            "<target> <message>" appended. Default: bin/fm-send.sh.
#   FM_CTX_CLEAR_CMD         override the /clear delivery (testing); receives "<target>".
#   FM_CTX_CAPTAIN_FLOOR / FM_CTX_CREW_PCT   thresholds (see fm-ctx-lib.sh)
set -u

FM_CTX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_CTX_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-ctx-lib.sh
. "$FM_CTX_DIR/fm-ctx-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh disable=SC1091  # sibling lib sourced at runtime; not a shellcheck input
. "$FM_CTX_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-herdr.sh disable=SC1091  # sibling lib sourced at runtime; not a shellcheck input
. "$FM_CTX_DIR/fm-herdr.sh"

POLL_DEFAULT=20
COOLDOWN_DEFAULT=600
HANDOFF_TIMEOUT_DEFAULT=120
HANDOFF_POLL_DEFAULT=2

_ctx_state_root() { printf '%s' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"; }
_ctx_now() { date +%s; }
if [ "$(uname)" = Darwin ]; then
  _ctx_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  _ctx_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
_ctx_age() {  # seconds since mtime; huge if missing
  local m; m=$(_ctx_mtime "$1") || { echo 999999; return; }
  echo $(( $(_ctx_now) - m ))
}

# --- sentinel reads (PURE) --------------------------------------------------
# fm_ctx_json_field: echo one top-level field of a ctx-*.json (empty if absent).
fm_ctx_json_field() {  # <json_file> <field>
  [ -r "$1" ] || { printf ''; return 0; }
  FM_F=$2 python3 -c '
import sys, json, os
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
v = d.get(os.environ["FM_F"], "")
print(v if v is not None else "")
' "$1" 2>/dev/null
}

# fm_ctx_needs_restart: 0 if the measurement in <ctx_json> crosses its role's
# threshold. Pure: reads only the file.
fm_ctx_needs_restart() {  # <ctx_json>
  local f=$1 role total pct
  [ -r "$f" ] || return 1
  role=$(fm_ctx_json_field "$f" role)
  total=$(fm_ctx_json_field "$f" total_tokens)
  pct=$(fm_ctx_json_field "$f" used_pct)
  fm_ctx_should_restart "$role" "$total" "$pct"
}

# _ctx_key_from_path: ctx-<key>.json -> <key>
_ctx_key_from_path() { local b; b=$(basename "$1"); b=${b#ctx-}; printf '%s' "${b%.json}"; }

# _ctx_in_cooldown: 0 if this window fired within FM_CTX_COOLDOWN.
_ctx_in_cooldown() {  # <statedir> <key>
  local marker="$1/.ctx-fired-$2"
  [ -e "$marker" ] || return 1
  [ "$(_ctx_age "$marker")" -lt "${FM_CTX_COOLDOWN:-$COOLDOWN_DEFAULT}" ]
}

# fm_ctx_sentinel_managed: 0 iff the sentinel was stamped managed:true by the
# MEASURE path (i.e. its pane is in the firstmate tmux session). Missing/false/any
# other value -> NOT managed (fail-closed). This is what stops the daemon from ever
# steering an ad-hoc/personal session that merely wrote a sentinel via the global
# statusLine. (json.load turns JSON true into Python True, printed as "True".)
fm_ctx_sentinel_managed() {  # <ctx_json>
  local f=$1 m
  [ -r "$f" ] || return 1
  m=$(fm_ctx_json_field "$f" managed)
  [ "$m" = true ] || [ "$m" = True ]
}

# _ctx_eligible: managed AND threshold crossed AND not in cooldown (no fire-time
# tmux — pure read of the sentinel + cooldown marker).
_ctx_eligible() {  # <statedir> <key>
  local state=$1 key=$2
  fm_ctx_sentinel_managed "$state/ctx-$key.json" || return 1
  fm_ctx_needs_restart "$state/ctx-$key.json" || return 1
  _ctx_in_cooldown "$state" "$key" && return 1
  return 0
}

# fm_ctx_select: print the window keys whose sessions should be restarted
# (threshold crossed, not in cooldown). Pure — the busy-guard is applied later by
# fm_ctx_can_fire. This is the G1 surface.
fm_ctx_select() {  # <statedir>
  local state=$1 f key
  for f in "$state"/ctx-*.json; do
    [ -e "$f" ] || continue
    key=$(_ctx_key_from_path "$f")
    _ctx_eligible "$state" "$key" && printf '%s\n' "$key"
  done
}

# fm_ctx_target_for: the tmux target to steer for a window key (the pane id stored
# by the statusline; falls back to the window field).
fm_ctx_target_for() {  # <statedir> <key>
  local state=$1 key=$2 f t
  f="$state/ctx-$key.json"
  t=$(fm_ctx_json_field "$f" tmux_target)
  [ -n "$t" ] || t=$(fm_ctx_json_field "$f" window)
  printf '%s' "$t"
}

# _ctx_pane_busy: the busy-guard, routed to the surface the target lives on.
#
# THIS GUARD IS LOAD-BEARING: firing on a busy pane interrupts a crewmate
# mid-turn and then /clears it. On tmux it is the SAME text detector the
# away-mode daemon and fm-send use. On herdr it is better than that - a real
# lifecycle read (`agent_status == working`) rather than a regex over rendered
# text, so a pane whose terminal title merely contains the word "working" is no
# longer mistaken for one that is.
_ctx_pane_busy() {  # <target>
  if fm_herdr_is_pane_id "$1"; then
    fm_herdr_is_busy "$1"
    return
  fi
  fm_pane_is_busy "$1"
}

# _ctx_target_in_session: 0 iff <target> is, RIGHT NOW, a pane firstmate owns.
# Defense-in-depth at fire time: even if a sentinel claimed managed:true, the
# actual pane is re-confirmed as ours before anything is sent. Anything
# unresolvable, foreign or unreadable -> return 1 (never fire on a pane we
# cannot positively confirm is ours).
#
# The two surfaces answer that question with different evidence, and the herdr
# answer is the stronger one. Under tmux, ownership is a SESSION NAME - anything
# that lands in the `firstmate` session counts. Under herdr it is this home's
# own RECORD: a meta whose `window=` is exactly this pane and whose `mux=` says
# herdr, which is the same discriminator fm-send, fm-peek and the watcher route
# on. A herdr pane the fleet never spawned has no meta, so the captain's own
# panes - and another home's crewmates - are not ours to steer.
# The state dir is PASSED, never re-derived from the environment: fm_ctx_can_fire
# is already holding the one the sentinel came from, and a scoped watch
# (--scope <home>) or a test seam can make _ctx_state_root's answer a different
# directory entirely. Re-deriving it here would ask one home's metas about
# another home's pane, which is how a fire gate silently answers the wrong
# question.
_ctx_target_in_session() {  # <statedir> <target>
  local state=$1 target=$2 sess m
  [ -n "$target" ] || return 1
  if fm_herdr_is_pane_id "$target"; then
    # Read LINES, not words: a meta path can contain a space (FM_HOME is a
    # user-chosen directory), and word-splitting a filename into fragments would
    # silently answer "not ours" for a pane that is.
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      grep -q '^mux=herdr$' "$m" && return 0
    done <<EOF
$(grep -lFx "window=$target" "$state"/*.meta 2>/dev/null)
EOF
    return 1
  fi
  sess=$(tmux display-message -p -t "$target" '#{session_name}' 2>/dev/null) || return 1
  fm_ctx_session_managed "$sess"
}

# fm_ctx_can_fire: the full fire gate — eligible (managed + over threshold + not in
# cooldown) AND the target re-confirms as a firstmate-session pane AND the pane is
# not busy. This is the G2 surface (a busy pane must NOT fire).
fm_ctx_can_fire() {  # <statedir> <key> <target>
  local state=$1 key=$2 target=$3
  _ctx_eligible "$state" "$key" || return 1
  _ctx_target_in_session "$state" "$target" || return 1
  _ctx_pane_busy "$target" && return 1
  return 0
}

# fm_ctx_checkpoint_msg: the instruction sent into the pane. Names the EXACT
# handoff path (so the session does not have to compute its own key) and the
# context-discipline leave-off format; kept terse and well under the inject cap.
fm_ctx_checkpoint_msg() {  # <key>
  local key=$1 state; state=$(_ctx_state_root)
  printf 'CONTEXT CHECKPOINT (auto): your context is near its limit. Write your leave-off doc NOW to %s/handoff-%s.md using the context-discipline format — Goal / Done-green / Frontier / Open-decisions / Pointers (references, not contents; keep it well under 10k chars). Write that file, then stop. You will be /cleared and rehydrated from it.' "$state" "$key"
}

# _ctx_send: deliver the checkpoint instruction. Overridable for tests; default is
# the verified fm-send.sh (non-fatal if its submit verification is unhappy — the
# text still landed, and the handoff poll is the real ack).
_ctx_send() {  # <target> <msg>
  if [ -n "${FM_CTX_SEND_CMD:-}" ]; then
    eval "$FM_CTX_SEND_CMD \"\$1\" \"\$2\"" || true
  else
    "$FM_CTX_DIR/fm-send.sh" "$1" "$2" || true
  fi
}

_ctx_mark_fired() { local state=$1 key=$2; _ctx_now > "$state/.ctx-fired-$key"; }

# _ctx_clear: issue the conversation reset. Best-effort on BOTH surfaces, as the
# tmux path always was: the handoff is already on disk by the time this runs, so
# a delivery that cannot be confirmed loses nothing that was not written down.
_ctx_clear() {  # <target>
  if [ -n "${FM_CTX_CLEAR_CMD:-}" ]; then
    eval "$FM_CTX_CLEAR_CMD \"\$1\"" || true
    return 0
  fi
  if fm_herdr_is_pane_id "$1"; then
    fm_herdr_prompt "$1" '/clear' >/dev/null 2>&1 || true
    return 0
  fi
  tmux send-keys -t "$1" -l '/clear' 2>/dev/null || true
  tmux send-keys -t "$1" Enter 2>/dev/null || true
  return 0
}

# fm_ctx_fire_once: the checkpoint -> wait-for-FRESH-handoff -> /clear sequence for
# one window. Returns 0 only if a handoff written AFTER this checkpoint appeared and
# /clear was issued. NEVER issues /clear on a STALE pre-existing handoff: a
# handoff-<key>.md left over from a prior cycle (one that did not get archived, e.g.
# the rehydrate never ran) would otherwise let the wait loop fall straight through and
# wipe the crewmate's CURRENT turn, rehydrating from the old doc and silently
# discarding live work. To prevent that we baseline the existing handoff's mtime before
# sending the checkpoint and only accept a handoff strictly NEWER than that baseline.
# This is the G4/G9 surface; it protects both the daemon and fm-compact-crewmate.
fm_ctx_fire_once() {  # <statedir> <key>
  local state=$1 key=$2 target handoff msg timeout step baseline
  target=$(fm_ctx_target_for "$state" "$key")
  [ -n "$target" ] || { _ctx_log "fire: no target for $key"; return 1; }
  handoff="$state/handoff-$key.md"
  # Baseline the pre-existing handoff mtime (0 if absent) so only a fresh, post-checkpoint
  # write counts. A stale handoff present at fire time will not satisfy the freshness test.
  if [ -e "$handoff" ]; then
    baseline=$(_ctx_mtime "$handoff"); baseline=${baseline:-0}
  else
    baseline=0
  fi
  msg=$(fm_ctx_checkpoint_msg "$key")
  _ctx_log "fire: checkpoint -> $key ($target); handoff-baseline-mtime=$baseline"
  _ctx_send "$target" "$msg"
  timeout=${FM_CTX_HANDOFF_TIMEOUT:-$HANDOFF_TIMEOUT_DEFAULT}
  step=${FM_CTX_HANDOFF_POLL:-$HANDOFF_POLL_DEFAULT}
  # step may be fractional (e.g. 0.2 in tests); count integer iterations against a
  # ceil(timeout/step) bound so the loop guard stays integer-safe.
  local i=0 max_iters m
  max_iters=$(awk -v t="$timeout" -v s="$step" 'BEGIN{ if (s<=0) s=1; n=t/s; if (n>int(n)) n=int(n)+1; print int(n) }')
  # Wait for a handoff that is strictly NEWER than the baseline (a fresh checkpoint).
  while true; do
    if [ -e "$handoff" ]; then
      m=$(_ctx_mtime "$handoff"); m=${m:-0}
      [ "$m" -gt "$baseline" ] && break
    fi
    [ "$i" -lt "$max_iters" ] || { _ctx_log "fire: no FRESH handoff for $key after ${timeout}s; NOT clearing"; return 1; }
    sleep "$step"
    i=$((i + 1))
  done
  # A fresh handoff exists — safe to recycle the session. Routed to the surface
  # the pane lives on: on herdr, `/clear` is submitted as a prompt (the pane is
  # not busy, so the acknowledged path applies), and the tmux keystrokes are the
  # pre-cutover path, unchanged.
  _ctx_clear "$target"
  _ctx_mark_fired "$state" "$key"
  _ctx_log "fire: /clear issued for $key (fresh handoff present)"
  return 0
}

_ctx_log() { [ -n "${FM_CTX_LOG:-}" ] && printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$FM_CTX_LOG"; return 0; }

# --- main loop (executed only) ----------------------------------------------
# fm_ctx_main accepts an optional --scope/--home <home> to watch ONLY that firstmate
# home's crewmates (a secondmate watching its own tree) instead of the global default.
# Scoping is just re-pointing FM_HOME: _ctx_state_root resolves to $home/state, so the
# poll set, the cooldown markers, AND the singleton lock ($STATE/.context-watch.lock)
# are all naturally per-scope. No scope -> unchanged global behavior (FM_STATE_OVERRIDE
# still wins when set, preserving the existing test/override path).
fm_ctx_main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --scope|--home)
        shift; [ $# -gt 0 ] || { echo "error: --scope needs a home path" >&2; exit 2; }
        FM_HOME=$1 ;;
      --scope=*|--home=*) FM_HOME=${1#*=} ;;
      --) shift; break ;;
      --*) echo "error: unknown flag: $1" >&2; exit 2 ;;
      *) echo "error: unexpected argument: $1" >&2; exit 2 ;;
    esac
    shift
  done
  local STATE; STATE="$(_ctx_state_root)"; mkdir -p "$STATE"
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091  # sibling lib sourced at runtime; not a shellcheck input
  FM_STATE_OVERRIDE="$STATE" . "$FM_CTX_DIR/fm-wake-lib.sh"
  local LOCK="$STATE/.context-watch.lock" PIDFILE="$STATE/.context-watch.pid"
  FM_CTX_LOG="$STATE/.context-watch.log"
  if ! fm_lock_try_acquire "$LOCK"; then
    echo "error: another fm-context-watch is already running (lock $LOCK held)" >&2
    exit 1
  fi
  echo "$$" > "$PIDFILE"
  cleanup() { trap - TERM INT; fm_lock_release "$LOCK" 2>/dev/null || true; rm -f "$PIDFILE" 2>/dev/null || true; _ctx_log "context-watch shutting down"; exit 0; }
  trap cleanup TERM INT
  _ctx_log "context-watch starting (pid $$); floor=${FM_CTX_CAPTAIN_FLOOR}; crew_pct=${FM_CTX_CREW_PCT}"
  local key target
  while true; do
    for key in $(fm_ctx_select "$STATE"); do
      target=$(fm_ctx_target_for "$STATE" "$key")
      [ -n "$target" ] || continue
      if fm_ctx_can_fire "$STATE" "$key" "$target"; then
        fm_ctx_fire_once "$STATE" "$key" || true
      else
        _ctx_log "skip $key: busy or ineligible"
      fi
    done
    sleep "${FM_CTX_POLL:-$POLL_DEFAULT}"
  done
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_ctx_main "$@"
fi
