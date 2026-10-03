#!/usr/bin/env bash
# Behavior tests for bin/fm-lane-liveness.sh: the deterministic liveness verdict
# at each threshold boundary the contract names, the drained-while-error rule
# that keeps a moving inbox from reading as health, and the routing-verification
# classification of a delivered claim with and without processing evidence.
#
# Every case drives the real script through its command line against a fixture
# home, so the verdicts asserted here are the ones a watcher would publish.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-lane-liveness)
RAIL="$ROOT/bin/fm-lane-liveness.sh"
NOW=$(date +%s)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# A fake tmux that answers the agent-state probe for every lane window this
# home's config names, so agent_status is a fixture value rather than whatever
# the host tmux reports for windows that do not exist. display-message carries
# the pane's foreground classification, list-windows answers the inventory, and
# the `missing` state omits every window the config asks about.
fake_tmux() {  # <root> <state>
  local root=$1 state=$2 fakebin windows
  windows=$(awk '/^lane /{print $2}' "$root/config/response-lanes.conf" 2>/dev/null | tr '\n' ' ')
  fakebin=$(fm_fakebin "$root/tmux-$state")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    case '$state' in
      alive) printf '%s\n' pi ;;
      dead) printf '%s\n' bash ;;
      ambiguous) printf '%s\n' node ;;
      unreadable|missing) exit 1 ;;
    esac
    exit 0 ;;
  list-windows)
    case '$state' in
      missing) printf '%s\n' someotherwindow ;;
      *) [ -n "$windows" ] || exit 0; printf '%s\n' $windows ;;
    esac
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# lane_fixture <home-root> <lane> : a lane record plus its own supervision home.
lane_fixture() {
  local root=$1 lane=$2
  mkdir -p "$root/lanes/$lane/state" "$root/state/$lane.inbox/handled"
  fm_write_secondmate_meta "$root/state/$lane.meta" "$root/lanes/$lane" \
    "firstmate:$lane"
  : > "$root/lanes/$lane/state/.last-watcher-beat"
}

# home_fixture <name> : a central rail home with config, and nothing else.
home_fixture() {
  local root="$TMP/$1"
  mkdir -p "$root/state" "$root/config"
  printf '%s\n' '# fixture' > "$root/config/response-lanes.conf"
  printf '%s\n' "$root"
}

conf_add() {  # <root> <line>
  printf '%s\n' "$2" >> "$1/config/response-lanes.conf"
}

rail() {  # <root> <mode...>  (FM_TEST_AGENT_STATE picks the probe answer,
           # FM_TEST_EXTRA_PATH prepends fixture tools such as a fake ssh)
  local root=$1 fb
  shift
  fb=$(fake_tmux "$root" "${FM_TEST_AGENT_STATE:-alive}")
  PATH="$fb${FM_TEST_EXTRA_PATH:+:$FM_TEST_EXTRA_PATH}:$BASE_PATH" \
    FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" FM_CONFIG_OVERRIDE="$root/config" \
    "$RAIL" "$@" 2>&1
}

# verdict_of <output> <lane>
verdict_of() {
  printf '%s\n' "$1" | awk -v l="lane=$2" '$1==l {for (i=1;i<=NF;i++) if ($i ~ /^verdict=/) {sub(/^verdict=/,"",$i); print $i; exit}}'
}

field_of() {  # <output> <lane> <field>
  printf '%s\n' "$1" | awk -v l="lane=$2" -v f="$3=" \
    '$1==l {for (i=1;i<=NF;i++) if (index($i,f)==1) {print substr($i,length(f)+1); exit}}'
}

# --- a healthy lane reads alive ---------------------------------------------
ROOT_A=$(home_fixture alive)
lane_fixture "$ROOT_A" quiet
conf_add "$ROOT_A" 'lane quiet'
OUT=$(rail "$ROOT_A" read)
assert_equals alive "$(verdict_of "$OUT" quiet)" 'a fresh lane with a drained inbox reads alive'

# --- W: the supervision beat boundary ---------------------------------------
# Under W stays out of dead; over W is dead. The band above half of W and under
# W is the elevated reading the contract calls degraded. The margins are wider
# than one second on purpose: these ages come from a wall clock the fixture and
# the script each read separately, so a to-the-second assertion would be flaky
# rather than strict.
ROOT_W=$(home_fixture beat)
for lane in under_w over_w elevated; do
  lane_fixture "$ROOT_W" "$lane"
  conf_add "$ROOT_W" "lane $lane"
done
fm_touch_epoch "$(( NOW - 840 ))" "$ROOT_W/lanes/under_w/state/.last-watcher-beat"
fm_touch_epoch "$(( NOW - 960 ))" "$ROOT_W/lanes/over_w/state/.last-watcher-beat"
fm_touch_epoch "$(( NOW - 600 ))" "$ROOT_W/lanes/elevated/state/.last-watcher-beat"
OUT=$(rail "$ROOT_W" read)
assert_not_equals dead "$(verdict_of "$OUT" under_w)" 'a beat under W is not dead'
assert_equals dead "$(verdict_of "$OUT" over_w)" 'a beat over W is dead'
assert_equals degraded "$(verdict_of "$OUT" elevated)" 'a beat over half of W but under W is degraded'
assert_contains "$(printf '%s\n' "$OUT" | grep '^lane=over_w')" 'over W=900s' \
  'the dead verdict names the threshold it crossed'

