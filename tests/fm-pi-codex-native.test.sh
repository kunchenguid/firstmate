#!/usr/bin/env bash
# Native Codex-through-Pi primary compatibility guard. Runs installed Pi and
# the adapter package with actual FirstMate extensions and durable scripts.
# A local protocol peer and watcher close stand in for model calls and a live
# fleet. No provider request leaves the machine and no live fleet is touched.
# PI_CODEX_NATIVE_PACKAGE selects the installed adapter package; FM_PI_BIN
# selects Pi. FM_NATIVE_TEST_KEEP=1 preserves the isolated fixture for diagnosis.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Mirror the adapter's own executable resolution: the ChatGPT.app binary when
# installed, else PATH codex. When PATH codex is the installed npm launcher and
# is not already the probe executable, the ownership probe runs through it too.
FM_NATIVE_GUI_CODEX=/Applications/ChatGPT.app/Contents/Resources/codex
if [ -z "${FM_NATIVE_CODEX_BIN:-}" ]; then
  if [ -x "$FM_NATIVE_GUI_CODEX" ]; then FM_NATIVE_CODEX_BIN=$FM_NATIVE_GUI_CODEX; else FM_NATIVE_CODEX_BIN=codex; fi
fi
export FM_NATIVE_CODEX_BIN
fm_live_gate default-on FM_PI_CODEX_NATIVE_LIVE node "${FM_PI_BIN:-pi}" "$FM_NATIVE_CODEX_BIN"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"
FM_NATIVE_CODEX_LAUNCHER=$(command -v codex 2>/dev/null || true)
if [ -n "$FM_NATIVE_CODEX_LAUNCHER" ] && [ "$FM_NATIVE_CODEX_LAUNCHER" != "$(command -v "$FM_NATIVE_CODEX_BIN")" ]; then
  case "$(fm_cursor_canonical_path "$FM_NATIVE_CODEX_LAUNCHER")" in
    */@openai/codex/bin/codex.js) ;;
    *) FM_NATIVE_CODEX_LAUNCHER='' ;;
  esac
else
  FM_NATIVE_CODEX_LAUNCHER=''
fi
export FM_NATIVE_CODEX_LAUNCHER
PI_CODEX_NATIVE_PACKAGE=${PI_CODEX_NATIVE_PACKAGE:-"$HOME/.pi/agent/packages/pi-codex-native"}
if [ ! -f "$PI_CODEX_NATIVE_PACKAGE/index.ts" ]; then
  if [ "${FM_PI_CODEX_NATIVE_LIVE:-${FM_LIVE:-0}}" = 1 ]; then
    fail "native Pi adapter missing: $PI_CODEX_NATIVE_PACKAGE"
  fi
  echo "skip: native Pi adapter not installed (PI_CODEX_NATIVE_PACKAGE to select it)"
  exit 0
fi
export PI_CODEX_NATIVE_PACKAGE
FM_NATIVE_TEST_ROOT="$ROOT" node --input-type=module <<'JS'
import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { homedir, tmpdir } from "node:os";
const root = process.env.FM_NATIVE_TEST_ROOT;
const nativePackage =
  process.env.PI_CODEX_NATIVE_PACKAGE ||
  path.join(homedir(), ".pi/agent/packages/pi-codex-native");
const piVersion = execFileSync(process.env.FM_PI_BIN || "pi", ["--version"], {
  encoding: "utf8", timeout: 10000,
}).trim();
let adapterVersion = "unknown";
try {
  adapterVersion = JSON.parse(fs.readFileSync(path.join(nativePackage, "package.json"), "utf8")).version || "unknown";
} catch { /* A source-only adapter may omit package metadata. */ }
const codexExecutables = [process.env.FM_NATIVE_CODEX_BIN, process.env.FM_NATIVE_CODEX_LAUNCHER].filter(Boolean);
const codexVersions = Object.fromEntries(codexExecutables.map((executable) => [
  executable,
  execFileSync(executable, ["--version"], { encoding: "utf8", timeout: 20000 }).trim(),
]));
console.log(`Native Codex guard: Pi ${piVersion}, pi-codex-native ${adapterVersion}, Codex ${JSON.stringify(codexVersions)}`);
const fixture = fs.mkdtempSync(path.join(tmpdir(), "fm-native-primary."));
const repo = path.join(fixture, "repo"),
  home = path.join(fixture, "home"),
  state = path.join(home, "state");
