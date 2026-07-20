#!/usr/bin/env bash
# Behavior tests for fm-lane-governor.sh and its fm-spawn.sh integration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lane-governor)
GOV="$ROOT/bin/fm-lane-governor.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/projects"
  printf '%s\n' "$home"
}

run_governor() {
  local home=$1
  shift
  FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_LANE_ORPHAN_CHECK="${FM_LANE_ORPHAN_CHECK:-0}" \
    FM_LANE_MEMORY_AVAILABLE_MB="${FM_LANE_MEMORY_AVAILABLE_MB:-4096}" \
    FM_LANE_SWAP_USED_MB="${FM_LANE_SWAP_USED_MB:-0}" \
    "$GOV" "$@" 2>&1
}

test_capacity_counts_active_workers() {
  local home out status
  home=$(make_home capacity-active)
  mkdir -p "$home/projects/a"
  fm_write_meta "$home/state/a.meta" "kind=ship" "worktree=$home/projects/a"
  printf 'a=working\n' > "$home/states"

  out=$(FM_LANE_MAX_CONCURRENT=1 FM_LANE_CREW_STATE_FILE="$home/states" run_governor "$home" acquire b --holder-pid "$$")
  status=$?

  [ "$status" -ne 0 ] || fail "capacity guard should refuse when active + requested exceeds max"
  assert_contains "$out" "LANE_GOVERNOR: refusing spawn: active=1 leases=0 requested=1 max=1" \
    "capacity refusal should name active, leases, requested, and max"
  pass "lane governor refuses over-capacity active worker spawns"
}

test_spawn_leases_reserve_capacity_until_released() {
  local home out status
  home=$(make_home lease-reserve)

  out=$(FM_LANE_MAX_CONCURRENT=1 run_governor "$home" acquire first --holder-pid "$$")
  status=$?
  [ "$status" -eq 0 ] || fail "first lease should acquire, got: $out"

  out=$(FM_LANE_MAX_CONCURRENT=1 run_governor "$home" check --count 1)
  status=$?
  [ "$status" -ne 0 ] || fail "live lease should reserve capacity"
  assert_contains "$out" "leases=1 requested=1 max=1" "capacity refusal should count live leases"

  out=$(run_governor "$home" release first --holder-pid "$$")
  status=$?
  [ "$status" -eq 0 ] || fail "lease release should succeed, got: $out"
  out=$(FM_LANE_MAX_CONCURRENT=1 run_governor "$home" check --count 1)
  status=$?
  [ "$status" -eq 0 ] || fail "capacity should be available after release, got: $out"
  pass "lane governor spawn leases reserve capacity only while live"
}

test_memory_thresholds_refuse_spawn() {
  local home out status
  home=$(make_home memory)

  out=$(FM_LANE_SWAP_USED_MB=25000 FM_LANE_MAX_SWAP_GB=24 run_governor "$home" check)
  status=$?
  [ "$status" -ne 0 ] || fail "swap threshold should refuse"
  assert_contains "$out" "swap used" "swap refusal should explain the threshold"

  out=$(FM_LANE_MEMORY_AVAILABLE_MB=512 FM_LANE_MIN_AVAILABLE_RAM_GB=1 run_governor "$home" check)
  status=$?
  [ "$status" -ne 0 ] || fail "available RAM threshold should refuse"
  assert_contains "$out" "available RAM" "RAM refusal should explain the threshold"
  pass "lane governor refuses high swap and low available RAM"
}

test_completed_workers_surface_cleanup_without_blocking() {
  local home out status
  home=$(make_home completed-cleanup)
  mkdir -p "$home/projects/done"
  fm_write_meta "$home/state/done.meta" "kind=ship" "worktree=$home/projects/done"
  printf 'done=done\n' > "$home/states"

  out=$(FM_LANE_MAX_CONCURRENT=1 FM_LANE_CREW_STATE_FILE="$home/states" run_governor "$home" acquire next --holder-pid "$$")
  status=$?
  [ "$status" -eq 0 ] || fail "completed workers should not consume lane capacity, got: $out"
  assert_contains "$out" "completed worker cleanup recommended before more spawns: done=done" \
    "completed worker cleanup warning missing"
  run_governor "$home" release next --holder-pid "$$" >/dev/null || true
  pass "lane governor surfaces completed-worker cleanup without blocking capacity"
}

write_orphan_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-axo pid=,ppid=,comm=,args=")
    printf '%s\n' '200 101 /usr/local/bin/codex codex --dangerously-bypass-approvals-and-sandbox'
    printf '%s\n' '101 1 /bin/zsh -zsh'
    exit 0
    ;;
  "-o ppid= -p 101")
    printf '%s\n' ' 1'
    exit 0
    ;;
  "-o comm= -p 101")
    printf '%s\n' ' /bin/zsh'
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$1/ps"
}

test_orphaned_harness_detector_matches_reparented_zsh() {
  local home fakebin out status
  home=$(make_home orphan)
  fakebin=$(fm_fakebin "$home")
  write_orphan_ps "$fakebin"
  printf '200=%s\n' "$home/projects/x" > "$home/cwds"

  out=$(PATH="$fakebin:$BASE_PATH" FM_LANE_ORPHAN_CHECK=1 FM_LANE_PROCESS_CWD_FILE="$home/cwds" run_governor "$home" memwatch)
  status=$?

  [ "$status" -ne 0 ] || fail "orphaned harness detector should refuse for this home's orphan"
  assert_contains "$out" "orphaned harness process detected: pid=200 harness=codex parent_zsh=101" \
    "orphan detector did not report the reparented zsh harness"
  pass "lane governor detects this home's orphaned harnesses below launchd-reparented zsh"
}

