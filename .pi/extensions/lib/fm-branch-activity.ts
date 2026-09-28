// Observational read model. Routing, claims and outcome acknowledgement remain
// owned by the branch/watcher; nothing returned here authorizes an action.
export const ACTIVITY_STALE_MS = 120_000;
export type ActivityHealth = {
  time: number; generation: number; owned?: boolean; disabled?: boolean;
  broken?: string; pending?: number; streaming?: boolean; pulse?: boolean;
};
export type ActivityRow = {
  time: string; token: string; actor: string; stage: string; reason: string;
  trigger?: string; seqs?: readonly string[];
};
type Current = { phase: string; count: number; kind: string };
type Result = { time: string; label: string };
const kinds = new Set(["signal", "stale", "heartbeat", "check", "continuation"]);
const expected = new Set(["ineligible-trigger", "check-main-only", "decision-owned", "unresolved-task",
  "no-eligible-rows", "branch-busy", "ida-result-busy", "ida-row-not-owned", "reset-in-progress", "away-mode", "afk", "afk-active"]);
const reasons = new Set([...expected, "ownership-lost", "main-owned", "fleet-lock-lost", "provider-failed",
  "reconcile-failed", "scope-changed", "generation-changed", "branch-settlement-failed", "no-durable-report",
  "handling-failed", "continuation-failed", "corrupt-queue", "not-lock-owner", "branch-broken",
  "branch-disabled", "no-listener", "construction-unhealthy", "provider-unhealthy", "reconcile-unhealthy", "mirror-collection-failed", "reconcile-backoff", "provider-backoff", "main-delivery-failed"]);
function safeReason(value: string): string { return reasons.has(value) ? value : "unclassified"; }
function stamp(value: string): string { return Number.isFinite(Date.parse(value)) ? new Date(value).toISOString() : "unknown"; }
export class BranchActivity {
  health: ActivityHealth | null = null;
  pulseAt = 0;
  active = new Map<string, Current>();
  completed: Result | null = null;
  fallback: Result | null = null;
  failure: Result | null = null;
  private failureToken = "";
  private classifications = new Map<string, string>();
  overflow = false;
  observeHealth(value: ActivityHealth): void {
    if (!value || !Number.isFinite(value.time) || !Number.isSafeInteger(value.generation)) return;
    if (value.pulse) {
      if (this.health?.generation === value.generation) this.pulseAt = value.time;
      return;
    }
    if (this.health && value.generation !== this.health.generation) { this.active.clear(); this.pulseAt = 0; }
    this.health = { ...value };
  }
  observe(row: ActivityRow, history = false): void {
    if (!row || typeof row.stage !== "string" || typeof row.reason !== "string" ||
      typeof row.token !== "string" || row.token.length > 96 || !Number.isFinite(Date.parse(row.time))) return;
    const time = stamp(row.time);
    if (row.stage === "classify") {
      this.classifications.set(row.token, safeReason(row.reason));
      if (this.classifications.size > 16) this.classifications.delete(this.classifications.keys().next().value!);
    }
    if (row.actor === "branch" && row.stage === "settlement" &&
      ["reported-and-released", "reported-continuation"].includes(row.reason)) {
      this.completed = { time, label: "durable branch result" };
      this.failure = null;
      this.failureToken = "";
    }
    if (row.stage === "fallback" || row.stage === "declined" || row.stage === "failure") {
      const label = row.stage === "declined" && row.reason === "ineligible-trigger"
        ? this.classifications.get(row.token) ?? safeReason(row.reason) : safeReason(row.reason);
      const result = { time, label };
      if (row.stage === "failure" || (row.stage === "fallback" && !expected.has(row.reason) && this.failureToken !== row.token)) {
        this.failure = result;
        this.failureToken = row.token;
      }
      if (row.stage !== "failure") this.fallback = result;
    }
    if (row.stage === "main-delivery" && row.reason === "main-delivery-failed") {
      this.failure = { time, label: "main-delivery-failed" };
    }
    if (["settlement", "fallback", "declined", "failure"].includes(row.stage)) this.classifications.delete(row.token);
    if (history) return; // A historical admission never proves current activity.
    if (row.actor === "branch" && row.stage === "admission") {
      if (this.active.size >= 16 && !this.active.has(row.token)) { this.overflow = true; return; }
      this.active.set(row.token, { phase: "accepted (not prompted)",
        count: Math.min(row.seqs?.length ?? 0, 64), kind: kinds.has(row.trigger ?? "") ? row.trigger! : "wake" });
    }
    const current = this.active.get(row.token);
    if (current && row.actor === "branch" && row.stage === "prompt" && row.reason === "started") current.phase = "model/tools";
    if (["settlement", "fallback", "declined", "failure"].includes(row.stage)) this.active.delete(row.token);
  }
  view(now = Date.now()): { state: string; lines: string[] } {
    const h = this.health;
    const stale = !h || now - Math.max(h.time, this.pulseAt) > ACTIVITY_STALE_MS;
    const state = stale ? "unknown" : h?.disabled ? "disabled" : this.overflow || !h?.owned ? "unknown" :
      h.broken && h.broken !== "none" ? "error" : this.active.size ? "processing" :
      this.failure ? "degraded" : h.streaming || (h.pending ?? 0) > 0 ? "unknown" : "idle";
    const first = this.active.values().next().value as Current | undefined;
    const item = first ? `${first.kind}, ${first.count === 64 ? "64+" : first.count || (first.kind === "continuation" ? 1 : "?")} item(s), ${first.phase}` : "none observed";
    const last = this.completed ? `${this.completed.time} durable branch result` : "unknown (no completion evidence)";
    const fallback = this.fallback ? `${this.fallback.time} MAIN: ${this.fallback.label}` : "none observed";
    const failure = this.failure ? `${this.failure.time} ${this.failure.label}` :
      ["construction", "reconcile", "provider"].includes(h?.broken ?? "") ? `${h!.broken} unhealthy` : "none observed";
    const freshness = stale ? "stale/missing; /supervision-status refreshes health" : h?.owned ? "current process observation" : "lock ownership unconfirmed";
    const summary = `Branch ${state} | ${first ? item : this.failure ? this.failure.label : this.completed ? "last result " + this.completed.time.slice(11, 19) + "Z" : "result unknown"}`;
    return { state, lines: [summary, `Current: ${item}; ${this.active.size} batch(es)`,
      `Completed: ${last}`, `Fallback: ${fallback}`, `Error: ${failure}`, `Evidence: ${freshness}`] };
  }
}
