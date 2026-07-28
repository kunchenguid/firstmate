#!/usr/bin/env bash
# Behavior tests for the axi agent tool PATH contract.
#
# Two halves, because the dangerous failure here is a SILENT partial success:
#
#   1. bin/fm-axi-path-lib.sh resolution - the happy path resolves the directory
#      dynamically from where the tools actually live, dedupes, warns loudly for an
#      individually uninstalled tool, and FAILS when no axi tool resolves at all.
#   2. bin/fm-spawn.sh integration - a resolvable directory is exported into the
#      agent's pane appended to PATH, and an unresolvable one refuses the spawn
#      before any endpoint or metadata exists.
#
# The refusal half is the point of the test: proving only the happy path would
# leave exactly the silent-launch failure this contract exists to prevent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-axi-path-lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-axi-path)
SCRATCH="$TMP_ROOT/scratch"
mkdir -p "$SCRATCH"

# A PATH with the ordinary system directories but WITHOUT whatever Node toolchain
# directory the real axi tools live in, so "required tool absent" is reproducible
# on a developer machine that has them installed.
BARE_PATH=/usr/bin:/bin:/usr/sbin:/sbin

make_axi_bin() {  # <dir> <tool>...
  local dir=$1 tool
  shift
  mkdir -p "$dir"
  # The resolver canonicalizes with cd/pwd, so hand back the canonical path and
  # keep every assertion comparing like with like.
  dir=$(cd "$dir" && pwd)
  for tool in "$@"; do
    cat > "$dir/$tool" <<SH
#!/usr/bin/env bash
printf '%s ok\n' "$tool"
SH
    chmod +x "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

# Run fm_axi_path_suffix with an exact PATH, capturing stdout, stderr and status
# separately so a warning is never mistaken for the resolved value.
run_suffix() {  # <path>
  local path=$1 errfile
  errfile="$SCRATCH/suffix.err.$$"
  SUFFIX_OUT=$(PATH="$path" bash -c '. "$1"; fm_axi_path_suffix' _ "$LIB" 2>"$errfile") \
    && SUFFIX_STATUS=0 || SUFFIX_STATUS=$?
  SUFFIX_ERR=$(cat "$errfile")
  rm -f "$errfile"
}

test_resolves_directory_from_actual_tool_location() {
  local dir
  dir=$(make_axi_bin "$TMP_ROOT/resolve/bin" tasks-axi gh-axi chrome-devtools-axi lavish-axi)

  run_suffix "$dir:$BARE_PATH"
  expect_code 0 "$SUFFIX_STATUS" "resolution should succeed when every axi tool is present"
  [ "$SUFFIX_OUT" = "$dir" ] || fail "suffix should be the directory the tools actually live in"$'\n'"expected: $dir"$'\n'"actual:   $SUFFIX_OUT"
  [ -z "$SUFFIX_ERR" ] || fail "a complete install should warn about nothing, got: $SUFFIX_ERR"
  pass "resolves the tool directory dynamically from where the tools actually live"
}

test_resolution_hardcodes_no_node_version() {
  local dir_a dir_b
  # The same lib, run against two unrelated install locations, must follow the
  # tools rather than any fixed toolchain path.
  dir_a=$(make_axi_bin "$TMP_ROOT/nover/a/bin" tasks-axi gh-axi chrome-devtools-axi)
  dir_b=$(make_axi_bin "$TMP_ROOT/nover/b/other-bin" tasks-axi gh-axi chrome-devtools-axi)

  run_suffix "$dir_a:$BARE_PATH"
  [ "$SUFFIX_OUT" = "$dir_a" ] || fail "expected $dir_a, got $SUFFIX_OUT"
  run_suffix "$dir_b:$BARE_PATH"
  [ "$SUFFIX_OUT" = "$dir_b" ] || fail "expected $dir_b, got $SUFFIX_OUT"
  assert_not_contains "$SUFFIX_OUT" "node/" "resolution must not assume a Node toolchain layout"
  pass "resolution follows the tools and assumes no Node version or install layout"
}

test_split_install_locations_are_all_carried() {
  local dir_req dir_exp
  dir_req=$(make_axi_bin "$TMP_ROOT/split/req" tasks-axi)
  dir_exp=$(make_axi_bin "$TMP_ROOT/split/exp" gh-axi chrome-devtools-axi)

  run_suffix "$dir_req:$dir_exp:$BARE_PATH"
  expect_code 0 "$SUFFIX_STATUS" "a split install should still resolve"
  [ "$SUFFIX_OUT" = "$dir_req:$dir_exp" ] || fail "both install directories should be carried"$'\n'"expected: $dir_req:$dir_exp"$'\n'"actual:   $SUFFIX_OUT"
  pass "tools installed in separate directories are all carried into the suffix"
}

test_shared_directory_is_not_duplicated() {
  local dir
  dir=$(make_axi_bin "$TMP_ROOT/dedupe/bin" tasks-axi gh-axi chrome-devtools-axi lavish-axi)

  run_suffix "$dir:$BARE_PATH"
  case "$SUFFIX_OUT" in
    *:*) fail "one shared directory should appear once, got: $SUFFIX_OUT" ;;
  esac
  pass "one shared install directory is emitted once, not once per tool"
}

