#!/usr/bin/env bash
# Behavior tests for bin/fm-live-lab.sh (readiness checks and teardown) and
# bin/fm-claude-trust.sh --lab-home.
#
# Every readiness check is proven both ways against a real private tmux server
# and real processes, with no harness: it passes on a lab in the shape up builds
# and fails, by name, on the recorded lab miss it exists to catch. The live
# end-to-end run on the real harnesses is the builder's own `up`.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-live-lab)
: > "$TMP_ROOT/pids"
: > "$TMP_ROOT/tmux-dirs"
LIVE_LAB="$ROOT/bin/fm-live-lab.sh"
TRUST="$ROOT/bin/fm-claude-trust.sh"

# lab_socket_of <tmux-dir>: the explicit socket a lab's TMUX_TMPDIR names.
lab_socket_of() { printf '%s/tmux-%s/default\n' "$1" "$(id -u)"; }

live_lab_cleanup() {
  local dir pid marker
  for marker in "$TMP_ROOT/orphan-child" "$TMP_ROOT/late-child" "$TMP_ROOT/reused-child"; do
    [ ! -s "$marker" ] || printf '%s\n' "$(<"$marker")" >> "$TMP_ROOT/pids"
  done
  while read -r pid; do [ -n "$pid" ] && { pkill -P "$pid" 2>/dev/null || true; kill "$pid" 2>/dev/null || true; }; done < "$TMP_ROOT/pids"
  while read -r dir; do
    [ -n "$dir" ] || continue
    # Only the explicit lab socket, and only while it exists: a missing
    # TMUX_TMPDIR would make tmux fall back to the user's default server.
    [ ! -S "$(lab_socket_of "$dir")" ] || env -u TMUX tmux -S "$(lab_socket_of "$dir")" kill-server 2>/dev/null
    case "$dir" in /tmp/fml.*) rm -rf "$dir" ;; esac
  done < "$TMP_ROOT/tmux-dirs"
  rm -rf "/tmp/fm-labt$$-mate" "/tmp/fm-labt$$-worker" "/tmp/fm-labt$$-other" /tmp/fm-labt"$$"-*+*
  fm_test_cleanup
}
trap live_lab_cleanup EXIT

command -v tmux >/dev/null 2>&1 || { echo "ok - skipped: tmux is not installed"; exit 0; }
# shellcheck disable=SC2119 # No bases: the gate checks the real default ones.
fm_tmux_isolation_gate

FAKE_HOME="$TMP_ROOT/fakehome"
mkdir -p "$FAKE_HOME/.pi/agent" "$FAKE_HOME/.treehouse/existing-pool"
printf '{}\n' > "$FAKE_HOME/.pi/agent/trust.json"
export HOME="$FAKE_HOME"
unset CLAUDE_CONFIG_DIR TMUX

MATE_ID="labt$$-mate"
WORKER_ID="labt$$-worker"
NONCE=abc12345

digest() { shasum -a 256 "$1" | awk '{print $1}'; }

# make_lab <name> <harness> [<claude-config-dir>]: a lab root in the shape up
# builds, with a live private tmux server. Every readiness input starts in its
# passing state.
make_lab() {
  local root="$TMP_ROOT/$1" harness=$2 claude_dir=${3:-} home tmux_dir lock_pid
  home="$root/home"
  mkdir -p "$root"
  "$ROOT/bin/fm-lab-home.sh" create "$home" >/dev/null || fail "lab home create"
  cp -R "$ROOT/bin" "$home/bin"
  cp "$ROOT/AGENTS.md" "$home/AGENTS.md"
  mkdir -p "$home/.pi" "$home/data/$WORKER_ID" "$root/mate/state" "$root/treehouse"
  cp -R "$ROOT/.pi/extensions" "$home/.pi/extensions"
  git -C "$home" init -q -b main
  git -C "$home" add -A bin AGENTS.md .pi
  git -C "$home" -c user.name=t -c user.email=t@example.invalid commit -qm lab
  tmux_dir=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$home") || fail "lab tmux dir"
  printf '%s\n' "$tmux_dir" >> "$TMP_ROOT/tmux-dirs"
  mkdir -m 700 "$tmux_dir/tmux-$(id -u)" || fail "lab tmux socket dir"
  find "$HOME/.treehouse" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort > "$root/.treehouse-before"
  {
    echo 'fm-live-lab v1'
    echo "harness=$harness"
    echo "home=$home"
    echo "expect_host=yes"
    echo "host_off=no"
    echo "mate=yes"
    echo "worker=yes"
    echo "nonce=$NONCE"
    echo "mate_id=$MATE_ID"
    echo "worker_id=$WORKER_ID"
    echo "gate=$home/data/$WORKER_ID/gate"
    echo "pi_trust=$(digest "$HOME/.pi/agent/trust.json")"
    echo "claude_config_dir=$claude_dir"
    echo "claude_store=${claude_dir:-$HOME}/.claude.json"
    echo "pi_trust_store=$HOME/.pi/agent/trust.json"
    echo "treehouse_dir=$HOME/.treehouse"
    echo "tmux_dir=$tmux_dir"
  } > "$root/.fm-live-lab"

  lab_tmux "$root" new-session -d -s firstmate -n lab -c "$root" 'exec sleep 600'
  record_pid "$root" "$(lab_tmux "$root" display-message -p '#{pid}')"
  lab_tmux "$root" new-window -d -t firstmate: -n main -c "$home" "printf 'LABREADY-$NONCE\n'; exec sleep 600"
  lab_tmux "$root" new-window -d -t firstmate: -n "fm-$MATE_ID" -c "$root/mate" 'exec sleep 600'
  lab_tmux "$root" new-window -d -t firstmate: -n "fm-$WORKER_ID" -c "$root" 'exec sleep 600'
  fm_write_meta "$home/state/$MATE_ID.meta" "window=firstmate:fm-$MATE_ID" "tasktmp=/tmp/fm-$MATE_ID"
  fm_write_meta "$home/state/$WORKER_ID.meta" "window=firstmate:fm-$WORKER_ID" "worktree=$home/projects/notes" "kind=secondmate" "tasktmp=/tmp/fm-$WORKER_ID"
  mkdir -p "$home/projects/notes"
  printf 'paused [at=1]: waiting on gate file %s to exist\n' "$home/data/$WORKER_ID/gate" > "$home/state/$WORKER_ID.status"

  lock_pid=$(lab_tmux "$root" display-message -p -t firstmate:=main '#{pane_pid}')
  printf '%s\n' "$lock_pid" > "$home/state/.lock"
  printf '%s\n' "$(lab_tmux "$root" display-message -p -t "firstmate:=fm-$MATE_ID" '#{pane_pid}')" > "$root/mate/state/.lock"
  start_watcher "$home"
  printf 'host\t%s\tx\n' "$(start_sleeper)" > "$home/state/.supervision-host"
  printf '%s\n' \
    '{"seq":1,"epoch":1,"key":"k","id":"a","tag":"captain","text":"probe"}' \
    '{"seq":2,"epoch":2,"key":"k","id":"b","tag":"main","text":"LABREADY"}' > "$home/state/.host-mirror.jsonl"
  write_pi_markers "$home" "$lock_pid"
  [ "$harness" = claude ] && node -e 'const fs=require("node:fs");const [s,h,r]=process.argv.slice(1);fs.writeFileSync(s,JSON.stringify({keep:1,projects:{[h]:{hasTrustDialogAccepted:true},[r+"/mate"]:{hasTrustDialogAccepted:true},"/elsewhere/project":{hasTrustDialogAccepted:true}}},null,2)+"\n")' \
    "${claude_dir:-$HOME}/.claude.json" "$home" "$root"
  printf '%s\n' "$root"
}

