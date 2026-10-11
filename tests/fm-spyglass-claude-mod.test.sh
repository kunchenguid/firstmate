#!/usr/bin/env bash
# Portable checks for the Claude Code Spyglass mod (.claude/mods/firstmate-spyglass) that
# need no Claude Code binary, so CI enforces them wherever Node runs:
#   - the plugin's declared shape: one hooks module and nothing else, reached from the
#     project's .claude/skills auto-load path through the tracked symlink, so nothing
#     of it can load while CLAUDE_CODE_ENABLE_FUNCTION_HOOKS is off;
#   - the pure fleet policy: home resolution, snapshot trimming (over a synthetic
#     snapshot and over the real bin/fm-fleet-snapshot.sh output), worker metadata, the
#     status-line summary, and the signal ids behind the toast;
#   - the update comparison: origin URL parsing, locally edited files, how far behind,
#     and which local edits the incoming commits also change;
#   - the session-capture sanitizer and the terminal-target guard.
# The engine-bound behavior runs under tests/fm-spyglass-claude-mod-plugin.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MOD="$ROOT/.claude/mods/firstmate-spyglass"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-spyglass-claude-mod)

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the Claude Code Spyglass mod checks"; exit 0; }

run_node() {  # <script-file>
  node --input-type=module <"$1"
}

# js_string <value>: a JavaScript string literal for a shell value, for the
# generated scripts below.
js_string() {  # <value>
  node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' -- "$1"
}

