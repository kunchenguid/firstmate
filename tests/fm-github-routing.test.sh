#!/usr/bin/env bash
# Deterministic security and concurrency tests for generic per-project GitHub
# account routing. Fake exact git/gh/gh-axi executables model two profiles and
# two repositories without reading or writing real credentials or remotes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-github-routing)
EXEC="$ROOT/bin/fm-github-exec.sh"
REAL_GIT=$(command -v git)
SENTINEL='credential-sentinel-ghp_test_only'

make_fixture() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/home/config" "$d/home/data" "$d/home/projects" "$d/home/state" "$d/profiles/profile-a" "$d/profiles/profile-b" "$d/exact" "$d/hostile"
  printf '%s\n' '- repo-a no-mistakes +yolo - A (added 2026-07-21)' '- repo-b direct-PR +yolo - B (added 2026-07-21)' > "$d/home/data/projects.md"
  for repo in repo-a repo-b; do
    fm_git_init_commit "$d/home/projects/$repo"
  done
  git -C "$d/home/projects/repo-a" remote add origin https://github.com/Owner-A/repo-a.git
  git -C "$d/home/projects/repo-b" remote add origin https://github.com/Owner-B/repo-b.git
  cat > "$d/exact/git" <<SH
#!/usr/bin/env bash
set -eu
if [ -n "\${GH_TOKEN+x}" ] || [ -n "\${GITHUB_TOKEN+x}" ] || [ -n "\${GIT_ASKPASS+x}" ] || [ -n "\${GIT_SSH_COMMAND+x}" ] || [ -n "\${GIT_SSL_NO_VERIFY+x}" ] || [ -n "\${HTTPS_PROXY+x}" ]; then
  printf '%s\n' '$SENTINEL' >&2
  exit 90
fi
printf 'git\t%s\t%s\n' "\${FM_GITHUB_PROFILE_ID:-unselected}" "\$*" >> "\${FM_TEST_ROUTE_LOG:-/dev/null}"
if [ "\${FM_TEST_FAKE_NETWORK:-}" = 1 ]; then
  case " \$* " in *' fetch '*|*' push '*|*' ls-remote '*) exit 0 ;; esac
fi
exec '$REAL_GIT' "\$@"
SH
  cat > "$d/exact/gh" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -n "${GH_TOKEN+x}" ] || [ -n "${GITHUB_TOKEN+x}" ] || [ -n "${GIT_ASKPASS+x}" ] || [ -n "${GIT_SSH_COMMAND+x}" ] || [ -n "${GIT_SSL_NO_VERIFY+x}" ] || [ -n "${HTTPS_PROXY+x}" ]; then
  printf '%s\n' "$FM_TEST_SENTINEL" >&2
  exit 90
fi
profile=${FM_GITHUB_PROFILE_ID:-unselected}
printf 'gh\t%s\t%s\n' "$profile" "$*" >> "${FM_TEST_ROUTE_LOG:-/dev/null}"
case "${1:-} ${2:-}" in
  "auth status")
    printf '%s\n' 'Token: keyring'
    exit 0
    ;;
  "api --hostname")
    case "$profile" in profile-a) printf '%s\n' account-a ;; profile-b) printf '%s\n' account-b ;; *) exit 91 ;; esac
    exit 0
    ;;
  "repo view")
    case "${FM_TEST_ACCESS_FAILURE:-}" in
      401) printf '%s\n' 'HTTP 401 bad credentials' >&2; exit 1 ;;
      403) printf '%s\n' 'HTTP 403 forbidden' >&2; exit 1 ;;
      sso) printf '%s\n' 'HTTP 403 SAML SSO authorization required' >&2; exit 1 ;;
      404) printf '%s\n' 'HTTP 404 not found' >&2; exit 1 ;;
    esac
    printf '%s\n' WRITE
    exit 0
    ;;
  "pr view")
    printf '%s\n' "${FM_TEST_PR_STATE:-ok}"
    exit 0
    ;;
esac
printf '%s\n' ok
SH
  cat > "$d/exact/gh-axi" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'gh-axi\t%s\t%s\n' "${FM_GITHUB_PROFILE_ID:-unselected}" "$*" >> "${FM_TEST_ROUTE_LOG:-/dev/null}"
