#!/usr/bin/env bash
# tests/fm-boot-resume.test.sh - the boot-resume decision surface
# (bin/fm-boot-resume-lib.sh with its entries bin/fm-boot-resume.sh and
# bin/fm-watchdog-beat.sh, plus bin/fm-boot-resume-install.sh): the gate order
# (kill switch, posture, per-boot idempotence, live-primary skip), the
# exact-conversation primary-pane match and its ambiguity refusal, the
# restore argv (permission default, home args, --resume of the recorded
# session) and the standing recovery prompt, the bounded attempt ledger with
# its park marker and exactly one inbox note, the secondmate fallback that
# runs only when the primary restore failed and honors the shared probe
# verdicts, the watchdog's healthy-silent / stale-nudge / stale-restore
# ladder against a real watcher-lock fixture, and the installer's rendered
# units and enable steps. Herdr, the goal gate, the inbox, and the
# secondmate probe/relaunch calls are pinned through the library's declared
# FM_TEST_SEAM shim; the away-posture gate is exercised against the real
# bin/fm-afk-contract.sh record owner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOOT="$ROOT/bin/fm-boot-resume.sh"
WATCHDOG="$ROOT/bin/fm-watchdog-beat.sh"
INSTALL="$ROOT/bin/fm-boot-resume-install.sh"
CONTRACT="$ROOT/bin/fm-afk-contract.sh"

TMP_ROOT=$(fm_test_tmproot fm-boot-resume-tests)

# fm_pid_identity, for the identity-complete watcher-lock fixture below.
mkdir -p "$TMP_ROOT/wakehome"
FM_HOME="$TMP_ROOT/wakehome" . "$ROOT/bin/fm-wake-lib.sh"

# The shim every entry-script run sources (the library honors it only under
# FM_TEST_SEAM=1, which tests/lib.sh arms). Defaults: no active goal, the
# inbox recorded to a file, secondmate probes refusing to authorize anything.
# A case overrides behavior through the FM_SHIM_* environment.
SHIM="$TMP_ROOT/shim.sh"
cat > "$SHIM" <<'SH'
fm_btr_goal_active() { [ -n "${FM_SHIM_GOAL:-}" ]; }
fm_btr_inbox_note() {
  printf '%s\t%s\n' "$1" "$2" >> "${FM_SHIM_INBOX_LOG:?}"
}
fm_btr_sm_probe() {
  eval "${FM_SHIM_SM_PROBE:-return 1}"
}
fm_btr_sm_relaunch() {
  printf '%s\t%s\n' "$2" "${FM_SM_LIVE_STATE:-unknown}" >> "${FM_SHIM_SM_RELAUNCH_LOG:-/dev/null}"
  FM_SM_LIVE_OUT='shim relaunch'
  return "${FM_SHIM_SM_RELAUNCH_RC:-0}"
}
SH

# A fake herdr that speaks exactly the surface the library uses: session list
# (plain and --json, failing while FM_FAKE_HERDR_DOWN stands for the readiness
# probe), per-session agent list from FM_FAKE_HERDR_AGENTS, and agent
# start/prompt recorded (verb, session, argv) to FM_FAKE_HERDR_LOG.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
log="${FM_FAKE_HERDR_LOG:?}"
session=
if [ "${1:-}" = "--session" ]; then
  session=$2
  shift 2
fi
case "${1:-}" in
  session)
    [ ! -e "${FM_FAKE_HERDR_DOWN:-}" ] || exit 1
    for arg in "$@"; do
      [ "$arg" = --json ] && { cat "${FM_FAKE_HERDR_SESSIONS:?}"; exit 0; }
    done
    echo "ok"
    exit 0
    ;;
  agent)
    case "${2:-}" in
      list) cat "${FM_FAKE_HERDR_AGENTS:?}"; exit 0 ;;
      start|prompt)
        printf '%s %s %s\n' "$1" "$session" "$*" >> "$log"
        if [ "$1" = start ]; then
          exit "${FM_FAKE_HERDR_START_RC:-0}"
        fi
        exit "${FM_FAKE_HERDR_PROMPT_RC:-0}"
        ;;
    esac
    ;;