fs.mkdirSync(path.join(repo, "bin"), { recursive: true });
fs.mkdirSync(state, { recursive: true });
fs.mkdirSync(path.join(home, "config"));
fs.symlinkSync(path.join(root, "docs"), path.join(repo, "docs"));
fs.cpSync(
  path.join(root, ".pi/extensions"),
  path.join(repo, ".pi/extensions"),
  { recursive: true },
);
for (const item of fs.readdirSync(path.join(root, "bin")))
  fs.symlinkSync(path.join(root, "bin", item), path.join(repo, "bin", item));
function script(name, text) {
  const file = path.join(repo, "bin", name);
  fs.unlinkSync(file);
  fs.writeFileSync(file, text, { mode: 0o755 });
}
script(
  "fm-sessionstart-run.sh",
  '#!/usr/bin/env bash\nprintf "NATIVE_PRIMARY_STARTUP_SENTINEL\\n"\n',
);
script("fm-turnend-guard.sh", "#!/usr/bin/env bash\nexit 0\n");
// Full startup runs below; external services and fleet work are fixture-only.
for (const name of ["fm-bootstrap.sh", "fm-startup-network.sh", "fm-wake-drain.sh"])
  script(name, "#!/usr/bin/env bash\nexit 0\n");
script(
  "fm-watch-arm.sh",
  `#!/usr/bin/env bash
if [ "\${1:-}" = --handling-delivered ]; then printf 'confirmed\\n' >> "$FM_HOME/state/arm.log"; exit 0; fi
printf 'arm\\n' >> "$FM_HOME/state/arm.log"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=native-smoke\\n' "$$"
trap 'exit 0' TERM INT
while :; do
 if [ -f "$FM_HOME/state/trigger" ]; then rm -f "$FM_HOME/state/trigger"; printf 'check: native-worker-complete\\n'; exit 0; fi
 sleep 0.05
done
`,
);
// Exercise each real Codex executable's token-free command/exec under Pi: the
// adapter's resolved binary and, when installed separately, the npm launcher.
// The protocol peer below cannot establish a real binary's process identity.
const own = path.join(fixture, "own-lock.ts");
const ownershipProbe = path.join(fixture, "ownership-probe.sh");
fs.writeFileSync(ownershipProbe, `#!/usr/bin/env bash
export FM_ROOT_OVERRIDE="$1" FM_HOME="$2" FM_STATE_OVERRIDE="$2/state"
"$1/bin/fm-session-start.sh" > "$2/state/native-startup.out" || exit
if grep -q 'READ-ONLY SESSION' "$2/state/native-startup.out"; then
  cat "$2/state/native-startup.out"
  exit 1
fi
"$1/bin/fm-lock.sh" || exit
. "$1/bin/fm-session-lock-lib.sh"
fm_session_lock_owned_by_self "$2/state" || exit
cat "$2/state/.lock"
`, { mode: 0o755 });
fs.writeFileSync(own, `
import {appendFileSync,readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import {CodexAppServer} from ${JSON.stringify(path.join(nativePackage, "app-server.mjs"))};
export default function(pi) {
 pi.on('session_start', async () => {
  for (const executable of ${JSON.stringify(codexExecutables)}) {
   const children = [];
   for (let i = 0; i < 2; i++) {
    const server = new CodexAppServer({cwd:${JSON.stringify(repo)}, executable});
    try {
     await server.start();
     children.push(server.child.pid);
     const result = await server.request('command/exec', {
      command:['bash',${JSON.stringify(ownershipProbe)},${JSON.stringify(repo)},process.env.FM_HOME],
      cwd:${JSON.stringify(repo)}, sandboxPolicy:{type:'dangerFullAccess'}, timeoutMs:30000,
     }, 40000);
     assert.equal(result.exitCode,0,executable+': '+JSON.stringify(result));
     assert.equal(readFileSync(process.env.FM_HOME+'/state/.lock','utf8').trim(),String(process.pid),executable+': '+JSON.stringify(result));
    } finally { await server.close(); }
   }
   assert.notEqual(children[0],children[1]);
   appendFileSync(process.env.FM_HOME+'/state/ownership-probes',JSON.stringify({executable,owner:process.pid,children})+'\\n');
  }
 });
 pi.events.on('codex-native:progress', event => appendFileSync(process.env.FM_HOME+'/state/progress-events',JSON.stringify(event)+'\\n'));
}
`);
const peer = path.join(fixture, "native-peer.mjs");
fs.writeFileSync(
  peer,
  `#!/usr/bin/env node
import fs from 'node:fs';
let buffer='',counter=0,config;
const log=(data)=>fs.appendFileSync(process.env.FM_HOME+'/state/native.log',JSON.stringify(data)+'\\n');
const emit=(x)=>process.stdout.write(JSON.stringify(x)+'\\n');
async function control(name,args={}){
 const response=await fetch(config.url,{method:'POST',headers:{...config.http_headers,'Content-Type':'application/json',Accept:'application/json, text/event-stream'},body:JSON.stringify({jsonrpc:'2.0',id:++counter,method:'tools/call',params:{name,arguments:args}})});
 const value=await response.json(); if(value.error) throw Error(JSON.stringify(value));log({kind:'control',name,args,result:value.result});return value.result;
}
async function handle(q){
 const reply=(result)=>emit({id:q.id,result});const thread={id:'fm-native-primary-thread',cwd:process.cwd(),turns:[],status:{type:'idle'}};
 if(q.method==='initialize')return reply({userAgent:'native-primary-smoke/1'});
 if(q.method==='model/list')return reply({data:[{id:'gpt-6-astra',model:'gpt-6-astra',displayName:'Astra',supportedReasoningEfforts:['high','ultra'].map(reasoningEffort=>({reasoningEffort,description:reasoningEffort})),defaultReasoningEffort:'high',inputModalities:['text'],isDefault:true}],nextCursor:null});
 if(q.method==='thread/start'||q.method==='thread/resume'){config=q.params.config.mcp_servers.pi_firstmate;log({kind:'thread',method:q.method});return reply({thread,model:'gpt-6-astra',modelProvider:'openai',cwd:process.cwd(),approvalPolicy:'never',sandbox:{type:'dangerFullAccess'}});}
 if(q.method==='turn/start'){
 const id='native-turn-'+ ++counter;const text=JSON.stringify(q.params.input);log({kind:'input',text,effort:q.params.effort});reply({turn:{id,status:'inProgress',items:[]}});emit({method:'turn/started',params:{threadId:thread.id,turn:{id,status:'inProgress',items:[]}}});
 // Yield once so the adapter has accepted the turn and opened its MCP guard.
 await new Promise(r=>setTimeout(r,150));
 if(text.includes('ARM_PRIMARY'))await control('fm_watch_arm_pi');
 const seq=text.match(/\\[seq (\\d+)\\]/);
 if(seq){await control('fm_branch_outcomes',{recent:1});await control('fm_branch_processed',{through:Number(seq[1])});await control('fm_branch_processed',{through:Number(seq[1])});}
 const answer=seq?'NATIVE_OUTCOME_HANDLED':'NATIVE_PRIMARY_READY';
 emit({method:'item/agentMessage/delta',params:{threadId:thread.id,turnId:id,itemId:id+'-answer',delta:answer}});
 emit({method:'item/completed',params:{threadId:thread.id,turnId:id,item:{type:'agentMessage',id:id+'-answer',text:answer,phase:'final_answer'}}});
 emit({method:'turn/completed',params:{threadId:thread.id,turn:{id,status:'completed',items:[],error:null}}});return;
 }
 if(q.id!==undefined)reply({});
}
process.stdin.setEncoding('utf8');process.stdin.on('data',data=>{buffer+=data;let i;while((i=buffer.indexOf('\\n'))>=0){const s=buffer.slice(0,i);buffer=buffer.slice(i+1);if(s.trim())void handle(JSON.parse(s)).catch(e=>{log({error:String(e)});process.exit(2)});}});process.stdin.on('end',()=>process.exit(0));
`,
  { mode: 0o755 },
);
const delay = (ms) => new Promise((r) => setTimeout(r, ms));
let child,
  events = [],
  next = 1;
