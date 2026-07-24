#!/usr/bin/env bash
# Focused behavior tests for complete public PR/MR publication attestation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PUBLICATION_CHECK="$ROOT/bin/fm-pr-publication-check.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-publication-check)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
REAL_MKTEMP=$(command -v mktemp)
REAL_SED=$(command -v sed)
REAL_AWK=$(command -v awk)
REAL_SORT=$(command -v sort)
REAL_RM=$(command -v rm)
GITHUB_URL=https://github.com/example/project/pull/17
GITHUB_HEAD=1111111111111111111111111111111111111111
GITLAB_URL=https://gitlab.example/group/project/-/merge_requests/23
GITLAB_HEAD=2222222222222222222222222222222222222222

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
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake-root/bin" "$fakebin"
  git -C "$dir" init -q worktree
  git -C "$dir/worktree" remote add origin https://github.com/example/project.git
  fm_write_meta "$dir/home/state/task-a.meta" \
    'window=fm-task-a' \
    "worktree=$dir/worktree" \
    'project=synthetic' \
    'kind=ship' \
    'mode=no-mistakes'
  cat > "$dir/fake-root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
if [ "${1:-}" = api ]; then
  [ "${FM_TEST_EVIDENCE_RC:-0}" -eq 0 ] || exit "$FM_TEST_EVIDENCE_RC"
  case "${FM_TEST_EVIDENCE_KIND:-file}" in
    file)
      jq -n --arg sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        '{type:"file",sha:$sha}'
      ;;
    directory)
      jq -n '[{type:"file",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]'
      ;;
    malformed) printf '%s\n' '{not-json' ;;
    *) exit 1 ;;
  esac
  exit 0
fi
case "${1:-} ${2:-}" in
  'repo view')
    cat "$FM_TEST_REPO_FILE"
    exit 0
    ;;
  'pr view')
    [ "${FM_TEST_GH_READ_RC:-0}" -eq 0 ] || exit "$FM_TEST_GH_READ_RC"
    if [ "${FM_TEST_READY_READBACK_FAIL:-0}" -eq 1 ] \
      && [ "$(cat "$FM_TEST_DRAFT_FILE")" = false ]; then
      exit 1
    fi
    printf '%s\n%s\n' "$FM_TEST_PR_URL" "$FM_TEST_PR_HEAD"
    base64 < "$FM_TEST_BODY_FILE" | tr -d '\n'
    printf '\n%s\n' "$(cat "$FM_TEST_DRAFT_FILE")"
    exit 0
    ;;
  'pr ready')
    [ "${4:-}" = --undo ] || exit 1
    [ "${FM_TEST_ROLLBACK_RC:-0}" -eq 0 ] || exit "$FM_TEST_ROLLBACK_RC"
    printf '%s\n' true > "$FM_TEST_DRAFT_FILE"
    ;;
esac
exit 1
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  'pr view')
    jq -n --rawfile body "${FM_TEST_AXI_BODY_FILE:-$FM_TEST_BODY_FILE}" --argjson number "$3" \
      '{pull_request:{number:$number,body:$body}}'
    ;;
  'pr ready') printf '%s\n' false > "$FM_TEST_DRAFT_FILE" ;;
  'api GET')
    number=${3##*/}
    jq -n --rawfile body "$FM_TEST_BODY_FILE" --argjson number "$number" --arg head "$FM_TEST_PR_HEAD" \
      '{number:$number,body:$body,head:{sha:$head}}'
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GLAB_LOG"
case "${1:-} ${2:-}" in
  'mr view')
    jq -n --rawfile description "$FM_TEST_BODY_FILE" \
      --arg web_url "$FM_TEST_PR_URL" --arg sha "$FM_TEST_PR_HEAD" \
      --argjson draft "$(cat "$FM_TEST_DRAFT_FILE")" \
      '{web_url:$web_url,sha:$sha,description:$description,draft:$draft}'
    ;;
  'mr update')
    case " $* " in
      *" --draft "*) printf '%s\n' true > "$FM_TEST_DRAFT_FILE" ;;
      *) printf '%s\n' false > "$FM_TEST_DRAFT_FILE" ;;
    esac
    ;;
  'api --hostname')
    [ "${FM_TEST_EVIDENCE_RC:-0}" -eq 0 ] || exit "$FM_TEST_EVIDENCE_RC"
    case "${FM_TEST_EVIDENCE_KIND:-file}" in
      file)
        jq -n --arg path "$FM_TEST_EVIDENCE_PATH" --arg ref "$FM_TEST_PR_HEAD" \
          --arg blob aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
          '{file_path:$path,ref:$ref,blob_id:$blob}'
        ;;
      directory)
        jq -n --arg path "$FM_TEST_EVIDENCE_PATH" --arg ref "$FM_TEST_PR_HEAD" \
          '{file_path:$path,ref:$ref,blob_id:null}'
        ;;
      malformed) printf '%s\n' '{not-json' ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fake-root/bin/fm-guard.sh" "$fakebin/gh" "$fakebin/gh-axi" "$fakebin/glab"
  : > "$dir/gh.log"
  : > "$dir/gh-axi.log"
  : > "$dir/glab.log"
  printf '%s\n' true > "$dir/draft"
  printf '%s\n' example/project > "$dir/repo-path"
  printf '%s\n' "$dir"
}

write_body() {
  local dir=$1 content=$2
  printf '%s' "$content" > "$dir/body.md"
}

safe_body() {
  cat <<'EOF'
## Intent

Make publication checks deterministic for the complete pull request.

## What Changed

- Added exact public body and head validation for `src/app.ts`.
- Kept ordinary source paths such as `src/auth/Jwt.Token.Parser.ts` publishable.
- Kept `src/longmodule.longmodule.verylongfilenamecomponent.ts` publishable.
- Documented the supported Windows install path `C:\Program Files\Example\config.ini` without exposing a user profile.

## Testing

Focused shell tests cover the accepted behavior.
EOF
}

