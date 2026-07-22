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

# --- 7. named launch variants -------------------------------------------------
#
# A variant is a DELTA over the harness-level entry, selected only by an explicit
# human choice (--launch, then default_variant). These tests pin the four
# invariants the design must hold: a variant never changes harness identity, an
# undeclared variant name is a hard refusal rather than a silent fallback to the
# base account, a variant's env stays out of state/<id>.meta, and a home whose
# file declares no variant launches byte-identically to before variants existed.

# The gateway launcher path stands in for the captain's real /Users/.../claude-gw.
# Its credentials live in that launcher, never in the override file, so these
# variants carry only a command path - the same shape the real config must use.
GW_BIN=/opt/fake/claude-gw
VARIANT_JSON="{\"claude\":{\"command\":\"cc\",\"variants\":{\"gateway\":{\"command\":\"$GW_BIN\"}}}}"

test_launch_variant_selects_variant_command() {
  local rec id out status launch expected
  id=ovr-variant-a9
  rec=$(make_spawn_case ovr-variant claude "$id")
  read_case_record "$rec"
  write_overrides "$HOME_DIR" "$VARIANT_JSON"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --launch gateway)
  status=$?
  expect_code 0 "$status" "spawn with a declared launch variant should succeed"
  assert_contains "$out" "spawned $id harness=claude launch=gateway" \
    "spawn line should report the base harness plus the selected variant"
  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false $GW_BIN --dangerously-skip-permissions \"\$(cat '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "variant command did not replace the binary"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "--launch selects the variant's command over the harness-level one"
}

test_launch_variant_keeps_harness_identity() {
  local rec id out status
  id=ovr-variant-identity-b1
  rec=$(make_spawn_case ovr-variant-identity claude "$id")
  read_case_record "$rec"
  write_overrides "$HOME_DIR" "$VARIANT_JSON"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --launch gateway)
  status=$?
  expect_code 0 "$status" "variant spawn should succeed"
  # The whole supervision contract rides harness=; a variant must never move it.
  assert_grep "harness=claude" "$HOME_DIR/state/$id.meta" \
    "meta harness must stay the base adapter name when a variant is selected"
  assert_grep "launch=gateway" "$HOME_DIR/state/$id.meta" \
    "meta should record the selected variant NAME for traceability"
  assert_present "$WT_DIR/.claude/settings.local.json" \
    "a variant must not drop the claude turn-end hook"
  pass "a launch variant changes how claude starts, never which harness it is"
}

test_launch_variant_layers_over_harness_level() {
  local rec id out status launch
  id=ovr-variant-layer-b2
  rec=$(make_spawn_case ovr-variant-layer claude "$id")
  read_case_record "$rec"
  # harness level supplies args + one env key; the variant supplies command + a
  # second env key and overrides the shared one.
  write_overrides "$HOME_DIR" '{"claude":{"command":"cc","args":["--base-arg"],"env":{"SHARED":"base","ONLY_BASE":"1"},"variants":{"gateway":{"command":"/opt/fake/claude-gw","env":{"SHARED":"variant","ONLY_VARIANT":"1"}}}}}'

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --launch gateway)
  status=$?
  expect_code 0 "$status" "layered variant spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  # command: variant wins. args: variant declares none, so the harness-level value survives.
  assert_contains "$launch" "/opt/fake/claude-gw '--base-arg'" \
    "variant command should win while the harness-level args survive"
  # env: merged, variant winning the shared key.
  assert_contains "$launch" "SHARED='variant'" "variant env must win on a key conflict"
  assert_contains "$launch" "ONLY_BASE='1'" "harness-level env keys must survive into a variant launch"
  assert_contains "$launch" "ONLY_VARIANT='1'" "variant env keys must be applied"
  assert_not_contains "$launch" "SHARED='base'" "the overridden harness-level env value must not be duplicated"
  pass "a variant layers over the harness-level entry per axis instead of replacing it"
}

