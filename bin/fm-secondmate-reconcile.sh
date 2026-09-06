#!/usr/bin/env bash
# fm-secondmate-reconcile.sh - ask a secondmate to reconcile its own books, at
# most once per home per cooldown window.
#
# Usage:
#   fm-secondmate-reconcile.sh request --snapshot <file>|-
#   fm-secondmate-reconcile.sh process-requests
#   fm-secondmate-reconcile.sh notify [--snapshot <file>|-]
#   fm-secondmate-reconcile.sh nudged <mate-id>
#
# This is a BACKSTOP, not the primary mechanism. Dispatch and completion pair
# the backlog row with the task's record inside the one script that moves the
# record, and each home reconciles its own books at session start
# (bin/fm-backlog-transition-lib.sh), so what reaches here is what neither could
# see: a home that has not restarted since it drifted, or one still running
# older code.
#
# A backlog-vs-metadata inventory mismatch inside a secondmate home
# (orphan_in_flight, unowned_current, terminal_in_flight) no longer makes that
# home unreadable: bin/fm-fleet-snapshot.sh keeps its decisions, queued, landed,
# and live work and carries the mismatch for renderers. The books are still
# wrong, and only the home that owns them may fix them, so the parent sends one
# reconcile instruction and stops there.
#
# What this script owns:
#   - the durable one-shot request queue under state/reconcile-notify. Bearings
#     supplies exactly one captured snapshot document and returns without sending.
#     Publication keeps at most one pending request per stable target id: a newer
#     snapshot replaces that target's payload across schema, relaunch, or route
#     changes without disturbing other targets. The watcher later runs
#     process-requests, which claims each request, invokes the normal notify path,
#     retires delivered or stale requests, and preserves skipped or failed requests
#     for another supervision pass;
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
#   - block a snapshot or digest. The Bearings path only publishes a local
#     request file. Sending happens later under supervision, and a send failure
#     preserves the request for another pass.
#
# Lock acquisition is non-blocking. A busy reconcile, lifecycle-control, or
# metadata lock skips that home without starting its cooldown, so a later recap
# can retry. The sampled endpoint identity is revalidated before delivery, by
# fm-send under its final route lock, and before the cooldown commit so a retired
# endpoint is never nudged or allowed to silence its replacement.
#
# A persistent REMOTE secondmate's parent-side metadata intentionally has no
# spawn_gen (docs/remote-secondmates.md). Such a row is legitimate and markerless
# by construction, not corrupt, so it uses its sampled remote_host as the separate
# identity guard. The current metadata must still have no spawn_gen and must still
# name that host. A row with neither identity fails loudly.
#
# Notify exits 0 when no delivery or cooldown-recording failure is known,
# including when a home was skipped for lock contention or a stale endpoint;
# it exits 1 when at least one due send failed or its cooldown could not be
# recorded. A known-undelivered send records no cooldown. Process-requests
# preserves that request for the next supervision pass; an unconfirmed send
# records the nudge, because a duplicate ask is worse than one the mate may
# already have.
#
# Notify output, one line per selected home in mismatch:
#   sent: <mate-id> <kind>          one reconcile instruction was recorded
#   cooldown: <mate-id> <seconds>   nudged this recently; nothing sent
#   skipped: <mate-id> lock         a required lock was busy; cooldown unchanged
#   stale: <mate-id> <kind>         the sampled endpoint retired or changed
#   failed: <mate-id> <kind>        the steer could not be recorded
#   sent-unrecorded: <mate-id> <kind>  sent, but cooldown commit failed
# Request prints `requested: <path>` or `not-needed`.
# Process-requests prints `processed: <count> deferred: <count>` after work and
# exits 1 when any request remains deferred; an empty queue is silent success.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# One nudge per home per four hours.
FM_RECONCILE_COOLDOWN_SECONDS=${FM_RECONCILE_COOLDOWN_SECONDS:-14400}
FM_RECONCILE_REQUEST_MAX_BYTES=${FM_RECONCILE_REQUEST_MAX_BYTES:-1048576}
case "$FM_RECONCILE_COOLDOWN_SECONDS" in
  ''|*[!0-9]*) echo "fm-secondmate-reconcile: FM_RECONCILE_COOLDOWN_SECONDS must be a whole number of seconds" >&2; exit 2 ;;
esac
case "$FM_RECONCILE_REQUEST_MAX_BYTES" in
  ''|*[!0-9]*|0) echo "fm-secondmate-reconcile: FM_RECONCILE_REQUEST_MAX_BYTES must be a positive whole number" >&2; exit 2 ;;
