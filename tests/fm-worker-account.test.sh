#!/usr/bin/env bash
# Behavior tests for explicit worker-account selection (issue 4574).
#
# Exercised through bin/fm-worker-account-lib.sh (the sourced public interface)
# and through bin/fm-spawn.sh launch construction and refusal. Assertions pin
# observable spawn behavior: exit status, stderr, metadata presence, and the
# captured launch command. They do not grep implementation source.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-worker-account-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-account)

make_world() {
  local name=$1 harness=${2:-claude} world home fakebin
  world="$TMP_ROOT/$name"
  home="$world/home"
  fakebin=$(fm_test_make_spawn_fakebin "$world/fake" pi pi-signed)
  fm_test_spawn_home "$home" "$harness"
  printf '%s\n' "$world|$home|$fakebin"
}

read_world() {
  IFS='|' read -r WORLD HOME_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_account_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  mkdir -p "$wt"
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

# --- library: resolve --------------------------------------------------------

test_missing_claude_declaration_refuses() {
  local dir cfg err rc
  dir="$TMP_ROOT/lib-missing-claude"
  mkdir -p "$dir/config"
  cfg="$dir/config/claude-account"
  err=$(mktemp "$dir/err.XXXXXX")
  fm_worker_account_resolve claude "$dir/config" "$dir" >"$dir/out" 2>"$err"
  rc=$?
  expect_code 1 "$rc" "a missing Claude declaration must refuse"
  assert_contains "$(cat "$err")" "require an explicit account selection" \
    "refusal must say the declaration is required"
  assert_contains "$(cat "$err")" "$cfg" "refusal must name the file to create"
  assert_contains "$(cat "$err")" "does not spend an ambient" \
    "refusal must distinguish absence from ordinary-account consent"
  pass "a missing Claude account declaration refuses with the file to create"
}

test_missing_pi_declaration_refuses() {
  local dir err rc
  dir="$TMP_ROOT/lib-missing-pi"
  mkdir -p "$dir/config"
  err=$(mktemp "$dir/err.XXXXXX")
  fm_worker_account_resolve pi "$dir/config" "$dir" >"$dir/out" 2>"$err"
  rc=$?
  expect_code 1 "$rc" "a missing Pi declaration must refuse"
  assert_contains "$(cat "$err")" "$dir/config/pi-account" \
    "refusal must name config/pi-account"
  pass "a missing Pi account declaration refuses with the file to create"
}

test_ordinary_claude_selects_the_vendor_default_root() {
  local dir home root provider
  dir="$TMP_ROOT/lib-ordinary-claude"
  home="$dir/user"
  mkdir -p "$home/.claude" "$dir/config"
  printf 'ordinary\n' > "$dir/config/claude-account"
  HOME="$home" IFS=$'\t' read -r root provider <<EOF
$(HOME="$home" fm_worker_account_resolve claude "$dir/config" "$dir")
EOF
  [ "$root" = "$home/.claude" ] || fail "ordinary Claude root was '$root', not $home/.claude"
  [ -z "$provider" ] || fail "Claude resolve must not invent a provider"
  pass "ordinary explicitly selects the vendor default Claude root"
}

test_explicit_claude_path_is_the_selected_root() {
  local dir root
  dir="$TMP_ROOT/lib-path-claude"
  mkdir -p "$dir/config" "$dir/accounts/work"
  printf '%s\n' "$dir/accounts/work" > "$dir/config/claude-account"
  root=$(fm_worker_account_resolve claude "$dir/config" "$dir")
  root=${root%%$'\t'*}
  [ "$root" = "$dir/accounts/work" ] || fail "explicit Claude root was '$root'"
  pass "an explicit Claude path is the selected account root"
}

test_pi_declaration_requires_a_provider() {
  local dir err rc
  dir="$TMP_ROOT/lib-pi-root-only"
  mkdir -p "$dir/config" "$dir/accounts/pi"
  printf '%s\n' "$dir/accounts/pi" > "$dir/config/pi-account"
  err=$(mktemp "$dir/err.XXXXXX")
  fm_worker_account_resolve pi "$dir/config" "$dir" >"$dir/out" 2>"$err"
  rc=$?
  expect_code 1 "$rc" "a Pi root without a provider must refuse"
  assert_contains "$(cat "$err")" "provider this home may spend" \
    "refusal must say selecting the root alone is not enough"
  pass "selecting a Pi root without naming a provider refuses"
}

test_pi_ordinary_with_provider_resolves() {
  local dir home root provider
  dir="$TMP_ROOT/lib-ordinary-pi"
  home="$dir/user"
  mkdir -p "$home/.pi/agent" "$dir/config"
  printf 'ordinary\nopenai-codex\n' > "$dir/config/pi-account"
  HOME="$home" IFS=$'\t' read -r root provider <<EOF
$(HOME="$home" fm_worker_account_resolve pi "$dir/config" "$dir")
EOF
  [ "$root" = "$home/.pi/agent" ] || fail "ordinary Pi root was '$root'"
  [ "$provider" = openai-codex ] || fail "Pi provider was '$provider'"
  pass "ordinary Pi plus a declared provider selects the vendor default root"
}

test_pi_guard_requires_matching_provider_model() {
  local err
  err=$(mktemp "$TMP_ROOT/guard.XXXXXX")
  fm_worker_account_pi_guard openai-codex openai-codex/gpt-5.4 || fail "matching provider/id must pass"
  fm_worker_account_pi_guard openai-codex openai-codex-work/gpt-5.4 >"$TMP_ROOT/guard.out" 2>"$err" && \
    fail "a different provider in --model must refuse"
  assert_contains "$(cat "$err")" "openai-codex-work" \
    "mismatch refusal must name the --model provider"
  fm_worker_account_pi_guard openai-codex gpt-5.4 >"$TMP_ROOT/guard.out" 2>"$err" && \
    fail "an unqualified model must refuse"
  assert_contains "$(cat "$err")" "names no provider" \
    "unqualified-model refusal must say the account cannot be proved"
  pass "Pi launches must name the declared provider in --model"
}

test_raw_launch_model_reads_the_embedded_flag() {
  [ "$(fm_worker_account_raw_model 'pi --model fake/test --offline')" = fake/test ] || \
    fail "space-separated --model was not read"
  [ "$(fm_worker_account_raw_model "pi --model='openai-codex/gpt-5.4'")" = openai-codex/gpt-5.4 ] || \
    fail "equals-form --model was not read"
  [ -z "$(fm_worker_account_raw_model 'pi --offline')" ] || \
    fail "a raw command with no --model must yield an empty model"
  pass "a raw Pi command's embedded --model is the account the launch would spend"
}

# --- spawn -------------------------------------------------------------------

test_spawn_refuses_claude_without_a_declaration_before_any_record() {
  local rec world home fakebin wt launchlog out status id=no-claude-account
  rec=$(make_world spawn-missing-claude claude)
  read_world "$rec"
  world=$WORLD
  home=$HOME_DIR
  fakebin=$FAKEBIN_DIR
  rm -f "$home/config/claude-account"
  wt="$world/wt"
  fm_git_worktree "$world/proj" "$wt" wt-missing-claude
  fm_test_spawn_brief "$home" "$id"
  launchlog="$world/launch.log"
  out=$(run_account_spawn "$home" "$wt" "$fakebin" "$launchlog" \
    "$id" "$world/proj" --mode no-mistakes --yolo off --harness claude 2>&1)
  status=$?
  expect_code 1 "$status" "claude spawn without config/claude-account must refuse"$'\n'"$out"
  assert_contains "$out" "config/claude-account" "refusal must name the file"
  assert_absent "$home/state/$id.meta" "a missing declaration must not publish metadata"
  [ ! -s "$launchlog" ] || fail "a missing declaration launched an agent"
  pass "a Claude spawn without an account declaration refuses before any record"
}

test_spawn_refuses_pi_without_a_declaration() {
  local rec world home fakebin wt launchlog out status id=no-pi-account
  rec=$(make_world spawn-missing-pi pi)
  read_world "$rec"
  world=$WORLD
  home=$HOME_DIR
  fakebin=$FAKEBIN_DIR
  rm -f "$home/config/pi-account"
  wt="$world/wt"
  fm_git_worktree "$world/proj" "$wt" wt-missing-pi
  fm_test_spawn_brief "$home" "$id"
  launchlog="$world/launch.log"
  out=$(run_account_spawn "$home" "$wt" "$fakebin" "$launchlog" \
    "$id" "$world/proj" --mode no-mistakes --yolo off --harness pi --model fake/test 2>&1)
  status=$?
  expect_code 1 "$status" "pi spawn without config/pi-account must refuse"$'\n'"$out"
  assert_contains "$out" "config/pi-account" "refusal must name the file"
  assert_absent "$home/state/$id.meta" "a missing Pi declaration must not publish metadata"
  pass "a Pi spawn without an account declaration refuses before any record"
}

test_spawn_claude_ignores_ambient_config_dir() {
  local rec world home fakebin wt launchlog out launch id=ambient-ignored
  rec=$(make_world spawn-ambient claude)
  read_world "$rec"
  world=$WORLD
  home=$HOME_DIR
  fakebin=$FAKEBIN_DIR
  mkdir -p "$world/ambient-claude"
  wt="$world/wt"
  fm_git_worktree "$world/proj" "$wt" wt-ambient
  fm_test_spawn_brief "$home" "$id"
  launchlog="$world/launch.log"
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$world/ambient-claude" \
    run_account_spawn "$home" "$wt" "$fakebin" "$launchlog" \
    "$id" "$world/proj" --mode no-mistakes --yolo off --harness claude 2>&1)
  expect_code 0 "$?" "declared Claude spawn should succeed"$'\n'"$out"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$home/accounts/claude'" \
    "launch must spend the declared root"
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR='$world/ambient-claude'" \
    "launch must not spend the ambient CLAUDE_CONFIG_DIR"
  assert_contains "$launch" "-u ANTHROPIC_API_KEY" \
    "Claude launch must shed environment credentials ranked above the selected root"
  pass "a declared Claude account wins over an ambient CLAUDE_CONFIG_DIR"
}

test_spawn_pi_refuses_a_provider_the_home_did_not_declare() {
  local rec world home fakebin wt launchlog out status id=pi-wrong-provider
  rec=$(make_world spawn-pi-mismatch pi)
  read_world "$rec"
  world=$WORLD
  home=$HOME_DIR
  fakebin=$FAKEBIN_DIR
  wt="$world/wt"
  fm_git_worktree "$world/proj" "$wt" wt-mismatch
  fm_test_spawn_brief "$home" "$id"
  launchlog="$world/launch.log"
  out=$(run_account_spawn "$home" "$wt" "$fakebin" "$launchlog" \
    "$id" "$world/proj" --mode no-mistakes --yolo off --harness pi \
    --model openai-codex-work/gpt-5.4 2>&1)
  status=$?
  expect_code 1 "$status" "a Pi spawn on an undeclared provider must refuse"$'\n'"$out"
  assert_contains "$out" "openai-codex-work" "refusal must name the undeclared provider"
  assert_absent "$home/state/$id.meta" "an undeclared Pi provider must not publish metadata"
  pass "an undeclared Pi provider in a shared root cannot be spent"
}

test_spawn_pi_refuses_an_unqualified_model() {
  local rec world home fakebin wt launchlog out status id=pi-no-provider
  rec=$(make_world spawn-pi-bare pi)
  read_world "$rec"
  world=$WORLD
  home=$HOME_DIR
  fakebin=$FAKEBIN_DIR
  wt="$world/wt"
  fm_git_worktree "$world/proj" "$wt" wt-bare
  fm_test_spawn_brief "$home" "$id"
  launchlog="$world/launch.log"
  out=$(run_account_spawn "$home" "$wt" "$fakebin" "$launchlog" \
    "$id" "$world/proj" --mode no-mistakes --yolo off --harness pi 2>&1)
  status=$?
  expect_code 1 "$status" "a Pi spawn without --model must refuse"$'\n'"$out"
  assert_contains "$out" "names no provider" "refusal must say the account cannot be proved"
  pass "a Pi spawn without --model as provider/id refuses rather than using defaultProvider"
}

test_spawn_codex_does_not_require_an_account_declaration() {
  local rec world home fakebin wt launchlog out id=codex-no-account
  rec=$(make_world spawn-codex-ok codex)
  read_world "$rec"
  world=$WORLD
  home=$HOME_DIR
  fakebin=$FAKEBIN_DIR
  rm -f "$home/config/claude-account" "$home/config/pi-account"
  wt="$world/wt"
  fm_git_worktree "$world/proj" "$wt" wt-codex
  fm_test_spawn_brief "$home" "$id"
  launchlog="$world/launch.log"
  out=$(run_account_spawn "$home" "$wt" "$fakebin" "$launchlog" \
    "$id" "$world/proj" --mode no-mistakes --yolo off --harness codex 2>&1)
  expect_code 0 "$?" "codex spawn without account files should succeed"$'\n'"$out"
  pass "runners without a selectable account root still launch without a declaration"
}

test_spawn_claude_ordinary_uses_the_vendor_default_under_throwaway_home() {
  local rec world home fakebin wt launchlog out launch id=ordinary-claude
  rec=$(make_world spawn-ordinary claude)
  read_world "$rec"
  world=$WORLD
  home=$HOME_DIR
  fakebin=$FAKEBIN_DIR
  mkdir -p "$home/user-home/.claude"
  printf 'ordinary\n' > "$home/config/claude-account"
  wt="$world/wt"
  fm_git_worktree "$world/proj" "$wt" wt-ordinary
  fm_test_spawn_brief "$home" "$id"
  launchlog="$world/launch.log"
  out=$(run_account_spawn "$home" "$wt" "$fakebin" "$launchlog" \
    "$id" "$world/proj" --mode no-mistakes --yolo off --harness claude 2>&1)
  expect_code 0 "$?" "ordinary Claude spawn should succeed"$'\n'"$out"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$home/user-home/.claude'" \
    "ordinary must resolve to the throwaway HOME's vendor default, not an ambient store"
  pass "ordinary is an explicit selection of the vendor default Claude root"
}

test_preflight_refuses_a_skipped_keychain_without_a_recorded_login() {
  local rec world home fakebin wt launchlog out status id=empty-claude
  rec=$(make_world spawn-empty-root claude)
  read_world "$rec"
  world=$WORLD
  home=$HOME_DIR
  fakebin=$FAKEBIN_DIR
  printf 'skipped\n' > "$home/accounts/claude/.fake-auth"
  printf '{"oauthAccount":true}\n' > "$home/accounts/claude/.claude.json.wrong"
  printf '{"schemaVersion":1}\n' > "$home/accounts/claude/.claude.json"
  wt="$world/wt"
  fm_git_worktree "$world/proj" "$wt" wt-empty
  fm_test_spawn_brief "$home" "$id"
  launchlog="$world/launch.log"
  # quota-axi fake reports the file's status; skipped plus no oauthAccount must refuse.
  printf '{"schemaVersion":1,"auth":[{"provider":"claude","sources":[{"source":"keychain","status":"skipped","credentialPresent":true}]}]}\n' \
    > "$home/accounts/claude/.quota-out"
  cat > "$fakebin/quota-axi" <<SH
#!/bin/sh
printf '%s\n' '{"schemaVersion":1,"auth":[{"provider":"claude","sources":[{"source":"keychain","status":"skipped","credentialPresent":true}]}]}'
SH
  chmod +x "$fakebin/quota-axi"
  out=$(run_account_spawn "$home" "$wt" "$fakebin" "$launchlog" \
    "$id" "$world/proj" --mode no-mistakes --yolo off --harness claude 2>&1)
  status=$?
  expect_code 1 "$status" "an empty Claude root with skipped keychain must refuse"$'\n'"$out"
  assert_contains "$out" "holds no usable login" "refusal must say the root cannot authenticate"
  assert_absent "$home/state/$id.meta" "an empty Claude root must not publish metadata"
  pass "a skipped keychain answer without oauthAccount does not authenticate an empty Claude root"
}

test_secondmate_launch_reads_the_launching_home_not_its_own() {
  local rec world home fakebin sm launchlog out launch id=sm-launching-account
  rec=$(make_world spawn-sm-account claude)
  read_world "$rec"
  world=$WORLD
  home=$HOME_DIR
  fakebin=$FAKEBIN_DIR
  sm="$world/sm"
  mkdir -p "$sm/bin" "$sm/data" "$sm/config" "$sm/accounts/other"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  printf '%s\n' "$sm/accounts/other" > "$sm/config/claude-account"
  launchlog="$world/launch.log"
  out=$(run_account_spawn "$home" "$sm" "$fakebin" "$launchlog" \
    "$id" "$sm" claude --secondmate 2>&1)
  expect_code 0 "$?" "secondmate Claude spawn should succeed"$'\n'"$out"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$home/accounts/claude'" \
    "a secondmate must spend the launching home's declared account"
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR='$sm/accounts/other'" \
    "a secondmate must not spend its own home's worker declaration"
  pass "a secondmate launch reads the launching home, never its own worker files"
}

test_missing_claude_declaration_refuses
test_missing_pi_declaration_refuses
test_ordinary_claude_selects_the_vendor_default_root
test_explicit_claude_path_is_the_selected_root
test_pi_declaration_requires_a_provider
test_pi_ordinary_with_provider_resolves
test_pi_guard_requires_matching_provider_model
test_raw_launch_model_reads_the_embedded_flag
test_spawn_refuses_claude_without_a_declaration_before_any_record
test_spawn_refuses_pi_without_a_declaration
test_spawn_claude_ignores_ambient_config_dir
test_spawn_pi_refuses_a_provider_the_home_did_not_declare
test_spawn_pi_refuses_an_unqualified_model
test_spawn_codex_does_not_require_an_account_declaration
test_spawn_claude_ordinary_uses_the_vendor_default_under_throwaway_home
test_preflight_refuses_a_skipped_keychain_without_a_recorded_login
test_secondmate_launch_reads_the_launching_home_not_its_own
