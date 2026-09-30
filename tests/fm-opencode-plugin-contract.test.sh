#!/usr/bin/env bash
# Behavior tests for the OpenCode 2 plugin contract that every firstmate
# OpenCode plugin depends on.
#
# OpenCode 2.0.20 rejects a v1 plugin at load: a module must default-export a
# definition carrying an id and a setup(ctx), and a named export that is a
# factory returning a hooks object is refused outright. That rejection is
# silent per plugin (a "failed to load plugin" warning in the OpenCode log), so
# every guard in this directory can be absent while still looking installed.
# These tests drive the real plugin modules through their public module
# interface with a host-shaped context, so a plugin that reverts to the v1
# module shape fails here instead of failing silently in a live session.
#
# The event-shape facts under test were established against OpenCode 2.0.20 by
# running real sessions and enumerating the event stream a plugin subscription
# actually receives; .opencode/plugins/lib/fm-opencode-contract.js owns them and
# is exercised directly here. The seatbelt cases run the real
# bin/fm-arm-pretool-check.sh and bin/fm-cd-pretool-check.sh owners, so a
# verdict that reads as a denial comes from the real policy, not from a stub.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-opencode-plugin-contract)

PLUGIN_DIR="$ROOT/.opencode/plugins"

# A primary-shaped checkout: a plain (non-worktree) git repo carrying AGENTS.md
# and a bin/ with the seatbelt owners, their shared classifier, and a
# session-start wrapper that prints a recognizable nudge. The seatbelt owners
# scope themselves to exactly this shape, so it is what makes the denials below
# real rather than inert, and a printing wrapper is what makes a delivered nudge
# observable through the host interface.
make_primary_fixture() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-arm-pretool-check.sh" "$dir/bin/fm-arm-pretool-check.sh"
  cp "$ROOT/bin/fm-cd-pretool-check.sh" "$dir/bin/fm-cd-pretool-check.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-arm-command-policy.mjs"
  cp "$ROOT/bin/fm-cd-command-policy.mjs" "$dir/bin/fm-cd-command-policy.mjs"
  chmod +x "$dir/bin/fm-arm-pretool-check.sh" "$dir/bin/fm-cd-pretool-check.sh" \
    "$dir/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-cd-command-policy.mjs"
  cat > "$dir/bin/fm-sessionstart-nudge.sh" <<'SH'
#!/usr/bin/env bash
printf 'NUDGE_MARKER_FROM_WRAPPER\n'
SH
  chmod +x "$dir/bin/fm-sessionstart-nudge.sh"
}

# Load a plugin module exactly as the OpenCode 2 loader does (import the file,
# read its default export), run setup() against a host-shaped context, then
# drive it the way the host would and report what it did as one JSON line.
#
#   CTX_MODE=seatbelt  drive the registered execute.before hook over CTX_CALLS
#   CTX_MODE=events    feed CTX_EVENTS through the subscription
drive_plugin() {  # <plugin-file> <location-directory> <canonical-root> <mode> <payload>
  PLUGIN_PATH="$1" CTX_DIR="$2" CTX_CANONICAL="$3" CTX_MODE="$4" CTX_PAYLOAD="$5" \
    node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN_PATH).href);
const definition = mod.default;

// The exact shape the OpenCode 2 loader requires. A v1 module exports a named
// factory instead, so this is where a silent load failure becomes a test
// failure.
if (!definition || typeof definition !== "object") {
  throw new Error("no default export: the OpenCode 2 loader rejects this module");
}
if (typeof definition.id !== "string" || !definition.id) {
  throw new Error("default export has no string id");
}
if (typeof definition.setup !== "function") {
  throw new Error("default export has no setup function");
}

const payload = JSON.parse(process.env.CTX_PAYLOAD);
const toolHooks = new Map();
const prompted = [];

