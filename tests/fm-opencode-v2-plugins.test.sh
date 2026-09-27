#!/usr/bin/env bash
# Portable, no-harness regression for the OpenCode v2 plugin port
# (.opencode/plugins/fm-primary-*.js). OpenCode v2 rejects a plugin module
# unless its default export is shaped { id, effect|setup } (verified
# 2026-09-27 against the installed OpenCode 2.0.18: the legacy V1 named-export
# shape fails with "Plugin must export a default definition with an id and an
# effect or setup function."). These checks drive each plugin's default export
# with a fake ctx that reproduces OpenCode v2's real setup(ctx) surface,
# confirmed live against 2.0.18: ctx.location.directory, ctx.event.subscribe
# returning an async iterable of { type, data }, ctx.tool.hook("execute.before",
# cb) where throwing blocks the tool (and the built-in shell tool's id is
# "shell", not V1's "bash"), and ctx.session.prompt({ sessionID, text, delivery
# }) to inject a follow-up turn. The turn boundary is the session.execution.*
# lifecycle (session.idle and session.status are deprecated in the v2 schema):
# session.execution.succeeded and .failed end a turn, and .interrupted is where
# the watch-arm plugin also re-establishes continuity. The real OpenCode binary
# and TUI continuity are exercised opt-in by
# tests/fm-opencode-primary-live-e2e.test.sh; this file needs neither and runs
# wherever Node does.
#
# Every JS fixture below is a single-quoted heredoc so bash never touches the
# JS template literals; bash-side values (fixture paths, plugin file names)
# cross the boundary only through exported environment variables read back
# with process.env, never through unescaped ${...} interpolation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the OpenCode v2 plugin port checks"; exit 0; }

PLUGINS_SRC="$ROOT/.opencode/plugins"
TMP_ROOT=$(fm_test_tmproot fm-opencode-v2-plugins)
export PLUGINS_SRC

run_node() {  # <script-file>
  node --input-type=module <"$1"
}

# Copies the whole plugins/ directory (package.json, every plugin, lib/) into
# a fresh fixture so ESM resolution and "type": "module" match production.
install_plugins_fixture() {  # <fixture-root>
  local fixture=$1
  mkdir -p "$fixture"
  cp -R "$PLUGINS_SRC" "$fixture/plugins"
  mkdir -p "$fixture/bin" "$fixture/state"
  git init -q "$fixture"
}

test_default_export_shape() {
  local out
  cat >"$TMP_ROOT/shape.mjs" <<'JS'
import { pathToFileURL } from "node:url";
const dir = process.env.PLUGINS_SRC;
const files = [
  "fm-primary-turnend-guard.js",
  "fm-primary-watch-arm.js",
  "fm-primary-sessionstart-nudge.js",
  "fm-primary-pretool-check.js",
  "fm-primary-cd-check.js",
];
for (const file of files) {
  const mod = await import(pathToFileURL(`${dir}/${file}`).href);
  const def = mod.default;
  if (!def || typeof def !== "object") throw new Error(`${file} has no default export`);
  if (typeof def.id !== "string" || !def.id) throw new Error(`${file} default export has no string id`);
  if (typeof def.setup !== "function") throw new Error(`${file} default export has no setup function`);
}
console.log("shape-ok");
JS
  out=$(run_node "$TMP_ROOT/shape.mjs" 2>&1) || fail "default export shape: $out"
  assert_contains "$out" "shape-ok" "the default export shape check did not complete"
  pass "all five OpenCode plugins export the v2-required { id, setup } default definition"
}

FAKE_CTX_HARNESS='
function createEventBus() {
  const queue = [];
  const waiters = [];
  return {
    push(event) {
      if (waiters.length) waiters.shift()(event);
      else queue.push(event);
    },
    subscribe({ signal } = {}) {
      return {
        [Symbol.asyncIterator]() {
          return {
            next() {
              return new Promise((resolve) => {
                if (signal?.aborted) { resolve({ done: true, value: undefined }); return; }
                if (queue.length) { resolve({ done: false, value: queue.shift() }); return; }
                const onAbort = () => resolve({ done: true, value: undefined });
                signal?.addEventListener?.("abort", onAbort, { once: true });
                waiters.push((event) => {
                  signal?.removeEventListener?.("abort", onAbort);
                  resolve({ done: false, value: event });
                });
              });
            },
          };
        },
      };
    },
  };
}

function createFakeCtx(directory) {
  const promptCalls = [];
  const hooks = {};
  const bus = createEventBus();
  const ctx = {
    location: { directory },
    event: { subscribe: (opts) => bus.subscribe(opts) },
    tool: {
      hook: async (name, cb) => {
        hooks[name] = cb;
      },
    },
    session: {
      prompt: async (args) => {
        promptCalls.push(args);
        return { id: "msg_fake", ...args };
      },
    },
  };
  return { ctx, promptCalls, hooks, pushEvent: (event) => bus.push(event) };
}

