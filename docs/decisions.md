# Decision log

Captain-level routing and operating decisions whose reasoning the current-behavior docs do not carry.
Each entry links the page that owns its resulting contract.

## 2026-11-18 - a running goal item with no live task is startable again

**Decision.** A goal item marked `running` whose `task=` is empty, whose task has no `state/<task>.meta` record, or whose `bin/fm-crew-state.sh` verdict is `done` or `failed` is orphaned-running: `bin/fm-goal.sh startable` lists it like an open item, with the marker `orphaned running, no live task` in the projection, `show`, the drain's GOAL section and the mate brief.
The goal-stall tick and the drive floor read the same list, so such an item is stalled and startable again with no watcher change.
A `working` or `parked` verdict keeps the item running and out of the startable list.
[`configuration.md`](configuration.md#drive-floor-configdrive-floor) owns the resulting contract.

**Why.** The Miko CI/CD item `cf-queue-at-green` sat marked `running` with no task behind the mark for hours: the projection's startable predicate accepted only `state=open`, so GOAL DUTY never re-dispatched it and the goal-stall tick never named it, because a mark alone was read as someone being on the work.
A running mark over no live work is waiting, not working, and the crew-state verdict already says which tasks are live - re-deriving it in the projection would fork the meaning of a live task.

## 2026-11-17 - an idle startable goal item wakes the supervisor

**Decision.** In a home with `config/drive-floor`, a startable item of an active goal that no working lane is on raises `check: goal stalled` once it has waited the drive-floor hold, even when the fleet meets the floor.
The drive floor also stops counting page hosts as working lanes and counts startable goal items as work waiting.
The wake reuses the drive-floor scan, hold and ledger pattern and the existing check wake kind; no new daemon or watcher loop was added.
[`configuration.md`](configuration.md#drive-floor-configdrive-floor) owns the resulting contract.

**Why.** S1 made goals visible at every wake, but a wake only happens when something else changes, so an overnight goal with startable items and nothing running stayed silent until the captain returned.
A busy-looking pane polling a board also read as a working lane and hid exactly that idleness.

## 2026-11-17 - spawn calls admission and a held start goes into a durable queue

**Decision.** `bin/fm-spawn.sh` asks `bin/fm-capacity.sh --admit` before it creates anything for a fresh ship or scout start, and every deferral (admission, the load guard, project capacity) is recorded in `state/admission-queue` before the exit 75.
The watcher retries the queue on its poll, one start per tick, and the wake drain prints what is held.
The verdict adds the fleet-wide working count against the cap, the project's GitHub queue with queued runs older than 24 hours ignored, open pull request and merge-queue depth, and treats memory as a limit only below 8 GB available.
The cross-home worker table is refreshed by the watcher so the fleet count is under five minutes old.
[`configuration.md`](configuration.md#spawn-admission) owns the resulting contract.

**Why.** Load reached 202 at 30 lanes, and a deferred start only waited if Firstmate remembered to dispatch it again, which an away window does not guarantee.
The Miko rows of the worker table were eight days old, so main counted a fleet far smaller than the real one.
Thirty-nine zombie queued runs on one project would have held every start for good had they counted.
The GitHub limits are keys rather than defaults so a home with no `config/lane-capacity`, and a home that sets only a cap, behave exactly as before and never reach the network.
One start per tick is the hysteresis: each start raises the load the next verdict reads, and a recovered host must not take the whole queue at once.

## 2026-11-17 - every active goal drives while the captain is away

**Decision.** Away driving no longer depends on whether `/afk` named a goal.
Naming a goal with `--drive-goal` still records the captain's emphasis and orders it first in the GOAL section, but it is no longer the switch that turns driving on.
The away spend cap defaults to 50 and a lower value is accepted only when the call quotes the captain's own away words that set it.
[`configuration.md`](configuration.md#attended-and-away-authority) owns the resulting contract, and the [`drive-goal`](../.agents/skills/drive-goal/SKILL.md) skill owns the driving judgment.

**Why.** Zero of twelve away records named a goal, so the goal that mattered stayed context only overnight while startable items sat unmarked.
The captain's standing rule is a worker cap of 50 also while away, and overnight caps of 5 and 20 had been written against it.

## 2026-11-05 - a known five-hour limit holds a seat, and an unknown one never does

**Decision.** A five-hour window with a known used percent and published reset is a real limit on every account, including Claude, so a seat at that limit waits for its reset.
An idle window, an unreadable one, or one with no published reset never blocks a start.
[`configuration.md`](configuration.md#typed-dispatch-resolution-jevd-socket) owns the resulting contract.

**Why.** Live reads still show a five-hour window on Claude seats, so treating it as absent would start work on a seat that is out of room, while the standing rule that an unknown quota never blocks a start still covers every window that cannot be read.

## 2026-11-05 - up to 50 workers, and unlanded work is finished rather than parked

**Decision.** A home runs up to 50 ordinary workers in parallel.
The primary firstmate and persistent secondmates do not count toward that cap, and there is no automatic pause at any usage percentage.
[`configuration.md`](configuration.md#lane-capacity-configlane-capacity) owns the cap's file format.
Work that cleanup refuses as uncommitted or unmerged is finished and merged by firstmate rather than sent to the captain, and never forced; [`ship-landing`](../.agents/skills/ship-landing/SKILL.md) owns the procedure.

## 2026-11-04 - no-mistakes steps choose their seat from two pools

**Decision.** A no-mistakes step takes its seat from a fixed resolver row, with no model call per step.
Pool 1 is claude1 or claude2.
Pool 2 is claude3 and every Codex account, used only when pool 1 has no seat with room.
A live five-hour window's short runway ranks seats for the pipeline only, claude3 stops at 20 percent weekly room left, and Codex seats run at the step's reasoning class.
When both pools are empty the step fails and names every seat's reset, with no downgrade and no GLM.
[`configuration.md`](configuration.md#pipeline-seat-rows) owns the resulting contract.

**Why a fixed row.** The step name already fixes the row, and a model call per step would add cost and turn a Jev outage into a captain pick that a pipeline cannot answer.

**Why claude3 comes before Codex inside pool 2.** After a mid-run switch to Codex, a no-mistakes run never returns to the Claude adapter, so a run that goes to Codex can no longer reach claude3.
Ranking pool 2 by spendPriority alone would normally pick Codex first, because claude3's priority runs far lower, so claude3 sits in an earlier `seat_tier` while it is above its floor.
This keeps the two kinds of seat in one pool, and the order stays a row declaration rather than code.

**Why the floor reads the weekly window.** A quota row can be bounded by both windows, so a floor on that row would stop claude3 on a low five-hour window while its week still has room.

**Why an unreadable floor takes the seat out.** Other unreadable seats fall back to the first seat of their tier so a brief quota outage does not stop the pipeline, but the floor is a limit the captain set, so missing evidence does not override it.

## 2026-11-09 - worker reservation and corrected no-mistakes pools

**Decision.** This supersedes the pool membership, ordering rationale, and unreadable-seat fallback in the 2026-11-04 entry above.
The no-mistakes pool 1 is claude1/claude2; pool 2 is codex1/codex2, then glm at a later seat tier.
Claude3 is excluded from worker seats and reserved for firstmate and secondmates.
Ordinary workers have no provider-family precedence: task-matched candidates compete mainly on quota and reset time, with no design work on GLM.
When all quota evidence is unreadable, logged round-robin chooses within the open tier rather than declaration order; measured-quota ranking and exact-tie handling stay unchanged.
[`configuration.md`](configuration.md#crew-dispatch-profiles-configcrew-dispatchjson) owns worker eligibility and selection, and [pipeline seat rows](configuration.md#pipeline-seat-rows) own the configurable pool mechanism.

**Why.** A supervisor login is never a worker reserve, and an unreadable quota must not turn Claude-first array declarations into a provider preference.
The no-mistakes pool order is a separate policy, not a rationale for biasing ordinary worker selection.

## 2026-11-18 - boot resume restores through the primary, bounded by a shared ledger

**Decision.** A WSL reboot no longer requires captain action: a systemd user oneshot (`bin/fm-boot-resume.sh`, unit rendered by `bin/fm-boot-resume-install.sh`) and a 5-minute watchdog timer (`bin/fm-watchdog-beat.sh`) bring back the primary firstmate session, the secondmates, and the recorded workers, gated by the kill switch (`config/boot-resume-off`), the unattended posture (a standing away record or an active goal; quiet mode is not a resume posture), per-boot idempotence (`/proc/sys/kernel/random/boot_id`), and a live-primary skip.
The primary restore is herdr-pane based: the exact conversation id recorded in `state/.lock-session` matched against herdr's per-pane `agent_session.value` (ambiguous or missing matches are typed refusals, never guesses), then `herdr agent start ... --resume <id>` plus one standing recovery prompt.
Every attempt spends from one bounded ledger (`state/.boot-resume-attempts`, 2 per kind per 3600s) whose overflow parks the kind behind a marker and leaves exactly one idempotent inbox note.
[`boot-resume.md`](boot-resume.md) owns the operator contract, including the Windows keepalive steps that stay a captain action.

**Why restore through the primary.** A live primary harness is the one mechanism that already re-establishes everything else: its SessionStart hook runs the locked session-start sweeps (secondmate liveness included) and the wake-queue drain, and its Stop hook re-arms the watcher chain.
Restoring anything around the primary would duplicate those owners with weaker guarantees, and a script blind-relaunching recorded workers would bypass the no-mistakes run rules, duplicate-worker guards, and fresh-dispatch-receipt judgment that the stuck-crewmate-recovery skill owns; the recovery prompt hands that judgment to the agent instead.

**Why a watchdog beat.** The reboot can also kill only the watcher while the primary lives, so a boot-path-only resume would leave a silent beacon until the next reboot.
The tick reuses `fm_watcher_healthy` (pid, lock identity, beacon) as the single health owner and answers through the primary (one standing nudge prompt plus one inbox note) rather than a shell-side arm, because the verified arm path and its stalled-holder eviction rules belong to the primary's turn-end chain.
**Why one ledger.** Boot loops and a 5-minute timer can turn retries into a prompt storm; both actors spending from the same budget, with park markers and single durable notes, keeps the recovery bounded without adding a new supervision layer.
