# Supervision on herdr — spec

`fm/muxwire-h2` moved the crew runtime onto herdr and deliberately did not touch
`bin/fm-watch.sh` or `bin/fm-context-watch.sh`. Both still sensed through tmux, so
for every crewmate spawned after the cutover the fleet lost the two guarantees the
whole supervision loop rests on:

* **nothing noticed a wedged agent** — `fm-watch.sh` inferred staleness by capturing
  pane text and comparing hashes, and a herdr pane has no tmux pane to capture; and
* **nothing auto-compacted a bloating one** — `fm-ctx-statusline.sh` stamped
  `managed:false` whenever `$TMUX_PANE` was unset and `fm-context-watch.sh`
  re-confirmed its target through tmux at fire time, so no herdr crewmate was ever
  selected for a checkpoint. It simply hit its context ceiling and died with no
  handoff written.

**Swap the sensor, keep the loop.** This is D4 in `docs/plans/cmux-herdr-surface-split.md`.
The watcher's loop, singleton lock, coalescing window, exponential backoff and durable
wake queue are untouched; only what they sense changed. The watchdog's thresholds
(captain ≥185k, crew/secondmate ≥50%), its fresh-handoff guard, its cooldown and its
per-secondmate scoping are untouched too.

## The fleet is mixed, so this is additive

Pre-cutover crewmates live in tmux windows whose `state/<id>.meta` has no `mux=` line,
and some hold unlanded commits. Every tmux behaviour keeps working, and the routing
discriminator is the meta — the same one `fm-send` and `fm-peek` route on (gate h4).
`mux=herdr` means herdr; anything else, including absent, means the drain.

## The stale sense

`bin/fm-sense-lib.sh` holds the sensing, split out of `fm-watch.sh` so it can be
sourced and unit-tested without starting a watcher.

* `herdr api snapshot` returns every agent's `agent_status` in **one** call, so the
  herdr sense is O(1) at any fleet width, fetched at most once per poll cycle and only
  when the home actually has a herdr crewmate.
* **`agent_status: unknown` is the only value that means "stopped without reporting."**
  `idle` and `done` do not: an agent between turns is idle, an agent awaiting a verdict
  is idle, and an agent whose turn ended while its own background shells keep running is
  idle. That last case is the third false-report shape, and on herdr it is covered *by
  construction* rather than by a heuristic — it never presents as `unknown`, so it never
  wakes. On the draining tmux path it remains indistinguishable from a wedge, and this
  spec says so plainly rather than guessing.
* A pane **absent** from the snapshot raises nothing. That is orphan detection, which is
  out of scope, and an unreachable herdr produces the same emptiness — both stay silent
  rather than inventing a wake nobody can act on. But raising nothing is not *remembering*
  nothing: the pane's bookkeeping is reset, because herdr no longer knowing of an agent
  there ends whatever episode was in progress. See the suppressor below.
* **The suppressor is per episode, not per pane.** `.stale-<key>` means "this stalled state
  was already reported", and under tmux the value was a content hash, so a fresh wedge
  always carried a fresh value and the marker aged out by accident. A herdr observation is
  *categorical* — the literal `unknown` every time — so keeping the tmux bookkeeping
  unchanged would have made a herdr pane wake exactly once in its life. Two things end an
  episode and clear the marker: the observation changing, and the pane ceasing to hold an
  agent. Both matter, because `stuck-crewmate-recovery` relaunches an agent **in the same
  pane** and the relaunch passes through "no agent" — so a crewmate that wedges, is
  relaunched, and wedges again must wake again, even when no healthy sample lands in
  between.
* **The session pin reaches the verb, not just the probe.** `fm-sense-lib.sh` sources
  `fm-herdr.sh` and calls `fm_herdr_session` before every snapshot, because every herdr
  verb takes its session from `$HERDR_SESSION` and defaults to `default`, and
  `FM_HERDR_SESSION` only reaches them through that export. Skipping it polls `default`
  while a pinned fleet runs elsewhere, and the answer comes back *empty rather than
  failing* — the whole fleet then reads as absent, which is silent blindness rather than an
  error anyone would see. The test fake models this: its `api snapshot` is session-scoped,
  so a snapshot aimed at the wrong session returns no agents.
