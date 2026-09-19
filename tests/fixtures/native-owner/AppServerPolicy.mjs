import path from 'node:path';
import fs from 'node:fs';
import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {fileURLToPath} from 'node:url';
import {discoverMcpServerNames,isolatedAppServerArgs,verifyExternalToolConfiguration,verifyExternalToolIsolation} from '../../../bin/native-owner/app-server-policy.mjs';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../../..');
const area=fs.mkdtempSync(path.join(process.env.TEMP,'fm-native-app-policy-'));
const codexHome=path.join(area,'codex-home');
fs.mkdirSync(codexHome);
const probe=process.execPath.replaceAll('\\','/');
fs.writeFileSync(path.join(codexHome,'config.toml'),`[features]\napps = true\nplugins = true\n[mcp_servers.inherited_probe]\ncommand = ${JSON.stringify(probe)}\nargs = ["-e", "process.exit(0)"]\nenabled = true\n`);
const executable=path.join(process.env.APPDATA,'npm/node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin/codex.exe');
const childEnvironment={...process.env,CODEX_HOME:codexHome};
const mcpServerNames=await discoverMcpServerNames(executable,root,childEnvironment);
const child=spawn(executable,isolatedAppServerArgs(mcpServerNames,['-c','windows.sandbox=unelevated']),{cwd:root,env:childEnvironment,stdio:['pipe','pipe','pipe'],windowsHide:true});
let next=0,stderr='';
const pending=new Map();
child.stderr.on('data',data=>stderr+=data);
const fail=error=>{for(const waiter of pending.values())waiter.reject(error);pending.clear();};
child.on('error',fail);child.on('exit',code=>fail(Error('App-server exited '+code+': '+stderr)));
createInterface({input:child.stdout}).on('line',line=>{
 const frame=JSON.parse(line);
 if(frame.id!==undefined&&pending.has(frame.id)){
  const waiter=pending.get(frame.id);pending.delete(frame.id);
  frame.error?waiter.reject(Error(JSON.stringify(frame.error))):waiter.resolve(frame.result);
 }else if(frame.id!==undefined&&frame.method)child.stdin.write(JSON.stringify({id:frame.id,error:{code:-32601,message:'Unsupported test request'}})+'\n');
});
const request=(method,params)=>new Promise((resolve,reject)=>{
 const id=++next,timer=setTimeout(()=>{pending.delete(id);reject(Error(method+' timed out'));},30000);
 pending.set(id,{resolve:value=>{clearTimeout(timer);resolve(value);},reject:error=>{clearTimeout(timer);reject(error);}});
 child.stdin.write(JSON.stringify({id,method,params})+'\n');
});

try {
 await request('initialize',{clientInfo:{name:'firstmate-native-policy-test',version:'0.1.0'},capabilities:{experimentalApi:true}});
 child.stdin.write(JSON.stringify({method:'initialized',params:{}})+'\n');
 const externalConfiguration=await verifyExternalToolConfiguration(request,mcpServerNames);
 const started=await request('thread/start',{cwd:root,sandbox:'read-only',approvalPolicy:'never',ephemeral:true,dynamicTools:[]});
 const result=await verifyExternalToolIsolation(request,started.thread.id,externalConfiguration);
 console.log('PASS: effective app and MCP catalogs are isolated '+JSON.stringify(result));
}finally{
 child.stdin.end();
 await new Promise(resolve=>{const timer=setTimeout(()=>{child.kill();resolve();},5000);child.once('exit',()=>{clearTimeout(timer);resolve();});});
}
