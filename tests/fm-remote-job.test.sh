#!/usr/bin/env bash
# Behavior tests for the bounded remote job queue and worker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
RUNTIME_BIN="$TMP_ROOT/runtime-bin"
FAKE_PERL_LOG="$TMP_ROOT/perl.log"
REAL_GIT=$(command -v git)
OTHER_PID=
RECOVERY_WORKER_PID=
REPEAT_WORKER_PID=
RESTART_SUPERVISOR_PID=
QUARANTINE_TEST_WORKER_PID=
QUARANTINE_TEST_AUX_PID=
mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME" "$RUNTIME_BIN"
# worker.pid records the serving child, not its restart supervisor, so stopping
# that pid alone leaves the supervisor to respawn - the leak
# tests/fm-remote-job-orphan-reap.test.sh pins. Stop the whole worker tree.
cleanup_remote_job_fixture() {
  [ -z "$OTHER_PID" ] || kill "$OTHER_PID" 2>/dev/null || true
  [ -z "$RECOVERY_WORKER_PID" ] || kill "$RECOVERY_WORKER_PID" 2>/dev/null || true
  [ -z "$REPEAT_WORKER_PID" ] || kill "$REPEAT_WORKER_PID" 2>/dev/null || true
  [ -z "$RESTART_SUPERVISOR_PID" ] || kill -KILL "$RESTART_SUPERVISOR_PID" 2>/dev/null || true
  [ -z "$QUARANTINE_TEST_WORKER_PID" ] || kill -KILL "$QUARANTINE_TEST_WORKER_PID" 2>/dev/null || true
  [ -z "$QUARANTINE_TEST_AUX_PID" ] || kill -KILL "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || true
  if [ -f "$STATE_ROOT/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$STATE_ROOT/worker.pid")" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup_remote_job_fixture EXIT

cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" \
  "$ROOT/bin/fm-remote-delta-read.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-probe-job.sh" <<'SH'
#!/bin/bash
set -u
printf 'home=%s\nroot=%s\nactive=%s\npath=%s\n' "$FM_HOME" "$FM_ROOT_OVERRIDE" "${FM_REMOTE_JOB_ACTIVE:-}" "$PATH"
printf 'args:'
printf ' <%s>' "$@"
printf '\n'
if [ -n "${TOP_SECRET:-}" ]; then printf 'secret=leaked\n'; else printf 'secret=absent\n'; fi
while IFS= read -r line || [ -n "$line" ]; do printf 'stdin=%s\n' "$line"; done
exit "${FM_PROBE_EXIT:-0}"
SH
cat > "$REMOTE_ROOT/bin/fm-timeout-job.sh" <<'SH'
#!/bin/bash
sleep 3
SH
cat > "$REMOTE_ROOT/bin/fm-delay-job.sh" <<'SH'
#!/bin/bash
sleep "$1"
printf 'ran\n' > "$2"
SH
cat > "$REMOTE_ROOT/bin/fm-touch-job.sh" <<'SH'
#!/bin/bash
printf 'ran\n' > "$1"
SH
cat > "$REMOTE_ROOT/bin/fm-shutdown-job.sh" <<'SH'
#!/bin/bash
trap '' HUP INT TERM
printf 'started\n' > "$1"
sleep 3
printf 'ran\n' > "$2"
SH
cat > "$REMOTE_ROOT/bin/fm-output-job.sh" <<'SH'
#!/bin/bash
set -e
head -c 1200000 < /dev/zero
head -c 1200000 < /dev/zero >&2
exit 23
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
cat > "$RUNTIME_BIN/perl" <<'SH'
#!/bin/bash
printf 'invoked\n' >> "$FM_FAKE_PERL_LOG"
exit 127
SH
chmod +x "$RUNTIME_BIN/perl"

git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'remote job fixture'

DEFAULT_STATE="$TMP_ROOT/default-timeout-jobs"
DEFAULT_BOUNDS=$(
  unset FM_REMOTE_JOB_QUEUE_TIMEOUT
  unset FM_REMOTE_JOB_TIMEOUT
  # shellcheck disable=SC2030 # This source intentionally initializes subshell-only defaults.
  FM_REMOTE_JOB_STATE_ROOT="$DEFAULT_STATE"
  export FM_REMOTE_JOB_STATE_ROOT
  # shellcheck source=bin/fm-remote-job-lib.sh
  . "$ROOT/bin/fm-remote-job-lib.sh"
  fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-probe-job.sh </dev/null >/dev/null
  printf '%s %s\n' \
    "$(cat "$DEFAULT_STATE/jobs/$FM_REMOTE_JOB_ID/queue_deadline")" \
    "$(cat "$DEFAULT_STATE/jobs/$FM_REMOTE_JOB_ID/timeout")"
)
read -r DEFAULT_QUEUE_DEADLINE DEFAULT_EXECUTION_TIMEOUT <<< "$DEFAULT_BOUNDS"
DEFAULT_QUEUE_REMAINING=$((DEFAULT_QUEUE_DEADLINE - $(date +%s)))
[ "$DEFAULT_QUEUE_REMAINING" -ge 350 ] || fail "the default queue bound is too short"
[ "$DEFAULT_EXECUTION_TIMEOUT" -ge 350 ] || fail "the default execution bound cannot contain a 300-second long poll"
pass "default queue and execution bounds independently cover long polls"

# shellcheck disable=SC2031 # The earlier assignment was confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
# shellcheck disable=SC2031 # The sourced defaults above were confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_QUEUE_TIMEOUT=5
# shellcheck disable=SC2031 # The sourced defaults above were confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_TIMEOUT=5
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

LOCAL_BIN_PARENT="$ACCOUNT_HOME/.local"
LOCAL_BIN_TARGET="$TMP_ROOT/local-bin-target"
mkdir -p "$LOCAL_BIN_PARENT" "$LOCAL_BIN_TARGET"
ln -s "$LOCAL_BIN_TARGET" "$LOCAL_BIN_PARENT/bin"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
case ":$FM_REMOTE_JOB_OPERATOR_PATH:" in
  *":$LOCAL_BIN_PARENT/bin:"*|*":$LOCAL_BIN_TARGET:"*) fail "the composed PATH followed a symlinked local bin" ;;
esac
rm -f "$LOCAL_BIN_PARENT/bin"
mkdir "$LOCAL_BIN_PARENT/bin"
pass "operator PATH excludes a symlinked local bin"

NVM_ROOT="$ACCOUNT_HOME/.nvm"
NVM_V20="$NVM_ROOT/versions/node/v20.18.0/bin"
NVM_V24="$NVM_ROOT/versions/node/v24.14.1/bin"
mkdir -p "$NVM_ROOT/alias" "$NVM_V20" "$NVM_V24"
printf '20\n' > "$NVM_ROOT/alias/default"
printf '#!/bin/bash\nprintf "20\\n"\n' > "$NVM_V20/node"
printf '#!/bin/bash\nprintf "24\\n"\n' > "$NVM_V24/node"
chmod +x "$NVM_V20/node" "$NVM_V24/node"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
NVM_SELECTED=$(PATH="$FM_REMOTE_JOB_OPERATOR_PATH" node)
[ "$NVM_SELECTED" = 20 ] || fail "the composed PATH ignored nvm's default alias"
rm -f "$NVM_ROOT/alias/default"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
NVM_SELECTED=$(PATH="$FM_REMOTE_JOB_OPERATOR_PATH" node)
[ "$NVM_SELECTED" = 24 ] || fail "the nvm fallback did not select the highest installed version"
printf 'system\n' > "$NVM_ROOT/alias/default"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
case ":$FM_REMOTE_JOB_OPERATOR_PATH:" in
  *":$NVM_V20:"*|*":$NVM_V24:"*) fail "the composed PATH ignored nvm's system default" ;;
esac
printf '20\n' > "$NVM_ROOT/alias/default"
pass "operator PATH honors nvm defaults with a deterministic fallback"

NIX_PROFILE="$ACCOUNT_HOME/.nix-profile"
NIX_BIN="$TMP_ROOT/nix-profile-bin"
mkdir -p "$NIX_PROFILE" "$NIX_BIN"
ln -s "$NIX_BIN" "$NIX_PROFILE/bin"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
case ":$FM_REMOTE_JOB_OPERATOR_PATH:" in
  *":$NIX_BIN:"*) ;;
  *) fail "the composed PATH omitted a resolved Nix profile bin link" ;;
esac
pass "operator PATH resolves the authorized Nix profile bin link"

# Which install of a multi-version tool a remote job resolves is decided by the
# order these directories land on PATH, so the composition has to be sorted
# rather than whatever order the filesystem returns. The fixture is created in
# a deliberately unsorted order, and the expectation is the shell's own
# pathname expansion - the mechanism the portable-PATH contract in
# tests/fm-on.test.sh reconstructs.
MISE_INSTALLS="$ACCOUNT_HOME/.local/share/mise/installs"
for TOOL_VERSION in node/26.7.0 node/8.1 node/26 bun/1.4 bun/1.3.14 python/3.12.7; do
  mkdir -p "$MISE_INSTALLS/$TOOL_VERSION/bin"
done
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
MISE_COMPOSED=$(printf '%s\n' "$FM_REMOTE_JOB_OPERATOR_PATH" | tr ':' '\n' | grep -F "$MISE_INSTALLS/" || true)
MISE_EXPECTED=$(printf '%s\n' "$MISE_INSTALLS"/*/*/bin)
[ "$MISE_COMPOSED" = "$MISE_EXPECTED" ] \
  || fail "the composed operator PATH did not order tool installs like the shell's own expansion"$'\n'"expected: $MISE_EXPECTED"$'\n'"actual:   $MISE_COMPOSED"
# This assertion detects the defect on bash 3.2 and 5.2, where compgen -G returns unsorted glob matches, but reads green on bash 5.3+ because glob sorting moved into the glob library so both mechanisms agree there.
rm -rf -- "$ACCOUNT_HOME/.local/share/mise"
pass "operator PATH orders discovered tool installs deterministically"

