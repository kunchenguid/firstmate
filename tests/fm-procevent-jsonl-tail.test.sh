#!/usr/bin/env bash
# Behavior tests for the JSONL-tail process-event adapter.
#
# The subject is the blocking child's cursor discipline, exercised only
# through the public `wait` command: emit exactly the complete lines past the
# durable cursor, never a partial trailing line a writer is mid-appending,
# advance durably so a restarted child does not re-emit, and re-read from the
# start when the file shrinks. Every case uses files where lines are already
# pending, so `wait` returns immediately and nothing here ever blocks.
#
# Nothing here registers a source or starts the generic runner; the runner's
# own capture and re-announcement guarantees are tests/fm-procevent.test.sh's
# subject, not this adapter's.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-procevent-jsonl-tail-tests)
trap fm_test_cleanup EXIT

ADAPTER="$ROOT/bin/fm-procevent-jsonl-tail.sh"
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/state"
EVENTS="$TMP_ROOT/events.jsonl"

# --- source-id is stable and path-derived -----------------------------------
id1=$("$ADAPTER" source-id "$EVENTS") || fail "source-id failed for a not-yet-existing file"
id2=$("$ADAPTER" source-id "$TMP_ROOT/../$(basename "$TMP_ROOT")/events.jsonl") || fail "source-id failed on an indirect path"
[ "$id1" = "$id2" ] || fail "source-id differs across spellings of one path: $id1 vs $id2"
case "$id1" in jsonl-tail-*) : ;; *) fail "source-id lacks the adapter prefix: $id1" ;; esac
pass "source-id is stable across path spellings"

# --- wait emits pending complete lines and advances the cursor --------------
printf '{"n":1}\n{"n":2}\n' > "$EVENTS"
out=$("$ADAPTER" wait "$EVENTS") || fail "wait failed with pending lines"
[ "$out" = '{"n":1}
{"n":2}' ] || fail "wait did not emit exactly the pending lines: $out"
pass "wait emits pending complete lines"

printf '{"n":3}\n' >> "$EVENTS"
out=$("$ADAPTER" wait "$EVENTS") || fail "wait failed on appended line"
[ "$out" = '{"n":3}' ] || fail "wait re-emitted already-consumed lines: $out"
pass "cursor advance survives across separate wait runs"

# --- a partial trailing line is never emitted --------------------------------
printf '{"n":4}\n{"part' >> "$EVENTS"
out=$("$ADAPTER" wait "$EVENTS") || fail "wait failed with a partial trailing line present"
[ "$out" = '{"n":4}' ] || fail "wait emitted a partial line: $out"
printf 'ial":5}\n' >> "$EVENTS"
out=$("$ADAPTER" wait "$EVENTS") || fail "wait failed after the partial line completed"
[ "$out" = '{"partial":5}' ] || fail "completed line not emitted whole: $out"
pass "partial trailing lines wait for their newline"

# --- a shrunken file resets the cursor and is re-read from the start ---------
printf '{"fresh":1}\n' > "$EVENTS"
out=$("$ADAPTER" wait "$EVENTS") || fail "wait failed after truncation"
[ "$out" = '{"fresh":1}' ] || fail "truncated file was not re-read from the start: $out"
pass "a shrunken file resets the cursor"

# --- terminal never ends the source ------------------------------------------
if "$ADAPTER" terminal "$TMP_ROOT/any-result"; then
  fail "terminal exited 0; a growing file must never read as ended"
fi
pass "terminal keeps the source armed"
