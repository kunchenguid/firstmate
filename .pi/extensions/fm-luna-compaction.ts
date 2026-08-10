// Safely route only Pi's nested compaction requests to Luna.
//
// Pi's own compact() remains the single owner of prompt construction, split-turn
// handling, file-operation tracking, token accounting, and session semantics.
import {
  compact,
  convertToLlm,
  serializeConversation,
  type CompactionResult,
  type ExtensionAPI,
  type ModelRegistry,
  type SessionBeforeCompactEvent,
} from "@earendil-works/pi-coding-agent";
import type { Model, Usage } from "@earendil-works/pi-ai";

const COMPACTION_MODELS = {
  provider: "openai-codex",
  primary: "gpt-5.6-luna",
  primaryLabel: "Luna",
  fallback: "gpt-5.6-terra",
  fallbackLabel: "Terra",
} as const;

const COMPACTION_SAFETY_POLICY = {
  disabledValue: "off",
  minimumUsageFraction: 0.5,
  outputCeilingFraction: 0.98,
  requestOverheadTokens: 2048,
  saturationMarginTokens: 1024,
  requiredHeadings: [
    "## Goal",
    "## Constraints & Preferences",
    "## Progress",
    "### Done",
    "### In Progress",
    "### Blocked",
    "## Key Decisions",
    "## Next Steps",
    "## Critical Context",
  ],
  requiredSplitHeadings: ["## Original Request", "## Early Progress", "## Context for Suffix"],
} as const;

type CompactionPreparation = SessionBeforeCompactEvent["preparation"];

type CompactionAttempt = {
  result: CompactionResult;
  model: Model<any>;
};

// Both token counts come from the same estimate today but bound the request from opposite
// sides: envelopeInputTokens is the ceiling a model must be able to receive, and
// expectedInputTokens is the floor a returned result must show it actually received.
// Keeping them separate stops a later change to one from silently moving the other.
type RequestSegment = {
  envelopeInputTokens: number;
  expectedInputTokens: number;
  outputTokens: number;
};

type CompactionDetails = {
  readFiles: string[];
  modifiedFiles: string[];
};

function encodedBytes(text: string): number {
  return new TextEncoder().encode(text).byteLength;
}

function estimatedTokens(text: string): number {
  return Math.ceil(encodedBytes(text) / 4);
}

function serializedText(messages: CompactionPreparation["messagesToSummarize"]): string {
  return serializeConversation(convertToLlm(messages));
}

function maximumOutputTokens(model: Model<any>, preparation: CompactionPreparation, split: boolean): number {
  const fraction = split ? 0.5 : 0.8;
  const modelLimit = model.maxTokens > 0 ? model.maxTokens : Number.POSITIVE_INFINITY;
  return Math.min(Math.floor(fraction * preparation.settings.reserveTokens), modelLimit);
}

// model.contextWindow is denominated in tokens, so every quantity compared against it must be
// too. Pi sizes its own compaction requests with the same chars/4 heuristic, and measuring
// UTF-8 bytes rather than UTF-16 code units keeps multibyte text on the conservative side of it.
function inputMeasurements(parts: readonly string[]): Pick<RequestSegment, "envelopeInputTokens" | "expectedInputTokens"> {
  const estimated = parts.reduce((total, part) => total + estimatedTokens(part), 0);
  return {
    envelopeInputTokens: estimated + COMPACTION_SAFETY_POLICY.requestOverheadTokens,
    expectedInputTokens: estimated,
  };
}

function historyInputMeasurements(
  preparation: CompactionPreparation,
  customInstructions?: string,
): Pick<RequestSegment, "envelopeInputTokens" | "expectedInputTokens"> {
  return inputMeasurements([
    serializedText(preparation.messagesToSummarize),
    preparation.previousSummary ?? "",
    customInstructions ?? "",
  ]);
}