# Recorded fixture roots must not share the runner's process group.
start_group() { perl -e 'setpgrp(0,0); exec @ARGV' "$@" >/dev/null 2>&1 & }

record_pid() {  # <root> <pid>
  printf 'launch_pid=%s\nlaunch_start=%s\n' "$2" "$(ps -o lstart= -p "$2" | awk '{$1=$1; print}')" >> "$1/.fm-live-lab"
}

lab_tmux() {  # <root> <tmux args...>
  local dir
  dir=$(sed -n 's/^tmux_dir=//p' "$1/.fm-live-lab")
  shift
  [ -n "$dir" ] || return 1
  env -u TMUX tmux -S "$(lab_socket_of "$dir")" "$@"
}

start_sleeper() {
  sleep 600 >/dev/null 2>&1 &
  printf '%s\n' "$!" >> "$TMP_ROOT/pids"
  printf '%s\n' "$!"
}

start_watcher() {  # <home>: a live process holding a matching watcher lock
  local home=$1 pid lock="$1/state/.watch.lock"
  pid=$(start_sleeper)
  mkdir -p "$lock"
  printf '%s\n' "$pid" > "$lock/pid"
  printf '%s\n' "$home" > "$lock/fm-home"
  printf '%s\n' "$home/bin/fm-watch.sh" > "$lock/watcher-path"
  fm_test_pid_identity "$pid" > "$lock/pid-identity"
  touch "$home/state/.last-watcher-beat"
}

