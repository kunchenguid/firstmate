#!/usr/bin/env bash
# Behavior tests for the intake poll shim.
#
# The suite is hermetic: GitHub and Linear are both fake commands. The real jq is
# used because the production script relies on jq for normalization/diffing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-intake-poll-tests)

make_fake_intake_tools() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'pr list --repo lindy-ai/lindy --author twaldin --state open --limit 1000')
    cat "${FAKE_GH_AUTHORED:?}"
    ;;
  'search prs review-requested:twaldin --state open --owner lindy-ai --limit 1000')
    cat "${FAKE_GH_REVIEW:?}"
    ;;
  *)
    echo "unexpected gh-axi args: $*" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$fakebin/gh-axi"
  cat > "$fakebin/fm-mcp-broker" <<'SH'
#!/usr/bin/env bash
if [ "${FAKE_LINEAR_FAIL:-}" = 1 ]; then
  echo "${FAKE_LINEAR_FAIL_REASON:-rate limit}" >&2
  exit 1
fi
if [ "${1:-}" != call ] || [ "${2:-}" != linear ]; then
  echo "unexpected broker args: $*" >&2
  exit 2
fi
case "${3:-}" in
  linear_get_issue)
    cat "${FAKE_LINEAR_GET:?}"
    ;;
  linear_search_issues)
    cat "${FAKE_LINEAR_SEARCH:?}"
    ;;
  *)
    echo "unexpected linear tool: ${3:-}" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$fakebin/fm-mcp-broker"
  printf '%s\n' "$fakebin"
}

make_bootstrap_toolchain() {
  local dir=$1 fakebin real_jq
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi quota-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then exit 0; fi
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' '0.2.2' ;;
  update)
    [ "${2:-}" = --help ] && printf '%s\n' 'usage: tasks-axi update <id> [--archive-body]'
    ;;
  mv)
    [ "${2:-}" = --help ] && printf '%s\n' 'usage: tasks-axi mv [<id>...] --to <path>'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for intake tests"
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  chmod +x "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

write_empty_gh() {
  local file=$1 kind=${2:-prs}
  {
    printf 'count: 0\n'
    printf '%s: []\n' "$kind"
  } > "$file"
}

write_oncall_example() {
  local file=$1
  cat > "$file" <<'JSON'
{
  "issue": {
    "identifier": "EM-11195",
    "labels": {
      "nodes": [
        { "name": "daily brief" },
        { "name": "🚨 On Call" }
      ]
    }
  }
}
JSON
}

write_search() {
  local file=$1
  shift
  {
    printf '{"issues":['
    local first=1 json
    for json in "$@"; do
      [ "$first" -eq 1 ] || printf ','
      printf '%s' "$json"
      first=0
    done
    printf ']}\n'
  } > "$file"
}

linear_issue_json() { # <id> <title> <priority> <state> <label-json-array>
  jq -nc \
    --arg id "$1" \
    --arg title "$2" \
    --argjson priority "$3" \
    --arg state "$4" \
    --argjson labels "$5" \
    '{
      identifier: $id,
      title: $title,
      priority: $priority,
      state: {name: $state},
      url: ("https://linear.app/acme/issue/" + $id),
      assignee: {email: "tim@lindy.ai"},
      labels: {nodes: ($labels | map({name:.}))},
      apiKey: "secret-linear-key"
    }'
}

write_gh_authored_one() {
  cat > "$1" <<'EOF'
count: 1
pull_requests[1]{number,title,state,author,draft,review}:
  101,captain-authored change,open,twaldin,no,none
EOF
}

write_gh_review_one() {
  cat > "$1" <<'EOF'
count: 1
prs[1]{number,title,state,author}:
  201,needs captain review,open,alice,no,required
EOF
}

setup_case() {
  local case_dir=$1
  mkdir -p "$case_dir/home/config"
  : > "$case_dir/home/config/intake.env"
  write_empty_gh "$case_dir/authored.gh" pull_requests
  write_empty_gh "$case_dir/review.gh" prs
  write_oncall_example "$case_dir/get.json"
  write_search "$case_dir/search.json"
}