HOME="$ACCOUNT_HOME" PATH="$RUNTIME_BIN:/usr/bin:/bin:/usr/sbin:/sbin" FM_FAKE_PERL_LOG="$FAKE_PERL_LOG" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_TIMEOUT=5 \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
for _ in $(seq 1 100); do
  [ -f "$STATE_ROOT/worker.ready" ] && break
  sleep 0.05
done
assert_present "$STATE_ROOT/worker.ready" "the worker did not publish its readiness heartbeat"

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

printf 'first line\nsecond line\n' > "$TMP_ROOT/stdin"
# shellcheck disable=SC2016 # Literal shell-looking argv is an injection probe.
TOP_SECRET=must-not-cross fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-probe-job.sh 'two words' '$(not executed)' < "$TMP_ROOT/stdin" > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
[ "$(file_mode "$JOB_DIR")" = 700 ] \
  || fail "staged job directory is not mode 0700"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the completed probe did not preserve exit status"
OUT=$(<"$FM_REMOTE_JOB_STDOUT")
assert_contains "$OUT" "home=$REMOTE_HOME" "the worker did not pass the staged FM_HOME"
assert_contains "$OUT" "root=$REMOTE_ROOT" "the worker did not pass the configured root"
assert_contains "$OUT" 'active=1' "the target did not execute inside the worker environment"
# shellcheck disable=SC2016 # Literal shell-looking expected output is an injection probe.
assert_contains "$OUT" 'args: <two words> <$(not executed)>' "the worker changed argv boundaries"
assert_contains "$OUT" 'stdin=first line' "the worker lost staged stdin"
assert_contains "$OUT" 'stdin=second line' "the worker lost staged stdin"
assert_contains "$OUT" 'secret=absent' "ambient environment crossed into the worker child"
case "$OUT" in *"$REMOTE_ROOT/bin:$ACCOUNT_HOME/.local/bin:"*) : ;; *) fail "worker PATH omitted its fixed root and account head" ;; esac
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the completed job could not be reaped"
assert_absent "$JOB_DIR" "reap retained a completed job record"
assert_absent "$FAKE_PERL_LOG" "the worker invoked an unavailable Perl runtime"
pass "the worker preserves bounded argv and stdin in an empty environment"

ACTIVE_SIDE_EFFECT="$TMP_ROOT/active-side-effect"
FM_REMOTE_JOB_TIMEOUT=10
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-delay-job.sh 4 "$ACTIVE_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the active-job readiness fixture did not begin running"
ACTIVE_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
touch -t 200001010000 "$STATE_ROOT/worker.ready"
for _ in $(seq 1 40); do
  fm_remote_job_probe "$ACCOUNT_HOME" && break
  sleep 0.05
done
fm_remote_job_probe "$ACCOUNT_HOME" || fail "the active worker did not refresh its readiness heartbeat"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
[ "$(cat "$STATE_ROOT/worker.pid")" = "$ACTIVE_WORKER_PID" ] \
  || fail "ensure replaced a healthy worker during an active job"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the active job did not complete after the readiness probe"
assert_present "$ACTIVE_SIDE_EFFECT" "the active job was interrupted by the concurrent readiness check"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the active readiness job could not be reaped"
pass "active jobs keep the worker ready for concurrent requests"

OLD_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
printf '\n' >> "$REMOTE_ROOT/bin/fm-remote-job-worker.sh"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "$FM_REMOTE_JOB_ERROR"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
[ "$NEW_WORKER_PID" != "$OLD_WORKER_PID" ] || fail "ensure retained a worker running stale code"
fm_remote_job_worker_identity_matches "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "the replacement worker did not publish the current code identity"
pass "ensure replaces a live worker after its code changes"

RELOCATED_ROOT="$TMP_ROOT/relocated-root"
cp -R "$REMOTE_ROOT" "$RELOCATED_ROOT"
OLD_WORKER_PID=$NEW_WORKER_PID
OLD_WORKER_PGID=$(fm_remote_job_process_pgid "$OLD_WORKER_PID") \
  || fail "the worker replacement fixture could not resolve its process group"
fm_remote_job_ensure_worker "$RELOCATED_ROOT" "$ACCOUNT_HOME" \
  || fail "$FM_REMOTE_JOB_ERROR"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
[ "$NEW_WORKER_PID" != "$OLD_WORKER_PID" ] || fail "ensure retained a worker bound to a different code root"
! kill -0 -- "-$OLD_WORKER_PGID" 2>/dev/null \
  || fail "ensure left the replaced worker supervisor group alive"
fm_remote_job_stage "$ACCOUNT_HOME" "$RELOCATED_ROOT" "$REMOTE_HOME" fm-probe-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the relocated worker rejected its configured code root"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the relocated-root probe could not be reaped"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
pass "worker identity binds the canonical configured code root"

CRASHED_WORKER_PID=$NEW_WORKER_PID
kill -KILL "$CRASHED_WORKER_PID"
wait "$CRASHED_WORKER_PID" 2>/dev/null || true
assert_present "$STATE_ROOT/worker.lock" "an unclean exit did not retain the worker ownership lock"
sleep 20 &
OTHER_PID=$!
printf '%s\n' "$OTHER_PID" > "$STATE_ROOT/worker.pid"
printf '%s\n' "$OTHER_PID" > "$STATE_ROOT/worker.lock/pid"
touch -t 200001010000 "$STATE_ROOT/worker.ready" "$STATE_ROOT/worker.lock"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "$FM_REMOTE_JOB_ERROR"
kill -0 "$OTHER_PID" 2>/dev/null || fail "stale worker state caused an unrelated process to be signaled"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
[ "$NEW_WORKER_PID" != "$OTHER_PID" ] || fail "the replacement adopted an unrelated persisted pid"
fm_remote_job_worker_identity_matches "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "stale ownership recovery did not start the current worker"
kill "$OTHER_PID" 2>/dev/null || true
wait "$OTHER_PID" 2>/dev/null || true
OTHER_PID=
pass "stale ownership is reclaimed without signaling a reused pid"

FM_REMOTE_JOB_TIMEOUT=1
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-timeout-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 124 ] || fail "the worker did not terminate an over-time job"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the timed-out job could not be reaped"
pass "the worker enforces the job timeout and publishes its result"

QUEUED_SIDE_EFFECT="$TMP_ROOT/queued-side-effect"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-timeout-job.sh < /dev/null > /dev/null
FIRST_JOB_ID=$FM_REMOTE_JOB_ID
FIRST_JOB_DIR="$STATE_ROOT/jobs/$FIRST_JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the blocking job did not begin running"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-touch-job.sh "$QUEUED_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
printf '%s\n' "$(fm_remote_job_read_deadline "$FIRST_JOB_DIR")" > "$STATE_ROOT/jobs/$JOB_ID/queue_deadline"
fm_remote_job_wait "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 124 ] || fail "an expired queued job did not publish a timeout result"
assert_absent "$QUEUED_SIDE_EFFECT" "the worker executed a queued job after its durable deadline"
fm_remote_job_reap "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "the blocking job could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the expired queued job could not be reaped"
pass "the worker expires queued jobs before they can mutate"

FIRST_DELAYED_SIDE_EFFECT="$TMP_ROOT/first-delayed-side-effect"
SECOND_DELAYED_SIDE_EFFECT="$TMP_ROOT/second-delayed-side-effect"
FM_REMOTE_JOB_QUEUE_TIMEOUT=5
FM_REMOTE_JOB_TIMEOUT=3
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-delay-job.sh 1.8 "$FIRST_DELAYED_SIDE_EFFECT" < /dev/null > /dev/null
FIRST_JOB_ID=$FM_REMOTE_JOB_ID
FIRST_JOB_DIR="$STATE_ROOT/jobs/$FIRST_JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the first delayed job did not begin running"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-delay-job.sh 1.8 "$SECOND_DELAYED_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "queue time consumed the second job's execution timeout"
assert_present "$SECOND_DELAYED_SIDE_EFFECT" "the queued job did not receive its full execution timeout"
fm_remote_job_reap "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "the first delayed job could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the second delayed job could not be reaped"
pass "queued jobs receive a fresh bounded execution window"

if command -v shasum >/dev/null 2>&1; then
  EMPTY_SHA=$(: | shasum -a 256 | awk '{print $1}')
else
  EMPTY_SHA=$(: | sha256sum | awk '{print $1}')
fi
mkdir -p "$REMOTE_HOME/state"
REPLY_LOG_REL=state/parent-replies.status
PREEMPT_SIDE_EFFECT="$TMP_ROOT/preempt-side-effect"
FM_REMOTE_JOB_QUEUE_TIMEOUT=60
FM_REMOTE_JOB_TIMEOUT=40
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-remote-delta-read.sh "$REPLY_LOG_REL" 0 "$EMPTY_SHA" 30 < /dev/null > /dev/null
POLL_JOB_ID=$FM_REMOTE_JOB_ID
POLL_JOB_DIR="$STATE_ROOT/jobs/$POLL_JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$POLL_JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$POLL_JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the long-poll job did not begin running"
PREEMPT_BEGAN=$(date +%s)
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-touch-job.sh "$PREEMPT_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
PREEMPT_ELAPSED=$(( $(date +%s) - PREEMPT_BEGAN ))
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the short command behind a long poll did not complete"
assert_present "$PREEMPT_SIDE_EFFECT" "the short command behind a long poll did not run"
[ "$PREEMPT_ELAPSED" -le 10 ] || fail "a queued short command waited a full poll window behind the long poll"
fm_remote_job_wait "$ACCOUNT_HOME" "$POLL_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq "$FM_REMOTE_JOB_PREEMPTED_EXIT" ] \
  || fail "a preempted long poll was not distinguished from an elapsed window"
[ ! -s "$FM_REMOTE_JOB_STDOUT" ] || fail "a preempted long poll published partial stdout"
[ ! -s "$FM_REMOTE_JOB_STDERR" ] || fail "a preempted long poll published partial stderr"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the short command could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$POLL_JOB_ID" || fail "the preempted poll could not be reaped"
pass "a queued short command preempts a running long poll instead of waiting its window"