* The snapshot is parsed, never grepped. An agent record carries `terminal_title`, which
  is the crewmate's own prompt text; a line-oriented extractor lets a title containing
  `"agent_status":"unknown"` forge a stale wake against another pane. The test fake
  embeds exactly that title in every record.
* The **`kind=secondmate` exception survives**: a secondmate idling on its own watcher is
  healthy, and its parent supervises it through status writes and the heartbeat review.

## The missing state: awaiting a verdict

A crewmate that appended `done:` has reported. Supervision had no state for "the claim is
in and the ball is in firstmate's court", so a correctly-finished agent was
indistinguishable from a wedged one — four false reports across 2026-08-28..31, including
firstmate telling the captain a branch was stalled while its fix was already committed and
mutation-tested. Same root cause as the blindness above: state inferred from the pane
instead of read.

`fm_sense_awaiting_verdict` holds a stale wake when the task's last status line is `done:`
**and** one of:

* a verify cycle is running — `bin/fm-verify.sh` writes `state/<id>.verifying` at entry and
  removes it on exit, so this is a fact rather than an inference; it also ages out
  (`FM_VERIFY_RUNNING_TTL`, default 3600s) so a verifier killed outright cannot suppress
  supervision forever;
* the last verdict decision is `approve:` — accepted, waiting on firstmate's next
  instruction; or
* the last decision is `escalate:`, or the reject count has reached the attempt cap — the
  captain owns it and the crewmate was told to stop.

A `reject:` is deliberately **not** in that set: the findings were relayed and the crewmate
is expected to be working, so an idle pane there is exactly the signal stale detection
exists to raise. `needs-decision:` and `blocked:` are also left unchanged — they are a
wider generalisation than the observed defect, and widening the suppression is the way to
re-introduce blindness.

**Suppression is not memoised.** Nothing is written to `.stale-*` while a wake is held, so
the moment the ball returns to the crewmate the very next cycle wakes on the unchanged
pane.

## The context watchdog

Three fire-time touchpoints route by surface, and the tmux halves are byte-identical to the
pre-cutover path:

| touchpoint | herdr | drain |
| --- | --- | --- |
| is the pane busy | `fm_herdr_is_busy` (`agent_status == working`) | `fm_pane_is_busy` |
| deliver the checkpoint | `bin/fm-send.sh`, which already routes by target | unchanged |
| deliver `/clear` | `fm_herdr_prompt` | `tmux send-keys -l '/clear'` + Enter |

The busy-guard is load-bearing on both — firing means interrupting a crewmate mid-turn and
then wiping its conversation. On herdr it is strictly better than the tmux detector: a
lifecycle field rather than a regex over rendered text, so a pane whose title merely
contains "working" is no longer mistaken for one that is.

Two further changes make the herdr path reachable at all:

* **MEASURE.** `fm_ctx_managed_target` (in `fm-ctx-lib.sh`) is the one owner of "firstmate
  owns this pane", and it is opt-in by construction on each surface: under tmux, the pane's
  session is `FM_TMUX_SESSION`; under herdr, `$FM_HERDR_PANE` is set, which only
  `bin/fm-spawn.sh` injects into the launch string of a pane it created. herdr sets no
  environment variable in a pane, so the pin is the only way a session can learn its own
  address. `fm_ctx_window_key` uses that pane id as the stable key — it survives a
  `/clear`, and it is also the address herdr steers by.
* **Fire-time ownership.** `_ctx_target_in_session` re-confirms a herdr pane against *this
  home's own metas* (`window=<pane>` plus `mux=herdr`), which is stronger evidence than a
  session name: a herdr pane the fleet never spawned has no meta and is never ours to
  steer. The state dir is now **passed in** rather than re-derived from the environment, so
  a scoped watch (`--scope <home>`) can never ask one home's metas about another's pane.

