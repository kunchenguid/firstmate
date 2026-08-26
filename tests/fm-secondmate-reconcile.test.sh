#!/usr/bin/env bash
# tests/fm-secondmate-reconcile.test.sh - the cooldown-limited reconcile ask.
#
# A backlog-vs-metadata inventory mismatch inside a secondmate home no longer
# blanks that home in the fleet snapshot, so the parent asks the home that owns
# those books to fix them. This suite pins that ask: it lands as a real durable
# steering record, a home is asked at most once per cooldown window however
# often the snapshot runs, a mismatch still sitting there after the window
# earns one gentle re-nudge, and the parent never touches the mate's own files.
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
spawn_gen=spawn-$id
home=$abs
worktree=$abs
META
  fakebin=$(make_fake_tmux "$TMP_ROOT/$1-fake")
  printf '%s\n' "$home" "$mate" "$fakebin"
}

# A minimal but schema-true fleet snapshot carrying one structured-home record.
write_snapshot() {  # <path> <mate-id> <invalidity-json> [state]
  jq -n --arg id "$2" --argjson inv "$3" --arg state "${4:-captain_decision}" '{
    schema:"fm-fleet-snapshot.v1", generated:"2026-08-26T00:00:00Z",
    secondmate_current:{records:[{
      id:$id, home:("/tmp/" + $id), spawn_gen:("spawn-" + $id),
      current:{state:$state, reason:null},
      invalidity:$inv, reconcile_inventory:($inv // {kind:null,ids:[]}),
      provenance:{selected:"structured-home", trust:"partial-structured"}}]}}' > "$1"
}

# Age the home's cooldown record so the next run sees the window as elapsed.
age_cooldown() {  # <state-dir> <mate-id> <seconds-ago>
  printf '%s\n' "$(( $(date +%s) - $3 ))" > "$1/$2.reconcile-nudged"
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

hold_lock_until_released() {  # <lock> <ready> <release>
  bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    : > "$3"
    while [ ! -f "$4" ]; do sleep 0.01; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2" "$3" &
}


test_an_inventory_mismatch_asks_the_mate_once_per_window() {
  local home mate fakebin snap out
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home once mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["stale-scout","watch-row"]}'

  out=$(run_notify "$home" "$fakebin" once "$snap") || fail "the first reconcile ask failed: $out"
  assert_contains "$out" "sent: mate orphan_in_flight" \
    "the first ask did not report what it sent: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] \
    || fail "the ask did not land as exactly one durable steering record"
  assert_contains "$(inbox_text "$home/state" mate)" "check your current books" \
    "the instruction did not ask the mate to inspect its current state"
  if printf '%s' "$(inbox_text "$home/state" mate)" | grep -Fq 'stale-scout'; then
    fail "the instruction prescribed a repair from sampled details that can become stale"
  fi

  # Every later recap sees the same mismatch; none of them may nag.
  out=$(run_notify "$home" "$fakebin" once "$snap") || fail "the repeat run failed: $out"
  assert_contains "$out" "cooldown: mate" "a repeated snapshot did not report the cooldown: $out"
  run_notify "$home" "$fakebin" once "$snap" >/dev/null
  run_notify "$home" "$fakebin" once "$snap" >/dev/null
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] \
    || fail "repeated snapshots asked the mate more than once inside the cooldown"
  pass "a home in mismatch is asked once, and later recaps stay silent"
}

test_a_mismatch_still_there_after_the_window_earns_one_more_nudge() {
  local home mate fakebin snap out
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home window mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["ghost"]}'
  run_notify "$home" "$fakebin" window "$snap" >/dev/null || fail "the first ask failed"

  # Just inside four hours: still silent.
  age_cooldown "$home/state" mate 14000
  out=$(run_notify "$home" "$fakebin" window "$snap") || fail "the in-window run failed: $out"
  assert_contains "$out" "cooldown: mate" "an ask inside the window was not suppressed: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] || fail "an in-window ask was sent anyway"

  # Past four hours: exactly one gentle re-nudge, then silent again.
  age_cooldown "$home/state" mate 14500
  out=$(run_notify "$home" "$fakebin" window "$snap") || fail "the past-window run failed: $out"
  assert_contains "$out" "sent: mate orphan_in_flight" \
    "a mismatch outliving the window did not earn a re-nudge: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 2 ] \
    || fail "the re-nudge did not send exactly one more instruction"
  run_notify "$home" "$fakebin" window "$snap" >/dev/null
  [ "$(inbox_records "$home/state" mate)" -eq 2 ] \
    || fail "the re-nudge did not restart the cooldown"
  pass "a mismatch outliving the cooldown earns one re-nudge, then goes quiet again"
}

