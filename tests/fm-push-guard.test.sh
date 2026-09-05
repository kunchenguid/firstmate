#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the push-guard PreToolUse seatbelt (docs/push-guard.md).
#
# bin/fm-push-guard-command-policy.mjs is the single owner of the block/allow
# decision for everything text alone can settle; it reuses the shell classifier
# owned by bin/fm-arm-command-policy.mjs. bin/fm-push-guard-pretool-check.sh is
# the stable transport: it drives the Claude and Codex entry forms and is the
# only place that queries real repository state (for the one case text cannot
# settle - a bare push). This suite proves the full refspec decision matrix
# from docs/push-guard.md, the owner-marker exemption, the bare-push branch
# check (both outcomes and the fail-open cases), recursion into subshells,
# substitutions, eval, and sh -c payloads, the fail-open transport behavior,
# the prefilter fast path, the policy CLI output contract, and shellcheck
# cleanliness. No harness is spawned.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-push-guard)

install_push_guard_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-push-guard-pretool-check.sh" "$dir/bin/fm-push-guard-pretool-check.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-push-guard-command-policy.mjs" "$dir/bin/fm-push-guard-command-policy.mjs"
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-arm-command-policy.mjs"
  chmod +x "$dir/bin/fm-push-guard-pretool-check.sh" "$dir/bin/fm-push-guard-command-policy.mjs"
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-push-guard-work.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$WORK")
install_push_guard_scripts "$WORK"
CHECK="$WORK/bin/fm-push-guard-pretool-check.sh"

# --- full cross-harness acceptance matrix (textual, no repository needed) --

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_COMMANDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_COMMANDS+=("$3")
}

# BLOCK: an explicit git push whose refspec targets main or master.
matrix_case B01 deny 'git push origin main'
matrix_case B02 deny 'git push origin HEAD:main'
matrix_case B03 deny 'git push -u origin main'
matrix_case B04 deny 'git push origin +main'
matrix_case B05 deny 'git push origin refs/heads/main'
matrix_case B06 deny 'git push origin HEAD:refs/heads/main'
matrix_case B07 deny 'git push origin master'
matrix_case B08 deny 'git push --all origin'
matrix_case B09 deny 'git push --mirror origin'
matrix_case B10 deny 'git -C projects/xau push origin main'
matrix_case B11 deny 'git --no-pager push origin main'
matrix_case B12 deny 'echo setup && git push origin main'
matrix_case B13 deny 'git push origin main; echo done'
matrix_case B14 deny 'git push origin main | cat'
matrix_case B15 deny 'git push origin main &'
matrix_case B16 deny '(cd projects/xau && git push origin main)'
matrix_case B17 deny '{ git push origin main; }'
matrix_case B18 deny 'x=$(git push origin main)'
matrix_case B19 deny 'sh -c "git push origin main"'
matrix_case B20 deny 'eval "git push origin main"'
matrix_case B21 deny 'git push origin feature:main'

# ALLOW: not a push to main/master, or exempted by the owner marker.
matrix_case A01 allow 'git status'
matrix_case A02 allow 'git checkout main'
matrix_case A03 allow 'git push origin feature-x'
matrix_case A04 allow 'git push origin dev'
matrix_case A05 allow 'git push origin :main'
matrix_case A06 allow 'echo "git push origin main"'
matrix_case A07 allow 'FM_PUSH_GUARD_OWNER=fm-pr-merge git push origin main'
matrix_case A08 allow 'FM_PUSH_GUARD_OWNER=fm-merge-local git push origin main'
matrix_case A09 allow 'git push origin main2'
matrix_case A10 allow 'git push origin mainline'
matrix_case A11 allow 'git log --grep push'

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-push-guard-matrix.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")

run_matrix_entry() {
  local id=$1 expected=$2 entry=$3 cmd=$4 payload out_file err_file rc
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"

  case "$entry" in
    codex)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    claude)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --claude >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry"
      ;;
  esac

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("\\["))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry a reason code on stderr: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  else
    jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
      || fail "$id via $entry deny must carry decision=deny on stdout: $(cat "$out_file")"
  fi
}

test_full_acceptance_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in codex claude; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
  done
  pass "push-guard acceptance matrix: ${#MATRIX_IDS[@]} cases x 2 harness entry forms, block/allow all correct"
}

