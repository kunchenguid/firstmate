#!/usr/bin/env bash
# tests/fm-browser-guard-block-live-e2e.test.sh - opt-in guard proving the flag
# emitted by bin/fm-browser-guard.sh actually blocks analytics requests in the
# REAL fleet browser (chrome-devtools-axi, headless).
#
# Why this file exists: the block relies on vendor behavior a stub cannot see -
# that headless Chrome honors --proxy-pac-url as a data: URL, routes a blocked
# host to a dead proxy with no DIRECT fallback so the request fails, and leaves
# everything else reachable. Chrome also STRIPS the path from HTTPS URLs before a
# PAC sees them and does NOT load extensions headless, which is exactly why the
# guard blocks by HOST rather than path; only a real browser can confirm the host
# block works. The portable counterpart in tests/fm-browser-guard.test.sh pins the
# decision logic and the spawn injection in CI.
#
# Safety: blocked probes are routed to a dead LOCAL proxy (127.0.0.1:9), so they
# fail without ever leaving the machine - no request reaches birdied or PostHog.
# The opt-out probe is routed through a LOCAL logging proxy that stubs every
# response, so it never connects out either.
#
# Standard CI has no browser, so this is opt-in and on-demand. Run it after a
# chrome-devtools-axi upgrade and before trusting refreshed evidence in
# docs/verification/browser-guard.md.
set -u