test_empty_variant_inherits_base_axes() {
  local rec id out status launch expected state_real sq_te sq_br
  id=ovr-variant-empty-b3
  rec=$(make_spawn_case ovr-variant-empty codex "$id")
  read_case_record "$rec"
  # `{}` is a declared, no-op launch identity. It must inherit every base axis.
  write_overrides "$HOME_DIR" '{"codex":{"command":"codex-base","args":["--base-arg"],"env":{"BASE_ENV":"base"},"default_variant":"api","variants":{"api":{}}}}'

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "an empty default launch variant should succeed"
  assert_contains "$out" "spawned $id harness=codex launch=api" \
    "empty default variant should be selected and reported"
  launch=$(cat "$LAUNCH_LOG")
  state_real=$(cd "$HOME_DIR/state" && pwd -P)
  sq_te="'$state_real/$id.turn-ended'"
  sq_br="'$HOME_DIR/data/$id/brief.md'"
  # shellcheck disable=SC2016
  expected='BASE_ENV='"'base'"' codex-base '"'--base-arg'"' -c "notify=[\"bash\",\"-c\",\"touch '"$sq_te"'\"]" "$(cat '"$sq_br"')"'
  [ "$launch" = "$expected" ] || fail "empty variant did not inherit the harness-level launch axes"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "an empty variant is declared and inherits command, args, and env from its harness"
}

test_variant_explicitly_overrides_all_launch_axes() {
  local rec id out status launch
  id=ovr-variant-all-axes-b4
  rec=$(make_spawn_case ovr-variant-all-axes claude "$id")
  read_case_record "$rec"
  write_overrides "$HOME_DIR" '{"claude":{"command":"base-command","args":["--base-arg"],"env":{"BASE_ENV":"base","SHARED":"base"},"variants":{"gateway":{"command":"variant-command","args":["--variant-arg"],"env":{"VARIANT_ENV":"variant","SHARED":"variant"}}}}}'

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --launch gateway)
  status=$?
  expect_code 0 "$status" "a variant overriding every launch axis should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "BASE_ENV='base' SHARED='variant' VARIANT_ENV='variant' variant-command '--variant-arg'" \
    "variant command, args, and env should override their harness-level counterparts"
  assert_not_contains "$launch" "base-command" "variant command must replace the harness-level command"
  assert_not_contains "$launch" "--base-arg" "variant args must replace the harness-level args"
  assert_not_contains "$launch" "SHARED='base'" "variant env must win over the harness-level env"
  pass "a variant's explicit command, args, and env overrides retain their existing behavior"
}

test_default_variant_applies_without_flag() {
  local rec id out status launch
  id=ovr-variant-default-b3
  rec=$(make_spawn_case ovr-variant-default claude "$id")
  read_case_record "$rec"
  write_overrides "$HOME_DIR" '{"claude":{"command":"cc","default_variant":"gateway","variants":{"gateway":{"command":"/opt/fake/claude-gw"},"subscription":{}}}}'

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn should succeed using default_variant"
  assert_contains "$out" "launch=gateway" "default_variant should apply when no --launch is passed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "/opt/fake/claude-gw" "default_variant should select the gateway command"
  pass "default_variant makes the default launch identity a config item"
}

test_explicit_launch_beats_default_variant() {
  local rec id out status launch
  id=ovr-variant-precedence-b4
  rec=$(make_spawn_case ovr-variant-precedence claude "$id")
  read_case_record "$rec"
  write_overrides "$HOME_DIR" '{"claude":{"command":"cc","default_variant":"gateway","variants":{"gateway":{"command":"/opt/fake/claude-gw"},"subscription":{"command":"/opt/fake/cc-sub"}}}}'

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --launch subscription)
  status=$?
  expect_code 0 "$status" "explicit --launch should succeed"
  assert_contains "$out" "launch=subscription" "an explicit --launch must beat default_variant"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "/opt/fake/cc-sub" "explicit --launch should select its own command"
  assert_not_contains "$launch" "claude-gw" "default_variant must not leak into an explicit selection"
  pass "an explicit --launch overrides default_variant"
}

