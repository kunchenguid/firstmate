#!/usr/bin/env node
// Protocol fixture: JSON config stands in for Codex-owned TOML parsing.
const fs = require('node:fs'), path = require('node:path'), rl = require('node:readline');
const store = path.join(process.env.CODEX_HOME, 'config.toml');
// A remote job's env -i resolves the real account store; persist elsewhere.
const file = process.env.FM_TEST_CODEX_STORE || store;
if (process.env.FM_TEST_CODEX_CONFIG_STALL) { // a server that never finishes shutting down
  fs.writeFileSync(process.env.FM_TEST_CODEX_CONFIG_STALL, String(process.pid));
  process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);
}
let races = Number(process.env.FM_TEST_CODEX_CONFIG_CONFLICT || 0); // reads that a concurrent edit follows
let lost = Number(process.env.FM_TEST_CODEX_CONFIG_LOST || 0); // ok writes a concurrent replace drops
rl.createInterface({input: process.stdin}).on('line', line => {
  const r = JSON.parse(line);
  if (r.id === undefined) return;
  try {
    const content = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '{}';
    const config = JSON.parse(content);
    let result = {};
    if (r.method === 'config/read') {
      result = {layers: [{name: {type:'user', file:store, profile:null}, version:content, config}]};
      if (races > 0 && races--)
        fs.writeFileSync(file, JSON.stringify({...config, concurrent_setting: (config.concurrent_setting || 0) + 1}));
    }
    if (r.method === 'config/value/write') {
      if (r.params.expectedVersion !== content)
        throw Object.assign(Error('version conflict'), {data: {config_write_error_code: 'configVersionConflict'}});
      const key = JSON.parse(r.params.keyPath.slice(9, -12));
      config.projects ||= {}; config.projects[key] ||= {};
      config.projects[key].trust_level = r.params.value;
      if (lost > 0 && lost--) // another writer's replace, based on the old content, lands after ours
        fs.writeFileSync(file, JSON.stringify({...JSON.parse(content), concurrent_setting: (JSON.parse(content).concurrent_setting || 0) + 1}));
      else fs.writeFileSync(file, JSON.stringify(config));
      result = {status:'ok', filePath:store};
    }
    console.log(JSON.stringify({id:r.id, result}));
  } catch(error) { console.log(JSON.stringify({id:r.id, error:{message:error.message, data:error.data}})); }
});