# --- D: pending that stops moving to handled --------------------------------
ROOT_D=$(home_fixture drain)
for lane in fresh_pending stale_pending drained_pending drained_moved; do
  lane_fixture "$ROOT_D" "$lane"
  conf_add "$ROOT_D" "lane $lane"
done
printf 'x\n' > "$ROOT_D/state/fresh_pending.inbox/001.msg"
fm_touch_epoch "$(( NOW - 1740 ))" "$ROOT_D/state/fresh_pending.inbox/001.msg"
printf 'x\n' > "$ROOT_D/state/stale_pending.inbox/001.msg"
fm_touch_epoch "$(( NOW - 1860 ))" "$ROOT_D/state/stale_pending.inbox/001.msg"
# Same age, and this lane has handled work before, but the journal shows no
# movement since the last sweep, which is what the rule measures now.
printf 'x\n' > "$ROOT_D/state/drained_pending.inbox/001.msg"
fm_touch_epoch "$(( NOW - 1860 ))" "$ROOT_D/state/drained_pending.inbox/001.msg"
printf 'x\n' > "$ROOT_D/state/drained_pending.inbox/handled/000.msg"
# Same age and history, but the journal's handled count is behind the inbox:
# the lane moved work to handled since the last sweep, so it is working.
printf 'x\n' > "$ROOT_D/state/drained_moved.inbox/001.msg"
fm_touch_epoch "$(( NOW - 1860 ))" "$ROOT_D/state/drained_moved.inbox/001.msg"
printf 'x\n' > "$ROOT_D/state/drained_moved.inbox/handled/000.msg"
printf 'nothing interesting here\n' > "$ROOT_D/state/drained_moved.pane"
printf '%s\n' "drained_moved none $NOW 0" > "$ROOT_D/state/.lane-liveness-lanes"
OUT=$(rail "$ROOT_D" read)
assert_not_equals dead "$(verdict_of "$OUT" fresh_pending)" \
  'pending under D is not dead'
assert_equals dead "$(verdict_of "$OUT" stale_pending)" \
  'pending over D with no movement to handled is dead'
assert_equals dead "$(verdict_of "$OUT" drained_pending)" \
  'handled history no longer shields a lane whose pending aged past D with no movement'
assert_equals alive "$(verdict_of "$OUT" drained_moved)" \
  'a handled count that moved since the last sweep keeps the lane out of the D rule'
assert_contains "$(printf '%s\n' "$OUT" | grep '^lane=stale_pending')" 'over D=1800s' \
  'the dead verdict names the drain threshold it crossed'

# --- E: a sustained transport or budget error class --------------------------
ROOT_E=$(home_fixture error)
for lane in fresh_err sustained_err; do
  lane_fixture "$ROOT_E" "$lane"
  conf_add "$ROOT_E" "lane $lane"
done
printf '429 Account budget exceeded\n' > "$ROOT_E/state/fresh_err.pane"
printf '429 Account budget exceeded\n' > "$ROOT_E/state/sustained_err.pane"
# The journal carries how long the class has held. One second under E, and over.
printf '%s\n' "fresh_err budget_exceeded $(( NOW - 540 )) 0" \
  > "$ROOT_E/state/.lane-liveness-lanes"
printf '%s\n' "sustained_err budget_exceeded $(( NOW - 660 )) 0" \
  >> "$ROOT_E/state/.lane-liveness-lanes"
OUT=$(rail "$ROOT_E" read)
assert_equals budget_exceeded "$(field_of "$OUT" sustained_err error_signature_class)" \
  'the error class is matched by its exact string'
assert_not_equals dead "$(verdict_of "$OUT" fresh_err)" \
  'an error class under E is not yet dead'
assert_equals dead "$(verdict_of "$OUT" sustained_err)" \
  'an error class sustained over E is dead'

# --- a pane that cannot be read is unknown, never none ----------------------
ROOT_U=$(home_fixture unknown_pane)
lane_fixture "$ROOT_U" no_pane
conf_add "$ROOT_U" 'lane no_pane'
OUT=$(rail "$ROOT_U" read)
assert_equals unknown "$(field_of "$OUT" no_pane error_signature_class)" \
  'an unreadable pane is unknown rather than a clean none'