printf 'hello after preemption\n' > "$REMOTE_HOME/$REPLY_LOG_REL"
FM_REMOTE_JOB_TIMEOUT=10
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-remote-delta-read.sh "$REPLY_LOG_REL" 0 "$EMPTY_SHA" 5 < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the re-armed poll after preemption did not complete"
OUT=$(<"$FM_REMOTE_JOB_STDOUT")
assert_contains "$OUT" 'status=delta' "the re-armed poll did not return a delta from the preserved cursor"
assert_contains "$OUT" 'hello after preemption' "the re-armed poll lost data appended around the preemption"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the re-armed poll could not be reaped"
rm -f -- "$REMOTE_HOME/$REPLY_LOG_REL"
pass "a poll re-armed after preemption reads the same cursor with nothing lost"

FM_REMOTE_JOB_TIMEOUT=15
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-remote-delta-read.sh "$REPLY_LOG_REL" 0 "$EMPTY_SHA" 6 < /dev/null > /dev/null
FIRST_JOB_ID=$FM_REMOTE_JOB_ID
FIRST_JOB_DIR="$STATE_ROOT/jobs/$FIRST_JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the first sibling poll did not begin running"
POLL_PAIR_BEGAN=$(date +%s)
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-remote-delta-read.sh "$REPLY_LOG_REL" 0 "$EMPTY_SHA" 1 < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
POLL_PAIR_ELAPSED=$(( $(date +%s) - POLL_PAIR_BEGAN ))
[ "$FM_REMOTE_JOB_EXIT" -eq 75 ] || fail "the first sibling poll did not close its own window"
[ "$POLL_PAIR_ELAPSED" -ge 4 ] || fail "a queued sibling poll preempted a running poll"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 75 ] || fail "the queued sibling poll did not run after the first window"
fm_remote_job_reap "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "the first sibling poll could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the queued sibling poll could not be reaped"
FM_REMOTE_JOB_QUEUE_TIMEOUT=5
pass "sibling polls never preempt each other into a re-arm churn loop"

STARTED="$TMP_ROOT/shutdown-started"
SHUTDOWN_SIDE_EFFECT="$TMP_ROOT/shutdown-side-effect"
FM_REMOTE_JOB_TIMEOUT=5
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-shutdown-job.sh "$STARTED" "$SHUTDOWN_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
for _ in $(seq 1 100); do
  [ -f "$STARTED" ] && break
  sleep 0.05
done
assert_present "$STARTED" "the shutdown fixture did not begin executing"
WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
kill -TERM "$WORKER_PID"
for _ in $(seq 1 100); do
  kill -0 "$WORKER_PID" 2>/dev/null || break
  sleep 0.05
done
kill -0 "$WORKER_PID" 2>/dev/null && fail "the worker did not finish its TERM shutdown"
HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_TIMEOUT=1 \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" >> "$TMP_ROOT/worker.out" 2>> "$TMP_ROOT/worker.err" &
for _ in $(seq 1 100); do
  [ -f "$STATE_ROOT/worker.ready" ] && break
  sleep 0.05
done
assert_present "$STATE_ROOT/worker.ready" "the replacement worker did not become ready"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 125 ] || fail "the interrupted job did not publish an unknown-completion result"
sleep 3
assert_absent "$SHUTDOWN_SIDE_EFFECT" "the active command mutated after worker shutdown"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the interrupted job could not be reaped"
pass "worker shutdown terminates the active command tree before replacement"

CRASH_STARTED="$TMP_ROOT/crash-started"
CRASH_SIDE_EFFECT="$TMP_ROOT/crash-side-effect"
FM_REMOTE_JOB_TIMEOUT=5
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-shutdown-job.sh "$CRASH_STARTED" "$CRASH_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
for _ in $(seq 1 100); do
  [ -f "$CRASH_STARTED" ] && break
  sleep 0.05
done
assert_present "$CRASH_STARTED" "the crash fixture did not begin executing"
CRASHED_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
kill -KILL "$CRASHED_WORKER_PID"
for _ in $(seq 1 200); do
  RESTARTED_WORKER_PID=$(cat "$STATE_ROOT/worker.pid" 2>/dev/null || true)
  [ -n "$RESTARTED_WORKER_PID" ] && [ "$RESTARTED_WORKER_PID" != "$CRASHED_WORKER_PID" ] && break
  sleep 0.05
done
[ -n "${RESTARTED_WORKER_PID:-}" ] && [ "$RESTARTED_WORKER_PID" != "$CRASHED_WORKER_PID" ] \
  || fail "the Linux supervisor did not restart a crashed worker"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 125 ] || fail "worker crash recovery did not publish unknown completion"
sleep 3
assert_absent "$CRASH_SIDE_EFFECT" "an orphaned command mutated after worker crash recovery"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the crash-recovered job could not be reaped"
fm_remote_job_probe "$ACCOUNT_HOME" || fail "the restarted worker did not remain ready"
pass "Linux supervision recovers crashes and stops orphaned commands"

mkdir -p "$ACCOUNT_HOME/.local/bin"
PREEXEC_STARTED="$TMP_ROOT/preexecution-started"
PREEXEC_FINISHED="$TMP_ROOT/preexecution-finished"
cat > "$ACCOUNT_HOME/.local/bin/git" <<SH
#!/bin/bash
if [ "\${3:-}" = ls-files ]; then
  printf 'started\n' > "$PREEXEC_STARTED"
  sleep 30
  printf 'finished\n' > "$PREEXEC_FINISHED"
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$ACCOUNT_HOME/.local/bin/git"
FM_REMOTE_JOB_TIMEOUT=3
PREEXEC_BEGAN=$(date +%s)
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-probe-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
PREEXEC_ELAPSED=$(( $(date +%s) - PREEXEC_BEGAN ))
[ "$FM_REMOTE_JOB_EXIT" -eq 124 ] || fail "the pre-execution deadline did not publish a timeout result"
assert_present "$PREEXEC_STARTED" "the pre-execution timeout fixture did not enter tracked-command validation"
assert_absent "$PREEXEC_FINISHED" "tracked-command validation continued after the job timeout"
[ "$PREEXEC_ELAPSED" -le 7 ] || fail "tracked-command validation exceeded the job timeout bound"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the pre-execution timeout leaked output readers or FIFOs"
rm -f -- "$ACCOUNT_HOME/.local/bin/git"
pass "pre-execution validation obeys the job timeout"

fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-output-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 23 ] || fail "bounded output changed the command exit status"
OUTPUT_BYTES=$(LC_ALL=C wc -c < "$FM_REMOTE_JOB_STDOUT" | tr -d ' ')
[ "$OUTPUT_BYTES" -le "$FM_REMOTE_JOB_MAX_BYTES" ] || fail "the worker retained output beyond its byte bound"
ERROR_BYTES=$(LC_ALL=C wc -c < "$FM_REMOTE_JOB_STDERR" | tr -d ' ')
[ "$ERROR_BYTES" -le "$FM_REMOTE_JOB_MAX_BYTES" ] || fail "the worker retained stderr beyond its byte bound"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the bounded-output job could not be reaped"
pass "the worker drains bounded output without changing command results"

SIDE_EFFECT="$TMP_ROOT/side-effect"
WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
fm_remote_job_stop_worker_tree "$WORKER_PID" \
  || fail "the worker tree did not stop before the staged-record tamper"
assert_absent "$STATE_ROOT/worker.pid" "the worker did not clear its pid before the staged-record tamper"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-touch-job.sh "$SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
rm -f -- "$JOB_DIR/argv"
ln -s "$TMP_ROOT/not-an-argv" "$JOB_DIR/argv"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 126 ] || fail "the worker accepted a symlinked argv record"
assert_absent "$SIDE_EFFECT" "the worker executed a job after its argv changed to a symlink"
pass "the worker refuses symlinked job fields before command execution"

QUARANTINE_STARTED="$TMP_ROOT/quarantine-started"
QUARANTINE_SIDE_EFFECT="$TMP_ROOT/quarantine-side-effect"
FM_REMOTE_JOB_TIMEOUT=5
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-shutdown-job.sh "$QUARANTINE_STARTED" "$QUARANTINE_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
for _ in $(seq 1 100); do
  [ -f "$QUARANTINE_STARTED" ] && break
  sleep 0.05
done
assert_present "$QUARANTINE_STARTED" "the quarantine fixture did not begin executing"
GROUP_PID=$(cat "$JOB_DIR/.claim/group")
printf 'invalid\n' > "$JOB_DIR/.claim/group"
WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
kill -TERM "$WORKER_PID"
wait "$WORKER_PID" 2>/dev/null || true
for _ in $(seq 1 100); do
  [ -f "$STATE_ROOT/worker.lock/quarantine" ] && break
  sleep 0.05
done
assert_present "$STATE_ROOT/worker.lock/quarantine" "failed shutdown released worker ownership"
fm_remote_job_probe "$ACCOUNT_HOME" && fail "quarantined worker ownership still reported ready"
set +e
HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" \
  >> "$TMP_ROOT/worker.out" 2>> "$TMP_ROOT/worker.err"
REPLACEMENT_RC=$?
set -e
[ "$REPLACEMENT_RC" -ne 0 ] || fail "a replacement worker ignored quarantined ownership"
assert_present "$STATE_ROOT/worker.lock/quarantine" "a replacement removed quarantined ownership"
kill -KILL -- "-$GROUP_PID" 2>/dev/null || true
sleep 3
assert_absent "$QUARANTINE_SIDE_EFFECT" "the quarantined command mutated after explicit termination"
pass "failed shutdown quarantines ownership against replacement workers"

RECOVERY_HOME="$TMP_ROOT/recovery-account"
RECOVERY_STATE="$TMP_ROOT/recovery-jobs"
RECOVERY_JOB="$RECOVERY_STATE/jobs/job-quarantine"
mkdir -p "$RECOVERY_HOME" "$RECOVERY_STATE/jobs" "$RECOVERY_STATE/logs" \
  "$RECOVERY_STATE/worker.lock" "$RECOVERY_JOB/.claim"
chmod 700 "$RECOVERY_HOME" "$RECOVERY_STATE" "$RECOVERY_STATE/jobs" "$RECOVERY_STATE/logs" \
  "$RECOVERY_STATE/worker.lock" "$RECOVERY_JOB" "$RECOVERY_JOB/.claim"
