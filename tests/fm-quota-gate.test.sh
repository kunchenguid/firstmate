#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-gate.sh (the Claude-provider quota check:
# minimum percentRemaining across the claude provider's five_hour/seven_day
# GENERAL windows, ignoring model:* windows, against FM_QUOTA_PAUSE_PCT/
# FM_QUOTA_SONNET_ONLY_PCT, with a fail-open contract) and its wiring into
# bin/fm-spawn.sh (crewmate/scout gating, secondmate exemption,
# FM_QUOTA_OVERRIDE).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

GATE="$ROOT/bin/fm-quota-gate.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"

# --- bin/fm-quota-gate.sh direct tests --------------------------------------

# make_quota_fakebin <dir> <five_hour> <seven_day> [fable] -> echoes a fakebin
# whose quota-axi stub reports the given percentRemaining for the claude
# provider's five_hour/seven_day windows, plus an optional model:fable window
# (default 50) to prove model-scoped windows never affect the result.
make_quota_fakebin() {
  local dir=$1 five=$2 seven=$3 fable=${4:-50} fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
cat <<JSON
{"providers":[{"provider":"claude","windows":[
  {"id":"five_hour","percentRemaining":$five},
  {"id":"seven_day","percentRemaining":$seven},
  {"id":"model:fable","percentRemaining":$fable}
]}]}
JSON
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

# run_gate <fakebin> [ASSIGN...] -> combined output, shadowing the real
# quota-axi with the fakebin's stub (fakebin first on PATH).
run_gate() {
  local fakebin=$1; shift
  ( env -u FM_QUOTA_PAUSE_PCT -u FM_QUOTA_SONNET_ONLY_PCT "PATH=$fakebin:$PATH" "$@" "$GATE" ) 2>&1
}

test_ok_above_both_thresholds() {
  local fb out rc
  fb=$(make_quota_fakebin "$(fm_test_tmproot quota-ok)" 88 97)
  out=$(run_gate "$fb"); rc=$?
  expect_code 0 "$rc" "ok: exit code"
  assert_contains "$out" "ok remaining=88" "ok: status line"
  pass "fm-quota-gate: reports ok above both thresholds"
}

test_takes_minimum_of_the_two_general_windows() {
  local fb out
  fb=$(make_quota_fakebin "$(fm_test_tmproot quota-min-a)" 97 88)
  out=$(run_gate "$fb")
  assert_contains "$out" "ok remaining=88" "min: seven_day lower must win"
  fb=$(make_quota_fakebin "$(fm_test_tmproot quota-min-b)" 35 90)
  out=$(run_gate "$fb")
  assert_contains "$out" "sonnet-only remaining=35" "min: five_hour lower must win"
  pass "fm-quota-gate: takes the minimum percentRemaining across five_hour and seven_day"
}

test_floors_fractional_percent_remaining() {
  local fb out rc
  # 40.9 must floor to 40 (at-or-below the default sonnet-only threshold of
  # 40), not round to 41 (which would wrongly read as "ok") and not be
  # rejected as non-numeric (quota-axi's real output is rarely a whole number).
  fb=$(make_quota_fakebin "$(fm_test_tmproot quota-fractional)" 40.9 97.3)
  out=$(run_gate "$fb"); rc=$?
  expect_code 1 "$rc" "fractional: exit code"
  assert_contains "$out" "sonnet-only remaining=40" "fractional: floors 40.9 down to 40, not rounds to 41"
  pass "fm-quota-gate: floors a fractional percentRemaining instead of rounding or rejecting it"
}

test_model_scoped_window_is_ignored() {
  local fb out
  # model:fable is deep in pause territory, but the two GENERAL windows are
  # healthy - the gate must still report ok, proving it never reads model:* windows.
  fb=$(make_quota_fakebin "$(fm_test_tmproot quota-model-ignore)" 90 95 3)
  out=$(run_gate "$fb")
  assert_contains "$out" "ok remaining=90" "model-scoped: a low model:fable window must not affect the result"
  pass "fm-quota-gate: ignores model:* windows, only five_hour/seven_day count"
}

test_sonnet_only_band() {
  local fb out rc
  fb=$(make_quota_fakebin "$(fm_test_tmproot quota-sonnet-only)" 35 90)
  out=$(run_gate "$fb"); rc=$?
  expect_code 1 "$rc" "sonnet-only: exit code"
  assert_contains "$out" "sonnet-only remaining=35" "sonnet-only: status line"
  pass "fm-quota-gate: reports sonnet-only between the pause and sonnet-only thresholds"
}

test_pause_band() {
  local fb out rc
  fb=$(make_quota_fakebin "$(fm_test_tmproot quota-pause)" 15 90)
  out=$(run_gate "$fb"); rc=$?
  expect_code 2 "$rc" "pause: exit code"
  assert_contains "$out" "pause remaining=15" "pause: status line"
  pass "fm-quota-gate: reports pause at or below the pause threshold"
}

test_thresholds_are_env_overridable() {
  local fb out
  fb=$(make_quota_fakebin "$(fm_test_tmproot quota-thresh)" 55 90)
  out=$(run_gate "$fb" FM_QUOTA_SONNET_ONLY_PCT=60)
  assert_contains "$out" "sonnet-only remaining=55" "thresholds: raised sonnet-only threshold must catch 55"
  out=$(run_gate "$fb" FM_QUOTA_PAUSE_PCT=60)
  assert_contains "$out" "pause remaining=55" "thresholds: raised pause threshold must catch 55 as pause"
  pass "fm-quota-gate: FM_QUOTA_SONNET_ONLY_PCT/FM_QUOTA_PAUSE_PCT are env-overridable"
}

test_fail_open_missing_quota_axi() {
  local fb out rc
  fb=$(fm_fakebin "$(fm_test_tmproot quota-missing)")
  # A restricted PATH (no ~/.local/bin) so the real quota-axi cannot be found
  # either - the fakebin here deliberately has no quota-axi stub in it.
  out=$(env -u FM_QUOTA_PAUSE_PCT -u FM_QUOTA_SONNET_ONLY_PCT "PATH=$fb:/usr/bin:/bin" "$GATE" 2>&1); rc=$?
  expect_code 0 "$rc" "fail-open missing: exit code must be ok's 0"
  assert_contains "$out" "ok remaining=unknown" "fail-open missing: status line"
  assert_contains "$out" "quota-axi not found" "fail-open missing: stderr warning"
  pass "fm-quota-gate: fails open (ok remaining=unknown) when quota-axi is missing from PATH"
}

test_fail_open_quota_axi_errors() {
  local fb out rc
  fb=$(fm_fakebin "$(fm_test_tmproot quota-errors)")
  cat > "$fb/quota-axi" <<'SH'
#!/usr/bin/env bash
echo "boom" >&2
exit 1
SH
  chmod +x "$fb/quota-axi"
  out=$(run_gate "$fb"); rc=$?
  expect_code 0 "$rc" "fail-open erroring: exit code must be ok's 0"
  assert_contains "$out" "ok remaining=unknown" "fail-open erroring: status line"
  assert_contains "$out" "exited non-zero" "fail-open erroring: stderr warning"
  pass "fm-quota-gate: fails open when quota-axi exits non-zero"
}

test_fail_open_unparseable_output() {
  local fb out rc
  fb=$(fm_fakebin "$(fm_test_tmproot quota-badjson)")
  cat > "$fb/quota-axi" <<'SH'
#!/usr/bin/env bash
echo "not json at all"
SH
  chmod +x "$fb/quota-axi"
  out=$(run_gate "$fb"); rc=$?
  expect_code 0 "$rc" "fail-open unparseable: exit code must be ok's 0"
  assert_contains "$out" "ok remaining=unknown" "fail-open unparseable: status line"
  pass "fm-quota-gate: fails open when quota-axi output is not valid JSON"
}

test_fail_open_missing_windows() {
  local fb out rc
  fb=$(fm_fakebin "$(fm_test_tmproot quota-nowindows)")
  cat > "$fb/quota-axi" <<'SH'
#!/usr/bin/env bash
echo '{"providers":[{"provider":"claude","windows":[{"id":"model:fable","percentRemaining":50}]}]}'
SH
  chmod +x "$fb/quota-axi"
  out=$(run_gate "$fb"); rc=$?
  expect_code 0 "$rc" "fail-open missing windows: exit code must be ok's 0"
  assert_contains "$out" "ok remaining=unknown" "fail-open missing windows: status line"
  pass "fm-quota-gate: fails open when claude's five_hour/seven_day windows are absent"
}

test_fail_open_bad_threshold_env() {
  local fb out rc
  fb=$(make_quota_fakebin "$(fm_test_tmproot quota-badthresh)" 88 97)
  out=$(run_gate "$fb" FM_QUOTA_PAUSE_PCT=notanumber); rc=$?
  expect_code 0 "$rc" "fail-open bad threshold: exit code must be ok's 0"
  assert_contains "$out" "ok remaining=unknown" "fail-open bad threshold: status line"
  pass "fm-quota-gate: fails open when a threshold env var is not a non-negative integer"
}

# --- bin/fm-spawn.sh wiring --------------------------------------------------

make_normal_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# A fake tmux/treehouse so fm-spawn resolves the crew worktree from a
# controlled pane path and completes without a live terminal, plus a
# quota-axi stub reporting the given five_hour/seven_day percentRemaining
# (mirrors tests/fm-gate-refuse.test.sh's make_spawn_fakebin).
make_spawn_fakebin() {  # <dir> <five_hour> <seven_day>
  local dir=$1 five=$2 seven=$3 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
cat <<JSON
{"providers":[{"provider":"claude","windows":[{"id":"five_hour","percentRemaining":$five},{"id":"seven_day","percentRemaining":$seven}]}]}
JSON
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

TMP=$(fm_test_tmproot fm-quota-gate-spawn)
fm_git_identity fmtest fmtest@example.invalid
NORMAL_CWD=$(make_normal_repo "$TMP/normal-cwd")

# run_spawn <home> <id> <proj> <pane> <fakebin> <model> <kindflag> [env=val ...]
run_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5 model=$6 kindflag=$7; shift 7
  local extra=(codex)
  [ -z "$model" ] || extra+=(--model "$model")
  [ -z "$kindflag" ] || extra+=("$kindflag")
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  ( cd "$NORMAL_CWD" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
      "FM_ROOT_OVERRIDE=" "FM_HOME=$home" \
      "FM_STATE_OVERRIDE=$home/state" "FM_DATA_OVERRIDE=$home/data" \
      "FM_PROJECTS_OVERRIDE=$home/projects" "FM_CONFIG_OVERRIDE=$home/config" \
      "FM_SPAWN_NO_GUARD=1" "FM_FAKE_PANE_PATH=$pane" "TMUX=fake,1,0" \
      "PATH=$fakebin:$PATH" "$@" \
      "$SPAWN" "$id" "$proj" "${extra[@]}" ) 2>&1
}

test_ok_level_spawns_silently() {
  local home proj fakebin wt out rc
  home="$TMP/ok-home"; mkdir -p "$home/data"
  proj=$(make_normal_repo "$TMP/ok-proj")
  wt="$TMP/ok-wt"; git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_fakebin "$TMP/ok-fake" 88 97)
  out=$(run_spawn "$home" spawn-ok "$proj" "$wt" "$fakebin" "" ""); rc=$?
  expect_code 0 "$rc" "ok level: spawn must succeed"
  assert_contains "$out" "spawned spawn-ok" "ok level: normal launch should report success"
  assert_not_contains "$out" "QUOTA" "ok level: no quota banner at healthy remaining"
  assert_present "$home/state/spawn-ok.meta" "ok level: meta must be written"
  pass "fm-spawn: an ok-level quota gate spawns a crewmate silently"
}

