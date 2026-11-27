#!/usr/bin/env bash
# fm-spawn.sh on the Herdr backend: a fresh task copy is leased durably and the
# pane's TOP-LEVEL shell is moved into it.
#
# Herdr restores a pane from the cwd of its top-level shell, and the pane's
# `cwd` field does not follow a nested shell (only `foreground_cwd` does). The
# interactive `treehouse get` runs a subshell, so the later `cd` landed inside
# it and a host restart reopened every worker in the primary clone. These cases
# pin the replacement: `treehouse get --lease`, then a cd the stub applies to
# the top-level shell, never the interactive form.
#
# Canned/stateful fakes only - never a real herdr session or a real pool.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-lease)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# make_lease_case <name>: a home, a project, and the leased task copy.
# The fake herdr models the two cwd fields: `cd` sent to the pane moves the
# restorable top-level cwd ($D/cwd) and, unless a nested shell is running,
# the foreground cwd with it. The fake treehouse opens that nested shell for
# the interactive form, which is exactly what must not be used.
make_lease_case() {
  local name=$1 harness=${2:-codex} dir home proj wt fb d
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/slot"
  d="$dir/fake"
  fb="$dir/fakebin"
  mkdir -p "$d" "$fb" "$dir/user-home"
  fm_test_spawn_home "$home" "$harness"
  fm_git_init_commit "$proj"
  git clone -q "$proj" "$wt"
  fm_test_spawn_brief "$home" "$name" "Exercise the Herdr task-copy lease for $name."
  printf '%s' "$proj" > "$d/cwd"
  printf '%s' "$proj" > "$d/fg"
  : > "$d/treehouse-log"
  : > "$d/herdr-log"
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/treehouse-log"
[ "${1:-}" != --root ] || shift 2
if [ -f "$D/model.json" ] && [ "${1:-}" = get ]; then
  id=${4:-}
  printf 'allocated %s\n' "$id" > "$D/events"
  if [ -p "$D/release-$id" ]; then
    read -r -t 60 _ < "$D/release-$id" || exit 1
  fi
fi
case "$*" in
  'get --lease '*) [ ! -f "$D/lease-fails" ] || { echo 'lease failed' >&2; exit 1; }
    printf '%s\n' "$FM_FAKE_SLOT" ;;
  'get') printf '%s' "$FM_FAKE_SLOT" > "$D/fg" ;;
  'return --force '*) : > "$D/returned" ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
if [ -f "$D/model.json" ]; then
  exec python3 "$FM_PROJECTION_FAKE" "$@"
fi
printf '%s\n' "$*" >> "$D/herdr-log"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n'
  exit 0
fi
[ "${1:-}" != server ] || exit 0
case "${1:-} ${2:-}" in
  'session list')
    [ ! -f "$D/session-lockable" ] || printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s/herdr.sock"}]}\n' "$D"
    exit 0 ;;
  'pane close') : > "$D/pane-gone"; exit 0 ;;
  'pane get')
    [ ! -f "$D/pane-gone" ] || { printf '{"error":{"code":"pane_not_found"}}\n'; exit 0; }
    if [ -f "$D/cd-sent" ] && [ -f "$D/delay-reads" ]; then
      reads=$(cat "$D/reads" 2>/dev/null || printf 0)
      reads=$((reads + 1)); printf '%s' "$reads" > "$D/reads"
      if [ "$reads" -ge "$(cat "$D/delay-reads")" ]; then
        bash -c 'cd -- "$1" && pwd -P > "$2"' bash "$FM_FAKE_SLOT" "$D/fg"
      fi
    fi
    printf '{"result":{"pane":{"pane_id":"%s","cwd":"%s","foreground_cwd":"%s"}}}\n' \
      "${3:-}" "$(cat "$D/cwd")" "$(cat "$D/fg")"
    exit 0 ;;
  'pane run' | 'pane send-text')
    payload=${4:-}
    case "$payload" in
      ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
    esac
    case "$payload" in
      'cd -- '*) path=${payload#cd -- }; path=${path#\'}; path=${path%\'}
        sends=$(cat "$D/cd-sends" 2>/dev/null || printf 0)
        sends=$((sends + 1)); printf '%s' "$sends" > "$D/cd-sends"
        : > "$D/cd-sent"
        [ ! -f "$D/never-moves" ] || exit 0
        [ ! -f "$D/delay-reads" ] || exit 0
        [ ! -f "$D/drop-first-cd" ] || [ "$sends" -gt 1 ] || exit 0
        bash -c 'cd -- "$1" && pwd -P > "$2"' bash "$path" "$D/cwd"
        cp "$D/cwd" "$D/fg" ;;
      *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
        [ ! -f "$D/launch-send-fails" ] || exit 1
        printf '%s\n' "$payload" > "$D/launched-command"
        : > "$D/herdr-agent-live" ;;
    esac
    exit 0 ;;
  'agent get')
    if [ -f "$D/herdr-agent-live" ]; then
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      printf '{"result":{"agent":{"agent_status":"shell-starting"}}}\n'
    fi
    exit 0 ;;
  'workspace list') printf '{"result":{"workspaces":[]}}\n'; exit 0 ;;
  'workspace create')
    printf '{"result":{"workspace":{"workspace_id":"wsnew"},"tab":{"tab_id":"seedtab"},"root_pane":{"pane_id":"%%1"}}}\n'
    exit 0 ;;
  'tab list') printf '{"result":{"tabs":[]}}\n'; exit 0 ;;
  'tab create')
    printf '{"result":{"tab":{"tab_id":"tabnew"},"root_pane":{"pane_id":"%%9"}}}\n'
    exit 0 ;;
