#!/usr/bin/env bash
# shellcheck disable=SC2034 # Probe/relaunch output globals are read by sourcing callers.
# fm-secondmate-liveness-lib.sh - shared persistent-secondmate endpoint liveness
# probing and recovery. bin/fm-bootstrap.sh owns the session-start sweep and
# bin/fm-watch.sh owns the ordinary-supervision poll tick; both drive this
# library so classification handling and the guarded relaunch path stay
# single-sourced here.
#
# A secondmate's recorded endpoint is the tmux window, herdr pane, or remote
# peer it runs in. Probing classifies that endpoint through the owning backend
# adapter's fm_backend_agent_state (local) or the remote control script's
# state verb (remote), which returns one of:
#
#   alive       - a primary-agent runtime is positively running
#   dead        - the endpoint exists, but no agent is running in it
#   missing     - the endpoint itself is gone
#   ambiguous   - backend inventory could not prove either way
#   unreadable  - backend state exists but could not be parsed
#   unverified  - the endpoint is recorded under a session this home does not
#                 own, so probing is not authorized
#
# Only `dead` and `missing` are recovery candidates; the generation-bound
# recheck and seat reclamation below must authorize replacement before any
# endpoint is closed or spawn is attempted. In particular, a shell-only
# endpoint from an unconfirmed submitted launch can still start its agent.
# `ambiguous`, `unreadable`, and `unverified` leave the endpoint untouched -
# relaunching on inconclusive evidence could create a second endpoint beside a
# live one - and an unreachable remote host is never evidence of death, so a
# remote route is never replaced by a local endpoint.
#
# Relaunch goes through `bin/fm-spawn.sh <id> --secondmate` with
# FM_SPAWN_NO_GUARD=1, the same guarded path every recovery uses. That path
# re-resolves placement from the task's own metadata and registry route, so a
# remote mate is relaunched on its recorded remote host through bin/fm-on.sh -
# never as a local replacement - behind fm-spawn's own readiness gate and
# per-task spawn lock.
#
# Modes:
#   full - session-start sweep: remote routes run the full readiness repair
#          sequence before probing, and an alive remote route is revalidated
#          (route readable, backend herdr) so the sweep reports drift.
#   poll - watcher tick: remote routes take one read-only state probe per
#          check; repair still happens, but inside fm-spawn's launch gate only
#          when a relaunch is actually authorized.
#
# Concurrency: .secondmate-liveness-<id>.lock is the ONE supervisor lifecycle
# episode mutex for that task in this home. The bootstrap sweep and watcher
# tick take it without waiting and skip a busy mate; initial and recovery
# secondmate spawn, local relaunch and exit, the parent remote relaunch
# wrapper, and the host-local remote control verbs join it too, so a stale
# death probe can never act on a generation another episode already replaced.
# A nested lifecycle process (liveness -> spawn, control -> spawn, host control
# -> control -> spawn) adopts the owner's hold through the verified carrier
# below instead of acquiring or releasing it. Acquisition order across the
# fleet is: this episode mutex, then the control/spawn/registry locks, then the
# task metadata lock, then the fleet seat lock (bin/fm-fleet-seats.sh).
# The attempt ledger (.secondmate-relaunch-<id>, one line per attempt plus one
# per outcome) is both the durable relaunch record and the input to the
# watcher's relaunch bound; teardown removes it.

set -u

FM_SM_LIVE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=bin/fm-backend.sh
. "$FM_SM_LIVE_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-remote-readiness-lib.sh
. "$FM_SM_LIVE_LIB_DIR/fm-remote-readiness-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_SM_LIVE_LIB_DIR/fm-timeout-lib.sh"

# Per-task probe+kill+relaunch serialization. A busy lock means another
# supervisor (the other sweep, or a racing tick) is mid-episode on this mate;
# callers skip and let that episode finish rather than probe a moving target.
# The lock helpers live in bin/fm-wake-lib.sh, which creates the state
# directory when sourced; load it only when a lock is actually taken so that
# sourcing this library stays side-effect free for read-only bootstrap runs.
fm_sm_live_require_locks() {
  command -v fm_lock_try_acquire >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_SM_LIVE_LIB_DIR/fm-wake-lib.sh"
}

