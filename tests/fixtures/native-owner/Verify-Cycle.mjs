// Verify captured protocol and durable command outcomes without another model turn.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../../..');
const state=path.join(repo,'data/native-candidate-validation');
const read=file=>JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,''));
const hash=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const latest=read(path.join(state,'cycle-latest.json'));
const home=latest.home;
const build=read(path.join(home,'build.json'));
const host=read(path.join(home,'app-host-evidence.json'));
const native=read(path.join(home,'result.json'));
assert.equal(latest.exit,0);assert.equal(native.rootExit,0);assert.equal(host.passed,true);
assert.deepEqual(Object.keys(host.externalTools).sort(),['activeMcpServers','appsFeatureEnabled','configuredMcpServers','enabledMcpServers','exposedApps','pluginsFeatureEnabled']);
assert.equal(host.externalTools.appsFeatureEnabled,false);assert.equal(host.externalTools.pluginsFeatureEnabled,false);
assert.ok(Array.isArray(host.externalTools.configuredMcpServers));assert.deepEqual(host.externalTools.enabledMcpServers,[]);
assert.deepEqual(host.externalTools.exposedApps,[]);assert.deepEqual(host.externalTools.activeMcpServers,[]);
assert.deepEqual(host.shutdown,{stopped:true,operationsStopped:true,reconciliationRequired:false,exited:true,forced:false,errors:[]});
assert.notEqual(host.primary,host.foreign);assert.equal(host.tools.length,4);
const requests=host.frames.filter(frame=>frame.method==='item/tool/call');
assert.equal(requests.length,4);
for(const tool of host.tools)assert.ok(requests.some(frame=>frame.id===tool.requestId&&frame.params.threadId===tool.threadId&&frame.params.turnId===tool.turnId&&frame.params.callId===tool.callId&&JSON.stringify(frame.params.arguments)===JSON.stringify(tool.arguments)));
assert.equal(host.frames.filter(frame=>frame.method==='turn/completed'&&frame.params.turn.status==='completed').length,2);
const primary=host.tools.filter(tool=>tool.threadId===host.primary);
assert.deepEqual(primary.map(tool=>tool.success),[true,true,false]);
assert.equal(primary[1].arguments.receipt,primary[0].result.receipt);
assert.equal(primary[1].arguments.observed,primary[0].result.challenge);
assert.equal(primary[2].result.denied,'receipt-already-consumed');
assert.equal(host.tools.find(tool=>tool.threadId===host.foreign).result.denied,'wrong-thread-turn-or-replay');
assert.equal(host.nativeReplayDenied,true);
assert.equal(host.native.filter(row=>row.action==='check'&&row.state==='pending').length,1);
assert.equal(host.native.filter(row=>row.action==='ack'&&row.state==='pending').length,1);
assert.equal(native.notificationConsumed,true);
assert.ok(host.native.filter(row=>row.action==='check'||row.action==='ack').every(row=>row.startupExpired));
const delivered=read(path.join(home,'notification-check.json'));
const acknowledgement=read(path.join(home,'notification-ack-request.json'));
for(const key of ['seq','generation','note','challenge'])assert.equal(acknowledgement[key],delivered[key]);
assert.equal(delivered.challenge,primary[1].arguments.observed);
const journal=fs.readFileSync(path.join(home,'home/owner-receipts.jsonl'),'utf8').trim().split('\n').map(line=>JSON.parse(line));
assert.deepEqual(journal.map(row=>row.event),['session','presented','ack-started','acknowledged']);
assert.ok(journal.every(row=>row.generation===native.probeGeneration));
for(const row of journal.slice(1)) {
 assert.equal(row.receipt,primary[0].result.receipt);
 for(const key of ['seq','generation','note','challenge'])assert.equal(row.payload[key],delivered[key]);
}
assert.ok(fs.readFileSync(path.join(home,'cycle-delivery.log'),'utf8').includes(`--ack-through ${delivered.seq} --recovery-generation ${delivered.generation}`));
assert.equal(read(path.join(home,'notification-ack.json')).acknowledged,true);
const operational=path.join(home,'home','state');
assert.equal(fs.readFileSync(path.join(operational,'.wake-queue'),'utf8').trim(),'');
const handled=path.join(operational,'inbox/handled',delivered.note+'.note');
assert.ok(fs.existsSync(handled));
const targets=journal[2].targetEvidence;
assert.equal(typeof targets,'string');assert.ok(targets.length>0);
assert.equal(journal[3].targetEvidence,targets);
const threads=host.frames.filter(frame=>frame.result?.thread);
assert.equal(threads.length,2);
for(const thread of threads){assert.equal(thread.result.sandbox.type,'readOnly');assert.equal(thread.result.sandbox.networkAccess,false);assert.equal(thread.result.approvalPolicy,'never');}
const archive=path.join(state,'evidence',path.basename(home));
if(!fs.existsSync(archive)) {
 fs.mkdirSync(archive,{recursive:true});
 fs.cpSync(home,path.join(archive,'live'),{recursive:true});
}

fs.writeFileSync(path.join(state,'verification.json'),JSON.stringify({passed:true,realModelTurns:2,realToolCalls:4,threadAndReplayRejection:true,postStartup:true,durableAcknowledgement:true,buildSources:build.hashes,binaryHash:hash(build.binary),gateHash:hash(path.join(build.code,'codex-tool-gate.mjs')),lifecycleHash:hash(path.join(build.code,'host-lifecycle.mjs')),confirmedShutdown:host.shutdown},null,2));
console.log('PASS: consolidated candidate protocol, ownership, and durable acknowledgement evidence.');
