#!/usr/bin/env bash
# fm-secondmate-reconcile.sh - ask a secondmate to reconcile its own books, at
# most once per home per cooldown window.
#
# Usage:
#   fm-secondmate-reconcile.sh notify [--snapshot <file>|-]
#   fm-secondmate-reconcile.sh nudged <mate-id>
#
# A backlog-vs-metadata inventory mismatch inside a secondmate home
# (orphan_in_flight, unowned_current, terminal_in_flight) no longer makes that
# home unreadable: bin/fm-fleet-snapshot.sh keeps its decisions, queued, landed,
# and live work and carries the mismatch for renderers. The books are still
# wrong, and only the home that owns them may fix them, so the parent sends one
# reconcile instruction and stops there.
#
# What this script owns:
#   - reading the mismatch from an already-produced fleet snapshot, so nothing
#     here re-parses another home's state or runs a second child summary;
#   - the cooldown. One durable per-home timestamp records the last nudge, and a
#     home is nudged only when that timestamp is older than the cooldown window
#     (FM_RECONCILE_COOLDOWN_SECONDS, four hours). A recap or digest loop
#     therefore cannot nag, while a mismatch still sitting there hours later
#     earns one gentle re-nudge. Deliberately coarse: a timestamp cannot go
#     stale, cannot mis-order against a concurrent snapshot, and cannot
#     mis-classify a repair as a new problem, which an identity-precise record
#     has to get right in every direction to avoid silently swallowing a nudge;
#   - sending through bin/fm-send.sh's fire-and-forget plane, which records the
#     instruction durably for local and remote mates alike while staying out of
#     the steering inbox's re-ring and escalation ladder: the parent expects no
#     reply, so nothing should chase one.
#
# What this script must never do:
#   - edit the mate's backlog, metadata, or queue from the parent. The mate owns
#     its own cleanup; the parent only asks.
#   - block a snapshot or digest. The enqueue is a fast local durable write, and
#     a send failure is reported, never fatal to the caller's own work.
#
# Exit status: 0 when every home in mismatch was nudged or was inside its
# cooldown; 1 when at least one due send failed. A known-undelivered send
# records nothing, so the next snapshot retries it; an unconfirmed send records
# the nudge, because a duplicate ask is worse than one the mate may already have.
#
# Output, one line per home in mismatch:
#   sent: <mate-id> <kind>          one reconcile instruction was recorded
#   cooldown: <mate-id> <seconds>   nudged this recently; nothing sent
#   failed: <mate-id> <kind>        the steer could not be recorded
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# One nudge per home per four hours.
FM_RECONCILE_COOLDOWN_SECONDS=${FM_RECONCILE_COOLDOWN_SECONDS:-14400}
case "$FM_RECONCILE_COOLDOWN_SECONDS" in
  ''|*[!0-9]*) echo "fm-secondmate-reconcile: FM_RECONCILE_COOLDOWN_SECONDS must be a whole number of seconds" >&2; exit 2 ;;
esac

ACTIVE_RECONCILE_LOCK=
ACTIVE_CONTROL_LOCK=
ACTIVE_META_LOCK=
release_active_locks() {
  [ -z "$ACTIVE_META_LOCK" ] || fm_lock_release "$ACTIVE_META_LOCK"
  ACTIVE_META_LOCK=
  [ -z "$ACTIVE_CONTROL_LOCK" ] || fm_lock_release "$ACTIVE_CONTROL_LOCK"
  ACTIVE_CONTROL_LOCK=
  [ -z "$ACTIVE_RECONCILE_LOCK" ] || fm_lock_release "$ACTIVE_RECONCILE_LOCK"
  ACTIVE_RECONCILE_LOCK=
}
trap release_active_locks EXIT
trap 'release_active_locks; exit 130' INT TERM

usage() {
  cat <<'EOF'
usage: fm-secondmate-reconcile.sh notify [--snapshot <file>|-]
       fm-secondmate-reconcile.sh nudged <mate-id>

notify   ask every secondmate home whose backlog disagrees with its own task
         metadata to reconcile it, at most once per home per cooldown window.
         Reads an fm-fleet-snapshot.v1 or fm-bearings.v1 document from
         --snapshot (or runs fm-fleet-snapshot.sh --json when omitted).
nudged   print the epoch second of the last reconcile nudge sent to <mate-id>.
EOF
}

