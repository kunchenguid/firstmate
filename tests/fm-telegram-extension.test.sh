#!/usr/bin/env bash
# Focused behavior checks for the Pi half of the Telegram terminal mirror:
# what it mirrors, what it never mirrors, and how queued Telegram text reaches
# Pi's own user-input path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the Telegram mirror extension test"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-telegram-extension)
trap fm_test_cleanup EXIT

cat >"$TMP_ROOT/codex-report.js" <<'JS'
setTimeout(() => {}, 30000);
JS
node "$TMP_ROOT/codex-report.js" &
NEAR_MATCH_PID=$!
mkdir -p "$TMP_ROOT/near-match-state"
printf '%s\n' "$NEAR_MATCH_PID" >"$TMP_ROOT/near-match-state/.lock"
if "$ROOT/bin/fm-session-lock-check.sh" "$TMP_ROOT/near-match-state" "$NEAR_MATCH_PID"; then
  kill "$NEAR_MATCH_PID" 2>/dev/null || true
  wait "$NEAR_MATCH_PID" 2>/dev/null || true
  fail "an unrelated node process with a harness substring authenticated as Pi"
fi
kill "$NEAR_MATCH_PID" 2>/dev/null || true
wait "$NEAR_MATCH_PID" 2>/dev/null || true

printf 'const value: number = 1;\nexport default value;\n' >"$TMP_ROOT/probe.ts"
if ! node -e 'import(process.argv[1]).catch(() => process.exit(1))' "$TMP_ROOT/probe.ts" >/dev/null 2>&1; then
  echo "skip: this node does not strip TypeScript types"
  exit 0
fi

# The settings UI imports Pi's own TUI components, so the extension runs from a
# fixture whose node_modules point at the installed Pi package, the same way the
# tracked Pi extensions resolve them in a real session.
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @earendil-works/pi-coding-agent package not found"
  exit 0
fi
FIXTURE="$TMP_ROOT/ext"
mkdir -p "$FIXTURE/lib" "$FIXTURE/node_modules/@earendil-works"
# This node process stands in for the one live Firstmate session: the bridge
# only mirrors when it runs inside the session that holds the home's lock.
mkdir -p "$TMP_ROOT/fmhome/state" "$TMP_ROOT/workerhome/state"
cp "$ROOT/.pi/extensions/fm-telegram-mirror.ts" "$FIXTURE/fm-telegram-mirror.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$FIXTURE/lib/fm-operational-input.ts"
ln -s "$PI_PACKAGE_DIR" "$FIXTURE/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$FIXTURE/node_modules/@earendil-works/pi-tui"
printf '%s\n' '{"type":"module"}' >"$FIXTURE/package.json"
cat >"$TMP_ROOT/session-lock-check" <<SH
#!/bin/sh
# Ownership cannot be genuine in this fixture - its session is node, not a
# harness - so that half is stood in for. The "is this home already claimed?"
# half is answered by the real shared classification, because that is the
# question a recycled pid makes dangerous.
if [ "\$1" = "--claimed" ]; then
  exec "$ROOT/bin/fm-session-lock-check.sh" --claimed "\$2"
fi
[ -f "\$1/.lock" ] && [ ! -L "\$1/.lock" ] || exit 1
[ "\$(cat "\$1/.lock")" = "\$2" ]
SH
chmod +x "$TMP_ROOT/session-lock-check"
# A real verified-harness process for the fixture to point locks at: bash
# launched through a symlink named "pi", which Firstmate's shared
# classification identifies exactly as it identifies a live Pi session.
ln -s /bin/bash "$TMP_ROOT/pi"

OUT="$TMP_ROOT/node-output"
if ! (cd "$FIXTURE" && \
  timeout 90 env \
  EXT="$FIXTURE/fm-telegram-mirror.ts" \
  OPERATIONAL_INPUT="$ROOT/bin/fm-operational-input.sh" \
  FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
  FM_TELEGRAM_DIR="$TMP_ROOT/home" \
  FM_TELEGRAM_MAX_OUTSTANDING_WRITE_BYTES=100000 \
  FM_TELEGRAM_TESTING=1 \
  FM_TELEGRAM_SESSION_LOCK_CHECK="$TMP_ROOT/session-lock-check" \
  FM_TEST_PI_BIN="$TMP_ROOT/pi" \
  FM_HOME="$TMP_ROOT/fmhome" \
  WORKER_HOME="$TMP_ROOT/workerhome" \
  PENDING_HOME="$TMP_ROOT/pendinghome" \
  FM_TELEGRAM_LOCK_WAIT_MS=100 \
  FM_TELEGRAM_LOCK_WAIT_ATTEMPTS=200 \
  node --input-type=module >"$OUT" 2>&1) <<'JS'
