#!/usr/bin/env bash
# tests/fm-unattended-session.test.sh - bin/fm-unattended-session.sh, the
# execution path from a queued trigger to a firstmate session start.
#
# The captain's 2026-08-03 ruling grants EXECUTION without a live human-started
# session and widens no approval authority. It binds four constraints on the
# implementation, and this suite exists to make each one red-capable rather than
# asserted in prose:
#
#   a. the session is identifiable as unattended IN ITS OWN RECORDS, so what it
#      did stays attributable afterwards;
#   b. it respects the per-home session lock and stays READ-ONLY when refused;
#   c. it never creates a SECOND supervision cycle alongside a live one;
#   d. starting itself is NOT licence to invent work - it acts on the drained
#      queue and already-registered work, never a self-directed survey.
#
# Every block witnesses its negative control first: the guard is proved by
# watching the same call go the other way when the one condition it names is
# removed. Guarantees are read through the public interface - exit status, the
# refuse_ tokens, the durable records, and the real session-start digest - never
# from the script's own source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

US="$ROOT/bin/fm-unattended-session.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-unattended-session)
fm_git_identity fmtest fmtest@example.invalid

OUT=""
CODE=0

# --- fixtures ----------------------------------------------------------------

# new_home <name>: a bare FM_HOME plus a fakebin and a recording launcher.
# Echoes "<home>|<fakebin>|<launcher>|<launcher-log>".
new_home() {
  local name=$1 dir home fakebin
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  mkdir -p "$home/state" "$home/config" "$home/data"
  fakebin=$(fm_fakebin "$dir")
  cat > "$dir/launcher" <<'SH'
#!/usr/bin/env bash
# Records the launch it was asked for, including the environment the started
# session would inherit. Never starts anything.
printf 'args=%s origin=%s home=%s\n' "$*" "${FM_SESSION_ORIGIN_ID:-none}" "${FM_HOME:-none}" \
  >> "${FM_FAKE_LAUNCH_LOG:?}"
exit "${FM_FAKE_LAUNCH_RC:-0}"
SH
  chmod +x "$dir/launcher"
  : > "$dir/launch.log"
  printf 'claude\n' > "$home/config/unattended-session"
  printf '%s|%s|%s|%s\n' "$home" "$fakebin" "$dir/launcher" "$dir/launch.log"
}

# queue_trigger <home> [key]: append one scheduled trigger to the durable queue
# through the production wake library, exactly as any session-independent
# producer does.
queue_trigger() {
  local home=$1 key=${2:-sched-probe}
  append_wake "$home/state" check "$key" "check: scheduled sweep due"
}

# us_run <home> <fakebin> [VAR=val ...] -- <args...>: run the script under a
# PATH holding only the fakebin and the system dirs.
us_run() {
  local home=$1 fakebin=$2
  shift 2
  local -a env_pairs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    env_pairs+=("$1")
    shift
  done
  shift
  OUT=$(env PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
    FM_UNATTENDED_LAUNCH_CMD="${FM_TEST_LAUNCHER:-}" \
    FM_FAKE_LAUNCH_LOG="${FM_TEST_LAUNCH_LOG:-/dev/null}" \
    ${env_pairs[@]+"${env_pairs[@]}"} "$US" "$@" 2>&1)
  CODE=$?
}

# start_live_harness: start a REAL background process and set LIVE_HARNESS_PID
# to its pid. The liveness half of the live-session guard is a real kill -0, so
# the process must genuinely exist; only its identification as a harness is a
# fixture, and that comes from fake_ps naming this pid in FM_FAKE_LIVE_HARNESSES.
# Splitting it that way is what lets the control case reuse the SAME live process
# and change only the identification.
#
# It sets a global rather than echoing, because fm_test_reap registers into this
# shell's arrays: called through $(...) the registration would die with the
# substitution subshell and orphan the sleeper on every failing path.
LIVE_HARNESS_PID=
start_live_harness() {
  sleep 300 &
  LIVE_HARNESS_PID=$!
  fm_test_reap "$LIVE_HARNESS_PID"
}

# arm_healthy_watcher <home>: a live, identity-matched watcher process holding
# this home's watch lock with a fresh beacon - the exact shape fm_watcher_healthy
# accepts. Echoes the watcher pid.
arm_healthy_watcher() {
  local home=$1 state="$1/state" pid identity
  sleep 60 &
  pid=$!
  fm_test_reap "$pid"
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$WAKE_LIB" "$pid") \
    || fail "could not read the fixture watcher's process identity"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$pid" > "$state/.watch.lock/pid"
  printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  printf '%s\n' "$pid"
}

