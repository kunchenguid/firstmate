#!/usr/bin/env bash
# Exercise exact same-home wake routing with opaque Herdr endpoint identities.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-branch-endpoint)
ROOT="$ROOT" CASE_DIR="$TMP_ROOT" node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import {mkdirSync,writeFileSync,unlinkSync,symlinkSync,linkSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
const {scopeForUnreadWake,dispositionForWakeTrigger}=await import(pathToFileURL(process.env.ROOT+'/.pi/extensions/lib/fm-branch-dispatch.ts'));
const home=process.env.CASE_DIR+'/home', state=home+'/state', other=process.env.CASE_DIR+'/other/state';
mkdirSync(state,{recursive:true});mkdirSync(other,{recursive:true});
const endpoint='default:wFA:p2';
const meta=(task,window=endpoint,extra='')=>writeFileSync(`${state}/${task}.meta`,`project=${home}/projects/p\nwindow=${window}\n${extra}`);
writeFileSync(state+'/.wake-queue',`1\t42\tstale\t${endpoint}\tstale: ${endpoint} (idle 300s)\n`);
meta('compatibility');
let s=scopeForUnreadWake(state,false);
assert.equal(s.taskBySeq['42'],'compatibility');assert.equal(s.taskByWakeKey[endpoint],'compatibility');
assert.equal(dispositionForWakeTrigger('stale: '+endpoint+' (idle 300s)',s).eligible,true);
assert.deepEqual(s.eligibleTasks,['compatibility']);
console.log('ok - full Herdr endpoint resolves to exact task, never session name default');
meta('compatibility',endpoint,'diagnostic=future\n# preserved comment\n');
assert.equal(scopeForUnreadWake(state,false).taskBySeq['42'],'compatibility');
meta('conflict');s=scopeForUnreadWake(state,false);
assert.equal(s.eligible,false,'duplicate endpoint claims must not pick the last file');
assert.equal(s.unresolvedRows[0]?.key,endpoint);assert.equal(dispositionForWakeTrigger('stale: '+endpoint,s).eligible,false);
meta('third-claim');assert.equal(scopeForUnreadWake(state,false).eligible,false,'third claim cannot erase ambiguity');
unlinkSync(state+'/third-claim.meta');unlinkSync(state+'/conflict.meta');
meta('compatibility',endpoint,'window=default:wOTHER:p2\n');
assert.equal(scopeForUnreadWake(state,false).eligible,false,'duplicate identity fields must not choose the first');
unlinkSync(state+'/compatibility.meta');
writeFileSync(other+'/foreign.meta',`project=${home}/projects/p\nwindow=${endpoint}\n`);
symlinkSync(other+'/foreign.meta',state+'/foreign.meta');
assert.equal(scopeForUnreadWake(state,false).eligible,false,'other-home symlink cannot establish local ownership');
unlinkSync(state+'/foreign.meta');
linkSync(other+'/foreign.meta',state+'/foreign.meta');
assert.equal(scopeForUnreadWake(state,false).eligible,false,'hardlink cannot import another home ownership');
unlinkSync(state+'/foreign.meta');
meta('unrelated','default:wOTHER:p2');
assert.equal(scopeForUnreadWake(state,false).eligible,false,'unmatched endpoint cannot be inferred from session prefix');
writeFileSync(state+'/.wake-queue',`1\t42\tstale\t${endpoint}\tstale: ${endpoint}\n2\t43\tsignal\tunrelated.status\tworking: active\n`);
s=scopeForUnreadWake(state,false);assert.deepEqual(s.eligibleSeqs,['43'],'unowned endpoint must not veto unrelated local work');
for (const supported of [endpoint,'named-lab:wF9:p2','fm-compatibility']) {
    meta('compatibility',supported);
    writeFileSync(state+'/.wake-queue',`1\t42\tstale\t${supported}\tstale: ${supported}\n`);
    assert.equal(scopeForUnreadWake(state,false).taskBySeq['42'],'compatibility');
}
writeFileSync(state+'/.wake-queue','1\t42\tsignal\tcompatibility.status.status\tworking: invalid task\n');
assert.equal(scopeForUnreadWake(state,false).eligible,false,'status alias must not create a new task identity');
console.log('ok - ambiguity, duplicate fields and foreign-home evidence stay unowned without hiding a valid mapping');
JS