import { execFileSync, spawn } from "node:child_process";
import { mkdirSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { createServer } from "node:net";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
// Pi's own footer renderer decides how the statuses extensions publish are
// ordered, joined, and truncated, so the rendered line is asserted through it
// rather than through a local copy of those rules.
import { FooterComponent, initTheme } from "@earendil-works/pi-coding-agent";

initTheme("dark");

const VOICE_STATUS = "voice: alt+m • parakeet-v3-q8";

function renderFooter(statuses, width) {
  const session = {
    state: { model: undefined, thinkingLevel: "off" },
    sessionManager: {
      getEntries: () => [],
      getCwd: () => process.cwd(),
      getSessionName: () => undefined,
    },
    getContextUsage: () => undefined,
    modelRuntime: { isUsingSubscription: () => false },
    autoCompactionEnabled: true,
  };
  const footerData = {
    getGitBranch: () => null,
    getExtensionStatuses: () => statuses,
    getAvailableProviderCount: () => 1,
  };
  return new FooterComponent(session, footerData)
    .render(width)
    // eslint-disable-next-line no-control-regex
    .map((line) => line.replace(/\u001b\[[0-9;]*m/g, ""));
}

const home = process.env.FM_TELEGRAM_DIR;
mkdirSync(home, { recursive: true });
const socketPath = join(home, "bot.sock");

// Bounded by construction: if any await below never settles, this fixture
// fails loudly instead of hanging the suite.
const watchdog = setTimeout(() => {
  console.error("fm-telegram-mirror fixture timed out before completing its checks");
  process.exit(3);
}, 45000);

const received = [];
let connections = 0;
let botWrite = null;
let onFrame = () => {};

const server = createServer((socket) => {
  connections += 1;
  botWrite = (frame) => socket.write(`${JSON.stringify(frame)}\n`);
  let buffer = "";
  socket.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    let index = buffer.indexOf("\n");
    while (index >= 0) {
      const line = buffer.slice(0, index);
      buffer = buffer.slice(index + 1);
      if (line.trim()) {
        const frame = JSON.parse(line);
        received.push(frame);
        onFrame(frame);
      }
      index = buffer.indexOf("\n");
    }
  });
});
await new Promise((resolve) => server.listen(socketPath, resolve));

// Fake Pi: records exactly what the agent would have been asked to do.
const submissions = [];
const notifications = [];
const handlers = new Map();
let commandDefinition;
let settingsDefinition;
let idle = true;
const footer = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand(name, definition) {
    if (name === "telegram") commandDefinition = definition;
    if (name === "telegram-settings") settingsDefinition = definition;
  },
  sendUserMessage(content, options) {
    submissions.push({ content, options });
  },
};
const ctx = {
  isIdle: () => idle,
  mode: "print",
  ui: {
    notify: (message, level) => notifications.push({ message, level }),
    setStatus: (key, value) => {
      if (value === undefined) footer.delete(key);
      else footer.set(key, value);
    },
  },
};
const footerText = () => footer.get("firstmate-telegram");

// The live session's lock names this process, so this instance is the primary.
writeFileSync(join(process.env.FM_HOME, "state", ".lock"), `${process.pid}\n`);
const extension = await import(pathToFileURL(process.env.EXT).href);
extension.default(pi);
handlers.get("session_start")({ reason: "startup" }, ctx);

function fail(message) {
  throw new Error(message);
}

async function waitFor(predicate, description) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  fail(`timed out waiting for ${description}; frames=${JSON.stringify(received)}`);
}

await waitFor(() => botWrite !== null, "the extension to connect to the bot socket");
await waitFor(() => received.some((frame) => frame.t === "hello"), "a hello frame");

// 1. Ordinary terminal submissions are mirrored; Telegram-injected text and
//    Firstmate's own operational input are not.
handlers.get("input")({ text: "check the failing test", source: "interactive" }, ctx);
handlers.get("input")({ text: "queued from telegram", source: "extension" }, ctx);
const operational = execFileSync(process.env.OPERATIONAL_INPUT, ["encode", "watcher"], {
  input: "FIRSTMATE WATCHER WAKE: signal: probe",
  encoding: "utf8",
});
handlers.get("input")({ text: operational, source: "interactive" }, ctx);
await waitFor(() => received.some((frame) => frame.t === "terminal"), "a terminal frame");
await new Promise((resolve) => setTimeout(resolve, 200));
const terminalFrames = received.filter((frame) => frame.t === "terminal");
if (terminalFrames.length !== 1 || terminalFrames[0].text !== "check the failing test") {
  fail(`unexpected terminal mirroring: ${JSON.stringify(terminalFrames)}`);
}

// 1b. A pasted screenshot is part of the submission: the bot receives the bytes
//     so Telegram can show real media, and the images keep their order. A
//     Telegram-origin screenshot still never echoes back.
const shotA = "iVBORw0KA";
const shotB = "iVBORw0KB";
handlers.get("input")({
  text: "what do you make of these",
  source: "interactive",
  images: [
    { type: "image", data: shotA, mimeType: "image/png" },
    { type: "image", data: shotB, mimeType: "image/webp" },
  ],
}, ctx);
handlers.get("input")({ text: "", source: "interactive", images: [{ type: "image", data: shotA, mimeType: "image/png" }] }, ctx);
handlers.get("input")({ text: "", source: "extension", images: [{ type: "image", data: shotB, mimeType: "image/png" }] }, ctx);
handlers.get("input")({ text: operational, source: "interactive", images: [{ type: "image", data: shotA, mimeType: "image/png" }] }, ctx);
await waitFor(
  () => received.filter((frame) => frame.t === "terminal" && frame.images).length === 2,
  "the terminal image frames",
);
await new Promise((resolve) => setTimeout(resolve, 200));
const imageFrames = received.filter((frame) => frame.t === "terminal" && frame.images);
if (imageFrames.length !== 2) {
  fail(`unexpected terminal image mirroring: ${JSON.stringify(imageFrames)}`);
}
if (JSON.stringify(imageFrames[0]) !== JSON.stringify({
  t: "terminal",
  text: "what do you make of these",
  images: [{ data: shotA, mime: "image/png" }, { data: shotB, mime: "image/webp" }],
})) {
  fail(`text plus images was not preserved in order: ${JSON.stringify(imageFrames[0])}`);
}
if (imageFrames[1].text !== "" || imageFrames[1].images.length !== 1) {
  fail(`an image-only submission was not mirrored intact: ${JSON.stringify(imageFrames[1])}`);
}

