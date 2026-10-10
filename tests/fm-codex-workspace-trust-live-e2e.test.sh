#!/usr/bin/env bash
# Token-free live guard: real Codex TOML writes and a fresh-folder TUI
# counterfactual. No prompt is submitted and no real credentials are copied.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate default-on FM_CODEX_WORKSPACE_TRUST_LIVE codex node python3
TMP_ROOT=$(fm_test_tmproot fm-codex-workspace-trust-live)
VERSION=$(codex --version 2>&1)
PROJ="$TMP_ROOT/project"
WT="$TMP_ROOT/worktree"
CONFIG="$TMP_ROOT/codex"
fm_git_worktree "$PROJ" "$WT" codex-trust-live
mkdir -p "$CONFIG"
printf '%s\n' '{"OPENAI_API_KEY":"unused-live-guard"}' > "$CONFIG/auth.json"
printf '# preserve this comment\nmodel_reasoning_effort = "low"\n[projects."/unrelated"]\ntrust_level = "untrusted"\n' > "$CONFIG/config.toml"
CODEX_HOME="$CONFIG" "$ROOT/bin/fm-codex-trust.sh" "$WT" "$PROJ" >/dev/null || fail "codex $VERSION: trust API registration failed"
assert_grep '# preserve this comment' "$CONFIG/config.toml" 'Codex lost an unrelated comment'
assert_grep 'model_reasoning_effort = "low"' "$CONFIG/config.toml" 'Codex lost an unrelated setting'
assert_grep '[projects."/unrelated"]' "$CONFIG/config.toml" 'Codex lost another project'
cp "$CONFIG/config.toml" "$TMP_ROOT/before"
CODEX_HOME="$CONFIG" "$ROOT/bin/fm-codex-trust.sh" "$WT" "$PROJ" >/dev/null || fail "codex $VERSION: idempotent registration failed"
cmp -s "$CONFIG/config.toml" "$TMP_ROOT/before" || fail "codex $VERSION: repeat registration rewrote TOML"

# A primary checkout of the same repository is deliberately left untrusted.
# Thus the positive cannot pass merely because some broad ancestor is trusted.
python3 - "$VERSION" "$CONFIG" "$PROJ" "$WT" <<'PY'
import fcntl, os, pty, re, select, signal, struct, subprocess, sys, termios, time
version, config, project, worktree = sys.argv[1:]
def capture(directory):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 35, 120, 0, 0))
    env = dict(os.environ, CODEX_HOME=config, TERM='xterm-256color')
    env.pop('CODEX_THREAD_ID', None)
    process = subprocess.Popen(['codex', '--no-daemon', '--no-alt-screen', '--disable', 'hooks',
        '-c', 'check_for_update_on_startup=false', '--dangerously-bypass-approvals-and-sandbox'],
        cwd=directory, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    output = b''
    try:
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try: output += os.read(master, 65536)
                except OSError: break
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        os.close(master)
    return re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', output.decode(errors='replace'))
negative = capture(project)
positive = capture(worktree)
trust_markers = ('Folder access', 'Trust and continue', 'Do you trust the contents')
if not any(marker in negative for marker in trust_markers):
    sys.exit(f'codex {version}: fresh unregistered checkout did not expose the trust gate: {negative[-2000:]}')
if any(marker in positive for marker in trust_markers):
    sys.exit(f'codex {version}: registered worktree still exposed the trust gate: {positive[-2000:]}')
if 'YOLO mode' not in positive or 'Ask Codex' not in positive:
    sys.exit(f'codex {version}: registered worktree did not reach the idle composer: {positive[-2000:]}')
print(f'ok - codex {version}: unregistered checkout gates; registered worktree reaches composer without input')
PY
expect_code 0 $? "codex $VERSION: live trust counterfactual failed"
printf 'broken = [\n' > "$CONFIG/config.toml"
out=$(CODEX_HOME="$CONFIG" "$ROOT/bin/fm-codex-trust.sh" "$WT" "$PROJ" 2>&1)
expect_code 1 $? "codex $VERSION: malformed TOML accepted: $out"
assert_grep 'broken = [' "$CONFIG/config.toml" 'malformed TOML was overwritten'
printf 'ok - codex %s: native config API preserves TOML, is idempotent and refuses malformed input\n' "$VERSION"
echo '# all fm-codex-workspace-trust-live-e2e checks passed'
