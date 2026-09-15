#!/usr/bin/env bash
# tests/fm-launcher.test.sh - refuse container-root launches; no auto-register.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-launcher)
export HOME="$TMP_ROOT/home"
FM_HOME_DIR="$HOME/firstmate"
mkdir -p "$FM_HOME_DIR" "$HOME/Desktop/projects/secret-zoo" "$HOME/projects"
printf '# Firstmate\n' > "$FM_HOME_DIR/AGENTS.md"
mkdir -p "$FM_HOME_DIR/bin" "$FM_HOME_DIR/data" "$FM_HOME_DIR/state" "$FM_HOME_DIR/projects"
cp "$ROOT/bin/fm-session-lock-lib.sh" "$FM_HOME_DIR/bin/"
# cursor lib is sourced by session-lock-lib
if [ -f "$ROOT/bin/fm-cursor-lib.sh" ]; then
  cp "$ROOT/bin/fm-cursor-lib.sh" "$FM_HOME_DIR/bin/"
fi
touch "$HOME/Desktop/projects/secret-zoo/package.json"

test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-launcher.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-launcher.sh must parse cleanly"
  [ -z "$out" ] || fail "bash -n bin/fm-launcher.sh emitted unexpected output: $out"
  pass "fm-launcher.sh: bash -n succeeds"
}

test_help_from_anywhere() {
  local out rc
  out=$(cd "$HOME" && FM_HOME_DIR="$FM_HOME_DIR" bash "$ROOT/bin/fm-launcher.sh" --help 2>&1); rc=$?
  expect_code 0 "$rc" "launcher --help must succeed from \$HOME"
  echo "$out" | grep -q "doctor" || fail "help must list doctor"
  echo "$out" | grep -q "Rejected launch directories" || fail "help must name rejected launch directories"
  pass "fm-launcher.sh: --help works from \$HOME"
}

test_refuse_home_launch() {
  local out rc
  set +e
  out=$(cd "$HOME" && FM_HOME_DIR="$FM_HOME_DIR" bash "$ROOT/bin/fm-launcher.sh" pi 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "launcher must refuse \$HOME"
  echo "$out" | grep -q "refusing to launch" || fail "refusal must name the launch directory"
  echo "$out" | grep -q "cd $FM_HOME_DIR" || fail "refusal must tell the operator where to start"
  pass "fm-launcher.sh: refuses \$HOME"
}

test_refuse_desktop_projects_container() {
  local out rc
  set +e
  out=$(cd "$HOME/Desktop/projects" && FM_HOME_DIR="$FM_HOME_DIR" bash "$ROOT/bin/fm-launcher.sh" pi 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "launcher must refuse ~/Desktop/projects"
  [ ! -e "$FM_HOME_DIR/projects/projects" ] || fail "launcher must not symlink the projects container"
  [ ! -f "$FM_HOME_DIR/data/projects.md" ] || fail "launcher must not auto-register from a container directory"
  pass "fm-launcher.sh: refuses the Desktop/projects container and does not auto-register"
}

test_script_parses
test_help_from_anywhere
test_refuse_home_launch
test_refuse_desktop_projects_container
