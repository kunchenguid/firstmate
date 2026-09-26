#!/usr/bin/env bash
# Behavior tests for the Firstmate Hermes plugin (.hermes/plugins/firstmate/
# loader and .hermes/firstmate/ implementation), driven through a fake Hermes
# PluginContext. No Hermes installation is needed: the plugin talks to Hermes
# only through the ctx it is handed, and to Firstmate only through bin/ owner
# scripts, which the scratch home below replaces with deterministic fakes
# (except the operational-input, primary-scope, gate, and busy-state owners,
# which are the real scripts).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PYTHON_BIN=$(command -v python3) || fail "test needs python3"
TMP_ROOT=$(fm_test_tmproot fm-hermes-plugin)
# The fake arm runs until the test releases it; a driver that exits without a
# shutdown (or fails midway) must not leave one behind. Scoped to this run's
# own temp root, so no other home's watcher can match.
reap_fake_arms() {
  local pid
  for pid in $(ps -axo pid=,args= 2>/dev/null | awk -v root="$TMP_ROOT/" 'index($0, root) && /fm-watch-arm\.sh/ {print $1}'); do
    kill "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap reap_fake_arms EXIT
fm_git_identity fmtest fmtest@example.invalid

make_home() {  # <dir>
  local home=$1
  mkdir -p "$home/bin" "$home/state" "$home/.hermes"
  cp -R "$ROOT/.hermes/plugins" "$home/.hermes/plugins"
  cp -R "$ROOT/.hermes/firstmate" "$home/.hermes/firstmate"
  rm -rf "$home/.hermes/firstmate/__pycache__" "$home/.hermes/plugins/firstmate/__pycache__"
  printf '# test home\n' > "$home/AGENTS.md"
  for f in fm-operational-input.sh fm-primary-scope-lib.sh fm-gate-refuse-lib.sh fm-busy-event.sh fm-busy-lib.sh; do
    cp "$ROOT/bin/$f" "$home/bin/$f"
  done
  : > "$home/bin/fm-session-start.sh"
  cat > "$home/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_LOG/sessionstart.args"
[ ! -f "$FM_TEST_LOG/sessionstart.delay" ] || sleep "$(cat "$FM_TEST_LOG/sessionstart.delay")"
printf 'DIGEST-BODY source=%s\n' "$2"
SH
  cat > "$home/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >> "$FM_TEST_LOG/guard.stdin"
printf '\n' >> "$FM_TEST_LOG/guard.stdin"
code=$(cat "$FM_TEST_LOG/guard.code" 2>/dev/null || printf 0)
[ "$code" = 2 ] && printf 'GUARD-RECOVERY-TEXT\n' >&2
exit "$code"
SH
  cat > "$home/bin/fm-subagent-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$FM_TEST_LOG/subagent.tools"
[ "$2" = delegate_task ] && { printf '[subagent-dispatch] denied\n' >&2; exit 2; }
exit 0
SH
  cat > "$home/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "$2" in "cd "*) printf '[persistent-cd] denied\n' >&2; exit 2 ;; esac
exit 0
SH
  cat > "$home/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_LOG/arm-check.args"
case "$2" in *"&"*) printf '[watcher-background] denied\n' >&2; exit 2 ;; esac
exit 0
SH
  # A fake arm: announce a verified start with a fresh recovery generation,
  # then wait for the test to release one actionable close.
  cat > "$home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf '%s %s\n' "$2" "$4" >> "$FM_TEST_LOG/handling-delivered"
  exit 0
fi
n=$(( $(cat "$FM_TEST_LOG/arm.count" 2>/dev/null || printf 0) + 1 ))
printf '%s\n' "$n" > "$FM_TEST_LOG/arm.count"
printf '%s %s predecessor=%s\n' "$n" "$*" "${FM_WATCH_PREDECESSOR_ARM_PID:-}" >> "$FM_TEST_LOG/arm.starts"
trap 'printf "%s\n" "$n" >> "$FM_TEST_LOG/arm.terminated"; exit 143' TERM
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=g%s\n' "$$" "$n"
while :; do
  if [ -f "$FM_TEST_LOG/release.$n" ]; then
    printf 'check: test wake %s\n' "$n"
    exit 0
  fi
  sleep 0.05
done
SH
  chmod +x "$home/bin/"*.sh
  git -C "$home" init -q
  git -C "$home" add -A >/dev/null 2>&1
  git -C "$home" commit -q -m init >/dev/null 2>&1
}

HOME_DIR="$TMP_ROOT/home"
LOG_DIR="$TMP_ROOT/log"
mkdir -p "$LOG_DIR"
make_home "$HOME_DIR"

