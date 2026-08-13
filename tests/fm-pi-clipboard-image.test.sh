#!/usr/bin/env bash
# Behavior contract for the project-local Pi clipboard-image input bridge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found for Pi clipboard-image extension test"; exit 0; }

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-}
if [ -z "$PI_PACKAGE_DIR" ] && command -v npm >/dev/null 2>&1; then
  PI_PACKAGE_DIR="$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"
fi

TMP_ROOT=$(fm_test_tmproot fm-pi-clipboard-image)
FIXTURE="$TMP_ROOT/fixture"
CLIPBOARD_TMP="$TMP_ROOT/clipboard-temp"
PACKAGE_FIXTURE="$FIXTURE/node_modules/@earendil-works/pi-coding-agent"
mkdir -p "$FIXTURE/.pi/extensions" "$FIXTURE/node_modules/@earendil-works" "$CLIPBOARD_TMP"
cp "$ROOT/.pi/extensions/fm-clipboard-image.ts" "$FIXTURE/.pi/extensions/fm-clipboard-image.ts"
if [ -n "$PI_PACKAGE_DIR" ] && [ -f "$PI_PACKAGE_DIR/package.json" ]; then
  ln -s "$PI_PACKAGE_DIR" "$PACKAGE_FIXTURE"
else
  mkdir -p "$PACKAGE_FIXTURE"
  printf '%s\n' '{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}' \
    > "$PACKAGE_FIXTURE/package.json"
  cat > "$PACKAGE_FIXTURE/index.js" <<'JS'
export async function resizeImage(bytes, mimeType) {
  return { data: Buffer.from(bytes).toString("base64"), mimeType };
}
JS
fi
printf '%s\n' '{"type":"module"}' > "$FIXTURE/package.json"

output_file="$TMP_ROOT/output"
set +e
(
  cd "$FIXTURE" || exit 1
  TMPDIR="$CLIPBOARD_TMP" \
    EXT="$FIXTURE/.pi/extensions/fm-clipboard-image.ts" \
    OUTSIDE="$TMP_ROOT/outside" \
    node --input-type=module
) >"$output_file" 2>&1 <<'JS'
import assert from "node:assert/strict";
import {
  chmod,
  lstat,
  mkdir,
  symlink,
  utimes,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const clipboardTmp = tmpdir();
const outside = process.env.OUTSIDE;
const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64",
);
const name = (id, extension = "png") => `pi-clipboard-${id}.${extension}`;
const ids = {
  stale: "10000000-0000-4000-8000-000000000001",
  fresh: "10000000-0000-4000-8000-000000000002",
  symlink: "10000000-0000-4000-8000-000000000003",
  directory: "10000000-0000-4000-8000-000000000004",
  first: "10000000-0000-4000-8000-000000000005",
  second: "10000000-0000-4000-8000-000000000006",
  injected: "10000000-0000-4000-8000-000000000007",
  malformed: "10000000-0000-4000-8000-000000000008",
  mismatch: "10000000-0000-4000-8000-000000000009",
  outside: "10000000-0000-4000-8000-00000000000a",
  unreadable: "10000000-0000-4000-8000-00000000000b",
};

const handlers = new Map();
const notifications = [];
const pi = {
  on(event, handler) {
    const eventHandlers = handlers.get(event) ?? [];
    eventHandlers.push(handler);
    handlers.set(event, eventHandlers);
  },
};
const extension = await import(`${pathToFileURL(process.env.EXT).href}?test=${Date.now()}`);
extension.default(pi);
assert.equal(handlers.get("session_start")?.length, 1, "extension did not register stale cleanup");
assert.equal(handlers.get("input")?.length, 1, "extension did not register the input transform");
const sessionStart = handlers.get("session_start")[0];
const input = handlers.get("input")[0];
const context = {
  hasUI: true,
  ui: {
    notify(message, level) {
      notifications.push({ message, level });
    },
  },
};
const exists = async (path) => lstat(path).then(() => true, () => false);
const oldTime = new Date(Date.now() - 48 * 60 * 60 * 1000);

// Startup cleanup removes only old regular files in the exact Pi UUID/image family.
const stale = join(clipboardTmp, name(ids.stale));
const fresh = join(clipboardTmp, name(ids.fresh));
const target = join(clipboardTmp, "unrelated-target.png");
const exactSymlink = join(clipboardTmp, name(ids.symlink));
const exactDirectory = join(clipboardTmp, name(ids.directory));
const prefixed = join(clipboardTmp, `not-${name(ids.stale)}`);
const suffixed = join(clipboardTmp, `${name(ids.stale)}.bak`);
const malformedName = join(clipboardTmp, "pi-clipboard-not-a-uuid.png");
for (const path of [stale, fresh, target, prefixed, suffixed, malformedName]) {
  await writeFile(path, png);
}
await symlink(target, exactSymlink);
await mkdir(exactDirectory);
for (const path of [stale, prefixed, suffixed, malformedName, exactDirectory]) {
  await utimes(path, oldTime, oldTime);
}
await sessionStart({}, context);
assert.equal(await exists(stale), false, "stale exact clipboard file was not cleaned");
for (const path of [fresh, target, exactSymlink, exactDirectory, prefixed, suffixed, malformedName]) {
  assert.equal(await exists(path), true, `cleanup touched unrelated, fresh, or non-regular path: ${path}`);
}
assert.equal((await lstat(exactSymlink)).isSymbolicLink(), true, "cleanup followed or removed a symlink");

