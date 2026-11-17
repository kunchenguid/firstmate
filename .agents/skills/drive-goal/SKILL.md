---
name: drive-goal
description: >-
  Load when the captain names a goal to keep driving, on "show goal" or "close goal", when /afk words name a goal, when writing or editing a goal's items from its plan, and when steering an owner's marks or closing a goal through bin/fm-goal.sh.
user-invocable: false
metadata:
  internal: true
---

# drive-goal

A goal is one durable record, `state/goals/<id>.goal`, that the captain names and this home drives to done across away windows and attended turns alike.
`bin/fm-goal.sh` owns the record schema, the mark grammar, the projection, the locks and the archive; its `--help` owns the exact flags, and this skill owns only firstmate's judgment steps around it: writing the items, choosing classes, steering owners, and closing.
The wake drain prints the live state as a GOAL section at every wake, so no goal fact is carried in memory.

## Writing a goal from its plan

When the captain names a goal, write its items from the plan the captain approved, in the same turn when a plan exists.
If `/afk` names a goal that has no record yet, write it in that same entry turn so the away session never drives a goal with no record.
Record the captain's naming words verbatim through `--named-by` and the plan's path or URL through `--plan`; the record, not the conversation, is the mandate's provenance.
When the plan lives in a secondmate's own material, ask that secondmate for the item file with `bin/fm-send.sh` instead of inventing the items here; for Miko I1 the plan lives on the secondmate's page.
Then run `bin/fm-goal.sh start <id> --title <t> --done-when <t> --named-by "<his words>" --plan <path> --items-file <path>`; the script refuses unsafe ids, duplicate item ids, unknown `after` ids, dependency cycles and unknown classes, so a refusal is a plan defect to fix, not a flag to force.

Write items so a cold reader can act on each line: one item names its owner and its next step on that one line, `after` orders the dependencies, and `task` names the child task so a landing is detected mechanically.
Make the last item the done-when check itself, with explicit evidence, because closing requires every item done or dropped.
Class each item honestly: `drive` is the default for reversible in-plan steps, and `captain` marks anything that needs the captain: money, a real architecture deviation, or credentials and logins.
A destructive, irreversible, or security-sensitive step is `drive` only behind the away limits' written analyse-first gate (an analysis recorded before the action, showing nothing crucial breaks) and `captain` whenever that gate cannot clear - anything shared by other lanes, unpushed or unmerged work, credentials, and production data are always crucial.
A `captain` item is never advanced while the captain is away; when one is reached, hold it for the captain under the captain-hold lifecycle with its category named in the hold reason.
When the plan changes later, `bin/fm-goal.sh edit <id> --items-file <path>` keeps every mark, and an item dropped while it still has marks shows as unplanned drift in `show`.

## Driving it

Attended or away, the drain's GOAL section is the live state and its GOAL DUTY line is the standing duty: start or advance every startable item nobody is on.
Steer the owning second mate with `bin/fm-send.sh`, or, for an item this home owns, dispatch it within the spend cap from a backlog item filed for exactly that step.
When `/afk` words name a goal, the afk skill's entry carries the id through `--drive-goal`; every active goal drives while away whether or not the record names it, and the entry output lists the goals that will drive.

## Marks and the secondmate duty

After every landing, and after any change to one of its items, the item's owner runs `bin/fm-goal.sh mark <id> <item> <state> [--task <task-id>] -- <note>`; in a secondmate home that same command routes the mark to the parent channel itself, so a second mate never writes the parent's record.
Steer by that duty, not by hope: an `unrecorded landing` line in the GOAL section is the gap, and the owner's next mark closes it.
Before retiring a second mate that owns items, reassign those items first through `edit`, so no item's owner stream disappears underneath the projection.

## Showing and closing

On "show goal", relay `bin/fm-goal.sh show <id>` in outcome language: how far it is, what is startable, and what waits on whom.
On "close goal <id>", only main closes, at the captain's word: `bin/fm-goal.sh close <id> --captain --words "<his words>"`.
`close <id> --done` is the other path and refuses while any item is not done or dropped; the away session may run it when the command accepts, reporting it as verdict captain under "per your away instructions".
Both forms archive the record with its marks.
After a close, retire the matching standing rule in `data/captain.md` at the next attended turn: inspect the page first, then update it under its inspect-then-update contract, because a goal's done-when typically duplicates a standing rule that must stop driving once the goal is done.
