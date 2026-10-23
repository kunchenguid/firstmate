#!/usr/bin/env bash
# Behavior tests for the wake backstop (bin/fm-wake-backstop.sh,
# docs/watcher-continuity.md "Wake backstop").
#
# Fixture homes are genuine primary checkouts whose bin is this repo's. A fake
# harness (a bash symlink named "claude") holds each home's session lock. The
# incident replay seeds the state the 2026-10-23 lost rewake left behind: an
# old main-only wake in the queue, an auto-arm epoch stuck at arming under a
# dead owner, a stale beacon, no watcher, and a dead arm a pass-through left
# for main. Pane delivery runs against fake backend primitives (the script is
# sourced for that case); the loop cases use the FM_TEST_WAKE_BACKSTOP_DELIVER
# seam in place of a pane, so no real terminal is driven.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BACKSTOP_REL=bin/fm-wake-backstop.sh

TMP_ROOT=$(fm_test_tmproot fm-wake-backstop)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"

# The suite runs the backstop itself; tests/lib.sh turns it off for every
# other suite.
export FM_WAKE_BACKSTOP_SECS=600
unset FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND FM_TEST_WAKE_BACKSTOP_DELIVER

PRIMARIES="$TMP_ROOT/primaries"
suite_cleanup() {
  local pid home
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    FM_HOME="$home" "$home/$BACKSTOP_REL" stop >/dev/null 2>&1 || true
    : > "$home/primary.stop" 2>/dev/null || true
  done < <(cat "$TMP_ROOT/homes" 2>/dev/null)
  while IFS= read -r pid; do
    kill -TERM "$pid" 2>/dev/null || true
  done < <(cat "$PRIMARIES" 2>/dev/null)
  fm_test_cleanup
}
trap suite_cleanup EXIT

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  git init -q "$home"
  : > "$home/AGENTS.md"
  ln -s "$ROOT/bin" "$home/bin"
  printf '%s\n' "$home" >> "$TMP_ROOT/homes"
  printf '%s\n' "$home"
}

