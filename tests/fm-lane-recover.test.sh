#!/usr/bin/env bash
# Behavior tests for bin/fm-lane-recover.sh, the bounded recovery ladder.
#
# The cases that matter here are the refusals, because the ladder's value is as
# much in what it declines to do as in what it tries:
#   - THE-FM is never a target, asserted rather than attempted.
#   - Inconclusive endpoint evidence never authorizes a relaunch.
#   - An unhealthy lane never ends at rung=none, which would report success
#     while doing nothing.
#   - Planning consumes no attempt budget and changes nothing.
#
# Every case drives the real script through its command line, and every rung
# decision is asserted from `plan`, so no test ever launches or replaces an
# agent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP=$(fm_test_tmproot fm-lane-recover)
LADDER="$ROOT/bin/fm-lane-recover.sh"
NOW=$(date +%s)

# A fake tmux that drives fm_backend_agent_state to one chosen classification,
# the same shape tests/fm-secondmate-liveness.test.sh establishes.
#   alive      a named agent command holds the pane
#   dead       a bare shell holds it
#   ambiguous  an unrecognized process holds it
#   unreadable the pane read fails while the inventory still lists the window
#   missing    the inventory is readable and omits the window
fake_tmux() {  # <dir> <state> <session:window>
  local dir=$1 state=$2 win=$3 fakebin
  # tmux lists window NAMES, so the inventory answer is the part after the
  # colon; printing the whole target here would make every window read missing.
  win=${win#*:}
  fakebin=$(fm_fakebin "$dir")
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
      missing) printf '%s\n' someothewindow ;;
      *) printf '%s\n' '$win' ;;
    esac
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# home <name> : a central home with config, plus a lane whose own supervision
# home exists so the rail can read a beat for it.
home() {
  local root="$TMP/$1"
  mkdir -p "$root/state" "$root/config"
  printf '%s\n' '# fixture' '# thresholds left at defaults' > "$root/config/response-lanes.conf"
  printf '%s\n' "$root"
}

lane() {  # <root> <lane> [beat-age] [harness]
  local root=$1 name=$2 age=${3:-0} harness=${4:-pi}
  mkdir -p "$root/lanes/$name/state" "$root/state/$name.inbox/handled"
  fm_write_secondmate_meta "$root/state/$name.meta" "$root/lanes/$name" \
    "sess:$name" alpha "$harness"
  : > "$root/lanes/$name/state/.last-watcher-beat"
  [ "$age" = 0 ] || fm_touch_epoch "$(( NOW - age ))" "$root/lanes/$name/state/.last-watcher-beat"
  printf '%s\n' "lane $name" >> "$root/config/response-lanes.conf"
}

conf() { printf '%s\n' "$2" >> "$1/config/response-lanes.conf"; }
pane() { printf '%s\n' "$3" > "$1/state/$2.pane"; }
seed_row() {  # <log> <rung> <outcome>: a durable ladder-log row, the state the counters read
  printf '%s\t%s\t%s\t%s\n' "$NOW" "$2" "$3" 'fixture' >> "$1"
}
attempt_count() {  # <log> <rung>: how many attempt rows that rung has
  awk -F '\t' -v r="$2" '$2 == r && $3 == "attempt" { n++ } END { print n + 0 }' "$1"
}

