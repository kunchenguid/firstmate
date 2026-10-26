#!/usr/bin/env bash
# fm-cold-cache-lib.sh: the cold prompt-cache policy.
#
# Pins the threshold config contract, the "only a valid idle record is cold"
# rule, park eligibility (including the relaunch-journal phase), the default
# relaunch note, and the fm-send refusal that the policy drives.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-cold-cache-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-cold-cache)
mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

new_home() {  # <name> -> echoes home dir with state/ config/ data/
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' "$home"
}

# write_busy <state> <id> <state-word> <seconds-ago>
write_busy() {
  printf 'g1\n' > "$1/$2.busy-gen"
  printf 'v1 gen=g1 seq=3 state=%s source=claude-hook event=stop ts=%s\n' \
    "$3" "$(( $(date +%s) - $4 ))" > "$1/$2.busy-state"
}

test_threshold_config() {
  local home rc out
  home=$(new_home threshold)
  assert_equals "3300" "$(fm_cold_cache_threshold_secs "$home/config")" "absent config should mean 55 minutes"
  printf '10\n' > "$home/config/cold-cache-minutes"
  assert_equals "600" "$(fm_cold_cache_threshold_secs "$home/config")" "minutes should convert to seconds"
  printf 'off\n' > "$home/config/cold-cache-minutes"
  assert_equals "off" "$(fm_cold_cache_threshold_secs "$home/config")" "off should disable the policy"
  for bad in 0 007 abc -5 ''; do
    printf '%s\n' "$bad" > "$home/config/cold-cache-minutes"
    out=$(fm_cold_cache_threshold_secs "$home/config" 2>&1); rc=$?
    expect_code 2 "$rc" "malformed value '$bad' should return 2"
    assert_contains "$out" "cold-cache-minutes" "malformed value '$bad' should name the file"
  done
  pass "cold-cache: threshold is 55 minutes by default, minutes or off when set, and malformed values refuse"
}

test_only_a_valid_old_idle_record_is_cold() {
  local home s rc
  home=$(new_home cold); s="$home/state"
  fm_write_meta "$s/t1.meta" "kind=ship" "harness=claude"
  fm_cold_cache_is_cold "$home/config" "$s" t1 >/dev/null; rc=$?
  expect_code 1 "$rc" "a missing record must not be cold"
  write_busy "$s" t1 idle 4000
  fm_cold_cache_is_cold "$home/config" "$s" t1 >/dev/null || fail "an idle record older than 55 minutes should be cold"
  write_busy "$s" t1 idle 60
  fm_cold_cache_is_cold "$home/config" "$s" t1 >/dev/null && fail "a fresh idle record must not be cold"
  write_busy "$s" t1 busy 4000
  fm_cold_cache_is_cold "$home/config" "$s" t1 >/dev/null && fail "an old busy record must not be cold"
  write_busy "$s" t1 unknown 4000
  fm_cold_cache_is_cold "$home/config" "$s" t1 >/dev/null && fail "an old unknown record must not be cold"
  write_busy "$s" t1 idle 4000
  printf 'g2\n' > "$s/t1.busy-gen"
  fm_cold_cache_is_cold "$home/config" "$s" t1 >/dev/null && fail "an old idle record from another incarnation must not be cold"
  write_busy "$s" t1 idle 4000
  printf 'off\n' > "$home/config/cold-cache-minutes"
  fm_cold_cache_is_cold "$home/config" "$s" t1 >/dev/null && fail "off must disable cold detection"
  printf 'x\n' > "$home/config/cold-cache-minutes"
  fm_cold_cache_is_cold "$home/config" "$s" t1 >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "a malformed config should surface as 2"
  pass "cold-cache: only a valid, current-incarnation idle record older than the threshold is cold"
}

test_park_check() {
  local home s out rc
  home=$(new_home park); s="$home/state"
  fm_write_meta "$s/t1.meta" "kind=ship" "harness=claude"
  write_busy "$s" t1 idle 4000
  printf 'working [at=1]: started\n' > "$s/t1.status"
  out=$(fm_cold_cache_park_check "$home/config" "$s" t1); rc=$?
  expect_code 1 "$rc" "a worker whose latest status is not a wait must not park"
  assert_contains "$out" "not a declared wait" "the refusal should say why"
  for verb in "done" paused needs-decision blocked failed; do
    printf '%s [at=1]: x\n' "$verb" > "$s/t1.status"
    fm_cold_cache_park_check "$home/config" "$s" t1 >/dev/null || fail "latest status '$verb' should allow parking"
  done
  mkdir -p "$(fm_task_inbox_dir "$s" t1)"
  : > "$(fm_task_inbox_dir "$s" t1)/001.msg"
  out=$(fm_cold_cache_park_check "$home/config" "$s" t1) && fail "an unread steer must block parking"
  assert_contains "$out" "unread steering-inbox" "the inbox refusal should say why"
  rm -f "$(fm_task_inbox_dir "$s" t1)/001.msg"
  printf 'phase=exiting\n' > "$s/t1.control-relaunch"
  out=$(fm_cold_cache_park_check "$home/config" "$s" t1) && fail "a pending relaunch must block parking"
  assert_contains "$out" "relaunch transaction" "the relaunch refusal should say why"
  printf 'phase=complete\n' > "$s/t1.control-relaunch"
  fm_cold_cache_park_check "$home/config" "$s" t1 >/dev/null || fail "a completed relaunch journal must not block parking"
  write_busy "$s" t1 busy 4000
  fm_cold_cache_park_check "$home/config" "$s" t1 >/dev/null && fail "a busy worker must never park"
  write_busy "$s" t1 idle 4000
  printf 'parked_at=1\n' > "$s/t1.cold-parked"
  out=$(fm_cold_cache_park_check "$home/config" "$s" t1) && fail "an already-parked task must not park again"
  rm -f "$s/t1.cold-parked"
  fm_write_meta "$s/t1.meta" "kind=secondmate" "harness=claude"
  out=$(fm_cold_cache_park_check "$home/config" "$s" t1) && fail "a secondmate must never park"
  assert_contains "$out" "out of scope" "the secondmate refusal should say why"
  pass "cold-cache: park needs a cold declared wait, no unread steer, no pending relaunch, and ship or scout scope"
}

