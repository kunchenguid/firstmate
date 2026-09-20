#!/usr/bin/env bash
# Releases lavish-axi's per-page SSE connection while a review page's tab is hidden, and
# reconnects it when shown again, so a captain with several review pages open does not
# exhaust the browser's six-connection-per-origin budget (data/fm-lavish-pages-dont-load/report.md).
# Idempotent: detects whether the patch is already present and does nothing if so.
# Any lavish-axi upgrade reinstalls an unpatched dist/chrome-client.js; re-run this after upgrading.
set -euo pipefail

CLIENT="$(npm root -g)/lavish-axi/dist/chrome-client.js"

if [[ ! -f "$CLIENT" ]]; then
  echo "fm-lavish-client-patch: $CLIENT not found (is lavish-axi installed globally?)" >&2
  exit 1
fi

if grep -q "fm-lavish-client-patch: release SSE on hide" "$CLIENT"; then
  echo "fm-lavish-client-patch: already applied to $CLIENT"
  exit 0
fi

node --input-type=module -e '
import { readFileSync, writeFileSync } from "node:fs";
const path = process.argv[1];
const src = readFileSync(path, "utf8");

const needle = `const events = new EventSource("/events/" + key);
events.addEventListener("reload", () => {
  resetFrame().then((reloaded) => {
    if (reloaded) refreshWhiteboardSource();
  });
});
events.addEventListener("chrome-reload", (event) => reloadAfterServerRestart(shutdownEventReason(event)));
// The replacement server serves a different artifact'"'"'s review. This page keeps working against
// it; it is only running the previous version of the chrome, which is the user'"'"'s to act on.
events.addEventListener("chrome-outdated", (event) => setChromeOutdated(true, shutdownEventReason(event)));
events.addEventListener("agent-reply", (event) => {
  const text = JSON.parse(event.data).text;
  addChat("agent", text);
  noteAgentReply(text);
});
events.addEventListener("chat-sync", (event) => syncChat(JSON.parse(event.data).chat || []));
events.addEventListener("agent-presence", (event) => setAgentPresence(JSON.parse(event.data).state));
events.addEventListener("layout-warnings", (event) => setLayoutWarnings(JSON.parse(event.data).warnings || []));
events.addEventListener("ended", () => markSessionEnded());
// A reconnecting stream means this chrome may have missed updates while it was away.
events.addEventListener("open", () => refreshLayoutWarnings());`;

const idx = src.indexOf(needle);
if (idx === -1) {
  console.error("fm-lavish-client-patch: expected code shape not found - lavish-axi client changed, patch needs a manual update");
  process.exit(1);
}

const replacement = `let events;
function fmBindEventsStream() {
  events = new EventSource("/events/" + key);
  events.addEventListener("reload", () => {
    resetFrame().then((reloaded) => {
      if (reloaded) refreshWhiteboardSource();
    });
  });
  events.addEventListener("chrome-reload", (event) => reloadAfterServerRestart(shutdownEventReason(event)));
  // The replacement server serves a different artifact'"'"'s review. This page keeps working against
  // it; it is only running the previous version of the chrome, which is the user'"'"'s to act on.
  events.addEventListener("chrome-outdated", (event) => setChromeOutdated(true, shutdownEventReason(event)));
  events.addEventListener("agent-reply", (event) => {
    const text = JSON.parse(event.data).text;
    addChat("agent", text);
    noteAgentReply(text);
  });
  events.addEventListener("chat-sync", (event) => syncChat(JSON.parse(event.data).chat || []));
  events.addEventListener("agent-presence", (event) => setAgentPresence(JSON.parse(event.data).state));
  events.addEventListener("layout-warnings", (event) => setLayoutWarnings(JSON.parse(event.data).warnings || []));
  events.addEventListener("ended", () => markSessionEnded());
  // A reconnecting stream means this chrome may have missed updates while it was away.
  events.addEventListener("open", () => refreshLayoutWarnings());
}
fmBindEventsStream();
// fm-lavish-client-patch: release SSE on hide - each open page permanently holds one of the
// browser'"'"'s six per-origin connections; drop it while backgrounded and reopen when shown again
// (bin/fm-lavish-client-patch.sh, docs/lavish-connection-limit.md).
document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    events.close();
  } else if (events.readyState === EventSource.CLOSED) {
    fmBindEventsStream();
  }
});`;

writeFileSync(path, src.slice(0, idx) + replacement + src.slice(idx + needle.length));
console.log("fm-lavish-client-patch: patched " + path);
' "$CLIENT"

echo "fm-lavish-client-patch: restart the lavish-axi server for the patch to take effect (lavish-axi stop / relaunch)."
