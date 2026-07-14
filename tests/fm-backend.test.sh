#!/usr/bin/env bash
# Backend selection, metadata, and generic dispatch regression coverage.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-tests)
CONFIG="$TMP_ROOT/config"
STATE="$TMP_ROOT/state"
mkdir -p "$CONFIG" "$STATE"

FM_CONFIG_OVERRIDE="$CONFIG"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

test_default_backend_is_herdr() {
  local out
  out=$(unset FM_BACKEND HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier; PATH="/usr/bin:/bin" fm_backend_name)
  [ "$out" = herdr ] || fail "unconfigured backend should resolve to herdr, got '$out'"
  pass "fm_backend_name: Herdr is the unconfigured default"
}

test_explicit_precedence() {
  local out
  printf 'zellij\n' > "$CONFIG/backend"
  out=$(FM_BACKEND=orca fm_backend_name)
  [ "$out" = orca ] || fail "FM_BACKEND should outrank config/backend, got '$out'"
  out=$(unset FM_BACKEND; fm_backend_name)
  [ "$out" = zellij ] || fail "config/backend should outrank runtime detection, got '$out'"
  rm -f "$CONFIG/backend"
  pass "fm_backend_name: explicit environment and config precedence is preserved"
}

test_runtime_detection() {
  local out
  out=$(unset CMUX_WORKSPACE_ID; HERDR_ENV=1 fm_backend_detect) || fail "HERDR_ENV should be detected"
  [ "$out" = herdr ] || fail "HERDR_ENV should resolve Herdr, got '$out'"
  out=$(unset HERDR_ENV; CMUX_WORKSPACE_ID=workspace-1 fm_backend_detect) || fail "cmux marker should be detected"
  [ "$out" = cmux ] || fail "cmux marker should resolve cmux, got '$out'"
  out=$(HERDR_ENV=1 CMUX_WORKSPACE_ID=workspace-1 fm_backend_detect) || fail "nested markers should be detected"
  [ "$out" = herdr ] || fail "Herdr should win as the inner provider, got '$out'"
  pass "fm_backend_detect: Herdr and cmux runtime markers preserve inner-provider precedence"
}

test_cmux_bundle_fallback_detection() {
  local fakebin="$TMP_ROOT/cmux-detect-bin" out
  mkdir -p "$fakebin"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$fakebin/lsappinfo" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/uname" "$fakebin/ps" "$fakebin/lsappinfo"
  out=$(unset HERDR_ENV CMUX_WORKSPACE_ID; PATH="$fakebin:$PATH" __CFBundleIdentifier=com.cmuxterm.app fm_backend_detect) \
    || fail "the documented cmux bundle fallback should be detected"
  [ "$out" = cmux ] || fail "the cmux bundle fallback resolved '$out'"
  if out=$(unset HERDR_ENV CMUX_WORKSPACE_ID; PATH="$fakebin:$PATH" __CFBundleIdentifier=com.apple.Terminal fm_backend_detect); then
    fail "a foreign bundle identifier must not select cmux, got '$out'"
  fi
  pass "fm_backend_detect: the macOS cmux bundle fallback remains supported and rejects foreign terminals"
}

test_known_and_spawn_sets() {
  local backend
  for backend in herdr zellij orca cmux; do
    fm_backend_validate "$backend" || fail "$backend should be known"
    fm_backend_validate_spawn "$backend" || fail "$backend should remain spawn-capable"
  done
  if fm_backend_validate legacy-provider >/dev/null 2>&1; then
    fail "an unknown provider must be rejected"
  fi
  pass "backend validation: Herdr, zellij, Orca, and cmux remain supported"
}

test_validation_refuses_unknown_and_blocked_backends() {
  local out
  out=$(fm_backend_validate bogus 2>&1) && fail "an unknown backend should be rejected"
  assert_contains "$out" "unknown backend 'bogus'" "unknown-backend validation lost its diagnostic"
  out=$(fm_backend_validate codex-app 2>&1) && fail "the blocked Codex App backend should be rejected"
  assert_contains "$out" "unknown backend 'codex-app'" "Codex App refusal lost its diagnostic"
  out=$(fm_backend_validate 'herdr zellij' 2>&1) && fail "a multi-token backend should be rejected"
  assert_contains "$out" "unknown backend 'herdr zellij'" "multi-token backend validation lost its diagnostic"
  pass "backend validation: unknown, blocked, and multi-token names fail loudly"
}

