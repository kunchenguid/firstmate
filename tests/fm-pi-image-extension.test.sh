#!/usr/bin/env bash
# Deterministic checks for Firstmate's Pi inline image display
# (.pi/extensions/fm-image.ts and .pi/extensions/lib/fm-image-display.ts):
# path and file validation, the bounded PNG display copy, rendering through Pi's
# own Image component for Kitty, iTerm2, and no-image terminals, the /image
# command and fm_show_image tool contracts, and escape-free model-facing text.
# tests/fm-pi-image-herdr-live-e2e.test.sh owns the real Pi TUI inside a real
# Herdr pane and the Kitty graphics Herdr relays to its attached client.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the Pi image extension test"; exit 0; }
command -v npm >/dev/null 2>&1 || { echo "skip: npm not found for the Pi image extension test"; exit 0; }
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @earendil-works/pi-coding-agent package not found for the Pi image extension test"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-pi-image-extension)
FIXTURE="$TMP_ROOT/project"
mkdir -p "$FIXTURE/.pi/extensions/lib" "$FIXTURE/node_modules/@earendil-works" "$TMP_ROOT/files"
cp "$ROOT/.pi/extensions/fm-image.ts" "$FIXTURE/.pi/extensions/fm-image.ts"
cp "$ROOT/.pi/extensions/lib/fm-image-display.ts" "$FIXTURE/.pi/extensions/lib/fm-image-display.ts"
ln -s "$PI_PACKAGE_DIR" "$FIXTURE/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$FIXTURE/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$FIXTURE/node_modules/typebox"
printf '%s\n' '{"type":"module"}' > "$FIXTURE/package.json"
FILES=$(cd "$TMP_ROOT/files" && pwd -P)
export FILES

# Shared fixture builders. The JPEG and WebP are 24x16 images encoded once with
# Pi's own image codec, so the suite needs no image tooling of its own.
cat > "$FIXTURE/helpers.mjs" <<'JS'
import { deflateSync } from "node:zlib";

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});

function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}