// 1c. A pasted clipboard image is the live case: Pi writes it into the temp
//     directory and inserts the path as ordinary text, with no image event at
//     all, so the artifact itself is the only signal. Recognition must be
//     narrow enough that naming any other file uploads nothing.
const clipboardDir = tmpdir();
const uuid = "a864c680-178e-4995-86d9-48d62744aa3e";
const pngBytes = Buffer.from("89504e470d0a1a0a" + "00".repeat(24), "hex");
const jpegBytes = Buffer.from("ffd8ff" + "11".repeat(24), "hex");
const genuine = join(clipboardDir, `pi-clipboard-${uuid}.png`);
const genuineJpeg = join(clipboardDir, `pi-clipboard-b1c2d3e4-1111-2222-3333-444455556666.jpg`);
writeFileSync(genuine, pngBytes);
writeFileSync(genuineJpeg, jpegBytes);

// Negatives, each a file that really exists and is really named plausibly.
const arbitrary = join(clipboardDir, "fm-telegram-secret.png");
writeFileSync(arbitrary, pngBytes);
const wrongMagic = join(clipboardDir, `pi-clipboard-99999999-1111-2222-3333-444455556666.png`);
writeFileSync(wrongMagic, Buffer.from("not an image at all"));
const oversized = join(clipboardDir, `pi-clipboard-88888888-1111-2222-3333-444455556666.png`);
writeFileSync(oversized, Buffer.concat([pngBytes, Buffer.alloc(11 * 1024 * 1024)]));
const linkTarget = join(clipboardDir, "fm-telegram-link-target.png");
writeFileSync(linkTarget, pngBytes);
const symlinked = join(clipboardDir, `pi-clipboard-77777777-1111-2222-3333-444455556666.png`);
try { unlinkSync(symlinked); } catch {}
symlinkSync(linkTarget, symlinked);
const missing = join(clipboardDir, `pi-clipboard-66666666-1111-2222-3333-444455556666.png`);
try { unlinkSync(missing); } catch {}

const framesBeforePaste = received.filter((frame) => frame.t === "terminal").length;
// The captain's exact submission: the clipboard path followed by their words.
handlers.get("input")({ text: `${genuine} lets see here`, source: "interactive" }, ctx);
await waitFor(
  () => received.filter((frame) => frame.t === "terminal").length === framesBeforePaste + 1,
  "the pasted clipboard image",
);
const pasted = received.filter((frame) => frame.t === "terminal").at(-1);
if (!pasted.images || pasted.images.length !== 1) {
  fail(`a pasted clipboard image was not mirrored: ${JSON.stringify(pasted)}`);
}
if (pasted.images[0].mime !== "image/png"
    || pasted.images[0].data !== pngBytes.toString("base64")) {
  fail(`the mirrored bytes were not the pasted image: ${JSON.stringify(pasted.images[0]).slice(0, 120)}`);
}
// The phone gets the captain's words, never Pi's local plumbing.
if (pasted.text !== "lets see here") {
  fail(`the caption kept the local path or lost the text: ${JSON.stringify(pasted.text)}`);
}

// Two pastes in one submission keep their order.
handlers.get("input")({ text: `${genuine} and ${genuineJpeg}`, source: "interactive" }, ctx);
await waitFor(
  () => received.filter((frame) => frame.t === "terminal").length === framesBeforePaste + 2,
  "the two-image paste",
);
const twoShots = received.filter((frame) => frame.t === "terminal").at(-1);
if (JSON.stringify(twoShots.images?.map((image) => image.mime)) !==
    JSON.stringify(["image/png", "image/jpeg"])) {
  fail(`two pasted images lost their order: ${JSON.stringify(twoShots.images?.length)}`);
}
if (twoShots.text !== "and") {
  fail(`unexpected caption for a two-image paste: ${JSON.stringify(twoShots.text)}`);
}

// Pi concatenates two pastes with nothing between them, which is exactly what
// the captain sent, so adjacency must parse as two artifacts and no prose.
const framesBeforeAdjacent = received.filter((frame) => frame.t === "terminal").length;
handlers.get("input")({ text: `${genuine}${genuineJpeg}`, source: "interactive" }, ctx);
await waitFor(
  () => received.filter((frame) => frame.t === "terminal").length === framesBeforeAdjacent + 1,
  "the adjacent two-image paste",
);
const adjacent = received.filter((frame) => frame.t === "terminal").at(-1);
if (JSON.stringify(adjacent.images?.map((image) => image.mime)) !==
    JSON.stringify(["image/png", "image/jpeg"])) {
  fail(`adjacent pastes were not both recognised: ${JSON.stringify(adjacent.images?.length)}`);
}
if (adjacent.images[0].data !== pngBytes.toString("base64")
    || adjacent.images[1].data !== jpegBytes.toString("base64")) {
  fail("adjacent pastes lost their order or their bytes");
}
if (adjacent.text !== "") {
  fail(`an adjacent paste left plumbing in the caption: ${JSON.stringify(adjacent.text)}`);
}

// The same, wrapped in the captain's own words.
handlers.get("input")({ text: `look ${genuine}${genuineJpeg} at these two`, source: "interactive" }, ctx);
await waitFor(
  () => received.filter((frame) => frame.t === "terminal").length === framesBeforeAdjacent + 2,
  "the adjacent paste with surrounding text",
);
const wrapped = received.filter((frame) => frame.t === "terminal").at(-1);
if (wrapped.images?.length !== 2) {
  fail(`surrounded adjacent pastes were not both recognised: ${JSON.stringify(wrapped.images?.length)}`);
}
if (wrapped.text !== "look at these two") {
  fail(`surrounding text was not preserved cleanly: ${JSON.stringify(wrapped.text)}`);
}

