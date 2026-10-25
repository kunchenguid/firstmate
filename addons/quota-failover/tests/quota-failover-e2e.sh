#!/usr/bin/env bash
# quota-failover e2e: the real script against a fixture home (one stub lib
# symlinked under the five names it sources, stub quota-axi and opencode on
# PATH). The fixture is a step-5-preview-free incident: a
# lead whose pinned route answers its one-line test with a 429, and a worker
# whose screen shows a limit on a second dead route. One pass must move both
# to the live candidate, pass the dead routes over, and drop them from
# crew-dispatch.json; a second pass with the routes answering again must
# restore them and move nothing. Passes 3 to 7 add workers on pool
# accounts: a Claude worker stopped on an account moves to the next account
# without a human, a Claude worker with no next account takes the route move,
# and OpenCode Go and Codex workers only rest; with
# config/account-pool-autorelaunch-off written a Claude worker only rests,
# once, and rests and wakes again when the same account stops a new
# incarnation, while a pool rest that fails still wakes the home, once; a
# Claude worker whose account folder answers a limit moves on that account's
# own reading, a pool worker wedged with a clean screen still loses its route
# to the pinned probe's verdict. Passes 11 to 13 cover the pre-limit move off a
# low account; passes 14 and 15 prove a Claude route test with no account
# runs on the pool's pick, never the default login. Needs bash, jq, flock, timeout, sed and stat
# on PATH; no real tool or home is touched.
set -u

here=$(cd "$(dirname "$0")" && pwd) || exit 1
[ -f "$here/../quota-failover" ] || { echo "not ok - $here/../quota-failover is missing"; exit 1; }
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
home=$work/home stub=$work/bin
mkdir -p "$home/state" "$home/config" "$home/bin" "$stub"

fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }
has() { if grep -q -- "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1: $2 lacks [$3]"; fi; }
count() { local got; got=$(grep -c -- "$3" "$2" 2>/dev/null) || got=0; is "$1" "$got" "$4"; }

# The fixture's firstmate surface: one stub lib (screens are state/<id>.screen,
# an fm-control relaunch clears the task's screen and status), the two exec'd
# scripts, and the CLI stubs.
awk -v w="$work" '
  /^#--- / { file = w "/" substr($0, 6); next }
  file { print > file }
' <<'STUBS' || exit 1
#--- home/bin/fm-stub-lib.sh
# shellcheck shell=bash
fm_meta_get() { [ -f "$1" ] || return 0; sed -n "s|^$2=||p" "$1" | tail -n 1; }
fm_backend_of_meta() { echo fixture; }
fm_backend_target_of_meta() { fm_meta_get "$1" endpoint_task_id; }
fm_backend_visible_capture() { [ -f "$FM_HOME/state/$2.screen" ] && cat "$FM_HOME/state/$2.screen"; return 0; }
fm_busy_classify_meta() { cat "$FM_HOME/state/$2.verdict" 2>/dev/null || echo 'idle no-busy-record'; }
fm_busy_record_read() { echo ''; }
FM_QUOTA_ROW_JQ='def quota_lane($harness; $model): ""; def quota_row($snapshot; $provider; $lane): null;'
fm_quota_json_valid() { jq -e '.schemaVersion == 5 and (.providers | type) == "array"' >/dev/null 2>&1; }
fm_quota_single_provider_for_harness() { return 1; }
fm_parent_channel_report() { printf '%s\n' "$3" >>"$1/state/parent-channel.log"; }
fm_run_timed() { shift; "$@"; }
#--- home/bin/fm-crew-state.sh
#!/usr/bin/env bash
echo 'state: working · source: fixture'
#--- home/bin/fm-control.sh
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FM_HOME/state/fm-control.log"
[ "${2:-}" = relaunch ] || exit 0
id=${1:-}
# d1's pool has no next account ready, as fm-control answers after its rest.
[ "$id $3 $4" != "d1 --account next" ] || { echo "error: config/account-pool cannot start a claude worker: no account is ready"; exit 1; }
# p6's relaunch replaces the incarnation, then fails a later launch step.
[ "$id $3 $4" != "p6 --account next" ] || { printf 'spawn_gen=s1.p6\naccount=nextacct\n' >>"$FM_HOME/state/p6.meta"; echo "error: launch step failed"; exit 1; }
rm -f "$FM_HOME/state/$id.screen"
date +%s >"$FM_HOME/state/$id.status"
#--- bin/opencode
#!/usr/bin/env bash
# Every model answers PONG except the two dead routes, which answer the
# 429, "Upstream request failed: Rate limit exceeded".
case $* in
  *step-5-preview-free*) [ "${OC_STEP5:-dead}" = dead ] || { echo PONG; exit 0; } ;;
  *gpt-5.6-luna*) [ "${OC_LUNA:-dead}" = dead ] || { echo PONG; exit 0; } ;;
  *) echo PONG; exit 0 ;;
