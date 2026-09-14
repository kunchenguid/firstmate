#!/usr/bin/env bash
# Process and transaction tests for fleet registry schema version 2.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FLEET="$ROOT/bin/fm-fleet.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet)
FROOT="$TMP_ROOT/fleet"
export FM_FLEET_ROOT=$FROOT
export FM_FLEET_BACKEND=nohup
export FM_FLEET_POLL=1
HOLDERS=""
LAST_HOLDER=""
holder_2=""

cleanup() {
  "$FLEET" stop --all >/dev/null 2>&1 || true
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

register_manager() {
  "$FLEET" manager register --id "$1" --home "$FROOT/homes/$1" >/dev/null
}

register_owner() {
  "$FLEET" owner register --secondmate "$1" --home "$FROOT/secondmates/$1" \
    --projects "$2" --domains "$3" >/dev/null
}

manager_for() {
  python3 - "$FROOT/fleet.json" "$1" <<'PY'
import json,sys
with open(sys.argv[1]) as handle: reg=json.load(handle)
print(next(row["manager"] for row in reg["assignments"] if row["secondmate"]==sys.argv[2]))
PY
}

generation_for() {
  python3 - "$FROOT/fleet.json" "$1" <<'PY'
import json,sys
with open(sys.argv[1]) as handle: reg=json.load(handle)
print(next(row["generation"] for row in reg["assignments"] if row["secondmate"]==sys.argv[2]))
PY
}

"$FLEET" init >/dev/null || fail "schema-v2 init"
for n in 1 2 3 4; do register_manager "manager-$n" || fail "register manager-$n"; done
register_owner harness 'AutoDev,dotcodex' harness || fail "register harness owner"
register_owner paperclip paperclip orchestration || fail "register paperclip owner"
register_owner interview interview interview || fail "register interview owner"
register_owner financials financials markets || fail "register financials owner"
"$FLEET" validate >/dev/null || fail "four-manager registry validates"

python3 - "$FROOT/fleet.json" <<'PY' || fail "manager rows contain semantic ownership"
import json,sys
with open(sys.argv[1]) as handle: reg=json.load(handle)
assert all(set(row)=={"id","home"} for row in reg["managers"])
PY
if "$FLEET" manager register --id manager-1 --home "$FROOT/homes/duplicate" >/dev/null 2>&1; then fail "duplicate manager id replaced a durable home"; fi
if "$FLEET" manager register --id manager-x --home "$FROOT/homes/manager-1" >/dev/null 2>&1; then fail "duplicate manager home was accepted"; fi
if "$FLEET" owner register --secondmate duplicate --home "$FROOT/secondmates/duplicate" --projects AutoDev >/dev/null 2>&1; then fail "duplicate project owner was accepted"; fi

# Four process-level capacity daemons stay isolated through wait, crash, and restart.
"$FLEET" start >/dev/null || fail "start four capacity daemons"
for n in 1 2 3 4; do
  pid=$(cat "$FROOT/homes/manager-$n/state/.fleet-manager.pid" 2>/dev/null || true)
  if [ -z "$pid" ] || ! kill -0 "$pid" >/dev/null 2>&1; then fail "manager-$n daemon is not live"; fi
done
if "$FLEET" start --managers manager-1 >/dev/null 2>&1; then fail "duplicate live manager authority was accepted"; fi
"$FLEET" set-wait manager-1 --on
states=$("$FLEET" status --json)
[ "$(printf '%s' "$states" | json_value 'next(r["state"] for r in json.load(sys.stdin)["managers"] if r["manager"]=="manager-1")')" = capacity-ready ] || fail "daemon wait marker masquerades as reasoning wait"
[ "$(printf '%s' "$states" | json_value 'next(r["state"] for r in json.load(sys.stdin)["managers"] if r["manager"]=="manager-4")')" = capacity-ready ] || fail "one manager wait affected another daemon"
crashed=$(cat "$FROOT/homes/manager-2/state/.fleet-manager.pid")
kill -9 "$crashed" >/dev/null 2>&1 || fail "crash manager-2"
sleep 1
[ "$("$FLEET" status --json | json_value 'next(r["state"] for r in json.load(sys.stdin)["managers"] if r["manager"]=="manager-2")')" = dead ] || fail "crashed manager was not isolated as dead"
"$FLEET" restart manager-2 >/dev/null || fail "restart crashed manager"
"$FLEET" stop --all >/dev/null || fail "stop capacity daemons"
"$FLEET" set-wait manager-1 --off

# A daemon is capacity-ready only. Assignment requires a live reasoning lock.
if "$FLEET" assign --secondmate harness >/dev/null 2>&1; then fail "assignment accepted a heartbeat-only manager"; fi
for n in 1 2 3 4; do add_lock "$FROOT/homes/manager-$n"; eval "holder_$n=$LAST_HOLDER"; done
"$FLEET" assign --secondmate harness >/dev/null || fail "assign harness"
[ "$(manager_for harness)" = manager-1 ] || fail "least-loaded tie did not choose manager-1"
[ "$(generation_for harness)" = 1 ] || fail "initial generation is not one"
"$FLEET" assign --secondmate harness >/dev/null || fail "sticky reassignment"
[ "$(manager_for harness):$(generation_for harness)" = manager-1:1 ] || fail "healthy assignment was not sticky"
"$FLEET" assign --secondmate paperclip >/dev/null || fail "assign paperclip"
[ "$(manager_for paperclip)" = manager-2 ] || fail "least-loaded choice ignored assignment load"
"$FLEET" set-wait manager-3 --on
"$FLEET" assign --secondmate interview >/dev/null || fail "model-wait manager should remain eligible"
[ "$(manager_for interview)" = manager-3 ] || fail "model-wait manager was not selected deterministically"
"$FLEET" set-wait manager-3 --off

"$FLEET" assign --secondmate financials >/dev/null & assign_one=$!
"$FLEET" assign --secondmate financials >/dev/null & assign_two=$!
wait "$assign_one" || fail "first colliding assignment failed"
wait "$assign_two" || fail "second colliding assignment failed"
[ "$(manager_for financials):$(generation_for financials)" = manager-4:1 ] || fail "colliding assignment duplicated or skipped a generation"

route=$("$FLEET" route --project AutoDev --issue MIX-900)
case "$route" in *"harness -> manager-1 (generation 1)"*) ;; *) fail "complete route missing: $route" ;; esac
if "$FLEET" route --project AutoDev --domain unknown >/dev/null 2>&1; then fail "known project hid an unknown semantic routing key"; fi
"$FLEET" route --project unknown --issue MIX-X >/dev/null 2>&1 || true
"$FLEET" route --project unknown --issue MIX-X >/dev/null 2>&1 || true
[ "$("$FLEET" status --json | json_value 'sum(1 for r in json.load(sys.stdin)["unassigned"] if r.get("project")=="unknown")')" = 1 ] || fail "unknown route duplicated triage"
[ "$("$FLEET" status --json | json_value 'next(r["attempts"] for r in json.load(sys.stdin)["unassigned"] if r.get("project")=="unknown")')" = 2 ] || fail "triage attempt count"