esac
exit 0
SH
  cat > "$fb/polytoken" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"print models"*) printf 'zai/glm-5.3-flash\nzai/glm-5.3-flash(low)\n' ;;
esac
exit 0
SH
  chmod +x "$fb/treehouse" "$fb/herdr" "$fb/polytoken"
  fm_test_fake_sleep_noop "$fb"
  printf '%s\n' "$dir"
}

run_lease_spawn() {  # <case-dir> <id> [extra spawn args...]
  local dir=$1 id=$2
  shift 2
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_FAKE_SLOT="$dir/slot" HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 FM_PROJECTION_FAKE="$ROOT/tests/fixtures/herdr-projection-fake.py" \
    "$SPAWN" "$id" "$dir/project" --backend herdr --mode no-mistakes --yolo off "$@" 2>&1
}

test_fresh_spawn_leases_and_moves_the_top_level_shell() {
  local id=lease-top-level dir out status
  dir=$(make_lease_case "$id")
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"$'\n'"$out"
  grep -Fqx -- "get --lease --lease-holder $id" "$dir/fake/treehouse-log" \
    || fail "the task copy was not leased durably from Treehouse's default pool under the task id"
  ! grep -qx 'get' "$dir/fake/treehouse-log" \
    || fail "the interactive treehouse get opened a nested shell the restore cannot see"
  [ "$(cat "$dir/fake/cwd")" = "$dir/slot" ] \
    || fail "the pane's restorable top-level cwd is '$(cat "$dir/fake/cwd")', not the task copy"
  [ "$(cat "$dir/fake/cd-sends")" = 1 ] || fail "an immediately ready pane received a redundant cd"
  assert_grep "worktree=$dir/slot" "$dir/home/state/$id.meta" "meta did not record the leased copy"
  pass "a fresh herdr spawn leases the copy and moves the pane's top-level shell into it"
}

