import { statSync } from "node:fs";
import { join } from "node:path";
import { runCommandAsync } from "./fm-async-exec.ts";
import { scanStateDirectory } from "../../../lib/fm-branch-eligibility.ts";
import type { UnreadWakeScope, UnreadWakeScopeStatus } from "../../../lib/fm-branch-eligibility.ts";

// Shared wake-dispatch handshake between the Pi watcher extension (the
// dispatcher) and the supervision-branch extension (the handler), carried over
// pi.events so neither extension imports the other.
//
// Contract: the watcher builds one offer per actionable wake and emits it on
// FM_BRANCH_DISPATCH_EVENT. A live, enabled branch extension calls accept()
// SYNCHRONOUSLY inside its handler (the event bus invokes handlers
// synchronously up to their first await), so after emit returns the watcher
// reads `accepted`: true means the branch owns handling the wake, and its
// settlement promise keeps the watcher outcome pending until handling finishes
// or rejects back to the watcher's consumption-acknowledged main path; false
// means no branch took it and the watcher delivers to main exactly as it did
// before the branch existed. Watcher-failure alarms are never offered - only
// main can repair the watcher cycle (fm_watch_arm_pi lives on main).
//
// Postures (docs/pi-supervision-branch.md "Postures"). The away-posture record
// state/.afk-contract (owner: bin/fm-afk-contract.sh) is the posture; it is
// read as a file at every routing decision, never inferred from chat. While
// it exists the branch takes EVERY actionable row - check rows, decision-owned
// rows, and heartbeat rows included - and main is offered nothing the branch
// can take. The two vetoes that describe a broken queue stay vetoes in both
// postures, and such a wake, like every watcher-failure alarm, still falls
// back to main exactly as attended, because only main can repair supervision
// itself; parking main is a cost measure, continuity is the safety property.

export const FM_BRANCH_DISPATCH_EVENT = "fm-branch-supervision:dispatch";

// The away-posture record's state-relative filename, exactly as
// bin/fm-afk-contract.sh writes it. Presence is the only fact read here; the
// guarded scripts validate the record themselves (bin/fm-lease-lib.sh).
export const AFK_CONTRACT_FILE = ".afk-contract";

export function afkPostureRecordPresent(state: string): boolean {
  try {
    return statSync(join(state, AFK_CONTRACT_FILE)).isFile();
  } catch {
    return false;
  }
}

// The Pi adapter consumes the mod's canonical scope type; re-exported so the
// dispatch module keeps its original type surface.
export type { UnreadWakeScope, UnreadWakeScopeStatus };

// scopeForUnreadWake classifies the durable wake queue for the branch offer
// handshake, bound to one state directory. The classification itself - the
// status-decision fold, the eligible-rows scan and its guards, the verdict
// cache, and the wake-key derivation - has one owner, the shared module
// lib/fm-branch-eligibility.ts (the bash v8 fold that
// tests/fm-branch-eligibility.test.sh pins against bin/fm-classify-lib.sh);
// this file only binds it to the extension's state directory and exposes the
// extension's scope shape. docs/pi-supervision-branch.md "Autonomy" and
// docs/watcher-continuity.md "Per-actor acknowledgement" own the routing
// contracts the classification feeds, restated here only as far as the
// dispatcher reads them off this scope: a check-kind row never vetoes a scan
// and stays queued for main; a needs-decision signal row and a decision-owned
// stale row are excluded from eligibleSeqs without a veto and forced to main
// on their own triggering close (fm-primary-pi-watch.ts's offerWakeToBranch);
// a heartbeat review takes every branch-ownable row or none of them, so a
// row this repo's fm_wake_append could never have produced still vetoes the
// whole scan; and in the away posture (`afk`, the dispatcher's read of the
// away-posture record) the partition collapses - main is parked, so check
// rows, decision-owned rows, and heartbeat rows are all claimed by the branch
// on whatever wake finds them unread, while the vetoes that describe a broken
// queue rather than a routing choice stay vetoes in both postures.
export function scopeForUnreadWake(state: string, heartbeat: boolean, afk = false): UnreadWakeScope {
  return scanStateDirectory(state, { heartbeat, afk });
}