# arm_away_supervisor <home>: away mode flagged, with a live process holding the
# away daemon's single-instance lock under the PRODUCTION process identity, which
# is the shape bin/fm-supervise-daemon.sh leaves behind. Liveness is decided by a
# real kill -0 against a real process; only the daemon's name is a fixture.
#
# Sets AWAY_DAEMON_PID rather than echoing, for the same reason
# start_live_harness does: fm_test_reap registers into this shell's arrays.
AWAY_DAEMON_PID=
arm_away_supervisor() {
  local home=$1 state="$1/state" identity
  mkdir -p "$state"
  date '+%s' > "$state/.afk"
  sleep 300 &
  AWAY_DAEMON_PID=$!
  fm_test_reap "$AWAY_DAEMON_PID"
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$WAKE_LIB" "$AWAY_DAEMON_PID") \
    || fail "could not read the fixture away daemon's process identity"
  mkdir -p "$state/.supervise-daemon.lock"
  printf '%s\n' "$AWAY_DAEMON_PID" > "$state/.supervise-daemon.lock/pid"
  printf '%s\n' "$identity" > "$state/.supervise-daemon.lock/pid-identity"
}

# kill_and_reap <pid>: end a fixture process and wait for it, so the pid names no
# process at all rather than an unreaped zombie that kill -0 still accepts.
kill_and_reap() {
  kill -KILL "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

# fake_ps <fakebin> : a deterministic process table. The pid named in
# $FM_FAKE_HARNESS_PID reports as a claude session and terminates the ancestry
# walk; every other pid reports as an ordinary shell. Any pid listed in
# $FM_FAKE_LIVE_HARNESSES (space separated) also reports as claude, which is how
# a fixture makes a REAL live process look like a competing session.
fake_ps() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid= previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
is_harness=0
[ -n "${FM_FAKE_HARNESS_PID:-}" ] && [ "$pid" = "$FM_FAKE_HARNESS_PID" ] && is_harness=1
case " ${FM_FAKE_LIVE_HARNESSES:-} " in *" $pid "*) is_harness=1 ;; esac
case "$*" in
  *comm=*) [ "$is_harness" = 1 ] && printf '%s\n' /usr/local/bin/claude || printf '%s\n' /bin/bash ;;
  *args=*) [ "$is_harness" = 1 ] && printf '%s\n' claude || printf '%s\n' bash ;;
  *ppid=*)
    if [ "$pid" = "${FM_FAKE_HARNESS_PID:-}" ]; then printf '%s\n' 1
    else printf '%s\n' "${FM_FAKE_HARNESS_PID:-1}"; fi
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
}

record_field() {  # <home> <key>
  sed -n "s/^$2=//p" "$1/state/.session-origin" 2>/dev/null | head -1
}

# --- (d) starting is not licence to invent work ------------------------------

test_start_refuses_without_a_queued_trigger() {
  local home fakebin launcher log
  IFS='|' read -r home fakebin launcher log <<EOF
$(new_home no-work)
EOF
  FM_TEST_LAUNCHER=$launcher FM_TEST_LAUNCH_LOG=$log

  # Registered work is deliberately present and deliberately NOT a trigger. A
  # home full of open tasks is exactly when a self-directed sweep is most
  # tempting, and the queue is still the only thing allowed to start a session.
  printf 'project=x\nwindow=fm-x\n' > "$home/state/open-task.meta"
  printf 'in flight: open-task\n' > "$home/data/backlog.md"

  us_run "$home" "$fakebin" -- start --trigger scheduled-sweep
  expect_code 1 "$CODE" "an empty queue must refuse the start"
  assert_contains "$OUT" "refuse_no_queued_work" "the refusal must name the missing queued work"
  assert_absent "$home/state/.session-origin" "a refused start must leave no origin record"
  assert_absent "$home/state/unattended-sessions.log" "a refused start must write no attribution log"
  [ ! -s "$log" ] || fail "a refused start invoked the launcher: $(cat "$log")"

  # Control: the ONE condition named above, and nothing else, changes.
  queue_trigger "$home"
  us_run "$home" "$fakebin" -- start --trigger scheduled-sweep
  expect_code 0 "$CODE" "a queued trigger must start a session: $OUT"
  assert_contains "$OUT" "UNATTENDED_START" "a successful start must report itself"
  assert_grep "args=--entry claude --detach" "$log" "the launcher was not asked for a detached scripted launch"

  pass "(d) an unattended session starts only for queued work, never to look for some"
}

# --- (c) never a second supervision cycle ------------------------------------

test_start_refuses_beside_a_live_session() {
  local home fakebin launcher log pid
  IFS='|' read -r home fakebin launcher log <<EOF
$(new_home live-session)
EOF
  FM_TEST_LAUNCHER=$launcher FM_TEST_LAUNCH_LOG=$log
  fake_ps "$fakebin"
  queue_trigger "$home"

  start_live_harness
  pid=$LIVE_HARNESS_PID
  printf '%s\n' "$pid" > "$home/state/.lock"

  us_run "$home" "$fakebin" "FM_FAKE_LIVE_HARNESSES=$pid" -- start
  expect_code 1 "$CODE" "a live session holding the lock must refuse the start"
  assert_contains "$OUT" "refuse_session_live" "the refusal must name the live session"
  [ ! -s "$log" ] || fail "a start refused for a live session still invoked the launcher"

  # Control: the same live process, the same lock file, but the process table no
  # longer reports it as a harness - so the verdict comes from the harness
  # liveness predicate rather than from the mere presence of a lock file.
  us_run "$home" "$fakebin" -- start
  expect_code 0 "$CODE" "a lock naming no live harness must not block the start: $OUT"
  assert_grep "args=--entry claude --detach" "$log" "the control start did not reach the launcher"

  pass "(c) a live session holding the home's lock refuses a second one"
}

