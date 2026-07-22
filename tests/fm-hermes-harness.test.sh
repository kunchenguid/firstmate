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

# A real YAML loader proves the generated config still parses; the leak
# assertions themselves run everywhere.
YAML_LOADER=none
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  YAML_LOADER=python3
elif command -v ruby >/dev/null 2>&1 && ruby -ryaml -e '' >/dev/null 2>&1; then
  YAML_LOADER=ruby
fi

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
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u HERMES_INTERACTIVE -u HERMES_SESSION_ID \
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
  local source="$TMP_ROOT/source" target="$TMP_ROOT/task home" turnend="$TMP_ROOT/task.turn-ended"
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
  assert_grep "command: '''$target/fm-on-session-end.sh'''" "$target/config.yaml" \
    "task hook command must survive a Hermes home containing spaces"
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
  assert_contains "$config" "fm-arm-pretool-check.sh'' --hermes" "Hermes pre-tool hook misses native output shaping"
  assert_contains "$config" "fm-cd-pretool-check.sh'' --hermes" "Hermes primary home lacks cd-guard parity with every other harness"
  pass "Hermes isolated primary home wires session start, turn end, and pre-tool safety"
}

test_primary_hook_commands_support_spaces() {
  local source="$TMP_ROOT/spaced-source" target="$TMP_ROOT/spaced-home" root="$TMP_ROOT/first mate" script
  mkdir -p "$source" "$root/bin"
  printf 'model:\n  provider: openai-codex\n' > "$source/config.yaml"
  for script in fm-sessionstart-nudge.sh fm-turnend-guard-hermes.sh fm-arm-pretool-check.sh fm-cd-pretool-check.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/$script"
    chmod +x "$root/bin/$script"
  done

  HERMES_SOURCE_HOME="$source" "$HOME_HELPER" primary "$target" "$root" >/dev/null
  assert_grep "command: '''$root/bin/fm-sessionstart-nudge.sh'''" "$target/config.yaml" \
    "session-start hook path is not shell-quoted"
  assert_grep "command: '''$root/bin/fm-turnend-guard-hermes.sh'''" "$target/config.yaml" \
    "turn-end hook path is not shell-quoted"
  assert_grep "command: '''$root/bin/fm-arm-pretool-check.sh'' --hermes'" "$target/config.yaml" \
    "watcher-arm hook path is not shell-quoted"
  assert_grep "command: '''$root/bin/fm-cd-pretool-check.sh'' --hermes'" "$target/config.yaml" \
    "cd-guard hook path is not shell-quoted"
  pass "Hermes primary hook commands shell-quote roots containing spaces"
}

test_primary_home_requires_every_safety_script() {
  local source="$TMP_ROOT/required-source" missing root target script out rc
  mkdir -p "$source"
  printf 'model:\n  provider: openai-codex\n' > "$source/config.yaml"
  for missing in fm-sessionstart-nudge.sh fm-turnend-guard-hermes.sh fm-arm-pretool-check.sh fm-cd-pretool-check.sh; do
    root="$TMP_ROOT/missing-$missing"
    target="$TMP_ROOT/missing-$missing-home"
    mkdir -p "$root/bin"
    for script in fm-sessionstart-nudge.sh fm-turnend-guard-hermes.sh fm-arm-pretool-check.sh fm-cd-pretool-check.sh; do
      printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/$script"
      chmod +x "$root/bin/$script"
    done
    rm "$root/bin/$missing"
    out=$(HERMES_SOURCE_HOME="$source" "$HOME_HELPER" primary "$target" "$root" 2>&1)
    rc=$?
    expect_code 1 "$rc" "Hermes primary home missing $missing"
    assert_contains "$out" "$missing" "missing-script error did not identify $missing"
    assert_absent "$target/config.yaml" "Hermes published hooks before validating $missing"
  done
  pass "Hermes primary home requires every safety hook script"
}

test_usage_states_the_isolation_guarantee() {
  local out
  out=$("$HOME_HELPER" --help)
  assert_contains "$out" "The source Hermes home is never changed." "usage truncated the isolation guarantee"
  pass "Hermes home usage renders its complete header"
}

# The operator's hooks block must never leak into the Firstmate-owned config,
# and what survives must stay loadable YAML. Each fixture ends the hooks block
# with a column-0 shape that a line-oriented stripper can mistake for the end of
# that block: a comment, a document marker, and a quoted key.
test_preserved_config_never_leaks_operator_hooks() {
  local case_dir source target n=0 fixture
  for fixture in comment marker quoted; do
    n=$((n + 1))
    case_dir="$TMP_ROOT/leak-$fixture"
    source="$case_dir/source"
    target="$case_dir/home"
    mkdir -p "$source"
    case "$fixture" in
      comment)
        cat > "$source/config.yaml" <<'YAML'
hooks:
# operator's own note pinned at column 0
  on_session_end:
    - command: '/captain/leak.sh'
      timeout: 10
model:
  default: gpt-5.6-sol
YAML
        ;;
      marker)
        cat > "$source/config.yaml" <<'YAML'
model:
  default: gpt-5.6-sol
hooks:
---
  on_session_start:
    - command: '/captain/leak.sh'
YAML
        ;;
      quoted)
        cat > "$source/config.yaml" <<'YAML'
model:
  default: gpt-5.6-sol
