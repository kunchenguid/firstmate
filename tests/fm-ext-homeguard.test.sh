#!/usr/bin/env bash
# tests/fm-ext-homeguard.test.sh - home guard: Pi primary extensions must be
# completely inert when the session cwd is outside the firstmate home they were
# installed in (ONM-1065).
#
# Regression for 2026-07-26 incident: a crewmate Pi session in a non-firstmate
# project (critter_clash) loaded the user-scoped firstmate watcher extension,
# acquired state/.lock, and role-confused into supervisor mode.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ext-homeguard-tests)
WATCH_EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
TURNEND_EXT="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"

export NODE_NO_WARNINGS=1

# ---------------------------------------------------------------------------
# Fixture helpers (mirrors fm-pi-watch-extension.test.sh install helper)
# ---------------------------------------------------------------------------

install_watch_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$WATCH_EXT" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent { render() { return []; } invalidate() {} }
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box { addChild() {} clear() {} setBgFn() {} }
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

install_turnend_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/bin"
  cp "$TURNEND_EXT" "$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent { render() { return []; } invalidate() {} }
JS
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_watch_extension_noop_outside_home() {
  # The watch extension must be completely inert when process.cwd() is not
  # within the directory the extension was installed in (root = 2 levels up
  # from the extension file).
  local repo home plugin foreign_dir arm_log out status
  repo="$TMP_ROOT/homeguard-watch-noop-repo"
  home="$TMP_ROOT/homeguard-watch-noop-home"
  arm_log="$TMP_ROOT/homeguard-watch-noop-arm.log"
  foreign_dir="$TMP_ROOT/homeguard-watch-noop-foreign"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$foreign_dir"
  install_watch_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_ARM_LOG="$arm_log" FOREIGN_DIR="$foreign_dir" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

// Simulate a foreign-project session: cwd is NOT the extension's repo root.
process.chdir(process.env.FOREIGN_DIR);

let toolRegistered = false;
let commandRegistered = false;
let anyEvent = false;
const pi = {
  on() { anyEvent = true; },
  events: { on() {} },
  registerCommand() { commandRegistered = true; },
  registerTool() { toolRegistered = true; },
  sendUserMessage: async () => {},
};
// Write a lock so the extension would try to arm if the guard fails.
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);

// Guard must prevent all side effects.
if (toolRegistered) {
  console.error("home guard failed: watch tool was registered in foreign cwd");
  process.exit(1);
}
if (commandRegistered) {
  console.error("home guard failed: watch command was registered in foreign cwd");
  process.exit(1);
}
if (anyEvent) {
  console.error("home guard failed: Pi events were registered in foreign cwd");
  process.exit(1);
}
const marker = `${process.env.FM_HOME}/state/.pi-watch-extension-loaded`;
if (existsSync(marker)) {
  console.error("home guard failed: watch marker written in foreign cwd");
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "watch extension must be a complete no-op when cwd is outside FM home: $out"
  [ -z "$out" ] || fail "watch noop test printed unexpected output: $out"
  [ ! -f "$arm_log" ] || fail "watch extension spawned arm child despite foreign cwd"
  pass "watch extension is a complete no-op outside FM home"
}

