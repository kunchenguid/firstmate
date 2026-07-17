#!/usr/bin/env bash
# Focused behavior tests for fm-spawn.sh's optional agent-secrets launch prefix.
#
# The baseline rows pin every verified launch template before the optional prefix
# is applied, including the distinct Codex and Pi secondmate templates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-agent-secrets.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT
FUNCTIONS="$TMP_ROOT/spawn-functions.sh"

extract_spawn_functions() {
  awk '
    /^agent_secrets_launch_prefix\(\)/ || /^launch_template\(\)/ { copying = 1 }
    copying { print }
    copying && /^}/ { copying = 0; print "" }
  ' "$SPAWN" > "$FUNCTIONS"
  # shellcheck disable=SC1090  # generated directly from the tracked script under test
  . "$FUNCTIONS"
}

launch_template_baselines() {
  cat <<'ROWS'
claude|ship|CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"
codex|ship|codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"
codex|secondmate|codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(cat __BRIEF__)"
opencode|ship|OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode __MODELFLAG__--prompt "$(cat __BRIEF__)"
pi|ship|pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(cat __BRIEF__)"
pi|secondmate|pi __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(cat __BRIEF__)"
grok|ship|grok --always-approve __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"
ROWS
}

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
      for arg in "$@"; do
        if [ "$prev" = -l ]; then
          printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$arg
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

run_spawn_capture() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" \
    PATH="$fakebin:/usr/bin:/bin" "$SPAWN" "$@" >/dev/null 2>&1
}

make_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '%s\n' '# Firstmate' > "$home/AGENTS.md"
  printf '%s\n' 'charter' > "$home/data/charter.md"
}

test_absent_gate_keeps_final_commands_byte_identical() {
  local world home project wt fakebin launchlog harness id expected actual secondmate secondmate_real state_real
  world="$TMP_ROOT/final-baselines"
  home="$world/home"
  project="$world/project"
  wt="$world/worktree"
  launchlog="$world/launch.log"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  state_real=$(cd "$home/state" && pwd -P)
  fm_git_worktree "$project" "$wt" baseline-worktree
  fakebin=$(make_spawn_fakebin "$world/fake")

  for harness in claude codex opencode pi grok; do
    id="agent-secrets-${harness}-z1"
    mkdir -p "$home/data/$id"
    printf '%s\n' 'brief' > "$home/data/$id/brief.md"
    run_spawn_capture "$home" "$wt" "$fakebin" "$launchlog" "$id" "$project" "$harness" \
      || fail "$harness absent-gate spawn failed"
    case "$harness" in
      claude)
        expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$(cat '$home/data/$id/brief.md')\""
        ;;
      codex)
        expected="codex --dangerously-bypass-approvals-and-sandbox -c \"notify=[\\\"bash\\\",\\\"-c\\\",\\\"touch '$state_real/$id.turn-ended'\\\"]\" \"\$(cat '$home/data/$id/brief.md')\""
        ;;
      opencode)
        expected="OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode --prompt \"\$(cat '$home/data/$id/brief.md')\""
        ;;
      pi)
        expected="pi -e '$home/state/$id.pi-ext.ts' \"\$(cat '$home/data/$id/brief.md')\""
        ;;
      grok)
        expected="grok --always-approve \"\$(cat '$home/data/$id/brief.md')\""
        ;;
    esac
    actual=$(cat "$launchlog")
    [ "$actual" = "$expected" ] \
      || fail "$harness absent-gate final command changed"$'\n'"expected: $expected"$'\n'"actual:   $actual"
  done

  for harness in codex pi; do
    id="agent-secrets-${harness}-secondmate-z2"
    secondmate="$world/$id"
    make_secondmate_home "$secondmate" "$id"
    secondmate_real=$(cd "$secondmate" && pwd -P)
    run_spawn_capture "$home" "$wt" "$fakebin" "$launchlog" "$id" "$secondmate" "$harness" --secondmate \
      || fail "$harness secondmate absent-gate spawn failed"
    case "$harness" in
      codex)
        expected="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME='$secondmate_real' codex --dangerously-bypass-approvals-and-sandbox \"\$(cat '$secondmate_real/data/charter.md')\""
        ;;
      pi)
        expected="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME='$secondmate_real' pi -e '$secondmate_real/.pi/extensions/fm-primary-turnend-guard.ts' -e '$secondmate_real/.pi/extensions/fm-primary-pi-watch.ts' \"\$(cat '$secondmate_real/data/charter.md')\""
        ;;
    esac
    actual=$(cat "$launchlog")
    [ "$actual" = "$expected" ] \
      || fail "$harness secondmate absent-gate final command changed"$'\n'"expected: $expected"$'\n'"actual:   $actual"
  done

  pass "the absent gate preserves every final verified launch command byte-for-byte"
}