// Interactive input consumes every valid path, preserves surrounding slash-command text,
// and appends attachments without disturbing images that were already present.
const first = join(clipboardTmp, name(ids.first));
const second = join(clipboardTmp, name(ids.second));
await writeFile(first, png);
await writeFile(second, png);
const existingImage = { type: "image", data: "existing-data", mimeType: "image/jpeg" };
const positive = await input({
  type: "input",
  source: "interactive",
  text: `/skill:inspect before ${first} middle ${second} after`,
  images: [existingImage],
}, context);
assert.equal(positive.action, "transform");
assert.equal(positive.text, "/skill:inspect before  middle  after");
assert.deepEqual(positive.images[0], existingImage, "existing image attachment changed");
assert.equal(positive.images.length, 3, "not every clipboard image was attached");
for (const image of positive.images.slice(1)) {
  assert.equal(image.type, "image");
  assert.equal(image.mimeType, "image/png");
  assert.deepEqual(Buffer.from(image.data, "base64"), png);
}
assert.equal(await exists(first), false, "consumed first clipboard temporary remained");
assert.equal(await exists(second), false, "consumed second clipboard temporary remained");
assert.deepEqual(notifications, [{ message: "Attached 2 clipboard images.", level: "info" }]);
assert.equal(notifications[0].message.includes(clipboardTmp), false, "notification exposed a temporary path");

// Extension-originated input is never interpreted as a clipboard paste.
const injected = join(clipboardTmp, name(ids.injected));
await writeFile(injected, png);
const extensionInput = await input({
  type: "input",
  source: "extension",
  text: `extension says ${injected}`,
}, context);
assert.deepEqual(extensionInput, { action: "continue" });
assert.equal(await exists(injected), true, "extension-originated input consumed a file");

// Invalid data, an extension/content mismatch, and a non-regular exact path remain text and stay on disk.
const malformed = join(clipboardTmp, name(ids.malformed));
const mismatch = join(clipboardTmp, name(ids.mismatch, "jpg"));
await writeFile(malformed, "not an image");
await writeFile(mismatch, png);
const rejectedText = `${malformed} ${mismatch} ${exactSymlink} ${exactDirectory}`;
const rejected = await input({ type: "input", source: "interactive", text: rejectedText }, context);
assert.deepEqual(rejected, { action: "continue" });
for (const path of [malformed, mismatch, exactSymlink, exactDirectory]) {
  assert.equal(await exists(path), true, `unreadable or invalid path was consumed: ${path}`);
}
if (typeof process.getuid === "function" && process.getuid() !== 0) {
  const unreadable = join(clipboardTmp, name(ids.unreadable));
  await writeFile(unreadable, png);
  await chmod(unreadable, 0o000);
  const unreadableResult = await input({
    type: "input",
    source: "interactive",
    text: `keep ${unreadable}`,
  }, context);
  assert.deepEqual(unreadableResult, { action: "continue" });
  assert.equal(await exists(unreadable), true, "unreadable clipboard file was consumed");
  await chmod(unreadable, 0o600);
}

// Paths outside Pi's temporary directory and lookalike basenames are ordinary text.
await mkdir(outside, { recursive: true });
const outsidePath = join(outside, name(ids.outside));
await writeFile(outsidePath, png);
const lookalikeText = [
  outsidePath,
  join(clipboardTmp, `not-${name(ids.outside)}`),
  join(clipboardTmp, `${name(ids.outside)}.bak`),
  join(clipboardTmp, "pi-clipboard-no-uuid.png"),
].join(" ");
const lookalikes = await input({ type: "input", source: "interactive", text: lookalikeText }, context);
assert.deepEqual(lookalikes, { action: "continue" });
assert.equal(await exists(outsidePath), true, "clipboard-looking file outside the temp directory was consumed");

assert.deepEqual(
  await input({ type: "input", source: "interactive", text: "/help" }, context),
  { action: "continue" },
  "ordinary slash command changed",
);
assert.deepEqual(
  await input({ type: "input", source: "interactive", text: "ordinary text" }, context),
  { action: "continue" },
  "ordinary text changed",
);
assert.equal(notifications.length, 1, "rejected inputs produced an attachment notification");
JS
status=$?
set -e
[ "$status" -eq 0 ] || fail "Pi clipboard-image behavior failed: $(cat "$output_file")"
[ ! -s "$output_file" ] || fail "Pi clipboard-image behavior printed output: $(cat "$output_file")"
pass "Pi clipboard-image input attaches exact temporary images, preserves text and existing images, and cleans only consumed or stale exact files"