test_unclassifiable_push_fails_closed() {
  local out rc
  out=$("$CHECK" --command 'git push "unterminated' 2>&1); rc=$?
  expect_code 2 "$rc" "unparseable syntax mentioning git and push must deny"
  assert_contains "$out" '[unclassifiable-push]' "unclassifiable deny must carry the reason code"
  pass "push-guard: fails closed on unparseable syntax that mentions git and push"
}

test_unrelated_malformed_syntax_allows() {
  local out rc
  out=$("$CHECK" --command 'echo unterminated push "quote' 2>&1); rc=$?
  expect_code 0 "$rc" "unparseable syntax with no git mention must allow"
  [ -z "$out" ] || fail "unrelated malformed syntax produced output: $out"
  pass "push-guard: allows unparseable syntax that never mentions git"
}

test_command_flag_direct() {
  local out rc
  out=$("$CHECK" --command 'git push origin main' 2>&1); rc=$?
  expect_code 2 "$rc" "--command must deny an explicit main push"
  assert_contains "$out" '[protected-branch-push]' "deny must carry the protected-branch-push reason code"
  pass "push-guard: --command direct entry denies an explicit main push"
}

# --- the one case text cannot settle: a bare push --------------------------

make_repo_on_branch() {
  local dir=$1 branch=$2
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" branch -q -m "$branch" 2>/dev/null || git -C "$dir" checkout -q -b "$branch"
  printf '%s\n' "$dir"
}

test_bare_push_denied_on_main() {
  local dir out rc
  dir=$(make_repo_on_branch "$TMP_ROOT/bare-main" main)
  out=$(cd "$dir" && "$CHECK" --claude --command 'git push' 2>&1); rc=$?
  expect_code 2 "$rc" "bare git push while on main must deny"
  assert_contains "$out" '[protected-branch-push]' "bare-push-on-main deny must carry the reason code"
  pass "push-guard: bare git push denies when the current branch is main"
}

test_bare_push_denied_on_master() {
  local dir out rc
  dir=$(make_repo_on_branch "$TMP_ROOT/bare-master" master)
  out=$(cd "$dir" && "$CHECK" --claude --command 'git push --force-with-lease' 2>&1); rc=$?
  expect_code 2 "$rc" "bare git push --force-with-lease while on master must deny"
  assert_contains "$out" '[protected-branch-push]' "bare-push-on-master deny must carry the reason code"
  pass "push-guard: git push --force-with-lease denies when the current branch is master"
}

test_bare_push_allowed_on_feature_branch() {
  local dir out rc
  dir=$(make_repo_on_branch "$TMP_ROOT/bare-feature" feature-x)
  out=$(cd "$dir" && "$CHECK" --claude --command 'git push' 2>&1); rc=$?
  expect_code 0 "$rc" "bare git push on a feature branch must allow"
  [ -z "$out" ] || fail "bare push on a feature branch produced output: $out"
  pass "push-guard: bare git push allows when the current branch is not main/master"
}

test_bare_push_dash_c_uses_named_directory() {
  local dir out rc
  dir=$(make_repo_on_branch "$TMP_ROOT/bare-dashc" main)
  out=$(cd "$TMP_ROOT" && "$CHECK" --claude --command "git -C $dir push origin" 2>&1); rc=$?
  expect_code 2 "$rc" "a repository-only push naming main via -C must deny"
  assert_contains "$out" '[protected-branch-push]' "the -C-resolved deny must carry the reason code"
  pass "push-guard: git -C <dir> push origin resolves the branch check to that directory"
}

test_bare_push_allows_when_not_a_git_repo() {
  local dir out rc
  dir="$TMP_ROOT/not-a-repo"
  mkdir -p "$dir"
  out=$(cd "$dir" && "$CHECK" --claude --command 'git push' 2>&1); rc=$?
  expect_code 0 "$rc" "a bare push outside any git repository must fail open"
  [ -z "$out" ] || fail "bare push outside a repo produced output: $out"
  pass "push-guard: fails open on a bare push when the current branch cannot be determined"
}

# --- fail-open transport behavior ------------------------------------------

