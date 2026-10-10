#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
#
# Line 1 of state/.lock is the owning session's anchor pid, resolved by
# fm_session_lock_anchor_pid in bin/fm-session-lock-lib.sh: the harness (agent)
# process found by walking the shell's ancestry, which lives as long as the
# firstmate session - unlike the transient subshell PID of any one tool call,
# which is dead moments after it is written. For a Claude session that proves a
# trusted session id the anchor is CLAUDE_PID, the model-loop process, so a
# shared transient daemon or a front-end that outlives the session never keeps
# a dead session's lock alive. Line 1 keeps its whole-line pid format because
# every other reader takes the first line as the pid.
#
# The trusted id itself is recorded beside the lock in state/.lock-session, a
# sidecar written only here and only under the claim lock: refreshed on every
# confirmed-own acquisition, including the early already-mine exit that waits
# for the claim lock, removed when the acquiring session proves no trusted id,
# and left byte-identical when it already names that id. A same-session
# confirmation never rewrites line 1 while the recorded pid is alive, because
# bin/fm-startup-network.sh compares that pid across its deferred sweeps; a dead
# recorded pid is reclaimed and rewritten to this session's anchor.
#
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0.
#                             A held lock is not proof the holder is consuming
#                             wakes. Machine-readable lock fields live on
#                             fm-inbox.sh ready, from the same inspect helper.
#        fm-lock.sh handover request [--wait <secs>] [--no-start]
#        fm-lock.sh handover request --snapshot
#        fm-lock.sh handover template
#        fm-lock.sh handover write <record-file>
#        fm-lock.sh handover release <record-file>
#        fm-lock.sh handover show [--json|--digest]
#
# Handover is the one swap-over path between two live firstmate sessions of a
# home. The incoming session runs `handover request`: it records
# state/.handover-request and queues one captain-inbox note (an idempotent
# request id, so a rerun queues nothing new) whose `check` wake tells the live
# owner exactly what to run. It then waits up to --wait seconds (default 300).
# If the owner hands over, it confirms the lock and execs fm-session-start.sh
# (unless --no-start); if the owner's harness exits instead, it takes the
# stale lock directly and says no new record exists; on expiry it exits 1 with
# the request still pending. A free or stale lock is simply acquired.
# The owner runs `handover template`, fills every section of the printed
# skeleton (Work in progress with files and local copies, Open captain asks,
# Promises to the captain, Facts not yet in durable records, Steers not yet
# reflected in status, Projects and local copies prefilled from
# data/projects.md and projects/), then `handover release <file>`. Release
# refuses unless this session owns the lock, a live takeover request exists,
# every section has content, no `<fill in` placeholder remains, and every
# unacknowledged captain inbox note id (other than the request's own) is named.
# Only then, under the claim lock, it publishes state/handover.md, archives the
# record it replaces under state/handover-archive/ (newest 20 kept), writes the
# requester's anchor pid onto line 1, removes the sidecar, and acknowledges the
# request note, so the record always exists before the lock moves and no third
# session can claim the lock in between.
# `handover write <file>` publishes the same validated record while keeping the
# lock; `request --snapshot` asks the live owner for one, needs no harness, and
# is the trigger an outside controller uses. `show --json` (schema
# fm-handover.v1: lock, record, request) is the stable read; `show --digest` is
# what fm-session-start.sh prints, in full when the record is addressed to the
# current holder or under 24 hours old, otherwise only named.
# Record format: key=value header lines (fm_handover, kind release|snapshot,
# from_pid, from_session, to_pid, to_session, written_at), a `--` line, then
# the Markdown body.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
LOCK_SESSION="$STATE/.lock-session"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness, trusted
# session id, anchor pid) is owned by the shared session-lock lib so the Claude
# Stop auto-arm applies the exact same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ "${1:-}" = "status" ]; then
  fm_session_lock_inspect "$STATE"
  case "$FM_LOCK_INSPECT_STATE" in
    free) echo "lock: free" ;;
    unreadable) echo "lock: unreadable" ;;
    held) echo "lock: held by live harness pid $FM_LOCK_INSPECT_PID" ;;
    *) echo "lock: stale (pid $FM_LOCK_INSPECT_PID dead or not a harness)" ;;
  esac
  exit 0
fi

