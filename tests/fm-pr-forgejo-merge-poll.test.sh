#!/usr/bin/env bash
# Tests for Forgejo PR URL parsing and merge-poll behavior.
# Uses a fake curl (controlled via env vars) to avoid live network calls;
# never uses real tokens. Real jq is required because the poll's filter
# programs are under test.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

POLL="$ROOT/bin/fm-pr-poll.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-forgejo-merge-poll)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

command -v jq >/dev/null 2>&1 \
  || fail "these tests drive the poll's jq programs over API-shaped JSON with the real jq, which was not found"

# fake curl - returns FM_TEST_FORGEJO_API_JSON or exits 1 when
# FM_TEST_FORGEJO_CURL_FAIL=1. Never echoes the Authorization header.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
[ "${FM_TEST_FORGEJO_CURL_FAIL:-0}" = 0 ] || exit 1
_json="${FM_TEST_FORGEJO_API_JSON:-}"
[ -n "$_json" ] || _json='{}'
printf '%s\n' "$_json"
SH
chmod +x "$FAKEBIN/curl"

# Creds file with a fake (non-sensitive) token for unit tests.
CREDS="$TMP_ROOT/test-forgejo.env"
printf 'FORGEJO_URL=https://codeberg.org\nFORGEJO_TOKEN=fake-test-token-for-unit-tests\n' > "$CREDS"

# Run the poll against codeberg.org/alice/myrepo/pulls/7 with fake curl/real jq.
run_forgejo_poll() {
  FM_FORGEJO_CREDS_FILE="$CREDS" \
  PATH="$FAKEBIN:$(dirname "$(command -v jq)")" \
    "$POLL" --validated \
      forgejo \
      "https://codeberg.org/alice/myrepo/pulls/7" \
      codeberg.org alice/myrepo 7
}

# --- URL parser ---

test_forgejo_valid_url_matrix() {
  local url host path number
  while IFS='|' read -r url host path number; do
    [ -n "$url" ] || continue
    fm_pr_url_parse "$url" \
      || fail "parser rejected canonical Forgejo URL: $url"
    [ "$FM_PR_PROVIDER" = forgejo ] \
      || fail "provider not forgejo for: $url"
    [ "$FM_PR_URL" = "$url" ] \
      || fail "parser changed canonical URL: $url"
    [ "$FM_PR_HOST" = "$host" ] \
      || fail "wrong host for $url: $FM_PR_HOST"
    [ "$FM_PR_PATH" = "$path" ] \
      || fail "wrong path for $url: $FM_PR_PATH"
    [ "$FM_PR_NUMBER" = "$number" ] \
      || fail "wrong number for $url: $FM_PR_NUMBER"
    [ "$FM_PR_OWNER" = "${path%%/*}" ] \
      || fail "FM_PR_OWNER not set for $url"
    [ "$FM_PR_REPO" = "${path#*/}" ] \
      || fail "FM_PR_REPO not set for $url"
  done <<'EOF'
https://codeberg.org/alice/myrepo/pulls/1|codeberg.org|alice/myrepo|1
https://codeberg.org/alice/myrepo/pulls/42|codeberg.org|alice/myrepo|42
https://forgejo.example.com/org/project/pulls/100|forgejo.example.com|org/project|100
https://git.sr.ht/alice/my-repo.git/pulls/7|git.sr.ht|alice/my-repo.git|7
https://git.internal/A1/Repo_Name.test/pulls/9999|git.internal|A1/Repo_Name.test|9999
EOF
  pass "canonical Forgejo URLs parse correctly with provider, host, path, number, owner, repo"
}

test_forgejo_url_provider_is_isolated() {
  fm_pr_url_parse "https://github.com/alice/repo/pull/1" \
    || fail "GitHub URL rejected"
  [ "$FM_PR_PROVIDER" = github ] \
    || fail "GitHub URL tagged as $FM_PR_PROVIDER instead of github"
  fm_pr_url_parse "https://gitlab.com/g/p/-/merge_requests/1" \
    || fail "GitLab URL rejected"
  [ "$FM_PR_PROVIDER" = gitlab ] \
    || fail "GitLab URL tagged as $FM_PR_PROVIDER instead of gitlab"
  pass "GitHub (/pull/) and GitLab (/-/merge_requests/) URLs do not become forgejo"
}

