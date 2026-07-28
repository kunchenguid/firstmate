#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-merge-guard)
POLICY="$ROOT/bin/fm-worker-command-policy.mjs"
CHECKER="$ROOT/bin/fm-worker-pretool-check.sh"
INSTALLER="$ROOT/bin/fm-worker-guard-install.sh"

policy_is() {
  local expected=$1 command=$2 actual
  actual=$(node "$POLICY" --command "$command" 2>&1) || fail "policy crashed for: $command"
  case "$actual" in "$expected"*) : ;; *) fail "policy expected $expected for '$command', got: $actual" ;; esac
}

test_semantic_command_matrix() {
  local command
  while IFS= read -r command; do
    policy_is deny "$command"
  done <<'EOF'
gh pr merge 792 --squash
gh-axi pr merge 792
/usr/local/bin/gh pr merge 792
command gh pr merge 792
env TOKEN=x gh pr merge 792
bash -lc 'gh pr merge 792'
eval 'gh pr merge 792'
(gh pr merge 792)
echo $(gh pr merge 792)
alias land='gh pr merge'; land 792
GH=/usr/bin/gh; "$GH" pr merge 792
gh api PUT /repos/acme/api/pulls/792/merge
gh api graphql -f query='mutation { mergePullRequest(input: {}) }'
EOF
  while IFS= read -r command; do
    policy_is allow "$command"
  done <<'EOF'
gh pr create --title merge
gh pr view 792 --comments
gh pr checks 792
gh pr review 792 --comment
gh api GET /repos/acme/api/pulls/792
printf '%s\n' 'gh pr merge 792'
bash -lc "printf '%s\n' 'gh pr merge 792'"
git push origin fm/fix
EOF
  pass "worker merge guard: semantic policy denies merge execution without blocking PR work or data"
}

make_fake_tools() {
  local base=$1 fakebin
  fakebin=$(fm_fakebin "$base")
  cat > "$fakebin/gh" <<EOF
#!/usr/bin/env bash
[ "\$*" != 'alias list' ] || exit 0
printf 'gh %s\n' "\$*" >> '$base/github-requests'
EOF
  cat > "$fakebin/gh-axi" <<EOF
#!/usr/bin/env bash
printf 'gh-axi %s\n' "\$*" >> '$base/github-requests'
case "\$*" in
  *'--json reviews'*) printf '%s\n' '{"reviews":[{"state":"COMMENTED"}]}' ;;
  *'/pulls/792/threads'*) printf '%s\n' '{"threads":[{"isResolved":false}]}' ;;
esac
EOF
  chmod +x "$fakebin/gh" "$fakebin/gh-axi"
  printf '%s\n' "$fakebin"
}

install_fixture() {
  local base=$1 harness=$2 fakebin=$3
  mkdir -p "$base/home/state" "$base/tasktmp"
  fm_git_init_commit "$base/work"
  PATH="$fakebin:$PATH" HOME="$base/home" "$INSTALLER" "$harness" "$base/work" \
    "$base/home/state" guard-task "$base/tasktmp" "$base/home/state/guard-task.turn-ended"
}

