#!/usr/bin/env bash
# Process-level tests for automatic planned SecondMate transfer: selection
# without --to, sticky/exclusive authority, destination stop race, and
# failure rollback. Transfer lifecycle hooks replace endpoint operations, so
# no external harness ever launches.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FLEET="$ROOT/bin/fm-fleet.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-transfer-auto)
FROOT="$TMP_ROOT/fleet"
export FM_FLEET_ROOT=$FROOT
HOLDERS=""
cleanup() {
  for pid in $HOLDERS; do kill "$pid" >/dev/null 2>&1 || true; done
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

reasoning_live_test() { case "$(FM_HOME="$1" "$ROOT/bin/fm-lock.sh" status 2>/dev/null)" in "lock: held by live"*) return 0 ;; *) return 1 ;; esac; }
json_value() { python3 -c "import json,sys; print($1)"; }

add_lock() {  # <home>
  local home=$1 pid
  mkdir -p "$home/state"
  bash -c 'exec -a /opt/homebrew/bin/codex sleep 300' & pid=$!
  HOLDERS="$HOLDERS $pid"
  printf '%s\n' "$pid" > "$home/state/.lock"
  LAST_HOLDER=$pid
}

remove_lock() {  # <home> <pid>
  kill "$2" >/dev/null 2>&1 || true
  i=0
  while kill -0 "$2" >/dev/null 2>&1 && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
  rm -f "$1/state/.lock"
}

manager_for() {
  python3 - "$FROOT/fleet.json" "$1" <<'PY'
import json,sys
with open(sys.argv[1]) as handle: reg=json.load(handle)
print(next(row["manager"] for row in reg["assignments"] if row["secondmate"]==sys.argv[2] and row.get("state")=="active"))
PY
}

generation_for() {
  python3 - "$FROOT/fleet.json" "$1" <<'PY'
import json,sys
with open(sys.argv[1]) as handle: reg=json.load(handle)
print(next(row["generation"] for row in reg["assignments"] if row["secondmate"]==sys.argv[2] and row.get("state")=="active"))
PY
}

active_rows_for() {
  python3 - "$FROOT/fleet.json" "$1" <<'PY'
import json,sys
with open(sys.argv[1]) as handle: reg=json.load(handle)
print(sum(1 for row in reg["assignments"] if row["secondmate"]==sys.argv[2] and row.get("state")=="active"))
PY
}

tx_state() {
  python3 "$ROOT/bin/fm-fleet-transfer.py" state --journal "$1" | json_value 'json.load(sys.stdin)["state"]'
}

journal_count() {
  find "$FROOT/transactions" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l
}

newest_journal() {  # <name-substring> -> newest matching journal path or empty
  python3 - "$FROOT/transactions" "$1" <<'PY'
import glob, os, sys
paths = [p for p in glob.glob(os.path.join(sys.argv[1], "*.json")) if sys.argv[2] in os.path.basename(p)]
print(max(paths, key=os.path.getmtime) if paths else "")
PY
}