# --- session swap-over (handover) ---------------------------------------------
# The lock never moves by force or by an ad hoc message: the incoming session
# asks, the outgoing session publishes a complete handover record, and only then
# writes the incoming session's anchor pid onto line 1, so no third session can
# claim the lock in between and the record always exists before the new owner
# can observe the lock as its own.
HANDOVER_RECORD="$STATE/handover.md"
HANDOVER_ARCHIVE="$STATE/handover-archive"
HANDOVER_REQUEST="$STATE/.handover-request"
HANDOVER_ARCHIVE_KEEP=20
HANDOVER_FRESH_SECS=86400
HANDOVER_DIGEST_LINES=200
HANDOVER_PLACEHOLDER='<fill in'
HANDOVER_SECTIONS='Work in progress
Open captain asks
Promises to the captain
Facts not yet in durable records
Steers not yet reflected in status
Projects and local copies'

handover_die() { echo "error: handover: $*" >&2; exit 1; }

# Header value <key> of a key=value ... -- record such as the handover record.
handover_field() {  # <file> <key>
  [ -f "$1" ] || return 1
  awk -v key="$2" '$0 == "--" { exit } index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$1"
}

handover_body() {  # <file>
  awk 'seen { print; next } $0 == "--" { seen = 1 }' "$1"
}

handover_iso() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$1"
}

handover_inbox() { FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-inbox.sh" "$@"; }

# True when a request is pending and still actionable: a snapshot request, or a
# takeover whose requesting session is still a live harness.
handover_request_live() {
  local requester
  [ -f "$HANDOVER_REQUEST" ] || return 1
  [ "$(handover_field "$HANDOVER_REQUEST" kind)" = snapshot ] && return 0
  requester=$(handover_field "$HANDOVER_REQUEST" requester_pid)
  [ -n "$requester" ] && fm_harness_pid_alive "$requester"
}

handover_template() {
  local section ids id summary registry="${FM_DATA_OVERRIDE:-$FM_HOME/data}/projects.md" clone request_note
  request_note=$(handover_field "$HANDOVER_REQUEST" note 2>/dev/null || true)
  ids=$(handover_inbox list --ids 2>/dev/null | grep -vxF "${request_note:-/}" || true)
  while IFS= read -r section; do
    printf '## %s\n' "$section"
    case "$section" in
      'Work in progress')
        printf '%s: each piece of work under way - what it is, the files it touches, and the exact local copy (path) it lives in, so the incoming session keeps working there and not in some other worktree; or write: none>\n' "$HANDOVER_PLACEHOLDER" ;;
      'Open captain asks')
        printf '%s: every captain ask not yet captured in the backlog, and what is owed on each; or write: none>\n' "$HANDOVER_PLACEHOLDER"
        printf 'Unacknowledged captain inbox notes (keep every id named here):\n'
        if [ -z "$ids" ]; then
          printf -- '- none pending\n'
        fi
        while IFS= read -r id; do
          [ -n "$id" ] || continue
          summary=$(handover_inbox list | awk -v id="$id" '$0 == id { getline; sub(/^    /, ""); print; exit }' | cut -c1-140)
          printf -- '- note %s: %s - %s: handled, in progress, or not started>\n' "$id" "$summary" "$HANDOVER_PLACEHOLDER"
        done <<IDS
$ids
IDS
        ;;
      'Promises to the captain')
        printf '%s: what this session told the captain it would do or report, and when; or write: none>\n' "$HANDOVER_PLACEHOLDER" ;;
      'Facts not yet in durable records')
        printf '%s: captain decisions and facts given only in chat, such as a project posture; write each to its owner first where one exists and name it here; or write: none>\n' "$HANDOVER_PLACEHOLDER" ;;
      'Steers not yet reflected in status')
        printf '%s: steers sent to workers whose effect has not shown up in their status yet; or write: none>\n' "$HANDOVER_PLACEHOLDER" ;;
      'Projects and local copies')
        if [ -f "$registry" ] && grep -q '^- ' "$registry"; then
          printf 'Registry (data/projects.md), including each live copy location:\n'
          grep '^- ' "$registry"
        else
          printf 'No project registry entries (data/projects.md absent or empty).\n'
        fi
        for clone in "$FM_HOME"/projects/*/; do
          [ -d "$clone" ] || continue
          clone=${clone%/}
          printf -- '- firstmate clone: projects/%s\n' "${clone##*/}"
        done
        ;;
    esac
    printf '\n'
  done <<SECTIONS