"$FLEET" dep add --owner harness --from MIX-900 --needs paperclip --task PC-1
deps=$("$FLEET" dep list)
case "$deps" in *owner_secondmate*) ;; *) fail "dependency owner is not SecondMate-keyed" ;; esac
case "$deps" in *needs_secondmate*) ;; *) fail "dependency target is not SecondMate-keyed" ;; esac
"$FLEET" dep "done" --owner harness --from MIX-900

# Recovery refuses a possibly live manager, then selects the least-loaded healthy peer.
if "$FLEET" recover --secondmate paperclip >/dev/null 2>&1; then fail "recovery replaced a live reasoning manager"; fi
remove_lock "$FROOT/homes/manager-2" "$holder_2"
"$FLEET" recover --secondmate paperclip >/dev/null || fail "recover paperclip after manager death"
[ "$(manager_for paperclip):$(generation_for paperclip)" = manager-1:2 ] || fail "recovery was not deterministic or generation-safe"

python3 - "$FROOT/fleet.json" <<'PY' || fail "assignment crossed the root completion boundary"
import json,sys
with open(sys.argv[1]) as handle: reg=json.load(handle)
for row in reg["assignments"]: assert not ({"done","reviewed","landed","accepted","complete"} & set(row))
PY
if "$FLEET" status | grep -Ei 'complete|landed|reviewed|accepted' >/dev/null 2>&1; then fail "fleet status claimed root completion"; fi