HOOK="$TMP_ROOT/hook.sh"
cat > "$HOOK" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$FM_HOOK_LOG"
SH
chmod +x "$HOOK"
FAIL_HOOK="$TMP_ROOT/fail-hook.sh"
cat > "$FAIL_HOOK" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAIL_HOOK"
CLOSE_HOOK="$TMP_ROOT/close-hook.sh"
cat > "$CLOSE_HOOK" <<'SH'
#!/usr/bin/env bash
home=$3
pid=$(cat "$home/state/.lock" 2>/dev/null || true)
[ -n "$pid" ] && printf 'close|%s\n' "$2" >> "$FM_HOOK_LOG"
[ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
rm -f "$home/state/.lock" "$home/state/.fleet-herdr-target"
SH
chmod +x "$CLOSE_HOOK"

"$FLEET" init >/dev/null || fail "auto transfer init"
for n in 1 2 3; do "$FLEET" manager register --id manager-$n --home "$FROOT/manager-$n" >/dev/null || fail "register manager-$n"; done
"$FLEET" owner register --secondmate harness --home "$FROOT/secondmates/harness" --projects AutoDev,dotcodex --domains harness >/dev/null || fail "register harness owner"
"$FLEET" owner register --secondmate paperclip --home "$FROOT/secondmates/paperclip" --projects paperclip --domains orchestration >/dev/null || fail "register paperclip owner"
for n in 1 2 3; do add_lock "$FROOT/manager-$n"; printf 'test:test\n' > "$FROOT/manager-$n/state/.fleet-herdr-target"; done
"$FLEET" assign --secondmate harness >/dev/null || fail "assign harness"
[ "$(manager_for harness)" = manager-1 ] || fail "harness did not land on manager-1"
"$FLEET" assign --secondmate paperclip >/dev/null || fail "assign paperclip"
[ "$(manager_for paperclip)" = manager-2 ] || fail "paperclip did not land on manager-2"

for sm in harness paperclip; do
  mhome="$FROOT/manager-$([ "$sm" = harness ] && echo 1 || echo 2)"
  mkdir -p "$mhome/data" "$mhome/state" "$FROOT/secondmates/$sm"
  printf '%s\n' '# SecondMates' "- $sm - S (home: $FROOT/secondmates/$sm; scope: s; projects: p; added 2026-09-13)" > "$mhome/data/secondmates.md"
  printf 'kind=secondmate\nhome=%s\nwindow=fake\n' "$FROOT/secondmates/$sm" > "$mhome/state/$sm.meta"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$mhome" > "$FROOT/secondmates/$sm/.fm-secondmate-parent"
done

export FM_HOOK_LOG="$TMP_ROOT/hooks.log"
export FM_FLEET_TRANSFER_STOP_HOOK=$HOOK
export FM_FLEET_TRANSFER_MANAGER_START_HOOK=$HOOK
export FM_FLEET_TRANSFER_SECONDMATE_START_HOOK=$HOOK
export FM_FLEET_TRANSFER_ROLLBACK_START_HOOK=$HOOK
export FM_FLEET_HERDR_CLOSE_HOOK=$CLOSE_HOOK

remove_lock "$FROOT/manager-1" "$(cat "$FROOT/manager-1/state/.lock")"

# Automatic selection picks the least-loaded healthy peer excluding the source.
out=$(FM_FLEET_ROOT=$FROOT "$FLEET" transfer begin --secondmate harness 2>&1); status=$?
expect_code 0 "$status" "automatic transfer failed: $out"
case "$out" in *"auto transfer: harness -> manager-3"*) ;; *) fail "selection was not announced deterministically: $out" ;; esac
case "$out" in *"active: harness -> manager-3"*) ;; *) fail "announced selection did not match the published transfer: $out" ;; esac
[ "$(manager_for harness)" = manager-3 ] || fail "automatic transfer did not choose least-loaded manager-3"
[ "$(generation_for harness)" = 2 ] || fail "automatic transfer did not publish generation 2"
[ "$(active_rows_for harness)" = 1 ] || fail "automatic transfer broke exclusive authority"
[ -f "$FROOT/manager-3/state/harness.meta" ] && [ ! -f "$FROOT/manager-1/state/harness.meta" ] || fail "automatic transfer did not move endpoint metadata"
grep -q "parent_home=$FROOT/manager-3" "$FROOT/secondmates/harness/.fm-secondmate-parent" || fail "automatic transfer did not move the parent binding"
grep -q "$FROOT/manager-1|harness|stop-secondmate" "$FM_HOOK_LOG" || fail "automatic transfer did not stop the source SecondMate"
grep -q "$FROOT/manager-3|manager-3|start-manager" "$FM_HOOK_LOG" || fail "automatic transfer did not restart the destination manager"
grep -q "$FROOT/manager-3|harness|start-secondmate" "$FM_HOOK_LOG" || fail "automatic transfer did not relaunch the SecondMate"