$HANDOVER_SECTIONS
SECTIONS
}

# Print every reason record file $1 is not a complete handover, or nothing.
handover_validate() {  # <file>
  local file=$1 section ids id request_note
  [ -s "$file" ] || { printf 'record %s is missing or empty\n' "$file"; return 0; }
  while IFS= read -r section; do
    if ! grep -qx "## $section" "$file"; then
      printf 'missing section "## %s"\n' "$section"
      continue
    fi
    awk -v head="## $section" '
      $0 == head { inside = 1; next }
      inside && /^## / { exit }
      inside && NF { found = 1 }
      END { exit found ? 0 : 1 }' "$file" \
      || printf 'section "## %s" is empty (write none when nothing applies)\n' "$section"
  done <<SECTIONS
$HANDOVER_SECTIONS
SECTIONS
  if grep -qF "$HANDOVER_PLACEHOLDER" "$file"; then
    printf 'template placeholders remain (lines containing "%s")\n' "$HANDOVER_PLACEHOLDER"
  fi
  request_note=$(handover_field "$HANDOVER_REQUEST" note 2>/dev/null || true)
  ids=$(handover_inbox list --ids 2>/dev/null || true)
  while IFS= read -r id; do
    [ -n "$id" ] && [ "$id" != "$request_note" ] || continue
    grep -qF "$id" "$file" || printf 'unacknowledged captain inbox note %s is not named in the record\n' "$id"
  done <<IDS
$ids
IDS
  return 0
}