esac
echo 'ERROR: 429 Upstream request failed: Rate limit exceeded'
exit 1
#--- bin/claude
#!/usr/bin/env bash
# The one-line test records the profile folder it ran on, so a pass can prove a
# pool task's limit was read on its own account and not on the ambient login.
printf '%s\n' "${CLAUDE_CONFIG_DIR:-ambient}" >>"$FM_HOME/state/claude-probe.log"
case ${CLAUDE_LIMIT_ACCOUNT:-} in
  '') ;;
  *) case "${CLAUDE_CONFIG_DIR:-}" in *"/profiles/$CLAUDE_LIMIT_ACCOUNT") echo "You've hit your usage limit for your plan; try again in 3h"; exit 1 ;; esac ;;
esac
if [ "${CLAUDE_LIMIT:-}" = yes ]; then
  echo "You've hit your usage limit for your plan; try again in 3h"
  exit 1
fi
echo PONG
#--- bin/quota-axi
#!/usr/bin/env bash
echo '{"schemaVersion":5,"providers":[]}'
#--- bin/byokit-accounts
#!/usr/bin/env bash
# The pool command: `status <id>` names one account's tool and profile folder.
case ${1:-} in
  status) id=${2:-}
    [ -d "$FM_HOME/state/profiles/$id" ] || { echo "error: no account $id" >&2; exit 1; }
    printf '{"ok":true,"id":"%s","tool":"claude","folder":"%s"}\n' "$id" "$FM_HOME/state/profiles/$id" ;;
  rest) id=${2:-}
    [ "$id" = deadpool ] && { echo "error: pool lib broken at $(date +%s%N)" >&2; exit 1; }
    printf 'rest %s\n' "$id" >>"$FM_HOME/state/pool.log" ;;
  pick) [ -z "${POOL_PICK_FAIL:-}" ] || { echo "error: no account can take a worker" >&2; exit 1; }
    mkdir -p "$FM_HOME/state/profiles/pooled"
    printf '{"ok":true,"id":"pooled","set":{"CLAUDE_CONFIG_DIR":"%s"},"unset":["ANTHROPIC_API_KEY"]}\n' "$FM_HOME/state/profiles/pooled" ;;
  *) echo "usage: byokit-accounts status <id>" >&2; exit 1 ;;
esac
STUBS
for lib in fm-backend.sh fm-busy-lib.sh fm-quota-axi-lib.sh fm-parent-channel-lib.sh; do
  ln -s fm-stub-lib.sh "$home/bin/$lib" || exit 1
done
chmod +x "$home/bin/fm-crew-state.sh" "$home/bin/fm-control.sh" "$stub/opencode" "$stub/claude" "$stub/quota-axi" "$stub/byokit-accounts"

# Step 5 ranked first, a second dead route, then the live ones.
cat >"$home/config/crew-dispatch.json" <<'JSON' || exit 1
{"rules": [{"when": "free preview models first", "use": [
  {"harness": "opencode", "model": "opencode-go/step-5-preview-free"},
  {"harness": "opencode", "model": "openai-codex/gpt-5.6-luna"},
  {"harness": "opencode", "model": "opencode-go/mimo-v2.6-flash"}]}],
 "default": [{"harness": "opencode", "model": "opencode-go/deepseek-v4.1-flash"}]}
JSON

# lead1 (a secondmate) sits on the 429 route with a clean screen: only the
# pinned-route provider-error test can move it. w1 sits on the second dead
# route with the usage-limit text on its screen.
printf 'endpoint_task_id=lead1\nharness=opencode\nmodel=opencode-go/step-5-preview-free\nkind=secondmate\nspawn_gen=s0.lead1\n' \
  >"$home/state/lead1.meta" || exit 1
printf 'endpoint_task_id=w1\nharness=opencode\nmodel=openai-codex/gpt-5.6-luna\nkind=crewmate\nspawn_gen=s0.w1\n' \
  >"$home/state/w1.meta" || exit 1
printf '%s\n' "You've hit your usage limit for your plan; try again in 3h" >"$home/state/w1.screen"

