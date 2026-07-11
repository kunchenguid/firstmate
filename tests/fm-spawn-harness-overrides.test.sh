#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh per-harness launch overrides
# (config/harness-overrides.json).
#
# Like fm-spawn-dispatch-profile.test.sh, these drive fm-spawn through launch
# construction with a fake tmux pane and a real isolated git worktree. The fake
# tmux captures the literal launch command sent with `tmux send-keys -l`, so
# assertions pin the exact command firstmate would run without starting any real
# harness. The central guarantee is that, with NO override file, the launch
# command is byte-identical to the historical one; overrides only touch the
# command/args/env axes and never the firstmate-owned tail or harness identity.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-harness-overrides)

make_spawn_fakebin() {
  local dir=$1 fakebin
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
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

write_overrides() {
  local home=$1 json=$2
  printf '%s\n' "$json" > "$home/config/harness-overrides.json"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  # CASE_DIR is captured for symmetry with the other spawn suites but unused here.
  # shellcheck disable=SC2034
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

# --- 1. absent file: byte-identical launch for claude and codex --------------

test_absent_file_claude_byte_identical() {
  local rec id out status launch expected
  id=ovr-absent-claude-a1
  rec=$(make_spawn_case ovr-absent-claude claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without an override file should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$(cat '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "absent-file claude launch changed"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "absent override file keeps the claude launch byte-identical"
}

test_absent_file_codex_byte_identical() {
  local rec id out status launch expected state_real sq_te sq_br
  id=ovr-absent-codex-a2
  rec=$(make_spawn_case ovr-absent-codex codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn without an override file should succeed"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report codex"
  launch=$(cat "$LAUNCH_LOG")
  state_real=$(cd "$HOME_DIR/state" && pwd -P)
  sq_te="'$state_real/$id.turn-ended'"
  sq_br="'$HOME_DIR/data/$id/brief.md'"
  # The $(cat ...) is deliberately literal here: it must appear verbatim in the
  # launch line to expand in the crewmate pane, not in this test.
  # shellcheck disable=SC2016
  expected='codex --dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch '"$sq_te"'\"]" "$(cat '"$sq_br"')"'
  [ "$launch" = "$expected" ] || fail "absent-file codex launch changed"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "absent override file keeps the codex launch byte-identical"
}

# --- 2. command override: binary changes, tail + identity unchanged ----------

test_command_override_changes_binary_only() {
  local rec id out status launch expected
  id=ovr-command-a3
  rec=$(make_spawn_case ovr-command claude "$id")
  read_case_record "$rec"
  write_overrides "$HOME_DIR" '{"claude":{"command":"cc"}}'

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with a command override should succeed"
  # harness identity is preserved: meta records the base harness, not the binary.
  assert_contains "$out" "spawned $id harness=claude" "command override must not change the recorded harness"
  assert_grep "harness=claude" "$HOME_DIR/state/$id.meta" "meta harness must stay claude"
  # supervision wiring intact: the claude turn-end hook is still installed.
  assert_present "$WT_DIR/.claude/settings.local.json" "command override must not drop the turn-end hook"
  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false cc --dangerously-skip-permissions \"\$(cat '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "command override did not replace only the binary"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "command override swaps the binary while keeping args, tail, and harness identity"
}

# --- 3. env override: merges over built-in env and is prepended --------------

test_env_override_merges_and_prepends() {
  local rec id out status launch
  id=ovr-env-a4
  rec=$(make_spawn_case ovr-env claude "$id")
  read_case_record "$rec"
  write_overrides "$HOME_DIR" '{"claude":{"env":{"ANTHROPIC_BASE_URL":"https://ex","ANTHROPIC_AUTH_TOKEN":"sk-x"}}}'

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with an env override should succeed"
  launch=$(cat "$LAUNCH_LOG")
  # built-in env is preserved, override env is appended, all prepended before the binary.
  assert_contains "$launch" \
    "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false ANTHROPIC_BASE_URL='https://ex' ANTHROPIC_AUTH_TOKEN='sk-x' claude --dangerously-skip-permissions" \
    "env override did not merge over built-in env and prepend as KEY=value assignments"
  pass "env override merges over built-in env and is prepended to the launch"
}

test_env_override_wins_on_key_conflict() {
  local rec id out status launch
  id=ovr-env-conflict-a5
  rec=$(make_spawn_case ovr-env-conflict claude "$id")
  read_case_record "$rec"
  write_overrides "$HOME_DIR" '{"claude":{"env":{"CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION":"true"}}}'

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with a conflicting env key should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='true' claude" \
    "override env value must win on a key conflict"
  assert_not_contains "$launch" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false" \
    "built-in env value must be replaced, not duplicated, on a key conflict"
  pass "env override wins over the built-in value on a key conflict"
}

# --- 4. args override: replaces the default args -----------------------------

test_args_override_replaces_defaults() {
  local rec id out status launch
  id=ovr-args-a6
  rec=$(make_spawn_case ovr-args claude "$id")
  read_case_record "$rec"
  write_overrides "$HOME_DIR" '{"claude":{"args":["--foo","--bar baz"]}}'

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with an args override should succeed"
  launch=$(cat "$LAUNCH_LOG")
  # each array element is one literal, shell-quoted argument; the default arg is gone.
  assert_contains "$launch" "claude '--foo' '--bar baz' \"\$(cat " \
    "args override did not replace the default args with the shell-quoted override"
  assert_not_contains "$launch" "--dangerously-skip-permissions" \
    "args override must replace, not append to, the default args"
  pass "args override replaces the default launch args"
}

test_empty_args_override_drops_defaults() {
  local rec id out status launch
  id=ovr-args-empty-a7
  rec=$(make_spawn_case ovr-args-empty claude "$id")
  read_case_record "$rec"
  write_overrides "$HOME_DIR" '{"claude":{"args":[]}}'

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with an empty args override should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude \"\$(cat " \
    "an empty args array should launch with no default args"
  assert_not_contains "$launch" "--dangerously-skip-permissions" \
    "an empty args array must drop the default args"
  pass "an empty args override launches with no args"
}

# --- 5. malformed / jq-less: fall back to built-in defaults ------------------

test_malformed_file_falls_back_to_defaults() {
  local rec id out status launch expected
  id=ovr-malformed-a8
  rec=$(make_spawn_case ovr-malformed claude "$id")
  read_case_record "$rec"
  printf '%s\n' '{not json' > "$HOME_DIR/config/harness-overrides.json"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a malformed override file must not break the spawn"
  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$(cat '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "malformed override did not fall back to the built-in launch"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "a malformed override file falls back to the built-in launch"
}

# --- 6. inheritance: the file rides the same propagation helper --------------

test_harness_overrides_is_inheritable() {
  case " $FM_INHERITABLE_CONFIG " in
    *" harness-overrides.json "*) : ;;
    *) fail "harness-overrides.json is not in FM_INHERITABLE_CONFIG ($FM_INHERITABLE_CONFIG)" ;;
  esac
  pass "harness-overrides.json is a declared inheritable config item"
}

test_propagate_carries_harness_overrides() {
  local d src dest json
  d="$TMP_ROOT/inherit"
  src="$d/src"
  dest="$d/dest"
  mkdir -p "$src" "$dest"
  json='{"claude":{"command":"cc"}}'
  printf '%s\n' "$json" > "$src/harness-overrides.json"

  propagate_inheritable_config "$src" "$dest" || fail "propagate returned non-zero"
  [ "$(cat "$dest/harness-overrides.json")" = "$json" ] \
    || fail "harness-overrides.json was not propagated into the secondmate home config"
  # absence-mirror: clearing it upstream clears it downstream too.
  rm -f "$src/harness-overrides.json"
  propagate_inheritable_config "$src" "$dest" || fail "propagate returned non-zero on absence-mirror"
  [ ! -e "$dest/harness-overrides.json" ] \
    || fail "clearing the primary's harness-overrides.json did not clear it downstream"
  pass "propagate_inheritable_config carries harness-overrides.json and mirrors its absence"
}

test_absent_file_claude_byte_identical
test_absent_file_codex_byte_identical
test_command_override_changes_binary_only
test_env_override_merges_and_prepends
test_env_override_wins_on_key_conflict
test_args_override_replaces_defaults
test_empty_args_override_drops_defaults
test_malformed_file_falls_back_to_defaults
test_harness_overrides_is_inheritable
test_propagate_carries_harness_overrides

echo "# all fm-spawn-harness-overrides tests passed"