fm_secondmate_liveness_lock() {  # <id>
  fm_supervisor_lifecycle_acquire "$STATE" "$1" 0
}

fm_secondmate_liveness_unlock() {  # <id>
  fm_supervisor_lifecycle_release "$STATE" "$1"
}

# --- supervisor lifecycle episode mutex ---------------------------------------
#
# fm_supervisor_lifecycle_acquire <state-dir> <id> <wait-secs>
#   Take the episode mutex (0 = try once, the automatic callers' skip-if-busy
#   shape; N = bounded wait for a manual caller). On success it publishes the
#   inheritance carrier FM_SUPERVISOR_LIFECYCLE_CARRIER for child lifecycle
#   processes and returns 0; a busy mutex returns 1 with FM_LOCK_HELD_PID set.
# fm_supervisor_lifecycle_adopt <state-dir> <id>
#   Verify an inherited carrier for exactly this mutex and adopt it without
#   taking or releasing anything. Returns 0 when adopted, 1 when no carrier
#   names this mutex, and 2 when a carrier names it but fails verification
#   (wrong holder, process identity, episode token, or an owner that is not
#   this process's ancestor) - a caller must refuse rather than acquire then.
# fm_supervisor_lifecycle_enter <state-dir> <id> <wait-secs>
#   Adopt when a verified carrier names the mutex, else acquire; a failed
#   carrier verification refuses.
# fm_supervisor_lifecycle_release <state-dir> <id>
#   Release only a hold this process acquired; an adopted hold stays with its
#   owner, whose exit path releases it.
#
# The carrier is "<canonical-lock-path>|<pid>|<pid-identity-cksum>|<episode>".
# The episode token lives in the sidecar file <lock>.episode, written by the
# holder after it owns the lock, so a stale carrier from an earlier episode
# never matches a newer hold of the same path.
FM_SUPERVISOR_LIFECYCLE_HELD=

fm_supervisor_lifecycle_lock_path() {  # <state-dir> <id>
  local dir
  case "${2-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  dir=$(cd "${1-}" 2>/dev/null && pwd -P) || return 1
  printf '%s/.secondmate-liveness-%s.lock\n' "$dir" "$2"
}

fm_sm_lifecycle_identity() {  # <pid>
  local identity
  identity=$(fm_pid_identity "$1" 2>/dev/null) || return 1
  printf '%s' "$identity" | cksum | tr -s ' ' '-' | cut -d- -f1-2
}

# fm_sm_lifecycle_is_ancestor <pid>: <pid> is this process or one of its
# ancestors. Bounded walk; any unreadable step answers no.
fm_sm_lifecycle_is_ancestor() {  # <pid>
  local want=$1 cur depth=0 next
  fm_current_pid cur || return 1
  while [ "$depth" -lt 64 ]; do
    [ "$cur" != "$want" ] || return 0
    case "$cur" in ''|*[!0-9]*|0|1) return 1 ;; esac
    next=$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ') || return 1
    [ -n "$next" ] && [ "$next" != "$cur" ] || return 1
    cur=$next
    depth=$((depth + 1))
  done
  return 1
}