// Removing an artifact does not normalize the captain's unrelated whitespace.
handlers.get("input")({ text: `  lead\t${genuine} \t tail  `, source: "interactive" }, ctx);
await waitFor(
  () => received.filter((frame) => frame.t === "terminal").length === framesBeforeAdjacent + 3,
  "the whitespace-preserving paste",
);
const spaced = received.filter((frame) => frame.t === "terminal").at(-1);
if (spaced.text !== "  lead\t\t tail  ") {
  fail(`clipboard cleanup altered unrelated whitespace: ${JSON.stringify(spaced.text)}`);
}

// A genuine artifact glued to an invalid suffix is prose, not an artifact, and
// must not be split at the extension to smuggle the file out.
const framesBeforeAmbiguous = received.filter((frame) => frame.t === "terminal").length;
handlers.get("input")({ text: `${genuine}.backup`, source: "interactive" }, ctx);
handlers.get("input")({ text: `${genuine}${genuineJpeg}.backup`, source: "interactive" }, ctx);
handlers.get("input")({ text: `prefix${genuine}`, source: "interactive" }, ctx);
handlers.get("input")({ text: `/home${genuine}`, source: "interactive" }, ctx);
await new Promise((resolve) => setTimeout(resolve, 300));
const ambiguous = received.filter((frame) => frame.t === "terminal").slice(framesBeforeAmbiguous);
if (ambiguous.length !== 4) {
  fail(`ambiguity probes were dropped: ${ambiguous.length}`);
}
if (ambiguous[0].images || ambiguous[2].images || ambiguous[3].images) {
  fail("a path-like word was treated as a genuine paste");
}
// Only the leading artifact of the glued pair is genuine; the suffixed one is not.
if (ambiguous[1].images?.length !== 1
    || ambiguous[1].images[0].data !== pngBytes.toString("base64")) {
  fail(`a glued valid+invalid pair was parsed wrongly: ${JSON.stringify(ambiguous[1].images?.length)}`);
}

// Nothing else may ever be uploaded, however it is named or linked.
const framesBeforeNegatives = received.filter((frame) => frame.t === "terminal").length;
for (const probe of [arbitrary, wrongMagic, oversized, symlinked, missing,
                     "/etc/passwd", join(clipboardDir, "pi-clipboard-not-a-uuid.png"),
                     `${genuine}.txt`]) {
  handlers.get("input")({ text: `look at ${probe}`, source: "interactive" }, ctx);
}
handlers.get("input")({ text: `${operational} ${genuine}`, source: "interactive" }, ctx);
await new Promise((resolve) => setTimeout(resolve, 400));
const negatives = received.filter((frame) => frame.t === "terminal").slice(framesBeforeNegatives);
for (const frame of negatives) {
  if (frame.images) {
    fail(`a file that is not a genuine clipboard paste was uploaded: ${JSON.stringify(frame.text)}`);
  }
}
if (negatives.length !== 8) {
  fail(`operational input was mirrored or a probe was dropped: ${negatives.length}`);
}

// Once a canonical artifact is proven, an admission-limit refusal must omit
// only its local plumbing path while preserving the accepted media and prose.
const framesBeforeImageCountLimit = received.filter((frame) => frame.t === "terminal").length;
const noticesBeforeImageCountLimit = notifications.length;
handlers.get("input")({
  text: `keep ${Array(11).fill(genuine).join(" ")} this`,
  source: "interactive",
}, ctx);
await waitFor(
  () => received.filter((frame) => frame.t === "terminal").length === framesBeforeImageCountLimit + 1,
  "the clipboard image-count refusal",
);
const countLimited = received.filter((frame) => frame.t === "terminal").at(-1);
if (countLimited.images?.length !== 10 || countLimited.text !== "keep this") {
  fail(`a refused canonical artifact leaked its path or changed accepted media: ${JSON.stringify(countLimited.text)}`);
}
if (countLimited.text.includes("pi-clipboard-") ||
    notifications[noticesBeforeImageCountLimit]?.message !==
      "Telegram image was not mirrored because it exceeds clipboard image limits.") {
  fail(`the clipboard image-count refusal was not reported safely: ${JSON.stringify(notifications.slice(noticesBeforeImageCountLimit))}`);
}

const repeatedLarge = join(clipboardDir, `pi-clipboard-44444444-1111-2222-3333-444455556666.png`);
writeFileSync(repeatedLarge, Buffer.concat([pngBytes, Buffer.alloc(6 * 1024)]));
const framesBeforeRepeatedLarge = received.filter((frame) => frame.t === "terminal").length;
handlers.get("input")({
  text: Array(1000).fill(repeatedLarge).join(" "),
  source: "interactive",
}, ctx);
await waitFor(
  () => received.filter((frame) => frame.t === "terminal").length === framesBeforeRepeatedLarge + 1,
  "the bounded repeated-artifact scan",
);
const repeatedLargeFrame = received.filter((frame) => frame.t === "terminal").at(-1);
if (repeatedLargeFrame.images?.length !== 10 || repeatedLargeFrame.text !== "") {
  fail(`repeated artifacts were not bounded and admitted in order: ${JSON.stringify(repeatedLargeFrame.text)}`);
}

const raced = join(clipboardDir, `pi-clipboard-55555555-1111-2222-3333-444455556666.png`);
const racedStage = `${raced}.stage`;
const racedSecret = join(clipboardDir, "fm-telegram-race-secret.png");
const racedSafeBytes = Buffer.from("89504e470d0a1a0a" + "22".repeat(24), "hex");
const racedSecretBytes = Buffer.from("89504e470d0a1a0a" + "ee".repeat(24), "hex");
writeFileSync(raced, racedSafeBytes);
writeFileSync(racedSecret, racedSecretBytes);
const raceScript = join(process.env.FM_TELEGRAM_DIR, "clipboard-racer.mjs");
writeFileSync(raceScript, `
  import { renameSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
  const [target, stage, secret, safe] = process.argv.slice(2);
  const bytes = Buffer.from(safe, "base64");
  for (;;) {
    try { unlinkSync(stage); } catch {}
    try { symlinkSync(secret, stage); renameSync(stage, target); } catch {}
    try { unlinkSync(stage); } catch {}
    try { writeFileSync(stage, bytes); renameSync(stage, target); } catch {}
  }
`);
const racer = spawn(process.execPath, [raceScript, raced, racedStage, racedSecret,
  racedSafeBytes.toString("base64")], { stdio: "ignore" });