esac
echo "fake herdr: unexpected $*" >&2
exit 64
SH
chmod +x "$FAKEBIN/herdr"

# A fake systemctl that records its argv, for the installer's enable path.
cat > "$FAKEBIN/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_SYSTEMCTL_LOG:?}"
exit 0
SH
chmod +x "$FAKEBIN/systemctl"

SID="11111111-2222-3333-4444-555555555555"

make_home() {  # <name> -> prints the home dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config"
  printf '%s\n' "$dir"
}

agent_row() {  # <pane> <session-id-or-null> <cwd> <agent>
  printf '{"agent":"%s","agent_session":%s,"cwd":"%s","pane_id":"%s","agent_status":"done"}' \
    "$4" \
    "$(if [ "$2" = null ]; then echo null; else printf '{"value":"%s"}' "$2"; fi)" \
    "$3" "$1"
}

# A home whose primary died with the reboot: a stale lock pid, the recorded
# conversation id, running herdr session s1 with the matching pane w1:p2 and
# one unrelated agent pane.
prepare_restorable_home() {  # <home>
  local h=$1
  printf '999999\n' > "$h/state/.lock"
  printf '%s\n' "$SID" > "$h/state/.lock-session"
  cat > "$TMP_ROOT/sessions.json" <<EOF
{"sessions":[{"name":"s1","running":true},{"name":"s2","running":false}]}
EOF
  printf '%s\n' "{\"id\":\"cli:agent:list\",\"result\":{\"agents\":[$(agent_row w1:p2 "$SID" "$h" claude),$(agent_row w2:p9 null "$h" claude)]}}" > "$TMP_ROOT/agents.json"
}

run_boot() {  # <home> [args...]
  local h=$1
  shift
  FM_TEST_SEAM=1 FM_TEST_BOOT_ID=test-boot-id \
  FM_HOME="$h" FM_TEST_BOOT_RESUME_SHIM="$SHIM" \
  FM_FAKE_HERDR_LOG="$TMP_ROOT/herdr.log" \
  FM_FAKE_HERDR_SESSIONS="$TMP_ROOT/sessions.json" \
  FM_FAKE_HERDR_AGENTS="$TMP_ROOT/agents.json" \
  FM_SHIM_INBOX_LOG="$TMP_ROOT/inbox.log" \
  PATH="$FAKEBIN:$PATH" "$BOOT" "$@"
}

run_watchdog() {  # <home> [args...]
  local h=$1
  shift
  FM_TEST_SEAM=1 FM_TEST_BOOT_ID=test-boot-id \
  FM_HOME="$h" FM_TEST_BOOT_RESUME_SHIM="$SHIM" \
  FM_FAKE_HERDR_LOG="$TMP_ROOT/herdr.log" \
  FM_FAKE_HERDR_SESSIONS="$TMP_ROOT/sessions.json" \
  FM_FAKE_HERDR_AGENTS="$TMP_ROOT/agents.json" \
  FM_SHIM_INBOX_LOG="$TMP_ROOT/inbox.log" \
  PATH="$FAKEBIN:$PATH" "$WATCHDOG" "$@"
}

herdr_calls() {
  local n
  n=$(grep -c . "$TMP_ROOT/herdr.log" 2>/dev/null) || n=0
  printf '%s\n' "$n"
}

start_calls() {
  local n
  n=$(grep -c 'start firstmate' "$TMP_ROOT/herdr.log" 2>/dev/null) || n=0
  printf '%s\n' "$n"
}

# Background helpers write the spawned pid to a file: a pid captured from a
# command substitution dies with that substitution's shell, so every process
# these fixtures rely on is a direct child of the test shell (the pattern
# tests/fm-afk-launch.test.sh uses for its sleeper fixtures).
SPAWN_PID_FILE="$TMP_ROOT/spawn.pid"

start_fake_harness() {  # a live pid whose argv0 reads as a claude harness
  bash -c 'exec -a claude sleep 120' >/dev/null 2>&1 &
  printf '%s\n' $! > "$SPAWN_PID_FILE"
}

start_sleeper() {
  sleep 120 >/dev/null 2>&1 &
  printf '%s\n' $! > "$SPAWN_PID_FILE"
}