# Herdr start launches an interactive harness and waits for its home lock.
HROOT="$TMP_ROOT/herdr"
HERDR_LOG="$TMP_ROOT/herdr-hooks.log"
HERDR_LAUNCH="$TMP_ROOT/herdr-launch.sh"
cat > "$HERDR_LAUNCH" <<'SH'
#!/usr/bin/env bash
home=$3
bash -c 'exec -a /opt/homebrew/bin/codex sleep 300' >/dev/null 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$home/state/.lock"
printf 'test:test\n' > "$home/state/.fleet-herdr-target"
printf '%s|%s|%s|%s\n' "$2" "$4" "$5" "$6" >> "$FM_TEST_HERDR_LOG"
SH
chmod +x "$HERDR_LAUNCH"
HERDR_CLOSE="$TMP_ROOT/herdr-close.sh"
cat > "$HERDR_CLOSE" <<'SH'
#!/usr/bin/env bash
home=$3
pid=$(cat "$home/state/.lock")
kill "$pid" >/dev/null 2>&1 || true
rm -f "$home/state/.lock" "$home/state/.fleet-herdr-target"
SH
chmod +x "$HERDR_CLOSE"
FM_FLEET_ROOT=$HROOT "$FLEET" init >/dev/null
FM_FLEET_ROOT=$HROOT "$FLEET" manager register --id manager-1 --home "$HROOT/manager-1" >/dev/null
FM_TEST_HERDR_LOG=$HERDR_LOG FM_FLEET_ROOT=$HROOT FM_FLEET_BACKEND=herdr \
  FM_FLEET_MANAGER_HARNESS=codex FM_FLEET_HERDR_LAUNCH_HOOK=$HERDR_LAUNCH \
  FM_FLEET_HERDR_CLOSE_HOOK=$HERDR_CLOSE "$FLEET" start >/dev/null || fail "interactive Herdr start"
grep -q 'manager-1|codex|FirstMate 1|Manager 1' "$HERDR_LOG" || fail "Herdr labels or harness launch are wrong"
[ "$(FM_FLEET_ROOT=$HROOT "$FLEET" status --json | json_value 'json.load(sys.stdin)["managers"][0]["authority"]')" = reasoning ] || fail "Herdr start returned before reasoning lock"
FM_FLEET_ROOT=$HROOT FM_FLEET_BACKEND=herdr FM_FLEET_HERDR_CLOSE_HOOK=$HERDR_CLOSE \
  FM_FLEET_HERDR_LAUNCH_HOOK=$HERDR_LAUNCH "$FLEET" stop --all >/dev/null || fail "interactive Herdr stop"

# Version-1 migration relabels homes, lifts confirmed bindings, and retains ambiguity.
MROOT="$TMP_ROOT/migrate"
mkdir -p "$MROOT/old-a/data" "$MROOT/old-c/data" "$MROOT/sm-a" "$MROOT/sm-c"
printf '%s\n' '# SecondMates' '- sm-a - A (home: '"$MROOT"'/sm-a; scope: a; projects: p-a; added 2026-09-13)' > "$MROOT/old-a/data/secondmates.md"
printf '%s\n' '# SecondMates' '- sm-c - C (home: '"$MROOT"'/sm-c; scope: c; projects: p-c; added 2026-09-13)' > "$MROOT/old-c/data/secondmates.md"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MROOT/old-a" > "$MROOT/sm-a/.fm-secondmate-parent"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MROOT/old-c" > "$MROOT/sm-c/.fm-secondmate-parent"
cat > "$MROOT/fleet.json" <<EOF
{"version":1,"managers":[
 {"id":"old-a","home":"$MROOT/old-a","scope":"a","secondmates":["sm-a"],"projects":["p-a"],"domains":["d-a"]},
 {"id":"old-b","home":"$MROOT/old-b","scope":"b","secondmates":["sm-b1","sm-b2"],"projects":["p-b"],"domains":["d-b"]},
 {"id":"old-c","home":"$MROOT/old-c","scope":"c","secondmates":["sm-c"],"projects":["p-c"],"domains":["d-c"]}],
 "dependencies":[
 {"owner":"old-a","from_task":"A1","needs_manager":"old-c","needs_task":"C1","status":"open"},
 {"owner":"old-b","from_task":"B1","needs_manager":"old-a","needs_task":"A1","status":"open"}]}