sleep 20 &
QUARANTINED_PROCESS_PID=$!
sleep 0.01 &
QUARANTINE_OWNER_PID=$!
wait "$QUARANTINE_OWNER_PID" 2>/dev/null || true
printf '%s\n' "$QUARANTINE_OWNER_PID" > "$RECOVERY_STATE/worker.lock/pid"
printf 'stale\n' > "$RECOVERY_STATE/worker.lock/start"
printf 'stale\n' > "$RECOVERY_STATE/worker.lock/command"
printf 'active execution could not be confirmed stopped\n' > "$RECOVERY_STATE/worker.lock/quarantine"
printf 'running\n' > "$RECOVERY_JOB/state"
printf '%s\n' "$QUARANTINE_OWNER_PID" > "$RECOVERY_JOB/.claim/owner"
printf '%s\n' "$QUARANTINED_PROCESS_PID" > "$RECOVERY_JOB/.claim/supervisor"
: > "$RECOVERY_JOB/stdout"
: > "$RECOVERY_JOB/stderr"
chmod 600 "$RECOVERY_STATE/worker.lock"/* "$RECOVERY_JOB/state" "$RECOVERY_JOB/.claim"/* \
  "$RECOVERY_JOB/stdout" "$RECOVERY_JOB/stderr"
touch -t 200001010000 "$RECOVERY_STATE/worker.lock"
set +e
HOME="$RECOVERY_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RECOVERY_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" \
  > "$TMP_ROOT/recovery-refused.out" 2> "$TMP_ROOT/recovery-refused.err"
RECOVERY_REFUSED_RC=$?
set -e
[ "$RECOVERY_REFUSED_RC" -ne 0 ] || fail "quarantine recovery ignored a recorded live process"
assert_present "$RECOVERY_STATE/worker.lock/quarantine" "a live recorded process lost quarantine protection"
printf '%s\n' "$QUARANTINED_PROCESS_PID" > "$RECOVERY_JOB/.claim/owner"
printf 'stale owner identity\n' > "$RECOVERY_JOB/.claim/owner_start"
printf 'stale supervisor identity\n' > "$RECOVERY_JOB/.claim/supervisor_start"
chmod 600 "$RECOVERY_JOB/.claim/owner" "$RECOVERY_JOB/.claim/owner_start" \
  "$RECOVERY_JOB/.claim/supervisor_start"
HOME="$RECOVERY_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RECOVERY_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" \
  > "$TMP_ROOT/recovery-worker.out" 2> "$TMP_ROOT/recovery-worker.err" &
RECOVERY_WORKER_PID=$!
for _ in $(seq 1 300); do
  [ -f "$RECOVERY_STATE/worker.ready" ] && break
  sleep 0.05
done
assert_present "$RECOVERY_STATE/worker.ready" "a reused supervisor pid did not permit worker recovery"
assert_absent "$RECOVERY_STATE/worker.lock/quarantine" "recovered worker retained stale quarantine"
kill -0 "$QUARANTINED_PROCESS_PID" 2>/dev/null \
  || fail "worker recovery signalled a process whose supervisor identity did not match"
kill -TERM "$RECOVERY_WORKER_PID"
wait "$RECOVERY_WORKER_PID" 2>/dev/null || true
RECOVERY_WORKER_PID=
kill "$QUARANTINED_PROCESS_PID" 2>/dev/null || true
wait "$QUARANTINED_PROCESS_PID" 2>/dev/null || true
pass "quarantine recovery refuses unverifiable supervisors and ignores reused pids"

QUARANTINE_SENTINEL='active execution could not be confirmed stopped'

new_staged_quarantine_fixture() { # <name>
  local name=$1
  QUARANTINE_TEST_DIR="$TMP_ROOT/quarantine-$name"
  QUARANTINE_TEST_HOME="$QUARANTINE_TEST_DIR/home"
  QUARANTINE_TEST_STATE="$QUARANTINE_TEST_DIR/state"
  QUARANTINE_TEST_STAGE="$QUARANTINE_TEST_STATE/worker.lock/.quarantine.A1b2C3"
  mkdir -p "$QUARANTINE_TEST_HOME" "$QUARANTINE_TEST_STATE/jobs" \
    "$QUARANTINE_TEST_STATE/logs" "$QUARANTINE_TEST_STATE/worker.lock"
  chmod 700 "$QUARANTINE_TEST_HOME" "$QUARANTINE_TEST_STATE" \
    "$QUARANTINE_TEST_STATE/jobs" "$QUARANTINE_TEST_STATE/logs" \
    "$QUARANTINE_TEST_STATE/worker.lock"
  printf '%s\n' "$QUARANTINE_SENTINEL" > "$QUARANTINE_TEST_STAGE"
  chmod 600 "$QUARANTINE_TEST_STAGE"
  touch -t 200001010000 "$QUARANTINE_TEST_STATE/worker.lock"
}

quarantine_test_identity() { # <path>
  if [ "$(uname -s)" = Darwin ]; then
    stat -f '%u %d %i' "$1"
  else
    stat -c '%u %d %i' -- "$1"
  fi
}

run_staged_quarantine_worker() { # [path]
  local worker_path=${1:-$PATH}
  set +e
  HOME="$QUARANTINE_TEST_HOME" PATH="$worker_path" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
    FM_REMOTE_JOB_STATE_ROOT="$QUARANTINE_TEST_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
    > "$QUARANTINE_TEST_DIR/worker.out" 2> "$QUARANTINE_TEST_DIR/worker.err"
  QUARANTINE_TEST_RC=$?
  set -e
}

start_staged_quarantine_worker() { # [path]
  local worker_path=${1:-$PATH}
  HOME="$QUARANTINE_TEST_HOME" PATH="$worker_path" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
    FM_REMOTE_JOB_STATE_ROOT="$QUARANTINE_TEST_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
    > "$QUARANTINE_TEST_DIR/worker.out" 2> "$QUARANTINE_TEST_DIR/worker.err" &
  QUARANTINE_TEST_WORKER_PID=$!
}

wait_for_quarantine_recovery() {
  local i=0
  while [ "$i" -lt 300 ]; do
    if [ ! -e "$QUARANTINE_TEST_STAGE" ] && [ ! -L "$QUARANTINE_TEST_STAGE" ] \
      && [ ! -e "$QUARANTINE_TEST_STATE/worker.lock/quarantine" ] \
      && [ ! -L "$QUARANTINE_TEST_STATE/worker.lock/quarantine" ]; then
      return 0
    fi
    kill -0 "$QUARANTINE_TEST_WORKER_PID" 2>/dev/null || return 1
    i=$((i + 1))
    sleep 0.05
  done
  return 1
}

stop_quarantine_test_worker() {
  [ -n "$QUARANTINE_TEST_WORKER_PID" ] || return 0
  kill -KILL "$QUARANTINE_TEST_WORKER_PID" 2>/dev/null || true
  wait "$QUARANTINE_TEST_WORKER_PID" 2>/dev/null || true
  QUARANTINE_TEST_WORKER_PID=
}

expect_staged_quarantine_identity_refusal() { # <expected-owner-dir> <description>
  local expected_owner=$1 description=$2 i=0 rc field
  start_staged_quarantine_worker
  while kill -0 "$QUARANTINE_TEST_WORKER_PID" 2>/dev/null; do
    if [ ! -e "$QUARANTINE_TEST_STAGE" ] && [ ! -L "$QUARANTINE_TEST_STAGE" ]; then
      stop_quarantine_test_worker
      fail "$description permitted staged recovery"
    fi
    [ "$i" -lt 100 ] || {
      stop_quarantine_test_worker
      fail "$description did not make the worker refuse ownership"
    }
    i=$((i + 1))
    sleep 0.05
  done
  set +e
  wait "$QUARANTINE_TEST_WORKER_PID" 2>/dev/null
  rc=$?
  set -e
  QUARANTINE_TEST_WORKER_PID=
  expect_code 1 "$rc" "$description returned the wrong ownership-refusal status"
  assert_present "$QUARANTINE_TEST_STAGE" "$description removed quarantine staging"
  assert_absent "$QUARANTINE_TEST_STATE/worker.lock/quarantine" \
    "$description promoted quarantine staging"
  for field in pid start command; do
    cmp -s "$expected_owner/$field" "$QUARANTINE_TEST_STATE/worker.lock/$field" \
      || fail "$description changed the recorded $field identity"
  done
}

new_staged_quarantine_fixture live-owner
sleep 30 &
QUARANTINE_TEST_AUX_PID=$!
printf '%s\n' "$QUARANTINE_TEST_AUX_PID" > "$QUARANTINE_TEST_STATE/worker.lock/pid"
fm_remote_job_process_start "$QUARANTINE_TEST_AUX_PID" > "$QUARANTINE_TEST_STATE/worker.lock/start"
fm_remote_job_process_command "$QUARANTINE_TEST_AUX_PID" > "$QUARANTINE_TEST_STATE/worker.lock/command"
chmod 600 "$QUARANTINE_TEST_STATE/worker.lock/pid" "$QUARANTINE_TEST_STATE/worker.lock/start" \
  "$QUARANTINE_TEST_STATE/worker.lock/command"
run_staged_quarantine_worker
expect_code 1 "$QUARANTINE_TEST_RC" "a completed staging marker displaced its matching live lock owner"
assert_present "$QUARANTINE_TEST_STAGE" \
  "a matching live lock owner lost its staged quarantine protection"
assert_absent "$QUARANTINE_TEST_STATE/worker.lock/quarantine" \
  "a matching live lock owner's staging marker was consumed"
kill -0 "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || fail "staged recovery signalled the matching live lock owner"
kill "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || true
wait "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || true
QUARANTINE_TEST_AUX_PID=
pass "completed quarantine staging preserves a matching live lock owner"

new_staged_quarantine_fixture live-job
QUARANTINE_JOB="$QUARANTINE_TEST_STATE/jobs/job-live-staged-quarantine"
mkdir -p "$QUARANTINE_JOB/.claim"
chmod 700 "$QUARANTINE_JOB" "$QUARANTINE_JOB/.claim"
sleep 30 &
QUARANTINE_TEST_AUX_PID=$!
printf 'running\n' > "$QUARANTINE_JOB/state"
printf '%s\n' "$QUARANTINE_TEST_AUX_PID" > "$QUARANTINE_JOB/.claim/supervisor"
fm_remote_job_process_start "$QUARANTINE_TEST_AUX_PID" > "$QUARANTINE_JOB/.claim/supervisor_start"
chmod 600 "$QUARANTINE_JOB/state" "$QUARANTINE_JOB/.claim/supervisor" \
  "$QUARANTINE_JOB/.claim/supervisor_start"
run_staged_quarantine_worker
expect_code 75 "$QUARANTINE_TEST_RC" "a completed staging marker displaced a matching live job supervisor"
assert_present "$QUARANTINE_TEST_STATE/worker.lock/quarantine" \
  "a matching live job supervisor lost the published quarantine protection"
kill -0 "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || fail "staged recovery signalled the live job supervisor"
kill "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || true
wait "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || true
QUARANTINE_TEST_AUX_PID=
pass "completed quarantine staging enters the existing live-job safety checks"

new_staged_quarantine_fixture reused-owner-pid
sleep 30 &
QUARANTINE_TEST_AUX_PID=$!
printf '%s\n' "$QUARANTINE_TEST_AUX_PID" > "$QUARANTINE_TEST_STATE/worker.lock/pid"
printf 'stale process start identity\n' > "$QUARANTINE_TEST_STATE/worker.lock/start"
fm_remote_job_process_command "$QUARANTINE_TEST_AUX_PID" > "$QUARANTINE_TEST_STATE/worker.lock/command"
chmod 600 "$QUARANTINE_TEST_STATE/worker.lock/pid" "$QUARANTINE_TEST_STATE/worker.lock/start" \
  "$QUARANTINE_TEST_STATE/worker.lock/command"
start_staged_quarantine_worker
wait_for_quarantine_recovery || fail "a reused owner pid prevented exact staged-quarantine promotion"
kill -0 "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || fail "staged recovery signalled a reused owner pid"
stop_quarantine_test_worker
kill "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || true
wait "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || true
QUARANTINE_TEST_AUX_PID=
pass "staged quarantine recovery distinguishes pid reuse by process start identity"

new_staged_quarantine_fixture dead-owner-malformed-command
sleep 30 &
QUARANTINE_TEST_AUX_PID=$!
printf '%s\n' "$QUARANTINE_TEST_AUX_PID" > "$QUARANTINE_TEST_STATE/worker.lock/pid"
fm_remote_job_process_start "$QUARANTINE_TEST_AUX_PID" > "$QUARANTINE_TEST_STATE/worker.lock/start"
: > "$QUARANTINE_TEST_STATE/worker.lock/command"
chmod 600 "$QUARANTINE_TEST_STATE/worker.lock/pid" "$QUARANTINE_TEST_STATE/worker.lock/start" \
  "$QUARANTINE_TEST_STATE/worker.lock/command"
kill "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || true
wait "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || true
QUARANTINE_TEST_AUX_PID=
DEAD_OWNER_EXPECTED="$QUARANTINE_TEST_DIR/expected-owner"
mkdir -p "$DEAD_OWNER_EXPECTED"
cp "$QUARANTINE_TEST_STATE/worker.lock/pid" "$QUARANTINE_TEST_STATE/worker.lock/start" \
  "$QUARANTINE_TEST_STATE/worker.lock/command" "$DEAD_OWNER_EXPECTED/"
expect_staged_quarantine_identity_refusal "$DEAD_OWNER_EXPECTED" \
  "a dead owner with an empty command identity"
pass "completed quarantine staging refuses malformed dead-owner identity"

new_staged_quarantine_fixture reused-owner-malformed-command
sleep 30 &
QUARANTINE_TEST_AUX_PID=$!
printf '%s\n' "$QUARANTINE_TEST_AUX_PID" > "$QUARANTINE_TEST_STATE/worker.lock/pid"
printf 'stale process start identity\n' > "$QUARANTINE_TEST_STATE/worker.lock/start"
printf 'first command line\nsecond command line\n' > "$QUARANTINE_TEST_STATE/worker.lock/command"
chmod 600 "$QUARANTINE_TEST_STATE/worker.lock/pid" "$QUARANTINE_TEST_STATE/worker.lock/start" \
  "$QUARANTINE_TEST_STATE/worker.lock/command"
REUSED_OWNER_EXPECTED="$QUARANTINE_TEST_DIR/expected-owner"
mkdir -p "$REUSED_OWNER_EXPECTED"
cp "$QUARANTINE_TEST_STATE/worker.lock/pid" "$QUARANTINE_TEST_STATE/worker.lock/start" \
  "$QUARANTINE_TEST_STATE/worker.lock/command" "$REUSED_OWNER_EXPECTED/"
expect_staged_quarantine_identity_refusal "$REUSED_OWNER_EXPECTED" \
  "a reused owner pid with a multiline command identity"
kill -0 "$QUARANTINE_TEST_AUX_PID" 2>/dev/null \
  || fail "staged recovery signalled a reused pid with malformed owner identity"
kill "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || true
wait "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || true
QUARANTINE_TEST_AUX_PID=
pass "completed quarantine staging refuses malformed reused-owner identity"

new_staged_quarantine_fixture live-legacy-worker
LEGACY_WORKER="$QUARANTINE_TEST_DIR/fm-remote-job-worker.sh"
cat > "$LEGACY_WORKER" <<'SH'
#!/bin/bash
sleep 30
SH
chmod +x "$LEGACY_WORKER"
"$LEGACY_WORKER" &
QUARANTINE_TEST_AUX_PID=$!
printf '%s\n' "$QUARANTINE_TEST_AUX_PID" > "$QUARANTINE_TEST_STATE/worker.pid"
chmod 600 "$QUARANTINE_TEST_STATE/worker.pid"
run_staged_quarantine_worker
expect_code 1 "$QUARANTINE_TEST_RC" "a completed staging marker displaced a live legacy worker"
assert_present "$QUARANTINE_TEST_STAGE" "a live legacy worker lost its staged quarantine protection"
kill -0 "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || fail "staged recovery signalled a live legacy worker"
kill "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || true
wait "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || true
QUARANTINE_TEST_AUX_PID=
pass "completed quarantine staging refuses a live legacy worker"

new_staged_quarantine_fixture wrong-content
printf 'not the quarantine sentinel\n' > "$QUARANTINE_TEST_STAGE"
run_staged_quarantine_worker
expect_code 1 "$QUARANTINE_TEST_RC" "a wrong-content quarantine staging file was recovered"
assert_present "$QUARANTINE_TEST_STAGE" "wrong-content quarantine staging was removed"

new_staged_quarantine_fixture wrong-mode
chmod 640 "$QUARANTINE_TEST_STAGE"
run_staged_quarantine_worker
expect_code 1 "$QUARANTINE_TEST_RC" "a wrong-mode quarantine staging file was recovered"
assert_present "$QUARANTINE_TEST_STAGE" "wrong-mode quarantine staging was removed"

for SPECIAL_MODE_CASE in lock-sticky:1700 lock-setgid:2700 marker-setuid:4600; do
  SPECIAL_MODE_NAME=${SPECIAL_MODE_CASE%%:*}
  SPECIAL_MODE=${SPECIAL_MODE_CASE##*:}
  new_staged_quarantine_fixture "special-mode-$SPECIAL_MODE_NAME"
  case "$SPECIAL_MODE_NAME" in
    lock-*) chmod "$SPECIAL_MODE" "$QUARANTINE_TEST_STATE/worker.lock" ;;
    marker-*) chmod "$SPECIAL_MODE" "$QUARANTINE_TEST_STAGE" ;;
  esac
  run_staged_quarantine_worker
  expect_code 1 "$QUARANTINE_TEST_RC" \
    "a $SPECIAL_MODE_NAME quarantine staging fixture was recovered"
  assert_present "$QUARANTINE_TEST_STAGE" \
    "the $SPECIAL_MODE_NAME quarantine staging fixture was removed"
done
pass "quarantine staging requires exact modes including special permission bits"

new_staged_quarantine_fixture changed-after-validation
MUTATE_FAKEBIN="$QUARANTINE_TEST_DIR/fakebin"
mkdir -p "$MUTATE_FAKEBIN"
REAL_MV=$(command -v mv)
cat > "$MUTATE_FAKEBIN/mv" <<'SH'
#!/bin/bash
last=${!#}
case "$last" in
  */worker.lock/quarantine) printf X >&9 ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