spawned_pid() {
  cat "$SPAWN_PID_FILE"
}

# A real, identity-complete watcher lock plus beacon, so the watchdog's
# health check runs against the genuine fm_watcher_healthy primitive.
make_watcher_lock() {  # <home> <pid> <beacon-age-seconds>
  local h=$1 pid=$2 age=$3
  mkdir -p "$h/state/.watch.lock"
  printf '%s\n' "$pid" > "$h/state/.watch.lock/pid"
  printf '%s\n' "$h" > "$h/state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$h/state/.watch.lock/watcher-path"
  fm_pid_identity "$pid" > "$h/state/.watch.lock/pid-identity"
  if [ "$age" -gt 0 ]; then
    touch -d "@$(( $(date +%s) - age ))" "$h/state/.last-watcher-beat"
  else
    touch "$h/state/.last-watcher-beat"
  fi
}

# --- gate order and clean no-ops ---------------------------------------------

boot_kill_switch_skips_without_herdr() {
  local h out
  h=$(make_home kill)
  prepare_restorable_home "$h"
  : > "$TMP_ROOT/herdr.log"
  : > "$h/config/boot-resume-off"
  out=$(run_boot "$h" 2>&1)
  [ "$(herdr_calls)" -eq 0 ] || fail "kill switch still reached herdr: $out"
  grep -q 'kill switch config/boot-resume-off' "$h/state/boot-resume.log" \
    || fail "no typed kill-switch line in log: $(cat "$h/state/boot-resume.log")"
  pass "boot kill switch is a clean typed no-op"
}

boot_attended_posture_skips() {
  local h
  h=$(make_home attended)
  prepare_restorable_home "$h"
  : > "$TMP_ROOT/herdr.log"
  run_boot "$h" >/dev/null 2>&1 || fail "attended skip must exit 0"
  [ "$(herdr_calls)" -eq 0 ] || fail "attended home still reached herdr"
  grep -q 'captain present' "$h/state/boot-resume.log" || fail "no posture skip line"
  pass "attended posture (no away record, no active goal) skips"
}

boot_idempotence_marker_skips_second_run() {
  local h
  h=$(make_home idem)
  prepare_restorable_home "$h"
  : > "$TMP_ROOT/herdr.log"
  FM_SHIM_GOAL=1 run_boot "$h" >/dev/null 2>&1 || fail "first resume run failed"
  FM_SHIM_GOAL=1 run_boot "$h" >/dev/null 2>&1 || fail "second resume run failed"
  [ "$(grep -c 'start firstmate' "$TMP_ROOT/herdr.log")" -eq 1 ] \
    || fail "second boot resumed again: $(cat "$TMP_ROOT/herdr.log")"
  grep -q 'already resumed this boot' "$h/state/boot-resume.log" || fail "no idempotence line"
  pass "per-boot marker makes the second run a no-op"
}

# --- the guarded primary restore ---------------------------------------------

boot_restores_primary_in_recorded_pane() {
  local h line
  h=$(make_home happy)
  prepare_restorable_home "$h"
  printf -- '--model sonnet\n# a comment line\n--effort high\n' > "$h/config/boot-resume-primary-args"
  : > "$TMP_ROOT/herdr.log"
  : > "$TMP_ROOT/inbox.log"
  FM_SHIM_GOAL=1 run_boot "$h" >/dev/null 2>&1 || fail "restore run failed: $(cat "$h/state/boot-resume.log")"
  line=$(grep 'start firstmate' "$TMP_ROOT/herdr.log")
  case "$line" in
    *"s1"*) ;;
    *) fail "agent start not aimed at session s1: $line" ;;
  esac
  case "$line" in
    *"--pane w1:p2"*) ;;
    *) fail "agent start not aimed at the recorded pane w1:p2: $line" ;;
  esac
  case "$line" in
    *"--dangerously-skip-permissions --model sonnet --effort high --resume $SID"*) ;;
    *) fail "restore argv wrong: $line" ;;
  esac
  grep -q "agent prompt w1:p2.*stuck-crewmate-recovery" "$TMP_ROOT/herdr.log" \
    || fail "no recovery prompt submitted: $(cat "$TMP_ROOT/herdr.log")"
  [ "$(awk -F'\t' '$2 == "primary" { n++ } END { print n + 0 }' "$h/state/.boot-resume-attempts" 2>/dev/null)" -ge 1 ] \
    || fail "no attempt ledger row"
  [ ! -s "$TMP_ROOT/inbox.log" ] || fail "healthy restore still left an inbox note: $(cat "$TMP_ROOT/inbox.log")"
  grep -q 'restore: started primary session' "$h/state/boot-resume.log" || fail "no started line"
  pass "restore starts the recorded conversation in the recorded pane"
}