log=$home/state/quota-failover.log ctl=$home/state/fm-control.log
dead=$home/state/quota-failover-dead.json disp=$home/config/crew-dispatch.json
run() { # one watcher pass, with the knobs the fixture needs
  env -u CLAUDE_CONFIG_DIR PATH="$stub:$PATH" FM_HOME="$home" QUOTA_FAILOVER_PROBE_SECS=0 \
    QUOTA_FAILOVER_RETEST_SECS="${RETEST_SECS:-1800}" "$here/../quota-failover" "$home"
}

run

has "pass1: the lead moved to the live candidate" "$log" \
  'lead1: switched opencode opencode-go/step-5-preview-free -> opencode opencode-go/mimo-v2.6-flash'
has "pass1: the screen-stopped worker moved to the live candidate" "$log" \
  'w1: switched opencode openai-codex/gpt-5.6-luna -> opencode opencode-go/mimo-v2.6-flash'
has "pass1: the dead 429 route was passed over, not chosen for a move" "$log" \
  'passed over opencode-go/step-5-preview-free is out of dispatch'
count "pass1: two relaunches onto the live candidate" "$ctl" \
  ' relaunch --harness opencode --model opencode-go/mimo-v2.6-flash ' 2
is "pass1: only the probe-confirmed dead route leaves dispatch" \
  "$(grep -Eo 'step-5-preview-free|gpt-5.6-luna' "$disp" 2>/dev/null | sort -u | paste -sd, -)" "gpt-5.6-luna"

# The routes answer again: one pass restores them to dispatch and moves
# nothing back.
OC_STEP5=alive OC_LUNA=alive RETEST_SECS=0 run

count "pass2: no further moves" "$ctl" ' relaunch ' 2
is "pass2: the dead list is empty" "$(jq -c . "$dead")" '[]'
is "pass2: every route is back in dispatch" \
  "$(jq -r '.rules[0].use[].model' "$disp" | sort | paste -sd, -)" \
  "openai-codex/gpt-5.6-luna,opencode-go/mimo-v2.6-flash,opencode-go/step-5-preview-free"

# Pool workers, each stopped with the limit on its screen.
printf 'state=/pool\n' >"$home/config/account-pool"
mkdir -p "$home/state/profiles/c1" "$home/state/profiles/c2" "$home/state/profiles/go1" "$home/state/profiles/cx1" \
  "$home/state/profiles/go9" "$home/state/profiles/c3" "$home/state/profiles/deadpool"
pool() { # <id> <harness> <model> <account> [generation]
  printf 'endpoint_task_id=%s\nharness=%s\nmodel=%s\nkind=crewmate\nspawn_gen=%s\naccount=%s\n' \
    "$1" "$2" "$3" "${5:-s0.$1}" "$4" >"$home/state/$1.meta"
  printf '%s\n' "You've hit your usage limit for your plan; try again in 3h" >"$home/state/$1.screen"
}
pool a1 claude claude-opus-4-8 c1
pool d1 claude claude-opus-4-8 c2
pool g1 opencode opencode-go/mimo-v2.6-flash go1
pool x1 codex gpt-5.5-codex cx1
# The pool's "ambient" id for a tool it does not pool: nothing to move or rest, so it takes the route move.
pool y1 codex gpt-5.5-codex ambient
pooll=$home/state/pool.log wake=$home/state/quota-failover.wake

run

has "pass3: the Claude worker moved to the next pool account" "$ctl" '^a1 relaunch --account next --note-file '
count "pass3: and took no route move" "$ctl" '^a1 relaunch --harness' 0
has "pass3: the move is logged with the old account" "$log" 'a1: moved claude claude-opus-4-8 off account c1 to the next claude account'
is "pass3: with no opt-out file the move needs no human" \
  "$([ -e "$home/config/account-pool-autorelaunch-off" ] && echo present || echo absent)" absent
rm -f "$home/config/account-pool-autorelaunch"
has "pass3: with no next account the existing route move still happens" "$ctl" \
  '^d1 relaunch --harness opencode --model opencode-go/deepseek-v4.1-flash '
count "pass3: OpenCode Go never moves accounts or routes" "$ctl" '^g1 ' 0
count "pass3: Codex never moves accounts or routes" "$ctl" '^x1 ' 0
is "pass3: Go and Codex accounts rested" "$(sort "$pooll" | paste -sd, -)" "rest cx1,rest go1"
has "pass3: a worker on an account the pool does not name takes the route move" "$ctl" \
  '^y1 relaunch --harness opencode --model opencode-go/deepseek-v4.1-flash '
has "pass3: the Go wake names the account and the manual command" "$wake" \
  'g1 stopped on opencode opencode-go/mimo-v2.6-flash account go1 .*bin/fm-control.sh g1 relaunch --account <id>$'
is "pass3: an account limit leaves the route in dispatch" "$(jq -c . "$dead")" '[]'