# --- a proven-absent agent with stalled pending is never alive --------------
# Handled history used to shield this lane: the D rule needs handled_count to
# be zero, so a dead agent with pending past D fell through to alive.
ROOT_AG=$(home_fixture absent_agent)
lane_fixture "$ROOT_AG" goner
conf_add "$ROOT_AG" 'lane goner'
printf 'x\n' > "$ROOT_AG/state/goner.inbox/001.msg"
fm_touch_epoch "$(( NOW - 1860 ))" "$ROOT_AG/state/goner.inbox/001.msg"
printf 'x\n' > "$ROOT_AG/state/goner.inbox/handled/000.msg"
OUT=$(FM_TEST_AGENT_STATE=dead rail "$ROOT_AG" read)
assert_equals dead "$(verdict_of "$OUT" goner)" \
  'a proven-dead agent with pending past D reads dead even with handled history'
assert_equals dead "$(field_of "$OUT" goner agent_status)" \
  'the reading really carries agent_status=dead'
assert_contains "$(printf '%s\n' "$OUT" | grep '^lane=goner')" 'over D=1800s' \
  'the verdict names the drain threshold the stalled pending crossed'

# The same rule on the endpoint-gone axis: a window that no longer exists is
# a proven-absent agent for exactly the same reason.
ROOT_MS=$(home_fixture missing_agent)
lane_fixture "$ROOT_MS" vanished
conf_add "$ROOT_MS" 'lane vanished'
printf 'x\n' > "$ROOT_MS/state/vanished.inbox/001.msg"
fm_touch_epoch "$(( NOW - 1860 ))" "$ROOT_MS/state/vanished.inbox/001.msg"
printf 'x\n' > "$ROOT_MS/state/vanished.inbox/handled/000.msg"
OUT=$(FM_TEST_AGENT_STATE=missing rail "$ROOT_MS" read)
assert_equals dead "$(verdict_of "$OUT" vanished)" \
  'a missing endpoint with pending past D reads dead'
assert_equals missing "$(field_of "$OUT" vanished agent_status)" \
  'the reading carries agent_status=missing'

# --- an unestablished supervision beat is never a fresh one -----------------
ROOT_NB=$(home_fixture nobeat)
lane_fixture "$ROOT_NB" unsupervised
conf_add "$ROOT_NB" 'lane unsupervised'
rm -f "$ROOT_NB/lanes/unsupervised/state/.last-watcher-beat"
OUT=$(rail "$ROOT_NB" read)
assert_equals dead "$(verdict_of "$OUT" unsupervised)" \
  'a lane whose supervision beat can never be established does not read alive'
assert_equals '-' "$(field_of "$OUT" unsupervised watcher_beat_age_s)" \
  'the reading still reports watcher_beat_age_s=- rather than inventing an age'
assert_contains "$(printf '%s\n' "$OUT" | grep '^lane=unsupervised')" 'unestablished' \
  'the verdict says why an unknown beat counts as stopped'
OUT=$(rail "$ROOT_NB" check)
assert_contains "$OUT" 'lane-liveness: lane=unsupervised' \
  'the check that pages the supervisor sees the same verdict'

# --- a remote lane reads its agent state from the remote control ------------
# The remote control's state verb, the same one the supervision library polls,
# answers for the remote lane, so agent_status is a real state word and the
# missed-ratio rule can fire remotely instead of being shielded forever by
# unverified.
ROOT_RM=$(home_fixture remotestate)
mkdir -p "$ROOT_RM/data"
# The lane's remote home and inbox exist at fixture paths the stand-in ssh can
# really read, so the rail's remote program executes against them and the
# reading that comes back is the genuine output of that program.
RHOME="$ROOT_RM/lanes/remotequiet-remote"
mkdir -p "$RHOME/state/parent-route/remotequiet.inbox/handled"
: > "$RHOME/state/.last-watcher-beat"
printf 'corr=aaa111\n' > "$RHOME/state/parent-route/remotequiet.inbox/001.msg"
printf 'corr=bbb222\n' > "$RHOME/state/parent-route/remotequiet.inbox/handled/001.msg"
fm_write_meta "$ROOT_RM/state/remotequiet.meta" \
  'window=remote:remotequiet' 'kind=secondmate' 'harness=claude' \
  'remote_host=lab-host' "home=$RHOME"
printf '%s\n' \
  '- remotequiet - Remote lane (host: lab-host; root: /remote/root; home: /remote/remotequiet-home; scope: remote work; projects: alpha; added 2026-01-01)' \
  > "$ROOT_RM/data/secondmates.md"
conf_add "$ROOT_RM" 'lane remotequiet'
printf 'nothing interesting here\n' > "$ROOT_RM/state/remotequiet.pane"
for i in 1 2 3 4 5; do
  printf '%s\n' "pending-reply-missed: pending-reply-id=miss$i" >> "$ROOT_RM/state/remotequiet.status"
done
printf '%s\n' 'pending-reply-resolved: pending-reply-id=done1' >> "$ROOT_RM/state/remotequiet.status"
FAKE_SSH=$(fm_fakebin "$ROOT_RM/fake-ssh")
cat > "$FAKE_SSH/ssh" <<'SH'
#!/usr/bin/env bash
# A stand-in with ssh own contract: drop the options and the host alias, join
# what remains with spaces, and hand that string to a shell, exactly what a
# remote login shell receives. Like the real client it drains its own stdin to
# forward it, so a caller that feeds its per-lane loop over stdin and does not
# close that pipe for this call loses every lane configured after this one,
# just as it would against OpenSSH.
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    -*) shift ;;
    *) shift; break ;;
  esac
