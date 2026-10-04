#!/usr/bin/env bash
# fm-branch-outcome.sh - the durable outcome store for the Pi supervision
# branch (docs/pi-supervision-branch.md).
#
# CONTRACT (this header is the one owner of the store's format).
#   - Active store: $STATE/branch-outcomes.jsonl. One JSON
#     object per line: {"seq":N,"epoch":N,"task":"...","wake":"...",
#     "verdict":"routine"|"captain","summary":"...","silent":true|false,
#     "statusEndpoint":N,"statusIdent":"...","taskGeneration":"...",
#     "taskDisposition":"...","evidenceKey":"..."}. `evidenceKey` binds the exact stable producer
#     material revision (or captured status revision when no producer key is
#     supplied), while `taskGeneration` binds its proved executor generation.
#     An unproved generation/material pair uses the legacy non-coalescible row shape. Legacy rows without `silent`
#     or status provenance remain valid and are treated as visible.
#     Ordinary reads validate this retained active window as a gap-free
#     sequence beginning at the base sequence recorded in
#     $STATE/.branch-outcomes-base. The base is 1 when that sidecar is absent.
#     Malformed, duplicate, reordered, or base-mismatched rows fail closed.
#     Sequence identifiers are never rewritten.
#   - Cold store: $STATE/branch-outcomes-cold.jsonl preserves the original,
#     immutable bytes of every verified processed row moved out of the active
#     scan path. Compaction retains the processed frontier and the preceding
#     63 rows in the active store, plus every row above that frontier. It never
#     truncates a row and 64 is a row count, not a byte cap. Explicit full or
#     exact history reads, once-task identity checks, and index recovery may
#     validate and read cold evidence; ordinary unread, unprocessed, recent,
#     append, and cursor operations do not.
#     Compaction shares the outcome lock. Its prepared record publishes cold
#     evidence before the shorter active store and base, and every command
#     completes an interrupted publication before using the store.
#     Historical rows with the same identity fields remain explicitly readable;
#     current append uses them only for once-task identity, never as lifecycle
#     state. The read state lives entirely in the cursor sidecar so marking
#     outcomes read cannot disturb either store.
#   - Cursor: $STATE/.branch-outcomes-cursor holds the highest seq handed to
#     Pi as a routine merge note, persisted as a sequence-keyed visible captain
#     entry, emitted by the locked session-start replay, or silently consumed
#     there because `silent` is true. Records above the cursor are unread.
#     A captain row advances only after its matching visible entry exists in
#     Pi's session, so reload recovery is idempotent across that crash window.
#     A cursor beyond the validated store tail fails closed.
#   - Processed marker: $STATE/.branch-outcomes-processed holds the highest
#     seq whose captain rows main has ACKNOWLEDGED as processed, separately
#     from the read cursor: reading (the visible entry) is the branch's act,
#     processing (main acting on the outcome and calling its acknowledgement
#     tool) is main's. A captain row between the two markers is "unprocessed":
#     delivered and shown, not yet acted on. Routine rows never wait on this
#     marker. It only advances through an explicit sequence-bound
#     acknowledgement naming a currently unprocessed captain row at or below
#     the read cursor; a routine, unread, or already-processed target is
#     refused. It never moves past the read cursor or backwards, so an
#     unrelated or empty model answer cannot move it. An absent marker reads as
#     0 (every delivered captain row is unprocessed, the safe direction);
#     processed-init is the one-time migration that sets an absent marker to
#     the read cursor so rows delivered before the marker existed are not
#     re-presented. A present marker is validated before the migration returns,
#     and a marker ahead of the read cursor fails closed.
#   - Outcome index: $STATE/.<task>.branch-outcome-index stores one bounded
#     cache of the latest outcome's status provenance. The authoritative copy
#     is in the append-only row. $STATE/.branch-outcome-index-ready is removed
#     before append and published only after the cache update; processed-init
#     rebuilds every cache before publishing it, so interruption or upgrade
#     fails closed without making each drain scan lifetime history.
#     Legacy task labels outside today's filename-safe task identity (such as
#     endpoint names) remain in the store and delivery cursors but have no task
#     cache. Migration filters them before interpreting any label as a path.
#     bin/fm-teardown.sh removes a retired task's cache with its other records,
#     and append skips the cache for a task that has neither a live meta nor a
#     status log (the outcome itself is still stored), so the branch's report
#     of a teardown it just performed leaves no index behind.
#     Main-actor drain calls processed-init under the outcome lock when that
#     ready marker is absent or invalid, on every harness; only a genuine store
#     fault keeps the lost-wake backstop skipped.
#   - Every mutation runs under $STATE/.branch-outcomes.lock so the branch
#     extension and a concurrent session-start replay cannot interleave.
#   - The store is written BEFORE the outcome is delivered to main
#     (store-first durability): nothing about a handled event depends on
#     conversation memory.
#
# Usage:
#   fm-branch-outcome.sh append --task <id> --verdict routine|captain \
#       --summary <text> [--wake <text>] [--silent true|false] [--material-key <text>] [--once-task]
#     Append one outcome record; prints the assigned seq.
#     --once-task returns the existing row for an identical task/summary/verdict/
#     wake, refusing conflicting reuse. This is a terminal-producer retry key.
#   fm-branch-outcome.sh unread
#     Print every unread record (raw JSONL). Exit 0 with no output when none.
#   fm-branch-outcome.sh mark-read --through <seq>
#     Advance the cursor (never backwards) after handing the records to Pi.
#   fm-branch-outcome.sh unprocessed
#     Print every captain record that is read but not yet processed (raw
#     JSONL, ascending seq). Exit 0 with no output when none.
#   fm-branch-outcome.sh mark-processed --through <seq>
#     Advance the processed marker after main acknowledged the captain rows
#     through <seq>; the target itself must be a currently unprocessed captain
#     row at or below the read cursor.
#   fm-branch-outcome.sh processed-init [--held-lock]
#     Rebuild the bounded per-task outcome indexes, then create the processed
#     marker at the current read cursor when it does not exist yet; validate a
#     present marker without changing it. --held-lock is only for a descendant
#     of the process holding $STATE/.branch-outcomes.lock (fm-wake-drain.sh may
#     run its redirected presentation body in a subshell on Bash 3.2); it skips
#     the nested acquire so drain's bounded lock wait remains the deadline.
#   fm-branch-outcome.sh list [--recent <n>|--all|--seq <n>]
#     Print the last n active records (default 20), the complete validated
#     active+cold history with --all, or one exact active/cold record by stable
#     sequence with --seq.
#   fm-branch-outcome.sh compact --dry-run|--apply
#     Report or apply the 64-processed-row active retention policy.
#   fm-branch-outcome.sh startup-replay
#     Session-start recovery: print the leading routine unread records under a
#     labeled header into the locked startup digest, skip rows whose `silent`
#     field is true, and mark those leading routine rows read. Stop before the
#     first captain row because only Pi's sequence-keyed visible entry may
#     acknowledge that row. Prints nothing when nothing replayable is unread.
#     Run it only when the session holds the lock (fm-session-start.sh owns the
#     call site).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

