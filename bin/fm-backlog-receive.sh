#!/usr/bin/env bash
# Receive one delivered remote-secondmate outbox into this home's backlog.
#
# Usage:
#   fm-backlog-receive.sh state/handoff/<secondmate-id>.outbox.md <bytes> <sha256> <generation>
#   fm-backlog-receive.sh {--prepare-handoff|--complete-handoff} <task-id> < <transfer.json>
#
# Delivered-file mode accepts one confined non-symlink backlog scratch file and
# moves destination-absent Queued keys through one dependency-closed tasks-axi
# transaction. Destination-present classification makes caller retry idempotent.
# Receipt mode reads one exact transfer envelope and asks fm-work-identity.sh to
# validate or advance its destination backlog-ownership state.
# If tasks-axi reports a lock failure, this host may retry once only after proving
# its own backlog or delivered lock has a dead pid and is at least 30 seconds old.
# No live or uncertain lock is touched.
# After a confirmed receipt, the delivered scratch file is removed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DEST="$FM_HOME/data/backlog.md"
LOCK_STALE_SECS=30

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

sha256_stream() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi
}

backlog_key_section() { # <file> <key>
  awk -v key="$2" '
    BEGIN { section = "## Queued" }
    /^##[[:space:]]+/ { section=$0; sub(/^##[[:space:]]+/, "## ", section); sub(/[[:space:]]+$/, "", section); next }
    /^- \[[ x]\] / {
      rest=$0; sub(/^- \[[ x]\] +/, "", rest); id=rest; sub(/[ \t].*/, "", id)
      if (id == key) { print section; found=1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

list_keys() { # <file>
  awk '
    /^- \[[ x]\] / {
      rest=$0; sub(/^- \[[ x]\] +/, "", rest); id=rest; sub(/[ \t].*/, "", id)
      if (id != "" && !seen[id]++) print id
    }
  ' "$1"
}

backlog_task_sha256() {
  local file=$1 task=$2
  [ "$(backlog_key_section "$file" "$task" 2>/dev/null || true)" = '## Queued' ] || return 1
  awk -v key="$task" '
    function item_id(line, rest, id) {
      rest=line; sub(/^- \[[ x]\] +/, "", rest); id=rest; sub(/[ \t].*/, "", id); return id
    }
    /^- \[[ x]\] / {
      if (capturing) exit
      if (item_id($0) == key) { capturing=1; print }
      next
    }
    capturing && /^##[[:space:]]+/ { exit }
    capturing && /^[[:space:]]*$/ { blanks++; next }
    capturing {
      while (blanks > 0) { print ""; blanks-- }
      print
    }
  ' "$file" | sha256_stream
}

handoff_backlog_transition() {
  local action=$1 task=$2 transfer expected section observed state action_rc
  transfer=$(umask 077; mktemp "$FM_HOME/state/.handoff-transfer.XXXXXX") || return 1
  if ! LC_ALL=C head -c 73729 > "$transfer"; then
    rm -f -- "$transfer"
    return 1
  fi
  [ "$(LC_ALL=C wc -c < "$transfer" | tr -d ' ')" -le 73728 ] || {
    rm -f -- "$transfer"
    return 1
  }
  expected=$(jq -er '.backlog.task_sha256 | select(type == "string" and test("^[0-9a-f]{64}$"))' "$transfer" 2>/dev/null) || {
    rm -f -- "$transfer"
    return 1
  }
  state=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-work-identity.sh" handoff-target-state "$task" --file "$transfer") || {
    rm -f -- "$transfer"
    return 1
  }
  if [ "$state" = completed ]; then
    rm -f -- "$transfer"
    return 0
  fi
  section=$(backlog_key_section "$DEST" "$task" 2>/dev/null || true)
  if [ "$action" = prepare ] && [ -z "$section" ]; then
    action_rc=0
    state=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
      "$SCRIPT_DIR/fm-work-identity.sh" handoff-backlog-state "$task" --file "$transfer") \
      || action_rc=$?
    case "$state" in prepared|backlog-prepared|backlog-completed|completed) ;; *) action_rc=1 ;; esac
    rm -f -- "$transfer"
    return "$action_rc"
  fi
  [ "$section" = '## Queued' ] || {
    rm -f -- "$transfer"
    return 1
  }
  observed=$(backlog_task_sha256 "$DEST" "$task") || {
    rm -f -- "$transfer"
    return 1
  }
  [ "$observed" = "$expected" ] || {
    rm -f -- "$transfer"
    return 1
  }
  action_rc=0
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-work-identity.sh" handoff-backlog-complete "$task" \
      --file "$transfer" --backlog-sha256 "$observed" >/dev/null \
    || action_rc=$?
  rm -f -- "$transfer"
  return "$action_rc"
}