cat > "$TMP_ROOT/driver.py" <<'PY'
import importlib.util, json, os, sys, threading, time
from pathlib import Path

home = Path(os.environ["FM_TEST_HOME"])
log = Path(os.environ["FM_TEST_LOG"])
mode = sys.argv[1]
passed = []

def ok(msg):
    print(f"ok - {msg}", flush=True)

def fail(msg):
    print(f"not ok - {msg}", file=sys.stderr, flush=True)
    sys.exit(1)

def wait_for(pred, timeout=10.0, what="condition"):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.05)
    fail(f"timed out waiting for {what}")

class Ctx:
    def __init__(self):
        self.hooks = {}
        self.tools = {}
        self.commands = {}
        self.injected = []
        self._manager = None
    def register_hook(self, name, fn):
        self.hooks.setdefault(name, []).append(fn)
    def register_tool(self, name, toolset, schema, handler, **kw):
        self.tools[name] = handler
    def register_command(self, name, handler, **kw):
        self.commands[name] = handler
    def inject_message(self, content, role="user", *, session_key=None):
        self.injected.append((content, session_key))
        return True
    def call(self, name, **kw):
        out = None
        for fn in self.hooks.get(name, []):
            r = fn(**kw)
            out = r if r is not None else out
        return out

def load(ctx):
    loader = home / ".hermes" / "plugins" / "firstmate" / "__init__.py"
    spec = importlib.util.spec_from_file_location("fm_loader_under_test", loader)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.register(ctx)
    return mod

(home / "state" / ".lock").write_text(f"{os.getpid()}\n")

