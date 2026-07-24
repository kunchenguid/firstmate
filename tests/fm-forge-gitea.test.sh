#!/usr/bin/env bash
# Mocked security and lifecycle tests for the Gitea forge foundation.
# No live server, repository, credential, or captain-private config is read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-forge-lib.sh"

FORGE="$ROOT/bin/fm-forge.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-forge-gitea)
TOKEN='fixture-secret-token-ABC123'
PR_URL='http://gitea.lan:3000/Brad/Test-Repo/pulls/7'
HEAD='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

write_config() {
  local dir=$1
  mkdir -p "$dir/config"
  cat > "$dir/config/gitea" <<'EOF'
base_url=http://gitea.lan:3000
account=brad
ssh_alias=forge
ssh_alias=gitea-vpn.lan
ssh_port=2222
EOF
  printf '%s\n' "$TOKEN" > "$dir/config/gitea-token"
  chmod 0600 "$dir/config/gitea" "$dir/config/gitea-token"
}

make_fake_curl() {
  local dir=$1
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
method=GET
url=
output=
data=
auth=$(cat)
printf 'call' >> "$FM_TEST_CURL_ARGV"
[ "${1:-}" = -q ] || exit 96
while [ "$#" -gt 0 ]; do
  printf ' <%s>' "$1" >> "$FM_TEST_CURL_ARGV"
  case "$1" in
    --request) method=$2; shift 2 ;;
    --url) url=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --data-binary) data=${2#@}; shift 2 ;;
    --config|--write-out|--header|--max-time|--max-filesize|--proto) shift 2 ;;
    -q|--silent) shift ;;
    *) exit 91 ;;
  esac
