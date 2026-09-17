#!/usr/bin/env bash
# Portable checks for the OpenCode Calm TUI plugin that need no OpenCode binary:
#   - tracked TUI registration and the sprite symlink to the shared core;
#   - home-local preference path, parse/serialize, atomic persist, and failed-write
#     leaving the current choice unchanged;
#   - working-strip presentation: busy/retry show, idle hide, freeze on hide,
#     resume in the same session, reset on a different session, ticks ignored while hidden.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLUGIN="$ROOT/.opencode/plugins/fm-calm.js"
PREF="$ROOT/.opencode/plugins/lib/fm-calm-preference.js"
PRES="$ROOT/.opencode/plugins/lib/fm-calm-presentation.js"
SPRITE="$ROOT/.opencode/plugins/lib/fm-calm-working-ship-sprite.ts"
CORE="$ROOT/.claude/mods/firstmate-calm/lib/fm-calm-working-ship-sprite.ts"
TUI_JSON="$ROOT/.opencode/tui.json"
TMP_ROOT=$(fm_test_tmproot fm-calm-opencode-tui)

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the OpenCode Calm TUI checks"; exit 0; }

test_plugin_shape() {
  local out
  [ -f "$PLUGIN" ] || fail "the OpenCode Calm TUI plugin is missing"
  [ -L "$SPRITE" ] || fail "the OpenCode sprite path is not a symlink to the shared core"
  [ "$(node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$SPRITE")" = \
    "$(node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$CORE")" ] \
    || fail "the OpenCode sprite path does not resolve to the shared core"
  out=$(
    TUI_JSON="$TUI_JSON" PLUGIN="$PLUGIN" node --input-type=module <<'JS'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const check = (condition, message) => { if (!condition) throw new Error(message); };
const tui = JSON.parse(readFileSync(process.env.TUI_JSON, "utf8"));
check(Array.isArray(tui.plugin) && tui.plugin.includes("./plugins/fm-calm.js"), "tui.json does not list the Calm plugin");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
check(mod.default?.id === "fm.calm", "plugin id");
check(typeof mod.default?.tui === "function", "tui export");
check(!("server" in mod.default), "server export would make the module target-ambiguous");
console.log("shape-ok");
JS
  ) || fail "plugin shape: $out"
  assert_contains "$out" "shape-ok" "plugin shape check did not complete"
  pass "the OpenCode Calm plugin is a TUI-only module listed in tui.json, with the shared sprite symlink"
}