test_launch_template_baselines() {
  local harness kind expected got count missing_security
  missing_security="$TMP_ROOT/missing-security"
  count=0
  while IFS='|' read -r harness kind expected; do
    [ -n "$harness" ] || continue
    count=$((count + 1))
    got=$(PATH=/usr/bin:/bin launch_template "$harness" "$kind" "$missing_security") \
      || fail "$harness/$kind launch template returned non-zero"
    [ "$got" = "$expected" ] \
      || fail "$harness/$kind baseline changed"$'\n'"expected: $expected"$'\n'"actual:   $got"
  done < <(launch_template_baselines)
  [ "$count" -eq 7 ] || fail "expected seven verified launch-template rows, got $count"
  pass "all verified harness templates match the pre-injection byte baseline"
}

make_fake_command() {
  local path=$1 status=${2:-0}
  mkdir -p "$(dirname "$path")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'exit %s\n' "$status"
  } > "$path"
  chmod +x "$path"
}

make_security_probe() {
  local path=$1 status=$2
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_SECURITY_LOG"
if IFS= read -r _line; then
  printf '%s\n' 'security unexpectedly received interactive input' >&2
  exit 97
fi
printf '%s\n' 'SECRET_TOKEN_MUST_NOT_ESCAPE'
printf '%s\n' 'SECRET_ERROR_MUST_NOT_ESCAPE' >&2
exit "$FM_FAKE_SECURITY_STATUS"
SH
  chmod +x "$path"
  : > "$TMP_ROOT/security.log"
  export FM_FAKE_SECURITY_LOG="$TMP_ROOT/security.log"
  export FM_FAKE_SECURITY_STATUS="$status"
}

assert_templates_for_gate() {
  local label fake_path security_bin expect_prefix harness kind baseline expected got count
  label=$1
  fake_path=$2
  security_bin=$3
  expect_prefix=$4
  count=0
  while IFS='|' read -r harness kind baseline; do
    [ -n "$harness" ] || continue
    count=$((count + 1))
    expected=$baseline
    if [ "$expect_prefix" = yes ]; then
      case "$harness" in
        claude)
          expected=${baseline/CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false /CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false $AGENT_SECRETS_PREFIX}
          ;;
        opencode)
          expected=${baseline/ opencode / __AGENT_SECRETS_PREFIX__opencode }
          expected=${expected/__AGENT_SECRETS_PREFIX__/$AGENT_SECRETS_PREFIX}
          ;;
        *) expected="$AGENT_SECRETS_PREFIX$baseline" ;;
      esac
    fi
    got=$(PATH="$fake_path:/usr/bin:/bin" launch_template "$harness" "$kind" "$security_bin") \
      || fail "$label: $harness/$kind launch template returned non-zero"
    [ "$got" = "$expected" ] \
      || fail "$label: $harness/$kind launch mismatch"$'\n'"expected: $expected"$'\n'"actual:   $got"
  done < <(launch_template_baselines)
  [ "$count" -eq 7 ] || fail "$label: expected seven verified launch-template rows, got $count"
}

