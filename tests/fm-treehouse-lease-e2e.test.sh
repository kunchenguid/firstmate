#!/usr/bin/env bash
# Live regression for the durable Treehouse lease every crewmate and scout slot
# is taken under (bin/fm-wake-lib.sh owns the lease contract; bin/fm-spawn.sh
# and bin/fm-teardown.sh are its two reclaim points).
#
# This drives the REAL treehouse binary against a scratch pool, and the real
# spawn and teardown scripts against a real tmux server on a private socket,
# because the whole point of the change is what Treehouse's own persistent
# state says about a slot once its worker is gone: a fake pool can only
# confirm the assumption written into the fake. The stand-in harness is a
# process named `codex` that sleeps, so the pane classifier sees a live
# harness without any model tokens being spent.
#
# It lives in the real-herdr-gated family only because that is the one CI lane
# that installs a pinned Treehouse (bin/fm-install-treehouse.sh); it needs no
# Herdr, and fm_live_gate makes it run wherever treehouse and tmux are
# installed and skip elsewhere.
#
# What it proves, on the installed Treehouse version it names:
#   1. Treehouse's own semantics the design rests on: a slot leased with no
#      live process is never handed to the next lease, `return
#      --if-lease-holder` refuses another holder's lease whatever --force says,
#      and the read helpers report mine/other/unleased from `status --json`.
#   2. The cause of the 2026-09-11/12 reassignments: a slot taken by the
#      interactive pane-driven `treehouse get` reads available the moment its
#      process is gone, so the next lease is handed that same slot.
#   3. A real spawn leases its slot under the task id and lands the pane in
#      that slot and not in the project, through a nested shell that leaves
#      the pane's top shell in the project; a relaunch reuses that same leased
#      slot; a second spawn while the first task's window is already gone gets
#      a different slot; and a real teardown returns the slot with the holder
#      check, reaping only the nested shell and never the pane's top shell.
#   4. The reassigned record: a task whose recorded slot is now leased to
#      another task cannot relaunch into it, and its teardown finishes only its
#      own cleanup, leaving the other task's lease, copy, and worker untouched.
#   5. A spawn that aborts after leasing returns its own lease, so the slot is
#      available again rather than leased to a task no record describes.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_LIVE_TREEHOUSE treehouse tmux

