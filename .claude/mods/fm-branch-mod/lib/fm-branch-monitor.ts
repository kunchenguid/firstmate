// One owner for the supervision-branch mod's watcher-continuity monitor
// state machine: the armed claim and its age, the double-arm guard, the
// stale-claim expiry (a claim older than the monitor timeout plus five
// minutes with no expiry notice in hand is a dead monitor whose notice was
// lost), the re-arm gating on a monitor expiry notice (only the live
// monitor's own end re-arms), and the Monitor task's loop command.
// .claude/mods/fm-branch-mod/hooks/branch.ts is the Claude Code binding:
// the raw $.tool.call Monitor stays there, bound as a dep.
//
// The loop the command runs, stated once: each watcher close prints its
// reason lines (one event); the loop re-arms the watcher itself so no
// per-wake background task is ever started. Re-arm only once the previous
// wake's rows are acknowledged (queue empty) and any recovery marker
// (state/.watcher-down) is absent or acked: arming over either makes the
// watcher announce `check: rearm-resurface` with a fresh recovery
// generation every cycle, which the Stop-hook model never does. The loop
// must leave before the Monitor's own kill: a natural exit leaves the
// watcher alive (no downtime, no recovery episode); the kill takes the
// whole process group with it.
//
// Host seams - declared, not unified: logging, the RAW host clock (the
// claim age reads $.clock.now() and deliberately does not refresh the
// provider latch's last-known time), the mode switch, the Monitor task
// start, and the counters persistence - all per-call (the host builds
// the deps from its bound host object, the validator's spelling rule
// for $). The claim rules, the re-arm verdicts, the loop command bytes,
// and the log event names and payloads are byte-stable:
// tests/fm-branch-monitor.test.sh pins them through both the module and
// the mod's exported binding, and the engine suite (tests/branch.test.ts
// inside the mod) pins the binding end to end.
//
// The mod loads this file directly from its own lib/ directory; the repo's
// lib/ entry is a tracked symlink to it (the Calm-mod pattern, inverted
// because a hooks module may import only its own files, never across the
// mod boundary). This file must therefore stay dependency-free: no imports
// of any kind.

/** The Monitor task's description, also the marker its event notifications
 * carry (the ours test). */
export const MONITOR_DESCRIPTION = 'fm-branch-mod watcher continuity'
/** One Monitor task's lifetime. */
export const MONITOR_TIMEOUT_MS = 30 * 60 * 1000
/** An armed claim older than this with no expiry notice in hand is a dead
 * monitor whose notice was lost: the claim expires and the next arm site
 * arms. */
export const MONITOR_CLAIM_STALE_MS = MONITOR_TIMEOUT_MS + 5 * 60 * 1000

export interface MonitorPaths {
  cwd: string
  home: string
  state: string
  config: string
  bin: string
}

export interface MonitorGuardDeps {
  log(kind: string, data: unknown): void
  /** The raw host clock ($.clock.now()), which does NOT refresh the
   * provider latch's last-known time. */
  clockNow(): Promise<number>
  modeOn(): Promise<boolean>
  /** Starts the Monitor task ($.tool.call Monitor + the tool-result text
   * coercion); answers { text, deny }. */
  startMonitor(command: string): Promise<{ text: string; deny: unknown }>
  saveCounters(): Promise<void>
  /** The bound home's paths, read at arm time. */
  paths(): MonitorPaths
}

/** The Monitor task's loop command: the watcher arm/re-arm cycle described
 * in the header, with the rotate deadline leaving one monitor timeout
 * minus a three-minute margin. */
