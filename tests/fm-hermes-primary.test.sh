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
printf '%s\n' "HERMES_ENABLE_PROJECT_PLUGINS=\${HERMES_ENABLE_PROJECT_PLUGINS:-} FM_BACKEND=\${FM_BACKEND:-} FM_HERMES_PRIMARY_POLICY=\${FM_HERMES_PRIMARY_POLICY:-} CLAUDECODE=\${CLAUDECODE:-} PI_CODING_AGENT=\${PI_CODING_AGENT:-} FM_PI_HARNESS=\${FM_PI_HARNESS:-} GROK_AGENT=\${GROK_AGENT:-} CURSOR_AGENT=\${CURSOR_AGENT:-} CURSOR_INVOKED_AS=\${CURSOR_INVOKED_AS:-} ARGS=\$*" >> '$dir/calls'
if [ "\${1:-}" = config ] && [ "\${2:-}" = get ]; then
  [ '$status' = enabled ] && printf '%s\n' '- firstmate-primary'
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
  mkdir -p "$dir/firstmate-config" "$dir/state"
  printf '%s\n' pi > "$dir/firstmate-config/crew-harness"
  printf '%s\n' pi > "$dir/firstmate-config/secondmate-harness"
  printf '%s\n' herdr > "$dir/firstmate-config/backend"
  printf '%s\n' "$fakebin"
}

run_primary_launcher() {
  local fakebin=$1 case_dir=$2
  shift 2
  PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$case_dir/firstmate-config" \
    FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-hermes-primary.sh" "$@"
}