test_plugin_shape() {
  local link resolved autoload out
  link="$ROOT/.agents/skills/firstmate-spyglass"
  [ -L "$link" ] || fail "the Spyglass mod is not linked into .agents/skills, so Claude Code's project skills-dir scan cannot adopt it"
  resolved=$(cd "$link" && pwd -P) || fail "the .agents/skills/firstmate-spyglass link does not resolve"
  [ "$resolved" = "$(cd "$MOD" && pwd -P)" ] || fail "the .agents/skills/firstmate-spyglass link resolves to $resolved, not the mod"
  autoload="$ROOT/.claude/skills/firstmate-spyglass"
  [ -f "$autoload/.claude-plugin/plugin.json" ] || fail "the project's .claude/skills path does not reach the mod's manifest"
  [ -f "$autoload/hooks/hooks.json" ] || fail "the project's .claude/skills path does not reach the mod's hooks module declaration"
  [ ! -e "$MOD/SKILL.md" ] || fail "the mod carries a SKILL.md and would load as a skill on every harness"
  cat >"$TMP_ROOT/shape.mjs" <<JS
import { readFileSync, readdirSync, existsSync } from "node:fs";
const mod = $(js_string "$MOD");
const manifest = JSON.parse(readFileSync(\`\${mod}/.claude-plugin/plugin.json\`, "utf8"));
if (manifest.name !== "spyglass") throw new Error(\`manifest name \${manifest.name}\`);
for (const key of ["commands", "agents", "skills", "hooks", "mcpServers", "lspServers", "outputStyles"]) {
  if (key in manifest) throw new Error(\`manifest declares \${key}, which would load while the flag is off\`);
}
const hooks = JSON.parse(readFileSync(\`\${mod}/hooks/hooks.json\`, "utf8"));
const keys = Object.keys(hooks).sort();
if (JSON.stringify(keys) !== JSON.stringify(["description", "modules"])) {
  throw new Error(\`hooks.json declares \${keys.join(", ")}: a classic hook would run while the flag is off\`);
}
if (JSON.stringify(hooks.modules) !== JSON.stringify(["./register.tsx"])) throw new Error("hooks.json names a different module");
if (!existsSync(\`\${mod}/hooks/register.tsx\`)) throw new Error("the hooks module is missing");
const entries = readdirSync(mod).filter((name) => name !== ".claude-plugin").sort();
if (JSON.stringify(entries) !== JSON.stringify(["hooks", "lib", "tests"])) {
  throw new Error(\`the mod folder holds \${entries.join(", ")}: only hooks, lib, and tests may exist\`);
}
console.log("shape-ok");
JS
  out=$(run_node "$TMP_ROOT/shape.mjs" 2>&1) || fail "plugin shape: $out"
  assert_contains "$out" "shape-ok" "plugin shape check did not complete"
  pass "the Spyglass mod is one hooks module, linked into the project's auto-load path, with no command, skill, agent, or classic hook path that bypasses its exact opt-in"
}

test_home_resolution() {
  local out
  cat >"$TMP_ROOT/home.mjs" <<JS
import { pathToFileURL } from "node:url";
const lib = await import(pathToFileURL($(js_string "$MOD") + "/lib/fm-spyglass.ts").href);
const check = (condition, message) => { if (!condition) throw new Error(message); };
const pluginRoot = "/code/.claude/skills/firstmate-spyglass";
const plain = lib.spyglassCodeRoot({}, pluginRoot);
check(plain === "/code", \`code root from the plugin folder was \${plain}\`);
check(lib.spyglassCodeRoot({}, "/code/.claude/mods/firstmate-spyglass/") === "/code", "a trailing slash or the physical mod path changed the code root");
check(lib.spyglassCodeRoot({ FM_ROOT_OVERRIDE: "/other" }, pluginRoot) === "/other", "FM_ROOT_OVERRIDE did not name the code root");
check(lib.spyglassCodeRoot({ FM_HOME: "/home" }, pluginRoot) === "/code", "FM_HOME moved the code root, which holds the bin scripts");
check(lib.spyglassHome({}, pluginRoot) === "/code", "the home did not default to the code root");
check(lib.spyglassHome({ FM_ROOT_OVERRIDE: "/other" }, pluginRoot) === "/other", "FM_ROOT_OVERRIDE did not name the home");
check(lib.spyglassHome({ FM_HOME: "/home", FM_ROOT_OVERRIDE: "/other" }, pluginRoot) === "/home", "FM_HOME did not win over FM_ROOT_OVERRIDE");
check(lib.spyglassStateDirectory({ FM_HOME: "/home" }, pluginRoot) === "/home/state", "the state directory was not under the home");
check(lib.spyglassStateDirectory({ FM_HOME: "/home", FM_STATE_OVERRIDE: "/elsewhere/state" }, pluginRoot) === "/elsewhere/state", "FM_STATE_OVERRIDE did not name the state directory");
console.log("home-ok");
JS
  out=$(run_node "$TMP_ROOT/home.mjs" 2>&1) || fail "home resolution: $out"
  assert_contains "$out" "home-ok" "home resolution check did not complete"
  pass "the mod resolves its code root, home, and state directory like the bin scripts: FM_HOME, FM_ROOT_OVERRIDE, FM_STATE_OVERRIDE, then the checkout"
}

test_snapshot_trimming_and_summary() {
  local out home
  home="$TMP_ROOT/real-home"
  mkdir -p "$home/state" "$home/data"
  FM_HOME="$home" "$SNAPSHOT" --json >"$TMP_ROOT/real-snapshot.json" 2>"$TMP_ROOT/real-snapshot.err" \
    || fail "bin/fm-fleet-snapshot.sh --json failed in an empty home: $(cat "$TMP_ROOT/real-snapshot.err")"
  cat >"$TMP_ROOT/trim.mjs" <<JS
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const lib = await import(pathToFileURL($(js_string "$MOD") + "/lib/fm-spyglass.ts").href);
const check = (condition, message) => { if (!condition) throw new Error(message); };
const same = (actual, expected, message) => check(JSON.stringify(actual) === JSON.stringify(expected), \`\${message}: \${JSON.stringify(actual)}\`);

// The real owner's output in an empty home trims to an empty fleet and reads as nothing to say.
const real = JSON.parse(readFileSync($(js_string "$TMP_ROOT/real-snapshot.json"), "utf8"));
const empty = lib.trimSnapshot(real);
check(typeof empty.generated === "string" && empty.generated !== "", "the real snapshot's generated time was lost");
same([empty.underWay, empty.calls, empty.prs, empty.queued], [[], [], [], []], "an empty home did not trim to an empty fleet");
check(lib.summary(empty, null) === undefined, "an empty fleet produced a status line");

const snapshot = {
  generated: "2026-10-03T10:15:00Z",
  tasks: [
    { id: "alpha", kind: "ship", current_state: { state: "done" }, backlog: { repo: "web" }, project: "ignored", pr: { url: "https://github.com/o/r/pull/7" }, backend: "tmux", remote: null, endpoint: { target: "fm:alpha" } },
    { id: "beta", current_state: {}, project: "api" },
    { id: "draft", current_state: { state: "working" }, pr: { url: "https://github.com/o/r/pull/8" } },
    { id: "gamma" },
    { id: "delta", backend: "herdr", remote: null, endpoint: { target: "herdr-pane-7" } },
    { id: "epsilon", backend: "tmux", remote: { host: "box", root: "/fm" }, endpoint: { target: "fm:epsilon" } },
  ],
  backlog: {
    records: [
      { id: "held", title: "Pick a name", hold_reason: "needs the captain", captain_actionable: true, state: "queued" },
      { id: "rawheld", raw: "- raw line", captain_actionable: true },
      { id: "wait", title: "Later work", state: "queued" },
      { id: "wait2", raw: "raw queued", state: "queued" },
      { id: "done", title: "Shipped", state: "done" },
    ],
  },
};
const fleet = lib.trimSnapshot(snapshot);
same(fleet.underWay, [
  { id: "alpha", kind: "ship", state: "done", project: "web", pr: "https://github.com/o/r/pull/7", target: "fm:alpha", model: null, effort: null },
  { id: "beta", kind: "-", state: "?", project: "api", pr: null, target: null, model: null, effort: null },
  { id: "draft", kind: "-", state: "working", project: "-", pr: "https://github.com/o/r/pull/8", target: null, model: null, effort: null },
  { id: "gamma", kind: "-", state: "?", project: "-", pr: null, target: null, model: null, effort: null },
  { id: "delta", kind: "-", state: "?", project: "-", pr: null, target: null, model: null, effort: null },
  { id: "epsilon", kind: "-", state: "?", project: "-", pr: null, target: null, model: null, effort: null },
], "workers were trimmed differently (only a local tmux worker keeps its attach target)");
same(fleet.calls, [
  { id: "held", title: "Pick a name", reason: "needs the captain" },
  { id: "rawheld", title: "- raw line", reason: "" },
], "captain holds were trimmed differently");
same(fleet.prs, [{ id: "alpha", url: "https://github.com/o/r/pull/7" }], "ready PRs were trimmed differently (a PR is ready only once its worker reports done)");
same(fleet.queued, [{ id: "wait", title: "Later work" }, { id: "wait2", title: "raw queued" }], "queued work was trimmed differently (a held record must not also queue)");
check(fleet.generated === "2026-10-03T10:15:00Z", "the generated time was lost");
same(lib.trimSnapshot({}), { generated: "", underWay: [], calls: [], prs: [], queued: [] }, "an empty object did not trim to an empty fleet");

// Worker metadata comes from the task record's model= and effort= lines.
same(lib.parseWorkerMeta("harness=claude\nmodel=opus\neffort=high\n"), { model: "opus", effort: "high" }, "meta lines were not read");
same(lib.parseWorkerMeta("model=\nharness=pi\n"), { model: null, effort: null }, "an empty or missing value did not read as default");

// The status line.
const behind = { remote: "r", behind: 2, local: [], conflicts: [], checkedAt: "10:00", error: null };
check(lib.summary(fleet, null) === "⚓ 6 under way · 2 signals · 1 PR ready", \`summary was \${lib.summary(fleet, null)}\`);
check(lib.summary(fleet, behind) === "⚓ 6 under way · 2 signals · 1 PR ready · ⬆ update", "the update flag is missing from the summary");
check(lib.summary({ ...empty, underWay: [fleet.underWay[0]] }, null) === "⚓ 1 under way", "a single worker pluralized");
check(lib.summary(empty, behind) === "⚓ ⬆ update", "an update alone did not read");
check(lib.summary(empty, { ...behind, behind: 0 }) === undefined, "an up-to-date checkout added to the summary");

// The toast follows ids it has not seen: calls and PRs, by kind.
same([...lib.signalIds(fleet)].sort(), ["call:held", "call:rawheld", "pr:alpha"], "signal ids differ");

// Ship's watches by local hour, and the local clock.
const at = (hour) => new Date(2026, 9, 3, hour, 5).toISOString();
const watches = [[0, "Middle Watch"], [3, "Middle Watch"], [4, "Morning Watch"], [8, "Forenoon Watch"], [12, "Afternoon Watch"], [16, "Dog Watch"], [20, "First Watch"], [23, "First Watch"]];
for (const [hour, name] of watches) check(lib.watchName(at(hour)) === name, \`hour \${hour} was \${lib.watchName(at(hour))}\`);
check(lib.watchName("not a time") === "On watch", "an unreadable time did not read as On watch");
check(lib.clockTime(at(9)) === "09:05", \`clock was \${lib.clockTime(at(9))}\`);
check(lib.clockTime("not a time") === "not a time", "an unreadable time was not returned as is");
console.log("trim-ok");
JS
  out=$(run_node "$TMP_ROOT/trim.mjs" 2>&1) || fail "snapshot trimming: $out"
  assert_contains "$out" "trim-ok" "snapshot trimming check did not complete"
  pass "snapshot trimming keeps workers, holds, ready PRs, and queued work from synthetic and real snapshots, and the status line, signal ids, and watches follow"
}

test_update_comparison() {
  local out
  cat >"$TMP_ROOT/update.mjs" <<JS
import { pathToFileURL } from "node:url";
const lib = await import(pathToFileURL($(js_string "$MOD") + "/lib/fm-spyglass.ts").href);
const check = (condition, message) => { if (!condition) throw new Error(message); };
const same = (actual, expected, message) => check(JSON.stringify(actual) === JSON.stringify(expected), \`\${message}: \${JSON.stringify(actual)}\`);

// The upstream repo comes from origin, for GitHub remotes only.
for (const url of [
  "https://github.com/kunchenguid/firstmate",
  "https://github.com/kunchenguid/firstmate.git",
  "https://github.com/kunchenguid/firstmate/",
  "https://user@github.com/kunchenguid/firstmate.git",
  "git@github.com:kunchenguid/firstmate.git",
  "ssh://git@github.com/kunchenguid/firstmate.git\n",
]) check(lib.githubRepoFromRemote(url) === "kunchenguid/firstmate", \`\${JSON.stringify(url)} did not name kunchenguid/firstmate\`);
check(lib.githubRepoFromRemote("https://github.com/jshef747/firstmate.git") === "jshef747/firstmate", "a fork was not derived from its own origin");
for (const url of ["", "https://gitlab.com/o/r.git", "git@gitlab.com:o/r.git", "https://github.com/onlyowner", "/local/path/firstmate", "https://example.com/github.com/o/r"]) {
  check(lib.githubRepoFromRemote(url) === undefined, \`\${JSON.stringify(url)} named a repo\`);
}

// Origin's default branch and its commit, from git ls-remote --symref origin HEAD.
same(lib.originHead("ref: refs/heads/trunk\tHEAD\nabc123\tHEAD\n"), { branch: "trunk", commit: "abc123" }, "origin's default branch was read differently");
check(lib.originHead("abc123\tHEAD\n") === undefined, "a missing symref named a branch");
check(lib.originHead("") === undefined, "no ls-remote output named a branch");

// Behind count and conflicts: only a local edit the incoming commits also change collides.
const clean = lib.updateFrom("abc", [], { n: 3, files: ["AGENTS.md", "bin/fm-spawn.sh"] }, "10:00");
same(clean, { remote: "abc", behind: 3, local: [], conflicts: [], checkedAt: "10:00", error: null }, "a clean checkout behind origin");
const untouched = lib.updateFrom("abc", ["README.md"], { n: 1, files: ["AGENTS.md"] }, "10:00");
same([untouched.behind, untouched.local, untouched.conflicts], [1, ["README.md"], []], "an unrelated local edit was flagged as a conflict");
const conflicting = lib.updateFrom("abc", ["AGENTS.md", "README.md"], { n: 2, files: ["AGENTS.md", "bin/fm-spawn.sh"] }, "10:00");
same([conflicting.behind, conflicting.local, conflicting.conflicts], [2, ["AGENTS.md", "README.md"], ["AGENTS.md"]], "a conflicting local edit was missed");
const level = lib.updateFrom("abc", ["AGENTS.md"], undefined, "10:00");
same([level.behind, level.conflicts], [0, []], "an identical head read as behind");
console.log("update-ok");
JS
  out=$(run_node "$TMP_ROOT/update.mjs" 2>&1) || fail "update comparison: $out"
  assert_contains "$out" "update-ok" "update comparison check did not complete"
  pass "the update comparison derives the upstream from origin, counts commits behind, and flags only local edits the incoming commits also change"
}

test_capture_sanitizer() {
  local out
  cat >"$TMP_ROOT/capture.mjs" <<JS
import { pathToFileURL } from "node:url";
const lib = await import(pathToFileURL($(js_string "$MOD") + "/lib/fm-spyglass.ts").href);
const check = (condition, message) => { if (!condition) throw new Error(message); };
const ESC = "\u001b";

// Escape sequences, carriage returns, and other control characters go; tab, newline, and spaces stay.
const dirty = \`\${ESC}[1;32mready\${ESC}[0m\r\nline\ttwo\u0007 \${ESC}[?25hdone\u0000\u007f\n\n  \`;
const clean = lib.sanitizeCapture(dirty);
check(clean === "ready\nline\ttwo done", \`sanitized to \${JSON.stringify(clean)}\`);
check(lib.sanitizeCapture("") === "", "an empty capture changed");

// Only the newest 10000 characters stay, and the cut keeps the tail.
const long = "a".repeat(9000) + "b".repeat(2000);
const cut = lib.sanitizeCapture(long);
check(cut.length === 10000 && cut.endsWith("b".repeat(2000)) && cut.startsWith("a"), \`the cut kept \${cut.length} characters\`);

// A terminal launcher only gets tmux targets of the shapes the backends record.
for (const target of ["firstmate:fm-abc", "fm-abc", "sess:1.2", "@3", "%4", "a/b+c"]) check(lib.isSafeTarget(target), \`\${target} was refused\`);
for (const target of ["", 'x" & do shell script "id', "a b", "x;y", "\$(id)", "a'b", "a\nb"]) check(!lib.isSafeTarget(target), \`\${JSON.stringify(target)} was accepted\`);
console.log("capture-ok");
JS
  out=$(run_node "$TMP_ROOT/capture.mjs" 2>&1) || fail "capture sanitizer: $out"
  assert_contains "$out" "capture-ok" "capture sanitizer check did not complete"
  pass "the capture sanitizer strips escapes and control characters and keeps the newest 10000 characters, and the terminal launcher refuses unsafe targets"
}

test_plugin_shape
test_home_resolution
test_snapshot_trimming_and_summary
test_update_comparison
test_capture_sanitizer