done
joined=$*
cat > /dev/null
case "$joined" in
  fm-remote-entrypoint.sh*) printf '%s\n' "${FM_FAKE_STATE:-alive}" ;;
  *) exec sh -c "$joined" ;;
esac
SH
chmod +x "$FAKE_SSH/ssh"
OUT=$(FM_TEST_EXTRA_PATH="$FAKE_SSH" rail "$ROOT_RM" read)
assert_equals alive "$(field_of "$OUT" remotequiet agent_status)" \
  'a remote lane reports its agent state from the remote state verb, not a permanent unverified'
assert_equals degraded "$(verdict_of "$OUT" remotequiet)" \
  'a remote lane with a heavily missed reply record and a live agent reads degraded'
assert_contains "$(printf '%s\n' "$OUT" | grep '^lane=remotequiet')" 'unanswered' \
  'the missed-ratio rule is the rule that fired'
assert_equals 1 "$(field_of "$OUT" remotequiet pending_count)" \
  'the remote inbox depth arrives from the remote program, not from an empty read'
assert_equals 1 "$(field_of "$OUT" remotequiet handled_count)" \
  'the remote handled count arrives from the records the remote program listed'
assert_not_equals '-' "$(field_of "$OUT" remotequiet watcher_beat_age_s)" \
  'the remote beat age is read from the remote home over the same transport'
OUT=$(FM_FAKE_STATE=dead FM_TEST_EXTRA_PATH="$FAKE_SSH" rail "$ROOT_RM" read)
assert_equals dead "$(field_of "$OUT" remotequiet agent_status)" \
  'a remote lane whose state verb reports a dead agent carries that word'

# The remote read runs inside the per-lane config loop, so it must not consume
# the loop's stdin. Every lane configured after the reachable remote lane still
# gets its reading in each of the three sweep modes, and check still reports the
# verdict change of a lane that sits behind the remote one.
lane_fixture "$ROOT_RM" quietafter
lane_fixture "$ROOT_RM" nohostafter
conf_add "$ROOT_RM" 'lane quietafter'
conf_add "$ROOT_RM" 'lane nohostafter'
fm_touch_epoch "$(( NOW - 960 ))" "$ROOT_RM/lanes/nohostafter/state/.last-watcher-beat"
OUT=$(FM_TEST_EXTRA_PATH="$FAKE_SSH" rail "$ROOT_RM" read)
assert_equals alive "$(verdict_of "$OUT" quietafter)" \
  'a local lane configured after the reachable remote lane still gets its reading'
assert_equals dead "$(verdict_of "$OUT" nohostafter)" \
  'every lane after the remote one is read, not only the first of them'
OUT=$(FM_TEST_EXTRA_PATH="$FAKE_SSH" rail "$ROOT_RM" routes)
assert_contains "$OUT" 'lane lane=quietafter' \
  'routes reports the lane configured after the reachable remote lane'
assert_contains "$OUT" 'lane lane=nohostafter' \
  'routes reaches the last lane in the config, past the remote read'
OUT=$(FM_TEST_EXTRA_PATH="$FAKE_SSH" rail "$ROOT_RM" check)
assert_contains "$OUT" 'lane-liveness: lane=nohostafter' \
  'check reports the verdict change of a lane configured after the remote one'

# --- an absent inbox is unknown with no counts, never a zero reading --------
ROOT_M=$(home_fixture missing_inbox)
lane_fixture "$ROOT_M" gone
rm -rf "$ROOT_M/state/gone.inbox"
conf_add "$ROOT_M" 'lane gone'
OUT=$(rail "$ROOT_M" read)
assert_equals unknown "$(verdict_of "$OUT" gone)" 'an absent inbox reads unknown'
assert_equals '-' "$(field_of "$OUT" gone pending_count)" \
  'an absent inbox reports no pending count rather than zero'
assert_contains "$OUT" 'unread rather than zero' \
  'the reading says why the absent inbox is not a zero-depth reading'

# --- the reading carries the inbox path it counted --------------------------
# The ladder re-sends from this exact path, so both the default resolution and
# a config override must appear on the line the rail prints.
ROOT_IB=$(home_fixture inboxpath)
lane_fixture "$ROOT_IB" plain
lane_fixture "$ROOT_IB" counted
mkdir -p "$ROOT_IB/alt"
printf 'x\n' > "$ROOT_IB/alt/001.msg"
conf_add "$ROOT_IB" 'lane plain'
conf_add "$ROOT_IB" "lane counted $ROOT_IB/alt"
OUT=$(rail "$ROOT_IB" read)
assert_equals "$ROOT_IB/state/plain.inbox" "$(field_of "$OUT" plain inbox)" \
  'a default lane reports its resolved state inbox'
