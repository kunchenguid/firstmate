#!/usr/bin/env bash
# Behavior tests for the orphaned chrome-devtools-axi browser bridge sweep.
#
# The leak this pins: chrome-devtools-axi starts its bridge detached, so the
# bridge is a process-group leader reparented to init at once, and it has no
# parent-liveness check. A firstmate task that ends without a farewell signal
# leaves the bridge, its chrome-devtools-mcp children, and their detached
# Chrome tree - plus the Chrome profile directory - running indefinitely.
# Observed 2026-09-21 as six orphaned automation trees, the oldest two days
# and four hours old, with 21 Chrome processes and ~3.6GB of leftover browser
# profiles from completed tasks.
#
# fm_browser_bridge_sweep is a machine-wide sweep by design, so these cases
# assert only about their own fixture processes. Any other bridge tree it
# reaps during the run had a proven-dead owner too, which is exactly the
# contract; anything it cannot positively attribute stays untouched.
#
# Fixture bridges are python stand-ins because only user binaries expose their
# environment through `ps eww` on macOS - SIP-protected binaries like
# /bin/sleep report none, and an unreadable environment is itself one of the
# refusal paths under test.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The shared test boundary pins the sweep's process-table hook to an empty
# table so no fixture bootstrap reaps the host's own bridges. This suite is the
# one that means to scan the real table, so it clears the hook.
unset FM_BROWSER_BRIDGE_PROC_TABLE

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-browser-bridge-sweep)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# shellcheck source=bin/fm-browser-bridge-sweep-lib.sh
. "$ROOT/bin/fm-browser-bridge-sweep-lib.sh"

AXI_STATE=$TMP_ROOT/axi-state
HOME_STATE=$TMP_ROOT/home-state
HOME_DATA=$TMP_ROOT/home-data
mkdir -p "$AXI_STATE/sessions" "$HOME_STATE" "$HOME_DATA"
export FM_CHROME_AXI_STATE_DIR=$AXI_STATE

# A python stand-in that mirrors the real detached shape: own process group
# (like detached:true), same-group "mcp" children, and further children each in
# their own process group (the mcp watchdog and the puppeteer Chrome).
FIXTURE=$TMP_ROOT/chrome-devtools-axi-bridge.py
cat > "$FIXTURE" <<'PY'
import os, subprocess, sys, time

outdir = sys.argv[1]
profiles = sys.argv[2:]
try:
    os.setsid()
except OSError:
    pass
kids = []
kids.append(subprocess.Popen(["python3", "-c", "import time;time.sleep(300)"]))
kids.append(subprocess.Popen(["python3", "-c", "import time;time.sleep(300)",
                             "gap  gap"]))
kids.append(subprocess.Popen(["python3", "-c", "import time;time.sleep(300)"],
                             start_new_session=True))
for d in profiles:
    kids.append(subprocess.Popen(
        ["python3", "-c", "import time;time.sleep(300)", "--user-data-dir=" + d],
        start_new_session=True))
with open(os.path.join(outdir, "children"), "w") as f:
    for k in kids:
        f.write("%d\n" % k.pid)
time.sleep(300)
PY

TRACKED_PIDS=()
sweep_cleanup() {
  local pid
  for pid in "${TRACKED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap sweep_cleanup EXIT

track() { TRACKED_PIDS+=("$1"); }

# kill -0 still answers for a zombie waiting on its parent, so "alive" is the
# same notion the sweep uses: not gone and not zombie.
alive() {
  kill -0 "$1" 2>/dev/null || return 1
  ! ps -p "$1" -o stat= 2>/dev/null | grep -q Z
}

pgid_of() { ps -p "$1" -o pgid= 2>/dev/null | tr -d '[:space:]'; }

wait_gone() { # <pid> <seconds>
  local pid=$1 deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    alive "$pid" || return 0
    sleep 0.1
  done
  ! alive "$pid"
}

wait_file() { # <path> <seconds>
  local f=$1 deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -f "$f" ] && return 0
    sleep 0.1
  done
  return 1
}