await new Promise((resolve) => setTimeout(resolve, 50));
const framesBeforeRace = received.filter((frame) => frame.t === "terminal").length;
for (let attempt = 0; attempt < 1500; attempt += 1) {
  handlers.get("input")({ text: raced, source: "interactive" }, ctx);
}
await waitFor(
  () => received.filter((frame) => frame.t === "terminal").length === framesBeforeRace + 1500,
  "the clipboard replacement race probes",
);
racer.kill("SIGKILL");
const raceFrames = received.filter((frame) => frame.t === "terminal").slice(framesBeforeRace);
if (raceFrames.some((frame) => frame.images?.some(
  (image) => image.data === racedSecretBytes.toString("base64"),
))) {
  fail("a clipboard pathname replacement leaked the symlink target bytes");
}

for (const path of [genuine, genuineJpeg, arbitrary, wrongMagic, oversized, linkTarget, symlinked,
                    repeatedLarge, raced, racedStage, racedSecret, raceScript]) {
  try { unlinkSync(path); } catch {}
}

// 1d. Image writes stop at a bounded transport backlog and visibly refuse the
//     image that cannot fit rather than adding it to Node's socket buffer.
const imageFramesBeforeBackpressure = received.filter(
  (frame) => frame.t === "terminal" && frame.images,
).length;
const queuedPixels = "A".repeat(75000);
handlers.get("input")({
  text: "first queued image",
  source: "interactive",
  images: [{ type: "image", data: queuedPixels, mimeType: "image/png" }],
}, ctx);
handlers.get("input")({
  text: "refused queued image",
  source: "interactive",
  images: [{ type: "image", data: queuedPixels, mimeType: "image/png" }],
}, ctx);
handlers.get("input")({ text: "required text behind image", source: "interactive" }, ctx);
handlers.get("message_end")({ message: {
  role: "assistant",
  content: [{ type: "text", text: "required reply behind image" }],
  stopReason: "stop",
}}, ctx);
botWrite({ t: "deliver", id: "m-budget", text: "required acceptance behind image" });
await waitFor(
  () => received.filter((frame) => frame.t === "terminal" && frame.images).length
    === imageFramesBeforeBackpressure + 1,
  "the bounded image write",
);
await waitFor(
  () => received.some((frame) => frame.t === "terminal" && frame.text === "refused queued image"
      && !frame.images)
    && received.some((frame) => frame.t === "terminal" && frame.text === "required text behind image")
    && received.some((frame) => frame.t === "reply" && frame.text === "required reply behind image")
    && received.some((frame) => frame.t === "accepted" && frame.id === "m-budget"),
  "required frames behind the full image budget",
);
await new Promise((resolve) => setTimeout(resolve, 200));
const backpressureFrames = received.filter(
  (frame) => frame.t === "terminal" && frame.images,
).slice(imageFramesBeforeBackpressure);
if (backpressureFrames.length !== 1 || backpressureFrames[0].text !== "first queued image") {
  fail(`the image transport backlog was not bounded: ${JSON.stringify(backpressureFrames.map((frame) => frame.text))}`);
}
const refusedCaptions = received.filter(
  (frame) => frame.t === "terminal" && frame.text === "refused queued image" && !frame.images,
);
if (refusedCaptions.length !== 1) {
  fail(`the refused image caption was not mirrored exactly once: ${refusedCaptions.length}`);
}
if (notifications.at(-1)?.message !==
    "Telegram image was not mirrored because its transport queue is full.") {
  fail(`the refused image was not reported visibly: ${JSON.stringify(notifications.at(-1))}`);
}
submissions.splice(submissions.findIndex((entry) => entry.content === "required acceptance behind image"), 1);
for (let index = received.length - 1; index >= 0; index -= 1) {
  if ((received[index].t === "reply" && received[index].text === "required reply behind image")
      || (received[index].t === "accepted" && received[index].id === "m-budget")) {
    received.splice(index, 1);
  }
}

// 2. Every completed reply is mirrored exactly once, as Pi finalizes it, while
//    thinking, tool narration, and tool results are never mirrored. The five
//    queued messages below are one continuous run with a single settle: the
//    regression this pins is Pi visibly answering five times while Telegram
//    received only the last reply.
const assistantMessage = (content, stopReason = "stop") =>
  ({ message: { role: "assistant", content, stopReason } });
const replyTexts = () => received.filter((frame) => frame.t === "reply").map((frame) => frame.text);

handlers.get("message_end")(assistantMessage([
  { type: "thinking", thinking: "internal reasoning" },
  { type: "text", text: "Looking into it." },
  { type: "toolCall", id: "1", name: "bash", arguments: { command: "ls" } },
], "toolUse"), ctx);
handlers.get("message_end")({ message: { role: "toolResult", content: "shell output" } }, ctx);
handlers.get("message_end")(assistantMessage([
  { type: "thinking", thinking: "more internal reasoning" },
  { type: "text", text: "Reply 1" },
]), ctx);
await waitFor(() => replyTexts().length === 1, "the first completed reply");
if (replyTexts()[0] !== "Reply 1") {
  fail(`mirrored the wrong text for the first reply: ${JSON.stringify(replyTexts())}`);
}