assert_equals "$ROOT_IB/alt" "$(field_of "$OUT" counted inbox)" \
  'an override lane reports the override path it counted'
assert_equals 1 "$(field_of "$OUT" counted pending_count)" \
  'the count on that same line came from the printed inbox'

# --- 2.2: drained while an error class is active stays degraded --------------
ROOT_P=$(home_fixture drained_on_error)
lane_fixture "$ROOT_P" mover
conf_add "$ROOT_P" 'lane mover'
printf '429 Account budget exceeded\n' > "$ROOT_P/state/mover.pane"
printf 'x\n' > "$ROOT_P/state/mover.inbox/handled/001.msg"
# The journal recorded one fewer handled record, so handled_count has moved, and
# the class was first seen just now so the E rule cannot reach dead.
printf '%s\n' "mover budget_exceeded $NOW 0" > "$ROOT_P/state/.lane-liveness-lanes"
OUT=$(rail "$ROOT_P" read)
assert_equals degraded "$(verdict_of "$OUT" mover)" \
  'handled_count moving while an error class is active stays degraded, never alive'
assert_equals yes "$(field_of "$OUT" mover drained_while_error_active)" \
  'the reading records that the drain happened under an active error class'
assert_contains "$OUT" 'not proof of work' \
  'the verdict says the drain is not evidence that work happened'
assert_not_equals '-' "$(field_of "$OUT" mover mover)" \
  'the mover is recorded when the filesystem can name it'

# The same lane with no error class is alive, so the rule is what made the
# difference and the case above is not vacuous.
ROOT_P2=$(home_fixture drained_no_error)
lane_fixture "$ROOT_P2" clean_mover
conf_add "$ROOT_P2" 'lane clean_mover'
printf 'nothing interesting here\n' > "$ROOT_P2/state/clean_mover.pane"
printf 'x\n' > "$ROOT_P2/state/clean_mover.inbox/handled/001.msg"
printf '%s\n' "clean_mover none $NOW 0" > "$ROOT_P2/state/.lane-liveness-lanes"
OUT=$(rail "$ROOT_P2" read)
assert_equals alive "$(verdict_of "$OUT" clean_mover)" \
  'the same drain with no active error class is alive'

# The pane cannot be read, so the class is unknown rather than none, and a lane
# moving records to handled during that window lands degraded with the mover
# recorded, never alive.
ROOT_UK=$(home_fixture drainedunknown)
lane_fixture "$ROOT_UK" unpaneled
conf_add "$ROOT_UK" 'lane unpaneled'
printf 'x\n' > "$ROOT_UK/state/unpaneled.inbox/001.msg"
printf 'x\n' > "$ROOT_UK/state/unpaneled.inbox/handled/001.msg"
printf '%s\n' "unpaneled transport_dead $(( NOW - 2400 )) 0" > "$ROOT_UK/state/.lane-liveness-lanes"
: > "$ROOT_UK/state/unpaneled.pane"
OUT=$(rail "$ROOT_UK" read)
assert_equals unknown "$(field_of "$OUT" unpaneled error_signature_class)" \
  'the pane read failed, so the class is unknown rather than none'
assert_equals degraded "$(verdict_of "$OUT" unpaneled)" \
  'a lane drained while its class is unknown reads degraded, never alive'
assert_equals yes "$(field_of "$OUT" unpaneled drained_while_error_active)" \
  'the reading records the drain against the unknown class'
assert_not_equals '-' "$(field_of "$OUT" unpaneled mover)" \
  'the mover is recorded when the filesystem can name it'

# --- an observation routes makes is carried forward --------------------------
# The sequence the emit contract exists for: a check sweep establishes the
# journal with an active class, the lane moves records to handled while that
# class still holds, `routes` runs between sweeps and is the sweep that sees
# the movement, and a later reading follows. Whoever observes the drain must
# report it, and a later reading must not erase the mover back to `-`.
ROOT_RC=$(home_fixture routesdrain)
lane_fixture "$ROOT_RC" moving
conf_add "$ROOT_RC" 'lane moving'
printf '429 Account budget exceeded\n' > "$ROOT_RC/state/moving.pane"
rail "$ROOT_RC" check > /dev/null
OUT=$(rail "$ROOT_RC" routes)
assert_not_contains "$OUT" 'drained_while_error_active' \
  'routes reports no drain before any record has moved'
printf 'x\n' > "$ROOT_RC/state/moving.inbox/handled/001.msg"
OUT=$(rail "$ROOT_RC" routes)
assert_contains "$OUT" 'drained_while_error_active=yes' \
  'the sweep that observes the drain emits it instead of discarding it'
assert_not_equals '-' "$(field_of "$OUT" moving mover)" \
  'the emitted observation carries the mover while it is determinable'
OUT=$(rail "$ROOT_RC" read)
LINE=$(printf '%s\n' "$OUT" | grep '^lane=moving')
assert_not_contains "$LINE" 'drained_while_error_active=no mover=-' \
  'the later reading does not erase the observation to no and dash'
