#!/usr/bin/env bash
# The real note producer and native admission must share one publication boundary.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
cleanup() {
  local child
  touch "$TMP/release"
  while IFS= read -r child; do kill "$child" 2>/dev/null || true; done < <(jobs -pr)
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
export MSYS=winsymlinks:nativestrict
# admit.sh's only Windows-specific shell operation is path conversion.
# On POSIX, preserve the already-canonical absolute test path.
if ! command -v cygpath >/dev/null 2>&1; then
  cygpath() { [ "$1" = -u ] && printf '%s\n' "$2"; }
  export -f cygpath
fi
wait_file() {
  local file=$1 i
  for ((i=0;i<400;i++)); do [ ! -f "$file" ] || return 0; sleep .02; done
  fail "publication did not reach $file"
}
admit() { FM_HOME="$1" bash "$ROOT/bin/native-owner/admit.sh" owned-operation </dev/null; }
capture_result() {
  local home=$1 id=$2 payload
  payload="$TMP/$id.payload"
  printf 'captured %s\n' "$id" > "$payload"
  bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-procevent-lib.sh"
    fm_procevent_capture "$2/state" "$3" lavish "$4"
  ' _ "$ROOT" "$home" "$id" "$payload"
}
handle_result() {
  bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-procevent-lib.sh"
    fm_procevent_mark_handled "$2/state" "$3" 1
  ' _ "$ROOT" "$1" "$2"
}
assert_refused_unchanged() {
  local home=$1 label=$2 before="$1-before"
  cp -R "$home" "$before"
  if admit "$home" >"$TMP/$label.out" 2>&1; then fail "admitted $label"; fi
  diff -r "$home" "$before" || fail "changed refused $label records"
}
assert_accepted_unchanged() {
  local home=$1 label=$2 before="$1-before"
  cp -R "$home" "$before"
  admit "$home" >"$TMP/$label.out" 2>&1 || fail "refused $label: $(<"$TMP/$label.out")"
  diff -r "$home" "$before" || fail "changed accepted $label records"
}

empty_result_home="$TMP/empty-result-home"
mkdir -p "$empty_result_home/state"
assert_accepted_unchanged "$empty_result_home" empty-result-home
pass 'admits a home with no process-event result state'

for source_shape in absent empty; do
  result_home="$TMP/unhandled-$source_shape-source"
  capture_result "$result_home" "pending-$source_shape" >/dev/null
  [ "$source_shape" != empty ] || mkdir -p "$result_home/state/procevent"
  assert_refused_unchanged "$result_home" "unhandled-$source_shape-source"
  pass "refuses an unhandled result with an $source_shape source directory without changing it"
done

queued_result_home="$TMP/queued-result"
FM_HOME="$queued_result_home" bash "$ROOT/bin/fm-inbox.sh" note 'Supported notification beside a captured result' >/dev/null
admit "$queued_result_home" >/dev/null || fail 'supported notification control was not admissible'
capture_result "$queued_result_home" queued-result >/dev/null
assert_refused_unchanged "$queued_result_home" queued-result
pass 'refuses an unhandled result even beside an otherwise supported queued notification'

handled_result_home="$TMP/handled-result"
handled_result=$(capture_result "$handled_result_home" handled-result)
handle_result "$handled_result_home" handled-result
assert_accepted_unchanged "$handled_result_home" handled-result
[ -f "${handled_result%.result}.handled" ] || fail 'handled-history control lost its acknowledgement'
pass 'admits canonical handled process-event history without changing it'

malformed_result_home="$TMP/malformed-result"
mkdir -p "$malformed_result_home/state/procevent-inbox"
printf 'ambiguous\n' > "$malformed_result_home/state/procevent-inbox/missing-sequence.result"
printf 'lavish\n' > "$malformed_result_home/state/procevent-inbox/missing-sequence.adapter"
assert_refused_unchanged "$malformed_result_home" malformed-result

hidden_result_home="$TMP/hidden-result"
mkdir -p "$hidden_result_home/state/procevent-inbox"
printf 'preserve hidden result\n' > "$hidden_result_home/state/procevent-inbox/.lost.1.result"
assert_refused_unchanged "$hidden_result_home" hidden-result

ambiguous_ack_home="$TMP/ambiguous-ack"
ambiguous_result=$(capture_result "$ambiguous_ack_home" ambiguous-ack)
mkdir "${ambiguous_result%.result}.handled"
assert_refused_unchanged "$ambiguous_ack_home" ambiguous-ack
pass 'refuses malformed results and ambiguous acknowledgement state without changing them'

# Pause an actual producer at its external rename, without production test hooks.
paused_note() {
  bash "$ROOT/tests/fixtures/native-owner/pause-inbox-publication.sh" \
    "$ROOT" "$1" "$TMP" 'Preserve this real producer notification' "${2:-before}"
}
home="$TMP/coherent"
paused_note "$home" >"$TMP/producer.out" 2>"$TMP/producer.err" & producer=$!
wait_file "$TMP/paused"
admit "$home" >"$TMP/reader.out" 2>"$TMP/reader.err" & reader=$!
sleep 1
kill -0 "$reader" 2>/dev/null || fail 'admission returned while publication was incomplete'
touch "$TMP/release"
wait "$producer" || fail "producer failed: $(<"$TMP/producer.err")"
wait "$reader" || fail "reader failed: $(<"$TMP/reader.err")"
admit "$home" || fail 'reader leaked its queue lock'
pass 'admission waits for actual staging/publication and releases its lock'

for kind in malformed orphan staging; do
  target="$TMP/$kind"; cp -R "$home" "$target"
  case "$kind" in
    malformed) printf 'malformed\n' > "$target/state/.wake-queue" ;;
    orphan) printf 'saved but unannounced\n' > "$target/state/inbox/orphan.note" ;;
    staging) printf 'unfinished\n' > "$target/state/inbox/.staging-orphan" ;;
  esac
  cp -R "$target" "$TMP/$kind-before"
  if admit "$target" >"$TMP/$kind.out" 2>&1; then fail "admitted $kind records"; fi
  diff -r "$target" "$TMP/$kind-before" || fail "changed refused $kind records"
  pass "refuses $kind records without changing them"