write_pi_markers() {  # <home> <lock-pid>
  local home=$1 pid=$2
  v() { FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pi_extension_version "$1/.pi/extensions/$2"' _ "$home" "$1"; }
  printf '%s\n%s\ngeneration=1 phase=active\n' "$(v fm-primary-pi-watch.ts)" "$pid" > "$home/state/.pi-watch-extension-loaded"
  printf '%s\n%s\n' "$(v fm-primary-turnend-guard.ts)" "$pid" > "$home/state/.pi-turnend-extension-loaded"
  printf '%s\n' "$pid" > "$home/state/.pi-branch-extension-loaded"
}

run_check() {  # <root>: sets CHECK_OUT and CHECK_RC
  CHECK_OUT=$("$LIVE_LAB" check "$1" 2>&1)
  CHECK_RC=$?
}

set_record() {  # <root> <key> <value>
  sed -i.bak "s|^$2=.*|$2=$3|" "$1/.fm-live-lab" && rm -f "$1/.fm-live-lab.bak"
}

# ---- Claude lab: every check passes on the shape up builds -----------------

C=$(make_lab c claude)
CH="$C/home"
run_check "$C"
expect_code 0 "$CHECK_RC" "a Claude lab in up's shape is ready: $CHECK_OUT"
for name in primary probe trust mirror host watcher mate worker treehouse; do
  assert_contains "$CHECK_OUT" "ok $name:" "the $name check passes on a ready Claude lab"
done
pass "a ready Claude lab passes every readiness check"

# primary: the lab session lock must name a live process (session start ran).
printf '999999\n' > "$CH/state/.lock"
run_check "$C"
expect_code 1 "$CHECK_RC" "a dead session lock is not ready"
assert_contains "$CHECK_OUT" "fail primary: the lab session lock names no live process" "primary names the dead lock"
lab_tmux "$C" display-message -p -t firstmate:=main '#{pane_pid}' > "$CH/state/.lock"
pass "primary fails when session start never took the lab lock"

# primary: a lab home that is a linked worktree is not the genuine primary
# checkout a mirrored Claude primary needs.
WT_CASE="$TMP_ROOT/wtcase"
fm_git_worktree "$WT_CASE/project" "$WT_CASE/wt" lab-wt
cp "$C/.fm-live-lab" "$WT_CASE/.fm-live-lab"
set_record "$WT_CASE" home "$WT_CASE/wt"
lab_tmux "$C" new-window -d -t firstmate: -n wtmain -c "$WT_CASE/wt" 'exec sleep 600'
lab_tmux "$C" kill-window -t firstmate:=main
lab_tmux "$C" rename-window -t firstmate:=wtmain main
run_check "$WT_CASE"
assert_contains "$CHECK_OUT" "fail primary: the lab home is not a primary checkout" "primary refuses a linked-worktree home"
lab_tmux "$C" kill-window -t firstmate:=main
lab_tmux "$C" new-window -d -t firstmate: -n main -c "$CH" "printf 'LABREADY-$NONCE\n'; exec sleep 600"
lab_tmux "$C" display-message -p -t firstmate:=main '#{pane_pid}' > "$CH/state/.lock"
pass "primary fails when the primary runs in a linked worktree instead of the lab's primary checkout"

# probe: the nonce reply proves the model is accepted and a turn completed.
set_record "$C" nonce 00000000
run_check "$C"
assert_contains "$CHECK_OUT" "fail probe: no LABREADY-00000000 reply" "probe names the missing reply"
set_record "$C" nonce "$NONCE"
pass "probe fails when the primary never answered its nonce"

# trust: the workspace-trust prompt wedged the first lab.
cp "$HOME/.claude.json" "$TMP_ROOT/claude.json.keep"
node -e 'const fs=require("node:fs");const [s,h]=process.argv.slice(1);const j=JSON.parse(fs.readFileSync(s,"utf8"));delete j.projects[h];fs.writeFileSync(s,JSON.stringify(j))' "$HOME/.claude.json" "$CH"
run_check "$C"
assert_contains "$CHECK_OUT" "fail trust: $CH has no registered Claude workspace trust" "trust names the untrusted home"
cp "$TMP_ROOT/claude.json.keep" "$HOME/.claude.json"
pass "trust fails when the lab home has no registered Claude trust"

# mirror: the dialog mirror feed must be wired and hold both sides.
cp "$CH/state/.host-mirror.jsonl" "$TMP_ROOT/mirror.keep"
head -n 1 "$TMP_ROOT/mirror.keep" > "$CH/state/.host-mirror.jsonl"
run_check "$C"
assert_contains "$CHECK_OUT" "fail mirror: the dialog mirror has no captain and main entry yet (captain=1 main=0)" "mirror needs a main entry"
rm -f "$CH/state/.host-mirror.jsonl"
run_check "$C"
assert_contains "$CHECK_OUT" "fail mirror: fm-host-mirror.sh check exited 1" "mirror fails without a mirror file"
cp "$TMP_ROOT/mirror.keep" "$CH/state/.host-mirror.jsonl"
pass "mirror fails when the feed is unwired or has not recorded a whole turn"

# host: expected on Claude, refused when it should be absent.
host_pid=$(awk -F '\t' '{print $2}' "$CH/state/.supervision-host")
kill "$host_pid" 2>/dev/null
wait "$host_pid" 2>/dev/null
run_check "$C"
assert_contains "$CHECK_OUT" "fail host: no live supervision host (expected one)" "host names the missing host"
set_record "$C" expect_host no
run_check "$C"
assert_contains "$CHECK_OUT" "ok host: none running, as expected" "an opted-out lab expects no host"
assert_not_contains "$CHECK_OUT" "mirror" "an opted-out lab skips the mirror"
host_pid=$(start_sleeper)
printf 'host\t%s\tx\n' "$host_pid" > "$CH/state/.supervision-host"
run_check "$C"
assert_contains "$CHECK_OUT" "fail host: supervision host pid $host_pid runs (expected none)" "an opted-out lab refuses a host"
set_record "$C" expect_host yes
pass "host passes and fails according to --expect-host"

# watcher: a stale beacon is not supervision.
touch -t 202001010000 "$CH/state/.last-watcher-beat"
run_check "$C"
assert_contains "$CHECK_OUT" "fail watcher: no live watcher with a fresh beacon" "watcher names the stale beacon"
touch "$CH/state/.last-watcher-beat"
pass "watcher fails on a stale beacon"

# mate: its own window, targeted exactly. A missing window must not resolve to
# another one (tmux falls back to the current window for an unknown name).
lab_tmux "$C" kill-window -t "firstmate:=fm-$MATE_ID"
run_check "$C"
assert_contains "$CHECK_OUT" "fail mate: the $MATE_ID window is not running" "mate names its missing window"
lab_tmux "$C" new-window -d -t firstmate: -n "fm-$MATE_ID" -c "$C/mate" 'exec sleep 600'
rm -f "$C/mate/state/.lock"
run_check "$C"
assert_contains "$CHECK_OUT" "fail mate: the mate holds no session lock yet" "mate needs its own session lock"
lab_tmux "$C" display-message -p -t "firstmate:=fm-$MATE_ID" '#{pane_pid}' > "$C/mate/state/.lock"
pass "mate fails when its window is gone or it never reached its charter"

# Opt-out readiness must observe the mate's inherited material and its real
# home gate, rather than just the primary's absent host.
set_record "$C" host_off yes
set_record "$C" expect_host no
host_pid=$(awk -F '\t' '{print $2}' "$CH/state/.supervision-host")
kill "$host_pid" 2>/dev/null
wait "$host_pid" 2>/dev/null
mkdir -p "$C/mate/config" "$C/mate/bin"
cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$C/mate/bin/"
run_check "$C"
expect_code 1 "$CHECK_RC" "off readiness refuses a mate without its inherited flag"
assert_contains "$CHECK_OUT" "fail mate: the inherited supervision-host-off flag is missing" "mate names the missing opt-out"
: > "$C/mate/config/supervision-host-off"
run_check "$C"
expect_code 0 "$CHECK_RC" "off readiness accepts the mate's inherited flag and disabled gate: $CHECK_OUT"
printf '#!/usr/bin/env bash\nexit 0\n' > "$C/mate/bin/fm-supervision-engine-lib.sh"
run_check "$C"
expect_code 1 "$CHECK_RC" "off readiness refuses a mate whose gate reads on"
assert_contains "$CHECK_OUT" "fail mate: the supervision-host gate did not read off" "mate names the enabled gate"
cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$C/mate/bin/"
set_record "$C" host_off no
set_record "$C" expect_host yes
printf 'host\t%s\tx\n' "$(start_sleeper)" > "$CH/state/.supervision-host"
pass "mate off readiness requires inherited material and a disabled home gate"

# The current-state reader, not an old event, establishes the gate wait.
GATE="$CH/data/$WORKER_ID/gate"
assert_contains "$(sed -n 's/^gate=//p' "$C/.fm-live-lab")" "$CH/data/$WORKER_ID/" "operator can find the gate in the worker's task directory"
: > "$CH/state/$WORKER_ID.status"
run_check "$C"
assert_contains "$CHECK_OUT" "fail worker: the worker is not currently parked" "worker needs a current pause"
printf 'paused [at=1]: waiting on gate file %s to exist\n' "$GATE" > "$CH/state/$WORKER_ID.status"
printf 'working [at=2]: resumed\n' >> "$CH/state/$WORKER_ID.status"
run_check "$C"
assert_contains "$CHECK_OUT" "fail worker: the worker is not currently parked" "stale paused event cannot pass readiness"
printf 'paused [at=3]: waiting on gate file %s to exist\n' "$GATE" >> "$CH/state/$WORKER_ID.status"
run_check "$C"
assert_contains "$CHECK_OUT" "ok worker: $WORKER_ID parked on $GATE" "current pause passes readiness"
pass "worker readiness follows current crew state and the recorded accessible gate"

# treehouse: a worker pool must land inside the lab, never in ~/.treehouse.
mkdir "$HOME/.treehouse/notes-leaked"
run_check "$C"
assert_contains "$CHECK_OUT" "fail treehouse: new ~/.treehouse entries: notes-leaked" "treehouse names the leaked pool"
rmdir "$HOME/.treehouse/notes-leaked"
LATER_HOME="$TMP_ROOT/later-home"
mkdir -p "$LATER_HOME"
CHECK_OUT=$(HOME="$LATER_HOME" "$LIVE_LAB" check "$C" 2>&1)
expect_code 0 "$?" "the Claude lab is ready again after every restore, even from a shell with another HOME: $CHECK_OUT"
pass "treehouse fails when a pool lands in ~/.treehouse"

# ---- Pi lab: extensions and the session-only trust store -------------------

P=$(make_lab p pi)
PH="$P/home"
run_check "$P"
expect_code 0 "$CHECK_RC" "a Pi lab in up's shape is ready: $CHECK_OUT"
assert_contains "$CHECK_OUT" "ok extensions: fm-primary-pi-watch fm-primary-turnend-guard fm-branch-supervision" "all three extensions load"
assert_contains "$CHECK_OUT" "ok trust: Pi trust store unchanged" "the Pi trust store is untouched"
assert_not_contains "$CHECK_OUT" "mirror" "a Pi lab has no host mirror check"
rm -f "$PH/state/.pi-branch-extension-loaded"
run_check "$P"
assert_contains "$CHECK_OUT" "fail extensions: fm-branch-supervision.ts is not loaded by the lock holder" "the missing branch extension is named"
printf '%s\n' "$(sed -n 1p "$PH/state/.lock")" > "$PH/state/.pi-branch-extension-loaded"
printf 'stale\n' > "$PH/state/.pi-turnend-extension-loaded"
run_check "$P"
assert_contains "$CHECK_OUT" "fail extensions: fm-primary-turnend-guard.ts is not loaded at its current build" "a stale turn-end build is named"
pass "extensions fail when the Pi lab lacks the branch extension or loads a stale build"

# ---- down -------------------------------------------------------------------

NOT_LAB="$TMP_ROOT/not-a-lab"
mkdir -p "$NOT_LAB/keep"
out=$("$LIVE_LAB" down "$NOT_LAB" 2>&1)
expect_code 1 "$?" "down refuses a path without a lab record"
assert_contains "$out" "carries no lab record" "the refusal names the missing record"
assert_present "$NOT_LAB/keep" "a refused down removes nothing"
pass "down refuses anything up did not build"

C_HASH=$(printf '%s' "$CH" | shasum -a 256 | awk '{print $1}')
OTHER_ID="labt$$-other"
fm_write_meta "$CH/state/$OTHER_ID.meta" "window=firstmate:fm-$OTHER_ID" "tasktmp=/tmp/fm-$OTHER_ID"
mkdir -p "/tmp/fm-$WORKER_ID/gotmp" "/tmp/fm-$MATE_ID" "/tmp/fm-$WORKER_ID+$C_HASH" "/tmp/fm-$OTHER_ID+$C_HASH" "/tmp/fm-$OTHER_ID"
# An outsider opening a lab path is not owned by the lab.
printf 'sleep 600\n' > "$C/stray.sh"
bash "$C/stray.sh" >/dev/null 2>&1 &
STRAY=$!
printf '%s\n' "$STRAY" >> "$TMP_ROOT/pids"
until STRAY_CHILD=$(pgrep -P "$STRAY" sleep); do sleep 0.1; done
printf '%s\n' "$STRAY_CHILD" >> "$TMP_ROOT/pids"
# A launch-recorded process and its child must be stopped even when not in tmux.
start_group sleep 600
OWNED=$!
printf '%s\n' "$OWNED" >> "$TMP_ROOT/pids"
record_pid "$C" "$OWNED"
# A process in the runner's group is not part of any recorded lab group.
sleep 600 >/dev/null 2>&1 &
UNRELATED=$!
printf '%s\n' "$UNRELATED" >> "$TMP_ROOT/pids"
[ "$(ps -o pgid= -p "$UNRELATED" | awk '{$1=$1; print}')" != "$(ps -o pgid= -p "$OWNED" | awk '{$1=$1; print}')" ] || fail "fixture roots must have their own group"
# A sibling lab root that shares this root as a string prefix is not this lab.
mkdir -p "${C}2"
printf 'sleep 600\n' > "${C}2/stray.sh"
bash "${C}2/stray.sh" 2>/dev/null &
SIBLING=$!
printf '%s\n' "$SIBLING" >> "$TMP_ROOT/pids"
# The worker spawn failed after keeping its task temp dirs, before its meta.
rm -f "$CH/state/$WORKER_ID.meta"
C_TMUX=$(sed -n 's/^tmux_dir=//p' "$C/.fm-live-lab")
out=$(HOME="$LATER_HOME" "$LIVE_LAB" down "$C" 2>&1)
expect_code 0 "$?" "down of a clean Claude lab succeeds from a shell with another HOME: $out"
kill -0 "$STRAY" 2>/dev/null || fail "down leaves unrelated processes opening the lab path alone"
kill -0 "$STRAY_CHILD" 2>/dev/null || fail "down leaves their descendants alone"
! kill -0 "$OWNED" 2>/dev/null || fail "down stops recorded launch processes"
kill -0 "$UNRELATED" 2>/dev/null || fail "down signalled an unrelated process outside recorded groups"
assert_absent "$C" "down removes the lab root"
kill -0 "$SIBLING" 2>/dev/null || fail "down leaves a sibling root's process running"
pkill -P "$SIBLING" 2>/dev/null
kill "$SIBLING" 2>/dev/null
assert_absent "$C_TMUX" "down removes the private tmux directory"
assert_absent "/tmp/fm-$WORKER_ID" "down removes the worker's task temp dir, even without its meta"
assert_absent "/tmp/fm-$MATE_ID" "down removes the mate's task temp dir"
assert_absent "/tmp/fm-$WORKER_ID+$C_HASH" "down removes the worker's launch dir"
assert_absent "/tmp/fm-$OTHER_ID+$C_HASH" "down removes a lab-spawned task's launch dir scoped to the lab home"
assert_present "/tmp/fm-$OTHER_ID" "down keeps a task temp dir another home could share"
kept=$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify([j.keep,Object.keys(j.projects).sort()]))' "$HOME/.claude.json")
assert_equals '[1,["/elsewhere/project"]]' "$kept" "down removes exactly the lab's Claude project entries"
assert_contains "$out" "removed: 2 Claude project entries" "down reports the removed entries"
kill "$STRAY" "$STRAY_CHILD" 2>/dev/null || true
pass "down stops only recorded lab processes, removes trust entries and task temp dirs"