test_harness_installation_and_safe_refusal() {
  local harness base fakebin guardbin output rc
  for harness in claude codex opencode pi pi-signed grok; do
    base="$TMP_ROOT/install-$harness"
    fakebin=$(make_fake_tools "$base")
    guardbin=$(install_fixture "$base" "$harness" "$fakebin") || fail "$harness guard installation failed"
    [ -x "$guardbin/gh" ] || fail "$harness did not receive a gh PATH guard"
    [ -f "$base/work/.fm-worker-guard" ] || fail "$harness did not receive a private worker registration"
    case "$harness" in
      claude) assert_grep 'fm-worker-pretool-check.sh' "$base/work/.claude/settings.local.json" "Claude PreToolUse hook missing" ;;
      codex) assert_grep 'fm-worker-pretool-check.sh' "$base/work/.codex/hooks.json" "Codex PreToolUse hook missing" ;;
      opencode) assert_grep 'tool.execute.before' "$base/work/.opencode/plugins/fm-worker-pretool-check.js" "OpenCode pretool plugin missing" ;;
      pi|pi-signed) assert_grep 'tool_call' "$base/home/state/guard-task.worker-guard.pi-ext.ts" "Pi tool_call guard missing" ;;
      grok) assert_grep 'PreToolUse' "$base/home/.grok/hooks/fm-worker-pretool-check.json" "Grok PreToolUse hook missing" ;;
    esac
  done

  for harness in kimi raw-unverified; do
    base="$TMP_ROOT/refuse-$harness"
    fakebin=$(make_fake_tools "$base")
    mkdir -p "$base/home/state" "$base/tasktmp"
    fm_git_init_commit "$base/work"
    set +e
    output=$(PATH="$fakebin:$PATH" HOME="$base/home" "$INSTALLER" "$harness" "$base/work" \
      "$base/home/state" guard-task "$base/tasktmp" "$base/home/state/guard-task.turn-ended" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$harness launched without deterministic enforcement"
    assert_contains "$output" "refusing" "$harness refusal was not actionable"
    [ ! -e "$base/work/.fm-worker-guard" ] || fail "$harness refusal left a worker registration"
  done

  base="$TMP_ROOT/refuse-merge-alias"
  fakebin=$(make_fake_tools "$base")
  cat > "$fakebin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = 'alias list' ]; then printf '%s\n' 'land: pr merge'; exit 0; fi
exit 0
EOF
  chmod +x "$fakebin/gh"
  mkdir -p "$base/home/state" "$base/tasktmp"
  fm_git_init_commit "$base/work"
  set +e
  output=$(PATH="$fakebin:$PATH" HOME="$base/home" "$INSTALLER" pi "$base/work" \
    "$base/home/state" guard-task "$base/tasktmp" "$base/home/state/guard-task.turn-ended" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "spawn accepted a pre-existing gh merge alias"
  assert_contains "$output" "existing gh alias can merge" "merge-alias refusal was not actionable"
  [ ! -e "$base/work/.fm-worker-guard" ] || fail "merge-alias refusal left a registration"
  pass "worker merge guard: every verified worker harness enforces or refuses before launch"
}

test_registered_transport_and_path_wrapper() {
  local base fakebin guardbin before output rc primary_resolution worker_resolution
  base="$TMP_ROOT/transport"
  fakebin=$(make_fake_tools "$base")
  guardbin=$(install_fixture "$base" pi "$fakebin") || fail "Pi fixture installation failed"

  "$guardbin/gh" pr create --title fix
  "$guardbin/gh-axi" pr view 792
  before=$(wc -l < "$base/github-requests" | tr -d ' ')
  set +e
  output=$("$guardbin/gh" pr merge 792 --squash 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "PATH wrapper allowed gh pr merge"
  assert_contains "$output" "worker-pr-merge" "PATH denial lacked stable reason"
  [ "$(wc -l < "$base/github-requests" | tr -d ' ')" = "$before" ] || fail "denied merge reached the fake GitHub CLI"
  if "$guardbin/gh" alias set land 'pr merge' >/dev/null 2>&1; then
    fail "PATH wrapper allowed creation of a merge alias"
  fi
  [ "$(wc -l < "$base/github-requests" | tr -d ' ')" = "$before" ] || fail "denied merge alias reached the fake GitHub CLI"

  set +e
  output=$(printf '%s' '{"toolInput":{"command":"/opt/bin/gh pr merge 792"}}' \
    | "$CHECKER" --workspace "$base/work" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "registered PreToolUse transport allowed an absolute merge"
  assert_contains "$output" "worker-pr-merge" "PreToolUse denial lacked stable reason"
  "$CHECKER" --workspace "$base/work" --command 'gh pr checks 792' || fail "guard blocked an allowed check command"

  primary_resolution=$(PATH="$fakebin:$PATH" command -v gh-axi)
  worker_resolution=$(PATH="$guardbin:$fakebin:$PATH" command -v gh-axi)
  [ "$primary_resolution" = "$fakebin/gh-axi" ] || fail "the Firstmate environment was unexpectedly prefixed"
  [ "$worker_resolution" = "$guardbin/gh-axi" ] || fail "the worker environment did not resolve the guard wrapper first"
  "$fakebin/gh" pr merge 792 --squash
  [ "$(wc -l < "$base/github-requests" | tr -d ' ')" -eq $((before + 1)) ] \
    || fail "the unprefixed Firstmate environment could not execute its own approved merge path"
  pass "worker merge guard: denial precedes GitHub while the Firstmate environment stays functional"
}

test_unpublished_installation_cleanup() {
  local base fakebin guardbin token
  base="$TMP_ROOT/remove"
  fakebin=$(make_fake_tools "$base")
  guardbin=$(install_fixture "$base" pi "$fakebin") || fail "cleanup fixture installation failed"
  token=$(cat "$base/home/state/guard-task.worker-guard-token")
  "$INSTALLER" --remove "$base/work" "$base/home/state" guard-task \
    || fail "registered guard cleanup failed"
  [ ! -e "$base/work/.fm-worker-guard" ] || fail "cleanup left the workspace registration"
  [ ! -e "$base/home/state/.worker-guard.d/$token" ] || fail "cleanup left the private auth binding"
  [ ! -e "$base/home/state/guard-task.worker-guard.pi-ext.ts" ] || fail "cleanup left the Pi extension"
  [ -d "$guardbin" ] || fail "guard cleanup unexpectedly removed the caller-owned task temp root"
  pass "worker merge guard: unpublished installations clean up only their registered guard artifacts"
}

test_green_review_lifecycle_stops_without_merge() {
  local base fakebin guardbin reviews threads before output rc status_file
  base="$TMP_ROOT/review-lifecycle"
  fakebin=$(make_fake_tools "$base")
  guardbin=$(install_fixture "$base" codex "$fakebin") || fail "review lifecycle guard installation failed"

  reviews=$("$guardbin/gh-axi" pr view 792 --json reviews)
  threads=$("$guardbin/gh-axi" api GET /repos/acme/api/pulls/792/threads)
  assert_contains "$reviews" 'COMMENTED' "fake lifecycle did not surface the late review submission"
  assert_contains "$threads" 'isResolved' "fake lifecycle did not surface the inline thread"
  before=$(wc -l < "$base/github-requests" | tr -d ' ')
  set +e
  output=$("$guardbin/gh-axi" pr merge 792 --squash 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "green lifecycle merged after review comments"
  assert_contains "$output" 'worker-pr-merge' "green lifecycle merge refusal lacked the stable reason"
  [ "$(wc -l < "$base/github-requests" | tr -d ' ')" = "$before" ] \
    || fail "green lifecycle merge reached the fake GitHub CLI"
  status_file="$base/status"
  printf '%s\n' 'done: PR https://github.com/acme/api/pull/792 checks green' > "$status_file"
  assert_grep 'done: PR https://github.com/acme/api/pull/792 checks green' "$status_file" \
    "green lifecycle did not stop with the full PR URL"
  pass "worker merge guard: green CI plus COMMENTED and inline-thread events returns the full URL without merging"
}

test_production_spawn_is_backend_independent() {
  local calls
  # shellcheck disable=SC2016  # the production source expression is matched literally
  calls=$(grep -Fc 'WORKER_GUARD_BIN=$("$SCRIPT_DIR/fm-worker-guard-install.sh"' "$ROOT/bin/fm-spawn.sh")
  [ "$calls" -eq 1 ] || fail "fm-spawn must have one central worker guard installation point"
  [ "$(grep -Fc 'fm-worker-guard-install.sh" --preflight' "$ROOT/bin/fm-spawn.sh")" -eq 1 ] \
    || fail "fm-spawn must preflight the guard once before endpoint creation"
  assert_no_grep 'BACKEND' "$INSTALLER" "worker guard installer must not vary by runtime backend"
  assert_grep '__PIWORKERGUARD__' "$ROOT/bin/fm-spawn.sh" "Pi production launch lost its explicit guard extension"
  assert_grep 'export PATH=' "$ROOT/bin/fm-spawn.sh" "production launch lost the worker-only PATH guard"
  pass "worker merge guard: the central production spawn path is backend-independent"
}

test_semantic_command_matrix
test_harness_installation_and_safe_refusal
test_registered_transport_and_path_wrapper
test_unpublished_installation_cleanup
test_green_review_lifecycle_stops_without_merge
test_production_spawn_is_backend_independent