test_backend_source_is_shell_portable() {
  local out
  bash -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source herdr && declare -F fm_backend_herdr_capture >/dev/null" \
    || fail "bash could not source the Herdr adapter"
  if command -v zsh >/dev/null 2>&1; then
    zsh -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source herdr && whence -w fm_backend_herdr_capture >/dev/null" \
      || fail "zsh could not source the Herdr adapter"
  fi
  out=$(bash -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source bogus" 2>&1) \
    && fail "bash accepted an unknown adapter"
  assert_contains "$out" "unknown backend 'bogus'" "shell-portable source refusal lost its diagnostic"
  pass "fm_backend_source: known adapters load and unknown adapters fail in supported shells"
}

test_required_tools() {
  [ "$(fm_backend_required_tools herdr)" = "herdr jq treehouse" ] || fail "Herdr dependency set changed"
  [ "$(fm_backend_required_tools zellij)" = "zellij jq treehouse" ] || fail "zellij dependency set changed"
  [ "$(fm_backend_required_tools orca)" = "orca" ] || fail "Orca dependency set changed"
  [ "$(fm_backend_required_tools cmux)" = "cmux jq treehouse" ] || fail "cmux dependency set changed"
  pass "fm_backend_required_tools: active provider dependencies are exact"
}

test_absent_metadata_defaults_safely() {
  local meta="$STATE/legacy.meta"
  printf 'window=lab:w1:p2\n' > "$meta"
  [ "$(fm_backend_of_meta "$meta")" = herdr ] || fail "absent backend metadata should resolve Herdr"
  [ "$(fm_backend_target_of_meta "$meta")" = "lab:w1:p2" ] || fail "legacy target should remain readable"
  [ "$(fm_backend_of_selector legacy "lab:w1:p2" "$STATE")" = herdr ] || fail "selector fallback should resolve Herdr"
  pass "metadata: absent backend resolves safely under the Herdr default"
}

test_removed_runtime_metadata_fails_closed() {
  local meta="$STATE/removed-runtime.meta" out rc
  printf 'window=firstmate:fm-upgrade-case\n' > "$meta"
  [ "$(fm_backend_of_meta "$meta")" = "$FM_BACKEND_LEGACY_REMOVED" ] \
    || fail "removed-runtime target shape was reinterpreted as a current backend"
  out=$(fm_backend_capture "$(fm_backend_of_meta "$meta")" firstmate:fm-upgrade-case 1 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "removed-runtime state reached a live backend adapter"
  assert_contains "$out" "legacy removed runtime" "removed-runtime refusal lost its actionable diagnostic"
  assert_contains "$out" "do not reinterpret it as Herdr" "removed-runtime refusal did not guard the upgrade hazard"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-peek.sh" removed-runtime 1 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "fm-peek accepted removed-runtime state"
  assert_contains "$out" "legacy removed runtime" "fm-peek lost the removed-runtime diagnostic"
  pass "metadata: removed-runtime records fail closed instead of routing to Herdr"
}

test_selector_resolution_refuses_guesses() {
  local out status
  printf 'window=lab:w1:p2\n' > "$STATE/task-a.meta"
  [ "$(fm_backend_resolve_selector task-a "$STATE")" = "lab:w1:p2" ] || fail "task id should resolve through metadata"
  out=$(fm_backend_resolve_selector unrecorded "$STATE" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unrecorded bare selector should be rejected"
  assert_contains "$out" "not recorded" "bare-selector refusal should explain the safe path"
  pass "selector resolution: recorded targets work and unresolved guesses fail closed"
}

test_default_spawn_omits_backend_metadata() {
  local proj="$TMP_ROOT/spawn-project" wt="$TMP_ROOT/spawn-worktree" data="$TMP_ROOT/spawn-data"
  local state="$TMP_ROOT/spawn-state" config="$TMP_ROOT/spawn-config" fakebin="$TMP_ROOT/spawn-bin"
  local id=default-herdr-spawn out
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config" "$fakebin"
  printf 'brief\n' > "$data/$id/brief.md"
  fm_test_write_basic_herdr "$fakebin/herdr"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_HERDR_CWD="$wt" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --harness 'bash --noprofile --norc' 2>&1)
  expect_code 0 $? "default Herdr spawn should succeed with the deterministic adapter fixture"$'\n'"$out"
  assert_no_grep 'backend=' "$state/$id.meta" "the default Herdr spawn must omit backend="
  [ "$(fm_backend_of_meta "$state/$id.meta")" = herdr ] || fail "the omitted backend metadata did not resolve Herdr"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh: the default Herdr path omits backend= and readers resolve it safely"
}

test_default_backend_is_herdr
test_explicit_precedence
test_runtime_detection
test_cmux_bundle_fallback_detection
test_known_and_spawn_sets
test_validation_refuses_unknown_and_blocked_backends
test_backend_source_is_shell_portable
test_required_tools
test_absent_metadata_defaults_safely
test_removed_runtime_metadata_fails_closed
test_selector_resolution_refuses_guesses
test_default_spawn_omits_backend_metadata

echo "All backend tests passed."