done

# A producer interrupted after rename must release its lock but retain its note.
rm "$TMP/paused" "$TMP/release" "$TMP/producer-pid"
interrupted="$TMP/interrupted"
paused_note "$interrupted" after >"$TMP/interrupted.out" 2>"$TMP/interrupted.err" & producer=$!
wait_file "$TMP/paused"
kill -TERM "$(<"$TMP/producer-pid")"
if wait "$producer"; then fail 'interrupted producer reported success'; fi
notes=("$interrupted"/state/inbox/*.note)
[ -f "${notes[0]}" ] || fail 'interrupted producer lost its saved note'
[ ! -e "$interrupted/state/.wake-queue.lock" ] || fail 'interrupted producer leaked queue lock'
if admit "$interrupted" >"$TMP/interrupted-reader.out" 2>&1; then fail 'admitted interrupted incomplete publication'; fi
[ -f "${notes[0]}" ] || fail 'reader removed interrupted note'
pass 'interrupted producer preserves its note, releases lock, and remains inadmissible'

# An unwritable sequence-counter path forces the real append to fail after saving.
failed="$TMP/append-failed"; mkdir -p "$failed/state/.wake-queue.seq"
if FM_HOME="$failed" bash "$ROOT/bin/fm-inbox.sh" note 'Keep me after append failure' >"$TMP/failed.out" 2>&1; then fail 'append failure reported success'; fi
notes=("$failed"/state/inbox/*.note)
[ -f "${notes[0]}" ] || fail 'append failure lost its saved note'
grep -q 'NOT woken' "$TMP/failed.out" || fail 'append failure was not reported'
[ ! -e "$failed/state/.wake-queue.lock" ] || fail 'append failure leaked queue lock'
if admit "$failed" >"$TMP/failed-reader.out" 2>&1; then fail 'admitted failed publication'; fi
pass 'failed append preserves the saved note and releases the lock'

# A reader timeout must not release another live writer's lock or erase staging.
rm -f "$TMP/paused" "$TMP/release" "$TMP/producer-pid"
timeout_home="$TMP/timeout"
paused_note "$timeout_home" >"$TMP/timeout-producer.out" 2>"$TMP/timeout-producer.err" & producer=$!
wait_file "$TMP/paused"
if admit "$timeout_home" >"$TMP/timeout-reader.out" 2>&1; then fail 'contended admission unexpectedly succeeded'; fi
grep -q 'within its bound' "$TMP/timeout-reader.out" || fail 'reader did not report lock timeout'
kill -0 "$producer" || fail 'reader killed producer'
[ -e "$timeout_home/state/.wake-queue.lock" ] || fail 'reader removed producer lock'
touch "$TMP/release"
wait "$producer" || fail "producer could not finish after reader timeout: $(<"$TMP/timeout-producer.err")"
admit "$timeout_home" || fail 'completed publication refused after timeout'
pass 'bounded reader timeout preserves live producer ownership and later publication'
