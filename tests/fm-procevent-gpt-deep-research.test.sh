#!/usr/bin/env bash
# Behavior tests for the GPT Deep Research process-event adapter.
#
# These exercise the public adapter and generic runner against isolated watch
# records. No fixture starts a browser, calls the standalone watcher, or reads
# a report body. The cases cover the live failure shape: a completed verified
# archive, watches that remain active, and terminal BLOCKED watches must each
# be independently visible to Firstmate without exposing prompts or browser
# secrets.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-gpt-deep-research-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

SKILL="$TMP_ROOT/gpt-deep-research-skill"
mkdir -p "$SKILL/scripts"
cat > "$SKILL/scripts/state_paths.py" <<'PY'
from pathlib import Path
import os

def resolve_watches_dir():
    return Path(os.environ["TEST_GDR_WATCHES"])
PY

pe() {
  FM_HOME="$1" GPT_DEEP_RESEARCH_SKILL_DIR="$SKILL" "$ROOT/bin/fm-procevent.sh" "${@:2}"
}
gdr() {
  FM_HOME="$1" GPT_DEEP_RESEARCH_SKILL_DIR="$SKILL" "$ROOT/bin/fm-procevent-gpt-deep-research.sh" "${@:2}"
}

GDR_HOMES=()
cleanup() {
  local home
  for home in ${GDR_HOMES[@]+"${GDR_HOMES[@]}"}; do
    FM_HOME="$home" GPT_DEEP_RESEARCH_SKILL_DIR="$SKILL" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup EXIT

new_home() {
  mkdir -p "$1/state"
  GDR_HOMES+=("$1")
}

source_id() {
  TEST_GDR_WATCHES="$1" gdr "$2" source-id "$3"
}

first_result() {  # <home> <source-id>
  local result
  for result in "$1/state/procevent-inbox/$2".*.result; do
    [ -f "$result" ] || continue
    printf '%s\n' "$result"
    return 0
  done
  return 1
}

result_count() {  # <home> <source-id>
  local result count=0
  for result in "$1/state/procevent-inbox/$2".*.result; do
    [ -f "$result" ] && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

wait_for() {  # <path> [tries]
  local path=$1 tries=${2:-120}
  for _ in $(seq 1 "$tries"); do
    [ -e "$path" ] && return 0
    sleep 0.1
  done
  return 1
}

wait_for_result() {  # <home> <source-id> [tries]
  local home=$1 id=$2 tries=${3:-120}
  for _ in $(seq 1 "$tries"); do
    first_result "$home" "$id" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

wait_for_absent() {  # <path> [tries]
  local path=$1 tries=${2:-120}
  for _ in $(seq 1 "$tries"); do
    [ ! -e "$path" ] && return 0
    sleep 0.1
  done
  return 1
}

write_watch() {  # <watches-dir> <watch-id> <status> <archive> <url> <error> <slug>
  mkdir -p "$1"
  python3 - "$@" <<'PY'
import json
import sys
from pathlib import Path

watch_dir, watch_id, status, archive, url, error, slug = sys.argv[1:]
payload = {
    "schema": "gpt_deep_research_report_watch.v1",
    "watch_id": watch_id,
    "session": "gpt-deep-research-profile",
    "page_id": 42,
    "expected_url": url,
    "status": status,
    "archive_path": archive or None,
    "last_error": error or None,
    "slug": slug,
}
Path(watch_dir, f"{watch_id}.json").write_text(json.dumps(payload), encoding="utf-8")
PY
}

write_archive() {  # <path>
  mkdir -p "$(dirname "$1")"
  printf '%s\n' '# Verified Deep Research archive' > "$1"
  printf '%0.sx' $(seq 1 512) >> "$1"
  printf '\n' >> "$1"
}

wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }
assert_not_grep() { grep -q -- "$1" "$2" && fail "$3"; }

# --- an exact existing record is required and receives a canonical identity --
H="$TMP_ROOT/h-validate"; new_home "$H"
WD="$TMP_ROOT/watches-validate"
mkdir -p "$WD"
missing_status=0
missing_out=$(TEST_GDR_WATCHES="$WD" gdr "$H" arm missing --interval-seconds 1 2>&1) || missing_status=$?
[ "$missing_status" -ne 0 ] || fail "arm accepted a missing watch record"
assert_contains "$missing_out" "watch record does not exist" "missing watch refusal identifies the binding failure"
write_watch "$WD" watch-validate WATCHING "" "https://chatgpt.com/c/validate" "" "private topic"
sid=$(source_id "$WD" "$H" watch-validate)
assert_contains "$sid" gpt-dr- "source identity is bounded and adapter-specific"
TEST_GDR_WATCHES="$WD" gdr "$H" arm watch-validate --interval-seconds 1 >/dev/null
assert_present "$H/state/gpt-deep-research/$sid.binding" "arm writes a private exact-watch binding"
assert_present "$H/state/procevent/$sid.source" "arm registers the exact watch source"
assert_not_grep 'private topic' "$H/state/gpt-deep-research/$sid.binding" "binding excludes the research slug"
pe "$H" retire "$sid" >/dev/null
rm -f "$H/state/gpt-deep-research/$sid.binding"
pass "arm requires and binds one exact existing watch"

# --- active records wait outside the turn, then collect one verified archive --
H="$TMP_ROOT/h-collected"; new_home "$H"
WD="$TMP_ROOT/watches-collected"
ARCHIVE="$TMP_ROOT/archives/collected.md"
write_archive "$ARCHIVE"
write_watch "$WD" watch-collected WATCHING "" "https://chatgpt.com/c/collected" "raw prompt: never expose" "private topic"
sid=$(source_id "$WD" "$H" watch-collected)
TEST_GDR_WATCHES="$WD" gdr "$H" arm watch-collected --interval-seconds 1 >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/$sid.claim" || fail "supervised arm did not start the blocking source"
sleep 0.2
if first_result "$H" "$sid" >/dev/null 2>&1; then
  fail "an active watch produced a completion result"
fi
write_watch "$WD" watch-collected COLLECTED "$ARCHIVE" "https://chatgpt.com/c/collected" "raw prompt: never expose" "private topic"
wait_for_result "$H" "$sid" || fail "verified collection produced no durable result"
RESULT=$(first_result "$H" "$sid")
assert_grep '"status":"COLLECTED"' "$RESULT" "existing verified archive is successful collection"
assert_grep "$ARCHIVE" "$RESULT" "successful result points to the archive"
assert_grep 'https://chatgpt.com/c/collected' "$RESULT" "successful result carries the exact conversation URL"
assert_not_grep 'private topic' "$RESULT" "result excludes slugs"
assert_not_grep 'raw prompt' "$RESULT" "result excludes raw watcher error text"
wait_for_absent "$H/state/procevent/$sid.source" || fail "terminal collection did not retire the source registration"
assert_absent "$H/state/procevent/$sid.source" "terminal collection retires the source registration"
assert_contains "$(wake_payloads "$H")" "procevent gpt-deep-research $sid 1" "collection reaches the durable Firstmate wake queue"
pass "active waits and successful collection wake with only review-safe fields"

# --- an in-place rewrite is retried, not falsely published as BLOCKED --------
H="$TMP_ROOT/h-transient-read"; new_home "$H"
WD="$TMP_ROOT/watches-transient-read"
write_watch "$WD" watch-transient-read WATCHING "" "https://chatgpt.com/c/transient-read" "" "transient"
sid=$(source_id "$WD" "$H" watch-transient-read)
TEST_GDR_WATCHES="$WD" gdr "$H" arm watch-transient-read --interval-seconds 1 >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/$sid.claim" || fail "transient-read watch was not supervised"
printf '{"schema":' > "$WD/watch-transient-read.json"
sleep 1.2
if first_result "$H" "$sid" >/dev/null 2>&1; then
  fail "a partial in-place watch rewrite falsely published a terminal result"
fi
write_watch "$WD" watch-transient-read NEEDS_COLLECTION "" "https://chatgpt.com/c/transient-read" "" "transient"
wait_for_result "$H" "$sid" || fail "watch did not recover after the in-place rewrite completed"
RESULT=$(first_result "$H" "$sid")
assert_grep '"status":"NEEDS_COLLECTION"' "$RESULT" "only the later valid terminal state is captured"
pass "inconsistent watch reads retry without a false terminal wake"

# --- a saved report with cleanup failure remains reviewable, never lost -------
H="$TMP_ROOT/h-cleanup"; new_home "$H"
WD="$TMP_ROOT/watches-cleanup"
ARCHIVE="$TMP_ROOT/archives/cleanup.md"
write_archive "$ARCHIVE"
write_watch "$WD" watch-cleanup COLLECTED_CLEANUP_PENDING "$ARCHIVE" "https://chatgpt.com/c/cleanup" "tab close failed after report export" "cleanup topic"
sid=$(source_id "$WD" "$H" watch-cleanup)
TEST_GDR_WATCHES="$WD" gdr "$H" arm watch-cleanup --interval-seconds 1 >/dev/null
wait_for_result "$H" "$sid" || fail "cleanup-pending collection produced no result"
RESULT=$(first_result "$H" "$sid")
assert_grep '"status":"COLLECTED_CLEANUP_PENDING"' "$RESULT" "cleanup-pending status remains distinct"
assert_grep "$ARCHIVE" "$RESULT" "cleanup-pending keeps the verified archive reviewable"
assert_not_grep 'tab close failed' "$RESULT" "raw cleanup diagnostics never leak into the result"
assert_present "$WD/watch-cleanup.json" "the adapter never removes the standalone watch record"
pass "cleanup-pending reports preserve the archive without browser cleanup"

# --- invalid COLLECTED archive is uncertain, not a false success -------------
H="$TMP_ROOT/h-archive-missing"; new_home "$H"
WD="$TMP_ROOT/watches-archive-missing"
MISSING_ARCHIVE="$TMP_ROOT/archives/absent.md"
write_watch "$WD" watch-archive-missing COLLECTED "$MISSING_ARCHIVE" "https://chatgpt.com/c/archive-missing" "sensitive error from page" "sensitive slug"
sid=$(source_id "$WD" "$H" watch-archive-missing)
TEST_GDR_WATCHES="$WD" gdr "$H" arm watch-archive-missing --interval-seconds 1 >/dev/null
wait_for_result "$H" "$sid" || fail "missing archive produced no terminal result"
RESULT=$(first_result "$H" "$sid")
assert_grep '"status":"COLLECTION_UNCERTAIN"' "$RESULT" "missing archive is not classified as collected"
assert_not_grep "$MISSING_ARCHIVE" "$RESULT" "missing archive path is omitted"
assert_grep 'recorded archive is unavailable' "$RESULT" "archive failure has bounded adapter-owned detail"
pass "COLLECTED requires an existing verified archive"

# --- terminal blocked watches from long-prompt ambiguity wake independently --
H="$TMP_ROOT/h-blocked"; new_home "$H"
WD="$TMP_ROOT/watches-blocked"
SECRET='prompt body cookie=secret-token browser-storage=forbidden'
write_watch "$WD" watch-blocked-a BLOCKED "" "https://chatgpt.com/c/blocked-a" "$SECRET" "prompt-derived slug"
write_watch "$WD" watch-blocked-b BLOCKED "" "https://chatgpt.com/c/blocked-b" "$SECRET" "prompt-derived slug"
for watch_id in watch-blocked-a watch-blocked-b; do
  sid=$(source_id "$WD" "$H" "$watch_id")
  TEST_GDR_WATCHES="$WD" gdr "$H" arm "$watch_id" --interval-seconds 1 >/dev/null
  wait_for_result "$H" "$sid" || fail "blocked watch $watch_id produced no terminal result"
  RESULT=$(first_result "$H" "$sid")
  assert_grep '"status":"BLOCKED"' "$RESULT" "blocked watch retains the terminal status"
  assert_not_grep 'secret-token' "$RESULT" "blocked result excludes credential-like watcher text"
  assert_not_grep 'prompt-derived' "$RESULT" "blocked result excludes prompt-derived slug"
done
pass "terminal BLOCKED research watches wake independently without sensitive payloads"

# --- separate watches never consume or suppress each other -------------------
H="$TMP_ROOT/h-isolation"; new_home "$H"
WD="$TMP_ROOT/watches-isolation"
write_watch "$WD" watch-isolation-a WATCHING "" "https://chatgpt.com/c/isolation-a" "" "a"
write_watch "$WD" watch-isolation-b WATCHING "" "https://chatgpt.com/c/isolation-b" "" "b"
sid_a=$(source_id "$WD" "$H" watch-isolation-a)
sid_b=$(source_id "$WD" "$H" watch-isolation-b)
TEST_GDR_WATCHES="$WD" gdr "$H" arm watch-isolation-a --interval-seconds 1 >/dev/null
TEST_GDR_WATCHES="$WD" gdr "$H" arm watch-isolation-b --interval-seconds 1 >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/$sid_a.claim" || fail "first isolated watch was not supervised"
wait_for "$FM_PROCEVENT_CLAIM_ROOT/$sid_b.claim" || fail "second isolated watch was not supervised"
write_watch "$WD" watch-isolation-b NEEDS_COLLECTION "" "https://chatgpt.com/c/isolation-b" "error from B" "b"
wait_for_result "$H" "$sid_b" || fail "second isolated watch did not complete"
if first_result "$H" "$sid_a" >/dev/null 2>&1; then
  fail "second watch completion consumed or completed the first watch"
fi
write_watch "$WD" watch-isolation-a COLLECTION_UNCERTAIN "" "https://chatgpt.com/c/isolation-a" "error from A" "a"
wait_for_result "$H" "$sid_a" || fail "first isolated watch did not independently complete"
[ "$(result_count "$H" "$sid_a")" = 1 ] || fail "first isolated watch captured more than one completion"
[ "$(result_count "$H" "$sid_b")" = 1 ] || fail "second isolated watch captured more than one completion"
pass "multiple research waits complete independently"

# --- re-arming one live binding is idempotent and preserves one child --------
H="$TMP_ROOT/h-idempotent"; new_home "$H"
WD="$TMP_ROOT/watches-idempotent"
write_watch "$WD" watch-idempotent WATCHING "" "https://chatgpt.com/c/idempotent" "" "idempotent"
sid=$(source_id "$WD" "$H" watch-idempotent)
TEST_GDR_WATCHES="$WD" gdr "$H" arm watch-idempotent --interval-seconds 1 >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/$sid.claim" || fail "first arm did not supervise the watch"
owner_before=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/$sid.claim")
out=$(TEST_GDR_WATCHES="$WD" gdr "$H" arm watch-idempotent --interval-seconds 1)
assert_contains "$out" "already armed: $sid" "same live watch arm is idempotent"
owner_after=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/$sid.claim")
[ "$owner_before" = "$owner_after" ] || fail "idempotent arm started a second blocking child"
write_watch "$WD" watch-idempotent NEEDS_COLLECTION "" "https://chatgpt.com/c/idempotent" "" "idempotent"
wait_for_result "$H" "$sid" || fail "idempotent source did not complete"
[ "$(result_count "$H" "$sid")" = 1 ] || fail "idempotent arm created a second completion effect"
pass "re-arming one live watch is idempotent"

# --- capture survives a restart until handled, then stops and can be cleaned --
H="$TMP_ROOT/h-restart"; new_home "$H"
WD="$TMP_ROOT/watches-restart"
write_watch "$WD" watch-restart NEEDS_COLLECTION "" "https://chatgpt.com/c/restart" "" "restart"
sid=$(source_id "$WD" "$H" watch-restart)
TEST_GDR_WATCHES="$WD" gdr "$H" arm watch-restart --interval-seconds 1 >/dev/null
wait_for_result "$H" "$sid" || fail "restart fixture did not capture a result"
wait_for_absent "$H/state/procevent/$sid.source" || fail "terminal result did not retire the exact source"
assert_absent "$H/state/procevent/$sid.source" "terminal result retires the exact source"
RESULT=$(first_result "$H" "$sid")
assert_contains "$(TEST_GDR_WATCHES="$WD" gdr "$H" classify "$RESULT")" NEEDS_COLLECTION "classify reads the bounded result status"
mv "$H/state/.wake-queue" "$H/state/.wake-queue.drained"
out=$(pe "$H" reconcile)
assert_contains "$out" 'published=1' "unhandled GPT result is re-announced after restart reconciliation"
assert_contains "$(wake_payloads "$H")" "procevent gpt-deep-research $sid 1" "restart preserves the exact wake identity"
out=$(pe "$H" handled "$sid" 1)
assert_contains "$out" "handled: $sid 1" "handled acknowledgement records terminal result handling"
mv "$H/state/.wake-queue" "$H/state/.wake-queue.handled"
out=$(pe "$H" reconcile)
assert_contains "$out" 'published=0' "handled result no longer re-announces"
TEST_GDR_WATCHES="$WD" gdr "$H" retire watch-restart >/dev/null
assert_absent "$H/state/gpt-deep-research/$sid.binding" "adapter retirement removes its private binding after handling"
pass "terminal results persist across restart until acknowledged then retire cleanly"

printf 'all fm-procevent-gpt-deep-research tests passed\n'
