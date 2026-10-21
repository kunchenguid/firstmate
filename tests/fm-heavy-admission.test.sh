#!/usr/bin/env bash
# Behavioral coverage for bin/fm-heavy-admission.sh over synthetic host
# readings: policy-off admission, admit, every hold trigger and below-admit
# condition, unreadable readings failing closed, the sampled window, the shared
# serial ramp, dry-run, wait, root-home config inheritance, and usage errors.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-heavy-admission) || fail "temp root"
ADMIT="$ROOT/bin/fm-heavy-admission.sh"

FAKEBIN=$(fm_fakebin "$TMP_ROOT") || fail "fakebin"
# df prints the available KiB from $FAKE_DF_KB, or fails when it is "fail".
cat > "$FAKEBIN/df" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_DF_KB:-}" != fail ] || exit 1
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on'
printf '/dev/fake 999999999 1 %s 1%% /\n' "${FAKE_DF_KB:-104857600}"
SH
# journalctl prints $FAKE_JOURNAL_KERNEL for -k and $FAKE_JOURNAL_UNIT for -u,
# appends $FAKE_JOURNAL_STDERR to stderr, and exits $FAKE_JOURNAL_RC.
cat > "$FAKEBIN/journalctl" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -k "*) [ -z "${FAKE_JOURNAL_KERNEL:-}" ] || printf '%s\n' "$FAKE_JOURNAL_KERNEL" ;;
  *" -u "*) [ -z "${FAKE_JOURNAL_UNIT:-}" ] || printf '%s\n' "$FAKE_JOURNAL_UNIT" ;;
esac
[ -z "${FAKE_JOURNAL_STDERR:-}" ] || printf '%s\n' "$FAKE_JOURNAL_STDERR" >&2
exit "${FAKE_JOURNAL_RC:-0}"
SH
# sleep never sleeps: it logs its argument and runs $FAKE_SLEEP_HOOK so a test
# can change the host between samples or age the ramp record.
cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
[ -z "${FAKE_SLEEP_LOG:-}" ] || printf '%s\n' "$1" >> "$FAKE_SLEEP_LOG"
[ -z "${FAKE_SLEEP_HOOK:-}" ] || sh -c "$FAKE_SLEEP_HOOK"
exit 0
SH
chmod +x "${FAKEBIN:?}"/df "$FAKEBIN"/journalctl "$FAKEBIN"/sleep

N=0
# new_world [config-lines...]: a fresh home and /proc with healthy readings.
# With no arguments the home gets the default policy file; pass "none" for no
# config at all. Sets HOME_DIR and PROC.
new_world() {
  N=$((N + 1))
  HOME_DIR="$TMP_ROOT/w$N/home"
  PROC="$TMP_ROOT/w$N/proc"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$PROC/pressure"
  set_load 3.00 4.00
  set_mem_gib 40
  set_psi memory some 0.00
  set_psi io full 0.50
  if [ "${1:-}" != none ]; then
    PATH="$BASE_PATH" "$ADMIT" defaults > "$HOME_DIR/config/heavy-admission"
    printf '%s\n' window_secs=0 "$@" >> "$HOME_DIR/config/heavy-admission"
  fi
}

set_load() { printf '%s %s 1.00 1/100 123\n' "$1" "$2" > "$PROC/loadavg"; }
set_mem_gib() {
  printf 'MemTotal:       99999999 kB\nMemAvailable:   %s kB\n' \
    "$(awk -v g="$1" 'BEGIN { printf "%.0f", g * 1048576 }')" > "$PROC/meminfo"
}
set_psi() {  # <memory|io> <some|full> <avg60>
  local other=full
  [ "$2" = full ] && other=some
  printf '%s avg10=0.00 avg60=%s avg300=0.00 total=1\n%s avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' \
    "$2" "$3" "$other" > "$PROC/pressure/$1"
}

run_admit() {
  OUT=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_PROC_ROOT_OVERRIDE="$PROC" "$ADMIT" "$@" 2>"$TMP_ROOT/stderr")
  RC=$?
  ERR=$(cat "$TMP_ROOT/stderr")
}

expect_hold() {  # <reason-fragment> <label> [args...]
  local fragment=$1 label=$2
  shift 2
  run_admit check "$@"
  expect_code 1 "$RC" "$label: exit"
  assert_contains "$OUT" "decision=hold" "$label: decision"
  assert_contains "$OUT" "$fragment" "$label: reason"
}

# --- policy off ----------------------------------------------------------------
new_world none
rm -f "$PROC/loadavg"
run_admit check
expect_code 0 "$RC" "policy off admits"
assert_contains "$OUT" "decision=admit reason=policy-off policy=off config=none" "policy off evidence"
assert_absent "$HOME_DIR/state/heavy-admission.last" "policy off records no admission"
pass "absent config leaves the policy off and admits without readings"

