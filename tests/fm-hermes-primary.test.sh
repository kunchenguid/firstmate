#!/usr/bin/env bash
# Hermetic behavior tests for the Hermes primary launcher, protocol, and plugin.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-hermes-primary)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

test_protocol_and_existing_harnesses() {
  local out repair
  out=$("$ROOT/bin/fm-supervision-instructions.sh" --harness hermes --x-mode 1)
  assert_contains "$out" "primary harness: hermes" "Hermes supervision header missing"
  assert_contains "$out" 'terminal(background=true, notify_on_complete=true)' "Hermes protocol omitted managed notification"
  assert_contains "$out" 'Drain queued wakes first' "Hermes protocol is not drain-first"
  assert_contains "$out" 'one bounded Hermes turn-end recovery retry' "Hermes protocol omitted bounded recovery"
  repair=$("$ROOT/bin/fm-supervision-instructions.sh" --harness hermes --repair-line)
  assert_contains "$repair" 'terminal(background=true, notify_on_complete=true)' "Hermes repair omitted managed notification"
  assert_contains "$repair" 'never shell &' "Hermes repair permits shell backgrounding"
  assert_contains "$("$ROOT/bin/fm-supervision-instructions.sh" --harness claude)" 'Mode: Claude Stop-hook-owned supervision.' "Claude protocol regressed"
  assert_contains "$("$ROOT/bin/fm-supervision-instructions.sh" --harness codex)" 'Mode: Codex foreground checkpoint.' "Codex protocol regressed"
  assert_contains "$("$ROOT/bin/fm-supervision-instructions.sh" --harness opencode)" 'Mode: OpenCode TUI plugin background wake.' "OpenCode protocol regressed"
  assert_contains "$("$ROOT/bin/fm-supervision-instructions.sh" --harness pi)" 'Mode: Pi extension background wake.' "Pi protocol regressed"
  assert_contains "$("$ROOT/bin/fm-supervision-instructions.sh" --harness grok)" 'Mode: Grok background-notify supervision.' "Grok protocol regressed"
  pass "Hermes protocol renders without changing existing primary protocols"
}

make_fake_hermes() {
  local dir=$1 status=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/hermes" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "HERMES_ENABLE_PROJECT_PLUGINS=\${HERMES_ENABLE_PROJECT_PLUGINS:-} CLAUDECODE=\${CLAUDECODE:-} PI_CODING_AGENT=\${PI_CODING_AGENT:-} ARGS=\$*" >> '$dir/calls'
if [ "\${1:-}" = config ] && [ "\${2:-}" = get ]; then
  case "\${3:-}:$status" in
    plugins.enabled:enabled|plugins.enabled:both) printf '%s\n' '- firstmate-primary' ;;
    plugins.disabled:both) printf '%s\n' '- firstmate-primary' ;;
  esac
  exit 0
fi
if [ "\${1:-}" = config ] && [ "\${2:-}" = path ]; then
  printf '%s\n' '$dir/config.yaml'
  exit 0
fi
if [ "\${1:-}" = plugins ] && [ "\${2:-}" = enable ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/hermes"
  printf '%s\n' "$fakebin"
}