test_start_refuses_beside_a_live_supervision_cycle() {
  local home fakebin launcher log
  IFS='|' read -r home fakebin launcher log <<EOF
$(new_home live-watcher)
EOF
  FM_TEST_LAUNCHER=$launcher FM_TEST_LAUNCH_LOG=$log
  queue_trigger "$home"
  arm_healthy_watcher "$home" >/dev/null

  us_run "$home" "$fakebin" -- start
  expect_code 1 "$CODE" "a healthy supervision cycle must refuse the start"
  assert_contains "$OUT" "refuse_supervision_live" "the refusal must name the live supervision cycle"
  [ ! -s "$log" ] || fail "a start refused for a live watcher still invoked the launcher"

  # Control: the same live watcher process and the same lock, with only the
  # beacon aged past the grace window, so the verdict rests on watcher HEALTH.
  touch -t 200001010000 "$home/state/.last-watcher-beat"
  us_run "$home" "$fakebin" -- start
  expect_code 0 "$CODE" "a lapsed supervision cycle must not block the start: $OUT"
  assert_grep "args=--entry claude --detach" "$log" "the control start did not reach the launcher"

  pass "(c) a healthy supervision cycle refuses a second one beside it"
}

test_start_refuses_while_a_launch_is_in_flight() {
  local home fakebin launcher log
  IFS='|' read -r home fakebin launcher log <<EOF
$(new_home inflight)
EOF
  FM_TEST_LAUNCHER=$launcher FM_TEST_LAUNCH_LOG=$log
  queue_trigger "$home"

  us_run "$home" "$fakebin" -- start
  expect_code 0 "$CODE" "the first start must proceed: $OUT"

  # The record that start just wrote is still pending, so a second timer firing
  # behind the first must not race it into a second session.
  us_run "$home" "$fakebin" -- start
  expect_code 1 "$CODE" "a pending launch must refuse a second concurrent start"
  assert_contains "$OUT" "refuse_launch_in_flight" "the refusal must name the launch already in flight"
  [ "$(grep -c . "$log")" -eq 1 ] || fail "a second start reached the launcher: $(cat "$log")"

  # Control: an expired pending record is not a live launch and never wedges the
  # home shut.
  us_run "$home" "$fakebin" FM_UNATTENDED_CLAIM_WINDOW=0 -- start
  expect_code 0 "$CODE" "an expired pending record must not block a later start: $OUT"

  pass "(c) a launch already in flight refuses a second session"
}

# --- (c) away mode: three answers about the supervisor, never two ------------
#
# The captain ruled on 2026-08-10 that this gate reads the away supervisor's
# LIVENESS, not the durable flag's presence: observed alive refuses, observed
# dead allows and says the supervisor died, and could-not-observe refuses under
# its own token. The three cases below hold those apart, because a gate that
# answered the same way to all three would pass a presence-only implementation.

test_away_mode_refuses_only_while_its_supervisor_is_alive() {
  local home fakebin launcher log dead_pid
  IFS='|' read -r home fakebin launcher log <<EOF
$(new_home away-live)
EOF
  FM_TEST_LAUNCHER=$launcher FM_TEST_LAUNCH_LOG=$log
  queue_trigger "$home"
  arm_away_supervisor "$home"
  dead_pid=$AWAY_DAEMON_PID

  us_run "$home" "$fakebin" -- start
  expect_code 1 "$CODE" "a live away supervisor must refuse the start"
  assert_contains "$OUT" "refuse_away_mode" "the refusal must name away mode"
  assert_contains "$OUT" "$dead_pid" "the refusal must name the supervisor it observed alive"
  [ ! -s "$log" ] || fail "a start refused for a live away supervisor still invoked the launcher"

  # Control: the flag stays set, the lock keeps naming the same pid and the same
  # recorded identity, and only the PROCESS dies. The verdict must move with the
  # process, because the flag is durable and outlives every supervisor that sets
  # it - the away session that dies and stays down for days is the measured case.
  kill_and_reap "$dead_pid"
  [ -f "$home/state/.afk" ] || fail "the fixture cleared the away flag, so the control proves nothing"

  us_run "$home" "$fakebin" -- start
  expect_code 0 "$CODE" "a dead away supervisor must not refuse the start: $OUT"
  assert_contains "$OUT" "UNATTENDED_AWAY_SUPERVISOR_DEAD" \
    "a start that stepped past a dead away supervisor must surface it, not allow silently"
  assert_contains "$OUT" "fm-supervise-daemon.sh" "the surfaced line must name the daemon that died"
  assert_contains "$OUT" "pid=$dead_pid" "the surfaced line must name the dead supervisor's recorded pid"
  assert_contains "$OUT" "last_activity=" "the surfaced line must carry a last-activity time or say it is unreadable"
  assert_grep "away-supervisor-dead" "$home/state/unattended-sessions.log" \
    "the dead supervisor left no attribution line, so it stops being attributable afterwards"
  assert_grep "args=--entry claude --detach" "$log" "the allowed start did not reach the launcher"

  pass "(c) away mode refuses while its supervisor is alive, and steps past it once it is dead"
}

