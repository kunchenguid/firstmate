export type FooterView = "action" | "work";
export type FooterStatus = "Working" | "Attention" | "Done" | "Waiting" | "Queued" | "Unknown";

export type FooterCounts = Record<"Working" | "Attention" | "Done" | "Waiting" | "Queued", number>;

export type TaskCard = {
  ref: string;
  name: string;
  status: FooterStatus;
  summary: [string, string];
  next: string;
};

export type FooterProjection = {
  counts: FooterCounts;
  cards: TaskCard[];
};

type Candidate = {
  id: string;
  title?: string;
  state?: string;
  detail?: string;
  backlogState?: string;
  reason?: string;
  pendingDecision?: boolean;
  blockedEvent?: boolean;
  status?: FooterStatus;
};

const EMPTY_COUNTS = (): FooterCounts => ({
  Working: 0,
  Attention: 0,
  Done: 0,
  Waiting: 0,
  Queued: 0,
});

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function boolValue(value: unknown): boolean {
  return value === true;
}

function candidateFromTask(value: unknown): Candidate | null {
  if (!isRecord(value)) return null;
  const id = stringValue(value.id);
  if (!id) return null;
  const current = isRecord(value.current_state) ? value.current_state : {};
  const backlog = isRecord(value.backlog) ? value.backlog : {};
  const hints = isRecord(value.hints) ? value.hints : {};
  return {
    id,
    title: stringValue(backlog.title),
    state: stringValue(current.state),
    detail: stringValue(current.detail),
    backlogState: stringValue(backlog.state),
    reason: stringValue(backlog.hold_reason) ?? stringValue(backlog.blocked_reason),
    pendingDecision: boolValue(hints.pending_decision),
    blockedEvent: boolValue(hints.blocked_event),
  };
}

function candidateFromBacklog(value: unknown): Candidate | null {
  if (!isRecord(value) || value.structured !== true) return null;
  const id = stringValue(value.id);
  if (!id) return null;
  return {
    id,
    title: stringValue(value.title),
    backlogState: stringValue(value.state),
    reason: stringValue(value.hold_reason) ?? stringValue(value.blocked_reason),
    pendingDecision: value.captain_actionable === true,
  };
}

function candidateFromSummary(value: unknown, status: FooterStatus): Candidate | null {
  if (!isRecord(value)) return null;
  const id = stringValue(value.id);
  if (!id) return null;
  return {
    id,
    title: stringValue(value.title) ?? stringValue(value.name),
    reason: stringValue(value.reason) ?? stringValue(value.blocked_reason) ?? stringValue(value.hold_reason),
    status,
  };
}

function statusFor(candidate: Candidate): FooterStatus {
  if (candidate.status) return candidate.status;
  if (candidate.pendingDecision || candidate.blockedEvent) return "Attention";
  if (candidate.state === "failed" || candidate.state === "blocked" || candidate.state === "parked") {
    return "Attention";
  }
  if (candidate.state === "unknown") return "Unknown";
  if (candidate.state === "done" || candidate.backlogState === "done") return "Done";
  if (candidate.state === "working") return "Working";
  if (candidate.state === "paused") return "Waiting";
  if (candidate.backlogState === "queued") return "Queued";
  if (candidate.state === "waiting") return "Waiting";
  if (candidate.backlogState === "in_flight") return "Unknown";
  return "Unknown";
}

function safeDetail(detail: string | undefined, fallback: string): string {
  if (!detail || /\b(?:worker|model|branch|worktree|checkout)\b|torn down|%|\d{4}-\d{2}-\d{2}T\d{2}/i.test(detail)) return fallback;
  return detail.replace(/\s+/g, " ").trim() || fallback;
}

function titleFor(candidate: Candidate): string {
  return candidate.title ?? candidate.id;
}

function summaryFor(candidate: Candidate, status: FooterStatus): [string, string] {
  const title = titleFor(candidate);
  const fallback = {
    Working: "Active work is under way.",
    Attention: "Needs captain attention.",
    Done: "Completed; ready to close.",
    Waiting: "Waiting for an external event.",
    Queued: "Queued for work.",
    Unknown: "Current state is unavailable.",
  }[status];
  return [title, safeDetail(candidate.reason ?? candidate.detail, fallback)];
}

