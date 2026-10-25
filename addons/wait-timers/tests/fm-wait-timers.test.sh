#!/usr/bin/env bash
# Real watcher/drain/parent-channel journey; only the terminal API is a fixture.
set -eu
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-wait-timers)
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

cycle() {
  local rc=0 seq gen
  env HOME="$dir/home" XDG_CONFIG_HOME="$dir/home/config" TMPDIR="$dir/tmp" \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_BUSY_TURN_MAX_SECS=999999 \
    FM_STALE_ESCALATE_SECS=999999 FM_WAIT_ALERT_SECS=2 FM_WAIT_ESCALATE_SECS=4 \
    "$WATCH" > "$dir/out" 2> "$dir/err" &
  pid=$!
  wait_for_exit "$pid" 70 || rc=$?
  case "$rc" in 0|124) ;; *) fail "watcher failed: $(cat "$dir/err")" ;; esac
  cat "$dir/out" >> "$dir/events"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$DRAIN" > "$dir/drain" 2> "$dir/ack"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$dir/ack")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$dir/ack")
  [ -z "$seq" ] || FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" >/dev/null
}

# Arms the lane's episode and ends that arming cycle on a real signal from a second
# lane, appended once the episode is recorded. The signal scan runs before the
# wait-timer tick, so a signal present before the tick would end the cycle before
# the episode existed; a quiet arming cycle would instead alert once its threshold
# matured. Ending it on the signal keeps the arming cycle silent, as before.
arm_episode() {  # <dir>
  printf 'kind=ship\nbackend=tmux\nwindow=fake:2\n' > "$1/state/lane-b.meta"
  printf 'working: building\n' > "$1/state/lane-b.status"
  prime_status_seen "$1/state" "$1/state/lane-b.status"
  (
    i=0
    while [ ! -e "$1/state/.waiting-timers/lane" ] && [ "$i" -lt 100 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    printf 'working: step two\n' >> "$1/state/lane-b.status"
  ) &
  cycle
  wait
}

if [ "${FM_WAIT_TIMERS_MAIN_ESCALATION_ONLY:-0}" != 1 ]; then
for verb in blocked needs-decision; do
  dir=$(make_case "$verb")
  mkdir -p "$dir/home/config" "$dir/tmp" "$dir/config" "$dir/parent/state"
  printf 'lead\n' > "$dir/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$dir/parent" > "$dir/.fm-secondmate-parent"
  channel="$dir/parent/state/lead.status"
  if [ "$verb" = needs-decision ]; then
    printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=fixture\n' > "$dir/.fm-secondmate-parent"
    channel="$dir/state/parent-replies.status"
  fi
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$dir/state/lane.meta"
  printf '%s [at=%s] [key=wait]: external condition until 2099-01-01T00:00Z\n' "$verb" "$(date +%s)" > "$dir/state/lane.status"
  prime_status_seen "$dir/state" "$dir/state/lane.status"
  arm_episode "$dir"
  if [ "$verb" = blocked ]; then
    IFS=$'\t' read -r sig since owner _parent key _misses < "$dir/state/.waiting-timers/lane"
    printf '%s\t%s\t0\t0\t%s\t0\n' "$sig" "$((since - 900))" "$key" > "$dir/state/.waiting-timers/lane"
  fi
  cycle
  if [ "$verb" = blocked ]; then
    [ ! -s "$channel" ] || fail 'restart escalated before owner response interval'
    IFS=$'\t' read -r sig since owner _parent key _misses < "$dir/state/.waiting-timers/lane"
    [ "$owner" -gt 1 ] || fail 'owner delivery timestamp missing'
  fi
  grep -q 'check: waiting-state lane .*level=owner' "$dir/events" || fail "$verb did not alert its owner"
  cycle
  grep -q 'blocked .*waiting-timer-overdue: lane' "$channel" || fail "$verb did not escalate to parent"
  cycle
  [ "$(grep -c 'level=owner' "$dir/events")" -eq 1 ] || fail "$verb repeated its owner alert"
  [ "$(grep -c '^blocked ' "$channel")" -eq 1 ] || fail "$verb repeated parent escalation"
  printf 'resolved [key=wait]: condition cleared\nworking: resumed\n' >> "$dir/state/lane.status"
  cycle
  cycle
  grep -q '^resolved .*waiting-timer-cleared:' "$channel" || fail "$verb left parent escalation open"
  printf '%s [key=wait]: another condition\n' "$verb" >> "$dir/state/lane.status"
  cycle
  cycle
  [ "$(grep -c 'level=owner' "$dir/events")" -eq 2 ] || fail "$verb did not re-arm"
  if [ "$verb" = blocked ]; then
    cycle
    rm "$dir/state/lane.meta"
    cycle
    [ "$(grep -c '^resolved .*waiting-timer-cleared:' "$channel")" -eq 2 ] || fail 'removed task left parent report open'
  fi
  pass "$verb owner alert, parent escalation, deduplication, resolution and re-arm"
done
fi

# A Main-owned wait has no parent channel, so its escalation is one wake to Main.
dir=$(make_case main-escalation)
mkdir -p "$dir/home/config" "$dir/tmp" "$dir/config"
printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$dir/state/lane.meta"
printf 'blocked [at=%s] [key=wait]: external condition until 2099-01-01T00:00Z\n' "$(date +%s)" > "$dir/state/lane.status"
prime_status_seen "$dir/state" "$dir/state/lane.status"
arm_episode "$dir"
IFS=$'\t' read -r sig since _owner _parent key _misses < "$dir/state/.waiting-timers/lane"
printf '%s\t%s\t0\t0\t%s\t0\n' "$sig" "$((since - 900))" "$key" > "$dir/state/.waiting-timers/lane"
cycle
[ "$(grep -c 'level=owner' "$dir/events")" -eq 1 ] || fail 'Main-owned wait did not alert Main'
grep -q 'waiting-state lane (blocked key=wait, .*level=owner' "$dir/events" || fail 'owner recheck did not name the decision key'
IFS=$'\t' read -r sig since owner _parent key _misses < "$dir/state/.waiting-timers/lane"
printf '%s\t%s\t%s\t0\t%s\t0\n' "$sig" "$since" "$((owner - 900))" "$key" > "$dir/state/.waiting-timers/lane"
cycle
grep -q 'check: waiting-state lane .*level=main' "$dir/events" || fail 'Main-owned wait did not escalate to Main'
grep -q 'waiting-state lane (blocked key=wait, .*level=main' "$dir/events" || fail 'Main escalation did not name the decision key'
! grep -qi 'captain' "$dir/events" || fail 'Main-owned escalation paged the captain'
[ "$(grep -c 'level=main' "$dir/events")" -eq 1 ] || fail 'Main-owned escalation repeated'
IFS=$'\t' read -r _sig _since _owner parent _key _misses < "$dir/state/.waiting-timers/lane"
[ "$parent" -eq 1 ] || fail 'Main-owned escalation was not recorded'
cycle
[ "$(grep -c 'level=main' "$dir/events")" -eq 1 ] || fail 'Main-owned escalation repeated on a later poll'
pass 'a Main-owned overdue wait escalates once to Main without paging the captain'
# Every wait carries a stable identity (home, task, generation, source key); a
# resolution closes only the wait it names, and escalations print that source.
dir=$(make_case identity)
mkdir -p "$dir/home/config" "$dir/tmp" "$dir/config"
printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$dir/state/lane.meta"
# No [at=] stamp on either decision, and an older unrelated decision (old-ask).
printf 'needs-decision [key=old-ask]: unrelated product choice\nblocked [key=cur-wait]: current dependency\n' > "$dir/state/lane.status"
prime_status_seen "$dir/state" "$dir/state/lane.status"
arm_episode "$dir"
IFS=$'\t' read -r sig since _owner _parent key _misses < "$dir/state/.waiting-timers/lane"
case "$key" in
  waiting-timer-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-lane-g[0-9]*-cur-wait) ;;
  *) fail "wait identity is not home/task/generation/key: $key" ;;