const cleanup = await definition.setup({
  location: {
    directory: process.env.CTX_DIR,
    project: { id: "test", directory: process.env.CTX_DIR, canonical: process.env.CTX_CANONICAL },
  },
  tool: {
    hook: async (name, callback) => {
      toolHooks.set(name, callback);
      return { dispose: async () => {} };
    },
  },
  session: {
    hook: async (_name, _callback) => ({ dispose: async () => {} }),
    prompt: async (input) => {
      prompted.push(input);
      return { id: "msg_test", sessionID: input.sessionID };
    },
  },
  event: {
    subscribe: () => ({
      async *[Symbol.asyncIterator]() {
        for (const event of payload.events ?? []) yield event;
      },
    }),
  },
});

const results = [];
if (process.env.CTX_MODE === "seatbelt") {
  const before = toolHooks.get("execute.before");
  // A plugin that is not a seatbelt registers no such hook; that is reported
  // rather than thrown, so the caller's own assertions decide whether the hook
  // was required.
  if (!before) {
    results.push("execute.before=absent");
  } else {
    for (const call of payload.calls) {
      let verdict = "allowed";
      try {
        await before(call);
      } catch (error) {
        verdict = `denied:${String(error.message).slice(0, 50)}`;
      }
      results.push(`${call.label}=${verdict}`);
    }
  }
} else {
  // Let the subscription's async loop drain before reporting.
  for (let tick = 0; tick < 50 && !payload.settled?.(); tick += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

// Cleanup is part of the contract under test: setup may return a cleanup
// function, and for the watch-arm adapter that cleanup retires a child process.
let cleaned = false;
if (typeof cleanup === "function") {
  await cleanup();
  cleaned = true;
}
console.log(JSON.stringify({ id: definition.id, results, prompted, cleaned }));
EOF
}

verdict() {  # <json> <label>
  printf '%s' "$1" | node -e '
let raw = "";
process.stdin.on("data", (chunk) => { raw += chunk; }).on("end", () => {
  const parsed = JSON.parse(raw);
  const hit = parsed.results.find((line) => line.startsWith(process.argv[1] + "="));
  process.stdout.write(hit ? hit.slice(process.argv[1].length + 1) : "MISSING");
});
' "$2"
}

prompt_count() {  # <json>
  printf '%s' "$1" | node -e '
let raw = "";
process.stdin.on("data", (chunk) => { raw += chunk; }).on("end", () => {
  process.stdout.write(String(JSON.parse(raw).prompted.length));
});
'
}

# Every tracked plugin must satisfy the loader module contract and name a
# distinct id, because two plugins sharing an id collide on plugin-scoped state.
test_every_plugin_exports_a_loadable_definition() {
  local out file read
  local -a ids=()
  for file in "$PLUGIN_DIR"/fm-primary-*.js; do
    assert_present "$file" "missing plugin $file"
    out=$(drive_plugin "$file" "$PRIMARY" "$PRIMARY" seatbelt '{"calls":[{"label":"noop","tool":"read","input":{}}]}') \
      || fail "$(basename "$file") is not a loadable OpenCode 2 plugin definition: $out"
    read=$(printf '%s' "$out" | node -e '
let raw = "";
process.stdin.on("data", (chunk) => { raw += chunk; }).on("end", () => process.stdout.write(JSON.parse(raw).id));
')
    ids+=("$read")
  done
  local total=${#ids[@]}
  local unique
  unique=$(printf '%s\n' "${ids[@]}" | sort -u | grep -c .)
  [ "$unique" = "$total" ] || fail "plugin ids must be distinct, got: ${ids[*]}"
  pass "all $total tracked plugins default-export a distinct id plus setup()"
}

# The v1 module shape is exactly what fails to load after the upgrade, so assert
# the loader's own refusal rather than only the happy path.
test_v1_module_shape_is_rejected() {
  local out fixture="$TMP_ROOT/v1-plugin"
  mkdir -p "$fixture"
  cat > "$fixture/v1.js" <<'JS'
export const FmLegacyPlugin = async () => ({
  event: async () => {},
});
JS
  out=$(drive_plugin "$fixture/v1.js" "$PRIMARY" "$PRIMARY" seatbelt '{"calls":[{"label":"noop","tool":"read","input":{}}]}') \
    && fail "a v1 named-export plugin must be refused, but it loaded: $out"
  printf '%s' "$out" | grep -q "no default export" \
    || fail "expected the loader's missing-default-export refusal, got: $out"
  pass "a v1 named-export plugin module is refused exactly as the OpenCode 2 loader refuses it"
}

# The seatbelt is the guard most easily broken by a wrong port: OpenCode 1
# called the tool "bash" and OpenCode 2 registers it as "shell", so a port
# keeping the old name matches no call and reads as installed while inert.
test_pretool_seatbelt_denies_unsafe_arm_shape() {
  local out payload
  payload='{"calls":[
    {"label":"legacy-bash-name","tool":"bash","input":{"command":"bin/fm-watch-arm.sh --restart &"}},
    {"label":"current-shell-name","tool":"shell","input":{"command":"bin/fm-watch-arm.sh --restart &"}},
    {"label":"non-shell-tool","tool":"read","input":{"command":"bin/fm-watch-arm.sh --restart &"}},
    {"label":"no-command","tool":"shell","input":{}},
    {"label":"unrelated-command","tool":"shell","input":{"command":"git status"}}
  ]}'
  out=$(drive_plugin "$PLUGIN_DIR/fm-primary-pretool-check.js" "$PRIMARY" "$PRIMARY" seatbelt "$payload") \
    || fail "pretool seatbelt drive failed: $out"

  [ "$(verdict "$out" legacy-bash-name)" = "allowed" ] \
    || fail "the v1 tool name must no longer match, or the guard would be inert: $out"
  case "$(verdict "$out" current-shell-name)" in
    denied:*) ;;
    *) fail "the seatbelt must deny the unsafe arm shape under the real tool name: $out" ;;
  esac
  [ "$(verdict "$out" non-shell-tool)" = "allowed" ] \
    || fail "a non-shell tool must not be judged by the shell seatbelt: $out"
  [ "$(verdict "$out" no-command)" = "allowed" ] \
    || fail "a shell call with no command must be allowed through: $out"
  [ "$(verdict "$out" unrelated-command)" = "allowed" ] \
    || fail "an unrelated command must be allowed through: $out"
  pass "the PreToolUse seatbelt denies an unsafe watcher-arm shape under OpenCode 2's tool name"
}