test_launcher_scope_and_fail_closed() {
  local fakebin out rc=0 calls
  fakebin=$(make_fake_hermes "$TMP_ROOT/launcher-enabled" enabled)
  out=$(CLAUDECODE=1 PI_CODING_AGENT=true PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-hermes-primary.sh" --provider openai-codex --model gpt-5) || rc=$?
  [ "$rc" -eq 0 ] || fail "enabled launcher failed: $out"
  calls=$(cat "$TMP_ROOT/launcher-enabled/calls")
  assert_contains "$calls" 'ARGS=config get plugins.enabled' "launcher did not check the enable list"
  assert_contains "$calls" 'ARGS=config get plugins.disabled' "launcher did not check the disable list"
  assert_contains "$calls" 'HERMES_ENABLE_PROJECT_PLUGINS=1 CLAUDECODE= PI_CODING_AGENT= ARGS=--cli --no-restore-cwd --provider openai-codex --model gpt-5' "launcher did not clear foreign markers or force persistent CLI mode"

  for escaped in --safe-mode -z --profile=other gateway acp; do
    rc=0
    out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-hermes-primary.sh" "$escaped" 2>&1) || rc=$?
    [ "$rc" -eq 1 ] || fail "launcher accepted incompatible option or command: $escaped"
    assert_contains "$out" "incompatible with the persistent Hermes Firstmate primary" \
      "unsafe Hermes launch shape omitted its refusal"
  done

  fakebin=$(make_fake_hermes "$TMP_ROOT/launcher-disabled" disabled)
  rc=0
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-hermes-primary.sh" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "disabled plugin must fail closed, got $rc"
  assert_contains "$out" '--setup' "disabled launcher omitted setup guidance"

  fakebin=$(make_fake_hermes "$TMP_ROOT/launcher-denied" both)
  rc=0
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-hermes-primary.sh" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "plugins.disabled must override plugins.enabled"
  pass "Hermes launcher is explicit, scoped, and fail-closed"
}

test_setup_keeps_normal_wrapper_plugin_discoverable() {
  local fakebin out link target rc=0
  fakebin=$(make_fake_hermes "$TMP_ROOT/launcher-setup" enabled)
  out=$(FM_HOME="$TMP_ROOT/launcher-setup/home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-hermes-primary.sh" --setup) || rc=$?
  [ "$rc" -eq 0 ] || fail "Hermes setup failed: $out"
  link="$TMP_ROOT/launcher-setup/plugins/firstmate-primary"
  [ -L "$link" ] || fail "Hermes setup did not retain the user-plugin link for the normal wrapper"
  target=$(readlink "$link")
  [ "$target" = "$ROOT/.hermes/plugins/firstmate-primary" ] ||
    fail "Hermes setup linked the wrong tracked plugin: $target"
  [ -d "$TMP_ROOT/launcher-setup/home/state" ] || fail "Hermes setup did not create clean-clone state"
  pass "Hermes setup makes the tracked plugin discoverable by the normal profile wrapper"
}

test_plugin_scope_guard_and_recovery() {
  local fixture="$TMP_ROOT/plugin-primary" child="$TMP_ROOT/plugin-child"
  mkdir -p "$fixture"
  cp -R "$ROOT/bin" "$fixture/bin"
  cp "$ROOT/AGENTS.md" "$fixture/AGENTS.md"
  mkdir -p "$fixture/state" "$fixture/config" "$fixture/docs"
  git -C "$fixture" init -q
  git -C "$fixture" add AGENTS.md
  git -C "$fixture" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
  git -C "$fixture" worktree add -q -b plugin-child "$child"
  mkdir -p "$child/state"

  FM_PLUGIN_SOURCE="$ROOT/.hermes/plugins/firstmate-primary/__init__.py" \
  FM_PLUGIN_FIXTURE="$fixture" FM_PLUGIN_CHILD="$child" python3 - <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

source = Path(os.environ["FM_PLUGIN_SOURCE"])
primary = Path(os.environ["FM_PLUGIN_FIXTURE"])
child = Path(os.environ["FM_PLUGIN_CHILD"])
spec = importlib.util.spec_from_file_location("fm_hermes_primary_plugin_test", source)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

class Context:
    def __init__(self):
        self.hooks = {}
        self.injected = []
    def register_hook(self, name, callback):
        self.hooks[name] = callback
    def inject_message(self, content, role="user"):
        self.injected.append((content, role))
        return True

def activate(root, argv=None):
    module._ROOT = root
    module._pending_retries.clear()
    os.environ["FM_HOME"] = str(root)
    os.environ["FM_STATE_OVERRIDE"] = str(root / "state")
    os.chdir(root)
    sys.argv = argv or ["hermes", "--cli", "--no-restore-cwd"]
    ctx = Context()
    module.register(ctx)
    return ctx

ctx = activate(child)
assert ctx.hooks == {}
assert not (child / "state" / ".hermes-primary-plugin-loaded").exists()

module._ROOT = primary
os.environ["FM_HOME"] = str(primary)
os.environ["FM_STATE_OVERRIDE"] = str(primary / "state")
os.chdir(primary)
sys.argv = ["hermes", "plugins", "list"]
ctx = Context()
module.register(ctx)
assert ctx.hooks == {}

ctx = activate(primary, ["hermes", "--cli", "--no-restore-cwd", "--ignore-rules"])
assert ctx.hooks == {}

ctx = activate(primary)
assert set(ctx.hooks) == {"pre_tool_call", "on_session_end", "on_session_finalize"}
marker = primary / "state" / ".hermes-primary-plugin-loaded"
lines = marker.read_text().splitlines()
assert lines[0].startswith("sha256:")
assert lines[1] == str(os.getpid())

pre = ctx.hooks["pre_tool_call"]
assert pre("read_file", {}) is None
blocked = pre("delegate_task", {})
assert blocked and blocked["action"] == "block"
assert "bin/fm-spawn.sh" in blocked["message"]
blocked = pre("terminal", {"command": "bin/fm-watch-arm.sh &", "background": False})
assert blocked and blocked["action"] == "block"
blocked = pre("terminal", {"command": "bin/fm-watch-arm.sh", "background": True})
assert blocked and blocked["action"] == "block"
assert pre(
    "terminal",
    {"command": "bin/fm-watch-arm.sh", "background": True, "notify_on_complete": True},
) is None

end = ctx.hooks["on_session_end"]
end(session_id="s1", platform="cli")
assert ctx.injected == []
end(session_id="s1", platform="telegram")
assert ctx.injected == []
(primary / "state" / "worker.meta").write_text("project=fixture\n")
end(session_id="s1", platform="cli", completed=False, failed=True)
assert len(ctx.injected) == 1
repair = ctx.injected[0][0]
assert repair.startswith("\u2063FIRSTMATE_OP: v1 turn-end-guard:")
assert "terminal(background=true, notify_on_complete=true)" in repair
end(session_id="s1", platform="cli", completed=False, interrupted=True)
assert len(ctx.injected) == 1
end(session_id="s1", platform="cli")
assert len(ctx.injected) == 2

os.chdir(primary.parent)
blocked = pre("delegate_task", {})
assert blocked and blocked["action"] == "block"
end(session_id="s2", platform="cli", completed=False, interrupted=True)
assert len(ctx.injected) == 3
ctx.hooks["on_session_finalize"](session_id="s2")
assert marker.exists()
PY
  pass "Hermes plugin is scoped, blocks delegation, preserves ordinary tools, and has bounded recovery"
}

test_protocol_and_existing_harnesses
test_launcher_scope_and_fail_closed
test_setup_keeps_normal_wrapper_plugin_discoverable
test_plugin_scope_guard_and_recovery

echo "# all fm-hermes-primary tests passed"