fm_supervisor_lifecycle_acquire() {  # <state-dir> <id> <wait-secs>
  local lock wait=${3:-0} me identity episode
  fm_sm_live_require_locks || return 1
  lock=$(fm_supervisor_lifecycle_lock_path "$1" "$2") || return 1
  case "$wait" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$wait" -gt 0 ]; then
    fm_lock_acquire_wait_max "$lock" "$wait" || return 1
  else
    fm_lock_try_acquire "$lock" || return 1
  fi
  fm_current_pid me || { fm_lock_release "$lock" 2>/dev/null || true; return 1; }
  identity=$(fm_sm_lifecycle_identity "$me") || identity=unknown
  episode="e$(date +%s).$me.$RANDOM$RANDOM"
  if ! { printf '%s\n' "$episode" > "$lock.episode.tmp.$me" \
      && mv -f "$lock.episode.tmp.$me" "$lock.episode"; } 2>/dev/null; then
    rm -f "$lock.episode.tmp.$me" 2>/dev/null || true
    fm_lock_release "$lock" 2>/dev/null || true
    return 1
  fi
  FM_SUPERVISOR_LIFECYCLE_HELD="$FM_SUPERVISOR_LIFECYCLE_HELD$lock
"
  FM_SUPERVISOR_LIFECYCLE_CARRIER="$lock|$me|$identity|$episode"
  export FM_SUPERVISOR_LIFECYCLE_CARRIER
  return 0
}

fm_supervisor_lifecycle_adopt() {  # <state-dir> <id>
  local lock carrier c_lock c_pid c_identity c_episode rest holder now
  carrier=${FM_SUPERVISOR_LIFECYCLE_CARRIER:-}
  [ -n "$carrier" ] || return 1
  lock=$(fm_supervisor_lifecycle_lock_path "$1" "$2") || return 2
  c_lock=${carrier%%|*}
  rest=${carrier#*|}
  [ "$c_lock" = "$lock" ] || return 1
  c_pid=${rest%%|*}
  rest=${rest#*|}
  c_identity=${rest%%|*}
  c_episode=${rest#*|}
  case "$c_pid" in ''|*[!0-9]*) return 2 ;; esac
  [ -n "$c_episode" ] && [ "$c_episode" != "$rest" ] || return 2
  fm_sm_live_require_locks || return 2
  holder=$(cat "$lock/pid" 2>/dev/null || true)
  [ "$holder" = "$c_pid" ] || return 2
  fm_pid_alive "$c_pid" || return 2
  now=$(fm_sm_lifecycle_identity "$c_pid") || now=unknown
  [ "$now" = "$c_identity" ] || return 2
  [ "$(cat "$lock.episode" 2>/dev/null || true)" = "$c_episode" ] || return 2
  fm_sm_lifecycle_is_ancestor "$c_pid" || return 2
  return 0
}

fm_supervisor_lifecycle_enter() {  # <state-dir> <id> <wait-secs>
  local rc=0
  fm_supervisor_lifecycle_adopt "$1" "$2" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) fm_supervisor_lifecycle_acquire "$1" "$2" "${3:-0}" ;;
    *) return 2 ;;
  esac
}

fm_supervisor_lifecycle_release() {  # <state-dir> <id>
  local lock me held='' kept='' one
  lock=$(fm_supervisor_lifecycle_lock_path "$1" "$2") || return 0
  while IFS= read -r one; do
    [ -n "$one" ] || continue
    if [ "$one" = "$lock" ]; then
      held=1
    else
      kept="$kept$one
"
    fi
  done <<EOF_HELD
$FM_SUPERVISOR_LIFECYCLE_HELD
EOF_HELD
  [ -n "$held" ] || return 0
  fm_sm_live_require_locks || return 0
  fm_current_pid me || return 0
  if [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$me" ]; then
    rm -f "$lock.episode" 2>/dev/null || true
    fm_lock_release "$lock" 2>/dev/null || true
  fi
  FM_SUPERVISOR_LIFECYCLE_HELD=$kept
  case "${FM_SUPERVISOR_LIFECYCLE_CARRIER:-}" in
    "$lock|"*) unset FM_SUPERVISOR_LIFECYCLE_CARRIER ;;
  esac
  return 0
}

