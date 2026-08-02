#!/usr/bin/env bash
# Behavior tests for fm-spawn's verified long-launch delivery protocol.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-launch-delivery)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u

screen=${FM_FAKE_SCREEN:?}
log=${FM_FAKE_TMUX_LOG:?}
attempts=${FM_FAKE_ATTEMPTS:?}
staged=${FM_FAKE_STAGED:?}
evaluated=${FM_FAKE_EVALUATED:?}
screen_history=${FM_FAKE_SCREEN_HISTORY:?}
write_screen_line() {
  printf '%s\n' "$1" | fold -w "${FM_FAKE_PANE_COLUMNS:-80}" > "$screen"
  cat "$screen" >> "$screen_history"
}
case "${1:-}" in
  display-message)
    case "$*" in
      *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_PANE_PATH" ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0
    ;;
  new-window) printf '@7\n'; exit 0 ;;
  list-windows|has-session|set-window-option|kill-window) exit 0 ;;
  capture-pane) cat "$screen"; exit 0 ;;
  send-keys)
    text=${4:-}
    printf '%s\n' "$text" >> "$log"
    case "$text" in
      *"__FM_SPAWN_READY_"*)
        token=$(printf '%s\n' "$text" | sed -n "s/.*'__FM_SPAWN_READY_' '\([^']*\)'.*/\1/p")
        [ -n "$token" ] && write_screen_line "__FM_SPAWN_READY_$token"
        ;;
      "FM_SPAWN_LAUNCH=''" )
        count=$(($(cat "$attempts" 2>/dev/null || printf 0) + 1))
        printf '%s\n' "$count" > "$attempts"
        : > "$staged"
        ;;
      FM_SPAWN_LAUNCH=*)
        rebuilt=$(FM_SPAWN_LAUNCH="$(cat "$staged")" bash -c "$text; printf '%s' \"\$FM_SPAWN_LAUNCH\"")
        if [ "$(cat "$attempts")" -le "${FM_FAKE_TRUNCATE_ATTEMPTS:-0}" ] && [ -n "$rebuilt" ]; then
          rebuilt=${rebuilt%?}
        fi
        printf '%s' "$rebuilt" > "$staged"
        ;;
      *"__FM_SPAWN_LAUNCH_OK_"*)
        result=$(FM_SPAWN_LAUNCH="$(cat "$staged")" bash -c "$text")
        if [ "$(cat "$attempts")" -le "${FM_FAKE_TRUNCATE_ATTEMPTS:-0}" ]; then
          # The fixed-offset env-scrub prefix is the live truncation signature.
          printf '/usr/bin/env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_H\n%s\n' "$result" > "$screen"
          cat "$screen" >> "$screen_history"
        else
          write_screen_line "$result"
        fi
        ;;
      'eval "$FM_SPAWN_LAUNCH"')
        FM_SPAWN_LAUNCH="$(cat "$staged")" bash -c "$text" > "$evaluated"
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'brief\n' > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  : > "$case_dir/screen"
  : > "$case_dir/tmux.log"
  : > "$case_dir/attempts"
  : > "$case_dir/staged"
  : > "$case_dir/evaluated"
  : > "$case_dir/screen-history"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_SCREEN="$case_dir/screen" FM_FAKE_TMUX_LOG="$case_dir/tmux.log" \
    FM_FAKE_ATTEMPTS="$case_dir/attempts" FM_FAKE_STAGED="$case_dir/staged" \
    FM_FAKE_EVALUATED="$case_dir/evaluated" FM_FAKE_SCREEN_HISTORY="$case_dir/screen-history" \
    FM_SPAWN_LAUNCH_POLL_INTERVAL=0 FM_SPAWN_LAUNCH_CHUNK_DELAY=0 \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$@" 2>&1
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

long_raw_launch() {
  local payload
  payload=$(printf 'x%.0s' $(seq 1 1800))
  printf "printf '%%s\\n' %s" "$payload"
}