boot_restore_args_default_without_config() {
  local h line
  h=$(make_home noargs)
  prepare_restorable_home "$h"
  : > "$TMP_ROOT/herdr.log"
  FM_SHIM_GOAL=1 run_boot "$h" >/dev/null 2>&1 || fail "restore run failed"
  line=$(grep 'start firstmate' "$TMP_ROOT/herdr.log")
  case "$line" in
    *"--dangerously-skip-permissions --resume $SID"*) ;;
    *) fail "default argv wrong: $line" ;;
  esac
  pass "restore argv defaults without config/boot-resume-primary-args"
}

boot_fails_typed_without_recorded_session() {
  local h
  h=$(make_home nosession)
  prepare_restorable_home "$h"
  rm "$h/state/.lock-session"
  : > "$TMP_ROOT/herdr.log"
  : > "$TMP_ROOT/inbox.log"
  FM_SHIM_GOAL=1 run_boot "$h" >/dev/null 2>&1
  grep -q 'no recorded primary session id' "$h/state/boot-resume.log" \
    || fail "no typed refusal: $(cat "$h/state/boot-resume.log")"
  grep -q 'boot-resume-test-boot-id' "$TMP_ROOT/inbox.log" \
    || fail "failed restore left no durable inbox note: $(cat "$TMP_ROOT/inbox.log")"
  pass "missing recorded session id is a typed refusal with one durable note"
}

boot_refuses_ambiguous_pane_match() {
  local h
  h=$(make_home ambiguous)
  prepare_restorable_home "$h"
  printf '%s\n' "{\"id\":\"cli:agent:list\",\"result\":{\"agents\":[$(agent_row w1:p2 "$SID" "$h" claude),$(agent_row w3:p7 "$SID" "$h" claude)]}}" > "$TMP_ROOT/agents.json"
  : > "$TMP_ROOT/herdr.log"
  FM_SHIM_GOAL=1 run_boot "$h" >/dev/null 2>&1
  grep -q 'matches more than one pane' "$h/state/boot-resume.log" \
    || fail "no ambiguity refusal: $(cat "$h/state/boot-resume.log")"
  [ "$(start_calls)" -eq 0 ] \
    || fail "ambiguous match still started an agent"
  pass "an ambiguous session-id match is refused, never guessed"
}

boot_budget_parks_after_max_attempts() {
  local h i
  h=$(make_home budget)
  prepare_restorable_home "$h"
  : > "$TMP_ROOT/herdr.log"
  : > "$TMP_ROOT/inbox.log"
  for i in 1 2; do
    printf '%s\tprimary\tfail\n' "$(( $(date +%s) - 60 ))" >> "$h/state/.boot-resume-attempts"
  done
  FM_SHIM_GOAL=1 run_boot "$h" >/dev/null 2>&1 || fail "parked run must still exit cleanly"
  [ "$(herdr_calls)" -eq 0 ] || fail "out-of-budget run still reached herdr"
  [ -e "$h/state/.boot-resume-parked-primary" ] || fail "no park marker"
  grep -q 'boot-resume-parked-primary-test-boot-id' "$TMP_ROOT/inbox.log" \
    || fail "no parked inbox note: $(cat "$TMP_ROOT/inbox.log")"
  pass "attempt budget parks with the marker and a durable note"
}

