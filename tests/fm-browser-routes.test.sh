#!/usr/bin/env bash
# Offline route-contract checks plus an opt-in live fixture replay.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENGINE="$ROOT/bin/fm-browser-engine.mjs"
SCRIPT="$ROOT/bin/fm-browser.sh"
FM_BROWSER_ENGINE="$ENGINE" node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const engine = await import(pathToFileURL(process.env.FM_BROWSER_ENGINE));
const route = {
  version: 1,
  host: '127.0.0.1',
  route: 'fixture',
  start: { url_path: '/routes.html' },
  vars: { name: { required: true } },
  steps: [
    { id: 'name', do: 'fill', target: { role: 'textbox', label: 'Route name' }, value: '${name}', expect: { appears: { role: 'heading', label: 'Name recorded' } } },
    { id: 'reveal', do: 'click', target: { role: 'button', label: 'Reveal fixture' }, expect: { appears: { role: 'heading', label: 'Route finished' } } },
    { id: 'handback', do: 'handoff', say: 'Continue in the browser', expect: { appears: { role: 'heading', label: 'Route finished' } } },
  ],
  heal_log: [],
};
assert.equal(engine.validateRoute(route), route);
assert.throws(() => engine.validateRoute({ ...route, version: 2 }));
assert.throws(() => engine.validateRoute({ ...route, steps: [...route.steps, route.steps[0]] }));
const snapshot = 'uid=x:0 rootwebarea "fixture"\n  uid=x:1 textbox "Route name"\n  uid=x:2 button "Reveal fixture"\n  uid=x:3 heading "Name recorded"\n  uid=x:4 heading "Route finished"';
let actionLog = [];
const page = {
  async eval(fn) {
    const source = String(fn);
    if (source.includes('location.hostname')) return { host: '127.0.0.1', path: '/routes.html' };
    if (source.includes('location.pathname')) return '/routes.html';
    return null;
  },
  async snapshot() { return snapshot; },
  async fill(target, value) { actionLog.push(['fill', target, value]); },
  async click(target) { actionLog.push(['click', target]); },
  async press(key) { actionLog.push(['press', key]); },
  async wait() {},
};
let result = await engine.executeRoute(route, { name: 'deployment' }, null, page);
assert.equal(result.ok, true);
assert.deepEqual(result.completed, ['name', 'reveal', 'handback']);
assert.deepEqual(result.handoff, { step: 'handback', say: 'Continue in the browser' });
assert.deepEqual(actionLog[0], ['fill', '@x:1', 'deployment']);
assert.deepEqual(actionLog[1], ['click', '@x:2']);
assert.equal(JSON.stringify(result).includes('deployment'), false);
result = await engine.executeRoute(route, { name: 'deployment' }, 'reveal', page);
assert.equal(result.ok, true);
assert.deepEqual(result.completed, ['reveal', 'handback']);
for (const [vars, error] of [
  [{}, 'MISSING_VARIABLE'],
  [{ name: 'deployment', extra: 'x' }, 'UNKNOWN_VARIABLE'],
  [{ name: 'ghp_abcdefghijklmnopqrstuvwxyz123456' }, 'UNSAFE_VARIABLE'],
  [{ name: 'ABCDEFGHIJKLMNOPQRSTUVWX1234' }, 'UNSAFE_VARIABLE'],
]) {
  const response = await engine.executeRoute(route, vars, null, page);
  assert.equal(response.error, error);
}
const confirmed = { ...route, steps: [{ id: 'danger', do: 'click', confirm: true, target: { role: 'button', label: 'Reveal fixture' } }] };
actionLog = [];
result = await engine.executeRoute(confirmed, { name: 'safe' }, null, page);
assert.equal(result.error, 'CONFIRM_REQUIRED');
assert.deepEqual(actionLog, []);
const mismatchPage = { ...page, async eval(fn) { return fn.toString().includes('hostname') ? { host: 'elsewhere.test', path: '/routes.html' } : null; } };
assert.equal((await engine.executeRoute(route, { name: 'safe' }, null, mismatchPage)).error, 'START_MISMATCH');
console.log('offline route format, variables, resume, confirmation, and replay checks passed');
JS
pass 'route format, interpolation, resume, confirmation, and one-run sequencing are covered'