EOF
FM_FLEET_ROOT=$MROOT "$FLEET" migrate >/dev/null || fail "version-1 migration"
FM_FLEET_ROOT=$MROOT "$FLEET" migrate >/dev/null || fail "version-2 migration is not idempotent"
python3 - "$MROOT/fleet.json" <<'PY' || fail "migration result"
import json,sys
with open(sys.argv[1]) as handle: reg=json.load(handle)
assert reg["version"]==2
assert [m["id"] for m in reg["managers"]]==["manager-1","manager-2","manager-3"]
assert {o["secondmate"] for o in reg["owners"]}=={"sm-a","sm-c"}
assert len(reg["assignments"])==2
assert any(r.get("project")=="p-b" for r in reg["unassigned"])
assert len(reg["dependencies"])==1 and reg["dependencies"][0]["owner_secondmate"]=="sm-a"
assert len(reg["legacy_dependencies"])==1
PY

# Transfer uses lifecycle hooks in tests, so it never launches an external harness.
TROOT="$TMP_ROOT/transfer"
FM_FLEET_ROOT=$TROOT "$FLEET" init >/dev/null
for n in 1 2; do FM_FLEET_ROOT=$TROOT "$FLEET" manager register --id manager-$n --home "$TROOT/manager-$n" >/dev/null; done
SMHOME="$TROOT/harness-home"
FM_FLEET_ROOT=$TROOT "$FLEET" owner register --secondmate harness --home "$SMHOME" --projects AutoDev,dotcodex --domains harness >/dev/null
mkdir -p "$TROOT/manager-1/data" "$TROOT/manager-1/state" "$TROOT/manager-2/data" "$TROOT/manager-2/state" "$SMHOME"
printf '%s\n' '# SecondMates' '- harness - Harness (home: '"$SMHOME"'; scope: harness; projects: AutoDev, dotcodex; added 2026-09-13)' > "$TROOT/manager-1/data/secondmates.md"
printf '%s\n' '# SecondMates' > "$TROOT/manager-2/data/secondmates.md"
printf 'kind=secondmate\nhome=%s\nwindow=fake\n' "$SMHOME" > "$TROOT/manager-1/state/harness.meta"
printf 'working: migration fixture\n' > "$TROOT/manager-1/state/harness.status"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$TROOT/manager-1" > "$SMHOME/.fm-secondmate-parent"
add_lock "$TROOT/manager-1"; transfer_source_holder=$LAST_HOLDER
FM_FLEET_ROOT=$TROOT "$FLEET" assign --secondmate harness --reason fixture >/dev/null
remove_lock "$TROOT/manager-1" "$transfer_source_holder"

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
export FM_HOOK_LOG="$TMP_ROOT/hooks.log"
export FM_FLEET_TRANSFER_STOP_HOOK=$HOOK
export FM_FLEET_TRANSFER_MANAGER_START_HOOK=$HOOK
export FM_FLEET_TRANSFER_SECONDMATE_START_HOOK=$HOOK
export FM_FLEET_TRANSFER_ROLLBACK_START_HOOK=$HOOK

