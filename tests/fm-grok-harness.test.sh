#!/usr/bin/env bash
# Behavior tests for Grok-harness hook authentication, teardown cleanup, and session-lock holder detection.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-grok-harness)

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin grok_home id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" gh-axi gh)
  grok_home="$case_dir/grok"
  id="grok-$name-x1"
  mkdir -p "$grok_home"
  fm_test_spawn_home "$home"
  fm_test_spawn_brief "$home" "$id" brief
  fm_git_worktree "$proj" "$wt" "fm/$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$grok_home|$id"
}

run_grok_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 grok_home=$5 id=$6
  GROK_HOME="$grok_home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj" grok --mode no-mistakes --yolo off
}

test_grok_hook_requires_registered_token() {
  local rec case_dir home proj wt fakebin grok_home id out status hook token target evil evil_target
  rec=$(make_spawn_case hook-auth)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed"
  assert_contains "$out" "spawned $id harness=grok" "grok spawn did not report success"

  hook="$grok_home/hooks/fm-turn-end.sh"
  assert_present "$hook" "grok hook script was not installed"
  assert_grep 'token=' "$wt/.fm-grok-turnend" "grok pointer did not contain a token"
  target="$home/state/$id.turn-ended"
  assert_no_grep "$target" "$wt/.fm-grok-turnend" "grok pointer exposed the turn-end path"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")
  assert_present "$grok_home/hooks/fm-turn-end.d/$token" "grok auth registry entry was not written"

  evil="$case_dir/evil"
  evil_target="$case_dir/evil-target.turn-ended"
  mkdir -p "$evil"
  printf '%s\n' "$evil_target" > "$evil/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$evil" bash "$hook"
  assert_absent "$evil_target" "old-style grok pointer touched an arbitrary target"

  {
    printf '%s\n' 'ignored'
    printf 'token=%s\n' "$token"
  } > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_absent "$target" "grok pointer accepted token outside the first line"

  printf 'token=%s\n' "$token" > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_present "$target" "registered grok pointer did not touch the task turn-end file"
  pass "grok global hook requires a firstmate registry token"
}

test_grok_teardown_removes_pointer_and_token() {
  local rec case_dir home proj wt fakebin grok_home id out status token
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "grok teardown failed"

  assert_absent "$wt/.fm-grok-turnend" "grok pointer survived teardown"
  assert_absent "$grok_home/hooks/fm-turn-end.d/$token" "grok auth token survived teardown"
  assert_absent "$home/state/$id.grok-turnend-token" "grok state token survived teardown"
  pass "grok teardown removes pointer and token state"
}

test_fm_lock_recognizes_grok_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/grok'; exit 0 ;;
  *"args="*) printf '%s\n' 'grok'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize grok as a live holder"
  pass "fm-lock recognizes grok harness processes"
}

# Wrap the spawn tmux so a pane capture shows the given fixture screen.
# Everything else, including the launch logging, is the stock fake.
grok_fake_pane() {  # <fakebin> <fixture-txt-or-empty> <cursor-row>
  local fakebin=$1 screen=$2 cursor=$3
  [ -e "$fakebin/tmux-base" ] || mv "$fakebin/tmux" "$fakebin/tmux-base"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *cursor_y*) printf '%s\n' '$cursor'; exit 0 ;;
esac
case "\${1:-}" in
  capture-pane) [ -z '$screen' ] || cat '$screen'; exit 0 ;;
esac
exec '$fakebin/tmux-base' "\$@"
SH
  chmod +x "$fakebin/tmux"
}

test_grok_spawn_surfaces_trust_dialog_without_typing() {
  local v rec case_dir home proj wt fakebin grok_home id out status launches
  for v in 1.0.52 1.0.62; do
    rec=$(make_spawn_case "trust-$v")
    IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
    grok_fake_pane "$fakebin" "$ROOT/tests/fixtures/grok-$v/trust-dialog.txt" 1
    : > "$case_dir/launch.log"
    out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" FM_GROK_POLL_INTERVAL=0 \
      run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
    status=$?
    expect_code 0 "$status" "a spawn parked on the grok $v trust dialog should still succeed"
    assert_contains "$out" "spawned $id harness=grok" "the $v spawn did not report success"
    assert_contains "$out" "Grok folder-trust dialog is open" "the $v spawn did not surface the trust dialog"
    assert_contains "$out" "fm-send.sh $id --key Enter" "the $v spawn did not name the sanctioned answer"
    assert_grep 'blocked [key=grok-trust-dialog] [at=' "$home/state/$id.status" "the $v spawn did not record the open blocker"
    launches=$(grep -c . "$case_dir/launch.log" || true)
    [ "$launches" -eq 1 ] || fail "the $v spawn typed more than the launch command: $(cat "$case_dir/launch.log")"
  done
  pass "grok spawn surfaces the 1.0.52 and 1.0.62 trust dialogs as an open blocker and types nothing into them"
}

test_grok_spawn_is_quiet_on_a_trusted_folder() {
  local v rec case_dir home proj wt fakebin grok_home id out status row
  for v in 1.0.52 1.0.62; do
    rec=$(make_spawn_case "idle-$v")
    IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
    row=$(awk '/^ *│ ❯/ { print NR - 1; exit }' "$ROOT/tests/fixtures/grok-$v/idle-composer-banner.txt")
    grok_fake_pane "$fakebin" "$ROOT/tests/fixtures/grok-$v/idle-composer-banner.txt" "$row"
    out=$(FM_GROK_POLL_INTERVAL=0 run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
    status=$?
    expect_code 0 "$status" "a spawn onto the grok $v idle composer should succeed"
    assert_not_contains "$out" "trust dialog" "the $v idle composer was reported as a trust dialog"
    [ ! -e "$home/state/$id.status" ] || assert_no_grep 'grok-trust-dialog' "$home/state/$id.status" "the $v idle composer recorded a trust blocker"
  done
  # A pane that shows nothing for the whole budget is not a dialog either.
  rec=$(make_spawn_case blank)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  grok_fake_pane "$fakebin" '' 1
  out=$(FM_GROK_TRUST_POLLS=3 FM_GROK_POLL_INTERVAL=0 run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "a spawn onto a blank pane should succeed"
  [ ! -e "$home/state/$id.status" ] || assert_no_grep 'grok-trust-dialog' "$home/state/$id.status" "a blank pane recorded a trust blocker"
  pass "grok spawn reports nothing on an idle composer or a blank pane"
}

test_grok_hook_requires_registered_token
test_grok_teardown_removes_pointer_and_token
test_grok_spawn_surfaces_trust_dialog_without_typing
test_grok_spawn_is_quiet_on_a_trusted_folder
test_fm_lock_recognizes_grok_holder
