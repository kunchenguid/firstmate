#!/usr/bin/env node
// fm-toon-decode.mjs - decode one TOON document on stdin to one JSON value on
// stdout, using the official @toon-format/toon codec that ships inside every
// installed axi tool (tasks-axi, gh-axi, quota-axi). No new dependency: the
// codec is resolved from the tool's own package directory, found by walking up
// from the real path of the tool binary passed as the single argument.
//
// Usage: fm-toon-decode.mjs <path-to-axi-tool-binary> < input.toon > output.json
//
// Exit 0 with one JSON line on success; exit 1 with a diagnostic on stderr for
// any decode failure or a missing codec; exit 2 for usage errors.
import { realpathSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createInterface } from 'node:readline';

const tool = process.argv[2];
if (!tool) {
  console.error('fm-toon-decode: usage: fm-toon-decode.mjs <axi-tool-binary>');
  process.exit(2);
}

const codecRel = join('node_modules', '@toon-format', 'toon', 'dist', 'index.mjs');
let codec = null;
let start;
try {
  start = dirname(realpathSync(tool));
} catch {
  console.error('fm-toon-decode: cannot resolve tool path: ' + tool);
  process.exit(1);
}
for (let dir = start; ; dir = dirname(dir)) {
  try {
    codec = await import(pathToFileURL(join(dir, codecRel)).href);
    break;
  } catch {
    // keep walking up toward the global node_modules root
  }
  if (dirname(dir) === dir) break;
}
if (!codec || typeof codec.decode !== 'function') {
  console.error('fm-toon-decode: @toon-format/toon codec not found beside ' + tool);
  process.exit(1);
}

let input = '';
for await (const line of createInterface({ input: process.stdin })) input += line + '\n';
try {
  const value = codec.decode(input);
  process.stdout.write(JSON.stringify(value) + '\n');
} catch (err) {
  console.error('fm-toon-decode: invalid TOON: ' + (err && err.message ? err.message : String(err)));
  process.exit(1);
}
