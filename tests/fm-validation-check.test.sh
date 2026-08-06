#!/usr/bin/env bash
# Behavior tests for registered no-mistakes validation-gate watcher checks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-check-lib.sh"

ARM="$ROOT/bin/fm-validation-check.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
MIGRATE="$ROOT/bin/fm-pr-check-migrate.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
X_LIB="$ROOT/bin/fm-x-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-validation-check)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
REAL_MV=$(command -v mv)

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/root/bin" "$fakebin" "$dir/wt"
  fm_git_init_commit "$dir/wt"
  git -C "$dir/wt" checkout -q -b fm/task-a
  fm_write_meta "$dir/home/state/task-a.meta" \
    'window=firstmate:fm-task-a' \
    'endpoint_task_id=task-a' \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=no-mistakes'
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'axi status')
    [ -z "${FM_TEST_EXECUTED:-}" ] || : > "$FM_TEST_EXECUTED"
    cat "${FM_TEST_STATUS:?}"
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' headRefOid '*) printf '%s\n' deadbeefcafefeed0000000000000000deadbeef ;;
  *) printf '%s\n' "${FM_TEST_GH_STATE:-OPEN}" ;;
esac
SH
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
src=
dst=
for arg in "$@"; do
  src=$dst
  dst=$arg
done
case "$src" in
  */.fm-validation-check.*)
    trust="${dst%.check.sh}.check-trust"
    if [ -n "${FM_TEST_VALIDATION_PUBLISH_LOG:-}" ]; then
      if [ -f "$trust" ] && [ ! -e "$dst" ]; then
        printf 'trust-first\n' > "$FM_TEST_VALIDATION_PUBLISH_LOG"
      else
        printf 'incomplete\n' > "$FM_TEST_VALIDATION_PUBLISH_LOG"
      fi
    fi
    if [ -n "${FM_TEST_VALIDATION_BLOCK_READY:-}" ]; then
      : > "$FM_TEST_VALIDATION_BLOCK_READY"
      while [ ! -e "${FM_TEST_VALIDATION_RELEASE:?}" ]; do sleep 0.02; done
    fi
    [ -z "${FM_TEST_VALIDATION_FAIL_SOURCE_MOVE:-}" ] || exit 1
    ;;
  */.fm-pr-poll-check.*)
    if [ -n "${FM_TEST_PR_POLL_BLOCK_READY:-}" ]; then
      : > "$FM_TEST_PR_POLL_BLOCK_READY"
      while [ ! -e "${FM_TEST_PR_POLL_BLOCK_RELEASE:?}" ]; do sleep 0.02; done
    fi
    if [ -n "${FM_TEST_PR_POLL_INTERRUPT_PARENT:-}" ]; then
      kill -TERM "$PPID"
      exit 1
    fi
    ;;
  */*.meta.fm-x.*)
    if [ -n "${FM_TEST_X_META_BLOCK_READY:-}" ]; then
      : > "$FM_TEST_X_META_BLOCK_READY"
      while [ ! -e "${FM_TEST_X_META_BLOCK_RELEASE:?}" ]; do sleep 0.02; done
    fi
    ;;
esac
exec "${FM_TEST_REAL_MV:-/bin/mv}" "$@"
SH
  cat > "$dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/gh" "$fakebin/mv" "$dir/root/bin/fm-guard.sh"
  printf '%s\n' "$dir"
}

run_arm() {
  local dir=$1
  FM_TEST_REAL_MV="$REAL_MV" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" PATH="$dir/fakebin:$BASE_PATH" \
    "$ARM" task-a
}

run_poll() {
  local dir=$1 status=$2
  FM_TEST_STATUS="$status" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    PATH="$dir/fakebin:$BASE_PATH" bash "$dir/home/state/task-a.check.sh"
}

write_owned_status() {
  local dir=$1 status=$2
  shift 2
  {
    printf 'id: run-owned\n'
    printf 'branch: %s\n' "$(git -C "$dir/wt" symbolic-ref --quiet --short HEAD)"
    printf 'head: %s\n' "$(git -C "$dir/wt" rev-parse HEAD)"
    printf '%s\n' "$@"
  } > "$status"
}

test_arms_a_private_registered_check_and_stays_quiet_when_healthy() {
  local dir status out i
  dir=$(make_case healthy)
  status="$dir/status"
  write_owned_status "$dir" "$status" 'status: running' 'awaiting_agent: working 2m'

  run_arm "$dir" >/dev/null || fail "could not arm a validation check"
  [ "$(file_mode "$dir/home/state/task-a.check.sh")" = 700 ] \
    || fail "validation check was not mode 0700"
  fm_custom_check_registered "$dir/home/state" task-a \
    || fail "validation check was not registered before it could run"

  for i in 1 2 3 4 5; do
    out=$(run_poll "$dir" "$status") || fail "healthy validation poll exited non-zero"
    [ -z "$out" ] || fail "healthy validation poll emitted on pass $i: $out"
  done
  pass "validation check is registered and silent for healthy runs"
}

test_wakes_only_for_terminal_or_over_age_parked_runs() {
  local dir status out terminal
  dir=$(make_case wake-conditions)
  status="$dir/status"
  run_arm "$dir" >/dev/null || fail "could not arm wake-condition check"

  for terminal in passed failed cancelled completed; do
    write_owned_status "$dir" "$status" "status: $terminal"
    out=$(run_poll "$dir" "$status") || fail "terminal validation poll failed for $terminal"
    [ "$out" = "validation: terminal $terminal" ] \
      || fail "terminal $terminal did not produce its one actionable line: $out"
  done

  write_owned_status "$dir" "$status" 'status: running' 'outcome: passed'
  out=$(run_poll "$dir" "$status") || fail "terminal outcome validation poll failed"
  [ "$out" = 'validation: terminal passed' ] \
    || fail "terminal outcome did not produce its one actionable line: $out"

  write_owned_status "$dir" "$status" 'status: running' 'outcome: checks-passed'
  out=$(run_poll "$dir" "$status") || fail "checks-passed validation poll failed"
  [ -z "$out" ] || fail "checks-passed is not a validation-gate wake condition: $out"

  write_owned_status "$dir" "$status" 'status: running' 'awaiting_agent: parked 4m'
  out=$(run_poll "$dir" "$status") || fail "equal-threshold validation poll failed"
  [ -z "$out" ] || fail "equal threshold parked run woke early: $out"

  write_owned_status "$dir" "$status" 'status: running' 'awaiting_agent: parked 5m'
  out=$(run_poll "$dir" "$status") || fail "parked validation poll failed"
  [ "$out" = 'validation: awaiting_agent parked 300s' ] \
    || fail "over-age parked run did not produce one actionable line: $out"

  write_owned_status "$dir" "$status" 'status: running' 'awaiting_agent: parked 301s'
  out=$(FM_VALIDATION_PARKED_SECS=300 run_poll "$dir" "$status") \
    || fail "configured-threshold validation poll failed"
  [ "$out" = 'validation: awaiting_agent parked 301s' ] \
    || fail "configured parked threshold was not honored: $out"

  write_owned_status "$dir" "$status" 'status: running' 'awaiting_agent: parked 4m1s'
  out=$(run_poll "$dir" "$status") || fail "compound parked validation poll failed"
  [ "$out" = 'validation: awaiting_agent parked 241s' ] \
    || fail "compound parked duration was not parsed: $out"
  pass "validation check wakes only for terminal and over-age parked runs"
}

test_ignores_runs_not_owned_by_the_task_worktree() {
  local dir status out own_head foreign_head
  dir=$(make_case own-run-binding)
  status="$dir/status"
  run_arm "$dir" >/dev/null || fail "could not arm ownership-binding check"
  own_head=$(git -C "$dir/wt" rev-parse HEAD)

  printf 'id: run-other-branch\nbranch: fm/other\nhead: %s\nstatus: passed\n' "$own_head" > "$status"
  out=$(run_poll "$dir" "$status") || fail "foreign-branch validation poll failed"
  [ -z "$out" ] || fail "foreign branch woke validation supervision: $out"

  git -C "$dir/wt" checkout -q --orphan fm/other
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m foreign
  foreign_head=$(git -C "$dir/wt" rev-parse HEAD)
  git -C "$dir/wt" checkout -q fm/task-a
  printf 'id: run-foreign-head\nbranch: fm/task-a\nhead: %s\nstatus: failed\n' "$foreign_head" > "$status"
  out=$(run_poll "$dir" "$status") || fail "foreign-head validation poll failed"
  [ -z "$out" ] || fail "foreign head woke validation supervision: $out"
  pass "validation polling binds terminal results to the task worktree"
}

test_publishes_trust_before_the_validation_source() {
  local dir publication
  dir=$(make_case trust-before-source)
  publication="$dir/publication"
  FM_TEST_REAL_MV="$REAL_MV" FM_TEST_VALIDATION_PUBLISH_LOG="$publication" \
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" PATH="$dir/fakebin:$BASE_PATH" \
    "$ARM" task-a >/dev/null || fail "could not arm trust-order check"
  [ "$(cat "$publication")" = trust-first ] \
    || fail "validation source became visible before its trust binding"
  fm_custom_check_registered "$dir/home/state" task-a \
    || fail "trust-first publication did not finish registered"
  pass "validation source becomes visible only after its trust binding"
}

test_failed_validation_publication_leaves_no_mismatched_registration() {
  local dir status out rc=0
  dir=$(make_case validation-publication-rollback)
  status="$dir/status"
  write_owned_status "$dir" "$status" 'status: running' 'awaiting_agent: working 2m'
  out=$(FM_TEST_REAL_MV="$REAL_MV" FM_TEST_VALIDATION_FAIL_SOURCE_MOVE=1 \
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" PATH="$dir/fakebin:$BASE_PATH" \
    "$ARM" task-a 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "forced validation source publication failure unexpectedly succeeded"
  assert_absent "$dir/home/state/task-a.check.sh" \
    "failed validation source publication left a runnable check"
  assert_absent "$dir/home/state/task-a.check-trust" \
    "failed validation source publication left a mismatched trust binding"
  rc=0
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" FM_TEST_STATUS="$status" \
    FM_POLL=1 FM_CHECK_INTERVAL=1 FM_SIGNAL_GRACE=1 PATH="$dir/fakebin:$BASE_PATH" \
    "$CHECKPOINT" --seconds 2 2>&1) || rc=$?
  case "$rc" in
    0|124) ;;
    *) fail "validation rollback checkpoint exited $rc: $out" ;;
  esac
  assert_not_contains "$out" 'rejected unauthenticated state checks' \
    "failed validation publication caused a false watcher rejection"
  pass "failed validation publication rolls back source and trust together"
}

test_fails_silent_when_a_local_status_read_is_unavailable_or_unparseable() {
  local dir status out empty_path
  dir=$(make_case silent-failures)
  status="$dir/status"
  run_arm "$dir" >/dev/null || fail "could not arm silent-failure check"

  empty_path="$dir/empty-path"
  mkdir "$empty_path"
  out=$(FM_TEST_STATUS="$status" PATH="$empty_path" /bin/bash "$dir/home/state/task-a.check.sh") \
    || fail "missing no-mistakes did not fail silent"
  [ -z "$out" ] || fail "missing no-mistakes emitted: $out"

  printf 'this is not no-mistakes status output\n' > "$status"
  out=$(run_poll "$dir" "$status") || fail "unparseable status did not fail silent"
  [ -z "$out" ] || fail "unparseable status emitted: $out"

  rm -rf "$dir/wt"
  out=$(run_poll "$dir" "$status") || fail "missing worktree did not fail silent"
  [ -z "$out" ] || fail "missing worktree emitted: $out"
  pass "validation check fails silent on unavailable or invalid local state"
}

test_watcher_does_not_execute_an_unregistered_validation_check() {
  local dir status marker out rc
  dir=$(make_case unregistered)
  status="$dir/status"
  marker="$dir/executed"
  write_owned_status "$dir" "$status" 'status: running' 'awaiting_agent: parked 5m'
  run_arm "$dir" >/dev/null || fail "could not arm unregistered-check fixture"
  rm -f "$dir/home/state/task-a.check-trust"

  rc=0
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" FM_TEST_STATUS="$status" \
    FM_TEST_EXECUTED="$marker" FM_POLL=1 FM_CHECK_INTERVAL=1 FM_SIGNAL_GRACE=1 \
    PATH="$dir/fakebin:$BASE_PATH" "$CHECKPOINT" --seconds 2 2>&1) || rc=$?
  case "$rc" in
    0|124) ;;
    *) fail "watcher rejected-check fixture exited $rc: $out" ;;
  esac
  [ ! -e "$marker" ] || fail "watcher executed a validation check after its trust binding was removed"
  pass "watcher refuses an unregistered validation check without executing it"
}

test_pr_merge_poll_replaces_and_outprioritizes_validation_poll() {
  local dir status out
  dir=$(make_case pr-transition)
  status="$dir/status"
  write_owned_status "$dir" "$status" 'status: passed'
  run_arm "$dir" >/dev/null || fail "could not arm validation half of transition"
  out=$(run_poll "$dir" "$status") || fail "validation half of transition failed"
  [ "$out" = 'validation: terminal passed' ] \
    || fail "validation half did not wake before PR hand-off: $out"

  FM_TEST_REAL_MV="$REAL_MV" FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" task-a https://github.com/example/repo/pull/9 >/dev/null \
    || fail "could not publish PR merge poll over validation check"
  fm_pr_poll_artifacts_valid "$dir/home/state" task-a "$POLL" \
    || fail "PR hand-off did not leave an authenticated merge poll"
  out=$(FM_TEST_GH_STATE=MERGED PATH="$dir/fakebin:$BASE_PATH" bash "$dir/home/state/task-a.check.sh") \
    || fail "published merge poll did not run"
  [ "$out" = merged ] || fail "merge poll did not replace validation behavior: $out"

  out=$(run_arm "$dir") || fail "validation armer refused a PR-owned check slot"
  assert_contains "$out" 'reserved for PR merge polling' \
    "validation armer did not disclose PR poll precedence"
  fm_pr_poll_artifacts_valid "$dir/home/state" task-a "$POLL" \
    || fail "validation armer displaced the PR merge poll"
  out=$(FM_TEST_GH_STATE=MERGED PATH="$dir/fakebin:$BASE_PATH" bash "$dir/home/state/task-a.check.sh") \
    || fail "merge poll did not run after reverse-order arming attempt"
  [ "$out" = merged ] || fail "reverse-order arming changed merge poll behavior: $out"
  pass "validation and PR poll hand-off preserves merge-poll priority in both orders"
}

test_pr_publication_wins_over_an_inflight_validation_arm() {
  local dir ready release validation_pid pr_pid attempt=0
  dir=$(make_case pr-concurrent-transition)
  ready="$dir/validation-ready"
  release="$dir/validation-release"

  FM_TEST_REAL_MV="$REAL_MV" FM_TEST_VALIDATION_BLOCK_READY="$ready" FM_TEST_VALIDATION_RELEASE="$release" \
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" PATH="$dir/fakebin:$BASE_PATH" \
    "$ARM" task-a > "$dir/validation.out" 2> "$dir/validation.err" &
  validation_pid=$!
  while [ "$attempt" -lt 100 ]; do
    [ -e "$ready" ] && break
    sleep 0.02
    attempt=$((attempt + 1))
  done
  if [ ! -e "$ready" ]; then
    : > "$release"
    wait "$validation_pid" 2>/dev/null || true
    fail "validation arm did not reach its slot publication boundary"
  fi

  FM_TEST_REAL_MV="$REAL_MV" FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" task-a https://github.com/example/repo/pull/9 \
    > "$dir/pr.out" 2> "$dir/pr.err" &
  pr_pid=$!
  sleep 0.1
  [ ! -e "$dir/home/state/task-a.pr-poll-registration" ] \
    || fail "PR publication entered the validation-owned check slot"

  : > "$release"
  wait "$validation_pid" || fail "inflight validation arm failed: $(cat "$dir/validation.err")"
  wait "$pr_pid" || fail "PR publication failed after validation release: $(cat "$dir/pr.err")"
  fm_pr_poll_artifacts_valid "$dir/home/state" task-a "$POLL" \
    || fail "PR merge poll did not own the slot after concurrent hand-off"
  pass "concurrent hand-off preserves PR merge poll priority"
}

test_x_metadata_rewrite_serializes_with_pr_publication() {
  local dir state ready release x_pid pr_pid attempt=0
  dir=$(make_case x-metadata-pr-transition)
  state="$dir/home/state"
  run_arm "$dir" >/dev/null || fail "could not arm X metadata transition fixture"
  ready="$dir/x-meta-ready"
  release="$dir/x-meta-release"

  FM_TEST_REAL_MV="$REAL_MV" FM_TEST_X_META_BLOCK_READY="$ready" FM_TEST_X_META_BLOCK_RELEASE="$release" \
    PATH="$dir/fakebin:$BASE_PATH" bash -c \
    '. "$1"; fmx_meta_link_set "$2/task-a.meta" req-x 1700000000' _ "$X_LIB" "$state" \
    > "$dir/x.out" 2> "$dir/x.err" &
  x_pid=$!
  while [ "$attempt" -lt 100 ]; do
    [ -e "$ready" ] && break
    sleep 0.02
    attempt=$((attempt + 1))
  done
  if [ ! -e "$ready" ]; then
    : > "$release"
    wait "$x_pid" 2>/dev/null || true
    fail "X metadata rewrite did not reach its check-slot boundary"
  fi

  FM_TEST_REAL_MV="$REAL_MV" FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" task-a https://github.com/example/repo/pull/9 \
    > "$dir/pr.out" 2> "$dir/pr.err" &
  pr_pid=$!
  sleep 0.1
  assert_absent "$state/task-a.pr-poll-registration" \
    "PR publication entered an X-owned metadata boundary"

  : > "$release"
  wait "$x_pid" || fail "X metadata rewrite failed: $(cat "$dir/x.err")"
  wait "$pr_pid" || fail "PR publication failed after X metadata release: $(cat "$dir/pr.err")"
  assert_grep 'x_request=req-x' "$state/task-a.meta" \
    "PR publication dropped the completed X metadata rewrite"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
    || fail "X metadata rewrite displaced the registered PR merge poll"
  pass "X metadata rewrites share the PR publication boundary"
}

test_custom_registration_and_migration_preserve_pr_poll_priority() {
  local dir state out
  dir=$(make_case custom-registration-priority)
  state="$dir/home/state"
  run_arm "$dir" >/dev/null || fail "could not arm validation check before PR hand-off"
  FM_TEST_REAL_MV="$REAL_MV" FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" task-a https://github.com/example/repo/pull/9 >/dev/null \
    || fail "could not arm PR merge poll before custom registration attempt"

  printf '#!/usr/bin/env bash\nprintf "%s\\n" custom-ran\n' > "$state/task-a.check.sh"
  chmod 0700 "$state/task-a.check.sh"
  out=$(FM_TEST_REAL_MV="$REAL_MV" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    PATH="$dir/fakebin:$BASE_PATH" "$REGISTER" task-a) \
    || fail "custom registration did not preserve the recorded PR poll"
  assert_contains "$out" 'reserved for PR merge polling' \
    "custom registration did not disclose PR poll precedence"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
    || fail "custom registration displaced the recorded PR merge poll"

  printf '#!/usr/bin/env bash\nprintf "%s\\n" custom-ran\n' > "$state/task-a.check.sh"
  chmod 0700 "$state/task-a.check.sh"
  fm_custom_check_register_source "$state" task-a "$state/task-a.check.sh" \
    || fail "could not construct the legacy registered-custom fixture"
  fm_custom_check_registered "$state" task-a \
    || fail "legacy registered-custom fixture was not authenticated"
  FM_TEST_REAL_MV="$REAL_MV" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    PATH="$dir/fakebin:$BASE_PATH" "$MIGRATE" --checks-safe >/dev/null \
    || fail "migration did not recover PR poll priority from a registered custom source"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
    || fail "migration preserved a registered custom source over the recorded PR poll"
  pass "custom registration and migration preserve PR merge poll priority"
}

test_no_mistakes_validation_ownership_rearms_custom_replacements() {
  local dir state status marker out
  dir=$(make_case validation-ownership)
  state="$dir/home/state"
  status="$dir/status"
  marker="$dir/custom-ran"
  write_owned_status "$dir" "$status" 'status: running' 'awaiting_agent: working 2m'
  run_arm "$dir" >/dev/null || fail "could not arm validation ownership fixture"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf ': > %q\n' "$marker"
  } > "$state/task-a.check.sh"
  chmod 0700 "$state/task-a.check.sh"
  out=$(FM_TEST_REAL_MV="$REAL_MV" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    PATH="$dir/fakebin:$BASE_PATH" "$REGISTER" task-a) \
    || fail "custom registration did not restore validation ownership"
  assert_contains "$out" 'armed: state/task-a.check.sh' \
    "custom registration did not hand the slot back to validation"
  fm_validation_check_registered "$state" task-a "$ROOT/bin/fm-nm-run-lib.sh" "$ROOT/bin/fm-validation-poll.sh" \
    || fail "custom registration displaced the validation gate"
  run_poll "$dir" "$status" >/dev/null || fail "restored validation gate did not run"
  [ ! -e "$marker" ] || fail "restored validation gate executed the custom replacement"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf ': > %q\n' "$marker"
  } > "$state/task-a.check.sh"
  chmod 0700 "$state/task-a.check.sh"
  fm_custom_check_register_source "$state" task-a "$state/task-a.check.sh" \
    || fail "could not construct a registered custom replacement"
  FM_TEST_REAL_MV="$REAL_MV" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    PATH="$dir/fakebin:$BASE_PATH" "$MIGRATE" --checks-safe >/dev/null \
    || fail "migration did not restore validation ownership"
  fm_validation_check_registered "$state" task-a "$ROOT/bin/fm-nm-run-lib.sh" "$ROOT/bin/fm-validation-poll.sh" \
    || fail "migration preserved a custom replacement over validation"
  run_poll "$dir" "$status" >/dev/null || fail "migrated validation gate did not run"
  [ ! -e "$marker" ] || fail "migrated validation gate executed the custom replacement"
  pass "no-mistakes validation ownership survives custom registration and migration"
}

test_migration_marker_rearms_a_missing_validation_gate() {
  local dir state
  dir=$(make_case migration-marker-validation-repair)
  state="$dir/home/state"
  run_arm "$dir" >/dev/null || fail "could not arm migration-marker validation fixture"
  FM_TEST_REAL_MV="$REAL_MV" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    PATH="$dir/fakebin:$BASE_PATH" "$MIGRATE" --checks-safe >/dev/null \
    || fail "could not establish the completed migration marker"
  [ -f "$state/.pr-check-migration-v1" ] \
    || fail "migration fixture did not establish its completion marker"
  rm -f "$state/task-a.check.sh" "$state/task-a.check-trust"
  FM_TEST_REAL_MV="$REAL_MV" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    PATH="$dir/fakebin:$BASE_PATH" "$MIGRATE" --checks-safe >/dev/null \
    || fail "migration did not repair a missing reserved validation gate"
  fm_validation_check_registered "$state" task-a "$ROOT/bin/fm-nm-run-lib.sh" "$ROOT/bin/fm-validation-poll.sh" \
    || fail "a completed migration marker left a no-mistakes ship unarmed"
  pass "migration markers remain incomplete until reserved validation gates are armed"
}

test_migration_rearms_an_expected_source_with_invalid_trust() {
  local dir state
  dir=$(make_case migration-invalid-validation-trust)
  state="$dir/home/state"
  run_arm "$dir" >/dev/null || fail "could not arm invalid-trust migration fixture"
  rm -f "$state/task-a.check-trust"

  FM_TEST_REAL_MV="$REAL_MV" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    PATH="$dir/fakebin:$BASE_PATH" "$MIGRATE" --checks-safe >/dev/null \
    || fail "migration did not repair an expected validation source with missing trust"
  fm_validation_check_registered "$state" task-a "$ROOT/bin/fm-nm-run-lib.sh" "$ROOT/bin/fm-validation-poll.sh" \
    || fail "migration left an expected validation source unregistered"
  pass "migration rearms expected validation sources with invalid trust"
}

test_migration_repairs_unlocked_validation_gates_during_other_handoffs() {
  local dir state ready release holder_pid attempt=0
  dir=$(make_case migration-unrelated-live-slot)
  state="$dir/home/state"
  ready="$dir/slot-ready"
  release="$dir/slot-release"
  (
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state"
    . "$ROOT/bin/fm-pr-lib.sh"
    . "$ROOT/bin/fm-check-lib.sh"
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_custom_check_slot_acquire "$state" task-b 100 || exit 1
    : > "$ready"
    while [ ! -e "$release" ]; do sleep 0.02; done
    fm_custom_check_slot_release
  ) &
  holder_pid=$!
  while [ "$attempt" -lt 100 ]; do
    [ -e "$ready" ] && break
    sleep 0.02
    attempt=$((attempt + 1))
  done
  if [ ! -e "$ready" ]; then
    : > "$release"
    wait "$holder_pid" 2>/dev/null || true
    fail "unrelated live-slot fixture did not acquire its task slot"
  fi

  FM_TEST_REAL_MV="$REAL_MV" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    PATH="$dir/fakebin:$BASE_PATH" "$MIGRATE" --checks-safe >/dev/null || {
      : > "$release"
      wait "$holder_pid" 2>/dev/null || true
      fail "migration did not repair an unlocked validation gate during another handoff"
    }
  fm_validation_check_registered "$state" task-a "$ROOT/bin/fm-nm-run-lib.sh" "$ROOT/bin/fm-validation-poll.sh" \
    || {
      : > "$release"
      wait "$holder_pid" 2>/dev/null || true
      fail "an unrelated task slot left the validation gate unarmed"
    }
  : > "$release"
  wait "$holder_pid" || fail "unrelated live-slot fixture did not release its task slot"
  pass "migration repairs unlocked validation gates during other handoffs"
}

test_watcher_skips_a_live_pr_publication_slot() {
  local dir state status ready release pr_pid attempt=0 out rc=0
  dir=$(make_case watcher-live-pr-publication)
  state="$dir/home/state"
  status="$dir/status"
  ready="$dir/pr-poll-ready"
  release="$dir/pr-poll-release"
  write_owned_status "$dir" "$status" 'status: running' 'awaiting_agent: working 2m'
  run_arm "$dir" >/dev/null || fail "could not arm watcher hand-off fixture"

  FM_TEST_REAL_MV="$REAL_MV" FM_TEST_PR_POLL_BLOCK_READY="$ready" FM_TEST_PR_POLL_BLOCK_RELEASE="$release" \
    FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" task-a https://github.com/example/repo/pull/9 \
    > "$dir/pr.out" 2> "$dir/pr.err" &
  pr_pid=$!
  while [ "$attempt" -lt 100 ]; do
    [ -e "$ready" ] && break
    sleep 0.02
    attempt=$((attempt + 1))
  done
  if [ ! -e "$ready" ]; then
    : > "$release"
    wait "$pr_pid" 2>/dev/null || true
    fail "PR publication did not reach its final source hand-off"
  fi

  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_TEST_STATUS="$status" \
    FM_POLL=1 FM_CHECK_INTERVAL=1 FM_SIGNAL_GRACE=1 PATH="$dir/fakebin:$BASE_PATH" \
    "$CHECKPOINT" --seconds 2 2>&1) || rc=$?
  case "$rc" in
    0|124) ;;
    *)
      : > "$release"
      wait "$pr_pid" 2>/dev/null || true
      fail "watcher hand-off checkpoint exited $rc: $out"
      ;;
  esac
  assert_not_contains "$out" 'rejected unauthenticated state checks' \
    "watcher rejected a PR hand-off while the publisher held its task slot"
  : > "$release"
  wait "$pr_pid" || fail "PR publication did not finish after watcher checkpoint: $(cat "$dir/pr.err")"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
    || fail "watcher hand-off fixture did not finish with a valid PR merge poll"
  pass "watcher skips PR publication while its task slot is live"
}

test_interrupted_pr_publication_restores_validation_gate() {
  local dir state status out rc=0
  dir=$(make_case interrupted-pr-publication)
  state="$dir/home/state"
  status="$dir/status"
  write_owned_status "$dir" "$status" 'status: running' 'awaiting_agent: working 2m'
  run_arm "$dir" >/dev/null || fail "could not arm interrupted PR publication fixture"

  out=$(FM_TEST_REAL_MV="$REAL_MV" FM_TEST_PR_POLL_INTERRUPT_PARENT=1 \
    FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" task-a https://github.com/example/repo/pull/9 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "interrupted PR publication unexpectedly succeeded"
  assert_no_grep '^pr=' "$state/task-a.meta" \
    "interrupted PR publication left metadata claiming an unavailable merge poll"
  fm_validation_check_registered "$state" task-a "$ROOT/bin/fm-nm-run-lib.sh" "$ROOT/bin/fm-validation-poll.sh" \
    || fail "interrupted PR publication did not restore the validation gate"
  rc=0
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_TEST_STATUS="$status" \
    FM_POLL=1 FM_CHECK_INTERVAL=1 FM_SIGNAL_GRACE=1 PATH="$dir/fakebin:$BASE_PATH" \
    "$CHECKPOINT" --seconds 2 2>&1) || rc=$?
  case "$rc" in
    0|124) ;;
    *) fail "interrupted PR checkpoint exited $rc: $out" ;;
  esac
  assert_not_contains "$out" 'rejected unauthenticated state checks' \
    "interrupted PR publication caused a false watcher rejection"
  pass "interrupted PR publication restores the prior validation gate"
}

test_migration_defers_a_live_check_slot() {
  local dir state ready release holder_pid attempt=0 source_hash
  dir=$(make_case migration-live-slot)
  state="$dir/home/state"
  run_arm "$dir" >/dev/null || fail "could not arm validation check before PR hand-off"
  FM_TEST_REAL_MV="$REAL_MV" FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" task-a https://github.com/example/repo/pull/9 >/dev/null \
    || fail "could not arm PR merge poll before migration deferral"

  printf '#!/usr/bin/env bash\nprintf "%s\\n" stale-custom\n' > "$state/task-a.check.sh"
  chmod 0700 "$state/task-a.check.sh"
  source_hash=$(fm_custom_check_sha256 "$state/task-a.check.sh")
  ready="$dir/slot-ready"
  release="$dir/slot-release"
  (
    . "$ROOT/bin/fm-pr-lib.sh"
    . "$ROOT/bin/fm-check-lib.sh"
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_custom_check_slot_acquire "$state" task-a 100 || exit 1
    : > "$ready"
    while [ ! -e "$release" ]; do sleep 0.02; done
    fm_custom_check_slot_release
  ) &
  holder_pid=$!
  while [ "$attempt" -lt 100 ]; do
    [ -e "$ready" ] && break
    sleep 0.02
    attempt=$((attempt + 1))
  done
  if [ ! -e "$ready" ]; then
    : > "$release"
    wait "$holder_pid" 2>/dev/null || true
    fail "live-slot migration fixture did not acquire the task slot"
  fi

  FM_TEST_REAL_MV="$REAL_MV" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    PATH="$dir/fakebin:$BASE_PATH" "$MIGRATE" --checks-safe >/dev/null || {
      : > "$release"
      wait "$holder_pid" 2>/dev/null || true
      fail "migration did not defer the live task slot"
    }
  [ "$(fm_custom_check_sha256 "$state/task-a.check.sh")" = "$source_hash" ] || {
    : > "$release"
    wait "$holder_pid" 2>/dev/null || true
    fail "migration changed a check while its task slot was live"
  }
  : > "$release"
  wait "$holder_pid" || fail "live-slot migration fixture did not release the task slot"
  FM_TEST_REAL_MV="$REAL_MV" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    PATH="$dir/fakebin:$BASE_PATH" "$MIGRATE" --checks-safe >/dev/null \
    || fail "migration did not retry after the task slot released"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
    || fail "migration did not restore the PR merge poll after the task slot released"
  pass "migration defers live task slots before rebuilding PR polls"
}

test_arms_a_private_registered_check_and_stays_quiet_when_healthy
test_wakes_only_for_terminal_or_over_age_parked_runs
test_ignores_runs_not_owned_by_the_task_worktree
test_publishes_trust_before_the_validation_source
test_failed_validation_publication_leaves_no_mismatched_registration
test_fails_silent_when_a_local_status_read_is_unavailable_or_unparseable
test_watcher_does_not_execute_an_unregistered_validation_check
test_pr_merge_poll_replaces_and_outprioritizes_validation_poll
test_pr_publication_wins_over_an_inflight_validation_arm
test_x_metadata_rewrite_serializes_with_pr_publication
test_custom_registration_and_migration_preserve_pr_poll_priority
test_no_mistakes_validation_ownership_rearms_custom_replacements
test_migration_marker_rearms_a_missing_validation_gate
test_migration_rearms_an_expected_source_with_invalid_trust
test_migration_repairs_unlocked_validation_gates_during_other_handoffs
test_watcher_skips_a_live_pr_publication_slot
test_interrupted_pr_publication_restores_validation_gate
test_migration_defers_a_live_check_slot