chmod +x "$MUTATE_FAKEBIN/mv"
export FM_TEST_REAL_MV="$REAL_MV"
STAGED_IDENTITY=$(quarantine_test_identity "$QUARANTINE_TEST_STAGE")
exec 9<> "$QUARANTINE_TEST_STAGE"
run_staged_quarantine_worker "$MUTATE_FAKEBIN:$PATH"
exec 9>&-
unset FM_TEST_REAL_MV
expect_code 1 "$QUARANTINE_TEST_RC" \
  "in-place staging content change after validation was recovered"
assert_absent "$QUARANTINE_TEST_STAGE" \
  "in-place changed quarantine staging was not atomically promoted"
assert_present "$QUARANTINE_TEST_STATE/worker.lock/quarantine" \
  "in-place changed promoted quarantine marker was deleted"
[ "$(quarantine_test_identity "$QUARANTINE_TEST_STATE/worker.lock/quarantine")" = "$STAGED_IDENTITY" ] \
  || fail "in-place changed quarantine marker lost its original object identity"
cmp -s "$QUARANTINE_TEST_STATE/worker.lock/quarantine" <(printf '%s\n' "$QUARANTINE_SENTINEL") \
  && fail "the in-place quarantine content change did not occur"
pass "promoted quarantine content is revalidated before recovery"

new_staged_quarantine_fixture symlink
printf '%s\n' "$QUARANTINE_SENTINEL" > "$QUARANTINE_TEST_STATE/symlink-target"
rm -f "$QUARANTINE_TEST_STAGE"
ln -s "$QUARANTINE_TEST_STATE/symlink-target" "$QUARANTINE_TEST_STAGE"
run_staged_quarantine_worker
expect_code 1 "$QUARANTINE_TEST_RC" "a symlinked quarantine staging file was recovered"
[ -L "$QUARANTINE_TEST_STAGE" ] || fail "symlinked quarantine staging was removed"

