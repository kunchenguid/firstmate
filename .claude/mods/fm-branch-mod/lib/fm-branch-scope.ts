// One owner for the supervision-branch mod's eligible-rows scan
// orchestration: the queue read, the .meta enumeration (one unreadable meta
// refuses the scan), each task's kind, and each project-bearing task's
// status log with the stat-read-stat torn check, pre-reading everything the
// shared fold core needs before calling it (.claude/mods/fm-branch-mod/
// hooks/branch.ts is the Claude Code binding).
//
// The pure fold itself - the row validation, the stale-row task resolution,
// the decision fold - is lib/fm-branch-eligibility.ts, passed in through
// deps.core because a module in this lib/ may import nothing (the repo's
// lib/ entries are symlinks here, so a sibling import could resolve against
// a differently-named file on the repo side; see fm-branch-eligibility.ts's
// wrapper for the one case that breaks). The FM_CLASSIFY_* environment read
// stays host-side too: the hooks-module validator lists the environment a
// module reads from the literal $.env.get call sites, so moving those reads
// behind a seam would silence the validated contract.
//
// Host seams: readFile/listDir/stat mirror the mod's $.fs surface (stat
// answers { isLink, size, mtimeMs } and both throw when a path is missing),
// vocabulary() is the host's env-bound fold vocabulary, and state is the
// home's state directory. The verdict cache is module-level here exactly as
// it was in the hooks file: one state directory per runtime, so task ids
// are stable keys and a stale row's fold carries across scans on an
// unchanged stat version.
//
// The mod loads this file directly from its own lib/ directory; the repo's
// lib/ entry is a tracked symlink to it (the Calm-mod pattern, inverted
// because a hooks module may import only its own files, never across the
// mod boundary). This file must therefore stay dependency-free: no imports
// of any kind.

/** The scope one wake routing decision consumes: the scan's verdict over
 * the queue and the task records it read. */
export interface Scope {
  status: 'safe' | 'empty' | 'unsafe'
  eligible: boolean
  eligibleSeqs: string[]
  /** Durable wake identity: the wake-queue "epoch:seq" of every eligible
   *  row, comma-joined. Stamped onto the outcome row the branch reports
   *  for this wake, so retrospective scorers join by identity instead of
   *  agent-supplied wake text. */
  eligibleWakeKey: string
  eligibleTasks: string[]
  corrupted: boolean
  needsDecisionTasks: string[]
  allSeqs?: string[]
}

/** The meta record of one task, as the shared core consumes it. */
export interface ScanQueueMeta {
  task: string
  project: string
  window: string
}

export type ScanStatusStat = { state: 'absent' } | { state: 'refused' } | { state: 'ok'; version: string }
export type ScanStatusText = { state: 'absent' } | { state: 'refused' } | { state: 'torn' } | { state: 'ok'; text: string; version: string }

/** The fold vocabulary the shared core folds with (the FM_CLASSIFY_* names
 * and defaults of bin/fm-classify-lib.sh). */
export interface ScanFoldVocabulary {
  resolveVerb: string
  heldVerb: string
  reservedPrefixes: string[]
  pausedVerb: string
}

/** The shared fold core from lib/fm-branch-eligibility.ts, passed in by the
 * host (see the header's no-import rule). */
export interface ScopeScanCore {
  statusKindFromMetaText(text: string | null): string
  scopeForUnreadWake(input: {
    queueText: string
    metas: ScanQueueMeta[]
    statStatus(task: string): ScanStatusStat
    readStatusText(task: string): ScanStatusText
    readKind(task: string): string
    env: ScanFoldVocabulary
    heartbeat: boolean
    afk: boolean
    cache: Map<string, unknown>
  }): {
    status: 'safe' | 'empty' | 'unsafe'
    eligible: boolean
    eligibleSeqs: string[]
    eligibleWakeKey: string
    eligibleTasks: string[]
    corrupted: boolean
    needsDecisionTasks: string[]
    allSeqs?: string[]
  }
}

export interface ScopeScanDeps {
  /** Reads a file's text; rejects when the path is missing (the $.fs.read
   * contract). */
  readFile(path: string): Promise<string>
  /** Lists a directory's entries; rejects when it cannot. */
  listDir(path: string): Promise<Array<{ name: string }>>
  /** Stats one path, answering { isLink, size, mtimeMs }; rejects when the
   * path is missing. */
  stat(path: string): Promise<{ isLink: boolean; size: number; mtimeMs: number }>
  /** The host's env-bound fold vocabulary (the FM_CLASSIFY_* seam). */
  vocabulary(): Promise<ScanFoldVocabulary>
  core: ScopeScanCore
}

// Cross-scan verdict cache keyed by task id: one state directory per
// runtime, so task ids are stable keys and a stale row's fold carries
// across scans on an unchanged stat version.
const verdictCache: Map<string, unknown> = new Map()

/** The presence of one state-directory file: the stat version for a plain
 * file; absent when the path is missing (both seam reads reject, which is
 * the seam's missing contract); or refused for a symlink or a present path
 * that will not stat but still reads. Only a missing path folds empty -
 * a refused log vetoes the scan so its row stays with main. */
