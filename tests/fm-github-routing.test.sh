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

routing_file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

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
  case " \$* " in
    *' clone '*)
      destination=\${!#}
      source=\${FM_TEST_CLONE_SOURCE:-}
      [ -n "\$source" ] || { mkdir -p "\$destination"; exit 0; }
      '$REAL_GIT' clone --quiet "\$source" "\$destination"
      '$REAL_GIT' -C "\$destination" remote set-url origin "\${@: -2:1}"
      exit 0
      ;;
    *' fetch '*|*' push '*|*' ls-remote '*) exit 0 ;;
  esac
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
  cat > "$d/exact/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'no-mistakes\t%s\n' "$*" >> "${FM_TEST_NO_MISTAKES_LOG:-/dev/null}"
if [ "${1:-}" = init ] && [ "${2:-}" = --help ]; then
  printf '%s\n' '  --github-context string'
  exit 0
fi
if [ "${1:-}" = init ]; then
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --github-context ]; then
      cp "$2" "$FM_TEST_NO_MISTAKES_CONTEXT"
      break
    fi
    shift
  done
  exit 0
fi
exit 0
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
  chmod +x "$d/exact/git" "$d/exact/gh" "$d/exact/gh-axi" "$d/exact/no-mistakes" "$d/hostile/gh" "$d/hostile/git"
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
  local d=$1 cwd=$PWD arg expect_repository=0
  shift
  for arg in "$@"; do
    if [ "$expect_repository" -eq 1 ]; then
      [ ! -d "$arg" ] || cwd=$arg
      expect_repository=0
      continue
    fi
    case "$arg" in
      --repository) expect_repository=1 ;;
      --repository=*) [ ! -d "${arg#--repository=}" ] || cwd=${arg#--repository=} ;;
    esac
  done
  (
    cd "$cwd" || exit 1
    FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" \
      FM_NO_MISTAKES_BINARY="$d/exact/no-mistakes" \
      GH_TOKEN="$SENTINEL" GITHUB_TOKEN="$SENTINEL" GIT_ASKPASS="$d/$SENTINEL-askpass" \
      GIT_SSL_NO_VERIFY=1 HTTPS_PROXY="https://$SENTINEL@proxy.invalid" \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="Authorization: $SENTINEL" \
      PATH="$d/hostile:$PATH" "$EXEC" "$@"
  )
}

