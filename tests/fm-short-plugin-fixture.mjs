// Portable SDK double. Real installed SDK behavior is covered by the live gate.
import fs from 'node:fs';
import path from 'node:path';
export function pluginFixture(pkg) {
  const agent = path.join(pkg, 'agent'), plugin = path.join(agent, 'npm/node_modules/pi-openai-codex-compat');
  fs.mkdirSync(path.join(plugin, 'extensions'), { recursive: true });
  fs.writeFileSync(path.join(plugin, 'package.json'), JSON.stringify({ name: 'pi-openai-codex-compat', version: '0.0.16', pi: { extensions: ['./extensions/index.ts'] } }));
  fs.writeFileSync(path.join(plugin, 'extensions/index.ts'), '// SDK fixture only\n');
  return `
export const getAgentDir=()=>${JSON.stringify(agent)};
export class DefaultResourceLoader {
 constructor(o){this.o=o;}
 async reload(){
  if(!this.o.noExtensions || !this.o.noSkills || !this.o.noContextFiles || !this.o.noThemes || !this.o.noPromptTemplates) throw Error('discovery enabled');
  this.result=this.o.extensionsOverride({extensions:[{path:this.o.additionalExtensionPaths[0],resolvedPath:this.o.additionalExtensionPaths[0],tools:new Map([['exec_command',{}]]),commands:new Map(),shortcuts:new Map(),handlers:new Map([['session_start',[]]])}],errors:[],runtime:{}});
 }
 getExtensions(){return this.result;}
 getAgentsFiles(){return this.o.agentsFilesOverride();}
 getSystemPrompt(){return this.o.systemPrompt;}
}
`;
}