fm_live_gate default-on FM_BROWSER_ROUTES_LIVE chrome-devtools-axi node python3
TMP_HOME=$(fm_test_tmproot fm-browser-routes)
mkdir -p "$TMP_HOME/data/browser-routes/127.0.0.1"
PORT=$((40000 + $$ % 20000))
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT/tests/fixtures/browser-steps" >/dev/null 2>&1 &
SERVER_PID=$!
SESSION="fm-browser-routes-$$-${RANDOM}"
STARTED=0
cleanup_routes() {
  if [ "$STARTED" -eq 1 ]; then
    CHROME_DEVTOOLS_AXI_SESSION="$SESSION" chrome-devtools-axi stop >/dev/null 2>&1 || true
  fi
  kill "$SERVER_PID" >/dev/null 2>&1 || true
  wait "$SERVER_PID" >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_routes EXIT INT TERM
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/routes.html" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
curl -fsS "http://127.0.0.1:$PORT/routes.html" >/dev/null || fail 'fixture server did not become ready'
cat >"$TMP_HOME/data/browser-routes/127.0.0.1/fixture.json" <<'JSON'
{
  "version": 1,
  "host": "127.0.0.1",
  "route": "fixture",
  "start": { "url_path": "/routes.html" },
  "vars": { "name": { "required": true } },
  "steps": [
    { "id": "name", "do": "fill", "target": { "role": "textbox", "label": "Route name" }, "value": "${name}", "expect": { "appears": { "role": "heading", "label": "Name recorded" } } },
    { "id": "reveal", "do": "click", "target": { "role": "button", "label": "Reveal fixture" }, "expect": { "appears": { "role": "heading", "label": "Route finished" } } },
    { "id": "handoff", "do": "handoff", "say": "Continue in the browser", "expect": { "appears": { "role": "heading", "label": "Route finished" } } }
  ],
  "heal_log": []
}
JSON
chmod 600 "$TMP_HOME/data/browser-routes/127.0.0.1/fixture.json"
unset CHROME_DEVTOOLS_AXI_AUTO_CONNECT CHROME_DEVTOOLS_AXI_BROWSER_URL \
  CHROME_DEVTOOLS_AXI_WS_HEADERS CHROME_DEVTOOLS_AXI_USER_DATA_DIR \
  CHROME_DEVTOOLS_AXI_PORT CHROME_DEVTOOLS_AXI_CHROME_ARGS
export CHROME_DEVTOOLS_AXI_SESSION="$SESSION"
chrome-devtools-axi start >/dev/null 2>&1 || fail 'could not start the named isolated browser session'
STARTED=1
printf 'await page.open("http://127.0.0.1:%s/routes.html");\nconsole.log("ready");\n' "$PORT" | chrome-devtools-axi run >/dev/null 2>&1 || fail 'could not open the route fixture'
OUT=$(FM_HOME="$TMP_HOME" "$SCRIPT" route run 127.0.0.1/fixture --var name=route-fixture --session "$SESSION") || fail "route did not replay: $OUT"
node -e 'const r=JSON.parse(process.argv[1]); if (!r.ok || r.completed.join(",") !== "name,reveal,handoff") process.exit(1)' "$OUT" || fail "route output did not confirm the full sequence: $OUT"
ROUTE=$(cat "$TMP_HOME/data/browser-routes/127.0.0.1/fixture.json")
case "$ROUTE" in *'route-fixture'*) fail 'a route variable value was written to disk' ;; esac
pass 'one named-session browser run replays, verifies, and keeps variable values out of route storage'
OUT=$(FM_HOME="$TMP_HOME" "$SCRIPT" step --fill 'textbox=Route name' --value recorded-literal --expect 'heading=Name recorded' --record 127.0.0.1/recorded --record-var name --session "$SESSION") || fail "verified step was not recorded: $OUT"
RECORDED=$(cat "$TMP_HOME/data/browser-routes/127.0.0.1/recorded.json")
case "$RECORDED" in *'${name}'*) ;; *) fail 'recorded fill did not use its named variable placeholder' ;; esac
case "$RECORDED" in *recorded-literal*) fail 'recorded input value was persisted' ;; esac
pass 'verified steps append safely and replace fill text with a named variable'
cat >"$TMP_HOME/data/browser-routes/127.0.0.1/heal.json" <<'JSON'
{
  "version": 1,
  "host": "127.0.0.1",
  "route": "heal",
  "start": { "url_path": "/routes.html" },
  "vars": {},
  "steps": [
    { "id": "renamed", "do": "click", "target": { "role": "button", "label": "Reveal fixture now" }, "expect": { "appears": { "role": "heading", "label": "Route finished" } } }
  ],
  "heal_log": []
}
JSON
chmod 600 "$TMP_HOME/data/browser-routes/127.0.0.1/heal.json"
printf 'await page.open("http://127.0.0.1:%s/routes.html");\nconsole.log("ready");\n' "$PORT" | chrome-devtools-axi run >/dev/null 2>&1 || fail 'could not reset the route fixture'
OUT=$(FM_HOME="$TMP_HOME" "$SCRIPT" route run 127.0.0.1/heal --session "$SESSION") || fail "route did not recover a renamed control: $OUT"
node -e 'const r=JSON.parse(process.argv[1]); if (!r.ok || r.completed.join(",") !== "renamed") process.exit(1)' "$OUT" || fail "healed route result was not successful: $OUT"
HEALED=$(cat "$TMP_HOME/data/browser-routes/127.0.0.1/heal.json")
case "$HEALED" in *'Reveal fixture"'*) ;; *) fail 'verified local healing did not update the saved target' ;; esac
case "$HEALED" in *'"by": "local"'*) ;; *) fail 'verified local healing did not append its local heal record' ;; esac
pass 'a locally healed target is written back only after its expectation verifies'
printf 'browser route tests passed\n'