done
printf '\n' >> "$FM_TEST_CURL_ARGV"
[ "$auth" = 'header = "Authorization: token fixture-secret-token-ABC123"' ] || exit 92
[ -z "${FM_GITEA_TOKEN+x}" ] || exit 95
printf 'auth-ok\n' >> "$FM_TEST_CURL_AUTH"
scenario=${FM_TEST_GITEA_SCENARIO:-normal}
fixture_head=${FM_TEST_GITEA_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}
code=200
body=
case "$scenario" in
  auth-fail) code=401; body='{"error":"fixture-secret-token-ABC123 rejected"}' ;;
  malformed) body='{"number":7,"html_url":"http://gitea.lan:3000/Brad/Test-Repo/pulls/7"}' ;;
  cross-host) body='{"number":7,"html_url":"http://evil.lan:3000/Brad/Test-Repo/pulls/7","base":{"repo":{"full_name":"Brad/Test-Repo"}},"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"state":"open","merged":false}' ;;
  *)
    case "$url" in
      */api/v1/user)
        if [ "$scenario" = malformed-account ]; then
          body='{"login":7}'
        elif [ "$scenario" = wrong-account ]; then
          body='{"login":"mallory"}'
        else
          body='{"login":"brad"}'
        fi
        ;;
      */pulls/7/reviews?page=*)
        page=${url##*page=}; page=${page%%&*}
        if [ "$scenario" = malformed-reviews ]; then
          body='[{"id":1,"state":"UNRECOGNIZED","user":{"login":"reviewer"}}]'
        elif [ "$scenario" = reflected-review ]; then
          body='[{"id":1,"state":"APPROVED","user":{"login":"fixture-secret-token-ABC123"},"commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]'
        elif [ "$scenario" = paginated-reviews ] && [ "$page" -eq 1 ]; then
          body=$(jq -cn '[range(1; 21) | {id:.,state:"APPROVED",user:{login:"reviewer"},commit_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]')
        elif [ "$scenario" = paginated-reviews ] && [ "$page" -eq 2 ]; then
          body='[{"id":51,"state":"REQUEST_CHANGES","user":{"login":"second-reviewer"},"commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]'
        elif [ "$scenario" = paginated-reviews ]; then
          body='[]'
        elif [ "$scenario" = malformed-review-page ] && [ "$page" -eq 1 ]; then
          body=$(jq -cn '[range(1; 51) | {id:.,state:"APPROVED",user:{login:"reviewer"},commit_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]')
        elif [ "$scenario" = malformed-review-page ]; then
          body='[{"id":51,"state":"UNRECOGNIZED","user":{"login":"reviewer"}}]'
        elif [ "$scenario" = excessive-reviews ]; then
          body=$(jq -cn --argjson page "$page" '[range(1; 51) | {id:(($page - 1) * 50 + .),state:"APPROVED",user:{login:"reviewer"},commit_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]')
        elif [ "$scenario" = excessive-review-records ]; then
          body=$(jq -cn '[range(1; 1002) | {id:.,state:"APPROVED",user:{login:"reviewer"},commit_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]')
        elif [ "$page" -gt 1 ]; then
          body='[]'
        else
          body='[{"id":1,"state":"APPROVED","user":{"login":"reviewer"},"commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]'
        fi
        ;;
      */commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/statuses?page=*)
        page=${url##*page=}; page=${page%%&*}
        if [ "$scenario" = malformed-checks ]; then
          body='[{"id":2,"status":"unknown","context":"ci/test"}]'
        elif [ "$scenario" = reflected-check ]; then
          body='[{"id":2,"status":"success","context":"ci/test","target_url":"http://ci.invalid/fixture-secret-token-ABC123","description":"passed"}]'
        elif [ "$scenario" = paginated-checks ] && [ "$page" -eq 1 ]; then
          body=$(jq -cn '[range(1; 21) | {id:.,status:"success",context:("ci/" + (.|tostring)),target_url:"http://ci.invalid/status",description:"passed"}]')
        elif [ "$scenario" = paginated-checks ] && [ "$page" -eq 2 ]; then
          body='[{"id":51,"status":"failure","context":"ci/final","target_url":"http://ci.invalid/51","description":"failed"}]'
        elif [ "$scenario" = paginated-checks ]; then
          body='[]'
        elif [ "$page" -gt 1 ]; then
          body='[]'
        else
          body='[{"id":2,"status":"success","context":"ci/test","target_url":"http://ci.invalid/2","description":"passed"}]'
        fi
        ;;
      */pulls/7/merge)
        [ "$method" = POST ] || exit 93
        [ -n "$data" ] && cp "$data" "$FM_TEST_CURL_MERGE_BODY"
        [ "$scenario" = no-confirm ] || : > "$FM_TEST_CURL_MERGED"
        body='{}'
        ;;
      */pulls)
        [ "$method" = POST ] || exit 94
        code=201
        [ -n "$data" ] && cp "$data" "$FM_TEST_CURL_CREATE_BODY"
        body=$(printf '{"number":7,"html_url":"http://gitea.lan:3000/Brad/Test-Repo/pulls/7","base":{"repo":{"full_name":"Brad/Test-Repo"}},"head":{"sha":"%s"},"state":"open","merged":false}' "$fixture_head")
        ;;
      */pulls/7)
        state=open; merged=false
        [ "$scenario" = closed ] && state=closed
        if [ "$scenario" = merged ] || [ -e "$FM_TEST_CURL_MERGED" ]; then state=closed; merged=true; fi
        if [ "$scenario" = reflected-pr ]; then
          body=$(printf '{"number":7,"html_url":"http://gitea.lan:3000/Brad/Test-Repo/pulls/7","base":{"repo":{"full_name":"Brad/Test-Repo"}},"head":{"sha":"%s"},"state":"%s","merged":%s,"title":"fixture-secret-token-ABC123"}' "$fixture_head" "$state" "$merged")
        else
          body=$(printf '{"number":7,"html_url":"http://gitea.lan:3000/Brad/Test-Repo/pulls/7","base":{"repo":{"full_name":"Brad/Test-Repo"}},"head":{"sha":"%s"},"state":"%s","merged":%s}' "$fixture_head" "$state" "$merged")
        fi
        ;;
      *) code=404; body='{"message":"not found"}' ;;
    esac
    ;;
esac
printf '%s' "$body" > "$output"
printf '%s' "$code"
SH
  chmod 0755 "$dir/fakebin/curl"
  : > "$dir/curl.argv"
  : > "$dir/curl.auth"
}

make_repo() {
  local dir=$1 origin=${2:-git@forge:Brad/Test-Repo.git}
  mkdir -p "$dir/repo"
  git -C "$dir/repo" init -q
  git -C "$dir/repo" remote add origin "$origin"
}

