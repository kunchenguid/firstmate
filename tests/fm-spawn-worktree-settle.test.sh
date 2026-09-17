#!/usr/bin/env bash
# Regression test for how bin/fm-spawn.sh acquires a crewmate or scout worktree.
#
# The worktree is leased in fm-spawn.sh's own shell with `treehouse get --lease`
# and the pane is then sent a plain `cd` into that already-known path. That
# replaced a loop that discovered the worktree by polling the pane's cwd, which
# could never succeed on a backend that cannot report a live path (Herdr on
# Windows reports null forever) and could accept a transient stale read on the
# backends that can.
#
# These cases pin the properties that acquisition now depends on: the leased
# path is what gets recorded, an unusable lease refuses instead of launching, a
# pane that never arrives refuses, a pane that cannot answer at all still
# launches, and every failure between the lease and the published task record
# hands the lease back so a pool slot is not burned.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-lease)

# make_lease_fakebin <dir> builds a fake tmux that answers the
# `#{pane_current_path}` probe from FM_FAKE_PANE_SEEN (empty by default, which
# is what a backend with no working current-path route reports) and a fake
# treehouse whose `get --lease` prints FM_FAKE_LEASE_PATH.
make_lease_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf 'tmux %s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_SEEN:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    case "$*" in
      *" cd "*) exit "${FM_FAKE_CD_SEND_EXIT:-0}" ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse_lease "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_lease_case <name> <id> builds a home, a project with one real linked
# worktree standing in for the pool's answer, and a separate real git repo
# standing in for a wrong-but-plausible path a pane might report.
make_lease_case() {
  local name=$1 id=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  CASE_HOME="$case_dir/home"
  CASE_PROJ="$case_dir/project"
  CASE_WT="$case_dir/wt"
  CASE_OTHER="$case_dir/other-checkout"
  CASE_TREEHOUSE_LOG="$case_dir/treehouse.log"
  CASE_TMUX_LOG="$case_dir/tmux.log"
  CASE_FAKEBIN=$(make_lease_fakebin "$case_dir/fake")
  mkdir -p "$CASE_HOME/data" "$CASE_HOME/projects" "$CASE_HOME/state" "$CASE_HOME/config"
  printf 'codex\n' > "$CASE_HOME/config/crew-harness"
  fm_git_worktree "$CASE_PROJ" "$CASE_WT" "wt-$name"
  fm_git_init_commit "$CASE_OTHER"
  mkdir -p "$CASE_HOME/data/$id"
  cat > "$CASE_HOME/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$CASE_HOME/state/.last-watcher-beat"
  : > "$CASE_TREEHOUSE_LOG"
  : > "$CASE_TMUX_LOG"
}

# run_lease_spawn <id> [<extra env assignments>...]: run one spawn against the
# case fixture. FM_FAKE_LEASE_PATH defaults to the case's real worktree.
run_lease_spawn() {
  local id=$1
  shift
  env FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_LEASE_PATH="$CASE_WT" FM_FAKE_LEASE_LOG="$CASE_TREEHOUSE_LOG" \
    FM_FAKE_TMUX_LOG="$CASE_TMUX_LOG" \
    FM_SPAWN_PANE_CONFIRM_POLLS=3 FM_SPAWN_PANE_CONFIRM_INTERVAL=0 \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$@" \
    "$SPAWN" "$id" "$CASE_PROJ" --mode no-mistakes --yolo off 2>&1
}

