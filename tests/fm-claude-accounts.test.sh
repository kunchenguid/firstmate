#!/usr/bin/env bash
# Behavior tests for native Claude Code OAuth account rotation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-claude-accounts.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-accounts)

make_account() {  # <dir> <name> <email> <access> <refresh> <expired> [disabled]
  local dir=$1 name=$2 email=$3 access=$4 refresh=$5 expired=$6 disabled=${7:-false}
  mkdir -p "$dir"
  cat > "$dir/claude-$name.json" <<JSON
{
  "access_token": "$access",
  "refresh_token": "$refresh",
  "email": "$email",
  "expired": "$expired",
  "disabled": $disabled,
  "type": "claude"
}
JSON
  chmod 600 "$dir/claude-$name.json"
}

run_helper() {
  local account_dir=$1 state_dir=$2
  shift 2
  FM_CLAUDE_ACCOUNT_DIR="$account_dir" \
    FM_CLAUDE_ROTATION_STATE_DIR="$state_dir" \
    "$HELPER" "$@"
}

field() {  # <line> <index>
  printf '%s\n' "$1" | awk -F '\t' -v i="$2" '{print $i}'
}

test_list_redacts_tokens() {
  local dir state out full_access full_refresh
  dir="$TMP_ROOT/list/accounts"
  state="$TMP_ROOT/list/state"
  full_access="fake-access-alpha-AAAA"
  full_refresh="fake-refresh-alpha-RRRR"
  make_account "$dir" alpha alpha@example.test "$full_access" "$full_refresh" "2999-01-01T00:00:00Z"

  out=$(run_helper "$dir" "$state" list)

  assert_contains "$out" "claude-alpha" "list should include account id"
  assert_contains "$out" "alpha@example.test" "list should include email"
  assert_contains "$out" "fake-access...AAAA" "list should redact access token"
  assert_contains "$out" "fake-refres...RRRR" "list should redact refresh token"
  assert_not_contains "$out" "$full_access" "list must not print full access token"
  assert_not_contains "$out" "$full_refresh" "list must not print full refresh token"
  pass "fm-claude-accounts list inventories accounts with redacted tokens"
}

test_round_robin_advances_cursor() {
  local dir state first second third
  dir="$TMP_ROOT/rr/accounts"
  state="$TMP_ROOT/rr/state"
  make_account "$dir" alpha alpha@example.test fake-access-alpha-AAAA fake-refresh-alpha-RRRR "2999-01-01T00:00:00Z"
  make_account "$dir" beta beta@example.test fake-access-beta-BBBB fake-refresh-beta-SSSS "2999-01-01T00:00:00Z"

  first=$(run_helper "$dir" "$state" select)
  second=$(run_helper "$dir" "$state" select)
  third=$(run_helper "$dir" "$state" select)

  [ "$(field "$first" 1)" = "claude-alpha" ] || fail "first round-robin selection should be alpha"
  [ "$(field "$second" 1)" = "claude-beta" ] || fail "second round-robin selection should be beta"
  [ "$(field "$third" 1)" = "claude-alpha" ] || fail "third round-robin selection should wrap to alpha"
  [ "$(cat "$state/.claude-rotation-cursor")" = "claude-alpha" ] || fail "cursor should record last selected account"
  pass "round-robin policy advances and persists the selection cursor"
}

test_cooling_skips_account() {
  local dir state cooled selected
  dir="$TMP_ROOT/cool/accounts"
  state="$TMP_ROOT/cool/state"
  make_account "$dir" alpha alpha@example.test fake-access-alpha-AAAA fake-refresh-alpha-RRRR "2999-01-01T00:00:00Z"
  make_account "$dir" beta beta@example.test fake-access-beta-BBBB fake-refresh-beta-SSSS "2999-01-01T00:00:00Z"

  cooled=$(run_helper "$dir" "$state" cool claude-alpha 600)
  selected=$(run_helper "$dir" "$state" select 2>/dev/null)

  [ "$(field "$cooled" 1)" = "claude-alpha" ] || fail "cool should return cooled account id"
  [ "$(field "$selected" 1)" = "claude-beta" ] || fail "selection should skip cooling alpha"
  pass "cooling marker skips a limited Claude account"
}

make_fake_curl() {
  local dir=$1 fakebin log reqcopy
  fakebin=$(fm_fakebin "$dir")
  log="$dir/curl-argv.log"
  reqcopy="$dir/request.json"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=
data=
printf '%s\n' "$*" >> "$FM_FAKE_CURL_ARGV_LOG"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    --data-binary) data=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || exit 2
case "$data" in
  @*) cp "${data#@}" "$FM_FAKE_CURL_REQUEST_COPY" ;;
esac
cat > "$out" <<'JSON'
{
  "access_token": "fake-access-new-CCCC",
  "refresh_token": "fake-refresh-new-DDDD",
  "expires_in": 3600,
  "id_token": "fake-id-token"
}
JSON
SH
  chmod +x "$fakebin/curl"
  printf '%s|%s|%s\n' "$fakebin" "$log" "$reqcopy"
}