# The home asks for the human instead: a Claude pool worker only rests, a
# second pass rests and wakes nothing more, and a worker whose pool rest fails
# still wakes the home, once.
touch "$home/config/account-pool-autorelaunch-off"
rm -f "$wake" "$pooll"
pool b1 claude claude-opus-4-8 c3
pool f1 claude claude-opus-4-8 deadpool
run
run

count "pass4: no relaunch with the opt-out file" "$ctl" '^b1 ' 0
count "pass4: no relaunch for the failed-rest worker either" "$ctl" '^f1 ' 0
is "pass4: the account rested once" "$(cat "$pooll")" "rest c3"
has "pass4: one log line names the account and the manual command" "$log" \
  'b1: stopped on claude claude-opus-4-8 account c3 .*bin/fm-control.sh b1 relaunch --account <id|next>$'
has "pass4: a failed rest is logged with the pool's error" "$log" \
  'f1: stopped on claude claude-opus-4-8 account deadpool .*rest failed (error: config/account-pool cannot rest account deadpool: pool lib broken at [0-9]*; it stays on the pick.s list until it rests), move it by hand'
has "pass4: a failed rest still wakes the home with the account named" "$wake" \
  'f1 stopped on claude claude-opus-4-8 account deadpool .*bin/fm-control.sh f1 relaunch --account <id|next>$'
count "pass4: one wake line per stopped worker" "$wake" '' 2

# The home takes the wake's advice and relaunches b1 on the same account c3;
# the new incarnation hits the limit again, and the rest and the wake happen
# once per stop, so both fire again.
pool b1 claude claude-opus-4-8 c3 s1.b1
run

is "pass5: the same account rests again for the new incarnation" "$(cat "$pooll")" "rest c3
rest c3"
count "pass5: and the wake fires again for the new stop" "$wake" 'b1 stopped' 2
count "pass5: the failed-rest wake stays at one line" "$wake" 'f1 stopped' 1

# A pool worker wedged with a clean screen on the 429 route: only the
# route-scoped pinned probe sees the outage, and it must still take the
# route out of dispatch while the worker itself rests and wakes.
printf 'endpoint_task_id=q1\nharness=opencode\nmodel=opencode-go/step-5-preview-free\nkind=crewmate\nspawn_gen=s0.q1\naccount=go9\n' \
  >"$home/state/q1.meta"
run

is "pass6: the pinned probe takes the pool worker's route out" \
  "$(jq -r '.[].model' "$dead" | paste -sd, -)" "opencode-go/step-5-preview-free"
is "pass6: and the route leaves new dispatch" \
  "$(grep -Eo 'step-5-preview-free' "$disp" 2>/dev/null | sort -u | paste -sd, -)" ""
has "pass6: the worker itself still rests and wakes" "$wake" \
  'q1 stopped on opencode opencode-go/step-5-preview-free account go9 .*bin/fm-control.sh q1 relaunch --account <id>$'

# The next pass sees q1's route as already out of dispatch instead of
# probe-detected, but the stop is the same one: nothing rests or wakes again.
run

count "pass7: the stop's changed label re-fires nothing" "$wake" 'q1 stopped' 1
is "pass7: and the out route is not rested a second time" "$(cat "$pooll")" "rest c3
rest c3
rest go9"

# A Claude pool worker whose screen is clean but whose own account folder
# answers a limit moves on that account's reading, and its route stays in
# dispatch for every other task.
rm -f "$home/config/account-pool-autorelaunch-off" "$wake" "$home/state/claude-probe.log"
mkdir -p "$home/state/profiles/c9"
pool h1 claude claude-opus-4-8 c9
: >"$home/state/h1.screen"
CLAUDE_LIMIT_ACCOUNT=c9 run
has "pass8: the account's own limit moves the worker to the next account" "$ctl" '^h1 relaunch --account next'
count "pass8: it is read on that account's profile folder" "$home/state/claude-probe.log" \
  "^$home/state/profiles/c9$" 1
is "pass8: an account limit leaves the claude route in dispatch" \
  "$(jq -r '[.[].model | select(startswith("claude"))] | join(",")' "$dead")" ""


# Wrapper/file text is not Claude's limit banner and must not remove its route.
printf '[]\n' >"$dead"
printf '{"rules":[],"default":[{"harness":"claude","model":"claude-haiku-5-5"}]}\n' >"$disp"
printf 'endpoint_task_id=cw\nharness=claude\nmodel=claude-haiku-5-5\nkind=crewmate\nspawn_gen=s0.cw\n' >"$home/state/cw.meta"
printf 'quota exhausted' >"$home/state/cw.screen"
run
is "pass9: wrapper text leaves Haiku dispatch intact" "$(jq -r '.default[0].model' "$disp")" claude-haiku-5-5
is "pass9: wrapper text does not mark Haiku dead" "$(jq -r 'any(.[]; .model == "claude-haiku-5-5")' "$dead")" false