esac
printf '%s\t%s\t0\t0\t%s\t0\n' "$sig" "$((since - 900))" "$key" > "$dir/state/.waiting-timers/lane"
cycle
grep -F "id=$key source=[blocked [key=cur-wait]: current dependency]" "$dir/events" >/dev/null || fail 'escalation did not print the exact unresolved source'
printf 'resolved [key=cur-wait]: dependency arrived\nworking: resumed\n' >> "$dir/state/lane.status"
cycle
cycle
[ -e "$dir/state/.waiting-timers/lane" ] || fail 'a later working line closed the unrelated open decision'
IFS=$'\t' read -r _sig _since _owner _parent key2 _misses < "$dir/state/.waiting-timers/lane"
case "$key2" in
  waiting-timer-*-lane-g[0-9]*-old-ask) ;;
  *) fail "unrelated decision did not become the named open wait: $key2" ;;
esac
[ "$key2" != "$key" ] || fail 'a changed wait kept the old identity'
printf 'resolved [key=old-ask]: decided\n' >> "$dir/state/lane.status"
for _ in 1 2 3; do [ -e "$dir/state/.waiting-timers/lane" ] || break; cycle; done
[ ! -e "$dir/state/.waiting-timers/lane" ] || fail 'resolving the last decision left the wait open'
printf 'blocked: waiting on an unkeyed thing\n' >> "$dir/state/lane.status"
cycle
cycle
IFS=$'\t' read -r _sig _since _owner _parent key3 _misses < "$dir/state/.waiting-timers/lane"
case "$key3" in
  waiting-timer-*-lane-g[0-9]*) ;;
  *) fail "unkeyed wait has no stable identity: $key3" ;;