async function waitFor(check, timeoutMs = 5000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (check()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error("waitFor timed out");
}
'

# --- fm-primary-pretool-check.js and fm-primary-cd-check.js ----------------
# Both hook ctx.tool.hook("execute.before", ...) and shell out to their owner
# script with --command; the owner's exit 2 must block by throwing. The
# critical regression this pins: OpenCode v2 renamed the built-in
# command-execution tool id from V1's "bash" to "shell" (verified live against
# 2.0.18 with a real tool.execute.before dump), so a hook that still matched
# "bash" would silently stop blocking anything on v2.
test_pretool_seatbelt() {  # <plugin-file> <owner-script-name> <label>
  local plugin=$1 owner=$2 label=$3 fixture out
  fixture="$TMP_ROOT/seatbelt-$owner"
  install_plugins_fixture "$fixture"
  cat >"$fixture/bin/$owner" <<'SH'
#!/usr/bin/env bash
set -u
cmd=""
while [ $# -gt 0 ]; do
  case "$1" in
    --command) cmd=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$cmd" in
  *BLOCK_ME*) echo "denied: $cmd" >&2; exit 2 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fixture/bin/$owner"
  {
    printf '%s\n' "$FAKE_CTX_HARNESS"
    cat <<'JS'
import { pathToFileURL } from "node:url";
const fixture = process.env.FIXTURE;
const plugin = process.env.PLUGIN_FILE;
const mod = await import(pathToFileURL(`${fixture}/plugins/${plugin}`).href);
const { ctx, hooks } = createFakeCtx(fixture);
await mod.default.setup(ctx);
if (typeof hooks["execute.before"] !== "function") throw new Error("execute.before was never hooked");
const hook = hooks["execute.before"];

let threw = false;
try { await hook({ tool: "shell", sessionID: "s1", input: { command: "echo BLOCK_ME" } }); }
catch (e) { threw = true; if (!String(e.message).includes("denied: echo BLOCK_ME")) throw new Error("wrong throw message: " + e.message); }
if (!threw) throw new Error("shell tool with a blocked command did not throw");

threw = false;
try { await hook({ tool: "shell", sessionID: "s1", input: { command: "echo ok" } }); }
catch (e) { threw = true; }
if (threw) throw new Error("shell tool with an allowed command threw");

threw = false;
try { await hook({ tool: "bash", sessionID: "s1", input: { command: "echo BLOCK_ME" } }); }
catch (e) { threw = true; }
if (threw) throw new Error('a stray V1 "bash" tool id must not match: OpenCode v2 tool id is "shell"');

threw = false;
try { await hook({ tool: "read", sessionID: "s1", input: { filePath: "x" } }); }
catch (e) { threw = true; }
if (threw) throw new Error("a non-shell tool must never be blocked");

console.log("seatbelt-ok");
JS
  } >"$TMP_ROOT/seatbelt-$owner.mjs"
  out=$(FIXTURE="$fixture" PLUGIN_FILE="$plugin" run_node "$TMP_ROOT/seatbelt-$owner.mjs" 2>&1) || fail "$label: $out"
  assert_contains "$out" "seatbelt-ok" "$label did not complete"
  pass "$label blocks by throwing on OpenCode v2's \"shell\" tool id, leaves \"bash\" and other tools alone, and hooks execute.before through ctx.tool.hook"
}