# A second automatic move excludes the stopped source and stays exclusive.
out=$(FM_FLEET_ROOT=$FROOT "$FLEET" transfer begin --secondmate harness 2>&1); status=$?
expect_code 0 "$status" "second automatic transfer failed: $out"
[ "$(manager_for harness):$(generation_for harness):$(active_rows_for harness)" = manager-2:3:1 ] || fail "second automatic transfer was not exclusive and generation-safe"
grep -q "parent_home=$FROOT/manager-2" "$FROOT/secondmates/harness/.fm-secondmate-parent" || fail "second automatic transfer did not move the parent binding"

# Destination stop race: the destination goes live after the stop, before apply.
add_lock "$FROOT/manager-3"
printf 'test:test\n' > "$FROOT/manager-3/state/.fleet-herdr-target"
RACE_STOP="$TMP_ROOT/race-stop.sh"
cat > "$RACE_STOP" <<SH
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$FM_HOOK_LOG"
bash -c 'exec -a /opt/homebrew/bin/codex sleep 300' >/dev/null 2>&1 < /dev/null & pid=\$!
printf '%s\n' "\$pid" > "$FROOT/manager-3/state/.lock"
printf '%s\n' "\$pid" > "$TMP_ROOT/race.pid"
SH
chmod +x "$RACE_STOP"
export FM_FLEET_TRANSFER_STOP_HOOK=$RACE_STOP
journals_before=$(journal_count)
out=$(FM_FLEET_ROOT=$FROOT "$FLEET" transfer begin --secondmate paperclip 2>&1); status=$?
[ "$status" -ne 0 ] || fail "transfer accepted a destination that went live after stop"
case "$out" in *"after endpoint stop"*) ;; *) fail "race refusal misnames its window: $out" ;; esac
[ "$(journal_count)" -eq "$((journals_before + 1))" ] || fail "raced transfer did not journal exactly one transaction"
race_tx=$(newest_journal paperclip)
[ -n "$race_tx" ] || fail "raced transfer left no journal"
[ "$(tx_state "$race_tx")" = abandoned ] || fail "raced transfer did not retire its reservation"
[ "$(manager_for paperclip):$(generation_for paperclip)" = manager-2:1 ] || fail "raced transfer moved records before the endpoint check"
grep -q "parent_home=$FROOT/manager-2" "$FROOT/secondmates/paperclip/.fm-secondmate-parent" || fail "raced transfer moved the parent binding"
grep -q "$FROOT/manager-2|paperclip|start-secondmate" "$FM_HOOK_LOG" || fail "raced transfer did not relaunch the source SecondMate"
export FM_FLEET_TRANSFER_STOP_HOOK=$HOOK
race_pid=$(cat "$TMP_ROOT/race.pid"); kill "$race_pid" >/dev/null 2>&1 || true
rm -f "$FROOT/manager-3/state/.lock"

# No healthy peer means an explicit refusal with no journal.
journals_before=$(journal_count)
out=$(FM_FLEET_ROOT=$FROOT "$FLEET" transfer begin --secondmate paperclip 2>&1); status=$?
[ "$status" -ne 0 ] || fail "transfer selected a destination with no healthy manager"
case "$out" in *"no healthy reasoning manager"*) ;; *) fail "empty-pool refusal wrong: $out" ;; esac
[ "$(journal_count)" -eq "$journals_before" ] || fail "refused transfer journaled a transaction"

# Invalid source preconditions refuse before any manager stops.
add_lock "$FROOT/manager-1"; printf 'test:test\n' > "$FROOT/manager-1/state/.fleet-herdr-target"; live_1=$LAST_HOLDER
mkdir -p "$FROOT/manager-2/state/pending-replies"
printf 'phase=escalated\n' > "$FROOT/manager-2/state/pending-replies/open1"
: > "$FM_HOOK_LOG"; journals_before=$(journal_count)
out=$(FM_FLEET_ROOT=$FROOT "$FLEET" transfer begin --secondmate harness 2>&1); status=$?
[ "$status" -ne 0 ] || fail "automatic transfer ignored an open pending reply"
[ ! -s "$FM_HOOK_LOG" ] || fail "open pending reply still stopped an endpoint: $(cat "$FM_HOOK_LOG")"
kill -0 "$live_1" 2>/dev/null && [ -f "$FROOT/manager-1/state/.lock" ] || fail "open pending reply stopped the selected manager"
[ "$(journal_count)" -eq "$journals_before" ] || fail "refused preflight reserved a manager"
rm -f "$FROOT/manager-2/state/pending-replies/open1"

