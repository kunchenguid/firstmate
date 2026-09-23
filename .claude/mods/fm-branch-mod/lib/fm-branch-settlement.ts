// One owner for the supervision-branch mod's session and settlement rules:
// the deterministic main-side backstop after a routine branch outcome, the
// transcript-persistence rule read from two environment values, the session
// counters record (build, parse, and the same-lock apply verdict), and the
// branch turn's usage fold with its context-bound rotation verdict.
// .claude/mods/fm-branch-mod/hooks/branch.ts is the Claude Code binding.
//
// The backstop, stated once: after the branch marks a wake routine,
// bin/fm-wake-evidence.sh --routine-covered names every captain-facing
// status line that wake covered; each such line is delivered to main as a
// deterministic prompt (the drain's STATUS OUTCOME BACKSTOP section names
// the same line), and a failed delivery is logged, never thrown.
//
// The transcript-persistence rule, stated once (Row 3 of the branch-reuse
// RCA, 2026-09-19: the next transcript regression must be one log line
// instead of a scout): persistence is off when the session inherited the
// CLAUDE_CODE_CHILD_SESSION marker (a Herdr server started inside a
// Claude session hands it to every pane) and back on when
// CLAUDE_CODE_FORCE_SESSION_PERSISTENCE is set; the launch-option and
// test-env disable causes are not visible to a hook, so their absence
// reads as default. The two environment reads stay host-side: the
// hooks-module validator lists the environment a module reads from the
// literal $.env.get call sites.
//
// The counters record, stated once: session counters survive a module
// reload (/reload-plugins) bound to the session lock pid, so a genuinely
// new session starts at zero; the field order is pinned because the
// engine suite reads the file. The usage fold, stated once: the branch is
// bounded inside the mod - once a wake's per-step request context (the
// turn's summed usage over its steps) passes the rotation bound, the next
// wake goes to a fresh agent seeded with the index note.
//
// Host seams - declared, not unified: the evidence-covered runner, the
// main prompt submission, and logging for the backstop; plain data in
// and plain data out for the rest. The decision order, the verdict
// strings, the record shape, and the log event names and payloads are
// byte-stable: tests/fm-branch-settlement.test.sh pins them through both
// the module and the mod's exported binding, and the engine suite
// (tests/branch.test.ts inside the mod) pins the binding end to end.
//
// The mod loads this file directly from its own lib/ directory; the repo's
// lib/ entry is a tracked symlink to it (the Calm-mod pattern, inverted
// because a hooks module may import only its own files, never across the
// mod boundary). This file must therefore stay dependency-free: no imports
// of any kind.

/** Once a wake's per-step request context passes this many tokens, the
 * next wake goes to a fresh branch agent. */
export const BRANCH_ROTATE_TOKENS = 60_000

export interface BackstopDeps {
  log(kind: string, data: unknown): void
  /** Runs bin/fm-wake-evidence.sh --routine-covered for one task. */
  runCovered(task: string): Promise<{ exitCode: number; stdout: string; stderr: string }>
  /** Submits one prompt to main ($.prompt.submit); rejects on failure. */
  submitPrompt(text: string): Promise<void>
}

/** The deterministic main-side backstop after a routine branch outcome:
 * for each task the wake covered, deliver every captain-facing status
 * line the routine verdict absorbed as a main prompt. */
export async function backstopCheck(deps: BackstopDeps, tasks: Iterable<string>, wakeNo: number): Promise<void> {
  for (const task of tasks) {
    const r = await deps.runCovered(task)
    const lines = String(r.stdout)
      .split('\n')
      .filter((l: string) => l.trim())
    deps.log('backstop.check', { task, wakeNo, rc: r.exitCode, lines, stderr: String(r.stderr).slice(0, 200) })
    if (lines.length === 0) continue
    const text =
      `Supervision backstop (deterministic, delivered automatically by fm-branch-mod, not typed by the captain): the supervision branch marked a wake of task ${task} routine, but the status log carries ${lines.length} captain-facing line(s) it covered:\n` +
      lines.map((l: string) => `  ${l.split('\t').slice(1).join('\t')}`).join('\n') +
      `\n\nRun bin/fm-wake-drain.sh (its STATUS OUTCOME BACKSTOP section names the same line), tell the captain the outcome in one sentence, then run the exact --ack-through command it printed.`
    try {
      await deps.submitPrompt(text)
      deps.log('backstop.delivered', { task, wakeNo, lines })
    } catch (error) {
      deps.log('backstop.error', { task, wakeNo, error: String(error) })
    }
  }
}

/** The transcript-persistence rule over the two environment values the
 * host read (empty string when unset). */
export function transcriptPersistenceFromEnv(force: string, marker: string): { on: boolean; cause: string } {
  if (force) return { on: true, cause: 'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE' }
  if (marker) return { on: false, cause: 'inherited CLAUDE_CODE_CHILD_SESSION marker' }
  return { on: true, cause: 'default' }
}

/** The counters record's fields, in the pinned save order. */
export interface CountersFields {
  lockPid: string
  wakeCounter: number
  spawnCount: number
  sendCount: number
  generation: string
  branchGeneration: number
  branchRef: string
  branchAgentId: string
  monitorTaskId: string
  monitorArmedAt: number
}

/** The counters record text: one JSON object, field order pinned. */
export function buildCountersText(c: CountersFields): string {
  return JSON.stringify({ lockPid: c.lockPid, wakeCounter: c.wakeCounter, spawnCount: c.spawnCount, sendCount: c.sendCount, generation: c.generation, branchGeneration: c.branchGeneration, branchRef: c.branchRef, branchAgentId: c.branchAgentId, monitorTaskId: c.monitorTaskId, monitorArmedAt: c.monitorArmedAt })
}

/** Parses the counters record; null when it is unreadable (the host then
 * starts at zero). */
export function parseCountersRecord(raw: string): Record<string, any> | null {
  try {
    const j = JSON.parse(raw)
    return j && typeof j === 'object' ? j : null
  } catch {
    return null
  }
}

/** The same-session verdict: a record applies only when it names the
 * session lock pid the host reads now. */
export function countersApplyVerdict(j: { lockPid?: unknown }, pid: string): boolean {
  return Boolean(j.lockPid && j.lockPid === pid)
}

/** The branch turn's usage fold: the wake's summed request tokens over its
 * steps, and the per-step context that sum implies. */
export function wakeUsageFold(usage: Record<string, number> | undefined, stepsThisWake: number): { wakeTokens: number; stepContext: number } {
  const u = usage ?? {}
  const wakeTokens = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0)
  const stepContext = Math.ceil(wakeTokens / Math.max(stepsThisWake, 1))
  return { wakeTokens, stepContext }
}

/** The context-bound rotation verdict: rotate on the next delivery once
 * the per-step context passes the bound, and only once per crossing. */
export function rotateDue(stepContext: number, rotatePending: boolean): boolean {
  return stepContext > BRANCH_ROTATE_TOKENS && !rotatePending
}
