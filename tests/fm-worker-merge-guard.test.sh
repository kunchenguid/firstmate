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
gh pr --repo acme/api merge 792 --squash
gh-axi pr --repo acme/api merge 792
gh pr -R acme/api merge 792
gh --repo acme/api pr merge 792
bash -lc 'gh pr --repo acme/api merge 792'
gh alias set land 'pr merge'
gh-axi alias set land 'pr merge'
/usr/local/bin/gh alias set land 'pr merge'
gh alias set land 'pr --repo acme/api merge'
gh alias set land --shell 'gh pr merge $1'
gh alias set land 'api PUT /repos/acme/api/pulls/792/merge --silent'
gh alias set land 'api graphql -f query=mutation{mergePullRequest(input:{})}'
gh alias import -
gh alias import merges.yml
gh-axi alias import -
/usr/local/bin/gh alias import -
printf 'land: pr merge\n' | gh alias import -
bash -lc 'gh alias import merges.yml'
EOF
  while IFS= read -r command; do
    policy_is allow "$command"
  done <<'EOF'
gh pr create --title merge
gh pr view 792 --comments
gh pr checks 792
gh pr review 792 --comment
gh pr --repo acme/api view 792
gh pr -R acme/api create --title merge-fix
gh pr revert 792
gh pr revert 792 --body merge
gh alias set prs 'pr list'
gh alias set co 'pr checkout'
gh alias list
gh alias delete land
gh alias --help
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

run_installer() {
  local base=$1 harness=$2 fakebin=$3
  shift 3
  PATH="$fakebin:$PATH" HOME="$base/home" GROK_HOME="${1-}" "$INSTALLER" "$harness" "$base/work" \
    "$base/home/state" guard-task "$base/tasktmp" "$base/home/state/guard-task.turn-ended"
}