REAL_TMUX=$(command -v tmux)
REAL_TREEHOUSE=$(command -v treehouse)
TREEHOUSE_VERSION=$("$REAL_TREEHOUSE" --version 2>/dev/null | tr -d '[:space:]')
TMP_ROOT=$(fm_test_tmproot fm-treehouse-lease-e2e)
SOCKET="fm-treehouse-lease-$$"

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Every treehouse call is logged, then forwarded to the real binary; tmux is
# pinned to the private socket with a config that forces a plain bash pane.
SHIM="$TMP_ROOT/shim"
TREEHOUSE_LOG="$TMP_ROOT/treehouse-calls.log"
mkdir -p "$SHIM"
printf 'set -g default-shell /bin/bash\nset -g default-command "/bin/bash --noprofile --norc"\n' > "$TMP_ROOT/tmux.conf"
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec '$REAL_TMUX' -L '$SOCKET' -f '$TMP_ROOT/tmux.conf' "\$@"
SH
cat > "$SHIM/treehouse" <<SH
#!/usr/bin/env bash
{ printf 'treehouse'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\\n'; } >> '$TREEHOUSE_LOG'
exec '$REAL_TREEHOUSE' "\$@"
SH
# The stand-in harness: exec's a symlink to sleep NAMED codex so the pane's
# foreground process reads as the harness to the tmux classifier.
mkdir -p "$SHIM/agent"
ln -s "$(command -v sleep)" "$SHIM/agent/codex"
printf '#!/usr/bin/env bash\nexec "%s/agent/codex" 600\n' "$SHIM" > "$SHIM/codex"
chmod +x "$SHIM/tmux" "$SHIM/treehouse" "$SHIM/codex"
export PATH="$SHIM:$PATH"

treehouse_calls() { cat "$TREEHOUSE_LOG" 2>/dev/null || true; }

# make_lab <name> <max_trees> lays out an origin, a project clone whose
# treehouse.toml roots the pool inside the lab, and a firstmate home. Prints
# the lab path (physical, so record comparisons never see a symlinked prefix).
make_lab() {
  local name=$1 max_trees=$2 lab
  lab="$TMP_ROOT/$name"
  mkdir -p "$lab/home/data" "$lab/home/state" "$lab/home/config" "$lab/user-home"
  git init -q -b main "$lab/origin"
  git -C "$lab/origin" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m init
  git -C "$lab/origin" config receive.denyCurrentBranch ignore
  git clone -q "$lab/origin" "$lab/project"
  printf 'max_trees = %s\nroot = "%s/pool-root"\n' "$max_trees" "$lab" > "$lab/project/treehouse.toml"
  git -C "$lab/project" add treehouse.toml
  git -C "$lab/project" -c user.name=test -c user.email=test@example.invalid commit -qm treehouse-config
  git -C "$lab/project" push -q origin main
  printf 'codex\n' > "$lab/home/config/crew-harness"
  touch "$lab/home/state/.last-watcher-beat"
  printf '%s\n' "$lab"
}

brief_for() {  # <lab> <id>
  fm_test_spawn_brief "$1/home" "$2" "Live Treehouse lease check for $2."
}

run_spawn() {  # <lab> <id> [args...]
  local lab=$1 id=$2
  shift 2
  env -u TMUX -u TMUX_PANE FM_HOME="$lab/home" HOME="$lab/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" "$lab/project" "$@" 2>&1
}

run_relaunch() {  # <lab> <id>
  env -u TMUX -u TMUX_PANE FM_HOME="$1/home" HOME="$1/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$2" --relaunch 2>&1
}

run_teardown() {  # <lab> <id> [--force]
  local lab=$1 id=$2
  shift 2
  env -u TMUX -u TMUX_PANE FM_HOME="$lab/home" "$ROOT/bin/fm-teardown.sh" "$id" "$@" 2>&1
}

meta_worktree() { grep '^worktree=' "$1/home/state/$2.meta" | cut -d= -f2-; }
pane_path() { "$REAL_TMUX" -L "$SOCKET" display-message -p -t "firstmate:fm-$1" '#{pane_current_path}' 2>/dev/null || true; }
window_exists() { "$REAL_TMUX" -L "$SOCKET" list-windows -t firstmate -F '#{window_name}' 2>/dev/null | grep -Fqx "fm-$1"; }
pane_harness_pid() {  # <task> ; the codex stand-in under the pane's nested shell
  local top nested pid
  top=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "firstmate:fm-$1" '#{pane_pid}' 2>/dev/null) || return 1
  for nested in $(pgrep -P "$top" 2>/dev/null); do
    for pid in $(pgrep -P "$nested" 2>/dev/null); do
      [ "$(ps -o comm= -p "$pid" 2>/dev/null | sed 's#.*/##')" = codex ] || continue
      printf '%s\n' "$pid"
      return 0
    done
  done
  return 1
}
lease_holder_of() {  # <lab> <slot> ; Treehouse's own holder label, or empty
  ( cd "$1/project" && "$REAL_TREEHOUSE" status --json 2>/dev/null ) \
    | node -e '
const entries = JSON.parse(require("fs").readFileSync(0, "utf8"));
const want = process.argv[1];
for (const e of entries) if (e.path === want && e.status === "leased") process.stdout.write(e.lease_holder);
' "$2"
}
slot_status_of() {  # <lab> <slot> ; Treehouse's own status word
  ( cd "$1/project" && "$REAL_TREEHOUSE" status --json 2>/dev/null ) \
    | node -e '
const entries = JSON.parse(require("fs").readFileSync(0, "utf8"));
const want = process.argv[1];
for (const e of entries) if (e.path === want) process.stdout.write(e.status);
' "$2"
}
start_session() {  # <lab>
  "$REAL_TMUX" -L "$SOCKET" -f "$TMP_ROOT/tmux.conf" new-session -d -s firstmate -n idle -c "$1"
}
stop_session() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  local _i
  for _i in $(seq 1 50); do
    "$REAL_TMUX" -L "$SOCKET" list-sessions >/dev/null 2>&1 || return 0
    sleep 0.1
  done
}
wait_for_state() {  # <target> <state>
  local _i state
  for _i in $(seq 1 50); do
    state=$(fm_backend_agent_state tmux "$1")
    [ "$state" != "$2" ] || return 0
    sleep 0.2
  done
  fail "endpoint $1 never read '$2' (last: $state)"
}

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux

