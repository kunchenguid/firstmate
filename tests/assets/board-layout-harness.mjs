// Execute a built board in Chromium and measure the actual owner glyphs against
// their clipping ancestors. A DOM shim sees text even when the captain cannot.
// 1080px is the board viewport at 1440px with Lavish's 360px sidebar open.
// Usage: node board-layout-harness.mjs <chrome> <built-board.html>
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

function measureOwners() {
  return [...document.querySelectorAll("#bb-charted .bb-row")].map((row, i) => {
    const owner = ["(main)", "mate"][i];
    const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
    let text;
    while ((text = walker.nextNode())) {
      const at = text.textContent.lastIndexOf(owner);
      // "mate" inside the repository name "firstmate" is not its owner label.
      if (at < 0 || (at > 0 && !/\s/.test(text.textContent[at - 1])) ||
          (at + owner.length < text.length && !/\s/.test(text.textContent[at + owner.length]))) continue;
      const range = document.createRange();
      range.setStart(text, at);
      range.setEnd(text, at + owner.length);
      const rects = [...range.getClientRects()];
      const clips = [{left: 0, top: 0, right: innerWidth, bottom: innerHeight}];
      for (let parent = text.parentElement; parent; parent = parent.parentElement) {
        const style = getComputedStyle(parent);
        if (style.overflowX !== "visible" || style.overflowY !== "visible") {
          clips.push(parent.getBoundingClientRect());
        }
      }
      return {owner, visible: rects.length > 0 && rects.every(rect =>
        rect.width > 0 && rect.height > 0 && clips.every(clip =>
          rect.left >= clip.left - 1 && rect.right <= clip.right + 1 &&
          rect.top >= clip.top - 1 && rect.bottom <= clip.bottom + 1)),
        rects: rects.map(rect => rect.toJSON()),
        clips: clips.map(clip => clip.toJSON ? clip.toJSON() : clip)};
    }
    return {owner, visible: false, missing: true};
  });
}

const [chrome, board] = process.argv.slice(2);
const browser = spawn(chrome, [
  "--headless=new", "--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage",
  "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
  `--user-data-dir=${join(dirname(board), "chrome-profile")}`,
  "--remote-debugging-pipe", "about:blank",
], {stdio: ["ignore", "ignore", "pipe", "pipe", "pipe"]});
let serial = 0, buffer = "", stderr = "";
const pending = new Map();
function call(method, params = {}, sessionId) {
  return new Promise((resolve, reject) => {
    const id = ++serial;
    pending.set(id, {resolve, reject});
    browser.stdio[3].write(JSON.stringify({id, method, params, sessionId}) + "\0");
  });
}
function rejectPending(error) {
  for (const request of pending.values()) request.reject(error);
  pending.clear();
}
browser.stderr.on("data", chunk => { stderr = (stderr + chunk).slice(-4000); });
browser.on("error", rejectPending);
browser.stdio[3].on("error", rejectPending);
browser.stdio[4].on("data", chunk => {
  buffer += chunk;
  let end;
  while ((end = buffer.indexOf("\0")) >= 0) {
    const message = JSON.parse(buffer.slice(0, end));
    buffer = buffer.slice(end + 1);
    const request = pending.get(message.id);
    if (!request) continue;
    pending.delete(message.id);
    if (message.error) request.reject(new Error(JSON.stringify(message.error)));
    else request.resolve(message.result);
  }
});
const closed = new Promise(resolve => browser.on("close", () => {
  rejectPending(new Error(`Browser exited: ${stderr}`));
  resolve();
}));
const deadline = setTimeout(() => {
  rejectPending(new Error(`Browser layout check timed out: ${stderr}`));
  browser.kill("SIGKILL");
}, 30000);
try {
  const {targetId} = await call("Target.createTarget", {url: "about:blank"});
  const {sessionId} = await call("Target.attachToTarget", {targetId, flatten: true});
  const evaluate = async expression => {
    const result = await call("Runtime.evaluate", {expression, returnByValue: true, awaitPromise: true}, sessionId);
    assert.ok(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  await call("Emulation.setDeviceMetricsOverride", {
    width: 1080, height: 1250, deviceScaleFactor: 1, mobile: false,
  }, sessionId);
  // Block font requests before navigation: DNS failure can leave the imported
  // stylesheet pending and prevent the board script and fonts.ready completing.
  // Request blocking exercises fallback fonts without consulting the network.
  await call("Network.enable", {}, sessionId);
  await call("Network.setBlockedURLs", {
    urls: ["https://fonts.googleapis.com/*", "https://fonts.gstatic.com/*"],
  }, sessionId);
  await call("Page.navigate", {url: pathToFileURL(board).href}, sessionId);
  for (let tries = 0; tries < 100; tries++) {
    if (await evaluate('!!document.querySelector("#bb-charted .bb-row")')) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  await evaluate("document.fonts.ready.then(() => true)");
  const owners = await evaluate(`(${measureOwners})()`);
  assert.deepEqual(owners.map(row => row.owner), ["(main)", "mate"]);
  assert.ok(owners.every(row => row.visible), `Queued owners are clipped: ${JSON.stringify(owners)}`);
} finally {
  clearTimeout(deadline);
  const reap = setTimeout(() => browser.kill("SIGKILL"), 2000);
  browser.kill("SIGTERM");
  await closed;
  clearTimeout(reap);
}