test_note_names_brief_branch_and_status() {
  local home s wt note
  home=$(new_home note); s="$home/state"; wt="$TMP_ROOT/note-wt"
  fm_git_init_commit "$wt"
  : > "$wt/dirty.txt"
  fm_write_meta "$s/t1.meta" "kind=ship" "worktree=$wt"
  printf 'paused [at=1]: one\npaused [at=2]: two\npaused [at=3]: three\nneeds-decision [at=4]: four\n' > "$s/t1.status"
  printf 'parked_at=%s\nstatus=x\nendpoint=closed\n' "$(date +%s)" > "$s/t1.cold-parked"
  note=$(fm_cold_cache_note "$s" "$home/data" t1)
  assert_contains "$note" "Instructions: $home/data/t1/brief.md" "the note should name the brief"
  assert_contains "$note" "stopped on purpose" "a parked task's note should say the stop was deliberate"
  assert_contains "$note" "Uncommitted paths: 1" "the note should count uncommitted paths"
  assert_contains "$note" "needs-decision [at=4]: four" "the note should carry the latest status"
  assert_not_contains "$note" "[at=1]: one" "the note should keep only the last three status events"
  assert_equals "$s/t1.cold-relaunch-note" "$(fm_cold_cache_write_note "$s" "$home/data" t1)" "write_note should print its path"
  [ -s "$s/t1.cold-relaunch-note" ] || fail "write_note should write the note"
  pass "cold-cache: the default note names the brief, the local copy, and the last three status events"
}

make_tmux_stub() {  # <dir> -> echoes fakebin
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  send-keys) printf '%s\n' "$*" >> "$FM_TMUX_LOG" ;;
  display-message) case "$*" in *cursor_y*) printf '1\n' ;; *) printf '%%1\n' ;; esac ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  list-windows) printf 'fm-t1\n' ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"; chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

test_send_refuses_a_cold_or_parked_ship() {
  local home s fb log out rc
  home=$(new_home send); s="$home/state"; log="$TMP_ROOT/send-tmux.log"; : > "$log"
  fb=$(make_tmux_stub "$TMP_ROOT/send")
  fm_write_meta "$s/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  write_busy "$s" t1 idle 4000
  printf 'paused [at=1]: waiting\n' > "$s/t1.status"
  out=$(PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t1 "hello" 2>&1); rc=$?
  expect_code 4 "$rc" "a cold ship steer should be refused with exit 4"
  assert_contains "$out" "fm-control.sh t1 relaunch --note-file" "the refusal should print the relaunch command"
  assert_contains "$out" "--cold-ok" "the refusal should name the override"
  case "$out" in *"No such file"*) fail "the refusal should print no stray error: $out" ;; esac
  [ -s "$s/t1.cold-relaunch-note" ] || fail "the refusal should write the default note"
  [ -s "$log" ] && fail "a refused steer must type nothing"
  [ -e "$s/t1.inbox/001.msg" ] && fail "a refused steer must record nothing"

  out=$(PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t1 --cold-ok "hello" 2>&1); rc=$?
  expect_code 0 "$rc" "--cold-ok should send to a cold ship: $out"
  grep -qF hello "$s/t1.inbox/001.msg" || fail "--cold-ok should record the steer"

  : > "$log"
  printf 'parked_at=1\nendpoint=kept\n' > "$s/t1.cold-parked"
  out=$(PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t1 --cold-ok "again" 2>&1); rc=$?
  expect_code 4 "$rc" "a parked ship must refuse even --cold-ok"
  assert_contains "$out" "relaunch" "the parked refusal should print the relaunch command"
  [ -s "$log" ] && fail "a parked refusal must type nothing"
  pass "fm-send: a cold ship is refused with the relaunch command, --cold-ok overrides, a parked ship always refuses"
}

test_send_leaves_a_cold_secondmate_alone() {
  local home s fb log rc out
  home=$(new_home send-sm); s="$home/state"; log="$TMP_ROOT/send-sm-tmux.log"; : > "$log"
  fb=$(make_tmux_stub "$TMP_ROOT/send-sm")
  fm_write_meta "$s/t1.meta" "window=sess:fm-t1" "kind=secondmate" "harness=claude" "home=$TMP_ROOT/sm-home"
  write_busy "$s" t1 idle 4000
  out=$(PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t1 "hello" 2>&1); rc=$?
  [ "$rc" -ne 4 ] || fail "a cold secondmate must not get the cold refusal: $out"
  assert_not_contains "$out" "--cold-ok" "a secondmate send must not print the cold hint"
  pass "fm-send: a cold secondmate is out of scope"
}

test_threshold_config
test_only_a_valid_old_idle_record_is_cold
test_park_check
test_note_names_brief_branch_and_status
test_send_refuses_a_cold_or_parked_ship
test_send_leaves_a_cold_secondmate_alone
