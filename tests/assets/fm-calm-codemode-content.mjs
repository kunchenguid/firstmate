/** Verify real nested execution, provider context and original session/export content. */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const fixture = process.env.CODEMODE_FIXTURE;
/** Read the complete JSONL evidence produced by the private Pi process. */
function readRecords(path) {
  return readFileSync(path, "utf8").trim().split("\n").map(line => JSON.parse(line));
}
const entries = readRecords(process.env.SESSION_FILE);
const messages = entries.filter(entry => entry.type === "message").map(entry => entry.message);
const results = messages.filter(message => message.role === "toolResult" && message.toolName === "codemode");
assert.equal(results.length, 2);
assert.equal(messages.filter(message => message.role === "toolResult").length, 3, "nested calls became transcript entries");
for (const result of results) {
  assert.match(result.content[0].text, /^Script completed/);
  assert(result.content.some(block => block.text?.includes("CODEMODE_READ_PRIVATE")));
  assert(result.content.some(block => block.text?.includes("OUTCOME_PRIVATE_RAW")));
  assert.deepEqual(result.nestedCalls.calls.map(call => call.name), ["read", "fm_branch_outcomes"]);
  assert(result.nestedCalls.complete);
  assert(result.nestedCalls.calls.every(call => call.status === "ok" && call.id.startsWith(`${result.toolCallId}/`)));
  assert.equal(result.usage.totalTokens, 13);
  assert.equal(result.usage.cost.total, 0.0002);
}
const events = readRecords(`${fixture}/events.jsonl`);
for (const result of results) {
  const nested = events.filter(event => event.parentToolCallId === result.toolCallId);
  assert.equal(nested.length, 4);
  assert.deepEqual(nested.filter(event => event.kind === "tool_execution_start").map(event => event.toolName), ["read", "fm_branch_outcomes"]);
}
const contexts = readRecords(`${fixture}/context.jsonl`);
assert.equal(contexts.length, 5, "presentation changed model request count");
for (const result of results) {
  const observed = contexts.at(-1).messages.find(message => message.role === "toolResult" && message.toolCallId === result.toolCallId);
  assert.deepEqual(observed.content, result.content, "provider context lost original script output");
}
const html = readFileSync(`${fixture}/export.html`, "utf8");
const encoded = html.match(/<script id="session-data" type="application\/json">([^<]+)<\/script>/)?.[1];
assert(encoded, "HTML export lost its original session data");
const exported = JSON.parse(Buffer.from(encoded, "base64").toString("utf8"));
const exportedEntries = exported.session?.entries ?? exported.entries;
assert.deepEqual(exportedEntries.filter(entry => entry.type === "message").map(entry => entry.message), messages);
for (const result of results) {
  const rendering = exported.renderedTools?.[result.toolCallId];
  assert(rendering?.callHtml?.includes("tools.fm_branch_outcomes"), "export lost the installed script renderer");
  assert(rendering?.resultHtmlExpanded?.includes("OUTCOME_PRIVATE_RAW"), "export lost stock nested-call/output rendering");
}
console.log("ok - repeated real Codemode calls preserve parent/child events, original output, model context, nested usage, session data and stock HTML export");