/** An RGB PNG: flat compresses to nearly nothing, noise not at all, and a declared size can lie. */
export function makePng(width, height, { flat = false, noise = false, declaredWidth = width, declaredHeight = height } = {}) {
  let seed = 12345;
  const rows = [];
  for (let y = 0; y < height; y++) {
    const row = Buffer.alloc(1 + width * 3);
    for (let x = 0; x < width; x++) {
      for (let channel = 0; channel < 3; channel++) {
        seed = (Math.imul(seed, 1103515245) + 12345) >>> 0;
        row[1 + x * 3 + channel] = flat ? 90 : noise ? seed >>> 24 : (x * 7 + y * 3 + channel * 60) & 0xff;
      }
    }
    rows.push(row);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(declaredWidth, 0);
  header.writeUInt32BE(declaredHeight, 4);
  header.set([8, 2, 0, 0, 0], 8);
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(Buffer.concat(rows))),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

export const JPEG_24x16 = Buffer.from(
  "/9j/4AAQSkZJRgABAgAAAQABAAD/wAARCAAQABgDAREAAhEBAxEB/9sAQwAGBAUGBQQGBgUGBwcGCAoQCgoJCQoUDg8MEBcUGBgXFBYWGh0lHxobIxwWFiAsICMmJykqKRkfLTAtKDAlKCko/9sAQwEHBwcKCAoTCgoTKBoWGigoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgo/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDyvRv4a80+zPRvC/8AF+FSz5Tif/l1/wBvfoei6N/DUnyh846N/DX353Hr3w2/5ef+Af8As1fIcVf8uv8At79D1Mt+18v1PXtG/hr5A9M//9k=",
  "base64",
);

export const WEBP_24x16 = Buffer.from(
  "UklGRq4AAABXRUJQVlA4TKIAAAAvF8ADEM1VICICHgiJDQMAAIDCPQZgUAAAAAAAAAoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIIAA8EA2AQAAAADOfwAAAAAAAAAAAAAADgIAAAAAgAAAAAAAAAAAAAAAAAAA8EA2AQAAAADOfwAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAABAAAAAABwAAiPyDQCAQCLw9EAgEAnFY837jV+NhTQA=",
  "base64",
);

export const plainTheme = { fg: (_color, text) => text, bg: (_color, text) => text, bold: (text) => text };

export function isPng(base64) {
  return Buffer.from(base64, "base64").subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
}

/** Any C0 or C1 control other than a newline: text that could drive a terminal. */
export function hasControl(text) {
  return /[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/.test(text);
}

export function fakePi() {
  const registered = { commands: new Map(), tools: new Map(), entryRenderers: new Map(), entries: [] };
  const api = {
    registerCommand: (name, spec) => registered.commands.set(name, spec),
    registerTool: (tool) => registered.tools.set(tool.name, tool),
    registerEntryRenderer: (type, renderer) => registered.entryRenderers.set(type, renderer),
    appendEntry: (type, data) => registered.entries.push({ type, data }),
  };
  return { api, registered };
}

export function fakeContext(cwd, mode = "tui") {
  const notices = [];
  return { notices, ctx: { cwd, mode, hasUI: mode !== "print", ui: { notify: (message, level) => notices.push({ message, level }) } } };
}
JS

run_case() { # <name> ; script on stdin
  local name=$1 out status=0
  cat > "$FIXTURE/case-$name.mjs"
  out=$(cd "$FIXTURE" && node "case-$name.mjs" 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "$name: $out"
}

test_loads_supported_images_into_png_display_copies() {
  run_case supported <<'JS'
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { JPEG_24x16, WEBP_24x16, isPng, makePng } from "./helpers.mjs";
const { loadImageForDisplay } = await import("./.pi/extensions/lib/fm-image-display.ts");
const dir = process.env.FILES;
const cases = [
  ["shot.png", makePng(24, 16), "image/png"],
  ["photo.jpg", JPEG_24x16, "image/jpeg"],
  ["art.webp", WEBP_24x16, "image/webp"],
  ["misnamed.txt", makePng(24, 16), "image/png"],
];
for (const [name, bytes, mimeType] of cases) {
  writeFileSync(`${dir}/${name}`, bytes);
  const result = await loadImageForDisplay(`${dir}/${name}`, "/");
  assert.equal(result.ok, true, `${name}: ${result.error}`);
  assert.equal(result.image.path, `${dir}/${name}`);
  assert.equal(result.image.mimeType, mimeType, `${name} is identified by its signature, not its name`);
  assert.deepEqual([result.image.width, result.image.height, result.image.bytes], [24, 16, bytes.length]);
  assert.ok(result.image.display, `${name} has an inline display copy`);
  assert.ok(isPng(result.image.display.data), `${name} display copy is PNG, the only format Kitty f=100 accepts`);
  assert.deepEqual([result.image.display.width, result.image.display.height], [24, 16]);
}
JS
  pass "pi image: PNG, JPEG, and WebP files load by signature into bounded PNG display copies"
}

test_bounds_the_display_copy() {
  run_case bounds <<'JS'
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { isPng, makePng } from "./helpers.mjs";
const { FM_IMAGE_LIMITS, loadImageForDisplay } = await import("./.pi/extensions/lib/fm-image-display.ts");
const dir = process.env.FILES;
writeFileSync(`${dir}/wide.png`, makePng(2400, 1800, { flat: true }));
const wide = await loadImageForDisplay(`${dir}/wide.png`, "/");
assert.equal(wide.ok, true, wide.error);
assert.deepEqual([wide.image.width, wide.image.height], [2400, 1800], "the path line reports the original size");
const side = FM_IMAGE_LIMITS.displayMaxSide;
assert.deepEqual([wide.image.display.width, wide.image.display.height], [side, (side * 3) / 4], "the display copy is capped at the display side");
writeFileSync(`${dir}/noise.png`, makePng(400, 300, { noise: true }));
const budget = 60_000;
const noisy = await loadImageForDisplay(`${dir}/noise.png`, "/", { ...FM_IMAGE_LIMITS, displayMaxBase64Bytes: budget });
assert.equal(noisy.ok, true, noisy.error);
assert.ok(noisy.image.display, "an incompressible image still gets a display copy");
assert.ok(isPng(noisy.image.display.data));
assert.ok(noisy.image.display.data.length <= budget, `display copy ${noisy.image.display.data.length} exceeds the ${budget} budget`);
assert.ok(noisy.image.display.width < 400, "the display copy shrank to meet its byte budget");
JS
  pass "pi image: display copies are capped in pixels and encoded size"
}

test_refuses_unsafe_or_unsupported_inputs() {
  run_case refusals <<'JS'
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { hasControl, makePng } from "./helpers.mjs";
const { FM_IMAGE_LIMITS, loadImageForDisplay } = await import("./.pi/extensions/lib/fm-image-display.ts");
const dir = process.env.FILES;
writeFileSync(`${dir}/real.png`, makePng(24, 16));
symlinkSync(`${dir}/real.png`, `${dir}/link.png`);
mkdirSync(`${dir}/folder.png`);
execFileSync("mkfifo", [`${dir}/pipe.png`]);
writeFileSync(`${dir}/empty.png`, "");
writeFileSync(`${dir}/notes.png`, "just some text\n");
writeFileSync(`${dir}/anim.gif`, Buffer.from("GIF89a\u0018\u0000\u0010\u0000", "latin1"));
writeFileSync(`${dir}/damaged.png`, Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0]));
writeFileSync(`${dir}/giant.png`, makePng(4, 4, { declaredWidth: 20000, declaredHeight: 20000 }));
const refusals = [
  ["", /No image path given/],
  ["   ", /No image path given/],
  [`${dir}/bad\u001b]52;c;name.png`, /control characters/],
  [`file://${dir}/encoded%1b%5b2J.png`, /control characters/],
  [`${dir}/missing.png`, /No such file/],
  [`${dir}/link.png`, /symbolic link/],
  [`${dir}/folder.png`, /Not a regular file/],
  [`${dir}/pipe.png`, /Not a regular file/],
  [`${dir}/empty.png`, /Empty file/],
  [`${dir}/notes.png`, /Not a PNG, JPEG, or WebP image/],
  [`${dir}/anim.gif`, /Not a PNG, JPEG, or WebP image/],
  [`${dir}/damaged.png`, /Could not read the image dimensions/],
  [`${dir}/giant.png`, /above the 16384-pixel side/],
  ["file://remote-host/share/real.png", /does not name a local path/],
];
for (const [path, pattern] of refusals) {
  const result = await Promise.race([
    loadImageForDisplay(path, "/"),
    new Promise((_, reject) => setTimeout(() => reject(new Error(`loading ${JSON.stringify(path)} did not finish`)), 5000)),
  ]);
  assert.equal(result.ok, false, `${JSON.stringify(path)} must be refused`);
  assert.match(result.error, pattern, `${JSON.stringify(path)} refusal: ${result.error}`);
  assert.ok(!hasControl(result.error), `refusal text must not carry control characters: ${JSON.stringify(result.error)}`);
}
const small = { ...FM_IMAGE_LIMITS, maxFileBytes: 64 };
const large = await loadImageForDisplay(`${dir}/real.png`, "/", small);
assert.equal(large.ok, false);
assert.match(large.error, /above the 64-byte limit/);
const area = await loadImageForDisplay(`${dir}/real.png`, "/", { ...FM_IMAGE_LIMITS, maxPixels: 100 });
assert.equal(area.ok, false);
assert.match(area.error, /100-pixel area limit/);
JS
  pass "pi image: links, special files, empty, oversized, damaged, huge, and unsupported inputs are refused"
}

test_resolves_supported_path_forms() {
  run_case paths <<'JS'
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { makePng } from "./helpers.mjs";
const { loadImageForDisplay, resolveImagePath } = await import("./.pi/extensions/lib/fm-image-display.ts");
const dir = process.env.FILES;
mkdirSync(`${dir}/home/pics`, { recursive: true });
writeFileSync(`${dir}/home/pics/cat.png`, makePng(24, 16));
process.env.HOME = `${dir}/home`;
for (const [raw, cwd] of [
  ["pics/cat.png", `${dir}/home`],
  ["~/pics/cat.png", "/"],
  [`"${dir}/home/pics/cat.png"`, "/"],
  [`  '${dir}/home/pics/cat.png'  `, "/"],
  [pathToFileURL(`${dir}/home/pics/cat.png`).href, "/"],
]) {
  const result = await loadImageForDisplay(raw, cwd);
  assert.equal(result.ok, true, `${JSON.stringify(raw)}: ${result.error}`);
  assert.equal(result.image.path, `${dir}/home/pics/cat.png`, `${JSON.stringify(raw)} resolved to ${result.image.path}`);
}
assert.deepEqual(resolveImagePath("~", "/"), { ok: true, path: `${dir}/home` });
JS
  pass "pi image: relative, home, quoted, and file URL paths resolve to the local file"
}

test_renders_through_pi_image_component() {
  run_case render <<'JS'
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { makePng, plainTheme } from "./helpers.mjs";
const { setCapabilities } = await import("@earendil-works/pi-tui");
const { FmImageComponent, loadImageForDisplay } = await import("./.pi/extensions/lib/fm-image-display.ts");
const dir = process.env.FILES;
writeFileSync(`${dir}/render.png`, makePng(240, 160));
const loaded = await loadImageForDisplay(`${dir}/render.png`, "/");
assert.equal(loaded.ok, true, loaded.error);
const view = loaded.image;

setCapabilities({ images: "kitty", trueColor: true, hyperlinks: false });
const kitty = new FmImageComponent(view, plainTheme);
const lines = kitty.render(400);
assert.match(lines[0], /^\[Image: .*render\.png \[image\/png\] 240x160\]$/, "the path line comes first");
assert.ok(!lines[0].includes("\u001b_G"), "the path line carries no graphics");
assert.ok(lines[1].startsWith("\u001b_G"), "Pi's Image component emits the Kitty graphics command");
const controls = /^\u001b_G([^;]*);/.exec(lines[1])[1].split(",");
for (const expected of ["a=T", "f=100", "C=1"]) assert.ok(controls.includes(expected), `Kitty command lacks ${expected}: ${controls}`);
const rows = Number(controls.find((item) => item.startsWith("r=")).slice(2));
assert.equal(lines.length, 1 + rows, "the component reserves exactly the image rows below the path line");
assert.ok(lines.slice(2).every((line) => line === ""), "reserved image rows stay empty");
const imageId = controls.find((item) => item.startsWith("i="));
kitty.update(plainTheme, true);
kitty.invalidate();
assert.ok(kitty.render(400)[1].split(";")[0].split(",").includes(imageId), "a reused component keeps its Kitty image id");

setCapabilities({ images: "iterm2", trueColor: true, hyperlinks: false });
const iterm = new FmImageComponent(view, plainTheme).render(100);
assert.ok(iterm.some((line) => line.includes("\u001b]1337;File=")), "an iTerm2 terminal gets Pi's iTerm2 inline image");

setCapabilities({ images: null, trueColor: true, hyperlinks: false });
const text = new FmImageComponent(view, plainTheme).render(100);
assert.equal(text.length, 1, "a terminal without inline images gets only the path line");
assert.ok(!text[0].includes("\u001b_G") && !text[0].includes("\u001b]1337"), "the fallback emits no graphics");

setCapabilities({ images: "kitty", trueColor: true, hyperlinks: false });
assert.equal(new FmImageComponent(view, plainTheme, false).render(100).length, 1, "images turned off in Pi show only the path line");
const { display: _display, ...withoutCopy } = view;
assert.equal(new FmImageComponent(withoutCopy, plainTheme).render(100).length, 1, "a view without a display copy shows only the path line");
for (const width of [1, 5, 20]) {
  const narrow = new FmImageComponent(view, plainTheme).render(width);
  assert.ok(narrow.length >= 1, `width ${width} renders`);
}
JS
  pass "pi image: rendering delegates to Pi's Image component and always keeps the path line"
}

test_parses_persisted_views_defensively() {
  run_case parse <<'JS'
import assert from "node:assert/strict";
const { parseImageView } = await import("./.pi/extensions/lib/fm-image-display.ts");
const good = { path: "/tmp/a.png", mimeType: "image/png", width: 2, height: 3, bytes: 40, display: { data: "iVBORw0KGgo=", width: 2, height: 3 } };
assert.deepEqual(parseImageView(good), good);
const { display: _display, ...noCopy } = good;
assert.deepEqual(parseImageView(noCopy), noCopy);
for (const bad of [
  undefined,
  null,
  "text",
  { ...good, path: "" },
  { ...good, path: "/tmp/\u001b[2Ja.png" },
  { ...good, mimeType: "image/gif" },
  { ...good, width: 0 },
  { ...good, height: 1.5 },
  { ...good, bytes: -1 },
  { ...good, display: null },
  { ...good, display: { ...good.display, data: "\u001b_Ga=d;\u001b\\" } },
  { ...good, display: { ...good.display, width: "2" } },
]) {
  assert.equal(parseImageView(bad), undefined, `must reject ${JSON.stringify(bad)}`);
}
JS
  pass "pi image: persisted image views are re-validated before rendering"
}

test_image_command_records_an_entry_outside_model_context() {
  run_case command <<'JS'
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { fakeContext, fakePi, makePng, plainTheme } from "./helpers.mjs";
const { setCapabilities } = await import("@earendil-works/pi-tui");
const extension = await import("./.pi/extensions/fm-image.ts");
const { FmImageComponent } = await import("./.pi/extensions/lib/fm-image-display.ts");
const dir = process.env.FILES;
writeFileSync(`${dir}/command.png`, makePng(24, 16));
const { api, registered } = fakePi();
extension.default(api);
assert.deepEqual([...registered.commands.keys()], ["image"]);
assert.deepEqual([...registered.entryRenderers.keys()], [extension.FM_IMAGE_ENTRY_TYPE]);

const good = fakeContext(dir);
await registered.commands.get("image").handler("command.png", good.ctx);
assert.deepEqual(good.notices, []);
assert.equal(registered.entries.length, 1);
const [entry] = registered.entries;
assert.equal(entry.type, extension.FM_IMAGE_ENTRY_TYPE, "the image is a custom entry, which Pi keeps out of model context");
assert.equal(entry.data.path, `${dir}/command.png`);
assert.ok(entry.data.display, "the entry persists its bounded display copy");

setCapabilities({ images: "kitty", trueColor: true, hyperlinks: false });
const renderer = registered.entryRenderers.get(extension.FM_IMAGE_ENTRY_TYPE);
const component = renderer({ type: "custom", customType: extension.FM_IMAGE_ENTRY_TYPE, data: entry.data }, { expanded: false }, plainTheme);
assert.ok(component instanceof FmImageComponent);
assert.ok(component.render(100)[1].startsWith("\u001b_G"), "/image is an explicit always-render override");
assert.equal(renderer({ type: "custom", customType: extension.FM_IMAGE_ENTRY_TYPE, data: { path: 1 } }, { expanded: false }, plainTheme), undefined);

const bad = fakeContext(dir);
await registered.commands.get("image").handler("", bad.ctx);
await registered.commands.get("image").handler("missing.png", bad.ctx);
assert.equal(registered.entries.length, 1, "a refused path records nothing");
assert.deepEqual(bad.notices.map((notice) => notice.level), ["error", "error"]);
assert.match(bad.notices[1].message, /No such file/);
JS
  pass "pi image: /image records a renderable custom entry and reports refusals without recording"
}

test_show_image_tool_returns_text_and_renders_the_details() {
  run_case tool <<'JS'
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { fakeContext, fakePi, hasControl, makePng, plainTheme } from "./helpers.mjs";
const { setCapabilities } = await import("@earendil-works/pi-tui");
const extension = await import("./.pi/extensions/fm-image.ts");
const { FmImageComponent, parseImageView } = await import("./.pi/extensions/lib/fm-image-display.ts");
const dir = process.env.FILES;
writeFileSync(`${dir}/tool.png`, makePng(24, 16));
const { api, registered } = fakePi();
extension.default(api);
const tool = registered.tools.get(extension.FM_SHOW_IMAGE_TOOL);
assert.ok(tool, "fm_show_image is registered");
assert.equal(tool.renderShell, "self", "the image renders outside Pi's colored tool box, like Pi's own tool images");
assert.deepEqual(Object.keys(tool.parameters.properties), ["path"]);

const run = async (mode, protocol) => {
  setCapabilities({ images: protocol, trueColor: true, hyperlinks: false });
  const result = await tool.execute("call-1", { path: "tool.png" }, undefined, undefined, fakeContext(dir, mode).ctx);
  assert.equal(result.content.length, 1);
  assert.equal(result.content[0].type, "text", "the model receives text only, never the pixels");
  assert.ok(!hasControl(result.content[0].text), "model-facing text carries no control characters");
  assert.ok(result.content[0].text.includes(`${dir}/tool.png`));
  return result;
};
const shown = await run("tui", "kitty");
assert.match(shown.content[0].text, /appears inline when image display is enabled and supported, otherwise only its file path appears/);
assert.ok(parseImageView(shown.details), "details carry a valid image view");
assert.match((await run("tui", null)).content[0].text, /otherwise only its file path appears/);
assert.match((await run("rpc", "kitty")).content[0].text, /Nothing was displayed/);
await assert.rejects(
  tool.execute("call-2", { path: "absent.png" }, undefined, undefined, fakeContext(dir).ctx),
  /No such file/,
);

setCapabilities({ images: "kitty", trueColor: true, hyperlinks: false });
const context = (overrides = {}) => ({ isError: false, showImages: true, lastComponent: undefined, ...overrides });
const component = tool.renderResult(shown, { expanded: false, isPartial: false }, plainTheme, context());
assert.ok(component instanceof FmImageComponent);
assert.ok(component.render(100)[1].startsWith("\u001b_G"));
assert.equal(tool.renderResult(shown, { expanded: false, isPartial: false }, plainTheme, context({ lastComponent: component })), component, "a rerender reuses the image component");
assert.equal(
  tool.renderResult(shown, { expanded: false, isPartial: false }, plainTheme, context({ showImages: false })).render(100).length,
  1,
  "automatic tool images obey Pi's global image-display preference",
);
assert.deepEqual(tool.renderResult(shown, { expanded: false, isPartial: true }, plainTheme, context()).render(100), []);
const failure = { content: [{ type: "text", text: "No such file: /x\u001b[2J.png" }], details: undefined };
const failureLines = tool.renderResult(failure, { expanded: false, isPartial: false }, plainTheme, context({ isError: true })).render(100);
assert.ok(failureLines.join("\n").includes("No such file"));
assert.ok(!failureLines.join("\n").includes("\u001b[2J"), "an error result cannot smuggle an escape into the transcript");
const callLines = tool.renderCall({ path: "evil\u001b]52;c;x\u0007.png" }, plainTheme, context()).render(100);
assert.ok(!callLines.join("\n").includes("\u001b]52"), "the call row sanitizes the model-supplied path");
JS
  pass "pi image: fm_show_image returns escape-free text and renders its image from the result details"
}

test_loads_supported_images_into_png_display_copies
test_bounds_the_display_copy
test_refuses_unsafe_or_unsupported_inputs
test_resolves_supported_path_forms
test_renders_through_pi_image_component
test_parses_persisted_views_defensively
test_image_command_records_an_entry_outside_model_context
test_show_image_tool_returns_text_and_renders_the_details
