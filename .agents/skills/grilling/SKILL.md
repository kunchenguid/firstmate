---
name: grilling
description: >-
  Interview the captain relentlessly about a plan, decision, or idea until reaching a shared understanding, then hand off a single build-ready paragraph.
  Use when the captain wants their thinking stress-tested, uses a "grill" trigger phrase, or loads this skill from `grill-me`.
user-invocable: false
metadata:
  internal: true
---

# grilling

Interview the captain relentlessly until you reach a shared understanding.
Map this as a **design tree**: every decision branches into the decisions that hang off it.

Work the tree in **rounds**.
The **frontier** is every decision whose prerequisites are already settled - the questions you can ask *now* without guessing at answers you haven't heard yet.
Ask the whole frontier in one round: number each question and give your recommended answer.
Then wait for the captain's answers before the next round.

Each question should be formatted like so:

```
❓ **Q1** - **<question title>**: <question body, might be multiple paragraphs, including multiple choices>

➡️ <your recommended answer>
```

Each round the captain's answers reshape the tree - settled decisions push the frontier outward and unblock questions that depended on them.
Recompute the frontier and ask the next round.
A question whose answer depends on another question still open in this round belongs to a *later* round, not this one.

Finding *facts* is your job, never the captain's.
When a frontier question needs a fact from the environment, dispatch a read-only scout to find it rather than asking the captain for anything you could look up yourself - never dispatch a coding crewmate for this, per hard rule 1.
Don't block on it: a running scout is an unsettled prerequisite, so only the questions downstream of it wait for its report - ask the rest of the frontier now.
The *decisions* are the captain's - put each to them and wait.

The interview portion is done when the frontier is empty: every branch of the design tree visited, nothing left silently assumed.
Do not treat the interview as concluded until the captain confirms you have reached a shared understanding.

## Output

Once the frontier is empty and the captain has confirmed shared understanding, close the session with exactly ONE self-contained paragraph a downstream worker can build from with no other context.
Cover, in whatever order fits the plan: the concrete objective, every settled decision reached in the interview, constraints and exclusions the interview surfaced, and how the work will be validated.
Do not draft this paragraph before every round is answered and confirmed - it is the interview's single closing artifact, never a running summary.
If staying self-contained would take two paragraphs, the interview settled on too much at once for one build handoff; say so instead of writing two.
