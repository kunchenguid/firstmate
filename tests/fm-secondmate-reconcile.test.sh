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
write_snapshot() {  # <path> <mate-id> <invalidity-json> [state] [generated] [observation]
  jq -n --arg id "$2" --argjson inv "$3" --arg state "${4:-captain_decision}" \
    --arg generated "${5:-2026-08-26T00:00:00Z}" \
    --arg observation "${6:-00000000000000000001-0000000001}" '{
    schema:"fm-fleet-snapshot.v1", generated:$generated, observation:$observation,
    secondmate_current:{records:[{
      id:$id, home:("/tmp/" + $id),
      current:{state:$state, reason:null},
      invalidity:$inv, reconcile_inventory:($inv // {kind:null,ids:[]}),
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
  assert_contains "$out" 'sent: mate orphan_in_flight:["stale-scout","watch-row"]' \
    "the first ask did not report the episode it sent: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] \
    || fail "the ask did not land as exactly one durable steering record"
  assert_contains "$(inbox_text "$home/state" mate)" "stale-scout" \
    "the instruction did not name the rows that disagree"
  [ "$(find "$home/state/pending-replies" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d '[:space:]')" -eq 0 ] \
    || fail "a fire-and-forget reconcile ask armed pending-reply recovery"

  # The same persistent mismatch, seen again on every later snapshot, must not
  # re-nag: this is the whole point of episode identity.
  out=$(run_notify "$home" "$fakebin" once "$snap") \
    || fail "the repeat reconcile run failed: $out"
  assert_contains "$out" 'dedupe: mate orphan_in_flight:["stale-scout","watch-row"]' \
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

  corr=$(inbox_text "$home/state" mate | grep -oE 'delivery=[a-f0-9]{16}' | head -1 | cut -d= -f2)
  [ -n "$corr" ] || fail "the delivered ask has no persisted delivery identity"
  printf 'pending\t00000000000000000001-0000000001\tunowned_current:["live-row"]\t%s\n' "$corr" > "$home/state/mate.reconcile-episode"
  out=$(run_notify "$home" "$fakebin" interrupted "$snap") \
    || fail "recovery after the missing commit failed: $out"
  assert_contains "$out" 'sent: mate unowned_current:["live-row"]' \
    "the interrupted episode was not recovered: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] \
    || fail "recovery after a delivered send duplicated the instruction"
  pass "an interrupted episode commit resumes without duplicating delivery"
}

test_an_unconfirmed_remote_send_reuses_its_delivery_identity() {
  local home mate fakebin runtime first retry out rc first_corr second_corr
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home remote-unknown mate)
  runtime="$home/runtime"
  mkdir -p "$runtime"
  cp -R "$ROOT/bin" "$runtime/bin"
  cat > "$runtime/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
set -eu
state=${FM_STATE_OVERRIDE:?}
[ "${2:-}" = --fire-and-forget ] || exit 2
corr=${3:-}
mkdir -p "$state/fake-remote-deliveries"
printf '%s\n' "$corr" >> "${FM_RECONCILE_FAKE_SEND_LOG:?}"
touch "$state/fake-remote-deliveries/$corr"
if [ ! -f "$state/fake-unknown-once" ]; then
  touch "$state/fake-unknown-once"
  exit 3
fi
exit 0
SH
  chmod +x "$runtime/bin/fm-send.sh"
  first="$home/first.json"
  retry="$home/retry.json"
  write_snapshot "$first" mate '{"kind":"unowned_current","ids":["live-row"]}' captain_decision 2026-08-26T00:00:01Z
  write_snapshot "$retry" mate '{"kind":"unowned_current","ids":["live-row"]}' captain_decision 2026-08-26T00:00:02Z

  set +e
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$runtime" \
    FM_STATE_OVERRIDE="$home/state" FM_RECONCILE_FAKE_SEND_LOG="$home/send.log" \
    "$runtime/bin/fm-secondmate-reconcile.sh" notify --snapshot "$first")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completion-unknown transport reported success: $out"
  assert_contains "$out" 'unconfirmed: mate unowned_current:["live-row"]' \
    "completion uncertainty was not preserved: $out"
  first_corr=$(head -1 "$home/send.log")
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$runtime" \
    FM_STATE_OVERRIDE="$home/state" FM_RECONCILE_FAKE_SEND_LOG="$home/send.log" \
    "$runtime/bin/fm-secondmate-reconcile.sh" notify --snapshot "$retry" >/dev/null \
    || fail "the delivery-preserving retry failed"
  second_corr=$(tail -1 "$home/send.log")
  [ "$first_corr" = "$second_corr" ] \
    || fail "the retry changed delivery identity from $first_corr to $second_corr"
  [ "$(find "$home/state/fake-remote-deliveries" -type f | wc -l | tr -d '[:space:]')" -eq 1 ] \
    || fail "the completion-unknown retry created a second logical delivery"
  pass "completion-unknown remote sends reuse their delivery identity"
}

test_an_older_snapshot_cannot_restore_a_cleared_episode() {
  local home mate fakebin first cleared stale recurrence out
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home stale mate)
  first="$home/first.json"
  cleared="$home/cleared.json"
  stale="$home/stale.json"
  recurrence="$home/recurrence.json"
  write_snapshot "$first" mate '{"kind":"orphan_in_flight","ids":["ghost"]}' captain_decision 2026-08-26T00:00:00Z 00000000000000000001-0000000001
  write_snapshot "$cleared" mate null no_active_work 2026-08-26T00:00:00Z 00000000000000000003-0000000001
  write_snapshot "$stale" mate '{"kind":"orphan_in_flight","ids":["ghost"]}' captain_decision 2026-08-26T00:00:00Z 00000000000000000002-0000000001
  write_snapshot "$recurrence" mate '{"kind":"orphan_in_flight","ids":["ghost"]}' captain_decision 2026-08-26T00:00:00Z 00000000000000000004-0000000001

  run_notify "$home" "$fakebin" stale "$first" >/dev/null || fail "the first episode failed"
  run_notify "$home" "$fakebin" stale "$cleared" >/dev/null || fail "the clear observation failed"
  out=$(run_notify "$home" "$fakebin" stale "$stale") || fail "the stale observation failed: $out"
  assert_contains "$out" "stale: mate 00000000000000000002-0000000001" \
    "an older observation was not rejected: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] \
    || fail "an older snapshot sent a stale reconcile instruction"
  run_notify "$home" "$fakebin" stale "$recurrence" >/dev/null \
    || fail "the later recurrence failed"
  [ "$(inbox_records "$home/state" mate)" -eq 2 ] \
    || fail "a stale snapshot prevented a later recurrence from being asked"
  pass "older snapshots cannot restore cleared reconcile episodes"
}

test_distinct_id_sets_never_share_an_episode_identity() {
  local home mate fakebin first second out
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home id-collision mate)
  first="$home/first.json"
  second="$home/second.json"
  write_snapshot "$first" mate '{"kind":"orphan_in_flight","ids":["a,b","c"]}' captain_decision \
    2026-08-26T00:00:00Z 00000000000000000001-0000000001
  write_snapshot "$second" mate '{"kind":"orphan_in_flight","ids":["a","b,c"]}' captain_decision \
    2026-08-26T00:00:00Z 00000000000000000002-0000000001

  run_notify "$home" "$fakebin" id-collision "$first" >/dev/null \
    || fail "the first comma-bearing id set failed"
  out=$(run_notify "$home" "$fakebin" id-collision "$second") \
    || fail "the distinct comma-bearing id set failed: $out"
  assert_contains "$out" 'sent: mate orphan_in_flight:["a","b,c"]' \
    "a distinct sorted id set was deduped through a joined-string collision: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 2 ] \
    || fail "distinct id sets that render similarly shared one delivery"
  pass "canonical id arrays keep distinct mismatch episodes separate"
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
  assert_contains "$out" 'sent: mate terminal_in_flight:["done-row","failed-row"]' \
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
  assert_contains "$out" 'sent: mate terminal_in_flight:["done-row"]' \
    "a recurrence after a repair was not asked about again: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 3 ] \
    || fail "the recurrence did not send exactly one more instruction"
  pass "a changed mismatch earns one more ask, and a repaired one is forgotten"
}

test_a_strict_invalidity_still_clears_the_prior_episode() {
  local home mate fakebin first strict recurrence out
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home strict-clear mate)
  first="$home/first.json"
  strict="$home/strict.json"
  recurrence="$home/recurrence.json"
  write_snapshot "$first" mate '{"kind":"orphan_in_flight","ids":["ghost"]}' captain_decision \
    2026-08-26T00:00:00Z 00000000000000000001-0000000001
  write_snapshot "$strict" mate null unknown \
    2026-08-26T00:00:00Z 00000000000000000002-0000000001
  jq '.secondmate_current.records[0]
      |= (.provenance.selected = "parent-event-fallback"
          | .invalidity = null
          | .reconcile_inventory = {kind:"unstructured_current",ids:["free-form-row"]})' \
    "$strict" > "$strict.tmp" && mv "$strict.tmp" "$strict"
  write_snapshot "$recurrence" mate '{"kind":"orphan_in_flight","ids":["ghost"]}' captain_decision \
    2026-08-26T00:00:00Z 00000000000000000003-0000000001

  run_notify "$home" "$fakebin" strict-clear "$first" >/dev/null || fail "the first episode failed"
  out=$(run_notify "$home" "$fakebin" strict-clear "$strict") \
    || fail "the strict-invalidity clear failed: $out"
  assert_contains "$out" "cleared: mate" \
    "a sampled strict-invalidity home did not clear its prior mismatch episode: $out"
  run_notify "$home" "$fakebin" strict-clear "$recurrence" >/dev/null \
    || fail "the recurrence after strict invalidity failed"
  [ "$(inbox_records "$home/state" mate)" -eq 2 ] \
    || fail "a stale episode marker suppressed recurrence after strict invalidity"
  pass "sampled strict-invalidity homes still clear prior mismatch episodes"
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
  if FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$RECONCILE" episode absent-mate >/dev/null; then
    fail "a failed ask recorded its episode and would never be retried"
  fi
  set +e
  out=$(run_notify "$home" "$fakebin" retry "$snap"); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unroutable ask was not retried: $out"
  assert_contains "$out" "failed: absent-mate" "the next run did not retry the failed ask: $out"
  pass "a failed ask records no episode, so the next run retries it"
}

test_an_inventory_mismatch_asks_the_mate_once_and_only_once
test_concurrent_recaps_send_one_instruction
test_a_completed_send_survives_a_missing_episode_commit
test_an_unconfirmed_remote_send_reuses_its_delivery_identity
test_an_older_snapshot_cannot_restore_a_cleared_episode
test_distinct_id_sets_never_share_an_episode_identity
test_the_ids_order_does_not_split_one_episode_in_two
test_a_changed_or_cleared_mismatch_is_a_new_episode
test_a_strict_invalidity_still_clears_the_prior_episode
test_a_readable_home_without_a_mismatch_is_never_asked
test_the_parent_never_changes_the_mates_own_files
test_a_failed_send_is_retried_on_the_next_run