test_cd_seatbelt_denies_stray_persistent_cd() {
  local out payload
  payload='{"calls":[
    {"label":"stray-cd","tool":"shell","input":{"command":"cd /tmp && ls"}},
    {"label":"unrelated","tool":"shell","input":{"command":"git status"}}
  ]}'
  out=$(drive_plugin "$PLUGIN_DIR/fm-primary-cd-check.js" "$PRIMARY" "$PRIMARY" seatbelt "$payload") \
    || fail "cd seatbelt drive failed: $out"

  case "$(verdict "$out" stray-cd)" in
    denied:*) ;;
    *) fail "the cd seatbelt must deny a stray persistent cd: $out" ;;
  esac
  [ "$(verdict "$out" unrelated)" = "allowed" ] \
    || fail "an unrelated command must be allowed through the cd seatbelt: $out"
  pass "the cd seatbelt denies a stray persistent cd and allows unrelated commands"
}

# A wrong root resolution would point a seatbelt at the wrong checkout or at
# none. v1 read `worktree` for a worktree session and `directory` otherwise; v2
# carries both roles in ctx.location, so assert the resolution from each side.
test_root_resolution_follows_the_instance_location() {
  local out worktree="$TMP_ROOT/agent-worktree"
  mkdir -p "$worktree"
  git init -q "$worktree"
  git -C "$worktree" commit -q --allow-empty -m init

  out=$(drive_plugin "$PLUGIN_DIR/fm-primary-cd-check.js" "$PRIMARY" "$PRIMARY" seatbelt \
    '{"calls":[{"label":"stray-cd","tool":"shell","input":{"command":"cd /tmp && ls"}}]}') \
    || fail "primary-location drive failed: $out"
  case "$(verdict "$out" stray-cd)" in
    denied:*) ;;
    *) fail "a session at the canonical root must resolve that root and guard it: $out" ;;
  esac

  out=$(drive_plugin "$PLUGIN_DIR/fm-primary-cd-check.js" "$worktree" "$PRIMARY" seatbelt \
    '{"calls":[{"label":"stray-cd","tool":"shell","input":{"command":"cd /tmp && ls"}}]}') \
    || fail "worktree-location drive failed: $out"
  [ "$(verdict "$out" stray-cd)" = "allowed" ] \
    || fail "a worktree session must resolve the worktree, where the guard is inert by design: $out"
  pass "root resolution follows this instance's own directory, not the canonical checkout"
}

