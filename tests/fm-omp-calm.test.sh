#!/usr/bin/env bash
# Portable command behavior; the live companion verifies OMP's rendering seam.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v bun >/dev/null || fail "bun is required"
bun --eval '
import { mock } from "bun:test";
import { strict as assert } from "node:assert";
mock.module("@oh-my-pi/pi-coding-agent/modes/settings", () => ({
  cfgDisplayHideToolActivity: {
    get: settings => settings.hidden,
    set: (settings, value) => {
      if (settings.refuse) throw new Error("write refused");
      settings.hidden = value;
    },
  },
}));
const { default: calm } = await import(process.cwd() + "/extensions/fm-calm-omp/fm-calm-omp.ts");
let command;
const settings = { hidden: false, refuse: false };
const notices = [];
calm({ pi: { settings }, registerCommand(name, value) {
  assert.equal(name, "calm-omp");
  command = value;
} });
const ctx = { hasUI: true, ui: { notify: (message, level) => notices.push({ message, level }) } };
await command.handler("", ctx);
assert.equal(settings.hidden, true);
await command.handler("", ctx);
assert.equal(settings.hidden, false);
await command.handler("unexpected", ctx);
assert.equal(settings.hidden, false);
assert.equal(notices.at(-1).level, "warning");
await command.handler("", { ...ctx, hasUI: false });
assert.equal(settings.hidden, false);
assert.equal(notices.at(-1).level, "warning");
settings.refuse = true;
await command.handler("", ctx);
assert.equal(settings.hidden, false);
assert.equal(notices.at(-1).level, "error");
'
pass "Calm toggles the host setting and rejects invalid or unavailable actions"
