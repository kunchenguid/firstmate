#!/usr/bin/env bash
# Regression tests for the Pi Luna compaction extension without live model calls.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-luna-compaction)
EXT="$ROOT/.pi/extensions/fm-luna-compaction.ts"

run_cases() {
  local fixture out output_file status
  fixture="$TMP_ROOT/fixture"
  mkdir -p "$fixture/.pi/extensions" "$fixture/node_modules/@earendil-works/pi-coding-agent" "$fixture/node_modules/@earendil-works/pi-ai"
  cp "$EXT" "$fixture/.pi/extensions/fm-luna-compaction.ts"
  printf '%s\n' '{"type":"module"}' >"$fixture/package.json"
  cat >"$fixture/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat >"$fixture/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function convertToLlm(messages) { return messages; }
export function serializeConversation(messages) {
  return messages.map((message) => typeof message.content === "string" ? message.content : JSON.stringify(message.content)).join("\n");
}
export async function compact(...args) { return globalThis.__compact(...args); }
JS
  cat >"$fixture/node_modules/@earendil-works/pi-ai/package.json" <<'JSON'
{"name":"@earendil-works/pi-ai","type":"module","exports":"./index.js"}
JSON
  : >"$fixture/node_modules/@earendil-works/pi-ai/index.js"

  output_file="$fixture/output"
  (cd "$fixture" && node --input-type=module) >"$output_file" 2>&1 <<'JS'
import { pathToFileURL } from "node:url";

const extension = await import(`${pathToFileURL(".pi/extensions/fm-luna-compaction.ts").href}?test=${Date.now()}`);
let handler;
extension.default({ on(name, next) { if (name === "session_before_compact") handler = next; } });
if (!handler) throw new Error("compaction handler was not registered");

const usage = { input: 1000, output: 100, cacheRead: 0, cacheWrite: 0, totalTokens: 1100, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const details = { readFiles: ["src/a.ts"], modifiedFiles: ["src/b.ts"] };
const historySummary = () => "## Goal\nGoal\n## Constraints & Preferences\n- none\n## Progress\n### Done\n- [x] done\n### In Progress\n- [ ] work\n### Blocked\n- none\n## Key Decisions\n- **Decision**: why\n## Next Steps\n1. next\n## Critical Context\n- context";
function fileSuffix(nextDetails) {
  const sections = [];
  if (nextDetails.readFiles.length) sections.push(`<read-files>\n${nextDetails.readFiles.join("\n")}\n</read-files>`);
  if (nextDetails.modifiedFiles.length) sections.push(`<modified-files>\n${nextDetails.modifiedFiles.join("\n")}\n</modified-files>`);
  return sections.length ? `\n\n${sections.join("\n\n")}` : "";
}
const valid = (nextDetails = details) => `${historySummary()}${fileSuffix(nextDetails)}`;
const malformed = "## Goal\nmissing the native summary structure";
const models = {
  luna: { provider: "openai-codex", id: "gpt-5.6-luna", contextWindow: 272000, maxTokens: 128000, reasoning: true },
  terra: { provider: "openai-codex", id: "gpt-5.6-terra", contextWindow: 272000, maxTokens: 128000, reasoning: true },
};
function preparation(overrides = {}) {
  return {
    firstKeptEntryId: "kept",
    messagesToSummarize: [{ role: "user", content: "x".repeat(2000) }],
    turnPrefixMessages: [],
    isSplitTurn: false,
    tokensBefore: 999,
    fileOps: { read: new Set(["src/a.ts"]), written: new Set(), edited: new Set(["src/b.ts"]) },
    settings: { enabled: true, reserveTokens: 16384, keepRecentTokens: 20000 },
    ...overrides,
  };
}
// `null` models a session where Pi reports no conversation model, which is distinct from
// omitting the argument and taking the same-window default.
function context(prep, conversationModel = { ...models.terra }) {
  const notifications = [];
  return {
    model: conversationModel === null ? undefined : conversationModel,
    notifications,
    ui: { notify(message, type) { notifications.push({ message, type }); } },
    modelRegistry: {
      find(_provider, id) { return id === models.luna.id ? models.luna : id === models.terra.id ? models.terra : undefined; },
      async getApiKeyAndHeaders() { return { ok: true, apiKey: "test", headers: { "x-test": "yes" }, env: { TEST: "1" } }; },
    },
  };
}
async function invoke({ prep = preparation(), plan, signal = new AbortController().signal, conversationModel } = {}) {
  const calls = [];
  const ctx = context(prep, conversationModel);
  globalThis.__compact = async (actualPrep, model, apiKey, headers, instructions, actualSignal, thinking, stream, env) => {
    calls.push({ model, actualPrep, apiKey, headers, instructions, actualSignal, thinking, stream, env });
    const next = plan[model.id];
    if (next instanceof Error) throw next;
    return next;
  };
  try {
    return { result: await handler({ preparation: prep, customInstructions: "focus", signal }, ctx), calls, notifications: ctx.notifications };
  } catch (error) {
    return { error, calls, notifications: ctx.notifications };
  }
}
function result(summary = valid(), nextUsage = usage, nextDetails = details, tokensBefore = 999) {
  return { summary, firstKeptEntryId: "kept", tokensBefore, usage: nextUsage, details: nextDetails };
}

// Luna is the only nested model selected on a safe result. The session model is read-only.
{
  const original = { ...models.terra, id: "captain-selected-model" };
  const run = await invoke({ conversationModel: original, plan: { [models.luna.id]: result() } });
  if (run.error || run.calls.map((call) => call.model.id).join() !== models.luna.id) throw new Error("safe Luna compaction did not select Luna exactly once");
  if (run.result.compaction.usage !== usage || run.result.compaction.details !== details) throw new Error("native usage or details were not preserved");
  if (run.calls[0].instructions !== "focus" || run.calls[0].thinking !== undefined || run.calls[0].stream !== undefined || run.calls[0].env.TEST !== "1") throw new Error("native compaction arguments were not preserved");
  if (original.id !== "captain-selected-model") throw new Error("the conversation model was changed");
}

// Pi's optional file sections are accepted only when both details and summary match prepared operations.
for (const [name, fileOps, nextDetails] of [
  ["no files", { read: new Set(), written: new Set(), edited: new Set() }, { readFiles: [], modifiedFiles: [] }],
  ["read only", { read: new Set(["read.ts"]), written: new Set(), edited: new Set() }, { readFiles: ["read.ts"], modifiedFiles: [] }],
  ["modified only", { read: new Set(), written: new Set(["written.ts"]), edited: new Set() }, { readFiles: [], modifiedFiles: ["written.ts"] }],
]) {
  const prep = preparation({ fileOps });
  const run = await invoke({ prep, plan: { [models.luna.id]: result(valid(nextDetails), usage, nextDetails) } });
  if (run.error || run.calls.length !== 1 || !run.result.compaction) throw new Error(`${name} native file tracking was rejected`);
}

// Luna's smaller envelope never receives a request; Terra gets the one fallback attempt.
{
  models.luna.contextWindow = 1000;
  const run = await invoke({ conversationModel: { ...models.terra, contextWindow: 1000 }, plan: { [models.terra.id]: result() } });
  models.luna.contextWindow = 272000;
  if (run.error || run.calls.map((call) => call.model.id).join() !== models.terra.id) throw new Error("oversize Luna preflight did not use only Terra");
}

for (const [name, luna] of [
  ["malformed", result(malformed)],
  ["reordered", result(valid().replace("## Goal\nGoal\n", "").replace("## Critical Context\n- context", "## Critical Context\n- context\n## Goal\nGoal"))],
  ["empty section", result(valid().replace("## Next Steps\n1. next", "## Next Steps\n"))],
  ["wrong file details", result(valid(), usage, { readFiles: [], modifiedFiles: [] })],
  ["visible truncation", result(`${valid()}\n- unfinished...`)],
  ["output-limit truncation", result(valid(), { ...usage, output: 13000 })],
  ["partial usage", result(valid(), { ...usage, input: 10 })],
  ["nested failure", new Error("provider failed")],
]) {
  const run = await invoke({ plan: { [models.luna.id]: luna, [models.terra.id]: result() } });
  if (run.error || run.calls.map((call) => call.model.id).join() !== "gpt-5.6-luna,gpt-5.6-terra") throw new Error(`${name} did not fall back to Terra exactly once`);
}

// Cached prompt tokens count as received input and do not trigger a false partial-result fallback.
{
  const cachedUsage = { ...usage, input: 10, cacheRead: 200, cacheWrite: 790 };
  const run = await invoke({ plan: { [models.luna.id]: result(valid(), cachedUsage) } });
  if (run.error || run.calls.length !== 1 || run.calls[0].model.id !== models.luna.id) throw new Error("complete cached input was treated as partial");
}

// Multibyte input is measured by UTF-8 length, not UTF-16 code units. 2000 emoji are 8000 UTF-8
// bytes but 4000 code units, so the window below is one a code-unit measure would wrongly accept.
{
  const dense = preparation({ messagesToSummarize: [{ role: "user", content: "😀".repeat(2000) }] });
  models.luna.contextWindow = 16500;
  const run = await invoke({ prep: dense, conversationModel: { ...models.terra, contextWindow: 16500 }, plan: { [models.terra.id]: result() } });
  models.luna.contextWindow = 272000;
  if (run.error || run.calls.map((call) => call.model.id).join() !== models.terra.id) throw new Error("multibyte input was measured by code units instead of UTF-8 bytes");
}

// A deployed-scale prose session is measured in tokens, not bytes. This is the reported failure:
// 944212 serialized bytes cost 180422 real input tokens and fit the 272000 window with room to
// spare, but a byte-denominated bound reads them as 946260 and cancels every compaction.
{
  const noFiles = { readFiles: [], modifiedFiles: [] };
  const deployed = preparation({
    isSplitTurn: true,
    messagesToSummarize: [{ role: "user", content: "x".repeat(944212) }],
    turnPrefixMessages: [{ role: "user", content: "y".repeat(3069) }],
    tokensBefore: 257005,
    fileOps: { read: new Set(), written: new Set(), edited: new Set() },
  });
  const splitSummary = `${historySummary()}\n\n---\n\n**Turn Context (split turn):**\n\n## Original Request\nrequest\n## Early Progress\n- progress\n## Context for Suffix\n- suffix`;
  const deployedUsage = { ...usage, input: 180422, output: 4000 };
  const run = await invoke({ prep: deployed, plan: { [models.luna.id]: result(splitSummary, deployedUsage, noFiles, 257005) } });
  if (run.error || run.calls.map((call) => call.model.id).join() !== models.luna.id) throw new Error("deployed-scale prose compaction was rejected by a byte-denominated envelope");
  if (run.result.compaction.summary !== splitSummary) throw new Error("deployed-scale split summary was altered");
}

// The tool-heavy shape that used to pass by coincidence still passes, and its real input cost of
// 95154 tokens against a 58386-token estimate is why a returned result is checked for saturation.
{
  const noFiles = { readFiles: [], modifiedFiles: [] };
  const toolHeavy = preparation({
    isSplitTurn: true,
    messagesToSummarize: [{ role: "user", content: "x".repeat(233542) }],
    turnPrefixMessages: [{ role: "user", content: "y".repeat(2227) }],
    tokensBefore: 258035,
    fileOps: { read: new Set(), written: new Set(), edited: new Set() },
  });
  const splitSummary = `${historySummary()}\n\n---\n\n**Turn Context (split turn):**\n\n## Original Request\nrequest\n## Early Progress\n- progress\n## Context for Suffix\n- suffix`;
  const run = await invoke({ prep: toolHeavy, plan: { [models.luna.id]: result(splitSummary, { ...usage, input: 95154, output: 4000 }, noFiles, 258035) } });
  if (run.error || run.calls.map((call) => call.model.id).join() !== models.luna.id) throw new Error("deployed-scale tool-heavy compaction regressed");
}

// A session that overshoots the earlier 239232-token trigger by 20000 tokens still fits, at the
// worst measured prose density and against the larger output budget a 32768-token reserve buys.
{
  const noFiles = { readFiles: [], modifiedFiles: [] };
  const overshoot = preparation({
    isSplitTurn: true,
    messagesToSummarize: [{ role: "user", content: "x".repeat(952420) }],
    turnPrefixMessages: [{ role: "user", content: "y".repeat(3069) }],
    tokensBefore: 259232,
    fileOps: { read: new Set(), written: new Set(), edited: new Set() },
    settings: { enabled: true, reserveTokens: 32768, keepRecentTokens: 20000 },
  });
  const splitSummary = `${historySummary()}\n\n---\n\n**Turn Context (split turn):**\n\n## Original Request\nrequest\n## Early Progress\n- progress\n## Context for Suffix\n- suffix`;
  const run = await invoke({ prep: overshoot, plan: { [models.luna.id]: result(splitSummary, { ...usage, input: 182004, output: 4000 }, noFiles, 259232) } });
  if (run.error || run.calls.map((call) => call.model.id).join() !== models.luna.id) throw new Error("realistic threshold overshoot was rejected at the configured reserve");
}

// A compaction model narrower than the session cannot hold it, however small this one request is.
// A 65536-token local model clears the absolute envelope below and is still refused.
{
  const [window, maxTokens] = [models.luna.contextWindow, models.luna.maxTokens];
  models.luna.contextWindow = 65536;
  models.luna.maxTokens = 4096;
  const run = await invoke({ plan: { [models.terra.id]: result() } });
  models.luna.contextWindow = window;
  models.luna.maxTokens = maxTokens;
  if (run.error || run.calls.map((call) => call.model.id).join() !== models.terra.id) throw new Error("a compaction model smaller than the session was used");
}

// When neither compaction model can hold the session, compaction stops instead of summarizing
// into a window too small for it, and the error names both models and the concrete reason.
{
  const run = await invoke({ conversationModel: { ...models.terra, id: "wide-model", contextWindow: 1000000 }, plan: {} });
  if (run.error || run.result?.cancel !== true || run.calls.length !== 0) throw new Error("a session wider than both compaction models was compacted anyway");
  const [notification] = run.notifications;
  if (run.notifications.length !== 1 || notification.type !== "error") throw new Error("the refusal was not surfaced as one error");
  for (const expected of ["Safe compaction failed", "Luna", "Terra", "smaller than the conversation's own model"]) {
    if (!notification.message.includes(expected)) throw new Error(`the refusal did not report ${expected}`);
  }
}

// Pi does not always report a conversation model; an unknown window uses the absolute envelope
// alone rather than cancelling every compaction.
{
  const run = await invoke({ conversationModel: null, plan: { [models.luna.id]: result() } });
  if (run.error || run.calls.map((call) => call.model.id).join() !== models.luna.id) throw new Error("an unreported conversation model blocked compaction");
}

// The estimate can understate real tokens, so a result whose reported input reaches the window
// ceiling is rejected: prepared history may have been dropped to make the request fit.
{
  const run = await invoke({ plan: { [models.luna.id]: result(valid(), { ...usage, input: 258893 }), [models.terra.id]: result() } });
  if (run.error || run.calls.map((call) => call.model.id).join() !== "gpt-5.6-luna,gpt-5.6-terra") throw new Error("a request that filled the context window was accepted");
}
{
  const run = await invoke({ plan: { [models.luna.id]: result(valid(), { ...usage, input: 200000 }) } });
  if (run.error || run.calls.map((call) => call.model.id).join() !== models.luna.id) throw new Error("a large but unsaturated request was rejected");
}

// Sparse input costs fewer real tokens than the estimate, which must not read as lost history.
// 400000 bytes estimate 100000 tokens; at 7 bytes per token the request really costs 57000.
{
  const sparse = preparation({ messagesToSummarize: [{ role: "user", content: "x".repeat(400000) }] });
  const complete = await invoke({ prep: sparse, plan: { [models.luna.id]: result(valid(), { ...usage, input: 57000 }) } });
  if (complete.error || complete.calls.map((call) => call.model.id).join() !== models.luna.id) throw new Error("sparse but complete input was treated as lost history");
  const lost = await invoke({ prep: sparse, plan: { [models.luna.id]: result(valid(), { ...usage, input: 40000 }), [models.terra.id]: result() } });
  if (lost.error || lost.calls.map((call) => call.model.id).join() !== "gpt-5.6-luna,gpt-5.6-terra") throw new Error("genuinely lost input was accepted");
}

// A rejected Luna followed by rejected Terra cancels and reports the full reason, preventing Pi's default fallback.
{
  const run = await invoke({ plan: { [models.luna.id]: result(malformed), [models.terra.id]: result(malformed) } });
  if (run.error || run.result?.cancel !== true || run.calls.length !== 2) throw new Error("double failure did not cancel compaction");
  if (run.notifications.length !== 1 || run.notifications[0].type !== "error" || !run.notifications[0].message.includes("Safe compaction failed")) throw new Error("double failure was not surfaced clearly");
}

// Cancellation is not accepted, and cannot become a successful fallback result.
{
  const controller = new AbortController();
  controller.abort();
  const run = await invoke({ signal: controller.signal, plan: { [models.luna.id]: result(), [models.terra.id]: result() } });
  if (run.error || run.result?.cancel !== true || run.calls.length !== 0 || !run.notifications[0]?.message.includes("Safe compaction failed")) throw new Error("cancelled compaction was accepted or called a model");
}

// The documented native split-turn shape is accepted without flattening it.
{
  const noFiles = { readFiles: [], modifiedFiles: [] };
  const split = preparation({ isSplitTurn: true, messagesToSummarize: [], turnPrefixMessages: [{ role: "user", content: "prefix" }], fileOps: { read: new Set(), written: new Set(), edited: new Set() } });
  const splitSummary = "No prior history.\n\n---\n\n**Turn Context (split turn):**\n\n## Original Request\nrequest\n## Early Progress\n- progress\n## Context for Suffix\n- suffix";
  const run = await invoke({ prep: split, plan: { [models.luna.id]: result(splitSummary, usage, noFiles) } });
  if (run.error || run.calls.length !== 1 || run.result.compaction.summary !== splitSummary) throw new Error("native split-turn compaction shape was altered or rejected");
}

// Split requests are preflighted independently instead of combining unrelated envelopes.
{
  const noFiles = { readFiles: [], modifiedFiles: [] };
  const split = preparation({ isSplitTurn: true, turnPrefixMessages: [{ role: "user", content: "prefix" }], fileOps: { read: new Set(), written: new Set(), edited: new Set() } });
  const splitSummary = `${historySummary()}\n\n---\n\n**Turn Context (split turn):**\n\n## Original Request\nrequest\n## Early Progress\n- progress\n## Context for Suffix\n- suffix`;
  models.luna.contextWindow = 18000;
  const run = await invoke({ prep: split, conversationModel: { ...models.terra, contextWindow: 18000 }, plan: { [models.luna.id]: result(splitSummary, usage, noFiles) } });
  models.luna.contextWindow = 272000;
  if (run.error || run.calls.length !== 1 || run.calls[0].model.id !== models.luna.id) throw new Error("independently safe split requests failed preflight");
}

// Truncation at the end of either split segment is rejected even when merged output looks complete.
{
  const noFiles = { readFiles: [], modifiedFiles: [] };
  const split = preparation({ isSplitTurn: true, turnPrefixMessages: [{ role: "user", content: "prefix" }], fileOps: { read: new Set(), written: new Set(), edited: new Set() } });
  const truncatedHistory = `${historySummary()}...\n\n---\n\n**Turn Context (split turn):**\n\n## Original Request\nrequest\n## Early Progress\n- progress\n## Context for Suffix\n- suffix`;
  const run = await invoke({ prep: split, plan: { [models.luna.id]: result(truncatedHistory, usage, noFiles), [models.terra.id]: result(`${historySummary()}\n\n---\n\n**Turn Context (split turn):**\n\n## Original Request\nrequest\n## Early Progress\n- progress\n## Context for Suffix\n- suffix`, usage, noFiles) } });
  if (run.error || run.calls.map((call) => call.model.id).join() !== "gpt-5.6-luna,gpt-5.6-terra") throw new Error("hidden split-segment truncation was accepted");
}

console.log("ok");
JS
  status=$?
  out=$(<"$output_file")
  [ "$status" -eq 0 ] || fail "Pi Luna compaction regression failed: $out"
  [ "$out" = "ok" ] || fail "Pi Luna compaction regression emitted unexpected output: $out"
  pass "Pi Luna compaction sizes requests in tokens, preserves native results, and falls back to Terra"
}

run_cases
