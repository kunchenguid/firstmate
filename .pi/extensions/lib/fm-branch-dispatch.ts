import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";

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
   * The exact task ids the eligible signal/stale rows name (a signal row by
   * its status-log key, a stale row through the task metadata recording that
   * endpoint). The branch may report only these tasks while it handles the
   * wake; `fleet` or a task it merely remembers is refused (docs/
   * pi-supervision-branch.md "Components and their owners"). Empty for a
   * heartbeat, which is not scoped by task.
   */
  eligibleTasks: string[];
  /**
   * True only when this scan itself is untrustworthy: the queue or its
   * metadata could not be read, a line fails the structural tab-field check,
   * or an unresolvable signal/stale row was found. False whenever the scan
   * completed cleanly and simply found nothing (or nothing further) eligible
   * for the branch right now: status "unsafe" with corrupted false is the
   * ordinary "ordinary main-only content, nothing here for the branch" case,
   * not a fault, and callers should treat it as ordinary absence rather than
   * escalating. A main-owned check row is never a source of corruption in
   * either mode.
   */
  corrupted: boolean;
  /**
   * The exact "key" field of every decision-owned signal or stale row this
   * scan excluded. Signal rows are marked by bin/fm-watch.sh; stale rows are
   * decision-owned when their task's current declaration is captain-held.
   * fm-primary-pi-watch.ts cross-references these keys against the current
   * trigger so its entire coalesced batch is forced to main.
   */
  needsDecisionKeys: string[];
}

const EMPTY_SCOPE: UnreadWakeScope = {
  status: "empty",
  eligible: false,
  projects: [],
  eligibleSeqs: [],
  eligibleTasks: [],
  corrupted: false,
  needsDecisionKeys: [],
};
const UNSAFE_SCOPE: UnreadWakeScope = {
  status: "unsafe",
  eligible: false,
  projects: [],
  eligibleSeqs: [],
  eligibleTasks: [],
  corrupted: true,
  needsDecisionKeys: [],
};