fail() { echo "fm-secondmate-reconcile: $*" >&2; exit 2; }

nudge_path() {  # <mate-id>
  printf '%s/%s.reconcile-nudged\n' "$STATE" "$1"
}

meta_spawn_gen() {
  grep '^spawn_gen=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

cmd_nudged() {
  local id path
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  id=$1
  case "$id" in ''|*/*|.*) fail "not a task id: $id" ;; esac
  path=$(nudge_path "$id")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  cat "$path"
}

delivery_id() {
  local raw digest
  if command -v openssl >/dev/null 2>&1; then
    raw=$(openssl rand -hex 8 2>/dev/null || true)
  fi
  if [ -z "${raw:-}" ]; then
    if command -v shasum >/dev/null 2>&1; then
      digest=$(printf '%s' "$$:$(date +%s):$RANDOM:$RANDOM" | shasum -a 256 | awk '{print $1}') || return 1
    elif command -v sha256sum >/dev/null 2>&1; then
      digest=$(printf '%s' "$$:$(date +%s):$RANDOM:$RANDOM" | sha256sum | awk '{print $1}') || return 1
    else
      return 1
    fi
    raw=$(printf '%s' "$digest" | cut -c1-16)
  fi
  printf '%s' "$raw"
}

# The instruction is deliberately plain: it names what disagrees and leaves the
# repair entirely to the mate, which is the only home allowed to change it.
reconcile_text() {  # <kind> <ids-csv>
  local kind=$1 ids=$2 what
  case "$kind" in
    orphan_in_flight)
      what="these in-flight backlog items have no task metadata in your home, so no worker is running them: $ids" ;;
    unowned_current)
      what="these live task records in your home have no in-flight backlog item: $ids" ;;
    terminal_in_flight)
      what="these in-flight backlog items already have a finished worker: $ids" ;;
    *) what="your backlog and task metadata disagree about: $ids" ;;
  esac
  cat <<EOF
Your home's backlog and its task metadata disagree, and only you can settle it: $what

Please reconcile your own books: move each row to the section that matches reality, or clean up the leftover record. Nothing outside your home has been changed, and no reply is expected.
EOF
}

cmd_notify() {
  local snapshot_src="" snapshot rows rc=0 now
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --snapshot) [ "$#" -ge 2 ] || fail "--snapshot needs a value"; snapshot_src=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || fail "jq is required"

  if [ -z "$snapshot_src" ]; then
    snapshot=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || fail "cannot read the fleet snapshot"
  elif [ "$snapshot_src" = - ]; then
    snapshot=$(cat)
  else
    [ -f "$snapshot_src" ] || fail "snapshot does not exist: $snapshot_src"
    snapshot=$(cat "$snapshot_src")
  fi
  printf '%s' "$snapshot" | jq -e '
    .schema == "fm-fleet-snapshot.v1" or .schema == "fm-bearings.v1"
  ' >/dev/null 2>&1 || fail "input is not an fm-fleet-snapshot.v1 or fm-bearings.v1 document"

  # Only a real inventory mismatch is a books problem the mate can fix; every
  # other invalidity is either unreadable state or nothing to reconcile.
  rows=$(printf '%s' "$snapshot" | jq -r '
    (if .schema == "fm-bearings.v1" then
       (.secondmate_reconcile // [])[]
       | {id, spawn_gen:(.spawn_gen // ""), kind:(.kind // ""), ids:(.ids // [])}
     else
       (.secondmate_current.records // [])[]
       | select(.reconcile_inventory != null)
       | {id, spawn_gen:(.spawn_gen // ""), kind:(.reconcile_inventory.kind // ""), ids:(.reconcile_inventory.ids // [])}
     end)
    | select((.id | type) == "string" and (.id | test("^[A-Za-z0-9._-]+$")))
    | select((.spawn_gen | type) == "string" and (.spawn_gen | test("^[A-Za-z0-9._-]+$")))
    | .kind as $kind
    | select(["orphan_in_flight","unowned_current","terminal_in_flight"] | index($kind))
    | [.id, .spawn_gen, $kind, (.ids | map(select(type == "string")) | sort | join(", "))]
    | @tsv')

  local id sampled_spawn_gen kind ids path last age now delivered_at reconcile_lock control_lock meta meta_lock current_spawn_gen did send_rc
  while IFS=$'\t' read -r id sampled_spawn_gen kind ids; do
    [ -n "${id:-}" ] || continue
    path=$(nudge_path "$id")
    reconcile_lock="$STATE/.$id.reconcile.lock"
    fm_lock_acquire_wait "$reconcile_lock" || { printf 'failed: %s lock\n' "$id"; rc=1; continue; }
    ACTIVE_RECONCILE_LOCK=$reconcile_lock
    now=$(date +%s)
    last=
    if [ -f "$path" ] && [ ! -L "$path" ]; then last=$(cat "$path" 2>/dev/null || true); fi
    case "$last" in ''|*[!0-9]*) last= ;; esac
    if [ -n "$last" ]; then
      age=$((now - last))
      # A clock that moved backwards must not silence the home forever.
      if [ "$age" -ge 0 ] && [ "$age" -lt "$FM_RECONCILE_COOLDOWN_SECONDS" ]; then
        printf 'cooldown: %s %s\n' "$id" "$age"
        release_active_locks
        continue
      fi
    fi
    control_lock="$STATE/.control-$id.lock"
    fm_lock_acquire_wait "$control_lock" || {
      printf 'failed: %s lock\n' "$id"
      rc=1
      release_active_locks
      continue
    }
    ACTIVE_CONTROL_LOCK=$control_lock
    meta="$STATE/$id.meta"
    meta_lock=$(fm_meta_lock_path "$meta") || {
      printf 'stale: %s %s\n' "$id" "$kind"
      release_active_locks
      continue
    }
    fm_lock_acquire_wait "$meta_lock" || {
      printf 'stale: %s %s\n' "$id" "$kind"
      release_active_locks
      continue
    }
    ACTIVE_META_LOCK=$meta_lock
    current_spawn_gen=
    if [ -f "$meta" ] && [ ! -L "$meta" ]; then
      current_spawn_gen=$(meta_spawn_gen "$meta")
    fi
    if [ -z "$current_spawn_gen" ]; then
      printf 'failed: %s %s\n' "$id" "$kind"
      rc=1
      release_active_locks
      continue
    fi
    if [ "$current_spawn_gen" != "$sampled_spawn_gen" ]; then
      printf 'stale: %s %s\n' "$id" "$kind"
      release_active_locks
      continue
    fi
    fm_lock_release "$ACTIVE_META_LOCK"
    ACTIVE_META_LOCK=
    did=$(delivery_id) || {
      printf 'failed: %s %s\n' "$id" "$kind"
      rc=1
      release_active_locks
      continue
    }
    send_rc=0
    "$SCRIPT_DIR/fm-send.sh" "$id" --fire-and-forget "$did" \
      "$(reconcile_text "$kind" "$ids")" >/dev/null 2>&1 || send_rc=$?
    # exit 3 is "typed but unconfirmed": the mate may already hold the ask, so
    # record the nudge rather than risk asking twice.
    if [ "$send_rc" -ne 0 ] && [ "$send_rc" -ne 3 ]; then
      printf 'failed: %s %s\n' "$id" "$kind"
      rc=1
      release_active_locks
      continue
    fi
    delivered_at=$(date +%s)
    fm_lock_acquire_wait "$meta_lock" || {
      printf 'sent-unrecorded: %s %s\n' "$id" "$kind"
      rc=1
      release_active_locks
      continue
    }
    ACTIVE_META_LOCK=$meta_lock
    current_spawn_gen=
    if [ -f "$meta" ] && [ ! -L "$meta" ]; then
      current_spawn_gen=$(meta_spawn_gen "$meta")
    fi
    if [ "$current_spawn_gen" = "$sampled_spawn_gen" ] \
      && (umask 077; printf '%s\n' "$delivered_at" > "$path.tmp") \
      && mv -f -- "$path.tmp" "$path"; then
      printf 'sent: %s %s\n' "$id" "$kind"
    else
      rm -f -- "$path.tmp"
      # The mate has the instruction; only this home's cooldown record is
      # missing, so say so rather than letting the next run ask again in silence.
      printf 'sent-unrecorded: %s %s\n' "$id" "$kind"
      rc=1
    fi
    release_active_locks
  done <<EOF
$rows
EOF
  return "$rc"
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
cmd=$1; shift
case "$cmd" in
  notify) cmd_notify "$@" ;;
  nudged) cmd_nudged "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