new_staged_quarantine_fixture multiple
printf '%s\n' "$QUARANTINE_SENTINEL" > "$QUARANTINE_TEST_STATE/worker.lock/.quarantine.D4e5F6"
chmod 600 "$QUARANTINE_TEST_STATE/worker.lock/.quarantine.D4e5F6"
run_staged_quarantine_worker
expect_code 1 "$QUARANTINE_TEST_RC" "multiple quarantine staging files were recovered ambiguously"
assert_present "$QUARANTINE_TEST_STAGE" "ambiguous quarantine staging was removed"

new_staged_quarantine_fixture unexpected-entry
printf 'unknown\n' > "$QUARANTINE_TEST_STATE/worker.lock/mystery"
chmod 600 "$QUARANTINE_TEST_STATE/worker.lock/mystery"
run_staged_quarantine_worker
expect_code 1 "$QUARANTINE_TEST_RC" "quarantine staging with an unknown lock entry was recovered"
assert_present "$QUARANTINE_TEST_STAGE" "quarantine staging beside an unknown entry was removed"

new_staged_quarantine_fixture malformed-name
mv "$QUARANTINE_TEST_STAGE" "$QUARANTINE_TEST_STATE/worker.lock/.quarantine.short"
touch -t 200001010000 "$QUARANTINE_TEST_STATE/worker.lock"
run_staged_quarantine_worker
expect_code 1 "$QUARANTINE_TEST_RC" "a malformed quarantine staging name was recovered"
assert_present "$QUARANTINE_TEST_STATE/worker.lock/.quarantine.short" \
  "malformed quarantine staging was removed"

new_staged_quarantine_fixture malformed-name-with-stale-owner
QUARANTINE_TEST_STAGE="$QUARANTINE_TEST_STATE/worker.lock/.quarantine.short"
mv "$QUARANTINE_TEST_STATE/worker.lock/.quarantine.A1b2C3" "$QUARANTINE_TEST_STAGE"
sleep 30 &
QUARANTINE_TEST_AUX_PID=$!
printf '%s\n' "$QUARANTINE_TEST_AUX_PID" > "$QUARANTINE_TEST_STATE/worker.lock/pid"
fm_remote_job_process_start "$QUARANTINE_TEST_AUX_PID" > "$QUARANTINE_TEST_STATE/worker.lock/start"
fm_remote_job_process_command "$QUARANTINE_TEST_AUX_PID" > "$QUARANTINE_TEST_STATE/worker.lock/command"
chmod 600 "$QUARANTINE_TEST_STATE/worker.lock/pid" "$QUARANTINE_TEST_STATE/worker.lock/start" \
  "$QUARANTINE_TEST_STATE/worker.lock/command"
kill "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || true
wait "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || true
QUARANTINE_TEST_AUX_PID=
MALFORMED_STALE_EXPECTED="$QUARANTINE_TEST_DIR/expected-lock"
mkdir -p "$MALFORMED_STALE_EXPECTED"
cp "$QUARANTINE_TEST_STATE/worker.lock/pid" "$QUARANTINE_TEST_STATE/worker.lock/start" \
  "$QUARANTINE_TEST_STATE/worker.lock/command" "$QUARANTINE_TEST_STAGE" \
  "$MALFORMED_STALE_EXPECTED/"
touch -t 200001010000 "$QUARANTINE_TEST_STATE/worker.lock"
expect_staged_quarantine_identity_refusal "$MALFORMED_STALE_EXPECTED" \
  "a malformed staging name beside a stale owner identity"
cmp -s "$MALFORMED_STALE_EXPECTED/.quarantine.short" "$QUARANTINE_TEST_STAGE" \
  || fail "malformed staging refusal changed the malformed entry"
pass "malformed staging preserves stale owner records and the unknown entry"

INHERITED_SHOPT_ENV="$QUARANTINE_TEST_DIR/inherited-shopt"
printf 'shopt -s nocasematch\n' > "$INHERITED_SHOPT_ENV"
new_staged_quarantine_fixture inherited-nocasematch
mv "$QUARANTINE_TEST_STAGE" "$QUARANTINE_TEST_STATE/worker.lock/.QUARANTINE.A1b2C3"
QUARANTINE_TEST_STAGE="$QUARANTINE_TEST_STATE/worker.lock/.QUARANTINE.A1b2C3"
touch -t 200001010000 "$QUARANTINE_TEST_STATE/worker.lock"
export BASH_ENV=$INHERITED_SHOPT_ENV
run_staged_quarantine_worker
unset BASH_ENV
expect_code 1 "$QUARANTINE_TEST_RC" \
  "nocasematch made a malformed quarantine prefix recoverable"
assert_present "$QUARANTINE_TEST_STAGE" \
  "nocasematch allowed malformed quarantine staging to be removed"

INHERITED_SHOPT_ENV="$QUARANTINE_TEST_DIR/inherited-shopt"
printf '%s\n' 'shopt -s dotglob failglob nocaseglob nocasematch nullglob' \
  "GLOBIGNORE='*:.*'" > "$INHERITED_SHOPT_ENV"
new_staged_quarantine_fixture inherited-glob-options
export BASH_ENV=$INHERITED_SHOPT_ENV
start_staged_quarantine_worker
unset BASH_ENV
wait_for_quarantine_recovery \
  || fail "inherited glob options prevented exact staged-quarantine recovery"
stop_quarantine_test_worker
pass "quarantine staging classification is independent of inherited shell options"

LOCALE_RANGE_TEST_SHELL=(bash)
if bash -c 'shopt -u globasciiranges' >/dev/null 2>&1; then
  LOCALE_RANGE_TEST_SHELL=(bash +O globasciiranges)
fi
LOCALE_RANGE_TEST_LOCALE=$(
  # candidate expands in the nested shell, not this test process.
  # shellcheck disable=SC2016
  "${LOCALE_RANGE_TEST_SHELL[@]}" -c '
    while IFS= read -r candidate; do
      LC_ALL=$candidate
      export LC_ALL
      case é in [A-Za-z0-9]) printf "%s\n" "$candidate"; exit 0 ;; esac
    done
    exit 1
  ' < <(locale -a 2>/dev/null)
) || LOCALE_RANGE_TEST_LOCALE=
if [ -n "$LOCALE_RANGE_TEST_LOCALE" ]; then
  new_staged_quarantine_fixture locale-expanded-name
  LOCALE_EXPANDED_STAGE="$QUARANTINE_TEST_STATE/worker.lock/.quarantine.é12345"
  mv "$QUARANTINE_TEST_STAGE" "$LOCALE_EXPANDED_STAGE"
  QUARANTINE_TEST_STAGE=$LOCALE_EXPANDED_STAGE
  touch -t 200001010000 "$QUARANTINE_TEST_STATE/worker.lock"
  set +e
  HOME="$QUARANTINE_TEST_HOME" PATH="$PATH" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
    FM_REMOTE_JOB_STATE_ROOT="$QUARANTINE_TEST_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    LC_ALL="$LOCALE_RANGE_TEST_LOCALE" "${LOCALE_RANGE_TEST_SHELL[@]}" \
    "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
    > "$QUARANTINE_TEST_DIR/worker.out" 2> "$QUARANTINE_TEST_DIR/worker.err"
  QUARANTINE_TEST_RC=$?
  set -e
  expect_code 1 "$QUARANTINE_TEST_RC" \
    "a locale-expanded malformed quarantine staging name was recovered"
  assert_present "$QUARANTINE_TEST_STAGE" \
    "locale-expanded malformed quarantine staging was removed"
  pass "locale-expanded malformed quarantine staging remains untouched"
else
  pass "skipped: no installed locale expands the quarantine suffix range"
fi

new_staged_quarantine_fixture conflicting-official
printf '%s\n' "$QUARANTINE_SENTINEL" > "$QUARANTINE_TEST_STATE/worker.lock/quarantine"
chmod 600 "$QUARANTINE_TEST_STATE/worker.lock/quarantine"
run_staged_quarantine_worker
expect_code 1 "$QUARANTINE_TEST_RC" "conflicting official and staged quarantine markers were recovered"
assert_present "$QUARANTINE_TEST_STAGE" "a conflicting official marker displaced quarantine staging"
assert_present "$QUARANTINE_TEST_STATE/worker.lock/quarantine" \
  "staged quarantine recovery removed a conflicting official marker"
cmp -s "$QUARANTINE_TEST_STAGE" <(printf '%s\n' "$QUARANTINE_SENTINEL") \
  || fail "a conflicting staged quarantine marker changed"
cmp -s "$QUARANTINE_TEST_STATE/worker.lock/quarantine" <(printf '%s\n' "$QUARANTINE_SENTINEL") \
  || fail "a conflicting official quarantine marker changed"
pass "conflicting official and staged quarantine markers remain untouched"

new_staged_quarantine_fixture ambiguous-owner
sleep 30 &
QUARANTINE_TEST_AUX_PID=$!
printf '%s\n' "$QUARANTINE_TEST_AUX_PID" > "$QUARANTINE_TEST_STATE/worker.lock/pid"
chmod 600 "$QUARANTINE_TEST_STATE/worker.lock/pid"
run_staged_quarantine_worker
expect_code 1 "$QUARANTINE_TEST_RC" "a partial live owner identity permitted staged recovery"
assert_present "$QUARANTINE_TEST_STAGE" "ambiguous live ownership lost quarantine staging"
kill "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || true
wait "$QUARANTINE_TEST_AUX_PID" 2>/dev/null || true
QUARANTINE_TEST_AUX_PID=

new_staged_quarantine_fixture wrong-owner
WRONG_OWNER_BIN="$QUARANTINE_TEST_DIR/fakebin"
mkdir -p "$WRONG_OWNER_BIN"
REAL_STAT=$(command -v stat)
cat > "$WRONG_OWNER_BIN/stat" <<'SH'
#!/bin/bash
last=${!#}
case "$last" in
  */worker.lock/.quarantine.A1b2C3)
    value=$("$FM_TEST_REAL_STAT" "$@") || exit 1
    read -r _ mode device inode extra <<< "$value"
    [ -z "${extra:-}" ] || exit 1
    printf '%s %s %s %s\n' "$FM_TEST_OTHER_UID" "$mode" "$device" "$inode"
    exit 0
    ;;
