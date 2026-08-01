#!/usr/bin/env bash
# Executable-interface tests for guarded Pi-on-Herdr primary custody and recovery.
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T_RAW=$(mktemp -d "${TMPDIR:-/tmp}/fm-primary-pi.XXXXXX")
T="${T_RAW}-captain's-recovery"
mv "$T_RAW" "$T"
T=$(cd "$T" && pwd -P)
HOME_FIXTURE="$T/home"
FAKEBIN=$(fm_fakebin "$T")
MODE="$T/mode"
LOG="$T/herdr.log"
SESSION_DIR="$T/sessions"
SESSION_FILE="$SESSION_DIR/target.jsonl"
SOCKET="$T/herdr.sock"
FULL_ID='full-session-1234567890'
WORKSPACE='w1'
TAB='w1:t1'
PANE='w1:p1'
mkdir -p "$HOME_FIXTURE/state" "$SESSION_DIR"
printf 'none\n' > "$MODE"
: > "$LOG"
: > "$SOCKET"

# Portable octal mode. Platform-detected, never the `stat -f || stat -c` fallback:
# GNU `stat -f` is --file-system, so it reads '%Lp' as a missing file and still
# writes a filesystem dump for the real path, which the fallback mode then trails.
file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

write_session() {
  cat > "$SESSION_FILE" <<EOF
{"type":"session","version":3,"id":"$FULL_ID","timestamp":"2026-01-01T00:00:00.000Z","cwd":"$T"}
{"type":"message","id":"m1","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"persist me","timestamp":1}}
EOF
}
write_session

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$TEST_HERDR_LOG"
case "$1 ${2:-}" in
  'status --json')
    if [ "$(cat "$TEST_MODE_FILE")" = server-down ]; then
      printf '{"server":{"running":false,"session":"%s","socket":"%s"},"focused_workspace_id":"decoy-workspace"}\n' "$TEST_SESSION" "$TEST_SOCKET"
    else
      printf '{"server":{"running":true,"session":"%s","socket":"%s"},"focused_workspace_id":"decoy-workspace"}\n' "$TEST_SESSION" "$TEST_SOCKET"
    fi
    ;;
  'server --session')
    printf 'shell\n' > "$TEST_MODE_FILE"
    ;;
  'pane get')
    printf '{"result":{"pane":{"pane_id":"%s","workspace_id":"%s","tab_id":"%s","label":"misleading-primary-label","focused":false}}}\n' "$TEST_PANE" "$TEST_WORKSPACE" "$TEST_TAB"
    ;;
  'agent get')
    case "$(cat "$TEST_MODE_FILE")" in
      pi) printf '{"result":{"agent":{"agent":"pi"}}}\n' ;;
      none|shell|contradictory) printf '{"error":{"code":"agent_not_found"}}\n'; exit 1 ;;
      *) printf '{"error":{"code":"transport_unknown"}}\n'; exit 1 ;;
    esac
    ;;
  'pane process-info')
    if [ "$(cat "$TEST_MODE_FILE")" = pi ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":10,"foreground_process_group_id":20,"foreground_processes":[{"pid":20,"argv0":"pi","name":"pi"}]}}}\n' "$TEST_PANE"
    elif [ "$(cat "$TEST_MODE_FILE")" = contradictory ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":10,"foreground_process_group_id":30,"foreground_processes":[{"pid":30,"argv0":"node","name":"node"}]}}}\n' "$TEST_PANE"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":10,"foreground_process_group_id":10,"foreground_processes":[{"pid":10,"argv0":"-zsh","name":"zsh"}]}}}\n' "$TEST_PANE"
    fi
    ;;
  'agent attach')
    printf '%s\n' "${HERDR_SESSION-unset}" > "$TEST_ATTACH_ENV_FILE"
    ;;
  'pane run')
    sleep "${TEST_PANE_RUN_DELAY:-0}"
    # The restored pane runs its own shell, not the recovering operator's. Give
    # it a stray FM_STATE_OVERRIDE the parent never uses, so any generated
    # command that fails to pin that variable resolves a private state tree the
    # parent never polls and cannot attest.
    (cd / && env FM_STATE_OVERRIDE="$TEST_STRAY_STATE" bash -c "$4") >> "$TEST_RESUME_LOG" 2>&1 &
    ;;
  *) printf '{"error":{"code":"unexpected"}}\n'; exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

