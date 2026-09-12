---
name: skills-verifier
description: >-
  Agent-only verifier loop for the workflow-conversion path: turning a verified process into an agent skill.
  Use when a generator has produced a draft agent skill from a verified process, when the captain asks to verify or iterate on a skill draft, or before shipping a skill that was distilled from evidence rather than written against a spec.
  Runs the anchor-verify-negotiate-blindjudge loop with independent pi session sub-agents, reports a recommendation to the captain, and either lands the accepted commit or restores the rollback commit exactly.
user-invocable: false
metadata:
  internal: true
---

# skills-verifier

Verify an agent skill that was distilled from a verified process, so the shipped skill is checked by an independent agent rather than graded by the agent that wrote it.

This is the loop for the workflow-conversion path: a process that has already been executed and verified becomes an agent skill.
The generator turns the evidence into a draft.
This skill runs the rest of the loop: anchor a rollback point, have an independent verifier review it, negotiate with a two-round cap, judge the versions blind, report to the captain, then land or restore.

This skill is the owner of the loop.
Where the captain or firstmate has configured authority to decide, the loop applies it; otherwise the captain decides.
See `references/agent-cookbook/` for the companion manual that converts any verified process into an SSF-style custom workflow.

## The loop

Run the phases in order.
Each phase hands a concrete artifact to the next, and every phase is a separate agent unless this skill is the deciding authority.

1. **Handoff** - the generator delivers its final output, a draft agent skill.
2. **Rollback anchor** - commit the final output and record the commit hash as the restore point before any iteration.
3. **Verify** - an independent verifier agent receives the output, reviews it, and records its own commit/note.
4. **Bounded negotiation** - the verifier sends structured suggestions to the generator; they discuss and converge on an upgraded, versioned artifact.
5. **Blind judging** - a judge agent receives both versions anonymized plus deterministic facts, and ranks them with a justification.
6. **Report to the captain** - result, comparison, options, recommendation.
7. **Accept or Reject** - keep the accepted commit and run `writing-for-agents` to finalize, or restore the recorded rollback commit exactly.

## Roles and independence

The loop has three work roles plus a decider.

- The **generator** owns the draft.
- The **verifier** reviews the draft and proposes upgrades.
- The **judge** is the tie-breaker that sees both versions blind.
- The **decider** is the captain, or firstmate under configured authority.

Each of the three work roles MUST be an independent pi session.
Never let one agent grade its own work, and never let the generator be the verifier or the judge of its own draft.
A verifier that rewrites the draft and then judges its own rewrite is the same violation.

The sub-agents speak through pi-peer.
pi-peer is the verified transport; if it is unavailable after two genuine attempts, fall back to herdr agent prompts plus file inboxes and record the substitution in the PR.
See the transport section below for the exact message-flow commands.

## Phase 1 - Handoff

The generator delivers its final output and the path to it.
The output is a single draft file, usually a `SKILL.md`, plus any direct reference files it needs.

A handoff is complete when the draft path is known and the draft is readable.
Record the handoff path in the run log.

## Phase 2 - Rollback anchor

Commit the generator's final output before anything is iterated, and record the commit hash as the restore point.

- Require a clean index before staging: `git diff --cached --quiet` must pass; if unrelated entries are already staged, stop and have the operator commit or stash them, so the anchor commit never sweeps in unrelated staged work.
- Run `git add -- <draft> <references>` to stage only the draft and its direct references, so unrelated worktree changes never enter the rollback anchor.
- Commit with a message naming the version and stage, for example `skills-verifier: generator v1.0.0 draft`.
- Tag the commit, for example `git tag skills-verifier-anchor-<slug>`.
- Append a status note naming the tag and commit hash so the restore point survives a restart.

Do this before any negotiation or revision.
The anchor is what "Reject" restores, so it must exist before any change.

## Phase 3 - Verify

The verifier agent receives the draft and reviews it against the source evidence and the skill-writing reference.
The verifier records a commit and a note, and returns a structured review.

The review carries what it observed and what it proposes.
Separate facts from opinions: a fact is a testable claim about the draft, an opinion is a recommendation about wording or scope.

The verifier also validates the draft's own contract: frontmatter, trigger branches, phase structure, and that every rule traces to an authoritative source rather than a re-derived value.

## Phase 4 - Bounded negotiation

The verifier sends its structured suggestions to the generator, and they converge on an upgraded, versioned artifact.
Versioning is semver MAJOR.MINOR.PATCH and is truthful:

