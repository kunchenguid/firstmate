# Planning gap reviews

The owner of this document is the repository owner.

Firstmate uses [Agent Room](https://github.com/steviebuilds/agent-room) only for adversarial planning gap reviews before implementation.
It is not used for pull-request reviews, where finders remain independent.
The agent-only operating procedure is [`planning-room`](../.agents/skills/planning-room/SKILL.md), and [`bin/fm-room.sh`](../bin/fm-room.sh) owns the lifecycle.

## Security footprint and limits

The room server binds to `127.0.0.1` and is scoped to one review under the active home state directory.
Agent Room has no authentication or authorization, so any process running as the same user can read or post room content.
Do not put secrets, credentials, or unrelated private material in a room.
The room is single-user local state and is not a network collaboration service.
The wrapper checks the review-owned process identity before stopping a server and refuses a port already in use by another process.
Setup checks out one pinned upstream commit and never runs the upstream installer or writes to global agent skill directories.

## Operating scope

A review starts with one lead seat and one or more independent adversary seats using the fixed time box recorded in the briefs.
The result is evidence for improving a plan: a numbered gap list, verdicts, counterexamples, transcript export, wall-time measurement, gap counts, and incident notes.
A room result does not authorize implementation, resolve a repository-owner decision, or replace a pull-request review.
Any repository-owner call follows the `captain-hold-lifecycle` completion gate before the planning review is closed.