# start_bridge <case-dir> <task-id-or-empty> <session> [profile-dir ...]
# Launch a fixture bridge tree; echoes the bridge pid and writes the child
# pids to <case-dir>/children. The pid is tracked by the caller because the
# echo runs through a command substitution whose subshell cannot register.
start_bridge() {
  local dir=$1 id=$2 session=$3
  shift 3
  mkdir -p "$dir"
  if [ -n "$id" ]; then
    env FM_TASK_ID="$id" CHROME_DEVTOOLS_AXI_SESSION="$session" \
      python3 "$FIXTURE" "$dir" "$@" >/dev/null 2>&1 &
  else
    env CHROME_DEVTOOLS_AXI_SESSION="$session" \
      python3 "$FIXTURE" "$dir" "$@" >/dev/null 2>&1 &
  fi
  local pid=$!
  wait_file "$dir/children" 10 || { kill -KILL "$pid" 2>/dev/null; return 1; }
  printf '%s\n' "$pid"
}

# track_tree <bridge-pid> <case-dir>: register the bridge and every spawned
# descendant for cleanup; the children lead their own process groups, so the
# bridge's group alone does not cover them.
track_tree() {
  local pid=$1 dir=$2 k
  track "$pid"
  while IFS= read -r k; do
    [ -n "$k" ] && track "$k"
  done < "$dir/children"
}

