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
#   - the operational-input classifier's parity with bin/fm-operational-input.sh over
#     envelopes the shell owner itself encodes, its legacy shapes, and near misses.
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
const mod = ${MOD@Q};
const manifest = JSON.parse(readFileSync(\`\${mod}/.claude-plugin/plugin.json\`, "utf8"));
if (manifest.name !== "firstmate-calm") throw new Error(\`manifest name \${manifest.name}\`);
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
const pi = await import(pathToFileURL(${PI_SHIP@Q}).href);
const core = await import(pathToFileURL(${MOD@Q} + "/lib/fm-calm-working-ship-sprite.ts").href);
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
const raster = await import(pathToFileURL(${MOD@Q} + "/lib/fm-calm-ship-raster.ts").href);
const core = await import(pathToFileURL(${MOD@Q} + "/lib/fm-calm-working-ship-sprite.ts").href);
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
const policy = await import(pathToFileURL(${MOD@Q} + "/lib/fm-calm-presentation.ts").href);
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
check(policy.CALM_PRESERVE_MIN_CHARS === 240, "preservation threshold");
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
  pass "the Calm policy resolves the shared preference exactly as Pi does, reads on, max, and off as Pi does, and classifies working notes by stop reason, tool use, and restored transcript shape"
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
const port = await import(pathToFileURL(${MOD@Q} + "/lib/fm-operational-input.ts").href);
const corpus = ${corpus@Q};
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

test_plugin_shape
test_shared_sprite_and_pi_rendering
test_raster_packing
test_presentation_policy
test_classifier_parity_with_shell_owner