boot_herdr_readiness_waits_for_server() {
  local h
  h=$(make_home readiness)
  prepare_restorable_home "$h"
  : > "$TMP_ROOT/herdr.log"
  touch "$TMP_ROOT/down"
  (cd "$TMP_ROOT" && sleep 3 && rm -f "$TMP_ROOT/down") >/dev/null 2>&1 &
  FM_SHIM_GOAL=1 FM_BOOT_RESUME_HERDR_WAIT_SECS=30 FM_FAKE_HERDR_DOWN="$TMP_ROOT/down" \
    run_boot "$h" >/dev/null 2>&1 || fail "restore failed while waiting for herdr"
  grep -q 'start firstmate' "$TMP_ROOT/herdr.log" || fail "no agent start after readiness"
  pass "bounded herdr readiness wait covers a slow server start"
}

real_away_contract_gates_the_boot() {
  local h
  h=$(make_home awayreal)
  prepare_restorable_home "$h"
  : > "$TMP_ROOT/herdr.log"
  FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" "$CONTRACT" enter \
    --words "away for the evening; keep the fleet supervised" >/dev/null 2>&1 \
    || fail "away record fixture could not be written"
  run_boot "$h" >/dev/null 2>&1 || fail "away-posture restore failed: $(cat "$h/state/boot-resume.log")"
  grep -q 'start firstmate' "$TMP_ROOT/herdr.log" || fail "away record did not authorize restore"
  pass "a real standing away record authorizes the boot resume"
}

goal_posture_gates_without_away() {
  local h
  h=$(make_home goalonly)
  prepare_restorable_home "$h"
  : > "$TMP_ROOT/herdr.log"
  FM_SHIM_GOAL=1 run_boot "$h" >/dev/null 2>&1 || fail "goal-posture restore failed"
  grep -q 'start firstmate' "$TMP_ROOT/herdr.log" || fail "active goal did not authorize restore"
  pass "an active goal alone authorizes the boot resume"
}

# --- the secondmate fallback --------------------------------------------------

secondmate_fallback_runs_only_when_primary_failed() {
  local h
  h=$(make_home smfallback)
  prepare_restorable_home "$h"
  printf 'kind=secondmate\n' > "$h/state/terp.meta"
  printf 'kind=secondmate\n' > "$h/state/miko.meta"
  : > "$TMP_ROOT/herdr.log"
  : > "$TMP_ROOT/sm-relaunch.log"
  # Primary restorable: the fallback must not fire even for a relaunchable mate.
  FM_SHIM_SM_PROBE='FM_SM_LIVE_STATUS=relaunchable; FM_SM_LIVE_STATE=dead; FM_SM_LIVE_CAUSE=shim; FM_SM_LIVE_WHERE=shim; return 0' \
  FM_SHIM_SM_RELAUNCH_LOG="$TMP_ROOT/sm-relaunch.log" \
    FM_SHIM_GOAL=1 run_boot "$h" >/dev/null 2>&1 || fail "restore run failed"
  n=$(grep -c . "$TMP_ROOT/sm-relaunch.log" 2>/dev/null) || n=0
  [ "$n" -eq 0 ] \
    || fail "fallback fired although the primary restored: $(cat "$TMP_ROOT/sm-relaunch.log")"
  # Primary unrestorable: relaunchable relaunches, alive stays untouched.
  printf '%s\n' '{"id":"cli:agent:list","result":{"agents":[]}}' > "$TMP_ROOT/agents.json"
  rm -f "$h/state/.boot-resume-boot"
  : > "$TMP_ROOT/herdr.log"
  # shellcheck disable=SC2016 # Deliberately quoted: the shim evals $2 at probe time.
  FM_SHIM_SM_PROBE='case "$2" in terp) FM_SM_LIVE_STATUS=relaunchable; FM_SM_LIVE_STATE=dead;; miko) FM_SM_LIVE_STATUS=alive; FM_SM_LIVE_STATE=alive;; esac; FM_SM_LIVE_CAUSE=shim; FM_SM_LIVE_WHERE=shim; return 0' \
  FM_SHIM_SM_RELAUNCH_LOG="$TMP_ROOT/sm-relaunch.log" \
    FM_SHIM_GOAL=1 run_boot "$h" >/dev/null 2>&1
  [ "$(grep -c . "$TMP_ROOT/sm-relaunch.log")" -eq 1 ] || fail "fallback ran wrong count: $(cat "$TMP_ROOT/sm-relaunch.log")"
  grep -q 'terp' "$TMP_ROOT/sm-relaunch.log" || fail "relaunchable mate not relaunched"
  ! grep -q 'miko' "$TMP_ROOT/sm-relaunch.log" || fail "alive mate was relaunched"
  grep -q 'secondmate terp relaunched' "$h/state/boot-resume.log" || fail "no typed fallback line"
  pass "secondmate fallback fires only on failed restore and honors probe verdicts"
}