test_pause_level_refuses_crewmate_spawn() {
  local home proj fakebin wt out rc
  home="$TMP/pause-home"; mkdir -p "$home/data"
  proj=$(make_normal_repo "$TMP/pause-proj")
  wt="$TMP/pause-wt"; git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_fakebin "$TMP/pause-fake" 12 90)
  out=$(run_spawn "$home" spawn-pause "$proj" "$wt" "$fakebin" "" ""); rc=$?
  expect_code 1 "$rc" "pause level: spawn must be refused"
  assert_contains "$out" "QUOTA PAUSE - SPAWN REFUSED" "pause level: bordered refusal banner"
  assert_contains "$out" "FM_QUOTA_OVERRIDE=1" "pause level: refusal must name the override"
  assert_absent "$home/state/spawn-pause.meta" "pause level: refused spawn must not record meta"
  pass "fm-spawn: a pause-level quota gate refuses a crewmate spawn"
}

test_pause_level_override_admits_spawn() {
  local home proj fakebin wt out rc
  home="$TMP/pause-override-home"; mkdir -p "$home/data"
  proj=$(make_normal_repo "$TMP/pause-override-proj")
  wt="$TMP/pause-override-wt"; git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_fakebin "$TMP/pause-override-fake" 12 90)
  out=$(run_spawn "$home" spawn-pause-ov "$proj" "$wt" "$fakebin" "" "" FM_QUOTA_OVERRIDE=1); rc=$?
  expect_code 0 "$rc" "pause level + override: spawn must succeed"
  assert_present "$home/state/spawn-pause-ov.meta" "pause level + override: meta must be written"
  pass "fm-spawn: FM_QUOTA_OVERRIDE=1 admits a spawn at the pause level"
}

