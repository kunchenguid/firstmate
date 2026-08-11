#!/usr/bin/env bash
# Comprehensive federation test. Run from ~/firstmate:
#   bash tests/federation/test_fleet.sh
# Exercises: init, atomic no-overlap claim race, TTL reap, scope routing,
# cross-operator handoff, view/status, and the cross-uid safety guard.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
FLEET_CLI="bin/fm-fleet.sh"
fails=0
ok(){ echo "PASS: $1"; }
bad(){ echo "FAIL: $1"; fails=$((fails+1)); }

# BSD `sed -i` REQUIRES a backup-suffix argument, so the GNU form
# `sed -i EXPR FILE` makes BSD read EXPR as the suffix and FILE as the script: it
# errors to stderr and leaves the file UNTOUCHED. Every in-place edit below sets
# up a scenario (ageing a stamp, flipping a status), so on macOS they silently
# did nothing and the assertions that followed graded the unmutated state.
# bin/fm-fleet-lib.sh is already BSD-first; these tests were not.
fm_portable_sed_i(){ # <expr> <file>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then sed -i '' "$1" "$2"
  else sed -i "$1" "$2"; fi
}

# ---- 1. init ----
D=$(mktemp -d); export FM_FLEET_DIR="$D/fleet"
"$FLEET_CLI" init >/dev/null
allok=1
for f in operators.md projects.md backlog.md events.log locks; do
  [ -e "$FM_FLEET_DIR/$f" ] || { allok=0; echo "  missing $f"; }
done
grep -q '## Queued' "$FM_FLEET_DIR/backlog.md" && [ "$allok" = 1 ] && ok "init creates KB" || bad "init"

# ---- 2. atomic claim race (the crux) ----
"$FLEET_CLI" queue FL-1 backend "race item" >/dev/null
( "$FLEET_CLI" claim FL-1 alice   >/dev/null 2>&1; echo $? >"$D/a.rc" ) &
( "$FLEET_CLI" claim FL-1 bob >/dev/null 2>&1; echo $? >"$D/b.rc" ) &
wait
wins=$(( $(cat "$D/a.rc")==0 ? 1 : 0 ))
wins=$(( wins + ($(cat "$D/b.rc")==0 ? 1 : 0) ))
claims=$(grep -c 'claimed-by:' "$FM_FLEET_DIR/backlog.md")
{ [ "$wins" -eq 1 ] && [ "$claims" -eq 1 ]; } && ok "atomic claim: exactly one winner, one record" || bad "atomic claim (winners=$wins claims=$claims)"

# ---- 3. TTL reap ----
D2=$(mktemp -d); export FM_FLEET_DIR="$D2/fleet"
"$FLEET_CLI" init >/dev/null
"$FLEET_CLI" queue FL-9 backend demo >/dev/null; "$FLEET_CLI" claim FL-9 bob >/dev/null
# stale claimed -> should requeue
fm_portable_sed_i 's/@[0-9TZ:-]\{1,\}/@2000-01-01T00:00:00Z/' "$FM_FLEET_DIR/backlog.md"
"$FLEET_CLI" reap 3600 >/dev/null
grep -q '\[id:FL-9\].*status:queued' "$FM_FLEET_DIR/backlog.md" && ok "reap requeues stale claim" || bad "reap requeue"
# in-flight with old ts must NOT be requeued
"$FLEET_CLI" queue FL-10 backend demo2 >/dev/null; "$FLEET_CLI" claim FL-10 bob >/dev/null
fm_portable_sed_i 's/\(FL-10.*\)status:claimed/\1status:in-flight/' "$FM_FLEET_DIR/backlog.md"
fm_portable_sed_i 's/@[0-9TZ:-]\{1,\}/@2000-01-01T00:00:00Z/' "$FM_FLEET_DIR/backlog.md"
"$FLEET_CLI" reap 3600 >/dev/null
grep -q '\[id:FL-10\].*status:in-flight' "$FM_FLEET_DIR/backlog.md" && ok "reap leaves in-flight alone" || bad "reap in-flight"
# an unreadable stamp means "cannot age it", not "ancient": reap must leave the item
# claimed rather than yank it back from its owner (the failure mode a non-GNU `date`
# used to produce for EVERY claim).
"$FLEET_CLI" queue FL-11 backend demo3 >/dev/null; "$FLEET_CLI" claim FL-11 bob >/dev/null
fm_portable_sed_i 's/\(FL-11.*\)@[0-9TZ:-]\{1,\}/\1@not-a-timestamp/' "$FM_FLEET_DIR/backlog.md"
"$FLEET_CLI" reap 3600 >/dev/null
grep -q '\[id:FL-11\].*status:claimed' "$FM_FLEET_DIR/backlog.md" && ok "reap leaves an unreadable stamp claimed (fail-safe)" || bad "reap unreadable stamp"