# The Claude store up selected is the one check and down use, even from a later
# shell with another CLAUDE_CONFIG_DIR, and a symlinked store stays a symlink.
SC="$TMP_ROOT/claude-config"
mkdir -p "$SC"
S=$(make_lab s claude "$SC")
mv "$SC/.claude.json" "$TMP_ROOT/claude-store-target.json"
ln -s "$TMP_ROOT/claude-store-target.json" "$SC/.claude.json"
HOME_STORE_BEFORE=$(digest "$HOME/.claude.json")
CHECK_OUT=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/other-config" "$LIVE_LAB" check "$S" 2>&1)
assert_contains "$CHECK_OUT" "ok trust: $S/home is trusted in the Claude store" "check reads the recorded store"
out=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/other-config" "$LIVE_LAB" down "$S" 2>&1)
expect_code 0 "$?" "down of a lab on a configured store succeeds: $out"
assert_contains "$out" "removed: 2 Claude project entries" "down removes the entries from the recorded store"
[ -L "$SC/.claude.json" ] || fail "down keeps a symlinked Claude store a symlink"
kept=$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify([j.keep,Object.keys(j.projects).sort()]))' "$TMP_ROOT/claude-store-target.json")
assert_equals '[1,["/elsewhere/project"]]' "$kept" "down rewrites the symlink's target"
assert_equals "$HOME_STORE_BEFORE" "$(digest "$HOME/.claude.json")" "down leaves the default store alone"
pass "check and down use the recorded Claude store and keep a symlinked store linked"