# ladder <root> <probe-state> <window> <mode...>
ladder() {
  local root=$1 state=$2 win=$3 fb slug
  shift 3
  # PATH is colon separated, so a fake-bin directory named after a session:window
  # target would split into two bogus entries and the fake would never be found.
  slug=${win//:/-}
  fb=$(fake_tmux "$root/fake-$state-$slug" "$state" "$win")
  PATH="$fb:$BASE_PATH" FM_TEST_SEAM=1 FM_HOME="$root" \
    FM_STATE_OVERRIDE="$root/state" FM_CONFIG_OVERRIDE="$root/config" \
    "$LADDER" "$@" 2>&1
}

row() {  # <output> <lane>
  printf '%s\n' "$1" | grep "^lane=$2 " | head -1
}

field() {  # <row> <name>
  printf '%s\n' "$1" | sed -n "s/.* $2=\\([^ ]*\\).*/\\1/p"
}

# --- THE-FM is never a target ------------------------------------------------
# The refusal is asserted, not attempted: a fake tmux that records every call
# proves nothing was even probed on the way to refusing.
R=$(home thefm)
mkdir -p "$R/state/itself.inbox/handled"
fm_write_secondmate_meta "$R/state/itself.meta" "$R" "sess:itself" alpha pi
conf "$R" 'lane itself'
OUT=$(ladder "$R" dead sess:itself plan)
ROW=$(row "$OUT" itself)
assert_equals refused "$(field "$ROW" rung)" 'a lane whose home resolves to THE-FM is refused'
assert_contains "$ROW" 'never restarts or recreates' 'the refusal says what it is protecting'
assert_not_contains "$OUT" 'rung=restart_lane_agent' 'THE-FM is never offered a restart'

# A record that is not a response lane at all is refused the same way.
R=$(home notalane)
mkdir -p "$R/lanes/ship/state" "$R/state/ship.inbox/handled"
fm_write_meta "$R/state/ship.meta" 'window=sess:ship' 'kind=ship' "home=$R/lanes/ship"
conf "$R" 'lane ship'
OUT=$(ladder "$R" dead sess:ship plan)
assert_equals refused "$(field "$(row "$OUT" ship)" rung)" 'a record that is not a response lane is refused'

# --- an unread lane is never acted on ---------------------------------------
R=$(home unread)
lane "$R" gone
rm -rf "$R/state/gone.inbox"
OUT=$(ladder "$R" dead sess:gone plan)
ROW=$(row "$OUT" gone)
assert_equals none "$(field "$ROW" rung)" 'a lane the rail could not read is left alone'
assert_contains "$ROW" 'unread is not dead' 'the reason says why an unread lane is not a dead one'

# --- inconclusive endpoint evidence never relaunches -------------------------
# Each inconclusive state gets its own home so the verdict cannot leak between
# them, and each must both decline rung 1 AND still escalate, because the lane
# is unhealthy either way.
for state in ambiguous unreadable; do
  R=$(home "inconclusive-$state")
  lane "$R" stalled 4000
  pane "$R" stalled 'nothing interesting'
  OUT=$(ladder "$R" "$state" sess:stalled plan)
  ROW=$(row "$OUT" stalled)
  assert_not_equals restart_lane_agent "$(field "$ROW" rung)" \
    "an $state endpoint must never be relaunched"
  assert_equals escalate_captain "$(field "$ROW" rung)" \
    "an $state endpoint on a dead lane escalates rather than reporting nothing to do"
done

# The same inconclusive endpoint with a provider fault still never reaches the
# switch rung: a fault admits rung 2 only on a conclusive probe, so the lane
# escalates carrying the inconclusive probe as its evidence instead.
for state in ambiguous unreadable; do
  R=$(home "fault-inconclusive-$state")
  lane "$R" stalled 4000
  pane "$R" stalled 'Account budget exceeded'
  conf "$R" 'SWITCH_MODEL=some-other-model'
  OUT=$(ladder "$R" "$state" sess:stalled plan)
  ROW=$(row "$OUT" stalled)
  assert_equals escalate_captain "$(field "$ROW" rung)" \
    "an $state endpoint with a provider fault escalates instead of reaching the switch rung"
  assert_contains "$ROW" 'inconclusive' \
    "the escalation names the inconclusive probe as its evidence"
  assert_not_contains "$OUT" 'rung=switch_model_or_harness' \
    "an $state endpoint is never offered the rung that replaces an agent"
done

# --- an escalation names the stale beat as its evidence ---------------------
# A lane whose defect is a stale supervision beat must be paged with that beat
# age named as the evidence, not with a bare report that a defect was found.
# The second count changes every run, so the phrasing is what is asserted.
R=$(home beatstale)
lane "$R" stalebeat 4000
pane "$R" stalebeat 'nothing interesting'
OUT=$(ladder "$R" ambiguous sess:stalebeat plan)
ROW=$(row "$OUT" stalebeat)
assert_equals escalate_captain "$(field "$ROW" rung)" \
  'a lane whose supervision beat is stale escalates rather than reporting nothing to do'
assert_contains "$ROW" 'supervision beat age' \
  'the escalation reason names the beat age'
assert_contains "$ROW" 'is the evidence' \
  'the escalation reason says the beat age is the evidence'

# --- a proven dead endpoint reaches rung 1 ----------------------------------
R=$(home rung1)
lane "$R" downed 4000
pane "$R" downed 'nothing interesting'
OUT=$(ladder "$R" dead sess:downed plan)
ROW=$(row "$OUT" downed)
assert_equals restart_lane_agent "$(field "$ROW" rung)" 'a proven dead endpoint reaches the restart rung'
assert_contains "$ROW" 'attempt 1 of 2' 'the rung records which attempt this would be'
assert_contains "$ROW" 'action=would-run' 'planning only says what it would run'
assert_contains "$ROW" "cmd=fm_secondmate_liveness_relaunch $R/state/downed.meta downed 300" \
  'the plan prints the exact relaunch invocation, meta path, lane, and timeout, run would execute'

# --- probe-alive must not short-circuit the error class ----------------------
# The regression this ordering exists for: process alive, provider dead. Before
# the fix this exited at rung=none reporting that the endpoint probes alive.
R=$(home providerdead)
lane "$R" stalled 4000
pane "$R" stalled 'stream disconnected before completion'
conf "$R" 'SWITCH_MODEL=some-other-model'
OUT=$(ladder "$R" alive sess:stalled plan)
ROW=$(row "$OUT" stalled)
assert_equals switch_model_or_harness "$(field "$ROW" rung)" \
  'a live endpoint with a matched provider error reaches the switch rung'
assert_contains "$ROW" 'stream_disconnected' 'the rung names the class that justified it'
assert_contains "$ROW" 'fm-control.sh' 'the switch uses the existing owner of replacing a running agent'
assert_contains "$ROW" "cmd=$ROOT/bin/fm-control.sh stalled relaunch --model some-other-model" \
  'the plan prints the exact switch invocation, path, and flags, run would execute'
assert_contains "$ROW" 'some-other-model' 'the configured switch target is the one that would be used'
assert_contains "$ROW" 'persist is attempted' 'a live endpoint is asked to persist first, bounded'
assert_not_contains "$ROW" 'endpoint probes alive' \
  'probe liveness must not be the terminal answer for a provider-dead lane'

# Same lane, same live endpoint, but no provider error: there is nothing to
# switch onto, so this must escalate rather than swap a healthy provider. This
# is what keeps the case above from passing vacuously.
R=$(home providerclean)
lane "$R" stalled 4000
pane "$R" stalled 'nothing interesting'
conf "$R" 'SWITCH_MODEL=some-other-model'
OUT=$(ladder "$R" alive sess:stalled plan)
assert_equals escalate_captain "$(field "$(row "$OUT" stalled)" rung)" \
  'a live endpoint with no provider error does not get a profile switch'

# --- a provider fault on a missing endpoint is not the provider's fault ------
R=$(home missingendpoint)
lane "$R" vanished 4000
pane "$R" vanished 'Account budget exceeded'
conf "$R" 'SWITCH_MODEL=some-other-model'
conf "$R" 'ATTEMPT_CEILING=0'
OUT=$(ladder "$R" missing sess:vanished plan)
ROW=$(row "$OUT" vanished)
assert_equals escalate_captain "$(field "$ROW" rung)" \
  'a missing endpoint never gets a profile switch, because the provider is not the cause'
assert_contains "$ROW" 'provider is not the cause' 'the escalation says why rung 2 does not apply'

# The reason an escalation was handed survives the re-send offered in front of
# it: the plan must report both the rung that failed and the rung being tried
# first, because this line is what the dry-run review reads.
R=$(home reasonkeep)
lane "$R" stalled 4000
pane "$R" stalled 'stream disconnected before completion'
printf 'schema=1\nat=now\n--\nwork order\n' > "$R/state/stalled.inbox/001.msg"
OUT=$(ladder "$R" alive sess:stalled plan)
ROW=$(row "$OUT" stalled)
assert_equals redispatch "$(field "$ROW" rung)" \
  'a lane that still holds work re-sends before the page'
assert_contains "$ROW" 'no SWITCH_MODEL' \
  'the reason keeps the escalation it was handed: no switch target is configured'
assert_contains "$ROW" 'fresh correlation ids' \
  'the reason also names the re-send being tried first'

# --- a class the rail does not publish is never dropped ---------------------
R=$(home unhandled)
lane "$R" odd 4000
pane "$R" odd 'nothing interesting'
conf "$R" 'SWITCH_MODEL=some-other-model'
# A rail that reports a class its own published vocabulary does not contain.
# That is the drift the ladder must refuse to guess about, and a stub rail is
# the only way to produce it, since the real rail keeps the two in step.
cat > "$R/stub-rail" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  classes) printf 'class none matched=no\nclass budget_exceeded matched=yes\n' ;;
  read) printf 'lane=odd source=local verdict=dead pending_count=0 handled_count=0 inbox_drain_age_s=- pending_reply_missed=0 pending_reply_resolved=0 error_signature_class=brand_new_class watcher_beat_age_s=4000 agent_status=alive route_evidence_count=0 drained_while_error_active=no mover=- reason=fixture\n' ;;
