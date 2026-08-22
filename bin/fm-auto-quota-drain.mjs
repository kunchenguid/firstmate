#!/usr/bin/env node
// Validate one quota-axi snapshot and the home-local automatic seat-drain configuration.
// This evaluator treats both files as data and emits a bounded normalized plan without performing lifecycle work.

import fs from "node:fs";

const args = process.argv.slice(2);
const configOnly = args[0] === "--config-only";
const [quotaPath, configPath, nowInput] = configOnly ? [null, args[1], null] : args;

function result(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function diagnostic(reason) {
  result({ ok: false, reason });
  process.exit(0);
}

function readJson(path, absentValue, malformedReason) {
  if (!path || path === "-") return absentValue;
  try {
    return JSON.parse(fs.readFileSync(path, "utf8"));
  } catch {
    diagnostic(malformedReason);
  }
}

function exactKeys(value, allowed) {
  return Object.keys(value).every((key) => allowed.includes(key));
}

function boundedName(value) {
  return typeof value === "string" && /^[A-Za-z0-9._-]{1,96}$/.test(value);
}

function finitePercent(value) {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 100;
}

function quotaRunway(row) {
  const runway = row.runway;
  if (!runway || typeof runway !== "object" || Array.isArray(runway)) return "unmeasurable";
  if (runway.status === "through_reset") return "sufficient";
  if (runway.status === "projected_exhaustion") {
    const seconds = runway.usableRunwaySeconds;
    if (typeof seconds !== "number" || !Number.isFinite(seconds) || seconds < 0) return "unmeasurable";
    return seconds >= 3600 ? "sufficient" : "tight";
  }
  return "unmeasurable";
}

const config = readJson(configPath, {}, "configuration is malformed");
if (!config || typeof config !== "object" || Array.isArray(config)) diagnostic("configuration is malformed");
if (!exactKeys(config, ["schemaVersion", "warningPercentRemaining", "actionPercentRemaining", "maxSnapshotAgeSeconds", "positions"])) {
  diagnostic("configuration is malformed");
}
if (config.schemaVersion != null && config.schemaVersion !== 1) diagnostic("configuration is malformed");
const warning = config.warningPercentRemaining ?? 7;
const action = config.actionPercentRemaining ?? 5;
const maxAge = config.maxSnapshotAgeSeconds ?? 300;
if (!finitePercent(warning) || !finitePercent(action) || action >= warning) diagnostic("configuration is malformed");
if (!Number.isInteger(maxAge) || maxAge < 30 || maxAge > 3600) diagnostic("configuration is malformed");
const rawPositions = config.positions ?? [];
if (!Array.isArray(rawPositions) || rawPositions.length > 16) diagnostic("configuration is malformed");

const positions = [];
const positionNames = new Set();
const seatNames = new Set();
const positionProviders = new Set();
for (const position of rawPositions) {
  if (!position || typeof position !== "object" || Array.isArray(position)) diagnostic("configuration is malformed");
  if (!exactKeys(position, [
    "position",
    "seat",
    "provider",
    "postDrainProvider",
    "postDrainModelFamily",
    "requiredReasoningClass",
    "postDrainReasoningClass",
  ])) {
    diagnostic("configuration is malformed");
  }
  if (![position.position, position.seat, position.provider, position.postDrainProvider, position.postDrainModelFamily,
    position.requiredReasoningClass, position.postDrainReasoningClass].every(boundedName)) {
    diagnostic("configuration is malformed");
  }
  if (positionNames.has(position.position) || seatNames.has(position.seat) || positionProviders.has(position.provider)) {
    diagnostic("configuration is contradictory");
  }
  if (position.postDrainReasoningClass !== position.requiredReasoningClass) {
    diagnostic("configuration would downgrade the required reasoning class");
  }
  positionNames.add(position.position);
  seatNames.add(position.seat);
  positionProviders.add(position.provider);
  positions.push({
    position: position.position,
    seat: position.seat,
    provider: position.provider,
    postDrainProvider: position.postDrainProvider,
    postDrainModelFamily: position.postDrainModelFamily,
    requiredReasoningClass: position.requiredReasoningClass,
    postDrainReasoningClass: position.postDrainReasoningClass,
  });
}

positions.sort((left, right) => left.position.localeCompare(right.position));
if (configOnly) {
  result({ ok: true, positions });
  process.exit(0);
}

const nowMs = Date.parse(nowInput);
if (!Number.isFinite(nowMs)) diagnostic("internal clock is invalid");

const quota = readJson(quotaPath, null, "quota snapshot is malformed");
if (!quota || typeof quota !== "object" || Array.isArray(quota) || quota.schemaVersion !== 3 || !Array.isArray(quota.providers) || quota.providers.length < 1) {
  diagnostic("quota snapshot is malformed");
}
const generatedMs = Date.parse(quota.generatedAt);
if (!Number.isFinite(generatedMs)) diagnostic("quota snapshot is malformed");
const ageSeconds = Math.floor((nowMs - generatedMs) / 1000);
if (ageSeconds < -60) diagnostic("quota snapshot is contradictory");
if (ageSeconds > maxAge) diagnostic("quota snapshot is stale");

const providers = [];
const providerNames = new Set();
for (const provider of quota.providers) {
  if (!provider || typeof provider !== "object" || Array.isArray(provider) || !boundedName(provider.provider)) {
    diagnostic("quota snapshot is malformed");
  }
  if (providerNames.has(provider.provider)) diagnostic("quota snapshot is contradictory");
  providerNames.add(provider.provider);
  if (!provider.state || provider.state.status !== "fresh" || provider.state.stale !== false) {
    diagnostic("quota snapshot is unmeasurable");
  }
  const availability = provider.quotaSemantics?.effectiveAvailability;
  if (!Array.isArray(availability)) diagnostic("quota snapshot is unmeasurable");
  const effective = availability.filter((row) => row && row.scope === "all_models");
  if (effective.length !== 1) diagnostic(effective.length > 1 ? "quota snapshot is contradictory" : "quota snapshot is unmeasurable");
  const row = effective[0];
  if (row.status !== "known" || !finitePercent(row.effectivePercentRemaining)) {
    diagnostic("quota snapshot is unmeasurable");
  }
  providers.push({
    provider: provider.provider,
    percentRemaining: row.effectivePercentRemaining,
    headroom: row.effectivePercentRemaining > warning ? "sufficient" : row.effectivePercentRemaining > action ? "tight" : "exhausted",
    runway: quotaRunway(row),
  });
}
for (const position of positions) {
  if (!providerNames.has(position.provider) || !providerNames.has(position.postDrainProvider)) {
    diagnostic("quota snapshot is unmeasurable");
  }
}
providers.sort((left, right) => left.provider.localeCompare(right.provider));
result({ ok: true, warningPercentRemaining: warning, actionPercentRemaining: action, providers, positions });
