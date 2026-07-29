#!/usr/bin/env bash
# Regression tests for Firstmate's shared Chrome DevTools AXI worker boundary.
# Covers home/task session isolation, the documented safe-name contract,
# root-only argument repair, launch-time environment publication, and exact
# metadata binding without invoking a real browser.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-chrome-axi-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-chrome-axi)
TASK_TMP=/tmp/fm-chrome-launch-r5
trap 'rm -rf "$TMP_ROOT" "$TASK_TMP"' EXIT

count_token() {
  printf '%s\n' "$1" | grep -o -- "$2" | wc -l | tr -d ' '
}

test_session_names_are_safe_and_isolated() {
  local home_a home_b long_id a a_again ambient_hash b other
  home_a="$TMP_ROOT/home-a"
  home_b="$TMP_ROOT/home-b"
  mkdir -p "$home_a" "$home_b"
  long_id=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._
  [ "${#long_id}" -eq 64 ] || fail "long-id fixture must exercise the 64-character task-id limit"

  a=$(fm_chrome_axi_session_name "$home_a" "$long_id") || fail "session generation failed"
  a_again=$(fm_chrome_axi_session_name "$home_a" "$long_id") || fail "repeat session generation failed"
  ambient_hash=$(GIT_DEFAULT_HASH=sha256 fm_chrome_axi_session_name "$home_a" "$long_id") \
    || fail "ambient-hash session generation failed"
  b=$(fm_chrome_axi_session_name "$home_b" "$long_id") || fail "second-home session generation failed"
  other=$(fm_chrome_axi_session_name "$home_a" "${long_id%?}x") || fail "second-task session generation failed"

  [ "$a" = "$a_again" ] || fail "same home/task identity did not generate deterministically"
  [ "$a" = "$ambient_hash" ] || fail "ambient Git object format changed the browser identity"
  [ "$a" != "$b" ] || fail "separate Firstmate homes shared one browser session"
  [ "$a" != "$other" ] || fail "separate task ids shared one browser session"
  [ "$a" != default ] || fail "generated session fell back to the shared default"
  [ "${#a}" -ge 1 ] && [ "${#a}" -le 64 ] || fail "generated session length violates the 1-64 contract: ${#a}"
  case "$a" in *[!A-Za-z0-9._-]*) fail "generated session contains an unsafe character: $a" ;; esac
  fm_chrome_axi_session_name_valid "$a" || fail "generated session failed its own validator"
  ! fm_chrome_axi_session_name_valid default || fail "validator accepted the shared default session"
  ! fm_chrome_axi_session_name_valid '../other' || fail "validator accepted path traversal"
  ! fm_chrome_axi_session_name_valid "$(printf '%065d' 0)" || fail "validator accepted an overlong name"
  pass "Chrome DevTools AXI sessions are deterministic, task/home-isolated, safe, and non-default"
}

test_root_and_nonroot_chrome_arguments() {
  local out
  out=$(fm_chrome_axi_args_for_uid 1000 '')
  [ -z "$out" ] || fail "empty non-root arguments gained a value: $out"

  out=$(fm_chrome_axi_args_for_uid 0 '')
  [ "$out" = '--no-sandbox' ] || fail "empty root arguments lacked the exact token: $out"

  out=$(fm_chrome_axi_args_for_uid 1000 '--enable-gpu')
  [ "$out" = '--enable-gpu' ] || fail "non-root launch changed ambient Chrome arguments: $out"

  out=$(fm_chrome_axi_args_for_uid 0 '--enable-gpu')
  [ "$out" = '--enable-gpu --no-sandbox' ] || fail "root launch did not preserve ambient args and append the exact token: $out"

  out=$(fm_chrome_axi_args_for_uid 0 '--no-sandbox --enable-gpu --no-sandbox')
  [ "$out" = '--enable-gpu --no-sandbox' ] || fail "root launch did not normalize duplicate exact tokens: $out"
  [ "$(count_token "$out" '--no-sandbox')" -eq 1 ] || fail "normalized root token did not appear exactly once"

  out=$(fm_chrome_axi_args_for_uid 1000 '--no-sandbox --enable-gpu --no-sandbox')
  [ "$out" = '--enable-gpu' ] || fail "non-root launch retained an exact sandbox weakening: $out"

  out=$(fm_chrome_axi_args_for_uid 0 '--no-sandboxed')
  [ "$out" = '--no-sandboxed --no-sandbox' ] || fail "root token detection accepted a prefix instead of an exact token: $out"

  out=$(fm_chrome_axi_args_for_uid 1000 '--no-sandboxed --enable-gpu')
  [ "$out" = '--no-sandboxed --enable-gpu' ] || fail "non-root normalization removed a non-exact substring: $out"

  out=$(fm_chrome_axi_args_for_uid 0 $'--enable-gpu\t--no-sandbox')
  [ "$out" = '--enable-gpu --no-sandbox' ] || fail "whitespace-delimited exact token was not normalized"
  pass "Chrome arguments preserve other tokens and enforce --no-sandbox exactly once only for root"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'tmux'
  printf ' <%s>' "$@"
  printf '\n'
} >> "${FM_TMUX_REC:?}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf '%s\n' firstmate; exit 0 ;;
  new-window) printf '%s\n' '@chrome-wid'; exit 0 ;;
  list-windows|has-session|new-session|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

