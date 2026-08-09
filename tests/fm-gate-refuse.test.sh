#!/usr/bin/env bash
# Behavior tests for the no-mistakes gate-agent fleet-lifecycle refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE_LIB="$ROOT/bin/fm-gate-refuse-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-gate-refuse)

make_normal_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" -c user.name=tests -c user.email=tests@example.invalid commit -qm init --allow-empty
  mkdir -p "$dir/bin"
  cp "$GATE_LIB" "$dir/bin/fm-gate-refuse-lib.sh"
  printf '%s\n' "$dir"
}

make_gate_worktree() {
  local root=$1 seed bare wt
  seed="$root/seed"
  bare="$root/.no-mistakes/repos/fixture.git"
  wt="$root/.no-mistakes/worktrees/fixture/run"
  mkdir -p "$root/.no-mistakes/repos"
  git init -q -b main "$seed"
  git -C "$seed" -c user.name=tests -c user.email=tests@example.invalid commit -qm init --allow-empty
  git clone -q --bare "$seed" "$bare"
  mkdir -p "$(dirname "$wt")"
  git --git-dir="$bare" worktree add --detach -q "$wt" main
  mkdir -p "$wt/bin"
  cp "$GATE_LIB" "$wt/bin/fm-gate-refuse-lib.sh"
  printf '%s\n' "$wt"
}

run_helper() {
  local cwd marker lib
  cwd=$1
  marker=${2:-unset}
  lib=${3:-$cwd/bin/fm-gate-refuse-lib.sh}
  (
    cd "$cwd" || exit 1
    unset NO_MISTAKES_GATE FM_ROOT_OVERRIDE FM_HOME FM_PROJECTS_OVERRIDE \
      FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
    # The marker is intentionally scoped to this child shell.
    # shellcheck disable=SC2030
    case "$marker" in
      set) export NO_MISTAKES_GATE=1 ;;
      empty) export NO_MISTAKES_GATE= ;;
    esac
    # shellcheck source=bin/fm-gate-refuse-lib.sh
    . "$lib"
    fm_refuse_if_gate_agent
  ) 2>&1
}

run_helper_with_override() {
  local cwd name path lib
  cwd=$1
  name=$2
  path=$3
  lib=${4:-$cwd/bin/fm-gate-refuse-lib.sh}
  (
    cd "$cwd" || exit 1
    unset NO_MISTAKES_GATE FM_ROOT_OVERRIDE FM_HOME FM_PROJECTS_OVERRIDE \
      FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
    export "$name=$path"
    # shellcheck source=bin/fm-gate-refuse-lib.sh
    . "$lib"
    fm_refuse_if_gate_agent
  ) 2>&1
}

run_entrypoint() {
  local script=$1 cwd=$2 marker=$3 rc out
  set +e
  if [ "$marker" = unset ]; then
    out=$(cd "$cwd" && env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_HOME \
      -u FM_PROJECTS_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
      -u FM_CONFIG_OVERRIDE \
      bash "$script" 2>&1)
  else
    out=$(cd "$cwd" && env -u FM_ROOT_OVERRIDE -u FM_HOME \
      -u FM_PROJECTS_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
      -u FM_CONFIG_OVERRIDE NO_MISTAKES_GATE="$marker" \
      bash "$script" 2>&1)
  fi
  rc=$?
  set -e
  printf '%s\n%s\n' "$rc" "$out"
}

run_entrypoint_with_override() {
  local script=$1 cwd=$2 name=$3 path=$4 rc out
  set +e
  out=$(cd "$cwd" && env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_HOME \
    -u FM_PROJECTS_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE "$name=$path" \
    bash "$script" 2>&1)
  rc=$?
  set -e
  printf '%s\n%s\n' "$rc" "$out"
}

NORMAL_CWD=$(make_normal_repo "$TMP_ROOT/normal")
GATE_CWD=$(make_gate_worktree "$TMP_ROOT/gate")

