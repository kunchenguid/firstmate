#!/usr/bin/env bash
# Portable public-dispatch contract: identity, freshness, read authority, bounds,
# exclusions and activation refusal. No Pi or model credentials required.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-context-atlas)
trap fm_test_cleanup EXIT
node --input-type=module - "$ROOT" "$TMP_ROOT" <<'JS'
import assert from 'node:assert/strict';
import {mkdirSync,writeFileSync,symlinkSync,linkSync,renameSync,rmSync,utimesSync,statSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const [root,tmp] = process.argv.slice(2);
const {createAtlas} = await import(pathToFileURL(root+'/bin/context-atlas/catalog.mjs'));
const repo=tmp+'/repo'; mkdirSync(repo);
const git=(...args)=>execFileSync('git',['-C',repo,...args]); git('init','-q');
const empty=createAtlas({root:repo,tools:()=>[],active:()=>[],activate:()=>false});
assert.equal(empty({op:'catalog'}).outcome,'not_found');
const put=(path,text)=>{mkdirSync(repo+'/'+path.split('/').slice(0,-1).join('/'),{recursive:true});writeFileSync(repo+'/'+path,text);};
put('src/alpha.ts','first\nsecond\nthird\n'); put('docs/alpha.md','guide\n');
put('.gitignore','ignored/\ntracked-ignore.txt\n');
put('tracked-ignore.txt','hidden'); git('add','-f','tracked-ignore.txt');
for (const p of ['ignored/a.ts','.env','env.json','src/auth.json','state/public.md','node_modules/a.ts','dist/a.ts','excluded/a.ts','.git/invented','credentials.txt']) put(p,'DO_NOT_READ');
put('big.txt','x'.repeat(270000)); put('long.txt','x'.repeat(9000)); put('binary.txt','x\0y');
put('utf.txt','é\n☃\n'); put('empty.txt','');
writeFileSync(tmp+'/outside.txt','OUTSIDE');
symlinkSync(tmp+'/outside.txt',repo+'/link.txt'); symlinkSync(tmp,repo+'/escape');
linkSync(tmp+'/outside.txt',repo+'/hard.txt');
let list=['read','write'].map(name=>({name,description:name,parameters:{type:'object'},sourceInfo:{source:'builtin',path:`<builtin:${name}>`}}));
let active=[]; let invoked=0;
const options={root:repo,read:true,exclusions:['excluded'],tools:()=>list,active:()=>active,activate:t=>{active.push(t.name);invoked++;return true;}};
const atlas=createAtlas(options);
const call=p=>{const r=atlas(p);assert.equal(r.outputBytes,Buffer.byteLength(JSON.stringify(r)));assert.ok(r.outputBytes<=8192);return r;};
const resolve=q=>{const r=call({op:'resolve',q});assert.equal(r.outcome,'resolved',q);return {ref:r.candidates[0].ref,gen:r.generation};};
const read=(h,extra={})=>call({op:'read',...h,...extra});
const alpha=resolve('f:src/alpha.ts');
assert.equal(read(alpha,{at:2,count:1}).content,'second');
assert.equal(call({op:'inspect',...alpha}).info.readAuthorized,true);
assert.equal(call({op:'resolve',q:'alpha'}).outcome,'ambiguous');
assert.equal(call({op:'resolve',q:'f:alpha'}).candidates.length,2);
assert.equal(call({op:'read',ref:alpha.ref}).outcome,'generation_required');
assert.equal(read({...alpha,gen:'old'}).outcome,'stale_snapshot');
assert.equal(read({...alpha,ref:'f:unknown'}).outcome,'unknown_handle');
assert.equal(read(alpha,{at:0}).outcome,'invalid_request');
assert.equal(read(alpha,{count:101}).outcome,'invalid_request');
assert.equal(call({op:'execute',command:'touch BAD'}).outcome,'invalid_request');
assert.equal(call({op:'read',...alpha,argv:['rm']}).outcome,'invalid_request');
for (const p of ['ignored/a.ts','tracked-ignore.txt','.env','env.json','src/auth.json','state/public.md','node_modules/a.ts','dist/a.ts','excluded/a.ts','.git/invented','credentials.txt','link.txt','escape/outside.txt','hard.txt','../outside.txt',tmp+'/outside.txt']) assert.equal(call({op:'resolve',q:'f:'+p}).outcome,'not_found',p);
assert.equal(read(resolve('f:big.txt')).outcome,'file_too_large');
assert.equal(read(resolve('f:long.txt')).outcome,'output_too_large');
assert.equal(read(resolve('f:binary.txt')).outcome,'unsupported_file_type');
assert.equal(read(resolve('f:utf.txt'),{at:2,count:1}).content,'☃');
assert.equal(read(resolve('f:empty.txt')).content,'');
assert.equal(read(alpha,{at:20}).outcome,'line_out_of_range');
const denied=createAtlas({...options,read:false}); const dr=denied({op:'resolve',q:'f:src/alpha.ts'});
assert.equal(denied({op:'read',ref:dr.candidates[0].ref,gen:dr.generation}).outcome,'read_not_authorized');
// Metadata-only indexing must not read an oversized, binary or private file.
// Freshness catches an equal-size rewrite even when mtime is restored.
const s=statSync(repo+'/src/alpha.ts');put('src/alpha.ts','other\nsecond\nthird\n');utimesSync(repo+'/src/alpha.ts',s.atime,s.mtime);
assert.equal(read(alpha).outcome,'stale_handle');
call({op:'refresh'}); assert.equal(read(alpha).outcome,'stale_snapshot');
const fresh=resolve('f:src/alpha.ts'); assert.notEqual(fresh.ref,alpha.ref);
put('.gitignore','ignored/\ntracked-ignore.txt\nsrc/alpha.ts\n'); assert.equal(read(fresh).freshness,'excluded');
put('.gitignore','ignored/\ntracked-ignore.txt\n');
const guide=resolve('f:docs/alpha.md');renameSync(repo+'/docs',repo+'/old-docs');symlinkSync(tmp,repo+'/docs');assert.equal(read(guide).outcome,'stale_handle');
const t=resolve('t:read'); assert.equal(call({op:'activate',...t}).outcome,'active_for_next_call');assert.equal(invoked,1);
assert.equal(call({op:'activate',...resolve('t:write')}).outcome,'execution_disallowed'); assert.equal(invoked,1);
list[0]={...list[0],parameters:{type:'object',required:['path']}};assert.equal(call({op:'activate',...t}).freshness,'stale');
list=[]; assert.equal(call({op:'inspect',...t}).freshness,'unavailable');
assert.equal(call({op:'activate',...fresh}).outcome,'execution_disallowed');
const noActivation=createAtlas({...options,tools:()=>[{name:'read',description:'custom override',parameters:{type:'object'},sourceInfo:{source:'extension',path:'/custom'}}],activate:()=>{throw new Error('must not activate');}});
const override=noActivation({op:'resolve',q:'t:read'});assert.equal(noActivation({op:'activate',ref:override.candidates[0].ref,gen:override.generation}).outcome,'execution_disallowed');
const disabled=createAtlas({...options,tools:()=>[{name:'read',description:'read',parameters:{type:'object'},sourceInfo:{source:'builtin',path:'<builtin:read>'}}],active:()=>[],activate:()=>false});
const off=disabled({op:'resolve',q:'t:read'});assert.equal(disabled({op:'activate',ref:off.candidates[0].ref,gen:off.generation}).outcome,'activation_not_authorized');
const hugeTool=createAtlas({...options,tools:()=>[{name:'huge',description:'x'.repeat(10000),parameters:{type:'object'},sourceInfo:{source:'sdk',path:'fixture'}}]});
const huge=hugeTool({op:'resolve',q:'t:huge'});assert.equal(hugeTool({op:'inspect',ref:huge.candidates[0].ref,gen:huge.generation}).outcome,'output_too_large');
const abort=new AbortController();abort.abort();assert.equal(atlas({op:'catalog'},abort.signal).outcome,'cancelled');
for(let i=0;i<12;i++)put('page-'+i+'.txt','ok');call({op:'refresh'});
const page=call({op:'catalog',q:'page-',count:100});assert.equal(page.candidates.length,8);assert.equal(page.more,true);
const next=call({op:'catalog',q:'page-',at:9,gen:page.generation});assert.equal(next.candidates.length,4);
assert.equal(new Set([...page.candidates,...next.candidates].map(c=>c.ref)).size,12);
assert.throws(()=>createAtlas({...options,root:repo+'/src'}),/toplevel/);
rmSync(repo+'/.git',{recursive:true}); assert.throws(()=>createAtlas(options));
assert.equal(read({ref:page.candidates[0].ref,gen:page.generation}).freshness,'unavailable');
console.log('ok - Atlas public dispatcher: identity, freshness, exclusions, authority, bounds and refusal cases');
JS
