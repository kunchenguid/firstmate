#!/usr/bin/env bash
# Behavior tests for bin/fm-notify.sh, the best-effort Discord review-ready
# notifier: message assembly and summary fallbacks, absent-webhook inertness,
# best-effort POST failure, per-PR idempotence, webhook non-disclosure, and the
# fm-pr-check.sh trigger wiring.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOTIFY="$ROOT/bin/fm-notify.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-notify)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
WEBHOOK='https://discord.example/api/webhooks/999/SECRETTOKEN'

make_home() {  # <name>
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data" "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TEST_GH_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
[ "${FM_TEST_GH_FAIL:-0}" = 0 ] || exit 1
case " $* " in
  *" headRefOid "*) printf '%s\n' "${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}" ;;
  *" --json title "*) printf '%s\n' "${FM_TEST_GH_TITLE:-Implement the widget}" ;;
esac
exit 0
SH
  cat > "$fakebin/glab" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TEST_GLAB_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_TEST_GLAB_LOG"
[ "${FM_TEST_GLAB_FAIL:-0}" = 0 ] || exit 1
printf 'title:\t%s\n' "${FM_TEST_GLAB_TITLE:-GitLab merge request title}"
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "${FM_TEST_TASKS_AXI_FAIL:-0}" = 0 ] || exit 1
printf 'task:\n  id: %s\n  title: "%s"\n' "${2:-task}" "${FM_TEST_BACKLOG_TITLE:-Backlog title}"
SH
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
cat > "$FM_TEST_CURL_STDIN"
url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$FM_TEST_CURL_STDIN" | head -1)
data=$(sed -n 's/^data-binary = "@\(.*\)"$/\1/p' "$FM_TEST_CURL_STDIN" | head -1)
printf 'CALL %s\n' "$url" >> "$FM_TEST_CURL_LOG"
if [ -n "$data" ] && [ -f "$data" ]; then cp "$data" "$FM_TEST_CURL_BODY"; fi
exit "${FM_TEST_CURL_RC:-0}"
SH
  chmod +x "$fakebin/gh" "$fakebin/glab" "$fakebin/tasks-axi" "$fakebin/curl"
  : > "$dir/curl.log"
  printf '%s\n' "$WEBHOOK" > "$dir/home/config/discord-webhook"
  chmod 0600 "$dir/home/config/discord-webhook"
  printf '%s\n' "$dir"
}

run_notify() {  # <dir> <args...>
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_CURL_LOG="$dir/curl.log" FM_TEST_CURL_STDIN="$dir/curl.stdin" \
    FM_TEST_CURL_BODY="$dir/curl.body" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$NOTIFY" "$@"
}

curl_calls() {  # <dir>
  grep -c '^CALL ' "$1/curl.log" 2>/dev/null || true
}

body_content() {  # <dir>
  [ -f "$1/curl.body" ] || fail "the notifier made no POST body to inspect"
  perl -MJSON::PP -e 'local $/; my $d = decode_json(<STDIN>); print $d->{content}' < "$1/curl.body"
}