esac
STUB
chmod +x "$R/stub-rail"
OUT=$(PATH="$(fake_tmux "$R/fake-odd" alive sess:odd):$BASE_PATH" FM_TEST_SEAM=1 \
  FM_HOME="$R" FM_STATE_OVERRIDE="$R/state" FM_CONFIG_OVERRIDE="$R/config" \
  FM_LANE_RAIL="$R/stub-rail" "$LADDER" plan 2>&1)
ROW=$(row "$OUT" odd)
assert_equals escalate_captain "$(field "$ROW" rung)" \
  'a class the rail does not publish routes to the escalation rung'
assert_contains "$ROW" 'unhandled_errclass' 'the unhandled class is named rather than silently dropped'

# --- drained-while-error evidence: recorded when acting, printed when planning
# The ladder's sweep reads the whole rail line but consumes only a few fields
# of it. The observation must surface either way: an acting run records it in
# the ladder log, a plan prints it and writes nothing, and an unwritable log is
# reported instead of claimed.
R=$(home drainreport)
lane "$R" moving 0
pane "$R" moving 'Account budget exceeded'
cat > "$R/stub-rail" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  classes) printf 'class none matched=no\nclass budget_exceeded matched=yes\n' ;;
  read) printf 'lane=moving source=local verdict=degraded pending_count=0 handled_count=2 inbox_drain_age_s=- pending_reply_missed=0 pending_reply_resolved=0 error_signature_class=budget_exceeded watcher_beat_age_s=1 agent_status=alive route_evidence_count=0 drained_while_error_active=yes mover=worker reason=fixture\n' ;;