// Pi sends one request per segment, so each is preflighted against the whole window on its own.
// The segments returned here must stay index-aligned with summarySegments(), which is how
// usageSuggestsTruncation() pairs a returned summary part with the budget it was generated under.
function requestSegments(
  model: Model<any>,
  preparation: CompactionPreparation,
  customInstructions?: string,
): RequestSegment[] {
  if (preparation.isSplitTurn && preparation.turnPrefixMessages.length > 0) {
    const segments: RequestSegment[] = [];
    if (preparation.messagesToSummarize.length > 0) {
      segments.push({
        ...historyInputMeasurements(preparation, customInstructions),
        outputTokens: maximumOutputTokens(model, preparation, false),
      });
    }
    segments.push({
      ...inputMeasurements([serializedText(preparation.turnPrefixMessages)]),
      outputTokens: maximumOutputTokens(model, preparation, true),
    });
    return segments;
  }
  return [{
    ...historyInputMeasurements(preparation, customInstructions),
    outputTokens: maximumOutputTokens(model, preparation, false),
  }];
}

function modelCanReceivePreparation(
  model: Model<any>,
  preparation: CompactionPreparation,
  customInstructions?: string,
): boolean {
  return requestSegments(model, preparation, customInstructions)
    .every((segment) => segment.envelopeInputTokens + segment.outputTokens <= model.contextWindow);
}

// Summarizing a session into a model that cannot hold it is how history goes missing quietly, so
// a compaction model narrower than the conversation itself is refused before it is ever called.
// Pi reports no conversation model in some sessions; refusing on an unknown window would cancel
// every compaction, so those fall back to the absolute envelope check alone.
function preflightRejection(
  model: Model<any>,
  label: string,
  conversationModel: Model<any> | undefined,
  preparation: CompactionPreparation,
  customInstructions?: string,
): string | undefined {
  if (conversationModel && model.contextWindow < conversationModel.contextWindow) {
    return `${label}'s context window is smaller than the conversation's own model`;
  }
  if (!modelCanReceivePreparation(model, preparation, customInstructions)) {
    return `the prepared request exceeds ${label}'s supported context/output envelope`;
  }
  return undefined;
}

function headingMatches(text: string, heading: string): RegExpMatchArray[] {
  const escaped = heading.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return [...text.matchAll(new RegExp(`^${escaped}\\s*$`, "gm"))];
}

function hasOrderedSubstantiveSections(
  text: string,
  headings: readonly string[],
  containerHeadings: readonly string[] = [],
): boolean {
  const matches = headings.map((heading) => headingMatches(text, heading));
  if (matches.some((headingMatchesForText) => headingMatchesForText.length !== 1)) return false;
  const positions = matches.map(([match]) => match.index ?? -1);
  if (positions.some((position, index) => index > 0 && position <= positions[index - 1])) return false;
  return headings.every((heading, index) => {
    if (containerHeadings.includes(heading)) return true;
    const match = matches[index][0];
    const start = (match.index ?? 0) + match[0].length;
    const end = index + 1 < positions.length ? positions[index + 1] : text.length;
    return /[\p{L}\p{N}]/u.test(text.slice(start, end));
  });
}

function expectedDetails(preparation: CompactionPreparation): CompactionDetails {
  const modified = new Set([...preparation.fileOps.edited, ...preparation.fileOps.written]);
  return {
    readFiles: [...preparation.fileOps.read].filter((file) => !modified.has(file)).sort(),
    modifiedFiles: [...modified].sort(),
  };
}

function validDetails(details: unknown, expected: CompactionDetails): details is CompactionDetails {
  if (!details || typeof details !== "object") return false;
  const candidate = details as Partial<CompactionDetails>;
  return Array.isArray(candidate.readFiles)
    && candidate.readFiles.every((file) => typeof file === "string")
    && Array.isArray(candidate.modifiedFiles)
    && candidate.modifiedFiles.every((file) => typeof file === "string")
    && candidate.readFiles.join("\n") === expected.readFiles.join("\n")
    && candidate.modifiedFiles.join("\n") === expected.modifiedFiles.join("\n");
}

function fileOperationsSuffix(details: CompactionDetails): string {
  const sections: string[] = [];
  if (details.readFiles.length > 0) {
    sections.push(`<read-files>\n${details.readFiles.join("\n")}\n</read-files>`);
  }
  if (details.modifiedFiles.length > 0) {
    sections.push(`<modified-files>\n${details.modifiedFiles.join("\n")}\n</modified-files>`);
  }
  return sections.length > 0 ? `\n\n${sections.join("\n\n")}` : "";
}

