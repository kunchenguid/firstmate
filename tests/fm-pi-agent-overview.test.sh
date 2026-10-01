#!/usr/bin/env bash
# Portable Pi agent-overview list, detail, mouse, refresh, and guarded-action tests.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v npm >/dev/null 2>&1 || { echo "skip: npm not found for Pi TUI test"; exit 0; }
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
if [ ! -d "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" ]; then
  echo "skip: installed Pi package with pi-tui not found"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-pi-agent-overview)
FIXTURE="$TMP_ROOT/repo"
HOME_DIR="$TMP_ROOT/home"
mkdir -p \
  "$FIXTURE/.pi/extensions/lib" \
  "$FIXTURE/node_modules/@earendil-works" \
  "$FIXTURE/bin" \
  "$HOME_DIR/state" \
  "$HOME_DIR/config" \
  "$HOME_DIR/data"
cp "$ROOT/.pi/extensions/fm-agent-overview.ts" "$FIXTURE/.pi/extensions/fm-agent-overview.ts"
cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$FIXTURE/.pi/extensions/lib/fm-async-exec.ts"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" \
  "$FIXTURE/node_modules/@earendil-works/pi-tui"
printf '%s\n' '{"type":"module"}' > "$FIXTURE/package.json"
cat > "$FIXTURE/bin/fm-fleet-snapshot.sh" <<'SH'
#!/bin/sh
exec node "$FM_ROOT_OVERRIDE/bin/fm-fleet-snapshot.mjs"
SH
cat > "$FIXTURE/bin/fm-fleet-snapshot.mjs" <<'JS'
import { readFileSync } from "node:fs";
process.stdout.write(readFileSync(`${process.env.FM_HOME}/state/snapshot.json`, "utf8"));
JS
cat > "$FIXTURE/bin/fm-send.sh" <<'SH'
#!/bin/sh
exec node "$FM_ROOT_OVERRIDE/bin/fm-send.mjs" "$@"
SH
cat > "$FIXTURE/bin/fm-send.mjs" <<'JS'
import { appendFileSync } from "node:fs";
appendFileSync(
  `${process.env.FM_HOME}/state/send-args.jsonl`,
  `${JSON.stringify({
    args: process.argv.slice(2),
    spawnGen: process.env.FM_SEND_EXPECTED_SPAWN_GEN || null,
    remoteHost: process.env.FM_SEND_EXPECTED_REMOTE_HOST || null,
  })}\n`,
);
process.stdout.write("durably recorded\n");
JS
chmod +x "$FIXTURE/bin/fm-fleet-snapshot.sh" "$FIXTURE/bin/fm-send.sh"
: > "$HOME_DIR/state/send-args.jsonl"

NODE_NO_WARNINGS=1 FIXTURE="$FIXTURE" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FIXTURE" node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const home = process.env.FM_HOME;
const pluginPath = `${process.env.FIXTURE}/.pi/extensions/fm-agent-overview.ts`;
const { getKeybindings } = await import(pathToFileURL(
  `${process.env.FIXTURE}/node_modules/@earendil-works/pi-tui/dist/index.js`,
).href);
const commands = new Map();
const extension = await import(pathToFileURL(pluginPath).href);
extension.default({ registerCommand: (name, options) => commands.set(name, options) });
const command = commands.get("fm-agents");
assert.ok(command, "/fm-agents command is registered");

const theme = {
  fg: (_color, text) => text,
  bold: (text) => text,
};
const tui = { requestRender() {} };
const keybindings = getKeybindings();
let activePanel = null;
let createdPanels = 0;
let editorCalls = [];
let editorValues = [];
let notifications = [];
function context(mode = "tui") {
  return {
    mode,
    hasUI: true,
    ui: {
      custom(factory) {
        createdPanels += 1;
        return new Promise((resolve) => {
          activePanel = factory(tui, theme, keybindings, (value) => {
            activePanel = null;
            resolve(value);
          });
        });
      },
      async editor(title) {
        editorCalls.push(title);
        return editorValues.shift();
      },
      notify(message, kind) {
        notifications.push({ message, kind });
      },
    },
  };
}
function writeSnapshot(tasks) {
  writeFileSync(`${home}/state/snapshot.json`, JSON.stringify({
    schema: "fm-agent-overview.v1",
    generated: "2026-10-02T12:00:00Z",
    tasks,
  }));
}
function waitFor(predicate, description) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const poll = () => {
      if (predicate()) return resolve();
      if (Date.now() - start > 3000) return reject(new Error(`timed out waiting for ${description}: ${JSON.stringify(activePanel?.render(100))}`));
      setTimeout(poll, 10);
    };
    poll();
  });
}
function render() {
  return activePanel ? activePanel.render(100) : [];
}
function press(data) {
  assert.ok(activePanel, "a custom panel is open");
  activePanel.handleInput(data);
}
function baseTask(id, state, detail, extra = {}) {
  return {
    id,
    kind: "ship",
    project: "firstmate",
    spawn_gen: `gen-${id}`,
    current_state: { state, source: "pane", detail },
    hints: { open_decisions: [] },
    paths: { report: { present: false, path: null } },
    pr: { url: null },
    ...extra,
  };
}

