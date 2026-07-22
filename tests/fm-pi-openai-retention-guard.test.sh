#!/usr/bin/env bash
# Regression coverage for Pi's direct-OpenAI retention opt-in.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_EXT="$ROOT/.pi/extensions/fm-openai-retention-guard.ts"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-openai-retention-guard.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
mkdir -p "$TMP_ROOT/config" "$TMP_ROOT/node_modules/@earendil-works"

command -v node >/dev/null 2>&1 || { echo "skip: node not found for Pi retention guard test"; exit 0; }
command -v npm >/dev/null 2>&1 || { echo "skip: npm not found for Pi retention guard test"; exit 0; }
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
PI_AI_DIR="$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai"
if [ ! -d "$PI_AI_DIR" ]; then
  echo "skip: installed Pi package dependencies not found"
  exit 0
fi
cp "$SOURCE_EXT" "$TMP_ROOT/fm-openai-retention-guard.ts"
ln -s "$PI_AI_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-ai"

FM_CONFIG_OVERRIDE="$TMP_ROOT/config" EXT="$TMP_ROOT/fm-openai-retention-guard.ts" node --experimental-strip-types --input-type=module <<'JS'
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const extensionPath = process.env.EXT;
if (!extensionPath) throw new Error("missing extension path");

process.env.PI_OPENAI_SERVER_COMPACTION_ENABLED = "1";
process.env.PI_OPENAI_SERVER_COMPACTION_RATIO = "0.7";
process.env.PI_OPENAI_SERVER_COMPACTION_PREVIOUS_RESPONSE_ID = "1";

const extension = await import(`${pathToFileURL(extensionPath).href}?test=${Date.now()}`);
function loadExtensionInstance() {
  const handlers = new Map();
  const providers = [];
  const pi = {
    on(name, handler) {
      const current = handlers.get(name) ?? [];
      current.push(handler);
      handlers.set(name, current);
    },
    registerProvider(name, config) {
      providers.push({ name, config });
    },
  };
  extension.default(pi);
  return { handlers, providers };
}

const { handlers, providers } = loadExtensionInstance();

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function runBeforeProviderRequest(payload, model, instanceHandlers = handlers) {
  let current = payload;
  for (const handler of instanceHandlers.get("before_provider_request") ?? []) {
    current = handler({ type: "before_provider_request", payload: current }, { model }) ?? current;
  }
  return current;
}

const packageEnv = extension.PACKAGE_PREVIOUS_RESPONSE_ID_ENV;
assert(process.env[packageEnv] === "0", "direct OpenAI retention must default off");
assert(process.env.PI_OPENAI_SERVER_COMPACTION_ENABLED === "1", "guard changed package enabled state");
assert(process.env.PI_OPENAI_SERVER_COMPACTION_RATIO === "0.7", "guard changed package threshold ratio");
for (const handler of handlers.get("session_start") ?? []) {
  handler({ type: "session_start", reason: "startup" }, {});
}
assert(providers.length === 1, "default denial did not install the final direct OpenAI transport guard");
assert(providers[0].name === "openai", "guard overrode a provider other than direct OpenAI");

const finalOptions = extension.withDirectOpenAIFinalPayloadGuard({
  async onPayload(payload) {
    return {
      ...payload,
      store: true,
      previous_response_id: "response-id",
      context_management: [{ type: "compaction", compact_threshold: 700000 }],
    };
  },
});
const finallyDenied = await finalOptions.onPayload({ model: "gpt-5.6-sol" }, {
  provider: "openai",
  api: "openai-responses",
  id: "gpt-5.6-sol",
});
assert(finallyDenied.store === false, "late package payload patch bypassed the final guard");
assert(!("previous_response_id" in finallyDenied), "late package continuation id bypassed the final guard");
assert(!("context_management" in finallyDenied), "late package context management bypassed the final guard");

