// Invoked serially by fm-pi-notebook-live-e2e.test.sh; no provider request is made.
import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";
import { spawn, spawnSync, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";

const root = process.env.FM_NOTEBOOK_TEST_ROOT;
const pkg = path.resolve(process.env.FM_PI_NOTEBOOK_PACKAGE);
const piPackage = path.resolve(process.env.FM_PI_PACKAGE_DIR);
const provider = process.env.FM_NOTEBOOK_PROVIDER;
const order = process.env.FM_NOTEBOOK_ORDER;
const model = provider === "azure-anthropic" ? "claude-opus-5" : "gpt-5.6";
const lab = fs.mkdtempSync(path.join(process.env.FM_NOTEBOOK_TEST_OUTPUT, `${order}-${provider}-`));
const state = path.join(lab, "state"), agent = path.join(lab, "agent");
const modulePath = (name) => JSON.stringify(path.join(pkg, "dist", name));
const run = (cmd, args, env = {}) => execFileSync(cmd, args, {
  encoding: "utf8", env: { ...process.env, ...env }, timeout: 15000,
}).trim();
for (const dir of [state, agent, "bin", "config", "projects/demo", ".pi/extensions/lib"].map(
  (dir) => path.isAbsolute(dir) ? dir : path.join(lab, dir),
)) fs.mkdirSync(dir, { recursive: true });
for (const name of fs.readdirSync(path.join(root, "bin"))) {
  fs.symlinkSync(path.join(root, "bin", name), path.join(lab, "bin", name));
}
for (const name of ["fm-primary-turnend-guard.ts", "lib/fm-operational-input.ts"]) {
  fs.copyFileSync(path.join(root, ".pi/extensions", name), path.join(lab, ".pi/extensions", name));
}
function script(name, body) {
  const target = path.join(lab, "bin", name);
  fs.unlinkSync(target);
  fs.writeFileSync(target, `#!/bin/sh\n${body}\n`, { mode: 0o700 });
}
// Isolate startup/supervision from the test session. Command classifiers, busy
// writer, watcher and queue remain real; the arm body can only create a marker.
script("fm-sessionstart-run.sh", "exit 0");
script("fm-turnend-guard.sh", "exit 0");
script("fm-watch-arm.sh", `printf BAD > '${lab}/watcher-ran'`);
fs.writeFileSync(path.join(lab, "AGENTS.md"), "");
run("git", ["init", "-q", lab]);
const { DENO_VERSION, resolveDenoAsset } = await import(pathToFileURL(path.join(pkg, "dist/tools/notebook-mode/deno-assets.js")));
const asset = resolveDenoAsset(process.platform, process.arch);
const binary = fs.readFileSync(process.env.FM_NOTEBOOK_DENO);
assert.equal(createHash("sha256").update(binary).digest("hex"), asset.binarySha256, "supply the package's pinned Deno, not an unverified substitute");
const cache = path.join(agent, "cache/pi-codex-conversion/notebook-mode", `deno-${DENO_VERSION}`, `${process.platform}-${process.arch}`);
fs.mkdirSync(cache, { recursive: true });
fs.writeFileSync(path.join(cache, asset.executable), binary, { mode: 0o700 });
const socket = `fm-notebook-${process.pid}`;
const tmux = run("which", ["tmux"]);
const env = {
  ...process.env, FM_HOME: lab, FM_ROOT_OVERRIDE: lab, FM_STATE_OVERRIDE: state,
  PI_CODING_AGENT_DIR: agent, PI_OFFLINE: "1", FM_POLL: "1", FM_SIGNAL_GRACE: "1",
  FM_HEARTBEAT: "999999", FM_STALE_ESCALATE_SECS: "999999",
};
const gen = run(path.join(root, "bin/fm-busy-event.sh"), ["arm", state, "worker", "--state", "idle"], env);
fs.writeFileSync(path.join(lab, "config/backend"), "tmux\n");
const fakebin = path.join(lab, "fakebin");
fs.mkdirSync(fakebin);
fs.writeFileSync(path.join(fakebin, "tmux"), `#!/bin/sh\nexec '${tmux}' -L '${socket}' "$@"\n`, { mode: 0o700 });
env.PATH = `${fakebin}:${path.dirname(process.execPath)}:${process.env.PATH}`;
fs.writeFileSync(path.join(state, "worker.meta"), `harness=pi\nbackend=tmux\nwindow=worker\nproject=${lab}\nworktree=${lab}\nkind=ship\n`);
const ext = path.join(lab, "notebook-proof.ts");
fs.writeFileSync(ext, `
import fs from "node:fs";
import {execFileSync} from "node:child_process";
import {createAssistantMessageEventStream} from "@earendil-works/pi-ai";
import {registerCodeModeTools} from ${modulePath("tools/code-mode/tools.js")};
import {createExecCommandTool} from ${modulePath("tools/exec/command-tool.js")};
import {createExecSessionManager} from ${modulePath("tools/exec/session-manager.js")};
import {createExecCommandTracker} from ${modulePath("tools/exec/command-state.js")};
import {toNestedTool} from ${modulePath("adapter/code-mode/nested-tool-adapter.js")};
import {registerCodeModeToolCompletion} from ${modulePath("code-mode-hooks.js")};
import {resolveCodexRuntimePlan} from ${modulePath("adapter/activation/runtime-plan.js")};
import {DEFAULT_CODEX_CONVERSION_CONFIG} from ${modulePath("adapter/activation/config-contract.js")};
const state = ${JSON.stringify(state)};
const log = (event) => fs.appendFileSync(state + "/events.jsonl", JSON.stringify(event) + "\\n");
const busy = (value,event) => execFileSync(${JSON.stringify(root + "/bin/fm-busy-event.sh")},
  ["apply",state,"worker",value,"--gen",${JSON.stringify(gen)},"--source","pi-ext","--event",event]);
export default async function(pi) {
  const sessions = createExecSessionManager();
  const tracker = createExecCommandTracker();
  const tool = createExecCommandTool(tracker,sessions,{waitForNonInteractiveExit:true,showOutputWhenCollapsed:true});
  const config = {...DEFAULT_CODEX_CONVERSION_CONFIG,executionMode:"notebook",scope:{allProviders:"on",additionalProviders:[]}};
  const registration = await registerCodeModeTools(pi,{
    getTools: () => [toNestedTool(tool,"await tools.exec_command({cmd})",{}, {yieldTimeMs:1800000})],
    executionKind: (ctx) => resolveCodexRuntimePlan(ctx,config).kind,
    notebookOptions: () => ({maxHeapMiB:256,agentDir:${JSON.stringify(agent)}}),
    isActive: () => true, providesRenderers:true, richRendering: () => ${order === "last"},
  });
  // Observation only: demonstrates the optional published completion surface.
  registerCodeModeToolCompletion(pi,(e) => log({kind:"nested",toolName:e.toolName,input:e.input,status:e.status,phase:e.phase,error:e.error}));
  // Same Pi lifecycle-to-writer contract generated by fm-spawn; no busy guess
  // from tool names, render text or subprocess liveness.
  pi.on("agent_start", () => {busy("busy","agent-start");log({kind:"busy"});});
  pi.on("agent_settled", (_e,ctx) => {if(ctx.isIdle()){busy("idle","agent-settled");log({kind:"idle"});}});
  pi.on("turn_end", () => {
    fs.closeSync(fs.openSync(state+"/worker.turn-ended","a"));
    const now=new Date();fs.utimesSync(state+"/worker.turn-ended",now,now);log({kind:"turn_end"});
  });
  pi.on("tool_call", (e) => log({kind:"outer",toolName:e.toolName,input:e.input}));
  pi.on("tool_execution_update", (e) => log({kind:"update",toolName:e.toolName}));
  pi.on("session_start", () => fs.writeFileSync(state+"/pi.pid",String(process.pid)));
  pi.on("session_shutdown", async () => {await registration.shutdown();await sessions.shutdown();});
  pi.registerProvider(${JSON.stringify(provider)}, {
    apiKey:"local-test-only",baseUrl:"http://127.0.0.1/unused",api:"notebook-proof",
    models:[{id:${JSON.stringify(model)},name:"Local deterministic notebook test",reasoning:false,input:["text"],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:32000,maxTokens:1000}],
    streamSimple(model,context) {
      const stream=createAssistantMessageEventStream();
      const isTool=context.messages.at(-1)?.role==="toolResult";
      const content=isTool ? [{type:"text",text:"NOTEBOOK_PROOF_FINISHED"}] : [{type:"toolCall",id:"cell-"+Date.now(),name:"exec",arguments:{code:fs.readFileSync(state+"/cell.js","utf8")}}];
      const result={role:"assistant",content,api:model.api,provider:model.provider,model:model.id,usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},stopReason:isTool?"stop":"toolUse",timestamp:Date.now()};
      queueMicrotask(() => {
        stream.push({type:"start",partial:result});
        if(isTool) stream.push({type:"text_end",contentIndex:0,content:content[0].text,partial:result});
        else stream.push({type:"toolcall_end",contentIndex:0,toolCall:content[0],partial:result});
        stream.push({type:"done",reason:result.stopReason,message:result});stream.end();
      });
      return stream;
    },
  });
}
`);
const statusCmd = `printf 'working: real notebook cell started\\n' >> '${state}/worker.status'; sleep 5; printf 'LEGIT_NOTEBOOK_COMMAND\\n'`;
fs.writeFileSync(path.join(state, "cell.js"), `
const command=${JSON.stringify(statusCmd)};
text(await tools.exec_command({cmd:command,login:false}));
for (const cmd of ["bin/fm-watch-arm.sh & wait", "cd projects/demo; pwd > ../../cd-ran"]) {
  try { await tools.exec_command({cmd,login:false}); } catch (error) { text(String(error)); }
}
await new Deno.Command("/bin/sh",{args:["-c","printf DIRECT > direct-ran"]}).output();
const originalCwd = Deno.cwd(); Deno.chdir("projects/demo"); text("DIRECT_CWD="+Deno.cwd()); Deno.chdir(originalCwd);
text(await tools.exec_command({cmd:${JSON.stringify(`printf 'done: notebook status notification\n' >> '${state}/worker.status'`)},login:false}));
`);
const guard = path.join(lab, ".pi/extensions/fm-primary-turnend-guard.ts");
const extensions = order === "first" ? [guard, ext] : [ext, guard];
const quote = (value) => `'${value.replaceAll("'", "'\\''")}'`;
fs.writeFileSync(path.join(lab, "launch.sh"), `#!/bin/sh\nexec ${[
  process.execPath, path.join(piPackage, "dist/cli.js"), "--offline", "--no-extensions", "--no-skills", "--no-context-files", "--approve",
  ...extensions.flatMap((file) => ["-e", file]), "--model", `${provider}/${model}`, "--session-dir", path.join(lab, "sessions"), "RUN_NOTEBOOK_PROOF",
].map(quote).join(" ")}\n`, { mode: 0o700 });
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(test, label) {
  for (let i = 0; i < 600; i++) {
    if (test()) return;
    if (run(tmux, ["-L", socket, "list-panes", "-t", "worker", "-F", "#{pane_dead}"]) === "1") {
      throw Error(`Pi exited: ${fs.readFileSync(path.join(lab, "pi.stderr"), "utf8")}`);
    }
    await delay(100);
  }
  throw Error(`timeout: ${label}`);
}
const pane = () => run(tmux, ["-L", socket, "capture-pane", "-p", "-t", "worker", "-S", "-500"]);
const record = () => fs.readFileSync(path.join(state, "worker.busy-state"), "utf8");
let watch, watchOutput = "";
try {
  run(tmux, ["-L", socket, "new-session", "-d", "-s", "worker", "-x", "160", "-y", "70", "-c", lab], env);
  run(tmux, ["-L", socket, "set-option", "-t", "worker", "remain-on-exit", "on"]);
  run(tmux, ["-L", socket, "send-keys", "-t", "worker", "-l", `exec ${quote(path.join(lab, "launch.sh"))} 2>${quote(path.join(lab, "pi.stderr"))}`]);
  run(tmux, ["-L", socket, "send-keys", "-t", "worker", "Enter"]);
  await until(() => fs.existsSync(path.join(state, "worker.status")), "notebook status append");
  fs.writeFileSync(path.join(lab, "pane-busy.txt"), pane());
  assert.match(record(), /state=busy /);
  assert(!fs.existsSync(path.join(state, "worker.turn-ended")), "long cell must not fabricate a completed turn");
  watch = spawn(path.join(root, "bin/fm-watch.sh"), [], { env, stdio: ["ignore", "pipe", "pipe"] });
  watch.stdout.on("data", (data) => { watchOutput += data; });
  watch.stderr.on("data", (data) => fs.appendFileSync(path.join(lab, "watch.stderr"), data));
  await until(() => fs.existsSync(path.join(state, ".last-watcher-beat")), "watcher ready");
  const duplicate = spawnSync(path.join(root, "bin/fm-watch.sh"), [], { env, encoding: "utf8", timeout: 3000 });
  assert.equal(duplicate.status, 0);
  assert.match(duplicate.stdout, /already running/);
  await until(() => record().includes("state=idle "), "settled idle");
  await until(() => watch.exitCode !== null, "supervision notification");
  assert.match(watchOutput, /worker.status/);
  assert.match(watchOutput, /worker.turn-ended/);
  const queue = fs.readFileSync(path.join(state, ".wake-queue"), "utf8");
  assert.match(queue, /worker.status/);
  assert.match(queue, /worker.turn-ended/);
  fs.writeFileSync(path.join(lab, "wake.txt"), watchOutput + queue);
  fs.writeFileSync(path.join(lab, "pane-idle.txt"), pane());
  assert.match(pane(), /NOTEBOOK_PROOF_FINISHED/);
  assert.match(pane(), /LEGIT_NOTEBOOK_COMMAND/);
  assert(!fs.existsSync(path.join(lab, "watcher-ran")), "watcher background command reached the shell");
  assert(!fs.existsSync(path.join(lab, "cd-ran")), "persistent cd reached the shell");
  assert(fs.existsSync(path.join(lab, "direct-ran")), "known limit: direct Deno execution is not intercepted");
  const events = fs.readFileSync(path.join(state, "events.jsonl"), "utf8").trim().split("\n").map(JSON.parse);
  assert.equal(events.filter((e) => e.kind === "outer").length, 1, "Pi sees the cell, not nested shell calls");
  const nested = events.filter((e) => e.kind === "nested");
  assert.equal(nested.length, 4, "completion sees four nested commands, not direct runtime operations");
  assert.equal(nested.filter((e) => e.phase === "preflight").length, 2);
  assert(nested.some((e) => e.error?.includes("watcher-background")));
  assert(nested.some((e) => e.error?.includes("persistent-cd")));
  assert(!fs.existsSync(path.join(state, "worker.progress")), "notebook updates do not currently refresh native-harness progress");

  // Crash a real active cell, preserve its already queued outcome, and reject
  // an old-generation lifecycle callback after recovery arms a replacement.
  fs.writeFileSync(path.join(state, "cell.js"), 'await new Promise(resolve => setTimeout(resolve, 30000));');
  run(tmux, ["-L", socket, "send-keys", "-t", "worker", "-l", "CRASH_NOTEBOOK_PROOF"]);
  run(tmux, ["-L", socket, "send-keys", "-t", "worker", "Enter"]);
  await until(() => record().includes("state=busy "), "second cell busy");
  await delay(1000);
  process.kill(Number(fs.readFileSync(path.join(state, "pi.pid"), "utf8")), "SIGKILL");
  assert.match(record(), /state=busy /, "crash must not fabricate idle");
  assert.equal(fs.readFileSync(path.join(state, ".wake-queue"), "utf8"), queue);
  const replacement = run(path.join(root, "bin/fm-busy-event.sh"), ["arm", state, "worker", "--state", "unknown"], env);
  assert.notEqual(replacement, gen);
  const late = spawnSync(path.join(root, "bin/fm-busy-event.sh"), ["apply", state, "worker", "idle", "--gen", gen, "--source", "pi-ext", "--event", "agent-settled"], { env, encoding: "utf8" });
  assert.equal(late.status, 1);
  assert.match(record(), /state=unknown /);
  const drained = spawnSync(path.join(root, "bin/fm-wake-drain.sh"), [], { env, encoding: "utf8", timeout: 15000 });
  assert.equal(drained.status, 0);
  assert.match(drained.stdout, /worker.status/);
  assert.match(drained.stderr, /WAKE_ACK_REQUIRED/);
  fs.writeFileSync(path.join(lab, "recovery.txt"), late.stderr + drained.stdout + drained.stderr);
  const version = JSON.parse(fs.readFileSync(path.join(piPackage, "package.json"), "utf8")).version;
  const packageVersion = JSON.parse(fs.readFileSync(path.join(pkg, "package.json"), "utf8")).version;
  console.log(`ok - Pi ${version}, Notebook ${packageVersion}, Deno ${DENO_VERSION}: guard-${order} ${provider}/${model}, shell denials, busy/idle, notifications, queue replay, stale-generation refusal, TUI (rich=${order === "last"}); direct runtime calls remain outside protection`);
} finally {
  if (watch?.exitCode === null) watch.kill("SIGTERM");
  const capture = spawnSync(tmux, ["-L", socket, "capture-pane", "-p", "-t", "worker", "-S", "-500"], { encoding: "utf8" });
  fs.writeFileSync(path.join(lab, "pane-final.txt"), capture.stdout ?? "");
  spawnSync(tmux, ["-L", socket, "kill-server"]);
}