lock_age() {
  local modified now
  if [ "$(uname 2>/dev/null)" = Darwin ]; then
    modified=$(stat -f '%m' "$1" 2>/dev/null) || return 1
  else
    modified=$(stat -c '%Y' "$1" 2>/dev/null) || return 1
  fi
  now=$(date +%s) || return 1
  case "$modified$now" in *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((now - modified))"
}

remove_dead_stale_lock() { # <lock-path>
  local lock=$1 token pid age
  [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
  IFS= read -r token < "$lock" || return 1
  pid=${token%%:*}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null && return 1
  age=$(lock_age "$lock") || return 1
  [ "$age" -ge "$LOCK_STALE_SECS" ] || return 1
  rm -f -- "$lock"
}

run_move() { # <keys...>
  tasks-axi mv "$@" --file "$DELIVERED" --to "$DEST"
}

case "${1:-}" in
  --prepare-handoff|--complete-handoff)
    [ "$#" -eq 2 ] || usage
    ACTION=${1#--}
    ACTION=${ACTION%-handoff}
    TASK=$2
    case "$TASK" in ''|.*|*[!A-Za-z0-9._-]*) die "handoff task id is unsafe" ;; esac
    [ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] \
      || die "FM_HOME is not a seeded secondmate home"
    [ -f "$FM_HOME/AGENTS.md" ] && [ -d "$FM_HOME/bin" ] || die "FM_HOME is not a Firstmate home"
    mkdir -p "$FM_HOME/data" "$FM_HOME/state"
    [ ! -L "$DEST" ] || die "destination backlog must not be a symlink"
    if [ -e "$DEST" ] && [ ! -f "$DEST" ]; then die "destination backlog is not a regular file"; fi
    handoff_backlog_transition "$ACTION" "$TASK" || die "exact destination backlog receipt refused for $TASK"
    exit 0
    ;;
esac

