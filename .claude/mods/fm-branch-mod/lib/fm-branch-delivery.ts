// One owner for the supervision-branch mod's delivery state machine to the
// one persistent branch agent: which agent id and pinned ref the session's
// branch currently is, the spawn-once-then-send rule, the module-reload
// adoption, the SendMessage ref-hint retry, the unresumable-agent rotation,
// the context-bound rotation handoff, and the own-agent bookkeeping the
// host's tool-call gating reads. .claude/mods/fm-branch-mod/hooks/branch.ts
// is the Claude Code binding: the raw $.agent.spawn, $.tool.call
// SendMessage, and $.agent.list calls stay there, bound as deps.
//
// The machine owns, once: delivery is $.agent.spawn once per branch
// generation, then $.tool.call SendMessage to the same named agent for
// every later wake. The harness pins a name to the agent it first reached
// in this conversation; when the name later resolves elsewhere (module
// reload, second spawn) the reply is {"success":false,"message":"...
// re-send with its ref: {"to": "fm-branch [3a11a1]"}"} and nothing is
// sent, so the pinned ref is learned from that text and the send retried
// once. A resumed agent whose transcript was never written (a bridge
// primary runs with transcript saving off) is unreachable for good:
// rotate to a fresh agent instead of passing every later wake to main.
// One rotation per delivery: a fresh agent under the next generation name
// takes over, and the old one simply never receives another message.
//
// Host seams - declared, not unified: logging, the session transcript id
// the send log names, the raw agent operations, the model config read,
// and the counters persistence - all per-call (the host builds the deps
// from its bound host object, the validator's spelling rule for $).
// The decision order, the verdict strings, and the log event names and
// payloads are byte-stable: tests/fm-branch-delivery.test.sh pins the
// machine through its deps and the engine suite (tests/branch.test.ts
// inside the mod) pins the binding end to end (only that host can drive a
// real SendMessage surface).
//
// The mod loads this file directly from its own lib/ directory; the repo's
// lib/ entry is a tracked symlink to it (the Calm-mod pattern, inverted
// because a hooks module may import only its own files, never across the
// mod boundary). This file must therefore stay dependency-free: no imports
// of any kind.

/** The branch agent's base name; a rotated generation appends -<n>. */
export const BRANCH_NAME = 'fm-branch'

export interface BranchDeliveryDeps {
  log(kind: string, data: unknown): void
  /** The primary session's transcript id, for the send log's resume
   * target. */
  sessionTranscriptId(): Promise<string>
  /** Raw $.tool.call SendMessage: answers the tool's result object (or
   * throws, which the machine converts to a denial). */
  sendMessage(to: string, prompt: string): Promise<any>
  /** Raw $.agent.spawn: answers the spawn result object (or throws). */
  spawnAgent(opts: Record<string, unknown>): Promise<any>
  /** Raw $.agent.list: answers the live agent records. */
  listAgents(): Promise<any[]>
  /** The configured supervision-branch model (default 'sonnet'). */
  readModel(): Promise<string>
  /** Persists the session counters after every state change that saves
   * them today. */
  saveCounters(): Promise<void>
  /** The tool-result text coercion (lib/fm-branch-text.ts's shape). */
  toolText(r: any): string
  /** The plugin's name, for the spawn's subagentType. */
  pluginName: string
}