run_forge() {
  local dir=$1; shift
  FM_CONFIG_OVERRIDE="$dir/config" \
  FM_FORGE_CURL_BIN="$dir/fakebin/curl" \
  FM_TEST_CURL_ARGV="$dir/curl.argv" \
  FM_TEST_CURL_AUTH="$dir/curl.auth" \
  FM_TEST_CURL_CREATE_BODY="$dir/create.body" \
  FM_TEST_CURL_MERGE_BODY="$dir/merge.body" \
  FM_TEST_CURL_MERGED="$dir/merged.marker" \
  "$FORGE" "$@"
}

assert_token_absent_tree() {
  local dir=$1
  if grep -R -F "$TOKEN" "$dir" \
      --exclude=gitea-token --exclude=curl --exclude='*.test.sh' >/dev/null 2>&1; then
    fail "token escaped its private fixture file"
  fi
}

test_canonical_pr_parser() {
  local url
  while IFS= read -r url; do
    fm_pr_url_parse "$url" || fail "Gitea parser rejected $url"
    [ "$FM_PR_PROVIDER" = gitea ] || fail "Gitea parser returned wrong provider"
    [ "$FM_PR_PATH" = Brad/Test-Repo ] || fail "Gitea parser returned wrong path"
  done <<'EOF'
http://gitea.lan:3000/Brad/Test-Repo/pulls/7
https://10.0.0.8:8443/Brad/Test-Repo/pulls/7
https://code.internal/Brad/Test-Repo/pulls/7
EOF
  for url in \
    'HTTP://gitea.lan:3000/Brad/Test-Repo/pulls/7' \
    'http://Gitea.lan:3000/Brad/Test-Repo/pulls/7' \
    'http://gitea.lan:03000/Brad/Test-Repo/pulls/7' \
    'http://gitea.lan:65536/Brad/Test-Repo/pulls/7' \
    'http://user@gitea.lan:3000/Brad/Test-Repo/pulls/7' \
    'http://gitea.lan:3000/Brad/Test-Repo.git/pulls/7' \
    'http://gitea.lan:3000/Brad/Test-Repo/pulls/07' \
    'http://gitea.lan:3000/Brad/Test-Repo/pulls/7?x=1' \
    'https://github.com/Brad/Test-Repo/pulls/7'; do
    ! fm_pr_url_parse "$url" || fail "Gitea parser accepted noncanonical $url"
  done
  fm_pr_url_parse https://github.com/o/r/pull/1 || fail "GitHub canonical URL regressed"
  [ "$FM_PR_PROVIDER" = github ] || fail "GitHub provider regressed"
  fm_pr_url_parse https://gitlab.com/g/p/-/merge_requests/1 || fail "GitLab canonical URL regressed"
  [ "$FM_PR_PROVIDER" = gitlab ] || fail "GitLab provider regressed"
  pass "Gitea PR identities support private HTTP ports without loosening GitHub or GitLab"
}

test_origin_alias_and_port_binding() {
  local dir origin
  dir="$TMP_ROOT/origins"
  write_config "$dir"
  for origin in \
    'http://gitea.lan:3000/Brad/Test-Repo.git' \
    'ssh://git@forge:2222/Brad/Test-Repo.git' \
    'ssh://git@gitea.lan:2222/Brad/Test-Repo.git' \
    'git@forge:Brad/Test-Repo.git' \
    'git@gitea-vpn.lan:Brad/Test-Repo.git'; do
    FM_CONFIG_OVERRIDE="$dir/config" fm_forge_repo_url_parse "$origin" \
      || fail "configured Gitea origin was rejected: $origin"
    [ "$FM_FORGE_REPO_PROVIDER" = gitea ] || fail "origin returned wrong provider"
    [ "$FM_FORGE_REPO_URL" = 'http://gitea.lan:3000/Brad/Test-Repo' ] \
      || fail "origin did not reconstruct canonical repo URL"
  done
  for origin in \
    'http://other.lan:3000/Brad/Test-Repo.git' \
    'ssh://git@forge:22/Brad/Test-Repo.git' \
    'ssh://git@other:2222/Brad/Test-Repo.git' \
    'git@other:Brad/Test-Repo.git'; do
    ! FM_CONFIG_OVERRIDE="$dir/config" fm_forge_repo_url_parse "$origin" \
      || fail "cross-host Gitea origin was accepted: $origin"
  done
  FM_CONFIG_OVERRIDE="$dir/config" fm_forge_repo_url_parse git@github.com:owner/repo.git \
    || fail "GitHub repository identity regressed"
  [ "$FM_FORGE_REPO_PROVIDER:$FM_FORGE_REPO_PATH" = github:owner/repo ] \
    || fail "GitHub repository identity changed"
  FM_CONFIG_OVERRIDE="$dir/config" fm_forge_repo_url_parse https://gitlab.com/group/subgroup/repo.git \
    || fail "nested GitLab repository identity was not recognized"
  [ "$FM_FORGE_REPO_PROVIDER:$FM_FORGE_REPO_PATH" = gitlab:group/subgroup/repo ] \
    || fail "GitLab repository identity changed"
  pass "forge repository identities bind Gitea aliases while preserving GitHub and nested GitLab"
}

