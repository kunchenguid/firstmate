#!/usr/bin/env bash
# Tests for Bitbucket Cloud as a third PR provider: URL parsing, the token
# resolution contract, a mocked REST record read, and bin/fm-pr-merge.sh's
# Bitbucket pre-merge conditions and merge/confirm path. GitHub and GitLab
# behavior is pinned by tests/fm-pr-check-security.test.sh and
# tests/fm-pr-merge.test.sh; this file owns Bitbucket only.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-bitbucket)
BASE_PATH=$PATH
JQ_BIN=$(command -v jq) || fail "these tests read Bitbucket JSON with the real jq, which was not found"

WS=my-workspace
REPO=my-repo
BB_URL="https://bitbucket.org/$WS/$REPO/pull-requests/9"
BB_HEAD=1111111111111111111111111111111111111111
BB_STALE_HEAD=2222222222222222222222222222222222222222

# --- URL parsing (bitbucket-specific edge cases beyond the shared matrix in
# tests/fm-pr-check-security.test.sh) ----------------------------------------

test_url_parse_basic() {
  fm_pr_url_parse "$BB_URL" || fail "parser rejected a canonical Bitbucket pull request URL"
  [ "$FM_PR_PROVIDER" = bitbucket ] || fail "wrong provider"
  [ "$FM_PR_HOST" = bitbucket.org ] || fail "wrong host"
  [ "$FM_PR_PATH" = "$WS/$REPO" ] || fail "wrong path"
  [ "$FM_PR_OWNER" = "$WS" ] || fail "wrong owner (workspace)"
  [ "$FM_PR_REPO" = "$REPO" ] || fail "wrong repo"
  [ "$FM_PR_NUMBER" = 9 ] || fail "wrong number"
  pass "parser tags a canonical Bitbucket pull request URL correctly"
}

test_url_parse_rejects_mismatched_case() {
  ! fm_pr_url_parse "https://BITBUCKET.ORG/$WS/$REPO/pull-requests/1" \
    || fail "parser accepted an uppercase bitbucket.org host"
  ! fm_pr_url_parse "https://bitbucket.org/$WS/$REPO/pull-requests/01" \
    || fail "parser accepted a zero-padded pull request number"
  ! fm_pr_url_parse "https://bitbucket.org/$WS/$REPO/pull-requests/" \
    || fail "parser accepted a missing pull request number"
  ! fm_pr_url_parse "https://bitbucket.org//$REPO/pull-requests/1" \
    || fail "parser accepted an empty workspace segment"
  pass "parser rejects malformed Bitbucket URL shapes"
}

# --- fm_pr_bitbucket_token: environment wins, .env is the opt-in fallback --

test_token_environment_wins() {
  local home
  home="$TMP_ROOT/token-env"; mkdir -p "$home"
  printf 'FM_BITBUCKET_TOKEN=from-env-file\n' > "$home/.env"
  [ "$(FM_BITBUCKET_TOKEN=from-ambient-env fm_pr_bitbucket_token "$home")" = from-ambient-env ] \
    || fail "ambient environment token did not win over .env"
  pass "the ambient environment token wins over .env"
}

test_token_env_file_fallback() {
  local home
  home="$TMP_ROOT/token-envfile"; mkdir -p "$home"
  printf 'export FM_BITBUCKET_TOKEN="quoted-token"\n' > "$home/.env"
  [ "$(unset FM_BITBUCKET_TOKEN; fm_pr_bitbucket_token "$home")" = quoted-token ] \
    || fail ".env fallback did not resolve an exported, quoted token"
  pass "the .env fallback resolves an exported, quoted token"
}

test_token_absent_refuses() {
  local home
  home="$TMP_ROOT/token-absent"; mkdir -p "$home"
  ! (unset FM_BITBUCKET_TOKEN; fm_pr_bitbucket_token "$home" >/dev/null 2>&1) \
    || fail "token resolution succeeded with neither an ambient env var nor a .env entry"
  pass "no token configured is a clean refusal, never an unauthenticated request"
}