esac
case "$key3" in *"$$"*) fail "unkeyed identity carries a process id: $key3" ;; esac
pass 'waits carry home/task/generation/key identity, name the unresolved source, and keep unrelated decisions open'
[ "${FM_WAIT_TIMERS_MAIN_ESCALATION_ONLY:-0}" != 1 ] || exit 0

# Native blocked wins over a working log and survives unrelated status churn.
dir=$(make_case herdr)
mkdir -p "$dir/home/config" "$dir/tmp" "$dir/config"
printf 'kind=secondmate\nharness=opencode\nbackend=herdr\nwindow=fixture:w1:p1\n' > "$dir/state/lane.meta"
printf 'working: running\n' > "$dir/state/lane.status"
printf 'blocked\n' > "$dir/native"
cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/native-calls"
if [ "$1 $2" = 'agent list' ]; then
  printf '{"result":{"agents":[{"pane_id":"w1:p1","agent_status":"%s"},{"pane_id":"foreign:pane","agent_status":"blocked"}]}}\n' "$(cat "$FM_HOME/native")"
elif [ "$1" = status ]; then
  printf '{"server":{"running":true}}\n'
elif [ "$1 $2" = 'session list' ]; then
  printf '{"sessions":[{"name":"fixture","socket_path":"fixture-socket"}]}\n'
elif [ "$1 $2" = 'agent get' ]; then
  printf 'agent-get\n' >> "$FM_HOME/native-reads"
  printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$(cat "$FM_HOME/native")"
else
  exit 1
fi
SH
chmod +x "$dir/fakebin/herdr"
cycle
printf 'working: more output\n' >> "$dir/state/lane.status"
cycle
cycle
[ "$(grep -c 'level=owner' "$dir/events")" -eq 1 ] || fail 'native blocked timer was reset by output or repeated'
grep -q 'herdr-blocked' "$dir/events" || fail 'native blocked did not override working'
! grep -q 'foreign:pane' "$dir/events" || fail 'foreign pane was monitored'
printf 'working\n' > "$dir/native"
# Clearing the episode takes two polls (one missed read is tolerated), and each
# cycle's watcher is stopped after a few seconds, so repeat until it has cleared.
for _ in 1 2 3 4 5; do
  [ -e "$dir/state/.waiting-timers/lane" ] || break
  cycle