test_individually_missing_tool_warns_but_still_resolves() {
  local dir
  # One tool installed, the rest genuinely absent: an install gap, not the
  # toolchain-resolved-away failure, so the fleet keeps moving with a loud warning.
  dir=$(make_axi_bin "$TMP_ROOT/warn/bin" tasks-axi)

  run_suffix "$dir:$BARE_PATH"
  expect_code 0 "$SUFFIX_STATUS" "an uninstalled tool is an install gap, not a resolution failure"
  [ "$SUFFIX_OUT" = "$dir" ] || fail "expected $dir, got $SUFFIX_OUT"
  assert_contains "$SUFFIX_ERR" "gh-axi" "warning should name an absent tool"
  assert_contains "$SUFFIX_ERR" "chrome-devtools-axi" "warning should name every absent tool"
  assert_contains "$SUFFIX_ERR" "instructions tell it to use them" \
    "warning should say why an absent tool matters"
  pass "an individually uninstalled tool warns loudly so the brief instruction is never silently false"
}

test_no_tool_resolving_fails_with_actionable_message() {
  # Every axi tool gone at once: the signature of a project toolchain resolving
  # away from the one they were installed into.
  run_suffix "$BARE_PATH"
  expect_code 1 "$SUFFIX_STATUS" "an unresolvable tool directory must fail, not resolve to nothing"
  [ -z "$SUFFIX_OUT" ] || fail "a failed resolution must print no suffix, got: $SUFFIX_OUT"
  assert_contains "$SUFFIX_ERR" "cannot resolve the axi agent tool directory" \
    "failure should name the unresolvable directory"
  assert_contains "$SUFFIX_ERR" "tasks-axi" "failure should name the missing tools"
  assert_contains "$SUFFIX_ERR" "Node toolchain they were installed into is not active" \
    "failure should name the likely cause"
  assert_contains "$SUFFIX_ERR" "npm install -g" "failure should be actionable"
  pass "an unresolvable tool directory fails with a clear, actionable message"
}

# --- fm-spawn.sh integration -------------------------------------------------

make_spawn_fakebin() {  # <dir> [--with-axi]
  local dir=$1 with_axi=${2:-} fakebin
  fakebin=$(fm_fakebin "$dir")
  fakebin=$(cd "$fakebin" && pwd)
  # Logs BOTH plain send-keys lines (the env exports) and literal -l sends (the
  # launch command), so the PATH export is asserted as sent, not inferred.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_SEND_LOG:-}" ]; then
      shift
      prev=
      for a in "$@"; do
        case "$a" in
          -t|-l|Enter) prev=$a; continue ;;
        esac
        [ "$prev" = "-t" ] || printf '%s\n' "$a" >> "$FM_FAKE_SEND_LOG"
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi-signed
  if [ "$with_axi" = --with-axi ]; then
    make_axi_bin "$fakebin" tasks-axi gh-axi chrome-devtools-axi lavish-axi >/dev/null
  fi
  printf '%s\n' "$fakebin"
}

make_spawn_case() {  # <name> <task-id> [--with-axi]
  local name=$1 id=$2 with_axi=${3:-} case_dir home proj wt fakebin sendlog
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  sendlog="$case_dir/send.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" "$with_axi")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$sendlog"
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR SEND_LOG <<EOF
$1
EOF
}

run_spawn() {  # <home> <wt> <fakebin> <sendlog> <path> <spawn args...>
  local home=$1 wt=$2 fakebin=$3 sendlog=$4 path=$5
  shift 5
  : > "$sendlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_SEND_LOG="$sendlog" PATH="$fakebin:$path" \
    "$SPAWN" "$@" 2>&1
}

test_spawn_exports_the_tool_directory_appended_to_path() {
  local rec id out status export_line expected
  id=axi-export-a1
  rec=$(make_spawn_case export "$id" --with-axi)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SEND_LOG" "$BARE_PATH" "$id" "$PROJ_DIR") \
    && status=0 || status=$?
  expect_code 0 "$status" "spawn with resolvable axi tools should succeed: $out"

  export_line=$(grep '^export PATH=' "$SEND_LOG" || true)
  [ -n "$export_line" ] || fail "spawn did not export a PATH into the agent's shell"$'\n'"sent: $(cat "$SEND_LOG")"
  expected="export PATH=\"\$PATH\":'$FAKEBIN_DIR'"
  [ "$export_line" = "$expected" ] || \
    fail "PATH export should APPEND the quoted tool directory so a project's own node/npm still wins"$'\n'"expected: $expected"$'\n'"actual:   $export_line"
  pass "spawn exports the resolved axi tool directory appended to the agent's PATH"
}

test_spawn_refuses_when_tool_directory_is_unresolvable() {
  local rec id out status
  id=axi-refuse-b2
  # No --with-axi: the fake bin dir has tmux/treehouse but no axi tools, and the
  # bare PATH excludes the real install location.
  rec=$(make_spawn_case refuse "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SEND_LOG" "$BARE_PATH" "$id" "$PROJ_DIR") \
    && status=0 || status=$?
  expect_code 1 "$status" "spawn must refuse when the axi tool directory cannot be resolved"
  assert_contains "$out" "cannot resolve the axi agent tool directory" \
    "refusal should say what could not be resolved"
  assert_contains "$out" "npm install -g tasks-axi" "refusal should be actionable"
  assert_absent "$HOME_DIR/state/$id.meta" "refusal must happen before task metadata is written"
  [ ! -s "$SEND_LOG" ] || fail "refusal must happen before anything is sent to an endpoint"$'\n'"sent: $(cat "$SEND_LOG")"
  pass "an unresolvable tool directory refuses the spawn before any endpoint or metadata exists"
}

test_resolves_directory_from_actual_tool_location
test_resolution_hardcodes_no_node_version
test_split_install_locations_are_all_carried
test_shared_directory_is_not_duplicated
test_individually_missing_tool_warns_but_still_resolves
test_no_tool_resolving_fails_with_actionable_message
test_spawn_exports_the_tool_directory_appended_to_path
test_spawn_refuses_when_tool_directory_is_unresolvable