test_away_supervisor_liveness_that_cannot_be_observed_refuses_distinctly() {
  local home fakebin launcher log identity
  IFS='|' read -r home fakebin launcher log <<EOF
$(new_home away-unknown)
EOF
  FM_TEST_LAUNCHER=$launcher FM_TEST_LAUNCH_LOG=$log
  queue_trigger "$home"
  arm_away_supervisor "$home"
  identity=$(cat "$home/state/.supervise-daemon.lock/pid-identity")

  # A lock owner whose pid is live but whose recorded identity is missing: the
  # daemon cannot be identified without falling back to a process-pattern search,
  # which would match the wrong process. That is could-not-observe, and it must
  # refuse under a token that says so rather than under the observed-alive one.
  rm -f "$home/state/.supervise-daemon.lock/pid-identity"
  us_run "$home" "$fakebin" -- start
  expect_code 1 "$CODE" "an unobservable away supervisor must refuse the start"
  assert_contains "$OUT" "refuse_away_liveness_unknown" \
    "could-not-observe must refuse under its own token"
  assert_not_contains "$OUT" "refuse_away_mode" \
    "could-not-observe must not read as an observed-alive refusal"
  assert_contains "$OUT" "identity" "the refusal must name what could not be determined"
  [ ! -s "$log" ] || fail "an unobservable away supervisor still invoked the launcher"

  # A lock owner whose pid is not a number names no process to ask about either.
  printf 'not-a-pid\n' > "$home/state/.supervise-daemon.lock/pid"
  us_run "$home" "$fakebin" -- start
  expect_code 1 "$CODE" "a lock recording no readable pid must refuse the start"
  assert_contains "$OUT" "refuse_away_liveness_unknown" \
    "an unreadable pid must refuse as could-not-observe"
  assert_not_contains "$OUT" "refuse_away_mode" \
    "an unreadable pid must not be narrowed into observed-alive"

  # Control: restore exactly what was removed - the same live pid and the
  # identity it was recorded under - and the same call becomes observed-alive.
  # Could-not-observe is therefore its own answer, not a relabelled one.
  printf '%s\n' "$AWAY_DAEMON_PID" > "$home/state/.supervise-daemon.lock/pid"
  printf '%s\n' "$identity" > "$home/state/.supervise-daemon.lock/pid-identity"
  us_run "$home" "$fakebin" -- start
  expect_code 1 "$CODE" "the restored live supervisor must still refuse"
  assert_contains "$OUT" "refuse_away_mode" "a restored identity match must read as observed-alive"
  assert_not_contains "$OUT" "refuse_away_liveness_unknown" \
    "an observable live supervisor must not refuse as could-not-observe"
  [ ! -s "$log" ] || fail "no away-mode case here may reach the launcher"

  pass "(c) an away supervisor whose liveness cannot be observed refuses under its own token"
}

test_away_flag_with_no_supervisor_behind_it_does_not_wedge_the_home_shut() {
  local home fakebin launcher log
  IFS='|' read -r home fakebin launcher log <<EOF
$(new_home away-flag-only)
EOF
  FM_TEST_LAUNCHER=$launcher FM_TEST_LAUNCH_LOG=$log
  queue_trigger "$home"

  # The durable flag with nothing holding the daemon's single-instance lock: the
  # supervisor that set it is gone, and the flag alone must not refuse for ever.
  date '+%s' > "$home/state/.afk"
  [ ! -e "$home/state/.supervise-daemon.lock" ] || fail "the fixture left a daemon lock behind"

  us_run "$home" "$fakebin" -- start
  expect_code 0 "$CODE" "an away flag with no supervisor behind it must not refuse the start: $OUT"
  assert_contains "$OUT" "UNATTENDED_AWAY_SUPERVISOR_DEAD" \
    "the start must surface that away mode's supervisor is not alive"
  assert_contains "$OUT" "last_activity=unreadable" \
    "with no lock to read, the surfaced line must say the last-activity time is unreadable rather than invent one"
  assert_grep "away-supervisor-dead" "$home/state/unattended-sessions.log" \
    "the missing supervisor left no attribution line"
  assert_grep "args=--entry claude --detach" "$log" "the allowed start did not reach the launcher"

  pass "(c) a durable away flag with no live supervisor behind it never wedges unattended execution shut"
}