test_local_secondmate_leases_from_its_own_pool() {
  local id=lease-secondmate-pool dir out status root
  dir=$(make_lease_case "$id")
  mkdir -p "$dir/parent-home/state"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' \
    "$dir/parent-home" > "$dir/home/.fm-secondmate-parent"
  root=$(FM_HOME="$dir/home" /bin/bash -c '. "$1" && fm_treehouse_spawn_root "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$dir/home")
  [ -n "$root" ] || fail "a local secondmate spawn root was empty"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  expect_code 0 "$status" "a local secondmate's herdr spawn should succeed"$'\n'"$out"
  grep -Fqx -- "--root $root get --lease --lease-holder $id" "$dir/fake/treehouse-log" \
    || fail "a local secondmate's lease did not come from its own outside-home pool: $(cat "$dir/fake/treehouse-log")"
  assert_grep "worktree=$dir/slot" "$dir/home/state/$id.meta" "meta did not record the leased copy"
  pass "a local secondmate's herdr spawn leases its copy from a pool of its own clone"
}

test_failed_lease_refuses_without_a_record() {
  local id=lease-refused dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/lease-fails"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn went on without a leased copy"$'\n'"$out"
  assert_contains "$out" "treehouse get --lease failed" "the refusal did not name the failed lease"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused spawn published task metadata"
  ! grep -qx 'get' "$dir/fake/treehouse-log" || fail "a refused lease fell back to the interactive form"
  pass "a failed lease refuses the spawn and falls back to nothing"
}

test_aborted_spawn_names_the_lease_it_keeps() {
  local id=lease-aborted dir out status
  dir=$(make_lease_case "$id")
  echo dirty >> "$dir/slot/README.md"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched into a dirty leased copy"$'\n'"$out"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused spawn published task metadata"
  assert_contains "$out" "stays leased to $id" "an abort did not name the lease that outlives the pane"
  assert_contains "$out" "treehouse return --force $dir/slot" "an abort did not name the command that releases it"
  [ ! -e "$dir/fake/returned" ] || fail "an abort with the endpoint still open returned a slot the operator may want to inspect"
  pass "an aborted spawn keeps the lease and names the command that releases it"
}

test_rolled_back_spawn_after_launch_names_the_lease_it_keeps() {
  local id=lease-after-launch dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/launch-send-fails"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded although its launch was not delivered"$'\n'"$out"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "the failed spawn kept its task record"
  assert_contains "$out" "stays leased to $id" "a rolled-back spawn after its launch left the lease unnamed"
  assert_contains "$out" "treehouse return --force $dir/slot" "a rolled-back spawn after its launch did not name the command that releases it"
  [ ! -e "$dir/fake/returned" ] || fail "an abort with the endpoint still open returned a slot the operator may want to inspect"
  pass "a spawn rolled back after its launch keeps the lease and names the command that releases it"
}

# abort_polytoken_spawn <id> <dirty|launch-fails> [session-lockable]: a
# polytoken spawn aborts, either before its launch into a dirty copy or after a
# launch that was not delivered into a clean copy, and asks Herdr to close its
# own pane. Herdr closes it only when the session's presentation lock can be
# taken, which needs the session's socket; without it the kill refuses and the
# pane stays.
abort_polytoken_spawn() {
  local id=$1 dir
  dir=$(make_lease_case "$id" polytoken)
  case "$2" in
    dirty) echo dirty >> "$dir/slot/README.md" ;;
    launch-fails) : > "$dir/fake/launch-send-fails" ;;
  esac
  [ -z "${3:-}" ] || : > "$dir/fake/session-lockable"
  LEASE_OUT=$(run_lease_spawn "$dir" "$id" --model zai/glm-5.3-flash --effort low)
  LEASE_STATUS=$?
  LEASE_DIR=$dir
}

test_abort_returns_a_clean_lease_once_the_pane_is_gone() {
  local id=lease-pane-gone
  abort_polytoken_spawn "$id" launch-fails session-lockable
  [ "$LEASE_STATUS" -ne 0 ] || fail "spawn succeeded although its launch was not delivered"$'\n'"$LEASE_OUT"
  [ ! -e "$LEASE_DIR/home/state/$id.meta" ] || fail "the failed spawn kept its task record"
  assert_grep 'pane close' "$LEASE_DIR/fake/herdr-log" "the abort did not close its pane"$'\n'"$LEASE_OUT"
  [ -e "$LEASE_DIR/fake/returned" ] || fail "the abort kept a clean lease although its pane is gone"$'\n'"$LEASE_OUT"
  pass "an abort whose pane Herdr reports gone returns a clean lease"
}

test_abort_keeps_a_dirty_lease_once_the_pane_is_gone() {
  local id=lease-pane-gone-dirty
  abort_polytoken_spawn "$id" dirty session-lockable
  [ "$LEASE_STATUS" -ne 0 ] || fail "spawn launched into a dirty leased copy"$'\n'"$LEASE_OUT"
  assert_grep 'pane close' "$LEASE_DIR/fake/herdr-log" "the abort did not close its pane"$'\n'"$LEASE_OUT"
  [ ! -e "$LEASE_DIR/fake/returned" ] || fail "the abort returned a copy holding uncommitted work"
  assert_grep dirty "$LEASE_DIR/slot/README.md" "the abort discarded the copy's uncommitted work"
  assert_contains "$LEASE_OUT" "stays leased to $id" "an abort that kept a dirty copy did not name the lease it keeps"
  pass "an abort whose pane Herdr reports gone keeps a copy with uncommitted work leased"
}

