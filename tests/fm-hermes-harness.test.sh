#!/usr/bin/env bash
# Behavior tests for the Hermes v0.19.0 harness adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-hermes-harness)
fm_git_identity fmtest fmtest@example.invalid
HOME_HELPER="$ROOT/bin/fm-hermes-home.sh"
GUARD="$ROOT/bin/fm-turnend-guard-hermes.sh"

file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

# Build a fake ps that reports one harness as the immediate parent and then
# stops the ancestry walk, so marker overlap is resolved against known ancestry.
fake_ancestry() {
  local dir=$1 comm=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/$comm'; exit 0 ;;
  *"ppid="*) printf '%s\n' '1'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

# The suite itself runs under a harness, so every case clears the ambient
# markers and sets only the ones under test.
harness_under() {
  local fakebin=$1; shift
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u HERMES_INTERACTIVE \
    PATH="$fakebin:$PATH" "$@" "$ROOT/bin/fm-harness.sh"
}

test_env_detection() {
  local out anc_hermes anc_claude anc_grok anc_none
  anc_hermes=$(fake_ancestry "$TMP_ROOT/anc-hermes" hermes)
  anc_claude=$(fake_ancestry "$TMP_ROOT/anc-claude" claude)
  anc_grok=$(fake_ancestry "$TMP_ROOT/anc-grok" grok)
  anc_none=$(fake_ancestry "$TMP_ROOT/anc-none" bash)

  out=$(harness_under "$anc_none" HERMES_INTERACTIVE=1)
  [ "$out" = hermes ] || fail "a lone HERMES_INTERACTIVE=1 marker must detect hermes, got '$out'"
  out=$(harness_under "$anc_none" CLAUDECODE=1)
  [ "$out" = claude ] || fail "a lone CLAUDECODE=1 marker must detect claude, got '$out'"

  # Overlapping markers are the nested case: ancestry, not marker order, decides.
  out=$(harness_under "$anc_hermes" CLAUDECODE=1 HERMES_INTERACTIVE=1)
  [ "$out" = hermes ] || fail "a hermes worker under a claude primary must detect hermes, got '$out'"

  out=$(harness_under "$anc_claude" CLAUDECODE=1 HERMES_INTERACTIVE=1)
  [ "$out" = claude ] || fail "a claude worker under a hermes primary must detect claude, got '$out'"

  out=$(harness_under "$anc_grok" GROK_AGENT=1 HERMES_INTERACTIVE=1)
  [ "$out" = grok ] || fail "a grok worker under a hermes primary must detect grok, got '$out'"

  # Inconclusive ancestry keeps a deterministic fixed order.
  out=$(harness_under "$anc_none" CLAUDECODE=1 HERMES_INTERACTIVE=1)
  [ "$out" = hermes ] || fail "unknown ancestry must fall back to the fixed order, got '$out'"
  pass "fm-harness resolves overlapping harness markers by ancestry in both directions"
}

test_task_home_isolated_and_resumable() {
  local source="$TMP_ROOT/source" target="$TMP_ROOT/task-home" turnend="$TMP_ROOT/task.turn-ended"
  mkdir -p "$source"
  printf '%s\n' 'opaque-auth' > "$source/auth.json"
  cat > "$source/config.yaml" <<'YAML'
model:
  default: gpt-5.6-sol
  provider: openai-codex
agent:
  reasoning_effort: medium
hooks:
  on_session_end:
    - command: '/captain/only.sh'
      timeout: 10
hooks_auto_accept: false
YAML
  HERMES_SOURCE_HOME="$source" "$HOME_HELPER" task "$target" "$turnend" >/dev/null
  assert_grep '/captain/only.sh' "$source/config.yaml" "Hermes source config was modified"
  assert_grep 'default: gpt-5.6-sol' "$target/config.yaml" "isolated task home dropped the operator model default"
  assert_grep 'provider: openai-codex' "$target/config.yaml" "isolated task home dropped the operator provider"
  assert_grep 'reasoning_effort: medium' "$target/config.yaml" "isolated task home dropped the operator agent settings"
  assert_grep 'hooks_auto_accept: true' "$target/config.yaml" "isolated task home must force hook auto-accept"
  assert_no_grep '/captain/only.sh' "$target/config.yaml" "isolated task home inherited the operator's own hooks"
  [ "$(cat "$target/auth.json")" = opaque-auth ] || fail "Hermes auth was not copied opaquely"
  [ "$(file_mode "$target/auth.json")" = 600 ] || fail "copied Hermes auth must be mode 0600"
  [ "$(file_mode "$target/config.yaml")" = 600 ] || fail "isolated Hermes config must be mode 0600"
  assert_grep 'on_session_end:' "$target/config.yaml" "task home lacks on_session_end"
  "$target/fm-on-session-end.sh"
  assert_present "$turnend" "task on_session_end hook did not touch its marker"

  printf '%s\n' 'session-survives' > "$target/session.db"
  HERMES_SOURCE_HOME="$source" "$HOME_HELPER" task "$target" "$turnend" >/dev/null
  [ "$(cat "$target/session.db")" = session-survives ] || fail "Hermes home regeneration destroyed resume state"
  pass "Hermes task home preserves source config and isolated resume state"
}

