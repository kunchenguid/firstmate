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
# The pool-selection lock cases below pin the other half of the allocation:
# directed select-then-enter claims nothing until the holder process occupies
# the chosen slot, so fm-spawn serializes the whole window under one
# machine-private lock per physical pool, refuses loudly when it cannot
# acquire it, and releases it at pane settle and on the abort path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

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
  send-keys) [ -z "${FM_FAKE_SEND_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_SEND_LOG"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse "$fakebin"
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
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
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
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION 2>&1
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
  # Durable ownership for bin/fm-worktree-guard.sh. The keys must always be
  # written so a later check can tell "no occupant was resolvable" (empty, which
  # reads unresolved) apart from a meta that predates the field entirely.
  assert_grep "worktree_owner_pid=" "$HOME_DIR/state/$id.meta" \
    "meta did not record the worktree owner pid field"
  assert_grep "worktree_owner_identity=" "$HOME_DIR/state/$id.meta" \
    "meta did not record the worktree owner identity field"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

# --- pool selection lock -----------------------------------------------------

# The lock path fm-spawn resolves for a pool, mirrored byte-for-byte from
# spawn_pool_select_lock_path so these cases can observe the real lock.
pool_lock_path() {  # <proj>
  local real hash
  real=$(cd "$1" && pwd -P) || return 1
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$real" | shasum -a 256 | awk '{print $1}')
  else
    hash=$(printf '%s' "$real" | sha256sum | awk '{print $1}')
  fi
  printf '/tmp/firstmate-worktree-pool/select-%s.lock' "${hash:0:32}"
}

# Overwrite lib.sh's empty-pool treehouse stub with one serving a canned pool,
# whose `status --json` can also mark, stall, or fail via env so a case can
# prove whether and when the guard read the pool.
install_pool_fake_treehouse() {  # <fakebin> <json>
  local fakebin=$1 json=$2
  printf '%s' "$json" > "$fakebin/../treehouse-status.json"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ] && [ "${2:-}" = --help ]; then
  printf 'Usage:\n  treehouse status [flags]\n\nFlags:\n  -h, --help   help for status\n      --json   Print pool status as JSON\n'
  exit 0
fi
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  [ -z "${FM_FAKE_TH_STATUS_MARKER:-}" ] || : > "$FM_FAKE_TH_STATUS_MARKER"
  [ -z "${FM_FAKE_TH_STATUS_DELAY:-}" ] || sleep "$FM_FAKE_TH_STATUS_DELAY"
  if [ -n "${FM_FAKE_TH_STATUS_FAIL:-}" ]; then
    echo "fake treehouse: status --json forced failure" >&2
    exit 1
  fi
  cat "$(dirname "$0")/../treehouse-status.json"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
}

# A home, a project, and one genuinely clean pool slot (detached, nothing
# unlanded) that the guard will select by name.
make_pool_lock_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj slot fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  slot="$case_dir/slot"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_init_commit "$proj"
  git -C "$proj" worktree add --quiet --detach "$slot"
  install_pool_fake_treehouse "$fakebin" \
    "[{\"name\":\"1\",\"status\":\"available\",\"path\":\"$slot\",\"processes\":[]}]"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$slot|$fakebin"
}

read_pool_lock_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR SLOT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_pool_lock_spawn() {  # <id>
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$SLOT_DIR" FM_FAKE_PANE_STALE='' \
    FM_FAKE_PANE_STALE_READS=0 FM_FAKE_PANE_COUNTFILE="$CASE_DIR/pane-call-count" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION 2>&1
}