test_abort_keeps_the_lease_while_the_pane_is_present() {
  local id=lease-close-refused
  abort_polytoken_spawn "$id" dirty
  [ "$LEASE_STATUS" -ne 0 ] || fail "spawn launched into a dirty leased copy"$'\n'"$LEASE_OUT"
  ! grep -q 'pane close' "$LEASE_DIR/fake/herdr-log" || fail "the kill closed the pane without its presentation lock"
  [ ! -e "$LEASE_DIR/fake/returned" ] || fail "the abort returned the lease while its pane is still present"
  assert_contains "$LEASE_OUT" "stays leased to $id" "an abort with its pane still present did not name the lease it keeps"
  pass "an abort whose pane is still present keeps the lease and names it"
}

test_delayed_worktree_entry() {
  local id=lease-delayed-cd dir out status
  dir=$(make_lease_case "$id")
  printf 25 > "$dir/fake/delay-reads"
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  expect_code 0 "$status" "delayed cwd should settle after the old 20-read limit"$'\n'"$out"
  [ "$(cat "$dir/fake/reads")" -ge 25 ] || fail "the delay was not exercised"
  [ "$(cat "$dir/fake/cd-sends")" = 2 ] || fail "cd was not resent exactly once"
  pass "Herdr waits past the former deadline for a delayed shell cwd"
}

test_dropped_worktree_entry() {
  local id=lease-dropped-cd dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/drop-first-cd"
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  expect_code 0 "$status" "a dropped first cd should recover"$'\n'"$out"
  [ "$(cat "$dir/fake/cd-sends")" = 2 ] || fail "cd was not resent exactly once"
  pass "Herdr recovers a dropped initial cd with one resend"
}

test_never_moving_worktree_entry() {
  local id=lease-stuck-cd dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/never-moves"
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  [ "$status" -ne 0 ] || fail "a pane that never moves was accepted"
  assert_contains "$out" "not its recorded worktree" "wrong cwd did not refuse"
  assert_contains "$out" "Herdr pane 'default:%9'" "refusal did not identify the pane"
  assert_contains "$out" "last foreground_cwd='$dir/project'" "refusal lost the last cwd"
  assert_contains "$out" "agent_status='shell-starting'" "refusal lost agent status"
  [ "$(cat "$dir/fake/cd-sends")" = 2 ] || fail "a stuck pane received more than one retry"
  [ ! -e "$dir/fake/launched-command" ] || fail "a harness started outside its copy"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused spawn published metadata"
  pass "Herdr refuses a never-moving pane with diagnostic context and no launch"
}

# Recovery lock contract (issue #6454): layout mutations serialize, unrelated
# allocation does not; default contention refuses, explicit waiting recovers.
# The oracle is the recorded exact task identity and the boundary command log,
# not implementation text. In particular a late release must fail the overlap.
PROJECTION_PIDS=()
projection_cleanup() {
  # Unblock every disposable child even when an assertion fails.
  printf 'release\n' >&7 2>/dev/null || true
  printf 'release\n' >&8 2>/dev/null || true
  local pid
  for pid in "${PROJECTION_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
  fm_test_cleanup
}

make_projection_pair() {
  A=$(make_lease_case "$1-a")
  B=$(make_lease_case "$1-b")
  rm -rf "$B/fake"
  ln -s "$A/fake" "$B/fake"
  D="$A/fake"
  mkfifo "$D/events" "$D/release-$1-a" "$D/release-$1-b"
  exec 9<>"$D/events" 8<>"$D/release-$1-a" 7<>"$D/release-$1-b"
  PROJECTION_PIDS=()
  trap projection_cleanup EXIT
  : > "$A/home/config/herdr-presentation-spaces"
  : > "$B/home/config/herdr-presentation-spaces"
  # Seed the serialized restart contract, not a previous invocation's output.
  FM_FAKE_DIR="$D" python3 "$ROOT/tests/fixtures/herdr-projection-fake.py" \
    seed "$1-b" "$B/home" "$B/project" bbbbbbbbbbbbbbbbbbbbbb >/dev/null
}

projection_event() {
  local event
  # Timeout is only a deadlock guard; all ordering is FIFO-driven.
  read -r -t 60 event <&9 || fail "missing event: $1"
  [ "$event" = "$1" ] || fail "expected '$1', got '$event': $(cat "$A/out" "$B/out" 2>/dev/null)"
}