# A failure after the destination stops restarts it and retires the reservation.
: > "$FM_HOOK_LOG"
export FM_FLEET_TRANSFER_STOP_HOOK=$FAIL_HOOK
out=$(FM_FLEET_ROOT=$FROOT "$FLEET" transfer begin --secondmate paperclip 2>&1); status=$?
[ "$status" -ne 0 ] || fail "automatic transfer hid a SecondMate stop failure"
grep -q '^close|manager-1$' "$FM_HOOK_LOG" || fail "post-stop failure fixture did not stop manager-1: $out"
grep -q "$FROOT/manager-1|manager-1|start-manager" "$FM_HOOK_LOG" || fail "post-stop failure did not restart the stopped destination: $out"
[ "$(tx_state "$(newest_journal paperclip)")" = abandoned ] || fail "post-stop failure left its reservation held"
[ "$(manager_for paperclip):$(generation_for paperclip)" = manager-2:1 ] || fail "post-stop failure changed the assignment"
grep -q "parent_home=$FROOT/manager-2" "$FROOT/secondmates/paperclip/.fm-secondmate-parent" || fail "post-stop failure moved the parent binding"
export FM_FLEET_TRANSFER_STOP_HOOK=$HOOK

# Concurrent automatic transfers for different SecondMates reserve different managers.
SLOW_STOP="$TMP_ROOT/slow-stop.sh"
printf '#!/usr/bin/env bash\nsleep 1\n' > "$SLOW_STOP"; chmod +x "$SLOW_STOP"
for n in 1 3; do add_lock "$FROOT/manager-$n"; printf 'test:test\n' > "$FROOT/manager-$n/state/.fleet-herdr-target"; done
: > "$FM_HOOK_LOG"
FM_FLEET_TRANSFER_STOP_HOOK=$SLOW_STOP "$FLEET" transfer begin --secondmate harness > "$TMP_ROOT/c1.out" 2>&1 & c1=$!
FM_FLEET_TRANSFER_STOP_HOOK=$SLOW_STOP "$FLEET" transfer begin --secondmate paperclip > "$TMP_ROOT/c2.out" 2>&1 & c2=$!
wait "$c1"; s1=$?; wait "$c2"; s2=$?
[ "$s1:$s2" = 0:0 ] || fail "concurrent automatic transfers failed: $(cat "$TMP_ROOT/c1.out" "$TMP_ROOT/c2.out")"
pair=$(printf '%s\n' "$(manager_for harness)" "$(manager_for paperclip)" | sort | tr '\n' ' ')
[ "$pair" = "manager-1 manager-3 " ] || fail "concurrent automatic transfers shared a destination: $pair"
[ "$(grep -c '^close|' "$FM_HOOK_LOG")" = 2 ] && [ "$(grep -c '^close|manager-1$' "$FM_HOOK_LOG")" = 1 ] || fail "concurrent transfers stopped a manager twice: $(cat "$FM_HOOK_LOG")"

# Every later failure after reserving manager-2 retires that reservation and restarts manager-2.
pc_home="$FROOT/$(manager_for paperclip)"
arm_manager_2() { add_lock "$FROOT/manager-2"; printf 'test:test\n' > "$FROOT/manager-2/state/.fleet-herdr-target"; : > "$FM_HOOK_LOG"; }
assert_released() {  # <label> <journal>
  [ "$(tx_state "$2")" = abandoned ] || fail "$1 leaked its reservation"
  grep -q "$FROOT/manager-2|manager-2|start-manager" "$FM_HOOK_LOG" || fail "$1 left the stopped destination down"
  [ "$(manager_for paperclip)" = "$(basename "$pc_home")" ] || fail "$1 changed the assignment"
  grep -q "parent_home=$pc_home" "$FROOT/secondmates/paperclip/.fm-secondmate-parent" || fail "$1 moved the parent binding"
}

