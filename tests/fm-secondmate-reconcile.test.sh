#!/usr/bin/env bash
# tests/fm-secondmate-reconcile.test.sh - the once-per-episode reconcile ask.
#
# A backlog-vs-metadata inventory mismatch inside a secondmate home no longer
# blanks that home in the fleet snapshot, so the parent asks the home that owns
# those books to fix them. This suite pins that ask: it lands as a real durable
# steering record, it lands exactly once per episode however often the snapshot
# runs, a changed mismatch earns one more, a cleared mismatch is forgotten, and
# the parent never touches the mate's own files.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

RECONCILE="$ROOT/bin/fm-secondmate-reconcile.sh"
TMP_ROOT=$(fm_test_tmproot fm-secondmate-reconcile)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

export FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1

# A main home with one registered, live, local secondmate reachable through the
# fake tmux backend, so fm-send's real inbox plane is exercised end to end.
make_main_home() {  # <name> <mate-id>
  local home="$TMP_ROOT/$1" mate="$TMP_ROOT/$1-mate" id=$2 abs fakebin
  mkdir -p "$home/data" "$home/state"
  seed_secondmate_home_marker "$mate" "$id"
  abs=$(cd "$mate" && pwd -P)
  printf -- '- %s - fixture domain (home: %s; scope: fixture; projects: sample; added 2026-08-26)\n' \
    "$id" "$abs" > "$home/data/secondmates.md"
  cat > "$home/state/$id.meta" <<META
window=firstmate:fm-$id
kind=secondmate
harness=claude
backend=tmux
home=$abs
worktree=$abs
META
  fakebin=$(make_fake_tmux "$TMP_ROOT/$1-fake")
  printf '%s\n' "$home" "$mate" "$fakebin"
}

# A minimal but schema-true fleet snapshot carrying one structured-home record.
write_snapshot() {  # <path> <mate-id> <invalidity-json> [state]
  jq -n --arg id "$2" --argjson inv "$3" --arg state "${4:-captain_decision}" '{
    schema:"fm-fleet-snapshot.v1",
    secondmate_current:{records:[{
      id:$id, home:("/tmp/" + $id),
      current:{state:$state, reason:null},
      invalidity:$inv,
      provenance:{selected:"structured-home", trust:"partial-structured"}}]}}' > "$1"
}

run_notify() {  # <home> <fakebin> <name> <snapshot> [extra args...]
  local home=$1 fakebin=$2 name=$3 snap=$4
  shift 4
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_FAKE_TMUX_WINDOW="firstmate:fm-mate" \
    FM_FAKE_TMUX_LOG="$TMP_ROOT/$name-tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/$name-fake/pane.txt" \
    "$RECONCILE" notify --snapshot "$snap" "$@"
}

inbox_records() {  # <state-dir> <task-id>
  find "$1/$2.inbox" -maxdepth 1 -type f -name '*.msg' 2>/dev/null | wc -l | tr -d '[:space:]'
}

# Content-and-name fingerprint of a whole home, so any parent-side write shows up.
fingerprint_tree() {  # <dir>
  find "$1" -type f -print0 2>/dev/null | LC_ALL=C sort -z \
    | while IFS= read -r -d '' f; do printf '%s %s\n' "${f#"$1"}" "$(cksum < "$f")"; done
}

