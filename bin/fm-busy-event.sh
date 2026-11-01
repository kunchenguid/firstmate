#!/usr/bin/env bash
# fm-busy-event.sh - the ONLY writer of the semantic busy-state contract
# owned by bin/fm-busy-lib.sh (record format, gen binding, and classification
# live there; this script owns mutation mechanics only).
#
# Subcommands:
#
#   arm <state-dir> <id> [--state busy|idle|unknown] [--source S] [--event E]
#       Mint a fresh incarnation gen token, write the gen sidecar, and seed
#       the record at seq=1 (default: busy, source fm-spawn, event
#       launch-brief - the launch prompt IS a submitted turn). Prints the
#       minted gen on stdout so the caller can embed it into adapter wiring.
#       Arming again replaces the previous incarnation: late events carrying
#       the old gen are rejected as stale from then on.
#
#   apply <state-dir> <id> <busy|idle|unknown> (--gen G | --current-gen)
#         --source S --event E [--turn-ended]
#       Append one lifecycle event: validate the gen against the armed
#       sidecar, advance seq under the lock, atomically replace the record.
#       A non-busy event also clears active stream evidence and closes any
#       request ordering record, so a settled or unknown worker never leaves
#       an observation standing.
#       --turn-ended also touches state/<id>.turn-ended, the watcher
#       notification, under the same lock, so a writer whose gen was refused,
#       or whose incarnation is replaced right after, never signals the
#       replacement.
#       Adapter wiring passes the exact --gen embedded at arm time, so a
#       hook that outlives its incarnation fails closed here. The legacy
#       Claude fm-send --key Escape path (fm-interrupt) and firstmate recovery
#       paths (fm-recovery) may pass --current-gen to bind to the incarnation
#       armed right now.
#
#   progress <state-dir> <id> --gen G
#       Refresh state/<id>.progress for observed native-harness activity under
#       the incarnation lock. This neither changes busy state nor emits a
#       turn-ended notification. Arm and retire clear the marker, and an old
#       incarnation can never refresh its replacement's progress.
#
#   permission-request <state-dir> <id> --gen G
#       Read a Claude PermissionRequest JSON payload on stdin and append a
#       keyed needs-decision event to state/<id>.status without changing busy
#       state or answering the prompt. Duplicate requests share a key derived
#       from the incarnation, lifecycle sequence, session, tool input, and
#       transcript byte position. The next apply event of the same incarnation
#       appends the matching resolved line once. The status log is the durable dedup record;
#       the existing watcher surfaces it even while the busy record is open.
#
#   retire <state-dir> <id> (--gen G | --current-gen)
#       Remove one incarnation's sidecar and record while holding the same
#       writer lock used by arm and apply. An exact gen prevents teardown for
#       an old task from retiring a newly armed incarnation. A missing sidecar
#       is already retired, so any orphan record is removed idempotently.
#
#   stream <state-dir> <id> <open|progress|close> --gen G --request N
#       Mutate the optional Pi stream contract owned by fm-busy-lib.sh.
#       Open requires a strictly newer request; open and progress both require
#       a busy pi-ext record, and progress and close must name the recorded
#       request. Close removes active evidence before persisting closed
#       ordering, so a persistence failure cannot leave observation active.
#
# Exit codes: 0 applied; 1 refused (stale gen, unarmed task, lock timeout,
# invalid input); 2 usage. Adapter hook command lines append `|| true` so a
# refusal never breaks the harness's own lifecycle.
set -u

usage() {
  cat >&2 <<'EOF'
usage:
  fm-busy-event.sh arm <state-dir> <id> [--state busy|idle|unknown] [--source S] [--event E]
  fm-busy-event.sh apply <state-dir> <id> <busy|idle|unknown> (--gen G | --current-gen) --source S --event E [--turn-ended]
  fm-busy-event.sh progress <state-dir> <id> --gen G
  fm-busy-event.sh stream <state-dir> <id> <open|progress|close> --gen G --request N
  fm-busy-event.sh permission-request <state-dir> <id> --gen G
  fm-busy-event.sh retire <state-dir> <id> (--gen G | --current-gen)
See the header comment for the full contract.
EOF
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

CMD=${1:-}
case "$CMD" in
  arm|apply|progress|stream|permission-request|retire) shift ;;
  *) usage ;;
esac

STATE=${1:-}
ID=${2:-}
[ -n "$STATE" ] && [ -n "$ID" ] || usage
shift 2
case "$ID" in *[!A-Za-z0-9._-]*) echo "error: invalid task id" >&2; exit 1 ;; esac
[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }

