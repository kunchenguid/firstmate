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
if [ "\${FM_TEST_ASSERT_SUBMODULE_DISABLED:-}" = 1 ] && [[ " \$* " = *' fetch '* ]]; then
  fetch_recurse= submodule_recurse=
  index=0
  while [ "\$index" -lt "\${GIT_CONFIG_COUNT:-0}" ]; do
    key_name=GIT_CONFIG_KEY_\$index
    value_name=GIT_CONFIG_VALUE_\$index
    case "\${!key_name}" in
      fetch.recurseSubmodules) fetch_recurse=\${!value_name} ;;
      submodule.recurse) submodule_recurse=\${!value_name} ;;
    esac
    index=\$((index + 1))
  done
  [ "\$fetch_recurse" = false ] && [ "\$submodule_recurse" = false ] || exit 92
fi
if [ "\${FM_TEST_SPOOF_UNSANITIZED_ORIGIN:-}" = 1 ] \
  && [[ " \$* " = *" -C \${FM_TEST_SPOOF_PATH_PREFIX}/"*' remote get-url origin '* ]] \
  && [ "\${GIT_CONFIG_COUNT:-0}" = 1 ]; then
  printf '%s\n' "\${GIT_CONFIG_VALUE_0}"
  exit 0
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
case "$*" in
  *'issueTypes(first:25)'*)
    printf '%s\n' '{"data":{"repository":{"issueTypes":{"nodes":[{"id":"TYPE_node_bug","name":"Bug"}]}}}}'
    exit 0
    ;;
  *' updateIssue(input:'*)
    printf '%s\n' '{"data":{"updateIssue":{"issue":{"id":"ISSUE_node_17"}}}}'
    exit 0
    ;;
esac
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
  "repo clone")
    git clone -- "https://github.com/${3}.git" "${4:-${3##*/}}"
    exit
    ;;
  "issue create")
    repo=Owner-A/repo-a
    case " $* " in *' --repo account-a/repo-a '*) repo=account-a/repo-a ;; esac
    printf 'https://github.com/%s/issues/17\n' "$repo"
    exit 0
    ;;
  "issue view")
    repo=Owner-A/repo-a
    case " $* " in *' --repo account-a/repo-a '*) repo=account-a/repo-a ;; esac
    printf '{"number":17,"title":"typed","state":"OPEN","url":"https://github.com/%s/issues/17","id":"ISSUE_node_17"}\n' "$repo"
    exit 0
    ;;
  "secret set"|"variable set")
    input=$(cat)
    printf 'stdin\t%s\t%s\t%s\n' "$profile" "$1 $2" "${#input}" >> "${FM_TEST_ROUTE_LOG:-/dev/null}"
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
case "${FM_TEST_GH_AXI_TYPED_API:-}" in
  read)
    gh api graphql --hostname github.com \
      -f 'query=query($owner:String!,$name:String!){repository(owner:$owner,name:$name){id}}' \
      -f owner=Owner-A -f name=repo-a
    exit
    ;;
  inline)
    gh api graphql -f 'query={repository(owner:"Owner-A",name:"repo-a"){pullRequests(states:[OPEN,MERGED]){totalCount}}}'
    exit
    ;;
  reviews) gh api repos/Owner-A/repo-a/pulls/17/reviews --paginate --slurp; exit ;;
  review-pair)
    gh api repos/Owner-A/repo-a/pulls/17/reviews --paginate --slurp
    gh api repos/Owner-A/repo-a/pulls/17/comments --paginate --slurp
    exit
    ;;
  relationships)
    gh api graphql -f 'query=query { repository(owner: "Owner-A", name: "repo-a") { issue(number: 17) { parent { number } subIssues(first: 100) { totalCount nodes { number } } } } }'
    exit
    ;;
  issue-type)
    gh api graphql -f owner=Owner-A -f name=repo-a \
      -f 'query=query($owner:String!,$name:String!){repository(owner:$owner,name:$name){issueTypes(first:25){nodes{id name}}}}'
    if [ "${2:-}" = create ]; then gh issue create --title typed; fi
    gh issue view 17 --json number,title,state,labels,assignees,id
    gh api graphql -f id=ISSUE_node_17 -f typeId=TYPE_node_bug \
      -f 'query=mutation($id:ID!,$typeId:ID!){updateIssue(input:{id:$id,issueTypeId:$typeId}){issue{id}}}'
    exit
    ;;
  issue-type-fork)
    gh api graphql -f owner=account-a -f name=repo-a \
      -f 'query=query($owner:String!,$name:String!){repository(owner:$owner,name:$name){issueTypes(first:25){nodes{id name}}}}'
    gh issue view 17 --json number,title,state,labels,assignees,id --repo account-a/repo-a
    gh api graphql -f id=ISSUE_node_17 -f typeId=TYPE_node_bug \
      -f 'query=mutation($id:ID!,$typeId:ID!){updateIssue(input:{id:$id,issueTypeId:$typeId}){issue{id}}}'
    exit
    ;;
  issue-clear-type)
    gh issue view 17 --json number,title,state,labels,assignees,id
    gh api graphql -f id=ISSUE_node_17 \
      -f 'query=mutation($id:ID!){updateIssue(input:{id:$id,issueTypeId:null}){issue{id}}}'
    exit
    ;;
  wrong-issue-id)
    gh api graphql -f owner=Owner-A -f name=repo-a \
      -f 'query=query($owner:String!,$name:String!){repository(owner:$owner,name:$name){issueTypes(first:25){nodes{id name}}}}'
    gh issue view 17 --json number,title,state,labels,assignees,id
    gh api graphql -f id=ISSUE_node_other -f typeId=TYPE_node_bug \
      -f 'query=mutation($id:ID!,$typeId:ID!){updateIssue(input:{id:$id,issueTypeId:$typeId}){issue{id}}}'
    exit
    ;;
  wrong-type-id)
    gh api graphql -f owner=Owner-A -f name=repo-a \
      -f 'query=query($owner:String!,$name:String!){repository(owner:$owner,name:$name){issueTypes(first:25){nodes{id name}}}}'
    gh issue view 17 --json number,title,state,labels,assignees,id
    gh api graphql -f id=ISSUE_node_17 -f typeId=TYPE_node_other \
      -f 'query=mutation($id:ID!,$typeId:ID!){updateIssue(input:{id:$id,issueTypeId:$typeId}){issue{id}}}'
    exit
    ;;
  credential) gh auth token; exit ;;
  destructive) gh issue delete 17 --yes; exit ;;
  global) gh repo list; exit ;;
  cross-command) gh issue view 17 --json id --repo Other/repo-a; exit ;;
  unbound-create) gh issue create --title hijack; exit ;;
  normalized-pr) gh pr view 17 --json number,title,state,author,isDraft,mergedAt,statusCheckRollup,body,comments,reviews; exit ;;
  escalated-merge) gh pr merge 17 --admin --delete-branch; exit ;;
  changed-release) gh release delete other --yes; exit ;;
  untyped-create)
    gh issue create --title plain
    gh issue view 17 --json number,title,state,url,id
    exit
    ;;
  pr-reopen)
    gh pr view 17 --json state
    gh pr reopen 17
    exit
    ;;
  run-cancel)
    gh run view 44 --json status,conclusion
    gh run cancel 44
    exit
    ;;
  workflow-enable)
    gh workflow list --json id,name,state,path --all
    gh workflow enable ci.yml
    exit
    ;;
  release-delete)
    gh release view v1 --json tagName
    gh release delete v1 --yes
    exit
    ;;
  stdin-secret)
    input=$(cat)
    printf '%s' "$input" | gh secret set ROUTED_VALUE
    exit
    ;;
  stdin-changed)
    cat >/dev/null
    printf '%s' substituted | gh secret set ROUTED_VALUE
    exit
    ;;
  stdin-variable)
    printf '%s' "${5:-}" | gh variable set ROUTED_VALUE
    exit
    ;;
  approved-body)
    gh pr comment 17 --body "$(cat "$5")"
    exit
    ;;
  changed-body)
    gh pr comment 17 --body substituted
    exit
    ;;
  merge-method)
    gh pr view 17 --json state,mergedBy,mergedAt
    gh pr merge 17 --squash
    exit
    ;;
  release-aliases)
    gh release create v2 --notes "$(cat "$7")" --draft --prerelease
    exit
    ;;
  issue-transfer)
    gh issue transfer 17 account-a/repo-a --repo Owner-A/repo-a
    gh issue view 17 --json number,url --repo account-a/repo-a
    exit
    ;;
  conflicting-selectors) gh issue view https://github.com/Other/repo-a/issues/17 --json number,id --repo Owner-A/repo-a; exit ;;
  foreign) gh api repos/Other/repo-a; exit ;;
  forks) gh api repos/Owner-A/repo-a/forks; exit ;;
  mutation)
    gh api graphql --hostname github.com \
      -f 'query=mutation($owner:String!,$name:String!){deleteRepository(input:{repositoryId:"x"}){clientMutationId}}' \
      -f owner=Owner-A -f name=repo-a
    exit
    ;;
  type-mutation)
    gh api graphql -f id=ISSUE_node_17 \
      -f 'query=mutation($id:ID!){deleteIssue(input:{issueId:$id}){clientMutationId}}'
    exit
    ;;
  traversal)
    gh api graphql --hostname github.com \
      -f 'query=query($owner:String!,$name:String!){repository(owner:$owner,name:$name){owner{repositories{nodes{name}}}}}' \
      -f owner=Owner-A -f name=repo-a
    exit
    ;;
  head-repository)
    gh api graphql --hostname github.com \
      -f 'query=query($owner:String!,$name:String!){repository(owner:$owner,name:$name){pullRequest(number:1){headRepository{id}}}}' \
      -f owner=Owner-A -f name=repo-a
    exit
    ;;