if mode == "primary":
    ctx = Ctx()
    load(ctx)
    for hook in ("pre_llm_call", "on_session_end", "pre_tool_call", "pre_verify", "on_session_reset"):
        if hook not in ctx.hooks:
            fail(f"primary role did not register {hook}")
    if "fm_watch_arm_hermes" not in ctx.tools or "fm-watch-arm-hermes" not in ctx.commands:
        fail("primary role did not register the watcher repair tool and command")
    ok("loader resolves the Firstmate root from its own project location and registers the primary hooks")

    # Session start: the digest started at load and rides the first turn.
    res = ctx.call("pre_llm_call", session_id="s1", user_message="hello", conversation_history=[])
    context = (res or {}).get("context", "")
    if "⁣FIRSTMATE_OP: v1 session-start:" not in context or "DIGEST-BODY source=startup" not in context:
        fail(f"first turn did not carry the encoded startup digest: {context!r}")
    args = (log / "sessionstart.args").read_text()
    if "--source startup --pi-prerequisite" not in args:
        fail(f"digest did not run with the startup source and prerequisite contract: {args!r}")
    ok("first pre_llm_call returns the operational-encoded startup digest as context")

    res = ctx.call("pre_llm_call", session_id="s1", user_message="again",
                   conversation_history=[{"role": "user", "content": "hello", "api_content": context}])
    if res is not None:
        fail(f"a later turn with the digest still in context re-delivered it: {res!r}")
    ok("a later turn whose history still holds the digest gets no second digest")

    # Markers bind the loaded builds to this process.
    for marker, module in ((".hermes-watch-plugin-loaded", "fm_hermes_watch.py"),
                           (".hermes-turnend-plugin-loaded", "fm_hermes_guard.py")):
        lines = (home / "state" / marker).read_text().splitlines()
        import hashlib
        want = "sha256:" + hashlib.sha256((home / ".hermes" / "firstmate" / module).read_bytes()).hexdigest()
        if lines[:2] != [want, str(os.getpid())]:
            fail(f"{marker} does not record the current build and this pid: {lines}")
    ok("both plugin markers record the current module digest and the lock-owning pid")

    # Watcher: the plugin armed after the digest, with no model call.
    wait_for(lambda: (log / "arm.starts").exists(), what="the first plugin-owned arm")
    first = (log / "arm.starts").read_text().splitlines()[0]
    if "--restart" not in first:
        fail(f"first arm did not use --restart: {first!r}")
    ok("the plugin starts bin/fm-watch-arm.sh --restart itself once the digest holds the lock")

    # An actionable close: successor verified, handling confirmed, then wake delivered.
    (log / "release.1").touch()
    wait_for(lambda: any("FIRSTMATE WATCHER WAKE: check: test wake 1" in c for c, _ in ctx.injected),
             what="the watcher wake injection")
    starts = (log / "arm.starts").read_text().splitlines()
    if len(starts) < 2 or "predecessor=" not in starts[1] or starts[1].endswith("predecessor="):
        fail(f"successor arm did not name its predecessor: {starts}")
    delivered = (log / "handling-delivered").read_text().split()
    if delivered[:1] != ["g2"]:
        fail(f"handling delivery was not confirmed for the successor generation: {delivered}")
    wake = next(c for c, _ in ctx.injected if "test wake 1" in c)
    if not wake.startswith("⁣FIRSTMATE_OP: v1 watcher:"):
        fail(f"watcher wake was not a watcher-kind operational input: {wake[:80]!r}")
    ok("an actionable close starts a verified successor, confirms handling delivery, then injects one watcher wake")

    # The repair tool is an ownership no-op while the plugin owns an arm child.
    msg = ctx.tools["fm_watch_arm_hermes"]({})
    if "watcher: unchanged" not in msg:
        fail(f"repair tool did not report an ownership no-op: {msg!r}")
    ok("fm_watch_arm_hermes is an ownership-based no-op while the plugin owns the arm")

    # Seatbelts.
    blocked = ctx.call("pre_tool_call", tool_name="delegate_task", args={"goal": "x"})
    if not blocked or blocked.get("action") != "block" or "subagent-dispatch" not in blocked.get("message", ""):
        fail(f"delegation tool was not blocked: {blocked!r}")
    blocked = ctx.call("pre_tool_call", tool_name="terminal", args={"command": "cd /tmp"})
    if not blocked or "persistent-cd" not in blocked.get("message", ""):
        fail(f"persistent cd was not blocked: {blocked!r}")
    blocked = ctx.call("pre_tool_call", tool_name="terminal", args={"command": "bin/fm-watch-arm.sh &", "background": True})
    if not blocked or "watcher-background" not in blocked.get("message", ""):
        fail(f"backgrounded arm was not blocked: {blocked!r}")
    if "--background" not in (log / "arm-check.args").read_text():
        fail("terminal background flag was not forwarded to the arm checker")
    if ctx.call("pre_tool_call", tool_name="terminal", args={"command": "ls"}) is not None:
        fail("an ordinary terminal command was blocked")
    before = (log / "subagent.tools").read_text().count("read_file")
    ctx.call("pre_tool_call", tool_name="read_file", args={"path": "x"})
    ctx.call("pre_tool_call", tool_name="read_file", args={"path": "y"})
    if (log / "subagent.tools").read_text().count("read_file") - before != 1:
        fail("delegation verdicts are not cached per tool name")
    ok("pre_tool_call blocks delegation, persistent cd, and unsafe arm shapes, and allows ordinary commands")

    # Turn-end guard: one bounded follow-up, latched until its own turn ends.
    (log / "guard.code").write_text("2")
    base = len(ctx.injected)
    ctx.call("on_session_end", session_id="s1", interrupted=False)
    wait_for(lambda: len(ctx.injected) > base, what="the turn-end guard follow-up")
    follow = ctx.injected[-1][0]
    if not follow.startswith("⁣FIRSTMATE_OP: v1 turn-end-guard:") or "GUARD-RECOVERY-TEXT" not in follow:
        fail(f"guard follow-up is not the encoded recovery instruction: {follow[:120]!r}")
    ctx.call("on_session_end", session_id="s1", interrupted=False)
    time.sleep(1.0)
    if len(ctx.injected) != base + 1:
        fail("a second unhealthy boundary scheduled another follow-up while one was pending")
    ctx.call("pre_llm_call", session_id="s1", user_message=follow,
             conversation_history=[{"role": "user", "content": context}])
    ctx.call("on_session_end", session_id="s1", interrupted=False)
    last = (log / "guard.stdin").read_text().strip().splitlines()[-1]
    if json.loads(last).get("stop_hook_active") is not True:
        fail(f"the follow-up's own stop was not reported with stop_hook_active true: {last!r}")
    time.sleep(1.0)
    if len(ctx.injected) != base + 1:
        fail("the follow-up's own stop scheduled yet another follow-up")
    ok("an unhealthy turn end schedules exactly one guard follow-up, and its own stop is bounded")

    ctx.call("on_session_end", session_id="s1", interrupted=True)
    time.sleep(0.6)
    if len(ctx.injected) != base + 1:
        fail("an interrupted turn was guarded")
    ok("an interrupted turn is deliberately unguarded")

    verdict = ctx.call("pre_verify", attempt=0, session_id="s1")
    if not verdict or verdict.get("action") != "continue" or "GUARD-RECOVERY-TEXT" not in verdict.get("message", ""):
        fail(f"pre_verify did not compel a continuation: {verdict!r}")
    (log / "guard.code").write_text("0")
    if ctx.call("pre_verify", attempt=1, session_id="s1") is not None:
        fail("pre_verify continued a healthy turn")
    ok("pre_verify compels an in-turn continuation only while supervision is off")

    # Compaction: a session that lost the digest from its context re-emits it.
    res = ctx.call("pre_llm_call", session_id="s1", user_message="after compaction",
                   conversation_history=[{"role": "user", "content": "[summary of earlier turns]"}])
    if "DIGEST-BODY source=compact" not in (res or {}).get("context", ""):
        fail(f"compaction did not re-emit the digest with the compact source: {res!r}")
    ok("a turn whose history lost the digest re-runs session start with the compact source")

    # /new maps to clear and delivers into the new session's first turn.
    ctx.call("on_session_reset", session_id="s2", platform="cli", reason="new_session")
    res = ctx.call("pre_llm_call", session_id="s2", user_message="fresh", conversation_history=[])
    if "DIGEST-BODY source=clear" not in (res or {}).get("context", ""):
        fail(f"/new did not deliver a clear-source digest: {res!r}")
    ok("/new runs session start with the clear source and delivers it to the new conversation")

    # Away mode: the daemon owns supervision; the plugin stands its arm down.
    count_before = int((log / "arm.count").read_text())
    (home / "state" / ".afk").write_text("away\n")
    wait_for(lambda: (log / "arm.terminated").exists(), timeout=10, what="the away-mode stand-down")
    msg = ctx.tools["fm_watch_arm_hermes"]({})
    if "away-mode daemon owns supervision" not in msg:
        fail(f"repair during away mode did not defer to the daemon: {msg!r}")
    (home / "state" / ".afk").unlink()
    wait_for(lambda: int((log / "arm.count").read_text()) > count_before, timeout=10,
             what="the re-arm after the away flag cleared")
    ok("the plugin retires its arm while the away daemon owns supervision and re-arms after return")

    # Crash handoff: an undelivered actionable close survives the process.
    watch = sys.modules["fm_hermes_watch"]
    owner = watch.WatchOwner.__new__(watch.WatchOwner)
    owner._handoff = home / "state" / "extensions" / "hermes-primary-watch" / "pending-actionable.json"
    owner._write_handoff([watch.Pending("1-2-3", "check: persisted wake", "42")])
    loaded = owner._load_handoff()
    if len(loaded) != 1 or loaded[0].message != "check: persisted wake" or loaded[0].predecessor_arm_pid != "42":
        fail(f"handoff did not round-trip: {loaded!r}")
    owner._clear_handoff_token("1-2-3")
    if owner._handoff.exists():
        fail("clearing the last handoff token left the file behind")
    ok("an undelivered actionable close persists to the handoff file and clears once delivered")

    ctx.call("on_session_finalize", session_id="s2", platform="cli", reason="shutdown")
    wait_for(lambda: len((log / "arm.terminated").read_text().split()) >= 2, timeout=5,
             what="the shutdown retirement")
    ok("a CLI shutdown retires the plugin-owned arm")
    os._exit(0)