test_message_assembly_and_idempotence() {
  local dir rc out body marker
  dir=$(make_home github-ready)
  set +e
  out=$(FM_TEST_GH_TITLE='Add the new widget' run_notify "$dir" task-ready task-a \
    https://github.com/o/r/pull/42 2> "$dir/stderr")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "notify failed: rc=$rc $(cat "$dir/stderr")"
  [ -z "$out" ] || fail "notify wrote to stdout: $out"
  [ "$(curl_calls "$dir")" -eq 1 ] || fail "notify did not POST exactly once"
  [ "$(sed -n '1p' "$dir/curl.log")" = "CALL $WEBHOOK" ] \
    || fail "notify did not address the configured webhook"

  body=$(body_content "$dir")
  [ "$body" = "$(printf 'PR ready for review: task-a\nAdd the new widget\nhttps://github.com/o/r/pull/42')" ] \
    || fail "notification message was not the expected header, summary, and URL: $body"

  marker="$dir/home/state/task-a.pr-notified"
  [ -f "$marker" ] || fail "notify did not record a notification marker"
  [ "$(stat -c %a "$marker" 2>/dev/null || stat -f %Lp "$marker")" = 600 ] \
    || fail "notification marker was not private"
  [ "$(cat "$marker")" = "$(printf 'fm-pr-poll-ready-notified-v1\ngithub\ngithub.com\no/r\n42')" ] \
    || fail "notification marker identity was not exact"

  # A second run for the same PR is a no-op.
  FM_TEST_GH_TITLE='Add the new widget' run_notify "$dir" task-ready task-a \
    https://github.com/o/r/pull/42 >/dev/null 2>/dev/null || fail "second notify failed"
  [ "$(curl_calls "$dir")" -eq 1 ] || fail "the same PR notified twice"

  # A different PR for the same task notifies on its own first record.
  FM_TEST_GH_TITLE='Follow-up widget' run_notify "$dir" task-ready task-a \
    https://github.com/o/r/pull/43 >/dev/null 2>/dev/null || fail "different-PR notify failed"
  [ "$(curl_calls "$dir")" -eq 2 ] || fail "a different PR for the same task did not notify"
  [ "$(sed -n '5p' "$marker")" = 43 ] || fail "the marker was not advanced to the new PR"

  # The webhook never reaches the notifier's output or this home's records.
  assert_no_grep "$WEBHOOK" "$dir/stderr" "the webhook appeared in notifier stderr"
  assert_no_grep "$WEBHOOK" "$marker" "the webhook appeared in the notification marker"
  ! grep -rF -- "$WEBHOOK" "$dir/home/state" >/dev/null 2>&1 \
    || fail "the webhook appeared in a task record"
  pass "notify assembles the message, records identity, and never notifies the same PR twice"
}

test_summary_fallbacks() {
  local dir body
  dir=$(make_home fallbacks)

  # PR title is preferred.
  body=$(FM_TEST_GH_TITLE='PR title wins' run_notify "$dir" task-ready g1 \
    https://github.com/o/r/pull/1 2>/dev/null; body_content "$dir")
  case "$body" in *'PR title wins'*) ;; *) fail "PR title was not used: $body" ;; esac

  # Fall back to the backlog title when the forge title is unavailable.
  body=$(FM_TEST_GH_FAIL=1 FM_TEST_BACKLOG_TITLE='Backlog title wins' \
    run_notify "$dir" task-ready g2 https://github.com/o/r/pull/2 2>/dev/null; body_content "$dir")
  case "$body" in *'Backlog title wins'*) ;; *) fail "backlog title fallback was not used: $body" ;; esac

  # Fall back to the task id when neither title can be read.
  body=$(FM_TEST_GH_FAIL=1 FM_TEST_TASKS_AXI_FAIL=1 \
    run_notify "$dir" task-ready g3 https://github.com/o/r/pull/3 2>/dev/null; body_content "$dir")
  [ "$body" = "$(printf 'PR ready for review: g3\ng3\nhttps://github.com/o/r/pull/3')" ] \
    || fail "task-id fallback was not used: $body"

  # A GitLab merge request reads its title through glab.
  body=$(FM_TEST_GLAB_TITLE='GitLab title wins' run_notify "$dir" task-ready g4 \
    https://gitlab.example/group/subgroup/project/-/merge_requests/7 2>/dev/null; body_content "$dir")
  case "$body" in *'GitLab title wins'*) ;; *) fail "GitLab title was not used: $body" ;; esac
  pass "notify prefers the PR title, then the backlog title, then the task id"
}

test_absent_and_empty_webhook_are_inert() {
  local dir rc
  dir=$(make_home inert)

  rm -f "$dir/home/config/discord-webhook"
  set +e
  run_notify "$dir" task-ready task-a https://github.com/o/r/pull/1 \
    > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "absent webhook was not a no-op"
  [ "$(curl_calls "$dir")" -eq 0 ] || fail "absent webhook still POSTed"
  [ ! -e "$dir/home/state/task-a.pr-notified" ] || fail "absent webhook recorded a marker"
  [ ! -s "$dir/out" ] && [ ! -s "$dir/err" ] || fail "absent webhook was not silent"

  : > "$dir/home/config/discord-webhook"
  run_notify "$dir" task-ready task-a https://github.com/o/r/pull/1 >/dev/null 2>/dev/null
  [ "$(curl_calls "$dir")" -eq 0 ] || fail "empty webhook still POSTed"
  [ ! -e "$dir/home/state/task-a.pr-notified" ] || fail "empty webhook recorded a marker"
  pass "an absent or empty webhook is a silent no-op"
}

test_post_failure_is_best_effort() {
  local dir rc
  dir=$(make_home post-failure)
  set +e
  FM_TEST_CURL_RC=1 run_notify "$dir" task-ready task-a https://github.com/o/r/pull/1 \
    > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a failed POST did not exit 0"
  [ "$(curl_calls "$dir")" -eq 1 ] || fail "the notifier did not attempt the POST"
  grep -q 'could not send the review-ready notification' "$dir/err" \
    || fail "a failed POST did not warn on stderr"
  assert_no_grep "$WEBHOOK" "$dir/err" "a failed POST leaked the webhook to stderr"
  [ ! -e "$dir/home/state/task-a.pr-notified" ] \
    || fail "a failed POST recorded a notification marker"
  pass "a failing POST logs one warning and exits 0 without recording success"
}

test_long_summary_is_bounded() {
  local dir long body chars
  dir=$(make_home long-summary)
  long=$(head -c 5000 /dev/zero | tr '\0' 'x')
  FM_TEST_GH_TITLE="$long" run_notify "$dir" task-ready task-a \
    https://github.com/o/r/pull/42 >/dev/null 2>/dev/null || fail "long-summary notify failed"
  body=$(body_content "$dir")
  chars=$(printf '%s' "$body" | perl -CS -Mutf8 -e 'local $/; my $s = <STDIN>; print length($s)')
  [ "$chars" -le 2000 ] || fail "message exceeded Discord's limit: $chars characters"
  case "$body" in *'https://github.com/o/r/pull/42'*) ;; *) fail "bounded message dropped the URL" ;; esac
  case "$body" in *'PR ready for review: task-a'*) ;; *) fail "bounded message dropped the heading" ;; esac
  pass "an over-long summary is truncated while the heading and URL survive"
}