test_fail_open_empty_stdin() {
  local out rc
  out=$("$CHECK" < /dev/null 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on empty stdin"
  [ -z "$out" ] || fail "transport produced output on empty stdin: $out"
  pass "push-guard: fails open on empty stdin"
}

test_fail_open_unparseable_json() {
  local out rc
  out=$(printf 'not json at all' | "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on unparseable stdin JSON"
  [ -z "$out" ] || fail "transport produced output on unparseable JSON: $out"
  pass "push-guard: fails open on unparseable stdin JSON"
}

test_fail_open_missing_node() {
  local fakebin tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/nonode")
  for tool in bash sh git dirname cat printf sed tr jq; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  # node deliberately absent from this PATH.
  out=$(PATH="$fakebin" "$CHECK" --command 'git push origin main' 2>&1); rc=$?
  expect_code 0 "$rc" "transport must fail open when node is unavailable"
  [ -z "$out" ] || fail "transport produced output without node: $out"
  pass "push-guard: fails open (never blocks) when node is missing"
}

test_fail_open_missing_jq_on_stdin() {
  local fakebin tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/nojq")
  for tool in bash sh git dirname cat printf sed tr node; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  # jq deliberately absent: the stdin transport cannot extract the command.
  out=$(printf '{"tool_input":{"command":"git push origin main"}}' | PATH="$fakebin" "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "stdin transport must fail open when jq is unavailable"
  [ -z "$out" ] || fail "stdin transport produced output without jq: $out"
  pass "push-guard: fails open on the stdin path when jq is missing"
}

# --- prefilter fast path ----------------------------------------------------

test_prefilter_skips_node_without_push_substring() {
  local fakebin marker tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/prefilter-fake")
  marker="$TMP_ROOT/prefilter-node-called"
  for tool in bash sh git dirname cat printf sed tr jq; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  cat > "$fakebin/node" <<EOF
#!/usr/bin/env bash
: > "$marker"
exit 0
EOF
  chmod +x "$fakebin/node"
  out=$(PATH="$fakebin" "$CHECK" --command 'git status' 2>&1); rc=$?
  expect_code 0 "$rc" "prefilter must fast-allow a command with no push substring"
  [ -z "$out" ] || fail "prefilter fast-allow produced output: $out"
  [ ! -e "$marker" ] || fail "prefilter fast-allow still invoked the node policy owner"
  pass "push-guard: prefilter fast-allows (skips node) when no push substring is present"
}

# --- policy CLI contract ----------------------------------------------------

test_policy_cli_direct() {
  local policy
  policy="$ROOT/bin/fm-push-guard-command-policy.mjs"
  [ "$(node "$policy" --command 'git push origin main' | cut -f1)" = deny ] \
    || fail "policy CLI must deny an explicit main push"
  [ "$(node "$policy" --command 'git push origin feature-x')" = allow ] \
    || fail "policy CLI must allow a non-protected target"
  [ "$(node "$policy" --command 'git push' | cut -f1)" = check-branch ] \
    || fail "policy CLI must return check-branch for a bare push"
  [ "$(node "$policy")" = allow ] \
    || fail "policy CLI must allow when no command is supplied"
  pass "push-guard: fm-push-guard-command-policy.mjs CLI honors the deny/allow/check-branch output contract"
}

# --- per-harness wiring -----------------------------------------------------

test_scripts_are_shellcheck_clean() {
  local out
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  out=$("$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-push-guard-pretool-check.sh" 2>&1) \
    || fail "bin/fm-push-guard-pretool-check.sh is not lint-clean under the pinned definition: $out"
  pass "bin/fm-push-guard-pretool-check.sh is clean under bin/fm-lint.sh"
}

test_registrations_present() {
  jq -e '[.hooks.PreToolUse[]?.hooks[]?.command // empty] | any(contains("fm-push-guard-pretool-check.sh"))' \
    "$ROOT/.claude/settings.json" >/dev/null 2>&1 \
    || fail ".claude/settings.json does not register fm-push-guard-pretool-check.sh"
  jq -e '[.hooks.PreToolUse[]?.hooks[]?.command // empty] | any(contains("fm-push-guard-pretool-check.sh"))' \
    "$ROOT/.codex/hooks.json" >/dev/null 2>&1 \
    || fail ".codex/hooks.json does not register fm-push-guard-pretool-check.sh"
  pass "push-guard: registered in .claude/settings.json and .codex/hooks.json"
}

test_full_acceptance_matrix
test_unclassifiable_push_fails_closed
test_unrelated_malformed_syntax_allows
test_command_flag_direct
test_bare_push_denied_on_main
test_bare_push_denied_on_master
test_bare_push_allowed_on_feature_branch
test_bare_push_dash_c_uses_named_directory
test_bare_push_allows_when_not_a_git_repo
test_fail_open_empty_stdin
test_fail_open_unparseable_json
test_fail_open_missing_node
test_fail_open_missing_jq_on_stdin
test_prefilter_skips_node_without_push_substring
test_policy_cli_direct
test_scripts_are_shellcheck_clean
test_registrations_present