# ---- 4. scope routing ----
D3=$(mktemp -d); export FM_FLEET_DIR="$D3/fleet"
"$FLEET_CLI" init >/dev/null
cat >> "$FM_FLEET_DIR/operators.md" <<'OPS'
| alice | backend,infra,deploy | /home/alice/firstmate | claude:default | online |
| bob | web,mobile,product | /home/bob/firstmate | claude:default | online |
| carol | overflow | /home/carol/firstmate | claude:default | online |
OPS
r_back=$("$FLEET_CLI" route backend); r_web=$("$FLEET_CLI" route web)
{ [ "$r_back" = alice ] && [ "$r_web" = bob ]; } && ok "route: backend->alice, web->bob" || bad "route primary (got '$r_back'/'$r_web')"
# alice offline -> backend falls to overflow (carol)
fm_portable_sed_i 's/| alice \(.*\)| online |/| alice \1| offline |/' "$FM_FLEET_DIR/operators.md"
r_off=$("$FLEET_CLI" route backend)
[ "$r_off" = carol ] && ok "route: offline owner -> overflow" || bad "route overflow (got '$r_off')"

# ---- 5. handoff ----
D4=$(mktemp -d); export FM_FLEET_DIR="$D4/fleet"
"$FLEET_CLI" init >/dev/null
"$FLEET_CLI" queue FL-2 web "handoff item" >/dev/null
"$FLEET_CLI" claim FL-2 alice >/dev/null
"$FLEET_CLI" handoff FL-2 bob >/dev/null
grep -q '\[id:FL-2\].*claimed-by:bob@' "$FM_FLEET_DIR/backlog.md" \
  && grep -q $'\thandoff\tFL-2' "$FM_FLEET_DIR/events.log" \
  && ok "handoff reassigns + logs event" || bad "handoff"
# handoff of a STILL-QUEUED item is a full assignment, not just a stamp: it lands in
# ## Claimed as status:claimed, so fm-fleet-wait.sh wakes the recipient and nobody
# else can claim it on top of the stamp.
"$FLEET_CLI" queue FL-3 web "queued handoff" >/dev/null
"$FLEET_CLI" handoff FL-3 bob >/dev/null
grep -q '\[id:FL-3\].*claimed-by:bob@[^ ]* status:claimed' "$FM_FLEET_DIR/backlog.md" \
  && ok "handoff of a queued item -> claimed-by + status:claimed" || bad "handoff queued status"
awk '/^## Claimed$/{c=1} /\[id:FL-3\]/{ print (c ? "in" : "out") }' "$FM_FLEET_DIR/backlog.md" | grep -qx in \
  && ok "handoff of a queued item moves it into ## Claimed" || bad "handoff queued section"
out=$(bin/fm-fleet-wait.sh bob --once --no-heartbeat 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'FL-3'; } \
  && ok "handoff of a queued item wakes the recipient" || bad "handoff queued wake (rc=$rc out='$out')"
"$FLEET_CLI" claim FL-3 alice >/dev/null 2>&1 && bad "handed-off item still claimable by a third party" \
  || ok "handed-off item is no longer claimable"
# in-flight work keeps its status through a reassignment
"$FLEET_CLI" queue FL-4 web "inflight handoff" >/dev/null; "$FLEET_CLI" claim FL-4 alice >/dev/null
fm_portable_sed_i 's/\(FL-4.*\)status:claimed/\1status:in-flight/' "$FM_FLEET_DIR/backlog.md"
"$FLEET_CLI" handoff FL-4 bob >/dev/null
grep -q '\[id:FL-4\].*claimed-by:bob@[^ ]* status:in-flight' "$FM_FLEET_DIR/backlog.md" \
  && ok "handoff of an in-flight item keeps status:in-flight" || bad "handoff in-flight"

# ---- 5b. the id is the KB's primary key: duplicates are refused, never silently
# collapsed by the single-match claim/handoff awk rules ----
"$FLEET_CLI" queue FL-5 backend "first" >/dev/null
"$FLEET_CLI" queue FL-5 backend "second" >/dev/null 2>&1 && bad "queue accepted a duplicate id" || ok "queue refuses a duplicate id"
n=$(grep -c 'id:FL-5' "$FM_FLEET_DIR/backlog.md")
{ [ "$n" -eq 1 ] && grep -q 'first' "$FM_FLEET_DIR/backlog.md"; } \
  && ok "the original item survives a rejected duplicate" || bad "duplicate rejection lost a line (n=$n)"

# ---- 6. view + status ----
vlines=$("$FLEET_CLI" view | grep -c 'FL-2' || true)
[ "$vlines" -ge 1 ] && ok "view renders events" || bad "view"
status_out=$("$FLEET_CLI" status); echo "$status_out" | grep -q 'operator' && ok "status renders header" || bad "status"

# ---- 7. cross-uid safety guard ----
# sourcing the lib and asserting a foreign home is refused
( . bin/fm-fleet-lib.sh; fm_fleet_assert_shared "/home/someoneelse/firstmate" ) 2>/dev/null \
  && bad "safety: foreign home NOT refused" || ok "safety: foreign home refused"
( . bin/fm-fleet-lib.sh; fm_fleet_assert_shared "/Users/not-$(id -un)/firstmate" ) 2>/dev/null \
  && bad "safety: macOS foreign home NOT refused" || ok "safety: macOS foreign home refused"
( . bin/fm-fleet-lib.sh; fm_fleet_assert_shared "/opt/agents/fleet" ) 2>/dev/null \
  && ok "safety: /opt shared dir allowed" || bad "safety: /opt wrongly refused"

echo "-----"
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILURE(S)"; exit 1; }