done
[ ! -e "$dir/state/.waiting-timers/lane" ] || fail 'native working did not clear the episode'
printf 'blocked\n' > "$dir/native"
cycle
cycle
[ "$(grep -c 'level=owner' "$dir/events")" -eq 2 ] || fail 'native blocked did not re-arm'
printf 'working\n' > "$dir/native"
printf 'blocked [key=waiting-timer-child]: waiting-timer-overdue: child is waiting\n' >> "$dir/state/lane.status"
cycle
cycle
[ "$(grep -c 'level=owner' "$dir/events")" -eq 2 ] || fail 'child report was mistaken for the lead waiting'
pass 'lead native blocked overrides log, ignores foreign panes, re-arms, and excludes child reports'

printf 'kind=ship\nharness=cursor\nbackend=herdr\nwindow=fixture:w1:p1\n' > "$dir/state/lane.meta"
cat > "$dir/fakebin/reader" <<'SH'
#!/usr/bin/env bash
printf '@subscribed\n'
sleep "$2"
SH
chmod +x "$dir/fakebin/reader"
export FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_BACKEND_HERDR_EVENT_READER="$dir/fakebin/reader"
: > "$dir/events"
: > "$dir/native-reads"
printf 'blocked\n' > "$dir/native"
printf 'working: healthy Cursor\n' > "$dir/state/lane.status"
prime_status_seen "$dir/state" "$dir/state/lane.status"
: > "$dir/native-calls"
cycle
[ ! -e "$dir/state/.waiting-timers/lane" ] || fail 'Cursor native blocked admitted'
[ -s "$dir/native-reads" ] || fail "Cursor ship did not reach native push reconciliation: $(cat "$dir/out" "$dir/err" "$dir/native-calls")"
[ -e "$dir/state/.herdr-escalated-fixture_w1_p1" ] || fail 'Cursor push was not consumed'
[ ! -s "$dir/events" ] || fail 'healthy Cursor ship emitted an alert'
printf 'blocked [key=cursor-wait]: real dependency\n' >> "$dir/state/lane.status"
cycle
cycle
grep -q 'waiting-state lane (blocked' "$dir/events" || fail 'Cursor declaration not monitored'
pass 'Cursor ship ignores native polling and push blockers but retains declaration monitoring'
unset FM_BACKEND_HERDR_EVENTS_FORCE FM_BACKEND_HERDR_EVENT_READER
printf 'kind=secondmate\nharness=cursor\nbackend=herdr\nwindow=fixture:w1:p1\n' > "$dir/state/lane.meta"

cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = 'agent list' ]; then sleep 30
elif [ "$1" = status ]; then printf '{"server":{"running":true}}\n'
elif [ "$1 $2" = 'session list' ]; then printf '{"sessions":[{"name":"fixture","socket_path":"fixture-socket"}]}\n'
else exit 1; fi
SH
for tool in timeout gtimeout; do
  # shellcheck disable=SC2016 # The generated script expands FM_HOME at runtime.
  printf '#!/usr/bin/env bash\nprintf "coreutils-called\\n" >> "$FM_HOME/coreutils-calls"\nexit 125\n' > "$dir/fakebin/$tool"
  chmod +x "$dir/fakebin/$tool"
done
rm -f "$dir/state/lane.meta" "$dir/state/lane.status"
printf 'kind=ship\nbackend=herdr\nwindow=fixture:w1:p1\n' > "$dir/state/herdr-lane.meta"
printf 'blocked [key=herdr-wait]: native lane dependency\n' > "$dir/state/herdr-lane.status"
printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$dir/state/tmux-lane.meta"
printf 'blocked [key=tmux-wait]: external dependency\n' > "$dir/state/tmux-lane.status"
prime_status_seen "$dir/state" "$dir/state/herdr-lane.status"
prime_status_seen "$dir/state" "$dir/state/tmux-lane.status"
: > "$dir/events"
export FM_BACKEND_HERDR_READ_TIMEOUT=1 FM_TIMEOUT_MECHANISM_OVERRIDE=bash
cycle
unset FM_BACKEND_HERDR_READ_TIMEOUT FM_TIMEOUT_MECHANISM_OVERRIDE
grep -q 'check: waiting-state tmux-lane .*level=owner' "$dir/events" || fail 'stalled native lookup stopped monitoring the healthy tmux lane'
! grep -q 'herdr-lane' "$dir/events" || fail 'lane on a stalled native session raised an alert'
grep -q 'agent list for fixture failed (code 124, deadline 1s); its lanes are unknown this poll' "$dir/err" || fail 'native failure diagnostic missing'
[ ! -e "$dir/coreutils-calls" ] || fail 'portable lookup invoked optional coreutils'
pass 'stalled native lookup marks only its lanes unknown and keeps the watcher monitoring the rest'

