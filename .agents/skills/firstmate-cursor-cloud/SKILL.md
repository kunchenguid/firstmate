---
name: firstmate-cursor-cloud
description: >-
  Agent-only playbook for reading the captain's own Cursor Cloud agents without pretending they are a selectable runtime backend or a harness.
  Use before reporting on Cursor Cloud agent activity, before answering what a cloud agent is doing or concluded, and before responding to requests to make Cursor Cloud native to firstmate.
user-invocable: false
metadata:
  internal: true
---

# firstmate-cursor-cloud

## Overview

Use this playbook when the captain asks what his Cursor Cloud agents are doing, what one of them concluded, or what they have consumed.
The current supported shape is a read-only view through `bin/fm-cursor.sh`, not a `cursor` value in `FM_BACKEND` and not an eighth harness.

`bin/fm-cursor.sh --help` owns the exact subcommands, flags, environment variables, and exit codes.
[`docs/configuration.md`](../../../docs/configuration.md) owns the `.env` activation contract.
This skill owns only the judgment: what the numbers mean, what this surface cannot do, and how to report it.

## Boundary

Cursor Cloud agents are a companion surface, the same boundary [`firstmate-codexapp`](../firstmate-codexapp/SKILL.md) draws for Codex Desktop threads.
They are not a runtime backend and not a harness, for concrete reasons rather than taste.

- A runtime backend must supply bounded pane capture, a composer, special-key sends, and a local worktree path.
  A cloud agent has none of these, so most of the adapter contract in `bin/fm-backend.sh` could only be stubbed with lies.
- A harness is a local interactive CLI that `bin/fm-spawn.sh` launches into a pane and `bin/fm-harness.sh` detects in the process tree.
  A cloud agent has no local process at all.
- A ship spawn must pass the worktree-isolation assertion in `bin/fm-spawn.sh`, which no cloud agent can satisfy.
  Bypassing that assertion for a whole backend class would weaken a safety invariant to fit a remote executor.

If the captain asks to make Cursor Cloud a native backend, relay that boundary and the increment path below rather than inventing an adapter.

## The one fact that is easy to get wrong

An agent's `status` field is lifecycle only: the enum is `ACTIVE|ARCHIVED`, and Cursor documents execution status as living on runs instead.
`ACTIVE` means "not archived". It does not mean the agent is working.
A finished agent stays `ACTIVE` indefinitely until somebody archives it, so a fleet of thirty `ACTIVE` agents can have nothing running at all.

Never report agent lifecycle as though it were activity.
Take the run status from the latest run, which `bin/fm-cursor.sh list` resolves and reports as its primary column: `CREATING` and `RUNNING` mean work is in flight, and `FINISHED`, `ERROR`, `CANCELLED`, and `EXPIRED` are terminal.

## Reading the fleet

1. `bin/fm-cursor.sh list` for the current picture, or `--json` when you need to compute over it.
2. `bin/fm-cursor.sh show <agent-id>` for one agent's repositories, environment, and Cursor Web URL.
3. `bin/fm-cursor.sh runs <agent-id>` for its history, including any PR URL a run produced.
4. `bin/fm-cursor.sh usage <agent-id>` for token consumption.

Two properties of the data change how you read it.

**The environment is the unit of work, not the repository.**
A Cursor agent is the task and its environment is the project: a named, multi-repo, secret-bearing context that `POST /v1/agents` accepts instead of a bare repository list, the two being mutually exclusive in the API.
A change spanning a front end and a back end is therefore one agent in one environment, not several tasks, and there is no multi-repo case to restrict.
`list` and `show` lead with the environment name for that reason.
Never describe an agent as working "in maverick-ui" when it runs in an environment that contains maverick-ui; name the environment.
Never assume a run's PR URL belongs to any particular repository in that environment - take the URL as given.
An agent created from a bare repository list has no environment name and displays as ad-hoc; it also carries none of a named environment's predefined secrets, which is worth saying when a captain wonders why an ad-hoc agent behaved differently from one in the shared environment.

**This home may declare a default environment** in `config/cursor-environment`, which `list` marks with `*` and `show` calls out.
The default is the intended target for a future operation that needs an environment; it deliberately does not filter what `list` shows, because hiding the agents outside it would misrepresent the fleet.
Use `--env` to narrow to the default or `--env <name>` for another environment, and read the filtered footer, which reports matches against the fetched page rather than against the whole fleet.
When the captain asks about "the environment" without naming one, the configured default is the sensible referent; say which one you used.

Run status resolution prefers a `latestRunId` field that list items carry in practice but that is **not** in Cursor's published schema, falling back to a per-agent runs lookup.
`--json` records which source answered in `runStatusSource`.
If the fast path ever disappears the fallback keeps working, so treat a change there as a Cursor-side change rather than a firstmate defect.

## What this surface cannot do

- **It cannot steer.** There is no `send`, `cancel`, `create`, `archive`, or `delete` verb, by design for this increment.
  When the captain wants to steer a cloud agent, hand him the agent's Cursor Web URL from `show` and say plainly that firstmate cannot send the follow-up itself yet.
- **It cannot show a live run's progress.** The Cloud Agents API has no conversation or messages endpoint, so there is no cheap bounded read of an in-flight run.
  A terminal run's final text is available through the API; for anything mid-run, escalate the URL rather than guessing.
- **It cannot report money.** `usage` returns token counts only, because the Cloud Agents API exposes no price or charge field.
  Report tokens and run counts, say that cost is unavailable, and never estimate spend from token counts and a public price list.
- **It sees only this operator's own agents.** A user API key is scoped to its own user, so this is not a company-wide fleet view.
  `GET /v1/agents` is documented as listing agents for the authenticated user and offers no team or user filter.
  Team-wide visibility would need a service account key that only a Cursor team admin can create, and it is not established that such a key enumerates agents created by other people rather than only its own.
  Do not promise a fleet-wide view on that basis; say what this key can see.

## Reporting to the captain

Translate through `AGENTS.md` section 9 as usual, and prefer the captain's nouns: the cloud agent, the run, the pull request, the repository.
Report activity from run status, never from lifecycle, and say "nothing running" rather than "35 active" when that is what the data means.
Include the full Cursor Web URL when the captain will want to open the agent, exactly as PR URLs are always given in full.

## Failure signals

- Helper reports it is not configured: the home has no `CURSOR_API_KEY` in its `.env`. Relay that and the dashboard link; do not go looking for a key in a keychain or another tool's credential store.
- Helper reports the key was rejected: the key is wrong, revoked, or belongs to another account. Ask the captain to regenerate it; never fall back to another credential source.
- Helper reports rate limiting: back off rather than retrying in a loop, and prefer `--limit` or `--no-runs` to shrink the request count.
- Every listed agent reads terminal but the captain expects work in flight: check whether he is looking at a different Cursor account, since this view is per-user.