test_invalid_requests_are_refused() {
  local dir rc
  dir=$(make_home invalid)
  for args in "task-ready" "task-ready task-a" "other task-a https://github.com/o/r/pull/1"; do
    set +e
    # shellcheck disable=SC2086 # Deliberate word splitting of the argument cases.
    run_notify "$dir" $args > "$dir/out" 2> "$dir/err"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "invalid request was accepted: $args"
  done
  set +e
  run_notify "$dir" task-ready '../escape' https://github.com/o/r/pull/1 > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unsafe task id was accepted"
  [ "$(curl_calls "$dir")" -eq 0 ] || fail "an invalid request reached the webhook"
  pass "invalid task-ready requests are refused before any side effect"
}

make_pr_case() {  # <name>
  local name=$1 dir fakebin fake_root
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  fake_root="$dir/root"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data" "$dir/wt" "$fakebin" "$fake_root/bin"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ "${FM_TEST_GH_FAIL:-0}" = 0 ] || exit 1
case " $* " in
  *" headRefOid "*) printf '%s\n' "${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}" ;;
  *" --json title "*) printf '%s\n' "${FM_TEST_GH_TITLE:-Implement the widget}" ;;
esac
exit 0
SH
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
cat > "$FM_TEST_CURL_STDIN"
url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$FM_TEST_CURL_STDIN" | head -1)
data=$(sed -n 's/^data-binary = "@\(.*\)"$/\1/p' "$FM_TEST_CURL_STDIN" | head -1)
printf 'CALL %s\n' "$url" >> "$FM_TEST_CURL_LOG"
if [ -n "$data" ] && [ -f "$data" ]; then cp "$data" "$FM_TEST_CURL_BODY"; fi
exit "${FM_TEST_CURL_RC:-0}"
SH
  chmod +x "$fakebin/gh" "$fakebin/curl"
  printf '%s\n' "$WEBHOOK" > "$dir/home/config/discord-webhook"
  chmod 0600 "$dir/home/config/discord-webhook"
  : > "$dir/curl.log"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "endpoint_task_id=task-a" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=no-mistakes'
  printf '%s\n' "$dir"
}

test_pr_check_triggers_notification_once() {
  local dir rc
  dir=$(make_pr_case pr-check-wiring)
  set +e
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_CURL_LOG="$dir/curl.log" FM_TEST_CURL_STDIN="$dir/curl.stdin" \
    FM_TEST_CURL_BODY="$dir/curl.body" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" task-a https://github.com/o/r/pull/42 > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "fm-pr-check failed: rc=$rc $(cat "$dir/err")"
  [ "$(curl_calls "$dir")" -eq 1 ] || fail "fm-pr-check did not trigger exactly one notification"
  [ -f "$dir/home/state/task-a.pr-notified" ] || fail "fm-pr-check did not record the notification"

  # Re-arming the same PR must not notify again.
  set +e
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_CURL_LOG="$dir/curl.log" FM_TEST_CURL_STDIN="$dir/curl.stdin" \
    FM_TEST_CURL_BODY="$dir/curl.body" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" task-a https://github.com/o/r/pull/42 > "$dir/out2" 2> "$dir/err2"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "re-arming fm-pr-check failed: rc=$rc"
  [ "$(curl_calls "$dir")" -eq 1 ] || fail "re-arming the same PR notified a second time"
  pass "fm-pr-check triggers one review-ready notification and never double-notifies"
}

test_pr_check_survives_notifier_failure() {
  local dir rc
  dir=$(make_pr_case pr-check-notify-failure)
  set +e
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_CURL_LOG="$dir/curl.log" FM_TEST_CURL_STDIN="$dir/curl.stdin" \
    FM_TEST_CURL_BODY="$dir/curl.body" FM_TEST_CURL_RC=1 \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" task-a https://github.com/o/r/pull/44 > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a notifier failure changed fm-pr-check's exit status: rc=$rc"
  grep -q 'armed:' "$dir/out" || fail "fm-pr-check did not report the armed poll"
  [ ! -e "$dir/home/state/task-a.pr-notified" ] \
    || fail "a failed notification recorded a marker through fm-pr-check"
  pass "a notifier failure never changes fm-pr-check's exit status"
}

test_message_assembly_and_idempotence
test_summary_fallbacks
test_absent_and_empty_webhook_are_inert
test_post_failure_is_best_effort
test_long_summary_is_bounded
test_invalid_requests_are_refused
test_pr_check_triggers_notification_once
test_pr_check_survives_notifier_failure