dir=$(make_case flicker)
mkdir -p "$dir/home/config" "$dir/tmp" "$dir/config"
printf 'kind=ship\nharness=opencode\nbackend=herdr\nwindow=fixture:w1:p1\n' > "$dir/state/lane.meta"
printf 'working: running\n' > "$dir/state/lane.status"
printf 'blocked\n' > "$dir/native"
cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = 'agent list' ]; then
  printf '{"result":{"agents":[{"pane_id":"w1:p1","agent_status":"%s"}]}}\n' "$(cat "$FM_HOME/native")"
else
  exit 1
fi
SH
chmod +x "$dir/fakebin/herdr"
prime_status_seen "$dir/state" "$dir/state/lane.status"
cycle
IFS=$'\t' read -r sig since owner _parent key _misses < "$dir/state/.waiting-timers/lane"
start=$((since - 900))
printf '%s\t%s\t0\t0\t%s\t0\n' "$sig" "$start" "$key" > "$dir/state/.waiting-timers/lane"
printf 'working\n' > "$dir/native"
cycle
IFS=$'\t' read -r _sig since owner _parent key misses < "$dir/state/.waiting-timers/lane"
[ "$since" -eq "$start" ] || fail 'one non-blocked poll reset the blocked observation time'
[ "$misses" -eq 1 ] || fail 'one non-blocked poll was not counted as a miss'
printf 'blocked\n' > "$dir/native"
: > "$dir/events"
cycle
[ "$(grep -c 'level=owner' "$dir/events")" -eq 1 ] || fail 'flicker re-block did not alert its owner from the preserved observation time'
pass 'a blocked/working flicker keeps the original blocked observation time'

dir=$(make_case push-owner)
mkdir -p "$dir/home/config" "$dir/tmp" "$dir/config"
printf 'kind=ship\nharness=opencode\nbackend=herdr\nwindow=fixture:w1:p1\n' > "$dir/state/lane.meta"
printf 'working: running\n' > "$dir/state/lane.status"
printf 'blocked\n' > "$dir/native"
cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = 'agent list' ]; then
  printf '{"result":{"agents":[{"pane_id":"w1:p1","agent_status":"%s"}]}}\n' "$(cat "$FM_HOME/native")"
elif [ "$1" = status ]; then
  printf '{"server":{"running":true}}\n'
elif [ "$1 $2" = 'session list' ]; then
  printf '{"sessions":[{"name":"fixture","socket_path":"fixture-socket"}]}\n'
elif [ "$1 $2" = 'agent get' ]; then
  printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$(cat "$FM_HOME/native")"
else
  exit 1
fi
SH
cat > "$dir/fakebin/reader" <<'SH'
#!/usr/bin/env bash
printf '@subscribed\n'
sleep "$2"
SH
chmod +x "$dir/fakebin/herdr" "$dir/fakebin/reader"
export FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_BACKEND_HERDR_EVENT_READER="$dir/fakebin/reader"
prime_status_seen "$dir/state" "$dir/state/lane.status"
: > "$dir/events"
cycle
grep -q 'stale: fixture:w1:p1 (herdr: agent blocked' "$dir/events" || fail 'native push did not wake the owner immediately'
IFS=$'\t' read -r _sig _since owner _parent _key _misses < "$dir/state/.waiting-timers/lane"
[ "$owner" -gt 1 ] || fail 'native push wake did not record owner delivery'
cycle
[ "$(grep -c 'level=owner' "$dir/events")" -eq 0 ] || fail 'native push wake was followed by a duplicate owner recheck'
unset FM_BACKEND_HERDR_EVENTS_FORCE FM_BACKEND_HERDR_EVENT_READER
pass 'an immediate native push wake is the episode owner delivery, with no duplicate recheck'