test_undeclared_variant_refuses_spawn() {
  local rec id out status
  id=ovr-variant-unknown-b5
  rec=$(make_spawn_case ovr-variant-unknown claude "$id")
  read_case_record "$rec"
  write_overrides "$HOME_DIR" "$VARIANT_JSON"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --launch typo)
  status=$?
  [ "$status" -ne 0 ] || fail "an undeclared launch variant must refuse the spawn, not fall back"
  assert_contains "$out" "not declared" "refusal should name the undeclared variant problem"
  assert_contains "$out" "gateway" "refusal should list the variants that ARE declared"
  assert_contains "$out" "declared variants for claude: gateway" \
    "refusal should list only the actually declared variant names"
  assert_not_contains "$out" "declared variants for claude: typo" \
    "refusal must not contradict itself by listing the requested missing variant as declared"
  # Silently falling back would launch on the WRONG billing account; nothing may start.
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused variant must not launch anything"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused variant must not leave task state behind"
  pass "an undeclared variant name is a hard refusal, never a silent fallback"
}

test_undeclared_default_variant_refuses_spawn() {
  local rec id out status
  id=ovr-variant-baddefault-b6
  rec=$(make_spawn_case ovr-variant-baddefault claude "$id")
  read_case_record "$rec"
  write_overrides "$HOME_DIR" '{"claude":{"command":"cc","default_variant":"gone","variants":{"gateway":{}}}}'

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "a default_variant naming a removed variant must refuse the spawn"
  assert_contains "$out" "not declared" "refusal should explain the undeclared default_variant"
  pass "a stale default_variant refuses the spawn instead of silently ignoring the default"
}

test_launch_without_overrides_file_refuses() {
  local rec id out status
  id=ovr-variant-nofile-b7
  rec=$(make_spawn_case ovr-variant-nofile claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --launch gateway)
  status=$?
  [ "$status" -ne 0 ] || fail "--launch with no override file must refuse rather than launch the default"
  assert_contains "$out" "gateway" "refusal should name the requested variant"
  pass "--launch refuses when no override file declares any variant"
}

test_variants_declared_but_unselected_is_byte_identical() {
  local rec id out status launch expected
  id=ovr-variant-unselected-b8
  rec=$(make_spawn_case ovr-variant-unselected claude "$id")
  read_case_record "$rec"
  # Variants exist but none is selected and no default_variant is set: the launch
  # must match the pre-variant harness-level-only result exactly.
  write_overrides "$HOME_DIR" "$VARIANT_JSON"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "declaring variants must not affect an unselected spawn"
  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false cc --dangerously-skip-permissions \"\$(cat '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "declaring variants changed the unselected launch"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_no_grep "launch=" "$HOME_DIR/state/$id.meta" \
    "meta must carry no launch= line when no variant was selected"
  pass "declaring variants leaves an unselected launch and its meta byte-identical"
}

test_variant_env_never_reaches_meta() {
  local rec id out status
  id=ovr-variant-secret-b9
  rec=$(make_spawn_case ovr-variant-secret claude "$id")
  read_case_record "$rec"
  # The design forbids credentials in this file at all; this test pins the weaker
  # backstop that whatever env a variant does carry never lands in tracked state.
  write_overrides "$HOME_DIR" '{"claude":{"variants":{"gateway":{"env":{"ANTHROPIC_AUTH_TOKEN":"sk-must-not-persist"}}}}}'

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --launch gateway)
  status=$?
  expect_code 0 "$status" "variant env spawn should succeed"
  assert_no_grep "sk-must-not-persist" "$HOME_DIR/state/$id.meta" \
    "variant env must never be recorded into task meta"
  pass "a variant's env reaches the launch but never the recorded task state"
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
test_launch_variant_selects_variant_command
test_launch_variant_keeps_harness_identity
test_launch_variant_layers_over_harness_level
test_empty_variant_inherits_base_axes
test_variant_explicitly_overrides_all_launch_axes
test_default_variant_applies_without_flag
test_explicit_launch_beats_default_variant
test_undeclared_variant_refuses_spawn
test_undeclared_default_variant_refuses_spawn
test_launch_without_overrides_file_refuses
test_variants_declared_but_unselected_is_byte_identical
test_variant_env_never_reaches_meta

echo "# all fm-spawn-harness-overrides tests passed"