test_sonnet_only_refuses_opus_model() {
  local home proj fakebin wt out rc
  home="$TMP/sonnetonly-opus-home"; mkdir -p "$home/data"
  proj=$(make_normal_repo "$TMP/sonnetonly-opus-proj")
  wt="$TMP/sonnetonly-opus-wt"; git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_fakebin "$TMP/sonnetonly-opus-fake" 35 90)
  out=$(run_spawn "$home" spawn-sonly-opus "$proj" "$wt" "$fakebin" "claude-opus-4" ""); rc=$?
  expect_code 1 "$rc" "sonnet-only + opus: spawn must be refused"
  assert_contains "$out" "QUOTA SONNET-ONLY - SPAWN REFUSED" "sonnet-only + opus: bordered refusal banner"
  assert_absent "$home/state/spawn-sonly-opus.meta" "sonnet-only + opus: refused spawn must not record meta"
  pass "fm-spawn: a sonnet-only quota gate refuses an opus model request"
}

test_sonnet_only_refuses_fable_case_insensitively() {
  local home proj fakebin wt out rc
  home="$TMP/sonnetonly-fable-home"; mkdir -p "$home/data"
  proj=$(make_normal_repo "$TMP/sonnetonly-fable-proj")
  wt="$TMP/sonnetonly-fable-wt"; git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_fakebin "$TMP/sonnetonly-fable-fake" 35 90)
  out=$(run_spawn "$home" spawn-sonly-fable "$proj" "$wt" "$fakebin" "FABLE" ""); rc=$?
  expect_code 1 "$rc" "sonnet-only + FABLE (uppercase): spawn must be refused"
  assert_contains "$out" "QUOTA SONNET-ONLY - SPAWN REFUSED" "sonnet-only + FABLE: bordered refusal banner"
  pass "fm-spawn: sonnet-only's opus/fable match is case-insensitive"
}