esac

REQUEST_DIR="$STATE/reconcile-notify"
ACTIVE_REQUEST_LOCK=
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
  [ -z "$ACTIVE_REQUEST_LOCK" ] || fm_lock_release "$ACTIVE_REQUEST_LOCK"
  ACTIVE_REQUEST_LOCK=
}
trap release_active_locks EXIT
trap 'release_active_locks; exit 130' INT TERM

usage() {
  cat <<'EOF'
usage: fm-secondmate-reconcile.sh request --snapshot <file>|-
       fm-secondmate-reconcile.sh process-requests
       fm-secondmate-reconcile.sh notify [--snapshot <file>|-]
       fm-secondmate-reconcile.sh nudged <mate-id>

request  accept exactly one captured snapshot and atomically publish at most
         one pending request per stable reconcile target id for later supervision
         delivery. Newer payloads replace that target's pending request without
         disturbing other targets. It never sends or takes mate lifecycle locks.
process-requests
         deliver and retire durable requests. Intended for the watcher loop;
         skipped or failed requests stay queued for a later pass.
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

meta_field() {  # <meta-file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

meta_spawn_gen() {
  meta_field "$1" spawn_gen
}

meta_remote_host() {
  meta_field "$1" remote_host
}

# revalidate_identity <meta> <sampled_spawn_gen> <sampled_host>
# Confirms the row's sampled identity still matches the mate's current
# metadata. When a spawn generation was sampled, that generation alone is the
# identity, exactly as before. When none was sampled - the only legitimate
# case is a persistent remote secondmate, whose parent metadata never carries
# one - the sampled host substitutes, and the metadata must still carry no
# spawn_gen of its own or the row's assumed identity model no longer holds.
# Sets REVALIDATE_REASON to "no-identity" (nothing here can be safely
# identified; report failed) or "stale" (identified, but changed; report
# stale) on any non-zero return.
revalidate_identity() {  # <meta> <sampled_spawn_gen> <sampled_host>
  local meta=$1 sampled_gen=$2 sampled_host=$3 cur_gen='' cur_host=''
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    cur_gen=$(meta_spawn_gen "$meta")
    cur_host=$(meta_remote_host "$meta")
  fi
  if [ -n "$sampled_gen" ]; then
    if [ -z "$cur_gen" ]; then REVALIDATE_REASON=no-identity; return 1; fi
    if [ "$cur_gen" != "$sampled_gen" ]; then REVALIDATE_REASON=stale; return 1; fi
    return 0
  fi
  if [ -z "$sampled_host" ]; then REVALIDATE_REASON=no-identity; return 1; fi
  if [ -n "$cur_gen" ]; then REVALIDATE_REASON=stale; return 1; fi
  if [ -z "$cur_host" ] || [ "$cur_host" != "$sampled_host" ]; then REVALIDATE_REASON=stale; return 1; fi
  return 0
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
  local seed=$1 digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$seed" | shasum -a 256 | awk '{print $1}') || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$seed" | sha256sum | awk '{print $1}') || return 1
  elif command -v openssl >/dev/null 2>&1; then
    digest=$(printf '%s' "$seed" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}') || return 1
  else
    return 1
  fi
  printf '%s' "$digest" | cut -c1-16
}

# The instruction is deliberately independent of the sampled mismatch details.
# A delayed snapshot can therefore ask only for a check of the mate's current
# books, never prescribe a repair for rows that may already have changed.
reconcile_text() {
  cat <<'EOF'
A fleet snapshot found that your home's backlog and task metadata disagreed.

Please check your current books and, if they still disagree, reconcile them to match reality. Nothing outside your home has been changed, and no reply is expected.
EOF
}

request_target_key() {
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s\n' "$1" | shasum -a 256 | awk '{print $1}') || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s\n' "$1" | sha256sum | awk '{print $1}') || return 1
  elif command -v openssl >/dev/null 2>&1; then
    digest=$(printf '%s\n' "$1" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}') || return 1
  else
    return 1
  fi
  case "$digest" in ''|*[!A-Fa-f0-9]*) return 1 ;; esac
  [ "${#digest}" -eq 64 ] || return 1
  printf '%s\n' "$digest"
}

request_dir_prepare() {
  if [ -e "$REQUEST_DIR" ] || [ -L "$REQUEST_DIR" ]; then
    [ -d "$REQUEST_DIR" ] && [ ! -L "$REQUEST_DIR" ] || return 1
  else
    (umask 077; mkdir "$REQUEST_DIR") || return 1
  fi
  chmod 700 "$REQUEST_DIR" || return 1
}