# --- 1. Treehouse's own lease semantics, through the helpers -----------------
test_lease_helpers_against_real_treehouse() {
  local lab slot_a slot_b out rc
  lab=$(make_lab helpers 2)
  # shellcheck source=bin/fm-wake-lib.sh
  FM_HOME="$lab/home" . "$ROOT/bin/fm-wake-lib.sh"

  slot_a=$(fm_treehouse_lease_acquire "$lab/project" task-a 2>/dev/null) \
    || fail "fm_treehouse_lease_acquire failed for task-a"
  [ -d "$slot_a" ] || fail "lease for task-a is not a directory: $slot_a"
  [ "$(lease_holder_of "$lab" "$slot_a")" = task-a ] \
    || fail "Treehouse does not record task-a as the holder of $slot_a"

  fm_treehouse_slot_lease_state "$lab/project" "$slot_a" task-a
  [ "$FM_TREEHOUSE_SLOT_LEASE" = mine ] || fail "own lease read as $FM_TREEHOUSE_SLOT_LEASE"
  fm_treehouse_slot_lease_state "$lab/project" "$slot_a" task-b
  [ "$FM_TREEHOUSE_SLOT_LEASE" = other ] || fail "another task's lease read as $FM_TREEHOUSE_SLOT_LEASE"
  [ "$FM_TREEHOUSE_SLOT_LEASE_HOLDER" = task-a ] || fail "holder evidence was '$FM_TREEHOUSE_SLOT_LEASE_HOLDER'"
  [ "$(fm_treehouse_lease_find "$lab/project" task-a)" = "$slot_a" ] \
    || fail "fm_treehouse_lease_find did not find task-a's slot"

  # No process lives in slot A; the durable lease alone keeps it out of the
  # next allocation.
  slot_b=$(fm_treehouse_lease_acquire "$lab/project" task-b 2>/dev/null) \
    || fail "fm_treehouse_lease_acquire failed for task-b"
  [ "$slot_b" != "$slot_a" ] || fail "Treehouse handed task-a's leased slot to task-b"

  set +e
  out=$(fm_treehouse_lease_release "$lab/project" "$slot_a" task-b 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a return under the wrong holder succeeded"
  assert_contains "$out" "lease holder does not match" "wrong-holder return did not name the precondition"
  [ "$(lease_holder_of "$lab" "$slot_a")" = task-a ] || fail "a refused return still released task-a's lease"

  fm_treehouse_lease_release "$lab/project" "$slot_a" task-a >/dev/null 2>&1 \
    || fail "a return under the right holder failed"
  fm_treehouse_slot_lease_state "$lab/project" "$slot_a" task-a
  [ "$FM_TREEHOUSE_SLOT_LEASE" = unleased ] || fail "returned slot read as $FM_TREEHOUSE_SLOT_LEASE"
  fm_treehouse_lease_release "$lab/project" "$slot_b" task-b >/dev/null 2>&1 \
    || fail "cleanup return for task-b failed"
  pass "Treehouse $TREEHOUSE_VERSION: a leased slot is never handed on, a wrong holder is refused, and the helpers read mine/other/unleased"
}

# --- 2. The cause: a process lease is gone with its process ------------------
test_pane_driven_get_releases_with_its_process() {
  local lab slot pid_file get_pid sub_pid status next _i
  lab=$(make_lab process-lease 1)
  pid_file="$lab/subshell.pid"
  cat > "$lab/subshell" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$\$" > '$pid_file'
exec sleep 600
SH
  chmod +x "$lab/subshell"
  ( cd "$lab/project" && SHELL="$lab/subshell" "$REAL_TREEHOUSE" get </dev/null >"$lab/get.out" 2>&1 & echo $! > "$lab/get.pid" )
  for _i in $(seq 1 100); do
    [ -s "$pid_file" ] && break
    sleep 0.1
  done
  [ -s "$pid_file" ] || fail "the interactive treehouse get never opened its subshell: $(cat "$lab/get.out")"
  get_pid=$(cat "$lab/get.pid")
  sub_pid=$(cat "$pid_file")
  slot=$(ls -d "$lab"/pool-root/.treehouse/*/1/project)
  status=$(slot_status_of "$lab" "$slot")
  [ "$status" = in-use ] || fail "slot with a live process lease read '$status', not in-use"

  kill -9 "$get_pid" "$sub_pid" 2>/dev/null || true
  wait "$get_pid" 2>/dev/null || true
  # The dead processes take a moment to leave the process table Treehouse
  # consults; what matters is where the status settles, not the first read.
  status=
  for _i in $(seq 1 50); do
    status=$(slot_status_of "$lab" "$slot")
    [ "$status" != available ] || break
    sleep 0.2
  done
  [ "$status" = available ] || fail "slot whose process lease died read '$status', not available"
  next=$( cd "$lab/project" && "$REAL_TREEHOUSE" get --lease --lease-holder newcomer 2>/dev/null )
  [ "$next" = "$slot" ] || fail "expected the next lease to be handed the dead-process slot, got '$next'"
  ( cd "$lab/project" && "$REAL_TREEHOUSE" return --force --if-lease-holder newcomer "$slot" >/dev/null 2>&1 ) || true
  pass "Treehouse $TREEHOUSE_VERSION: a pane-driven get's process lease reads available once its process is gone, and the next lease takes that slot"
}

# --- 3. Real spawn and teardown honour the lease -----------------------------
test_spawn_leases_and_teardown_returns_with_holder_check() {
  local lab wt1 wt2 out agent_pid top_pid top_cwd
  lab=$(make_lab spawn-teardown 3)
  brief_for "$lab" t1
  brief_for "$lab" t2
  start_session "$lab"
  : > "$TREEHOUSE_LOG"

  out=$(run_spawn "$lab" t1 --scout) || fail "spawn of t1 failed: $out"
  wt1=$(meta_worktree "$lab" t1)
  [ -n "$wt1" ] && [ -d "$wt1" ] || fail "t1 recorded no worktree: $out"
  [ "$(cd "$wt1" && pwd -P)" != "$(cd "$lab/project" && pwd -P)" ] \
    || fail "t1's recorded worktree is the spawning project itself"
  grep -Fxq "treehouse get --lease --lease-holder t1" "$TREEHOUSE_LOG" \
    || fail "spawn did not lease its slot under the task id: $(treehouse_calls)"
  ! grep -Fxq "treehouse get" "$TREEHOUSE_LOG" \
    || fail "spawn still ran the pane-driven treehouse get: $(treehouse_calls)"
  [ "$(lease_holder_of "$lab" "$wt1")" = t1 ] || fail "Treehouse does not record t1 as the holder of $wt1"
  [ "$(cd "$(pane_path t1)" && pwd -P)" = "$(cd "$wt1" && pwd -P)" ] \
    || fail "t1's pane sits in '$(pane_path t1)', not its leased slot $wt1"
  wait_for_state "firstmate:fm-t1" alive

  # The agent exits and is relaunched: the relaunch reads the slot's lease,
  # finds it t1's own, and puts the replacement agent back into that slot.
  # The harness runs under the nested shell the spawn opened in the slot, so
  # it is the pane top shell's grandchild; the nested shell itself is an
  # interactive shell that ignores TERM, which is the point of stopping the
  # harness rather than the shell.
  agent_pid=$(pane_harness_pid t1)
  [ -n "$agent_pid" ] || fail "could not find t1's harness process under its pane"
  kill -TERM "$agent_pid" 2>/dev/null || true
  wait_for_state "firstmate:fm-t1" dead
  : > "$TREEHOUSE_LOG"
  out=$(run_relaunch "$lab" t1) || fail "relaunch of t1 into its own leased slot failed: $out"
  wait_for_state "firstmate:fm-t1" alive
  [ "$(meta_worktree "$lab" t1)" = "$wt1" ] || fail "relaunch moved t1 off its leased slot"
  [ "$(lease_holder_of "$lab" "$wt1")" = t1 ] || fail "relaunch disturbed t1's lease"
  [ "$(cd "$(pane_path t1)" && pwd -P)" = "$(cd "$wt1" && pwd -P)" ] \
    || fail "the relaunched agent is not in t1's leased slot"
  ! grep -Fq "treehouse get" "$TREEHOUSE_LOG" \
    || fail "relaunch leased a new slot instead of reusing t1's: $(treehouse_calls)"
  ! grep -Fq "treehouse return" "$TREEHOUSE_LOG" \
    || fail "relaunch returned t1's slot: $(treehouse_calls)"

  # The worker vanishes without exiting cleanly - the shape of the incident.
  # With a durable lease the slot stays t1's, so the next spawn gets another.
  "$REAL_TMUX" -L "$SOCKET" kill-window -t firstmate:fm-t1
  [ "$(lease_holder_of "$lab" "$wt1")" = t1 ] \
    || fail "killing t1's window released its durable lease"
  out=$(run_spawn "$lab" t2 --scout) || fail "spawn of t2 failed: $out"
  wt2=$(meta_worktree "$lab" t2)
  [ -n "$wt2" ] && [ "$wt2" != "$wt1" ] || fail "t2 was handed t1's leased slot $wt1"
  [ "$(lease_holder_of "$lab" "$wt2")" = t2 ] || fail "Treehouse does not record t2 as the holder of $wt2"

  # t2's pane has the shape every spawned pane has: a top shell still in the
  # project with a nested shell in the slot. Teardown's slot cleanup (the
  # process reap and the holder-checked return) must only ever take the nested
  # shell and the harness, never the pane's top shell - a pane that loses its
  # only process closes on its own before the endpoint's focus-preserving
  # close runs, which is the Herdr focus drift measured on CI.
  top_pid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t firstmate:fm-t2 '#{pane_pid}')
  [ "$(cd "$(pane_path t2)" && pwd -P)" = "$(cd "$wt2" && pwd -P)" ] \
    || fail "t2's pane foreground is not in its leased slot"
  top_cwd=$(lsof -a -p "$top_pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
  [ -n "$top_cwd" ] || fail "could not read t2's top shell cwd (pid $top_pid)"
  [ "$(cd "$top_cwd" && pwd -P)" = "$(cd "$lab/project" && pwd -P)" ] \
    || fail "t2's top shell left the project for '$top_cwd'; the slot must be entered by a nested shell"

  # t1's teardown returns its own slot with the holder check; t2 is untouched.
  : > "$TREEHOUSE_LOG"
  out=$(run_teardown "$lab" t1 --force) || fail "teardown of t1 failed: $out"
  grep -Fxq "treehouse return --force --if-lease-holder t1 $wt1" "$TREEHOUSE_LOG" \
    || fail "teardown did not return t1's slot with the holder check: $(treehouse_calls)"
  [ "$(slot_status_of "$lab" "$wt1")" = available ] || fail "t1's slot is not available after teardown"
  [ "$(lease_holder_of "$lab" "$wt2")" = t2 ] || fail "t1's teardown disturbed t2's lease"
  window_exists t2 || fail "t1's teardown closed t2's window"
  [ ! -e "$lab/home/state/t1.meta" ] || fail "t1's record survived teardown"

  out=$(run_teardown "$lab" t2 --force) || fail "teardown of t2 failed: $out"
  [ "$(slot_status_of "$lab" "$wt2")" = available ] || fail "t2's slot is not available after teardown"
  case " $(printf '%s\n' "$out" | sed -n 's/^teardown: reaping leaked worktree process(es) for t2: //p' | tr '\n' ' ') " in
    *" $top_pid "*) fail "teardown's slot reap killed t2's top shell (pid $top_pid): $out" ;;
  esac
  stop_session
  pass "a real spawn leases its slot under the task id and lands there, a dead worker keeps its slot, and teardown returns with the holder check"
}

# --- 4. The reassigned record ---------------------------------------------
test_reassigned_record_cannot_relaunch_and_leaves_the_slot_alone() {
  local lab slot out rc pane_pid
  lab=$(make_lab reassigned 1)
  brief_for "$lab" stale
  brief_for "$lab" holder
  start_session "$lab"

  out=$(run_spawn "$lab" stale --scout) || fail "spawn of stale failed: $out"
  slot=$(meta_worktree "$lab" stale)
  wait_for_state "firstmate:fm-stale" alive
  # Construct the pre-fix world: the slot is released out from under the
  # record (its window dies and something returns it), then the pool hands
  # the same slot - the only one - to the next task.
  "$REAL_TMUX" -L "$SOCKET" kill-window -t firstmate:fm-stale
  ( cd "$lab/project" && "$REAL_TREEHOUSE" return --force --if-lease-holder stale "$slot" >/dev/null 2>&1 ) \
    || fail "could not release stale's lease to construct the reassignment"
  out=$(run_spawn "$lab" holder --scout) || fail "spawn of holder failed: $out"
  [ "$(meta_worktree "$lab" holder)" = "$slot" ] \
    || fail "the reassignment fixture did not reuse the slot: holder got $(meta_worktree "$lab" holder)"
  [ "$(lease_holder_of "$lab" "$slot")" = holder ] || fail "Treehouse does not record holder as the lease holder"
  wait_for_state "firstmate:fm-holder" alive
  pane_pid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t firstmate:fm-holder '#{pane_pid}')
  # The incident's shape: the task that took the slot next leaves no record
  # this home can reach, so the record scan sees nothing to contradict stale's
  # worktree= line and only Treehouse's lease can say the slot moved on.
  mv "$lab/home/state/holder.meta" "$lab/holder.meta.hidden"

  # stale's record still names the slot. Recreate its window as an idle shell
  # sitting in the slot, which is the only endpoint shape a relaunch accepts.
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t firstmate: -n fm-stale -c "$slot"
  wait_for_state "firstmate:fm-stale" dead
  set +e
  out=$(run_relaunch "$lab" stale)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "relaunch put stale's agent into holder's leased slot: $out"
  assert_contains "$out" "leased to 'holder'" "relaunch refusal did not name the lease holder"
  assert_contains "$out" "no longer stale's copy" "relaunch refusal did not explain the reassignment"
  kill -0 "$pane_pid" 2>/dev/null || fail "the refused relaunch disturbed holder's pane"

  # stale's teardown, without --force and as a scout with no report: only its
  # own cleanup runs, and the slot, its lease, and holder's worker are left.
  : > "$TREEHOUSE_LOG"
  set +e
  out=$(run_teardown "$lab" stale --force)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "teardown of the reassigned record failed: $out"
  assert_contains "$out" "leased to 'holder'" "teardown did not name the holder the slot was reassigned to"
  ! grep -Fq "treehouse return" "$TREEHOUSE_LOG" \
    || fail "teardown returned a slot leased to another task: $(treehouse_calls)"
  [ "$(lease_holder_of "$lab" "$slot")" = holder ] || fail "teardown released holder's lease"
  kill -0 "$pane_pid" 2>/dev/null || fail "teardown killed holder's pane"
  wait_for_state "firstmate:fm-holder" alive
  [ ! -e "$lab/home/state/stale.meta" ] || fail "stale's record survived its own cleanup"

  mv "$lab/holder.meta.hidden" "$lab/home/state/holder.meta"
  out=$(run_teardown "$lab" holder --force) || fail "teardown of holder failed: $out"
  [ "$(slot_status_of "$lab" "$slot")" = available ] || fail "holder's slot is not available after its teardown"
  stop_session
  pass "a record whose slot is leased to another task neither relaunches into it nor releases it, and only its own cleanup runs"
}

# --- 5. An aborted spawn returns its own lease ------------------------------
test_aborted_spawn_returns_its_lease() {
  local lab slot out rc
  lab=$(make_lab abort 1)
  brief_for "$lab" aborted
  start_session "$lab"
  # Warm the pool so Treehouse's own setup needs nothing from origin, then make
  # the base refresh fail after the lease: origin's HEAD points nowhere, so
  # freshen_spawn_worktree_base cannot resolve the default branch and refuses.
  slot=$( cd "$lab/project" && "$REAL_TREEHOUSE" get --lease --lease-holder warm 2>/dev/null )
  ( cd "$lab/project" && "$REAL_TREEHOUSE" return --force --if-lease-holder warm "$slot" >/dev/null 2>&1 ) \
    || fail "could not return the warm-up lease"
  git -C "$lab/origin" symbolic-ref HEAD refs/heads/nope
  : > "$TREEHOUSE_LOG"

  set +e
  out=$(run_spawn "$lab" aborted --mode no-mistakes --yolo off)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "spawn succeeded despite an unresolvable origin default branch: $out"
  grep -Fxq "treehouse get --lease --lease-holder aborted" "$TREEHOUSE_LOG" \
    || fail "the aborted spawn never leased a slot: $(treehouse_calls)"
  grep -Fxq "treehouse return --force --if-lease-holder aborted $slot" "$TREEHOUSE_LOG" \
    || fail "the aborted spawn did not return its lease with the holder check: $(treehouse_calls)"
  [ "$(slot_status_of "$lab" "$slot")" = available ] \
    || fail "the aborted spawn left its slot leased: $(slot_status_of "$lab" "$slot")"
  [ ! -e "$lab/home/state/aborted.meta" ] || fail "the aborted spawn published a record"
  assert_contains "$out" "returned task aborted's leased Treehouse slot" \
    "the aborted spawn did not report returning its lease"
  stop_session
  pass "a spawn that aborts after leasing returns its own lease, so the slot is available again"
}

test_lease_helpers_against_real_treehouse
test_pane_driven_get_releases_with_its_process
test_spawn_leases_and_teardown_returns_with_holder_check
test_reassigned_record_cannot_relaunch_and_leaves_the_slot_alone
test_aborted_spawn_returns_its_lease

echo "# all fm-treehouse-lease-e2e tests passed (treehouse $TREEHOUSE_VERSION)"