async function statLogOf(deps: ScopeScanDeps, path: string): Promise<{ state: 'absent' } | { state: 'refused' } | { state: 'ok'; version: string }> {
  try {
    const stat = await deps.stat(path)
    if (stat.isLink) return { state: 'refused' }
    return { state: 'ok', version: `${stat.size}:${stat.mtimeMs}` }
  } catch {
    try {
      await deps.readFile(path)
      return { state: 'refused' }
    } catch {
      return { state: 'absent' }
    }
  }
}

/** bin/fm-classify-lib.sh _fm_status_kind through the shared core's parser:
 * a symlinked, missing, or unreadable meta names no kind (unknown). */
export async function statusKindOf(deps: ScopeScanDeps, state: string, task: string): Promise<string> {
  const path = `${state}/${task}.meta`
  let metaText: string | null = null
  try {
    const stat = await deps.stat(path)
    if (!stat.isLink) metaText = await deps.readFile(path)
  } catch {
    metaText = null
  }
  return deps.core.statusKindFromMetaText(metaText)
}

/** The eligible-rows scan: pre-read the queue, every .meta record (one
 * unreadable meta refuses the scan exactly as the lib's node:fs binding
 * does), each task's kind, and each project-bearing task's log with the
 * stat-read-stat torn check, then hand the sync bindings to the shared
 * core. An empty queue is nothing to claim before any metadata enumeration
 * can fail - the shared core's own ordering. */
export async function scanScope(deps: ScopeScanDeps, state: string, heartbeat: boolean): Promise<Scope> {
  const unsafe: Scope = { status: 'unsafe', eligible: false, eligibleSeqs: [], eligibleWakeKey: '', eligibleTasks: [], corrupted: true, needsDecisionTasks: [] }
  let queueText: string
  try {
    queueText = await deps.readFile(`${state}/.wake-queue`)
  } catch {
    return unsafe
  }
  if (queueText.split(/\r?\n/).filter((l: string) => l.length > 0).length === 0) {
    return { status: 'empty', eligible: false, eligibleSeqs: [], eligibleWakeKey: '', eligibleTasks: [], corrupted: false, needsDecisionTasks: [] }
  }
  const metas: ScanQueueMeta[] = []
  const kinds = new Map<string, string>()
  try {
    for (const entry of await deps.listDir(state)) {
      if (!entry.name.endsWith('.meta')) continue
      const task = entry.name.slice(0, -5)
      const metaPath = `${state}/${entry.name}`
      const text: string = await deps.readFile(metaPath)
      const fields = text.split('\n')
      metas.push({
        task,
        project: fields.find((l: string) => l.startsWith('project='))?.slice(8) ?? '',
        window: fields.find((l: string) => l.startsWith('window='))?.slice(7) ?? '',
      })
      let kind: string
      try {
        kind = (await deps.stat(metaPath)).isLink ? 'unknown' : deps.core.statusKindFromMetaText(text)
      } catch {
        kind = 'unknown'
      }
      kinds.set(task, kind)
    }
  } catch {
    return unsafe
  }
  // The core resolves which stale rows fold a status log; every task the
  // resolution can name is one with a project, so pre-read those logs and
  // let the core consult the ones it needs.
  const stats = new Map<string, ScanStatusStat>()
  const texts = new Map<string, ScanStatusText>()
  for (const { task, project } of metas) {
    if (!project) continue
    const path = `${state}/${task}.status`
    const presence = await statLogOf(deps, path)
    if (presence.state === 'absent') {
      stats.set(task, { state: 'absent' })
      texts.set(task, { state: 'absent' })
      continue
    }
    if (presence.state === 'refused') {
      stats.set(task, { state: 'refused' })
      texts.set(task, { state: 'refused' })
      continue
    }
    stats.set(task, { state: 'ok', version: presence.version })
    let text: string
    try {
      text = await deps.readFile(path)
    } catch {
      // A clean stat whose read fails is a present log no host can read:
      // veto, never an empty fold.
      texts.set(task, { state: 'refused' })
      continue
    }
    const after = await statLogOf(deps, path)
    // A vanished or changed log after a successful read is torn (Pi's
    // rule refuses the scan); only a log missing from the start folds
    // empty, exactly as the lib's node:fs binding reads it.
    texts.set(task, after.state === 'ok' && after.version === presence.version ? { state: 'ok', text, version: after.version } : after.state === 'refused' ? { state: 'refused' } : { state: 'torn' })
  }
  const libScope = deps.core.scopeForUnreadWake({
    queueText,
    metas,
    statStatus: (task) => stats.get(task) ?? { state: 'refused' },
    readStatusText: (task) => texts.get(task) ?? { state: 'refused' },
    readKind: (task) => kinds.get(task) ?? 'unknown',
    env: await deps.vocabulary(),
    heartbeat,
    // The mod routes the away collapse before scoping (routing's .afk
    // check), so the core's own afk branch stays off here.
    afk: false,
    cache: verdictCache,
  })
  return {
    status: libScope.status,
    eligible: libScope.eligible,
    eligibleSeqs: libScope.eligibleSeqs,
    eligibleWakeKey: libScope.eligibleWakeKey,
    eligibleTasks: libScope.eligibleTasks,
    corrupted: libScope.corrupted,
    needsDecisionTasks: libScope.needsDecisionTasks,
    allSeqs: libScope.allSeqs,
  }
}
