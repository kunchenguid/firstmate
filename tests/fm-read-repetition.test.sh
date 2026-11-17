#!/usr/bin/env bash
# Executes the Pi read-loop policy, extension events and ownership boundary
# against synthetic fixtures, without a model, SDK install or live home.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Keep fixture types readable using Node's built-in TypeScript stripping.
# One process shares the imports; only completed assertions emit named results.
if ! policy_results=$(
  cd "$ROOT"
  NODE_NO_WARNINGS=1 node --input-type=module-typescript <<'TS'
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";

import { HISTORY_TYPE, NOTICE_TYPE, identifyRead, ReadRepetition, WINDOW_MS, readLimits, DEFAULT_LIMITS } from "./.pi/extensions/lib/fm-primary-read-repetition-policy.ts";
import managedGuard, { loadReadRepetitionLimits, primaryOwnsContext, registerReadRepetitionGuard } from "./.pi/extensions/fm-primary-read-repetition.ts";

// Assertions stay synchronous; Bash owns reporting and the subject exit status.
function check(name: string, body: () => void, enabled = true) {
  if (!enabled) {
    console.log(`skip\t${name}`);
    return;
  }
  try {
    body();
  } catch (error) {
    console.error(`Assertion failed: ${name}`);
    throw error;
  }
  console.log(`pass\t${name}`);
}

const root = process.cwd();
// Fully synthetic long sequences. No private transcript or command data.
const captured = [85, 65].map((count) => ({ calls: Array.from({ length: count * 2 }, (_, i) => ({
  timestamp: new Date(1000 + i).toISOString(), toolCallId: `synthetic-${i}`, toolName: "bash",
  input: { command: `cat ${root}/${i % 2 ? "README.md" : "AGENTS.md"}` },
  isError: false, content: [{ type: "text", text: `fixture-result-${i % 2}` }],
})) }));
const ssh = `ssh -o BatchMode=yes -o ConnectTimeout=10 fixture-host 'cd /fixture && echo summary && git diff --stat abcdef0..HEAD | sed -n "1,20p"' 2>&1 | head -40`;
const input = { command: `cat ${root}/README.md` };

function harness({ entries = [], owned = true, acceptsInput = true, now = () => 1000, limits = readLimits({ enabled: true }) } = {} as any) {
  const handlers = new Map();
  const messages: any[] = [], writes: any[] = [];
  let aborts = 0, seq = 0;
  const ctx: any = {
    cwd: root, abort() { aborts++; },
    sessionManager: { getSessionId: () => "test-session", getBranch: () => entries },
  };
  const pi: any = {
    on(name: string, fn: any) { handlers.set(name, fn); },
    appendEntry(customType: string, data: any) {
      const entry = { type: "custom", customType, data: structuredClone(data) };
      entries.push(entry); writes.push(entry);
    },
    sendMessage(message: any, options: any) { messages.push({ ...message, options }); },
  };
  registerReadRepetitionGuard(pi, { root, owns: () => typeof owned === "function" ? owned() : owned, acceptsInput: () => acceptsInput, now, limits });
  const emit = (type: string, event = {}) => handlers.get(type)?.({ type, ...event }, ctx);
  function call(args = input, name = "bash", id = `fake-${++seq}`) {
    return { type: "tool_call", toolCallId: id, toolName: name, input: args };
  }
  function result(call: any, text = "sanitized stable output", extra = {}) {
    return { ...call, type: "tool_result", content: [{ type: "text", text }], isError: false, ...extra };
  }
  function complete(args = input, text = "sanitized stable output", extra = {}, name = "bash") {
    const c = call(args, name); const veto = emit("tool_call", c);
    if (!veto?.block) emit("tool_result", result(c, text, extra));
    return veto;
  }
  return { emit, call, result, complete, entries, messages, writes, get aborts() { return aborts; } };
}

check("synthetic 85/65 alternating batches execute only three A/B pairs", () => {
  assert.deepEqual(captured.map((c: any) => c.calls.length), [170, 130]);
  for (const fixture of captured) {
    let clock = Date.parse(fixture.calls[0].timestamp);
    const h = harness({ now: () => clock });
    let executed = 0;
    for (const c of fixture.calls) {
      clock = Date.parse(c.timestamp);
      assert.ok(identifyRead(c.toolName, c.input, root));
      if (!h.emit("tool_call", c)?.block) {
        h.emit("tool_result", c); executed++;
      }
    }
    assert.equal(executed, 6);
    assert.equal(h.messages.length, 1);
    assert.equal(h.messages[0].display, true);
    assert.equal(h.messages[0].options.triggerTurn, false);
    assert.equal(h.messages[0].customType, NOTICE_TYPE);
    assert.doesNotMatch(JSON.stringify(h.writes), /command|sanitized-result|fixture-result/);
  }
});

check("only completed successful identical results count; fourth is vetoed and run aborted", () => {
  const h = harness();
  for (let i = 0; i < 3; i++) assert.equal(h.complete(), undefined);
  const fourth = h.emit("tool_call", h.call());
  assert.equal(fourth.block, true);
  assert.equal(h.aborts, 1);
  assert.match(fourth.reason, /next call was blocked before execution/);
  assert.doesNotMatch(fourth.reason, /README|sanitized stable output/);
  assert.equal(h.messages.length, 1);
});

check("same-batch duplicate veto never fabricates a completed success or abort", () => {
  const h = harness(); const first = h.call();
  assert.equal(h.emit("tool_call", first), undefined);
  assert.match(h.emit("tool_call", h.call()).reason, /already pending/);
  assert.equal(h.aborts, 0);
  h.emit("tool_result", h.result(first));
  assert.equal(h.complete(), undefined);
  assert.equal(h.complete(), undefined);
  assert.equal(h.complete().block, true);
});

check("backlog line slicing with cut blocks the fourth identical read", () => {
  const command = `echo "first excerpt"; sed -n '17,18p' ${root}/data/backlog.md | cut -c1-500; echo "second excerpt"; sed -n '232,235p' ${root}/data/backlog.md | cut -c1-500`;
  const h = harness();
  for (let i = 0; i < 3; i++) assert.equal(h.complete({ command }), undefined);
  assert.equal(h.complete({ command }).block, true);
  for (const bad of ["cut -c1-500 > output", "cut -c1-500; touch output", "cut --output=bad"]) {
    assert.equal(identifyRead("bash", { command: bad }, root), undefined);
  }
});

check("observed outer read groups and multiline pipelines stop before a fourth execution", () => {
  for (const command of [
    `(cd /fixture && echo "first excerpt"; sed -n '17,18p' data/backlog.md | nl -ba; echo "second excerpt"; sed -n '232,235p' data/backlog.md | cut -c1-500)`,
    `(cd /fixture\necho counts\nsed -n '17,18p' data/backlog.md | wc -l\necho bytes\nsed -n '232,235p' data/backlog.md | head -c 500 | tail -c 80 | od -An -tx1c\n)`,
    `(cd /fixture &&\n echo excerpt;\n sed -n '1,20p' README.md |\n nl -ba\n)`,
    "(cd /fixture && \\\n echo excerpt; \\\n sed -n '1,20p' README.md | \\\n nl -ba)",
  ]) {
    assert.ok(identifyRead("bash", { command }, root), command);
    const h = harness();
    let executions = 0;
    for (let i = 0; i < 344; i++) {
      const c = h.call({ command });
      const veto = h.emit("tool_call", c);
      if (!veto?.block) { h.emit("tool_result", h.result(c)); executions++; }
    }
    assert.equal(executions, 3);
    assert.equal(h.messages.length, 1);
  }
});

for (const command of [
  `(cat file${String.fromCharCode(92, 10)})`,
  `(cat file;${String.fromCharCode(92, 10)})`,
  `(cat file${String.fromCharCode(92, 10)} )`,
  `(cat file${String.fromCharCode(92, 10)}\n)`,
]) {
  check(`terminal continuation stops repeated read ${JSON.stringify(command)}`, () => {
    const h = harness();
    let executions = 0;
    for (let i = 0; i < 344; i++) {
      const c = h.call({ command });
      if (!h.emit("tool_call", c)?.block) { h.emit("tool_result", h.result(c)); executions++; }
    }
    assert.equal(executions, 3);
    assert.equal(h.messages.length, 1);
    assert.ok(identifyRead("bash", { command }, root));
  });
}

check("group recognition refuses mutation, redirection, nested shells and unknown filter options", () => {
  for (const command of [
    `(cd /fixture && cat file; touch changed)`, `(cd /fixture\nrm file\ncat file)`,
    `(cat file > output)`, `(cat file 2> errors)`, `(cat file >> output)`, `(cat < file)`,
    `(cat file | tee output)`, `(cat file | unknown)`, `(cat file | nl --unrecognized)`,
    `(cat file | wc --files0-from=other)`, `(cat file | od --unrecognized)`,
    `(cat file; (cat other))`, `{ cat file; }`, `((cat file))`, `(cat file) ; touch other`,
    `(echo $(cat file))`, `(cat file & cat other)`, `(cat file || cat other)`,
    `(cat file\necho 'unclosed)`, `(cat file\n# concealed stage\ntouch other)`,
    `(cat file 2>&1\ntouch changed)`,
    "(cat file; \\\n touch changed)", "(cat file | \\\n tee output)",
    "(cat file >\\\n output)", "(to\\\nuch changed; cat file)",
    ...["touch changed", "cat file > output", "cat file | unknown", "cat file | nl --unknown",
      "cat file; (cat other)", "echo $(cat file)"].map((body) => `(${body}${String.fromCharCode(92, 10)})`),
  ]) {
    assert.equal(identifyRead("bash", { command }, root), undefined, command);
    const h = harness();
    for (let i = 0; i < 6; i++) assert.equal(h.complete({ command }), undefined);
    assert.equal(h.aborts, 0);
    assert.equal(h.messages.length, 0);
    assert.equal(h.writes.filter((e) => e.customType === HISTORY_TYPE).length, 0);
  }
});

check("changes, errors, exit failures, empty results and volatile details", () => {
  const h = harness();
  for (let i = 0; i < 8; i++) assert.equal(h.complete(input, `changed ${i}`), undefined);
  h.complete(input, "same"); h.complete(input, "same");
  h.complete(input, "same", { isError: true });
  assert.equal(h.complete(input, "same"), undefined);
  h.complete(input, "same", { details: { exitCode: 1 } });
  assert.equal(h.complete(input, "same"), undefined);
  h.complete(input, "same", { structuredContent: { exit_code: 2, output: "same" } });
  for (let i = 0; i < 3; i++) assert.equal(h.complete(input, "", { details: { fullOutputPath: `/tmp/fake-${i}` } }), undefined);
  assert.equal(h.complete(input, "").block, true);
  const s = harness();
  for (let i = 0; i < 8; i++) assert.equal(s.complete(input, "", { structuredContent: { output: `different-${i}`, wall_time_seconds: i } }), undefined);
});

check("operational inputs, fresh turns and compaction cannot reset the budget", () => {
  const h = harness();
  for (let i = 0; i < 3; i++) h.complete();
  for (const [source, text] of [
    ["extension", "unmarked automatic followup"],
    [undefined, "adapter input without provenance"],
    ["rpc", "\u2063FIRSTMATE_OP: v1 watcher: heartbeat"],
    ["rpc", "\u2063FIRSTMATE_OP: watcher wake"],
    ["interactive", "\u2063FIRSTMATE_OP: v2 future-producer: followup"],
    ["interactive", "\u2063FIRSTMATE_OP: v1 branch-outcome: ready"],
    ["rpc", "\u2063Supervisor escalate (test): review"],
    ["extension", "\u2063FIRSTMATE_OP: v1 session-start: digest"],
  ]) h.emit("input", { source, text });
  h.emit("agent_start"); h.emit("session_compact"); h.emit("session_start");
  assert.equal(h.complete().block, true);
  h.emit("agent_start");
  assert.equal(h.aborts, 2);
  assert.equal(h.messages.length, 1);
});

check("genuine interactive and RPC input resets, including an image; in-flight old results cannot count", () => {
  for (const source of ["interactive", "rpc"]) {
    const h = harness(); for (let i = 0; i < 3; i++) h.complete();
    h.complete();
    h.emit("input", { source, text: "Read it again now" });
    for (let i = 0; i < 3; i++) assert.equal(h.complete(), undefined);
    assert.equal(h.complete().block, true);
    h.emit("input", { source, text: "", images: [{ type: "image" }] });
    assert.equal(h.complete(), undefined);
    const c = h.call({ command: `cat ${root}/AGENTS.md` }); h.emit("tool_call", c);
    h.emit("input", { source, text: "New request" });
    h.emit("tool_result", h.result(c));
    assert.equal(h.writes.at(-1).data.rows.length, 0);
  }
});

check("bounded history expires, but a tripped latch requires real user input", () => {
  let clock = 1000; const h = harness({ now: () => clock });
  h.complete(); h.complete(); clock += WINDOW_MS + 1;
  for (let i = 0; i < 3; i++) assert.equal(h.complete(), undefined);
  assert.equal(h.complete().block, true);
  clock += WINDOW_MS + 1;
  assert.equal(h.complete().block, true);
});

check("reload/resume restore durable hashes, including a tripped latch", () => {
  const entries: any[] = []; const a = harness({ entries });
  for (let i = 0; i < 3; i++) a.complete();
  entries.push({ type: "compaction", summary: "content intentionally unavailable" });
  const b = harness({ entries });
  b.emit("session_start");
  assert.equal(b.complete().block, true);
  const c = harness({ entries }); c.emit("agent_start");
  assert.equal(c.aborts, 1); assert.equal(c.messages.length, 0);
  c.emit("input", { source: "rpc", text: "Continue deliberately" });
  assert.equal(c.complete(), undefined);
});

check("result IDs deduplicate and unknown adapter events never invent success", () => {
  const h = harness(); const c = h.call();
  h.emit("tool_call", c); h.emit("tool_result", h.result(c));
  h.emit("tool_result", h.result(c));
  h.emit("tool_execution_end", h.result(c)); // Some adapters only report this: insufficient evidence.
  assert.equal(h.writes.at(-1).data.rows[0].times.length, 1);
  const missing = h.call(); h.emit("tool_call", missing);
  h.emit("tool_result", h.result(missing, "same", { isError: undefined }));
  assert.equal(h.writes.at(-1).data.rows[0].times.length, 1);
  assert.equal(h.complete(), undefined); assert.equal(h.complete(), undefined);
  assert.equal(h.complete().block, true);
});

check("known read commands count; mutation, unknown syntax, and bounded polling stay uncounted", () => {
  for (const command of [ssh, ...captured.flatMap((c: any) => c.calls.slice(0, 2).map((x: any) => x.input.command)),
    `sleep 1; cat ${root}/README.md`]) {
    assert.ok(identifyRead("bash", { command }, root));
    const h = harness(); for (let i = 0; i < 3; i++) h.complete({ command });
    assert.equal(h.complete({ command }).block, true);
  }
  for (const command of [
    "echo $(touch /tmp/MUST-NOT-EXECUTE)", "echo `touch /tmp/MUST-NOT-EXECUTE`", "eval 'cat x'",
    "python3 -c 'print(1)'", "sh -c 'cat x'", "cat x > output", "cat <(touch x)",
    "cat x || cat y", "cat x &", "sed -i 's/a/b/' x", "sed -n '1e touch x' x", "tail -f x",
    "{ cat x; cat y; }", "cat x\ncat y",
    "git diff --stat --output=bad", "FM_HOME=/tmp sh -c 'cat x'", "ssh fixture-host 'cat x'",
    ssh.replace("git diff --stat", "git reset --hard"), ssh.replace("echo summary", "touch summary"),
    ssh.replace("git diff --stat", "git -c core.sshCommand=bad diff --stat"),
    `timeout 30s gh-axi pr checks 123 --watch --interval 5`,
    `sleep 1; touch /tmp/MUST-NOT-EXECUTE`,
  ]) {
    assert.equal(identifyRead("bash", { command }, root), undefined);
    const h = harness(); for (let i = 0; i < 6; i++) assert.equal(h.complete({ command }), undefined);
    assert.equal(h.aborts, 0);
  }
  const poll = harness();
  for (let i = 0; i < 6; i++) assert.equal(poll.complete({ timeout: 30 }, "unchanged", {}, "bounded_poll"), undefined);
});

check("normal native reads are independent and argument order does not create a new budget", () => {
  const h = harness();
  for (let i = 0; i < 3; i++) assert.equal(h.complete({ path: "file", offset: 1, limit: 20 }, "same", {}, "read"), undefined);
  assert.equal(h.complete({ path: "file", offset: 21, limit: 20 }, "same", {}, "read"), undefined);
  assert.equal(h.complete({ limit: 20, offset: 1, path: "file" }, "same", {}, "read").block, true);
});

check("primary ownership requires exact root, primary PID marker, session namespace and lock ancestry", () => {
  const encoded = `--${root.slice(1).replaceAll("/", "-")}--`;
  const ctx: any = { cwd: root, sessionManager: { getCwd: () => root, getSessionDir: () => `/private-agent/sessions/${encoded}` } };
  const files: Record<string, string> = {
    "/private-state/.lock": "400\n", "/private-state/.pi-turnend-extension-loaded": "sha256:test\n500\n",
    "/proc/500/status": "Name:\tpi\nPPid:\t400\n",
  };
  const opts = { root, home: root, platform: "linux" as const, state: "/private-state", agentDir: "/private-agent", pid: 500, env: {}, parentPid: (pid: number) => pid === 500 ? 400 : 1, read: (path: string) => {
    if (!(path in files)) throw new Error("absent fixture"); return files[path];
  } };
  assert.equal(primaryOwnsContext(ctx, opts), true);
  for (const platform of ["darwin", "win32"] as const) assert.equal(primaryOwnsContext(ctx, { ...opts, platform }), false);
  for (const env of [{ FM_TASK_ID: "worker" }, { FM_TASK_INBOX: "worker-inbox" }, { FM_SUPERVISION_ACTOR: "branch" }])
    assert.equal(primaryOwnsContext(ctx, { ...opts, env }), false);
  assert.equal(primaryOwnsContext(ctx, { ...opts, pid: 600 }), false); // nested Pi probe
  assert.equal(primaryOwnsContext(ctx, { ...opts, home: "/tmp" }), false); // secondmate
  assert.equal(primaryOwnsContext({ ...ctx, cwd: "/tmp" }, opts), false);
  assert.equal(primaryOwnsContext({ ...ctx, sessionManager: { ...ctx.sessionManager, getSessionDir: () => `${root}/state/branch-session` } }, opts), false);
  files["/private-state/.lock"] = "999\n";
  assert.equal(primaryOwnsContext(ctx, opts), false);
  delete files["/private-state/.lock"];
  assert.equal(primaryOwnsContext(ctx, opts), false);
  const foreign = harness({ owned: false });
  for (let i = 0; i < 6; i++) foreign.complete();
  foreign.emit("input", { source: "interactive", text: "new" });
  assert.equal(foreign.writes.length, 0); assert.equal(foreign.aborts, 0);
});

check("state memory and persisted payload are bounded and contain only hashes/labels", () => {
  const guard = new ReadRepetition(root, Date.now, readLimits({ enabled: true }));
  for (let i = 0; i < 1000; i++) {
    const args = { path: `private-name-${i}` };
    guard.before(`id-${i}`, "read", args);
    guard.complete({ toolCallId: `id-${i}`, toolName: "read", input: args, isError: false, content: [{ type: "text", text: "secret output" }] });
  }
  const snapshot = guard.snapshot();
  assert.equal(snapshot.rows.length, 128); assert.equal(snapshot.ids.length, 512);
  assert.doesNotMatch(JSON.stringify(snapshot), /private-name|secret output/);
  assert.equal(HISTORY_TYPE, "fm-read-repetition-state-v1");
});

check("fresh captain reset survives temporary missing or stale ownership", () => {
  for (const missing of ["missing-lock", "stale-pid"]) {
    const original = harness();
    for (let i = 0; i < 4; i++) original.complete();
    let owned = false;
    const resumed = harness({ entries: [...original.entries], owned: () => owned });
    resumed.emit("session_start");
    resumed.emit("input", { source: "rpc", text: `Continue after ${missing}` });
    assert.equal(resumed.writes.length, 0);
    owned = true;
    resumed.emit("agent_start");
    assert.equal(resumed.aborts, 0);
    for (let i = 0; i < 3; i++) assert.equal(resumed.complete(), undefined);
    assert.equal(resumed.complete().block, true);
  }
});
check("operational input cannot defer a reset until ownership returns", () => {
  const original = harness(); for (let i = 0; i < 4; i++) original.complete();
  let owned = false;
  const resumed = harness({ entries: [...original.entries], owned: () => owned });
  resumed.emit("input", { source: "rpc", text: "\u2063FIRSTMATE_OP: v1 watcher: heartbeat" });
  owned = true; resumed.emit("agent_start");
  assert.equal(resumed.aborts, 1);
});

check("foreign session input cannot defer a reset until ownership returns", () => {
  const original = harness(); for (let i = 0; i < 4; i++) original.complete();
  let owned = false;
  const resumed = harness({ entries: [...original.entries], owned: () => owned, acceptsInput: false });
  resumed.emit("input", { source: "rpc", text: "Continue" });
  owned = true; resumed.emit("agent_start");
  assert.equal(resumed.aborts, 1);
});

check("results received during ownership loss retire pending reads without counting or clearing history", () => {
  let owned = true;
  const h = harness({ owned: () => owned });
  h.complete();
  const c = h.call();
  assert.equal(h.emit("tool_call", c), undefined);
  owned = false;
  const writes = h.writes.length;
  h.emit("tool_result", h.result(c));
  assert.equal(h.writes.length, writes);
  assert.equal(h.aborts, 0);
  owned = true;
  assert.equal(h.complete(), undefined);
  assert.equal(h.complete(), undefined);
  assert.equal(h.complete().block, true); // Previous owned success was retained.
});

check("bounded operator configuration rejects invalid and unknown settings", () => {
  assert.deepEqual(readLimits(), DEFAULT_LIMITS);
  assert.equal(readLimits().enabled, false);
  assert.equal(readLimits({ repeatLimit: 8 }).enabled, false);
  assert.deepEqual(readLimits({ repeatLimit: 8 }), { ...DEFAULT_LIMITS, repeatLimit: 8 });
  for (const value of [null, [], true, { extra: 1 }, { repeatLimit: 1 }, { repeatLimit: 33 },
    { repeatLimit: 2.5 }, { repeatLimit: "3" }, { windowMs: 0 }, { windowMs: 86_400_001 }, { enabled: "false" }]) {
    assert.throws(() => readLimits(value), /read-repetition.json/);
  }
});

check("missing/default/disabled configuration registers no interception handlers", () => {
  // Pin an explicitly absent private config even if the invoking operator has
  // enabled the guard. Never read source-tree or inherited home configuration.
  const handlers: string[] = [];
  const config = mkdtempSync(`${tmpdir()}/fm-read-default-`);
  const previous = process.env.FM_CONFIG_OVERRIDE;
  try {
    process.env.FM_CONFIG_OVERRIDE = config;
    managedGuard({ on(name: string) { handlers.push(name); } } as any);
  } finally {
    if (previous === undefined) delete process.env.FM_CONFIG_OVERRIDE;
    else process.env.FM_CONFIG_OVERRIDE = previous;
    rmSync(config, { recursive: true, force: true });
  }
  assert.deepEqual(handlers, []);
  for (const limits of [DEFAULT_LIMITS, readLimits({}), readLimits({ enabled: false })]) {
    const h = harness({ limits });
    for (let i = 0; i < 8; i++) h.complete();
    assert.equal(h.writes.length, 0);
    assert.equal(h.aborts, 0);
  }
});

check("load diagnostics refuse legacy collisions and unsupported activation without touching source/config", () => {
  const dir = mkdtempSync(`${tmpdir()}/fm-read-config-`);
  const config = `${dir}/config/read-repetition.json`;
  const legacy = `${dir}/.pi/extensions/fm-read-repetition-guard.ts`;
  try {
    mkdirSync(`${dir}/config`, { recursive: true });
    mkdirSync(`${dir}/.pi/extensions`, { recursive: true });
    assert.equal(loadReadRepetitionLimits(dir, config).enabled, false);
    writeFileSync(config, '{}');
    assert.equal(loadReadRepetitionLimits(dir, config).enabled, false);
    writeFileSync(config, '{"enabled":true}');
    assert.equal(loadReadRepetitionLimits(dir, config, "linux").enabled, true);
    for (const platform of ["darwin", "win32"] as const) {
      assert.throws(() => loadReadRepetitionLimits(dir, config, platform), /supports Linux Pi only/);
    }
    writeFileSync(legacy, 'private workaround bytes');
    assert.throws(() => loadReadRepetitionLimits(dir, config, "linux"), /Legacy.*move its entrypoint outside/);
    assert.equal(readFileSync(legacy, 'utf8'), 'private workaround bytes');
    assert.equal(readFileSync(config, 'utf8'), '{"enabled":true}');
    rmSync(legacy);
    symlinkSync(`${dir}/missing-target`, legacy);
    assert.throws(() => loadReadRepetitionLimits(dir, config, "linux"), /Legacy/);
    rmSync(legacy);
    // Deliberate migration removes only the legacy autoload entrypoint.
    assert.equal(loadReadRepetitionLimits(dir, config, "linux").enabled, true);
    for (const text of ['{', '{"enabled":"true"}', '{"enabled":true,"unknown":1}']) {
      writeFileSync(config, text);
      assert.throws(() => loadReadRepetitionLimits(dir, config), /Cannot load read-repetition.json/);
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

check("truncated Bash footers cannot disguise unchanged successful output", () => {
  for (const footer of ["Showing lines 2001-4000 of 4000.",
    "Showing lines 2-5 of 5 (50KB limit).", "Showing last 50KB of line 1 (line is 100KB)."] ) {
    const h = harness();
    for (let i = 0; i < 3; i++) {
      const path = `/tmp/fixture-output-${i}.log`;
      assert.equal(h.complete(input, `stable tail\n\n[${footer} Full output: ${path}]`, {
        details: { fullOutputPath: path, truncation: { truncated: true } },
        structuredContent: { output: "stable prefix", full_output_path: path },
      }), undefined);
    }
    assert.equal(h.complete().block, true);
  }
  // A similarly shaped path is real output unless SDK truncation evidence
  // and the matching terminal footer agree.
  const h = harness();
  for (let i = 0; i < 8; i++) assert.equal(h.complete(input,
    `real output changed\n\n[Showing lines 1-2 of 2. Full output: /tmp/fixture-${i}]`,
    { details: { fullOutputPath: `/tmp/fixture-${i}`, truncation: { truncated: false } } }), undefined);
});

check("stopped primary vetoes compaction without affecting another owner", () => {
  const h = harness();
  assert.equal(h.emit("session_before_compact"), undefined);
  for (let i = 0; i < 4; i++) h.complete();
  for (const reason of ["threshold", "overflow", "manual"]) {
    assert.deepEqual(h.emit("session_before_compact", { reason }), { cancel: true });
  }
  const foreign = harness({ owned: false, entries: h.entries });
  assert.equal(foreign.emit("session_before_compact"), undefined);
  h.emit("input", { source: "rpc", text: "Continue deliberately" });
  assert.equal(h.emit("session_before_compact"), undefined);
});

check("configured threshold and time window govern execution, disabled guard stays inert", () => {
  for (const repeatLimit of [2, 4, 32]) {
    let clock = 1000;
    const h = harness({ limits: readLimits({ enabled: true, repeatLimit, windowMs: 1000 }), now: () => clock });
    for (let i = 0; i < repeatLimit - 1; i++) assert.equal(h.complete(), undefined);
    clock += 1001;
    for (let i = 0; i < repeatLimit; i++) assert.equal(h.complete(), undefined);
    assert.equal(h.complete().block, true);
    assert.match(h.messages[0].content, new RegExp(`${repeatLimit} times within 1000 ms`));
  }
  const h = harness({ limits: readLimits({ enabled: false }) });
  for (let i = 0; i < 100; i++) h.complete();
  assert.equal(h.writes.length, 0);
  assert.equal(h.aborts, 0);
});

check("Linux real parent ancestry is read through ps", () => {
  const encoded = `--${root.slice(1).replaceAll("/", "-")}--`;
  const ctx: any = { cwd: root, sessionManager: {
    getCwd: () => root, getSessionDir: () => `/fixture-agent/sessions/${encoded}`,
  } };
  const options = { root, home: root, state: "/fixture-state", agentDir: "/fixture-agent", pid: process.pid, env: {},
    read: (path: string) => path.endsWith(".lock") ? `${process.ppid}` : `sha256:fixture\n${process.pid}\n`,
  };
  assert.equal(primaryOwnsContext(ctx, options), true);
  for (const env of [{ FM_TASK_ID: "worker" }, { FM_TASK_INBOX: "worker" }, { FM_SUPERVISION_ACTOR: "branch" }]) {
    assert.equal(primaryOwnsContext(ctx, { ...options, env }), false);
  }
  assert.equal(primaryOwnsContext(ctx, { ...options, read: () => "" }), false);
}, process.platform === "linux");
check("numbered backlog excerpts stop before fourth identical read", () => {
  const command = `(cd /fixture && sed -n '180,230p' BACKLOG.md | nl -ba -v180)`;
  assert.ok(identifyRead("bash", {command}, root));
  const h=harness();for(let i=0;i<3;i++)assert.equal(h.complete({command}),undefined);
  assert.equal(h.complete({command}).block,true);assert.equal(h.aborts,1);
});
check("grouped byte excerpts stop before fourth identical read", () => {
  const command = `(cd /fixture\necho excerpt\nsed -n '61p' fixture.jsonl | od -An -c | head -40\n)`;
  assert.ok(identifyRead("bash", {command}, root));
  const h=harness();for(let i=0;i<3;i++)assert.equal(h.complete({command}),undefined);
  assert.equal(h.complete({command}).block,true);assert.equal(h.aborts,1);
});
check("excerpt additions do not recognize writes, substitutions or unknown flags", () => {
 for(const command of [
  'nl -ba -v180 FILE > output', 'od -An -c FILE; rm FILE',
  'nl -ba -v180 FILE | sh', 'od -An -c "$(touch output)"',
  'nl -ba -v180 FILE | sed -i s/a/b/ FILE', 'nl -ba -vbanana FILE',
  'od --output=FILE', '(od -An -c FILE; (cat OTHER))'
 ])assert.equal(identifyRead("bash",{command},root),undefined,command);
});

TS
); then
  printf '%s\n' "$policy_results" >&2
  fail 'read-repetition policy assertions failed'
fi
while IFS=$'\t' read -r result name; do
  case "$result" in
    pass) pass "$name" ;;
    skip) printf 'skip: %s (Linux only)\n' "$name" ;;
    *) fail "unexpected policy assertion result: $result $name" ;;
  esac
done <<< "$policy_results"

# Exercise the OLD updater's ordinary Git fast-forward. Managed paths must
# leave the existing ignored workaround and private config byte-for-byte intact.
TMP_ROOT=$(fm_test_tmproot fm-read-update)
fm_git_identity fmtest fmtest@example.com
fm_git_init_commit "$TMP_ROOT/repo"
mkdir -p "$TMP_ROOT/repo/.pi/extensions/lib" "$TMP_ROOT/repo/config"
printf '.pi/\nconfig/\n' > "$TMP_ROOT/repo/.git/info/exclude"
printf 'legacy guard\n' > "$TMP_ROOT/repo/.pi/extensions/fm-read-repetition-guard.ts"
printf 'legacy policy\n' > "$TMP_ROOT/repo/.pi/extensions/lib/fm-read-repetition.ts"
printf '{"enabled":true}\n' > "$TMP_ROOT/repo/config/read-repetition.json"
base=$(git -C "$TMP_ROOT/repo" rev-parse HEAD)
git -C "$TMP_ROOT/repo" checkout -qb managed
cp "$ROOT/.pi/extensions/fm-primary-read-repetition.ts" "$TMP_ROOT/repo/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-primary-read-repetition-policy.ts" "$TMP_ROOT/repo/.pi/extensions/lib/"
git -C "$TMP_ROOT/repo" add -f .pi/extensions/fm-primary-read-repetition.ts .pi/extensions/lib/fm-primary-read-repetition-policy.ts
git -C "$TMP_ROOT/repo" commit -qm 'managed fixture'
git -C "$TMP_ROOT/repo" checkout -q --detach "$base"
git -C "$TMP_ROOT/repo" merge --ff-only managed >/dev/null
[ "$(cat "$TMP_ROOT/repo/.pi/extensions/fm-read-repetition-guard.ts")" = 'legacy guard' ] || fail 'ignored guard changed'
[ "$(cat "$TMP_ROOT/repo/.pi/extensions/lib/fm-read-repetition.ts")" = 'legacy policy' ] || fail 'ignored helper changed'
[ "$(cat "$TMP_ROOT/repo/config/read-repetition.json")" = '{"enabled":true}' ] || fail 'private configuration changed'
test -f "$TMP_ROOT/repo/.pi/extensions/fm-primary-read-repetition.ts"
pass 'pre-feature fast-forward preserves ignored legacy guard/helper and configuration'
