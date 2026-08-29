#!/usr/bin/env bash
# fm-watch-codex-bridge.sh - the Codex-primary watcher bridge.
#
# Codex cannot reason while a foreground tool call runs, and it has no
# extension API, background-task completion notification, or Stop-rewake. Its
# bounded foreground checkpoint (bin/fm-watch-checkpoint.sh) observes events
# only while a turn is actively running, so external signal/stale/check/
# heartbeat events can exist durably in state/.wake-queue without opening a
# new Codex turn. This bridge is the service-owned counterpart for a Codex
# primary: one persistent owner process, launched in its own tracked
# non-visible terminal, keeps a live watcher cycle (bin/fm-watch.sh) running
# across ordinary Codex turn boundaries and injects the canonical operational
# wake prompt into the exact recorded Codex primary pane when the durable
# queue holds wakes Codex has not been doorbelled about yet.
#
# Usage:
#   fm-watch-codex-bridge.sh arm        Run from inside the Codex primary
#                                       session (its first supervision cycle
#                                       or a repair). Resolves and verifies
#                                       the exact primary pane, reconciles a
#                                       stale prior bridge, and launches the
#                                       bridge in a tracked non-visible
#                                       terminal, then verifies it. Idempotent:
#                                       a bridge for the same session is
#                                       attached, not duplicated; one bound to
#                                       a replaced session or different target
#                                       is stopped and replaced.
#   fm-watch-codex-bridge.sh stop       Stop the bridge by its recorded lock
#                                       pid, close its recorded terminal by
#                                       exact id, and drop the record.
#   fm-watch-codex-bridge.sh reconcile  Close a recorded-but-dead bridge
#                                       terminal and drop the record.
#   fm-watch-codex-bridge.sh status     Print one line of bridge state.
#   fm-watch-codex-bridge.sh run        The daemon loop. Launched only inside
#                                       the bridge's own tracked terminal;
#                                       never a model-facing command.
#
# The arm passes the daemon its binding through state/.watch-codex-bridge-binding
# (one atomic 0600 record the arm rewrites at every arm), not through the
# terminal's command line: the verified backend submit/launch transports are
# keystroke paths, and a multi-hundred-byte binding (the session identity alone
# is the session's full /proc cmdline hex) is silently truncated when the arm
# - running inside the primary pane - types the launch command through a
# backend terminal. The binding file keeps the launch command short enough to
# survive every verified backend transport and binds the daemon to exactly the
# binding the arm verified, never to a re-derived one.
#
# Ownership binding, re-verified before every injection; every failure stands
# the bridge down instead of injecting:
#   - canonical home: the resolved absolute FM_HOME the arm recorded;
#   - session: the pid recorded from state/.lock at arm time, re-verified by
#     recomputing its fm_pid_identity against the live lock every cycle, so a
#     replaced or dead session can never receive an injection;
#   - watcher generation: the bridge's own generation token recorded in its
#     singleton lock; a replacement bridge steals the lock and the old
#     instance self-evicts within one tick;
#   - backend session: named in the recorded target (herdr
#     "<session>:<pane-id>"; tmux "session:window"), and every backend call
#     is re-scoped through bin/fm-backend.sh's named-session dispatch, never
#     through ambient session variables;
#   - workspace/tab/pane: the exact structured ids the backend reported at
#     arm time (herdr workspace_id/tab_id/pane_id; tmux server-global pane
#     id), re-verified before every injection. Labels are never authority and
#     ambiguous panes are never swept;
#   - Codex primary identity: the pane's own shell must positively contain
#     the session-lock pid inside its descendant process tree, so the pane is
#     provably the Codex session that owns the recorded lock. A same-named
#     pane, a pane id reused by another session, or a pane hosting a
#     different session is a refusal, never a target.
#
# Delivery contract:
#   - The trigger is the durable queue itself: inject when the queue's newest
#     row is newer than the last confirmed injection
#     (state/.watch-codex-bridge-delivered, an "epoch<TAB>seq" row identity).
#     .wake-queue durability and the generation-bound fm-wake-drain /
#     WAKE_ACK_REQUIRED acknowledgement remain the only source of truth; the
#     bridge never appends, consumes, or acknowledges a wake row, and
#     duplicate suppression is exactly "nothing newer than what was already
#     doorbelled".
#   - The prompt is constructed by bin/fm-operational-input.sh (kind watcher)
#     around the newest durable row's payload verbatim:
#       U+2063FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: stale: ...
#       Run bin/fm-wake-drain.sh first and handle the queued wake. Watcher
#       continuity is bridge-owned.
#     The transport form is single-line (the verified submit core types
#     literal text and submits with Enter, so an embedded newline would
#     submit mid-prompt) with newlines collapsed to " - ", the same
#     single-line convention the away-mode daemon uses for its digest.
#   - The pane must read not-busy (native agent state where the backend has
#     it, else the rendered codex delivery footer scoped to the recorded
#     harness) and its composer must be POSITIVELY empty
#     (bin/fm-composer-lib.sh) before anything is typed. Anything else defers
#     and retries on a bounded cadence with full identity revalidation. A
#     pending composer is never merged into; captain input is never
#     overwritten. The residual check-to-type race is the same accepted
#     boundary the away-mode daemon documents.
#   - Only fm_backend_send_text_submit's confirmed 'empty' verdict marks the
#     delivery point; an unconfirmed submit records nothing and keeps
#     retrying, so an unverified delivery is never reported as delivered.
#
# Lifecycle:
#   - The watcher child runs under the existing watcher singleton lock and
#     liveness beacon, so every guard, ledger, and recovery-generation
#     mechanism is unchanged. After an actionable close the next child start
#     carries FM_WATCH_HANDLING_SUCCESSOR=1: the bridge is delivering that
#     wake, so the recovery episode is not re-announced while the model
#     handles it.
#   - While state/.afk exists the bridge stops entirely: the away daemon owns
#     supervision and must not be double-injected behind. The next Codex
#     turn-end guard repair re-arms the bridge after away mode ends.
#   - arm fails closed (no terminal created) when the detected harness is not
#     codex, the session lock is missing or not owned by the calling session
#     (lock-refused read-only mode), away mode is active, the backend has no
#     verified non-visible launch primitive, the target does not resolve, or
#     the Codex primary identity cannot be positively pinned to the pane.
#   - The tracked-terminal launch mechanics mirror bin/fm-afk-launch.sh (a
#     dedicated --no-focus herdr workspace in the captain's named session, or
#     a detached tmux session) with this bridge's own record
#     (state/.watch-codex-bridge-terminal) and workspace label. Away-mode
#     state is never written. Shell &, nohup, disown, and untracked detached
#     terminals are never used.
#
# Test seams (unset in production): FM_BRIDGE_ENTRY overrides the tracked
# terminal's entry command; FM_BRIDGE_HARNESS overrides arm-time harness
# detection; FM_BRIDGE_WS_LABEL overrides the herdr workspace label;
# FM_BRIDGE_SKIP_PANE_VALIDATION supports topology tests that cannot run a
# real primary process tree. FM_BRIDGE_POLL,
# FM_BRIDGE_INJECT_RETRY_SECS, FM_BRIDGE_PANE_GONE_SLEEP,
# FM_BRIDGE_SUBMIT_RETRIES, and FM_BRIDGE_SUBMIT_SLEEP own the cadences.

set -u

BRIDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$BRIDGE_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
case "$FM_HOME" in
  /*) ;;
  *)
    _bridge_home_input=$FM_HOME
    FM_HOME=$(CDPATH='' cd -- "$_bridge_home_input" 2>/dev/null && pwd -P) || {
      echo "error: FM_HOME directory cannot be resolved: $_bridge_home_input" >&2
      exit 1
    }
    ;;
esac
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  case "$FM_STATE_OVERRIDE" in
    /*) ;;
    *)
      _bridge_state_input=$FM_STATE_OVERRIDE
      FM_STATE_OVERRIDE=$(CDPATH='' cd -- "$_bridge_state_input" 2>/dev/null && pwd -P) || {
        echo "error: FM_STATE_OVERRIDE directory cannot be resolved: $_bridge_state_input" >&2
        exit 1
      }
      ;;
  esac
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$BRIDGE_DIR/fm-wake-lib.sh"
# Backend dispatch: target existence, capture, busy state, composer state,
# and the verified submit core with positive acknowledgement.
# shellcheck source=bin/fm-backend.sh
. "$BRIDGE_DIR/fm-backend.sh"
# Canonical construction and parsing for every Firstmate operational input.
# shellcheck source=bin/fm-operational-input.sh
. "$BRIDGE_DIR/fm-operational-input.sh"
# The rendered busy-line matcher: this bridge reads it directly rather than
# relying on a backend adapter having loaded bin/fm-composer-lib.sh first,
# because the tmux adapter does not load it and the pane-busy guard must hold
# for every supported backend.
# shellcheck source=bin/fm-composer-lib.sh
. "$BRIDGE_DIR/fm-composer-lib.sh"
# Supervisor-pane discovery, shared with the away-mode launcher so the
# captain pane resolves identically in both ownership models.
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$BRIDGE_DIR/fm-supervisor-target-lib.sh"
# Shared session-lock harness identity (fm_harness_pid_alive,
# fm_session_lock_owned_by_self).
# shellcheck source=bin/fm-session-lock-lib.sh
. "$BRIDGE_DIR/fm-session-lock-lib.sh"

BRIDGE_LOCK="$STATE/.watch-codex-bridge.lock"
BRIDGE_RECORD="$STATE/.watch-codex-bridge-terminal"
BRIDGE_BINDING="$STATE/.watch-codex-bridge-binding"
BRIDGE_DELIVERED="$STATE/.watch-codex-bridge-delivered"
BRIDGE_LOG="$STATE/.watch-codex-bridge.log"
BRIDGE_CHILD_ERR="$STATE/.watch-codex-bridge.watch.err"
WATCH="$BRIDGE_DIR/fm-watch.sh"

FM_BRIDGE_SUPPORTED_BACKENDS=${FM_BRIDGE_SUPPORTED_BACKENDS:-"tmux herdr"}
FM_BRIDGE_WS_LABEL=${FM_BRIDGE_WS_LABEL:-firstmate-codex-bridge}
BRIDGE_POLL=${FM_BRIDGE_POLL:-1}
BRIDGE_INJECT_RETRY_SECS=${FM_BRIDGE_INJECT_RETRY_SECS:-15}
BRIDGE_PANE_GONE_SLEEP=${FM_BRIDGE_PANE_GONE_SLEEP:-30}
BRIDGE_WATCH_RESTART_SLEEP=${FM_BRIDGE_WATCH_RESTART_SLEEP:-5}
BRIDGE_CRASH_THRESHOLD=${FM_BRIDGE_CRASH_THRESHOLD:-10}
BRIDGE_CRASH_WINDOW=${FM_BRIDGE_CRASH_WINDOW:-60}
BRIDGE_CRASH_BACKOFF=${FM_BRIDGE_CRASH_BACKOFF:-60}
BRIDGE_LOG_MAX_BYTES=${FM_BRIDGE_LOG_MAX_BYTES:-1048576}
BRIDGE_LOG_KEEP_LINES=${FM_BRIDGE_LOG_KEEP_LINES:-2000}
BRIDGE_SUBMIT_RETRIES=${FM_BRIDGE_SUBMIT_RETRIES:-3}
BRIDGE_SUBMIT_SLEEP=${FM_BRIDGE_SUBMIT_SLEEP:-0.5}
BRIDGE_DELIVERED_EPOCH_SLACK=${BRIDGE_DELIVERED_EPOCH_SLACK:-60}

# --- logging -------------------------------------------------------------------
bridge_log() {
  local sz tmp
  [ -n "$BRIDGE_LOG" ] || return 0
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$BRIDGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$BRIDGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ "$sz" -ge "$BRIDGE_LOG_MAX_BYTES" ]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/fm-bridge-log.XXXXXX") || return 0
    tail -n "$BRIDGE_LOG_KEEP_LINES" "$BRIDGE_LOG" >"$tmp" 2>/dev/null && mv -f "$tmp" "$BRIDGE_LOG"
    rm -f "$tmp" 2>/dev/null || true
  fi
}

# --- the canonical doorbell prompt ----------------------------------------------
# bin/fm-operational-input.sh owns the envelope bytes; this is the
# watcher-kind body around the watcher's wake reason, passed through
# verbatim. The bridge is a doorbell, never a classifier: it never reformats,
# classifies, or drops a reason.
fm_bridge_wake_body() {  # <reason>
  printf 'FIRSTMATE WATCHER WAKE: %s\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is bridge-owned.' "$1"
}

fm_bridge_wake_prompt() {  # <reason> -> canonical multi-line encoded prompt
  local encoded
  fm_operational_input_encode watcher "$(fm_bridge_wake_body "$1")" encoded || return 1
  printf '%s' "$encoded"
}

fm_bridge_wake_line() {  # <reason> -> single-line transport form
  local prompt
  prompt=$(fm_bridge_wake_prompt "$1") || return 1
  printf '%s' "${prompt//$'\n'/ - }"
}

# --- delivery-state helpers -------------------------------------------------------
# fm_bridge_queue_top: "epoch<TAB>seq" of the newest valid row in the durable
# queue, or nothing when no valid row exists. Rows are appended in increasing
# seq under the queue lock; comparing (epoch, seq) keeps the comparison
# monotonic even across a reset .wake-queue.seq counter, because a fresh row
# always carries a current epoch.
fm_bridge_queue_top() {
  [ -s "$FM_WAKE_QUEUE" ] || return 1
  awk -F '\t' '
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      if (!found || $1 > epoch || ($1 == epoch && $2 > seq)) {
        found = 1; epoch = $1; seq = $2
      }
    }
    END { if (found) print epoch "\t" seq }
  ' "$FM_WAKE_QUEUE" 2>/dev/null
}

# fm_bridge_queue_top_payload: the newest valid row's payload (the reason the
# watcher classified and queued) verbatim, or nothing when no valid row
# exists. fm_wake_clean_field already collapsed tabs and newlines, so field 5
# is the whole reason on one line.
fm_bridge_queue_top_payload() {
  [ -s "$FM_WAKE_QUEUE" ] || return 1
  awk -F '\t' '
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      if (!found || $1 > epoch || ($1 == epoch && $2 > seq)) {
        found = 1; epoch = $1; seq = $2; payload = $5
      }
    }
    END { if (found) print payload }
  ' "$FM_WAKE_QUEUE" 2>/dev/null
}

# fm_bridge_delivered_read: "epoch<TAB>seq" of the newest row the last
# confirmed injection covered, or nothing when no injection was ever
# confirmed. A marker whose epoch lies beyond a bounded future slack is
# corrupt, not delivered: it reads as nothing so a corrupt or rolled-back
# marker can never permanently silence the doorbell. Within the normal
# monotonic-sequence lifetime the (epoch, seq) pair is the row identity the
# ack contract itself relies on.
fm_bridge_delivered_read() {
  local line epoch seq now
  { [ -f "$BRIDGE_DELIVERED" ] && [ ! -L "$BRIDGE_DELIVERED" ]; } || return 0
  line=$(cat "$BRIDGE_DELIVERED" 2>/dev/null) || return 0
  case "$line" in ''|*[!0-9$'\t']*) return 0 ;; esac
  epoch=${line%%$'\t'*}
  seq=${line#*$'\t'}
  case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
  case "$seq" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s) || return 0
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  [ "$epoch" -le $(( now + BRIDGE_DELIVERED_EPOCH_SLACK )) ] || return 0
  printf '%s\t%s' "$epoch" "$seq"
}

# fm_bridge_undelivered_pending: 0 when the queue's newest row is NEWER than
# the delivered marker, i.e. at least one durable wake row has not been
# doorbelled yet. An absent marker means everything is undelivered.
fm_bridge_undelivered_pending() {  # [delivered]
  local delivered=${1:-} top
  top=$(fm_bridge_queue_top) || return 1
  if [ -z "$delivered" ]; then
    return 0
  fi
  awk -v delivered="$delivered" -v top="$top" 'BEGIN {
    n = split(delivered, a, "\t"); m = split(top, b, "\t")
    if (n != 2 || m != 2) exit 1
    if (a[1] + 0 != a[1] || a[2] + 0 != a[2] || b[1] + 0 != b[1] || b[2] + 0 != b[2]) exit 1
    exit !((b[1] + 0 > a[1] + 0) || (b[1] + 0 == a[1] + 0 && b[2] + 0 > a[2] + 0))
  }'
}

# Sample the queue top AFTER the confirmed submit, so every row that was in
# the queue when the prompt landed (which the model's drain, starting after
# the prompt, will present) counts as doorbelled; any later row gets its own
# doorbell.
fm_bridge_delivered_write() {
  local pending tmp
  pending=$(fm_bridge_queue_top) || return 1
  tmp=$(mktemp "$STATE/.watch-codex-bridge-delivered.XXXXXX") || return 1
  printf '%s\n' "$pending" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$BRIDGE_DELIVERED" || { rm -f "$tmp"; return 1; }
}

# --- pane guards -------------------------------------------------------------------
# bridge_pane_busy mirrors the away-mode daemon's pane_is_busy: native
# semantic busy state first (herdr agent get), then the rendered delivery
# footer scoped to the recorded harness, so another harness's busy-looking
# output can never suppress the primary's idle verdict.
bridge_pane_busy() {  # <backend> <target> <harness>
  local backend=$1 target=$2 harness=$3 native tail40
  native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null) || native=
  case "$native" in
    busy) return 0 ;;
  esac
  tail40=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -12 \
    | fm_busy_lines_match "$harness"
}

# bridge_pane_input_pending: 0 unless the composer is POSITIVELY empty. A
# pending verdict is unsubmitted text - the captain's draft or a prior
# swallowed submission - and typing would merge into or overwrite it.
bridge_pane_input_pending() {  # <backend> <target>
  local backend=$1 target=$2 verdict
  verdict=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null) || verdict=
  [ "$verdict" != empty ]
}

# --- exact pane identity -------------------------------------------------------------
# fm_bridge_pane_ids: the exact structured ids <target> resolves to right now:
# "<workspace><TAB><tab><TAB><pane>" for herdr, the server-global pane id for
# tmux. Any read failure returns nonzero and callers never treat that as a
# match.
fm_bridge_pane_ids() {  # <backend> <target>
  local backend=$1 target=$2 session pane out
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      { [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ]; } || return 1
      fm_backend_source herdr || return 1
      out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
      # Verified live against herdr 0.7.x: `pane get` answers type "pane_info"
      # with the queried pane_id echoed back; the presence classifier in
      # bin/backends/herdr.sh validates the echoed id the same way.
      printf '%s' "$out" | jq -er --arg pane "$pane" '
        .result as $r
        | if ($r.pane.pane_id == $pane
            and ($r.pane.workspace_id | type == "string" and length > 0)
            and ($r.pane.tab_id | type == "string" and length > 0))
          then [$r.pane.workspace_id, $r.pane.tab_id, $r.pane.pane_id] | @tsv
          else empty end
      ' 2>/dev/null
      ;;
    tmux)
      tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_pane_shell_pid() {  # <backend> <target>
  local backend=$1 target=$2 session pane out
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      { [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ]; } || return 1
      fm_backend_source herdr || return 1
      out=$(fm_backend_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null) || return 1
      printf '%s' "$out" | jq -er --arg pane "$pane" '
        .result as $r
        | if ($r.type == "pane_process_info" and $r.process_info.pane_id == $pane)
          then $r.process_info.shell_pid
          else empty end
        | select(type == "number" and . > 1)
        | floor
      ' 2>/dev/null
      ;;
    tmux)
      tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

# bridge_pid_is_descendant: 0 iff <needle> equals <root> or sits inside
# <root>'s descendant tree per the operating-system process table. One
# breadth-first walk over `ps -axo pid=,ppid=` with a bounded frontier; an
# unreadable table is a refusal, never a match.
bridge_pid_is_descendant() {  # <root> <needle>
  local root=$1 needle=$2 rows
  case "$root" in ''|*[!0-9]*|0) return 1 ;; esac
  case "$needle" in ''|*[!0-9]*|0) return 1 ;; esac
  [ "$root" = "$needle" ] && return 0
  rows=$(ps -axo pid=,ppid= 2>/dev/null) || return 1
  printf '%s\n' "$rows" | awk -v root="$root" -v needle="$needle" '
    {
      pid = $1 + 0; ppid = $2 + 0
      if (pid > 1 && ppid > 0) children[ppid] = children[ppid] " " pid
    }
    END {
      if (!(root + 0 in children) && root + 0 != needle + 0) exit 1
      head = 1; tail = 1
      queue[head] = root + 0
      seen[root + 0] = 1
      while (head <= tail) {
        current = queue[head]; head++
        if (current == needle + 0) exit 0
        split(children[current], kids, " ")
        for (k in kids) {
          child = kids[k] + 0
          if (child <= 0 || (child in seen)) continue
          seen[child] = 1
          tail++; queue[tail] = child
          if (tail - head > 4096) exit 1
        }
      }
      exit 1
    }
  '
}

# bridge_primary_pinned: the positive "this pane hosts the Codex primary that
# owns the recorded session lock" proof - the pane's own shell has the
# session pid inside its descendant tree.
bridge_primary_pinned() {  # <backend> <target> <session-pid>
  local backend=$1 target=$2 session_pid=$3 shell_pid
  case "$session_pid" in ''|*[!0-9]*|0) return 1 ;; esac
  shell_pid=$(bridge_pane_shell_pid "$backend" "$target") || return 1
  case "$shell_pid" in ''|*[!0-9]*|0) return 1 ;; esac
  bridge_pid_is_descendant "$shell_pid" "$session_pid"
}

# --- session binding ------------------------------------------------------------------
bridge_session_intact() {  # <session-pid> <session-identity>
  local lock_pid current
  [ -f "$STATE/.lock" ] || return 1
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  [ "$lock_pid" = "$1" ] || return 1
  current=$(fm_pid_identity "$lock_pid" 2>/dev/null) || return 1
  [ -n "$current" ] && [ "$current" = "$2" ]
}

bridge_afk_active() {
  [ -e "$STATE/.afk" ]
}

# bridge_session_owner: print "pid<TAB>identity" for the live session-lock
# owner. Fails closed when the lock is missing, unreadable, or its holder is
# not a live verified harness process.
bridge_session_owner() {
  local pid identity
  if [ ! -f "$STATE/.lock" ]; then
    echo "watcher bridge: FAILED - no firstmate session lock in $STATE/.lock; run bin/fm-session-start.sh before arming" >&2
    return 1
  fi
  pid=$(cat "$STATE/.lock" 2>/dev/null) || {
    echo "watcher bridge: FAILED - the session lock is unreadable" >&2
    return 1
  }
  case "$pid" in
    ''|*[!0-9]*)
      echo "watcher bridge: FAILED - the session lock does not name a pid" >&2
      return 1
      ;;
  esac
  if ! identity=$(fm_pid_identity "$pid" 2>/dev/null) || [ -z "$identity" ] || ! fm_harness_pid_alive "$pid"; then
    echo "watcher bridge: FAILED - session lock holder pid $pid is not a live verified harness process; run bin/fm-session-start.sh" >&2
    return 1
  fi
  printf '%s\t%s' "$pid" "$identity"
}

bridge_targets_exact() {  # <backend> <target> <recorded-ids>
  local backend=$1 target=$2 recorded=$3 live
  [ -n "$recorded" ] || return 1
  bridge_terminal_alive "$backend" "$target" || return 1
  live=$(fm_bridge_pane_ids "$backend" "$target") || return 1
  [ "$live" = "$recorded" ]
}

# --- terminal record --------------------------------------------------------------------
# One "backend<TAB>terminal-target<TAB>extra" line; extra carries the herdr
# workspace id for the record's own documentation (the exact pane id closes
# the terminal). This format's single owner is this header.
bridge_record_write() {  # <backend> <target> <extra>
  local pending
  mkdir -p "$STATE" || return 1
  pending=$(mktemp "$STATE/.watch-codex-bridge-terminal.pending.XXXXXX") || return 1
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$BRIDGE_RECORD" || { rm -f "$pending"; return 1; }
}

# Read the record into FM_BRIDGE_REC_BACKEND/FM_BRIDGE_REC_TARGET/FM_BRIDGE_REC_EXTRA.
# Returns 2 on a malformed record (never acted on), 1 when absent, 0 valid.
bridge_record_read() {
  local record
  FM_BRIDGE_REC_BACKEND=""
  FM_BRIDGE_REC_TARGET=""
  FM_BRIDGE_REC_EXTRA=""
  { [ -f "$BRIDGE_RECORD" ] && [ ! -L "$BRIDGE_RECORD" ]; } || return 1
  record=$(cat "$BRIDGE_RECORD" 2>/dev/null) || record=""
  IFS=$'\t' read -r FM_BRIDGE_REC_BACKEND FM_BRIDGE_REC_TARGET FM_BRIDGE_REC_EXTRA \
    < "$BRIDGE_RECORD" || true
  if ! printf '%s\n' "$record" | awk -F '\t' 'NF != 3 { bad=1 } END { exit !(NR == 1 && !bad) }' \
    || [ -z "$FM_BRIDGE_REC_BACKEND" ] || [ -z "$FM_BRIDGE_REC_TARGET" ]; then
    bridge_log "bridge terminal record is malformed; refusing to act on it"
    return 2
  fi
  case "$FM_BRIDGE_REC_BACKEND" in
    herdr) [ -n "$FM_BRIDGE_REC_EXTRA" ] || return 2 ;;
    tmux) [ "$FM_BRIDGE_REC_EXTRA" = "" ] || return 2 ;;
    *) return 2 ;;
  esac
}

bridge_terminal_alive() {  # <backend> <target>
  local backend=$1 target=$2 session pane
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      { [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ]; } || return 1
      fm_backend_source herdr || return 1
      fm_backend_herdr_cli "$session" pane get "$pane" >/dev/null 2>&1
      ;;
    tmux)
      tmux has-session -t "$target" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

bridge_terminal_absent() {  # <backend> <target>
  local backend=$1 target=$2 session pane out result code
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      { [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ]; } || return 1
      fm_backend_source herdr || return 1
      out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>&1)
      result=$?
      [ "$result" -ne 0 ] || return 1
      code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null) || return 1
      [ "$code" = pane_not_found ]
      ;;
    tmux)
      out=$(tmux has-session -t "$target" 2>&1)
      result=$?
      [ "$result" -eq 1 ] || return 1
      printf '%s' "$out" | grep -Eq "can't find session"
      ;;
    *) return 1 ;;
  esac
}

bridge_close_terminal() {  # <backend> <target>
  local backend=$1 target=$2 session pane
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      { [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ]; } || return 1
      fm_backend_source herdr || return 1
      fm_backend_herdr_cli "$session" pane close "$pane" >/dev/null 2>&1
      ;;
    tmux)
      tmux kill-session -t "$target" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

bridge_close_recorded() {
  local close_result=0
  bridge_close_terminal "$FM_BRIDGE_REC_BACKEND" "$FM_BRIDGE_REC_TARGET" || close_result=$?
  if bridge_terminal_absent "$FM_BRIDGE_REC_BACKEND" "$FM_BRIDGE_REC_TARGET"; then
    rm -f "$BRIDGE_RECORD" || return 1
    { [ "$close_result" -eq 0 ]; } || bridge_log "terminal close command failed, but exact absence was confirmed"
    return 0
  fi
  bridge_log "recorded bridge terminal teardown is unconfirmed; preserving exact id"
  return 1
}

# --- singleton lock ------------------------------------------------------------------------
bridge_lock_live() {  # -> 0 when a live bridge process holds the lock
  local pid identity
  [ -d "$BRIDGE_LOCK" ] || return 1
  pid=$(cat "$BRIDGE_LOCK/pid" 2>/dev/null) || return 1
  fm_pid_alive "$pid" || return 1
  identity=$(cat "$BRIDGE_LOCK/pid-identity" 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  [ "$(fm_pid_identity "$pid" 2>/dev/null)" = "$identity" ]
}

bridge_lock_pid() {
  cat "$BRIDGE_LOCK/pid" 2>/dev/null
}

bridge_lock_binding_matches() {  # <session-pid> <identity> <target> <backend>
  [ "$(cat "$BRIDGE_LOCK/session-pid" 2>/dev/null || true)" = "$1" ] || return 1
  [ "$(cat "$BRIDGE_LOCK/session-identity" 2>/dev/null || true)" = "$2" ] || return 1
  [ "$(cat "$BRIDGE_LOCK/target" 2>/dev/null || true)" = "$3" ] || return 1
  [ "$(cat "$BRIDGE_LOCK/backend" 2>/dev/null || true)" = "$4" ]
}

bridge_generate_generation() {
  printf 'g%s-%s-%s\n' "$(date +%s)" "${BASHPID:-$$}" "${RANDOM:-0}"
}

# --- arm --------------------------------------------------------------------------------------
BRIDGE_SESSION_OWNER_OUT=

bridge_arm() {
  local session_pid session_identity target backend harness recorded
  # Away mode owns supervision; the bridge must not arm beside the daemon.
  if bridge_afk_active; then
    echo "watcher bridge: FAILED - away mode is active; the away daemon owns supervision" >&2
    return 1
  fi
  # Codex-primary only: any other harness's primary has its own ownership
  # model and must not arm this bridge.
  if [ -n "${FM_BRIDGE_HARNESS:-}" ]; then
    harness=$FM_BRIDGE_HARNESS
  else
    harness=$("$BRIDGE_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
  fi
  if [ "$harness" != codex ]; then
    echo "watcher bridge: FAILED - this bridge arms only a Codex primary (detected harness: $harness)" >&2
    return 1
  fi
  if ! BRIDGE_SESSION_OWNER_OUT=$(bridge_session_owner); then
    return 1
  fi
  session_pid=${BRIDGE_SESSION_OWNER_OUT%%$'\t'*}
  session_identity=${BRIDGE_SESSION_OWNER_OUT#*$'\t'}
  # The arm runs inside the Codex primary session's own process tree, so the
  # session lock must name an ancestor of THIS process - the same evidence
  # fm-lock.sh publishes. Without it this is the lock-refused read-only case.
  if ! fm_session_lock_owned_by_self "$STATE"; then
    echo "watcher bridge: FAILED - this session does not own the fleet lock (lock-refused read-only mode); run bin/fm-session-start.sh first" >&2
    return 1
  fi
  if ! target=$(discover_supervisor_target); then
    echo "watcher bridge: FAILED - could not resolve the primary pane (set FM_SUPERVISOR_TARGET)" >&2
    return 1
  fi
  if ! backend=$(discover_supervisor_backend); then
    backend=$FM_SUPERVISOR_BACKEND_DEFAULT
  fi
  case " $FM_BRIDGE_SUPPORTED_BACKENDS " in
    *" $backend "*) ;;
    *)
      echo "watcher bridge: FAILED - no verified non-visible launch primitive for backend '$backend' (supported: $FM_BRIDGE_SUPPORTED_BACKENDS)" >&2
      return 1
      ;;
  esac
  if ! fm_backend_target_exists "$backend" "$target"; then
    echo "watcher bridge: FAILED - primary target '$target' does not resolve to a $backend pane" >&2
    return 1
  fi
  if ! recorded=$(fm_bridge_pane_ids "$backend" "$target"); then
    echo "watcher bridge: FAILED - could not read the exact pane identity for '$target'" >&2
    return 1
  fi
  if ! bridge_primary_pinned "$backend" "$target" "$session_pid"; then
    echo "watcher bridge: FAILED - the pane behind '$target' does not positively contain the session-lock pid $session_pid; refusing to bind an unverified primary" >&2
    return 1
  fi

  if bridge_lock_live; then
    if bridge_lock_binding_matches "$session_pid" "$session_identity" "$target" "$backend"; then
      echo "watcher bridge: attached pid=$(bridge_lock_pid) supervising $target (generation $(cat "$BRIDGE_LOCK/generation" 2>/dev/null || echo unknown))"
      return 0
    fi
    # A live bridge bound to a replaced session or a different target is a
    # stale owner: stop it by its exact pid, close its recorded terminal, and
    # replace it. Never a second concurrent bridge.
    echo "watcher bridge: replacing a bridge bound to a different session or target"
    bridge_stop_owned || return 1
    bridge_reconcile_recorded || return 1
  elif { [ -e "$BRIDGE_RECORD" ] || [ -L "$BRIDGE_RECORD" ]; }; then
    bridge_reconcile_recorded || return 1
  fi

  bridge_launch "$backend" "$target" "$session_pid" "$session_identity" "$harness" "$recorded"
}

# bridge_reconcile_recorded: close a recorded-but-dead bridge terminal by its
# exact id and drop the record. Never sweeps; a malformed record is refused.
bridge_reconcile_recorded() {
  local read_result
  bridge_record_read
  read_result=$?
  if [ "$read_result" -eq 2 ]; then
    echo "watcher bridge: FAILED - malformed bridge terminal record; refusing to reconcile it" >&2
    return 1
  fi
  [ "$read_result" -eq 0 ] || return 0
  bridge_log "reconciling recorded bridge terminal ${FM_BRIDGE_REC_BACKEND}:${FM_BRIDGE_REC_TARGET}"
  bridge_close_recorded
}

bridge_stop_owned() {  # stop the bridge holding the lock, by its exact pid
  local pid identity current i
  bridge_lock_live || return 0
  pid=$(bridge_lock_pid) || return 0
  identity=$(cat "$BRIDGE_LOCK/pid-identity" 2>/dev/null) || identity=""
  if [ -n "$identity" ] && [ "$(fm_pid_identity "$pid" 2>/dev/null)" != "$identity" ]; then
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || return 0
  i=0
  while [ "$i" -lt 40 ] && fm_pid_alive "$pid"; do
    sleep 0.25
    i=$((i + 1))
  done
  if fm_pid_alive "$pid"; then
    current=$(fm_pid_identity "$pid" 2>/dev/null) || {
      bridge_log "could not confirm the prior bridge's exit; preserving lifecycle state"
      return 1
    }
    if [ "$current" = "$identity" ]; then
      bridge_log "prior bridge pid $pid did not exit after SIGTERM; preserving lifecycle state"
      return 1
    fi
  fi
  return 0
}

bridge_entry_cmd() {
  printf '%s' "${FM_BRIDGE_ENTRY:-$FM_ROOT/bin/fm-watch-codex-bridge.sh}"
}

bridge_write_binding() {  # <target> <backend> <session-pid> <identity> <harness> <generation> <recorded-ids>
  local pending ws tab pane
  mkdir -p "$STATE" || return 1
  pending=$(mktemp "$STATE/.watch-codex-bridge-binding.pending.XXXXXX") || return 1
  chmod 600 "$pending" 2>/dev/null || true
  # The herdr pane identity is itself tab-shaped (<ws><TAB><tab><TAB><pane>),
  # so the binding record is backend-shaped: herdr carries the three ids as
  # fields 7-9 and tmux carries the single server-global pane id as field 7;
  # field 8 (herdr) / 9 is always the home. bridge_read_binding enforces the
  # same shape, so a record from the other backend can never be misread.
  case "$2" in
    herdr)
      IFS=$'\t' read -r ws tab pane_id <<< "$7"
      [ -n "$ws" ] && [ -n "$tab" ] && [ -n "$pane_id" ] \
        || { rm -f "$pending"; return 1; }
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$3" "$4" "$1" "$2" "$5" "$6" "$ws" "$tab" "$pane_id" "$FM_HOME" > "$pending" \
        || { rm -f "$pending"; return 1; }
      ;;
    tmux)
      case "$7" in *$'\t'*) rm -f "$pending"; return 1 ;; esac
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$3" "$4" "$1" "$2" "$5" "$6" "$7" "$FM_HOME" > "$pending" \
        || { rm -f "$pending"; return 1; }
      ;;
    *) rm -f "$pending"; return 1 ;;
  esac
  mv -f "$pending" "$BRIDGE_BINDING" || { rm -f "$pending"; return 1; }
}

# Read the binding file into FM_BRIDGE_BIND_* fields. Returns 2 on a malformed
# or cross-home record (never acted on), 1 when absent, 0 valid. The home field
# is verified against this process's own resolved FM_HOME so a record written
# by another home's arm can never start a daemon here.
bridge_read_binding() {
  FM_BRIDGE_BIND_PID=""; FM_BRIDGE_BIND_IDENTITY=""; FM_BRIDGE_BIND_TARGET=""
  FM_BRIDGE_BIND_BACKEND=""; FM_BRIDGE_BIND_HARNESS=""; FM_BRIDGE_BIND_GENERATION=""
  FM_BRIDGE_BIND_PANE_IDS=""; FM_BRIDGE_BIND_HOME=""
  { [ -f "$BRIDGE_BINDING" ] && [ ! -L "$BRIDGE_BINDING" ]; } || return 1
  local line nf ws tab pane_id
  line=$(cat "$BRIDGE_BINDING" 2>/dev/null) || return 1
  nf=$(printf '%s\n' "$line" | awk -F '\t' 'END { print NF }')
  case "$nf" in 8|10) ;; *)
    bridge_log "bridge binding record is malformed; refusing to act on it"
    return 2
    ;;
  esac
  IFS=$'\t' read -r FM_BRIDGE_BIND_PID FM_BRIDGE_BIND_IDENTITY FM_BRIDGE_BIND_TARGET \
    FM_BRIDGE_BIND_BACKEND FM_BRIDGE_BIND_HARNESS FM_BRIDGE_BIND_GENERATION \
    _f7 _f8 _f9 FM_BRIDGE_BIND_HOME <<< "$line" || true
  # The herdr pane identity is itself tab-shaped, so the binding record is
  # backend-shaped: herdr carries the three ids as fields 7-9 (NF=10), tmux the
  # single server-global pane id as field 7 (NF=8); the home is always last.
  # The rejoining must produce the exact bytes fm_bridge_pane_ids emits, so the
  # daemon's equality comparison stays byte-strict.
  case "$FM_BRIDGE_BIND_BACKEND" in
    herdr)
      if [ "$nf" -ne 10 ] || [ -z "$_f7" ] || [ -z "$_f8" ] || [ -z "$_f9" ]; then
        bridge_log "bridge binding record is malformed; refusing to act on it"
        return 2
      fi
      ws=$_f7; tab=$_f8; pane_id=$_f9
      FM_BRIDGE_BIND_PANE_IDS="$ws$(printf '\t')$tab$(printf '\t')$pane_id"
      ;;
    tmux)
      if [ "$nf" -ne 8 ] || [ -z "$_f7" ]; then
        bridge_log "bridge binding record is malformed; refusing to act on it"
        return 2
      fi
      FM_BRIDGE_BIND_PANE_IDS=$_f7
      ;;
    *)
      bridge_log "bridge binding record is malformed; refusing to act on it"
      return 2
      ;;
  esac
  if [ -z "$FM_BRIDGE_BIND_PID" ] || [ -z "$FM_BRIDGE_BIND_IDENTITY" ] \
    || [ -z "$FM_BRIDGE_BIND_TARGET" ] || [ -z "$FM_BRIDGE_BIND_BACKEND" ] \
    || [ "$FM_BRIDGE_BIND_HARNESS" != codex ] || [ -z "$FM_BRIDGE_BIND_GENERATION" ] \
    || [ "$FM_BRIDGE_BIND_HOME" != "$FM_HOME" ]; then
    bridge_log "bridge binding record is malformed or foreign; refusing to act on it"
    return 2
  fi
}

bridge_launch_env() {  # <binding-path>
  local envs
  envs=$(printf 'FM_HOME=%q FM_BRIDGE_BINDING=%q FM_BRIDGE_HARNESS=codex' "$FM_HOME" "$1")
  # The documented daemon cadence knobs are read at daemon start from the
  # environment; the tracked terminal's shell would otherwise drop them, so an
  # operator's exports (and the live tests') would never reach the daemon.
  [ -z "${FM_BRIDGE_POLL:-}" ] || envs="$envs FM_BRIDGE_POLL=$(printf '%q' "$FM_BRIDGE_POLL")"
  [ -z "${FM_BRIDGE_INJECT_RETRY_SECS:-}" ] || envs="$envs FM_BRIDGE_INJECT_RETRY_SECS=$(printf '%q' "$FM_BRIDGE_INJECT_RETRY_SECS")"
  printf '%s' "$envs"
}

bridge_launch() {  # <backend> <target> <session-pid> <identity> <harness> <recorded-ids>
  local backend=$1 target=$2 session_pid=$3 identity=$4 harness=$5 recorded=$6
  local generation
  generation=$(bridge_generate_generation)
  if ! bridge_write_binding "$target" "$backend" "$session_pid" "$identity" "$harness" "$generation" "$recorded"; then
    echo "watcher bridge: FAILED - could not persist the launch binding record" >&2
    return 1
  fi
  case "$backend" in
    herdr) bridge_launch_herdr "$target" "$backend" || return 1 ;;
    tmux) bridge_launch_tmux "$target" "$backend" || return 1 ;;
    *) return 1 ;;
  esac
  echo "watcher bridge: started pid=$(bridge_lock_pid) supervising $target (generation $(cat "$BRIDGE_LOCK/generation" 2>/dev/null || echo unknown))"
}

bridge_launch_herdr() {  # <target> <backend>
  local target=$1 backend=$2
  local session wsid pane entry cmd out create_result recovered label
  session=${target%%:*}
  if [ -z "$session" ] || [ "$session" = "$target" ]; then
    echo "watcher bridge: FAILED - cannot derive the herdr session from target '$target'" >&2
    return 1
  fi
  fm_backend_source herdr || return 1
  fm_backend_herdr_server_ensure "$session" || {
    echo "watcher bridge: FAILED - the herdr server for session '$session' is not ready" >&2
    return 1
  }
  wsid=""
  pane=""
  label="$FM_BRIDGE_WS_LABEL-$$-${RANDOM:-0}-$(date '+%s')"
  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$FM_HOME" --label "$label" --no-focus 2>/dev/null)
  create_result=$?
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ "$create_result" -ne 0 ] && [ -n "$wsid" ] && [ -n "$pane" ]; then
    bridge_log "herdr create failed after returning exact ids; closing $session:$pane"
    bridge_record_write herdr "$session:$pane" "$wsid" || true
    FM_BRIDGE_REC_BACKEND=herdr
    FM_BRIDGE_REC_TARGET="$session:$pane"
    bridge_close_recorded || true
    return 1
  fi
  if [ -z "$wsid" ] || [ -z "$pane" ]; then
    recovered=$(bridge_recover_created "$session" "$label") || {
      echo "watcher bridge: FAILED - herdr create did not yield a recoverable exact workspace/pane id" >&2
      return 1
    }
    IFS=$'\t' read -r wsid pane <<< "$recovered"
  fi
  entry=$(bridge_entry_cmd)
  cmd=$(printf 'exec env %s %q run' "$(bridge_launch_env "$BRIDGE_BINDING")" "$entry")
  if ! bridge_record_write herdr "$session:$pane" "$wsid"; then
    echo "watcher bridge: FAILED - could not persist the bridge terminal record; closing $session:$pane" >&2
    bridge_close_terminal herdr "$session:$pane" || true
    return 1
  fi
  if ! fm_backend_herdr_cli "$session" pane run "$pane" "$cmd" >/dev/null 2>&1; then
    echo "watcher bridge: FAILED - could not run the bridge in herdr pane $session:$pane; closing it" >&2
    FM_BRIDGE_REC_BACKEND=herdr
    FM_BRIDGE_REC_TARGET="$session:$pane"
    bridge_close_recorded || true
    return 1
  fi
  bridge_commit_terminal herdr "$session:$pane" "$wsid" || return 1
  bridge_log "bridge launched in non-visible herdr workspace $wsid (pane $session:$pane), supervising $target"
}

bridge_launch_tmux() {  # <target> <backend>
  local target=$1 backend=$2
  local session entry cmd hash nonce
  hash=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
  nonce="${BASHPID:-$$}-${RANDOM:-0}-$(date '+%s')"
  session="fm-codex-bridge-$hash-$nonce"
  entry=$(bridge_entry_cmd)
  cmd=$(printf 'exec env %s %q run' "$(bridge_launch_env "$BRIDGE_BINDING")" "$entry")
  if ! bridge_record_write tmux "$session" ""; then
    echo "watcher bridge: FAILED - could not persist the planned tmux bridge session '$session'" >&2
    return 1
  fi
  if ! tmux new-session -d -s "$session" "$cmd" 2>/dev/null; then
    echo "watcher bridge: FAILED - could not create detached tmux bridge session '$session'" >&2
    rm -f "$BRIDGE_RECORD" 2>/dev/null || true
    return 1
  fi
  bridge_commit_terminal tmux "$session" "" || return 1
  bridge_log "bridge launched in detached tmux session '$session', supervising $target"
}

bridge_wait_ready() {  # <backend> <target>
  local backend=$1 target=$2 attempt=0
  if [ -n "${FM_BRIDGE_ENTRY:-}" ]; then
    bridge_terminal_alive "$backend" "$target"
    return
  fi
  while [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    if bridge_lock_live && [ "$(cat "$BRIDGE_LOCK/home" 2>/dev/null || true)" = "$FM_HOME" ]; then
      return 0
    fi
    bridge_terminal_alive "$backend" "$target" || return 1
    sleep 0.05
  done
  return 1
}

bridge_commit_terminal() {  # <backend> <target> <extra>
  local backend=$1 target=$2
  if ! bridge_wait_ready "$backend" "$target"; then
    echo "watcher bridge: FAILED - the bridge did not become ready; closing $backend:$target" >&2
    FM_BRIDGE_REC_BACKEND=$backend
    FM_BRIDGE_REC_TARGET=$target
    bridge_close_recorded || true
    return 1
  fi
}

# herdr create can return before its ids are listable; recover the exact
# workspace/pane by the unique label the create call used (the same bounded
# recovery shape the away launcher uses).
bridge_recover_created() {  # <session> <label>
  local session=$1 label=$2 workspaces ws_count wsid panes pane_count pane attempt=0
  while [ "$attempt" -lt 20 ]; do
    attempt=$((attempt + 1))
    workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || { sleep 0.05; continue; }
    ws_count=$(printf '%s' "$workspaces" | jq --arg want "$label" \
      '[.result.workspaces[]? | select(.label == $want)] | length' 2>/dev/null) || { sleep 0.05; continue; }
    if [ "$ws_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$ws_count" = 1 ] || return 1
    wsid=$(printf '%s' "$workspaces" | jq -r --arg want "$label" \
      '.result.workspaces[]? | select(.label == $want) | .workspace_id' 2>/dev/null) || return 1
    [ -n "$wsid" ] || return 1
    panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || { sleep 0.05; continue; }
    pane_count=$(printf '%s' "$panes" | jq '[.result.panes[]?] | length' 2>/dev/null) || { sleep 0.05; continue; }
    if [ "$pane_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$pane_count" = 1 ] || return 1
    pane=$(printf '%s' "$panes" | jq -r '.result.panes[0].pane_id // empty' 2>/dev/null) || return 1
    [ -n "$pane" ] || return 1
    printf '%s\t%s' "$wsid" "$pane"
    return 0
  done
  return 1
}

# --- stop / reconcile / status -----------------------------------------------------------------
bridge_stop() {
  local read_result result=0
  bridge_record_read
  read_result=$?
  if [ "$read_result" -eq 2 ]; then
    echo "watcher bridge: FAILED - malformed bridge terminal record; refusing to stop without its exact id" >&2
    return 1
  fi
  bridge_stop_owned || result=1
  if [ "$read_result" -eq 0 ]; then
    bridge_close_recorded || result=1
  fi
  if [ "$result" -eq 0 ]; then
    bridge_log "bridge stopped; terminal torn down and record cleared"
  else
    bridge_log "bridge stop incomplete; lifecycle state preserved for retry"
  fi
  return "$result"
}

bridge_reconcile_cmd() {
  if bridge_lock_live; then
    echo "watcher bridge: a live bridge holds the lock; nothing to reconcile" >&2
    return 0
  fi
  bridge_reconcile_recorded
}

bridge_status() {
  local pid="" recorded="none" delivered="none"
  if bridge_lock_live; then
    pid=$(bridge_lock_pid)
    recorded="$(cat "$BRIDGE_LOCK/target" 2>/dev/null || echo unknown)@$(cat "$BRIDGE_LOCK/backend" 2>/dev/null || echo unknown)"
  fi
  if { [ -f "$BRIDGE_RECORD" ] && [ ! -L "$BRIDGE_RECORD" ]; }; then
    recorded="$recorded; terminal=$(bridge_record_read >/dev/null 2>&1 && printf '%s:%s' "$FM_BRIDGE_REC_BACKEND" "$FM_BRIDGE_REC_TARGET" || echo malformed)"
  fi
  [ -f "$BRIDGE_DELIVERED" ] && delivered=$(cat "$BRIDGE_DELIVERED" 2>/dev/null || echo none)
  printf 'codex bridge: %s supervising=%s delivered=%s\n' \
    "${pid:+running pid=$pid}${pid:-not running}" "$recorded" "$delivered"
}

# --- the daemon loop ---------------------------------------------------------------------------
BRIDGE_PID=
BRIDGE_PIDFILE=
BRIDGE_CHILD_PID=
BRIDGE_CHILD_OUT=
BRIDGE_SUCCESSOR_NEXT=0
BRIDGE_CRASH_TIMES=()
BRIDGE_BACKOFF=0
BRIDGE_LAST_TRY=0

bridge_cleanup() {
  local status=$?
  trap - TERM INT HUP
  if [ -n "${BRIDGE_CHILD_PID:-}" ]; then
    kill -TERM "$BRIDGE_CHILD_PID" 2>/dev/null || true
    wait "$BRIDGE_CHILD_PID" 2>/dev/null || true
  fi
  if [ -n "${BRIDGE_CHILD_OUT:-}" ]; then
    rm -f "$BRIDGE_CHILD_OUT" 2>/dev/null || true
  fi
  if [ "$(cat "$BRIDGE_LOCK/pid" 2>/dev/null || true)" = "$BRIDGE_PID" ]; then
    fm_lock_release "$BRIDGE_LOCK" 2>/dev/null || true
  fi
  { [ -z "$BRIDGE_PIDFILE" ]; } || rm -f "$BRIDGE_PIDFILE" 2>/dev/null || true
  bridge_log "bridge shutting down (status=$status)"
  exit "$status"
}

bridge_is_wake_reason() {  # <reason>
  case "$1" in
    signal:*|stale:*|check:*|heartbeat|heartbeat:*) return 0 ;;
  esac
  return 1
}

bridge_record_crash() {  # <rc> <output>
  local rc=$1 output=$2 now t
  now=$(date +%s)
  local -a keep=()
  for t in "${BRIDGE_CRASH_TIMES[@]:-}"; do
    { [ -n "$t" ] && [ $((now - t)) -lt "$BRIDGE_CRASH_WINDOW" ]; } && keep+=("$t")
  done
  keep+=("$now")
  BRIDGE_CRASH_TIMES=("${keep[@]}")
  if [ "${#BRIDGE_CRASH_TIMES[@]}" -gt "$BRIDGE_CRASH_THRESHOLD" ]; then
    bridge_log "watcher exited badly ${#BRIDGE_CRASH_TIMES[@]} times within ${BRIDGE_CRASH_WINDOW}s; backing off ${BRIDGE_CRASH_BACKOFF}s"
    BRIDGE_CRASH_TIMES=()
    BRIDGE_BACKOFF=$BRIDGE_CRASH_BACKOFF
  else
    BRIDGE_BACKOFF=$BRIDGE_WATCH_RESTART_SLEEP
  fi
  { [ -z "$output" ]; } || bridge_log "watcher exited rc=$rc output='${output%%$'\n'*}'"
}

bridge_child_reap() {
  local rc=0 output=""
  if ! wait "$BRIDGE_CHILD_PID"; then
    rc=$?
  fi
  if [ -n "${BRIDGE_CHILD_OUT:-}" ] && [ -e "$BRIDGE_CHILD_OUT" ]; then
    output=$(<"$BRIDGE_CHILD_OUT")
    rm -f "$BRIDGE_CHILD_OUT" 2>/dev/null || true
  fi
  BRIDGE_CHILD_PID=""
  BRIDGE_CHILD_OUT=""
  if [ "$rc" -eq 0 ] && [ -n "$output" ] && bridge_is_wake_reason "$output"; then
    bridge_log "watcher closed with actionable wake: $output"
    # The bridge is delivering this wake to the model, so the next watcher
    # cycle is a handling successor: it must not re-announce the recovery
    # episode the model's handling turn is about to acknowledge.
    BRIDGE_SUCCESSOR_NEXT=1
    return 0
  fi
  if [ "$rc" -eq 0 ]; then
    bridge_log "watcher closed cleanly without a wake reason; restarting"
    return 0
  fi
  bridge_record_crash "$rc" "$output"
  return 0
}

bridge_start_child() {
  BRIDGE_CHILD_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-bridge-watch.XXXXXX") || return 1
  if [ "$BRIDGE_SUCCESSOR_NEXT" = 1 ]; then
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" >"$BRIDGE_CHILD_OUT" 2>>"$BRIDGE_CHILD_ERR" &
  else
    "$WATCH" >"$BRIDGE_CHILD_OUT" 2>>"$BRIDGE_CHILD_ERR" &
  fi
  BRIDGE_CHILD_PID=$!
  BRIDGE_SUCCESSOR_NEXT=0
  return 0
}

bridge_stand_down() {  # <why>
  bridge_log "standing down: $*"
  exit 0
}

# bridge_inject_attempt: one fully identity-revalidated injection attempt.
#   exit 0 - injected and positively confirmed
#   exit 2 - pane busy; retry later
#   exit 3 - composer not confirmed empty; retry later (nothing typed)
#   exit 4 - nothing undelivered in the queue (already doorbelled)
#   exit 1 - submit unconfirmed; retry later, nothing recorded
# Any identity loss calls bridge_stand_down, which exits the whole bridge.
bridge_inject_attempt() {  # <backend> <target> <harness> <session-pid> <identity> <recorded>
  local backend=$1 target=$2 harness=$3 session_pid=$4 identity=$5 recorded=$6
  local verdict prompt delivered
  if bridge_afk_active; then
    bridge_stand_down "away mode is active; the away daemon owns supervision"
  fi
  if ! bridge_session_intact "$session_pid" "$identity"; then
    bridge_stand_down "the recorded session lock no longer names the recorded live session"
  fi
  if ! bridge_targets_exact "$backend" "$target" "$recorded"; then
    bridge_stand_down "the recorded pane no longer resolves to the exact recorded ids"
  fi
  if ! bridge_primary_pinned "$backend" "$target" "$session_pid"; then
    bridge_stand_down "the pane no longer positively hosts the recorded Codex primary identity"
  fi
  delivered=$(fm_bridge_delivered_read)
  if ! fm_bridge_undelivered_pending "$delivered"; then
    return 4
  fi
  if bridge_pane_busy "$backend" "$target" "$harness"; then
    bridge_log "injection deferred: the primary pane is busy (Codex mid-turn)"
    return 2
  fi
  if bridge_pane_input_pending "$backend" "$target"; then
    bridge_log "injection deferred: composer not confirmed empty (pending input, dead-shell prompt, or unreadable pane)"
    return 3
  fi
  # The doorbell carries the newest durable row's classified reason verbatim,
  # so the model sees the same wake line the queue holds (e.g. "stale:
  # default:wH:p2 (idle 244s, possible wedge, escalation 1)"); rows appended
  # between this read and the confirmed submit are covered by the post-submit
  # delivery-point sample.
  reason=$(fm_bridge_queue_top_payload) || {
    bridge_log "injection skipped: the queue no longer holds a wake row"
    return 4
  }
  prompt=$(fm_bridge_wake_line "$reason")
  if [ -z "$prompt" ]; then
    bridge_log "injection refused: the canonical wake prompt could not be constructed"
    return 1
  fi
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$prompt" \
    "$BRIDGE_SUBMIT_RETRIES" "$BRIDGE_SUBMIT_SLEEP" "$BRIDGE_SUBMIT_SLEEP")
  if [ "$verdict" != empty ]; then
    bridge_log "injection unconfirmed after $BRIDGE_SUBMIT_RETRIES Enter attempts (verdict=${verdict:-unknown}); nothing recorded, retry continues"
    return 1
  fi
  if ! fm_bridge_delivered_write; then
    bridge_log "submit confirmed but the delivery marker could not be written; the next tick retries conservatively"
    return 1
  fi
  bridge_log "wake doorbell delivered: $(printf '%s' "$prompt" | cut -c1-200)"
  return 0
}

bridge_tick() {  # <target> <backend> <harness> <session-pid> <identity> <recorded>
  local target=$1 backend=$2 harness=$3 session_pid=$4 identity=$5 recorded=$6
  # Cheap identity gates every tick, even with nothing queued: a dead or
  # replaced session, a stolen singleton, or away mode stands the bridge down.
  if bridge_afk_active; then
    bridge_stand_down "away mode is active; the away daemon owns supervision"
  fi
  if ! bridge_session_intact "$session_pid" "$identity"; then
    bridge_stand_down "the recorded session lock no longer names the recorded live session"
  fi
  if [ "$(cat "$BRIDGE_LOCK/pid" 2>/dev/null || true)" != "$BRIDGE_PID" ]; then
    bridge_stand_down "another bridge generation owns the singleton lock (self-eviction)"
  fi
  if ! fm_backend_target_exists "$backend" "$target" 2>/dev/null; then
    bridge_log "primary target '$target' gone; backing off ${BRIDGE_PANE_GONE_SLEEP}s (queued wakes stay durable)"
    sleep "$BRIDGE_PANE_GONE_SLEEP"
    return 0
  fi
  # Queue-driven injection cadence: full identity revalidation, pane guards,
  # then the doorbell. The expensive pane reads run only when something is
  # actually undelivered, so an idle fleet costs one cheap lock/exists read.
  if fm_bridge_undelivered_pending "$(fm_bridge_delivered_read)" \
    && [ $(( $(date +%s) - BRIDGE_LAST_TRY )) -ge "$BRIDGE_INJECT_RETRY_SECS" ]; then
    BRIDGE_LAST_TRY=$(date +%s)
    bridge_inject_attempt "$backend" "$target" "$harness" "$session_pid" "$identity" "$recorded" || true
  fi
}

bridge_run() {  # <target> <backend> <harness> <session-pid> <identity> <recorded-ids> <generation>
  local target=$1 backend=$2 harness=$3 session_pid=$4 identity=$5 recorded=$6 generation=$7
  mkdir -p "$STATE"
  if ! fm_lock_try_acquire "$BRIDGE_LOCK"; then
    if bridge_lock_live; then
      echo "error: another codex watch bridge is already running (pid $(bridge_lock_pid), lock $BRIDGE_LOCK held)" >&2
    else
      echo "error: the bridge lock at $BRIDGE_LOCK could not be acquired" >&2
    fi
    exit 1
  fi
  BRIDGE_PID=${BASHPID:-$$}
  BRIDGE_PIDFILE="$STATE/.watch-codex-bridge.pid"
  printf '%s\n' "$BRIDGE_PID" > "$BRIDGE_PIDFILE" 2>/dev/null || true
  if ! printf '%s' "$session_pid" > "$BRIDGE_LOCK/session-pid" 2>/dev/null \
    || ! printf '%s' "$identity" > "$BRIDGE_LOCK/session-identity" 2>/dev/null \
    || ! printf '%s' "$target" > "$BRIDGE_LOCK/target" 2>/dev/null \
    || ! printf '%s' "$backend" > "$BRIDGE_LOCK/backend" 2>/dev/null \
    || ! printf '%s' "$generation" > "$BRIDGE_LOCK/generation" 2>/dev/null \
    || ! printf '%s' "$FM_HOME" > "$BRIDGE_LOCK/home" 2>/dev/null \
    || ! printf '%s' "$recorded" > "$BRIDGE_LOCK/pane-ids" 2>/dev/null; then
    fm_lock_release "$BRIDGE_LOCK" 2>/dev/null || true
    echo "error: the bridge identity could not be bound to its lock" >&2
    exit 1
  fi
  printf '%s\n' "$(fm_pid_identity "$BRIDGE_PID" 2>/dev/null)" > "$BRIDGE_LOCK/pid-identity" 2>/dev/null || true
  trap bridge_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  bridge_log "bridge starting (pid $BRIDGE_PID, generation $generation); target=$target backend=$backend harness=$harness session_pid=$session_pid pane_ids=$recorded"

  while :; do
    if bridge_afk_active; then
      bridge_stand_down "away mode is active; the away daemon owns supervision"
    fi
    if ! bridge_session_intact "$session_pid" "$identity"; then
      bridge_stand_down "the recorded session lock no longer names the recorded live session"
    fi
    if [ "$(cat "$BRIDGE_LOCK/pid" 2>/dev/null || true)" != "$BRIDGE_PID" ]; then
      bridge_stand_down "another bridge generation owns the singleton lock (self-eviction)"
    fi
    if [ -z "${BRIDGE_CHILD_PID:-}" ] || ! kill -0 "$BRIDGE_CHILD_PID" 2>/dev/null; then
      if [ -n "${BRIDGE_CHILD_PID:-}" ]; then
        bridge_child_reap
        if [ "$BRIDGE_BACKOFF" -gt 0 ]; then
          sleep "$BRIDGE_BACKOFF"
          BRIDGE_BACKOFF=0
        fi
      fi
      if ! bridge_session_intact "$session_pid" "$identity"; then
        bridge_stand_down "the recorded session lock no longer names the recorded live session"
      fi
      bridge_start_child || bridge_log "watcher child could not start; retrying next tick"
    fi
    bridge_tick "$target" "$backend" "$harness" "$session_pid" "$identity" "$recorded"
    sleep "$BRIDGE_POLL"
  done
}

bridge_run_entry() {
  # The arm passes the daemon exactly one piece of env - where the binding
  # record lives - because the tracked terminal's launch transport is a
  # keystroke path that truncates long command lines. Everything else is read
  # from the binding file the arm wrote and validated before launching.
  local binding=${FM_BRIDGE_BINDING:-}
  if [ -z "$binding" ] || [ "${FM_BRIDGE_HARNESS:-}" != codex ]; then
    echo "error: bridge run requires FM_BRIDGE_BINDING and FM_BRIDGE_HARNESS=codex (set by the tracked-terminal launch command)" >&2
    return 2
  fi
  if ! bridge_read_binding; then
    echo "error: the bridge launch binding record is missing or malformed; refusing to start" >&2
    return 1
  fi
  if ! bridge_validate_binding "$FM_BRIDGE_BIND_BACKEND" "$FM_BRIDGE_BIND_TARGET" \
    "$FM_BRIDGE_BIND_PID" "$FM_BRIDGE_BIND_IDENTITY" "$FM_BRIDGE_BIND_GENERATION" \
    "$FM_BRIDGE_BIND_PANE_IDS"; then
    return 1
  fi
  bridge_run "$FM_BRIDGE_BIND_TARGET" "$FM_BRIDGE_BIND_BACKEND" codex \
    "$FM_BRIDGE_BIND_PID" "$FM_BRIDGE_BIND_IDENTITY" "$FM_BRIDGE_BIND_PANE_IDS" \
    "$FM_BRIDGE_BIND_GENERATION"
}

# Re-validate the binding the arm recorded before the daemon trusts it: the
# session lock must still name a live identity-matched harness pid, the exact
# pane ids recorded at arm time must still resolve to the same ids, and the
# pane must still positively host that session pid. Any failure is a refusal:
# a stale or mutated binding never starts a daemon.
bridge_validate_binding() {  # <backend> <target> <session-pid> <identity> <generation> [recorded-ids]
  local backend=$1 target=$2 session_pid=$3 identity=$4 generation=$5 recorded
  local recorded_at_arm=${6:-${FM_BRIDGE_PANE_IDS:-}}
  case "$backend" in
    tmux|herdr) ;;
    *)
      echo "error: unsupported bridge backend '$backend' (supported: $FM_BRIDGE_SUPPORTED_BACKENDS)" >&2
      return 1
      ;;
  esac
  case "$generation" in ''|*[!A-Za-z0-9._-]*)
    echo "error: invalid bridge generation token" >&2
    return 1
    ;;
  esac
  case "$session_pid" in ''|*[!0-9]*|0)
    echo "error: invalid bridge session pid" >&2
    return 1
    ;;
  esac
  [ -n "$identity" ] || {
    echo "error: invalid bridge session identity" >&2
    return 1
  }
  if ! fm_harness_pid_alive "$session_pid" || [ "$(fm_pid_identity "$session_pid" 2>/dev/null)" != "$identity" ]; then
    echo "error: the recorded session pid is not the recorded live harness identity; refusing to start" >&2
    return 1
  fi
  if [ -z "${FM_BRIDGE_SKIP_PANE_VALIDATION:-}" ]; then
    if ! fm_backend_target_exists "$backend" "$target" 2>/dev/null; then
      echo "error: primary target '$target' does not resolve to a $backend pane" >&2
      return 1
    fi
    if ! recorded=$(fm_bridge_pane_ids "$backend" "$target"); then
      echo "error: could not read the exact pane identity for '$target'" >&2
      return 1
    fi
    if [ "$recorded" != "$recorded_at_arm" ]; then
      echo "error: the primary pane's exact ids changed between arm and start; refusing a stale binding" >&2
      return 1
    fi
    if ! bridge_primary_pinned "$backend" "$target" "$session_pid"; then
      echo "error: the pane does not positively host the recorded session pid" >&2
      return 1
    fi
  fi
  return 0
}

bridge_usage() {
  sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

bridge_main() {
  local command=${1:-}
  case "$command" in
    arm)
      [ "$#" -eq 1 ] || { bridge_usage >&2; return 2; }
      bridge_arm
      ;;
    stop)
      [ "$#" -eq 1 ] || { bridge_usage >&2; return 2; }
      bridge_stop
      ;;
    reconcile)
      [ "$#" -eq 1 ] || { bridge_usage >&2; return 2; }
      bridge_reconcile_cmd
      ;;
    status)
      bridge_status
      ;;
    run)
      [ "$#" -eq 1 ] || { bridge_usage >&2; return 2; }
      bridge_run_entry
      ;;
    -h|--help|help)
      bridge_usage
      ;;
    *)
      bridge_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

bridge_main "$@"