run_poll() {
  local home=$1 fakebin=$2 now=$3 authored=$4 review=$5 get=$6 search=$7
  shift 7
  env PATH="$fakebin:$BASE_PATH" \
    FM_HOME="$home" \
    FM_INTAKE_NOW_EPOCH="$now" \
    FM_INTAKE_GH_CMD="$fakebin/gh-axi" \
    FM_INTAKE_BROKER_CMD="$fakebin/fm-mcp-broker" \
    FAKE_GH_AUTHORED="$authored" \
    FAKE_GH_REVIEW="$review" \
    FAKE_LINEAR_GET="$get" \
    FAKE_LINEAR_SEARCH="$search" \
    "$@" \
    "$ROOT/bin/fm-intake-poll.sh"
}

assert_jq() {
  local filter=$1 file=$2 msg=$3
  jq -e "$filter" "$file" >/dev/null || fail "$msg"
}

test_new_items_snapshot_backlog_and_silence_after_marker() {
  local case_dir home fakebin out snapshot backlog oncall normal plain_label
  case_dir="$TMP_ROOT/new-items"
  setup_case "$case_dir"
  home="$case_dir/home"
  fakebin=$(make_fake_intake_tools "$case_dir/fake")
  write_gh_authored_one "$case_dir/authored.gh"
  write_gh_review_one "$case_dir/review.gh"
  oncall=$(linear_issue_json EM-1 "Oncall ticket" 2 "In Progress" '["🚨 On Call"]')
  normal=$(linear_issue_json EM-2 "Normal ticket" 3 "Todo" '["customer"]')
  plain_label=$(linear_issue_json EM-3 "Plain label is normal" 1 "Todo" '["On Call"]')
  write_search "$case_dir/search.json" "$oncall" "$normal" "$plain_label"

  out=$(run_poll "$home" "$fakebin" 1000 "$case_dir/authored.gh" "$case_dir/review.gh" "$case_dir/get.json" "$case_dir/search.json")
  assert_contains "$out" "intake:" "first intake poll should wake for new assigned/review items"
  assert_contains "$out" "EM-1" "wake should include new oncall item"
  assert_contains "$out" "EM-2" "wake should include new normal item"
  assert_contains "$out" "PR#201" "wake should include new review request"
  assert_not_contains "$out" "PR#101" "authored PRs are derived silently, not wake-worthy"

  snapshot="$home/state/intake/snapshot.json"
  backlog="$home/data/backlog.md"
  assert_present "$home/state/intake/github.json" "github source snapshot missing"
  assert_present "$home/state/intake/linear.json" "linear source snapshot missing"
  assert_present "$snapshot" "merged intake snapshot missing"
  assert_jq '.items | length == 5' "$snapshot" "snapshot should contain all open GitHub + Linear items"
  assert_jq '.items[] | select(.id=="EM-1" and .lane=="oncall" and .sla_class=="oncall" and .sla_warn_at != null and .sla_breach_at != null)' "$snapshot" "oncall item schema/SLA fields missing"
  assert_jq '.items[] | select(.id=="EM-2" and .lane=="normal" and .sla_warn_at == null and .sla_breach_at == null)' "$snapshot" "normal item should have no SLA clock by default"
  assert_jq '.items[] | select(.id=="EM-3" and .lane=="normal")' "$snapshot" "plain On Call label must not match exact siren label"
  assert_jq '.items[] | select(.id=="github:review:201" and .lane=="review" and .sla_warn_at != null)' "$snapshot" "review request SLA warn missing"
  assert_no_grep "secret-linear-key" "$snapshot" "snapshot must not contain ignored secret-like source fields"
  assert_grep "<!-- fm-backlog-pull:generated:start -->" "$backlog" "backlog generated start marker missing"
  assert_grep "On-call Linear tickets" "$backlog" "backlog should include oncall lane"
  assert_grep "GitHub review requests" "$backlog" "backlog should include review lane"
  assert_no_grep "Slack" "$backlog" "intake v1 backlog derivation must not add Slack sections"

  out=$(run_poll "$home" "$fakebin" 1000 "$case_dir/authored.gh" "$case_dir/review.gh" "$case_dir/get.json" "$case_dir/search.json")
  [ -z "$out" ] || fail "unchanged second poll must be silent, got: $out"
  pass "intake poll wakes only on new deltas, writes redacted snapshots, and silently derives backlog"
}