# TERM handlers may write trust again, and an uncooperative lab process must
# be killed before the store or lab directory is removed.
X=$(make_lab x claude)
cat > "$TMP_ROOT/exit-rewriter.sh" <<'SH'
store=$1 key=$2 marker=$3
trap 'sleep 1; node -e "const fs=require(\"node:fs\");const [s,k]=process.argv.slice(1);const j=JSON.parse(fs.readFileSync(s,\"utf8\"));j.projects[k]={hasTrustDialogAccepted:true};fs.writeFileSync(s,JSON.stringify(j))" "$store" "$key"; echo rewrote > "$marker"; exit 0' TERM
while :; do sleep 0.1; done
SH
start_group bash "$TMP_ROOT/exit-rewriter.sh" "$HOME/.claude.json" "$X/home" "$TMP_ROOT/rewrote"
REWRITER=$!
start_group bash -c 'trap "" TERM; while :; do sleep 0.1; done'
STUBBORN=$!
sleep 0.2
printf '%s\n%s\n' "$REWRITER" "$STUBBORN" >> "$TMP_ROOT/pids"
record_pid "$X" "$REWRITER"
record_pid "$X" "$STUBBORN"
out=$("$LIVE_LAB" down "$X" 2>&1)
expect_code 0 "$?" "down waits for lab processes: $out"
wait "$REWRITER" 2>/dev/null || true
assert_equals rewrote "$(cat "$TMP_ROOT/rewrote" 2>/dev/null)" "TERM handler rewrote its Claude key before down returned"
! kill -0 "$STUBBORN" 2>/dev/null || fail "down must kill a TERM-resistant lab process"
sleep 1.5
lab_keys=$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));console.log(Object.keys(j.projects).filter(k=>k.startsWith(process.argv[2])).join(" "))' "$HOME/.claude.json" "$X")
assert_equals "" "$lab_keys" "no exiting lab process re-adds Claude trust"
pass "down waits for TERM handlers and escalates before removing trust"

# A pane root may exit on TERM while its child remains alive, reparented and
# still able to write Claude trust. Teardown must wait for the captured child.
ORPHAN=$(make_lab orphan claude)
cat > "$TMP_ROOT/orphan-rewriter.sh" <<'SH'
store=$1 key=$2 marker=$3
trap 'sleep 1; node -e "const fs=require(\"node:fs\");const [s,k]=process.argv.slice(1);const j=JSON.parse(fs.readFileSync(s,\"utf8\"));j.projects[k]={hasTrustDialogAccepted:true};fs.writeFileSync(s,JSON.stringify(j))" "$store" "$key"; echo rewrote > "$marker"; exit 0' TERM
while :; do sleep 0.1; done
SH
# shellcheck disable=SC2016 # Positional parameters expand in the launched shell.
start_group bash -c 'bash "$1" "$2" "$3" "$4" & echo $! > "$5"; while :; do sleep 0.1; done' _ \
  "$TMP_ROOT/orphan-rewriter.sh" "$HOME/.claude.json" "$ORPHAN/home" "$TMP_ROOT/orphan-rewrote" "$TMP_ROOT/orphan-child"
ORPHAN_ROOT=$!
until [ -s "$TMP_ROOT/orphan-child" ]; do sleep 0.1; done
ORPHAN_CHILD=$(cat "$TMP_ROOT/orphan-child")
printf '%s\n%s\n' "$ORPHAN_ROOT" "$ORPHAN_CHILD" >> "$TMP_ROOT/pids"
record_pid "$ORPHAN" "$ORPHAN_ROOT"
out=$("$LIVE_LAB" down "$ORPHAN" 2>&1)
expect_code 0 "$?" "down waits for a reparented child: $out"
assert_equals rewrote "$(cat "$TMP_ROOT/orphan-rewrote" 2>/dev/null)" "child finished its TERM handler before cleanup"
lab_keys=$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));console.log(Object.keys(j.projects).filter(k=>k.startsWith(process.argv[2])).join(" "))' "$HOME/.claude.json" "$ORPHAN")
assert_equals "" "$lab_keys" "reparented child cannot re-add trust after down"
pass "down waits for captured descendants after their root exits"

# A recorded process can create a new descendant only after TERM arrives.
LATE=$(make_lab late claude)
cat > "$TMP_ROOT/late-rewriter.sh" <<'SH'
store=$1 key=$2 marker=$3
trap 'bash -c '\''sleep 1; node -e "const fs=require(\"node:fs\");const [s,k]=process.argv.slice(1);const j=JSON.parse(fs.readFileSync(s,\"utf8\"));j.projects[k]={hasTrustDialogAccepted:true};fs.writeFileSync(s,JSON.stringify(j))" "$1" "$2"'\'' _ "$store" "$key" >/dev/null 2>&1 & echo $! > "$marker"; exit 0' TERM
echo ready > "$marker.ready"
while :; do sleep 0.1; done
SH
start_group bash "$TMP_ROOT/late-rewriter.sh" "$HOME/.claude.json" "$LATE/home" "$TMP_ROOT/late-child"
LATE_ROOT=$!
printf '%s\n' "$LATE_ROOT" >> "$TMP_ROOT/pids"
for ((attempt=0; attempt<50; attempt++)); do
  [ -s "$TMP_ROOT/late-child.ready" ] && break
  sleep 0.1
