// One owner for the supervision-branch mod's text builders and text-shaped
// parses (.claude/mods/fm-branch-mod/hooks/branch.ts is the Claude Code
// binding that renders them): the Stop-hook rewake banner, the reason-line
// filter every wake routing starts from, the monitor-event reason parse, the
// task-notice id parse, the deterministic new-status-lines note, the
// processing request main renders for a captain outcome, the Bash actor
// rewrite command, the Stop-hook wake predicate, the tool-result text
// coercion, and the version pin's probe parsing.
//
// Host seams - declared, not unified: every function here is pure except
// newStatusLinesNote, which reads two state files per task through an
// injected readFile that throws when a path is missing (exactly the
// $.fs.read contract the mod binds). The rendered bytes are byte-stable:
// tests/fm-branch-text.test.sh pins them and the engine suite
// (tests/branch.test.ts inside the mod) pins the binding end to end.
//
// The mod loads this file directly from its own lib/ directory; the repo's
// lib/ entry is a tracked symlink to it (the Calm-mod pattern, inverted
// because a hooks module may import only its own files, never across the
// mod boundary). This file must therefore stay dependency-free: no imports
// of any kind.

/** The actionable reason lines of one wake text: signal, stale, check, and
 * heartbeat lines, trimmed, in order. Everything else (alarm notices,
 * failure text, prose) is not a reason. */
export function reasonLines(text: string): string[] {
  return text
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => /^(signal:|stale:|check:|heartbeat($|:))/.test(l))
}

/** Rewake banner in the Stop hook's own shape, so a wake main must take
 * reaches it exactly as the hook would have delivered it. */
export function rewakeBanner(reason: string): string {
  return (
    `<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>\n<system-reminder>\n` +
    `Stop hook blocking error from command "Stop": firstmate watcher wake - one supervision event needs a handling turn now.\n${reason}\n` +
    `Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n</system-reminder>`
  )
}

/** The pure parse of one monitor event notification: whether it is ours
 * (carries the monitor description), whether the monitor expired (an
 * expiry or rotate notice rode the event stream), and the actionable
 * reason lines its events carry. The host logs and renders the banner. */
export function parseMonitorEvent(text: string, description: string): { ours: boolean; expired: boolean; reasons: string[] } {
  const ours = text.includes(description)
  if (!ours) return { ours: false, expired: false, reasons: [] }
  // Events arrive as <event>line</event> blocks; the expiry notice arrives
  // as an event too: `<event>[Monitor expired after 30m with N events
  // delivered. ...]</event>`.
  const all = [...text.matchAll(/<event>([\s\S]*?)<\/event>/g)].map((m) => m[1])
  const events = all.filter((t) => !/^\s*(\[Monitor |rotate:)/.test(t))
  const expired = all.length === 0 || events.length < all.length
  const reasons = reasonLines(events.join('\n'))
  return { ours: true, expired, reasons }
}

/** The task id of a task-notification text, or '' when it names none. */
export function taskNoticeId(text: string): string {
  return text.match(/<task-id>([a-z0-9]+)<\/task-id>/)?.[1] ?? ''
}

/** A prompt is one Stop-hook watcher wake exactly when it carries the Stop
 * hook feedback summary and the watcher wake marker. */
export function isStopHookWakeText(text: string): boolean {
  return /<summary>Stop hook feedback<\/summary>/.test(text) && /firstmate watcher wake/.test(text)
}

/** The file-read seam of the deterministic note: same contract as the
 * mod's $.fs.read - resolves with the file's text, rejects when missing. */
export interface StatusNoteDeps {
  readFile(path: string): Promise<string>
}

/** Deterministic note of the status lines appended since each task's last
 * outcome: per task, the outcome index names the byte endpoint and the seq
 * of that outcome, the status log is sliced from the endpoint, and at most
 * the last 12 non-empty lines ride the note. A missing index reads as "no
 * earlier outcome"; a missing status log reads as no new lines. */
export async function newStatusLinesNote(deps: StatusNoteDeps, state: string, tasks: string[]): Promise<string> {
  const parts: string[] = []
  for (const task of tasks) {
    let endpoint = 0
    let lastSeq = ''
    try {
      const idx = (await deps.readFile(`${state}/.${task}.branch-outcome-index`)).split('\t')
      if (idx[0] === 'fm-branch-outcome-index-v1' && /^[0-9]+$/.test(idx[2] ?? '')) {
        endpoint = Number(idx[2])
        lastSeq = idx[1]
      }
    } catch {
      endpoint = 0
    }
    let text = ''
    try {
      text = await deps.readFile(`${state}/${task}.status`)
    } catch {
      text = ''
    }
    const fresh = text
      .slice(endpoint)
      .split('\n')
      .filter((l: string) => l.trim())
      .slice(-12)
    if (!lastSeq) parts.push(`No earlier outcome exists for ${task}: the whole status log is new for this wake.`)
    else parts.push(`Status lines of ${task} appended since your last outcome (seq ${lastSeq}):\n` + (fresh.length ? fresh.map((l: string) => `  ${l}`).join('\n') : '  (none - only a turn-end or pane signal)'))
  }
  return parts.length ? `\n\n${parts.join('\n\n')}` : ''
}

/** Processing request for main: exactly one main turn per captain outcome. */
export function processingRequest(seq: number, task: string, summary: string, source: string): string {
  return (
    `This is a supervision processing request delivered automatically by the supervision branch (${source}). It was not typed by the captain. ` +
    `The outcome below is already stored durably; the fleet event is already handled, so do not re-drain, re-run, or acknowledge the wake. ` +
    `Process it now as firstmate: tell the captain the outcome in one sentence. ` +
    `Then call fm_branch_processed with through=${seq} exactly once.\n\n[seq ${seq}] ${task}: ${summary}`
  )
}

/** The text a tool result or tool call answers with, coerced: the text
 * field, else the result field, else ''. */
export function toolText(r: any): string {
  return String(r?.text ?? r?.result ?? '')
}

/** The Bash command prefix that carries the branch actor identity: the
 * supervision actor, the lease holder pid ('' means the shell's own $$),
 * and the home overrides, wrapped around the original command. */
export function bashActorCommand(command: string, holder: string, paths: { home: string; state: string; config: string }): string {
  return `export FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=${holder || '$$'} FM_HOME=${JSON.stringify(paths.home)} FM_STATE_OVERRIDE=${JSON.stringify(paths.state)} FM_CONFIG_OVERRIDE=${JSON.stringify(paths.config)}\n(\n${command}\n)`
}

/** The first whitespace-delimited token of a version probe's output. */
export function versionToken(text: string): string {
  return text.split(/\s+/)[0] ?? ''
}

/** The version-pin shape test: a token is a version exactly when it opens
 * with three dot-separated numbers. */
export function isVersionShaped(version: string): boolean {
  return /^\d+\.\d+\.\d+/.test(version)
}