STORE="$STATE/branch-outcomes.jsonl"
COLD_STORE="$STATE/branch-outcomes-cold.jsonl"
BASE_FILE="$STATE/.branch-outcomes-base"
COMPACTION_JOURNAL="$STATE/.branch-outcomes-compaction"
COMPACTION_ACTIVE="$STATE/.branch-outcomes-active.prepared"
COMPACTION_COLD="$STATE/.branch-outcomes-cold.prepared"
COMPACTION_BASE="$STATE/.branch-outcomes-base.prepared"
DATA_ROOT=${FM_DATA_OVERRIDE:-$FM_HOME/data}
CURSOR="$STATE/.branch-outcomes-cursor"
PROCESSED="$STATE/.branch-outcomes-processed"
LOCK="$STATE/.branch-outcomes.lock"
MAX_SAFE_SEQ=9007199254740991
OUTCOME_INDEX_VERSION=fm-branch-outcome-index-v1
OUTCOME_INDEX_MAX_BYTES=512
OUTCOME_INDEX_READY="$STATE/.branch-outcome-index-ready"
RETAIN_PROCESSED=64

usage() {
  echo "usage: fm-branch-outcome.sh append --task <id> --verdict routine|captain --summary <text> [--wake <text>] [--silent true|false] [--material-key <text>] [--once-task] | unread | mark-read --through <seq> | unprocessed | mark-processed --through <seq> | processed-init [--held-lock] | list [--recent <n>|--all|--seq <n>] | compact --dry-run|--apply | startup-replay" >&2
  exit 2
}

bounded_uint() {
  local value=$1
  case "$value" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#value}" -le "${#MAX_SAFE_SEQ}" ] || return 1
  [ "$value" -le "$MAX_SAFE_SEQ" ]
}

json_escape() { # <text> -> escaped JSON string content on stdout
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) print "\\n"
      line = $0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      # Any remaining C0 control character would break the JSON line record.
      gsub(/[\001-\010\013\014\016-\037]/, "", line)
      print line
    }'
}

sha256_text() { # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    echo "error: shasum or sha256sum is required" >&2
    return 1
  fi
}

read_cursor() {
  local value
  [ -e "$CURSOR" ] || { printf '0\n'; return 0; }
  if ! value=$(cat "$CURSOR" 2>/dev/null); then
    echo "error: refusing operation because the outcome cursor is unreadable" >&2
    return 1
  fi
  case "$value" in
    ''|*[!0-9]*|0[0-9]*)
      echo "error: refusing operation because the outcome cursor is malformed" >&2
      return 1
      ;;
  esac
  if ! bounded_uint "$value"; then
    echo "error: refusing operation because the outcome cursor is out of range" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

read_processed() {
  local value
  [ -e "$PROCESSED" ] || { printf '0\n'; return 0; }
  if ! value=$(cat "$PROCESSED" 2>/dev/null); then
    echo "error: refusing operation because the processed marker is unreadable" >&2
    return 1
  fi
  case "$value" in
    ''|*[!0-9]*|0[0-9]*)
      echo "error: refusing operation because the processed marker is malformed" >&2
      return 1
      ;;
  esac
  if ! bounded_uint "$value"; then
    echo "error: refusing operation because the processed marker is out of range" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

