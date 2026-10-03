#!/usr/bin/env bash
# Behavior tests for the Grok crew-spawn refusal and session-lock holder detection.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

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

test_grok_crew_spawn_is_refused_before_wiring() {
  local rec case_dir home proj wt fakebin grok_home id out status
  rec=$(make_spawn_case refused)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id" 2>&1)
  status=$?
  expect_code 1 "$status" "grok crew spawn should be refused"
  assert_contains "$out" "spawn quota preflight refused 'grok'" "grok refusal did not come from the quota preflight"
  assert_absent "$grok_home/hooks/fm-turn-end.sh" "refused grok spawn installed the global turn-end hook"
  assert_absent "$wt/.fm-grok-turnend" "refused grok spawn wrote a worktree pointer"
  assert_absent "$home/state/$id.grok-turnend-token" "refused grok spawn wrote a state token"
  assert_absent "$home/state/$id.meta" "refused grok spawn published task meta"
  pass "grok crew spawn is refused before any hook or task wiring"
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

test_grok_crew_spawn_is_refused_before_wiring
test_fm_lock_recognizes_grok_holder
