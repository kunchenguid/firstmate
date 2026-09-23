// One owner for the supervision-branch provider-error latch state machine,
// shared by the Pi supervision-branch extension
// (.pi/extensions/fm-branch-supervision.ts) and the Claude Code
// supervision-branch mod (.claude/mods/fm-branch-mod/hooks/branch.ts).
//
// The machine owns, once: the consecutive-failure count, the threshold that
// latches the branch off, the cooldown computation on every failure while a
// latch is active (first latch takes the base cooldown, each later failure
// doubles the active cooldown up to the cap), time-gated admission of one
// recovery probe per cooldown when the policy arms probes, the probe-in-
// flight slot, probe-failure cooldown extension, release of a slot whose
// wake never reached the provider, and full recovery (latch cleared, count
// reset) on a clean settlement.
//
// Host seams - the FAILURE PREDICATE is unified (the captain's 2026-09-20
// ruling adopted the mod's counting on Pi); the rest are declared, not
// unified (firstmate's A4 decision D3=C for these):
//   - The FAILURE PREDICATE. Both hosts now count the same rule: a completed
//     branch turn that ended in a provider error OR produced no report is
//     one recordFailure(), and any other completed turn is one
//     recordSuccess(). What stays host input is only each host's own
//     detection of those two states (the mod reads its turn reason and
//     report ledger; the Pi extension reads its settled prompt transcript
//     and durable-report revision). On Pi a report-less, error-free
//     settlement still throws to the watcher - it now also counts one
//     consecutive failure, where before it neither counted nor reset.
//   - NOTIFICATIONS. The Pi extension renders a first-latch note and a
//     recovery note into main (the first-latch wording names repeated
//     failures, not provider errors only); the mod logs a line on every
//     latch entry. Both render from this machine's structured verdicts
//     (firstLatch, recovered), never from their own counting.
//   - BROKEN-BRANCH VIEW. The Pi extension keeps a host-side "broken"
//     detail string that also covers non-provider breakage (branch build
//     failures, reconcile failures); this machine owns only the
//     provider-error latch component of that state.
//   - THE CLOCK is injected, so tests drive the whole schedule without
//     waiting.
//
// Per-host policies, parameterised by firstmate's A4 build spec:
//   - Pi: threshold 2, base cooldown 5 minutes doubling to a 1 hour cap,
//     one recovery probe per cooldown.
//   - Mod: threshold 2, fixed 5 minute cooldown (base == cap), no probe.
//
// The mod loads this file directly from its own lib/ directory; the repo's
// lib/ entry is a tracked symlink to it (the Calm-mod pattern, inverted
// because a hooks module may import only its own files, never across the
// mod boundary). This file must therefore stay dependency-free: no imports
// of any kind.

export interface ProviderErrorLatchPolicy {
  /** Consecutive failures that arm the first latch. */
  threshold: number;
  /** Cooldown of the first latch; also the doubling base. */
  baseCooldownMs: number;
  /** Doubling cap; equal to baseCooldownMs for a fixed schedule. */
  maxCooldownMs: number;
  /** Whether one wake per elapsed cooldown is admitted as a recovery probe. */
  recoveryProbe: boolean;
}

export interface LatchFailureVerdict {
  /** Consecutive failure count after this failure. */
  streak: number;
  /** True when the latch is active after this failure. */
  armed: boolean;
  /** True when this failure moved the latch from inactive to active. */
  firstLatch: boolean;
  /** Cooldown this failure applied; 0 when no latch state changed. */
  cooldownMs: number;
  /** Epoch ms when the latch expires; 0 when not armed. */
  latchedUntil: number;
}

export type LatchAdmission =
  | { decision: "open" }
  | { decision: "probe" }
  | { decision: "latched" };

export interface LatchSuccessVerdict {
  /** True when a clean settlement cleared an active latch. */
  recovered: boolean;
  /** Consecutive failure count after the reset (always 0). */
  streak: number;
}

export function createProviderErrorLatch(policy: ProviderErrorLatchPolicy, now: () => number) {
  let streak = 0;
  let armed = false;
  let latchedUntil = 0;
  let activeCooldownMs = policy.baseCooldownMs;
  let probeInFlight = false;

  // One host-counted failure. Below the threshold with no active latch this
  // only counts; from the threshold on - and on every later failure while
  // the latch stays armed - it arms or extends the latch.
  function recordFailure(): LatchFailureVerdict {
    streak += 1;
    const wasArmed = armed;
    if (streak < policy.threshold && !wasArmed) {
      return { streak, armed: false, firstLatch: false, cooldownMs: 0, latchedUntil: 0 };
    }
    const cooldownMs = wasArmed ? Math.min(policy.maxCooldownMs, activeCooldownMs * 2) : policy.baseCooldownMs;
    armed = true;
    activeCooldownMs = cooldownMs;
    latchedUntil = now() + cooldownMs;
    probeInFlight = false;
    return { streak, armed: true, firstLatch: !wasArmed, cooldownMs, latchedUntil };
  }

  // Admission decision for one offered wake, WITHOUT mutating state: the
  // host commits to a probe by calling beginProbe() only once it has
  // accepted the wake. An armed latch admits nothing before its cooldown
  // elapses; with probes armed it then admits exactly one wake as the
  // recovery probe; without probes it opens again once the cooldown has
  // passed (the fixed-schedule hosts).
  function admitWake(): LatchAdmission {
    if (!armed) return { decision: "open" };
    if (probeInFlight) return { decision: "latched" };
    if (now() < latchedUntil) return { decision: "latched" };
    if (policy.recoveryProbe) return { decision: "probe" };
    return { decision: "open" };
  }

  function beginProbe(): void {
    if (armed && policy.recoveryProbe) probeInFlight = true;
  }

  // Settles the probe slot when an admitted probe's wake finishes. A failed
  // probe keeps the latch armed and, if its cooldown already elapsed, re-
  // extends it by the active cooldown so the next probe waits a full term.
  function finishProbe(): void {
    probeInFlight = false;
    if (armed && now() >= latchedUntil) {
      latchedUntil = now() + activeCooldownMs;
    }
  }

  // Releases an admitted probe slot whose wake never reached the provider
  // (the host routed it away before its prompt): nothing was probed, so the
  // cooldown is not extended and the next admitted wake becomes the probe.
  function releaseProbe(): void {
    probeInFlight = false;
  }

  // One host-counted clean settlement: resets the count and, when a latch
  // was active, clears it (the host renders its recovery notification from
  // the recovered flag).
  function recordSuccess(): LatchSuccessVerdict {
    const recovered = armed;
    streak = 0;
    armed = false;
    latchedUntil = 0;
    activeCooldownMs = policy.baseCooldownMs;
    probeInFlight = false;
    return { recovered, streak };
  }

  // Host lifecycle that ends the latch from outside the failure/success
  // stream (a branch conversation replacement or a model/effort change).
  function reset(): void {
    streak = 0;
    armed = false;
    latchedUntil = 0;
    activeCooldownMs = policy.baseCooldownMs;
    probeInFlight = false;
  }

  function isArmed(): boolean {
    return armed;
  }

  /** True between beginProbe() and the probe wake's finishProbe(). */
  function isProbing(): boolean {
    return probeInFlight;
  }

  return { recordFailure, admitWake, beginProbe, finishProbe, releaseProbe, recordSuccess, reset, isArmed, isProbing };
}
