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

export interface BranchDispatchOffer {
  /** The watcher's actionable close message (the wake reason line(s)). */
  message: string;
  /**
   * Exact project values from the unread task metadata this wake will drain.
   * Empty means the wake is fleet-wide or could not be scoped safely.
   */
  projects: readonly string[];
  /** Set by accept(); read by the watcher after emit returns. */
  accepted: boolean;
  accept(): void;
}

export function createBranchDispatchOffer(message: string, projects: readonly string[] = []): BranchDispatchOffer {
  const offer: BranchDispatchOffer = {
    message,
    projects: [...projects],
    accepted: false,
    accept() {
      offer.accepted = true;
    },
  };
  return offer;
}
