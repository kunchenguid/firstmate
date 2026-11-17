# Decision log

Captain-level routing and operating decisions whose reasoning the current-behavior docs do not carry.
Each entry links the page that owns its resulting contract.

## 2026-11-17 - every active goal drives while the captain is away

**Decision.** While an away record stands, every active goal drives until it is done or closed, whether or not `/afk` named it.
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