run_gate() {
  local dir=$1 url=$2 head=$3; shift 3
  FM_ROOT_OVERRIDE="$dir/fake-root" FM_HOME="$dir/home" \
    FM_TEST_PR_URL="$url" FM_TEST_PR_HEAD="$head" FM_TEST_BODY_FILE="$dir/body.md" \
    FM_TEST_AXI_BODY_FILE="${FM_TEST_AXI_BODY_FILE:-$dir/body.md}" \
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
    FM_TEST_GLAB_LOG="$dir/glab.log" FM_TEST_DRAFT_FILE="$dir/draft" \
    FM_TEST_REPO_FILE="$dir/repo-path" FM_TEST_EVIDENCE_PATH="${FM_TEST_EVIDENCE_PATH:-evidence/result.txt}" \
    FM_TEST_EVIDENCE_KIND="${FM_TEST_EVIDENCE_KIND:-file}" \
    FM_TEST_READY_READBACK_FAIL="${FM_TEST_READY_READBACK_FAIL:-0}" \
    FM_TEST_ROLLBACK_RC="${FM_TEST_ROLLBACK_RC:-0}" FM_TEST_GH_READ_RC="${FM_TEST_GH_READ_RC:-0}" \
    FM_TEST_REAL_MKTEMP="$REAL_MKTEMP" FM_TEST_REAL_SED="$REAL_SED" \
    FM_TEST_REAL_AWK="$REAL_AWK" FM_TEST_REAL_SORT="$REAL_SORT" FM_TEST_REAL_RM="$REAL_RM" \
    FM_TEST_SCRATCH_FAIL_STAGE="${FM_TEST_SCRATCH_FAIL_STAGE:-}" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PUBLICATION_CHECK" "$@"
}

install_scratch_fault_tools() {
  local dir=$1
  cat > "$dir/fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
case "${FM_TEST_SCRATCH_FAIL_STAGE:-}:${1:-}" in
  initial-create:*.fm-pr-publication-body.*|intent-create:*.fm-pr-publication-intent.*|outcome-create:*.fm-pr-publication-outcome.*) exit 1 ;;
esac
exec "$FM_TEST_REAL_MKTEMP" "$@"
SH
  cat > "$dir/fakebin/sed" <<'SH'
#!/usr/bin/env bash
[ "${FM_TEST_SCRATCH_FAIL_STAGE:-}" != scan-write ] || exit 1
exec "$FM_TEST_REAL_SED" "$@"
SH
  cat > "$dir/fakebin/awk" <<'SH'
#!/usr/bin/env bash
case "${FM_TEST_SCRATCH_FAIL_STAGE:-}:$*" in
  intent-write:*wanted=intent*|outcome-write:*wanted=outcome*) exit 1 ;;
esac
exec "$FM_TEST_REAL_AWK" "$@"
SH
  cat > "$dir/fakebin/sort" <<'SH'
#!/usr/bin/env bash
[ "${FM_TEST_SCRATCH_FAIL_STAGE:-}" != url-list-write ] || exit 1
exec "$FM_TEST_REAL_SORT" "$@"
SH
  cat > "$dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_SCRATCH_FAIL_STAGE:-}" = cleanup ]; then
  case "$*" in
    *fm-pr-publication-*) exit 1 ;;
  esac
fi
exec "$FM_TEST_REAL_RM" "$@"
SH
  chmod +x "$dir/fakebin/mktemp" "$dir/fakebin/sed" "$dir/fakebin/awk" \
    "$dir/fakebin/sort" "$dir/fakebin/rm"
}

attest_none() {
  local dir=$1 url=${2:-$GITHUB_URL} head=${3:-$GITHUB_HEAD}
  run_gate "$dir" "$url" "$head" attest task-a "$url" \
    --intent-outcome-complete --evidence none-required
}

assert_attest_rejected() {
  local name=$1 body=$2 expected=$3 dir rc
  dir=$(make_case "$name")
  write_body "$dir" "$body"
  set +e
  attest_none "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$name: unsafe body passed publication attestation"
  assert_grep "$expected" "$dir/stderr" "$name: refusal was not actionable"
  assert_absent "$dir/home/state/task-a.pr-publication" "$name: failed attestation wrote a passing receipt"
}

test_help_documents_publication_mechanics() {
  local help check_help
  help=$("$PUBLICATION_CHECK" --help)
  check_help=$("$PR_CHECK" --help)
  assert_contains "$help" 'attest <task-id> <pr-url>' "publication help omitted attest usage"
  assert_contains "$help" 'verify <task-id> <pr-url>' "publication help omitted verify usage"
  assert_contains "$help" 'Neither mode edits a PR body.' "publication help omitted correction ownership"
  assert_contains "$help" 'gh-axi pr create --draft' "publication help omitted GitHub draft creation"
  assert_contains "$help" 'glab mr update <number> -R <repo> --draft' "publication help omitted GitLab drift correction"
  assert_contains "$help" 'percent-decoded once and API-encoded once' \
    "publication help omitted GitLab evidence path encoding"
  assert_contains "$check_help" 'complete public body, exact head' "fm-pr-check help omitted its publication prerequisite"
  pass "publication and monitoring help describe the exact gate mechanics"
}

test_safe_nonvisual_body_and_legitimate_paths_pass() {
  local dir receipt
  dir=$(make_case safe-nonvisual)
  safe_body > "$dir/body.md"
  attest_none "$dir" > "$dir/attest.out" 2> "$dir/attest.err" \
    || fail "safe nonvisual body failed: $(cat "$dir/attest.err")"
  receipt="$dir/home/state/task-a.pr-publication"
  assert_present "$receipt" "safe attestation did not write a private receipt"
  [ "$(file_mode "$receipt")" = 600 ] || fail "publication receipt mode was not 0600"
  grep -qxF privacy=pass "$receipt" || fail "receipt lost privacy verdict"
  grep -qxF links=pass "$receipt" || fail "receipt lost link verdict"
  grep -qxF attestation=agent-explicit "$receipt" || fail "receipt lost explicit attestation verdict"
  grep -qxF evidence_mode=none-required "$receipt" || fail "nonvisual no-evidence mode was not recorded"
  grep -qxF evidence_count=0 "$receipt" || fail "nonvisual PR unexpectedly required image evidence"
  run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" verify task-a "$GITHUB_URL" \
    > "$dir/verify.out" 2> "$dir/verify.err" \
    || fail "safe receipt did not verify: $(cat "$dir/verify.err")"
  grep -Eq '^verified 1111111111111111111111111111111111111111 [0-9]+ [0-9a-f]{64}$' "$dir/verify.out" \
    || fail "verify did not return exact bound evidence"
  pass "publication check accepts nonvisual work without screenshots and ignores legitimate technical paths"
}