# The full directed path: the guard selects the clean slot, the spawn enters it
# by name, and the pool selection lock is gone once the spawn returns.
test_directed_spawn_enters_selected_slot_and_releases_lock() {
  local rec id out status lock sendlog
  id=poollock-directed-z3
  rec=$(make_pool_lock_case poollock-directed "$id")
  read_pool_lock_record "$rec"
  lock=$(pool_lock_path "$PROJ_DIR") || fail "cannot compute the pool selection lock path"
  sendlog="$CASE_DIR/sent-lines"
  out=$(FM_FAKE_SEND_LOG="$sendlog" run_pool_lock_spawn "$id")
  status=$?
  expect_code 0 "$status" "directed spawn should succeed"
  assert_contains "$out" "spawned $id" "directed spawn did not report success"
  assert_grep "treehouse enter '1'" "$sendlog" \
    "the pane was not steered to the selected slot by name"
  assert_grep "worktree=$SLOT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the selected slot"
  { [ ! -e "$lock" ] && [ ! -L "$lock" ]; } \
    || fail "the pool selection lock survived a successful spawn"
  pass "a directed spawn enters the selected slot by name and releases the pool lock at settle"
}

# While another spawn holds the pool selection lock, a second spawn must wait
# or refuse - never read the pool and choose the same slot.
test_spawn_refuses_while_pool_lock_is_held() {
  local rec id out status lock holder marker
  id=poollock-held-z4
  rec=$(make_pool_lock_case poollock-held "$id")
  read_pool_lock_record "$rec"
  lock=$(pool_lock_path "$PROJ_DIR") || fail "cannot compute the pool selection lock path"
  marker="$CASE_DIR/pool-was-read"
  FM_STATE_OVERRIDE="${TMPDIR:-/tmp}" bash -c \
    '. "$1" && fm_lock_try_acquire "$2" && exec sleep 300' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$lock" >/dev/null 2>&1 &
  holder=$!
  fm_test_reap "$holder"
  for _ in $(seq 1 50); do
    [ -L "$lock" ] && break
    sleep 0.1
  done
  [ -L "$lock" ] || fail "test setup: the holder never acquired the pool selection lock"
  out=$(FM_FAKE_TH_STATUS_MARKER="$marker" FM_SPAWN_POOL_LOCK_POLLS=3 run_pool_lock_spawn "$id")
  status=$?
  expect_code 1 "$status" "spawn must refuse while another spawn holds the pool selection lock"
  assert_contains "$out" "another spawn is choosing a slot in this pool" \
    "the refusal did not name the held lock"
  [ ! -e "$marker" ] || fail "the guard read the pool although the selection lock was held elsewhere"
  [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn still recorded task meta"
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  rm -rf "$lock" "$lock".owner.* 2>/dev/null
  pass "a spawn that cannot acquire the pool selection lock refuses loudly without selecting"
}

# The abort path: the guard's refusal aborts the spawn after the lock was
# acquired, and the spawn's EXIT cleanup releases it.
test_aborted_spawn_releases_pool_lock() {
  local rec id lock outfile spawn_pid status seen
  id=poollock-abort-z5
  rec=$(make_pool_lock_case poollock-abort "$id")
  read_pool_lock_record "$rec"
  lock=$(pool_lock_path "$PROJ_DIR") || fail "cannot compute the pool selection lock path"
  outfile="$CASE_DIR/spawn-out"
  FM_FAKE_TH_STATUS_DELAY=5 FM_FAKE_TH_STATUS_FAIL=1 \
    run_pool_lock_spawn "$id" > "$outfile" &
  spawn_pid=$!
  fm_test_reap "$spawn_pid"
  seen=0
  for _ in $(seq 1 100); do
    if [ -L "$lock" ]; then seen=1; break; fi
    sleep 0.1
  done
  [ "$seen" = 1 ] || fail "the pool selection lock was never held while the guard read the pool"
  wait "$spawn_pid"
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded although the guard could not read the pool"
  assert_contains "$(cat "$outfile")" "cannot verify pool safety" \
    "the spawn did not fail on the guard's refusal"
  { [ ! -e "$lock" ] && [ ! -L "$lock" ]; } \
    || fail "the pool selection lock leaked after an aborted spawn"
  pass "an aborted spawn releases the pool selection lock from the abort path"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_directed_spawn_enters_selected_slot_and_releases_lock
test_spawn_refuses_while_pool_lock_is_held
test_aborted_spawn_releases_pool_lock

echo "# all fm-spawn-worktree-settle tests passed"