test_legacy_absence_is_byte_compatible() {
  local d="$TMP_ROOT/legacy" out
  mkdir -p "$d/home/config" "$d/fake"
  cat > "$d/fake/gh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "${GH_TOKEN:-}" "${FM_GITHUB_CONFIG_PATH:-}" "${FM_CONFIG_OVERRIDE:-}" "$*"
SH
  chmod +x "$d/fake/gh"
  out=$(FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" GH_TOKEN=legacy-token FM_GITHUB_CONFIG_PATH=legacy-pin FM_CONFIG_OVERRIDE=legacy-config PATH="$d/fake:$PATH" \
    "$EXEC" exec --repository github.com/owner/repo -- gh pr view 7)
  [ "$out" = 'legacy-token|legacy-pin|legacy-config|pr view 7' ] || fail "legacy absence changed ambient command bytes: $out"
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

  mv "$d/home/config/github-accounts.json" "$d/home/config/github-accounts.saved"
  ln -s "$d/home/config/missing-routing.json" "$d/home/config/github-accounts.json"
  set +e; run_exec "$d" validate >/dev/null 2>&1; rc=$?; set -e
  expect_code 1 "$rc" "dangling config symlink"
  rm "$d/home/config/github-accounts.json"
  mv "$d/home/config/github-accounts.saved" "$d/home/config/github-accounts.json"

  mv "$d/home/config" "$d/home/config.saved"
  ln -s config.saved "$d/home/config"
  set +e; run_exec "$d" validate >/dev/null 2>&1; rc=$?; set -e
  expect_code 1 "$rc" "config directory symlink"
  rm "$d/home/config"
  mv "$d/home/config.saved" "$d/home/config"

  mv "$d/home/config" "$d/home/config.saved"
  ln -s missing-config "$d/home/config"
  set +e; run_exec "$d" validate >/dev/null 2>&1; rc=$?; set -e
  expect_code 1 "$rc" "dangling config directory symlink"
  rm "$d/home/config"
  mv "$d/home/config.saved" "$d/home/config"

  mv "$d/home/config" "$d/home/config.saved"
  : > "$d/home/config"
  set +e; run_exec "$d" validate >/dev/null 2>&1; rc=$?; set -e
  expect_code 1 "$rc" "non-directory config path"
  rm "$d/home/config"
  mv "$d/home/config.saved" "$d/home/config"

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
  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.profiles["profile-b"].gh_config_dir=v.profiles["profile-a"].gh_config_dir; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$d/home/config/github-accounts.json"
  set +e; run_exec "$d" validate >/dev/null 2>&1; rc=$?; set -e
  expect_code 1 "$rc" "shared profile directory"

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

test_preregistration_project_bindings_are_narrow() {
  local d rc err
  d=$(make_fixture preregistration)
  node -e '
    const fs=require("fs");
    const p=process.argv[1];
    const v=JSON.parse(fs.readFileSync(p));
    v.bindings.projects={"new-project":"profile-a","created-project":"profile-a"};
    v.bindings.repositories={};
    v.bindings.owners={};
    fs.writeFileSync(p,JSON.stringify(v));
    fs.chmodSync(p,0o600);
  ' "$d/home/config/github-accounts.json"

  set +e
  (cd "$d/home/projects" && run_exec "$d" exec --project new-project --repository github.com/Owner-A/new-project -- \
    git clone https://github.com/Owner-A/new-project.git new-project >/dev/null 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unregistered project binding without authorization"

  (cd "$d/home/projects" && FM_TEST_FAKE_NETWORK=1 FM_TEST_CLONE_SOURCE="$d/home/projects/repo-a" \
    run_exec "$d" exec --project new-project --repository github.com/Owner-A/new-project --pre-register-project -- \
      git clone https://github.com/Owner-A/new-project.git new-project >/dev/null) \
    || fail "authorized pre-registration clone did not use its project binding"
  [ -d "$d/home/projects/new-project/.git" ] || fail "authorized pre-registration clone did not create its conventional destination"

  set +e
  (cd "$d/home/projects" && run_exec "$d" exec --project created-project --repository github.com/Owner-A/created-project --pre-register-project -- \
    gh pr view 1 --repo Owner-A/created-project >/dev/null 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "pre-registration non-onboarding operation"

  (cd "$d/home/projects" && run_exec "$d" exec --project created-project --repository github.com/Owner-A/created-project --pre-register-project -- \
    gh-axi repo create Owner-A/created-project --private >/dev/null) \
    || fail "authorized pre-registration repository creation did not use its project binding"

  set +e
  err=$(run_exec "$d" exec --project created-project --repository github.com/Owner-A/created-project --pre-register-project -- \
    gh repo create Owner-A/created-project --private 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "pre-registration create from unrelated checkout"
  assert_contains "$err" 'not the configured project or task copy' "pre-registration create accepted an unrelated checkout"

  printf '%s\n' '- created-project direct-PR - created (added 2026-07-22)' >> "$d/home/data/projects.md"
  set +e
  (cd "$d/home/projects" && run_exec "$d" exec --project created-project --repository github.com/Owner-A/created-project --pre-register-project -- \
    gh repo create Owner-A/created-project --private >/dev/null 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "pre-registration flag on registered project"
  pass "project-only bindings authorize only transactional pre-registration clone and create paths"
}

test_concurrent_profiles_and_exact_children() {
  local d p1 p2 contexts rc
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
  contexts=$(find "$d/home/state/.github-routing-path" -maxdepth 1 -type d -name 'context*' | wc -l | tr -d ' ')
  [ "$contexts" -eq 1 ] || fail "routing commands created $contexts persistent shim contexts"
  [ "$(routing_file_mode "$d/home/state/.github-routing-path/context-v1")" = 500 ] || fail "routing shim context is writable"
  chmod 0700 "$d/home/state/.github-routing-path/context-v1/gh"
  set +e
  run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- gh pr view 12 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "tampered persistent routing shim"
  pass "two repositories route concurrently through distinct exact profiles"
}

test_forbidden_commands_and_access_diagnostics() {
  local d rc err kind expected command branch
  local command_args=()
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
  err=$(run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    git -c ReMoTe.origin.PushURL=https://github.com/Other/repo-a push origin 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "split git config push URL"
  assert_contains "$err" 'forbidden credential' "split git config did not use the centralized unsafe-key policy"
  set +e
  err=$(run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    git -c ReMoTe.origin.URL=https://github.com/Other/repo-a push origin 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "command-scoped git remote URL"
  assert_contains "$err" 'forbidden credential' "command-scoped remote URL did not use the centralized unsafe-key policy"
  for command in \
    'git -c fetch.recurseSubmodules=true fetch origin' \
    'git -c submodule.escape.url=https://github.com/Other/repo-a fetch origin' \
    'git clone --config=submodule.escape.url=https://github.com/Other/repo-a https://github.com/Owner-A/repo-a.git blocked-clone'; do
    read -r -a command_args <<< "$command"
    set +e
    FM_TEST_FAKE_NETWORK=1 run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
      "${command_args[@]}" >/dev/null 2>&1
    rc=$?
    set -e
    expect_code 1 "$rc" "recursive submodule configuration: $command"
  done
  git -C "$d/home/projects/repo-a" config --local submodule.escape.url https://github.com/Other/repo-a
  set +e
  run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- gh pr view 1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "repository submodule URL configuration"
  git -C "$d/home/projects/repo-a" config --local --unset submodule.escape.url
  set +e
  run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    git clone --bundle-uri=https://github.com/Other/repo-a https://github.com/Owner-A/repo-a.git "$d/bundle-clone" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "clone bundle URI"
  set +e
  run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    git fetch-pack https://github.com/Owner-A/repo-a.git >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "unrecognized Git network plumbing"
  for command in config alias extension ssh-key; do
    case "$command" in
      config) command_args=(config set editor vim) ;;
      alias) command_args=(alias set escape api) ;;
      extension) command_args=(extension install owner/extension) ;;
      ssh-key) command_args=(ssh-key add key.pub) ;;
    esac
    set +e
    run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- gh "${command_args[@]}" >/dev/null 2>&1
    rc=$?
    set -e
    expect_code 1 "$rc" "unknown gh mutator $command"
  done

  set +e
  err=$(FM_TEST_FAKE_NETWORK=1 run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    git -C "$d/home/projects/repo-a" fetch https://github.com/Other/repo-a.git 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "foreign fetch route"
  assert_contains "$err" 'not the configured HTTPS parent' "foreign fetch target was not rejected"
  git -C "$d/home/projects/repo-a" remote add other https://github.com/Other/repo-a.git
  branch=$(git -C "$d/home/projects/repo-a" symbolic-ref --short HEAD)
  git -C "$d/home/projects/repo-a" config "branch.$branch.pushRemote" other
  set +e
  err=$(FM_TEST_FAKE_NETWORK=1 run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    git -C "$d/home/projects/repo-a" push 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "effective branch pushRemote"
  assert_contains "$err" 'not the configured HTTPS parent' "effective push target was not rejected"
  git -C "$d/home/projects/repo-a" config --unset "branch.$branch.pushRemote"
  git -C "$d/home/projects/repo-a" remote remove other
  set +e
  FM_TEST_FAKE_NETWORK=1 run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    git -C "$d/home/projects/repo-a" push --repo https://github.com/Other/repo-a.git >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "push --repo target"
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
  set +e
  err=$(run_exec "$d" exec --repository github.com/Owner-A/new -- gh repo create --private Other/new 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "repository positional after flags"
  assert_contains "$err" 'outside the configured parent' "repository positional parser skipped a post-flag target"
  for command in \
    'gh repo create Owner-A/new --template Other/template' \
    'gh issue transfer 1 Other/repo-a' \
    'gh issue develop 1 --branch-repo Other/repo-a' \
    'gh repo list --source OtherOwner' \
    'gh secret set NAME --org Other'; do
    read -r -a command_args <<< "$command"
    set +e
    run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- "${command_args[@]}" >/dev/null 2>&1
    rc=$?
    set -e
    expect_code 1 "$rc" "command-specific GitHub target: $command"
  done
  run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh pr comment 1 --body https://github.com/Other/repo-a >/dev/null \
    || fail "GitHub URL body text was mistaken for a repository target"
  assert_grep $'gh\tprofile-a\tpr comment 1 --body https://github.com/Other/repo-a' "$d/routes.log" \
    "typed GitHub grammar did not preserve body data"
  (cd "$d/home/projects" && run_exec "$d" exec --repository github.com/Owner-A/new-repository -- gh-axi repo create Owner-A/new-repository --private >/dev/null) \
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

  git -C "$d/home/projects/repo-a" remote add foreign https://github.com/Other/repo-a.git
  set +e
  err=$(run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- gh pr view 1 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "foreign selectable gh remote"
  assert_contains "$err" 'repository remote is not the configured HTTPS parent' "gh selectable remote was not rejected"
  git -C "$d/home/projects/repo-a" remote remove foreign

  git -C "$d/home/projects/repo-a" config --local remote.origin.gh-resolved base
  set +e
  run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- gh pr view 1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "gh-resolved remote override"
  git -C "$d/home/projects/repo-a" config --local --unset remote.origin.gh-resolved

  fm_git_init_commit "$d/unrelated"
  git -C "$d/unrelated" remote add origin https://github.com/Other/unrelated.git
  set +e
  err=$(FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" \
    FM_NO_MISTAKES_BINARY="$d/exact/no-mistakes" PATH="$d/hostile:$PATH" bash -c 'cd "$1" && "$2" exec --project repo-a --repository "$3" -- gh pr view 1 --repo Owner-A/repo-a' \
    _ "$d/unrelated" "$EXEC" "$d/home/projects/repo-a" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "explicit repository from unrelated cwd"
  assert_contains "$err" 'not the configured project or task copy' "explicit repository skipped the unrelated cwd checkout"

  git -C "$d/home/projects/repo-a" config extensions.worktreeConfig true
  git -C "$d/home/projects/repo-a" worktree add -q -b task-copy "$d/task-copy"
  git -C "$d/task-copy" config --worktree remote.origin.url https://github.com/Other/repo-a.git
  set +e
  err=$(FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" \
    FM_GITHUB_ACTIVE=1 FM_GITHUB_PROFILE_ID=profile-a \
    FM_GITHUB_REPOSITORY=github.com/Owner-A/repo-a FM_GITHUB_PROJECT=repo-a FM_GITHUB_PROJECT_PATH="$d/home/projects/repo-a" \
    FM_GITHUB_GIT_BINARY="$d/exact/git" PATH="$d/hostile:$PATH" \
    bash -c 'cd "$1" && "$2" child-gh --home "$3" -- pr view 1' _ "$d/task-copy" "$EXEC" "$d/home" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "worktree-scoped origin"
  assert_contains "$err" 'repository remote is not the configured HTTPS parent' "actual task worktree route did not fail closed"
  set +e
  err=$(FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" \
    PATH="$d/hostile:$PATH" bash -c 'cd "$1" && "$2" exec --project repo-a --repository "$3" -- gh pr view 1' \
    _ "$d/task-copy" "$EXEC" "$d/home/projects/repo-a" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "direct gh from worktree-scoped origin"
  assert_contains "$err" 'repository remote is not the configured HTTPS parent' "direct gh validated the primary clone instead of the task worktree"

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
  local d author rc err mode
  local mode_args=()
  d=$(make_fixture identity)
  printf '%s\n' routed > "$d/home/projects/repo-a/routed.txt"
  run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- git -C "$d/home/projects/repo-a" add routed.txt >/dev/null
  set +e
  err=$(run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    git -c user.name=Other -c user.email=other@example.test -C "$d/home/projects/repo-a" commit -m routed 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "commit identity override"
  set +e
  err=$(run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    git -C "$d/home/projects/repo-a" commit --author='Other <other@example.test>' -m routed 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "commit --author identity override"
  for mode in '-C HEAD' '-c HEAD' '--reuse-message=HEAD' '--reedit-message=HEAD' '--amend'; do
    read -r -a mode_args <<< "$mode"
    set +e
    run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
      git -C "$d/home/projects/repo-a" commit "${mode_args[@]}" -m routed >/dev/null 2>&1
    rc=$?
    set -e
    expect_code 1 "$rc" "commit authorship mode $mode"
  done
  run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- git -C "$d/home/projects/repo-a" commit -m routed >/dev/null
  author=$(git -C "$d/home/projects/repo-a" show -s --format='%an <%ae>' HEAD)
  [ "$author" = 'Account A <account-a@example.test>' ] || fail "selected commit identity was not applied: $author"

  printf '%s\n' second > "$d/home/projects/repo-a/second.txt"
  git -C "$d/home/projects/repo-a" add second.txt
  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); delete v.profiles["profile-a"].commit_identity; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$d/home/config/github-accounts.json"
  set +e
  err=$(run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- git -C "$d/home/projects/repo-a" commit -m second 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "missing commit identity"
  assert_contains "$err" 'needs commit_identity' "missing commit identity was not rejected explicitly"
  git -C "$d/home/projects/repo-a" reset -q HEAD second.txt
  write_config "$d"

  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); delete v.profiles["profile-a"]; delete v.bindings.projects["repo-a"]; delete v.bindings.repositories["github.com/Owner-A/repo-a"]; delete v.bindings.owners["github.com/Owner-A"]; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$d/home/config/github-accounts.json"
  set +e
  err=$(FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_GITHUB_ACTIVE=1 FM_GITHUB_PROFILE_ID=profile-a \
    FM_GITHUB_REPOSITORY=github.com/Owner-A/repo-a FM_GITHUB_PROJECT=repo-a "$EXEC" child-gh --home "$d/home" -- pr view 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "removed profile fell back"
  assert_not_contains "$err" "$SENTINEL" "removed profile error leaked sentinel"
  pass "commit identity is selected and removed profiles cannot fall back"
}

test_pinned_config_and_fork_bindings() {
  local d hostile_config alternate_home rc err
  d=$(make_fixture pinned)
  hostile_config="$d/hostile-config"
  mkdir -p "$hostile_config"
  cp "$d/home/config/github-accounts.json" "$hostile_config/github-accounts.json"
  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.profiles["profile-a"].expected_login="wrong-login"; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$hostile_config/github-accounts.json"
  FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" \
    FM_GITHUB_ACTIVE=1 FM_GITHUB_CONFIG_PATH="$hostile_config/github-accounts.json" FM_GITHUB_CONFIG="$hostile_config/github-accounts.json" FM_CONFIG_OVERRIDE="$hostile_config" \
    FM_GITHUB_PROFILE_ID=profile-a FM_GITHUB_REPOSITORY=github.com/Owner-A/repo-a FM_GITHUB_PROJECT=repo-a FM_GITHUB_PROJECT_PATH="$d/home/projects/repo-a" \
    FM_GITHUB_GIT_BINARY="$d/exact/git" PATH="$d/hostile:$PATH" \
    bash -c 'cd "$1" && "$2" child-gh --home "$3" -- pr view 1' _ "$d/home/projects/repo-a" "$EXEC" "$d/home" >/dev/null \
    || fail "descendant routing context did not use its authoritative home config"

  alternate_home="$d/alternate-home"
  mkdir -p "$alternate_home/config"
  cp "$d/home/config/github-accounts.json" "$alternate_home/config/github-accounts.json"
  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.profiles["profile-a"].expected_login="wrong-login"; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$alternate_home/config/github-accounts.json"
  run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    bash -c 'FM_HOME="$1" gh pr view 1' _ "$alternate_home" >/dev/null \
    || fail "descendant FM_HOME redirected the authoritative routing context"

  git -C "$d/home/projects/repo-a" remote add fork https://github.com/account-a/repo-a.git
  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.bindings.owners["github.com/account-a"]="profile-b"; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$d/home/config/github-accounts.json"
  set +e
  err=$(FM_TEST_FAKE_NETWORK=1 run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- git -C "$d/home/projects/repo-a" push fork feature 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "conflicting fork owner binding"
  assert_contains "$err" 'not the configured HTTPS parent' "fork owner binding conflict did not fail before push"
  pass "descendants use authoritative home config and fork routes honor every binding"
}

test_secondmate_routing_inheritance_is_validated_and_sanitized() {
  local d child report instruction rc err source saved
  d=$(make_fixture inheritance)
  child="$d/inherited-home"
  report="$d/inheritance.report"
  instruction="$child/state/reread"
  mkdir -p "$child/config" "$child/state"
  source="$d/home/config/github-accounts.json"
  node -e 'const fs=require("fs"); const p=process.argv[1]; fs.writeFileSync(p,JSON.stringify(JSON.parse(fs.readFileSync(p)))); fs.chmodSync(p,0o600)' "$source"
  : > "$report"
  FM_CONFIG_INHERIT_REPORT="$report" FM_INHERITABLE_CONFIG=github-accounts.json bash -c \
    '. "$1/bin/fm-config-inherit-lib.sh"; propagate_inheritable_config "$2" "$3"' \
    _ "$ROOT" "$d/home/config" "$child/config" \
    || fail "validated routing inheritance failed"
  [ "$(routing_file_mode "$child/config/github-accounts.json")" = 600 ] || fail "inherited routing config mode is not 0600"
  cmp -s "$source" "$child/config/github-accounts.json" && fail "routing inheritance copied raw source bytes instead of sanitized JSON"
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1]))' "$child/config/github-accounts.json" \
    || fail "sanitized inherited routing config is not valid JSON"
  set +e
  FM_INHERITABLE_CONFIG=github-accounts.json bash -c \
    '. "$1/bin/fm-config-inherit-lib.sh"; fm_config_write_reread_instruction "$2" "$3" "$4"' \
    _ "$ROOT" "$child" "$report" "$instruction"
  rc=$?
  set -e
  expect_code 1 "$rc" "routing-only reread instruction"
  [ ! -e "$instruction" ] || fail "routing config bytes were persisted in an agent reread instruction"

  saved="$d/home/config/github-accounts.saved"
  mv "$source" "$saved"
  ln -s "$saved" "$source"
  set +e
  err=$(FM_INHERITABLE_CONFIG=github-accounts.json bash -c \
    '. "$1/bin/fm-config-inherit-lib.sh"; propagate_inheritable_config "$2" "$3"' \
    _ "$ROOT" "$d/home/config" "$d/symlink-child/config" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "symlinked routing inheritance source"
  rm "$source"
  mv "$saved" "$source"

  chmod 0644 "$source"
  set +e
  FM_INHERITABLE_CONFIG=github-accounts.json bash -c \
    '. "$1/bin/fm-config-inherit-lib.sh"; propagate_inheritable_config "$2" "$3"' \
    _ "$ROOT" "$d/home/config" "$d/mode-child/config" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "wrong-mode routing inheritance source"
  chmod 0600 "$source"

  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.token=process.argv[2]; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$source" "$SENTINEL"
  set +e
  err=$(FM_INHERITABLE_CONFIG=github-accounts.json bash -c \
    '. "$1/bin/fm-config-inherit-lib.sh"; propagate_inheritable_config "$2" "$3"' \
    _ "$ROOT" "$d/home/config" "$d/schema-child/config" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "schema-invalid routing inheritance source"
  assert_not_contains "$err" "$SENTINEL" "invalid routing inheritance leaked source bytes"
  [ ! -e "$d/schema-child/config/github-accounts.json" ] || fail "invalid routing source was copied downstream"
  pass "secondmate routing inheritance validates, sanitizes, and never inlines config bytes"
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
  (cd "$child" && FM_HOME="$child" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" \
    FM_NO_MISTAKES_BINARY="$d/exact/no-mistakes" PATH="$d/hostile:$PATH" \
    "$EXEC" exec --project repo-b --repository github.com/Owner-B/repo-b -- gh pr view 3 --repo Owner-B/repo-b >/dev/null) \
    || fail "secondmate child did not resolve inherited routing"
  assert_grep $'gh\tprofile-b\tpr view 3 --repo Owner-B/repo-b' "$d/routes.log" "secondmate child did not use profile-b"
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
  local d fake_nm captured log refresh_count
  d=$(make_fixture no-mistakes)
  fake_nm="$d/exact/no-mistakes"
  captured="$d/nm-context.json"
  log="$d/no-mistakes.log"
  cat > "$fake_nm" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_TEST_NM_LOG"
if [ "${1:-}" = init ] && [ "${2:-}" = --help ]; then printf '%s\n' '  --github-context string'; exit 0; fi
if [ "${1:-}" = init ]; then
  printf '%s\n' "$*" > "$FM_TEST_NM_CAPTURE.args"
  shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --github-context ]; then cp "$2" "$FM_TEST_NM_CAPTURE"; fi
    shift
  done
  exit 0
fi
if [ "${1:-}" = axi ] && [ "${2:-}" = run ]; then exit 0; fi
exit 91
SH
  chmod +x "$fake_nm"
  : > "$log"
  FM_NO_MISTAKES_BINARY="$fake_nm" FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" \
    run_exec "$d" no-mistakes-init --project repo-a --repository "$d/home/projects/repo-a" \
    || fail "typed no-mistakes init failed"
  assert_grep '"expected_login": "account-a"' "$captured" "no-mistakes context missed selected login"
  assert_grep '"credential_helper": "gh"' "$captured" "no-mistakes context missed typed helper"
  assert_grep '--fork-url https://github.com/account-a/repo-a.git' "$captured.args" \
    "no-mistakes initialization did not derive the selected-profile fork"
  assert_no_grep "$SENTINEL" "$captured" "no-mistakes context persisted sentinel"
  assert_no_grep "$SENTINEL" "$captured.args" "no-mistakes argv persisted sentinel"
  assert_no_grep 'token' "$captured" "no-mistakes context persisted a token field"
  : > "$log"
  FM_NO_MISTAKES_BINARY="$fake_nm" FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" \
    run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- no-mistakes axi run >/dev/null \
    || fail "strict no-mistakes run did not refresh its typed context"
  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.profiles["profile-a"].commit_identity.name="Refreshed Account A"; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$d/home/config/github-accounts.json"
  FM_NO_MISTAKES_BINARY="$fake_nm" FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" \
    run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- no-mistakes axi run >/dev/null \
    || fail "second strict no-mistakes run did not refresh its typed context"
  assert_grep '"name": "Refreshed Account A"' "$captured" "strict run preserved stale no-mistakes context"
  refresh_count=$(grep -c '^init --github-context ' "$log")
  [ "$refresh_count" -eq 2 ] || fail "strict runs refreshed no-mistakes context $refresh_count times instead of twice"
  pass "no-mistakes receives secret-free context and refreshes it before every strict run"
}

test_secondmate_seed_does_not_leak_project_context() {
  local d secondhome
  d=$(make_fixture seed-context)
  secondhome="$d/seeded-secondmate"
  printf '%s\n' '- repo-b [direct-PR] +yolo - B (added 2026-07-21)' > "$d/home/data/projects.md"
  FM_HOME="$d/home" FM_SECONDMATE_CHARTER='routing seed context' FM_SECONDMATE_SCOPE='routing seed context' \
    "$ROOT/bin/fm-brief.sh" routing-sm --secondmate repo-b >/dev/null \
    || fail "could not scaffold strict secondmate seed fixture"
  FM_HOME="$d/home" FM_NO_MISTAKES_BINARY="$d/exact/no-mistakes" FM_TEST_FAKE_NETWORK=1 \
    FM_TEST_CLONE_SOURCE="$d/home/projects/repo-b" FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" \
    "$ROOT/bin/fm-home-seed.sh" routing-sm "$secondhome" repo-b >/dev/null \
    || fail "strict secondmate seed leaked its project context into local home creation"
  [ -d "$secondhome/projects/repo-b/.git" ] || fail "strict secondmate seed did not clone the routed project"
  [ "$(git -C "$secondhome/projects/repo-b" remote get-url origin)" = https://github.com/Owner-B/repo-b.git ] \
    || fail "strict secondmate seed did not preserve the routed origin"
  pass "secondmate seed scopes strict activation to routed validation and clone subprocesses"
}

test_legacy_absence_is_byte_compatible
test_schema_and_resolution_strictness
test_preregistration_project_bindings_are_narrow
test_concurrent_profiles_and_exact_children
test_forbidden_commands_and_access_diagnostics
test_commit_identity_and_removed_profile
test_pinned_config_and_fork_bindings
test_secondmate_routing_inheritance_is_validated_and_sanitized
test_direct_pr_fork_fleet_sync_and_secondmate_child
test_delayed_poll_profile_binding_and_nonexecuting_migration
test_no_mistakes_context_handoff_is_typed_and_secret_free
test_secondmate_seed_does_not_leak_project_context
