/**
 * winnow's hooks: a Claude Code function-hook module ("Claude Mods", early access).
 *
 * Claude Code loads this file when it runs with CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1
 * (2.1.260 or newer); without the flag winnow does nothing, which `winnow doctor`
 * reports. The module wraps every Read, Bash and Grep call in-process: the result
 * goes to the resident sidecar (`winnow serve`) together with the task read from
 * the live session, and the sidecar's rewrite comes back as the tool's result.
 */
import type { EngineInterface, Register } from 'claude-code'
import { safetyAllows } from '../../../jev-safety/client.mjs'

/** The sidecar's port. Keep it equal to WINNOW_PORT. */
export const PORT = 47311
export const TOOLS = ['Read', 'Bash', 'Grep'] as const
/** Results shorter than this are never rewritten (the sidecar's WINNOW_MIN_CHARS default); skip the round trip. */
const MIN_CHARS = 1500

export type Task = { user_request: string; assistant_intent: string }

/** What the sidecar puts in its X-Winnow response header when it rewrote a result. */
export type Meta = { hidden?: number; blocks?: number; before?: number; after?: number; key?: string }

type HookOutput = {
  hookSpecificOutput?: { updatedToolOutput?: unknown; additionalContext?: string }
  systemMessage?: string // the sidecar's once-per-session notice when its judge cannot start
}

type ToolCallEvent = { tool: string; tool_use_id?: string; agentId?: string } & Record<string, unknown>

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
  root: string,
): Promise<{ output: HookOutput | undefined; meta: Meta | undefined } | undefined> {
  let res
  try {
    if (!safetyAllows(JSON.stringify(payload), root)) {
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

async function liveTask($: EngineInterface): Promise<Task | undefined> {
  const messages = await $.session.messages().catch(() => [])
  const lastText = (role: string) =>
    [...messages].reverse().find((message) =>
      message.role === role &&
      message.text.trim() &&
      (role !== 'user' || (message.toolResults ?? []).length === 0),
    )?.text.trim() ?? ''
  const user_request = lastText('user')
  const assistant_intent = lastText('assistant')
  return user_request && assistant_intent ? { user_request, assistant_intent } : undefined
}

export const register: Register = (on) => {
  const base = `http://127.0.0.1:${PORT}`

  for (const tool of TOOLS) {
    on('tool.call', { tool }, async ($, e, next) => {
      const answer = await next(e)
      if (!('result' in answer) || answer.result === undefined) return answer
      if (JSON.stringify(answer.result).length < MIN_CHARS) return answer

      const { tool: toolName, tool_use_id, agentId, ...input } = e as ToolCallEvent
      const where = await whereami($)
      const task = await liveTask($)
      if (!task) return answer
      const res = await post($, `${base}/hook/post-tool-use`, {
        hook_event_name: 'PostToolUse',
        source: 'function-hook',
        ...where,
        agent_id: agentId,
        tool_name: toolName,
        tool_input: input,
        tool_response: answer.result,
        tool_use_id,
        task,
      }, where.cwd)
      if (typeof res?.output?.systemMessage === 'string') $.ui.toast(res.output.systemMessage)
      const updated = res?.output?.hookSpecificOutput?.updatedToolOutput
      if (updated === undefined) return answer
      if (res?.meta !== undefined) $.ui.toast(describeMeta(toolName, res.meta))
      return { ...answer, result: updated }
    })
  }
}
