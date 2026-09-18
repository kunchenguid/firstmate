#!/usr/bin/env node
/**
 * fm-dispatch-jev evaluate — AI Gateway transport for typed dispatch resolution.
 *
 * Reads one JSON object from stdin: { state, questions, timeoutMs? }.
 * Calls experimental_evaluate via Vercel AI Gateway with model typesafe-ai/jev
 * (gateway.evaluationModel). Auth: AI_GATEWAY_API_KEY in this process env only
 * (parent sets it; do not load .env here).
 *
 * Prints one JSON object on stdout matching the TypeSafe systemone Choice
 * answer shape expected by bin/fm-dispatch-resolve.sh jq validation:
 *   { model, answers: { rule: { type, choice, confidence, probabilities } },
 *     usage?: { input_tokens, output_tokens } }
 *
 * Exit non-zero on failure with a short stderr message.
 */
import { experimental_evaluate as evaluate } from 'ai';
import { gateway } from '@ai-sdk/gateway';
import { resolveRuleConfidence } from './confidence.mjs';

function fail(message, code = 1) {
  process.stderr.write(`dispatch-jev: ${message}\n`);
  process.exit(code);
}

function readStdin() {
  return new Promise((resolve, reject) => {
    const chunks = [];
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (c) => chunks.push(c));
    process.stdin.on('end', () => resolve(chunks.join('')));
    process.stdin.on('error', reject);
  });
}

const raw = await readStdin();
let input;
try {
  input = JSON.parse(raw);
} catch (err) {
  fail(`stdin is not JSON: ${err.message}`);
}

if (!input || typeof input !== 'object' || Array.isArray(input)) {
  fail('stdin must be a JSON object');
}
if (!('state' in input) || !('questions' in input)) {
  fail('stdin must include state and questions');
}
if (!process.env.AI_GATEWAY_API_KEY) {
  fail('AI_GATEWAY_API_KEY is required');
}

const timeoutMs =
  typeof input.timeoutMs === 'number' && Number.isFinite(input.timeoutMs) && input.timeoutMs > 0
    ? input.timeoutMs
    : 5000;

const controller = new AbortController();
const timer = setTimeout(() => controller.abort(), timeoutMs);

let result;
try {
  result = await evaluate({
    model: gateway.evaluationModel('typesafe-ai/jev'),
    state: input.state,
    questions: input.questions,
    abortSignal: controller.signal,
  });
} catch (err) {
  clearTimeout(timer);
  const message = err?.message || String(err);
  fail(message.includes('abort') ? `timed out after ${timeoutMs} ms` : message);
}
clearTimeout(timer);

const answer = result?.answers?.rule;
if (!answer || answer.type !== 'choice' || typeof answer.choice !== 'string') {
  fail('evaluation result missing answers.rule Choice');
}

const probabilities =
  answer.probabilities && typeof answer.probabilities === 'object'
    ? answer.probabilities
    : null;
if (!probabilities) {
  fail('evaluation result missing answers.rule.probabilities');
}

const confidence = resolveRuleConfidence(answer, result?.providerMetadata);
if (typeof confidence !== 'number' || !Number.isFinite(confidence)) {
  fail('could not resolve answers.rule.confidence');
}

const out = {
  model: result?.response?.modelId || 'typesafe-ai/jev',
  answers: {
    rule: {
      type: 'choice',
      choice: answer.choice,
      confidence,
      probabilities,
    },
  },
};

const inputTokens = result?.usage?.inputTokens;
const outputTokens = result?.usage?.outputTokens;
if (typeof inputTokens === 'number' || typeof outputTokens === 'number') {
  out.usage = {
    input_tokens: typeof inputTokens === 'number' ? inputTokens : 0,
    output_tokens: typeof outputTokens === 'number' ? outputTokens : 0,
  };
}

process.stdout.write(`${JSON.stringify(out)}\n`);
