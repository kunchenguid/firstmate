#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the primary project-write PreToolUse guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-project-write-pretool-check)
SAFE_PATCH="$TMP_ROOT/safe.diff"
PROJECT_PATCH="$TMP_ROOT/project.diff"
printf '%s\n' '--- a/safe.txt' '+++ b/safe.txt' '@@ -1 +1 @@' '-before' '+after' > "$SAFE_PATCH"
printf '%s\n' '--- a/projects/foo/patched.txt' '+++ b/projects/foo/patched.txt' '@@ -1 +1 @@' '-before' '+after' > "$PROJECT_PATCH"

install_guard() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-project-write-pretool-check.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-project-write-command-policy.mjs" "$dir/bin/"
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/"
  chmod +x "$dir/bin/fm-project-write-pretool-check.sh" "$dir/bin/fm-project-write-command-policy.mjs"
}

PRIMARY="$TMP_ROOT/primary"
mkdir -p "$PRIMARY/state" "$PRIMARY/projects/foo"
git init -q "$PRIMARY"
git -C "$PRIMARY" commit -q --allow-empty -m init
: > "$PRIMARY/AGENTS.md"
install_guard "$PRIMARY"
WORKER_COPY="$TMP_ROOT/worker-copy"
mkdir -p "$WORKER_COPY"
printf 'worktree=%s\n' "$WORKER_COPY" > "$PRIMARY/state/example.meta"
CHECK="$PRIMARY/bin/fm-project-write-pretool-check.sh"

run_command() {
  (cd "$PRIMARY" && FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state" "$CHECK" --command "$1")
}

expect_deny() {
  local command=$1 out rc
  out=$(run_command "$command" 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "expected deny for [$command], got exit $rc: $out"
  assert_contains "$out" '[project-write]' "deny must name the project-write guard"
  case "$out" in
    *'read GitHub instead of fetching'*) ;;
    *) assert_contains "$out" 'delegate the change to a worker' "deny must name the allowed alternative" ;;
  esac
}