# Publish body file $1 as the handover record, archiving the record it
# replaces. The caller holds the claim lock.
handover_publish() {  # <body-file> <kind> <to-pid> <to-session>
  local body=$1 kind=$2 to_pid=$3 to_session=$4 now tmp from_session prior old
  now=$(date +%s)
  from_session=$(fm_session_lock_trusted_session_id 2>/dev/null || true)
  tmp=$(mktemp "$STATE/.handover.XXXXXX") || return 1
  if ! {
    printf 'fm_handover=v1\nkind=%s\nfrom_pid=%s\nfrom_session=%s\n' "$kind" "$me" "$from_session"
    printf 'to_pid=%s\nto_session=%s\nwritten_at=%s\n--\n' "$to_pid" "$to_session" "$now"
    cat "$body"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [ -f "$HANDOVER_RECORD" ]; then
    mkdir -p "$HANDOVER_ARCHIVE" || { rm -f "$tmp"; return 1; }
    prior=$(handover_field "$HANDOVER_RECORD" written_at)
    mv -f "$HANDOVER_RECORD" "$HANDOVER_ARCHIVE/${prior:-$now}-$$.md" || { rm -f "$tmp"; return 1; }
    # shellcheck disable=SC2012 # archive names are digits, a dash, and .md
    ls -1t "$HANDOVER_ARCHIVE" 2>/dev/null | tail -n +$((HANDOVER_ARCHIVE_KEEP + 1)) | while IFS= read -r old; do
      rm -f "${HANDOVER_ARCHIVE:?}/${old:?}"
    done
  fi
  mv -f "$tmp" "$HANDOVER_RECORD"
}

# Acknowledge the request's own inbox note and drop the request.
handover_close_request() {
  local note
  note=$(handover_field "$HANDOVER_REQUEST" note 2>/dev/null || true)
  [ -z "$note" ] || handover_inbox drain --ack "$note" >/dev/null 2>&1 || true
  rm -f "$HANDOVER_REQUEST"
}

handover_claim() {
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  HANDOVER_CLAIM="$STATE/.lock.acquire"
  fm_lock_acquire_wait "$HANDOVER_CLAIM" || handover_die "cannot take the session-lock claim lock"
  trap 'fm_lock_release "$HANDOVER_CLAIM"' EXIT
}

handover_require_owner() {
  me=$(fm_session_lock_anchor_pid) || handover_die "cannot locate harness process in ancestry"
  fm_session_lock_owned_by_self "$STATE" \
    || handover_die "this session does not hold the session lock; only the live owner writes or releases a handover"
}

handover_write_or_release() {  # <write|release> <record-file>
  local mode=$1 file=${2:-} problems requester requester_session tmp
  [ -n "$file" ] || handover_die "usage: fm-lock.sh handover $mode <record-file>"
  handover_require_owner
  problems=$(handover_validate "$file")
  if [ -n "$problems" ]; then
    {
      printf 'error: handover: record %s is not complete; nothing was published and the lock did not move:\n' "$file"
      printf '%s\n' "$problems" | sed 's/^/  - /'
      printf 'Start from: fm-lock.sh handover template\n'
    } >&2
    exit 1
  fi
  if [ "$mode" = write ]; then
    handover_claim
    handover_require_owner
    handover_publish "$file" snapshot '' '' || handover_die "cannot publish $HANDOVER_RECORD"
    if [ "$(handover_field "$HANDOVER_REQUEST" kind 2>/dev/null)" = snapshot ]; then
      handover_close_request
    fi
    echo "handover record written: $HANDOVER_RECORD (this session keeps the lock)"
    exit 0
  fi
  [ "$(handover_field "$HANDOVER_REQUEST" kind 2>/dev/null)" = takeover ] \
    || handover_die "no incoming session has asked to take control; the incoming session runs fm-lock.sh handover request (fm-lock.sh handover write publishes a record and keeps the lock)"
  requester=$(handover_field "$HANDOVER_REQUEST" requester_pid)
  requester_session=$(handover_field "$HANDOVER_REQUEST" requester_session)
  fm_harness_pid_alive "$requester" \
    || handover_die "the requesting session (pid ${requester:-?}) is no longer a live harness; keep the lock"
  if fm_harness_ancestry_pids 2>/dev/null | grep -qx "$requester"; then
    handover_die "the requesting pid $requester is this session itself"
  fi
  handover_claim
  handover_require_owner
  handover_publish "$file" release "$requester" "$requester_session" || handover_die "cannot publish $HANDOVER_RECORD"
  tmp=$(mktemp "$STATE/.lock.handover.XXXXXX") || handover_die "cannot stage the lock transfer"
  if ! { printf '%s\n' "$requester" > "$tmp" && mv -f "$tmp" "$LOCK"; }; then
    rm -f "$tmp"
    handover_die "cannot transfer the session lock"
  fi
  rm -f "$LOCK_SESSION" "$LOCK_SESSION.prev"
  handover_close_request
  echo "lock handed over to harness pid $requester with record $HANDOVER_RECORD"
  echo "This session no longer holds the lock: stay read-only - do not spawn, steer, merge, drain or acknowledge wakes, or answer captain notes."
  exit 0
}

# Queue the request's one captain-inbox note, which is what wakes the live
# session. A repeat with the same request id replays the original note.
handover_request_note() {  # <kind> <request-id> <requester-pid>
  local body out rc=0
  if [ "$1" = takeover ]; then
    body="firstmate handover requested: another session (harness pid $3) is taking control of this home.
Run bin/fm-lock.sh handover template, save it to a file, and fill every section: what is being worked on with its files and local copy, open captain asks including every unacknowledged inbox note, promises, facts not yet in durable records, and steers not yet reflected in status.
Then run bin/fm-lock.sh handover release <file>; it refuses until the record is complete, then hands the lock straight to the requesting session, after which this session stays read-only."
  else
    body="firstmate handover snapshot requested: publish the current handover record without giving up control.
Run bin/fm-lock.sh handover template, save it to a file, fill every section, then run bin/fm-lock.sh handover write <file>; this session keeps the lock."
  fi
  out=$(handover_inbox note --request-id "$2" -- "$body") || rc=$?
  printf '%s\n' "$out" | awk 'NR == 1 { print $2 }'
  return "$rc"
}

handover_record_request() {  # <kind> <requester-pid> <requester-session> <holder> <now> <request-id>
  local note rc=0
  printf 'kind=%s\nrequester_pid=%s\nrequester_session=%s\nholder_pid=%s\nrequested_at=%s\nrequest_id=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" > "$HANDOVER_REQUEST.tmp" || handover_die "cannot record the request"
  note=$(handover_request_note "$1" "$6" "$2") || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$note" ]; then
    rm -f "$HANDOVER_REQUEST.tmp"
    [ -z "$note" ] || handover_inbox drain --ack "$note" >/dev/null 2>&1 || true
    handover_die "the request note was not saved or did not wake the live session (harness pid $4), so it would never act on the request; not waiting"
  fi
  if [ -f "$HANDOVER_REQUEST" ] && [ "$(handover_field "$HANDOVER_REQUEST" note)" != "$note" ]; then
    handover_close_request
  fi
  if ! { printf 'note=%s\n' "$note" >> "$HANDOVER_REQUEST.tmp" && mv -f "$HANDOVER_REQUEST.tmp" "$HANDOVER_REQUEST"; }; then
    handover_die "cannot record the request"
  fi
}

handover_request() {
  local wait=300 snapshot=0 start=1 holder now rid deadline line
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --wait)
        case "${2:-}" in ''|*[!0-9]*) handover_die "--wait needs whole seconds" ;; esac
        wait=$2
        shift 2
        ;;
      --snapshot) snapshot=1; shift ;;
      --no-start) start=0; shift ;;
      *) handover_die "usage: fm-lock.sh handover request [--snapshot] [--wait <seconds>] [--no-start]" ;;
    esac
  done
  fm_session_lock_inspect "$STATE"
  holder=$FM_LOCK_INSPECT_PID
  now=$(date +%s)
  if [ "$snapshot" -eq 1 ]; then
    [ "$FM_LOCK_INSPECT_STATE" = held ] \
      || handover_die "no live firstmate session holds this home's lock, so none can write a snapshot"
    if handover_request_live; then
      echo "a $(handover_field "$HANDOVER_REQUEST" kind) handover is already requested; the record will appear at $HANDOVER_RECORD"
      exit 0
    fi
    handover_record_request snapshot '' '' "$holder" "$now" "handover-snapshot-$now"
    echo "handover snapshot requested from harness pid $holder; read it with fm-lock.sh handover show once written to $HANDOVER_RECORD"
    exit 0
  fi
  me=$(fm_session_lock_anchor_pid) \
    || handover_die "cannot locate harness process in ancestry; only a live firstmate session can take control (--snapshot asks for a record only)"
  case "$FM_LOCK_INSPECT_STATE" in
    held)
      if [ "$holder" = "$me" ] || fm_session_lock_owned_by_self "$STATE"; then
        echo "this session already holds the lock; nothing to hand over"
        exit 0
      fi
      ;;
    free|stale)
      echo "no live firstmate session holds the lock, so there is no one to hand over; acquiring it directly"
      "$SCRIPT_DIR/fm-lock.sh" || exit 1
      [ "$start" -eq 0 ] || exec "$SCRIPT_DIR/fm-session-start.sh"
      exit 0
      ;;
    *) handover_die "the session lock cannot be classified ($FM_LOCK_INSPECT_STATE); resolve it before a handover" ;;
  esac
  if [ "$(handover_field "$HANDOVER_REQUEST" kind 2>/dev/null)" = takeover ] \
    && [ "$(handover_field "$HANDOVER_REQUEST" requester_pid)" = "$me" ] \
    && [ "$(handover_field "$HANDOVER_REQUEST" holder_pid)" = "$holder" ]; then
    echo "handover already requested from harness pid $holder; waiting again"
  else
    rid="handover-takeover-$me-$now"
    handover_record_request takeover "$me" "$(fm_session_lock_trusted_session_id 2>/dev/null || true)" "$holder" "$now" "$rid"
    echo "handover requested from harness pid $holder"
  fi
  echo "waiting up to ${wait}s for it to write its handover record and pass the lock"
  deadline=$((now + wait))
  while :; do
    line=$(head -n 1 "$LOCK" 2>/dev/null || true)
    if [ "$line" = "$me" ]; then
      echo "the previous session handed over; record at $HANDOVER_RECORD"
      break
    fi
    fm_session_lock_inspect "$STATE"
    case "$FM_LOCK_INSPECT_STATE" in
      free|stale)
        echo "the previous session ended without handing over, so no new handover record exists; rebuild from durable records"
        break
        ;;
      held)
        [ "$FM_LOCK_INSPECT_PID" = "$holder" ] \
          || handover_die "a different session (harness pid $FM_LOCK_INSPECT_PID) now holds the lock; the handover did not complete"
        ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "error: handover: harness pid $holder has not handed over within ${wait}s; the request stays pending." >&2
      echo "Re-run fm-lock.sh handover request to keep waiting (it queues no second request), or ask the captain to close the old session, after which this command takes the lock directly." >&2
      exit 1
    fi
    sleep 1
  done
  "$SCRIPT_DIR/fm-lock.sh" || exit 1
  [ "$start" -eq 0 ] || exec "$SCRIPT_DIR/fm-session-start.sh"
  exit 0
}

