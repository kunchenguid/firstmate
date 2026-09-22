#!/usr/bin/env bash
# tests/fm-spawn-launch-delivery.test.sh - spawn launch commands are delivered
# through the pane's executable interface without terminal-line truncation or
# destination-shell quoting drift.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-launch-delivery)
LAUNCH_DIRS=(
  "/tmp/fm-launch-delivery-raw-a1"
  "/tmp/fm-launch-delivery-raw-a1+"* "/tmp/fm-launch-delivery-raw-a1."
  "/tmp/fm-launch-delivery-claude-b1"
  "/tmp/fm-launch-delivery-claude-b1+"* "/tmp/fm-launch-delivery-claude-b1."
)

fm_launch_delivery_cleanup() {
  local d
  for d in "${LAUNCH_DIRS[@]}"; do
    rm -rf -- "$d" 2>/dev/null
  done
  rm -rf "$TMP_ROOT"
}
trap fm_launch_delivery_cleanup EXIT INT TERM HUP QUIT

shell_quote_py() {  # <text>
  python3 - "$1" <<'PY'
import shlex
import sys
print(shlex.quote(sys.argv[1]))
PY
}

make_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  : > "$LAUNCH_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

test_long_quoted_raw_launch_reaches_destination_shell_intact() {
  local rec id marker payload payload_q marker_q raw out rc delivered
  id='launch-delivery-raw-a1'
  rec=$(make_case raw-long-quoted "$id")
  read_case "$rec"
  marker="$CASE_DIR/result.txt"
  payload="prefix 'single quoted' \"double quoted\" literal command substitution \$(printf should-not-run) $(python3 - <<'PY'
print('A' * 1800)
PY
) suffix-after-long-padding"
  payload_q=$(shell_quote_py "$payload")
  marker_q=$(shell_quote_py "$marker")
  raw="/bin/sh -c $(shell_quote_py "printf '%s\\n' $payload_q > $marker_q")"

  out=$(run_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --harness "$raw")
  rc=$?
  expect_code 0 "$rc" "raw long launch spawn should succeed: $out"
  [ -s "$LAUNCH_LOG" ] || fail "spawn did not deliver a launch command to the pane"
  # Execute the exact command captured from the pane delivery interface, proving
  # the staged transport preserved a shell command the destination shell can parse.
  env -i PATH=/usr/bin:/bin /bin/sh -c "$(cat "$LAUNCH_LOG")" \
    || fail "delivered launch command did not parse or execute in the destination shell"
  delivered=$(cat "$marker" 2>/dev/null || true)
  assert_equals "$payload" "$delivered" \
    "long quoted launch command was truncated or shell-parsed differently after pane delivery"
  case "$(cat "$LAUNCH_LOG")" in
    *suffix-after-long-padding*) ;;
    *) fail "captured launch command lost its long-command suffix" ;;
  esac
  pass "fm-spawn launch delivery: long quoted raw commands survive pane transport and destination-shell parsing"
}

test_claude_launch_is_delivered_from_staged_source_file() {
  local rec id out rc launch
  id='launch-delivery-claude-b1'
  rec=$(make_case claude-staged "$id")
  read_case "$rec"
  out=$(run_spawn "$id" "$PROJ_DIR" claude --mode no-mistakes --yolo off)
  rc=$?
  expect_code 0 "$rc" "claude launch spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" 'claude --dangerously-skip-permissions' \
    "claude launch did not reach the pane-delivered command"
  local command_substitution_marker
  command_substitution_marker="\"\$("
  assert_contains "$launch" "$command_substitution_marker" \
    "claude launch should let the destination shell read the brief through command substitution"
  assert_contains "$launch" "$HOME_DIR/data/$id/launch-brief.md" \
    "claude launch did not preserve the generated brief path"
  pass "fm-spawn launch delivery: claude launch command reaches the pane through the staged command path"
}

test_long_quoted_raw_launch_reaches_destination_shell_intact
test_claude_launch_is_delivered_from_staged_source_file

echo "# all fm-spawn-launch-delivery tests passed"
