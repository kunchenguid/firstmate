#!/usr/bin/env bash
# Portable public read-model/event tests; real rendering is covered by the live guard.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export NODE_NO_WARNINGS=1
FM_ACTIVITY_MODULE="$ROOT/.pi/extensions/lib/fm-branch-activity.ts" node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const { BranchActivity, ACTIVITY_STALE_MS } = await import(pathToFileURL(process.env.FM_ACTIVITY_MODULE));
const now = Date.now();
const m = new BranchActivity();
const row = (stage, reason, token='a', actor='branch') => ({time:new Date(now).toISOString(),token,actor,stage,reason,trigger:'signal',seqs:['1','2']});
assert.equal(m.view(now).state, 'unknown');
m.observeHealth({time:now,generation:1,owned:true,broken:'none'});
assert.equal(m.view(now).state, 'idle');
m.observe(row('admission','accepted'));
assert.equal(m.view(now).state, 'processing');
assert.match(m.view(now).lines[1], /not prompted/);
m.observe(row('settled','branch-complete','a','watcher'));
assert.equal(m.completed,null); // watcher quiet no-op is not a durable result
m.observe(row('settlement','empty-queue'));
assert.equal(m.view(now).state,'idle');
m.observe(row('report','routine'));
assert.equal(m.completed,null); // report before final settlement is not a completed batch
m.observe(row('admission','accepted'));
m.observe(row('prompt','started'));
assert.match(m.view(now).lines[1],/model\/tools/);
m.observe(row('settlement','reported-and-released'));
assert.match(m.view(now).lines[2],/durable branch result/);
m.observe(row('classify','check-main-only','b','watcher'));
m.observe(row('declined','ineligible-trigger','b','watcher'));
assert.equal(m.view(now).state,'idle');
assert.match(m.view(now).lines[3],/MAIN: check-main-only/);
m.observe(row('admission','accepted'));
m.observe(row('fallback','ownership-lost','a','watcher'));
assert.equal(m.view(now).state,'degraded');
assert.equal(m.active.size,0);
assert.equal(m.view(now+ACTIVITY_STALE_MS+1).state,'unknown');
m.observeHealth({time:now,generation:1,owned:true,broken:'provider'});
assert.equal(m.view(now).state,'error');
m.observeHealth({time:now,generation:1,owned:true,disabled:true});
assert.equal(m.view(now).state,'disabled');
m.observe(row('failure','secret\u001b[31m private message'));
assert.ok(!m.view(now).lines.join('').includes('secret'));
const n = new BranchActivity();
n.observe(row('admission','accepted'),true);
n.observe(row('report','captain'),true);
assert.equal(n.active.size,0); assert.equal(n.completed,null);
for(let i=0;i<1000;i++) n.observe(row('admission','accepted',String(i)));
assert.equal(n.active.size,16); assert.equal(n.view(now).state,'unknown');
console.log('ok - branch status distinguishes actual completion, expected fallback, failure, disabled and stale; bounds and redacts observations');
JS
status=$?
[ "$status" -eq 0 ] || fail 'branch activity model failed'
TMP_ROOT=$(fm_test_tmproot fm-pi-branch-status)
mkdir -p "$TMP_ROOT/.pi/extensions/lib" "$TMP_ROOT/node_modules/@earendil-works/pi-tui" "$TMP_ROOT/state"
cp "$ROOT/.pi/extensions/fm-branch-status.ts" "$TMP_ROOT/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/"{fm-branch-activity,fm-branch-dispatch,fm-async-exec}.ts "$TMP_ROOT/.pi/extensions/lib/"
printf '%s\n' '{"type":"module","exports":"./index.js"}' > "$TMP_ROOT/node_modules/@earendil-works/pi-tui/package.json"
printf '%s\n' 'export const truncateToWidth = (text, width) => text.slice(0,width);' > "$TMP_ROOT/node_modules/@earendil-works/pi-tui/index.js"
FM_STATUS_MODULE="$TMP_ROOT/.pi/extensions/fm-branch-status.ts" FM_STATE_OVERRIDE="$TMP_ROOT/state" node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { writeFileSync, readFileSync, readdirSync } from 'node:fs';
const {default:install} = await import(pathToFileURL(process.env.FM_STATUS_MODULE));
const lifecycle=new Map(), commands=new Map(), listeners=new Map();
let paints=0, actions=0, requests=0;
const events={on(name,fn){if(!listeners.has(name))listeners.set(name,new Set());listeners.get(name).add(fn);return()=>listeners.get(name).delete(fn)},
 emit(name,data){if(name==='firstmate:branch-health-request')requests++;for(const fn of listeners.get(name)??[])fn(data)}};
install({on:(name,fn)=>lifecycle.set(name,fn),registerCommand:(name,fn)=>commands.set(name,fn),events,
 sendMessage:()=>actions++,sendUserMessage:()=>actions++});
const ctx={mode:'tui',ui:{setWidget(_key,factory){if(factory){paints++;factory({}, {fg:(_c,s)=>s}).render(40)}}}};
const sleep=()=>new Promise(r=>setTimeout(r,180));
const state=process.env.FM_STATE_OVERRIDE;
writeFileSync(state+'/.wake-queue','untouched');writeFileSync(state+'/.lock','untouched');
const files=readdirSync(state).sort();
await lifecycle.get('session_start')({},ctx);
for(let i=0;i<1000;i++)events.emit('firstmate:branch-health',{time:Date.now(),generation:1,owned:true,broken:'none'});
await sleep();assert.equal(paints,1);
await lifecycle.get('session_shutdown')();
for(let i=0;i<1000;i++)events.emit('firstmate:branch-health',{time:Date.now(),generation:1,owned:true});
await sleep();assert.equal(paints,1);
await lifecycle.get('session_start')({},ctx);
for(let i=0;i<1000;i++)events.emit('firstmate:branch-health',{time:Date.now(),generation:2,owned:true});
await sleep();assert.equal(paints,2);assert.equal(listeners.get('firstmate:branch-health').size,1);
await commands.get('supervision-status').handler('',ctx);await sleep();assert.equal(paints,3);
await lifecycle.get('session_shutdown')();
await lifecycle.get('session_start')({}, {...ctx,mode:'json'});
await commands.get('supervision-status').handler('',{...ctx,mode:'json'});await sleep();
assert.equal(paints,3);assert.equal(actions,0);assert.equal(requests,3);
assert.deepEqual(readdirSync(state).sort(),files);assert.equal(readFileSync(state+'/.wake-queue','utf8'),'untouched');
assert.equal(readFileSync(state+'/.lock','utf8'),'untouched');
console.log('ok - 1000 notifications coalesce into one paint; shutdown/reload have no duplicate subscriptions; noninteractive UI and unrelated actions remain untouched');
JS
status=$?
[ "$status" -eq 0 ] || fail 'branch activity lifecycle failed'