# Fleet-lock timeout at the record claim.
LOCK_STOP="$TMP_ROOT/lock-stop.sh"
cat > "$LOCK_STOP" <<SH
#!/usr/bin/env bash
python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"a"); fcntl.flock(f,fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(60)' "$FROOT/.fleet.lock" "$TMP_ROOT/held" >/dev/null 2>&1 < /dev/null &
printf '%s\n' "\$!" > "$TMP_ROOT/lock-holder.pid"
while [ ! -e "$TMP_ROOT/held" ]; do sleep 0.05; done
SH
chmod +x "$LOCK_STOP"
arm_manager_2
FM_FLEET_TRANSFER_STOP_HOOK=$LOCK_STOP "$FLEET" transfer begin --secondmate paperclip > "$TMP_ROOT/lock.out" 2>&1 & lock_pid=$!
i=0; while ! grep -q 'registry is locked' "$TMP_ROOT/lock.out" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.05; i=$((i + 1)); done
kill "$(cat "$TMP_ROOT/lock-holder.pid")" >/dev/null 2>&1 || true; rm -f "$TMP_ROOT/held"
wait "$lock_pid"; status=$?; out=$(cat "$TMP_ROOT/lock.out")
[ "$status" -ne 0 ] || fail "transfer ignored a fleet-lock timeout: $out"
case "$out" in *"registry is locked"*"abandoned before moving records"*) ;; *) fail "lock timeout was not released: $out" ;; esac
assert_released "fleet-lock timeout" "$(newest_journal paperclip)"
grep -q "$pc_home|paperclip|start-secondmate" "$FM_HOOK_LOG" || fail "fleet-lock timeout left the source SecondMate stopped"

