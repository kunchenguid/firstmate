#!/usr/bin/env node
// Collect read-only local telemetry for the /bearings lavish board.
// Usage: node bin/fm-bearings-metrics.mjs

import { spawnSync } from "node:child_process";
import { createReadStream } from "node:fs";
import { readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";

const projectsDir = process.env.FM_BEARINGS_CLAUDE_PROJECTS
  ?? path.join(homedir(), ".claude", "projects");
const transcriptWindowMs = 24 * 60 * 60 * 1000;
const metrics = {};
const tokenTotals = {
  cacheRead: 0,
  cacheCreation: 0,
  input: 0,
};
let toolUses = 0;
let toolResultErrors = 0;

async function jsonlFiles(directory) {
  const files = [];
  let entries;
  try {
    entries = await readdir(directory, { withFileTypes: true });
  } catch (error) {
    if (error.code === "ENOENT" || error.code === "ENOTDIR") return files;
    throw error;
  }
  for (const entry of entries) {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await jsonlFiles(fullPath));
    else if (entry.isFile() && entry.name.endsWith(".jsonl")) files.push(fullPath);
  }
  return files;
}

function addToken(usage, key, target) {
  const value = usage?.[key];
  if (typeof value === "number" && Number.isFinite(value) && value >= 0) {
    tokenTotals[target] += value;
  }
}

async function scanTranscript(file, cutoffMs) {
  const lines = createInterface({ input: createReadStream(file), crlfDelay: Infinity });
  for await (const line of lines) {
    let entry;
    try {
      entry = JSON.parse(line);
    } catch (error) {
      if (error instanceof SyntaxError) continue;
      throw error;
    }
    if (entry === null || typeof entry !== "object") continue;
    const eventTime = typeof entry.timestamp === "string" ? Date.parse(entry.timestamp) : NaN;
    if (!Number.isFinite(eventTime) || eventTime < cutoffMs) continue;
    if (entry.type === "assistant") {
      const message = entry.message;
      const blocks = message?.content;
      if (Array.isArray(blocks)) {
        for (const block of blocks) {
          if (block?.type === "tool_use") toolUses += 1;
        }
      }
      const usage = message?.usage;
      addToken(usage, "cache_read_input_tokens", "cacheRead");
      addToken(usage, "cache_creation_input_tokens", "cacheCreation");
      addToken(usage, "input_tokens", "input");
    } else if (entry.type === "user" && Array.isArray(entry.message?.content)) {
      for (const block of entry.message.content) {
        if (block?.type === "tool_result" && block.is_error === true) {
          toolResultErrors += 1;
        }
      }
    }
  }
}

async function transcriptMetrics() {
  const files = await jsonlFiles(projectsDir);
  if (files.length === 0) return;
  const cutoffMs = Date.now() - transcriptWindowMs;
  for (const file of files) {
    if ((await stat(file)).mtimeMs >= cutoffMs) await scanTranscript(file, cutoffMs);
  }
  const cachedTokens = tokenTotals.cacheRead + tokenTotals.cacheCreation + tokenTotals.input;
  if (cachedTokens > 0) {
    metrics.cache_hit_rate = Math.round((tokenTotals.cacheRead / cachedTokens) * 1000) / 10;
  }
  if (toolUses > 0 && toolResultErrors <= toolUses) {
    metrics.tool_error_rate = { errors: toolResultErrors, total: toolUses };
  }
}

function quotaMetrics() {
  const result = spawnSync("quota-axi", [
    "--provider", "claude", "--json", "--no-credential-refresh",
  ], { encoding: "utf8", maxBuffer: 1024 * 1024 });
  if (result.status !== 0 || !result.stdout) return;
  let report;
  try {
    report = JSON.parse(result.stdout);
  } catch (error) {
    if (error instanceof SyntaxError) return;
    throw error;
  }
  if (!report || !Array.isArray(report.providers)) return;
  const provider = report.providers.find((item) => item?.provider === "claude");
  if (!provider || provider.state?.stale === true
      || (provider.state?.status && provider.state.status !== "fresh")) return;
  const windows = new Map((Array.isArray(provider.windows) ? provider.windows : [])
    .filter((window) => window && typeof window.id === "string")
    .map((window) => [window.id, window]));
  for (const [windowId, metricName] of [
    ["five_hour", "quota_session_used_percent"],
    ["seven_day", "quota_weekly_used_percent"],
  ]) {
    const window = windows.get(windowId);
    const used = typeof window?.percentUsed === "number"
      ? window.percentUsed
      : typeof window?.percentRemaining === "number"
        ? 100 - window.percentRemaining
        : undefined;
    if (used !== undefined && Number.isFinite(used) && used >= 0 && used <= 100) {
      metrics[metricName] = used;
    }
  }
}

async function main() {
  try {
    await transcriptMetrics();
  } catch (error) {
    if (error.code !== "EACCES" && error.code !== "ENOENT" && error.code !== "ENOTDIR") {
      throw error;
    }
    delete metrics.cache_hit_rate;
    delete metrics.tool_error_rate;
  }
  quotaMetrics();
  process.stdout.write(`${JSON.stringify(metrics)}\n`);
}

await main();
