// One owner for the supervision-branch report and acknowledgement decision
// core, shared by the Pi supervision-branch extension
// (.pi/extensions/fm-branch-supervision.ts) and the Claude Code
// supervision-branch mod (.claude/mods/fm-branch-mod/hooks/branch.ts).
//
// This module owns, once, the rules that both adapters previously restated:
// the fm_branch_report argument validation rule, the task-in-scope rule for
// reports during a task-scoped wake, the fm_branch_processed "safe positive
// sequence number" rule, the exact argv of the bin/fm-branch-outcome.sh store
// calls (append, mark-read, mark-processed), the settlement call ORDER, and
// the meaning of each settlement failure.
//
// Host seams - the refusal and failure STRINGS, unified but still host-
// rendered (firstmate's A4 decision kept them per-host; the captain's
// 2026-09-20 ruling then unified them on the mod's wording and shape):
//   - The task-in-scope refusal text, the through-validation refusal text,
//     the mark-read failure text, the mark-processed failure text, and the
//     processed success text are byte-identical across both hosts now, and
//     the task-in-scope refusal is a normal tool result carrying the
//     corrective re-report instruction on BOTH hosts (the Pi extension no
//     longer renders it as an isError result). They stay rendered host-side
//     because the mod's hooks source is the adopted original and its bytes
//     are frozen; no module constant exists for them, so the tests pin the
//     bytes instead: tests/fm-branch-report-sequence.test.sh pins the mod's
//     and tests/fm-pi-branch-extension.test.sh pins the same bytes against
//     the real Pi extension. The strings owned here as constants (the
//     invalid-report refusal, the append-failure refusal, the report success
//     line) cannot drift by construction.
//   - Parameter coercion preambles. Each host coerces raw tool-call input
//     into primitives its own way (trimming, Number() coercion) before
//     calling the rules here; those few lines stay host-side so pathological
//     inputs keep each host's historical verdict.
//   - The mod's --wake-key argv extension and duplicate-report guard are mod
//     delivery mechanics and stay host-side (extraArgs below).
//   - The latch failure predicate belongs to lib/fm-branch-provider-latch.ts
//     (unified there by the same ruling), not to this file.
//
// The mod loads this file directly from its own lib/ directory; the repo's
// lib/ entry is a tracked symlink to it (the Calm-mod pattern, inverted
// because a hooks module may import only its own files, never across the
// mod boundary). This file must therefore stay dependency-free: no imports
// of any kind.

export type BranchVerdict = "routine" | "captain";

// The module-owned strings that are byte-identical across both hosts today.
export const INVALID_REPORT_MESSAGE = "invalid report: task, verdict (routine|captain), and summary are required";

export function appendFailureMessage(detail: string): string {
  return `outcome store append failed (nothing merged): ${detail}`;
}

export function reportSuccessMessage(seq: string | number, verdict: BranchVerdict): string {
  return `recorded seq ${seq} and delivered [${verdict}] into main`;
}

// The report the rules below judge: already coerced from raw tool-call input
// by the calling host (see the coercion-preamble seam in the header).
export interface BranchReportInput {
  task: string;
  verdict: string;
  summary: string;
  silent: boolean;
}

export type ValidatedBranchReport =
  | { valid: true; task: string; verdict: BranchVerdict; summary: string; silent: boolean }
  | { valid: false; message: string };

// The fm_branch_report argument rule, stated once: a non-empty task, a
// non-empty summary, a verdict of routine or captain, and a silent flag only
// on a fleet-wide routine report.
export function validateBranchReport(report: BranchReportInput): ValidatedBranchReport {
  const verdict: BranchVerdict | null = report.verdict === "routine" || report.verdict === "captain" ? report.verdict : null;
  if (report.task === "" || report.summary === "" || verdict === null || (report.silent && (report.task !== "fleet" || report.verdict !== "routine"))) {
    return { valid: false, message: INVALID_REPORT_MESSAGE };
  }
  return { valid: true, task: report.task, verdict, summary: report.summary, silent: report.silent };
}

// The task scope a host is enforcing while it handles one wake: the wake's
// own row sequence numbers and the exact task ids those rows name. Null
// whenever the host is not scoped by task (no wake, heartbeat and check
// wakes, the mod's heartbeat-flagged request).
export interface WakeTaskScope {
  rows: string[];
  tasks: string[];
}

export type TaskScopeVerdict =
  | { allowed: true }
  | { allowed: false; task: string; tasks: string[]; rows: string[] };

// The task-in-scope rule, stated once: during a task-scoped wake a report
// may only name a task the wake's own rows resolve to; an unscoped host
// accepts any task. The refusal TEXT is unified across the hosts (see the
// header) but stays host-rendered.
export function reportTaskScopeVerdict(scope: WakeTaskScope | null, task: string): TaskScopeVerdict {
  if (!scope || scope.tasks.includes(task)) return { allowed: true };
  return { allowed: false, task, tasks: [...scope.tasks], rows: [...scope.rows] };
}

// The argv of the durable outcome-store append for one accepted report, in
// the exact byte order both hosts emit today. `wake` is the optional wake
// reason line; `extraArgs` carries host-only argv extensions (the mod's
// --wake-key), always appended last.
export function reportAppendArgv(
  report: { task: string; verdict: BranchVerdict; summary: string; silent: boolean },
  wake: string | null,
  extraArgs?: string[],
): string[] {
  const argv = ["append", "--task", report.task, "--verdict", report.verdict, "--summary", report.summary, "--silent", String(report.silent)];
  if (wake) argv.push("--wake", wake);
  if (extraArgs) argv.push(...extraArgs);
  return argv;
}

export function markReadArgv(seq: string | number): string[] {
  return ["mark-read", "--through", String(seq)];
}

export function markProcessedArgv(through: string | number): string[] {
  return ["mark-processed", "--through", String(through)];
}

// The store's append stdout is the new row's sequence number; anything that
// is not a safe positive integer is not a usable sequence.
export function parseOutcomeSeq(stdout: string): number | null {
  const seq = Number(stdout);
  return Number.isSafeInteger(seq) && seq >= 1 ? seq : null;
}

// The fm_branch_processed rule, stated once: a through value must be a safe
// positive integer. The coercion of raw tool input into a number stays
// host-side (see the header); the refusal TEXT is unified across the hosts
// but stays host-rendered.
export function validateThroughValue(through: number): boolean {
  return Number.isSafeInteger(through) && through >= 1;
}

// The settlement call ORDER and failure MEANINGS, stated once: a report is
// durable (append) BEFORE it is delivered or its read cursor advances
// (mark-read); a captain acknowledgement advances the processed marker
// (mark-processed). A failed append means nothing was recorded and nothing
// may be delivered; a failed mark-read means the row IS recorded but its
// delivery or cursor advance failed; a failed mark-processed means the
// acknowledgement did not land. These meanings live here as the shared
// contract the hosts' rendered failure strings carry.

export interface OutcomeCallResult {
  ok: boolean;
  stdout: string;
  detail: string;
}

export type OutcomeRunner = (argv: string[]) => Promise<OutcomeCallResult>;

export type SettlementStepResult = { ok: true; stdout: string } | { ok: false; detail: string };

// Runs one settlement step through the host's outcome runner in the module's
// call order - the argv builder already names the step - so both adapters
// share the same settlement path instead of restating it.
export async function runSettlementStep(run: OutcomeRunner, argv: string[]): Promise<SettlementStepResult> {
  const result = await run(argv);
  if (result.ok) return { ok: true, stdout: result.stdout };
  return { ok: false, detail: result.detail };
}
