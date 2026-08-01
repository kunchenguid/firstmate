#!/usr/bin/env bash
# Executable-interface tests for guarded Pi-on-Herdr primary custody and recovery.
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(mktemp -d "${TMPDIR:-/tmp}/fm-primary-pi.XXXXXX")
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
      printf '{"result":{"process_info":{"shell_pid":10,"foreground_processes":[{"pid":20,"argv0":"pi","name":"pi"}]}}}\n'
    elif [ "$(cat "$TEST_MODE_FILE")" = contradictory ]; then
      printf '{"result":{"process_info":{"shell_pid":10,"foreground_processes":[{"pid":30,"argv0":"node","name":"node"}]}}}\n'
    else
      printf '{"result":{"process_info":{"shell_pid":10,"foreground_processes":[{"pid":10,"argv0":"zsh","name":"zsh"}]}}}\n'
    fi
    ;;
  'pane run')
    sleep "${TEST_PANE_RUN_DELAY:-0}"
    bash -c "$4" >> "$TEST_RESUME_LOG" 2>&1 &
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

export PATH="$FAKEBIN:$PATH"
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
export TEST_RESUME_LOG="$T/resume.log" TEST_PI_LOG="$T/pi.log" TEST_UMASK_FILE="$T/pi.umask"
SCRIPT="$ROOT/bin/fm-primary-pi.sh"
RECOVERY_LOCK="$HOME_FIXTURE/state/primary-pi/recovery.lock"
LAUNCH_PID=''
RECOVERY_PID=''

cleanup() {
  if [ -f "$HOME_FIXTURE/state/primary-pi/lease/owner" ]; then
    pid=$(grep '^pid=' "$HOME_FIXTURE/state/primary-pi/lease/owner" | cut -d= -f2-)
    kill -TERM "$pid" 2>/dev/null || true
  fi
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
  [ -f "$HOME_FIXTURE/state/primary-pi/lease/owner" ] && [ "$(cat "$MODE")" = pi ]
}

lease_absent() {
  [ ! -e "$HOME_FIXTURE/state/primary-pi/lease" ] && [ "$(cat "$MODE")" = shell ]
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
[ "$(stat -f '%Lp' "$CUSTODY" 2>/dev/null || stat -c '%a' "$CUSTODY")" = 600 ] || fail 'custody must be private mode 0600'
LEASE_DIR="$HOME_FIXTURE/state/primary-pi/lease"
LEASE_TOKEN_FILE="$LEASE_DIR/token"
[ "$(stat -f '%Lp' "$LEASE_DIR" 2>/dev/null || stat -c '%a' "$LEASE_DIR")" = 700 ] || fail 'lease directory must be private mode 0700'
[ "$(stat -f '%Lp' "$LEASE_TOKEN_FILE" 2>/dev/null || stat -c '%a' "$LEASE_TOKEN_FILE")" = 600 ] || fail 'lease token must be private mode 0600'
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
pass 'malformed, header-mismatched, duplicate, missing, and non-regular session authority refuses recovery'

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
mkdir "$HOME_FIXTURE/state/primary-pi/lease"
printf 'version=1\n' > "$HOME_FIXTURE/state/primary-pi/lease/version"
printf 'token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$HOME_FIXTURE/state/primary-pi/lease/token"
printf 'pid=999999\nstart=Mon Jan  1 00:00:00 2001\n' > "$HOME_FIXTURE/state/primary-pi/lease/owner"
chmod 700 "$HOME_FIXTURE/state/primary-pi/lease"
chmod 600 "$HOME_FIXTURE/state/primary-pi/lease/"*
: > "$LOG"
: > "$TEST_RESUME_LOG"
: > "$TEST_PI_LOG"
TEST_PANE_RUN_DELAY=0.5 FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover > "$T/exact.out" 2>&1 &
RECOVERY_PID=$!
wait_for 'recovery ownership lock' bash -c "[ -d '$HOME_FIXTURE/state/primary-pi/recovery.lock' ]"
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
assert_no_grep ' --session-id ' "$TEST_PI_LOG" 'Pi restart command must never use --session-id'
assert_no_grep ' -c ' "$TEST_PI_LOG" 'Pi restart command must never use -c'
assert_grep 'result=ok' "$HOME_FIXTURE/state/primary-pi/attestation.v1" 'recovery must publish successful post-launch attestation'
assert_grep "pi_session_id=$FULL_ID" "$CUSTODY" 'post-launch custody must attest the exact full id'
new_token=$(grep '^token=' "$HOME_FIXTURE/state/primary-pi/lease/token" | cut -d= -f2-)
[ "$new_token" != aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ] || fail 'stale lease token was not atomically replaced'
assert_absent "$RECOVERY_LOCK" 'a completed no-attach restart must release its recovery ownership'
assert_grep "pane get $PANE --session lab-exact" "$LOG" 'recovery must resolve only the exact recorded pane'
assert_grep "pane run $PANE" "$LOG" 'restart must target only the exact recorded pane'
assert_no_grep 'workspace list' "$LOG" 'workspace labels must not participate in recovery'
assert_no_grep 'tab list' "$LOG" 'tab labels or focus must not participate in recovery'
pass 'stale lease and race handling converge on one exact attested session'

# A second concurrent/repeated recover observes live custody and does not relaunch.
: > "$LOG"
out=$(FM_PRIMARY_NO_ATTACH=1 "$SCRIPT" recover 2>&1) || fail "second attach-first recover failed: $out"
assert_contains "$out" 'primary live:' 'second recover must attach to the attested process'
assert_no_grep 'pane run' "$LOG" 'second recover must not launch another Pi'
assert_absent "$RECOVERY_LOCK" 'repeated no-attach recovery must not accumulate dead recovery ownership'
pass 'repeated recovery remains idempotently attach-first and leaves no recovery lock'

# Stop the recovered wrapper through exact recorded PID/start custody.
owner=$(grep '^pid=' "$HOME_FIXTURE/state/primary-pi/lease/owner" | cut -d= -f2-)
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
wait_for 'failed token owner cleanup' bash -c "[ ! -e '$HOME_FIXTURE/state/primary-pi/lease' ]"
[ "$(cat "$MODE")" != pi ] || fail 'mismatched Pi remained presented as live'
kill -0 "$unrelated" 2>/dev/null || fail 'token cleanup signaled an unrelated process'
kill "$unrelated" 2>/dev/null || true
wait "$unrelated" 2>/dev/null || true
pass 'post-launch mismatch refuses success and cleans only fresh token custody'

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
mkdir "$HOME_FIXTURE/state/primary-pi/lease"
printf 'version=1\n' > "$HOME_FIXTURE/state/primary-pi/lease/version"
printf 'token=not-a-hex-token\n' > "$HOME_FIXTURE/state/primary-pi/lease/token"
printf 'pid=999999\nstart=Mon Jan  1 00:00:00 2001\n' > "$HOME_FIXTURE/state/primary-pi/lease/owner"
chmod 700 "$HOME_FIXTURE/state/primary-pi/lease"
chmod 600 "$HOME_FIXTURE/state/primary-pi/lease/"*
out=$("$SCRIPT" status 2>&1) || fail "status must report a malformed lease token instead of exiting: $out"
assert_contains "$out" 'lease=malformed' 'a non-hex lease token must read as a malformed lease'
rm -rf "$HOME_FIXTURE/state/primary-pi/lease"
pass 'malformed custody and lease records are reported by status rather than exiting'

printf 'all fm-primary-pi executable-interface tests passed\n'