fm_remote_seat_receipts_for_generation() {
  local state=$1 id=$2 gen=$3 receipt op
  [ -n "$gen" ] || return 0
  for receipt in "$state/$id.seat-operation."*; do
    [ -f "$receipt" ] && [ ! -L "$receipt" ] || continue
    op=${receipt##*.seat-operation.}
    awk -F= -v op="$op" -v gen="$gen" -v receipt="$receipt" '
      { count[$1]++; value[$1] = substr($0, length($1) + 2) }
      END {
        if (count["schema"] != 1 || value["schema"] != "fm-remote-seat-receipt.v1" ||
            count["operation"] != 1 || value["operation"] != op ||
            count["requested_generation"] != 1 || value["requested_generation"] != op ||
            count["actual_generation"] > 1 || count["phase"] != 1) exit
        actual = value["actual_generation"]
        if (actual == "") actual = op
        if (actual == gen) printf "%s\t%s\t%s\n", receipt, op, value["phase"]
      }
    ' "$receipt"
  done
}

# fm_remote_seat_receipt_validate <receipt> <operation> <generation>
# Malformed or foreign evidence cannot authorize a settled disposition or write.
fm_remote_seat_receipt_validate() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  awk -F= -v op="$2" -v gen="$3" '
    { count[$1]++; value[$1] = substr($0, length($1) + 2) }
    END {
      for (key in count) if (count[key] != 1) exit 1
      if (value["schema"] != "fm-remote-seat-receipt.v1" ||
          value["operation"] != op || value["requested_generation"] != gen ||
          (value["verb"] != "launch" && value["verb"] != "relaunch") ||
          value["previous_generation"] == "" ||
          value["phase"] !~ /^(received|prelaunch|existing|dispatched|started|dead-after-start|cancelled)$/) exit 1
    }
  ' "$1"
}

# fm_remote_seat_receipt_update <receipt> <operation> <generation> <key=value>...
#
# The host operation receipt (<host-state>/parent-route/<id>.seat-operation.<gen>) is
# opened by bin/fm-remote-secondmate-control.sh, which owns its schema, before
# any endpoint effect; a host-local launch inside that same episode records its
# delivery and startup through this one writer. Refuses unless the receipt is
# a valid receipt naming exactly <operation> and <generation> and the inherited
# lifecycle carrier verifies for the receipt's state directory and task.
# Prelaunch updates also require an unsubmitted phase; values never carry newlines.
fm_remote_seat_receipt_update() {
  local receipt=$1 op=$2 gen=$3 tmp kv key name id phase
  shift 3
  name=${receipt##*/}
  id=${name%".seat-operation.$op"}
  [ "$name" = "$id.seat-operation.$op" ] || return 1
  if ! fm_supervisor_lifecycle_adopt "${receipt%/*}" "$id"; then
    printf 'error: seat receipt update requires the verified lifecycle episode for %s\n' "$id" >&2
    return 1
  fi
  fm_remote_seat_receipt_validate "$receipt" "$op" "$gen" || return 1
  phase=$(sed -n 's/^phase=//p' "$receipt")
  for kv in "$@"; do
    if [ "$kv" = phase=prelaunch ]; then
      case "$phase" in received|prelaunch) ;; *) return 1 ;; esac
    fi
  done
  tmp="$receipt.tmp.$$"
  (umask 077 && cp "$receipt" "$tmp") || return 1
  for kv in "$@"; do
    case "$kv" in *=*) ;; *) rm -f "$tmp"; return 1 ;; esac
    case "$kv" in *$'\n'*) rm -f "$tmp"; return 1 ;; esac
    key=${kv%%=*}
    if ! { { grep -v "^$key=" "$tmp" || true; printf '%s\n' "$kv"; } > "$tmp.next" && mv -f "$tmp.next" "$tmp"; }; then
      rm -f "$tmp" "$tmp.next"
      return 1
    fi
  done
  chmod 0600 "$tmp" && mv -f "$tmp" "$receipt"
}

fm_sm_live_first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

# One line per relaunch attempt and one per outcome, keyed by epoch, plus a
# `rearmed` row when a live probe lifts a parked mate. The watcher bound counts
# `attempt` rows inside its window and after the last `rearmed` row; the whole
# file is the durable per-mate relaunch record the captain can count to see
# frequency. Fails when the row cannot be appended.
fm_secondmate_liveness_ledger_add() {  # <id> <attempt|relaunched|failed|rearmed>
  printf '%s\t%s\n' "$(date +%s)" "$2" >> "$STATE/.secondmate-relaunch-$1" 2>/dev/null
}

