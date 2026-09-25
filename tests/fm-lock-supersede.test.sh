#!/usr/bin/env bash
# The session lock supersedes a live idle primary without touching its process.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAB=$(fm_test_tmproot fm-lock-supersede)
HOME_ROOT="$LAB/primary"
STATE="$HOME_ROOT/state"
FAKEBIN=$(fm_fakebin "$LAB/fakebin")
mkdir -p "$STATE" "$HOME_ROOT/bin"
: > "$HOME_ROOT/AGENTS.md"
git -C "$HOME_ROOT" init -q
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$pid" = "${FM_TEST_OLD:-}" ] || [ "$pid" = "${FM_TEST_NEW:-}" ] || [ "$pid" = "${FM_TEST_THIRD:-}" ]; then
  kind=claude
  [ "$pid" != "${FM_TEST_ME:-}" ] || kind=${FM_TEST_KIND:-claude}
  case "$field" in comm=|args=) printf '%s\n' "$kind" ;; ppid=) printf '1\n' ;; esac
elif [ "$pid" = 1 ]; then
  case "$field" in comm=|args=) printf 'systemd\n' ;; ppid=) printf '0\n' ;; esac
else
  case "$field" in comm=|args=) printf 'bash\n' ;; ppid=) printf '%s\n' "$FM_TEST_ME" ;; esac
fi
SH
chmod +x "$FAKEBIN/ps"