if [ "${FM_BROWSER_GUARD_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_BROWSER_GUARD_LIVE=1 to run the live chrome-devtools-axi analytics-block guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/bin/fm-browser-guard.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v node >/dev/null 2>&1 || fail "node not found"
command -v chrome-devtools-axi >/dev/null 2>&1 || { echo "skip: chrome-devtools-axi not installed"; exit 0; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-browser-guard-live.XXXXXX")
SRV_PID=
PROXY_PID=
SESSIONS=()

cleanup_all() {
  local s
  for s in "${SESSIONS[@]:-}"; do
    [ -n "$s" ] && CHROME_DEVTOOLS_AXI_SESSION="$s" chrome-devtools-axi stop >/dev/null 2>&1
  done
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

# --- local server: records hit paths, serves a blank page -------------------
cat > "$LAB/server.js" <<'JS'
const http = require('http');
const fs = require('fs');
const srv = http.createServer((req, res) => {
  fs.appendFileSync(process.env.HITLOG, req.url.split('?')[0] + "\n");
  res.end('ok');
});
srv.listen(0, '127.0.0.1', () => fs.writeFileSync(process.env.PORTFILE, String(srv.address().port)));
setTimeout(() => process.exit(0), 120000);
JS

# --- local logging forward proxy: logs requested paths and CONNECT targets,
# then stubs/closes so nothing egresses. CONNECT handling matters because the
# .app TLD is HSTS-preloaded, so Chrome force-upgrades birdied.app to HTTPS and
# routes it as a CONNECT tunnel rather than a plain proxied GET.
cat > "$LAB/proxy.js" <<'JS'
const http = require('http');
const fs = require('fs');
const proxy = http.createServer((req, res) => {
  let path = req.url;
  try { path = new URL(req.url).pathname; } catch (e) {}
  fs.appendFileSync(process.env.PROXYLOG, path + "\n");
  res.end('stub');
});
proxy.on('connect', (req, socket) => {
  fs.appendFileSync(process.env.PROXYLOG, "CONNECT " + req.url + "\n");
  socket.end(); // never tunnel out; the log entry is the delivery signal
});
proxy.listen(0, '127.0.0.1', () => fs.writeFileSync(process.env.PROXYPORTFILE, String(proxy.address().port)));
setTimeout(() => process.exit(0), 120000);
JS

HITLOG="$LAB/hits.log"; : > "$HITLOG"
PORTFILE="$LAB/port.txt"; rm -f "$PORTFILE"
HITLOG="$HITLOG" PORTFILE="$PORTFILE" node "$LAB/server.js" & SRV_PID=$!
for _ in $(seq 1 50); do [ -s "$PORTFILE" ] && break; sleep 0.1; done
[ -s "$PORTFILE" ] || fail "local server did not start"
PORT="$(cat "$PORTFILE")"

# ---------------------------------------------------------------------------
# Case 1: the shipped guard flag blocks analytics hosts and leaves normal
# traffic reachable, all in the real headless browser.
# ---------------------------------------------------------------------------
FLAG="$("$GUARD" chrome-args)" || fail "guard chrome-args failed"
S1="fm-guard-live-block-$$"
SESSIONS+=("$S1")
CHROME_DEVTOOLS_AXI_SESSION="$S1" CHROME_DEVTOOLS_AXI_CHROME_ARGS="$FLAG" \
  chrome-devtools-axi open "http://127.0.0.1:$PORT/blank" >/dev/null 2>&1 \
  || fail "browser failed to open under the guard flag"

# Return flat key=VALUE tokens (no quotes/JSON) so the verdicts survive
# chrome-devtools-axi's own output escaping and grep cleanly.
PROBE=$(CHROME_DEVTOOLS_AXI_SESSION="$S1" chrome-devtools-axi eval '() => {
  const probe = (u) => Promise.race([
    fetch(u, {mode:"no-cors"}).then(()=>"REACHED").catch(()=>"BLOCKED"),
    new Promise(r=>setTimeout(()=>r("BLOCKED"), 6000))
  ]);
  return Promise.all([
    probe("http://birdied.app/"),
    probe("https://birdied.app/ingest/e/"),
    probe("https://eu.i.posthog.com/e/"),
    probe("https://posthog.com/"),
    probe(location.origin + "/ok")
  ]).then(([apex, apexIngest, phEu, phApex, ok]) =>
    ["apex="+apex, "apexIngest="+apexIngest, "phEu="+phEu, "phApex="+phApex, "ok="+ok].join(" "));
}' 2>&1)
CHROME_DEVTOOLS_AXI_SESSION="$S1" chrome-devtools-axi stop >/dev/null 2>&1

has() { printf '%s' "$PROBE" | grep -q "$1"; }
has 'apex=BLOCKED'       || fail "birdied production apex was NOT blocked under the guard flag: $PROBE"
has 'apexIngest=BLOCKED' || fail "birdied first-party /ingest beacon was NOT blocked under the guard flag: $PROBE"
has 'phEu=BLOCKED'       || fail "PostHog EU cloud ingest was NOT blocked under the guard flag: $PROBE"
has 'phApex=BLOCKED'     || fail "posthog.com was NOT blocked under the guard flag: $PROBE"
has 'ok=REACHED'         || fail "normal same-origin traffic was broken by the guard flag: $PROBE"
grep -q '^/ok$' "$HITLOG" || fail "the allowed request did not actually reach the local server"
pass "live: guard flag blocks birdied apex, its /ingest beacon, and PostHog cloud while normal traffic still flows"

# ---------------------------------------------------------------------------
# Case 2: opt-out. With the block absent and traffic routed through an
# observable proxy, the same analytics request is DELIVERED (not intrinsically
# dropped) - proving the block is what stops it, and the opt-out opens it.
# ---------------------------------------------------------------------------
cat > "$LAB/proxy-run.txt" <<'NOTE'
Case 2 routes through a local logging proxy instead of DIRECT so the opt-out
delivery is observable without any real network egress.
NOTE
PROXYLOG="$LAB/proxy.log"; : > "$PROXYLOG"
PROXYPORTFILE="$LAB/proxyport.txt"; rm -f "$PROXYPORTFILE"
PROXYLOG="$PROXYLOG" PROXYPORTFILE="$PROXYPORTFILE" node "$LAB/proxy.js" & PROXY_PID=$!
for _ in $(seq 1 50); do [ -s "$PROXYPORTFILE" ] && break; sleep 0.1; done
[ -s "$PROXYPORTFILE" ] || fail "local logging proxy did not start"
PROXYPORT="$(cat "$PROXYPORTFILE")"

S2="fm-guard-live-optout-$$"
SESSIONS+=("$S2")
# A top-level navigation through the observable proxy is the cleanest delivery
# signal: with no block, the analytics request reaches the proxy (which stubs it,
# so nothing egresses).
CHROME_DEVTOOLS_AXI_SESSION="$S2" CHROME_DEVTOOLS_AXI_CHROME_ARGS="--proxy-server=127.0.0.1:$PROXYPORT" \
  chrome-devtools-axi open "http://birdied.app/ingest/optout-probe" >/dev/null 2>&1 \
  || fail "browser failed to open in the opt-out configuration"
sleep 1
CHROME_DEVTOOLS_AXI_SESSION="$S2" chrome-devtools-axi stop >/dev/null 2>&1

grep -q 'birdied.app' "$PROXYLOG" \
  || fail "opt-out: the analytics request was not delivered through the observable proxy (log: $(cat "$PROXYLOG"))"
pass "live: without the block, the analytics request is delivered (opt-out opens it)"

kill "$SRV_PID" 2>/dev/null; SRV_PID=
kill "$PROXY_PID" 2>/dev/null; PROXY_PID=
note "live browser analytics guard verified against $(chrome-devtools-axi --version 2>/dev/null | head -1)"
