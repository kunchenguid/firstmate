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

create_firstmate_action_home() {
  local fixture=$1 id=$2 tag=${3:-$2} target
  target="$TMP_ROOT/${fixture##*/}-$tag"
  mkdir -p "$target/bin"
  printf '%s\n' "$id" > "$target/.fm-secondmate-home"
  printf 'instructions\n' > "$target/AGENTS.md"
  printf '#!/usr/bin/env bash\n' > "$target/bin/tool.sh"
  git -C "$target" init -q
  git -C "$target" config user.email test@example.com
  git -C "$target" config user.name Test
  git -C "$target" add AGENTS.md bin/tool.sh .fm-secondmate-home
  git -C "$target" commit -qm seed
  printf '%s\n' "$target"
}

register_firstmate_action_target() {
  local fixture=$1 id=$2 target=$3
  mkdir -p "$fixture/state" "$fixture/data"
  {
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$target"
  } > "$fixture/state/$id.meta"
}

prepare_firstmate_action_target() {
  local fixture=$1 id=$2 target
  target=$(create_firstmate_action_home "$fixture" "$id") || return 1
  register_firstmate_action_target "$fixture" "$id" "$target"
}

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

test_herdr_quiet_window_requires_session_schema() {
  local fakebin out payload status
  fakebin=$(fm_fakebin "$TMP_ROOT/herdr-schema")
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' "$FM_DEPS_TEST_HERDR_JSON"' \
    > "$fakebin/herdr"
  chmod +x "$fakebin/herdr"

  for payload in '{}' '[]' '{"sessions":[{}]}' \
    '{"sessions":[{"running":"false"}]}'; do
    out=$(PATH="$fakebin:$PATH" FM_DEPS_TEST_HERDR_JSON="$payload" \
      quiet_window_blocker herdr)
    status=$?
    [ "$status" -eq 2 ] || fail "invalid Herdr session schema was treated as idle: $payload"
    assert_contains "$out" "Herdr session inspection failed" \
      "invalid Herdr session schema did not fail closed"
  done
  out=$(PATH="$fakebin:$PATH" FM_DEPS_TEST_HERDR_JSON='{"sessions":[]}' \
    quiet_window_blocker herdr)
  status=$?
  [ "$status" -eq 1 ] || fail "valid empty Herdr sessions were not treated as idle: $out"
  pass "Herdr quiet windows require the expected sessions schema"
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
  local fixture log out confirmed_line send_line
  fixture="$TMP_ROOT/firstmate-update"
  log="$fixture/send.log"
  mkdir -p "$fixture/bin"
  prepare_firstmate_action_target "$fixture" one
  prepare_firstmate_action_target "$fixture" two
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''firstmate: updated old..new\n'\''' \
    'printf '\''reread-firstmate: yes\n'\''' \
    'printf '\''nudge-secondmates: fm-one fm-two\n'\''' > "$fixture/bin/fm-update.sh"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''%s|%s|%s\n'\'' "$FM_HOME" "$1" "$2" >> "$FM_DEPS_TEST_LOG"' \
    'printf '\''SEND:%s\n'\'' "$1"' \
    > "$fixture/bin/fm-send.sh"
  chmod +x "$fixture/bin/fm-update.sh" "$fixture/bin/fm-send.sh"

  out=$(FM_ROOT="$fixture" FM_HOME="$fixture" FM_DEPS_SOURCE_ONLY=1 \
    FM_DEPS_INTERACTIVE=1 CHECK_ONLY=0 FM_DEPS_TEST_LOG="$log" \
    run_upgrade firstmate <<<yes)
  assert_contains "$out" \
    "REREAD_REQUIRED: $fixture/AGENTS.md changed" \
    "Firstmate reread action was discarded"
  confirmed_line=$(printf '%s\n' "$out" | grep -n '^REREAD_CONFIRMED:' | cut -d: -f1)
  send_line=$(printf '%s\n' "$out" | grep -n '^SEND:fm-one$' | cut -d: -f1)
  if [ -z "$confirmed_line" ] || [ -z "$send_line" ] \
    || [ "$confirmed_line" -ge "$send_line" ]; then
    fail "secondmate nudge was not gated behind reread confirmation"
  fi
  assert_grep "$fixture|fm-one|$FM_SECOND_MATE_NUDGE_MESSAGE" "$log" \
    "first updated secondmate was not nudged"
  assert_grep "$fixture|fm-two|$FM_SECOND_MATE_NUDGE_MESSAGE" "$log" \
    "second updated secondmate was not nudged"
  pass "Firstmate post-update reread and nudge actions are consumed"
}

test_firstmate_secondmate_only_actions_are_preserved() {
  local fixture log out
  fixture="$TMP_ROOT/firstmate-secondmate-only"
  log="$fixture/send.log"
  mkdir -p "$fixture/bin"
  prepare_firstmate_action_target "$fixture" only
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''firstmate: already current\n'\''' \
    'printf '\''reread-firstmate: no\n'\''' \
    'printf '\''nudge-secondmates: fm-only\n'\''' > "$fixture/bin/fm-update.sh"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''%s|%s\n'\'' "$1" "$2" >> "$FM_DEPS_TEST_LOG"' \
    > "$fixture/bin/fm-send.sh"
  chmod +x "$fixture/bin/fm-update.sh" "$fixture/bin/fm-send.sh"

  out=$(FM_ROOT="$fixture" FM_HOME="$fixture" FM_DEPS_TEST_LOG="$log" \
    run_upgrade firstmate)
  assert_contains "$out" "nudge-secondmates: fm-only" \
    "secondmate-only updater action was discarded"
  assert_grep "fm-only|$FM_SECOND_MATE_NUDGE_MESSAGE" "$log" \
    "secondmate-only updater action was not performed"
  pass "secondmate-only Firstmate updater actions are preserved"
}