esac
STUB
chmod +x "$R/stub-rail"
run_drain_ladder() {  # <mode>: this fixture's stub rail behind its fake tmux
  PATH="$(fake_tmux "$R/fake-moving" alive sess:moving):$BASE_PATH" FM_TEST_SEAM=1 \
    FM_HOME="$R" FM_STATE_OVERRIDE="$R/state" FM_CONFIG_OVERRIDE="$R/config" \
    FM_LANE_RAIL="$R/stub-rail" "$LADDER" "$1" 2>&1
}
OUT=$(run_drain_ladder plan)
assert_absent "$R/state/.lane-recovery-moving" \
  'planning writes no ladder log row for the observation'
assert_contains "$OUT" 'observation=drained_while_error_active mover=worker' \
  'the plan prints the drained-while-error observation instead of recording it'
conf "$R" 'RECOVERY=acting'
OUT=$(run_drain_ladder run)
assert_grep "$(printf 'rail\tdrained_while_error_active\tmover=worker')" \
  "$R/state/.lane-recovery-moving" \
  'the acting run records the drained-while-error observation in the ladder log'
assert_contains "$(row "$OUT" moving)" 'action=parked' \
  'the acting escalation parks the lane alongside the recorded observation'
rm -f "$R/state/.lane-recovery-moving"
mkdir -p "$R/state/.lane-recovery-moving"
OUT=$(run_drain_ladder run)
assert_contains "$OUT" 'observation=drained_while_error_active mover=worker reason=ladder log unwritable' \
  'an observation that cannot be recorded is printed with the failure instead of vanishing'
assert_contains "$OUT" 'rung=escalate_captain action=skipped' \
  'a parked row that could not be written is reported as skipped, not parked'
assert_contains "$OUT" 'no parked row was recorded' \
  'the report names exactly what was not recorded'
assert_not_contains "$OUT" 'action=parked' \
  'no line claims a parked row when the append failed'