NEW_STATE=
GEN=
USE_CURRENT_GEN=0
TURN_ENDED=0
SOURCE=
EVENT=
STREAM_OP=
REQUEST=
if [ "$CMD" = apply ]; then
  NEW_STATE=${1:-}
  case "$NEW_STATE" in busy|idle|unknown) shift ;; *) usage ;; esac
elif [ "$CMD" = arm ]; then
  NEW_STATE=busy
  SOURCE=fm-spawn
  EVENT=launch-brief
elif [ "$CMD" = stream ]; then
  STREAM_OP=${1:-}
  case "$STREAM_OP" in open|progress|close) shift ;; *) usage ;; esac
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --state) NEW_STATE=${2:-}; shift 2 || usage ;;
    --gen) GEN=${2:-}; shift 2 || usage ;;
    --current-gen) USE_CURRENT_GEN=1; shift ;;
    --source) SOURCE=${2:-}; shift 2 || usage ;;
    --event) EVENT=${2:-}; shift 2 || usage ;;
    --turn-ended) [ "$CMD" = apply ] || usage; TURN_ENDED=1; shift ;;
    --request) REQUEST=${2:-}; shift 2 || usage ;;
    *) usage ;;
  esac
done
if [ "$CMD" = apply ] || [ "$CMD" = arm ]; then
  case "$NEW_STATE" in busy|idle|unknown) : ;; *) usage ;; esac
  fm_busy_token_valid "$SOURCE" || { echo "error: invalid --source" >&2; exit 1; }
  fm_busy_token_valid "$EVENT" || { echo "error: invalid --event" >&2; exit 1; }
fi

case "$CMD" in progress|permission-request) [ "$USE_CURRENT_GEN" = 0 ] || usage ;; esac
if [ "$CMD" = stream ]; then
  [ "$USE_CURRENT_GEN" = 0 ] || usage
  fm_busy_stream_uint_valid "$REQUEST" || usage
fi

if [ "$CMD" = permission-request ]; then
  PAYLOAD=$(jq -ceS '
    select(.hook_event_name == "PermissionRequest")
    | select((.session_id | type) == "string" and (.session_id | length) > 0)
    | select((.tool_name | type) == "string" and (.tool_name | test("^[A-Za-z0-9_.-]+$")))
    | select((.tool_input | type) == "object")
    | {session_id, tool_name, tool_input, transcript_path}
  ') || { echo "error: invalid Claude PermissionRequest payload" >&2; exit 1; }
fi

REC=$(fm_busy_record_path "$STATE" "$ID")
GEN_FILE=$(fm_busy_gen_path "$STATE" "$ID")
LOCK="$REC.lock"

# Portable mtime in epoch seconds. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU)
# stat uses `-c <fmt>`. Do NOT collapse this into `stat -f <fmt> ... || stat -c
# <fmt> ...`: on GNU `-f` is *filesystem* stat, so it reads the format string as
# a path, reports that on stderr, prints a partial filesystem dump ("  File:
# ...") on stdout, and still exits 0 - the fallback never runs and the caller
# gets a non-numeric token. Detect the platform once and pick the right form,
# exactly as bin/fm-watch.sh does.
if [ "$(uname)" = Darwin ]; then
  lock_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null; }
else
  lock_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

# Serialize writers. The lock protects seq advancement and the sidecar/record
# pair; a holder that died mid-write is broken after FM_BUSY_LOCK_STALE_SECS.
lock_acquire() {
  local tries=0 now mtime age
  while ! mkdir "$LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 40 ]; then
      now=$(date +%s)
      mtime=$(lock_mtime "$LOCK" || true)
      # Anything unreadable or non-numeric reads as "just created", so an
      # unforeseen stat surprise degrades to a lock-timeout refusal instead of
      # aborting the writer - and its caller, fm-teardown.sh - under `set -u`.
      case "$mtime" in ''|*[!0-9]*) mtime=$now ;; esac
      age=$((now - mtime))
      if [ "$age" -ge "${FM_BUSY_LOCK_STALE_SECS:-5}" ]; then
        rmdir "$LOCK" 2>/dev/null || rm -rf "$LOCK" 2>/dev/null || true
        mkdir "$LOCK" 2>/dev/null && break
      fi
      echo "error: busy-state lock timeout for $ID" >&2
      return 1
    fi
    sleep 0.05
  done
  return 0
}
lock_release() { rmdir "$LOCK" 2>/dev/null || true; }

write_record() {  # <gen> <seq>
  local tmp
  tmp="$REC.tmp.$$"
  printf 'v1 gen=%s seq=%s state=%s source=%s event=%s ts=%s\n' \
    "$1" "$2" "$NEW_STATE" "$SOURCE" "$EVENT" "$(date +%s)" > "$tmp" || return 1
  mv -f "$tmp" "$REC"
}