# OpenCode 2's event subscription is the whole server's stream, so an
# unfiltered handler would deliver this plugin's nudge into another location's
# session. Prove the scoping through a real plugin's real delivery.
test_event_handling_is_scoped_to_this_location() {
  local out
  out=$(drive_plugin "$PLUGIN_DIR/fm-primary-sessionstart-nudge.js" "$PRIMARY" "$PRIMARY" events \
    "$(printf '{"events":[{"type":"session.created","data":{"sessionID":"ses_own"},"location":{"directory":"%s"}}]}' "$PRIMARY")") \
    || fail "own-location nudge drive failed: $out"
  [ "$(prompt_count "$out")" = "1" ] \
    || fail "a session created in this instance's own location must receive the nudge, got: $out"
  printf '%s' "$out" | grep -q "NUDGE_MARKER_FROM_WRAPPER" \
    || fail "the delivered text must be the wrapper's nudge, got: $out"
  printf '%s' "$out" | grep -q '"sessionID":"ses_own"' \
    || fail "the nudge must be addressed to the created session, got: $out"

  out=$(drive_plugin "$PLUGIN_DIR/fm-primary-sessionstart-nudge.js" "$PRIMARY" "$PRIMARY" events \
    '{"events":[{"type":"session.created","data":{"sessionID":"ses_theirs"},"location":{"directory":"/somewhere/else"}}]}') \
    || fail "foreign-location nudge drive failed: $out"
  [ "$(prompt_count "$out")" = "0" ] \
    || fail "another location's session must never be nudged by this instance, got: $out"
  pass "event handling is scoped to this instance's own location on the shared v2 stream"
}

test_contract_helpers_classify_turn_end() {
  local out driver="$TMP_ROOT/contract-driver.mjs"
  cat > "$driver" <<'DRIVER'
import { pathToFileURL } from "node:url";
const lib = await import(pathToFileURL(`${process.argv[2]}/lib/fm-opencode-contract.js`).href);

const own = { location: { directory: "/home/x/primary" } };
const step = (finish, directory = "/home/x/primary") => ({
  type: "session.step.ended",
  data: { sessionID: "ses_a", finish },
  location: { directory },
});
const results = [];
const check = (label, actual, expected) => {
  const got = String(actual);
  results.push(label + "=" + (got === String(expected) ? "ok" : "MISMATCH(got " + got + ")"));
};

check("stop-ends-turn", lib.turnEndedSessionID(step("stop")), "ses_a");
check("tool-calls-does-not", lib.turnEndedSessionID(step("tool-calls")), "null");
check("length-ends-turn", lib.turnEndedSessionID(step("length")), "ses_a");
check("other-event-ignored", lib.turnEndedSessionID({ type: "session.tool.called", data: { sessionID: "ses_a" } }), "null");
check("own-event", lib.isOwnEvent(own, step("stop")), "true");
check("foreign-event", lib.isOwnEvent(own, step("stop", "/home/x/other")), "false");
check("locationless-event", lib.isOwnEvent(own, { type: "session.execution.succeeded", data: {} }), "false");
check("shell-tool-name", lib.SHELL_TOOL, "shell");
console.log(results.join("\n"));
DRIVER
  out=$(node "$driver" "$PLUGIN_DIR" 2>&1) || fail "contract helper drive failed: $out"

  printf '%s' "$out" | grep -q "MISMATCH" \
    && fail "contract helper misclassified a v2 event: $out"
  printf '%s' "$out" | grep -q "stop-ends-turn=ok" || fail "a stopped turn must be a turn end: $out"
  printf '%s' "$out" | grep -q "tool-calls-does-not=ok" || fail "a tool-calls step is not a turn end: $out"
  printf '%s' "$out" | grep -q "own-event=ok" || fail "this instance's own event must be recognised: $out"
  printf '%s' "$out" | grep -q "foreign-event=ok" || fail "a foreign location's event must not be ours: $out"
  printf '%s' "$out" | grep -q "locationless-event=ok" || fail "an event with no location must not be attributed: $out"
  printf '%s' "$out" | grep -q "shell-tool-name=ok" || fail "the shell tool name must be the v2 one: $out"
  pass "the contract helpers classify v2 turn ends and location scoping correctly"
}