# --- admit, ramp, evidence ----------------------------------------------------
new_world
run_admit check
expect_code 0 "$RC" "healthy host admits"
assert_contains "$OUT" "decision=admit reason=ok policy=on" "admit evidence"
assert_contains "$OUT" "samples=1 load1=3.00 load5=4.00 mem_available_gib=40.0 mem_psi_some_avg60=0.00 io_psi_full_avg60=0.50 disk_free_gib=100.0 warnings=0" "admit readings"
assert_contains "$OUT" "jest_max_workers=2 playwright_workers=1" "admit carries validator parallelism bounds"
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] || fail "one evidence line per decision"
assert_present "$HOME_DIR/state/heavy-admission.last" "admit records the ramp"
assert_grep "decision=admit reason=ok" "$HOME_DIR/state/heavy-admission.log" "admit evidence is logged"
expect_hold "reason=ramp:remaining=" "second admission inside the ramp holds"
assert_contains "$OUT" "samples=0" "ramp hold takes no readings"
pass "a healthy host admits once, records the ramp, and holds the next admission"

new_world ramp_secs=0
run_admit check
expect_code 0 "$RC" "first admission with no ramp"
run_admit check
expect_code 0 "$RC" "ramp_secs=0 admits back to back"
pass "ramp_secs=0 disables the serial ramp"

new_world
run_admit check --dry-run
expect_code 0 "$RC" "dry-run admits"
assert_contains "$OUT" "dry_run=1" "dry-run evidence"
assert_absent "$HOME_DIR/state/heavy-admission.last" "dry-run records no admission"
run_admit check
expect_code 0 "$RC" "dry-run consumed no ramp slot"
pass "dry-run prints the decision without recording an admission"

# --- holds ----------------------------------------------------------------------
new_world; set_load 21.50 10.00
expect_hold "reason=trip:load1=21.50>=20" "load1 at the hold trigger"
new_world; set_load 17.00 10.00
expect_hold "reason=below-admit:load1=17.00>=16" "load1 between admit and hold"
new_world; set_load 5.00 20.00
expect_hold "reason=below-admit:load5=20.00>=20" "load5 at the admit limit"
new_world; set_mem_gib 11
expect_hold "reason=trip:mem_available_gib=11.0<=12" "MemAvailable at the hold trigger"
new_world; set_mem_gib 14
expect_hold "reason=below-admit:mem_available_gib=14.0<=16" "MemAvailable below the admit floor"
new_world; set_mem_gib 20
expect_hold "reason=below-admit:mem_available_gib=20.0<=peak+reserve=22.0" "MemAvailable short of peak plus reserve" --peak-gib 14
assert_contains "$OUT" "peak_gib=14" "peak evidence"
new_world; set_mem_gib 30
run_admit check --peak-gib 14
expect_code 0 "$RC" "MemAvailable covering peak plus reserve admits"
new_world; set_psi memory some 1.00
expect_hold "reason=below-admit:mem_psi_some_avg60=1.00>=1" "memory pressure"
new_world; set_psi io full 12.00
expect_hold "reason=trip:io_psi_full_avg60=12.00>=10" "I/O pressure at the hold trigger"
new_world; set_psi io full 6.00
expect_hold "reason=below-admit:io_psi_full_avg60=6.00>=5" "I/O pressure between admit and hold"
new_world
FAKE_DF_KB=10485760 expect_hold "reason=below-admit:disk_free_gib=10.0<=20" "low root free space"
new_world
FAKE_JOURNAL_KERNEL='INFO: task btrfs:123 blocked for more than 122 seconds.' \
  expect_hold "reason=trip:warnings=1" "hung-task report"
new_world
FAKE_JOURNAL_UNIT='systemd-journald.service: Watchdog timeout (limit 3min)!' \
  expect_hold "reason=trip:warnings=1" "journald watchdog timeout"
new_world; set_load 25.00 22.00; set_psi io full 30.00
expect_hold "reason=trip:load1=25.00>=20,below-admit:load5=22.00>=20" "several conditions"
assert_contains "$OUT" "trip:io_psi_full_avg60=30.00>=10" "every failing condition is named"
pass "every hold trigger and admit condition holds with a named reason"

# --- fail closed ----------------------------------------------------------------
new_world; rm -f "$PROC/loadavg"
expect_hold "reason=unreadable:loadavg" "missing loadavg"
assert_contains "$OUT" "load1=unknown" "unreadable reading is unknown"
new_world; rm -f "$PROC/meminfo"
expect_hold "reason=unreadable:meminfo" "missing meminfo"
new_world; rm -f "$PROC/pressure/memory"
expect_hold "reason=unreadable:memory_pressure" "missing memory PSI"
new_world; rm -f "$PROC/pressure/io"
expect_hold "reason=unreadable:io_pressure" "missing I/O PSI"
new_world
FAKE_DF_KB=fail expect_hold "reason=unreadable:disk" "failing df"
new_world
FAKE_JOURNAL_RC=1 expect_hold "reason=unreadable:journal" "failing journal query"
new_world
FAKE_JOURNAL_STDERR='Hint: You are currently not seeing messages from other users and the system.' \
  expect_hold "reason=unreadable:journal" "journal without system messages"