# A live fake Claude session holding the home's lock until primary.stop.
start_primary() {  # <home>
  local home=$1 i=0
  rm -f "$home/primary.stop" "$home/primary.pid"
  "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$1/state/.lock"
    printf "%s\n" "$$" > "$1/primary.pid"
    while [ ! -e "$1/primary.stop" ]; do sleep 0.2; done
  ' _ "$home" &
  printf '%s\n' "$!" >> "$PRIMARIES"
  while [ "$i" -lt 50 ] && [ ! -s "$home/primary.pid" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$home/primary.pid" ] || fail "fixture: the fake primary did not take the lock"
}

dead_pid() {
  local pid
  sleep 0 &
  pid=$!
  wait "$pid" 2>/dev/null || true
  printf '%s\n' "$pid"
}

identity_of() {  # <pid>
  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$1"
}

# The state the 2026-10-23 incident left: rows 1219 and 1221-1223 queued for
# an hour, epoch 216 stuck at arming under a dead owner, a stale beacon, no
# watcher lock, and the pass-through's left arm long dead.
seed_incident() {  # <home>
  local home=$1 now owner arm
  now=$(date +%s)
  owner=$(dead_pid)
  arm=$(dead_pid)
  {
    printf '%s\t1219\tcheck\tinactive-outcome:0de831cd190ebb3c5490e7bdd45e9dfb\tcheck: inactive-outcome\n' "$((now - 3700))"
    printf '%s\t1221\tsignal\tuxb-prd-16980.status\tsignal: %s/state/uxb-prd-16980.status\n' "$((now - 3580))" "$home"
    printf '%s\t1222\tsignal\tuxb-prd-16980.turn-ended\tsignal: %s/state/uxb-prd-16980.turn-ended\n' "$((now - 3580))" "$home"
    printf '%s\t1223\tsignal\tuxb-prd-16989.turn-ended\tsignal: %s/state/uxb-prd-16989.turn-ended\n' "$((now - 3580))" "$home"
  } > "$home/state/.wake-queue"
  printf '1223\n' > "$home/state/.wake-queue.seq"
  printf 'epoch=216 owner_pid=%s outcome=arming updated_at=%s owner_session_id=1302ae45-9d44-4c67-ae51-b33d4eb0b61b\nFri Oct 23 02:38:03 2026     bash %s/bin/fm-claude-stop-autoarm.sh\nThu Oct 22 15:04:26 2026     claude\n' \
    "$owner" "$((now - 3766))" "$home" > "$home/state/.claude-autoarm-epoch"
  touch -t 202610230238 "$home/state/.claude-autoarm-epoch"
  printf 'pending:downtime:10072.1792715927.EofFni\n' > "$home/state/.watcher-down"
  : > "$home/state/.last-watcher-beat"
  touch -t 202610230240 "$home/state/.last-watcher-beat"
  printf '%s\tFri Oct 23 02:39:10 2026     bash %s/bin/fm-watch-arm.sh\n' "$arm" "$home" > "$home/state/.supervision-host-left"
  printf 'stale-beacon\n' > "$home/state/.guard-watcher-stale-banner"
}

check_home() {  # <home> [env assignments...]
  local home=$1
  shift
  env FM_HOME="$home" "$@" "$home/$BACKSTOP_REL" check
}

# --- detection ----------------------------------------------------------------

test_incident_replay_is_stranded() {
  local home out
  home=$(make_home incident)
  seed_incident "$home"
  start_primary "$home"
  out=$(check_home "$home")
  assert_contains "$out" "wake-backstop: stranded - 4 wake(s) queued, the oldest (row 1219)" "the replayed incident must read stranded"
  out=$(check_home "$home" FM_WAKE_BACKSTOP_SECS=7200)
  assert_contains "$out" "wake-backstop: clear - 4 wake(s) queued, the oldest for" "a wake younger than the threshold is not stranded"
  pass "backstop: the replayed 2026-10-23 state reads stranded once the oldest wake passes the threshold"
}

test_inert_and_clear_cases() {
  local home out
  home=$(make_home inert)
  seed_incident "$home"
  out=$(check_home "$home")
  assert_contains "$out" "wake-backstop: inert - no live primary session holds the lock" "a dead lock holder must be inert"
  start_primary "$home"
  : > "$home/state/.afk"
  out=$(check_home "$home")
  assert_contains "$out" "wake-backstop: inert - away or quiet mode" "the away daemon owns supervision while state/.afk exists"
  rm -f "$home/state/.afk"
  out=$(check_home "$home" FM_WAKE_BACKSTOP_SECS=0)
  assert_contains "$out" "wake-backstop: inert - turned off" "a zero threshold turns the backstop off"
  : > "$home/state/.wake-queue"
  out=$(check_home "$home")
  assert_contains "$out" "wake-backstop: clear - no durable wake is queued" "an empty queue is clear"
  printf 'voyager\n' > "$home/.fm-secondmate-home"
  seed_incident "$home"
  out=$(check_home "$home")
  assert_contains "$out" "wake-backstop: inert - a secondmate home" "a secondmate home is inert"
  out=$(FM_HOME="$home" "$home/$BACKSTOP_REL" ensure)
  assert_contains "$out" "wake-backstop: inert - a secondmate home" "ensure must start nothing in a secondmate home"
  [ ! -e "$home/state/.wake-backstop" ] || fail "a secondmate home recorded a backstop loop"
  pass "backstop: inert without a live primary, under away mode, when off, and in a secondmate home; clear on an empty queue"
}

# A live Stop-hook generation claim owns the delivery of its cycle's close.
test_open_stop_hook_claim_is_clear() {
  local home out owner
  home=$(make_home open-claim)
  seed_incident "$home"
  start_primary_with_claim "$home"
  out=$(check_home "$home")
  assert_contains "$out" "wake-backstop: clear - 4 wake(s) queued" "an open claim must keep the backstop clear"
  assert_contains "$out" "a live Stop-hook cycle owns their delivery" "the verdict must name the open claim"
  owner=$(cat "$home/owner.pid")
  kill "$owner" 2>/dev/null
  wait_gone "$owner"
  out=$(check_home "$home")
  assert_contains "$out" "wake-backstop: stranded" "a claim whose owner died must not keep the backstop clear"
  pass "backstop: a live open Stop-hook claim keeps it clear, and its owner's death strands the wakes again"
}

# The successor a pass-through leaves for main is a healthy watcher with no
# owner to deliver its close: watcher health alone is not a live cycle.
test_healthy_ownerless_watcher_does_not_clear() {
  local home out watcher
  home=$(make_home ownerless-watcher)
  seed_incident "$home"
  start_primary "$home"
  sleep 300 &
  watcher=$!
  printf '%s\n' "$watcher" >> "$PRIMARIES"
  mkdir -p "$home/state/.watch.lock"
  printf '%s\n' "$watcher" > "$home/state/.watch.lock/pid"
  identity_of "$watcher" > "$home/state/.watch.lock/pid-identity"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$home/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
  touch "$home/state/.last-watcher-beat"
  FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_watcher_healthy "$2/state" "$2/bin/fm-watch.sh" 300 "$2"' _ "$ROOT" "$home" \
    || fail "fixture: the left-for-main watcher must read healthy"
  out=$(check_home "$home")
  assert_contains "$out" "wake-backstop: stranded" "a healthy watcher without a live Stop-hook owner must not clear the backstop"
  kill "$watcher" 2>/dev/null
  pass "backstop: a healthy watcher with no live owner does not hide stranded wakes"
}

wait_gone() {  # <pid>
  local i=0
  while [ "$i" -lt 100 ] && kill -0 "$1" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  ! kill -0 "$1" 2>/dev/null
}

wait_for() {  # <polls of 0.1s> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

recorded_pid() { awk -F '\t' '{ print $1; exit }' "$1/state/.wake-backstop" 2>/dev/null; }

# --- the loop -------------------------------------------------------------------

DELIVER="$TMP_ROOT/deliver"
cat > "$DELIVER" <<'SH'
#!/usr/bin/env bash
n=$(( $(ls "$FM_HOME"/delivered.* 2>/dev/null | wc -l) + 1 ))
printf '%s\n' "$1" > "$FM_HOME/delivered.$n"
SH
chmod +x "$DELIVER"
deliveries() { find "$1" -maxdepth 1 -name 'delivered.*' 2>/dev/null | wc -l | tr -d ' '; }

test_loop_rings_an_idle_primary_once_and_touches_no_supervision_state() {
  local home out pid epoch_before left_before
  home=$(make_home loop)
  seed_incident "$home"
  start_primary "$home"
  epoch_before=$(cat "$home/state/.claude-autoarm-epoch")
  left_before=$(cat "$home/state/.supervision-host-left")
  out=$(FM_HOME="$home" FM_WAKE_BACKSTOP_TICK=1 FM_TEST_WAKE_BACKSTOP_DELIVER="$DELIVER" "$home/$BACKSTOP_REL" ensure)
  assert_contains "$out" "wake-backstop: started pid=" "ensure must start the loop"
  wait_for 100 test -s "$home/delivered.1" || fail "the loop never rang the idle primary: $(cat "$home/state/.wake-backstop.log" 2>/dev/null)"
  assert_grep 'firstmate wake backstop - 4 durable wake(s) have waited' "$home/delivered.1" "the doorbell must say what is stranded"
  assert_grep 'check: inactive-outcome' "$home/delivered.1" "the doorbell must name the oldest wake"
  assert_grep 'Run bin/fm-wake-drain.sh first' "$home/delivered.1" "the doorbell must direct the drain-first protocol"
  assert_grep 'do NOT run bin/fm-watch-arm.sh' "$home/delivered.1" "the doorbell must forbid a model re-arm"
  assert_grep '	stranded	' "$home/state/.wake-backstop.log" "the first stranded pass is only recorded"
  assert_grep '	delivered	' "$home/state/.wake-backstop.log" "the confirming pass delivers"
  [ "$(awk -F '\t' '$2 == "stranded" { s = NR } $2 == "delivered" && !d { d = NR } END { print (s < d) }' "$home/state/.wake-backstop.log")" = 1 ] \
    || fail "delivery must follow a confirming pass: $(cat "$home/state/.wake-backstop.log")"
  sleep 3
  expect_code 1 "$(deliveries "$home")" "a still-stranded wake must not be rung again inside the threshold"
  pid=$(recorded_pid "$home")
  out=$(FM_HOME="$home" FM_WAKE_BACKSTOP_TICK=1 FM_TEST_WAKE_BACKSTOP_DELIVER="$DELIVER" "$home/$BACKSTOP_REL" ensure)
  assert_contains "$out" "wake-backstop: running pid=$pid" "a second ensure for the same session keeps the one loop"
  [ ! -e "$home/state/.watch.lock" ] || fail "the backstop must never start a watcher"
  [ "$(cat "$home/state/.claude-autoarm-epoch")" = "$epoch_before" ] || fail "the backstop must not touch the auto-arm ledger"
  [ "$(cat "$home/state/.supervision-host-left")" = "$left_before" ] || fail "the backstop must not touch the host's left record"
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" = 4 ] || fail "the backstop must not consume wakes"
  : > "$home/primary.stop"
  wait_gone "$pid" || fail "the loop must exit when its session ends"
  assert_grep 'the session this loop served has ended' "$home/state/.wake-backstop.log" "the exit must be recorded"
  pass "backstop: the loop rings a stranded idle primary once, changes no supervision state, and ends with its session"
}

# A live session whose own Stop hook holds a fresh claim.
start_primary_with_claim() {  # <home>
  local home=$1 owner
  rm -f "$home/primary.pid" "$home/primary.stop"
  "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$1/state/.lock"
    sleep 300 &
    printf "%s\n" "$!" > "$1/owner.pid"
    printf "%s\n" "$$" > "$1/primary.pid"
    while [ ! -e "$1/primary.stop" ]; do sleep 0.2; done
    kill "$(cat "$1/owner.pid")" 2>/dev/null
  ' _ "$home" 2>/dev/null &
  printf '%s\n' "$!" >> "$PRIMARIES"
  wait_for 50 test -s "$home/primary.pid" || fail "fixture: the session did not start"
  owner=$(cat "$home/owner.pid")
  printf 'epoch=217 owner_pid=%s outcome=arming updated_at=%s\n%s\n' "$owner" "$(date +%s)" "$(identity_of "$owner")" \
    > "$home/state/.claude-autoarm-epoch"
}

test_loop_holds_while_a_stop_hook_claim_is_open() {
  local home out
  home=$(make_home loop-claim)
  seed_incident "$home"
  start_primary_with_claim "$home"
  out=$(FM_HOME="$home" FM_WAKE_BACKSTOP_TICK=1 FM_TEST_WAKE_BACKSTOP_DELIVER="$DELIVER" "$home/$BACKSTOP_REL" ensure)
  assert_contains "$out" "wake-backstop: started pid=" "ensure must start the loop"
  sleep 4
  expect_code 0 "$(deliveries "$home")" "an open Stop-hook claim owns delivery, so the backstop must not ring"
  kill "$(cat "$home/owner.pid")" 2>/dev/null
  wait_for 100 test -s "$home/delivered.1" || fail "the loop never rang once the claim's owner died: $(cat "$home/state/.wake-backstop.log" 2>/dev/null)"
  pass "backstop: the loop holds while a live Stop-hook claim is open and rings once it is gone"
}

test_new_session_replaces_the_loop_by_its_record() {
  local home out old new
  home=$(make_home replace)
  : > "$home/state/.wake-queue"
  start_primary "$home"
  out=$(FM_HOME="$home" FM_WAKE_BACKSTOP_TICK=1 "$home/$BACKSTOP_REL" ensure)
  assert_contains "$out" "wake-backstop: started pid=" "ensure must start the loop"
  wait_for 50 test -s "$home/state/.wake-backstop" || fail "the loop never recorded itself"
  old=$(recorded_pid "$home")
  # The session restarts: a new harness takes the lock.
  : > "$home/primary.stop"
  start_primary "$home"
  out=$(FM_HOME="$home" FM_WAKE_BACKSTOP_TICK=1 "$home/$BACKSTOP_REL" ensure)
  assert_contains "$out" "wake-backstop: started pid=" "a new session must get its own loop"
  wait_gone "$old" || fail "the loop bound to the ended session must stop"
  wait_for 50 bash -c '[ "$(awk -F "\t" "{ print \$1; exit }" "$1")" != "$2" ]' _ "$home/state/.wake-backstop" "$old" \
    || fail "the new loop never recorded itself"
  new=$(recorded_pid "$home")
  kill -0 "$new" 2>/dev/null || fail "the new loop is not running"
  [ "$(awk -F '\t' '{ print $3; exit }' "$home/state/.wake-backstop")" = "$(cat "$home/primary.pid")" ] \
    || fail "the new loop must be bound to the new session"
  FM_HOME="$home" "$home/$BACKSTOP_REL" stop
  wait_gone "$new" || fail "stop must end the recorded loop"
  [ ! -e "$home/state/.wake-backstop" ] || fail "stop must remove the record"
  pass "backstop: a new session replaces the loop through its record, and stop ends it"
}

# --- pane delivery with fake backend primitives ------------------------------------

test_pane_delivery_guards() {
  local home
  home=$(make_home pane-delivery)
  FM_HOME="$home" bash -c '
    set -u
    home=$1
    . "$home/bin/fm-wake-backstop.sh"
    . "$home/bin/fm-operational-input.sh"
    DELIVERY_LIBS=1
    SENT="$home/sent"
    fm_backend_target_exists() { [ "$FAKE_EXISTS" = 1 ]; }
    fm_backend_busy_state() { printf "%s" "$FAKE_BUSY"; }
    fm_backend_capture() { printf "%s\n" "$FAKE_SCREEN"; }
    fm_busy_lines_match() { grep -q "esc to interrupt"; }
    fm_backend_composer_state() { printf "%s" "$FAKE_COMPOSER"; }
    fm_backend_send_text_submit() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$SENT"; printf "%s" "$FAKE_SUBMIT"; }
    WAKE_COUNT=4 OLDEST_AGE=3700 OLDEST_REASON="check: inactive-outcome"
    expect() {  # <want-rc> <label>
      local rc=0
      deliver || rc=$?
      [ "$rc" = "$1" ] || { printf "not ok - %s: rc %s (%s)\n" "$2" "$rc" "$DELIVER_WHY" >&2; exit 1; }
    }
    FAKE_EXISTS=1 FAKE_BUSY=idle FAKE_SCREEN="> " FAKE_COMPOSER=empty FAKE_SUBMIT=empty
    unset FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND
    expect 3 "no proven pane"
    export FM_SUPERVISOR_BACKEND=rex FM_SUPERVISOR_TARGET=sess:block
    FAKE_EXISTS=0; expect 1 "a gone pane"; FAKE_EXISTS=1
    FAKE_BUSY=busy; expect 1 "a natively busy primary"; FAKE_BUSY=idle
    FAKE_SCREEN="thinking (esc to interrupt)"; expect 1 "a primary whose screen shows a running turn"; FAKE_SCREEN="> "
    FAKE_COMPOSER=pending; expect 1 "half-typed captain text"; FAKE_COMPOSER=unknown; expect 1 "an unreadable composer"; FAKE_COMPOSER=empty
    [ ! -e "$SENT" ] || { printf "not ok - a guarded delivery typed into the pane\n" >&2; exit 1; }
    FAKE_SUBMIT=pending; expect 1 "an unconfirmed submit"
    FAKE_SUBMIT=empty; expect 0 "an idle primary with an empty composer"
  ' _ "$home" || fail "a pane delivery guard misbehaved"
  [ "$(wc -l < "$home/sent" | tr -d ' ')" = 2 ] || fail "only the two unguarded attempts may type: $(cat "$home/sent")"
  local line doorbell kind
  line=$(tail -n 1 "$home/sent")
  [ "${line%%|*}" = rex ] || fail "the delivery must use the recorded backend: $line"
  doorbell=${line#*|*|}
  kind=$(printf '%s' "$doorbell" | FM_HOME="$home" "$ROOT/bin/fm-operational-input.sh" doorbell-kind) \
    || fail "a Claude primary must receive a record-backed doorbell: $doorbell"
  [ "$kind" = watcher ] || fail "the doorbell's record must be a watcher wake, got $kind"
  pass "backstop: pane delivery waits for an idle primary with an empty composer and rings a watcher doorbell"
}

# A host home's away posture is the record alone (no daemon flag), so the
# backstop still runs there; its doorbell must not read as the captain's return.
test_doorbell_under_an_away_record_is_not_a_return() {
  local home body
  home=$(make_home away-note)
  body=$(FM_HOME="$home" bash -c '. "$1/bin/fm-wake-backstop.sh"; WAKE_COUNT=1 OLDEST_AGE=900 OLDEST_REASON="check: x"; doorbell_body' _ "$home")
  case "$body" in *'away-posture record'*) fail "an attended doorbell must carry no away note: $body" ;; esac
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'watch the fleet' >/dev/null 2>&1 || fail "fixture: could not record the away posture"
  body=$(FM_HOME="$home" bash -c '. "$1/bin/fm-wake-backstop.sh"; WAKE_COUNT=1 OLDEST_AGE=900 OLDEST_REASON="check: x"; doorbell_body' _ "$home")
  assert_contains "$body" "not from the captain: it is not a return" "a doorbell under an away record must say it is not a return"
  start_primary "$home"
  [ "$(check_home "$home" | cut -d' ' -f2)" != inert ] || fail "an away record without the daemon flag must not make the backstop inert"
  pass "backstop: under an away record its doorbell says it is not the captain's return"
}

test_doorbell_under_an_away_record_is_not_a_return
test_incident_replay_is_stranded
test_inert_and_clear_cases
test_open_stop_hook_claim_is_clear
test_healthy_ownerless_watcher_does_not_clear
test_loop_rings_an_idle_primary_once_and_touches_no_supervision_state
test_loop_holds_while_a_stop_hook_claim_is_open
test_new_session_replaces_the_loop_by_its_record
test_pane_delivery_guards
