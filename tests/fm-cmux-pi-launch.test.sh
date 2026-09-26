#!/usr/bin/env bash
# Public fm-spawn regression for cmux Pi launch confirmation.
# The fake cmux preserves the incident's masking condition: workspace creation
# returns an exact UUID pair while every current-window title listing stays empty.
# It can either emit Pi's real busy-event shape when the staged launch is
# submitted or leave the surface as an idle shell.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-cmux-pi-launch)
SUCCESS_ID="cmux-pi-ready-ok-$$"
FAILURE_ID="cmux-pi-ready-fail-$$"
SEND_FAILURE_ID="cmux-pi-send-fail-$$"
ENTER_FAILURE_ID="cmux-pi-enter-fail-$$"
PUBLISH_FAILURE_ID="cmux-pi-publish-fail-$$"
DISPATCH_FAILURE_ID="cmux-pi-dispatch-fail-$$"
WORKTREE_FAILURE_ID="cmux-pi-worktree-fail-$$"
TMUX_FAILURE_ID="tmux-pi-send-fail-$$"

cleanup_launch_tmp() {
  rm -rf -- "/tmp/fm-$SUCCESS_ID" "/tmp/fm-$FAILURE_ID" "/tmp/fm-$SEND_FAILURE_ID" "/tmp/fm-$ENTER_FAILURE_ID" "/tmp/fm-$PUBLISH_FAILURE_ID" "/tmp/fm-$DISPATCH_FAILURE_ID" "/tmp/fm-$WORKTREE_FAILURE_ID" "/tmp/fm-$TMUX_FAILURE_ID"
  find /tmp -maxdepth 1 -type d \( -name "fm-$SUCCESS_ID+*" -o -name "fm-$FAILURE_ID+*" -o -name "fm-$SEND_FAILURE_ID+*" -o -name "fm-$ENTER_FAILURE_ID+*" -o -name "fm-$PUBLISH_FAILURE_ID+*" -o -name "fm-$DISPATCH_FAILURE_ID+*" -o -name "fm-$WORKTREE_FAILURE_ID+*" -o -name "fm-$TMUX_FAILURE_ID+*" \) -exec rm -rf -- {} + 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_launch_tmp EXIT INT TERM

make_cmux_pi_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" treehouse
  fm_test_fake_sleep_noop "$fakebin"

  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --help) printf '%s\n' 'Usage: pi [--tui-mode <mode>]' ;;
  --version) printf '%s\n' 'pi 0.87.1' ;;
esac
exit 0
SH

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_FALLBACK_LOG:?}"
exit 88
SH

  cat > "$fakebin/cmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_CMUX_LOG:?}"
case "${1:-}" in
  version)
    printf '%s\n' 'cmux 0.64.17 (97) [fake]'
    exit 0
    ;;
  ping)
    printf '%s\n' 'PONG'
    exit 0
    ;;
esac
if [ "${1:-}" = workspace ] && [ "${2:-}" = list ]; then
  for arg in "$@"; do
    if [ "$arg" = --window ]; then
      printf '%s\n' '{"workspaces":[{"id":"aaaaaaaa-0000-0000-0000-000000000000","title":"fm-task"},{"id":"ffffffff-0000-0000-0000-000000000000","title":"other"}]}'
      exit 0
    fi
  done
  printf '%s\n' '{"workspaces":[]}'
  exit 0
fi
if [ "${1:-}" = workspace ] && [ "${2:-}" = create ]; then
  printf '%s\n' '{"workspace_id":"aaaaaaaa-0000-0000-0000-000000000000","surface_id":"bbbbbbbb-1111-1111-1111-111111111111"}'
  exit 0