test_helper_signals() {
  local out rc
  out=$(run_helper "$NORMAL_CWD" set); rc=$?
  expect_code 3 "$rc" "set marker must refuse"
  assert_contains "$out" 'NO_MISTAKES_GATE set' "set marker message missing"

  out=$(run_helper "$NORMAL_CWD" empty); rc=$?
  expect_code 3 "$rc" "empty marker must refuse"
  assert_contains "$out" 'NO_MISTAKES_GATE set' "empty marker message missing"

  out=$(run_helper "$GATE_CWD"); rc=$?
  expect_code 3 "$rc" "gate worktree must refuse with marker unset"
  assert_contains "$out" 'no-mistakes gate worktree' "gate path backstop message missing"

  out=$(run_helper "$TMP_ROOT" unset "$GATE_CWD/bin/fm-gate-refuse-lib.sh"); rc=$?
  expect_code 3 "$rc" "gate library must refuse when called from outside the checkout"
  assert_contains "$out" 'no-mistakes gate worktree' "gate library source-path refusal missing"

  for override in FM_ROOT_OVERRIDE FM_HOME FM_PROJECTS_OVERRIDE FM_STATE_OVERRIDE \
    FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE; do
    out=$(run_helper_with_override "$NORMAL_CWD" "$override" "$GATE_CWD/nonexistent"); rc=$?
    expect_code 3 "$rc" "$override must refuse with marker unset"
    assert_contains "$out" 'no-mistakes gate worktree' "$override refusal missing"
  done

  out=$(run_helper "$NORMAL_CWD"); rc=$?
  expect_code 0 "$rc" "normal worktree must be unaffected"
  [ -z "$out" ] || fail "normal worktree printed a refusal: $out"
  pass "gate refusal helper covers marker, empty marker, path backstop, and normal session"
}

test_entrypoints_refuse() {
  local script gate_script out rc first
  for script in "$ROOT/bin/fm-spawn.sh" "$ROOT/bin/fm-send.sh" "$ROOT/bin/fm-teardown.sh"; do
    # Use a copy rooted in the synthetic gate worktree for path-backstop cases.
    # The main checkout is ordinary on CI, so its source path is not itself a
    # no-mistakes gate path as it is in the local gate worktree.
    gate_script="$GATE_CWD/bin/$(basename "$script")"
    cp "$script" "$gate_script"

    out=$(run_entrypoint "$script" "$NORMAL_CWD" set)
    first=${out%%$'\n'*}
    rc=$first
    expect_code 3 "$rc" "$(basename "$script") must refuse the gate marker"
    assert_contains "$out" 'NO_MISTAKES_GATE set' "$(basename "$script") marker refusal missing"

    out=$(run_entrypoint "$gate_script" "$GATE_CWD" unset)
    first=${out%%$'\n'*}
    rc=$first
    expect_code 3 "$rc" "$(basename "$script") must refuse the gate path backstop"
    assert_contains "$out" 'no-mistakes gate worktree' "$(basename "$script") path refusal missing"

    out=$(run_entrypoint "$gate_script" "$TMP_ROOT" unset)
    first=${out%%$'\n'*}
    rc=$first
    expect_code 3 "$rc" "$(basename "$script") must refuse when called from outside the checkout"
    assert_contains "$out" 'no-mistakes gate worktree' "$(basename "$script") source-path refusal missing"

    for override in FM_ROOT_OVERRIDE FM_HOME FM_PROJECTS_OVERRIDE FM_STATE_OVERRIDE \
      FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE; do
      out=$(run_entrypoint_with_override "$script" "$NORMAL_CWD" "$override" \
        "$GATE_CWD/nonexistent")
      first=${out%%$'\n'*}
      rc=$first
      expect_code 3 "$rc" "$(basename "$script") must refuse $override"
      assert_contains "$out" 'no-mistakes gate worktree' \
        "$(basename "$script") $override refusal missing"
    done
  done
  pass "spawn, send, and teardown refuse both gate signals before lifecycle work"
}

test_tracked_contracts() {
  local config_json status
  config_json=$(python3 "$ROOT/tests/workflow-contract.py" "$ROOT/.no-mistakes.yaml")
  CONFIG_JSON="$config_json" python3 - <<'PY'
import json
import os

config = json.loads(os.environ["CONFIG_JSON"])
assert config["disable_project_settings"] is True
PY
  status=$?
  expect_code 0 "$status" "the gate configuration must disable project settings"
  out=$(run_helper "$NORMAL_CWD" set); rc=$?
  expect_code 3 "$rc" "the live refusal consumer must reject the gate marker"
  assert_contains "$out" 'NO_MISTAKES_GATE set' "the live refusal consumer lost its marker error"
  pass "the live gate refusal consumer rejects the gate marker"
}

test_helper_signals
test_entrypoints_refuse
test_tracked_contracts
echo '# all fm-gate-refuse tests passed'