cat > "$FAKEBIN/pi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$TEST_PI_LOG"
umask > "$TEST_UMASK_FILE"
pwd -P > "$TEST_PI_CWD_FILE"
trap 'printf "shell\n" > "$TEST_MODE_FILE"; exit 0' TERM INT HUP
actual_id=${TEST_ATTEST_ID:-$TEST_FULL_ID}
pi_start=$(ps -o lstart= -p $$ | awk '{$1=$1; print}')
"$FM_ROOT_OVERRIDE/bin/fm-primary-pi.sh" attest \
  --token "$FM_PRIMARY_PI_TOKEN" \
  --actual-id "$actual_id" \
  --session-file "$TEST_SESSION_FILE" \
  --session-dir "$TEST_SESSION_DIR" \
  --cwd "$TEST_CWD" \
  --pi-pid $$ \
  --pi-start "$pi_start" \
  --reason startup \
  $( [ "$FM_PRIMARY_PI_RECOVERY" = 1 ] && printf '%s' --recovery ) || exit 1
printf 'pi\n' > "$TEST_MODE_FILE"
while :; do sleep 1; done
SH
chmod +x "$FAKEBIN/pi"

# Recovery delegates its bare-shell decision to bin/backends/herdr.sh's single
# authoritative idle-shell proof, which cross-checks the reported shell against
# the real process table. Give that owner a fake table matching the fake pane so
# the suite exercises the delegation rather than this machine's pid 10.
FAKE_PS="$T/fake-ps"
cat > "$FAKE_PS" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-axo pid=,ppid=") printf '1 0\n10 1\n' ;;
  "-p 10 -o stat=") printf 'Ss\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKE_PS"

export PATH="$FAKEBIN:$PATH"
export FM_HERDR_PS_BIN="$FAKE_PS"
export FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=2
export FM_HOME="$HOME_FIXTURE"
export FM_ROOT_OVERRIDE="$ROOT"
export FM_PRIMARY_HERDR_BIN="$FAKEBIN/herdr"
export FM_PRIMARY_SERVER_ATTEMPTS=2
export FM_PRIMARY_SERVER_DELAY=0.02
export FM_PRIMARY_ATTEST_ATTEMPTS=100
export FM_PRIMARY_ATTEST_DELAY=0.02
export HERDR_ENV=1 HERDR_SESSION='lab-exact' HERDR_SOCKET_PATH="$SOCKET"
export HERDR_WORKSPACE_ID="$WORKSPACE" HERDR_TAB_ID="$TAB" HERDR_PANE_ID="$PANE"
export TEST_HERDR_LOG="$LOG" TEST_MODE_FILE="$MODE" TEST_SESSION='lab-exact' TEST_SOCKET="$SOCKET"
export TEST_PANE="$PANE" TEST_WORKSPACE="$WORKSPACE" TEST_TAB="$TAB"
export TEST_FULL_ID="$FULL_ID" TEST_SESSION_FILE="$SESSION_FILE" TEST_SESSION_DIR="$SESSION_DIR" TEST_CWD="$T"
export TEST_RESUME_LOG="$T/resume.log" TEST_PI_LOG="$T/pi.log" TEST_UMASK_FILE="$T/pi.umask" TEST_PI_CWD_FILE="$T/pi.cwd"
export TEST_ATTACH_ENV_FILE="$T/attach.env"
STRAY_STATE="$T/stray pane state"
ALT_STATE="$T/specialized state"
mkdir -p "$STRAY_STATE" "$ALT_STATE"
export TEST_STRAY_STATE="$STRAY_STATE"
SCRIPT="$ROOT/bin/fm-primary-pi.sh"
LEASE="$HOME_FIXTURE/state/primary-pi/lease"
RECOVERY_LOCK="$HOME_FIXTURE/state/primary-pi/recovery.lock"
LAUNCH_PID=''
RECOVERY_PID=''