projection_start() {
  local dir=$1 id=$2
  shift 2
  (run_lease_spawn "$dir" "$id" "$@" > "$dir/out"; status=$?
   printf 'done %s %s\n' "$id" "$status" > "$D/events"
   exit "$status") &
  PROJECTION_PIDS+=("$!")
}

projection_finish() {
  local pid
  for pid in "${PROJECTION_PIDS[@]}"; do
    wait "$pid" || fail "projection child failed: $(cat "$A/out" "$B/out" 2>/dev/null)"
  done
  PROJECTION_PIDS=()
  exec 7>&- 8>&- 9>&-
  trap fm_test_cleanup EXIT
}

projection_assert_replaced() {
  local dir=$1 id=$2
  grep -Fxq "herdr_workspace_id=husk-$id" "$dir/home/state/$id.meta" || fail "recovery flattened its workspace"
  grep -Fxq "pane close old-pane-$id" "$D/herdr-log" || fail "recovery did not close its exact old husk"
  python3 - "$dir/home/state/$id.meta" "$dir/home/state/$id.herdr-presentation" "$D/model.json" "$id" <<'PY' || fail "replacement endpoint contract failed"
import json, sys
meta, journal = [dict(line.rstrip('\n').split('=', 1) for line in open(p) if '=' in line) for p in sys.argv[1:3]]
state = json.load(open(sys.argv[3]))
ident = sys.argv[4]
pane = meta['herdr_pane_id']
assert pane != 'old-pane-' + ident, 'recovery kept its husk'
assert journal['pane_id'] == pane, 'journal did not advance to the published endpoint'
assert journal['tab_id'] == meta['herdr_tab_id']
assert any(p['pane_id'] == pane and p['workspace_id'] == 'husk-' + ident for p in state['panes'])
assert not any(p['pane_id'] == 'old-pane-' + ident for p in state['panes'])
PY
}

# Runs only as a background child, so its exports and sourced libraries stay
# out of the test shell.
projection_lock_holder_child() {
  export PATH="$A/fakebin:$PATH" FM_FAKE_DIR="$D" FM_HOME="$A/home"
  export FM_PROJECTION_FAKE="$ROOT/tests/fixtures/herdr-projection-fake.py"
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/backends/herdr.sh"
  local lock
  lock=$(fm_backend_herdr_presentation_session_lock_path default) || exit 1
  fm_lock_try_acquire "$lock" || exit 1
  printf 'held\n' > "$D/events"
  read -r -t 60 _ <&8
  fm_lock_release "$lock"
  printf 'released\n' > "$D/events"
}

projection_lock_holder() {
  projection_lock_holder_child &
  PROJECTION_PIDS+=("$!")
  projection_event held
}

test_exact_recovery_during_sibling_allocation() {
  local A B D
  make_projection_pair overlap
  projection_start "$A" overlap-a
  projection_event 'allocated overlap-a'
  # A has published its exact projection but is still inside Treehouse.
  grep -Fxq 'version=2' "$A/home/state/overlap-a.herdr-presentation" || fail "A did not finish binding its projection: $(cat "$A/out")"
  projection_start "$B" overlap-b
  projection_event 'allocated overlap-b'
  printf 'release\n' >&7
  projection_event 'done overlap-b 0'
  projection_assert_replaced "$B" overlap-b
  # B completed without A's allocation ever being released.
  printf 'release\n' >&8
  projection_event 'done overlap-a 0'
  projection_finish
  pass "exact recovery reaches allocation while a sibling projected spawn is held in Treehouse"
}

test_default_exact_recovery_refuses_contention() {
  local A B D out status
  make_projection_pair refuse
  cp "$B/home/state/refuse-b.meta" "$B/meta-before"
  cp "$B/home/state/refuse-b.herdr-presentation" "$B/journal-before"
  projection_lock_holder
  : > "$D/herdr-log"
  out=$(run_lease_spawn "$B" refuse-b); status=$?
  [ "$status" -ne 0 ] || fail "default recovery accepted actual lock contention"
  assert_contains "$out" 'could not acquire its session lock' "missing default refusal"
  ! grep -E '^(workspace|tab|pane) (create|close|move|rename) ' "$D/herdr-log" \
    || fail "refused recovery mutated the projection"
  cmp "$B/meta-before" "$B/home/state/refuse-b.meta" || fail "refusal changed metadata"
  cmp "$B/journal-before" "$B/home/state/refuse-b.herdr-presentation" || fail "refusal changed journal"
  printf 'release\n' >&8
  projection_event released
  projection_finish
  pass "default exact recovery refuses a held session lock without projection mutations"
}