test_complete_github_readbacks_must_match() {
  local dir rc
  dir=$(make_case mismatched-github-readbacks)
  safe_body > "$dir/body.md"
  safe_body > "$dir/axi-body.md"
  printf '\nPublic bytes changed between readbacks.\n' >> "$dir/axi-body.md"
  set +e
  FM_TEST_AXI_BODY_FILE="$dir/axi-body.md" attest_none "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "mismatched complete GitHub readbacks passed"
  assert_grep 'complete GitHub PR readbacks did not match' "$dir/stderr" \
    "GitHub cross-readback mismatch was not actionable"
  assert_absent "$dir/home/state/task-a.pr-publication" \
    "mismatched GitHub readbacks wrote a receipt"
  pass "publication check fails closed when complete GitHub public readbacks disagree"
}

test_github_readback_is_bound_to_task_worktree() {
  local dir rc
  dir=$(make_case github-task-worktree)
  safe_body > "$dir/body.md"
  attest_none "$dir" >/dev/null 2> "$dir/stderr" \
    || fail "task-worktree GitHub attestation failed: $(cat "$dir/stderr")"
  assert_grep 'github-task-worktree/worktree|pr view 17 --full' "$dir/gh-axi.log" \
    "complete GitHub readback did not run in the validated task worktree: $(cat "$dir/gh-axi.log")"
  printf '%s\n' other/project > "$dir/repo-path"
  printf '%s\n' true > "$dir/draft"
  set +e
  attest_none "$dir" >/dev/null 2> "$dir/wrong-repo.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "GitHub readback accepted a task worktree for another repository"
  assert_grep 'task worktree does not match the GitHub PR repository' "$dir/wrong-repo.err" \
    "wrong task repository refusal was unclear"
  pass "GitHub complete readback is bound to the validated task worktree"
}

test_studio_and_windows_privacy_hazards_refuse() {
  local prefix suffix
  prefix=$'## Intent\n\nDeliver the complete change.\n\n## What Changed\n\n'
  suffix=$'\n'
  assert_attest_rejected studio-home "$prefix- Review used /Users/synthetic-user/.no-mistakes/worktrees/run/src/app.ts.$suffix" 'absolute Unix home path'
  assert_attest_rejected linux-root-home "$prefix- Review used /root/private-worktree/src/app.ts.$suffix" 'absolute Unix home path'
  assert_attest_rejected studio-temp "$prefix- local file: /var/folders/aa/bb/T/no-mistakes-evidence/run/ui.png$suffix" 'absolute Unix temporary path'
  assert_attest_rejected windows-user "$prefix- Evidence is at C:\\Users\\SyntheticUser\\AppData\\Local\\Temp\\proof.png.$suffix" 'Windows user or temporary path'
  assert_attest_rejected windows-drive-evidence "$prefix- Evidence is at D:\\agent\\build\\result.png.$suffix" 'Windows local-drive evidence path'
  assert_attest_rejected windows-unc "$prefix- Evidence is at \\\\private-host\\share\\proof.png.$suffix" 'Windows UNC path'
  pass "publication check rejects Studio-like Unix/temp/local-file and Windows local paths"
}

