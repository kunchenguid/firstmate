#!/usr/bin/env bash
# Behavior tests for the per-provider lane cap: bin/fm-spawn.sh refuses a
# dispatch that would push a billing provider past its configured cap, and
# bin/fm-provider-load.sh reports the current load for intake.
#
# Every case drives the real spawn CLI with a fake tmux pane and a real
# isolated git worktree, seeds real state/<id>.meta fixtures at known provider
# loads, and asserts the actual accept/refuse outcome and the reported load.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

LOAD="$ROOT/bin/fm-provider-load.sh"
TMP_ROOT=$(fm_test_tmproot fm-provider-lane-cap)

FIREWORKS_MODEL='fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash'
DEEPSEEK_MODEL='deepseek-v4.1-flash'
DEEPSEEK_PRO_MODEL='deepseek-v4-pro'

# make_case <name> [brief-id...]
# Builds home+project+worktree+fakebin plus a brief per id, and echoes
# "<case_dir>|<home>|<project>|<worktree>|<fakebin>".
make_case() {
  local name=$1 case_dir home proj wt fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do fm_test_spawn_brief "$home" "$id"; done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# seed_lane <home> <id> <harness> <model> [<window>]
# A minimal real task record: harness and model decide the provider, and an
# optional window target gives the counter an endpoint to classify (a target
# the fake tmux never lists reads provably missing, freeing the seat).
seed_lane() {
  local home=$1 id=$2 harness=$3 model=$4 window=${5:-}
  {
    printf 'harness=%s\n' "$harness"
    printf 'model=%s\n' "$model"
    printf 'kind=ship\n'
    [ -n "$window" ] && printf 'window=%s\n' "$window"
  } > "$home/state/$id.meta"
}

write_caps() {  # <home> <providerCaps-json>
  mkdir -p "$1/config"
  printf '{"rules":[],"providerCaps":%s}\n' "$2" > "$1/config/crew-dispatch.json"
}

run_ship_spawn() {  # <home> <wt> <fakebin> <id> <proj> [extra...]
  local home=$1 wt=$2 fakebin=$3 id=$4 proj=$5
  shift 5
  fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode direct-PR --yolo off "$@"
}

run_load() {  # <home>
  FM_ROOT_OVERRIDE='' FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" \
    "$LOAD" 2>&1
}

test_under_cap_accepts() {
  local rec out status
  rec=$(make_case under-cap spawn-under-cap)
  read_case "$rec"
  seed_lane "$HOME_DIR" lane-fw-1 opencode "$FIREWORKS_MODEL"
  seed_lane "$HOME_DIR" lane-fw-2 opencode "$FIREWORKS_MODEL"
  seed_lane "$HOME_DIR" lane-fw-3 opencode "$FIREWORKS_MODEL"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" spawn-under-cap "$PROJ_DIR" \
    --harness opencode --model "$FIREWORKS_MODEL")
  status=$?
  expect_code 0 "$status" "a third lane against a cap of four should spawn"
  assert_contains "$out" "spawned spawn-under-cap harness=opencode" "spawn did not report success"
  pass "a dispatch under the provider cap is accepted"
}

test_at_cap_refuses_with_provider_and_load() {
  local rec out status
  rec=$(make_case at-cap spawn-at-cap)
  read_case "$rec"
  seed_lane "$HOME_DIR" lane-fw-1 opencode "$FIREWORKS_MODEL"
  seed_lane "$HOME_DIR" lane-fw-2 opencode "$FIREWORKS_MODEL"
  seed_lane "$HOME_DIR" lane-fw-3 opencode "$FIREWORKS_MODEL"
  seed_lane "$HOME_DIR" lane-fw-4 opencode "$FIREWORKS_MODEL"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" spawn-at-cap "$PROJ_DIR" \
    --harness opencode --model "$FIREWORKS_MODEL")
  status=$?
  expect_code 1 "$status" "the fifth lane against a cap of four should refuse"
  assert_contains "$out" "provider lane cap: fireworks already carries 4 live lanes (cap 4)" \
    "refusal did not name the provider and its load"
  assert_absent "$HOME_DIR/state/spawn-at-cap.meta" "a refused spawn wrote a task record"
  pass "a dispatch at the provider cap is refused before any record is written"
}

test_one_pool_counts_models_together_and_a_different_pool_stays_separate() {
  local rec out status
  rec=$(make_case pool-spread spawn-pool-spread)
  read_case "$rec"
  seed_lane "$HOME_DIR" lane-ds-1 opencode "$DEEPSEEK_MODEL"
  seed_lane "$HOME_DIR" lane-ds-2 opencode "$DEEPSEEK_MODEL"
  seed_lane "$HOME_DIR" lane-ds-3 opencode "$DEEPSEEK_PRO_MODEL"
  seed_lane "$HOME_DIR" lane-ds-4 opencode "$DEEPSEEK_PRO_MODEL"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" spawn-pool-spread "$PROJ_DIR" \
    --harness opencode --model "$DEEPSEEK_PRO_MODEL")
  status=$?
  expect_code 1 "$status" "two models on one pool must share the cap"
  assert_contains "$out" "provider lane cap: deepseek already carries 4 live lanes (cap 4)" \
    "the shared pool was not reported as full"

  rec=$(make_case pool-separate spawn-pool-separate)
  read_case "$rec"
  seed_lane "$HOME_DIR" lane-ds-1 opencode "$DEEPSEEK_MODEL"
  seed_lane "$HOME_DIR" lane-ds-2 opencode "$DEEPSEEK_MODEL"
  seed_lane "$HOME_DIR" lane-ds-3 opencode "$DEEPSEEK_PRO_MODEL"
  seed_lane "$HOME_DIR" lane-ds-4 opencode "$DEEPSEEK_PRO_MODEL"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" spawn-pool-separate "$PROJ_DIR" \
    --harness opencode --model "$FIREWORKS_MODEL")
  status=$?
  expect_code 0 "$status" "Fireworks is a different pool and should keep its headroom"
  assert_contains "$out" "spawned spawn-pool-separate harness=opencode" \
    "the separate pool did not accept the dispatch"
  pass "one pool's models count together while a different pool stays separate"
}

test_dead_endpoint_frees_a_seat() {
  local rec out status
  rec=$(make_case dead-seat spawn-dead-seat)
  read_case "$rec"
  seed_lane "$HOME_DIR" lane-ds-1 opencode "$DEEPSEEK_MODEL"
  seed_lane "$HOME_DIR" lane-ds-2 opencode "$DEEPSEEK_MODEL"
  seed_lane "$HOME_DIR" lane-ds-3 opencode "$DEEPSEEK_PRO_MODEL"
  seed_lane "$HOME_DIR" lane-ds-4 opencode "$DEEPSEEK_PRO_MODEL" 'firstmate:gone'

  out=$(run_load "$HOME_DIR")
  assert_contains "$out" 'provider-load: deepseek 3/4' \
    "a provably missing endpoint must not keep occupying a seat"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" spawn-dead-seat "$PROJ_DIR" \
    --harness opencode --model "$DEEPSEEK_MODEL")
  status=$?
  expect_code 0 "$status" "a freed seat should admit the next dispatch"
  assert_contains "$out" "spawned spawn-dead-seat harness=opencode" \
    "the freed seat did not admit the dispatch"
  pass "a lane whose endpoint is provably gone no longer holds a seat"
}

test_operator_cap_config_is_honoured() {
  local rec out status
  rec=$(make_case cap-config spawn-cap-config)
  read_case "$rec"
  write_caps "$HOME_DIR" '{"default":1}'
  seed_lane "$HOME_DIR" lane-fw-1 opencode "$FIREWORKS_MODEL"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" spawn-cap-config "$PROJ_DIR" \
    --harness opencode --model "$FIREWORKS_MODEL")
  status=$?
  expect_code 1 "$status" "providerCaps.default of one should refuse a second lane"
  assert_contains "$out" "provider lane cap: fireworks already carries 1 live lanes (cap 1)" \
    "the configured default cap was not applied"

  rec=$(make_case cap-raise spawn-cap-raise)
  read_case "$rec"
  write_caps "$HOME_DIR" '{"fireworks":5}'
  seed_lane "$HOME_DIR" lane-fw-1 opencode "$FIREWORKS_MODEL"
  seed_lane "$HOME_DIR" lane-fw-2 opencode "$FIREWORKS_MODEL"
  seed_lane "$HOME_DIR" lane-fw-3 opencode "$FIREWORKS_MODEL"
  seed_lane "$HOME_DIR" lane-fw-4 opencode "$FIREWORKS_MODEL"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" spawn-cap-raise "$PROJ_DIR" \
    --harness opencode --model "$FIREWORKS_MODEL")
  status=$?
  expect_code 0 "$status" "a raised per-provider cap should admit a fifth lane"
  assert_contains "$out" "spawned spawn-cap-raise harness=opencode" \
    "the raised cap did not admit the dispatch"
  pass "the cap is operator-editable configuration, not a code constant"
}

test_load_command_reports_provider_load() {
  local rec out
  rec=$(make_case load-report)
  read_case "$rec"
  out=$(run_load "$HOME_DIR")
  assert_contains "$out" 'provider-load: no live lanes' "an empty home should report no lanes"

  seed_lane "$HOME_DIR" lane-ds-1 opencode "$DEEPSEEK_MODEL"
  seed_lane "$HOME_DIR" lane-ds-2 opencode "$DEEPSEEK_MODEL"
  seed_lane "$HOME_DIR" lane-fw-1 opencode "$FIREWORKS_MODEL"
  out=$(run_load "$HOME_DIR")
  assert_contains "$out" 'provider-load: deepseek 2/4' "the load command did not count the deepseek lane"
  assert_contains "$out" 'provider-load: fireworks 1/4' "the load command did not count the fireworks lane"
  pass "the intake load command reports live lanes per provider against their caps"
}

test_under_cap_accepts
test_at_cap_refuses_with_provider_and_load
test_one_pool_counts_models_together_and_a_different_pool_stays_separate
test_dead_endpoint_frees_a_seat
test_operator_cap_config_is_honoured
test_load_command_reports_provider_load

echo "# all fm-provider-lane-cap tests passed"
