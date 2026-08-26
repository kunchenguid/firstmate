#!/usr/bin/env bash
# fm-secondmate-reconcile.sh - ask a secondmate to reconcile its own books once
# per inventory-mismatch episode.
#
# Usage:
#   fm-secondmate-reconcile.sh notify [--snapshot <file>|-]
#   fm-secondmate-reconcile.sh episode <mate-id>
#
# A backlog-vs-metadata inventory mismatch inside a secondmate home
# (orphan_in_flight, unowned_current, terminal_in_flight) no longer makes that
# home unreadable: bin/fm-fleet-snapshot.sh keeps its decisions, queued, landed,
# and live work and carries the mismatch in `invalidity`. The books are still
# wrong, and only the home that owns them may fix them, so the parent sends one
# reconcile instruction and stops there.
#
# What this script owns:
#   - reading the mismatch from an already-produced fleet snapshot, so nothing
#     here re-parses another home's state or runs a second child summary;
#   - the once-per-episode contract. An episode identity is
#     "<invalidity-kind>:<sorted mismatch ids>". A persistent mismatch keeps the
#     same identity and is never re-sent, so a recap or digest loop cannot nag.
#     A changed identity is a NEW episode and earns exactly one more send. A
#     home whose mismatch clears drops its record, so a recurrence notifies
#     again;
#   - sending through bin/fm-send.sh, the existing steering transport, which
#     records the instruction durably for local and remote mates alike.
#
# What this script must never do:
#   - edit the mate's backlog, metadata, or queue from the parent. The mate owns
#     its own cleanup; the parent only asks.
#   - block a snapshot or digest. Callers run it after their output is produced,
#     and a send failure is reported, never fatal to the caller's own work.
#
# Exit status: 0 when every due home was either notified, deduped, or cleared;
# 1 when at least one due send failed or remained completion-unknown.
# A known-undelivered send records no episode, while an unknown completion keeps
# its delivery identity so the next fresh snapshot retries the same logical delivery.
#
# Output, one line per home considered:
#   sent: <mate-id> <episode>       one reconcile instruction was recorded
#   dedupe: <mate-id> <episode>     same episode already notified; nothing sent
#   cleared: <mate-id>              the mismatch is gone; the record was dropped
#   unconfirmed: <mate-id> <episode> transport completion is unknown
#   stale: <mate-id> <generation>   an older observation was ignored
#   failed: <mate-id> <episode>     the steer could not be recorded
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

ACTIVE_LOCK=
release_active_lock() {
  [ -z "$ACTIVE_LOCK" ] || fm_lock_release "$ACTIVE_LOCK"
  ACTIVE_LOCK=
}
trap release_active_lock EXIT
trap 'release_active_lock; exit 130' INT TERM

usage() {
  cat <<'EOF'
usage: fm-secondmate-reconcile.sh notify [--snapshot <file>|-]
       fm-secondmate-reconcile.sh episode <mate-id>

notify   ask every secondmate home with a NEW inventory-mismatch episode to
         reconcile its own backlog against its own task metadata, exactly once
         per episode. Reads an fm-fleet-snapshot.v1 or fm-bearings.v1 document
         from --snapshot (or runs fm-fleet-snapshot.sh --json when omitted).
episode  print the episode identity already notified for <mate-id>, if any.
EOF
}

fail() { echo "fm-secondmate-reconcile: $*" >&2; exit 2; }

episode_path() {  # <mate-id>
  printf '%s/%s.reconcile-episode\n' "$STATE" "$1"
}

observation_path() {  # <mate-id>
  printf '%s/%s.reconcile-observed\n' "$STATE" "$1"
}

write_observation() {  # <mate-id> <generation>
  local path
  path=$(observation_path "$1")
  (umask 077; printf '%s\n' "$2" > "$path.tmp") && mv -f -- "$path.tmp" "$path"
}

observation_is_stale() {  # <generation> <latest-generation>
  [ -n "$2" ] && [[ "$1" < "$2" ]]
}