# --- (a) identifiable as unattended in its own records -----------------------

test_start_and_claim_leave_an_attributable_record() {
  local home fakebin launcher log origin_id claimed_pid
  IFS='|' read -r home fakebin launcher log <<EOF
$(new_home attribution)
EOF
  FM_TEST_LAUNCHER=$launcher FM_TEST_LAUNCH_LOG=$log
  fake_ps "$fakebin"
  queue_trigger "$home"

  us_run "$home" "$fakebin" -- start --trigger scheduled-sweep
  expect_code 0 "$CODE" "the start must succeed: $OUT"
  origin_id=$(record_field "$home" origin_id)
  [ -n "$origin_id" ] || fail "the start left no origin id"
  [ "$(record_field "$home" origin)" = unattended ] || fail "the origin record does not read unattended"
  [ "$(record_field "$home" state)" = pending ] || fail "a started-but-unclaimed record must be pending"
  assert_grep "$origin_id" "$home/state/unattended-sessions.log" "the attribution log does not carry the origin id"
  assert_grep "declared" "$home/state/unattended-sessions.log" "the attribution log has no declaration line"
  assert_grep "launched" "$home/state/unattended-sessions.log" "the attribution log has no launch line"
  assert_grep "origin=$origin_id" "$log" "the launcher did not receive the origin id the record names"

  # The session the launcher would have started: it owns the lock, so it may
  # bind the record to itself.
  printf '%s\n' 4242 > "$home/state/.lock"
  us_run "$home" "$fakebin" "FM_FAKE_HARNESS_PID=4242" "FM_SESSION_ORIGIN_ID=$origin_id" -- claim
  expect_code 0 "$CODE" "a lock-owning session must claim its origin record: $OUT"
  [ "$(record_field "$home" state)" = claimed ] || fail "the claimed record does not read claimed"
  claimed_pid=$(record_field "$home" harness_pid)
  [ "$claimed_pid" = 4242 ] || fail "the record was not bound to the session-lock holder (got '$claimed_pid')"
  assert_grep "claimed" "$home/state/unattended-sessions.log" "the attribution log has no claim line"

  us_run "$home" "$fakebin" "FM_FAKE_HARNESS_PID=4242" -- session
  assert_contains "$OUT" "session_origin=unattended claimed=yes" \
    "a claimed session must still identify itself without the launch environment"

  # Control 1: a session of the same home that does NOT hold the record's lock is
  # attended. A stale claimed record can never relabel a later captain-started
  # session as unattended.
  printf '%s\n' 5150 > "$home/state/.lock"
  us_run "$home" "$fakebin" "FM_FAKE_HARNESS_PID=5150" -- session
  assert_contains "$OUT" "session_origin=attended" \
    "a session holding a different lock was mislabelled from a stale record"

  # Control 2: a home that never ran an unattended start has no record at all,
  # so absence keeps its meaning - no marker means captain-started.
  local other ofakebin
  IFS='|' read -r other ofakebin _ _ <<EOF
$(new_home attribution-control)
EOF
  us_run "$other" "$ofakebin" -- session
  assert_contains "$OUT" "session_origin=attended" "a home with no origin record must read attended"
  us_run "$other" "$ofakebin" -- status
  assert_contains "$OUT" "origin=none" "a home with no origin record must report none"

  pass "(a) an unattended session is identifiable and attributable in its own records"
}

# --- (b) lock-refused stays read-only ----------------------------------------

test_claim_is_the_only_write_and_it_needs_the_lock() {
  local home fakebin launcher log origin_id before_record before_log
  IFS='|' read -r home fakebin launcher log <<EOF
$(new_home read-only-claim)
EOF
  FM_TEST_LAUNCHER=$launcher FM_TEST_LAUNCH_LOG=$log
  fake_ps "$fakebin"
  queue_trigger "$home"
  us_run "$home" "$fakebin" -- start
  expect_code 0 "$CODE" "the start must succeed: $OUT"
  origin_id=$(record_field "$home" origin_id)

  # Another session owns the lock, so this one never verified ownership.
  printf '%s\n' 9001 > "$home/state/.lock"
  before_record=$(cat "$home/state/.session-origin")
  before_log=$(cat "$home/state/unattended-sessions.log")

  us_run "$home" "$fakebin" "FM_FAKE_HARNESS_PID=4242" "FM_SESSION_ORIGIN_ID=$origin_id" -- claim
  expect_code 1 "$CODE" "a session that does not own the lock must not claim"
  assert_contains "$OUT" "refuse_lock_not_owned" "the refusal must name the unverified lock ownership"
  [ "$(cat "$home/state/.session-origin")" = "$before_record" ] \
    || fail "a lock-refused claim modified the origin record"
  [ "$(cat "$home/state/unattended-sessions.log")" = "$before_log" ] \
    || fail "a lock-refused claim appended to the attribution log"

  # It is still able to SAY what it is, because reporting is a read.
  us_run "$home" "$fakebin" "FM_SESSION_ORIGIN_ID=$origin_id" -- session
  assert_contains "$OUT" "session_origin=unattended claimed=no" \
    "a lock-refused unattended session must still identify itself"

  # Control: the same call inside the session that does own the lock writes.
  printf '%s\n' 4242 > "$home/state/.lock"
  us_run "$home" "$fakebin" "FM_FAKE_HARNESS_PID=4242" "FM_SESSION_ORIGIN_ID=$origin_id" -- claim
  expect_code 0 "$CODE" "the lock-owning control claim must succeed: $OUT"
  [ "$(cat "$home/state/.session-origin")" != "$before_record" ] \
    || fail "the control claim wrote nothing, so the read-only assertion above proves nothing"

  pass "(b) claiming is the only write, and a session without verified lock ownership makes none"
}