test_all_presence_conditions_enable_prefix() {
  local fakebin security_bin output
  fakebin="$TMP_ROOT/present-bin"
  security_bin="$TMP_ROOT/present-security"
  make_fake_command "$fakebin/op"
  make_fake_command "$fakebin/with-1password-local-development-reader"
  make_security_probe "$security_bin" 0

  output=$(PATH="$fakebin:/usr/bin:/bin" agent_secrets_launch_prefix "$security_bin" 2>&1) \
    || fail "present gate returned non-zero"
  [ "$output" = "$AGENT_SECRETS_PREFIX" ] \
    || fail "present gate leaked probe output or produced the wrong prefix"$'\n'"actual: $output"
  assert_contains "$(cat "$FM_FAKE_SECURITY_LOG")" \
    "find-generic-password -a kunchen -s op-local-sa -w" \
    "Keychain probe did not use the exact account, service, and password-only lookup"
  assert_templates_for_gate "all conditions present" "$fakebin" "$security_bin" yes
  pass "all verified templates receive the exact prefix when every presence condition succeeds"
}

test_each_missing_condition_is_byte_identical() {
  local fakebin security_bin

  fakebin="$TMP_ROOT/missing-op-bin"
  security_bin="$TMP_ROOT/missing-op-security"
  make_fake_command "$fakebin/with-1password-local-development-reader"
  make_security_probe "$security_bin" 0
  assert_templates_for_gate "op absent" "$fakebin" "$security_bin" no
  [ ! -s "$FM_FAKE_SECURITY_LOG" ] || fail "op-absent gate still queried Keychain"

  fakebin="$TMP_ROOT/missing-wrapper-bin"
  security_bin="$TMP_ROOT/missing-wrapper-security"
  make_fake_command "$fakebin/op"
  make_security_probe "$security_bin" 0
  assert_templates_for_gate "wrapper absent" "$fakebin" "$security_bin" no
  [ ! -s "$FM_FAKE_SECURITY_LOG" ] || fail "wrapper-absent gate still queried Keychain"

  fakebin="$TMP_ROOT/missing-keychain-bin"
  security_bin="$TMP_ROOT/missing-keychain-security"
  make_fake_command "$fakebin/op"
  make_fake_command "$fakebin/with-1password-local-development-reader"
  make_security_probe "$security_bin" 44
  assert_templates_for_gate "Keychain item absent" "$fakebin" "$security_bin" no

  pass "each missing presence condition leaves every verified template byte-identical"
}

test_literal_home_and_noninteractive_silent_probe() {
  local fakebin security_bin output
  fakebin="$TMP_ROOT/literal-home-bin"
  security_bin="$TMP_ROOT/literal-home-security"
  make_fake_command "$fakebin/op"
  make_fake_command "$fakebin/with-1password-local-development-reader"
  make_security_probe "$security_bin" 0
  output=$(HOME=/must/not/expand PATH="$fakebin:/usr/bin:/bin" agent_secrets_launch_prefix "$security_bin" 2>&1)
  [ "$output" = "$AGENT_SECRETS_PREFIX" ] \
    || fail "prefix expanded HOME early or leaked Keychain probe output: $output"
  assert_not_contains "$output" "SECRET_TOKEN_MUST_NOT_ESCAPE" "Keychain token reached gate output"
  assert_not_contains "$output" "/must/not/expand" "HOME expanded during launch composition"
  pass "Keychain probing is stdin-closed and silent, and HOME remains literal"
}

extract_spawn_functions
# shellcheck disable=SC2016  # HOME must remain literal until the target pane shell
AGENT_SECRETS_PREFIX='with-1password-local-development-reader op run --env-file "$HOME/.config/agent-secrets.env" -- '
test_launch_template_baselines
test_absent_gate_keeps_final_commands_byte_identical
test_all_presence_conditions_enable_prefix
test_each_missing_condition_is_byte_identical
test_literal_home_and_noninteractive_silent_probe

echo "# all fm-spawn-agent-secrets tests passed"