async function wait(test, what, ms = 30000) {
  const until = Date.now() + ms;
  while (Date.now() < until) {
    const result = test();
    if (result) return result;
    if (child?.exitCode != null)
      throw Error(`Pi exited while ${what}: ${child.err}`);
    await delay(50);
  }
  throw Error(
    `Timeout ${what}; ${child?.err}; ${JSON.stringify(events.slice(-5))}`,
  );
}
const log = () => {
  try {
    return fs
      .readFileSync(path.join(state, "native.log"), "utf8")
      .trim()
      .split("\n")
      .filter(Boolean)
      .map(JSON.parse);
  } catch {
    return [];
  }
};
async function send(type, fields = {}) {
  const id = String(next++);
  child.stdin.write(JSON.stringify({ id, type, ...fields }) + "\n");
  const response = await wait(
    () => events.find((e) => e.id === id),
    "RPC " + type,
  );
  assert(response.success, JSON.stringify(response));
  return response;
}
async function start(resume) {
  events = [];
  const args = [
    "--mode",
    "rpc",
    "--offline",
    "--no-extensions",
    "--no-skills",
    "--no-context-files",
    "--approve",
    "-e",
    own,
    "-e",
    path.join(nativePackage, "index.ts"),
    ...[
      "fm-primary-turnend-guard.ts",
      "fm-primary-pi-watch.ts",
      "fm-branch-supervision.ts",
    ].flatMap((name) => ["-e", path.join(repo, ".pi/extensions", name)]),
    "--model",
    "codex-native/gpt-6-astra",
    "--session-dir",
    path.join(fixture, "sessions"),
  ];
  if (resume) args.push("--session", resume);
  else args.push("--codex-effort", "ultra");
  child = spawn(process.env.FM_PI_BIN || "pi", args, {
    cwd: repo,
    env: {
      ...process.env,
      FM_HOME: home,
      FM_STATE_OVERRIDE: state,
      FM_ROOT_OVERRIDE: repo,
      PI_CODEX_NATIVE_BIN: peer,
      PI_CODING_AGENT_DIR: path.join(fixture, "pi-config"),
      PI_TELEMETRY: "false",
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const ownedChild = child;
  ownedChild.err = "";
  ownedChild.stderr.on("data", (d) => {
    ownedChild.err += d;
    fs.appendFileSync(path.join(fixture, "stderr.log"), d);
  });
  let buffer = "";
  child.stdout.on("data", (d) => {
    buffer += d;
    let i;
    while ((i = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, i);
      buffer = buffer.slice(i + 1);
      if (line.trim()) {
        let e;
        try {
          e = JSON.parse(line);
        } catch {
          continue;
        }
        events.push(e);
        fs.appendFileSync(
          path.join(fixture, "events.jsonl"),
          JSON.stringify(e) + "\n",
        );
      }
    }
  });
  return (await send("get_state")).data.sessionFile;
}
async function stop() {
  if (!child) return;
  const c = child;
  child = undefined;
  c.kill("SIGTERM");
  await Promise.race([new Promise((r) => c.once("exit", r)), delay(3000)]);
  if (c.exitCode === null && c.signalCode === null) c.kill("SIGKILL");
}
let passed = false;
try {
  const session = await start();
  await send("prompt", { message: "ARM_PRIMARY" });
  await wait(
    () => events.some((e) => e.type === "agent_settled"),
    "first settle",
  );
  assert(fs.existsSync(path.join(state, "ownership-probes")), "real native ownership probe failed: " + child.err);
  const probed = fs.readFileSync(path.join(state, "ownership-probes"), "utf8").trim().split("\n").map((line) => JSON.parse(line));
  assert.deepEqual(probed.map((probe) => probe.executable), codexExecutables, "every real Codex executable was probed: " + child.err);
  assert.equal(fs.readFileSync(path.join(state, ".lock"), "utf8").trim(), String(child.pid));
  assert(
    log().some(
      (e) =>
        e.kind === "input" &&
        e.text.includes("NATIVE_PRIMARY_STARTUP_SENTINEL"),
    ),
    "startup missing",
  );
  assert(
    log().some(
      (e) =>
        e.kind === "control" &&
        e.name === "fm_watch_arm_pi" &&
        !e.result.isError,
    ),
    "watch control missing",
  );
  fs.writeFileSync(path.join(state, ".branch-outcomes-processed"), "0\n");
  execFileSync(
    path.join(root, "bin/fm-branch-outcome.sh"),
    [
      "append",
      "--task",
      "worker-smoke",
      "--verdict",
      "captain",
      "--summary",
      "WORKER_DONE_SENTINEL verified fixture completion",
    ],
    { env: { ...process.env, FM_HOME: home } },
  );
  fs.writeFileSync(path.join(state, "trigger"), "complete\n");
  await wait(
    () =>
      fs.existsSync(path.join(state, ".branch-outcomes-processed")) &&
      fs
        .readFileSync(path.join(state, ".branch-outcomes-processed"), "utf8")
        .trim() === "1",
    "native outcome acknowledgement",
  );
  await wait(
    () => log().filter((e) => e.name === "fm_branch_processed").length === 2,
    "duplicate acknowledgement refusal",
  );
  let calls = log().filter((e) => e.kind === "control");
  assert.equal(
    calls.filter((e) => e.name === "fm_branch_processed" && !e.result.isError)
      .length,
    1,
  );
  assert.equal(
    calls.filter((e) => e.name === "fm_branch_processed" && e.result.isError)
      .length,
    1,
  );
  assert(
    calls
      .find((e) => e.name === "fm_branch_outcomes")
      .result.content.some((c) => c.text.includes("WORKER_DONE_SENTINEL")),
  );
  await wait(
    () => events.filter((e) => e.type === "agent_settled").length >= 3,
    "completion settled",
  );
  await stop();
  const prior = log().filter((e) => e.name === "fm_branch_processed").length;
  await start(session);
  await send("prompt", { message: "RESTART_OBSERVATION" });
  await wait(
    () => events.some((e) => e.type === "agent_settled"),
    "resume settle",
  );
  assert.equal(
    log().filter((e) => e.name === "fm_branch_processed").length,
    prior,
    "resume repeated processed outcome",
  );
  const inputs = log().filter((entry) => entry.kind === "input");
  assert(inputs.length > 1 && inputs.every((entry) => entry.effort === "ultra"),
    "native Ultra was lost on initial, operational, or resumed turns");
  const progress = fs.readFileSync(path.join(state, "progress-events"), "utf8")
    .trim().split("\n").map(JSON.parse);
  assert(progress.some((event) => event.threadId === "fm-native-primary-thread" && event.phase === "output"),
    "installed native adapter did not emit streamed-output progress");
  passed = true;
  console.log(
    JSON.stringify(
      {
        result: "PASS",
        piVersion,
        adapterVersion,
        ...(process.env.FM_NATIVE_TEST_KEEP === "1" ? { fixture } : {}),
        codexVersions,
        checks: [
          "actual Pi runtime and native package",
          "full startup through real Codex command/exec and shell ownership",
          "native child replacement preserves Pi owner",
          ...(process.env.FM_NATIVE_CODEX_LAUNCHER ? ["installed npm Codex launcher resolves to the same Pi owner"] : []),
          "native Ultra preserved across operational turns and restart",
          "installed native adapter emits observable output progress",
          "actual FirstMate primary extensions",
          "startup operational message forwarded",
          "MCP watcher control",
          "idle watcher notification opens native turn",
          "durable completion visible/read/ack once",
          "duplicate acknowledgement refused",
          "restart does not reprocess acknowledged outcome",
        ],
        limits: [
          "model turns and watcher-close process use deterministic peers; no live model or backend tested",
        ],
      },
      null,
      2,
    ),
  );
} catch (error) {
  console.error(`Native Codex guard failed against Pi ${piVersion}, pi-codex-native ${adapterVersion}`);
  throw error;
} finally {
  await stop();
  if (passed && process.env.FM_NATIVE_TEST_KEEP !== "1")
    fs.rmSync(fixture, { recursive: true, force: true });
  else console.error("Native FirstMate test fixture: " + fixture);
}

JS