test_authored_pr_only_is_silent_but_derived() {
  local case_dir home fakebin out snapshot
  case_dir="$TMP_ROOT/authored-only"
  setup_case "$case_dir"
  home="$case_dir/home"
  fakebin=$(make_fake_intake_tools "$case_dir/fake")
  write_gh_authored_one "$case_dir/authored.gh"

  out=$(run_poll "$home" "$fakebin" 1000 "$case_dir/authored.gh" "$case_dir/review.gh" "$case_dir/get.json" "$case_dir/search.json")
  [ -z "$out" ] || fail "authored PR-only poll should be silent, got: $out"
  snapshot="$home/state/intake/snapshot.json"
  assert_jq '.items[] | select(.id=="github:pr:101" and .lane=="pr")' "$snapshot" "authored PR should still be derived into snapshot"
  assert_grep "captain-authored change" "$home/data/backlog.md" "authored PR should be derived into backlog"
  pass "authored PRs are a silent derived lane"
}

test_priority_raise_wakes_existing_item() {
  local case_dir home fakebin out normal
  case_dir="$TMP_ROOT/priority"
  setup_case "$case_dir"
  home="$case_dir/home"
  fakebin=$(make_fake_intake_tools "$case_dir/fake")
  normal=$(linear_issue_json EM-7 "Priority ticket" 3 "Todo" '["customer"]')
  write_search "$case_dir/search.json" "$normal"
  run_poll "$home" "$fakebin" 1000 "$case_dir/authored.gh" "$case_dir/review.gh" "$case_dir/get.json" "$case_dir/search.json" >/dev/null

  normal=$(linear_issue_json EM-7 "Priority ticket" 1 "Todo" '["customer"]')
  write_search "$case_dir/search.json" "$normal"
  out=$(run_poll "$home" "$fakebin" 1001 "$case_dir/authored.gh" "$case_dir/review.gh" "$case_dir/get.json" "$case_dir/search.json")
  assert_contains "$out" "priority-raise" "priority raise should wake"
  assert_contains "$out" "EM-7" "priority raise should name the item"
  pass "intake poll wakes on priority raises"
}

test_sla_warn_and_breach_wake_once() {
  local case_dir home fakebin out oncall
  case_dir="$TMP_ROOT/sla"
  setup_case "$case_dir"
  home="$case_dir/home"
  fakebin=$(make_fake_intake_tools "$case_dir/fake")
  cat > "$home/config/intake-sla.env" <<'EOF'
FM_INTAKE_ONCALL_WARN=10s
FM_INTAKE_ONCALL_BREACH=20s
EOF
  oncall=$(linear_issue_json EM-SLA "Aging oncall" 2 "Todo" '["🚨 On Call"]')
  write_search "$case_dir/search.json" "$oncall"
  run_poll "$home" "$fakebin" 1000 "$case_dir/authored.gh" "$case_dir/review.gh" "$case_dir/get.json" "$case_dir/search.json" >/dev/null

  out=$(run_poll "$home" "$fakebin" 1005 "$case_dir/authored.gh" "$case_dir/review.gh" "$case_dir/get.json" "$case_dir/search.json")
  [ -z "$out" ] || fail "pre-warn SLA poll should be silent, got: $out"
  out=$(run_poll "$home" "$fakebin" 1011 "$case_dir/authored.gh" "$case_dir/review.gh" "$case_dir/get.json" "$case_dir/search.json")
  assert_contains "$out" "sla-warn" "SLA warn crossing should wake"
  out=$(run_poll "$home" "$fakebin" 1015 "$case_dir/authored.gh" "$case_dir/review.gh" "$case_dir/get.json" "$case_dir/search.json")
  [ -z "$out" ] || fail "repeated SLA warn level should be silent, got: $out"
  out=$(run_poll "$home" "$fakebin" 1021 "$case_dir/authored.gh" "$case_dir/review.gh" "$case_dir/get.json" "$case_dir/search.json")
  assert_contains "$out" "sla-breach" "SLA breach crossing should wake"
  pass "intake poll computes SLA warn/breach crossings once"
}