test_launcher_scope_and_fail_closed() {
  local fakebin out rc=0 calls
  fakebin=$(make_fake_hermes "$TMP_ROOT/launcher-enabled" enabled)
  out=$(run_primary_launcher "$fakebin" "$TMP_ROOT/launcher-enabled" --provider openai-codex --model gpt-5) || rc=$?
  [ "$rc" -eq 0 ] || fail "enabled launcher failed: $out"
  calls=$(cat "$TMP_ROOT/launcher-enabled/calls")
  assert_contains "$calls" 'ARGS=config get plugins.enabled' "launcher did not check allow-list"
  assert_contains "$calls" 'HERMES_ENABLE_PROJECT_PLUGINS=1 FM_BACKEND=herdr FM_HERMES_PRIMARY_POLICY=pi-herdr-v1' "launcher did not scope project discovery and worker policy"
  assert_contains "$calls" 'ARGS=--cli --no-restore-cwd --provider openai-codex --model gpt-5' "launcher did not force persistent CLI mode"

  : > "$TMP_ROOT/launcher-enabled/calls"
  rc=0
  out=$(CLAUDECODE=1 PI_CODING_AGENT=true FM_PI_HARNESS=pi GROK_AGENT=1 \
    CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent \
    run_primary_launcher "$fakebin" "$TMP_ROOT/launcher-enabled") || rc=$?
  [ "$rc" -eq 0 ] || fail "launcher failed while clearing inherited harness markers: $out"
  calls=$(cat "$TMP_ROOT/launcher-enabled/calls")
  assert_contains "$calls" 'CLAUDECODE= PI_CODING_AGENT= FM_PI_HARNESS= GROK_AGENT= CURSOR_AGENT= CURSOR_INVOKED_AS=' \
    "Hermes launch inherited a foreign harness identity marker"

  printf 'window=old\nharness=codex\nbackend=herdr\n' > "$TMP_ROOT/launcher-enabled/state/old.meta"
  rc=0
  out=$(run_primary_launcher "$fakebin" "$TMP_ROOT/launcher-enabled" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "launcher must reject an active non-Pi task"
  assert_contains "$out" 'active task old with harness=codex' "active harness mismatch was not actionable"
  printf 'window=old\nharness=pi\n' > "$TMP_ROOT/launcher-enabled/state/old.meta"
  rc=0
  out=$(run_primary_launcher "$fakebin" "$TMP_ROOT/launcher-enabled" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "launcher must reject an active non-Herdr task"
  assert_contains "$out" 'active task old with backend=tmux' "active backend mismatch was not actionable"
  rm -f "$TMP_ROOT/launcher-enabled/state/old.meta"

  rc=0
  out=$(run_primary_launcher "$fakebin" "$TMP_ROOT/launcher-enabled" --safe-mode 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "launcher must refuse options that disable the primary plugin"
  assert_contains "$out" "incompatible with the persistent Hermes Firstmate primary" \
    "unsafe Hermes launch option omitted its refusal"

  rc=0
  out=$(run_primary_launcher "$fakebin" "$TMP_ROOT/launcher-enabled" -z prompt 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "launcher must refuse one-shot Hermes mode"

  for escaped in '--profile=other' gateway acp; do
    rc=0
    out=$(run_primary_launcher "$fakebin" "$TMP_ROOT/launcher-enabled" "$escaped" 2>&1) || rc=$?
    [ "$rc" -eq 1 ] || fail "launcher must refuse Hermes surface escape '$escaped'"
    assert_contains "$out" "incompatible with the persistent Hermes Firstmate primary" \
      "surface escape '$escaped' omitted its refusal"
  done

  printf '%s\n' codex > "$TMP_ROOT/launcher-enabled/firstmate-config/crew-harness"
  rc=0
  out=$(run_primary_launcher "$fakebin" "$TMP_ROOT/launcher-enabled" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "launcher must require Pi crewmates"
  assert_contains "$out" "crew-harness to contain 'pi'" "Pi worker-policy refusal was not actionable"

  printf '%s\n' pi > "$TMP_ROOT/launcher-enabled/firstmate-config/crew-harness"
  printf '%s\n' codex > "$TMP_ROOT/launcher-enabled/firstmate-config/secondmate-harness"
  rc=0
  out=$(run_primary_launcher "$fakebin" "$TMP_ROOT/launcher-enabled" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "launcher must require Pi secondmates"
  assert_contains "$out" "secondmate-harness to contain 'pi'" "Pi secondmate-policy refusal was not actionable"

  printf '%s\n' pi > "$TMP_ROOT/launcher-enabled/firstmate-config/secondmate-harness"
  printf '%s\n' tmux > "$TMP_ROOT/launcher-enabled/firstmate-config/backend"
  rc=0
  out=$(run_primary_launcher "$fakebin" "$TMP_ROOT/launcher-enabled" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "launcher must require the Herdr backend"
  assert_contains "$out" "backend to contain 'herdr'" "Herdr policy refusal was not actionable"

  printf '%s\n' herdr > "$TMP_ROOT/launcher-enabled/firstmate-config/backend"
  rc=0
  out=$(FM_BACKEND=tmux run_primary_launcher "$fakebin" "$TMP_ROOT/launcher-enabled" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "launcher must reject an ambient non-Herdr backend override"
  assert_contains "$out" "FM_BACKEND=herdr" "ambient backend refusal was not actionable"

  fakebin=$(make_fake_hermes "$TMP_ROOT/launcher-disabled" disabled)
  rc=0
  out=$(run_primary_launcher "$fakebin" "$TMP_ROOT/launcher-disabled" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "disabled plugin must fail closed, got $rc"
  assert_contains "$out" '--setup' "disabled launcher omitted setup guidance"
  pass "Hermes launcher is explicit, scoped, and fail-closed"
}

test_setup_keeps_normal_wrapper_plugin_discoverable() {
  local fakebin out link target rc=0
  fakebin=$(make_fake_hermes "$TMP_ROOT/launcher-setup" enabled)
  out=$(run_primary_launcher "$fakebin" "$TMP_ROOT/launcher-setup" --setup) || rc=$?
  [ "$rc" -eq 0 ] || fail "Hermes setup failed: $out"
  link="$TMP_ROOT/launcher-setup/plugins/firstmate-primary"
  [ -L "$link" ] || fail "Hermes setup did not retain the user-plugin link for the normal wrapper"
  target=$(readlink "$link")
  [ "$target" = "$ROOT/.hermes/plugins/firstmate-primary" ] ||
    fail "Hermes setup linked the wrong tracked plugin: $target"
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
    os.environ["FM_HERMES_PRIMARY_POLICY"] = "pi-herdr-v1"
    os.environ["FM_HERMES_PRIMARY_PID"] = str(os.getpid())
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

ctx = activate(primary)
assert set(ctx.hooks) == {"pre_tool_call", "on_session_end", "on_session_finalize"}
marker = primary / "state" / ".hermes-primary-plugin-loaded"
lines = marker.read_text().splitlines()
assert lines[0].startswith("sha256:")
assert lines[1] == str(os.getpid())
assert lines[2] == str(primary.resolve())

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
end(session_id="s1", platform="cli", completed=True)
assert ctx.injected == []
end(session_id="s1", platform="telegram", completed=True)
assert ctx.injected == []
(primary / "state" / "worker.meta").write_text("project=fixture\n")
end(session_id="s1", platform="cli", completed=False, failed=True)
assert len(ctx.injected) == 1
repair = ctx.injected[0][0]
assert repair.startswith("\u2063FIRSTMATE_OP: v1 turn-end-guard: ")
assert "terminal(background=true, notify_on_complete=true)" in repair
end(session_id="s1", platform="cli", completed=False, interrupted=True)
assert len(ctx.injected) == 1
end(session_id="s2", platform="cli", completed=False, interrupted=True)
assert len(ctx.injected) == 2
ctx.hooks["on_session_finalize"](session_id="s1")
assert marker.exists()
end(session_id="s1", platform="cli", completed=True)
assert len(ctx.injected) == 3

os.chdir(primary.parent)
pre("delegate_task", {}) is None
end(session_id="s3", platform="cli", completed=False, failed=True)
assert len(ctx.injected) == 3
PY
  pass "Hermes plugin is scoped, blocks delegation, preserves ordinary tools, and has bounded recovery"
}

test_protocol_and_existing_harnesses
test_launcher_scope_and_fail_closed
test_setup_keeps_normal_wrapper_plugin_discoverable
test_plugin_scope_guard_and_recovery

echo "# all fm-hermes-primary tests passed"