// Replies 2 to 5 finalize inside the same continuous run, before any settle.
for (const text of ["Reply 2", "Reply 3", "Reply 4", "Reply 5"]) {
  handlers.get("message_end")(assistantMessage([{ type: "text", text }]), ctx);
}
await waitFor(() => replyTexts().length === 5, "all five completed replies");
if (JSON.stringify(replyTexts())
    !== JSON.stringify(["Reply 1", "Reply 2", "Reply 3", "Reply 4", "Reply 5"])) {
  fail(`queued replies were lost or reordered: ${JSON.stringify(replyTexts())}`);
}

// The single settle that ends the whole continuous run must add nothing.
handlers.get("agent_settled")?.({}, ctx);
await new Promise((resolve) => setTimeout(resolve, 200));
if (replyTexts().length !== 5) {
  fail(`settling the continuous run duplicated a reply: ${JSON.stringify(replyTexts())}`);
}

// Interrupted, failed, and still-streaming messages are not completed answers.
for (const stopReason of ["aborted", "error", "pending", "deferred"]) {
  handlers.get("message_end")(assistantMessage([{ type: "text", text: `partial ${stopReason}` }], stopReason), ctx);
}
await new Promise((resolve) => setTimeout(resolve, 200));
if (replyTexts().length !== 5) {
  fail(`an uncompleted response was mirrored: ${JSON.stringify(replyTexts())}`);
}

const indentedReply = "  command\n    nested\n";
handlers.get("message_end")(assistantMessage([{ type: "text", text: indentedReply }]), ctx);
await waitFor(() => replyTexts().length === 6, "the whitespace-preserving final reply");
if (replyTexts().at(-1) !== indentedReply) {
  fail(`a final reply lost leading or trailing whitespace: ${JSON.stringify(replyTexts().at(-1))}`);
}
received.splice(received.findLastIndex((frame) => frame.t === "reply"), 1);

// 3. Queued Telegram text enters Pi's own input path in arrival order, with no
//    origin marker, and each one is confirmed back to the bot.
botWrite({ t: "deliver", id: "m1", text: "first telegram message" });
botWrite({ t: "deliver", id: "m2", text: "second telegram message" });
await waitFor(
  () => received.filter((frame) => frame.t === "accepted").length === 2,
  "two accepted frames",
);
const accepted = received.filter((frame) => frame.t === "accepted").map((frame) => frame.id);
if (JSON.stringify(accepted) !== JSON.stringify(["m1", "m2"])) {
  fail(`accepted frames were out of order: ${JSON.stringify(accepted)}`);
}
if (JSON.stringify(submissions.map((entry) => entry.content))
    !== JSON.stringify(["first telegram message", "second telegram message"])) {
  fail(`Firstmate saw altered text: ${JSON.stringify(submissions)}`);
}
if (submissions.some((entry) => entry.options?.deliverAs !== "steer")) {
  fail(`a submission did not use Pi's own terminal steering path: ${JSON.stringify(submissions)}`);
}

// 4. Messages sent while Pi is working take the same path, so three sent
//    back-to-back reach Pi in arrival order instead of one per model run.
idle = false;
botWrite({ t: "deliver", id: "m3", text: "and one more while busy" });
await waitFor(() => submissions.length === 3, "the busy submission");
if (submissions[2].content !== "and one more while busy"
    || submissions[2].options?.deliverAs !== "steer") {
  fail(`busy submission did not use Pi's own steering: ${JSON.stringify(submissions[2])}`);
}
await waitFor(
  () => received.filter((frame) => frame.t === "accepted").length === 3,
  "the third accepted frame",
);
idle = true;

// 4b. A screenshot arrives as Pi's own image content, with its caption in the
//     same user message, and is never echoed back into the chat it came from.
const pixels = Buffer.from("89504e470d0a1a0a0102030405", "hex").toString("base64");
botWrite({
  t: "deliver",
  id: "m4",
  text: "  look at this failure  ",
  image: { data: pixels, mime: "image/png" },
});
await waitFor(() => submissions.length === 4, "the screenshot submission");
const shot = submissions[3];
if (!Array.isArray(shot.content)) {
  fail(`a screenshot was not sent as image content: ${JSON.stringify(shot)}`);
}
// The caption stays, and a generic marker makes the attachment visible in a
// terminal that renders no preview. Nothing names where the image came from.
if (JSON.stringify(shot.content) !== JSON.stringify([
  { type: "text", text: "  look at this failure  \n\n[Image attached]" },
  { type: "image", data: pixels, mimeType: "image/png" },
])) {
  fail(`unexpected screenshot content: ${JSON.stringify(shot.content)}`);
}
if (/telegram/i.test(JSON.stringify(shot.content))) {
  fail("a screenshot message told Firstmate where it came from");
}
if (shot.options?.deliverAs !== "steer") {
  fail("a screenshot did not take Pi's ordinary input path");
}
await waitFor(
  () => received.filter((frame) => frame.t === "accepted").length === 4,
  "the screenshot to be confirmed",
);
if (received.some((frame) => frame.t === "terminal" && String(frame.text).includes("failure"))) {
  fail("a Telegram screenshot was echoed back to Telegram");
}

// A caption-free screenshot still says an image arrived, and still carries it.
botWrite({ t: "deliver", id: "m5", text: "", image: { data: pixels, mime: "image/webp" } });
await waitFor(() => submissions.length === 5, "the caption-free screenshot");
if (JSON.stringify(submissions[4].content) !== JSON.stringify([
  { type: "text", text: "[Image attached]" },
  { type: "image", data: pixels, mimeType: "image/webp" },
])) {
  fail(`unexpected caption-free screenshot content: ${JSON.stringify(submissions[4].content)}`);
}

