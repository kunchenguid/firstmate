#!/usr/bin/env node
// Internal snapshot computer for bin/fm-quota-utilization.sh.
// quota-axi remains data-only; this file never routes, holds work, or
// recommends a harness. It derives the widget metric, binding-weekly reserve,
// usable runway, and end-of-window outcomes from already-fetched snapshots.

import fs from "node:fs";

const raw = fs.readFileSync(0, "utf8");
const input = JSON.parse(raw);
const nowMs = Date.parse(input.now);
if (!Number.isFinite(nowMs)) {
  process.stderr.write("error: invalid now instant\n");
  process.exit(2);
}

function asNumber(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function asString(value) {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function countdownSeconds(resetsAt) {
  const resetMs = Date.parse(resetsAt);
  if (!Number.isFinite(resetMs)) return null;
  return Math.max(0, Math.floor((resetMs - nowMs) / 1000));
}

function windowById(windows, id) {
  return windows.find((window) => window && window.id === id) || null;
}

function accountWindows(provider) {
  return Array.isArray(provider.windows) ? provider.windows : [];
}

function allModelsAvailability(provider) {
  const rows = provider?.quotaSemantics?.effectiveAvailability;
  if (!Array.isArray(rows)) return null;
  return rows.find((row) => row && row.scope === "all_models") || null;
}

function providerCause(provider) {
  const stateError = provider.state?.error;
  if (typeof stateError === "string" && stateError) return stateError;
  if (provider.source === "unavailable" && accountWindows(provider).length === 0) {
    return "source unavailable";
  }
  return null;
}

function verdictFromReserve(reserve, paceStatus) {
  if (paceStatus === "ahead" || (reserve != null && reserve < 0)) return "RATION";
  if (paceStatus === "behind" || (reserve != null && reserve > 0)) return "SPEND";
  return "ON_TRACK";
}

function describeAccount(snapshotMeta, provider) {
  const windows = accountWindows(provider);
  const cause = providerCause(provider);
  if (windows.length === 0) {
    return {
      degraded: {
        provider: provider.provider,
        account: snapshotMeta.account,
        cause: cause || "no measured windows",
      },
    };
  }

  const availability = allModelsAvailability(provider);
  const limitingId =
    availability?.limitingWindowIds?.[0] ||
    availability?.runway?.limitingWindowId ||
    null;
  const tightest =
    (limitingId && windowById(windows, limitingId)) ||
    windows
      .filter((window) => window.kind !== "model" && asNumber(window.percentRemaining) != null)
      .sort((a, b) => a.percentRemaining - b.percentRemaining)[0] ||
    windows[0];

  const weekly = windows.find((window) => window.kind === "weekly") || null;
  const weeklyReserve = asNumber(weekly?.pace?.reservePercentPoints);
  const weeklyPace = asString(weekly?.pace?.status) || asString(availability?.pace?.status);
  const weeklyAhead = weeklyPace === "ahead" || (weeklyReserve != null && weeklyReserve < 0);
  const utilization =
    asNumber(tightest?.percentUsed) ??
    (asNumber(availability?.effectivePercentRemaining) != null
      ? 100 - availability.effectivePercentRemaining
      : null);
  const shortWindows = windows
    .filter((window) => window.kind === "session")
    .map((window) => {
      const percentRemaining = asNumber(window.percentRemaining);
      return {
        id: window.id,
        percentRemaining,
        reservePercentPoints: asNumber(window.pace?.reservePercentPoints),
        spareCapacity: !weeklyAhead && (percentRemaining ?? 0) > 0,
      };
    });

  const usableRunway = asNumber(availability?.runway?.usableRunwaySeconds);
  const verdict = verdictFromReserve(weeklyReserve, weeklyPace);
  return {
    account: {
      provider: provider.provider,
      account: snapshotMeta.account,
      plan: provider.plan ?? null,
      source: provider.source ?? null,
      tightestWindowId: tightest?.id ?? null,
      utilizationPercent: utilization,
      resetCountdownSeconds: countdownSeconds(tightest?.resetsAt),
      resetsAt: tightest?.resetsAt ?? null,
      bindingWeeklyWindowId: weekly?.id ?? null,
      bindingWeeklyReservePercentPoints: weeklyReserve,
      bindingWeeklyPaceStatus: weeklyPace,
      usableRunwaySeconds: usableRunway,
      runwayStatus: availability?.runway?.status ?? null,
      shortWindows,
      verdict,
      pressure: verdict === "RATION" ? "ahead_of_pace" : verdict === "SPEND" ? "behind_pace" : "on_pace",
    },
  };
}

const accounts = [];
const degraded = [];
for (const snapshotMeta of input.snapshots || []) {
  if (snapshotMeta.error) {
    degraded.push({
      provider: snapshotMeta.provider || "quota-axi",
      account: snapshotMeta.account || "default",
      cause: snapshotMeta.error,
    });
    continue;
  }
  const snapshot = snapshotMeta.snapshot;
  const providers = Array.isArray(snapshot?.providers) ? snapshot.providers : [];
  if (providers.length === 0) {
    continue;
  }
  for (const provider of providers) {
    if (input.provider && provider.provider !== input.provider) continue;
    const described = describeAccount(snapshotMeta, provider);
    if (described.degraded) degraded.push(described.degraded);
    if (described.account) accounts.push(described.account);
  }
}

const weeklyCandidates = accounts.filter(
  (row) => row.bindingWeeklyReservePercentPoints != null,
);
let preferred = null;
if (weeklyCandidates.length > 0) {
  preferred = weeklyCandidates.reduce((best, row) =>
    row.bindingWeeklyReservePercentPoints > best.bindingWeeklyReservePercentPoints
      ? row
      : best,
  );
}

function outcomeFromObservation(observation) {
  const remaining = asNumber(observation.percentRemaining);
  const resetMs = Date.parse(observation.resetsAt);
  const observedMs = Date.parse(observation.observedAt);
  if (!Number.isFinite(resetMs) || remaining == null) return null;
  // The outcome is a property of the window, not of the reading clock: a window
  // that hit zero before its own reset stays exhausted-early when the table is
  // recomputed after the week closed.
  const atMs = Number.isFinite(observedMs) ? observedMs : nowMs;
  if (remaining === 0 && atMs < resetMs) {
    return {
      provider: observation.provider,
      account: observation.account || "default",
      windowId: observation.windowId,
      kind: "exhausted-early",
      unusedPercent: 0,
      exhaustedEarlySeconds: Math.max(0, Math.floor((resetMs - atMs) / 1000)),
    };
  }
  if (nowMs >= resetMs) {
    return {
      provider: observation.provider,
      account: observation.account || "default",
      windowId: observation.windowId,
      kind: "expired-unused",
      unusedPercent: remaining,
      exhaustedEarlySeconds: null,
    };
  }
  return null;
}

const outcomes = [];
for (const observation of input.observations || []) {
  if (input.provider && observation.provider !== input.provider) continue;
  const outcome = outcomeFromObservation(observation);
  if (outcome) outcomes.push(outcome);
}

const result = {
  now: input.now,
  accounts,
  degraded,
  preferredBindingWeeklyProvider: preferred?.provider ?? null,
  preferredBindingWeeklyAccount: preferred?.account ?? null,
  holdReadyWork: false,
  weakenReasoningClass: false,
  outcomes,
};

process.stdout.write(`${JSON.stringify(result)}\n`);
