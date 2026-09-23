// One owner for the supervision-branch mod's wake-routing decision:
// the pass/grant verdict sequence of one watcher wake (mode switch, latch
// admission, away collapse, reason-line gate, scope verdicts, the passed-
// wake dedupe key and window, the handled-row and in-flight dedupe, the
// stale in-flight release, the classifier gate with its rows-already-
// passed skip, the grant publish verdicts, the granted wake's prompt and
// in-flight record, and the pass effects - the evidence-offset advance and
// the covering captain row a classifier or scope pass writes for main).
// .claude/mods/fm-branch-mod/hooks/branch.ts is the Claude Code binding.
//
// The router owns the session routing state that only routing mutates:
// the passed-wake dedupe map, the handled-row set, and the in-flight wake
// record (the host reads the in-flight record for report scoping and
// settlement, and clears it at settlement and session start, through the
// accessors below).
//
// Host seams - declared, not unified: every effect the decision fires is a
// dep (logging, the tracked clock, real time, the mode/afk switches, the
// scope scan, the passed-rows file, the classifier, activation and grant,
// the outcome store, delivery, the status note, and
// the wake counter). The decision order, the verdict strings, the log
// event names and payloads, and the written records are byte-stable:
// tests/fm-branch-routing.test.sh pins them through both the module and
// the mod's exported binding, and the engine suite
// (tests/branch.test.ts inside the mod) pins the binding end to end.
//
// The mod loads this file directly from its own lib/ directory; the repo's
// lib/ entry is a tracked symlink to it (the Calm-mod pattern, inverted
// because a hooks module may import only its own files, never across the
// mod boundary). This file must therefore stay dependency-free: no imports
// of any kind.

/** The scope one routing decision consumes (lib/fm-branch-scope.ts's
 * output shape, structural). */
export interface WakeScope {
  status: 'safe' | 'empty' | 'unsafe'
  eligibleSeqs: string[]
  eligibleWakeKey: string
  eligibleTasks: string[]
  corrupted: boolean
  needsDecisionTasks: string[]
  allSeqs?: string[]
}

/** The in-flight wake record: the wake the branch currently owns. */
export interface InFlight {
  seqs: string[]
  wakeKey: string
  tasks: Set<string>
  heartbeat: boolean
  wakeText: string
  reason: string
  reportedSeqs: number[]
  startedAt: number
  granted: boolean
  wakeNo: number
  via: 'spawn' | 'send'
}

/** The classifier verdict one routing decision gates on (lib/
 * fm-branch-classifier.ts's result shape, structural). */
export interface RoutedClassifierResult {
  verdict: string
  reason: string
  ms: number
  promptChars: number
  answer: string
  model: string | null
  evidence: Array<{ task: string; from: number; to: number; text: string }>
}

/** A passed-wake window: 90 seconds per row set. */
export const PASSED_DEDUPE_MS = 90_000
/** An in-flight wake this old never settled: free the grant and route
 * afresh rather than queueing every later wake behind it. */
export const INFLIGHT_STALE_MS = 180_000