// Empty fleet has a clear explanation and can be dismissed without acting.
writeSnapshot([]);
let run = command.handler("", context());
await waitFor(() => render().some((line) => line.includes("No agents are currently recorded")), "empty fleet view");
press("\u001b");
await run;
assert.equal(activePanel, null, "Escape closes an empty overview");

// Keyboard selection opens agent details, then Escape returns to the list and dismisses cleanly.
writeSnapshot([
  baseTask("agent-alpha", "working", "reading the project docs"),
  baseTask("agent-beta", "paused", "awaiting workflow evidence", {
    kind: "scout",
    hints: { open_decisions: [{ key: "workflow-choice", verb: "needs-decision", summary: "Choose the workflow page scope" }] },
  }),
]);
const keyboardContext = context();
run = command.handler("", keyboardContext);
await waitFor(() => render().some((line) => line.includes("agent-beta")), "agent list");
assert.ok(render().some((line) => line.includes("needs-decision")), "the list surfaces an actionable wait");
assert.ok(render().some((line) => line.includes("click rows in fullscreen")), "mouse-mode limitation is stated in the UI");
press("\u001b[B");
press("\r");
await waitFor(() => render().some((line) => line.includes("agent-alpha · ship")), "keyboard-selected detail menu");
assert.ok(render().some((line) => line.includes("reading the project docs")), "detail view shows current activity");
assert.ok(render().some((line) => line.includes("Send a message")), "detail menu offers a guarded message action");
press("\u001b");
await waitFor(() => render().some((line) => line.includes("agent-beta")), "return to list");
press("\u001b");
await run;
assert.equal(createdPanels, 4, "keyboard list/detail/back/dismiss opens the expected panels");
assert.equal(readFileSync(`${home}/state/send-args.jsonl`, "utf8").trim(), "", "opening and dismissing menus sends no message");

// A fullscreen mouse click on a row opens that agent's second menu.
createdPanels = 0;
run = command.handler("", context());
await waitFor(() => render().some((line) => line.includes("agent-beta")), "clickable agent list");
const listLines = render();
const betaRow = listLines.findIndex((line) => line.includes("agent-beta"));
assert.ok(betaRow >= 0, "the beta row is rendered");
activePanel.handleMouse({
  type: "click",
  button: "left",
  x: 2,
  y: betaRow,
  screenX: 2,
  screenY: betaRow,
  width: 100,
  height: listLines.length,
  shift: false,
  alt: false,
  ctrl: false,
  clickCount: 1,
});
await waitFor(() => render().some((line) => line.includes("agent-beta · scout")), "mouse-selected detail menu");
assert.ok(render().some((line) => line.includes("Choose the workflow page scope")), "detail view shows its current wait");
assert.ok(render().some((line) => line.includes("workflow-choice")), "detail menu offers the keyed wait action");

// Selecting a keyed action is explicit and still goes through fm-send.
editorValues = ["Use the existing workflow scope.\nKeep the research unchanged."];
press("\u001b[B");
press("\r");
await waitFor(() => editorCalls.length === 1, "message editor after action selection");
await waitFor(() => createdPanels >= 3 && activePanel !== null, "refreshed overview after message");
const sent = readFileSync(`${home}/state/send-args.jsonl`, "utf8").trim().split("\n").map(JSON.parse);
assert.deepEqual(sent.at(-1), {
  args: ["agent-beta", "--resolve-key", "workflow-choice", "Use the existing workflow scope.\nKeep the research unchanged."],
  spawnGen: "gen-agent-beta",
  remoteHost: null,
}, "keyed reply uses fm-send with the exact multiline answer and sampled generation guard");
assert.equal(keybindings.matches("\u001b", "tui.select.cancel"), true, "test uses Pi's live Escape binding");
press("\u001b");
await run;

// Refresh reads changing current state rather than replaying the previous activity.
createdPanels = 0;
writeSnapshot([baseTask("changing-agent", "working", "\u001b[32mcollecting workflow references\u001b[0m")]);
run = command.handler("", context());
await waitFor(() => render().some((line) => line.includes("collecting workflow references")), "initial activity");
writeSnapshot([baseTask("changing-agent", "paused", "waiting for the workflow page", {
  hints: { open_decisions: [{ key: "page-ready", verb: "blocked", summary: "The source page has not loaded yet" }] },
})]);
press("r");
await waitFor(() => render().some((line) => line.includes("waiting for the workflow page")), "refreshed activity");
assert.ok(render().some((line) => line.includes("blocked")), "refresh shows the latest actionable wait");
assert.ok(render().every((line) => !line.includes("\u001b[32m")), "terminal control sequences in current-state text are stripped");
press("\u001b");
await run;

// Outside the interactive TUI, the command declines without requesting data or a custom component.
const before = createdPanels;
const nonTuiContext = context("rpc");
await command.handler("", nonTuiContext);
assert.equal(createdPanels, before, "non-TUI mode does not open a custom screen");
assert.ok(notifications.some((entry) => entry.message.includes("interactive TUI")), "non-TUI limitation is explained");

console.log("ok - Pi agent overview covers empty fleet, keyboard and click detail selection, refresh, clean dismissal, and guarded keyed replies");
NODE