test_firstmate_concurrent_update_preserves_actions() {
  local fixture fakebin log out
  fixture="$TMP_ROOT/firstmate-concurrent"
  fakebin=$(fm_fakebin "$fixture")
  log="$fixture/send.log"
  mkdir -p "$fixture/bin"
  prepare_firstmate_action_target "$fixture" concurrent
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''firstmate: already current\n'\''' \
    'printf '\''reread-firstmate: yes\n'\''' \
    'printf '\''nudge-secondmates: fm-concurrent\n'\''' > "$fixture/bin/fm-update.sh"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''%s|%s\n'\'' "$1" "$2" >> "$FM_DEPS_TEST_LOG"' \
    > "$fixture/bin/fm-send.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'printf '\''same-head\n'\''' > "$fakebin/git"
  chmod +x "$fixture/bin/fm-update.sh" "$fixture/bin/fm-send.sh" "$fakebin/git"

  out=$(PATH="$fakebin:$PATH" FM_ROOT="$fixture" FM_HOME="$fixture" \
    FM_DEPS_SOURCE_ONLY=1 FM_DEPS_INTERACTIVE=1 CHECK_ONLY=0 \
    FM_DEPS_TEST_LOG="$log" run_upgrade firstmate <<<yes)
  assert_contains "$out" "REREAD_CONFIRMED: $fixture/AGENTS.md" \
    "concurrent update lost the reread action"
  assert_grep "fm-concurrent|$FM_SECOND_MATE_NUDGE_MESSAGE" "$log" \
    "concurrent update lost the secondmate nudge action"
  pass "concurrent Firstmate updates preserve every emitted action"
}

test_firstmate_action_publication_is_serialized() {
  local fixture events ready release started holder waiter holder_status waiter_status
  local entered_before_release=0 out i
  fixture="$TMP_ROOT/firstmate-action-serialization"
  events="$fixture/events.log"
  ready="$fixture/holder.ready"
  release="$fixture/holder.release"
  started="$fixture/waiter.started"
  mkdir -p "$fixture/bin"
  prepare_firstmate_action_target "$fixture" serialized
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''update\n'\'' >> "$FM_DEPS_TEST_EVENTS"' \
    'printf '\''firstmate: already current\n'\''' \
    'printf '\''reread-firstmate: no\n'\''' \
    'printf '\''nudge-secondmates: none\n'\''' > "$fixture/bin/fm-update.sh"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''send:%s\n'\'' "$1" >> "$FM_DEPS_TEST_EVENTS"' \
    > "$fixture/bin/fm-send.sh"
  chmod +x "$fixture/bin/fm-update.sh" "$fixture/bin/fm-send.sh"

  FM_ROOT_OVERRIDE="$fixture" FM_HOME="$fixture" FM_STATE_OVERRIDE="$fixture/state" \
    FM_DEPS_SOURCE_ONLY=1 FM_DEPS_TEST_EVENTS="$events" bash -c '
      deps=$1
      ready=$2
      release=$3
      set --
      . "$deps"
      hold_firstmate_publication() {
        persist_firstmate_update_actions no fm-serialized || return 1
        printf "published\n" >> "$FM_DEPS_TEST_EVENTS"
        : > "$ready"
        while [ ! -e "$release" ]; do
          sleep 0.02
        done
      }
      with_firstmate_action_lock hold_firstmate_publication
    ' _ "$DEPS" "$ready" "$release" &
  holder=$!
  for ((i = 0; i < 100; i++)); do
    [ -e "$ready" ] && break
    kill -0 "$holder" 2>/dev/null || break
    sleep 0.02
  done
  if [ ! -e "$ready" ]; then
    wait "$holder" 2>/dev/null || true
    fail "Firstmate action serialization holder did not publish its inventory"
  fi

  FM_ROOT_OVERRIDE="$fixture" FM_HOME="$fixture" FM_STATE_OVERRIDE="$fixture/state" \
    FM_DEPS_SOURCE_ONLY=1 FM_DEPS_TEST_EVENTS="$events" bash -c '
      deps=$1
      started=$2
      set --
      . "$deps"
      : > "$started"
      run_upgrade firstmate
    ' _ "$DEPS" "$started" > "$fixture/waiter.out" 2>&1 &
  waiter=$!
  for ((i = 0; i < 100; i++)); do
    [ -e "$started" ] && break
    kill -0 "$waiter" 2>/dev/null || break
    sleep 0.02
  done
  for ((i = 0; i < 50; i++)); do
    if grep -Eq '^(send:|update$)' "$events" 2>/dev/null; then
      entered_before_release=1
      break
    fi
    sleep 0.02
  done
  printf 'release\n' >> "$events"
  : > "$release"
  wait "$holder"
  holder_status=$?
  wait "$waiter"
  waiter_status=$?
  out=$(< "$events")

  [ "$holder_status" -eq 0 ] || fail "Firstmate action serialization holder failed"
  [ "$waiter_status" -eq 0 ] \
    || fail "serialized Firstmate updater failed: $(< "$fixture/waiter.out")"
  [ "$entered_before_release" -eq 0 ] \
    || fail "a concurrent Firstmate updater entered before publication completed"
  [ "$out" = $'published\nrelease\nsend:fm-serialized\nupdate' ] \
    || fail "serialized Firstmate actions ran out of order: $out"
  assert_absent "$fixture/state/.fm-deps-pending/firstmate-actions.pending" \
    "serialized Firstmate update retained a completed action inventory"
  pass "Firstmate action publication is serialized per home"
}

