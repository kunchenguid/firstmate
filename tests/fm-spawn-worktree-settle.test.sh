#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)
PRESENTATION_PIDS=
cleanup_presentation_test() {
  local pid
  if [ -d "${FM_PRESENTATION_FIXTURE:-}" ]; then
    touch "$FM_PRESENTATION_FIXTURE/continue"
  fi
  for pid in $PRESENTATION_PIDS; do wait "$pid" 2>/dev/null || true; done
  fm_test_cleanup
}
trap cleanup_presentation_test EXIT

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 2 ] || fail "already-settled pane took $reads reads to confirm - expected the first read plus one confirmation"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

run_presentation_spawn() {  # <id> <launch>
  (
    unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
    export HERDR_SESSION=fmtest
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
      "$1" "$PROJ_DIR" "$2" --backend herdr --mode local-only --yolo off
  )
}

prepare_presentation_peer() {  # <name>
  local rec
  rec=$(make_primary_case "$1" "$1" 0)
  read_settle_record "$rec"
  printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$ROOT/tests/herdr-presentation-fixture.py" > "$FAKEBIN_DIR/herdr"
  chmod +x "$FAKEBIN_DIR/herdr"
  fm_test_write_active_treehouse_fake "$FAKEBIN_DIR" "$WT_DIR"
  fm_fake_exit0 "$FAKEBIN_DIR" no-mistakes gh-axi
  printf 'on\n' > "$HOME_DIR/config/herdr-presentation-spaces"
}