assert_not_equals '-' "$(field_of "$OUT" moving mover)" \
  'the later reading still names the owner of the handled record'

# --- the E clock is owned by the sweep that read the pane -------------------
ROOT_J=$(home_fixture sustain)
lane_fixture "$ROOT_J" flaky
conf_add "$ROOT_J" 'lane flaky'
printf 'Connection refused\n' > "$ROOT_J/state/flaky.pane"
printf '%s\n' "flaky transport_dead $(( NOW - 660 )) 0" > "$ROOT_J/state/.lane-liveness-lanes"
OUT=$(rail "$ROOT_J" read)
assert_equals dead "$(verdict_of "$OUT" flaky)" \
  'an error sustained over E reads dead on the first sweep'
rail "$ROOT_J" routes > /dev/null
OUT=$(rail "$ROOT_J" read)
assert_equals dead "$(verdict_of "$OUT" flaky)" \
  'a routes run between sweeps does not restart the E clock'
: > "$ROOT_J/state/flaky.pane"
OUT=$(rail "$ROOT_J" read)
assert_not_equals dead "$(verdict_of "$OUT" flaky)" \
  'an unreadable pane alone never fabricates a dead verdict'
printf 'Connection refused\n' > "$ROOT_J/state/flaky.pane"
OUT=$(rail "$ROOT_J" read)
assert_equals dead "$(verdict_of "$OUT" flaky)" \
  'an unreadable pane did not end the error, so the sustained clock survives it'

# --- an unreadable pane cannot freeze the movement baseline ------------------
# The handled column of the journal is an inbox fact, so it advances even while
# the pane cannot be read. A baseline frozen behind a failed pane capture would
# keep the movement rule seeing movement forever and let a stalled lane read
# alive, which is the direction detection must never fail in.
ROOT_F=$(home_fixture frozenpane)
lane_fixture "$ROOT_F" stalled
conf_add "$ROOT_F" 'lane stalled'
for i in 1 2 3 4 5 6 7; do
  printf 'x\n' > "$ROOT_F/state/stalled.inbox/handled/$i.msg"
done
printf 'x\n' > "$ROOT_F/state/stalled.inbox/001.msg"
fm_touch_epoch "$(( NOW - 1860 ))" "$ROOT_F/state/stalled.inbox/001.msg"
printf '%s\n' "stalled none $(( NOW - 2400 )) 5" > "$ROOT_F/state/.lane-liveness-lanes"
: > "$ROOT_F/state/stalled.pane"
rail "$ROOT_F" read > /dev/null
OUT=$(rail "$ROOT_F" read)
assert_equals dead "$(verdict_of "$OUT" stalled)" \
  'an unreadable pane must not let a stalled lane read alive'
assert_contains "$(printf '%s\n' "$OUT" | grep '^lane=stalled')" 'no movement to handled' \
  'the dead verdict comes from the movement rule whose baseline the pane cannot freeze'

# The same baseline through a pane-skipping run: routes reads the inbox, so it
# advances the handled column while still leaving class and clock untouched.
ROOT_F2=$(home_fixture frozenroutes)
lane_fixture "$ROOT_F2" stalled2
conf_add "$ROOT_F2" 'lane stalled2'
for i in 1 2 3 4 5 6 7; do
  printf 'x\n' > "$ROOT_F2/state/stalled2.inbox/handled/$i.msg"
done
printf 'x\n' > "$ROOT_F2/state/stalled2.inbox/001.msg"
fm_touch_epoch "$(( NOW - 1860 ))" "$ROOT_F2/state/stalled2.inbox/001.msg"
printf 'nothing interesting here\n' > "$ROOT_F2/state/stalled2.pane"
printf '%s\n' "stalled2 none $(( NOW - 2400 )) 5" > "$ROOT_F2/state/.lane-liveness-lanes"
rail "$ROOT_F2" routes > /dev/null
OUT=$(rail "$ROOT_F2" read)
assert_equals dead "$(verdict_of "$OUT" stalled2)" \
  'a pane-skipping routes run must not freeze the baseline a stalled lane reads against'

# --- section 4: routed versus routed_unverified -----------------------------
ROOT_R=$(home_fixture routes)
lane_fixture "$ROOT_R" claims
conf_add "$ROOT_R" 'lane claims'
# Handled: processing evidence by the record's own location.
printf 'corr=aaa111\n' > "$ROOT_R/state/claims.inbox/handled/001.msg"
# Pending, but a status line carries the same corr token firstmate embedded.
printf 'corr=bbb222\n' > "$ROOT_R/state/claims.inbox/002.msg"
# Pending with a corr token that appears nowhere.
printf 'corr=ccc333\n' > "$ROOT_R/state/claims.inbox/003.msg"
# Pending with no corr token at all.
printf 'no token here\n' > "$ROOT_R/state/claims.inbox/004.msg"
printf '%s\n' 'working [at=1]: acknowledged corr=bbb222' > "$ROOT_R/state/claims.status"
OUT=$(rail "$ROOT_R" routes)
assert_contains "$OUT" 'lane lane=claims claims=4 routed=2 routed_unverified=2' \
  'handled and corr-correlated claims count as routed, the rest do not'