# The leased path is the recorded worktree, and the pane is sent into it.
test_leased_worktree_is_recorded_and_entered() {
  local id out status
  id=lease-ok-z1
  make_lease_case lease-ok "$id"

  out=$(run_lease_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed on a leased worktree"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$CASE_WT" "$CASE_HOME/state/$id.meta" \
    "meta did not record the leased worktree"
  assert_grep "get --lease --lease-holder $id" "$CASE_TREEHOUSE_LOG" \
    "spawn did not durably lease the worktree under the task id"
  assert_grep "cd '$CASE_WT' Enter" "$CASE_TMUX_LOG" \
    "spawn did not send the endpoint into the leased worktree"
  assert_no_grep "treehouse return" "$CASE_TREEHOUSE_LOG" \
    "a successful spawn must not hand its worktree back"
  pass "a leased worktree is recorded and the endpoint is sent into it"
}

# On Windows treehouse prints a native, drive-lettered, backslashed path, which
# no POSIX comparison in fm-spawn.sh can use and which teardown could not match
# against its record. Acquisition folds it through fm_path_posix at the point of
# capture, so only one spelling ever reaches the rest of the script.
#
# The MSYS half is supplied by the library's own seams rather than by the host,
# so this case pins the behavior on every platform including Linux CI:
# FM_PLATFORM_UNAME drives the MSYS branch, FM_PLATFORM_MSYS is cleared so the
# per-process cache cannot short-circuit it, and a cygpath fixture ahead of the
# real one on PATH answers the conversion. The fixture is an identity translator
# for everything except the one native spelling, so the script's other
# path-normalizing calls behave exactly as they do off MSYS.
test_native_lease_path_is_normalized() {
  local id out status native
  id=lease-native-z1
  native='C:\fixture\leased\wt'
  make_lease_case lease-native "$id"

  cat > "$CASE_FAKEBIN/cygpath" <<'SH'
#!/usr/bin/env bash
set -u
mode=${1:-}
shift || true
[ "${1:-}" != "--" ] || shift
in=${1:-}
if [ "$mode" = "-u" ] && [ "$in" = "${FM_FAKE_NATIVE_WT:-}" ]; then
  printf '%s\n' "$FM_FAKE_POSIX_WT"
  exit 0
fi
printf '%s\n' "$in"
SH
  chmod +x "$CASE_FAKEBIN/cygpath"

  out=$(run_lease_spawn "$id" \
    FM_FAKE_LEASE_PATH="$native" \
    FM_FAKE_NATIVE_WT="$native" FM_FAKE_POSIX_WT="$CASE_WT" \
    FM_PLATFORM_UNAME=MINGW64_NT-fixture FM_PLATFORM_MSYS=)
  status=$?
  expect_code 0 "$status" "a natively spelled lease should spawn"$'\n'"$out"
  assert_grep "worktree=$CASE_WT" "$CASE_HOME/state/$id.meta" \
    "meta recorded the native lease spelling instead of the POSIX identity"
  assert_no_grep 'C:\\fixture' "$CASE_HOME/state/$id.meta" \
    "the native drive-lettered spelling reached the task record"
  assert_grep "cd '$CASE_WT' Enter" "$CASE_TMUX_LOG" \
    "the endpoint was sent a spelling the shell cannot cd into"
  pass "a natively spelled lease path is folded to one POSIX identity"
}

# A pool with nothing to hand out prints no path. That must refuse loudly rather
# than launching an agent with no isolated copy.
test_empty_lease_refuses() {
  local id out status
  id=lease-empty-z2
  make_lease_case lease-empty "$id"

  out=$(run_lease_spawn "$id" FM_FAKE_LEASE_PATH=)
  status=$?
  expect_code 1 "$status" "an empty lease must refuse"
  assert_contains "$out" "did not lease a worktree" "empty lease lacked its refusal"
  assert_absent "$CASE_HOME/state/$id.meta" "a refused lease must not record a task"
  pass "an empty lease refuses instead of launching without an isolated copy"
}

# A failing treehouse is the same refusal: no path, no launch.
test_failed_lease_refuses() {
  local id out status
  id=lease-fail-z3
  make_lease_case lease-fail "$id"

  out=$(run_lease_spawn "$id" FM_FAKE_LEASE_EXIT=3)
  status=$?
  expect_code 1 "$status" "a failed lease must refuse"
  assert_contains "$out" "did not lease a worktree" "failed lease lacked its refusal"
  assert_absent "$CASE_HOME/state/$id.meta" "a failed lease must not record a task"
  pass "a failed lease refuses instead of launching without an isolated copy"
}

# The isolation guard is unchanged: a leased path that is not a real worktree
# distinct from the primary checkout refuses, and the lease goes back.
test_non_isolated_lease_refuses_and_returns_the_lease() {
  local id out status
  id=lease-notiso-z4
  make_lease_case lease-notiso "$id"

  out=$(run_lease_spawn "$id" FM_FAKE_LEASE_PATH="$CASE_PROJ")
  status=$?
  expect_code 1 "$status" "a lease that resolves to the primary checkout must refuse"
  assert_contains "$out" "did not yield an isolated worktree" "isolation refusal is missing"
  assert_grep "treehouse return --force $CASE_PROJ" "$CASE_TREEHOUSE_LOG" \
    "the refused spawn did not hand its lease back"
  assert_absent "$CASE_HOME/state/$id.meta" "a refused spawn must not record a task"
  pass "an isolation refusal after the lease returns the lease rather than burning a pool slot"
}

# The base-freshness step runs after the lease and can refuse. Its failure path
# has to return the lease too - it is the failure most likely to fire in real
# use, because it fetches.
test_stale_base_refusal_returns_the_lease() {
  local id out status
  id=lease-stale-z5
  make_lease_case lease-stale "$id"
  # Break the pooled worktree's origin so freshen_spawn_worktree_base refuses.
  git -C "$CASE_WT" remote set-url origin "$TMP_ROOT/lease-stale/no-such-remote.git"

  out=$(run_lease_spawn "$id")
  status=$?
  expect_code 1 "$status" "an unfetchable base must refuse"
  assert_contains "$out" "refusing to launch from a potentially stale base" \
    "base-freshness refusal is missing"
  assert_grep "treehouse return --force $CASE_WT" "$CASE_TREEHOUSE_LOG" \
    "the base-freshness refusal did not hand its lease back"
  pass "a base-freshness refusal after the lease returns the lease"
}

# A backend that cannot report a live path reports empty forever. That is not
# evidence the pane is elsewhere, so the spawn proceeds and the ship brief's own
# isolation assertion is the agent-side backstop.
test_unreportable_pane_path_still_launches() {
  local id out status
  id=lease-blind-z6
  make_lease_case lease-blind "$id"

  out=$(run_lease_spawn "$id" FM_FAKE_PANE_SEEN=)
  status=$?
  expect_code 0 "$status" "a backend that cannot report a path must not block the spawn"$'\n'"$out"
  assert_grep "worktree=$CASE_WT" "$CASE_HOME/state/$id.meta" \
    "meta did not record the leased worktree when the pane could not be read"
  pass "an unreadable pane path proceeds rather than refusing a spawn it cannot confirm"
}

# A backend that CAN report a path is held to it: a pane parked somewhere else
# refuses, and the lease goes back.
test_pane_in_the_wrong_place_refuses_and_returns_the_lease() {
  local id out status
  id=lease-wrong-z7
  make_lease_case lease-wrong "$id"

  out=$(run_lease_spawn "$id" FM_FAKE_PANE_SEEN="$CASE_OTHER")
  status=$?
  expect_code 1 "$status" "a pane that never reached the worktree must refuse"
  assert_contains "$out" "not its leased worktree" "wrong-pane refusal is missing"
  assert_grep "treehouse return --force $CASE_WT" "$CASE_TREEHOUSE_LOG" \
    "the wrong-pane refusal did not hand its lease back"
  assert_absent "$CASE_HOME/state/$id.meta" "a refused spawn must not record a task"
  pass "a reportable pane outside the leased worktree refuses and returns the lease"
}

# A `cd` the backend reports as failed is a concrete error rather than an
# unanswerable question, so it refuses even where the path cannot be read back.
test_failed_cd_send_refuses_and_returns_the_lease() {
  local id out status
  id=lease-send-z9
  make_lease_case lease-send "$id"

  out=$(run_lease_spawn "$id" FM_FAKE_CD_SEND_EXIT=1)
  status=$?
  expect_code 1 "$status" "a failed cd send must refuse"
  assert_contains "$out" "could not send the endpoint" "failed cd send lacked its refusal"
  assert_grep "treehouse return --force $CASE_WT" "$CASE_TREEHOUSE_LOG" \
    "the failed cd send did not hand its lease back"
  assert_absent "$CASE_HOME/state/$id.meta" "a refused spawn must not record a task"
  pass "a cd the backend reports as failed refuses and returns the lease"
}

# A pane that does report the leased worktree confirms it.
test_pane_reporting_the_worktree_confirms() {
  local id out status
  id=lease-seen-z8
  make_lease_case lease-seen "$id"

  out=$(run_lease_spawn "$id" FM_FAKE_PANE_SEEN="$CASE_WT")
  status=$?
  expect_code 0 "$status" "a confirmed pane should spawn"$'\n'"$out"
  assert_grep "worktree=$CASE_WT" "$CASE_HOME/state/$id.meta" \
    "meta did not record the confirmed worktree"
  pass "a pane reporting the leased worktree confirms the spawn"
}

test_leased_worktree_is_recorded_and_entered
test_native_lease_path_is_normalized
test_empty_lease_refuses
test_failed_lease_refuses
test_non_isolated_lease_refuses_and_returns_the_lease
test_stale_base_refusal_returns_the_lease
test_unreportable_pane_path_still_launches
test_pane_in_the_wrong_place_refuses_and_returns_the_lease
test_failed_cd_send_refuses_and_returns_the_lease
test_pane_reporting_the_worktree_confirms

echo "# all fm-spawn-worktree-settle tests passed"