# Exercise the production adapter, journal publisher, lock and launcher together.
# A paused launch is a continuity assertion, not merely an eventual cleanup check.
test_projected_launch_releases_session_lock() {
  local rec id pid lock pane ready=0 base_path=$PATH
  local first_home peer_pid retired_home retired_fake peer_home starting expected
  id=launch-probe
  rec=$(make_primary_case presentation-launch "$id" 0)
  read_settle_record "$rec"
  export FM_PRESENTATION_FIXTURE="$TMP_ROOT/presentation-launch/server"
  mkdir -p "$FM_PRESENTATION_FIXTURE"
  printf '%s\n' '{"next":1,"workspaces":[{"workspace_id":"w1","label":"firstmate","active_tab_id":"w1:t1","focused":true}],"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","label":"parent","focused":true}],"panes":[{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1"}]}' > "$FM_PRESENTATION_FIXTURE/server.json"
  printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$ROOT/tests/herdr-presentation-fixture.py" > "$FAKEBIN_DIR/herdr"
  chmod +x "$FAKEBIN_DIR/herdr"
  fm_test_write_active_treehouse_fake "$FAKEBIN_DIR" "$WT_DIR"
  printf 'on\n' > "$HOME_DIR/config/herdr-presentation-spaces"
  run_presentation_spawn "$id" 'sh -c "launch-probe"' \
    > "$FM_PRESENTATION_FIXTURE/spawn.out" 2> "$FM_PRESENTATION_FIXTURE/spawn.err" &
  pid=$!
  PRESENTATION_PIDS=$pid
  for _ in $(seq 1 600); do
    for pane in "$FM_PRESENTATION_FIXTURE"/*.starting; do
      [ -e "$pane" ] && ready=1
    done
    if [ "$ready" = 1 ] || ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  if [ "$ready" != 1 ]; then
    wait "$pid" || true
    fail "projected launch never reached the paused harness: $(< "$FM_PRESENTATION_FIXTURE/spawn.err")"
  fi
  lock=$(PATH="$FAKEBIN_DIR:$base_path" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path fmtest' "$ROOT")
  if ! bash -c '. "$0/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$1" && fm_lock_release "$1"' "$ROOT" "$lock"; then
    touch "$FM_PRESENTATION_FIXTURE/continue"
    wait "$pid" || true
    fail "session presentation lock remained held while the harness was starting"
  fi
  # Version 2 binds the exact endpoint before the lock-free launch interval.
  if ! rg -qx 'version=2' "$HOME_DIR/state/$id.herdr-presentation"; then
    touch "$FM_PRESENTATION_FIXTURE/continue"
    wait "$pid" || true
    fail "restart binding was not published before launch: $(< "$FM_PRESENTATION_FIXTURE/spawn.err")"
  fi
  first_home=$HOME_DIR
  cp "$first_home/state/$id.herdr-presentation" "$FM_PRESENTATION_FIXTURE/binding.before"
  prepare_presentation_peer retire-probe
  retired_home=$HOME_DIR; retired_fake=$FAKEBIN_DIR
  run_presentation_spawn retire-probe 'sleep 600' > "$FM_PRESENTATION_FIXTURE/retire-spawn.out" \
    || fail "could not prepare the endpoint to retire: $(< "$FM_PRESENTATION_FIXTURE/retire-spawn.out")"
  prepare_presentation_peer peer-probe
  peer_home=$HOME_DIR
  run_presentation_spawn peer-probe 'sh -c "launch-probe"' > "$FM_PRESENTATION_FIXTURE/peer.out" &
  peer_pid=$!
  PRESENTATION_PIDS="$PRESENTATION_PIDS $peer_pid"
  starting=0
  for _ in $(seq 1 600); do
    starting=0
    for pane in "$FM_PRESENTATION_FIXTURE"/*.starting; do
      if [ -e "$pane" ]; then starting=$((starting + 1)); fi
    done
    if [ "$starting" = 2 ] || ! kill -0 "$peer_pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  [ "$starting" = 2 ] || fail "second spawn did not reach concurrent launch: $(< "$FM_PRESENTATION_FIXTURE/peer.out")"
  rg -qx 'version=2' "$peer_home/state/peer-probe.herdr-presentation" \
    || fail "concurrent spawn did not publish its exact restart binding"
  cp "$peer_home/state/peer-probe.herdr-presentation" "$FM_PRESENTATION_FIXTURE/peer-binding.before"
  expected=$(jq -c '[.workspaces[] | select(.label | contains("retire-probe") | not) | .workspace_id]' "$FM_PRESENTATION_FIXTURE/server.json")
  FM_HOME="$retired_home" FM_STATE_OVERRIDE="$retired_home/state" \
    FM_DATA_OVERRIDE="$retired_home/data" FM_CONFIG_OVERRIDE="$retired_home/config" \
    PATH="$retired_fake:$base_path" "$ROOT/bin/fm-teardown.sh" retire-probe --force \
    > "$FM_PRESENTATION_FIXTURE/teardown.out" 2>&1 \
    || fail "teardown failed while both harnesses were starting: $(< "$FM_PRESENTATION_FIXTURE/teardown.out")"
  [ ! -e "$retired_home/state/retire-probe.meta" ] || fail "concurrent teardown retained endpoint metadata"
  [ "$(jq -c '[.workspaces[].workspace_id]' "$FM_PRESENTATION_FIXTURE/server.json")" = "$expected" ] \
    || fail "concurrent teardown changed surviving workspace order"
  [ ! -e "$FM_PRESENTATION_FIXTURE/continue" ] || fail "launches were not paused during teardown"
  touch "$FM_PRESENTATION_FIXTURE/continue"
  wait "$pid" || fail "projected launch failed after release: $(< "$FM_PRESENTATION_FIXTURE/spawn.err")"
  wait "$peer_pid" || fail "concurrent projected launch failed after release: $(< "$FM_PRESENTATION_FIXTURE/peer.out")"
  cmp -s "$first_home/state/$id.herdr-presentation" "$FM_PRESENTATION_FIXTURE/binding.before" \
    || fail "launch changed the recorded restart binding after releasing the session lock"
  cmp -s "$peer_home/state/peer-probe.herdr-presentation" "$FM_PRESENTATION_FIXTURE/peer-binding.before" \
    || fail "concurrent launch changed its recorded restart binding"
  pass "two projected spawns and teardown complete while launches are paused, preserving order and restart bindings"
}

# Optional focused evidence entry; the ordinary CI invocation still runs all cases.
if [ "${FM_TEST_ONLY:-}" = test_projected_launch_releases_session_lock ]; then
  test_projected_launch_releases_session_lock
  exit 0
fi

test_projected_launch_releases_session_lock
test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline

echo "# all fm-spawn-worktree-settle tests passed"