[ "$#" -eq 4 ] || usage
REL=$1
EXPECTED_BYTES=$2
EXPECTED_HASH=$3
GENERATION=$4
case "$EXPECTED_BYTES" in ''|*[!0-9]*) die "expected bytes must be a nonnegative integer" ;; esac
[ "${#EXPECTED_BYTES}" -le 10 ] || die "expected bytes are outside the supported range"
[ "$EXPECTED_BYTES" -le 1048576 ] || die "expected bytes are outside the supported range"
case "$EXPECTED_HASH" in ''|*[!A-Fa-f0-9]*) die "expected SHA-256 is invalid" ;; esac
[ "${#EXPECTED_HASH}" -eq 64 ] || die "expected SHA-256 has the wrong length"
EXPECTED_HASH=$(printf '%s' "$EXPECTED_HASH" | tr 'A-F' 'a-f')
case "$GENERATION" in ''|*[!0-9]*) die "generation must be a positive integer" ;; esac
[ "${#GENERATION}" -le 18 ] && [ "$GENERATION" -ge 1 ] || die "generation is outside the supported range"
case "$REL" in state/handoff/*.outbox.md) ;; *) die "delivered outbox path is outside state/handoff: $REL" ;; esac
case "/$REL/" in */../*|*/./*) die "delivered outbox path contains traversal" ;; esac
case "$REL" in *'//'*) die "delivered outbox path is malformed" ;; esac
[ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] \
  || die "FM_HOME is not a seeded secondmate home"
[ -f "$FM_HOME/AGENTS.md" ] && [ -d "$FM_HOME/bin" ] || die "FM_HOME is not a Firstmate home"
HOME_REAL=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "FM_HOME cannot be resolved"
PARENT=$(dirname "$FM_HOME/$REL")
PARENT_REAL=$(CDPATH='' cd -- "$PARENT" 2>/dev/null && pwd -P) || die "delivered outbox parent is unavailable"
case "$PARENT_REAL" in "$HOME_REAL/state/handoff") ;; *) die "delivered outbox escapes the remote scratch directory" ;; esac
DELIVERED="$PARENT_REAL/$(basename "$REL")"
NAME=$(basename "$REL")
ID=${NAME%.outbox.md}
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "delivered outbox id is unsafe" ;; esac
TRANSFER_LOCK="$PARENT_REAL/.$ID.upload.lock"
BACKLOG_LOCK="$FM_HOME/state/.backlog-mutation.lock"
TRANSFER_LOCK_HELD=0
BACKLOG_LOCK_HELD=0
IDENTITY_BATCH_LOCKS_HELD=0
IDENTITY_BATCH_LOCK_NAMES=()
IDENTITY_BATCH_LOCK_TOKEN=
IDENTITY_BATCH_LOCK_PID=
IDENTITY_BATCH_STATE_REAL=
IDENTITY_BATCH_STATE_ID=
IDENTITY_BATCH_DATA_REAL=
IDENTITY_BATCH_DATA_ID=
identity_batch_locks_release() {
  local index name
  [ "$IDENTITY_BATCH_LOCKS_HELD" -eq 1 ] || return 0
  index=${#IDENTITY_BATCH_LOCK_NAMES[@]}
  while [ "$index" -gt 0 ]; do
    index=$((index - 1))
    name=${IDENTITY_BATCH_LOCK_NAMES[$index]}
    python3 "$SCRIPT_DIR/fm-work-identity-fs.py" lock-release \
      "$IDENTITY_BATCH_STATE_REAL" "$IDENTITY_BATCH_STATE_ID" "$name" \
      "$IDENTITY_BATCH_LOCK_PID" "$IDENTITY_BATCH_LOCK_TOKEN" >/dev/null 2>&1 || true
  done
  python3 "$SCRIPT_DIR/fm-work-identity-fs.py" lock-release \
    "$IDENTITY_BATCH_DATA_REAL" "$IDENTITY_BATCH_DATA_ID" ".work-identity-publication.lock" \
    "$IDENTITY_BATCH_LOCK_PID" "$IDENTITY_BATCH_LOCK_TOKEN" >/dev/null 2>&1 || true
  IDENTITY_BATCH_LOCKS_HELD=0
}
receive_locks_release() {
  identity_batch_locks_release
  [ "$BACKLOG_LOCK_HELD" -eq 0 ] || fm_lock_release "$BACKLOG_LOCK" || true
  [ "$TRANSFER_LOCK_HELD" -eq 0 ] || fm_lock_release "$TRANSFER_LOCK" || true
}
trap receive_locks_release EXIT
fm_lock_acquire_wait "$TRANSFER_LOCK" || die "cannot lock delivered outbox"
TRANSFER_LOCK_HELD=1
fm_lock_acquire_wait "$BACKLOG_LOCK" || die "cannot lock destination backlog"
BACKLOG_LOCK_HELD=1
[ -f "$DELIVERED" ] && [ ! -L "$DELIVERED" ] || die "delivered outbox is not a non-symlink regular file"
GENERATION_FILE="$PARENT_REAL/.$ID.upload-generation"
[ -f "$GENERATION_FILE" ] && [ ! -L "$GENERATION_FILE" ] || die "delivered outbox generation is unavailable or unsafe"
{
  IFS= read -r STORED_GENERATION \
    && IFS= read -r STORED_BYTES \
    && IFS= read -r STORED_HASH \
    && ! IFS= read -r
} < "$GENERATION_FILE" || die "delivered outbox generation is malformed"
case "$STORED_GENERATION" in ''|*[!0-9]*) die "delivered outbox generation is malformed" ;; esac
[ "${#STORED_GENERATION}" -le 18 ] || die "delivered outbox generation is malformed"
case "$STORED_BYTES" in ''|*[!0-9]*) die "delivered outbox generation is malformed" ;; esac
case "$STORED_HASH" in ''|*[!A-Fa-f0-9]*) die "delivered outbox generation is malformed" ;; esac
[ "${#STORED_HASH}" -eq 64 ] || die "delivered outbox generation is malformed"
[ "$STORED_GENERATION" = "$GENERATION" ] \
  && [ "$STORED_BYTES" = "$EXPECTED_BYTES" ] \
  && [ "$STORED_HASH" = "$EXPECTED_HASH" ] \
  || die "delivered outbox generation is superseded or conflicting"
ACTUAL_BYTES=$(LC_ALL=C wc -c < "$DELIVERED" | tr -d ' ')
[ "$ACTUAL_BYTES" -eq "$EXPECTED_BYTES" ] || die "delivered outbox length does not match its commitment"
ACTUAL_HASH=$(sha256_file "$DELIVERED") || die "cannot hash delivered outbox"
[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || die "delivered outbox digest does not match its commitment"
[ ! -L "$DEST" ] || die "destination backlog must not be a symlink"
if [ -e "$DEST" ] && [ ! -f "$DEST" ]; then die "destination backlog is not a regular file"; fi

KEYS=()
while IFS= read -r key; do
  [ -n "$key" ] && KEYS+=("$key")
done < <(list_keys "$DELIVERED")
for key in "${KEYS[@]}"; do
  section=$(backlog_key_section "$DELIVERED" "$key") || die "delivered key disappeared during classification: $key"
  [ "$section" = '## Queued' ] || die "delivered outbox contains non-Queued item $key under $section"
done

mkdir -p "$FM_HOME/data" "$FM_HOME/state"
IDENTITY_BATCH_STATE_REAL=$(CDPATH='' cd -- "$FM_HOME/state" && pwd -P) \
  || die "cannot resolve work identity state directory"
IDENTITY_BATCH_DATA_REAL=$(CDPATH='' cd -- "$FM_HOME/data" && pwd -P) \
  || die "cannot resolve work identity data directory"
if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
  IDENTITY_BATCH_STATE_ID=$(stat -f '%d:%i' "$IDENTITY_BATCH_STATE_REAL") \
    || die "cannot identify work identity state directory"
  IDENTITY_BATCH_DATA_ID=$(stat -f '%d:%i' "$IDENTITY_BATCH_DATA_REAL") \
    || die "cannot identify work identity data directory"
else
  IDENTITY_BATCH_STATE_ID=$(stat -c '%d:%i' "$IDENTITY_BATCH_STATE_REAL") \
    || die "cannot identify work identity state directory"
  IDENTITY_BATCH_DATA_ID=$(stat -c '%d:%i' "$IDENTITY_BATCH_DATA_REAL") \
    || die "cannot identify work identity data directory"
fi
IDENTITY_BATCH_LOCK_PID=${BASHPID:-$$}
IDENTITY_BATCH_LOCK_TOKEN="handoff-${IDENTITY_BATCH_LOCK_PID}-${RANDOM}-${RANDOM}"
while :; do
  lock_rc=0
  python3 "$SCRIPT_DIR/fm-work-identity-fs.py" lock-try \
    "$IDENTITY_BATCH_DATA_REAL" "$IDENTITY_BATCH_DATA_ID" ".work-identity-publication.lock" \
    "$IDENTITY_BATCH_LOCK_PID" "$IDENTITY_BATCH_LOCK_TOKEN" "${FM_LOCK_STALE_AFTER:-2}" >/dev/null \
    || lock_rc=$?
  case "$lock_rc" in 0) break ;; 2) sleep 0.1 ;; *) die "work identity publication lock is unsafe" ;; esac
done
IDENTITY_BATCH_LOCKS_HELD=1
LOCK_TASKS=()
while IFS= read -r key; do
  [ -n "$key" ] && LOCK_TASKS+=("$key")
done < <(printf '%s\n' "${KEYS[@]}" | LC_ALL=C sort -u)
for key in "${LOCK_TASKS[@]}"; do
  case "$key" in ''|.*|*[!A-Za-z0-9._-]*) die "delivered task id is unsafe: $key" ;; esac
  lock_key=$(printf '%s' "$key" | sha256_stream) || die "cannot identify work identity task lock"
  lock_name=".work-identity-task-${lock_key}.lock"
  while :; do
    lock_rc=0
    python3 "$SCRIPT_DIR/fm-work-identity-fs.py" lock-try \
      "$IDENTITY_BATCH_STATE_REAL" "$IDENTITY_BATCH_STATE_ID" "$lock_name" \
      "$IDENTITY_BATCH_LOCK_PID" "$IDENTITY_BATCH_LOCK_TOKEN" "${FM_LOCK_STALE_AFTER:-2}" >/dev/null \
      || lock_rc=$?
    case "$lock_rc" in 0) break ;; 2) sleep 0.1 ;; *) die "work identity task lock is unsafe for $key" ;; esac
  done
  IDENTITY_BATCH_LOCK_NAMES+=("$lock_name")
done
FM_WORK_IDENTITY_BATCH_LOCK_TASKS=$(printf '%s\n' "${LOCK_TASKS[@]}")
export FM_WORK_IDENTITY_BATCH_LOCK_PID="$IDENTITY_BATCH_LOCK_PID"
export FM_WORK_IDENTITY_BATCH_LOCK_TOKEN="$IDENTITY_BATCH_LOCK_TOKEN"
export FM_WORK_IDENTITY_BATCH_LOCK_TASKS

DEST_CREATED=0
TO_MOVE=()
ALREADY=()
for key in "${KEYS[@]}"; do
  if backlog_key_section "$DEST" "$key" >/dev/null 2>&1; then
    ALREADY+=("$key")
  else
    TO_MOVE+=("$key")
  fi
done

for key in "${KEYS[@]}"; do
  TARGET_RECEIPT="$FM_HOME/data/$key/work-identity-handoff-target.json"
  [ -f "$TARGET_RECEIPT" ] && [ ! -L "$TARGET_RECEIPT" ] \
    || die "exact destination backlog receipt is absent for $key"
  TARGET_TRANSFER=$(jq -e -S -c '.transfer' "$TARGET_RECEIPT" 2>/dev/null) \
    || die "exact destination backlog receipt is malformed for $key"
  if backlog_key_section "$DEST" "$key" >/dev/null 2>&1; then
    COMMITTED_BACKLOG=$DEST
  else
    COMMITTED_BACKLOG=$DELIVERED
  fi
  EXPECTED_TASK_HASH=$(printf '%s' "$TARGET_TRANSFER" \
    | jq -er '.backlog.task_sha256 | select(type == "string" and test("^[0-9a-f]{64}$"))' 2>/dev/null) \
    || die "exact destination backlog commitment is malformed for $key"
  OBSERVED_TASK_HASH=$(backlog_task_sha256 "$COMMITTED_BACKLOG" "$key") \
    || die "exact destination backlog item is absent or not Queued for $key"
  [ "$OBSERVED_TASK_HASH" = "$EXPECTED_TASK_HASH" ] \
    || die "exact destination backlog commitment is stale or mismatched for $key"
  printf '%s\n' "$TARGET_TRANSFER" | handoff_backlog_transition prepare "$key" \
    || die "exact destination backlog receipt was refused before batch move for $key"
done

if [ "${#TO_MOVE[@]}" -gt 0 ]; then
  fm_tasks_axi_compatible || die "a compatible tasks-axi is required for atomic backlog receipt; run bin/fm-bootstrap.sh for the required version"
  if [ ! -f "$DEST" ]; then
    printf '## In flight\n\n## Queued\n\n## Done\n' > "$DEST"
    DEST_CREATED=1
  fi
  if ! MOVE_OUT=$(run_move "${TO_MOVE[@]}" 2>&1); then
    recovered=0
    for lock in "$DELIVERED.lock" "$DEST.lock"; do
      if remove_dead_stale_lock "$lock"; then recovered=1; fi
    done
    if [ "$recovered" -ne 1 ] || ! MOVE_OUT=$(run_move "${TO_MOVE[@]}" 2>&1); then
      [ "$DEST_CREATED" -eq 0 ] || rm -f -- "$DEST"
      [ -z "$MOVE_OUT" ] || printf '%s\n' "$MOVE_OUT" >&2
      die "atomic backlog receipt failed; delivered outbox is preserved for retry"
    fi
  fi
fi

for key in "${KEYS[@]}"; do
  backlog_key_section "$DEST" "$key" >/dev/null 2>&1 \
    || die "receipt verification failed for $key; delivered outbox is preserved"
  TARGET_RECEIPT="$FM_HOME/data/$key/work-identity-handoff-target.json"
  [ -f "$TARGET_RECEIPT" ] && [ ! -L "$TARGET_RECEIPT" ] \
    || die "exact destination backlog receipt is absent for $key"
  TARGET_TRANSFER=$(jq -e -S -c '.transfer' "$TARGET_RECEIPT" 2>/dev/null) \
    || die "exact destination backlog receipt is malformed for $key"
  printf '%s\n' "$TARGET_TRANSFER" | handoff_backlog_transition complete "$key" \
    || die "exact destination backlog receipt is incomplete for $key"
done
rm -f -- "$DELIVERED" || die "receipt succeeded but delivered scratch cleanup failed"
identity_batch_locks_release
unset FM_WORK_IDENTITY_BATCH_LOCK_PID FM_WORK_IDENTITY_BATCH_LOCK_TOKEN FM_WORK_IDENTITY_BATCH_LOCK_TASKS
fm_lock_release "$BACKLOG_LOCK" || die "receipt succeeded but backlog lock cleanup failed"
BACKLOG_LOCK_HELD=0
fm_lock_release "$TRANSFER_LOCK" || die "receipt succeeded but transfer lock cleanup failed"
TRANSFER_LOCK_HELD=0
trap - EXIT
printf 'received: %s moved=%s already=%s\n' "$(basename "$REL" .outbox.md)" "${#TO_MOVE[@]}" "${#ALREADY[@]}"