handover_show_json() {
  command -v python3 >/dev/null 2>&1 || handover_die "--json needs python3"
  fm_session_lock_inspect "$STATE"
  python3 - "$HANDOVER_RECORD" "$HANDOVER_REQUEST" "$FM_LOCK_INSPECT_STATE" "$FM_LOCK_INSPECT_PID" <<'PY'
import json, os, sys
record_path, request_path, lock_state, lock_pid = sys.argv[1:5]

def parse(path):
    if not os.path.isfile(path):
        return None, None
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().split("\n")
    fields, body = {}, ""
    for i, line in enumerate(lines):
        if line == "--":
            body = "\n".join(lines[i + 1:])
            break
        key, sep, value = line.partition("=")
        if sep:
            fields[key] = value
    return fields, body

def num(value):
    return int(value) if value and value.isdigit() else None

record, body = parse(record_path)
request, _ = parse(request_path)
out = {
    "schema": "fm-handover.v1",
    "lock": {"state": lock_state, "pid": num(lock_pid)},
    "record": None,
    "request": None,
}
if record is not None:
    out["record"] = {
        "path": record_path,
        "kind": record.get("kind"),
        "from_pid": num(record.get("from_pid")),
        "to_pid": num(record.get("to_pid")),
        "written_at": num(record.get("written_at")),
        "body": body,
    }
if request is not None:
    out["request"] = {
        "kind": request.get("kind"),
        "requester_pid": num(request.get("requester_pid")),
        "holder_pid": num(request.get("holder_pid")),
        "requested_at": num(request.get("requested_at")),
        "note": request.get("note") or None,
    }
json.dump(out, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
}

handover_show() {
  local mode=human kind written to_pid to_session lock_pid recorded age printed=1 rkind
  case "${1:-}" in
    --json) handover_show_json; exit 0 ;;
    --digest) mode=digest ;;
    '') ;;
    *) handover_die "usage: fm-lock.sh handover show [--json|--digest]" ;;
  esac
  if handover_request_live; then
    rkind=$(handover_field "$HANDOVER_REQUEST" kind)
    printf 'HANDOVER REQUESTED (%s) at %s' "$rkind" "$(handover_iso "$(handover_field "$HANDOVER_REQUEST" requested_at)")"
    [ "$rkind" != takeover ] || printf ' by harness pid %s' "$(handover_field "$HANDOVER_REQUEST" requester_pid)"
    printf '\n'
    if fm_session_lock_owned_by_self "$STATE" 2>/dev/null; then
      if [ "$rkind" = takeover ]; then
        printf 'ACTION for this lock-holding session: fm-lock.sh handover template > <file>, fill every section, then fm-lock.sh handover release <file>.\n'
      else
        printf 'ACTION for this lock-holding session: fm-lock.sh handover template > <file>, fill every section, then fm-lock.sh handover write <file>.\n'
      fi
    fi
  fi
  if [ ! -f "$HANDOVER_RECORD" ]; then
    printf '(no handover record)\n'
    exit 0
  fi
  kind=$(handover_field "$HANDOVER_RECORD" kind)
  written=$(handover_field "$HANDOVER_RECORD" written_at)
  to_pid=$(handover_field "$HANDOVER_RECORD" to_pid)
  to_session=$(handover_field "$HANDOVER_RECORD" to_session)
  case "$written" in ''|*[!0-9]*) written=0 ;; esac
  age=$(( $(date +%s) - written ))
  if [ "$mode" = digest ]; then
    # A record addressed to the current lock holder, or any recent one, prints
    # in full; an old record addressed elsewhere is only named.
    lock_pid=$(head -n 1 "$LOCK" 2>/dev/null || true)
    recorded=$(fm_session_lock_recorded_session_id "$STATE" 2>/dev/null || true)
    printed=0
    if [ "$kind" = release ] && { { [ -n "$to_pid" ] && [ "$to_pid" = "$lock_pid" ]; } \
      || { [ -n "$to_session" ] && [ "$to_session" = "$recorded" ]; }; }; then
      printed=1
    elif [ "$age" -lt "$HANDOVER_FRESH_SECS" ]; then
      printed=1
    fi
  fi
  if [ "$printed" -eq 0 ]; then
    printf 'older %s handover record from %s at %s - not printed (not addressed to the current lock holder and older than %sh)\n' \
      "${kind:-unknown}" "$(handover_iso "$written")" "$HANDOVER_RECORD" "$((HANDOVER_FRESH_SECS / 3600))"
    exit 0
  fi
  printf '%s handover record written %s by harness pid %s' \
    "${kind:-unknown}" "$(handover_iso "$written")" "$(handover_field "$HANDOVER_RECORD" from_pid)"
  [ -z "$to_pid" ] || printf ' for harness pid %s' "$to_pid"
  printf ' (%s)\n' "$HANDOVER_RECORD"
  printf 'Act on it before new work: resume each piece in the local copy it names and settle every open ask and promise.\n\n'
  handover_body "$HANDOVER_RECORD" | awk -v max="$([ "$mode" = digest ] && echo "$HANDOVER_DIGEST_LINES" || echo 0)" -v path="$HANDOVER_RECORD" '
    max > 0 && NR > max { cut++; next } { print }
    END { if (cut) printf "(%d more line(s) omitted; read %s)\n", cut, path }'
  exit 0
}