test_forgejo_invalid_url_matrix() {
  local url
  # shellcheck disable=SC2043
  for url in \
    "https://github.com/alice/repo/pulls/1" \
    "https://codeberg.org/alice/repo/pulls/0" \
    "https://codeberg.org/alice/repo/pulls/01" \
    "https://codeberg.org/alice/repo/pulls/" \
    "https://codeberg.org/alice--bob/repo/pulls/1" \
    "https://codeberg.org/-alice/repo/pulls/1" \
    "https://codeberg.org/alice-/repo/pulls/1" \
    "https://codeberg.org/alice/./pulls/1" \
    "https://codeberg.org/alice/../pulls/1" \
    "https://CODEBERG.ORG/alice/repo/pulls/1" \
    "http://codeberg.org/alice/repo/pulls/1" \
    "https://codeberg.org/alice/repo/pulls/1/" \
    "https://codeberg.org/alice/repo/pulls/1?q=x" \
    "https://codeberg.org/alice/repo/pulls/1#f" \
    "https://codeberg.org/alice/repo/issues/1" \
    "https://codeberg.org/alice/repo/pull/1" \
    "https://user@codeberg.org/alice/repo/pulls/1" \
    "https://codeberg.org:443/alice/repo/pulls/1"
  do
    ! fm_pr_url_parse "$url" \
      || fail "parser accepted a rejected Forgejo URL: $url"
  done
  pass "invalid and ambiguous Forgejo URLs are all rejected"
}

# --- Poll behavior ---

test_poll_merged_pr_emits_merged() {
  local out
  out=$(FM_TEST_FORGEJO_API_JSON='{"state":"open","merged":true}' run_forgejo_poll) \
    || fail "poll exited nonzero for merged PR fixture"
  [ "$out" = merged ] \
    || fail "a merged Forgejo PR must emit 'merged', got: $out"
  pass "a merged Forgejo PR emits 'merged'"
}

test_poll_open_pr_is_silent() {
  local out
  out=$(FM_TEST_FORGEJO_API_JSON='{"state":"open","merged":false}' run_forgejo_poll) \
    || fail "poll exited nonzero for open PR"
  [ -z "$out" ] \
    || fail "an open Forgejo PR must be silent, got: $out"
  pass "an open Forgejo PR is silent"
}

test_poll_closed_pr_emits_forgejo_closed() {
  local out
  out=$(FM_TEST_FORGEJO_API_JSON='{"state":"closed","merged":false}' run_forgejo_poll) \
    || fail "poll exited nonzero for closed PR"
  [ "$out" = 'forgejo closed' ] \
    || fail "a closed-unmerged Forgejo PR must emit 'forgejo closed', got: $out"
  pass "a closed-unmerged Forgejo PR emits 'forgejo closed'"
}

test_poll_missing_creds_emits_unavailable() {
  local out absent="$TMP_ROOT/absent-creds.env"
  [ ! -f "$absent" ] || fail "test setup error: absent creds path already exists"
  out=$(FM_FORGEJO_CREDS_FILE="$absent" \
    PATH="$FAKEBIN:$(dirname "$(command -v jq)")" \
    "$POLL" --validated \
      forgejo \
      "https://codeberg.org/alice/myrepo/pulls/7" \
      codeberg.org alice/myrepo 7) \
    || fail "poll exited nonzero for missing creds"
  [ "$out" = 'forgejo credentials unavailable' ] \
    || fail "missing creds must emit 'forgejo credentials unavailable', got: $out"
  pass "missing creds file emits 'forgejo credentials unavailable'"
}

test_poll_empty_token_emits_unavailable() {
  local out empty_creds="$TMP_ROOT/empty-token-creds.env"
  printf 'FORGEJO_URL=https://codeberg.org\n' > "$empty_creds"
  out=$(FM_FORGEJO_CREDS_FILE="$empty_creds" \
    PATH="$FAKEBIN:$(dirname "$(command -v jq)")" \
    "$POLL" --validated \
      forgejo \
      "https://codeberg.org/alice/myrepo/pulls/7" \
      codeberg.org alice/myrepo 7) \
    || fail "poll exited nonzero for empty token"
  [ "$out" = 'forgejo credentials unavailable' ] \
    || fail "empty token must emit 'forgejo credentials unavailable', got: $out"
  pass "missing FORGEJO_TOKEN line emits 'forgejo credentials unavailable'"
}

test_poll_curl_failure_is_silent() {
  local out
  out=$(FM_TEST_FORGEJO_CURL_FAIL=1 run_forgejo_poll) \
    || fail "poll exited nonzero for curl failure"
  [ -z "$out" ] \
    || fail "a curl failure must be silent so it cannot be read as a merge, got: $out"
  pass "a curl failure is silent"
}

test_poll_invalid_host_is_silent() {
  local out
  # github.com is explicitly rejected in the forgejo case.
  out=$(FM_FORGEJO_CREDS_FILE="$CREDS" \
    PATH="$FAKEBIN:$(dirname "$(command -v jq)")" \
    "$POLL" --validated \
      forgejo \
      "https://github.com/alice/repo/pulls/7" \
      github.com alice/repo 7) \
    || fail "poll exited nonzero for github.com host"
  [ -z "$out" ] \
    || fail "github.com host must be silent in forgejo case, got: $out"
  pass "github.com is rejected by the forgejo poll case"
}