The launch-prefix caveat is inherited, not new: `FM_HERDR_PANE` rides the same `VAR=x <cmd>`
prefix as `FM_HOME` and `HERDR_SESSION`, so it does not survive an agent restarted by hand
in its own pane (AGENTS.md, "herdr workspace hygiene").

## One inherited red, fixed on the way

`gate-h5-herdr-live-roundtrip` arrived red on this branch (it is red on the merge base, and
was red before this branch's first edit). Diagnosed against herdr 0.8.2: for a pane with
**no agent** — a bare shell — `herdr agent read` answers `agent_not_found` and the
`herdr pane read --source recent` fallback then *succeeds with empty output*, because the
scrollback source is backed by the agent session. `fm_herdr_read` therefore reported a
plainly-populated pane as silent, through its success path, which is exactly the confusion
its error path exists to prevent. It now retries `visible` only where `recent` had nothing
to give; the two sources are still not interchangeable, and an agent pane never reaches
that branch because `agent read` succeeds first. Fixed here because a red ledger blocks the
branch and the defect is in the herdr read path supervision depends on.

## Why every "nothing happened" assertion carries proof

These gates drive the real watcher and are wall-clock bounded, so two failure modes sit on
opposite sides of one budget. Too short and a busy machine starves a wake that was coming —
w1 and w2 flaked red under a full `ledger verify` sweep while passing standalone 24 runs
running. Too long and a case asserting that *nothing* happens passes trivially, because a
watcher that never reached its decision looks exactly like one that decided not to wake.

So the budget is generous **and** every negative case demands evidence the decision point
was reached: `fm_watch_assert_sensed` (the per-target counter advanced, i.e. the wake/no-wake
branch ran), `fm_watch_assert_ran` (a full cycle completed — the available evidence for a
`kind=secondmate`, whose bookkeeping is deliberately skipped before any marker is touched),
and `fm_watch_assert_reset` (the pane's episode was ended because it stopped holding an
agent). Each assertion is itself proven to fire on an empty state dir.

## Out of scope

Any sweep, orphan-closing or pane-closing behaviour; the domain registry; the `config` verb;
the `doctrine` verb; retiring tmux for the crew.

## Gates

- **w1** a wedged herdr crewmate raises a stale wake — and does so *again* after recovering
  or after a relaunch through no-agent (once per wedge, never once per pane); the pin
  reaches the snapshot verb; an idle one does not wake; the fleet is read in one snapshot
  call; and a herdr pane is never sensed through tmux
- **w2** a wedged tmux crewmate still raises one, a pre-seam meta still takes the tmux
  sense, a busy pane is still suppressed, and a pre-seam **secondmate** keeps its exemption
- **w3** an idle `kind=secondmate` herdr pane raises none, while an ordinary crewmate in the
  identical state still wakes (the exception is per target, not per fleet)
- **w4** an over-threshold herdr crewmate is measured as managed, selected, checkpointed,
  `/clear`ed over herdr and rehydrated, end to end — starting at the real statusLine, in the
  environment `fm-spawn` actually gives a herdr crewmate
- **w5** a busy over-threshold herdr pane is NOT fired on; the busy read is the lifecycle
  field rather than the terminal title; a pane with no meta in this home is never fired on
- **w6** a `done:` claim awaiting a verdict raises no stale wake (verify running, approved,
  or cap-blocked), while a rejected claim and a mid-work crewmate still do, and holding a
  wake does not consume it
- **w7** away-mode escalates a wedged herdr crewmate instead of dropping it: the daemon
  maps a herdr pane to its task through the meta both ways, escalates a persistent stale
  marker naming the pane, clears it quietly for a working one, and still escalates a
  draining tmux window through the enumeration fallback