# The actual Claude banner is confirmed by the one-line probe before removal.
printf "%s\n" "You've hit your usage limit for your plan; try again in 3h" >"$home/state/cw.screen"
CLAUDE_LIMIT=yes run
is "pass10: confirmed Claude limit removes Haiku" "$(jq -r '.default // [] | length' "$disp")" 0
is "pass10: confirmed Claude limit is recorded out" "$(jq -r 'any(.[]; .model == "claude-haiku-5-5")' "$dead")" true

# Pre-limit: an account at or below the floor sheds its working, idle-between-turns workers
# before they stop on the limit; a busy worker, a healthy account, a stale reading and a second
# pass move nobody, and Codex (D1) only wakes the home.
rm -f "$wake"
now=$(date +%s)
reading() { # <tool> <generated_at> <id 5h 7d>...
  local tool=$1 at=$2; shift 2
  printf '%s\n' "$@" | jq -Rn --argjson at "$at" '{schema: 1, generated_at: $at, accounts: [inputs | split(" ")
    | {id: .[0], five_hour: {left: (.[1] | tonumber)}, seven_day: {left: (.[2] | tonumber)}, problem: null}]}' \
    >"$home/state/$tool-accounts.json"
}
reading claude "$now" "lowacct 90 3" "okacct 60 70"
reading codex "$now" "lowcx 12 80"
prelim() { # <id> <harness> <model> <account>
  printf 'endpoint_task_id=%s\nharness=%s\nmodel=%s\nkind=crewmate\nspawn_gen=s0.%s\naccount=%s\n' "$1" "$2" "$3" "$1" "$4" >"$home/state/$1.meta"
}
prelim p1 claude claude-opus-4-8 lowacct
prelim p2 claude claude-opus-4-8 lowacct
echo 'busy claude-hook' >"$home/state/p2.verdict"
prelim p3 claude claude-opus-4-8 okacct
prelim p4 codex gpt-5.5-codex lowcx
run
run
count "pass11: the idle worker on the low account moved once" "$ctl" '^p1 relaunch --account next --note-file ' 1
has "pass11: the move names the account and its headroom" "$log" 'p1: moved idle claude claude-opus-4-8 off low account lowacct (90% 5h, 3% week)'
count "pass11: a worker mid-turn is never moved" "$ctl" '^p2 ' 0
count "pass11: a worker on a healthy account stays" "$ctl" '^p3 ' 0
count "pass11: Codex never moves on its own" "$ctl" '^p4 ' 0
count "pass11: Codex wakes the home once with the manual command" "$wake" 'p4 account lowcx is low (12% 5h, 80% week); move it by hand' 1
reading claude "$((now - 4000))" "lowacct 90 3"
prelim p5 claude claude-opus-4-8 lowacct
run
count "pass12: a stale reading moves nobody" "$ctl" '^p5 ' 0
reading claude "$(date +%s)" "lowacct 90 3"
prelim p6 claude claude-opus-4-8 lowacct
run
has "pass13: a relaunch that fails after the swap reports the account it moved to" "$log" \
  'p6: moved idle claude claude-opus-4-8 off low account lowacct (90% 5h, 3% week) to account nextacct, but the relaunch reported: error: launch step failed'
# A Claude route test that names no account runs on the pool's pick; when the pick fails it
# reuses the last good pick and never the default login.
is "pass14: the route tests ran on the pool's pick" "$(tail -n 1 "$home/state/claude-probe.log")" "$home/state/profiles/pooled"
printf 'endpoint_task_id=cz\nharness=claude\nmodel=claude-sonnet-test\nkind=crewmate\nspawn_gen=s0.cz\n' >"$home/state/cz.meta"
printf "%s\n" "You've hit your usage limit for your plan; try again in 3h" >"$home/state/cz.screen"
POOL_PICK_FAIL=1 run
is "pass15: a failed pick reuses the last good pick" "$(tail -n 1 "$home/state/claude-probe.log")" "$home/state/profiles/pooled"
count "pass15: no Claude test ever ran on the default login" "$home/state/claude-probe.log" '^ambient$' 0

if [ "$fails" -eq 0 ]; then
  echo "quota-failover e2e: all assertions held"
else
  echo "quota-failover e2e: $fails assertion(s) failed"
  exit 1
fi
