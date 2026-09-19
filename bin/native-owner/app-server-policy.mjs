import {spawn} from 'node:child_process';

const MAX_MCP_STATUS_PAGES=256;
const MCP_RUNTIME_STATUS_ACTIVE=new Map([
 [null,false],
 ['notStarted',true],
 ['starting',true],
 ['connected',true],
 ['authenticationRequired',true],
 ['failed',true],
 ['cancelled',true],
 ['disabled',false],
]);

function isRecord(value) {
 return value!==null&&typeof value==='object'&&!Array.isArray(value);
}

function validInstalledApp(value) {
 return isRecord(value)&&typeof value.id==='string'&&(value.runtimeName===null||typeof value.runtimeName==='string')&&typeof value.enabled==='boolean'&&typeof value.callable==='boolean';
}

function validMcpServerStatus(value) {
 return isRecord(value)&&typeof value.name==='string'&&
  (value.runtimeStatus===undefined||MCP_RUNTIME_STATUS_ACTIVE.has(value.runtimeStatus))&&
  (value.pluginId==null||typeof value.pluginId==='string')&&
  (value.serverInfo==null||isRecord(value.serverInfo))&&
  isRecord(value.tools)&&(value.toolsError==null||typeof value.toolsError==='string')&&
  Array.isArray(value.resources)&&Array.isArray(value.resourceTemplates)&&
  ['unknown','unsupported','notLoggedIn','bearerToken','oAuth'].includes(value.authStatus);
}

async function readMcpServerStatuses(request) {
 const statuses=[],seenCursors=new Set();
 let cursor=null;
 for(let page=0;page<MAX_MCP_STATUS_PAGES;page++){
  const response=await request('mcpServerStatus/list',{cursor,limit:100,detail:'toolsAndAuthOnly'});
  if(!isRecord(response)||!Array.isArray(response.data)||response.data.some(status=>!validMcpServerStatus(status))||(response.nextCursor!=null&&typeof response.nextCursor!=='string'))throw Error('Invalid MCP server status response');
  statuses.push(...response.data);
  if(response.nextCursor==null)return statuses;
  if(seenCursors.has(response.nextCursor))throw Error('Repeated MCP server status cursor');
  seenCursors.add(response.nextCursor);
  cursor=response.nextCursor;
 }
 throw Error('MCP server status pagination exceeded its bound');
}

function uniqueNames(value) {
 if(!Array.isArray(value)||value.length>256||value.some(name=>typeof name!=='string'||!name.length||name.length>256))throw Error('Invalid inherited MCP server catalog');
 const names=[...new Set(value)];
 if(names.length!==value.length)throw Error('Duplicate inherited MCP server name');
 return names.sort();
}

export function discoverMcpServerNames(executable,cwd,env=process.env) {
 return new Promise((resolve,reject)=>{
  const child=spawn(executable,['mcp','list','--json','--disable','apps','--disable','plugins'],{cwd,env,stdio:['ignore','pipe','pipe'],windowsHide:true});
  let stdout='',stderr='',settled=false;
  const finish=(callback,value)=>{if(settled)return;settled=true;clearTimeout(timer);callback(value);};
  const fail=error=>{child.kill();finish(reject,error);};
  const timer=setTimeout(()=>fail(Error('MCP configuration discovery timed out')),30000);
  child.stdout.on('data',data=>{stdout+=data;if(stdout.length>1048576)fail(Error('MCP configuration discovery exceeded its bound'));});
  child.stderr.on('data',data=>{stderr+=data;if(stderr.length>1048576)fail(Error('MCP configuration diagnostics exceeded their bound'));});
  child.on('error',fail);
  child.on('exit',code=>{
   if(settled)return;
   if(code!==0){finish(reject,Error('MCP configuration discovery failed: '+stderr.trim()));return;}
   try {
    const rows=JSON.parse(stdout);
    if(!Array.isArray(rows)||rows.some(row=>!row||typeof row!=='object'))throw Error('Invalid MCP configuration response');
    finish(resolve,uniqueNames(rows.map(row=>row.name)));
   }catch(error){finish(reject,error);}
  });
 });
}

export function isolatedAppServerArgs(mcpServerNames,extra=[]) {
 const names=uniqueNames(mcpServerNames);
 const disabled=names.length?['-c','mcp_servers={'+names.map(name=>JSON.stringify(name)+'={enabled=false}').join(',')+'}']:[];
 return ['app-server','--stdio','--disable','hooks','--disable','apps','--disable','plugins',...disabled,...extra];
}

export async function verifyExternalToolConfiguration(request,mcpServerNames) {
 const expected=uniqueNames(mcpServerNames);
 const effective=(await request('config/read',{includeLayers:false})).config??{};
 const configured=effective.mcp_servers&&typeof effective.mcp_servers==='object'?effective.mcp_servers:{};
 const configuredNames=Object.keys(configured).sort();
 const enabledMcpServers=configuredNames.filter(name=>configured[name]?.enabled!==false);
 const result={
  appsFeatureEnabled:effective.features?.apps,
  pluginsFeatureEnabled:effective.features?.plugins,
  configuredMcpServers:configuredNames,
  enabledMcpServers,
 };
 if(result.appsFeatureEnabled!==false||result.pluginsFeatureEnabled!==false||JSON.stringify(configuredNames)!==JSON.stringify(expected)||enabledMcpServers.length)throw Error('External app-server configuration is not isolated: '+JSON.stringify(result));
 return result;
}

export async function verifyExternalToolIsolation(request,threadId,configuration) {
 const installed=await request('app/installed',{threadId,forceRefresh:false});
 if(!isRecord(installed)||!Array.isArray(installed.apps)||installed.apps.some(app=>!validInstalledApp(app)))throw Error('Invalid installed app catalog response');
 const apps=installed.apps;
 const mcpServers=await readMcpServerStatuses(request);
 const activeMcpServers=mcpServers.filter(server=>MCP_RUNTIME_STATUS_ACTIVE.get(server.runtimeStatus)||server.serverInfo!=null||server.toolsError!=null||Object.keys(server.tools).length||server.resources.length||server.resourceTemplates.length);
 const result={
  ...configuration,
  exposedApps:apps.filter(app=>app.enabled||app.callable).map(app=>app.id),
  activeMcpServers:activeMcpServers.map(server=>server.name),
 };
 if(result.exposedApps.length||result.activeMcpServers.length)throw Error('External app-server tools are not isolated: '+JSON.stringify(result));
 return result;
}