test_the_cooldown_starts_when_delivery_finishes() {
  local home mate fakebin snap started nudged
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home deliverytime mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["ghost"]}'
  mv "$fakebin/tmux" "$fakebin/tmux-real"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = send-keys ]; then sleep 2; fi
exec "$(dirname "$0")/tmux-real" "$@"
SH
  chmod +x "$fakebin/tmux"

  started=$(date +%s)
  run_notify "$home" "$fakebin" deliverytime "$snap" >/dev/null \
    || fail "the delayed reconcile ask failed"
  nudged=$(cat "$home/state/mate.reconcile-nudged")
  [ "$nudged" -ge "$((started + 2))" ] \
    || fail "the cooldown began before delivery finished: start=$started nudged=$nudged"
  pass "the cooldown begins when delivery finishes"
}

test_the_window_is_four_hours() {
  local home mate fakebin snap out
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home fourhours mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"terminal_in_flight","ids":["done-row"]}'
  run_notify "$home" "$fakebin" fourhours "$snap" >/dev/null || fail "the first ask failed"
  # One second short of four hours is still inside; one second past is not.
  age_cooldown "$home/state" mate 14399
  out=$(run_notify "$home" "$fakebin" fourhours "$snap")
  assert_contains "$out" "cooldown: mate" "the window was shorter than four hours: $out"
  age_cooldown "$home/state" mate 14401
  out=$(run_notify "$home" "$fakebin" fourhours "$snap")
  assert_contains "$out" "sent: mate" "the window was longer than four hours: $out"
  pass "the cooldown window is four hours"
}

test_each_home_carries_its_own_cooldown() {
  local home mate fakebin snap out
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home perhome mate)
  # A second registered mate in the same home, so one nudge cannot silence the other.
  cp "$home/state/mate.meta" "$home/state/other.meta"
  sed -i.bak 's/fm-mate/fm-other/' "$home/state/other.meta" && rm -f "$home/state/other.meta.bak"
  snap="$home/snapshot.json"
  jq -n '{schema:"fm-fleet-snapshot.v1", generated:"2026-08-26T00:00:00Z",
    secondmate_current:{records:[
      {id:"mate", home:"/tmp/mate", spawn_gen:"spawn-mate", current:{state:"captain_decision",reason:null},
       invalidity:{kind:"orphan_in_flight",ids:["a"]},
       reconcile_inventory:{kind:"orphan_in_flight",ids:["a"]},
       provenance:{selected:"structured-home",trust:"partial-structured"}},
      {id:"other", home:"/tmp/other", spawn_gen:"spawn-mate", current:{state:"captain_decision",reason:null},
       invalidity:{kind:"unowned_current",ids:["b"]},
       reconcile_inventory:{kind:"unowned_current",ids:["b"]},
       provenance:{selected:"structured-home",trust:"partial-structured"}}]}}' > "$snap"
  out=$(run_notify "$home" "$fakebin" perhome "$snap") || fail "the first run failed: $out"
  assert_contains "$out" "sent: mate" "the first home was not asked: $out"
  assert_contains "$out" "sent: other" "the second home was not asked: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] || fail "the first home got the wrong count"
  [ "$(inbox_records "$home/state" other)" -eq 1 ] || fail "the second home got the wrong count"
  # Only one home's window elapses; the other must stay quiet.
  age_cooldown "$home/state" mate 14500
  out=$(run_notify "$home" "$fakebin" perhome "$snap")
  assert_contains "$out" "sent: mate" "an elapsed window did not re-nudge its own home: $out"
  assert_contains "$out" "cooldown: other" "one home's nudge reset another home's window: $out"
  pass "the cooldown is per home, not fleet-wide"
}