if [ "${1:-}" = "handover" ]; then
  shift
  case "${1:-}" in
    request) shift; handover_request "$@" ;;
    template) handover_template; exit 0 ;;
    write|release) handover_write_or_release "$1" "${2:-}" ;;
    show) shift; handover_show "$@" ;;
    *) handover_die "usage: fm-lock.sh handover request|template|write|release|show" ;;
  esac
fi

me=$(fm_session_lock_anchor_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
# PHASE 0: committed/none. 1: sidecar mutated, line 1 not written. 2: line 1 written, not verified.
# KIND 0: no backup. 1: restore $LOCK_SESSION_PREV. 2: sidecar was absent.
LOCK_SESSION_PHASE=0
LOCK_SESSION_KIND=0
LOCK_SESSION_PREV="$STATE/.lock-session.prev"
LOCK_LINE_PRE=
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
restore_uncommitted_lock_session() {
  case "$LOCK_SESSION_PHASE" in
    1)
      case "$LOCK_SESSION_KIND" in
        1) mv -f "$LOCK_SESSION_PREV" "$LOCK_SESSION" 2>/dev/null || true ;;
        2) rm -f "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || true ;;
      esac
      ;;
    2) rm -f "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || true ;;
  esac
  LOCK_SESSION_PHASE=0
  LOCK_SESSION_KIND=0
}
commit_lock_session() {
  LOCK_SESSION_PHASE=0
  LOCK_SESSION_KIND=0
  rm -f "$LOCK_SESSION_PREV" 2>/dev/null || true
}
on_lock_exit() {
  restore_uncommitted_lock_session
  [ -n "$LOCK_LINE_PRE" ] && rm -f "$LOCK_LINE_PRE"
  release_claim_lock
}
trap on_lock_exit EXIT
trap 'exit 1' HUP INT TERM