test_sonnet_only_admits_sonnet_model() {
  local home proj fakebin wt out rc
  home="$TMP/sonnetonly-sonnet-home"; mkdir -p "$home/data"
  proj=$(make_normal_repo "$TMP/sonnetonly-sonnet-proj")
  wt="$TMP/sonnetonly-sonnet-wt"; git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_fakebin "$TMP/sonnetonly-sonnet-fake" 35 90)
  out=$(run_spawn "$home" spawn-sonly-ok "$proj" "$wt" "$fakebin" "claude-sonnet-5" ""); rc=$?
  expect_code 0 "$rc" "sonnet-only + sonnet model: spawn must succeed"
  assert_present "$home/state/spawn-sonly-ok.meta" "sonnet-only + sonnet model: meta must be written"
  pass "fm-spawn: a sonnet-only quota gate admits a sonnet model request"
}

test_sonnet_only_override_admits_opus() {
  local home proj fakebin wt out rc
  home="$TMP/sonnetonly-override-home"; mkdir -p "$home/data"
  proj=$(make_normal_repo "$TMP/sonnetonly-override-proj")
  wt="$TMP/sonnetonly-override-wt"; git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_fakebin "$TMP/sonnetonly-override-fake" 35 90)
  out=$(run_spawn "$home" spawn-sonly-ov "$proj" "$wt" "$fakebin" "opus" "" FM_QUOTA_OVERRIDE=1); rc=$?
  expect_code 0 "$rc" "sonnet-only + opus + override: spawn must succeed"
  assert_present "$home/state/spawn-sonly-ov.meta" "sonnet-only + opus + override: meta must be written"
  pass "fm-spawn: FM_QUOTA_OVERRIDE=1 admits an opus request at the sonnet-only level"
}

