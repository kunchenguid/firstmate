#!/usr/bin/env bash
# Opt-in credentialed live guard for the supervision host's Claude engine
# (bin/fm-supervision-host.sh, bin/fm-supervision-engine-lib.sh,
# docs/supervision-host.md "Engines").
#
# Proves against the real installed Claude Code, with no stub anywhere: in an
# isolated lab copy of this checkout opted into the host, an away-posture wake
# produced by a real status append reaches a real headless engine turn that
# drains the wake as the branch actor, records its outcome through
# bin/fm-branch-report.sh, and acknowledges the wake, while the host stays
# parked on a live successor watcher, main is never woken, and no hook of the
# lab home fires inside the engine. A second wake then resumes the same engine
# conversation. Claude keeps its existing managed authentication; the engine's
# own session files land in Claude's project store for the lab directory.
# No live fleet home, worktree, or session is touched.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_SUPERVISION_HOST_LIVE_E2E claude node perl git

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
LAB=$(fm_test_tmproot fm-supervision-host-live)
LAB=$(cd -P "$LAB" && pwd -P)
FM="$LAB/fm"
# The session-lock holder must look like a Claude harness to the ancestry walk
# without shadowing the real claude the engine resolves from PATH.
mkdir -p "$LAB/harness"
ln -s /bin/bash "$LAB/harness/claude"
FAKE_CLAUDE="$LAB/harness/claude"
HOST_TIMEOUT_POLLS=${FM_SUPERVISION_HOST_LIVE_POLLS:-3000}

stop_lab() {
  local pid
  if [ -f "$FM/state/.supervision-host" ]; then
    pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$FM/state/.supervision-host")
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
    sleep 2
  fi
  pid=$(cat "$FM/state/.watch.lock/pid" 2>/dev/null || true)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  while IFS= read -r pid; do
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  done < "$LAB/claude-pids" 2>/dev/null || true
}
trap 'stop_lab; fm_test_cleanup' EXIT

# A lab copy of this checkout's current tree (tracked and untracked, never
# ignored), committed on main, so the lab is a genuine primary checkout whose
# code root is its home.
mkdir -p "$FM"
git -C "$ROOT" ls-files -z -co --exclude-standard \
  | (cd "$ROOT" && tar --null -T - -cf -) | (cd "$FM" && tar -xf -)
git -C "$FM" init -q -b main
git -C "$FM" add -A >/dev/null
git -C "$FM" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q -m lab
mkdir -p "$FM/state" "$FM/config" "$LAB/tmuxbin"
: > "$FM/config/supervision-host"
printf '#!/usr/bin/env bash\nexit 1\n' > "$LAB/tmuxbin/tmux"
chmod +x "$LAB/tmuxbin/tmux"
printf 'project=demo\nwindow=fm-demo\nharness=claude\n' > "$FM/state/demo.meta"
FM_HOME="$FM" "$FM/bin/fm-afk-contract.sh" enter --words 'Watch the fleet. Merge nothing and dispatch nothing.' >/dev/null \
  || fail "could not record the lab's away posture"

export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
unset FM_SUPERVISION_ENGINE_CLAUDE_BIN FM_SUPERVISION_ACTOR FM_BRANCH_REPORT_TURN FM_LEASE_HOLDER_PID
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE PI_CODING_AGENT

FM_HOME="$FM" PATH="$LAB/tmuxbin:$PATH" "$FAKE_CLAUDE" -c '
  printf "%s\n" "$$" > "$FM_HOME/state/.lock"
  printf "%s\n" "$$" >> "$1/claude-pids"
  "$FM_HOME/bin/fm-supervision-host.sh" park > "$1/host.out" 2>&1
  printf "%s\n" "$?" > "$1/host.rc"
' _ "$LAB" 2>> "$LAB/harness.err" &