# --- fm-primary-sessionstart-nudge.js ---------------------------------------
test_sessionstart_nudge() {
  local fixture out
  fixture="$TMP_ROOT/nudge"
  install_plugins_fixture "$fixture"
  cat >"$fixture/bin/fm-sessionstart-nudge.sh" <<'SH'
#!/usr/bin/env bash
echo "NUDGE_TEXT"
SH
  chmod +x "$fixture/bin/fm-sessionstart-nudge.sh"
  {
    printf '%s\n' "$FAKE_CTX_HARNESS"
    cat <<'JS'
import { pathToFileURL } from "node:url";
const fixture = process.env.FIXTURE;
const mod = await import(pathToFileURL(`${fixture}/plugins/fm-primary-sessionstart-nudge.js`).href);
const { ctx, promptCalls, pushEvent } = createFakeCtx(fixture);
await mod.default.setup(ctx);

pushEvent({ type: "session.created", data: { sessionID: "s1" } });
await waitFor(() => promptCalls.length === 1);
if (promptCalls[0].sessionID !== "s1") throw new Error("nudge sessionID mismatch: " + JSON.stringify(promptCalls[0]));
if (promptCalls[0].text !== "NUDGE_TEXT") throw new Error("nudge text mismatch: " + JSON.stringify(promptCalls[0]));
if (promptCalls[0].delivery !== "queue") throw new Error("nudge delivery mismatch: " + JSON.stringify(promptCalls[0]));

// A repeat session.created for the same session must not nudge twice.
pushEvent({ type: "session.created", data: { sessionID: "s1" } });
await new Promise((resolve) => setTimeout(resolve, 200));
if (promptCalls.length !== 1) throw new Error("the same session was nudged twice");

// A different session must still get its own nudge.
pushEvent({ type: "session.created", data: { sessionID: "s2" } });
await waitFor(() => promptCalls.length === 2);
if (promptCalls[1].sessionID !== "s2") throw new Error("second session nudge mismatch: " + JSON.stringify(promptCalls[1]));

console.log("nudge-ok");
JS
  } >"$TMP_ROOT/nudge.mjs"
  out=$(FIXTURE="$fixture" run_node "$TMP_ROOT/nudge.mjs" 2>&1) || fail "sessionstart-nudge: $out"
  assert_contains "$out" "nudge-ok" "the sessionstart-nudge check did not complete"
  pass "fm-primary-sessionstart-nudge reads session.created's v2 event.data.sessionID, injects the nudge exactly once per session through ctx.session.prompt, and nudges each new session independently"
}

# --- fm-primary-turnend-guard.js --------------------------------------------
test_turnend_guard() {
  local fixture out
  fixture="$TMP_ROOT/turnend-guard"
  install_plugins_fixture "$fixture"
  cp "$ROOT/bin/fm-operational-input.sh" "$fixture/bin/fm-operational-input.sh"
  chmod +x "$fixture/bin/fm-operational-input.sh"
  cat >"$fixture/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
touch "$(dirname "$0")/../state/guard-ran"
echo "GUARD_STDERR_REASON" >&2
exit 2
SH
  chmod +x "$fixture/bin/fm-turnend-guard.sh"
  {
    printf '%s\n' "$FAKE_CTX_HARNESS"
    cat <<'JS'
import { pathToFileURL } from "node:url";
import { existsSync, unlinkSync } from "node:fs";
const fixture = process.env.FIXTURE;
const ran = `${fixture}/state/guard-ran`;

// Case 1: no watch-arm coordinator present, the guard script fires and its
// exit 2 injects one follow-up turn.
{
  const mod = await import(pathToFileURL(fixture + "/plugins/fm-primary-turnend-guard.js").href + "?case=1");
  const { ctx, promptCalls, pushEvent } = createFakeCtx(fixture);
  await mod.default.setup(ctx);

  // session.execution.started is the busy signal, never a turn boundary.
  pushEvent({ type: "session.execution.started", data: { sessionID: "s1" } });
  await new Promise((resolve) => setTimeout(resolve, 150));
  if (promptCalls.length !== 0 || existsSync(ran)) throw new Error("session.execution.started must never trigger the guard");

  pushEvent({ type: "session.execution.succeeded", data: { sessionID: "s1" } });
  await waitFor(() => promptCalls.length === 1);
  if (!existsSync(ran)) throw new Error("the guard script never ran");
  unlinkSync(ran);
  if (promptCalls[0].sessionID !== "s1") throw new Error("guard sessionID mismatch: " + JSON.stringify(promptCalls[0]));
  if (promptCalls[0].delivery !== "queue") throw new Error("guard delivery mismatch: " + JSON.stringify(promptCalls[0]));
  if (!promptCalls[0].text.includes("TURN WOULD END BLIND")) throw new Error("guard text missing the blind-turn warning: " + promptCalls[0].text);

  // The very next turn end is the guard's own forced follow-up turn ending: it
  // must be skipped once, not re-guarded.
  pushEvent({ type: "session.execution.succeeded", data: { sessionID: "s1" } });
  await new Promise((resolve) => setTimeout(resolve, 200));
  if (promptCalls.length !== 1) throw new Error("the forced follow-up's own turn end was not skipped");
  if (existsSync(ran)) throw new Error("the guard script ran again on the skipped turn end");

  // A third turn end is ordinary again and re-guards; session.execution.failed
  // ends a turn exactly like .succeeded.
  pushEvent({ type: "session.execution.failed", data: { sessionID: "s1" } });
  await waitFor(() => promptCalls.length === 2);
  if (!existsSync(ran)) throw new Error("the guard script did not run on the third (failed) turn end");
  unlinkSync(ran);

  // session.execution.interrupted is a terminal boundary like the others: the
  // next turn end (this failed turn's own forced follow-up) is skipped once,
  // and the interrupt after that re-guards.
  pushEvent({ type: "session.execution.interrupted", data: { sessionID: "s1" } });
  await new Promise((resolve) => setTimeout(resolve, 200));
  if (promptCalls.length !== 2) throw new Error("the forced follow-up's own interrupt was not skipped");
  if (existsSync(ran)) throw new Error("the guard script ran on the skipped interrupt");
  pushEvent({ type: "session.execution.interrupted", data: { sessionID: "s1" } });
  await waitFor(() => promptCalls.length === 3);
  if (!existsSync(ran)) throw new Error("the guard script did not run on the interrupted turn end");
  unlinkSync(ran);
}

// Case 2: a watch-arm coordinator reports it already handled continuity, so
// the guard must defer to it and never run its own script or prompt.
{
  globalThis.__firstmateOpenCodeWatchArm = { ensureArmed: async () => "armed" };
  const mod = await import(pathToFileURL(fixture + "/plugins/fm-primary-turnend-guard.js").href + "?case=2");
  const { ctx, promptCalls, pushEvent } = createFakeCtx(fixture);
  await mod.default.setup(ctx);
  pushEvent({ type: "session.execution.succeeded", data: { sessionID: "s1" } });
  await new Promise((resolve) => setTimeout(resolve, 200));
  if (promptCalls.length !== 0) throw new Error("the guard prompted even though watch-arm reported it handled continuity");
  if (existsSync(ran)) throw new Error("the guard script ran even though watch-arm reported it handled continuity");
  delete globalThis.__firstmateOpenCodeWatchArm;
}

console.log("turnend-guard-ok");
JS
  } >"$TMP_ROOT/turnend-guard.mjs"
  out=$(FIXTURE="$fixture" run_node "$TMP_ROOT/turnend-guard.mjs" 2>&1) || fail "turnend-guard: $out"
  assert_contains "$out" "turnend-guard-ok" "the turnend-guard check did not complete"
  pass "fm-primary-turnend-guard triggers on session.execution.succeeded/.failed/.interrupted (never .started), reads v2 event.data.sessionID, defers to an armed watch-arm coordinator, and otherwise runs the guard script and injects the encoded blind-turn follow-up exactly once per firing, skipping its own forced turn end"
}