export interface WakeRouterDeps {
  log(kind: string, data: unknown): void
  reasonLines(text: string): string[]
  /** The tracked host clock: resolves the epoch ms the host last observed
   * through $.clock.now() (the latch's time source). */
  clockNow(): Promise<number>
  /** Real time, for the in-flight stale check and the startedAt stamp. */
  dateNow(): number
  modeOn(): Promise<boolean>
  /** True when the provider-error latch admits no wake right now. */
  latched(): boolean
  afkPresent(): Promise<boolean>
  scopeFor(heartbeat: boolean): Promise<WakeScope>
  readPassedSeqs(): Promise<string[]>
  writePassedSeqs(seqs: string[]): Promise<void>
  classify(wake: string, tasks: string[], seqs: string[]): Promise<RoutedClassifierResult>
  ensureActivated(): Promise<boolean>
  grantPublish(seqs: string[]): Promise<number>
  grantRelease(): Promise<void>
  /** Fire-and-forget evidence-offset advance for a task main now handles. */
  advanceEvidence(task: string): void
  /** The outcome-store runner (bin/fm-branch-outcome.sh) for cover rows. */
  runOutcome(argv: string[]): Promise<{ ok: boolean; stdout: string; detail: string }>
  passedToMainSummary(why: string, classifierReason: string): string
  classifierPassCoverArgv(task: string, summary: string, wake: string): string[]
  /** Increments the session wake counter, persists it, and answers it. */
  claimWakeNo(): Promise<number>
  /** True when the next delivery needs a fresh agent (rotation pending or
   * no live branch agent). */
  freshAgentNeeded(): boolean
  stateDir(): string
  /** The deterministic new-status-lines note for the wake's tasks. */
  statusNote(tasks: string[]): Promise<string>
  /** Zeroes the per-step counter the settlement reads. */
  resetStepCounter(): void
  deliver(prompt: string): Promise<{ ok: boolean; via: 'spawn' | 'send'; detail: string }>
  spawnSendCounts(): { spawnCount: number; sendCount: number }
}