mkdir -p "$TROOT/manager-1/state/pending-replies"
printf 'phase=escalated\n' > "$TROOT/manager-1/state/pending-replies/open1"
if FM_FLEET_ROOT=$TROOT "$FLEET" transfer begin --secondmate harness --to manager-2 >/dev/null 2>&1; then fail "transfer ignored an open pending reply"; fi
[ ! -e "$FM_HOOK_LOG" ] || fail "open pending reply allowed an endpoint lifecycle action"
rm -f "$TROOT/manager-1/state/pending-replies/open1"
export FM_FLEET_TRANSFER_MANAGER_START_HOOK=$FAIL_HOOK
if FM_FLEET_ROOT=$TROOT "$FLEET" transfer begin --secondmate harness --to manager-2 >/dev/null 2>&1; then fail "transfer hid a manager relaunch failure"; fi
txfile=$(find "$TROOT/transactions" -type f -name '*.json' | head -1); tx=$(basename "$txfile" .json)
[ -n "$tx" ] || fail "interrupted transfer has no journal"
grep -q "parent_home=$TROOT/manager-2" "$SMHOME/.fm-secondmate-parent" || fail "parent binding did not move"
[ -f "$TROOT/manager-2/state/harness.meta" ] && [ ! -f "$TROOT/manager-1/state/harness.meta" ] || fail "parent metadata was not transferred"
[ "$(FM_FLEET_ROOT=$TROOT "$FLEET" route --project AutoDev | sed -n 's/.*-> \(manager-[0-9]*\).*/\1/p')" = manager-2 ] || fail "transfer assignment was not published"
export FM_FLEET_TRANSFER_MANAGER_START_HOOK=$HOOK
FM_FLEET_ROOT=$TROOT "$FLEET" transfer recover --transaction "$tx" >/dev/null || fail "recover interrupted transfer"
grep -q "$TROOT/manager-2|harness|start-secondmate" "$FM_HOOK_LOG" || fail "SecondMate relaunch did not use destination parent"

FM_FLEET_ROOT=$TROOT "$FLEET" transfer rollback --transaction "$tx" >/dev/null || fail "rollback transfer"
grep -q "$TROOT/manager-2|harness|stop-secondmate" "$FM_HOOK_LOG" || fail "rollback did not stop the destination-bound SecondMate"
grep -q "parent_home=$TROOT/manager-1" "$SMHOME/.fm-secondmate-parent" || fail "rollback did not restore parent binding"
[ -f "$TROOT/manager-1/state/harness.meta" ] && [ ! -f "$TROOT/manager-2/state/harness.meta" ] || fail "rollback did not restore parent records"
[ "$(FM_FLEET_ROOT=$TROOT "$FLEET" route --project AutoDev | sed -n 's/.*-> \(manager-[0-9]*\).*/\1/p')" = manager-1 ] || fail "rollback did not restore assignment"

# Recovery publishes a records-ready transaction exactly once even when a later relaunch fails.
records_tx=records-ready-recovery
records_journal="$TROOT/transactions/$records_tx.json"
python3 "$ROOT/bin/fm-fleet-transfer.py" prepare "$TROOT/fleet.json" --secondmate harness \
  --manager manager-2 --source-home "$TROOT/manager-1" --transaction "$records_tx" \
  --journal "$records_journal" >/dev/null || fail "prepare records-ready recovery fixture"
python3 "$ROOT/bin/fm-fleet-transfer.py" apply --journal "$records_journal" || fail "apply records-ready recovery fixture"
python3 "$ROOT/bin/fm-fleet-transfer.py" state --journal "$records_journal" --set preparing >/dev/null || fail "simulate crash before records-ready journal publication"
export FM_FLEET_TRANSFER_SECONDMATE_START_HOOK=$FAIL_HOOK
if FM_FLEET_ROOT=$TROOT "$FLEET" transfer recover --transaction "$records_tx" >/dev/null 2>&1; then fail "records-ready recovery ignored a relaunch failure"; fi
[ "$(python3 "$ROOT/bin/fm-fleet-transfer.py" state --journal "$records_journal" | json_value 'json.load(sys.stdin)["state"]')" = published ] || fail "records-ready recovery did not durably record publication"
export FM_FLEET_TRANSFER_SECONDMATE_START_HOOK=$HOOK
FM_FLEET_ROOT=$TROOT "$FLEET" transfer recover --transaction "$records_tx" >/dev/null || fail "published recovery tried to republish its assignment"
FM_FLEET_ROOT=$TROOT "$FLEET" transfer rollback --transaction "$records_tx" >/dev/null || fail "rollback records-ready recovery"

add_lock "$TROOT/manager-1"; live_source=$LAST_HOLDER
if FM_FLEET_ROOT=$TROOT "$FLEET" transfer begin --secondmate harness --to manager-2 >/dev/null 2>&1; then fail "transfer accepted a live source lock"; fi
remove_lock "$TROOT/manager-1" "$live_source"

pass "fleet schema-v2 assignment and transfer control plane"
