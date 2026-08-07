#!/usr/bin/env bash
# Spawn-path regressions for optional GitHub App worker identity.
# Proves the inert (unconfigured) path leaves pane exports identical to today's
# GOTMPDIR-only baseline, and that a configured path injects a helper wrapper
# without placing a token on send-keys argv or into the worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-github-app-spawn)

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
  list-windows)
    [ -z "${FM_FAKE_DUPLICATE_WINDOW:-}" ] || printf '%s\n' "$FM_FAKE_DUPLICATE_WINDOW"
    exit 0
    ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
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

# Fake curl used when the spawn preflight mints against a mock API.
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
body_out=
for a in "$@"; do
  :
done
prev=
for a in "$@"; do
  if [ "$prev" = "-o" ]; then body_out=$a; fi
  prev=$a
done
token=${FM_FAKE_INSTALL_TOKEN:-ghs_spawn_test_token_not_real}
if [ -n "$body_out" ]; then
  printf '{"token":"%s","expires_at":"2099-01-01T00:00:00Z"}\n' "$token" > "$body_out"
fi
printf '201'
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'Delivery contract: mode=no-mistakes\nbrief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  : > "$launchlog"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog|$id"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$1
EOF
}

# The unconfigured path must not inject any GitHub App exports.
test_unconfigured_spawn_is_inert() {
  local rec out status
  rec=$(make_case inert ghapp-inert)
  read_case "$rec"

  out=$(
    env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$CASE_ID" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "unconfigured spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "unconfigured spawn should report success"

  assert_grep 'export GOTMPDIR=' "$LAUNCH_LOG" "GOTMPDIR export should still be sent"
  if grep -E 'GH_TOKEN|GITHUB_TOKEN|FM_GITHUB_APP|github-app-token' "$LAUNCH_LOG" >/dev/null; then
    fail "unconfigured spawn must not inject GitHub App env; launch log was: $(cat "$LAUNCH_LOG")"
  fi
  # No wrapper should have been created under the task tmp for this id.
  assert_absent "/tmp/fm-$CASE_ID/github-app-token-cmd" \
    "unconfigured spawn must not write a github-app-token-cmd wrapper"
  # Worktree must stay free of token material and app pointers.
  if find "$WT_DIR" -name '*github-app*' -o -name '*GH_TOKEN*' 2>/dev/null | grep -q .; then
    fail "worktree must not gain GitHub App artifacts when unconfigured"
  fi
  pass "unconfigured spawn leaves worker env inert (byte-identical export surface)"
}

test_configured_spawn_injects_helper_not_token() {
  local rec out status key curlbin token wrapper export_line
  token="ghs_spawn_cfg_token_not_real_xyz"
  rec=$(make_case configured ghapp-cfg)
  read_case "$rec"
  key="$HOME_DIR/app.pem"
  openssl genrsa -out "$key" 2048 2>/dev/null || fail "openssl genrsa failed"
  chmod 600 "$key"
  printf '111\n' > "$HOME_DIR/config/github-app-id"
  printf '222\n' > "$HOME_DIR/config/github-app-installation-id"
  printf '%s\n' "$key" > "$HOME_DIR/config/github-app-private-key-path"
  curlbin=$(make_fake_curl "$HOME_DIR/fake-curl")

  out=$(
    env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      FM_GITHUB_APP_API_BASE="https://example.test" \
      FM_FAKE_INSTALL_TOKEN="$token" \
      PATH="$curlbin:$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$CASE_ID" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "configured spawn should succeed after mint preflight"
  assert_contains "$out" "spawned $CASE_ID" "configured spawn should report success"

  wrapper="/tmp/fm-$CASE_ID/github-app-token-cmd"
  assert_present "$wrapper" "configured spawn should write the private mint wrapper under TASK_TMP"
  [ -x "$wrapper" ] || fail "mint wrapper should be executable"
  # Wrapper must not embed the token or private key bytes.
  assert_no_grep "$token" "$wrapper" "wrapper must not embed the installation token"
  assert_no_grep "BEGIN" "$wrapper" "wrapper must not embed private key material"
  assert_grep "fm-github-app-token.sh" "$wrapper" "wrapper should exec the mint helper"

  export_line=$(grep 'GH_TOKEN=' "$LAUNCH_LOG" | head -1 || true)
  [ -n "$export_line" ] || fail "configured spawn should send a GH_TOKEN export line"
  assert_contains "$export_line" "$wrapper" "export should invoke the TASK_TMP wrapper"
  assert_contains "$export_line" "GITHUB_TOKEN=" "export should also set GITHUB_TOKEN"
  assert_contains "$export_line" "FM_GITHUB_APP_TOKEN_HELPER=" "export should publish the remint helper path"
  case "$export_line" in
    *"$token"*) fail "installation token must not appear in send-keys argv: $export_line" ;;
  esac
  # Token must not land in the worktree.
  if grep -R -- "$token" "$WT_DIR" >/dev/null 2>&1; then
    fail "installation token must not be written into the worktree"
  fi
  if find "$WT_DIR" \( -name '.fm-github*' -o -name '*github-app-token*' \) 2>/dev/null | grep -q .; then
    fail "worktree must not hold github-app token artifacts"
  fi
  pass "configured spawn injects helper-based GH_TOKEN without token on argv or in worktree"
}

test_configured_but_broken_mint_refuses_spawn() {
  local rec out status key
  rec=$(make_case broken ghapp-broken)
  read_case "$rec"
  key="$HOME_DIR/not-a-key.pem"
  printf 'not-a-pem\n' > "$key"
  chmod 600 "$key"
  printf '111\n' > "$HOME_DIR/config/github-app-id"
  printf '222\n' > "$HOME_DIR/config/github-app-installation-id"
  printf '%s\n' "$key" > "$HOME_DIR/config/github-app-private-key-path"

  out=$(
    env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$CASE_ID" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "configured-but-broken mint should refuse spawn"
  assert_contains "$out" "GitHub App" "refusal should name the GitHub App path"
  if grep -E 'GH_TOKEN|GITHUB_TOKEN' "$LAUNCH_LOG" >/dev/null 2>&1; then
    fail "refused spawn must not inject GH_TOKEN"
  fi
  pass "configured-but-broken mint refuses spawn rather than launching ambiguously"
}

test_unconfigured_spawn_is_inert
test_configured_spawn_injects_helper_not_token
test_configured_but_broken_mint_refuses_spawn

printf 'All fm-github-app-spawn tests passed.\n'