export function createBranchDelivery() {
  let branchGeneration = 1
  let rotatePending = false
  let branchRef = ''
  let branchAgentId = ''
  let spawnCount = 0
  let sendCount = 0
  const ownAgents = new Set<string>()

  function branchName(): string {
    return branchGeneration > 1 ? `${BRANCH_NAME}-${branchGeneration}` : BRANCH_NAME
  }

  // One SendMessage to the named branch, with the pinned-ref retry.
  async function sendToBranch(deps: BranchDeliveryDeps, prompt: string): Promise<{ ok: boolean; id: string; detail: string; noAgent: boolean }> {
    const name = branchName()
    const sessionId = await deps.sessionTranscriptId()
    for (let attempt = 0; attempt < 2; attempt++) {
      const to = branchRef ? `${name} [${branchRef}]` : name
      let r: any
      try {
        r = await deps.sendMessage(to, prompt)
      } catch (error) {
        r = { deny: String(error) }
      }
      sendCount += 1
      const text = deps.toolText(r)
      deps.log('agent.send', { to, agentId: branchAgentId, sessionId, sendCount, attempt, text: text.slice(0, 400), deny: r?.deny, isError: r?.isError })
      if (r?.deny || r?.isError) {
        const failure = String(r?.deny ?? text)
        return { ok: false, id: '', detail: failure.slice(0, 300), noAgent: /no agent|not found|unknown agent|could not be resumed|no transcript found/i.test(failure) }
      }
      let j: any = {}
      try {
        j = JSON.parse(text)
      } catch {}
      if (j.success === false) {
        const hint = text.match(new RegExp(`${name} \\[([0-9a-f]+)\\]`))
        if (hint && hint[1] !== branchRef) {
          branchRef = hint[1]
          continue
        }
        return { ok: false, id: '', detail: String(j.message ?? text).slice(0, 300), noAgent: /no agent|not found|unknown agent|does not resolve|could not be resumed|no transcript found/i.test(text) }
      }
      if (j.pin?.ref) branchRef = j.pin.ref
      return { ok: true, id: String(j.resumedAgentId ?? j.pin?.id ?? ''), detail: text.slice(0, 200), noAgent: false }
    }
    return { ok: false, id: '', detail: 'ref changed twice', noAgent: false }
  }

  async function spawnBranch(deps: BranchDeliveryDeps, prompt: string, model: string): Promise<{ ok: boolean; detail: string }> {
    let spawned: any
    try {
      spawned = await deps.spawnAgent({ prompt, description: 'firstmate supervision branch (persistent)', subagentType: `${deps.pluginName}:${BRANCH_NAME}`, model, background: true, name: branchName() })
    } catch (error) {
      spawned = { deny: String(error) }
    }
    deps.log('agent.spawn', { model, name: branchName(), branchGeneration, result: spawned })
    if (!spawned?.agentId) return { ok: false, detail: String(spawned?.deny ?? 'no agentId') }
    spawnCount += 1
    branchAgentId = spawned.agentId
    ownAgents.add(branchAgentId)
    branchRef = ''
    await deps.saveCounters()
    return { ok: true, detail: branchAgentId }
  }

  async function rotateToFreshAgent(deps: BranchDeliveryDeps, prompt: string, model: string, why: string, sendDetail?: string): Promise<{ ok: boolean; via: 'spawn'; detail: string }> {
    branchGeneration += 1
    branchAgentId = ''
    branchRef = ''
    const s = await spawnBranch(deps, prompt, model)
    deps.log('agent.rotated', { why, branchGeneration, name: branchName(), ok: s.ok, detail: s.detail, sendDetail })
    await deps.saveCounters()
    return { ok: s.ok, via: 'spawn', detail: s.detail }
  }

  /** Delivers one wake to the branch agent: spawn once per generation,
   * then send; adopts after a reload; rotates an unresumable agent. The
   * deps are per-call (the host builds them from its bound host
   * object), the delivery state is this object's. */
  async function deliverToBranch(deps: BranchDeliveryDeps, prompt: string): Promise<{ ok: boolean; via: 'spawn' | 'send'; detail: string }> {
    const model = await deps.readModel()
    if (rotatePending) {
      // The previous agent's context passed the bound.
      rotatePending = false
      return rotateToFreshAgent(deps, prompt, model, 'context bound')
    }
    if (!branchAgentId) {
      // A module reload (/reload-plugins, or a hooks file save) resets this
      // state while the named agent lives on in the session. $.agent.list()
      // is scoped to this module instance, so adoption goes through
      // SendMessage itself: a successful resume names the agent's id. A
      // session that never spawned has nothing to adopt and spawns
      // directly, so the first wake costs no refused send.
      if (spawnCount > 0) {
        const s = await sendToBranch(deps, prompt)
        if (s.ok) {
          deps.log('agent.adopted', { agentId: s.id, ref: branchRef })
          branchAgentId = s.id
          if (s.id) ownAgents.add(s.id)
          await deps.saveCounters()
          return { ok: true, via: 'send', detail: s.id }
        }
        deps.log('agent.adopt.failed', { detail: s.detail, noAgent: s.noAgent })
      }
      const spawned = await spawnBranch(deps, prompt, model)
      return { ok: spawned.ok, via: 'spawn', detail: spawned.detail }
    }
    const s = await sendToBranch(deps, prompt)
    if (!s.ok) {
      // A resumed agent whose transcript was never written (a bridge
      // primary runs with transcript saving off) is unreachable for good:
      // rotate to a fresh agent instead of passing every later wake to
      // main.
      if (!s.noAgent) return { ok: false, via: 'send', detail: s.detail }
      return rotateToFreshAgent(deps, prompt, model, 'unresumable', s.detail)
    }
    if (s.id && s.id !== branchAgentId) {
      deps.log('agent.id.changed', { from: branchAgentId, to: s.id })
      branchAgentId = s.id
    }
    if (s.id) ownAgents.add(s.id)
    return { ok: true, via: 'send', detail: s.id || branchAgentId }
  }

  return {
    deliverToBranch,
    /** The named branch agent's id, when a live one exists under the
     * current generation name ($.agent.list scoped to this module
     * instance). The deps are per-call. */
    async resolveNamedAgent(deps: BranchDeliveryDeps): Promise<string> {
      try {
        const list = await deps.listAgents()
        const name = branchName()
        const named = (list as any[]).filter((a) => a.name === name)
        deps.log('agent.list', { count: (list as any[]).length, named })
        const live = named.at(-1)
        return live?.id ?? ''
      } catch (error) {
        deps.log('agent.list.error', { error: String(error) })
        return ''
      }
    },
    /** True when the agent id is one the branch delivery owns (the Bash
     * and report gating, the effort rewrite, the settlement). */
    knowsAgent(agentId: string): boolean {
      return ownAgents.has(agentId)
    },
    /** The branch agent id the session currently pins, '' when none. */
    currentAgentId(): string {
      return branchAgentId
    },
    /** An unknown caller is the branch under a new id: adopt it. */
    adoptAgent(agentId: string): void {
      ownAgents.add(agentId)
      branchAgentId = agentId
    },
    /** A peer message is the branch's own hand-back when it names the
     * branch, one of the branch's agent ids, or the branch marker. */
    isOwnHandback(from: string, text: string): boolean {
      return from.startsWith(BRANCH_NAME) || ownAgents.has(from) || /fm-branch/.test(text.slice(0, 200))
    },
    /** A task notification is the branch agent's own when it names the
     * branch agent and is not a Stop-hook wake. */
    isOwnAgentNotification(text: string): boolean {
      return Boolean(branchAgentId) && (text.includes(branchAgentId) || /fm-branch\b/.test(text)) && !/Stop hook feedback/.test(text)
    },
    /** True when the next delivery needs a fresh agent (rotation pending
     * or no live branch agent). */
    freshAgentNeeded(): boolean {
      return rotatePending || !branchAgentId
    },
    /** True while a context-bound rotation is armed for the next
     * delivery. */
    isRotatePending(): boolean {
      return rotatePending
    },
    /** The settlement's context-bound verdict arms the next-delivery
     * rotation. */
    setRotatePending(v: boolean): void {
      rotatePending = v
    },
    /** The current branch generation (log payloads and counters). */
    branchGeneration(): number {
      return branchGeneration
    },
    /** The counters fields this machine owns, in the save order. */
    snapshot(): { spawnCount: number; sendCount: number; branchGeneration: number; branchRef: string; branchAgentId: string } {
      return { spawnCount, sendCount, branchGeneration, branchRef, branchAgentId }
    },
    /** Applies the same-session counters record (each field's historical
     * default on absence). */
    restoreFromCounters(j: { spawnCount?: number; sendCount?: number; branchGeneration?: number; branchRef?: string; branchAgentId?: string }): void {
      spawnCount = j.spawnCount ?? 0
      sendCount = j.sendCount ?? 0
      branchGeneration = j.branchGeneration ?? 1
      if (j.branchRef) branchRef = j.branchRef
      if (j.branchAgentId) {
        branchAgentId = j.branchAgentId
        ownAgents.add(j.branchAgentId)
      }
    },
    /** Session start: fresh delivery state (the pinned ref and the
     * own-agent set deliberately survive, as they always have). */
    resetForSession(): void {
      branchAgentId = ''
      spawnCount = 0
      sendCount = 0
      branchGeneration = 1
      rotatePending = false
    },
  }
}

export type BranchDelivery = ReturnType<typeof createBranchDelivery>
