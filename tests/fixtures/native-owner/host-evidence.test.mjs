import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {saveHostEvidence} from '../../../bin/native-owner/host-evidence.mjs';

const readerSource=`
const fs=require('node:fs');
const [file,mode]=process.argv.slice(1);
let fd=mode==='hold'?fs.openSync(file,'r'):null,reads=0,errors=0;
const timer=mode==='poll'?setInterval(()=>{try{JSON.parse(fs.readFileSync(file,'utf8'));reads++;}catch{errors++;}},100):null;
process.on('message',message=>{
 if(message==='release-later'){setTimeout(()=>{fs.closeSync(fd);fd=null;},75);process.send('scheduled');}
 if(message==='stop'){if(timer)clearInterval(timer);if(fd!==null)fs.closeSync(fd);process.send({reads,errors});process.disconnect();}
});
process.send('ready');
`;
async function reader(file,mode){
 const child=spawn(process.execPath,['-e',readerSource,file,mode],{stdio:['ignore','ignore','inherit','ipc']});
 await new Promise((resolve,reject)=>{child.once('message',resolve);child.once('error',reject);});
 return {child,async releaseLater(){const scheduled=new Promise(resolve=>child.once('message',resolve));child.send('release-later');assert.equal(await scheduled,'scheduled');},async stop(){const summary=new Promise(resolve=>child.once('message',resolve));const exited=new Promise(resolve=>child.once('exit',resolve));child.send('stop');const value=await summary;assert.equal(await exited,0);return value;}};
}
function home(t){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'fm-host-evidence-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));return dir;}

test('progress publication replaces complete JSON without changing receipt records',t=>{
 const dir=home(t),receipt=path.join(dir,'owner-receipts.jsonl');fs.writeFileSync(receipt,'preserved receipt\n');
 saveHostEvidence(dir,{version:1});saveHostEvidence(dir,{version:2});
 assert.deepEqual(JSON.parse(fs.readFileSync(path.join(dir,'host.json'),'utf8')),{version:2});
 assert.equal(fs.existsSync(path.join(dir,'host.json.tmp')),false);assert.equal(fs.readFileSync(receipt,'utf8'),'preserved receipt\n');
});

test('unrelated write errors are propagated',t=>{
 const dir=home(t);fs.writeFileSync(path.join(dir,'host.json.tmp'),'not a directory');
 assert.throws(()=>saveHostEvidence(path.join(dir,'host.json.tmp'),{}),error=>['ENOTDIR','ENOENT'].includes(error.code));
});

test('Windows reader contention clears without removing the old snapshot',{skip:process.platform!=='win32'},async t=>{
 const dir=home(t),file=path.join(dir,'host.json');saveHostEvidence(dir,{version:1});
 const held=await reader(file,'hold');
 try{
  fs.writeFileSync(file+'.tmp','{}');assert.throws(()=>fs.renameSync(file+'.tmp',file),{code:'EPERM'});
  assert.deepEqual(JSON.parse(fs.readFileSync(file,'utf8')),{version:1});
  await held.releaseLater();saveHostEvidence(dir,{version:2});
  assert.deepEqual(JSON.parse(fs.readFileSync(file,'utf8')),{version:2});
 }finally{await held.stop();}
});

test('persistent Windows refusal stays bounded and preserves the complete prior snapshot',{skip:process.platform!=='win32'},async t=>{
 const dir=home(t),file=path.join(dir,'host.json');saveHostEvidence(dir,{version:1});
 const held=await reader(file,'hold');
 try{
  const start=performance.now();assert.throws(()=>saveHostEvidence(dir,{version:2}),{code:'EPERM'});
  assert(performance.now()-start<2000,'Persistent replacement refusal exceeded the bound');
  assert.deepEqual(JSON.parse(fs.readFileSync(file,'utf8')),{version:1});
  assert.deepEqual(JSON.parse(fs.readFileSync(file+'.tmp','utf8')),{version:2});
 }finally{await held.stop();}
 saveHostEvidence(dir,{version:2});assert.deepEqual(JSON.parse(fs.readFileSync(file,'utf8')),{version:2});
});

test('Windows publication tolerates the launcher polling cadence with coherent reads',{skip:process.platform!=='win32'},async t=>{
 const dir=home(t),file=path.join(dir,'host.json');saveHostEvidence(dir,{version:0});
 const polling=await reader(file,'poll');let result;
 try{
  const deadline=performance.now()+1500;let version=0;
  while(performance.now()<deadline)saveHostEvidence(dir,{version:++version,padding:'x'.repeat(4096)});
 }finally{result=await polling.stop();}
 assert(result.reads>=3,'Reader did not exercise concurrent polling');assert.equal(result.errors,0);
});