# --- end to end: a queued trigger starts a session that drains and acts ------

# new_world <name>: the fixture a real bin/fm-session-start.sh run needs - a git
# repo on main for FM_ROOT_OVERRIDE (so the worktree-tangle check behaves), an
# FM_HOME, a fakebin, and the launcher. Echoes "<root>|<home>|<fakebin>|<log>".
new_world() {
  local name=$1 dir root home fakebin
  dir="$TMP_ROOT/$name"
  root="$dir/root"
  home="$dir/home"
  mkdir -p "$home/state" "$home/config" "$home/data"
  fakebin=$(fm_fakebin "$dir")
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  printf 'claude\n' > "$home/config/unattended-session"
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi lavish-axi gh gh-axi \
    tasks-axi treehouse no-mistakes
  fake_ps "$fakebin"
  printf '%s|%s|%s|%s\n' "$root" "$home" "$fakebin" "$dir/launch.log"
}

# A launcher that actually starts the session, so the assertion below runs
# against the REAL bin/fm-session-start.sh with the environment an unattended
# launch hands it. Only the terminal and the harness binary are substituted.
write_session_launcher() {  # <dir> <root> <fakebin> <out>
  local dir=$1 root=$2 fakebin=$3 out=$4
  cat > "$dir/launcher" <<SH
#!/usr/bin/env bash
env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \\
  PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$root" \\
  FM_FAKE_HARNESS_PID=4242 \\
  "$SESSION_START" > "$out" 2>&1
SH
  chmod +x "$dir/launcher"
  printf '%s\n' "$dir/launcher"
}

test_queued_trigger_starts_a_session_that_drains_and_acts() {
  local root home fakebin log dir launcher out
  IFS='|' read -r root home fakebin log <<EOF
$(new_world e2e)
EOF
  dir=$(dirname "$root")
  out="$dir/session.out"
  launcher=$(write_session_launcher "$dir" "$root" "$fakebin" "$out")

  queue_trigger "$home" scheduled-sweep
  [ -s "$home/state/.wake-queue" ] || fail "the fixture failed to queue a trigger"

  us_run "$home" "$fakebin" "FM_UNATTENDED_LAUNCH_CMD=$launcher" -- start --trigger scheduled-sweep
  expect_code 0 "$CODE" "the queued trigger must start a session: $OUT"

  local digest
  digest=$(cat "$out")
  assert_contains "$digest" "UNATTENDED SESSION" "the started session did not announce itself as unattended"
  assert_contains "$digest" "PARKS" "the unattended banner did not carry the park-rather-than-widen rule"
  assert_contains "$digest" "- Session origin: unattended" \
    "the supervision block did not carry the unattended origin"
  assert_contains "$digest" "scheduled sweep due" "the started session did not drain the queued trigger"

  # It ACTED: the durable queue it drained is now empty, and its own record is
  # bound to the session that did the draining.
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "the queue still holds records after the session drained: $(cat "$home/state/.wake-queue")"
  [ "$(record_field "$home" state)" = claimed ] \
    || fail "the started session did not claim its origin record"
  [ "$(record_field "$home" harness_pid)" = 4242 ] \
    || fail "the claimed record is not bound to the session-lock holder"

  pass "end to end: a queued trigger starts a session that drains the queue and records itself"
}