wait_until() {  # <polls of 0.1s> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
watcher_live() {
  local pid
  pid=$(cat "$FM/state/.watch.lock/pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
settled_at_least() {  # <turns>: handled or failed engine turns
  [ "$(grep -cE '	(handled|failed)	' "$FM/state/.supervision-host.log" 2>/dev/null || true)" -ge "$1" ] || [ -s "$LAB/host.rc" ]
}
diagnose() {
  printf -- '--- host.out\n%s\n--- host log\n%s\n--- queue\n%s\n' "$(cat "$LAB/host.out" 2>/dev/null)" \
    "$(cat "$FM/state/.supervision-host.log" 2>/dev/null)" "$(cat "$FM/state/.wake-queue" 2>/dev/null)"
}

wait_until 300 watcher_live || fail "the host never started a watcher cycle ($CLAUDE_VERSION)"$'\n'"$(diagnose)"
lock_before=$(cat "$FM/state/.lock")

printf 'done [at=%s]: the demo cleanup finished; nothing else is needed\n' "$(date +%s)" >> "$FM/state/demo.status"
wait_until "$HOST_TIMEOUT_POLLS" settled_at_least 1 || fail "the first engine turn never settled ($CLAUDE_VERSION)"$'\n'"$(diagnose)"
grep -q '	handled	turn=' "$FM/state/.supervision-host.log" \
  || fail "the real engine did not handle the away wake ($CLAUDE_VERSION)"$'\n'"$(diagnose)"
[ ! -s "$LAB/host.rc" ] || fail "a handled away wake reached main ($CLAUDE_VERSION)"$'\n'"$(diagnose)"
grep -q '"task":"demo"' "$FM/state/branch-outcomes.jsonl" \
  || fail "the engine's outcome did not reach the store ($CLAUDE_VERSION)"$'\n'"$(diagnose)"
! grep -q 'demo.status' "$FM/state/.wake-queue" 2>/dev/null \
  || fail "the engine did not acknowledge its wake ($CLAUDE_VERSION)"$'\n'"$(diagnose)"
[ ! -e "$FM/state/.claude-autoarm-epoch" ] || fail "a lab Stop hook fired inside the engine ($CLAUDE_VERSION)"
[ "$(cat "$FM/state/.lock")" = "$lock_before" ] || fail "the engine rewrote the session lock ($CLAUDE_VERSION)"
if FM_HOME="$FM" "$FM/bin/fm-lease.sh" check demo >/dev/null 2>&1; then
  fail "a branch lease outlived the engine turn ($CLAUDE_VERSION)"
fi
wait_until 100 watcher_live || fail "the host is not parked on a live successor after handling ($CLAUDE_VERSION)"
printf '# first turn: %s\n' "$(grep '	handled	' "$FM/state/.supervision-host.log" | head -n 1 | cut -f2-5)"
printf '# outcome: %s\n' "$(head -n 1 "$FM/state/branch-outcomes.jsonl")"

session=$(sed -n 's/^session=//p' "$FM/state/.supervision-host-engine")
printf 'working [at=%s]: started the follow-up check\n' "$(date +%s)" >> "$FM/state/demo.status"
wait_until "$HOST_TIMEOUT_POLLS" settled_at_least 2 || fail "the second engine turn never settled ($CLAUDE_VERSION)"$'\n'"$(diagnose)"
[ "$(grep -c '	handled	' "$FM/state/.supervision-host.log")" -ge 2 ] \
  || fail "the real engine did not handle the second wake ($CLAUDE_VERSION)"$'\n'"$(diagnose)"
[ "$(sed -n 's/^session=//p' "$FM/state/.supervision-host-engine")" = "$session" ] \
  || fail "the second turn did not resume the engine conversation ($CLAUDE_VERSION)"
[ "$(sed -n 's/^turns=//p' "$FM/state/.supervision-host-engine")" = 2 ] \
  || fail "the engine conversation did not count its second turn ($CLAUDE_VERSION)"
printf '# second turn: %s\n' "$(grep '	handled	' "$FM/state/.supervision-host.log" | sed -n 2p | cut -f2-5)"

host_pid=$(awk -F '\t' '$1 == "host" { print $2 }' "$FM/state/.supervision-host")
watcher=$(cat "$FM/state/.watch.lock/pid")
kill -TERM "$host_pid"
wait_until 400 test -s "$LAB/host.rc" || fail "the host did not stop on TERM"
wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$watcher" || fail "a stopped host left its watcher running"
[ ! -e "$FM/state/.supervision-host" ] || fail "a stopped host left its record"

pass "supervision host live ($CLAUDE_VERSION): a real engine handles and resumes away wakes under the branch contract without waking main"