# --- rung 3: a recovered lane's unclaimed work is re-sent once --------------
R=$(home rung3)
lane "$R" reloaded 4000
pane "$R" reloaded 'nothing interesting'
printf 'schema=1\nat=now\n--\ncorr=0123456789abcdef original work order\n' > "$R/state/reloaded.inbox/001.msg"
OUT=$(ladder "$R" alive sess:reloaded plan)
assert_contains "$OUT" 'mode=dry-run' 'a plan is labeled as a dry run'
ROW=$(row "$OUT" reloaded)
assert_equals redispatch "$(field "$ROW" rung)" \
  'an alive endpoint on a lane that still holds unclaimed work reaches rung 3 before the page'
assert_contains "$ROW" 'action=would-run' 'planning says what rung 3 would run'
assert_contains "$ROW" 'cmd=redispatch_do reloaded' 'the plan prints the exact call the acting run makes'
assert_contains "$ROW" 'fresh correlation ids' 'the plan names the re-send contract'
assert_absent "$R/state/.lane-recovery-reloaded" 'planning the re-send writes no ladder log'
OUT=$(ladder "$R" alive sess:reloaded run)
assert_contains "$OUT" 'refusing to act' 'the off-switch also holds rung 3'
assert_absent "$R/state/.lane-recovery-reloaded" 'a refused re-send writes no ladder log'
conf "$R" 'RECOVERY=acting'
OUT=$(ladder "$R" alive sess:reloaded run)
assert_contains "$OUT" 'mode=acting' 'the banner labels an acting sweep'
assert_not_contains "$OUT" 'mode=acting1' 'the banner label is not a parameter echo'
ROW=$(row "$OUT" reloaded)
assert_contains "$ROW" 'rung=redispatch action=done' 'the acting run executes the re-send'
assert_contains "$ROW" 'sent=1' 'the acting run reports what it re-sent'
assert_grep "$(printf 'redispatch\tattempt')" "$R/state/.lane-recovery-reloaded" \
  'the re-send writes the attempt row the once-only cap counts'
assert_present "$R/state/reloaded.inbox/002.msg" 'the re-send left a new inbox record'
OLD_CORR=$(LC_ALL=C grep -o 'corr=[A-Fa-f0-9]*' "$R/state/reloaded.inbox/001.msg" | head -1)
NEW_CORR=$(LC_ALL=C grep -o 'corr=[A-Fa-f0-9]*' "$R/state/reloaded.inbox/002.msg" | head -1)
assert_not_equals '' "$NEW_CORR" 'the re-send carries a correlation id'
assert_not_equals "$OLD_CORR" "$NEW_CORR" \
  'the re-send mints a fresh correlation id, so the duplicate is detectable'
assert_present "$R/state/reloaded.inbox/001.msg" 'the original unclaimed record is never discarded'
OUT=$(ladder "$R" alive sess:reloaded run)
ROW=$(row "$OUT" reloaded)
assert_equals escalate_captain "$(field "$ROW" rung)" \
  'once the once-only cap is spent the same lane escalates instead of re-sending again'
assert_contains "$ROW" 'action=parked' 'the escalation parks the lane for a person'
assert_grep "$(printf 'escalate_captain\tparked')" "$R/state/.lane-recovery-reloaded" \
  'the ladder log carries the escalation that followed the re-send'

# --- the worst case itself: 2 restarts, 1 switch, 1 redispatch, then a page --
# Every counter state is driven through the ladder own decisions, each seeded
# as the durable attempt rows those decisions read, and the final page is
# executed. A third restart, a second switch, or a second re-send at any step
# would have to appear as a decision this walk makes.
R=$(home worstcase)
lane "$R" doomed 4000
pane "$R" doomed 'stream disconnected before completion'
conf "$R" 'SWITCH_MODEL=some-other-model'
printf 'schema=1\nat=now\n--\nwork order\n' > "$R/state/doomed.inbox/001.msg"
LOG="$R/state/.lane-recovery-doomed"
OUT=$(ladder "$R" dead sess:doomed plan)
ROW=$(row "$OUT" doomed)
assert_equals restart_lane_agent "$(field "$ROW" rung)" 'the walk starts at the restart rung'
assert_contains "$ROW" 'attempt 1 of 2' 'the restart rung allows two attempts'
seed_row "$LOG" restart_lane_agent attempt
OUT=$(ladder "$R" dead sess:doomed plan)
assert_contains "$(row "$OUT" doomed)" 'attempt 2 of 2' 'the second restart attempt is the last one'
seed_row "$LOG" restart_lane_agent attempt
OUT=$(ladder "$R" dead sess:doomed plan)
ROW=$(row "$OUT" doomed)
assert_equals switch_model_or_harness "$(field "$ROW" rung)" \
  'a provider fault after two restarts reaches the switch rung'