remember_lock_session() {
  [ "$LOCK_SESSION_PHASE" -eq 0 ] || return 0
  if [ -e "$LOCK_SESSION" ] || [ -L "$LOCK_SESSION" ]; then
    rm -f "$LOCK_SESSION_PREV" 2>/dev/null || true
    cp -P "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || return 1
    LOCK_SESSION_KIND=1
  else
    LOCK_SESSION_KIND=2
  fi
  LOCK_SESSION_PHASE=1
}

# Record the trusted session id beside the lock, or remove a sidecar that no
# trusted id backs. Called only while the claim lock is held. A sidecar already
# naming this id is left untouched, so a same-session confirmation keeps it
# byte-identical.
publish_lock_session() {
  local trusted recorded tmp
  if trusted=$(fm_session_lock_trusted_session_id); then
    if recorded=$(fm_session_lock_recorded_session_id "$STATE") && [ "$recorded" = "$trusted" ]; then
      return 0
    fi
    remember_lock_session || return 1
    tmp=$(mktemp "$STATE/.lock-session.XXXXXX" 2>/dev/null) || return 1
    if ! { printf '%s\n' "$trusted" > "$tmp" && mv -f "$tmp" "$LOCK_SESSION"; } 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null
      return 1
    fi
    return 0
  fi
  if [ -e "$LOCK_SESSION" ] || [ -L "$LOCK_SESSION" ]; then
    remember_lock_session || return 1
    rm -f "$LOCK_SESSION" 2>/dev/null || return 1
  fi
  return 0
}