cmd_episode() {
  local id path
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  id=$1
  case "$id" in ''|*/*|.*) fail "not a task id: $id" ;; esac
  path=$(episode_path "$id")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  cat "$path"
}

# The instruction is deliberately plain: it names what disagrees and leaves the
# repair entirely to the mate, which is the only home allowed to change it.
episode_corr() {
  local raw digest
  if command -v openssl >/dev/null 2>&1; then
    raw=$(openssl rand -hex 8 2>/dev/null || true)
  fi
  if [ -z "${raw:-}" ]; then
    if command -v shasum >/dev/null 2>&1; then
      digest=$(printf '%s' "$$:$(date +%s%N 2>/dev/null || date +%s):$RANDOM:$RANDOM" | shasum -a 256 | awk '{print $1}') || return 1
    elif command -v sha256sum >/dev/null 2>&1; then
      digest=$(printf '%s' "$$:$(date +%s%N 2>/dev/null || date +%s):$RANDOM:$RANDOM" | sha256sum | awk '{print $1}') || return 1
    else
      return 1
    fi
    raw=${digest:0:16}
  fi
  printf '%s' "$raw"
}

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

Please reconcile your own books: move each row to the section that matches reality, or clean up the leftover record. Nothing outside your home has been changed, and this is the only time you will be asked about this particular disagreement.
EOF
}

cmd_notify() {
  local snapshot_src="" snapshot rows rc=0
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
    (.schema == "fm-fleet-snapshot.v1" or .schema == "fm-bearings.v1")
    and (.generated | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.observation | type == "string" and test("^[0-9]{20}-[0-9]{10}$"))
  ' >/dev/null 2>&1 || fail "input is not a generated fm-fleet-snapshot.v1 or fm-bearings.v1 document"

  rows=$(printf '%s' "$snapshot" | jq -r '
    .observation as $generation
    | (if .schema == "fm-bearings.v1" then
       (.secondmate_reconcile // [])[]
       | {id, kind:(.kind // ""), ids:(.ids // [])}
     else
       (.secondmate_current.records // [])[]
       | select(.provenance.selected == "structured-home")
       | {id, kind:(.invalidity.kind // ""), ids:(.invalidity.ids // [])}
     end)
    | select((.id | type) == "string" and (.id | test("^[A-Za-z0-9._-]+$")))
    | .kind as $kind
    | (if ["orphan_in_flight","unowned_current","terminal_in_flight"] | index($kind)
       then (.ids | map(select(type == "string")) | sort)
       else [] end) as $ids
    | ($ids | map(@json) | join(", ")) as $ids_display
    | ($ids | @json) as $ids_canonical
    | [.id, (if ($ids | length) == 0 then "" else $kind end), $ids_display, $ids_canonical, $generation]
    | join("\u001f")')

  local id kind ids ids_canonical generation episode path observed_path observed prior corr lock send_rc
  local pending_tag pending_episode pending_corr pending_generation
  while IFS=$'\x1f' read -r id kind ids ids_canonical generation; do
    [ -n "${id:-}" ] || continue
    path=$(episode_path "$id")
    observed_path=$(observation_path "$id")
    lock="$STATE/.$id.reconcile.lock"
    fm_lock_acquire_wait "$lock" || { printf 'failed: %s lock\n' "$id"; rc=1; continue; }
    ACTIVE_LOCK=$lock
    observed=
    if [ -f "$observed_path" ] && [ ! -L "$observed_path" ]; then observed=$(cat "$observed_path" 2>/dev/null || true); fi
    prior=
    if [ -f "$path" ] && [ ! -L "$path" ]; then prior=$(cat "$path" 2>/dev/null || true); fi
    pending_tag=
    pending_episode=
    pending_corr=
    pending_generation=
    IFS=$'\t' read -r pending_tag pending_episode pending_corr pending_generation <<EOF_PENDING
$prior
EOF_PENDING
    if observation_is_stale "$generation" "$observed" \
      || { [ "$pending_tag" = pending ] && [ -n "$pending_generation" ] \
        && [[ "$generation" < "$pending_generation" ]]; }; then
      printf 'stale: %s %s\n' "$id" "$generation"
      release_active_lock
      continue
    fi
    if [ -z "$kind" ]; then
      if ! write_observation "$id" "$generation"; then
        printf 'failed: %s observation\n' "$id"
        rc=1
      elif [ -f "$path" ] && [ ! -L "$path" ]; then
        rm -f -- "$path" && printf 'cleared: %s\n' "$id"
      fi
      release_active_lock
      continue
    fi
    episode="$kind:$ids_canonical"
    if [ "$prior" = "$episode" ]; then
      if write_observation "$id" "$generation"; then
        printf 'dedupe: %s %s\n' "$id" "$episode"
      else
        printf 'failed: %s observation\n' "$id"
        rc=1
      fi
      release_active_lock
      continue
    fi
    corr=
    if [ "$pending_tag" = pending ] && [ "$pending_episode" = "$episode" ] \
      && printf '%s' "$pending_corr" | grep -Eq '^[a-f0-9]{16}$'; then
      corr=$pending_corr
    else
      corr=$(episode_corr) || {
        printf 'failed: %s %s\n' "$id" "$episode"
        rc=1
        release_active_lock
        continue
      }
    fi
    if ! (umask 077; printf 'pending\t%s\t%s\t%s\n' "$episode" "$corr" "$generation" > "$path.tmp") \
      || ! mv -f -- "$path.tmp" "$path"; then
      rm -f -- "$path.tmp"
      printf 'failed: %s %s\n' "$id" "$episode"
      rc=1
      release_active_lock
      continue
    fi
    send_rc=0
    "$SCRIPT_DIR/fm-send.sh" "$id" --fire-and-forget "$corr" \
      "$(reconcile_text "$kind" "$ids")" >/dev/null 2>&1 || send_rc=$?
    if [ "$send_rc" -eq 3 ]; then
      write_observation "$id" "$generation" || rc=1
      printf 'unconfirmed: %s %s\n' "$id" "$episode"
      rc=1
      release_active_lock
      continue
    fi
    if [ "$send_rc" -ne 0 ]; then
      if write_observation "$id" "$generation"; then rm -f -- "$path"; else rc=1; fi
      printf 'failed: %s %s\n' "$id" "$episode"
      rc=1
      release_active_lock
      continue
    fi
    if ! write_observation "$id" "$generation"; then
      printf 'sent-unrecorded: %s %s\n' "$id" "$episode"
      rc=1
    elif (umask 077; printf '%s\n' "$episode" > "$path.tmp") && mv -f -- "$path.tmp" "$path"; then
      printf 'sent: %s %s\n' "$id" "$episode"
    else
      rm -f -- "$path.tmp"
      printf 'sent-unrecorded: %s %s\n' "$id" "$episode"
      rc=1
    fi
    release_active_lock
  done <<EOF
$rows
EOF
  return "$rc"
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
cmd=$1; shift
case "$cmd" in
  notify) cmd_notify "$@" ;;
  episode) cmd_episode "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