test_secondmate_spawns_never_invoke_the_quota_gate() {
  local fakedir fakebin marker out
  fakedir=$(fm_test_tmproot quota-secondmate)
  fakebin=$(fm_fakebin "$fakedir")
  marker="$fakedir/quota-axi-called"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
touch "$marker"
echo '{"providers":[{"provider":"claude","windows":[{"id":"five_hour","percentRemaining":5},{"id":"seven_day","percentRemaining":5}]}]}'
SH
  chmod +x "$fakebin/quota-axi"
  fm_fake_exit0 "$fakebin" tmux treehouse
  out=$(cd "$NORMAL_CWD" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
    "FM_ROOT_OVERRIDE=" "FM_HOME=$fakedir/home" "FM_STATE_OVERRIDE=$fakedir/home/state" \
    "FM_DATA_OVERRIDE=$fakedir/home/data" "FM_PROJECTS_OVERRIDE=$fakedir/home/projects" \
    "FM_CONFIG_OVERRIDE=$fakedir/home/config" "FM_SPAWN_NO_GUARD=1" "TMUX=fake,1,0" \
    "PATH=$fakebin:$PATH" \
    "$SPAWN" secondmate-quota-x1 "$fakedir/secondmate-home" --secondmate codex 2>&1)
  # The secondmate spawn may still fail later on unrelated provisioning this
  # fixture does not stub - the only thing under test is that it never reaches
  # the quota gate on its way there.
  [ ! -e "$marker" ] || fail "a secondmate spawn must never invoke quota-axi: $out"
  pass "fm-spawn: a secondmate spawn is exempt from the quota gate (quota-axi is never invoked)"
}

test_ok_above_both_thresholds
test_takes_minimum_of_the_two_general_windows
test_floors_fractional_percent_remaining
test_model_scoped_window_is_ignored
test_sonnet_only_band
test_pause_band
test_thresholds_are_env_overridable
test_fail_open_missing_quota_axi
test_fail_open_quota_axi_errors
test_fail_open_unparseable_output
test_fail_open_missing_windows
test_fail_open_bad_threshold_env
test_ok_level_spawns_silently
test_pause_level_refuses_crewmate_spawn
test_pause_level_override_admits_spawn
test_sonnet_only_refuses_opus_model
test_sonnet_only_refuses_fable_case_insensitively
test_sonnet_only_admits_sonnet_model
test_sonnet_only_override_admits_opus
test_secondmate_spawns_never_invoke_the_quota_gate

echo "# fm-quota-gate.test.sh: all assertions passed"