test_poll_reconstructed_url_must_match() {
  local out
  # path=alice/myrepo does not reconstruct to the url for alice/OTHER
  out=$(FM_FORGEJO_CREDS_FILE="$CREDS" \
    FM_TEST_FORGEJO_API_JSON='{"state":"open","merged":true}' \
    PATH="$FAKEBIN:$(dirname "$(command -v jq)")" \
    "$POLL" --validated \
      forgejo \
      "https://codeberg.org/alice/OTHER/pulls/7" \
      codeberg.org alice/myrepo 7) \
    || fail "poll exited nonzero for mismatched URL fixture"
  [ -z "$out" ] \
    || fail "a mismatch between url and path/host components must be silent, got: $out"
  pass "the reconstructed URL must exactly match the stored url"
}

test_poll_quoted_token_stripped_before_use() {
  local out quoted_creds="$TMP_ROOT/quoted-creds.env"
  # Both leading and trailing single-quote are stripped; API returns merged.
  printf "FORGEJO_TOKEN='fake-test-token-for-unit-tests'\n" > "$quoted_creds"
  out=$(FM_FORGEJO_CREDS_FILE="$quoted_creds" \
    FM_TEST_FORGEJO_API_JSON='{"state":"open","merged":true}' \
    PATH="$FAKEBIN:$(dirname "$(command -v jq)")" \
    "$POLL" --validated \
      forgejo \
      "https://codeberg.org/alice/myrepo/pulls/7" \
      codeberg.org alice/myrepo 7) \
    || fail "poll exited nonzero with single-quoted token"
  [ "$out" = merged ] \
    || fail "single-quoted token should be stripped and poll should proceed, got: $out"
  # A token that is only quotes (empty after stripping) is treated as absent.
  printf "FORGEJO_TOKEN=''\n" > "$quoted_creds"
  out=$(FM_FORGEJO_CREDS_FILE="$quoted_creds" \
    FM_TEST_FORGEJO_API_JSON='{"state":"open","merged":true}' \
    PATH="$FAKEBIN:$(dirname "$(command -v jq)")" \
    "$POLL" --validated \
      forgejo \
      "https://codeberg.org/alice/myrepo/pulls/7" \
      codeberg.org alice/myrepo 7) \
    || fail "poll exited nonzero for empty-quoted token"
  [ "$out" = 'forgejo credentials unavailable' ] \
    || fail "a token of only quotes must report unavailable after stripping, got: $out"
  pass "surrounding single quotes are stripped; an all-quotes token is treated as absent"
}

# --- fm-pr-check.sh acceptance ---

make_forgejo_check_case() {
  local name=$1 dir fakebin fake_root
  dir="$TMP_ROOT/check-$name"
  fakebin="$dir/fakebin"
  fake_root="$dir/root"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/wt" \
           "$fakebin" "$fake_root/bin"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
:
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  # contributions.sh is optional; a missing jq just prints a warning.
  # Supply a no-op stub so the test does not depend on jq being on BASE_PATH.
  cat > "$fakebin/fm-contributions.sh" <<'SH'
#!/usr/bin/env bash
:
SH
  chmod +x "$fakebin/fm-contributions.sh"
  fm_write_meta "$dir/home/state/task-fg.meta" \
    "window=firstmate:fm-task-fg" \
    "endpoint_task_id=task-fg" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "$dir"
}

run_forgejo_check_entry() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" \
    PATH="$dir/fakebin:$PATH" \
    "$PR_CHECK" "$@"
}

test_pr_check_accepts_forgejo_url() {
  local dir out meta_url
  dir=$(make_forgejo_check_case forgejo-arm)
  out=$(run_forgejo_check_entry "$dir" \
    task-fg "https://codeberg.org/alice/myrepo/pulls/42" 2>&1) \
    || fail "fm-pr-check.sh rejected a valid Forgejo URL: $out"
  assert_contains "$out" "armed:" \
    "fm-pr-check.sh must report armed for a valid Forgejo URL"
  # Verify pr= was written to meta.
  meta_url=$(grep '^pr=' "$dir/home/state/task-fg.meta" | head -1 | cut -d= -f2-)
  [ "$meta_url" = "https://codeberg.org/alice/myrepo/pulls/42" ] \
    || fail "pr= in meta wrong: $meta_url"
  # Verify the static poll was armed.
  [ -f "$dir/home/state/task-fg.check.sh" ] \
    || fail "fm-pr-check.sh did not create the check.sh poll"
  pass "fm-pr-check.sh accepts a Forgejo URL, records pr= in meta, and arms the poll"
}

test_forgejo_valid_url_matrix
test_forgejo_url_provider_is_isolated
test_forgejo_invalid_url_matrix
test_poll_merged_pr_emits_merged
test_poll_open_pr_is_silent
test_poll_closed_pr_emits_forgejo_closed
test_poll_missing_creds_emits_unavailable
test_poll_empty_token_emits_unavailable
test_poll_curl_failure_is_silent
test_poll_invalid_host_is_silent
test_poll_reconstructed_url_must_match
test_poll_quoted_token_stripped_before_use
test_pr_check_accepts_forgejo_url