test_the_ask_never_arms_a_reply_expectation_or_a_re_ring() {
  local home mate fakebin snap ladder
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home fireforget mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["ghost"]}'
  run_notify "$home" "$fakebin" fireforget "$snap" >/dev/null || fail "the ask failed"
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] || fail "the ask was not durably recorded"

  # The parent expects no answer, so nothing may chase one.
  [ "$(find "$home/state/pending-replies" -type f 2>/dev/null | wc -l | tr -d '[:space:]')" -eq 0 ] \
    || fail "the reconcile ask armed a pending-reply expectation"

  # The record stays unhandled. With the ladder's grace elapsed, an ordinary
  # steer in that position is due for a re-ring; this one must stay invisible.
  ladder=$(FM_TASK_INBOX_GRACE_SECS=0 bash -c '. "$1"; fm_task_inbox_due_action "$2" "$3"' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state" mate 2>&1 || true)
  [ "$ladder" = quiet ] \
    || fail "the unacknowledged reconcile record entered the re-ring ladder: $ladder"

  # Divergence check, so the assertion above cannot pass for the wrong reason:
  # the same inbox, same grace, with an ordinary unhandled steer added.
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_FAKE_TMUX_WINDOW="firstmate:fm-mate" \
    FM_FAKE_TMUX_LOG="$TMP_ROOT/fireforget-tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/fireforget-fake/pane.txt" \
    "$ROOT/bin/fm-send.sh" mate "an ordinary steer that does expect handling" >/dev/null 2>&1 \
    || fail "the control steer could not be recorded"
  ladder=$(FM_TASK_INBOX_GRACE_SECS=0 bash -c '. "$1"; fm_task_inbox_due_action "$2" "$3"' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state" mate 2>&1 || true)
  case "$ladder" in
    ring\ *) ;;
    *) fail "the ladder ignored an ordinary steer too, so the quiet verdict proved nothing: $ladder" ;;
  esac
  pass "the reconcile ask expects no reply and stays out of a ladder that still rings ordinary steers"
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
  [ "$(inbox_records "$home/state" mate)" -eq 0 ] || fail "a healthy home was asked to reconcile"
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
  assert_absent "$home/state/absent-mate.reconcile-nudged" \
    "a failed ask started a cooldown and would never be retried"
  pass "a failed ask starts no cooldown, so the next run retries it"
}

test_busy_lifecycle_locks_never_hold_up_the_digest() {
  local label home mate fakebin snap lock ready release holder notify out
  for label in reconcile control meta; do
    { read -r home; read -r mate; read -r fakebin; } < <(make_main_home "busy-$label" mate)
    snap="$home/snapshot.json"
    write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["ghost"]}'
    case "$label" in
      reconcile) lock="$home/state/.mate.reconcile.lock" ;;
      control) lock="$home/state/.control-mate.lock" ;;
      meta) lock="$home/state/.meta-mate.lock" ;;
    esac
    ready="$home/lock-ready"
    release="$home/lock-release"
    hold_lock_until_released "$lock" "$ready" "$release"
    holder=$!
    while [ ! -f "$ready" ]; do sleep 0.01; done
    run_notify "$home" "$fakebin" "busy-$label" "$snap" > "$home/notify.out" 2>&1 &
    notify=$!
    sleep 0.2
    if kill -0 "$notify" 2>/dev/null; then
      : > "$release"
      wait "$notify" 2>/dev/null || true
      wait "$holder" 2>/dev/null || true
      fail "a busy $label lock blocked the reconcile path"
    fi
    wait "$notify" || fail "a busy $label lock made notify fail"
    : > "$release"
    wait "$holder" || fail "the $label lock holder failed"
    out=$(cat "$home/notify.out")
    assert_contains "$out" "skipped: mate lock" \
      "a busy $label lock was not reported as a skipped nudge: $out"
    assert_absent "$home/state/mate.reconcile-nudged" \
      "a skipped $label-lock nudge started the cooldown"
  done
  pass "busy reconcile lifecycle locks never block the digest or start cooldown"
}

test_concurrent_recaps_send_one_instruction() {
  local home mate fakebin snap
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home concurrent mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["ghost"]}'
  run_notify "$home" "$fakebin" concurrent "$snap" >/dev/null 2>&1 &
  run_notify "$home" "$fakebin" concurrent "$snap" >/dev/null 2>&1 &
  wait
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] \
    || fail "two simultaneous recaps asked the mate twice"
  pass "simultaneous recaps still ask the mate only once"
}

test_a_delayed_snapshot_never_prescribes_a_stale_repair() {
  local home mate fakebin old_snap new_snap out text
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home delayed mate)
  old_snap="$home/old-snapshot.json"
  new_snap="$home/new-snapshot.json"
  write_snapshot "$old_snap" mate '{"kind":"orphan_in_flight","ids":["already-repaired"]}'
  write_snapshot "$new_snap" mate '{"kind":"unowned_current","ids":["current-row"]}'

  out=$(run_notify "$home" "$fakebin" delayed "$old_snap") \
    || fail "the delayed reconcile ask failed: $out"
  assert_contains "$out" "sent: mate orphan_in_flight" \
    "the delayed snapshot did not produce the cooldown-limited check: $out"
  out=$(run_notify "$home" "$fakebin" delayed "$new_snap") \
    || fail "the current snapshot reconcile failed: $out"
  assert_contains "$out" "cooldown: mate" \
    "the per-home cooldown did not deduplicate the newer observation: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] \
    || fail "the old and new snapshots produced more than one ask inside the cooldown"
  text=$(inbox_text "$home/state" mate)
  assert_contains "$text" "check your current books" \
    "the delayed ask did not direct the mate to current state"
  if printf '%s' "$text" | grep -Eq 'already-repaired|current-row'; then
    fail "the delayed ask embedded sampled row details and could prescribe a stale repair: $text"
  fi
  pass "a delayed snapshot asks for a current check instead of prescribing a stale repair"
}