expect_allow() {
  local command=$1 out rc
  out=$(run_command "$command" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "expected allow for [$command], got exit $rc: $out"
  [ -z "$out" ] || fail "allowed command must be silent: $out"
}

test_git_state_changes_are_denied() {
  local subcommand
  for subcommand in fetch pull commit checkout switch reset restore stash push clean tag 'branch -d old' 'branch -D old' merge rebase am cherry-pick; do
    expect_deny "git -C projects/foo $subcommand"
  done
  expect_deny 'git clone https://example.invalid/repo.git projects/foo'
  expect_deny 'git init projects/foo'
  expect_deny 'GIT_DIR=projects/foo/.git git fetch origin'
  expect_deny 'p=projects/foo; GIT_WORK_TREE="$p" git fetch origin'
  expect_deny 'GIT_WORK_TREE=projects/foo git fetch origin'
  expect_deny 'git --git-dir=projects/foo/.git fetch origin'
  expect_deny 'git --work-tree=projects/foo fetch origin'
  expect_deny 'env GIT_DIR=projects/foo/.git git fetch origin'
  expect_deny 'git init --separate-git-dir=projects/foo/.git /tmp/fm-project-write-separate-dir'
  expect_deny 'git init --separate-git-dir projects/foo/.git /tmp/fm-project-write-separate-dir-2'
  expect_deny 'git archive -o projects/foo/out.tar HEAD'
  expect_deny 'git checkout-index --all --prefix=projects/foo/'
  expect_deny 'git checkout-index --all --prefix projects/foo/'
  expect_deny 'git bundle create projects/foo/x.bundle HEAD'
  expect_deny 'p=projects/foo; git -C "$p" fetch origin'
  expect_deny 'git worktree add projects/foo'
  expect_deny 'git worktree add -b scratch projects/foo'
  expect_deny 'git submodule add https://example.invalid/repo.git projects/foo/module'
  expect_allow 'git worktree list'
  expect_allow 'git -C projects/foo worktree list'
  expect_allow 'git archive -o /tmp/fm-project-write-safe.tar HEAD'
  expect_allow 'git checkout-index --all --prefix=/tmp/fm-project-write-safe/'
  expect_allow 'git bundle create /tmp/fm-project-write-safe.bundle HEAD'
  pass "project-write guard: denies the requested Git state-changing commands"
}

test_git_reads_and_guarded_scripts_are_allowed() {
  local subcommand
  for subcommand in status log diff show rev-parse; do
    expect_allow "git -C projects/foo $subcommand"
  done
  expect_allow 'git status'
  expect_allow 'p=projects/foo; git -C "$p" status'
  expect_allow 'bin/fm-fleet-sync.sh'
  expect_allow 'bin/fm-merge-local.sh'
  expect_allow 'bin/fm-teardown.sh'
  expect_allow 'bin/fm-project-init.sh'
  pass "project-write guard: allows Git reads and guarded firstmate scripts"
}

test_file_mutations_are_denied() {
  expect_deny 'rm -rf projects/foo/file'
  expect_deny 'mv notes.txt projects/foo/file'
  expect_deny 'cp notes.txt projects/foo/file'
  expect_deny 'cp -t projects/foo notes.txt'
  expect_deny 'echo changed > projects/foo/file'
  expect_deny 'printf x &> projects/foo/both-streams'
  expect_deny 'printf x &>> projects/foo/appended-both-streams'
  expect_deny 'printf x >| projects/foo/forced-redirection'
  expect_deny "sed -Ei 's/old/new/' projects/foo/sed-file"
  expect_deny "perl -pi -e 's/old/new/' projects/foo/perl-file"
  expect_deny 'patch projects/foo/file < /tmp/update.diff'
  expect_deny 'patch -d projects/foo < /tmp/update.diff'
  expect_deny "patch -p1 < \"$PROJECT_PATCH\""
  expect_deny "patch -p1 < \"$TMP_ROOT/missing.diff\""
  expect_deny "printf '%s\\n' '--- a/projects/foo/piped.txt' '+++ b/projects/foo/piped.txt' | patch -p1"
  local heredoc_patch
  heredoc_patch=$(printf '%s\n' "patch -p1 <<'PATCH'" '--- a/projects/foo/heredoc.txt' '+++ b/projects/foo/heredoc.txt' '@@ -1 +1 @@' '-before' '+after' 'PATCH')
  expect_deny "$heredoc_patch"
  expect_deny 'dd if=/dev/zero of=projects/foo/file'
  expect_deny 'find projects/foo -delete'
  expect_deny 'find projects/foo -type f -exec rm -f {} +'
  expect_deny 'find projects/foo -type f -execdir rm -f {} +'
  expect_deny 'find projects/foo -type f -exec sh -c "printf x > projects/foo/created" \\;'
  expect_deny 'find /tmp -type f -exec rm -f projects/foo/file \\;'
  expect_deny 'printf x > projects/foo/quoted-name'
  expect_deny 'f=projects/foo/new.txt; printf x > "$f"'
  expect_deny 'export f=projects/foo/exported.txt; printf x > "$f"'
  expect_deny 'f=projects/foo/new.txt; dd if=/dev/zero of="$f"'
  expect_deny 'printf changed | tee projects/foo/file'
  expect_deny "sed -i 's/old/new/' projects/foo/file"
  expect_deny 'touch projects/foo/file'
  expect_deny '(cd projects/foo && git fetch origin)'
  expect_deny "bash -c 'git -C projects/foo fetch origin'"
  expect_deny 'git diff --output=projects/foo/diff.txt'
  expect_allow 'echo changed > /tmp/fm-project-write-safe-file'
  expect_allow 'printf x &> /tmp/fm-project-write-both-streams'
  expect_allow 'printf x &>> /tmp/fm-project-write-appended-both-streams'
  expect_allow 'printf x >| /tmp/fm-project-write-forced-redirection'
  expect_allow "sed -Ei 's/old/new/' /tmp/fm-project-write-sed-safe"
  expect_allow "perl -pi -e 's/old/new/' /tmp/fm-project-write-perl-safe"
  expect_allow 'f=/tmp/fm-project-write-variable-safe; printf x > "$f"'
  expect_allow 'find projects/foo -type f -exec cat {} +'
  expect_allow "patch -i \"$SAFE_PATCH\""
  expect_allow 'patch /tmp/fm-project-write-patch-target'
  expect_allow 'sed -n 1p projects/foo/file'
  pass "project-write guard: blocks file writes while allowing reads and external writes"
}

test_recorded_worker_copy_is_guarded() {
  expect_deny "git -C $WORKER_COPY fetch origin"
  expect_deny "printf changed > $WORKER_COPY/file"
  expect_allow "git -C $WORKER_COPY status"
  pass "project-write guard: applies to worktrees recorded in task metadata"
}

test_shell_payload_parity() {
  local payload out rc
  for payload in \
    '{"tool_name":"Bash","tool_input":{"command":"git -C projects/foo fetch origin"}}' \
    '{"toolName":"run_terminal_command","toolInput":{"command":"git -C projects/foo fetch origin"}}' \
    '{"tool_name":"Shell","tool_input":{"command":"git -C projects/foo fetch origin"}}' \
    '{"tool_name":"bash","tool_input":{"command":"git -C projects/foo fetch origin"}}'; do
    out=$(printf '%s' "$payload" | (cd "$PRIMARY" && FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state" "$CHECK") 2>&1); rc=$?
    [ "$rc" -eq 2 ] || fail "expected shell payload deny, got exit $rc: $out"
    assert_contains "$out" '[project-write]' "shell payload deny must name the guard"
  done
  payload='{"tool_name":"Bash","tool_input":{"command":"git -C projects/foo fetch origin"}}'
  out=$(printf '%s' "$payload" | (cd "$PRIMARY" && FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state" "$CHECK" --claude) 2>/dev/null); rc=$?
  [ "$rc" -eq 2 ] && [ -z "$out" ] || fail "Claude-shaped deny must keep stdout empty"
  out=$(printf '%s' "$payload" | (cd "$PRIMARY" && FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state" "$CHECK" --cursor) 2>&1); rc=$?
  if [ "$rc" -ne 0 ] || ! jq -e '.permission == "deny"' <<<"$out" >/dev/null; then
    fail "Cursor-shaped deny must return its decision object: $out"
  fi
  pass "project-write guard: shell command decision parity across all hook payload shapes"
}

test_native_file_tools_are_guarded() {
  local payload out rc
  for payload in \
    '{"tool_name":"Write","tool_input":{"file_path":"projects/foo/new.txt","content":"x"}}' \
    '{"tool_name":"Edit","tool_input":{"file_path":"projects/foo/existing.txt","old_string":"x","new_string":"y"}}' \
    '{"tool_name":"write","tool_input":{"path":"'"$WORKER_COPY"'/new.txt","content":"x"}}' \
    '{"toolName":"edit","input":{"filePath":"projects/foo/native.txt","oldText":"a","newText":"b"}}'; do
    out=$(printf '%s' "$payload" | (cd "$PRIMARY" && FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state" "$CHECK") 2>&1); rc=$?
    [ "$rc" -eq 2 ] || fail "expected native file-tool deny, got exit $rc: $out"
    assert_contains "$out" '[project-write]' "native file-tool deny must name the guard"
  done
  payload='{"tool_name":"Write","tool_input":{"file_path":"/tmp/outside-project.txt","content":"x"}}'
  out=$(printf '%s' "$payload" | (cd "$PRIMARY" && FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state" "$CHECK") 2>&1); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] || fail "outside native file write must be allowed: $out"
  pass "project-write guard: denies native write/edit tools in all harness payload shapes"
}

test_caller_supplied_approval_cannot_bypass_guard() {
  expect_deny "FM_PROJECT_WRITE_APPROVAL='Captain explicitly approved: git -C projects/foo fetch origin' git -C projects/foo fetch origin"
  [ ! -e "$PRIMARY/state/project-write-approvals.jsonl" ] || fail "caller-supplied approval must not create an approval record"
  pass "project-write guard: caller-supplied approval text cannot bypass the policy"
}

test_worker_worktree_is_inert() {
  local child="$TMP_ROOT/child"
  git -C "$PRIMARY" worktree add -q -b fm/project-write-child "$child"
  : > "$child/AGENTS.md"
  install_guard "$child"
  local out rc
  out=$(cd "$child" && FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" "$child/bin/fm-project-write-pretool-check.sh" --command 'git -C ../primary/projects/foo fetch' 2>&1); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] || fail "linked worker worktree must remain inert: $out"
  pass "project-write guard: does not affect crew/scout task worktrees"
}

test_adapter_configurations_and_open_code_plugin() {
  local plugin out rc adapter_trace
  mkdir -p "$PRIMARY/.claude" "$PRIMARY/.codex" "$PRIMARY/.cursor" "$PRIMARY/.grok/hooks"
  cp "$ROOT/.claude/settings.json" "$PRIMARY/.claude/settings.json"
  cp "$ROOT/.codex/hooks.json" "$PRIMARY/.codex/hooks.json"
  cp "$ROOT/.cursor/hooks.json" "$PRIMARY/.cursor/hooks.json"
  cp "$ROOT/.grok/hooks/fm-primary-project-write-check.json" "$PRIMARY/.grok/hooks/"
  mv "$PRIMARY/bin/fm-project-write-pretool-check.sh" "$PRIMARY/bin/fm-project-write-pretool-check.real.sh"
  cat > "$PRIMARY/bin/fm-project-write-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_PROJECT_WRITE_ADAPTER_TRACE:-}" ]; then
  printf 'invoked\n' >> "$FM_PROJECT_WRITE_ADAPTER_TRACE"
fi
exec "$(dirname "${BASH_SOURCE[0]}")/fm-project-write-pretool-check.real.sh" "$@"
SH
  chmod +x "$PRIMARY/bin/fm-project-write-pretool-check.sh" "$PRIMARY/bin/fm-project-write-pretool-check.real.sh"
  adapter_trace="$PRIMARY/state/adapter-hook.trace"
  out=$(FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state" FIXTURE="$PRIMARY" TRACE="$adapter_trace" node --input-type=module 2>&1 <<'NODE'
import { readFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const fixture = process.env.FIXTURE;
const trace = process.env.TRACE;
const payload = JSON.stringify({ tool_name: "Bash", tool_input: { command: "printf x > projects/foo/adapter-sentinel" } });
const adapters = [
  {
    name: "Claude",
    file: ".claude/settings.json",
    env: { CLAUDE_PROJECT_DIR: fixture },
    commands: (config) => config.hooks.PreToolUse.filter((event) => event.matcher === ".*").flatMap((event) => event.hooks.map((hook) => hook.command)),
  },
  {
    name: "Codex",
    file: ".codex/hooks.json",
    env: {},
    commands: (config) => config.hooks.PreToolUse.filter((event) => event.matcher === ".*").flatMap((event) => event.hooks.map((hook) => hook.command)),
  },
  {
    name: "Cursor",
    file: ".cursor/hooks.json",
    env: { CURSOR_PROJECT_DIR: fixture },
    commands: (config) => config.hooks.preToolUse.filter((event) => event.matcher === ".*").map((event) => event.command),
  },
  {
    name: "Grok",
    file: ".grok/hooks/fm-primary-project-write-check.json",
    env: { GROK_WORKSPACE_ROOT: fixture },
    commands: (config) => config.hooks.PreToolUse.filter((event) => event.matcher === ".*").flatMap((event) => event.hooks.map((hook) => hook.command)),
  },
];
const traceCount = () => existsSync(trace) ? readFileSync(trace, "utf8").trim().split("\n").filter(Boolean).length : 0;
for (const adapter of adapters) {
  const config = JSON.parse(readFileSync(join(fixture, adapter.file), "utf8"));
  const commands = adapter.commands(config);
  if (!commands.length) throw new Error(`${adapter.name} has no all-tool hook commands`);
  let invokedAndDenied = false;
  for (const command of commands) {
    const before = traceCount();
    const env = { ...process.env, FM_HOME: fixture, FM_STATE_OVERRIDE: join(fixture, "state"), FM_PROJECT_WRITE_ADAPTER_TRACE: trace, ...adapter.env };
    delete env.GROK_AGENT;
    delete env.GROK_HOOK_EVENT;
    delete env.FM_ROOT_OVERRIDE;
    const result = spawnSync("bash", ["-c", command], { cwd: fixture, env, input: payload, encoding: "utf8" });
    const invoked = traceCount() > before;
    const output = `${result.stdout || ""}\n${result.stderr || ""}`;
    let denied = result.status === 2 && output.includes("[project-write]");
    if (adapter.name === "Cursor" && result.status === 0) {
      try {
        const decision = JSON.parse(result.stdout);
        denied = decision.permission === "deny" && String(decision.user_message).includes("[project-write]");
      } catch {}
    }
    if (invoked && denied) invokedAndDenied = true;
  }
  if (!invokedAndDenied) throw new Error(`${adapter.name} configured hook did not invoke the checker and deny the protected operation`);
}
if (existsSync(join(fixture, "projects/foo/adapter-sentinel"))) throw new Error("a configured hook allowed the protected write");
NODE
  ); rc=$?
  [ "$rc" -eq 0 ] || fail "configured adapters did not execute and enforce the project-write hook: $out"
  [ -z "$out" ] || fail "adapter behavior check printed output: $out"
  pass "project-write guard: Claude, Codex, Cursor, and Grok commands invoke the checker and deny writes"

  plugin="$TMP_ROOT/fm-primary-project-write-check.mjs"
  cp "$ROOT/.opencode/plugins/fm-primary-project-write-check.js" "$plugin"
  out=$(FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state" PLUGIN="$plugin" FIXTURE="$PRIMARY" node --input-type=module 2>&1 <<'NODE'
import { pathToFileURL } from "node:url";
process.chdir(process.env.FIXTURE);
const { FmPrimaryProjectWriteCheck } = await import(pathToFileURL(process.env.PLUGIN));
const hooks = await FmPrimaryProjectWriteCheck({ directory: process.env.FIXTURE });
const before = hooks["tool.execute.before"];
for (const [tool, args] of [
  ["bash", { command: "git -C projects/foo fetch origin" }],
  ["write", { file_path: "projects/foo/native.txt", content: "x" }],
]) {
  let denied = false;
  try { await before({ tool }, { args }); }
  catch (error) { denied = String(error.message).includes("[project-write]"); }
  if (!denied) throw new Error(`OpenCode ${tool} invocation was not denied by the live plugin`);
}
await before({ tool: "read" }, { args: { file_path: "projects/foo/read-only.txt" } });
NODE
  ); rc=$?
  [ "$rc" -eq 0 ] || fail "OpenCode plugin did not enforce shell and native write decisions: $out"
  [ -z "$out" ] || fail "OpenCode plugin contract test printed output: $out"
  pass "project-write guard: JSON hook configs and the OpenCode plugin enforce all-tool policy"
}

test_git_state_changes_are_denied
test_git_reads_and_guarded_scripts_are_allowed
test_file_mutations_are_denied
test_recorded_worker_copy_is_guarded
test_shell_payload_parity
test_native_file_tools_are_guarded
test_caller_supplied_approval_cannot_bypass_guard
test_worker_worktree_is_inert
test_adapter_configurations_and_open_code_plugin