# --- fm-primary-watch-arm.js (wiring only; continuity spawning is covered by
# the opt-in live e2e and by bin/fm-watch-arm.sh's own tests) ---------------
test_watch_arm_wiring() {
  local fixture out
  fixture="$TMP_ROOT/watch-arm"
  install_plugins_fixture "$fixture"
  # No AGENTS.md: isPrimaryRoot() is false, so ensureArm resolves "not-primary"
  # without spawning anything, while still proving the v2 event/coordinator
  # wiring runs end to end with no crash.
  {
    printf '%s\n' "$FAKE_CTX_HARNESS"
    cat <<'JS'
import { pathToFileURL } from "node:url";
const fixture = process.env.FIXTURE;
const mod = await import(pathToFileURL(fixture + "/plugins/fm-primary-watch-arm.js").href);
const { ctx, promptCalls, pushEvent } = createFakeCtx(fixture);
await mod.default.setup(ctx);
if (typeof globalThis.__firstmateOpenCodeWatchArm?.ensureArmed !== "function") {
  throw new Error("setup did not publish the watch-arm coordinator");
}
const direct = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("s1");
if (direct !== "not-primary") throw new Error("expected a non-primary root to resolve not-primary, got " + direct);

// All three turn-ending/interrupting types must reach the wiring (and safely
// no-op outside a primary root); session.execution.started must not.
for (const type of ["session.execution.started", "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"]) {
  pushEvent({ type, data: { sessionID: "s1" } });
}
await new Promise((resolve) => setTimeout(resolve, 200));
if (promptCalls.length !== 0) throw new Error("a non-primary root must never prompt");

console.log("watch-arm-wiring-ok");
JS
  } >"$TMP_ROOT/watch-arm.mjs"
  out=$(FIXTURE="$fixture" run_node "$TMP_ROOT/watch-arm.mjs" 2>&1) || fail "watch-arm wiring: $out"
  assert_contains "$out" "watch-arm-wiring-ok" "the watch-arm wiring check did not complete"
  pass "fm-primary-watch-arm subscribes through ctx.event.subscribe, reads session.execution.*'s v2 event.data.sessionID, and publishes a working ensureArmed coordinator without crashing outside a primary root"
}

test_default_export_shape
test_pretool_seatbelt fm-primary-pretool-check.js fm-arm-pretool-check.sh "fm-primary-pretool-check"
test_pretool_seatbelt fm-primary-cd-check.js fm-cd-pretool-check.sh "fm-primary-cd-check"
test_sessionstart_nudge
test_turnend_guard
test_watch_arm_wiring