exec gh "$@"
SH
  cat > "$d/hostile/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' '$SENTINEL' >&2
exit 98
SH
  cat > "$d/hostile/git" <<SH
#!/usr/bin/env bash
printf '%s\n' '$SENTINEL' >&2
exit 98
SH
  chmod +x "$d/exact/git" "$d/exact/gh" "$d/exact/gh-axi" "$d/hostile/gh" "$d/hostile/git"
  write_config "$d"
  printf '%s\n' "$d"
}

write_config() {
  local d=$1
  cat > "$d/home/config/github-accounts.json" <<JSON
{
  "version": 1,
  "gh_binary": "$d/exact/gh",
  "git_binary": "$d/exact/git",
  "gh_axi_binary": "$d/exact/gh-axi",
  "require_secure_storage": true,
  "profiles": {
    "profile-a": {
      "host": "github.com",
      "expected_login": "account-a",
      "gh_config_dir": "$d/profiles/profile-a",
      "git_protocol": "https",
      "fork_owner": "account-a",
      "commit_identity": {"name": "Account A", "email": "account-a@example.test"}
    },
    "profile-b": {
      "host": "github.com",
      "expected_login": "account-b",
      "gh_config_dir": "$d/profiles/profile-b",
      "git_protocol": "https",
      "fork_owner": "account-b",
      "commit_identity": {"name": "Account B", "email": "account-b@example.test"}
    }
  },
  "bindings": {
    "projects": {"repo-a": "profile-a", "repo-b": "profile-b"},
    "repositories": {
      "github.com/Owner-A/repo-a": "profile-a",
      "github.com/Owner-B/repo-b": "profile-b"
    },
    "owners": {"github.com/Owner-A": "profile-a", "github.com/Owner-B": "profile-b"}
  }
}
JSON
  chmod 0600 "$d/home/config/github-accounts.json"
}

run_exec() {
  local d=$1
  shift
  FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" \
    GH_TOKEN="$SENTINEL" GITHUB_TOKEN="$SENTINEL" GIT_ASKPASS="$d/$SENTINEL-askpass" \
    GIT_SSL_NO_VERIFY=1 HTTPS_PROXY="https://$SENTINEL@proxy.invalid" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="Authorization: $SENTINEL" \
    PATH="$d/hostile:$PATH" "$EXEC" "$@"
}