# --- the watchdog -------------------------------------------------------------

watchdog_healthy_tick_is_silent() {
  local h pid
  h=$(make_home wdhealthy)
  prepare_restorable_home "$h"
  start_sleeper
  pid=$(spawned_pid)
  make_watcher_lock "$h" "$pid" 0
  : > "$TMP_ROOT/herdr.log"
  FM_SHIM_GOAL=1 run_watchdog "$h" >/dev/null 2>&1 || fail "healthy tick must exit 0"
  [ "$(herdr_calls)" -eq 0 ] || fail "healthy tick still reached herdr: $(cat "$TMP_ROOT/herdr.log")"
  [ ! -e "$h/state/boot-resume.log" ] || fail "healthy tick wrote a log action"
  kill "$pid" 2>/dev/null || true
  pass "healthy watcher tick is silent and touches nothing"
}

watchdog_stale_with_live_primary_nudges() {
  local h wpid hpid
  h=$(make_home wdnudge)
  prepare_restorable_home "$h"
  start_fake_harness
  hpid=$(spawned_pid)
  printf '%s\n' "$hpid" > "$h/state/.lock"
  start_sleeper
  wpid=$(spawned_pid)
  make_watcher_lock "$h" "$wpid" 900
  : > "$TMP_ROOT/herdr.log"
  : > "$TMP_ROOT/inbox.log"
  FM_SHIM_GOAL=1 run_watchdog "$h" >/dev/null 2>&1 || fail "nudge tick must exit 0"
  grep -q "agent prompt w1:p2.*watcher-continuity" "$TMP_ROOT/herdr.log" \
    || fail "no nudge prompt: $(cat "$TMP_ROOT/herdr.log")"
  [ "$(start_calls)" -eq 0 ] \
    || fail "nudge path started an agent"
  grep -q 'nudged primary' "$h/state/boot-resume.log" || fail "no typed nudge line"
  [ -s "$TMP_ROOT/inbox.log" ] || fail "no durable watchdog note"
  kill "$hpid" "$wpid" 2>/dev/null || true
  pass "stale watcher with a live primary nudges the primary, not a shell arm"
}

watchdog_stale_without_primary_restores() {
  local h pid
  h=$(make_home wdrestore)
  prepare_restorable_home "$h"
  start_sleeper
  pid=$(spawned_pid)
  make_watcher_lock "$h" "$pid" 900
  : > "$TMP_ROOT/herdr.log"
  FM_SHIM_GOAL=1 run_watchdog "$h" >/dev/null 2>&1 || fail "restore tick must exit 0"
  grep -q 'start firstmate' "$TMP_ROOT/herdr.log" || fail "watchdog did not restore the primary"
  kill "$pid" 2>/dev/null || true
  pass "stale watcher with no live primary runs the guarded restore"
}

watchdog_respects_kill_switch() {
  local h
  h=$(make_home wdkill)
  prepare_restorable_home "$h"
  : > "$h/config/boot-resume-off"
  : > "$TMP_ROOT/herdr.log"
  FM_SHIM_GOAL=1 run_watchdog "$h" >/dev/null 2>&1 || fail "kill-switch tick must exit 0"
  [ "$(herdr_calls)" -eq 0 ] || fail "kill switch still reached herdr"
  pass "watchdog honors the kill switch"
}