export function monitorLoopCommand(paths: MonitorPaths, rotateSecs: number): string {
  return (
    `cd ${JSON.stringify(paths.cwd)} && export FM_HOME=${JSON.stringify(paths.home)} FM_STATE_OVERRIDE=${JSON.stringify(paths.state)} FM_CONFIG_OVERRIDE=${JSON.stringify(paths.config)}; ` +
    `A=${JSON.stringify(paths.bin + '/fm-watch-arm.sh')}; Q=${JSON.stringify(paths.state + '/.wake-queue')}; D=${JSON.stringify(paths.state + '/.watcher-down')}; T0=$(date +%s); ` +
    `while :; do out=$("$A" 2>&1); printf '%s\\n' "$out" | grep -E '^(signal:|stale:|check:|heartbeat)' || printf 'quiet: %s\\n' "$(printf '%s' "$out" | tail -n 1 | cut -c1-160)"; ` +
    `w=0; while { [ -s "$Q" ] || { [ -e "$D" ] && ! grep -q '^acked:' "$D"; }; } && [ $w -lt 300 ]; do sleep 2; w=$((w+2)); done; [ $w -lt 300 ] || printf 'forced-rearm: queue or recovery marker still pending after %ss\\n' "$w"; ` +
    `[ $(( $(date +%s) - T0 )) -lt ${rotateSecs} ] || { printf 'rotate: loop exiting ahead of the monitor timeout\\n'; exit 0; }; sleep 2; done`
  )
}

export function createMonitorGuard() {
  let monitorArmed = false
  let monitorTaskId = ''
  let monitorArmedAt = 0
  let armingNow = false
  let monitorArms = 0

  /** Arms the continuity monitor when no live claim holds. The deps are
   * per-call (the host builds them from its bound host object). */
  async function armMonitor(deps: MonitorGuardDeps, why: string): Promise<void> {
    if (armingNow) return
    // Claim before the first await: the rotate event and the source-ended
    // notice of one monitor arrive within milliseconds and would otherwise
    // arm two loops.
    armingNow = true
    const now = await deps.clockNow()
    if (monitorArmed) {
      const ageMs = now - monitorArmedAt
      if (ageMs < MONITOR_CLAIM_STALE_MS) {
        armingNow = false
        return
      }
      deps.log('monitor.stale.claim', { why, taskId: monitorTaskId, ageMs })
    }
    if (!(await deps.modeOn())) {
      armingNow = false
      return
    }
    monitorArmed = true
    monitorArmedAt = now
    monitorArms += 1
    const rotateSecs = Math.floor(MONITOR_TIMEOUT_MS / 1000) - 180
    const command = monitorLoopCommand(deps.paths(), rotateSecs)
    try {
      const r = await deps.startMonitor(command)
      monitorTaskId = r.text.match(/Monitor started \(task ([a-z0-9]+)/)?.[1] ?? ''
      deps.log('monitor.armed', { why, monitorArms, taskId: monitorTaskId, text: r.text.slice(0, 300), deny: r.deny })
      if (r.deny) monitorArmed = false
      await deps.saveCounters()
    } catch (error) {
      monitorArmed = false
      deps.log('monitor.error', { why, error: String(error) })
    } finally {
      armingNow = false
    }
  }

  return {
    armMonitor,
    /** A monitor expiry notice's re-arm verdict: only the live monitor's
     * own end re-arms - an older monitor's expiry (after a reload reset
     * this state) must not start a second loop. */
    noteExpiry(tid: string): { rearm: true } | { rearm: false; live: string } {
      if ((!monitorTaskId || tid === monitorTaskId) && !armingNow) {
        monitorArmed = false
        return { rearm: true }
      }
      return { rearm: false, live: monitorTaskId }
    },
    /** True when a monitor claim is armed (the settlement re-arms when it
     * is not). */
    isArmed(): boolean {
      return monitorArmed
    },
    /** The counters fields this machine owns, in the save order. */
    snapshot(): { monitorTaskId: string; monitorArmedAt: number } {
      return { monitorTaskId, monitorArmedAt }
    },
    /** Applies the same-session counters record's monitor claim. */
    restoreFromCounters(taskId: string | undefined, armedAt: number | undefined, fallbackNow: number): void {
      if (taskId) {
        monitorTaskId = taskId
        monitorArmedAt = armedAt ?? fallbackNow
        monitorArmed = true
      }
    },
    /** Session start: no armed claim. */
    resetForSession(): void {
      monitorArmed = false
    },
  }
}

export type MonitorGuard = ReturnType<typeof createMonitorGuard>