test_spawn_publishes_environment_before_shared_launch() {
  local home project worktree fakebin rec id out rc meta session launch_line
  home="$TMP_ROOT/spawn-home"
  project="$TMP_ROOT/project"
  worktree="$TMP_ROOT/worktree"
  id=chrome-launch-r5
  rec="$TMP_ROOT/tmux.log"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  printf 'browser brief\n' > "$home/data/$id/brief.md"
  fm_git_init_commit "$project"
  git -C "$project" worktree add -q --detach "$worktree"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/fake")
  : > "$rec"

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$worktree" FM_TMUX_REC="$rec" \
    TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    CHROME_DEVTOOLS_AXI_CHROME_ARGS='--enable-gpu' \
    CHROME_DEVTOOLS_AXI_PORT=9777 CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1 \
    CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:9222 \
    CHROME_DEVTOOLS_AXI_USER_DATA_DIR=/shared/profile \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "sh -c 'printf launched'" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "shared launch fixture failed: $out"

  meta="$home/state/$id.meta"
  assert_present "$meta" "spawn did not publish task metadata"
  session=$(fm_chrome_axi_session_name "$home" "$id")
  assert_grep "chrome_devtools_axi_session=$session" "$meta" "spawn did not record the exact browser session"
  launch_line=$(grep "CHROME_DEVTOOLS_AXI_SESSION" "$rec" | tail -1)
  assert_contains "$launch_line" "CHROME_DEVTOOLS_AXI_SESSION='$session'" "agent launch lacked the recorded named session"
  assert_contains "$launch_line" "CHROME_DEVTOOLS_AXI_CHROME_ARGS='--enable-gpu --no-sandbox'" "agent launch lacked preserved root-safe Chrome arguments"
  assert_contains "$launch_line" "CHROME_DEVTOOLS_AXI_PORT=''" "agent launch retained a fixed ambient port"
  assert_contains "$launch_line" "CHROME_DEVTOOLS_AXI_AUTO_CONNECT=''" "agent launch retained ambient interactive-browser attachment"
  assert_contains "$launch_line" "CHROME_DEVTOOLS_AXI_BROWSER_URL=''" "agent launch retained an external browser URL"
  assert_contains "$launch_line" "CHROME_DEVTOOLS_AXI_USER_DATA_DIR=''" "agent launch retained a shared profile"
  assert_contains "$launch_line" "sh -c 'printf launched'" "browser environment was not attached to the actual worker launch command"

  # shellcheck disable=SC2016 # The quoted source pattern must match literal variable references.
  [ "$(grep -c 'spawn_send_literal \"\$T\" \"\$LAUNCH\"' "$ROOT/bin/fm-spawn.sh")" -eq 1 ] \
    || fail "fm-spawn lost its one shared launch-command boundary"
  for backend in tmux herdr zellij orca cmux; do
    grep -q "^  $backend)" "$ROOT/bin/fm-spawn.sh" || fail "spawn-capable backend $backend is absent from the shared backend convergence"
  done
  for harness in claude codex opencode pi pi-signed grok kimi; do
    grep -q "$harness" "$ROOT/bin/fm-spawn.sh" || fail "verified worker runtime $harness is absent from launch templates"
  done
  pass "the shared launch boundary publishes one isolated root-safe browser environment before every worker runtime"
}

test_metadata_binding_and_legacy_safety() {
  local home id meta expected
  home="$TMP_ROOT/meta-home"
  id='meta-browser-t6'
  meta="$TMP_ROOT/meta"
  mkdir -p "$home"
  expected=$(fm_chrome_axi_session_name "$home" "$id")

  printf 'window=firstmate:fm-%s\n' "$id" > "$meta"
  fm_chrome_axi_validate_meta_session "$meta" "$id" "$home" \
    || fail "legacy metadata without a browser field must remain a safe no-op"

  printf 'chrome_devtools_axi_session=%s\n' "$expected" >> "$meta"
  fm_chrome_axi_validate_meta_session "$meta" "$id" "$home" \
    || fail "exact home/task browser binding was refused"

  printf 'chrome_devtools_axi_session=%s\n' "$expected" >> "$meta"
  ! fm_chrome_axi_validate_meta_session "$meta" "$id" "$home" 2>/dev/null \
    || fail "duplicate browser fields were accepted"

  printf 'chrome_devtools_axi_session=default\n' > "$meta"
  ! fm_chrome_axi_validate_meta_session "$meta" "$id" "$home" 2>/dev/null \
    || fail "shared default browser metadata was accepted"

  printf 'chrome_devtools_axi_session=%s\n' "$(fm_chrome_axi_session_name "$home" other-task)" > "$meta"
  ! fm_chrome_axi_validate_meta_session "$meta" "$id" "$home" 2>/dev/null \
    || fail "another task's valid browser session was accepted"
  pass "browser cleanup metadata accepts only one exact home/task binding and keeps legacy records inert"
}

test_session_names_are_safe_and_isolated
test_root_and_nonroot_chrome_arguments
test_spawn_publishes_environment_before_shared_launch
test_metadata_binding_and_legacy_safety