publish_lock_session_or_die() {
  publish_lock_session && return 0
  echo "error: cannot record the session identity beside the lock; operate read-only until resolved" >&2
  exit 1
}

# This session already holds the lock, recorded as pid $1. Line 1 stays exactly
# as recorded while that pid is alive; only the sidecar is refreshed, under the
# claim lock, so a /clear re-key inside the same process replaces the old id.
# A same-session confirmation waits for the claim lock so the sidecar refresh
# completes. After the wait, the lock is re-read and the sidecar is refreshed
# only when this session still owns it; otherwise the claim lock is released
# and the caller continues with the ordinary live-owner or reclaim path. The
# prior-session-sweep-is-finishing refusal is a takeover rule and does not
# apply here.
confirm_own_lock() {  # <recorded-pid>
  local recorded waited=0
  if [ "$CLAIM_LOCK_HELD" -ne 1 ]; then
    fm_lock_acquire_wait "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=1
    waited=1
  fi
  recorded=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$recorded" = "$me" ] || fm_session_lock_owned_by_self "$STATE"; then
    publish_lock_session_or_die
    commit_lock_session
    release_claim_lock
    echo "lock acquired: harness pid $recorded"
    exit 0
  fi
  if [ "$waited" -eq 1 ]; then
    release_claim_lock
  fi
  return 1
}

refuse_live_owner() {  # <recorded-pid>
  local recorded
  if recorded=$(fm_session_lock_recorded_session_id "$STATE"); then
    echo "error: another live firstmate session holds the lock (pid $1, session $recorded); operate read-only until resolved" >&2
  else
    echo "error: another live firstmate session holds the lock (pid $1); operate read-only until resolved" >&2
  fi
  exit 1
}

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ] || fm_session_lock_owned_by_self "$STATE"; then
    confirm_own_lock "$old"
    old=$(cat "$LOCK" 2>/dev/null || true)
  fi
  if fm_harness_pid_alive "$old"; then
    refuse_live_owner "$old"
  fi
fi

if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
  sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
  if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
    echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$CLAIM_LOCK"
fi
CLAIM_LOCK_HELD=1

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if [ "$old" != "$me" ] && fm_harness_pid_alive "$old"; then
    fm_session_lock_owned_by_self "$STATE" && confirm_own_lock "$old"
    old=$(cat "$LOCK" 2>/dev/null || true)
    if [ "$old" != "$me" ] && fm_harness_pid_alive "$old"; then
      refuse_live_owner "$old"
    fi
  fi
fi
# The sidecar goes first: a fresh pid beside a previous session's id would let
# that session's resume own this lock. If the sidecar changes before line 1 is
# written, a failure restores the previous sidecar. If line 1 is written but
# not yet verified, a failure removes the sidecar and leaves the lock
# ancestry-only. After line 1 verifies as this session's anchor, a later
# signal leaves the published pair in place.
publish_lock_session_or_die
if [ -f "$LOCK" ]; then
  LOCK_LINE_PRE=$(mktemp "$STATE/.lock.pre.XXXXXX") || {
    echo "error: cannot write session lock; operate read-only until resolved" >&2
    exit 1
  }
  if ! cp "$LOCK" "$LOCK_LINE_PRE" 2>/dev/null; then
    echo "error: cannot write session lock; operate read-only until resolved" >&2
    exit 1
  fi
fi
LOCK_SESSION_PHASE=2
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  lock_unchanged=0
  if [ -n "$LOCK_LINE_PRE" ] && cmp -s "$LOCK_LINE_PRE" "$LOCK"; then
    lock_unchanged=1
  elif [ -z "$LOCK_LINE_PRE" ] && [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; then
    lock_unchanged=1
  fi
  if [ "$lock_unchanged" -eq 1 ]; then
    if [ "$LOCK_SESSION_KIND" -ne 0 ]; then
      LOCK_SESSION_PHASE=1
    else
      LOCK_SESSION_PHASE=0
    fi
  fi
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
commit_lock_session
release_claim_lock
echo "lock acquired: harness pid $me"
