---
name: firstmate-addons-owner-rules
description: >-
  Use before writing a lane brief or merging a lane, and when a brief or merge is refused with an "owner-rules:" line.
  States the brief-time owner, hierarchy and risk rules and the one-step fix for each refusal.
user-invocable: false
---

# Owner rules

Brief-time owner, hierarchy and risk rules are enforced by the fleet, not by prose. A refusal prints one `owner-rules:` line; fix it as below.

## Rule 00: every lane names the owner ask it serves

The backlog item for the lane id (`data/backlog.md`) must have a title starting `[captain-ask]`, or its title or body must name a `MainNNN` order. Ship and scout lanes both need one; secondmate charters do not.

Refusal at brief time (`$id` is the task id):

```
owner-rules: no owner ask: name the [captain-ask] item or the MainNNN order this lane serves (add it to the backlog item for $id)
```

Fix: retitle the item `[captain-ask] ...` or add the `MainNNN` order to its body, then brief again.

## Rule 02: every backlog item belongs under an owner ask

Every non-scout lane item whose title does not start `[captain-ask]` needs one `parent:` body line naming an existing backlog item, or the exact value `upkeep` for true upkeep.
The named item may be an epic or a ticket under an epic; owner ask items are epic roots.
Secondmate charters and scouts are exempt from this hierarchy check.

Refusal at brief time (`$id` is the task id):

```
owner-rules: no valid parent: add parent: <backlog item id> or parent: upkeep to the backlog item for $id
```

Fix: add `parent: <backlog item id>` or `parent: upkeep` to the item's body, then brief again.
Run `bin/fm-owner-rules-tree.sh <backlog-file>` to inspect parent chains and invalid parent references.

## Rule 13: direct-PR plus a done-done check is the default route

`--mode no-mistakes` is only for an npm/store release, sign-in/keys/payment/security code, a data migration, a large change (new subsystem or about 400+ changed lines), shared protocol/crypto, or any PR to the Firstmate fork (umeranjum17/firstmate), whose required check "PR must be raised via no-mistakes" demands it. Everything else ships direct-PR, and the real user journey is checked (the done-done check) with its evidence on the sign-off Evidence tab.

Refusal at brief time for `--mode no-mistakes`:

```
owner-rules: mode no-mistakes needs one listed risk reason (release, security, migration, large-change, shared-protocol, fork-repo) in the backlog item for $id; use direct-PR plus a done-done check
```

Fix: if the lane truly is one of those, add exactly one body line `risk: <reason>` to the item (reason is one of the six listed). Otherwise brief with `--mode direct-PR`.

Refusal at merge time (`$what` is the PR URL, or `local merge <head>` with no PR):

```
owner-rules: no passed-proof receipt for $what; run the done-done check and post the evidence to the sign-off Evidence tab first
```

Fix: run the done-done check on the real journey at the merge head and post its evidence, then merge again. A merge whose Checks block says `screen: none` is exempt from this receipt only.

Refusal (`$src` is the PR URL, `$3` the merge head) when checks-lint has no PASS row for the PR head in `data/checks-gate.log`:

```
owner-rules: no checks-lint PASS for $src at $3; run FM_HOME=$FM_HOME <XDG_DATA_HOME>/fm-merge-on-green/checks-lint.sh $src <evidence folder> first
```

Fix: run that command (it logs the row), then merge again.

## Design discovery: say `design: required` or `design: none`

Design discovery goes through first-draft, and the lead decides per task whether a lane needs it. Put one body line on the lane's backlog item: `design: required` or `design: none`. Nothing blocks a lane on this; no line means not required.

- Always `required`: a bigger redesign, a new screen, a landing page, a new prototype or mock.
- Normally `none`: a copy fix, a CSS bug fix, a spacing or colour-token fix, a behaviour bug, a dependency bump. A scout that only investigates design is `none` too.

When it is `required`, the brief gets the exact line `Design discovery: required` under "Home brief additions". For a late change, append that exact line to `data/<id>/brief.md` and steer the worker with the mid-task-ask rule.

If the item has no `design:` line but its title or body says redesign, landing page, new screen, mock-up, prototype or first draft, the brief prints one stderr note and still succeeds; add the line and brief again if you want it recorded.

Refusal at brief time, for a design-like line (`design`, `desing`, `designs`, `design-discovery`) whose value is not exactly `required` or `none`, or for two such lines (`$id` is the task id):

```
owner-rules: design: must be required or none (backlog item for $id)
```

Fix: make the item's line exactly `design: required` or `design: none`, then brief again.

## Install

No add-on installs skills, so link this folder into the home's skills by hand:

```
ln -s <firstmate-addons>/owner-rules/skill <fm-home>/.agents/skills/firstmate-addons-owner-rules
```

`owner-rules/install.sh <fm-home>` turns the refusals on; the skill is only the reading for the leads.
