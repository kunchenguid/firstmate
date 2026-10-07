#!/usr/bin/env bash
# Regression test for the OpenCode v2 plugin entrypoint and hook registration contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

out=$(node --input-type=module - "$ROOT" 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const root = process.argv[2];
const plugins = [
  ["fm-primary-cd-check.js", "fm-primary-cd-check", "tool"],
  ["fm-primary-pretool-check.js", "fm-primary-pretool-check", "tool"],
  ["fm-primary-sessionstart-nudge.js", "fm-primary-sessionstart-nudge", "event"],
  ["fm-primary-turnend-guard.js", "fm-primary-turnend-guard", "event"],
  ["fm-primary-watch-arm.js", "fm-primary-watch-arm", "event"],
];

for (const [filename, id, domain] of plugins) {
  const moduleUrl = pathToFileURL(`${root}/.opencode/plugins/${filename}`);
  const plugin = (await import(moduleUrl.href)).default;
  assert.equal(typeof plugin?.id, "string", `${filename} has a default id`);
  assert.equal(plugin.id, id, `${filename} exports its stable plugin id`);
  assert.equal(typeof plugin?.setup, "function", `${filename} has a v2 setup function`);

  const registrations = [];
  let eventDrained = false;
  const events = [];
  const ctx = {
    location: { directory: "" },
    session: { prompt: async () => {} },
    tool: {
      hook: async (name, callback) => registrations.push({ domain: "tool", name, callback }),
    },
    event: {
      subscribe: ({ signal } = {}) => (async function* () {
        while (events.length && !signal?.aborted) yield events.shift();
        if (!signal?.aborted) eventDrained = true;
      })(),
    },
  };

  const cleanup = await plugin.setup(ctx);
  if (domain === "tool") {
    assert.deepEqual(registrations.map(({ name }) => name), ["execute.before"], `${filename} registers its v2 tool hook`);
  } else {
    for (let i = 0; i < 50 && !eventDrained; i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.equal(eventDrained, true, `${filename} subscribes through the v2 event domain`);
  }
  await cleanup?.();
}

const fixture = mkdtempSync(join(root, ".opencode-event-contract-"));
const savedFmEnv = Object.fromEntries(["FM_HOME", "FM_ROOT_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_STATE_OVERRIDE"].map((key) => [key, process.env[key]]));
try {
  mkdirSync(join(fixture, "bin"), { recursive: true });
  mkdirSync(join(fixture, "state"), { recursive: true });
  mkdirSync(join(fixture, "config"), { recursive: true });
  writeFileSync(join(fixture, "AGENTS.md"), "fixture\n");
  execFileSync("git", ["init", "--quiet", fixture]);

  // The session-start hook is executable against a fixture nudge command.
  writeFileSync(join(fixture, "bin", "fm-sessionstart-nudge.sh"), "#!/bin/sh\nprintf 'fixture nudge'\n");
  chmodSync(join(fixture, "bin", "fm-sessionstart-nudge.sh"), 0o755);
  const createdPrompts = [];
  const createdEvents = [{ type: "session.created", data: { info: { id: "created-v2" } } }];
  const createdCtx = eventContext(fixture, createdEvents, createdPrompts);
  const stopCreated = await (await import(pathToFileURL(`${root}/.opencode/plugins/fm-primary-sessionstart-nudge.js`).href + `?contract=${Date.now()}`)).default.setup(createdCtx);
  await waitFor(() => createdPrompts.length === 1);
  assert.equal(createdPrompts[0].sessionID, "created-v2", "session.created reads v2 data.info.id");
  await stopCreated();

  // The turn-end handler must pass v2 idle IDs into the shared arm coordinator.
  const armedSessions = [];
  globalThis.__firstmateOpenCodeWatchArm = { ensureArmed: async (sessionID) => { armedSessions.push(sessionID); return "armed"; } };
  const idleEvents = [{ type: "session.idle", data: { sessionID: "idle-turn-v2" } }];
  const turnCtx = eventContext(fixture, idleEvents, []);
  const stopTurn = await (await import(pathToFileURL(`${root}/.opencode/plugins/fm-primary-turnend-guard.js`).href + `?contract=${Date.now()}`)).default.setup(turnCtx);
  await waitFor(() => armedSessions.length === 1);
  assert.deepEqual(armedSessions, ["idle-turn-v2"], "turn-end guard forwards v2 data.sessionID");
  await stopTurn();

  // Watch-arm must launch its executable arm path from the same v2 idle event.
  writeFileSync(join(fixture, "config", "x-mode.env"), "\n");
  process.env.FM_HOME = fixture;
  process.env.FM_ROOT_OVERRIDE = fixture;
  process.env.FM_CONFIG_OVERRIDE = join(fixture, "config");
  process.env.FM_STATE_OVERRIDE = join(fixture, "state");
  writeFileSync(join(fixture, "state", ".lock"), String(process.pid));
  const armMarker = join(fixture, "arm-session");
  writeFileSync(join(fixture, "bin", "fm-watch-arm.sh"), `#!/bin/sh\nprintf '%s' "$1" > '${armMarker}'\nprintf 'watcher: started\\n'\nsleep 2\n`);
  chmodSync(join(fixture, "bin", "fm-watch-arm.sh"), 0o755);
  const watchEvents = [{ type: "session.idle", data: { sessionID: "idle-watch-v2" } }];
  const watchCtx = eventContext(fixture, watchEvents, []);
  const stopWatch = await (await import(pathToFileURL(`${root}/.opencode/plugins/fm-primary-watch-arm.js`).href + `?contract=${Date.now()}`)).default.setup(watchCtx);
  await waitFor(() => {
    try { return readFileSync(armMarker, "utf8") === "--restart"; } catch { return false; }
  });
  assert.equal(readFileSync(armMarker, "utf8"), "--restart", "watch-arm launches for v2 data.sessionID");
  await stopWatch();
} finally {
  for (const [key, value] of Object.entries(savedFmEnv)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  delete globalThis.__firstmateOpenCodeWatchArm;
  rmSync(fixture, { recursive: true, force: true });
}

function eventContext(worktree, events, prompts) {
  return {
    location: { directory: worktree, worktree },
    session: { prompt: async (prompt) => prompts.push(prompt) },
    event: { subscribe: ({ signal } = {}) => (async function* () {
      for (const event of events) if (!signal?.aborted) yield event;
    })() },
  };
}

async function waitFor(predicate) {
  for (let i = 0; i < 100 && !predicate(); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(predicate(), true, "expected observable event side effect");
}
EOF
) || fail "OpenCode plugins failed the v2 default-export/setup contract: $out"
[ -z "$out" ] || fail "OpenCode v2 plugin contract test printed output: $out"
pass "all five OpenCode plugins export v2 id/setup definitions and register through ctx domains"