fi
case "${1:-}" in
  list-windows)
    printf '%s\n' '[{"id":"eeeeeeee-0000-0000-0000-000000000000"}]'
    ;;
  list-panes)
    if [ -f "${FM_FAKE_CMUX_CLOSED:?}" ]; then
      printf '%s\n' 'Error: not_found: Workspace not found' >&2
      exit 1
    fi
    printf '%s\n' '{"panes":[{"selected_surface_id":"bbbbbbbb-1111-1111-1111-111111111111","surface_ids":["bbbbbbbb-1111-1111-1111-111111111111"]}]}'
    ;;
  close-workspace)
    [ "${FM_FAKE_CMUX_CONFIRM_CLOSE:-0}" != 1 ] || : > "${FM_FAKE_CMUX_CLOSED:?}"
    ;;
  send)
    last=
    for arg in "$@"; do last=$arg; done
    if [[ "$last" == *'/launch.'* ]] && [ "${FM_FAKE_CMUX_FAIL_LAUNCH_SEND:-0}" = 1 ]; then
      exit 1
    fi
    printf '%s' "$last" > "${FM_FAKE_CMUX_LAST_LITERAL:?}"
    ;;
  send-key)
    last=
    for arg in "$@"; do last=$arg; done
    if [ "$last" = enter ] && grep -q '/launch\..*\.sh' "${FM_FAKE_CMUX_LAST_LITERAL:?}" 2>/dev/null; then
      if [ "${FM_FAKE_CMUX_FAIL_LAUNCH_ENTER:-0}" = 1 ]; then
        exit 1
      fi
      : > "${FM_FAKE_CMUX_LAUNCH_MARKER:?}"
      [ ! -e "${FM_STATE_OVERRIDE:?}/${FM_FAKE_CMUX_ID:?}.meta" ] || : > "${FM_FAKE_CMUX_EARLY_META:?}"
      record=$(bash -c '. "$0/bin/fm-busy-lib.sh"; fm_busy_record_read "$1" "$2"' \
        "${FM_FAKE_ROOT:?}" "$FM_STATE_OVERRIDE" "$FM_FAKE_CMUX_ID")
      case "$record" in
        'unknown fm-spawn '*) : ;;
        *) : > "${FM_FAKE_CMUX_EARLY_BUSY:?}" ;;
      esac
      if [ "${FM_FAKE_CMUX_START_PI:-0}" = 1 ]; then
        gen=$(cat "${FM_STATE_OVERRIDE:?}/${FM_FAKE_CMUX_ID:?}.busy-gen")
        "${FM_FAKE_ROOT:?}/bin/fm-busy-event.sh" apply \
          "$FM_STATE_OVERRIDE" "$FM_FAKE_CMUX_ID" busy \
          --gen "$gen" --source pi-ext --event agent-start >/dev/null
      fi
    fi
    ;;
  read-screen)
    text=$(printf '__FM_CMUX_CWD_BEGIN__\n%s\n__FM_CMUX_CWD_END__' "${FM_FAKE_CMUX_WT:?}")
    jq -n --arg text "$text" '{text:$text}'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/pi" "$fakebin/tmux" "$fakebin/cmux"
  printf '%s\n' "$fakebin"
}

make_case() {  # <name> <id>
  local name=$1 id=$2 dir home project copy fakebin
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  project="$dir/project"
  copy="$dir/isolated-copy"
  fm_test_spawn_home "$home" pi
  printf '%s\n' manual > "$home/config/backlog-backend"
  fm_test_spawn_brief "$home" "$id" "Confirm a cmux Pi worker is processing this brief."
  fm_git_init_commit "$project"
  git clone -q "$project" "$copy" || fail "could not clone the isolated fixture copy"
  fakebin=$(make_cmux_pi_fakebin "$dir/fake")
  printf '%s\n' "$dir|$home|$project|$copy|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR COPY_DIR FAKEBIN_DIR <<EOF_CASE
$1
EOF_CASE
}