test_lock_refused_unattended_session_stays_read_only() {
  local root home fakebin log dir launcher out pid before_queue before_record
  IFS='|' read -r root home fakebin log <<EOF
$(new_world e2e-read-only)
EOF
  dir=$(dirname "$root")
  out="$dir/session.out"
  # A RECORDING launcher here, not a session-starting one: this case needs the
  # origin record written and the queue still full, so that the digest below is
  # the FIRST session to see either.
  launcher="$dir/record-only"
  cat > "$launcher" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$launcher"

  queue_trigger "$home" scheduled-sweep
  us_run "$home" "$fakebin" "FM_UNATTENDED_LAUNCH_CMD=$launcher" -- start --trigger scheduled-sweep
  expect_code 0 "$CODE" "the start must succeed before the read-only case can be posed: $OUT"

  # A live competing session takes the lock between the launch and the digest,
  # which is the only way a real unattended session reaches the refused path.
  start_live_harness
  pid=$LIVE_HARNESS_PID
  printf '%s\n' "$pid" > "$home/state/.lock"
  before_queue=$(cat "$home/state/.wake-queue")
  before_record=$(cat "$home/state/.session-origin")
  [ -n "$before_queue" ] || fail "the fixture queue is empty, so the read-only assertion would be vacuous"

  # Re-run the digest as that same started session, now lock-refused.
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_FAKE_HARNESS_PID=4242 FM_FAKE_LIVE_HARNESSES="$pid" \
    FM_SESSION_ORIGIN_ID="$(record_field "$home" origin_id)" \
    "$SESSION_START" > "$out" 2>&1 || fail "the digest must complete even when refused"

  local digest
  digest=$(cat "$out")
  assert_contains "$digest" "READ-ONLY SESSION" "the refused session did not announce read-only mode"
  assert_contains "$digest" "UNATTENDED SESSION" "a refused unattended session must still announce its origin"
  assert_contains "$digest" "claimed=no" "a refused unattended session must report itself unclaimed"
  [ "$(cat "$home/state/.wake-queue")" = "$before_queue" ] \
    || fail "a lock-refused unattended session drained the durable queue"
  [ "$(cat "$home/state/.session-origin")" = "$before_record" ] \
    || fail "a lock-refused unattended session wrote to its origin record"

  # Control: with the competing lock removed and nothing else changed, the same
  # session claims and drains - so the read-only assertions above are proved by
  # contrast rather than by a run that could never have written.
  rm -f "$home/state/.lock"
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_FAKE_HARNESS_PID=4242 \
    FM_SESSION_ORIGIN_ID="$(record_field "$home" origin_id)" \
    "$SESSION_START" > "$out" 2>&1 || fail "the control digest must complete"
  [ "$(record_field "$home" state)" = claimed ] \
    || fail "the control session did not claim, so the read-only assertion proves nothing"
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "the control session did not drain, so the read-only assertion proves nothing"

  pass "(b) a lock-refused unattended session announces itself and writes nothing"
}

# The two owners of constraint (b) - the digest's read-only guard and claim's own
# lock-ownership check - agree in almost every case, which makes it easy to ship
# one of them broken and never notice. This case separates them: the lock is
# UNUSABLE (a symlink, which bin/fm-lock.sh refuses outright) while its content
# still names this session's own harness, so claim's check would pass and only
# the digest's read-only guard stands between an unlocked session and a write.
test_read_only_session_never_claims_when_ownership_would_verify() {
  local root home fakebin log dir launcher out before_record before_queue digest
  IFS='|' read -r root home fakebin log <<EOF
$(new_world e2e-lock-unusable)
EOF
  dir=$(dirname "$root")
  out="$dir/session.out"
  launcher="$dir/record-only"
  cat > "$launcher" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$launcher"

  queue_trigger "$home" scheduled-sweep
  us_run "$home" "$fakebin" "FM_UNATTENDED_LAUNCH_CMD=$launcher" -- start --trigger scheduled-sweep
  expect_code 0 "$CODE" "the start must succeed before the case can be posed: $OUT"

  printf '%s\n' 4242 > "$dir/lock-target"
  ln -s "$dir/lock-target" "$home/state/.lock"
  before_record=$(cat "$home/state/.session-origin")
  before_queue=$(cat "$home/state/.wake-queue")
  [ -n "$before_queue" ] || fail "the fixture queue is empty, so the assertion would be vacuous"

  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_FAKE_HARNESS_PID=4242 \
    FM_SESSION_ORIGIN_ID="$(record_field "$home" origin_id)" \
    "$SESSION_START" > "$out" 2>&1 || fail "the digest must complete even when refused"

  digest=$(cat "$out")
  assert_contains "$digest" "READ-ONLY SESSION" "an unusable lock must produce a read-only session"
  assert_contains "$digest" "UNATTENDED SESSION" "a refused unattended session must still announce its origin"
  [ "$(cat "$home/state/.session-origin")" = "$before_record" ] \
    || fail "a read-only session claimed its origin record because ownership happened to verify"
  [ "$(cat "$home/state/.wake-queue")" = "$before_queue" ] \
    || fail "a read-only session drained the durable queue"

  # Control: the same session, the same ancestry, with only the lock made usable
  # - now it verifies ownership AND is allowed to write, so it claims.
  rm -f "$home/state/.lock"
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_FAKE_HARNESS_PID=4242 \
    FM_SESSION_ORIGIN_ID="$(record_field "$home" origin_id)" \
    "$SESSION_START" > "$out" 2>&1 || fail "the control digest must complete"
  [ "$(record_field "$home" state)" = claimed ] \
    || fail "the control session did not claim, so the assertion above proves nothing"

  pass "(b) a read-only session writes nothing even where its lock ownership would verify"
}