esac
exec "$FM_TEST_REAL_STAT" "$@"
SH
chmod +x "$WRONG_OWNER_BIN/stat"
export FM_TEST_REAL_STAT="$REAL_STAT"
export FM_TEST_OTHER_UID="$(( $(id -u) + 1 ))"
run_staged_quarantine_worker "$WRONG_OWNER_BIN:$PATH"
unset FM_TEST_REAL_STAT FM_TEST_OTHER_UID
expect_code 1 "$QUARANTINE_TEST_RC" "a foreign-owner quarantine staging file was recovered"
assert_present "$QUARANTINE_TEST_STAGE" "foreign-owner quarantine staging was removed"
pass "malformed, ambiguous, symlinked, and foreign quarantine staging remains untouched"

PUBLISH_FAKEBIN="$TMP_ROOT/quarantine-publish-fakebin"
mkdir -p "$PUBLISH_FAKEBIN"
REAL_CHMOD=$(command -v chmod)
REAL_MV=$(command -v mv)
cat > "$PUBLISH_FAKEBIN/chmod" <<'SH'
#!/bin/bash
last=${!#}
case "${FM_TEST_QUARANTINE_PUBLISH_ACTION:-}:$last" in
  chmod:*/worker.lock/.quarantine.??????)
    printf 'chmod: No space left on device\n' >&2
    exit 1
    ;;
esac
exec "$FM_TEST_REAL_CHMOD" "$@"
SH
cat > "$PUBLISH_FAKEBIN/mv" <<'SH'
#!/bin/bash
last=${!#}
case "${FM_TEST_QUARANTINE_PUBLISH_ACTION:-}:$last" in
  mv:*/worker.lock/quarantine)
    printf 'mv: No space left on device\n' >&2
    exit 1
    ;;
  crash:*/worker.lock/quarantine)
    kill -KILL "$PPID" 2>/dev/null || true
    sleep 0.1
    exit 1
    ;;
  race:*/worker.lock/quarantine)
    : > "$FM_TEST_RACE_READY"
    while [ ! -e "$FM_TEST_RACE_RELEASE" ]; do sleep 0.01; done
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
chmod +x "$PUBLISH_FAKEBIN/chmod" "$PUBLISH_FAKEBIN/mv"
export FM_TEST_REAL_CHMOD="$REAL_CHMOD"
export FM_TEST_REAL_MV="$REAL_MV"

new_staged_quarantine_fixture live-publisher-race
rm -rf "$QUARANTINE_TEST_STATE/worker.lock"
FM_TEST_RACE_READY="$QUARANTINE_TEST_DIR/publisher-ready"
FM_TEST_RACE_RELEASE="$QUARANTINE_TEST_DIR/publisher-release"
export FM_TEST_RACE_READY FM_TEST_RACE_RELEASE
export FM_TEST_QUARANTINE_PUBLISH_ACTION=race
start_staged_quarantine_worker "$PUBLISH_FAKEBIN:$PATH"
for _ in $(seq 1 300); do
  [ -f "$QUARANTINE_TEST_STATE/worker.ready" ] && break
  sleep 0.05
done
assert_present "$QUARANTINE_TEST_STATE/worker.ready" \
  "the live-publisher race worker did not become ready"
kill -TERM "$QUARANTINE_TEST_WORKER_PID"
for _ in $(seq 1 300); do
  [ -f "$FM_TEST_RACE_READY" ] && break
  sleep 0.05
done
assert_present "$FM_TEST_RACE_READY" \
  "the live publisher did not reach completed quarantine staging"
QUARANTINE_TEST_STAGE=$(find "$QUARANTINE_TEST_STATE/worker.lock" -maxdepth 1 \
  -name '.quarantine.??????' -print)
[ -n "$QUARANTINE_TEST_STAGE" ] \
  || fail "the live publisher did not retain its completed staging marker"
run_staged_quarantine_worker
expect_code 1 "$QUARANTINE_TEST_RC" \
  "a replacement consumed an active publisher's quarantine staging"
assert_present "$QUARANTINE_TEST_STAGE" \
  "a replacement removed an active publisher's quarantine staging"
assert_absent "$QUARANTINE_TEST_STATE/worker.lock/quarantine" \
  "a replacement promoted an active publisher's quarantine staging"
kill -0 "$QUARANTINE_TEST_WORKER_PID" 2>/dev/null \
  || fail "a replacement disturbed the active quarantine publisher"
: > "$FM_TEST_RACE_RELEASE"
wait "$QUARANTINE_TEST_WORKER_PID" \
  || fail "the active quarantine publisher did not finish shutdown"
QUARANTINE_TEST_WORKER_PID=
unset FM_TEST_QUARANTINE_PUBLISH_ACTION FM_TEST_RACE_READY FM_TEST_RACE_RELEASE
assert_absent "$QUARANTINE_TEST_STATE/worker.lock" \
  "the active quarantine publisher did not release ownership"
pass "a replacement preserves an active publisher's quarantine staging"

for PUBLISH_FAILURE in chmod mv; do
  new_staged_quarantine_fixture "publish-$PUBLISH_FAILURE"
  rm -rf "$QUARANTINE_TEST_STATE/worker.lock"
  export FM_TEST_QUARANTINE_PUBLISH_ACTION=$PUBLISH_FAILURE
  start_staged_quarantine_worker "$PUBLISH_FAKEBIN:$PATH"
  for _ in $(seq 1 300); do
    [ -f "$QUARANTINE_TEST_STATE/worker.ready" ] && break
    sleep 0.05
  done
  assert_present "$QUARANTINE_TEST_STATE/worker.ready" \
    "the $PUBLISH_FAILURE publication-failure worker did not become ready"
  printf 'preserve\n' > "$QUARANTINE_TEST_STATE/worker.lock/keep"
  chmod 600 "$QUARANTINE_TEST_STATE/worker.lock/keep"
  kill -TERM "$QUARANTINE_TEST_WORKER_PID"
  for _ in $(seq 1 100); do
    grep -F 'cannot guard worker ownership for shutdown' "$QUARANTINE_TEST_DIR/worker.err" >/dev/null 2>&1 && break
    sleep 0.05
  done
  assert_grep 'cannot guard worker ownership for shutdown' "$QUARANTINE_TEST_DIR/worker.err" \
    "the $PUBLISH_FAILURE publication failure was not reported"
  [ "$(find "$QUARANTINE_TEST_STATE/worker.lock" -maxdepth 1 -name '.quarantine.??????' | wc -l | tr -d ' ')" -eq 0 ] \
    || fail "the $PUBLISH_FAILURE publication failure retained its temporary artifact"
  assert_present "$QUARANTINE_TEST_STATE/worker.lock/keep" \
    "the $PUBLISH_FAILURE publication failure removed an unrelated lock artifact"
  stop_quarantine_test_worker
done
unset FM_TEST_QUARANTINE_PUBLISH_ACTION
pass "reported chmod and ENOSPC rename failures clean only their publisher temporary artifact"

new_staged_quarantine_fixture interrupted-publication
rm -rf "$QUARANTINE_TEST_STATE/worker.lock"
export FM_TEST_QUARANTINE_PUBLISH_ACTION=crash
start_staged_quarantine_worker "$PUBLISH_FAKEBIN:$PATH"
for _ in $(seq 1 300); do
  [ -f "$QUARANTINE_TEST_STATE/worker.ready" ] && break
  sleep 0.05
done
assert_present "$QUARANTINE_TEST_STATE/worker.ready" "the interrupted-publication worker did not become ready"
kill -TERM "$QUARANTINE_TEST_WORKER_PID"
wait "$QUARANTINE_TEST_WORKER_PID" 2>/dev/null || true
QUARANTINE_TEST_WORKER_PID=
unset FM_TEST_QUARANTINE_PUBLISH_ACTION
INTERRUPTED_STAGE=$(find "$QUARANTINE_TEST_STATE/worker.lock" -maxdepth 1 -name '.quarantine.??????' -print)
[ -n "$INTERRUPTED_STAGE" ] && [ "$(printf '%s\n' "$INTERRUPTED_STAGE" | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "the interruption did not leave one completed quarantine staging artifact"
cmp -s "$INTERRUPTED_STAGE" <(printf '%s\n' "$QUARANTINE_SENTINEL") \
  || fail "the interrupted quarantine staging artifact was incomplete"
QUARANTINE_TEST_STAGE=$INTERRUPTED_STAGE
start_staged_quarantine_worker
wait_for_quarantine_recovery || fail "a worker could not safely recover interrupted quarantine publication"
stop_quarantine_test_worker
pass "the next worker safely recovers interruption between staging and quarantine publication"

unset FM_TEST_REAL_CHMOD FM_TEST_REAL_MV

new_staged_quarantine_fixture doctor-recovery
DOCTOR_BIN="$QUARANTINE_TEST_HOME/.local/bin"
DOCTOR_FM_HOME="$QUARANTINE_TEST_HOME/project-home"
mkdir -p "$DOCTOR_BIN" "$DOCTOR_FM_HOME"
ln -s "$(command -v git)" "$DOCTOR_BIN/git"
ln -s "$(command -v jq)" "$DOCTOR_BIN/jq"
cat > "$DOCTOR_BIN/herdr" <<'SH'
#!/bin/bash
case "${1:-}:${2:-}" in
  status:--json) printf '{"client":{"version":"test","protocol":16},"server":{"running":true}}\n' ;;
esac
SH
cat > "$DOCTOR_BIN/tasks-axi" <<'SH'
#!/bin/bash
case "${1:-}:${2:-}" in
  --version:*) printf '0.2.4\n' ;;
  update:--help) printf '%s\n' --archive-body ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]' ;;
esac
SH
for tool in treehouse claude; do
  cat > "$DOCTOR_BIN/$tool" <<'SH'