check_modes_print_verdicts_and_change_nothing() {
  local h out
  h=$(make_home checkmode)
  prepare_restorable_home "$h"
  : > "$TMP_ROOT/herdr.log"
  out=$(run_boot "$h" --check 2>&1)
  case "$out" in
    *'primary pane: s1:w1:p2'*) ;;
    *) fail "--check did not resolve the primary pane: $out" ;;
  esac
  [ "$(start_calls)" -eq 0 ] || fail "--check must not start or prompt anything: $(cat "$TMP_ROOT/herdr.log")"
  [ ! -e "$h/state/boot-resume.log" ] || fail "--check wrote a log line"
  [ ! -e "$h/state/.boot-resume-boot" ] || fail "--check consumed the boot marker"
  out=$(run_watchdog "$h" --check 2>&1)
  case "$out" in
    *'watcher: NOT healthy'*) ;;
    *) fail "watchdog --check wrong verdict: $out" ;;
  esac
  pass "--check modes are read-only verdicts"
}

# --- the installer -------------------------------------------------------------

installer_print_renders_baked_units() {
  local out
  out=$(PATH="$FAKEBIN:$PATH" "$INSTALL" --home "$ROOT" --print 2>&1)
  case "$out" in
    *"# firstmate-boot-resume.service"*"# firstmate-watchdog-beat.service"*"# firstmate-watchdog-beat.timer"*) ;;
    *) fail "missing unit headers: $out" ;;
  esac
  case "$out" in
    *"ExecStart=$ROOT/bin/fm-boot-resume.sh"*"Environment=FM_HOME=$ROOT"*) ;;
    *) fail "home not baked: $out" ;;
  esac
  case "$out" in
    *"After=herdr-bucket@personal.service"*) ;;
    *) fail "herdr soft ordering missing: $out" ;;
  esac
  case "$out" in
    *"OnUnitActiveSec=5min"*"Persistent=true"*) ;;
    *) fail "timer cadence missing: $out" ;;
  esac
  pass "installer --print renders the three baked units"
}

installer_writes_units_without_enable() {
  local units="$TMP_ROOT/units"
  : > "$TMP_ROOT/systemctl.log"
  PATH="$FAKEBIN:$PATH" "$INSTALL" --home "$ROOT" --units-dir "$units" >/dev/null 2>&1 \
    || fail "install run failed"
  [ -f "$units/firstmate-boot-resume.service" ] || fail "boot unit missing"
  [ -f "$units/firstmate-watchdog-beat.service" ] || fail "watchdog service missing"
  [ -f "$units/firstmate-watchdog-beat.timer" ] || fail "timer missing"
  [ ! -s "$TMP_ROOT/systemctl.log" ] || fail "no-enable still called systemctl"
  pass "default install writes units and enables nothing"
}

installer_enable_invokes_systemctl() {
  local units="$TMP_ROOT/units2"
  : > "$TMP_ROOT/systemctl.log"
  PATH="$FAKEBIN:$PATH" FM_FAKE_SYSTEMCTL_LOG="$TMP_ROOT/systemctl.log" \
    "$INSTALL" --home "$ROOT" --units-dir "$units" --enable >/dev/null 2>&1 \
    || fail "enable run failed"
  grep -q -- '--user daemon-reload' "$TMP_ROOT/systemctl.log" || fail "no daemon-reload"
  grep -q -- 'enable firstmate-boot-resume.service' "$TMP_ROOT/systemctl.log" || fail "boot unit not enabled"
  grep -q -- 'enable --now firstmate-watchdog-beat.timer' "$TMP_ROOT/systemctl.log" || fail "timer not enabled"
  pass "--enable runs daemon-reload and enables unit plus timer"
}

fm_test_run \
  boot_kill_switch_skips_without_herdr \
  boot_attended_posture_skips \
  boot_idempotence_marker_skips_second_run \
  boot_restores_primary_in_recorded_pane \
  boot_restore_args_default_without_config \
  boot_fails_typed_without_recorded_session \
  boot_refuses_ambiguous_pane_match \
  boot_budget_parks_after_max_attempts \
  boot_herdr_readiness_waits_for_server \
  real_away_contract_gates_the_boot \
  goal_posture_gates_without_away \
  secondmate_fallback_runs_only_when_primary_failed \
  watchdog_healthy_tick_is_silent \
  watchdog_stale_with_live_primary_nudges \
  watchdog_stale_without_primary_restores \
  watchdog_respects_kill_switch \
  check_modes_print_verdicts_and_change_nothing \
  installer_print_renders_baked_units \
  installer_writes_units_without_enable \
  installer_enable_invokes_systemctl