# A due wait alert defers to a same-cycle signal: the signal scan runs first,
# and the deferred alert still surfaces on the next quiet cycle (retro fix 4).
dir=$(make_case signals-first)
mkdir -p "$dir/home/config" "$dir/tmp" "$dir/config"
printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$dir/state/lane-a.meta"
printf 'blocked [at=%s] [key=wait]: external condition until 2099-01-01T00:00Z\n' "$(date +%s)" > "$dir/state/lane-a.status"
printf 'kind=ship\nbackend=tmux\nwindow=fake:2\n' > "$dir/state/lane-b.meta"
printf 'working: building\n' > "$dir/state/lane-b.status"
prime_status_seen "$dir/state" "$dir/state/lane-a.status"
prime_status_seen "$dir/state" "$dir/state/lane-b.status"
cycle
IFS=$'\t' read -r sig since owner _parent key _misses < "$dir/state/.waiting-timers/lane-a"
printf '%s\t%s\t0\t0\t%s\t0\n' "$sig" "$((since - 900))" "$key" > "$dir/state/.waiting-timers/lane-a"
printf 'done: fix complete, PR open\n' >> "$dir/state/lane-b.status"
: > "$dir/events"
cycle
grep -q '^signal:' "$dir/out" || fail "a due wait alert outran the signal wake: $(cat "$dir/out")"
! grep -q 'waiting-state' "$dir/out" || fail 'the wait-timer step ran before the signal scan'
cycle
grep -q 'check: waiting-state lane-a .*level=owner' "$dir/events" || fail 'the wait alert deferred behind the signal was never delivered'
pass 'a due wait alert defers to a same-cycle signal and still surfaces next cycle'

# A declared pause rechecks at the pause cadence, never the owner-alert
# threshold, and its episode survives pause-prose churn on the same key.
dir=$(make_case paused-recheck)
mkdir -p "$dir/home/config" "$dir/tmp" "$dir/config"
printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$dir/state/lane.meta"
printf 'paused: waiting on the pipeline run\n' > "$dir/state/lane.status"
prime_status_seen "$dir/state" "$dir/state/lane.status"
cycle
cycle
[ -e "$dir/state/.waiting-timers/lane" ] || fail 'a due paused wait armed no episode'
[ "$(grep -c 'waiting-state lane' "$dir/events")" -eq 0 ] || fail 'a paused wait alerted at the owner-alert threshold'
IFS=$'\t' read -r sig since owner _parent key _misses < "$dir/state/.waiting-timers/lane"
start=$((since - 15000))
printf '%s\t%s\t0\t0\t%s\t0\n' "$sig" "$start" "$key" > "$dir/state/.waiting-timers/lane"
: > "$dir/events"
cycle
grep -q 'check: waiting-state lane (paused, observed .*level=owner' "$dir/events" || fail 'a paused wait never rechecked its owner at the pause cadence'
! grep 'waiting-state lane (paused' "$dir/events" | grep -q 'key=' || fail 'an unkeyed paused wait named a decision key'
printf 'paused [at=%s]: refreshed prose, still waiting on the pipeline run\n' "$(date +%s)" >> "$dir/state/lane.status"
cycle
cycle
[ "$(grep -c 'level=owner' "$dir/events")" -eq 1 ] || fail 'refreshed pause prose re-alerted the owner'
IFS=$'\t' read -r _sig since _owner _parent _key _misses < "$dir/state/.waiting-timers/lane"
[ "$since" -eq "$start" ] || fail 'refreshed pause prose re-armed the episode'
printf 'paused [key=phase-two]: a different wait\n' >> "$dir/state/lane.status"
cycle
cycle
IFS=$'\t' read -r _sig since _owner _parent _key _misses < "$dir/state/.waiting-timers/lane"
[ "$since" -gt "$start" ] || fail 'a pause with a new phase key did not re-arm the episode'
pass 'a paused wait rechecks at FM_PAUSE_RESURFACE_SECS, survives prose churn, and re-arms on a new key'