cmd_request() {
  local snapshot_src='' tmp bytes targets target id spawn_gen host key pending final published=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --snapshot) [ "$#" -ge 2 ] || fail "--snapshot needs a value"; snapshot_src=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  [ -n "$snapshot_src" ] || fail "request requires --snapshot <file>|-"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  request_dir_prepare || fail "cannot prepare the reconcile notify request directory"
  tmp=$(umask 077; mktemp "$REQUEST_DIR/.request.XXXXXX") \
    || fail "cannot create a reconcile notify request"
  if [ "$snapshot_src" = - ]; then
    LC_ALL=C head -c "$((FM_RECONCILE_REQUEST_MAX_BYTES + 1))" > "$tmp" \
      || { rm -f -- "$tmp"; fail "cannot capture the snapshot"; }
  else
    [ -f "$snapshot_src" ] && [ ! -L "$snapshot_src" ] \
      || { rm -f -- "$tmp"; fail "snapshot does not exist or is unsafe: $snapshot_src"; }
    LC_ALL=C head -c "$((FM_RECONCILE_REQUEST_MAX_BYTES + 1))" "$snapshot_src" > "$tmp" \
      || { rm -f -- "$tmp"; fail "cannot capture the snapshot"; }
  fi
  bytes=$(LC_ALL=C wc -c < "$tmp" | tr -d ' ')
  case "$bytes" in ''|*[!0-9]*) rm -f -- "$tmp"; fail "cannot size the captured snapshot" ;; esac
  if [ "$bytes" -gt "$FM_RECONCILE_REQUEST_MAX_BYTES" ]; then
    rm -f -- "$tmp"
    fail "captured snapshot exceeds FM_RECONCILE_REQUEST_MAX_BYTES"
  fi
  if ! jq -e -s '
    length == 1
    and (.[0].schema == "fm-bearings.v1" or .[0].schema == "fm-fleet-snapshot.v1")
  ' "$tmp" >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "input is not exactly one fm-fleet-snapshot.v1 or fm-bearings.v1 document"
  fi
  if ! jq -e '
    if .schema == "fm-bearings.v1" then
      any((.secondmate_reconcile // [])[];
        .kind as $kind
        | ["orphan_in_flight","unowned_current","terminal_in_flight"] | index($kind))
    else
      any((.secondmate_current.records // [])[];
        .reconcile_inventory as $inv
        | ["orphan_in_flight","unowned_current","terminal_in_flight"] | index($inv.kind))
    end
  ' "$tmp" >/dev/null 2>&1; then
    rm -f -- "$tmp"
    printf 'not-needed\n'
    return 0
  fi
  targets=$(jq -c '
    [if .schema == "fm-bearings.v1" then
       (.secondmate_reconcile // [])[]
       | {id,spawn_gen:(.spawn_gen // ""),host:(.host // ""),kind:(.kind // "")}
     else
       (.secondmate_current.records // [])[]
       | {id,spawn_gen:(.spawn_gen // ""),host:(.host // ""),kind:(.reconcile_inventory.kind // "")}
     end
     | select((.id | type) == "string" and (.id | test("^[A-Za-z0-9._-]+$")))
     | select((.spawn_gen | type) == "string" and (.spawn_gen | test("^[A-Za-z0-9._-]*$")))
     | select((.host | type) == "string" and (.host | test("[[:cntrl:]]") | not))
     | .kind as $kind
     | select(["orphan_in_flight","unowned_current","terminal_in_flight"] | index($kind))]
    | unique_by([.id,.spawn_gen,.host])[]
  ' "$tmp") || { rm -f -- "$tmp"; fail "cannot identify reconcile notify targets"; }
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    id=$(printf '%s' "$target" | jq -r '.id') || continue
    spawn_gen=$(printf '%s' "$target" | jq -r '.spawn_gen') || continue
    host=$(printf '%s' "$target" | jq -r '.host') || continue
    key=$(request_target_key "$id") \
      || { rm -f -- "$tmp"; fail "cannot identify reconcile notify target"; }
    pending=$(umask 077; mktemp "$REQUEST_DIR/.request.XXXXXX") \
      || { rm -f -- "$tmp"; fail "cannot create a reconcile notify request"; }
    if ! jq -c --arg id "$id" --arg spawn_gen "$spawn_gen" --arg host "$host" '
      if .schema == "fm-bearings.v1" then
        .secondmate_reconcile |= map(select(.id == $id and (.spawn_gen // "") == $spawn_gen and (.host // "") == $host))
      else
        .secondmate_current.records |= map(select(.id == $id and (.spawn_gen // "") == $spawn_gen and (.host // "") == $host))
      end
    ' "$tmp" > "$pending" || ! chmod 600 "$pending"; then
      rm -f -- "$tmp" "$pending"
      fail "cannot prepare the reconcile notify request"
    fi
    final="$REQUEST_DIR/request-$key.json"
    if ! mv -f -- "$pending" "$final"; then
      rm -f -- "$tmp" "$pending"
      fail "cannot publish the reconcile notify request"
    fi
    printf 'requested: %s\n' "$final"
    published=$((published + 1))
  done <<EOF
$targets
EOF
  rm -f -- "$tmp"
  [ "$published" -gt 0 ] || fail "cannot identify reconcile notify targets"
}

cmd_process_requests() {
  local process_lock="$STATE/.reconcile-notify-process.lock" request claimed base original output rc deferred=0 processed=0 have_request=0
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  [ -d "$REQUEST_DIR" ] && [ ! -L "$REQUEST_DIR" ] || return 0
  for request in "$REQUEST_DIR"/.processing-request-*.json "$REQUEST_DIR"/request-*.json; do
    if [ -f "$request" ] && [ ! -L "$request" ]; then
      have_request=1
      break
    fi
  done
  [ "$have_request" -eq 1 ] || return 0
  if ! fm_lock_try_acquire "$process_lock"; then
    return 0
  fi
  ACTIVE_REQUEST_LOCK=$process_lock
  output=$(umask 077; mktemp "$REQUEST_DIR/.process-output.XXXXXX") || {
    release_active_locks
    return 1
  }
  for request in "$REQUEST_DIR"/.processing-request-*.json "$REQUEST_DIR"/request-*.json; do
    [ -f "$request" ] && [ ! -L "$request" ] || continue
    base=$(basename "$request")
    case "$base" in
      .processing-*)
        claimed=$request
        original="$REQUEST_DIR/${base#.processing-}"
        ;;
      *)
        claimed="$REQUEST_DIR/.processing-$base"
        original=$request
        mv -- "$request" "$claimed" 2>/dev/null || continue
        ;;
    esac
    rc=0
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-secondmate-reconcile.sh" notify --snapshot "$claimed" \
      > "$output" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ] \
      && ! grep -Eq '^(skipped|failed|sent-unrecorded):' "$output" 2>/dev/null; then
      if rm -f -- "$claimed"; then
        processed=$((processed + 1))
      else
        deferred=$((deferred + 1))
      fi
    else
      if ln "$claimed" "$original" 2>/dev/null; then
        rm -f -- "$claimed" 2>/dev/null || true
      elif [ -f "$original" ] && [ ! -L "$original" ]; then
        rm -f -- "$claimed" 2>/dev/null || true
      fi
      deferred=$((deferred + 1))
    fi
  done
  rm -f -- "$output"
  release_active_locks
  printf 'processed: %s deferred: %s\n' "$processed" "$deferred"
  [ "$deferred" -eq 0 ]
}

cmd_notify() {
  local snapshot_src="" snapshot rows rc=0 now row_sep
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
  # spawn_gen is empty only for a persistent remote secondmate, whose parent
  # metadata never carries one (bin/fm-spawn.sh's spawn_remote_secondmate());
  # host is its substitute identity there and is otherwise unused. Both are
  # still character-restricted so a malformed sample cannot masquerade as
  # either a live incarnation token or a live host.
  #
  # Rows join on ASCII unit separator (0x1F), not @tsv: bash's IFS-whitespace
  # `read` collapses consecutive tabs, which would silently drop a
  # legitimately empty spawn_gen or host field instead of preserving it. 0x1F
  # is a control character, so the host filter below already excludes it from
  # every field; it is passed in via --arg rather than written literally so no
  # raw control byte sits in this source file.
  row_sep=$(printf '\037')
  rows=$(printf '%s' "$snapshot" | jq -r --arg sep "$row_sep" '
    (if .schema == "fm-bearings.v1" then
       (.secondmate_reconcile // [])[]
       | {id, spawn_gen:(.spawn_gen // ""), host:(.host // ""), kind:(.kind // ""), ids:(.ids // [])}
     else
       (.secondmate_current.records // [])[]
       | select(.reconcile_inventory != null)
       | {id, spawn_gen:(.spawn_gen // ""), host:(.host // ""), kind:(.reconcile_inventory.kind // ""), ids:(.reconcile_inventory.ids // [])}
     end)
    | select((.id | type) == "string" and (.id | test("^[A-Za-z0-9._-]+$")))
    | select((.spawn_gen | type) == "string" and (.spawn_gen | test("^[A-Za-z0-9._-]*$")))
    | select((.host | type) == "string" and (.host | test("[[:cntrl:]]") | not))
    | .kind as $kind
    | select(["orphan_in_flight","unowned_current","terminal_in_flight"] | index($kind))
    | [.id, .spawn_gen, .host, $kind]
    | join($sep)')

  local id sampled_spawn_gen sampled_host expected_remote_host kind path last age now delivered_at reconcile_lock control_lock meta meta_lock did send_rc
  while IFS=$'\037' read -r id sampled_spawn_gen sampled_host kind; do
    [ -n "${id:-}" ] || continue
    path=$(nudge_path "$id")
    reconcile_lock="$STATE/.$id.reconcile.lock"
    if ! fm_lock_try_acquire "$reconcile_lock"; then
      printf 'skipped: %s lock\n' "$id"
      continue
    fi
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
    if ! fm_lock_try_acquire "$control_lock"; then
      printf 'skipped: %s lock\n' "$id"
      release_active_locks
      continue
    fi
    ACTIVE_CONTROL_LOCK=$control_lock
    meta="$STATE/$id.meta"
    meta_lock=$(fm_meta_lock_path "$meta") || {
      printf 'stale: %s %s\n' "$id" "$kind"
      release_active_locks
      continue
    }
    if ! fm_lock_try_acquire "$meta_lock"; then
      printf 'skipped: %s lock\n' "$id"
      release_active_locks
      continue
    fi
    ACTIVE_META_LOCK=$meta_lock
    if ! revalidate_identity "$meta" "$sampled_spawn_gen" "$sampled_host"; then
      if [ "$REVALIDATE_REASON" = stale ]; then
        printf 'stale: %s %s\n' "$id" "$kind"
      else
        printf 'failed: %s %s\n' "$id" "$kind"
        rc=1
      fi
      release_active_locks
      continue
    fi
    did=$(delivery_id "$id:$sampled_spawn_gen:${last:-none}") || {
      printf 'failed: %s %s\n' "$id" "$kind"
      rc=1
      release_active_locks
      continue
    }
    expected_remote_host=
    [ -n "$sampled_spawn_gen" ] || expected_remote_host=$sampled_host
    release_active_locks
    send_rc=0
    FM_TASK_INBOX_LOCK_WAIT_SECS=0 FM_SEND_EXPECTED_SPAWN_GEN="$sampled_spawn_gen" \
      FM_SEND_EXPECTED_REMOTE_HOST="$expected_remote_host" \
      "$SCRIPT_DIR/fm-send.sh" "$id" --fire-and-forget "$did" \
      "$(reconcile_text)" >/dev/null 2>&1 || send_rc=$?
    # exit 3 is "typed but unconfirmed": the mate may already hold the ask, so
    # record the nudge rather than risk asking twice.
    if [ "$send_rc" -ne 0 ] && [ "$send_rc" -ne 3 ]; then
      printf 'failed: %s %s\n' "$id" "$kind"
      rc=1
      continue
    fi
    delivered_at=$(date +%s)
    if ! fm_lock_try_acquire "$reconcile_lock"; then
      printf 'sent-unrecorded: %s %s\n' "$id" "$kind"
      rc=1
      continue
    fi
    ACTIVE_RECONCILE_LOCK=$reconcile_lock
    if ! fm_lock_try_acquire "$control_lock"; then
      printf 'sent-unrecorded: %s %s\n' "$id" "$kind"
      rc=1
      release_active_locks
      continue
    fi
    ACTIVE_CONTROL_LOCK=$control_lock
    if ! fm_lock_try_acquire "$meta_lock"; then
      printf 'sent-unrecorded: %s %s\n' "$id" "$kind"
      rc=1
      release_active_locks
      continue
    fi
    ACTIVE_META_LOCK=$meta_lock
    last=
    if [ -f "$path" ] && [ ! -L "$path" ]; then last=$(cat "$path" 2>/dev/null || true); fi
    case "$last" in ''|*[!0-9]*) last= ;; esac
    if [ -n "$last" ] && [ "$last" -gt "$delivered_at" ]; then delivered_at=$last; fi
    if revalidate_identity "$meta" "$sampled_spawn_gen" "$sampled_host" \
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
  request) cmd_request "$@" ;;
  process-requests) cmd_process_requests "$@" ;;
  notify) cmd_notify "$@" ;;
  nudged) cmd_nudged "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