test_error_dedupe_and_recovery() {
  local case_dir home fakebin out normal
  case_dir="$TMP_ROOT/errors"
  setup_case "$case_dir"
  home="$case_dir/home"
  fakebin=$(make_fake_intake_tools "$case_dir/fake")
  normal=$(linear_issue_json EM-ERR "Recoverable ticket" 3 "Todo" '["customer"]')
  write_search "$case_dir/search.json" "$normal"

  out=$(FAKE_LINEAR_FAIL=1 FAKE_LINEAR_FAIL_REASON="rate limit" \
    run_poll "$home" "$fakebin" 1000 "$case_dir/authored.gh" "$case_dir/review.gh" "$case_dir/get.json" "$case_dir/search.json")
  [ "$out" = "intake-error linear failed: rate limit" ] || fail "first source error should emit one diagnostic, got: $out"
  out=$(FAKE_LINEAR_FAIL=1 FAKE_LINEAR_FAIL_REASON="rate limit" \
    run_poll "$home" "$fakebin" 1001 "$case_dir/authored.gh" "$case_dir/review.gh" "$case_dir/get.json" "$case_dir/search.json")
  [ -z "$out" ] || fail "repeated identical source error should be silent, got: $out"
  out=$(run_poll "$home" "$fakebin" 1002 "$case_dir/authored.gh" "$case_dir/review.gh" "$case_dir/get.json" "$case_dir/search.json")
  assert_contains "$out" "intake:" "recovered source should resume normal delta detection"
  assert_absent "$home/state/intake/error" "successful poll should clear intake error marker"
  pass "intake poll rate-limits source errors and clears on recovery"
}

test_bootstrap_opt_in_and_noop_gating() {
  local case_dir home fakebin fake_root out shim
  case_dir="$TMP_ROOT/bootstrap"
  home="$case_dir/home"
  fake_root="$case_dir/fake-root"
  mkdir -p "$home/config" "$home/state"
  chmod 0700 "$home/state"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  printf '%s\n' manual > "$home/config/backlog-backend"
  fm_git_init_commit "$fake_root"
  mkdir -p "$fake_root/bin"
  printf '#!/usr/bin/env bash\n' > "$fake_root/bin/fm-intake-poll.sh"
  chmod +x "$fake_root/bin/fm-intake-poll.sh"
  fakebin=$(make_bootstrap_toolchain "$case_dir/fake")
  shim="$home/state/intake.check.sh"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "bootstrap without config/intake.env should be silent, got: $out"
  assert_absent "$shim" "bootstrap must not create intake shim by default"

  printf '# opt in\n' > "$home/config/intake.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "INTAKE: intake mode on - intake poll armed via state/intake.check.sh" "bootstrap should arm intake mode when opted in"
  assert_present "$shim" "bootstrap should create intake shim"
  assert_grep "exec $fake_root/bin/fm-intake-poll.sh" "$shim" "generated intake shim should exec the poll body"

  rm -f "$home/config/intake.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "INTAKE: intake mode off - removed intake poll shim" "bootstrap should remove stale shim on opt-out"
  assert_absent "$shim" "bootstrap should remove intake shim when opted out"
  pass "bootstrap gates intake shim generation on config/intake.env"
}

test_new_items_snapshot_backlog_and_silence_after_marker
test_authored_pr_only_is_silent_but_derived
test_priority_raise_wakes_existing_item
test_sla_warn_and_breach_wake_once
test_error_dedupe_and_recovery
test_bootstrap_opt_in_and_noop_gating
