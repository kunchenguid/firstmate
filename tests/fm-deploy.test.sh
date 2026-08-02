#!/usr/bin/env bash
# Synthetic contract tests for the default-off guarded deployment capability.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DEPLOY="$ROOT/bin/fm-deploy.sh"
TMP_ROOT=$(fm_test_tmproot fm-deploy-tests)

make_case() {
  local name=$1 case_dir project worktree origin source
  case_dir="$TMP_ROOT/$name"
  project="$case_dir/projects/kg-metall"
  worktree="$case_dir/worktree"
  origin="$case_dir/origin.git"
  source="$case_dir/external/kg-metall/staging.key"
  mkdir -p "$project" "$case_dir/state" "$case_dir/data" "$case_dir/config" "$(dirname "$source")"
  git init -q --bare "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git init -q "$project"
  git -C "$project" remote add origin "file://$origin"
  cat > "$project/bin-deploy" <<'SH'
#!/usr/bin/env bash
set -eu
{ [ "$#" -eq 1 ] && [ "$1" = staging ]; } || { [ "$#" -eq 2 ] && [ "$1" = preflight ] && [ "$2" = staging ]; } || exit 19
[ -n "${KG_METALL_RAILS_KEY_PATH:-}" ] || exit 20
[ -n "${KAMAL_SECRETS_PATH:-}" ] || exit 21
[ -z "${RAILS_MASTER_KEY:-}" ] || exit 22
[ -z "${SECRET_KEY_BASE:-}" ] || exit 23
printf '%s\n' "$*" >> .deploy-args
printf '%s\n' "$KG_METALL_RAILS_KEY_PATH" "$KAMAL_SECRETS_PATH" >> .deploy-paths
env | LC_ALL=C sort > .deploy-env
cat "$KG_METALL_RAILS_KEY_PATH"
SH
  chmod +x "$project/bin-deploy"
  mkdir -p "$project/bin"
  mv "$project/bin-deploy" "$project/bin/deploy"
  printf 'fixture\n' > "$project/README.md"
  git -C "$project" add .
  git -C "$project" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
  git -C "$project" branch -M main
  git -C "$project" push -q origin main
  git -C "$project" worktree add -qb feature "$worktree"
  printf '0123456789abcdef0123456789abcdef\n' > "$source"
  chmod 600 "$source"
  printf '%s\n' '- kg-metall - fixture' > "$case_dir/data/projects.md"
  cat > "$case_dir/config/deployment-capabilities.json" <<JSON
{"version":1,"source_roots":{"operator-rails-keys":{"path":"$case_dir/external","owner":"current-user","allow_group_or_world_write":false}},"projects":{"kg-metall":{"origin":{"remote":"origin","url":"file://$origin"},"profiles":{"deploy-staging":{"kind":"rails-kamal-key-file-v1","destination":"staging","source":{"root":"operator-rails-keys","relative_path":"kg-metall/staging.key","owner":"current-user","mode":"0600","links":1},"command":["bin/deploy","staging"],"required_credentials":["secret_key_base"],"destination_manifest":"config/deploy_targets.yml"}}}}}
JSON
  chmod 600 "$case_dir/config/deployment-capabilities.json"
  cat > "$case_dir/state/task.meta" <<META
window=firstmate:fm-task
endpoint_task_id=task
worktree=$worktree
project=$project
harness=pi
kind=ship
mode=no-mistakes
yolo=off
tasktmp=$case_dir/tasktmp
META
  CASE="$case_dir"
  WORKTREE="$worktree"
  SOURCE="$source"
}
run_deploy() {
  FM_HOME="$CASE" FM_STATE_OVERRIDE="$CASE/state" FM_DATA_OVERRIDE="$CASE/data" \
    FM_CONFIG_OVERRIDE="$CASE/config" FM_PROJECTS_OVERRIDE="$CASE/projects" "$DEPLOY" "$@"
}