run_case_spawn() {  # <id> <emit-pi-event> [fail-launch-send] [fail-launch-enter] [reported-path] [confirm-close]
  local id=$1 emit=$2 fail_send=${3:-0} fail_enter=${4:-0} reported_path=${5:-$COPY_DIR} confirm_close=${6:-0}
  FM_FAKE_CMUX_LOG="$CASE_DIR/cmux.log" \
    FM_FAKE_CMUX_LAST_LITERAL="$CASE_DIR/last-literal" \
    FM_FAKE_CMUX_LAUNCH_MARKER="$CASE_DIR/launch-attempted" \
    FM_FAKE_CMUX_EARLY_META="$CASE_DIR/early-meta" \
    FM_FAKE_CMUX_EARLY_BUSY="$CASE_DIR/early-busy" \
    FM_FAKE_CMUX_CLOSED="$CASE_DIR/closed" \
    FM_FAKE_CMUX_CONFIRM_CLOSE="$confirm_close" \
    FM_FAKE_CMUX_FAIL_LAUNCH_SEND="$fail_send" \
    FM_FAKE_CMUX_FAIL_LAUNCH_ENTER="$fail_enter" \
    FM_FAKE_CMUX_START_PI="$emit" FM_FAKE_CMUX_ID="$id" \
    FM_FAKE_CMUX_WT="$reported_path" FM_FAKE_ROOT="$ROOT" \
    FM_FAKE_TMUX_FALLBACK_LOG="$CASE_DIR/tmux-fallback.log" \
    fm_test_run_spawn "$HOME_DIR" "$COPY_DIR" "$FAKEBIN_DIR" \
      "$id" "$PROJECT_DIR" --scout --harness pi --backend cmux
}

assert_cmux_recovery_record() {
  local confirmed=$2 closure=${3:-unverified} record="$HOME_DIR/state/$1.cmux-launch-recovery" contents
  assert_present "$record" "failed cmux Pi launch left no exact endpoint recovery record"
  contents=$(cat "$record")
  assert_contains "$contents" "endpoint=aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" \
    "cmux recovery record lost the exact endpoint"
  assert_contains "$contents" "worktree=$COPY_DIR" \
    "cmux recovery record lost the isolated project copy"
  assert_contains "$contents" "pi_start_confirmed=$confirmed" \
    "cmux recovery record misstates Pi launch confirmation"
  assert_contains "$contents" "closure=$closure" \
    "cmux recovery record misstated the exact endpoint closure"
}

test_spawn_accepts_only_after_pi_agent_start() {
  local fixture out status record
  fixture=$(make_case success "$SUCCESS_ID")
  read_case "$fixture"
  out=$(run_case_spawn "$SUCCESS_ID" 1)
  status=$?
  expect_code 0 "$status" "spawn should accept the cmux endpoint after Pi reports agent_start"$'\n'"$out"
  assert_contains "$out" "spawned $SUCCESS_ID" "spawn did not report the confirmed Pi worker"
  assert_present "$HOME_DIR/state/$SUCCESS_ID.meta" "confirmed Pi spawn did not publish metadata"
  assert_absent "$HOME_DIR/state/$SUCCESS_ID.cmux-launch-recovery" \
    "confirmed Pi spawn left a failed-launch recovery record"
  assert_absent "$CASE_DIR/early-meta" "spawn published metadata before Pi reported processing"
  assert_absent "$CASE_DIR/early-busy" "spawn reported a busy Pi before its lifecycle event"
  assert_present "$CASE_DIR/launch-attempted" "the staged Pi launch was not submitted"
  record=$(bash -c '. "$0/bin/fm-busy-lib.sh"; fm_busy_record_read "$1" "$2"' \
    "$ROOT" "$HOME_DIR/state" "$SUCCESS_ID")
  assert_contains "$record" 'busy pi-ext agent-start' \
    "confirmed Pi spawn did not retain the Pi extension event"
  assert_contains "$(cat "$CASE_DIR/cmux.log")" 'workspace create' \
    "spawn did not use the authoritative cmux workspace create response"
  assert_not_contains "$(cat "$CASE_DIR/cmux.log")" 'new-workspace' \
    "spawn fell back to the deprecated create-then-title-lookup command"
  [ ! -e "$CASE_DIR/tmux-fallback.log" ] || fail "explicit cmux spawn silently invoked tmux"
  pass "fm-spawn accepts a masked cmux workspace only after Pi reports processing the brief"
}