done
assert_present "$TMP_ROOT/late-child.ready" "TERM fixture installed its handler before down"
record_pid "$LATE" "$LATE_ROOT"
out=$("$LIVE_LAB" down "$LATE" 2>&1)
expect_code 0 "$?" "down waits for a child born during TERM: $out"
assert_present "$TMP_ROOT/late-child" "TERM handler spawned a child"
LATE_CHILD=$(cat "$TMP_ROOT/late-child")
printf '%s\n' "$LATE_CHILD" >> "$TMP_ROOT/pids"
case "$(ps -o stat= -p "$LATE_CHILD" 2>/dev/null | awk '{$1=$1; print}')" in ''|Z*) ;; *) fail "down leaves a TERM-spawned child alive" ;; esac
lab_keys=$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));console.log(Object.keys(j.projects).filter(k=>k.startsWith(process.argv[2])).join(" "))' "$HOME/.claude.json" "$LATE")
assert_equals "" "$lab_keys" "TERM-spawned child cannot re-add trust after down"
pass "down tracks descendants spawned during TERM"

# A reused PID with a different start time must not own its new process tree.
Y=$(make_lab y claude)
# shellcheck disable=SC2016 # Positional parameters expand in the launched shell.
start_group bash -c 'sleep 600 & echo $! > "$1"; wait' _ "$TMP_ROOT/reused-child"; REUSED=$!
until [ -s "$TMP_ROOT/reused-child" ]; do sleep 0.1; done
REUSED_CHILD=$(cat "$TMP_ROOT/reused-child")
printf '%s\n%s\n' "$REUSED" "$REUSED_CHILD" >> "$TMP_ROOT/pids"
printf 'launch_pid=%s\nlaunch_start=Mon Jan  1 00:00:00 1990\n' "$REUSED" >> "$Y/.fm-live-lab"
out=$("$LIVE_LAB" down "$Y" 2>&1)
expect_code 0 "$?" "down skips the mismatched root: $out"
kill -0 "$REUSED" 2>/dev/null || fail "down killed a reused PID"
kill -0 "$REUSED_CHILD" 2>/dev/null || fail "down killed the reused PID's child"
pass "down ignores roots with mismatched start times"

# A group observed empty must not be admitted again if its id is later reused.
# The ps shim hides the first group's only member on pass 2, then presents an
# unrelated process under that pgid on pass 3 while another lab group waits.
GROUP_REUSE=$(make_lab group-reuse claude)
start_group python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(600)'
GROUP_ROOT=$!
start_group python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(600)'
WAIT_ROOT=$!
sleep 0.2
printf '%s\n%s\n' "$GROUP_ROOT" "$WAIT_ROOT" >> "$TMP_ROOT/pids"
record_pid "$GROUP_REUSE" "$GROUP_ROOT"
record_pid "$GROUP_REUSE" "$WAIT_ROOT"
sleep 600 >/dev/null 2>&1 &
GROUP_OUTSIDER=$!
printf '%s\n' "$GROUP_OUTSIDER" >> "$TMP_ROOT/pids"
GROUP_ID=$(ps -o pgid= -p "$GROUP_ROOT" | awk '{$1=$1; print}')
mkdir -p "$TMP_ROOT/group-ps-bin"
cat > "$TMP_ROOT/group-ps-bin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -axo ] && [ "${2:-}" = 'pid=,ppid=,pgid=,stat=,lstart=' ]; then
  count=$(cat "$PS_SCAN_COUNT" 2>/dev/null || echo 0)
  count=$((count + 1))
  echo "$count" > "$PS_SCAN_COUNT"
  "$REAL_PS" "$@" | awk -v scan="$count" -v root="$PS_GROUP_ROOT" -v outsider="$PS_OUTSIDER" -v group="$PS_GROUP_ID" '
    scan >= 2 && $1 == root { next }
    scan >= 3 && $1 == outsider { $3=group }
    { print }
  '
else
  "$REAL_PS" "$@"
fi
SH
chmod +x "$TMP_ROOT/group-ps-bin/ps"
out=$(REAL_PS="$(command -v ps)" PS_SCAN_COUNT="$TMP_ROOT/group-scan-count" PS_GROUP_ROOT="$GROUP_ROOT" PS_OUTSIDER="$GROUP_OUTSIDER" PS_GROUP_ID="$GROUP_ID" PATH="$TMP_ROOT/group-ps-bin:$PATH" "$LIVE_LAB" down "$GROUP_REUSE" 2>&1)
expect_code 0 "$?" "down ignores a reused group id: $out"
[ "$(cat "$TMP_ROOT/group-scan-count")" -ge 3 ] || fail "fixture did not expose the reused group id"
kill -0 "$GROUP_OUTSIDER" 2>/dev/null || fail "down signalled an unrelated process with a reused group id"
pass "down drops empty groups permanently before their ids can be reused"

# Simulate a recorded PID changing identity after TERM: the first process
# snapshot matches its start time, subsequent snapshots describe a reused PID.
Z=$(make_lab z claude)
start_group python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(600)'
REPLACED=$!
printf '%s\n' "$REPLACED" >> "$TMP_ROOT/pids"
record_pid "$Z" "$REPLACED"
mkdir -p "$TMP_ROOT/ps-bin"
printf '%s\n' "$REPLACED" > "$TMP_ROOT/replaced-pid"
cat > "$TMP_ROOT/ps-bin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -o ] && [ "${2:-}" = 'stat=,lstart=' ] && [ "${4:-}" = "$(cat "$PS_TARGET")" ]; then
  count=$(cat "$PS_COUNT" 2>/dev/null || echo 0)
  echo "$((count + 1))" > "$PS_COUNT"
  if [ "$count" -gt 0 ]; then
    echo 'S Mon Jan 1 00:00:00 1990'
  else
    "$REAL_PS" "$@"
  fi
else
  "$REAL_PS" "$@"
fi
SH
chmod +x "$TMP_ROOT/ps-bin/ps"
start=$(date +%s)
out=$(REAL_PS="$(command -v ps)" PS_COUNT="$TMP_ROOT/ps-count" PS_TARGET="$TMP_ROOT/replaced-pid" PATH="$TMP_ROOT/ps-bin:$PATH" "$LIVE_LAB" down "$Z" 2>&1)
expect_code 0 "$?" "down must not treat the changed PID as a survivor: $out"
[ "$(( $(date +%s) - start ))" -lt 8 ] || fail "down waited on a PID with a different start time"
kill -0 "$REPLACED" 2>/dev/null || fail "down killed a PID after its recorded identity changed"
kill "$REPLACED" 2>/dev/null || true
pass "down revalidates process identity during its bounded wait"

