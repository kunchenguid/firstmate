// Fake SDK boundary and real confined filesystem behavior; no SDK runtime imports.
import assert from "node:assert/strict";
import { generateKeyPairSync, sign, verify } from "node:crypto";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, rmSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { CreateAgentSessionResult } from "@oh-my-pi/pi-coding-agent/sdk";
import type { Settings } from "@oh-my-pi/pi-coding-agent/config/settings";
import type { CustomToolContext } from "@oh-my-pi/pi-coding-agent/extensibility/custom-tools/types";
import { ApprovalBroker, type Capsule, type ApprovalReceipt, canonical, credentialGuard, digest, validateGate, verifyCredit, type CreditReceipt } from "../bin/omp-kepler/contract";
import { createConfinedTools, fileOperation } from "../bin/omp-kepler/tools";
import { options, PINNED, runApproved } from "../bin/omp-kepler/worker";

let checks = 0;
let nativeInteropSigned = 0;
const check = (fn: () => void): void => { fn(); checks++; };
const now = Math.floor(Date.now() / 1000);
const root = realpathSync(mkdtempSync(join(tmpdir(), "fm-omp-fake-")));
const model = {provider: "fixture", id: "fixture-model", name: "Fixture", identity: {class: "unknown"}, api: "openai-completions",
  baseUrl: "https://example.invalid/v1", reasoning: false, input: ["text"], compat: undefined, cost: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0}, contextWindow: 8192, maxTokens: 512} satisfies Capsule["model"];
const c: Capsule = {version: 1, task: "ATX-2170", issue: "ATX-2170", scope: "command-center-pilot", role: "crew", backend: "orca", cockpit: "kepler", launchSurface: "manual-terminal", supervisor: "firstmate", keplerTaskId: null, keplerWorktreeId: null,
  authority: "owner-approved-activation", ownerAction: "ATX-1758-approved", gates: {provider: true, installation: false, login: false, merge: false, production: false},
  worktree: root, head: "0".repeat(40), brief: "Inspect the fixture.", issuedAt: now, deadline: now + 300,
  credit: {included: true, overage: 0, validUntil: now + 300}, fallback: false, tools: ["read", "grep", "write", "edit"], model,
  runtime: {bun: "/fixture/bun", bunVersion: "1.4.0", bunSha256: "fixture", sdkVersion: "18.1.11", nodeModules: "/fixture/modules", nodeModulesSha256: "fixture"}, sourceHashes: {}, credentialFile: "/fixture/credential"};