# Count of attempt rows no older than <window-secs> that follow the last
# `rearmed` row. An absent ledger counts
# zero; an existing ledger that cannot be read fails rather than counting zero.
fm_secondmate_liveness_recent_attempts() {  # <id> <window-secs>
  local id=$1 window=$2 now cutoff ledger
  ledger="$STATE/.secondmate-relaunch-$id"
  if [ ! -e "$ledger" ] && [ ! -L "$ledger" ]; then
    printf '0\n'
    return 0
  fi
  now=$(date +%s)
  cutoff=$((now - window))
  awk -F '\t' -v cutoff="$cutoff" \
    '$2 == "rearmed" { n = 0; next } $1 ~ /^[0-9]+$/ && $1 >= cutoff && $2 == "attempt" { n++ } END { print n + 0 }' \
    "$ledger" 2>/dev/null
}

# fm_secondmate_liveness_probe <meta> <id> <full|poll>
#
# Read-only probe of one registered secondmate's recorded endpoint. Populates:
#
#   FM_SM_LIVE_STATUS  silent | alive | relaunchable | skipped
#   FM_SM_LIVE_STATE   the raw classifier/state word
#   FM_SM_LIVE_KILL    1 when relaunch must first kill a confirmed-dead local
#                      endpoint (its shell husk occupies the name)
#   FM_SM_LIVE_CAUSE   relaunch cause phrase, on relaunchable
#   FM_SM_LIVE_WHERE   backend=<b> or host=<h>, on relaunchable
#   FM_SM_LIVE_REASON  exact skip suffix, on skipped
#   FM_SM_LIVE_LINE    verbose already-live line body, on alive
#   FM_SM_LIVE_GENERATION  the incarnation the record names (its fleet seat
#                      generation, else spawn_gen), so a verdict is bound to it
#   FM_SM_LIVE_ROUTE   the exact endpoint or host route the verdict is about
#
# `silent` means the meta records no endpoint at all - that shape is owned by
# secondmate-provisioning recovery, not liveness.
#
# The caller must hold fm_secondmate_liveness_lock for <id> whenever a
# relaunchable verdict could be acted on.
fm_secondmate_liveness_probe() {  # <meta> <id> <full|poll>
  local meta=$1 id=$2 mode=$3
  FM_SM_LIVE_STATUS=skipped FM_SM_LIVE_STATE=unknown FM_SM_LIVE_KILL=0
  FM_SM_LIVE_CAUSE='' FM_SM_LIVE_WHERE='' FM_SM_LIVE_REASON='' FM_SM_LIVE_LINE=''
  FM_SM_LIVE_GENERATION='' FM_SM_LIVE_ROUTE='' FM_SM_LIVE_BACKEND='' FM_SM_LIVE_TARGET=''
  local window harness remote_host remote_rc out agent_state readiness_reason route_out remote_backend seat_record incarnation backend target
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] || { FM_SM_LIVE_STATUS=silent; return 0; }
  harness=$(fm_meta_get "$meta" harness)
  remote_host=$(fm_meta_get "$meta" remote_host)
  FM_SM_LIVE_GENERATION=$(fm_meta_get "$meta" fleet_seat_generation)
  [ -n "$FM_SM_LIVE_GENERATION" ] || FM_SM_LIVE_GENERATION=$(fm_meta_get "$meta" remote_spawn_gen)
  [ -n "$FM_SM_LIVE_GENERATION" ] || FM_SM_LIVE_GENERATION=$(fm_meta_get "$meta" spawn_gen)
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target="$window"
  if ! seat_record=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$FM_SM_LIVE_LIB_DIR/fm-fleet-seats.sh" show "$id" 2>/dev/null); then
    FM_SM_LIVE_REASON="the fleet seat ledger could not be read; recovery is refused"
    return 0
  fi
  if [ -n "$seat_record" ]; then
    incarnation=$(printf '%s\n' "$seat_record" | jq -c --arg g "$FM_SM_LIVE_GENERATION" '
      [.incarnations[] | select(.lifecycle == "reserved" or .lifecycle == "confirmed")]
      | (map(select(.generation == $g)) | last) // (map(select(.lifecycle == "confirmed")) | last) // last // empty')
    if [ -n "$incarnation" ]; then
      FM_SM_LIVE_GENERATION=$(printf '%s\n' "$incarnation" | jq -r .generation)
      if [ "$(printf '%s\n' "$incarnation" | jq -r '.route.placement // empty')" = local ]; then
        backend=$(printf '%s\n' "$incarnation" | jq -r .route.backend)
        target=$(printf '%s\n' "$incarnation" | jq -r .route.target)
      fi
    fi
  fi
  FM_SM_LIVE_BACKEND=$backend FM_SM_LIVE_TARGET=$target
  if [ -n "$remote_host" ]; then
    target=$(fm_meta_get "$meta" remote_target)
    if [ -n "${incarnation:-}" ]; then
      route_out=$(printf '%s\n' "$incarnation" | jq -r '.route.target // empty')
      [ -z "$route_out" ] || target=$route_out
    fi
    FM_SM_LIVE_ROUTE="remote:$remote_host:$target"
  else
    FM_SM_LIVE_ROUTE="$backend:$target"
  fi
  if [ -n "$remote_host" ]; then
    if [ "$mode" = full ]; then
      remote_rc=0
      fm_remote_readiness_ensure "$FM_SM_LIVE_LIB_DIR" "$id" || remote_rc=$?
      if [ "$remote_rc" -eq 255 ]; then
        FM_SM_LIVE_REASON="remote host unavailable or endpoint state unknown; route preserved on $remote_host"
        return 0
      fi
      if [ "$remote_rc" -ne 0 ]; then
        readiness_reason=$(printf '%s\n' "$FM_REMOTE_READINESS_OUT" \
          | awk '/^check [^=]+=(fixable|human):|^action:|^error:/ { print; exit }')
        [ -n "$readiness_reason" ] || readiness_reason=$(fm_sm_live_first_line "$FM_REMOTE_READINESS_OUT")
        [ -n "$readiness_reason" ] || readiness_reason="unknown readiness failure"
        FM_SM_LIVE_REASON="remote readiness failed on $remote_host: $readiness_reason"
        return 0
      fi
    fi
    if out=$("$FM_SM_LIVE_LIB_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh state "$id" < /dev/null 2>/dev/null); then
      remote_rc=0
    else
      remote_rc=$?
    fi
    if [ "$remote_rc" -eq 255 ]; then
      FM_SM_LIVE_REASON="remote host unavailable or endpoint state unknown; route preserved on $remote_host"
      return 0
    fi
    if [ "$remote_rc" -ne 0 ]; then
      FM_SM_LIVE_REASON="remote endpoint probe unreadable on $remote_host"
      return 0
    fi
    agent_state=$(printf '%s\n' "$out" | tail -1)
    FM_SM_LIVE_STATE=$agent_state
    case "$agent_state" in
      alive)
        if [ "$mode" = full ]; then
          if route_out=$("$FM_SM_LIVE_LIB_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh route "$id" < /dev/null 2>/dev/null); then
            remote_rc=0
          else
            remote_rc=$?
          fi
          if [ "$remote_rc" -eq 255 ]; then
            FM_SM_LIVE_REASON="remote host unavailable or endpoint route unknown; route preserved on $remote_host"
            return 0
          fi
          if [ "$remote_rc" -ne 0 ]; then
            FM_SM_LIVE_REASON="alive remote endpoint route is unreadable on $remote_host; inspect and migrate or retire it explicitly"
            return 0
          fi
          remote_backend=$(printf '%s\n' "$route_out" | sed -n 's/^backend=//p' | tail -1)
          if [ "$remote_backend" != herdr ]; then
            FM_SM_LIVE_REASON="alive remote endpoint is recorded on backend '${remote_backend:-missing}'; migrate or retire it explicitly"
            return 0
          fi
        fi
        FM_SM_LIVE_STATUS=alive
        FM_SM_LIVE_LINE="remote secondmate $id already live (host=$remote_host)"
        ;;
      dead|missing)
        FM_SM_LIVE_STATUS=relaunchable
        FM_SM_LIVE_CAUSE="remote endpoint $agent_state on its configured host"
        FM_SM_LIVE_WHERE="host=$remote_host"
        ;;
      ambiguous|unreadable|unverified)
        FM_SM_LIVE_REASON="remote endpoint state is $agent_state on $remote_host"
        ;;
      *)
        FM_SM_LIVE_REASON="remote endpoint returned an invalid state"
        ;;
    esac
    return 0
  fi

  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || agent_state=unreadable
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|omp) ;;
    *)
      case "$agent_state" in dead|missing) agent_state=unverified-harness ;; esac
      ;;
  esac
  FM_SM_LIVE_STATE=$agent_state
  case "$agent_state" in
    alive)
      FM_SM_LIVE_STATUS=alive
      FM_SM_LIVE_LINE="secondmate $id already live (backend=$backend)"
      ;;
    dead|missing)
      FM_SM_LIVE_STATUS=relaunchable
      if [ "$agent_state" = dead ]; then
        FM_SM_LIVE_KILL=1
        FM_SM_LIVE_CAUSE="confirmed agent absence on existing endpoint"
      else
        FM_SM_LIVE_CAUSE="recorded endpoint confidently missing"
      fi
      FM_SM_LIVE_WHERE="backend=$backend"
      ;;
    ambiguous)
      FM_SM_LIVE_REASON="existing endpoint has ambiguous agent process (backend=$backend)"
      ;;
    unreadable)
      FM_SM_LIVE_REASON="endpoint probe unreadable (backend=$backend)"
      ;;
    unverified-harness)
      FM_SM_LIVE_REASON="recorded harness '$harness' is unverified for recovery (backend=$backend)"
      ;;
    *)
      FM_SM_LIVE_REASON="agent recovery classifier unverified (backend=$backend)"
      ;;
  esac
  return 0
}