test_default_off_and_strict_parser() {
  local out rc
  make_case default-off
  rm "$CASE/config/deployment-capabilities.json"
  set +e
  out=$(run_deploy validate-config 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing configuration must disable deployment"
  assert_contains "$out" "not configured" "missing configuration refusal is not clear"
  printf '%s\n' '{"version":1,"version":1,"source_roots":{},"projects":{}}' > "$CASE/config/deployment-capabilities.json"
  chmod 600 "$CASE/config/deployment-capabilities.json"
  set +e
  out=$(run_deploy validate-config 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "duplicate JSON key must be rejected"
  assert_contains "$out" "duplicate" "duplicate-key parser refusal missing"
  pass "deployment capability is default-off and rejects duplicate-key JSON"
}

test_one_shot_redacted_clean_deploy() {
  local grant out rc paths
  make_case one-shot
  grant=$(run_deploy issue task deploy-staging --authority-ref captain-staging-test)
  [ "${#grant}" -eq 32 ] || fail "issue did not produce a 128-bit grant id"
  set +e
  run_deploy issue task deploy-staging --authority-ref captain-staging-test >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "same task and destination must not receive concurrent pending grants"
  out=$(run_deploy run "$grant") || fail "synthetic fixed deployment failed"
  assert_not_contains "$out" "0123456789abcdef0123456789abcdef" "secret canary leaked to deployment output"
  [ "$(wc -l < "$WORKTREE/.deploy-args" | tr -d ' ')" = 2 ] || fail "runner must preflight then run fixed command"
  paths=$(cat "$WORKTREE/.deploy-paths")
  assert_not_contains "$paths" "$SOURCE" "original source path reached child"
  assert_no_grep 'RAILS_MASTER_KEY=' "$WORKTREE/.deploy-env" "secret key entered child environment"
  assert_no_grep 'SECRET_KEY_BASE=' "$WORKTREE/.deploy-env" "secret base entered child environment"
  ! find "$CASE/tasktmp" -type f 2>/dev/null | grep -q . || fail "temporary secret files survived normal cleanup"
  grep -Fq '"result":"completed"' "$CASE/data/deployment-receipts.jsonl" || fail "value-silent completion receipt missing"
  set +e
  run_deploy run "$grant" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "consumed grant must not run twice"
  assert_no_grep '0123456789abcdef0123456789abcdef' "$CASE/data/deployment-receipts.jsonl" "receipt contains canary"
  pass "fixed command is preflighted, redacted, cleaned, and one-shot"
}

test_source_identity_and_destination_separation() {
  local out rc
  make_case source-identity
  rm "$SOURCE"
  ln -s /dev/null "$SOURCE"
  set +e
  out=$(run_deploy deploy task deploy-staging --authority-ref captain-staging-test 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "symlinked external source must be rejected"
  assert_contains "$out" "unsafe component" "source symlink refusal missing"
  [ ! -e "$CASE/tasktmp/deploy-runtime" ] || fail "source refusal created temporary key material"
  pass "external source validation rejects symlinks before child execution"
}

test_orca_task_binding_uses_the_recorded_worktree() {
  local fakebin grant
  make_case orca-binding
  fakebin=$(fm_fakebin "$CASE")
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$1" = worktree ] && [ "$2" = show ] && [ "$3" = --worktree ] && [ "$4" = id:orca-fixture ] && [ "$5" = --json ]
printf '{"ok":true,"result":{"worktree":{"path":"%s"}}}\n' "$FM_ORCA_FIXTURE_PATH"
SH
  chmod +x "$fakebin/orca"
  cat >> "$CASE/state/task.meta" <<META
backend=orca
orca_worktree_id=orca-fixture
META
  grant=$(PATH="$fakebin:$PATH" FM_ORCA_FIXTURE_PATH="$WORKTREE" run_deploy issue task deploy-staging --authority-ref captain-staging-test) || fail "Orca task binding should accept the exact recorded worktree"
  [ "${#grant}" -eq 32 ] || fail "Orca binding did not issue a grant"
  pass "Orca and Treehouse task identity share exact project and worktree binding"
}

test_recovery_cleans_exact_dead_remote_receipt_without_retry() {
  local runtime receipt
  make_case recovery
  runtime="$CASE/tasktmp/deploy-runtime/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  mkdir -p "$runtime"
  chmod 700 "$CASE/tasktmp" "$CASE/tasktmp/deploy-runtime" "$runtime"
  printf '0123456789abcdef0123456789abcdef\n' > "$runtime/rails.key"
  printf 'RAILS_MASTER_KEY=0123456789abcdef0123456789abcdef\n' > "$runtime/secrets.staging"
  chmod 600 "$runtime/rails.key" "$runtime/secrets.staging"
  receipt="$CASE/state/deploy-runtime/task/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json"
  mkdir -p "$(dirname "$receipt")"
  node - "$runtime" "$receipt" <<'JS'
const fs = require('fs');
const [dir, receipt] = process.argv.slice(2);
const identity = file => { const s = fs.lstatSync(file); return { path: file, dev: s.dev, ino: s.ino, uid: s.uid, mode: s.mode & 0o777 }; };
fs.writeFileSync(receipt, JSON.stringify({ version: 1, transaction: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', task_id: 'task', project: 'kg-metall', profile: 'deploy-staging', destination: 'staging', head: 'synthetic', phase: 'remote-started', started_at: '2020-01-01T00:00:00.000Z', directory: dir, rails: identity(`${dir}/rails.key`), secrets: identity(`${dir}/secrets.staging`) }) + '\n');
JS
  chmod 600 "$receipt"
  run_deploy recover task || fail "dead recorded deployment recovery should clean exact local files"
  [ ! -e "$runtime" ] || fail "recovery left exact runtime directory behind"
  grep -Fq '"result":"unknown-after-remote"' "$CASE/data/deployment-receipts.jsonl" || fail "remote recovery must record an unknown outcome"
  pass "recovery cleans only exact dead receipt material and never retries remote work"
}

test_cross_project_and_dirty_worktree_refuse_before_source_read() {
  local out rc
  make_case cross-project
  printf 'dirty\n' >> "$WORKTREE/README.md"
  set +e
  out=$(run_deploy deploy task deploy-staging --authority-ref captain-staging-test 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "dirty worktree must refuse deployment"
  assert_contains "$out" "not clean" "dirty-worktree refusal missing"
  [ ! -e "$CASE/tasktmp/deploy-runtime" ] || fail "dirty-worktree refusal read or staged source"
  pass "task and clean-HEAD binding refuse before source access"
}

run_tests() {
  test_default_off_and_strict_parser
  test_one_shot_redacted_clean_deploy
  test_source_identity_and_destination_separation
  test_orca_task_binding_uses_the_recorded_worktree
  test_recovery_cleans_exact_dead_remote_receipt_without_retry
  test_cross_project_and_dirty_worktree_refuse_before_source_read
}
run_tests