test_opt_in_exact_recoveries_wait_and_replace_own_husks() {
  local A B D
  make_projection_pair wait
  FM_FAKE_DIR="$D" python3 "$ROOT/tests/fixtures/herdr-projection-fake.py" \
    seed wait-a "$A/home" "$A/project" aaaaaaaaaaaaaaaaaaaaaa >/dev/null
  projection_lock_holder
  # Observe an actual failed acquire at the sleep boundary, then park that
  # retry on the task's FIFO. Never infer contention from elapsed time.
  cat > "$A/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "$*" = 0.1 ] && [ ! -f "$FM_FAKE_DIR/retried-$FM_WAIT_ID" ]; then
  : > "$FM_FAKE_DIR/retried-$FM_WAIT_ID"
  printf 'waiting %s\n' "$FM_WAIT_ID" > "$FM_FAKE_DIR/events"
  read -r -t 60 _ < "$FM_FAKE_DIR/retry-$FM_WAIT_ID" || exit 1
fi
SH
  cp "$A/fakebin/sleep" "$B/fakebin/sleep"
  mkfifo "$D/retry-wait-a" "$D/retry-wait-b"
  exec 5<>"$D/retry-wait-a" 6<>"$D/retry-wait-b"
  FM_WAIT_ID=wait-a projection_start "$A" wait-a --herdr-resume-lock-wait
  projection_event 'waiting wait-a'
  FM_WAIT_ID=wait-b projection_start "$B" wait-b --herdr-resume-lock-wait
  projection_event 'waiting wait-b'
  printf 'release\n' >&8
  projection_event released
  cp "$B/home/state/wait-b.meta" "$B/meta-before"
  cp "$B/home/state/wait-b.herdr-presentation" "$B/journal-before"
  printf 'retry\n' >&5
  projection_event 'allocated wait-a'
  cmp "$B/meta-before" "$B/home/state/wait-b.meta" || fail "A changed B's metadata"
  cmp "$B/journal-before" "$B/home/state/wait-b.herdr-presentation" || fail "A changed B's journal"
  ! grep -q '^pane close old-pane-wait-b' "$D/herdr-log" || fail "A closed B's husk"
  # A's allocation shares the holder's release FIFO; release it anew.
  printf 'release\n' >&8
  projection_event 'done wait-a 0'
  projection_assert_replaced "$A" wait-a
  cp "$A/home/state/wait-a.meta" "$A/meta-before"
  cp "$A/home/state/wait-a.herdr-presentation" "$A/journal-before"
  printf 'retry\n' >&6
  projection_event 'allocated wait-b'
  printf 'release\n' >&7
  projection_event 'done wait-b 0'
  projection_assert_replaced "$B" wait-b
  cmp "$A/meta-before" "$A/home/state/wait-a.meta" || fail "B changed A's metadata"
  cmp "$A/journal-before" "$A/home/state/wait-a.herdr-presentation" || fail "B changed A's journal"
  projection_finish
  exec 5>&- 6>&-
  pass "opt-in concurrent recoveries wait for the session lock and replace only their own husks"
}

test_exact_recovery_during_sibling_allocation
test_default_exact_recovery_refuses_contention
test_opt_in_exact_recoveries_wait_and_replace_own_husks

test_delayed_worktree_entry
test_dropped_worktree_entry
test_never_moving_worktree_entry

test_fresh_spawn_leases_and_moves_the_top_level_shell
test_local_secondmate_leases_from_its_own_pool
test_failed_lease_refuses_without_a_record
test_aborted_spawn_names_the_lease_it_keeps
test_rolled_back_spawn_after_launch_names_the_lease_it_keeps
test_abort_returns_a_clean_lease_once_the_pane_is_gone
test_abort_keeps_a_dirty_lease_once_the_pane_is_gone
test_abort_keeps_the_lease_while_the_pane_is_present

echo "# all fm-spawn-herdr-lease tests passed"
