#!/usr/bin/env bash
# Focused tests for the Linux dependency checker. Network calls and upgrades
# stay outside this suite; fixtures exercise Debian version ordering, APT
# metadata parsing, quiet-window deferral, and NVM upgrade command selection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DEPS="$ROOT/bin/fm-deps.sh"
TMP_ROOT=$(fm_test_tmproot fm-deps-tests)

# shellcheck source=bin/fm-deps.sh
FM_DEPS_SOURCE_ONLY=1 FM_ROOT_OVERRIDE="$ROOT" . "$DEPS"

test_version_ordering() {
  version_is_older 1.2.3 1.2.4 || fail "semver patch update was not detected"
  version_is_older 3.7a 3.7b || fail "lettered patch update was not detected"
  version_is_older 2.45.0-1ubuntu0.2 2.45.0-1ubuntu0.3 \
    || fail "Debian revision update was not detected"
  ! version_is_older 2.0.0 1.9.9 || fail "downgrade was treated as an update"
  ! version_is_older 1.2.3 1.2.3 || fail "equal versions were treated as an update"
  pass "version ordering uses Debian's native comparison semantics"
}

test_apt_metadata() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/apt")
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf 'install ok installed\\t2.45.0-1ubuntu0.2\\n'" > "$fakebin/dpkg-query"
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf 'gh:\\n  Installed: 2.45.0-1ubuntu0.2\\n  Candidate: 2.45.0-1ubuntu0.3\\n'" > "$fakebin/apt-cache"
  chmod +x "$fakebin/dpkg-query" "$fakebin/apt-cache"

  out=$(PATH="$fakebin:$PATH" apt_package_versions gh)
  [ "$out" = $'2.45.0-1ubuntu0.2\t2.45.0-1ubuntu0.3' ] \
    || fail "APT versions were parsed incorrectly: $out"
  pass "APT installed and candidate versions are parsed without refreshing indexes"
}

test_quiet_window_defers() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/quiet")
  # shellcheck disable=SC2016 # literal fixture script; expansion happens when it runs.
  printf '%s\n' '#!/usr/bin/env bash' '[ "${2:-}" = codex ]' > "$fakebin/pgrep"
  chmod +x "$fakebin/pgrep"

  # shellcheck disable=SC2034 # consumed by the sourced offer_update function.
  AVAILABLE=0 DEFERRED=0 CHECK_ONLY=1
  out=$(PATH="$fakebin:$PATH" offer_update codex Codex 0.146.0 0.147.0 quiet)
  assert_contains "$out" "UPDATE: Codex 0.146.0 -> 0.147.0 [quiet window]" \
    "Codex update was reported"
  assert_contains "$out" "DEFER: Codex - Codex process is active; close Codex and rerun" \
    "active Codex process deferred update"
  pass "quiet-window upgrades defer while their runtime is active"
}

test_noninteractive_override_is_source_only() {
  local out status
  out=$(FM_DEPS_SOURCE_ONLY=0 FM_DEPS_INTERACTIVE=1 CHECK_ONLY=0 \
    prompt_yes Unsafe <<<yes 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "non-interactive input authorized an upgrade prompt"
  [ -z "$out" ] || fail "non-interactive input produced an upgrade prompt: $out"
  pass "interactive test overrides cannot authorize non-interactive upgrades"
}

test_quiet_window_probe_failures_defer() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/quiet-failure")
  printf '%s\n' '#!/usr/bin/env bash' 'exit 2' > "$fakebin/pgrep"
  chmod +x "$fakebin/pgrep"

  AVAILABLE=0 DEFERRED=0 CHECK_ONLY=1
  out=$(PATH="$fakebin:$PATH" offer_update codex Codex 0.146.0 0.147.0 quiet)
  assert_contains "$out" \
    "DEFER: Codex - Cannot confirm quiet window because pgrep failed for codex" \
    "failed process inspection did not fail closed"
  pass "quiet-window probe failures defer upgrades"
}

test_quiet_window_rechecks_after_consent() {
  local fakebin count log out
  fakebin=$(fm_fakebin "$TMP_ROOT/quiet-recheck")
  count="$TMP_ROOT/quiet-recheck.count"
  log="$TMP_ROOT/quiet-recheck.log"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'count=0' \
    '[ ! -f "$FM_DEPS_TEST_COUNT" ] || IFS= read -r count < "$FM_DEPS_TEST_COUNT"' \
    'count=$((count + 1))' \
    'printf '\''%s\n'\'' "$count" > "$FM_DEPS_TEST_COUNT"' \
    '[ "$count" -ge 2 ]' > "$fakebin/pgrep"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''%s\n'\'' "$*" >> "$FM_DEPS_TEST_LOG"' > "$fakebin/codex"
  chmod +x "$fakebin/pgrep" "$fakebin/codex"

  out=$(export FM_DEPS_TEST_COUNT="$count" FM_DEPS_TEST_LOG="$log"; \
    PATH="$fakebin:$PATH" FM_DEPS_SOURCE_ONLY=1 FM_DEPS_INTERACTIVE=1 CHECK_ONLY=0 \
      offer_update codex Codex 0.146.0 0.147.0 quiet <<<yes)
  assert_contains "$out" "DEFER: Codex - Codex process is active; close Codex and rerun" \
    "runtime start after consent did not defer the upgrade"
  [ "$(sed -n '1p' "$count")" = 2 ] || fail "quiet window was not checked twice"
  [ ! -e "$log" ] || fail "upgrade ran after the second quiet-window check blocked it"
  pass "quiet windows are rechecked immediately after consent"
}

