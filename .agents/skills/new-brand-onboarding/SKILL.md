---
name: new-brand-onboarding
description: >-
  Route a Studio v2 Brand onboarding to the home that executes it.
  Use when the captain asks to onboard, add, set up, or resume a Brand in Studio v2, including requests such as "Onboard Whoa Tea" and the explicit /skill:new-brand-onboarding command.
user-invocable: true
metadata:
  internal: true
---

# new-brand-onboarding

Route a Studio v2 Brand onboarding request to the home that executes it.
This skill owns recognition and routing only.
The execution procedure is the project-local skill in the Studio v2 clone, `projects/studio-v2/.agents/skills/new-brand-onboarding/SKILL.md`; load it where the run happens and never copy its steps here.

## Recognize

Treat each of these as this skill's trigger:

- The captain invokes `/skill:new-brand-onboarding`.
- The captain asks to onboard, add, set up, or resume a Brand in Studio v2, by name or generically, for example "Onboard Whoa Tea".

## Choose the home

Read the home you are in from durable records, never from conversation memory.

- `data/secondmates.md` registers `studio-v2-mate`: you are the primary Firstmate home; take the primary branch.
- This home's `data/charter.md` names the Studio v2 second-mate domain: you are `studio-v2-mate`; take the mate branch.
- Neither matches: stop and tell the captain the concrete blocker - Brand onboarding runs only in the primary home or the `studio-v2-mate` home.

## Primary branch: route to studio-v2-mate

Send the captain's request, with the Brand name and any stated scope, to the registered `studio-v2-mate` through the ordinary secondmate routing (`bin/fm-send.sh`; AGENTS.md section 7 owns the transport and the routed-reply contract).
Brand onboarding never executes in the primary home and never routes to the legacy Studio Pi domain (`studio-pi-mate`, `whoa-tea-brand-mate`).
When `studio-v2-mate` is not registered or is unreachable, stop and report that blocker instead of improvising an onboard elsewhere.

## Mate branch: commission one per-Brand worker

Create one ordinary task worker for this Brand through the standard lifecycle (`bin/fm-brief.sh`, `bin/fm-spawn.sh`; AGENTS.md sections 7 and 11 own them).
The brief states that the worker loads and follows the project-local `new-brand-onboarding` skill before running the engine, and that a Brand onboarding is an operational run of the Studio v2 engine: the worker changes no Studio code and places no runtime Brand data in the repository.
If the Studio v2 clone or the project-local skill is missing in this home, stop and report that concrete blocker.
Keep one persistent `studio-v2-mate` for every Brand; ordinary per-Brand workers stay the default, and a separate Brand-domain second mate is a captain decision made only when sustained volume justifies it.

## Isolation and approvals

- One worker per Brand; never mix two Brands' sources, evidence, decisions, or outputs in one worker or one report.
- The project skill owns the conversational contract: ask one missing-input question at a time, and keep raw CLI commands, record identifiers, and worker mechanics out of Captain-facing chat.
- Manifest approval and Brand Truth approval each require a fresh captain reply after the exact review packet is shown; an earlier or bundled approval cannot authorize either gate.
- When the request began in the primary home, route those approval packets and the captain's decisions back through the primary Firstmate; on direct mate contact, use the mate's normal Captain-facing route.
