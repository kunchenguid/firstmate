import test from 'node:test';
import assert from 'node:assert/strict';
import {isolatedAppServerArgs,verifyExternalToolConfiguration,verifyExternalToolIsolation} from '../../../bin/native-owner/app-server-policy.mjs';

function requestBoundary(responses) {
 const calls=[];
 const request=async(method,params)=>{
  calls.push({method,params});
  if(!(method in responses))throw Error('Unexpected request '+method);
  const response=responses[method];
  return typeof response==='function'?response(params):response;
 };
 return {request,calls};
}

function inactiveMcpServer(name) {
 return {name,tools:{},resources:[],resourceTemplates:[],authStatus:'unknown'};
}

const isolatedConfiguration={appsFeatureEnabled:false,pluginsFeatureEnabled:false,configuredMcpServers:['alpha'],enabledMcpServers:[]};

test('isolated app-server arguments disable every inherited external capability',()=>{
 assert.deepEqual(isolatedAppServerArgs(['zeta','alpha'],['-c','windows.sandbox=unelevated']),[
  'app-server','--stdio','--disable','hooks','--disable','apps','--disable','plugins',
  '-c','mcp_servers={"alpha"={enabled=false},"zeta"={enabled=false}}',
  '-c','windows.sandbox=unelevated',
 ]);
});

test('the fake request boundary observes a fully isolated effective catalog',async()=>{
 const boundary=requestBoundary({
  'config/read':{config:{features:{apps:false,plugins:false},mcp_servers:{alpha:{enabled:false}}}},
  'app/installed':{apps:[{id:'policy-disabled-app',runtimeName:'Policy Disabled App',enabled:false,callable:false}]},
  'mcpServerStatus/list':{data:[],nextCursor:null},
 });
 const configuration=await verifyExternalToolConfiguration(boundary.request,['alpha']);
 const result=await verifyExternalToolIsolation(boundary.request,'thread-1',configuration);
 assert.deepEqual(result,{
  appsFeatureEnabled:false,pluginsFeatureEnabled:false,configuredMcpServers:['alpha'],enabledMcpServers:[],exposedApps:[],activeMcpServers:[],
 });
 assert.deepEqual(boundary.calls,[
  {method:'config/read',params:{includeLayers:false}},
  {method:'app/installed',params:{threadId:'thread-1',forceRefresh:false}},
  {method:'mcpServerStatus/list',params:{cursor:null,limit:100,detail:'toolsAndAuthOnly'}},
 ]);
});

test('enabled app features and MCP servers are rejected at the effective configuration boundary',async()=>{
 for(const config of [
 {features:{apps:true,plugins:false},mcp_servers:{alpha:{enabled:false}}},
  {features:{apps:false,plugins:true},mcp_servers:{alpha:{enabled:false}}},
  {features:{apps:false,plugins:false},mcp_servers:{alpha:{enabled:true}}},
 ]) {
  const {request}=requestBoundary({'config/read':{config}});
  await assert.rejects(verifyExternalToolConfiguration(request,['alpha']),/External app-server configuration is not isolated/);
 }
});

test('exposed apps and active MCP tools are rejected at the thread boundary',async()=>{
 for(const responses of [
  {'app/installed':{apps:[{id:'connected-app',runtimeName:'Connected App',enabled:true,callable:true}]},'mcpServerStatus/list':{data:[],nextCursor:null}},
  {'app/installed':{apps:[]},'mcpServerStatus/list':{data:[{...inactiveMcpServer('alpha'),tools:{write:{}}}],nextCursor:null}},
 ]) {
  const {request}=requestBoundary(responses);
  await assert.rejects(verifyExternalToolIsolation(request,'thread-1',isolatedConfiguration),/External app-server tools are not isolated/);
 }
});

test('a prohibited MCP capability on a later page is rejected',async()=>{
 const pages=new Map([
  [null,{data:Array.from({length:100},(_,index)=>inactiveMcpServer('inactive-'+index)),nextCursor:'page-2'}],
  ['page-2',{data:[{...inactiveMcpServer('active'),runtimeStatus:'connected'}],nextCursor:null}],
 ]);
 const {request,calls}=requestBoundary({'app/installed':{apps:[]},'mcpServerStatus/list':({cursor})=>pages.get(cursor)});
 await assert.rejects(verifyExternalToolIsolation(request,'thread-1',isolatedConfiguration),/External app-server tools are not isolated/);
 assert.equal(calls.filter(call=>call.method==='mcpServerStatus/list').length,2);
});