function nextFor(candidate: Candidate, status: FooterStatus): string {
  if (status === "Attention") {
    if (candidate.pendingDecision) return "Review the open decision.";
    if (candidate.state === "failed") return "Inspect the failed work.";
    if (candidate.state === "unknown") return "Inspect the live state.";
    return "Review or unblock this task.";
  }
  if (status === "Done") return "Review and close it.";
  if (status === "Waiting") return "Wait for the external event.";
  if (status === "Queued") return "Start when ready.";
  if (status === "Working") return "Monitor active work.";
  return "Inspect the live state.";
}

const STATUS_PRIORITY: Record<FooterStatus, number> = {
  Unknown: 1,
  Queued: 2,
  Waiting: 3,
  Working: 4,
  Done: 5,
  Attention: 6,
};

function mergeCandidate(existing: Candidate, incoming: Candidate): Candidate {
  const existingStatus = statusFor(existing);
  const incomingStatus = statusFor(incoming);
  return STATUS_PRIORITY[incomingStatus] > STATUS_PRIORITY[existingStatus]
    ? { ...existing, ...incoming }
    : { ...incoming, ...existing };
}

function unknownProjection(reason = "Fleet state is unavailable."): FooterProjection {
  return {
    counts: { Working: 0, Attention: 1, Done: 0, Waiting: 0, Queued: 0 },
    cards: [{
      ref: "T01",
      name: "fleet-state",
      status: "Unknown",
      summary: [reason, "No live state was guessed."],
      next: "Retry the fleet read.",
    }],
  };
}

export function projectSnapshot(value: unknown): FooterProjection {
  if (!isRecord(value) || value.schema !== "fm-fleet-snapshot.v1") return unknownProjection();
  if (isRecord(value.main_inventory) && value.main_inventory.valid === false) {
    return unknownProjection("Fleet inventory needs attention.");
  }
  if (isRecord(value.secondmate_current) && value.secondmate_current.available === false) {
    return unknownProjection("Registered fleet state is unavailable.");
  }

  const candidates = new Map<string, Candidate>();
  const add = (candidate: Candidate | null): void => {
    if (!candidate) return;
    const prior = candidates.get(candidate.id);
    candidates.set(candidate.id, prior ? mergeCandidate(prior, candidate) : candidate);
  };

  const tasks = Array.isArray(value.tasks) ? value.tasks : [];
  const backlog = isRecord(value.backlog) && Array.isArray(value.backlog.records) ? value.backlog.records : [];
  for (const task of tasks) add(candidateFromTask(task));
  for (const record of backlog) add(candidateFromBacklog(record));

  const homes = isRecord(value.secondmate_current) && Array.isArray(value.secondmate_current.records)
    ? value.secondmate_current.records
    : [];
  for (const home of homes) {
    if (!isRecord(home)) continue;
    const groups: [string, FooterStatus][] = [
      ["active_children", "Working"],
      ["decisions_open", "Attention"],
      ["holds", "Waiting"],
      ["queued", "Queued"],
      ["landed", "Done"],
    ];
    for (const [key, status] of groups) {
      const records = Array.isArray(home[key]) ? home[key] : [];
      for (const record of records) add(candidateFromSummary(record, status));
    }
  }

  const ordered = [...candidates.values()].sort((left, right) => left.id < right.id ? -1 : left.id > right.id ? 1 : 0);
  const counts = EMPTY_COUNTS();
  const cards = ordered.map((candidate, index) => {
    const status = statusFor(candidate);
    if (status === "Unknown") counts.Attention += 1;
    else counts[status] += 1;
    return {
      ref: `T${String(index + 1).padStart(2, "0")}`,
      name: candidate.id,
      status,
      summary: summaryFor(candidate, status),
      next: nextFor(candidate, status),
    } satisfies TaskCard;
  });
  return { counts, cards };
}

export function projectionForError(reason: string): FooterProjection {
  return unknownProjection(reason || "Fleet state is unavailable.");
}

export function cardsForView(projection: FooterProjection, view: FooterView): TaskCard[] {
  return projection.cards.filter((card) => view === "action"
    ? card.status === "Attention" || card.status === "Unknown" || card.status === "Done"
    : card.status === "Working" || card.status === "Waiting" || card.status === "Queued");
}

export function pageCount(projection: FooterProjection, view: FooterView, pageSize = 6): number {
  return Math.max(1, Math.ceil(cardsForView(projection, view).length / pageSize));
}
