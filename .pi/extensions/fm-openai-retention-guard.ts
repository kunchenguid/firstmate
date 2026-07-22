import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { Context, Model, SimpleStreamOptions, StreamFunction } from "@earendil-works/pi-ai";
import { streamSimpleOpenAIResponses } from "@earendil-works/pi-ai/compat";

const extensionFile = fileURLToPath(import.meta.url);
const root = resolve(dirname(extensionFile), "../..");

export const DIRECT_OPENAI_RETENTION_OPT_IN = "allow-store";
export const PACKAGE_PREVIOUS_RESPONSE_ID_ENV = "PI_OPENAI_SERVER_COMPACTION_PREVIOUS_RESPONSE_ID";

function configPath(): string {
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const configDir = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
  return `${configDir}/pi-direct-openai-retention`;
}

export function directOpenAIRetentionOptedIn(path = configPath()): boolean {
  try {
    return readFileSync(path, "utf8").trim() === DIRECT_OPENAI_RETENTION_OPT_IN;
  } catch {
    return false;
  }
}

export function applyDirectOpenAIRetentionPolicy(
  path = configPath(),
  env: NodeJS.ProcessEnv = process.env,
): boolean {
  const optedIn = directOpenAIRetentionOptedIn(path);
  env[PACKAGE_PREVIOUS_RESPONSE_ID_ENV] = optedIn ? "1" : "0";
  return optedIn;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isDirectOpenAIModel(model: unknown): boolean {
  return isRecord(model) && model.provider === "openai";
}

export function guardDirectOpenAIPayload(params: {
  payload: unknown;
  model: unknown;
  retentionOptedIn: boolean;
}): Record<string, unknown> | undefined {
  if (params.retentionOptedIn || !isDirectOpenAIModel(params.model) || !isRecord(params.payload)) {
    return undefined;
  }

  const payload: Record<string, unknown> = { ...params.payload, store: false };
  delete payload.previous_response_id;
  delete payload.context_management;
  return payload;
}

export function withDirectOpenAIFinalPayloadGuard(
  options: SimpleStreamOptions | undefined,
): SimpleStreamOptions {
  const originalOnPayload = options?.onPayload;
  return {
    ...(options ?? {}),
    onPayload: async (payload, model) => {
      const processedPayload = (await originalOnPayload?.(payload, model)) ?? payload;
      return guardDirectOpenAIPayload({
        payload: processedPayload,
        model,
        retentionOptedIn: false,
      }) ?? processedPayload;
    },
  };
}

const safeDirectOpenAIStream: StreamFunction = (model, context, options) => {
  return streamSimpleOpenAIResponses(
    model as Model<"openai-responses">,
    context as Context,
    withDirectOpenAIFinalPayloadGuard(options),
  );
};

export default function openAIRetentionGuard(pi: ExtensionAPI) {
  const retentionOptedIn = applyDirectOpenAIRetentionPolicy();

  pi.on("session_start", () => {
    if (retentionOptedIn) return;
    pi.registerProvider("openai", {
      api: "openai-responses",
      streamSimple: safeDirectOpenAIStream,
    });
  });
  pi.on("before_provider_request", (event, ctx) => {
    return guardDirectOpenAIPayload({
      payload: event.payload,
      model: ctx.model,
      retentionOptedIn,
    });
  });
}