test_foreign_home_orphan_reported_without_blocking() {
  local home fakebin out status
  home=$(make_home orphan-foreign)
  fakebin=$(fm_fakebin "$home")
  write_orphan_ps "$fakebin"
  printf '200=%s\n' "$TMP_ROOT/some-other-home/projects/x" > "$home/cwds"

  out=$(PATH="$fakebin:$BASE_PATH" FM_LANE_ORPHAN_CHECK=1 FM_LANE_PROCESS_CWD_FILE="$home/cwds" run_governor "$home" memwatch)
  status=$?

  [ "$status" -eq 0 ] || fail "foreign-home orphan must not block this home's spawns, got: $out"
  assert_contains "$out" "ignoring orphaned harness in another home" \
    "foreign-home orphan should be reported without blocking"
  assert_not_contains "$out" "refusing spawn: orphaned harness" \
    "foreign-home orphan must not trigger a spawn refusal"
  pass "lane governor reports foreign-home orphans without blocking this home"
}

test_fm_spawn_consults_governor_before_brief_lookup() {
  local home out status
  home=$(make_home spawn-integration)
  mkdir -p "$home/projects/a" "$home/projects/new"
  fm_write_meta "$home/state/a.meta" "kind=ship" "worktree=$home/projects/a"
  printf 'a=working\n' > "$home/states"

  out=$(FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_BACKEND=tmux \
    FM_LANE_ORPHAN_CHECK=0 \
    FM_LANE_MEMORY_AVAILABLE_MB=4096 \
    FM_LANE_SWAP_USED_MB=0 \
    FM_LANE_MAX_CONCURRENT=1 \
    FM_LANE_CREW_STATE_FILE="$home/states" \
    "$SPAWN" new projects/new codex 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "spawn should be refused by governor"
  assert_contains "$out" "LANE_GOVERNOR: refusing spawn" "fm-spawn should surface the lane governor refusal"
  assert_not_contains "$out" "error: no brief" "fm-spawn should consult the governor before looking up the brief"
  pass "fm-spawn consults lane governor before launch and brief side effects"
}

test_secondmate_metas_excluded_from_capacity() {
  local home out status
  home=$(make_home secondmate-capacity)
  mkdir -p "$home/projects/sm" "$home/projects/a"
  fm_write_meta "$home/state/sm.meta" "kind=secondmate" "worktree=$home/projects/sm"
  fm_write_meta "$home/state/a.meta" "kind=ship" "worktree=$home/projects/a"
  printf 'sm=unknown\na=working\n' > "$home/states"

  out=$(FM_LANE_MAX_CONCURRENT=2 FM_LANE_CREW_STATE_FILE="$home/states" run_governor "$home" acquire b --holder-pid "$$")
  status=$?

  [ "$status" -eq 0 ] || fail "persistent secondmate metas must not consume lane capacity, got: $out"
  run_governor "$home" release b --holder-pid "$$" >/dev/null || true

  fm_write_meta "$home/state/a2.meta" "kind=ship" "worktree=$home/projects/a"
  printf 'sm=unknown\na=working\na2=working\n' > "$home/states"
  out=$(FM_LANE_MAX_CONCURRENT=2 FM_LANE_CREW_STATE_FILE="$home/states" run_governor "$home" acquire c --holder-pid "$$")
  status=$?
  [ "$status" -ne 0 ] || fail "two active ship workers at max=2 should still refuse regardless of secondmate metas"
  assert_contains "$out" "active=2" "capacity should count only the two ship workers, not the secondmate"
  pass "lane governor excludes persistent secondmate metas from lane capacity"
}

test_lease_ttl_reaps_stale_live_lease() {
  local home out status lease_dir
  home=$(make_home lease-ttl)

  out=$(FM_LANE_MAX_CONCURRENT=1 run_governor "$home" acquire stale --holder-pid "$$")
  status=$?
  [ "$status" -eq 0 ] || fail "lease should acquire, got: $out"

  lease_dir="$home/state/.lane-governor/leases"
  [ -f "$lease_dir/stale.lease" ] || fail "expected lease file to exist"
  {
    grep -v '^created=' "$lease_dir/stale.lease"
    printf 'created=%s\n' "1"
  } > "$lease_dir/stale.lease.tmp"
  mv -f "$lease_dir/stale.lease.tmp" "$lease_dir/stale.lease"

  out=$(FM_LANE_MAX_CONCURRENT=1 FM_LANE_LEASE_TTL_SECONDS=600 run_governor "$home" check --count 1)
  status=$?
  [ "$status" -eq 0 ] || fail "capacity should be free after a past-TTL lease is reaped, got: $out"
  [ ! -f "$lease_dir/stale.lease" ] || fail "past-TTL lease should have been reaped"
  pass "lane governor reaps live leases held past FM_LANE_LEASE_TTL_SECONDS"
}

test_capacity_counts_active_workers
test_spawn_leases_reserve_capacity_until_released
test_secondmate_metas_excluded_from_capacity
test_lease_ttl_reaps_stale_live_lease
test_memory_thresholds_refuse_spawn
test_completed_workers_surface_cleanup_without_blocking
test_orphaned_harness_detector_matches_reparented_zsh
test_foreign_home_orphan_reported_without_blocking
test_fm_spawn_consults_governor_before_brief_lookup
