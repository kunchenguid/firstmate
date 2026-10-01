#!/usr/bin/env bash
# Portable checks for the Claude Code Calm mod (.claude/mods/firstmate-calm) that need
# no Claude Code binary, so CI enforces them wherever Node runs:
#   - the plugin's declared shape: one hooks module and nothing else, reached from the
#     project's .claude/skills auto-load path through the tracked symlink, so nothing
#     of it can load while CLAUDE_CODE_ENABLE_FUNCTION_HOOKS is off;
#   - the harness-neutral sprite core both harnesses share: the Pi widget's rendering
#     is byte-for-byte the shared frame painted with standard ANSI codes, so extracting
#     the core changed nothing Pi draws;
#   - the Raster packing of that frame and its base64 encoder;
#   - the pure presentation policy: home resolution, preference values, working notes;
#   - the pure supervision-note lines over a tail copy bin/fm-branch-outcome.sh writes;
#   - the operational-input classifier's parity with bin/fm-operational-input.sh over
#     envelopes the shell owner itself encodes, its legacy shapes, and near misses, and
#     the record-backed doorbell port's parity with the owner's doorbell-kind.
# The engine-bound behavior runs under tests/fm-calm-claude-mod-plugin.test.sh and the
# real TUI under tests/fm-calm-claude-mod-live-e2e.test.sh.
# shellcheck disable=SC2016 # Backticks are literal historical prompt markup in the corpus.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MOD="$ROOT/.claude/mods/firstmate-calm"
PI_SHIP="$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts"
PI_SPRITE="$ROOT/.pi/extensions/lib/fm-calm-working-ship-sprite.ts"
OPERATIONAL_INPUT="$ROOT/bin/fm-operational-input.sh"
TMP_ROOT=$(fm_test_tmproot fm-calm-claude-mod)

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the Claude Code Calm mod checks"; exit 0; }

run_node() {  # <script-file>
  node --input-type=module <"$1"
}

# js_string <value>: a JavaScript string literal for a shell value, for the
# generated scripts below. ${value@Q} would need Bash 4.4 and yields shell
# quoting; stock macOS Bash 3.2 reports a bad substitution.
js_string() {  # <value>
  node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' -- "$1"
}