assert_contains "$ROW" 'attempt 1 of 1' 'the switch rung admits one model switch per lane'
seed_row "$LOG" switch_model_or_harness attempt
OUT=$(ladder "$R" dead sess:doomed plan)
ROW=$(row "$OUT" doomed)
assert_equals escalate_captain "$(field "$ROW" rung)" \
  'a second model switch is never offered'
assert_contains "$ROW" 'ceilings are spent' 'the escalation says both ceilings are spent'
OUT=$(ladder "$R" alive sess:doomed plan)
ROW=$(row "$OUT" doomed)
assert_equals redispatch "$(field "$ROW" rung)" \
  'a recovered lane that still holds pending work re-sends before the page'
seed_row "$LOG" redispatch attempt
OUT=$(ladder "$R" alive sess:doomed plan)
assert_equals escalate_captain "$(field "$(row "$OUT" doomed)" rung)" \
  'a second re-send is never offered'
conf "$R" 'RECOVERY=acting'
OUT=$(ladder "$R" alive sess:doomed run)
assert_contains "$(row "$OUT" doomed)" 'action=parked' \
  'exhaustion ends in the page, not in another rung'
assert_equals 2 "$(attempt_count "$LOG" restart_lane_agent)" \
  'at most two restarts were produced'
assert_equals 1 "$(attempt_count "$LOG" switch_model_or_harness)" \
  'at most one model switch was produced'
assert_equals 1 "$(attempt_count "$LOG" redispatch)" \
  'at most one re-send was produced'
assert_grep "$(printf 'escalate_captain\tparked')" "$LOG" \
  'the page is the last thing the ladder produced'

# --- probe, decide and act happen under the lane's liveness lock ------------
R=$(home locked)
lane "$R" heldup 4000
pane "$R" heldup 'nothing interesting'
printf 'schema=1\nat=now\n--\nwork order\n' > "$R/state/heldup.inbox/001.msg"
conf "$R" 'RECOVERY=acting'
LOCK="$R/state/.secondmate-liveness-heldup.lock"
( . "$ROOT/bin/fm-wake-lib.sh" && fm_lock_try_acquire "$LOCK" && sleep 30 ) &
# shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
HOLDER=$!
sleep 1
OUT=$(ladder "$R" alive sess:heldup run)
assert_contains "$OUT" 'action=skipped' 'a lane whose lock is busy is skipped'
assert_contains "$OUT" 'another supervisor holds this lane' \
  'the skip says who holds the lane'
assert_absent "$R/state/.lane-recovery-heldup" \
  'nothing was decided or acted while another supervisor held the lock'
kill "$HOLDER" 2>/dev/null || true
wait "$HOLDER" 2>/dev/null || true
OUT=$(ladder "$R" alive sess:heldup run)
assert_contains "$OUT" 'rung=redispatch action=done' \
  'once the lock is free the probe, decision, and act all proceed'
assert_grep "$(printf 'redispatch\tattempt')" "$R/state/.lane-recovery-heldup" \
  'the acted rung wrote its attempt row'

# --- redispatch honors the config inbox override ----------------------------
R=$(home overridelane)
lane "$R" shifted 4000
pane "$R" shifted 'nothing interesting'
CONF="$R/config/response-lanes.conf"
grep -v '^lane shifted$' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
mkdir -p "$R/alt"
printf 'schema=1\nat=now\n--\nwork order from the overridden inbox\n' > "$R/alt/001.msg"
conf "$R" "lane shifted $R/alt"
OUT=$(ladder "$R" alive sess:shifted plan)
ROW=$(row "$OUT" shifted)
assert_equals redispatch "$(field "$ROW" rung)" \
  'the rail counts the overridden inbox, so the rung applies'