inbox_text() {  # <state-dir> <task-id>
  local rec
  for rec in "$1/$2.inbox"/*.msg; do
    [ -f "$rec" ] || continue
    bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$rec"
  done
}

test_an_inventory_mismatch_asks_the_mate_once_and_only_once() {
  local home mate fakebin snap out
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home once mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["stale-scout","watch-row"]}'

  out=$(run_notify "$home" "$fakebin" once "$snap") \
    || fail "the first reconcile ask failed: $out"
  assert_contains "$out" "sent: mate orphan_in_flight:stale-scout,watch-row" \
    "the first ask did not report the episode it sent: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] \
    || fail "the ask did not land as exactly one durable steering record"
  assert_contains "$(inbox_text "$home/state" mate)" "stale-scout" \
    "the instruction did not name the rows that disagree"

  # The same persistent mismatch, seen again on every later snapshot, must not
  # re-nag: this is the whole point of episode identity.
  out=$(run_notify "$home" "$fakebin" once "$snap") \
    || fail "the repeat reconcile run failed: $out"
  assert_contains "$out" "dedupe: mate orphan_in_flight:stale-scout,watch-row" \
    "a repeated snapshot did not dedupe the episode: $out"
  out=$(run_notify "$home" "$fakebin" once "$snap")
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] \
    || fail "repeated snapshots sent the mate more than one instruction per episode"
  pass "one inventory-mismatch episode asks the mate exactly once, however often it is seen"
}

test_concurrent_recaps_send_one_instruction() {
  local home mate fakebin snap p1 p2
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home concurrent mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["ghost"]}'

  run_notify "$home" "$fakebin" concurrent "$snap" > "$home/first.out" & p1=$!
  run_notify "$home" "$fakebin" concurrent "$snap" > "$home/second.out" & p2=$!
  wait "$p1" || fail "the first concurrent recap failed"
  wait "$p2" || fail "the second concurrent recap failed"
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] \
    || fail "concurrent recaps sent more than one instruction for one episode"
  pass "concurrent recaps serialize one reconcile instruction per episode"
}

test_a_completed_send_survives_a_missing_episode_commit() {
  local home mate fakebin snap out corr
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home interrupted mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"unowned_current","ids":["live-row"]}'
  run_notify "$home" "$fakebin" interrupted "$snap" >/dev/null || fail "the first ask failed"

  corr=$(find "$home/state/pending-replies" -maxdepth 1 -type f -name '????????????????' -exec basename {} \; | head -1)
  [ -n "$corr" ] || fail "the delivered ask has no persisted correlation identity"
  printf 'pending\tunowned_current:live-row\t%s\n' "$corr" > "$home/state/mate.reconcile-episode"
  out=$(run_notify "$home" "$fakebin" interrupted "$snap") \
    || fail "recovery after the missing commit failed: $out"
  assert_contains "$out" "sent: mate unowned_current:live-row" \
    "the interrupted episode was not recovered: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] \
    || fail "recovery after a delivered send duplicated the instruction"
  pass "an interrupted episode commit resumes without duplicating delivery"
}

test_the_ids_order_does_not_split_one_episode_in_two() {
  local home mate fakebin snap
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home order mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"unowned_current","ids":["b","a"]}'
  run_notify "$home" "$fakebin" order "$snap" >/dev/null || fail "the first ask failed"
  write_snapshot "$snap" mate '{"kind":"unowned_current","ids":["a","b"]}'
  assert_contains "$(run_notify "$home" "$fakebin" order "$snap")" "dedupe: mate" \
    "the same mismatch reported in a different order was treated as a new episode"
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] \
    || fail "a reordered id list produced a second instruction"
  pass "episode identity ignores the order the mismatched ids arrive in"
}

test_a_changed_or_cleared_mismatch_is_a_new_episode() {
  local home mate fakebin snap out
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home change mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"terminal_in_flight","ids":["done-row"]}'
  run_notify "$home" "$fakebin" change "$snap" >/dev/null || fail "the first ask failed"

  # A different mismatch is genuinely new information and earns one more ask.
  write_snapshot "$snap" mate '{"kind":"terminal_in_flight","ids":["done-row","failed-row"]}'
  out=$(run_notify "$home" "$fakebin" change "$snap")
  assert_contains "$out" "sent: mate terminal_in_flight:done-row,failed-row" \
    "a changed mismatch did not earn a fresh ask: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 2 ] \
    || fail "a changed episode did not send exactly one more instruction"

  # Once the mate has fixed its books the episode is forgotten, so a later
  # recurrence is asked about again instead of being silently deduped forever.
  write_snapshot "$snap" mate 'null'
  out=$(run_notify "$home" "$fakebin" change "$snap")
  assert_contains "$out" "cleared: mate" "a repaired home was not cleared: $out"
  write_snapshot "$snap" mate '{"kind":"terminal_in_flight","ids":["done-row"]}'
  out=$(run_notify "$home" "$fakebin" change "$snap")
  assert_contains "$out" "sent: mate terminal_in_flight:done-row" \
    "a recurrence after a repair was not asked about again: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 3 ] \
    || fail "the recurrence did not send exactly one more instruction"
  pass "a changed mismatch earns one more ask, and a repaired one is forgotten"
}

test_a_readable_home_without_a_mismatch_is_never_asked() {
  local home mate fakebin snap out
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home quiet mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"child_current_unavailable","ids":["x"]}' unknown
  out=$(run_notify "$home" "$fakebin" quiet "$snap") || fail "notify failed: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 0 ] \
    || fail "an unavailable child state was mistaken for a books problem"
  write_snapshot "$snap" mate '{"kind":null,"ids":[]}' no_active_work
  out=$(run_notify "$home" "$fakebin" quiet "$snap") || fail "notify failed: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 0 ] \
    || fail "a healthy home was asked to reconcile"
  pass "only a backlog-vs-metadata mismatch produces an ask"
}

test_the_parent_never_changes_the_mates_own_files() {
  local home mate fakebin snap before after
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home readonly mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["ghost"]}'
  before=$(fingerprint_tree "$mate")
  [ -n "$before" ] || fail "the mate fixture has no files to compare"
  run_notify "$home" "$fakebin" readonly "$snap" >/dev/null || fail "the ask failed"
  after=$(fingerprint_tree "$mate")
  [ "$before" = "$after" ] \
    || fail "asking for a reconcile changed the mate's own files: $before / $after"
  pass "the parent asks and changes nothing inside the mate's home"
}

test_a_failed_send_is_retried_on_the_next_run() {
  local home mate fakebin snap out rc
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home retry mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" absent-mate '{"kind":"orphan_in_flight","ids":["ghost"]}'
  set +e
  out=$(run_notify "$home" "$fakebin" retry "$snap"); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unroutable ask reported success: $out"
  assert_contains "$out" "failed: absent-mate" "the failure was not reported: $out"
  assert_absent "$home/state/absent-mate.reconcile-episode" \
    "a failed ask recorded its episode and would never be retried"
  pass "a failed ask records nothing, so the next run retries it"
}

test_an_inventory_mismatch_asks_the_mate_once_and_only_once
test_concurrent_recaps_send_one_instruction
test_a_completed_send_survives_a_missing_episode_commit
test_the_ids_order_does_not_split_one_episode_in_two
test_a_changed_or_cleared_mismatch_is_a_new_episode
test_a_readable_home_without_a_mismatch_is_never_asked
test_the_parent_never_changes_the_mates_own_files
test_a_failed_send_is_retried_on_the_next_run