test_private_configuration_and_token_custody() {
  local dir out rc scenario_command scenario command_name
  dir="$TMP_ROOT/custody"
  write_config "$dir"
  make_fake_curl "$dir"
  make_repo "$dir"

  chmod 0644 "$dir/config/gitea-token"
  set +e
  out=$(run_forge "$dir" pr-state "$PR_URL" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "world-readable token was accepted"
  assert_contains "$out" 'not mode 0600' "unsafe token mode refusal was unclear"
  chmod 0600 "$dir/config/gitea-token"

  chmod 0644 "$dir/config/gitea"
  set +e
  out=$(run_forge "$dir" provider "$dir/repo" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "world-readable Gitea config was accepted"
  chmod 0600 "$dir/config/gitea"

  printf '%s\n%s\n' "$TOKEN" extra > "$dir/config/gitea-token"
  chmod 0600 "$dir/config/gitea-token"
  set +e
  out=$(run_forge "$dir" pr-state "$PR_URL" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "multiline token file was accepted"
  printf '%s\n' "$TOKEN" > "$dir/config/token-target"
  chmod 0600 "$dir/config/token-target"
  rm -f "$dir/config/gitea-token"
  ln -s "$dir/config/token-target" "$dir/config/gitea-token"
  set +e
  out=$(run_forge "$dir" pr-state "$PR_URL" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "symlinked token file was accepted"
  rm -f "$dir/config/gitea-token" "$dir/config/token-target"
  printf '%s\n' "$TOKEN" > "$dir/config/gitea-token"
  chmod 0600 "$dir/config/gitea-token"

  printf '%s\n' 'base_url=http://gitea.lan:3000' 'base_url=http://gitea.lan:4000' \
    'account=brad' > "$dir/config/gitea"
  chmod 0600 "$dir/config/gitea"
  set +e
  out=$(run_forge "$dir" provider "$dir/repo" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "duplicate Gitea base URL was accepted"
  write_config "$dir"

  out=$(run_forge "$dir" pr-state "$PR_URL" 2> "$dir/stderr") \
    || fail "valid private Gitea state lookup failed"
  [ "$out" = open ] || fail "valid state lookup returned $out"
  grep -qxF auth-ok "$dir/curl.auth" || fail "curl did not receive auth over stdin config"
  grep -q '^call <-q>' "$dir/curl.argv" \
    || fail "authenticated curl did not disable ambient configuration first"
  assert_no_grep "$TOKEN" "$dir/curl.argv" "token appeared in curl argv"
  assert_no_grep "$TOKEN" "$dir/stderr" "token appeared in successful diagnostics"

  set +e
  out=$(FM_TEST_GITEA_SCENARIO=auth-fail run_forge "$dir" pr-state "$PR_URL" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Gitea auth failure was accepted"
  assert_contains "$out" 'response contained private authentication data' "reflected auth failure was not fixed and safe"
  case "$out" in *"$TOKEN"*) fail "reflected auth error exposed the token" ;; esac

  for scenario_command in reflected-pr:pr-state reflected-review:pr-reviews reflected-check:pr-checks; do
    scenario=${scenario_command%%:*}
    command_name=${scenario_command##*:}
    set +e
    out=$(FM_TEST_GITEA_SCENARIO=$scenario run_forge "$dir" "$command_name" "$PR_URL" 2>&1); rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$scenario Gitea response was accepted"
    assert_contains "$out" 'response contained private authentication data' \
      "$scenario refusal was unclear"
    case "$out" in *"$TOKEN"*) fail "$scenario response exposed the token" ;; esac
  done
  assert_token_absent_tree "$dir"
  pass "Gitea config permissions and stdin-only token custody fail safely"
}

test_pr_operations_and_malformed_responses() {
  local dir out rc scenario_command scenario command_name branch reviews checks
  dir="$TMP_ROOT/operations"
  write_config "$dir"
  make_fake_curl "$dir"
  make_repo "$dir"
  printf 'Body fixture.\n' > "$dir/body.md"

  out=$(run_forge "$dir" pr-create "$dir/repo" --head fm/topic --base main \
    --title 'Fixture PR' --body-file "$dir/body.md") || fail "Gitea PR create failed"
  [ "$out" = "$PR_URL" ] || fail "Gitea PR create did not return canonical URL"
  jq -e '.head == "fm/topic" and .base == "main" and .title == "Fixture PR" and .body == "Body fixture."' \
    "$dir/create.body" >/dev/null || fail "Gitea PR create body was malformed"

  for branch in '.hidden' 'feature..topic' 'feature.lock' 'feature/' 'feature//topic' 'feature@{topic}'; do
    : > "$dir/curl.argv"
    set +e
    out=$(run_forge "$dir" pr-create "$dir/repo" --head "$branch" --base main \
      --title 'Fixture PR' --body-file "$dir/body.md" 2>&1); rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Git-invalid Gitea head branch was accepted: $branch"
    assert_contains "$out" 'branches are invalid' "Git-invalid branch refusal was unclear"
    [ ! -s "$dir/curl.argv" ] || fail "Git-invalid branch triggered a Gitea request: $branch"
  done

  for scenario in malformed-account wrong-account; do
    : > "$dir/curl.argv"
    set +e
    out=$(FM_TEST_GITEA_SCENARIO=$scenario run_forge "$dir" pr-state "$PR_URL" 2>&1); rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$scenario Gitea account response was accepted"
    assert_contains "$out" 'authenticated account does not match' \
      "$scenario Gitea account refusal was unclear"
    assert_no_grep '/repos/' "$dir/curl.argv" \
      "$scenario Gitea account response allowed a repository request"
  done

  [ "$(run_forge "$dir" pr-head "$PR_URL")" = "$HEAD" ] || fail "Gitea PR head failed"
  [ "$(FM_TEST_GITEA_SCENARIO=closed run_forge "$dir" pr-state "$PR_URL")" = closed ] \
    || fail "Gitea closed-unmerged state was misread"
  [ -z "$(FM_TEST_GITEA_SCENARIO=closed run_forge "$dir" pr-merged "$PR_URL")" ] \
    || fail "closed-unmerged Gitea PR reported merged"
  assert_contains "$(run_forge "$dir" pr-reviews "$PR_URL")" '"state":"APPROVED"' \
    "Gitea reviews were not validated"
  assert_contains "$(run_forge "$dir" pr-checks "$PR_URL")" '"status":"success"' \
    "Gitea checks were not validated"
  reviews=$(FM_TEST_GITEA_SCENARIO=paginated-reviews run_forge "$dir" pr-reviews "$PR_URL")
  [ "$(jq 'length' <<< "$reviews")" -eq 21 ] || fail "Gitea review pagination omitted records"
  assert_contains "$reviews" '"state":"REQUEST_CHANGES"' \
    "Gitea review pagination omitted a later change request"
  checks=$(FM_TEST_GITEA_SCENARIO=paginated-checks run_forge "$dir" pr-checks "$PR_URL")
  [ "$(jq 'length' <<< "$checks")" -eq 21 ] || fail "Gitea check pagination omitted records"
  assert_contains "$checks" '"status":"failure"' \
    "Gitea check pagination omitted a later failure"

  set +e
  out=$(FM_TEST_GITEA_SCENARIO=malformed-review-page run_forge "$dir" pr-reviews "$PR_URL" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "malformed later Gitea review page was accepted"
  assert_contains "$out" 'malformed review data' "malformed later review page refusal was unclear"
  : > "$dir/curl.argv"
  set +e
  out=$(FM_TEST_GITEA_SCENARIO=excessive-reviews run_forge "$dir" pr-reviews "$PR_URL" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "excessive Gitea review pagination was accepted"
  assert_contains "$out" 'pagination safety limit' "excessive review pagination refusal was unclear"
  [ "$(grep -c 'reviews?page=' "$dir/curl.argv")" -le 20 ] \
    || fail "Gitea review pagination exceeded its request bound"
  set +e
  out=$(FM_TEST_GITEA_SCENARIO=excessive-review-records run_forge "$dir" pr-reviews "$PR_URL" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "excessive Gitea review record count was accepted"
  assert_contains "$out" 'record safety limit' "excessive review record refusal was unclear"

  for scenario_command in malformed:pr-head cross-host:pr-head malformed-reviews:pr-reviews malformed-checks:pr-checks; do
    scenario=${scenario_command%%:*}
    command_name=${scenario_command##*:}
    set +e
    out=$(FM_TEST_GITEA_SCENARIO=$scenario run_forge "$dir" "$command_name" "$PR_URL" 2>&1); rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$scenario Gitea response was accepted"
    case "$out" in *"$TOKEN"*) fail "$scenario response exposed token" ;; esac
  done
  set +e
  out=$(run_forge "$dir" pr-state 'http://other.lan:3000/Brad/Test-Repo/pulls/7' 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cross-host PR request was sent"
  assert_contains "$out" 'does not match private configuration' "cross-host refusal was unclear"
  pass "Gitea create, head, state, reviews, and checks validate exact response identities"
}

make_lifecycle_case() {
  local dir=$1
  write_config "$dir"
  make_fake_curl "$dir"
  mkdir -p "$dir/home/state" "$dir/fake-root/bin" "$dir/wt"
  cat > "$dir/fake-root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod 0755 "$dir/fake-root/bin/fm-guard.sh"
  fm_write_meta "$dir/home/state/task-g.meta" \
    'window=fm-task-g' \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=direct-PR'
}

run_check() {
  local dir=$1
  FM_ROOT_OVERRIDE="$dir/fake-root" FM_HOME="$dir/home" FM_CONFIG_OVERRIDE="$dir/config" \
  FM_FORGE_CURL_BIN="$dir/fakebin/curl" FM_TEST_CURL_ARGV="$dir/curl.argv" \
  FM_TEST_CURL_AUTH="$dir/curl.auth" FM_TEST_CURL_CREATE_BODY="$dir/create.body" \
  FM_TEST_CURL_MERGE_BODY="$dir/merge.body" FM_TEST_CURL_MERGED="$dir/merged.marker" \
    "$PR_CHECK" task-g "$PR_URL"
}

run_merge() {
  local dir=$1; shift
  FM_ROOT_OVERRIDE="$dir/fake-root" FM_HOME="$dir/home" FM_CONFIG_OVERRIDE="$dir/config" \
  FM_FORGE_CURL_BIN="$dir/fakebin/curl" FM_TEST_CURL_ARGV="$dir/curl.argv" \
  FM_TEST_CURL_AUTH="$dir/curl.auth" FM_TEST_CURL_CREATE_BODY="$dir/create.body" \
  FM_TEST_CURL_MERGE_BODY="$dir/merge.body" FM_TEST_CURL_MERGED="$dir/merged.marker" \
    "$PR_MERGE" task-g "$PR_URL" "$@"
}

test_check_poll_and_guarded_merge() {
  local dir out rc
  dir="$TMP_ROOT/lifecycle"
  make_lifecycle_case "$dir"
  set +e
  FM_TEST_GITEA_SCENARIO=auth-fail run_check "$dir" > "$dir/auth-check.out" 2> "$dir/auth-check.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fm-pr-check armed after a Gitea auth failure"
  assert_absent "$dir/home/state/task-g.check.sh" "auth failure published a Gitea poll"
  assert_no_grep '^pr=' "$dir/home/state/task-g.meta" "auth failure recorded a Gitea PR"
  assert_no_grep "$TOKEN" "$dir/auth-check.err" "auth failure exposed token through fm-pr-check"

  run_check "$dir" > "$dir/check.out" 2> "$dir/check.err" || fail "Gitea PR check failed"
  grep -qxF "pr=$PR_URL" "$dir/home/state/task-g.meta" || fail "Gitea canonical PR was not recorded"
  grep -qxF "pr_head=$HEAD" "$dir/home/state/task-g.meta" || fail "Gitea PR head was not recorded"
  [ "$(cat "$dir/home/state/task-g.pr-poll")" = $'gitea\nhttp://gitea.lan:3000/Brad/Test-Repo/pulls/7\ngitea.lan:3000\nBrad/Test-Repo\n7' ] \
    || fail "Gitea poll sidecar was not canonical"
  cmp -s "$POLL" "$dir/home/state/task-g.check.sh" || fail "Gitea poll was not static"
  assert_no_grep "$TOKEN" "$dir/home/state/task-g.meta" "token reached metadata"
  assert_no_grep "$TOKEN" "$dir/home/state/task-g.check.sh" "token reached generated check"
  assert_no_grep "$TOKEN" "$dir/home/state/task-g.pr-poll" "token reached poll data"

  out=$(FM_HOME="$dir/home" FM_CONFIG_OVERRIDE="$dir/config" FM_FORGE_CURL_BIN="$dir/fakebin/curl" \
    FM_TEST_CURL_ARGV="$dir/curl.argv" FM_TEST_CURL_AUTH="$dir/curl.auth" \
    FM_TEST_CURL_CREATE_BODY="$dir/create.body" FM_TEST_CURL_MERGE_BODY="$dir/merge.body" \
    FM_TEST_CURL_MERGED="$dir/merged.marker" FM_TEST_GITEA_SCENARIO=closed \
    "$POLL" --validated gitea "$PR_URL" gitea.lan:3000 Brad/Test-Repo 7)
  [ -z "$out" ] || fail "closed-unmerged Gitea poll emitted output"
  out=$(FM_HOME="$dir/home" FM_CONFIG_OVERRIDE="$dir/config" FM_FORGE_CURL_BIN="$dir/fakebin/curl" \
    FM_TEST_CURL_ARGV="$dir/curl.argv" FM_TEST_CURL_AUTH="$dir/curl.auth" \
    FM_TEST_CURL_CREATE_BODY="$dir/create.body" FM_TEST_CURL_MERGE_BODY="$dir/merge.body" \
    FM_TEST_CURL_MERGED="$dir/merged.marker" FM_TEST_GITEA_SCENARIO=auth-fail \
    "$POLL" --validated gitea "$PR_URL" gitea.lan:3000 Brad/Test-Repo 7)
  [ -z "$out" ] || fail "auth-failed Gitea poll emitted output"
  assert_present "$dir/home/state/task-g.check.sh" "auth-failed poll retired its evidence"
  out=$(FM_HOME="$dir/home" FM_CONFIG_OVERRIDE="$dir/config" FM_FORGE_CURL_BIN="$dir/fakebin/curl" \
    FM_TEST_CURL_ARGV="$dir/curl.argv" FM_TEST_CURL_AUTH="$dir/curl.auth" \
    FM_TEST_CURL_CREATE_BODY="$dir/create.body" FM_TEST_CURL_MERGE_BODY="$dir/merge.body" \
    FM_TEST_CURL_MERGED="$dir/merged.marker" FM_TEST_GITEA_SCENARIO=merged \
    "$POLL" --validated gitea "$PR_URL" gitea.lan:3000 Brad/Test-Repo 7)
  [ "$out" = merged ] || fail "merged Gitea poll did not emit exactly merged"

  rm -f "$dir/merged.marker"
  run_merge "$dir" -- --squash --delete-branch > "$dir/merge.out" 2> "$dir/merge.err" \
    || fail "guarded Gitea merge failed: $(cat "$dir/merge.err")"
  jq -e '.Do == "squash" and .delete_branch_after_merge == true' "$dir/merge.body" >/dev/null \
    || fail "Gitea merge payload did not preserve method and delete choice"

  rm -f "$dir/merged.marker"
  set +e
  FM_TEST_GITEA_SCENARIO=no-confirm run_merge "$dir" -- --merge > "$dir/unconfirmed.out" 2> "$dir/unconfirmed.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unconfirmed Gitea merge reported success"
  assert_token_absent_tree "$dir"
  pass "fm-pr-check, static polling, and approval-path merge support canonical Gitea PRs"
}

test_gitea_teardown_landed_check() {
  local dir head
  dir="$TMP_ROOT/teardown"
  write_config "$dir"
  make_fake_curl "$dir"
  mkdir -p "$dir/home/state" "$dir/data" "$dir/fake-root/bin" "$dir/fakebin"
  cat > "$dir/fake-root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$dir/fake-root/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod 0755 "$dir/fake-root/bin/fm-guard.sh" "$dir/fake-root/bin/fm-fleet-sync.sh" \
    "$dir/fakebin/treehouse" "$dir/fakebin/tmux"

  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/seed" 2>/dev/null
  git -C "$dir/seed" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -q --allow-empty -m baseline
  git -C "$dir/seed" push -q origin main
  git clone -q "$dir/origin.git" "$dir/project"
  git -C "$dir/project" worktree add -q -b fm/task-g-teardown "$dir/wt" main
  git -C "$dir/wt" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -q --allow-empty -m feature
  head=$(git -C "$dir/wt" rev-parse HEAD)
  fm_write_meta "$dir/home/state/task-g-teardown.meta" \
    'window=fm-task-g-teardown' \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=direct-PR' \
    "pr=$PR_URL" \
    "pr_head=$head"
  touch "$dir/home/state/.last-watcher-beat"

  FM_ROOT_OVERRIDE="$dir/fake-root" FM_HOME="$dir/home" \
  FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/data" \
  FM_CONFIG_OVERRIDE="$dir/config" FM_FORGE_CURL_BIN="$dir/fakebin/curl" \
  FM_TEST_CURL_ARGV="$dir/curl.argv" FM_TEST_CURL_AUTH="$dir/curl.auth" \
  FM_TEST_CURL_CREATE_BODY="$dir/create.body" FM_TEST_CURL_MERGE_BODY="$dir/merge.body" \
  FM_TEST_CURL_MERGED="$dir/merged.marker" FM_TEST_GITEA_SCENARIO=merged \
  FM_TEST_GITEA_HEAD="$head" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" task-g-teardown > "$dir/teardown.out" 2> "$dir/teardown.err" \
    || fail "Gitea merged-PR teardown refused: $(cat "$dir/teardown.err")"
  assert_absent "$dir/home/state/task-g-teardown.meta" "Gitea landed cleanup retained task metadata"
  assert_no_grep "$TOKEN" "$dir/teardown.err" "Gitea landed cleanup exposed token"
  pass "Gitea merged-state and head evidence satisfy the existing guarded cleanup check"
}

test_gitea_direct_pr_brief() {
  local dir brief
  dir="$TMP_ROOT/brief"
  write_config "$dir"
  mkdir -p "$dir/data" "$dir/projects/gitea-project"
  git -C "$dir/projects/gitea-project" init -q
  git -C "$dir/projects/gitea-project" remote add origin git@forge:Brad/Test-Repo.git
  printf '%s\n' '- gitea-project [direct-PR] - Gitea fixture (added 2026-07-21)' > "$dir/data/projects.md"
  FM_HOME="$dir" "$ROOT/bin/fm-brief.sh" task-gitea gitea-project >/dev/null \
    || fail "Gitea direct-PR brief generation failed"
  brief="$dir/data/task-gitea/brief.md"
  assert_grep 'fm-forge.sh pr-create' "$brief" "Gitea brief omitted common PR creation helper"
  assert_grep 'do not use GitHub-only PR tooling' "$brief" "Gitea brief retained GitHub-only PR instruction"
  # shellcheck disable=SC2016  # Backticks are literal generated brief text.
  assert_no_grep 'open a PR with `gh-axi`' "$brief" "Gitea brief told worker to use gh-axi"
  pass "registered Gitea direct-PR projects receive provider-correct worker instructions"
}

test_canonical_pr_parser
test_origin_alias_and_port_binding
test_private_configuration_and_token_custody
test_pr_operations_and_malformed_responses
test_check_poll_and_guarded_merge
test_gitea_teardown_landed_check
test_gitea_direct_pr_brief
