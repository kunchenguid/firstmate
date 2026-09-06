#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-arm-consumers)
repo="$TMP_ROOT/pi"
mkdir -p \
  "$repo/.pi/extensions/lib" \
  "$repo/node_modules/@earendil-works/pi-coding-agent" \
  "$repo/node_modules/@earendil-works/pi-tui" \
  "$repo/node_modules/typebox"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
printf '%s\n' '{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}' \
  > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json"
printf '%s\n' 'export function getMarkdownTheme() { return {}; } export class UserMessageComponent {}' \
  > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js"
printf '%s\n' '{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}' \
  > "$repo/node_modules/@earendil-works/pi-tui/package.json"
printf '%s\n' 'export class Box {} export class Container {} export class Text {}' \
  > "$repo/node_modules/@earendil-works/pi-tui/index.js"
printf '%s\n' '{"name":"typebox","type":"module","exports":"./index.js"}' \
  > "$repo/node_modules/typebox/package.json"
printf '%s\n' 'export const Type = { Object(properties) { return { properties }; } };' \
  > "$repo/node_modules/typebox/index.js"

PI_PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" \
OPENCODE_PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js" \
NODE_NO_WARNINGS=1 node --input-type=module <<'JS'
import { pathToFileURL } from "node:url";

const pi = await import(pathToFileURL(process.env.PI_PLUGIN).href);
const openCode = await import(pathToFileURL(process.env.OPENCODE_PLUGIN).href);
const marker = "watcher: busy holder pid=42 lock=0s (grace 300s)\nFM_WATCH_ARM_RESULT=busy-holder\n";

for (const [name, classify] of [
  ["Pi", pi.classifyClose],
  ["OpenCode", openCode.classifyArmClose],
]) {
  const benign = classify(marker, "", 0, null);
  if (benign.kind !== "benign") throw new Error(`${name} classified a typed busy holder as ${benign.kind}`);
  const failed = classify(marker, "", 1, null);
  if (failed.kind !== "failure") throw new Error(`${name} suppressed a nonzero arm failure as ${failed.kind}`);
  const unexplained = classify("", "", 0, null);
  if (unexplained.kind !== "failure") throw new Error(`${name} suppressed an unexplained arm close as ${unexplained.kind}`);
}
JS

pass "Pi and OpenCode distinguish typed busy holders from genuine arm failures"