assert_contains "$ROW" 'holds 1 unclaimed work order' 'the plan counts the record in the overridden inbox'
conf "$R" 'RECOVERY=acting'
OUT=$(ladder "$R" alive sess:shifted run)
ROW=$(row "$OUT" shifted)
assert_contains "$ROW" 'rung=redispatch action=done sent=1' \
  'the re-send read the overridden inbox, not the default one'
assert_present "$R/state/shifted.inbox/001.msg" \
  'the re-sent record lands where fm-send writes'
assert_present "$R/alt/001.msg" \
  'the original record in the overridden inbox is never touched'

# --- one owner: the inbox on the rail's line is the inbox re-sent from -------
# The rail resolves the override and prints the exact path it counted, and the
# ladder reads that path back off the line, so a quoting-sensitive record is
# read from the directory the count came from and crosses the round trip whole.
R=$(home inboxdrift)
lane "$R" scribe 4000
pane "$R" scribe 'nothing interesting'
CONF="$R/config/response-lanes.conf"
grep -v '^lane scribe$' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
mkdir -p "$R/alt"
# shellcheck disable=SC2016  # the literal $ is the quoting-sensitive value under test
printf 'schema=1\nat=now\n--\nquoted "body" with $dollar and \\back\\slash and %s\n' "'single'" > "$R/alt/001.msg"
conf "$R" "lane scribe $R/alt"
OUT=$(PATH="$(fake_tmux "$R/fake-rail" alive sess:scribe):$BASE_PATH" FM_TEST_SEAM=1 \
  FM_HOME="$R" FM_STATE_OVERRIDE="$R/state" FM_CONFIG_OVERRIDE="$R/config" \
  "$ROOT/bin/fm-lane-liveness.sh" read 2>&1)
RAIL_ROW=$(printf '%s\n' "$OUT" | grep '^lane=scribe ')
assert_equals "$R/alt" "$(field "$RAIL_ROW" inbox)" \
  'the rail prints the override inbox it resolved and counted'
assert_equals 1 "$(field "$RAIL_ROW" pending_count)" \
  'the count on that same line came from the printed inbox'
conf "$R" 'RECOVERY=acting'
OUT=$(ladder "$R" alive sess:scribe run)
ROW=$(row "$OUT" scribe)
assert_contains "$ROW" 'action=done sent=1' \
  'the ladder re-sent from the inbox the rail printed, the only one holding the record'
assert_present "$R/alt/001.msg" 'the original record stays in the override inbox'
assert_present "$R/state/scribe.inbox/001.msg" 'the re-send landed in the lane own inbox'
# shellcheck disable=SC2016  # the literal $ is the quoting-sensitive value under test
assert_grep 'quoted "body" with $dollar and \back\slash and '\''single'\''' \
  "$R/state/scribe.inbox/001.msg" \
  'the quoting-sensitive body crossed the read and the re-send unchanged'

# --- no unhealthy lane ever ends at rung=none -------------------------------
# The invariant, asserted directly across every endpoint state: a dead verdict
# must never produce rung=none, whatever the probe said.
for state in alive dead ambiguous unreadable missing; do
  R=$(home "invariant-$state")
  lane "$R" sick 4000
  pane "$R" sick 'nothing interesting'
  OUT=$(ladder "$R" "$state" sess:sick plan)
  ROW=$(row "$OUT" sick)
  assert_equals dead "$(field "$ROW" verdict)" "the $state fixture must really be a dead lane"
  assert_not_equals none "$(field "$ROW" rung)" \
    "a dead lane with an $state endpoint must not report nothing to do"
done

# --- planning changes nothing -----------------------------------------------
R=$(home nomutate)
lane "$R" downed 4000
pane "$R" downed 'nothing interesting'
ladder "$R" dead sess:downed plan > /dev/null
assert_absent "$R/state/.lane-recovery-downed" 'planning writes no ladder log'
assert_absent "$R/state/.secondmate-relaunch-downed" 'planning consumes no relaunch budget'

# --- the off-switch ---------------------------------------------------------
R=$(home offswitch)
lane "$R" downed 4000
pane "$R" downed 'nothing interesting'
OUT=$(ladder "$R" dead sess:downed run)
assert_contains "$OUT" 'refusing to act' 'run refuses while the off-switch is off'
assert_contains "$OUT" 'action=would-run' 'a refused run degrades to printing the plan'
assert_absent "$R/state/.lane-recovery-downed" 'a refused run writes no ladder log'
conf "$R" 'RECOVERY=dry-run'
OUT=$(ladder "$R" dead sess:downed run)
assert_contains "$OUT" 'refusing to act' 'dry-run is still not acting'
assert_absent "$R/state/.lane-recovery-downed" 'RECOVERY=dry-run writes no ladder log either'