clear_stream() {
  local order order_gen request phase
  # Active observation must disappear even when closing-order persistence fails.
  # The retained order still denies duplicate open, and progress needs a marker.
  rm -f "$STATE/$ID.model-stream" || return 1
  if order=$(fm_busy_stream_order_read "$STATE" "$ID"); then
    read -r order_gen request phase <<< "$order"
    printf 'v1 gen=%s request=%s phase=closed\n' "$order_gen" "$request" > "$STATE/$ID.model-stream-order.tmp.$$" &&
      mv -f "$STATE/$ID.model-stream-order.tmp.$$" "$STATE/$ID.model-stream-order" || return 1
  fi
  return 0
}

clear_stream_incarnation() {
  rm -f "$STATE/$ID.model-stream" "$STATE/$ID.model-stream-order" "$STATE/$ID.model-progress" "$STATE/$ID.permission-keys"
}

old_umask=$(umask)
umask 077

if [ "$CMD" = arm ]; then
  GEN="g$(date +%s).$$.$RANDOM"
  lock_acquire || exit 1
  {
    printf '%s\n' "$GEN" > "$GEN_FILE.tmp.$$" && mv -f "$GEN_FILE.tmp.$$" "$GEN_FILE" \
      && write_record "$GEN" 1 && rm -f "$STATE/$ID.progress" && clear_stream_incarnation
  } || { lock_release; umask "$old_umask"; echo "error: arm failed for $ID" >&2; exit 1; }
  lock_release
  umask "$old_umask"
  printf '%s\n' "$GEN"
  exit 0
fi

# apply / progress / permission-request / retire
if [ "$USE_CURRENT_GEN" = 1 ] && [ "$CMD" != retire ]; then
  GEN=$(fm_busy_current_gen "$STATE" "$ID") || {
    umask "$old_umask"
    echo "error: no armed busy-state gen for $ID" >&2
    exit 1
  }
fi
if [ "$USE_CURRENT_GEN" != 1 ] || [ "$CMD" != retire ]; then
  fm_busy_token_valid "$GEN" || { umask "$old_umask"; echo "error: invalid --gen" >&2; exit 1; }
fi

lock_acquire || { umask "$old_umask"; exit 1; }
CURRENT=$(fm_busy_current_gen "$STATE" "$ID") || {
  if [ "$CMD" = retire ] && [ ! -e "$GEN_FILE" ] && [ ! -L "$GEN_FILE" ]; then
    if ! { rm -f "$REC" "$STATE/$ID.progress" && clear_stream_incarnation; }; then
      lock_release
      umask "$old_umask"
      echo "error: busy-state retirement failed for $ID" >&2
      exit 1
    fi
    lock_release
    umask "$old_umask"
    exit 0
  fi
  lock_release
  umask "$old_umask"
  echo "error: no armed busy-state gen for $ID" >&2
  exit 1
}
if [ "$CMD" = retire ] && [ "$USE_CURRENT_GEN" = 1 ]; then
  GEN=$CURRENT
fi
if [ "$GEN" != "$CURRENT" ]; then
  lock_release
  umask "$old_umask"
  echo "error: stale busy-state gen for $ID (event rejected)" >&2
  exit 1
fi
if [ "$CMD" = retire ]; then
  if ! { rm -f "$GEN_FILE" "$REC" "$STATE/$ID.progress" && clear_stream_incarnation; }; then
    lock_release
    umask "$old_umask"
    echo "error: busy-state retirement failed for $ID" >&2
    exit 1
  fi
  lock_release
  umask "$old_umask"
  exit 0
fi
if [ "$CMD" = progress ]; then
  touch "$STATE/$ID.progress" || { lock_release; umask "$old_umask"; exit 1; }
  lock_release
  umask "$old_umask"
  exit 0
