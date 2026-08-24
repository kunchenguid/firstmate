import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";

// Shared wake-dispatch handshake between the Pi watcher extension (the
// dispatcher) and the supervision-branch extension (the handler), carried over
// pi.events so neither extension imports the other.
//
// Contract: the watcher builds one offer per actionable wake and emits it on
// FM_BRANCH_DISPATCH_EVENT. A live, enabled branch extension calls accept()
// SYNCHRONOUSLY inside its handler (the event bus invokes handlers
// synchronously up to their first await), so after emit returns the watcher
// reads `accepted`: true means the branch now owns delivering and handling the
// wake (including its own fallback back to main on a later failure); false
// means no branch took it and the watcher delivers to main exactly as it did
// before the branch existed. Watcher-failure alarms are never offered - only
// main can repair the watcher cycle (fm_watch_arm_pi lives on main).

export const FM_BRANCH_DISPATCH_EVENT = "fm-branch-supervision:dispatch";

export type UnreadWakeScopeStatus = "safe" | "empty" | "unsafe";

export interface UnreadWakeScope {
  status: UnreadWakeScopeStatus;
  eligible: boolean;
  /** Exact project values touched by the currently eligible rows (context only). */
  projects: string[];
  /**
   * The exact durable-queue sequence numbers this scan proved safe for the
   * branch to drain and acknowledge right now (docs/watcher-continuity.md
   * "Per-actor acknowledgement" - the single owner of the consume contract
   * bin/fm-wake-drain.sh implements against this list). Empty whenever
   * `eligible` is false.
   */
  eligibleSeqs: string[];
  /**
   * True only when this scan itself is untrustworthy: the queue or its
   * metadata could not be read, a line fails the structural tab-field check,
   * an unresolvable signal/stale row was found, or - for a heartbeat review
   * only - a main-owned row sits anywhere in the unread queue. False whenever
   * the scan completed cleanly and simply found nothing (or nothing further)
   * eligible for the branch right now: status "unsafe" with corrupted false
   * is the ordinary "ordinary main-only content, nothing here for the
   * branch" case, not a fault, and callers should treat it as ordinary
   * absence rather than escalating.
   */
  corrupted: boolean;
}

const EMPTY_SCOPE: UnreadWakeScope = { status: "empty", eligible: false, projects: [], eligibleSeqs: [], corrupted: false };
const UNSAFE_SCOPE: UnreadWakeScope = { status: "unsafe", eligible: false, projects: [], eligibleSeqs: [], corrupted: true };