cleanup() {
  local held
  for held in "$LEASE" "$ALT_STATE/primary-pi/lease"; do
    [ -f "$held" ] || continue
    pid=$(grep '^pid=' "$held" | cut -d= -f2-)
    kill -TERM "$pid" 2>/dev/null || true
  done
  [ -n "$LAUNCH_PID" ] && kill -TERM "$LAUNCH_PID" 2>/dev/null || true
  [ -n "$RECOVERY_PID" ] && kill -TERM "$RECOVERY_PID" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

wait_for() {
  local description=$1 i=0
  shift
  while [ "$i" -lt 150 ]; do
    "$@" && return 0
    sleep 0.02
    i=$((i + 1))
  done
  fail "timed out waiting for $description"
}

lease_live() {
  [ -f "$LEASE" ] && [ "$(cat "$MODE")" = pi ]
}

lease_absent() {
  [ ! -e "$LEASE" ] && [ "$(cat "$MODE")" = shell ]
}

# The lifetime lease is one atomically published private object: a regular
# mode 0600 record carrying exactly version, token, pid, and start.
assert_whole_lease() {
  [ -f "$LEASE" ] && [ ! -L "$LEASE" ] || fail "$1: the lease must be a regular non-symlink record"
  [ "$(file_mode "$LEASE")" = 600 ] || fail "$1: the lease must be private mode 0600"
  [ "$(cut -d= -f1 "$LEASE" | tr '\n' ' ')" = 'version token pid start ' ] \
    || fail "$1: the lease must carry exactly version, token, pid, and start"
  assert_grep 'version=1' "$LEASE" "$1: the lease must carry its schema version"
  [ -n "$(lease_token)" ] || fail "$1: the lease must carry a custody token"
  [ -n "$(grep '^start=' "$LEASE" | cut -d= -f2-)" ] || fail "$1: the lease must carry its owner start identity"
}

lease_token() {
  grep '^token=' "$LEASE" | cut -d= -f2-
}

seed_lease() {
  printf 'version=1\ntoken=%s\npid=999999\nstart=Mon Jan  1 00:00:00 2001\n' "$1" > "$LEASE"
  chmod 600 "$LEASE"
}

recovery_lock_present() {
  [ -f "$RECOVERY_LOCK" ]
}

path_absent() {
  [ ! -e "$1" ]
}

mode_is() {
  [ "$(cat "$MODE")" = "$1" ]
}

# A wrapped ordinary launch acquires lifetime custody and publishes exact state.
umask 022
"$SCRIPT" launch --pi pi > "$T/launch.out" 2>&1 &
LAUNCH_PID=$!
wait_for 'initial exact custody' lease_live
CUSTODY="$HOME_FIXTURE/state/primary-pi/custody.v1"
assert_grep 'version=1' "$CUSTODY" 'custody schema version must be present'
assert_grep "home=$HOME_FIXTURE" "$CUSTODY" 'canonical Firstmate home must be persisted'
assert_grep 'herdr_session=lab-exact' "$CUSTODY" 'exact named Herdr session must be persisted'
assert_grep "herdr_socket=$SOCKET" "$CUSTODY" 'exact Herdr socket must be persisted'
assert_grep "herdr_workspace_id=$WORKSPACE" "$CUSTODY" 'workspace id must be persisted'
assert_grep "herdr_tab_id=$TAB" "$CUSTODY" 'tab id must be persisted'
assert_grep "herdr_pane_id=$PANE" "$CUSTODY" 'pane id must be persisted'
assert_grep "pi_session_id=$FULL_ID" "$CUSTODY" 'full Pi session id must be persisted'
assert_grep "pi_session_file=$SESSION_FILE" "$CUSTODY" 'canonical Pi session file must be persisted'
assert_grep 'session_integrity=ok' "$CUSTODY" 'strict session result must be persisted'
[ "$(file_mode "$CUSTODY")" = 600 ] || fail 'custody must be private mode 0600'
[ "$(file_mode "$HOME_FIXTURE/state/primary-pi")" = 700 ] || fail 'private custody directory must be mode 0700'
assert_whole_lease 'a live lease'
[ "$(cat "$TEST_UMASK_FILE")" = 0022 ] || fail "private state writes must not change the umask Pi inherits: $(cat "$TEST_UMASK_FILE")"
pass 'wrapped launch publishes complete exact custody without widening the inherited umask'

# Live Pi always takes the attach-first path and duplicate launch is refused.
out=$(FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover 2>&1) || fail "attach-first recover failed: $out"
assert_contains "$out" 'primary live:' 'live recovery must report the existing Pi'
assert_absent "$RECOVERY_LOCK" 'a completed no-attach recovery must release its recovery ownership'
set +e
duplicate=$("$SCRIPT" launch --pi pi 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'duplicate wrapped launch unexpectedly succeeded'
assert_contains "$duplicate" 'already live' 'duplicate launch must identify live custody'
pass 'live exact Pi attaches first and duplicate launch is refused'

# Stop the first owner and wait for its token-matched clean lease release.
kill -TERM "$LAUNCH_PID"
wait "$LAUNCH_PID" 2>/dev/null || true
LAUNCH_PID=''
wait_for 'clean lease release' lease_absent
cp "$CUSTODY" "$T/custody.good"

# Corrupt JSONL, header mismatches, duplicate IDs, missing files, and unchecked paths all refuse.
printf '{broken\n' >> "$SESSION_FILE"
set +e
out=$(FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'malformed JSONL unexpectedly recovered'
assert_contains "$out" 'strict integrity' 'malformed JSONL must fail strict validation'
write_session
printf '{"type":"message","id":"m2",\n"parentId":null,"message":{"role":"user"}}\n' >> "$SESSION_FILE"
set +e
out=$(FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'a record split across physical lines unexpectedly recovered'
assert_contains "$out" 'strict integrity' 'a record spanning two physical lines must fail strict validation'
write_session
printf '{"type":"message","id":"m2"} {"type":"message","id":"m3"}\n' >> "$SESSION_FILE"
set +e
out=$(FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'two records on one physical line unexpectedly recovered'
assert_contains "$out" 'strict integrity' 'two records on one physical line must fail strict validation'
write_session
sed "s/\"id\":\"$FULL_ID\"/\"id\":\"wrong-full-id\"/" "$SESSION_FILE" > "$T/header-id.jsonl"
mv "$T/header-id.jsonl" "$SESSION_FILE"
set +e
FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover > "$T/header-id.out" 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'mismatched header id unexpectedly recovered'
write_session
sed "s#\"cwd\":\"$T\"#\"cwd\":\"/\"#" "$SESSION_FILE" > "$T/header-cwd.jsonl"
mv "$T/header-cwd.jsonl" "$SESSION_FILE"
set +e
FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover > "$T/header-cwd.out" 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'mismatched header cwd unexpectedly recovered'
write_session
cp "$SESSION_FILE" "$SESSION_DIR/duplicate.jsonl"
set +e
FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover > "$T/duplicate.out" 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'duplicate full session id unexpectedly recovered'
rm "$SESSION_DIR/duplicate.jsonl"
mv "$SESSION_FILE" "$T/missing.jsonl"
set +e
FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover > "$T/missing.out" 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'missing session file unexpectedly recovered'
mv "$T/missing.jsonl" "$SESSION_FILE"
ln -s "$SESSION_FILE" "$SESSION_DIR/link.jsonl"
awk -v p="$SESSION_DIR/link.jsonl" 'BEGIN{FS=OFS="="} $1=="pi_session_file"{$2=p} {print}' "$T/custody.good" > "$CUSTODY"
set +e
FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover > "$T/symlink.out" 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'symlink session path unexpectedly recovered'
rm "$SESSION_DIR/link.jsonl"
mkdir "$SESSION_DIR/not-file.jsonl"
awk -v p="$SESSION_DIR/not-file.jsonl" 'BEGIN{FS=OFS="="} $1=="pi_session_file"{$2=p} {print}' "$T/custody.good" > "$CUSTODY"
set +e
FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover > "$T/nonregular.out" 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'directory session path unexpectedly recovered'
rmdir "$SESSION_DIR/not-file.jsonl"
cp "$T/custody.good" "$CUSTODY"
pass 'malformed, non-line-oriented, header-mismatched, duplicate, missing, and non-regular session authority refuses recovery'

# Unknown/contradictory process evidence never becomes launch authority.
printf 'unknown\n' > "$MODE"
set +e
out=$(FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'unknown agent state unexpectedly recovered'
assert_contains "$out" 'unknown' 'unknown state refusal should be concise'
printf 'contradictory\n' > "$MODE"
set +e
out=$(FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'contradictory pane unexpectedly recovered'
assert_contains "$out" 'not a proven bare restored shell' 'contradictory process must not launch Pi'
pass 'unknown and contradictory process evidence refuses recovery'

# Server absence uses bounded exact-session retries and does not attach or launch.
printf 'server-down\n' > "$MODE"
: > "$LOG"
start=$(python3 -c 'import time; print(time.monotonic())')
set +e
out=$(FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover --no-server-start 2>&1); rc=$?
set -e
end=$(python3 -c 'import time; print(time.monotonic())')
[ "$rc" -ne 0 ] || fail 'absent server unexpectedly recovered'
python3 - "$start" "$end" <<'PY' || fail 'bounded server retry exceeded two seconds'
import sys
assert float(sys.argv[2]) - float(sys.argv[1]) < 2
PY
[ "$(grep -c 'status --json --session lab-exact' "$LOG")" -eq 2 ] || fail 'server retry count or exact session selection is wrong'
assert_no_grep 'agent get' "$LOG" 'server absence must not continue to pane inspection'
pass 'named-server absence terminates within the configured bound'

# A stale PID/start lease is reclaimable only once, and a concurrent recovery loses the lock.
printf 'shell\n' > "$MODE"
seed_lease aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
: > "$LOG"
: > "$TEST_RESUME_LOG"
: > "$TEST_PI_LOG"
# Invoked exactly the way the operator docs document it: a relative path from the
# code root. The fake pane runs its injected command from `/`, so a resume
# wrapper built from the caller's `$0` could never be found there.
(cd "$ROOT" && TEST_PANE_RUN_DELAY=0.5 FM_PRIMARY_NO_ATTACH=1 bin/fm-primary-pi.sh recover) > "$T/exact.out" 2>&1 &
RECOVERY_PID=$!
wait_for 'recovery ownership lock' recovery_lock_present
set +e
race=$(FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover 2>&1); race_rc=$?
set -e
[ "$race_rc" -ne 0 ] || fail 'concurrent recovery unexpectedly acquired duplicate authority'
assert_contains "$race" 'another recovery' 'concurrent recovery must report exclusive ownership'
if ! wait "$RECOVERY_PID"; then
  out=$(cat "$T/exact.out")
  fail "exact recovery failed: $out"
fi
RECOVERY_PID=''
out=$(cat "$T/exact.out")
assert_contains "$out" "pi_session=$FULL_ID" 'successful restart must report exact Pi session'
assert_grep "--session $FULL_ID" "$TEST_PI_LOG" 'Pi restart command must carry the full exact session id'
[ "$(cat "$TEST_PI_CWD_FILE")" = "$T" ] || fail 'Pi restart did not enter the exact recorded session cwd'
assert_no_grep ' --session-id ' "$TEST_PI_LOG" 'Pi restart command must never use --session-id'
assert_no_grep ' -c ' "$TEST_PI_LOG" 'Pi restart command must never use -c'
assert_grep 'result=ok' "$HOME_FIXTURE/state/primary-pi/attestation.v1" 'recovery must publish successful post-launch attestation'
assert_grep "pi_session_id=$FULL_ID" "$CUSTODY" 'post-launch custody must attest the exact full id'
new_token=$(lease_token)
[ "$new_token" != aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ] || fail 'stale lease token was not atomically replaced'
assert_whole_lease 'an atomically handed-off lease'
assert_absent "$RECOVERY_LOCK" 'a completed no-attach restart must release its recovery ownership'
assert_grep "env -u FM_STATE_OVERRIDE" "$LOG" 'a default-state restart must clear a stray pane state override'
assert_absent "$STRAY_STATE/primary-pi" 'a default-state restart must never write into the pane shell stray state tree'
assert_grep "pane get $PANE --session lab-exact" "$LOG" 'recovery must resolve only the exact recorded pane'
assert_grep "pane run $PANE" "$LOG" 'restart must target only the exact recorded pane'
assert_grep "'$ROOT/bin/fm-primary-pi.sh' resume" "$LOG" 'the restored pane must be driven through the canonical absolute script path'
assert_no_grep 'workspace list' "$LOG" 'workspace labels must not participate in recovery'
assert_no_grep 'tab list' "$LOG" 'tab labels or focus must not participate in recovery'
pass 'stale lease and race handling preserve an apostrophe-bearing exact recovery path'

# A second concurrent/repeated recover observes live custody and does not relaunch.
: > "$LOG"
out=$(FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover 2>&1) || fail "second attach-first recover failed: $out"
assert_contains "$out" 'primary live:' 'second recover must attach to the attested process'
assert_no_grep 'pane run' "$LOG" 'second recover must not launch another Pi'
assert_absent "$RECOVERY_LOCK" 'repeated no-attach recovery must not accumulate dead recovery ownership'
pass 'repeated recovery remains idempotently attach-first and leaves no recovery lock'

# A SIGKILL while the recovery guard is held can never publish an identity-less
# guard: the guard is a complete private record or it is absent. Hold the guard
# inside the bounded server wait so the kill lands long before any pane run.
printf 'server-down\n' > "$MODE"
FM_PRIMARY_SERVER_ATTEMPTS=2000 FM_PRIMARY_SERVER_DELAY=0.05 \
  FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover --no-server-start > "$T/crash.out" 2>&1 &
CRASH_PID=$!
wait_for 'recovery guard published before the crash' recovery_lock_present
kill -9 "$CRASH_PID"
wait "$CRASH_PID" 2>/dev/null || true
[ -f "$RECOVERY_LOCK" ] && [ ! -L "$RECOVERY_LOCK" ] || fail 'a killed wrapper must leave a regular guard record'
[ "$(file_mode "$RECOVERY_LOCK")" = 600 ] || fail 'the guard left by a killed wrapper must stay private mode 0600'
assert_grep "pid=$CRASH_PID" "$RECOVERY_LOCK" 'a killed wrapper must leave its owner pid in the guard'
assert_grep 'start=' "$RECOVERY_LOCK" 'a killed wrapper must leave its owner start identity in the guard'
[ "$(grep -c . "$RECOVERY_LOCK")" -eq 2 ] || fail 'the guard must carry exactly the pid and start identity fields'
printf 'pi\n' > "$MODE"
out=$(FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover 2>&1) || fail "PID/start-dead guard was not reclaimable: $out"
assert_contains "$out" 'primary live:' 'reclaiming a dead guard must still take the attach-first path'
assert_absent "$RECOVERY_LOCK" 'reclaimed guard must be released again'
# An identity-less or non-regular object at the guard path is foreign state this
# script cannot produce, so it refuses instead of guessing ownership.
for shape in empty directory; do
  case "$shape" in
    empty) : > "$RECOVERY_LOCK" ;;
    directory) mkdir "$RECOVERY_LOCK" ;;
  esac
  set +e
  out=$(FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a $shape guard shape unexpectedly granted recovery ownership"
  assert_contains "$out" 'another recovery' "a $shape guard shape must refuse as ambiguous ownership"
  case "$shape" in
    empty) rm -f "$RECOVERY_LOCK" ;;
    directory) rmdir "$RECOVERY_LOCK" ;;
  esac
done
out=$(FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover 2>&1) || fail "recovery did not resume after the foreign guard was removed: $out"
assert_contains "$out" 'primary live:' 'removing the foreign guard must restore ordinary attach-first recovery'
pass 'a killed wrapper leaves a complete reclaimable guard and foreign guard shapes refuse'

# The real attach addresses only the exact recorded named session: an operator
# running recover from a pane of some other session must not leak that ambient
# selector into the attach it execs away into.
: > "$TEST_ATTACH_ENV_FILE"
HERDR_SESSION='decoy-ambient-session' "$SCRIPT" recover > "$T/attach.out" 2>&1 \
  || fail "exact attach failed: $(cat "$T/attach.out")"
[ "$(cat "$TEST_ATTACH_ENV_FILE")" = lab-exact ] \
  || fail "attach must pin HERDR_SESSION to the exact recorded session: $(cat "$TEST_ATTACH_ENV_FILE")"
assert_grep 'agent attach w1:p1 --session lab-exact' "$LOG" 'attach must also carry the explicit exact session selector'
pass 'the exec attach pins the exact recorded named session over an ambient one'

# Stop the recovered wrapper through exact recorded PID/start custody.
owner=$(grep '^pid=' "$LEASE" | cut -d= -f2-)
kill -TERM "$owner"
wait_for 'recovered owner cleanup' lease_absent

# A post-launch identity mismatch fails, kills only the fresh token owner, and never reports recovery.
printf 'shell\n' > "$MODE"
sleep 30 &
unrelated=$!
set +e
out=$(TEST_ATTEST_ID='wrong-full-id' FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'post-launch identity mismatch unexpectedly recovered'
assert_contains "$out" 'attestation failed' 'identity mismatch must be reported as failed attestation'
wait_for 'failed token owner cleanup' path_absent "$LEASE"
[ "$(cat "$MODE")" != pi ] || fail 'mismatched Pi remained presented as live'
kill -0 "$unrelated" 2>/dev/null || fail 'token cleanup signaled an unrelated process'
kill "$unrelated" 2>/dev/null || true
wait "$unrelated" 2>/dev/null || true
pass 'post-launch mismatch refuses success and cleans only fresh token custody'

# A SIGKILL anywhere in a wrapper's lifetime can never publish a partial lease.
# The lease is one hardlinked record, so an interrupted wrapper leaves either no
# lease at all or a complete PID/start identity that the next recovery reclaims.
printf 'shell\n' > "$MODE"
out=$(FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover 2>&1) || fail "the restart before the lease crash failed: $out"
assert_whole_lease 'a live restarted lease'
killed_owner=$(grep '^pid=' "$LEASE" | cut -d= -f2-)
killed_token=$(lease_token)
orphan_pi=$(grep '^pi_pid=' "$HOME_FIXTURE/state/primary-pi/attestation.v1" | cut -d= -f2-)
kill -9 "$killed_owner"
assert_whole_lease 'the lease a SIGKILLed wrapper leaves behind'
kill -TERM "$orphan_pi" 2>/dev/null || true
wait_for 'the orphaned Pi to leave a bare restored shell' mode_is shell
assert_whole_lease 'the preserved lease after the orphaned Pi exits'
: > "$LOG"
out=$(FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover 2>&1) \
  || fail "the lease left by a SIGKILLed wrapper was not reclaimable: $out"
assert_contains "$out" "pi_session=$FULL_ID" 'reclaiming a crash-left lease must restore the exact Pi session'
assert_whole_lease 'the reclaimed lease'
[ "$(lease_token)" != "$killed_token" ] || fail 'the crash-left lease token was not atomically replaced'
owner=$(grep '^pid=' "$LEASE" | cut -d= -f2-)
kill -TERM "$owner"
wait_for 'crash-reclaim cleanup' lease_absent
pass 'a SIGKILLed wrapper leaves only a complete, reclaimable lifetime lease'

# A specialized state home is a supported operational override, and the restored
# pane runs its own shell. The generated command must therefore carry that exact
# resolved state path, apostrophe and space included, rather than inheriting the
# pane's own stray value.
mkdir -p "$ALT_STATE/primary-pi"
chmod 700 "$ALT_STATE/primary-pi"
cp "$T/custody.good" "$ALT_STATE/primary-pi/custody.v1"
chmod 600 "$ALT_STATE/primary-pi/custody.v1"
printf 'shell\n' > "$MODE"
: > "$LOG"
out=$(FM_STATE_OVERRIDE="$ALT_STATE" FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover 2>&1) \
  || fail "specialized-state recovery failed: $out"
assert_contains "$out" "pi_session=$FULL_ID" 'specialized-state recovery must restore the exact Pi session'
alt_quoted=$(printf '%s' "$ALT_STATE" | sed "s/'/'\\\\''/g")
assert_grep "FM_STATE_OVERRIDE='$alt_quoted'" "$LOG" 'the generated resume command must pin the exact resolved state path with POSIX-safe quoting'
assert_present "$ALT_STATE/primary-pi/lease" 'the restarted wrapper must hold its lease in the specialized state tree'
assert_grep 'result=ok' "$ALT_STATE/primary-pi/attestation.v1" 'the specialized state tree must carry the attestation the parent polled'
assert_absent "$STRAY_STATE/primary-pi" 'no restart may follow the pane shell stray state override'
assert_absent "$LEASE" 'a specialized-state restart must not touch the default state tree'
alt_owner=$(grep '^pid=' "$ALT_STATE/primary-pi/lease" | cut -d= -f2-)
kill -TERM "$alt_owner"
wait_for 'specialized-state cleanup' path_absent "$ALT_STATE/primary-pi/lease"
pass 'recovery into an apostrophe-bearing specialized state home stays self-consistent'

# Launch session-selection shortcuts are refused before invoking Pi.
for bad in -c --resume --session-id=foo --session=foo --no-session; do
  printf 'none\n' > "$MODE"
  set +e
  out=$("$SCRIPT" launch --pi pi -- "$bad" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "forbidden launch option succeeded: $bad"
  assert_contains "$out" 'forbids Pi session-selection' "forbidden launch option should explain refusal: $bad"
done
pass 'interactive, partial, and create-on-miss Pi selectors are unavailable'

# Malformed private records are reported by status, never turned into an exit.
printf 'none\n' > "$MODE"
cp "$CUSTODY" "$T/custody.attested"
awk 'BEGIN{FS=OFS="="} $1=="pi_session_id"{$2="full session 1234567890"} {print}' "$T/custody.attested" > "$CUSTODY"
out=$("$SCRIPT" status 2>&1) || fail "status must report a malformed session id instead of exiting: $out"
assert_contains "$out" 'custody=unknown' 'a malformed full Pi session id must read as unknown custody'
cp "$T/custody.attested" "$CUSTODY"
seed_lease not-a-hex-token
out=$("$SCRIPT" status 2>&1) || fail "status must report a malformed lease token instead of exiting: $out"
assert_contains "$out" 'lease=malformed' 'a non-hex lease token must read as a malformed lease'
# An old-layout or otherwise foreign object at the lease path is unknown state
# this script cannot publish, so it reads as malformed rather than reclaimable.
rm -f "$LEASE"
mkdir "$LEASE"
out=$("$SCRIPT" status 2>&1) || fail "status must report a non-regular lease instead of exiting: $out"
assert_contains "$out" 'lease=malformed' 'a non-regular lease object must read as a malformed lease'
rmdir "$LEASE"
# A readable custody record whose recorded lease identity disagrees with the
# on-disk lease is the one state that is genuinely contradictory.
seed_lease cccccccccccccccccccccccccccccccc
out=$("$SCRIPT" status 2>&1) || fail "status must report a mismatched lease instead of exiting: $out"
assert_contains "$out" 'lease=contradictory' 'a lease disagreeing with readable custody must read as contradictory'
rm -f "$LEASE"
pass 'malformed, non-regular, and custody-contradicting lease records are reported by status rather than exiting'

# A crash before first attestation leaves a lease with no custody. `launch` runs
# inside the very pane it would have to prove agent-free, so it never reclaims
# that lease automatically: it preserves the evidence, refuses, and leaves only
# the documented manual removal as the supported exit.
mv "$HOME_FIXTURE/state/primary-pi" "$T/previous-primary-state"
mkdir -p "$HOME_FIXTURE/state/primary-pi"
chmod 700 "$HOME_FIXTURE/state/primary-pi"
seed_lease bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
# Without a custody record there is no recorded endpoint, so status reports the
# lease it can read and refuses to guess a pane or agent it never recorded. A
# lease cannot contradict a custody record that does not exist, so this reads as
# the plain PID/start-dead lease the documented manual fallback acts on.
out=$("$SCRIPT" status 2>&1) || fail "status must report the pre-attestation state instead of exiting: $out"
assert_contains "$out" 'custody=unknown' 'a pre-attestation state must read as unknown custody'
assert_contains "$out" 'lease=stale' 'an absent-custody dead lease must read as stale, not contradictory'
assert_contains "$out" 'pane=unknown' 'status must not name a pane it never recorded'
assert_contains "$out" 'agent=unknown' 'status must not claim agent evidence it never recorded'
for pane_state in unknown shell pi; do
  printf '%s\n' "$pane_state" > "$MODE"
  : > "$LOG"
  set +e
  out=$("$SCRIPT" launch --pi pi 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "stale pre-attestation lease unexpectedly relaunched with a $pane_state pane"
  assert_contains "$out" 'preserved as evidence' "stale pre-attestation launch must refuse with a $pane_state pane"
  assert_grep 'token=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$LEASE" 'refused stale launch must preserve its lease evidence'
  assert_absent "$HOME_FIXTURE/state/primary-pi/custody.v1" 'refused stale launch must not publish custody'
  assert_absent "$RECOVERY_LOCK" 'refused stale launch must release its recovery ownership'
  assert_grep 'pane get' "$LOG" 'stale pre-attestation launch must still verify its own injected pane identity'
  assert_no_grep 'agent get' "$LOG" 'launch must never turn a pane agent reading into stale-lease authority'
  assert_no_grep 'pane process-info' "$LOG" 'launch must never claim an in-pane bare-shell proof of itself'
done
# The documented narrow manual fallback: remove the stale lease by hand, then launch.
printf 'shell\n' > "$MODE"
rm -f "$LEASE"
"$SCRIPT" launch --pi pi > "$T/stale-launch.out" 2>&1 &
LAUNCH_PID=$!
wait_for 'manual-fallback launch after the stale lease is removed' lease_live
new_token=$(lease_token)
[ "$new_token" != bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ] || fail 'manual-fallback launch reused the removed stale token'
assert_present "$HOME_FIXTURE/state/primary-pi/custody.v1" 'manual-fallback launch must publish fresh attested custody'
kill -TERM "$LAUNCH_PID"
wait "$LAUNCH_PID" 2>/dev/null || true
LAUNCH_PID=''
wait_for 'manual-fallback launch cleanup' lease_absent
pass 'stale pre-attestation launch preserves its evidence and exits only through the documented manual fallback'

printf 'all fm-primary-pi executable-interface tests passed\n'