printf '{"trusted":["/somewhere"]}\n' > "$HOME/.pi/agent/trust.json"
run_check "$P"
assert_contains "$CHECK_OUT" "fail trust: the Pi trust store changed since up began" "a written Pi trust store is caught"
pass "trust fails on Pi when the lab wrote the persistent Pi trust store"

out=$("$LIVE_LAB" down "$P" 2>&1)
expect_code 1 "$?" "down reports a changed Pi trust store"
assert_contains "$out" "the Pi trust store changed since up began; left as is" "the Pi trust change is named"
assert_absent "$P" "the lab is still removed"
assert_equals '{"trusted":["/somewhere"]}' "$(cat "$HOME/.pi/agent/trust.json")" "down never rewrites the Pi trust store"
pass "down removes the lab but reports, without reverting, a written Pi trust store"

# ---- up argument safety -----------------------------------------------------

EXISTING="$TMP_ROOT/existing"
mkdir -p "$EXISTING/keep"
out=$("$LIVE_LAB" up --harness claude "$EXISTING" 2>&1)
expect_code 1 "$?" "up refuses an existing lab root"
assert_contains "$out" "a lab root must not exist yet" "the refusal names the existing root"
assert_present "$EXISTING/keep" "a refused up touches nothing"
out=$("$LIVE_LAB" up --harness codex "$TMP_ROOT/new" 2>&1)
expect_code 1 "$?" "up refuses an unsupported harness"
assert_absent "$TMP_ROOT/new" "a refused harness creates nothing"
pass "up refuses an existing root and an unsupported harness"

# up persists full-width, distinct task IDs even when checkout fails before
# launching a harness; down can still clean this partial lab.
PARTIAL="$TMP_ROOT/partial-lab"
mkdir -p "$TMP_ROOT/stub-bin"
cat > "$TMP_ROOT/stub-bin/claude" <<'SH'
#!/bin/sh
: > "$FM_HOME/state/.session-start-complete"
exec sleep 45 >/dev/null 2>&1
SH
chmod +x "$TMP_ROOT/stub-bin/claude"
out=$(PATH="$TMP_ROOT/stub-bin:$PATH" "$LIVE_LAB" up --harness claude --source "$TMP_ROOT/missing-origin" "$PARTIAL" 2>&1)
expect_code 1 "$?" "an unavailable source stops up before launch"
assert_present "$PARTIAL/.fm-live-lab" "up recorded its selected task IDs"
ids=$(awk -F= '/^(mate_id|worker_id)=/ {print $2}' "$PARTIAL/.fm-live-lab")
if ! printf '%s\n' "$ids" | grep -Eq '^lab[0-9a-f]{12}-(mate|worker)$'; then fail "task IDs need twelve nonce hex digits: $ids"; fi
assert_equals 2 "$(printf '%s\n' "$ids" | grep -Ec '^lab[0-9a-f]{12}-(mate|worker)$')" "both mate and worker use twelve nonce digits"
out=$($LIVE_LAB down "$PARTIAL" 2>&1)
expect_code 0 "$?" "down cleans a lab whose checkout failed: $out"
assert_absent "$PARTIAL" "partial lab removed"
pass "up gives both task IDs a long nonce and down cleans partial setup"

# A rival Claude writer drops the newly registered primary key once. The
# stand-in primary checks the store on startup, while the readiness probe fails.
UPSRC="$TMP_ROOT/up-source"
mkdir -p "$UPSRC"
cp -R "$ROOT/bin" "$UPSRC/bin"
cp "$ROOT/AGENTS.md" "$UPSRC/AGENTS.md"
git -C "$UPSRC" init -q -b main
git -C "$UPSRC" add -A
git -C "$UPSRC" -c user.name=t -c user.email=t@example.invalid commit -qm source
# A worker can have written its first status while still working. That must
# not hold up the Claude primary; the generated brief must ask it to end its
# turn on the gate instead of running a foreground polling command.
WORKSRC="$TMP_ROOT/worker-source"
cp -R "$UPSRC" "$WORKSRC"
cat > "$WORKSRC/bin/fm-brief.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p "$FM_HOME/data/$1"
printf '{TASK}\n{FIRSTMATE_SPEC}\n' > "$FM_HOME/data/$1/brief.md"
SH
cat > "$WORKSRC/bin/fm-tasks-axi.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$WORKSRC/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
id=$1
# The lab's explicit socket, never TMUX_TMPDIR alone, which falls back to the
# user's default server when its directory is missing.
lab_tmux() { tmux -S "${TMUX_TMPDIR:?}/tmux-$(id -u)/default" "$@"; }
lab_tmux new-window -d -t firstmate: -n "fm-$id" -c "$FM_HOME" 'exec sleep 45 >/dev/null 2>&1' || exit 1
# A missing =name can silently resolve to the current window: verify the name.
for (( n=0; n<30; n++ )); do
  if lab_tmux list-windows -t firstmate -F '#{window_name}' | grep -Fxq "fm-$id"; then
    pid=$(lab_tmux display-message -p -t "firstmate:=fm-$id" '#{pane_pid}')
    [ -z "$pid" ] || break
  fi
  sleep 0.1
done
[ -n "${pid:-}" ] || exit 1
printf 'window=firstmate:fm-%s\n' "$id" > "$FM_HOME/state/$id.meta"
printf 'working [at=1]: setting up\n' > "$FM_HOME/state/$id.status"
SH
chmod +x "$WORKSRC/bin/"{fm-brief,fm-tasks-axi,fm-spawn}.sh
git -C "$WORKSRC" add -A
git -C "$WORKSRC" -c user.name=t -c user.email=t@example.invalid commit -qm stubs
W="$TMP_ROOT/worker-up"
out=$(SHELL=/bin/sh PATH="$TMP_ROOT/stub-bin:$PATH" "$LIVE_LAB" up --harness claude --worker --source "$WORKSRC" --timeout 0 "$W" 2>&1)
expect_code 1 "$?" "unanswered probe leaves worker lab for inspection: $out"
assert_contains "$out" "primary: claude" "the unparked worker did not block primary launch"
assert_contains "$out" "gate: $W/home/data/" "up shows the gate path"
assert_contains "$out" "then message the worker to resume" "up explains the release message"
worker_id=$(sed -n 's/^worker_id=//p' "$W/.fm-live-lab")
brief=$(<"$W/home/data/$worker_id/brief.md")
assert_contains "$brief" "append one paused status line naming the gate file" "worker declares its wait"
assert_contains "$brief" "and end your turn" "worker ends its waiting turn"
assert_contains "$brief" "Do not poll or sleep in a foreground command" "worker does not run a blocking wait"
assert_contains "$brief" "When a later message resumes you, check that" "worker checks the gate after a message"
assert_contains "$out" "fail worker: the worker is not currently parked" "final readiness remains strict"
node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.exit(j.projects?.[process.argv[2]]?.hasTrustDialogAccepted===true?0:1)' "$HOME/.claude.json" "$W/home" || fail "primary trust was not registered before launch"
out=$("$LIVE_LAB" down "$W" 2>&1)
expect_code 0 "$?" "down cleans the worker lab: $out"
pass "up launches primary after worker status without weakening final parked readiness"