# An unloading watch-arm adapter must not leave a successor armed. Its cleanup
# retires the live arm child, and that child's own close handler reads the signal
# as a watcher failure, so without a shutdown marker the plugin would schedule
# another arm that nothing owns once it is gone.
test_watch_arm_cleanup_does_not_rearm_after_unload() {
  local repo home out
  repo="$TMP_ROOT/cleanup-primary"
  home="$TMP_ROOT/cleanup-home"
  make_primary_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
# Answer the readiness probe, then linger until this arm is retired, so cleanup
# is the only thing that can end it.
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
while [ ! -e "${FM_STOP_FILE:?}" ]; do sleep 0.05; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(FM_OPENCODE_PLUGIN_HOST="$ROOT/tests/assets/fm-opencode-plugin-host.mjs" \
    PLUGIN="$PLUGIN_DIR/fm-primary-watch-arm.js" REPO="$repo" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
    FM_ARM_LOG="$TMP_ROOT/cleanup-arm.log" FM_STOP_FILE="$TMP_ROOT/cleanup.stop" \
    FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 \
    node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
const { loadPlugin } = await import(process.env.FM_OPENCODE_PLUGIN_HOST);

const repo = process.env.REPO;
const hooks = await loadPlugin(process.env.PLUGIN, { directory: repo, onPrompt: async () => {} });
// The arm checks session-lock ownership at launch, so this process must own the
// lock before the turn ends, exactly as a real primary session does.
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.turnEnd("ses_cleanup");
for (let i = 0; i < 300 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("the arm never started");

await hooks.cleanup();
// The retired child closes on the cleanup SIGTERM. Its close handler must see
// the shutdown and not schedule a successor, so give it well past the retry
// backoff before counting the arms.
await new Promise((resolve) => setTimeout(resolve, 1200));
const arms = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length;
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
if (arms !== 1) throw new Error(`expected exactly one arm, got ${arms}`);
console.log(`arms=${arms}`);
EOF
  ) || fail "watch-arm cleanup drive failed: $out"
  printf '%s' "$out" | grep -q "arms=1" \
    || fail "the plugin armed a successor after unloading: $out"
  pass "the watch-arm plugin does not re-arm after its cleanup retires the arm child"
}

PRIMARY="$TMP_ROOT/primary"
make_primary_fixture "$PRIMARY"

test_every_plugin_exports_a_loadable_definition
test_v1_module_shape_is_rejected
test_pretool_seatbelt_denies_unsafe_arm_shape
test_cd_seatbelt_denies_stray_persistent_cd
test_root_resolution_follows_the_instance_location
test_event_handling_is_scoped_to_this_location
test_contract_helpers_classify_turn_end
test_watch_arm_cleanup_does_not_rearm_after_unload
