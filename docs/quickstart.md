# Quickstart

This is a day-one walkthrough for someone who has just cloned firstmate and wants to use it.
It is deliberately short and concrete, and it points at the reference pages instead of repeating them.
If you have not installed the prerequisites yet, start with the Quick Start section of the [README](../README.md), then come back here.

## The mental model

You have one conversation, with the first mate.
You describe what you want in plain language, and the first mate figures out which project you mean, what shape the work is, and who should do it.

The actual project work is done by workers the first mate launches for you.
Each worker gets its own isolated copy of the repository, so several pieces of work can run at once without stepping on each other, and none of them touch the copy you are looking at.

You stay the captain.
The first mate is read-only over your projects, workers make the changes, and nothing lands until the merge authority you set says it can.
Most of the time your job is to answer questions, review a finished pull request, and say "merge it".

## Your first session

Launch Claude Code, Grok, or Pi inside the firstmate clone, as shown in the README, and let it read `AGENTS.md`.
The first thing it does is a session start: it takes charge of this home, checks the tools it needs, picks up anything left over from your last session, and prints a startup summary.

That summary - the digest - is the first mate orienting itself out loud, and it is worth skimming once.
It tells you four useful things:

- Anything that needs your attention right now, such as work that finished while you were away or a decision waiting on you.
- The state of your fleet: which pieces of work are under way and what each one is doing.
- Your projects and your recorded preferences, so you can see what it thinks it knows about you.
- Any setup problem it found, such as a missing tool or a GitHub login that has expired.

If it asks to install something, that is intentional: it detects, asks, and only installs after you approve.
If it reports a GitHub authentication problem, fix that before dispatching work, because everything downstream depends on it.

On a fresh clone the digest is mostly empty, and that is correct.
You have no projects and no work yet.

## Registering your first project

Just tell the first mate about the project.
Something like "add my repo github.com/you/xyz" or "clone xyz and set it up" is enough; it will make a local copy and register it.

At that point it will settle two things with you, and it helps to know what they mean.

**Delivery mode** is how finished work reaches you:

- `no-mistakes` runs the full validation pipeline - review, tests, documentation - before a pull request is offered to you.
  The right choice for anything product-facing.
- `direct-PR` skips that pipeline and simply opens a pull request.
  Good for small, low-risk, or internal work where the extra rigor is not worth the wait.
- `local-only` never pushes anywhere.
  The worker leaves a clean branch in your local copy, and the first mate merges it locally once you approve.
  Use this for private repos, experiments, or anything that must not reach a remote.

You are not asked to pick one cold.
A newly added project with a remote resolves to `no-mistakes-prod-only` unless you say otherwise, and a project with no remote resolves to `local-only`.
The first mate states the posture it resolved when it confirms the registration, so you only have to speak up if you want a different one.
`no-mistakes-prod-only` is a conditional policy rather than a fourth flat mode, and the [`project-management` skill](../.agents/skills/project-management/SKILL.md) owns which work it sends down which path.

**Merge authority** is the separate question of who presses merge.
By default you do: every pull request and every local landing waits for your explicit word.
If you set `yolo` on a project, the first mate will merge green, in-scope work itself and tell you afterwards.
It still never merges anything failing, and anything destructive, irreversible, or security-sensitive still comes to you.

You can pick a standing choice per project and override it for a single request whenever you want.
[docs/architecture.md](architecture.md) owns the registry entry behind these choices, including the `+yolo` merge flag and how each task's mode is decided.

## Dispatching your first piece of work

Say what you want.

```
> the login test is flaky in xyz, fix it
```

That is a **ship** task: you want the project changed, so a worker implements it and delivers it through the project's delivery mode.
Ship is the default, and it is what most requests become.

```
> before we touch it, figure out why our build got 3 minutes slower last month
```

That is a **scout** task: you want to know something, not change something.
A scout investigates and writes up what it found, and it never opens a pull request.
When the findings point at a fix you want, you say so, and the same worker is promoted to implement it rather than starting over.

From your seat the difference is simply what comes back: a scout returns findings, a ship returns something to merge.
You do not have to choose the label; describing the outcome you want is enough, and the first mate will tell you which one it dispatched.

If several pieces of work are independent, just ask for all of them.
Running them in parallel is the normal case, not a special mode.

## What supervision feels like

Silence is the healthy state.
Once work is under way the first mate keeps watch for you, so an idle-looking session usually means everything is fine.

You get pulled in for five things:

- A decision only you can make.
- Work that is ready for your review, with the full pull request link whenever the work produced one.
- Findings from a finished scout, handed to you as the findings themselves rather than a bare "done".
- A real failure or blocker, after the first mate has already tried the obvious recovery.
- Something it needs from you, such as a login or a credential.

You will not be told about retries, routine progress, or the machinery it uses to keep track.
If you want a status picture on demand rather than waiting to be told, ask for one with `/bearings`.

You can also watch any worker directly: each one runs in its own visible session you can attach to and even type into.
The first mate reconciles whatever you do there at its next check.

## Landing work

When a ship task is ready you get a message with the pull request link, a one-line summary of what changed, and the risk level when the validation pipeline produced one.

Review it however you normally would.
When you are happy, tell the first mate to merge, and it does the merge and records it.
For a `local-only` project there is no pull request; you approve the branch and it fast-forwards your local copy.

Afterwards it cleans up on its own: the worker's isolated copy is released, the work is recorded as done, and anything that was waiting on it is re-evaluated and may start immediately.
Cleanup deliberately refuses to run while there is unmerged or uncommitted work, so if you ever see it refuse, treat that as a signal to look rather than something to force.

## Commands worth knowing

You mostly talk in plain language, but these are the commands you type directly.

| Command            | Reach for it when                                                                              |
| ------------------ | ---------------------------------------------------------------------------------------------- |
| `/bearings`        | You want a status picture: what is running, what is waiting on you, what landed.                 |
| `/ahoy`            | You lost the thread of this conversation and want a recap plus a walkthrough of open decisions.  |
| `/afk`             | You are stepping away and want routine matters handled quietly and real escalations batched.     |
| `/stow`            | You are about to reset or compact the session and want what was learned written down first.      |
| `/updatefirstmate` | You want to pull the latest firstmate and update everything it runs.                             |

Codex uses the same names with `$` instead of `/`, such as `$afk`.
The README's built-in skills table has the fuller description of each.

## When something looks wrong

Nothing here needs you to debug internals; point at the owner and let the first mate work.

- Ask it plainly: "what is the state of that work?" or "why has nothing happened?" is a legitimate instruction, and it will reconcile and report.
- Setup, tool, and authentication problems surface in the startup summary; [docs/configuration.md](configuration.md) owns every setting behind them.
- Runtime problems specific to how workers are launched belong to your backend's page, linked from the README's Documentation section.
- If you want to understand a behavior rather than fix it, [docs/architecture.md](architecture.md) explains how the parts fit together, and [`AGENTS.md`](../AGENTS.md) is the contract the first mate itself follows.

If the first mate is stuck rather than merely quiet, restarting the session is safe.
Everything durable lives on disk, so the next session picks up exactly where this one was.