function summaryContent(result: CompactionResult, preparation: CompactionPreparation): string | undefined {
  const expected = expectedDetails(preparation);
  if (!validDetails(result.details, expected)) return undefined;
  const suffix = fileOperationsSuffix(expected);
  if (suffix && !result.summary.endsWith(suffix)) return undefined;
  const content = suffix ? result.summary.slice(0, -suffix.length) : result.summary;
  if (/<\/?(?:read|modified)-files>/.test(content)) return undefined;
  return content;
}

function summarySegments(content: string, preparation: CompactionPreparation): string[] | undefined {
  if (!preparation.isSplitTurn || preparation.turnPrefixMessages.length === 0) {
    return hasOrderedSubstantiveSections(content, COMPACTION_SAFETY_POLICY.requiredHeadings, ["## Progress"])
      ? [content]
      : undefined;
  }
  const marker = "\n\n---\n\n**Turn Context (split turn):**\n\n";
  const parts = content.split(marker);
  if (parts.length !== 2) return undefined;
  const [history, prefix] = parts;
  if (preparation.messagesToSummarize.length > 0) {
    if (!hasOrderedSubstantiveSections(history, COMPACTION_SAFETY_POLICY.requiredHeadings, ["## Progress"])) return undefined;
  } else if (history.trim() !== "No prior history.") {
    return undefined;
  }
  if (!hasOrderedSubstantiveSections(prefix, COMPACTION_SAFETY_POLICY.requiredSplitHeadings)) return undefined;
  return preparation.messagesToSummarize.length > 0 ? [history, prefix] : [prefix];
}

function visiblyTruncated(summary: string): boolean {
  const ending = summary.trimEnd();
  return /(?:\.\.\.|…|\[\.\.\.[^\]]*|[:,;])$/.test(ending);
}

function usageSuggestsTruncation(
  usage: Usage | undefined,
  segments: readonly string[],
  envelopes: readonly RequestSegment[],
): boolean {
  if (!usage || usage.output <= 0) return false;
  if (usage.output >= envelopes.reduce((total, segment) => total + segment.outputTokens, 0)
    * COMPACTION_SAFETY_POLICY.outputCeilingFraction) return true;
  return segments.some((segment, index) => estimatedTokens(segment) >= envelopes[index].outputTokens
    * COMPACTION_SAFETY_POLICY.outputCeilingFraction);
}

function receivedInputTokens(usage: Usage): number {
  return usage.input + usage.cacheRead + usage.cacheWrite;
}

function usageSuggestsLostInput(usage: Usage | undefined, envelopes: readonly RequestSegment[]): boolean {
  if (!usage) return true;
  const received = receivedInputTokens(usage);
  if (received <= 0) return true;
  const preparedTokens = envelopes.reduce((total, segment) => total + segment.expectedInputTokens, 0);
  return received < preparedTokens * COMPACTION_SAFETY_POLICY.minimumUsageFraction;
}

// The estimate above can understate a request's real token cost, so a request that passed
// preflight may still have overrun the window. An endpoint that clips instead of erroring would
// leave usage looking complete against that understated estimate, so this compares the reported
// input against the ceiling a clipped segment lands on instead. Pi sums usage across a split
// turn's requests, and a clipped segment alone pushes that sum to at least the smallest
// per-segment ceiling. Comparing against the smallest ceiling therefore catches a clipped
// segment, and can also reject a genuinely near-ceiling request, which is the safe direction.
function usageSuggestsSaturatedRequest(
  usage: Usage | undefined,
  model: Model<any>,
  envelopes: readonly RequestSegment[],
): boolean {
  if (!usage || envelopes.length === 0) return false;
  const ceiling = Math.min(...envelopes.map((segment) => model.contextWindow - segment.outputTokens));
  return receivedInputTokens(usage) >= ceiling - COMPACTION_SAFETY_POLICY.saturationMarginTokens;
}

function safeResult(
  result: CompactionResult,
  model: Model<any>,
  preparation: CompactionPreparation,
  customInstructions?: string,
): string | undefined {
  if (!result.summary.trim()) return "the summary was empty";
  if (result.firstKeptEntryId !== preparation.firstKeptEntryId || result.tokensBefore !== preparation.tokensBefore) {
    return "the result did not preserve the prepared session boundary";
  }
  const content = summaryContent(result, preparation);
  if (content === undefined) return "the result did not preserve native file tracking";
  const segments = summarySegments(content, preparation);
  if (!segments) return "the summary was malformed or incomplete";
  if (segments.some(visiblyTruncated)) return "a summary segment is visibly truncated";
  const envelopes = requestSegments(model, preparation, customInstructions);
  if (usageSuggestsTruncation(result.usage, segments, envelopes)) return "the summary reached its output limit";
  if (usageSuggestsLostInput(result.usage, envelopes)) return "usage indicates the request received too little prepared history";
  if (usageSuggestsSaturatedRequest(result.usage, model, envelopes)) {
    return "the request filled the model's context window, so prepared history may have been dropped";
  }
  return undefined;
}