test_internal_transcripts_and_secrets_refuse() {
  local prefix dir name value rc
  prefix=$'## Intent\n\nDeliver the complete change.\n\n## What Changed\n\n'
  assert_attest_rejected raw-findings "$prefix- Raw result: {\"findings\":[{\"id\":\"review-1\",\"severity\":\"high\"}]}\n" 'raw generated pipeline-agent transcript'
  assert_attest_rejected worker-narration "$prefix- Worker status: finished after supervision.\n" 'private task, run, worker, or supervision narration'
  assert_attest_rejected secret-token "$prefix- access_token=abcdefghijklmnopqrstuvwxyz123456\n" 'assigned secret value'
  assert_attest_rejected bearer-token "$prefix- Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signaturevalue1234567890\n" 'Authorization Bearer credential'
  assert_attest_rejected basic-token "$prefix- Authorization: Basic dXNlcjpwYXNzd29yZA==\n" 'Authorization Basic credential'
  assert_attest_rejected basic-unpadded-token "$prefix- Authorization: Basic dXNlcjpwYXNzd29yZA\n" 'Authorization Basic credential'
  assert_attest_rejected basic-canonical-no-colon "$prefix- Authorization: Basic c2VjcmV0\n" 'Authorization Basic credential'
  assert_attest_rejected basic-empty-user "$prefix- authorization: basic OnNlY3JldA==\n" 'Authorization Basic credential'
  assert_attest_rejected basic-invalid-remainder "$prefix- Authorization: Basic dXNlcjpwYXNzd29yZ\n" 'Authorization Basic credential'
  assert_attest_rejected basic-ambiguous-padding "$prefix- Authorization: Basic dXNlcjpwYXNzd29yZA===\n" 'Authorization Basic credential'
  assert_attest_rejected basic-noncanonical-padding "$prefix- Authorization: Basic dXNlcjpwYXNzd29yZB==\n" 'Authorization Basic credential'
  assert_attest_rejected basic-after-placeholder "$prefix- Authorization: Basic REDACTED; Authorization: Basic dXNlcjpwYXNzd29yZA==\n" 'Authorization Basic credential'
  while IFS='|' read -r name value; do
    assert_attest_rejected "basic-context-$name" "$prefix$value"$'\n' 'Authorization Basic credential'
  done <<'EOF'
raw-header|Authorization: Basic dXNlcjpwYXNzd29yZA
whitespace-header|    Authorization: Basic dXNlcjpwYXNzd29yZA
markdown-quote|> Authorization: Basic dXNlcjpwYXNzd29yZA
markdown-list|- Authorization: Basic dXNlcjpwYXNzd29yZA
markdown-code|`Authorization: Basic dXNlcjpwYXNzd29yZA`
curl-short|curl -H 'Authorization: Basic dXNlcjpwYXNzd29yZA' https://example.invalid
curl-long|curl --header="Authorization: Basic dXNlcjpwYXNzd29yZA" https://example.invalid
curl-attached-single|curl -H'Authorization: Basic dXNlcjpwYXNzd29yZA' https://example.invalid
curl-attached-double|curl -H"Authorization: Basic dXNlcjpwYXNzd29yZA" https://example.invalid
curl-attached-header-token|curl -HAuthorization:'Basic dXNlcjpwYXNzd29yZA' https://example.invalid
curl-long-separated|curl --header 'Authorization: Basic dXNlcjpwYXNzd29yZA' https://example.invalid
curl-long-spaced-equals|curl --header = 'Authorization: Basic dXNlcjpwYXNzd29yZA' https://example.invalid
structured-json|{"Authorization": "Basic dXNlcjpwYXNzd29yZA"}
structured-non-leading|{"method":"GET","Authorization":"Basic dXNlcjpwYXNzd29yZA"}
structured-nested|{"headers":{"Authorization":"Basic dXNlcjpwYXNzd29yZA"}}
structured-multiple|{"Authorization":"Basic REDACTED","authorization":"Basic dXNlcjpwYXNzd29yZA"}
structured-key|Authorization = "Basic dXNlcjpwYXNzd29yZA"
EOF
  while IFS='|' read -r name value; do
    assert_attest_rejected "basic-$name" "$prefix- Authorization: Basic $value"$'\n' 'Authorization Basic credential'
  done <<'EOF'
suffix-bypass|REDACTED-dXNlcjpwYXNzd29yZA
backtick-wrapped-populated|`dXNlcjpwYXNzd29yZA`
single-quote-wrapped-populated|'dXNlcjpwYXNzd29yZA'
double-quote-wrapped-populated|"dXNlcjpwYXNzd29yZA"
angle-wrapped-populated|<dXNlcjpwYXNzd29yZA>
square-wrapped-populated|[dXNlcjpwYXNzd29yZA]
mismatched-wrapper|<REDACTED]
unterminated-wrapper|`REDACTED
nested-wrapper|<[REDACTED]>
trailing-content|<REDACTED> trailing
empty-wrapper|<>
unapproved-placeholder|SECRET_VALUE
EOF
  assert_attest_rejected standalone-jwt "$prefix- Captured eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signaturevalue1234567890 during validation.\n" 'standalone JWT-shaped credential'

  while IFS='|' read -r name value; do
    dir=$(make_case "basic-placeholder-$name")
    write_body "$dir" "$(safe_body)

- Authorization: Basic $value
"
    attest_none "$dir" >/dev/null 2> "$dir/stderr" \
      || fail "Basic placeholder $name was rejected: $(cat "$dir/stderr")"
  done <<'EOF'
raw-redacted|REDACTED
case-variant|rEdAcTeD
raw-masked|MASKED
raw-placeholder|PLACEHOLDER
raw-token|TOKEN
raw-your-token|YOUR_TOKEN
backtick|`REDACTED`
single-quote|'PLACEHOLDER'
double-quote|"TOKEN"
angle|<YOUR_TOKEN>
square|[redacted]
shell-variable|${BASIC_CREDENTIAL}
redacted-token|REDACTED_TOKEN
basic-credential|BASIC_CREDENTIAL
basic-token-hyphen|basic-token
empty|
EOF

  while IFS='|' read -r name value; do
    dir=$(make_case "basic-placeholder-context-$name")
    write_body "$dir" "$(safe_body)

$value
"
    attest_none "$dir" >/dev/null 2> "$dir/stderr" \
      || fail "Basic placeholder context $name was rejected: $(cat "$dir/stderr")"
  done <<'EOF'
markdown-code|`Authorization: Basic REDACTED`
curl-header|curl -H 'Authorization: Basic PLACEHOLDER' https://example.invalid
curl-attached|curl -H'Authorization: Basic REDACTED' https://example.invalid
structured-key|{"Authorization": "Basic TOKEN"}
structured-non-leading|{"method":"GET","Authorization":"Basic REDACTED"}
structured-nested|{"headers":{"Authorization":"Basic PLACEHOLDER"}}
structured-multiple|{"Authorization":"Basic REDACTED","authorization":"Basic TOKEN"}
structured-leading-with-tail|{"Authorization":"Basic REDACTED","method":"GET"}
EOF

  dir=$(make_case basic-ordinary-prose)
  write_body "$dir" "$(safe_body)

- Basic authorization documentation describes the scheme without publishing a header value.
"
  attest_none "$dir" >/dev/null 2> "$dir/stderr" \
    || fail "ordinary Basic authorization prose was rejected: $(cat "$dir/stderr")"

  while IFS='|' read -r name value; do
    dir=$(make_case "basic-prose-$name")
    write_body "$dir" "$(safe_body)

$value
"
    attest_none "$dir" >/dev/null 2> "$dir/stderr" \
      || fail "Basic non-header prose $name was rejected: $(cat "$dir/stderr")"
  done <<'EOF'
scheme-name|The client calls this the Authorization: Basic scheme.
quoted-scheme-name|> The client calls this the Authorization: Basic scheme.
near-miss-key|clientAuthorization: Basic dXNlcjpwYXNzd29yZA
near-miss-curl|The curl -H 'Authorization: Basic dXNlcjpwYXNzd29yZA' example is documentation.
unrelated-short-option|curl -Help 'Authorization: Basic dXNlcjpwYXNzd29yZA' https://example.invalid
lowercase-help-option|curl -h 'Authorization: Basic dXNlcjpwYXNzd29yZA' https://example.invalid
unrelated-long-option|curl --headers='Authorization: Basic dXNlcjpwYXNzd29yZA' https://example.invalid
near-miss-structured|{"clientAuthorization":"Basic dXNlcjpwYXNzd29yZA"}
EOF

  dir=$(make_case basic-machine-verdict)
  safe_body > "$dir/body.md"
  attest_none "$dir" >/dev/null 2> "$dir/attest.err" \
    || fail "Basic machine-verdict fixture did not attest"
  write_body "$dir" "$(safe_body)

- Authorization: Basic dXNlcjpwYXNzd29yZA==
"
  set +e
  run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" verify task-a "$GITHUB_URL" --machine \
    > "$dir/verify.out" 2> "$dir/verify.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && [ "$(cat "$dir/verify.out")" = 'failure publication-invalid' ] \
    || fail "Basic credential did not preserve the machine-readable privacy verdict"
  assert_grep 'Authorization Basic credential' "$dir/verify.err" \
    "Basic machine-verdict failure lost its privacy diagnostic"
  pass "publication check rejects generated findings, private narration, and credential-shaped material"
}

test_partial_intent_framing_refuses() {
  local phrase expected
  for phrase in 'successor run' 'current task' 'latest commit' 'this round' 'recovered branch' 'Captain authorization'; do
    expected='operational rather than PR-level intent framing'
    [ "$phrase" != 'Captain authorization' ] || expected='private task, run, worker, or supervision narration'
    assert_attest_rejected "partial-$(printf '%s' "$phrase" | tr ' A-Z' '-a-z')" \
      "## Intent

Continue the $phrase and publish its result.

## What Changed

- Applied one bounded update.
" "$expected"
  done
  pass "publication check rejects known operational framing while semantic judgment remains explicit"
}

test_exact_head_evidence_accessibility_and_kind() {
  local dir exact_url mutable_url rc
  exact_url="https://github.com/example/project/blob/$GITHUB_HEAD/evidence/result.txt#L1-L3"
  mutable_url='https://github.com/example/project/blob/main/evidence/result.txt'

  dir=$(make_case mutable-evidence)
  write_body "$dir" "$(safe_body)

[Evidence]($mutable_url)
"
  set +e
  run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" attest task-a "$GITHUB_URL" \
    --intent-outcome-complete --evidence nonvisual --evidence-url "$mutable_url" \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "mutable evidence URL passed"
  assert_grep 'pinned to the exact PR head' "$dir/stderr" "mutable evidence refusal was unclear"

  dir=$(make_case inaccessible-evidence)
  write_body "$dir" "$(safe_body)

[Evidence]($exact_url)
"
  set +e
  FM_TEST_EVIDENCE_RC=1 run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" attest task-a "$GITHUB_URL" \
    --intent-outcome-complete --evidence nonvisual --evidence-url "$exact_url" \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "inaccessible evidence URL passed"
  assert_grep 'not authenticated-accessible' "$dir/stderr" "inaccessible evidence refusal was unclear"

  dir=$(make_case safe-evidence)
  write_body "$dir" "$(safe_body)

[Evidence]($exact_url)
"
  run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" attest task-a "$GITHUB_URL" \
    --intent-outcome-complete --evidence nonvisual --evidence-url "$exact_url" \
    > "$dir/stdout" 2> "$dir/stderr" || fail "safe exact-head evidence failed: $(cat "$dir/stderr")"
  assert_grep "api /repos/example/project/contents/evidence/result.txt?ref=$GITHUB_HEAD --header Accept: application/vnd.github.object+json" "$dir/gh.log" \
    "GitHub evidence did not parse the authenticated exact-head Contents response"

  dir=$(make_case directory-evidence)
  write_body "$dir" "$(safe_body)

[Evidence]($exact_url)
"
  set +e
  FM_TEST_EVIDENCE_KIND=directory run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" attest task-a "$GITHUB_URL" \
    --intent-outcome-complete --evidence nonvisual --evidence-url "$exact_url" \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "GitHub directory passed as file evidence"
  assert_grep 'does not identify a file/blob' "$dir/stderr" \
    "GitHub directory evidence refusal was unclear"

  dir=$(make_case evidence-substring)
  write_body "$dir" "$(safe_body)

[Different evidence]($exact_url.bak)
"
  set +e
  run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" attest task-a "$GITHUB_URL" \
    --intent-outcome-complete --evidence nonvisual --evidence-url "$exact_url" \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "evidence URL substring passed as an exact public link"
  assert_grep 'declared evidence URL is absent' "$dir/stderr" \
    "evidence substring refusal was unclear"

  dir=$(make_case illustration-evidence)
  exact_url="https://github.com/example/project/blob/$GITHUB_HEAD/evidence/custom-illustration.png"
  write_body "$dir" "$(safe_body)

[UI evidence]($exact_url)
"
  set +e
  run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" attest task-a "$GITHUB_URL" \
    --intent-outcome-complete --evidence real-ui --evidence-url "$exact_url" \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "custom illustration passed as real UI evidence"
  assert_grep 'cannot attest real UI behavior' "$dir/stderr" "illustration refusal was unclear"
  pass "publication check enforces accessible exact-head evidence and rejects illustrations as real UI proof"
}

test_body_head_drift_and_correction_retry() {
  local dir rc
  dir=$(make_case drift)
  safe_body > "$dir/body.md"
  attest_none "$dir" >/dev/null 2> "$dir/attest.err" || fail "drift fixture did not attest"

  write_body "$dir" "$(safe_body)

Additional public outcome.
"
  set +e
  run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" verify task-a "$GITHUB_URL" > /dev/null 2> "$dir/body-drift.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "body drift kept the old receipt valid"
  assert_grep 'does not match the fresh public body and head' "$dir/body-drift.err" "body drift refusal was unclear"

  safe_body > "$dir/body.md"
  set +e
  run_gate "$dir" "$GITHUB_URL" 3333333333333333333333333333333333333333 verify task-a "$GITHUB_URL" \
    > /dev/null 2> "$dir/head-drift.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "head drift kept the old receipt valid"

  dir=$(make_case correction-retry)
  write_body "$dir" $'## Intent\n\nThis round only.\n\n## What Changed\n\n- Partial.\n'
  set +e
  attest_none "$dir" >/dev/null 2> "$dir/first.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "bad first publication unexpectedly passed"
  safe_body > "$dir/body.md"
  attest_none "$dir" >/dev/null 2> "$dir/retry.err" || fail "corrected public readback retry failed"
  run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" verify task-a "$GITHUB_URL" >/dev/null 2> "$dir/verify.err" \
    || fail "corrected receipt did not verify"
  pass "publication receipt rejects body/head drift and accepts a correction-readback retry"
}

test_ready_readback_surfaces_failed_rollback() {
  local dir rc
  dir=$(make_case ready-readback-rollback-failure)
  safe_body > "$dir/body.md"
  set +e
  FM_TEST_READY_READBACK_FAIL=1 FM_TEST_ROLLBACK_RC=9 attest_none "$dir" \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "failed ready-state readback and rollback passed"
  assert_grep 'ready-state readback did not preserve the attested PR identity and head' "$dir/stderr" \
    "ready-state readback failure was lost"
  assert_grep 'draft rollback also failed with exit 9' "$dir/stderr" \
    "draft rollback failure was lost"
  assert_grep 'may remain reviewable without a valid publication receipt' "$dir/stderr" \
    "failed rollback did not report the unsafe reviewable state"
  assert_absent "$dir/home/state/task-a.pr-publication" \
    "failed ready-state readback retained an invalid receipt"
  [ "$(cat "$dir/draft")" = false ] || fail "rollback-failure fixture did not remain reviewable"
  pass "ready-state failure retains both the readback and rollback diagnostics"
}

test_machine_failure_classes_are_bounded() {
  local dir rc
  dir=$(make_case machine-failure-classes)
  safe_body > "$dir/body.md"
  attest_none "$dir" >/dev/null 2> "$dir/attest.err" \
    || fail "machine classification fixture did not attest"

  printf '\nPublic body drift.\n' >> "$dir/body.md"
  set +e
  run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" verify task-a "$GITHUB_URL" --machine \
    > "$dir/drift.out" 2> "$dir/drift.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && [ "$(cat "$dir/drift.out")" = 'failure publication-invalid' ] \
    || fail "body drift did not emit the bounded publication failure class"

  safe_body > "$dir/body.md"
  set +e
  FM_TEST_GH_READ_RC=7 run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" verify task-a "$GITHUB_URL" --machine \
    > "$dir/read.out" 2> "$dir/read.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && [ "$(cat "$dir/read.out")" = 'failure forge-read-failed' ] \
    || fail "forge authentication or transport failure did not emit its bounded class"

  set +e
  run_gate "$dir" "$GITHUB_URL" invalid-head verify task-a "$GITHUB_URL" --machine \
    > "$dir/malformed.out" 2> "$dir/malformed.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && [ "$(cat "$dir/malformed.out")" = 'failure forge-response-invalid' ] \
    || fail "malformed forge response did not emit its bounded class"

  mv "$dir/fakebin/gh-axi" "$dir/gh-axi.disabled"
  set +e
  run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" verify task-a "$GITHUB_URL" --machine \
    > "$dir/tool.out" 2> "$dir/tool.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && [ "$(cat "$dir/tool.out")" = 'failure tool-unavailable' ] \
    || fail "missing verifier tool did not emit its bounded class"
  pass "machine verification distinguishes publication, forge, response, and tool failures"
}

test_scratch_failures_are_state_invalid_and_preserve_primary_failure() {
  local dir rc stage

  for stage in initial-create scan-write intent-create outcome-create intent-write outcome-write url-list-write; do
    dir=$(make_case "scratch-$stage")
    safe_body > "$dir/body.md"
    attest_none "$dir" >/dev/null 2> "$dir/attest.err" \
      || fail "$stage scratch fixture did not attest"
    install_scratch_fault_tools "$dir"
    set +e
    FM_TEST_SCRATCH_FAIL_STAGE="$stage" run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" \
      verify task-a "$GITHUB_URL" --machine > "$dir/verify.out" 2> "$dir/verify.err"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] && [ "$(cat "$dir/verify.out")" = 'failure state-invalid' ] \
      || fail "$stage scratch failure was not routed as state-invalid"
  done

  dir=$(make_case scratch-cleanup-only)
  safe_body > "$dir/body.md"
  attest_none "$dir" >/dev/null 2> "$dir/attest.err" \
    || fail "cleanup-only scratch fixture did not attest"
  install_scratch_fault_tools "$dir"
  set +e
  FM_TEST_SCRATCH_FAIL_STAGE=cleanup run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" \
    verify task-a "$GITHUB_URL" --machine > "$dir/verify.out" 2> "$dir/verify.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && [ "$(cat "$dir/verify.out")" = 'failure state-invalid' ] \
    || fail "cleanup-only failure did not emit one bounded state-invalid result"
  assert_grep 'private PR publication scratch cleanup failed' "$dir/verify.err" \
    "cleanup-only failure lacked an operational diagnostic"

  dir=$(make_case scratch-cleanup-precedence)
  safe_body > "$dir/body.md"
  attest_none "$dir" >/dev/null 2> "$dir/attest.err" \
    || fail "cleanup precedence scratch fixture did not attest"
  printf '\nPublic body drift.\n' >> "$dir/body.md"
  install_scratch_fault_tools "$dir"
  set +e
  FM_TEST_SCRATCH_FAIL_STAGE=cleanup run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" \
    verify task-a "$GITHUB_URL" --machine > "$dir/verify.out" 2> "$dir/verify.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && [ "$(cat "$dir/verify.out")" = 'failure publication-invalid' ] \
    || fail "cleanup failure suppressed the earlier publication-invalid result"
  assert_grep 'private PR publication scratch cleanup failed' "$dir/verify.err" \
    "cleanup failure after a primary failure was not reported"
  pass "scratch I/O failures are state errors and cleanup preserves primary failures"
}

test_gitlab_evidence_paths_decode_and_encode_once() {
  local dir actual_path web_path exact_url api_path rc name rejected_path
  actual_path='evidence/result log#review?+proof.txt'
  web_path='evidence/result%20log%23review%3F%2Bproof.txt'
  api_path='evidence%2Fresult%20log%23review%3F%2Bproof.txt'
  exact_url="https://gitlab.example/group/project/-/blob/$GITLAB_HEAD/$web_path"
  dir=$(make_case gitlab-encoded-evidence)
  write_body "$dir" "$(safe_body)

[Evidence]($exact_url)
"
  FM_TEST_EVIDENCE_PATH="$actual_path" run_gate "$dir" "$GITLAB_URL" "$GITLAB_HEAD" \
    attest task-a "$GITLAB_URL" --intent-outcome-complete --evidence nonvisual \
    --evidence-url "$exact_url" > "$dir/attest.out" 2> "$dir/attest.err" \
    || fail "percent-encoded GitLab evidence failed: $(cat "$dir/attest.err")"
  assert_grep "repository/files/$api_path?ref=$GITLAB_HEAD" "$dir/glab.log" \
    "GitLab evidence path was not decoded and API-encoded exactly once"
  FM_TEST_EVIDENCE_PATH="$actual_path" run_gate "$dir" "$GITLAB_URL" "$GITLAB_HEAD" \
    verify task-a "$GITLAB_URL" > "$dir/verify.out" 2> "$dir/verify.err" \
    || fail "encoded GitLab evidence receipt did not reverify: $(cat "$dir/verify.err")"

  while IFS='|' read -r name rejected_path; do
    dir=$(make_case "gitlab-evidence-$name")
    exact_url="https://gitlab.example/group/project/-/blob/$GITLAB_HEAD/$rejected_path"
    write_body "$dir" "$(safe_body)

[Evidence]($exact_url)
"
    set +e
    run_gate "$dir" "$GITLAB_URL" "$GITLAB_HEAD" attest task-a "$GITLAB_URL" \
      --intent-outcome-complete --evidence nonvisual --evidence-url "$exact_url" \
      > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$name GitLab evidence path unexpectedly passed"
    assert_grep 'malformed or ambiguously encoded repository path' "$dir/stderr" \
      "$name GitLab evidence refusal was unclear"
  done <<'EOF'
malformed-percent|evidence/result%2Glog.txt
double-encoded|evidence/result%2520log.txt
encoded-control|evidence/result%00log.txt
EOF
  pass "GitLab evidence paths decode once and reject malformed or ambiguous escapes"
}

test_local_receipt_and_evidence_io_failures_are_state_invalid() {
  local dir exact_url receipt rc

  dir=$(make_case unsafe-receipt-state)
  safe_body > "$dir/body.md"
  attest_none "$dir" >/dev/null 2> "$dir/attest.err" \
    || fail "unsafe receipt state fixture did not attest"
  receipt="$dir/home/state/task-a.pr-publication"
  chmod 0644 "$receipt"
  set +e
  run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" verify task-a "$GITHUB_URL" --machine \
    > "$dir/verify.out" 2> "$dir/verify.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && [ "$(cat "$dir/verify.out")" = 'failure state-invalid' ] \
    || fail "unsafe receipt state was not routed as state-invalid"

  dir=$(make_case missing-receipt-content)
  safe_body > "$dir/body.md"
  attest_none "$dir" >/dev/null 2> "$dir/attest.err" \
    || fail "missing receipt fixture did not attest"
  rm -f "$dir/home/state/task-a.pr-publication"
  set +e
  run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" verify task-a "$GITHUB_URL" --machine \
    > "$dir/verify.out" 2> "$dir/verify.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && [ "$(cat "$dir/verify.out")" = 'failure publication-invalid' ] \
    || fail "missing receipt content was not routed as publication-invalid"

  dir=$(make_case malformed-evidence-receipt)
  exact_url="https://github.com/example/project/blob/$GITHUB_HEAD/evidence/result.txt"
  write_body "$dir" "$(safe_body)

[Evidence]($exact_url)
"
  run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" attest task-a "$GITHUB_URL" \
    --intent-outcome-complete --evidence nonvisual --evidence-url "$exact_url" \
    > "$dir/attest.out" 2> "$dir/attest.err" \
    || fail "malformed receipt fixture did not attest: $(cat "$dir/attest.err")"
  receipt="$dir/home/state/task-a.pr-publication"
  sed 's/^evidence_url_base64=.*/evidence_url_base64=%%%/' "$receipt" > "$receipt.tmp"
  mv "$receipt.tmp" "$receipt"
  chmod 0600 "$receipt"
  set +e
  run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" verify task-a "$GITHUB_URL" --machine \
    > "$dir/verify.out" 2> "$dir/verify.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && [ "$(cat "$dir/verify.out")" = 'failure publication-invalid' ] \
    || fail "malformed receipt content was not routed as publication-invalid"

  dir=$(make_case evidence-url-mktemp-failure)
  exact_url="https://github.com/example/project/blob/$GITHUB_HEAD/evidence/result.txt"
  write_body "$dir" "$(safe_body)

[Evidence]($exact_url)
"
  run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" attest task-a "$GITHUB_URL" \
    --intent-outcome-complete --evidence nonvisual --evidence-url "$exact_url" \
    > "$dir/attest.out" 2> "$dir/attest.err" \
    || fail "evidence mktemp fixture did not attest: $(cat "$dir/attest.err")"
  cat > "$dir/fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  *.fm-pr-publication-url.*) exit 1 ;;
esac
exec "$FM_TEST_REAL_MKTEMP" "$@"
SH
  chmod +x "$dir/fakebin/mktemp"
  set +e
  run_gate "$dir" "$GITHUB_URL" "$GITHUB_HEAD" verify task-a "$GITHUB_URL" --machine \
    > "$dir/verify.out" 2> "$dir/verify.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && [ "$(cat "$dir/verify.out")" = 'failure state-invalid' ] \
    || fail "evidence URL temporary-file failure was not routed as state-invalid"
  pass "local receipt and evidence I/O failures remain operational state errors"
}

test_github_and_gitlab_routes_and_monitoring_boundary() {
  local dir exact_url rc
  dir=$(make_case no-receipt-monitor)
  safe_body > "$dir/body.md"
  set +e
  FM_ROOT_OVERRIDE="$dir/fake-root" FM_HOME="$dir/home" \
    FM_TEST_PR_URL="$GITHUB_URL" FM_TEST_PR_HEAD="$GITHUB_HEAD" FM_TEST_BODY_FILE="$dir/body.md" \
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" FM_TEST_GLAB_LOG="$dir/glab.log" \
    FM_TEST_DRAFT_FILE="$dir/draft" FM_TEST_REPO_FILE="$dir/repo-path" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" task-a "$GITHUB_URL" > "$dir/check.out" 2> "$dir/check.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fm-pr-check armed monitoring without publication attestation"
  assert_absent "$dir/home/state/task-a.check.sh" "monitoring artifact appeared without publication receipt"

  dir=$(make_case github-monitor)
  safe_body > "$dir/body.md"
  attest_none "$dir" >/dev/null 2> "$dir/attest.err" || fail "GitHub route did not attest"
  assert_grep 'pr view 17 --full' "$dir/gh-axi.log" \
    "GitHub readback did not use the complete gh-axi PR view"
  assert_grep "pr view $GITHUB_URL --json url,headRefOid,body,isDraft" "$dir/gh.log" \
    "GitHub head binding did not use one exact body/head JSON snapshot"
  FM_ROOT_OVERRIDE="$dir/fake-root" FM_HOME="$dir/home" \
    FM_TEST_PR_URL="$GITHUB_URL" FM_TEST_PR_HEAD="$GITHUB_HEAD" FM_TEST_BODY_FILE="$dir/body.md" \
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" FM_TEST_GLAB_LOG="$dir/glab.log" \
    FM_TEST_DRAFT_FILE="$dir/draft" FM_TEST_REPO_FILE="$dir/repo-path" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" task-a "$GITHUB_URL" > "$dir/check.out" 2> "$dir/check.err" \
    || fail "fm-pr-check refused a valid GitHub publication: $(cat "$dir/check.err")"
  assert_present "$dir/home/state/task-a.check.sh" "valid publication did not arm monitoring"
  grep -qxF "pr_head=$GITHUB_HEAD" "$dir/home/state/task-a.meta" || fail "GitHub exact head was not recorded"

  dir=$(make_case gitlab-route)
  exact_url="https://gitlab.example/group/project/-/blob/$GITLAB_HEAD/evidence/result.txt"
  write_body "$dir" "$(safe_body)

[Evidence]($exact_url)
"
  run_gate "$dir" "$GITLAB_URL" "$GITLAB_HEAD" attest task-a "$GITLAB_URL" \
    --intent-outcome-complete --evidence nonvisual --evidence-url "$exact_url" \
    > "$dir/attest.out" 2> "$dir/attest.err" || fail "GitLab route did not attest: $(cat "$dir/attest.err")"
  assert_grep 'mr view 23 -R https://gitlab.example/group/project -F json' "$dir/glab.log" \
    "GitLab readback did not use the canonical project route and JSON fields"
  assert_grep 'api --hostname gitlab.example projects/group%2Fproject/repository/files/evidence%2Fresult.txt' "$dir/glab.log" \
    "GitLab evidence did not use the authenticated host-bound route"
  assert_grep 'mr update 23 -R https://gitlab.example/group/project --ready --yes' "$dir/glab.log" \
    "GitLab attestation did not mark the unchanged draft ready"
  run_gate "$dir" "$GITLAB_URL" "$GITLAB_HEAD" verify task-a "$GITLAB_URL" >/dev/null 2> "$dir/verify.err" \
    || fail "GitLab receipt did not verify"

  dir=$(make_case gitlab-directory-evidence)
  write_body "$dir" "$(safe_body)

[Evidence]($exact_url)
"
  set +e
  FM_TEST_EVIDENCE_KIND=directory run_gate "$dir" "$GITLAB_URL" "$GITLAB_HEAD" attest task-a "$GITLAB_URL" \
    --intent-outcome-complete --evidence nonvisual --evidence-url "$exact_url" \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "GitLab non-file response passed as file evidence"
  assert_grep 'does not identify a file/blob' "$dir/stderr" \
    "GitLab non-file evidence refusal was unclear"
  pass "publication check routes GitHub and GitLab explicitly and blocks monitoring before fresh verification"
}

test_help_documents_publication_mechanics
test_safe_nonvisual_body_and_legitimate_paths_pass
test_complete_github_readbacks_must_match
test_github_readback_is_bound_to_task_worktree
test_studio_and_windows_privacy_hazards_refuse
test_internal_transcripts_and_secrets_refuse
test_partial_intent_framing_refuses
test_exact_head_evidence_accessibility_and_kind
test_body_head_drift_and_correction_retry
test_ready_readback_surfaces_failed_rollback
test_machine_failure_classes_are_bounded
test_scratch_failures_are_state_invalid_and_preserve_primary_failure
test_gitlab_evidence_paths_decode_and_encode_once
test_local_receipt_and_evidence_io_failures_are_state_invalid
test_github_and_gitlab_routes_and_monitoring_boundary