test('supported runtime statuses have explicit activity semantics',async()=>{
 const semantics=new Map([[null,false],['disabled',false],['notStarted',true],['starting',true],['connected',true],['authenticationRequired',true],['failed',true],['cancelled',true]]);
 for(const [runtimeStatus,active] of semantics){
  const boundary=requestBoundary({'app/installed':{apps:[]},'mcpServerStatus/list':{data:[{...inactiveMcpServer(String(runtimeStatus)),runtimeStatus}],nextCursor:null}});
  if(active)await assert.rejects(verifyExternalToolIsolation(boundary.request,'thread-1',isolatedConfiguration),/External app-server tools are not isolated/);
  else assert.deepEqual((await verifyExternalToolIsolation(boundary.request,'thread-1',isolatedConfiguration)).activeMcpServers,[]);
 }
});

test('disabled status is inactive only when the complete response exposes nothing',async()=>{
 for(const exposed of [
  {serverInfo:{}},{toolsError:'failed to enumerate'}, {tools:{read:{}}}, {resources:[{}]}, {resourceTemplates:[{}]},
 ]){
  const server={...inactiveMcpServer('disabled'),runtimeStatus:'disabled',...exposed};
  const boundary=requestBoundary({'app/installed':{apps:[]},'mcpServerStatus/list':{data:[server],nextCursor:null}});
  await assert.rejects(verifyExternalToolIsolation(boundary.request,'thread-1',isolatedConfiguration),/External app-server tools are not isolated/);
 }
});

test('valid empty and protocol-optional-field catalogs are accepted',async()=>{
 const empty=requestBoundary({'app/installed':{apps:[]},'mcpServerStatus/list':{data:[]}});
 assert.deepEqual((await verifyExternalToolIsolation(empty.request,'thread-1',isolatedConfiguration)).activeMcpServers,[]);
 const pages=new Map([
  [null,{data:[inactiveMcpServer('alpha')],nextCursor:'page-2'}],
  ['page-2',{data:[inactiveMcpServer('beta')],nextCursor:null}],
 ]);
 const multiple=requestBoundary({'app/installed':{apps:[]},'mcpServerStatus/list':({cursor})=>pages.get(cursor)});
 assert.deepEqual((await verifyExternalToolIsolation(multiple.request,'thread-1',isolatedConfiguration)).activeMcpServers,[]);
 assert.deepEqual(multiple.calls.filter(call=>call.method==='mcpServerStatus/list').map(call=>call.params.cursor),[null,'page-2']);
});

test('malformed catalog responses are rejected',async()=>{
 for(const responses of [
  {'app/installed':{},'mcpServerStatus/list':{data:[],nextCursor:null}},
  {'app/installed':{apps:[{}]},'mcpServerStatus/list':{data:[],nextCursor:null}},
  {'app/installed':{apps:[]},'mcpServerStatus/list':{}},
  {'app/installed':{apps:[]},'mcpServerStatus/list':{data:[{}],nextCursor:null}},
  {'app/installed':{apps:[]},'mcpServerStatus/list':{data:[{...inactiveMcpServer('future'),runtimeStatus:'future'}],nextCursor:null}},
  {'app/installed':{apps:[]},'mcpServerStatus/list':{data:[],nextCursor:7}},
 ]) {
  const {request}=requestBoundary(responses);
  await assert.rejects(verifyExternalToolIsolation(request,'thread-1',isolatedConfiguration),/Invalid (installed app catalog|MCP server status) response/);
 }
});

test('repeated and unbounded MCP pagination are rejected',async()=>{
 const repeated=requestBoundary({'app/installed':{apps:[]},'mcpServerStatus/list':{data:[],nextCursor:'same'}});
 await assert.rejects(verifyExternalToolIsolation(repeated.request,'thread-1',isolatedConfiguration),/Repeated MCP server status cursor/);
 let page=0;
 const unbounded=requestBoundary({'app/installed':{apps:[]},'mcpServerStatus/list':()=>({data:[],nextCursor:String(++page)})});
 await assert.rejects(verifyExternalToolIsolation(unbounded.request,'thread-1',isolatedConfiguration),/MCP server status pagination exceeded its bound/);
 assert.equal(unbounded.calls.filter(call=>call.method==='mcpServerStatus/list').length,256);
});