sleep 300 & old=$!
sleep 300 & new=$!
sleep 300 & third=$!
cleanup() {
  kill "$old" "$new" "$third" 2>/dev/null || true
  wait "$old" "$new" "$third" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

run_as() { # <fixture-pid> <command...>
  local me=$1
  shift
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CODEX_THREAD_ID -u CODEX_SESSION_ID \
    PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$HOME_ROOT" FM_HOME="$HOME_ROOT" \
    FM_STATE_OVERRIDE="$STATE" FM_TEST_ME="$me" FM_TEST_OLD="$old" \
    FM_TEST_NEW="$new" FM_TEST_THIRD="$third" "$@"
}

printf '%s\n' "$old" > "$STATE/.lock"
printf '%s\n' "$old" > "$STATE/.session-start-complete"
out=$(run_as "$new" "$ROOT/bin/fm-lock.sh") || fail "a new primary could not supersede an idle live holder"
assert_contains "$out" "lock takeover: displaced live holder $old" "takeover did not name the displaced holder"
[ "$(cat "$STATE/.lock")" = "$new" ] || fail "new primary did not own the lock"
kill -0 "$old" 2>/dev/null || fail "takeover touched the displaced holder process"
if run_as "$old" "$ROOT/bin/fm-wake-drain.sh" > "$LAB/displaced.out" 2>&1; then
  fail "displaced holder was allowed to drain wakes"
fi
assert_contains "$(cat "$LAB/displaced.out")" 'this session was displaced' "displaced drain refusal was not explicit"
if run_as "$old" "$ROOT/bin/fm-watch-arm.sh" > "$LAB/arm.out" 2>&1; then
  fail "displaced holder was allowed to arm a watcher"
fi
if FM_WATCH_SESSION_IDENTITY="$old" run_as "$new" "$ROOT/bin/fm-wake-drain.sh" > "$LAB/watch-child.out" 2>&1; then
  fail "a child of the displaced watcher was allowed to drain wakes"
fi
assert_contains "$(cat "$LAB/watch-child.out")" 'watcher session was displaced' \
  "a stale watcher child was not bound to its launch owner"
if run_as "$old" "$ROOT/bin/fm-send.sh" absent message > "$LAB/send.out" 2>&1; then
  fail "displaced holder was allowed to steer"
fi
for command in fm-spawn.sh fm-control.sh fm-teardown.sh fm-update.sh; do
  if run_as "$old" "$ROOT/bin/$command" absent > "$LAB/$command.out" 2>&1; then
    fail "displaced holder was allowed to run $command"
  fi
  assert_contains "$(cat "$LAB/$command.out")" 'this session was displaced' \
    "$command did not refuse on the displaced identity"
done
pass "an old idle live pane is superseded, stays alive, and its mutation guards refuse"

printf '%s\n' "$old" > "$STATE/.lock"
printf '%s\n' "$old" > "$STATE/.session-start-complete"
if FM_TASK_ID=worker run_as "$new" "$ROOT/bin/fm-lock.sh" takeover > "$LAB/worker.out" 2>&1; then
  fail "a task-marked worker took over a live primary lock"
fi
[ "$(cat "$STATE/.lock")" = "$old" ] || fail "worker refusal changed the lock"
printf 'sm-test\n' > "$HOME_ROOT/.fm-secondmate-home"
if run_as "$new" "$ROOT/bin/fm-lock.sh" takeover > "$LAB/secondmate.out" 2>&1; then
  fail "a secondmate home took over a live primary lock"
fi
rm "$HOME_ROOT/.fm-secondmate-home"
printf 'invalid marker\n' > "$HOME_ROOT/.fm-secondmate-home"
if run_as "$new" "$ROOT/bin/fm-lock.sh" takeover > "$LAB/invalid-secondmate.out" 2>&1; then
  fail "an ambiguous secondmate marker allowed takeover"
fi
rm "$HOME_ROOT/.fm-secondmate-home"
git -C "$HOME_ROOT" -c user.name=fixture -c user.email=fixture@example.invalid add AGENTS.md
git -C "$HOME_ROOT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
git -C "$HOME_ROOT" worktree add -q --detach "$LAB/worker-worktree"
mkdir -p "$LAB/worker-worktree/bin"
if env -u FM_TASK_ID -u CODEX_THREAD_ID -u CODEX_SESSION_ID \
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$LAB/worker-worktree" FM_HOME="$HOME_ROOT" \
  FM_STATE_OVERRIDE="$STATE" FM_TEST_ME="$new" FM_TEST_OLD="$old" \
  FM_TEST_NEW="$new" FM_TEST_THIRD="$third" \
  "$ROOT/bin/fm-lock.sh" takeover > "$LAB/worktree.out" 2>&1; then
  fail "an unmarked linked worker worktree took over a live primary lock"
fi
mkdir -p "$LAB/other-home"
if env -u FM_TEST_SEAM -u FM_TASK_ID -u CODEX_THREAD_ID -u CODEX_SESSION_ID \
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$HOME_ROOT" FM_HOME="$LAB/other-home" \
  FM_STATE_OVERRIDE="$STATE" FM_TEST_ME="$new" FM_TEST_OLD="$old" \
  FM_TEST_NEW="$new" FM_TEST_THIRD="$third" \
  "$ROOT/bin/fm-lock.sh" takeover > "$LAB/other-home.out" 2>&1; then
  fail "a process targeting a different FM_HOME took over the primary lock"
fi
pass "worker and secondmate contexts cannot take over a live primary"

codex_root="$LAB/codex-home"
mkdir -p "$codex_root/thread-writer-locks"
codex_lock="$codex_root/thread-writer-locks/old-thread.lock"
: > "$codex_lock"
flock -x "$codex_lock" sleep 300 & codex_writer=$!
sleep 0.1
printf 'codex:old-thread:%s\n' "$codex_root" > "$STATE/.lock"
printf 'codex:old-thread:%s\n' "$codex_root" > "$STATE/.session-start-complete"
out=$(run_as "$new" "$ROOT/bin/fm-lock.sh" takeover) || fail "live Codex identity could not be superseded"
assert_contains "$out" "displaced live holder codex:old-thread:$codex_root" "Codex takeover did not name its identity"
[ "$(cat "$STATE/.lock")" = "$new" ] || fail "PID successor did not own a Codex-held lock"
kill -0 "$codex_writer" 2>/dev/null || fail "Codex writer fixture was touched by takeover"
kill "$codex_writer" 2>/dev/null || true
wait "$codex_writer" 2>/dev/null || true
pass "a live Codex writer identity and a live PID holder use the same takeover path"

codex_new_lock="$codex_root/thread-writer-locks/new-thread.lock"
: > "$codex_new_lock"
flock -x "$codex_new_lock" sleep 300 & codex_new_writer=$!
sleep 0.1
printf '%s\n' "$old" > "$STATE/.lock"
printf '%s\n' "$old" > "$STATE/.session-start-complete"
out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$HOME_ROOT" FM_HOME="$HOME_ROOT" \
  FM_STATE_OVERRIDE="$STATE" FM_TEST_ME="$new" FM_TEST_KIND=codex \
  FM_TEST_OLD="$old" FM_TEST_NEW="$new" FM_TEST_THIRD="$third" \
  CODEX_THREAD_ID=new-thread CODEX_HOME="$codex_root" \
  "$ROOT/bin/fm-lock.sh" takeover) || fail "a verified Codex successor could not take over"
assert_contains "$out" "displaced live holder $old" "Codex successor did not report its PID predecessor"
[ "$(cat "$STATE/.lock")" = "codex:new-thread:$codex_root" ] \
  || fail "Codex successor did not publish its thread identity"
kill "$codex_new_writer" 2>/dev/null || true
wait "$codex_new_writer" 2>/dev/null || true
pass "a verified Codex successor publishes its bound thread identity"

# The claim lock serializes both contenders; exactly the final holder can act.
printf '%s\n' "$old" > "$STATE/.lock"
printf '%s\n' "$old" > "$STATE/.session-start-complete"
run_as "$new" "$ROOT/bin/fm-lock.sh" > "$LAB/new.out" 2>&1 & first=$!
run_as "$third" "$ROOT/bin/fm-lock.sh" > "$LAB/third.out" 2>&1 & second=$!
if wait "$first"; then first_rc=0; else first_rc=1; fi
if wait "$second"; then second_rc=0; else second_rc=1; fi
[ "$((first_rc + second_rc))" -le 1 ] || fail "concurrent starters both failed to claim the lock: $(cat "$LAB/new.out") / $(cat "$LAB/third.out")"
winner=$(cat "$STATE/.lock")
case "$winner" in "$new"|"$third") ;; *) fail "race published a corrupt lock: $winner" ;; esac
if [ "$winner" = "$new" ]; then loser=$third; else loser=$new; fi
if run_as "$loser" "$ROOT/bin/fm-wake-drain.sh" > "$LAB/race-loser.out" 2>&1; then
  fail "losing starter was allowed to mutate after the race"