export function createWakeRouter() {
  // Queue rows the classifier already passed to main, keyed by the dedupe
  // key, durable in the host's passed file; the rows the branch took; and
  // the wake the branch currently owns.
  const recentPassed = new Map<string, number>()
  const handledSeqs = new Set<string>()
  let inFlight: InFlight | null = null

  /** Route one watcher wake: 'dropped' when the branch took it, 'passed'
   * when main must handle it. The deps are per-call (the host builds them
   * from its bound host object), the routing state is this object's. */
  async function routeWake(deps: WakeRouterDeps, wakeText: string, source: string): Promise<'dropped' | 'passed'> {
    const reasons = deps.reasonLines(wakeText)
    const reason = reasons.join('\n')
    const now = await deps.clockNow()
    // Dedupe key: the queue rows the wake resolves to, never the reason
    // text, because every wake of one task reads the same
    // `signal: .../<task>.status`.
    let passKey = ''
    const pass = (why: string, extra: Record<string, unknown> = {}) => {
      deps.log('wake.passed', { why, reason: reason || wakeText.slice(0, 300), source, ...extra })
      if (passKey) recentPassed.set(passKey, now)
      // Lines main handles become history for the classifier: advance its
      // offset.
      const tasks = new Set<string>([...((extra.seqsTasks as string[]) ?? []), ...((extra.needsDecisionTasks as string[]) ?? [])])
      for (const t of tasks) deps.advanceEvidence(t)
      // A captain-class wake main takes directly still needs a covering
      // CAPTAIN row in the outcome store: without it the branch's next wake
      // note lists the line as "appended since your last outcome" and
      // re-escalates what main already handled, and the backstop reads the
      // line as uncovered.
      if (/^(classifier|scope unsafe)/.test(why)) {
        for (const t of tasks) {
          void (async () => {
            const coverSummary = deps.passedToMainSummary(why, String(extra.classifierReason ?? 'open captain decision on this task'))
            const a = await deps.runOutcome(deps.classifierPassCoverArgv(t, coverSummary, reason))
            if (!a.ok) return deps.log('pass.cover.error', { task: t, detail: a.detail })
            const seq = Number(a.stdout)
            await deps.runOutcome(['mark-read', '--through', String(seq)])
            const m = await deps.runOutcome(['mark-processed', '--through', String(seq)])
            deps.log('pass.cover', { task: t, seq, why, processed: m.ok, detail: m.detail })
          })().catch((error) => deps.log('pass.cover.error', { task: t, detail: String(error) }))
        }
      }
      return 'passed' as const
    }
    if (!(await deps.modeOn())) return pass('no state/.branch-mod-mode')
    if (deps.latched()) return pass('latched')
    if (await deps.afkPresent()) return pass('afk')
    if (reasons.length === 0) return pass('no actionable reason line (alarm or failure notice)')
    const heartbeat = reasons.some((r) => /^heartbeat($|:)/.test(r))
    const scope = await deps.scopeFor(heartbeat)
    deps.log('wake.scope', { reason, scope, source })
    const passedSeqs = new Set(await deps.readPassedSeqs())
    // Sweep only on a safe scan: an unsafe scope carries an empty allSeqs,
    // and treating that as "nothing queued" would wipe rows main still owns.
    if (!scope.corrupted && (scope.allSeqs || scope.status === 'empty')) {
      const queued = new Set(scope.allSeqs ?? [])
      const gone = [...passedSeqs].filter((s) => !queued.has(s))
      if (gone.length > 0) {
        for (const s of gone) passedSeqs.delete(s)
        await deps.writePassedSeqs([...passedSeqs])
      }
    }
    passKey = `${scope.status}:${(scope.allSeqs ?? scope.eligibleSeqs).join(',')}:${scope.needsDecisionTasks.join(',')}`
    const seenAt = recentPassed.get(passKey)
    if (seenAt !== undefined && now - seenAt < PASSED_DEDUPE_MS) {
      deps.log('wake.passed.deduped', { passKey, source, ageMs: now - seenAt })
      return 'dropped'
    }
    // An empty queue under a signal/stale/heartbeat reason means the other
    // continuity path (Stop hook vs Monitor) already routed this close:
    // nothing for main to drain, so drop it. A `check:` reason (recovery
    // marker, registered poll) still needs main's acknowledgement and is
    // passed.
    if (scope.status === 'empty' && !reasons.some((r) => /^check:/.test(r))) {
      deps.log('wake.dropped.empty', { reason, source })
      return 'dropped'
    }
    if (scope.status === 'empty' || scope.corrupted || scope.eligibleSeqs.length === 0) return pass(`scope ${scope.status}`, { needsDecisionTasks: scope.needsDecisionTasks, seqsTasks: scope.eligibleTasks })
    // Dedupe: the Stop-hook arm and the monitor can both surface one wake,
    // and a wake already in the branch's hands must not be granted twice.
    if (scope.eligibleSeqs.every((s) => handledSeqs.has(s))) {
      deps.log('wake.deduped', { seqs: scope.eligibleSeqs, source })
      return 'dropped'
    }
    if (inFlight && deps.dateNow() - inFlight.startedAt > INFLIGHT_STALE_MS) {
      // A delivery that never settled (send refused, agent gone): free the
      // grant and route afresh rather than queueing every later wake behind
      // it.
      deps.log('inflight.stale', { seqs: inFlight.seqs, wakeNo: inFlight.wakeNo, ageMs: deps.dateNow() - inFlight.startedAt })
      inFlight = null
      for (const s of scope.eligibleSeqs) handledSeqs.delete(s)
      await deps.grantRelease()
    }
    if (inFlight) {
      // The grant file holds one row set at a time; the branch's settlement
      // re-scopes the queue and routes what is still there.
      deps.log('wake.queued', { seqs: scope.eligibleSeqs, source, inFlightSeqs: inFlight.seqs })
      return 'dropped'
    }
    const unacknowledged = scope.eligibleSeqs.filter((s) => passedSeqs.has(s))
    if (unacknowledged.length > 0) {
      for (const s of scope.eligibleSeqs) passedSeqs.add(s)
      await deps.writePassedSeqs([...passedSeqs])
      return pass('classifier skipped: rows already passed to main, unacknowledged', { classifierReason: `row ${unacknowledged.join(', ')} of this wake was already passed to main and is not yet acknowledged`, seqs: scope.eligibleSeqs, seqsTasks: scope.eligibleTasks })
    }
    // Classifier ahead of the branch: only a confident routine verdict is
    // granted; captain or uncertain goes to main untouched.
    const c = await deps.classify(reason, scope.eligibleTasks, scope.eligibleSeqs)
    // The event log keeps the record shape but never the evidence texts;
    deps.log('classifier', { seqs: scope.eligibleSeqs, tasks: scope.eligibleTasks, verdict: c.verdict, reason: c.reason, ms: c.ms, promptChars: c.promptChars, answer: c.answer, model: c.model, estTokens: Math.ceil(c.promptChars / 4) })
    if (c.verdict !== 'routine') {
      for (const s of scope.eligibleSeqs) passedSeqs.add(s)
      await deps.writePassedSeqs([...passedSeqs])
      return pass(`classifier ${c.verdict}`, { classifierReason: c.reason, seqs: scope.eligibleSeqs, seqsTasks: scope.eligibleTasks })
    }
    if (!(await deps.ensureActivated())) return pass('no lock pid / activation failed')
    const rc = await deps.grantPublish(scope.eligibleSeqs)
    deps.log('grant.publish', { seqs: scope.eligibleSeqs, rc })
    if (rc !== 0) return pass(rc === 3 ? 'main-owned' : `publish rc ${rc}`)
    const wakeNo = await deps.claimWakeNo()
    const freshAgent = deps.freshAgentNeeded()
    const state = deps.stateDir()
    const scopeNote = heartbeat
      ? ''
      : `\n\nThis wake's rows resolve to task ${scope.eligibleTasks.join(', ')} (records: ${state}/${scope.eligibleTasks[0]}.meta and ${state}/${scope.eligibleTasks[0]}.status). Report with task=${scope.eligibleTasks[0]}, never fleet.` +
        (await deps.statusNote(scope.eligibleTasks))
    const prompt = `FIRSTMATE SUPERVISION WAKE: ${reason}\n\n(wake ${wakeNo} of this session)\nHandle this per your operating procedure and finish with fm_branch_report.` + scopeNote
    inFlight = {
      seqs: scope.eligibleSeqs,
      wakeKey: scope.eligibleWakeKey,
      tasks: new Set(scope.eligibleTasks),
      heartbeat,
      wakeText,
      reason,
      reportedSeqs: [],
      startedAt: deps.dateNow(),
      granted: true,
      wakeNo,
      via: freshAgent ? 'spawn' : 'send',
    }
    deps.resetStepCounter()
    const d = await deps.deliver(prompt)
    const counts = deps.spawnSendCounts()
    deps.log('wake.delivered', { wakeNo, seqs: scope.eligibleSeqs, ...d, spawnCount: counts.spawnCount, sendCount: counts.sendCount, source })
    if (!d.ok) {
      inFlight = null
      await deps.grantRelease()
      return pass(`delivery failed via ${d.via}: ${d.detail}`)
    }
    for (const s of scope.eligibleSeqs) handledSeqs.add(s)
    deps.log('wake.dropped', { wakeNo, source })
    return 'dropped'
  }

  return {
    routeWake,
    /** The wake the branch currently owns, if any (report scoping and
     * settlement read it; the record stays mutable by reference). */
    peekInFlight(): InFlight | null {
      return inFlight
    },
    /** Settlement: the branch no longer owns the in-flight wake. */
    clearInFlight(): void {
      inFlight = null
    },
    /** Behavior-neutral test seam (same precedent as the host's
     * __fmSetInFlight): plants the in-flight wake record. */
    setInFlightForTest(p: InFlight | null): void {
      inFlight = p
    },
    /** A failed branch turn may retry its rows: forget the branch took
     * them. */
    forgetHandled(seqs: string[]): void {
      for (const s of seqs) handledSeqs.delete(s)
    },
    /** True when any of the seqs is not in the branch's handled set. */
    hasUnhandled(seqs: string[]): boolean {
      return seqs.some((s) => !handledSeqs.has(s))
    },
    /** Session start: no in-flight wake, no handled rows. */
    resetForSession(): void {
      inFlight = null
      handledSeqs.clear()
    },
  }
}

export type WakeRouter = ReturnType<typeof createWakeRouter>