async function runCompaction(
  preparation: CompactionPreparation,
  model: Model<any>,
  customInstructions: string | undefined,
  signal: AbortSignal,
  registry: ModelRegistry,
): Promise<CompactionAttempt> {
  if (signal.aborted) throw new Error("compaction was cancelled");
  const auth = await registry.getApiKeyAndHeaders(model);
  if (!auth.ok) throw new Error(auth.error);
  const result = await compact(
    preparation,
    model,
    auth.apiKey,
    requestHeaders(auth.headers),
    customInstructions,
    signal,
    undefined,
    undefined,
    auth.env,
  );
  if (signal.aborted) throw new Error("compaction was cancelled");
  return { result, model };
}

function requestHeaders(headers: Record<string, string | null> | undefined): Record<string, string> | undefined {
  if (!headers) return undefined;
  return Object.fromEntries(Object.entries(headers).filter((entry): entry is [string, string] => entry[1] !== null));
}

function failureMessage(primaryReason: string, fallbackReason: string): string {
  return `Safe compaction failed: ${COMPACTION_MODELS.primaryLabel} was rejected because ${primaryReason}; `
    + `${COMPACTION_MODELS.fallbackLabel} was rejected because ${fallbackReason}.`;
}

function cancelWithError(ctx: { ui: { notify(message: string, type?: "info" | "warning" | "error"): void } }, message: string) {
  ctx.ui.notify(message, "error");
  return { cancel: true } as const;
}

export default function (pi: ExtensionAPI) {
  pi.on("session_before_compact", async (event, ctx) => {
    if (process.env.FM_PI_LUNA_COMPACTION === COMPACTION_SAFETY_POLICY.disabledValue) return;

    const primary = ctx.modelRegistry.find(COMPACTION_MODELS.provider, COMPACTION_MODELS.primary);
    const fallback = ctx.modelRegistry.find(COMPACTION_MODELS.provider, COMPACTION_MODELS.fallback);
    if (!primary || !fallback) {
      return cancelWithError(
        ctx,
        `Safe compaction requires both ${COMPACTION_MODELS.provider}/${COMPACTION_MODELS.primary} `
          + `and ${COMPACTION_MODELS.provider}/${COMPACTION_MODELS.fallback}.`,
      );
    }

    let primaryReason = `${COMPACTION_MODELS.primaryLabel} could not safely compact this session`;
    const primaryRejection = preflightRejection(
      primary,
      COMPACTION_MODELS.primaryLabel,
      ctx.model,
      event.preparation,
      event.customInstructions,
    );
    if (primaryRejection) {
      primaryReason = primaryRejection;
    } else {
      try {
        const attempt = await runCompaction(
          event.preparation,
          primary,
          event.customInstructions,
          event.signal,
          ctx.modelRegistry,
        );
        const rejected = safeResult(attempt.result, attempt.model, event.preparation, event.customInstructions);
        if (!rejected) return { compaction: attempt.result };
        primaryReason = rejected;
      } catch (error) {
        primaryReason = error instanceof Error ? error.message : String(error);
      }
    }

    try {
      const fallbackRejection = preflightRejection(
        fallback,
        COMPACTION_MODELS.fallbackLabel,
        ctx.model,
        event.preparation,
        event.customInstructions,
      );
      if (fallbackRejection) throw new Error(fallbackRejection);
      const attempt = await runCompaction(
        event.preparation,
        fallback,
        event.customInstructions,
        event.signal,
        ctx.modelRegistry,
      );
      const rejected = safeResult(attempt.result, attempt.model, event.preparation, event.customInstructions);
      if (!rejected) return { compaction: attempt.result };
      throw new Error(rejected);
    } catch (error) {
      const fallbackReason = error instanceof Error ? error.message : String(error);
      return cancelWithError(ctx, failureMessage(primaryReason, fallbackReason));
    }
  });
}