esac
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
      GH_TOKEN="$SENTINEL" GITHUB_TOKEN="$SENTINEL" GIT_ASKPASS="$d/$SENTINEL-askpass" \
      GIT_SSL_NO_VERIFY=1 HTTPS_PROXY="https://$SENTINEL@proxy.invalid" \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="Authorization: $SENTINEL" \
      PATH="$d/hostile:$d/exact:$PATH" "$EXEC" "$@"
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
  cat > "$d/fake/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "${GH_TOKEN:-}" "${FM_CONFIG_OVERRIDE:-}" "$*"
SH
  chmod +x "$d/fake/no-mistakes"
  out=$(FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" GH_TOKEN=legacy-token FM_GITHUB_CONFIG_PATH=legacy-pin FM_CONFIG_OVERRIDE=legacy-config PATH="$d/fake:$PATH" \
    "$EXEC" exec --repository github.com/owner/repo -- gh pr view 7)
  [ "$out" = 'legacy-token|legacy-pin|legacy-config|pr view 7' ] || fail "legacy absence changed ambient command bytes: $out"
  mkdir -p "$d/repository"
  out=$(FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" GH_TOKEN=legacy-token FM_CONFIG_OVERRIDE=legacy-config \
    FM_NO_MISTAKES_BINARY="$d/fake/no-mistakes" PATH="$d/fake:$PATH" \
    "$EXEC" no-mistakes-init --repository "$d/repository" --fork-url https://github.com/owner/repo.git)
  [ "$out" = 'legacy-token|legacy-config|init --fork-url https://github.com/owner/repo.git' ] \
    || fail "legacy no-mistakes initialization changed ambient command bytes: $out"
  pass "github routing absence preserves legacy ambient command behavior"
}

test_operation_schema_is_shared() {
  local rc
  node "$ROOT/bin/fm-github-operation-schema.mjs" validate || fail "typed operation schema validation failed"
  [ "$(node "$ROOT/bin/fm-github-operation-schema.mjs" option-kind issue:transfer --to-repo)" = destination_repo ] \
    || fail "public transfer option did not resolve through the typed operation schema"
  [ "$(node "$ROOT/bin/fm-github-operation-schema.mjs" option-kind release:create -p)" = flag ] \
    || fail "public release alias did not resolve through the typed operation schema"
  node "$ROOT/bin/fm-github-operation-schema.mjs" validate-clear-type issue edit 17 --no-type --repo Owner-A/repo-a \
    || fail "clear-type variant was rejected by the typed operation schema"
  node "$ROOT/bin/fm-github-operation-schema.mjs" has-issue-type-variant issue edit 17 --no-type \
    || fail "clear-type variant was not shared with the public native-command boundary"
  set +e
  node "$ROOT/bin/fm-github-operation-schema.mjs" validate-clear-type issue edit 17 --no-type --title changed
  rc=$?
  set -e
  expect_code 1 "$rc" "non-atomic clear-type schema variant"
  set +e
  node "$ROOT/bin/fm-github-operation-schema.mjs" validate-clear-type issue edit 17 --no-type --repo
  rc=$?
  set -e
  expect_code 1 "$rc" "clear-type schema missing repository value"
  pass "public and descendant routing consume one typed operation schema"
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
  write_config "$d"
  node -e '
    const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p));
    const token=`ghp_${"A".repeat(36)}`;
    v.profiles[token]=v.profiles["profile-a"];
    delete v.profiles["profile-a"];
    v.bindings.projects["repo-a"]=token;
    v.bindings.repositories["github.com/Owner-A/repo-a"]=token;
    v.bindings.owners["github.com/Owner-A"]=token;
    fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600);
  ' "$d/home/config/github-accounts.json"
  set +e; err=$(run_exec "$d" validate 2>&1); rc=$?; set -e
  expect_code 1 "$rc" "credential-shaped configured string"
  assert_not_contains "$err" 'ghp_AAAAA' "credential-shaped config rejection leaked credential bytes"
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

  write_config "$d"
  set +e
  (cd "$d/home/projects" && FM_GITHUB_ALLOW_UNREGISTERED_PROJECT=1 FM_TEST_FAKE_NETWORK=1 \
    run_exec "$d" exec --project owner-clone --repository github.com/Owner-A/owner-clone -- \
      git clone https://github.com/Owner-A/owner-clone.git "$d/arbitrary-clone" >/dev/null 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "ambient onboarding authority and arbitrary clone destination"
  [ ! -e "$d/arbitrary-clone" ] || fail "ambient onboarding authority created an arbitrary clone destination"

  node -e '
    const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p));
    v.bindings.projects={"new-project":"profile-a","created-project":"profile-a"};
    v.bindings.repositories={}; v.bindings.owners={};
    fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600);
  ' "$d/home/config/github-accounts.json"

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
  (cd "$d/home/projects" && run_exec "$d" exec --project created-project --repository github.com/Owner-A/created-project --pre-register-project -- \
    gh repo create Owner-A/created-project --private --clone >/dev/null 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "combined repository creation and clone"

  set +e
  err=$(run_exec "$d" exec --project created-project --repository github.com/Owner-A/created-project --pre-register-project -- \
    gh repo create Owner-A/created-project --private 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "pre-registration create from unrelated checkout"
  assert_contains "$err" 'pre-registration GitHub routing' "pre-registration create accepted an unrelated checkout"

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
  mkdir -p "$d/home/state/.github-routing-path"
  printf '%s\n%s\n%s\n%s\n' fm-github-lock-v1 999999 'dead process' \
    "$(cd "$d/home/state/.github-routing-path" && pwd -P)/.lock-owner.stale" > "$d/home/state/.github-routing-path/.install.lock"
  chmod 0600 "$d/home/state/.github-routing-path/.install.lock"
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
  [ "$(routing_file_mode "$d/home/state/.github-routing-path/context-v2")" = 500 ] || fail "routing shim context is writable"
  [ ! -e "$d/home/state/.github-routing-path/.install.lock" ] || fail "stale routing shim lock was not recovered"
  printf '%s\n' unproven > "$d/home/state/.github-routing-path/.install.lock"
  chmod 0600 "$d/home/state/.github-routing-path/.install.lock"
  set +e
  FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" bash -c '. "$FM_ROOT_OVERRIDE/bin/fm-github-lib.sh"; fm_github_lock_acquire "$FM_HOME/state/.github-routing-path/.install.lock" 1' >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "unproven routing lock"
  [ -f "$d/home/state/.github-routing-path/.install.lock" ] || fail "unproven routing lock was evicted"
  rm -f "$d/home/state/.github-routing-path/.install.lock"
  FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" bash -c '
    . "$FM_ROOT_OVERRIDE/bin/fm-github-lib.sh"
    lock="$FM_HOME/state/.github-routing-path/.owner-test.lock"
    fm_github_lock_acquire "$lock" 1
    [ "$(sed -n "2p" "$lock")" = "$$" ]
    fm_github_lock_release
  ' || fail "routing lock did not record the actual owning shell"
  chmod 0700 "$d/home/state/.github-routing-path/context-v2/gh"
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
  FM_TEST_ASSERT_SUBMODULE_DISABLED=1 FM_TEST_FAKE_NETWORK=1 \
    run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- git fetch origin >/dev/null \
    || fail "authoritative Git context did not disable implicit submodule recursion"
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
  FM_TEST_GH_AXI_TYPED_API=read run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi pr view 1 >/dev/null \
    || fail "verified gh-axi descendant could not perform its typed internal API operation"
  for kind in inline reviews review-pair; do
    FM_TEST_GH_AXI_TYPED_API=$kind run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
      gh-axi pr view 1 >/dev/null \
      || fail "verified gh-axi descendant could not perform its typed $kind operation"
  done
  FM_TEST_GH_AXI_TYPED_API=relationships run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi issue view 17 >/dev/null \
    || fail "verified gh-axi descendant could not read typed issue relationships"
  FM_TEST_GH_AXI_TYPED_API=normalized-pr run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi pr view 17 >/dev/null \
    || fail "normalized gh-axi PR view descendant was rejected"
  FM_TEST_GH_AXI_TYPED_API=untyped-create run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi issue create --title plain >/dev/null \
    || fail "untyped issue create did not bind its follow-up view"
  printf '%s' 'routed-value' | FM_TEST_GH_AXI_TYPED_API=stdin-secret run_exec "$d" exec --project repo-a \
    --repository "$d/home/projects/repo-a" -- gh-axi secret set ROUTED_VALUE >/dev/null \
    || fail "routed secret stdin was not carried through the broker"
  FM_TEST_GH_AXI_TYPED_API=stdin-variable run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi variable set ROUTED_VALUE --body routed-value >/dev/null \
    || fail "routed inline variable value was not bound to broker stdin"
  assert_grep $'stdin\tprofile-a\tsecret set\t12' "$d/routes.log" "secret stdin length was not preserved"
  assert_grep $'stdin\tprofile-a\tvariable set\t12' "$d/routes.log" "variable stdin length was not preserved"
  set +e
  printf '%s' 'routed-value' | FM_TEST_GH_AXI_TYPED_API=stdin-changed run_exec "$d" exec --project repo-a \
    --repository "$d/home/projects/repo-a" -- gh-axi secret set ROUTED_VALUE >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "substituted routed stdin"
  printf '%s' 'approved body' > "$d/approved-body.md"
  FM_TEST_GH_AXI_TYPED_API=approved-body run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi pr comment 17 --body-file "$d/approved-body.md" >/dev/null \
    || fail "approved generated body was rejected"
  set +e
  FM_TEST_GH_AXI_TYPED_API=changed-body run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi pr comment 17 --body-file "$d/approved-body.md" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "substituted generated body"
  FM_TEST_GH_AXI_TYPED_API=merge-method run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi pr merge 17 --method squash >/dev/null \
    || fail "typed merge method translation was rejected"
  FM_TEST_GH_AXI_TYPED_API=release-aliases run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi release create v2 -d -p --body-file "$d/approved-body.md" >/dev/null \
    || fail "typed release alias translation was rejected"
  for child_contract in 'pr-reopen pr reopen 17' 'run-cancel run cancel 44' \
    'workflow-enable workflow enable ci.yml' 'release-delete release delete v1'; do
    read -r mode family subcommand target <<< "$child_contract"
    FM_TEST_GH_AXI_TYPED_API=$mode run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
      gh-axi "$family" "$subcommand" "$target" >/dev/null \
      || fail "normalized $family $subcommand child contract was rejected"
  done
  FM_TEST_GH_AXI_TYPED_API=issue-transfer run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi issue transfer 17 -R Owner-A/repo-a --to-repo account-a/repo-a >/dev/null \
    || fail "typed issue transfer grammar or child contract was rejected"
  FM_TEST_GH_AXI_TYPED_API=issue-type run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi issue create --title typed --type Bug >/dev/null \
    || fail "verified gh-axi descendant could not apply a scoped issue type"
  FM_TEST_GH_AXI_TYPED_API=issue-type run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi issue edit 17 --type Bug >/dev/null \
    || fail "verified gh-axi descendant could not edit a scoped issue type"
  FM_TEST_GH_AXI_TYPED_API=issue-clear-type run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi issue edit 17 --no-type >/dev/null \
    || fail "verified gh-axi descendant could not clear a scoped issue type"
  set +e
  FM_TEST_GH_AXI_TYPED_API=issue-clear-type run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi issue edit 17 --no-type --title changed >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "non-atomic issue type clear"
  if grep -F $'gh-axi\tprofile-a\tissue edit 17 --no-type --title changed' "$d/routes.log" >/dev/null; then
    fail "non-atomic issue type clear reached a routed mutation"
  fi
  FM_TEST_GH_AXI_TYPED_API=issue-type-fork run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi issue edit 17 --type Bug --repo account-a/repo-a >/dev/null \
    || fail "verified gh-axi descendant could not edit a selected-fork issue type"
  FM_TEST_GH_AXI_TYPED_API=issue-type-fork run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi issue edit --repo account-a/repo-a 17 --type Bug >/dev/null \
    || fail "verified gh-axi descendant could not parse flags before an issue target"
  FM_TEST_GH_AXI_TYPED_API=issue-type run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi issue edit https://github.com/Owner-A/repo-a/issues/17 --type Bug >/dev/null \
    || fail "verified gh-axi descendant could not parse a canonical issue URL"
  assert_grep $'gh-axi\tprofile-a\tissue edit 17 --type Bug --repo Owner-A/repo-a' "$d/routes.log" \
    "canonical issue URL was not normalized before gh-axi execution"
  assert_grep $'gh\tprofile-a\tapi graphql --hostname github.com' "$d/routes.log" \
    "typed gh-axi internal API call did not retain the selected profile"
  for kind in foreign forks mutation traversal head-repository; do
    set +e
    FM_TEST_GH_AXI_TYPED_API=$kind run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
      gh-axi pr view 1 >/dev/null 2>&1
    rc=$?
    set -e
    expect_code 1 "$rc" "gh-axi internal API broker $kind request"
  done
  set +e
  FM_TEST_GH_AXI_TYPED_API=type-mutation run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi issue create --title typed --type Bug >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "gh-axi non-typed mutation under issue-type grant"
  for kind in wrong-issue-id wrong-type-id; do
    set +e
    FM_TEST_GH_AXI_TYPED_API=$kind run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
      gh-axi issue edit 17 --type Bug >/dev/null 2>&1
    rc=$?
    set -e
    expect_code 1 "$rc" "gh-axi repository-bound $kind mutation"
  done
  for kind in credential destructive global cross-command unbound-create; do
    set +e
    FM_TEST_GH_AXI_TYPED_API=$kind run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
      gh-axi issue edit 17 --type Bug >/dev/null 2>&1
    rc=$?
    set -e
    expect_code 1 "$rc" "gh-axi non-API broker $kind command"
  done
  set +e
  FM_TEST_GH_AXI_TYPED_API=conflicting-selectors run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh-axi issue edit 17 --type Bug >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "gh-axi conflicting repository selectors"
  for attack in 'escalated-merge pr merge 17 --squash' 'changed-release release delete v1'; do
    read -r mode family subcommand target flag <<< "$attack"
    set +e
    FM_TEST_GH_AXI_TYPED_API=$mode run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
      gh-axi "$family" "$subcommand" "$target" ${flag:+"$flag"} >/dev/null 2>&1
    rc=$?
    set -e
    expect_code 1 "$rc" "gh-axi complete child schema $mode"
  done
  set +e
  run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
    gh issue edit 17 --type Bug >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "native issue type mutation"
  (cd "$d/home/projects" && FM_TEST_FAKE_NETWORK=1 FM_TEST_CLONE_SOURCE="$d/home/projects/repo-a" \
    run_exec "$d" exec --project clone-project --repository github.com/Owner-A/clone-project -- \
      gh repo clone Owner-A/clone-project clone-project >/dev/null) \
    || fail "guarded gh repo clone did not use its canonical project capability"
  [ -d "$d/home/projects/clone-project/.git" ] || fail "guarded gh repo clone did not create its canonical destination"
  set +e
  err=$(run_exec "$d" exec --repository github.com/Owner-A/new -- gh repo create --private Other/new 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "repository positional after flags"
  assert_contains "$err" 'requires an authorized pre-registration' "repository creation bypassed its explicit capability"
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
  set +e
  (cd "$d/home/projects" && run_exec "$d" exec --repository github.com/Owner-A/new-repository -- \
    gh-axi repo create Owner-A/new-repository --private >/dev/null 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "repository creation without pre-registration capability"
  (cd "$d/home/projects" && run_exec "$d" exec --project new-repository \
    --repository github.com/Owner-A/new-repository --pre-register-project -- \
    gh-axi repo create Owner-A/new-repository --private >/dev/null) \
    || fail "known-owner repository creation did not use its guarded owner binding"

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
    PATH="$d/hostile:$d/exact:$PATH" bash -c 'cd "$1" && "$2" exec --project repo-a --repository "$3" -- gh pr view 1 --repo Owner-A/repo-a' \
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
    PATH="$d/hostile:$d/exact:$PATH" \
    bash -c 'cd "$1" && "$2" exec --project repo-a --repository "$1" --profile profile-a -- gh pr view 1' \
    _ "$d/task-copy" "$EXEC" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "worktree-scoped origin"
  assert_contains "$err" 'repository remote is not the configured HTTPS parent' "actual task worktree route did not fail closed"

  set +e
  (cd "$d/home/projects/repo-a" && FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_GITHUB_ACTIVE=1 FM_GITHUB_PROFILE_ID=profile-a FM_GITHUB_REPOSITORY=github.com/Owner-A/repo-a \
    FM_GITHUB_PROJECT=repo-a FM_GITHUB_PROJECT_PATH="$d/home/projects/repo-a" \
    PATH="$d/hostile:$d/exact:$PATH" "$EXEC" child-gh --home "$d/home" -- api repos/Owner-A/repo-a >/dev/null 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "removed child gh entrypoint"
  set +e
  (cd "$d/home/projects" && FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_GITHUB_ACTIVE=1 FM_GITHUB_PROFILE_ID=profile-a FM_GITHUB_REPOSITORY=github.com/Owner-A/forged \
    FM_GITHUB_PROJECT=forged FM_GITHUB_CLONE_CAPABILITY=gh-project FM_GITHUB_CLONE_ROOT="$d/home/projects" \
    FM_GITHUB_PROJECT_PATH="$d/home/projects/forged" FM_GITHUB_GIT_BINARY="$d/exact/git" \
    FM_TEST_FAKE_NETWORK=1 PATH="$d/hostile:$d/exact:$PATH" \
    "$EXEC" child-git --home "$d/home" -- clone -- https://github.com/Owner-A/forged.git forged >/dev/null 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "removed child git entrypoint"
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
  err=$(FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" "$EXEC" exec --project repo-a \
    --repository "$d/home/projects/repo-a" --profile profile-a -- gh pr view 1 2>&1)
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
    PATH="$d/hostile:$d/exact:$PATH" \
    bash -c 'cd "$1" && "$2" exec --project repo-a --repository "$1" --profile profile-a -- gh pr view 1' \
      _ "$d/home/projects/repo-a" "$EXEC" >/dev/null \
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
  local d child report instruction rc err source saved override
  d=$(make_fixture inheritance)
  child="$d/inherited-home"
  report="$d/inheritance.report"
  instruction="$child/state/reread"
  mkdir -p "$child/config" "$child/state"
  source="$d/home/config/github-accounts.json"
  node -e 'const fs=require("fs"); const p=process.argv[1]; fs.writeFileSync(p,JSON.stringify(JSON.parse(fs.readFileSync(p)))); fs.chmodSync(p,0o600)' "$source"
  : > "$report"
  FM_CONFIG_INHERIT_REPORT="$report" FM_INHERITABLE_CONFIG=github-accounts.json bash -c \
    '. "$1/bin/fm-config-inherit-lib.sh"; propagate_inheritable_config "$2" "$3" "$4"' \
    _ "$ROOT" "$d/home/config" "$child/config" "$d/home" \
    || fail "validated routing inheritance failed"
  [ "$(routing_file_mode "$child/config/github-accounts.json")" = 600 ] || fail "inherited routing config mode is not 0600"
  cmp -s "$source" "$child/config/github-accounts.json" && fail "routing inheritance copied raw source bytes instead of sanitized JSON"
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1]))' "$child/config/github-accounts.json" \
    || fail "sanitized inherited routing config is not valid JSON"
  override="$d/override-config"
  mkdir -p "$override"
  FM_INHERITABLE_CONFIG=github-accounts.json bash -c \
    '. "$1/bin/fm-config-inherit-lib.sh"; propagate_inheritable_config "$2" "$3" "$4"' \
    _ "$ROOT" "$override" "$child/config" "$d/home" \
    || fail "canonical routing inheritance failed with a specialized config override"
  [ -f "$child/config/github-accounts.json" ] || fail "specialized config override removed canonical routing inheritance"
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
    '. "$1/bin/fm-config-inherit-lib.sh"; propagate_inheritable_config "$2" "$3" "$4"' \
    _ "$ROOT" "$d/home/config" "$d/symlink-child/config" "$d/home" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "symlinked routing inheritance source"
  rm "$source"
  mv "$saved" "$source"

  chmod 0644 "$source"
  set +e
  FM_INHERITABLE_CONFIG=github-accounts.json bash -c \
    '. "$1/bin/fm-config-inherit-lib.sh"; propagate_inheritable_config "$2" "$3" "$4"' \
    _ "$ROOT" "$d/home/config" "$d/mode-child/config" "$d/home" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "wrong-mode routing inheritance source"
  chmod 0600 "$source"

  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.token=process.argv[2]; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$source" "$SENTINEL"
  set +e
  err=$(FM_INHERITABLE_CONFIG=github-accounts.json bash -c \
    '. "$1/bin/fm-config-inherit-lib.sh"; propagate_inheritable_config "$2" "$3" "$4"' \
    _ "$ROOT" "$d/home/config" "$d/schema-child/config" "$d/home" 2>&1)
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
  FM_INHERITABLE_CONFIG=github-accounts.json bash -c '. "$1/bin/fm-config-inherit-lib.sh"; propagate_inheritable_config "$2" "$3" "$4"' \
    _ "$ROOT" "$d/home/config" "$child/config" "$d/home" || fail "secondmate routing inheritance failed"
  (cd "$child" && FM_HOME="$child" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" \
    PATH="$d/hostile:$d/exact:$PATH" \
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
  mkdir -p "$d/empty-config" "$d/ambient"
  cat > "$d/ambient/gh" <<SH
#!/usr/bin/env bash
touch '$marker'
printf '%s\n' MERGED
SH
  chmod +x "$d/ambient/gh"
  out=$(FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$d/empty-config" \
    PATH="$d/ambient:$PATH" bash "$ROOT/bin/fm-pr-poll.sh" --validated github \
      https://github.com/Owner-A/repo-a/pull/17 github.com Owner-A/repo-a 17)
  [ -z "$out" ] && [ ! -e "$marker" ] || fail "profile-less delayed poll hid canonical strict routing behind a config override"
  FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" PATH="$d/hostile:$PATH" \
    "$ROOT/bin/fm-pr-check-migrate.sh" >/dev/null 2>&1 || fail "strict delayed poll migration failed"
  [ ! -e "$marker" ] || fail "legacy delayed content executed during migration"
  [ "$(sed -n '5p' "$state/task-poll.pr-poll")" = profile-a ] || fail "migration did not rebuild an unambiguous stable profile id"
  [ "$(sed -n '1p' "$state/task-poll.pr-poll-registration")" = fm-pr-poll-registration-v2 ] || fail "migration did not publish authenticated v2 records"
  pass "delayed polls bind stable profiles, revalidate on use, and migrate legacy content without execution"
}

test_no_mistakes_context_handoff_is_typed_and_secret_free() {
  local d fake_nm captured log refresh_count rc err expected_pwd marker marker_before override_marker p1 p2 status current_branch current_head descendant_head mature_runs= n
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
  if [ "${1:-}" = axi ] && [ "${2:-}" = status ]; then
  [ -z "${FM_TEST_NM_STATUS_FAIL:-}" ] || exit 73
  branch=${FM_TEST_NM_BRANCH:-$(git symbolic-ref --quiet --short HEAD)}
  if [ -n "${FM_TEST_NM_ABSENCE_MODE:-}" ]; then
    printf '%s\n' 'no runs yet. Push through the gate to start a pipeline:'
    [ "$FM_TEST_NM_ABSENCE_MODE" != complete ] || printf '  git push no-mistakes %s\n' "$branch"
    exit "${FM_TEST_NM_NO_RUNS_STATUS:-0}"
  fi
  if [ -n "${FM_TEST_NM_NO_RUNS_ONCE:-}" ] && [ ! -e "$FM_TEST_NM_CAPTURE.no-runs-probed" ]; then
    touch "$FM_TEST_NM_CAPTURE.no-runs-probed"
    printf 'no runs yet. Push through the gate to start a pipeline:\n  git push no-mistakes %s\n' "$branch"
    exit "${FM_TEST_NM_NO_RUNS_STATUS:-0}"
  fi
  if [ -n "${FM_TEST_NM_MALFORMED_STATUS:-}" ]; then
    printf '%s\n' 'no runs yet but status is malformed'
    exit 0
  fi
  if [ -n "${FM_TEST_NM_CROSS_BRANCH_ONCE:-}" ] && [ ! -e "$FM_TEST_NM_CAPTURE.status-probed" ]; then
    branch=other-branch
    touch "$FM_TEST_NM_CAPTURE.status-probed"
  fi
  head=${FM_TEST_NM_HEAD:-$(git rev-parse HEAD)}
  run_id=run-0
  [ ! -e "$FM_TEST_NM_CAPTURE.run-id" ] || run_id=$(cat "$FM_TEST_NM_CAPTURE.run-id")
  status=completed
  [ ! -e "$FM_TEST_NM_CAPTURE.active" ] || status=${FM_TEST_NM_STATUS:-running}
  if [ -n "${FM_TEST_NM_QUOTED:-}" ]; then
    printf '  id: "%s"\n  branch: "%s"\n  status: "%s"\n  head: "%s"\n' "$run_id" "$branch" "$status" "$head"
  else
    printf '  id: %s\n  branch: %s\n  status: %s\n  head: %s\n' "$run_id" "$branch" "$status" "$head"
  fi
  exit 0
fi
if [ "${1:-}" = runs ]; then
  [ -z "${FM_TEST_NM_RUNS_FAIL:-}" ] || exit 74
  printf '%s' "${FM_TEST_NM_RUNS:-}"
  exit 0
fi
if [ "${1:-}" = axi ] && { [ "${2:-}" = run ] || [ "${2:-}" = respond ]; }; then
  if [ "${2:-}" = run ] && [ ! -e "$FM_TEST_NM_CAPTURE.active" ]; then printf '%s\n' run-1 > "$FM_TEST_NM_CAPTURE.run-id"; fi
  if [ "${2:-}" = run ] && [ -n "${FM_TEST_NM_MUTATE_CONFIG:-}" ]; then
    node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.profiles["profile-a"].commit_identity.name="Changed During Run"; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$FM_TEST_NM_MUTATE_CONFIG"
  fi
  touch "$FM_TEST_NM_CAPTURE.active"
  printf '%s\n' "$PWD" > "$FM_TEST_NM_CAPTURE.pwd"
  exit 0
fi
exit 91
SH
  chmod +x "$fake_nm"
  mkdir -p "$d/override"
  override_marker="$d/hostile-no-mistakes-executed"
  cat > "$d/override/no-mistakes" <<SH
#!/usr/bin/env bash
touch '$override_marker'
exit 97
SH
  chmod +x "$d/override/no-mistakes"
  : > "$log"
  FM_NO_MISTAKES_BINARY="$d/override/no-mistakes" FM_GITHUB_NO_MISTAKES_BINARY="$d/override/no-mistakes" \
    FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" \
    run_exec "$d" no-mistakes-init --project repo-a --repository "$d/home/projects/repo-a" \
    || fail "typed no-mistakes init failed"
  [ ! -e "$override_marker" ] || fail "strict routing executed a caller-selected no-mistakes binary"
  assert_grep '"expected_login": "account-a"' "$captured" "no-mistakes context missed selected login"
  assert_grep '"credential_helper": "gh"' "$captured" "no-mistakes context missed typed helper"
  assert_grep '--fork-url https://github.com/account-a/repo-a.git' "$captured.args" \
    "no-mistakes initialization did not derive the selected-profile fork"
  assert_no_grep "$SENTINEL" "$captured" "no-mistakes context persisted sentinel"
  assert_no_grep "$SENTINEL" "$captured.args" "no-mistakes argv persisted sentinel"
  assert_no_grep 'token' "$captured" "no-mistakes context persisted a token field"
  rmdir "$d/home/state/.github-routing-no-mistakes" || fail "typed initialization left unexpected marker state"
  : > "$log"
  (FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" \
    run_exec "$d" no-mistakes-init --project repo-a --repository "$d/home/projects/repo-a" >/dev/null) & p1=$!
  (FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" \
    run_exec "$d" no-mistakes-init --project repo-a --repository "$d/home/projects/repo-a" >/dev/null) & p2=$!
  wait "$p1" || fail "first concurrent no-mistakes initialization failed"
  wait "$p2" || fail "second concurrent no-mistakes initialization failed"
  : > "$log"
  fm_git_init_commit "$d/unrelated-no-mistakes"
  n=1
  while [ "$n" -le 101 ]; do
    mature_runs+="completed other-$n deadbee 2026-07-22 12:34:56"$'\n'
    n=$((n + 1))
  done
  (cd "$d/unrelated-no-mistakes" && FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" FM_TEST_ROUTE_LOG="$d/routes.log" \
    FM_TEST_NM_MUTATE_CONFIG="$d/home/config/github-accounts.json" \
    FM_TEST_NM_NO_RUNS_ONCE=1 FM_TEST_NM_RUNS="$mature_runs" \
    FM_TEST_SENTINEL="$SENTINEL" PATH="$d/hostile:$d/exact:$PATH" \
    "$EXEC" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
      no-mistakes axi run --intent initial >/dev/null) \
    || fail "strict no-mistakes run from another checkout failed"
  [ -e "$captured.no-runs-probed" ] || fail "strict no-mistakes run did not exercise explicit current-checkout absence"
  expected_pwd=$(cd "$d/home/projects/repo-a" && pwd -P)
  [ "$(cat "$captured.pwd")" = "$expected_pwd" ] || fail "strict no-mistakes run used the caller working directory"
  assert_no_grep 'runs --limit' "$log" "strict no-mistakes run guessed absence from bounded history"
  marker=$(find "$d/home/state/.github-routing-no-mistakes" -maxdepth 1 -type f -print | head -1)
  [ -n "$marker" ] && [ "$(routing_file_mode "$marker")" = 600 ] || fail "successful strict run did not record its typed routing marker"
  assert_grep '"name": "Account A"' "$marker" "new run marker recomputed routing after executor launch"
  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.profiles["profile-a"].commit_identity.name="Account A"; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$d/home/config/github-accounts.json"
  marker_before=$(cat "$marker")
  current_branch=$(git -C "$d/home/projects/repo-a" symbolic-ref --quiet --short HEAD)
  set +e
  FM_TEST_NM_BRANCH=other-branch \
    FM_TEST_NM_RUNS="running $current_branch deadbee 2026-07-22 12:34:56 https://github.com/Owner-A/repo-a/pull/17" \
    FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" \
    run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- no-mistakes axi respond accepted >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "cross-branch no-mistakes continuation"
  [ "$(cat "$marker")" = "$marker_before" ] || fail "cross-branch continuation changed the active no-mistakes binding marker"
  assert_no_grep 'runs --limit' "$log" "cross-branch no-mistakes continuation scanned repository history"
  current_head=$(git -C "$d/home/projects/repo-a" rev-parse HEAD)
  descendant_head=$(printf '%s\n' descendant | git -C "$d/home/projects/repo-a" \
    -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit-tree "$(git -C "$d/home/projects/repo-a" rev-parse 'HEAD^{tree}')" -p "$current_head")
  set +e
  FM_TEST_NM_HEAD="$descendant_head" FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" \
    run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- no-mistakes axi respond accepted >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "active mismatched-head no-mistakes continuation"
  [ "$(cat "$marker")" = "$marker_before" ] || fail "active head mismatch changed the no-mistakes binding marker"
  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.profiles["profile-a"].commit_identity.name="Refreshed Account A"; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$d/home/config/github-accounts.json"
  set +e
  err=$(FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" \
    run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- no-mistakes axi respond accepted 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "stale no-mistakes continuation context"
  assert_contains "$err" 'stale GitHub routing context' "stale no-mistakes continuation did not fail closed"
  set +e
  FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" \
    run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- \
      no-mistakes axi run --intent refreshed >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "changed routing while reattaching no-mistakes"
  [ "$(cat "$marker")" = "$marker_before" ] || fail "failed reattachment overwrote the active no-mistakes binding marker"
  node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.profiles["profile-a"].commit_identity.name="Account A"; fs.writeFileSync(p,JSON.stringify(v)); fs.chmodSync(p,0o600)' "$d/home/config/github-accounts.json"
  set +e
  FM_TEST_NM_STATUS_FAIL=1 FM_TEST_NM_RUNS_FAIL=1 FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" \
    run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- no-mistakes axi respond accepted >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "transient no-mistakes status failure"
  [ "$(cat "$marker")" = "$marker_before" ] || fail "status failure changed the active no-mistakes binding marker"
  set +e
  FM_TEST_NM_MALFORMED_STATUS=1 FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" \
    run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- no-mistakes axi respond accepted >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "malformed no-mistakes absence status"
  [ "$(cat "$marker")" = "$marker_before" ] || fail "malformed status changed the active no-mistakes binding marker"
  set +e
  FM_TEST_NM_ABSENCE_MODE=partial FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" \
    run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- no-mistakes axi respond accepted >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "partial no-mistakes absence status"
  set +e
  FM_TEST_NM_ABSENCE_MODE=complete FM_TEST_NM_NO_RUNS_STATUS=73 FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" \
    run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- no-mistakes axi respond accepted >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "nonzero no-mistakes absence status"
  FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" \
    run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- no-mistakes axi respond accepted >/dev/null \
    || fail "matching no-mistakes continuation did not revalidate its typed context"
  FM_TEST_NM_QUOTED=1 FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" \
    run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- no-mistakes axi respond accepted >/dev/null \
    || fail "quoted TOON no-mistakes identity was not decoded"
  for status in fixing ci awaiting_approval fix_review; do
    FM_TEST_NM_STATUS=$status FM_TEST_NM_CAPTURE="$captured" FM_TEST_NM_LOG="$log" \
      run_exec "$d" exec --project repo-a --repository "$d/home/projects/repo-a" -- no-mistakes axi respond accepted >/dev/null \
      || fail "documented active no-mistakes status $status was not accepted"
  done
  refresh_count=$(grep -c '^init --github-context ' "$log")
  [ "$refresh_count" -eq 7 ] || fail "strict run and continuations refreshed no-mistakes context $refresh_count times instead of seven times"
  pass "no-mistakes receives secret-free context and revalidates every strict run and continuation"
}

test_secondmate_seed_does_not_leak_project_context() {
  local d secondhome seed_path
  d=$(make_fixture seed-context)
  secondhome="$d/seeded-secondmate"
  seed_path="$d/seed-path"
  mkdir -p "$seed_path"
  ln -s "$REAL_GIT" "$seed_path/git"
  ln -s "$d/exact/no-mistakes" "$seed_path/no-mistakes"
  printf '%s\n' '- repo-a [no-mistakes] +yolo - A (added 2026-07-21)' \
    '- repo-b [direct-PR] +yolo - B (added 2026-07-21)' > "$d/home/data/projects.md"
  FM_HOME="$d/home" FM_SECONDMATE_CHARTER='routing seed context' FM_SECONDMATE_SCOPE='routing seed context' \
    "$ROOT/bin/fm-brief.sh" routing-sm --secondmate repo-a repo-b >/dev/null \
    || fail "could not scaffold strict secondmate seed fixture"
  env -u GH_TOKEN -u GITHUB_TOKEN -u GIT_ASKPASS -u GIT_SSH_COMMAND -u GIT_SSL_NO_VERIFY -u HTTPS_PROXY \
    FM_HOME="$d/home" FM_TEST_FAKE_NETWORK=1 \
    FM_TEST_NO_MISTAKES_CONTEXT="$d/seed-no-mistakes-context.json" \
    FM_TEST_CLONE_SOURCE="$d/home/projects/repo-b" FM_TEST_ROUTE_LOG="$d/routes.log" FM_TEST_SENTINEL="$SENTINEL" \
    FM_TEST_SPOOF_UNSANITIZED_ORIGIN=1 FM_TEST_SPOOF_PATH_PREFIX="$d/home/projects" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.url GIT_CONFIG_VALUE_0=https://github.com/Other/spoofed.git \
    PATH="$seed_path:$PATH" \
    "$ROOT/bin/fm-home-seed.sh" routing-sm "$secondhome" repo-a repo-b >/dev/null \
    || fail "strict secondmate seed leaked its project context into local home creation"
  [ -d "$secondhome/projects/repo-a/.git" ] || fail "strict secondmate seed did not clone its first routed project"
  [ -d "$secondhome/projects/repo-b/.git" ] || fail "strict secondmate seed did not clone the routed project"
  [ "$(git -C "$secondhome/projects/repo-b" remote get-url origin)" = https://github.com/Owner-B/repo-b.git ] \
    || fail "strict secondmate seed did not preserve the routed origin"
  pass "secondmate seed scopes strict activation to routed validation and clone subprocesses"
}

test_legacy_absence_is_byte_compatible
test_operation_schema_is_shared
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