test_watch_extension_active_inside_home() {
  # The watch extension must work normally when process.cwd() equals the
  # extension's repo root (2 levels up from the extension file).
  local repo home plugin arm_log stop out status
  repo="$TMP_ROOT/homeguard-watch-active-repo"
  home="$TMP_ROOT/homeguard-watch-active-home"
  arm_log="$TMP_ROOT/homeguard-watch-active-arm.log"
  stop="$TMP_ROOT/homeguard-watch-active.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_watch_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_ARM_LOG="$arm_log" FM_STOP_FILE="$stop" REPO="$repo" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

// Simulate a legitimate firstmate-home session: cwd IS the extension's repo root.
process.chdir(process.env.REPO);

let tool = null;
const pi = {
  on() {},
  events: { on() {} },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);

if (!tool) {
  console.error("guard over-fired: watch tool not registered in home cwd");
  process.exit(1);
}
const result = await tool.execute("tool-call-1", {}, undefined, undefined, {});
if (!result.content[0]?.text.includes("started Pi extension arm child")) {
  console.error(`guard over-fired or arm failed: ${result.content[0]?.text}`);
  process.exit(1);
}
for (let i = 0; i < 200 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("guard over-fired: arm child did not start in home cwd");
  process.exit(1);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_code 0 "$status" "watch extension must work normally when cwd is FM home: $out"
  [ -z "$out" ] || fail "watch active test printed unexpected output: $out"
  pass "watch extension operates normally inside FM home"
}

test_turnend_extension_noop_outside_home() {
  # The turn-end guard must be completely inert in a foreign-cwd session.
  local repo home plugin foreign_dir out status
  repo="$TMP_ROOT/homeguard-turnend-noop-repo"
  home="$TMP_ROOT/homeguard-turnend-noop-home"
  foreign_dir="$TMP_ROOT/homeguard-turnend-noop-foreign"
  mkdir -p "$repo/bin" "$home/state" "$foreign_dir"
  install_turnend_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FOREIGN_DIR="$foreign_dir" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

process.chdir(process.env.FOREIGN_DIR);

let anyEvent = false;
const pi = {
  on() { anyEvent = true; },
  events: { on() {} },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);

if (anyEvent) {
  console.error("home guard failed: turnend events registered in foreign cwd");
  process.exit(1);
}
const marker = `${process.env.FM_HOME}/state/.pi-turnend-extension-loaded`;
if (existsSync(marker)) {
  console.error("home guard failed: turnend marker written in foreign cwd");
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "turn-end extension must be a complete no-op when cwd is outside FM home: $out"
  [ -z "$out" ] || fail "turnend noop test printed unexpected output: $out"
  pass "turn-end extension is a complete no-op outside FM home"
}

test_turnend_extension_active_inside_home() {
  # The turn-end guard must register its event handlers when cwd equals the
  # extension's repo root.
  local repo home plugin out status
  repo="$TMP_ROOT/homeguard-turnend-active-repo"
  home="$TMP_ROOT/homeguard-turnend-active-home"
  mkdir -p "$repo/bin" "$home/state"
  install_turnend_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" REPO="$repo" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

process.chdir(process.env.REPO);

let eventsRegistered = 0;
const pi = {
  on() { eventsRegistered += 1; },
  events: { on() {} },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);

if (eventsRegistered === 0) {
  console.error("guard over-fired: no events registered in home cwd");
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "turn-end extension must register events when cwd is FM home: $out"
  [ -z "$out" ] || fail "turnend active test printed unexpected output: $out"
  pass "turn-end extension registers events inside FM home"
}

test_watch_extension_noop_does_not_acquire_lock() {
  # A guarded-out watch extension must not read or write state/.lock or spawn
  # any lock-acquisition process.
  local repo home plugin foreign_dir out status lock_before lock_after
  repo="$TMP_ROOT/homeguard-lock-noop-repo"
  home="$TMP_ROOT/homeguard-lock-noop-home"
  foreign_dir="$TMP_ROOT/homeguard-lock-noop-foreign"
  mkdir -p "$repo/bin" "$home/state" "$foreign_dir"
  install_watch_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  # Pre-populate lock with an unrelated sentinel pid
  printf '%s\n' "1" > "$home/state/.lock"
  lock_before=$(cat "$home/state/.lock")
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FOREIGN_DIR="$foreign_dir" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

process.chdir(process.env.FOREIGN_DIR);

const pi = {
  on() {},
  events: { on() {} },
  registerCommand() {},
  registerTool() {},
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
EOF
)
  status=$?
  lock_after=$(cat "$home/state/.lock" 2>/dev/null || printf '')
  expect_code 0 "$status" "watch noop must not fail: $out"
  [ "$lock_before" = "$lock_after" ] || fail "home guard failed: lock file was modified in foreign cwd (before=$lock_before after=$lock_after)"
  [ -z "$out" ] || fail "watch lock-noop test printed unexpected output: $out"
  pass "watch extension no-op does not acquire or modify the session lock"
}

test_watch_extension_noop_inside_subdir_of_home() {
  # cwd inside a subdirectory of home (e.g. firstmate/bin) should still pass
  # the guard (startsWith check).
  local repo home plugin subdir arm_log stop out status
  repo="$TMP_ROOT/homeguard-subdir-repo"
  home="$TMP_ROOT/homeguard-subdir-home"
  arm_log="$TMP_ROOT/homeguard-subdir-arm.log"
  stop="$TMP_ROOT/homeguard-subdir.stop"
  subdir="$repo/some-subdir"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$subdir"
  install_watch_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_ARM_LOG="$arm_log" FM_STOP_FILE="$stop" SUBDIR="$subdir" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

// cwd is a subdir of the home repo - guard must allow this.
process.chdir(process.env.SUBDIR);

let tool = null;
const pi = {
  on() {},
  events: { on() {} },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);

if (!tool) {
  console.error("guard over-fired: watch tool not registered when cwd is a subdir of home");
  process.exit(1);
}
const result = await tool.execute("tool-call-subdir", {}, undefined, undefined, {});
if (!result.content[0]?.text.includes("started Pi extension arm child")) {
  console.error(`guard over-fired or arm failed (subdir): ${result.content[0]?.text}`);
  process.exit(1);
}
for (let i = 0; i < 200 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("guard over-fired: arm not started when cwd is subdir of home");
  process.exit(1);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_code 0 "$status" "watch extension must work when cwd is a subdir of home: $out"
  [ -z "$out" ] || fail "watch subdir test printed unexpected output: $out"
  pass "watch extension works when cwd is a subdirectory of FM home"
}

test_tracked_extensions_contain_homeguard() {
  # Static contract: the tracked extension sources must include the home guard
  # function so a deployment that copies them without re-running tests still
  # has the fix.
  local watch_text turnend_text
  watch_text=$(cat "$WATCH_EXT")
  turnend_text=$(cat "$TURNEND_EXT")
  assert_contains "$watch_text" "isAtFirstmateHome" "watch extension missing home guard function"
  assert_contains "$watch_text" "realpathSync(process.cwd())" "watch extension home guard must use realpathSync(cwd)"
  assert_contains "$watch_text" "realpathSync(root)" "watch extension home guard must use realpathSync(root)"
  assert_contains "$watch_text" 'if (!isAtFirstmateHome()) return' "watch extension missing home guard call in default export"
  assert_contains "$turnend_text" "isAtFirstmateHome" "turnend extension missing home guard function"
  assert_contains "$turnend_text" "realpathSync(process.cwd())" "turnend extension home guard must use realpathSync(cwd)"
  assert_contains "$turnend_text" "realpathSync(root)" "turnend extension home guard must use realpathSync(root)"
  assert_contains "$turnend_text" 'if (!isAtFirstmateHome()) return' "turnend extension missing home guard call in default export"
  pass "tracked extensions contain the home guard"
}

test_tracked_extensions_contain_homeguard
test_watch_extension_noop_outside_home
test_watch_extension_active_inside_home
test_watch_extension_noop_does_not_acquire_lock
test_watch_extension_noop_inside_subdir_of_home
test_turnend_extension_noop_outside_home
test_turnend_extension_active_inside_home