fi
pass "racing starts leave one verified owner and refuse the displaced contender"

printf '%s\n' "$old" > "$STATE/.lock"
printf '%s\n' "$old" > "$STATE/.session-start-complete"
FM_TASK_ID=worker run_as "$new" "$ROOT/bin/fm-lock.sh" > "$LAB/refusal.out" 2>&1 && fail "worker takeover unexpectedly passed"
rm "$STATE/.session-start-complete"
printf 'state=running\nlock_pid=%s\npid=%s\nstarted=%s\n' "$old" "$old" "$(date +%s)" > "$STATE/.startup-network.status"
run_as "$new" "$ROOT/bin/fm-lock.sh" > "$LAB/unfinished.out" 2>&1 \
  && fail "a holder whose startup sweep is running was superseded"
assert_contains "$(cat "$LAB/unfinished.out")" 'startup sweep is still running' \
  "running-sweep refusal changed"
[ "$(cat "$STATE/.lock")" = "$old" ] || fail "the running-sweep refusal changed the lock"
printf 'state=done\nlock_pid=%s\npid=%s\nstarted=%s\n' "$old" "$old" "$(date +%s)" > "$STATE/.startup-network.status"
run_as "$new" "$ROOT/bin/fm-lock.sh" > "$LAB/finished.out" 2>&1 \
  || fail "a holder whose startup sweep finished could not be superseded"
rm -f "$STATE/.startup-network.status"
printf '%s\n' "$old" > "$STATE/.lock"
printf '1\n' > "$STATE/.lock"
out=$(run_as "$new" "$ROOT/bin/fm-lock.sh") || fail "a live non-harness pid (pid reuse) wedged the lock"
assert_contains "$out" "lock acquired: harness pid $new" "a live non-harness holder was not reclaimed as stale"
printf '%s\n' "$old" > "$STATE/.lock"
printf '%s\n' "$old" > "$STATE/.session-start-complete"
run_as "$new" "$ROOT/bin/fm-lock.sh" takeover > "$LAB/via-takeover.out" 2>&1 || fail "takeover from an idle holder failed"
run_as "$third" "$ROOT/bin/fm-lock.sh" > "$LAB/after-takeover.out" 2>&1 \
  || fail "a holder that acquired the lock by takeover could not be superseded by a later start"
[ "$(cat "$STATE/.lock")" = "$third" ] || fail "the later start did not own the lock after a takeover chain"
printf 'not-an-identity\n' > "$STATE/.lock"
run_as "$new" "$ROOT/bin/fm-lock.sh" > "$LAB/unknown.out" 2>&1 \
  && fail "an unverifiable holder was reclaimed"
assert_contains "$(cat "$LAB/unknown.out")" 'owner cannot be verified' \
  "uncertain-owner refusal changed"
printf '%s\n' "$old" > "$STATE/.lock"
printf '%s\n' "$old" > "$STATE/.session-start-complete"
chmod a-r "$STATE/.lock"
if [ ! -r "$STATE/.lock" ]; then
  unreadable_rc=0
  run_as "$new" "$ROOT/bin/fm-lock.sh" > "$LAB/unreadable.out" 2>&1 || unreadable_rc=$?
  chmod u+r "$STATE/.lock"
  [ "$unreadable_rc" -ne 0 ] || fail "an unreadable lock was superseded"
  assert_contains "$(cat "$LAB/unreadable.out")" 'session lock is unreadable' \
    "unreadable-lock refusal changed"
else
  chmod u+r "$STATE/.lock"
fi
chmod a-w "$STATE"
if [ ! -w "$STATE" ]; then
  unwritable_rc=0
  run_as "$new" "$ROOT/bin/fm-lock.sh" > "$LAB/unwritable.out" 2>&1 || unwritable_rc=$?
  chmod u+w "$STATE"
  [ "$unwritable_rc" -ne 0 ] || fail "an unwritable state directory allowed takeover"
  assert_contains "$(cat "$LAB/unwritable.out")" 'cannot write session lock' \
    "unwritable-state refusal changed"
else
  chmod u+w "$STATE"
fi
rm "$STATE/.lock"
mkdir "$STATE/.lock"
run_as "$new" "$ROOT/bin/fm-lock.sh" > "$LAB/nonregular.out" 2>&1 && fail "non-regular lock unexpectedly passed"
assert_contains "$(cat "$LAB/nonregular.out")" 'not a regular file' "non-regular refusal changed"
rmdir "$STATE/.lock"
pass "genuine lock refusal remains read-only"
