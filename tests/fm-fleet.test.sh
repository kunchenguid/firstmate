#!/usr/bin/env bash
# Behavior tests for the thin multi-manager fleet control plane.
#
# Covers real process-level concurrency: three isolated manager processes with
# isolated FM_HOMEs, duplicate SecondMate and duplicate authority refusal,
# model-wait isolation, crash isolation with durable restart, deterministic
# single-owner routing, cross-shard dependencies without joint ownership, no
# fleet-level completion claims, and the single-manager degenerate case.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FLEET="$ROOT/bin/fm-fleet.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet)
export FM_FLEET_POLL=1
export FM_FLEET_STALL_SECS=300

FROOT=$TMP_ROOT/fleet
export FM_FLEET_ROOT=$FROOT

cleanup() {
  "$FLEET" stop --all >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

wait_state() {  # <id> <want> <deadline-secs>
  local id=$1 want=$2 deadline=$3 i=0 got=""
  while [ "$i" -lt "$deadline" ]; do
    got=$("$FLEET" status --json | python3 -c 'import json,sys; print("\n".join(r["manager"]+":"+r["state"] for r in json.load(sys.stdin)["managers"]))' 2>/dev/null | grep "^$id:" | cut -d: -f2 || true)
    [ "$got" = "$want" ] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

"$FLEET" init || fail "fleet init"
[ -f "$FROOT/fleet.json" ] || fail "fleet init writes a registry"

"$FLEET" register --id fm-a --home "$FROOT/homes/fm-a" --scope runtime \
  --secondmates sm-a1,sm-a2 --projects proj-a --domains runtime || fail "register fm-a"
"$FLEET" register --id fm-b --home "$FROOT/homes/fm-b" --scope governance \
  --secondmates sm-b1 --projects proj-b --domains governance || fail "register fm-b"
"$FLEET" register --id fm-c --home "$FROOT/homes/fm-c" --scope integrations \
  --secondmates sm-c1 --projects proj-c --domains integrations || fail "register fm-c"
"$FLEET" validate || fail "fleet validates with three shards"

if "$FLEET" register --id fm-d --home "$FROOT/homes/fm-d" --scope x \
  --secondmates sm-a1 >/dev/null 2>&1; then
  fail "duplicate SecondMate assignment is accepted"
fi
ids=$(python3 -c 'import json; print(" ".join(sorted(m["id"] for m in json.load(open("'"$FROOT"'/fleet.json"))["managers"])))')
[ "$ids" = "fm-a fm-b fm-c" ] || fail "failed registration pollutes the registry: $ids"

if "$FLEET" register --id fm-d --home "$FROOT/homes/fm-d" --scope x \
  --projects proj-a >/dev/null 2>&1; then
  fail "overlapping project routing is accepted"
fi
"$FLEET" validate || fail "registry still valid after refused registrations"

"$FLEET" start || fail "fleet start with three managers"
wait_state fm-a idle 15 || wait_state fm-a running 5 || fail "fm-a never becomes live"
wait_state fm-b idle 15 || wait_state fm-b running 5 || fail "fm-b never becomes live"
wait_state fm-c idle 15 || wait_state fm-c running 5 || fail "fm-c never becomes live"

homes=$(python3 -c 'import json; print(" ".join(sorted(m["home"] for m in json.load(open("'"$FROOT"'/fleet.json"))["managers"])))')
[ "$(printf '%s' "$homes" | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')" = "3" ] || fail "manager homes are not isolated: $homes"
for mid in fm-a fm-b fm-c; do
  pid=$(cat "$FROOT/homes/$mid/state/.fleet-manager.pid" 2>/dev/null || true)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || fail "$mid has no live process"
done

if "$FLEET" start --managers fm-a >/dev/null 2>&1; then
  fail "duplicate live authority over fm-a is accepted"
fi

"$FLEET" progress fm-b --note "shard work" --active 2 >/dev/null || fail "progress fm-b"
"$FLEET" set-wait fm-a --on >/dev/null || fail "set-wait fm-a"
wait_state fm-a model-wait 15 || fail "fm-a never reports model-wait"
i=0
bstate=""
while [ "$i" -lt 15 ]; do
  bstate=$("$FLEET" status --json | python3 -c 'import json,sys; print([r["state"] for r in json.load(sys.stdin)["managers"] if r["manager"]=="fm-b"][0])')
  [ "$bstate" = "running" ] && break
  sleep 1
  i=$((i + 1))
done
[ "$bstate" = "running" ] || fail "fm-b stopped progressing while fm-a waits: $bstate"
cstate=$("$FLEET" status --json | python3 -c 'import json,sys; print([r["state"] for r in json.load(sys.stdin)["managers"] if r["manager"]=="fm-c"][0])')
[ "$cstate" = "idle" ] || [ "$cstate" = "running" ] || fail "fm-c affected by fm-a wait: $cstate"

bpid=$(cat "$FROOT/homes/fm-b/state/.fleet-manager.pid")
kill -9 "$bpid" 2>/dev/null || fail "cannot kill fm-b for crash test"
wait_state fm-b dead 15 || fail "crashed fm-b never reports dead"
astate=$("$FLEET" status --json | python3 -c 'import json,sys; print([r["state"] for r in json.load(sys.stdin)["managers"] if r["manager"]=="fm-a"][0])')
[ "$astate" = "model-wait" ] || fail "fm-a affected by fm-b crash: $astate"
browns=$("$FLEET" status --json | python3 -c 'import json,sys; print([r["secondmates"] for r in json.load(sys.stdin)["managers"] if r["manager"]=="fm-b"][0])')
[ "$browns" = "['sm-b1']" ] || fail "crashed shard loses its SecondMate list: $browns"

"$FLEET" restart fm-b >/dev/null || fail "restart fm-b after crash"
wait_state fm-b running 15 || fail "restarted fm-b never recovers"
bactive=$("$FLEET" status --json | python3 -c 'import json,sys; print([r["active"] for r in json.load(sys.stdin)["managers"] if r["manager"]=="fm-b"][0])')
[ "$bactive" = "2" ] || fail "restarted fm-b loses durable shard state: active=$bactive"

[ "$("$FLEET" route --secondmate sm-c1)" = "fm-c (by secondmates)" ] || fail "route by secondmate"
[ "$("$FLEET" route --project proj-b)" = "fm-b (by projects)" ] || fail "route by project"
[ "$("$FLEET" route --domain runtime)" = "fm-a (by domains)" ] || fail "route by domain"
if "$FLEET" route --project unknown-proj >/dev/null 2>&1; then
  fail "route resolves an unowned project"
fi

"$FLEET" dep add --owner fm-a --from T1 --needs fm-c --task T9 >/dev/null || fail "dep add"
[ "$("$FLEET" route --project proj-a)" = "fm-a (by projects)" ] || fail "dependency transfers ownership"
depstate=$("$FLEET" status --json | python3 -c 'import json,sys; print([r["state"] for r in json.load(sys.stdin)["managers"] if r["manager"]=="fm-a"][0])')
[ "$depstate" = "model-wait" ] || [ "$depstate" = "blocked" ] || fail "dep owner state is wrong: $depstate"
"$FLEET" set-wait fm-a --off >/dev/null || fail "clear fm-a wait"
wait_state fm-a blocked 15 || fail "dep owner never reports blocked"
"$FLEET" dep "done" --owner fm-a --from T1 >/dev/null || fail "dep done"
wait_state fm-a idle 15 || wait_state fm-a running 5 || fail "dep close never unblocks the owner"
if "$FLEET" status | grep -Ei "complete|done|closed" | grep -v "LAST-PROGRESS" >/dev/null 2>&1; then
  fail "fleet status claims completion"
fi

SROOT=$TMP_ROOT/single
export FM_FLEET_ROOT=$SROOT
"$FLEET" init >/dev/null || fail "single fleet init"
"$FLEET" register --id fm-only --home "$SROOT/homes/fm-only" --scope everything \
  --secondmates sm-1 --projects p1 --domains d1 >/dev/null || fail "single register"
"$FLEET" start >/dev/null || fail "single start"
wait_state fm-only idle 15 || wait_state fm-only running 5 || fail "single manager never live"
[ "$("$FLEET" route --project p1)" = "fm-only (by projects)" ] || fail "single route"
"$FLEET" stop --all >/dev/null || fail "single stop"
export FM_FLEET_ROOT=$FROOT

if command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  HROOT=$TMP_ROOT/herdfleet
  FM_FLEET_ROOT=$HROOT FM_FLEET_BACKEND=herdr "$FLEET" init >/dev/null || fail "herdr fleet init"
  FM_FLEET_ROOT=$HROOT FM_FLEET_BACKEND=herdr "$FLEET" register --id fm-h \
    --home "$HROOT/homes/fm-h" --scope trial --secondmates sm-h1 >/dev/null || fail "herdr register"
  FM_FLEET_ROOT=$HROOT FM_FLEET_BACKEND=herdr "$FLEET" start >/dev/null || fail "herdr start"
  i=0
  hstate=""
  while [ "$i" -lt 20 ]; do
    hstate=$(FM_FLEET_ROOT=$HROOT "$FLEET" status --json | python3 -c 'import json,sys; print([r["state"] for r in json.load(sys.stdin)["managers"] if r["manager"]=="fm-h"][0])')
    [ "$hstate" = "running" ] || [ "$hstate" = "idle" ] && break
    sleep 1
    i=$((i + 1))
  done
  [ "$hstate" = "running" ] || [ "$hstate" = "idle" ] || fail "herdr manager never live: $hstate"
  [ -s "$HROOT/homes/fm-h/state/.fleet-herdr-target" ] || fail "herdr target not recorded"
  FM_FLEET_ROOT=$HROOT FM_FLEET_BACKEND=herdr "$FLEET" stop --all >/dev/null || fail "herdr stop"
else
  echo "skip: herdr backend not available"
fi
export FM_FLEET_ROOT=$FROOT
unset FM_FLEET_BACKEND
"$FLEET" status --json | python3 -c 'import json,sys; assert len(json.load(sys.stdin)["managers"])==3' || fail "status json loses managers"
"$FLEET" attach fm-a | grep -q "homes/fm-a" || fail "attach does not name the manager home"

"$FLEET" stop --all >/dev/null || fail "fleet stop --all"
for mid in fm-a fm-b fm-c; do
  if [ -f "$FROOT/homes/$mid/state/.fleet-manager.pid" ]; then
    pid=$(cat "$FROOT/homes/$mid/state/.fleet-manager.pid")
    kill -0 "$pid" 2>/dev/null && fail "$mid still alive after stop"
  fi
done
"$FLEET" validate || fail "registry invalid after stop"

# A live reasoning session holding the home lock (no daemon) is real authority.
"$FLEET" register --id fm-s --home "$FROOT/homes/fm-s" --scope sessions >/dev/null || fail "register fm-s"
mkdir -p "$FROOT/homes/fm-s/state"
bash -c 'exec -a /opt/homebrew/bin/codex sleep 300' & SHOLDER=$!
printf '%s\n' "$SHOLDER" > "$FROOT/homes/fm-s/state/.lock"
sstate=$("$FLEET" status --json | python3 -c 'import json,sys; print([r["state"] for r in json.load(sys.stdin)["managers"] if r["manager"]=="fm-s"][0])')
[ "$sstate" = "idle" ] || fail "session-held home not idle: $sstate"
sdetail=$("$FLEET" status --json | python3 -c 'import json,sys; print([r["detail"] for r in json.load(sys.stdin)["managers"] if r["manager"]=="fm-s"][0])')
[ "$sdetail" = "agent" ] || fail "session authority not labeled agent: $sdetail"
"$FLEET" progress fm-s --active 2 --note "session work" >/dev/null || fail "session progress"
sstate=$("$FLEET" status --json | python3 -c 'import json,sys; print([r["state"] for r in json.load(sys.stdin)["managers"] if r["manager"]=="fm-s"][0])')
[ "$sstate" = "running" ] || fail "session progress not running: $sstate"
"$FLEET" set-wait fm-s --on >/dev/null || fail "session set-wait"
sstate=$("$FLEET" status --json | python3 -c 'import json,sys; print([r["state"] for r in json.load(sys.stdin)["managers"] if r["manager"]=="fm-s"][0])')
[ "$sstate" = "model-wait" ] || fail "session wait not model-wait: $sstate"
"$FLEET" set-wait fm-s --off >/dev/null || fail "session clear-wait"
if "$FLEET" start --managers fm-s >/dev/null 2>&1; then
  fail "fleet started a daemon over a session-held home"
fi
sstate=$("$FLEET" status --json | python3 -c 'import json,sys; print([r["detail"] for r in json.load(sys.stdin)["managers"] if r["manager"]=="fm-s"][0])')
[ "$sstate" = "agent" ] || fail "session authority lost after refused start: $sstate"
kill "$SHOLDER" 2>/dev/null || true
sstate=$("$FLEET" status --json | python3 -c 'import json,sys; print([r["state"] for r in json.load(sys.stdin)["managers"] if r["manager"]=="fm-s"][0])')
[ "$sstate" = "ready" ] || [ "$sstate" = "dead" ] || [ "$sstate" = "stopped" ] || fail "released home not quiescent: $sstate"

pass "fleet control plane"