test_start_refuses_without_a_launch_entry() {
  local home fakebin launcher log
  IFS='|' read -r home fakebin launcher log <<EOF
$(new_home no-entry)
EOF
  FM_TEST_LAUNCHER=$launcher FM_TEST_LAUNCH_LOG=$log
  rm -f "$home/config/unattended-session"
  queue_trigger "$home"

  us_run "$home" "$fakebin" -- start
  expect_code 1 "$CODE" "an unconfigured home must refuse rather than guess a harness"
  assert_contains "$OUT" "refuse_no_entry" "the refusal must name the missing launch entry"
  [ ! -s "$log" ] || fail "an unconfigured start still invoked the launcher"

  # Control: the launcher's own last-used entry is an acceptable answer.
  printf 'codex\n' > "$home/state/.launch-last"
  us_run "$home" "$fakebin" -- start
  expect_code 0 "$CODE" "the last-used entry must satisfy the entry gate: $OUT"
  assert_grep "args=--entry codex --detach" "$log" "the fallback entry did not reach the launcher"

  pass "a start with no configured launch entry refuses rather than guessing a harness"
}

# The entry files are operator-authored, and this repo ships firstmate.bat and
# docs/windows-launcher.md - so one of them saved with CRLF line endings is an
# ordinary input. A carriage return that survived the read would fail the entry
# id's charset check while still counting as a populated value, and the operator
# would be told to name an entry in the file they had just populated.
test_a_crlf_saved_entry_file_still_names_its_entry() {
  local home fakebin launcher log
  IFS='|' read -r home fakebin launcher log <<EOF
$(new_home crlf-entry)
EOF
  FM_TEST_LAUNCHER=$launcher FM_TEST_LAUNCH_LOG=$log
  queue_trigger "$home"

  printf 'claude\r\n' > "$home/config/unattended-session"
  us_run "$home" "$fakebin" -- start
  expect_code 0 "$CODE" "a CRLF-saved config entry must be read as the entry it names: $OUT"
  assert_grep "args=--entry claude --detach" "$log" \
    "the entry the launcher received did not survive the CRLF line ending"

  # The launcher's own last-used entry is written by the same kind of operator
  # environment and has the same exposure.
  rm -f "$home/config/unattended-session" "$home/state/.session-origin"
  queue_trigger "$home"
  printf 'codex\r\n' > "$home/state/.launch-last"
  us_run "$home" "$fakebin" -- start
  expect_code 0 "$CODE" "a CRLF-saved last-used entry must be read as the entry it names: $OUT"
  assert_grep "args=--entry codex --detach" "$log" \
    "the fallback entry did not survive the CRLF line ending"

  pass "an entry file saved with CRLF line endings names its entry rather than refusing"
}

test_failed_launch_is_recorded_not_swallowed() {
  local home fakebin launcher log
  IFS='|' read -r home fakebin launcher log <<EOF
$(new_home launch-failure)
EOF
  FM_TEST_LAUNCHER=$launcher FM_TEST_LAUNCH_LOG=$log
  queue_trigger "$home"

  us_run "$home" "$fakebin" FM_FAKE_LAUNCH_RC=3 -- start
  expect_code 1 "$CODE" "a launcher refusal must refuse the start"
  assert_contains "$OUT" "refuse_launch_failed" "the refusal must name the failed launch"
  assert_grep "launch-failed" "$home/state/unattended-sessions.log" \
    "a failed launch left no trace, so an attempted unattended start would be unattributable"

  pass "a launch the launcher refuses is recorded rather than swallowed"
}

test_start_refuses_unknown_arguments() {
  local home fakebin launcher log
  IFS='|' read -r home fakebin launcher log <<EOF
$(new_home usage)
EOF
  FM_TEST_LAUNCHER=$launcher FM_TEST_LAUNCH_LOG=$log
  us_run "$home" "$fakebin" -- start --merge-everything
  expect_code 2 "$CODE" "an unknown option must be a usage error"
  us_run "$home" "$fakebin" -- conquer
  expect_code 2 "$CODE" "an unknown command must be a usage error"
  pass "unknown commands and options refuse as usage errors"
}

test_start_refuses_without_a_queued_trigger
test_start_refuses_beside_a_live_session
test_start_refuses_beside_a_live_supervision_cycle
test_start_refuses_while_a_launch_is_in_flight
test_away_mode_refuses_only_while_its_supervisor_is_alive
test_away_supervisor_liveness_that_cannot_be_observed_refuses_distinctly
test_away_flag_with_no_supervisor_behind_it_does_not_wedge_the_home_shut
test_start_and_claim_leave_an_attributable_record
test_claim_is_the_only_write_and_it_needs_the_lock
test_start_refuses_without_a_launch_entry
test_a_crlf_saved_entry_file_still_names_its_entry
test_failed_launch_is_recorded_not_swallowed
test_start_refuses_unknown_arguments
test_queued_trigger_starts_a_session_that_drains_and_acts
test_lock_refused_unattended_session_stays_read_only
test_read_only_session_never_claims_when_ownership_would_verify