test_primary_home_has_all_hooks() {
  local source="$TMP_ROOT/primary-source" target="$TMP_ROOT/primary-home" config
  mkdir -p "$source"
  printf 'model:\n  default: gpt-5.6-sol\n  provider: openai-codex\n' > "$source/config.yaml"
  HERMES_SOURCE_HOME="$source" "$HOME_HELPER" primary "$target" "$ROOT" >/dev/null
  config=$(cat "$target/config.yaml")
  assert_contains "$config" 'default: gpt-5.6-sol' "Hermes primary home dropped the operator model default"
  assert_contains "$config" 'provider: openai-codex' "Hermes primary home dropped the operator provider"
  assert_contains "$config" 'on_session_start:' "Hermes primary home lacks session-start enforcement"
  assert_contains "$config" 'fm-sessionstart-nudge.sh' "Hermes primary session-start hook misses the shared wrapper"
  assert_contains "$config" 'on_session_end:' "Hermes primary home lacks turn-end protection"
  assert_contains "$config" 'fm-turnend-guard-hermes.sh' "Hermes primary turn-end hook misses its adapter"
  assert_contains "$config" 'pre_tool_call:' "Hermes primary home lacks watcher-arm safety protection"
  assert_contains "$config" 'matcher: terminal' "Hermes pre-tool hook is not terminal-scoped"
  assert_contains "$config" 'fm-arm-pretool-check.sh --hermes' "Hermes pre-tool hook misses native output shaping"
  assert_contains "$config" 'fm-cd-pretool-check.sh --hermes' "Hermes primary home lacks cd-guard parity with every other harness"
  pass "Hermes isolated primary home wires session start, turn end, and pre-tool safety"
}

test_usage_states_the_isolation_guarantee() {
  local out
  out=$("$HOME_HELPER" --help)
  assert_contains "$out" "The source Hermes home is never changed." "usage truncated the isolation guarantee"
  pass "Hermes home usage renders its complete header"
}

test_cd_guard_renders_hermes_block_shape() {
  local out rc
  out=$("$ROOT/bin/fm-cd-pretool-check.sh" --hermes --command 'cd projects/foo' 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 2 ]; then
    assert_contains "$out" '"action":"block"' "Hermes cd-guard deny must use the native action object"
  else
    [ -z "$out" ] || fail "Hermes cd-guard allow must leave stdout empty, got: $out"
  fi
  pass "cd-guard speaks the Hermes native block shape"
}

test_busy_and_idle_classification() {
  local state
  printf '%s' '⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel' \
    | grep -qE "$FM_TMUX_BUSY_REGEX_DEFAULT" || fail "Hermes busy footer did not match the fleet busy regex"
  state=$(fm_composer_classify_content 0 '❯')
  [ "$state" = empty ] || fail "Hermes bare idle prompt should classify empty, got '$state'"
  pass "Hermes busy footer and bare idle composer classify correctly"
}

test_passive_guard_forces_one_resume() {
  local primary="$TMP_ROOT/primary" fakebin log payload out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/fake")
  log="$TMP_ROOT/hermes-resume.log"
  mkdir -p "$primary/bin" "$primary/state" "$primary/config"
  : > "$primary/AGENTS.md"
  git init -q "$primary"
  git -C "$primary" commit -q --allow-empty -m init
  printf '%s\n' 'window=fake' > "$primary/state/inflight.meta"
  cat > "$fakebin/hermes" <<'SH'
#!/usr/bin/env bash
printf 'active=%s args=%s\n' "${HERMES_TURNEND_GUARD_ACTIVE:-}" "$*" >> "$FM_HERMES_TEST_LOG"
exit 0
SH
  chmod +x "$fakebin/hermes"
  payload='{"session_id":"20260721_214600_e8ae23","extra":{"completed":true,"interrupted":false}}'
  out=$(printf '%s' "$payload" | FM_ROOT_OVERRIDE="$primary" FM_HOME="$primary" \
    FM_HERMES_TEST_LOG="$log" PATH="$fakebin:$PATH" "$GUARD" 2>&1)
  rc=$?
  expect_code 0 "$rc" "Hermes passive guard adapter"
  [ -z "$out" ] || fail "Hermes passive guard adapter must be silent, got: $out"
  assert_grep 'active=1 args=--resume 20260721_214600_e8ae23 --yolo --accept-hooks -z TURN WOULD END BLIND' "$log" \
    "Hermes guard did not force a loop-guarded same-session resume"
  pass "Hermes passive turn-end guard forces one bounded resumed follow-up"
}

test_fm_lock_recognizes_hermes_holder() {
  local home="$TMP_ROOT/lock-home" fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/home/user/.local/bin/hermes'; exit 0 ;;
  *"args="*) printf '%s\n' 'hermes chat --yolo --accept-hooks --cli'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize Hermes as a live holder"
  pass "fm-lock recognizes Hermes harness processes"
}

test_env_detection
test_task_home_isolated_and_resumable
test_primary_home_has_all_hooks
test_usage_states_the_isolation_guarantee
test_cd_guard_renders_hermes_block_shape
test_busy_and_idle_classification
test_passive_guard_forces_one_resume
test_fm_lock_recognizes_hermes_holder