const codexPayload = {
  model: "gpt-5.6-sol",
  context_management: [{ type: "compaction", compact_threshold: 700000 }],
};
const codexResult = runBeforeProviderRequest(codexPayload, {
  provider: "openai-codex",
  api: "openai-codex-responses",
  id: "gpt-5.6-sol",
});
assert(codexResult === codexPayload, "Codex payload must remain unchanged");
assert(codexResult.context_management[0].compact_threshold === 700000, "Codex threshold changed");
assert(process.env.PI_OPENAI_SERVER_COMPACTION_ENABLED === "1", "Codex compaction was disabled");

const deniedPayload = runBeforeProviderRequest({
  model: "gpt-5.6-sol",
  store: true,
  previous_response_id: "response-id",
  context_management: [{ type: "compaction", compact_threshold: 700000 }],
}, {
  provider: "openai",
  api: "openai-responses",
  id: "gpt-5.6-sol",
});
assert(deniedPayload.store === false, "direct OpenAI store:true was not denied");
assert(!("previous_response_id" in deniedPayload), "direct OpenAI continuation id was retained");
assert(!("context_management" in deniedPayload), "direct OpenAI retaining context management was retained");

const configPath = `${process.env.FM_CONFIG_OVERRIDE}/pi-direct-openai-retention`;
mkdirSync(process.env.FM_CONFIG_OVERRIDE, { recursive: true });
const rejectedOptIns = [
  ["", "empty file"],
  ["allow-store", "missing newline"],
  [" allow-store\n", "leading whitespace"],
  ["allow-store \n", "trailing whitespace"],
  ["allow-store\n\n", "extra newline"],
  ["allow-store\r\n", "carriage return"],
  ["# allow-store\n", "comment"],
  ["allow-store\n# retained intentionally\n", "trailing comment"],
  ["true\n", "unrecognized token"],
  ["ALLOW-STORE\n", "different token"],
  [Buffer.from([0x61, 0x6c, 0x6c, 0x6f, 0x77, 0x2d, 0x73, 0x74, 0x6f, 0x72, 0x65, 0x0a, 0xff]), "extra non-UTF-8 byte"],
];
for (const [contents, description] of rejectedOptIns) {
  writeFileSync(configPath, contents);
  const rejectedInstance = loadExtensionInstance();
  const rejectedResult = runBeforeProviderRequest({ store: true }, {
    provider: "openai",
    api: "openai-responses",
    id: "gpt-5.6-sol",
  }, rejectedInstance.handlers);
  assert(rejectedResult.store === false, `${description} enabled direct OpenAI retention`);
  assert(process.env[packageEnv] === "0", `${description} enabled package continuation`);
}

writeFileSync(configPath, `${extension.DIRECT_OPENAI_RETENTION_OPT_IN}\n`);
const allowedPayload = {
  model: "gpt-5.6-sol",
  store: true,
  previous_response_id: "response-id",
  context_management: [{ type: "compaction", compact_threshold: 700000 }],
};
const optedInInstance = loadExtensionInstance();
const allowedResult = runBeforeProviderRequest(allowedPayload, {
  provider: "openai",
  api: "openai-responses",
  id: "gpt-5.6-sol",
}, optedInInstance.handlers);
assert(allowedResult === allowedPayload, "explicit direct OpenAI opt-in did not preserve package payload");
assert(process.env[packageEnv] === "1", "explicit opt-in did not enable package continuation");
for (const handler of optedInInstance.handlers.get("session_start") ?? []) {
  handler({ type: "session_start", reason: "startup" }, {});
}
assert(optedInInstance.providers.length === 0, "explicit opt-in did not preserve the package transport");

rmSync(configPath);
const rollbackInstance = loadExtensionInstance();
const rollbackResult = runBeforeProviderRequest({ store: true }, {
  provider: "openai",
  api: "openai-responses",
  id: "gpt-5.6-sol",
}, rollbackInstance.handlers);
assert(rollbackResult.store === false, "removing the opt-in did not restore denial");
assert(process.env[packageEnv] === "0", "removing the opt-in did not disable package continuation");

console.log("ok - Codex compaction stays enabled while direct OpenAI retention requires explicit opt-in");
JS