"hooks":
  on_session_start:
    - command: '/captain/leak.sh'
hooks_auto_accept: false
YAML
        ;;
    esac
    HERMES_SOURCE_HOME="$source" "$HOME_HELPER" primary "$target" "$ROOT" >/dev/null
    assert_no_grep '/captain/leak.sh' "$target/config.yaml" \
      "operator hook leaked through the $fixture fixture into the isolated config"
    assert_grep 'fm-turnend-guard-hermes.sh' "$target/config.yaml" \
      "$fixture fixture lost Firstmate's own turn-end hook"
    if [ "$YAML_LOADER" = python3 ]; then
      python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$target/config.yaml" \
        || fail "$fixture fixture produced a config Hermes cannot parse"
    elif [ "$YAML_LOADER" = ruby ]; then
      ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]))' "$target/config.yaml" \
        || fail "$fixture fixture produced a config Hermes cannot parse"
    fi
  done
  pass "preserved config strips whole hook blocks across $n column-0 boundary shapes"
}

test_home_and_config_are_private_from_creation() {
  local source="$TMP_ROOT/perm-source" target="$TMP_ROOT/perm-home"
  mkdir -p "$source"
  printf 'model:\n  provider: openai-codex\n' > "$source/config.yaml"
  HERMES_SOURCE_HOME="$source" "$HOME_HELPER" primary "$target" "$ROOT" >/dev/null
  [ "$(file_mode "$target")" = 700 ] || fail "isolated Hermes home must be mode 0700, got $(file_mode "$target")"
  [ "$(file_mode "$target/config.yaml")" = 600 ] || fail "isolated Hermes config must be mode 0600"
  pass "isolated Hermes home and config are private"
}

test_busy_and_idle_classification() {
  local state
  printf '%s' '⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel' \
    | grep -qE "$FM_TMUX_BUSY_REGEX_DEFAULT" || fail "Hermes busy footer did not match the fleet busy regex"
  state=$(fm_composer_classify_content 0 '❯')
  [ "$state" = empty ] || fail "Hermes bare idle prompt should classify empty, got '$state'"
  pass "Hermes busy footer and bare idle composer classify correctly"
}

test_passive_guard_forces_one_safe_followup() {
  local primary="$TMP_ROOT/primary" source_home="$TMP_ROOT/current-hermes-home" fakebin followup_home log payload out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/fake")
  log="$TMP_ROOT/hermes-resume.log"
  mkdir -p "$primary/bin" "$primary/state" "$primary/config" "$source_home"
  printf 'model:\n  provider: openai-codex\n' > "$source_home/config.yaml"
  : > "$primary/AGENTS.md"
  git init -q "$primary"
  git -C "$primary" commit -q --allow-empty -m init
  printf '%s\n' 'window=fake' > "$primary/state/inflight.meta"
  cat > "$fakebin/hermes" <<'SH'
#!/usr/bin/env bash
printf 'home=%s active=%s args=%s\n' "${HERMES_HOME:-}" "${HERMES_TURNEND_GUARD_ACTIVE:-}" "$*" >> "$FM_HERMES_TEST_LOG"
exit 0
SH
  chmod +x "$fakebin/hermes"
  payload='{"session_id":"20260721_214600_e8ae23","extra":{"completed":true,"interrupted":false}}'
  out=$(printf '%s' "$payload" | FM_ROOT_OVERRIDE="$primary" FM_HOME="$primary" HERMES_HOME="$source_home" \
    FM_HERMES_TEST_LOG="$log" PATH="$fakebin:$PATH" "$GUARD" 2>&1)
  rc=$?
  expect_code 0 "$rc" "Hermes passive guard adapter"
  [ -z "$out" ] || fail "Hermes passive guard adapter must be silent, got: $out"
  assert_grep 'active=1 args=--yolo --accept-hooks -z TURN WOULD END BLIND' "$log" \
    "Hermes guard did not force a loop-guarded independent follow-up"
  assert_no_grep --resume "$log" "Hermes guard must not resume a session that is still live"
  assert_no_grep "home=$source_home " "$log" "Hermes guard must not share the live session store"
  followup_home=$(sed -n 's/^home=\([^ ]*\) active=.*/\1/p' "$log")
  [ -n "$followup_home" ] || fail "Hermes guard did not select an isolated follow-up home"
  assert_absent "$followup_home" "Hermes guard left its isolated follow-up home behind"

  : > "$log"
  payload='{"session_id":"20260721_214600_e8ae23","completed":false,"interrupted":true}'
  printf '%s' "$payload" | FM_ROOT_OVERRIDE="$primary" FM_HOME="$primary" HERMES_HOME="$source_home" \
    FM_HERMES_TEST_LOG="$log" PATH="$fakebin:$PATH" "$GUARD" >/dev/null 2>&1
  [ ! -s "$log" ] || fail "Hermes turn-end guard must respect an operator interrupt"
  pass "Hermes passive turn-end guard starts a safe follow-up but respects interrupts"
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
test_primary_hook_commands_support_spaces
test_primary_home_requires_every_safety_script
test_usage_states_the_isolation_guarantee
test_preserved_config_never_leaks_operator_hooks
test_home_and_config_are_private_from_creation
test_busy_and_idle_classification
test_passive_guard_forces_one_safe_followup
test_fm_lock_recognizes_hermes_holder