# SIGTERM while the SecondMate stop hook runs.
TERM_STOP="$TMP_ROOT/term-stop.sh"
printf '#!/usr/bin/env bash\n: > "%s"\nsleep 1\n' "$TMP_ROOT/term.ready" > "$TERM_STOP"; chmod +x "$TERM_STOP"
arm_manager_2; rm -f "$TMP_ROOT/term.ready"
FM_FLEET_TRANSFER_STOP_HOOK=$TERM_STOP "$FLEET" transfer begin --secondmate paperclip > "$TMP_ROOT/term.out" 2>&1 & term_pid=$!
i=0; while [ ! -e "$TMP_ROOT/term.ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
kill -TERM "$term_pid"
if wait "$term_pid"; then fail "terminated transfer reported success"; fi
assert_released "terminated transfer" "$(newest_journal paperclip)"

# An owner-record move failure keeps the journal for rollback, which restarts the stopped destination.
BREAK_STOP="$TMP_ROOT/break-stop.sh"
printf '#!/usr/bin/env bash\nmkdir -p "%s"\n' "$FROOT/manager-2/state/paperclip.meta" > "$BREAK_STOP"; chmod +x "$BREAK_STOP"
arm_manager_2
out=$(FM_FLEET_TRANSFER_STOP_HOOK=$BREAK_STOP "$FLEET" transfer begin --secondmate paperclip 2>&1); status=$?
[ "$status" -ne 0 ] || fail "transfer hid an owner-record move failure"
broken=$(newest_journal paperclip)
[ "$(tx_state "$broken")" = preparing ] || fail "record-move failure abandoned a transfer whose records may have moved"
rmdir "$FROOT/manager-2/state/paperclip.meta"
: > "$FM_HOOK_LOG"
out=$("$FLEET" transfer rollback --transaction "$(basename "$broken" .json)" 2>&1) || fail "rollback of failed record move: $out"
grep -q "$FROOT/manager-2|manager-2|start-manager" "$FM_HOOK_LOG" || fail "rollback left the destination stopped by the transfer down"
[ "$(manager_for paperclip)" = "$(basename "$pc_home")" ] || fail "rollback changed the assignment"
! grep -q '^- paperclip ' "$FROOT/manager-2/data/secondmates.md" 2>/dev/null || fail "rollback left the destination route"

# A signal after the record claim commits preserves the stopped endpoints for recovery.
REG_HOLD="$TMP_ROOT/reg-hold.sh"
cat > "$REG_HOLD" <<'SH'
#!/usr/bin/env bash
STATE="$1/state"
. "$FM_HOLD_ROOT/bin/fm-wake-lib.sh"
for home in "$@"; do mkdir -p "$home/state"; fm_lock_acquire_wait "$home/state/.secondmate-registry.lock"; done
: > "$FM_HOLD_READY"
while [ ! -e "$FM_HOLD_RELEASE" ]; do sleep 0.05; done
for home in "$@"; do fm_lock_release "$home/state/.secondmate-registry.lock"; done
SH
chmod +x "$REG_HOLD"
hold_registries() {  # <home>...
  rm -f "$TMP_ROOT/hold.ready" "$TMP_ROOT/hold.release"
  FM_HOLD_ROOT=$ROOT FM_HOLD_READY="$TMP_ROOT/hold.ready" FM_HOLD_RELEASE="$TMP_ROOT/hold.release" "$REG_HOLD" "$@" >/dev/null 2>&1 & hold_pid=$!
  i=0; while [ ! -e "$TMP_ROOT/hold.ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$TMP_ROOT/hold.ready" ] || fail "registry lock holder did not start"
}
release_registries() { : > "$TMP_ROOT/hold.release"; wait "$hold_pid" 2>/dev/null; }
start_claimed_transfer() {  # <secondmate> -> sets claim_pid and claim_tx once the claim row commits
  : > "$FM_HOOK_LOG"
  "$FLEET" transfer begin --secondmate "$1" > "$TMP_ROOT/claim.out" 2>&1 & claim_pid=$!
  claim_tx=""; i=0
  while [ "$i" -lt 200 ]; do
    claim_tx=$(sed -n 's/.*(transaction \(.*\))$/\1/p' "$TMP_ROOT/claim.out")
    [ -n "$claim_tx" ] && python3 - "$FROOT/fleet.json" "$claim_tx" <<'PY' && return 0
import json, sys
with open(sys.argv[1]) as handle: reg = json.load(handle)
sys.exit(0 if any(row.get("transaction") == sys.argv[2] for row in reg.get("transfers", [])) else 1)
PY
    sleep 0.05; i=$((i + 1))
  done
  fail "transfer never committed its record claim: $(cat "$TMP_ROOT/claim.out")"
}
assert_preserved() {  # <label> <expected-journal-state>
  [ "$(tx_state "$FROOT/transactions/$claim_tx.json")" = "$2" ] || fail "$1 did not keep the journal recoverable: $(cat "$TMP_ROOT/claim.out")"
  ! grep -q 'start-manager\|start-secondmate' "$FM_HOOK_LOG" || fail "$1 restarted an authority after the claim: $(cat "$FM_HOOK_LOG")"
  case "$(cat "$TMP_ROOT/claim.out")" in *"recover or rollback $claim_tx"*) ;; *) fail "$1 printed no recovery hint: $(cat "$TMP_ROOT/claim.out")" ;; esac
}

# TERM after the claim commits but before records move.
src_home=$pc_home
arm_manager_2
hold_registries "$src_home" "$FROOT/manager-2"
start_claimed_transfer paperclip
kill -TERM "$claim_pid"; pkill -TERM -P "$claim_pid" 2>/dev/null
if wait "$claim_pid"; then fail "transfer terminated after its claim reported success"; fi
release_registries
assert_preserved "claim-time TERM" preparing
grep -q "parent_home=$src_home" "$FROOT/secondmates/paperclip/.fm-secondmate-parent" || fail "claim-time TERM moved records"
if reasoning_live_test "$FROOT/manager-2" || reasoning_live_test "$src_home"; then fail "claim-time TERM left a live authority"; fi
out=$("$FLEET" transfer recover --transaction "$claim_tx" 2>&1) || fail "claimed transfer was not recoverable: $out"
[ "$(manager_for paperclip)" = manager-2 ] || fail "recovery of claimed transfer did not publish"
grep -q "parent_home=$FROOT/manager-2" "$FROOT/secondmates/paperclip/.fm-secondmate-parent" || fail "recovery of claimed transfer did not move the binding"