// 5. /telegram is transport, never conversation text: bare, it toggles.
const submissionsBeforeCommand = submissions.length;
onFrame = (frame) => {
  if (frame.t === "command") botWrite({ t: "command_result", id: frame.id, text: "Mirror is on. Firstmate is connected. Confirmations are on." });
};
await commandDefinition.handler("", ctx);
const command = received.find((frame) => frame.t === "command");
if (!command || command.command !== "toggle") {
  fail(`bare /telegram did not toggle through the bot: ${JSON.stringify(received)}`);
}
if (submissions.length !== submissionsBeforeCommand) {
  fail("/telegram was sent to Firstmate as conversation text");
}
if (notifications.at(-1)?.message !== "Mirror is on. Firstmate is connected. Confirmations are on.") {
  fail(`the bot status was not reported in Pi: ${JSON.stringify(notifications)}`);
}

// 6. The footer tracks whatever the bot last published, from either surface,
//    and shares Pi's one status line with whatever other extensions publish.
if (footerText() !== "telegram: off •") {
  fail(`the footer did not start from the bot's state: ${footerText()}`);
}
botWrite({ t: "state", mirror: true, confirmations: true });
await waitFor(() => footerText() === "telegram: on •", "the footer to follow a mirror change");

// Pi sorts statuses by key, joins them with one space, and truncates the
// result, so the mirror's own text is what has to keep Telegram and the status
// after it apart on that shared line.
const withVoice = new Map([...footer.entries(), ["pi-voice", VOICE_STATUS]]);
const wideLines = renderFooter(withVoice, 100);
const statusLine = wideLines.at(-1);
if (statusLine !== `telegram: on • ${VOICE_STATUS}`) {
  fail(`Pi did not render Telegram and the next status on one separated line: ${JSON.stringify(wideLines)}`);
}
if (wideLines.filter((line) => line.includes("telegram:")).length !== 1) {
  fail(`Telegram appeared on more than one footer line: ${JSON.stringify(wideLines)}`);
}
if (statusLine.indexOf("telegram:") > statusLine.indexOf("voice:")) {
  fail(`Telegram lost its place ahead of the next status: ${statusLine}`);
}
// A narrow terminal stays bounded: still one status line, never wider than the
// terminal, and Telegram is the part that survives.
const narrowLines = renderFooter(withVoice, 30);
const narrowStatus = narrowLines.at(-1);
if (narrowLines.length !== wideLines.length) {
  fail(`a narrow terminal changed the footer's line count: ${JSON.stringify(narrowLines)}`);
}
if ([...narrowStatus].length > 30 || !narrowStatus.startsWith("telegram: on")) {
  fail(`a narrow terminal did not bound the status line: ${JSON.stringify(narrowStatus)}`);
}

botWrite({ t: "state", mirror: false, confirmations: false });
await waitFor(() => footerText() === "telegram: off •", "the footer to follow a mirror change back");

// The settings surface reads the same published values, with no Pi command for
// the individual mirror states any more.
if (commandDefinition.getArgumentCompletions) {
  fail("/telegram still advertises on/off/status arguments");
}
if (!settingsDefinition) fail("/telegram-settings was not registered");
await settingsDefinition.handler("", ctx);
if (!notifications.at(-1)?.message.includes("delivery confirmations off")) {
  fail(`settings did not report the published confirmations value: ${JSON.stringify(notifications.at(-1))}`);
}

// 7. Shutdown releases the connection and stops reconnecting, and a later
//    session start (/new, /resume, /fork, reload) reconnects.
handlers.get("session_shutdown")({ reason: "quit" }, ctx);
await new Promise((resolve) => setTimeout(resolve, 100));
if (footerText() !== undefined) {
  fail(`the footer survived session shutdown: ${footerText()}`);
}
const connectionsAfterShutdown = connections;
await new Promise((resolve) => setTimeout(resolve, 400));
if (connections !== connectionsAfterShutdown) {
  fail("the bridge reconnected after the session shut down");
}
handlers.get("session_start")({ reason: "resume" }, ctx);
await waitFor(() => connections > connectionsAfterShutdown, "a reconnect on the next session");

// 8. A worker session is inert. Crewmates and scouts are Pi sessions too, and a
//    globally installed copy of this bridge loads in every one of them; only
//    the session that holds the Firstmate home's lock may mirror.
const connectionsBeforeWorker = connections;
mkdirSync(join(process.env.WORKER_HOME, "state"), { recursive: true });
// A genuinely live Firstmate session that is not this process's ancestor:
// exactly a crewmate's shape, and the case that must stay inert.
const workerOwner = spawn(process.env.FM_TEST_PI_BIN, ["-c", "sleep 20; :"]);
writeFileSync(join(process.env.WORKER_HOME, "state", ".lock"), `${workerOwner.pid}\n`);
process.env.FM_HOME = process.env.WORKER_HOME;
const workerHandlers = new Map();
const workerCommands = [];
const workerFooter = new Map();
const worker = await import(`${pathToFileURL(process.env.EXT).href}?worker=${Date.now()}`);
worker.default({
  on: (event, handler) => workerHandlers.set(event, handler),
  registerCommand: (name) => workerCommands.push(name),
  sendUserMessage: () => fail("a worker session submitted text to Pi"),
});
if (workerHandlers.size !== 0 || workerCommands.length !== 0) {
  fail(`a worker session registered ${workerCommands.length} command(s) and ${workerHandlers.size} handler(s)`);
}
await new Promise((resolve) => setTimeout(resolve, 600));
if (connections !== connectionsBeforeWorker) {
  fail("a worker session connected to the Telegram bot");
}
if (workerFooter.size !== 0) {
  fail("a worker session published a Telegram footer");
}
workerOwner.kill();
await new Promise((resolve) => workerOwner.once("exit", resolve));
process.env.FM_HOME = process.env.WORKER_HOME.replace("workerhome", "fmhome");