test_a_stale_snapshot_never_targets_a_replacement_mate() {
  local home mate fakebin snap out
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home stale mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["old-ghost"]}'
  awk '{ sub(/^spawn_gen=.*/, "spawn_gen=spawn-replacement"); print }' \
    "$home/state/mate.meta" > "$home/state/mate.meta.tmp"
  mv "$home/state/mate.meta.tmp" "$home/state/mate.meta"

  out=$(run_notify "$home" "$fakebin" stale "$snap") \
    || fail "a stale snapshot made reconcile fail: $out"
  assert_contains "$out" "stale: mate orphan_in_flight" \
    "the stale snapshot was not identified: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 0 ] \
    || fail "a replacement mate received its predecessor's reconcile ask"
  assert_absent "$home/state/mate.reconcile-nudged" \
    "a replacement mate inherited cooldown from a stale snapshot"
  pass "a stale snapshot cannot ask or silence a replacement mate"
}

test_teardown_cannot_leave_its_replacement_in_cooldown() {
  local home mate fakebin snap signal release lifecycle_done cooldown notify_pid lifecycle_pid
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home lifecycle mate)
  snap="$home/snapshot.json"
  signal="$home/send-ringing"
  release="$home/release-ring"
  lifecycle_done="$home/lifecycle-done"
  cooldown="$home/state/mate.reconcile-nudged"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["ghost"]}'
  mv "$fakebin/tmux" "$fakebin/tmux-real"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = send-keys ]; then
  : > "$FM_FAKE_TMUX_SEND_SIGNAL"
  while [ ! -f "$FM_FAKE_TMUX_SEND_RELEASE" ]; do sleep 0.01; done
fi
exec "$(dirname "$0")/tmux-real" "$@"
SH
  chmod +x "$fakebin/tmux"

  FM_FAKE_TMUX_SEND_SIGNAL="$signal" FM_FAKE_TMUX_SEND_RELEASE="$release" \
    run_notify "$home" "$fakebin" lifecycle "$snap" >/dev/null 2>&1 &
  notify_pid=$!
  while [ ! -f "$signal" ]; do sleep 0.01; done

  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$home/state/.control-mate.lock"
    fm_lock_acquire_wait "$home/state/.meta-mate.lock"
    rm -rf "$home/state/mate.inbox"
    rm -f "$home/state/mate.meta" "$home/state/mate.reconcile-nudged"
    cat > "$home/state/mate.meta" <<META
window=firstmate:fm-mate
kind=secondmate
harness=claude
backend=tmux
spawn_gen=spawn-replacement
home=$mate
worktree=$mate
META
    fm_lock_release "$home/state/.meta-mate.lock"
    fm_lock_release "$home/state/.control-mate.lock"
    : > "$lifecycle_done"
  ) &
  lifecycle_pid=$!

  sleep 0.1
  : > "$release"
  wait "$notify_pid" 2>/dev/null || true
  wait "$lifecycle_pid" || fail "the simulated teardown and reseed failed"
  [ -f "$lifecycle_done" ] || fail "the simulated lifecycle transition did not finish"
  assert_absent "$cooldown" \
    "a retired mate's cooldown was recreated after its replacement was seeded"
  pass "teardown retires the cooldown before a replacement can inherit it"
}

test_an_inventory_mismatch_asks_the_mate_once_per_window
test_a_mismatch_still_there_after_the_window_earns_one_more_nudge
test_the_cooldown_starts_when_delivery_finishes
test_the_window_is_four_hours
test_each_home_carries_its_own_cooldown
test_the_ask_never_arms_a_reply_expectation_or_a_re_ring
test_a_readable_home_without_a_mismatch_is_never_asked
test_the_parent_never_changes_the_mates_own_files
test_a_failed_send_is_retried_on_the_next_run
test_busy_lifecycle_locks_never_hold_up_the_digest
test_concurrent_recaps_send_one_instruction
test_a_delayed_snapshot_never_prescribes_a_stale_repair
test_a_stale_snapshot_never_targets_a_replacement_mate
test_teardown_cannot_leave_its_replacement_in_cooldown