elif mode == "late-digest":
    (log / "sessionstart.delay").write_text("3")
    os.environ["FM_HERMES_SESSIONSTART_WAIT_SECS"] = "1"
    ctx = Ctx()
    load(ctx)
    res = ctx.call("pre_llm_call", session_id="s1", user_message="hi", conversation_history=[])
    ctxt = (res or {}).get("context", "")
    if "still running inside the Hermes plugin" not in ctxt:
        fail(f"a slow digest did not leave the pending notice: {ctxt!r}")
    ctx.call("on_session_end", session_id="s1", interrupted=False)
    wait_for(lambda: any("DIGEST-BODY" in c for c, _ in ctx.injected), timeout=10,
             what="idle delivery of the late digest")
    ok("a digest that outlives the bounded first-turn wait is delivered once the session is idle")
    ctx.call("on_session_finalize", session_id="s1", platform="cli", reason="shutdown")
    os._exit(0)

elif mode == "worker":
    os.environ["FM_HERMES_ROLE"] = "worker"
    ctx = Ctx()
    load(ctx)
    if "pre_tool_call" in ctx.hooks or "pre_verify" in ctx.hooks:
        fail("worker role registered primary hooks")
    state = os.environ["FM_HERMES_STATE"]
    task = os.environ["FM_HERMES_TASK"]
    rec = Path(state) / f"{task}.busy-state"
    ctx.call("pre_llm_call", session_id="w1", user_message="brief", conversation_history=[])
    if "state=busy" not in rec.read_text() or "source=hermes-plugin" not in rec.read_text():
        fail(f"turn start did not record busy from hermes-plugin: {rec.read_text()!r}")
    ctx.call("post_tool_call", tool_name="terminal", args={}, result="")
    if not (Path(state) / f"{task}.progress").exists():
        fail("tool completion did not refresh the progress marker")
    ctx.call("on_session_end", session_id="w1", interrupted=False)
    text = rec.read_text()
    if "state=idle" not in text or "event=turn-end" not in text:
        fail(f"turn end did not record idle: {text!r}")
    if not Path(os.environ["FM_HERMES_TURNEND"]).exists():
        fail("turn end did not touch the turn-ended marker")
    ctx.call("pre_llm_call", session_id="w1", user_message="again", conversation_history=[])
    ctx.call("on_session_end", session_id="w1", interrupted=True)
    if "event=turn-abort" not in rec.read_text():
        fail("an interrupted turn did not record its abort close")
    ok("worker role records busy, progress, idle, interrupt close, and the turn-ended marker")
    os._exit(0)