test_spawn_refuses_idle_shell_without_worker_record() {
  local fixture out status
  fixture=$(make_case failure "$FAILURE_ID")
  read_case "$fixture"
  out=$(run_case_spawn "$FAILURE_ID" 0)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a cmux workspace whose Pi launch never started"
  assert_contains "$out" "Pi did not report processing its launch brief" \
    "spawn did not explain the missing Pi readiness evidence"
  assert_contains "$out" "idle shell" \
    "spawn did not identify the visible idle-shell symptom"
  assert_not_contains "$out" "spawned $FAILURE_ID" \
    "spawn pretended an unverified cmux endpoint was live"
  assert_absent "$HOME_DIR/state/$FAILURE_ID.meta" \
    "refused cmux Pi launch left a published worker record"
  assert_cmux_recovery_record "$FAILURE_ID" 0
  assert_absent "$CASE_DIR/early-meta" "unverified Pi launch was visible through metadata during the wait"
  assert_absent "$CASE_DIR/early-busy" "unverified Pi launch was reported busy during the wait"
  assert_present "$CASE_DIR/launch-attempted" \
    "the failure arm did not reach staged Pi launch submission"
  assert_present "$COPY_DIR/README.md" \
    "refused cmux Pi launch lost the isolated project copy"
  assert_contains "$(cat "$CASE_DIR/cmux.log")" \
    'close-workspace --workspace aaaaaaaa-0000-0000-0000-000000000000' \
    "refused cmux Pi launch did not attempt exact endpoint cleanup"
  assert_grep 'idle shell' "$HOME_DIR/state/$FAILURE_ID.status" \
    "refused cmux Pi launch did not leave an actionable failure event"
  [ ! -e "$CASE_DIR/tmux-fallback.log" ] || fail "failed cmux spawn silently invoked tmux"
  pass "fm-spawn refuses an idle cmux shell, attempts exact cleanup, and preserves the unrecorded project copy"
}