test_retries_the_recorded_truncation_signature_and_never_types_a_long_line() {
  local id rec out rc
  id='launch-retry-z1'
  rec=$(make_case retry "$id")
  read_case "$rec"
  out=$(FM_FAKE_TRUNCATE_ATTEMPTS=1 FM_SPAWN_LAUNCH_DELIVERY_RETRIES=3 \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$(long_raw_launch)")
  rc=$?
  expect_code 0 "$rc" "spawn should retry the observed truncation signature"$'\n'"$out"
  [ "$(cat "$CASE_DIR/attempts")" = 2 ] \
    || fail "launch verification did not retry after the truncated env-scrub signature"
  awk 'length($0) > 450 { exit 1 }' "$CASE_DIR/tmux.log" \
    || fail "fm-spawn sent a line larger than the bounded delivery chunk"
  assert_grep 'C-c' "$CASE_DIR/tmux.log" "failed delivery did not clear the pending shell line before retry"
  [ "$(wc -c < "$CASE_DIR/evaluated" | tr -d ' ')" = 1801 ] \
    || fail "verified retry did not evaluate the complete 1,800-byte payload"
  [ -z "$(tr -d 'x\n' < "$CASE_DIR/evaluated")" ] \
    || fail "verified retry evaluated bytes other than the complete launch payload"
  assert_contains "$out" "spawned $id" "verified retry did not finish the spawn"
  if [ -n "${FM_TEST_EVIDENCE_DIR:-}" ]; then
    mkdir -p "$FM_TEST_EVIDENCE_DIR"
    {
      printf '$ fm-spawn.sh %s <1,800-byte raw launch>\n' "$id"
      printf '%s\n' "$out"
      printf '\nObserved shell output across delivery attempts:\n'
      cat "$CASE_DIR/screen-history"
      printf '\nDelivery facts:\n'
      printf 'attempts=%s\n' "$(cat "$CASE_DIR/attempts")"
      printf 'largest_typed_line_bytes=%s\n' "$(awk '{ if (length > max) max=length } END { print max + 0 }' "$CASE_DIR/tmux.log")"
      printf 'evaluated_payload_bytes=%s\n' "$(wc -c < "$CASE_DIR/evaluated" | tr -d ' ')"
      printf 'evaluated_payload_non_x_bytes=%s\n' "$(tr -d 'x\n' < "$CASE_DIR/evaluated" | wc -c | tr -d ' ')"
    } > "$FM_TEST_EVIDENCE_DIR/launch-retry-transcript.txt"
  fi
  pass "fm-spawn retries the recorded canonical-buffer truncation and stages only bounded lines"
}

test_refuses_to_report_success_when_every_delivery_check_is_truncated() {
  local id rec out rc
  id='launch-refuse-z2'
  rec=$(make_case refuse "$id")
  read_case "$rec"
  out=$(FM_FAKE_TRUNCATE_ATTEMPTS=3 FM_SPAWN_LAUNCH_DELIVERY_RETRIES=2 \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$(long_raw_launch)") || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "fm-spawn reported success after every staged launch was truncated"
  assert_contains "$out" "launch command delivery could not be verified after 2 attempts" \
    "failed delivery did not name the bounded verification refusal"
  assert_grep 'failed: launch command delivery could not be verified after 2 attempts' \
    "$HOME_DIR/state/$id.status" "failed delivery was not recorded for supervision"
  [ ! -s "$CASE_DIR/evaluated" ] || fail "failed launch verification still evaluated the staged command"
  if [ -n "${FM_TEST_EVIDENCE_DIR:-}" ]; then
    mkdir -p "$FM_TEST_EVIDENCE_DIR"
    {
      printf '$ fm-spawn.sh %s <1,800-byte raw launch>\n' "$id"
      printf '%s\n' "$out"
      printf '\nPersisted supervision status:\n'
      cat "$HOME_DIR/state/$id.status"
      printf '\nObserved shell output across delivery attempts:\n'
      cat "$CASE_DIR/screen-history"
      printf '\nRefusal facts:\n'
      printf 'attempts=%s\n' "$(cat "$CASE_DIR/attempts")"
      printf 'evaluated_payload_bytes=%s\n' "$(wc -c < "$CASE_DIR/evaluated" | tr -d ' ')"
    } > "$FM_TEST_EVIDENCE_DIR/launch-refusal-transcript.txt"
  fi
  pass "fm-spawn fails loudly when bounded launch verification never succeeds"
}

test_long_task_id_keeps_verification_markers_on_one_pane_line() {
  local id rec out rc
  id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  rec=$(make_case long-id "$id")
  read_case "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$(long_raw_launch)")
  rc=$?
  expect_code 0 "$rc" "64-character task ID should not wrap launch verification markers"$'\n'"$out"
  assert_contains "$out" "spawned $id" "long task ID did not complete verified launch delivery"
  pass "fm-spawn keeps verification markers bounded independently of task ID length"
}

test_wrapped_delivery_marker_still_proves_shell_execution() {
  local id rec out rc
  id='launch-wrap-z3'
  rec=$(make_case wrapped-marker "$id")
  read_case "$rec"
  out=$(FM_FAKE_PANE_COLUMNS=20 \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$(long_raw_launch)")
  rc=$?
  expect_code 0 "$rc" "a terminal-wrapped verification marker should still prove launch delivery"$'\n'"$out"
  assert_contains "$(cat "$CASE_DIR/screen-history")" "__FM_SPAWN_READY_" \
    "wrapped-marker fixture did not render the shell-ready marker"
  assert_contains "$out" "spawned $id" "wrapped marker did not complete verified launch delivery"
  pass "fm-spawn accepts a verification marker split across terminal rows"
}

test_retries_the_recorded_truncation_signature_and_never_types_a_long_line
test_refuses_to_report_success_when_every_delivery_check_is_truncated
test_long_task_id_keeps_verification_markers_on_one_pane_line
test_wrapped_delivery_marker_still_proves_shell_execution

echo "# all fm-spawn-launch-delivery tests passed"