const {publicKey, privateKey} = generateKeyPairSync("ed25519");
const key = publicKey.export({type: "spki", format: "pem"}).toString();
const signature = (payload: ApprovalReceipt) => ({payload, signature: sign(null, Buffer.from(canonical(payload)), privateKey).toString("base64")});
try {
  const fixtureKey = join(root, "fixture.key");
  writeFileSync(fixtureKey, privateKey.export({type: "pkcs8", format: "pem"}), {mode: 0o600});
  const pythonRecord = (payload: unknown): {body: string; hash: string; envelope: {payload: unknown; signature: string} | null} => {
    const fixture = join(root, "interop.json"); writeFileSync(fixture, JSON.stringify(payload));
    const code = `import importlib.util,json,hashlib,subprocess,sys\ns=importlib.util.spec_from_file_location('producer',sys.argv[3]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)\np=json.load(open(sys.argv[1]));b=m.controller.canonical(p)\nv=subprocess.run(['/usr/bin/openssl','version'],stdout=subprocess.PIPE,check=True).stdout\ne=m.sign_record(p,sys.argv[2]) if v.startswith(b'OpenSSL 3') else None\nprint(json.dumps({'body':b.decode(),'hash':hashlib.sha256(b).hexdigest(),'envelope':e}))`;
    const result = spawnSync("/usr/bin/python3", ["-I", "-c", code, fixture, fixtureKey, join(import.meta.dir, "../bin/omp-kepler/record_signer.py")], {encoding: "utf8", timeout: 5000});
    assert.equal(result.status, 0, result.stderr); return JSON.parse(result.stdout);
  };
  for (const payload of [
    {...c, model: {...model, cost: {input: 0.1, output: 1.0, cacheRead: 1e-7, cacheWrite: -0}}, unicode: {"\ue000": "é\\\"\n", "😀": "𐀀"}},
    {numbers: [1.0, -0, 1e-7, 1e-5, 0.1, Number.MIN_VALUE, Number.MAX_SAFE_INTEGER, -Number.MAX_SAFE_INTEGER]},
  ]) {
    const produced = pythonRecord(payload);
    check(() => assert.equal(produced.body, canonical(payload)));
    check(() => assert.equal(produced.hash, digest(payload)));
    if (produced.envelope) { check(() => assert.equal(verify(null, Buffer.from(canonical(produced.envelope!.payload)), key, Buffer.from(produced.envelope!.signature, "base64")), true)); nativeInteropSigned++; }
  }
  for (const bad of [NaN, Infinity, 2 ** 53, "\ud800", {"\udfff": 1}]) check(() => assert.throws(() => canonical(bad)));
  check(() => assert.equal(PINNED["features.unexpectedStopDetection"], "none"));
  check(() => validateGate(c));
  const failures: Array<(copy: Capsule) => void> = [
    v => { v.authority = "implementation-only"; }, v => { v.ownerAction = "ATX1758 OWNER ACTION PENDING"; }, v => { v.issue = "OTHER" as never; },
    v => { v.gates.provider = false; }, v => { v.gates.installation = true; }, v => { v.gates.login = true; },
    v => { v.gates.merge = true; }, v => { v.gates.production = true; }, v => { v.credit.included = false; },
    v => { v.credit.overage = 1; }, v => { v.credit.validUntil = now; }, v => { v.deadline = now; },
    v => { v.deadline = now + 901; }, v => { v.issuedAt = now + 10; }, v => { v.issuedAt = now - 1000; }, v => { v.tools.push("bash"); },
    v => { v.tools = []; }, v => { v.model.id = "*"; }, v => { v.model.provider = "default"; v.model.baseUrl = "http://example.invalid"; },
    v => { v.brief = ""; }, v => { v.role = "scout"; }, v => { v.cockpit = undefined as never; },
  ];
  for (const mutate of failures) {
    const copy = structuredClone(c); mutate(copy);
    let invoked = false;
    await assert.rejects(runApproved(copy, {}, async () => { invoked = true; throw Error("unexpected_factory"); }, async () => {}, () => {}));
    check(() => assert.equal(invoked, false));
  }
  let clock = now;
  let cancelled = false;
  const guard = credentialGuard(c, "fixture-opaque-token", () => cancelled, () => clock);
  check(() => assert.equal(guard(model), "fixture-opaque-token"));
  for (const key of ["provider", "id", "api", "baseUrl"] as const) check(() => assert.throws(() => guard({...model, [key]: "changed"})));
  check(() => assert.throws(() => guard({...model, requestModelId: "foreign-upstream"})));
  cancelled = true; check(() => assert.throws(() => guard(model))); cancelled = false;
  clock = c.deadline; check(() => assert.throws(() => guard(model))); clock = now;
  check(() => assert.throws(() => credentialGuard(c, "", () => false)(model)));
  const credit: CreditReceipt = {version: 1, kind: "verified-provider-credit", task: c.task, capsuleHash: digest(c), provider: model.provider,
    modelId: model.id, accountEvidenceRef: "inert-account-fixture", usageEvidenceRef: "inert-usage-fixture", included: true, overage: 0, observedAt: now, validUntil: c.deadline};
  const signedCredit = (p: CreditReceipt) => ({payload: p, signature: sign(null, Buffer.from(canonical(p)), privateKey).toString("base64")});
  const producedCredit = pythonRecord({...credit, observedAt: now - 0.125});
  check(() => assert.equal(producedCredit.body, canonical({...credit, observedAt: now - 0.125})));
  if (producedCredit.envelope) {
    check(() => verifyCredit(producedCredit.envelope as {payload: CreditReceipt; signature: string}, c, digest(c), key, now));
    nativeInteropSigned++;
  }
  check(() => verifyCredit(signedCredit(credit), c, digest(c), key, now));
  check(() => assert.throws(() => verifyCredit(signedCredit(credit), c, digest(c), key, now + 61)));
  check(() => assert.throws(() => verifyCredit(signedCredit({...credit, provider: "foreign"}), c, digest(c), key, now)));
  check(() => assert.throws(() => verifyCredit(signedCredit({...credit, usageEvidenceRef: ""}), c, digest(c), key, now)));

  const broker = new ApprovalBroker(c, digest(c), key, () => clock);
  const helper = realpathSync(join(import.meta.dir, "../bin/omp-kepler/fs_boundary.py"));
  check(() => assert.throws(() => fileOperation("/usr/bin/python3", helper, realpathSync(join(import.meta.dir, "../bin/omp-kepler")), "execute", {operation: "read", path: "controller.py"})));
  writeFileSync(join(root, "file.txt"), "original\n");
  const tools = createConfinedTools(broker, "/usr/bin/python3", helper);
  check(() => assert.deepEqual(tools.map(t => t.name), c.tools));
  const read = tools.find(t => t.name === "read")!;
  const readResult = await read.execute("read-1", {path: "file.txt"}, undefined, {} as CustomToolContext);
  check(() => assert.equal(readResult.content[0].type, "text"));
  for (const path of ["/etc/passwd", "../foreign", ".env.local", ".git/config", "state/owner.pub"]) {
    await assert.rejects(read.execute("read-bad", {path}, undefined, {} as CustomToolContext)); checks++;
  }
  const write = tools.find(t => t.name === "write")!;
  const args = {path: "file.txt", content: "approved\n"};
  assert.equal(typeof write.approval, "function");
  const approval = typeof write.approval === "function" ? write.approval(args) : undefined;
  assert.ok(approval && typeof approval === "object" && approval.reason);
  const request = JSON.parse(approval.reason.slice("FM_MUTATION ".length));
  check(() => assert.equal(request.preview.path, join(root, "file.txt")));
  check(() => assert.equal(request.preview.argsDigest, digest({...args, operation: "write"})));
  const interopBroker = new ApprovalBroker(c, digest(c), key, () => now + 0.125);
  const interopRequest = interopBroker.request("write", request.preview, request.arguments);
  const producedApproval = pythonRecord({...interopRequest, decision: "approve"});
  check(() => assert.equal(producedApproval.body, canonical({...interopRequest, decision: "approve"})));
  if (producedApproval.envelope) {
    check(() => assert.equal(interopBroker.consume(producedApproval.envelope as {payload: ApprovalReceipt; signature: string}), true));
    nativeInteropSigned++;
  }
  await assert.rejects(write.execute("write-before-owner", args, undefined, {} as CustomToolContext)); checks++;
  const receipt: ApprovalReceipt = {...request, decision: "approve"};
  check(() => assert.throws(() => broker.consume({...signature(receipt), signature: "wrong"})));
  check(() => assert.throws(() => broker.consume(signature({...receipt, task: "foreign"}))));
  check(() => assert.equal(broker.consume(signature(receipt)), true));
  check(() => assert.throws(() => broker.consume(signature(receipt))));
  await write.execute("write-approved", args, undefined, {} as CustomToolContext);
  check(() => assert.equal(readFileSync(join(root, "file.txt"), "utf8"), "approved\n"));
  await assert.rejects(write.execute("write-replay", args, undefined, {} as CustomToolContext)); checks++;
  const next = broker.request("write", fileOperation("/usr/bin/python3", helper, root, "preview", {...args, operation: "write"}) as typeof request.preview, {...args, operation: "write"});
  broker.consume(signature({...next, decision: "approve"}));
  writeFileSync(join(root, "file.txt"), "target changed\n");
  await assert.rejects(write.execute("write-changed", args, undefined, {} as CustomToolContext)); checks++;
  check(() => assert.equal(readFileSync(join(root, "file.txt"), "utf8"), "target changed\n"));
  const stale = broker.request("write", request.preview, {...args, operation: "write"}); clock += 61;
  check(() => assert.throws(() => broker.consume(signature({...stale, decision: "approve"})))); clock = now;
  const denied = broker.request("write", request.preview, {...args, operation: "write"});
  check(() => assert.equal(broker.consume(signature({...denied, decision: "deny"})), false));
  check(() => assert.throws(() => broker.take(denied.preview.argsDigest)));
  const scout = {...c, role: "scout" as const, tools: ["read", "grep"]};
  check(() => assert.deepEqual(createConfinedTools(new ApprovalBroker(scout, digest(scout), key), "/usr/bin/python3", helper).map(t => t.name), ["read", "grep"]));

  // Explicit fake classes satisfy only the boundary under test, never SDK construction.
  const settings = {get: (key: string) => PINNED[key as keyof typeof PINNED]} as unknown as Settings;
  const dependencies = {settings, authStorage: {}, modelRegistry: {}, sessionManager: {}, customTools: tools, getApiKey: guard} as unknown as Parameters<typeof options>[1];
  const input = options(c, dependencies, "/neutral", "/neutral/agent");
  check(() => assert.equal(input.restrictToolNames, true));
  check(() => assert.equal(input.allowRestrictedCustomTools, true));
  check(() => assert.equal(input.autoApprove, false));
  check(() => assert.deepEqual([input.enableMCP, input.enableLsp, input.enableIrc], [false, false, false]));
  let prompts = 0, disposals = 0, uiReady = false;
  let listener: (event: {type: string; isTerminal?: boolean}) => void = () => {};
  const fake = {session: {model, getActiveToolNames: () => c.tools, getEnabledToolNames: () => c.tools,
    extensionRunner: {hasUI: () => uiReady}, subscribe: (cb: typeof listener) => {listener = cb; return () => {};},
    prompt: async (brief: string, opts: unknown) => { assert.equal(brief, c.brief); assert.deepEqual(opts, {expandPromptTemplates: false}); prompts++; listener({type: "agent_start"}); listener({type: "agent_end", isTerminal: false}); listener({type: "agent_end", isTerminal: true}); },
    getLastAssistantMessage: () => ({stopReason: "stop"}), getLastAssistantText: () => "inert fake result",
    abort: async () => {}, dispose: async () => {disposals++;}}, lspServers: [], setToolUIContext: () => {uiReady = true;}} as unknown as CreateAgentSessionResult;
  const events: unknown[] = [];
  await runApproved(c, input, async () => fake, async result => {result.setToolUIContext({} as never, true);}, e => events.push(e));
  check(() => assert.equal(prompts, 1)); check(() => assert.equal(disposals, 1));
  check(() => assert.deepEqual(events, [{type: "agent_start"}, {type: "agent_end", isTerminal: false}, {type: "agent_end", isTerminal: true},
    {type: "worker_result", task: c.task, stopReason: "stop", text: "inert fake result", truncated: false}]));
  const wrong = {...fake, modelFallbackMessage: "fallback"};
  await assert.rejects(runApproved(c, input, async () => wrong, async () => {}, () => {})); checks++;
  check(() => assert.equal(prompts, 1));
  for (const weakened of [{...input, autoApprove: true}, {...input, enableMCP: true}, {...input, getApiKey: undefined}, {...input, modelRegistry: undefined}, {...input, customTools: []}]) {
    let invoked = false;
    await assert.rejects(runApproved(c, weakened, async () => {invoked = true; return fake;}, async () => {}, () => {}));
    check(() => assert.equal(invoked, false));
  }
  const failingCleanup = {...fake, session: {...fake.session, dispose: async () => {throw Error("inert failure");}}} as unknown as CreateAgentSessionResult;
  await assert.rejects(runApproved(c, input, async () => failingCleanup, async () => {}, () => {}), /worker_cleanup_failed/); checks++;
  const hangingCleanup = {...fake, session: {...fake.session, dispose: async () => new Promise<void>(() => {})}} as unknown as CreateAgentSessionResult;
  await assert.rejects(runApproved(c, input, async () => hangingCleanup, async () => {}, () => {}), /worker_cleanup_timeout/); checks++;
  const failedAssistant = {...fake, session: {...fake.session, getLastAssistantMessage: () => ({stopReason: "error"})}} as unknown as CreateAgentSessionResult;
  await assert.rejects(runApproved(c, input, async () => failedAssistant, async () => {}, () => {}), /successful_assistant_stop_required/); checks++;
  console.log(JSON.stringify({classification: "fake-sdk-and-confined-tools-only", checks, nativeInteropSigned,
    nativeInteropCapability: nativeInteropSigned ? "passed" : "skipped-native-openssl-3-required", actualSdkSessions: 0, providerCalls: 0}));
} finally { rmSync(root, {recursive: true, force: true}); }