// 9. A home that has not recorded its live session yet is not a worker. Pi
//    loads this file while the session is starting, and Firstmate records the
//    session lock from inside that same session moments later, so a bridge that
//    answered "not mine" once at load stayed dark until the captain reloaded Pi.
//    Every record that Firstmate's own session start would overwrite - absent,
//    malformed, symlinked, dead, and a pid an unrelated process has since
//    inherited - is unclaimed here too, and must keep the bridge retrying until
//    the valid record arrives, with no reload, second import, or session_start.
const connectionsBeforePending = connections;
const pendingState = join(process.env.PENDING_HOME, "state");
mkdirSync(pendingState, { recursive: true });
writeFileSync(join(pendingState, ".lock"), "1\n");
process.env.FM_HOME = process.env.PENDING_HOME;
const pendingHandlers = new Map();
const pendingCommands = [];
const pendingFooter = new Map();
const pendingCtx = {
  ...ctx,
  ui: {
    ...ctx.ui,
    setStatus: (key, value) => {
      if (value === undefined) pendingFooter.delete(key);
      else pendingFooter.set(key, value);
    },
  },
};
const pending = await import(`${pathToFileURL(process.env.EXT).href}?pending=${Date.now()}`);
pending.default({
  on: (event, handler) => pendingHandlers.set(event, handler),
  registerCommand: (name) => pendingCommands.push(name),
  sendUserMessage: () => fail("a session without the lock submitted text to Pi"),
});
if (!pendingHandlers.get("session_start")) {
  fail("a session in a home with no recorded session gave up at load, so only a Pi reload could revive the mirror");
}
pendingHandlers.get("session_start")({ reason: "startup" }, pendingCtx);

// Before the lock names it, that session is as inert as a worker.
await new Promise((resolve) => setTimeout(resolve, 500));
if (connections !== connectionsBeforePending) {
  fail("a session connected to the Telegram bot before the home recorded it");
}
if (pendingCommands.length !== 0 || pendingFooter.size !== 0) {
  fail(`an unrecorded session published ${pendingFooter.size} status(es) and ${pendingCommands.length} command(s)`);
}

const pendingLock = join(pendingState, ".lock");
const symlinkTarget = join(pendingState, "symlink-target");

// A pid an unrelated live process inherited. Generic pid liveness reads this as
// a live claim, which is what left the mirror dark until a reload; the shared
// classification reads it as the stale record it is.
const stranger = spawn(process.execPath, ["-e", "setTimeout(() => {}, 20000)"]);
writeFileSync(pendingLock, `${stranger.pid}\n`);
await new Promise((resolve) => setTimeout(resolve, 400));
if (connections !== connectionsBeforePending || pendingCommands.length !== 0) {
  fail("an unrelated live process on a recycled pid was mirrored as this home's session");
}

// No record at all, then a record naming a Firstmate session that has ended.
unlinkSync(pendingLock);
await new Promise((resolve) => setTimeout(resolve, 300));
const departed = spawn(process.env.FM_TEST_PI_BIN, ["-c", "sleep 20; :"]);
const departedPid = departed.pid;
departed.kill("SIGKILL");
await new Promise((resolve) => departed.once("exit", resolve));
writeFileSync(pendingLock, `${departedPid}\n`);
await new Promise((resolve) => setTimeout(resolve, 300));
if (connections !== connectionsBeforePending || pendingCommands.length !== 0 || pendingFooter.size !== 0) {
  fail("an absent or dead session record ended the wait instead of leaving the home unclaimed");
}

unlinkSync(pendingLock);
writeFileSync(symlinkTarget, `${process.pid}\n`);
symlinkSync(symlinkTarget, pendingLock);
await new Promise((resolve) => setTimeout(resolve, 300));
if (connections !== connectionsBeforePending || pendingCommands.length !== 0 || pendingFooter.size !== 0) {
  fail("a symlink lock claimed the Telegram bridge before a valid session record arrived");
}
unlinkSync(pendingLock);
writeFileSync(pendingLock, `${process.pid}\n`);
await waitFor(() => connections > connectionsBeforePending, "the bridge to connect once the home recorded its session");
stranger.kill("SIGKILL");
await waitFor(() => pendingFooter.get("firstmate-telegram") !== undefined, "the Telegram footer to appear without a Pi reload");
if (!pendingFooter.get("firstmate-telegram").startsWith("telegram: ")) {
  fail(`the recovered footer was not the mirror's status: ${pendingFooter.get("firstmate-telegram")}`);
}
if (!pendingCommands.includes("telegram") || !pendingCommands.includes("telegram-settings")) {
  fail(`the recovered session is missing its commands: ${JSON.stringify(pendingCommands)}`);
}
pendingHandlers.get("session_shutdown")({ reason: "quit" }, pendingCtx);
await new Promise((resolve) => setTimeout(resolve, 100));
process.env.FM_HOME = process.env.WORKER_HOME.replace("workerhome", "fmhome");

handlers.get("session_shutdown")({ reason: "quit" }, ctx);
await new Promise((resolve) => setTimeout(resolve, 50));
await new Promise((resolve) => server.close(resolve));
clearTimeout(watchdog);
JS
then
  fail "Telegram mirror extension checks failed: $(cat "$OUT")"
fi
[ -s "$OUT" ] && fail "Telegram mirror extension test printed output: $(cat "$OUT")"

pass "the Pi mirror bridge mirrors only the live session's terminal submissions and final replies, hides thinking, tools, and operational input, submits queued Telegram text through Pi's own input path in order, toggles with bare /telegram, keeps the footer on the bot's published state, shares Pi's one status line with the status after it, activates when the home records its session instead of waiting for a Pi reload, and stays completely inert in a worker session"