# start_carrier <task-id>: a live process outside any bridge tree carrying
# FM_TASK_ID=<id> in its environment - proof the owning task is still alive.
start_carrier() {
  env FM_TASK_ID="$1" python3 -c 'import time;time.sleep(300)' >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

# --- case 1: an orphaned bridge tree is reaped whole, profiles removed ------

ID1=fmtest-bbs-orphan-$RANDOM
PROFILE1=$TMP_ROOT/zk-axi-profile-$ID1
mkdir -p "$PROFILE1/Default"
C1=$TMP_ROOT/case1
BP1=$(start_bridge "$C1" "$ID1" s-orphan "$PROFILE1") ||
  fail "could not start the fixture bridge"
track_tree "$BP1" "$C1"
[ "$(pgid_of "$BP1")" = "$BP1" ] ||
  fail "the fixture bridge is not its own process group leader"
KIDS1=$(cat "$C1/children")
[ -n "$KIDS1" ] || fail "the fixture bridge never spawned children"
alive "$BP1" || fail "the fixture bridge died before the sweep"

out=$(fm_browser_bridge_sweep mutate "$HOME_STATE" "$HOME_DATA/secondmates.md" 2>&1) \
  || fail "the sweep failed: $out"
assert_contains "$out" "reaping orphaned bridge pid=$BP1" \
  "the sweep did not name the bridge it reaped"
assert_contains "$out" "pgid=$BP1" \
  "the reap line did not name the process group"
assert_contains "$out" "task=$ID1" \
  "the reap line did not name the owning task"
assert_contains "$out" "age=" \
  "the reap line did not name the bridge age"
assert_contains "$out" "profile=$PROFILE1" \
  "the reap line did not name the profile directory"
wait_gone "$BP1" 15 || fail "the orphaned bridge survived the sweep"
k=0; survived=0
while IFS= read -r k; do
  [ -n "$k" ] && alive "$k" && survived=1
done <<EOF
$KIDS1
EOF
[ "$survived" -eq 0 ] || fail "a bridge descendant survived the sweep"
assert_absent "$PROFILE1" "the orphaned profile directory was not removed"
assert_contains "$out" "removed browser profile dir" \
  "the sweep did not report the profile removal"
pass "an orphaned bridge tree is reaped across every group it leads and its profile removed"

# --- case 2: report mode detects without signalling --------------------------

ID2=fmtest-bbs-report-$RANDOM
PROFILE2=$TMP_ROOT/zk-axi-profile-$ID2
mkdir -p "$PROFILE2"
C2=$TMP_ROOT/case2
BP2=$(start_bridge "$C2" "$ID2" s-report "$PROFILE2") ||
  fail "could not start the second fixture bridge"
track_tree "$BP2" "$C2"

out=$(fm_browser_bridge_sweep report "$HOME_STATE" "$HOME_DATA/secondmates.md" 2>&1) \
  || fail "the report run failed: $out"
assert_contains "$out" "orphaned bridge pid=$BP2" \
  "the report run did not name the orphaned bridge"
assert_contains "$out" "not reaped (report-only run)" \
  "the report run did not mark its finding as report-only"
assert_contains "$out" "profile=$PROFILE2" \
  "the report line did not name the profile directory"
alive "$BP2" || fail "a report-only run signalled the bridge"
[ -d "$PROFILE2" ] || fail "a report-only run removed the profile dir"
pass "report mode names the orphan, its group, age, and profile - and signals nothing"

out=$(fm_browser_bridge_sweep mutate "$HOME_STATE" "$HOME_DATA/secondmates.md" 2>&1) \
  || fail "the mutating sweep failed: $out"
wait_gone "$BP2" 15 || fail "the reported bridge survived the mutating sweep"
assert_absent "$PROFILE2" "the second orphaned profile directory was not removed"

out=$(fm_browser_bridge_sweep mutate "$HOME_STATE" "$HOME_DATA/secondmates.md" 2>&1) \
  || fail "a repeat sweep failed: $out"
assert_not_contains "$out" "$BP2" \
  "the sweep reported an already-reaped bridge"
pass "a mutating run reaps what report mode found, and a repeat run is silent"

# --- case 3: a live owner carrier keeps the bridge ---------------------------

ID3=fmtest-bbs-live-$RANDOM
C3=$TMP_ROOT/case3
BP3=$(start_bridge "$C3" "$ID3" s-live) ||
  fail "could not start the third fixture bridge"
track_tree "$BP3" "$C3"
CARRIER3=$(start_carrier "$ID3")
track "$CARRIER3"
alive "$CARRIER3" || fail "the owner carrier did not start"

out=$(fm_browser_bridge_sweep mutate "$HOME_STATE" "$HOME_DATA/secondmates.md" 2>&1) \
  || fail "the sweep failed with a live owner: $out"
assert_not_contains "$out" "reaping orphaned bridge pid=$BP3" \
  "the sweep reaped a bridge whose owner carrier is alive"
alive "$BP3" || fail "the sweep killed a bridge with a live owner"
pass "a bridge whose FM_TASK_ID carrier is alive is never touched"

# --- case 4: an unattributable bridge is refused and reported ----------------

C4=$TMP_ROOT/case4
BP4=$(start_bridge "$C4" "" s-foreign) ||
  fail "could not start the unattributable fixture bridge"
track_tree "$BP4" "$C4"

out=$(fm_browser_bridge_sweep mutate "$HOME_STATE" "$HOME_DATA/secondmates.md" 2>&1) \
  || fail "the sweep failed on an unattributable bridge: $out"
assert_contains "$out" "left bridge pid=$BP4" \
  "the sweep did not report the refused bridge"
assert_contains "$out" "not attributable" \
  "the refusal line did not name the attribution refusal"
alive "$BP4" || fail "the sweep killed an unattributable bridge"
pass "a bridge with no firstmate attribution is refused and reported, never killed"

# --- case 5: an unverifiable owner endpoint is refused -----------------------

ID5=fmtest-bbs-unknown-$RANDOM
C5=$TMP_ROOT/case5
fm_write_meta "$HOME_STATE/$ID5.meta" \
  "window=firstmate:fm-$ID5" \
  "endpoint_task_id=$ID5" \
  "backend=fmtest-no-such-backend" \
  "kind=ship"
BP5=$(start_bridge "$C5" "$ID5" s-unknown) ||
  fail "could not start the fifth fixture bridge"
track_tree "$BP5" "$C5"

out=$(fm_browser_bridge_sweep mutate "$HOME_STATE" "$HOME_DATA/secondmates.md" 2>&1) \
  || fail "the sweep failed on an unverifiable endpoint: $out"
assert_contains "$out" "left bridge pid=$BP5" \
  "the sweep did not report the unverifiable bridge"
assert_contains "$out" "could not be proven dead" \
  "the refusal line did not name the unproven-owner refusal"
alive "$BP5" || fail "the sweep killed a bridge whose owner state is unverifiable"
pass "a bridge whose recorded endpoint cannot be verified is refused, not reaped"

# --- case 6: a recorded endpoint proven missing reaps through the meta path --
# The task is gone but left its meta behind: no carrier exists, and the
# recorded tmux endpoint resolves to a window that is not there -> dead.
# Needs tmux to return `missing`; without tmux the same meta is `unverified`
# and the bridge stays refused, which case 5 already pins.

if command -v tmux >/dev/null 2>&1; then
  ID6=fmtest-bbs-meta-$RANDOM
  C6=$TMP_ROOT/case6
  PROFILE6=$TMP_ROOT/zk-axi-profile-$ID6
  mkdir -p "$PROFILE6"
  fm_write_meta "$HOME_STATE/$ID6.meta" \
    "window=firstmate:fm-$ID6" \
    "endpoint_task_id=$ID6" \
    "kind=ship"
  BP6=$(start_bridge "$C6" "$ID6" s-meta "$PROFILE6") ||
    fail "could not start the sixth fixture bridge"
  track_tree "$BP6" "$C6"

  out=$(fm_browser_bridge_sweep mutate "$HOME_STATE" "$HOME_DATA/secondmates.md" 2>&1) \
    || fail "the sweep failed on a dead recorded endpoint: $out"
  assert_contains "$out" "reaping orphaned bridge pid=$BP6" \
    "the sweep did not reap through the recorded-endpoint path"
  wait_gone "$BP6" 15 || fail "the meta-orphaned bridge survived the sweep"
  assert_absent "$PROFILE6" "the sixth profile dir was not removed"
  pass "a bridge whose recorded endpoint is proven missing is reaped"

  # --- case 7: session-name attribution when FM_TASK_ID is unreadable -------
  # The session name itself matches a recorded task id, so the bridge is
  # attributable even without the env var, and its dead endpoint reaps it.
  ID7=fmtest-bbs-sess-$RANDOM
  C7=$TMP_ROOT/case7
  fm_write_meta "$HOME_STATE/$ID7.meta" \
    "window=firstmate:fm-$ID7" \
    "endpoint_task_id=$ID7" \
    "kind=ship"
  BP7=$(start_bridge "$C7" "" "$ID7") ||
    fail "could not start the seventh fixture bridge"
  track_tree "$BP7" "$C7"

  out=$(fm_browser_bridge_sweep mutate "$HOME_STATE" "$HOME_DATA/secondmates.md" 2>&1) \
    || fail "the sweep failed on the session-fallback bridge: $out"
  assert_contains "$out" "reaping orphaned bridge pid=$BP7" \
    "the session-named bridge was not attributed through its meta"
  wait_gone "$BP7" 15 || fail "the session-named bridge survived the sweep"
  pass "a bridge whose session name matches a recorded task id is attributable and reaped"
else
  printf 'skip: tmux not found; recorded-endpoint cases not exercised\n'
fi

# --- case 8: a refused profile dir is left and reported ----------------------

ID8=fmtest-bbs-noprof-$RANDOM
C8=$TMP_ROOT/case8
NOTDIR=$TMP_ROOT/session-data-$ID8   # basename carries no "profile"
mkdir -p "$NOTDIR"
BP8=$(start_bridge "$C8" "$ID8" s-noprof "$NOTDIR") ||
  fail "could not start the eighth fixture bridge"
track_tree "$BP8" "$C8"

out=$(fm_browser_bridge_sweep mutate "$HOME_STATE" "$HOME_DATA/secondmates.md" 2>&1) \
  || fail "the sweep failed on a non-profile dir: $out"
wait_gone "$BP8" 15 || fail "the eighth bridge survived the sweep"
assert_present "$NOTDIR" "a directory outside the profile rules was removed"
assert_contains "$out" "outside the removable rules" \
  "the sweep did not report the refused profile dir"
pass "a --user-data-dir outside the profile rules is left and reported, never guessed"

# --- case 8b: a profile another live process names is left ----------------
# CHROME_DEVTOOLS_AXI_USER_DATA_DIR is often a stable, reused path, so an
# orphaned tree's profile can be the same one a live task still intends to
# use. The tree is reaped, but a shared profile is never deleted underneath
# that live consumer.

ID8B=fmtest-bbs-inuse-$RANDOM
C8B=$TMP_ROOT/case8b
PROFILE8B=$TMP_ROOT/zk-axi-profile-$ID8B
mkdir -p "$PROFILE8B"
python3 -c 'import time;time.sleep(300)' "--user-data-dir=$PROFILE8B" >/dev/null 2>&1 &
HOLDER8B=$!
track "$HOLDER8B"
alive "$HOLDER8B" || fail "the live profile holder did not start"
BP8B=$(start_bridge "$C8B" "$ID8B" s-inuse "$PROFILE8B") ||
  fail "could not start the shared-profile fixture bridge"
track_tree "$BP8B" "$C8B"

out=$(fm_browser_bridge_sweep mutate "$HOME_STATE" "$HOME_DATA/secondmates.md" 2>&1) \
  || fail "the sweep failed on a shared profile: $out"
wait_gone "$BP8B" 15 || fail "the orphaned bridge survived the sweep"
assert_present "$PROFILE8B" "a profile a live process still names was removed"
assert_contains "$out" "a live process still names it" \
  "the sweep did not report the shared profile as still in use"
pass "a profile dir a live process still names is left and reported"

# --- case 9: stale bridge pid files ------------------------------------------

# A recorded pid that cannot exist (above the platform pid ceiling).
mkdir -p "$AXI_STATE/sessions/dead-one"
printf '{"pid":99999,"port":9555}\n' > "$AXI_STATE/sessions/dead-one/bridge.pid"
# A recorded pid reused by a non-bridge process.
mkdir -p "$AXI_STATE/sessions/reused-one"
printf '{"pid":%s,"port":9556}\n' "$CARRIER3" > "$AXI_STATE/sessions/reused-one/bridge.pid"
# A recorded pid belonging to a live fixture bridge stays.
mkdir -p "$AXI_STATE/sessions/live-one"
printf '{"pid":%s,"port":9557}\n' "$BP3" > "$AXI_STATE/sessions/live-one/bridge.pid"
# An unreadable pid file is reported, not removed.
mkdir -p "$AXI_STATE/sessions/broken-one"
printf 'not json\n' > "$AXI_STATE/sessions/broken-one/bridge.pid"

out=$(fm_browser_bridge_sweep report "$HOME_STATE" "$HOME_DATA/secondmates.md" 2>&1) \
  || fail "the stale-pid report run failed: $out"
assert_contains "$out" "stale bridge pid file" \
  "the report run did not name the stale pid files"
assert_contains "$out" "unreadable bridge pid file" \
  "the report run did not name the unreadable pid file"
assert_present "$AXI_STATE/sessions/dead-one/bridge.pid" \
  "a report-only run removed a stale pid file"
pass "report mode names stale and unreadable pid files without touching them"

out=$(fm_browser_bridge_sweep mutate "$HOME_STATE" "$HOME_DATA/secondmates.md" 2>&1) \
  || fail "the stale-pid sweep failed: $out"
assert_absent "$AXI_STATE/sessions/dead-one/bridge.pid" \
  "the dead-pid file was not removed"
assert_absent "$AXI_STATE/sessions/reused-one/bridge.pid" \
  "the reused-pid file was not removed"
assert_present "$AXI_STATE/sessions/live-one/bridge.pid" \
  "a live bridge's pid file was removed"
assert_present "$AXI_STATE/sessions/broken-one/bridge.pid" \
  "an unreadable pid file was removed"
assert_contains "$out" "removed stale bridge pid file" \
  "the sweep did not report the stale pid file removals"
pass "stale pid files for dead or reused pids are removed; live and unreadable ones stay"

# --- case 10: the never-touch rule for the captain's own browser -------------
# The fixture already proves unattributable trees are refused (case 4). The
# stronger guarantee is structural: the sweep only ever matches processes
# whose command carries the chrome-devtools-axi bridge signature AND whose
# environment attributes them to a firstmate task, so no captain Chrome,
# Spotify embedded browser, or other process is ever a candidate. Assert the
# signature gate directly.

fm_browser_bridge_is_bridge_command \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  && fail "the captain's Chrome matched the bridge signature"
fm_browser_bridge_is_bridge_command \
  "/Applications/Spotify.app/Contents/MacOS/Spotify --type=renderer" \
  && fail "Spotify's embedded browser matched the bridge signature"
fm_browser_bridge_is_bridge_command \
  "node /opt/homebrew/lib/node_modules/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js" \
  || fail "a real bridge command did not match the bridge signature"
pass "the signature gate excludes ordinary browsers and admits only the axi bridge"