- **PATCH** - wording, clarity, or documentation, no behavior change.
- **MINOR** - a new bounded capability that does not change existing behavior.
- **MAJOR** - a behavior change.

Every bump must match what the artifact actually changed.
A negotiation is capped at two suggestion rounds.
After two rounds, the loop lands on a sign-off or escalates.
Never let the negotiation become unbounded discussion.
Write a `round` tag on each suggestion set and on the resulting artifact version.

## Phase 5 - Blind judging

The judge agent receives BOTH versions anonymized and ranks them.
Anonymization is strict:

- Label the versions A and B with the order randomized per round.
- Strip all metadata that could identify a version, including author, timestamp, and any name that leaks recency.
- Give the judge the two bodies plus deterministic facts only, never the source of either.

The deterministic facts are the objective inputs: test results, diff statistics, gate outputs, and any executable check on the skill.
The judge ranks one version over the other and writes a justification tied to those facts.

The judge must not be able to tell which version is newer, which is the generator's, or which the verifier rewrote.

## Phase 6 - Report to the captain

Report in plain terms: the result, the comparison, the options, and a recommendation.
Include the full URL of any PR when one exists.
Lead with the outcome and the decision the captain needs to make.

## Phase 7 - Accept or Reject

The decider chooses the winner, applying configured authority when present.

- **Accept** - keep the accepted commit and run the `writing-for-agents` skill to finalize and codify it.
  Then return to the generator (or the lane) for the final accept decision.
- **Reject** - restore the recorded rollback commit exactly.
  The restore is the anchor from phase 2, not a fresh checkout and not a discard of unlanded work.
  When firstmate decides under configured authority, discarding unlanded negotiated work beyond the anchored commit still requires explicit captain authorization per hard rule 3.

A rejected run must not leave a half-versioned draft in place.
Restore the anchor commit and stop the loop unless the decider reopens it.

## Transport: pi-peer

pi-peer lets independent pi sessions find and message each other.
Install it once per machine:

```bash
pi install git:github.com/shift-labs-ai/pi-peer@5e8fcb20c14cc5bc99a704e5b466f22bcf553861
```

The pinned ref is the piloted revision (v0.2.0).
Pinning keeps the install on the verified transport instead of the mutable head.

Nothing else to enable; every session registers itself on startup.
pi-peer exposes two model-invoked tools: `list_peers` and `message_peer`.
`list_peers` shows the other sessions, their working directory, and whether each is idle, working, unresponsive, or not running.
`message_peer` sends plain text to one peer by name; the receiving session sees it mid-task, marked as coming from a peer and carrying no authority.

A message is text only, capped at 32 KB.
Send a summary and a path, never a payload.
The channel is auditable and useless for smuggling state, which is the point.

The message-flow for a role is:

1. Launch the role as its own pi session in its own working directory, for example `pi -p --name <role>` with the role prompt.
2. Have the role call `list_peers` to discover the other sessions by name.
3. Have the role call `message_peer({ to: "<peer-name>", message: "<summary + path>" })` to hand off.
4. Check the receipt: the sender is told **delivered** if the receiving agent took the letter and **queued** if the letter waited.
   A queued letter is read when the peer session resumes.

The address of a session is derived from its working directory and pi's session id, so it survives restarts.
Mail for a session that is not running waits on disk and is read when the session resumes.
Use a distinct working directory per role so the three roles never share an inbox.

If pi-peer cannot be made to work after two genuine attempts, substitute herdr agent prompts plus file inboxes.
Each role's inbound and outbound messages become files in a shared directory, and each role is still a separate pi session.
Record the substitution in the PR so the reader knows the transport was swapped.

## The workflow-conversion path

A process becomes a skill only after it has been executed and verified.
The conversion path is:

1. Have the verified process's evidence, not a spec.
2. Have the generator distill the evidence into a draft skill.
3. Run this verifier loop on the draft.
4. Land the accepted version, then codify it with `writing-for-agents`.

The companion manual, `references/agent-cookbook/README.md`, walks through converting any verified process into an SSF-style custom workflow.
It uses the data-analysis process as the worked example.
See it when the conversion target is a custom workflow rather than a single skill.

## Tests

A colocated test pins the loop's deterministic parts.
It asserts the labels randomize per round, the negotiation cap holds, and the version bump is truthful.
It does not grade a model's prose, because a stub cannot prove an agent's judgement.
Run it with the repo's script runner; see `tests/skills-verifier.test.sh`.

## Files

- `SKILL.md` - this skill, the owner of the loop.
- `references/agent-cookbook/README.md` - the companion conversion manual, with the data-analysis worked example.