test_near_expiry_refreshes_atomically() {
  local dir state curl_rec fakebin log req out file
  dir="$TMP_ROOT/refresh/accounts"
  state="$TMP_ROOT/refresh/state"
  make_account "$dir" alpha alpha@example.test fake-access-old-AAAA fake-refresh-old-RRRR "2000-01-01T00:00:00Z"
  curl_rec=$(make_fake_curl "$TMP_ROOT/refresh/fake")
  IFS='|' read -r fakebin log req <<EOF
$curl_rec
EOF

  out=$(
    FM_CLAUDE_ACCOUNT_DIR="$dir" \
      FM_CLAUDE_ROTATION_STATE_DIR="$state" \
      FM_FAKE_CURL_ARGV_LOG="$log" \
      FM_FAKE_CURL_REQUEST_COPY="$req" \
      PATH="$fakebin:$PATH" \
      "$HELPER" select
  )
  file="$dir/claude-alpha.json"

  [ "$(field "$out" 1)" = "claude-alpha" ] || fail "refreshing select should still choose alpha"
  [ "$(jq -r '.access_token' "$file")" = "fake-access-new-CCCC" ] || fail "access token was not rotated in account file"
  [ "$(jq -r '.refresh_token' "$file")" = "fake-refresh-new-DDDD" ] || fail "refresh token was not rotated in account file"
  [ "$(stat -f '%Lp' "$file")" = "600" ] || fail "account file mode should stay 0600"
  assert_no_grep "fake-refresh-old-RRRR" "$log" "refresh token must not appear in curl argv"
  assert_grep "fake-refresh-old-RRRR" "$req" "refresh request body should carry the old refresh token in the temp file"
  pass "near-expiry account refreshes through a mock endpoint and persists the new pair"
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
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin launchlog accounts
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  accounts="$case_dir/accounts"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$accounts"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  make_account "$accounts" alpha alpha@example.test fake-access-alpha-AAAA fake-refresh-alpha-RRRR "2999-01-01T00:00:00Z"
  printf '%s|%s|%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$accounts"
}

read_spawn_case() {
  IFS='|' read -r _case_dir HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG ACCOUNT_DIR <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_fm_spawn_injects_only_when_claude_rotation_enabled() {
  local rec id out status launch
  id=claude-rotate-spawn-z1
  rec=$(make_spawn_case claude-enabled claude "$id")
  read_spawn_case "$rec"
  printf 'enabled\npolicy=round-robin\naccount_dir=%s\n' "$ACCOUNT_DIR" > "$HOME_DIR/config/claude-rotation"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with rotation enabled should succeed"
  launch=$(cat "$LAUNCH_LOG")

  assert_contains "$launch" "fm-claude-accounts.sh' exec 'claude-alpha' -- claude --dangerously-skip-permissions" \
    "claude launch should wrap through the account helper"
  assert_not_contains "$launch" "fake-access-alpha-AAAA" "claude launch string must not contain the access token"
  assert_grep "claude_oauth_account=alpha@example.test" "$HOME_DIR/state/$id.meta" "meta should record account email"
  assert_grep "claude_oauth_account_id=claude-alpha" "$HOME_DIR/state/$id.meta" "meta should record account id"
  pass "fm-spawn injects Claude OAuth helper only when rotation is enabled for claude"
}

test_fm_spawn_leaves_non_claude_harness_alone_when_enabled() {
  local rec id out status launch
  id=claude-rotate-spawn-z2
  rec=$(make_spawn_case codex-enabled codex "$id")
  read_spawn_case "$rec"
  printf 'enabled\npolicy=round-robin\naccount_dir=%s\n' "$ACCOUNT_DIR" > "$HOME_DIR/config/claude-rotation"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn with Claude rotation enabled should succeed"
  launch=$(cat "$LAUNCH_LOG")

  # Match the codex command and its sandbox flag separately: an absent
  # config/crew-codex-mcp legitimately inserts the MCP opt-out (-c 'mcp_servers={}')
  # between them, and this case is about the harness, not that knob.
  case "$launch" in
    codex\ *) ;;
    *) fail "codex launch should still be codex, got: $launch" ;;
  esac
  assert_contains "$launch" "--dangerously-bypass-approvals-and-sandbox" "codex launch should keep its codex sandbox flag"
  assert_not_contains "$launch" "fm-claude-accounts.sh" "non-claude launch must not use Claude OAuth helper"
  assert_no_grep "claude_oauth_account" "$HOME_DIR/state/$id.meta" "non-claude meta must not record Claude account"
  pass "fm-spawn does not inject Claude OAuth rotation into non-claude harnesses"
}

test_fm_spawn_keeps_claude_default_when_rotation_disabled() {
  local rec id out status launch expected
  id=claude-rotate-spawn-z3
  rec=$(make_spawn_case claude-disabled claude "$id")
  read_spawn_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with rotation disabled should succeed"
  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$(cat '$HOME_DIR/data/$id/brief.md')\""

  [ "$launch" = "$expected" ] || fail "disabled rotation should keep claude launch unchanged"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_no_grep "claude_oauth_account" "$HOME_DIR/state/$id.meta" "disabled rotation meta must not record Claude account"
  pass "fm-spawn keeps default claude auth when rotation is disabled"
}

test_list_redacts_tokens
test_round_robin_advances_cursor
test_cooling_skips_account
test_near_expiry_refreshes_atomically
test_fm_spawn_injects_only_when_claude_rotation_enabled
test_fm_spawn_leaves_non_claude_harness_alone_when_enabled
test_fm_spawn_keeps_claude_default_when_rotation_disabled

echo "# all fm-claude-accounts tests passed"