// scopeForUnreadWake is the single owner of branch-eligibility classification
// (docs/pi-supervision-branch.md "Autonomy"; docs/watcher-continuity.md
// "Per-actor acknowledgement"). bin/fm-wake-drain.sh never reclassifies a row
// itself - it only consumes the exact sequence-number snapshot this function
// (via writeEligibleRowsSnapshot) hands it.
//
// A check-kind row - merge-confirmation polls, Relay mentions, credential/auth
// failures, and every other legitimately main-only class - never vetoes a scan
// in either mode. It is simply excluded from eligibleSeqs and left queued for
// main, which is woken for it on that check's own watcher cycle
// (fm-primary-pi-watch.ts forces every check-kind TRIGGER to main), so nothing
// starves by being left behind.
//
// A signal row whose payload is "needs-decision:"-prefixed, or a stale row
// for a task whose current declaration is captain-held, gets the identical
// treatment: excluded from eligibleSeqs, never a scan veto, and forced to main
// on its own triggering close (fm-primary-pi-watch.ts's offerWakeToBranch).
// Heartbeat handling remains independent.
//
// That applies to a heartbeat review too, and it is the whole point: a
// heartbeat used to be deferred to main merely because some unrelated check
// row happened to be sitting unread, which put a routine fleet review in the
// captain's chat for a reason that had nothing to do with the fleet. A
// permanently main-owned row is not fleet context the branch is missing, so it
// no longer rides the heartbeat into main (docs/pi-supervision-branch.md
// "Heartbeat routing").
//
// The heartbeat's all-or-nothing contract is unchanged in what it actually
// guarantees: a heartbeat review takes EVERY branch-ownable unread row or none
// of them. An unresolvable signal/stale row (unmapped project) still vetoes the
// whole scan in both modes, because that is a data/metadata problem this
// function cannot safely reason past, not an ordinary main-only event. A row
// this repo's fm_wake_append could never have produced (an unknown kind, or a
// line that fails the structural tab-field check) also still vetoes the whole
// scan - that is queue corruption, not an everyday mixed queue.
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
  // The task id behind each key a signal or stale row may carry: the task id
  // itself, or the endpoint its metadata records.
  const taskByKey = new Map<string, string>();
  try {
    for (const name of readdirSync(state)) {
      if (!name.endsWith(".meta")) continue;
      const task = name.slice(0, -5);
      const fields = readFileSync(`${state}/${name}`, "utf8").split(/\r?\n/);
      const project = fields.find((line) => line.startsWith("project="))?.slice(8) ?? "";
      const window = fields.find((line) => line.startsWith("window="))?.slice(7) ?? "";
      if (project) {
        metadata.set(task, project);
        taskByKey.set(task, task);
        if (window) {
          metadata.set(window, project);
          taskByKey.set(window, task);
        }
      }
    }
  } catch {
    return UNSAFE_SCOPE;
  }

  const eligibleSeqs: string[] = [];
  const eligibleTasks = new Set<string>();
  const needsDecisionKeys: string[] = [];
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
      // Always main-owned, in every mode: excluded from what the branch may
      // claim, never a reason to reject the rest of the queue and never a
      // reason to send an otherwise-eligible heartbeat review to main.
      continue;
    }
    let project = "";
    let task = "";
    if (kind === "signal") {
      const payload = fields[4] ?? "";
      if (/^needs-decision:/.test(payload)) {
        // Main-owned exactly like a check-kind row above: a needs-decision
        // status append surfaced through the actionable signal path is
        // excluded from what the branch may claim without vetoing the scan
        // (docs/pi-supervision-branch.md "Autonomy").
        needsDecisionKeys.push(key);
        continue;
      }
      task = key.replace(/\.(?:status|turn-ended)$/, "");
      project = metadata.get(task) ?? "";
    } else if (kind === "stale") {
      task = taskByKey.get(key) ?? taskByKey.get(key.replace(/^fm-/, "")) ?? "";
      project = metadata.get(key) ?? metadata.get(key.replace(/^fm-/, "")) ?? "";
      if (task) {
        const statusPath = `${state}/${task}.status`;
        if (existsSync(statusPath)) {
          let statusLines: string[];
          try {
            statusLines = readFileSync(statusPath, "utf8").split(/\r?\n/).filter(Boolean);
          } catch {
            return UNSAFE_SCOPE;
          }
          if (/^captain-held(?:\s|\[|:)/.test(statusLines.at(-1) ?? "")) {
            needsDecisionKeys.push(key);
            continue;
          }
        }
      }
    } else {
      // A kind fm_wake_append never emits: structural corruption, not an
      // ordinary main-only row.
      return UNSAFE_SCOPE;
    }
    if (!project || !task) return UNSAFE_SCOPE;
    projects.add(project);
    eligibleTasks.add(task);
    eligibleSeqs.push(seq);
  }
  const eligible = eligibleSeqs.length > 0;
  // Reached only after every row passed classification without a veto. A scan
  // that ends up ineligible simply found nothing the branch may claim - a
  // queue of purely main-only content, not a fault. (Before check rows stopped
  // vetoing a heartbeat, this point was unreachable for a heartbeat with an
  // empty eligible set, so reading eligibility off the claim set rather than
  // off the heartbeat flag changes no pre-existing outcome and keeps a
  // heartbeat from being offered with nothing to hand over.)
  return {
    status: eligible ? "safe" : "unsafe",
    eligible,
    projects: [...projects],
    eligibleSeqs,
    eligibleTasks: [...eligibleTasks],
    corrupted: false,
    needsDecisionKeys,
  };
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
  settlement: Promise<void>;
  accept(settlement?: Promise<void>): void;
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
    settlement: Promise.resolve(),
    accept(settlement = Promise.resolve()) {
      offer.accepted = true;
      offer.settlement = settlement;
    },
  };
  return offer;
}