new_world
NO_JOURNAL_PATH=$(fm_test_base_path_sans "$BASE_PATH" journalctl) || fail "path without journalctl"
mkdir -p "$TMP_ROOT/no-journal-bin"
cp "$FAKEBIN/df" "$FAKEBIN/sleep" "$TMP_ROOT/no-journal-bin/"
OUT=$(PATH="$TMP_ROOT/no-journal-bin:$NO_JOURNAL_PATH" FM_HOME="$HOME_DIR" FM_PROC_ROOT_OVERRIDE="$PROC" "$ADMIT" check 2>/dev/null)
RC=$?
expect_code 1 "$RC" "absent journalctl holds"
assert_contains "$OUT" "unreadable:journal" "absent journalctl names the journal"
new_world bogus_key=1
expect_hold "reason=config-invalid:unknown-key-line" "unknown config key"
new_world admit_load1_below=lots
expect_hold "reason=config-invalid:admit_load1_below" "malformed config value"
pass "unreadable readings and malformed config hold and say which"

# --- sampled window ---------------------------------------------------------------
new_world window_secs=1 sample_interval_secs=1
FAKE_SLEEP_HOOK="printf '%s\n' '18.00 4.00 1.00 1/100 123' > '$PROC/loadavg'" \
  expect_hold "reason=below-admit:load1=18.00>=16" "load rising inside the window"
assert_contains "$OUT" "samples=2" "the window sampled again before deciding"
assert_absent "$HOME_DIR/state/heavy-admission.last" "a hold inside the window records nothing"
new_world window_secs=1 sample_interval_secs=1
run_admit check
expect_code 0 "$RC" "a steady window admits"
assert_contains "$OUT" "samples=2" "a steady window takes every sample"
new_world window_secs=60
WINDOW_SLEEPS="$TMP_ROOT/window-sleeps.log"
: > "$WINDOW_SLEEPS"
FAKE_SLEEP_LOG="$WINDOW_SLEEPS" run_admit check
expect_code 0 "$RC" "the default window admits a steady host"
assert_contains "$OUT" "samples=7" "the default window samples seven times"
[ "$(tr '\n' ' ' < "$WINDOW_SLEEPS")" = "10 10 10 10 10 10 " ] || fail "the default window waits ten seconds between samples"
pass "admission requires the conditions in every sample across the window"

# --- wait -----------------------------------------------------------------------------
new_world
run_admit check
expect_code 0 "$RC" "prime the ramp"
SLEEP_LOG="$TMP_ROOT/sleep.log"
: > "$SLEEP_LOG"
FAKE_SLEEP_LOG="$SLEEP_LOG" FAKE_SLEEP_HOOK="touch -t 200001010000 '$HOME_DIR/state/heavy-admission.last'" \
  run_admit wait --timeout 300
expect_code 0 "$RC" "wait admits once the ramp passes"
assert_contains "$OUT" "decision=hold reason=ramp:remaining=" "wait reports the hold"
assert_contains "$OUT" "decision=admit reason=ok" "wait reports the admit"
[ "$(wc -l < "$SLEEP_LOG" | tr -d ' ')" = 1 ] || fail "wait sleeps once for the ramp"
awk '$1 > 0 && $1 <= 120 { ok = 1 } END { exit !ok }' "$SLEEP_LOG" || fail "wait sleeps for the remaining ramp"
new_world; set_load 30.00 30.00
FAKE_SLEEP_LOG="$SLEEP_LOG" run_admit wait --timeout 0
expect_code 1 "$RC" "wait times out holding"
assert_contains "$OUT" "reason=trip:load1=30.00>=20" "wait timeout evidence"
assert_contains "$ERR" "still holding after 0s" "wait timeout note"
pass "wait retries until admission or its timeout"

# --- root home config ---------------------------------------------------------------
new_world
ROOT_HOME_DIR=$HOME_DIR
new_world none
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$ROOT_HOME_DIR" > "$HOME_DIR/.fm-secondmate-parent"
run_admit check
expect_code 0 "$RC" "secondmate home admits under the root policy"
assert_contains "$OUT" "policy=on config=$ROOT_HOME_DIR/config/heavy-admission" "root policy applies"
assert_present "$ROOT_HOME_DIR/state/heavy-admission.last" "the ramp is shared through the root home"
assert_absent "$HOME_DIR/state/heavy-admission.last" "no home-local ramp"
expect_hold "reason=ramp:remaining=" "the root ramp holds the next admission"
printf '%s\n' ramp_secs=0 window_secs=0 > "$HOME_DIR/config/heavy-admission"
run_admit check
expect_code 0 "$RC" "a home override replaces the root policy"
assert_contains "$OUT" "config=$HOME_DIR/config/heavy-admission" "home override evidence"
pass "the root home sets the machine policy and the ramp, and a home can override the policy"

# --- usage ------------------------------------------------------------------------------
new_world
run_admit
expect_code 2 "$RC" "no command"
run_admit check --peak-gib nope
expect_code 2 "$RC" "bad peak"
run_admit check --timeout 5
expect_code 2 "$RC" "timeout on check"
run_admit frobnicate
expect_code 2 "$RC" "unknown command"
run_admit --help
expect_code 0 "$RC" "help"
assert_contains "$OUT" "single owner" "help prints the header"
pass "usage errors exit 2"