test_preference() {
  local out
  out=$(
    PREF="$PREF" TMP_ROOT="$TMP_ROOT" node --input-type=module <<'JS'
import { chmodSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
const pref = await import(pathToFileURL(process.env.PREF).href);
const check = (condition, message) => { if (!condition) throw new Error(message); };
const plugin = "/repo/.opencode/plugins/fm-calm.js";
check(pref.calmCodeRootFromPluginFile(plugin) === "/repo", "plugin-file root");
check(pref.calmPreferencePath({}, plugin) === "/repo/config/calm", "plugin-root fallback");
check(pref.calmPreferencePath({ FM_ROOT_OVERRIDE: "/override/root" }, plugin) === "/override/root/config/calm", "FM_ROOT_OVERRIDE");
check(pref.calmPreferencePath({ FM_HOME: "/home/fm", FM_ROOT_OVERRIDE: "/override/root" }, plugin) === "/home/fm/config/calm", "FM_HOME beats FM_ROOT_OVERRIDE");
check(pref.calmPreferencePath({ FM_HOME: "/home/fm", FM_CONFIG_OVERRIDE: "/cfg" }, plugin) === "/cfg/calm", "FM_CONFIG_OVERRIDE beats the home");
check(pref.calmPreferencePath({ FM_HOME: "" }, plugin) === "/repo/config/calm", "an empty FM_HOME reads as unset");
for (const [stored, expected] of [["on\n", true], ["on", true], [" on \n", true], ["max\n", true], ["off\n", false], ["", false], [undefined, false], ["ON", false], ["maybe", false]]) {
  check(pref.parseCalmPreference(stored) === expected, `preference ${JSON.stringify(stored)}`);
}
check(pref.serializeCalmPreference(true) === "on\n" && pref.serializeCalmPreference(false) === "off\n", "serialized values");
check(pref.loadCalmPreference(join(process.env.TMP_ROOT, "missing-calm")) === false, "absent file is off");
const dir = join(process.env.TMP_ROOT, "home", "config");
mkdirSync(dir, { recursive: true });
const path = join(dir, "calm");
pref.persistCalmPreference(path, true);
check(readFileSync(path, "utf8") === "on\n", "persisted on");
check((statSync(path).mode & 0o777) === 0o600, "persisted mode");
pref.persistCalmPreference(path, false);
check(readFileSync(path, "utf8") === "off\n", "persisted off");
const blocked = join(process.env.TMP_ROOT, "blocked");
mkdirSync(blocked);
writeFileSync(join(blocked, "calm"), "on\n");
chmodSync(blocked, 0o500);
let failed = false;
try {
  pref.persistCalmPreference(join(blocked, "calm"), false);
} catch {
  failed = true;
}
chmodSync(blocked, 0o700);
check(failed, "a failed persist did not throw");
check(readFileSync(join(blocked, "calm"), "utf8") === "on\n", "failed persist left the current choice");
console.log("pref-ok");
JS
  ) || fail "preference: $out"
  assert_contains "$out" "pref-ok" "preference check did not complete"
  pass "OpenCode Calm preference resolution, values, atomic persist, and failed-write leave-unchanged match the shared contract"
}

test_presentation() {
  local out
  out=$(
    PRES="$PRES" SPRITE="$SPRITE" node --input-type=module <<'JS'
import { pathToFileURL } from "node:url";
const pres = await import(pathToFileURL(process.env.PRES).href);
const spriteMod = await import(pathToFileURL(process.env.SPRITE).href);
const check = (condition, message) => { if (!condition) throw new Error(message); };
check(pres.calmOpencodePalette("dark").water === "#93a5ff" && pres.calmOpencodePalette("dark").boat === "#d77757", "dark palette");
check(pres.calmOpencodePalette("light").water === "#5769f7", "light water");
check(pres.calmOpencodePalette("auto").water === "#93a5ff", "unknown mode uses dark");
check(pres.calmOpencodeBoatWidth(80) === 36 && pres.calmOpencodeBoatWidth(200) === 56 && pres.calmOpencodeBoatWidth(10) === 14, "boat width clamp");
check(pres.calmOpencodeStatusIsWorking({ type: "busy" }) && pres.calmOpencodeStatusIsWorking({ type: "retry" }), "busy and retry work");
check(!pres.calmOpencodeStatusIsWorking({ type: "idle" }) && !pres.calmOpencodeStatusIsWorking(undefined), "idle and missing do not work");
const fake = () => {
  let position = 0;
  let rendered = 0;
  let ticks = 0;
  let resets = 0;
  let restores = 0;
  return {
    reset() { position = 0; rendered = 0; resets += 1; },
    restoreLastRendered() { position = rendered; restores += 1; },
    tick() { ticks += 1; position += 1; },
    frame(width) { rendered = position; return [[{ text: String(width), color: "water" }]]; },
    stats: () => ({ position, ticks, resets, restores }),
  };
};
const sprite = fake();
const ship = pres.createCalmPresentation(sprite);
ship.setActive(true);
ship.bind("s1");
check(!ship.isShown() && ship.frame(40) === null, "calm on but idle hides");
ship.setStatus("s1", { type: "busy" });
check(ship.isShown() && sprite.stats().resets === 1, "first busy show resets");
check(ship.frame(40)[0][0].text === "40", "frame uses requested width");
ship.tick();
ship.tick();
check(sprite.stats().ticks === 2 && sprite.stats().position === 2, "shown ticks advance");
ship.frame(40);
ship.setStatus("s1", { type: "idle" });
check(!ship.isShown() && sprite.stats().restores === 1, "idle hide freezes");
const ticksAtHide = sprite.stats().ticks;
ship.tick();
check(sprite.stats().ticks === ticksAtHide && sprite.stats().position === 2, "hidden ticks do not advance");
ship.setStatus("s1", { type: "busy" });
check(ship.isShown() && sprite.stats().resets === 1, "same-session re-busy does not reset");
ship.bind("s2");
ship.setStatus("s2", { type: "retry" });
check(ship.shownSession() === "s2" && sprite.stats().resets === 2, "a different session resets");
ship.setActive(false);
check(!ship.isShown(), "calm off hides");
check(spriteMod.CALM_WORKING_SHIP_TICK_MS === 220 && spriteMod.CALM_WORKING_SHIP_TICKS_PER_MOVE === 4, "shared cadence");
console.log("pres-ok");
JS
  ) || fail "presentation: $out"
  assert_contains "$out" "pres-ok" "presentation check did not complete"
  pass "OpenCode Calm shows the boat for busy/retry, freezes while hidden, resumes in-session, and resets on a new session"
}

test_plugin_shape
test_preference
test_presentation
