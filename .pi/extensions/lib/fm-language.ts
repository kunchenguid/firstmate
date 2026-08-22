// Firstmate home language for visible product strings.
//
// docs/configuration.md owns the config/language contract, the optional tracked
// languages/<tag>.json packs, and the home-local config/languages/<tag>.json overlays.
// English is the source catalog and the fallback. Any other language is a pack or
// overlay; the resolver never prefers a specific non-English language.
// Background diagnostics stay in English and do not go through this module.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

export const DEFAULT_LANGUAGE = "en";

export type LanguageCatalog = Record<string, string>;

export type LanguageContext = {
  codeRoot: string;
  configDirectory: string;
};

const SOURCE_CATALOG: LanguageCatalog = {
  "calm.command.description":
    "Toggle Firstmate's supported conversation-only transcript presentation.",
  "calm.tool_collision.warning.one":
    "Firstmate Calm: the {names} built-in tool is already provided by another extension, so Calm may not fully function for it this session.",
  "calm.tool_collision.warning.other":
    "Firstmate Calm: the {names} built-in tools are already provided by another extension, so Calm may not fully function for them this session.",
};

const LANGUAGE_TAG = /^[a-z]{2,3}(?:-[a-z0-9]+){0,3}$/;

function readOptionalCatalog(path: string): LanguageCatalog {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return {};
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return {};
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return {};
  }
  const catalog: LanguageCatalog = {};
  for (const [key, value] of Object.entries(parsed)) {
    if (typeof value === "string") catalog[key] = value;
  }
  return catalog;
}

export function loadHomeLanguage(configDirectory: string): string {
  let raw: string;
  try {
    raw = readFileSync(resolve(configDirectory, "language"), "utf8");
  } catch {
    return DEFAULT_LANGUAGE;
  }
  const line = raw
    .split(/\r?\n/)
    .map((entry) => entry.trim())
    .find((entry) => entry.length > 0 && !entry.startsWith("#"));
  if (!line) return DEFAULT_LANGUAGE;
  const tag = line.toLowerCase();
  return LANGUAGE_TAG.test(tag) ? tag : DEFAULT_LANGUAGE;
}

export function languageFallbackTags(tag: string): string[] {
  const parts = tag.split("-");
  const tags = [tag];
  for (let i = parts.length - 1; i >= 1; i -= 1) {
    tags.push(parts.slice(0, i).join("-"));
  }
  if (tags[tags.length - 1] !== DEFAULT_LANGUAGE) tags.push(DEFAULT_LANGUAGE);
  return [...new Set(tags)];
}

export function resolveLanguageCatalog(ctx: LanguageContext): LanguageCatalog {
  const catalog: LanguageCatalog = { ...SOURCE_CATALOG };
  const tags = languageFallbackTags(loadHomeLanguage(ctx.configDirectory));
  for (const tag of [...tags].reverse()) {
    Object.assign(
      catalog,
      readOptionalCatalog(resolve(ctx.codeRoot, "languages", `${tag}.json`)),
    );
    Object.assign(
      catalog,
      readOptionalCatalog(resolve(ctx.configDirectory, "languages", `${tag}.json`)),
    );
  }
  return catalog;
}

export function formatHomeString(
  ctx: LanguageContext,
  key: string,
  vars: Record<string, string> = {},
): string {
  const catalog = resolveLanguageCatalog(ctx);
  const template = catalog[key] ?? SOURCE_CATALOG[key] ?? key;
  return template.replace(/\{([a-zA-Z0-9_]+)\}/g, (match, name: string) => {
    return Object.prototype.hasOwnProperty.call(vars, name) ? vars[name] : match;
  });
}