test_spawn_refuses_cmux_launch_send_failure() {
  local fixture out status
  fixture=$(make_case send-failure "$SEND_FAILURE_ID")
  read_case "$fixture"
  out=$(run_case_spawn "$SEND_FAILURE_ID" 0 1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a failed cmux Pi launch send"
  assert_contains "$out" "could not submit Pi's staged launch command" \
    "spawn did not report the failed cmux Pi launch send"
  assert_absent "$HOME_DIR/state/$SEND_FAILURE_ID.meta" \
    "failed cmux Pi launch send published a worker record"
  assert_cmux_recovery_record "$SEND_FAILURE_ID" 0
  assert_present "$COPY_DIR/README.md" "failed cmux Pi launch send lost the isolated copy"
  pass "fm-spawn refuses a failed cmux Pi launch send without publishing metadata"
}

test_spawn_refuses_cmux_launch_enter_failure() {
  local fixture out status
  fixture=$(make_case enter-failure "$ENTER_FAILURE_ID")
  read_case "$fixture"
  out=$(run_case_spawn "$ENTER_FAILURE_ID" 0 0 1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a failed cmux Pi Enter"
  assert_contains "$out" "could not submit Pi's staged launch command" \
    "spawn did not report the failed cmux Pi Enter"
  assert_absent "$HOME_DIR/state/$ENTER_FAILURE_ID.meta" \
    "failed cmux Pi Enter published a worker record"
  assert_cmux_recovery_record "$ENTER_FAILURE_ID" 0
  assert_present "$COPY_DIR/README.md" "failed cmux Pi Enter lost the isolated copy"
  pass "fm-spawn refuses a failed cmux Pi Enter without publishing metadata"
}

test_spawn_closes_started_pi_after_record_publication_failure() {
  local fixture out status
  fixture=$(make_case publish-failure "$PUBLISH_FAILURE_ID")
  read_case "$fixture"
  cat > "$FAKEBIN_DIR/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do target=$arg; done
if [ "$target" = "${FM_STATE_OVERRIDE:?}/${FM_FAKE_CMUX_ID:?}.meta" ]; then
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$FAKEBIN_DIR/mv"
  out=$(run_case_spawn "$PUBLISH_FAILURE_ID" 1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted Pi after its task record failed to publish"
  assert_present "$CASE_DIR/launch-attempted" "the publication failure case did not start Pi"
  assert_contains "$out" "Pi began processing but its task record could not be published" \
    "spawn did not report the post-processing publication failure"
  assert_contains "$(cat "$CASE_DIR/cmux.log")" \
    'close-workspace --workspace aaaaaaaa-0000-0000-0000-000000000000' \
    "spawn did not attempt exact cleanup of Pi after publication failed"
  assert_absent "$HOME_DIR/state/$PUBLISH_FAILURE_ID.meta" \
    "failed publication left a task record"
  assert_cmux_recovery_record "$PUBLISH_FAILURE_ID" 1
  assert_absent "$HOME_DIR/state/$PUBLISH_FAILURE_ID.busy-state" \
    "failed publication left a busy record"
  assert_present "$COPY_DIR/README.md" "failed publication lost the isolated project copy"
  out=$(run_case_spawn "$PUBLISH_FAILURE_ID" 1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn retried a cmux Pi launch with unresolved closure"
  assert_contains "$out" 'has an unresolved cmux launch' \
    "spawn did not refuse a retry while exact endpoint closure remains unverified"
  pass "fm-spawn attempts exact Pi cleanup when post-processing metadata publication fails"
}

test_spawn_retains_exact_recovery_after_dispatch_rollback() {
  local fixture out status
  fixture=$(make_case dispatch-failure "$DISPATCH_FAILURE_ID")
  read_case "$fixture"
  rm -f "$HOME_DIR/config/backlog-backend"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$HOME_DIR/.tasks.toml"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$HOME_DIR/data/backlog.md"
  cat > "$FAKEBIN_DIR/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '0.2.6\n' ;;
  update) printf '%s\n' '--archive-body' ;;
  mv) printf '%s\n' '[<id>...]' ;;
  show) printf 'task:\n  id: %s\n  state: queued\n  held: no\n  blocked: no\n' "${FM_FAKE_CMUX_ID:?}" ;;
  start) printf 'start\n' >> "${FM_FAKE_CMUX_LOG:?}.dispatch"; exit 1 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$FAKEBIN_DIR/tasks-axi"
  out=$(run_case_spawn "$DISPATCH_FAILURE_ID" 1 0 0 "$COPY_DIR" 1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted Pi after both backlog dispatch attempts failed"
  assert_present "$CASE_DIR/launch-attempted" "dispatch failure did not launch Pi"
  [ "$(wc -l < "$CASE_DIR/cmux.log.dispatch")" -eq 2 ] || fail "dispatch failure did not exercise both start attempts"
  assert_contains "$out" 'backlog item could not be moved to In flight' \
    "spawn did not report the failed backlog dispatch"
  assert_cmux_recovery_record "$DISPATCH_FAILURE_ID" 1 confirmed
  assert_contains "$out" 'closure is confirmed' \
    "failed dispatch did not report confirmed endpoint closure"
  assert_absent "$HOME_DIR/state/$DISPATCH_FAILURE_ID.meta" \
    "failed dispatch retained an ordinary worker record"
  assert_absent "$HOME_DIR/state/$DISPATCH_FAILURE_ID.busy-state" \
    "failed dispatch retained an ordinary busy record"
  assert_present "$COPY_DIR/README.md" "failed dispatch lost the isolated project copy"
  assert_contains "$(cat "$CASE_DIR/cmux.log")" \
    'close-workspace --workspace aaaaaaaa-0000-0000-0000-000000000000' \
    "failed dispatch did not attempt exact endpoint cleanup"
  pass "fm-spawn preserves exact cmux recovery after failed backlog dispatch"
}

test_spawn_recovers_exact_endpoint_before_worktree_confirmation() {
  local fixture out status record
  fixture=$(make_case worktree-failure "$WORKTREE_FAILURE_ID")
  read_case "$fixture"
  out=$(run_case_spawn "$WORKTREE_FAILURE_ID" 0 0 0 "$PROJECT_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a cmux Pi endpoint that never entered its isolated copy"
  assert_contains "$out" 'treehouse get did not enter an isolated worktree' \
    "spawn did not reach the worktree discovery refusal"
  record="$HOME_DIR/state/$WORKTREE_FAILURE_ID.cmux-launch-recovery"
  assert_present "$record" "pre-launch abort left no exact endpoint recovery record"
  assert_grep 'endpoint=aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111' "$record" \
    "pre-launch recovery lost the exact cmux endpoint"
  grep -Fx 'worktree=' "$record" >/dev/null \
    || fail "pre-launch recovery claimed an unverified worktree path"
  assert_grep "project=$PROJECT_DIR" "$record" \
    "pre-launch recovery lost the spawning project"
  assert_absent "$HOME_DIR/state/$WORKTREE_FAILURE_ID.meta" \
    "pre-launch abort published an unverified worker"
  assert_present "$COPY_DIR/README.md" "pre-launch abort lost the isolated project copy"
  if out=$(run_case_spawn "$WORKTREE_FAILURE_ID" 0); then
    fail "spawn retried while the early failure's endpoint remained unresolved"
  fi
  assert_contains "$out" 'has an unresolved cmux launch' \
    "pre-launch recovery did not block an unsafe retry"
  pass "fm-spawn retains exact cmux recovery when worktree discovery aborts"
}

test_spawn_propagates_tmux_launch_send_failure() {
  local fixture out status
  fixture=$(make_case tmux-send-failure "$TMUX_FAILURE_ID")
  read_case "$fixture"
  fm_test_fake_tmux_spawn "$FAKEBIN_DIR"
  mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux-base"
  cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    *'/launch.'*'.sh'*) exit 1 ;;
  esac
done
exec "$(dirname "$0")/tmux-base" "$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  out=$(fm_test_run_spawn "$HOME_DIR" "$COPY_DIR" "$FAKEBIN_DIR" \
    "$TMUX_FAILURE_ID" "$PROJECT_DIR" --scout --harness pi --backend tmux)
  status=$?
  [ "$status" -ne 0 ] || fail "tmux spawn accepted a failed launch send"
  assert_not_contains "$out" "spawned $TMUX_FAILURE_ID" \
    "tmux spawn reported success after launch delivery failed"
  assert_absent "$HOME_DIR/state/$TMUX_FAILURE_ID.meta" \
    "failed tmux launch send left a published worker record"
  pass "fm-spawn propagates a non-cmux launch send failure"
}

test_spawn_accepts_only_after_pi_agent_start
test_spawn_refuses_idle_shell_without_worker_record
test_spawn_refuses_cmux_launch_send_failure
test_spawn_refuses_cmux_launch_enter_failure
test_spawn_closes_started_pi_after_record_publication_failure
test_spawn_retains_exact_recovery_after_dispatch_rollback
test_spawn_recovers_exact_endpoint_before_worktree_confirmation
test_spawn_propagates_tmux_launch_send_failure

echo "# all cmux Pi launch confirmation tests passed"