#!/bin/bash
exit 0
SH
done
chmod +x "$DOCTOR_BIN/herdr" "$DOCTOR_BIN/tasks-axi" "$DOCTOR_BIN/treehouse" "$DOCTOR_BIN/claude"
set +e
DOCTOR_CHECK_OUT=$(
  HOME="$QUARANTINE_TEST_HOME" FM_HOME="$DOCTOR_FM_HOME" \
    PATH="$ROOT/bin:$DOCTOR_BIN:/usr/bin:/bin:/usr/sbin:/sbin" FM_ROOT_OVERRIDE="$ROOT" \
    FM_REMOTE_JOB_STATE_ROOT="$QUARANTINE_TEST_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    "$ROOT/bin/fm-remote-doctor.sh" 2>&1
)
DOCTOR_CHECK_RC=$?
set -e
expect_code 1 "$DOCTOR_CHECK_RC" \
  "read-only doctor unexpectedly accepted interrupted quarantine publication: $DOCTOR_CHECK_OUT"
assert_contains "$DOCTOR_CHECK_OUT" \
  'check remote-job-probe=fixable: the remote job worker has not reported a fresh probe' \
  "read-only doctor did not report the missing fresh worker probe"
assert_present "$QUARANTINE_TEST_STAGE" "read-only doctor removed quarantine staging"
assert_absent "$QUARANTINE_TEST_STATE/worker.lock/quarantine" \
  "read-only doctor promoted quarantine staging"

set +e
DOCTOR_RECOVERY_OUT=$(
  HOME="$QUARANTINE_TEST_HOME" FM_HOME="$DOCTOR_FM_HOME" \
    PATH="$ROOT/bin:$DOCTOR_BIN:/usr/bin:/bin:/usr/sbin:/sbin" FM_ROOT_OVERRIDE="$ROOT" \
    FM_REMOTE_JOB_STATE_ROOT="$QUARANTINE_TEST_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    "$ROOT/bin/fm-remote-doctor.sh" --fix 2>&1
)
DOCTOR_RECOVERY_RC=$?
set -e
expect_code 0 "$DOCTOR_RECOVERY_RC" \
  "the supported doctor did not recover one exact completed quarantine staging marker: $DOCTOR_RECOVERY_OUT"
assert_contains "$DOCTOR_RECOVERY_OUT" \
  'check remote-job-probe=ok: the remote job worker completed the required-tool probe' \
  "the recovered doctor did not complete a fresh worker tool probe"
assert_absent "$QUARANTINE_TEST_STATE/worker.lock/quarantine" \
  "the successful doctor probe retained the official quarantine marker"
[ "$(find "$QUARANTINE_TEST_STATE/worker.lock" -maxdepth 1 -name '.quarantine.??????' | wc -l | tr -d ' ')" -eq 0 ] \
  || fail "the successful doctor probe retained quarantine staging"
QUARANTINE_TEST_WORKER_PID=$(cat "$QUARANTINE_TEST_STATE/worker.pid")
fm_remote_job_stop_worker_tree "$QUARANTINE_TEST_WORKER_PID" \
  || fail "the doctor-recovery worker did not stop cleanly"
QUARANTINE_TEST_WORKER_PID=
pass "the supported doctor reaches a fresh required-tool probe after safe staged-quarantine recovery"

# A replacement stops a Linux worker by signalling its whole isolated group, and
# the supervisor in that group forwards a second stop signal to the same serving
# child, so the serving child is always signalled more than once. Signal a small
# bounded burst and then keep signalling until it is gone: the first signal
# starts the shutdown and every later one lands inside it, the same way the group
# signal and the forwarded signal do. A shutdown that dies part way through
# leaves its ownership lock behind holding a half-written temp file no later
# worker can clear, and every replacement then fails to report ready.
#
# The burst is bounded and the follow-up signals are paced deliberately. An
# unpaced signal loop delivers hundreds of thousands of signals per second,
# which corrupts the signalled bash's own pending-trap bookkeeping ("warning:
# run_pending_traps: bad value in trap_list[15]") and then kills it part way
# through the shutdown with SIGTERM or SIGSEGV. That reports a shutdown defect
# this worker does not have. Ten back-to-back signals still all land inside the
# shutdown's first file operation, so the repeat this pins is unchanged: with
# the default disposition restored instead of ignored, the ownership lock is
# left behind every run.
REPEAT_HOME="$TMP_ROOT/repeat-signal-account"
REPEAT_STATE="$TMP_ROOT/repeat-signal-jobs"
mkdir -p "$REPEAT_HOME"
chmod 700 "$REPEAT_HOME"
HOME="$REPEAT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$REPEAT_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/repeat-signal.out" 2> "$TMP_ROOT/repeat-signal.err" &
REPEAT_WORKER_PID=$!
for _ in $(seq 1 300); do
  [ -f "$REPEAT_STATE/worker.ready" ] && break
  sleep 0.05
done
assert_present "$REPEAT_STATE/worker.ready" "the repeated-signal worker did not become ready"
REPEAT_DEADLINE=$((SECONDS + 30))
REPEAT_BURST=0
while [ "$REPEAT_BURST" -lt 10 ]; do
  kill -TERM "$REPEAT_WORKER_PID" 2>/dev/null || true
  REPEAT_BURST=$((REPEAT_BURST + 1))
done
while kill -0 "$REPEAT_WORKER_PID" 2>/dev/null && [ "$SECONDS" -lt "$REPEAT_DEADLINE" ]; do
  kill -TERM "$REPEAT_WORKER_PID" 2>/dev/null || true
  sleep 0.05
done
if kill -0 "$REPEAT_WORKER_PID" 2>/dev/null; then
  kill -KILL "$REPEAT_WORKER_PID" 2>/dev/null || true
  wait "$REPEAT_WORKER_PID" 2>/dev/null || true
  REPEAT_WORKER_PID=
  fail "the repeatedly signalled worker never finished its shutdown"
fi
wait "$REPEAT_WORKER_PID" 2>/dev/null || true
REPEAT_WORKER_PID=
assert_absent "$REPEAT_STATE/worker.lock" \
  "a repeatedly signalled shutdown left its ownership lock behind"
assert_absent "$REPEAT_STATE/worker.ready" \
  "a repeatedly signalled shutdown left its readiness heartbeat behind"
HOME="$REPEAT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$REPEAT_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  >> "$TMP_ROOT/repeat-signal.out" 2>> "$TMP_ROOT/repeat-signal.err" &
REPEAT_WORKER_PID=$!
for _ in $(seq 1 600); do
  [ -f "$REPEAT_STATE/worker.ready" ] && break
  sleep 0.05
done
assert_present "$REPEAT_STATE/worker.ready" \
  "the worker after a repeatedly signalled shutdown never reported ready"
kill -TERM "$REPEAT_WORKER_PID"
wait "$REPEAT_WORKER_PID" 2>/dev/null || true
REPEAT_WORKER_PID=
pass "a repeatedly signalled shutdown still releases ownership for the next worker"

# A child that stays up for FM_REMOTE_JOB_SUPERVISOR_HEALTHY_SECONDS clears the
# consecutive-failure backoff, so a child that dies just past that threshold
# used to reset the only guard the supervisor had and restart forever. The
# fixture below is that worker: it exits non-zero after living just longer than
# the healthy window, so every restart is accounted as healthy-then-failed.
RESTART_ROOT="$TMP_ROOT/restart-root"
RESTART_HOME="$TMP_ROOT/restart-account"
RESTART_STATE="$TMP_ROOT/restart-state"
RESTART_CHILD_LOG="$TMP_ROOT/restart-children"
mkdir -p "$RESTART_ROOT/bin" "$RESTART_HOME"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$RESTART_ROOT/bin/"
cp "$ROOT/bin/fm-remote-job-worker.sh" "$RESTART_ROOT/bin/fm-remote-job-supervisor-under-test.sh"
printf 'fixture\n' > "$RESTART_ROOT/AGENTS.md"
cat > "$RESTART_ROOT/bin/fm-remote-job-worker.sh" <<'SH'
#!/bin/bash
set -u
[ "${1:-}" = --serve ] || exit 2
printf '%s\n' "${BASHPID:-$$}" >> "$FM_TEST_SUPERVISOR_CHILD_LOG"
sleep "$FM_TEST_SUPERVISOR_CHILD_SECONDS"
exit "$FM_TEST_SUPERVISOR_CHILD_STATUS"
SH
chmod +x "$RESTART_ROOT/bin"/*.sh
HOME="$RESTART_HOME" FM_ROOT_OVERRIDE="$RESTART_ROOT" \
  FM_REMOTE_JOB_STATE_ROOT="$RESTART_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_SUPERVISOR_HEALTHY_SECONDS=1 FM_REMOTE_JOB_SUPERVISOR_MAX_RESTARTS=3 \
  FM_REMOTE_JOB_SUPERVISOR_MAX_BACKOFF_SECONDS=0 FM_TEST_SUPERVISOR_CHILD_LOG="$RESTART_CHILD_LOG" \
  FM_TEST_SUPERVISOR_CHILD_SECONDS=1.1 FM_TEST_SUPERVISOR_CHILD_STATUS=1 \
  "$RESTART_ROOT/bin/fm-remote-job-supervisor-under-test.sh" \
  > "$TMP_ROOT/restart-supervisor.out" 2> "$TMP_ROOT/restart-supervisor.err" &
RESTART_SUPERVISOR_PID=$!
for _ in $(seq 1 300); do
  kill -0 "$RESTART_SUPERVISOR_PID" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$RESTART_SUPERVISOR_PID" 2>/dev/null; then
  fail "workers dying just past the healthy threshold drove an unbounded restart loop"
fi
set +e
wait "$RESTART_SUPERVISOR_PID"
RESTART_SUPERVISOR_RC=$?
set -e
RESTART_SUPERVISOR_PID=
[ "$RESTART_SUPERVISOR_RC" -ne 0 ] || fail "the exhausted restart guard reported success"
[ "$(wc -l < "$RESTART_CHILD_LOG" | tr -d ' ')" -eq 3 ] \
  || fail "the restart guard did not stop at the configured maximum"
assert_grep "remote job worker exited 3 times; stopping the supervisor" "$TMP_ROOT/restart-supervisor.err" \
  "the restart guard did not explain why it stopped"
pass "barely healthy worker failures remain bounded by the restart guard"

echo "ALL TESTS PASSED"