// The exact state-relative filename bin/fm-wake-drain.sh reads for a
// FM_SUPERVISION_ACTOR=branch drain or ack (its header is the single owner of
// the consume-side contract). Written atomically, immediately before every
// branch prompt, by writeEligibleRowsSnapshot below.
export const BRANCH_ELIGIBLE_ROWS_FILE = ".branch-eligible-rows";

// Atomically publish the exact row set a branch turn may drain and
// acknowledge. One sequence number per line - an opaque handoff, never
// reclassified by the consumer. A main-owned result means the competing main
// turn won the queue-lock claim and already owns presentation; error means no
// actor acquired the requested rows.
export type EligibleRowsSnapshotResult = "published" | "main-owned" | "error";

// Awaited rather than synchronous because every caller runs on the Pi thread
// that draws the captain's TUI (lib/fm-async-exec.ts). The grant script itself
// is unchanged, and so is each result: a null status still means the script
// could not be run at all.
async function runGrantScript(
  state: string,
  grantScript: string,
  args: readonly string[],
): Promise<number | null> {
  const result = await runCommandAsync("bash", [grantScript, ...args], {
    env: {
      ...process.env,
      FM_STATE_OVERRIDE: state,
      FM_WAKE_QUEUE: `${state}/.wake-queue`,
      FM_WAKE_QUEUE_LOCK: `${state}/.wake-queue.lock`,
    },
  });
  return result.status;
}

export async function activateEligibleRowsOwner(
  state: string,
  grantScript: string,
  ownerPid: number,
  generation: string,
): Promise<boolean> {
  return (await runGrantScript(state, grantScript, ["activate", String(ownerPid), generation])) === 0;
}

export async function writeEligibleRowsSnapshot(
  state: string,
  seqs: readonly string[],
  grantScript: string,
  generation: string,
): Promise<EligibleRowsSnapshotResult> {
  if (seqs.length === 0 || seqs.some((seq) => !/^[0-9]+$/.test(seq))) return "error";
  const status = await runGrantScript(state, grantScript, ["publish", generation, ...seqs]);
  if (status === 0) return "published";
  if (status === 3) return "main-owned";
  return "error";
}

export async function releaseEligibleRowsSnapshot(
  state: string,
  grantScript: string,
  generation: string,
): Promise<boolean> {
  return (await runGrantScript(state, grantScript, ["release", generation])) === 0;
}

export async function deactivateEligibleRowsOwner(
  state: string,
  grantScript: string,
  ownerPid: number,
  generation: string,
): Promise<boolean> {
  return (await runGrantScript(state, grantScript, ["deactivate", String(ownerPid), generation])) === 0;
}

export interface BranchDispatchOffer {
  /** The watcher's actionable close message (the wake reason line(s)). */
  message: string;
  /**
   * Exact project values from the unread task metadata this wake will drain.
   * Empty means the wake is fleet-wide or could not be scoped safely.
   */
  projects: readonly string[];
  /** True when the watcher classified this wake as a fleet-wide heartbeat scan. */
  heartbeat: boolean;
  /** True only when at least one currently unread row is safe for branch handling. */
  eligible: boolean;
  /** True when routing-time eligibility existed only because of the away collapse. */
  awayOnly: boolean;
  /** Set by accept(); read by the watcher after emit returns. */
  accepted: boolean;
  settlement: Promise<void>;
  accept(settlement?: Promise<void>): void;
}

export function createBranchDispatchOffer(
  message: string,
  projects: readonly string[] = [],
  heartbeat = false,
  eligible = false,
  awayOnly = false,
): BranchDispatchOffer {
  const offer: BranchDispatchOffer = {
    message,
    projects: [...projects],
    heartbeat,
    eligible,
    awayOnly,
    accepted: false,
    settlement: Promise.resolve(),
    accept(settlement = Promise.resolve()) {
      offer.accepted = true;
      offer.settlement = settlement;
    },
  };
  return offer;
}