PY

run_driver() {  # <mode> [env...]
  local mode=$1
  shift
  env -u FM_HERMES_ROLE -u FM_HERMES_ROOT -u FM_HOME -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
    FM_TEST_HOME="$HOME_DIR" FM_TEST_LOG="$LOG_DIR" HERMES_SESSION_ID=s1 \
    FM_HERMES_AFK_POLL_MS=100 FM_WATCH_REARM_RETRY_BASE_MS=50 FM_GATE_REFUSE_BYPASS=1 "$@" \
    "$PYTHON_BIN" "$TMP_ROOT/driver.py" "$mode"
}

out=$(run_driver primary 2>&1) || { printf '%s\n' "$out" >&2; fail "primary plugin driver failed"; }
printf '%s\n' "$out"

rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
rm -f "$HOME_DIR/state/.hermes-"*
out=$(run_driver late-digest 2>&1) || { printf '%s\n' "$out" >&2; fail "late digest driver failed"; }
printf '%s\n' "$out"

# Worker role: the real busy writer against an armed incarnation.
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
WSTATE="$TMP_ROOT/worker-state"
mkdir -p "$WSTATE"
gen=$("$HOME_DIR/bin/fm-busy-event.sh" arm "$WSTATE" wtask) || fail "could not arm the worker incarnation"
out=$(run_driver worker FM_HERMES_STATE="$WSTATE" FM_HERMES_TASK=wtask FM_HERMES_BUSY_GEN="$gen" \
  FM_HERMES_TURNEND="$WSTATE/wtask.turn-ended" 2>&1) || { printf '%s\n' "$out" >&2; fail "worker plugin driver failed"; }
printf '%s\n' "$out"

# Outside any registered root the installed loader stays inert.
LOADER_HOME="$TMP_ROOT/hermes-home/plugins/firstmate"
mkdir -p "$LOADER_HOME"
cp "$ROOT/.hermes/plugins/firstmate/__init__.py" "$ROOT/.hermes/plugins/firstmate/plugin.yaml" "$LOADER_HOME/"
printf '%s\n' "$TMP_ROOT/not-a-root" > "$LOADER_HOME/roots"
inert=$(cd "$TMP_ROOT" && env -u FM_HERMES_ROOT "$PYTHON_BIN" -c "
import importlib.util
spec = importlib.util.spec_from_file_location('l', '$LOADER_HOME/__init__.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.resolve_root())
FM_ROOT = '$HOME_DIR'
import os; os.environ['FM_HERMES_ROOT'] = FM_ROOT
print(m.resolve_root())
os.environ['FM_HERMES_ROOT'] = '$TMP_ROOT'
print(m.resolve_root())
") || fail "installed loader probe failed"
[ "$(printf '%s\n' "$inert" | sed -n 1p)" = None ] || fail "installed loader resolved a root outside FM_HERMES_ROOT and the registry: $inert"
[ "$(printf '%s\n' "$inert" | sed -n 2p)" = "$(cd "$HOME_DIR" && pwd -P)" ] || fail "installed loader ignored an explicit FM_HERMES_ROOT: $inert"
[ "$(printf '%s\n' "$inert" | sed -n 3p)" = None ] || fail "installed loader accepted a FM_HERMES_ROOT that is not Firstmate-shaped: $inert"
pass "installed loader is inert without FM_HERMES_ROOT or a registered root, and never trusts a non-Firstmate root"