test_node_upgrade_uses_nvm() {
  local nvm_dir log
  nvm_dir="$TMP_ROOT/nvm"
  log="$TMP_ROOT/nvm.log"
  mkdir -p "$nvm_dir"
  # shellcheck disable=SC2016 # literal fixture function; expansion happens when sourced.
  printf '%s\n' 'nvm() {' '  printf '\''%s\\n'\'' "$*" >> "$FM_DEPS_TEST_LOG"' '}' \
    > "$nvm_dir/nvm.sh"

  FM_DEPS_NVM_DIR="$nvm_dir" FM_DEPS_TEST_LOG="$log" \
    run_upgrade node 24.18.0 24.19.0
  assert_grep "install 24.19.0 --reinstall-packages-from=24.18.0" "$log" \
    "Node upgrade did not preserve global packages"
  assert_grep "alias default 24.19.0" "$log" \
    "Node upgrade did not move the NVM default alias"
  pass "Node upgrades stay on the selected release and preserve NVM globals"
}

test_node_requires_active_nvm_provenance() {
  local fakebin nvm_dir out
  fakebin=$(fm_fakebin "$TMP_ROOT/node-provenance")
  nvm_dir="$TMP_ROOT/node-provenance/nvm"
  mkdir -p "$nvm_dir"
  printf '%s\n' 'nvm() { :; }' > "$nvm_dir/nvm.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'printf '\''v24.18.0\n'\''' > "$fakebin/node"
  chmod +x "$fakebin/node"

  out=$(PATH="$fakebin:$PATH" FM_DEPS_NVM_DIR="$nvm_dir" check_node)
  assert_contains "$out" \
    "MANUAL: Node 24.18.0 is not NVM-managed; update it with its owning package manager" \
    "external Node executable was treated as NVM-managed"
  pass "Node upgrades require active executable provenance under NVM"
}

test_firstmate_update_actions_are_consumed() {
  local fixture fakebin marker log out
  fixture="$TMP_ROOT/firstmate-update"
  fakebin=$(fm_fakebin "$fixture")
  marker="$fixture/updated"
  log="$fixture/send.log"
  mkdir -p "$fixture/bin"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'touch "$FM_DEPS_TEST_UPDATED"' \
    'printf '\''firstmate: updated old..new\n'\''' \
    'printf '\''reread-firstmate: yes\n'\''' \
    'printf '\''nudge-secondmates: fm-one fm-two\n'\''' > "$fixture/bin/fm-update.sh"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''%s|%s|%s\n'\'' "$FM_HOME" "$1" "$2" >> "$FM_DEPS_TEST_LOG"' \
    > "$fixture/bin/fm-send.sh"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ -f "$FM_DEPS_TEST_UPDATED" ]; then printf '\''new\n'\''; else printf '\''old\n'\''; fi' \
    > "$fakebin/git"
  chmod +x "$fixture/bin/fm-update.sh" "$fixture/bin/fm-send.sh" "$fakebin/git"

  out=$(PATH="$fakebin:$PATH" FM_ROOT="$fixture" FM_HOME="$fixture" \
    FM_DEPS_TEST_UPDATED="$marker" FM_DEPS_TEST_LOG="$log" run_upgrade firstmate)
  assert_contains "$out" \
    "REREAD_REQUIRED: $fixture/AGENTS.md changed; re-read it before further work" \
    "Firstmate reread action was discarded"
  assert_grep "$fixture|fm-one|$FM_SECOND_MATE_NUDGE_MESSAGE" "$log" \
    "first updated secondmate was not nudged"
  assert_grep "$fixture|fm-two|$FM_SECOND_MATE_NUDGE_MESSAGE" "$log" \
    "second updated secondmate was not nudged"
  pass "Firstmate post-update reread and nudge actions are consumed"
}

test_mixed_checkout_majors_report_repository_update() {
  local fixture fakebin out
  fixture="$TMP_ROOT/checkout-majors"
  fakebin=$(fm_fakebin "$fixture")
  mkdir -p "$fixture/.github/workflows"
  printf '%s\n' 'uses: actions/checkout@v3' 'uses: actions/checkout@v4' \
    > "$fixture/.github/workflows/ci.yml"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''  4.2.2, Latest\n'\''' > "$fakebin/gh-axi"
  chmod +x "$fakebin/gh-axi"

  out=$(PATH="$fakebin:$PATH" FM_ROOT="$fixture" check_github_actions)
  assert_contains "$out" "REPO_UPDATE: actions/checkout@v3 actions/checkout@v4" \
    "mixed checkout majors were reported as current"
  pass "every actions/checkout call site must use the latest major"
}

test_version_ordering
test_apt_metadata
test_quiet_window_defers
test_noninteractive_override_is_source_only
test_quiet_window_probe_failures_defer
test_quiet_window_rechecks_after_consent
test_node_upgrade_uses_nvm
test_node_requires_active_nvm_provenance
test_firstmate_update_actions_are_consumed
test_mixed_checkout_majors_report_repository_update

echo "# all fm-deps tests passed"