assert_contains "$OUT" 'routing-verification claims=4 routed=2 routed_unverified=2 unverified_rate=2/4 (50%)' \
  'the measurement reports the unverified rate with its denominator'
assert_contains "$OUT" 'record=003.msg corr=ccc333 verdict=routed_unverified' \
  'each unverified claim is named with its own reason'
assert_contains "$OUT" 'record=004.msg corr=- verdict=routed_unverified' \
  'a delivered claim with no corr token is unverified too'
assert_not_contains "$OUT" 'record=002.msg' \
  'a claim with processing evidence is not reported as unverified'

# The measurement is reproducible: the same fixture gives the same bytes.
OUT2=$(rail "$ROOT_R" routes)
assert_equals "$OUT" "$OUT2" 'the same input produces the same output'

# --- the rail reports its own silence ---------------------------------------
ROOT_S=$(home_fixture selfcheck)
lane_fixture "$ROOT_S" watched
conf_add "$ROOT_S" 'lane watched'
OUT=$(rail "$ROOT_S" selfcheck)
assert_contains "$OUT" 'never completed a sweep' \
  'a configured rail with no heartbeat reports that it has never run'
rail "$ROOT_S" check > /dev/null
OUT=$(rail "$ROOT_S" selfcheck)
assert_equals '' "$OUT" 'a rail that just swept is silent'
fm_touch_epoch "$(( NOW - 960 ))" "$ROOT_S/state/.lane-liveness-beat"
OUT=$(rail "$ROOT_S" selfcheck)
assert_contains "$OUT" 'over SELF=900s' 'a stale heartbeat reports rail silence'

# --- selfcheck enforces the configured SELF ---------------------------------
ROOT_SC=$(home_fixture selfconf)
lane_fixture "$ROOT_SC" watchful
conf_add "$ROOT_SC" 'lane watchful'
conf_add "$ROOT_SC" 'SELF=120'
rail "$ROOT_SC" check > /dev/null
fm_touch_epoch "$(( NOW - 300 ))" "$ROOT_SC/state/.lane-liveness-beat"
OUT=$(rail "$ROOT_SC" selfcheck)
assert_contains "$OUT" 'over SELF=120s' \
  'the armed silence check enforces the configured SELF, not the default'

# A config that will not load must not silence the check: it falls back to the
# default threshold and still reports.
ROOT_SB=$(home_fixture selfbad)
conf_add "$ROOT_SB" 'W=soon'
fm_touch_epoch "$(( NOW - 960 ))" "$ROOT_SB/state/.lane-liveness-beat"
OUT=$(rail "$ROOT_SB" selfcheck)
expect_code 0 $? 'a malformed config still lets selfcheck report'
assert_contains "$OUT" 'over SELF=900s' \
  'a config that will not load falls back to the default threshold'
assert_not_contains "$OUT" 'error:' \
  'the lenient load does not surface the config error in the silence report'

# --- only the completing check writes the heartbeat --------------------------
ROOT_HB=$(home_fixture heartbeat)
lane_fixture "$ROOT_HB" beatless
conf_add "$ROOT_HB" 'lane beatless'
rail "$ROOT_HB" read > /dev/null
assert_absent "$ROOT_HB/state/.lane-liveness-beat" \
  'a completed read does not write the heartbeat only check certifies'
rail "$ROOT_HB" check > /dev/null
assert_present "$ROOT_HB/state/.lane-liveness-beat" \
  'the completing check writes the heartbeat'
fm_touch_epoch "$(( NOW - 960 ))" "$ROOT_HB/state/.lane-liveness-beat"
rail "$ROOT_HB" read > /dev/null
OUT=$(rail "$ROOT_HB" selfcheck)
assert_contains "$OUT" 'over SELF=900s' \
  'a read between sweeps cannot mask rail silence'

# --- check mode wakes on a change, then stays quiet -------------------------
ROOT_C=$(home_fixture changes)
lane_fixture "$ROOT_C" flapper
conf_add "$ROOT_C" 'lane flapper'
fm_touch_epoch "$(( NOW - 4000 ))" "$ROOT_C/lanes/flapper/state/.last-watcher-beat"
OUT=$(rail "$ROOT_C" check)
assert_contains "$OUT" 'lane-liveness: lane=flapper' 'a newly dead lane wakes the supervisor'
OUT=$(rail "$ROOT_C" check)
assert_equals '' "$OUT" 'the same verdict does not wake the supervisor again'
: > "$ROOT_C/lanes/flapper/state/.last-watcher-beat"
OUT=$(rail "$ROOT_C" check)
assert_contains "$OUT" 'flapper recovered to alive' 'a recovery is reported once'