test_dependency_check_lock_is_run_wide_and_bounded() {
  local fixture primary secondmate host_lock ready release events holder holder_status
  local out status started elapsed i
  fixture="$TMP_ROOT/dependency-check-run-lock"
  primary="$fixture/primary"
  secondmate="$fixture/secondmate"
  host_lock="$fixture/host-lock"
  ready="$fixture/holder.ready"
  release="$fixture/holder.release"
  events="$fixture/events.log"
  mkdir -p "$primary/state" "$secondmate/state"

  # shellcheck disable=SC2016
  FM_ROOT_OVERRIDE="$primary" FM_HOME="$primary" FM_STATE_OVERRIDE="$primary/state" \
    FM_DEPS_HOST_LOCK_DIR="$host_lock" FM_DEPS_SOURCE_ONLY=1 \
    FM_DEPS_INTERACTIVE=0 FM_DEPS_LOCK_TIMEOUT=3 bash -c '
      deps=$1
      ready=$2
      release=$3
      set --
      . "$deps"
      check_release_tool() {
        if [ ! -e "$ready" ]; then
          : > "$ready"
          while [ ! -e "$release" ]; do
            sleep 0.02
          done
        fi
      }
      check_apt_package() { :; }
      check_npm_tool() { :; }
      check_herdr() { :; }
      check_node() { :; }
      check_zellij() { :; }
      check_shellcheck_pin() { :; }
      check_github_actions() { :; }
      check_firstmate() { :; }
      run_dependency_check
    ' _ "$DEPS" "$ready" "$release" > "$fixture/holder.out" 2>&1 &
  holder=$!
  for ((i = 0; i < 100; i++)); do
    [ -e "$ready" ] && break
    kill -0 "$holder" 2>/dev/null || break
    sleep 0.02
  done
  if [ ! -e "$ready" ]; then
    wait "$holder" 2>/dev/null || true
    fail "run-wide dependency checker owner did not reach its first check"
  fi

  started=$(date +%s)
  # shellcheck disable=SC2016
  out=$(FM_ROOT_OVERRIDE="$secondmate" FM_HOME="$secondmate" \
    FM_STATE_OVERRIDE="$secondmate/state" FM_DEPS_HOST_LOCK_DIR="$host_lock" \
    FM_DEPS_SOURCE_ONLY=1 FM_DEPS_INTERACTIVE=0 FM_DEPS_LOCK_TIMEOUT=1 \
    FM_DEPS_TEST_EVENTS="$events" \
    bash -c '
      deps=$1
      set --
      . "$deps"
      check_release_tool() { printf "entered\n" >> "$FM_DEPS_TEST_EVENTS"; }
      check_apt_package() { :; }
      check_npm_tool() { :; }
      check_herdr() { :; }
      check_node() { :; }
      check_zellij() { :; }
      check_shellcheck_pin() { :; }
      check_github_actions() { :; }
      check_firstmate() { :; }
      run_dependency_check
    ' _ "$DEPS" 2>&1)
  status=$?
  elapsed=$(( $(date +%s) - started ))
  : > "$release"
  wait "$holder"
  holder_status=$?

  [ "$holder_status" -eq 0 ] || fail "run-wide dependency checker owner failed"
  [ "$status" -eq 0 ] || fail "busy dependency check did not return a deferred result: $out"
  [ "$elapsed" -le 4 ] || fail "busy dependency check exceeded its ownership bound"
  assert_contains "$out" \
    "DEFER: dependency check - another invocation is still running; retry later" \
    "busy dependency check did not report its deferred result"
  assert_contains "$out" \
    "SUMMARY: 0 update(s) available; 0 completed; 1 deferred; 0 check/upgrade failure(s)" \
    "busy dependency check did not produce a deferred summary"
  assert_absent "$events" "concurrent dependency check entered an upgrade-capable check"
  pass "dependency checker ownership is host-wide and bounded"
}

test_direct_checker_reexecutes_under_host_lock() {
  local fixture host_lock bash_env count_file observation out status
  fixture="$TMP_ROOT/dependency-check-reexec"
  host_lock="$fixture/host-lock"
  bash_env="$fixture/bash-env"
  count_file="$fixture/bash-count"
  observation="$fixture/reexec-lock"
  mkdir -p "$fixture/state"
  printf 'invalid\n' > "$fixture/state/.fm-deps-pending"
  printf '%s\n' \
    'count=0' \
    'if [ -f "$FM_DEPS_TEST_BASH_COUNT" ]; then read -r count < "$FM_DEPS_TEST_BASH_COUNT"; fi' \
    'count=$((count + 1))' \
    'printf "%s\n" "$count" > "$FM_DEPS_TEST_BASH_COUNT"' \
    'if [ "$count" -eq 2 ]; then' \
    '  owner=$(readlink "$FM_DEPS_HOST_LOCK_DIR/fm-deps.lock" 2>/dev/null || true)' \
    '  if [ -n "$owner" ] && [ "$(< "$owner/pid")" = "${BASHPID:-$$}" ]; then' \
    '    printf "locked\n" > "$FM_DEPS_TEST_REEXEC_LOCK"' \
    '  else' \
    '    printf "unlocked\n" > "$FM_DEPS_TEST_REEXEC_LOCK"' \
    '  fi' \
    'fi' > "$bash_env"

  out=$(BASH_ENV="$bash_env" FM_DEPS_TEST_BASH_COUNT="$count_file" \
    FM_DEPS_TEST_REEXEC_LOCK="$observation" FM_DEPS_HOST_LOCK_DIR="$host_lock" \
    FM_ROOT_OVERRIDE="$fixture" FM_HOME="$fixture" FM_STATE_OVERRIDE="$fixture/state" \
    bash "$DEPS" --check 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "direct checker accepted invalid pending action storage: $out"
  [ "$(< "$count_file")" = 2 ] || fail "direct checker did not re-exec exactly once"
  [ "$(< "$observation")" = locked ] || fail "checker re-exec did not inherit host lock ownership"
  assert_contains "$out" "Firstmate pending action directory is invalid" \
    "re-executed checker did not process pending action storage"
  assert_absent "$host_lock/fm-deps.lock" "re-executed checker retained the host lock"
  pass "direct checker re-executes while retaining host lock ownership"
}

test_invalid_pending_action_directory_stops_run() {
  local kind fixture events out status
  for kind in symlink file; do
    fixture="$TMP_ROOT/invalid-pending-$kind"
    events="$fixture/events.log"
    mkdir -p "$fixture/state"
    if [ "$kind" = symlink ]; then
      ln -s missing "$fixture/state/.fm-deps-pending"
    else
      printf 'invalid\n' > "$fixture/state/.fm-deps-pending"
    fi

    # shellcheck disable=SC2016
    out=$(FM_ROOT_OVERRIDE="$fixture" FM_HOME="$fixture" \
      FM_STATE_OVERRIDE="$fixture/state" FM_DEPS_HOST_LOCK_DIR="$fixture/host-lock" \
      FM_DEPS_SOURCE_ONLY=1 \
      FM_DEPS_INTERACTIVE=0 FM_DEPS_TEST_EVENTS="$events" bash -c '
        deps=$1
        set --
        . "$deps"
        check_release_tool() { printf "entered\n" >> "$FM_DEPS_TEST_EVENTS"; }
        check_apt_package() { :; }
        check_npm_tool() { :; }
        check_herdr() { :; }
        check_node() { :; }
        check_zellij() { :; }
        check_shellcheck_pin() { :; }
        check_github_actions() { :; }
        check_firstmate() { :; }
        run_dependency_check
      ' _ "$DEPS" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$kind pending action directory was accepted: $out"
    assert_contains "$out" "Firstmate pending action directory is invalid" \
      "$kind pending action directory was not diagnosed"
    assert_contains "$out" "FAILED: Firstmate pending action storage is invalid" \
      "$kind pending action directory did not stop the dependency check"
    assert_absent "$events" "$kind pending action directory allowed later checks"
  done
  pass "invalid pending action directories stop dependency checks"
}

test_firstmate_actions_are_durable_and_retry_every_target() {
  local fixture log out status pending nudge one_home one_commit replacement before after
  local manifest_contents
  fixture="$TMP_ROOT/firstmate-durable-actions"
  log="$fixture/send.log"
  pending="$fixture/state/.fm-deps-pending"
  nudge="$fixture/state/.secondmate-nudge-pending"
  mkdir -p "$fixture/bin"
  one_home=$(create_firstmate_action_home "$fixture" one)
  register_firstmate_action_target "$fixture" one "$one_home"
  prepare_firstmate_action_target "$fixture" two
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''firstmate: updated old..new\n'\''' \
    'printf '\''reread-firstmate: yes\n'\''' \
    'printf '\''nudge-secondmates: fm-one fm-two\n'\''' > "$fixture/bin/fm-update.sh"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''%s\n'\'' "$1" >> "$FM_DEPS_TEST_LOG"' \
    '[ "$1" != "${FM_DEPS_TEST_FAIL_SELECTOR:-}" ]' > "$fixture/bin/fm-send.sh"
  chmod +x "$fixture/bin/fm-update.sh" "$fixture/bin/fm-send.sh"

  out=$(FM_ROOT="$fixture" FM_HOME="$fixture" FM_DEPS_SOURCE_ONLY=1 \
    FM_DEPS_INTERACTIVE=1 CHECK_ONLY=0 FM_DEPS_TEST_LOG="$log" \
    run_upgrade firstmate <<<no 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "declined reread completed Firstmate post-update actions: $out"
  assert_present "$pending/firstmate-actions.pending" \
    "declined reread left no durable action inventory"
  assert_grep "targets=fm-one fm-two" "$pending/firstmate-actions.pending" \
    "durable action inventory omitted an updated secondmate"
  one_commit=$(git -C "$one_home" rev-parse HEAD)
  manifest_contents=$(< "$pending/firstmate-actions.pending")
  assert_contains "$manifest_contents" "target.one.home=$one_home" \
    "durable action inventory omitted the original secondmate home"
  assert_contains "$manifest_contents" "target.one.commit=$one_commit" \
    "durable action inventory omitted the original instruction commit"
  assert_absent "$nudge/one.pending" \
    "secondmate identity was recorded before reread confirmation"
  assert_absent "$log" "secondmates were nudged before reread confirmation"

  replacement=$(create_firstmate_action_home "$fixture" one replacement)
  register_firstmate_action_target "$fixture" one "$replacement"
  out=$(FM_ROOT="$fixture" FM_HOME="$fixture" FM_DEPS_SOURCE_ONLY=1 \
    FM_DEPS_INTERACTIVE=1 CHECK_ONLY=0 FM_DEPS_TEST_LOG="$log" \
    process_pending_firstmate_actions <<<yes 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "reassigned target completed pending actions: $out"
  assert_not_contains "$(< "$log")" "fm-one" \
    "pending action was rebound to the replacement secondmate"
  assert_grep "fm-two" "$log" "later pending secondmate was skipped after a failure"
  assert_grep "targets=fm-one" "$pending/firstmate-actions.pending" \
    "identity mismatch lost its target from the durable action inventory"
  manifest_contents=$(< "$pending/firstmate-actions.pending")
  assert_contains "$manifest_contents" "target.one.home=$one_home" \
    "identity mismatch rewrote the action to the replacement home"
  assert_absent "$nudge/two.pending" \
    "successful later secondmate nudge retained its retry marker"

  register_firstmate_action_target "$fixture" one "$one_home"
  mkdir -p "$nudge/one.pending"
  out=$(FM_ROOT="$fixture" FM_HOME="$fixture" FM_DEPS_SOURCE_ONLY=1 \
    FM_DEPS_INTERACTIVE=1 CHECK_ONLY=0 FM_DEPS_TEST_LOG="$log" \
    process_pending_firstmate_actions 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "corrupt first marker completed pending actions: $out"
  assert_grep "targets=fm-one" "$pending/firstmate-actions.pending" \
    "failed marker lost its target from the durable action inventory"

  rmdir "$nudge/one.pending"
  out=$(FM_ROOT="$fixture" FM_HOME="$fixture" FM_DEPS_SOURCE_ONLY=1 \
    FM_DEPS_INTERACTIVE=1 CHECK_ONLY=0 FM_DEPS_TEST_LOG="$log" \
    FM_DEPS_TEST_FAIL_SELECTOR=fm-one process_pending_firstmate_actions 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "failed remaining nudge completed pending actions: $out"
  assert_present "$nudge/one.pending" \
    "failed remaining nudge lost its identity-bound retry marker"
  assert_absent "$pending/firstmate-actions.pending" \
    "fully identity-bound inventory was not retired"

  before=$(wc -l < "$log")
  register_firstmate_action_target "$fixture" one "$replacement"
  out=$(FM_ROOT="$fixture" FM_HOME="$fixture" FM_DEPS_SOURCE_ONLY=1 \
    FM_DEPS_INTERACTIVE=1 CHECK_ONLY=0 FM_DEPS_TEST_LOG="$log" \
    process_pending_firstmate_actions 2>&1)
  status=$?
  after=$(wc -l < "$log")
  [ "$status" -ne 0 ] || fail "reassigned selector accepted a stale nudge identity: $out"
  [ "$after" -eq "$before" ] || fail "stale nudge was delivered to a reassigned selector"
  assert_present "$nudge/one.pending" \
    "identity mismatch discarded the original pending nudge"
  pass "Firstmate actions persist completely and bind retry identity"
}

test_remote_secondmate_actions_use_shared_retry_markers() {
  local fixture log marker startup_marker startup_home startup_commit out status
  fixture="$TMP_ROOT/firstmate-remote-action"
  log="$fixture/send.log"
  marker="$fixture/state/.secondmate-nudge-pending/remote.pending"
  startup_marker="$fixture/state/.secondmate-nudge-pending/startup.pending"
  mkdir -p "$fixture/bin" "$fixture/state" "$fixture/data"
  {
    printf 'kind=secondmate\n'
    printf 'home=/srv/firstmate-remote\n'
    printf 'remote_host=remote.example\n'
  } > "$fixture/state/remote.meta"
  startup_home=$(create_firstmate_action_home "$fixture" startup)
  register_firstmate_action_target "$fixture" startup "$startup_home"
  startup_commit=$(git -C "$startup_home" rev-parse HEAD)
  fm_secondmate_nudge_write "$fixture/state" startup "$startup_home" "$startup_commit" \
    AGENTS.md "$FM_SECOND_MATE_NUDGE_MESSAGE" 0
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''%s|%s\n'\'' "$1" "$2" >> "$FM_DEPS_TEST_LOG"' \
    '[ "${FM_DEPS_TEST_SEND_FAIL:-0}" -eq 0 ]' > "$fixture/bin/fm-send.sh"
  chmod +x "$fixture/bin/fm-send.sh"

  FM_ROOT="$fixture" FM_HOME="$fixture" persist_firstmate_update_actions no fm-remote
  assert_grep "target.remote.remote-host=remote.example" \
    "$fixture/state/.fm-deps-pending/firstmate-actions.pending" \
    "remote action inventory omitted its original placement"
  {
    printf 'kind=secondmate\n'
    printf 'home=/srv/firstmate-remote\n'
    printf 'remote_host=replacement.example\n'
  } > "$fixture/state/remote.meta"
  out=$(FM_ROOT="$fixture" FM_HOME="$fixture" FM_DEPS_TEST_LOG="$log" \
    process_pending_firstmate_actions 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "remote placement change rebound the pending action"
  assert_absent "$log" "remote placement change delivered the pending action"
  assert_present "$fixture/state/.fm-deps-pending/firstmate-actions.pending" \
    "remote placement change discarded the original action inventory"
  {
    printf 'kind=secondmate\n'
    printf 'home=/srv/firstmate-remote\n'
    printf 'remote_host=remote.example\n'
  } > "$fixture/state/remote.meta"
  out=$(FM_ROOT="$fixture" FM_HOME="$fixture" FM_DEPS_TEST_LOG="$log" \
    FM_DEPS_TEST_SEND_FAIL=1 process_pending_firstmate_actions 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "failed remote nudge completed pending actions"
  assert_contains "$out" "Firstmate post-update nudge failed for fm-remote" \
    "failed remote nudge was not reported"
  assert_present "$marker" "failed remote nudge left no shared retry marker"
  assert_grep "owner=fm-deps" "$marker" \
    "dependency-checker retry marker lost its owner"
  assert_grep "remote=1" "$marker" "remote retry marker lost its placement identity"
  assert_grep "remote_host=remote.example" "$marker" \
    "remote retry marker lost its host identity"
  assert_grep "home=/srv/firstmate-remote" "$marker" \
    "remote retry marker lost its home identity"

  FM_ROOT="$fixture" FM_HOME="$fixture" FM_DEPS_TEST_LOG="$log" \
    process_pending_firstmate_actions
  assert_absent "$marker" "successful remote nudge retained its shared retry marker"
  assert_present "$startup_marker" \
    "dependency checker consumed a retry marker owned by startup"
  assert_not_contains "$(< "$log")" "fm-startup" \
    "dependency checker delivered a retry marker owned by startup"
  assert_grep "fm-remote|$FM_REMOTE_SECOND_MATE_NUDGE_MESSAGE" "$log" \
    "remote secondmate did not receive the shared reread message"
  pass "remote secondmate actions use the shared retry path"
}

test_nudge_delivery_preserves_concurrent_replacement() {
  local fixture log marker claim home commit
  fixture="$TMP_ROOT/firstmate-nudge-replacement"
  log="$fixture/send.log"
  marker="$fixture/state/.secondmate-nudge-pending/race.pending"
  claim="$fixture/state/.fm-deps-pending/secondmate-nudge-race.claimed"
  mkdir -p "$fixture/bin"
  home=$(create_firstmate_action_home "$fixture" race)
  register_firstmate_action_target "$fixture" race "$home"
  commit=$(git -C "$home" rev-parse HEAD)
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''%s\n'\'' "$1" >> "$FM_DEPS_TEST_LOG"' \
    'tmp="$FM_DEPS_TEST_MARKER.replacement"' \
    'printf '\''%s\n'\'' '\''id=race'\'' '\''selector=fm-race'\'' \' \
    '  "home=$FM_DEPS_TEST_HOME" "commit=$FM_DEPS_TEST_COMMIT" \' \
    '  '\''instructions=AGENTS.md'\'' "message=$FM_DEPS_TEST_MESSAGE" \' \
    '  '\''remote=0'\'' '\''owner=startup'\'' > "$tmp"' \
    'mv -f -- "$tmp" "$FM_DEPS_TEST_MARKER"' > "$fixture/bin/fm-send.sh"
  chmod +x "$fixture/bin/fm-send.sh"

  FM_ROOT="$fixture" FM_HOME="$fixture" persist_firstmate_update_actions no fm-race
  FM_ROOT="$fixture" FM_HOME="$fixture" FM_DEPS_TEST_LOG="$log" \
    FM_DEPS_TEST_MARKER="$marker" FM_DEPS_TEST_HOME="$home" \
    FM_DEPS_TEST_COMMIT="$commit" FM_DEPS_TEST_MESSAGE="$FM_SECOND_MATE_NUDGE_MESSAGE" \
    process_pending_firstmate_actions
  assert_present "$marker" "successful delivery erased a concurrent replacement action"
  assert_grep "owner=startup" "$marker" \
    "successful delivery retained the consumed action instead of its replacement"
  assert_absent "$claim" "successful delivery retained its immutable claim"
  assert_grep "fm-race" "$log" "race fixture did not deliver the claimed action"
  pass "nudge delivery preserves concurrent retry replacements"
}

test_npm_upgrade_pins_version_and_retries_hooks() {
  local fixture fakebin npm_log hook_log marker out status
  fixture="$TMP_ROOT/npm-hook-retry"
  fakebin=$(fm_fakebin "$fixture")
  npm_log="$fixture/npm.log"
  hook_log="$fixture/hooks.log"
  marker="$fixture/state/.fm-deps-pending/npm-hooks-gh-axi.pending"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$1" in' \
    '  install) printf '\''%s\n'\'' "$*" >> "$FM_DEPS_TEST_NPM_LOG" ;;' \
    '  view) printf '\''1.2.3\n'\'' ;;' \
    '  *) exit 1 ;;' \
    'esac' > "$fakebin/npm"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$1" in' \
    '  --version) printf '\''gh-axi 1.2.3\n'\'' ;;' \
    '  setup)' \
    '    printf '\''%s\n'\'' "$*" >> "$FM_DEPS_TEST_HOOK_LOG"' \
    '    [ "${FM_DEPS_TEST_HOOK_FAIL:-0}" -eq 0 ]' \
    '    ;;' \
    '  *) exit 1 ;;' \
    'esac' > "$fakebin/gh-axi"
  chmod +x "$fakebin/npm" "$fakebin/gh-axi"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$fixture/state" \
    FM_DEPS_TEST_NPM_LOG="$npm_log" FM_DEPS_TEST_HOOK_LOG="$hook_log" \
    FM_DEPS_TEST_HOOK_FAIL=1 run_upgrade gh-axi 1.0.0 1.2.3 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "failed hook setup completed the npm upgrade"
  assert_grep "install -g gh-axi@1.2.3" "$npm_log" \
    "npm upgrade did not install the approved version"
  assert_present "$marker" "failed hook setup left no durable retry action"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$fixture/state" \
    FM_DEPS_SOURCE_ONLY=1 FM_DEPS_INTERACTIVE=1 CHECK_ONLY=0 \
    FM_DEPS_TEST_NPM_LOG="$npm_log" FM_DEPS_TEST_HOOK_LOG="$hook_log" \
    check_npm_tool gh-axi gh-axi gh-axi <<<yes 2>&1)
  assert_contains "$out" "COMPLETED: gh-axi hook setup" \
    "later dependency check did not retry pending hook setup"
  assert_absent "$marker" "successful hook retry retained its pending action"
  pass "npm upgrades pin approved versions and retry hook setup"
}

test_pending_npm_hooks_supersede_changed_active_version() {
  local fixture fakebin hook_log marker out status version
  fixture="$TMP_ROOT/npm-hook-supersede"
  fakebin=$(fm_fakebin "$fixture")
  hook_log="$fixture/hooks.log"
  marker="$fixture/state/.fm-deps-pending/npm-hooks-gh-axi.pending"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$1" in' \
    '  view) printf '\''%s\n'\'' "$FM_DEPS_TEST_LATEST" ;;' \
    '  *) exit 1 ;;' \
    'esac' > "$fakebin/npm"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$1" in' \
    '  --version) printf '\''gh-axi %s\n'\'' "$FM_DEPS_TEST_TOOL_VERSION" ;;' \
    '  setup)' \
    '    printf '\''%s\n'\'' "$*" >> "$FM_DEPS_TEST_HOOK_LOG"' \
    '    [ "${FM_DEPS_TEST_HOOK_FAIL:-0}" -eq 0 ]' \
    '    ;;' \
    '  *) exit 1 ;;' \
    'esac' > "$fakebin/gh-axi"
  chmod +x "$fakebin/npm" "$fakebin/gh-axi"

  FM_STATE_OVERRIDE="$fixture/state" persist_npm_hook_action gh-axi 1.2.3
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$fixture/state" \
    FM_DEPS_SOURCE_ONLY=1 FM_DEPS_INTERACTIVE=1 CHECK_ONLY=0 \
    FM_DEPS_TEST_LATEST=1.3.0 FM_DEPS_TEST_TOOL_VERSION=1.3.0 \
    FM_DEPS_TEST_HOOK_LOG="$hook_log" FM_DEPS_TEST_HOOK_FAIL=1 \
    check_npm_tool gh-axi gh-axi gh-axi <<<yes 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "failed superseding hook check did not finish its report: $out"
  assert_contains "$out" "superseded by active approved version 1.3.0" \
    "changed active version did not supersede the stale hook action"
  version=$(pending_marker_value "$marker" version)
  [ "$version" = 1.3.0 ] || fail "failed hook retry retained stale version $version"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$fixture/state" \
    FM_DEPS_SOURCE_ONLY=1 FM_DEPS_INTERACTIVE=1 CHECK_ONLY=0 \
    FM_DEPS_TEST_LATEST=1.3.0 FM_DEPS_TEST_TOOL_VERSION=1.3.0 \
    FM_DEPS_TEST_HOOK_LOG="$hook_log" check_npm_tool gh-axi gh-axi gh-axi <<<yes 2>&1)
  assert_contains "$out" "COMPLETED: gh-axi hook setup" \
    "superseded hook action was not recoverable on the next run"
  assert_absent "$marker" "successful superseded hook retry retained its marker"
  pass "pending npm hooks safely follow an approved active version"
}

test_npm_upgrade_rejects_active_version_mismatch() {
  local fixture fakebin npm_log out status
  fixture="$TMP_ROOT/npm-version-mismatch"
  fakebin=$(fm_fakebin "$fixture")
  npm_log="$fixture/npm.log"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''%s\n'\'' "$*" >> "$FM_DEPS_TEST_NPM_LOG"' > "$fakebin/npm"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''tasks-axi 1.2.2\n'\''' > "$fakebin/tasks-axi"
  chmod +x "$fakebin/npm" "$fakebin/tasks-axi"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$fixture/state" \
    FM_DEPS_TEST_NPM_LOG="$npm_log" run_upgrade tasks-axi 1.0.0 1.2.3 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "mismatched active npm executable was accepted"
  assert_grep "install -g tasks-axi@1.2.3" "$npm_log" \
    "npm mismatch case did not install the approved version"
  assert_contains "$out" "resolved to 1.2.2 instead of approved version 1.2.3" \
    "active npm executable mismatch was not reported"
  pass "npm upgrades verify the active executable version"
}

test_dependency_probes_are_bounded_and_git_is_noninteractive() {
  local fixture fakebin out status started elapsed
  fixture="$TMP_ROOT/bounded-probes"
  fakebin=$(fm_fakebin "$fixture")
  printf '%s\n' '#!/usr/bin/env bash' 'sleep 5' > "$fakebin/npm"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    '[ "${GIT_TERMINAL_PROMPT:-}" = 0 ] || exit 9' \
    'printf '\''remote-sha\n'\''' > "$fakebin/git"
  chmod +x "$fakebin/npm" "$fakebin/git"

  started=$(date +%s)
  out=$(PATH="$fakebin:$PATH" FM_DEPS_PROBE_TIMEOUT=1 npm_latest example 2>&1)
  status=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -ne 0 ] || fail "hung npm probe was treated as successful: $out"
  [ "$elapsed" -le 3 ] || fail "npm probe exceeded its configured bound"
  out=$(PATH="$fakebin:$PATH" FM_DEPS_PROBE_TIMEOUT=1 \
    run_git_probe ls-remote origin refs/heads/main)
  [ "$out" = remote-sha ] || fail "Git probe allowed an interactive credential path"
  pass "dependency probes are bounded and Git credentials stay non-interactive"
}

test_zero_padded_probe_timeout_is_rejected() {
  local fixture out status
  fixture="$TMP_ROOT/zero-probe-timeout"
  mkdir -p "$fixture"
  out=$(FM_DEPS_PROBE_TIMEOUT=00 FM_ROOT_OVERRIDE="$fixture" \
    bash "$DEPS" --check 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "zero-padded zero disabled the probe deadline"
  assert_contains "$out" "FM_DEPS_PROBE_TIMEOUT must be a positive integer" \
    "zero-padded zero timeout was not rejected before probing"
  pass "probe timeout rejects every all-zero spelling"
}

test_unread_instructions_stop_dependency_mutations() {
  local fixture fakebin log out status
  fixture="$TMP_ROOT/unread-instructions"
  fakebin=$(fm_fakebin "$fixture")
  log="$fixture/probes.log"
  mkdir -p "$fixture/state/.fm-deps-pending" "$fixture/bin"
  printf '%s\n' 'action=firstmate-update' 'reread=invalid' 'targets=none' \
    > "$fixture/state/.fm-deps-pending/firstmate-actions.pending"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''called\n'\'' >> "$FM_DEPS_TEST_PROBE_LOG"' > "$fakebin/codex"
  chmod +x "$fakebin/codex"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" \
    FM_STATE_OVERRIDE="$fixture/state" FM_DEPS_SOURCE_ONLY=0 \
    FM_DEPS_HOST_LOCK_DIR="$fixture/host-lock" FM_DEPS_TEST_PROBE_LOG="$log" \
    bash "$DEPS" --check 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "invalid pending reread allowed the checker to continue"
  assert_contains "$out" "required Firstmate instruction reread remains incomplete" \
    "blocked mutation path did not report the unread instructions"
  assert_absent "$log" "dependency probes ran before the required reread cleared"
  pass "required instruction rereads stop later dependency mutations"
}

run_firstmate_outcome_case() {
  local fixture=$1 status=$2 nudge=$3 fakebin out_file selector
  fakebin=$(fm_fakebin "$fixture")
  out_file="$fixture/output"
  mkdir -p "$fixture/bin"
  if [ "$nudge" != none ]; then
    for selector in $nudge; do
      prepare_firstmate_action_target "$fixture" "${selector#fm-}"
    done
  fi
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''firstmate: %s\n'\'' "$FM_DEPS_TEST_FIRSTMATE_STATUS"' \
    'printf '\''reread-firstmate: no\n'\''' \
    'printf '\''nudge-secondmates: %s\n'\'' "$FM_DEPS_TEST_FIRSTMATE_NUDGE"' \
    > "$fixture/bin/fm-update.sh"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''%s|%s\n'\'' "$1" "$2" >> "$FM_DEPS_TEST_LOG"' \
    > "$fixture/bin/fm-send.sh"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  *"symbolic-ref --short refs/remotes/origin/HEAD"*) printf '\''origin/main\n'\'' ;;' \
    '  *"rev-parse HEAD"*) printf '\''local-sha\n'\'' ;;' \
    '  *"ls-remote origin refs/heads/main"*) printf '\''remote-sha\trefs/heads/main\n'\'' ;;' \
    '  *"status --porcelain"*) ;;' \
    '  *"symbolic-ref --short HEAD"*) printf '\''main\n'\'' ;;' \
    '  *) exit 1 ;;' \
    'esac' > "$fakebin/git"
  chmod +x "$fixture/bin/fm-update.sh" "$fixture/bin/fm-send.sh" "$fakebin/git"

  AVAILABLE=0 UPDATES=0 FAILURES=0 DEFERRED=0
  PATH="$fakebin:$PATH" FM_ROOT="$fixture" FM_HOME="$fixture" \
    FM_DEPS_SOURCE_ONLY=1 FM_DEPS_INTERACTIVE=1 CHECK_ONLY=0 \
    FM_DEPS_TEST_FIRSTMATE_STATUS="$status" FM_DEPS_TEST_FIRSTMATE_NUDGE="$nudge" \
    FM_DEPS_TEST_LOG="$fixture/send.log" check_firstmate <<<yes > "$out_file" 2>&1
  FIRSTMATE_OUTCOME_OUTPUT=$(< "$out_file")
}

test_firstmate_updated_outcome_counts_upgrade() {
  run_firstmate_outcome_case "$TMP_ROOT/firstmate-outcome-updated" 'updated old..new' none
  assert_contains "$FIRSTMATE_OUTCOME_OUTPUT" "UPGRADED: Firstmate" \
    "updated Firstmate outcome was not reported as upgraded"
  [ "$UPDATES" -eq 1 ] || fail "updated Firstmate outcome was not counted"
  [ "$FAILURES" -eq 0 ] || fail "updated Firstmate outcome was counted as failed"
  pass "updated Firstmate outcomes count one completed upgrade"
}

test_firstmate_current_outcome_is_success_without_upgrade() {
  run_firstmate_outcome_case "$TMP_ROOT/firstmate-outcome-current" 'already current' none
  assert_contains "$FIRSTMATE_OUTCOME_OUTPUT" \
    "CURRENT: Firstmate became current before the guarded update completed" \
    "concurrent already-current outcome was not accepted"
  assert_not_contains "$FIRSTMATE_OUTCOME_OUTPUT" "UPGRADED: Firstmate" \
    "concurrent already-current outcome was reported as upgraded"
  [ "$UPDATES" -eq 0 ] || fail "concurrent already-current outcome was counted as upgraded"
  [ "$AVAILABLE" -eq 0 ] || fail "concurrent already-current outcome remained available"
  [ "$FAILURES" -eq 0 ] || fail "concurrent already-current outcome was counted as failed"
  pass "already-current Firstmate outcomes complete without upgrade counts"
}

test_firstmate_skipped_outcome_fails_without_upgrade() {
  local fixture="$TMP_ROOT/firstmate-outcome-skipped"
  run_firstmate_outcome_case "$fixture" 'skipped: fetch failed' fm-skipped
  assert_contains "$FIRSTMATE_OUTCOME_OUTPUT" "firstmate: skipped: fetch failed" \
    "guarded skip reason was not retained"
  assert_contains "$FIRSTMATE_OUTCOME_OUTPUT" \
    "FAILED: Firstmate guarded update failed or was skipped" \
    "guarded skipped outcome was not reported as failed"
  assert_not_contains "$FIRSTMATE_OUTCOME_OUTPUT" "UPGRADED: Firstmate" \
    "guarded skipped outcome was reported as upgraded"
  assert_grep "fm-skipped|$FM_SECOND_MATE_NUDGE_MESSAGE" "$fixture/send.log" \
    "guarded skipped outcome discarded a secondmate action"
  [ "$UPDATES" -eq 0 ] || fail "guarded skipped outcome was counted as upgraded"
  [ "$FAILURES" -eq 1 ] || fail "guarded skipped outcome was not counted as failed"
  pass "skipped Firstmate outcomes fail without losing emitted actions"
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
test_herdr_quiet_window_requires_session_schema
test_quiet_window_rechecks_after_consent
test_node_upgrade_uses_nvm
test_node_requires_active_nvm_provenance
test_firstmate_update_actions_are_consumed
test_firstmate_secondmate_only_actions_are_preserved
test_firstmate_concurrent_update_preserves_actions
test_firstmate_action_publication_is_serialized
test_dependency_check_lock_is_run_wide_and_bounded
test_direct_checker_reexecutes_under_host_lock
test_invalid_pending_action_directory_stops_run
test_firstmate_actions_are_durable_and_retry_every_target
test_remote_secondmate_actions_use_shared_retry_markers
test_nudge_delivery_preserves_concurrent_replacement
test_firstmate_updated_outcome_counts_upgrade
test_firstmate_current_outcome_is_success_without_upgrade
test_firstmate_skipped_outcome_fails_without_upgrade
test_npm_upgrade_pins_version_and_retries_hooks
test_pending_npm_hooks_supersede_changed_active_version
test_npm_upgrade_rejects_active_version_mismatch
test_dependency_probes_are_bounded_and_git_is_noninteractive
test_zero_padded_probe_timeout_is_rejected
test_unread_instructions_stop_dependency_mutations
test_mixed_checkout_majors_report_repository_update

echo "# all fm-deps tests passed"