# If a spawn reports success without a pane, fail at the missing PID rather
# than invoking ps with an empty -p argument or waiting for readiness.
cat > "$WORKSRC/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
id=$1
printf 'window=firstmate:fm-%s\n' "$id" > "$FM_HOME/state/$id.meta"
printf 'working [at=1]: setting up\n' > "$FM_HOME/state/$id.status"
SH
git -C "$WORKSRC" add bin/fm-spawn.sh
git -C "$WORKSRC" -c user.name=t -c user.email=t@example.invalid commit -qm missing-pane
NO_PANE="$TMP_ROOT/no-pane"
out=$(SHELL=/bin/sh PATH="$TMP_ROOT/stub-bin:$PATH" "$LIVE_LAB" up --harness claude --worker --source "$WORKSRC" --timeout 0 "$NO_PANE" 2>&1)
expect_code 1 "$?" "up refuses a worker without a pane PID: $out"
assert_contains "$out" "cannot record lab process: missing or invalid PID ''" "missing pane PID fails at launch recording"
assert_not_contains "$out" "list of process IDs must follow -p" "ps never receives an empty PID"
out=$("$LIVE_LAB" down "$NO_PANE" 2>&1)
expect_code 0 "$?" "down cleans the missing-pane lab: $out"
pass "up fails immediately when a spawned worker has no pane PID"

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
sleep 1.5
if node -e 'const [s,k]=process.argv.slice(1);const j=JSON.parse(require("node:fs").readFileSync(s,"utf8"));process.exit(j.projects?.[k]?.hasTrustDialogAccepted===true?0:1)' "$HOME/.claude.json" "$FM_HOME"; then
  echo present > "$FM_HOME/../claude-launch-trust"
else
  echo absent > "$FM_HOME/../claude-launch-trust"
fi
: > "$FM_HOME/state/.session-start-complete"
exec sleep 45 >/dev/null 2>&1
SH
chmod +x "$FAKEBIN/claude"
U="$TMP_ROOT/up-lab"
(
  end=$(( $(date +%s) + 120 ))
  until node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.exit(j.projects?.[process.argv[2]]?1:0)' "$HOME/.claude.json" "$U/home" 2>/dev/null; do
    [ "$(date +%s)" -lt "$end" ] || exit 1
    sleep 0.05
  done
  sleep 0.5
  node -e 'const fs=require("node:fs");const [s,k]=process.argv.slice(1);const j=JSON.parse(fs.readFileSync(s,"utf8"));delete j.projects[k];fs.writeFileSync(s,JSON.stringify(j))' "$HOME/.claude.json" "$U/home"
  echo dropped > "$TMP_ROOT/rival-dropped"
) &
RIVAL=$!
printf '%s\n' "$RIVAL" >> "$TMP_ROOT/pids"
out=$(SHELL=/bin/sh PATH="$FAKEBIN:$PATH" "$LIVE_LAB" up --harness claude --source "$UPSRC" --ref HEAD --timeout 1 "$U" 2>&1)
expect_code 1 "$?" "stand-in primary does not answer probe"
wait "$RIVAL" 2>/dev/null || true
assert_equals dropped "$(cat "$TMP_ROOT/rival-dropped" 2>/dev/null)" "rival dropped primary trust once"
assert_equals present "$(cat "$U/claude-launch-trust" 2>/dev/null)" "primary launched trusted after the rival write"
assert_contains "$out" "ok trust: $U/home is trusted in the Claude store" "readiness sees primary trust"
out=$("$LIVE_LAB" down "$U" 2>&1)
expect_code 0 "$?" "down removes the up-built lab: $out"
pass "up re-registers primary trust after a concurrent Claude write"

# ---- fm-claude-trust.sh --lab-home -------------------------------------------

T="$TMP_ROOT/trust"
mkdir -p "$T/config"
"$ROOT/bin/fm-lab-home.sh" create "$T/home" >/dev/null
cp "$ROOT/AGENTS.md" "$T/home/AGENTS.md"
mkdir -p "$T/home/bin"
git -C "$T/home" init -q -b main
out=$(CLAUDE_CONFIG_DIR="$T/config" "$TRUST" --lab-home "$T/home" 2>&1)
expect_code 0 "$?" "a marked lab primary checkout is trusted: $out"
TH=$(cd -P "$T/home" && pwd -P)
node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.exit(j.projects[process.argv[2]].hasTrustDialogAccepted===true&&!("hasClaudeMdExternalIncludesApproved" in j.projects[process.argv[2]])?0:1)' \
  "$T/config/.claude.json" "$TH" || fail "lab-home trust is trust-only"

mkdir -p "$T/plain/bin"
cp "$ROOT/AGENTS.md" "$T/plain/AGENTS.md"
git -C "$T/plain" init -q -b main
out=$(CLAUDE_CONFIG_DIR="$T/config" "$TRUST" --lab-home "$T/plain" 2>&1)
expect_code 1 "$?" "an unmarked checkout is refused"
assert_contains "$out" "carries no lab-home marker" "the refusal names the missing marker"

fm_git_worktree "$T/proj" "$T/wt" lab-trust-wt
printf 'fm-lab-home v1\n' > "$T/wt/.fm-lab-home"
cp "$ROOT/AGENTS.md" "$T/wt/AGENTS.md"
mkdir -p "$T/wt/bin"
out=$(CLAUDE_CONFIG_DIR="$T/config" "$TRUST" --lab-home "$T/wt" 2>&1)
expect_code 1 "$?" "a linked worktree is refused"
assert_contains "$out" "is a linked worktree" "the refusal names the linked worktree"

rm "$T/home/.fm-lab-home"
ln -s "$T/wt/.fm-lab-home" "$T/home/.fm-lab-home"
out=$(CLAUDE_CONFIG_DIR="$T/config" "$TRUST" --lab-home "$T/home" 2>&1)
expect_code 1 "$?" "a symlinked marker is refused"
assert_contains "$out" "is a symlink" "the refusal names the symlink"
pass "fm-claude-trust.sh --lab-home trusts only a marked lab primary checkout"