# --- malformed config is an actionable error, not a silent pass -------------
ROOT_BAD=$(home_fixture badconf)
conf_add "$ROOT_BAD" 'W=soon'
OUT=$(rail "$ROOT_BAD" read)
expect_code 2 $? 'a non-numeric threshold refuses rather than defaulting'
assert_contains "$OUT" 'needs a whole number' 'the refusal names the malformed setting'

ROOT_BAD2=$(home_fixture badconf2)
conf_add "$ROOT_BAD2" 'lane ../escape'
OUT=$(rail "$ROOT_BAD2" read)
expect_code 2 $? 'a lane name that is not path safe is refused'

ROOT_BAD3=$(home_fixture badconf3)
conf_add "$ROOT_BAD3" 'SSH_TIMEOUT=0'
OUT=$(rail "$ROOT_BAD3" read)
expect_code 2 $? 'a zero timeout refuses rather than disabling the bound'
assert_contains "$OUT" 'positive whole number' 'the refusal says the bound must be positive'

ROOT_BAD4=$(home_fixture badconf4)
conf_add "$ROOT_BAD4" 'CAPTURE_TIMEOUT=0'
OUT=$(rail "$ROOT_BAD4" read)
expect_code 2 $? 'a zero capture bound refuses rather than disabling it'
assert_contains "$OUT" 'CAPTURE_TIMEOUT' 'the refusal names the offending key'

# --- an unconfigured home is inert -----------------------------------------
ROOT_OFF="$TMP/off"
mkdir -p "$ROOT_OFF/state" "$ROOT_OFF/config"
OUT=$(rail "$ROOT_OFF" read)
assert_contains "$OUT" 'not configured' 'an unconfigured home says so and does nothing'
assert_contains "$OUT" 'is absent' 'a missing config file is labeled absent'
OUT=$(rail "$ROOT_OFF" selfcheck)
assert_equals '' "$OUT" 'an unconfigured home reports no rail silence'
assert_absent "$ROOT_OFF/state/.lane-liveness-beat" \
  'an unconfigured home writes no heartbeat'

# A config that exists but names no lane is a different fault from a missing
# file and is reported as itself.
ROOT_EC=$(home_fixture emptyconf)
OUT=$(rail "$ROOT_EC" read)
assert_contains "$OUT" 'names no lane' \
  'a config present but naming no lane is labeled as exactly that'
assert_not_contains "$OUT" 'is absent' \
  'a present config is never reported as absent'
OUT=$(rail "$ROOT_EC" routes)
assert_contains "$OUT" 'names no lane' \
  'routes labels a present but laneless config as itself'
assert_not_contains "$OUT" 'is absent' \
  'routes never reports a present config as absent'

# --- disarm reports a failed unregistration instead of claiming success ------
ROOT_DA=$(home_fixture disarmfail)
lane_fixture "$ROOT_DA" covered
conf_add "$ROOT_DA" 'lane covered'
rail "$ROOT_DA" read > /dev/null
rail "$ROOT_DA" check > /dev/null
OUT=$(rail "$ROOT_DA" arm 2>&1)
expect_code 0 $? 'arming the rail in a fixture succeeds'
assert_present "$ROOT_DA/state/lane-liveness.check.sh" 'arming writes the lane check shim'
assert_present "$ROOT_DA/state/lane-liveness-self.check.sh" 'arming writes the silence check shim'
# A trust file with a second hard link is refused by the unregister contract,
# which is the failure a disarm must report rather than print past.
ln "$ROOT_DA/state/lane-liveness-self.check-trust" "$ROOT_DA/state/.trust-dupe"
OUT=$(rail "$ROOT_DA" disarm 2>&1)
expect_code 2 $? 'a failed unregistration refuses rather than exiting success'
assert_not_contains "$OUT" 'disarmed:' \
  'a failed unregistration never prints a disarmed result'
assert_contains "$OUT" 'could not unregister lane-liveness-self' \
  'the refusal names the check that stayed'
assert_present "$ROOT_DA/state/.lane-liveness-beat" \
  'the records stay in place while a check is still armed'
assert_present "$ROOT_DA/state/lane-liveness-self.check.sh" \
  'the still-armed check keeps its shim'

# The ordinary path still disarms and reports it.
ROOT_OK=$(home_fixture disarmok)
lane_fixture "$ROOT_OK" covered
conf_add "$ROOT_OK" 'lane covered'
rail "$ROOT_OK" read > /dev/null
rail "$ROOT_OK" check > /dev/null
rail "$ROOT_OK" arm > /dev/null 2>&1
OUT=$(rail "$ROOT_OK" disarm 2>&1)
expect_code 0 $? 'an ordinary disarm exits 0'
assert_contains "$OUT" 'disarmed: lane-liveness lane-liveness-self' \
  'an ordinary disarm reports itself'
assert_absent "$ROOT_OK/state/.lane-liveness-beat" \
  'a successful disarm removes the records'

pass 'fm-lane-liveness.sh: liveness verdicts, the drained-while-error rule, routing verification, and rail self-reporting'