# --- fake curl: a minimal Bitbucket Cloud REST API v2.0 double -------------
#
# Routes on the trailing path shape ("/pullrequests/<n>", ".../statuses",
# ".../merge") and the -X method, writes the configured body to the -o file,
# and prints the configured HTTP status the way real curl's -w '%{http_code}'
# does. Every call is logged so a test can assert on what was actually sent
# (path, method, Authorization header, and POST body).
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" method=GET data="" url="" auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -X) method=$2; shift 2 ;;
    --data-binary) data=$2; shift 2 ;;
    -H)
      case "$2" in
        Authorization:*) auth=$2 ;;
      esac
      shift 2
      ;;
    -sS|-s) shift ;;
    -w) shift 2 ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  { echo "method=$method"; echo "url=$url"; echo "auth=$auth"; echo "data=$data"; } >> "$FAKE_CURL_LOG"
fi
case "$url" in
  */pullrequests/*/merge)
    [ -n "$ofile" ] && printf '%s' "${FAKE_MERGE_BODY:-}" > "$ofile"
    printf '%s' "${FAKE_MERGE_CODE:-200}"
    ;;
  */statuses*)
    [ -n "$ofile" ] && printf '%s' "${FAKE_STATUSES_BODY:-{\"values\":[],\"next\":null\}}" > "$ofile"
    printf '%s' "${FAKE_STATUSES_CODE:-200}"
    ;;
  */pullrequests/*)
    [ -n "$ofile" ] && printf '%s' "${FAKE_PR_BODY:-}" > "$ofile"
    printf '%s' "${FAKE_PR_CODE:-200}"
    ;;
  *)
    printf '%s' 404
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/curl"
  ln -sf "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

# --- fm_pr_bitbucket_read_record --------------------------------------------

test_read_record_open() {
  local home fakebin
  home="$TMP_ROOT/read-open"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  if ! PATH="$fakebin:$BASE_PATH" FAKE_PR_BODY='{"state":"OPEN"}' \
    FM_BITBUCKET_TOKEN=tok bash -c '. "$1"; fm_pr_bitbucket_read_record "$2" "$3" "$4" "$5"' \
    _ "$ROOT/bin/fm-pr-lib.sh" "$home" "$WS" "$REPO" 9 \
    > "$home/out" 2>/dev/null; then
    fail "read record failed for an open pull request"
  fi
  pass "fm_pr_bitbucket_read_record reads an open pull request without error"
}

test_read_record_merged_true_only_on_merged_state() {
  local home fakebin record state merged
  home="$TMP_ROOT/read-merged"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  record=$(PATH="$fakebin:$BASE_PATH" FAKE_PR_BODY='{"state":"MERGED"}' \
    FM_BITBUCKET_TOKEN=tok bash -c '
      . "$1"
      fm_pr_bitbucket_read_record "$2" "$3" "$4" "$5" || exit 1
      printf "state=%s\nmerged=%s\n" "$FM_PR_RECORD_STATE" "$FM_PR_RECORD_MERGED"
    ' _ "$ROOT/bin/fm-pr-lib.sh" "$home" "$WS" "$REPO" 9 2>/dev/null) \
    || fail "read record failed for a merged pull request"
  state=$(printf '%s\n' "$record" | sed -n 's/^state=//p')
  merged=$(printf '%s\n' "$record" | sed -n 's/^merged=//p')
  [ "$state" = MERGED ] || fail "wrong state for a merged pull request"
  [ "$merged" = true ] || fail "merged flag was not true for state=MERGED"

  record=$(PATH="$fakebin:$BASE_PATH" FAKE_PR_BODY='{"state":"DECLINED"}' \
    FM_BITBUCKET_TOKEN=tok bash -c '
      . "$1"
      fm_pr_bitbucket_read_record "$2" "$3" "$4" "$5" || exit 1
      printf "state=%s\nmerged=%s\n" "$FM_PR_RECORD_STATE" "$FM_PR_RECORD_MERGED"
    ' _ "$ROOT/bin/fm-pr-lib.sh" "$home" "$WS" "$REPO" 9 2>/dev/null) \
    || fail "read record failed for a declined pull request"
  merged=$(printf '%s\n' "$record" | sed -n 's/^merged=//p')
  [ "$merged" = false ] || fail "merged flag was true for a non-merged state"
  pass "fm_pr_bitbucket_read_record reports merged=true only for state=MERGED"
}

test_read_record_non_2xx_refuses() {
  local home fakebin
  home="$TMP_ROOT/read-401"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  ! PATH="$fakebin:$BASE_PATH" FAKE_PR_CODE=401 FM_BITBUCKET_TOKEN=tok bash -c '
      . "$1"
      fm_pr_bitbucket_read_record "$2" "$3" "$4" "$5"
    ' _ "$ROOT/bin/fm-pr-lib.sh" "$home" "$WS" "$REPO" 9 2>/dev/null \
    || fail "read record succeeded on a non-2xx HTTP status"
  pass "a non-2xx HTTP status is a clean refusal, never a false read"
}

# --- fm-pr-merge.sh: Bitbucket pre-merge conditions and merge path ---------

make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/home/data" "$case_dir/home/config" "$fakebin"
  cp "$ROOT/.tasks.toml" "$case_dir/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/home/data/backlog.md"
  fm_write_meta "$case_dir/state/task-b1.meta" \
    "window=fm-task-b1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'FM_BITBUCKET_TOKEN=test-token\n' > "$case_dir/home/.env"
  printf '%s\n' "$case_dir"
}

run_merge() {  # <case_dir> <extra fm-pr-merge args...>
  local case_dir=$1
  shift
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$BASE_PATH" \
    "$PR_MERGE" task-b1 "$BB_URL" "$@"
}

write_pr_and_statuses() {  # <case_dir> [state] [status_state]
  local case_dir=$1 state=${2:-OPEN} status_state=${3:-SUCCESSFUL}
  printf '{"state":"%s","source":{"commit":{"hash":"%s"}},"destination":{"branch":{"name":"main"}}}\n' \
    "$state" "$BB_HEAD" > "$case_dir/pr.json"
  if [ "$status_state" = NONE ]; then
    printf '{"values":[],"next":null}\n' > "$case_dir/statuses.json"
  else
    printf '{"values":[{"key":"build","state":"%s"}],"next":null}\n' \
      "$status_state" > "$case_dir/statuses.json"
  fi
}

# The bitbucket fake for the fm-pr-merge.sh path drives PR state, statuses, and
# the merge outcome from the case directory's own JSON files, and records
# every merge POST body so a test can assert on merge_strategy/close_source_branch.
add_bitbucket_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/curl" <<SH
#!/usr/bin/env bash
ofile="" method=GET data="" url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) ofile=\$2; shift 2 ;;
    -X) method=\$2; shift 2 ;;
    --data-binary) data=\$2; shift 2 ;;
    -H) shift 2 ;;
    -sS|-s) shift ;;
    -w) shift 2 ;;
    http://*|https://*) url=\$1; shift ;;
    *) shift ;;
  esac
done
case_dir="$case_dir"
echo "\$method \$url \$data" >> "\$case_dir/curl.log"
case "\$url" in
  */pullrequests/*/merge)
    [ ! -e "\$case_dir/merge-fails" ] || { printf '{"type":"error","error":{"message":"conflict"}}' > "\$ofile"; printf '409'; exit 0; }
    : > "\$case_dir/merge-called"
    if [ -e "\$case_dir/merge-async" ]; then
      [ -n "\$ofile" ] && printf '{}' > "\$ofile"
      printf '202'
    else
      [ -n "\$ofile" ] && cat "\$case_dir/merge-result.json" > "\$ofile"
      printf '200'
    fi
    ;;
  */commit/*/statuses*)
    [ -n "\$ofile" ] && cat "\$case_dir/statuses.json" > "\$ofile"
    printf '200'
    ;;
  */pullrequests/*)
    if [ -e "\$case_dir/merge-called" ] && [ -e "\$case_dir/pr-merged-after.json" ]; then
      [ -n "\$ofile" ] && cat "\$case_dir/pr-merged-after.json" > "\$ofile"
    else
      [ -n "\$ofile" ] && cat "\$case_dir/pr.json" > "\$ofile"
    fi
    printf '200'
    ;;
  *)
    printf '404'
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/curl"
  ln -sf "$JQ_BIN" "$case_dir/fakebin/jq"
}

test_merge_refuses_when_not_open() {
  local case_dir out rc=0
  case_dir=$(make_case merge-not-open)
  add_bitbucket_mock "$case_dir"
  write_pr_and_statuses "$case_dir" MERGED SUCCESSFUL
  out=$(run_merge "$case_dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "merge did not refuse a non-open pull request"
  printf '%s\n' "$out" | grep -q 'not OPEN' \
    || fail "refusal did not name the non-open state: $out"
  [ ! -e "$case_dir/merge-called" ] || fail "merge was called despite a non-open pull request"
  pass "a non-open pull request refuses the merge before calling the forge"
}

test_merge_refuses_on_red_status() {
  local case_dir out rc=0
  case_dir=$(make_case merge-red-status)
  add_bitbucket_mock "$case_dir"
  write_pr_and_statuses "$case_dir" OPEN FAILED
  out=$(run_merge "$case_dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "merge did not refuse a FAILED commit status"
  printf '%s\n' "$out" | grep -q "status 'build' is not SUCCESSFUL" \
    || fail "refusal did not name the failing status: $out"
  [ ! -e "$case_dir/merge-called" ] || fail "merge was called despite a red status"
  pass "a FAILED commit status refuses the merge"
}

test_merge_refuses_on_inprogress_status() {
  local case_dir out rc=0
  case_dir=$(make_case merge-inprogress-status)
  add_bitbucket_mock "$case_dir"
  write_pr_and_statuses "$case_dir" OPEN INPROGRESS
  out=$(run_merge "$case_dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "merge did not refuse an INPROGRESS commit status"
  [ ! -e "$case_dir/merge-called" ] || fail "merge was called despite a still-running status"
  pass "an INPROGRESS commit status is not green and refuses the merge"
}

test_merge_refuses_on_no_status_reported() {
  local case_dir out rc=0
  case_dir=$(make_case merge-no-status)
  add_bitbucket_mock "$case_dir"
  write_pr_and_statuses "$case_dir" OPEN NONE
  out=$(run_merge "$case_dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "merge did not refuse a head with no reported commit status"
  printf '%s\n' "$out" | grep -q 'no commit status has reported' \
    || fail "refusal did not name the absent status signal: $out"
  [ ! -e "$case_dir/merge-called" ] || fail "merge was called despite no reported status"
  pass "total silence from commit statuses is refused rather than read as green"
}

test_merge_succeeds_synchronously() {
  local case_dir out rc=0
  case_dir=$(make_case merge-sync)
  add_bitbucket_mock "$case_dir"
  write_pr_and_statuses "$case_dir" OPEN SUCCESSFUL
  printf '{"state":"MERGED","source":{"commit":{"hash":"%s"}},"destination":{"branch":{"name":"main"}},"merge_commit":{"hash":"deadbeef"}}\n' \
    "$BB_HEAD" > "$case_dir/merge-result.json"
  cp "$case_dir/merge-result.json" "$case_dir/pr-merged-after.json"
  out=$(run_merge "$case_dir" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a green, open, synchronously-merged pull request was not accepted: $out"
  [ -e "$case_dir/merge-called" ] || fail "the merge endpoint was never called"
  grep -q 'merge_strategy":"merge_commit"' "$case_dir/curl.log" \
    || fail "the default merge_strategy was not merge_commit: $(cat "$case_dir/curl.log")"
  grep -qxF "pr=$BB_URL" "$case_dir/state/task-b1.meta" \
    || fail "pr= was not recorded in task metadata"
  pass "a green Bitbucket pull request merges synchronously and is confirmed landed"
}

test_merge_squash_method_selected() {
  local case_dir out rc=0
  case_dir=$(make_case merge-squash)
  add_bitbucket_mock "$case_dir"
  write_pr_and_statuses "$case_dir" OPEN SUCCESSFUL
  printf '{"state":"MERGED","source":{"commit":{"hash":"%s"}},"destination":{"branch":{"name":"main"}}}\n' \
    "$BB_HEAD" > "$case_dir/merge-result.json"
  cp "$case_dir/merge-result.json" "$case_dir/pr-merged-after.json"
  out=$(run_merge "$case_dir" --squash 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a --squash merge was refused: $out"
  grep -q 'merge_strategy":"squash"' "$case_dir/curl.log" \
    || fail "--squash did not select the squash merge_strategy: $(cat "$case_dir/curl.log")"
  pass "--squash selects Bitbucket's squash merge_strategy"
}

test_merge_accepted_async_leaves_poll_armed() {
  local case_dir out rc=0
  case_dir=$(make_case merge-async)
  add_bitbucket_mock "$case_dir"
  write_pr_and_statuses "$case_dir" OPEN SUCCESSFUL
  : > "$case_dir/merge-async"
  # After the merge call, the confirm re-read still shows OPEN (the async task
  # has not finished): only the merge POST is answered with 202.
  out=$(run_merge "$case_dir" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "an accepted-but-unconfirmed async merge should not fail the run: $out"
  [ -e "$case_dir/merge-called" ] || fail "the merge endpoint was never called"
  printf '%s\n' "$out" | grep -q 'does not yet read back as merged' \
    || fail "the unconfirmed outcome was not reported as actionable: $out"
  grep -qxF "pr=$BB_URL" "$case_dir/state/task-b1.meta" \
    || fail "pr= was not recorded even though the merge poll must stay armed"
  [ -e "$case_dir/state/task-b1.check.sh" ] \
    || fail "the merge poll was not armed for an unconfirmed async merge"
  pass "an accepted asynchronous merge is never reported landed until confirmed; the poll stays armed"
}

test_merge_head_moved_refuses() {
  local case_dir out rc=0
  case_dir=$(make_case merge-head-moved)
  cat > "$case_dir/fakebin/curl" <<SH
#!/usr/bin/env bash
ofile="" url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) ofile=\$2; shift 2 ;;
    -X) shift 2 ;;
    --data-binary) shift 2 ;;
    -H) shift 2 ;;
    -sS|-s) shift ;;
    -w) shift 2 ;;
    http://*|https://*) url=\$1; shift ;;
    *) shift ;;
  esac
done
case_dir="$case_dir"
echo "call" >> "\$case_dir/curl.log"
calls=\$(wc -l < "\$case_dir/curl.log")
case "\$url" in
  */commit/*/statuses*)
    [ -n "\$ofile" ] && cat "\$case_dir/statuses.json" > "\$ofile"
    printf '200'
    ;;
  */pullrequests/*)
    # First PR read (preflight) reports the original head; every later read
    # (the immediate pre-merge race check) reports a moved head.
    if [ "\$calls" -le 2 ]; then
      cat "\$case_dir/pr.json" > "\$ofile"
    else
      cat "\$case_dir/pr-moved.json" > "\$ofile"
    fi
    printf '200'
    ;;
  *)
    printf '404'
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/curl"
  ln -sf "$JQ_BIN" "$case_dir/fakebin/jq"
  write_pr_and_statuses "$case_dir" OPEN SUCCESSFUL
  printf '{"state":"OPEN","source":{"commit":{"hash":"%s"}},"destination":{"branch":{"name":"main"}}}\n' \
    "$BB_STALE_HEAD" > "$case_dir/pr-moved.json"
  out=$(run_merge "$case_dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "merge did not refuse when the head moved between verification and merge"
  printf '%s\n' "$out" | grep -q 'the head moved to' \
    || fail "refusal did not name the moved head: $out"
  [ ! -e "$case_dir/merge-called" ] || fail "merge was called despite the head moving"
  pass "a head that moves between verification and merge refuses rather than merging unverified commits"
}

test_url_parse_basic
test_url_parse_rejects_mismatched_case
test_token_environment_wins
test_token_env_file_fallback
test_token_absent_refuses
test_read_record_open
test_read_record_merged_true_only_on_merged_state
test_read_record_non_2xx_refuses
test_merge_refuses_when_not_open
test_merge_refuses_on_red_status
test_merge_refuses_on_inprogress_status
test_merge_refuses_on_no_status_reported
test_merge_succeeds_synchronously
test_merge_squash_method_selected
test_merge_accepted_async_leaves_poll_armed
test_merge_head_moved_refuses