test_legacy_absence_is_byte_compatible() {
  local d="$TMP_ROOT/legacy" out
  mkdir -p "$d/home/config" "$d/fake"
  cat > "$d/fake/gh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${GH_TOKEN:-}" "$*"
SH
  chmod +x "$d/fake/gh"
  out=$(FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" GH_TOKEN=legacy-token PATH="$d/fake:$PATH" \
    "$EXEC" exec --repository github.com/owner/repo -- gh pr view 7)
  [ "$out" = 'legacy-token|pr view 7' ] || fail "legacy absence changed ambient command bytes: $out"
  pass "github routing absence preserves legacy ambient command behavior"
}

test_schema_and_resolution_strictness() {
  local d id rc err local_sync
  d=$(make_fixture schema)
  id=$(run_exec "$d" profile-id --project repo-a --repository "$d/home/projects/repo-a") || fail "valid route did not resolve"
  [ "$id" = profile-a ] || fail "project route resolved $id"
  fm_git_init_commit "$d/home/projects/local-project"
  printf '%s\n' '- local-project [local-only] - local project (added 2026-07-21)' >> "$d/home/data/projects.md"
  run_exec "$d" validate-all >/dev/null || fail "strict validation incorrectly required an account for a local-only project"
  local_sync=$(FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-fleet-sync.sh" "$d/home/projects/local-project" 2>/dev/null)
  assert_contains "$local_sync" 'skipped: local-only project' "strict fleet sync did not preserve local-only behavior"

  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.bindings.repositories["github.com/Owner-A/repo-a"]="profile-b"; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$d/home/config/github-accounts.json"
  set +e
  err=$(run_exec "$d" profile-id --project repo-a --repository "$d/home/projects/repo-a" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "conflicting bindings"
  assert_contains "$err" 'bindings conflict' "conflict diagnostic missing"
  write_config "$d"

  node -e 'const fs=require("fs"); const p=process.argv[1]; const s=fs.readFileSync(p,"utf8").replace(/"version": 1,/,"\"version\": 1, \"Version\": 1,"); fs.writeFileSync(p,s)' "$d/home/config/github-accounts.json"
  set +e
  err=$(run_exec "$d" validate 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "case-normalized duplicate"
  assert_not_contains "$err" "$SENTINEL" "schema error leaked sentinel"
  write_config "$d"

  chmod 0644 "$d/home/config/github-accounts.json"
  set +e
  run_exec "$d" validate >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "config mode"
  chmod 0600 "$d/home/config/github-accounts.json"

  write_config "$d"
  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.version=2; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$d/home/config/github-accounts.json"
  set +e; run_exec "$d" validate >/dev/null 2>&1; rc=$?; set -e
  expect_code 1 "$rc" "unknown schema version"

  write_config "$d"
  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.profiles["profile-a"].environment={GH_TOKEN:"credential-sentinel"}; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$d/home/config/github-accounts.json"
  set +e; err=$(run_exec "$d" validate 2>&1); rc=$?; set -e
  expect_code 1 "$rc" "arbitrary environment field"
  assert_not_contains "$err" 'credential-sentinel' "unknown field error leaked attacker-controlled text"

  write_config "$d"
  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.git_binary="relative/git"; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$d/home/config/github-accounts.json"
  set +e; run_exec "$d" validate >/dev/null 2>&1; rc=$?; set -e
  expect_code 1 "$rc" "relative executable"

  write_config "$d"
  mkdir -p "$d/home/state/unsafe-profile"
  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.profiles["profile-a"].gh_config_dir=process.argv[2]; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$d/home/config/github-accounts.json" "$d/home/state/unsafe-profile"
  set +e; run_exec "$d" validate >/dev/null 2>&1; rc=$?; set -e
  expect_code 1 "$rc" "unsafe profile location"

  write_config "$d"
  mkdir -p "$d/.treehouse/task-profile"
  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.profiles["profile-a"].gh_config_dir=process.argv[2]; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$d/home/config/github-accounts.json" "$d/.treehouse/task-profile"
  set +e; run_exec "$d" validate >/dev/null 2>&1; rc=$?; set -e
  expect_code 1 "$rc" "task-copy profile location"

  write_config "$d"
  set +e; err=$(run_exec "$d" profile-id --repository github.com/Unknown/repo 2>&1); rc=$?; set -e
  expect_code 1 "$rc" "unknown owner"
  assert_contains "$err" 'no GitHub account route' "unknown owner did not fail closed"
  set +e; run_exec "$d" profile-id --repository git@github.com:Owner-A/repo-a.git >/dev/null 2>&1; rc=$?; set -e
  expect_code 1 "$rc" "SSH route"
  set +e; err=$(run_exec "$d" profile-id --repository "https://$SENTINEL@github.com/Owner-A/repo-a" 2>&1); rc=$?; set -e
  expect_code 1 "$rc" "URL userinfo"
  assert_not_contains "$err" "$SENTINEL" "userinfo error leaked attacker-controlled bytes"
  pass "strict schema rejects conflicts, unknown fields and versions, unsafe paths, unknown owners, SSH, and userinfo"
}

test_concurrent_profiles_and_exact_children() {
  local d p1 p2
  d=$(make_fixture concurrent)
  : > "$d/routes.log"
  (run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- gh pr view 11 >/dev/null) & p1=$!
  (run_exec "$d" exec --project repo-b --repository "$d/home/projects/repo-b" -- gh-axi pr list --repo Owner-B/repo-b >/dev/null) & p2=$!
  wait "$p1" || fail "profile-a concurrent operation failed"
  wait "$p2" || fail "profile-b concurrent operation failed"
  assert_grep $'gh\tprofile-a\tpr view 11' "$d/routes.log" "profile-a exact gh route missing"
  assert_grep $'gh-axi\tprofile-b\tpr list --repo Owner-B/repo-b' "$d/routes.log" "profile-b exact gh-axi route missing"
  assert_grep $'gh\tprofile-b\tpr list --repo Owner-B/repo-b' "$d/routes.log" "gh-axi did not resolve guarded exact gh"
  assert_no_grep "$SENTINEL" "$d/routes.log" "credential sentinel reached route log"
  pass "two repositories route concurrently through distinct exact profiles"
}

test_forbidden_commands_and_access_diagnostics() {
  local d rc err kind expected
  d=$(make_fixture forbidden)
  set +e
  err=$(run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- gh auth token 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "gh auth token"
  assert_contains "$err" 'token display is forbidden' "token command refusal missing"
  set +e
  run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- gh auth git-credential >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "direct credential-helper response"
  set +e
  err=$(run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- git config --global credential.helper hostile 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "global credential config"
  assert_contains "$err" 'forbidden credential' "git config refusal missing"

  set +e
  err=$(FM_TEST_FAKE_NETWORK=1 run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    git -C "$d/home/projects/repo-a" fetch https://github.com/Other/repo-a.git 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "foreign fetch route"
  assert_contains "$err" 'not the configured HTTPS parent' "foreign fetch target was not rejected"
  set +e
  run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    git -C "$d/home/projects/repo-a" remote set-url origin git@github.com:Owner-A/repo-a.git >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "remote URL mutation"
  [ "$(git -C "$d/home/projects/repo-a" remote get-url origin)" = https://github.com/Owner-A/repo-a.git ] || fail "forbidden remote mutation changed origin"
  set +e
  err=$(run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh pr view https://github.com/Other/repo-a/pull/1 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "foreign GitHub resource"
  assert_contains "$err" 'outside the configured parent' "foreign GitHub resource was not rejected"
  set +e
  run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- gh-axi api repos/Other/repo-a >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "raw API escape"
  run_exec "$d" exec --repository github.com/Owner-A/new-repository -- gh-axi repo create Owner-A/new-repository --private >/dev/null \
    || fail "known-owner repository creation did not route through selected login"
  assert_grep $'gh-axi\tprofile-a\trepo create Owner-A/new-repository --private' "$d/routes.log" \
    "repository creation did not use the exact selected gh-axi"

  git -C "$d/home/projects/repo-a" config --local http.extraHeader "Authorization: $SENTINEL"
  set +e
  err=$(run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- gh pr view 1 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "repository-controlled authorization header"
  assert_not_contains "$err" "$SENTINEL" "repository-controlled header value leaked"
  git -C "$d/home/projects/repo-a" config --local --unset-all http.extraHeader

  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.profiles["profile-a"].expected_login="wrong-login"; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$d/home/config/github-accounts.json"
  set +e
  err=$(run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- gh pr view 1 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "login mismatch"
  assert_contains "$err" 'authenticated as a different login' "login mismatch was not actionable"
  write_config "$d"

  for row in '401|expired or unauthenticated' '403|lacks repository permission' 'sso|requires organization SSO authorization' '404|repository is inaccessible'; do
    kind=${row%%|*}; expected=${row#*|}
    set +e
    err=$(FM_TEST_ACCESS_FAILURE="$kind" run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- gh pr view 1 2>&1); rc=$?
    set -e
    expect_code 1 "$rc" "$kind diagnostic"
    assert_contains "$err" "$expected" "$kind diagnostic was not actionable"
    assert_not_contains "$err" "$SENTINEL" "$kind diagnostic leaked sentinel"
  done
  pass "routed auth mutation, Git injection, and access failures stop with sanitized diagnostics"
}

test_commit_identity_and_removed_profile() {
  local d author rc err
  d=$(make_fixture identity)
  printf '%s\n' routed > "$d/home/projects/repo-a/routed.txt"
  run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- git -C "$d/home/projects/repo-a" add routed.txt >/dev/null
  run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- git -C "$d/home/projects/repo-a" commit -m routed >/dev/null
  author=$(git -C "$d/home/projects/repo-a" show -s --format='%an <%ae>' HEAD)
  [ "$author" = 'Account A <account-a@example.test>' ] || fail "selected commit identity was not applied: $author"

  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); delete v.profiles["profile-a"]; delete v.bindings.projects["repo-a"]; delete v.bindings.repositories["github.com/Owner-A/repo-a"]; delete v.bindings.owners["github.com/Owner-A"]; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$d/home/config/github-accounts.json"
  set +e
  err=$(FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_GITHUB_ACTIVE=1 FM_GITHUB_PROFILE_ID=profile-a \
    FM_GITHUB_REPOSITORY=github.com/Owner-A/repo-a FM_GITHUB_PROJECT=repo-a "$EXEC" child-gh -- pr view 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "removed profile fell back"
  assert_not_contains "$err" "$SENTINEL" "removed profile error leaked sentinel"
  pass "commit identity is selected and removed profiles cannot fall back"
}

test_direct_pr_fork_fleet_sync_and_secondmate_child() {
  local d child p1 p2
  d=$(make_fixture integration)
  git -C "$d/home/projects/repo-a" remote add fork https://github.com/account-a/repo-a.git
  FM_TEST_FAKE_NETWORK=1 run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    git -C "$d/home/projects/repo-a" push fork feature/account-route >/dev/null \
    || fail "selected-profile fork push path failed"
  run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi pr create --repo Owner-A/repo-a --head account-a:feature/account-route --base main --title routed --body safe >/dev/null \
    || fail "direct PR path failed"
  assert_grep $'git\tprofile-a\t-C ' "$d/routes.log" "direct push did not use profile-a exact Git"
  assert_grep $'gh-axi\tprofile-a\tpr create' "$d/routes.log" "direct PR did not use profile-a exact gh-axi"

  (FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" FM_TEST_FAKE_NETWORK=1 \
    PATH="$d/hostile:$PATH" "$ROOT/bin/fm-fleet-sync.sh" "$d/home/projects/repo-a" >/dev/null 2>&1) & p1=$!
  (FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" FM_TEST_FAKE_NETWORK=1 \
    PATH="$d/hostile:$PATH" "$ROOT/bin/fm-fleet-sync.sh" "$d/home/projects/repo-b" >/dev/null 2>&1) & p2=$!
  wait "$p1" || fail "profile-a fleet sync failed"
  wait "$p2" || fail "profile-b fleet sync failed"
  grep -F $'git\tprofile-a\t' "$d/routes.log" | grep -F ' fetch origin --prune --quiet' >/dev/null || fail "fleet sync missed profile-a"
  grep -F $'git\tprofile-b\t' "$d/routes.log" | grep -F ' fetch origin --prune --quiet' >/dev/null || fail "fleet sync missed profile-b"

  child="$d/secondmate"
  mkdir -p "$child/config" "$child/data"
  printf '%s\n' '- repo-b direct-PR +yolo - B (added 2026-07-21)' > "$child/data/projects.md"
  FM_INHERITABLE_CONFIG=github-accounts.json bash -c '. "$1/bin/fm-config-inherit-lib.sh"; propagate_inheritable_config "$2" "$3"' \
    _ "$ROOT" "$d/home/config" "$child/config" || fail "secondmate routing inheritance failed"
  FM_HOME="$child" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" \
    PATH="$d/hostile:$PATH" "$EXEC" exec --project repo-b --repository github.com/Owner-B/repo-b -- gh pr view 3 >/dev/null \
    || fail "secondmate child did not resolve inherited routing"
  assert_grep $'gh\tprofile-b\tpr view 3' "$d/routes.log" "secondmate child did not use profile-b"
  assert_no_grep "$SENTINEL" "$d/routes.log" "integration routes persisted a credential sentinel"
  pass "direct PR, fork push, concurrent fleet sync, and secondmate child paths stay project-scoped"
}

test_delayed_poll_profile_binding_and_nonexecuting_migration() {
  local d state meta out marker malicious
  d=$(make_fixture delayed)
  state="$d/home/state"
  touch "$state/.last-watcher-beat"
  meta="$state/task-poll.meta"
  fm_write_meta "$meta" \
    "window=fm-task-poll" \
    "worktree=$d/home/projects/repo-a" \
    "project=$d/home/projects/repo-a" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  chmod 0600 "$meta"
  FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" PATH="$d/hostile:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-poll https://github.com/Owner-A/repo-a/pull/17 >/dev/null \
    || fail "strict delayed poll registration failed"
  [ "$(sed -n '5p' "$state/task-poll.pr-poll")" = profile-a ] || fail "delayed sidecar did not bind the stable profile id"
  [ "$(sed -n '1p' "$state/task-poll.pr-poll-registration")" = fm-pr-poll-registration-v2 ] || fail "delayed registration was not upgraded to v2"
  assert_no_grep "$SENTINEL" "$state/task-poll.pr-poll" "delayed sidecar persisted a credential sentinel"
  out=$(FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" FM_TEST_PR_STATE=MERGED PATH="$d/hostile:$PATH" \
    bash "$state/task-poll.check.sh")
  [ "$out" = merged ] || fail "delayed poll did not re-resolve the selected profile"
  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.bindings.repositories={}; v.bindings.owners={}; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$d/home/config/github-accounts.json"
  out=$(FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" FM_TEST_PR_STATE=MERGED PATH="$d/hostile:$PATH" \
    bash "$state/task-poll.check.sh")
  [ "$out" = merged ] || fail "stable delayed profile could not survive a project-only binding"

  malicious="$d/legacy-poll.sh"
  marker="$d/legacy-executed"
  cat > "$malicious" <<SH
#!/usr/bin/env bash
touch '$marker'
SH
  chmod 0600 "$malicious"
  FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" bash -c '
    . "$FM_ROOT_OVERRIDE/bin/fm-pr-lib.sh"
    fm_pr_poll_prepare "$FM_STATE_OVERRIDE" task-poll https://github.com/Owner-A/repo-a/pull/17 Owner-A repo-a 17 "$1"
    fm_pr_poll_publish_prepared
  ' _ "$malicious" || fail "could not prepare legacy migration fixture"
  [ "$(sed -n '1p' "$state/task-poll.pr-poll-registration")" = fm-pr-poll-registration-v1 ] || fail "legacy fixture was not v1"
  FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" PATH="$d/hostile:$PATH" \
    "$ROOT/bin/fm-pr-check-migrate.sh" >/dev/null 2>&1 || fail "strict delayed poll migration failed"
  [ ! -e "$marker" ] || fail "legacy delayed content executed during migration"
  [ "$(sed -n '5p' "$state/task-poll.pr-poll")" = profile-a ] || fail "migration did not rebuild an unambiguous stable profile id"
  [ "$(sed -n '1p' "$state/task-poll.pr-poll-registration")" = fm-pr-poll-registration-v2 ] || fail "migration did not publish authenticated v2 records"
  pass "delayed polls bind stable profiles, revalidate on use, and migrate legacy content without execution"
}

test_no_mistakes_context_handoff_is_typed_and_secret_free() {
  local d fake_nm captured
  d=$(make_fixture no-mistakes)
  fake_nm="$d/exact/no-mistakes"
  captured="$d/nm-context.json"
  cat > "$fake_nm" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = init ] && [ "${2:-}" = --help ]; then printf '%s\n' '  --github-context string'; exit 0; fi
if [ "${1:-}" = init ]; then
  printf '%s\n' "$*" > "$FM_TEST_NM_CAPTURE.args"
  shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --github-context ]; then cp "$2" "$FM_TEST_NM_CAPTURE"; exit 0; fi
    shift
  done
fi
exit 91
SH
  chmod +x "$fake_nm"
  FM_NO_MISTAKES_BINARY="$fake_nm" FM_TEST_NM_CAPTURE="$captured" run_exec "$d" no-mistakes-init --project repo-a --repository "$d/home/projects/repo-a" \
    || fail "typed no-mistakes init failed"
  assert_grep '"expected_login": "account-a"' "$captured" "no-mistakes context missed selected login"
  assert_grep '"credential_helper": "gh"' "$captured" "no-mistakes context missed typed helper"
  assert_grep '--fork-url https://github.com/account-a/repo-a.git' "$captured.args" \
    "no-mistakes initialization did not derive the selected-profile fork"
  assert_no_grep "$SENTINEL" "$captured" "no-mistakes context persisted sentinel"
  assert_no_grep "$SENTINEL" "$captured.args" "no-mistakes argv persisted sentinel"
  assert_no_grep 'token' "$captured" "no-mistakes context persisted a token field"
  pass "no-mistakes receives only its typed non-secret repository context"
}

test_legacy_absence_is_byte_compatible
test_schema_and_resolution_strictness
test_concurrent_profiles_and_exact_children
test_forbidden_commands_and_access_diagnostics
test_commit_identity_and_removed_profile
test_direct_pr_fork_fleet_sync_and_secondmate_child
test_delayed_poll_profile_binding_and_nonexecuting_migration
test_no_mistakes_context_handoff_is_typed_and_secret_free
