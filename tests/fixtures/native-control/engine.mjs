// Executable engine double: real transport subprocesses, native behavior fixtures.
import {readFileSync, writeFileSync, existsSync} from "node:fs";
import {spawn} from "node:child_process";
import {pathToFileURL} from "node:url";
const [mod, channel, fixture] = process.argv.slice(2);
const config = JSON.parse(readFileSync(fixture, "utf8"));
const hooks = new Map();
let box = {text: config.draft ?? "ALPHA\n\n❯ title\n────\nTAIL", cursor: 3};
let reads = 0;
let fills = 0;
const save = () => writeFileSync(`${channel}/box.json`, JSON.stringify(box), {mode: 0o600});
const processRun = (args, init) => new Promise(resolve => {
  if (config.holdPoll && args[2] === "poll" && !existsSync(`${channel}/release-poll`)) {
    const t = setInterval(() => {
      if (existsSync(`${channel}/release-poll`)) {
        clearInterval(t);
        processRun(args, init).then(resolve);
      }
    }, 20);
    return;
  }
  const p = spawn(args[0], args.slice(1), {stdio: ["pipe", "pipe", "pipe"]});
  let stdout = "", stderr = "";
  p.stdout.on("data", s => {stdout += s;}); p.stderr.on("data", s => {stderr += s;});
  p.on("close", exitCode => resolve({exitCode, stdout, stderr}));
  p.stdin.end(init.stdin);
});
const engine = {
  plugin: {root: mod},
  env: {get: async name => ({CLAUDE_CODE_ENABLE_FUNCTION_HOOKS: "1",
    FM_CLAUDE_NATIVE_CHANNEL: channel, FM_CLAUDE_NATIVE_PID: String(process.pid)})[name]},
  session: {id: async () => "fixture-session", version: async () => ({base: config.version ?? "2.1.288"})},
  process: {run: processRun},
  clock: {every: (ms, callback) => {const t = setInterval(callback, ms); return {cancel: () => clearInterval(t)};}},
  prompt: {
    fill: async input => {
      if (config.refusal) return {isFilled: false, refusal: config.refusal};
      fills++;
      box = {text: input.mode === "append" ? box.text + input.text : input.text, cursor: input.text.length};
      if (config.rewrite && fills === 2) box.text = "MIDDLEWARE REWRITE";
      save();
      return {isFilled: true};
    },
    read: async () => {
      reads++;
      if (config.conflict && reads === 3) {
        await hooks.get("prompt.edit")(engine, {inputText: "NEW EDIT"}, async () => {
          box = {text: "NEW EDIT", cursor: 8}; save(); return box;
        });
      }
      return config.redacted ? {text: "", cursor: 0} : box;
    },
  },
  command: {run: async input => {
    if (input.command !== "exit") throw new Error("unexpected command");
    writeFileSync(`${channel}/command.json`, JSON.stringify(input), {mode: 0o600});
    if (config.commandError) throw new Error("command refused");
    if (!config.stubborn) setTimeout(() => process.exit(0), 150);
  }},
};
save();
while (!existsSync(`${channel}/boot.json`) || !JSON.parse(readFileSync(`${channel}/boot.json`)).pid)
  await new Promise(r => setTimeout(r, 20));
const {register} = await import(pathToFileURL(`${mod}/hooks/register.ts`));
register((event, hook) => hooks.set(event, hook));
await hooks.get("session.start")(engine, {}, async () => ({}));
writeFileSync(`${channel}/started.json`, JSON.stringify({version: config.version ?? "2.1.288"}), {mode: 0o600});
setInterval(() => {}, 1000);
