#!/usr/bin/env bash
# Offline behavior tests for the public browser-step command and its parser.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-browser.sh"
pass() { printf 'ok - %s\n' "$1"; }

help=$("$SCRIPT" --help) || fail 'fm-browser --help failed'
assert_contains "$help" '--within <target>' 'help must document target scoping'
assert_contains "$help" 'Output is one compact JSON object' 'help must document the output privacy boundary'
assert_contains "$help" 'held afterward' 'help must define verification as a postcondition'
pass 'help documents the step contract'

set +e
out=$(CHROME_DEVTOOLS_AXI_SESSION=default "$SCRIPT" step --press Enter 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail 'the default browser session must be refused before launch'
assert_contains "$out" 'default browser session is not allowed' 'session refusal must name the safe requirement'
pass 'default session is refused'

for within in '' '   '; do
  set +e
  out=$("$SCRIPT" step --click 'button=Use' --within "$within" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail 'an empty within scope must be rejected before launch'
  assert_contains "$out" '--within needs a non-empty target' 'empty scope must not be treated as absent'
done
pass 'empty and whitespace-only within scopes are refused'

FM_BROWSER_ENGINE="$ROOT/bin/fm-browser-engine.mjs" node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const engine = await import(pathToFileURL(process.env.FM_BROWSER_ENGINE));

const secret = 'cfut_Zx9Kq2Lm8Rt4Vw6Yb1Nc3Hd5Jf7Gs0PaQe8Ui2Ok4';
const account = '0123456789abcdef0123456789abcdef';
for (const [input, needle, marker] of [
  [`Copy ${secret}`, secret, '[redacted]'],
  [`account ${account}`, account, '[opaque]'],
  ['ghp_abcdefghijklmnopqrstuvwxyz0123456789', 'ghp_abcdefghijklmnopqrstuvwxyz', '[redacted]'],
  ['github_pat_abcdefghijklmnopqrstuvwxyz0123456789', 'github_pat_abcdefghijklmnopqrstuvwxyz', '[redacted]'],
  ['sk-abcdefghijklmnopqrstuvwxyz0123456789', 'sk-abcdefghijklmnopqrstuvwxyz', '[redacted]'],
  ['Bearer abcdefghijklmnopqrstuvwxyz0123456789', 'Bearer abcdef', '[redacted]'],
]) {
  const safe = engine.redact(input);
  assert.equal(safe.includes(needle), false, `redactor leaked ${needle}`);
  assert.ok(safe.includes(marker), `redactor omitted ${marker}`);
}
assert.equal(engine.redact('Copy token=ab12cd34 and trailing details'), 'Copy token [redacted]');
assert.equal(engine.redact('Copy token abcdef'), 'Copy token [redacted]');
assert.equal(engine.redact('Authorization: Bearer abcdef'), 'Authorization [redacted]');
assert.equal(engine.redact('Copy API key Qx6'), 'Copy API [redacted]');
assert.equal(engine.redact('Copy API_KEY=Qx6'), 'Copy API [redacted]');
assert.equal(engine.redact('Copy access_token=ab12cd34'), 'Copy access_token [redacted]');
assert.equal(engine.redact('OTP abcdef'), 'OTP [redacted]');
assert.equal(engine.redact('passcode abcdef'), 'passcode [redacted]');
assert.equal(engine.redact('PIN abcdef'), 'PIN [redacted]');
assert.equal(engine.redact('View code samples'), 'View code samples');
assert.equal(engine.redact('mail jane@example.test').includes('jane@example.test'), false);
assert.ok(engine.redact('mail jane@example.test').includes('[email]'));
assert.equal(engine.redact('https://example.test/callback?code=123456'), '[url]');
assert.equal(engine.redact('OTP 123456').includes('123456'), false);
assert.ok(engine.redact('reference 987654').includes('[number]'));
assert.ok(engine.redact('Workers Scripts Edit').includes('Workers Scripts Edit'));
assert.ok(engine.redact('internationalization-settings-panel').includes('internationalization-settings-panel'));
const ordinaryCodeLabel = engine.sanitizeResult({ ok: true, appeared: ['button|View code samples'] });
assert.deepEqual(ordinaryCodeLabel.appeared, ['button|View code samples']);
assert.deepEqual(engine.sanitizeResult(ordinaryCodeLabel).appeared, ['button|View code samples']);

const snapshot = [
  'uid=g1:0 rootwebarea "Step fixture"',
  '  uid=g1:1 main',
  '    uid=g1:2 row "Token 7"',
  '      uid=g1:3 button "Use"',
  '    uid=g1:4 row "Token 8"',
  '      uid=g1:5 button "Use"',
  '    uid=g1:6 textbox "Token name" value="scout-fixture"',
].join('\n');
const nodes = engine.parseSnapshot(snapshot);
assert.equal(nodes.length, 7);
assert.equal(nodes[2].indent, 4);
const ambiguous = engine.resolveSelector(nodes, engine.parseSelector('button=Use'));
assert.equal(ambiguous.error, 'AMBIGUOUS_TARGET');
const useTarget = engine.resolveSelector(
  nodes,
  engine.parseSelector('button=Use'),
  engine.parseSelector('row=Token 8'),
);
assert.equal(useTarget.target.uid, 'g1:5');
const scoped = engine.resolveSelector(
  nodes,
  engine.parseSelector('button~us'),
  engine.parseSelector('row=Token 7'),
);
assert.equal(scoped.target.uid, 'g1:3');
assert.equal(engine.resolveSelector(nodes, engine.parseSelector('button=Use'), engine.parseSelector('row=Missing')).error, 'WITHIN_NOT_FOUND');
assert.equal(engine.resolveSelector(nodes, engine.parseSelector('button=Use'), engine.parseSelector('row~Token')).error, 'AMBIGUOUS_TARGET');
assert.throws(() => engine.validateParams({ action: 'select', target: 'button=Use', option: 'DNS Edit' }));

let index = 0;
const afterSnapshot = `${snapshot}\n    uid=g2:7 button "Copy token=ab12cd34"\n    uid=g2:8 button "Copy token abcdef"\n    uid=g2:9 button "Authorization: Bearer abcdef"\n    uid=g2:10 button "Copy API key Qx6"\n    uid=g2:11 button "Copy API_KEY=Qx6"\n    uid=g2:12 generic "${secret}"`;
const clickCalls = [];
const fakePage = {
  async snapshot() { return index++ === 0 ? snapshot : afterSnapshot; },
  async click(uid) { clickCalls.push(uid); },
  async fill() { throw new Error('not expected'); },
  async press() { throw new Error('not expected'); },
  async wait() {},
  async eval() { return '/safe-path'; },
};
const result = await engine.executeStep({
  action: 'click',
  target: 'button=Use',
  within: 'row=Token 8',
  expectation: { kind: 'appears', selector: 'button~Copy' },
}, fakePage);
assert.equal(result.ok, true);
assert.equal(result.verified, true);
assert.deepEqual(clickCalls, ['@g1:5']);
assert.deepEqual(result.appeared, [
  'button|Copy token [redacted]',
  'button|Copy token [redacted]',
  'button|Authorization [redacted]',
  'button|Copy API [redacted]',
  'button|Copy API [redacted]',
]);
assert.deepEqual(engine.sanitizeResult(result).appeared, result.appeared);
assert.equal(JSON.stringify(result).includes(secret), false);
assert.equal(JSON.stringify(result).includes('scout-fixture'), false);

let ambiguousClicks = 0;
const ambiguousTarget = await engine.executeStep({ action: 'click', target: 'button=Use' }, {
  async snapshot() { return snapshot; },
  async click() { ambiguousClicks += 1; },
});
assert.equal(ambiguousTarget.error, 'AMBIGUOUS_TARGET');
assert.equal(ambiguousClicks, 0);

const missingTarget = await engine.executeStep({ action: 'click', target: 'button=Settings' }, {
  ...fakePage,
  async snapshot() { return snapshot; },
});
assert.equal(missingTarget.error, 'TARGET_NOT_FOUND');
assert.equal(Object.hasOwn(missingTarget, 'candidates'), false);
assert.deepEqual(missingTarget.gone, []);

const actionFailure = await engine.executeStep({
  action: 'click', target: 'button=Use', within: 'row=Token 7',
}, {
  ...fakePage,
  async snapshot() { return snapshot; },
  async click() { throw new Error('rejected click'); },
});
assert.equal(actionFailure.ok, false);
assert.equal(actionFailure.verified, false);
assert.deepEqual(actionFailure.gone, []);
assert.deepEqual(actionFailure.appeared, []);

let fillValue = '';
index = 0;
const fillResult = await engine.executeStep({
  action: 'fill',
  target: 'textbox=Token name',
  value: 'scout-fixture',
}, {
  ...fakePage,
  async snapshot() { return snapshot; },
  async fill(uid, value) { fillValue = `${uid}:${value}`; },
});
assert.equal(fillValue, '@g1:6:scout-fixture');
assert.equal(fillResult.ok, true);
assert.equal(fillResult.verified, false);
assert.equal(JSON.stringify(fillResult).includes('scout-fixture'), false);

const alreadySatisfiedSnapshot = [
  'uid=s:0 rootwebarea "Save fixture"',
  '  uid=s:1 status "Saved"',
  '  uid=s:2 button "Save"',
].join('\n');
const alreadyAppears = await engine.executeStep({
  action: 'click', target: 'button=Save',
  expectation: { kind: 'appears', selector: 'status=Saved' },
}, {
  async snapshot() { return alreadySatisfiedSnapshot; },
  async click() {},
});
assert.equal(alreadyAppears.ok, true);
assert.equal(alreadyAppears.verified, true);
assert.equal(Object.hasOwn(alreadyAppears, 'reason'), false);
const alreadyGone = await engine.executeStep({
  action: 'click', target: 'button=Save',
  expectation: { kind: 'gone', selector: 'status=Pending' },
}, {
  async snapshot() { return alreadySatisfiedSnapshot; },
  async click() {},
});
assert.equal(alreadyGone.ok, true);
assert.equal(alreadyGone.verified, true);
assert.equal(Object.hasOwn(alreadyGone, 'reason'), false);
const alreadyTitle = await engine.executeStep({
  action: 'press', key: 'Enter',
  expectation: { kind: 'title', selector: 'title~Save fixture' },
}, {
  async snapshot() { return alreadySatisfiedSnapshot; },
  async press() {},
});
assert.equal(alreadyTitle.ok, true);
assert.equal(alreadyTitle.verified, true);
let stablePathReadCount = 0;
const alreadyPath = await engine.executeStep({
  action: 'press', key: 'Enter',
  expectation: { kind: 'url-path', path: '/same-path' },
}, {
  async snapshot() { return alreadySatisfiedSnapshot; },
  async press() {},
  async eval() { stablePathReadCount += 1; return '/same-path'; },
});
assert.equal(alreadyPath.ok, true);
assert.equal(alreadyPath.verified, true);
assert.equal(stablePathReadCount, 1);

const pendingSnapshot = 'uid=p:0 rootwebarea "Save fixture"\n  uid=p:1 status "Saving"\n  uid=p:2 button "Save"';
let saveSnapshotIndex = 0;
const gonePostcondition = await engine.executeStep({
  action: 'click', target: 'button=Save',
  expectation: { kind: 'gone', selector: 'status=Saving' },
}, {
  async snapshot() { return saveSnapshotIndex++ === 0 ? pendingSnapshot : alreadySatisfiedSnapshot; },
  async click() {},
});
assert.equal(gonePostcondition.ok, true);
assert.equal(gonePostcondition.verified, true);

let pressed = '';
let urlReadCount = 0;
const urlResult = await engine.executeStep({
  action: 'press', key: 'Enter', expectation: { kind: 'url-path', path: '/safe-path' },
}, {
  ...fakePage,
  async snapshot() { return snapshot; },
  async press(key) { pressed = key; },
  async eval() { urlReadCount += 1; return '/safe-path'; },
});
assert.equal(pressed, 'Enter');
assert.equal(urlResult.ok, true);
assert.equal(urlResult.verified, true);
assert.equal(urlReadCount, 1);
const titleResult = await engine.executeStep({
  action: 'press', key: 'Enter', expectation: { kind: 'title', selector: 'title~Build release 2' },
}, {
  ...fakePage,
  async snapshot() { return 'uid=t:0 rootwebarea "Build release 2"'; },
  async press() {},
});
assert.equal(titleResult.ok, true);
assert.equal(titleResult.verified, true);

const filtered = engine.sanitizeResult({
  step: 'step', ok: true, verified: true, appeared: [`button|${secret}`, 'button|Copy token=ab12cd34'], gone: ['button|Copy token abcdef with suffix', 'button|Copy access_token=abc'], ms: 4,
  value: secret, pageText: secret,
});
assert.equal(JSON.stringify(filtered).includes(secret), false);
assert.equal(JSON.stringify(filtered).includes('ab12cd34'), false);
assert.equal(JSON.stringify(filtered).includes('abcdef'), false);
assert.equal(JSON.stringify(filtered).includes('Qx6'), false);
assert.equal(JSON.stringify(filtered).includes('suffix'), false);
assert.equal(JSON.stringify(filtered).includes('abc'), false);
assert.equal(Object.hasOwn(filtered, 'value'), false);
console.log('offline parser, selector, execution, and redaction checks passed');
JS
pass 'selectors, within scoping, action execution, and redaction are covered'

printf 'all tests passed\n'