# --- parking keeps recovery out of a human decision -------------------------
R=$(home parked)
lane "$R" held 4000
pane "$R" held 'nothing interesting'
printf '%s\t%s\t%s\t%s\n' "$NOW" escalate_captain parked 'fixture' > "$R/state/.lane-recovery-held"
OUT=$(ladder "$R" dead sess:held plan)
ROW=$(row "$OUT" held)
assert_equals none "$(field "$ROW" rung)" 'a parked lane stays out of automatic recovery'
assert_contains "$ROW" 'until it is cleared' 'the reason says what would re-arm it'
OUT=$(ladder "$R" dead sess:held clear held)
assert_contains "$OUT" 're-armed' 'clear reports that the lane is re-armed'
OUT=$(ladder "$R" dead sess:held plan)
assert_not_equals none "$(field "$(row "$OUT" held)" rung)" \
  'a cleared lane is considered by the ladder again'

# --- a zero bound refuses instead of disabling the machinery -----------------
R=$(home zerobound)
lane "$R" downed 4000
pane "$R" downed 'nothing interesting'
conf "$R" 'COOLDOWN=0'
OUT=$(ladder "$R" dead sess:downed plan)
expect_code 2 $? 'a zero cooldown refuses rather than emptying the attempt window'
assert_contains "$OUT" 'positive whole number' 'the refusal says the bound must be positive'
R=$(home zerotimeout)
lane "$R" downed 4000
pane "$R" downed 'nothing interesting'
conf "$R" 'SSH_TIMEOUT=0'
OUT=$(ladder "$R" dead sess:downed plan)
expect_code 2 $? 'a zero ssh timeout refuses rather than removing the bound'
assert_contains "$OUT" 'SSH_TIMEOUT' 'the refusal names the offending key'

# A rail-key typo is refused by the rail, not the ladder, so the rail refusal
# must survive into the ladder's own error instead of being swallowed.
R=$(home railrefusal)
lane "$R" fine 0
conf "$R" 'W=soon'
OUT=$(ladder "$R" alive sess:fine plan)
expect_code 1 $? 'a rail that refuses its own config ends the plan'
assert_contains "$OUT" 'needs a whole number' 'the rail refusal naming the bad key survives'
assert_contains "$OUT" 'produced no reading' 'the ladder still reports the missing reading'

# --- an unconfigured home is inert -----------------------------------------
R="$TMP/off"
mkdir -p "$R/state" "$R/config"
OUT=$(FM_HOME="$R" FM_STATE_OVERRIDE="$R/state" FM_CONFIG_OVERRIDE="$R/config" "$LADDER" plan 2>&1)
assert_contains "$OUT" 'not configured' 'an unconfigured home says so and does nothing'
assert_contains "$OUT" 'is absent' 'a missing config file is labeled absent'

# A config that exists but names no lane is a different fault from a missing
# file and is reported as itself.
R="$TMP/emptycfg"
mkdir -p "$R/state" "$R/config"
printf '%s\n' '# fixture' > "$R/config/response-lanes.conf"
OUT=$(FM_HOME="$R" FM_STATE_OVERRIDE="$R/state" FM_CONFIG_OVERRIDE="$R/config" "$LADDER" plan 2>&1)
assert_contains "$OUT" 'names no lane' \
  'a config present but naming no lane is labeled as exactly that'
assert_not_contains "$OUT" 'is absent' \
  'a present config is never reported as absent'
OUT=$(FM_HOME="$R" FM_STATE_OVERRIDE="$R/state" FM_CONFIG_OVERRIDE="$R/config" "$LADDER" run 2>&1)
expect_code 2 $? 'running against a laneless config refuses'
assert_contains "$OUT" 'names no lane, so there is nothing to recover' \
  'the refusal names the real fault rather than a missing file'
assert_not_contains "$OUT" 'is absent' \
  'the refusal never reports a present config as absent'

pass 'fm-lane-recover.sh: refusals, rung ordering that does not short-circuit on probe liveness, no silent no-op on a dead lane, and a planning mode that changes nothing'
