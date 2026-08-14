# Visual patterns

This reference owns visual selection, minimal templates, symbols, arrow meanings, and visual anti-patterns for `visual-technical-communication`.
Read it when selecting, drafting, or reviewing a visual.

## Select by relationship

| Reader question | Primary format | Minimum content | Prefer prose when |
|---|---|---|---|
| What happens after each choice? | Flow | Start, actions, labeled decisions, outcomes | The sequence has no branch |
| Which states exist and what changes them? | State | Initial state, states, labeled transitions, terminal cues | The subject is a schedule |
| What happens when and for how long? | Timeline | Time direction, events, meaningful intervals | The order is logical rather than temporal |
| How do options compare on shared criteria? | Matrix | Parallel criteria, options, explicit cell meanings | Cells require paragraph-length qualifications |
| How much is used, available, likely, or risky? | Bar or scale | Baseline, value, unit, direction, textual value | Values are categorical or incomparable |
| What changed between two structures? | Before and after | Same viewpoint, named changes, unchanged context | Intermediate steps are the main question |
| Where are boundaries and allowed dependencies? | Layered architecture | Layers, components, external boundary, arrow meanings | Runtime sequence is the main question |

Use one primary format for one reader question.
Combine formats only when each one answers a distinct necessary question.

## Use consistent semantics

Define every non-obvious line, enclosure, shape, and terminal marker in a nearby legend.
Use one arrow style for one relationship within a visual.
Label conditions on the branch or transition that they control.
Label data, requests, events, or ownership transfers when the relationship is not obvious from component names.
Use text plus shape, line style, enclosure, or pattern for meaningful distinctions.
Preserve a linear reading order from start to outcome, earliest to latest, or outer boundary to inner detail.

These defaults apply when the source or project has no established notation:

```text
----->  synchronous request or direct dependency
- - ->  asynchronous message or deferred handoff
<---->  bidirectional exchange
--X     prohibited or terminated path
[NAME]  component or ordinary state
(NAME)  active or transient state
/NAME/  terminal state
{rule}  condition or guard
```

State a different legend when the domain uses these marks differently.

## Flow

Use a flow diagram for branching actions, routing, or decision logic.
Put the decision text in the decision node and label each outgoing branch.
End every reachable path at an outcome or a named continuation.

```text
[Start]
   |
   v
{Input valid?} --no--> /Reject with reason/
   |
  yes
   v
[Perform action] ----> /Return result/
```

The text equivalent lists each condition, its branch, and its outcome in reading order.

## State

Use a state visual for stable states and valid transitions.
Write transitions as `event {guard} / action` when all three elements exist.
Keep states, events, guards, actions, and terminal outcomes distinct.

```text
[QUEUED] --claim / start work--> (RUNNING)
                                     |
                                     +--success----------> /SUCCEEDED/
                                     |
                                     '--error {retry}----> [QUEUED]
```

The text equivalent names the initial state, each permitted transition, every guard, transition action, and terminal state.

## Timeline

Use a timeline for temporal order, latency, deadlines, or ownership handoffs.
Show a time direction and label intervals only when their duration matters.
Distinguish measured time from sequence order.

```text
Time ----->
T0              T0 + 30 s                 T0 + 2 min
| receive       | retry window opens      | request expires
[Gateway] ----> [Scheduler] - - - - - --> /Expired/
```

The text equivalent states the event order, actors, time basis, intervals, and any uncertainty in timing.

## Matrix

Use a matrix for options that share genuinely comparable criteria.
Keep each criterion independent and use parallel scales or phrases in each row.
Define symbols in text and preserve qualifications outside crowded cells.

| Option | Release coupling | Operating cost | Main constraint |
|---|---|---|---|
| One service | High | Low | Shared scaling |
| Split worker | Medium | Medium | Queue operations |

The text equivalent identifies the options, criteria, material differences, and any recommendation separately from the evidence.

## Bar or scale

Use a bar or scale for comparable magnitudes, capacity, confidence, or risk.
Show the baseline, unit, direction, exact or bounded value, and reference maximum when one exists.
Print the value in text beside the encoding.

```text
Queue capacity: 72 of 100 jobs
0 jobs  [##############------]  100 jobs
Direction: more filled segments means less remaining capacity.
```

The text equivalent states the value, unit, baseline, comparison point, and uncertainty.

## Before and after

Use matched panels for a structural or behavioral change.
Keep the viewpoint and abstraction level constant across both panels.
Mark and name changed relationships while retaining relevant unchanged context.

```text
BEFORE                         AFTER
[API] ----> [Job logic]        [API] - - -> [Queue] - - -> [Worker]
  |                              |
  '----> [Database]              '----> [Database]

Changed relationship: job execution moves from the API process to a queued worker.
```

The text equivalent inventories added, removed, changed, and intentionally unchanged elements.

## Layered architecture

Use layers for boundaries, dependency direction, ownership, and external systems.
Name every layer and place external actors outside the system boundary.
Distinguish structural dependencies from runtime exchanges in the legend.

```text
External caller
      |
      v request
+---------------- System boundary ----------------+
| Interface layer: [API]                           |
|                    | direct dependency           |
|                    v                             |
| Domain layer:    [Policy]                        |
|                    |                             |
|                    v                             |
| Data layer:      [Repository] ----> [Database]   |
+--------------------------------------------------+
```

The text equivalent states each boundary, component ownership, permitted dependency direction, external system, and relevant runtime behavior.

## Reject visual anti-patterns

- Reject a decorative diagram that answers no reader question.
- Reject unlabeled arrows, ambiguous arrow direction, and mixed edge meanings without a legend.
- Reject color-only, position-only, icon-only, or shape-only meaning.
- Reject crossing edges or dense labels that make reading order uncertain.
- Reject prose paragraphs placed inside nodes.
- Reject a matrix whose rows do not share criteria or whose cells hide decisive caveats.
- Reject bars without units or baselines and scales that imply false precision.
- Reject before-and-after panels with different viewpoints or abstraction levels.
- Reject architecture layers that mix ownership, deployment, and runtime sequence without naming those dimensions.
- Reject a visual that fails the main skill's fidelity completion check.

Return to prose or split the model when the smallest faithful visual remains harder to understand than its text equivalent.
