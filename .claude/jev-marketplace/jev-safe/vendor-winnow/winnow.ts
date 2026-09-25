/**
 * winnow's hooks: a Claude Code function-hook module ("Claude Mods", early access).
 *
 * Claude Code loads this file when it runs with CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1
 * (2.1.260 or newer); without the flag winnow does nothing, which `winnow doctor`
 * reports. The module wraps every Read, Bash and Grep call in-process: the result
 * goes to the resident sidecar (`winnow serve`) together with the task read from
 * the live session, and the sidecar's rewrite comes back as the tool's result.
 * At prompt time it asks the sidecar which context files the prompt needs and
 * appends them to the prompt's context.
 */
import type { EngineInterface, Register, SessionMessage } from 'claude-code'

/** The sidecar's port. Keep it equal to WINNOW_PORT. */
export const PORT = 47311
export const TOOLS = ['Read', 'Bash', 'Grep'] as const
/** Results shorter than this are never rewritten (the sidecar's WINNOW_MIN_CHARS default); skip the round trip. */
const MIN_CHARS = 1500
const TASK_CHARS = 1500

export type Task = { user_request: string; assistant_intent: string }

/** What the sidecar puts in its X-Winnow response header when it rewrote a result. */
export type Meta = { hidden?: number; blocks?: number; before?: number; after?: number; key?: string }

type HookOutput = {
  hookSpecificOutput?: { updatedToolOutput?: unknown; additionalContext?: string }
  systemMessage?: string // the sidecar's once-per-session notice when its judge cannot start
}

type ToolCallEvent = { tool: string; tool_use_id?: string; agentId?: string } & Record<string, unknown>

/**
 * The task a tool call serves: the last thing the human asked for and the last
 * thing the assistant said since. Mirrors the sidecar's `read_task`, which reads
 * the same two things from the transcript file; here they come from the live
 * session, so no transcript path is needed and a subagent sees its own task.
 */
export function taskFrom(messages: readonly SessionMessage[]): Task {
  let user = ''
  let assistant = ''
  for (const m of messages) {
    const text = m.text.trim()
    if (m.role === 'user') {
      if (m.toolResults !== undefined && m.toolResults.length > 0) continue // a tool-result turn, not the human
      if (text !== '') {
        user = text
        assistant = ''
      }
    } else if (text !== '') {
      assistant = text
    }
  }
  return { user_request: head(user, TASK_CHARS), assistant_intent: tail(assistant, TASK_CHARS) }
}

/** A long request says what to do in its first lines. */
export function head(text: string, limit: number): string {
  return text.length <= limit ? text : text.slice(0, limit - 1).trimEnd() + '…'
}

/** A long assistant message says what it will do next at its end. */
export function tail(text: string, limit: number): string {
  return text.length <= limit ? text : '…' + text.slice(-(limit - 1)).trimStart()
}

export function describeMeta(tool: string, meta: Meta): string {
  const k = (n: number | undefined) =>
    n === undefined ? '?' : n >= 10_000 ? `${Math.round(n / 1000)}k` : n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n)
  const key = meta.key === undefined ? '' : `; winnow_recall ${meta.key}`
  return `winnow: hid ${meta.hidden ?? '?'} of ${meta.blocks ?? '?'} blocks of ${tool} (${k(meta.before)} to ${k(meta.after)} chars${key})`
}

async function post(
  $: EngineInterface,
  url: string,
  payload: unknown,
): Promise<{ output: HookOutput | undefined; meta: Meta | undefined } | undefined> {
  let res
  try {
    const gate = await $.http.fetch('http://127.0.0.1:48752/check', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(payload),
    })
    if (!gate.ok || JSON.parse(gate.text).allowed !== true) {
      $.ui.log('winnow: safety gate blocked or unavailable; preserving original output', { to: 'debug' })
      return undefined
    }
    res = await $.http.fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(payload),
    })
  } catch (err) {
    $.ui.log(`winnow: sidecar not answering at ${url}: ${String(err)}`, { to: 'debug' })
    return undefined
  }
  if (!res.ok) {
    $.ui.log(`winnow: sidecar answered ${res.status} at ${url}`, { to: 'debug' })
    return undefined
  }
  let meta: Meta | undefined
  const raw = res.headers['x-winnow']
  if (raw !== undefined) {
    try {
      meta = JSON.parse(raw) as Meta
    } catch {
      meta = undefined
    }
  }
  if (res.text.trim() === '') return { output: undefined, meta } // empty 2xx: pass-through
  try {
    return { output: JSON.parse(res.text) as HookOutput, meta }
  } catch {
    $.ui.log('winnow: sidecar sent something that is not JSON', { to: 'debug' })
    return undefined
  }
}

async function whereami($: EngineInterface): Promise<{ session_id: string; cwd: string }> {
  const [session_id, cwd] = await Promise.all([$.session.id().catch(() => ''), $.session.cwd().catch(() => '')])
  return { session_id, cwd }
}

export const register: Register = (on) => {
  const base = `http://127.0.0.1:${PORT}`

  for (const tool of TOOLS) {
    on('tool.call', { tool }, async ($, e, next) => {
      const answer = await next(e)
      if (!('result' in answer) || answer.result === undefined) return answer
      if (JSON.stringify(answer.result).length < MIN_CHARS) return answer

      const { tool: toolName, tool_use_id, agentId, ...input } = e as ToolCallEvent
      const [messages, where] = await Promise.all([$.session.messages().catch(() => [] as SessionMessage[]), whereami($)])
      const res = await post($, `${base}/hook/post-tool-use`, {
        hook_event_name: 'PostToolUse',
        source: 'function-hook',
        ...where,
        agent_id: agentId,
        tool_name: toolName,
        tool_input: input,
        tool_response: answer.result,
        tool_use_id,
        task: taskFrom(messages),
      })
      if (typeof res?.output?.systemMessage === 'string') $.ui.toast(res.output.systemMessage)
      const updated = res?.output?.hookSpecificOutput?.updatedToolOutput
      if (updated === undefined) return answer
      if (res?.meta !== undefined) $.ui.toast(describeMeta(toolName, res.meta))
      return { ...answer, result: updated }
    })
  }

  on('prompt.submit', async ($, e, next) => {
    if (e.text.trim().length < 12) return next(e)
    const where = await whereami($)
    const res = await post($, `${base}/hook/user-prompt-submit`, {
      hook_event_name: 'UserPromptSubmit',
      source: 'function-hook',
      ...where,
      prompt: e.text,
    })
    if (typeof res?.output?.systemMessage === 'string') $.ui.toast(res.output.systemMessage)
    const extra = res?.output?.hookSpecificOutput?.additionalContext
    if (typeof extra !== 'string' || extra === '') return next(e)
    return next({ ...e, context: [...(e.context ?? []), extra] })
  })
}
