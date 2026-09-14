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
[ "$(tx_state "$race_tx")" = preparing ] || fail "raced transfer journal is not stuck at preparing"
[ "$(manager_for paperclip):$(generation_for paperclip)" = manager-2:1 ] || fail "raced transfer moved records before the endpoint check"
grep -q "parent_home=$FROOT/manager-2" "$FROOT/secondmates/paperclip/.fm-secondmate-parent" || fail "raced transfer moved the parent binding"
export FM_FLEET_TRANSFER_STOP_HOOK=$HOOK

# Rollback of the raced transaction restores with the registry untouched.
race_pid=$(cat "$TMP_ROOT/race.pid"); kill "$race_pid" >/dev/null 2>&1 || true
rm -f "$FROOT/manager-3/state/.lock"
race_tx_name=$(basename "$race_tx" .json)
out=$(FM_FLEET_ROOT=$FROOT "$FLEET" transfer rollback --transaction "$race_tx_name" 2>&1); status=$?
expect_code 0 "$status" "rollback of raced transfer failed: $out"
[ "$(tx_state "$race_tx")" = rolled-back ] || fail "raced journal was not marked rolled-back"
[ "$(manager_for paperclip):$(generation_for paperclip)" = manager-2:1 ] || fail "rollback changed an unmoved assignment"
grep -q "parent_home=$FROOT/manager-2" "$FROOT/secondmates/paperclip/.fm-secondmate-parent" || fail "rollback moved the parent binding"
grep -q "$FROOT/manager-2|paperclip|start-secondmate" "$FM_HOOK_LOG" || fail "rollback did not relaunch the source SecondMate"

# No healthy peer means an explicit refusal with no journal.
journals_before=$(journal_count)
out=$(FM_FLEET_ROOT=$FROOT "$FLEET" transfer begin --secondmate paperclip 2>&1); status=$?
[ "$status" -ne 0 ] || fail "transfer selected a destination with no healthy manager"
case "$out" in *"no healthy reasoning manager"*) ;; *) fail "empty-pool refusal wrong: $out" ;; esac
[ "$(journal_count)" -eq "$journals_before" ] || fail "refused transfer journaled a transaction"

pass "automatic planned transfer selects, stays exclusive, refuses races, and rolls back"