install_fixture() {
  local base=$1 harness=$2 fakebin=$3
  mkdir -p "$base/home/state" "$base/tasktmp"
  fm_git_init_commit "$base/work"
  run_installer "$base" "$harness" "$fakebin"
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

# Installation refuses rather than overwriting a workspace .codex/hooks.json that
# does not already register this guard, so Firstmate's own tracked hooks are
# load-bearing: dropping the worker entry would make every Codex worker spawned on
# a firstmate-repo worktree refuse to launch. Assert through the real installer so
# this stays a launch fact rather than a copy of the installer's acceptance clause.
test_tracked_codex_hooks_admit_a_codex_worker() {
  local base fakebin settings
  settings="$ROOT/.codex/hooks.json"
  [ -f "$settings" ] || fail "tracked .codex/hooks.json is missing"
  base="$TMP_ROOT/tracked-codex-hooks"
  fakebin=$(make_fake_tools "$base")
  mkdir -p "$base/home/state" "$base/tasktmp"
  fm_git_init_commit "$base/work"
  mkdir -p "$base/work/.codex"
  cp "$settings" "$base/work/.codex/hooks.json"
  run_installer "$base" codex "$fakebin" >/dev/null \
    || fail "tracked .codex/hooks.json no longer registers the worker merge guard, so every Codex worker on a firstmate-repo worktree refuses to launch"
  cmp -s "$settings" "$base/work/.codex/hooks.json" \
    || fail "worker guard installation rewrote a project-owned .codex/hooks.json instead of accepting it"
  jq -e '[.hooks.PreToolUse[]?.hooks[]?.command? | select(type == "string" and (contains("fm-arm-pretool-check.sh") or contains("fm-cd-pretool-check.sh")))] | length == 2' \
    "$settings" >/dev/null \
    || fail "the tracked worker merge-guard entry must sit alongside the arm and cd guards, not displace them"
  pass "worker merge guard: the tracked .codex/hooks.json admits a Codex worker alongside the arm and cd guards"
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

  assert_grep 'fm-worker-github.sh' "$guardbin/gh" "the generated launcher does not exec the worker GitHub wrapper"
  set +e
  output=$("$guardbin/gh" pr --repo acme/api merge 792 --squash 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "PATH wrapper allowed a flag-interspersed gh pr merge"
  assert_contains "$output" "worker-pr-merge" "flag-interspersed PATH denial lacked stable reason"
  if "$guardbin/gh" alias set land 'pr --repo acme/api merge' >/dev/null 2>&1; then
    fail "PATH wrapper allowed creation of a flag-interspersed merge alias"
  fi
  [ "$(wc -l < "$base/github-requests" | tr -d ' ')" = "$before" ] \
    || fail "a flag-interspersed merge reached the fake GitHub CLI"

  set +e
  output=$(printf 'land: pr merge\n' | "$guardbin/gh" alias import - 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "PATH wrapper allowed a stdin alias import"
  assert_contains "$output" "worker-pr-merge" "alias-import PATH denial lacked stable reason"
  if "$guardbin/gh" alias import merges.yml >/dev/null 2>&1; then
    fail "PATH wrapper allowed a file alias import"
  fi
  if "$guardbin/gh-axi" alias import - >/dev/null 2>&1; then
    fail "PATH wrapper allowed a gh-axi alias import"
  fi
  [ "$(wc -l < "$base/github-requests" | tr -d ' ')" = "$before" ] \
    || fail "a denied alias import reached the fake GitHub CLI"
  "$guardbin/gh" alias list >/dev/null || fail "PATH wrapper blocked reading existing aliases"

  "$guardbin/gh" pr --repo acme/api view 792 >/dev/null || fail "PATH wrapper blocked a flag-interspersed PR read"
  [ "$(wc -l < "$base/github-requests" | tr -d ' ')" -eq $((before + 1)) ] \
    || fail "an allowed flag-interspersed PR read did not reach the real CLI"
  before=$((before + 1))

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

test_both_enforcement_layers_classify_identically() {
  local base fakebin real
  base="$TMP_ROOT/layer-parity"
  mkdir -p "$base"
  fakebin=$(fm_fakebin "$base")
  fm_fake_exit0 "$fakebin" real-gh
  real="$fakebin/real-gh"

  layers_agree() {
    local expected=$1 command=gh arg quoted policy wrapper
    shift
    for arg in "$@"; do
      quoted=$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")
      command="$command '$quoted'"
    done
    policy=$(node "$POLICY" --command "$command" 2>&1 | cut -f1) \
      || fail "policy crashed for: $command"
    if "$ROOT/bin/fm-worker-github.sh" --tool gh --real "$real" -- "$@" >/dev/null 2>&1; then
      wrapper=allow
    else
      wrapper=deny
    fi
    [ "$policy" = "$expected" ] || fail "semantic policy expected $expected for '$command', got $policy"
    [ "$wrapper" = "$expected" ] || fail "PATH wrapper expected $expected for '$command', got $wrapper"
  }

  layers_agree deny pr merge 792
  layers_agree deny pr --repo acme/api merge 792 --squash
  layers_agree deny alias set land 'pr merge'
  layers_agree deny alias set land 'pr --repo acme/api merge'
  # shellcheck disable=SC2016  # the gh alias body is passed through unexpanded
  layers_agree deny alias set land --shell 'gh pr merge $1'
  layers_agree deny alias set land 'api PUT /repos/acme/api/pulls/792/merge --silent'
  layers_agree deny api PUT /repos/acme/api/pulls/792/merge
  layers_agree deny alias import -
  layers_agree deny alias import merges.yml
  layers_agree allow pr revert 792
  layers_agree allow pr --repo acme/api view 792
  layers_agree allow pr create --title merge
  layers_agree allow alias set prs 'pr list'
  layers_agree allow alias list
  layers_agree allow alias delete land
  pass "worker merge guard: the semantic policy and the PATH wrapper classify identically"
}

test_pr_subcommand_lists_stay_in_sync() {
  local policy_list wrapper_list
  policy_list=$(sed -n '/^const PR_SUBCOMMANDS/,/^]);/p' "$POLICY" \
    | grep -oE '"[a-z][a-z-]*"' | tr -d '"' | LC_ALL=C sort)
  wrapper_list=$(grep -oE '^ *checkout\|[a-z|-]*\)' "$ROOT/bin/fm-worker-github.sh" \
    | tr -d ' )' | tr '|' '\n' | LC_ALL=C sort)
  [ -n "$policy_list" ] || fail "the semantic policy no longer exposes a readable PR_SUBCOMMANDS list"
  [ -n "$wrapper_list" ] || fail "fm-worker-github.sh no longer exposes a readable pr subcommand list"
  [ "$policy_list" = "$wrapper_list" ] \
    || fail "the pr subcommand lists drifted between the two enforcement layers"$'\n'"policy: $policy_list"$'\n'"wrapper: $wrapper_list"
  case "$policy_list" in
    *revert*) : ;;
    *) fail "the real gh pr revert subcommand is missing, so revert work is denied" ;;
  esac
  case "$policy_list" in
    *merge*) fail "merge must never be listed as a subcommand that stops the scan" ;;
  esac
  pass "worker merge guard: both layers share one gh pr subcommand list that excludes merge"
}

test_grok_hook_follows_grok_home() {
  local base fakebin grok_home
  base="$TMP_ROOT/grok-home"
  fakebin=$(make_fake_tools "$base")
  grok_home="$base/relocated-grok"
  mkdir -p "$base/home/state" "$base/tasktmp"
  fm_git_init_commit "$base/work"
  run_installer "$base" grok "$fakebin" "$grok_home" >/dev/null \
    || fail "grok guard installation under GROK_HOME failed"
  [ -x "$grok_home/hooks/fm-worker-pretool-check.sh" ] \
    || fail "the grok merge-denial hook was not installed under GROK_HOME"
  assert_grep "$grok_home/hooks/fm-worker-pretool-check.sh" \
    "$grok_home/hooks/fm-worker-pretool-check.json" \
    "the grok hook registration does not invoke the GROK_HOME hook script"
  [ ! -e "$base/home/.grok/hooks/fm-worker-pretool-check.json" ] \
    || fail "the grok hook was written where a relocated GROK_HOME never loads it"
  pass "worker merge guard: the grok hook is installed where a relocated GROK_HOME loads it"
}

test_checker_binding_survives_a_symlinked_firstmate_path() {
  local base fakebin linkbin output rc
  base="$TMP_ROOT/symlinked-root"
  fakebin=$(make_fake_tools "$base")
  mkdir -p "$base/home/state" "$base/tasktmp"
  fm_git_init_commit "$base/work"
  linkbin="$base/link-bin"
  ln -s "$ROOT/bin" "$linkbin"
  PATH="$fakebin:$PATH" HOME="$base/home" GROK_HOME='' "$linkbin/fm-worker-guard-install.sh" pi \
    "$base/work" "$base/home/state" guard-task "$base/tasktmp" \
    "$base/home/state/guard-task.turn-ended" >/dev/null \
    || fail "guard installation through a symlinked firstmate path failed"
  "$CHECKER" --workspace "$base/work" --command 'gh pr checks 792' \
    || fail "a symlinked firstmate path left the worker guard unavailable for ordinary commands"
  set +e
  output=$("$CHECKER" --workspace "$base/work" --command 'gh pr merge 792' 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a symlinked firstmate path stopped denying merges"
  assert_contains "$output" "worker-pr-merge" "symlinked-path denial lacked the stable reason"
  pass "worker merge guard: the checker binding survives a symlinked firstmate path"
}

test_teardown_leaves_no_guard_residue() {
  local base fakebin guardbin token
  base="$TMP_ROOT/teardown"
  fakebin=$(make_fake_tools "$base")
  fm_fake_exit0 "$fakebin" treehouse tmux
  mkdir -p "$base/home/state" "$base/config" "$base/tasktmp"

  # A pool worktree is reused by the next task, so a task that ends must not
  # leave its own guard registration (or its private auth binding) behind.
  git init -q --bare "$base/origin.git"
  git -C "$base/origin.git" symbolic-ref HEAD refs/heads/main
  fm_git_init_commit "$base/seed"
  git -C "$base/seed" push -q "$base/origin.git" HEAD:main
  git clone -q "$base/origin.git" "$base/project"
  git -C "$base/project" worktree add -q -b fm/guard-task "$base/work" main
  touch "$base/home/state/.last-watcher-beat"

  guardbin=$(run_installer "$base" pi "$fakebin") || fail "teardown fixture installation failed"
  token=$(cat "$base/home/state/guard-task.worker-guard-token")
  fm_write_meta "$base/home/state/guard-task.meta" \
    'window=firstmate:fm-guard-task' 'endpoint_task_id=guard-task' \
    "worktree=$base/work" "project=$base/project" \
    'kind=ship' 'mode=local-only' "tasktmp=$base/tasktmp" 'worker_guard=pr-merge-v1'

  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$base/home/state" \
    FM_CONFIG_OVERRIDE="$base/config" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" guard-task --force >/dev/null 2>&1 \
    || fail "teardown of a guarded worker task failed"

  [ ! -e "$base/work/.fm-worker-guard" ] || fail "teardown left the workspace guard registration"
  [ ! -e "$base/home/state/.worker-guard.d/$token" ] || fail "teardown left the private auth binding"
  [ ! -e "$base/home/state/guard-task.worker-guard-token" ] || fail "teardown left the guard token"
  [ ! -e "$base/home/state/guard-task.worker-guard.pi-ext.ts" ] || fail "teardown left the Pi guard extension"
  [ ! -e "$guardbin/gh" ] || fail "teardown left the worker-only PATH wrapper"
  pass "worker merge guard: teardown leaves no guard residue in a reusable worktree or in state"
}

test_respawn_reclaims_only_its_own_registration() {
  local base fakebin guardbin output rc
  base="$TMP_ROOT/respawn"
  fakebin=$(make_fake_tools "$base")
  install_fixture "$base" pi "$fakebin" >/dev/null || fail "first guard installation failed"
  guardbin=$(run_installer "$base" pi "$fakebin") \
    || fail "a recovery respawn could not reclaim its own registration"
  [ -x "$guardbin/gh" ] || fail "the reclaimed installation did not rebuild the PATH guard"
  [ -f "$base/work/.fm-worker-guard" ] || fail "the reclaimed installation left no registration"
  "$CHECKER" --workspace "$base/work" --command 'gh pr checks 792' \
    || fail "the reclaimed registration is not usable"

  printf '%s\n' 'fm.zzzzzzzzzzzz' > "$base/home/state/guard-task.worker-guard-token"
  set +e
  output=$(run_installer "$base" pi "$fakebin" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "installation overwrote a registration it could not prove it owns"
  assert_contains "$output" "ambiguous" "unowned-registration refusal was not actionable"
  pass "worker merge guard: respawn reclaims its own registration and refuses any other"
}

test_semantic_command_matrix
test_harness_installation_and_safe_refusal
test_tracked_codex_hooks_admit_a_codex_worker
test_registered_transport_and_path_wrapper
test_unpublished_installation_cleanup
test_green_review_lifecycle_stops_without_merge
test_both_enforcement_layers_classify_identically
test_pr_subcommand_lists_stay_in_sync
test_grok_hook_follows_grok_home
test_checker_binding_survives_a_symlinked_firstmate_path
test_teardown_leaves_no_guard_residue
test_respawn_reclaims_only_its_own_registration
test_production_spawn_is_backend_independent