# TERM while records move: the move finishes and stays recoverable, with no endpoint restarted.
add_lock "$src_home"; printf 'test:test\n' > "$src_home/state/.fleet-herdr-target"
hold_registries "$src_home" "$FROOT/manager-2"
start_claimed_transfer paperclip
kill -TERM "$claim_pid"
release_registries
if wait "$claim_pid"; then fail "transfer terminated during record move reported success"; fi
assert_preserved "record-move TERM" records-ready
grep -q "parent_home=$src_home" "$FROOT/secondmates/paperclip/.fm-secondmate-parent" || fail "record-move TERM did not finish moving records"
! grep -q '^- paperclip ' "$FROOT/manager-2/data/secondmates.md" || fail "record-move TERM left two parent routes"
if reasoning_live_test "$FROOT/manager-2" || reasoning_live_test "$src_home"; then fail "record-move TERM left a live authority"; fi
out=$("$FLEET" transfer recover --transaction "$claim_tx" 2>&1) || fail "moved transfer was not recoverable: $out"
[ "$(manager_for paperclip)" = "$(basename "$src_home")" ] || fail "recovery of moved transfer did not publish"

# An unclaimed stale journal never gains mutation authority, even after a newer transfer succeeds.
stale_tx=stale-unclaimed
stale_journal="$FROOT/transactions/$stale_tx.json"
python3 "$ROOT/bin/fm-fleet-transfer.py" prepare "$FROOT/fleet.json" --secondmate paperclip --manager manager-2 \
  --source-home "$src_home" --transaction "$stale_tx" --journal "$stale_journal" >/dev/null || fail "prepare stale journal fixture"
for n in 1 3; do [ "$FROOT/manager-$n" = "$src_home" ] || newer=manager-$n; done
out=$("$FLEET" transfer begin --secondmate paperclip --to "$newer" 2>&1) || fail "newer transfer after stale journal: $out"
records_digest() {
  python3 - "$FROOT" <<'PY'
import glob, hashlib, os, sys
root = sys.argv[1]
paths = [os.path.join(root, "fleet.json"), os.path.join(root, "secondmates/paperclip/.fm-secondmate-parent")]
paths += sorted(glob.glob(os.path.join(root, "manager-*/data/secondmates.md")) + glob.glob(os.path.join(root, "manager-*/state/paperclip.*")))
print(hashlib.sha256(b"".join(p.encode() + open(p, "rb").read() for p in paths)).hexdigest())
PY
}
before=$(records_digest); : > "$FM_HOOK_LOG"
if "$FLEET" transfer rollback --transaction "$stale_tx" >/dev/null 2>&1; then fail "rollback accepted an unclaimed stale journal"; fi
if "$FLEET" transfer recover --transaction "$stale_tx" >/dev/null 2>&1; then fail "recover accepted an unclaimed stale journal"; fi
[ "$(records_digest)" = "$before" ] || fail "stale journal rewrote owner records"
[ ! -s "$FM_HOOK_LOG" ] || fail "stale journal ran an endpoint lifecycle action: $(cat "$FM_HOOK_LOG")"
[ "$(manager_for paperclip)" = "$newer" ] || fail "stale journal changed the newer assignment"
out=$("$FLEET" transfer abandon --transaction "$stale_tx" 2>&1) || fail "abandon of stale journal: $out"
[ "$(tx_state "$stale_journal")" = abandoned ] || fail "abandon did not retire the stale reservation"
[ "$(records_digest)" = "$before" ] || fail "abandon rewrote owner records"
if "$FLEET" transfer abandon --transaction "$claim_tx" >/dev/null 2>&1; then fail "abandon accepted a claimed transfer"; fi

pass "automatic planned transfer reserves, stays exclusive, refuses races, and restarts on failure"