read_base() {
  local version value extra
  [ -e "$BASE_FILE" ] || { printf '1\n'; return 0; }
  exec 8< "$BASE_FILE" || {
    echo "error: refusing operation because the outcome base is unreadable" >&2
    return 1
  }
  IFS=$(printf '\t') read -r version value extra <&8 || true
  exec 8<&-
  if [ "$version" != fm-branch-outcomes-base-v1 ] || [ -n "$extra" ] \
      || ! bounded_uint "$value" || [ "$value" -lt 1 ]; then
    echo "error: refusing operation because the outcome base is malformed" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

sha256_file() { # <path>, including an absent/empty file
  if [ -s "$1" ]; then
    if command -v shasum >/dev/null 2>&1; then
      shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$1" | awk '{print $1}'
    else
      echo "error: shasum or sha256sum is required" >&2
      return 1
    fi
  else
    sha256_text ''
  fi
}

file_size() { # <path>
  [ -e "$1" ] || { printf '0\n'; return 0; }
  wc -c < "$1" | tr -d '[:space:]'
}

segment_last_seq() { # <path> <first-seq>
  local path=$1 first=$2
  [ -s "$path" ] || { printf '%s\n' "$((first - 1))"; return 0; }
  jq -Rse --argjson first "$first" '
    def valid:
      type == "object"
      and (
        keys == ["epoch", "seq", "summary", "task", "verdict", "wake"]
        or (keys == ["epoch", "seq", "silent", "summary", "task", "verdict", "wake"] and (.silent | type) == "boolean")
        or (
          ((keys == ["epoch", "seq", "silent", "statusEndpoint", "statusIdent", "summary", "task", "verdict", "wake"])
           or (keys == ["epoch", "evidenceKey", "seq", "silent", "statusEndpoint", "statusIdent", "summary", "task", "taskGeneration", "verdict", "wake"]
             and (.evidenceKey | type == "string" and test("^[a-f0-9]{64}$"))
             and (.taskGeneration | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$")))
           or (keys == ["epoch", "evidenceKey", "seq", "silent", "statusEndpoint", "statusIdent", "summary", "task", "taskDisposition", "taskGeneration", "verdict", "wake"]
             and (.evidenceKey | type == "string" and test("^[a-f0-9]{64}$"))
             and (.taskGeneration | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$"))
             and (.taskDisposition | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$")))
           or (keys == ["epoch", "evidenceKey", "lifecycleRevision", "seq", "silent", "statusEndpoint", "statusIdent", "summary", "task", "taskGeneration", "verdict", "wake"]
             and (.evidenceKey | type == "string" and test("^[a-f0-9]{64}$"))
             and (.taskGeneration | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$"))
             and ((.lifecycleRevision | type) == "number") and .lifecycleRevision >= 1
             and .lifecycleRevision <= 9007199254740991 and .lifecycleRevision == (.lifecycleRevision | floor)))
          and (.silent | type) == "boolean"
          and ((.statusEndpoint | type) == "number" and .statusEndpoint >= 0 and .statusEndpoint <= 9007199254740991 and .statusEndpoint == (.statusEndpoint | floor))
          and ((.statusIdent | type) == "string" and (.statusIdent | test("[\\t\\n]") | not))
        )
      )
      and ((.seq | type) == "number" and .seq >= 1 and .seq <= 9007199254740991 and .seq == (.seq | floor))
      and ((.epoch | type) == "number" and .epoch >= 0 and .epoch == (.epoch | floor))
      and ((.task | type) == "string" and (.wake | type) == "string")
      and ((.summary | type) == "string" and (.verdict == "routine" or .verdict == "captain"))
      and (.silent != true or (.task == "fleet" and .verdict == "routine"));
    if endswith("\n") then split("\n")[:-1]
    else error("unterminated outcome store")
    end
    | map(fromjson)
    | . as $rows
    | if reduce range(0; length) as $i
        (true; . and ($rows[$i] | valid and .seq == ($first + $i)))
      then .[-1].seq
      else error("malformed or non-sequential outcome store")
      end
  ' "$path" 2>/dev/null
}

last_seq() {
  local base
  base=$(read_base) || return 1
  if [ ! -s "$STORE" ] && [ "$base" -ne 1 ]; then
    return 1
  fi
  segment_last_seq "$STORE" "$base"
}

validate_cold_store() {
  local base cold_last
  base=$(read_base) || return 1
  if [ "$base" -eq 1 ]; then
    [ ! -s "$COLD_STORE" ] || return 1
    return 0
  fi
  [ -s "$COLD_STORE" ] || return 1
  cold_last=$(segment_last_seq "$COLD_STORE" 1) || return 1
  [ "$cold_last" -eq "$((base - 1))" ]
}

write_base_prepared() { # <base>
  printf 'fm-branch-outcomes-base-v1\t%s\n' "$1" > "$COMPACTION_BASE"
  chmod 0600 "$COMPACTION_BASE"
}

recover_compaction_locked() {
  local schema old_base new_base old_last cold_hash active_hash base_hash extra
  local current_hash current_base current_last
  if [ ! -e "$COMPACTION_JOURNAL" ]; then
    rm -f -- "$COMPACTION_ACTIVE" "$COMPACTION_COLD" "$COMPACTION_BASE"
    return 0
  fi
  exec 8< "$COMPACTION_JOURNAL" || return 1
  IFS=$(printf '\t') read -r schema old_base new_base old_last cold_hash active_hash base_hash extra <&8 || true
  exec 8<&-
  if [ "$schema" != fm-branch-outcome-compaction-v1 ] || [ -n "$extra" ] \
      || ! bounded_uint "$old_base" || ! bounded_uint "$new_base" \
      || ! bounded_uint "$old_last" \
      || [ "$new_base" -le "$old_base" ] || [ "$new_base" -gt "$old_last" ] \
      || [ "${#cold_hash}" -ne 64 ] || [ "${#active_hash}" -ne 64 ] || [ "${#base_hash}" -ne 64 ]; then
    echo "error: refusing operation because the outcome compaction journal is malformed" >&2
    return 1
  fi
  case "$cold_hash$active_hash$base_hash" in *[!a-f0-9]*)
    echo "error: refusing operation because the outcome compaction journal is malformed" >&2
    return 1
    ;;
  esac

  current_hash=$(sha256_file "$COLD_STORE") || return 1
  if [ "$current_hash" != "$cold_hash" ]; then
    current_base=$(read_base) || return 1
    if [ "$current_base" -ne "$old_base" ] || ! validate_cold_store; then
      echo "error: refusing recovery because current cold outcome evidence does not match the journal base" >&2
      return 1
    fi
    [ -f "$COMPACTION_COLD" ] && [ "$(sha256_file "$COMPACTION_COLD")" = "$cold_hash" ] || {
      echo "error: refusing recovery because prepared cold outcome evidence is missing or changed" >&2
      return 1
    }
    mv -f -- "$COMPACTION_COLD" "$COLD_STORE" || return 1
  fi
  [ "${FM_BRANCH_OUTCOME_TEST_COMPACTION_INTERRUPT:-}" != after-cold ] || return 75

  current_hash=$(sha256_file "$STORE") || return 1
  if [ "$current_hash" != "$active_hash" ]; then
    current_last=$(segment_last_seq "$STORE" "$old_base") || {
      echo "error: refusing recovery because current active outcome evidence does not match the journal base" >&2
      return 1
    }
    [ "$current_last" -eq "$old_last" ] || {
      echo "error: refusing recovery because current active outcome evidence does not match the journal tail" >&2
      return 1
    }
    [ -f "$COMPACTION_ACTIVE" ] && [ "$(sha256_file "$COMPACTION_ACTIVE")" = "$active_hash" ] || {
      echo "error: refusing recovery because prepared active outcome evidence is missing or changed" >&2
      return 1
    }
    mv -f -- "$COMPACTION_ACTIVE" "$STORE" || return 1
  fi
  [ "${FM_BRANCH_OUTCOME_TEST_COMPACTION_INTERRUPT:-}" != after-active ] || return 75

  current_hash=$(sha256_file "$BASE_FILE") || return 1
  if [ "$current_hash" != "$base_hash" ]; then
    current_base=$(read_base) || return 1
    [ "$current_base" -eq "$old_base" ] || {
      echo "error: refusing recovery because the current outcome base does not match the journal" >&2
      return 1
    }
    [ -f "$COMPACTION_BASE" ] && [ "$(sha256_file "$COMPACTION_BASE")" = "$base_hash" ] || {
      echo "error: refusing recovery because prepared outcome base is missing or changed" >&2
      return 1
    }
    mv -f -- "$COMPACTION_BASE" "$BASE_FILE" || return 1
  fi
  [ "${FM_BRANCH_OUTCOME_TEST_COMPACTION_INTERRUPT:-}" != after-base ] || return 75

  rm -f -- "$COMPACTION_ACTIVE" "$COMPACTION_COLD" "$COMPACTION_BASE" "$COMPACTION_JOURNAL"
  [ "$(read_base)" -eq "$new_base" ] || return 1
  [ "$(last_seq)" -eq "$old_last" ] || return 1
  validate_cold_store || return 1
}

compaction_plan_locked() {
  local base last cursor processed archive_through active_rows active_bytes cold_bytes move_rows
  base=$(read_base) || return 1
  last=$(last_seq) || return 1
  cursor=$(read_cursor) || return 1
  processed=$(read_processed) || return 1
  if [ "$cursor" -gt "$last" ] || [ "$processed" -gt "$cursor" ] || [ "$processed" -lt "$((base - 1))" ]; then
    echo "error: refusing compaction because outcome cursors do not match the active base and tail" >&2
    return 1
  fi
  archive_through=$((processed - RETAIN_PROCESSED))
  [ "$archive_through" -ge "$base" ] || archive_through=$((base - 1))
  move_rows=$((archive_through - base + 1))
  active_rows=$((last - base + 1 - move_rows))
  active_bytes=$(file_size "$STORE") || return 1
  cold_bytes=$(file_size "$COLD_STORE") || return 1
  printf '{"base":%s,"tail":%s,"processed":%s,"retain_processed":%s,"archive_through":%s,"move_rows":%s,"active_rows_after":%s,"active_bytes_before":%s,"cold_bytes_before":%s}\n' \
    "$base" "$last" "$processed" "$RETAIN_PROCESSED" "$archive_through" "$move_rows" "$active_rows" "$active_bytes" "$cold_bytes"
}

compact_locked() {
  local plan base last archive_through move_rows new_base journal_tmp
  local cold_hash active_hash base_hash
  plan=$(compaction_plan_locked) || return 1
  base=$(printf '%s\n' "$plan" | jq -r .base)
  last=$(printf '%s\n' "$plan" | jq -r .tail)
  archive_through=$(printf '%s\n' "$plan" | jq -r .archive_through)
  move_rows=$(printf '%s\n' "$plan" | jq -r .move_rows)
  [ "$move_rows" -gt 0 ] || { printf '%s\n' "$plan"; return 0; }
  validate_cold_store || {
    echo "error: refusing compaction because cold outcome evidence is malformed or does not meet the active base" >&2
    return 1
  }
  new_base=$((archive_through + 1))
  # The active segment has already been validated as a gap-free sequence, so
  # row counts identify the exact prefix without parsing or reserializing it.
  # This preserves the immutable original JSONL bytes in cold storage.
  { [ ! -s "$COLD_STORE" ] || cat "$COLD_STORE"; head -n "$move_rows" "$STORE"; } > "$COMPACTION_COLD" || return 1
  tail -n "+$((move_rows + 1))" "$STORE" > "$COMPACTION_ACTIVE" || return 1
  write_base_prepared "$new_base" || return 1
  chmod 0600 "$COMPACTION_COLD" "$COMPACTION_ACTIVE"
  cold_hash=$(sha256_file "$COMPACTION_COLD") || return 1
  active_hash=$(sha256_file "$COMPACTION_ACTIVE") || return 1
  base_hash=$(sha256_file "$COMPACTION_BASE") || return 1
  journal_tmp=$(mktemp "$STATE/.branch-outcomes-compaction.XXXXXX") || return 1
  printf 'fm-branch-outcome-compaction-v1\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$base" "$new_base" "$last" "$cold_hash" "$active_hash" "$base_hash" > "$journal_tmp" || {
      rm -f -- "$journal_tmp"
      return 1
    }
  chmod 0600 "$journal_tmp"
  mv -f -- "$journal_tmp" "$COMPACTION_JOURNAL" || return 1
  recover_compaction_locked || return 1
  printf '%s\n' "$plan"
}

record_seq() { # <jsonl-line>
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" | jq -er '.seq'
}

outcome_index_path() { # <task>
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s/.%s.branch-outcome-index' "$STATE" "$1"
}

capture_status_position() { # <task>
  local f="$STATE/$1.status" size ident size_after ident_after
  CAPTURED_STATUS_ENDPOINT=0
  CAPTURED_STATUS_IDENT=-
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  size=$(_fm_status_file_size "$f") || return 0
  size=${size//[[:space:]]/}
  ident=$(_fm_open_decisions_file_ident "$f") || return 0
  size_after=$(_fm_status_file_size "$f") || return 0
  size_after=${size_after//[[:space:]]/}
  ident_after=$(_fm_open_decisions_file_ident "$f") || return 0
  case "$size:$size_after" in *[!0-9:]*) return 0 ;; esac
  [ "$size" = "$size_after" ] && [ "$ident" = "$ident_after" ] || return 0
  case "$ident" in *$'\t'*|*$'\n'*|'') return 0 ;; esac
  CAPTURED_STATUS_ENDPOINT=$size
  CAPTURED_STATUS_IDENT=$ident
}

write_outcome_index() { # <task> <seq> [<endpoint> <identity>]
  local task=$1 seq=$2 endpoint=${3:-$CAPTURED_STATUS_ENDPOINT} ident=${4:-$CAPTURED_STATUS_IDENT} path tmp record
  path=$(outcome_index_path "$task") || return 1
  record=$(printf '%s\t%s\t%s\t%s\n' "$OUTCOME_INDEX_VERSION" "$seq" \
    "$endpoint" "$ident") || return 1
  [ "${#record}" -le "$OUTCOME_INDEX_MAX_BYTES" ] || return 1
  tmp=$(mktemp "$STATE/.branch-outcome-index.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  printf '%s\n' "$record" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

publish_outcome_index_ready() { # <seq>
  local tmp
  tmp=$(mktemp "$STATE/.branch-outcome-index-ready.XXXXXX") || return 1
  printf '%s\n' "$1" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$OUTCOME_INDEX_READY"
}

rebuild_outcome_indexes() {
  local rows task seq epoch endpoint ident f mtime
  rm -f -- "$OUTCOME_INDEX_READY" || return 1
  validate_cold_store || return 1
  [ -s "$STORE" ] || { publish_outcome_index_ready "$(last_seq)"; return; }
  rows=$({ [ ! -s "$COLD_STORE" ] || cat "$COLD_STORE"; cat "$STORE"; } | jq -r -s '
    map(select(.task != "fleet" and (.task | length > 0 and (test("[^A-Za-z0-9._-]") | not))))
    | group_by(.task)
    | map(.[-1])[]
    | [.task, (.seq | tostring), (.epoch | tostring),
       ((.statusEndpoint // "") | tostring), (.statusIdent // "")]
    | @tsv
  ') || return 1
  while IFS=$(printf '\t') read -r task seq epoch endpoint ident; do
    [ -n "$task" ] || continue
    if [ -z "$endpoint" ] || [ -z "$ident" ]; then
      f="$STATE/$task.status"
      endpoint=0
      ident=-
      if [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ]; then
        mtime=$(_fm_status_file_mtime "$f") || mtime=
        case "$mtime" in ''|*[!0-9]*) ;;
          *)
            # Legacy rows have only whole-second epochs, so equal timestamps
            # cannot prove whether the status preceded the outcome. Leave that
            # span uncovered: migration may rarely duplicate an old handled
            # event, but it will not hide a plausibly later captain-facing one.
            if [ "$mtime" -lt "$epoch" ]; then
              capture_status_position "$task"
              endpoint=$CAPTURED_STATUS_ENDPOINT
              ident=$CAPTURED_STATUS_IDENT
            fi
            ;;
        esac
      fi
    fi
    write_outcome_index "$task" "$seq" "$endpoint" "$ident" || return 1
  done <<EOF
$rows
EOF
  publish_outcome_index_ready "$(last_seq)"
}

print_unread() {
  local cursor last base
  cursor=$(read_cursor)
  base=$(read_base) || return 1
  if ! last=$(last_seq); then
    echo "error: refusing read because the outcome store is malformed or non-sequential" >&2
    return 1
  fi
  if [ "$cursor" -gt "$last" ]; then
    echo "error: refusing read because the outcome cursor is ahead of the store" >&2
    return 1
  fi
  if [ "$cursor" -lt "$((base - 1))" ]; then
    echo "error: refusing read because the outcome cursor is behind the archived prefix" >&2
    return 1
  fi
  [ -s "$STORE" ] || return 0
  jq -c --argjson cursor "$cursor" 'select(.seq > $cursor)' "$STORE"
}

advance_cursor() { # <seq>
  local through=$1 cursor processed tmp
  cursor=$(read_cursor) || return 1
  processed=$(read_processed) || return 1
  if [ "$processed" -gt "$cursor" ]; then
    echo "error: refusing cursor advancement because the processed marker is ahead of the read cursor" >&2
    return 1
  fi
  [ "$through" -gt "$cursor" ] || return 0
  tmp=$(mktemp "$STATE/.branch-outcomes-cursor.XXXXXX")
  printf '%s\n' "$through" > "$tmp"
  mv -f -- "$tmp" "$CURSOR"
}

write_processed() { # <seq>
  local through=$1 tmp
  tmp=$(mktemp "$STATE/.branch-outcomes-processed.XXXXXX")
  printf '%s\n' "$through" > "$tmp"
  mv -f -- "$tmp" "$PROCESSED"
}

# Captain rows above the processed marker and at or below the read cursor.
print_unprocessed() {
  local cursor processed last base
  cursor=$(read_cursor) || return 1
  processed=$(read_processed) || return 1
  base=$(read_base) || return 1
  if ! last=$(last_seq); then
    echo "error: refusing read because the outcome store is malformed or non-sequential" >&2
    return 1
  fi
  if [ "$cursor" -gt "$last" ]; then
    echo "error: refusing read because the outcome cursor is ahead of the store" >&2
    return 1
  fi
  if [ "$processed" -gt "$cursor" ]; then
    echo "error: refusing read because the processed marker is ahead of the read cursor" >&2
    return 1
  fi
  if [ "$processed" -lt "$((base - 1))" ]; then
    echo "error: refusing read because the processed marker is behind the archived prefix" >&2
    return 1
  fi
  [ -s "$STORE" ] || return 0
  jq -c --argjson processed "$processed" --argjson cursor "$cursor" \
    'select(.verdict == "captain" and .seq > $processed and .seq <= $cursor)' "$STORE"
}

# Assumes $LOCK is already held. Callers that do not already hold it use the
# processed-init command, which acquires and releases around this body.
processed_init_locked() {
  local store_last cursor_seq processed_seq base_seq ready_seq
  if ! store_last=$(last_seq); then
    echo "error: refusing processed initialization because the outcome store is malformed or non-sequential" >&2
    return 1
  fi
  if ! cursor_seq=$(read_cursor); then
    return 1
  fi
  if [ "$cursor_seq" -gt "$store_last" ]; then
    echo "error: refusing processed initialization because the outcome cursor is ahead of the store" >&2
    return 1
  fi
  base_seq=$(read_base) || return 1
  if [ "$cursor_seq" -lt "$((base_seq - 1))" ]; then
    echo "error: refusing processed initialization because the outcome cursor is behind the archived prefix" >&2
    return 1
  fi
  if [ -e "$PROCESSED" ]; then
    if ! processed_seq=$(read_processed); then
      return 1
    fi
    if [ "$processed_seq" -gt "$cursor_seq" ]; then
      echo "error: refusing processed initialization because the processed marker is ahead of the read cursor" >&2
      return 1
    fi
  else
    if [ "$base_seq" -gt 1 ]; then
      echo "error: refusing processed initialization because a compacted store has no processed marker" >&2
      return 1
    fi
    write_processed "$cursor_seq" || return 1
  fi
  ready_seq=$(cat "$OUTCOME_INDEX_READY" 2>/dev/null || true)
  if [ "$ready_seq" = "$store_last" ]; then
    return 0
  fi
  if ! rebuild_outcome_indexes; then
    echo "error: outcome index migration could not be completed safely" >&2
    return 1
  fi
}

held_lock_owned_by_ancestor() {
  local owner owner_pid pid parent depth=0
  case "$PPID" in ''|*[!0-9]*|0|1) return 1 ;; esac
  if [ -L "$LOCK" ]; then
    owner=$(fm_lock_link_owner "$LOCK" 2>/dev/null) || return 1
    fm_lock_points_to_owner "$LOCK" "$owner" || return 1
  elif [ -d "$LOCK" ]; then
    owner=$LOCK
  else
    return 1
  fi
  owner_pid=$(cat "$owner/pid" 2>/dev/null) || return 1
  fm_pid_alive "$owner_pid" || return 1

  # Bash 3.2 keeps $$ unchanged in a redirected subshell while that subshell's
  # real pid becomes this script's parent. Walk the bounded live ancestry so
  # that legitimate drain shape is accepted without trusting an arbitrary
  # caller merely because it can name or observe the lock owner.
  pid=$PPID
  while [ "$depth" -lt 64 ]; do
    [ "$pid" = "$owner_pid" ] && return 0
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null) || return 1
    parent=${parent//[[:space:]]/}
    case "$parent" in ''|*[!0-9]*|0|1) return 1 ;; esac
    [ "$parent" != "$pid" ] || return 1
    pid=$parent
    depth=$((depth + 1))
  done
  return 1
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  append)
    TASK=''
    VERDICT=''
    SUMMARY=''
    WAKE=''
    SILENT=false
    ONCE_TASK=false
    MATERIAL_KEY=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --once-task) ONCE_TASK=true; shift ;;
        --task) TASK=${2:-}; shift 2 || usage ;;
        --verdict) VERDICT=${2:-}; shift 2 || usage ;;
        --summary) SUMMARY=${2:-}; shift 2 || usage ;;
        --wake) WAKE=${2:-}; shift 2 || usage ;;
        --silent) SILENT=${2:-}; shift 2 || usage ;;
        --material-key) MATERIAL_KEY=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$TASK" ] || usage
    outcome_index_path "$TASK" >/dev/null || usage
    [ -n "$SUMMARY" ] || usage
    case "$MATERIAL_KEY" in *$'\n'*|*$'\r'*) echo "error: material key must be one line" >&2; exit 2 ;; esac
    case "$VERDICT" in routine|captain) ;; *) usage ;; esac
    case "$SILENT" in true|false) ;; *) usage ;; esac
    if [ "$SILENT" = true ] && { [ "$TASK" != fleet ] || [ "$VERDICT" != routine ]; }; then
      echo "error: silent outcomes must be routine fleet outcomes" >&2
      exit 2
    fi
    fm_lock_acquire_wait "$LOCK"
    if ! recover_compaction_locked; then
      fm_lock_release "$LOCK"
      echo "error: refusing append because outcome compaction recovery failed" >&2
      exit 1
    fi
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    BASE_SEQ=$(read_base) || { fm_lock_release "$LOCK"; exit 1; }
    if ! CURSOR_SEQ=$(read_cursor) || [ "$CURSOR_SEQ" -gt "$LAST_SEQ" ] \
        || [ "$CURSOR_SEQ" -lt "$((BASE_SEQ - 1))" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the outcome cursor is invalid or ahead of the store" >&2
      exit 1
    fi
    if [ "$ONCE_TASK" = true ] && { [ -s "$STORE" ] || [ -s "$COLD_STORE" ]; }; then
      if ! validate_cold_store; then
        fm_lock_release "$LOCK"
        echo "error: refusing once-task append because cold outcome evidence is malformed" >&2
        exit 1
      fi
      EXISTING=$({ [ ! -s "$COLD_STORE" ] || cat "$COLD_STORE"; [ ! -s "$STORE" ] || cat "$STORE"; } \
        | jq -c --arg task "$TASK" 'select(.task == $task)')
      if [ -n "$EXISTING" ]; then
        if ! SEQ=$(printf '%s\n' "$EXISTING" | jq -ser --arg summary "$SUMMARY" --arg verdict "$VERDICT" --arg wake "$WAKE" --argjson silent "$SILENT" '
          if length == 1 and .[0].summary == $summary and .[0].verdict == $verdict and .[0].wake == $wake and .[0].silent == $silent
          then .[0].seq else error("conflicting terminal task outcome") end'); then
          fm_lock_release "$LOCK"
          echo "error: conflicting once-task outcome" >&2
          exit 1
        fi
        fm_lock_release "$LOCK"
        printf '%s\n' "$SEQ"
        exit 0
      fi
    fi
    SEQ=$(( LAST_SEQ + 1 ))
    capture_status_position "$TASK"
    TASK_GENERATION=$(awk -F= '$1 == "spawn_gen" { count++; value=substr($0, 11) }
      END { if (count == 1 && value ~ /^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$/) print value; else exit 1 }' \
      "$STATE/$TASK.meta" 2>/dev/null) || TASK_GENERATION=''
    TASK_DISPOSITION=$(jq -er '.state | select(type == "string" and length > 0)' "$DATA_ROOT/$TASK/task.json" 2>/dev/null || printf 'unknown\n')
    case "$TASK_DISPOSITION" in *[!A-Za-z0-9._-]*) TASK_DISPOSITION=unknown ;; esac
    rm -f -- "$OUTCOME_INDEX_READY" || { fm_lock_release "$LOCK"; exit 1; }
    if [ -n "$TASK_GENERATION" ] && { [ -n "$MATERIAL_KEY" ] || { [ "$CAPTURED_STATUS_ENDPOINT" -ge 0 ] && [ -n "$CAPTURED_STATUS_IDENT" ]; }; }; then
      if [ -n "$MATERIAL_KEY" ]; then
        EVIDENCE_KEY=$(sha256_text "$TASK|$TASK_GENERATION|material|$MATERIAL_KEY") \
          || { fm_lock_release "$LOCK"; exit 1; }
      else
        EVIDENCE_KEY=$(sha256_text "$TASK|$TASK_GENERATION|status|$CAPTURED_STATUS_ENDPOINT|$CAPTURED_STATUS_IDENT") \
          || { fm_lock_release "$LOCK"; exit 1; }
      fi
      printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s","silent":%s,"statusEndpoint":%s,"statusIdent":"%s","taskGeneration":"%s","taskDisposition":"%s","evidenceKey":"%s"}\n' \
        "$SEQ" "$(date +%s)" "$(json_escape "$TASK")" "$(json_escape "$WAKE")" \
        "$VERDICT" "$(json_escape "$SUMMARY")" "$SILENT" "$CAPTURED_STATUS_ENDPOINT" \
        "$(json_escape "$CAPTURED_STATUS_IDENT")" "$(json_escape "$TASK_GENERATION")" \
        "$(json_escape "$TASK_DISPOSITION")" "$EVIDENCE_KEY" >> "$STORE"
    else
      # Unknown generation or material identity remains append-only and
      # visible, but is deliberately ineligible for identity coalescing.
      printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s","silent":%s,"statusEndpoint":%s,"statusIdent":"%s"}\n' \
        "$SEQ" "$(date +%s)" "$(json_escape "$TASK")" "$(json_escape "$WAKE")" \
        "$VERDICT" "$(json_escape "$SUMMARY")" "$SILENT" "$CAPTURED_STATUS_ENDPOINT" \
        "$(json_escape "$CAPTURED_STATUS_IDENT")" >> "$STORE"
    fi
    # A task with neither a live meta nor a status log is retired: the branch
    # reports the teardown it just performed, and writing the index here would
    # recreate the footprint teardown removed. The outcome itself is still
    # stored and delivered; only the reader-less cache is skipped.
    if { [ -e "$STATE/$TASK.meta" ] || [ -e "$STATE/$TASK.status" ]; } \
        && ! write_outcome_index "$TASK" "$SEQ"; then
      fm_lock_release "$LOCK"
      echo "error: outcome was stored but its bounded task index could not be updated" >&2
      exit 1
    fi
    if ! publish_outcome_index_ready "$SEQ"; then
      fm_lock_release "$LOCK"
      echo "error: outcome was stored but its bounded task index could not be updated" >&2
      exit 1
    fi
    fm_lock_release "$LOCK"
    printf '%s\n' "$SEQ"
    ;;
  unread)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! recover_compaction_locked; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    print_unread
    fm_lock_release "$LOCK"
    ;;
  mark-read)
    [ "${1:-}" = --through ] || usage
    THROUGH=${2:-}
    bounded_uint "$THROUGH" || usage
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! recover_compaction_locked; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing cursor advancement because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if ! CURSOR_SEQ=$(read_cursor); then
      fm_lock_release "$LOCK"
      exit 1
    fi
    BASE_SEQ=$(read_base) || { fm_lock_release "$LOCK"; exit 1; }
    if [ "$CURSOR_SEQ" -gt "$LAST_SEQ" ] || [ "$CURSOR_SEQ" -lt "$((BASE_SEQ - 1))" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing cursor advancement because the outcome cursor is ahead of the store" >&2
      exit 1
    fi
    if [ "$THROUGH" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing cursor advancement beyond a valid stored outcome" >&2
      exit 1
    fi
    if ! advance_cursor "$THROUGH"; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    fm_lock_release "$LOCK"
    ;;
  unprocessed)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! recover_compaction_locked; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    print_unprocessed
    STATUS=$?
    fm_lock_release "$LOCK"
    exit "$STATUS"
    ;;
  mark-processed)
    [ "${1:-}" = --through ] || usage
    THROUGH=${2:-}
    bounded_uint "$THROUGH" || usage
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! recover_compaction_locked; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    if ! CURSOR_SEQ=$(read_cursor) || ! PROCESSED_SEQ=$(read_processed); then
      fm_lock_release "$LOCK"
      exit 1
    fi
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if [ "$CURSOR_SEQ" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because the outcome cursor is ahead of the store" >&2
      exit 1
    fi
    BASE_SEQ=$(read_base) || { fm_lock_release "$LOCK"; exit 1; }
    if [ "$PROCESSED_SEQ" -gt "$CURSOR_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because the processed marker is ahead of the read cursor" >&2
      exit 1
    fi
    if [ "$PROCESSED_SEQ" -lt "$((BASE_SEQ - 1))" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because the processed marker is behind the archived prefix" >&2
      exit 1
    fi
    if [ "$THROUGH" -gt "$CURSOR_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement beyond the read cursor ($CURSOR_SEQ)" >&2
      exit 1
    fi
    if [ "$THROUGH" -le "$PROCESSED_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because seq $THROUGH is already processed" >&2
      exit 1
    fi
    VERDICT=$(jq -r --argjson through "$THROUGH" 'select(.seq == $through) | .verdict' "$STORE")
    if [ "$VERDICT" != captain ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because seq $THROUGH is not an unprocessed captain outcome" >&2
      exit 1
    fi
    write_processed "$THROUGH"
    if ! compact_locked >/dev/null; then
      fm_lock_release "$LOCK"
      echo "error: processed marker advanced but outcome compaction did not complete; preserve active evidence and retry compact --apply after resolving the reported store fault" >&2
      exit 1
    fi
    fm_lock_release "$LOCK"
    ;;
  processed-init)
    HELD_LOCK=0
    if [ "${1:-}" = --held-lock ]; then
      HELD_LOCK=1
      shift
    fi
    [ "$#" -eq 0 ] || usage
    if [ "$HELD_LOCK" -eq 0 ]; then
      fm_lock_acquire_wait "$LOCK"
    elif ! held_lock_owned_by_ancestor; then
      echo "error: --held-lock requires an ancestor process to own the outcome lock" >&2
      exit 1
    fi
    if ! recover_compaction_locked; then
      if [ "$HELD_LOCK" -eq 0 ]; then
        fm_lock_release "$LOCK"
      fi
      exit 1
    fi
    if ! processed_init_locked; then
      if [ "$HELD_LOCK" -eq 0 ]; then
        fm_lock_release "$LOCK"
      fi
      exit 1
    fi
    if [ "$HELD_LOCK" -eq 0 ]; then
      fm_lock_release "$LOCK"
    fi
    ;;
  list)
    RECENT=20
    ALL=false
    EXACT=''
    if [ "${1:-}" = --recent ]; then
      RECENT=${2:-}
      case "$RECENT" in ''|*[!0-9]*|0) usage ;; esac
      shift 2 || usage
    elif [ "${1:-}" = --all ]; then
      ALL=true
      shift
    elif [ "${1:-}" = --seq ]; then
      EXACT=${2:-}
      bounded_uint "$EXACT" || usage
      shift 2 || usage
    fi
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! recover_compaction_locked; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    if ! last_seq >/dev/null; then
      fm_lock_release "$LOCK"
      echo "error: refusing read because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if [ "$ALL" = true ] || [ -n "$EXACT" ]; then
      if ! validate_cold_store; then
        fm_lock_release "$LOCK"
        echo "error: refusing historical read because cold outcome evidence is malformed" >&2
        exit 1
      fi
    fi
    if [ "$ALL" = true ]; then
      [ ! -s "$COLD_STORE" ] || cat "$COLD_STORE"
      [ ! -s "$STORE" ] || cat "$STORE"
    elif [ -n "$EXACT" ]; then
      BASE_SEQ=$(read_base) || { fm_lock_release "$LOCK"; exit 1; }
      if [ "$EXACT" -lt "$BASE_SEQ" ]; then
        FOUND=$(jq -c --argjson seq "$EXACT" 'select(.seq == $seq)' "$COLD_STORE")
      else
        FOUND=$(jq -c --argjson seq "$EXACT" 'select(.seq == $seq)' "$STORE")
      fi
      if [ -z "$FOUND" ]; then
        fm_lock_release "$LOCK"
        echo "error: exact outcome sequence $EXACT does not exist" >&2
        exit 1
      fi
      printf '%s\n' "$FOUND"
    elif [ -s "$STORE" ]; then
      tail -n "$RECENT" "$STORE"
    fi
    fm_lock_release "$LOCK"
    ;;
  compact)
    MODE=${1:-}
    case "$MODE" in --dry-run|--apply) ;; *) usage ;; esac
    [ "$#" -eq 1 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! recover_compaction_locked; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    if [ "$MODE" = --dry-run ]; then
      compaction_plan_locked
      STATUS=$?
    else
      compact_locked
      STATUS=$?
    fi
    fm_lock_release "$LOCK"
    exit "$STATUS"
    ;;
  startup-replay)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! recover_compaction_locked; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    UNREAD=$(print_unread)
    if [ -n "$UNREAD" ]; then
      REPLAYABLE=$(printf '%s\n' "$UNREAD" | jq -sc '
        map(.verdict) as $verdicts
        | ($verdicts | index("captain")) as $captain
        | .[0:($captain // length)][]
      ')
      VISIBLE=$(printf '%s\n' "$REPLAYABLE" | jq -c 'select(.silent != true)')
      if [ -n "$VISIBLE" ]; then
        printf 'BRANCH OUTCOMES (handled by the supervision branch, not yet seen by this session):\n'
        printf '%s\n' "$VISIBLE"
      fi
      LAST=$(record_seq "$(printf '%s\n' "$REPLAYABLE" | tail -n 1)")
      if [ -n "$LAST" ] && ! advance_cursor "$LAST"; then
        fm_lock_release "$LOCK"
        exit 1
      fi
    fi
    fm_lock_release "$LOCK"
    ;;
  *) usage ;;
esac