test_plugin_shape() {
  local link resolved autoload
  link="$ROOT/.agents/skills/firstmate-calm"
  [ -L "$link" ] || fail "the Calm mod is not linked into .agents/skills, so Claude Code's project skills-dir scan cannot adopt it"
  resolved=$(cd "$link" && pwd -P) || fail "the .agents/skills/firstmate-calm link does not resolve"
  [ "$resolved" = "$(cd "$MOD" && pwd -P)" ] || fail "the .agents/skills/firstmate-calm link resolves to $resolved, not the mod"
  autoload="$ROOT/.claude/skills/firstmate-calm"
  [ -f "$autoload/.claude-plugin/plugin.json" ] || fail "the project's .claude/skills path does not reach the mod's manifest"
  [ -f "$autoload/hooks/hooks.json" ] || fail "the project's .claude/skills path does not reach the mod's hooks module declaration"
  [ -L "$PI_SPRITE" ] || fail "the Pi sprite path is not a symlink to the shared core"
  [ "$(node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$PI_SPRITE")" = \
    "$(node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$MOD/lib/fm-calm-working-ship-sprite.ts")" ] \
    || fail "the Pi sprite path does not resolve to the mod's shared core"
  [ ! -e "$MOD/SKILL.md" ] || fail "the mod carries a SKILL.md and would load as a skill on every harness"
  cat >"$TMP_ROOT/shape.mjs" <<JS
import { readFileSync, readdirSync, existsSync } from "node:fs";
const mod = $(js_string "$MOD");
const manifest = JSON.parse(readFileSync(\`\${mod}/.claude-plugin/plugin.json\`, "utf8"));
if (manifest.name !== "fm") throw new Error(\`manifest name \${manifest.name}\`);
for (const key of ["commands", "agents", "skills", "hooks", "mcpServers", "lspServers", "outputStyles"]) {
  if (key in manifest) throw new Error(\`manifest declares \${key}, which would load while the flag is off\`);
}
const hooks = JSON.parse(readFileSync(\`\${mod}/hooks/hooks.json\`, "utf8"));
const keys = Object.keys(hooks).sort();
if (JSON.stringify(keys) !== JSON.stringify(["description", "modules"])) {
  throw new Error(\`hooks.json declares \${keys.join(", ")}: a classic hook would run while the flag is off\`);
}
if (JSON.stringify(hooks.modules) !== JSON.stringify(["./register.ts"])) throw new Error("hooks.json names a different module");
if (!existsSync(\`\${mod}/hooks/register.ts\`)) throw new Error("the hooks module is missing");
const entries = readdirSync(mod).filter((name) => name !== ".claude-plugin").sort();
if (JSON.stringify(entries) !== JSON.stringify(["hooks", "lib", "tests"])) {
  throw new Error(\`the mod folder holds \${entries.join(", ")}: only hooks, lib, and tests may exist\`);
}
console.log("shape-ok");
JS
  out=$(run_node "$TMP_ROOT/shape.mjs" 2>&1) || fail "plugin shape: $out"
  assert_contains "$out" "shape-ok" "plugin shape check did not complete"
  pass "the Calm mod is one hooks module, linked into the project's auto-load path, with no command, skill, agent, or classic hook path that bypasses its exact opt-in"
}

test_shared_sprite_and_pi_rendering() {
  local out
  cat >"$TMP_ROOT/sprite.mjs" <<JS
import { pathToFileURL } from "node:url";
const pi = await import(pathToFileURL($(js_string "$PI_SHIP")).href);
const core = await import(pathToFileURL($(js_string "$MOD") + "/lib/fm-calm-working-ship-sprite.ts").href);
const ESC = "\\u001b";
const ANSI = { water: ESC + "[34m", boat: ESC + "[33m" };
const RESET = ESC + "[39m";
const paint = (row) => row.map((run) => (run.color === "plain" ? run.text : ANSI[run.color] + run.text + RESET)).join("");
const cells = (row) => row.map((run) => run.text).join("");
const check = (condition, message) => { if (!condition) throw new Error(message); };
check(pi.CALM_WORKING_SHIP_TICK_MS === core.CALM_WORKING_SHIP_TICK_MS, "Pi re-exports a different tick");
check(pi.CALM_WORKING_SHIP_TICKS_PER_MOVE === core.CALM_WORKING_SHIP_TICKS_PER_MOVE, "Pi re-exports a different move cadence");
let frames = 0;
for (const width of [0, 1, 2, 3, 4, 5, 6, 9, 12, 24, 40, 80, 121]) {
  const animation = pi.createCalmWorkingShipAnimation();
  const sprite = core.createCalmWorkingShipSprite();
  for (let step = 0; step < 41; step += 1) {
    const rendered = animation.render(width);
    const frame = sprite.frame(width);
    const expected = frame.map(paint);
    check(JSON.stringify(rendered) === JSON.stringify(expected), \`Pi rendering diverged from the shared frame at width \${width} step \${step}: \${JSON.stringify(rendered)} vs \${JSON.stringify(expected)}\`);
    check(animation.position() === sprite.position() && animation.direction() === sprite.direction() && animation.waterPhase() === sprite.waterPhase(), \`Pi animation state diverged at width \${width} step \${step}\`);
    if (width === 0) check(frame.length === 0, "zero width painted a row");
    if (width > 0) {
      const water = frame[frame.length - 1];
      check(cells(water).length === width, \`water row is \${cells(water).length} cells at width \${width}\`);
      for (const row of frame) {
        check(cells(row).length <= width, \`a row overflowed width \${width}\`);
        for (const run of row) check(["plain", "water", "boat"].includes(run.color), \`unknown color \${run.color}\`);
      }
      if (width >= 5) {
        check(frame.length === 2, \`width \${width} did not paint two rows\`);
        check(JSON.stringify(frame[0].slice(1)) === JSON.stringify([{ text: "◿│◣", color: "boat" }]), "the sail is not one boat-colored run");
        check(frame[0][0].color === "plain" && /^ +$/.test(frame[0][0].text), "sail padding is not plain spaces");
        const hullAt = frame[1].findIndex((run) => run.text === "╲▁▁▁╱");
        check(hullAt >= 0, "the hull is not one run");
        check(frame[1][hullAt].color === "boat", "the hull is not boat-colored");
        check(frame[1].filter((_run, index) => index !== hullAt).every((run) => run.text.length === 1 && run.color === "water"), "water outside the hull is not one water-colored bar per cell");
      } else if (width >= 3) {
        check(frame.length === 1 && cells(frame[0]).includes("◿│◣"), \`width \${width} lost the sail-only fallback\`);
      } else {
        check(frame.length === 1 && /^[▁▂▃▄]+$/.test(cells(frame[0])), \`width \${width} lost the water-only fallback\`);
      }
    }
    animation.tick();
    sprite.tick();
    frames += 1;
  }
}
// Freeze and resume: restoring the last painted frame discards later ticks on both.
{
  const animation = pi.createCalmWorkingShipAnimation();
  const sprite = core.createCalmWorkingShipSprite();
  animation.render(30); sprite.frame(30);
  for (let step = 0; step < 9; step += 1) { animation.tick(); sprite.tick(); }
  animation.render(30); sprite.frame(30);
  for (let step = 0; step < 6; step += 1) { animation.tick(); sprite.tick(); }
  animation.restoreLastRendered(); sprite.restoreLastRendered();
  check(animation.position() === sprite.position() && animation.waterPhase() === sprite.waterPhase(), "restore diverged");
  check(sprite.waterPhase() === 1 && sprite.position() === 2, \`restore landed at phase \${sprite.waterPhase()} column \${sprite.position()}\`);
  sprite.clampToWidth(6);
  check(sprite.position() === 1 && sprite.direction() === -1, "a hidden clamp did not turn the boat at the new edge");
  sprite.reset();
  check(sprite.position() === 0 && sprite.direction() === 1 && sprite.waterPhase() === 0, "reset did not restore the initial state");
}
console.log("sprite-ok frames=" + frames);
JS
  out=$(run_node "$TMP_ROOT/sprite.mjs" 2>&1) || fail "shared sprite: $out"
  assert_contains "$out" "sprite-ok frames=533" "the sprite parity sweep did not cover every width and step"
  pass "the Pi working ship renders byte-for-byte the shared sprite core's frame painted in standard ANSI, at every width, cadence step, freeze, clamp, and reset"
}

test_raster_packing() {
  local out
  cat >"$TMP_ROOT/raster.mjs" <<JS
import { pathToFileURL } from "node:url";
import { randomBytes } from "node:crypto";
const raster = await import(pathToFileURL($(js_string "$MOD") + "/lib/fm-calm-ship-raster.ts").href);
const core = await import(pathToFileURL($(js_string "$MOD") + "/lib/fm-calm-working-ship-sprite.ts").href);
const check = (condition, message) => { if (!condition) throw new Error(message); };
for (let length = 0; length <= 80; length += 1) {
  const bytes = new Uint8Array(randomBytes(length));
  check(raster.encodeBase64(bytes) === Buffer.from(bytes).toString("base64"), \`base64 diverged at length \${length}\`);
}
const decode = (cells, columns, rows) => {
  const words = new Uint32Array(new Uint8Array(Buffer.from(cells, "base64")).buffer);
  check(words.length === columns * rows * 3, \`\${words.length} words for \${columns}x\${rows}\`);
  const grid = [];
  for (let row = 0; row < rows; row += 1) {
    const line = [];
    for (let column = 0; column < columns; column += 1) {
      const offset = (row * columns + column) * 3;
      line.push({ glyph: String.fromCodePoint(words[offset]), fg: words[offset + 1], bg: words[offset + 2] });
    }
    grid.push(line);
  }
  return grid;
};
// Claude Code's own theme tables: spinner blue water per family, Claude orange boat.
const palettes = raster.CALM_SHIP_RASTER_PALETTES;
check(palettes.dark.water === 0x93a5ff && palettes.dark.boat === 0xd77757, "dark palette is not Claude Code's dark spinner blue and Claude orange");
check(palettes.light.water === 0x5769f7 && palettes.light.boat === 0xd77757, "light palette is not Claude Code's light spinner blue and Claude orange");
check(palettes.dark.plain === raster.CALM_SHIP_RASTER_DEFAULT_COLOR && palettes.light.plain === raster.CALM_SHIP_RASTER_DEFAULT_COLOR, "plain padding is not the terminal default");
for (const [theme, family] of [["dark", "dark"], ["dark-ansi", "dark"], ["dark-daltonized", "dark"], ["light", "light"], ["light-ansi", "light"], ["light-daltonized", "light"], ["auto", "light"], ["custom:rose", "light"], [undefined, "light"], [42, "light"], ["", "light"]]) {
  check(raster.calmShipPaletteFamily(theme) === family, \`theme \${JSON.stringify(theme)} chose \${raster.calmShipPaletteFamily(theme)}, not \${family}\`);
}
for (const [family, colors] of Object.entries(palettes)) for (const width of [1, 2, 3, 4, 5, 20, 77, 512]) {
  const sprite = core.createCalmWorkingShipSprite();
  for (let step = 0; step < 6; step += 1) {
    const frame = sprite.frame(width);
    const packed = raster.packCalmShipRasterCells(frame, width, colors);
    check(packed.rows === frame.length, \`rows \${packed.rows} for a \${frame.length}-row frame\`);
    const grid = decode(packed.cells, width, packed.rows);
    for (let row = 0; row < frame.length; row += 1) {
      let column = 0;
      for (const run of frame[row]) {
        for (const glyph of Array.from(run.text)) {
          const cell = grid[row][column];
          check(cell.glyph === glyph, \`glyph mismatch at \${row},\${column}: \${cell.glyph} vs \${glyph}\`);
          check(cell.fg === colors[run.color], \`\${family} color mismatch at \${row},\${column}\`);
          column += 1;
        }
      }
      for (; column < width; column += 1) {
        check(grid[row][column].glyph === " " && grid[row][column].fg === colors.plain, \`padding at \${row},\${column} is not a plain space\`);
      }
      check(grid[row].every((cell) => cell.bg === raster.CALM_SHIP_RASTER_DEFAULT_COLOR), "a background was set");
      check(grid[row].every((cell) => cell.glyph.codePointAt(0) <= 0xffff), "a glyph left the BMP");
    }
    sprite.tick();
  }
}
// The packer's pre-load default is the both-readable light fallback.
{
  const packed = raster.packCalmShipRasterCells([[{ text: "▁", color: "water" }]], 1);
  check(decode(packed.cells, 1, 1)[0][0].fg === palettes.light.water, "the default packing palette is not the light fallback");
}
// A run wider than the grid is clipped, never wrapped into the next row.
{
  const packed = raster.packCalmShipRasterCells([[{ text: "▁▁▁▁▁▁▁▁", color: "water" }], [{ text: "◿│◣", color: "boat" }]], 4);
  check(packed.rows === 2, "clip changed the row count");
  const grid = decode(packed.cells, 4, 2);
  check(grid[0].map((c) => c.glyph).join("") === "▁▁▁▁" && grid[1].map((c) => c.glyph).join("") === "◿│◣ ", "clip wrapped or dropped cells");
}
check(raster.packCalmShipRasterCells([], 3).rows === 1, "an empty frame did not pack one blank row");
check(raster.calmShipRasterColumns(undefined) === 78, "unmeasured viewport width");
check(raster.calmShipRasterColumns(160) === 158, "measured viewport width");
check(raster.calmShipRasterColumns(2) === 1 && raster.calmShipRasterColumns(-5) === 1, "narrow viewport floor");
check(raster.calmShipRasterColumns(10000) === 512, "raster width ceiling");
console.log("raster-ok");
JS
  out=$(run_node "$TMP_ROOT/raster.mjs" 2>&1) || fail "raster packing: $out"
  assert_contains "$out" "raster-ok" "the raster packing check did not complete"
  pass "the Raster packing lays the shared frame out row-major in Claude Code's dark or light theme palette, using light as the both-readable fallback, with plain padding, default backgrounds, BMP glyphs, clipping, and a standard base64 encoding"
}

test_presentation_policy() {
  local out
  cat >"$TMP_ROOT/policy.mjs" <<JS
import { pathToFileURL } from "node:url";
const policy = await import(pathToFileURL($(js_string "$MOD") + "/lib/fm-calm-presentation.ts").href);
const piPreservation = await import(pathToFileURL($(js_string "$ROOT") + "/.pi/extensions/lib/fm-calm-preservation.ts").href);
const check = (condition, message) => { if (!condition) throw new Error(message); };
const plugin = "/repo/.claude/mods/firstmate-calm";
check(policy.calmPreferencePath({}, plugin) === "/repo/config/calm", "plugin-root fallback");
check(policy.calmPreferencePath({}, "/repo/.claude/skills/firstmate-calm/") === "/repo/config/calm", "trailing slash on the plugin root");
check(policy.calmPreferencePath({}, "/repo/.agents/skills/firstmate-calm") === "/repo/config/calm", ".agents/skills spelling of the plugin root");
check(policy.calmCodeRootFromPluginRoot("C:\\\\fm\\\\.claude\\\\mods\\\\firstmate-calm") === "C:\\\\fm", "Windows separators");
check(policy.calmPreferencePath({ FM_ROOT_OVERRIDE: "/override/root" }, plugin) === "/override/root/config/calm", "FM_ROOT_OVERRIDE");
check(policy.calmPreferencePath({ FM_HOME: "/home/fm", FM_ROOT_OVERRIDE: "/override/root" }, plugin) === "/home/fm/config/calm", "FM_HOME beats FM_ROOT_OVERRIDE");
check(policy.calmPreferencePath({ FM_HOME: "/home/fm", FM_CONFIG_OVERRIDE: "/cfg" }, plugin) === "/cfg/calm", "FM_CONFIG_OVERRIDE beats the home");
check(policy.calmPreferencePath({ FM_HOME: "" }, plugin) === "/repo/config/calm", "an empty FM_HOME reads as unset");
for (const [stored, expected] of [["on\\n", true], ["on", true], [" on \\n", true], ["max\\n", true], ["off\\n", false], ["", false], [undefined, false], ["ON", false], ["maybe", false]]) {
  check(policy.parseCalmPreference(stored) === expected, \`preference \${JSON.stringify(stored)}\`);
}
check(policy.serializeCalmPreference(true) === "on\\n" && policy.serializeCalmPreference(false) === "off\\n", "serialized values");
const shortNote = "Checking briefly.";
const multiLineReply = "The result is substantive.\\nHere is the context needed to continue.";
const atThresholdReply = "x".repeat(240);
const belowThresholdNote = "x".repeat(239);
check(policy.CALM_PRESERVE_MIN_CHARS === 240, "Claude preservation threshold");
check(piPreservation.CALM_PRESERVE_MIN_CHARS === policy.CALM_PRESERVE_MIN_CHARS, "Pi and Claude preservation thresholds");
for (const [text, expectedPreserved, label] of [
  [belowThresholdNote, false, "239-character single line"],
  [atThresholdReply, true, "240-character single line"],
  [multiLineReply, true, "multi-line text"],
]) {
  const claudePreserved = !policy.stepTextIsWorkingNote({ stopReason: "tool_use", toolUses: [] }, text);
  const piPreserved = piPreservation.calmTextIsSubstantive(text);
  check(claudePreserved === expectedPreserved, "Claude did not classify " + label + " as expected");
  check(piPreserved === expectedPreserved, "Pi did not classify " + label + " as expected");
}
check(policy.stepTextIsWorkingNote({ stopReason: "tool_use", toolUses: [] }, shortNote) === true, "short single-line tool_use note");
check(policy.stepTextIsWorkingNote({ stopReason: "tool_use", toolUses: [] }, multiLineReply) === false, "multi-line tool_use reply");
check(policy.stepTextIsWorkingNote({ stopReason: "tool_use", toolUses: [] }, atThresholdReply) === false, "threshold-length tool_use reply");
check(policy.stepTextIsWorkingNote({ stopReason: "tool_use", toolUses: [] }, belowThresholdNote) === true, "just-under-threshold tool_use note");
check(policy.stepTextIsWorkingNote({ stopReason: "max_tokens", toolUses: [{}] }, shortNote) === true, "max_tokens with tools");
check(policy.stepTextIsWorkingNote({ stopReason: "max_tokens", toolUses: [] }, shortNote) === false, "max_tokens without tools");
check(policy.stepTextIsWorkingNote({ stopReason: "end_turn", toolUses: [{}] }, shortNote) === false, "end_turn");
check(policy.stepTextIsWorkingNote({ stopReason: null, toolUses: [] }, shortNote) === false, "no response");
check(policy.workingNoteKey("  note \\n") === "note\\n" && policy.workingNoteKey(" note ") === "note" && policy.workingNoteKey("   ") === "", "note key");
const restored = policy.classifyRestoredTranscript([
  { role: "user", text: "go", toolUses: [] },
  { role: "assistant", text: " own call ", toolUses: [{}] },
  { role: "assistant", text: "before a tool row", toolUses: [] },
  { role: "assistant", text: "", toolUses: [{}] },
  { role: "assistant", text: "final", toolUses: [] },
  { role: "user", text: "again", toolUses: [] },
  { role: "assistant", text: "collision", toolUses: [{}] },
  { role: "assistant", text: "collision", toolUses: [] },
  { role: "user", text: "last", toolUses: [] },
  { role: "assistant", text: "plain reply", toolUses: [] },
  { role: "user", text: "multi-line case", toolUses: [] },
  { role: "assistant", text: multiLineReply, toolUses: [] },
  { role: "assistant", text: "", toolUses: [{}] },
  { role: "user", text: "threshold case", toolUses: [] },
  { role: "assistant", text: atThresholdReply, toolUses: [] },
  { role: "assistant", text: "", toolUses: [{}] },
  { role: "user", text: "below-threshold case", toolUses: [] },
  { role: "assistant", text: belowThresholdNote, toolUses: [] },
  { role: "assistant", text: "", toolUses: [{}] },
  { role: "user", text: "newline collision", toolUses: [] },
  { role: "assistant", text: "Checking.\\n", toolUses: [] },
  { role: "assistant", text: "", toolUses: [{}] },
  { role: "user", text: "single-line collision", toolUses: [] },
  { role: "assistant", text: "Checking.", toolUses: [] },
  { role: "assistant", text: "", toolUses: [{}] },
]);
check(JSON.stringify(restored.workingNotes) === JSON.stringify(["own call", "before a tool row", belowThresholdNote, "Checking."]), \`restored notes \${JSON.stringify(restored.workingNotes)}\`);
check(JSON.stringify(restored.finalReplies) === JSON.stringify(["final", "collision", "plain reply", multiLineReply + "\\n", atThresholdReply, "Checking.\\n"]), \`restored final replies \${JSON.stringify(restored.finalReplies)}\`);
check(policy.userTextIsOperational("\\u2063FIRSTMATE_OP: v1 watcher: x") && !policy.userTextIsOperational("hello"), "operational recognition");
console.log("policy-ok");
JS
  out=$(run_node "$TMP_ROOT/policy.mjs" 2>&1) || fail "presentation policy: $out"
  assert_contains "$out" "policy-ok" "the policy check did not complete"
  pass "the Calm policy resolves the shared preference exactly as Pi does, reads on, max, and off as Pi does, and shares Pi's 240-character-or-newline preservation behavior while classifying working notes by stop reason, tool use, and restored transcript shape"
}

test_branch_notes_over_the_store_owner() {
  local home state out
  home="$TMP_ROOT/notes-home"
  state="$home/state"
  mkdir -p "$state"
  outcome() { FM_HOME="$home" bash "$ROOT/bin/fm-branch-outcome.sh" "$@" >/dev/null || fail "fm-branch-outcome.sh $1 failed"; }
  outcome append --task fm-a --verdict routine --summary 'worker healthy, "quoted"'
  outcome append --task fm-b --verdict routine --summary 'no change' --silent true
  outcome append --task fm-c --verdict captain --summary $'PR https://example.test/pr/3 green\nmerge?'
  outcome append --task fm-d --verdict captain --summary 'decision answered'
  outcome mark-read --through 4
  outcome mark-processed --through 4
  outcome append --task fm-e --verdict routine --summary 'reconciled the backlog'
  # A home whose store predates the tail copy gains it at its next session start, and the
  # session-start drain may read a routine row before the mod first sees that copy.
  rm -f "$state/.branch-outcomes-tail.jsonl"
  cp "$state/.branch-outcomes-cursor" "$TMP_ROOT/notes-start-cursor"
  outcome seed-tail
  [ -s "$state/.branch-outcomes-tail.jsonl" ] || fail "seed-tail did not create the display tail copy"
  outcome mark-read --through 5
  cat >"$TMP_ROOT/notes.mjs" <<'JS'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const notes = await import(pathToFileURL(`${process.env.NOTES_MOD}/lib/fm-branch-notes.ts`).href);
const check = (condition, message) => { if (!condition) throw new Error(message); };
const same = (actual, expected, message) => check(JSON.stringify(actual) === JSON.stringify(expected), `${message}: ${JSON.stringify(actual)}`);
const state = process.env.NOTES_STATE;
const read = (name) => readFileSync(`${state}/${name}`, "utf8");
const plugin = "/repo/.claude/mods/firstmate-calm";
same(notes.firstmateStateDirectory({}, plugin), "/repo/state", "code-root fallback");
same(notes.firstmateStateDirectory({ FM_ROOT_OVERRIDE: "/r", FM_HOME: "/h" }, plugin), "/h/state", "FM_HOME beats FM_ROOT_OVERRIDE");
same(notes.firstmateStateDirectory({ FM_HOME: "/h", FM_STATE_OVERRIDE: "/s" }, plugin), "/s", "FM_STATE_OVERRIDE beats the home");
// A torn last line, as a reader racing a writer that is not atomic would see, is skipped.
const rows = notes.parseOutcomeTail(read(".branch-outcomes-tail.jsonl") + '{"seq":6,"epoch":');
same(rows.map((row) => row.seq), [1, 2, 3, 4, 5], "rows the store owner wrote");
same(rows.map(notes.outcomeNoteLine), [
  '⛵ fm-a: worker healthy, "quoted"',
  undefined,
  "⚓ [seq 3] fm-c: PR https://example.test/pr/3 green merge?",
  "⚓ [seq 4] fm-d: decision answered",
  "⛵ fm-e: reconciled the backlog",
], "Pi's line for each row");
const cursor = notes.parseOutcomeMarker(readFileSync(process.env.NOTES_START_CURSOR, "utf8"));
same(notes.replayOutcomeNotes(rows, notes.parseOutcomeMarker(read(".branch-outcomes-cursor")), 4), [],
  "the markers after the drain read seq 5 would drop its sailboat, so the replay judges by the session-start cursor");
same(notes.replayOutcomeNotes(rows, cursor, notes.parseOutcomeMarker(read(".branch-outcomes-processed"))),
  ["⛵ fm-e: reconciled the backlog"], "replay after main processed seq 4");
same(notes.replayOutcomeNotes(rows, cursor, notes.parseOutcomeMarker(undefined)),
  ["⚓ [seq 3] fm-c: PR https://example.test/pr/3 green merge?", "⚓ [seq 4] fm-d: decision answered", "⛵ fm-e: reconciled the backlog"],
  "an absent processed marker replays every captain row, the safe direction");
for (const bad of ["", "x", "07", "-1", "99999999999999999999"]) same(notes.parseOutcomeMarker(bad), 0, `marker ${bad}`);
const many = Array.from({ length: 25 }, (_, i) => ({ seq: i + 1, epoch: 0, task: `t${i + 1}`, verdict: "routine", summary: "s", silent: false }));
const replay = notes.replayOutcomeNotes(many, 0, 0);
same(replay.length, 21, "replay bound");
same(replay[0], "⛵ 5 earlier supervision notes not replayed; bin/fm-branch-outcome.sh list shows them", "omitted count");
same(replay[1], "⛵ t6: s", "the newest rows are kept");
same(notes.newOutcomeNotes(rows, 4), { lines: ["⛵ fm-e: reconciled the backlog"], lastSeen: 5 }, "rows above the anchor");
same(notes.newOutcomeNotes(rows, 5), { lines: [], lastSeen: 5 }, "nothing new");
same(notes.newOutcomeNotes(rows.slice(0, 2), 5), { lines: [], lastSeen: 2 }, "a replaced store re-anchors without replay");
same(notes.newOutcomeNotes(rows.slice(2), 1), {
  lines: [
    "⛵ 1 earlier supervision outcome not shown; bin/fm-branch-outcome.sh list shows them",
    "⚓ [seq 3] fm-c: PR https://example.test/pr/3 green merge?",
    "⚓ [seq 4] fm-d: decision answered",
    "⛵ fm-e: reconciled the backlog",
  ],
  lastSeen: 5,
}, "rows that left the tail before a poll are counted, not dropped silently");
same(notes.replayOutcomeNotes(rows, cursor, 0, 3), ["⚓ [seq 4] fm-d: decision answered", "⛵ fm-e: reconciled the backlog"],
  "rows this session already showed are not replayed on resume");
same(notes.replayOutcomeNotes(rows, cursor, 0, 99).length, 3, "a shown sequence past the tail is a replaced store");
let stored = notes.recordSessionShownThrough(undefined, "s1", 4);
stored = notes.recordSessionShownThrough(stored, "s2", 7);
stored = notes.recordSessionShownThrough(stored, "s1", 9);
same(stored, [["s2", 7], ["s1", 9]], "one entry per session, newest last");
same([notes.sessionShownThrough(stored, "s1"), notes.sessionShownThrough(stored, "s3"), notes.sessionShownThrough("junk", "s1")], [9, 0, 0], "shown lookups");
for (let i = 0; i < 30; i += 1) stored = notes.recordSessionShownThrough(stored, `x${i}`, i + 1);
same([stored.length, stored[stored.length - 1]], [20, ["x29", 30]], "the store keeps the newest 20 sessions");
const health = (key, cooldown) => notes.parseHostHealth(`key=${key}\nerrors=2\ncooldown=${cooldown}\nretry_after=9\n`);
const paused = "⛵ Supervision session paused after repeated engine errors; main will handle wakes while it cools down.";
const recovered = "⛵ Supervision session recovered after a successful cooldown probe.";
same(notes.parseHostHealth(undefined), undefined, "no latch file");
same(notes.hostHealthNote(health("k", 0), health("k", 300)), paused, "trip");
same(notes.hostHealthNote(health("k", 300), health("k", 600)), undefined, "a longer cooldown is not a new trip");
same(notes.hostHealthNote(health("k", 600), health("k", 0)), recovered, "recovery");
same(notes.hostHealthNote(health("k", 300), health("k2", 0)), undefined, "a new main session's fresh latch");
same(notes.hostHealthNote(health("k", 0), health("k2", 300)), paused, "a trip under a new key");
console.log("notes-ok");
JS
  out=$(NOTES_MOD=$MOD NOTES_STATE=$state NOTES_START_CURSOR=$TMP_ROOT/notes-start-cursor run_node "$TMP_ROOT/notes.mjs" 2>&1) || fail "supervision notes: $out"
  assert_contains "$out" "notes-ok" "the supervision notes check did not complete"
  pass "the supervision notes read the store owner's tail copy and markers as Pi does: sailboat and anchor lines, silent rows skipped, bounded replay of unread and unprocessed rows not already shown in the session, and latch notes"
}

# The classifier parity corpus: envelopes the shell owner encodes itself, its legacy
# shapes, and near misses. Each case is one file so multi-line bodies stay exact.
canonical_generic_kinds() {
  bash -c '. "$1"; printf "%s\n" "$FM_OPERATIONAL_KINDS"' firstmate "$OPERATIONAL_INPUT"
}

write_parity_corpus() {
  local dir=$1 kind index=0 body generic_kinds
  mkdir -p "$dir"
  generic_kinds=$(canonical_generic_kinds) || fail "could not read generic kinds from the operational-input owner"
  [ -n "$generic_kinds" ] || fail "the operational-input owner exposes no generic kinds"
  for kind in $generic_kinds; do
    for body in 'plain body' $'multi\nline\n\nbody' $'trailing newline\n' $'two trailing newlines\n\n' 'colon: inside: body' 'ünïcödé body ✓' ' '; do
      index=$((index + 1))
      printf '%s' "$body" | "$OPERATIONAL_INPUT" encode "$kind" >"$dir/case-$index.txt" \
        || fail "the owner could not encode kind $kind for the parity corpus"
    done
  done
  for body in 'plain body' $'multi\nline\n\nbody' $'trailing newline\n' $'two trailing newlines\n\n' 'colon: inside: body' 'ünïcödé body ✓' ' '; do
    index=$((index + 1))
    printf '%s' "$body" | "$OPERATIONAL_INPUT" encode from-firstmate >"$dir/case-$index.txt" \
      || fail "the owner could not encode from-firstmate for the parity corpus"
  done
  for body in \
    'Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.' \
    'Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions. ' \
    $'FIRSTMATE WATCHER WAKE: signal: x\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.' \
    $'FIRSTMATE WATCHER WAKE: \n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.' \
    $'TURN WOULD END BLIND - supervision is off. The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\nrecover' \
    $'TURN WOULD END BLIND - supervision is off. The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n' \
    $'\xE2\x81\xA3Supervisor escalate (' \
    $'\xE2\x81\xA3Supervisor escalate (needs you)' \
    $'\xE2\x81\xA3FIRSTMATE_OP: untyped legacy' \
    $'\xE2\x81\xA3FIRSTMATE_OP: ' \
    $'\xE2\x81\xA3FIRSTMATE_OP: v1 watcher:' \
    $'\xE2\x81\xA3FIRSTMATE_OP: v1 watcher: ' \
    $'\xE2\x81\xA3FIRSTMATE_OP: v1 bogus: body' \
    $'\xE2\x81\xA3FIRSTMATE_OP: v2 watcher: body' \
    $'\xE2\x81\xA3FIRSTMATE_OP: v1 watcher: : x' \
    $'\xE2\x81\xA3FIRSTMATE_OP:v1 watcher: body' \
    $'[fm-from-firstmate]\xE2\x81\xA3' \
    $'[fm-from-firstmate]\xE2\x81\xA3x' \
    '[fm-from-firstmate] no separator' \
    "'"$'\xE2\x81\xA3'"FIRSTMATE_OP: v1 watcher: quoted'" \
    'FIRSTMATE_OP: v1 watcher: ascii only' \
    $'text before \xE2\x81\xA3FIRSTMATE_OP: v1 watcher: body' \
    $'\xE2\x81\xA3' \
    $'\xE2\x81\xA3unrelated' \
    'hello there' \
    '' \
    $'\n' \
    'signal: /tmp/x.status changed'
  do
    index=$((index + 1))
    printf '%s' "$body" >"$dir/case-$index.txt"
  done
  printf '%s\n' "$index"
}

test_classifier_parity_with_shell_owner() {
  local corpus count out shell_verdict port_verdict mismatches=0 compared=0 index file generic_kinds kind
  corpus="$TMP_ROOT/corpus"
  count=$(write_parity_corpus "$corpus")
  cat >"$TMP_ROOT/classify.mjs" <<JS
import { pathToFileURL } from "node:url";
import { readFileSync, writeFileSync } from "node:fs";
const port = await import(pathToFileURL($(js_string "$MOD") + "/lib/fm-operational-input.ts").href);
const corpus = $(js_string "$corpus");
const count = ${count};
const lines = [];
for (let index = 1; index <= count; index += 1) {
  const text = readFileSync(\`\${corpus}/case-\${index}.txt\`, "utf8");
  lines.push(\`\${index}\\t\${port.classifyFirstmateOperationalText(text) ?? "none"}\`);
}
writeFileSync(\`\${corpus}/port-verdicts.tsv\`, lines.join("\\n") + "\\n");
console.log("classified " + count);
JS
  out=$(run_node "$TMP_ROOT/classify.mjs" 2>&1) || fail "classifier port: $out"
  assert_contains "$out" "classified $count" "the port did not classify the whole corpus"
  index=1
  while [ "$index" -le "$count" ]; do
    file="$corpus/case-$index.txt"
    if shell_verdict=$("$OPERATIONAL_INPUT" classify <"$file" 2>/dev/null); then
      :
    else
      shell_verdict=none
    fi
    port_verdict=$(awk -F '\t' -v i="$index" '$1 == i { print $2 }' "$corpus/port-verdicts.tsv")
    compared=$((compared + 1))
    if [ "$shell_verdict" != "$port_verdict" ]; then
      mismatches=$((mismatches + 1))
      printf 'parity mismatch on case %s: shell=%s port=%s text=%s\n' "$index" "$shell_verdict" "$port_verdict" "$(od -c "$file" | head -3 | tr '\n' ' ')" >&2
    fi
    index=$((index + 1))
  done
  [ "$compared" -eq "$count" ] || fail "compared $compared of $count parity cases"
  [ "$mismatches" -eq 0 ] || fail "the TypeScript classifier diverged from bin/fm-operational-input.sh on $mismatches of $count cases"
  # The corpus must exercise every current kind and the legacy shapes, or parity is vacuous.
  generic_kinds=$(canonical_generic_kinds) || fail "could not reread generic kinds from the operational-input owner"
  [ -n "$generic_kinds" ] || fail "the operational-input owner exposes no generic kinds"
  for kind in $generic_kinds from-firstmate legacy-operational; do
    grep -q "	$kind\$" "$corpus/port-verdicts.tsv" || fail "the parity corpus never produced the $kind verdict"
  done
  grep -q '	none$' "$corpus/port-verdicts.tsv" || fail "the parity corpus never produced a non-operational verdict"
  pass "the mod's operational-input classifier agrees with bin/fm-operational-input.sh on all $count corpus cases: every current kind the owner encodes, every legacy shape, and every near miss"
}

# The record-backed doorbell: the port's parse plus its record classification must match
# the owner's doorbell-kind on doorbells the owner itself writes and on every near miss.
test_doorbell_parity_with_shell_owner() {
  local dir state inbox doorbell index=0 count out shell_verdict port_verdict mismatches=0 kind
  dir="$TMP_ROOT/doorbells"
  state="$dir/home/state"
  inbox="$state/operational-inbox"
  mkdir -p "$state"
  for kind in $(canonical_generic_kinds); do
    index=$((index + 1))
    printf 'body for %s' "$kind" | FM_STATE_OVERRIDE="$state" "$OPERATIONAL_INPUT" record "$kind" \
      | tr -d '\n' >"$dir/case-$index.txt" || fail "the owner could not publish a $kind record"
  done
  doorbell=$(cat "$dir/case-1.txt")
  printf 'FIRSTMATE_OP: v1 watcher: ascii only' >"$inbox/9-ascii.msg"
  printf '\342\201\243FIRSTMATE_OP: v1 bogus: body' >"$inbox/9-bogus.msg"
  printf '\342\201\243FIRSTMATE_OP: legacy untyped' >"$inbox/9-legacy.msg"
  printf '[fm-from-firstmate]\342\201\243routed' >"$inbox/9-routed.msg"
  mkdir -p "$dir/elsewhere"
  printf '\342\201\243FIRSTMATE_OP: v1 watcher: x' >"$dir/elsewhere/9-x.msg"
  for out in \
    "$inbox/9-ascii.msg" "$inbox/9-bogus.msg" "$inbox/9-legacy.msg" "$inbox/9-routed.msg" \
    "$inbox/9-missing.msg" "$dir/elsewhere/9-x.msg" "$inbox/9-UPPER.msg" "$inbox/9_x.msg" \
    "$inbox/.msg" "$inbox/9-x.txt" "relative/operational-inbox/9-x.msg" "$inbox/9 x.msg" \
    "$inbox/it's.msg" "$inbox/9-é.msg"; do
    index=$((index + 1))
    printf ": Firstmate operational input waiting: read '%s' and handle its contents as Firstmate operational input." "$out" \
      >"$dir/case-$index.txt"
  done
  for out in "$doorbell " " $doorbell" "${doorbell%.}" "$doorbell"$'\n' \
    ": Firstmate operational input waiting: read '' and handle its contents as Firstmate operational input." \
    ": Firstmate operational input waiting: read ' and handle its contents as Firstmate operational input." \
    'FIRSTMATE_OP: v1 away-supervisor: typed by a human' ''; do
    index=$((index + 1))
    printf '%s' "$out" >"$dir/case-$index.txt"
  done
  count=$index
  cat >"$TMP_ROOT/doorbells.mjs" <<JS
import { pathToFileURL } from "node:url";
import { readFileSync, writeFileSync } from "node:fs";
const port = await import(pathToFileURL($(js_string "$MOD") + "/lib/fm-operational-input.ts").href);
const dir = $(js_string "$dir");
const lines = [];
for (let index = 1; index <= ${count}; index += 1) {
  const record = port.firstmateOperationalDoorbellPath(readFileSync(\`\${dir}/case-\${index}.txt\`, "utf8"));
  let content;
  try {
    content = record === undefined ? undefined : readFileSync(record, "utf8");
  } catch {
    content = undefined;
  }
  lines.push(\`\${index}\\t\${(content === undefined ? undefined : port.firstmateOperationalRecordKind(content)) ?? "none"}\`);
}
writeFileSync(\`\${dir}/port-verdicts.tsv\`, lines.join("\\n") + "\\n");
console.log("classified ${count}");
JS
  out=$(run_node "$TMP_ROOT/doorbells.mjs" 2>&1) || fail "doorbell port: $out"
  assert_contains "$out" "classified $count" "the port did not classify every doorbell case"
  index=1
  while [ "$index" -le "$count" ]; do
    shell_verdict=$("$OPERATIONAL_INPUT" doorbell-kind <"$dir/case-$index.txt" 2>/dev/null) || shell_verdict=none
    port_verdict=$(awk -F '\t' -v i="$index" '$1 == i { print $2 }' "$dir/port-verdicts.tsv")
    if [ "$shell_verdict" != "$port_verdict" ]; then
      mismatches=$((mismatches + 1))
      printf 'doorbell parity mismatch on case %s: shell=%s port=%s text=%s\n' "$index" "$shell_verdict" "$port_verdict" "$(cat "$dir/case-$index.txt")" >&2
    fi
    index=$((index + 1))
  done
  [ "$mismatches" -eq 0 ] || fail "the TypeScript doorbell port diverged from bin/fm-operational-input.sh on $mismatches of $count cases"
  for kind in $(canonical_generic_kinds); do
    grep -q "	$kind\$" "$dir/port-verdicts.tsv" || fail "the doorbell corpus never produced the $kind verdict"
  done
  grep -q '	none$' "$dir/port-verdicts.tsv" || fail "the doorbell corpus never produced a non-operational verdict"
  pass "the mod's doorbell port agrees with bin/fm-operational-input.sh doorbell-kind on all $count cases: every record the owner writes and every unbacked or malformed near miss"
}

test_plugin_shape
test_shared_sprite_and_pi_rendering
test_raster_packing
test_presentation_policy
test_branch_notes_over_the_store_owner
test_classifier_parity_with_shell_owner
test_doorbell_parity_with_shell_owner
