#!/usr/bin/env bash
# tests/fm-spawn-pool-sweep-wiring.test.sh - the pool sweep as fm-spawn sees it.
#
# tests/fm-treehouse-pool-sweep.test.sh covers the sweep script's own verdicts.
# This suite covers the other half of the mitigation: that fm-spawn.sh actually
# consults the sweep on the acquisition path, refuses the spawn when the sweep
# refuses, and ships DEACTIVATED so an unconfigured home spawns exactly as before.
#
# It drives the real spawn path with a fake terminal against a synthetic scratch
# pool under mktemp -d; the real ~/.treehouse pool and `treehouse get` are never
# touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-sweep-wiring)

# An ambient config/home override would outrank the per-case values below and
# make the sweep read a config dir no fixture ever wrote.
unset FM_CONFIG_OVERRIDE
unset FM_ROOT_OVERRIDE

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# Builds a project + origin + one pooled worktree, exactly as the pool-base
# freshen suite does, then leaves the pool CLEAN but parked on a commit that no
# branch, tag or rescue ref reaches - the shape the sweep classifies unsafe(2).
# Clean-but-unreachable is deliberate: a dirty pool is already refused later by
# the base-freshen check, so it could not tell us whether the sweep ran at all.
make_case() {
  local name=$1 id=$2 case_dir home project origin pool fakebin initial orphan
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  # Abandoned work left behind in the pool: committed, so the worktree is clean,
  # but reachable from nothing durable once the detached HEAD moves on.
  printf 'abandoned lane work\n' > "$pool/abandoned.txt"
  git -C "$pool" add abandoned.txt
  git -C "$pool" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'abandoned work'
  orphan=$(git -C "$pool" rev-parse HEAD)

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$orphan"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR ORPHAN_SHA <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$POOL_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" "$@" 2>&1
}

test_shipped_deactivated() {
  local rec id out status
  id='sweep-wiring-default-r1'
  rec=$(make_case shipped-default "$id")
  read_case_record "$rec"
  [ ! -e "$HOME_DIR/config/worktree-pool-sweep" ] \
    || fail "fixture pre-enabled the sweep; the shipped default is no config file"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an unconfigured home must spawn exactly as before the sweep existed"
  assert_contains "$out" "spawned $id" "spawn did not report success with the sweep deactivated"
  case "$out" in
    *"pool sweep refused"*) fail "the sweep refused a spawn in a home that never enabled it" ;;
  esac
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" != "$ORPHAN_SHA" ] \
    || fail "fixture did not prove the spawn actually proceeded past the sweep"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# deactivated default: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "the sweep ships deactivated: an unconfigured home spawns on an unsafe pool"
}

test_enabled_sweep_refuses_the_spawn() {
  local rec id out status
  id='sweep-wiring-enabled-r2'
  rec=$(make_case enabled-refusal "$id")
  read_case_record "$rec"
  printf 'on\n' > "$HOME_DIR/config/worktree-pool-sweep"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite the sweep refusing the pooled worktree"
  assert_contains "$out" "pool sweep refused worktree" \
    "spawn did not surface the sweep's refusal to the operator"
  assert_contains "$out" "(exit 2)" \
    "spawn did not report the sweep's unreachable-HEAD verdict"
  assert_contains "$out" "config/worktree-pool-sweep" \
    "the refusal did not tell the operator where to disable the sweep"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$ORPHAN_SHA" ] \
    || fail "spawn moved the pooled worktree off the unreachable work it refused"
  assert_grep 'abandoned lane work' "$POOL_DIR/abandoned.txt" \
    "spawn discarded the abandoned pool work while refusing it"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# enabled refusal: %s\n' "$(printf '%s\n' "$out" | grep 'pool sweep refused' | tail -n 1)"
  fi
  pass "an enabled sweep refuses the spawn before it can reuse an unsafe pooled worktree"
}

test_off_value_keeps_the_spawn_path_open() {
  local rec id out status
  id='sweep-wiring-off-r3'
  rec=$(make_case explicit-off "$id")
  read_case_record "$rec"
  printf 'off\n' > "$HOME_DIR/config/worktree-pool-sweep"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an explicit off must leave the acquisition path unchanged"
  case "$out" in
    *"pool sweep refused"*) fail "the sweep refused a spawn in a home that set it off" ;;
  esac
  pass "an explicit off leaves the spawn acquisition path unchanged"
}

test_shipped_deactivated
test_enabled_sweep_refuses_the_spawn
test_off_value_keeps_the_spawn_path_open

echo "# all fm-spawn-pool-sweep-wiring tests passed"