fi
if [ "$CMD" = stream ]; then
  order_gen=$GEN old_request=0 phase=closed rev=1
  if [ -e "$STATE/$ID.model-stream-order" ]; then
    order=$(fm_busy_stream_order_read "$STATE" "$ID") || { lock_release; exit 1; }
    read -r order_gen old_request phase <<< "$order"
    [ "$order_gen" = "$GEN" ] || { lock_release; exit 1; }
  fi
  if [ "$STREAM_OP" = open ]; then
    [ "$REQUEST" -gt "$old_request" ] || { lock_release; exit 1; }
  else
    [ "$REQUEST" = "$old_request" ] || { lock_release; exit 1; }
  fi
  if [ "$STREAM_OP" = close ]; then
    clear_stream || { lock_release; exit 1; }
    lock_release
    exit 0
  fi
  case "$(fm_busy_record_read "$STATE" "$ID")" in 'busy pi-ext '*) : ;; *) lock_release; exit 1 ;; esac
  if [ "$STREAM_OP" = progress ]; then
    [ "$phase" = active ] || { lock_release; exit 1; }
    snapshot=$(fm_busy_stream_record_read "$STATE/$ID.model-stream") || { lock_release; exit 1; }
    read -r stream_gen stream_request old_rev _ <<< "$snapshot"
    [ "$stream_gen" = "$GEN" ] && [ "$stream_request" = "$REQUEST" ] || { lock_release; exit 1; }
    rev=$((old_rev + 1))
  else
    if ! { printf 'v1 gen=%s request=%s phase=active\n' "$GEN" "$REQUEST" > "$STATE/$ID.model-stream-order.tmp.$$" &&
      mv -f "$STATE/$ID.model-stream-order.tmp.$$" "$STATE/$ID.model-stream-order"; }; then
      lock_release; exit 1
    fi
  fi
  if ! { printf 'v1 gen=%s request=%s rev=%s ts=%s\n' "$GEN" "$REQUEST" "$rev" "$(date +%s)" > "$STATE/$ID.model-stream.tmp.$$" &&
    mv -f "$STATE/$ID.model-stream.tmp.$$" "$STATE/$ID.model-stream"; }; then
    lock_release; exit 1
  fi
  if [ "$STREAM_OP" = progress ]; then
    if ! { cp "$STATE/$ID.model-stream" "$STATE/$ID.model-progress.tmp.$$" &&
      mv -f "$STATE/$ID.model-progress.tmp.$$" "$STATE/$ID.model-progress"; }; then
      lock_release; exit 1
    fi
  fi
  lock_release
  exit 0
fi
if [ "$CMD" = permission-request ]; then
  transcript=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty')
  transcript_size=0
  if [ -f "$transcript" ]; then
    if [ "$(uname)" = Darwin ]; then
      transcript_size=$(/usr/bin/stat -f %z "$transcript")
    else
      transcript_size=$(stat -c %s "$transcript")
    fi
  fi
  request_key=$(printf '%s\n' "$GEN" "$(cat "$REC")" "$PAYLOAD" "$transcript_size" | git hash-object --stdin) || {
    lock_release; umask "$old_umask"; exit 1;
  }
  request_key="claude-permission-$request_key"
  status="$STATE/$ID.status"
  if ! grep -qF "[key=$request_key]:" "$status" 2>/dev/null; then
    tool=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name')
    printf 'needs-decision [at=%s] [key=%s]: Claude permission prompt for %s; inspect the worker and route the security decision; never answer with keys\n' \
      "$(date +%s)" "$request_key" "$tool" >> "$status" || {
      lock_release; umask "$old_umask"; exit 1;
    }
    printf '%s %s\n' "$GEN" "$request_key" >> "$STATE/$ID.permission-keys" || {
      lock_release; umask "$old_umask"; exit 1;
    }
  fi
  lock_release
  umask "$old_umask"
  exit 0
fi
OLD_SEQ=0
if [ -f "$REC" ]; then
  old_line=$(head -n 1 "$REC" 2>/dev/null || true)
  case "$old_line" in
    *" gen=$GEN "*)
      old_seq_field=${old_line##* seq=}
      old_seq_field=${old_seq_field%% *}
      case "$old_seq_field" in
        ''|*[!0-9]*) OLD_SEQ=0 ;;
        *) OLD_SEQ=$old_seq_field ;;
      esac
      ;;
  esac
fi
write_record "$GEN" $((OLD_SEQ + 1)) || {
  lock_release
  umask "$old_umask"
  echo "error: record write failed for $ID" >&2
  exit 1
}
if [ "$NEW_STATE" != busy ]; then
  clear_stream || { lock_release; exit 1; }
fi
if [ -f "$STATE/$ID.permission-keys" ]; then
  while read -r key_gen request_key; do
    [ "$key_gen" = "$GEN" ] || continue
    printf 'resolved [at=%s] [key=%s]: worker resumed after the Claude permission prompt\n' \
      "$(date +%s)" "$request_key" >> "$STATE/$ID.status" || true
  done < "$STATE/$ID.permission-keys"
  rm -f "$STATE/$ID.permission-keys"
fi
umask "$old_umask"
# Best effort: the record already settled, so a failed touch never refuses it.
[ "$TURN_ENDED" = 0 ] || touch "$STATE/$ID.turn-ended" 2>/dev/null || true
lock_release
exit 0