// scopeForUnreadWake is the single owner of branch-eligibility classification
// (docs/pi-supervision-branch.md "Autonomy"; docs/watcher-continuity.md
// "Per-actor acknowledgement"). bin/fm-wake-drain.sh never reclassifies a row
// itself - it only consumes the exact sequence-number snapshot this function
// (via writeEligibleRowsSnapshot) hands it.
//
// heartbeat=true keeps the ORIGINAL all-or-nothing rule byte-for-byte: a
// heartbeat review needs the whole fleet's context, so a single check-kind or
// unresolvable row anywhere in the unread queue still makes the entire scan
// unsafe (docs/pi-supervision-branch.md "Heartbeat routing").
//
// heartbeat=false is the changed half of this contract. A check-kind row -
// merge-confirmation polls, Relay mentions, credential/auth failures, and
// every other legitimately main-only class - no longer vetoes the whole scan;
// it is simply excluded from eligibleSeqs and left for main. An unresolvable
// signal/stale row (unmapped project) still vetoes the whole scan exactly as
// before, because that is a data/metadata problem this function cannot safely
// reason past, not an ordinary main-only event. A row this repo's
// fm_wake_append could never have produced (an unknown kind, or a line that
// fails the structural tab-field check) also still vetoes the whole scan -
// that is queue corruption, not an everyday mixed queue.
export function scopeForUnreadWake(state: string, heartbeat: boolean): UnreadWakeScope {
  let queue = "";
  try {
    queue = readFileSync(`${state}/.wake-queue`, "utf8");
  } catch {
    return UNSAFE_SCOPE;
  }

  const rows = queue.split(/\r?\n/).filter((line) => line.length > 0);
  if (rows.length === 0) return EMPTY_SCOPE;

  const projects = new Set<string>();
  const metadata = new Map<string, string>();
  try {
    for (const name of readdirSync(state)) {
      if (!name.endsWith(".meta")) continue;
      const task = name.slice(0, -5);
      const fields = readFileSync(`${state}/${name}`, "utf8").split(/\r?\n/);
      const project = fields.find((line) => line.startsWith("project="))?.slice(8) ?? "";
      const window = fields.find((line) => line.startsWith("window="))?.slice(7) ?? "";
      if (project) {
        metadata.set(task, project);
        if (window) metadata.set(window, project);
      }
    }
  } catch {
    return UNSAFE_SCOPE;
  }

  const eligibleSeqs: string[] = [];
  for (const line of rows) {
    const fields = line.split("\t");
    if (fields.length < 5 || !/^[0-9]+$/.test(fields[1])) return UNSAFE_SCOPE;
    const seq = fields[1];
    const kind = fields[2];
    const key = fields[3];
    if (kind === "heartbeat") {
      if (heartbeat) eligibleSeqs.push(seq);
      continue;
    }
    if (kind === "check") {
      // Always main-owned. Vetoes an all-or-nothing heartbeat review (it
      // needs the whole fleet's context); otherwise simply excluded, never a
      // reason to reject the rest of the queue.
      if (heartbeat) return UNSAFE_SCOPE;
      continue;
    }
    let project = "";
    if (kind === "signal") {
      const task = key.replace(/\.(?:status|turn-ended)$/, "");
      project = metadata.get(task) ?? "";
    } else if (kind === "stale") {
      project = metadata.get(key) ?? metadata.get(key.replace(/^fm-/, "")) ?? "";
    } else {
      // A kind fm_wake_append never emits: structural corruption, not an
      // ordinary main-only row.
      return UNSAFE_SCOPE;
    }
    if (!project) return UNSAFE_SCOPE;
    projects.add(project);
    eligibleSeqs.push(seq);
  }
  const eligible = heartbeat ? true : eligibleSeqs.length > 0;
  // Reached only after every row passed classification without a veto: a
  // heartbeat review is always eligible here, and a non-heartbeat scan that
  // ends up ineligible simply found no signal/stale rows to offer - ordinary
  // main-only content, not a fault.
  return { status: eligible ? "safe" : "unsafe", eligible, projects: [...projects], eligibleSeqs, corrupted: false };
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

function runGrantScript(state: string, grantScript: string, args: readonly string[]): number | null {
  try {
    const result = spawnSync("bash", [grantScript, ...args], {
      encoding: "utf8",
      env: {
        ...process.env,
        FM_STATE_OVERRIDE: state,
        FM_WAKE_QUEUE: `${state}/.wake-queue`,
        FM_WAKE_QUEUE_LOCK: `${state}/.wake-queue.lock`,
      },
    });
    return result.status;
  } catch {
    return null;
  }
}

export function activateEligibleRowsOwner(
  state: string,
  grantScript: string,
  ownerPid: number,
  generation: string,
): boolean {
  return runGrantScript(state, grantScript, ["activate", String(ownerPid), generation]) === 0;
}

export function writeEligibleRowsSnapshot(
  state: string,
  seqs: readonly string[],
  grantScript: string,
  generation: string,
): EligibleRowsSnapshotResult {
  if (seqs.length === 0 || seqs.some((seq) => !/^[0-9]+$/.test(seq))) return "error";
  const status = runGrantScript(state, grantScript, ["publish", generation, ...seqs]);
  if (status === 0) return "published";
  if (status === 3) return "main-owned";
  return "error";
}

export function releaseEligibleRowsSnapshot(state: string, grantScript: string, generation: string): boolean {
  return runGrantScript(state, grantScript, ["release", generation]) === 0;
}

export function deactivateEligibleRowsOwner(
  state: string,
  grantScript: string,
  ownerPid: number,
  generation: string,
): boolean {
  return runGrantScript(state, grantScript, ["deactivate", String(ownerPid), generation]) === 0;
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
  /** Set by accept(); read by the watcher after emit returns. */
  accepted: boolean;
  accept(): void;
}

export function createBranchDispatchOffer(
  message: string,
  projects: readonly string[] = [],
  heartbeat = false,
  eligible = false,
): BranchDispatchOffer {
  const offer: BranchDispatchOffer = {
    message,
    projects: [...projects],
    heartbeat,
    eligible,
    accepted: false,
    accept() {
      offer.accepted = true;
    },
  };
  return offer;
}