# fm_secondmate_liveness_relaunch <meta> <id> [timeout-secs]
#
# Acts on a `relaunchable` probe verdict for <id>. It first reloads the record
# and re-probes under the same episode: a verdict whose generation or route
# changed, or that no longer reads dead or missing, is abandoned rather than
# acted on. It then asks the fleet seat owner to reclaim exactly the probed
# generation (bin/fm-fleet-seats.sh reclaim, which collects its own endpoint
# or host evidence); a generation that cannot be proven finished - for example
# a submitted launch whose endpoint still holds only a shell - stays counted
# and nothing is killed or spawned. Only then does it kill a confirmed-dead
# local endpoint (FM_SM_LIVE_KILL), record the attempt and its outcome in the
# per-mate ledger, and run the guarded secondmate spawn, which reserves a new
# generation inside this same episode. A positive timeout wraps the spawn in
# fm_run_timed so a watcher poll stays bounded; 124/137 mean the bound fired.
# Returns the spawn exit status; combined spawn output is in FM_SM_LIVE_OUT and
# the status in FM_SM_LIVE_RC. When the verdict is abandoned, the seat cannot
# be reclaimed, the ledger cannot be read, or the attempt row cannot be
# appended, nothing is killed or spawned: the verdict becomes
# FM_SM_LIVE_STATUS=skipped with FM_SM_LIVE_REASON set and this returns 1.
# Caller holds the liveness lock and owns reporting.
fm_secondmate_liveness_relaunch() {  # <meta> <id> [timeout-secs]
  local meta=$1 id=$2 timeout=${3:-} probed_gen probed_route seat_out seat_rc
  FM_SM_LIVE_OUT='' FM_SM_LIVE_RC=0
  probed_gen=$FM_SM_LIVE_GENERATION
  probed_route=$FM_SM_LIVE_ROUTE
  fm_secondmate_liveness_probe "$meta" "$id" poll
  if [ "$FM_SM_LIVE_STATUS" != relaunchable ] || [ "$FM_SM_LIVE_GENERATION" != "$probed_gen" ] \
    || [ "$FM_SM_LIVE_ROUTE" != "$probed_route" ]; then
    FM_SM_LIVE_STATUS=skipped
    FM_SM_LIVE_REASON="the recorded incarnation or its endpoint changed since it was probed (now $FM_SM_LIVE_STATE); left for the next check"
    FM_SM_LIVE_RC=1
    return 1
  fi
  if [ -n "$probed_gen" ]; then
    local seat_home=$FM_HOME seat_config=${CONFIG:-$FM_HOME/config} seat_data=${DATA:-$FM_HOME/data}
    seat_rc=0
    seat_out=$(FM_HOME="$seat_home" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
      FM_CONFIG_OVERRIDE="$seat_config" FM_DATA_OVERRIDE="$seat_data" \
      "$FM_SM_LIVE_LIB_DIR/fm-fleet-seats.sh" reclaim "$id" --generation "$probed_gen" 2>&1) || seat_rc=$?
    if [ "$seat_rc" -eq 0 ] && [ -n "$seat_out" ]; then
      case "$seat_out" in
        "fleet-seats: reclaimed id=$id generation=$probed_gen"*|"fleet-seats: released id=$id generation=$probed_gen"*|"fleet-seats: already terminal id=$id generation=$probed_gen"|"fleet-seats: no seat held id=$id generation=$probed_gen") ;;
        *) seat_rc=1 ;;
      esac
    fi
    if [ "$seat_rc" -ne 0 ]; then
      FM_SM_LIVE_STATUS=skipped
      FM_SM_LIVE_REASON="its fleet seat generation $probed_gen was not reclaimed, so no replacement was launched: $(printf '%s\n' "$seat_out" | tail -1)"
      FM_SM_LIVE_RC=1
      return 1
    fi
  fi
  if ! fm_secondmate_liveness_recent_attempts "$id" 0 >/dev/null; then
    FM_SM_LIVE_STATUS=skipped
    FM_SM_LIVE_REASON="relaunch ledger $STATE/.secondmate-relaunch-$id is unreadable; endpoint left $FM_SM_LIVE_STATE"
    FM_SM_LIVE_RC=1
    return 1
  fi
  if ! fm_secondmate_liveness_ledger_add "$id" attempt; then
    FM_SM_LIVE_STATUS=skipped
    FM_SM_LIVE_REASON="relaunch ledger $STATE/.secondmate-relaunch-$id is unwritable; endpoint left $FM_SM_LIVE_STATE"
    FM_SM_LIVE_RC=1
    return 1
  fi
  if [ "$FM_SM_LIVE_KILL" = 1 ]; then
    [ -z "$FM_SM_LIVE_TARGET" ] || fm_backend_kill "$FM_SM_LIVE_BACKEND" "$FM_SM_LIVE_TARGET" 2>/dev/null || true
  fi
  local rc=0
  if [ -n "$timeout" ]; then
    FM_SM_LIVE_OUT=$(FM_SPAWN_NO_GUARD=1 fm_run_timed "$timeout" "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate 2>&1) || rc=$?
  else
    FM_SM_LIVE_OUT=$(FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate 2>&1) || rc=$?
  fi
  FM_SM_LIVE_RC=$rc
  if [ "$rc" -eq 0 ]; then
    fm_secondmate_liveness_ledger_add "$id" relaunched || true
  else
    fm_secondmate_liveness_ledger_add "$id" failed || true
  fi
  return "$rc"
}
